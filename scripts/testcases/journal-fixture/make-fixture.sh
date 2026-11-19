#!/bin/sh
# openccu-lite: makes archived.journal.gz, the journal file lite-journal-sync-test.sh trims (B-352).
# 400 made-up entries (fixed times, ids and texts) written by systemd-journal-remote in a Debian 13
# container, then marked archived (state byte 2 at offset 16), as journald leaves a rotated file;
# like every journal file it is allocated far beyond its last object (8 MB here, 2 MB on a box).
#
# Usage: sh scripts/testcases/journal-fixture/make-fixture.sh    (needs docker and python3)
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
python3 - "$W/in.export" <<'PY'
import random, sys
random.seed(352)
t, mono, out = 1763560000000000, 5000000, []
for i in range(400):
    t += random.randint(1000000, 90000000)
    mono += random.randint(1000000, 90000000)
    ident = random.choice(['hs485d', 'rfd', 'occulited', 'lighttpd', 'systemd'])
    out.append("__REALTIME_TIMESTAMP=%d\n__MONOTONIC_TIMESTAMP=%d\n_BOOT_ID=5f1d0b7c3a2e4d6f8a9b0c1d2e3f4a5b\n"
               "_MACHINE_ID=0123456789abcdef0123456789abcdef\n_HOSTNAME=openccu-lite\n_TRANSPORT=journal\n"
               "PRIORITY=6\nSYSLOG_IDENTIFIER=%s\nMESSAGE=openccu-lite B-352 fixture line %d from %s\n\n"
               % (t, mono, ident, i, ident))
open(sys.argv[1], 'w').write(''.join(out))
PY
docker run --rm -v "$W:/w" debian:13 sh -c 'apt-get update -qq && apt-get install -y -qq systemd-journal-remote >/dev/null &&
  /lib/systemd/systemd-journal-remote -o /w/fixture.journal - < /w/in.export && chown -R '"$(id -u):$(id -g)"' /w'
printf '\002' | dd of="$W/fixture.journal" bs=1 seek=16 conv=notrunc 2>/dev/null
gzip -9n < "$W/fixture.journal" > "$HERE/archived.journal.gz"
echo "wrote $HERE/archived.journal.gz"
