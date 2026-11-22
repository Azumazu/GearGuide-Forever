local _, ns = ...

---------------------------------------------------------------------------
-- Acquired-gear tracking.
-- Counts how many copies of each gear item this character currently owns
-- (equipped + bags, + bank while it is open) and keeps a per-character
-- high-water mark in GearGuideCharDB.acquired[itemID]. The mark never goes
-- down when items are sold or destroyed (only /gg unmark resets it).
---------------------------------------------------------------------------

-- Container API: modern clients use C_Container, older ones the globals.
local getNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local getContainerItemID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
local getContainerItemLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
local getItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant

local FIRST_EQUIP_SLOT, LAST_EQUIP_SLOT = 1, 19

local function containerItemID(bag, slot)
    if getContainerItemID then return getContainerItemID(bag, slot) end
    if getContainerItemLink then return ns.LinkToId(getContainerItemLink(bag, slot)) end
    return nil
end

local function equippedItemID(slot)
    if GetInventoryItemID then return GetInventoryItemID("player", slot) end
    if GetInventoryItemLink then return ns.LinkToId(GetInventoryItemLink("player", slot)) end
    return nil
end

---------------------------------------------------------------------------
-- Gear filter (cached; only definitive answers are cached so items whose
-- info is not loaded yet get re-checked on the next scan)
---------------------------------------------------------------------------
local gearCache = {}

local function isGear(id)
    local cached = gearCache[id]
    if cached ~= nil then return cached end
    if ns:GetItem(id) then
        gearCache[id] = true
        return true
    end
    local equipLoc
    if getItemInfoInstant then
        local _, _, _, loc = getItemInfoInstant(id)
        equipLoc = loc
    end
    if equipLoc == nil then
        local name, _, _, _, _, _, _, _, loc = ns.GetItemInfo(id)
        if not name then return false end -- not cached yet; decide on a later scan
        equipLoc = loc
    end
    local result = ns.EQUIPLOC_GROUP[equipLoc or ""] ~= nil
    gearCache[id] = result
    return result
end

---------------------------------------------------------------------------
-- Scanning
---------------------------------------------------------------------------
local bankOpen = false
local counts = {} -- reused between scans

local function clear(t)
    if wipe then wipe(t) else for k in pairs(t) do t[k] = nil end end
end

local function countContainer(bag)
    local n = getNumSlots and getNumSlots(bag) or 0
    for slot = 1, n do
        local id = containerItemID(bag, slot)
        if id then counts[id] = (counts[id] or 0) + 1 end
    end
end

-- Scans everything currently owned and raises high-water marks.
-- Returns true when at least one acquired count increased.
-- quiet: don't announce new gear (login, bank contents, resets: things the player already had).
local announce = false   -- off until shortly after login, so owned gear isn't "acquired" again
function ns:ScanAcquired(quiet)
    if not (GearGuideCharDB and GearGuideCharDB.acquired) then return false end
    local acquired = GearGuideCharDB.acquired
    clear(counts)

    for slot = FIRST_EQUIP_SLOT, LAST_EQUIP_SLOT do
        local id = equippedItemID(slot)
        if id then counts[id] = (counts[id] or 0) + 1 end
    end

    local numBags = NUM_BAG_SLOTS or 4
    for bag = 0, numBags do countContainer(bag) end

    if bankOpen then
        countContainer(BANK_CONTAINER or -1)
        local numBankBags = NUM_BANKBAGSLOTS or 6
        for bag = numBags + 1, numBags + numBankBags do countContainer(bag) end
        ns:RememberBankGear()
    end

    local changed, gained = false, {}
    for id, n in pairs(counts) do
        if n > (acquired[id] or 0) and isGear(id) then
            gained[#gained + 1] = id
            changed = true
        end
    end
    -- Announced before the marks change, so "currently recommended" means before this item came in.
    if #gained > 0 and announce and not quiet and ns.OnGearAcquired then pcall(ns.OnGearAcquired, ns, gained) end
    for _, id in ipairs(gained) do acquired[id] = counts[id] end
    if changed then self:RequestRefresh() end
    return changed
end

---------------------------------------------------------------------------
-- Upgrades on level up: gear in your bags or bank that you couldn't wear yet and now can, and
-- that beats what you wear. The bank is only readable while it's open, so the gear in it is
-- remembered then (GearGuideCharDB.bankGear = { link, ... }).
---------------------------------------------------------------------------
local function containerLinks(bag, out)
    local n = getNumSlots and getNumSlots(bag) or 0
    for slot = 1, n do
        local link = getContainerItemLink and getContainerItemLink(bag, slot)
        local id = link and ns.LinkToId(link)
        if id and isGear(id) then out[#out + 1] = link end
    end
end

function ns:RememberBankGear()
    if not (bankOpen and GearGuideCharDB) then return end
    local links = {}
    containerLinks(BANK_CONTAINER or -1, links)
    local numBags = NUM_BAG_SLOTS or 4
    for bag = numBags + 1, numBags + (NUM_BANKBAGSLOTS or 6) do containerLinks(bag, links) end
    GearGuideCharDB.bankGear = links
end

-- { { link, gain, bank = true/nil }, ... } best first: items needing a level above fromLevel and at
-- most toLevel that are upgrades now.
function ns:LevelUpUpgrades(fromLevel, toLevel)
    local candidates, seen, out = {}, {}, {}
    local bagLinks = {}
    for bag = 0, NUM_BAG_SLOTS or 4 do containerLinks(bag, bagLinks) end
    for _, link in ipairs(bagLinks) do candidates[#candidates + 1] = { link = link } end
    for _, link in ipairs(GearGuideCharDB and GearGuideCharDB.bankGear or {}) do
        candidates[#candidates + 1] = { link = link, bank = true }
    end
    for _, c in ipairs(candidates) do
        local item = not seen[c.link] and ns.Party and ns.Party.ItemFor(c.link)
        seen[c.link] = true
        local rl = item and (item.rl or 0) or 0
        if item and rl > fromLevel and rl <= toLevel then
            local gain = ns.Badges and ns.Badges.GainFor(c.link)
            if gain and gain > 0 then c.gain = gain; out[#out + 1] = c end
        end
    end
    table.sort(out, function(a, b) return a.gain > b.gain end)
    return out
end

local lastLevel
local function announceLevelUp(level)
    local from = lastLevel or (level - 1)
    lastLevel = level
    if not (GearGuideDB and GearGuideDB.levelUpGear ~= false) or level <= from then return end
    local list = ns:LevelUpUpgrades(from, level)
    if #list == 0 then return end
    ns.Print(string.format("Level %d: %d upgrade%s you can wear now:", level, #list, #list == 1 and "" or "s"))
    for i, u in ipairs(list) do
        if i > 8 then ns.Print(string.format("  ...and %d more", #list - 8)) break end
        print(string.format("  %s %s+%.1f|r%s", u.link, ns.Skin:Hex("upgrade"), u.gain, u.bank and " |cff999999(in your bank)|r" or ""))
    end
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage(string.format("GearGuide: %d upgrade%s you can wear now (see chat)",
            #list, #list == 1 and "" or "s"), 0.4, 1, 0.6)
    end
end
ns.AnnounceLevelUp = announceLevelUp  -- (tests)

local scanPending = false
local function scheduleScan(delay)
    if scanPending then return end
    scanPending = true
    C_Timer.After(delay, function()
        scanPending = false
        ns:ScanAcquired()
    end)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local frame = CreateFrame("Frame")
local hasBagUpdateDelayed = false

local function safeRegister(event)
    return (pcall(frame.RegisterEvent, frame, event))
end

frame:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_LEVEL_UP" then
        -- After the client's level and the upgrade numbers have caught up (Badges: 0.5 s).
        local level = tonumber(ns.Plain(arg1))
        if level and C_Timer and C_Timer.After then
            C_Timer.After(1, function() pcall(announceLevelUp, level) end)
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        if not hasBagUpdateDelayed then
            -- The client has the batched event; stop listening to per-bag spam.
            hasBagUpdateDelayed = true
            pcall(frame.UnregisterEvent, frame, "BAG_UPDATE")
        end
        scheduleScan(0)
    elseif event == "BAG_UPDATE" then
        if not hasBagUpdateDelayed then scheduleScan(0.2) end
    elseif event == "BANKFRAME_OPENED" then
        bankOpen = true
        ns:ScanAcquired(true)
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen = false
    elseif event == "PLAYERBANKSLOTS_CHANGED" or event == "PLAYERBANKBAGSLOTS_CHANGED" then
        if bankOpen then scheduleScan(0.2) end
    else -- PLAYER_EQUIPMENT_CHANGED
        scheduleScan(0.2)
    end
end)

function ns:StartTracking()
    if self.trackingStarted then return end
    self.trackingStarted = true
    lastLevel = ns.Plain(UnitLevel("player"))
    safeRegister("PLAYER_LEVEL_UP")
    safeRegister("BAG_UPDATE")
    safeRegister("BAG_UPDATE_DELAYED")
    safeRegister("PLAYER_EQUIPMENT_CHANGED")
    safeRegister("BANKFRAME_OPENED")
    safeRegister("BANKFRAME_CLOSED")
    safeRegister("PLAYERBANKSLOTS_CHANGED")
    safeRegister("PLAYERBANKBAGSLOTS_CHANGED")
    self:ScanAcquired(true)
    -- Item info may still be cold right after login; scan again shortly.
    C_Timer.After(2, function() ns:ScanAcquired(true); announce = true end)
end

---------------------------------------------------------------------------
-- Public queries
---------------------------------------------------------------------------
function ns:GetNeededCount(item, class)
    if not item or item.u then return 1 end
    local eq = item.eq
    if eq == "INVTYPE_FINGER" or eq == "INVTYPE_TRINKET" then return 2 end
    if eq == "INVTYPE_WEAPON" then
        class = class or self:GetPlayerClass()
        local dwLevel = ns.DUAL_WIELD[class]
        -- The item is worn at its required level at the earliest; for your own class, at your current level.
        local level = item.rl or 0
        if class == self:GetPlayerClass() then level = math.max(level, UnitLevel("player")) end
        if dwLevel and level >= dwLevel then return 2 end
    end
    return 1
end

function ns:GetAcquiredCount(id)
    local acquired = GearGuideCharDB and GearGuideCharDB.acquired
    return (acquired and id and acquired[id]) or 0
end

function ns:GetCompletion(id, class)
    local need = self:GetNeededCount(self:GetItem(id), class)
    local have = math.min(self:GetAcquiredCount(id), need)
    local state
    if have >= need then
        state = "done"
    elseif have > 0 then
        state = "partial"
    else
        state = "none"
    end
    return state, have, need
end

function ns:ResetAcquired()
    if GearGuideCharDB then
        if GearGuideCharDB.acquired then clear(GearGuideCharDB.acquired) else GearGuideCharDB.acquired = {} end
    end
    clear(gearCache)
    -- Items owned right now count again immediately (otherwise the next bag event would re-mark them).
    self:ScanAcquired(true)
    self:RequestRefresh()
end
