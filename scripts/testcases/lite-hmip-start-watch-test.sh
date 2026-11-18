#!/bin/sh
# openccu-lite B-348: lite-hmip-start-watch, hmipserver.service's ExecStartPost, restarts the unit
# when HMIPServer.jar has not bound its VirtualDevices port (HMServer.conf's hmServerPort) the given
# time after the ready step - at most twice per boot, only for HMIPServer.jar, only while the start's
# JVM is still the unit's active main process, never while the system stops, a radio change holds
# the units or the recovery is due. Stand-ins for systemctl and /proc/net; nothing needs root.
# A workaround: the test goes with the script once upstream fixes the start hang.
#
# Usage: sh scripts/testcases/lite-hmip-start-watch-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
W="$HERE/buildroot-external/overlay/lite/usr/libexec/occu/lite-hmip-start-watch"
U="$HERE/buildroot-external/overlay/lite/usr/lib/systemd/system/hmipserver.service"
[ -f "$W" ] || { echo "lite-hmip-start-watch not found at $W"; exit 2; }

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

# the systemctl stand-in: answers from files, logs what it is asked to do
cat >"$T/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
  "show -p MainPID --value hmipserver.service") cat "$FAKE/mainpid" ;;
  "is-active hmipserver.service") cat "$FAKE/active" ;;
  is-system-running) cat "$FAKE/system" ;;
  *) echo "$*" >>"$FAKE/calls" ;;
esac
EOF
chmod +x "$T/systemctl"

HDR='  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode'
# the listening sockets: "port" in decimal, on the loopback (IPv4) or v4-mapped (IPv6)
tables() { # tcp-port tcp6-port
  mkdir -p "$T/net"
  { echo "$HDR"
    [ -n "$1" ] && printf '   0: 0100007F:%04X 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 1 1\n' "$1"
    printf '   1: 0100007F:7D50 0100007F:997C 01 00000000:00000000 00:00000000 00000000     0        0 2 1\n'
  } >"$T/net/tcp"
  { echo "$HDR"
    [ -n "$2" ] && printf '  10: 0000000000000000FFFF00000100007F:%04X 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  8111        0 3 1\n' "$2"
  } >"$T/net/tcp6"
}

reset() {
  rm -rf "$T/fake" "$T/state" "$T/radio" "$T/recovery"
  mkdir -p "$T/fake" "$T/radio"
  echo 2540 >"$T/fake/mainpid"
  echo active >"$T/fake/active"
  echo running >"$T/fake/system"
  printf 'hmServerPort=39292\nregaPort=31999\n' >"$T/HMServer.conf"
  tables "" ""
}

run() { # mode (watch|launch) [class]
  FAKE="$T/fake" MAINPID=2540 HMIP_CLASS=${2-de.eq3.ccu.server.ip.HMIPServer} \
    HMIP_WATCH_DELAY=0 HMIP_WATCH_SYSTEMCTL="$T/systemctl" HMIP_WATCH_STATE="$T/state" \
    HMIP_WATCH_CONF="$T/HMServer.conf" HMIP_WATCH_PROC_NET="$T/net" OCCU_RADIO_RUN_DIR="$T/radio" \
    HMIP_WATCH_RECOVERY="$T/recovery" \
    sh "$W" ${1:+--$1} >"$T/out" 2>&1
}
restarts() { grep -c '^--no-block restart hmipserver.service$' "$T/fake/calls" 2>/dev/null || echo 0; }

[ -x "$W" ] && ok "the script is executable" || bad "$W must be executable"

reset; tables 39292 ""
run watch
[ "$(restarts)" = 0 ] && [ ! -s "$T/out" ] && ok "port bound (IPv4): quiet, no restart" || bad "bound v4: $(cat "$T/out") restarts=$(restarts)"

reset; tables "" 39292
run watch
[ "$(restarts)" = 0 ] && [ ! -s "$T/out" ] && ok "port bound (v4-mapped IPv6, as the JVM binds it): quiet" || bad "bound v6: $(cat "$T/out")"

reset
run watch
[ "$(restarts)" = 1 ] && ok "port not bound: one restart" || bad "hang: restarts=$(restarts) $(cat "$T/out")"
grep -q '^<4>lite-hmip-start-watch: port 39292 not bound 0 s after the start' "$T/out" && ok "the warning names the port and the delay" || bad "the line: $(cat "$T/out")"
grep -q '(1 of at most 2 this boot)' "$T/out" && ok "the line counts the restart" || bad "count: $(cat "$T/out")"
[ "$(wc -l <"$T/out")" -eq 1 ] && ok "the first restart of the boot logs one line, nothing else" || bad "extra output: $(cat "$T/out")"
run watch
[ "$(restarts)" = 2 ] && ok "second hang in the same boot: a second restart" || bad "second: restarts=$(restarts)"
run watch
[ "$(restarts)" = 2 ] && ok "third hang: no restart loop" || bad "third: restarts=$(restarts)"
grep -q 'not restarting again (2 restarts this boot, at most 2)' "$T/out" && ok "the limit says so" || bad "limit line: $(cat "$T/out")"

reset; printf 'hmServerPort=40000\n' >"$T/HMServer.conf"; tables 40000 ""
run watch
[ "$(restarts)" = 0 ] && ok "the port from HMServer.conf is the one checked" || bad "conf port: $(cat "$T/out")"
reset; printf 'hmServerPort=40000\n' >"$T/HMServer.conf"; tables 39292 ""
run watch
[ "$(restarts)" = 1 ] && grep -q 'port 40000' "$T/out" && ok "39292 bound but HMServer.conf names 40000: restart" || bad "conf port 2: $(cat "$T/out")"
reset; rm -f "$T/HMServer.conf"; tables 39292 ""
run watch
[ "$(restarts)" = 0 ] && ok "no HMServer.conf: 39292" || bad "default port: $(cat "$T/out")"

reset; echo 3999 >"$T/fake/mainpid"
run watch
[ "$(restarts)" = 0 ] && ok "a newer JVM is the main process (restarted meanwhile): no restart" || bad "mainpid"
reset; echo deactivating >"$T/fake/active"
run watch
[ "$(restarts)" = 0 ] && ok "the unit is stopping: no restart" || bad "deactivating"
reset; echo stopping >"$T/fake/system"
run watch
[ "$(restarts)" = 0 ] && ok "the system shuts down: no restart" || bad "shutdown"
reset; echo 900 >"$T/radio/changing"
run watch
[ "$(restarts)" = 0 ] && ok "a radio change holds the units: no restart" || bad "radio change"
reset; : >"$T/recovery"
run watch
[ "$(restarts)" = 0 ] && ok "the recovery is due: no restart" || bad "recovery"

reset
run watch de.eq3.ccu.server.HMServer
[ "$(restarts)" = 0 ] && [ ! -s "$T/out" ] && ok "HMServer.jar (HmIP none) is not watched" || bad "HMServer.jar"
reset
run watch ""
[ "$(restarts)" = 0 ] && ok "no HMIP_CLASS: not watched" || bad "no class"

# the launcher returns at once and leaves the watch in the background
reset
start=$(date +%s)
FAKE="$T/fake" MAINPID=2540 HMIP_CLASS=de.eq3.ccu.server.ip.HMIPServer HMIP_WATCH_DELAY=1 \
  HMIP_WATCH_SYSTEMCTL="$T/systemctl" HMIP_WATCH_STATE="$T/state" HMIP_WATCH_CONF="$T/HMServer.conf" \
  HMIP_WATCH_PROC_NET="$T/net" OCCU_RADIO_RUN_DIR="$T/radio" HMIP_WATCH_RECOVERY="$T/recovery" \
  "$W" >"$T/out" 2>&1
rc=$?
[ "$rc" = 0 ] && [ $(( $(date +%s) - start )) -le 1 ] && ok "the launcher returns at once with 0" || bad "launcher rc=$rc"
i=0
while [ "$(restarts)" = 0 ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
[ "$(restarts)" = 1 ] && ok "the background watch restarts after its delay" || bad "background watch: restarts=$(restarts)"
reset
FAKE="$T/fake" MAINPID=2540 HMIP_CLASS=de.eq3.ccu.server.HMServer HMIP_WATCH_DELAY=0 \
  HMIP_WATCH_SYSTEMCTL="$T/systemctl" HMIP_WATCH_STATE="$T/state" HMIP_WATCH_CONF="$T/HMServer.conf" \
  HMIP_WATCH_PROC_NET="$T/net" OCCU_RADIO_RUN_DIR="$T/radio" HMIP_WATCH_RECOVERY="$T/recovery" \
  "$W" >"$T/out" 2>&1
sleep 0.5
[ "$(restarts)" = 0 ] && ok "the launcher starts no watch for HMServer.jar" || bad "launcher HMServer.jar"

# the unit: the watch after the ready step, as root, its failure ignored
ready=$(grep -n '^ExecStartPost=+/usr/bin/occulited radio ready hmipserver$' "$U" | cut -d: -f1)
watch=$(grep -n '^ExecStartPost=-+/usr/libexec/occu/lite-hmip-start-watch$' "$U" | cut -d: -f1)
if [ -n "$ready" ] && [ -n "$watch" ] && [ "$watch" -gt "$ready" ]; then
  ok "hmipserver.service runs the watch after the ready step"
else
  bad "hmipserver.service: ExecStartPost=-+/usr/libexec/occu/lite-hmip-start-watch after the ready step (ready=$ready watch=$watch)"
fi
grep -q '^KillMode=control-group$' "$U" && ok "the unit's stop ends the watch (KillMode=control-group)" || bad "KillMode=control-group"

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
