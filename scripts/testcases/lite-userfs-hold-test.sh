#!/bin/sh
# openccu-lite (B-368): lite-userfs-hold - S03CheckUserFSResize and S04CheckFactoryReset run with
# udev's event queue held, and the queue is released (and udev settled) however the script ends:
# its own exit code passes through, a TERM still releases it, and without udevd (a container) the
# script runs unheld. And the two units run their scripts through it.
#
# Usage: sh scripts/testcases/lite-userfs-hold-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
EXT="$HERE/buildroot-external"
TOOL="$EXT/overlay/lite/usr/libexec/occu/lite-userfs-hold"
U="$EXT/overlay/lite/usr/lib/systemd/system"
[ -f "$TOOL" ] || { echo "lite-userfs-hold not found under $HERE"; exit 2; }

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

# udevadm: logs its arguments; FAKE_UDEV_DOWN makes "control" fail as without udevd
cat >"$T/udevadm" <<'EOS'
#!/bin/sh
echo "udevadm $*" >>"$FAKE_LOG"
case "$1" in control) [ -z "${FAKE_UDEV_DOWN:-}" ] || exit 1;; esac
exit 0
EOS
# the script under the hold: logs, then exits with its first argument
cat >"$T/script" <<'EOS'
#!/bin/sh
echo "script $*" >>"$FAKE_LOG"
exit "$1"
EOS
# a script whose runner is stopped meanwhile (systemd's TERM to the unit's cgroup)
cat >"$T/term-script" <<'EOS'
#!/bin/sh
echo "script term" >>"$FAKE_LOG"
kill -TERM "$PPID"
exit 0
EOS
chmod +x "$T/udevadm" "$T/script" "$T/term-script"
export FAKE_LOG="$T/log" LITE_UDEVADM="$T/udevadm"

run() { : >"$FAKE_LOG"; sh "$TOOL" "$@"; rc=$?; got=$(tr '\n' '|' <"$FAKE_LOG"); }

run "$T/script" 0
[ "$rc" = 0 ] && ok "a script that succeeds: exit 0" || bad "a script that succeeds: exit $rc"
[ "$got" = "udevadm control --stop-exec-queue|script 0|udevadm control --start-exec-queue|udevadm settle --timeout=60|" ] \
  && ok "held before the script, released and settled after it" || bad "the order: $got"

run "$T/script" 3
[ "$rc" = 3 ] && ok "the script's exit code passes through" || bad "a script that exits 3: exit $rc"
case "$got" in *"script 3|udevadm control --start-exec-queue|"*) ok "released after a failing script" ;; *) bad "a failing script left the queue held: $got" ;; esac

run "$T/term-script"
[ "$rc" = 143 ] && ok "stopped by TERM: exit 143" || bad "stopped by TERM: exit $rc"
case "$got" in *"script term|udevadm control --start-exec-queue|udevadm settle"*) ok "released after a TERM" ;; *) bad "a TERM left the queue held: $got" ;; esac
n=$(grep -c -- '--start-exec-queue' "$FAKE_LOG")
[ "$n" = 1 ] && ok "released once" || bad "released $n times"

FAKE_UDEV_DOWN=1 run "$T/script" 0
[ "$rc" = 0 ] && [ "$got" = "udevadm control --stop-exec-queue|script 0|" ] && ok "without udevd the script runs unheld" || bad "without udevd: exit $rc, $got"

for pair in occu-userfs-resize.service:S03CheckUserFSResize occu-factory-reset.service:S04CheckFactoryReset; do
  u=${pair%%:*}; s=${pair#*:}
  if grep -qx "ExecStart=/usr/libexec/occu/lite-userfs-hold /etc/init.d/$s.script start" "$U/$u"; then
    ok "$u runs $s under the hold"
  else
    bad "$u must run /etc/init.d/$s.script start through lite-userfs-hold"
  fi
  grep -qx "SyslogIdentifier=$s.script" "$U/$u" && ok "$u: the journal names $s.script" || bad "$u must keep SyslogIdentifier=$s.script"
done
[ -x "$TOOL" ] && ok "lite-userfs-hold is executable" || bad "lite-userfs-hold must be executable (0755)"

[ "$fails" = 0 ] && { echo "lite-userfs-hold: all ok"; exit 0; }
echo "lite-userfs-hold: $fails failed"; exit 1
