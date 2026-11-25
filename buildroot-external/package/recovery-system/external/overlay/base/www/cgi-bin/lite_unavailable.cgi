#!/bin/sh
# openccu-lite: the recovery's answer on the running system's API and addon paths
# (lighttpd.conf's error-handler-404 for /api/, /addons/ and /.well-known/acme-challenge/):
# 503 with Retry-After, so a client retries instead of following a redirect to the recovery's
# page - JSON under /api/ as occulited's lighttpd answers while it starts, a line of text
# elsewhere. REQUEST_URI is the client's original path under an error handler.
#
# Task 505: the JSON says "recovery": true and carries an "update" object - how far a firmware
# update has got - so that occulited's page, which polls /api/system/v1/health during an install,
# can show it. Everything is read from outside: the lock file and the log of upstream's
# fwinstall.sh, a running dd's command line in /proc and the target partition's "sectors
# written" counter in /sys (dd's own file position runs ahead of the card by the page cache).
# Nothing is written, no signal is sent. Every value is a number or one of a few fixed words, so
# the JSON stays valid whatever the log holds; what cannot be read is left out, the answer stays.
#
#   "update": {"running": true|false, "phase": "starting|prepare|install|done|failed",
#              "step": n, "steps": m,               the last "[n/m]" of the log (7 prepare, 5 install)
#              "flashing": "bootfs|rootfs|...",     while a dd writes a partition
#              "written": bytes, "total": bytes,    the partition's counter, the source's size
#              "log_bytes": bytes}                  the size of /fwinstall.log, the raw output
#
# The object is there while an install log or the lock file exists; a recovery entered for
# anything else (its menu, a restore) answers "recovery": true without it.
# LITE_STATUS_ROOT is a prefix for /tmp, /proc and /sys, for the fork's tests only (lighttpd
# passes no such variable to a CGI; a client can set only HTTP_* ones).

R="${LITE_STATUS_ROOT:-}"
LOG="$R/tmp/fwinstall.log"
LOCK="$R/tmp/.runningFirmwareUpdate"

num() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "${#1}" -le 18 ]; }

update_json() {
  running=false
  [ -f "$LOCK" ] && running=true
  [ -f "$LOG" ] || [ "$running" = true ] || return 0
  log_bytes=0
  [ -f "$LOG" ] && log_bytes=$(wc -c <"$LOG" 2>/dev/null | tr -dc 0-9)
  num "$log_bytes" || log_bytes=0
  # phase and step from the log's marker lines: the last [n/m], the end markers, the last "flashing x"
  # shellcheck disable=SC2046
  set -- $( [ -f "$LOG" ] && tr '\r' '\n' <"$LOG" 2>/dev/null | awk '
    { line = $0
      while (match(line, /\[[0-9]+\/[0-9]+\]/)) { s = substr(line, RSTART + 1, RLENGTH - 2); line = substr(line, RSTART + RLENGTH); split(s, a, "/"); n = a[1]; m = a[2] }
      if ($0 ~ /Starting firmware update/) started = 1
      if ($0 ~ /Finished firmware update successfully/) done = 1
      if ($0 ~ /ERROR/) failed = 1
      line = $0
      while (match(line, /flashing [a-z0-9]+/)) { fl = substr(line, RSTART + 9, RLENGTH - 9); line = substr(line, RSTART + RLENGTH) }
    }
    END { printf "%s %s %d %d %d %s\n", (n == "" ? "-" : n), (m == "" ? "-" : m), started, done, failed, (fl == "" ? "-" : fl) }' 2>/dev/null )
  n=${1:--}; m=${2:--}; started=${3:-0}; finished=${4:-0}; failed=${5:-0}; fl=${6:--}
  if [ "$failed" = 1 ]; then phase=failed
  elif [ "$finished" = 1 ]; then phase="done"
  elif [ "$m" = 5 ]; then phase=install
  elif [ "$m" = 7 ] || [ "$started" = 1 ]; then phase=prepare
  else phase=starting
  fi
  out="\"running\":$running,\"phase\":\"$phase\""
  if num "$n" && num "$m" && [ "$m" -le 99 ] && [ "$n" -ge 1 ] && [ "$n" -le "$m" ]; then
    out="$out,\"step\":$n,\"steps\":$m"
  fi
  # a running dd that writes a partition: of= names it, if= the source (a loop partition or a file)
  if [ "$running" = true ] && [ "$phase" = install ]; then
    for c in "$R"/proc/[0-9]*/comm; do
      [ "$(cat "$c" 2>/dev/null)" = dd ] || continue
      d=${c%/comm}
      src=""; dst=""
      # if=/of= as one argument, or as two: busybox dd cuts its argv at the "=" in place, so
      # /proc shows "of" and "/dev/mmcblk0p2" as separate arguments
      for a in $(tr '\0' '\n' <"$d/cmdline" 2>/dev/null | awk '(p == "if" || p == "of") { print p "=" $0 } { print; p = $0 }' | sed -n -E 's#^(if|of)=(/[A-Za-z0-9_./-]+)$#\1=\2#p'); do
        case "$a" in if=*) src=${a#if=} ;; of=*) dst=${a#of=} ;; esac
      done
      case "$dst" in /dev/*) ;; *) continue ;; esac
      part=${dst#/dev/}
      case "$part" in *[!A-Za-z0-9_-]*|'') continue ;; esac
      [ -f "$R/sys/class/block/$part/stat" ] || continue
      written=$(awk '$7 ~ /^[0-9]+$/ { printf "%.0f\n", $7 * 512 } { exit }' "$R/sys/class/block/$part/stat" 2>/dev/null)
      num "$written" || continue
      total=""
      case "$src" in
        /dev/*) s=$(cat "$R/sys/class/block/${src#/dev/}/size" 2>/dev/null); num "$s" && total=$((s * 512)) ;;
        /*) total=$(stat -c %s "$R$src" 2>/dev/null) ;;
      esac
      case "$fl" in *[!a-z0-9]*|''|-) fl=$part ;; esac
      out="$out,\"flashing\":\"$fl\""
      if num "$total" && [ "$total" -gt 0 ]; then
        [ "$written" -gt "$total" ] && written=$total
        out="$out,\"written\":$written,\"total\":$total"
      fi
      break
    done
  fi
  printf ',"update":{%s,"log_bytes":%s}' "$out" "$log_bytes"
}

case "${REQUEST_URI:-}" in
  /api/*)
    printf 'Status: 503 Service Unavailable\r\nRetry-After: 30\r\nCache-Control: no-store\r\nContent-Type: application/json\r\n\r\n'
    printf '{"error":"updating","message":"the system is in its recovery system, installing an update or restoring a backup","recovery":true%s}\n' "$(update_json 2>/dev/null)"
    ;;
  *)
    printf 'Status: 503 Service Unavailable\r\nRetry-After: 30\r\nCache-Control: no-store\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n'
    printf 'the system is in its recovery system, installing an update or restoring a backup\n'
    ;;
esac
