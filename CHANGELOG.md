# Changelog

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

