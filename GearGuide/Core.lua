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
    window = { w = 760, h = 480 },
    mini = { shown = false, count = 10, hideCompleted = false },
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

function ns.ItemIcon(id)
    local icon
    if C_Item and C_Item.GetItemIconByID then
        icon = C_Item.GetItemIconByID(id)
    elseif GetItemIcon then
        icon = GetItemIcon(id)
    end
    return icon or ns.QUESTION_ICON
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

function ns.ReadStats(link)
    local out = {}
    local raw = getItemStats and getItemStats(link)
    if raw then
        for k, v in pairs(raw) do
            local key = STAT_MAP[k]
            if key then out[key] = (out[key] or 0) + v end
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
-- Item access: generated database merged with items learned in game
---------------------------------------------------------------------------
-- Three layers: items scanned from this game client (newest), the shipped/generated Data.lua,
-- and items learned from loot/quest/vendor windows.
function ns:GetItem(id)
    return GearGuideHarvest.items[id] or GearGuide_Data.items[id] or GearGuideLearned.items[id]
end

function ns:AllItemIds()
    if self.idCache then return self.idCache end
    local list, seen = {}, {}
    for _, layer in ipairs({ GearGuideHarvest.items, GearGuide_Data.items, GearGuideLearned.items }) do
        for id in pairs(layer) do
            if not seen[id] then seen[id] = true; list[#list + 1] = id end
        end
    end
    self.idCache = list
    return list
end

function ns:InvalidateItems()
    self.idCache = nil
    self:RequestRefresh()
end

-- "A" (Alliance) or "H" (Horde); nil before the faction is known (e.g. Pandaren choosing).
function ns.PlayerFaction()
    local group = UnitFactionGroup and UnitFactionGroup("player")
    return (group == "Alliance" and "A") or (group == "Horde" and "H") or nil
end

function ns:GetSources(id)
    local out, seen = {}, {}
    local faction = ns.PlayerFaction()
    local function add(list)
        for _, s in ipairs(list or {}) do
            local key = (s.t or "") .. "|" .. (s.n or "") .. "|" .. (s.z or "")
            -- Hide the other faction's quests, city vendors and PvP rewards.
            local mine = not s.f or not faction or s.f == faction
            if mine and not seen[key] then seen[key] = true; out[#out + 1] = s end
        end
    end
    local dbItem = GearGuide_Data.items[id]
    if dbItem and dbItem.src then
        -- Format 2 stores each source once in GearGuide_Data.sources; items hold indices.
        local pool, locs, resolved = GearGuide_Data.sources, GearGuide_Data.locs, {}
        for _, s in ipairs(dbItem.src) do
            if type(s) == "number" then s = pool and pool[s] end
            if type(s) == "table" then
                if s.l and locs and locs[s.l] and not s.loc then
                    s = { t = s.t, n = s.n, z = s.z, k = s.k, f = s.f, loc = locs[s.l] }  -- format 3: map location
                end
                resolved[#resolved + 1] = s
            end
        end
        add(resolved)
    end
    add(GearGuideLearned.sources[id])
    if ns.GetSharedSources then add(ns:GetSharedSources(id)) end  -- from other GearGuide users
    return out
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

function ns.FormatSource(s)
    local text = (SOURCE_LABELS[s.t] or s.t or "?") .. ": " .. (s.n or "?")
    local zone = ns.ZoneName(s.z)
    if zone and zone ~= "" then text = text .. " (" .. zone .. ")" end
    if s.shared then text = text .. " |cff888888(shared by players)|r" end
    if s.k == "guess" then text = text .. " |cff888888(likely)|r" end
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
    local points = {}
    for i = 1, #(entry.p or {}) - 1, 2 do
        points[#points + 1] = { x = entry.p[i] / 100, y = entry.p[i + 1] / 100 }
    end
    local kind = entry.e and "entrance" or (s.k == "object" and "object") or s.t
    local sub = ns.FormatSource(s)
    if entry.e then sub = sub .. " - dungeon entrance" end
    if #s.loc > 1 then sub = sub .. string.format("  (location %d of %d, click again for the next)", lastIndex, #s.loc) end
    self:ShowOnMap({ map = entry.m, points = points, title = s.n, sub = sub, kind = kind })
end

function ns:SourceSummary(id)
    local list = self:GetSources(id)
    if #list == 0 then return "|cff888888Source unknown|r" end
    local text = ns.FormatSource(list[1])
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
    self:RequestRefresh()
end

function ns:ToggleFavorite(id)
    self:SetFavorite(id, not self:IsFavorite(id))
    return self:IsFavorite(id)
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
    if chosen and chosen ~= "AUTO" then
        for _, s in ipairs(self:GetSpecs()) do
            if s.key == chosen then return chosen end
        end
    end
    local detected = self:DetectPlayerSpec()
    return detected or (self:GetSpecs()[1] or {}).key
end

-- key = a spec key or "AUTO" (follow talents).
function ns:SetPlayerSpec(key)
    GearGuideCharDB.spec = key or "AUTO"
    self:RequestRefresh()
end

function ns:IsSpecAuto()
    return not GearGuideCharDB or not GearGuideCharDB.spec or GearGuideCharDB.spec == "AUTO"
end

function ns:SpecLabel(class, key)
    local s = self:GetSpecInfo(class, key)
    return s and s.label or "?"
end

-- "Auto (Fury)" or "Fury"
function ns:PlayerSpecLabel()
    local label = self:SpecLabel(nil, self:GetPlayerSpec())
    if self:IsSpecAuto() then return "Auto (" .. label .. ")" end
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
    if item.rl and item.rl > 0 then return item.rl end
    return math.max(1, (item.il or 1) - 5)
end

-- Wraps the user-defined ScoreItem so a bug there can't break the whole UI.
local RANGED_LOCS = { INVTYPE_RANGED = true, INVTYPE_RANGEDRIGHT = true, INVTYPE_THROWN = true }
local rangedWeights = setmetatable({}, { __mode = "k" })  -- weights table -> copy with DPS = RDPS

-- Ranged weapons use the RDPS weight for their DPS when the spec defines one (hunters' bows vs.
-- melee stat sticks), so ScoreItem can keep reading weights.DPS.
local function weightsFor(item, weights)
    if not (weights.RDPS and RANGED_LOCS[item.eq]) then return weights end
    local w = rangedWeights[weights]
    if not w then
        w = {}
        for k, v in pairs(weights) do w[k] = v end
        w.DPS = weights.RDPS
        rangedWeights[weights] = w
    end
    return w
end

function ns:Score(item, weights, ctx)
    weights = weightsFor(item, weights)
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
    if self.refreshPending then return end
    self.refreshPending = true
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
        GearGuideDB = GearGuideDB or {}
        applyDefaults(GearGuideDB, defaults)
        GearGuideLearned = GearGuideLearned or {}
        GearGuideLearned.items = GearGuideLearned.items or {}
        GearGuideLearned.sources = GearGuideLearned.sources or {}
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
        if GearGuideDB.mini.shown then ns:ShowMini() end
        ns:CheckDatabaseBuild()
        if ns.dbTooNew then
            ns.Print("Data.lua was built for a newer GearGuide version and was not loaded. Update the addon.")
        elseif ns.dataExpired then
            ns.Print("Item database is older than 30 days and was not loaded (Blizzard API terms). "
                .. "Re-run GearGuideTools/update_db.py to refresh it.")
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
    elseif cmd == "rec" then
        ns:ShowWindow("recommended")
    elseif cmd == "mini" then
        local n = tonumber(rest)
        if n then ns:SetMiniCount(n) else ns:ToggleMini() end
    elseif cmd == "sharing" then
        local want = rest:lower()
        if want == "on" or want == "off" then ns:SetSharing(want == "on")
        else ns:SetSharing(not ns:IsSharingEnabled()) end
    elseif cmd == "dev" then
        GearGuideDB.maintainer = not GearGuideDB.maintainer
        GearGuideDB.notifiedBuild = nil
        ns.Print("Maintainer mode " .. (GearGuideDB.maintainer and "on: you'll be reminded to rescan after patches."
            or "off."))
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
        GearGuideLearned.items, GearGuideLearned.sources = {}, {}
        ns:InvalidateItems()
        ns.Print("Forgot all items and sources learned in game.")
    else
        ns.Print("Commands: /gg (toggle window), /gg browse, /gg rec, /gg mini [count], /gg minimap, "
            .. "/gg spec [name], /gg range <below> <above>, /gg sharing [on|off], /gg ej, /gg scan [pause|status|reset|full|extend], /gg status, /gg unmark, /gg forget")
    end
end
