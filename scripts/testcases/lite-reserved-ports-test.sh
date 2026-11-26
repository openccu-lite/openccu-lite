#!/bin/sh
# openccu-lite: 61-openccu-lite-reserved-ports.conf, the system's fixed ports in the kernel's
# ephemeral range (32768-60999) kept out of automatic port selection. The file sets exactly one
# key, net.ipv4.ip_local_reserved_ports, in the kernel's syntax (ports and ranges, comma
# separated, no blanks); it does not touch ip_local_port_range; every reserved port lies in the
# ephemeral range and is named in the file's comment with its owner; and it covers the known
# fixed ports as well as every port in the range that the image's sources configure: hmipserver's
# hmServerPort, the ports its unit binds to the loopback, the classic RPC TLS ports.
#
# Usage: sh scripts/testcases/lite-reserved-ports-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
OVL="$HERE/buildroot-external/overlay"
CONF="$OVL/lite/usr/lib/sysctl.d/61-openccu-lite-reserved-ports.conf"
UNIT="$OVL/lite/usr/lib/systemd/system/hmipserver.service"
HMSERVER="$OVL/base/etc/HMServer.conf"
CLASSIC="$OVL/lite/usr/libexec/occu/lite-classic-rpc-conf"
for f in "$CONF" "$UNIT" "$HMSERVER" "$CLASSIC"; do
  [ -f "$f" ] || { echo "$f not found"; exit 2; }
done
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }
LO=32768 HI=60999
KEY=net.ipv4.ip_local_reserved_ports

# expand <list>: the kernel's syntax to one port per line; nothing and rc 1 on a malformed list
expand() {
  printf '%s\n' "$1" | grep -qE '^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$' || return 1
  printf '%s\n' "$1" | tr ',' '\n' | while IFS=- read -r a b; do
    [ -n "$b" ] || b=$a
    [ "$a" -ge 1 ] && [ "$b" -le 65535 ] && [ "$a" -le "$b" ] || { echo BAD; continue; }
    p=$a; while [ "$p" -le "$b" ]; do echo "$p"; p=$((p+1)); done
  done
}

# parse <file>: every line a comment, blank or "key = value"; prints the value of $KEY
parse() {
  awk -v key="$KEY" '
    /^[ \t]*([#;].*)?$/ { next }
    {
      line = $0; sub(/^[ \t]*-?/, "", line)
      i = index(line, "="); if (!i) { print "BADLINE " NR; next }
      k = substr(line, 1, i-1); v = substr(line, i+1)
      gsub(/[ \t]/, "", k); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (k == key) print v; else print "OTHERKEY " k
    }' "$1"
}

out=$(parse "$CONF")
case "$out" in
  *BADLINE*) bad "a line is neither a comment nor key = value: $out" ;;
  *OTHERKEY*) bad "the file sets another key: $(printf '%s\n' "$out" | grep OTHERKEY)" ;;
  *) ok "only comments and key = value lines, only $KEY" ;;
esac
n=$(printf '%s\n' "$out" | grep -vc -e BADLINE -e OTHERKEY -e '^$')
[ "$n" = 1 ] && ok "$KEY is set once" || bad "$KEY is set $n times"
value=$(printf '%s\n' "$out" | grep -v -e BADLINE -e OTHERKEY | head -n 1)
grep -q 'ip_local_port_range[ \t]*=' "$CONF" && bad "the file sets ip_local_port_range" || ok "ip_local_port_range is not touched"

ports=$(expand "$value") && ok "the value is in the kernel's syntax: $value" || bad "the value is not in the kernel's syntax: '$value'"
case "$ports" in *BAD*) bad "a port or range is out of 1-65535 or reversed: $value" ;; esac
ports=$(printf '%s\n' "$ports" | grep -v BAD)
[ -n "$ports" ] && ok "$(printf '%s\n' "$ports" | grep -c .) ports reserved" || bad "no port reserved"

comments=$(grep -E '^[ \t]*#' "$CONF")
for p in $ports; do
  [ "$p" -ge $LO ] && [ "$p" -le $HI ] || bad "$p lies outside the ephemeral range $LO-$HI"
  printf '%s\n' "$comments" | grep -qE "^#[ \t]+${p}[ \t]+(tcp|udp)[ \t]+[a-z0-9-]+:" \
    || bad "$p has no comment line '#   $p  tcp|udp  <owner>: ...'"
done
# and no comment line names a port the value does not reserve
for p in $(printf '%s\n' "$comments" | sed -En 's/^#[ \t]*([0-9]+)[ \t]+(tcp|udp)[ \t].*/\1/p'); do
  printf '%s\n' "$ports" | grep -qx "$p" || bad "the comment names $p, the value does not reserve it"
done

reserved() { printf '%s\n' "$ports" | grep -qx "$1"; }
# need <why> <port...>: each port in the ephemeral range must be reserved
need() {
  why=$1; shift
  for p in "$@"; do
    [ "$p" -ge $LO ] && [ "$p" -le $HI ] || continue
    reserved "$p" && ok "$why: $p reserved" || bad "$why: $p lies in the ephemeral range and is not reserved"
  done
}

# the known fixed ports, seen listening on the systems (netstat -tulpn)
need "hmipserver VirtualDevices" 39292
need "hmipserver HmIP access points" 43438
need "occulited eQ-3 discovery" 43439
need "lighttpd classic RPC TLS" 42000 42001 42010 49292

# what the sources configure: a port added there in the range must come here too
hm=$(sed -n 's/^hmServerPort=\([0-9][0-9]*\)$/\1/p' "$HMSERVER")
[ -n "$hm" ] && need "HMServer.conf hmServerPort" $hm || bad "no hmServerPort in HMServer.conf"
bl=$(sed -n 's/^Environment=BINDLO_PORTS=//p' "$UNIT" | tr ', ' '\n\n' | grep -E '^[0-9]+$')
[ -n "$bl" ] && need "hmipserver.service BINDLO_PORTS" $bl || bad "no BINDLO_PORTS in hmipserver.service"
tls=$(sed -n 's/.*tls="\(.*\)".*/\1/p' "$CLASSIC" | tr ' ' '\n' | sed -n 's/^\$tls$//; s/^\([0-9][0-9]*\):[0-9]*$/\1/p')
[ -n "$tls" ] && need "lite-classic-rpc-conf TLS sockets" $tls || bad "no TLS socket in lite-classic-rpc-conf"

# self-tests of the helpers
expand "1-3,7" | tr '\n' ' ' | grep -qx '1 2 3 7 ' && ok "self-test: ranges expand" || bad "self-test: ranges do not expand"
expand "1, 3" >/dev/null && bad "self-test: a blank after the comma passes" || ok "self-test: a blank after the comma is refused"
expand "5-3" | grep -q BAD && ok "self-test: a reversed range is refused" || bad "self-test: a reversed range passes"
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
printf '# c\n\n%s = 1\nnet.ipv4.ip_local_port_range = 40000 60999\n' "$KEY" > "$T/x.conf"
parse "$T/x.conf" | grep -q 'OTHERKEY net.ipv4.ip_local_port_range' && ok "self-test: another key is found" || bad "self-test: another key is missed"
printf 'garbage\n' > "$T/y.conf"
parse "$T/y.conf" | grep -q BADLINE && ok "self-test: a malformed line is found" || bad "self-test: a malformed line is missed"

echo; [ "$fails" -eq 0 ] && { echo "lite-reserved-ports-test: all passed"; exit 0; }
echo "lite-reserved-ports-test: $fails check(s) failed"; exit 1
