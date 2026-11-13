local _, ns = ...

-- Learns gear and where it comes from by watching what the player actually sees:
-- loot windows, quest rewards (talking to NPCs and the whole quest log), vendor lists and
-- profession windows. Everything stays in GearGuideLearned; build_db.py can bake it into Data.lua.

local MAX_SOURCES_PER_ITEM = 10
local pending = {}  -- itemID -> { link, src } waiting for the client to cache item info

local function addSource(id, src)
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

function ns:LearnLink(link, src)
    local id = ns.LinkToId(link)
    if not id then return end
    local item = self:GetItem(id)
    if not item then
        item = self:BuildFullRecord(link)
        if not item then
            pending[id] = { link = link, src = src }  -- retried on GET_ITEM_INFO_RECEIVED
            return
        end
        if not ns.EQUIPLOC_GROUP[item.eq] then return end  -- not gear
        GearGuideLearned.items[id] = item
        self:InvalidateItems()
    end
    if src and addSource(id, src) and ns.QueueShare then
        ns:QueueShare(id, src)  -- share first-time sightings (unless the player opted out)
    end
end

local function zone()
    return GetRealZoneText() or ""
end

---------------------------------------------------------------------------
-- Loot: who dropped it. Loot slots carry the source's GUID (GetLootSourceInfo); names come from
-- a small GUID -> name cache filled from units the player targets or mouses over.
---------------------------------------------------------------------------
local nameByGUID, nameCount = {}, 0
local Plain = ns.Plain  -- secret values (GUIDs/names the client protects) become nil

local function rememberUnit(unit)
    local guid = Plain(UnitGUID and UnitGUID(unit))
    if not guid or nameByGUID[guid] then return end
    if Plain(UnitIsPlayer(unit)) ~= false then return end  -- players (or unknown) aren't loot sources
    local name = Plain(UnitName(unit))
    if not name then return end
    if nameCount > 300 then wipe(nameByGUID); nameCount = 0 end  -- keep it small
    nameByGUID[guid] = name
    nameCount = nameCount + 1
end

local function lootSourceName(slot)
    if type(GetLootSourceInfo) == "function" then
        local guid = Plain(GetLootSourceInfo(slot))
        if guid then
            if nameByGUID[guid] then return nameByGUID[guid] end
            local kind = guid:match("^(%a+)")
            if kind == "GameObject" then return "Container" end
        end
    end
    if Plain(UnitExists("target")) and Plain(UnitIsDead("target")) then
        return Plain(UnitName("target")) or "Unknown"
    end
    return "Unknown"
end

local function onLootOpened()
    local z = zone()
    for i = 1, GetNumLootItems() do
        local link = GetLootSlotLink(i)
        if link then ns:LearnLink(link, { t = "drop", n = lootSourceName(i), z = z }) end
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
    local header = ""
    for i = 1, (GetNumQuestLogEntries() or 0) do
        local title, _, _, isHeader = GetQuestLogTitle(i)
        if isHeader then
            header = title or ""
        elseif title and not questLogScanned[title] then
            questLogScanned[title] = true
            SelectQuestLogEntry(i)
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
    SelectQuestLogEntry(previous)  -- put the player's quest log selection back
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
    local count = tonumber(r[#r]) or 0  -- some clients return honor, arena points, count
    local out = {}
    for j = 1, count do
        local icon, amount, link, currencyName = GetMerchantItemCostItem(i, j)
        local name = currencyName or (link and link:match("%[(.-)%]"))
        if name and (amount or 0) > 0 then out[#out + 1] = { n = name, q = amount, i = icon } end
    end
    return out[1] and out or nil
end

-- Remembers what this vendor charges for the item (latest visit wins).
local function learnPrice(id, vendor, i)
    local okP, price, extended = pcall(merchantPrice, i)
    local okC, costs = true, nil
    if extended ~= false then okC, costs = pcall(merchantCosts, i) end
    if not okP then price = nil end
    if not okC then costs = nil end
    if not ((price or 0) > 0 or costs) then return end
    GearGuideLearned.prices[id] = GearGuideLearned.prices[id] or {}
    GearGuideLearned.prices[id][vendor] = { g = (price or 0) > 0 and price or nil, c = costs }
end

local function onMerchantShow()
    local vendor = Plain(UnitName("npc")) or "?"
    local z = zone()
    for i = 1, (GetMerchantNumItems() or 0) do
        local link = GetMerchantItemLink(i)
        if link then
            ns:LearnLink(link, { t = "vendor", n = vendor, z = z })  -- own table per item
            -- Gear only; the instant lookup knows the slot even before the item is cached.
            local id, _, _, equipLoc = getInstant(link)
            if id and ns.EQUIPLOC_GROUP[equipLoc] then learnPrice(id, vendor, i) end
        end
    end
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

function ns:EnableLearning()
    local f = CreateFrame("Frame")
    for _, e in ipairs({ "LOOT_OPENED", "QUEST_DETAIL", "QUEST_COMPLETE", "MERCHANT_SHOW",
        "GET_ITEM_INFO_RECEIVED", "QUEST_LOG_UPDATE", "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE",
        "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED" }) do
        safeRegister(f, e)
    end
    f:SetScript("OnEvent", function(_, event, arg1)
        if event == "LOOT_OPENED" then
            onLootOpened()
        elseif event == "QUEST_DETAIL" or event == "QUEST_COMPLETE" then
            onQuestRewards()
        elseif event == "QUEST_LOG_UPDATE" then
            scheduleQuestLogScan()
        elseif event == "MERCHANT_SHOW" then
            onMerchantShow()
        elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" then
            onTradeSkillShow()
        -- Name cache for loot sources: optional enrichment, so it may never raise errors
        -- (these events fire constantly; a client-side restriction must not spam the error frame).
        elseif event == "PLAYER_TARGET_CHANGED" then
            pcall(rememberUnit, "target")
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
