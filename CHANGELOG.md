# Changelog

## 0.9.0 (2026-11-13)

- Mini tracker background opacity: new header button (click: more transparent, right-click: less,
  mouse wheel: 5% steps) or `/gg mini opacity 0-100`. Text and icons stay fully visible; saved
  between sessions.

## 0.8.1 (2026-11-13)

- Honor vendor prices: PvP rank gear no longer shows the old vanilla gold price (WoW: Forever sells it
  for Honor). Opening an honor vendor records the real cost (Honor Points, battleground marks and any
  gold), and it then shows on every honor vendor for that item. Until then the source says "Honor".
- Fixed: on clients that report Honor/Arena Points separately, those were left out of recorded prices.

## 0.8.0 (2026-11-13)

- Patrolling rare mobs: their route is drawn on the world map like roaming vendors' (Ghost Howl,
  Narillasanz, Mazzranache and about 50 more). Rare drops are marked "(rare)" in source lists.

## 0.7.0 (2026-11-13)

- Roaming vendors: clicking a vendor that walks around (Antonio Perelli, Zixil, Lizzarik, ...) draws
  its route on the world map. Routes that cross zones show on each zone's map (click again for the next).

## 0.6.0 (2026-11-13)

Item sources refreshed (11227 gear items, client build 70888).
- Vendor prices for 926 items (cmangos classic-db; prices seen in game take priority)

## 0.5.1 (2026-11-13)

Item sources refreshed (11227 gear items, client build 70888).
- Item sources updated from QuestieDB 1.0.16 (2023-11-14, a444a64) (1354 items changed)
- 3373 new item sources

## 0.5.0 (2026-11-12)

- Vendor prices: "Where to get it" shows what a vendor charges for an item, in gold and every
  other currency or token it costs (e.g. "Vendor: Gerard Abernathy (Westfall) - 1g 23s 45c").
  Prices are learned when you open a vendor and will ship with future database updates
- Fix: a vendor or quest giver could be listed twice (once from the database, once learned in game)

## 0.4.9 (2026-11-12)

- Assassination rogues from level 40 are only recommended daggers for main and off hand
  (ranged slot unchanged; other rogue specs still see every weapon type)

## 0.4.8 (2026-11-12)

- The mini tracker scrolls: the +/- buttons set how many rows it shows, and the mouse wheel
  scrolls through the rest of the list (up to 60 items). A thin bar on the right shows where you are
- Common (white) items are no longer recommended; favorites still show. The Gear Browser now
  starts at Uncommon+ (pick Common+ or Any quality in its quality filter to see them)

## 0.4.7 (2026-11-12)

- The mini tracker hides itself in battlegrounds and arenas and comes back when you leave
  (if you had it open). You can still open it mid-match; it stays open until your next entry
- No zone view or auto-popup inside battlegrounds and arenas

## 0.4.6 (2026-11-12)

Item database rebuilt from client build 70888: 11227 gear items.
- Hidden: the Super Hogger event items (Thunderfury, Sulfuras, Rhok'delar, Band of Sulfuras), also
  when your own /gg scan contains them
- Items with an unknown source are now hidden from recommendations, the browser and the mini
  tracker. Show them with the "Unknown sources" button in the window footer or /gg unknown.
  Favorites always show

## 0.4.5 (2026-11-12)

- Fix: the item tooltip on the mini tracker opened on top of the tracker when it sat near the
  left screen edge; it now opens beside the tracker, on whichever side has room

## 0.4.4 (2026-11-12)

Item database rebuilt from client build 70888: 11231 gear items.
- Removed 116 developer test items (AHNQIRAJ TEST ITEM, "(Test)" gear, QATest rings, ...); they are
  also hidden if your own /gg scan picked them up
- Fix: new characters were recommended high-level gear. Items without a level requirement (many
  quest rewards and WoW: Forever drops) now count at their item level - 5, like every other item
- Fix: items worth nothing to your spec (score 0, e.g. stat-less relics) are no longer recommended

## 0.4.3 (2026-11-12)

Item sources refreshed (11347 gear items, client build 70888).
- 14 new item sources
- Mini tracker zone view: in a zone or instance with drops that are upgrades for you (or favorites),
  the mini tracker lists those items and who drops them; Ctrl-click a row to see the spot on the map
- New mini setting (map button in its header, or /gg mini auto): auto-open the mini tracker when you
  enter such a zone, and close it again when you leave (only if it opened itself)
- Fixed an error flood from protected unit values when hovering mobs
- Larger, less crowded buttons; EllesmereUI-style window backdrop with see-through rows
- Crafted "Pattern" items now name the right profession (Tailoring or Leatherworking)

## 0.4.2 (2026-11-12)

Item sources refreshed (11347 gear items, client build 70888).
- 4278 new item sources
- Faction aware: Alliance-only and Horde-only items (faction quest rewards, city vendors, PvP rank
  gear) are hidden for the other faction, and the other faction's sources are left out of the list

## 0.4.1 (2026-11-12)

Item sources refreshed (11347 gear items, client build 70888).
- Sources for 1274 more items: crafted gear (with the profession and where to get the recipe),
  PvP rank rewards and starting equipment
- Recommendations only show gear your spec should use: the best armor type for your class and
  level, and only stats your spec values (no Intellect robes for rogues, no Strength rings for mages)
- Weapons follow your spec's setup: dual wielders get one-handers in the off hand, shield and caster
  specs get shields / off-hand items, two-hander specs get no off-hand section

## 0.4.0 (2026-11-12)

Item sources refreshed (11347 gear items, client build 70888).
- 19015 new item sources
- Where to get it: every creature, vendor, quest giver and chest is listed; click one to open the
  world map at its location (dungeon bosses show the dungeon entrance; repeat clicks cycle locations)
- Favorites: star items to pin them at the top of Recommended and the mini tracker
- In-game source sharing with guild and group (invisible addon messages), opt out with the
  Sharing button or /gg sharing off
- Researched stat weights for all 28 specs, including Forever's Haste and Expertise

## 0.3.1 (2026-11-12)

Initial item database from client build 70888: 11347 gear items, 6175 with known sources.
- Item sources include QuestieDB 1.0.12 (2023-11-14, 4d31c10)

