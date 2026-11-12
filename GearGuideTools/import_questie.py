#!/usr/bin/env python3
"""
Imports item sources (who drops it, which chest/container holds it, who sells it, which quest
rewards it) from Questie's Forever database (QuestieDB, GPL-3.0) for GearGuide's items.
Build-time only: GearGuide never calls Questie in game, and players don't need Questie installed.

Credits: the source data comes from the Questie project (https://github.com/Questie/Questie),
GPL-3.0; QuestieDB data by Muehe, TheCrux (BreakBB), Drejjmit, Dyaxler, Cheeq, TechnoHunter,
Yttrium and contributors. GearGuide is GPL-3.0 as well.

QuestieDB "baked" format: the TOC file holds custom metadata lines
  ## X-<Type>-IDS: zlib+CBOR id list         ## X-<Type>-<id>-S: CBOR row of scalar fields
  ## X-<Type>-<id>-<field>: CBOR table field  values are base64; "~N~" = split into key-1..key-N
Zones are stored as area IDs; the addon turns them into (localized) names in game.

    python import_questie.py --wow "E:/World of Warcraft/_forever_" --report    # stats only
Used by build_db.py / release.py through --questie.
"""
from __future__ import annotations

import argparse
import base64
import re
import struct
import sys
import zlib
from pathlib import Path

# Field indices from QuestieDB src/meta/*Meta.lua
ITEM_NAME, ITEM_NPC_DROPS, ITEM_OBJECT_DROPS, ITEM_ITEM_DROPS, ITEM_QUEST_REWARDS, ITEM_VENDORS = 1, 2, 3, 4, 6, 14
NPC_NAME, NPC_ZONE = 1, 9
OBJECT_NAME, OBJECT_ZONE = 1, 5
QUEST_NAME, QUEST_ZONE_OR_SORT = 1, 17

MAX_SOURCES_PER_KIND = 8


# ----------------------------------------------------------------------------- CBOR (RFC 8949)
class CBOR:
    def __init__(self, data: bytes):
        self.d, self.i = data, 0

    def _arg(self, info: int) -> int | None:
        if info < 24:
            return info
        size = {24: 1, 25: 2, 26: 4, 27: 8}.get(info)
        if size is None:
            return None  # 31 = indefinite length
        v = int.from_bytes(self.d[self.i:self.i + size], "big")
        self.i += size
        return v

    def item(self):
        b = self.d[self.i]
        self.i += 1
        major, info = b >> 5, b & 0x1F
        if major == 0:
            return self._arg(info)
        if major == 1:
            return -1 - self._arg(info)
        if major in (2, 3):
            n = self._arg(info)
            if n is None:  # indefinite: concatenated chunks
                out = b""
                while self.d[self.i] != 0xFF:
                    chunk = self.item()
                    out += chunk.encode() if isinstance(chunk, str) else chunk
                self.i += 1
                return out.decode("utf-8", "replace") if major == 3 else out
            raw = self.d[self.i:self.i + n]
            self.i += n
            return raw.decode("utf-8", "replace") if major == 3 else raw
        if major == 4:
            n = self._arg(info)
            if n is None:
                out = []
                while self.d[self.i] != 0xFF:
                    out.append(self.item())
                self.i += 1
                return out
            return [self.item() for _ in range(n)]
        if major == 5:
            n = self._arg(info)
            out = {}
            if n is None:
                while self.d[self.i] != 0xFF:
                    k = self.item()
                    out[k] = self.item()
                self.i += 1
                return out
            for _ in range(n):
                k = self.item()
                out[k] = self.item()
            return out
        if major == 6:
            self._arg(info)
            return self.item()  # ignore tags
        if info == 20:
            return False
        if info == 21:
            return True
        if info in (22, 23):
            return None
        if info == 25:
            v = struct.unpack(">e", self.d[self.i:self.i + 2])[0]; self.i += 2; return v
        if info == 26:
            v = struct.unpack(">f", self.d[self.i:self.i + 4])[0]; self.i += 4; return v
        if info == 27:
            v = struct.unpack(">d", self.d[self.i:self.i + 8])[0]; self.i += 8; return v
        raise ValueError(f"unsupported CBOR simple value {info}")


def cbor(data: bytes):
    return CBOR(data).item()


def text(v) -> str:
    if isinstance(v, bytes):
        return v.decode("utf-8", "replace")
    return v if isinstance(v, str) else ""


def id_list(v) -> list[int]:
    if isinstance(v, dict):
        v = [v[k] for k in sorted(v)]
    return [x for x in (v or []) if isinstance(x, int)]


# ----------------------------------------------------------------------------- baked store
class QuestieStore:
    def __init__(self, toc: Path):
        self.dir = toc.parent
        self.meta: dict[str, str] = {}
        with toc.open(encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("## X-"):
                    key, _, value = line[3:].rstrip("\r\n").partition(": ")
                    self.meta[key] = value
        self._rows: dict[tuple[str, int], dict] = {}

    def _stored(self, key: str) -> str | None:
        v = self.meta.get(key)
        if v and v.startswith("~") and v.endswith("~") and v[1:-1].isdigit():
            v = "".join(self.meta.get(f"{key}-{i}", "") for i in range(1, int(v[1:-1]) + 1))
        return v

    def ids(self, kind: str) -> list[int]:
        raw = self._stored(f"X-{kind}-IDS")
        return id_list(cbor(zlib.decompress(base64.b64decode(raw)))) if raw else []

    def row(self, kind: str, eid: int) -> dict:
        key = (kind, eid)
        if key not in self._rows:
            raw = self._stored(f"X-{kind}-{eid}-S")
            row = cbor(base64.b64decode(raw)) if raw else {}
            if isinstance(row, list):  # dense rows are stored as arrays: position i+1 = field i+1
                row = {i + 1: v for i, v in enumerate(row) if v is not None}
            self._rows[key] = row if isinstance(row, dict) else {}
        return self._rows[key]

    def field(self, kind: str, eid: int, index: int):
        row = self.row(kind, eid)
        if index in row:
            return row[index]
        raw = self._stored(f"X-{kind}-{eid}-{index}")
        return cbor(base64.b64decode(raw)) if raw else None

    def name(self, kind: str, eid: int) -> str:
        return text(self.row(kind, eid).get(1))


def questie_version(path: Path) -> str:
    """QuestieDB release version plus build stamp, e.g. '1.0.12 (2026-11-02, a1b2c3d)'."""
    fields = {}
    with find_toc(path).open(encoding="utf-8", errors="replace") as f:
        for line in f:
            if not line.startswith("## "):
                if fields.get("Version") and not line.strip():
                    continue
                if not line.startswith("#"):
                    break  # metadata header ends where the file list starts
                continue
            key, _, value = line[3:].strip().partition(": ")
            if key in ("Version", "X-BUILD-TIME", "X-BUILD-COMMIT"):
                fields[key] = value
    stamp = ", ".join(v for v in (fields.get("X-BUILD-TIME", "")[:10], fields.get("X-BUILD-COMMIT", "")[:7]) if v)
    return fields.get("Version", "?") + (f" ({stamp})" if stamp else "")


def find_toc(path: Path) -> Path:
    """Accepts the game folder, the AddOns folder, the QuestieDB folder, or the TOC itself."""
    if path.is_file():
        return path
    for candidate in (path / "QuestieDB_Forever.toc",
                      path / "QuestieDB" / "QuestieDB_Forever.toc",
                      path / "Interface" / "AddOns" / "QuestieDB" / "QuestieDB_Forever.toc"):
        if candidate.exists():
            return candidate
    raise SystemExit(f"QuestieDB_Forever.toc not found under {path}")


# ----------------------------------------------------------------------------- zones and map locations
NPC_SPAWNS, OBJECT_SPAWNS, QUEST_STARTED_BY = 7, 4, 2
MAX_POINTS = 20          # spawn points kept per map
MAX_LOC_MAPS = 3         # maps kept per location (most spawns first)
MAX_DROP_NPCS = 25       # creatures listed per item before "... and N more"
MAX_CHEST_KINDS = 6


def _lua_blocks(path: Path) -> dict[str, dict]:
    """ZoneDB.private.<name> = [[return { ... }]] blocks -> {name: table}."""
    from build_db import LuaTableParser  # local import: build_db imports this module too
    text = path.read_text(encoding="utf-8", errors="replace")
    out = {}
    for name, body in re.findall(r"ZoneDB\.private\.(\w+)\s*=\s*\[\[(.*?)\]\]", text, re.S):
        body = body.strip()
        if body.startswith("return"):
            body = body[len("return"):]
        value = LuaTableParser(body).value()
        out[name] = value if isinstance(value, dict) else {i + 1: v for i, v in enumerate(value or [])}
    return out


class ZoneData:
    """Area IDs -> world map IDs, sub-zone parents and dungeon entrances (QuestieDB Forever support files)."""

    ENTRY = re.compile(r'^\s*\[(\d+)\]\s*=\s*\{"([^"]*)",\s*(nil|\{[^}]*\}),\s*(\d+),\s*\{(.*)\}\s*\},')
    ENTRANCE = re.compile(r"\{\s*(\d+)\s*,\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\}")

    def __init__(self, questiedb_dir: Path):
        zones = questiedb_dir / "support" / "Forever" / "Zones"
        self.area_to_map, self.parent, self.dungeons = {}, {}, {}
        needed = [zones / n for n in ("areaIdToUiMapId.lua", "subZoneToParentZone.lua", "dungeons.lua")]
        missing = [p.name for p in needed if not p.exists()]
        if missing:
            print(f"  QuestieDB zone files missing ({', '.join(missing)}): sources imported without map locations")
            return
        maps = _lua_blocks(zones / "areaIdToUiMapId.lua")
        self.area_to_map = {**maps.get("areaIdToUiMapId", {}), **maps.get("areaIdToUiMapIdOverride", {})}
        parents = _lua_blocks(zones / "subZoneToParentZone.lua")
        self.parent = {**parents.get("subZoneToParentZone", {}), **parents.get("subZoneToParentZoneOverride", {})}
        alias: dict[int, int] = {}
        in_base = False
        for line in (zones / "dungeons.lua").read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("local dungeons = {"):
                in_base = True
                continue
            if in_base and line.startswith("}"):
                break  # only the base table applies to Forever (later blocks are for newer expansions)
            m = self.ENTRY.match(line) if in_base else None
            if not m:
                continue  # faction-dependent entries (battlegrounds) and comments are skipped
            area, name, alts, parent, rest = int(m.group(1)), m.group(2), m.group(3), int(m.group(4)), m.group(5)
            entrances = [(int(a), float(x), float(y)) for a, x, y in self.ENTRANCE.findall(rest)]
            self.dungeons[area] = {"name": name, "parent": parent, "entrances": entrances}
            if alts != "nil":
                for alt in re.findall(r"\d+", alts):
                    alias[int(alt)] = area
        for alt, area in alias.items():
            self.dungeons.setdefault(alt, self.dungeons[area])

    def map_for(self, area) -> int | None:
        for a in (area, self.parent.get(area)):
            m = self.area_to_map.get(a) if a is not None else None
            if m:
                return int(m)
        return None


def _sample(points: list, limit: int) -> list:
    if len(points) <= limit:
        return points
    step = len(points) / limit
    return [points[int(i * step)] for i in range(limit)]


def location(zones: ZoneData, spawns) -> list[dict] | None:
    """Spawn table {area: [[x, y, phase?], ...]} -> [{m: uiMapID, p: [x1, y1, ...], e: dungeonArea?}, ...]."""
    if isinstance(spawns, list):
        spawns = {i + 1: v for i, v in enumerate(spawns)}
    if not isinstance(spawns, dict):
        return None
    by_map: dict[tuple, list] = {}
    for area, pts in spawns.items():
        if not isinstance(area, int) or not isinstance(pts, list):
            continue
        coords = [p for p in pts if isinstance(p, list) and len(p) >= 2]
        if any(p[0] == -1 and p[1] == -1 for p in coords):
            dungeon = zones.dungeons.get(area)
            for e_area, x, y in (dungeon or {}).get("entrances", []):
                m = zones.map_for(e_area)
                if m:
                    by_map.setdefault((m, area), []).append((round(x, 1), round(y, 1)))
            continue
        m = zones.map_for(area)
        if not m:
            continue
        for p in coords:
            if 0 <= p[0] <= 100 and 0 <= p[1] <= 100:
                by_map.setdefault((m, None), []).append((round(p[0], 1), round(p[1], 1)))
    if not by_map:
        return None
    best = sorted(by_map.items(), key=lambda kv: -len(kv[1]))[:MAX_LOC_MAPS]
    out = []
    for (m, dungeon_area), pts in best:
        flat = [c for xy in _sample(sorted(set(pts)), MAX_POINTS) for c in xy]
        entry = {"m": m, "p": flat}
        if dungeon_area:
            entry["e"] = dungeon_area  # these points are the dungeon's entrance(s)
        out.append(entry)
    return out


def merge_locations(locs: list) -> list | None:
    """Combines several locations (e.g. every 'Solid Chest' object) into one, same limits."""
    by_map: dict[tuple, list] = {}
    for loc in locs:
        for entry in loc or []:
            pts = list(zip(entry["p"][0::2], entry["p"][1::2]))
            by_map.setdefault((entry["m"], entry.get("e")), []).extend(pts)
    if not by_map:
        return None
    out = []
    for (m, e), pts in sorted(by_map.items(), key=lambda kv: -len(kv[1]))[:MAX_LOC_MAPS]:
        entry = {"m": m, "p": [c for xy in _sample(sorted(set(pts)), MAX_POINTS) for c in xy]}
        if e:
            entry["e"] = e
        out.append(entry)
    return out


# ----------------------------------------------------------------------------- factions
NPC_FRIENDLY_TO, QUEST_REQUIRED_RACES = 13, 6
# Race bits (QuestieDB raceMaskById): classic races plus Forever's Skyborne (bits 32/33).
ALLIANCE_RACES = 1 + 4 + 8 + 64 + (1 << 32)      # Human, Dwarf, Night Elf, Gnome, Skyborne (Alliance)
HORDE_RACES = 2 + 16 + 32 + 128 + (1 << 33)       # Orc, Undead, Tauren, Troll, Skyborne (Horde)


def npc_faction(store, nid) -> str | None:
    """'A' or 'H' for NPCs friendly to only one faction (e.g. city vendors); None if both/neither."""
    v = text(store.field("Npc", nid, NPC_FRIENDLY_TO))
    return v if v in ("A", "H") else None


def quest_faction(store, qid) -> str | None:
    races = store.field("Quest", qid, QUEST_REQUIRED_RACES)
    if not isinstance(races, int) or races == 0:
        return None
    alliance, horde = bool(races & ALLIANCE_RACES), bool(races & HORDE_RACES)
    return "A" if alliance and not horde else "H" if horde and not alliance else None


# ----------------------------------------------------------------------------- sources
def _npc_source(store, zones, kind, nid):
    name = store.name("Npc", nid)
    if not name:
        return None
    return {"t": kind, "n": name, "z": store.field("Npc", nid, NPC_ZONE) or None,
            "loc": location(zones, store.field("Npc", nid, NPC_SPAWNS)),
            "f": npc_faction(store, nid) if kind == "vendor" else None}


def _quest_giver_location(store, zones, qid):
    started = store.field("Quest", qid, QUEST_STARTED_BY)
    if isinstance(started, list):
        started = {i + 1: v for i, v in enumerate(started)}
    if not isinstance(started, dict):
        return None
    for nid in id_list(started.get(1)):
        loc = location(zones, store.field("Npc", nid, NPC_SPAWNS))
        if loc:
            return loc
    for oid in id_list(started.get(2)):
        loc = location(zones, store.field("Object", oid, OBJECT_SPAWNS))
        if loc:
            return loc
    return None


def item_sources(store: QuestieStore, iid: int, zones: ZoneData | None = None) -> list[dict]:
    if not store.row("Item", iid):
        return []
    zones = zones or ZoneData(store.dir)
    out: list[dict] = []

    npcs = id_list(store.field("Item", iid, ITEM_NPC_DROPS))
    for nid in npcs[:MAX_DROP_NPCS]:
        src = _npc_source(store, zones, "drop", nid)
        if src:
            out.append(src)
    if len(npcs) > MAX_DROP_NPCS:
        out.append({"t": "drop", "n": f"... and {len(npcs) - MAX_DROP_NPCS} more creatures"})

    chests: dict[str, list] = {}
    for oid in id_list(store.field("Item", iid, ITEM_OBJECT_DROPS)):
        name = store.name("Object", oid)
        if name:
            chests.setdefault(name, []).append(location(zones, store.field("Object", oid, OBJECT_SPAWNS)))
    for name, locs in sorted(chests.items(), key=lambda kv: -len(kv[1]))[:MAX_CHEST_KINDS]:
        out.append({"t": "drop", "n": name, "loc": merge_locations(locs), "k": "object"})

    for cid in id_list(store.field("Item", iid, ITEM_ITEM_DROPS))[:MAX_SOURCES_PER_KIND]:
        name = store.name("Item", cid)
        if name:
            out.append({"t": "drop", "n": f"Inside {name}"})

    for vid in id_list(store.field("Item", iid, ITEM_VENDORS))[:MAX_SOURCES_PER_KIND]:
        src = _npc_source(store, zones, "vendor", vid)
        if src:
            out.append(src)

    for qid in id_list(store.field("Item", iid, ITEM_QUEST_REWARDS))[:MAX_SOURCES_PER_KIND]:
        name = store.name("Quest", qid)
        if name:
            zone = store.field("Quest", qid, QUEST_ZONE_OR_SORT)
            out.append({"t": "quest", "n": name, "z": zone if isinstance(zone, int) and zone > 0 else None,
                        "loc": _quest_giver_location(store, zones, qid), "f": quest_faction(store, qid)})

    unique = {}
    for src in out:
        src = {k: v for k, v in src.items() if v is not None}
        unique.setdefault((src.get("t"), src.get("n"), src.get("z")), src)
    return list(unique.values())


# ----------------------------------------------------------------------------- inferred sources
# For items that still have no source: conservative, clearly labelled inferences.
ITEM_CLASS, ITEM_SUBCLASS = 12, 13
RECIPE_NAME = re.compile(r"^(Plans|Pattern|Formula|Schematic|Recipe|Design|Manual|Technique): (.+)$")
PROFESSION_BY_RECIPE_SUBCLASS = {1: "Leatherworking", 2: "Tailoring", 3: "Engineering", 4: "Blacksmithing",
                                 5: "Cooking", 6: "Alchemy", 7: "First Aid", 8: "Enchanting", 9: "Fishing"}
PROFESSION_BY_PREFIX = {"Plans": "Blacksmithing", "Formula": "Enchanting", "Schematic": "Engineering",
                        "Recipe": "Alchemy", "Manual": "First Aid"}
PVP_RANK = re.compile(r"^(Private's|Scout's|Corporal's|Grunt's|Sergeant's|Master Sergeant's|Sergeant Major's|"
                      r"Stone Guard's|First Sergeant's|Knight's|Blood Guard's|Knight-Lieutenant's|Legionnaire's|"
                      r"Knight-Captain's|Centurion's|Knight-Champion's|Champion's|Lieutenant Commander's|"
                      r"Lieutenant General's|Commander's|General's|Marshal's|Warlord's|Field Marshal's|"
                      r"Grand Marshal's|High Warlord's)\s")
ALLIANCE_RANKS = {"Private's", "Corporal's", "Master Sergeant's", "Sergeant Major's", "Knight's",
                  "Knight-Lieutenant's", "Knight-Captain's", "Knight-Champion's", "Lieutenant Commander's",
                  "Commander's", "Marshal's", "Field Marshal's", "Grand Marshal's"}
HORDE_RANKS = {"Scout's", "Grunt's", "First Sergeant's", "Stone Guard's", "Blood Guard's", "Legionnaire's",
               "Centurion's", "Champion's", "Lieutenant General's", "General's", "Warlord's", "High Warlord's"}
STARTER = re.compile(r"^(Recruit's|Apprentice's|Neophyte's|Acolyte's|Squire's|Footpad's|Initiate's|Novice's|"
                     r"Trapper's|Rugged Trapper's|Primitive|Tribal|Ancestral|Thug|Worn|Bent|Battleworn|Hunting|Tarnished)\b")
FOREVER_ID_START = 260000


def _recipe_index(store: QuestieStore) -> dict[str, tuple[int, str, str]]:
    """Crafted item name -> (recipe item ID, recipe name, profession)."""
    index = {}
    for rid in store.ids("Item"):
        name = store.name("Item", rid)
        m = RECIPE_NAME.match(name or "")
        if not m:
            continue
        row = store.row("Item", rid)
        prof = None
        if row.get(ITEM_CLASS) == 9:
            prof = PROFESSION_BY_RECIPE_SUBCLASS.get(row.get(ITEM_SUBCLASS))
        prof = prof or PROFESSION_BY_PREFIX.get(m.group(1)) or "Profession"
        index.setdefault(m.group(2), (rid, name, prof))
    return index


def infer_sources(items: dict[int, dict], store: QuestieStore, zones: ZoneData) -> dict[str, int]:
    """Adds inferred sources ("k": "guess" when it's an estimate) to items that have none. Returns counts."""
    recipes = _recipe_index(store)
    counts: dict[str, int] = {}

    def add(rec, src, kind):
        rec["src"] = [src]
        counts[kind] = counts.get(kind, 0) + 1

    for iid, rec in items.items():
        if rec.get("src"):
            continue
        name, quality, ilvl = rec.get("n") or "", rec.get("q") or 1, rec.get("il") or 0
        if name in recipes:
            rid, recipe_name, prof = recipes[name]
            # Where to get the recipe: first source with a map location, preferring ones both factions
            # can use. The crafted item itself stays faction-neutral (it can be traded).
            located = [s for s in item_sources(store, rid, zones) if s.get("loc")]
            recipe_src = next((s for s in located if not s.get("f")), located[0] if located else None)
            src = {"t": "craft", "n": f"{prof} ({recipe_name})"}
            if recipe_src:
                src["z"] = recipe_src.get("z")
                src["loc"] = recipe_src["loc"]
            add(rec, {k: v for k, v in src.items() if v is not None}, "crafted")
        elif PVP_RANK.match(name):
            rank = PVP_RANK.match(name).group(1)
            faction = "A" if rank in ALLIANCE_RANKS else "H" if rank in HORDE_RANKS else None
            add(rec, {k: v for k, v in {"t": "pvp", "n": "PvP rank reward", "f": faction}.items() if v}, "pvp")
        elif STARTER.match(name) and (rec.get("rl") or 0) <= 1 and quality <= 1:
            add(rec, {"t": "start", "n": "Starting equipment"}, "starting gear")
        elif rec.get("r") and ilvl > 0:
            # Only items with random enchantments ("of the Bear"): those really are world drops.
            # Plain greens without a source are often trainer-crafted, so they stay unknown.
            low, high = max(1, ilvl - 4), ilvl + 1
            add(rec, {"t": "world", "n": f"creatures around level {low}-{high}", "k": "guess"}, "likely world drop")
    return counts


def merge_sources(items: dict[int, dict], questie_path: Path) -> tuple[int, int]:
    """Adds Questie sources to GearGuide items in place. Returns (items with new sources, sources added)."""
    store = QuestieStore(find_toc(questie_path))
    zones = ZoneData(store.dir)
    touched = added = 0
    for iid, rec in items.items():
        new = item_sources(store, iid, zones)
        if not new:
            continue
        have = rec.setdefault("src", [])
        seen = {(s.get("t"), s.get("n")) for s in have}
        fresh = [s for s in new if (s.get("t"), s.get("n")) not in seen]
        if fresh:
            have.extend(fresh)
            touched += 1
            added += len(fresh)
    inferred = infer_sources(items, store, zones)
    if inferred:
        print("Inferred sources for items without one: "
              + ", ".join(f"{n} {k}" for k, n in sorted(inferred.items(), key=lambda kv: -kv[1])))
    return touched, added


def main() -> int:
    p = argparse.ArgumentParser(description="Report what Questie's Forever database knows about item sources.")
    p.add_argument("--wow", type=Path, required=True, help='game folder, AddOns folder or QuestieDB folder')
    p.add_argument("--item", type=int, action="append", help="show sources for these item IDs")
    args = p.parse_args()
    store = QuestieStore(find_toc(args.wow))
    ids = store.ids("Item")
    print(f"QuestieDB {questie_version(args.wow)}")
    print(f"QuestieDB Forever: {len(ids)} items, {len(store.ids('Npc'))} NPCs, {len(store.ids('Quest'))} quests")
    for iid in args.item or []:
        print(f"{iid} {store.name('Item', iid)!r}:")
        for s in item_sources(store, iid):
            print("   ", s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
