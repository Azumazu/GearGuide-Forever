#!/usr/bin/env python3
"""
GearGuide database updater.

Builds GearGuide/Data.lua from Blizzard's official Battle.net Game Data API
(https://develop.battle.net). Uses only the Python standard library.

Credentials come from environment variables (create a free client at
https://develop.battle.net/access/clients):
    BLIZZARD_CLIENT_ID, BLIZZARD_CLIENT_SECRET

Usage:
    python update_db.py                      # auto-detect namespace, write ../GearGuide/Data.lua
    python update_db.py --region eu --out "<WoW>/Interface/AddOns/GearGuide/Data.lua"
    python update_db.py --list-namespaces    # only probe which namespaces answer

Item details are cached in .cache/ so re-runs only fetch new items.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_OUT = HERE.parent / "GearGuide" / "Data.lua"
CACHE_DIR = HERE / ".cache"
CORRECTIONS = HERE / "corrections.json"
TOKEN_URL = "https://oauth.battle.net/token"

# Blizzard Developer API Terms of Use:
#  - "limited to thirty-six thousand (36,000) calls ... per hour" -> stay below it
#  - "maximum 30-day TTL ... for all Data obtained through our APIs" -> cache and Data.lua expire
HOURLY_CALL_LIMIT = 35_000
DATA_TTL_SECONDS = 30 * 24 * 3600

# Tried in order. The Forever name is a guess (unconfirmed at time of writing);
# Classic Era is the fallback. Override with --namespace once you know the right one.
NAMESPACE_CANDIDATES = ["static-forever-{region}", "static-classic1x-{region}"]

GEAR_ITEM_CLASSES = {2, 4}  # weapon, armor
SKIP_INVTYPES = {"NON_EQUIP", "BODY", "TABARD", "BAG", "AMMO", "QUIVER"}
QUALITY = {"POOR": 0, "COMMON": 1, "UNCOMMON": 2, "RARE": 3, "EPIC": 4,
           "LEGENDARY": 5, "ARTIFACT": 6, "HEIRLOOM": 7}
CLASS_TOKENS = {1: "WARRIOR", 2: "PALADIN", 3: "HUNTER", 4: "ROGUE", 5: "PRIEST",
                7: "SHAMAN", 8: "MAGE", 9: "WARLOCK", 11: "DRUID"}
STAT_KEYS = {"STRENGTH": "STR", "AGILITY": "AGI", "STAMINA": "STA",
             "INTELLECT": "INT", "SPIRIT": "SPI"}

# Equip effects ("spells") parsed into stats. Order matters: specific before generic.
SPELL_PATTERNS = [
    (re.compile(r"ranged attack power by (\d+)", re.I), "RAP"),
    (re.compile(r"attack power by (\d+)", re.I), "AP"),
    (re.compile(r"healing done by spells and effects by up to (\d+)", re.I), "HEAL"),
    (re.compile(r"damage and healing done by magical spells and effects by up to (\d+)", re.I), "SP"),
    (re.compile(r"critical strike with spells by (\d+)%", re.I), "SCRIT"),
    (re.compile(r"chance to hit with spells by (\d+)%", re.I), "SHIT"),
    (re.compile(r"critical strike by (\d+)%", re.I), "CRIT"),
    (re.compile(r"chance to hit by (\d+)%", re.I), "HIT"),
    (re.compile(r"defense \+(\d+)", re.I), "DEF"),
    (re.compile(r"dodge an attack by (\d+)%", re.I), "DODGE"),
    (re.compile(r"parry an attack by (\d+)%", re.I), "PARRY"),
    (re.compile(r"block attacks with a shield by (\d+)%", re.I), "BLOCK"),
    (re.compile(r"(\d+) mana per 5 sec", re.I), "MP5"),
    (re.compile(r"haste by (\d+)%", re.I), "HASTE"),
    (re.compile(r"attack and casting speed by (\d+)%", re.I), "HASTE"),
    (re.compile(r"expertise by (\d+)%", re.I), "EXPERTISE"),
]


class ApiError(RuntimeError):
    pass


class Api:
    """Minimal Battle.net API client with token handling, rate limiting and retries."""

    def __init__(self, region: str, locale: str, client_id: str, client_secret: str,
                 min_interval: float = 0.012):
        self.base = f"https://{region}.api.blizzard.com"
        self.locale = locale
        self.client_id, self.client_secret = client_id, client_secret
        self.min_interval = min_interval  # ~80 req/s, under the 100/s limit
        self._token: str | None = None
        self._last = 0.0
        self.requests = 0
        self._window: deque[float] = deque()  # timestamps of calls in the last hour

    def _throttle(self) -> None:
        """Per-second spacing plus a hard cap on calls per rolling hour."""
        now = time.monotonic()
        while self._window and now - self._window[0] >= 3600:
            self._window.popleft()
        if len(self._window) >= HOURLY_CALL_LIMIT:
            wait = 3600 - (now - self._window[0]) + 1
            print(f"  hourly API limit reached, pausing {wait / 60:.0f} min...")
            time.sleep(wait)
            return self._throttle()
        wait = self.min_interval - (now - self._last)
        if wait > 0:
            time.sleep(wait)
        self._last = time.monotonic()
        self._window.append(self._last)

    def _fetch_token(self) -> str:
        auth = base64.b64encode(f"{self.client_id}:{self.client_secret}".encode()).decode()
        req = urllib.request.Request(
            TOKEN_URL, data=b"grant_type=client_credentials",
            headers={"Authorization": f"Basic {auth}",
                     "Content-Type": "application/x-www-form-urlencoded"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)["access_token"]
        except urllib.error.HTTPError as e:
            raise ApiError(f"Token request failed ({e.code}). Check BLIZZARD_CLIENT_ID/SECRET.") from e

    def get(self, path: str, namespace: str, **params) -> dict | None:
        """GET a JSON document. Returns None on 404 (endpoint/namespace not available)."""
        if self._token is None:
            self._token = self._fetch_token()
        query = {"namespace": namespace, "locale": self.locale, **params}
        url = f"{self.base}{path}?{urllib.parse.urlencode(query)}"
        for attempt in range(6):
            self._throttle()
            self.requests += 1
            req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self._token}"})
            try:
                with urllib.request.urlopen(req, timeout=30) as r:
                    return json.load(r)
            except urllib.error.HTTPError as e:
                if e.code == 404:
                    return None
                if e.code == 401 and attempt == 0:
                    self._token = self._fetch_token()
                    continue
                if e.code in (429, 500, 502, 503, 504):
                    time.sleep(2 ** attempt)
                    continue
                raise ApiError(f"HTTP {e.code} for {path}") from e
            except urllib.error.URLError:
                time.sleep(2 ** attempt)
        raise ApiError(f"Giving up on {path} after retries")

    def cached(self, namespace: str, kind: str, key: int, path: str, refresh: bool) -> dict | None:
        """GET with an on-disk cache under .cache/<namespace>/<kind>/<key>.json."""
        file = CACHE_DIR / namespace / kind / f"{key}.json"
        fresh = file.exists() and time.time() - file.stat().st_mtime < DATA_TTL_SECONDS
        if fresh and not refresh:
            return json.loads(file.read_text(encoding="utf-8"))
        doc = self.get(path, namespace)
        if doc is not None:
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text(json.dumps(doc), encoding="utf-8")
        return doc


def prune_cache() -> int:
    """Deletes cached API responses older than the 30-day TTL."""
    removed = 0
    if CACHE_DIR.exists():
        cutoff = time.time() - DATA_TTL_SECONDS
        for f in CACHE_DIR.rglob("*.json"):
            if f.stat().st_mtime < cutoff:
                f.unlink()
                removed += 1
    return removed


def localized(value, locale: str) -> str:
    if isinstance(value, dict):
        return value.get(locale) or value.get("en_US") or next(iter(value.values()), "")
    return value or ""


def pick_namespace(api: Api, region: str, explicit: str | None) -> str:
    candidates = [explicit] if explicit else [c.format(region=region) for c in NAMESPACE_CANDIDATES]
    for ns in candidates:
        if api.get("/data/wow/item-class/index", ns) is not None:
            return ns
        print(f"  namespace {ns}: not available")
    raise ApiError("No working namespace found. Pass --namespace explicitly.")


def search_gear(api: Api, namespace: str, max_level: int) -> dict[int, dict]:
    """Walks the item search index by id range and keeps equippable weapons/armor."""
    found: dict[int, dict] = {}
    start, scanned = 1, 0
    while True:
        res = api.get("/data/wow/search/item", namespace,
                      orderby="id", _pageSize="1000", id=f"[{start},]")
        results = (res or {}).get("results") or []
        if not results:
            break
        for entry in results:
            d = entry.get("data") or {}
            iid = d.get("id")
            if iid is None:
                continue
            start = max(start, iid + 1)
            scanned += 1
            inv = (d.get("inventory_type") or {}).get("type")
            cls = (d.get("item_class") or {}).get("id")
            if (not d.get("is_equippable") or cls not in GEAR_ITEM_CLASSES
                    or inv is None or inv in SKIP_INVTYPES
                    or (d.get("required_level") or 0) > max_level):
                continue
            found[iid] = d
        print(f"  scanned {scanned} items, {len(found)} gear so far (next id {start})")
    return found


def invtype_to_lua(inv: str) -> str:
    return "INVTYPE_2HWEAPON" if inv == "TWOHWEAPON" else f"INVTYPE_{inv}"


def build_record(summary: dict, detail: dict | None, locale: str) -> dict:
    rec = {
        "n": localized(summary.get("name"), locale),
        "q": QUALITY.get((summary.get("quality") or {}).get("type"), 1),
        "il": summary.get("level") or 0,
        "rl": summary.get("required_level") or 0,
        "eq": invtype_to_lua((summary.get("inventory_type") or {}).get("type", "")),
        "c": (summary.get("item_class") or {}).get("id"),
        "sc": (summary.get("item_subclass") or {}).get("id"),
    }
    preview = (detail or {}).get("preview_item") or {}
    stats: dict[str, float] = {}
    for s in preview.get("stats") or []:
        key = STAT_KEYS.get((s.get("type") or {}).get("type"))
        if key and not s.get("is_negated"):
            stats[key] = stats.get(key, 0) + s.get("value", 0)
    armor = (preview.get("armor") or {}).get("value")
    if armor:
        stats["ARMOR"] = armor
    dps = ((preview.get("weapon") or {}).get("dps") or {}).get("value")
    if dps:
        stats["DPS"] = round(dps, 1)
    for spell in preview.get("spells") or []:
        text = localized(spell.get("description"), locale)
        for pattern, key in SPELL_PATTERNS:
            m = pattern.search(text)
            if m:
                stats[key] = stats.get(key, 0) + int(m.group(1))
                break
    rec["st"] = stats
    if preview.get("unique_equipped") or (detail or {}).get("is_unique"):
        rec["u"] = 1  # unique-equipped: only one can be worn (rings/trinkets/weapons)

    reqs = preview.get("requirements") or (detail or {}).get("requirements") or {}
    links = (reqs.get("playable_classes") or {}).get("links") or []
    classes = [CLASS_TOKENS[l["id"]] for l in links if l.get("id") in CLASS_TOKENS]
    if classes:
        rec["cls"] = classes
    return rec


def journal_sources(api: Api, namespace: str, refresh: bool, locale: str) -> dict[int, list]:
    """Boss drops from the Adventure Guide endpoints, if this namespace has them."""
    index = api.get("/data/wow/journal-instance/index", namespace)
    if not index:
        print("  no journal data in this namespace; boss-drop sources will come from in-game learning")
        return {}
    sources: dict[int, list] = {}
    for inst in index.get("instances") or []:
        idoc = api.cached(namespace, "journal-instance", inst["id"],
                          f"/data/wow/journal-instance/{inst['id']}", refresh)
        if not idoc:
            continue
        iname = localized(idoc.get("name"), locale)
        for enc in idoc.get("encounters") or []:
            edoc = api.cached(namespace, "journal-encounter", enc["id"],
                              f"/data/wow/journal-encounter/{enc['id']}", refresh)
            if not edoc:
                continue
            ename = localized(edoc.get("name"), locale)
            for it in edoc.get("items") or []:
                iid = (it.get("item") or {}).get("id")
                if iid:
                    sources.setdefault(iid, []).append({"t": "drop", "n": ename, "z": iname})
    print(f"  journal: sources for {len(sources)} items")
    return sources


def apply_corrections(items: dict[int, dict], path: Path = CORRECTIONS) -> int:
    """Hand-written fixes, applied last at build time (they beat scanned and learned data).

    corrections.json: { "<itemId>": { "<field>": value | null, "src+": [...], "src-": [...], "_delete": true } }
      field: null      -> remove the field         "src+": add these sources
      "_delete": true  -> drop the item entirely   "src-": remove sources matching all given keys
    A correction for an unknown item with "n" and "eq" adds that item.
    """
    if not path.exists():
        return 0
    raw = json.loads(path.read_text(encoding="utf-8"))
    applied = 0
    for key, fix in raw.items():
        if key.startswith("_") or not isinstance(fix, dict):
            continue  # "_comment" etc.
        iid = int(key)
        if fix.get("_delete"):
            applied += items.pop(iid, None) is not None
            continue
        rec = items.get(iid)
        if rec is None:
            if not (fix.get("n") and fix.get("eq")):
                print(f"  correction for unknown item {iid} skipped (needs n and eq to add it)")
                continue
            rec = items[iid] = {}
        for field, value in fix.items():
            if field == "src+":
                rec.setdefault("src", []).extend(value)
            elif field == "src-":
                rec["src"] = [s for s in rec.get("src", [])
                              if not any(all(s.get(k) == v for k, v in m.items()) for m in value)]
            elif value is None:
                rec.pop(field, None)
            else:
                rec[field] = value
        applied += 1
    return applied


# ---------------------------------------------------------------- Lua output
_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def lua_str(s: str) -> str:
    return '"' + (s.replace("\\", "\\\\").replace('"', '\\"')
                  .replace("\n", "\\n").replace("\r", "")) + '"'


def lua_val(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v.is_integer():
            return str(int(v))
        return f"{v:.4f}".rstrip("0").rstrip(".") or "0"  # keep small weights like 0.003
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, list):
        return "{" + ",".join(lua_val(x) for x in v) + "}"
    if isinstance(v, dict):
        parts = []
        for k, x in v.items():
            if x is None:
                continue
            key = k if isinstance(k, str) and _IDENT.match(k) else f"[{lua_val(k)}]"
            parts.append(f"{key}={lua_val(x)}")
        return "{" + ",".join(parts) + "}"
    if v is None:
        return "nil"
    raise TypeError(f"Cannot serialize {type(v)}")


API_HEADER = [
    "-- GearGuide item database. GENERATED by GearGuideTools/update_db.py. Do not edit by hand.",
    "-- Data source: Blizzard Battle.net Game Data API. Not affiliated with or endorsed by Blizzard.",
    "-- API terms require a 30-day maximum data lifetime: the addon ignores this file after 30 days;",
    "-- re-run the updater to refresh it. Do not redistribute this file; each user generates their own.",
]


DB_FORMAT = 2  # 2 = item.src holds indices into GearGuide_Data.sources


def intern_sources(items: dict[int, dict]) -> list[dict]:
    """Stores each distinct source once; item["src"] becomes a list of 1-based indices."""
    pool: list[dict] = []
    index: dict[tuple, int] = {}
    for iid in sorted(items):
        refs = []
        for s in items[iid].get("src") or []:
            if not isinstance(s, dict):
                continue
            key = (s.get("t"), s.get("n"), s.get("z"))
            if key not in index:
                pool.append({k: v for k, v in zip(("t", "n", "z"), key) if v})
                index[key] = len(pool)
            if index[key] not in refs:
                refs.append(index[key])
        if refs:
            items[iid]["src"] = refs
        else:
            items[iid].pop("src", None)
    return pool


def write_lua(out: Path, items: dict[int, dict], meta: dict, header: list[str] | None = None) -> None:
    items = {iid: dict(rec) for iid, rec in items.items()}  # don't mutate the caller's records
    pool = intern_sources(items)
    meta = {**meta, "format": DB_FORMAT}
    lines = list(header or API_HEADER) + [
        f"GearGuide_Data = {{ meta = {lua_val(meta)}, items = {{}}, sources = {{}} }}",
        "local S = GearGuide_Data.sources",
    ]
    lines += [f"S[{i}]={lua_val(s)}" for i, s in enumerate(pool, 1)]
    lines.append("local I = GearGuide_Data.items")
    lines += [f"I[{iid}]={lua_val(items[iid])}" for iid in sorted(items)]
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".lua.tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    tmp.replace(out)


# ---------------------------------------------------------------- main
def main() -> int:
    p = argparse.ArgumentParser(description="Build GearGuide/Data.lua from the Blizzard Game Data API.")
    p.add_argument("--region", default="us", choices=["us", "eu", "kr", "tw"])
    p.add_argument("--locale", default="en_US")
    p.add_argument("--namespace", help="e.g. static-classic1x-eu (default: auto-detect)")
    p.add_argument("--max-level", type=int, default=60)
    p.add_argument("--out", type=Path, default=DEFAULT_OUT)
    p.add_argument("--refresh", action="store_true", help="ignore the on-disk cache")
    p.add_argument("--skip-journal", action="store_true")
    p.add_argument("--limit", type=int, help="only fetch details for the first N items (testing)")
    p.add_argument("--list-namespaces", action="store_true")
    args = p.parse_args()

    client_id = os.environ.get("BLIZZARD_CLIENT_ID")
    client_secret = os.environ.get("BLIZZARD_CLIENT_SECRET")
    if not client_id or not client_secret:
        print("Set BLIZZARD_CLIENT_ID and BLIZZARD_CLIENT_SECRET first.\n"
              "Create a free client at https://develop.battle.net/access/clients", file=sys.stderr)
        return 2

    removed = prune_cache()
    if removed:
        print(f"Deleted {removed} cached responses older than 30 days (API terms data TTL).")

    api = Api(args.region, args.locale, client_id, client_secret)
    try:
        print("Detecting namespace...")
        namespace = pick_namespace(api, args.region, args.namespace)
        print(f"  using {namespace}")
        if args.list_namespaces:
            return 0

        print("Searching gear...")
        summaries = search_gear(api, namespace, args.max_level)
        ids = sorted(summaries)[: args.limit] if args.limit else sorted(summaries)

        print(f"Fetching details for {len(ids)} items (cached ones are free)...")
        items: dict[int, dict] = {}
        for n, iid in enumerate(ids, 1):
            detail = api.cached(namespace, "item", iid, f"/data/wow/item/{iid}", args.refresh)
            items[iid] = build_record(summaries[iid], detail, args.locale)
            if n % 500 == 0:
                print(f"  {n}/{len(ids)}")

        sources: dict[int, list] = {}
        if not args.skip_journal:
            print("Reading Adventure Guide sources...")
            sources = journal_sources(api, namespace, args.refresh, args.locale)
        for iid, src in sources.items():
            if iid in items:
                items[iid]["src"] = src
        fixed = apply_corrections(items)
        if fixed:
            print(f"Applied {fixed} corrections from {CORRECTIONS.name}")

        now = datetime.now(timezone.utc)
        meta = {"generated": now.strftime("%Y-%m-%d"), "ts": int(now.timestamp()),
                "namespace": namespace, "count": len(items),
                "source": "Blizzard Battle.net Game Data API"}
        write_lua(args.out, items, meta)
        print(f"Wrote {len(items)} items to {args.out} ({api.requests} API requests).")
        return 0
    except ApiError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
