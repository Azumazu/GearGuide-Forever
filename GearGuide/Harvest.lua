local _, ns = ...

-- Builds GearGuide's item database from the game client itself (no web API):
--   1. discover: GetItemInfoInstant over every item ID reads the client's local item table
--      (no server traffic) and keeps gear only;
--   2. fetch: for each gear item, GetItemInfo/GetItemStats plus a hidden-tooltip read for
--      "Unique", class restrictions and Equip: effects. Throttled to stay light on the server
--      (Blizzard UI Add-On Policy rule 3), paused in combat, resumable across sessions.
-- Results live in the GearGuideHarvest saved variable; GearGuideTools/build_db.py can bake
-- them into Data.lua so the addon ships with a ready database.

local DISCOVER_PER_FRAME = 400      -- local lookups per frame in the discover phase
local FETCH_INTERVAL = 0.1          -- seconds between fetch ticks (~10 server requests/s max)
local CACHED_PER_TICK = 25          -- already-cached items handled per tick (no server cost)
local PENDING_TIMEOUT = 15          -- seconds to wait for a server answer before retrying
local MAX_RETRIES = 2
local DEFAULT_MAX_ID = 400000      -- Forever's own items sit around 270000-281000
local EXTEND_MARGIN = 20000         -- gear found this close to the end -> keep scanning further
local EXTEND_BY = 50000

local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local requestLoad = C_Item and C_Item.RequestLoadItemDataByID

local driver = CreateFrame("Frame")
local ticker
local pending = {}       -- itemID -> { since = time, tries = n }
local pendingCount = 0
local inCombat = false

---------------------------------------------------------------------------
-- Tooltip reading (unique / class restriction / equip effects)
---------------------------------------------------------------------------
local tip = CreateFrame("GameTooltip", "GearGuideScanTooltip", nil, "GameTooltipTemplate")

local EQUIP_PATTERNS = {  -- matched against the lowercased tooltip line, first match wins
    { "ranged attack power by (%d+)", "RAP" },
    { "attack power by (%d+)", "AP" },
    { "healing done by spells and effects by up to (%d+)", "HEAL" },
    { "damage and healing done by magical spells and effects by up to (%d+)", "SP" },
    { "critical strike with spells by (%d+)%%", "SCRIT" },
    { "chance to hit with spells by (%d+)%%", "SHIT" },
    { "critical strike by (%d+)%%", "CRIT" },
    { "chance to hit by (%d+)%%", "HIT" },
    { "defense %+(%d+)", "DEF" },
    { "dodge an attack by (%d+)%%", "DODGE" },
    { "parry an attack by (%d+)%%", "PARRY" },
    { "block attacks with a shield by (%d+)%%", "BLOCK" },
    { "(%d+) mana per 5 sec", "MP5" },
    { "haste by (%d+)%%", "HASTE" },                           -- Forever's new Haste stat
    { "attack and casting speed by (%d+)%%", "HASTE" },
    { "casting speed by (%d+)%%", "HASTE" },
    { "attack speed by (%d+)%%", "HASTE" },
    { "expertise by (%d+)%%", "EXPERTISE" },                   -- Forever: reduces dodge/parry
    { "chance to be dodged or parried by (%d+)%%", "EXPERTISE" },
}

local classPattern
local classByName
local function initLocaleTables()
    if classByName then return end
    classByName = {}
    for _, names in ipairs({ LOCALIZED_CLASS_NAMES_MALE or {}, LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
        for token, name in pairs(names) do classByName[name] = token end
    end
    if ITEM_CLASSES_ALLOWED then
        classPattern = "^" .. ITEM_CLASSES_ALLOWED:gsub("([%%%(%)%.%-%+%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
    end
end

-- Adds u (unique), cls (class restriction) and equip-effect stats to `rec` from the item's tooltip.
function ns:ReadTooltipInto(link, rec)
    initLocaleTables()
    tip:SetOwner(WorldFrame, "ANCHOR_NONE")
    tip:ClearLines()
    local ok = pcall(tip.SetHyperlink, tip, link)
    if not ok then return rec end
    rec.st = rec.st or {}
    for i = 2, tip:NumLines() do
        local fs = _G["GearGuideScanTooltipTextLeft" .. i]
        local text = fs and fs:GetText()
        if text then
            if text == ITEM_UNIQUE or text == ITEM_UNIQUE_EQUIPPABLE then
                rec.u = 1
            elseif ITEM_RANDOM_ENCHANT and text == ITEM_RANDOM_ENCHANT then
                rec.r = 1  -- "<Random enchantment>": a world-drop green/blue with random "of the ..." stats
            elseif classPattern and text:match(classPattern) then
                local list = {}
                for name in text:match(classPattern):gmatch("[^,]+") do
                    local token = classByName[strtrim and strtrim(name) or name:match("^%s*(.-)%s*$")]
                    if token then list[#list + 1] = token end
                end
                if #list > 0 then rec.cls = list end
            else
                local lower = text:lower()
                for _, p in ipairs(EQUIP_PATTERNS) do
                    local value = lower:match(p[1])
                    if value then
                        if not rec.st[p[2]] then rec.st[p[2]] = tonumber(value) end  -- don't double-count GetItemStats
                        break
                    end
                end
            end
        end
    end
    tip:Hide()
    return rec
end

-- Full record: client item info + stats + tooltip extras. nil if the client hasn't got the item yet.
function ns:BuildFullRecord(linkOrId)
    local name, link, q, il, rl, _, _, _, eq, _, _, c, sc = ns.GetItemInfo(linkOrId)
    if not name then return nil end
    local rec = { n = name, q = q, il = il, rl = rl, eq = eq, c = c, sc = sc, st = ns.ReadStats(link) }
    return self:ReadTooltipInto(link, rec)
end

---------------------------------------------------------------------------
-- Scan state (persisted in GearGuideHarvest.scan)
---------------------------------------------------------------------------
local function S() return GearGuideHarvest.scan end

local function isGearLoc(eq) return eq and ns.EQUIPLOC_GROUP[eq] ~= nil end

local function finish()
    local s = S()
    s.phase, s.running = "done", false
    s.finishedAt = time()
    if ticker then ticker:Cancel(); ticker = nil end
    driver:SetScript("OnUpdate", nil)
    local n = 0
    for _ in pairs(GearGuideHarvest.items) do n = n + 1 end
    ns.Print(string.format("Database scan complete: %d gear items. They are in use now; "
        .. "run GearGuideTools/build_db.py to bake them into Data.lua.", n))
    ns:InvalidateItems()
end

local function reportProgress()
    local s = S()
    if s.phase == "discover" then
        local pct = math.floor(100 * (s.nextId - 1) / s.maxId)
        if pct >= (s.lastPct or -10) + 10 then
            s.lastPct = pct
            ns.Print(string.format("Scanning item table: %d%% (%d gear items found)", pct, #s.queue))
        end
    elseif s.phase == "fetch" then
        local pct = #s.queue > 0 and math.floor(100 * (s.qpos - 1) / #s.queue) or 100
        if pct >= (s.lastPct or -10) + 10 then
            s.lastPct = pct
            ns.Print(string.format("Reading gear details: %d%% (%d / %d)", pct, s.qpos - 1, #s.queue))
        end
    end
end

local function store(id)
    local rec = ns:BuildFullRecord(id)
    if rec and isGearLoc(rec.eq) then
        GearGuideHarvest.items[id] = rec
        return true
    end
    return rec ~= nil
end

---------------------------------------------------------------------------
-- Phase 2: fetch (timer driven, throttled)
---------------------------------------------------------------------------
local function fetchTick()
    local s = S()
    if not s.running or inCombat then return end
    local now = GetTime()

    -- Retry or drop items the server hasn't answered.
    for id, p in pairs(pending) do
        if now - p.since > PENDING_TIMEOUT then
            if p.tries >= MAX_RETRIES then
                pending[id] = nil; pendingCount = pendingCount - 1
            else
                p.tries, p.since = p.tries + 1, now
                if requestLoad then requestLoad(id) else ns.GetItemInfo(id) end
            end
        end
    end

    local handled, requested = 0, false
    while s.qpos <= #s.queue and handled < CACHED_PER_TICK and not requested do
        local id = s.queue[s.qpos]
        s.qpos = s.qpos + 1
        handled = handled + 1
        if not store(id) then
            -- Not cached: GetItemInfo inside store() already asked the server. One request per tick.
            if requestLoad then requestLoad(id) end
            pending[id] = { since = now, tries = 0 }
            pendingCount = pendingCount + 1
            requested = true
        end
    end
    reportProgress()
    if s.qpos > #s.queue and pendingCount <= 0 then finish() end
end

---------------------------------------------------------------------------
-- Phase 1: discover (frame driven, local only)
---------------------------------------------------------------------------
local function startFetch()
    local s = S()
    s.phase, s.qpos, s.lastPct = "fetch", s.qpos or 1, nil
    driver:SetScript("OnUpdate", nil)
    ns.Print(string.format("Found %d gear items. Reading details (about %d min; pauses in combat).",
        #s.queue, math.ceil(#s.queue * FETCH_INTERVAL / 60)))
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(FETCH_INTERVAL, fetchTick)
end

local function discoverStep()
    local s = S()
    if not s.running or inCombat then return end
    local last = math.min(s.nextId + DISCOVER_PER_FRAME - 1, s.maxId)
    for id = s.nextId, last do
        local ok, _, _, _, eq = pcall(getInstant, id)
        if ok and isGearLoc(eq) then
            s.queue[#s.queue + 1] = id
            s.lastFound = id
        end
    end
    s.nextId = last + 1
    reportProgress()
    if s.nextId > s.maxId then
        if (s.lastFound or 0) > s.maxId - EXTEND_MARGIN then
            s.maxId = s.maxId + EXTEND_BY  -- items still turning up near the end: look further
        else
            startFetch()
        end
    end
end

---------------------------------------------------------------------------
-- Public control
---------------------------------------------------------------------------
function ns:StartScan(maxId)
    if not getInstant then
        ns.Print("This client has no GetItemInfoInstant, so the item table can't be scanned locally.")
        return
    end
    local s = S()
    if s.running then ns.Print("Scan is already running. /gg scan status"); return end
    if s.phase == "done" or not s.phase or maxId then
        GearGuideHarvest.scan = { phase = "discover", nextId = 1, maxId = maxId or DEFAULT_MAX_ID,
            queue = {}, qpos = 1, startedAt = time() }
        s = S()
        local build = select(2, GetBuildInfo())
        GearGuideHarvest.build = build
        ns.Print("Building the item database from the game client. You can keep playing and use "
            .. "the window meanwhile; it pauses in combat and resumes after a reload. /gg scan pause to stop.")
    else
        ns.Print("Resuming database scan.")
    end
    s.running = true
    if s.phase == "discover" then
        driver:SetScript("OnUpdate", discoverStep)
    else
        startFetch()
    end
end

-- Scans only IDs above the previous scan's range, keeping every item already stored.
function ns:ExtendScan(newMax)
    local s = S()
    if s.running then ns.Print("Scan is already running. /gg scan status"); return end
    local from = (s.maxId or 0) + 1
    newMax = newMax or DEFAULT_MAX_ID
    if from > newMax then ns.Print("The scan already covers item IDs up to " .. (s.maxId or 0) .. "."); return end
    GearGuideHarvest.scan = { phase = "discover", nextId = from, maxId = newMax, queue = {}, qpos = 1,
        startedAt = time(), extended = true }
    ns.Print(string.format("Extending the database scan to item IDs %d-%d (keeps the %d items already scanned).",
        from, newMax, (function() local n = 0 for _ in pairs(GearGuideHarvest.items) do n = n + 1 end return n end)()))
    GearGuideHarvest.scan.running = true
    driver:SetScript("OnUpdate", discoverStep)
end

function ns:PauseScan()
    local s = S()
    s.running = false
    if ticker then ticker:Cancel(); ticker = nil end
    driver:SetScript("OnUpdate", nil)
    ns.Print("Database scan paused. /gg scan to resume.")
end

function ns:ScanStatus()
    local s = S()
    local n = 0
    for _ in pairs(GearGuideHarvest.items) do n = n + 1 end
    if not s.phase then
        return string.format("No scan yet. %d items stored. Start with /gg scan.", n)
    elseif s.phase == "done" then
        return string.format("Scan complete (%s): %d gear items.", date("%Y-%m-%d", s.finishedAt or time()), n)
    elseif s.phase == "discover" then
        return string.format("%s: scanning item table %d / %d, %d gear found.",
            s.running and "Running" or "Paused", s.nextId - 1, s.maxId, #s.queue)
    end
    return string.format("%s: reading details %d / %d (%d stored).",
        s.running and "Running" or "Paused", s.qpos - 1, #s.queue, n)
end

function ns:ResetScan()
    self:PauseScan()
    GearGuideHarvest.items, GearGuideHarvest.scan = {}, {}
    ns:InvalidateItems()
    ns.Print("Scanned item database cleared.")
end

function ns:HasScanData()
    return next(GearGuideHarvest.items) ~= nil
end

-- Starts the first scan on its own when the addon has no item database at all.
function ns:AutoScanIfEmpty()
    local s = S()
    if s.running or s.phase == "done" or self:HasScanData() or next(GearGuide_Data.items) ~= nil then return end
    self:StartScan()
end

-- Called by Core at PLAYER_LOGIN: resume an interrupted scan, or start the first one.
function ns:InitHarvest()
    local s = S()
    if s.running then
        s.running = false
        C_Timer.After(5, function() ns:StartScan() end)
    elseif s.phase == "done" and (s.maxId or 0) < DEFAULT_MAX_ID and self:HasScanData() then
        -- An earlier scan stopped below the current range (Forever's own items sit above 260000).
        C_Timer.After(8, function() ns:ExtendScan() end)
    else
        C_Timer.After(8, function() ns:AutoScanIfEmpty() end)
    end
end

driver:RegisterEvent("PLAYER_REGEN_DISABLED")
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:RegisterEvent("GET_ITEM_INFO_RECEIVED")
driver:SetScript("OnEvent", function(_, event, id, success)
    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
    elseif event == "GET_ITEM_INFO_RECEIVED" and id and pending[id] then
        pending[id] = nil
        pendingCount = pendingCount - 1
        if success ~= false then store(id) end
    end
end)
