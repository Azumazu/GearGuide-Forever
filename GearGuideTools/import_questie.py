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
import math
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
NPC_WAYPOINTS, NPC_RANK = 8, 6
RARE_RANKS = {2, 4}      # rare elite, rare
MIN_ROUTE_LENGTH = 2.0   # map units (0-100); shorter "routes" are an NPC pacing inside its shop
ROUTE_STEP = 0.4         # points closer than this to the previous kept point are dropped
MAX_ROUTE_POINTS = 80    # per path, after thinning
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


AREA_LINK = 7.0       # spawns closer than this (map units, 0-100) belong to the same area
AREA_MIN_SPAWNS = 3   # fewer spawns than this: plain pins, no area
AREA_PAD = 2.0        # area edge distance around the outermost spawns
MAX_AREAS = 8         # areas kept per map (most spawns first)


def _hull(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Convex hull (monotone chain), counter-clockwise, no repeated end point."""
    pts = sorted(set(points))
    if len(pts) < 3:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


MAX_AREA_SPAN = 25.0  # an area wider or taller than this (map units) is split or left as pins
MIN_AREA_LINK = 3.0   # tightest grouping tried when splitting


def _groups(pts: list[tuple[float, float]], link: float) -> list[list[tuple[float, float]]]:
    """Single-linkage grouping: points closer than `link` (directly or through others) group together."""
    import math
    groups, seen = [], set()
    for start in pts:
        if start in seen:
            continue
        seen.add(start)
        group, todo = [], [start]
        while todo:
            p = todo.pop()
            group.append(p)
            for q in pts:
                if q not in seen and math.dist(p, q) <= link:
                    seen.add(q)
                    todo.append(q)
        groups.append(group)
    return groups


def _span(group: list[tuple[float, float]]) -> float:
    xs, ys = [p[0] for p in group], [p[1] for p in group]
    return max(max(xs) - min(xs), max(ys) - min(ys))


def _compact_groups(pts, link):
    """Groups no wider than MAX_AREA_SPAN: a group that is too wide (spawns scattered along a long
    chain, e.g. chests all over a zone) is regrouped more tightly; if even the tightest grouping
    leaves it too wide, it gets no area and its spawns stay pins."""
    out = []
    for group in _groups(pts, link):
        if _span(group) <= MAX_AREA_SPAN:
            out.append(group)
        elif link * 0.6 >= MIN_AREA_LINK:
            out.extend(_compact_groups(group, link * 0.6))
    return out


def areas(points: list[tuple[float, float]]) -> list[list[float]]:
    """Groups nearby spawn points and outlines each group: [[x1, y1, x2, y2, ...], ...], biggest
    group first. Each outline is the convex hull of the spawns padded by AREA_PAD (a rounded shape),
    so the map can shade where a creature or chest is found instead of pinning every spawn."""
    import math
    groups = [g for g in _compact_groups(sorted(set(points)), AREA_LINK) if len(g) >= AREA_MIN_SPAWNS]
    out = []
    for group in sorted(groups, key=len, reverse=True)[:MAX_AREAS]:
        ring = [(x + AREA_PAD * math.cos(a * math.pi / 4), y + AREA_PAD * math.sin(a * math.pi / 4))
                for x, y in group for a in range(8)]
        hull = [(min(100.0, max(0.0, round(x, 1))), min(100.0, max(0.0, round(y, 1)))) for x, y in _hull(ring)]
        out.append([c for xy in hull for c in xy])
    return out


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
        else:
            a = areas(pts)  # from every spawn, not just the sampled pins
            if a:
                entry["a"] = a
        out.append(entry)
    return out


def _as_list(v):
    return list(v.values()) if isinstance(v, dict) else v if isinstance(v, list) else []


def routes(zones: ZoneData, waypoints) -> dict[int, list[list[float]]]:
    """Questie waypoints {area: [[[x, y], ...], ...]} -> {uiMapID: [[x1, y1, x2, y2, ...], ...]} for
    paths long enough to be worth drawing, thinned to a few dozen points each."""
    if isinstance(waypoints, list):
        waypoints = {i + 1: v for i, v in enumerate(waypoints)}
    if not isinstance(waypoints, dict):
        return {}
    out: dict[int, list] = {}
    for area, paths in waypoints.items():
        m = zones.map_for(area) if isinstance(area, int) else None
        if not m:
            continue
        for path in _as_list(paths):
            pts = []
            for p in _as_list(path):
                xy = _as_list(p)
                if len(xy) >= 2 and all(isinstance(c, (int, float)) and 0 <= c <= 100 for c in xy[:2]):
                    pts.append((float(xy[0]), float(xy[1])))
            if len(pts) < 2 or sum(math.dist(pts[i], pts[i + 1]) for i in range(len(pts) - 1)) < MIN_ROUTE_LENGTH:
                continue
            kept = [pts[0]]
            for pt in pts[1:]:
                if math.dist(pt, kept[-1]) >= ROUTE_STEP:
                    kept.append(pt)
            if kept[-1] != pts[-1]:
                kept.append(pts[-1])  # keep the true end, so loops close
            if len(kept) > MAX_ROUTE_POINTS:
                kept = _sample(kept[:-1], MAX_ROUTE_POINTS - 1) + [kept[-1]]
            out.setdefault(m, []).append([round(c, 1) for xy in kept for c in xy])
    return out


def add_routes(loc: list | None, by_map: dict[int, list]) -> list | None:
    """Attaches routes (entry["r"]) to the location's map entries; maps the NPC only walks through
    get an entry of their own with no spawn points."""
    if not by_map:
        return loc
    loc = list(loc or [])
    for m, paths in by_map.items():
        entry = next((e for e in loc if e.get("m") == m and not e.get("e")), None)
        if entry is None:
            entry = {"m": m, "p": []}
            loc.append(entry)
        entry["r"] = paths
    return loc


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
    loc = location(zones, store.field("Npc", nid, NPC_SPAWNS))
    rare = kind == "drop" and store.field("Npc", nid, NPC_RANK) in RARE_RANKS
    if kind == "vendor" or rare:  # roaming vendors and patrolling rares: their route, drawn on the map
        loc = add_routes(loc, routes(zones, store.field("Npc", nid, NPC_WAYPOINTS)))
    return {"t": kind, "n": name, "z": store.field("Npc", nid, NPC_ZONE) or None,
            "loc": loc, "k": "rare" if rare else None,
            "f": npc_faction(store, nid) if kind == "vendor" else None}


def resolve_npc_sources(items: dict[int, dict], questie_path: Path) -> int:
    """Hand-written sources (corrections.json) that name their creature by Questie ID ("npc": 263380)
    get its name, zone and map location (with its patrol route for rares) from Questie, so they show
    on the map like imported ones. Fields written in the correction win, e.g. "k": "rare" for a rare
    Questie lists as a plain elite. Returns how many sources were resolved."""
    store = QuestieStore(find_toc(questie_path))
    zones = ZoneData(store.dir)
    n = 0
    for rec in items.values():
        for i, s in enumerate(rec.get("src") or []):
            if not (isinstance(s, dict) and s.get("npc")):
                continue
            nid = s.pop("npc")
            found = _npc_source(store, zones, s.get("t") or "drop", nid) or {}
            if found.get("loc") and s.get("k") == "rare" and found.get("k") != "rare":
                found["loc"] = add_routes(found["loc"], routes(zones, store.field("Npc", nid, NPC_WAYPOINTS)))
            rec["src"][i] = {k: v for k, v in {**found, **s}.items() if v is not None}
            n += 1
    return n


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


def item_sources(store: QuestieStore, iid: int, zones: ZoneData | None = None,
                 chances: dict | None = None) -> list[dict]:
    """chances (optional, from import_cmangos.drop_chances): adds "dc" (drop chance %) to drop
    sources and lists the creatures with the best chance first."""
    if not store.row("Item", iid):
        return []
    zones = zones or ZoneData(store.dir)
    out: list[dict] = []
    npc_dc = lambda nid: ((chances or {}).get("npc", {}).get(nid) or {}).get(iid)

    npcs = id_list(store.field("Item", iid, ITEM_NPC_DROPS))
    if chances:
        npcs.sort(key=lambda nid: -(npc_dc(nid) or 0))  # stable: unknown chances keep Questie's order
    for nid in npcs[:MAX_DROP_NPCS]:
        src = _npc_source(store, zones, "drop", nid)
        if src:
            src["dc"] = npc_dc(nid)
            out.append(src)
    if len(npcs) > MAX_DROP_NPCS:
        out.append({"t": "drop", "n": f"... and {len(npcs) - MAX_DROP_NPCS} more creatures"})

    # Same-named chests (every "Solid Chest" object) become one source. Their raw spawn tables are
    # combined before building the location, so the map areas cover every spawn of every one of them.
    chests: dict[str, dict] = {}
    chest_count: dict[str, int] = {}
    chest_dc: dict[str, float] = {}
    for oid in id_list(store.field("Item", iid, ITEM_OBJECT_DROPS)):
        name = store.name("Object", oid)
        if name:
            chest_count[name] = chest_count.get(name, 0) + 1
            combined = chests.setdefault(name, {})
            spawns = store.field("Object", oid, OBJECT_SPAWNS)
            if isinstance(spawns, list):
                spawns = {i + 1: v for i, v in enumerate(spawns)}
            for area, pts in (spawns or {}).items() if isinstance(spawns, dict) else ():
                if isinstance(pts, list):
                    combined.setdefault(area, []).extend(pts)
            dc = ((chances or {}).get("object", {}).get(oid) or {}).get(iid)
            if dc:  # same-named chests can differ (e.g. by zone): show the best one
                chest_dc[name] = max(dc, chest_dc.get(name, 0))
    for name in sorted(chests, key=lambda n: -chest_count[n])[:MAX_CHEST_KINDS]:
        out.append({"t": "drop", "n": name, "loc": location(zones, chests[name]), "k": "object", "dc": chest_dc.get(name)})

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
            if prof == "Profession" and recipe_name.startswith("Pattern:"):
                # "Pattern" is shared: cloth -> Tailoring, leather/mail -> Leatherworking
                prof = "Tailoring" if rec.get("sc") == 1 else "Leatherworking" if rec.get("sc") in (2, 3) else prof
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


CMANGOS_MAX_DROPPERS = 10  # more creatures than this = a world drop: too vague to list
CMANGOS_MIN_CHANCE = 1.0   # % (the best creature's chance)


def add_cmangos_drops(items: dict[int, dict], store: QuestieStore, zones: ZoneData, chances: dict) -> int:
    """Items still without a source: the creatures cmangos' loot tables say drop them (boss and
    named-mob loot that Questie's item list misses), named and placed on the map through Questie's
    creature data. Only specific drops, not world drops. Returns how many items got one."""
    by_item: dict[int, list[tuple[float, int]]] = {}
    for nid, found in chances.get("npc", {}).items():
        for iid, pct in found.items():
            if iid in items and not items[iid].get("src"):
                by_item.setdefault(iid, []).append((pct, nid))
    n = 0
    for iid, droppers in by_item.items():
        if len(droppers) > CMANGOS_MAX_DROPPERS or max(droppers)[0] < CMANGOS_MIN_CHANCE:
            continue
        out = []
        for pct, nid in sorted(droppers, reverse=True):
            src = _npc_source(store, zones, "drop", nid)
            if src:
                src["dc"] = pct
                out.append({k: v for k, v in src.items() if v is not None})
        if out:
            items[iid]["src"] = out
            n += 1
    return n


def raid_area(store: QuestieStore, zones: ZoneData, kind: str, eid: int, maps: dict) -> int | None:
    """The raid's area ID if this creature/chest is in a raid; 0 for an outdoor world boss; None
    otherwise. Where it spawns (cmangos spawn tables) decides; Questie's zone is the fallback for
    creatures without a fixed spawn (summoned bosses)."""
    from cmangos_items import BOSS_RANK, CONTINENTS, RAID_AREAS, RAID_MAPS, WORLD_BOSS_MIN_LEVEL
    qkind = "Npc" if kind == "npc" else "Object"
    if not store.name(qkind, eid):
        return None
    spawned = maps.get(kind, {}).get(eid) or set()
    raids = {RAID_MAPS[m] for m in spawned if m in RAID_MAPS}
    if raids:
        return raids.pop() if len(raids) == 1 and spawned <= set(RAID_MAPS) else None
    zone = store.field(qkind, eid, NPC_ZONE if kind == "npc" else OBJECT_ZONE)
    if not spawned and zone in RAID_AREAS:
        return zone
    boss = (kind == "npc" and store.field("Npc", eid, NPC_RANK) == BOSS_RANK
            and (store.field("Npc", eid, 5) or 0) >= WORLD_BOSS_MIN_LEVEL)
    if boss and spawned and spawned <= CONTINENTS:
        return 0  # world boss (Azuregos, Lord Kazzak)
    if boss and not spawned and isinstance(zone, int) and zone > 0 and zone not in zones.dungeons:
        return 0  # event-spawned world boss outdoors (the dragons of Nightmare)
    return None


def add_raid_items(items: dict[int, dict], store: QuestieStore, zones: ZoneData, chances: dict,
                   dump: Path) -> int:
    """Adds raid loot missing from the database (provisional records, see cmangos_items.py).

    An item qualifies only if every creature and chest cmangos says drops it is in a raid (or is a
    world boss): anything that also drops elsewhere is a world drop and is left alone. Its sources
    are exactly those raid creatures/chests, best chance first. Returns how many items were added."""
    from cmangos_items import MAX_SOURCES, MIN_CHANCE, MIN_QUALITY, item_shells, spawn_maps
    from build_db import excluded
    maps = spawn_maps(dump)
    area = {}  # (kind, id) -> raid area / 0 / None, cached
    droppers: dict[int, list[tuple[float, str, int]]] = {}
    for kind in ("npc", "object"):
        for eid, found in chances.get(kind, {}).items():
            for iid, pct in found.items():
                # missing, provisional from an earlier build, or known but without any source
                rec = items.get(iid)
                if rec is None or rec.get("pv") or not rec.get("src"):
                    droppers.setdefault(iid, []).append((pct, kind, eid))

    def in_raid(kind, eid):
        if (kind, eid) not in area:
            area[(kind, eid)] = raid_area(store, zones, kind, eid, maps)
        return area[(kind, eid)] is not None

    candidates = {iid for iid, ds in droppers.items()
                  if all(in_raid(k, e) for _, k, e in ds) and max(p for p, _, _ in ds) >= MIN_CHANCE}
    shells = item_shells(dump, candidates)
    added = 0
    for iid, rec in shells.items():
        known = items.get(iid)
        if known and not known.get("pv"):
            rec = {k: v for k, v in known.items() if k != "src"}  # the client's record: keep it
        if (rec.get("q") or 0) < MIN_QUALITY or excluded(rec):
            continue
        src = []
        for pct, kind, eid in sorted(droppers[iid], reverse=True):
            if pct < MIN_CHANCE or len(src) >= MAX_SOURCES:
                break
            if kind == "npc":
                s = _npc_source(store, zones, "drop", eid)
            else:
                s = {"t": "drop", "n": store.name("Object", eid), "z": store.field("Object", eid, OBJECT_ZONE),
                     "loc": location(zones, store.field("Object", eid, OBJECT_SPAWNS)), "k": "object"}
            if s:
                s["dc"] = pct
                if not s.get("z") and area[(kind, eid)]:
                    s["z"] = area[(kind, eid)]  # e.g. Sapphiron, whom Questie has no zone for
                s = {k: v for k, v in s.items() if v is not None}
                if all(o["n"] != s["n"] for o in src):
                    src.append(s)
        if src:
            items[iid] = {**rec, "src": src}
            added += 1
    return added


MAX_LEVEL_GAP = 15  # a creature this many levels below the item's required level can't drop it
WORLD_DROP_MAX_CHANCE = 1.0  # % : loot tables with no chance this high are world drops (incomplete lists)


def effective_level(rec: dict) -> int:
    """The level an item is meant for (Core.lua ns.EffectiveLevel): its required level, or item level - 5
    when it says "Requires level 1" (no requirement)."""
    rl = rec.get("rl") or 0
    return rl if rl > 1 else max(1, (rec.get("il") or 1) - 5)


def _confirmed(s) -> bool:
    """Backed by more than a database listing: players looted it in game (build_db marks those
    "seen": your own finds, and shared ones reported by 2+ players) or a loot table gives a chance."""
    return isinstance(s, dict) and bool(s.get("seen") or s.get("dc"))


def _unconfirmed_drop(s) -> bool:
    """A creature drop only a database lists: no drop chance, never seen in game by players."""
    return isinstance(s, dict) and s.get("t") == "drop" and s.get("k") != "object" and not _confirmed(s)


def drop_implausible(items: dict[int, dict], store: QuestieStore) -> tuple[int, list[int]]:
    """Removes drop sources whose creature is far below the item's level (e.g. a level 57 epic
    "dropped" by a level 16 creature), whatever added them. When most of an item's drops are like
    that, its whole unconfirmed drop list is from another version of the game (e.g. Questie listing
    level-30 copies of Molten Core loot on starting-zone boars) and none of it is kept; drops with a
    known chance stay. Returns (sources removed, items whose unconfirmed drops were all removed)."""
    level: dict[str, int] = {}
    for nid in store.ids("Npc"):
        name = store.name("Npc", nid)
        if name:
            level[name] = max(level.get(name, 0), store.field("Npc", nid, 5) or 0)
    removed, wiped = 0, []
    REMOVED_LOG.clear()
    for iid, rec in items.items():
        need = effective_level(rec)
        src = rec.get("src")
        if need <= MAX_LEVEL_GAP or not src:
            continue
        creatures = [s for s in src if isinstance(s, dict) and s.get("t") == "drop" and s.get("k") != "object"]
        # A real loot-table entry (1%+ in cmangos) or a drop players saw in game is confirmed,
        # whatever the creature's level.
        low = [s for s in creatures if 0 < level.get(s.get("n"), 0) < need - MAX_LEVEL_GAP
               and (s.get("dc") or 0) < WORLD_DROP_MAX_CHANCE and not s.get("seen")]
        if not low:
            continue
        # Most of its creatures (those of unknown level count as fitting) far below the item: the list.
        if len(low) * 2 > len(creatures):
            keep = [s for s in src if not _unconfirmed_drop(s) and s not in low]
            wiped.append(iid)
        else:
            keep = [s for s in src if s not in low]
        for s in src:
            if s not in keep:
                REMOVED_LOG.append((iid, rec.get("n"), need, s.get("n"), level.get(s.get("n")), s.get("dc"), iid in wiped))
        removed += len(src) - len(keep)
        rec["src"] = keep
    return removed, wiped


REMOVED_LOG: list[tuple] = []  # (item id, name, its level, creature, creature level, chance, whole list) for review


ITEM_LEVEL, ITEM_REQUIRED_LEVEL = 9, 10


def drop_other_version(items: dict[int, dict], store: QuestieStore) -> list[int]:
    """Questie's item record from another version of the game (its item level or required level
    differs from the game client's): the creature drops it lists for that item aren't kept unless a
    drop chance confirms them. Returns the items changed."""
    changed = []
    for iid, rec in items.items():
        src = rec.get("src")
        if not src or not store.row("Item", iid):
            continue
        qil, qrl = store.field("Item", iid, ITEM_LEVEL), store.field("Item", iid, ITEM_REQUIRED_LEVEL)
        differs = (isinstance(qil, int) and qil > 0 and rec.get("il") and qil != rec["il"]) or \
                  (isinstance(qrl, int) and qrl > 0 and rec.get("rl") and qrl != rec["rl"])
        if not differs:
            continue
        questie_droppers = {store.name("Npc", n) for n in id_list(store.field("Item", iid, ITEM_NPC_DROPS))}
        keep = [s for s in src if not (_unconfirmed_drop(s) and s.get("n") in questie_droppers)]
        if len(keep) != len(src):
            rec["src"] = keep
            changed.append(iid)
    return changed


def add_missed_gear(items: dict[int, dict], store: QuestieStore, dump: Path | None) -> int:
    """Gear Questie knows a source for that the client scan missed (the server didn't answer in time):
    provisional records (pv = 1), like cmangos_items.py does for raid loot. In game, GearGuide asks the
    client for each one and lists it only once the client returns its own record (real stats); items
    the client doesn't know never show. Classic items: name, quality, levels and slot from cmangos
    (not gear there, or poor quality: left out). WoW: Forever's own items: name and required level from
    Questie; the client fills in the rest. Returns how many were added."""
    from build_db import EXCLUDE_NAME, excluded
    from cmangos_items import ALL_CLASSES, CLASS_BITS, INVTYPE
    cmangos = {}
    if dump and dump.exists():
        from import_cmangos import read_tables
        cmangos = {r["entry"]: r for r in read_tables(dump, {"item_template"})["item_template"]}
    added = 0
    for iid in store.ids("Item"):
        if iid in items or store.field("Item", iid, 12) not in (2, 4):  # weapons, armor
            continue
        if not any(store.field("Item", iid, k) for k in (2, 3, 4, 6, 14)):  # no source: nothing to show
            continue
        name = store.name("Item", iid)
        if not name or EXCLUDE_NAME.search(name):
            continue
        row = cmangos.get(iid)
        if row:
            eq = INVTYPE.get(row.get("InventoryType") or 0)
            if not eq:
                continue  # shirts, tabards, bags...
            rec = {"n": row.get("name") or name, "q": row.get("Quality"), "il": row.get("ItemLevel"),
                   "rl": row.get("RequiredLevel") or 0, "eq": eq, "c": row.get("class"),
                   "sc": row.get("subclass"), "pv": 1}
            mask = row.get("AllowableClass") or -1
            if mask > 0 and mask & ALL_CLASSES != ALL_CLASSES:
                rec["cls"] = [n for bit, n in CLASS_BITS.items() if mask & bit]
        else:
            rec = {"n": name, "rl": store.field("Item", iid, 10) or 0, "c": store.field("Item", iid, 12), "pv": 1}
            sc = store.field("Item", iid, 13)
            if sc is not None:
                rec["sc"] = sc
        if excluded(rec):
            continue
        items[iid] = {k: v for k, v in rec.items() if v is not None}
        added += 1
    return added


def merge_sources(items: dict[int, dict], questie_path: Path, chances: dict | None = None) -> tuple[int, int]:
    """Adds Questie sources to GearGuide items in place. Returns (items with new sources, sources added).
    chances: optional drop chances (import_cmangos.drop_chances), also added to matching known sources."""
    store = QuestieStore(find_toc(questie_path))
    zones = ZoneData(store.dir)
    missed = add_missed_gear(items, store, (chances or {}).get("dump"))
    if missed:
        print(f"Gear the scan missed, from Questie (provisional, confirmed in game): {missed} items")
    touched = added = 0
    for iid, rec in items.items():
        new = item_sources(store, iid, zones, chances)
        if not new:
            continue
        have = rec.setdefault("src", [])
        if max((s.get("dc") or 0 for s in new), default=0) >= WORLD_DROP_MAX_CHANCE:
            # The item's loot table is known: learned/shared drops from other creatures are
            # misattributed (older versions credited container loot to the targeted creature).
            # World drops (every chance below 1%: chests and random creatures) are exempt: any
            # creature of the right level can drop them (same rule as Core.lua GetSources).
            droppers = {s.get("n") for s in new if s.get("t") == "drop"}
            have[:] = [s for s in have if not (isinstance(s, dict) and s.get("t") == "drop"
                                               and s.get("n") not in droppers)]
        known = {(s.get("t"), s.get("n")): s for s in have if isinstance(s, dict)}
        for s in new:
            old = known.get((s.get("t"), s.get("n")))
            if old is not None and s.get("dc") and not old.get("dc"):
                old["dc"] = s["dc"]
        fresh = [s for s in new if (s.get("t"), s.get("n")) not in known]
        if fresh:
            have.extend(fresh)
            touched += 1
            added += len(fresh)
        if chances:  # best drop chance first (stable: everything else keeps its order)
            have.sort(key=lambda s: -(s.get("dc") or 0) if isinstance(s, dict) else 0)
    if chances:
        if chances.get("dump"):  # first: raid loot gets raid-only sources
            raid = add_raid_items(items, store, zones, chances, chances["dump"])
            print(f"Raid loot from cmangos (missing from the scan, or without a source): {raid} items")
        found = add_cmangos_drops(items, store, zones, chances)
        if found:
            print(f"Drop sources from cmangos for items Questie has none for: {found} items")
    stale = drop_other_version(items, store)
    if stale:
        print(f"Questie drops from another game version (item level differs from the client), unconfirmed, "
              f"left out: {len(stale)} items ({', '.join(str(i) for i in stale[:12])}{' ...' if len(stale) > 12 else ''})")
    dropped, wiped = drop_implausible(items, store)
    if dropped:
        print(f"Removed {dropped} drop sources from creatures far below the item's level")
    if wiped:
        names = ", ".join(f"{i} {items[i].get('n', '?')}" for i in wiped[:12])
        print(f"Unconfirmed drop lists that don't fit the item's level, left out: {len(wiped)} items "
              f"({names}{' ...' if len(wiped) > 12 else ''})")
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
