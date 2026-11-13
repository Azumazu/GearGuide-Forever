#!/usr/bin/env python3
"""
Vendor buy prices from the cmangos classic-db world database (GPL-3.0,
https://github.com/cmangos/classic-db), used at build time only.

    python import_cmangos.py ClassicDB_1_12_1_z2815.sql.gz      # print a summary

Reads item_template.BuyPrice for every item that some vendor sells (npc_vendor and
npc_vendor_template). The result becomes item["bp"] (copper) in Data.lua: the default gold price for
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
                row.append(s)


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


def buy_prices(path: Path) -> dict[int, int]:
    """{item id: buy price in copper} for items a vendor sells and that cost gold."""
    t = read_tables(path, {"item_template", "npc_vendor", "npc_vendor_template"})
    sold = {r["item"] for r in t["npc_vendor"] + t["npc_vendor_template"] if isinstance(r.get("item"), int)}
    prices = {}
    for r in t["item_template"]:
        iid, price, count = r.get("entry"), r.get("BuyPrice"), r.get("BuyCount") or 1
        if iid in sold and isinstance(price, int) and price > 0:
            prices[iid] = price // max(1, count)  # price of one item (gear is always sold singly)
    return prices


def merge_prices(items: dict[int, dict], prices: dict[int, int]) -> int:
    """Sets item["bp"] on every item that has a vendor source; returns how many got a price."""
    n = 0
    for iid, rec in items.items():
        p = prices.get(iid)
        if p and any(isinstance(s, dict) and s.get("t") == "vendor" for s in rec.get("src") or []):
            rec["bp"] = p
            n += 1
        else:
            rec.pop("bp", None)
    return n


if __name__ == "__main__":
    p = buy_prices(Path(sys.argv[1]))
    print(f"{len(p)} vendor items with a gold price")
