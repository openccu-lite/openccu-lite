#!/bin/sh
# openccu-lite: the HB-RF-ETH session check (usr/libexec/occu/lite-hb-rf-eth-session) against a fake
# sysfs flag, /proc and systemctl: who is restarted, and that it cannot become a restart loop.
#
# Usage: sh scripts/testcases/lite-hb-rf-eth-session-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$HERE/buildroot-external/overlay/lite/usr/libexec/occu/lite-hb-rf-eth-session"
U="$HERE/buildroot-external/overlay/lite/usr/lib/systemd/system"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

mkdir -p "$T/proc"
cat >"$T/systemctl" <<SH
#!/bin/sh
case "\$1" in
  show) cat "$T/pid-\$5" 2>/dev/null || echo 0 ;;
  restart) shift; echo "\$*" >>"$T/restarted" ;;
esac
SH
chmod +x "$T/systemctl"

export HB_RF_ETH_SESSION_FLAG="$T/flag" HB_RF_ETH_SESSION_STAMP="$T/stamp" HB_RF_ETH_SESSION_UPTIME="$T/uptime"
export HB_RF_ETH_SESSION_PROC="$T/proc" HB_RF_ETH_SESSION_SYSTEMCTL="$T/systemctl"

# a unit's main process, holding a device
daemon() { # unit pid device
  echo "$2" >"$T/pid-$1"
  mkdir -p "$T/proc/$2/fd"
  ln -sf "$3" "$T/proc/$2/fd/5"
}
reset() { rm -rf "$T/proc"/* "$T"/pid-* "$T/restarted" "$T/stamp"; echo 1 >"$T/flag"; echo "1000.5 0.0" >"$T/uptime"; }
run() { sh "$SCRIPT" >"$T/out" 2>&1; echo $? >"$T/rc"; }
restarted() { cat "$T/restarted" 2>/dev/null | tr '\n' ';'; }

reset; echo 0 >"$T/flag"; daemon multimacd.service 10 /dev/raw-uart; run
[ -z "$(restarted)" ] && ok "flag 0: nothing restarted" || bad "flag 0 restarted $(restarted)"

reset; rm "$T/flag"; run
[ "$(cat "$T/rc")" = 0 ] && [ -z "$(restarted)" ] && ok "no flag file: a clean no-op" || bad "no flag file: rc $(cat "$T/rc"), $(restarted)"

reset; daemon multimacd.service 10 /dev/raw-uart1; daemon rfd.service 11 /dev/mmd_bidcos; run
[ "$(restarted)" = "multimacd.service;" ] && ok "multimacd holds it: only multimacd (PartOf takes the rest)" || bad "multimacd: $(restarted)"
grep -q 'restarting multimacd.service' "$T/out" && ok "the journal line names the unit" || bad "line: $(cat "$T/out")"

reset; daemon rfd.service 11 /dev/raw-uart; daemon hmipserver.service 12 /dev/ttyUSB0; run
[ "$(restarted)" = "rfd.service;" ] && ok "rfd directly on the module: rfd alone" || bad "rfd: $(restarted)"

reset; daemon rfd.service 11 /dev/raw-uart; daemon hmipserver.service 12 /dev/raw-uart; run
[ "$(restarted)" = "rfd.service hmipserver.service;" ] && ok "both directly: both" || bad "both: $(restarted)"

reset; daemon rfd.service 11 /dev/ttyUSB0; run
[ -z "$(restarted)" ] && [ "$(cat "$T/rc")" = 0 ] && ok "nobody holds a raw UART: no restart, no failure" || bad "nobody: $(restarted)"

# no loop: the flag stays set
reset; daemon multimacd.service 10 /dev/raw-uart; run; run
[ "$(restarted)" = "multimacd.service;" ] && ok "flag still set 0 s later: no second restart" || bad "loop: $(restarted)"
echo "1149.0 0.0" >"$T/uptime"; run
[ "$(restarted)" = "multimacd.service;" ] && ok "149 s later: still none" || bad "149 s: $(restarted)"
echo "1150.0 0.0" >"$T/uptime"; run
[ "$(restarted)" = "multimacd.service;multimacd.service;" ] && ok "150 s later: the next one" || bad "150 s: $(restarted)"

# the units
grep -q '^ConditionPathExists=/sys/class/hb-rf-eth/hb-rf-eth/session_lost$' "$U/occu-hb-rf-eth-session.service" && ok "skipped without the driver" || bad "the service's condition"
grep -q '^OnUnitInactiveSec=30$' "$U/occu-hb-rf-eth-session.timer" && ok "the timer's period" || bad "the timer's period"
# B-351: the timer runs only while the driver's device is there, so a system without an HB-RF-ETH
# gets no "skipped, unmet condition" journal line every 30 s
R="$HERE/buildroot-external/overlay/lite/usr/lib/udev/rules.d/61-openccu-lite-radio-hotplug.rules"
! grep -q 'occu-hb-rf-eth-session' "$U/../system-preset/50-openccu-lite.preset" && ok "the preset does not enable the timer" || bad "the preset names the timer"
! grep -q '^\[Install\]' "$U/occu-hb-rf-eth-session.timer" && ok "the timer has no [Install]: nothing enables it for every system" || bad "the timer has an [Install] section"
grep -q '^ConditionPathExists=/sys/class/hb-rf-eth/hb-rf-eth$' "$U/occu-hb-rf-eth-session.timer" && ok "a timer started by hand without the driver is skipped" || bad "the timer's condition"
grep -q '^SUBSYSTEM=="hb-rf-eth", KERNEL=="hb-rf-eth", ACTION=="add", RUN+="/bin/systemctl --no-block start occu-hb-rf-eth-session.timer"$' "$R" && ok "udev starts the timer when the driver's device appears" || bad "no udev start of the timer"
grep -q '^SUBSYSTEM=="hb-rf-eth", KERNEL=="hb-rf-eth", ACTION=="remove", RUN+="/bin/systemctl --no-block stop occu-hb-rf-eth-session.timer"$' "$R" && ok "udev stops the timer when the driver goes" || bad "no udev stop of the timer"
[ "$(grep -c 'occu-hb-rf-eth-session' "$R")" = 2 ] && ok "nothing else in the rules starts the timer" || bad "the rules name the timer $(grep -c 'occu-hb-rf-eth-session' "$R") times"
[ -x "$SCRIPT" ] && ok "the script is executable" || bad "the script's mode"

[ "$fails" = 0 ] && { echo "all ok"; exit 0; }
echo "$fails failed"; exit 1
