#!/bin/sh
# openccu-lite: occu-link.service hands the userfs's .link files to udev (lite-link-apply), against
# stand-ins (no udev, no root, no network):
#   - no directory, an empty one: nothing runs;
#   - a file: copied to the run directory 0644, udev reloads, the add events of the wired
#     interfaces that are up are replayed (not lo, not Wi-Fi, not a veth, not an interface that is
#     down: its driver refuses the advertisement), the list of what was copied is kept;
#   - the same again: replayed (udev leaves an interface alone whose settings are the file's), not
#     copied again;
#   - a changed file: copied and replayed again;
#   - a removed file: gone from the run directory, and the interface it was applied to goes back
#     to everything it supports (ethtool -s <if> autoneg on) - the other interfaces are left alone;
#   - a file of the run directory that is not this script's stays;
#   - a symlink, a file another user may write, a file of another owner, another name: not taken;
#   - udev failing to reload: exit 1;
#   - --up <iface>, the network start's call after it brought an interface up: that interface's
#     add event while a file is applied, nothing at all otherwise; the hook is in eQ3StartNetwork,
#     between the interface coming up and the wait for its link;
#   - the unit: before the network, after the restore at boot, enabled.
#
# Usage: sh scripts/testcases/lite-link-apply-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$HERE/buildroot-external/overlay/lite/usr/libexec/occu/lite-link-apply"
UNIT="$HERE/buildroot-external/overlay/lite/usr/lib/systemd/system/occu-link.service"
PRESET="$HERE/buildroot-external/overlay/lite/usr/lib/systemd/system-preset/50-openccu-lite.preset"
HOOK="$HERE/buildroot-external/overlay/base/etc/network/if-up.d/eQ3StartNetwork"

T=$(mktemp -d) || exit 2
trap 'rm -rf "${T:?}"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

sh -n "$SCRIPT" && ok "lite-link-apply parses" || bad "lite-link-apply does not parse"
[ -x "$SCRIPT" ] && ok "lite-link-apply is executable" || bad "lite-link-apply is not executable"
grep -q '^ExecStart=/usr/libexec/occu/lite-link-apply$' "$UNIT" && ok "occu-link.service runs it" || bad "occu-link.service does not run lite-link-apply"
grep -q '^Before=.*occu-network\.service' "$UNIT" && ok "occu-link.service is before the network" || bad "occu-link.service is not before occu-network.service"
grep -q '^After=.*occu-backup-restore\.service' "$UNIT" && ok "occu-link.service is after the restore at boot" || bad "occu-link.service is not after occu-backup-restore.service"
grep -q '^RequiresMountsFor=/usr/local$' "$UNIT" && ok "occu-link.service needs the userfs" || bad "occu-link.service does not require /usr/local"
grep -q '^RemainAfterExit=yes$' "$UNIT" && ok "a restart runs it again" || bad "occu-link.service has no RemainAfterExit"
grep -qx 'enable occu-link.service' "$PRESET" && ok "occu-link.service is enabled" || bad "occu-link.service is not in the preset"

# the network start replays the interface's add event once it is up, before it waits for the link
up_line=$(grep -n '/sbin/ip link set "${IFACE}" up' "$HOOK" | head -1 | cut -d: -f1)
hook_line=$(grep -n '/usr/libexec/occu/lite-link-apply --up "${IFACE}"' "$HOOK" | head -1 | cut -d: -f1)
wait_line=$(grep -n 'while \[\[ "$(cat "/sys/class/net/${IFACE}/carrier")" == "0" \]\]' "$HOOK" | head -1 | cut -d: -f1)
if [ -n "$up_line" ] && [ -n "$hook_line" ] && [ -n "$wait_line" ] && [ "$up_line" -lt "$hook_line" ] && [ "$hook_line" -lt "$wait_line" ]; then
  ok "eQ3StartNetwork calls lite-link-apply --up between the interface coming up and the wait for its link"
else
  bad "eQ3StartNetwork does not call lite-link-apply --up after ip link set up and before the carrier wait (lines: up=$up_line hook=$hook_line wait=$wait_line)"
fi

# the stand-ins: a sysfs with eth0 (wired, up), eth1 (wired, down), wlan0, lo and a veth; udevadm and ethtool
# log their arguments, and udevadm answers ID_NET_LINK_FILE from $T/applied/<iface>
mkdir -p "$T/bin" "$T/sys/eth0/device" "$T/sys/eth1/device" "$T/sys/wlan0/device" "$T/sys/wlan0/wireless" "$T/sys/lo" "$T/sys/veth0" "$T/applied"
for i in eth0 eth1 wlan0 veth0; do echo 1 > "$T/sys/$i/type"; echo 0x1003 > "$T/sys/$i/flags"; done
echo 0x1002 > "$T/sys/eth1/flags"
echo 772 > "$T/sys/lo/type"
cat > "$T/bin/udevadm" <<'STUB'
#!/bin/sh
echo "udevadm $*" >> "$CALLS"
case "$1" in
  info) for a in "$@"; do i=$a; done; i=${i##*/}; [ -f "$APPLIED/$i" ] && echo "ID_NET_LINK_FILE=$(cat "$APPLIED/$i")"; echo "INTERFACE=$i" ;;
  control) [ -e "$APPLIED/.reload-fails" ] && exit 1 ;;
  trigger)
    # what udev would do: the first .link file of the run directory that names the interface wins
    for a in "$@"; do i=$a; done; i=${i##*/}
    rm -f "${APPLIED:?}/${i:?}"
    for f in "$RUNDIR"/*.link; do
      [ -f "$f" ] && grep -q "INTERFACE=$i\$" "$f" && { echo "$f" > "$APPLIED/$i"; break; }
    done ;;
esac
exit 0
STUB
cat > "$T/bin/ethtool" <<'STUB'
#!/bin/sh
echo "ethtool $*" >> "$CALLS"
STUB
chmod +x "$T/bin/udevadm" "$T/bin/ethtool"
CALLS="$T/calls"; APPLIED="$T/applied"; RUNDIR="$T/run/network"
export CALLS APPLIED RUNDIR
run() {
  : > "$CALLS"
  OCCU_LINK_SRC="$T/src" OCCU_LINK_DST="$RUNDIR" OCCU_LINK_LIST="$T/run/occu-link.list" OCCU_SYS_NET="$T/sys" \
    OCCU_UDEVADM="$T/bin/udevadm" OCCU_ETHTOOL="$T/bin/ethtool" OCCU_LINK_OWNER="${OWNER_AS:-$(id -u)}" sh "$SCRIPT" > "$T/out" 2>&1
}
link() { printf '[Match]\nProperty=INTERFACE=%s\n\n[Link]\nAdvertise=%s\n' "$1" "$2"; }
mkdir -p "$T/run"

run; rc=$?
[ "$rc" = 0 ] && [ ! -s "$CALLS" ] && [ ! -e "$RUNDIR" ] && ok "no directory: nothing runs" || bad "no directory: rc=$rc, calls: $(cat "$CALLS")"
mkdir -p "$T/src"
run; rc=$?
[ "$rc" = 0 ] && [ ! -s "$CALLS" ] && ok "an empty directory: nothing runs" || bad "an empty directory: rc=$rc, calls: $(cat "$CALLS")"

# a file of somebody else's in the run directory
mkdir -p "$RUNDIR"; echo other > "$RUNDIR/90-generator.link"

link eth0 "100baset-full 100baset-half" > "$T/src/10-occulite-speed-eth0.link"
chmod 0600 "$T/src/10-occulite-speed-eth0.link"
run; rc=$?
[ "$rc" = 0 ] && cmp -s "$T/src/10-occulite-speed-eth0.link" "$RUNDIR/10-occulite-speed-eth0.link" && ok "a file is copied to the run directory" || bad "the file was not copied (rc=$rc): $(cat "$T/out")"
[ "$(stat -c %a "$RUNDIR/10-occulite-speed-eth0.link")" = 644 ] && ok "the copy is 0644" || bad "the copy's mode is $(stat -c %a "$RUNDIR/10-occulite-speed-eth0.link")"
grep -qx 'udevadm control --reload' "$CALLS" && ok "udev reloads" || bad "no udevadm control --reload: $(cat "$CALLS")"
grep -qx "udevadm trigger --action=add --settle $T/sys/eth0" "$CALLS" && ok "the add event of the wired interface that is up is replayed" || bad "no add event for eth0: $(cat "$CALLS")"
grep -q "trigger.*/eth1$" "$CALLS" && bad "an add event for eth1, which is down" || ok "a wired interface that is down is not replayed"
if grep 'trigger' "$CALLS" | grep -q -e '/lo$' -e '/wlan0$' -e '/veth0$'; then bad "an add event for lo, wlan0 or veth0: $(cat "$CALLS")"; else ok "lo, Wi-Fi and the veth are left alone"; fi
[ "$(grep -n 'control --reload' "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'trigger' "$CALLS" | head -1 | cut -d: -f1)" ] && ok "the reload comes before the add events" || bad "the add events came before the reload"
[ "$(cat "$T/run/occu-link.list")" = "10-occulite-speed-eth0.link" ] && ok "the list names the copy" || bad "the list: $(cat "$T/run/occu-link.list")"
grep -q ethtool "$CALLS" && bad "ethtool ran although nothing was removed" || ok "ethtool does not run for a new file"
[ "$(cat "$APPLIED/eth0")" = "$RUNDIR/10-occulite-speed-eth0.link" ] || bad "the stand-in did not apply the file to eth0"

run; rc=$?
[ "$rc" = 0 ] && grep -q "trigger.*/eth0$" "$CALLS" && ! grep -q ethtool "$CALLS" && ! grep -q 'applied' "$T/out" && ok "the same again: replayed, not copied again" || bad "the same again: rc=$rc, $(cat "$CALLS") $(cat "$T/out")"

# --up: the network start's call
up() {
  : > "$CALLS"
  OCCU_LINK_SRC="$T/src" OCCU_LINK_DST="$RUNDIR" OCCU_LINK_LIST="$T/run/occu-link.list" OCCU_SYS_NET="$T/sys" \
    OCCU_UDEVADM="$T/bin/udevadm" OCCU_ETHTOOL="$T/bin/ethtool" sh "$SCRIPT" --up "$@" > "$T/out" 2>&1
}
up eth1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$CALLS")" = "udevadm trigger --action=add --settle $T/sys/eth1" ] && ok "--up eth1 with a file applied: its add event, nothing else" || bad "--up eth1: rc=$rc, $(cat "$CALLS")"
up nosuch0; rc=$?
[ "$rc" = 0 ] && [ ! -s "$CALLS" ] && ok "--up for an interface that is not there: nothing" || bad "--up nosuch0: rc=$rc, $(cat "$CALLS")"
up; rc=$?
[ "$rc" = 2 ] && [ ! -s "$CALLS" ] && ok "--up without an interface: usage, exit 2" || bad "--up without an interface: rc=$rc"
up '../eth0'; rc=$?
[ "$rc" = 2 ] && [ ! -s "$CALLS" ] && ok "--up with a path: refused" || bad "--up ../eth0: rc=$rc, $(cat "$CALLS")"

link eth0 "100baset-full" > "$T/src/10-occulite-speed-eth0.link"
run; rc=$?
[ "$rc" = 0 ] && cmp -s "$T/src/10-occulite-speed-eth0.link" "$RUNDIR/10-occulite-speed-eth0.link" && grep -q "trigger.*/eth0$" "$CALLS" && ok "a changed file is copied and replayed" || bad "a changed file was not applied: $(cat "$CALLS")"
grep -q ethtool "$CALLS" && bad "ethtool ran for a changed file" || ok "ethtool does not run for a changed file"

rm "$T/src/10-occulite-speed-eth0.link"
run; rc=$?
[ "$rc" = 0 ] && [ ! -e "$RUNDIR/10-occulite-speed-eth0.link" ] && ok "a removed file leaves the run directory" || bad "the removed file is still in the run directory (rc=$rc)"
grep -qx 'ethtool -s eth0 autoneg on' "$CALLS" && ok "its interface advertises everything again" || bad "no ethtool -s eth0 autoneg on: $(cat "$CALLS")"
grep -q 'ethtool -s eth1' "$CALLS" && bad "eth1 was reset although no file was applied to it" || ok "an interface without a file is not reset"
[ ! -s "$T/run/occu-link.list" ] && ok "the list is empty again" || bad "the list still names $(cat "$T/run/occu-link.list")"
[ "$(cat "$RUNDIR/90-generator.link")" = other ] && ok "a file that is not this script's stays" || bad "another file of the run directory was touched"
run
! grep -q -e trigger -e control -e ethtool "$CALLS" && ok "and nothing runs after that" || bad "something ran with nothing to apply: $(cat "$CALLS")"
up eth0; rc=$?
[ "$rc" = 0 ] && [ ! -s "$CALLS" ] && ok "--up with no file applied: nothing" || bad "--up with no file applied: rc=$rc, $(cat "$CALLS")"

# what is not taken
link eth0 "100baset-full" > "$T/real.link"
ln -s "$T/real.link" "$T/src/20-symlink.link"
link eth0 "100baset-full" > "$T/src/30-world-writable.link"; chmod 0666 "$T/src/30-world-writable.link"
link eth0 "100baset-full" > "$T/src/31-group-writable.link"; chmod 0664 "$T/src/31-group-writable.link"
link eth0 "100baset-full" > "$T/src/40-not-a-link.conf"
link eth0 "100baset-full" > "$T/src/50 space.link"
mkdir "$T/src/60-directory.link"
run; rc=$?
[ "$rc" = 0 ] && [ "$(ls "$RUNDIR")" = "90-generator.link" ] && ! grep -q trigger "$CALLS" && ok "a symlink, a file others may write, another name, a directory: not taken" || bad "something was taken: $(ls "$RUNDIR"); $(cat "$T/out")"
grep -q '^<4>.*30-world-writable.link: not taken' "$T/out" && grep -q '^<4>.*20-symlink.link: not taken' "$T/out" && ok "and each is named in a warning" || bad "no warning: $(cat "$T/out")"
mv "$T/src" "$T/src-refused"; mkdir "$T/src"

# a file of another owner
link eth0 "100baset-full" > "$T/src/10-a.link"
OWNER_AS=4294967 run
[ ! -e "$RUNDIR/10-a.link" ] && ok "a file of another owner is not taken" || bad "a file of another owner was taken"

# udev does not reload
: > "$APPLIED/.reload-fails"
run; rc=$?
[ "$rc" = 1 ] && grep -q '^<3>' "$T/out" && ok "udev failing to reload: exit 1 with an error line" || bad "udev failing to reload: rc=$rc, $(cat "$T/out")"

if [ "$fails" = 0 ]; then echo "all passed"; else echo "$fails failed"; exit 1; fi
