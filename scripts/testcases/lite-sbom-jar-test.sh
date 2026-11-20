#!/bin/sh
# openccu-lite: scripts/lite-sbom.py lists the libraries the JARs bundle in both JAR layouts (B-360).
# The 1.2 line's HMIPServer.jar carried a third-party list (THIRD-PARTY.txt, read by OpenCCU-Base's
# createLicenseForJar.py into <jar>-JARLICENSEINFO.txt); OpenCCU-Base 2.0's HMIPServer.jar and
# ESHBridge.jar carry none, and the 2.0 betas' SBOMs listed no library inside them. Both keep the
# Maven metadata of each bundled library (META-INF/maven/<group>/<artifact>/pom.properties).
#
# The JARs are made from the listings in scripts/testcases/sbom-jars/ (made up, not eQ-3's JARs).
# 1. The layout without a list: the libraries from the metadata - version from pom.properties, name
#    and website from pom.xml, the licence from pom.xml or else from lite-sbom.py's table (a group,
#    a group:artifact, a choice); the JAR's own modules (de.eq3*) are not libraries; a library
#    whose licence neither names is left without one, so --check reports it (no-license).
# 2. The layout with a list: the list's libraries with the list's licences, then what only the
#    metadata names; a library in both is listed once.
# 3. A JAR with neither a list nor metadata is a gap (jar-empty); a file that is no JAR adds nothing.
#
# Usage: sh scripts/testcases/lite-sbom-jar-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
SBOM="$HERE/scripts/lite-sbom.py"
FIX="$HERE/scripts/testcases/sbom-jars"
for f in "$SBOM" "$FIX/jar-maven-only.list" "$FIX/jar-third-party-list.list"; do [ -f "$f" ] || { echo "$f not found"; exit 2; }; done

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails+1)); }

cat > "$T/t.py" <<'PY'
import importlib.util, json, os, sys, zipfile
s = importlib.util.spec_from_file_location("s", sys.argv[1])
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
fix, root = sys.argv[2], sys.argv[3]

def jar(listing, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with zipfile.ZipFile(path, "w") as z, open(listing, encoding="utf-8") as f:
        for line in f:
            name, _, text = line.rstrip("\n").partition("\t")
            z.writestr(name, text.replace("\\n", "\n"))

def build(case, layout, info=True):
    """A fake build: OpenCCU-Base installed one JAR, HMIPServer.jar, made from <layout>.list."""
    r = os.path.join(root, case)
    d = os.path.join(r, "build", "openccu-base-1")
    os.makedirs(d)
    if layout:
        jar(os.path.join(fix, layout + ".list"), os.path.join(r, "target", "opt", "HMServer", "HMIPServer.jar"))
    else:
        os.makedirs(os.path.join(r, "target", "opt", "HMServer"))
        with open(os.path.join(r, "target", "opt", "HMServer", "HMIPServer.jar"), "w") as f:
            f.write("not a zip")
    if info:
        src = os.path.join(fix, (layout or "jar-maven-only") + ".info")
        with open(src, encoding="utf-8") as a, open(os.path.join(d, "HMIPServer.jar-JARLICENSEINFO.txt"), "w", encoding="utf-8") as b:
            b.write(a.read())
    class B:
        pass
    b = B()
    b.root = r
    b.info = {"openccu-base": {"version": "1"}}
    b.files = {"openccu-base": ["opt/HMServer/HMIPServer.jar"]}
    b.pkgdir = lambda name: d
    errors = []
    cs = m.openccu_base(m.Texts(), b, errors)
    j = [c for c in cs if c["name"] == "HMIPServer.jar"][0]
    return j.get("components", []), errors

def lic(c):
    out = []
    for l in c.get("licenses", []):
        out.append(l["expression"] if "expression" in l else l["license"].get("id") or "name:" + l["license"].get("name", ""))
    choice = any(p["name"] == "openccu-lite:licence-choice" for p in c.get("properties", []))
    return ("|" if choice else ",").join(out) or "-"

for case, layout, info in (("maven-only", "jar-maven-only", True), ("list", "jar-third-party-list", True),
                           ("neither", None, True), ("no-info", "jar-maven-only", False)):
    libs, errors = build(case, layout, info)
    print(f"[{case}] errors={sorted(k for k, _ in errors)}")
    for c in libs:
        url = (c.get("externalReferences") or [{}])[0].get("url", "")
        print(f"  {c['purl']} name={c['name']} lic={lic(c)} url={url} unlicensed={m.unlicensed(c)}")
PY
out=$(python3 "$T/t.py" "$SBOM" "$FIX" "$T" 2>&1)
echo "$out" > "$T/out"
has() { grep -qxF -- "$1" "$T/out"; }
sect() { awk -v s="[$1]" 'index($0, s) == 1 {on=1; print; next} /^\[/ {on=0} on' "$T/out"; }

# --- 1. the layout without a list
sect maven-only > "$T/m"
[ "$(grep -c '^  pkg:' "$T/m")" = 5 ] && ok "maven-only: five libraries from the metadata" || { fail "maven-only: count"; cat "$T/m"; }
grep -q 'de\.eq3' "$T/m" && fail "maven-only: the JAR's own module listed as a library" || ok "maven-only: the JAR's own module is not a library"
has "  pkg:maven/io.netty/netty-common@4.2.5.Final name=Netty/Common lic=Apache-2.0 url= unlicensed=False" \
	&& ok "maven-only: netty-common - the version from pom.properties, the name from pom.xml, the licence from the group table" || { fail "maven-only: netty-common"; cat "$T/m"; }
has "  pkg:maven/com.google.code.gson/gson@2.13.2 name=Gson lic=Apache-2.0 url=https://github.com/google/gson unlicensed=False" \
	&& ok "maven-only: gson - the licence and website from its pom.xml" || { fail "maven-only: gson"; cat "$T/m"; }
has "  pkg:maven/io.vertx/vertx-core@5.0.4 name=Vert.x Core lic=EPL-2.0|Apache-2.0 url= unlicensed=False" \
	&& ok "maven-only: vertx-core - a licence choice from the group table" || { fail "maven-only: vertx-core"; cat "$T/m"; }
has "  pkg:maven/io.vertx/vertx-web-common@5.0.4 name=vertx-web-common lic=EPL-1.0|Apache-2.0 url= unlicensed=False" \
	&& ok "maven-only: vertx-web-common - group:artifact before group, the artifact as the name without a pom.xml" || { fail "maven-only: vertx-web-common"; cat "$T/m"; }
has "  pkg:maven/org.example.unknown/lib@0.1 name=An unknown library lic=- url= unlicensed=True" \
	&& ok "maven-only: a library no source names a licence for stays without one (--check: no-license)" || { fail "maven-only: unknown"; cat "$T/m"; }
has "[maven-only] errors=[]" && ok "maven-only: no gap" || { fail "maven-only: errors"; cat "$T/m"; }

# --- 2. the layout with a list
sect list > "$T/l"
[ "$(grep -c '^  pkg:' "$T/l")" = 3 ] && ok "list: three libraries" || { fail "list: count"; cat "$T/l"; }
[ "$(grep -c '^  pkg:maven/io.netty/netty-common@' "$T/l")" = 1 ] && ok "list: a library in the list and the metadata is listed once" || { fail "list: netty twice"; cat "$T/l"; }
has "  pkg:maven/org.bouncycastle/bcprov-jdk18on@1.82 name=Bouncy Castle Provider lic=MIT url=https://www.bouncycastle.org/download/bouncy-castle-java/ unlicensed=False" \
	&& ok "list: the list's own entry kept as the list says" || { fail "list: bouncycastle"; cat "$T/l"; }
[ "$(sed -n 2p "$T/l" | cut -d' ' -f3)" = "pkg:maven/io.netty/netty-common@4.2.5.Final" ] && [ "$(sed -n 4p "$T/l" | cut -d' ' -f3)" = "pkg:maven/org.jctools/jctools-core@4.0.5" ] \
	&& ok "list: the list first, then what only the metadata names" || { fail "list: order"; cat "$T/l"; }
has "  pkg:maven/org.jctools/jctools-core@4.0.5 name=Java Concurrency Tools Core Library lic=Apache-2.0 url= unlicensed=False" \
	&& ok "list: a library the list misses comes from the metadata" || { fail "list: jctools"; cat "$T/l"; }
has "[list] errors=[]" && ok "list: no gap" || { fail "list: errors"; cat "$T/l"; }

# --- 3. neither
has "[neither] errors=['jar-empty']" && ok "a JAR with neither a list nor metadata is a gap (jar-empty)" || { fail "neither"; sect neither; }
[ "$(sect neither | grep -c '^  pkg:')" = 0 ] && ok "a file that is no JAR adds nothing" || fail "neither: libraries"
has "[no-info] errors=['jar-info']" && [ "$(sect no-info | grep -c '^  pkg:')" = 5 ] \
	&& ok "a missing JARLICENSEINFO.txt stays a gap, the metadata is read all the same" || { fail "no-info"; sect no-info; }
grep -q Traceback "$T/out" && { fail "the script raised"; cat "$T/out"; }

echo "--- $fails failure(s)"
[ "$fails" = 0 ]
