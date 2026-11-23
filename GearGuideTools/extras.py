#!/usr/bin/env python3
"""
Mounts, toys and recipes for the Gear Browser's "Additional drops" (off by default in game). Build
time only. Recipes: item class 9 (Recipe) in both databases, profession subclasses 1-11 (subclass 0
is class books, not recipes); x = "r".

Which items:
  * Questie's Forever database (QuestieDB, GPL-3.0) classifies WoW: Forever's own items like the
    modern client: item class 15 (Miscellaneous), subclass 5 = Mount, subclass 4 = Other. Toys are
    among "Other" with no flag of their own, so those ship as toy candidates (x = "t") and the
    game confirms each one with its toy API before showing it.
  * cmangos classic-db (GPL-3.0): classic mounts are class 15 items whose spell applies the
    "mounted" aura (78). Their sources come from Questie like every other item.

Records: { n = name, x = "m" (mount) | "t" (toy candidate), q = quality (when cmangos knows it),
rl = required level }. Sources are added by the usual Questie merge; items left without any source
are dropped (nothing to show where to get them).
"""
from __future__ import annotations

from pathlib import Path

MOUNT_AURA = 78              # SPELL_AURA_MOUNTED
MISC_CLASS = 15
SUB_OTHER, SUB_MOUNT = 4, 5
RECIPE_CLASS = 9


def questie_extras(questie: Path) -> dict[int, dict]:
    from import_questie import QuestieStore, find_toc
    store = QuestieStore(find_toc(questie))
    out: dict[int, dict] = {}
    for iid in store.ids("Item"):
        cls, sub = store.field("Item", iid, 12), store.field("Item", iid, 13)
        if cls == MISC_CLASS and sub in (SUB_MOUNT, SUB_OTHER):
            kind = "m" if sub == SUB_MOUNT else "t"
        elif cls == RECIPE_CLASS and sub:
            kind = "r"
        else:
            continue
        name = store.name("Item", iid)
        if not name:
            continue
        rec = {"n": name, "x": kind}
        rl = store.field("Item", iid, 10)
        if isinstance(rl, int) and rl > 0:
            rec["rl"] = rl
        out[iid] = rec
    return out


def cmangos_mounts(dump: Path) -> dict[int, dict]:
    from import_cmangos import read_tables
    t = read_tables(dump, {"item_template", "spell_template"})
    mount_spells = {s["Id"] for s in t["spell_template"]
                    if MOUNT_AURA in (s.get("EffectApplyAuraName1"), s.get("EffectApplyAuraName2"),
                                      s.get("EffectApplyAuraName3"))}
    out: dict[int, dict] = {}
    for r in t["item_template"]:
        if not r.get("name"):
            continue
        if r.get("class") == MISC_CLASS and r.get("spellid_1") in mount_spells:
            kind = "m"
        elif r.get("class") == RECIPE_CLASS and r.get("subclass"):
            kind = "r"
        else:
            continue
        rec = {"n": r["name"], "x": kind}
        if isinstance(r.get("Quality"), int):
            rec["q"] = r["Quality"]
        if isinstance(r.get("RequiredLevel"), int) and r["RequiredLevel"] > 0:
            rec["rl"] = r["RequiredLevel"]
        out[r["entry"]] = rec
    return out


def extra_items(questie: Path | None, cmangos: Path | None) -> dict[int, dict]:
    """{item id: record} for mounts and toy candidates (no sources yet)."""
    out: dict[int, dict] = {}
    if cmangos and cmangos.exists():
        out.update(cmangos_mounts(cmangos))
    if questie:
        for iid, rec in questie_extras(questie).items():
            old = out.get(iid)
            out[iid] = {**rec, **({"q": old["q"]} if old and "q" in old else {})}
            if old and old["x"] == "m":
                out[iid]["x"] = "m"  # cmangos' spell check says mount
    return out


def add_extras(items: dict[int, dict], questie: Path | None, cmangos: Path | None) -> int:
    """Adds mounts/toy candidates that aren't already items (gear). Returns how many."""
    from build_db import EXCLUDE_NAME  # test/deprecated items ("Deprecated Wolf Summoning (Mount)")
    n = 0
    for iid, rec in extra_items(questie, cmangos).items():
        if iid not in items and not EXCLUDE_NAME.search(rec["n"]):
            items[iid] = rec
            n += 1
    return n


def drop_sourceless(items: dict[int, dict]) -> tuple[int, int, int]:
    """After the source merge: extras without any source are removed. Returns (mounts, toys, recipes) kept."""
    for iid in [i for i, r in items.items() if r.get("x") and not r.get("src")]:
        del items[iid]
    return tuple(sum(1 for r in items.values() if r.get("x") == k) for k in ("m", "t", "r"))
