#!/bin/sh
# openccu-lite (task 310): lite-qemu-test.sh's addon e2e lost dev.35's and dev.36's runs to GitHub's
# unauthenticated rate limit (60 calls an hour per public address, which the guest shares with the
# runner and everything behind it). github_budget reads the address's budget before the e2e and
# waits for the reset when too little is left, within a bound. Here the function is taken from the
# script (awk) and runs against a stub curl that answers GET /rate_limit from a script of
# "<remaining> <seconds to the reset>" lines (the last one repeats) and a stub sleep that only
# counts: enough left at once, too little and a reset within the bound (it waits, then goes on),
# a reset past the bound (it fails and says when), an unreadable answer (it goes on).
#
# Usage: sh scripts/testcases/lite-qemu-ratelimit-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
S="$HERE/scripts/lite-qemu-test.sh"
[ -f "$S" ] || { echo "lite-qemu-test.sh not found at $S"; exit 2; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

awk '/^github_budget\(\) \{$/ {p=1} p {print} p && /^\}$/ {p=0}' "$S" >"$T/fn.sh"
grep -q '^github_budget() {$' "$T/fn.sh" && ok "github_budget found in lite-qemu-test.sh" || { bad "github_budget() not found in lite-qemu-test.sh"; # task 376: occulited's refusal by GitHub's quota is the environment's failure, any other the image's
grep -q '^is_quota() { case "$1" in \*"rate limit"\*' "$S" && ok "is_quota found in lite-qemu-test.sh" || bad "is_quota() not found in lite-qemu-test.sh"
eval "$(grep '^is_quota() {' "$S")"
is_quota '{"phase":"failed","error":"GitHub rate limit, try again in 42 min: the release list of rdmtc/RedMatic cannot be read now"}' && ok "the install's quota refusal is the environment" || bad "quota refusal not recognised"
is_quota '{"phase":"failed","error":"checksum mismatch"}' && bad "an image failure taken for the quota" || ok "another install failure is the image's"
grep -q 'exit 3; fi' "$S" && ok "only the quota failed: exit 3" || bad "no exit 3 for a quota-only failure"
grep -q 'once more"; try=2; relogin "after the wait for GitHub'"'"'s quota" || break; continue' "$S" && ok "a quota refusal is tried once more after the reset, with a new login (B-354)" || bad "no retry with a new login after the reset"

echo "failures: $fails"; exit 1; }

mkdir -p "$T/bin"
cat >"$T/bin/curl" <<EOS
#!/bin/sh
n=\$(cat "$T/calls" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n >"$T/calls"
l=\$(sed -n "\${n}p" "$T/answers"); [ -n "\$l" ] || l=\$(tail -n 1 "$T/answers")
case "\$l" in
  garbage) echo "<html>no</html>";;
  *) set -- \$l; printf '{"resources":{"core":{"limit":60,"remaining":%s,"reset":%s,"used":0}}}\n' "\$1" "\$((\$(date +%s) + \$2))";;
esac
EOS
cat >"$T/bin/sleep" <<EOS
#!/bin/sh
n=\$(cat "$T/sleeps" 2>/dev/null || echo 0); echo \$((n + \$1)) >"$T/sleeps"
EOS
chmod +x "$T/bin/curl" "$T/bin/sleep"

run() { # <need> <max wait> <answers...>: $out, $rc, $calls, $slept
  need=$1; max=$2; shift 2
  rm -f "$T/calls" "$T/sleeps"; : >"$T/answers"; for a in "$@"; do echo "$a" >>"$T/answers"; done
  out=$(PATH="$T/bin:$PATH" sh -c ". '$T/fn.sh'; qemu_check() { :; }; github_budget $need $max" 2>"$T/err")
  rc=$?
  calls=$(cat "$T/calls" 2>/dev/null || echo 0); slept=$(cat "$T/sleeps" 2>/dev/null || echo 0)
}

run 30 3900 "57 2000"
[ "$rc" = 0 ] && [ "$out" = "GitHub: 57 of 60 calls left (need 30)" ] && ok "enough left: '$out'" || bad "enough left: rc $rc '$out'"
[ "$slept" = 0 ] && [ "$calls" = 1 ] && ok "and no waiting" || bad "enough left, but slept ${slept}s in $calls calls"

run 30 3900 "5 100" "60 3600"
[ "$rc" = 0 ] && ok "too little, reset within the bound: goes on after the reset: '$out'" || bad "reset within the bound: rc $rc '$out'"
case "$out" in *"60 of 60 calls left after waiting"*) ok "and says it waited";; *) bad "no 'after waiting' in '$out'";; esac
[ "$slept" -ge 100 ] && [ "$slept" -le 180 ] && ok "waited for the reset (${slept}s)" || bad "waited ${slept}s for a reset 100 s away"
grep -q "waiting 10[0-9]s for the reset\|waiting 9[0-9]s for the reset" "$T/err" && ok "and announced the wait" || bad "the wait was not announced: $(cat "$T/err")"

run 30 3900 "5 5000"
[ "$rc" = 1 ] && ok "reset past the bound: refused" || bad "reset past the bound: rc $rc '$out'"
case "$out" in *"more than the 3900s"*) ok "and says when: '$out'";; *) bad "no reason in '$out'";; esac
[ "$slept" = 0 ] && ok "without waiting first" || bad "slept ${slept}s before refusing"

run 30 3900 "5 100" "5 3600"
[ "$rc" = 1 ] && ok "still too little after the reset (another user of the address): refused" || bad "still too little after the reset: rc $rc '$out'"

run 30 3900 garbage
[ "$rc" = 0 ] && case "$out" in *"could not be read; going on"*) true;; *) false;; esac && ok "unreadable answer: goes on: '$out'" || bad "unreadable answer: rc $rc '$out'"

run 0 0 "12 3000"
[ "$rc" = 0 ] && [ "$out" = "GitHub: 12 of 60 calls left (need 0)" ] && ok "the count after the e2e: '$out'" || bad "the count after the e2e: rc $rc '$out'"

# the e2e asks before its catalogue refresh, with room for the refresh and the installs
grep -q 'R=$(github_budget "${LITE_QEMU_GITHUB_NEED:-[2-9][0-9]}" "${LITE_QEMU_GITHUB_WAIT:-[0-9]*}") || fail' "$S" \
  && ok "the addon e2e checks the budget first (20 calls or more)" || bad "the addon e2e does not call github_budget with a need of 20 or more"
awk '/github_budget "\$\{LITE_QEMU_GITHUB_NEED/ && !b {b=NR} /catalog\/refresh/ && !r {r=NR} END {exit !(b && r && b < r)}' "$S" \
  && ok "before the catalogue refresh" || bad "github_budget is not called before the catalogue refresh"

# B-354: the session from the setup idles out during a wait for the quota's reset (beta.9's first run:
# the install refused with 401); relogin logs in with the setup's account and takes the new session
grep -q '^  relogin() {$' "$S" && ok "relogin found in lite-qemu-test.sh" || bad "relogin() not found in lite-qemu-test.sh"
awk '/^  relogin\(\) \{$/ {p=1} p {print} p && /^  \}$/ {p=0}' "$S" >"$T/relogin.sh"
mkdir -p "$T/bin-login"
cat >"$T/bin-login/curl" <<EOS
#!/bin/sh
echo "\$*" >>"$T/login-calls"
cat "$T/login-answer"
EOS
chmod +x "$T/bin-login/curl"
relog() { # <answer>: $out, $rc, the SID and AUTH after it
  printf '%s' "$1" >"$T/login-answer"; rm -f "$T/login-calls"
  out=$(PATH="$T/bin-login:$PATH" sh -c "WORK='$T' BASE=http://127.0.0.1:1 QU=litetest QP=pw SID=old AUTH='Authorization: Bearer old'
    say() { echo \"say \$*\"; }; fail() { echo \"fail \$*\"; }; . '$T/relogin.sh'; relogin why; rc=\$?; echo \"SID=\$SID\"; echo \"AUTH=\$AUTH\"; exit \$rc")
  rc=$?
}
relog '{"sid":"s3cr3t","user":"litetest","role":"admin"}'
[ "$rc" = 0 ] && echo "$out" | grep -qx 'SID=s3cr3t' && echo "$out" | grep -qx 'AUTH=Authorization: Bearer s3cr3t' && ok "relogin takes the new session" || bad "relogin: rc $rc $out"
grep -q -- '/api/auth/v1/login' "$T/login-calls" && grep -q -- '"username":"litetest","password":"pw"' "$T/login-calls" && ok "with the setup's account at the login" || bad "login call: $(cat "$T/login-calls")"
relog '{"error":"invalid credentials"}'
[ "$rc" != 0 ] && echo "$out" | grep -q '^fail no session from a new login (why)' && echo "$out" | grep -qx 'SID=old' && ok "a refused login fails the run and keeps nothing new" || bad "refused login: rc $rc $out"
# an install that answers 401 logs in again, once
grep -q 'if \[ "$code" = 401 \] && \[ -z "$relogged" \]; then' "$S" && grep -q 'relogin "the install of $id answered 401" && continue' "$S" \
  && ok "an install answering 401 logs in again and tries once more" || bad "no new login on a 401 from the install"
grep -q 'AUTH="Authorization: Bearer $SID"' "$T/relogin.sh" && ok "relogin sets the header the calls use" || bad "relogin does not set AUTH"

echo "failures: $fails"
[ "$fails" = 0 ]
