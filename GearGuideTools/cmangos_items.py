#!/usr/bin/env python3
"""
Raid loot GearGuide's client scan missed, from the cmangos classic-db world database (GPL-3.0,
https://github.com/cmangos/classic-db). Build time only.

The scan drops items the server didn't answer in time; that hit a lot of endgame gear. These items
are added as provisional records (pv = 1) with only what cmangos can be trusted for: name, quality,
levels, slot, class restriction. WoW: Forever changed many item stats, so cmangos' stats are not
used. In game, GearGuide asks the client for every provisional item and keeps it hidden until the
client returns its own record (real stats); items the client doesn't know never show.

Only loot that drops exclusively in raids or from world bosses is added, and only with those
raid creatures and chests as sources, so raid gear can't end up listed under a leveling zone mob.
"""
from __future__ import annotations

from pathlib import Path

from import_cmangos import read_tables

INVTYPE = {1: "INVTYPE_HEAD", 2: "INVTYPE_NECK", 3: "INVTYPE_SHOULDER", 5: "INVTYPE_CHEST",
           6: "INVTYPE_WAIST", 7: "INVTYPE_LEGS", 8: "INVTYPE_FEET", 9: "INVTYPE_WRIST", 10: "INVTYPE_HAND",
           11: "INVTYPE_FINGER", 12: "INVTYPE_TRINKET", 13: "INVTYPE_WEAPON", 14: "INVTYPE_SHIELD",
           15: "INVTYPE_RANGED", 16: "INVTYPE_CLOAK", 17: "INVTYPE_2HWEAPON", 20: "INVTYPE_ROBE",
           21: "INVTYPE_WEAPONMAINHAND", 22: "INVTYPE_WEAPONOFFHAND", 23: "INVTYPE_HOLDABLE",
           25: "INVTYPE_THROWN", 26: "INVTYPE_RANGEDRIGHT", 28: "INVTYPE_RELIC"}
CLASS_BITS = {1: "WARRIOR", 2: "PALADIN", 4: "HUNTER", 8: "ROGUE", 16: "PRIEST", 64: "SHAMAN",
              128: "MAGE", 256: "WARLOCK", 1024: "DRUID"}
ALL_CLASSES = sum(CLASS_BITS)

# Raid instances (area IDs as Questie uses them for creature zones)
RAID_AREAS = {2717: "Molten Core", 2159: "Onyxia's Lair", 2677: "Blackwing Lair", 1977: "Zul'Gurub",
              3429: "Ruins of Ahn'Qiraj", 3428: "Temple of Ahn'Qiraj", 3456: "Naxxramas"}
# Raid instance maps (creature/gameobject spawn map) -> area ID
RAID_MAPS = {409: 2717, 249: 2159, 469: 2677, 309: 1977, 509: 3429, 531: 3428, 533: 3456}
CONTINENTS = {0, 1}     # Eastern Kingdoms, Kalimdor: where world bosses live
BOSS_RANK = 3
WORLD_BOSS_MIN_LEVEL = 60
MIN_QUALITY = 3          # rare and better
MIN_CHANCE = 0.1         # % (sources below this aren't listed)
MAX_SOURCES = 10


def spawn_maps(path: Path) -> dict[str, dict[int, set[int]]]:
    """{"npc": {creature id: {map, ...}}, "object": {gameobject id: {map, ...}}} from the spawn tables."""
    t = read_tables(path, {"creature", "gameobject"})
    out: dict[str, dict[int, set[int]]] = {"npc": {}, "object": {}}
    for kind, table in (("npc", "creature"), ("object", "gameobject")):
        for r in t[table]:
            out[kind].setdefault(r["id"], set()).add(r["map"])
    return out


def item_shells(path: Path, ids: set[int]) -> dict[int, dict]:
    """Provisional records (no stats) for equippable items among `ids`."""
    t = read_tables(path, {"item_template"})
    out = {}
    for r in t["item_template"]:
        iid = r.get("entry")
        eq = INVTYPE.get(r.get("InventoryType") or 0)
        if iid not in ids or not eq:
            continue
        rec = {"n": r.get("name"), "q": r.get("Quality"), "il": r.get("ItemLevel"),
               "rl": r.get("RequiredLevel") or 0, "eq": eq, "c": r.get("class"), "sc": r.get("subclass"), "pv": 1}
        mask = r.get("AllowableClass") or -1
        if mask > 0 and mask & ALL_CLASSES != ALL_CLASSES:
            rec["cls"] = [name for bit, name in CLASS_BITS.items() if mask & bit]
        if r.get("maxcount") == 1:
            rec["u"] = 1
        out[iid] = rec
    return out
