#!/bin/sh
# openccu-lite: lite-release-github.sh takes a release commit that GitHub's main contains, and a patch
# release X.Y.Z also from GitHub's hotfix-X.Y (the guard script's --hotfix push); nothing else. The
# dry run goes against a small GitHub API stand-in (python3 http.server) with a fake round in a
# build tree of the test's own:
#   - 1.2.2 in main: ok ("main contains");
#   - 1.2.2 only in hotfix-1.2: ok ("a hotfix release");
#   - 1.2.2 in neither: rc 1;
#   - 1.3.0-beta.0 only in hotfix-1.3: rc 1 (a prerelease is never a hotfix);
#   - 1.2.2 only in hotfix-1.3: rc 1 (the branch is the version's own).
#
# Usage: sh scripts/testcases/lite-release-hotfix-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
S="$HERE/scripts/lite-release-github.sh"
[ -f "$S" ] || { echo "lite-release-github.sh not found at $S"; exit 2; }
command -v python3 >/dev/null || { echo "python3 missing"; exit 2; }
T=$(mktemp -d) || exit 2
PID=""
trap '[ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }
PIN=0123456789abcdef0123456789abcdef01234567
P=x86_64-ova

g() { git -c user.name=t -c user.email=t@example.org -c init.defaultBranch=lite "$@"; }
mkrepo() { # LITE-VERSION's VERSION [release version] -> $SHA, a build tree at it with the round's files
  rv="${2:-$1}"
  rm -rf "$T/repo" "$T/tree"
  mkdir -p "$T/repo/buildroot-external/package/occulited"
  printf 'VERSION=%s\nBASE=3.89.11\n' "$1" >"$T/repo/LITE-VERSION"
  printf 'OCCULITED_VERSION = %s\n' "$PIN" >"$T/repo/buildroot-external/package/occulited/occulited.mk"
  g -C "$T/repo" init -q && g -C "$T/repo" add -A && g -C "$T/repo" commit -qm test || { echo "git setup failed"; exit 2; }
  SHA=$(git -C "$T/repo" rev-parse HEAD)
  g clone -q "$T/repo" "$T/tree" || { echo "git clone failed"; exit 2; }
  tg="$T/tree/build-$P/target"
  mkdir -p "$tg/usr/share/openccu-lite" "$T/tree/release" "$T/tree/build-$P/build/occulited-$PIN/docs"
  printf 'VERSION=3.89.11\nLITE=%s\n' "$rv" >"$tg/VERSION"
  printf '{"metadata":{"component":{"version":"%s","properties":[{"name":"openccu-lite:product","value":"%s"}]}},"components":[{"name":"occulited","bom-ref":"occulited@%s"}]}\n' \
    "$rv" "$P" "$PIN" | gzip >"$tg/usr/share/openccu-lite/sbom.cdx.json.gz"
  for f in "openccu-lite-$P-$rv.zip" "openccu-lite-$P-$rv.ova"; do
    echo "$f" >"$T/tree/release/$f"; (cd "$T/tree/release" && sha256sum "$f" >"$f.sha256")
  done
}

# the GitHub API stand-in: compare answers "ahead" for the branches in $T/branches, 404 otherwise;
# occulited's tag is the pin; no releases yet
cat >"$T/gh.py" <<'PY'
import json, re, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
T, PIN = sys.argv[1], sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        code, body = 404, {"message": "Not Found"}
        m = re.fullmatch(r"/repos/[^/]+/[^/]+/compare/[0-9a-f]{40}\.\.\.([A-Za-z0-9._-]+)", self.path)
        if m:
            branches = open(T + "/branches").read().split()
            if m.group(1) in branches:
                code, body = 200, {"status": "ahead", "behind_by": 0}
        elif re.fullmatch(r"/repos/openccu-lite/occulited/git/ref/tags/v[^/]+", self.path):
            code, body = 200, {"object": {"type": "commit", "sha": PIN}}
        elif self.path.startswith("/repos/openccu-lite/openccu-lite/releases"):
            code, body = 200, []
        data = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def log_message(self, *a): pass
s = HTTPServer(("127.0.0.1", 0), H)
open(T + "/port", "w").write(str(s.server_address[1]))
s.serve_forever()
PY
: >"$T/branches"
python3 "$T/gh.py" "$T" "$PIN" &
PID=$!
i=0; while [ ! -s "$T/port" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
[ -s "$T/port" ] || { echo "the API stand-in did not start"; exit 2; }
API="http://127.0.0.1:$(cat "$T/port")"

run() { # version branches...: $rc, $out
  v="$1"; shift
  printf '%s\n' "$@" >"$T/branches"
  out=$(cd "$T/repo" && env -u STAGE TREE="$T/tree" PRODUCTS="$P" GH_API="$API" GH_TOKEN=test \
    bash "$S" --dry-run "$v" "$SHA" 2>&1)
  rc=$?
}

mkrepo 1.2.2
run 1.2.2 main
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "GitHub's main contains" && ok "1.2.2 in main" || bad "1.2.2 in main: rc $rc: $out"
run 1.2.2 hotfix-1.2
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q "GitHub's hotfix-1.2 contains .* (a hotfix release)" \
  && ok "1.2.2 in hotfix-1.2 only" || bad "1.2.2 in hotfix-1.2: rc $rc: $out"
printf '%s\n' "$out" | grep -q "would create the draft v1.2.2" && ok "and the dry run gets to the draft" || bad "no draft line: $out"
run 1.2.2
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q "main and hotfix-1.2 do not contain" && ok "1.2.2 in neither: refused" || bad "1.2.2 in neither: rc $rc: $out"
run 1.2.2 hotfix-1.3
[ "$rc" = 1 ] && ok "1.2.2 in another hotfix branch: refused" || bad "1.2.2 in hotfix-1.3: rc $rc: $out"

mkrepo 1.3.0-beta 1.3.0-beta.0
run 1.3.0-beta.0 hotfix-1.3
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q "GitHub's main do not contain" && ok "a prerelease is never a hotfix" || bad "1.3.0-beta.0 in hotfix-1.3: rc $rc: $out"

[ "$fails" = 0 ] && echo "all ok" || echo "$fails failed"
[ "$fails" = 0 ]
