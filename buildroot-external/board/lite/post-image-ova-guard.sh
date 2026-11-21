#!/bin/sh
# openccu-lite: after board/ova/post-image.sh, the finished x86_64 image is checked for both boot
# paths - GRUB for a BIOS in the MBR and behind it, GRUB for UEFI in bootfs, one grub.cfg, kernels
# that boot from either (scripts/lite-efi-boot-guard.py says what exactly).
set -e
python3 "$(cd "$(dirname "$0")/../../.." && pwd)/scripts/lite-efi-boot-guard.py" "${BINARIES_DIR}" "${BUILD_DIR}"
