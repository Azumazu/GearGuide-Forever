#!/usr/bin/env python3
"""
Packages the GearGuide addon folder into a release zip (GearGuide/ at the zip root), and reads
the version and its changelog entry. Used by release.py locally and by the GitHub release workflow.

    python package.py                 # zip the current version into releases/
    python package.py --print-version
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("GEARGUIDE_ROOT", HERE.parent))
ADDON = ROOT / "GearGuide"
TOC = ADDON / "GearGuide.toc"
CHANGELOG = ROOT / "CHANGELOG.md"
RELEASES = ROOT / "releases"
SKIP_SUFFIXES = (".tmp", ".bak")


def toc_field(name: str) -> str:
    m = re.search(rf"^## {re.escape(name)}: *(.+?) *$", TOC.read_text(encoding="utf-8"), re.M)
    if not m:
        raise SystemExit(f"{TOC} has no '## {name}:' line")
    return m.group(1)


def version() -> str:
    return toc_field("Version")


def interface_versions() -> list[str]:
    """TOC Interface numbers as game versions: 16001 -> '1.60.1', 11507 -> '1.15.7'."""
    out = []
    for raw in toc_field("Interface").split(","):
        n = int(raw.strip())
        out.append(f"{n // 10000}.{(n // 100) % 100}.{n % 100}")
    return out


def changelog_entry(ver: str) -> str:
    """The CHANGELOG.md section for `ver` (without its heading), or a fallback line."""
    if CHANGELOG.exists():
        text = CHANGELOG.read_text(encoding="utf-8")
        m = re.search(rf"^## {re.escape(ver)}\b.*?\n(.*?)(?=^## |\Z)", text, re.S | re.M)
        if m and m.group(1).strip():
            return m.group(1).strip()
    return f"GearGuide {ver}"


def make_zip(ver: str | None = None) -> Path:
    ver = ver or version()
    RELEASES.mkdir(exist_ok=True)
    path = RELEASES / f"GearGuide-{ver}.zip"
    tmp = path.with_suffix(".zip.tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(ADDON.rglob("*")):
            if f.is_file() and not f.name.endswith(SKIP_SUFFIXES):
                z.write(f, Path("GearGuide") / f.relative_to(ADDON))
    tmp.replace(path)
    return path


def main() -> int:
    p = argparse.ArgumentParser(description="Package GearGuide into a release zip.")
    p.add_argument("--print-version", action="store_true")
    args = p.parse_args()
    if args.print_version:
        print(version())
        return 0
    path = make_zip()
    print(f"{path} ({path.stat().st_size // 1024} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
