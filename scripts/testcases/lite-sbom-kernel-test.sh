#!/bin/sh
# openccu-lite: scripts/lite-sbom.py names each package's CPE (show-info's cpe-id), lists the kernel
# with the version it was built as where Buildroot only knows "custom" (the Makefile in its build
# directory; version, bom-ref, purl and CPE), and --kernel-files writes the kernel sources the
# product compiled: an object with its .c, .S or .rs beside it, not the host tools, not a .mod.o,
# sorted, under a header with the product, the version and the kernel; nothing for a product
# without a kernel, and a stale list goes.
#
# Usage: sh scripts/testcases/lite-sbom-kernel-test.sh    (from the fork's checkout)
set -u
HERE=$(cd "$(dirname "$0")/../.." && pwd)
SBOM="$HERE/scripts/lite-sbom.py"
[ -f "$SBOM" ] || { echo "$SBOM not found"; exit 2; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT

cat > "$T/t.py" <<'PY'
import gzip, importlib.util, json, os, subprocess, sys
sbom, root = sys.argv[1], sys.argv[2]
s = importlib.util.spec_from_file_location("s", sbom)
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
fails = 0
def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1

def write(path, text=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)

def tree(name, info, kernel_dir=None, files=()):
    b = os.path.join(root, name)
    write(os.path.join(b, "show-info.json"), json.dumps(info))
    write(os.path.join(b, "target", "VERSION"), "VERSION=3.89.14\n")
    for n, i in info.items():
        d = os.path.join(b, "build", f"{n}-{i['version']}")
        write(os.path.join(d, "COPYING"), "GNU GENERAL PUBLIC LICENSE\nVersion 2, June 1991\n")
    if kernel_dir:
        k = os.path.join(b, "build", kernel_dir)
        write(os.path.join(k, "Makefile"), "# SPDX-License-Identifier: GPL-2.0\nVERSION = 6\nPATCHLEVEL = 18\nSUBLEVEL = 64\nEXTRAVERSION =\nNAME = Baby Opossum Posse\n")
        for f in files:
            write(os.path.join(k, f))
    return b

def run(b, product, *extra):
    out = os.path.join(b, "sbom.cdx.json.gz")
    exc = os.path.join(root, "exceptions.txt")
    write(exc, "")
    r = subprocess.run([sys.executable, sbom, "--build-dir", b, "--product", product, "--version", "9.9.9", "--out", out,
                        "--exceptions", exc, *extra], capture_output=True, text=True)
    with gzip.open(out, "rt", encoding="utf-8") as f:
        return r, {c["name"]: c for c in json.load(f)["components"]}

KFILES = ["kernel/fork.c", "kernel/fork.o", "arch/arm64/kernel/entry.S", "arch/arm64/kernel/entry.o",
          "net/ipv4/tcp.c", "net/ipv4/tcp.o", "net/sctp/socket.c",            # not compiled: no object
          "drivers/usb/core/usbcore.o", "drivers/usb/core/usb.c", "drivers/usb/core/usb.o",   # a composite object has no source
          "drivers/net/usb/r8152.c", "drivers/net/usb/r8152.o", "drivers/net/usb/r8152.mod.c", "drivers/net/usb/r8152.mod.o",
          "rust/kernel/lib.rs", "rust/kernel/lib.o",
          "scripts/mod/modpost.c", "scripts/mod/modpost.o", "tools/objtool/check.c", "tools/objtool/check.o",
          "usr/gen_init_cpio.c", "usr/gen_init_cpio.o", "vmlinux.o", "include/linux/tcp.h",
          ".vmlinux.export.c", ".vmlinux.export.o", ".tmp_vmlinux1.kallsyms.S", ".tmp_vmlinux1.kallsyms.o"]
lic = {"licenses": "GPL-2.0", "license_files": ["COPYING"]}

# a Raspberry Pi product: Buildroot's version is "custom"
pi = tree("pi", {
    "linux": {"type": "target", "version": "custom", "cpe-id": "cpe:2.3:o:linux:linux_kernel:custom:-:*:*:*:*:*:*", **lic},
    "busybox": {"type": "target", "version": "1.38.0", "cpe-id": "cpe:2.3:a:busybox:busybox:1.38.0:-:*:*:*:*:*:*", **lic},
    "lite-tools": {"type": "target", "version": "1", **lic},
}, "linux-custom", KFILES)
kf = os.path.join(pi, "kernel-files.txt")
r, c = run(pi, "aarch64-rpi4", "--kernel-files", kf)
check("the run succeeds", r.returncode == 0)
lin = c.get("linux", {})
check("the kernel's version is the built one", lin.get("version") == "6.18.64")
check("its bom-ref and purl carry it", lin.get("bom-ref") == "linux@6.18.64" and lin.get("purl") == "pkg:generic/linux@6.18.64")
check("its CPE carries it", lin.get("cpe") == "cpe:2.3:o:linux:linux_kernel:6.18.64:-:*:*:*:*:*:*")
props = {p["name"]: p["value"] for p in lin.get("properties", [])}
check("Buildroot's word is kept", props.get("openccu-lite:buildroot-version") == "custom")
check("a package's CPE is show-info's", c.get("busybox", {}).get("cpe") == "cpe:2.3:a:busybox:busybox:1.38.0:-:*:*:*:*:*:*")
check("a package without one has none", "cpe" not in c.get("lite-tools", {"cpe": 1}))
lines = open(kf, encoding="utf-8").read().splitlines() if os.path.exists(kf) else []
check("the list's header names the product, the version and the kernel",
      lines[:1] == ["# openccu-lite aarch64-rpi4 9.9.9: the kernel sources this product compiled (linux 6.18.64)"])
check("the compiled sources, sorted: .c, .S, .rs; no host tool, no .mod.c, no generated link file, nothing without an object",
      lines[1:] == ["arch/arm64/kernel/entry.S", "drivers/net/usb/r8152.c", "drivers/usb/core/usb.c", "kernel/fork.c",
                    "net/ipv4/tcp.c", "rust/kernel/lib.rs"])

# the VM: Buildroot knows the version, nothing is rewritten
ova = tree("ova", {"linux": {"type": "target", "version": "6.18.59", "cpe-id": "cpe:2.3:o:linux:linux_kernel:6.18.59:-:*:*:*:*:*:*", **lic}},
           "linux-6.18.59", ["kernel/fork.c", "kernel/fork.o"])
r, c = run(ova, "x86_64-ova", "--kernel-files", os.path.join(ova, "kernel-files.txt"))
lin = c.get("linux", {})
check("a version Buildroot knows stays (not the Makefile's)", lin.get("version") == "6.18.59" and lin.get("cpe", "").split(":")[5] == "6.18.59")
check("and carries no buildroot-version", not any(p["name"] == "openccu-lite:buildroot-version" for p in lin.get("properties", [])))
check("its list is written", open(os.path.join(ova, "kernel-files.txt")).read().splitlines()[1:] == ["kernel/fork.c"])

# a container image: no kernel, no list - and a stale one goes
lxc = tree("lxc", {"busybox": {"type": "target", "version": "1.38.0", **lic}})
stale = os.path.join(lxc, "kernel-files.txt")
write(stale, "# old\nkernel/fork.c\n")
r, c = run(lxc, "lxc-lite_arm64", "--kernel-files", stale)
check("a product without a kernel: the run succeeds", r.returncode == 0 and "linux" not in c)
check("and no list is left", not os.path.exists(stale))

# a kernel whose build directory holds no object: said, and --check fails
gone = tree("gone", {"linux": {"type": "target", "version": "custom", **lic}}, "linux-custom", ["kernel/fork.c"])
r, c = run(gone, "aarch64-rpi4", "--kernel-files", os.path.join(gone, "kernel-files.txt"), "--check")
check("a kernel without objects: --check fails and says why", r.returncode == 1 and "kernel-files" in r.stderr)
check("without --kernel-files nothing is written", run(pi, "aarch64-rpi4")[0].returncode == 0)
# custom without a Makefile: the version stays Buildroot's
bare = tree("bare", {"linux": {"type": "target", "version": "custom", "cpe-id": "cpe:2.3:o:linux:linux_kernel:custom:-:*:*:*:*:*:*", **lic}})
r, c = run(bare, "aarch64-rpi4")
check("custom with no build directory: Buildroot's word stays", c.get("linux", {}).get("version") == "custom")
sys.exit(1 if fails else 0)
PY
python3 "$T/t.py" "$SBOM" "$T/b"
rc=$?
[ $rc -eq 0 ] && echo "all passed" || echo "FAILED"
exit $rc
