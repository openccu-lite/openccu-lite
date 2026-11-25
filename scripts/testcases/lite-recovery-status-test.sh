#!/bin/sh
# openccu-lite task 505: the recovery's 503 JSON (lite_unavailable.cgi) and its "update" object.
#
# The CGI reads an install's state from outside - upstream fwinstall.sh's lock file and log, a
# running dd's command line in /proc, the target partition's sectors-written counter in /sys. Here
# each of those is a fixture under LITE_STATUS_ROOT, and every answer must be valid JSON with
# "error": "updating" and "recovery": true whatever the inputs hold: one case per phase (starting,
# prepare, install, the two flash steps with their bytes, done, failed), and garbage - a binary
# log, quotes and braces in it, a step out of range, a dd writing a file, a counter that is not a
# number or runs past the total, a missing log with the lock, nothing at all (no object).
#
# Usage: sh scripts/testcases/lite-recovery-status-test.sh      (needs python3 for the JSON checks)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
CGI="$HERE/buildroot-external/package/recovery-system/external/overlay/base/www/cgi-bin/lite_unavailable.cgi"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }
command -v python3 >/dev/null 2>&1 || { echo "FAIL python3 is needed"; exit 1; }

W=$(mktemp -d "${TMPDIR:-/tmp}/lite-recovery-status.XXXXXX")
trap 'rm -rf "$W"' EXIT INT TERM

fresh() { rm -rf "$W/r"; mkdir -p "$W/r/tmp" "$W/r/proc" "$W/r/sys/class/block"; }
# a dd process: pid, then its arguments
dd_proc() { pid=$1; shift; mkdir -p "$W/r/proc/$pid"; echo dd >"$W/r/proc/$pid/comm"; printf '%s\0' dd "$@" >"$W/r/proc/$pid/cmdline"; }
# a partition: name, sectors written, size in sectors
part() { mkdir -p "$W/r/sys/class/block/$1"; echo "  100 0 800 10 5 0 $2 20 0 30 40 0 0 0 0" >"$W/r/sys/class/block/$1/stat"; echo "$3" >"$W/r/sys/class/block/$1/size"; }

# run the CGI for a path; the body into $W/body, the headers into $W/head
cgi() { LITE_STATUS_ROOT="$W/r" REQUEST_URI="${1:-/api/system/v1/health}" sh "$CGI" >"$W/out" 2>"$W/err"
  sed -n '1,/^\r\{0,1\}$/p' "$W/out" >"$W/head"; sed '1,/^\r\{0,1\}$/d' "$W/out" >"$W/body"; }

# check <name> <python expression on d = the JSON body>
check() {
  name=$1; expr=$2
  if python3 - "$W/body" "$expr" <<'PY' >"$W/py" 2>&1
import json, sys
body = open(sys.argv[1], encoding="utf-8").read()
d = json.loads(body)
assert d.get("error") == "updating", d
assert d.get("recovery") is True, d
u = d.get("update")
assert eval(sys.argv[2], {"d": d, "u": u}), body
PY
  then ok "$name"; else bad "$name: $(cat "$W/py" | tail -3 | tr '\n' ' ')"; fi
  [ -s "$W/err" ] && bad "$name: stderr: $(cat "$W/err")"
  return 0
}

LOG_PREPARE='Starting firmware update (DO NOT INTERRUPT!!!):<br/>
[1/7] Checking uploaded data... 313133836 bytes received, OK<br/>
[2/7] Calculating SHA256 checksum....0b2a9c<br/>
[3/7] Checking free disk space... 25804304384 bytes, OK<br/>
[4/7] Checking storage performance.... sequential write: 21.44 MB/s (OK: > 10.0 MB/s)<br/>
[5/7] Preparing uploaded data... zip identified, unarchiving......'
LOG_INSTALL="$LOG_PREPARE OK<br/>
[6/7] Verifying uploaded data....OK (sha256sum), DONE<br>
[7/7] Preparing firmware update... OK<br/>
[1/5] Validate update directory... OK<br/>
[2/5] Checking update_script... OK<br/>
[3/5] Checking for rootfs filesystem images... none<br/>
[4/5] Checking for bootfs filesystem images... none<br/>
[5/5] Checking for image file... found, OK<br/>"

# --- nothing: the recovery's menu, a restore ---------------------------------------------------
fresh; cgi
check "no log, no lock: recovery without an update object" 'u is None'
grep -q '^Status: 503' "$W/head" && ok "503" || bad "status: $(head -1 "$W/head")"
grep -q '^Retry-After: 30' "$W/head" && ok "Retry-After: 30" || bad "no Retry-After"
grep -q '^Cache-Control: no-store' "$W/head" && ok "no-store" || bad "no Cache-Control: no-store"
grep -qi '^Location' "$W/head" && bad "a Location header" || ok "no Location"
grep -qi 'Strict-Transport-Security' "$W/head" && bad "an HSTS header" || ok "no HSTS header"

fresh; cgi /addons/red/
grep -q '^Content-Type: text/plain' "$W/head" && grep -q 'recovery system' "$W/body" && ok "/addons/: the text answer, unchanged" || bad "/addons/: $(cat "$W/out")"

# --- the phases -------------------------------------------------------------------------------
fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; cgi
check "lock, no log yet: starting" 'u == {"running": True, "phase": "starting", "log_bytes": 0}'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf 'Starting firmware update (DO NOT INTERRUPT!!!):<br/>\n' >"$W/r/tmp/fwinstall.log"; cgi
check "started, no step: prepare without a step" 'u["phase"] == "prepare" and "step" not in u and u["log_bytes"] > 0'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%s' "$LOG_PREPARE" >"$W/r/tmp/fwinstall.log"; cgi
check "prepare, step 5 of 7" 'u["phase"] == "prepare" and u["step"] == 5 and u["steps"] == 7 and u["running"] is True and "flashing" not in u'
check "log_bytes is the log's size" "u['log_bytes'] == $(wc -c <"$W/r/tmp/fwinstall.log")"

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%s' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"; cgi
check "install, step 5 of 5, no dd yet" 'u["phase"] == "install" and u["step"] == 5 and u["steps"] == 5 and "flashing" not in u'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%sflashing bootfs....' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"
dd_proc 812 if=/dev/loop0p1 of=/dev/mmcblk0p1 bs=4M conv=fsync status=none; part loop0p1 0 524288; part mmcblk0p1 209715 524288; cgi
check "flashing bootfs: 40 % of 256 MiB" 'u["flashing"] == "bootfs" and u["written"] == 209715 * 512 and u["total"] == 524288 * 512'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%sflashing bootfs..OK, flashing rootfs....' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"
echo 1 >"$W/r/proc/1"; mkdir -p "$W/r/proc/77"; echo sh >"$W/r/proc/77/comm"; printf 'sh\0-c\0dd of=/dev/x\0' >"$W/r/proc/77/cmdline"
dd_proc 913 if=/dev/loop0p2 of=/dev/mmcblk0p2 bs=4M conv=fsync status=none; part loop0p2 0 4194304; part mmcblk0p2 3103784 4194304; cgi
check "flashing rootfs: 74 % of 2 GiB (another process with dd in its arguments ignored)" 'u["flashing"] == "rootfs" and u["written"] == 3103784 * 512 and u["total"] == 4194304 * 512'

# busybox dd cuts its own argv at each "=" (measured in the recovery on 2026-11-25: /proc showed
# "of" and "/dev/mmcblk0p2" as two arguments, and the first version of this CGI found no dd)
fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%sflashing bootfs..OK, flashing rootfs....' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"
dd_proc 921 if /dev/loop1 of /dev/mmcblk0p2 bs 4M conv fsync status none; part loop1 0 4194304; part mmcblk0p2 2097152 4194304; cgi
check "busybox dd (argv cut at the =): flashing rootfs 50 %" 'u["flashing"] == "rootfs" and u["written"] == 2097152 * 512 and u["total"] == 4194304 * 512'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%s' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"
mkdir -p "$W/r/tmp/img"; head -c 4096 /dev/zero >"$W/r/tmp/img/rootfs.ext4"
dd_proc 914 if=/tmp/img/rootfs.ext4 of=/dev/mmcblk0p2 bs=4M conv=fsync status=none; part mmcblk0p2 4 4194304; cgi
check "a dd from an image file: its size is the total" 'u["total"] == 4096 and u["written"] == 2048 and u["flashing"] == "mmcblk0p2"'

fresh; printf '%sflashing bootfs..OK, flashing rootfs..OK, DONE<br/>\nFinished firmware update successfully.<br/>\n' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"; cgi
check "done, the lock gone" 'u["phase"] == "done" and u["running"] is False and "flashing" not in u'

fresh; printf '%s\nERROR: unattended firmware update failed (rc=1), rebooting into the normal system<br/>\n' "$LOG_PREPARE" >"$W/r/tmp/fwinstall.log"; cgi
check "failed" 'u["phase"] == "failed" and u["running"] is False'

# --- garbage ----------------------------------------------------------------------------------
fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; head -c 20000 /dev/urandom >"$W/r/tmp/fwinstall.log"; printf '\n[2/7] x' >>"$W/r/tmp/fwinstall.log"; cgi
check "a binary log: still JSON" 'u["running"] is True and u["phase"] in ("prepare", "starting")'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '"},{"x":"\\\n[1/7] "quoted" {braces} </script>\nflashing ro"otfs\n' >"$W/r/tmp/fwinstall.log"; cgi
check "quotes, braces, backslashes in the log: still JSON, nothing of it copied" 'u["step"] == 1 and "x" not in d'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '[9/7] x\n' >"$W/r/tmp/fwinstall.log"; cgi
check "a step past its count: no step" '"step" not in u'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '[99999999999999999999/99999999999999999999] x\n' >"$W/r/tmp/fwinstall.log"; cgi
check "absurd numbers: no step" '"step" not in u'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%sflashing rootfs..' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"
dd_proc 915 if=/dev/loop0p2 of=/tmp/somefile; part loop0p2 0 100; cgi
check "a dd writing a file, not a partition: no flash figures" '"flashing" not in u'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%sflashing rootfs..' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"
dd_proc 916 'if=/dev/loop0p2' 'of=/dev/../../etc/x'; cgi
check "a target path with ..: ignored" '"flashing" not in u'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%sflashing rootfs..' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"
dd_proc 917 if=/dev/loop0p2 of=/dev/mmcblk0p2; part loop0p2 0 abc; part mmcblk0p2 50 abc; cgi
check "no source size: flashing without bytes" 'u["flashing"] == "rootfs" and "written" not in u and "total" not in u'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%sflashing rootfs..' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"
dd_proc 918 if=/dev/loop0p2 of=/dev/mmcblk0p2; part loop0p2 0 100; part mmcblk0p2 0 100; echo "garbage here x y z w q" >"$W/r/sys/class/block/mmcblk0p2/stat"; cgi
check "a counter that is not a number: no flash figures" '"written" not in u'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; printf '%sflashing rootfs..' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"
dd_proc 919 if=/dev/loop0p2 of=/dev/mmcblk0p2; part loop0p2 0 100; part mmcblk0p2 500 100; cgi
check "a counter past the total: clamped" 'u["written"] == u["total"] == 51200'

fresh; printf '%sflashing rootfs..' "$LOG_INSTALL" >"$W/r/tmp/fwinstall.log"
dd_proc 920 if=/dev/loop0p2 of=/dev/mmcblk0p2; part loop0p2 0 100; part mmcblk0p2 50 100; cgi
check "a dd without the lock (not ours): no flash figures" '"flashing" not in u and u["running"] is False'

fresh; : >"$W/r/tmp/.runningFirmwareUpdate"; mkdir "$W/r/tmp/fwinstall.log"; cgi
check "the log a directory: JSON, no log size" 'u["log_bytes"] == 0'

echo; [ "$fails" -eq 0 ] && { echo "lite-recovery-status-test: all checks passed"; exit 0; }
echo "lite-recovery-status-test: $fails check(s) failed"; exit 1
