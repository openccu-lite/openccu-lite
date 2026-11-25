#!/bin/sh
# openccu-lite: the recovery system's lighttpd while it installs an update (B-343, issue #21).
#
# The recovery answers every unknown path with a 301 to its own page. A client of the running
# system - Home Assistant's Loom client on /addons/loom/api/v1/events - took that 301 for a final
# answer and stopped reconnecting. So the paths the running system's clients poll answer 503 with
# Retry-After there, and browsers keep the redirect:
#
#   - static: the recovery's lighttpd.conf sends /api/, /addons/ and /.well-known/acme-challenge/
#     to lite_unavailable.cgi, which is executable in git and parses; with an occulited checkout,
#     every URL prefix its lighttpd fragment proxies is among them (a new one fails here);
#   - a real lighttpd (Alpine's, in a container; docker and apk over the network): the recovery's
#     configuration parses (-tt) and, with the recovery's /www, curl gets 503 + Retry-After + JSON
#     on the API (GET, POST with a body, HEAD, a WebSocket upgrade), 503 + text on the addons and
#     the ACME challenge, and the 301 to / on a browser path, a near miss (/apix) and /api itself,
#     while / is the recovery's page. Skipped with a note when docker is not available.
#
# Task 505 adds a second container: the recovery's HTTPS instance (S51lighttpd-ssl) beside port 80 -
# for a good, an expired, a missing, an empty, a truncated, a garbage, a huge certificate, a foreign
# key, a symlink elsewhere, a fifo and port 443 taken by another program, port 80 serves the menu,
# the look and the 503 JSON without a redirect and without HSTS, and 443 the system's certificate in
# the good cases only; the 443 instance killed, port 80 still answers; the install status (the update
# object, /fwinstall.log as text/plain with ranges) on both ports.
#
# The recovery's conf.d lacks access_log.conf, debug.conf and dirlisting.conf (Buildroot's
# lighttpd package installs them); the container takes the fork's base overlay's copies, and drops
# mod_openssl, which Alpine's lighttpd has built in.
#
# Usage: sh scripts/testcases/lite-recovery-lighttpd-test.sh [occulited checkout]   (default: ../occulited)
#        ALPINE_IMAGE=alpine:3.22 is the default image.
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
REC="$HERE/buildroot-external/package/recovery-system/external"
CONF="$REC/overlay/base/etc/lighttpd/lighttpd.conf"
CGI_REL="buildroot-external/package/recovery-system/external/overlay/base/www/cgi-bin/lite_unavailable.cgi"
CGI="$HERE/$CGI_REL"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

# --- static -------------------------------------------------------------------------------------
pat=$(sed -n 's/^\$HTTP\["url"\] =~ "\(.*\)" {$/\1/p' "$CONF" | head -1)
[ "$pat" = '^/(api|addons|\.well-known/acme-challenge)/' ] && ok "lighttpd.conf: the URL block is $pat" || bad "lighttpd.conf: the URL block is '$pat'"
awk '/^\$HTTP\["url"\] =~ / { b=1; next } b && /server\.error-handler-404 = "\/cgi-bin\/lite_unavailable\.cgi"/ { f=1 } b && /^}/ { b=0 } END { exit !f }' "$CONF" &&
  ok "lighttpd.conf: the block's 404 handler is lite_unavailable.cgi" || bad "lighttpd.conf: lite_unavailable.cgi is not the block's 404 handler"
grep -q '^server.error-handler-404 = "/notexisting"$' "$CONF" && ok "lighttpd.conf: other paths still go to /notexisting (the 301 to /)" || bad "lighttpd.conf: the global 404 redirect is gone"
[ -f "$CGI" ] && sh -n "$CGI" && ok "lite_unavailable.cgi parses" || bad "lite_unavailable.cgi is missing or does not parse"
mode=$(git -C "$HERE" ls-files -s -- "$CGI_REL" 2>/dev/null | cut -d' ' -f1)
case "$mode" in
  100755) ok "lite_unavailable.cgi is executable in git" ;;
  "") if [ -x "$CGI" ]; then ok "lite_unavailable.cgi is executable (not in git yet)"; else bad "lite_unavailable.cgi is not executable"; fi ;;
  *) bad "lite_unavailable.cgi has mode $mode in git" ;;
esac

OCC=$(cd "${1:-$HERE/../occulited}" 2>/dev/null && pwd) || OCC=""
if [ -n "$OCC" ] && [ -f "$OCC/deploy/lighttpd/occulited.conf" ]; then
  # the prefixes occulited's fragment proxies: $HTTP["url"] =~ "^/<prefix>/" (the negated catch-all
  # for the shell is a browser path and stays redirected)
  prefixes=$(sed -n 's|^\$HTTP\["url"\] =~ "^/\([^"]*\)/" {$|\1|p' "$OCC/deploy/lighttpd/occulited.conf" | sort -u)
  [ -n "$prefixes" ] && ok "occulited's fragment proxies: $(echo $prefixes)" || bad "no URL prefix found in occulited's fragment"
  ours="|$(printf '%s' "$pat" | sed 's/^\^\/(\(.*\))\/$/\1/')|"
  for p in $prefixes; do
    case "$ours" in
      *"|$p|"*) ok "the recovery answers 503 on occulited's /$p/" ;;
      *) bad "occulited's fragment proxies /$p/, the recovery redirects it" ;;
    esac
  done
else
  echo "skip the prefix comparison: no occulited checkout at ${1:-$HERE/../occulited}"
fi

# --- a real lighttpd ------------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "skip the container part: docker is not available"
else
  out="${TMPDIR:-/tmp}/lite-recovery-lighttpd.$$"
  if docker run --rm -i \
       -v "$REC/overlay/base/etc/lighttpd:/src/lighttpd:ro" \
       -v "$REC/overlay/base/www:/src/www-lite:ro" \
       -v "$REC/package/hm-platform/rootfs-overlay/www:/src/www-platform:ro" \
       -v "$HERE/buildroot-external/overlay/base/etc/lighttpd/conf.d:/src/conf.d-base:ro" \
       "${ALPINE_IMAGE:-alpine:3.22}" sh -s >"$out" 2>&1 <<'INNER'
set -u
apk add --no-cache lighttpd curl >/tmp/apk.log 2>&1 || { cat /tmp/apk.log; exit 3; }
lighttpd -v
f=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; f=$((f+1)); }
rm -rf /etc/lighttpd && cp -a /src/lighttpd /etc/lighttpd
for c in access_log.conf debug.conf dirlisting.conf; do cp /src/conf.d-base/$c /etc/lighttpd/conf.d/; done
sed -i '/"mod_openssl"/d' /etc/lighttpd/modules.conf
mkdir -p /www /var/log /var/run /var/lib/lighttpd /var/cache/lighttpd /usr/local/tmp /dev/shm
cp -a /src/www-platform/. /www/ && cp -a /src/www-lite/. /www/
lighttpd -tt -f /etc/lighttpd/lighttpd.conf >/tmp/tt.log 2>&1 && ok "lighttpd -tt parses the recovery's configuration" || { cat /tmp/tt.log; bad "lighttpd -tt"; }
lighttpd -D -f /etc/lighttpd/lighttpd.conf >/tmp/run.log 2>&1 &
pid=$!
# B-349: a lighttpd that does not listen fails here, not as a wrong answer further down
i=0; until curl -s -o /dev/null --max-time 1 http://127.0.0.1/; do
  i=$((i+1)); [ $i -ge 300 ] && { cat /tmp/run.log; echo "FAIL lighttpd did not listen within 30 s"; exit 1; }; sleep 0.1
done
H=/tmp/h; B=/tmp/b
req() { rm -f $H $B; curl -s -D $H -o $B "$@" >/dev/null; sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' $H; }
hdr() { sed -n "s/^$1: *\(.*\)\r\$/\1/Ip" $H | head -1; }

# the API: 503, Retry-After, JSON, no redirect - every method and the change stream's upgrade
for m in GET POST HEAD WS; do
  case $m in
    GET)  s=$(req http://127.0.0.1/api/system/v1/status) ;;
    POST) s=$(req -X POST -H 'Content-Type: application/json' --data '{"username":"a","password":"b"}' http://127.0.0.1/api/auth/v1/login) ;;
    HEAD) s=$(req -I http://127.0.0.1/api/meta/v1/channels) ;;
    WS)   s=$(req -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' http://127.0.0.1/api/meta/v1/events) ;;
  esac
  [ "$s" = 503 ] && ok "/api/ $m: 503" || bad "/api/ $m: $s ($(tr '\r\n' '  ' <$H))"
  [ "$(hdr Retry-After)" = 30 ] && ok "/api/ $m: Retry-After: 30" || bad "/api/ $m: Retry-After '$(hdr Retry-After)'"
  [ -z "$(hdr Location)" ] && ok "/api/ $m: no Location" || bad "/api/ $m: Location $(hdr Location)"
  case "$(hdr Content-Type)" in application/json*) ok "/api/ $m: JSON" ;; *) bad "/api/ $m: Content-Type '$(hdr Content-Type)'" ;; esac
  if [ $m != HEAD ]; then grep -q '^{"error":"updating"' $B && ok "/api/ $m: the body says updating" || bad "/api/ $m: body '$(cat $B)'"; fi
done

# the addons and the ACME challenge: 503, Retry-After, text - the Loom client's event stream first
for p in /addons/loom/api/v1/events /addons/red/ /addons/xmlapi/statelist.cgi /.well-known/acme-challenge/token; do
  if [ $p = /addons/loom/api/v1/events ]; then
    s=$(req -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' http://127.0.0.1$p)
  else
    s=$(req http://127.0.0.1$p)
  fi
  [ "$s" = 503 ] && [ "$(hdr Retry-After)" = 30 ] && [ -z "$(hdr Location)" ] && ok "$p: 503, Retry-After: 30, no Location" || bad "$p: $s ($(tr '\r\n' '  ' <$H))"
  case "$(hdr Content-Type)" in text/plain*) ok "$p: text" ;; *) bad "$p: Content-Type '$(hdr Content-Type)'" ;; esac
done

# browser paths and near misses: still the 301 to the recovery's page
for p in /index.htm /webui/index.htm /api /apix/x /addonsx /config/xmlapi/statelist.cgi; do
  s=$(req http://127.0.0.1$p)
  loc=$(hdr Location)
  [ "$s" = 301 ] && [ "$loc" = / -o "$loc" = http://127.0.0.1/ ] && ok "$p: 301 to /" || bad "$p: $s Location '$loc'"
done
s=$(req http://127.0.0.1/)
[ "$s" != 301 ] && [ "$s" != 503 ] && ok "/: the recovery's page ($s)" || bad "/: $s"

kill $pid 2>/dev/null; wait $pid 2>/dev/null
grep -i 'error\|fail' /var/log/lighttpd-error.log 2>/dev/null | grep -v 'server started\|server stopped' | sed 's/^/     error log: /'
[ "$f" = 0 ]
INNER
  then
    sed 's/^/     /' "$out"
    ok "the recovery's lighttpd (container)"
  else
    sed 's/^/     /' "$out"
    bad "the recovery's lighttpd (container)"
  fi
  rm -f "$out"

  # --- task 505: the HTTPS instance (S51lighttpd-ssl) beside port 80, on a real lighttpd ---------
  # Port 80 runs as S50lighttpd starts it; S51lighttpd-ssl starts the second instance from the
  # certificate on a tmpfs "userfs". For every certificate - good, expired, missing, empty,
  # truncated, garbage, huge, a foreign key, a symlink elsewhere - and with port 443 taken by
  # another program: port 80 serves the menu, our look and the 503 JSON, without a redirect and
  # without HSTS; 443 serves the system's certificate only in the good cases. Then the 443
  # instance killed: port 80 still answers. And the install status through lighttpd: the update
  # object and /fwinstall.log on both ports.
  out="${TMPDIR:-/tmp}/lite-recovery-tls.$$"
  if docker run --rm -i --tmpfs /userfs \
       -v "$REC/overlay/base/etc:/src/etc:ro" \
       -v "$REC/overlay/base/www:/src/www-lite:ro" \
       -v "$REC/overlay/lite/www:/src/www-look:ro" \
       -v "$REC/package/hm-platform/rootfs-overlay/www:/src/www-platform:ro" \
       -v "$HERE/buildroot-external/overlay/base/etc/lighttpd/conf.d:/src/conf.d-base:ro" \
       "${ALPINE_IMAGE:-alpine:3.22}" sh -s >"$out" 2>&1 <<'INNER'
set -u
apk add --no-cache lighttpd curl openssl >/tmp/apk.log 2>&1 || { cat /tmp/apk.log; exit 3; }
f=0; ok() { echo "ok   $1"; }; bad() { echo "FAIL $1"; f=$((f+1)); }
rm -rf /etc/lighttpd && cp -a /src/etc/lighttpd /etc/lighttpd
for c in access_log.conf debug.conf dirlisting.conf; do cp /src/conf.d-base/$c /etc/lighttpd/conf.d/; done
# (mod_openssl stays: Alpine's lighttpd has it as a module, as the recovery's has)
mkdir -p /www /var/log /var/run /run /var/lib/lighttpd /var/cache/lighttpd /dev/shm /etc/init.d /opt/mock
cp -a /src/www-platform/. /www/ && cp -a /src/www-lite/. /www/ && cp -a /src/www-look/. /www/
cp /src/etc/init.d/S51lighttpd-ssl /etc/init.d/ && chmod 755 /etc/init.d/S51lighttpd-ssl
# the recovery's links: /usr/local -> /userfs, /etc/config -> /usr/local/etc/config
rm -rf /usr/local && ln -s /userfs /usr/local && mkdir -p /userfs/etc/config /usr/local/tmp && ln -s /usr/local/etc/config /etc/config
printf '#!/bin/sh\nshift 2; echo "$*" >>/tmp/ssl.log\n' >/opt/mock/logger && chmod 755 /opt/mock/logger
# Alpine has no start-stop-daemon (the recovery's busybox has): the two forms S51 uses
cat >/opt/mock/start-stop-daemon <<'SSD'
#!/bin/sh
pidf=""; mode=""; exe=""
while [ $# -gt 0 ]; do case "$1" in -S) mode=S ;; -K) mode=K ;; -q) ;; -p) shift; pidf=$1 ;; --exec) shift; exe=$1 ;; --) shift; break ;; esac; shift; done
case $mode in
  S) "$exe" "$@" ;;
  K) [ -f "$pidf" ] && kill "$(cat "$pidf")" ;;
esac
SSD
chmod 755 /opt/mock/start-stop-daemon
grep -q ' /userfs ' /proc/mounts && ok "/userfs is a mount (tmpfs)" || bad "/userfs is no mount"

EC="-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes"
openssl req -x509 $EC -days 3650 -subj /CN=openccu -keyout /tmp/a.key -out /tmp/a.crt 2>/dev/null
openssl req -x509 $EC -days 3650 -subj /CN=other -keyout /tmp/b.key -out /tmp/b.crt 2>/dev/null
mkdir -p /tmp/ca && cd /tmp/ca && : >index.txt && echo 01 >serial && printf '[ca]\ndefault_ca = d\n[d]\ndir = .\ndatabase = index.txt\nserial = serial\nnew_certs_dir = .\ndefault_md = sha256\npolicy = p\n[p]\ncommonName = supplied\n' >ca.cnf &&
  openssl req -new $EC -subj /CN=expired -keyout e.key -out e.csr 2>/dev/null &&
  openssl ca -batch -config ca.cnf -selfsign -keyfile e.key -in e.csr -startdate 20200101000000Z -enddate 20200102000000Z -notext -out e.crt >/dev/null 2>&1; cd /
fp() { openssl x509 -noout -fingerprint -sha256 -in "$1" | cut -d= -f2; }

lighttpd -f /etc/lighttpd/lighttpd.conf || bad "port 80 instance did not start"
i=0; until curl -s -o /dev/null --max-time 1 http://127.0.0.1/; do i=$((i+1)); [ $i -ge 300 ] && { echo "FAIL port 80 not listening"; exit 1; }; sleep 0.1; done

H=/tmp/h; B=/tmp/b
req() { rm -f $H $B; curl -s --max-time 5 -D $H -o $B "$@" >/dev/null; sed -n '1s/^HTTP\/[0-9.]* \([0-9]*\).*/\1/p' $H; }
hdr() { sed -n "s/^$1: *\(.*\)\r\$/\1/Ip" $H | head -1; }

# port 80 as today, whatever 443 does: the menu, the look, the 503 JSON - no redirect, no HSTS
port80() {
  c=$1
  s=$(req http://127.0.0.1/); { [ "$s" = 200 ] && grep -q 'CCU Recovery System' $B && [ -z "$(hdr Location)" ] && [ -z "$(hdr Strict-Transport-Security)" ]; } && ok "$c: port 80 serves the menu (200, no Location, no HSTS)" || bad "$c: port 80 /: $s $(hdr Location)"
  s=$(req http://127.0.0.1/css/index.css); [ "$s" = 200 ] && grep -q 'openccu-lite' $B && ok "$c: port 80 serves our index.css" || bad "$c: port 80 index.css: $s"
  s=$(req http://127.0.0.1/api/system/v1/health); { [ "$s" = 503 ] && grep -q '"recovery":true' $B; } && ok "$c: port 80 answers the API with the 503 JSON" || bad "$c: port 80 API: $s $(cat $B)"
  s=$(req http://[::1]/); [ "$s" = 200 ] && ok "$c: port 80 on IPv6 too" || echo "     (no IPv6 loopback in this container: $s)"
}
# 443: the system's certificate, the same menu and JSON, no HSTS - or nothing listening
port443_on() {
  c=$1; want=$2
  got=$(echo | openssl s_client -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  [ -n "$got" ] && [ "$got" = "$want" ] && ok "$c: 443 presents the system's certificate" || bad "$c: 443 certificate '$got' (want '$want')"
  s=$(req -k https://127.0.0.1/); { [ "$s" = 200 ] && grep -q 'CCU Recovery System' $B && [ -z "$(hdr Strict-Transport-Security)" ]; } && ok "$c: 443 serves the menu, no HSTS" || bad "$c: 443 /: $s"
  s=$(req -k https://127.0.0.1/api/system/v1/health); { [ "$s" = 503 ] && grep -q '"recovery":true' $B; } && ok "$c: 443 answers the API with the 503 JSON" || bad "$c: 443 API: $s"
}
port443_off() {
  c=$1
  if curl -sk --max-time 3 -o /dev/null https://127.0.0.1/; then bad "$c: 443 answers"; else ok "$c: nothing on 443"; fi
}
# S51lighttpd-ssl start with a certificate (or none), waiting for its one log line
s51() {
  PATH=/opt/mock:$PATH /etc/init.d/S51lighttpd-ssl stop >/dev/null 2>&1; rm -f /tmp/ssl.log; sleep 0.3
  t0=$(date +%s)
  PATH=/opt/mock:$PATH /etc/init.d/S51lighttpd-ssl start >/dev/null 2>&1
  t1=$(date +%s); [ $((t1 - t0)) -le 1 ] || bad "S51 start took $((t1 - t0)) s"
  i=0; until [ -s /tmp/ssl.log ]; do i=$((i+1)); [ $i -ge 300 ] && { bad "no log line from S51 in 30 s"; break; }; sleep 0.1; done
  echo "     log: $(cat /tmp/ssl.log 2>/dev/null)"
}
pem() { rm -rf /userfs/etc/config/server.pem; [ $# -gt 0 ] && cat "$@" >/userfs/etc/config/server.pem; return 0; }

pem /tmp/a.crt /tmp/a.key; s51; port443_on good "$(fp /tmp/a.crt)"; port80 good
s=$(req -k https://[::1]/); [ "$s" = 200 ] && ok "good: 443 on IPv6 too" || echo "     (no IPv6 loopback in this container: $s)"
# the 443 instance killed: port 80 does not care
kill "$(cat /var/run/lighttpd-ssl.pid)" 2>/dev/null; sleep 0.5
port443_off "443 killed"; port80 "443 killed"

pem /tmp/ca/e.crt /tmp/ca/e.key; s51; port443_on expired "$(fp /tmp/ca/e.crt)"; port80 expired
grep -q 'expired - served anyway' /tmp/ssl.log && ok "expired: logged" || bad "expired: not logged"

pem; s51; port443_off missing; port80 missing
: >/userfs/etc/config/server.pem; s51; port443_off empty; port80 empty
head -c 300 /tmp/a.crt >/userfs/etc/config/server.pem; s51; port443_off truncated; port80 truncated
head -c 4000 /dev/urandom >/userfs/etc/config/server.pem; s51; port443_off garbage; port80 garbage
{ cat /tmp/a.crt /tmp/a.key; head -c 70000 /dev/zero | tr '\0' x; } >/userfs/etc/config/server.pem; s51; port443_off huge; port80 huge
pem /tmp/a.crt /tmp/b.key; s51; port443_off "foreign key"; port80 "foreign key"
pem /tmp/a.crt; s51; port443_off "certificate only"; port80 "certificate only"
rm -f /userfs/etc/config/server.pem; cat /tmp/a.crt /tmp/a.key >/tmp/elsewhere.pem; ln -s /tmp/elsewhere.pem /userfs/etc/config/server.pem; s51; port443_off "symlink elsewhere"; port80 "symlink elsewhere"
mkfifo /tmp/fifo.pem 2>/dev/null; rm -f /userfs/etc/config/server.pem; mkfifo /userfs/etc/config/server.pem; s51; port443_off fifo; port80 fifo

# 443 taken by another program: the second instance cannot bind, port 80 is untouched
pem /tmp/a.crt /tmp/a.key
nc -lk -p 443 -e true >/dev/null 2>&1 & ncpid=$!
sleep 0.3; s51; grep -q 'did not start' /tmp/ssl.log && ok "443 taken: logged, no second instance" || bad "443 taken: $(cat /tmp/ssl.log)"
port80 "443 taken"; kill $ncpid 2>/dev/null; wait $ncpid 2>/dev/null

# the install status through lighttpd, on both ports: the update object and the raw log
pem /tmp/a.crt /tmp/a.key; s51
: >/tmp/.runningFirmwareUpdate; printf 'Starting firmware update (DO NOT INTERRUPT!!!):<br/>\n[1/7] Checking uploaded data... OK<br/>\n[5/7] Preparing uploaded data... ' >/tmp/fwinstall.log
for u in http://127.0.0.1 https://127.0.0.1; do
  s=$(req -k $u/api/system/v1/health); { [ "$s" = 503 ] && grep -q '"update":{"running":true,"phase":"prepare","step":5,"steps":7,' $B; } && ok "$u: the update object" || bad "$u: $s $(cat $B)"
  s=$(req -k $u/fwinstall.log); { [ "$s" = 200 ] && case "$(hdr Content-Type)" in text/plain*) true ;; *) false ;; esac && cmp -s $B /tmp/fwinstall.log; } && ok "$u: /fwinstall.log is the raw output, text/plain" || bad "$u: /fwinstall.log $s $(hdr Content-Type)"
  s=$(req -k -H 'Range: bytes=10-' $u/fwinstall.log); [ "$s" = 206 ] && ok "$u: /fwinstall.log answers a range" || bad "$u: range $s"
done
rm -f /tmp/.runningFirmwareUpdate /tmp/fwinstall.log; sleep 2   # lighttpd's stat cache
s=$(req http://127.0.0.1/fwinstall.log); { [ "$s" = 301 ] || [ "$s" = 404 ]; } && ok "no log: /fwinstall.log is not text ($s)" || bad "no log: /fwinstall.log $s"

grep -i 'error' /var/log/lighttpd-error.log 2>/dev/null | grep -v 'server started\|server stopped\|bind\|Address in use' | sed 's/^/     error log: /'
[ "$f" = 0 ]
INNER
  then
    sed 's/^/     /' "$out"
    ok "the recovery's HTTPS instance (container)"
  else
    sed 's/^/     /' "$out"
    bad "the recovery's HTTPS instance (container)"
  fi
  rm -f "$out"
fi

echo; [ "$fails" -eq 0 ] && { echo "lite-recovery-lighttpd-test: all checks passed"; exit 0; }
echo "lite-recovery-lighttpd-test: $fails check(s) failed"; exit 1
