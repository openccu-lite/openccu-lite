#!/usr/bin/env python3
"""openccu-lite: the x86_64 image boots with a BIOS and with UEFI (task 480) - checked on the image.

One disk image serves both firmware types: an MBR disk whose boot code and the sectors behind it
hold GRUB for a BIOS, and whose first partition (bootfs, FAT) holds GRUB for UEFI as
EFI/BOOT/BOOTX64.EFI. Both read boot/grub/grub.cfg from bootfs. Any part can go missing without a
build error - a buildroot bump that changes where grub2 puts its images, an upstream change to
board/ova, a kernel defconfig that drops EFI - and the result is an image that boots under one
firmware only, which nobody notices on the other. The lite post-image runs this, and it fails the
build when one of these does not hold:

  the disk (images/sdcard.img)
    - an MBR with the 55 AA signature whose boot code is GRUB's boot.img (images/boot.img);
    - GRUB's core image (images/grub.img) from sector 1;
    - partition 1 active, a FAT type (0x0b, 0x0c, 0x0e or 0xef), and its content images/boot.vfat;
  bootfs (images/boot.vfat)
    - EFI/BOOT/BOOTX64.EFI, a PE32+ image for x86-64 with the EFI application subsystem, which
      carries the embedded configuration of board/lite/ova-grub-efi.cfg;
    - boot/grub/grub.cfg, the one menu;
    - no EFI/BOOT/grub.cfg: buildroot's sample menu next to its EFI binary is not ours;
    - the recovery's kernel and initrd (recoveryfs-zImage, recoveryfs-initrd);
  the kernels (<build dir>/linux-*/.config and the recovery's,
  <build dir>/recovery-system-*/output/build/linux-*/.config)
    - CONFIG_EFI=y and CONFIG_EFI_STUB=y;
    - a console on the firmware's framebuffer, which is all a UEFI VM has before a graphics
      driver loads: CONFIG_FRAMEBUFFER_CONSOLE=y with CONFIG_FB_EFI=y, or with
      CONFIG_SYSFB_SIMPLEFB=y and one of CONFIG_DRM_SIMPLEDRM=y, CONFIG_FB_SIMPLE=y;
  the appliance (images/OpenCCU.ova)
    - its .ovf says that the image boots with UEFI too: the line scripts/install-proxmox.sh looks
      for before it sets a VM up with OVMF.

The FAT is read here (FAT16 and FAT32), so the check needs no mtools and no mount.

Usage: scripts/lite-efi-boot-guard.py <images dir> <build dir> [<embedded config>]
       (default embedded config: buildroot-external/board/lite/ova-grub-efi.cfg)
"""
import glob
import os
import struct
import sys
import tarfile

OVF_MARKER = "openccu-lite: boots with BIOS and UEFI firmware"
FAT_TYPES = (0x0B, 0x0C, 0x0E, 0xEF)

errors = []


def bad(msg):
    errors.append(msg)
    print("lite-efi-boot-guard: ERROR: " + msg, file=sys.stderr)


class Fat:
    """A read-only FAT16/FAT32 file system in a file; names by their short or long form, any case."""

    def __init__(self, path):
        self.f = open(path, "rb")
        b = self.f.read(512)
        if len(b) < 512 or b[510:512] != b"\x55\xaa":
            raise ValueError("no boot sector signature")
        self.bps, self.spc, reserved, nfats, rootent, tot16 = struct.unpack("<HBHBHH", b[11:21])
        fatsz16 = struct.unpack("<H", b[22:24])[0]
        tot32 = struct.unpack("<I", b[32:36])[0]
        fatsz32 = struct.unpack("<I", b[36:40])[0]
        if self.bps not in (512, 1024, 2048, 4096) or self.spc == 0 or nfats == 0:
            raise ValueError("not a FAT boot sector")
        fatsz = fatsz16 or fatsz32
        total = tot16 or tot32
        self.fat_off = reserved * self.bps
        rootsecs = (rootent * 32 + self.bps - 1) // self.bps
        self.root_off = (reserved + nfats * fatsz) * self.bps
        self.data_off = self.root_off + rootsecs * self.bps
        clusters = (total - (self.data_off // self.bps)) // self.spc
        if clusters < 4085:
            raise ValueError("FAT12 is not read here (%d clusters)" % clusters)
        self.bits = 16 if clusters < 65525 else 32
        self.rootent = rootent
        self.root_cluster = struct.unpack("<I", b[44:48])[0] if self.bits == 32 else 0
        self.label = (b[71:82] if self.bits == 32 else b[43:54]).decode("ascii", "replace").rstrip()

    def _next(self, c):
        if self.bits == 16:
            self.f.seek(self.fat_off + 2 * c)
            n = struct.unpack("<H", self.f.read(2))[0]
            return None if n >= 0xFFF8 or n < 2 else n
        self.f.seek(self.fat_off + 4 * c)
        n = struct.unpack("<I", self.f.read(4))[0] & 0x0FFFFFFF
        return None if n >= 0x0FFFFFF8 or n < 2 else n

    def _chain(self, c, size=None):
        out = bytearray()
        seen = 0
        while c is not None:
            self.f.seek(self.data_off + (c - 2) * self.spc * self.bps)
            out += self.f.read(self.spc * self.bps)
            seen += 1
            if seen > 1 << 22 or (size is not None and len(out) >= size):
                break
            c = self._next(c)
        return bytes(out if size is None else out[:size])

    def _dir(self, cluster):
        if cluster == 0 and self.bits == 16:
            self.f.seek(self.root_off)
            raw = self.f.read(self.rootent * 32)
        else:
            raw = self._chain(cluster or self.root_cluster)
        ents = {}
        lfn = []
        for i in range(0, len(raw) - 31, 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5:
                lfn = []
                continue
            if e[11] & 0x3F == 0x0F:  # a part of the long name, the last part first
                lfn.insert(0, e[1:11] + e[14:26] + e[28:32])
                continue
            if e[11] & 0x08:  # the volume label
                lfn = []
                continue
            base = e[0:8].decode("ascii", "replace").rstrip()
            ext = e[8:11].decode("ascii", "replace").rstrip()
            first = struct.unpack("<H", e[26:28])[0] | (struct.unpack("<H", e[20:22])[0] << 16 if self.bits == 32 else 0)
            ent = (bool(e[11] & 0x10), first, struct.unpack("<I", e[28:32])[0])
            ents[(base + ("." + ext if ext else "")).upper()] = ent
            if lfn:
                long = b"".join(lfn).decode("utf-16-le", "replace").split("\0")[0]
                ents[long.upper()] = ent
            lfn = []
        return ents

    def read(self, path):
        """The file's bytes, or None when the path does not exist or names a directory."""
        cluster = 0
        parts = [p for p in path.upper().split("/") if p]
        for n, part in enumerate(parts):
            ent = self._dir(cluster).get(part)
            if ent is None:
                return None
            isdir, first, size = ent
            if n == len(parts) - 1:
                return None if isdir else self._chain(first, size) if size else b""
            if not isdir:
                return None
            cluster = first
        return None


def check_efi_binary(data, config):
    name = "bootfs' EFI/BOOT/BOOTX64.EFI"
    if len(data) < 0x100 or data[:2] != b"MZ":
        return bad(name + " is no PE image (no MZ header)")
    pe = struct.unpack("<I", data[0x3C:0x40])[0]
    if pe + 0x60 > len(data) or data[pe:pe + 4] != b"PE\0\0":
        return bad(name + " is no PE image (no PE signature)")
    machine = struct.unpack("<H", data[pe + 4:pe + 6])[0]
    magic = struct.unpack("<H", data[pe + 24:pe + 26])[0]
    subsystem = struct.unpack("<H", data[pe + 24 + 68:pe + 24 + 70])[0]
    if machine != 0x8664 or magic != 0x20B:
        bad("%s is not a PE32+ image for x86-64 (machine %#x, magic %#x)" % (name, machine, magic))
    if subsystem != 10:
        bad("%s is not an EFI application (subsystem %d)" % (name, subsystem))
    if config is not None and config.strip() and config.strip() not in data:
        bad("%s does not carry the embedded configuration (%s): GRUB would look for its menu in EFI/BOOT"
            % (name, config.strip().decode("ascii", "replace")))


def check_bootfs(images, config):
    path = os.path.join(images, "boot.vfat")
    try:
        fat = Fat(path)
    except (OSError, ValueError, struct.error) as e:
        return bad("%s cannot be read as FAT16/FAT32: %s" % (path, e))
    if fat.label != "bootfs":
        bad("%s has the label '%s', not bootfs: neither GRUB nor the recovery finds it" % (path, fat.label))
    efi = fat.read("EFI/BOOT/BOOTX64.EFI")
    if efi is None:
        bad("bootfs has no EFI/BOOT/BOOTX64.EFI: the image does not boot with UEFI")
    else:
        check_efi_binary(efi, config)
    if not fat.read("boot/grub/grub.cfg"):
        bad("bootfs has no boot/grub/grub.cfg: neither GRUB has a menu")
    if fat.read("EFI/BOOT/grub.cfg") is not None:
        bad("bootfs has EFI/BOOT/grub.cfg (buildroot's sample menu): only boot/grub/grub.cfg belongs there")
    for f in ("recoveryfs-zImage", "recoveryfs-initrd"):
        if not fat.read(f):
            bad("bootfs has no %s: the recovery system is not in the image" % f)


def check_disk(images):
    disk = os.path.join(images, "sdcard.img")
    try:
        with open(disk, "rb") as f:
            mbr = f.read(512)
            def at(off, n):
                f.seek(off)
                return f.read(n)
            if len(mbr) < 512 or mbr[510:512] != b"\x55\xaa":
                return bad("%s has no MBR signature" % disk)
            try:
                boot = open(os.path.join(images, "boot.img"), "rb").read()
                core = open(os.path.join(images, "grub.img"), "rb").read()
            except OSError as e:
                return bad("GRUB's BIOS images are missing: %s" % e)
            if len(boot) < 440 or mbr[:440] != boot[:440]:
                bad("%s's MBR boot code is not GRUB's boot.img: the image does not boot with a BIOS" % disk)
            if not core or at(512, len(core)) != core:
                bad("%s does not hold GRUB's core image (grub.img) from sector 1: the image does not boot with a BIOS" % disk)
            status, ptype = mbr[446], mbr[446 + 4]
            start, count = struct.unpack("<II", mbr[446 + 8:446 + 16])
            if ptype not in FAT_TYPES:
                bad("%s's partition 1 has type %#04x, not a FAT type: a UEFI firmware may pass it by" % (disk, ptype))
            if status != 0x80:
                bad("%s's partition 1 is not marked active" % disk)
            vfat = os.path.join(images, "boot.vfat")
            try:
                size = os.path.getsize(vfat)
                with open(vfat, "rb") as v:
                    same = size <= count * 512
                    off = 0
                    while same and off < size:
                        chunk = v.read(1 << 20)
                        same = at(start * 512 + off, len(chunk)) == chunk
                        off += len(chunk)
                if not same:
                    bad("%s's partition 1 is not %s: the disk was not made from this bootfs" % (disk, vfat))
            except OSError as e:
                bad("%s: %s" % (vfat, e))
    except OSError as e:
        bad("%s: %s" % (disk, e))


def kconfig(path):
    on = set()
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.endswith("=y") and line.startswith("CONFIG_"):
                on.add(line[:-2])
    return on


def check_kernels(build):
    main = [c for c in glob.glob(os.path.join(build, "linux-*", ".config"))
            if not os.path.basename(os.path.dirname(c)).startswith(("linux-headers-", "linux-firmware-", "linux-tools"))]
    rec = [c for c in glob.glob(os.path.join(build, "recovery-system-*", "output", "build", "linux-*", ".config"))
           if not os.path.basename(os.path.dirname(c)).startswith(("linux-headers-", "linux-firmware-", "linux-tools"))]
    if not main:
        bad("no kernel .config under %s/linux-*/" % build)
    if not rec:
        bad("no kernel .config of the recovery system under %s/recovery-system-*/output/build/linux-*/" % build)
    for c in main + rec:
        on = kconfig(c)
        for opt in ("CONFIG_EFI", "CONFIG_EFI_STUB"):
            if opt not in on:
                bad("%s lacks %s=y: this kernel does not boot with UEFI" % (c, opt))
        fb = "CONFIG_FB_EFI" in on or ("CONFIG_SYSFB_SIMPLEFB" in on and ("CONFIG_DRM_SIMPLEDRM" in on or "CONFIG_FB_SIMPLE" in on))
        if not fb or "CONFIG_FRAMEBUFFER_CONSOLE" not in on:
            bad("%s has no console on the firmware's framebuffer (CONFIG_FRAMEBUFFER_CONSOLE with CONFIG_FB_EFI, or with "
                "CONFIG_SYSFB_SIMPLEFB and CONFIG_DRM_SIMPLEDRM or CONFIG_FB_SIMPLE): no screen under UEFI" % c)


def check_ova(images):
    ova = os.path.join(images, "OpenCCU.ova")
    try:
        with tarfile.open(ova) as t:
            ovf = [m for m in t.getmembers() if m.name.endswith(".ovf")]
            if not ovf:
                return bad("%s holds no .ovf" % ova)
            text = t.extractfile(ovf[0]).read().decode("utf-8", "replace")
    except (OSError, tarfile.TarError) as e:
        return bad("%s: %s" % (ova, e))
    if OVF_MARKER not in text:
        bad("%s's .ovf lacks the line '%s': install-proxmox.sh would refuse this image for a UEFI VM" % (ova, OVF_MARKER))


def main(argv):
    if len(argv) not in (3, 4):
        print(__doc__.strip().split("\n\n")[-1], file=sys.stderr)
        return 2
    images, build = argv[1], argv[2]
    cfg = argv[3] if len(argv) == 4 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "buildroot-external", "board", "lite", "ova-grub-efi.cfg")
    for d in (images, build):
        if not os.path.isdir(d):
            print("lite-efi-boot-guard: %s is not a directory" % d, file=sys.stderr)
            return 2
    try:
        config = open(cfg, "rb").read()
    except OSError as e:
        print("lite-efi-boot-guard: the embedded configuration: %s" % e, file=sys.stderr)
        return 2
    check_disk(images)
    check_bootfs(images, config)
    check_kernels(build)
    check_ova(images)
    if errors:
        return 1
    print("lite-efi-boot-guard: ok - BIOS (MBR boot code, core image) and UEFI (EFI/BOOT/BOOTX64.EFI) boot paths, one grub.cfg, EFI kernels")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
