#!/bin/sh
# openccu-lite (B-353): package/java-azul puts the archive's JRE files back into the target at every
# build's target-finalize, before buildroot strips the executables and patches their RUNPATH. A warm
# round otherwise stripped and patched the JRE the previous round had patched, and 40 files under
# /opt/java-azul changed without a JRE update.
#
# The hook is run the way buildroot's target-finalize runs it ($(foreach hook,$(TARGET_FINALIZE_HOOKS),
# $($(hook))$(sep)), in a rule whose $(@D) is not the package's directory) against a stand-in build
# directory and target: a patched file comes back as the archive has it, nothing else is touched.
#
# Usage: sh scripts/testcases/lite-java-azul-finalize-test.sh    (from the fork's checkout; needs make)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
MK="$HERE/buildroot-external/package/java-azul/java-azul.mk"
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

grep -q '^JAVA_AZUL_TARGET_FINALIZE_HOOKS += JAVA_AZUL_RESTORE_ARCHIVE_FILES$' "$MK" && ok "the hook is registered" || bad "JAVA_AZUL_TARGET_FINALIZE_HOOKS does not name the restore"
awk '/^define JAVA_AZUL_RESTORE_ARCHIVE_FILES$/ {p=1} p && /^endef$/ {p=0} p' "$MK" | grep -q '@D' && bad "the hook uses \$(@D), which is not the package's directory in target-finalize" || ok "the hook does not use \$(@D)"

# the stand-ins: the extracted archive, and a target the previous round left patched
B="$T/build/java-azul-1"
mkdir -p "$B/bin" "$B/conf" "$B/lib" "$B/legal/java.base" "$T/target/opt/java-azul/bin" "$T/target/opt/java-azul/lib" "$T/target/usr/bin"
printf 'archive java\n' > "$B/bin/java"; chmod 0555 "$B/bin/java"
printf 'archive libjvm\n' > "$B/lib/libjvm.so"
printf 'conf\n' > "$B/conf/security.properties"
printf 'license\n' > "$B/legal/java.base/LICENSE"
printf 'disclaimer\n' > "$B/DISCLAIMER"
printf 'patched and stripped twice\n' > "$T/target/opt/java-azul/bin/java"; chmod 0555 "$T/target/opt/java-azul/bin/java"
printf 'patched libjvm\n' > "$T/target/opt/java-azul/lib/libjvm.so"
printf 'another package\n' > "$T/target/usr/bin/other"

cat > "$T/Makefile" <<MAKE
define sep


endef
BR2_ARCH = "aarch64"
qstrip = \$(strip \$(subst ",,\$(1)))
INSTALL = install
TARGET_DIR = $T/target
JAVA_AZUL_DIR = $B
generic-package =
include $MK
TARGET_FINALIZE_HOOKS += \$(JAVA_AZUL_TARGET_FINALIZE_HOOKS)
$T/out/target-finalize:
	\$(foreach hook,\$(TARGET_FINALIZE_HOOKS),\$(\$(hook))\$(sep))
MAKE
if make -s -f "$T/Makefile" "$T/out/target-finalize" > "$T/make.log" 2>&1; then ok "the hook runs in a target-finalize rule"; else bad "the hook failed: $(cat "$T/make.log")"; fi
cmp -s "$B/bin/java" "$T/target/opt/java-azul/bin/java" && ok "a patched executable comes back as the archive has it" || bad "bin/java: $(cat "$T/target/opt/java-azul/bin/java")"
cmp -s "$B/lib/libjvm.so" "$T/target/opt/java-azul/lib/libjvm.so" && ok "and a library" || bad "lib/libjvm.so: $(cat "$T/target/opt/java-azul/lib/libjvm.so")"
[ -f "$T/target/opt/java-azul/conf/security.properties" ] && [ -f "$T/target/opt/java-azul/legal/java.base/LICENSE" ] && [ -f "$T/target/opt/java-azul/DISCLAIMER" ] && ok "conf, legal and DISCLAIMER as well" || bad "conf/legal/DISCLAIMER missing"
[ "$(cat "$T/target/usr/bin/other")" = "another package" ] && ok "nothing outside /opt/java-azul is touched" || bad "another package's file changed"
[ ! -e "$T/out" ] || [ -z "$(ls -A "$T/out")" ] && ok "nothing written next to the rule's target" || bad "files beside the rule's target: $(ls -A "$T/out")"

[ "$fails" = 0 ] && { echo "lite-java-azul-finalize-test: all passed"; exit 0; }
echo "lite-java-azul-finalize-test: $fails failed"; exit 1
