#!/usr/bin/env python3
"""
Maintainer release tool: turns a finished in-game scan into a shippable GearGuide release.

    python release.py --wow "E:/World of Warcraft/_forever_"            # normal release
    python release.py --wow "..." --dry-run                              # only show what changed

Steps:
  1. Read the scan (+ learned sources + corrections.json) from the SavedVariables file.
  2. Compare it with the database currently shipped in GearGuide/Data.lua. Added, removed or
     changed items are the "confirmed item changes" of a patch. With none (and no --sources),
     nothing is released.
  3. Write the new Data.lua, bump the TOC version, add a CHANGELOG.md entry.
  4. Zip the addon to releases/GearGuide-<version>.zip with GearGuide/ at the zip root, so
     extracting into Interface/AddOns gives the right folder layout.
Pushing the version tag makes GitHub Actions upload the zip to CurseForge (see README).
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from build_db import HEADER, LuaTableParser, collect, default_questie, excluded, find_saved_variables  # noqa: E402
from update_db import CORRECTIONS, write_lua  # noqa: E402
import package  # noqa: E402

ROOT = Path(os.environ.get("GEARGUIDE_ROOT", HERE.parent))  # override for tests
ADDON = ROOT / "GearGuide"
DATA = ADDON / "Data.lua"
TOC = ADDON / "GearGuide.toc"
CHANGELOG = ROOT / "CHANGELOG.md"
COMPARE_FIELDS = ("n", "q", "il", "rl", "eq", "c", "sc", "st", "cls", "u")
SHOW_NAMES = 15  # items listed by name per category in the changelog


def read_shipped(path: Path) -> tuple[dict[int, dict], dict]:
    """Parses a Data.lua written by write_lua back into items (sources resolved) and meta."""
    if not path.exists():
        return {}, {}
    text = path.read_text(encoding="utf-8")
    meta = {}
    m = re.search(r"meta = ", text)
    if m:
        meta = LuaTableParser(text[m.end():]).value()
    tables: dict[str, dict[int, object]] = {"S": {}, "I": {}, "L": {}}
    for line in text.splitlines():
        lm = re.match(r"^([SIL])\[(\d+)\]=(.*)$", line)
        if not lm:
            continue
        tables[lm.group(1)][int(lm.group(2))] = LuaTableParser(lm.group(3)).value()
    pool, items, locs = tables["S"], tables["I"], tables["L"]
    for rec in items.values():  # indices -> sources, location index -> location (format 3)
        if isinstance(rec.get("src"), list):
            resolved = []
            for s in rec["src"]:
                s = pool.get(s, s) if isinstance(s, int) else s
                if isinstance(s, dict) and isinstance(s.get("l"), int):
                    s = {**{k: v for k, v in s.items() if k != "l"}, "loc": locs.get(s["l"])}
                resolved.append(s)
            rec["src"] = resolved
    return items, meta if isinstance(meta, dict) else {}


def norm(v):
    """Comparable form: lists/dicts -> sorted tuples, floats rounded."""
    if isinstance(v, dict):
        return tuple(sorted((k, norm(x)) for k, x in v.items()))
    if isinstance(v, list):
        return tuple(sorted(norm(x) for x in v))
    if isinstance(v, float):
        return round(v, 2)
    return v


def diff(old: dict[int, dict], new: dict[int, dict]):
    added = sorted(set(new) - set(old))
    removed = sorted(set(old) - set(new))
    changed = []
    for iid in sorted(set(old) & set(new)):
        fields = [f for f in COMPARE_FIELDS if norm(old[iid].get(f)) != norm(new[iid].get(f))]
        if fields:
            changed.append((iid, fields))
    new_sources = sum(
        len({norm(s) for s in new[i].get("src") or []} - {norm(s) for s in old.get(i, {}).get("src") or []})
        for i in new)
    # items whose source list changed in either direction (added, fixed or removed sources)
    sources_changed = [i for i in sorted(set(old) & set(new))
                       if {norm(s) for s in old[i].get("src") or []} != {norm(s) for s in new[i].get("src") or []}]
    return added, removed, changed, new_sources, sources_changed


def bump(version: str, part: str) -> str:
    major, minor, patch = (int(x) for x in (version.split(".") + ["0", "0"])[:3])
    if part == "major":
        return f"{major + 1}.0.0"
    if part == "minor":
        return f"{major}.{minor + 1}.0"
    if part == "patch":
        return f"{major}.{minor}.{patch + 1}"
    return version


def names(ids, items, limit=SHOW_NAMES) -> str:
    shown = ", ".join(f"{items[i].get('n', '?')} ({i})" for i in ids[:limit])
    return shown + (f", and {len(ids) - limit} more" if len(ids) > limit else "")


def main() -> int:
    p = argparse.ArgumentParser(description="Build, diff, version and package a GearGuide release.")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--wow", type=Path, help='game folder, e.g. "E:/World of Warcraft/_forever_"')
    src.add_argument("--saved", type=Path, help="path to SavedVariables/GearGuide.lua")
    p.add_argument("--bump", choices=["patch", "minor", "major", "none"], default="patch")
    p.add_argument("--corrections", type=Path, default=CORRECTIONS)
    p.add_argument("--questie", type=Path, help="QuestieDB folder for item sources (default: the one in --wow)")
    p.add_argument("--no-questie", action="store_true")
    p.add_argument("--keep-poor", action="store_true", help="keep gray (poor quality) items")
    p.add_argument("--sources", action="store_true", help="release even if only new sources were learned")
    p.add_argument("--force", action="store_true", help="release even if the scan is unfinished or nothing changed")
    p.add_argument("--dry-run", action="store_true", help="show the comparison, change nothing")
    args = p.parse_args()

    saved = args.saved or find_saved_variables(args.wow)
    print(f"Reading scan from {saved}")
    questie = None if args.no_questie else (args.questie or default_questie(args.wow))
    items, meta, scan = collect(saved, args.corrections, questie=questie, keep_poor=args.keep_poor)
    old, old_meta = read_shipped(DATA)
    if meta.get("scanned", 0) == 0 and old:
        # Local scan cleared (/gg scan reset): use the shipped items as the base so Questie-only and
        # source-only releases still work. Item fields can only change through a new scan.
        print("No local scan: using the items in the shipped Data.lua as the base.")
        from update_db import apply_corrections
        # The shipped items still pass through the build's exclusion rules, so a tightened filter
        # (e.g. new test-item name patterns) applies without a fresh scan.
        base = {iid: {k: v for k, v in rec.items() if k != "src"} for iid, rec in old.items()
                if not excluded(rec, args.keep_poor)}
        for iid, rec in items.items():  # learned items/sources from the saved variables
            if iid in base:
                if rec.get("src"):
                    base[iid]["src"] = list(rec["src"])
            else:
                base[iid] = rec
        if questie:
            from import_questie import merge_sources, questie_version
            merge_sources(base, questie)
            meta["questie"] = questie_version(questie)
            meta["credits"] = "Item sources include data from the Questie project's database (GPL-3.0)"
        apply_corrections(base, args.corrections)
        items = base
        meta["build"] = old_meta.get("build", meta.get("build"))
        meta["count"] = len(items)
        scan = {"phase": "done"}
    if scan.get("phase") != "done" and not args.force:
        print(f"The scan isn't finished (phase: {scan.get('phase') or 'not started'}). Let /gg scan complete, "
              "then /reload or log out so WoW saves it. (--force overrides.)", file=sys.stderr)
        return 1
    if not items:
        print("No items in the scan.", file=sys.stderr)
        return 1

    added, removed, changed, new_sources, sources_changed = diff(old, items)
    questie_before, questie_now = old_meta.get("questie"), meta.get("questie")
    questie_updated = bool(questie_now) and questie_before != questie_now
    print(f"Shipped database: {len(old)} items (client build {old_meta.get('build', '?')})")
    print(f"New scan:         {len(items)} items (client build {meta['build']})")
    print(f"  added {len(added)}, removed {len(removed)}, changed {len(changed)}, new sources {new_sources}, "
          f"items with changed sources {len(sources_changed)}")
    if questie_updated:
        print(f"  QuestieDB updated: {questie_before or 'none'} -> {questie_now}")
    for iid, fields in changed[:SHOW_NAMES]:
        print(f"    changed: {items[iid].get('n')} ({iid}): {', '.join(fields)}")

    item_changes = bool(added or removed or changed)
    questie_release = questie_updated and bool(sources_changed or new_sources)
    if not item_changes and not questie_release and not (args.sources and new_sources) and not args.force:
        print("No confirmed item changes and no QuestieDB source changes: nothing to release. "
              "(--sources releases newly learned sources.)")
        return 0
    if args.dry_run:
        print("Dry run: nothing written.")
        return 0

    toc = TOC.read_text(encoding="utf-8")
    current = re.search(r"^## Version: (\S+)", toc, re.M).group(1)
    version = bump(current, args.bump)
    TOC.write_text(re.sub(r"^## Version: \S+", f"## Version: {version}", toc, flags=re.M), encoding="utf-8")

    meta["version"] = version
    write_lua(DATA, items, meta, header=HEADER)

    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    lines = [f"## {version} ({today})", ""]
    if not old:
        lines.append(f"Initial item database from client build {meta['build']}: {len(items)} gear items, "
                     f"{sum(1 for r in items.values() if r.get('src'))} with known sources.")
        if questie_now:
            lines.append(f"- Item sources include QuestieDB {questie_now}")
    else:
        lines.append(f"Item database rebuilt from client build {meta['build']}: {len(items)} gear items."
                     if item_changes else f"Item sources refreshed ({len(items)} gear items, client build {meta['build']}).")
        if added:
            lines.append(f"- Added {len(added)}: {names(added, items)}")
        if removed:
            lines.append(f"- Removed {len(removed)}: {names(removed, old)}")
        if changed:
            lines.append(f"- Changed {len(changed)}: {names([i for i, _ in changed], items)}")
        if questie_updated and (sources_changed or new_sources):
            lines.append(f"- Item sources updated from QuestieDB {questie_now} ({len(sources_changed)} items changed)")
        if new_sources:
            lines.append(f"- {new_sources} new item sources")
    entry = "\n".join(lines) + "\n\n"
    previous = CHANGELOG.read_text(encoding="utf-8") if CHANGELOG.exists() else "# Changelog\n\n"
    head, _, rest = previous.partition("\n\n")
    CHANGELOG.write_text(head + "\n\n" + entry + rest, encoding="utf-8")

    zip_path = package.make_zip(version)
    print(f"\nReleased {version}: {zip_path} ({zip_path.stat().st_size // 1024} KB)")
    print("Changelog entry:\n" + entry)
    print("Publish it (GitHub Actions uploads to CurseForge when the tag arrives):")
    print(f'  git add -A && git commit -m "Release {version}" && git tag v{version} && git push && git push origin v{version}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
