#!/usr/bin/env python3
"""
Bakes GearGuide's in-game database scan into GearGuide/Data.lua.

In game, `/gg scan` reads every gear item from the game client into the GearGuideHarvest saved
variable (WTF/Account/<account>/SavedVariables/GearGuide.lua). This script turns that, plus the
sources GearGuide learned from loot/quest/vendor windows, into a Data.lua the addon ships with.
No web API and no API key involved. Standard library only.

Usage:
    python build_db.py --wow "E:/World of Warcraft/_forever_"
    python build_db.py --saved ".../SavedVariables/GearGuide.lua" --out ../GearGuide/Data.lua
Log out (or /reload) first so WoW writes the saved variables to disk.
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from update_db import apply_corrections, hide_by_source, write_lua, CORRECTIONS  # noqa: E402  (shared helpers)

DEFAULT_OUT = HERE.parent / "GearGuide" / "Data.lua"
MAX_LEVEL = 60
MIN_SHARED_REPORTS = 2  # sources from other players need this many independent reports to ship
JUNK_NAMES = {"", "?", "Unknown", "Container"}  # learned before the client knew the name / opened containers


def real_source(s) -> bool:
    return isinstance(s, dict) and isinstance(s.get("n"), str) and s["n"].strip() not in JUNK_NAMES
# Items in the client's table that players never get: NPC weapons, test, placeholder and retired items.
EXCLUDE_NAME = re.compile(r"^Monster - |^zz|^OLD|(?i:\btest(?:ing)?\b|qatest)|DELETE ME|Deprecated|DEPRECATED|\[PH\]|\(OLD\)|\bOLD\b|UNUSED|Unused|\bQA\b|DEBUG")
KEEP_FIELDS = ("n", "q", "il", "rl", "eq", "c", "sc", "st", "cls", "u", "r")  # r = random enchantment


class LuaParseError(ValueError):
    pass


class LuaTableParser:
    """Parses the subset of Lua that WoW writes into SavedVariables files."""

    def __init__(self, text: str):
        self.s, self.i, self.n = text, 0, len(text)

    def _ws(self) -> None:
        s, n = self.s, self.n
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("--", self.i):
                if s.startswith("--[[", self.i):
                    end = s.find("]]", self.i)
                    self.i = n if end < 0 else end + 2
                else:
                    end = s.find("\n", self.i)
                    self.i = n if end < 0 else end + 1
            else:
                break

    def _peek(self) -> str:
        self._ws()
        return self.s[self.i] if self.i < self.n else ""

    def _expect(self, ch: str) -> None:
        if self._peek() != ch:
            raise LuaParseError(f"expected {ch!r} at {self.i}: {self.s[self.i:self.i + 30]!r}")
        self.i += 1

    def _name(self) -> str:
        self._ws()
        start = self.i
        while self.i < self.n and (self.s[self.i].isalnum() or self.s[self.i] == "_"):
            self.i += 1
        if start == self.i:
            raise LuaParseError(f"expected name at {self.i}")
        return self.s[start:self.i]

    def _string(self) -> str:
        quote = self.s[self.i]
        self.i += 1
        out = []
        escapes = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'", "\n": "\n", "a": "\a",
                   "b": "\b", "f": "\f", "v": "\v"}
        while self.i < self.n:
            c = self.s[self.i]
            if c == quote:
                self.i += 1
                return "".join(out)
            if c == "\\":
                nxt = self.s[self.i + 1]
                if nxt.isdigit():  # \ddd decimal byte escape
                    j = self.i + 1
                    while j < self.i + 4 and j < self.n and self.s[j].isdigit():
                        j += 1
                    out.append(chr(int(self.s[self.i + 1:j])))
                    self.i = j
                    continue
                out.append(escapes.get(nxt, nxt))
                self.i += 2
                continue
            out.append(c)
            self.i += 1
        raise LuaParseError("unterminated string")

    def _number(self):
        start = self.i
        while self.i < self.n and self.s[self.i] in "0123456789+-.eExXabcdefABCDEF":
            self.i += 1
        text = self.s[start:self.i]
        try:
            return int(text, 0) if text.lower().startswith(("0x", "-0x")) else (
                int(text) if text.lstrip("-").isdigit() else float(text))
        except ValueError as e:
            raise LuaParseError(f"bad number {text!r}") from e

    def value(self):
        c = self._peek()
        if c == "{":
            return self._table()
        if c in "\"'":
            return self._string()
        if c.isdigit() or c in "-.":
            return self._number()
        word = self._name()
        if word in ("true", "false"):
            return word == "true"
        if word == "nil":
            return None
        raise LuaParseError(f"unexpected {word!r} at {self.i}")

    def _table(self):
        self._expect("{")
        result: dict = {}
        auto = 1
        while True:
            c = self._peek()
            if c == "}":
                self.i += 1
                break
            if c == "[":
                self.i += 1
                key = self.value()
                self._expect("]")
                self._expect("=")
                result[key] = self.value()
            else:
                save = self.i
                try:
                    key = self._name()
                    if self._peek() == "=":
                        self.i += 1
                        result[key] = self.value()
                    else:
                        raise LuaParseError("positional")
                except LuaParseError:
                    self.i = save
                    result[auto] = self.value()
                    auto += 1
            if self._peek() in ",;":
                self.i += 1
        # Lua arrays come back as lists
        if result and all(isinstance(k, int) for k in result) and sorted(result) == list(range(1, len(result) + 1)):
            return [result[k] for k in range(1, len(result) + 1)]
        return result

    def assignments(self) -> dict:
        out = {}
        while self._peek():
            name = self._name()
            self._expect("=")
            out[name] = self.value()
        return out


def find_saved_variables(wow: Path) -> Path:
    candidates = list((wow / "WTF" / "Account").glob("*/SavedVariables/GearGuide.lua"))
    if not candidates:
        raise SystemExit(f"No GearGuide saved variables under {wow / 'WTF' / 'Account'}. "
                         "Run /gg scan in game, then log out so WoW writes the file.")
    return max(candidates, key=lambda p: p.stat().st_mtime)  # most recently played account


def default_questie(wow: Path | None) -> Path | None:
    """Use the installed QuestieDB automatically when building from a game folder."""
    if wow and (wow / "Interface" / "AddOns" / "QuestieDB" / "QuestieDB_Forever.toc").exists():
        return wow / "Interface" / "AddOns" / "QuestieDB"
    return None


def as_dict(v) -> dict:
    if isinstance(v, dict):
        return v
    if isinstance(v, list):
        return {i + 1: x for i, x in enumerate(v)}
    return {}


HEADER = [
    "-- GearGuide item database. GENERATED by GearGuideTools/build_db.py from an in-game scan",
    "-- of the game client (/gg scan) plus sources seen in game. Do not edit by hand.",
]


def clean_prices(by_vendor) -> dict:
    """Validated {vendor: {"g": copper, "c": [{"n", "q", "i"}]}} from the saved variables."""
    out = {}
    for vendor, p in as_dict(by_vendor).items():
        if not (isinstance(vendor, str) and isinstance(p, dict)):
            continue
        rec = {}
        if isinstance(p.get("g"), (int, float)) and p["g"] > 0:
            rec["g"] = int(p["g"])
        costs = p.get("c")
        costs = list(costs.values()) if isinstance(costs, dict) else costs  # Lua arrays may parse as dicts
        clean = [{k: c[k] for k in ("n", "q", "i") if c.get(k) is not None}
                 for c in costs or [] if isinstance(c, dict) and c.get("n") and c.get("q")]
        if clean:
            rec["c"] = clean
        if rec:
            out[vendor] = rec
    return out


def excluded(rec: dict, keep_poor: bool = False) -> str | None:
    """Reason an item is left out of the shipped database, or None to keep it."""
    if EXCLUDE_NAME.search(rec.get("n") or ""):
        return "test/NPC/retired item"
    if (rec.get("rl") or 0) > MAX_LEVEL:
        return f"requires level above {MAX_LEVEL}"
    if (rec.get("q") or 0) >= 6:
        return "artifact/internal quality"
    if rec.get("q") == 0 and not keep_poor:
        return "poor (gray) quality"
    return None


def learned_spots(saved: Path) -> tuple[dict, dict]:
    """Creature spots learned in game (Sources.lua): ({name: {uiMapID: [x1, y1, ...]}}, {name: zone name})."""
    data = LuaTableParser(saved.read_text(encoding="utf-8", errors="replace")).assignments()
    learned = data.get("GearGuideLearned") or {}
    spots = {}
    for name, by_map in as_dict(learned.get("spots")).items():
        clean = {}
        for m, flat in as_dict(by_map).items():
            flat = list(flat.values()) if isinstance(flat, dict) else flat
            if isinstance(flat, list) and len(flat) >= 2 and all(isinstance(v, (int, float)) for v in flat):
                clean[int(m)] = flat[: len(flat) // 2 * 2]
        if clean:
            spots[str(name)] = clean
    zones = {str(n): z for n, z in as_dict(learned.get("spotZones")).items() if isinstance(z, str) and z}
    return spots, zones


def apply_spots(items: dict[int, dict], spots: dict, zones: dict) -> int:
    """Gives creature drop sources without a map location the spots learned in game (pins and
    areas, like imported locations) and, if they have no zone, the zone name. Returns sources changed."""
    from import_questie import MAX_LOC_MAPS, MAX_POINTS, _sample, areas
    changed = 0
    for rec in items.values():
        for s in rec.get("src") or []:
            if not isinstance(s, dict) or s.get("t") != "drop" or s.get("k") == "object" or s.get("loc"):
                continue
            name = s.get("n")
            if name in spots:
                loc = []
                for m, flat in sorted(spots[name].items(), key=lambda kv: -len(kv[1]))[:MAX_LOC_MAPS]:
                    pts = sorted(set(zip(flat[0::2], flat[1::2])))
                    entry = {"m": m, "p": [c for xy in _sample(pts, MAX_POINTS) for c in xy]}
                    a = areas(pts)
                    if a:
                        entry["a"] = a
                    loc.append(entry)
                s["loc"] = loc
                changed += 1
            if not s.get("z") and zones.get(name):
                s["z"] = zones[name]
                changed += 1
    return changed


def collect(saved: Path, corrections: Path = CORRECTIONS, include_learned: bool = True,
            questie: Path | None = None, keep_poor: bool = False, chances: dict | None = None):
    """Reads a SavedVariables file -> (items, meta, scan_state). Shared by build_db and release."""
    data = LuaTableParser(saved.read_text(encoding="utf-8", errors="replace")).assignments()
    harvest = data.get("GearGuideHarvest") or {}
    learned = data.get("GearGuideLearned") or {}
    items: dict[int, dict] = {}
    for iid, rec in as_dict(harvest.get("items")).items():
        if isinstance(rec, dict) and rec.get("eq"):
            items[int(iid)] = {k: rec[k] for k in KEEP_FIELDS if rec.get(k) not in (None, {}, [])}
    dropped = {}
    for iid in list(items):
        reason = excluded(items[iid], keep_poor)
        if reason:
            dropped[reason] = dropped.get(reason, 0) + 1
            del items[iid]
    if dropped:
        print("Left out: " + ", ".join(f"{n} {r}" for r, n in sorted(dropped.items(), key=lambda x: -x[1])))
    scanned = len(items)
    if include_learned:
        for iid, rec in as_dict(learned.get("items")).items():
            if isinstance(rec, dict) and rec.get("eq") and int(iid) not in items and not excluded(rec, keep_poor):
                items[int(iid)] = {k: rec[k] for k in KEEP_FIELDS if rec.get(k) not in (None, {}, [])}
        for iid, srcs in as_dict(learned.get("sources")).items():
            if int(iid) in items and isinstance(srcs, list) and srcs:
                items[int(iid)]["src"] = [s for s in srcs if real_source(s)]
        # Vendor prices seen in game -> item["vp"] = {vendor: {g: copper, c: [{n, q, i}, ...]}}
        priced = 0
        for iid, by_vendor in as_dict(learned.get("prices")).items():
            vp = clean_prices(by_vendor)
            if int(iid) in items and vp:
                items[int(iid)]["vp"] = vp
                priced += 1
        if priced:
            print(f"Vendor prices: {priced} items")
        # Sources heard from other GearGuide users: only those reported by 2+ different players ship.
        trusted = 0
        for iid, srcs in as_dict(learned.get("shared")).items():
            if int(iid) not in items or not isinstance(srcs, list):
                continue
            have = items[int(iid)].setdefault("src", [])
            seen = {(s.get("t"), s.get("n")) for s in have}
            for s in srcs:
                if real_source(s) and (s.get("c") or 0) >= MIN_SHARED_REPORTS and (s.get("t"), s.get("n")) not in seen:
                    have.append({k: s[k] for k in ("t", "n", "z") if s.get(k) is not None})
                    trusted += 1
        if trusted:
            print(f"Shared sources from players (reported 2+ times): {trusted}")
    credits = None
    if questie:
        from import_questie import merge_sources, questie_version
        touched, added = merge_sources(items, questie, chances)
        questie_ver = questie_version(questie)
        print(f"Questie sources (QuestieDB {questie_ver}): {added} sources added to {touched} items")
        credits = "Item sources include data from the Questie project's database (GPL-3.0)"
    fixed = apply_corrections(items, corrections)
    if fixed:
        print(f"Applied {fixed} corrections from {corrections.name}")
    hidden = hide_by_source(items, corrections)
    if hidden:
        print(f"Hidden by source (_hide_sources): {len(hidden)} items")
    now = datetime.now(timezone.utc)
    meta = {"generated": now.strftime("%Y-%m-%d"), "source": "client",
            "build": str(harvest.get("build") or "?"), "count": len(items), "scanned": scanned}
    if hidden:
        meta["hidden"] = hidden
    if credits:
        meta["credits"] = credits
        meta["questie"] = questie_ver
    return items, meta, as_dict(harvest.get("scan"))


def main() -> int:
    p = argparse.ArgumentParser(description="Bake GearGuide's in-game scan into Data.lua.")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("--wow", type=Path, help='game folder, e.g. "E:/World of Warcraft/_forever_"')
    src.add_argument("--saved", type=Path, help="path to SavedVariables/GearGuide.lua")
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--corrections", type=Path, default=CORRECTIONS, help="hand-written fixes (JSON)")
    p.add_argument("--questie", type=Path, help="add sources from Questie's Forever database (QuestieDB folder or game folder)")
    p.add_argument("--keep-poor", action="store_true", help="keep gray (poor quality) items")
    p.add_argument("--no-learned", action="store_true", help="skip items/sources learned from loot, quests, vendors")
    args = p.parse_args()

    saved = args.saved or find_saved_variables(args.wow)
    print(f"Reading {saved}")
    items, meta, _ = collect(saved, args.corrections, not args.no_learned, args.questie or default_questie(args.wow), args.keep_poor)
    if not items:
        print("No scanned items found. Run /gg scan in game and let it finish, then log out.", file=sys.stderr)
        return 1
    write_lua(args.out, items, meta, header=HEADER)
    with_src = sum(1 for r in items.values() if r.get("src"))
    print(f"Wrote {len(items)} items ({meta['scanned']} scanned, {len(items) - meta['scanned']} learned; "
          f"{with_src} with sources) to {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
