#!/usr/bin/env python3
"""
Vendor buy prices from the cmangos classic-db world database (GPL-3.0,
https://github.com/cmangos/classic-db), used at build time only.

    python import_cmangos.py ClassicDB_1_12_1_z2815.sql.gz      # print a summary

Reads item_template.BuyPrice for every item that some vendor sells (npc_vendor and
npc_vendor_template), except PvP rank gear (bought with Honor in WoW: Forever). The result becomes item["bp"] (copper) in Data.lua: the default gold price for
the item's vendor sources. Prices seen at a vendor in game (item["vp"]) always win, because
WoW: Forever may have changed a price, and reputation discounts apply on top.
"""
from __future__ import annotations

import gzip
import re
import sys
from pathlib import Path

CREDITS = "Vendor prices include data from the cmangos classic-db project (GPL-3.0)"

# One SQL value inside a VALUES tuple: a quoted string (with backslash escapes), NULL or a number.
TOKEN = re.compile(r"'((?:[^'\\]|\\.)*)'|(NULL)|(-?\d+(?:\.\d+)?(?:e[+-]?\d+)?)|([(),])", re.I)


_ESCAPES = {"n": "\n", "r": "", "t": "\t", "0": ""}


def _unescape(s: str) -> str:
    """mysqldump string escapes (backslash + quote, backslash, n, ...) -> plain text."""
    return re.sub(r"\\(.)", lambda m: _ESCAPES.get(m.group(1), m.group(1)), s) if "\\" in s else s


def _rows(values: str):
    """Yields each (...) tuple of an INSERT ... VALUES list as a list of Python values."""
    row = None
    for m in TOKEN.finditer(values):
        s, null, num, punct = m.groups()
        if punct == "(":
            row = []
        elif punct == ")":
            if row is not None:
                yield row
            row = None
        elif punct == ",":
            continue
        elif row is not None:
            if null:
                row.append(None)
            elif num is not None:
                row.append(float(num) if "." in num or "e" in num.lower() else int(num))
            else:
                row.append(_unescape(s))


def _columns(create: str) -> list[str]:
    return re.findall(r"^\s*`(\w+)`", create, re.M)


def read_tables(path: Path, wanted: set[str]) -> dict[str, list[dict]]:
    """Rows of the wanted tables as dicts keyed by column name, from a mysqldump (.sql or .sql.gz)."""
    opener = gzip.open if path.suffix == ".gz" else open
    cols: dict[str, list[str]] = {}
    out: dict[str, list[dict]] = {t: [] for t in wanted}
    create, current = None, None
    with opener(path, "rt", encoding="utf-8", errors="replace") as f:
        for line in f:
            if create is not None:  # inside CREATE TABLE: collect column names until the closing line
                create += line
                if line.startswith(")"):
                    cols[current] = _columns(create)
                    create = None
                continue
            m = re.match(r"CREATE TABLE `(\w+)`", line)
            if m and m.group(1) in wanted:
                current, create = m.group(1), ""
                continue
            m = re.match(r"INSERT INTO `(\w+)` VALUES ", line)
            if m and m.group(1) in wanted:
                names = cols[m.group(1)]
                out[m.group(1)].extend(dict(zip(names, r)) for r in _rows(line[m.end():]))
    return out


def vendor_data(path: Path) -> tuple[dict[int, int], dict[int, int]]:
    """({item id: buy price in copper}, {item id: PvP rank needed}) for items a vendor sells."""
    t = read_tables(path, {"item_template", "npc_vendor", "npc_vendor_template"})
    sold = {r["item"] for r in t["npc_vendor"] + t["npc_vendor_template"] if isinstance(r.get("item"), int)}
    prices, ranks = {}, {}
    for r in t["item_template"]:
        iid, price, count = r.get("entry"), r.get("BuyPrice"), r.get("BuyCount") or 1
        if iid in sold and isinstance(r.get("requiredhonorrank"), int) and r["requiredhonorrank"] > 0:
            ranks[iid] = r["requiredhonorrank"]
        # PvP rank gear: WoW: Forever's honor vendors charge Honor Points (and battleground marks),
        # not the vanilla gold price, so no default price is shipped for it. The real cost is
        # learned the first time a player opens that vendor.
        if r.get("requiredhonorrank"):
            continue
        if iid in sold and isinstance(price, int) and price > 0:
            prices[iid] = price // max(1, count)  # price of one item (gear is always sold singly)
    return prices, ranks


def buy_prices(path: Path) -> dict[int, int]:
    """{item id: buy price in copper} for items a vendor sells and that cost gold."""
    return vendor_data(path)[0]


def merge_prices(items: dict[int, dict], prices: dict[int, int], ranks: dict[int, int] | None = None) -> int:
    """Sets item["bp"] on every item that has a vendor source, and item["hr"] (PvP rank needed: the
    item is bought with Honor) on honor vendor gear; returns how many got a gold price."""
    n = 0
    for iid, rec in items.items():
        if ranks is not None:
            if ranks.get(iid):
                rec["hr"] = ranks[iid]
            else:
                rec.pop("hr", None)
        p = prices.get(iid)
        if p and any(isinstance(s, dict) and s.get("t") == "vendor" for s in rec.get("src") or []):
            rec["bp"] = p
            n += 1
        else:
            rec.pop("bp", None)
    return n


# ----------------------------------------------------------------------------- random variants
def random_variants(path: Path) -> tuple[dict[int, int], dict[int, list]]:
    """({item id: random property group}, {group: [suffix id, chance %, suffix id, chance %, ...]}).

    Items like "Cross Dagger" drop as "...of the Falcon", "...of the Monkey" etc.: item_template.RandomProperty
    names a group, item_enchantment_template lists the group's suffixes (ItemRandomProperties ids, the
    7th field of an item link) with their chances. Names and stats aren't taken from here: the game
    client returns them for a link carrying the suffix id."""
    t = read_tables(path, {"item_template", "item_enchantment_template"})
    groups: dict[int, list[tuple[int, float]]] = {}
    for r in t["item_enchantment_template"]:
        if isinstance(r.get("entry"), int) and isinstance(r.get("ench"), int):
            groups.setdefault(r["entry"], []).append((r["ench"], float(r.get("chance") or 0)))
    item_group = {r["entry"]: r["RandomProperty"] for r in t["item_template"]
                  if r.get("RandomProperty") and r["RandomProperty"] in groups}
    flat = {}
    for g, entries in groups.items():
        # cmangos chances don't always add up to 100 (131 groups go over): show each as its share.
        total = sum(c for _, c in entries) or 1
        entries = [(p, c * 100 / total) for p, c in entries]
        entries.sort(key=lambda e: (-e[1], e[0]))  # most likely first
        flat[g] = [x for p, c in entries for x in (p, round(c, 2))]
    return item_group, flat


def merge_variants(items: dict[int, dict], item_group: dict[int, int], groups: dict[int, list]) -> dict[int, list]:
    """Sets item["rg"] on items with random variants; returns the groups those items use."""
    used = {}
    for iid, rec in items.items():
        g = item_group.get(iid)
        if g:
            rec["rg"] = g
            used[g] = groups[g]
        else:
            rec.pop("rg", None)
    return used


# ----------------------------------------------------------------------------- drop chances
DROP_CREDITS = "Drop chances are from the cmangos classic-db project (GPL-3.0)"
CHEST = 3  # gameobject_template.type of chests; data1 is their loot id


class _Loot:
    """Chance of each item dropping from one loot entry, following cmangos' loot rules:
    - rows outside a group roll on their own (ChanceOrQuestChance %; negative = quest drop),
    - each group (groupid > 0) yields at most one item: the rows with a chance roll first, the
      rows with chance 0 share what's left equally,
    - a negative mincountOrRef points at reference_loot_template, rolled maxcount times."""

    def __init__(self, tables: dict[str, list[dict]]):
        self.by_entry: dict[str, dict[int, list[dict]]] = {}
        for name, rows in tables.items():
            idx = self.by_entry.setdefault(name, {})
            for r in rows:
                idx.setdefault(r["entry"], []).append(r)
        self._refs: dict[int, dict[int, float]] = {}

    def chances(self, table: str, entry: int, _depth: int = 0) -> dict[int, float]:
        """{item id: probability (0-1) that at least one drops} for one kill/chest of `entry`."""
        if table == "reference_loot_template" and entry in self._refs:
            return self._refs[entry]
        rows = self.by_entry.get(table, {}).get(entry, [])
        miss: dict[int, float] = {}  # item -> probability that it does NOT drop

        def add(row, picked: float):
            ref = row.get("mincountOrRef") or 0
            if ref < 0:
                if _depth > 8:
                    return
                times = max(1, row.get("maxcount") or 1)
                for iid, q in self.chances("reference_loot_template", -ref, _depth + 1).items():
                    p = picked * (1 - (1 - q) ** times)
                    miss[iid] = miss.get(iid, 1.0) * (1 - p)
            elif row.get("item"):
                miss[row["item"]] = miss.get(row["item"], 1.0) * (1 - picked)

        groups: dict[int, list[dict]] = {}
        for r in rows:
            if r.get("groupid"):
                groups.setdefault(r["groupid"], []).append(r)
            else:
                add(r, min(100.0, abs(r.get("ChanceOrQuestChance") or 0)) / 100)
        for members in groups.values():
            explicit = [r for r in members if r.get("ChanceOrQuestChance")]
            equal = [r for r in members if not r.get("ChanceOrQuestChance")]
            used = sum(abs(r["ChanceOrQuestChance"]) for r in explicit)
            for r in explicit:
                add(r, min(100.0, abs(r["ChanceOrQuestChance"])) / 100)
            if equal:
                share = max(0.0, 100.0 - used) / 100 / len(equal)
                for r in equal:
                    add(r, share)
        out = {iid: 1 - m for iid, m in miss.items() if m < 1}
        if table == "reference_loot_template":
            self._refs[entry] = out
        return out


def drop_chances(path: Path, wanted: set[int] | None = None) -> dict[str, dict[int, dict[int, float]]]:
    """{"npc": {creature id: {item id: %}}, "object": {gameobject id: {item id: %}}} from a cmangos
    dump. Only items in `wanted` (all when None) are kept."""
    t = read_tables(path, {"creature_template", "gameobject_template", "creature_loot_template",
                           "gameobject_loot_template", "reference_loot_template"})
    loot = _Loot({k: t[k] for k in ("creature_loot_template", "gameobject_loot_template", "reference_loot_template")})
    out: dict[str, dict[int, dict[int, float]]] = {"npc": {}, "object": {}}

    def keep(kind, eid, table, loot_id):
        if not loot_id:
            return
        found = {iid: round(p * 100, 3) for iid, p in loot.chances(table, loot_id).items()
                 if (wanted is None or iid in wanted) and p > 0}
        if found:
            out[kind][eid] = found

    for r in t["creature_template"]:
        keep("npc", r.get("Entry"), "creature_loot_template", r.get("LootId"))
    for r in t["gameobject_template"]:
        if r.get("type") == CHEST:
            keep("object", r.get("entry"), "gameobject_loot_template", r.get("data1"))
    return out


def format_chance(pct: float) -> str:
    return f"{pct:.0f}%" if pct >= 10 else f"{pct:.1f}%" if pct >= 1 else f"{pct:.2f}%" if pct >= 0.1 else "<0.1%"


if __name__ == "__main__":
    path = Path(sys.argv[1])
    if len(sys.argv) > 2:  # import_cmangos.py dump.sql ITEM_ID ... : drop chances for these items
        ids = {int(a) for a in sys.argv[2:]}
        dc = drop_chances(path, ids)
        for kind, by in dc.items():
            for eid, found in by.items():
                for iid, pct in found.items():
                    print(f"item {iid}: {kind} {eid} {format_chance(pct)}")
    else:
        p = buy_prices(path)
        print(f"{len(p)} vendor items with a gold price")
