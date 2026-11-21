#!/bin/sh
# openccu-lite: lite-efi-boot-guard.py against made-up images, and the wiring that puts GRUB for
# UEFI into the x86_64 image next to GRUB for a BIOS:
#   - an image with both boot paths passes (the FAT is made here, with long names, as mtools does);
#   - bootfs without EFI/BOOT/BOOTX64.EFI, with one that is no x86-64 EFI application or carries
#     no embedded configuration, with buildroot's sample EFI/BOOT/grub.cfg, without the menu or
#     without the recovery fails, each named;
#   - a disk whose MBR boot code or core image is not GRUB's, whose first partition is not FAT or
#     not this bootfs fails;
#   - a kernel or a recovery kernel without EFI, the EFI stub or a framebuffer console fails, and
#     so does a build without a recovery kernel;
#   - an appliance whose .ovf does not say "UEFI" fails;
#   - the product's config builds both GRUBs and runs the staging script, upstream's post-image
#     and the guard in that order; genimage takes the EFI directory; the embedded configuration is
#     one plain line; install-proxmox.sh looks for the line the .ovf template carries;
#   - grub.cfg's file_env (bootfs' cmdline.txt) exists in both GRUBs: loadenv built in, upstream's
#     grub2 patch applied (B-365).
#
# Usage: sh scripts/testcases/lite-efi-boot-guard-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
G="$HERE/scripts/lite-efi-boot-guard.py"
EXT="$HERE/buildroot-external"
[ -f "$G" ] || { echo "lite-efi-boot-guard.py not found at $G"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 is needed"; exit 2; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails+1)); }

# mk.py <dir> [<what to break>...]: a build with images/ and build/ under <dir>
cat >"$T/mk.py" <<'PY'
import io, os, struct, sys, tarfile

out, broken = sys.argv[1], set(sys.argv[2:])
images, build = os.path.join(out, "images"), os.path.join(out, "build")
CONFIG = b"set prefix=($root)/boot/grub\n"


def efi(machine=0x8664, subsystem=10, config=CONFIG):
    d = bytearray(0x200)
    d[0:2] = b"MZ"
    struct.pack_into("<I", d, 0x3C, 0x80)
    d[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", d, 0x84, machine)
    struct.pack_into("<H", d, 0x80 + 24, 0x20B)
    struct.pack_into("<H", d, 0x80 + 24 + 68, subsystem)
    return bytes(d) + b"grub modules ..." + config + b"\0" * 700


def lfn_sum(short):
    s = 0
    for c in short:
        s = ((s >> 1) | ((s & 1) << 7)) + c & 0xFF
    return s


class Fat16:
    """512-byte sectors, one sector per cluster, 5000 clusters: FAT16 by the cluster count."""

    def __init__(self, label):
        self.fat = [0xFFF8, 0xFFFF]
        self.data = bytearray()
        self.root = bytearray()
        self.label = label
        self.dirs = {"": None}  # path -> (cluster, bytearray) of sub-directories
        self.alias = 0

    def alloc(self, content):
        n = max(1, (len(content) + 511) // 512)
        first = len(self.fat)
        for i in range(n):
            self.fat.append(first + i + 1 if i < n - 1 else 0xFFFF)
        self.data += content + b"\0" * (n * 512 - len(content))
        return first

    def entry(self, name, attr, cluster, size):
        base, _, ext = name.partition(".")
        fits = name == name.upper() and len(base) <= 8 and len(ext) <= 3 and name.count(".") <= 1
        if fits:
            short = base.ljust(8).encode() + ext.ljust(3).encode()
            pre = b""
        else:
            self.alias += 1
            short = (base.upper().replace("-", "")[:6] + "~%d" % self.alias).ljust(8).encode() + ext.upper()[:3].ljust(3).encode()
            u = (name + "\0").encode("utf-16-le")
            u += b"\xff" * (-len(u) % 26)
            parts = [u[i:i + 26] for i in range(0, len(u), 26)]
            pre = b""
            for n in range(len(parts), 0, -1):
                p = parts[n - 1]
                seq = n | (0x40 if n == len(parts) else 0)
                pre += bytes([seq]) + p[0:10] + b"\x0f\0" + bytes([lfn_sum(short)]) + p[10:22] + b"\0\0" + p[22:26]
        return pre + short + bytes([attr]) + b"\0" * 14 + struct.pack("<HI", cluster, size)

    def mkdir(self, path):
        if path in self.dirs:
            return
        parent, _, name = path.rpartition("/")
        self.mkdir(parent)
        cluster = self.alloc(b"\0" * 2048)  # four sectors of entries, filled in at the end
        self.dirs[path] = (cluster, bytearray())
        self.add(parent, self.entry(name, 0x10, cluster, 0))

    def add(self, parent, ent):
        if parent == "":
            self.root += ent
        else:
            self.dirs[parent][1].extend(ent)

    def write(self, path, content):
        parent, _, name = path.rpartition("/")
        self.mkdir(parent)
        self.add(parent, self.entry(name, 0x20, self.alloc(content) if content else 0, len(content)))

    def image(self):
        for path, d in self.dirs.items():
            if d is not None:
                off = (d[0] - 2) * 512
                self.data[off:off + len(d[1])] = d[1]
        clusters = 5000
        fatsz, rootent = 40, 512
        total = 1 + 2 * fatsz + rootent * 32 // 512 + clusters
        b = bytearray(512)
        b[0:3] = b"\xeb\x3c\x90"
        b[3:11] = b"mkfs.fat"
        struct.pack_into("<HBHBHHBHHHII", b, 11, 512, 1, 1, 2, rootent, total, 0xF8, fatsz, 32, 2, 0, 0)
        b[38] = 0x29
        b[43:54] = self.label.ljust(11).encode()
        b[54:62] = b"FAT16   "
        b[510:512] = b"\x55\xaa"
        fat = b"".join(struct.pack("<H", x) for x in self.fat).ljust(fatsz * 512, b"\0")
        root = bytes(self.root).ljust(rootent * 32, b"\0")
        return bytes(b) + fat + fat + root + bytes(self.data).ljust(clusters * 512, b"\0")


os.makedirs(images)
fs = Fat16("nolabel" if "label" in broken else "bootfs")
fs.write("VERSION", b"VERSION=3.89.13\n")
if "menu" not in broken:
    fs.write("boot/grub/grub.cfg", b"menuentry x { }\n")
if "efi" not in broken:
    fs.write("EFI/BOOT/BOOTX64.EFI", efi(
        machine=0xAA64 if "machine" in broken else 0x8664,
        subsystem=3 if "subsystem" in broken else 10,
        config=b"" if "embedded" in broken else CONFIG))
if "sample" in broken:
    fs.write("EFI/BOOT/grub.cfg", b"set default=0\n")
if "recovery" not in broken:
    fs.write("recoveryfs-zImage", b"K" * 3000)
fs.write("recoveryfs-initrd", b"I" * 1500)
vfat = fs.image()
open(os.path.join(images, "boot.vfat"), "wb").write(vfat)

boot = bytes(range(256)) * 2
core = b"GRUBCORE" * 4000
open(os.path.join(images, "boot.img"), "wb").write(boot)
open(os.path.join(images, "grub.img"), "wb").write(core)
mbr = bytearray(boot[:440] if "mbr" not in broken else b"\x90" * 440) + b"\xef\xbe\xed\xde\0\0"
start, count = 2048, len(vfat) // 512
part = bytes([0x80 if "active" not in broken else 0, 0, 0, 0, 0x83 if "ptype" in broken else 0x0C, 0, 0, 0]) + struct.pack("<II", start, count)
mbr += part + b"\0" * 48 + b"\x55\xaa"
disk = bytearray(start * 512 + len(vfat))
disk[0:512] = mbr
disk[512:512 + len(core)] = core if "core" not in broken else b"X" * len(core)
disk[start * 512:] = vfat
if "partition" in broken:
    disk[start * 512 + 4096] ^= 0xFF
open(os.path.join(images, "sdcard.img"), "wb").write(disk)

ovf = b'<Envelope>\n  <!-- openccu-lite: boots with BIOS and UEFI firmware (Secure Boot off) -->\n</Envelope>\n'
if "ovf" in broken:
    ovf = b"<Envelope>\n</Envelope>\n"
with tarfile.open(os.path.join(images, "OpenCCU.ova"), "w") as t:
    for name, data in (("OpenCCU.ovf", ovf), ("OpenCCU.vmdk", b"disk")):
        ti = tarfile.TarInfo(name)
        ti.size = len(data)
        t.addfile(ti, io.BytesIO(data))

good = ["CONFIG_EFI=y", "CONFIG_EFI_STUB=y", "CONFIG_SYSFB_SIMPLEFB=y", "CONFIG_DRM_SIMPLEDRM=y", "CONFIG_FRAMEBUFFER_CONSOLE=y"]


def kernel(d, lines):
    os.makedirs(d)
    open(os.path.join(d, ".config"), "w").write("\n".join(lines) + "\n")


kernel(os.path.join(build, "linux-6.18.64"), [l for l in good if not ("stub" in broken and l == "CONFIG_EFI_STUB=y")])
kernel(os.path.join(build, "linux-headers-6.18.64"), ["# CONFIG_EFI is not set"])
if "norecovery" not in broken:
    rec = ["CONFIG_EFI=y", "CONFIG_EFI_STUB=y", "CONFIG_FB_EFI=y", "CONFIG_FRAMEBUFFER_CONSOLE=y"]
    if "recfb" in broken:
        rec = ["CONFIG_EFI=y", "CONFIG_EFI_STUB=y", "CONFIG_SYSFB_SIMPLEFB=y", "CONFIG_FRAMEBUFFER_CONSOLE=y", "CONFIG_DRM_SIMPLEDRM=m"]
    kernel(os.path.join(build, "recovery-system-1.24.1-x", "output", "build", "linux-6.18.64"), rec)
PY

n=0
# case <expected rc> <what the message must name, or -> <description> [<what to break>...]
case_() {
	want=$1 pat=$2 desc=$3; shift 3
	n=$((n+1)); d="$T/c$n"
	python3 "$T/mk.py" "$d" "$@" || { bad "$desc: the fixture could not be made"; return; }
	out=$(python3 "$G" "$d/images" "$d/build" 2>&1); rc=$?
	if [ "$rc" != "$want" ]; then bad "$desc: rc $rc, expected $want: $out"; return; fi
	if [ "$pat" != - ] && ! printf '%s\n' "$out" | grep -q -- "$pat"; then bad "$desc: the message does not name '$pat': $out"; return; fi
	ok "$desc"
	rm -rf "$d"
}

case_ 0 'ok - BIOS' "an image with both boot paths passes"
case_ 1 'no EFI/BOOT/BOOTX64.EFI' "bootfs without the EFI binary fails" efi
case_ 1 'not a PE32+ image for x86-64' "an EFI binary for another machine fails" machine
case_ 1 'not an EFI application' "a PE image that is no EFI application fails" subsystem
case_ 1 'does not carry the embedded configuration' "an EFI binary without the embedded configuration fails" embedded
case_ 1 "buildroot's sample menu" "buildroot's sample EFI/BOOT/grub.cfg in bootfs fails" sample
case_ 1 'no boot/grub/grub.cfg' "bootfs without the menu fails" menu
case_ 1 'no recoveryfs-zImage' "bootfs without the recovery's kernel fails" recovery
case_ 1 "label 'nolabel'" "a bootfs with another label fails" label
case_ 1 "MBR boot code is not GRUB's boot.img" "an MBR without GRUB's boot code fails" mbr
case_ 1 "does not hold GRUB's core image" "a disk without GRUB's core image fails" core
case_ 1 'type 0x83, not a FAT type' "a first partition that is not FAT fails" ptype
case_ 1 'not marked active' "a first partition that is not active fails" active
case_ 1 'the disk was not made from this bootfs' "a disk whose first partition is not this bootfs fails" partition
case_ 1 'linux-6.18.64/.config lacks CONFIG_EFI_STUB=y' "a kernel without the EFI stub fails" stub
case_ 1 "no console on the firmware's framebuffer" "a recovery kernel whose framebuffer driver is a module fails" recfb
case_ 1 'no kernel .config of the recovery system' "a build without a recovery kernel fails" norecovery
case_ 1 "lacks the line 'openccu-lite: boots with BIOS and UEFI firmware'" "an appliance whose .ovf does not say UEFI fails" ovf

out=$(python3 "$G" "$T/nowhere" "$T" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "a missing images directory is a usage error (2), not a pass" || bad "a missing directory: rc $rc: $out"

# the wiring
C="$EXT/configs/x86_64-ova.config"
grep -q '^BR2_TARGET_GRUB2_I386_PC=y$' "$C" && grep -q '^BR2_TARGET_GRUB2_X86_64_EFI=y$' "$C" && ok "the product builds GRUB for a BIOS and for UEFI" || bad "x86_64-ova.config does not select both GRUB platforms"
grep -q '^BR2_TARGET_GRUB2_BUILTIN_CONFIG_EFI="$(BR2_EXTERNAL_EQ3_PATH)/board/lite/ova-grub-efi.cfg"$' "$C" && ok "the EFI one embeds board/lite/ova-grub-efi.cfg" || bad "no BR2_TARGET_GRUB2_BUILTIN_CONFIG_EFI for board/lite/ova-grub-efi.cfg"
pc=$(sed -n 's/^BR2_TARGET_GRUB2_BUILTIN_MODULES_PC="\(.*\)"$/\1/p' "$C"); efi=$(sed -n 's/^BR2_TARGET_GRUB2_BUILTIN_MODULES_EFI="\(.*\)"$/\1/p' "$C")
miss=""; for m in $pc; do case "$m" in biosdisk) continue;; esac; case " $efi " in *" $m "*) ;; *) miss="$miss $m";; esac; done
[ -n "$pc" ] && [ -z "$miss" ] && ok "every module the BIOS GRUB has built in is in the EFI one (biosdisk apart)" || bad "the EFI GRUB lacks the BIOS one's modules:$miss"
case " $efi " in *" efi_gop "*) ok "the EFI one has efi_gop for the screen";; *) bad "the EFI GRUB has no efi_gop";; esac
# B-365: grub.cfg reads bootfs' cmdline.txt with file_env, which upstream's grub2 patch adds to
# loadenv; with no module directory on bootfs, both GRUBs need loadenv built in and the patch applied
if grep -q '^file_env ' "$EXT/board/ova/grub.cfg"; then
	case " $pc " in *" loadenv "*) ok "grub.cfg calls file_env: the BIOS GRUB has loadenv built in";; *) bad "grub.cfg calls file_env, the BIOS GRUB lacks loadenv";; esac
	case " $efi " in *" loadenv "*) ok "grub.cfg calls file_env: the EFI GRUB has loadenv built in";; *) bad "grub.cfg calls file_env, the EFI GRUB lacks loadenv";; esac
	fp=$(ls "$EXT"/board/lite/patches-upstream/grub2/*.patch 2>/dev/null | head -1)
	case "$(cat "$C")" in *'/board/lite/patches-upstream"'*|*'/board/lite/patches-upstream '*) pd=1;; *) pd=0;; esac
	[ "$pd" = 1 ] && [ -n "$fp" ] && grep -q 'grub_register_extcmd ("file_env"' "$fp" && ok "the file_env patch is in a patch directory the product applies" || bad "no grub2 patch registering file_env under board/lite/patches-upstream/grub2 (or that directory is not in BR2_GLOBAL_PATCH_DIR)"
fi
grep -q '^BR2_ROOTFS_POST_IMAGE_SCRIPT=".*/board/lite/post-image-ova-efi.sh .*/board/ova/post-image.sh .*/board/lite/post-image-ova-guard.sh"$' "$C" && ok "post-image: the staging script, upstream's, then the guard" || bad "BR2_ROOTFS_POST_IMAGE_SCRIPT is not staging, upstream's post-image, guard"
for s in post-image-ova-efi.sh post-image-ova-guard.sh; do
	[ -x "$EXT/board/lite/$s" ] && ok "board/lite/$s is executable" || bad "board/lite/$s is missing or not executable"
done
grep -q 'scripts/lite-efi-boot-guard.py' "$EXT/board/lite/post-image-ova-guard.sh" && ok "the post-image guard runs lite-efi-boot-guard.py" || bad "post-image-ova-guard.sh does not run the guard"
grep -q '^ *"EFI",$' "$EXT/board/ova/genimage.cfg" && ok "genimage takes the EFI directory into bootfs" || bad "board/ova/genimage.cfg does not list \"EFI\""
grep -q 'partition-table-type = "mbr"' "$EXT/board/ova/genimage.cfg" && grep -q 'partition-type = 0xC' "$EXT/board/ova/genimage.cfg" && ok "the disk stays an MBR disk with a FAT bootfs" || bad "board/ova/genimage.cfg is no longer MBR with a 0xC bootfs"
[ "$(cat "$EXT/board/lite/ova-grub-efi.cfg")" = 'set prefix=($root)/boot/grub' ] && ok "the embedded configuration is the one line the rescue parser can run" || bad "board/lite/ova-grub-efi.cfg is not the single set prefix line"
M='openccu-lite: boots with BIOS and UEFI firmware'
grep -q "$M" "$EXT/board/ova/template.ovf" && ok "the .ovf template says the image boots with UEFI too" || bad "board/ova/template.ovf lacks '$M'"
grep -q "$M" "$HERE/scripts/install-proxmox.sh" && ok "install-proxmox.sh looks for that line" || bad "install-proxmox.sh does not look for '$M'"
grep -q "\"$M\"" "$G" && ok "and so does the guard" || bad "the guard's marker differs from '$M'"

echo; [ "$fails" -eq 0 ] && { echo "lite-efi-boot-guard-test: all passed"; exit 0; }
echo "lite-efi-boot-guard-test: $fails check(s) failed"; exit 1
