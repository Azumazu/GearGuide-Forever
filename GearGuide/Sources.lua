local _, ns = ...

-- Learns gear and where it comes from by watching what the player actually sees:
-- loot windows, quest rewards (talking to NPCs and the whole quest log), vendor lists and
-- profession windows. Everything stays in GearGuideLearned; build_db.py can bake it into Data.lua.

local MAX_SOURCES_PER_ITEM = 10
local pending = {}  -- itemID -> { link, src } waiting for the client to cache item info

-- Names that aren't a real source: the client hadn't loaded the creature's name yet, or an
-- opened container. Never stored (older versions did; they are hidden when read back too).
local JUNK_NAMES = { [""] = true, ["?"] = true, ["Unknown"] = true, ["Container"] = true }
function ns.IsJunkSourceName(n)
    return type(n) ~= "string" or JUNK_NAMES[n] or (UNKNOWNOBJECT and n == UNKNOWNOBJECT) or false
end

-- Already among the player's own finds? (Checked first: most loot repeats what's known.)
local function hasOwnSource(id, src)
    for _, s in ipairs(GearGuideLearned.sources[id] or {}) do
        if s.t == src.t and s.n == src.n and s.z == src.z then return true end
    end
    return false
end

local function addSource(id, src)
    if ns.IsJunkSourceName(src.n) then return false end
    local list = GearGuideLearned.sources[id]
    if not list then
        list = {}
        GearGuideLearned.sources[id] = list
    end
    for _, s in ipairs(list) do
        if s.t == src.t and s.n == src.n and s.z == src.z then return false end
    end
    if #list < MAX_SOURCES_PER_ITEM then
        list[#list + 1] = src
        return true
    end
    return false
end

-- A mount, toy or recipe (Gear Browser "Additional drops"): "m", "t", "r", or nil.
local function extraKindOf(id, instant)
    local _, _, _, _, _, classID, subclassID = instant(id)
    if classID == 9 and (subclassID or 0) > 0 then return "r" end   -- recipes (not class books)
    if classID == 15 and subclassID == 5 then return "m" end
    if C_ToyBox and C_ToyBox.GetToyInfo then
        local ok, toy = pcall(C_ToyBox.GetToyInfo, id)
        if ok and toy then return "t" end
    end
end

function ns:LearnLink(link, src)
    local id = ns.LinkToId(link)
    if not id then return end
    local item = self:GetItem(id)
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local kind = not item and instant and extraKindOf(id, instant)
    if kind then
        -- Not in the database yet: a small record, the client knows the rest.
        local name, _, quality, _, reqLevel = ns.GetItemInfo(id)
        if not name then
            pending[id] = { link = link, src = src }  -- retried on GET_ITEM_INFO_RECEIVED
            return
        end
        item = { n = name, q = quality, rl = (reqLevel or 0) > 0 and reqLevel or nil, x = kind }
        GearGuideLearned.items[id] = item
        self:InvalidateItems()
    end
    if not item then
        -- Not gear (cloth, potions...): stop before the full record and tooltip scan.
        local equip = instant and select(4, instant(id))
        if equip ~= nil and not ns.EQUIPLOC_GROUP[equip] then return end
        -- The base item (no random bonus): a looted "...of the Falcon" link would store that
        -- variant's name and stats as the item's own.
        item = self:BuildFullRecord("item:" .. id)
        if not item then
            pending[id] = { link = link, src = src }  -- retried on GET_ITEM_INFO_RECEIVED
            return
        end
        if not ns.EQUIPLOC_GROUP[item.eq] then return end  -- not gear
        GearGuideLearned.items[id] = item
        self:InvalidateItems()
    end
    -- A random variant ("...of the Falcon") is credited to the base item; its bonus is remembered.
    self:RememberVariant(id, self:LinkVariant(link))
    if not src or hasOwnSource(id, src) then return end  -- known: skip the source list lookups below
    -- A creature nobody listed yet for this item (shipped data, own or shared finds): announce it.
    local fresh = src and src.t == "drop" and src.n and src.n ~= "Container" and not self:ListsDropper(id, src.n)
    if not (src and addSource(id, src)) then return end
    if src.t == "drop" and ns.InvalidateSpotNames then ns:InvalidateSpotNames() end
    if ns.QueueShare and self:IsSharingEnabled() then
        -- Not shared when everyone knows it already (shipped data, world drop, enough reports).
        ns:QueueShare(id, src, self:IsSettledSource(id, src))
    end
    self:InvalidateSourceIndexes()  -- an item's first source can make it listable
    -- Only if it's really listed now (GetSources hides misattributed drops from known loot tables).
    if fresh and self:ListsDropper(id, src.n) then self:AnnounceNewDrop(id, link) end
end

-- Does the item's source list (as the player sees it) already name this creature?
function ns:ListsDropper(id, name)
    local world = self:WorldDropsOf(name)  -- a world drop's creatures share one source line
    if world and world[id] then return true end
    for _, s in ipairs(self:GetSources(id)) do
        if s.t == "drop" and s.n == name then return true end
    end
    return false
end

-- "New drop location discovered for [item]": on screen (like quest progress) and in chat (with the
-- clickable item link). Settings: General > "Announce new drop locations".
function ns:AnnounceNewDrop(id, link)
    if GearGuideDB and GearGuideDB.announceDrops == false then return end
    local item = self:GetItem(id)
    local name = (item and item.n) or ns.GetItemInfo(id) or ("item " .. id)
    local hex = ns.QualityHex(item and item.q or 1)
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage("New drop location discovered for " .. hex .. name .. "|r", 1, 0.82, 0)
    end
    ns.Print("New drop location discovered for " .. (link or (hex .. "[" .. name .. "]|r")))
end

local function zone()
    return ns.Plain(GetRealZoneText()) or ""
end

---------------------------------------------------------------------------
-- Loot: who dropped it. Loot slots carry the source's GUID (GetLootSourceInfo); names come from
-- a small GUID -> name cache filled from units the player targets or mouses over.
---------------------------------------------------------------------------
local nameByGUID, levelByGUID, nameCount = {}, {}, 0
-- By creature type (the NPC ID in the GUID): a name seen once for any Krol'dok Brute names the
-- loot of every Krol'dok Brute, also ones never targeted. Session only.
local nameByNpc, levelByNpc = {}, {}
local function npcOf(guid)
    return type(guid) == "string" and guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)") or nil
end
local Plain = ns.Plain  -- secret values (GUIDs/names the client protects) become nil

local function rememberUnit(unit)
    local guid = Plain(UnitGUID and UnitGUID(unit))
    if not guid or nameByGUID[guid] then return end
    if Plain(UnitIsPlayer(unit)) ~= false then return end  -- players (or unknown) aren't loot sources
    local name = Plain(UnitName(unit))
    if not name then return end
    if nameCount > 300 then wipe(nameByGUID); wipe(levelByGUID); nameCount = 0 end  -- keep it small
    nameByGUID[guid] = name
    levelByGUID[guid] = Plain(UnitLevel and UnitLevel(unit))
    nameCount = nameCount + 1
    local npc = npcOf(guid)
    if npc then nameByNpc[npc], levelByNpc[npc] = name, levelByGUID[guid] end
end

-- Who dropped the item in this loot slot: name and level (nil level = unknown or a boss), or nil
-- when it can't be told. Third value true: it was a creature (or the client hid what it was),
-- only its name is unknown; inside a dungeon the dungeon itself is then credited. Loot from a bag, box or other container item, fishing or anything else
-- that isn't a creature or chest is not learned: naming it after the creature that happens to be
-- targeted credited raid gear in a container to the last Stonetusk Boar killed.
local function lootSource(slot)
    if type(GetLootSourceInfo) == "function" then
        local guid = Plain(GetLootSourceInfo(slot))
        if guid then
            local kind = guid:match("^(%a+)")
            if kind == "GameObject" then return "Container" end
            if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
            if nameByGUID[guid] then return nameByGUID[guid], levelByGUID[guid] end
            if Plain(UnitGUID("target")) == guid then  -- the very creature, not just any dead target
                local name = Plain(UnitName("target"))
                if name then return name, Plain(UnitLevel("target")) end
            end
            local npc = npcOf(guid)
            if npc and nameByNpc[npc] then return nameByNpc[npc], levelByNpc[npc] end
            return nil, nil, true
        end
        -- The client didn't say (or hid it: dungeons can hide unit data): don't guess a creature.
        return nil, nil, GetLootSourceInfo(slot) ~= nil
    end
    -- Clients without GetLootSourceInfo: the dead creature being targeted is the best guess.
    if Plain(UnitExists("target")) and Plain(UnitIsDead("target")) then
        return Plain(UnitName("target")), Plain(UnitLevel("target"))
    end
    return nil
end

-- A level 10 boar can't drop level 60 raid gear: skip drops far above the creature's level.
local function plausibleDrop(link, level)
    if not level or level <= 0 then return true end  -- unknown, or a boss ("??")
    local id = ns.LinkToId(link)
    local item = id and ns:GetItem(id)
    local _, _, _, _, minLevel = ns.GetItemInfo(link)
    local need = (item and item.rl) or minLevel or 0
    return need <= level + 10
end

---------------------------------------------------------------------------
-- Creature spots: where creatures that drop gear but have no known map location are found (most
-- are WoW: Forever's own creatures: neither Questie nor the build's databases place them).
-- Recorded when the player loots one or targets one up close: the player's own map position is
-- then within a few yards of the creature. Inside instances there are no coordinates; the
-- instance's name is kept instead. GearGuideLearned.spots[name] = { [uiMapID] = { x1, y1, ... } },
-- GearGuideLearned.spotZones[name] = zone name. The build bakes them into Data.lua.
---------------------------------------------------------------------------
local SPOTS_PER_MAP = 30
local SPOT_MIN_GAP = 1.5      -- map % between kept spots of the same creature
local wantedNames             -- creature names that drop gear and have no map location

function ns:InvalidateSpotNames() wantedNames = nil; ns:InvalidateSourcesCache() end

local function buildWanted()
    wantedNames = {}
    local pool = GearGuide_Data and GearGuide_Data.sources or {}
    -- Creatures that drop gear and vendors that sell it (WoW: Forever's quartermasters).
    local function placeable(s)
        return type(s) == "table" and s.n and (s.t == "drop" and s.k ~= "object" or s.t == "vendor")
    end
    for _, s in pairs(pool) do
        if placeable(s) and not s.l and not s.loc then wantedNames[s.n] = true end
    end
    for _, list in pairs(GearGuideLearned.sources or {}) do
        for _, s in ipairs(list) do
            if placeable(s) and s.n ~= "Container" then wantedNames[s.n] = true end
        end
    end
    -- Names that do have a shipped location don't need spots (learned sources may repeat them).
    for _, s in pairs(pool) do
        if placeable(s) and s.l then wantedNames[s.n] = nil end
    end
end

local function recordSpot(name)
    if not name then return end
    if not wantedNames then buildWanted() end
    if not wantedNames[name] then return end
    GearGuideLearned.spots = GearGuideLearned.spots or {}
    GearGuideLearned.spotZones = GearGuideLearned.spotZones or {}
    local inInstance = IsInInstance and Plain(IsInInstance())
    local zoneName = Plain(GetRealZoneText and GetRealZoneText())
    if zoneName and zoneName ~= "" and not GearGuideLearned.spotZones[name] then
        GearGuideLearned.spotZones[name] = zoneName
    end
    if inInstance or not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return end
    local map = Plain(C_Map.GetBestMapForUnit("player"))
    local pos = map and C_Map.GetPlayerMapPosition(map, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    x, y = Plain(x), Plain(y)
    if not x or not y or (x == 0 and y == 0) then return end
    x, y = math.floor(x * 1000 + 0.5) / 10, math.floor(y * 1000 + 0.5) / 10
    local byMap = GearGuideLearned.spots[name] or {}
    GearGuideLearned.spots[name] = byMap
    local list = byMap[map] or {}
    byMap[map] = list
    if #list / 2 >= SPOTS_PER_MAP then return end
    for i = 1, #list - 1, 2 do
        if math.abs(list[i] - x) < SPOT_MIN_GAP and math.abs(list[i + 1] - y) < SPOT_MIN_GAP then return end
    end
    ns:InvalidateSourcesCache()  -- a new spot: map locations in source lists change
    list[#list + 1], list[#list + 2] = x, y
end
ns.RecordCreatureSpot = recordSpot  -- (tests)

-- Targeting a creature up close (about 28 yards) also places it.
local function onTargetChanged()
    local name = Plain(UnitName("target"))
    if not name or Plain(UnitIsPlayer("target")) ~= false then return end
    if InCombatLockdown and InCombatLockdown() then return end
    local ok, near = pcall(CheckInteractDistance, "target", 4)
    if ok and Plain(near) then recordSpot(name) end
end

-- /gg dev loot: prints what the client reports for every loot slot and what GearGuide makes of it
-- (diagnosing drops that aren't credited). Never prints a secret value itself.
local function show(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "SECRET" end
    return tostring(v)
end

local function traceLoot(i, link, name, level)
    local rawGuid = type(GetLootSourceInfo) == "function" and GetLootSourceInfo(i) or nil
    local guid = Plain(rawGuid)
    local tgt = UnitGUID and UnitGUID("target")
    local kind = GetLootSlotType and show(GetLootSlotType(i)) or "?"
    local plainLink = Plain(link)
    ns.Print(string.format("loot %d (type %s): %s | source GUID %s (%s) | cached name %s | target GUID %s, %s, dead %s"
        .. " | -> %s (level %s)%s",
        i, kind, link == nil and "no link" or (plainLink or "SECRET link"), show(rawGuid), guid and (guid:match("^(%a+)") or "?") or "-",
        show(guid and nameByGUID[guid]), show(tgt), show(UnitName and UnitName("target")),
        show(UnitIsDead and UnitIsDead("target")), show(name), show(level),
        (plainLink and name and not plausibleDrop(plainLink, level)) and " | rejected: item level too high" or ""))
end

function ns:ToggleLootTrace()
    self.lootTrace = not self.lootTrace
    ns.Print("Loot trace " .. (self.lootTrace and "on: loot something, the details print here." or "off."))
end

-- Looting inside a dungeon or raid marks its zone as an instance, so the Gear Browser's dungeon
-- menu lists dungeons the shipped data doesn't know yet (with what was looted there).
local function rememberInstanceZone(z)
    if z == "" or not IsInInstance then return end
    local inside, kind = IsInInstance()
    inside, kind = Plain(inside), Plain(kind)
    if not inside or (kind ~= "party" and kind ~= "raid") then return end
    GearGuideLearned.instanceZones = GearGuideLearned.instanceZones or {}
    if GearGuideLearned.instanceZones[z] ~= kind then
        GearGuideLearned.instanceZones[z] = kind
        ns.instanceIndex, ns.zoneIndex = nil, nil
    end
end
ns.RememberInstanceZone = rememberInstanceZone  -- (tests)

-- Inside a party/raid dungeon: its name, else nil.
local function dungeonName()
    if not IsInInstance then return nil end
    local inside, kind = IsInInstance()
    inside, kind = Plain(inside), Plain(kind)
    if not inside or (kind ~= "party" and kind ~= "raid") then return nil end
    local z = zone()
    return z ~= "" and z or nil
end

-- Loot whose creature can't be named, from inside a dungeon: credited to the dungeon itself
-- ("Drop: Krol'dok Stronghold"), so it is listed with the dungeon's loot and shared. Not when a
-- named creature of this dungeon is already known for the item (that's the better source).
function ns:LearnDungeonDrop(link, dungeon)
    local id = ns.LinkToId(link)
    if not id or not dungeon then return end
    for _, list in ipairs({ GearGuideLearned.sources[id] or {}, ns:GetSources(id) }) do
        for _, s in ipairs(list) do
            if s.t == "drop" and ns.ZoneName(s.z) == dungeon then return end
        end
    end
    ns:LearnLink(link, { t = "drop", n = dungeon, z = dungeon })
end

local readyCount  -- slots read at LOOT_READY; LOOT_OPENED for the same window then has nothing new
local function onLootOpened(event)
    local slots = GetNumLootItems() or 0
    if event == "LOOT_OPENED" then
        local done = readyCount and readyCount > 0 and readyCount == slots
        readyCount = nil
        if done then return end
    else
        readyCount = slots
    end
    local z = zone()
    rememberInstanceZone(z)
    local dungeon = dungeonName()
    local spotted = {}
    local n = GetNumLootItems()
    if ns.lootTrace then ns.Print(string.format("%s: %s slot(s)", event or "loot", show(n))) end
    for i = 1, n do
        local rawLink = GetLootSlotLink(i)
        local link = Plain(rawLink)
        local name, level, creature = lootSource(i)
        if ns.lootTrace then
            local ok, err = pcall(traceLoot, i, rawLink, name, level)
            if not ok then ns.Print(string.format("loot %d: trace failed (%s)", i, tostring(err))) end
        end
        if link and name and plausibleDrop(link, level) then
            ns:LearnLink(link, { t = "drop", n = name, z = z })
        elseif link and not name and creature and dungeon then
            if ns.lootTrace then ns.Print(string.format("loot %d: creature unknown, credited to %s", i, dungeon)) end
            ns:LearnDungeonDrop(link, dungeon)
        end
        if name and name ~= "Container" and not spotted[name] then
            spotted[name] = true
            recordSpot(name)
        end
    end
end

---------------------------------------------------------------------------
-- Quests: the reward panel while talking to an NPC, and every quest in the log.
---------------------------------------------------------------------------
local function onQuestRewards()
    local src = { t = "quest", n = GetTitleText() or "?", z = zone() }
    for i = 1, (GetNumQuestChoices() or 0) do
        ns:LearnLink(GetQuestItemLink("choice", i), src)
    end
    for i = 1, (GetNumQuestRewards() or 0) do
        ns:LearnLink(GetQuestItemLink("reward", i), src)
    end
end

local questLogScanned = {}  -- quest title -> true, so each quest is read once per session
local function scanQuestLog()
    if type(GetNumQuestLogEntries) ~= "function" or type(GetQuestLogTitle) ~= "function"
        or type(SelectQuestLogEntry) ~= "function" or type(GetQuestLogItemLink) ~= "function" then
        return
    end
    local previous = GetQuestLogSelection and GetQuestLogSelection() or 0
    local header, selected = "", false
    ns.scanningQuestLog = true  -- our own SelectQuestLogEntry calls: Badges' hook ignores them
    for i = 1, (GetNumQuestLogEntries() or 0) do
        local title, _, _, isHeader = GetQuestLogTitle(i)
        if isHeader then
            header = title or ""
        elseif title and not questLogScanned[title] then
            questLogScanned[title] = true
            SelectQuestLogEntry(i)
            selected = true
            local src = { t = "quest", n = title, z = header }
            for j = 1, (GetNumQuestLogChoices and GetNumQuestLogChoices() or 0) do
                local link = GetQuestLogItemLink("choice", j)
                if link then ns:LearnLink(link, src) end
            end
            for j = 1, (GetNumQuestLogRewards and GetNumQuestLogRewards() or 0) do
                local link = GetQuestLogItemLink("reward", j)
                if link then ns:LearnLink(link, src) end
            end
        end
    end
    -- Put the player's quest log selection back, only if a new quest was read (each quest is read
    -- once per session: most scans read nothing and touch nothing).
    if selected then SelectQuestLogEntry(previous) end
    ns.scanningQuestLog = false
end

local questLogTimer
local function scheduleQuestLogScan()
    if questLogTimer then return end
    questLogTimer = C_Timer.NewTimer(2, function()
        questLogTimer = nil
        if not InCombatLockdown or not InCombatLockdown() then scanQuestLog() end
    end)
end

---------------------------------------------------------------------------
-- Vendors and professions
---------------------------------------------------------------------------
local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant or function() end

-- Copper price (as shown, so reputation discounts included) and whether extra costs exist.
-- Newer clients moved this into C_MerchantFrame.GetItemInfo (a table); older ones return values.
local function merchantPrice(i)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(i)
        if type(info) == "table" then return info.price, info.hasExtendedCost end
    end
    if GetMerchantItemInfo then
        local _, _, price, _, _, _, _, extendedCost = GetMerchantItemInfo(i)
        return price, extendedCost
    end
end

-- Every non-gold cost: tokens, marks, currencies. { {n = name, q = amount, i = icon}, ... }
local function merchantCosts(i)
    if not (GetMerchantItemCostInfo and GetMerchantItemCostItem) then return nil end
    local r = { GetMerchantItemCostInfo(i) }
    local count = tonumber(r[#r]) or 0
    local out, seen = {}, {}
    for j = 1, count do
        local icon, amount, link, currencyName = GetMerchantItemCostItem(i, j)
        local name = currencyName or (link and link:match("%[(.-)%]"))
        if name and (amount or 0) > 0 then
            out[#out + 1] = { n = name, q = amount, i = icon }
            seen[name:lower():gsub(" points?$", "")] = true
        end
    end
    -- Clients with the older signature return honor, arena points, count: those points are not in
    -- the cost-item list above, so add them (once, if the list didn't already name them).
    if #r >= 3 then
        local faction = UnitFactionGroup and Plain(UnitFactionGroup("player"))
        local points = {
            { tonumber(r[1]), "Honor Points", "honor",
              "Interface\\PVPFrame\\PVP-Currency-" .. (faction == "Horde" and "Horde" or "Alliance") },
            { tonumber(r[2]), "Arena Points", "arena", "Interface\\PVPFrame\\PVP-ArenaPoints-Icon" },
        }
        for k = #points, 1, -1 do
            local amount, name, key, icon = points[k][1], points[k][2], points[k][3], points[k][4]
            if (amount or 0) > 0 and not seen[key] then table.insert(out, 1, { n = name, q = amount, i = icon }) end
        end
    end
    return out[1] and out or nil
end

-- Remembers what this vendor charges for the item (latest visit wins).
-- "Requires Nightclaw Druids - Revered" on a vendor's item: WoW: Forever's factions aren't in the
-- build's reputation data, so it is read here. GearGuideLearned.reps[itemID] = { n = faction
-- name, s = standing (5 Friendly ... 8 Exalted), f = faction ID when the player has met it }.
local repPattern
local function readRep(i, link)
    if not repPattern then
        local fmt = ITEM_REQ_REPUTATION or "Requires %s - %s"
        repPattern = "^" .. fmt:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1"):gsub("%%s", "(.+)") .. "$"
    end
    local data
    if C_TooltipInfo then
        local ok, d = pcall(C_TooltipInfo.GetMerchantItem or C_TooltipInfo.GetHyperlink,
            C_TooltipInfo.GetMerchantItem and i or link)
        data = ok and d or nil
    end
    for _, line in ipairs(type(data) == "table" and data.lines or {}) do
        local text = Plain(line.leftText)
        if type(text) == "string" then
            local faction, standing = text:match(repPattern)  -- (not "a and f()": that keeps one value)
            local s = standing and ns.StandingFromName(standing)
            if s then return faction, s end
        end
    end
end

local function learnRep(id, i, link)
    local faction, standing = readRep(i, link)
    if not faction then return end
    GearGuideLearned.reps = GearGuideLearned.reps or {}
    local old = GearGuideLearned.reps[id]
    local fid = ns.FactionIdByName(faction)
    if not (old and old.n == faction and old.s == standing and (old.f or not fid)) then
        GearGuideLearned.reps[id] = { n = faction, s = standing, f = fid }
    end
end

local MAX_PRICE_VENDORS = 8  -- vendor prices kept per item
local pricesChanged = false
local function learnPrice(id, vendor, i)
    local okP, price, extended = pcall(merchantPrice, i)
    local okC, costs = true, nil
    if extended ~= false then okC, costs = pcall(merchantCosts, i) end
    if not okP then price = nil end
    if not okC then costs = nil end
    if not ((price or 0) > 0 or costs) then return end
    local byVendor = GearGuideLearned.prices[id] or {}
    GearGuideLearned.prices[id] = byVendor
    if not byVendor[vendor] then
        local n = 0
        for _ in pairs(byVendor) do n = n + 1 end
        if n >= MAX_PRICE_VENDORS then return end  -- the same item at every vendor: a few are enough
    end
    byVendor[vendor] = { g = (price or 0) > 0 and price or nil, c = costs }
    pricesChanged = true
end

local function onMerchantShow()
    local vendor = Plain(UnitName("npc")) or "?"
    local z = zone()
    local sellsGear = false
    for i = 1, (GetMerchantNumItems() or 0) do
        local link = GetMerchantItemLink(i)
        if link then
            ns:LearnLink(link, { t = "vendor", n = vendor, z = z })  -- own table per item
            -- Gear only; the instant lookup knows the slot even before the item is cached.
            local id, _, _, equipLoc = getInstant(link)
            if id and ns.EQUIPLOC_GROUP[equipLoc] then
                learnPrice(id, vendor, i)
                pcall(learnRep, id, i, link)
                sellsGear = true
            end
        end
    end
    -- A vendor of gear without a known location: the player stands next to it (map pin).
    if sellsGear then recordSpot(vendor) end
    if pricesChanged then pricesChanged = false; ns:InvalidateSourcesCache() end  -- prices show in source lines
end

local function onTradeSkillShow()
    if type(GetNumTradeSkills) ~= "function" or type(GetTradeSkillItemLink) ~= "function" then return end
    local profession = GetTradeSkillLine and GetTradeSkillLine() or "Profession"
    local src = { t = "craft", n = profession, z = "" }
    for i = 1, (GetNumTradeSkills() or 0) do
        local _, kind = GetTradeSkillInfo(i)
        if kind ~= "header" then
            local link = GetTradeSkillItemLink(i)
            if link then ns:LearnLink(link, src) end
        end
    end
end

local function safeRegister(frame, event)
    pcall(frame.RegisterEvent, frame, event)  -- not every client has every event
end

-- Loot the party gets that this player may never see in a loot window: items up for a roll, and
-- "<name> receives loot: [item]" lines. Neither says which creature dropped it, so only inside a
-- dungeon, credited to the dungeon (LearnDungeonDrop). Chat can be hidden from addons in
-- dungeons; then only rolls count.
local LOOT_LINE = "|Hitem:[%-%d:]+|h"
local function onPartyLoot(link)
    local dungeon = dungeonName()
    if not dungeon or not link then return end
    rememberInstanceZone(dungeon)
    local id, _, _, equipLoc = (C_Item and C_Item.GetItemInfoInstant or GetItemInfoInstant or function() end)(link)
    if id and equipLoc and equipLoc ~= "" and not ns.EQUIPLOC_GROUP[equipLoc] then return end  -- not gear
    if ns.lootTrace then ns.Print("party loot: " .. tostring(link) .. " -> " .. dungeon) end
    ns:LearnDungeonDrop(link, dungeon)
end

local function onLootChat(msg)
    msg = Plain(msg)
    if type(msg) ~= "string" then return end
    local link = msg:match("(|c%x+" .. LOOT_LINE .. "%[.-%]|h|r)") or msg:match("(" .. LOOT_LINE .. "%[.-%]|h)")
    if link then onPartyLoot(link) end
end

local function onLootRoll(rollID)
    local link = Plain(GetLootRollItemLink and GetLootRollItemLink(rollID))
    if link then onPartyLoot(link) end
end

local tradeTimer
function ns:EnableLearning()
    local f = CreateFrame("Frame")
    -- LOOT_READY comes first: with auto loot the items can already be gone by LOOT_OPENED.
    -- LOOT_OPENED is skipped when LOOT_READY already read the same slots.
    for _, e in ipairs({ "LOOT_READY", "LOOT_OPENED", "LOOT_CLOSED", "START_LOOT_ROLL", "CHAT_MSG_LOOT", "QUEST_DETAIL", "QUEST_COMPLETE", "MERCHANT_SHOW",
        "GET_ITEM_INFO_RECEIVED", "QUEST_LOG_UPDATE", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE",
        "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED" }) do
        safeRegister(f, e)
    end
    f:SetScript("OnEvent", function(_, event, arg1)
        if event == "LOOT_READY" or event == "LOOT_OPENED" then
            onLootOpened(event)
        elseif event == "LOOT_CLOSED" then
            readyCount = nil
        elseif event == "START_LOOT_ROLL" then
            local rollID = arg1
            if C_Timer and C_Timer.After then C_Timer.After(0, function() pcall(onLootRoll, rollID) end)
            else pcall(onLootRoll, rollID) end
        elseif event == "CHAT_MSG_LOOT" then
            pcall(onLootChat, arg1)
        elseif event == "QUEST_DETAIL" or event == "QUEST_COMPLETE" then
            onQuestRewards()
        elseif event == "QUEST_LOG_UPDATE" then
            scheduleQuestLogScan()
        elseif event == "MERCHANT_SHOW" then
            onMerchantShow()
        elseif event == "TRADE_SKILL_SHOW" then
            onTradeSkillShow()
        elseif event == "TRADE_SKILL_UPDATE" then
            -- Fires on every craft and list change: read the window once things settle.
            if not tradeTimer then
                tradeTimer = C_Timer.NewTimer(1, function() tradeTimer = nil; onTradeSkillShow() end)
            end
        -- Name cache for loot sources: optional enrichment, so it may never raise errors
        -- (these events fire constantly; a client-side restriction must not spam the error frame).
        elseif event == "PLAYER_TARGET_CHANGED" then
            pcall(rememberUnit, "target")
            pcall(onTargetChanged)
        elseif event == "UPDATE_MOUSEOVER_UNIT" then
            pcall(rememberUnit, "mouseover")
        elseif event == "NAME_PLATE_UNIT_ADDED" then
            if arg1 then pcall(rememberUnit, arg1) end
        elseif event == "GET_ITEM_INFO_RECEIVED" then
            local p = arg1 and pending[arg1]
            if p then
                pending[arg1] = nil
                ns:LearnLink(p.link, p.src)
            end
        end
    end)
    scheduleQuestLogScan()
end

---------------------------------------------------------------------------
-- Encounter Journal import (only if this client has the EJ API)
---------------------------------------------------------------------------
function ns:HasEncounterJournal()
    return type(EJ_GetNumTiers) == "function" and type(EJ_GetNumLoot) == "function"
        and C_EncounterJournal ~= nil and type(C_EncounterJournal.GetLootInfoByIndex) == "function"
end

function ns:ImportEncounterJournal()
    if not self:HasEncounterJournal() then
        ns.Print("This client has no Encounter Journal API. Use the updater script and in-game learning instead.")
        return
    end
    local _, _, classID = UnitClass("player")
    local count = 0
    -- Remember the player's own Adventure Guide loot filter so the import doesn't change it.
    local oldClass, oldSpec
    if type(EJ_GetLootFilter) == "function" then oldClass, oldSpec = EJ_GetLootFilter() end
    local ok, err = pcall(function()
        for tier = 1, EJ_GetNumTiers() do
            EJ_SelectTier(tier)
            for _, isRaid in ipairs({ false, true }) do
                local i = 1
                while true do
                    local instanceID, instanceName = EJ_GetInstanceByIndex(i, isRaid)
                    if not instanceID then break end
                    EJ_SelectInstance(instanceID)
                    EJ_SetLootFilter(classID, 0)
                    local e = 1
                    while true do
                        local encName, _, encounterID = EJ_GetEncounterInfoByIndex(e, instanceID)
                        if not encName then break end
                        EJ_SelectEncounter(encounterID)
                        for l = 1, EJ_GetNumLoot() do
                            local info = C_EncounterJournal.GetLootInfoByIndex(l)
                            if info and info.itemID then
                                ns:LearnLink(info.link or ("item:" .. info.itemID),
                                    { t = "drop", n = encName, z = instanceName })
                                count = count + 1
                            end
                        end
                        e = e + 1
                    end
                    i = i + 1
                end
            end
        end
    end)
    if oldClass then pcall(EJ_SetLootFilter, oldClass, oldSpec or 0) end
    if ok then
        ns.Print(string.format("Encounter Journal: scanned %d loot entries. Uncached items finish importing over the next few seconds.", count))
    else
        ns.Print("Encounter Journal import failed: " .. tostring(err))
    end
end
