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
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from update_db import apply_corrections, write_lua, CORRECTIONS  # noqa: E402  (shared helpers)

DEFAULT_OUT = HERE.parent / "GearGuide" / "Data.lua"
KEEP_FIELDS = ("n", "q", "il", "rl", "eq", "c", "sc", "st", "cls", "u")


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


def collect(saved: Path, corrections: Path = CORRECTIONS, include_learned: bool = True,
            questie: Path | None = None):
    """Reads a SavedVariables file -> (items, meta, scan_state). Shared by build_db and release."""
    data = LuaTableParser(saved.read_text(encoding="utf-8", errors="replace")).assignments()
    harvest = data.get("GearGuideHarvest") or {}
    learned = data.get("GearGuideLearned") or {}
    items: dict[int, dict] = {}
    for iid, rec in as_dict(harvest.get("items")).items():
        if isinstance(rec, dict) and rec.get("eq"):
            items[int(iid)] = {k: rec[k] for k in KEEP_FIELDS if rec.get(k) not in (None, {}, [])}
    scanned = len(items)
    if include_learned:
        for iid, rec in as_dict(learned.get("items")).items():
            if isinstance(rec, dict) and rec.get("eq") and int(iid) not in items:
                items[int(iid)] = {k: rec[k] for k in KEEP_FIELDS if rec.get(k) not in (None, {}, [])}
        for iid, srcs in as_dict(learned.get("sources")).items():
            if int(iid) in items and isinstance(srcs, list) and srcs:
                items[int(iid)]["src"] = [s for s in srcs if isinstance(s, dict)]
    credits = None
    if questie:
        from import_questie import merge_sources, questie_version
        touched, added = merge_sources(items, questie)
        questie_ver = questie_version(questie)
        print(f"Questie sources (QuestieDB {questie_ver}): {added} sources added to {touched} items")
        credits = "Item sources include data from the Questie project's database (GPL-3.0)"
    fixed = apply_corrections(items, corrections)
    if fixed:
        print(f"Applied {fixed} corrections from {corrections.name}")
    now = datetime.now(timezone.utc)
    meta = {"generated": now.strftime("%Y-%m-%d"), "source": "client",
            "build": str(harvest.get("build") or "?"), "count": len(items), "scanned": scanned}
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
    p.add_argument("--no-learned", action="store_true", help="skip items/sources learned from loot, quests, vendors")
    args = p.parse_args()

    saved = args.saved or find_saved_variables(args.wow)
    print(f"Reading {saved}")
    items, meta, _ = collect(saved, args.corrections, not args.no_learned, args.questie or default_questie(args.wow))
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
