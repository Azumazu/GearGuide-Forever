local _, ns = ...

-- Build simulator tab: a character-page lookalike where each slot can hold any item. The model
-- wears the chosen set and the stats panel shows what the character would have with it.
--
-- Stats are worked out from the live character sheet: today's value, minus what the equipped
-- gear gives, plus what the simulated gear gives. Buffs, talents and racials stay in, because they
-- are part of today's value. The chosen set is kept per character (GearGuideCharDB.sim).

local SLOT_LABELS = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest", [6] = "Waist", [7] = "Legs",
    [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Finger", [12] = "Finger", [13] = "Trinket",
    [14] = "Trinket", [15] = "Back", [16] = "Main Hand", [17] = "Off Hand", [18] = "Ranged", [19] = "Tabard",
}
local SLOT_NAMES = {
    [1] = "HEADSLOT", [2] = "NECKSLOT", [3] = "SHOULDERSLOT", [4] = "SHIRTSLOT", [5] = "CHESTSLOT",
    [6] = "WAISTSLOT", [7] = "LEGSSLOT", [8] = "FEETSLOT", [9] = "WRISTSLOT", [10] = "HANDSSLOT",
    [11] = "FINGER0SLOT", [12] = "FINGER1SLOT", [13] = "TRINKET0SLOT", [14] = "TRINKET1SLOT",
    [15] = "BACKSLOT", [16] = "MAINHANDSLOT", [17] = "SECONDARYHANDSLOT", [18] = "RANGEDSLOT", [19] = "TABARDSLOT",
}
-- The character page's order: left column, right column, weapons along the bottom.
local LEFT = { 1, 2, 3, 15, 5, 4, 19, 9 }
local RIGHT = { 10, 6, 7, 8, 11, 12, 13, 14 }
local BOTTOM = { 16, 17, 18 }
local ALL_SLOTS = {}
for _, t in ipairs({ LEFT, RIGHT, BOTTOM }) do
    for _, s in ipairs(t) do ALL_SLOTS[#ALL_SLOTS + 1] = s end
end
ns.SIM_SLOTS = ALL_SLOTS

-- Which equip locations fit a slot. One-handers go in the off hand only for classes that dual wield.
local SLOT_LOCS = {
    [1] = { INVTYPE_HEAD = true }, [2] = { INVTYPE_NECK = true }, [3] = { INVTYPE_SHOULDER = true },
    [4] = { INVTYPE_BODY = true }, [5] = { INVTYPE_CHEST = true, INVTYPE_ROBE = true },
    [6] = { INVTYPE_WAIST = true }, [7] = { INVTYPE_LEGS = true }, [8] = { INVTYPE_FEET = true },
    [9] = { INVTYPE_WRIST = true }, [10] = { INVTYPE_HAND = true }, [11] = { INVTYPE_FINGER = true },
    [12] = { INVTYPE_FINGER = true }, [13] = { INVTYPE_TRINKET = true }, [14] = { INVTYPE_TRINKET = true },
    [15] = { INVTYPE_CLOAK = true }, [16] = { INVTYPE_WEAPON = true, INVTYPE_2HWEAPON = true, INVTYPE_WEAPONMAINHAND = true },
    [17] = { INVTYPE_WEAPON = true, INVTYPE_WEAPONOFFHAND = true, INVTYPE_SHIELD = true, INVTYPE_HOLDABLE = true },
    [18] = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true, INVTYPE_RELIC = true },
    [19] = { INVTYPE_TABARD = true },
}

function ns.SimSlotFits(slot, eq, class)
    local locs = SLOT_LOCS[slot]
    if not (locs and eq and locs[eq]) then return false end
    if slot == 17 and eq == "INVTYPE_WEAPON" then return ns.DUAL_WIELD ~= nil and ns.DUAL_WIELD[class] ~= nil end
    return true
end

---------------------------------------------------------------------------
-- Item data
---------------------------------------------------------------------------
local getItemStats = (C_Item and C_Item.GetItemStats) or GetItemStats
local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local RES_KEYS = { RESISTANCE1_NAME = "R1", RESISTANCE2_NAME = "R2", RESISTANCE3_NAME = "R3",
    RESISTANCE4_NAME = "R4", RESISTANCE5_NAME = "R5", RESISTANCE6_NAME = "R6" }

local function equipLoc(link)
    local id = ns.LinkToId(link)
    local item = id and ns:GetItem(id)
    if item and item.eq then return item.eq end
    if id and getInstant then
        local ok, _, _, _, eq = pcall(getInstant, id)
        if ok then return eq end
    end
end

-- Stats of one item link: the client's (random bonus included) once it has the item, else the
-- database record's. Resistances come from the client only.
local statCache = {}
local function itemStats(link)
    local hit = statCache[link]
    if hit then return hit end
    local st = {}
    local raw = getItemStats and getItemStats(link)
    if raw and next(raw) then
        for k, v in pairs(ns.ReadStats(link)) do st[k] = v end
        for k, v in pairs(raw) do
            local r = RES_KEYS[k]
            if r then st[r] = (st[r] or 0) + v end
        end
        if ns.LinkBonus(link) then  -- a random "of Fire Resistance" bonus: only its tooltip shows it
            for k, v in pairs(ns.TooltipStats(link) or {}) do
                if k:match("^R%d$") and v > (st[k] or 0) then st[k] = v end
            end
        end
        statCache[link] = st
        return st
    end
    local id = ns.LinkToId(link)
    local item = id and ns:GetItem(id)
    for k, v in pairs(item and item.st or {}) do st[k] = v end
    return st
end
ns.SimItemStats = itemStats

-- Weapon damage range and speed from the item's tooltip ("48 - 67 Damage" ... "Speed 2.60").
local weaponCache = {}
local function weaponInfo(link)
    if not link then return nil end
    local c = weaponCache[link]
    if c ~= nil then return c or nil end
    if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
    if not (ok and type(data) == "table" and type(data.lines) == "table") then return nil end
    for _, line in ipairs(data.lines) do
        local l, r = ns.Plain(line.leftText), ns.Plain(line.rightText)
        local lo, hi
        if l then lo, hi = l:match("^(%d+) %- (%d+)") end  -- (`l and l:match()` keeps only `lo`)
        local sp = lo and r and r:match("(%d+[%.,]%d+)")
        if sp then
            local w = { min = tonumber(lo), max = tonumber(hi), speed = tonumber((sp:gsub(",", "."))) }
            weaponCache[link] = w
            return w
        end
    end
    if #data.lines > 1 then weaponCache[link] = false end  -- loaded, and not a weapon
    return nil
end
ns.SimWeaponInfo = weaponInfo

local function sumStats(links)
    local t = {}
    for _, link in pairs(links) do
        if link then
            for k, v in pairs(itemStats(link)) do t[k] = (t[k] or 0) + v end
        end
    end
    return t
end

-- "|cff...|Hitem:2819:0:...|h[Cross Dagger]|h|r" -> "item:2819:0:..." (what the set stores).
local function itemString(link)
    link = ns.Plain(link)
    if type(link) ~= "string" then return nil end
    return link:match("|H(item:[^|]+)|h") or link
end
ns.SimItemString = itemString

-- What the player wears now, as item strings.
function ns:EquippedLinks()
    local out = {}
    for _, slot in ipairs(ALL_SLOTS) do
        local link = itemString(GetInventoryItemLink("player", slot))
        if link then out[slot] = link end
    end
    return out
end

---------------------------------------------------------------------------
-- Stats
---------------------------------------------------------------------------
local function call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local r = { pcall(fn, ...) }
    if r[1] then return unpack(r, 2) end
    return nil
end

-- Today's character sheet.
function ns:LiveStats()
    local L = {}
    L.HEALTH = call(UnitHealthMax, "player")
    local mana = call(UnitPowerMax, "player", 0)
    if mana and mana > 0 then L.MANA = mana end
    for i, k in ipairs({ "STR", "AGI", "STA", "INT", "SPI" }) do
        local _, eff = call(UnitStat, "player", i)
        L[k] = eff
    end
    L.ARMOR = select(2, call(UnitArmor, "player"))
    local b, p, n = call(UnitAttackPower, "player")
    if b then L.AP = b + (p or 0) + (n or 0) end
    b, p, n = call(UnitRangedAttackPower, "player")
    if b then L.RAP = b + (p or 0) + (n or 0) end
    L.CRIT = call(GetCritChance)
    L.RCRIT = call(GetRangedCritChance)
    -- Hit: talents and auras (the modifier) plus what gear rating gives, as the paper doll adds them.
    local function ratingBonus(name, index)
        if type(GetCombatRatingBonus) ~= "function" then return 0 end
        return tonumber(call(GetCombatRatingBonus, _G[name] or index)) or 0
    end
    L.HIT_TALENT = call(GetHitModifier)
    L.SHIT_TALENT = call(GetSpellHitModifier)
    if L.HIT_TALENT then L.HIT = L.HIT_TALENT + ratingBonus("CR_HIT_MELEE", 6) end
    if L.SHIT_TALENT then L.SHIT = L.SHIT_TALENT + ratingBonus("CR_HIT_SPELL", 8) end
    local sp, sc = nil, nil
    for school = 2, 7 do
        local v = call(GetSpellBonusDamage, school)
        if v then sp = math.max(sp or 0, v) end
        local c = call(GetSpellCritChance, school)
        if c then sc = math.max(sc or 0, c) end
    end
    L.SP, L.SCRIT = sp, sc
    L.HEAL = call(GetSpellBonusHealing)
    local db, dm = call(UnitDefense, "player")
    if db then L.DEF = db + (dm or 0) end
    L.DODGE = call(GetDodgeChance)
    L.PARRY = call(GetParryChance)
    L.BLOCK = call(GetBlockChance)
    for i = 1, 6 do L["R" .. i] = select(2, call(UnitResistance, "player", i)) end
    local mn, mx, omn, omx = call(UnitDamage, "player")
    if mn and mx then L.MH = { mn, mx } end
    if omn and omx and omx > 0 then L.OH = { omn, omx } end
    local _, rmn, rmx = call(UnitRangedDamage, "player")
    if rmn and rmx and rmx > 0 then L.RNG = { rmn, rmx } end
    return L
end

-- Attack power per point of Strength and Agility (melee), and per Agility (ranged), by class.
local AP_RULES = {
    WARRIOR = { 2, 0, 1 }, PALADIN = { 2, 0, 0 }, SHAMAN = { 2, 0, 0 }, DRUID = { 2, 0, 0 },
    ROGUE = { 1, 1, 1 }, HUNTER = { 1, 1, 2 }, MAGE = { 1, 0, 0 }, PRIEST = { 1, 0, 0 }, WARLOCK = { 1, 0, 0 },
}
local HEALTH_PER_STA, MANA_PER_INT, ARMOR_PER_AGI = 10, 15, 2
local WAND = 19  -- weapon subclass: wands don't use attack power

-- A weapon's shown damage is its range plus AP / 14 x speed (off hand: half). Today's value is
-- adjusted by the change in weapon and attack power, so talents and buffs carry over.
local function weaponRange(live, eqW, simW, liveAP, simAP, factor)
    if not simW then return nil end
    if live and eqW then
        local function at(i, key)
            return live[i] + factor * ((simW[key] - eqW[key]) + (simAP * simW.speed - liveAP * eqW.speed) / 14)
        end
        return { at(1, "min"), at(2, "max") }
    end
    return { factor * (simW.min + simAP / 14 * simW.speed), factor * (simW.max + simAP / 14 * simW.speed) }
end

local function isWand(link)
    local id = ns.LinkToId(link)
    local item = id and ns:GetItem(id)
    return item and item.c == ns.ITEM_CLASS_WEAPON and item.sc == WAND
end

-- Returns live, simulated: { key = number or {min, max} }.
function ns:SimulateStats(simLinks, eqLinks, class, live)
    live = live or self:LiveStats()
    class = class or self:GetPlayerClass()
    local eq, sim = sumStats(eqLinks), sumStats(simLinks)
    local d = setmetatable({}, { __index = function(_, k) return (sim[k] or 0) - (eq[k] or 0) end })
    local r = AP_RULES[class] or AP_RULES.MAGE
    live.HIT = live.HIT or 0
    live.SHIT = live.SHIT or 0
    live.MP5 = eq.MP5 or 0
    local S = {}
    local function add(k, delta) if live[k] then S[k] = live[k] + delta end end
    for _, k in ipairs({ "STR", "AGI", "STA", "INT", "SPI" }) do add(k, d[k]) end
    add("HEALTH", d.STA * HEALTH_PER_STA)
    add("MANA", d.INT * MANA_PER_INT)
    add("ARMOR", d.ARMOR + d.AGI * ARMOR_PER_AGI)
    local dAP = d.AP + d.STR * r[1] + d.AGI * r[2]
    local dRAP = d.AP + d.RAP + d.AGI * r[3]
    add("AP", dAP)
    add("RAP", dRAP)
    -- Items list hit, crit, dodge... as ratings; the sheet shows percent. Forever's hit and crit
    -- ratings count for melee, ranged and spells alike (no item carries spell hit/crit of its own).
    local level = UnitLevel("player") or 60
    local function pct(stat, v, spell) return v * (ns.RatingPct(stat, level, spell) or 1) end
    add("CRIT", pct("CRIT", d.CRIT))
    add("RCRIT", pct("CRIT", d.CRIT))
    add("HIT", pct("HIT", d.HIT))
    add("SP", d.SP)
    add("HEAL", d.SP + d.HEAL)
    add("SHIT", pct("HIT", d.HIT, true) + pct("SHIT", d.SHIT))
    add("SCRIT", pct("SCRIT", d.CRIT + d.SCRIT))
    add("DEF", d.DEF)
    add("DODGE", pct("DODGE", d.DODGE))
    add("PARRY", pct("PARRY", d.PARRY))
    add("BLOCK", pct("BLOCK", d.BLOCK))
    for i = 1, 6 do add("R" .. i, d["R" .. i]) end
    S.MP5 = sim.MP5 or 0

    local liveAP, simAP = live.AP or 0, (live.AP or 0) + dAP
    S.MH = weaponRange(live.MH, weaponInfo(eqLinks[16]), weaponInfo(simLinks[16]), liveAP, simAP, 1)
    S.OH = weaponRange(live.OH, weaponInfo(eqLinks[17]), weaponInfo(simLinks[17]), liveAP, simAP, 0.5)
    local liveRAP, simRAP = live.RAP or 0, (live.RAP or 0) + dRAP
    local eqR, simR = eqLinks[18], simLinks[18]
    S.RNG = weaponRange(live.RNG, weaponInfo(eqR), weaponInfo(simR),
        (eqR and isWand(eqR)) and 0 or liveRAP, (simR and isWand(simR)) and 0 or simRAP, 1)
    return live, S
end

---------------------------------------------------------------------------
-- Saved set
---------------------------------------------------------------------------
local function simDB()
    GearGuideCharDB.sim = GearGuideCharDB.sim or {}
    local db = GearGuideCharDB.sim
    if not db.slots then db.slots = ns:EquippedLinks() end
    return db
end

function ns:SimResetToEquipped()
    simDB().slots = self:EquippedLinks()
end

function ns:SimClear()
    simDB().slots = {}
end

-- Puts `link` (nil: empties the slot) on, taking off what it can't be worn with.
function ns:SimSetSlot(slot, link)
    local slots = simDB().slots
    slots[slot] = link
    if link and slot == 16 and equipLoc(link) == "INVTYPE_2HWEAPON" then slots[17] = nil end
    if link and slot == 17 and slots[16] and equipLoc(slots[16]) == "INVTYPE_2HWEAPON" then slots[16] = nil end
end

function ns:SimSlots() return simDB().slots end

---------------------------------------------------------------------------
-- Saved builds (per character): named copies of the simulated set. db.active is the build the set
-- was last loaded from or saved to; the set counts as changed when it no longer matches it.
---------------------------------------------------------------------------
local MAX_BUILDS, MAX_BUILD_NAME = 20, 32

local function copySlots(t)
    local c = {}
    for k, v in pairs(t or {}) do c[k] = v end
    return c
end

local function sameSlots(a, b)
    for k, v in pairs(a or {}) do if (b or {})[k] ~= v then return false end end
    for k, v in pairs(b or {}) do if (a or {})[k] ~= v then return false end end
    return true
end

function ns:SimBuilds()
    local db = simDB()
    db.builds = db.builds or {}
    return db.builds
end

local function findBuild(name)
    for i, b in ipairs(ns:SimBuilds()) do
        if b.name == name then return b, i end
    end
end

-- Saves the current set under `name` (a new build, or over the one with that name).
-- Returns true, or nil and a message for the player.
function ns:SimSaveBuild(name)
    name = tostring(name or ""):gsub("|", ""):match("^%s*(.-)%s*$")  -- "|" starts the game's text codes
    if name == "" then return nil, "Give the build a name." end
    name = name:sub(1, MAX_BUILD_NAME)
    local builds, b = self:SimBuilds(), findBuild(name)
    if not b then
        if #builds >= MAX_BUILDS then
            return nil, string.format("You can keep up to %d builds: delete one first.", MAX_BUILDS)
        end
        b = { name = name }
        builds[#builds + 1] = b
    end
    b.slots, b.at = copySlots(simDB().slots), time()
    simDB().active = name
    return true, name
end

function ns:SimLoadBuild(name)
    local b = findBuild(name)
    if not b then return false end
    simDB().slots = copySlots(b.slots)
    simDB().active = name
    return true
end

function ns:SimDeleteBuild(name)
    local _, i = findBuild(name)
    if not i then return false end
    table.remove(self:SimBuilds(), i)
    if simDB().active == name then simDB().active = nil end
    return true
end

-- A name no build has yet: "Name", "Name (2)", "Name (3)"...
local function freeName(base)
    base = tostring(base or ""):match("^%s*(.-)%s*$"):sub(1, MAX_BUILD_NAME - 4)
    if base == "" then base = "Build" end
    if not findBuild(base) then return base end
    for i = 2, 99 do
        local n = base .. " (" .. i .. ")"
        if not findBuild(n) then return n end
    end
    return base
end

-- Puts `slots` ({ [slot] = item string }) into the simulator and saves them as a build. The set is
-- in the simulator even when the build can't be saved (20 builds). Returns ok, name or message.
local function loadAndSave(slots, name, replace)
    simDB().slots = slots
    simDB().active = nil
    local ok, msg = ns:SimSaveBuild(replace and name or freeName(name))
    return ok, msg
end

---------------------------------------------------------------------------
-- Sharing builds as text: "GG1~Name~1:12640,3:4521/-17,..." (slot:item id, /suffix for random
-- bonus items). Short enough to paste in chat or a guild note.
---------------------------------------------------------------------------
local BUILD_PREFIX = "GG1"

function ns:SimExportBuild(name)
    local b = name and findBuild(name)
    local slots = b and b.slots or simDB().slots
    local parts = {}
    for _, slot in ipairs(ALL_SLOTS) do
        local link = slots[slot]
        local id = link and ns.LinkToId(link)
        if id then
            local suffix = ns:LinkVariant(link)
            parts[#parts + 1] = slot .. ":" .. id .. (suffix and ("/" .. suffix) or "")
        end
    end
    local clean = tostring(name or "Build"):gsub("[~|]", "")
    return BUILD_PREFIX .. "~" .. clean .. "~" .. table.concat(parts, ",")
end

-- Reads a shared build and saves it (under a new name if taken). Returns ok, name or message.
function ns:SimImportBuild(text)
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    local name, body = text:match("^" .. BUILD_PREFIX .. "~([^~]*)~([%d:,/%-]*)$")
    if not body then return nil, "That isn't a GearGuide build (it starts with " .. BUILD_PREFIX .. "~)." end
    local valid, slots, n = {}, {}, 0
    for _, s in ipairs(ALL_SLOTS) do valid[s] = true end
    for slot, id, suffix in body:gmatch("(%d+):(%d+)/?(%-?%d*)") do
        slot, id, suffix = tonumber(slot), tonumber(id), tonumber(suffix)
        if valid[slot] and id and id > 0 then
            slots[slot] = (suffix and suffix ~= 0) and ns.VariantLink(id, suffix) or ("item:" .. id)
            n = n + 1
        end
    end
    if n == 0 then return nil, "That build has no items in it." end
    return loadAndSave(slots, (name ~= "" and name) or "Imported build")
end

-- Another player's gear (Inspect) as a build: "Name's gear", replacing an older copy of it.
function ns:SimSaveUnitGear(unit)
    if not unit or not UnitExists or not UnitExists(unit) then return nil, "Nobody to load." end
    local slots, n = {}, 0
    for _, slot in ipairs(ALL_SLOTS) do
        local link = itemString(GetInventoryItemLink(unit, slot))
        if link then slots[slot] = link; n = n + 1 end
    end
    if n == 0 then return nil, "Their gear isn't loaded yet: inspect them first, then try again." end
    local who = (UnitName(unit)) or "Someone"
    return loadAndSave(slots, who .. "'s gear", true)
end

-- name of the active build (or nil), and whether the set changed since it was saved.
function ns:SimActiveBuild()
    local db = simDB()
    local b = db.active and findBuild(db.active)
    if not b then return nil, false end
    return b.name, not sameSlots(db.slots, b.slots)
end

---------------------------------------------------------------------------
-- Shopping list: the set's items you don't have, grouped by where to get them (the dungeon, zone
-- or vendor's zone of each item's best source; crafted and PvP items in their own groups).
---------------------------------------------------------------------------
local KIND_GROUPS = { craft = "Crafted", pvp = "PvP rewards", world = "World drops", start = "Starting gear" }
local UNKNOWN_GROUP = "Source not discovered yet"

local function owns(id)
    if IsEquippedItem and IsEquippedItem(id) then return true end
    return GetItemCount ~= nil and (GetItemCount(id, true) or 0) > 0
end

local function placeOf(s)
    if KIND_GROUPS[s.t] then return KIND_GROUPS[s.t] end
    local zone = ns.ZoneName(s.z)
    if (not zone or zone == "") and type(s.loc) == "table" and s.loc[1] then
        local e = s.loc[1]
        zone = e.e and ns.ZoneName(e.e)
        if not zone and e.m and C_Map and C_Map.GetMapInfo then
            local info = C_Map.GetMapInfo(e.m)
            zone = info and info.name
        end
    end
    return (zone and zone ~= "") and zone or "Elsewhere"
end

-- Short source line for a row (the zone is the group's header).
function ns.ShopSourceText(s)
    if not s then return "" end
    local text
    if s.t == "drop" then
        text = (s.k == "object" and "Chest: " or "") .. (s.n or "?")
        if s.dc then text = text .. " " .. ns.FormatChance(s.dc) end
    elseif s.t == "vendor" then text = "Vendor: " .. (s.n or "?")
    elseif s.t == "quest" then text = "Quest: " .. (s.n or "?")
    else text = s.n or "" end
    return text
end

-- { { label, items = { {slot, id, item, link, source}, ... } }, ... }, items still to get, items in the set
function ns:SimShoppingList()
    local slots = simDB().slots
    local groups, byLabel, seen = {}, {}, {}
    local need, total = 0, 0
    for _, slot in ipairs(ALL_SLOTS) do
        local link = (slot ~= 4 and slot ~= 19) and slots[slot] or nil  -- shirt and tabard: cosmetic, not in the database
        local id = link and ns.LinkToId(link)
        if id and not seen[id] then
            seen[id] = true
            total = total + 1
            if not owns(id) then
                need = need + 1
                local s = self:GetSources(id)[1]
                local label = s and placeOf(s) or UNKNOWN_GROUP
                local g = byLabel[label]
                if not g then
                    g = { label = label, items = {} }
                    byLabel[label] = g
                    groups[#groups + 1] = g
                end
                g.items[#g.items + 1] = { slot = slot, id = id, link = link, source = s,
                    item = (ns.LinkBonus(link) and self:ItemFromLink(link)) or self:GetItem(id) }
            end
        end
    end
    table.sort(groups, function(a, b)
        if (a.label == UNKNOWN_GROUP) ~= (b.label == UNKNOWN_GROUP) then return b.label == UNKNOWN_GROUP end
        if #a.items ~= #b.items then return #a.items > #b.items end
        return a.label < b.label
    end)
    return groups, need, total
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
local DOLL_W, DOLL_H = 330, 356
local SLOT, PITCH = 32, 36
local STATS_W, PICKER_MIN, GAP = 200, 200, 6
local GOLD = { 1, 0.82, 0, 1 }

local SECTIONS = {
    { "General", { { "Health", "HEALTH" }, { "Mana", "MANA" }, { "Armor", "ARMOR" } } },
    { "Primary Attributes", { { "Strength", "STR" }, { "Agility", "AGI" }, { "Stamina", "STA" },
        { "Intellect", "INT" }, { "Spirit", "SPI" } } },
    { "Weapons", { { "Main Hand", "MH" }, { "Off Hand", "OH" }, { "Ranged", "RNG" } } },
    { "Melee", { { "Attack Power", "AP" }, { "Hit Chance", "HIT" }, { "Crit Chance", "CRIT" } } },
    { "Ranged", { { "Attack Power", "RAP" }, { "Crit Chance", "RCRIT" } } },
    { "Spell", { { "Spell Power", "SP" }, { "Healing", "HEAL" }, { "Hit Chance", "SHIT" },
        { "Crit Chance", "SCRIT" }, { "Mana per 5 sec.", "MP5" } } },
    { "Defense", { { "Defense", "DEF" }, { "Dodge", "DODGE" }, { "Parry", "PARRY" }, { "Block", "BLOCK" } } },
    { "Resistances", { { "Arcane", "R6" }, { "Fire", "R2" }, { "Nature", "R3" }, { "Frost", "R4" }, { "Shadow", "R5" } } },
}
local PCT = { HIT = true, CRIT = true, RCRIT = true, SHIT = true, SCRIT = true, DODGE = true, PARRY = true, BLOCK = true }
local NOTES = {
    HEALTH = "10 health per point of Stamina.",
    MANA = "15 mana per point of Intellect.",
    ARMOR = "Armor on gear, plus 2 per point of Agility.",
    AP = "Attack power on gear, plus what Strength and Agility give your class.",
    RAP = "Attack power on gear, plus what Agility gives your class.",
    CRIT = "Crit chance on gear. The extra crit from Agility isn't estimated.",
    RCRIT = "Crit chance on gear. The extra crit from Agility isn't estimated.",
    SCRIT = "Spell crit on gear. The extra crit from Intellect isn't estimated.",
    DODGE = "Dodge on gear. The extra dodge from Agility isn't estimated.",
    MH = "Weapon damage plus attack power (AP / 14 x weapon speed).",
    OH = "Half of the weapon's damage plus attack power.",
    RNG = "Weapon damage plus ranged attack power (wands don't use it).",
    MP5 = "Mana regeneration from gear.",
}

local function fmt(key, v)
    if v == nil then return "-" end
    if type(v) == "table" then return string.format("%d - %d", math.floor(v[1] + 0.5), math.floor(v[2] + 0.5)) end
    if PCT[key] then return string.format("%.2f%%", v) end
    return tostring(math.floor(v + 0.5))
end

local function num(v)
    if type(v) == "table" then return (v[1] + v[2]) / 2 end
    return v
end

local function outline(parent, colorKey, pad)
    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", -pad, pad)
    f:SetPoint("BOTTOMRIGHT", pad, -pad)
    local c = ns.Skin:Color(colorKey)
    for i = 1, 4 do
        local t = f:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
        if i == 1 then t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetHeight(2)
        elseif i == 2 then t:SetPoint("BOTTOMLEFT"); t:SetPoint("BOTTOMRIGHT"); t:SetHeight(2)
        elseif i == 3 then t:SetPoint("TOPLEFT"); t:SetPoint("BOTTOMLEFT"); t:SetWidth(2)
        else t:SetPoint("TOPRIGHT"); t:SetPoint("BOTTOMRIGHT"); t:SetWidth(2) end
    end
    f:Hide()
    return f
end

local slotTexCache = {}
local function emptySlotTexture(slot)
    if slotTexCache[slot] then return slotTexCache[slot] end
    local tex
    if GetInventorySlotInfo then
        local ok, _, t = pcall(GetInventorySlotInfo, SLOT_NAMES[slot])
        if ok then tex = t end
    end
    tex = tex or "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
    slotTexCache[slot] = tex
    return tex
end

local function itemLinkFor(link)
    local _, full = ns.GetItemInfo(link)
    return full or link
end

local function sameItem(a, b)
    if not a or not b then return a == b end
    return ns.LinkToId(a) == ns.LinkToId(b) and (ns.LinkBonus(a) or "") == (ns.LinkBonus(b) or "")
end

-- Hit, expertise and defense caps per spec, from the spec research (the `caps` notes in
-- SpecWeights.lua). Percent (defense: points above the level's base defense) against level-63 raid
-- bosses (`raid`, used at 60) and level-equal mobs (`normal`, used from 50 to 59). Past the cap a
-- percent is worth `after` (or `afterShare` of the stat's weight); unset means about nothing.
-- Caps count talents and gear together, so talent hit (Precision, Surefooted...) is included.
local function meleeHit(after, share) return { stat = "HIT", label = "Hit", raid = 8, normal = 5, after = after, afterShare = share } end
local SPELL_HIT = { stat = "HIT", label = "Spell hit", raid = 17, normal = 4, spell = true }
local function expertise(cap, after) return { stat = "EXPERTISE", label = "Expertise", raid = cap, normal = 5, after = after } end
local function defense(after) return { stat = "DEF", label = "Defense", raid = 140, after = after } end
local SIM_CAPS = {
    WARRIOR = { ARMS = { meleeHit(0), expertise(6.5, 0) }, FURY = { meleeHit(7), expertise(6.5, 0) },
        PROTECTION = { defense(0.6), meleeHit(2), expertise(6.5, 3) } },
    PALADIN = { PROTECTION = { defense(0.5), meleeHit(2), expertise(6.5, 2) },
        RETRIBUTION = { meleeHit(3), expertise(6.5, 0) } },
    HUNTER = { BEASTMASTERY = { meleeHit(0) }, MARKSMANSHIP = { meleeHit(0) }, SURVIVAL = { meleeHit(0) } },
    ROGUE = { ASSASSINATION = { meleeHit(4), expertise(6.5, 0) }, COMBAT = { meleeHit(5), expertise(6.5, 0) },
        SUBTLETY = { meleeHit(4), expertise(6.5, 0) } },
    PRIEST = { SHADOW = { SPELL_HIT } },
    SHAMAN = { ELEMENTAL = { SPELL_HIT }, ENHANCEMENT = { meleeHit(nil, 1 / 3), expertise(6.5, 0) } },
    MAGE = { ARCANE = { SPELL_HIT }, FIRE = { SPELL_HIT }, FROST = { SPELL_HIT } },
    WARLOCK = { AFFLICTION = { SPELL_HIT }, DEMONOLOGY = { SPELL_HIT }, DESTRUCTION = { SPELL_HIT } },
    DRUID = { BALANCE = { SPELL_HIT }, FERAL_CAT = { meleeHit(0), expertise(6.5, 0) },
        FERAL_BEAR = { defense(0.9), meleeHit(0), expertise(14, 0) } },
}
ns.SIM_CAPS = SIM_CAPS
local CAPS_FROM = 50  -- below this, items are judged one slot at a time (no caps while leveling)

-- The caps that apply now, each with what talents already give (`base`) and its value per percent.
local function activeCaps(weights, ctx, level)
    local out = {}
    local list = level >= CAPS_FROM and SIM_CAPS[ctx.class] and SIM_CAPS[ctx.class][ctx.spec or ""]
    if not list then return out end
    local live = ns:LiveStats()
    local worn = sumStats(ns:EquippedLinks())
    -- The modern client reports talent hit apart from gear rating; an older one adds them up.
    local separate = type(GetCombatRatingBonus) == "function"
    for _, c in ipairs(list) do
        local cap = (level >= 60) and c.raid or c.normal
        local w = weights[c.stat] or 0
        if cap and w > 0 then
            local perPoint = (c.stat == "DEF") and 1 or (ns.RatingPct(c.stat, level, c.spell) or 1)
            local base = 0
            if c.stat == "HIT" then
                local mod = (c.spell and live.SHIT_TALENT or live.HIT_TALENT) or 0
                base = separate and mod or math.max(0, mod - (worn.HIT or 0) * perPoint)
            elseif c.stat == "DEF" then
                local ok, _, m = pcall(UnitDefense, "player")
                base = ok and math.max(0, (tonumber(m) or 0) - (worn.DEF or 0)) or 0
            end
            out[#out + 1] = { stat = c.stat, label = c.label, cap = cap, w = w, perPoint = perPoint, base = base,
                after = c.afterShare and w * c.afterShare or c.after or 0, raid = level >= 60 }
        end
    end
    return out
end

-- The best set GearGuide knows for this character right now, from items it can wear at its
-- current level. It follows the recommendations' rules: the spec's weapon setup, the best armor
-- type the class wears, and stats the spec values. Worn items compete with their live stats, so a
-- good random bonus ("of the Bear") isn't swapped out for less. Rings, trinkets and the two hands
-- get different items; shirt and tabard stay as they are.
--
-- Up to level 49 the best item per slot is the best set. From 50, hit, expertise and defense caps
-- start to matter: a point past the cap is worth little, so the set is tuned as a whole. It starts
-- from the best item per slot, then keeps swapping single slots (or the weapon pair) while the
-- whole set's value goes up. Returns the number of slots changed and the cap results.
function ns:SimRecommend()
    local weights, ctx = self:GetScoringContext()
    local class, level = ctx.class, ctx.level or 1
    local setup = self:WeaponSetup(class, ctx.spec, level)
    local caps = activeCaps(weights, ctx, level)
    local buckets = {}
    local function consider(item, link, id, worn)
        if self:IsIgnored(id) then return end  -- the player banned it from recommendations
        if not worn and self:RaidGearTooEarly(item, level) then return end  -- raid gear waits for max level
        local groups = self:GroupsForItem(item, setup)
        if not groups or not self:IsUsable(item, class, level) or ns.EffectiveLevel(item) > level
            or not ns.WeaponTypeAllowed(item, class, ctx.spec, level) then return end
        local score = self:Score(item, weights, ctx)
        local statsOk, armorOk = self:IsSuitable(item, weights, ctx, score)
        if not statsOk or score <= 0 then return end
        -- What the item adds toward each cap, and its score without those stats.
        local toward, free = {}, score
        for i, c in ipairs(caps) do
            local v = (item.st and item.st[c.stat] or 0) * c.perPoint
            toward[i] = v
            free = free - v * c.w
        end
        for _, g in ipairs(groups) do
            buckets[g] = buckets[g] or {}
            table.insert(buckets[g], { id = id, item = item, link = link, score = score, free = free,
                toward = toward, armorOk = armorOk, worn = worn })
        end
    end
    for _, id in ipairs(self:AllItemIds()) do
        local item = self:GetItem(id)
        if item and self:ShowsItem(id) then consider(item, "item:" .. id, id, false) end
    end
    local wornLinks = {}
    for _, slot in ipairs(ALL_SLOTS) do
        local item, link, id = self:ItemForSlot(slot)
        if item and id then
            wornLinks[slot] = itemString(link)
            consider(item, wornLinks[slot], id, true)
        end
    end

    -- Best first (worn wins a tie: same item, keeps its bonus); best armor type only, unless the
    -- slot has nothing of that type (low levels).
    local function ranked(group)
        local list = buckets[group] or {}
        table.sort(list, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            if a.worn ~= b.worn then return a.worn end
            return a.id < b.id
        end)
        for _, c in ipairs(list) do
            if c.armorOk then
                local out = {}
                for _, d in ipairs(list) do if d.armorOk then out[#out + 1] = d end end
                return out
            end
        end
        return list
    end
    -- The few items worth trying in a slot: the best overall, and the best once capped stats are
    -- left out (what replaces a hit piece when the set is already over the cap).
    local SHORTLIST, SHORTLIST_FREE = 30, 15
    local function shortlist(list, accept)
        local out, seen = {}, {}
        local function addFrom(sorted, n)
            local k = 0
            for _, c in ipairs(sorted) do
                if k >= n then break end
                if not accept or accept(c) then
                    k = k + 1
                    if not seen[c] then seen[c] = true; out[#out + 1] = c end
                end
            end
        end
        addFrom(list, SHORTLIST)
        if #caps > 0 then
            local byFree = {}
            for i, c in ipairs(list) do byFree[i] = c end
            table.sort(byFree, function(a, b)
                if a.free ~= b.free then return a.free > b.free end
                return a.id < b.id
            end)
            addFrom(byFree, SHORTLIST_FREE)
        end
        return out
    end
    local function is2H(c) return c.item.eq == "INVTYPE_2HWEAPON" end

    -- Choices: one per slot, the hands as one choice { [16] = c, [17] = c }.
    local choices, slotUnits = {}, {}
    for _, grp in ipairs(ns.SLOT_GROUPS) do
        if grp.key ~= "MAINHAND" and grp.key ~= "OFFHAND" then
            local options = shortlist(ranked(grp.key))
            for _, slot in ipairs(grp.inv) do
                local opts = {}
                for i, c in ipairs(options) do opts[i] = { [slot] = c } end
                slotUnits[#slotUnits + 1] = opts
            end
        end
    end
    local mh, oh = ranked("MAINHAND"), ranked("OFFHAND")
    local twos = shortlist(mh, is2H)
    local ones = shortlist(mh, function(c) return not is2H(c) end)
    local offs = shortlist(oh)
    local hands = {}
    for _, c in ipairs(twos) do hands[#hands + 1] = { [16] = c } end
    local PAIRS = 12
    for i, a in ipairs(ones) do
        if i > PAIRS then break end
        hands[#hands + 1] = { [16] = a }
        for j, b in ipairs(offs) do
            if j > PAIRS then break end
            if b.id ~= a.id then hands[#hands + 1] = { [16] = a, [17] = b } end
        end
    end
    if #offs > 0 and #ones == 0 and #twos == 0 then hands[#hands + 1] = { [17] = offs[1] } end
    slotUnits[#slotUnits + 1] = hands

    -- Whole-set value: item scores, less what capped stats past their cap don't give.
    local function capTotals(set)
        local totals = {}
        for i, c in ipairs(caps) do
            local t = c.base
            for _, cand in pairs(set) do t = t + cand.toward[i] end
            totals[i] = t
        end
        return totals
    end
    local function value(set)
        local v = 0
        for _, cand in pairs(set) do v = v + cand.score end
        local totals = capTotals(set)
        for i, c in ipairs(caps) do
            local over = totals[i] - c.cap
            if over > 0 then v = v - over * (c.w - c.after) end
        end
        return v
    end
    local function fits(set, option)
        for slot, c in pairs(option) do
            for s, other in pairs(set) do
                if other.id == c.id and option[s] == nil and s ~= slot then return false end
            end
        end
        return true
    end
    -- Puts `option` in for its choice (clearing every slot the choice covers); returns what was there.
    local function apply(set, unit, option)
        local old, covered = {}, {}
        for _, opt in ipairs(unit) do
            for slot in pairs(opt) do
                if not covered[slot] then covered[slot] = true; old[slot] = set[slot] end
            end
        end
        for slot in pairs(covered) do set[slot] = nil end
        for slot, c in pairs(option) do set[slot] = c end
        return old, covered
    end
    local function restore(set, old, covered)
        for slot in pairs(covered) do set[slot] = old[slot] end
    end

    -- Start: the best option per choice in turn (the best item per slot), then improve.
    local set = {}
    for _, unit in ipairs(slotUnits) do
        local best, bestScore
        for _, option in ipairs(unit) do
            if fits(set, option) then
                local s = 0
                for _, c in pairs(option) do s = s + c.score end
                if not bestScore or s > bestScore then best, bestScore = option, s end
            end
        end
        if best then apply(set, unit, best) end
    end
    if #caps > 0 then
        for _ = 1, 12 do
            local improved = false
            for _, unit in ipairs(slotUnits) do
                local current = value(set)
                local best, bestValue = nil, current + 1e-6
                for _, option in ipairs(unit) do
                    local old, covered = apply(set, unit, option)
                    if fits(set, option) then
                        local v = value(set)
                        if v > bestValue then best, bestValue = option, v end
                    end
                    restore(set, old, covered)
                end
                if best then
                    apply(set, unit, best)
                    improved = true
                end
            end
            if not improved then break end
        end
    end

    local out = {}
    for slot, c in pairs(set) do out[slot] = c.link end
    -- Nothing suitable known for a slot (stat-less trinkets at low level): keep what's worn there.
    -- Not for the hands: an empty off hand is what a two-hand setup wants.
    for slot, link in pairs(wornLinks) do
        if out[slot] == nil and slot ~= 4 and slot ~= 19 and slot ~= 16 and slot ~= 17 then
            local id = ns.LinkToId(link)
            local dupe = self:IsIgnored(id)  -- an ignored item stays out even when it's what you wear
            for s, l in pairs(out) do if s ~= slot and ns.LinkToId(l) == id then dupe = true end end
            if not dupe then out[slot] = link end
        end
    end

    local slots = simDB().slots
    local changed = 0
    for _, slot in ipairs(ALL_SLOTS) do
        if slot ~= 4 and slot ~= 19 then
            if not sameItem(slots[slot], out[slot]) then changed = changed + 1 end
            slots[slot] = out[slot]
        end
    end
    local results = {}
    local totals = capTotals(set)
    for i, c in ipairs(caps) do
        results[i] = { label = c.label, stat = c.stat, total = totals[i], cap = c.cap, raid = c.raid }
    end
    return changed, results
end

function ns:CreateSimulatorPanel(parent)
    local Skin = ns.Skin
    local panel = CreateFrame("Frame", nil, parent)
    local state = { slot = 1, text = "", facing = 0, zoom = 0, dressed = nil }
    local slotButtons = {}

    -----------------------------------------------------------------------
    -- Character page (fixed native size, scaled to fit)
    -----------------------------------------------------------------------
    -- column: the full-height strip the stats panel lines up with. holder: the bordered character
    -- window inside it, exactly as big as the (scaled) character page.
    local column = CreateFrame("Frame", nil, panel)
    column:SetPoint("TOPLEFT")
    column:SetPoint("BOTTOMLEFT")
    column:SetWidth(DOLL_W)
    local holder = Skin:Panel(column, "panel", "border")
    holder:SetPoint("TOPLEFT")
    holder:SetSize(DOLL_W, DOLL_H)

    local doll = CreateFrame("Frame", nil, holder)
    doll:SetSize(DOLL_W, DOLL_H)
    doll:SetPoint("TOP", holder, "TOP", 0, 0)

    local title = Skin:Text(doll, Skin.SIZE.header + 2, GOLD)
    title:SetPoint("TOP", doll, "TOP", 0, -10)
    title:SetJustifyH("CENTER")

    local model = CreateFrame("DressUpModel", nil, doll)
    model:SetPoint("TOPLEFT", doll, "TOPLEFT", 48, -50)
    model:SetPoint("BOTTOMRIGHT", doll, "BOTTOMRIGHT", -48, 44)
    model:EnableMouse(true)
    model:EnableMouseWheel(true)

    local function applyView()
        if model.SetFacing then pcall(model.SetFacing, model, state.facing) end
        if model.SetPortraitZoom then pcall(model.SetPortraitZoom, model, state.zoom) end
    end

    local function dressItems()
        if model.Undress then pcall(model.Undress, model) end
        state.missing = false  -- an item the client hasn't loaded yet: dress again once it has
        for _, slot in ipairs(ALL_SLOTS) do
            local link = simDB().slots[slot]
            if link and not ns.GetItemInfo(link) then state.missing = true end
            if link then
                local hand = (slot == 16 and "MAINHANDSLOT") or (slot == 17 and "SECONDARYHANDSLOT") or nil
                pcall(model.TryOn, model, itemLinkFor(link), hand)
            end
        end
        applyView()
    end

    -- SetUnit loads the model in the background; the items go on once it's there.
    local function dressModel(force)
        local sig = {}
        for _, slot in ipairs(ALL_SLOTS) do sig[#sig + 1] = simDB().slots[slot] or "" end
        sig = table.concat(sig, ";")
        if not force and sig == state.dressed then return end
        state.dressed = sig
        if model.SetUnit then pcall(model.SetUnit, model, "player") end
        dressItems()
        if C_Timer and C_Timer.After then C_Timer.After(0.1, dressItems) end
    end
    if model.HasScript and model:HasScript("OnModelLoaded") then
        model:SetScript("OnModelLoaded", dressItems)
    end

    model:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then self.dragX = GetCursorPosition() end
    end)
    model:SetScript("OnMouseUp", function(self) self.dragX = nil end)
    model:SetScript("OnHide", function(self) self.dragX, self.spin = nil, nil end)
    model:SetScript("OnUpdate", function(self, elapsed)
        local turned = false
        if self.dragX then
            local x = GetCursorPosition()
            state.facing = state.facing + (x - self.dragX) * 0.02
            self.dragX = x
            turned = true
        end
        if self.spin then
            state.facing = state.facing + self.spin * elapsed * 2.5
            turned = true
        end
        if turned and self.SetFacing then self:SetFacing(state.facing) end
    end)
    model:SetScript("OnMouseWheel", function(_, delta)
        state.zoom = math.max(0, math.min(0.9, state.zoom + delta * 0.1))
        applyView()
    end)

    -- Toolbar: zoom in / out, turn left / right (hold), reset.
    local tools = {
        { "+", "Zoom in", function() state.zoom = math.min(0.9, state.zoom + 0.1); applyView() end },
        { "-", "Zoom out", function() state.zoom = math.max(0, state.zoom - 0.1); applyView() end },
        { "<", "Turn left (hold)", nil, -1 },
        { ">", "Turn right (hold)", nil, 1 },
        { "o", "Reset view", function() state.facing, state.zoom = 0, 0; applyView() end },
    }
    local TOOL = 18
    local x0 = -(#tools * (TOOL + 4) - 4) / 2
    for i, t in ipairs(tools) do
        local b = Skin:IconButton(doll, t[1], TOOL)
        b:SetPoint("TOPLEFT", doll, "TOP", x0 + (i - 1) * (TOOL + 4), -30)
        b:SetFrameLevel(model:GetFrameLevel() + 2)
        if t[3] then b:SetScript("OnClick", t[3]) end
        if t[4] then
            b:HookScript("OnMouseDown", function() model.spin = t[4] end)
            b:HookScript("OnMouseUp", function() model.spin = nil end)
            b:HookScript("OnHide", function() model.spin = nil end)
        end
        b:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(t[2], 1, 1, 1)
            if i == 1 then GameTooltip:AddLine("Mouse wheel over the character zooms; dragging turns it.", 0.6, 0.6, 0.6, true) end
            GameTooltip:Show()
        end)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -----------------------------------------------------------------------
    -- Slots
    -----------------------------------------------------------------------
    local refreshAll  -- defined below

    local function slotOnEnter(b)
        local link = simDB().slots[b.slot]
        GameTooltip:SetOwner(b, (b.side == "bottom" and "ANCHOR_TOP") or (b.side == "right" and "ANCHOR_LEFT")
            or "ANCHOR_RIGHT")
        if link then
            GameTooltip:SetHyperlink(link)
        else
            GameTooltip:AddLine(SLOT_LABELS[b.slot], 1, 1, 1)
            GameTooltip:AddLine("Empty", 0.6, 0.6, 0.6)
        end
        local worn = GetInventoryItemLink("player", b.slot)
        if not sameItem(link, itemString(worn)) then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("You're wearing: " .. (worn or "nothing"), 0.86, 0.66, 0.5, true)
        end
        GameTooltip:AddLine("Click: choose an item for this slot. Right-click: empty it.", 0.4, 1, 0.6, true)
        GameTooltip:Show()
    end

    local function createSlot(slot, side)
        local b = CreateFrame("Button", nil, doll, "BackdropTemplate")
        b:SetSize(SLOT, SLOT)
        b.slot, b.side = slot, side
        Skin:SetBackdrop(b, "bg", "borderStrong")
        b:SetFrameLevel(model:GetFrameLevel() + 2)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 2, -2)
        b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(b.icon)
        hl:SetColorTexture(1, 1, 1, 0.15)
        b.changed = b:CreateTexture(nil, "OVERLAY")
        b.changed:SetSize(6, 6)
        b.changed:SetPoint("TOPRIGHT", -2, -2)
        local ac = Skin:Color("accent")
        b.changed:SetColorTexture(ac[1], ac[2], ac[3], 1)
        b.sel = outline(b, "accent", 2)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", function(self, button)
            local link = simDB().slots[self.slot]
            if button == "LeftButton" and link and IsModifiedClick and IsModifiedClick("CHATLINK") then
                if ChatEdit_InsertLink then ChatEdit_InsertLink(itemLinkFor(link)) end
                return
            end
            if button == "RightButton" then
                ns:SimSetSlot(self.slot, nil)
            end
            if state.slot ~= self.slot and state.onSlotChange then state.onSlotChange() end
            state.slot = self.slot
            state.resetScroll = true
            refreshAll()
            if self:IsMouseOver() then slotOnEnter(self) end
        end)
        b:SetScript("OnEnter", slotOnEnter)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        slotButtons[slot] = b
        return b
    end

    local TOP_Y = -52
    for i, slot in ipairs(LEFT) do
        createSlot(slot, "left"):SetPoint("TOPLEFT", doll, "TOPLEFT", 10, TOP_Y - (i - 1) * PITCH)
    end
    for i, slot in ipairs(RIGHT) do
        createSlot(slot, "right"):SetPoint("TOPRIGHT", doll, "TOPRIGHT", -10, TOP_Y - (i - 1) * PITCH)
    end
    local bx = -(#BOTTOM * PITCH - (PITCH - SLOT)) / 2
    for i, slot in ipairs(BOTTOM) do
        createSlot(slot, "bottom"):SetPoint("BOTTOMLEFT", doll, "BOTTOM", bx + (i - 1) * PITCH, 6)
    end

    local function updateSlots()
        local slots = simDB().slots
        for slot, b in pairs(slotButtons) do
            local link = slots[slot]
            local id = link and ns.LinkToId(link)
            if id then
                b.icon:SetTexture(ns.ItemIcon(id))
                b.icon:SetDesaturated(false)
                b.icon:SetAlpha(1)
                local q = select(3, ns.GetItemInfo(link)) or (ns:GetItem(id) or {}).q
                local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
                if c and c.r then b:SetBackdropBorderColor(c.r, c.g, c.b, 1)
                else b:SetBackdropBorderColor(1, 1, 1, 0.22) end
            else
                b.icon:SetTexture(emptySlotTexture(slot))
                b.icon:SetDesaturated(true)
                b.icon:SetAlpha(0.6)
                b:SetBackdropBorderColor(1, 1, 1, 0.22)
            end
            local worn = GetInventoryItemLink("player", slot)
            b.changed:SetShown(not sameItem(link, itemString(worn)))
            b.sel:SetShown(slot == state.slot)
        end
        local level = UnitLevel("player") or 1
        local className = UnitClass("player") or ""
        title:SetText(string.format("Level %d %s", level, className))
    end

    -----------------------------------------------------------------------
    -- Stats column
    -----------------------------------------------------------------------
    local stats = Skin:Panel(panel, "panel", "border")
    stats:SetPoint("TOPLEFT", column, "TOPRIGHT", GAP, 0)
    stats:SetPoint("BOTTOMLEFT", column, "BOTTOMRIGHT", GAP, 0)
    stats:SetWidth(STATS_W)

    local resetBtn = Skin:Button(stats, "Reset", nil, Skin.CONTROL_H)
    resetBtn:SetPoint("BOTTOMLEFT", stats, "BOTTOMLEFT", 6, 6)
    resetBtn:SetPoint("RIGHT", stats, "CENTER", -3, 0)
    resetBtn:SetScript("OnClick", function() ns:SimResetToEquipped(); refreshAll() end)
    resetBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Reset", 1, 1, 1)
        GameTooltip:AddLine("Puts back what you're wearing in every slot.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    resetBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    local clearBtn = Skin:Button(stats, "Clear all", nil, Skin.CONTROL_H)
    clearBtn:SetPoint("BOTTOMRIGHT", stats, "BOTTOMRIGHT", -6, 6)
    clearBtn:SetPoint("LEFT", stats, "CENTER", 3, 0)
    clearBtn:SetScript("OnClick", function() ns:SimClear(); refreshAll() end)
    local bestBtn = Skin:Button(stats, "Recommended build", nil, Skin.CONTROL_H)
    bestBtn:SetPoint("BOTTOMLEFT", resetBtn, "TOPLEFT", 0, 4)
    bestBtn:SetPoint("RIGHT", clearBtn, "RIGHT", 0, 0)
    bestBtn:SetScript("OnClick", function()
        local n, caps = ns:SimRecommend()
        refreshAll()
        local msg = (n == 0) and "Recommended build: this set already is the best GearGuide knows for your level."
            or string.format("Recommended build: %d slot%s changed.", n, n == 1 and "" or "s")
        if caps and #caps > 0 then
            local parts = {}
            for _, c in ipairs(caps) do
                local unit = (c.stat == "DEF") and "" or "%"
                parts[#parts + 1] = string.format("%s %.1f%s of %g%s", c.label, c.total, unit, c.cap, unit)
            end
            msg = msg .. string.format(" Tuned as a whole set for caps vs %s: %s.",
                caps[1].raid and "raid bosses" or "same-level enemies", table.concat(parts, ", "))
        end
        ns.Print(msg)
    end)
    bestBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Recommended build", 1, 1, 1)
        GameTooltip:AddLine("Puts the highest-scoring item you can wear at your current level in every slot, "
            .. "using your spec's stat weights and weapon setup. Items whose source isn't known are left out "
            .. "unless you show them in Settings.", nil, nil, nil, true)
        GameTooltip:AddLine("From level 50 the set is tuned as a whole: hit, expertise and defense count only "
            .. "up to their caps (raid bosses at 60, same-level enemies before), talents included.",
            nil, nil, nil, true)
        GameTooltip:Show()
    end)
    bestBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    stats.bestBtn = bestBtn

    local scroll = CreateFrame("ScrollFrame", nil, stats)
    scroll:SetPoint("TOPLEFT", 6, -6)
    scroll:SetPoint("BOTTOMRIGHT", -6, 2 * Skin.CONTROL_H + 16)
    scroll:EnableMouseWheel(true)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(STATS_W - 12, 10)
    scroll:SetScrollChild(body)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, body:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * 30)))
    end)

    local statRows = {}
    local y = 0
    local ROW_H = 17
    for _, sec in ipairs(SECTIONS) do
        local head = Skin:Text(body, Skin.SIZE.normal, "accent")
        head:SetPoint("TOP", body, "TOP", 0, -(y + 4))
        head:SetJustifyH("CENTER")
        head:SetText(sec[1])
        local l1 = Skin:Divider(body, "accent")
        l1:SetPoint("LEFT", body, "LEFT", 2, 0)
        l1:SetPoint("RIGHT", head, "LEFT", -6, 0)
        l1:SetPoint("TOP", head, "CENTER", 0, 0)
        l1:SetAlpha(0.5)
        local l2 = Skin:Divider(body, "accent")
        l2:SetPoint("LEFT", head, "RIGHT", 6, 0)
        l2:SetPoint("RIGHT", body, "RIGHT", -2, 0)
        l2:SetPoint("TOP", head, "CENTER", 0, 0)
        l2:SetAlpha(0.5)
        y = y + 24
        for i, def in ipairs(sec[2]) do
            local row = CreateFrame("Frame", nil, body)
            row:SetHeight(ROW_H)
            row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
            row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
            row:EnableMouse(true)
            if i % 2 == 0 then
                local s = row:CreateTexture(nil, "BACKGROUND")
                s:SetAllPoints()
                s:SetColorTexture(1, 1, 1, 0.025)
            end
            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.05)
            row.label = Skin:Text(row, Skin.SIZE.small, "textDim")
            row.label:SetPoint("LEFT", 6, 0)
            row.label:SetText(def[1] .. ":")
            row.value = Skin:Text(row, Skin.SIZE.small, "text")
            row.value:SetPoint("RIGHT", -6, 0)
            row.value:SetJustifyH("RIGHT")
            row.key, row.name = def[2], def[1]
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(self.name, 1, 1, 1)
                GameTooltip:AddDoubleLine("Now:", fmt(self.key, self.now), 0.6, 0.6, 0.6, 1, 1, 1)
                GameTooltip:AddDoubleLine("With this set:", fmt(self.key, self.sim), 0.6, 0.6, 0.6, 1, 1, 1)
                local a, b = num(self.now), num(self.sim)
                if a and b and math.abs(b - a) > 0.004 then
                    local d = b - a
                    GameTooltip:AddDoubleLine("Change:", (PCT[self.key] and string.format("%+.2f%%", d))
                        or string.format("%+d", math.floor(d + (d > 0 and 0.5 or -0.5))), 0.6, 0.6, 0.6,
                        d > 0 and 0.3 or 0.95, d > 0 and 0.9 or 0.35, d > 0 and 0.4 or 0.3)
                end
                if NOTES[self.key] then GameTooltip:AddLine(NOTES[self.key], 0.6, 0.6, 0.6, true) end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            statRows[#statRows + 1] = row
            y = y + ROW_H
        end
        y = y + 6
    end
    body:SetHeight(y)

    local function updateStats()
        local live, sim = ns:SimulateStats(simDB().slots, ns:EquippedLinks())
        local up, down, text = Skin:Color("upgrade"), Skin:Color("downgrade"), Skin:Color("text")
        for _, row in ipairs(statRows) do
            local a, b = live[row.key], sim[row.key]
            row.now, row.sim = a, b
            row.value:SetText(fmt(row.key, b))
            local na, nb = num(a), num(b)
            local c = text
            if na and nb and nb - na > 0.004 then c = up elseif na and nb and na - nb > 0.004 then c = down end
            row.value:SetTextColor(c[1], c[2], c[3], 1)
        end
    end

    -----------------------------------------------------------------------
    -- Item picker
    -----------------------------------------------------------------------
    local picker = Skin:Panel(panel, "panel", "border")
    picker:SetPoint("TOPLEFT", stats, "TOPRIGHT", GAP, 0)
    picker:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)

    local pTitle = Skin:Text(picker, Skin.SIZE.header, "accent")
    pTitle:SetPoint("TOPLEFT", 8, -8)
    local pCount = Skin:Text(picker, Skin.SIZE.small, "textDim")
    pCount:SetPoint("TOPRIGHT", -8, -10)
    pCount:SetJustifyH("RIGHT")

    local search = Skin:EditBox(picker, 100)
    search:SetPoint("TOPLEFT", 6, -28)
    search:SetPoint("TOPRIGHT", -6, -28)
    search:SetPlaceholder("Search this slot by name")

    -- Level range: "Level [min] – [max]", by the level an item can be worn at (EffectiveLevel).
    -- An empty box is open-ended below and "my level" above (shown as the placeholder), so the
    -- default follows level-ups; type a higher max to plan ahead. Saved per character.
    local lvl = CreateFrame("Frame", nil, picker)
    lvl:SetHeight(Skin.CONTROL_H)
    lvl:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -4)
    lvl:SetPoint("RIGHT", picker, "RIGHT", -6, 0)
    local lvlLabel = Skin:Text(lvl, Skin.SIZE.small, "textDim")
    lvlLabel:SetPoint("LEFT", 2, 0)
    lvlLabel:SetText("Level")
    local minBox = Skin:EditBox(lvl, 40, true)
    minBox:SetMaxLetters(2)
    minBox:SetPoint("LEFT", lvlLabel, "RIGHT", 6, 0)
    minBox:SetPlaceholder("1")
    local lvlDash = Skin:Text(lvl, Skin.SIZE.small, "textDim")
    lvlDash:SetPoint("LEFT", minBox, "RIGHT", 4, 0)
    lvlDash:SetText("-")
    local maxBox = Skin:EditBox(lvl, 40, true)
    maxBox:SetMaxLetters(2)
    maxBox:SetPoint("LEFT", lvlDash, "RIGHT", 4, 0)
    local lvlHint = Skin:Text(lvl, Skin.SIZE.small, "textDim")
    lvlHint:SetPoint("LEFT", maxBox, "RIGHT", 8, 0)
    lvlHint:SetPoint("RIGHT", lvl, "RIGHT", 0, 0)
    lvlHint:SetJustifyH("LEFT")
    lvlHint:SetWordWrap(false)
    minBox:SetScript("OnTabPressed", function() maxBox:SetFocus() end)
    maxBox:SetScript("OnTabPressed", function() minBox:SetFocus() end)
    for _, box in ipairs({ minBox, maxBox }) do
        box:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Level range")
            GameTooltip:AddLine("Lists items you can wear between these levels. Leave the first box empty for "
                .. "no lower limit, and the second empty for your current level.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        box:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- "Empty this slot": pinned above the list, so it never scrolls away or ends up below items.
    local clearRow = CreateFrame("Button", nil, picker)
    clearRow:SetHeight(24)
    clearRow:SetPoint("TOPLEFT", lvl, "BOTTOMLEFT", 0, -4)
    clearRow:SetPoint("RIGHT", picker, "RIGHT", -6, 0)
    Skin:BarRow(clearRow, 24)
    clearRow:SetBarStyle("item")
    clearRow:SetBarQuality(nil, "accent")
    clearRow.name = Skin:Text(clearRow, Skin.SIZE.normal, "textDim")
    clearRow.name:SetPoint("LEFT", clearRow, "LEFT", clearRow.barContentX, 0)
    clearRow.name:SetText("Empty this slot")
    clearRow:SetScript("OnClick", function()
        ns:SimSetSlot(state.slot, nil)
        refreshAll()
    end)

    local listBox = CreateFrame("Frame", nil, picker)
    listBox:SetPoint("TOPLEFT", clearRow, "BOTTOMLEFT", 0, -2)
    listBox:SetPoint("BOTTOMRIGHT", -6, 6)

    local list
    local weights, ctx

    local function rowScore(link)
        if not link then return 0 end
        local id = ns.LinkToId(link)
        local item = (ns.LinkBonus(link) and ns:ItemFromLink(link)) or (id and ns:GetItem(id))
        return item and ns:Score(item, weights, ctx) or 0
    end

    local function fillRow(row, d)
        row:SetBarStyle(d.kind == "note" and "plain" or "item")
        row.score:SetText("")
        if d.kind == "item" or d.kind == "worn" then
            local item = d.item
            row:SetBarQuality(item.q)
            row:SetBarIcon(ns.ItemIcon(d.id))
            row:SetBarDimmed(false)
            local name = ns.QualityHex(item.q or 1) .. (item.n or ("Item " .. d.id)) .. "|r"
                .. (ns:IsIgnored(d.id) and (" " .. Skin:Hex("textDim") .. "(ignored)|r") or "")
            row.name:SetText(d.kind == "worn" and (Skin:Hex("textDim") .. "Wearing:|r " .. name) or name)
            local delta = d.score - state.current
            local dc = math.abs(delta) < 0.05 and "textDim" or (delta > 0 and "upgrade" or "downgrade")
            row.score:SetText(string.format("%.1f %s(%+.1f)|r", d.score, Skin:Hex(dc), delta))
        else
            row:SetBarQuality(nil, "accent")
            row:SetBarIcon(nil)
            row.name:SetText(Skin:Hex("textDim") .. d.text .. "|r")
        end
    end

    list = Skin:List(listBox, {
        rowHeight = 26, rowGap = 2, barRows = true,
        createRow = function(row)
            row.name = Skin:Text(row, Skin.SIZE.normal, "text")
            row.name:SetPoint("LEFT", row, "LEFT", row.barContentX, 0)
            row.name:SetPoint("RIGHT", row, "RIGHT", -70, 0)
            row.name:SetWordWrap(false)
            row.score = Skin:Text(row, Skin.SIZE.small, "text")
            row.score:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row.score:SetJustifyH("RIGHT")
        end,
        fillRow = fillRow,
        onClick = function(row, d, button)
            if button ~= "LeftButton" then return end
            if (d.kind == "item" or d.kind == "worn") and IsModifiedClick and IsModifiedClick("CHATLINK") then
                if ChatEdit_InsertLink then ChatEdit_InsertLink(itemLinkFor(d.link)) end
                return
            end
            if d.kind == "item" or d.kind == "worn" then
                ns:SimSetSlot(state.slot, d.link)
            else
                return
            end
            refreshAll()
        end,
        onEnter = function(row, d)
            if d.kind == "worn" then
                GameTooltip:SetOwner(row, "ANCHOR_NONE")
                GameTooltip:SetPoint("TOPLEFT", panel, "TOPRIGHT", 8, 0)
                GameTooltip:SetHyperlink(d.link)
                GameTooltip:Show()
            elseif d.kind == "item" then
                ns:ShowItemTooltip(row, d.id, { score = d.score, delta = d.score - state.current, beside = panel })
            end
        end,
        onLeave = function() GameTooltip:Hide() end,
    })
    list.frame:SetAllPoints(listBox)

    local function isSelectedRow(d)
        local cur = simDB().slots[state.slot]
        return (d.kind == "item" or d.kind == "worn") and cur ~= nil and sameItem(cur, d.link)
    end

    local function updatePicker()
        weights, ctx = ns:GetScoringContext()
        local slot = state.slot
        local cur = simDB().slots[slot]
        state.current = rowScore(cur)
        pTitle:SetText(SLOT_LABELS[slot])
        search:SetPlaceholder("Search " .. SLOT_LABELS[slot]:lower() .. " items by name")
        clearRow:SetBarIcon(emptySlotTexture(slot))
        clearRow:SetBarDimmed(true)
        clearRow:SetBarSelected(cur == nil)  -- the slot is empty now
        local class, level = ns:GetPlayerClass(), UnitLevel("player") or 1
        local db = simDB()
        local minL, maxL = db.minL or 1, db.maxL or level
        maxBox:SetPlaceholder(tostring(level))
        lvlHint:SetText((db.minL or db.maxL) and "" or "up to your level")
        local text = (state.text or ""):lower()
        local rows, items = {}, {}
        local worn = GetInventoryItemLink("player", slot)
        if worn then
            local id = ns.LinkToId(worn)
            local item = ns:ItemFromLink(worn) or ns:GetItem(id)
            if item then
                rows[#rows + 1] = { kind = "worn", id = id, item = item, link = itemString(worn), score = rowScore(itemString(worn)) }
            end
        end
        for _, id in ipairs(ns:AllItemIds()) do
            local item = ns:GetItem(id)
            local eff = item and ns.EffectiveLevel(item)
            if item and eff >= minL and eff <= maxL and ns.SimSlotFits(slot, item.eq, class)
                and ns:IsUsable(item, class, math.max(level, eff))
                and (text == "" or ns.NameMatches(item.n, text)) then
                items[#items + 1] = { kind = "item", id = id, item = item, link = "item:" .. id,
                    score = ns:Score(item, weights, ctx) }
            end
        end
        table.sort(items, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.id < b.id
        end)
        for _, d in ipairs(items) do rows[#rows + 1] = d end
        if #items == 0 then
            rows[#rows + 1] = { kind = "note", text = (text ~= "" and "No matching items for this slot")
                or ((db.minL or db.maxL) and "No items for this slot in this level range")
                or "GearGuide has no items for this slot" }
        end
        pCount:SetText(string.format("%d item%s", #items, #items == 1 and "" or "s"))
        list:SetData(rows)
        list:SetSelected(isSelectedRow)
        if state.resetScroll then
            state.resetScroll = false
            list:ScrollToTop()
        end
    end

    local searchTimer
    -- A new slot starts with an empty search: text typed for daggers would hide every helmet.
    state.onSlotChange = function()
        if searchTimer then searchTimer:Cancel(); searchTimer = nil end
        state.text = ""
        state.quietSearch = true
        search:SetText("")
        search:ClearFocus()
        state.quietSearch = false
    end
    search:SetScript("OnTextChanged", function(self)
        if state.quietSearch then return end
        state.text = self:GetText() or ""
        if searchTimer then searchTimer:Cancel() end
        if C_Timer and C_Timer.NewTimer then
            searchTimer = C_Timer.NewTimer(0.2, function() searchTimer = nil; state.resetScroll = true; updatePicker() end)
        else
            state.resetScroll = true
            updatePicker()
        end
    end)
    local function onLevelChanged(_, userInput)
        if not userInput then return end
        local db = simDB()
        db.minL = tonumber(minBox:GetText())
        db.maxL = tonumber(maxBox:GetText())
        if searchTimer then searchTimer:Cancel() end
        if C_Timer and C_Timer.NewTimer then
            searchTimer = C_Timer.NewTimer(0.3, function() searchTimer = nil; state.resetScroll = true; updatePicker() end)
        else
            state.resetScroll = true
            updatePicker()
        end
    end
    minBox:HookScript("OnTextChanged", onLevelChanged)
    maxBox:HookScript("OnTextChanged", onLevelChanged)
    do  -- show the saved range
        local db = simDB()
        minBox:SetText(db.minL and tostring(db.minL) or "")
        maxBox:SetText(db.maxL and tostring(db.maxL) or "")
    end

    -----------------------------------------------------------------------
    -- Under the character window: saved builds bar, then the shopping list
    -----------------------------------------------------------------------
    local buildBar = CreateFrame("Frame", nil, column)
    buildBar:SetHeight(Skin.CONTROL_H)
    buildBar:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -GAP)
    buildBar:SetPoint("TOPRIGHT", holder, "BOTTOMRIGHT", 0, -GAP)

    local function hint(frame, title, text)
        frame:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(title, 1, 1, 1)
            GameTooltip:AddLine(text, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local delBtn = Skin:Button(buildBar, "Delete", 56, Skin.CONTROL_H)
    delBtn:SetPoint("RIGHT", buildBar, "RIGHT", 0, 0)
    local saveBtn = Skin:Button(buildBar, "Save", 48, Skin.CONTROL_H)
    saveBtn:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)

    local NEW_BUILD, EXPORT_BUILD, IMPORT_BUILD = "\001new", "\001export", "\001import"
    local buildSel = Skin:Dropdown(buildBar, 120, {
        getItems = function()
            local out = {}
            local active, changed = ns:SimActiveBuild()
            if not active then out[1] = { value = "", text = "Unsaved set" } end
            local names = {}
            for _, b in ipairs(ns:SimBuilds()) do names[#names + 1] = b.name end
            table.sort(names, function(a, b) return a:lower() < b:lower() end)
            for _, n in ipairs(names) do
                out[#out + 1] = { value = n, text = n .. ((n == active and changed) and " *" or "") }
            end
            out[#out + 1] = { value = NEW_BUILD, text = Skin:Hex("accent") .. "New build...|r" }
            out[#out + 1] = { value = EXPORT_BUILD, text = Skin:Hex("accent") .. "Share this set...|r" }
            out[#out + 1] = { value = IMPORT_BUILD, text = Skin:Hex("accent") .. "Import a build...|r" }
            return out
        end,
        getValue = function() return ns:SimActiveBuild() or "" end,
        onSelect = function(v)
            if v == NEW_BUILD then state.startNaming()
            elseif v == EXPORT_BUILD then state.openShare("export")
            elseif v == IMPORT_BUILD then state.openShare("import")
            elseif v ~= "" and ns:SimLoadBuild(v) then refreshAll() end
        end,
        prefix = "Build",
        maxVisible = 14,
        tooltip = { "Saved builds", "Pick a build to load it into the simulator, or \"New build...\" to save "
            .. "this set under a name. A * means the set changed since it was saved." },
    })
    buildSel:SetPoint("LEFT", buildBar, "LEFT", 0, 0)
    buildSel:SetPoint("RIGHT", saveBtn, "LEFT", -4, 0)

    local nameBox = Skin:EditBox(buildBar, 120)
    nameBox:SetMaxLetters(32)
    nameBox:SetPoint("LEFT", buildBar, "LEFT", 0, 0)
    nameBox:SetPoint("RIGHT", saveBtn, "LEFT", -4, 0)
    nameBox:SetPlaceholder("Build name, then Enter")
    nameBox:Hide()

    local function stopNaming()
        nameBox:Hide()
        buildSel:Show()
    end
    function state.startNaming()
        buildSel:Hide()
        nameBox:SetText("")
        nameBox:Show()
        nameBox:SetFocus()
    end
    local function saveAs(name)
        local ok, msg = ns:SimSaveBuild(name)
        if ok then
            ns.Print("Build saved: " .. msg .. ".")
            stopNaming()
            refreshAll()
        else
            ns.Print(msg)
        end
    end
    nameBox:HookScript("OnEnterPressed", function(self) saveAs(self:GetText()) end)
    nameBox:HookScript("OnEscapePressed", stopNaming)
    nameBox:HookScript("OnEditFocusLost", function() if not nameBox:HasFocus() then stopNaming() end end)

    saveBtn:SetScript("OnClick", function()
        if nameBox:IsShown() then saveAs(nameBox:GetText()) return end
        local active = ns:SimActiveBuild()
        if active then saveAs(active) else state.startNaming() end
    end)
    hint(saveBtn, "Save", "Saves this set into the chosen build (or asks for a name for a new one).")

    -- Delete asks for a second click within a few seconds.
    local armedAt
    delBtn:SetScript("OnClick", function()
        local active = ns:SimActiveBuild()
        if not active then return end
        local now = GetTime and GetTime() or 0
        if armedAt and now - armedAt < 4 then
            armedAt = nil
            ns:SimDeleteBuild(active)
            ns.Print("Build deleted: " .. active .. ". The set stays in the simulator.")
            refreshAll()
        else
            armedAt = now
            ns.Print("Click Delete again to delete the build \"" .. active .. "\".")
        end
    end)
    hint(delBtn, "Delete", "Deletes the chosen build (click twice). The items stay in the simulator.")

    -- Share / import box: a text field over the simulator. Export fills it with the build string,
    -- selected for Ctrl+C; import takes a pasted string.
    local share = Skin:Panel(panel, "menu", "edge")
    share:SetSize(380, 112)
    share:SetPoint("CENTER", panel, "CENTER", 0, 40)
    share:SetFrameStrata("DIALOG")
    share:EnableMouse(true)
    share:Hide()
    local shareTitle = Skin:Text(share, Skin.SIZE.header, "accent")
    shareTitle:SetPoint("TOPLEFT", 10, -9)
    local shareHint = Skin:Text(share, Skin.SIZE.small, "textDim")
    shareHint:SetPoint("TOPLEFT", shareTitle, "BOTTOMLEFT", 0, -4)
    shareHint:SetPoint("RIGHT", share, "RIGHT", -10, 0)
    shareHint:SetJustifyH("LEFT")
    local shareBox = Skin:EditBox(share, 360)
    shareBox:SetPoint("TOPLEFT", 10, -50)
    shareBox:SetPoint("RIGHT", share, "RIGHT", -10, 0)
    local shareClose = Skin:Button(share, "Close", 70, Skin.CONTROL_H)
    shareClose:SetPoint("BOTTOMRIGHT", -10, 8)
    shareClose:SetScript("OnClick", function() share:Hide() end)
    local shareGo = Skin:Button(share, "Import", 70, Skin.CONTROL_H)
    shareGo:SetPoint("RIGHT", shareClose, "LEFT", -6, 0)
    local function doImport()
        local ok, msg = ns:SimImportBuild(shareBox:GetText())
        if ok then
            ns.Print("Build imported: " .. msg .. ".")
            share:Hide()
            refreshAll()
        else
            ns.Print(msg)
        end
    end
    shareGo:SetScript("OnClick", doImport)
    shareBox:HookScript("OnEnterPressed", function() if share.mode == "import" then doImport() end end)
    shareBox:HookScript("OnEscapePressed", function() share:Hide() end)
    function state.openShare(mode)
        share.mode = mode
        if mode == "export" then
            local active = ns:SimActiveBuild()
            shareTitle:SetText("Share this set")
            shareHint:SetText("Press Ctrl+C to copy, then paste it to a friend. They use Import a build... in their Build menu.")
            shareBox:SetText(ns:SimExportBuild(active or "My build"))
            shareGo:Hide()
            share:Show()
            shareBox:SetFocus()
            shareBox:HighlightText()
        else
            shareTitle:SetText("Import a build")
            shareHint:SetText("Paste a GearGuide build (Ctrl+V), then Import. It's saved as a new build.")
            shareBox:SetText("")
            shareGo:Show()
            share:Show()
            shareBox:SetFocus()
        end
    end
    panel:HookScript("OnHide", function() share:Hide() end)

    local function updateBuilds()
        armedAt = nil
        buildSel:Refresh()
        if ns:SimActiveBuild() then delBtn:Enable() else delBtn:Disable() end
    end

    -- Shopping list -----------------------------------------------------------
    local shop = Skin:Panel(column, "panel", "border")
    shop:SetPoint("TOPLEFT", buildBar, "BOTTOMLEFT", 0, -GAP)
    shop:SetPoint("TOPRIGHT", buildBar, "BOTTOMRIGHT", 0, -GAP)
    shop:SetPoint("BOTTOMLEFT", column, "BOTTOMLEFT", 0, 0)
    local shopTitle = Skin:Text(shop, Skin.SIZE.header, "accent")
    shopTitle:SetPoint("TOPLEFT", 8, -7)
    shopTitle:SetText("Where to get this set")
    local shopCount = Skin:Text(shop, Skin.SIZE.small, "textDim")
    shopCount:SetPoint("TOPRIGHT", -8, -9)
    shopCount:SetJustifyH("RIGHT")
    local shopBox = CreateFrame("Frame", nil, shop)
    shopBox:SetPoint("TOPLEFT", 4, -26)
    shopBox:SetPoint("BOTTOMRIGHT", -4, 4)

    local shopList = Skin:List(shopBox, {
        rowHeight = 22, rowGap = 1, barRows = true,
        createRow = function(row)
            row.name = Skin:Text(row, Skin.SIZE.normal, "text")
            row.name:SetPoint("LEFT", row, "LEFT", row.barContentX, 0)
            row.name:SetWordWrap(false)
            row.src = Skin:Text(row, Skin.SIZE.small, "textDim")
            row.src:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row.src:SetJustifyH("RIGHT")
            row.src:SetWordWrap(false)
            row.name:SetPoint("RIGHT", row.src, "LEFT", -6, 0)
        end,
        fillRow = function(row, d)
            row.src:SetText("")
            -- Places start at the left edge in copper; their items are indented under them.
            local indent = (d.kind == "item") and 14 or 0
            row:SetBarIndent(indent)
            row.name:ClearAllPoints()
            row.name:SetPoint("LEFT", row, "LEFT", d.kind == "item" and (row.barContentX + indent) or 8, 0)
            row.name:SetPoint("RIGHT", row.src, "LEFT", -6, 0)
            if d.kind == "header" then
                row:SetBarStyle("header")
                row:SetBarQuality(nil, "accent")
                row:SetBarIcon(nil)
                row.name:SetText(Skin:Hex("accent") .. d.text .. "|r")
                row.src:SetText(string.format("%d item%s", d.count, d.count == 1 and "" or "s"))
                row.src:SetWidth(60)
            elseif d.kind == "item" then
                row:SetBarStyle("item")
                row:SetBarQuality(d.item and d.item.q)
                row:SetBarIcon(ns.ItemIcon(d.id))
                row.name:SetText(ns.QualityHex((d.item and d.item.q) or 1) .. ((d.item and d.item.n) or ("Item " .. d.id)) .. "|r")
                row.src:SetText(ns.ShopSourceText(d.source))
                row.src:SetWidth(math.floor((shopBox:GetWidth() or 300) * 0.45))
            else
                row:SetBarStyle("plain")
                row.name:SetText(Skin:Hex("textDim") .. d.text .. "|r")
            end
        end,
        onClick = function(row, d, button)
            if d.kind ~= "item" or button ~= "LeftButton" then return end
            if IsModifiedClick and IsModifiedClick("CHATLINK") then
                if ChatEdit_InsertLink then ChatEdit_InsertLink(itemLinkFor(d.link)) end
                return
            end
            if d.source then ns:ShowSourceOnMap(d.source) end
        end,
        onEnter = function(row, d)
            if d.kind ~= "item" then return end
            GameTooltip:SetOwner(row, "ANCHOR_NONE")
            GameTooltip:SetPoint("TOPLEFT", panel, "TOPRIGHT", 8, 0)
            GameTooltip:SetHyperlink(itemLinkFor(d.link))
            if d.source then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(ns.FormatSource(d.source), 1, 1, 1, true)
                if ns.HasLocation(d.source) then GameTooltip:AddLine("Click: show on the map", 0.4, 1, 0.6) end
            end
            GameTooltip:Show()
        end,
        onLeave = function() GameTooltip:Hide() end,
    })
    shopList.frame:SetAllPoints(shopBox)

    local function updateShop()
        local groups, need, total = ns:SimShoppingList()
        local rows = {}
        if total == 0 then
            rows[1] = { kind = "note", text = "Put items in the slots above to see where to get them." }
        elseif need == 0 then
            rows[1] = { kind = "note", text = "You have every item in this set." }
        end
        for _, g in ipairs(groups) do
            rows[#rows + 1] = { kind = "header", text = g.label, count = #g.items }
            for _, it in ipairs(g.items) do
                rows[#rows + 1] = { kind = "item", id = it.id, item = it.item, link = it.link, source = it.source }
            end
        end
        shopCount:SetText(total == 0 and "" or string.format("%d of %d to get", need, total))
        shopList:SetData(rows)
    end

    -----------------------------------------------------------------------
    -- Layout and refresh
    -----------------------------------------------------------------------
    -- Room kept under the character window for the builds bar and a few shopping list rows.
    local BELOW_MIN = GAP + Skin.CONTROL_H + GAP + 120
    local function layout()
        local w, h = panel:GetWidth() or 0, panel:GetHeight() or 0
        if w <= 0 or h <= 0 then return end
        local s = math.min(1.3, (h - BELOW_MIN) / DOLL_H, (w - STATS_W - PICKER_MIN - 2 * GAP) / DOLL_W)
        s = math.max(0.5, s)
        if math.abs((doll:GetScale() or 1) - s) > 0.001 then
            doll:SetScale(s)
            ns.Skin:RefreshPixels()  -- slot borders stay one pixel at the doll's scale
        end
        column:SetWidth(DOLL_W * s)
        holder:SetSize(DOLL_W * s, DOLL_H * s)  -- the border hugs the character page
    end
    panel:SetScript("OnSizeChanged", layout)

    -- Each part refreshes on its own: an error in one (the game hides Lua errors by default) can't
    -- stop the others, and it's printed in chat once so it can be reported.
    local reported = {}
    local function safe(name, fn)
        local ok, err = pcall(fn)
        if not ok and not reported[name] then
            reported[name] = true
            ns.Print("Build Simulator error (" .. name .. "): " .. tostring(err))
        end
    end
    function refreshAll()
        safe("slots", updateSlots)
        safe("model", dressModel)
        safe("stats", updateStats)
        safe("item list", updatePicker)
        safe("builds", updateBuilds)
        safe("shopping list", updateShop)
    end

    function panel:Refresh()
        layout()
        refreshAll()
    end

    -- Live stats change with gear, buffs and level; item data arrives in the background.
    local pending
    local events = CreateFrame("Frame", nil, panel)
    for _, e in ipairs({ "PLAYER_EQUIPMENT_CHANGED", "UNIT_STATS", "UNIT_AURA", "PLAYER_LEVEL_UP",
        "GET_ITEM_INFO_RECEIVED", "UNIT_ATTACK_POWER", "UNIT_RESISTANCES", "BAG_UPDATE_DELAYED" }) do
        pcall(events.RegisterEvent, events, e)
    end
    events:SetScript("OnEvent", function(_, event, unit)
        if not panel:IsVisible() then return end
        if (event == "UNIT_STATS" or event == "UNIT_AURA" or event == "UNIT_ATTACK_POWER"
            or event == "UNIT_RESISTANCES") and unit ~= "player" then return end
        if pending then return end
        pending = true
        local function run()
            pending = false
            if not panel:IsVisible() then return end
            safe("slots", updateSlots)
            safe("stats", updateStats)
            if event == "GET_ITEM_INFO_RECEIVED" and state.missing then safe("model", function() dressModel(true) end) end
            if event ~= "UNIT_AURA" then
                safe("item list", updatePicker)
                safe("shopping list", updateShop)  -- something looted or bought is off the list
            end
        end
        if C_Timer and C_Timer.After then C_Timer.After(0.2, run) else run() end
    end)

    panel:SetScript("OnShow", function() panel:Refresh() end)
    panel.state, panel.pickerList, panel.clearRow = state, list, clearRow  -- (tests)
    panel.minBox, panel.maxBox = minBox, maxBox
    panel.characterPane = holder  -- the window centers its watermark here on this tab
    panel.buildSel, panel.saveBtn, panel.delBtn, panel.nameBox = buildSel, saveBtn, delBtn, nameBox
    panel.shopList, panel.shopCount = shopList, shopCount
    panel.share, panel.shareBox, panel.shareGo = share, shareBox, shareGo
    return panel
end
