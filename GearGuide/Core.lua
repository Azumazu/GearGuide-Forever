local addonName, ns = ...
_G.GearGuide = ns

ns.QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
ns.GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local DATA_TTL_SECONDS = 30 * 24 * 3600
local SUPPORTED_DB_FORMAT = 3

local defaults = {
    minimap = { angle = 225, hide = false },
    levelBehind = 5,  -- recommend items whose required level is up to this many levels below you
    levelAhead = 3,   -- ...and up to this many levels above you (things to aim for)
    showUnknown = false,  -- list items nobody knows a source for (favorites always show)
    window = { w = 760, h = 480, scale = 1 },
    -- autoPopup: open the mini tracker when entering a zone/instance with recommended items
    mini = { shown = false, count = 10, hideCompleted = false, autoPopup = true, opacity = 1, pvpHide = true, scale = 1,
             hoverMode = false },
    minQuality = 2,   -- lowest item quality recommended (2 = Uncommon)
    map = { routes = true, waypoint = false },  -- draw patrol routes; set a waypoint arrow (game / TomTom)
    creatureTips = true,  -- list the gear a creature drops on its tooltip
    -- ...which gear (CreatureTips.lua): upgrades/usable/all, lowest quality, level bracket, BoE world drops
    tipDrops = { show = "upgrades", minQuality = 2, bracket = "range", world = true },
    announceDrops = true, -- "New drop location discovered for [item]" when looting a new source
    -- "Gear Acquired" pop-up (Toast.lua): on/off, locked in place, width, scale; point = saved position
    toast = { shown = true, locked = false, w = 300, scale = 1 },
    -- Appearance (Skin.lua): color theme, hand-picked colors over it (colors[key] = {r, g, b}), window
    -- border style and size (borderSize nil = the style's own), blue/orange upgrade numbers, text size
    skin = { theme = "copper", colors = {}, border = "solid", colorblind = false, textScale = 1 },
    -- Gear Browser "Additional drops": mounts and toys listed (with their sources, also on item and
    -- creature/vendor tooltips). Off by default: GearGuide is about gear.
    extras = { mounts = false, toys = false, recipes = false },
    levelUpGear = true,   -- on level up, list bag/bank gear you can now wear that's an upgrade (Tracking.lua)
}

local function applyDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then dst[k] = {} end
            applyDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

function ns.Print(...)
    print("|cff33ff99GearGuide|r:", ...)
end

-- Newer clients (Forever included) can hand addons "secret" values, e.g. a unit's GUID or name in
-- some situations: they may be passed around but not used as table keys, compared or string-
-- processed. ns.Plain(v) returns v when it's a normal value and nil when it's secret.
function ns.Plain(v)
    if v ~= nil and issecretvalue and issecretvalue(v) then return nil end
    return v
end

function ns.LinkToId(link)
    if type(link) == "number" then return link end
    return link and tonumber(link:match("item:(%d+)"))
end

---------------------------------------------------------------------------
-- Display helpers shared by all UI files
---------------------------------------------------------------------------
function ns.QualityHex(q)
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q or 1]
    return (c and c.hex) or "|cffffffff"
end

---------------------------------------------------------------------------
-- Reputation requirements (Data.lua item.rp = { faction id, standing }: "Requires Honored with
-- Timbermaw Hold"). standing is the game's standingID: 4 Neutral ... 8 Exalted.
---------------------------------------------------------------------------
local STANDING_NAMES = { "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }
local STANDING_START = { -42000, -6000, -3000, 0, 3000, 9000, 21000, 42000 }  -- reputation where each begins

function ns.StandingName(s)
    return _G["FACTION_STANDING_LABEL" .. tostring(s)] or STANDING_NAMES[s] or ("standing " .. tostring(s))
end

-- "Revered" (the client's own words first) -> 7.
function ns.StandingFromName(text)
    for i = 1, 8 do
        if text == _G["FACTION_STANDING_LABEL" .. i] or text == STANDING_NAMES[i] then return i end
    end
end

-- A faction's ID from its name, among the factions the player has met (nil when not listed).
function ns.FactionIdByName(name)
    if not name then return nil end
    if C_Reputation and C_Reputation.GetNumFactions and C_Reputation.GetFactionDataByIndex then
        for i = 1, (C_Reputation.GetNumFactions() or 0) do
            local ok, d = pcall(C_Reputation.GetFactionDataByIndex, i)
            if ok and type(d) == "table" and d.name == name and d.factionID then return d.factionID end
        end
    end
    if GetNumFactions and GetFactionInfo then
        for i = 1, (GetNumFactions() or 0) do
            local n, _, _, _, _, _, _, _, _, _, _, _, _, fid = GetFactionInfo(i)
            if n == name and fid then return fid end
        end
    end
end

local function thousands(n)
    local s = tostring(math.floor(n + 0.5))
    while true do
        local t, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        s = t
        if k == 0 then return s end
    end
end

-- The player's standing with a faction: name, standingID, reputation value (nil when unknown).
function ns:FactionStanding(faction)
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local ok, d = pcall(C_Reputation.GetFactionDataByID, faction)
        if ok and type(d) == "table" and d.name then return d.name, d.reaction, d.currentStanding end
    end
    if GetFactionInfoByID then
        local ok, name, _, standing, _, _, value = pcall(GetFactionInfoByID, faction)
        if ok and name then return name, standing, value end
    end
end

-- { faction, standing, name, have = your standing, met, toGo = reputation still needed } or nil.
function ns:ReputationNeed(id)
    local item = GearGuide_Data and GearGuide_Data.items and GearGuide_Data.items[id]
    local rp = item and item.rp
    if type(rp) ~= "table" or not rp[1] or not rp[2] then
        -- Read from a vendor's tooltip in game (Sources.lua): WoW: Forever's own factions.
        local learned = GearGuideLearned and GearGuideLearned.reps and GearGuideLearned.reps[id]
        if type(learned) ~= "table" or not learned.s then return nil end
        local fid = learned.f or ns.FactionIdByName(learned.n)
        if not fid then return { standing = learned.s, name = learned.n } end
        rp = { fid, learned.s }
    end
    local name, standing, value = self:FactionStanding(rp[1])
    local need = { faction = rp[1], standing = rp[2], name = name, have = standing }
    if standing then
        need.met = standing >= rp[2]
        if not need.met and value and STANDING_START[rp[2]] then need.toGo = math.max(0, STANDING_START[rp[2]] - value) end
    end
    return need
end

-- "Requires Honored with Timbermaw Hold (you: Friendly, 2,400 to go)", met (true/false/nil unknown).
function ns:ReputationText(id)
    local r = self:ReputationNeed(id)
    if not r then return nil end
    local text = "Requires " .. ns.StandingName(r.standing) .. (r.name and (" with " .. r.name) or " reputation")
    if r.have and not r.met then
        text = text .. " (you: " .. ns.StandingName(r.have) .. (r.toGo and (", " .. thousands(r.toGo) .. " to go") or "") .. ")"
    end
    return text, r.met
end

-- Only while not reached: "2,400 reputation to Honored with Timbermaw Hold" (item tooltips; the game
-- itself already prints the requirement).
function ns:ReputationProgressText(id)
    local r = self:ReputationNeed(id)
    if not (r and r.have and not r.met) then return nil end
    local target = ns.StandingName(r.standing) .. (r.name and (" with " .. r.name) or "")
    if r.toGo then return thousands(r.toGo) .. " reputation to " .. target end
    return "You are " .. ns.StandingName(r.have) .. ", it needs " .. target
end

function ns.ItemIcon(id)
    local icon
    if C_Item and C_Item.GetItemIconByID then
        icon = C_Item.GetItemIconByID(id)
    elseif GetItemIcon then
        icon = GetItemIcon(id)
    end
    return icon or ns.QUESTION_ICON
end

---------------------------------------------------------------------------
-- Additional drops: mounts, toys and recipes (item.x = "m" mount, "t" toy candidate, "r" recipe;
-- shipped in Data.lua or learned in game). They are
-- not gear: never scored or recommended, only listed when their Gear Browser toggle is on.
-- Toy candidates are the build's "Miscellaneous - Other" items; the client's toy box says which
-- really are toys.
---------------------------------------------------------------------------
local EXTRA_KIND = { m = "mounts", t = "toys", r = "recipes" }
ns.EXTRA_KINDS = { "mounts", "toys", "recipes" }
function ns.ExtraKind(item) return type(item) == "table" and EXTRA_KIND[item.x] or nil end

function ns:ExtrasOn(kind)
    local e = GearGuideDB and GearGuideDB.extras
    return e ~= nil and e[kind] == true
end

function ns:SetExtras(kind, on)
    GearGuideDB.extras = GearGuideDB.extras or {}
    GearGuideDB.extras[kind] = on and true or false
    self:InvalidateSourceIndexes()  -- lists, tooltips and creature/vendor tips change
end

local toyConfirmed = {}
function ns:IsToy(id)
    if toyConfirmed[id] then return true end
    local get = C_ToyBox and C_ToyBox.GetToyInfo
    local ok, itemID = false, nil
    if get then ok, itemID = pcall(get, id) end
    if ok and itemID then toyConfirmed[id] = true; return true end
    return false  -- not a toy, or not known yet: asked again next time (cheap)
end

-- Is this item a mount or toy whose toggle is on (and, for toys, confirmed by the client)?
function ns:ExtraShown(id, item)
    item = item or self:GetItem(id)
    local kind = ns.ExtraKind(item)
    if not kind or not self:ExtrasOn(kind) then return false end
    return kind ~= "toys" or self:IsToy(id)
end

local extraIds
function ns:ExtraItemIds(kind)
    if not extraIds then
        extraIds = { mounts = {}, toys = {}, recipes = {} }
        local seen = {}
        for _, layer in ipairs({ GearGuide_Data.items or {}, GearGuideLearned and GearGuideLearned.items or {} }) do
            for id, item in pairs(layer) do
                local k = not seen[id] and ns.ExtraKind(item)
                if k then seen[id] = true; extraIds[k][#extraIds[k] + 1] = id end
            end
        end
        for _, list in pairs(extraIds) do table.sort(list) end
    end
    local out = {}
    for _, id in ipairs(extraIds[kind] or {}) do
        if kind ~= "toys" or self:IsToy(id) then out[#out + 1] = id end
    end
    return out
end

function ns:InvalidateExtraIds() extraIds = nil end

function ns.ExtraLabel(item)
    local kind = ns.ExtraKind(item)
    return kind == "mounts" and "Mount" or kind == "toys" and "Toy" or kind == "recipes" and "Recipe" or nil
end

function ns.SlotLabel(eq)
    local key = ns.EQUIPLOC_GROUP[eq]
    local g = key and ns.SLOT_GROUP_BY_KEY[key]
    return g and g.label or "?"
end

function ns:ClassName(class)
    local names = LOCALIZED_CLASS_NAMES_MALE
    return (names and names[class]) or (class:sub(1, 1) .. class:sub(2):lower())
end

function ns:ClassColorHex(class)
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c and c.colorStr then return "|c" .. c.colorStr end
    return "|cffffffff"
end

---------------------------------------------------------------------------
-- Item stats read from the game client (used for learned and equipped items)
---------------------------------------------------------------------------
local STAT_MAP = {
    ITEM_MOD_STRENGTH_SHORT = "STR", ITEM_MOD_AGILITY_SHORT = "AGI", ITEM_MOD_STAMINA_SHORT = "STA",
    ITEM_MOD_INTELLECT_SHORT = "INT", ITEM_MOD_SPIRIT_SHORT = "SPI", RESISTANCE0_NAME = "ARMOR",
    ITEM_MOD_DAMAGE_PER_SECOND_SHORT = "DPS", ITEM_MOD_ATTACK_POWER_SHORT = "AP",
    ITEM_MOD_RANGED_ATTACK_POWER_SHORT = "RAP", ITEM_MOD_SPELL_POWER_SHORT = "SP",
    ITEM_MOD_SPELL_DAMAGE_DONE_SHORT = "SP", ITEM_MOD_SPELL_HEALING_DONE_SHORT = "HEAL",
    ITEM_MOD_CRIT_RATING_SHORT = "CRIT", ITEM_MOD_HIT_RATING_SHORT = "HIT",
    ITEM_MOD_CRIT_SPELL_RATING_SHORT = "SCRIT", ITEM_MOD_HIT_SPELL_RATING_SHORT = "SHIT",
    ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = "DEF", ITEM_MOD_DODGE_RATING_SHORT = "DODGE",
    ITEM_MOD_PARRY_RATING_SHORT = "PARRY", ITEM_MOD_BLOCK_RATING_SHORT = "BLOCK",
    ITEM_MOD_BLOCK_VALUE_SHORT = "BLOCK", ITEM_MOD_MANA_REGENERATION_SHORT = "MP5",
    ITEM_MOD_POWER_REGEN0_SHORT = "MP5",
    -- Haste is new in WoW: Forever; these are the client's usual key names for it.
    ITEM_MOD_HASTE_RATING_SHORT = "HASTE", ITEM_MOD_HASTE_SPELL_RATING_SHORT = "HASTE",
    ITEM_MOD_HASTE_MELEE_RATING_SHORT = "HASTE", ITEM_MOD_HASTE_RANGED_RATING_SHORT = "HASTE",
    ITEM_MOD_EXPERTISE_RATING_SHORT = "EXPERTISE",
}
local getItemStats = (C_Item and C_Item.GetItemStats) or GetItemStats

-- A random bonus ("of the Eagle": +9 Stamina, +9 Intellect) is an enchantment on the item, and the
-- client's stat function leaves it out. Its tooltip lists it ("+9 Stamina"), so for items with a
-- bonus the "+N Stat" lines are read there. Stat name (lower case, the client's language) -> key.
local tipNames
local function tooltipStatNames()
    if tipNames then return tipNames end
    tipNames = {}
    for global, key in pairs(STAT_MAP) do
        local name = _G[global]
        if type(name) == "string" and key ~= "ARMOR" and key ~= "DPS" then tipNames[name:lower()] = key end
    end
    for i = 1, 6 do  -- "of Fire Resistance" (R2...): the Build Simulator's resistance keys
        local name = _G["RESISTANCE" .. i .. "_NAME"]
        if type(name) == "string" then tipNames[name:lower()] = "R" .. i end
    end
    return tipNames
end

local tipStatCache = {}
-- { key = total } of the "+N Stat" lines in the item's tooltip; nil when the client can't show it yet.
function ns.TooltipStats(link)
    if tipStatCache[link] then return tipStatCache[link] end
    if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink) then return nil end
    local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
    if not (ok and type(data) == "table" and type(data.lines) == "table" and data.lines[2]) then return nil end
    local names, out = tooltipStatNames(), {}
    for _, line in ipairs(data.lines) do
        local text = ns.Plain(line.leftText)
        local n, stat
        if text then n, stat = text:match("^%+(%d+) (.-)%.?$") end  -- (`text and ...` keeps only n)
        local key = stat and names[stat:lower()]
        if key then out[key] = (out[key] or 0) + tonumber(n) end
    end
    tipStatCache[link] = out
    return out
end

function ns.ReadStats(link)
    local out = {}
    local raw = getItemStats and getItemStats(link)
    if raw then
        for k, v in pairs(raw) do
            local key = STAT_MAP[k]
            if key then out[key] = (out[key] or 0) + v end
        end
    end
    if ns.LinkBonus(link) then
        -- The tooltip's lines are the base stats plus the bonus: the larger of the two counts, so a
        -- client that does include the bonus isn't counted twice.
        for key, v in pairs(ns.TooltipStats(link) or {}) do
            if not key:match("^R%d$") and v > (out[key] or 0) then out[key] = v end
        end
    end
    return out
end

-- Builds an item record (same shape as Data.lua entries) from the client cache.
-- Returns nil when the client hasn't cached the item yet.
function ns:ItemFromLink(link)
    local name, _, q, il, rl, _, _, _, eq, _, _, c, sc = ns.GetItemInfo(link)
    if not name then return nil end
    return { n = name, q = q, il = il, rl = rl, eq = eq, c = c, sc = sc, st = ns.ReadStats(link) }
end

---------------------------------------------------------------------------
-- Random variants ("Cross Dagger of the Falcon"): the same item id with a random bonus. The bonus
-- (suffix id) is the 7th field of the link: item:id:enchant:gem1:gem2:gem3:gem4:suffix:...
---------------------------------------------------------------------------
function ns.LinkSuffix(link)
    if type(link) ~= "string" then return nil end
    local s = tonumber(link:match("item:%-?%d+:[^:|]*:[^:|]*:[^:|]*:[^:|]*:[^:|]*:(%-?%d+)"))
    if s and s ~= 0 then return s end
end

-- Whether the link carries a random bonus, in either form: the classic suffix field, or (how the
-- WoW: Forever client links them) bonus ids after the 13th field:
--   item:10777::::::::42:1488::1:1:13171:1:28:5245  -> 1 bonus id, 13171
-- Returns a key naming the bonus ("s604", "b13171") or nil. Stats then come from the tooltip.
-- Memoized per link (tooltips, bags and the party view ask for the same links again and again).
local bonusMemo, bonusCount = {}, 0
local linkBonus
function ns.LinkBonus(link)
    if type(link) ~= "string" then return linkBonus(link) end
    local v = bonusMemo[link]
    if v == nil then
        if bonusCount >= 500 then wipe(bonusMemo); bonusCount = 0 end
        v = linkBonus(link) or false
        bonusMemo[link], bonusCount = v, bonusCount + 1
    end
    return v or nil
end

function linkBonus(link)
    local s = ns.LinkSuffix(link)
    if s then return "s" .. s end
    local body = type(link) == "string" and link:match("item:([%-%d:]*)")
    if not body then return nil end
    local f = {}
    for v in (body .. ":"):gmatch("([^:]*):") do f[#f + 1] = v end
    local n = tonumber(f[13])
    if not n or n < 1 then return nil end
    local ids = {}
    for i = 14, 13 + n do
        if tonumber(f[i]) then ids[#ids + 1] = f[i] end
    end
    if #ids > 0 then return "b" .. table.concat(ids, ",") end
end

function ns.VariantLink(id, suffix)
    return "item:" .. id .. ":0:0:0:0:0:" .. suffix
end

-- Data.lua packs map coordinates and random-variant groups into strings ("48.2,42.9,..."; a Lua
-- table would cost 16+ bytes per number for data that's only read when a map or item details
-- open). ns.Numbers: such a string (or an already unpacked list) -> list of numbers.
function ns.Numbers(v)
    if type(v) ~= "string" then return v end
    local out = {}
    for n in v:gmatch("[^,]+") do out[#out + 1] = tonumber(n) end
    return out
end

-- "x,y,x,y;x,y,..." (routes, area outlines) -> { {x, y, ...}, ... }; lists pass through.
function ns.NumberLists(v)
    if type(v) ~= "string" then return v end
    local out = {}
    for part in v:gmatch("[^;]+") do out[#out + 1] = ns.Numbers(part) end
    return out
end

local randomGroups = {}  -- group -> unpacked { suffix, chance, ... }
local function randomGroup(g)
    local packed = g and GearGuide_Data.randoms and GearGuide_Data.randoms[g]
    if packed == nil then return nil end
    if not randomGroups[g] then randomGroups[g] = ns.Numbers(packed) end
    return randomGroups[g]
end

-- { { p = suffix id, c = chance % (nil: only seen in game) }, ... }: the shipped group, most likely
-- first (Data.lua R[item.rg] = "suffix,chance,..."), then suffixes players looted that it lacks.
function ns:GetVariants(id)
    local out, seen = {}, {}
    local db = GearGuide_Data.items[id]
    local group = db and randomGroup(db.rg)
    if group then
        for i = 1, #group - 1, 2 do
            out[#out + 1] = { p = group[i], c = group[i + 1] }
            seen[group[i]] = true
        end
    end
    local learned = GearGuideLearned and GearGuideLearned.variants and GearGuideLearned.variants[id]
    if learned then
        local extra = {}
        for p in pairs(learned) do if not seen[p] then extra[#extra + 1] = p end end
        table.sort(extra)
        for _, p in ipairs(extra) do out[#out + 1] = { p = p } end
    end
    return out
end

function ns:RememberVariant(id, suffix)
    if not (id and suffix and GearGuideLearned) then return end
    GearGuideLearned.variants = GearGuideLearned.variants or {}
    local v = GearGuideLearned.variants[id] or {}
    GearGuideLearned.variants[id] = v
    v[suffix] = true
end

-- Name ("Cross Dagger of the Falcon"), suffix ("of the Falcon"), total stats and the bonus over the
-- base item, all from the game client. nil while the client doesn't have the item yet.
local variantCache = {}
function ns:VariantInfo(id, suffix)
    local key = id .. ":" .. suffix
    if variantCache[key] then return variantCache[key] end
    local link = ns.VariantLink(id, suffix)
    local name
    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then  -- the tooltip title carries the suffix
        local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
        local line = ok and type(data) == "table" and data.lines and data.lines[1]
        name = line and ns.Plain(line.leftText)
    end
    name = name or ns.GetItemInfo(link)
    local baseName = ns.GetItemInfo(id)
    if not name or not baseName then return nil end
    local st, base = ns.ReadStats(link), ns.ReadStats("item:" .. id)
    local bonus = {}
    for k, v in pairs(st) do
        local d = v - (base[k] or 0)
        if d ~= 0 then bonus[k] = d end
    end
    local sfx = name:sub(1, #baseName) == baseName and name:sub(#baseName + 2) or ""
    local info = { name = name, suffix = sfx ~= "" and sfx or nil, st = st, bonus = bonus, link = link }
    variantCache[key] = info
    return info
end

-- The variant's suffix id (what the shipped groups and VariantLink use) for a link of either form.
-- A WoW: Forever link has a bonus id instead, so its name ("Sentinel Girdle of the Bandit") is
-- matched against the item's variants. nil: no bonus, an unknown one, or the client still loading.
local variantByBonus = {}
function ns:LinkVariant(link)
    local s = ns.LinkSuffix(link)
    if s then return s end
    local bonus = ns.LinkBonus(link)
    local id = bonus and ns.LinkToId(link)
    if not id then return nil end
    local key = id .. ":" .. bonus
    if variantByBonus[key] ~= nil then return variantByBonus[key] or nil end
    local name = (type(link) == "string" and link:match("|h%[(.-)%]|h")) or ns.GetItemInfo(link)
    if not name then return nil end
    local pending = false
    for _, v in ipairs(self:GetVariants(id)) do
        local info = self:VariantInfo(id, v.p)
        if info and info.name == name then
            variantByBonus[key] = v.p
            return v.p
        end
        pending = pending or info == nil
    end
    if not pending then variantByBonus[key] = false end  -- every variant checked: not one of them
    return nil
end

---------------------------------------------------------------------------
-- Item access: generated database merged with items learned in game
---------------------------------------------------------------------------
-- Three layers: items scanned from this game client (newest), the shipped/generated Data.lua,
-- and items learned from loot/quest/vendor windows.
function ns:GetItem(id)
    return GearGuideHarvest.items[id] or GearGuide_Data.items[id] or GearGuideLearned.items[id]
end

-- Same rules as GearGuideTools/build_db.py excluded(), so a local /gg scan (which keeps whatever
-- the client knows) doesn't bring back developer test items the shipped database leaves out.
-- %f[...] is Lua 5.1's word-boundary ("frontier") pattern.
local JUNK_PATTERNS = { "^Monster %- ", "^zz", "^OLD", "%f[%a]OLD%f[%A]", "%(OLD%)", "Deprecated", "DEPRECATED",
    "%[PH%]", "UNUSED", "Unused", "%f[%a]QA%f[%A]", "DEBUG", "DELETE ME" }
function ns.IsJunkItem(item)
    local name = item.n or ""
    for _, pat in ipairs(JUNK_PATTERNS) do
        if name:find(pat) then return true end
    end
    local lower = name:lower()
    if lower:find("%f[%a]test%f[%A]") or lower:find("%f[%a]testing%f[%A]") or lower:find("qatest", 1, true) then
        return true  -- "Testament of Hope" is real and stays
    end
    if (item.rl or 0) > 60 or (item.q or 0) >= 6 then return true end  -- above WoW: Forever's cap; internal quality
    return false
end

function ns:AllItemIds()
    if self.idCache then return self.idCache end
    local list, seen = {}, {}
    -- Items the maintainer hid by source (corrections.json "_hide_sources", e.g. joke event loot):
    -- they're gone from Data.lua, and this keeps a local scan from bringing them back.
    for _, id in ipairs(GearGuide_Data.meta and GearGuide_Data.meta.hidden or {}) do seen[id] = true end
    for _, layer in ipairs({ GearGuideHarvest.items, GearGuide_Data.items, GearGuideLearned.items }) do
        for id in pairs(layer) do
            if not seen[id] then
                seen[id] = true
                -- Judge by the record GetItem returns (newest layer wins). Provisional raid items
                -- (pv, from the build's cmangos import) only count once the client has returned its
                -- own record for them (Harvest.lua VerifyProvisional).
                -- Shipped records were filtered by build_db.py with the same rules: only scanned and
                -- learned ones need the name checks (~200k pattern matches saved per rebuild).
                local item = self:GetItem(id)
                if not item.pv and not item.x  -- mounts and toys: ExtraItemIds
                    and (item == GearGuide_Data.items[id] or not ns.IsJunkItem(item)) then
                    list[#list + 1] = id
                end
            end
        end
    end
    self.idCache = list
    return list
end

function ns:InvalidateItems()
    self.idCache = nil
    self:InvalidateExtraIds()
    self:InvalidateSourceIndexes()
end

-- New sources may add dungeon or zone loot: the Gear Browser's Instance/Zone indexes are rebuilt
-- (only then: gear, level or settings changes don't touch them).
function ns:InvalidateSourceIndexes()
    self.instanceIndex, self.zoneIndex = nil, nil
    self:RequestRefresh()
end

-- "A" (Alliance) or "H" (Horde); nil before the faction is known (e.g. Pandaren choosing).
local knownFaction  -- asked per item in scans: remembered once known (it never changes)
function ns.PlayerFaction()
    if knownFaction then return knownFaction end
    local group = UnitFactionGroup and UnitFactionGroup("player")
    knownFaction = (group == "Alliance" and "A") or (group == "Horde" and "H") or nil
    return knownFaction
end

-- Creature name -> { { z = zone name, loc = locations }, ... } from shipped drop sources that have a
-- map location. Learned/shared/hand-added drops carry only a name and zone; they borrow the spot of
-- the same creature from here (zone must match: "Defias Bandit" lives in more than one zone).
local creatureLocs
local function locForCreature(name, z)
    if not creatureLocs then
        creatureLocs = {}
        local pool, locs = GearGuide_Data.sources or {}, GearGuide_Data.locs or {}
        for _, s in pairs(pool) do
            if type(s) == "table" and s.t == "drop" and s.k ~= "object" and s.n and s.l and locs[s.l] then
                local list = creatureLocs[s.n] or {}
                creatureLocs[s.n] = list
                list[#list + 1] = { z = ns.ZoneName(s.z), loc = locs[s.l] }
            end
        end
    end
    local list = creatureLocs[name]
    if not list then return nil end
    local zone = ns.ZoneName(z)
    for _, e in ipairs(list) do
        if not zone or e.z == zone then return e.loc, e.z end
    end
end

---------------------------------------------------------------------------
-- World drops (WorldDrops.lua, from cmangos' shared loot tables): BoE gear that hundreds of
-- creatures can drop. A creature links a few tables ("level 53-58 greens and blues") with its own
-- chance; each table yields one of its items, all equally likely unless x overrides one.
---------------------------------------------------------------------------

-- creatures, lowest level, highest level, usual chance% per kill, best chance% (or nil)
function ns:WorldDropInfo(id)
    local w = GearGuide_WorldDrops and GearGuide_WorldDrops.items[id]
    if w then return w[1], w[2], w[3], w[5] or w[4], w[4] end
end

-- { [itemID] = chance% } for one creature (by name), or nil. The last answer is kept: the same
-- creature's tooltip is built many times while the mouse rests on it.
local lastWorldName, lastWorldDrops
function ns:WorldDropsOf(name)
    if name == lastWorldName then return lastWorldDrops end
    local wd = GearGuide_WorldDrops
    local e = wd and name and wd.npc[name]
    local out
    if e then
        out = {}
        for i = 3, #e - 1, 2 do
            local ref, pick = wd.refs[e[i]], e[i + 1]
            if ref then
                for j = 2, #ref do
                    local id = ref[j]
                    local pct = pick * ((ref.x and ref.x[id]) or ref[1]) / 100
                    -- Linked through two tables: either one can drop it.
                    out[id] = 100 * (1 - (1 - (out[id] or 0) / 100) * (1 - pct / 100))
                end
            end
        end
    end
    lastWorldName, lastWorldDrops = name, out
    return out
end

-- World drops of the creatures that spawn in a zone (by name, as ns.ZoneName gives it):
-- { [itemID] = { usual chance% here, creatures here } }. The usual (median) chance, not the best:
-- the best is a rare spawn's. Kept per zone.
local worldByZone = {}
function ns:WorldDropsInZone(zoneName)
    local wd = GearGuide_WorldDrops
    if not (wd and zoneName and zoneName ~= "") then return {} end
    if worldByZone[zoneName] then return worldByZone[zoneName] end
    local chances = {}  -- itemID -> { chance%, ... }
    for name, e in pairs(wd.npc) do
        local here = false
        for _, area in ipairs(e.z or {}) do
            if ns.ZoneName(area) == zoneName then here = true break end
        end
        if here then
            for id, pct in pairs(self:WorldDropsOf(name) or {}) do
                local list = chances[id]
                if not list then list = {}; chances[id] = list end
                list[#list + 1] = pct
            end
        end
    end
    local out = {}
    for id, list in pairs(chances) do
        table.sort(list)
        out[id] = { list[math.floor(#list / 2) + 1], #list }
    end
    worldByZone[zoneName] = out
    return out
end

-- The world-drop line of an item's sources: "any of 712 creatures (level 38-61), each 0.03%".
local function worldSource(id)
    local n, lo, hi, usual = ns:WorldDropInfo(id)
    if not n then return nil end
    local levels = lo == hi and ("level " .. lo) or ("level " .. lo .. "-" .. hi)
    return { t = "world", n = string.format("any of %d creature%s (%s), each", n, n == 1 and "" or "s", levels),
             dc = usual, k = "boe" }
end

local function computeSources(self, id)
    local out, seen = {}, {}
    local faction = ns.PlayerFaction()
    local knownDroppers  -- shipped drop names, when the shipped data knows the item's loot table
    local function add(list)
        for _, s in ipairs(list or {}) do
            -- Zone by name: shipped sources hold area IDs, learned ones zone names, and the same
            -- vendor/quest giver must not be listed twice. The first (shipped, with map spot) wins.
            local key = (s.t or "") .. "|" .. (s.n or "") .. "|" .. tostring(ns.ZoneName(s.z) or s.z or "")
            -- Hide the other faction's quests, city vendors and PvP rewards.
            local mine = not s.f or not faction or s.f == faction
            -- Learned/shared drops from a creature that isn't in the item's known loot table are
            -- misattributed (older versions credited container loot to the targeted creature).
            local plausible = not (knownDroppers and s.t == "drop" and not knownDroppers[s.n or ""])
                and not (ns.IsJunkSourceName and ns.IsJunkSourceName(s.n))  -- nameless finds of older versions
            if mine and plausible and not seen[key] then seen[key] = true; out[#out + 1] = s end
        end
    end
    local dbItem = GearGuide_Data.items[id]
    if dbItem and dbItem.src then
        -- Format 2 stores each source once in GearGuide_Data.sources; items hold indices.
        local pool, locs, resolved = GearGuide_Data.sources, GearGuide_Data.locs, {}
        for i, s in ipairs(dbItem.src) do
            if type(s) == "number" then s = pool and pool[s] end
            if type(s) == "table" then
                -- dc[i]: drop chance (%) of this item from source i (the pooled source is shared).
                local dc = type(dbItem.dc) == "table" and dbItem.dc[i] or nil
                if dc == 0 then dc = nil end
                if (s.l and locs and locs[s.l] and not s.loc) or dc then
                    s = { t = s.t, n = s.n, z = s.z, k = s.k, f = s.f, loc = s.loc or (s.l and locs and locs[s.l]), dc = dc }
                end
                resolved[#resolved + 1] = s
            end
        end
        add(resolved)
        -- Only a real loot table (some source drops it at 1% or more, e.g. a raid boss) rules out
        -- other creatures. World drops (only tiny chances: a few chests and random creatures) can
        -- come from any creature of the right level, so learned drops of those stay.
        local best = 0
        for _, c in ipairs(type(dbItem.dc) == "table" and dbItem.dc or {}) do best = math.max(best, c) end
        if best >= 1 then
            knownDroppers = {}
            for _, s in ipairs(resolved) do
                if s.t == "drop" and s.n then knownDroppers[s.n] = true end
            end
        end
    end
    add(GearGuideLearned.sources[id])
    if ns.GetSharedSources then add(ns:GetSharedSources(id)) end  -- from other GearGuide users
    -- World drop: one line for all its creatures, after the item's real loot table (drops at 1%+)
    -- and in place of Questie's "... and N more creatures".
    local world = worldSource(id)
    if world then
        for i = #out, 1, -1 do
            local s = out[i]
            if s.t == "drop" and type(s.n) == "string" and s.n:find("^%.%.%. and %d+ more") then table.remove(out, i) end
        end
        local at = #out + 1
        for i, s in ipairs(out) do
            if s.t == "drop" and not (s.dc and s.dc >= 1) then at = i; break end
        end
        table.insert(out, at, world)
    end
    -- Drops without a location (learned, shared, hand-added): the same creature's shipped spot.
    for i, s in ipairs(out) do
        if s.t == "drop" and s.k ~= "object" and not s.loc and s.n then
            local loc, z = locForCreature(s.n, s.z)
            if loc then
                local c = {}
                for k, v in pairs(s) do c[k] = v end
                c.loc, c.z = loc, c.z or z
                out[i] = c
            end
        end
    end
    -- Creatures without a known location: where the player has found them (Sources.lua spots).
    local spots, spotZones = GearGuideLearned.spots or {}, GearGuideLearned.spotZones or {}
    for i, s in ipairs(out) do
        if (s.t == "drop" and s.k ~= "object" or s.t == "vendor") and not s.loc and s.n
            and (spots[s.n] or spotZones[s.n]) then
            local c = {}
            for k, v in pairs(s) do c[k] = v end
            local maps = {}
            for map, flat in pairs(spots[s.n] or {}) do
                if #flat >= 2 then maps[#maps + 1] = { m = map, p = flat } end
            end
            table.sort(maps, function(a, b) return #a.p > #b.p end)
            if #maps > 0 then c.loc = maps end
            if not c.z then
                local info = maps[1] and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(maps[1].m)
                c.z = (info and info.name) or spotZones[s.n]
            end
            out[i] = c
        end
    end
    -- Crafted: the recipe's own source ("Crafted: Leatherworking (Pattern: X)" -> the recipe item,
    -- now in the database as an additional drop). Its first source with a map location gives the
    -- craft source its map location (clicking it shows where to get the recipe) and is named on it.
    local RECIPE_PREFIXES = { "Pattern: ", "Plans: ", "Schematic: ", "Formula: ", "Recipe: ", "Design: ", "Manual: " }
    for i, s in ipairs(out) do
        local rname = s.t == "craft" and type(s.n) == "string" and s.n:match("%((.-)%)$")
        local rid = rname and self:RecipeIdByName(rname)
        if s.t == "craft" and not rid then  -- learned crafts name only the profession: by the item's name
            local own = self:GetItem(id)
            for _, prefix in ipairs(own and own.n and RECIPE_PREFIXES or {}) do
                rid = self:RecipeIdByName(prefix .. own.n)
                if rid then break end
            end
        end
        if rid and rid ~= id then
            local first, located
            for _, rs in ipairs(self:GetSources(rid)) do
                first = first or rs
                if ns.HasLocation(rs) then located = rs; break end
            end
            local via = located or first
            if via then
                local c = {}
                for k, v in pairs(s) do c[k] = v end
                c.recipe, c.via = rid, ns.FormatSource(via)
                if not c.loc and located then c.loc, c.z = located.loc, c.z or located.z end
                out[i] = c
            end
        end
    end
    -- Vendor prices live apart from the sources (keyed by vendor name), so shipped and learned
    -- vendor entries both get them. Copies: never write into saved or shipped tables.
    for i, s in ipairs(out) do
        if s.t == "vendor" then
            local price = self:GetVendorPrice(id, s.n)
            if price then
                local c = {}
                for k, v in pairs(s) do c[k] = v end
                c.price = price
                out[i] = c
            end
        end
    end
    return out
end

-- Every source line of an item, as the tooltip, item details, lists and zone picks show it.
-- Cached per item (the item list's rows, tooltips and zone picks ask for the same items over and
-- over); cleared whenever sources, spots or prices are learned and on every refresh. Callers
-- only read the list.
-- Recipe items (additional drops, x = "r") by name: "Pattern: Fine Leather Boots" -> item ID.
local recipeByName
function ns:RecipeIdByName(name)
    if not recipeByName then
        recipeByName = {}
        for _, layer in ipairs({ GearGuide_Data.items or {}, GearGuideLearned and GearGuideLearned.items or {} }) do
            for rid, item in pairs(layer) do
                if item.x == "r" and item.n and not recipeByName[item.n] then recipeByName[item.n] = rid end
            end
        end
    end
    return recipeByName[name]
end

local sourcesCache, sourcesCount = {}, 0
function ns:InvalidateSourcesCache() wipe(sourcesCache); sourcesCount = 0; recipeByName = nil end
function ns:GetSources(id)
    local list = sourcesCache[id]
    if not list then
        if sourcesCount >= 3000 then wipe(sourcesCache); sourcesCount = 0 end
        list = computeSources(self, id)
        if #list > 0 then  -- not "none yet": data arriving late must show at once (and none is cheap)
            sourcesCache[id], sourcesCount = list, sourcesCount + 1
        end
    end
    return list
end

-- { g = copper or nil, c = { {n = currency, q = amount, i = icon}, ... } or nil } for an item at a
-- vendor: seen in game (newest), else shipped in Data.lua.
function ns:GetVendorPrice(id, vendor)
    if not vendor then return nil end
    local learned = GearGuideLearned.prices and GearGuideLearned.prices[id]
    if learned and learned[vendor] then return learned[vendor] end
    local dbItem = GearGuide_Data.items[id]
    if not dbItem then return nil end
    if dbItem.vp and dbItem.vp[vendor] then return dbItem.vp[vendor] end
    -- Default gold price (item.bp, from the build's vendor database): the same at every vendor.
    if dbItem.bp and dbItem.bp > 0 then return { g = dbItem.bp } end
    -- PvP rank gear (item.hr) is bought with Honor. Every honor vendor charges the same, so a
    -- price seen at any of them (the other faction's included) applies here too.
    if dbItem.hr then
        for _, p in pairs(learned or {}) do return p end
        for _, p in pairs(dbItem.vp or {}) do return p end
        return { honor = true }  -- cost not seen yet: say it's Honor rather than nothing
    end
    return nil
end

-- "1g 25s" (coin icons where the client has them) + " + 2 Mark of Honor" for each extra cost.
function ns.FormatPrice(p)
    local parts = {}
    if p.g and p.g > 0 then
        if GetCoinTextureString then
            parts[#parts + 1] = GetCoinTextureString(p.g)
        else
            local gold, silver, copper = math.floor(p.g / 10000), math.floor(p.g / 100) % 100, p.g % 100
            local t = {}
            if gold > 0 then t[#t + 1] = gold .. "g" end
            if silver > 0 then t[#t + 1] = silver .. "s" end
            if copper > 0 then t[#t + 1] = copper .. "c" end
            parts[#parts + 1] = table.concat(t, " ")
        end
    end
    for _, cost in ipairs(p.c or {}) do
        local icon = cost.i and ("|T" .. cost.i .. ":0|t ") or ""
        parts[#parts + 1] = icon .. (cost.q or 1) .. " " .. (cost.n or "?")
    end
    if p.honor and #parts == 0 then
        return "Honor |cff888888(open the vendor once to see the price)|r"
    end
    return table.concat(parts, " + ")
end

-- Does anyone know where this item comes from? Cheap check (no resolving), any faction.
function ns:HasSource(id)
    local dbItem = GearGuide_Data.items[id]
    if dbItem and dbItem.src and dbItem.src[1] ~= nil then return true end
    if GearGuide_WorldDrops and GearGuide_WorldDrops.items[id] then return true end
    local learned = GearGuideLearned.sources[id]
    if learned and learned[1] ~= nil then return true end
    local shared = GearGuideLearned.shared and GearGuideLearned.shared[id]  -- raw: no copy per call
    return shared ~= nil and shared[1] ~= nil
end

-- Lists (recommendations, browser, mini tracker) leave out items without a known source unless
-- the player turned them on. Favorites always stay: the player picked them on purpose.
function ns:ShowsItem(id)
    local item = self:GetItem(id)
    if item and item.pv then return false end  -- not confirmed by this client yet
    return GearGuideDB.showUnknown or self:HasSource(id) or (self.IsFavorite and self:IsFavorite(id)) or false
end

---------------------------------------------------------------------------
-- Dungeon and raid loot (Gear Browser "Instance" filter). An instance is any area that shipped
-- creature locations mark as "inside, entrance at e" (spawns with no outdoor coordinates); its
-- loot is what creatures and chests there drop. World drops that trash happens to carry (the
-- client lists them at well under 1%) are left out, so the list is the instance's own loot.
---------------------------------------------------------------------------
local RAID_AREAS = { [2717] = true, [2677] = true, [2159] = true, [1977] = true, [3429] = true,
    [3428] = true, [3456] = true }  -- MC, BWL, Onyxia, ZG, AQ20, AQ40, Naxxramas
local INSTANCE_MIN_CHANCE = 0.5     -- % ; below this a drop is a world drop, not instance loot
-- WoW Forever's nine new dungeons, always in the menu so players see they exist, even before any
-- of their loot is known. area: the area ID where QuestieDB's Forever dungeons.lua has one (the
-- client then gives the localized name); the others go by name until the data has them. min/max:
-- the dungeon's level range, shown while no loot is known.
local FOREVER_DUNGEONS = {
    { area = 16919, name = "The Hall of Thanes", min = 13, max = 18 },
    { area = 16611, name = "Ruins of Lordaeron", min = 15, max = 20 },
    { area = 16732, name = "Excavation Site: Wetlands", min = 24, max = 29 },
    { area = 16544, name = "City of Dalaran", min = 28, max = 33 },
    { name = "The Drowned City", min = 35, max = 40 },
    { name = "Krol'dok Stronghold", min = 40, max = 45 },
    { name = "Alcaz Prison", min = 48, max = 53 },
    { name = "Blackmaw Hold", min = 55, max = 60 },
    { name = "Shaper's Terrace", min = 58, max = 60 },
}

-- Zone names compared loosely: the game may say "The Drowned City" where the list says "Drowned City".
local function nameKey(name)
    return (name:lower():gsub("^the%s+", ""))
end

function ns:InstanceIndex()
    if self.instanceIndex then return self.instanceIndex end
    local data = GearGuide_Data
    local areas, byName = {}, {}
    local function addArea(key, name, raid)
        if areas[key] or not name or name == "" then return areas[key] end
        areas[key] = { area = key, name = name, raid = raid or false, items = {} }
        byName[nameKey(name)] = areas[key]
        return areas[key]
    end
    for _, loc in pairs(data.locs or {}) do
        for _, entry in ipairs(type(loc) == "table" and loc or {}) do
            if entry.e then addArea(entry.e, ns.ZoneName(entry.e), RAID_AREAS[entry.e]) end
        end
    end
    for _, d in ipairs(FOREVER_DUNGEONS) do
        local inst = byName[nameKey(d.name)]
            or (d.area and addArea(d.area, ns.ZoneName(d.area) or d.name, false))
            or addArea(d.name, d.name, false)
        if inst then inst.levels = { d.min, d.max } end
    end
    -- Instances the player looted in that the shipped data doesn't know (new dungeons): by name.
    for name, kind in pairs(GearGuideLearned.instanceZones or {}) do
        if not byName[nameKey(name)] then addArea(name, name, kind == "raid") end
    end
    local function instanceOf(z)
        if type(z) == "number" then return areas[z] end
        return type(z) == "string" and byName[nameKey(z)] or nil
    end
    -- Shipped sources: judged per source by its own drop chance. An unknown chance counts as loot,
    -- unless the item is known elsewhere only as a rare world drop (new dungeons' creatures carry
    -- world drops with no chance on record).
    local bestChance = {}
    for id, dbItem in pairs(data.items or {}) do
        if type(dbItem) == "table" and type(dbItem.dc) == "table" then
            for _, dc in pairs(dbItem.dc) do
                if type(dc) == "number" and dc > 0 then bestChance[id] = math.max(bestChance[id] or 0, dc) end
            end
        end
    end
    for id, dbItem in pairs(data.items or {}) do
        if type(dbItem) == "table" and dbItem.src then
            local chances = type(dbItem.dc) == "table" and dbItem.dc or nil
            local best = bestChance[id]
            for i, s in ipairs(dbItem.src) do
                if type(s) == "number" then s = data.sources and data.sources[s] end
                local inst = type(s) == "table" and s.t == "drop" and instanceOf(s.z)
                local dc = chances and chances[i]
                local known = dc and dc > 0
                if inst and ((known and dc >= INSTANCE_MIN_CHANCE)
                    or (not known and (not best or best >= INSTANCE_MIN_CHANCE))) then
                    inst.items[id] = true
                end
            end
        end
    end
    -- Drops seen in game (own and shared) carry zone names and no chance: they count unless the
    -- shipped data knows the item only as a rare world drop.
    local function addSeen(store)
        for id, list in pairs(store or {}) do
            local best = bestChance[id]
            if not best or best >= INSTANCE_MIN_CHANCE then
                for _, s in ipairs(type(list) == "table" and list or {}) do
                    local inst = s.t == "drop" and instanceOf(s.z)
                    if inst then inst.items[id] = true end
                end
            end
        end
    end
    addSeen(GearGuideLearned.sources)
    addSeen(GearGuideLearned.shared)
    -- Sorted by the level of their loot (median wearable level), dungeons before raids, and labeled
    -- with the middle of that range (most of the loot, without the odd outlier).
    local list = {}
    for _, inst in pairs(areas) do
        local levels = {}
        for id in pairs(inst.items) do
            local item = self:GetItem(id)
            if item then levels[#levels + 1] = ns.EffectiveLevel(item) end
        end
        inst.noLoot = #levels == 0
        if #levels > 0 then
            table.sort(levels)
            local function at(p) return levels[math.max(1, math.min(#levels, math.floor(#levels * p + 0.5)))] end
            inst.minL, inst.midL, inst.maxL = at(0.2), at(0.5), at(0.8)
            list[#list + 1] = inst
        elseif inst.levels then
            -- Known to exist, loot not yet: listed with the dungeon's own level range.
            inst.minL, inst.maxL = inst.levels[1], inst.levels[2]
            inst.midL = (inst.minL + inst.maxL) / 2
            list[#list + 1] = inst
        end
    end
    table.sort(list, function(a, b)
        if a.raid ~= b.raid then return not a.raid end
        if a.midL ~= b.midL then return a.midL < b.midL end
        return a.name < b.name
    end)
    self.instanceIndex = { list = list, byArea = areas }
    return self.instanceIndex
end

---------------------------------------------------------------------------
-- Outdoor zones (Gear Browser "Zone" filter): every zone the client's world map knows, new WoW
-- Forever zones included, plus zones only known from loot. Dungeons and raids aren't zones (the
-- dungeon menu has them). A zone's items: creature/chest drops, vendors and quests located there,
-- with the instance rule for chances (rare world drops left out).
---------------------------------------------------------------------------
local ZONE_MAP = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
local DUNGEON_MAP = (Enum and Enum.UIMapType and Enum.UIMapType.Dungeon) or 4
local WORLD_MAPS = { 946, 947 }  -- Cosmic, Azeroth: their descendants are every map
local mapZones = {}
-- The zone map a world map ID lies in (itself, or the zone above a sub-zone map), or nil for
-- continents and dungeon maps.
local function zoneOfMap(m)
    if mapZones[m] == nil then
        local found, id = false, m
        for _ = 1, 8 do
            local info = id and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(id)
            if not info or info.mapType == DUNGEON_MAP then break end
            if info.mapType == ZONE_MAP then found = id; break end
            if (info.mapType or 0) < ZONE_MAP then break end  -- a continent: not inside one zone
            id = info.parentMapID
        end
        mapZones[m] = found
    end
    return mapZones[m] or nil
end

function ns:ZoneIndex()
    if self.zoneIndex then return self.zoneIndex end
    local data = GearGuide_Data
    local instances = {}
    for _, inst in pairs(self:InstanceIndex().byArea) do instances[nameKey(inst.name)] = true end
    for name in pairs(GearGuideLearned.instanceZones or {}) do instances[nameKey(name)] = true end
    local zones, byName = {}, {}
    local function continentOf(parent)
        local info = parent and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(parent)
        return info and info.name or "Other"
    end
    local function addZone(key, name, continent)
        if zones[key] then return zones[key] end
        if not name or name == "" or instances[nameKey(name)] then return nil end
        local same = byName[nameKey(name)]
        if same then zones[key] = same; return same end  -- one zone under two map IDs
        local z = { key = key, name = name, continent = continent or "Other", items = {} }
        if type(key) == "number" and C_Map and C_Map.GetMapLevels then
            local lo, hi = C_Map.GetMapLevels(key)
            if lo and hi and lo > 0 and hi > 0 then z.levels = { lo, hi } end
        end
        zones[key], byName[nameKey(name)] = z, z
        return z
    end
    local function zoneForMap(m)
        local zid = m and zoneOfMap(m)
        if not zid then return nil end
        if zones[zid] then return zones[zid] end
        local info = C_Map.GetMapInfo(zid)
        return addZone(zid, info and info.name, continentOf(info and info.parentMapID))
    end
    if C_Map and C_Map.GetMapChildrenInfo then
        for _, root in ipairs(WORLD_MAPS) do
            for _, info in ipairs(C_Map.GetMapChildrenInfo(root, ZONE_MAP, true) or {}) do
                addZone(info.mapID, info.name, continentOf(info.parentMapID))
            end
        end
    end
    -- One source's zones: its outdoor map spots (dungeon entrances aren't loot of the zone), else
    -- its zone (area ID or name) when that is an outdoor zone.
    local function place(id, s, loc)
        if s.t == "craft" or s.t == "world" or s.t == "start" then return end
        local placed = false
        for _, entry in ipairs(type(loc) == "table" and loc or {}) do
            if type(entry) == "table" and not entry.e then
                local z = zoneForMap(entry.m)
                if z then z.items[id] = true; placed = true end
            end
        end
        if not placed and s.z then
            local name = ns.ZoneName(s.z)
            local z = type(name) == "string" and byName[nameKey(name)]
            if z then z.items[id] = true end
        end
    end
    local locs = data.locs or {}
    for id, dbItem in pairs(data.items or {}) do
        if type(dbItem) == "table" and dbItem.src then
            local chances = type(dbItem.dc) == "table" and dbItem.dc or nil
            local best = 0
            for _, c in ipairs(chances or {}) do best = math.max(best, c) end
            for i, s in ipairs(dbItem.src) do
                if type(s) == "number" then s = data.sources and data.sources[s] end
                if type(s) == "table" then
                    local dc = chances and chances[i]
                    local known = dc and dc > 0
                    local rare = s.t == "drop" and ((known and dc < INSTANCE_MIN_CHANCE)
                        or (not known and best > 0 and best < INSTANCE_MIN_CHANCE))
                    if not rare then place(id, s, s.loc or (s.l and locs[s.l])) end
                end
            end
        end
    end
    -- Seen in game (own and shared): zone names from the client; zones nobody listed join.
    for _, store in ipairs({ GearGuideLearned.sources, GearGuideLearned.shared }) do
        for id, list in pairs(store or {}) do
            for _, s in ipairs(type(list) == "table" and list or {}) do
                if type(s) == "table" then
                    if type(s.z) == "string" and not byName[nameKey(s.z)] and s.t ~= "craft" then
                        addZone(s.z, s.z, "Other")
                    end
                    place(id, s, s.loc)
                end
            end
        end
    end
    local list, seen = {}, {}
    for _, z in pairs(zones) do
        if not seen[z] then seen[z] = true; list[#list + 1] = z end
    end
    table.sort(list, function(a, b)
        if a.continent ~= b.continent then
            if (a.continent == "Other") ~= (b.continent == "Other") then return b.continent == "Other" end
            return a.continent < b.continent
        end
        return a.name < b.name
    end)
    self.zoneIndex = { list = list, byKey = zones }
    return self.zoneIndex
end

-- Item ids obtainable in an outdoor zone (map ID or name), as a set; nil for an unknown zone.
function ns:ZoneItems(key)
    local z = key and self:ZoneIndex().byKey[key]
    return z and z.items or nil
end

-- Raid gear: an item named like loot from a raid (the raid's own copy, and look-alikes such as
-- WoW Forever's level-30 copies of Molten Core rings). Not recommended before max level: raids
-- are endgame, whatever a copy's required level says.
local raidNames
function ns:IsRaidGear(item)
    if not item or not item.n then return false end
    if not raidNames then
        raidNames = {}
        local data = GearGuide_Data
        for _, dbItem in pairs(data.items or {}) do
            -- Only raid loot: every creature drop is in a raid (world-drop epics that raid trash
            -- also carries, like Imbued Plate Pauldrons, stay normal gear).
            if type(dbItem) == "table" and dbItem.n and dbItem.src then
                local inRaid, elsewhere = false, false
                for _, s in ipairs(dbItem.src) do
                    if type(s) == "number" then s = data.sources and data.sources[s] end
                    if type(s) == "table" and s.t == "drop" then
                        if RAID_AREAS[s.z] then inRaid = true else elsewhere = true end
                    end
                end
                if inRaid and not elsewhere then raidNames[dbItem.n] = true end
            end
        end
    end
    return raidNames[item.n] == true
end

-- Raid gear waits for max level (favorites still show: the player picked those).
local maxLevel  -- the level cap, asked per item in scans
function ns:RaidGearTooEarly(item, level)
    maxLevel = maxLevel or (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
    local max = maxLevel
    return (level or 1) < max and self:IsRaidGear(item)
end

-- Item ids that drop in an instance (area ID), as a set; nil for an unknown area.
function ns:InstanceItems(area)
    local inst = area and self:InstanceIndex().byArea[area]
    return inst and inst.items or nil
end

function ns:SetShowUnknown(on)
    GearGuideDB.showUnknown = on and true or false
    ns.Print(on and "Showing items whose source is not discovered yet." or "Hiding items whose source is not discovered yet (favorites still show).")
    self:RequestRefresh()
end

local SOURCE_LABELS = { drop = "Drop", quest = "Quest", vendor = "Vendor", craft = "Crafted",
    world = "World drop", pvp = "PvP", start = "Starting gear" }

-- Zones arrive as names (learned in game) or area IDs (imported data); IDs become localized names.
local zoneNames = {}
function ns.ZoneName(z)
    if type(z) ~= "number" then return z end
    if zoneNames[z] == nil then
        local name = C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(z)
        zoneNames[z] = name or false
    end
    return zoneNames[z] or nil
end

-- Drop chance in % -> "20%", "2.5%", "0.35%", "<0.1%".
function ns.FormatChance(pct)
    local text
    if pct >= 10 then text = string.format("%.0f", pct)
    elseif pct >= 1 then text = string.format("%.1f", pct)
    elseif pct >= 0.1 then text = string.format("%.2f", pct)
    else return "<0.1%" end
    text = text:gsub("(%.%d-)0+$", "%1"):gsub("%.$", "")  -- 2.50 -> 2.5, 3.0 -> 3
    return text .. "%"
end

function ns.FormatSource(s)
    local text = (SOURCE_LABELS[s.t] or s.t or "?") .. ": " .. (s.n or "?")
    local zone = ns.ZoneName(s.z)
    if zone == s.n then
        text = text .. " |cff888888(creature unknown)|r"  -- a dungeon drop credited to the dungeon
    elseif zone and zone ~= "" then
        text = text .. " (" .. zone .. ")"
    end
    if s.dc then text = text .. " |cffffd100" .. ns.FormatChance(s.dc) .. "|r" end
    if s.price then text = text .. " |cffffffff- " .. ns.FormatPrice(s.price) .. "|r" end
    if s.shared then text = text .. " |cff888888(shared by players)|r" end
    if s.via then text = text .. " |cff888888- recipe: " .. s.via:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r" end
    if s.k == "guess" then text = text .. " |cff888888(likely)|r" end
    if s.k == "rare" then text = text .. " |cffc0c0c0(rare)|r" end
    if s.k == "boe" then text = text .. " |cff888888(BoE)|r" end
    return text
end

-- Does this source have a place on the world map?
function ns.HasLocation(s)
    return type(s) == "table" and type(s.loc) == "table" and s.loc[1] ~= nil
end

-- Opens the world map at a source: creature/vendor/quest giver spawns, chest spots, or the dungeon
-- entrance for things inside instances. Clicking the same source again shows its next location.
local lastShown, lastIndex
function ns:ShowSourceOnMap(s)
    if not ns.HasLocation(s) then
        ns.Print("No map location is known for " .. (s and s.n or "this source") .. " yet.")
        return
    end
    local key = (s.t or "") .. "|" .. (s.n or "") .. "|" .. tostring(s.z)  -- sources are rebuilt per call
    lastIndex = (lastShown == key) and (lastIndex % #s.loc) + 1 or 1
    lastShown = key
    local entry = s.loc[lastIndex]
    local points, flatPoints = {}, ns.Numbers(entry.p) or {}
    for i = 1, #flatPoints - 1, 2 do
        points[#points + 1] = { x = flatPoints[i] / 100, y = flatPoints[i + 1] / 100 }
    end
    local routes = {}
    for _, r in ipairs(ns.NumberLists(entry.r) or {}) do
        local route = {}
        for i = 1, #r - 1, 2 do route[#route + 1] = { x = r[i] / 100, y = r[i + 1] / 100 } end
        if #route > 1 then routes[#routes + 1] = route end
    end
    local areas = {}
    for _, flat in ipairs(ns.NumberLists(entry.a) or {}) do
        local poly = {}
        for i = 1, #flat - 1, 2 do poly[#poly + 1] = { x = flat[i] / 100, y = flat[i + 1] / 100 } end
        if #poly >= 3 then areas[#areas + 1] = poly end
    end
    local kind = entry.e and "entrance" or (s.k == "object" and "object") or s.t
    local sub = ns.FormatSource(s)
    if entry.e then sub = sub .. " - dungeon entrance" end
    if #routes > 0 then
        local who = s.k == "rare" and "patrols" or "walks"
        sub = sub .. (#points > 0 and (" - " .. who .. " the marked route") or " - passes through here on the marked route")
    end
    if #s.loc > 1 then sub = sub .. string.format("  (location %d of %d, click again for the next)", lastIndex, #s.loc) end
    if #areas > 0 then sub = sub .. (#areas > 1 and " - lives in the shaded areas" or " - lives in the shaded area") end
    self:ShowOnMap({ map = entry.m, points = points, routes = routes, areas = areas, title = s.n, sub = sub, kind = kind })
end

-- preferZone (a zone name): lead with a source there, e.g. the boss when browsing one dungeon.
function ns:SourceSummary(id, preferZone)
    local list = self:GetSources(id)
    if #list == 0 then return "|cff888888Not discovered yet|r" end
    local first = list[1]
    if preferZone then
        local function inZone(s)
            if ns.ZoneName(s.z) == preferZone then return true end
            for _, e in ipairs(type(s.loc) == "table" and s.loc or {}) do  -- outdoor spots (Zone filter)
                local zid = type(e) == "table" and not e.e and e.m and zoneOfMap(e.m)
                local info = zid and C_Map.GetMapInfo(zid)
                if info and info.name == preferZone then return true end
            end
            return false
        end
        for _, s in ipairs(list) do
            if (s.t == "drop" or s.t == "vendor" or s.t == "quest") and inZone(s) then first = s break end
        end
    end
    local text = ns.FormatSource(first)
    if #list > 1 then text = text .. string.format(" |cff888888+%d more|r", #list - 1) end
    return text
end

---------------------------------------------------------------------------
-- Favorites (per character): items the player has chosen to go for
---------------------------------------------------------------------------
function ns:IsFavorite(id)
    return GearGuideCharDB ~= nil and GearGuideCharDB.favorites ~= nil and GearGuideCharDB.favorites[id] ~= nil
end

function ns:SetFavorite(id, on)
    if not id then return end
    GearGuideCharDB.favorites[id] = on and (GearGuideCharDB.favorites[id] or time()) or nil
    if on and GearGuideCharDB.ignored then GearGuideCharDB.ignored[id] = nil end  -- wanted again
    self:RequestRefresh()
end

function ns:ToggleFavorite(id)
    self:SetFavorite(id, not self:IsFavorite(id))
    return self:IsFavorite(id)
end

---------------------------------------------------------------------------
-- Ignored items (per character): never recommended (Recommended tab, mini tracker, zone picks,
-- Gear Acquired pop-up, creature tooltips, the Build Simulator's recommended build). They still
-- show in the Gear Browser and the simulator's item lists, marked, so they can be un-ignored.
---------------------------------------------------------------------------
function ns:IsIgnored(id)
    return GearGuideCharDB ~= nil and GearGuideCharDB.ignored ~= nil and id ~= nil
        and GearGuideCharDB.ignored[id] ~= nil
end

function ns:SetIgnored(id, on)
    if not id or not GearGuideCharDB then return end
    GearGuideCharDB.ignored = GearGuideCharDB.ignored or {}
    GearGuideCharDB.ignored[id] = on and (GearGuideCharDB.ignored[id] or time()) or nil
    if on and GearGuideCharDB.favorites then GearGuideCharDB.favorites[id] = nil end  -- not wanted
    self:RequestRefresh()
end

function ns:ToggleIgnored(id)
    self:SetIgnored(id, not self:IsIgnored(id))
    return self:IsIgnored(id)
end

function ns:IgnoredCount()
    local n = 0
    for _ in pairs(GearGuideCharDB and GearGuideCharDB.ignored or {}) do n = n + 1 end
    return n
end

function ns:ClearIgnored()
    if GearGuideCharDB then GearGuideCharDB.ignored = {} end
    self:RequestRefresh()
end

-- Favorite item IDs, oldest first (the order the player picked them).
function ns:GetFavorites()
    local list = {}
    for id, at in pairs(GearGuideCharDB.favorites or {}) do list[#list + 1] = { id = id, at = at } end
    table.sort(list, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.id < b.id  -- starred within the same second: stable order
    end)
    local ids = {}
    for i, f in ipairs(list) do ids[i] = f.id end
    return ids
end

---------------------------------------------------------------------------
-- Class, specialization, usability
---------------------------------------------------------------------------
function ns:GetPlayerClass()
    return select(2, UnitClass("player"))
end

function ns:GetSpecs(class)
    return ns.CLASS_SPECS[class or self:GetPlayerClass()] or {}
end

-- Spec table for a class + key; falls back to the class's first spec.
function ns:GetSpecInfo(class, key)
    local specs = self:GetSpecs(class)
    for _, s in ipairs(specs) do
        if s.key == key then return s end
    end
    return specs[1]
end

-- Points spent in talent tree `tab`. Classic-era clients return (name, icon, points, ...);
-- newer Classic clients return (id, name, description, icon, points, ...).
local function talentPoints(tab)
    if type(GetTalentTabInfo) ~= "function" then return 0 end
    local a, _, c, _, e = GetTalentTabInfo(tab)
    if type(a) == "number" then return tonumber(e) or 0 end
    return tonumber(c) or 0
end

-- Spec key of the talent tree with the most points, or nil without talents (or API).
function ns:DetectPlayerSpec()
    local numTabs = type(GetNumTalentTabs) == "function" and GetNumTalentTabs() or 0
    local bestTab, bestPoints = nil, 0
    for tab = 1, numTabs do
        local ok, points = pcall(talentPoints, tab)
        if ok and points > bestPoints then bestTab, bestPoints = tab, points end
    end
    if not bestTab then return nil end
    for _, s in ipairs(self:GetSpecs()) do
        if s.tab == bestTab then return s.key end  -- first match wins (Feral -> Cat)
    end
end

-- The player's spec: their saved choice, else detected from talents, else the first spec.
function ns:GetPlayerSpec()
    local chosen = GearGuideCharDB and GearGuideCharDB.spec
    if chosen == "CUSTOM" then chosen = GearGuideCharDB.custom and GearGuideCharDB.custom.base end
    if chosen and chosen ~= "AUTO" then
        for _, s in ipairs(self:GetSpecs()) do
            if s.key == chosen then return chosen end
        end
    end
    -- Talent reads (3 API calls) are asked for on every score and badge: kept for 2 seconds and
    -- dropped on every refresh (talent and level events request one).
    local now = GetTime and GetTime() or 0
    if self.detectedAt == nil or now - self.detectedAt > 2 then
        self.detectedSpec, self.detectedAt = self:DetectPlayerSpec(), now
    end
    return self.detectedSpec or (self:GetSpecs()[1] or {}).key
end

-- key = a spec key, "AUTO" (follow talents) or "CUSTOM" (the player's own stat weights).
function ns:SetPlayerSpec(key)
    if key == "CUSTOM" then self:InitCustomWeights() end
    GearGuideCharDB.spec = key or "AUTO"
    self:RequestRefresh()
end

function ns:IsSpecAuto()
    return not GearGuideCharDB or not GearGuideCharDB.spec or GearGuideCharDB.spec == "AUTO"
end

---------------------------------------------------------------------------
-- Custom stat weights: the player's own value per stat point, on top of a base spec that still
-- decides the role and how weapons are held. Per character:
-- GearGuideCharDB.custom = { base = specKey, weights = { STAT = value } }.
---------------------------------------------------------------------------
function ns:IsCustomWeights()
    return GearGuideCharDB ~= nil and GearGuideCharDB.spec == "CUSTOM" and GearGuideCharDB.custom ~= nil
end

-- First use starts from the spec the player is on, so the numbers begin somewhere sensible.
function ns:InitCustomWeights()
    if GearGuideCharDB.custom and GearGuideCharDB.custom.weights then return end
    local base = self:GetPlayerSpec()
    GearGuideCharDB.custom = { base = base, weights = self:GetWeights(self:GetPlayerClass(), base, 60) }
end

function ns:SetCustomBase(key)
    self:InitCustomWeights()
    GearGuideCharDB.custom.base = key
    self:RequestRefresh()
end

-- value nil or 0 removes the stat.
function ns:SetCustomWeight(stat, value)
    self:InitCustomWeights()
    GearGuideCharDB.custom.weights[stat] = (value and value ~= 0) and value or nil
    self:RequestRefresh()
end

-- Back to the base spec's researched values (level 60 ones; custom weights have no leveling set).
function ns:ResetCustomWeights()
    self:InitCustomWeights()
    local c = GearGuideCharDB.custom
    c.weights = self:GetWeights(self:GetPlayerClass(), c.base, 60)
    self:RequestRefresh()
end

---------------------------------------------------------------------------
-- Pawn scale import: ( Pawn: v1: "Name": Class=Warrior, Strength=2, CritRating=0.8, ... )
-- Pawn's stat names map to GearGuide's. Pawn values are per point; a "...Rating" stat is per rating
-- point and becomes per 1% here (GearGuide's percent stats), with the same conversion items use.
-- Bare Hit/Crit (Pawn's classic percent stats) are per 1% already.
---------------------------------------------------------------------------
local PAWN_STATS = {
    strength = "STR", agility = "AGI", stamina = "STA", intellect = "INT", spirit = "SPI",
    armor = "ARMOR", dps = "DPS", meleedps = "DPS", rangeddps = "RDPS",
    ap = "AP", attackpower = "AP", rap = "RAP", rangedattackpower = "RAP",
    spelldamage = "SP", spellpower = "SP", healing = "HEAL", mp5 = "MP5",
    hit = "HIT", spellhit = "SHIT", crit = "CRIT", spellcrit = "SCRIT", haste = "HASTE", spellhaste = "HASTE",
    expertise = "EXPERTISE", defense = "DEF", dodge = "DODGE", parry = "PARRY", block = "BLOCK",
}
local PAWN_INFO = { class = true, classid = true, spec = true, specid = true, name = true }

-- text -> weights { STAT = per point/per 1% }, scale name, { ignored Pawn stat names }; or nil, error.
function ns.ParsePawnScale(text)
    text = tostring(text or "")
    local name, body = text:match('%(%s*Pawn%s*:%s*v%d+%s*:%s*"([^"]*)"%s*:(.-)%)')
    if not body then body = text:match("^%s*(.-)%s*$") end  -- also a bare "Strength=2, Agility=1" list
    local weights, ignored, found = {}, {}, 0
    for key, value in body:gmatch("([%w_]+)%s*=%s*([%-%d%.]+)") do
        local k = key:lower()
        local v = tonumber(value)
        local rating = k:find("rating$") ~= nil
        local stat = PAWN_STATS[(k:gsub("rating$", ""))]
        if stat and v then
            if rating and ns.RatingPct(stat, 60) then v = v / ns.RatingPct(stat, 60) end  -- per point -> per 1%
            if v ~= 0 then weights[stat] = (weights[stat] or 0) + v end
            found = found + 1
        elseif not PAWN_INFO[k] then
            ignored[#ignored + 1] = key
        end
    end
    if found == 0 then return nil, "That doesn't look like a Pawn scale: no stat weights found." end
    for stat, v in pairs(weights) do weights[stat] = math.floor(v * 1000 + 0.5) / 1000 end
    return weights, name, ignored
end

-- Replaces the custom stat weights with a Pawn scale and switches to them. ok, message.
function ns:ImportPawnScale(text)
    local weights, name, ignored = ns.ParsePawnScale(text)
    if not weights then return false, name end
    self:InitCustomWeights()
    GearGuideCharDB.custom.weights = weights
    self:SetPlayerSpec("CUSTOM")
    local n = 0
    for _ in pairs(weights) do n = n + 1 end
    local msg = string.format("Imported %s: %d stat weight%s", name and ('"' .. name .. '"') or "the Pawn scale",
        n, n == 1 and "" or "s")
    if #ignored > 0 then msg = msg .. " (not used by GearGuide: " .. table.concat(ignored, ", ") .. ")" end
    return true, msg
end

function ns:SpecLabel(class, key)
    local s = self:GetSpecInfo(class, key)
    return s and s.label or "?"
end

-- "Auto (Fury)" or "Fury"
function ns:PlayerSpecLabel()
    local label = self:SpecLabel(nil, self:GetPlayerSpec())
    if self:IsSpecAuto() then return "Auto (" .. label .. ")" end
    if self:IsCustomWeights() then return "Custom (" .. label .. ")" end
    return label
end

-- Role of the player's current spec (MELEE/TANK/RANGED/CASTER/HEALER).
function ns:GetRole()
    local s = self:GetSpecInfo(nil, self:GetPlayerSpec())
    return s and s.role or "MELEE"
end

-- Researched per-spec weights (SpecWeights.lua) when available, else role base + spec tweaks.
-- Below level 60, the spec's "leveling" overrides apply (e.g. stamina and weapon damage matter more).
function ns:GetWeights(class, specKey, level)
    local spec = self:GetSpecInfo(class, specKey)
    local researched = spec and ns.SPEC_WEIGHTS and ns.SPEC_WEIGHTS[class] and ns.SPEC_WEIGHTS[class][spec.key]
    local w = {}
    if researched then
        for k, v in pairs(researched.weights) do w[k] = v end
        if researched.leveling and (level or 60) < 60 then
            for k, v in pairs(researched.leveling) do w[k] = v end
        end
        return w
    end
    for k, v in pairs(ns.ROLE_WEIGHTS[spec and spec.role or "MELEE"] or {}) do w[k] = v end
    for k, v in pairs(spec and spec.mod or {}) do w[k] = v end
    return w
end

-- Researched stat priority for a spec, e.g. { "HIT", "CRIT", "STR" }, or nil.
function ns:GetSpecPriority(class, specKey)
    local spec = self:GetSpecInfo(class, specKey)
    local r = spec and ns.SPEC_WEIGHTS and ns.SPEC_WEIGHTS[class] and ns.SPEC_WEIGHTS[class][spec.key]
    return r and r.priority
end

function ns:ArmorMax(class, level)
    local p = ns.ARMOR_PROF[class]
    if not p then return 4 end
    if p.upgradeAt and level >= p.upgradeAt then return p.max + 1 end
    return p.max
end

-- Can `class` use this item once they reach its required level?
function ns:IsUsable(item, class, level)
    if not ns.EQUIPLOC_GROUP[item.eq] then return false end
    -- Items only the other faction can get (all known sources are theirs).
    local faction = ns.PlayerFaction()
    if item.fa and faction and item.fa ~= faction then return false end
    if item.cls then
        local allowed = false
        for _, c in ipairs(item.cls) do if c == class then allowed = true break end end
        if not allowed then return false end
    end
    local sc = item.sc or 0
    if item.c == ns.ITEM_CLASS_ARMOR then
        if sc == 0 or item.eq == "INVTYPE_CLOAK" then return true end
        local prof = ns.ARMOR_PROF[class]
        if not prof then return true end
        if sc >= 1 and sc <= 4 then
            return sc <= self:ArmorMax(class, math.max(level, item.rl or 0))
        elseif sc == 6 then
            return prof.shield == true
        elseif sc >= 7 and sc <= 9 then
            return prof.relic == sc
        end
        return false
    elseif item.c == ns.ITEM_CLASS_WEAPON then
        local prof = ns.WEAPON_PROF[class]
        return prof ~= nil and prof[sc] == true
    end
    return false
end

-- Required level, falling back to an estimate from item level for items with no requirement.
function ns.EffectiveLevel(item)
    -- "Requires level 1" just means no requirement (common on vanilla quest rewards, Forever event
    -- loot): estimate from item level instead, since stated requirements are always item level - 5.
    if item.rl and item.rl > 1 then return item.rl end
    return math.max(1, (item.il or 1) - 5)
end

---------------------------------------------------------------------------
-- Combat ratings. WoW: Forever items carry hit, crit, dodge... as ratings (14 crit rating is 1% crit),
-- while stat weights and caps are per 1%. The client converts at the player's own level; otherwise
-- the table below. Forever doesn't scale the conversion with level (100 hit rating is 10% at level
-- 29 too): lower-level items simply carry smaller ratings. Defense stays in skill points (items
-- list it that way).
---------------------------------------------------------------------------
local RATING_60 = { HIT = 10, SHIT = 8, CRIT = 14, SCRIT = 14, DODGE = 12, PARRY = 15, BLOCK = 5,
    HASTE = 10, EXPERTISE = 10 }  -- rating per 1% (expertise: per 1% less dodge)
local CR_INDEX = { HIT = { "CR_HIT_MELEE", 6 }, SHIT = { "CR_HIT_SPELL", 8 }, CRIT = { "CR_CRIT_MELEE", 9 },
    SCRIT = { "CR_CRIT_SPELL", 11 }, DODGE = { "CR_DODGE", 3 }, PARRY = { "CR_PARRY", 4 },
    BLOCK = { "CR_BLOCK", 5 }, HASTE = { "CR_HASTE_MELEE", 18 } }
local pctCache = {}

-- Percent per rating point of `stat` at `level` (spell: hit as spell hit), or nil for stats that
-- aren't ratings.
function ns.RatingPct(stat, level, spell)
    if not RATING_60[stat] then return nil end
    if spell and stat == "HIT" then stat = "SHIT" end
    level = math.max(1, math.min(60, math.floor(tonumber(level) or 60)))
    local key = stat .. level
    local v = pctCache[key]
    if v then return v end
    local cr = CR_INDEX[stat]
    local convert = GetCombatRatingBonusForCombatRatingValue
    if cr and type(convert) == "function" and level == (UnitLevel("player") or 0) then
        local ok, pct = pcall(convert, _G[cr[1]] or cr[2], 100)
        pct = ok and tonumber(pct)
        if pct and pct > 0 and pct < 1000 then v = pct / 100 end
    end
    if not v then v = 1 / RATING_60[stat] end
    pctCache[key] = v
    return v
end

-- Wraps the user-defined ScoreItem so a bug there can't break the whole UI.
local RANGED_LOCS = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true }
local derivedWeights = setmetatable({}, { __mode = "k" })  -- weights table -> { key -> copy }
local SPELL_ROLES = { CASTER = true, HEALER = true }

-- What ScoreItem multiplies item stats by: weights per rating point instead of per 1% (stats
-- the item lists as ratings), and for ranged weapons the RDPS weight as DPS when the spec defines
-- one (hunters' bows vs. melee stat sticks), so ScoreItem can keep reading weights.DPS.
local function weightsFor(item, weights, ctx)
    local ranged = weights.RDPS ~= nil and RANGED_LOCS[item.eq] == true
    local spell = SPELL_ROLES[ctx.role] == true
    local level = ctx.level or 60
    -- [level][variant]: numbers as keys, no string built per scored item
    local variant = (spell and 2 or 0) + (ranged and 1 or 0) + 1
    local byLevel = derivedWeights[weights]
    if not byLevel then byLevel = {}; derivedWeights[weights] = byLevel end
    local byKey = byLevel[level]
    if not byKey then byKey = {}; byLevel[level] = byKey end
    local w = byKey[variant]
    if not w then
        w = {}
        for k, v in pairs(weights) do
            local pct = ns.RatingPct(k, level, spell)
            w[k] = pct and v * pct or v
        end
        if ranged then w.DPS = weights.RDPS end
        byKey[variant] = w
    end
    return w
end
ns.ScoringWeights = weightsFor

function ns:Score(item, weights, ctx)
    weights = weightsFor(item, weights, ctx)
    ctx.armorMax = self:ArmorMax(ctx.class, math.max(ctx.level, item.rl or 0))
    local ok, result = pcall(ns.ScoreItem, item, weights, ctx)
    if not ok then
        if not self.scoreErrorShown then
            self.scoreErrorShown = true
            ns.Print("ScoreItem error: " .. tostring(result))
        end
        return 0
    end
    return tonumber(result) or 0
end

---------------------------------------------------------------------------
-- Client build vs. database build
---------------------------------------------------------------------------
-- Players: a shipped database built on an older client build may miss this patch's item changes;
-- say so once per build. Maintainer mode (/gg dev): remind to rescan and release.
function ns:CheckDatabaseBuild()
    local build = select(2, GetBuildInfo())
    local meta = GearGuide_Data.meta or {}
    ns.clientBuild = build
    ns.dbOutdated = meta.source == "client" and meta.build ~= nil and meta.build ~= "?"
        and tostring(meta.build) ~= tostring(build) and next(GearGuide_Data.items) ~= nil
    if GearGuideDB.notifiedBuild == build then return end
    GearGuideDB.notifiedBuild = build
    if GearGuideDB.maintainer then
        if tostring(GearGuideHarvest.build or "") ~= tostring(build) then
            ns.Print(string.format("Maintainer: new client build %s (last scan: %s). Run /gg scan, then "
                .. "GearGuideTools/release.py to check for item changes and package an update.",
                tostring(build), tostring(GearGuideHarvest.build or "none")))
        end
    elseif ns.dbOutdated then
        ns.Print(string.format("The game was patched (build %s); GearGuide's item database is from build %s. "
            .. "If this patch changed items, a GearGuide update will bring them.", tostring(build), tostring(meta.build)))
    end
end

---------------------------------------------------------------------------
-- Refresh scheduling (coalesces bursts of events into one UI rebuild)
---------------------------------------------------------------------------
function ns:RequestRefresh()
    if self.InvalidateRecommendations then self:InvalidateRecommendations() end  -- even while pending
    self:InvalidateSourcesCache()
    self.detectedAt = nil  -- talents may have changed
    if self.refreshPending then return end
    self.refreshPending = true
    if self.InvalidateCreatureTips then self:InvalidateCreatureTips() end  -- upgrades may have changed
    if self.InvalidateBadges then self:InvalidateBadges() end
    C_Timer.After(0.3, function()
        ns.refreshPending = false
        if ns.RefreshUI then ns:RefreshUI() end
        if ns.RefreshMini then ns:RefreshMini() end
    end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
for _, e in ipairs({ "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "ACTIVE_TALENT_GROUP_CHANGED" }) do
    pcall(events.RegisterEvent, events, e)  -- re-detect spec when talents change (not every client has all)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == addonName then
        local updating = GearGuideDB ~= nil  -- settings from an earlier GearGuide: an update, not a fresh install
        GearGuideDB = GearGuideDB or {}
        applyDefaults(GearGuideDB, defaults)
        if ns.Skin then ns.Skin:ApplyTheme(true) end  -- before any window is built, so they start in the chosen colors
        if ns.NoteVersion then ns:NoteVersion(updating) end  -- WhatsNew.lua: "NEW" badges after updates
        -- 0.15.2: the map shades whole areas now, so the game's waypoint pin is off by default
        -- (it was on before). Once; the Settings checkbox turns it back on.
        if not GearGuideDB.waypointDefaultOff then
            GearGuideDB.waypointDefaultOff = true
            GearGuideDB.map.waypoint = false
        end
        GearGuideLearned = GearGuideLearned or {}
        GearGuideLearned.items = GearGuideLearned.items or {}
        GearGuideLearned.sources = GearGuideLearned.sources or {}
        GearGuideLearned.prices = GearGuideLearned.prices or {}  -- [itemID][vendor] = { g = copper, c = costs }
        GearGuideLearned.spots = GearGuideLearned.spots or {}          -- [creature][uiMapID] = { x1, y1, ... }
        GearGuideLearned.spotZones = GearGuideLearned.spotZones or {}  -- [creature] = zone name
        GearGuideHarvest = GearGuideHarvest or {}
        GearGuideHarvest.items = GearGuideHarvest.items or {}
        GearGuideHarvest.scan = GearGuideHarvest.scan or {}
        GearGuideCharDB = GearGuideCharDB or {}
        GearGuideCharDB.acquired = GearGuideCharDB.acquired or {}
        GearGuideCharDB.spec = GearGuideCharDB.spec or "AUTO"
        GearGuideCharDB.favorites = GearGuideCharDB.favorites or {}
        if type(GearGuide_Data) ~= "table" then GearGuide_Data = {} end
        GearGuide_Data.items = GearGuide_Data.items or {}
        GearGuide_Data.meta = GearGuide_Data.meta or {}
        GearGuide_Data.sources = GearGuide_Data.sources or {}
        GearGuide_Data.locs = GearGuide_Data.locs or {}
        -- A database written in a newer format than this addon understands is ignored, not misread.
        if (GearGuide_Data.meta.format or 1) > SUPPORTED_DB_FORMAT then
            ns.dbTooNew = true
            GearGuide_Data.items, GearGuide_Data.sources = {}, {}
        end
        -- Blizzard Developer API terms: API data may be kept at most 30 days. Stale files are ignored.
        -- Data scanned from the game client (meta.source == "client") is not API data and has no TTL.
        local ts = GearGuide_Data.meta.ts
        local fromApi = GearGuide_Data.meta.source ~= "client"
        if fromApi and next(GearGuide_Data.items) ~= nil and (not ts or time() - ts > DATA_TTL_SECONDS) then
            ns.dataExpired = true
            GearGuide_Data.items = {}
        end
    elseif event == "PLAYER_LOGIN" then
        ns:CreateMinimapButton()
        ns:EnableLearning()
        ns:StartTracking()
        ns:InitHarvest()
        ns:StartComm()
        if ns.EnableCreatureTips then ns:EnableCreatureTips() end
        if GearGuideDB.mini.shown then ns:ShowMini() end
        ns:CheckDatabaseBuild()
        if ns.dbTooNew then
            ns.Print("Data.lua was built for a newer GearGuide version and was not loaded. Update the addon.")
        elseif ns.dataExpired then
            ns.Print("Item database is older than 30 days and was not loaded (Blizzard API terms). "
                .. "Update GearGuide to refresh it.")
        end  -- an empty database starts building by itself (ns:InitHarvest)
    elseif event == "PLAYER_LEVEL_UP" or event == "PLAYER_EQUIPMENT_CHANGED"
        or event == "CHARACTER_POINTS_CHANGED" or event == "PLAYER_TALENT_UPDATE"
        or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        ns:RequestRefresh()
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_GEARGUIDE1 = "/gearguide"
SLASH_GEARGUIDE2 = "/gg"
SlashCmdList.GEARGUIDE = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        ns:ToggleWindow()
        ns:AutoScanIfEmpty()
    elseif cmd == "browse" then
        ns:ShowWindow("browser")
    elseif cmd == "settings" or cmd == "config" or cmd == "options" then
        ns:ShowWindow("settings")
    elseif cmd == "rec" then
        ns:ShowWindow("recommended")
    elseif cmd == "mini" then
        local sub, arg = rest:lower():match("^(%S*)%s*(.-)$")
        local n = tonumber(sub)
        if n then
            ns:SetMiniCount(n)
        elseif sub == "auto" then
            local on = (arg == "on") or (arg ~= "off" and not GearGuideDB.mini.autoPopup)
            ns:SetMiniAutoPopup(on)
            ns.Print("Mini tracker auto-popup in zones with recommended items: " .. (on and "on" or "off"))
        elseif sub == "hover" then
            local on = (arg == "on") or (arg ~= "off" and not GearGuideDB.mini.hoverMode)
            ns:SetMiniHoverMode(on)
            ns.Print("Mini tracker hover mode: " .. (on and "on (header and background show on mouse-over)" or "off"))
        elseif sub == "scale" then
            local pct = tonumber(arg)
            if pct then ns:SetMiniScale(pct / 100) end
            ns.Print(string.format("Mini tracker scale: %d%% (/gg mini scale 60-160)", math.floor((GearGuideDB.mini.scale or 1) * 100 + 0.5)))
        elseif sub == "opacity" or sub == "alpha" then
            local pct = tonumber(arg)
            if pct then
                ns:SetMiniOpacity(pct / 100)
                ns.Print(string.format("Mini tracker background opacity: %d%%", math.floor(GearGuideDB.mini.opacity * 100 + 0.5)))
            else
                ns.Print("Usage: /gg mini opacity 0-100 (current: " .. math.floor((GearGuideDB.mini.opacity or 1) * 100 + 0.5) .. "%)")
            end
        else
            ns:ToggleMini()
        end
    elseif cmd == "unknown" then
        local want = rest:lower()
        if want == "on" or want == "off" then ns:SetShowUnknown(want == "on")
        else ns:SetShowUnknown(not GearGuideDB.showUnknown) end
    elseif cmd == "sharing" then
        local want = rest:lower()
        if want == "on" or want == "off" then ns:SetSharing(want == "on")
        else ns:SetSharing(not ns:IsSharingEnabled()) end
    elseif cmd == "dev" and rest:lower():match("^tips?") then
        -- /gg dev tips: print what each unit/item tooltip hook can read (dungeons may hide it)
        ns.tipTrace = not ns.tipTrace
        ns.Print("Tooltip trace " .. (ns.tipTrace and "on: hover a creature or item." or "off."))
    elseif cmd == "dev" and rest:lower():match("^loot") then
        ns:ToggleLootTrace()  -- /gg dev loot: print where each looted item is credited (Sources.lua)
    elseif cmd == "dev" and rest:lower():match("^toast") then
        -- /gg dev toast [itemID or shift-clicked link]: show the Gear Acquired pop-up (testing).
        -- Without an item: your top recommended pick, else a favorite. Changes no acquired marks.
        local arg = rest:match("^%S+%s+(.+)$")
        local id = arg and (tonumber(arg) or ns.LinkToId(arg))
        if not id then
            local ok, rec = pcall(ns.BuildRecommendations, ns)
            for _, g in ipairs(ok and rec and rec.groups or {}) do id = id or (g.picks[1] and g.picks[1].id) end
            id = id or ns:GetFavorites()[1]
        end
        if id then ns:ShowGearToast(id) else ns.Print("No item to show: /gg dev toast <itemID or link>") end
    elseif cmd == "dev" then
        GearGuideDB.maintainer = not GearGuideDB.maintainer
        GearGuideDB.notifiedBuild = nil
        ns.Print("Maintainer mode " .. (GearGuideDB.maintainer and "on: you'll be reminded to rescan after patches."
            or "off."))
    elseif cmd == "inspect" then
        ns:InspectTarget()  -- Party.lua: the target's gear as a build in the Build Simulator
    elseif cmd == "unmark" then
        ns:ResetAcquired()
        ns.Print("Cleared acquired marks for this character.")
    elseif cmd == "minimap" then
        GearGuideDB.minimap.hide = not GearGuideDB.minimap.hide
        ns:UpdateMinimapButton()
    elseif cmd == "spec" then
        local want = rest:lower()
        if want == "" or want == "auto" then
            ns:SetPlayerSpec("AUTO")
        else
            for _, sp in ipairs(ns:GetSpecs()) do
                if sp.key:lower() == want or sp.label:lower():find(want, 1, true) then ns:SetPlayerSpec(sp.key) end
            end
        end
        local names = {}
        for _, sp in ipairs(ns:GetSpecs()) do names[#names + 1] = sp.label end
        ns.Print("Spec: " .. ns:PlayerSpecLabel() .. "  (options: auto, " .. table.concat(names, ", ") .. ")")
    elseif cmd == "range" then
        local behind, ahead = rest:match("^(%d+)%s+(%d+)$")
        if behind then
            GearGuideDB.levelBehind, GearGuideDB.levelAhead = tonumber(behind), tonumber(ahead)
            ns:RequestRefresh()
        end
        ns.Print(string.format("Level range: %d below to %d above your level.",
            GearGuideDB.levelBehind, GearGuideDB.levelAhead))
    elseif cmd == "scan" then
        local sub, arg = rest:match("^(%S*)%s*(.-)$")
        sub = (sub or ""):lower()
        if sub == "" or sub == "start" then ns:StartScan()
        elseif sub == "full" then ns:StartScan(tonumber(arg) or 400000)
        elseif sub == "extend" then ns:ExtendScan(tonumber(arg))
        elseif sub == "pause" or sub == "stop" then ns:PauseScan()
        elseif sub == "reset" then ns:ResetScan()
        else ns.Print(ns:ScanStatus()) end
    elseif cmd == "ej" then
        ns:ImportEncounterJournal()
    elseif cmd == "status" then
        local db, learned = 0, 0
        for _ in pairs(GearGuide_Data.items) do db = db + 1 end
        for _ in pairs(GearGuideLearned.items) do learned = learned + 1 end
        ns.Print(string.format("Data.lua: %d items (generated %s, %s). Learned in game: %d.",
            db, tostring(GearGuide_Data.meta.generated), tostring(GearGuide_Data.meta.source or GearGuide_Data.meta.namespace), learned))
        ns.Print("Client scan: " .. ns:ScanStatus())
    elseif cmd == "forget" then
        GearGuideLearned.items, GearGuideLearned.sources, GearGuideLearned.prices = {}, {}, {}
        GearGuideLearned.spots, GearGuideLearned.spotZones = {}, {}
        GearGuideLearned.shared, GearGuideLearned.variants = {}, {}
        ns:InvalidateItems()
        if ns.InvalidateSpotNames then ns:InvalidateSpotNames() end
        ns:RequestRefresh()
        ns.Print("Forgot all items, sources and variants learned in game or shared by other players.")
    else
        ns.Print("Commands: /gg (toggle window), /gg browse, /gg rec, /gg settings, /gg inspect (target's gear into the Build Simulator), /gg mini [count|auto|hover|opacity 0-100|scale 60-160], /gg minimap, "
            .. "/gg spec [name], /gg range <below> <above>, /gg sharing [on|off], /gg unknown [on|off], /gg ej, /gg scan [pause|status|reset|full|extend], /gg status, /gg unmark, /gg forget")
    end
end
