#!/bin/bash
# openccu-lite: boot a disk image (ova / generic-x86_64 products) headless in QEMU and check that
# occulited answers through lighttpd. Works without KVM (TCG; count on a few minutes to boot).
# Prints the image's /VERSION first, so a wrong PLATFORM is caught before the recovery would.
#
# A systemd image (task 20, D-30) is booted with its kernel taken straight from the rootfs and a
# systemd debug shell on the serial line (systemd.debug_shell=ttyS0 — no login, no password, only
# in this test), through which the script checks the units, the journal on the userfs and the
# addon generator round trip: an rc.d script is dropped in, addons.target is restarted, the box is
# rebooted and the addon unit must be back after the reboot. busybox images boot through grub as
# before; the HTTP checks are the same for both.
#
# Usage: scripts/lite-qemu-test.sh <sdcard.img> [port]
#
# The work dir (a sparse copy of the image, 4.5 GB apparent, ~700 MB real, the serial log) goes to
# LITE_QEMU_WORKDIR, or to /var/tmp when /tmp is a tmpfs: on the runner /tmp is a tmpfs counted as
# the container's memory, and disk copies there starved the 2 GB guest until the OOM killer took
# QEMU (task 308, dev.35). Whatever ends the script - a pass, a failure, QEMU dying, Ctrl-C or a
# kill - stops the QEMU it started and removes the work dir; a failed run keeps its serial log next
# to it as <workdir>.serial.log, and a failed systemd run its evidence as <workdir>.evidence/ (B-321,
# below).
#
# The evidence of a failed run (B-321, B-326): hmipserver's JVM aborted in its first minute under
# TCG on three build rounds, and each time the reason stayed in the guest - the JVM's hs_err file
# and the core went to the unit's private /tmp and /var/tmp, which systemd removes at the restart,
# and the work dir went with the disk. So the guest is booted with a test-only drop-in for
# hmipserver.service, a credential on its kernel command line: JAVA_TOOL_OPTIONS points the JVM's
# hs_err file into /var/hmipserver (the unit's own, kept until the reboot), and a step before each
# start pipes cores through dd into /usr/local/lite-qemu-core.<comm> (one per program, the newest,
# cut at LITE_QEMU_CORE_MB, default 256). Before the reboot and on a failure the guest moves both into /usr/local/lite-qemu-evidence/
# with its boot ID; on a failure it also exports every boot's journal, the journal of the addon
# units, occulited and hmipserver, and a state summary there, and powers off cleanly. The script
# then copies that directory out of the disk copy's userfs (debugfs, no mount) - or, when QEMU died
# first, the raw journal and any core - gzips the cores, holds the whole to LITE_QEMU_EVIDENCE_MB
# (default 512; the cores go first), and prints where it lies. Nothing of this on a pass, a
# GitHub-quota-only failure (exit 3) or an interrupt. LITE_QEMU_CRASH_TEST=hmipserver sends the
# JVM a SIGSEGV after boot 1's checks (hs_err, then abort and core, as in B-321): a run that must
# fail and keep its evidence, to test this path.
#
# The firmware and the boot loader (task 480): the image boots with a BIOS and with UEFI, and the
# -kernel boot above passes both GRUBs by. Four switches cover them:
#   LITE_QEMU_FIRMWARE=uefi   OVMF instead of SeaBIOS (LITE_QEMU_OVMF_CODE / LITE_QEMU_OVMF_VARS, or
#                             the ovmf package's 4M files under /usr/share/OVMF). With the -kernel
#                             boot OVMF starts the kernel through its EFI stub.
#   LITE_QEMU_BOOT=disk       no -kernel: the firmware starts the image's own GRUB (the MBR's under
#                             SeaBIOS, EFI/BOOT/BOOTX64.EFI under OVMF), which reads grub.cfg and
#                             loads the kernel from the rootfs. The test's kernel arguments (the
#                             debug shell, the evidence drop-in) are appended to default_cmdline in
#                             the disk copy's grub.cfg (mtools). Each boot checks that the firmware
#                             is the one asked for (/sys/firmware/efi) and that GRUB loaded the kernel.
#   LITE_QEMU_RECOVERY=1      (disk boots) at the end: .recoveryMode on the userfs, a reboot, and GRUB
#                             must start the recovery system - its page answers, and it removed the
#                             marker. The run ends there.
#   LITE_QEMU_UPDATE=<zip>    (disk boots) at the end, instead: the release zip is handed to
#                             `occulited update install --file`, the recovery system installs it and
#                             the system must come back as the zip's version, under the same firmware,
#                             with GRUB's EFI binary in bootfs. LITE_QEMU_SWITCH_FIRMWARE=1 then powers
#                             off and starts the updated disk under the other firmware: an installation
#                             from before UEFI support boots with UEFI after its update.
#
# LITE_QEMU_FIRSTBOOT_RUNS=<n> (B-368) boots the image's first boot <n> times, each from a fresh copy
# with the grown disk, and nothing else: the userfs resize (S03) and the factory reset (S04) of a
# fresh image run on every one of them. A run passes when both ran, /usr/local is mounted and
# occulited, occulited-helper and occu-clock-save are active - and systemd itself never stopped
# the userfs or its file system check during the boot (PID 1's "Unmounting /usr/local" or "Stopped
# File System Check"). That was the race: mkfs.ext4 made udev drop /dev/disk/by-label/userfs for a
# moment, systemd stopped the fsck unit bound to it and with it usr-local.mount and every unit that
# requires the mount, and the pending starts of occulited-helper and occulited were gone for the
# boot (1 of 3 installs on a Proxmox VM). It counts the runs that met the race and the runs that
# lost occulited; any of either fails. Combines with LITE_QEMU_FIRMWARE and LITE_QEMU_BOOT.
# LITE_QEMU_FIRSTBOOT_STRESS=1 adds udev probes of the userfs during the factory reset (see there).
#
# LITE_QEMU_FRESH=1 is the fresh-image probe of the build rounds (no outbound connection from a
# fresh image, D-91): boot 1, then ten minutes of the guest's TCP connections to ports 443 and 80
# and occulited's journal lines about the outside, nothing else. It replaces the runner's
# hand-made copy of this script (dev29b-qemu-fresh.sh), which exited before the cleanup.
set -u
IMG=${1:?disk image}
PORT=${2:-8090}
say() { printf '%s %s\n' "$(date +%T)" "$*"; }
FAILED=0
fail() { say "FAIL: $*"; FAILED=1; ENV_ONLY=0; }
# task 376: a failure that is GitHub's anonymous quota on this host's address, not the image - said
# apart, and the run's exit is 3 instead of 1 when nothing else failed
QUOTA_MET=0
ENV_ONLY=1
envfail() { say "FAIL (environment: GitHub's quota, not the image): $*"; FAILED=1; QUOTA_MET=1; }
is_quota() { case "$1" in *"rate limit"*) return 0;; esac; return 1; }  # occulited's "GitHub rate limit", the API's "API rate limit exceeded"

say "image $IMG ($(du -h "$IMG" | cut -f1))"
# The rootfs without mounting: buildroot leaves the filesystem that went into the image next to
# it as rootfs.ext4, and debugfs (e2fsprogs) reads that as a plain file - no loop device, no
# root, and no "-o offset", which Debian 13's debugfs does not have.
ROOTFS="$(dirname "$IMG")/rootfs.ext4"
# debugfs lives in /usr/sbin, which a non-root PATH usually omits - and the CI job runs as
# `builder`. When it was only looked for with `command -v`, the whole systemd branch below was
# skipped without a word and the run still said OK: on 2026-09-07 that turned the first beta.2
# boot test into "does it answer HTTP" and nothing else. Look for it properly, and if the rootfs
# is here and debugfs is not, fail rather than degrade.
DEBUGFS="$(command -v debugfs 2>/dev/null || true)"
for c in /usr/sbin/debugfs /sbin/debugfs /usr/local/sbin/debugfs; do
  [ -n "$DEBUGFS" ] && break
  [ -x "$c" ] && DEBUGFS="$c"
done
if [ -f "$ROOTFS" ] && [ -z "$DEBUGFS" ]; then
  say "FAIL: $ROOTFS is here but debugfs (e2fsprogs) is not - install it, or put /usr/sbin on PATH."
  say "      Without it this test checks only that the image answers HTTP, and says OK anyway."
  exit 1
fi
[ -f "$ROOTFS" ] && [ -n "$DEBUGFS" ] || ROOTFS=
if [ -n "$ROOTFS" ]; then
  say "/VERSION in the image:"; "$DEBUGFS" -R 'cat /VERSION' "$ROOTFS" 2>/dev/null | sed 's/^/  | /'
fi
# the cgroup's OOM kills, read before and after: a QEMU that vanished is most likely one of them
oom_kills() { awk '$1 == "oom_kill" {print $2}' /sys/fs/cgroup/memory.events 2>/dev/null; }
OOM0=$(oom_kills)
[ -z "$OOM0" ] || say "cgroup oom_kill: $OOM0"

# the work dir: never on a tmpfs when it can be helped (see the top)
if [ -n "${LITE_QEMU_WORKDIR:-}" ]; then
  mkdir -p "$LITE_QEMU_WORKDIR" && WORK=$(mktemp -d "$LITE_QEMU_WORKDIR/lite-qemu.XXXXXXXXXX") || { say "cannot create a work dir in $LITE_QEMU_WORKDIR"; exit 1; }
elif [ "$(stat -f -c %T "${TMPDIR:-/tmp}" 2>/dev/null)" = tmpfs ] && [ -d /var/tmp ] && [ -w /var/tmp ] \
  && [ "$(stat -f -c %T /var/tmp 2>/dev/null)" != tmpfs ]; then
  WORK=$(mktemp -d /var/tmp/lite-qemu.XXXXXXXXXX) || { say "cannot create a work dir in /var/tmp"; exit 1; }
else
  WORK=$(mktemp -d) || { say "cannot create a work dir"; exit 1; }
fi
say "work dir $WORK ($(stat -f -c %T "$WORK" 2>/dev/null))"
GUEST_PID=

qemu_pid() { cat "$WORK/qemu.pid" 2>/dev/null; }
qemu_alive() { p=$(qemu_pid); [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
# stop the QEMU this script started, by its pidfile: TERM, up to 10 s, then KILL
qemu_stop() {
  p=$(qemu_pid); [ -n "$p" ] || return 0
  kill "$p" 2>/dev/null || return 0
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$p" 2>/dev/null || return 0; sleep 1; done
  say "QEMU (pid $p) ignored TERM; killing it"; kill -9 "$p" 2>/dev/null; true
}
oom_report() {
  o=$(oom_kills); [ -n "$o" ] || return 0
  if [ -n "$OOM0" ] && [ "$o" != "$OOM0" ]; then say "cgroup oom_kill: $OOM0 -> $o: the OOM killer struck during this run"
  else say "cgroup oom_kill: $o (unchanged)"; fi
}
# QEMU gone while the test still needs it: say so once, with the OOM count, and end the run. In
# the script's own shell only (a $( ) subshell cannot end the script; guest() there just returns).
# Before task 308 the guest driver was restarted against the dead socket for minutes, until the
# script's bash segfaulted (rc 139) and left the work dir behind.
qemu_check() {
  qemu_alive && return 0
  [ -n "$(qemu_pid)" ] || return 0  # not started yet
  say "FAIL: QEMU's process (pid $(qemu_pid)) is gone: $1"
  oom_report
  FAILED=1
  exit 1
}
# B-321: the evidence of a failed run (see the top). Only the systemd product has the guest shell
# and the userfs layout this knows.
EVID_CORE_MB=${LITE_QEMU_CORE_MB:-256}
EVID_MAX_MB=${LITE_QEMU_EVIDENCE_MB:-512}
EVID_DONE=0
# a drop-in for hmipserver.service as a systemd credential on the kernel command line (base64; the
# debug generator installs it, systemd >= 256): the JVM's hs_err file into /var/hmipserver, and the
# core pipe set before each start - at the unit's start, because S01InitHost's sysctl -p sets the
# image's /var/tmp pattern after systemd-sysctl, so a sysctl.extra credential does not hold. In a
# unit file % is %%. busybox's dd counts every short read from the pipe as a block, so 4 KiB blocks
# (the pages the kernel writes): with 1 MiB ones the cap was 16 MB instead of 256.
EVID_DROPIN=$(printf '[Service]\nEnvironment=JAVA_TOOL_OPTIONS=-XX:ErrorFile=/var/hmipserver/hs_err_pid%%%%p.log\nExecStartPre=-+/bin/sh -c '"'"'echo "|/bin/dd of=/usr/local/lite-qemu-core.%%%%e bs=4096 count=%s" >/proc/sys/kernel/core_pattern'"'"'\n' "$((EVID_CORE_MB * 256))" | base64 | tr -d '\n')
EVID_CMDLINE="systemd.set_credential_binary=systemd.unit-dropin.hmipserver.service~lite-qemu-evidence:$EVID_DROPIN"
only_quota() { [ "$ENV_ONLY" = 1 ] && [ "$QUOTA_MET" = 1 ]; }
# stash_snippet: the guest-side one-liner that moves hmipserver's hs_err files (from /var/hmipserver,
# a tmpfs) and the cores onto the userfs, named with the boot's ID; makes the directory only when
# there is something to keep
stash_snippet() {
  printf '%s' 'E=/usr/local/lite-qemu-evidence; b=$(cut -c1-8 /proc/sys/kernel/random/boot_id); for f in /var/hmipserver/hs_err_pid*.log; do [ -e "$f" ] && mkdir -p $E && cp "$f" "$E/boot-$b-${f##*/}"; done; for f in /usr/local/lite-qemu-core.*; do [ -e "$f" ] && mkdir -p $E && mv "$f" "$E/boot-$b-${f##*/}"; done; sync; [ -d $E ] && ls -l $E; true'
}
# evidence_snippet: every boot's journal, the addon units', occulited's and hmipserver's journal per
# boot (B-326), and a state summary, each cut at 64 MiB before gzip
evidence_snippet() {
  printf '%s' 'E=/usr/local/lite-qemu-evidence; C=67108864; mkdir -p $E; for b in $(journalctl --list-boots --no-pager | grep -E "^ *-?[0-9]+ [0-9a-f]{32}" | sed -E "s/^ *(-?[0-9]+) .*/\1/"); do journalctl -b $b --no-pager -o short-precise | head -c $C | gzip >$E/journal-b$b.txt.gz; journalctl -b $b --no-pager -o short-precise -u "addon-*" -u occulited.service -u hmipserver.service | head -c $C | gzip >$E/units-b$b.txt.gz; done; { cat /proc/cmdline; uptime; free -m; df -h /usr/local; systemctl is-system-running; systemctl --failed --no-legend --plain --no-pager; systemctl list-units --all --no-legend --plain --no-pager "addon-*" hmipserver.service occulited.service; systemctl show hmipserver.service -p NRestarts -p Result -p ExecMainCode -p ExecMainStatus; journalctl --list-boots --no-pager; cat /proc/sys/kernel/core_pattern; ls -l /var/hmipserver; } >$E/state.txt 2>&1; sync; ls -l $E'
}
# evidence_guest: on a failure, once, while the guest answers
evidence_guest() {
  [ "${SYSTEMD:-0}" = 1 ] && [ "$EVID_DONE" = 0 ] || return 0
  EVID_DONE=1
  qemu_alive || return 0
  say "evidence: the failed run's hs_err files, cores and journals onto the guest's userfs"
  R=$(guest "$(stash_snippet)"); printf '%s\n' "$R"
  case "$R" in *'[rc=0]'*) ;; *) say "evidence: the guest shell did not answer; only what is on its disk is kept"; return 0;; esac
  guest "$(evidence_snippet)"
}
# evidence_poweroff: a clean poweroff, so the userfs is unmounted before its copy is read; QEMU
# exits with its guest. Stopped by force after 180 s.
evidence_poweroff() {
  qemu_alive || return 0
  [ "${SYSTEMD:-0}" = 1 ] || return 0
  guest 'sync; systemctl --no-block poweroff' >/dev/null
  guest_close
  for _ in $(seq 1 90); do qemu_alive || return 0; sleep 2; done
  say "evidence: the guest did not power off within 180 s; stopping QEMU (its userfs may miss the last writes)"
  qemu_stop
}
# part_offset <disk> <n>: the byte offset of MBR partition <n>, empty when there is none
part_offset() {
  python3 -c 'import struct, sys
d = open(sys.argv[1], "rb").read(512); n = int(sys.argv[2])
s = struct.unpack("<I", d[446 + 16 * (n - 1) + 8:446 + 16 * (n - 1) + 12])[0] if len(d) == 512 and d[510:512] == b"\x55\xaa" else 0
print(s * 512 if s else "")' "$1" "$2" 2>/dev/null
}
# evidence_extract: after QEMU stopped, copy the evidence out of the disk copy's userfs (partition 3)
# into <workdir>.evidence/, gzip the cores, hold the whole to EVID_MAX_MB, and say where it lies
evidence_extract() {
  [ "${SYSTEMD:-0}" = 1 ] && [ -n "$DEBUGFS" ] && [ -f "$WORK/disk.img" ] || return 0
  ev_off=$(part_offset "$WORK/disk.img" 3)
  [ -n "$ev_off" ] || { say "evidence: no userfs partition in the disk copy"; return 0; }
  ev_fs="$WORK/disk.img?offset=$ev_off"
  ev="$WORK.evidence"
  mkdir -p "$ev" || return 0
  "$DEBUGFS" -R "rdump /lite-qemu-evidence $ev" "$ev_fs" >/dev/null 2>&1
  [ -d "$ev/lite-qemu-evidence" ] && { mv "$ev/lite-qemu-evidence"/* "$ev"/ 2>/dev/null; rmdir "$ev/lite-qemu-evidence" 2>/dev/null; }
  # cores the guest did not move (QEMU died first)
  for n in $("$DEBUGFS" -R 'ls -p /' "$ev_fs" 2>/dev/null | awk -F/ '$6 ~ /^lite-qemu-core\./ {print $6}'); do
    "$DEBUGFS" -R "dump /$n $ev/$n" "$ev_fs" >/dev/null 2>&1
  done
  # no journal export from the guest (it did not answer, or QEMU died): the raw journal, read here
  # when this host has journalctl
  if ! ls "$ev"/journal-b*.txt.gz >/dev/null 2>&1; then
    "$DEBUGFS" -R "rdump /var/log/journal $ev" "$ev_fs" >/dev/null 2>&1
    if [ -d "$ev/journal" ] && command -v journalctl >/dev/null 2>&1; then
      for b in $(journalctl -D "$ev/journal" --list-boots --no-pager 2>/dev/null | grep -E '^ *-?[0-9]+ [0-9a-f]{32}' | sed -E 's/^ *(-?[0-9]+) .*/\1/'); do
        journalctl -D "$ev/journal" -b "$b" --no-pager -o short-precise 2>/dev/null | head -c 67108864 | gzip >"$ev/journal-b$b.txt.gz"
      done
    fi
  fi
  for f in "$ev"/*lite-qemu-core.*; do
    case "$f" in *.gz|*'*'*) ;; *) [ -f "$f" ] && gzip -1 "$f";; esac
  done
  if [ "$(du -sm --apparent-size "$ev" | cut -f1)" -gt "$EVID_MAX_MB" ]; then
    say "evidence: more than $EVID_MAX_MB MB (LITE_QEMU_EVIDENCE_MB); dropping the cores, then the raw journal"
    for f in "$ev"/*lite-qemu-core.* "$ev/journal"; do
      [ -e "$f" ] || continue
      [ "$(du -sm --apparent-size "$ev" | cut -f1)" -gt "$EVID_MAX_MB" ] || break
      say "evidence: dropped ${f##*/} ($(du -sh --apparent-size "$f" | cut -f1))"; rm -rf "$f"
    done
  fi
  if [ -z "$(ls -A "$ev" 2>/dev/null)" ]; then rmdir "$ev"; say "evidence: nothing found on the guest's userfs"; return 0; fi
  say "evidence kept at $ev ($(du -sh --apparent-size "$ev" | cut -f1)):"; ls -l "$ev" | sed 's/^/  | /'
}
cleanup() {
  rc=$?
  trap - EXIT INT TERM
  # the evidence (B-321): not on a pass, GitHub's quota alone (3) or an interrupt
  case "$rc" in 0|3|130|143) EVID=0;; *) EVID=1;; esac
  if [ "$EVID" = 1 ]; then evidence_guest; evidence_poweroff; fi
  guest_close 2>/dev/null
  qemu_stop
  [ -z "${UP_HTTP:-}" ] || kill "$UP_HTTP" 2>/dev/null  # the update phase's file server
  if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
    if [ "$rc" != 0 ] && [ -s "$WORK/serial.log" ]; then
      say "last serial output:"; tail -n 60 "$WORK/serial.log" | sed 's/^/  | /'
      cp "$WORK/serial.log" "$WORK.serial.log" && say "serial log kept at $WORK.serial.log"
    fi
    [ "$EVID" = 1 ] && evidence_extract
    rm -rf "$WORK"
  fi
  [ "$rc" = 0 ] || oom_report
  exit "$rc"
}
# the driver holds the chardev socket and the CI step's stderr, QEMU the disk copy: neither may
# outlive the script, however it ends
trap cleanup EXIT
trap 'say "interrupted"; exit 130' INT
trap 'say "terminated"; exit 143' TERM
cp --sparse=always "$IMG" "$WORK/disk.img" || { say "cannot copy $IMG into $WORK"; exit 1; }
# a real VM disk is bigger than the image: give the userfs resize room (journald lives there
# on the systemd product; the image's userfs partition is 3 MB until it grows).
# LITE_QEMU_DISK_GROW=8G for LITE_QEMU_UPDATE: the userfs then holds the zip and its unpacked image
truncate -s "+${LITE_QEMU_DISK_GROW:-2G}" "$WORK/disk.img"

SYSTEMD=0
if [ -n "$ROOTFS" ] && "$DEBUGFS" -R 'stat /usr/lib/systemd/systemd' "$ROOTFS" >/dev/null 2>&1; then
  SYSTEMD=1
  "$DEBUGFS" -R "dump /zImage $WORK/zImage" "$ROOTFS" >/dev/null 2>&1 || { say "cannot extract /zImage"; exit 1; }
fi

# the firmware and the boot loader (see the top)
FIRMWARE=${LITE_QEMU_FIRMWARE:-bios}
BOOTVIA=${LITE_QEMU_BOOT:-kernel}
case "$FIRMWARE" in bios|uefi) ;; *) say "LITE_QEMU_FIRMWARE is bios or uefi, not '$FIRMWARE'"; exit 1;; esac
case "$BOOTVIA" in kernel|disk) ;; *) say "LITE_QEMU_BOOT is kernel or disk, not '$BOOTVIA'"; exit 1;; esac
[ "$SYSTEMD" = 1 ] || BOOTVIA=disk  # a busybox image has always booted through its GRUB
UPDATE_ZIP=${LITE_QEMU_UPDATE:-}
if [ "${LITE_QEMU_RECOVERY:-0}" = 1 ] || [ -n "$UPDATE_ZIP" ]; then
  [ "$SYSTEMD" = 1 ] && [ "$BOOTVIA" = disk ] || { say "LITE_QEMU_RECOVERY and LITE_QEMU_UPDATE need LITE_QEMU_BOOT=disk (GRUB chooses the recovery system) and a systemd image"; exit 1; }
  [ -z "$UPDATE_ZIP" ] || [ -f "$UPDATE_ZIP" ] || { say "LITE_QEMU_UPDATE: $UPDATE_ZIP is not a file"; exit 1; }
fi
OVMF_CODE=${LITE_QEMU_OVMF_CODE:-}
OVMF_VARS=${LITE_QEMU_OVMF_VARS:-}
ovmf_find() {
  for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/edk2/x64/OVMF_CODE.4m.fd; do
    [ -n "$OVMF_CODE" ] && break
    [ -f "$c" ] && OVMF_CODE=$c
  done
  for c in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd /usr/share/edk2/x64/OVMF_VARS.4m.fd; do
    [ -n "$OVMF_VARS" ] && break
    [ -f "$c" ] && OVMF_VARS=$c
  done
  [ -f "$OVMF_CODE" ] && [ -f "$OVMF_VARS" ] || { say "FAIL: no OVMF firmware here (the ovmf package, or LITE_QEMU_OVMF_CODE and LITE_QEMU_OVMF_VARS)"; exit 1; }
}
if [ "$FIRMWARE" = uefi ] || [ "${LITE_QEMU_SWITCH_FIRMWARE:-0}" = 1 ]; then ovmf_find; fi
# the arguments the test gives the kernel besides the image's own
TEST_CMDLINE="systemd.debug_shell=ttyS0 $EVID_CMDLINE"
# LITE_QEMU_FIRSTBOOT_STRESS=1 (with LITE_QEMU_FIRSTBOOT_RUNS, B-368): a test-only drop-in for
# occu-factory-reset.service, as a credential like the evidence one, asks udev to probe the userfs
# partition every 50 ms while the factory reset runs - the probe that, by chance, fell into
# mkfs.ext4's window on the Proxmox VM. It turns the 1-in-3 race into a near certainty on an
# image without the fix, and a fixed image must still keep the userfs and occulited. In a unit
# file $ is $$.
if [ "${LITE_QEMU_FIRSTBOOT_STRESS:-0}" = 1 ]; then
  STRESS_DROPIN=$(base64 -w0 <<'EOS'
[Service]
ExecStartPre=/bin/sh -c 'while :; do echo change >/sys/class/block/vda3/uevent; sleep 0.05; done >/dev/null 2>&1 & echo $$! >/run/lite-qemu-uevent.pid'
ExecStartPost=-/bin/sh -c 'kill $$(cat /run/lite-qemu-uevent.pid)'
EOS
)
  TEST_CMDLINE="$TEST_CMDLINE systemd.set_credential_binary=systemd.unit-dropin.occu-factory-reset.service~lite-qemu-stress:$STRESS_DROPIN"
fi
# grub_patch: a disk boot takes the kernel's arguments from the image's grub.cfg, so the test's are
# appended to default_cmdline there, in the disk copy (again after an update, which writes a new
# bootfs). Nothing else of the boot path is touched: the firmware finds GRUB, GRUB its grub.cfg.
grub_patch() {
  command -v mcopy >/dev/null 2>&1 || { say "FAIL: LITE_QEMU_BOOT=disk needs mtools (mcopy) to add the test's kernel arguments to the disk copy's grub.cfg"; exit 1; }
  gp_off=$(part_offset "$WORK/disk.img" 1)
  [ -n "$gp_off" ] || { say "FAIL: no first partition in the disk copy"; exit 1; }
  rm -f "$WORK/grub.cfg"
  MTOOLS_SKIP_CHECK=1 mcopy -i "$WORK/disk.img@@$gp_off" ::boot/grub/grub.cfg "$WORK/grub.cfg" >/dev/null 2>&1 || { say "FAIL: no boot/grub/grub.cfg in the disk copy's bootfs"; exit 1; }
  grep -q '^default_cmdline=".*"$' "$WORK/grub.cfg" || { say "FAIL: the image's grub.cfg has no default_cmdline line to append the test's arguments to"; exit 1; }
  grep -qF "systemd.debug_shell=ttyS0" "$WORK/grub.cfg" && return 0
  sed -i "s|^default_cmdline=\"\(.*\)\"\$|default_cmdline=\"\1 $TEST_CMDLINE\"|" "$WORK/grub.cfg"
  MTOOLS_SKIP_CHECK=1 mcopy -o -i "$WORK/disk.img@@$gp_off" "$WORK/grub.cfg" ::boot/grub/grub.cfg >/dev/null 2>&1 || { say "FAIL: cannot write grub.cfg back into the disk copy's bootfs"; exit 1; }
}
# has_efi_loader: 0 when the disk copy's bootfs holds GRUB's EFI binary
has_efi_loader() {
  he_off=$(part_offset "$WORK/disk.img" 1)
  [ -n "$he_off" ] && MTOOLS_SKIP_CHECK=1 mdir -i "$WORK/disk.img@@$he_off" ::EFI/BOOT/BOOTX64.EFI >/dev/null 2>&1
}
if [ "$SYSTEMD" = 1 ] && [ "$BOOTVIA" = disk ]; then
  grub_patch
  if [ "$FIRMWARE" = uefi ] && ! has_efi_loader; then say "FAIL: the image's bootfs has no EFI/BOOT/BOOTX64.EFI: it cannot boot with UEFI"; exit 1; fi
fi
say "firmware: $FIRMWARE; boot: $BOOTVIA$([ "$BOOTVIA" = disk ] && echo " (the image's own GRUB)")"
# firmware_check <boot>: the guest runs under the firmware asked for and, in a disk boot, its
# kernel came from GRUB (which names the image it loaded on the command line)
firmware_check() {
  R=$(guest '[ -d /sys/firmware/efi ] && echo fw=uefi || echo fw=bios; cat /proc/cmdline')
  case "$R" in *"| fw=$FIRMWARE"*) say "$1: the guest runs under $FIRMWARE firmware";; *) fail "$1: the guest does not run under $FIRMWARE firmware: $R";; esac
  if [ "$BOOTVIA" = disk ]; then
    case "$R" in *BOOT_IMAGE=/zImage*) say "$1: the kernel was loaded by GRUB";; *) fail "$1: the kernel command line does not name GRUB's BOOT_IMAGE: $R";; esac
  fi
}
# monitor <command>: one command to QEMU's monitor
monitor() {
  python3 -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(5); s.connect(sys.argv[1])
time.sleep(0.5); s.sendall((sys.argv[2] + "\n").encode()); time.sleep(0.5)' "$WORK/monitor.sock" "$1" 2>/dev/null
}
# power_off: ACPI's power button, for a guest without the debug shell (after an update the new
# bootfs has the image's own grub.cfg); QEMU ends with its guest, and is stopped when it does not
power_off() {
  monitor system_powerdown
  for _ in $(seq 1 90); do qemu_alive || return 0; sleep 2; done
  say "the guest did not power off within 180 s after the power button; stopping QEMU"
  qemu_stop
}

# the guest shell: one command line at a time over the serial socket, output until the marker.
#
# ONE connection for the whole guest phase. QEMU's socket chardev serves a single client at a
# time and drops on the floor whatever the guest writes while no client is attached, so the
# earlier "connect per command" shape lost a marker as soon as a command took long enough for
# the previous connection to have been closed - and the next call then waited its full timeout
# for a marker that had already gone by (diagnosed 2026-09-07, fixed 2026-09-07). The driver
# below connects once, keeps the connection for every command, and tags each command with its
# own sequence number so a late line from the previous one cannot be mistaken for this one's.
#
# guest_open is lazy and guest_close ends the driver; a guest reboot needs a close (the shell on
# the other side is a new process) and the next guest call reopens.
guest_driver() {
  cat >"$WORK/guest-driver.py" <<'PY'
import re, socket, sys, time

sockpath, logpath = sys.argv[1], sys.argv[2]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1.0)
s.connect(sockpath)
log = open(logpath, "a", buffering=1)
buf = b""


def pump(deadline, marker):
    """Read until marker matches what has arrived, or the deadline passes."""
    global buf
    while time.time() < deadline:
        try:
            d = s.recv(4096)
        except socket.timeout:
            if marker is not None and marker.search(buf):
                return True
            continue
        except OSError:
            return False
        if not d:
            return False
        buf += d
        log.write(d.decode("utf-8", "replace").replace("\r", ""))
        if marker is not None and marker.search(buf):
            return True
    return marker is not None and bool(marker.search(buf))


# The prompt of the shell on the other side, which lands in front of the first line a command
# prints and, when a command prints nothing, in front of the marker itself. systemd's debug shell
# gives "sh-5.2# "; a plain busybox ash gives "# " or "$ ". Stripped rather than used to drop the
# whole line, which is what threw away a one-word answer such as "0" or "active".
PROMPT = re.compile(r"^(?:sh-[\d.]+[#$]|[#$])\s*")


def strip_prompts(line):
    prev = None
    while prev != line:
        prev = line
        line = PROMPT.sub("", line, count=1)
    return line


# let the debug shell settle, and throw away whatever it printed before we attached
pump(time.time() + 2, None)
buf = b""
seq = 0
for line in sys.stdin:
    cmd = line.rstrip("\n")
    if cmd == "__QUIT__":
        break
    seq += 1
    tag = "__OLT%d__" % seq
    # not anchored to the line start: with no output before it the shell's prompt sits on the
    # same line ("sh-5.2# __OLT4__=1"), and a serial line ends "\r\n" so the \r is still here.
    # The echoed command line carries "=$?" rather than digits, so it cannot match by accident.
    marker = re.compile((re.escape(tag) + r"=\d+").encode())
    buf = b""
    try:
        s.sendall(("\n" + cmd + "; echo " + tag + "=$?\n").encode())
        ok = pump(time.time() + 240, marker)
    except OSError as e:
        print("  | (the serial connection is gone: %s)" % e)
        print("[rc=disconnected]")
        print("__END__", flush=True)
        break
    out = []
    for l in buf.decode("utf-8", "replace").replace("\r", "").split("\n"):
        if "echo " + tag in l:  # the command line the shell echoes back
            continue
        l = strip_prompts(l)
        m = re.match("^" + re.escape(tag) + r"=(\d+)$", l.strip())
        if m:
            out.append("[rc=%s]" % m.group(1))
            break
        if l.strip():
            out.append("  | " + l)
    if not ok:
        out.append("  | (no marker within 240 s; the guest shell did not answer)")
        out.append("[rc=timeout]")
    print("\n".join(out))
    print("__END__", flush=True)
PY
}

guest_open() {
  [ -n "${GUEST_PID:-}" ] && return 0
  # a SIGPIPE here would kill the script rather than report a failure
  trap '' PIPE
  guest_driver
  rm -f "$WORK/guest.in" "$WORK/guest.out"
  mkfifo "$WORK/guest.in" "$WORK/guest.out"
  python3 "$WORK/guest-driver.py" "$WORK/serial.sock" "$WORK/serial.log" <"$WORK/guest.in" >"$WORK/guest.out" &
  GUEST_PID=$!
  exec 8>"$WORK/guest.in"
  exec 9<"$WORK/guest.out"
  # systemctl and journalctl page on the debug shell's tty and the listing arrives as escape
  # codes, after which the shell is unusable (seen 2026-09-08 on list-timers): no pager, no colour
  guest 'export SYSTEMD_PAGER=cat PAGER=cat SYSTEMD_COLORS=0 TERM=dumb' >/dev/null
  # HTTP answers long before the boot is over (occulited is Before=lighttpd, the addons and the
  # end-of-boot units come after); every check below assumes a finished boot, so wait for it -
  # "degraded" counts, psplash-start fails here (see above). Up to 8 minutes: hmipserver's JVM
  # under TCG on a loaded runner has taken more than 6 (2026-09-25, load 5 on 8 cores) and its unit
  # allows 7 (TimeoutStartSec=420); a settled boot leaves the loop at once
  guest 'for i in $(seq 1 240); do s=$(systemctl is-system-running 2>/dev/null); case "$s" in starting|initializing) sleep 2;; *) break;; esac; done; echo "system: $s after ${i}x2s"'
}

# boot_checks: the boot settled (running or degraded - psplash-start fails here, see above), and no
# unit failed but the two allowed. A boot that is still "starting" after guest_open's 180 s wait,
# or a failed unit, fails the test - both were printed and passed over before (the second boot of
# 1.0.0-dev.24 and dev.25 sat in "starting" for the whole wait with a failed
# occu-lgw-firmware-update, and the run said OK). What the failed units said is printed: without
# it a failed unit in a VM that is gone a minute later is a name and nothing else.
boot_checks() {
  R=$(guest 'systemctl is-system-running'); case "$R" in *'| running'*|*'| degraded'*) ;; *) fail "$1 did not settle: $R"
    guest 'systemctl list-units --state=activating,deactivating,failed --no-legend --plain --no-pager; systemctl list-jobs --no-legend --no-pager | head -20';; esac
  R=$(guest 'systemctl --failed --no-legend --plain --no-pager | grep -v "^psplash-start.service \|^occu-interface-clock.service " | wc -l'); case "$R" in *'| 0'*) ;; *) fail "$1: failed units (see above)"
    guest 'for u in $(systemctl --failed --no-legend --plain --no-pager | cut -d" " -f1); do echo "== $u"; systemctl show -p Result,ExecMainCode,ExecMainStatus "$u"; journalctl -b -u "$u" --no-pager -n 15 -o cat; systemctl status "$u" --no-pager -n 15 | tail -n 15; done';; esac
}

guest_close() {
  [ -n "${GUEST_PID:-}" ] || return 0
  printf '__QUIT__\n' >&8 2>/dev/null
  exec 8>&-
  wait "$GUEST_PID" 2>/dev/null
  exec 9<&-
  GUEST_PID=
}

# settle_snippet <unit> <seconds>: the guest-side one-liner that waits, up to <seconds>, for <unit>
# to leave "activating", then prints its state, the seconds waited and its Result - one guest call,
# so a start that takes longer than a fixed sleep (hm2mqtt's, still activating 8 s after its
# install on two build rounds, B-279) is judged when it is over, and a failure is still seen at
# once. Read with: case in *'| active after'*) ok. lite-qemu-settle-test.sh runs it against a stub.
settle_snippet() {
  printf 'u=%s; n=0; s=$(systemctl is-active $u); while [ "$s" = activating ] && [ $n -lt %d ]; do sleep 2; n=$((n+2)); s=$(systemctl is-active $u); done; echo "$s after ${n}s, result $(systemctl show -p Result --value $u)"' "$1" "$2"
}

# kill_restart_snippet <unit> <seconds>: the guest-side one-liner that kills <unit>'s main process
# with SIGKILL and waits, up to <seconds>, first for systemd to count the restart (NRestarts goes
# up) and then for the unit to be active again, and prints "restarted=yes" only when it is active
# on a new main PID with one more restart - else "restarted=no" and what it saw. B-334: one fixed
# 8 s sleep met lighttpd still "activating" (NRestarts already 1) twice while Gitea CI loaded the
# runner (dev.4, load 14-19); a quiet runner had it back within 8 s. A daemon that does not come
# back still fails, at the bound. lite-qemu-settle-test.sh runs it against a stub systemctl.
kill_restart_snippet() {
  printf 'u=%s; P=$(systemctl show -p MainPID --value $u); N=$(systemctl show -p NRestarts --value $u); [ "${P:-0}" != 0 ] && kill -9 "$P"; n=0; while [ "$(systemctl show -p NRestarts --value $u)" = "$N" ] && [ $n -lt %d ]; do sleep 1; n=$((n+1)); done; s=$(systemctl is-active $u); while [ "$s" != active ] && [ "$s" != failed ] && [ $n -lt %d ]; do sleep 1; n=$((n+1)); s=$(systemctl is-active $u); done; M=$(systemctl show -p NRestarts --value $u); Q=$(systemctl show -p MainPID --value $u); r=no; [ "$s" = active ] && [ "$M" != "$N" ] && [ "${Q:-0}" != 0 ] && [ "$Q" != "$P" ] && r=yes; echo "restarted=$r: $s after ${n}s, restarts $N -> $M, main pid $P -> $Q"' "$1" "$2" "$2"
}

# initscript_restart_snippet <unit> <init script> <daemon process> <seconds>: the guest-side
# one-liner for a hand-invoked "<init script> restart", which the wrapper turns into
# "systemctl restart --no-block <unit>" (B-3). It waits, up to <seconds>, for the unit to be active
# before the restart, then for the restart to be over: the unit active on a new main PID with
# exactly one <daemon process>, and prints "settled=yes" only then. B-334: the old wait took the
# unit's state right after the --no-block call, which was still the old daemon's "active" - it
# said "settled after 0s", and the next check met the restart's "activating". B-317's 30 s bounds
# were too short under a loaded runner. lite-qemu-settle-test.sh runs it against stubs.
initscript_restart_snippet() {
  printf 'u=%s; i=0; while [ $i -lt %d ] && [ "$(systemctl is-active $u)" != active ]; do sleep 1; i=$((i+1)); done; echo "active before the restart after ${i}s: $(systemctl show -p ActiveState -p SubState -p NRestarts --value $u | tr "\\n" " ")"; P=$(systemctl show -p MainPID --value $u); %s restart; i=0; while [ $i -lt %d ]; do s=$(systemctl is-active $u); Q=$(systemctl show -p MainPID --value $u); a=$(pgrep -x %s | wc -l); [ "$s" = active ] && [ "${Q:-0}" != 0 ] && [ "$Q" != "$P" ] && [ "$a" = 1 ] && break; sleep 1; i=$((i+1)); done; r=no; [ "$s" = active ] && [ "${Q:-0}" != 0 ] && [ "$Q" != "$P" ] && [ "$a" = 1 ] && r=yes; echo "settled=$r: $s, main pid $P -> $Q, $a %s, after ${i}s"' "$1" "$4" "$2" "$4" "$3" "$3"
}

# page_wait <url> <cookie> <seconds>: the host-side wait for an addon's page behind the gate. An
# addon's unit is active once its rc.d start has returned (Type=oneshot, RemainAfterExit), while a
# Node.js server behind lighttpd's proxy listens some seconds later, and the proxy answers 503
# (502 for a refused connection) until then - hmm's did in dev.34's run, probed 2 s after its
# install, where the green runs had probed 8 s after (B-287). Polls every 2 s while the answer is
# 502 or 503, up to <seconds>, and prints the code and the seconds waited: "200 after 4s". Read
# with ${R%% *}. lite-qemu-settle-test.sh runs it against a stub curl.
page_wait() {
  pw_n=0
  pw_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H 'Accept: text/html' -b "$2" "$1")
  while { [ "$pw_code" = 503 ] || [ "$pw_code" = 502 ]; } && [ "$pw_n" -lt "$3" ]; do
    sleep 2; pw_n=$((pw_n+2))
    pw_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H 'Accept: text/html' -b "$2" "$1")
  done
  echo "$pw_code after ${pw_n}s"
}

# github_budget <need> <max wait s>: the addon e2e's GitHub budget (task 310). The guest reaches
# GitHub through QEMU's user network, i.e. from this host's public address, and occulited asks
# GitHub's API unauthenticated: 60 calls an hour per address, shared with everything else behind
# it (dev.35 and dev.36 lost the e2e to "GitHub rate limit" after a few runs in an hour). So read
# the address's budget here first (GET /rate_limit costs nothing); with fewer than <need> calls left,
# wait for the reset if it comes within <max wait s> - watching QEMU meanwhile - else fail and say
# when it resets. An unreadable answer goes on (the install then says what GitHub says). Prints one
# line; returns 1 only for "the reset is too far". LITE_QEMU_GITHUB_API overrides the API base.
github_budget() {
  gb_api=${LITE_QEMU_GITHUB_API:-https://api.github.com}
  gb_n=0
  while :; do
    gb=$(curl -s --max-time 15 -H 'Accept: application/vnd.github+json' "$gb_api/rate_limit" | python3 -c '
import json, sys, time
try:
    r = json.load(sys.stdin)["resources"]["core"]
    print(int(r["remaining"]), max(0, int(r["reset"]) - int(time.time())), int(r["limit"]))
except Exception:
    print("? 0 0")' 2>/dev/null)
    gb_rem=${gb%% *}; gb_rest=${gb#* }; gb_reset=${gb_rest%% *}; gb_limit=${gb_rest#* }
    case "$gb_rem" in ''|*[!0-9]*) echo "GitHub's rate limit could not be read; going on"; return 0;; esac
    if [ "$gb_rem" -ge "$1" ]; then
      [ "$gb_n" = 0 ] && echo "GitHub: $gb_rem of $gb_limit calls left (need $1)" || echo "GitHub: $gb_rem of $gb_limit calls left after waiting ${gb_n}s"
      return 0
    fi
    if [ "$gb_n" -gt 0 ] && [ "$gb_n" -ge "$2" ]; then
      echo "GitHub: still $gb_rem of $gb_limit calls left after waiting ${gb_n}s (need $1)"; return 1
    fi
    if [ $((gb_n + gb_reset)) -gt "$2" ]; then
      echo "GitHub: $gb_rem of $gb_limit calls left (need $1), the reset is in ${gb_reset}s - more than the ${2}s this run may wait"; return 1
    fi
    echo "GitHub: $gb_rem of $gb_limit calls left (need $1); waiting ${gb_reset}s for the reset" >&2
    gb_end=$((gb_n + gb_reset + 15))
    while [ "$gb_n" -lt "$gb_end" ]; do qemu_check "while waiting for GitHub's rate limit"; sleep 30; gb_n=$((gb_n + 30)); done
  done
}

guest() {
  # QEMU gone: no new driver against its dead socket - the caller's check fails on the silence
  if ! qemu_alive; then say "guest: QEMU's process is gone"; GUEST_PID=; return 1; fi
  guest_open
  printf '%s\n' "$1" >&8
  while IFS= read -r __l <&9; do
    [ "$__l" = "__END__" ] && return 0
    printf '%s\n' "$__l"
  done
  # the driver died: say so rather than return silence that a case statement reads as a pass
  say "guest: the serial driver stopped answering"
  GUEST_PID=
  return 1
}

# the fresh-image probe (LITE_QEMU_FRESH=1, see the top): what a fresh image reaches out to by
# itself in its first ten minutes. It prints and judges nothing; the build round reads it.
fresh_probe() {
  say "FRESH: occulited.json at the first start"; guest 'uptime; cat /usr/local/etc/occulite/occulited.json; echo; ls -l --time-style=+%T /usr/local/etc/occulite/ | grep -iE "catalog|firmware|update|release"'
  for m in 1 2 3 4 5 6 7 8 9 10; do
    qemu_check "during the fresh probe"
    say "FRESH: minute $m: TCP to ports 443/80 (remote, state) every 10 s"; guest 'for i in 1 2 3 4 5 6; do awk "NR>1 && (\$3 ~ /:01BB\$/ || \$3 ~ /:0050\$/) {print \$3, \$4}" /proc/net/tcp; sleep 10; done | sort | uniq -c; uptime'
  done
  say "FRESH: occulited's journal lines about the outside"; guest 'journalctl -u occulited -b --no-pager -o cat | grep -iE "catalog|firmware|update|release|github|outbound|config:|ssdp" | head -30; ls -l --time-style=+%T /usr/local/etc/occulite/ | grep -iE "catalog|firmware|update|release"'
  say "FRESH: done"
}

qemu_start() {
  FW_ARGS=()
  if [ "$FIRMWARE" = uefi ]; then
    # the firmware's variables are the VM's own: a copy, kept across this run's boots
    [ -f "$WORK/ovmf-vars.fd" ] || cp "$OVMF_VARS" "$WORK/ovmf-vars.fd" || { say "cannot copy $OVMF_VARS"; exit 1; }
    FW_ARGS=(-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" -drive "if=pflash,format=raw,file=$WORK/ovmf-vars.fd")
  fi
  KERNEL_ARGS=()
  if [ "$BOOTVIA" = kernel ]; then
    KERNEL_ARGS=(-kernel "$WORK/zImage"
      -append "root=PARTUUID=deedbeef-02 rootfstype=ext4 fsck.repair=yes console=tty2 ro rootwait rootdelay=5 init_on_alloc=1 init_on_free=1 slab_nomerge net.ifnames=0 $TEST_CMDLINE")
  fi
  rm -f "$WORK/qemu.pid"
  if [ "$SYSTEMD" = 1 ]; then
    qemu-system-x86_64 -m 2048 -smp 2 -cpu qemu64 "${FW_ARGS[@]}" "${KERNEL_ARGS[@]}" \
      -drive file="$WORK/disk.img",format=raw,if=virtio \
      -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:80 -device virtio-net-pci,netdev=n0 \
      -display none -chardev socket,id=ser0,path="$WORK/serial.sock",server=on,wait=off -serial chardev:ser0 \
      -monitor "unix:$WORK/monitor.sock,server=on,wait=off" \
      -pidfile "$WORK/qemu.pid" -daemonize >/dev/null 2>&1 || { say "qemu failed to start"; exit 1; }
  else
    qemu-system-x86_64 -m 2048 -smp 2 -cpu qemu64 "${FW_ARGS[@]}" \
      -drive file="$WORK/disk.img",format=raw,if=virtio \
      -netdev user,id=n0,hostfwd=tcp:127.0.0.1:$PORT-:80 -device virtio-net-pci,netdev=n0 \
      -display none -serial file:"$WORK/serial.log" -pidfile "$WORK/qemu.pid" -daemonize >/dev/null 2>&1 || { say "qemu failed to start"; exit 1; }
  fi
  say "$1: booting ($FIRMWARE, TCG, ${WORK}/disk.img is a copy; nothing is written to $IMG)"
}
boot() {
  qemu_start "$1"
  wait_http "$1"
}

wait_http() {
  T0=$(date +%s)
  for _ in $(seq 1 180); do
    qemu_check "$1: while waiting for HTTP"
    H=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/api/system/v1/health" 2>/dev/null)
    case "$H" in *'"ok":true'*) break;; esac
    sleep 5
  done
  say "$1: after $(( $(date +%s) - T0 )) s: ${H:-no answer}"
  case "$H" in *'"ok":true'*) ;; *) fail "occulited did not answer through lighttpd";; esac
}

# http_gone: wait until the system's health endpoint stops answering (the guest is going down)
http_gone() {
  for _ in $(seq 1 90); do
    qemu_check "$1"
    curl -s --max-time 2 "http://127.0.0.1:$PORT/api/system/v1/health" 2>/dev/null | grep -q '"ok":true' || return 0
    sleep 2
  done
  return 1
}
# recovery_wait <seconds>: wait for the recovery system's page - its start page, or the running
# update's output it shows instead. Prints which one.
recovery_wait() {
  rw_end=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$rw_end" ]; do
    qemu_check "while waiting for the recovery system"
    rw=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null | head -c 4096 | tr -d '\0')
    case "$rw" in
      *'CCU Recovery System'*) echo page; return 0;;
      *'Displaying running firmware update output'*) echo update; return 0;;
    esac
    sleep 5
  done
  return 1
}
# recovery_phase: the marker GRUB looks for, a reboot, and the recovery system must answer. It
# removes the marker when it mounts the userfs, which is read from the disk copy afterwards.
recovery_phase() {
  say "recovery: .recoveryMode on the userfs and a reboot - GRUB must start the recovery system ($FIRMWARE)"
  guest 'touch /usr/local/.recoveryMode && sync && systemctl --no-block reboot' >/dev/null
  guest_close
  http_gone "during the reboot into the recovery system" || { fail "the system did not go down for the reboot into the recovery system"; return; }
  T0=$(date +%s)
  R=$(recovery_wait 600) || { fail "the recovery system did not answer within 600 s (GRUB did not start it, or it did not boot under $FIRMWARE)"; return; }
  say "recovery: its page answers after $(( $(date +%s) - T0 )) s ($R)"
  sleep 20  # S11MountAll removes the marker early; the page comes later, this is slack
  qemu_stop
  rp_off=$(part_offset "$WORK/disk.img" 3)
  if ! "$DEBUGFS" -R 'stat /etc' "$WORK/disk.img?offset=$rp_off" 2>/dev/null | grep -q '^Inode:'; then
    fail "the disk copy's userfs cannot be read after the recovery system ran (debugfs, partition 3)"
  elif "$DEBUGFS" -R 'stat /.recoveryMode' "$WORK/disk.img?offset=$rp_off" 2>/dev/null | grep -q '^Inode:'; then
    fail "the recovery system left /usr/local/.recoveryMode behind: it did not mount the userfs"
  else say "recovery: it removed .recoveryMode from the userfs"; fi
}
# update_phase: the release zip through occulited's own command and the recovery system, back as
# the zip's version under the same firmware; then, when asked, the same disk under the other one
update_phase() {
  up_name=$(basename "$UPDATE_ZIP")
  up_ver=${LITE_QEMU_UPDATE_VERSION:-$(printf '%s\n' "$up_name" | sed -n 's/^openccu-lite-x86_64-ova-\(.*\)\.zip$/\1/p')}
  [ -n "$up_ver" ] || { fail "LITE_QEMU_UPDATE: no version in the name $up_name (openccu-lite-x86_64-ova-<version>.zip), and no LITE_QEMU_UPDATE_VERSION"; return; }
  up_port=$((PORT + 1))
  say "update: $up_name ($(du -h "$UPDATE_ZIP" | cut -f1)) to the guest, from this host's port $up_port"
  ( cd "$(dirname "$UPDATE_ZIP")" && exec python3 -m http.server --bind 127.0.0.1 "$up_port" >/dev/null 2>&1 ) &
  UP_HTTP=$!
  for _ in $(seq 1 20); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$up_port/" && break; sleep 1; done
  R=$(guest "df -m /usr/local | tail -n 1; wget -q -O /usr/local/tmp/$up_name http://10.0.2.2:$up_port/$up_name && echo size=\$(wc -c </usr/local/tmp/$up_name)")
  kill "$UP_HTTP" 2>/dev/null; UP_HTTP=
  case "$R" in *"| size=$(stat -c %s "$UPDATE_ZIP")"*) ;; *) fail "the guest did not fetch the update: $R"; return;; esac
  say "update: occulited update install --file (no backup: a fresh system) - it stages the file, arms the recovery system and reboots"
  guest "occulited update install --file /usr/local/tmp/$up_name --yes --no-backup >/usr/local/lite-qemu-update.log 2>&1 & echo started" >/dev/null
  for _ in $(seq 1 60); do
    R=$(curl -s --max-time 2 "http://127.0.0.1:$PORT/api/system/v1/health" 2>/dev/null)
    case "$R" in *'"ok":true'*) sleep 5;; *) break;; esac
  done
  case "$R" in *'"ok":true'*) fail "the system did not reboot for the update within 5 minutes: $(guest 'tail -n 5 /usr/local/lite-qemu-update.log')"; return;; esac
  guest_close
  T0=$(date +%s)
  R=$(recovery_wait 600) || { fail "the recovery system did not answer within 600 s after the update's reboot (under $FIRMWARE)"; return; }
  say "update: the recovery system answers after $(( $(date +%s) - T0 )) s ($R); it installs and reboots"
  # the flash is 2 GB through dd under TCG, then the first boot of the new system
  H=
  for _ in $(seq 1 480); do
    qemu_check "during the update"
    H=$(curl -s --max-time 3 "http://127.0.0.1:$PORT/api/system/v1/health" 2>/dev/null)
    case "$H" in *'"ok":true'*) break;; esac
    sleep 5
  done
  say "update: after $(( $(date +%s) - T0 )) s: ${H:-no answer from the updated system}"
  case "$H" in *'"ok":true'*"\"release\":\"$up_ver\""*) ;; *) fail "the system did not come back as $up_ver after the update"
    curl -s --max-time 5 "http://127.0.0.1:$PORT/" 2>/dev/null | head -c 2000 | sed 's/<br\/>/\n/g' | tail -n 15 | sed 's/^/  | /'; return;; esac
  # the new bootfs has the image's own grub.cfg: no debug shell. Off by the power button, the
  # test's arguments in again, and the checks on the next boot.
  sleep 60
  power_off
  has_efi_loader && say "update: the new bootfs holds EFI/BOOT/BOOTX64.EFI" || fail "after the update bootfs has no EFI/BOOT/BOOTX64.EFI"
  grub_patch
  if [ "${LITE_QEMU_SWITCH_FIRMWARE:-0}" = 1 ]; then
    case "$FIRMWARE" in bios) FIRMWARE=uefi;; *) FIRMWARE=bios;; esac
    say "update: the updated disk under the other firmware, $FIRMWARE"
  fi
  boot "boot after the update"
  guest_open
  firmware_check "boot after the update"
  R=$(guest 'echo "updated: $(grep -E "^(LITE|VERSION)=" /VERSION | tr "\n" " ") bootfs: $(ls /boot/EFI/BOOT/ | tr "\n" " ")"'); say "update: $(printf '%s\n' "$R" | grep -o 'updated: VERSION.*' | tail -n 1)"
  case "$R" in *"LITE=$up_ver"*) ;; *) fail "/VERSION of the updated system does not say LITE=$up_ver";; esac
  boot_checks "boot after the update"
}

# the first-boot race test (LITE_QEMU_FIRSTBOOT_RUNS, B-368; see the top)
firstboot_race() {
  fr_n=$1; fr_bad=0; fr_race=0
  [ "$SYSTEMD" = 1 ] || { say "FAIL: LITE_QEMU_FIRSTBOOT_RUNS needs a systemd image"; exit 1; }
  EVID_DONE=1  # each run is judged here; the evidence of the last disk copy would say nothing more
  for fr_i in $(seq 1 "$fr_n"); do
    if [ "$fr_i" -gt 1 ]; then
      rm -f "$WORK/disk.img" "$WORK/ovmf-vars.fd" "$WORK/serial.log"
      cp --sparse=always "$IMG" "$WORK/disk.img" && truncate -s "+${LITE_QEMU_DISK_GROW:-2G}" "$WORK/disk.img" || { say "cannot copy $IMG into $WORK"; exit 1; }
      [ "$BOOTVIA" = disk ] && grub_patch
    fi
    fr_t0=$(date +%s)
    qemu_start "first boot $fr_i/$fr_n"
    # lighttpd answering at all (503 without occulited) means the debug shell is long up
    fr_code=000
    for _ in $(seq 1 120); do
      qemu_check "first boot $fr_i: while waiting for HTTP"
      fr_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/" 2>/dev/null)
      [ "$fr_code" != 000 ] && break
      sleep 5
    done
    [ "$fr_code" != 000 ] || { fail "first boot $fr_i: lighttpd did not answer within 10 minutes"; fr_bad=$((fr_bad+1)); guest_close; qemu_stop; continue; }
    guest_open
    # occulited is Type=notify; give a start under way its time
    R=$(guest 'for i in $(seq 1 60); do [ "$(systemctl is-active occulited)" = activating ] || break; sleep 2; done; echo "occ=$(systemctl is-active occulited) helper=$(systemctl is-active occulited-helper) clock=$(systemctl is-active occu-clock-save) local=$(mountpoint -q /usr/local && echo mounted || echo missing) resize=$(journalctl -b -o cat -u occu-userfs-resize | grep -c resizepart) reset=$(journalctl -b -o cat -u occu-factory-reset | grep -c "cleared, OK") sdumount=$(journalctl -b -o cat _PID=1 | grep -c "^Unmounting /usr/local") fsckstop=$(journalctl -b -o cat _PID=1 | grep -c "^Stopped File System Check") end"')
    fr_line=$(printf '%s\n' "$R" | grep -o 'occ=.* end' | tail -n 1)
    fr_ok=1; fr_hit=0
    case "$fr_line" in *'occ=active helper=active clock=active local=mounted resize=1 reset=1 '*) ;; *) fr_ok=0;; esac
    case "$fr_line" in *'sdumount=0 fsckstop=0 end') ;; *) fr_hit=1;; esac
    say "first boot $fr_i/$fr_n after $(( $(date +%s) - fr_t0 )) s: ${fr_line:-no answer from the guest shell}"
    if [ "$fr_hit" = 1 ]; then fr_race=$((fr_race+1)); say "first boot $fr_i: systemd stopped the userfs during the boot (the race)"; fi
    if [ "$fr_ok" = 0 ]; then fr_bad=$((fr_bad+1)); say "first boot $fr_i: occulited did not come up, or the resize and factory reset did not both run"; fi
    if [ "$fr_hit" = 1 ] || [ "$fr_ok" = 0 ]; then
      guest 'systemctl is-system-running; systemctl --failed --no-legend --plain --no-pager; journalctl -b --no-pager -o short-monotonic | grep -E "S0[34]Check|Unmounting /usr/local|usr-local.mount|File System Check|Stopping|Stopped|occulited" | head -40'
    fi
    guest_close
    qemu_stop
  done
  say "first boots: $fr_n, the race met in $fr_race, occulited missing (or the path not taken) in $fr_bad ($FIRMWARE, boot via $BOOTVIA)"
  if [ "$fr_race" != 0 ] || [ "$fr_bad" != 0 ]; then FAILED=1; exit 1; fi
  say "OK"; exit 0
}
[ -z "${LITE_QEMU_FIRSTBOOT_RUNS:-}" ] || firstboot_race "$LITE_QEMU_FIRSTBOOT_RUNS"

boot "boot 1"
# the HTTP checks the Docker boot test of the dropped OCI product made (task 142, D-94): a fresh
# image asks for its first account, serves the shell, and the addon gate sends a browser without a
# session to the login page and answers an API caller 401
S=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/api/auth/v1/state"); say "auth state: $S"
case "$S" in *'"setup_required":true'*) ;; *) fail "the auth state of a fresh image does not ask for the first account";; esac
curl -s --max-time 5 "http://127.0.0.1:$PORT/" | grep -q '<div id="app">' || fail "the shell is not served at /"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Accept: text/html' "http://127.0.0.1:$PORT/addons/nothing/"); say "/addons/nothing/ as a browser -> $code"
[ "$code" = 302 ] || fail "the addon gate did not redirect a browser (got $code)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -H 'Accept: application/json' "http://127.0.0.1:$PORT/addons/nothing/"); say "/addons/nothing/ as an API caller -> $code"
[ "$code" = 401 ] || fail "the addon gate did not answer 401 to an API caller (got $code)"

if [ "$SYSTEMD" = 1 ] && [ "$FAILED" = 0 ]; then
  # open the driver here, in the script's own shell. Almost every guest call below is inside
  # $( ), which is a subshell: if the first call of a phase were one of those, the driver, its
  # fifos and GUEST_PID would be created and lost inside it, and the next call would start a
  # second driver against a chardev that serves one client at a time.
  guest_open
  firmware_check "boot 1"
  if [ "${LITE_QEMU_FRESH:-0}" = 1 ]; then fresh_probe; qemu_check "during the fresh probe"; say "OK (fresh probe)"; exit 0; fi
  # psplash-start.service (buildroot's, not ours) fails here because headless QEMU has no
  # framebuffer; on a box or a VM with a display it does not. occu-interface-clock.service is
  # skipped without rfd since task 129 (B-142); its old failure stays tolerated for older images.
  # --no-pager: systemctl pages on the debug shell's tty and the listing came out as escape codes.
  # occulited task 147: a VM without radio on HmIP Automatic - hmipserver runs HMIPServer.jar, which
  # cannot start without its module, so the prep step refuses it with the known-fatal marker
  # no-module and the unit is not restarted; HMServer.jar runs only with HmIP set to none, never as a
  # fallback. Then the choice none is written as the Interfaces page writes it, the radio stack runs
  # again, and hmipserver comes up as HMServer.jar with the virtual devices - what the rest of this
  # run (the crash test, the unit override, boot 2) checks. The end of the run sets it back.
  say "guest: HmIP on Automatic without a module (occulited task 147)"
  R=$(guest 'echo "fatal=$(grep -c no-module /run/occulite/radio/hmipserver.fatal 2>/dev/null) state=$(systemctl is-active hmipserver) end"')
  case "$R" in *'fatal=1 state='*) case "$R" in *'state=active'*) fail "hmipserver ran without an HmIP module on Automatic (task 147: no fallback to HMServer.jar): $R";; esac;; *) fail "hmipserver without an HmIP module must be refused with the no-module marker (task 147): $R";; esac
  say "guest: HmIP set to none, the radio stack again"
  guest 'H=/usr/local/etc/config/crRFD/hmip_user.conf; mkdir -p ${H%/*}; touch $H; sed -i "/^occulite.hmip.adapter=/d" $H; echo occulite.hmip.adapter=none >>$H; systemctl restart occu-init-rf-hardware.service; systemctl reset-failed hmipserver.service; systemctl start --no-block hmipserver.service; echo restarted' >/dev/null
  for _ in 1 2 3 4 5 6 7; do
    R=$(guest 'for i in $(seq 1 12); do [ "$(systemctl is-active hmipserver)" = active ] && break; sleep 5; done; systemctl is-active hmipserver')
    case "$R" in *'| active'*) break;; esac
  done
  R=$(guest 'echo "state=$(systemctl is-active hmipserver) class=$(sed -n "s/^HMIP_CLASS=//p" /run/occulite/radio/hmipserver.env) fatal=$(test -e /run/occulite/radio/hmipserver.fatal && echo y || echo n) crrfd=$(test -e /var/etc/crRFD.conf && echo y || echo n) end"')
  case "$R" in *'state=active class=de.eq3.ccu.server.HMServer fatal=n crrfd=n end'*) ;; *) fail "with HmIP none hmipserver must run HMServer.jar (task 147): $R";; esac
  say "guest: system state"; guest 'systemctl is-system-running; systemctl --failed --no-legend --plain --no-pager'
  boot_checks "boot 1"
  # B-321: the evidence path on demand - the JVM's own crash handling (hs_err, then abort and core)
  if [ "${LITE_QEMU_CRASH_TEST:-}" = hmipserver ]; then
    say "guest: LITE_QEMU_CRASH_TEST - a SIGSEGV to hmipserver's JVM; this run must fail and keep its evidence"
    guest 'u=hmipserver.service; P=$(systemctl show -p MainPID --value $u); N=$(systemctl show -p NRestarts --value $u); kill -SEGV $P; n=0; while [ "$(systemctl show -p NRestarts --value $u)" = "$N" ] && [ $n -lt 220 ]; do sleep 2; n=$((n+2)); done; echo "pid $P crashed, restarts $N -> $(systemctl show -p NRestarts --value $u) after ${n}s"; ls -l /var/hmipserver /usr/local/lite-qemu-core.* 2>&1 | grep -E "hs_err|core"'
  fi
  say "guest: boot time"; guest 'journalctl -b --no-pager -o short-monotonic | grep -m1 "Startup finished"; journalctl -b -u occu-leds.service --no-pager -o short-monotonic | grep -m1 "booted, OK"'
  say "guest: the lite units"; guest 'systemctl list-units --all --no-legend --plain "occu-*" "addon*" addons.target occulited.service lighttpd.service chrony.service sshd.service hs485d.service multimacd.service rfd.service hmipserver.service crond.service ca-certificates.service qemu-guest-agent.service'
  say "guest: timers"; guest 'systemctl list-timers --all --no-legend --plain "occu-*"'
  say "guest: lighttpd as a tracked daemon"; guest 'systemctl status lighttpd.service --no-pager -n0 | sed -n 1,12p'
  # B-3: the unit has to follow the daemon. RemainAfterExit on a daemon unit is the bug.
  say "guest: no daemon unit keeps RemainAfterExit"; guest 'for u in lighttpd sshd chrony rfd hs485d hmipserver multimacd crond; do printf "%s %s %s\n" "$u" "$(systemctl show -p RemainAfterExit --value $u.service)" "$(systemctl show -p MainPID --value $u.service)"; done'
  R=$(guest 'for u in lighttpd sshd chrony rfd hs485d hmipserver multimacd crond; do systemctl show -p RemainAfterExit --value $u.service; done | grep -c yes'); case "$R" in *'| 0'*) ;; *) fail "a daemon unit still has RemainAfterExit=yes (B-3)";; esac
  # every other check here fails closed; this one used to pass on a timeout or an empty answer
  R=$(guest 'systemctl show -p MainPID --value lighttpd.service'); case "$R" in *'| '[1-9]*) ;; *) fail "lighttpd.service has no main PID, or the guest did not answer (B-3): $R";; esac
  # B-334: no fixed sleep - the restart is waited for (up to 90 s under TCG on a loaded runner)
  say "guest: killing lighttpd - the unit must notice and restart it"
  R=$(guest "$(kill_restart_snippet lighttpd.service 90)"); printf '%s\n' "$R"
  case "$R" in *'| restarted=yes'*) ;; *) fail "lighttpd.service did not come back after its daemon was killed (B-3)";; esac
  wait_http "after killing lighttpd"
  # B-3: an init script called by hand goes to systemctl, not around it
  # B-317: no fixed sleeps. Under runner load the restart came while lighttpd was still in its
  # restart backoff from the kill above, and 6 s were not enough for it to come back: the restart
  # waits for the unit to be settled and active, and the checks wait for it to be active again on
  # a new main PID with exactly one lighttpd-angel - up to 90 s each since B-334, whose loaded runs
  # outlasted 30 s (initscript_restart_snippet). Each wait says how long it took.
  say "guest: the init-script wrapper"; guest 'ls -l /etc/init.d/S50lighttpd /etc/init.d/S50lighttpd.script'
  R=$(guest "$(initscript_restart_snippet lighttpd.service /etc/init.d/S50lighttpd lighttpd-angel 90)"); printf '%s\n' "$R"
  case "$R" in *'| settled=yes'*) ;; *) fail "a hand-invoked S50lighttpd restart did not settle: lighttpd.service active on a new main PID with one lighttpd-angel (B-3, B-334)";; esac
  guest 'systemctl show -p ControlGroup --value lighttpd.service; pgrep -x lighttpd-angel | wc -l'
  R=$(guest 'pgrep -x lighttpd-angel | wc -l'); case "$R" in *'| 1'*) ;; *) fail "a hand-invoked S50lighttpd restart left the daemon outside its unit (B-3)";; esac
  R=$(guest 'systemctl is-active lighttpd.service'); case "$R" in *'| active'*) ;; *) fail "lighttpd.service not active after a hand-invoked restart";; esac
  # B-5: the end-of-boot hint
  say "guest: the end-of-boot hint"; guest 'cat /run/issue; ls -l /etc/issue'
  R=$(guest 'grep -c "is up" /run/issue'); case "$R" in *'| 1'*) ;; *) fail "/run/issue has no end-of-boot hint (B-5)";; esac
  say "guest: machine id and journal on the userfs"; guest 'cat /etc/machine-id; cat /usr/local/etc/machine-id; cat /var/board_serial 2>/dev/null; echo; grep " /var/log/journal " /proc/mounts; ls /usr/local/var/log/journal; journalctl --disk-usage; journalctl --list-boots --no-pager'
  # D-41: the ID is derived from the board serial and stored on the userfs on the first boot
  R=$(guest 'test "$(cat /etc/machine-id)" = "$(cat /usr/local/etc/machine-id)" && echo same || echo differs'); case "$R" in *'| same'*) ;; *) fail "the running machine ID is not the one stored on the userfs (D-41)";; esac
  say "guest: the watchdog is PID 1's"; guest 'systemctl show -p RuntimeWatchdogUSec --value; ls -l /dev/watchdog 2>&1 | head -1; systemctl list-units --all --no-legend --plain occu-watchdog-marker.service'
  say "guest: memory and processes"; guest 'free -m; ps -o pid,rss,comm | sort -k2 -n -r | head -12'
  # no ReGaHss in a lite image (D-1), and the tclrega shim still loads for the Tcl scripts
  R=$(guest 'pidof ReGaHss >/dev/null && echo rega-running || echo no-rega'); case "$R" in *'| no-rega'*) ;; *) fail "ReGaHss is running - this is not a lite image";; esac
  R=$(guest 'echo "load tclrega.so" | tclsh && echo shim-ok'); case "$R" in *'| shim-ok'*) ;; *) fail "tclrega.so does not load";; esac
  say "guest: addon generator round trip"; guest 'mkdir -p /usr/local/etc/config/rc.d && printf "#!/bin/sh\ncase \$1 in start) sleep 100000 & echo started;; stop) echo stopped;; esac\n" >/usr/local/etc/config/rc.d/litetest && chmod +x /usr/local/etc/config/rc.d/litetest && systemctl daemon-reload && systemctl start addons.target && systemctl status addon-litetest.service --no-pager -n3'
  R=$(guest 'systemctl is-active addon-litetest.service'); case "$R" in *'| active'*) ;; *) fail "addon-litetest.service not active after daemon-reload";; esac
  R=$(guest 'systemctl stop addon-litetest.service; pgrep -f "sleep 100000" | wc -l'); case "$R" in *'| 0'*) ;; *) fail "the addon's sleeper survived systemctl stop";; esac
  # task 27.4 / B-26: what the Services page stores on the userfs must be in force at the NEXT
  # boot before the units start - occu-unit-overrides.service, not occulited, does that. Seed an
  # override on hmipserver (the one interface daemon that runs on a VM without radio: HMServer.jar
  # with HmIP set to none above; rfd is skipped by its marker condition since task 129) and a switch-off of
  # crond the way occulited writes them; boot 2 checks.
  # task 14: the addon install e2e - the D-19 set from the catalogue (homematic-manager, RedMatic,
  # ccu-addon-mosquitto, hm2mqtt.js), each installed through the API as the Addons page does, its
  # unit active, the rc.d script's info, the session gate on its pages (a browser without a session
  # is sent to the login, one with the session gets through), uninstalled, and nothing left behind.
  # The guest reaches GitHub through QEMU's user network; a set that cannot be fetched fails the
  # run - that is the verdict the catalogue's flags rest on. LITE_QEMU_ADDONS="" skips the phase,
  # LITE_QEMU_ADDONS="mosquitto" narrows it. The synthetic litetest addon above stays the control.
  ADDONS=${LITE_QEMU_ADDONS-mosquitto hm2mqtt hmm redmatic}
  # the first account's name and password; relogin uses them again
  QU=litetest QP=lite-qemu-test-2026
  # B-354: a new session for the account. A wait for GitHub's quota can take the hour its reset is
  # away, and the session from the setup idles out meanwhile: beta.9's first run then had its install
  # refused with 401. So the run logs in again after such a wait, and once when the API answers 401.
  relogin() {
    curl -s --max-time 10 -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$QU\",\"password\":\"$QP\"}" "$BASE/api/auth/v1/login" >"$WORK/login.json"
    rl_sid=$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' "$WORK/login.json")
    if [ -z "$rl_sid" ]; then fail "no session from a new login ($1): $(cat "$WORK/login.json")"; return 1; fi
    SID=$rl_sid
    AUTH="Authorization: Bearer $SID"
    say "addons: logged in again ($1)"
  }
  if [ -n "$ADDONS" ] && [ "$FAILED" = 0 ]; then
    BASE="http://127.0.0.1:$PORT"
    # task 310: the refresh asks GitHub twice per catalogue entry (the stars, the releases), the
    # installs once per addon; 30 leaves room. LITE_QEMU_GITHUB_NEED/_WAIT override.
    R=$(github_budget "${LITE_QEMU_GITHUB_NEED:-30}" "${LITE_QEMU_GITHUB_WAIT:-3900}") || fail "the addon e2e cannot run: $R"
    say "addons: $R"
    GB_BEFORE=$(printf '%s\n' "$R" | sed -n 's/^GitHub: \([0-9]*\) of .*/\1/p')
  fi
  if [ -n "$ADDONS" ] && [ "$FAILED" = 0 ]; then
    say "addons: the first account and a session"
    curl -s --max-time 10 -X POST -H 'Content-Type: application/json' -d "{\"username\":\"$QU\",\"password\":\"$QP\"}" "$BASE/api/auth/v1/setup" >"$WORK/setup.json"
    SID=$(sed -n 's/.*"sid":"\([^"]*\)".*/\1/p' "$WORK/setup.json")
    [ -n "$SID" ] || fail "no session from the first account's setup: $(cat "$WORK/setup.json")"
    AUTH="Authorization: Bearer $SID"
    code=$(curl -s -o "$WORK/refresh.json" -w '%{http_code}' --max-time 300 -X POST -H "$AUTH" "$BASE/api/system/v1/catalog/refresh"); say "addons: catalogue refresh -> $code"
    [ "$code" = 200 ] || fail "the catalogue could not be refreshed (GitHub not reachable from the guest?): $(cat "$WORK/refresh.json")"
    # the refresh answers 200 with per-entry errors kept inside (a manifest that could not be
    # fetched - GitHub's unauthenticated API limit is 60 calls an hour per address, and four runs
    # in an hour from one runner reached it on 2026-09-26); an addon without its manifest is
    # "unknown" to the install, so check the catalogue first and say why an entry is missing
    curl -s --max-time 30 -H "$AUTH" "$BASE/api/system/v1/catalog" >"$WORK/catalog.json"
    for id in $ADDONS; do
      grep -q "\"id\":\"$id\"" "$WORK/catalog.json" && continue
      E=$(grep -o '"error":"[^"]*"' "$WORK/catalog.json" | sort -u | tr '\n' ' ' | cut -c1-600)
      if is_quota "$E"; then envfail "$id is not in the catalogue after the refresh: $E"; else fail "$id is not in the catalogue after the refresh; the entries' errors: $E"; fi
    done
    for id in $ADDONS; do
      [ "$FAILED" = 0 ] || break
      qemu_check "before the install of $id"
      # task 376: an install GitHub's quota refuses ("GitHub rate limit, try again in N min") waits
      # for the reset (github_budget, the same cap) and is tried once more; refused again, or with
      # the reset too far, it is the environment's failure, not the image's
      try=1 relogged=""
      while :; do
        say "addons: installing $id from the catalogue${try#1}"
        T0=$(date +%s)
        code=$(curl -s -o "$WORK/install.json" -w '%{http_code}' --max-time 30 -X POST -H "$AUTH" -H 'Content-Type: application/json' -d '{}' "$BASE/api/system/v1/catalog/$id/install")
        P=""
        if [ "$code" = 202 ]; then
          for _ in $(seq 1 300); do
            qemu_check "during the install of $id"
            P=$(curl -s --max-time 10 -H "$AUTH" "$BASE/api/system/v1/catalog/progress")
            case "$P" in *'"phase":"done"'*|*'"phase":"failed"'*) break;; esac
            sleep 5
          done
          say "addons: $id after $(( $(date +%s) - T0 )) s: $(printf '%s' "$P" | sed 's/"result":{.*//' | cut -c1-300)"
          case "$P" in *'"phase":"done"'*) break;; esac
          WHY=$(printf '%s' "$P" | cut -c1-400)
        else
          WHY="not accepted ($code): $(cat "$WORK/install.json")"
        fi
        # a session that idled out: log in again and try once more
        if [ "$code" = 401 ] && [ -z "$relogged" ]; then
          relogged=1
          relogin "the install of $id answered 401" && continue
          break
        fi
        if ! is_quota "$WHY"; then break; fi
        QUOTA_MET=1
        if [ "$try" = 1 ]; then
          R=$(github_budget "${LITE_QEMU_GITHUB_NEED:-30}" "${LITE_QEMU_GITHUB_WAIT:-3900}") && { say "addons: GitHub's quota refused $id; $R - once more"; try=2; relogin "after the wait for GitHub's quota" || break; continue; }
          say "addons: GitHub's quota refused $id: $R"
        fi
        break
      done
      if [ "$code" != 202 ]; then
        if is_quota "$WHY"; then envfail "install of $id $WHY"; else fail "install of $id $WHY"; fi
        continue
      fi
      case "$P" in *'"phase":"done"'*) ;; *) if is_quota "$WHY"; then envfail "$id did not install: $WHY"; else fail "$id did not install: $WHY"; fi; continue;; esac
      A=$(curl -s --max-time 30 -H "$AUTH" "$BASE/api/system/v1/addons")
      case "$A" in *"\"id\":\"$id\""*) ;; *) fail "$id is not in the addon list after the install";; esac
      # the unit may still be activating (a Node.js addon on an emulated CPU): wait for it to settle, up to 60 s
      R=$(guest "$(settle_snippet "addon-$id.service" 60)"); say "addons: addon-$id.service $(printf '%s\n' "$R" | grep -o '[a-z-]* after [0-9]*s, result .*' | tail -n 1)"
      case "$R" in *'| active after'*) ;; *) fail "addon-$id.service is not active after the install: $R";; esac
      say "addons: $id info"; guest "/usr/local/etc/config/rc.d/$id info 2>&1 | head -4"
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H 'Accept: text/html' "$BASE/addons/$id/"); say "addons: /addons/$id/ without a session -> $code"
      [ "$code" = 302 ] || fail "the gate let a browser without a session at /addons/$id/ ($code)"
      # the page behind the gate, once the addon's own server answers (B-287: hmm's proxy said 503
      # when probed 2 s after the install; the wait is page_wait's, up to 60 s)
      R=$(page_wait "$BASE/addons/$id/" "occulite_gate=$SID" 60); code=${R%% *}; say "addons: /addons/$id/ with the session (the gate cookie, task 259) -> $R"
      case "$code" in 302|401|403) fail "the gate refused the session at /addons/$id/ ($code)";; 502|503) fail "the web of $id did not answer behind the gate within 60 s ($code)";; esac
      # hmm and hm2mqtt serve a page at their root: 200, not the gate's 404 for an addon without one
      case "$id" in hmm|hm2mqtt) [ "$code" = 200 ] || fail "/addons/$id/ answered $code, want 200";; esac
      say "addons: uninstalling $id"
      code=$(curl -s -o "$WORK/uninstall.json" -w '%{http_code}' --max-time 300 -X POST -H "$AUTH" "$BASE/api/system/v1/addons/$id/uninstall")
      [ "$code" = 200 ] || fail "uninstall of $id answered $code: $(cat "$WORK/uninstall.json" | cut -c1-300)"
      # what the uninstall must leave: no tree, no rc.d script, no www or config directory, no
      # hm_addons.cfg line, and no unit - the unit goes when its process has stopped and the
      # generator has reloaded, which takes RedMatic (Node-RED) a good many seconds, so poll for it.
      # The marker is built in the guest: the guest echoes the command line back, and a literal
      # "LEFTOVER:" in it would match its own echo.
      R=$(guest "m=LEFT; m=\"\${m}OVER\"; for i in \$(seq 1 30); do n=\$(systemctl list-units --all --plain --no-legend addon-$id.service | wc -l); [ \"\$n\" = 0 ] && break; sleep 2; done; for p in /usr/local/addons/$id /usr/local/etc/config/rc.d/$id /usr/local/etc/config/addons/www/$id /usr/local/etc/config/addons/$id; do [ -e \$p ] && echo \"\$m: \$p\"; done; grep -c '^$id ' /usr/local/etc/config/hm_addons.cfg 2>/dev/null; echo \"unit \$n after \$i\"; [ \"\$n\" = 0 ] || systemctl status addon-$id.service --no-pager -n5 2>&1 | head -12; echo checked")
      case "$R" in *'LEFTOVER:'*) fail "$id left files behind: $R";; esac
      case "$R" in *'| 0'*'| unit 0 after'*'| checked'*) ;; *) fail "$id is still in hm_addons.cfg or its unit is still known: $R";; esac
      A=$(curl -s --max-time 30 -H "$AUTH" "$BASE/api/system/v1/addons")
      case "$A" in *"\"id\":\"$id\""*) fail "$id is still in the addon list after the uninstall";; esac
    done
    # what the e2e cost of the address's budget (others behind the address count too)
    R=$(LITE_QEMU_GITHUB_NEED=0 github_budget 0 0)
    GB_AFTER=$(printf '%s\n' "$R" | sed -n 's/^GitHub: \([0-9]*\) of .*/\1/p')
    if [ -n "${GB_BEFORE:-}" ] && [ -n "$GB_AFTER" ]; then say "addons: GitHub calls used meanwhile: $((GB_BEFORE - GB_AFTER)) ($R)"; else say "addons: $R"; fi
  else
    say "addons: the install e2e is skipped (LITE_QEMU_ADDONS empty or an earlier failure)"
  fi

  say "guest: seeding a unit override and a switched-off unit for boot 2"; guest 'mkdir -p /usr/local/etc/occulite/unit-overrides && printf "[Service]\nEnvironment=OCCULITE_TEST=boot\n" >/usr/local/etc/occulite/unit-overrides/hmipserver.service.conf && printf "{\"masked\":[\"crond.service\"]}\n" >/usr/local/etc/occulite/unit-switch.json && ls -l /usr/local/etc/occulite/unit-overrides /usr/local/etc/occulite/unit-switch.json'
  # task 129 (D-82, D-97), the switch guarantee: a userfs as a CCU3 or OpenCCU leaves it - an
  # rfd.conf with a BidCos LAN gateway (unreachable here) and an InterfacesList.xml with an entry
  # another program added - boots with those connections and no lite setting: rfd runs on the
  # gateway alone (its local section off, no module), the interface list is the template's cut
  # for the hardware (BidCos-RF for the gateway, no HmIP-RF, the foreign entry lost as on OpenCCU).
  say "guest: seeding an OpenCCU-shaped userfs for boot 2 (a LAN gateway in rfd.conf, a foreign interface entry)"
  # The seeded LAN gateway must stay silent (B-229's skip): QEMU's user-mode network answers every
  # ICMP echo it routes through its gateway, a documentation address included (seen on the 1.0.0-dev.26
  # image: 192.0.2.1 "answered", so the firmware step ran into eq3configcmd's timeouts). An unused address
  # on the guest's own link gets no ARP answer, so its ping fails as an unplugged gateway's would.
  # The list is written beside and renamed: occulited watches it and read a half-written file once
  # (2.0.0-beta.4's second run: "could not be parsed ... unexpected EOF", a boot warning).
  guest 'cp /usr/local/etc/config/rfd.conf /usr/local/etc/config/rfd.conf.lite-qemu-test 2>/dev/null; cp /etc/config_templates/rfd.conf /usr/local/etc/config/rfd.conf && printf "\n[Interface 1]\nType = HMLGW2\nSerial Number = KEQ0123456\nEncryption Key = 00000000000000000000000000000000\nIP Address = 10.0.2.200\n\n" >>/usr/local/etc/config/rfd.conf && { grep -v "</interfaces>" /etc/config_templates/InterfacesList.xml; printf "\t<ipc>\n\t \t<name>CCU-Jack</name>\n\t \t<url>xmlrpc://127.0.0.1:2121/RPC3</url> \n\t \t<info>CCU-Jack</info> \n\t</ipc>\n</interfaces>\n"; } >/usr/local/etc/config/InterfacesList.xml.tmp && mv /usr/local/etc/config/InterfacesList.xml.tmp /usr/local/etc/config/InterfacesList.xml && grep -c Interface /usr/local/etc/config/rfd.conf && grep -c "<name>" /usr/local/etc/config/InterfacesList.xml'
  # B-321: hs_err files live in /var/hmipserver, a tmpfs: onto the userfs before the reboot
  say "guest: crash files of boot 1 onto the userfs (none on a clean boot)"; guest "$(stash_snippet)"
  say "guest: rebooting"; guest 'systemctl --no-block reboot' >/dev/null
  # the shell on the other side dies with the reboot: end the driver, the next guest call reopens
  guest_close
  # the VM reboots in place (-kernel boots are not -no-reboot); wait until the endpoint is gone
  for _ in $(seq 1 60); do
    qemu_check "during the reboot"
    curl -s --max-time 2 "http://127.0.0.1:$PORT/api/system/v1/health" >/dev/null 2>&1 || break
    sleep 2
  done
  wait_http "boot 2"
  guest_open # again in this shell, not in the first $( ) that follows
  firmware_check "boot 2"
  say "guest (boot 2): the addon unit came back from the generator at boot, the journal remembers boot 1"
  guest 'systemctl is-system-running; systemctl --failed --no-legend --plain --no-pager; systemctl status addon-litetest.service --no-pager -n0 | sed -n 1,8p; journalctl --list-boots --no-pager; cat /etc/machine-id; cat /usr/local/etc/machine-id; journalctl -b --no-pager -o short-monotonic | grep -m1 "Startup finished"'
  boot_checks "boot 2"
  # the warnings of both boots, boot 1 with its shutdown, against the allowlist: a new one fails
  # until it is fixed or allowlisted with its reason (scripts/lite-boot-warnings.sh).
  # LITE_BOOT_WARNINGS=report prints them without failing (to make an allowlist).
  for b in -1 0; do
    say "guest (boot 2): the warnings of journal boot $b"
    guest "journalctl -b $b -p warning -q --no-pager -o short" >"$WORK/warnings$b.txt"
    if ! sh "$(dirname "$0")/lite-boot-warnings.sh" "${LITE_BOOT_WARNINGS_ALLOW:-$(dirname "$0")/lite-boot-warnings.allow}" "$WORK/warnings$b.txt" >"$WORK/warncheck$b.txt"; then
      cat "$WORK/warncheck$b.txt"
      if [ "${LITE_BOOT_WARNINGS:-}" = report ]; then say "(report only: LITE_BOOT_WARNINGS=report)"
      # task 376: when the run met GitHub's quota, occulited's lines about it are the environment's
      elif [ "$QUOTA_MET" = 1 ] && ! grep '^new warning: ' "$WORK/warncheck$b.txt" | grep -qv 'rate limit'; then envfail "journal boot $b: only occulited's lines about GitHub's quota are new (above)"
      else fail "journal boot $b: a warning that is not in lite-boot-warnings.allow (above)"; fi
    else
      cat "$WORK/warncheck$b.txt"
    fi
  done
  # systemd-tmpfiles' notes are below the warning level, so the check above does not see them: a
  # path two files declare ("Duplicate line for path") and a path it refuses ("unsafe path
  # transition"). Neither belongs in a boot's journal; both boots are asked.
  R=$(guest 'journalctl --no-pager -o cat -t systemd-tmpfiles | grep -cE "Duplicate line for path|unsafe path transition"'); case "$R" in *'| 0'*) ;; *) fail "systemd-tmpfiles notes a duplicate or a refused path: $R"; guest 'journalctl --no-pager -o cat -t systemd-tmpfiles | sort -u | head -20';; esac
  # the seeded gateway is a documentation address nobody answers: the firmware update skips it with
  # a line, a success - it used to run eq3configcmd into three timeouts and fail the unit
  R=$(guest 'systemctl show -p Result --value occu-lgw-firmware-update.service; journalctl -b -u occu-lgw-firmware-update.service --no-pager -o cat | grep -c "no RF LAN gateway answers (10.0.2.200)"'); case "$R" in *'| success'*'| 1'*) ;; *) fail "occu-lgw-firmware-update did not skip the silent gateway as a success: $R";; esac
  R=$(guest 'systemctl is-active addon-litetest.service'); case "$R" in *'| active'*) ;; *) fail "addon-litetest.service not active after the reboot";; esac
  # counted by their rows: systemd 257 prints a header line above them
  R=$(guest 'journalctl --list-boots --no-pager | grep -cE "^ *-?[0-9]+ [0-9a-f]{32} "'); case "$R" in *'| 2'*) ;; *) fail "expected two boots in the persistent journal";; esac
  # D-41: the second boot starts on the stored ID, before journald - so both boots share it
  R=$(guest 'test "$(cat /etc/machine-id)" = "$(cat /usr/local/etc/machine-id)" && echo same || echo differs'); case "$R" in *'| same'*) ;; *) fail "boot 2 did not start on the stored machine ID (D-41)";; esac
  # task 27.4 / B-26, boot 2: the override is in rfd's environment without anyone restarting it,
  # crond is masked and never started, and the replayer finished before rfd began.
  say "guest (boot 2): the unit override and the switch were applied before the units started"
  guest 'systemctl status occu-unit-overrides.service --no-pager -n5 | sed -n 1,12p; systemctl show rfd.service -p Environment -p DropInPaths; systemctl is-enabled crond.service; systemctl is-active crond.service; journalctl -b -u crond.service --no-pager | wc -l; journalctl -b -o short-monotonic -u occu-unit-overrides.service -u rfd.service --no-pager | head -6'
  R=$(guest 'systemctl show hmipserver.service -p Environment --value'); case "$R" in *OCCULITE_TEST=boot*) ;; *) fail "the unit override was not in force at boot (task 27.4): $R";; esac
  R=$(guest 'systemctl is-enabled crond.service'); case "$R" in *masked*) ;; *) fail "crond was not masked at boot from unit-switch.json (B-26): $R";; esac
  R=$(guest 'journalctl -b -q --no-pager _COMM=crond | wc -l'); case "$R" in *'| 0'*) ;; *) fail "crond ran at boot 2 before the mask landed (B-26)";; esac
  R=$(guest 'A=$(systemctl show -p ExecMainExitTimestampMonotonic --value occu-unit-overrides.service); B=$(systemctl show -p InactiveExitTimestampMonotonic --value hmipserver.service); [ -n "$A" ] && [ -n "$B" ] && [ "$A" -lt "$B" ] && echo before || echo "after: $A vs $B"'); case "$R" in *'| before'*) ;; *) fail "occu-unit-overrides did not finish before hmipserver started: $R";; esac
  # task 129, boot 2: the switch guarantee. The plan ran (its markers and files), rfd runs on the
  # gateway alone, the interface list is the template's cut for the hardware, hmipserver runs
  # HMServer.jar (HmIP none, set on boot 1), multimacd is skipped (inactive, not failed) without a module.
  say "guest (boot 2): the radio plan on an OpenCCU-shaped userfs"
  guest 'journalctl -b -o short-monotonic -u occu-init-rf-hardware.service --no-pager | grep -E "plan:|run:" | head -12; ls /run/occulite/radio; systemctl is-active multimacd.service rfd.service hmipserver.service hs485d.service occu-init-hs485d.service occu-interface-clock.service | tr "\n" " "; echo; grep -E "^#?\[Interface|^#?Type|^Listen" /var/etc/rfd.conf; grep -o "<name>[^<]*</name>" /usr/local/etc/config/InterfacesList.xml | tr "\n" " "; echo'
  R=$(guest 'test -e /run/occulite/radio/rfd.enabled && test ! -e /run/occulite/radio/multimacd.enabled && test -e /run/occulite/radio/hmipserver.enabled && echo markers-ok'); case "$R" in *'| markers-ok'*) ;; *) fail "the plan's markers: rfd and hmipserver expected, no multimacd (task 129): $R";; esac
  R=$(guest 'grep -q "^Type = HMLGW2" /var/etc/rfd.conf && grep -q "^#\[Interface 0\]" /var/etc/rfd.conf && grep -q "^Listen IP = 127.0.0.1" /var/etc/rfd.conf && echo rfdconf-ok'); case "$R" in *'| rfdconf-ok'*) ;; *) fail "rfd.conf on the userfs was not kept with its gateway, the local section off and the loopback line (task 129, D-82)";; esac
  # the gateway here is a documentation address nobody answers: rfd runs and keeps trying it, so its
  # unit may stay "activating"; a refusal is failed or inactive
  R=$(guest 'systemctl is-active rfd.service'); case "$R" in *'| active'*|*'| activating'*) ;; *) fail "rfd did not run on the LAN gateway alone (task 129 measurement 8: does rfd refuse without a local interface?): $R";; esac
  # the interface list is the template's cut for the hardware: BidCos-RF for the gateway, no
  # foreign entry (D-97), no HmIP-RF without a module - and it stays so while rfd does not answer
  R=$(guest 'grep -o "<name>[^<]*</name>" /usr/local/etc/config/InterfacesList.xml | tr "\n" " "'); case "$R" in *'BidCos-RF'*'VirtualDevices'*) case "$R" in *CCU-Jack*|*HmIP-RF*) fail "InterfacesList.xml must be the template's cut: no foreign entry (D-97), no HmIP-RF without a module: $R";; esac;; *) fail "InterfacesList.xml lost BidCos-RF (the gateway) or VirtualDevices: $R";; esac
  # HMIPServer 1.5.2 - here HMServer.jar, HmIP set to none - starts while rfd does not answer
  # and registers with it every 5 seconds until it does (1.5.1 did not come up without it: 2.0.0-beta.0's
  # boot 2 restarted it every 5 minutes; beta.1 held it back, beta.2 left BidCos-RF out of the list for
  # the start). rfd never answers here (the seeded gateway is silent), so hmipserver must come up at its
  # first try with BidCos-RF still listed, VirtualDevices answering, no marker and no JVM exception.
  # the guest's console takes a line of a few hundred characters and every call answers within
  # 240 s: the wait is split into calls (up to 7 minutes for a TCG JVM start), and the checks are
  # short lines
  for _ in 1 2 3 4 5 6 7; do
    R=$(guest 'for i in $(seq 1 12); do [ "$(systemctl is-active hmipserver)" = active ] && break; sleep 5; done; systemctl is-active hmipserver')
    case "$R" in *'| active'*) break;; esac
  done
  R=$(guest 'echo "state=$(systemctl is-active hmipserver) marker=$(ls /run/occulite/radio | grep -c bidcos) restarts=$(systemctl show -p NRestarts --value hmipserver) end"')
  R2=$(guest 'J="journalctl -b -u hmipserver -o cat --no-pager"; echo "out=$($J | grep -c "left out of InterfacesList.xml") died=$($J | grep -c "Exception in thread") started=$(test -e /var/status/HMServerStarted && echo y || echo n) end"')
  R3=$(guest 'echo "list=$(grep -o "<name>[^<]*</name>" /usr/local/etc/config/InterfacesList.xml | sed "s/<[^>]*>//g" | tr "\n" ",") end"')
  R4=$(guest 'printf "%s" "<?xml version=\"1.0\"?><methodCall><methodName>system.listMethods</methodName></methodCall>" >/tmp/lm.xml; echo "vd=$(curl -s -m 20 -H Content-Type:text/xml -d @/tmp/lm.xml http://127.0.0.1:39292/groups | grep -o "<value>[a-zA-Z.]*</value>" | wc -l) end"')
  R="$(printf '%s\n' "$R" | grep -o 'state=.* end' | tail -n 1) $(printf '%s\n' "$R2" | grep -o 'out=.* end' | tail -n 1) $(printf '%s\n' "$R3" | grep -o 'list=.* end' | tail -n 1) $(printf '%s\n' "$R4" | grep -o 'vd=.* end' | tail -n 1)"
  say "guest (boot 2): hmipserver while rfd does not answer: $R"
  case "$R" in *'state=active marker=0 restarts=0 end out=0 died=0 started=y end list=BidCos-RF,VirtualDevices, end vd='[1-9]*' end'*) ;; *) fail "hmipserver must come up with VirtualDevices at its first try while rfd does not answer, BidCos-RF kept in InterfacesList.xml: $R";; esac
  R=$(guest 'systemctl show -p Result --value multimacd.service; systemctl is-active multimacd.service')
  case "$R" in *'| '*inactive*) ;; *) fail "multimacd must be skipped (inactive, not failed) without a module: $R";; esac
  # leave the image's userfs as the next test expects it: nothing switched off, no override, the
  # rfd.conf and interface list as the first boot made them
  guest 'sed -i "/^occulite.hmip.adapter=/d" /usr/local/etc/config/crRFD/hmip_user.conf; rm -rf /usr/local/etc/occulite/unit-overrides /usr/local/etc/occulite/unit-switch.json /usr/local/etc/config/InterfacesList.xml; if [ -e /usr/local/etc/config/rfd.conf.lite-qemu-test ]; then mv /usr/local/etc/config/rfd.conf.lite-qemu-test /usr/local/etc/config/rfd.conf; else rm -f /usr/local/etc/config/rfd.conf; fi' >/dev/null
  # the recovery system through GRUB, and an update through it (see the top)
  if [ "$FAILED" = 0 ] && [ -n "$UPDATE_ZIP" ]; then update_phase
  elif [ "$FAILED" = 0 ] && [ "${LITE_QEMU_RECOVERY:-0}" = 1 ]; then recovery_phase; fi
  # B-321: a failed run keeps its evidence first, and then powers off cleanly (the cleanup copies it)
  if [ "$FAILED" != 0 ] && ! only_quota; then evidence_guest; evidence_poweroff
  elif qemu_alive; then guest 'systemctl --no-block poweroff' >/dev/null; sleep 15; fi
  guest_close
fi

# (no QEMU check here: the systemd phase ends with a poweroff, and QEMU exits with its guest)
# B-321: a failure before the systemd phase (boot 1's HTTP checks) keeps its evidence too
if [ "$FAILED" != 0 ] && ! only_quota; then evidence_guest; evidence_poweroff; fi
qemu_stop
oom_report
# the cleanup trap removes the work dir; on a failure it keeps the serial log and the evidence next to it
if [ "$FAILED" = 0 ]; then say "OK"; exit 0; fi
# task 376: only GitHub's quota failed - the environment, not the image: run again after the reset
if [ "$ENV_ONLY" = 1 ] && [ "$QUOTA_MET" = 1 ]; then say "FAIL: only GitHub's quota (the environment), not the image - run again after the reset (exit 3)"; exit 3; fi
exit 1
