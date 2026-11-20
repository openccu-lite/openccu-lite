#!/bin/sh
# openccu-lite: the lite kernel fragments hold in the kernel that was built.
#
# kernel/6.18/lite.config and lite-systemd.config are merged over each product's defconfig, but a
# merged option whose dependencies are missing is dropped by Kconfig without a word, and an option
# the lite products rely on that only the defconfig provides goes away with a defconfig change. The
# check: every kernel .config of the build (<build dir>/linux-*/.config, not the headers, the
# firmware or the tools) has each "CONFIG_X=y" line of the fragments as CONFIG_X=y, and none of
# their "# CONFIG_X is not set" options as y or m. A build that has a kernel (BR2_LINUX_KERNEL=y in
# $BR2_CONFIG) but no kernel .config is an error, not a pass; a build without one (lxc) passes.
#
# Usage: scripts/lite-kernel-fragment-guard.sh <build dir> [<fragment>...]
#        (default fragments: buildroot-external/kernel/6.18/lite.config and lite-systemd.config)
#        BR2_CONFIG=<buildroot .config> (the post-build has it) makes a missing kernel config an error
set -u

BUILD=${1:?usage: lite-kernel-fragment-guard.sh <build dir> [<fragment>...]}
shift
[ -d "$BUILD" ] || { echo "lite-kernel-fragment-guard: $BUILD is not a directory" >&2; exit 2; }
if [ $# -eq 0 ]; then
	top=$(cd "$(dirname "$0")/.." && pwd)
	set -- "$top/buildroot-external/kernel/6.18/lite.config" "$top/buildroot-external/kernel/6.18/lite-systemd.config"
fi
for f in "$@"; do
	[ -f "$f" ] || { echo "lite-kernel-fragment-guard: fragment $f not found" >&2; exit 2; }
done

found=0
checked=0
for c in "$BUILD"/linux-*/.config; do
	[ -f "$c" ] || continue
	case "$(basename "$(dirname "$c")")" in linux-headers-*|linux-firmware-*|linux-tools) continue ;; esac
	checked=$((checked + 1))
	for f in "$@"; do
		for opt in $(sed -n 's/^\(CONFIG_[A-Za-z0-9_]*\)=y$/\1/p' "$f"); do
			grep -q "^${opt}=y\$" "$c" && continue
			echo "lite-kernel-fragment-guard: ERROR: $c lacks ${opt}=y, which $(basename "$f") sets (a dependency missing, or another fragment turns it off)" >&2
			found=1
		done
		for opt in $(sed -n 's/^# \(CONFIG_[A-Za-z0-9_]*\) is not set$/\1/p' "$f"); do
			grep -Eq "^${opt}=[ym]\$" "$c" || continue
			echo "lite-kernel-fragment-guard: ERROR: $c has ${opt} on, which $(basename "$f") turns off" >&2
			found=1
		done
	done
done

if [ "$checked" = 0 ] && [ -n "${BR2_CONFIG:-}" ] && grep -q '^BR2_LINUX_KERNEL=y$' "$BR2_CONFIG" 2>/dev/null; then
	echo "lite-kernel-fragment-guard: ERROR: the build has a kernel (BR2_LINUX_KERNEL=y) but no kernel .config under $BUILD/linux-*/" >&2
	exit 1
fi
exit "$found"
