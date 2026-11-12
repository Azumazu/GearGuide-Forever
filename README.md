# GearGuide

A free, open-source gear planner addon for World of Warcraft: Forever. It recommends the best gear
for your class and level range, shows where to get it, tracks what you've acquired, and has a
gear browser for every class.

## Install
Copy the `GearGuide` folder into your Forever client's `Interface/AddOns/` folder.

- `/gg` or the minimap icon (left-click) opens the window on **Recommended**
- Minimap right-click or `/gg browse` opens the **Gear Browser** (any class, slot, level, quality)
- Shift-click the minimap icon or `/gg mini [count]` toggles the **mini tracker** (top 1-20 picks)
- Spec: picked automatically from your talents, or choose it in the window's Spec dropdown / `/gg spec <name>`
- Other commands: `/gg range <below> <above>`, `/gg minimap`, `/gg status`, `/gg unmark` (clear acquired
  marks), `/gg forget` (clear learned items), `/gg scan` (see below)

## Item data (no other addon or web service required)
1. **Scan the game client:** `/gg scan` reads every gear item from the client's own item table in the
   background (about 10 server requests per second, pauses in combat, resumes after a reload).
   `/gg scan status`, `/gg scan pause`, `/gg scan reset`. Scanned items are used immediately.
2. **Sources are learned while you play:** loot (with the creature's name), quest rewards (including
   every quest in your quest log), vendors and profession windows.
3. **Bake it into the shipped database:** log out, then run
   ```powershell
   python GearGuideTools/build_db.py --wow "E:/World of Warcraft/_forever_"
   ```
   This writes `GearGuide/Data.lua` from your scan plus learned sources. If QuestieDB is installed
   in that game folder, its Forever database also supplies drop, chest, vendor and quest-reward sources
   (build time only; players don't need Questie). Each source is stored once
   and items refer to it by number. Hand-written fixes in `GearGuideTools/corrections.json` are applied last.
4. **Optional:** `GearGuideTools/update_db.py` builds Data.lua from the Blizzard Battle.net API instead
   (needs a free API client; see below).

## Stat weights
Each of the 28 specs has researched weights in `GearGuideTools/spec_weights/<CLASS>.json`
(stat priority, value per point or per 1%, leveling adjustments below 60, caps, confidence, sources).
They were cross-checked from WoW: Forever guides (Icy Veins, wow.gg, Warcraft Tavern, Mobalytics)
in November 2026, most marked preliminary. After a balance patch, edit the JSON and run
`python GearGuideTools/gen_spec_weights.py` to regenerate `GearGuide/SpecWeights.lua`.
Forever's new stats are included: Haste, Expertise, and unified hit/crit. Hunters' ranged weapons
use a separate `RDPS` weight.

## Releasing (maintainers)
Players get a database that ships with the addon; they never need to scan. Per game patch:
1. `/gg dev` once enables maintainer mode: after a patch you're reminded to rescan.
2. In game: `/gg scan`, let it finish, then `/reload` or log out so WoW saves it.
3. `python GearGuideTools/release.py --wow "E:/World of Warcraft/_forever_" --dry-run` shows what the
   patch changed (items added, removed, changed). Without `--dry-run` it writes the new `Data.lua`,
   bumps the version, adds a CHANGELOG.md entry and builds `releases/GearGuide-<version>.zip`.
   No item changes means no release (`--sources` also releases newly learned sources).
4. Commit and push the version tag (release.py prints the exact commands). GitHub Actions
   (`.github/workflows/release.yml`) checks the tag matches the TOC version, packages the addon,
   uploads it to CurseForge and attaches the zip to a GitHub release. CurseForge app users get it
   automatically.

### One-time publishing setup
1. CurseForge: create the project (World of Warcraft, license GPL-3.0) and an API token in your author settings.
2. GitHub: create a repository and push this folder (`git remote add origin <url>`, `git push -u origin main`).
3. Repository settings: secret `CF_API_TOKEN` = the token; variable `CF_PROJECT_ID` = the project's numeric ID.
4. Check the game version mapping once: `CF_API_TOKEN=... python GearGuideTools/upload_curseforge.py --list-versions`
   (the TOC's Interface 16001 maps to "1.60.1"; use `--game-version-id` if CurseForge names Forever differently).

Players on a newer game build than the shipped database get a one-time note that an update may follow.

**When Questie updates** (your CurseForge app updates QuestieDB in the game folder), just run
`release.py` again; no rescan is needed. The shipped `Data.lua` records which QuestieDB version
its sources came from. If the new version changed sources for any of our items (added, fixed or
removed), a release is made automatically, with "Item sources updated from QuestieDB <version>" in
the changelog. A Questie update that doesn't touch our items releases nothing.

### Blizzard Developer API terms (only if you use update_db.py)
- **30-day data lifetime.** API data may be kept at most 30 days. The updater deletes cached
  responses older than that, and the addon ignores an API-built `Data.lua` older than 30 days.
  (Databases built from your own client scan with build_db.py don't expire.)
- **Rate limit.** The updater stays under 36,000 calls per hour and pauses if it gets close.
- **Attribution.** Item data is identified in the addon as coming from the Blizzard Battle.net API.
  GearGuide is not affiliated with or endorsed by Blizzard Entertainment.
- **Distribution.** If you publish GearGuide, do not ship your generated `Data.lua`. Ship the
  placeholder; each user generates their own data with their own API client.

Wowhead or other sites are not scraped. Their terms, and Blizzard's, forbid it.

## Source sharing (in game)
GearGuide users in the same guild or group share item sources they discover (which creature,
quest, vendor or profession gives an item) through invisible addon messages: nothing appears in
chat. Only item IDs, source type, the creature/quest/vendor name and zone are sent; no character
data. Messages are batched (at most one every 10 seconds), only for first-time discoveries, and
paused in combat and instances. Received sources show in tooltips as "(shared by players)".
Releases only include shared sources that two or more different players reported.
**Opt out** with the "Sharing" button at the bottom of the window or `/gg sharing off`; that stops
both sending and receiving.

## Privacy
GearGuide collects no personal data. Apart from the optional in-game source sharing above (item and source names only), it sends nothing anywhere. Everything it stores stays on
your computer in WoW's SavedVariables: settings, items learned in game, and which items your
character has owned. Item data from the Blizzard API is game data provided "as is", and is used
only to show gear information to you.

## Compliance with Blizzard's UI Add-On Development Policy
Free of charge, fully readable source code, no advertising, no donation requests, no automation
(it never casts, equips, loots, buys, sells or sends chat messages), and no protected function calls.

## License and credits
GearGuide is free software under the GNU General Public License v3.0 or later (see `LICENSE`).

Item sources (NPC drops, chests, vendors, quest rewards) are imported at build time from the
[Questie](https://github.com/Questie/Questie) project's Forever database (QuestieDB, GPL-3.0;
data by Muehe, TheCrux (BreakBB), Drejjmit, Dyaxler, Cheeq, TechnoHunter, Yttrium and contributors).
GearGuide doesn't use Questie's code and doesn't need Questie installed.
