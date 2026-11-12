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
import struct
import sys
import zlib
from pathlib import Path

# Field indices from QuestieDB src/meta/*Meta.lua
ITEM_NAME, ITEM_NPC_DROPS, ITEM_OBJECT_DROPS, ITEM_ITEM_DROPS, ITEM_QUEST_REWARDS, ITEM_VENDORS = 1, 2, 3, 4, 6, 14
NPC_NAME, NPC_ZONE = 1, 9
OBJECT_NAME, OBJECT_ZONE = 1, 5
QUEST_NAME, QUEST_ZONE_OR_SORT = 1, 17

WORLD_DROP_THRESHOLD = 12   # more droppers than this -> one "World drop" source
CHEST_THRESHOLD = 3         # more distinct chests than this -> one summary source
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


# ----------------------------------------------------------------------------- sources
def item_sources(store: QuestieStore, iid: int) -> list[dict]:
    if not store.row("Item", iid):
        return []
    out: list[dict] = []

    npcs = id_list(store.field("Item", iid, ITEM_NPC_DROPS))
    if len(npcs) > WORLD_DROP_THRESHOLD:
        out.append({"t": "drop", "n": f"World drop ({len(npcs)} creatures)"})
    else:
        for nid in npcs[:MAX_SOURCES_PER_KIND]:
            name = store.name("Npc", nid)
            if name:
                out.append({"t": "drop", "n": name, "z": store.field("Npc", nid, NPC_ZONE) or None})

    objects = []
    for oid in id_list(store.field("Item", iid, ITEM_OBJECT_DROPS)):
        name = store.name("Object", oid)
        if name:
            objects.append({"t": "drop", "n": name, "z": store.field("Object", oid, OBJECT_ZONE) or None})
    objects = list({(o["n"], o["z"]): o for o in objects}.values())  # same chest type in same zone once
    if len(objects) > CHEST_THRESHOLD:
        kinds = sorted({o["n"] for o in objects})
        label = kinds[0] if len(kinds) == 1 else "Treasure chests"
        out.append({"t": "drop", "n": f"{label} ({len(objects)} locations)"})
    else:
        out.extend(objects)

    for cid in id_list(store.field("Item", iid, ITEM_ITEM_DROPS))[:MAX_SOURCES_PER_KIND]:
        name = store.name("Item", cid)
        if name:
            out.append({"t": "drop", "n": f"Inside {name}"})

    for vid in id_list(store.field("Item", iid, ITEM_VENDORS))[:MAX_SOURCES_PER_KIND]:
        name = store.name("Npc", vid)
        if name:
            out.append({"t": "vendor", "n": name, "z": store.field("Npc", vid, NPC_ZONE) or None})

    for qid in id_list(store.field("Item", iid, ITEM_QUEST_REWARDS))[:MAX_SOURCES_PER_KIND]:
        name = store.name("Quest", qid)
        if name:
            zone = store.field("Quest", qid, QUEST_ZONE_OR_SORT)
            out.append({"t": "quest", "n": name, "z": zone if isinstance(zone, int) and zone > 0 else None})

    unique = {}
    for src in out:
        src = {k: v for k, v in src.items() if v is not None}
        unique.setdefault((src.get("t"), src.get("n"), src.get("z")), src)
    return list(unique.values())


def merge_sources(items: dict[int, dict], questie_path: Path) -> tuple[int, int]:
    """Adds Questie sources to GearGuide items in place. Returns (items with new sources, sources added)."""
    store = QuestieStore(find_toc(questie_path))
    touched = added = 0
    for iid, rec in items.items():
        new = item_sources(store, iid)
        if not new:
            continue
        have = rec.setdefault("src", [])
        seen = {(s.get("t"), s.get("n")) for s in have}
        fresh = [s for s in new if (s.get("t"), s.get("n")) not in seen]
        if fresh:
            have.extend(fresh)
            touched += 1
            added += len(fresh)
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
