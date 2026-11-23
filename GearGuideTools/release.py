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
CMANGOS_DUMP = HERE / ".cache" / "ClassicDB.sql.gz"  # not committed (see .gitignore)
TOC = ADDON / "GearGuide.toc"
CHANGELOG = ROOT / "CHANGELOG.md"
COMPARE_FIELDS = ("n", "q", "il", "rl", "eq", "c", "sc", "st", "cls", "u", "vp")  # vp: vendor prices
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
    from update_db import unpack_loc
    pool, items, locs = tables["S"], tables["I"], {i: unpack_loc(l) for i, l in tables["L"].items()}
    for rec in items.values():  # indices -> sources, location index -> location (format 3)
        if isinstance(rec.get("src"), list):
            resolved = []
            for s in rec["src"]:
                s = pool.get(s, s) if isinstance(s, int) else s
                if isinstance(s, dict) and isinstance(s.get("l"), int):
                    s = {**{k: v for k, v in s.items() if k != "l"}, "loc": locs.get(s["l"])}
                resolved.append(s)
            dc = rec.pop("dc", None)  # item.dc[i] is the drop chance of item.src[i]
            if isinstance(dc, list):
                for s, c in zip(resolved, dc):
                    if isinstance(s, dict) and c:
                        s["dc"] = c
            rec["src"] = resolved
    return items, meta if isinstance(meta, dict) else {}


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)


def read_randoms(path: Path) -> dict[int, list]:
    """The random variant groups (R[group]={suffix, chance, ...}) of a Data.lua written by write_lua."""
    if not path.exists():
        return {}
    out = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"^R\[(\d+)\]=(.*)$", line)
        if m:
            from update_db import unpack_numbers
            out[int(m.group(1))] = unpack_numbers(LuaTableParser(m.group(2)).value())  # packed "id,chance,..."
    return out


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
    def names(i, side):
        return {(s.get("t"), s.get("n")) for s in side.get(i, {}).get("src") or [] if isinstance(s, dict)}
    new_sources = sum(len(names(i, new) - names(i, old)) for i in new)
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
    p.add_argument("--cmangos", type=Path, default=CMANGOS_DUMP if CMANGOS_DUMP.exists() else None,
                   help="cmangos classic-db dump (.sql or .sql.gz) for vendor gold prices and drop chances "
                        "(default: GearGuideTools/.cache/ClassicDB.sql.gz when present)")
    p.add_argument("--no-cmangos", action="store_true", help="don't use the cmangos dump (drop chances, raid loot, prices)")
    p.add_argument("--keep-poor", action="store_true", help="keep gray (poor quality) items")
    p.add_argument("--sources", action="store_true", help="release even if only new sources were learned")
    p.add_argument("--force", action="store_true", help="release even if the scan is unfinished or nothing changed")
    p.add_argument("--dry-run", action="store_true", help="show the comparison, change nothing")
    args = p.parse_args()
    if args.no_cmangos:
        args.cmangos = None

    saved = args.saved or find_saved_variables(args.wow)
    print(f"Reading scan from {saved}")
    questie = None if args.no_questie else (args.questie or default_questie(args.wow))
    chances = None
    if args.cmangos and questie:
        from import_cmangos import drop_chances
        chances = drop_chances(args.cmangos)
        chances["dump"] = args.cmangos  # for raid loot the scan missed (cmangos_items.py)
        print(f"cmangos drop chances: {sum(len(v) for v in chances['npc'].values())} creature drops")
    items, meta, scan = collect(saved, args.corrections, questie=questie, keep_poor=args.keep_poor, chances=chances)
    old, old_meta = read_shipped(DATA)
    if meta.get("scanned", 0) == 0 and old:
        # Local scan cleared (/gg scan reset): use the shipped items as the base so Questie-only and
        # source-only releases still work. Item fields can only change through a new scan.
        print("No local scan: using the items in the shipped Data.lua as the base.")
        from update_db import apply_corrections, hide_by_source
        # The shipped items still pass through the build's exclusion rules, so a tightened filter
        # (e.g. new test-item name patterns) applies without a fresh scan.
        base = {iid: {k: v for k, v in rec.items() if k != "src"} for iid, rec in old.items()
                if not excluded(rec, args.keep_poor)}
        for iid, rec in items.items():  # learned items/sources from the saved variables
            if iid in base and base[iid].get("pv") and rec.get("st"):
                # A provisional raid item the client has now returned: its real record replaces it.
                base[iid] = {k: v for k, v in rec.items() if k != "src"}
            if iid in base:
                if rec.get("src"):
                    base[iid]["src"] = list(rec["src"])
                if rec.get("vp"):
                    base[iid]["vp"] = {**base[iid].get("vp", {}), **rec["vp"]}  # newly seen prices win
            else:
                base[iid] = rec
        if questie:
            from import_questie import merge_sources, questie_version
            merge_sources(base, questie, chances)
            meta["questie"] = questie_version(questie)
            meta["credits"] = "Item sources include data from the Questie project's database (GPL-3.0)"
        apply_corrections(base, args.corrections)
        if questie:
            from import_questie import resolve_npc_sources
            resolve_npc_sources(base, questie)
        # Items hidden earlier are already gone from the shipped base, so keep the shipped list too:
        # it is what hides them again when a player's own scan still has them.
        hidden = sorted(set(hide_by_source(base, args.corrections)) | set(old_meta.get("hidden") or []))
        if hidden:
            print(f"Hidden by source (_hide_sources): {len(hidden)} items")
            meta["hidden"] = hidden
        items = base
        meta["build"] = old_meta.get("build", meta.get("build"))
        meta["count"] = len(items)
        scan = {"phase": "done"}
    # Drop chances: from the cmangos dump when given, else kept from the shipped Data.lua.
    if chances:
        from import_cmangos import DROP_CREDITS
        meta["credits"] = "; ".join(c for c in (meta.get("credits"), DROP_CREDITS) if c)
    else:
        for iid, rec in items.items():
            old_dc = {(s.get("t"), s.get("n")): s["dc"] for s in (old.get(iid) or {}).get("src") or []
                      if isinstance(s, dict) and s.get("dc")}
            for s in rec.get("src") or []:
                if isinstance(s, dict) and not s.get("dc") and (s.get("t"), s.get("n")) in old_dc:
                    s["dc"] = old_dc[(s.get("t"), s.get("n"))]
    # Vendor prices only come from players visiting vendors: keep every shipped price a fresh
    # scan doesn't carry (prices seen since then win).
    for iid, rec in items.items():
        old_vp = (old.get(iid) or {}).get("vp")
        if isinstance(old_vp, dict) and old_vp:
            rec["vp"] = {**old_vp, **(rec.get("vp") or {})}
    # Default vendor gold prices (item.bp): from a cmangos classic-db dump when given, else kept from
    # the shipped Data.lua for items that still have a vendor source.
    if args.cmangos:
        from import_cmangos import CREDITS as CM_CREDITS, merge_prices, vendor_data
        priced = merge_prices(items, *vendor_data(args.cmangos))
        print(f"cmangos vendor prices: {priced} items")
        from import_cmangos import merge_reputation, reputation_data
        print(f"cmangos reputation requirements: {merge_reputation(items, reputation_data(args.cmangos))} items")
        meta["credits"] = "; ".join(c for c in (meta.get("credits"), CM_CREDITS) if c)
    else:
        for iid, rec in items.items():
            old_rec = old.get(iid) or {}
            if old_rec.get("rp"):
                rec["rp"] = old_rec["rp"]
            if old_rec.get("bp") and any(isinstance(s, dict) and s.get("t") == "vendor" for s in rec.get("src") or []):
                rec["bp"] = old_rec["bp"]
            if old_rec.get("hr"):
                rec["hr"] = old_rec["hr"]
        if any(r.get("bp") for r in items.values()):
            from import_cmangos import CREDITS as CM_CREDITS
            meta["credits"] = "; ".join(c for c in (meta.get("credits"), CM_CREDITS) if c)
    # Random variants ("Cross Dagger of the Falcon"): suffix groups from the cmangos dump, else kept
    # from the shipped Data.lua.
    if args.cmangos:
        from import_cmangos import merge_variants, random_variants
        randoms = merge_variants(items, *random_variants(args.cmangos))
        print(f"cmangos random variants: {sum(1 for r in items.values() if r.get('rg'))} items, {len(randoms)} groups")
    else:
        randoms = read_randoms(DATA)
        for iid, rec in items.items():
            g = (old.get(iid) or {}).get("rg")
            if g in randoms:
                rec["rg"] = g
    # Reputation requirements read from vendor tooltips in game (WoW: Forever's own factions, which
    # the cmangos data doesn't have): only for items without one.
    from build_db import learned_reps
    rep_added = 0
    for iid, rp in learned_reps(saved).items():
        if iid in items and not items[iid].get("rp"):
            items[iid]["rp"] = rp
            rep_added += 1
    if rep_added:
        print(f"Reputation requirements learned in game: {rep_added} items")
    # Where creatures and vendors without a known location were found in game (GearGuideLearned.spots).
    from build_db import apply_spots, learned_spots
    placed = apply_spots(items, *learned_spots(saved))
    if placed:
        print(f"Creature locations learned in game: {placed} sources placed")
    if scan.get("phase") != "done" and not args.force:
        print(f"The scan isn't finished (phase: {scan.get('phase') or 'not started'}). Let /gg scan complete, "
              "then /reload or log out so WoW saves it. (--force overrides.)", file=sys.stderr)
        return 1
    if not items:
        print("No items in the scan.", file=sys.stderr)
        return 1

    added, removed, changed, new_sources, sources_changed = diff(old, items)
    new_prices = sum(1 for i, r in items.items()  # gold price, PvP rank or reputation needed
                     if (r.get("bp"), r.get("hr"), r.get("rp"))
                     != ((old.get(i) or {}).get("bp"), (old.get(i) or {}).get("hr"), (old.get(i) or {}).get("rp")))
    questie_before, questie_now = old_meta.get("questie"), meta.get("questie")
    questie_updated = bool(questie_now) and questie_before != questie_now
    print(f"Shipped database: {len(old)} items (client build {old_meta.get('build', '?')})")
    print(f"New scan:         {len(items)} items (client build {meta['build']})")
    print(f"  added {len(added)}, removed {len(removed)}, changed {len(changed)}, new sources {new_sources}, "
          f"items with changed sources {len(sources_changed)}, new/changed vendor prices {new_prices}")
    if questie_updated:
        print(f"  QuestieDB updated: {questie_before or 'none'} -> {questie_now}")
    for iid, fields in changed[:SHOW_NAMES]:
        print(f"    changed: {items[iid].get('n')} ({iid}): {', '.join(fields)}")

    # Random variants: items that gained/lost a group, or whose group's suffixes or chances changed.
    old_randoms = read_randoms(DATA)
    variant_items = sorted(iid for iid, rec in items.items()
                           if norm(rec.get("rg") and randoms.get(rec["rg"]))
                           != norm((old.get(iid) or {}).get("rg") and old_randoms.get(old[iid]["rg"])))
    if variant_items:
        print(f"  random variants changed for {len(variant_items)} items")
    item_changes = bool(added or removed or changed)
    questie_release = questie_updated and bool(sources_changed or new_sources)
    if not item_changes and not questie_release and not new_prices and not variant_items and not (args.sources and new_sources) and not args.force:
        print("No confirmed item changes and no QuestieDB source changes: nothing to release. "
              "(--sources releases newly learned sources.)")
        return 0
    if args.dry_run:
        print("Dry run: nothing written.")
        return 0

    toc = TOC.read_text(encoding="utf-8")
    current = re.search(r"^## Version: (\S+)", toc, re.M).group(1)
    version = bump(current, args.bump)

    meta["version"] = version
    write_lua(DATA, items, meta, header=HEADER, randoms=randoms)
    if args.cmangos:  # BoE world drops and their creatures (else the shipped WorldDrops.lua stays)
        import world_drops
        world = world_drops.build(args.cmangos, set(items), questie)
        world_drops.write_lua(world, ADDON / "WorldDrops.lua")
        print(f"World drops: {len(world['items'])} items from {len(world['npc'])} creatures")
    if version == current:
        # --bump none: the released version's changelog and zip stay as they are.
        print(f"\nData.lua rebuilt (version {version} unchanged): no changelog entry or zip written.")
        return 0

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
        if variant_items:
            lines.append(f"- Random variants (\"...of the Falcon\" etc.) with their chances for {len(variant_items)} items")
        if new_prices:
            lines.append(f"- Vendor prices for {new_prices} items (cmangos classic-db; prices seen in game take priority)")
    entry = "\n".join(lines) + "\n\n"
    previous = CHANGELOG.read_text(encoding="utf-8") if CHANGELOG.exists() else "# Changelog\n\n"
    head, _, rest = previous.partition("\n\n")
    write_atomic(CHANGELOG, head + "\n\n" + entry + rest)
    # The version goes into the TOC last, so a failed run doesn't bump it again on the next try.
    write_atomic(TOC, re.sub(r"^## Version: \S+", f"## Version: {version}", toc, flags=re.M))

    zip_path = package.make_zip(version)
    print(f"\nReleased {version}: {zip_path} ({zip_path.stat().st_size // 1024} KB)")
    print("Changelog entry:\n" + entry)
    print("Publish it (GitHub Actions uploads to CurseForge when the tag arrives):")
    print(f'  git add -A && git commit -m "Release {version}" && git tag v{version} && git push && git push origin v{version}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
