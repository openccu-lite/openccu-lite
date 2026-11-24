#!/usr/bin/env python3
"""openccu-lite: the image's SBOM, CycloneDX 1.6 with the licence texts (task 179).

Usage (the post-build step runs it; by hand after a build works the same):

    scripts/lite-sbom.py --build-dir build-<product> --product <product> --version <lite version> \\
        [--check] [--exceptions buildroot-external/sbom-exceptions.txt] --out <file>[.gz]

What becomes a component:
- every target package of `make show-info` (build-<p>/show-info.json, written before the build),
  with its licence expression and the texts of its licence files, read from the package's build
  directory;
- OpenCCU-Base split into what reaches the image (build/packages-file-list.txt against the target
  tree): each program and library, the four JARs with the libraries each bundles (their
  *-JARLICENSEINFO.txt, and the Maven metadata each JAR keeps of them: META-INF/maven/*/*/
  pom.properties; nested under the JAR), the firmware, the device descriptions and the
  configuration files - HMSL-2.0 unless licenses/licenses.md says otherwise;
- occulited with the Go modules it links (vendor/modules.txt, each module's LICENSE; checked against
  `go version -m` when the host Go is there) and the npm packages its UI bundle ships
  (internal/ui/bundle-licenses.json), nested under it;
- linux-firmware per WHENCE entry that has a file in the image.

The CVEs Buildroot marks as not applying to a package (`<PKG>_IGNORE_CVES`, show-info's `ignore_cves`;
openccu-lite task 483) are the SBOM's `vulnerabilities`, one per CVE and package, as Buildroot's own
utils/generate-cyclonedx writes them: `resolved_with_pedigree` when a patch the package applies names
the CVE in its `CVE:` header (a backported fix), `not_affected` otherwise; the patches in the property
`openccu-lite:patches`, the variable in `openccu-lite:ignore-var`. scripts/lite-cve-scan.py takes such
a CVE as fixed in that release and marks the cell "+ patch".

Each package carries the CPE Buildroot names for it (show-info's `cpe-id`) as `cpe`, which is what
scripts/lite-cve-scan.py matches against the NVD's. The kernel is listed with the version it was
built as - the VERSION, PATCHLEVEL and SUBLEVEL of its Makefile in the build directory - where
Buildroot only knows `custom` (a tarball by commit: the Raspberry Pi products), in its version, its
bom-ref, its purl and its CPE; `openccu-lite:buildroot-version` keeps Buildroot's word.

--kernel-files <file> also writes the list of the kernel sources this product compiled (openccu-lite
task 473): one path per line for every object in the kernel's build directory that has its .c, .S or
.rs beside it, sorted, after a `#` header with the product, the version and the kernel. A release
publishes it beside the SBOM, and the CVE scanner drops a kernel CVE whose fix touches no file of
it. Nothing is written for a product without a kernel (a container image).

Each distinct licence text is stored once: the first licence that carries it has `text` and a
`bom-ref`, every other names that ref in `properties[openccu-lite:text-ref]` (occulited's
/licenses page reads it that way). `properties[openccu-lite:origin]` says where a top-level component
comes from.

--check fails (exit 1) on a component without a licence or with `unknown`, a target package without
a component, a Go module without a licence file or linked but not vendored, a JAR library line that
could not be read, a JAR with no library found - unless the exceptions file names it, with a reason. No network, no module
outside Python's standard library.
"""
import copy
import argparse
import glob
import gzip
import hashlib
import json
import os
import re
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET
import zipfile
from datetime import datetime, timezone
from urllib.parse import quote

# --- licences ---------------------------------------------------------------------------------

# buildroot's short forms to SPDX ids; an expression that is not one of these (several licences,
# comments in parentheses) stays a name
SPDX = {
    "GPL-2.0": "GPL-2.0-only", "GPL-2.0+": "GPL-2.0-or-later", "GPL-2.0-only": "GPL-2.0-only",
    "GPL-2.0-or-later": "GPL-2.0-or-later", "GPL2": "GPL-2.0-only", "GPLv2": "GPL-2.0-only",
    "GPL-3.0": "GPL-3.0-only", "GPL-3.0+": "GPL-3.0-or-later", "GPL-3.0-or-later": "GPL-3.0-or-later",
    "LGPL-2.1": "LGPL-2.1-only", "LGPL-2.1+": "LGPL-2.1-or-later", "LGPL-2.1-or-later": "LGPL-2.1-or-later",
    "LGPL-2.0+": "LGPL-2.0-or-later", "LGPL-3.0": "LGPL-3.0-only", "LGPL-3.0+": "LGPL-3.0-or-later",
    "MIT": "MIT", "ISC": "ISC", "Zlib": "Zlib", "BSD-2-Clause": "BSD-2-Clause", "BSD-3-Clause": "BSD-3-Clause",
    "Apache-2.0": "Apache-2.0", "MPL-2.0": "MPL-2.0", "OFL-1.1": "OFL-1.1", "curl": "curl", "NTP": "NTP",
    "TCL": "TCL", "OpenSSL": "OpenSSL", "PSF-2.0": "PSF-2.0", "Unlicense": "Unlicense", "CC0-1.0": "CC0-1.0",
    "EPL-1.0": "EPL-1.0", "EPL-2.0": "EPL-2.0", "BSL-1.0": "BSL-1.0", "0BSD": "0BSD",
    "LGPL-2.1-only": "LGPL-2.1-only", "LGPL-3.0-only": "LGPL-3.0-only", "GPL-3.0-only": "GPL-3.0-only",
}

# what buildroot's line does not say, and why this may: the package's own licence file is the text
LICENSE_OVERRIDES = {
    # buildroot 2026.08 has no SPDX id for it; the fonts' LICENSE is the Bitstream Vera licence with
    # the DejaVu changes in the public domain
    "dejavu": "Bitstream-Vera AND LicenseRef-DejaVu-public-domain",
    # buildroot's line warns that the vendored modules are not listed; this SBOM lists them
    "occulited": "GPL-3.0-only",
    # the kernel's tools (lsgpio and the like), built from the kernel's tree
    "linux-tools": "GPL-2.0",
    # the recovery image's part of OpenCCU-Base (eq3configd and what it needs)
    "hm-platform": "HMSL-2.0",
    # an external toolchain's runtime in the image: glibc and GCC's libraries
    "toolchain-external-custom": "LGPL-2.1-or-later AND GPL-3.0-or-later WITH GCC-exception-3.1",
}

# a package whose licence file is another package's (the same source tree)
TEXT_FROM = {"linux-tools": "linux"}

# licence files a package's .mk does not name
LICENSE_FILES = {"hm-platform": ["licenses/HMSL2.txt"]}

# the licence names in the JARs' lists (Maven's) to SPDX ids
MAVEN = [
    (r"apache.*2\.0|^apache-2\.0$|asl 2\.0|^apache 2$|^apache software licen[cs]e$", "Apache-2.0"),
    (r"^(the )?mit|mit license", "MIT"),
    (r"new bsd|bsd[- ]3|revised bsd|3-clause", "BSD-3-Clause"),
    (r"bsd[- ]2|simplified bsd|2-clause", "BSD-2-Clause"),
    (r"^bsd( license)?$", "BSD-3-Clause"),
    (r"eclipse public license.*2\.0|epl[- ]?2", "EPL-2.0"),
    (r"eclipse public license.*1\.0|epl[- ]?1", "EPL-1.0"),
    (r"eclipse distribution license|edl 1\.0", "BSD-3-Clause"),
    (r"lesser.*3|lgpl.*3", "LGPL-3.0-only"),
    (r"lesser.*2\.1|lgpl.*2\.1", "LGPL-2.1-only"),
    (r"gpl2? w/ cpe|classpath", "GPL-2.0-only WITH Classpath-exception-2.0"),
    (r"cddl.*1\.1", "CDDL-1.1"),
    (r"cddl", "CDDL-1.0"),
    (r"mozilla public license.*2\.0|mpl[- ]2", "MPL-2.0"),
    (r"public domain", "LicenseRef-public-domain"),
    (r"bouncy castle", "MIT"),
    (r"go license", "BSD-3-Clause"),
]


def maven_license(name):
    n = name.strip().lower()
    for pat, spdx in MAVEN:
        if re.search(pat, n):
            return spdx
    return None


def detect(text):
    """An SPDX id for a licence text, when it is plainly one of the common ones."""
    t = re.sub(r"\s+", " ", text)
    if "Apache License" in t and "Version 2.0" in t:
        return "Apache-2.0"
    if "Mozilla Public License Version 2.0" in t or "Mozilla Public License, version 2.0" in t:
        return "MPL-2.0"
    if "Permission is hereby granted, free of charge" in t:
        return "MIT"
    if "Permission to use, copy, modify, and/or distribute this software for any purpose" in t:
        return "ISC"
    if "Redistribution and use in source and binary forms" in t:
        return "BSD-3-Clause" if ("Neither the name" in t or "names of its contributors" in t) else "BSD-2-Clause"
    # the version from the text's own head; "-only", since the text alone does not say "or later"
    head = t[:400]
    if "GNU AFFERO GENERAL PUBLIC LICENSE" in head and "Version 3" in head:
        return "AGPL-3.0-only"
    if "GNU LESSER GENERAL PUBLIC LICENSE" in head and "Version 3" in head:
        return "LGPL-3.0-only"
    if "GNU LESSER GENERAL PUBLIC LICENSE" in head and "Version 2.1" in head:
        return "LGPL-2.1-only"
    if "GNU GENERAL PUBLIC LICENSE" in head and "Version 3" in head:
        return "GPL-3.0-only"
    if "GNU GENERAL PUBLIC LICENSE" in head and "Version 2" in head:
        return "GPL-2.0-only"
    return None


# the standard licence texts, for a component whose own files are not at hand (a JAR's libraries, a
# package without a licence file): SPDX's texts, kept in buildroot-external/sbom-licenses. Only
# licences whose text is the same everywhere - an MIT or BSD text carries its project's own
# copyright line, so another project's is never borrowed.
CANONICAL_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "buildroot-external", "sbom-licenses")
CANONICAL = {
    "Apache-2.0": "Apache-2.0", "EPL-1.0": "EPL-1.0", "EPL-2.0": "EPL-2.0", "MPL-2.0": "MPL-2.0",
    "CDDL-1.0": "CDDL-1.0", "CDDL-1.1": "CDDL-1.1",
    "GPL-2.0-only": "GPL-2.0-only", "GPL-2.0-or-later": "GPL-2.0-only",
    "GPL-3.0-only": "GPL-3.0-only", "GPL-3.0-or-later": "GPL-3.0-only",
    "LGPL-2.1-only": "LGPL-2.1-only", "LGPL-2.1-or-later": "LGPL-2.1-only",
    "LGPL-3.0-only": "LGPL-3.0-only", "LGPL-3.0-or-later": "LGPL-3.0-only",
}


def canonical_text(ident):
    f = CANONICAL.get(ident)
    return read(os.path.join(CANONICAL_DIR, f + ".txt")) if f else None


def maven_text(purl):
    """A bundled Maven library's own licence file (with its copyright line), kept in
    sbom-licenses/maven/<group>.txt: the JARs' license folders carry only templates and web pages."""
    m = re.match(r"^pkg:maven/([^/]+)/", purl or "")
    return read(os.path.join(CANONICAL_DIR, "maven", m.group(1) + ".txt")) if m else None


class Texts:
    """Each distinct text once: the first user carries it, the others refer to it."""

    def __init__(self):
        self.refs = {}

    def licence(self, lic, text):
        if not text:
            return lic
        h = hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:16]
        ref = f"lic-{h}"
        if h in self.refs:
            lic.setdefault("properties", []).append({"name": "openccu-lite:text-ref", "value": ref})
        else:
            self.refs[h] = ref
            lic["text"] = {"contentType": "text/plain", "content": text}
            lic["bom-ref"] = ref
        return lic


def licences(texts, expr, text=None):
    """The CycloneDX licences of a component: one id with its text, or the expression as a name."""
    expr = (expr or "").strip()
    if not expr and not text:
        return []
    ident = SPDX.get(expr)
    if not ident and not text:
        parts = split_expression(texts, expr)
        if parts:
            return [{"license": p} for p in parts]
    lic = {"id": ident} if ident else {"name": expr or "see text"}
    return [{"license": texts.licence(lic, text)}]


def split_expression(texts, expr):
    """A package's licence of several parts ("GPL-2.0-or-later, LGPL-2.1-or-later (factory/var.mount)",
    "LGPL-2.1-or-later AND GPL-3.0-or-later WITH GCC-exception-3.1") as one licence per part, when
    every part has a standard text here; a choice (OR) or a part without one leaves it as it is."""
    if re.search(r"\bOR\b", expr):
        return None
    out = []
    for part in re.split(r"\s*(?:,|\bAND\b)\s*", expr):
        part = re.sub(r"\s*\([^)]*\)\s*$", "", part).strip()
        m = re.match(r"^(\S+)(?:\s+WITH\s+(\S+))?$", part)
        if not m:
            return None
        ident = SPDX.get(m.group(1), m.group(1))
        if ident not in CANONICAL:
            return None
        if m.group(2):
            exc = read(os.path.join(CANONICAL_DIR, m.group(2) + ".txt"))
            if not exc:
                return None
            # an exception is no licence id of its own: the name says both, the text has both
            out.append(texts.licence({"name": f"{ident} WITH {m.group(2)}"}, exc.rstrip() + "\n\n" + canonical_text(ident)))
        else:
            out.append({"id": ident})
    return out if len(out) > 1 or (out and "name" in out[0]) else None


# "Copyright (c) 2016 Name", "Copyright © ...", "Copyright: Name", "Copyright 2014 Name", "(c) 2003 Name" -
# not a sentence of a licence's body ("copyright law", "copyright license to ...")
COPYRIGHT_LINE = re.compile(r"^\s*(?:copyright\s*(?:\(c\)|©|:|\d)|\(c\)\s*\d|©\s*\d)", re.I)


def copyright_of(text):
    """The copyright lines of a component's own licence file - not the licence's authors (the FSF
    in every GPL text) and not a template's placeholders - at most three."""
    out = []
    for line in (text or "").splitlines():
        line = line.strip().strip("*#/ ").strip()
        if not COPYRIGHT_LINE.match(line) or len(line) > 200:
            continue
        low = line.lower()
        if "free software foundation" in low or "[yyyy]" in low or "<year>" in low or "{yyyy}" in low or "copyright holders" in low or "copyright owner" in low or "copyright notice" in low or "name of author" in low or "19yy" in low or re.search(r"\byear\b", low):
            continue
        if line not in out:
            out.append(line)
        if len(out) == 3:
            break
    return "\n".join(out)


def read(path, limit=2_000_000):
    try:
        with open(path, "rb") as f:
            return f.read(limit).decode("utf-8", "replace")
    except OSError:
        return None


def join_texts(parts):
    """Several licence files of one package as one text, each under its file name."""
    parts = [(n, t) for n, t in parts if t]
    if not parts:
        return None
    if len(parts) == 1:
        return parts[0][1]
    return "\n\n".join(f"==> {n} <==\n{t.strip()}" for n, t in parts)


# --- where things are ---------------------------------------------------------------------------

class Build:
    def __init__(self, root):
        self.root = root
        with open(os.path.join(root, "show-info.json"), encoding="utf-8") as f:
            self.info = json.load(f)
        self.target = set()
        tgt = os.path.join(root, "target")
        tf = os.path.join(root, "target-files.txt")  # a list instead of the tree (a copy of the inputs)
        if os.path.isdir(tgt):
            for d, dirs, files in os.walk(tgt):
                for fn in files + [x for x in dirs if os.path.islink(os.path.join(d, x))]:
                    self.target.add(os.path.relpath(os.path.join(d, fn), tgt))
        elif os.path.exists(tf):
            with open(tf, encoding="utf-8") as f:
                self.target = {l.strip() for l in f if l.strip()}
        self.files = {}  # package -> the files it installed that are still in the target
        pl = os.path.join(root, "build", "packages-file-list.txt")
        if os.path.exists(pl):
            with open(pl, encoding="utf-8", errors="replace") as f:
                for line in f:
                    pkg, _, path = line.rstrip("\n").partition(",")
                    path = path[2:] if path.startswith("./") else path
                    if path in self.target:
                        self.files.setdefault(pkg, []).append(path)

    def pkgdir(self, name):
        v = self.info.get(name, {}).get("version") or ""
        base = os.path.join(self.root, "build")
        d = os.path.join(base, f"{name}-{v}" if v else name)
        if os.path.isdir(d):
            return d
        if os.path.isdir(base):
            for e in sorted(os.listdir(base)):
                if e.startswith(name + "-") and os.path.isdir(os.path.join(base, e)):
                    return os.path.join(base, e)
        return None

    def license_text(self, name):
        files = LICENSE_FILES.get(name) or self.info.get(TEXT_FROM.get(name, name), {}).get("license_files") or []
        name = TEXT_FROM.get(name, name)
        d = self.pkgdir(name)
        parts = [(f, read(os.path.join(d, f)) if d else None) for f in files]
        # a build directory cleaned since: legal-info keeps a copy of the licence files
        v = self.info.get(name, {}).get("version") or ""
        li = os.path.join(self.root, "legal-info", "licenses", f"{name}-{v}" if v else name)
        parts = [(f, t if t is not None else read(os.path.join(li, f))) for f, t in parts]
        return join_texts(parts)


# --- the CVEs Buildroot marks as not applying (task 483) ---------------------------------------

def patch_cves(path):
    """the CVE ids a patch's header names on its `CVE:` lines (Buildroot's convention), [] when unreadable"""
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith(("diff ", "--- ", "Index: ")):
                    break
                if line.startswith("CVE: "):
                    out.extend(re.findall(r"CVE-\d{4}-\d+", line))
    except OSError:
        pass
    return out


def package_patches(b, name):
    """the patches a package applies: show-info's list (relative to the build directory, or absolute), else
    the build directory's .applied_patches_list"""
    out = []
    for p in b.info.get(name, {}).get("patches") or []:
        out.append(p if os.path.isabs(p) else os.path.join(b.root, p))
    d = b.pkgdir(name)
    if not out and d:
        lst = read(os.path.join(d, ".applied_patches_list")) or ""
        out = [l.strip() for l in lst.splitlines() if l.strip()]
    return out


def vulnerabilities(b, comps):
    """the SBOM's vulnerabilities: per CVE and target package that ignores it, resolved_with_pedigree when a
    patch of the package names the CVE, not_affected otherwise"""
    refs = {c["name"]: c["bom-ref"] for c in comps}
    out = []
    for name in sorted(refs):
        cves = (b.info.get(name) or {}).get("ignore_cves") or []
        if not cves:
            continue
        patched = {}
        for p in package_patches(b, name):
            for cve in patch_cves(p):
                patched.setdefault(cve, []).append(os.path.basename(p))
        var = re.sub(r"[^A-Z0-9]", "_", name.upper()) + "_IGNORE_CVES"
        for cve in sorted(set(cves)):
            props = [{"name": "openccu-lite:ignore-var", "value": var}]
            if cve in patched:
                props.append({"name": "openccu-lite:patches", "value": " ".join(sorted(patched[cve]))})
                analysis = {"state": "resolved_with_pedigree",
                            "detail": f"Buildroot applies a patch that fixes it ({', '.join(sorted(patched[cve]))}; {var})"}
            else:
                analysis = {"state": "not_affected", "detail": f"Buildroot marks it as not applying to this package ({var})"}
            out.append({"id": cve, "source": {"name": "NVD", "url": f"https://nvd.nist.gov/vuln/detail/{cve}"},
                        "analysis": analysis, "affects": [{"ref": refs[name]}], "properties": props})
    return out


# --- components ---------------------------------------------------------------------------------

# the authors of Go modules, by module path prefix, where the module does not say
GO_AUTHORS = {"github.com/mdzio/": "Mathias Dzionsko"}

# where a top-level component comes from: the title (the authors are the Author column's) and the
# repository the Licences page links (openccu-lite:origin-url); openccu-lite is not published yet,
# so it has no link
REPOS = {
    "buildroot": "https://github.com/buildroot/buildroot",
    "OpenCCU": "https://github.com/OpenCCU/OpenCCU",
    "OpenCCU-Base": "https://github.com/OpenCCU/OpenCCU-Base",
    "piVCCU": "https://github.com/openccu-lite/piVCCU",
    "git.zerfleddert.de": "https://git.zerfleddert.de/cgi-bin/gitweb.cgi/hmcfgusb",
    "linux-firmware": "https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git",
    "Azul Zulu": "https://www.azul.com/downloads/",
}

ORIGINS = {
    "generic_raw_uart": ("piVCCU", {"authors": [{"name": "Alexander Reinert"}]}),
    "detect_radio_module": ("piVCCU", {"authors": [{"name": "Alexander Reinert"}]}),
    "hmcfgusb": ("git.zerfleddert.de", {"supplier": {"name": "Michael Gernoth"}, "authors": [{"name": "Michael Gernoth"}]}),
    "eq3_char_loop": ("OpenCCU-Base", {"supplier": {"name": "eQ-3 AG"}}),
    "occulited": ("openccu-lite", {"authors": [{"name": "Sebastian Raff"}]}),
    "lite-bindlo": ("openccu-lite", {}),
    "recovery-system": ("OpenCCU", {"authors": [{"name": "Jens Maus"}]}),
    "multilib32": ("OpenCCU", {"authors": [{"name": "Jens Maus"}]}),
    "rpi-rf-mod": ("OpenCCU", {"authors": [{"name": "Jens Maus"}]}),
    "hmlangw": ("OpenCCU", {"authors": [{"name": "Oliver Kastl"}, {"name": "Jens Maus"}]}),
    "java-azul": ("Azul Zulu", {"supplier": {"name": "Azul Systems"}}),
}


def origin(name):
    """The origin properties: the title and, where the project is published, its repository."""
    props = [{"name": "openccu-lite:origin", "value": name}]
    if REPOS.get(name):
        props.append({"name": "openccu-lite:origin-url", "value": REPOS[name]})
    return props



def urls(info):
    out = []
    for d in info.get("downloads") or []:
        for u in d.get("uris") or []:
            scheme, _, rest = u.partition("://")
            u = scheme.split("+")[-1].split("|")[0] + "://" + rest
            if "sources.buildroot.net" in u:
                continue
            out.append({"type": "distribution", "url": u})
    return out[:2]


def kernel_version(b):
    """the kernel's version as it was built, from its Makefile in the build directory; None without one"""
    d = b.pkgdir("linux")
    mk = read(os.path.join(d, "Makefile")) if d else None
    if not mk:
        return None
    f = dict(re.findall(r"^(VERSION|PATCHLEVEL|SUBLEVEL)\s*=\s*(\d+)\s*$", mk, re.M))
    if len(f) != 3:
        return None
    return f"{f['VERSION']}.{f['PATCHLEVEL']}.{f['SUBLEVEL']}"


KERNEL_SOURCES = (".c", ".S", ".rs")


def kernel_files(b):
    """the kernel sources the product compiled: every object in the build directory with its source beside it"""
    d = b.pkgdir("linux")
    if not d:
        return None
    out = set()
    for cur, dirs, files in os.walk(d):
        rel = os.path.relpath(cur, d)
        # the host tools and the generated user-space helpers are not the kernel
        dirs[:] = [x for x in dirs if not (rel == "." and x in ("scripts", "tools", "usr", "Documentation", "samples"))]
        names = set(files)
        for fn in files:
            # not a module's generated .mod.c, not the link's own generated files (.vmlinux.export.c, .tmp_vmlinux*)
            if not fn.endswith(".o") or fn.endswith(".mod.o") or fn.startswith("."):
                continue
            for ext in KERNEL_SOURCES:
                if fn[:-2] + ext in names:
                    out.add(os.path.normpath(os.path.join(rel, fn[:-2] + ext)))
                    break
    return sorted(out)


def package(texts, b, name):
    i = b.info[name]
    version = str(i.get("version") or "")
    cpe = str(i.get("cpe-id") or "")
    props = []
    if name == "linux" and not re.match(r"^\d+\.\d+", version):
        real = kernel_version(b)
        if real:
            props = [{"name": "openccu-lite:buildroot-version", "value": version}]
            # cpe:2.3:o:linux:linux_kernel:<version>:...
            parts = cpe.split(":")
            if len(parts) > 5:
                parts[5] = real
                cpe = ":".join(parts)
            version = real
    origin_name, extra = ORIGINS.get(name, ("buildroot", {}))
    expr = LICENSE_OVERRIDES.get(name, i.get("licenses") or "")
    text = b.license_text(name)
    c = {
        "type": "library",
        "bom-ref": f"{name}@{version}" if version else name,
        "name": name,
        "version": version,
        "licenses": licences(texts, expr, text),
        "purl": f"pkg:generic/{name}@{version}" if version else f"pkg:generic/{name}",
        "properties": origin(origin_name) + props,
    }
    if cpe.startswith("cpe:2.3:"):
        c["cpe"] = cpe
    c.update(extra)
    cr = copyright_of(text)
    if cr:
        c["copyright"] = cr
    refs = urls(i)
    if refs:
        c["externalReferences"] = refs
    return c


def base_group(path):
    """OpenCCU-Base's files in the image, grouped the way a reader looks for them."""
    if path.startswith("usr/bin/") or (path.startswith("usr/lib/") and path.endswith(".so")):
        return os.path.basename(path)
    if path.startswith("usr/lib/tcl8.6/homematic/"):
        return "tclrpc.so"
    if path == "opt/HMServer/HMIPServer.jar":
        return "HMIPServer.jar"
    if path.startswith("opt/HMServer/coupling/"):
        return "ESHBridge.jar"
    if path == "opt/HMServer/HMServer.jar":
        # from OpenCCU-Base's release archive: VirtualDevices without an HmIP module (B-313)
        return "HMServer.jar"
    if path.startswith("opt/HMServer/"):
        # the group definitions hmipserver reads (task 329)
        return "HMIPServer.jar"
    if path.startswith("opt/HmIP/hmip-copro-update.jar"):
        return "hmip-copro-update.jar"
    if path.startswith("firmware/rftypes/") or path.startswith("firmware/hs485types/"):
        return "device descriptions"
    if path.startswith("firmware/"):
        return "radio and device firmware"
    if path.startswith("opt/HmIP/") or path.startswith("etc/"):
        return "configuration files"
    # the WebUI's files addons read, at the CCU's paths (task 331); Apache-2.0 per licenses.md
    if path.startswith("www/config/img/devices/"):
        return "WebUI device pictures"
    if path.startswith("www/config/devdescr/"):
        return "WebUI device catalogue"
    if path == "www/config/stringtable_de.txt" or path.startswith("www/webui/js/lang/"):
        return "WebUI translations"
    return None


PAREN = r"\([^()]*(?:\([^()]*\)[^()]*)*\)"
JAR_LINE = re.compile(r"^\s*((?:" + PAREN + r"\s*)+)(.*?)\s*\(([^:()\s]+):([^:()\s]+):([^\s()]+)\s+-\s+([^()\s]*)\)\s*$")


def maven_component(names, name, group, artifact, version, url):
    """A bundled Maven library as a component: its licence names (Maven's spelling) to SPDX."""
    ids = list(dict.fromkeys(maven_license(n) or n for n in names))
    choice = False
    if not names:
        lic = []
    elif len(ids) == 1 and " " not in ids[0] and maven_license(names[0]):
        lic = [{"license": {"id": ids[0]}}]
    elif all(maven_license(n) and " " not in maven_license(n) for n in names):
        # a choice of licences (dual licensing): each licence of its own, so each carries its
        # text; the property says the list is a choice, not all of them at once
        lic = [{"license": {"id": i}} for i in ids]
        choice = True
    elif all(maven_license(n) for n in names):
        lic = [{"expression": " OR ".join(ids)}]
    else:
        lic = [{"license": {"name": " / ".join(names)}}]
    c = {
        "type": "library",
        "bom-ref": f"pkg:maven/{group}/{artifact}@{version}",
        "name": name or artifact,
        "group": group,
        "version": version,
        "purl": f"pkg:maven/{group}/{artifact}@{version}",
        "licenses": lic,
    }
    if choice:
        c["properties"] = [{"name": "openccu-lite:licence-choice", "value": "OR"}]
    if url:
        c["externalReferences"] = [{"type": "website", "url": url}]
    return c


def jar_libraries(path, errors):
    """A JAR's bundled libraries from its *-JARLICENSEINFO.txt (Maven's license list)."""
    out = []
    started = False
    for line in (read(path) or "").splitlines():
        if re.match(r"^\s*Lists? of \d+ third-party dependenc", line):
            started = True
            continue
        if not started:
            continue
        if not line.strip():
            if out:
                break
            continue
        m = JAR_LINE.match(line)
        if not m:
            errors.append(("jar-line", f"{os.path.basename(path)}: {line.strip()}"))
            continue
        names = [n[1:-1] for n in re.findall(PAREN, m.group(1))]
        out.append(maven_component(names, m.group(2).strip(), m.group(3), m.group(4), m.group(5), m.group(6)))
    return out


# the licences of bundled libraries whose own pom.xml names none (their parent POM does), by
# group:artifact or group, in Maven's spelling - as the JARs' third-party lists of the 1.2 line and the
# projects' parent POMs name them
MAVEN_LICENCES = {
    "com.fasterxml.jackson.dataformat": ["Apache-2.0"],
    "com.fasterxml.jackson.module": ["Apache-2.0"],
    "com.google.guava": ["Apache-2.0"],
    "com.sun.xml.bind.jaxb:isorelax": ["MIT"],
    "commons-codec": ["Apache-2.0"],
    "commons-io": ["Apache-2.0"],
    "commons-lang": ["Apache-2.0"],
    "commons-logging": ["Apache-2.0"],
    "commons-net": ["Apache-2.0"],
    "io.dropwizard.metrics": ["Apache-2.0"],
    "io.netty": ["Apache-2.0"],
    "io.prometheus": ["Apache-2.0"],
    "io.vertx": ["EPL-2.0", "Apache-2.0"],
    "io.vertx:vertx-auth-common": ["EPL-1.0", "Apache-2.0"],
    "io.vertx:vertx-bridge-common": ["EPL-1.0", "Apache-2.0"],
    "io.vertx:vertx-dropwizard-metrics": ["EPL-1.0", "Apache-2.0"],
    "io.vertx:vertx-web-common": ["EPL-1.0", "Apache-2.0"],
    "org.apache.commons": ["Apache-2.0"],
    "org.apache.httpcomponents": ["Apache-2.0"],
    "org.apache.logging.log4j": ["Apache-2.0"],
    "org.eclipse.jetty": ["Apache-2.0", "EPL-1.0"],
    "org.eclipse.paho": ["EPL-2.0"],
    "org.jupnp": ["CDDL-1.0"],
    "org.slf4j": ["MIT"],
}

# the JAR's own modules (eQ-3's): the JAR itself, not a library it bundles
OWN_GROUPS = ("de.eq3",)

POM_PROPERTIES = re.compile(r"^META-INF/maven/([^/]+)/([^/]+)/pom\.properties$")


def pom_fields(data):
    """name, url and licence names of a pom.xml, without its parent's."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError:
        return "", "", []
    ns = root.tag[:root.tag.index("}") + 1] if root.tag.startswith("{") else ""
    def text(el, tag):
        e = el.find(ns + tag)
        return (e.text or "").strip() if e is not None and e.text else ""
    lics = [text(l, "name") for l in root.findall(f"{ns}licenses/{ns}license")]
    return text(root, "name"), text(root, "url"), [n for n in lics if n]


def jar_maven_libraries(path):
    """A JAR's bundled libraries from the Maven metadata its build keeps of each:
    META-INF/maven/<group>/<artifact>/pom.properties (the version) and the pom.xml next to it (name,
    website, licences; MAVEN_LICENCES when it names none). The HMIPServer JARs of OpenCCU-Base 2.0
    carry no third-party list (B-360); this is what a JAR scanner reads too."""
    out = []
    try:
        z = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile):
        return out
    with z:
        names = set(z.namelist())
        for n in sorted(names):
            m = POM_PROPERTIES.match(n)
            if not m or m.group(1).startswith(OWN_GROUPS):
                continue
            props = {}
            for line in z.read(n).decode("utf-8", "replace").splitlines():
                k, sep, v = line.partition("=")
                if sep and not k.lstrip().startswith("#"):
                    props[k.strip()] = v.strip()
            group = props.get("groupId") or m.group(1)
            artifact = props.get("artifactId") or m.group(2)
            version = props.get("version") or ""
            name, url, lics = "", "", []
            pom = n[: -len("pom.properties")] + "pom.xml"
            if pom in names:
                name, url, lics = pom_fields(z.read(pom))
            if not lics:
                lics = MAVEN_LICENCES.get(f"{group}:{artifact}") or MAVEN_LICENCES.get(group) or []
            out.append(maven_component(lics, name, group, artifact, version, url))
    return out


def merge_libraries(listed, found):
    """The listed libraries, then the ones found in the JAR's metadata that the list misses."""
    seen = {(c["group"], c["purl"].rsplit("@", 1)[0]) for c in listed}
    return listed + [c for c in found if (c["group"], c["purl"].rsplit("@", 1)[0]) not in seen]


def openccu_base(texts, b, errors):
    d = b.pkgdir("openccu-base") or ""
    hmsl = read(os.path.join(d, "licenses", "HMSL2.txt"))
    lgpl = read(os.path.join(d, "licenses", "lgpl-2.1.txt"))
    # licenses.md's exceptions table: path | licence
    lgpl_libs = set()
    for line in (read(os.path.join(d, "licenses", "licenses.md")) or "").splitlines():
        m = re.match(r"^\s*(lib/[\w.]+)\s*\|\s*(.+?)\s*$", line)
        if m and "LGPL-2.1" in m.group(2):
            lgpl_libs.add(os.path.basename(m.group(1)))
    version = str(b.info.get("openccu-base", {}).get("version") or "")
    groups = {}
    for f in b.files.get("openccu-base", []):
        g = base_group(f)
        if g:
            groups.setdefault(g, []).append(f)
    out = []
    for g in sorted(groups):
        if g in lgpl_libs:
            lic = texts.licence({"id": "LGPL-2.1-only"}, lgpl)
        elif g.startswith("WebUI "):
            # licenses.md: "src/webui | Apache 2.0 if not stated otherwise" (task 331)
            lic = texts.licence({"id": "Apache-2.0"}, canonical_text("Apache-2.0"))
        else:
            lic = texts.licence({"name": "HMSL-2.0"}, hmsl)
        kind = "library" if g.endswith((".so", ".jar")) else "firmware" if "firmware" in g else "data" if " " in g else "application"
        c = {
            "type": kind,
            "bom-ref": f"openccu-base/{g}@{version}",
            "name": g,
            "version": version,
            "supplier": {"name": "eQ-3 AG"},
            "licenses": [{"license": lic}],
            "properties": origin("OpenCCU-Base"),
        }
        if g.endswith(".jar"):
            info = os.path.join(d, f"{g}-JARLICENSEINFO.txt")
            libs = []
            if os.path.exists(info):
                libs = jar_libraries(info, errors)
            else:
                errors.append(("jar-info", g))
            for f in groups[g]:
                if os.path.basename(f) == g:
                    libs = merge_libraries(libs, jar_maven_libraries(os.path.join(b.root, "target", f)))
            if libs:
                c["components"] = libs
            else:
                # neither a list nor metadata: an SBOM that says the JAR bundles nothing (B-360)
                errors.append(("jar-empty", g))
        out.append(c)
    return out


def go_licence(b):
    """The Go toolchain's LICENSE: host-go keeps it in its build directory, not under host/."""
    for f in [os.path.join(b.root, "host", "lib", "go", "LICENSE")] + sorted(glob.glob(os.path.join(b.root, "build", "host-go*", "LICENSE"))):
        t = read(f)
        if t:
            return t
    return None


def npm_purl(name, version):
    """The purl of an npm package: a scoped name's scope is the namespace, its '@' percent-encoded
(purl spec: pkg:npm/%40scope/name@version), every segment and the version percent-encoded."""
    segs = [quote(seg, safe="") for seg in name.split("/")]
    return "pkg:npm/" + "/".join(segs) + (f"@{quote(version, safe='')}" if version else "")


def occulited(texts, b, errors):
    c = package(texts, b, "occulited")
    c["version"] = c["version"][:7]
    d = b.pkgdir("occulited")
    nested = []
    if d:
        for line in (read(os.path.join(d, "vendor", "modules.txt")) or "").splitlines():
            m = re.match(r"^# (\S+) (\S+)(?: => (\S+) (\S+))?$", line)
            if not m:
                continue
            path, ver = m.group(1), m.group(4) or m.group(2)
            mdir = os.path.join(d, "vendor", path)
            text = None
            if os.path.isdir(mdir):
                for fn in sorted(os.listdir(mdir)):
                    if re.match(r"^(licen[cs]e|copying)(\.(md|txt))?$", fn, re.I):
                        text = read(os.path.join(mdir, fn))
                        break
            if text is None:
                errors.append(("go-module-license", path))
            ident = detect(text or "")
            nested.append({
                "type": "library",
                "bom-ref": f"pkg:golang/{path}@{ver}",
                "name": path,
                "version": ver,
                "purl": f"pkg:golang/{path}@{ver}",
                "licenses": [{"license": texts.licence({"id": ident} if ident else {"name": "see text"}, text)}] if text else [],
                **({"copyright": copyright_of(text)} if copyright_of(text) else {}),
                **({"authors": [{"name": a} for p_, a in GO_AUTHORS.items() if path.startswith(p_)]} if any(path.startswith(p_) for p_ in GO_AUTHORS) else {}),
            })
        # what the binary links, by Go's own account, against the vendored list
        go = os.path.join(b.root, "host", "bin", "go")
        binary = os.path.join(b.root, "target", "usr", "bin", "occulited")
        if os.access(go, os.X_OK) and os.path.exists(binary):
            try:
                out = subprocess.run([go, "version", "-m", binary], capture_output=True, text=True, timeout=60).stdout
                have = {n["name"] for n in nested}
                for line in out.splitlines():
                    f = line.split()
                    if len(f) >= 3 and f[0] == "dep" and f[1] not in have:
                        errors.append(("go-module", f"{f[1]} {f[2]} is linked but not vendored"))
                gv = re.search(r"go(\d+\.\d+(?:\.\d+)?)", out.splitlines()[0] if out else "")
                if gv:
                    lic = texts.licence({"id": "BSD-3-Clause"}, go_licence(b))
                    nested.insert(0, {"type": "library", "bom-ref": f"pkg:golang/std@{gv.group(1)}", "name": "Go standard library and runtime",
                                      "version": gv.group(1), "purl": f"pkg:golang/std@{gv.group(1)}", "licenses": [{"license": lic}]})
            except (OSError, subprocess.TimeoutExpired) as e:
                errors.append(("go-version", str(e)))
        # the UI bundle's npm packages (occulited writes the list at its UI build)
        bl = read(os.path.join(d, "internal", "ui", "bundle-licenses.json"))
        if bl:
            for p in json.loads(bl).get("packages", []):
                n = {
                    "type": "library",
                    "bom-ref": npm_purl(p["name"], p["version"]),
                    "name": p["name"],
                    "version": p["version"],
                    "purl": npm_purl(p["name"], p["version"]),
                    "licenses": licences(texts, p.get("license") or "", p.get("text")),
                    "properties": [{"name": "openccu-lite:origin", "value": "occulited UI bundle"}],
                }
                if p.get("author"):
                    n["authors"] = [{"name": p["author"]}]
                if copyright_of(p.get("text")):
                    n["copyright"] = copyright_of(p.get("text"))
                if p.get("homepage"):
                    n["externalReferences"] = [{"type": "website", "url": p["homepage"]}]
                nested.append(n)
        else:
            errors.append(("ui-bundle", "occulited's internal/ui/bundle-licenses.json is missing"))
    if nested:
        c["components"] = nested
    return c


def linux_firmware(texts, b, errors):
    """One component per WHENCE entry with a file in the image (the Pis' brcm files are a package of
    their own, brcmfmac_sdio-firmware-rpi)."""
    d = b.pkgdir("linux-firmware")
    version = str(b.info.get("linux-firmware", {}).get("version") or "")
    whence = read(os.path.join(d, "WHENCE")) if d else None
    installed = set()
    for f in b.files.get("linux-firmware", []):
        for prefix in ("usr/lib/firmware/", "lib/firmware/"):
            if f.startswith(prefix):
                installed.add(re.sub(r"\.(zst|xz)$", "", f[len(prefix):]))
    if not whence:
        return [package(texts, b, "linux-firmware")]
    out, covered = [], set()
    for block in re.split(r"\n-{10,}\n", whence):
        driver = re.search(r"^Driver:\s*(\S+)", block, re.M)
        names = re.findall(r"^(?:File|RawFile|Link):\s*(\S+)", block, re.M)
        hit = sorted(n for n in names if n in installed)
        if not driver or not hit:
            continue
        lic = re.search(r"^Licen[cs]e:\s*(.+(?:\n(?![A-Z][A-Za-z ]*:)\S.*)*)", block, re.M)
        licline = re.sub(r"\s+", " ", lic.group(1)).strip() if lic else "Redistributable, see WHENCE"
        text = None
        ref = re.search(r"(LICEN[CS]E[\w.\-]*)", licline)
        if ref:
            text = read(os.path.join(d, "LICENSES", ref.group(1))) or read(os.path.join(d, ref.group(1)))
        name = driver.group(1)
        if any(c["name"] == f"linux-firmware: {name}" for c in out):
            name = f"{name} ({hit[0]})"
        covered.update(hit)
        out.append({"type": "firmware", "bom-ref": f"linux-firmware/{name}@{version}", "name": f"linux-firmware: {name}", "version": version,
                    "licenses": [{"license": texts.licence({"name": licline}, text)}],
                    "properties": origin("linux-firmware") + [{"name": "openccu-lite:files", "value": " ".join(hit)}]})
    for f in sorted(installed - covered):
        # a link WHENCE lists under its target's name, or a file of no entry
        errors.append(("linux-firmware", f))
    return out


# --- the document and the check -----------------------------------------------------------------

def walk(cs):
    for c in cs:
        yield c
        yield from walk(c.get("components", []))


def unlicensed(c):
    ls = c.get("licenses") or []
    if not ls:
        return True
    for l in ls:
        if "expression" in l:
            v = l["expression"]
        else:
            L = l.get("license", {})
            v = L.get("id") or L.get("name") or ""
            has_text = "text" in L or any(p.get("name") == "openccu-lite:text-ref" for p in L.get("properties", []))
            if v == "see text" and has_text:
                continue
        if not v.strip() or v.strip().lower() in ("unknown", "see text"):
            return True
    return False


def load_exceptions(path):
    out = {}
    if not path or not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, reason = line.partition(" # ")
            if not reason.strip():
                sys.exit(f"{path}: an exception without a reason: {line}")
            out[key.strip()] = reason.strip()
    return out


def nested_build(b, name, errors):
    """A buildroot build inside a package (multilib32, the recovery system): its own show-info,
    written into its output directory anew each time (`make show-info` there, a few seconds), so a
    changed inner configuration is never read from an old one."""
    d = b.pkgdir(name)
    out = os.path.join(d, "output") if d else None
    if not out or not os.path.isdir(out):
        return None
    si = os.path.join(out, "show-info.json")
    if True:
        env = {k: v for k, v in os.environ.items() if k not in ("MAKEFLAGS", "MAKELEVEL", "MFLAGS", "MAKEOVERRIDES")}
        # the inner configs name the outer tree (BR2_GLOBAL_PATCH_DIR); a build exports it, a run by
        # hand gets it from where this script lives
        env.setdefault("BR2_EXTERNAL_EQ3_PATH", os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "buildroot-external")))
        # what the package's .mk hands its inner build (package/recovery-system/recovery-system.mk):
        # the kernel of the OVA's recovery, the splash image, Base's version
        cfg = {}
        for line in (read(os.path.join(b.root, ".config")) or "").splitlines():
            k, eq, v = line.partition("=")
            if eq:
                cfg[k] = v.strip('"')
        args = []
        for inner, outer in (("BR2_EXTERNAL_LINUX_KERNEL_CUSTOM_VERSION_VALUE", "BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE"),
                             ("BR2_EXTERNAL_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION", "BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION"),
                             ("BR2_PACKAGE_PSPLASH_IMAGE", "BR2_PACKAGE_PSPLASH_IMAGE")):
            if cfg.get(outer):
                args.append(f"{inner}={cfg[outer]}")
        base = b.info.get("openccu-base", {}).get("version")
        if base:
            args.append(f"OPENCCU_BASE_VERSION={base}")
            # the release itself, for the recovery's hm-platform (recovery-system.mk; task 330):
            # openccu-base.mk's compat version, as the top Makefile reads it
            mk = read(os.path.join(env["BR2_EXTERNAL_EQ3_PATH"], "package", "openccu-base", "openccu-base.mk")) or ""
            m = re.search(r"^OPENCCU_BASE_COMPAT_VERSION = (\S+)", mk, re.M)
            args.append("OPENCCU_BASE_COMPAT_VERSION=" + (m.group(1) if m else str(base)))
        try:
            r = subprocess.run(["make", "-s", "-C", out, *args, "show-info"], capture_output=True, text=True, env=env, timeout=600)
            if r.returncode != 0 or not r.stdout.strip().startswith("{"):
                errors.append(("nested-show-info", f"{name}: {r.stderr.strip()[-200:]}"))
                return None
            with open(si, "w", encoding="utf-8") as f:
                f.write(r.stdout)
        except (OSError, subprocess.TimeoutExpired) as e:
            errors.append(("nested-show-info", f"{name}: {e}"))
            return None
    return Build(out)


def with_nested(texts, b, name, errors, shipped, known=None):
    """The package, with the packages of its inner build that ship nested under it. shipped says
    which: the inner packages owning the files the outer image has, or all with files. known maps
    a package name to the top-level component already made for it: an inner package that is
    itself a build inside a package (the recovery's own multilib32, whose 32-bit libraries the
    recovery ships) has no licence of its own and takes the top-level one's, same version only."""
    c = package(texts, b, name)
    nb = nested_build(b, name, errors)
    if not nb:
        return c
    inner = []
    for pkg in sorted(shipped(nb)):
        if pkg not in nb.info or nb.info[pkg].get("virtual"):
            continue
        n = package(texts, nb, pkg)
        k = (known or {}).get(pkg)
        if k and unlicensed(n) and not unlicensed(k) and n.get("version") == k.get("version"):
            n["licenses"] = copy.deepcopy(k["licenses"])
        n.pop("properties", None)
        n["bom-ref"] = f"{name}/{n['bom-ref']}"
        inner.append(n)
    if inner:
        c["components"] = inner
        if unlicensed(c):
            seen = []
            for n in inner:
                for l in n.get("licenses") or []:
                    v = l.get("expression") or l.get("license", {}).get("id") or l.get("license", {}).get("name")
                    if v and v not in seen:
                        seen.append(v)
            c["licenses"] = [{"license": {"name": "; ".join(seen)}}] if seen else []
    return c


def multilib32_shipped(outer):
    def pick(nb):
        want = {"lib/" + f[len("lib32/"):] for f in outer.files.get("multilib32", []) if f.startswith("lib32/")}
        return {pkg for pkg, files in nb.files.items() if want.intersection(files)}
    return pick


SPLIT = {"openccu-base", "occulited", "linux-firmware", "multilib32", "recovery-system"}


def main():
    ap = argparse.ArgumentParser(description="openccu-lite: the image's SBOM (CycloneDX 1.6)")
    ap.add_argument("--build-dir", required=True)
    ap.add_argument("--product", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--out", required=True, help="the file; .gz is gzip")
    ap.add_argument("--check", action="store_true", help="fail on a gap the exceptions file does not name")
    ap.add_argument("--kernel-files", help="also write the list of the kernel sources the product compiled")
    ap.add_argument("--exceptions", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "buildroot-external", "sbom-exceptions.txt"))
    a = ap.parse_args()

    b = Build(a.build_dir)
    texts = Texts()
    errors = []
    comps = []
    targets = sorted(n for n, i in b.info.items() if isinstance(i, dict) and i.get("type") == "target" and not i.get("virtual"))
    for name in targets:
        if name not in SPLIT:
            comps.append(package(texts, b, name))
    if "openccu-base" in b.info:
        comps.extend(openccu_base(texts, b, errors))
    if "occulited" in b.info:
        comps.append(occulited(texts, b, errors))
    if "linux-firmware" in b.info:
        comps.extend(linux_firmware(texts, b, errors))
    known = {}
    if "multilib32" in b.info:
        known["multilib32"] = with_nested(texts, b, "multilib32", errors, multilib32_shipped(b))
        comps.append(known["multilib32"])
    if "recovery-system" in b.info:
        # the recovery image is built whole from its inner build: every package with files there
        comps.append(with_nested(texts, b, "recovery-system", errors, lambda nb: {p for p, f in nb.files.items() if f}, known))

    # OpenCCU itself: the firmware build lite is a fork of - its overlay, scripts, patches and
    # packages (the ones of its own are listed above with it as their origin)
    kv = dict(l.split("=", 1) for l in (read(os.path.join(b.root, "target", "VERSION")) or "").splitlines() if "=" in l)
    comps.append({
        "type": "application",
        "bom-ref": f"openccu@{kv.get('VERSION', '')}",
        "name": "OpenCCU",
        "version": kv.get("VERSION", ""),
        "description": "the firmware build openccu-lite is a fork of: its overlay, scripts, patches and packages",
        "authors": [{"name": "Jens Maus"}],
        "licenses": [{"license": texts.licence({"id": "Apache-2.0"}, read(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "LICENSE")))}],
        "properties": origin("OpenCCU"),
    })

    # a licence named by its SPDX id but without a text of its own gets the project's own file
    # (Maven) or the standard text
    for c in walk(comps):
        for l in c.get("licenses") or []:
            lic = l.get("license")
            if not lic or not lic.get("id") or "text" in lic or any(p.get("name") == "openccu-lite:text-ref" for p in lic.get("properties", [])):
                continue
            t = maven_text(c.get("purl")) or canonical_text(lic["id"])
            if t:
                texts.licence(lic, t)

    root_ref = f"openccu-lite-{a.product}@{a.version}"
    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "serialNumber": f"urn:uuid:{uuid.uuid4()}",
        "version": 1,
        "metadata": {
            "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "tools": {"components": [{"type": "application", "name": "lite-sbom.py", "version": "2"}]},
            "component": {"type": "firmware", "bom-ref": root_ref, "name": "openccu-lite", "version": a.version,
                          "properties": [{"name": "openccu-lite:product", "value": a.product}]},
        },
        "components": comps,
        "dependencies": [{"ref": root_ref, "dependsOn": [c["bom-ref"] for c in comps]}],
    }
    vulns = vulnerabilities(b, [c for c in comps if c["name"] in b.info])
    if vulns:
        bom["vulnerabilities"] = vulns

    for c in walk(comps):
        if unlicensed(c):
            errors.append(("no-license", c["name"]))
    exc = load_exceptions(a.exceptions)
    keys = [(k, v, f"{k}:{v}") for k, v in errors]
    left = [(k, v) for k, v, key in keys if key not in exc and f"{k}:*" not in exc]
    used = {key for _, _, key in keys} | {f"{k}:*" for k, _, _ in keys}
    stale = [e for e in exc if e not in used]

    data = json.dumps(bom, indent=1, ensure_ascii=False).encode("utf-8") + b"\n"
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    if a.out.endswith(".gz"):
        with gzip.GzipFile(a.out, "wb", mtime=0) as f:
            f.write(data)
    else:
        with open(a.out, "wb") as f:
            f.write(data)
    if a.kernel_files:
        kf = kernel_files(b) if "linux" in b.info else None
        if kf:
            kv = next((c["version"] for c in comps if c["name"] == "linux"), "")
            os.makedirs(os.path.dirname(os.path.abspath(a.kernel_files)), exist_ok=True)
            with open(a.kernel_files, "w", encoding="utf-8") as f:
                f.write(f"# openccu-lite {a.product} {a.version}: the kernel sources this product compiled (linux {kv})\n")
                f.write("\n".join(kf) + "\n")
            print(f"lite-sbom: {len(kf)} kernel sources -> {a.kernel_files}", file=sys.stderr)
        else:
            # no kernel in this product, or its build directory is gone: no stale list either
            if os.path.exists(a.kernel_files):
                os.remove(a.kernel_files)
            if "linux" in b.info:
                print("lite-sbom: kernel-files: no object with a source in the kernel's build directory", file=sys.stderr)
                if a.check:
                    sys.exit(1)
    n = sum(1 for _ in walk(comps))
    size = os.path.getsize(a.out)
    print(f"lite-sbom: {n} components ({len(comps)} top level), {len(texts.refs)} licence texts, {len(data) // 1024} KiB, {size // 1024} KiB written -> {a.out}", file=sys.stderr)
    for e in stale:
        print(f"lite-sbom: the exception '{e}' matches nothing any more", file=sys.stderr)
    for k, v in left:
        print(f"lite-sbom: {k}: {v}", file=sys.stderr)
    if a.check and (left or stale):
        print(f"lite-sbom: {len(left)} gaps, {len(stale)} stale exceptions - close them, or name them in {a.exceptions} with a reason", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
