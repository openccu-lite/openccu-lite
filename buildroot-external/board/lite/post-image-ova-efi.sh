#!/bin/sh
# openccu-lite: the x86_64 image boots with UEFI as well as with a BIOS. buildroot's grub2 leaves
# the EFI binary in images/efi-part/EFI/BOOT/bootx64.efi (next to a sample grub.cfg that is not
# used: the binary's embedded configuration, board/lite/ova-grub-efi.cfg, reads bootfs'
# boot/grub/grub.cfg). This runs before board/ova/post-image.sh and stages the binary under the
# name a UEFI firmware looks for on a disk without a boot entry, EFI/BOOT/BOOTX64.EFI; genimage
# takes the EFI directory into bootfs (board/ova/genimage.cfg).
set -e

SRC="${BINARIES_DIR}/efi-part/EFI/BOOT/bootx64.efi"
if [ ! -s "${SRC}" ]; then
	echo "post-image-ova-efi: ${SRC} is missing: BR2_TARGET_GRUB2_X86_64_EFI is off, or grub2 was built before it was turned on (make grub2-dirclean)" >&2
	exit 1
fi
rm -rf "${BINARIES_DIR}/EFI"
mkdir -p "${BINARIES_DIR}/EFI/BOOT"
cp "${SRC}" "${BINARIES_DIR}/EFI/BOOT/BOOTX64.EFI"
