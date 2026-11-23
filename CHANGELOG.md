# Changelog

## 0.18.0 (2026-11-22)

- Realm-wide source sharing: GearGuide users on the same realm now share the item sources they find (which creature, quest or vendor gives an item) even without being in the same guild or group, through a hidden chat channel. Nothing shows in chat. Only the item, the source's name and the zone are sent, never your inventory, gear, level, gold or name. GearGuide tells you once in chat; the Sharing button (or /gg sharing off) turns it off and leaves the channel.
- Releases only add a shared source after three players reported it (was two).
- Gear Browser > "Additional drops": list mounts (81), toys and recipes (1,612) too, each with its own toggle (all off by default), with where they drop, are sold or rewarded. With a toggle on, their sources also show on the game's item tooltips and on creature tooltips. From Questie's and cmangos' databases; mounts, toys and recipes you loot or see at a vendor are learned in game too. Toys are only listed once the game confirms them as toys.
- Vendor tooltips: hovering a vendor lists the gear it sells that your class can use (upgrades first), plus its mounts, toys and recipes when those are turned on.
- Crafted items: the source names where the recipe comes from ("recipe: Vendor: ... ") and clicking it shows that place on the map.
- 1,094 more items: gear Questie knows a source for that GearGuide's item scan had missed (including Quel'Serrar and the Blackblade of Shahram). They show once the game confirms each one (in the background after login).
- Tooltips inside dungeons: creature, vendor and item tooltips now work when the dungeon hides unit or item details from addons (the tooltip's own text and the item ID stand in).
- WoW: Forever's reputation vendors: opening a quartermaster now records which reputation each item needs ("Requires Nightclaw Druids - Revered", read from the item) and where the quartermaster stands, so the item shows its reputation requirement and the vendor gets a map pin. Both are shared through releases.
- Dungeon loot is recorded again: inside dungeons the game often hides which creature dropped an item, and GearGuide then skipped it. Now a creature's name seen once (targeted, moused over or on a nameplate) names the loot of every creature of that kind, and loot whose creature can't be named is credited to the dungeon itself ("Drop: Krol'dok Stronghold (creature unknown)"), so it is listed with the dungeon in the Gear Browser and shared.
- Party loot inside dungeons: items up for a roll and items other players loot ("... receives loot") are recorded too, even if you never see them in a loot window.
- Quieter source sharing: only sources nobody has confirmed yet are shared (not those already in GearGuide's database, world drops, or sources three players already reported). The realm channel sends at most one message a minute, no longer repeats your older finds at login, sends your version at most once a day, and never answers older versions (guild and group still do). Copies that send faster than that on the channel are ignored.
- Lighter on your game: the recommendation list is worked out once per change (gear, level, spec, settings, new sources) instead of up to five times, creature tooltips remember a creature's drops instead of searching again on every redraw, reading the quest log no longer makes GearGuide look over the whole UI every two seconds while questing, the mini tracker no longer re-checks the zone each time you walk in or out of a building, map pins and routes stop redrawing when nothing changed and while the map is closed, bag badges redraw once after a gear set swap instead of once per slot, and the Gear Browser's dungeon and zone lists are only rebuilt when new sources arrive. Also: item source lists are worked out once per item instead of on every list row and tooltip, the Build Simulator's item list no longer rescans the whole database whenever item info arrives, loot windows are read once (not twice), profession windows are read once things settle instead of on every craft, the party inspect timer only runs in a party, the mini tracker's mouse-over check only runs in hover mode, lists redraw once per update instead of two or three times, and vendor prices are kept for at most 8 vendors per item.
- The main window shows GearGuide's version in its bottom-left corner.

## 0.17.3 (2026-11-21)

- Reputation gear: items that need a reputation ("Requires Honored with Timbermaw Hold") say so in the item details, with your standing and how much reputation is still to go, and item tooltips show "2,400 reputation to Honored with ..." until you reach it (179 items, from the cmangos item data).
- Upgrades on level up: when you level up, GearGuide lists in chat the gear in your bags and bank that you can wear now and that beats what you have on. The bank is remembered each time you open it. Can be turned off in Settings > General > In the game.
- Import Pawn scales: Settings > Stat Weights > "Import Pawn scale..." takes a Pawn scale string and uses it as your custom stat weights. Rating stats (CritRating, HitRating...) are converted to GearGuide's per 1% values; stats GearGuide doesn't score are listed.
- New window header: the GearGuide logo and a gold GEARGUIDE wordmark in spaced capitals, then your class (in its class color), spec and role on one line ("Rogue Assassination ◆ Melee DPS"). The level range is no longer shown there. On a narrow window the spec name is shortened and the role left out.
- Tabs: the tab names are bold, and the Settings tab sits on the right side of the window, apart from the gear tabs.
- Settings > General > Appearance: pick your own colors with the game's color picker (accent, background, title bar, text, dim text, border). Each one replaces only that color of the chosen theme and stays when you switch themes; "Theme" next to it, or "Use the theme's colors", goes back. The window border has a size setting (1 to 6) and its own color, next to the style (solid line, tooltip, dialog or none). Your old thin/thick border and accent color carry over.
- Settings > General > Appearance: colorblind-friendly upgrade colors (blue for better, orange for worse, instead of green and red) and a text size setting (85% to 125%).
- Scroll bars can be clicked and dragged: dropdown menus, the item details, the settings pages and the mini tracker. Clicking the bar jumps there; the bar widens while the mouse is over it.
- Item sources updated from QuestieDB 1.1.3: 402 new sources.
- Smaller database in memory: map locations and random bonus tables are stored packed and unpacked only when a map or item details open (about 1.4 MB less).

## 0.17.2 (2026-11-20)

- Gear browser dungeon menu: all nine of WoW Forever's new dungeons are listed (The Hall of Thanes, Ruins of Lordaeron, Excavation Site: Wetlands, City of Dalaran, The Drowned City, Krol'dok Stronghold, Alcaz Prison, Blackmaw Hold, Shaper's Terrace), sorted by level among the others. Those whose loot isn't known yet show their level range, and what you loot inside them is recorded and listed there. Any other dungeon you loot in joins the menu too. World drops that a dungeon's creatures also carry (random greens, Black Malice, Ragehammer...) are no longer listed as that dungeon's loot.
- BoE world drops: every creature that can drop one now shows it on its tooltip (about 2,700 items from 3,600 creatures, from the cmangos loot tables), listed after the creature's own loot. An item's sources show one "World drop: any of N creatures (level X-Y)" line instead of a list cut off at 25, and about 1,000 world drops that had no known source before can now be recommended. Looting one from any of its creatures no longer announces a "new drop location". The mini tracker's zone list includes them too ("World drop", listed with random chest loot after the zone's own sources) when creatures of the zone can drop them.
- Settings > General > Creature tooltips: turn the drop list on or off, choose which drops it shows (upgrades and favorites, gear your class can use, or all gear), the lowest quality, the item level bracket (your recommendation range, any level, or 1-10 to 51-60), and whether BoE world drops are included. Favorites always show. World drops get their own "BoE world drops" header with their shared chance shown once.
- Gear browser zone filter: pick any outdoor zone of the world map (WoW Forever's new zones included, grouped by continent, with their levels) to list the gear its creatures and chests drop, its vendors sell and its quests reward, at every level. Dungeons and raids stay in the dungeon menu; rare world drops are left out. A zone only known from loot joins the list under "Other".
- Settings > General > Appearance: a color theme (Copper, Slate blue, Forest green, Crimson, Violet, Graphite and gold), your own accent color from the game's color picker, and the window border (thin line, thick line, none, tooltip or dialog border) for the main window and the mini tracker.

## 0.17.1 (2026-11-18)

- Share builds: "Share this set..." in the Build menu gives a short text to copy and send; "Import a build..." takes one and saves it as a new build.
- Inspect in GearGuide: a button on the game's Inspect window (or /gg inspect on your target) opens that player's gear in the Build Simulator, saved as "Name's gear".
- Loot roll help: on group loot rolls, the roll shows what the item is worth to you, and a chat line (only you see it) tells you who in your party it's an upgrade for. Party members don't need GearGuide: their gear is read with the game's Inspect while they're near you. Can be turned off in Settings.
- Upgrade numbers: item icons in your bags, the bank, merchants, loot and quest rewards show how the item compares to what you wear: how much better in green, how much worse in red. Item tooltips show it too. Works with Bagnon and other bag addons, and quest rewards get it in any quest window (the game's own, DialogueUI and others). Can be turned off in Settings.
- Settings are tidier: three tabs, General (incl. tooltips, item icons and loot), Tracker & Pop-up, and Stat Weights. Custom stat weights have their own tab, laid out in two columns; picking "Custom" in the Spec menu opens it. Settings reopens on the tab you used last.
- Random bonus fix ("of the Eagle", "of the Bandit"...): the bonus stats of items you wear or are offered are now counted. The game only reports the base item's stats, so before, a Cabalist Belt of the Eagle (Stamina, Intellect) could show as an upgrade for a rogue wearing a Sentinel Girdle of the Bandit (Agility, Attack Power). Any item could look better than such a belt: a Kurzen Headshrinker's Cinch (Stamina, spell power) showed +2.8. Upgrade numbers, loot roll help, the Build Simulator and the item details' random variants now read the bonus from the item's tooltip. (WoW: Forever links random bonuses differently from the original game, which hid them from GearGuide; the same fix makes looting a random bonus item remember its bonus again, and its game tooltip line show up.)
- Protection Paladin weights follow the November 17 hotfix: Blizzard is moving Paladin tanks to Spell Power for their damage (the Soulforge Armor tank set now has Spell Power instead of Strength), so Spell Power now counts as much as Stamina and Strength much less, while leveling too.
- Enhancement Shaman weights follow the November 10 hotfix: Intellect turns into less Attack Power and Maelstrom Weapon procs less often, so Intellect and Spell Power count less, and Strength and weapon damage lead.
- Hunters no longer get thrown weapons suggested: Auto Shot and hunter shots still need a bow, gun or crossbow.
- Gloves of Holy Might now show their source: Ghostmaw, a rare elite in Riverglades, with its location on the map.

## 0.17.0 (2026-11-16)

- New "Build Simulator" tab: try on any gear and see your character sheet with it. It looks like the game's character window: your character wears the simulated set (drag to turn, mouse wheel to zoom), and the stats panel shows what your attributes, health, mana, armor, attack power, weapon damage, crit, hit, dodge, parry, block and resistances would be. Click a slot to pick an item for it (best for your spec first, with the change in score), right-click a slot to empty it. "Reset to equipped" and "Clear all" start over. Your set is kept per character.
- "Where to get this set": under the character window, the simulated items you don't have yet, grouped by where they come from (dungeon, raid, zone, crafted...), each with its best source and drop chance. Click one to show it on the map; items you get drop off the list.
- Saved builds: keep up to 20 named sets per character. Pick "New build..." in the Build menu under the character window to save the current set, pick a build to load it, Save to update it, Delete (click twice) to remove it. A * shows the set changed since it was saved.
- Build Simulator item list: search by name, a level range (empty means up to your level, so it follows you as you level; type a higher level to plan ahead), and "Empty this slot".
- "Recommended build" button: fills every slot with the best item you can wear at your level, following your spec's weapon setup and best armor type. From level 50 the whole set is tuned together: hit, expertise and defense only count up to their caps (raid bosses at 60, same-level enemies before), your talents included, so the set doesn't waste stats past a cap.
- Gear browser: new dungeon and raid menu next to the slot menu. Pick an instance to list its loot (bosses, trash and chests, without rare world drops) at every level; each row names the boss that drops it. Dungeons are sorted by level and show the usual level of their loot.
- Scoring fix: hit, crit, dodge, parry, block, haste and expertise on items are ratings (10 hit rating is 1% hit, 14 crit rating is 1% crit), but they were scored as if each point were 1%. Items with these stats were valued far too high; recommendations and the gear browser now convert them using the game's own conversion.
- Fix: borders of menus, input boxes and buttons no longer lose an edge at UI scales below 100%.
- The window's tabs are easier to read. After an update, new features get a small "NEW" badge until you first use them (once, never again).
- Item sources: drops that don't line up with WoW Forever's current data are no longer shown. The level 30 copies of Molten Core rings, the Choker of the Fire Lord and Earthshaker were listed as drops from starting-zone creatures (Stonetusk Boar, Murloc...), and a few items from rare creatures came from an older version of the game. Drops with a known drop chance, and drops players have looted in game, still show.
- "Ignore" button in the item details: an ignored item is never recommended again, not on the Recommended tab, in the mini tracker, the zone list, the Gear Acquired pop-up, creature tooltips or the Build Simulator's recommended build. It still shows in the gear browser, marked "(ignored)". Click "Unignore" to undo, or clear the whole list in Settings > Recommendations. Ignoring a favorite removes it from your favorites (and favoriting an ignored item un-ignores it). Kept per character.
- Raid gear is no longer recommended before level 60, including WoW Forever's level 30 copies of Molten Core items (Quick Strike Ring, Choker of the Fire Lord...). Favorites still show.

## 0.16.2 (2026-11-15)

- Random bonus items (e.g. Cross Dagger "of the Falcon" or "of the Monkey"): looting one now counts as a drop of the base item, so the creature and its map location are recorded there. The item details have a new "Random variants" section with every possible bonus, its stats, its score for your spec and how often it drops, best for you first (1,671 items).
- Game tooltips of a random bonus item now show which item it's a variant of and how often that bonus drops.
- Gear browser: searching for an item's full name with its bonus (e.g. "Cross Dagger of the Falcon") now finds the base item.
- Loot fix: drops are now recorded with auto loot on. Before, auto loot could empty the loot window before GearGuide read it, and the drop was lost.
- World map fix: clearing GearGuide's pins no longer removes your own map waypoint.
- Tooltip fix: item tooltips in the GearGuide window no longer jump when the item finishes loading.
- Removed item sources without a usable name ("Unknown", "Container" or empty). Creature tooltips now list the same sources as the item details.
- Smaller fixes: scores from custom stat weights are labeled "Custom", the Gear Acquired preview in Settings no longer replaces a real pop-up, and /gg forget also clears shared sources and learned variants.
- Cross Dagger: added Nightbane Dark Runner (Duskwood) as a source.

## 0.16.1 (2026-11-15)

- "New drop location discovered for [item]": when you loot gear from a creature that isn't listed as a source for it yet, a message shows on screen and in chat (with the item link). Can be turned off in Settings > General.
- World drops (items that can drop from any creature of the right level, e.g. Feet of the Lynx) now keep the creatures players find them on. Before, these were hidden because the database only lists a few chests for them.
- Drops found by players now get the creature's map location when the database knows where it spawns.
- Gear browser: searching by name now finds items outside the level range (class, slot and quality filters still apply).
- Feet of the Lynx: added Skeletal Horror (Duskwood) as a source.
- 927 new item sources from player discoveries.

## 0.16.0 (2026-11-15)

- Custom stat weights: pick "Custom" in the Spec menu (window header) to score gear with your own value for every stat. Settings has the editor: one box per stat (decimal commas like 0,5 work; empty or 0 ignores the stat, negative values mark stats you'd rather avoid), the spec it's based on (decides your role and how you hold weapons), and a button to reset to that spec's researched values. Your first switch copies your current spec's weights; your values are kept per character.
- "Gear Acquired" pop-up: when an item GearGuide currently recommends for you, or one you favorited, lands in your bags, a pop-up shows it for a few seconds. Hover to keep it open, left-click to open the item, right-click to dismiss. Gear you already had (at login, in your bank) doesn't trigger it.
- The pop-up can be moved (drag it) and made wider or narrower (drag its corner). Settings has a new section to turn it off, lock its position and size, scale it, show a preview to place it with, and reset its position.
- 919 new item sources from player discoveries.

## 0.15.2 (2026-11-15)

- Opening a source on the map no longer also places the game's own map pin and waypoint arrow: GearGuide's shaded areas and pins show where to go. You can turn the game's waypoint back on in Settings ("Set a waypoint arrow").

## 0.15.1 (2026-11-15)

- World map fix: shaded areas and outlines were still hidden behind the map's own layers. They are now placed above everything the map draws, with GearGuide's pins on top.

## 0.15.0 (2026-11-15)

- World map fix: area outlines (and roaming routes) were drawn underneath the map, so only pins showed. They are now drawn on top of the map, below the pins.
- Creatures without a known location (mostly WoW: Forever's own creatures, e.g. Nar'gurk) are now placed on the map once you loot one or target one up close, and get their zone name. In dungeons the dungeon's name is shown. Future GearGuide updates will include these locations for everyone.

## 0.14.1 (2026-11-15)

- World map: chests now also show the areas where they can be found (shaded and outlined, one pin in the middle) instead of a pin on every spawn. Chests of the same kind are combined, so the areas cover all of them.
- Very spread-out spawns no longer turn into one huge area covering most of a zone: those are split into smaller areas or stay as pins.

## 0.14.0 (2026-11-15)

- Raid loot: 481 raid and world boss items that were missing from the database are now included, e.g. Perdition's Blade and Bonereaver's Edge (Ragnaros), with their drop chances. Only loot that drops exclusively in raids or from world bosses was added, listed only under those bosses and creatures.
- These items appear once your game client confirms them: GearGuide asks the client in the background and uses its own item data (WoW: Forever's real stats). Items the client doesn't know never show up.
- Removed a few wrong drop sources where a creature far below an item's level was listed as dropping it (e.g. a level 57 epic "dropped" by a level 16 creature).

## 0.13.0 (2026-11-15)

- Creature tooltips: mouse over a creature to see which of your recommended and favorite items it drops, with the drop chance and the score gain over what you have equipped (favorites are marked with a star). Can be turned off in Settings.
- World map: creatures that spawn in groups now have the whole area they live in shaded and outlined, with one pin in the middle, instead of a pin on every spawn.
- Update notice: when a guild or group member uses a newer GearGuide, you get a one-time message in chat (and a note in the window footer) telling you to update. Works from this version on, and only with source sharing turned on.

## 0.12.1 (2026-11-14)

- Fixed raid gear showing up as a drop from low level creatures (e.g. Molten Core rings "dropped" by a Stonetusk Boar in Elwynn Forest). Loot from a bag or other container was credited to whatever dead creature you had targeted, and then shared with other GearGuide users. GearGuide now only learns loot from the creature it really came from, ignores gear far above that creature's level, and hides such wrong entries already learned or shared.

## 0.12.0 (2026-11-14)

- Drop chances: creature and chest drops now show how likely the item is to drop (e.g. "Drop: Ragnaros 20%") in item tooltips, the item details and the mini tracker. The creatures with the best chance are listed first.
- 359 more items now show where they drop, mostly boss and named-creature loot (e.g. Choker of the Fire Lord, Battleguard Sartura's drops).
- Drop chances come from the cmangos classic-db project and are based on the original game; WoW: Forever's own rates may differ slightly.

## 0.11.4 (2026-11-14)

- Main window item tooltips no longer jump around: they open right of and below the cursor (left or
  above only when there's no room on screen) and stay put while you move along the row.

## 0.11.3 (2026-11-14)

- Items without a known source now say "Not discovered yet"; the footer button is now
  "Undiscovered: Shown/Hidden".
- Removed developer instructions ("run update_db.py") from player-facing text, and the
  "older game build" note from the window footer.

## 0.11.2 (2026-11-14)

- Item tooltips in the main window open beside the mouse cursor, on the side with more room, and
  follow it along the row (they used to appear wherever the last tooltip had been).

## 0.11.1 (2026-11-13)

- Mini tracker hover mode (and 0% background opacity) now also hides the frame's border.

## 0.11.0 (2026-11-13)

- Mini tracker scale (60-160%) in Settings or `/gg mini scale 60-160`; its top-left corner stays put.
- Mini tracker hover mode (Settings, the tracker's options menu, or `/gg mini hover`): the header and
  background fade out so only the item list shows, and come back while the mouse is over the tracker,
  its menu is open, or the main window is open.
- Item tooltips beside a scaled mini tracker are placed correctly.

## 0.10.0 (2026-11-13)

- New Settings tab in the main window (also `/gg settings`): minimap icon, source sharing, unknown
  sources, recommendation level range, lowest recommended quality, mini tracker (shown, rows, background
  opacity, hide acquired, auto-open, hide in battlegrounds/arenas), main window scale, and world map
  patrol routes and waypoint arrow.
- Mini tracker header: the open-window, hide-acquired, auto-open and opacity buttons are now one
  options menu, leaving more room for the zone name.

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

