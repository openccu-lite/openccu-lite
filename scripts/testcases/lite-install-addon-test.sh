#!/bin/sh
# openccu-lite: /bin/install_addon's hand-over to occulited (openccu-lite B-274).
#
# Outside occulited's install scope, with the install token and curl, the archive goes to
# occulited's POST /api/system/v1/addons/install/local and the script exits with the installer's
# code from the answer; inside the scope, without a token, or when occulited does not take it
# (not listening, 401, 404) the base install runs as always - seen here as the script's test stop
# right before it (exit 99), with the archive put back where it was. A 409 or a
# connection that broke after the upload installs nothing (exit 1). curl is a fake on PATH that
# records its arguments and answers what the case asks for; nothing needs root. The base install's
# failure exits (101, 102, 104, 105) run on a copy whose /usr/local/tmp is the test's own directory:
# its unpack directory is gone afterwards. update_script's output (occulited B-167) runs on the same
# copy: a failing script's last lines are the installer's output, bounded; a succeeding one's are
# not shown; a daemon the script leaves behind does not hold the install. The body below the
# hand-over is the base copy's but for that block.
#
# Usage: sh scripts/testcases/lite-install-addon-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPT="$HERE/buildroot-external/overlay/lite/bin/install_addon"
BASE="$HERE/buildroot-external/overlay/base/bin/install_addon"
[ -f "$SCRIPT" ] || { echo "install_addon not found at $SCRIPT"; exit 2; }

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tmp" "$T/bin"
LOG="$T/calls"
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails+1)); }

# the fake curl: records its arguments and the uploaded file's content, writes the headers and
# the body the case sets, exits with FAKE_CURL_RC
cat > "$T/bin/curl" <<'CURL'
#!/bin/sh
echo "curl $*" >> "$FAKE_LOG"
out= hdr= up=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift ;;
    -D) hdr=$2; shift ;;
    -T) up=$2; shift ;;
  esac
  shift
done
[ -n "$up" ] && echo "uploaded $(cat "$up")" >> "$FAKE_LOG"
[ -n "$hdr" ] && printf "$FAKE_HEADERS" > "$hdr"
[ -n "$out" ] && printf "$FAKE_BODY" > "$out"
exit "${FAKE_CURL_RC:-0}"
CURL
chmod 755 "$T/bin/curl"
printf 'secret\n' > "$T/token"
printf '0::/system.slice/sshd.service\n' > "$T/cg-ssh"
printf '0::/system.slice/occulite-addon-08e4e24f.scope\n' > "$T/cg-scope"

run() { # cgroup token rc headers body -> $code, $stdout, $stderr
  : > "$LOG"
  printf 'ARCHIVE' > "$T/tmp/new_addon.tar.gz"
  OCCU_INSTALL_TEST_STOP=99 OCCU_INSTALL_TMP="$T/tmp" OCCU_INSTALL_TOKEN_FILE="$2" OCCU_INSTALL_CGROUP="$1" \
    FAKE_LOG="$LOG" FAKE_CURL_RC="$3" FAKE_HEADERS="$4" FAKE_BODY="$5" PATH="$T/bin:$PATH" \
    sh "$SCRIPT" > "$T/stdout" 2> "$T/stderr"
  code=$?
}
leftover() { # the first entry of the tmp directory other than the archive, "" for none
  for f in "$T/tmp"/* "$T/tmp"/.[!.]*; do
    [ -e "$f" ] || continue
    [ "${f##*/}" = new_addon.tar.gz ] || { echo "${f##*/}"; return; }
  done
}

# 1. from ssh with the token: handed over, the installer's code and output are the script's
run "$T/cg-ssh" "$T/token" 0 'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\nX-Occulite-Addon-Exit: 10\r\nContent-Type: text/plain\r\n\r\n' '[manifest] hmm: applied\n'
[ "$code" = 10 ] && ok "handed over: the installer's exit code" || fail "handed over: exit $code"
grep -q '^\[manifest\] hmm: applied$' "$T/stdout" && ok "handed over: occulited's output on stdout" || fail "handed over: stdout $(cat "$T/stdout")"
grep -q 'Authorization: Bearer secret' "$LOG" && grep -q -- '-X POST' "$LOG" && grep -q 'addons/install/local' "$LOG" && ok "handed over: POST with the token to the local route" || fail "handed over: $(cat "$LOG")"
grep -q '^uploaded ARCHIVE$' "$LOG" && ok "handed over: the archive is the body" || fail "handed over: upload $(cat "$LOG")"
[ ! -e "$T/tmp/new_addon.tar.gz" ] && [ -z "$(leftover)" ] && ok "handed over: nothing left in the tmp directory" || fail "handed over: left $(ls "$T/tmp")"

# 2. a failed install: 422 with its code
run "$T/cg-ssh" "$T/token" 0 'HTTP/1.1 422 Unprocessable Entity\r\nX-Occulite-Addon-Exit: 104\r\n\r\n' ''
[ "$code" = 104 ] && ok "a failed install: its exit code" || fail "a failed install: exit $code"

# 3. inside occulited's install scope: no hand-over, the base install runs
run "$T/cg-scope" "$T/token" 0 '' ''
[ ! -s "$LOG" ] && ok "in the install scope: curl is not called" || fail "in the install scope: $(cat "$LOG")"
[ "$code" = 99 ] && [ -f "$T/tmp/new_addon.tar.gz" ] && ok "in the install scope: the base install runs" || fail "in the install scope: exit $code"

# 4. without the token: the base install runs
run "$T/cg-ssh" "$T/none" 0 '' ''
[ ! -s "$LOG" ] && [ "$code" = 99 ] && ok "without a token: the base install" || fail "without a token: exit $code, $(cat "$LOG")"

# 5. occulited not listening (curl 7), or refusing the token (401), or an older one without the
#    route (404): the archive goes back and the base install runs
for c in "curl 7|7|" "HTTP 401|0|HTTP/1.1 401 Unauthorized\r\n\r\n" "HTTP 404|0|HTTP/1.1 404 Not Found\r\n\r\n"; do
  label=${c%%|*} rest=${c#*|}
  run "$T/cg-ssh" "$T/token" "${rest%%|*}" "${rest#*|}" ''
  [ "$code" = 99 ] && [ "$(cat "$T/tmp/new_addon.tar.gz" 2>/dev/null)" = ARCHIVE ] && [ -z "$(leftover)" ] \
    && ok "not taken ($label): back to the base install" || fail "not taken ($label): exit $code, $(ls "$T/tmp")"
  grep -q 'installing without it' "$T/stderr" || fail "not taken ($label): no note on stderr"
done

# 6. another install runs (409), or the connection broke after the upload (curl 52): nothing here
for c in "HTTP 409|0|HTTP/1.1 409 Conflict\r\n\r\n" "curl 52|52|"; do
  label=${c%%|*} rest=${c#*|}
  run "$T/cg-ssh" "$T/token" "${rest%%|*}" "${rest#*|}" ''
  [ "$code" = 1 ] && [ ! -e "$T/tmp/new_addon.tar.gz" ] && [ -z "$(leftover)" ] \
    && ok "refused ($label): exit 1, nothing installed" || fail "refused ($label): exit $code, $(ls "$T/tmp")"
done

# 7. the base install's failure exits leave no unpack directory behind: a copy of the script whose
#    /usr/local/tmp is the test's directory, run without the test stop and without a token (no
#    hand-over); every exit taken here comes before update_script, but should one reach it, mount,
#    sync and ldconfig are stand-ins. The base body uses [[ ]] (busybox ash on the system): run it
#    with bash, which has it, where dash would skip every check
B="$T/base"
sed -e "s#/usr/local/tmp#$B/tmp#g" -e "s#/sbin/ldconfig#$T/bin/ldconfig#g" "$SCRIPT" > "$B.sh"
for f in mount sync ldconfig; do printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$f" "$LOG" > "$T/bin/$f"; chmod 755 "$T/bin/$f"; done
BSH=$(command -v bash || command -v busybox) || { echo "lite-install-addon-test: needs bash or busybox"; exit 2; }
[ "${BSH##*/}" = busybox ] && BSH="$BSH sh"
base_run() { # archive-maker -> $code, the tmp directory's content in $left
  rm -rf "$B"; mkdir -p "$B/tmp" "$B/src"; : > "$LOG"
  "$@"
  # shellcheck disable=SC2086 # BSH is "bash" or "busybox sh"
  UPDATEDIR=/must/not/be/removed OCCU_INSTALL_TOKEN_FILE="$T/none" OCCU_INSTALL_CGROUP="$T/cg-ssh" PATH="$T/bin:$PATH" \
    $BSH "$B.sh" > "$T/stdout" 2> "$T/stderr"
  code=$?
  left=$(ls -A "$B/tmp")
  [ -n "${REACHES:-}" ] || [ ! -s "$LOG" ] || fail "exit $code reached mount, sync or ldconfig: $(cat "$LOG")"
}
no_script() { echo payload > "$B/src/readme.txt"; tar -C "$B/src" -czf "$B/tmp/new_addon.tar.gz" readme.txt; }
not_exec()  { echo 'exit 0' > "$B/src/update_script"; chmod 644 "$B/src/update_script"; tar -C "$B/src" -czf "$B/tmp/new_addon.tar.gz" update_script; }
bad_sum()   { printf '#!/bin/sh\nexit 0\n' > "$B/src/update_script"; chmod 755 "$B/src/update_script"
              echo "0000000000000000000000000000000000000000000000000000000000000000  update_script" > "$B/src/addon.sha256"
              tar -C "$B/src" -czf "$B/tmp/new_addon.tar.gz" update_script addon.sha256; }
junk()      { echo 'not a tar archive' > "$B/tmp/new_addon.tar.gz"; }
base_run no_script
[ "$code" = 104 ] && [ -z "$left" ] && ok "no update_script (104): nothing left in the tmp directory" || fail "no update_script: exit $code, left '$left'"
base_run not_exec
[ "$code" = 104 ] && [ -z "$left" ] && ok "update_script not executable (104): nothing left" || fail "update_script not executable: exit $code, left '$left'"
base_run bad_sum
case "$code" in
  105|106) [ -z "$left" ] && ok "a wrong checksum ($code): nothing left" || fail "a wrong checksum: left '$left'" ;;
  *) fail "a wrong checksum: exit $code, left '$left'" ;;
esac
base_run junk
# a broken archive (102): the unpack directory goes, the archive stays where the caller put it, as in the base
[ "$code" = 102 ] && [ "$left" = new_addon.tar.gz ] && ok "a broken archive (102): only the archive is left" || fail "a broken archive: exit $code, left '$left'"
base_run true
[ "$code" = 101 ] && [ -z "$left" ] && ok "no archive (101): nothing made" || fail "no archive: exit $code, left '$left'"

# 8. update_script's output (occulited B-167): nothing of a script that succeeds or asks for a
#    reboot, the last 20 lines of one that fails - bounded in length - and its exit code; the file
#    it went to is gone afterwards, and a daemon the script leaves behind does not hold the install
script_pkg() { # the update_script's body
  printf '#!/bin/sh
%s
' "$1" > "$B/src/update_script"; chmod 755 "$B/src/update_script"
  tar -C "$B/src" -czf "$B/tmp/new_addon.tar.gz" update_script
}
mkdir -p "$T/run"
export OCCU_INSTALL_RUN="$T/run"
REACHES=1
wrong_arch() { script_pkg 'echo "copying files"; echo "this package is for aarch64, this system is x86_64: take battery-x86_64-1.5.5.tar.gz" >&2; exit 13'; }
base_run wrong_arch
[ "$code" = 13 ] && grep -qx 'update_script (exit 13):' "$T/stdout" && grep -q 'this package is for aarch64, this system is x86_64' "$T/stdout" && grep -q 'copying files' "$T/stdout" \
  && ok "a failing update_script: its exit code, and its output (stdout and stderr) as the installer's" || fail "a failing update_script: exit $code, stdout '$(cat "$T/stdout")'"
[ -z "$(ls -A "$T/run")" ] && [ -z "$left" ] && ok "its output file and the unpack directory are gone" || fail "left behind: run '$(ls -A "$T/run")', tmp '$left'"
succeeds() { script_pkg 'echo "all fine, a lot of chatter"; exit 0'; }
base_run succeeds
[ "$code" = 0 ] && [ ! -s "$T/stdout" ] && [ -z "$(ls -A "$T/run")" ] && ok "an update_script that succeeds: no output" || fail "a succeeding update_script: exit $code, stdout '$(cat "$T/stdout")'"
reboots() { script_pkg 'echo "installed, reboot please"; exit 10'; }
base_run reboots
[ "$code" = 10 ] && [ ! -s "$T/stdout" ] && ok "an update_script that asks for a reboot (10): no output" || fail "exit 10: exit $code, stdout '$(cat "$T/stdout")'"
chatty() { script_pkg 'i=0; while [ $i -lt 3000 ]; do echo "line $i $(printf %%0600d 0)"; i=$((i+1)); done; echo "the last line"; exit 1'; }
base_run chatty
lines=$(wc -l < "$T/stdout"); longest=$(awk '{ if (length($0) > m) m = length($0) } END { print m }' "$T/stdout")
[ "$code" = 1 ] && [ "$lines" -le 21 ] && [ "$longest" -le 400 ] && [ "$(tail -n 1 "$T/stdout")" = "the last line" ] \
  && ok "a chatty failing script: its last 20 lines at most, each cut at 400 characters" || fail "a chatty script: exit $code, $lines lines, longest $longest"
silent() { script_pkg 'exit 13'; }
base_run silent
[ "$code" = 13 ] && [ ! -s "$T/stdout" ] && ok "a failing script that says nothing: the exit code alone" || fail "a silent failing script: exit $code, stdout '$(cat "$T/stdout")'"
# a daemon the script starts keeps the script's output open; the install does not wait for it
lingers() { script_pkg "(sleep 20; echo late) & echo started; exit 1"; }
start=$(date +%s)
base_run lingers
took=$(( $(date +%s) - start ))
[ "$code" = 1 ] && [ "$took" -lt 10 ] && grep -qx started "$T/stdout" && ok "a daemon left behind does not hold the install (${took} s)" || fail "a lingering daemon: exit $code after ${took} s, stdout '$(cat "$T/stdout")'"
# no place for the output: the install runs all the same, without it
OCCU_INSTALL_RUN="$T/no-such-dir" base_run wrong_arch
[ "$code" = 13 ] && [ ! -s "$T/stdout" ] && ok "no place for the output: the install runs, the exit code alone" || fail "no output directory: exit $code, stdout '$(cat "$T/stdout")'"
unset REACHES

# 9. everything below the hand-over is the base copy unchanged - but for update_script's output:
#    the lite body with its marked block put back to the base's two lines is the base's body
lite_body=$(sed -n '/^# check if we have an update archive/,$p' "$SCRIPT" | awk '
  /^# openccu-lite \(occulited B-167\)/ { skip = 1 }
  skip && /^\[ "\$\{LITE_OUT\}" = \/dev\/null \] \|\| rm -f/ { skip = 0; print "(cd \"${UPDATEDIR}\" && ./update_script HM-RASPBERRYMATIC 2>/dev/null >/dev/null)"; print "RESULT=$?"; next }
  !skip { print }')
if [ "$lite_body" = "$(sed -n '/^# check if we have an update archive/,$p' "$BASE")" ]; then
  ok "the install itself is the base copy's, but for update_script's output"
else
  fail "the lite install_addon's body differs from overlay/base/bin/install_addon beyond update_script's output"
fi

[ "$fails" -eq 0 ] && { echo "lite-install-addon-test: all passed"; exit 0; }
echo "lite-install-addon-test: $fails failed"; exit 1
