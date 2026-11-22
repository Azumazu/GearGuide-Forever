#!/usr/bin/env python3
"""
World drops (BoE gear any creature of the right level can drop) from the cmangos classic-db world
database (GPL-3.0, https://github.com/cmangos/classic-db), used at build time only.

    python world_drops.py --wow "E:/World of Warcraft/_forever_"     # writes GearGuide/WorldDrops.lua

In cmangos, world drops live in shared reference loot tables ("level 53-58 greens and blues"):
a creature's loot rolls each table it links with its own chance, and a table yields one of its
items, each equally likely. A world drop has hundreds of creatures, too many to list per item in
Data.lua (Questie's lists stop at 25), so WorldDrops.lua keeps that structure instead:

    GearGuide_WorldDrops.refs[ref]  = { share%, item, item, ... }   (x = { [item] = % } overrides)
    GearGuide_WorldDrops.npc[name]  = { min level, max level, ref, chance%, ref, chance%, ..., z = { area IDs } }
    GearGuide_WorldDrops.items[id]  = { creatures, min level, max level, best chance%, usual chance% }

An item's chance from a creature is chance% * share% / 100 for each table the creature links that
holds it. Only BoE gear GearGuide ships, and only tables linked by more than WORLD_MIN_CREATURES
creatures that exist in WoW: Forever (QuestieDB knows them), count as world drops.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

ROOT = HERE.parent
DATA = ROOT / "GearGuide" / "Data.lua"
OUT = ROOT / "GearGuide" / "WorldDrops.lua"
CMANGOS_DUMP = HERE / ".cache" / "ClassicDB.sql.gz"
CREDITS = "World drops are from the cmangos classic-db project (GPL-3.0)"

WORLD_MIN_CREATURES = 10  # a reference table linked by more creatures than this is a world-drop table
BIND_ON_EQUIP = 2         # item_template.bonding


def shipped_items(path: Path = DATA) -> set[int]:
    return {int(m.group(1)) for m in re.finditer(r"^I\[(\d+)\]=", path.read_text(encoding="utf-8"), re.M)}


def build(dump: Path, items: set[int], questie: Path | None = None) -> dict:
    """{"refs": {ref: (share%, [items], {item: %})}, "npc": {name: [min, max, [(ref, %)], [area IDs]]},
    "items": {item: (creatures, min, max, best%, median%)}}"""
    from import_cmangos import _Loot, read_tables
    t = read_tables(dump, {"creature_template", "creature_loot_template", "reference_loot_template", "item_template"})
    boe = {r["entry"] for r in t["item_template"] if r.get("bonding") == BIND_ON_EQUIP and r["entry"] in items}
    loot = _Loot({k: t[k] for k in ("creature_loot_template", "reference_loot_template")})
    rows_by_loot: dict[int, list[dict]] = {}
    for r in t["creature_loot_template"]:
        rows_by_loot.setdefault(r["entry"], []).append(r)

    forever, zones_of = None, {}
    if questie:
        from import_questie import QuestieStore, find_toc, NPC_SPAWNS, NPC_ZONE
        store = QuestieStore(find_toc(questie))
        forever = {nid: store.name("Npc", nid) for nid in store.ids("Npc")}

        def zones_of_npc(nid: int) -> set[int]:
            """The zones (area IDs) a creature spawns in, for the mini tracker's "in this zone" list."""
            spawns = store.field("Npc", nid, NPC_SPAWNS)
            out = {int(k) for k in spawns} if isinstance(spawns, dict) else set()
            z = store.field("Npc", nid, NPC_ZONE)
            if not out and isinstance(z, int) and z > 0:
                out.add(z)
            return out

    # (creature name, level range) -> {ref: chance% of rolling that table per kill}
    links: dict[str, dict] = {}
    users: dict[int, set[str]] = {}
    for c in t["creature_template"]:
        cid, lid = c.get("Entry"), c.get("LootId")
        if not lid or not c.get("Name"):
            continue
        name = c["Name"]
        if forever is not None:
            if not forever.get(cid):
                continue  # not in WoW: Forever
            name = forever[cid]
        groups: dict[int, list[dict]] = {}
        picked: dict[int, float] = {}
        for r in rows_by_loot.get(lid, []):
            if r.get("groupid"):
                groups.setdefault(r["groupid"], []).append(r)
            elif (r.get("mincountOrRef") or 0) < 0:
                times = max(1, r.get("maxcount") or 1)
                p = min(100.0, abs(r.get("ChanceOrQuestChance") or 0)) / 100
                ref = -r["mincountOrRef"]
                picked[ref] = 1 - (1 - picked.get(ref, 0)) * (1 - p) ** times
        for members in groups.values():  # a grouped table link: the group's own share rule
            used = sum(abs(r.get("ChanceOrQuestChance") or 0) for r in members)
            equal = [r for r in members if not r.get("ChanceOrQuestChance")]
            for r in members:
                if (r.get("mincountOrRef") or 0) < 0:
                    pct = abs(r.get("ChanceOrQuestChance") or 0) or max(0.0, 100 - used) / max(1, len(equal))
                    ref = -r["mincountOrRef"]
                    picked[ref] = 1 - (1 - picked.get(ref, 0)) * (1 - min(100.0, pct) / 100)
        if not picked:
            continue
        e = links.setdefault(name, {"min": c.get("MinLevel") or 0, "max": c.get("MaxLevel") or 0, "refs": {}, "z": set()})
        if forever is not None:
            e["z"] |= zones_of_npc(cid)
        e["min"] = min(e["min"], c.get("MinLevel") or e["min"])
        e["max"] = max(e["max"], c.get("MaxLevel") or e["max"])
        for ref, p in picked.items():
            e["refs"][ref] = max(e["refs"].get(ref, 0), p * 100)
            users.setdefault(ref, set()).add(name)

    refs = {}
    for ref, who in users.items():
        if len(who) <= WORLD_MIN_CREATURES:
            continue
        q = loot.chances("reference_loot_template", ref)  # {item: 0-1}, one roll of the table
        mine = {iid: p * 100 for iid, p in q.items() if iid in boe}
        if not mine:
            continue
        share = max(set(round(v, 4) for v in mine.values()), key=list(round(v, 4) for v in mine.values()).count)
        refs[ref] = (share, sorted(mine), {i: round(v, 4) for i, v in mine.items() if round(v, 4) != share})

    npc, summary = {}, {}
    for name, e in links.items():
        mine = [(ref, round(p, 4)) for ref, p in sorted(e["refs"].items()) if ref in refs]
        if not mine:
            continue
        npc[name] = [e["min"], e["max"], mine, sorted(e["z"])]
        best: dict[int, float] = {}
        for ref, p in mine:
            share, ids, over = refs[ref]
            for iid in ids:
                pct = p * over.get(iid, share) / 100
                best[iid] = 1 - (1 - best.get(iid, 0)) * (1 - pct / 100)  # several tables: either one
        for iid, b in best.items():
            s = summary.setdefault(iid, [0, e["min"], e["max"], []])
            s[0] += 1
            s[1], s[2] = min(s[1], e["min"]), max(s[2], e["max"])
            s[3].append(b * 100)
    out = {}
    for iid, (n, lo, hi, pcts) in summary.items():
        pcts.sort()
        out[iid] = (n, lo, hi, pcts[-1], pcts[len(pcts) // 2])
    return {"refs": refs, "npc": npc, "items": out}


def _num(v: float) -> str:
    s = f"{v:.4f}".rstrip("0").rstrip(".")
    return s or "0"


def _lua_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_lua(world: dict, path: Path = OUT) -> None:
    lines = [
        "-- GearGuide world drops. GENERATED by GearGuideTools/world_drops.py from the cmangos classic-db",
        "-- project's loot tables (GPL-3.0). Do not edit by hand. Format: see world_drops.py.",
        "GearGuide_WorldDrops = { refs = {}, npc = {}, items = {} }",
        "local R, N, W = GearGuide_WorldDrops.refs, GearGuide_WorldDrops.npc, GearGuide_WorldDrops.items",
    ]
    for ref in sorted(world["refs"]):
        share, ids, over = world["refs"][ref]
        x = (",x={" + ",".join(f"[{i}]={_num(v)}" for i, v in sorted(over.items())) + "}") if over else ""
        lines.append(f"R[{ref}]={{{_num(share)},{','.join(map(str, ids))}{x}}}")
    for name in sorted(world["npc"]):
        lo, hi, mine, zones = world["npc"][name]
        pairs = ",".join(f"{ref},{_num(p)}" for ref, p in mine)
        z = (",z={" + ",".join(map(str, zones)) + "}") if zones else ""
        lines.append(f"N[{_lua_str(name)}]={{{lo},{hi},{pairs}{z}}}")
    for iid in sorted(world["items"]):
        n, lo, hi, best, usual = world["items"][iid]
        lines.append(f"W[{iid}]={{{n},{lo},{hi},{_num(best)},{_num(usual)}}}")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")


def main() -> int:
    p = argparse.ArgumentParser(description="Write GearGuide/WorldDrops.lua from a cmangos classic-db dump.")
    p.add_argument("--cmangos", type=Path, default=CMANGOS_DUMP, help="cmangos classic-db dump (.sql or .sql.gz)")
    p.add_argument("--wow", type=Path, help="game folder (its QuestieDB limits creatures to WoW: Forever's)")
    p.add_argument("--questie", type=Path, help="QuestieDB folder (instead of --wow)")
    args = p.parse_args()
    questie = args.questie
    if not questie and args.wow:
        from build_db import default_questie
        questie = default_questie(args.wow)
    world = build(args.cmangos, shipped_items(), questie)
    write_lua(world)
    print(f"{OUT}: {len(world['items'])} items, {len(world['npc'])} creatures, {len(world['refs'])} loot tables, "
          f"{OUT.stat().st_size // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
