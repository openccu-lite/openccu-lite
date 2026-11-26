#!/bin/sh
# openccu-lite: lite-kernel-fragment-guard.sh against made-up build dirs and fragments:
#   - a kernel that has every option of the fragments passes;
#   - one that lacks a "=y" option, or has it as a module, fails and names it;
#   - one that has a "is not set" option on fails;
#   - the headers', firmware's and tools' dirs are not kernels;
#   - a build with BR2_LINUX_KERNEL=y and no kernel .config fails; one without a kernel passes;
#   - a fragment line with a value other than y ("CONFIG_X=6") must be in the kernel as written;
#   - the real fragments pin the io controller and writeback attribution, and the lite post-build
#     runs the guard;
#   - every lite product with a kernel ends its fragment list with CONFIG_MESSAGE_LOGLEVEL_DEFAULT=6
#     (task 508: a printk without a level is info), from lite.config.
#
# Usage: sh scripts/testcases/lite-kernel-fragment-guard-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
G="$HERE/scripts/lite-kernel-fragment-guard.sh"
[ -f "$G" ] || { echo "lite-kernel-fragment-guard.sh not found at $G"; exit 2; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

kconf() { # <build dir> <linux dir name> <lines…>
	d="$1/$2"; shift 2
	mkdir -p "$d"
	printf '%s\n' "$@" >"$d/.config"
}
run() { out=$(sh "$G" "$@" 2>&1); rc=$?; }

printf '%s\n' '# a comment' CONFIG_BLK_CGROUP=y CONFIG_CGROUP_WRITEBACK=y >"$T/frag-a.config"
printf '%s\n' CONFIG_MEMCG=y '# CONFIG_RT_GROUP_SCHED is not set' >"$T/frag-b.config"
F="$T/frag-a.config $T/frag-b.config"

kconf "$T/good" linux-custom CONFIG_BLK_CGROUP=y CONFIG_CGROUP_WRITEBACK=y CONFIG_MEMCG=y '# CONFIG_RT_GROUP_SCHED is not set'
kconf "$T/good" linux-headers-custom '# CONFIG_BLK_CGROUP is not set'
# shellcheck disable=SC2086 # F is two paths
run "$T/good" $F
[ "$rc" = 0 ] && ok "a kernel with every fragment option passes (the headers' dir is no kernel)" || bad "the good kernel: rc $rc: $out"

kconf "$T/lacks" linux-6.18.64 CONFIG_BLK_CGROUP=y CONFIG_MEMCG=y '# CONFIG_CGROUP_WRITEBACK is not set'
# shellcheck disable=SC2086
run "$T/lacks" $F
[ "$rc" = 1 ] && ok "a kernel without CGROUP_WRITEBACK fails" || bad "a missing option: rc $rc: $out"
printf '%s\n' "$out" | grep -q 'CONFIG_CGROUP_WRITEBACK=y, which frag-a.config sets' && ok "and it names the option and the fragment" || bad "no option named in: $out"

kconf "$T/module" linux-custom CONFIG_BLK_CGROUP=m CONFIG_CGROUP_WRITEBACK=y CONFIG_MEMCG=y
# shellcheck disable=SC2086
run "$T/module" $F
[ "$rc" = 1 ] && ok "a =y option built as a module fails" || bad "=m for =y: rc $rc: $out"

kconf "$T/on" linux-custom CONFIG_BLK_CGROUP=y CONFIG_CGROUP_WRITEBACK=y CONFIG_MEMCG=y CONFIG_RT_GROUP_SCHED=y
# shellcheck disable=SC2086
run "$T/on" $F
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'CONFIG_RT_GROUP_SCHED on' && ok "an option the fragment turns off, on in the kernel, fails" || bad "an option turned off: rc $rc: $out"

mkdir -p "$T/empty/linux-firmware-20260810" "$T/empty/linux-tools"
echo CONFIG_MEMCG=y >"$T/empty/linux-firmware-20260810/.config"
printf 'BR2_LINUX_KERNEL=y\n' >"$T/br-kernel.config"
printf '# BR2_LINUX_KERNEL is not set\n' >"$T/br-none.config"
# shellcheck disable=SC2086
out=$(BR2_CONFIG="$T/br-kernel.config" sh "$G" "$T/empty" $F 2>&1); rc=$?
[ "$rc" = 1 ] && ok "a build with a kernel but no kernel .config fails" || bad "no kernel .config: rc $rc: $out"
# shellcheck disable=SC2086
out=$(BR2_CONFIG="$T/br-none.config" sh "$G" "$T/empty" $F 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a build without a kernel (lxc) passes" || bad "a build without a kernel: rc $rc: $out"

printf '%s\n' CONFIG_MEMCG=y CONFIG_MESSAGE_LOGLEVEL_DEFAULT=6 'CONFIG_DEFAULT_HOSTNAME="ccu"' >"$T/frag-v.config"
kconf "$T/val-good" linux-custom CONFIG_MEMCG=y CONFIG_MESSAGE_LOGLEVEL_DEFAULT=6 'CONFIG_DEFAULT_HOSTNAME="ccu"'
run "$T/val-good" "$T/frag-v.config"
[ "$rc" = 0 ] && ok "a kernel with a fragment's value options as written passes" || bad "value options: rc $rc: $out"
kconf "$T/val-bad" linux-custom CONFIG_MEMCG=y CONFIG_MESSAGE_LOGLEVEL_DEFAULT=4 'CONFIG_DEFAULT_HOSTNAME="(none)"'
run "$T/val-bad" "$T/frag-v.config"
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'has CONFIG_MESSAGE_LOGLEVEL_DEFAULT=4, not CONFIG_MESSAGE_LOGLEVEL_DEFAULT=6, which frag-v.config sets' \
	&& printf '%s\n' "$out" | grep -q 'not CONFIG_DEFAULT_HOSTNAME="ccu"' \
	&& ok "a kernel with another value fails and names the option, the value and the fragment" || bad "another value: rc $rc: $out"
kconf "$T/val-none" linux-custom CONFIG_MEMCG=y 'CONFIG_DEFAULT_HOSTNAME="ccu"'
run "$T/val-none" "$T/frag-v.config"
[ "$rc" = 1 ] && printf '%s\n' "$out" | grep -q 'has no CONFIG_MESSAGE_LOGLEVEL_DEFAULT, not CONFIG_MESSAGE_LOGLEVEL_DEFAULT=6' \
	&& ok "a kernel without the value option fails" || bad "a missing value option: rc $rc: $out"

run "$T/good" "$T/nowhere.config"
[ "$rc" = 2 ] && ok "a fragment that does not exist is an error" || bad "a missing fragment: rc $rc: $out"

# the real fragments: the default list is lite.config and lite-systemd.config, which pin what
# occulited's write accounting needs
L="$HERE/buildroot-external/kernel/6.18/lite.config"
for o in CONFIG_BLK_CGROUP CONFIG_CGROUP_WRITEBACK CONFIG_MEMCG; do
	grep -q "^$o=y\$" "$L" && ok "lite.config pins $o" || bad "lite.config lacks $o=y"
done
kconf "$T/real" linux-custom CONFIG_CGROUPS=y
run "$T/real"
printf '%s\n' "$out" | grep -q 'CONFIG_CGROUP_WRITEBACK=y, which lite.config sets' && printf '%s\n' "$out" | grep -q 'which lite-systemd.config sets' \
	&& ok "without fragments the guard checks lite.config and lite-systemd.config" || bad "the default fragments: rc $rc: $out"

# task 508: every lite product with a kernel (a config with the lite post-build and
# BR2_LINUX_KERNEL=y) merges lite.config, and the last fragment of its list that sets
# MESSAGE_LOGLEVEL_DEFAULT sets 6 (Buildroot merges the fragments in order, the last one wins)
grep -q '^CONFIG_MESSAGE_LOGLEVEL_DEFAULT=6$' "$L" && ok "lite.config sets CONFIG_MESSAGE_LOGLEVEL_DEFAULT=6" || bad "lite.config lacks CONFIG_MESSAGE_LOGLEVEL_DEFAULT=6"
products=0
for cfg in "$HERE"/buildroot-external/configs/*.config; do
	grep -q 'board/lite/post-build\.sh' "$cfg" || continue
	grep -q '^BR2_LINUX_KERNEL=y$' "$cfg" || continue
	products=$((products + 1))
	p=$(basename "$cfg" .config)
	frags=$(sed -n 's/^BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES="\(.*\)"$/\1/p' "$cfg" | sed "s|\$(BR2_EXTERNAL_EQ3_PATH)|$HERE/buildroot-external|g")
	case " $frags " in *"/kernel/6.18/lite.config "*) ;; *) bad "$p: lite.config is not among its kernel fragments"; continue ;; esac
	last=
	for fr in $frags; do
		[ -f "$fr" ] || { bad "$p: kernel fragment $fr not found"; continue; }
		v=$(sed -n 's/^CONFIG_MESSAGE_LOGLEVEL_DEFAULT=\(.*\)$/\1/p; s/^# CONFIG_MESSAGE_LOGLEVEL_DEFAULT is not set$/unset/p' "$fr" | tail -n 1)
		[ -n "$v" ] && last="$v ($(basename "$fr"))"
	done
	[ "${last%% *}" = 6 ] && ok "$p: its kernel fragments end with CONFIG_MESSAGE_LOGLEVEL_DEFAULT=6" \
		|| bad "$p: its kernel fragments end with CONFIG_MESSAGE_LOGLEVEL_DEFAULT=${last:-<none>}, not 6"
done
[ "$products" -ge 3 ] && ok "$products lite products with a kernel checked" || bad "only $products lite products with a kernel found (expected rpi3, rpi4, ova at least)"

grep -v '^[[:space:]]*#' "$HERE/buildroot-external/board/lite/post-build.sh" | grep -q 'lite-kernel-fragment-guard\.sh' \
	&& ok "the lite post-build runs the guard" || bad "the lite post-build does not run lite-kernel-fragment-guard.sh"

[ "$fails" = 0 ] && echo "all ok" || echo "$fails failed"
[ "$fails" = 0 ]
