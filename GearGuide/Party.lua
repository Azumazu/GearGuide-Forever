local _, ns = ...

---------------------------------------------------------------------------
-- Party gear and loot rolls. GearGuide reads what nearby party members wear through the game's
-- normal Inspect (one member at a time, out of combat, in inspect range), so it works whether
-- they use GearGuide or not. When a group loot roll starts, it shows on the roll frame what the
-- item is worth to you, and prints (to you only) who in the party it's an upgrade for.
-- Inspect window: an "Inspect in GearGuide" button loads that player's gear as a build.
---------------------------------------------------------------------------
local Party = {}
ns.Party = Party

local INSPECT_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }
local REFRESH_AFTER = 300  -- seconds before a member's gear is read again
local INSPECT_TIMEOUT = 4
local TICK = 3

local members = {}         -- guid -> { name, class, level, spec, links = { [slot] = link }, at }
local pending              -- { guid, unit, at, callback }

local function now() return (GetTime and GetTime()) or 0 end
local function isPlayer(u) return not UnitIsPlayer or UnitIsPlayer(u) end
local function connected(u) return not UnitIsConnected or UnitIsConnected(u) end

-- Spec of an inspected player: the talent tree with the most points (classic-era clients take an
-- isInspect flag), else nil.
local function inspectedSpec(class)
    if type(GetTalentTabInfo) ~= "function" or type(GetNumTalentTabs) ~= "function" then return nil end
    local ok, numTabs = pcall(GetNumTalentTabs, true)
    if not ok or not numTabs or numTabs == 0 then return nil end
    local bestTab, best = nil, 0
    for tab = 1, numTabs do
        local okInfo, a, _, c, _, e = pcall(GetTalentTabInfo, tab, true)
        local points = okInfo and ((type(a) == "number") and tonumber(e) or tonumber(c)) or 0
        if (points or 0) > best then bestTab, best = tab, points end
    end
    if not bestTab then return nil end
    for _, s in ipairs(ns:GetSpecs(class)) do
        if s.tab == bestTab then return s.key end
    end
end

local function readUnit(unit)
    local guid = UnitGUID(unit)
    if not guid then return end
    local _, class = UnitClass(unit)
    local m = members[guid] or {}
    members[guid] = m
    m.name, m.class, m.level = UnitName(unit), class, UnitLevel(unit)
    m.links = {}
    for _, slot in ipairs(INSPECT_SLOTS) do
        local link = GetInventoryItemLink(unit, slot)
        if link then m.links[slot] = link end
    end
    m.spec = inspectedSpec(class) or m.spec
    m.at = now()
    return m
end

local function inspectWindowOpen()
    return InspectFrame ~= nil and InspectFrame.IsShown ~= nil and InspectFrame:IsShown()
end

-- Starts an inspect of `unit` (a party member or the target). callback(unit) runs when it's ready.
function Party.Inspect(unit, callback)
    if pending and now() - pending.at < INSPECT_TIMEOUT then return false end
    if not (UnitExists(unit) and isPlayer(unit) and CanInspect and NotifyInspect and CanInspect(unit)) then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    pending = { guid = UnitGUID(unit), unit = unit, at = now(), callback = callback }
    NotifyInspect(unit)
    return true
end

local function partyUnits()
    local out = {}
    if IsInRaid and IsInRaid() then return out end  -- raids use master loot: party only
    for i = 1, 4 do
        local u = "party" .. i
        if UnitExists(u) and isPlayer(u) then out[#out + 1] = u end
    end
    return out
end

-- Every few seconds: inspect one party member whose gear is unknown or old, if they're in range.
local function tick()
    if not (UnitGUID and NotifyInspect and CanInspect) then return end  -- no Inspect in this client
    if pending and now() - pending.at < INSPECT_TIMEOUT then return end
    pending = nil
    if inspectWindowOpen() or (InCombatLockdown and InCombatLockdown()) then return end
    for _, u in ipairs(partyUnits()) do
        local m = members[UnitGUID(u) or ""]
        local stale = not m or not m.at or now() - m.at > REFRESH_AFTER
        local inRange = connected(u) and (not CheckInteractDistance or CheckInteractDistance(u, 1))
        if stale and inRange and Party.Inspect(u) then return end
    end
end

-- The inspect ticker runs only in a party (raids use master loot, solo has no one to inspect).
local ticker
local function updateTicker()
    local party = IsInGroup and IsInGroup() and not (IsInRaid and IsInRaid())
    if party and not ticker and C_Timer and C_Timer.NewTicker then
        ticker = C_Timer.NewTicker(TICK, tick)
    elseif not party and ticker then
        ticker:Cancel(); ticker = nil
    end
end

---------------------------------------------------------------------------
-- What an item is worth to someone: score gain over what they wear in that slot (the weaker one
-- of two rings/trinkets), nil if they can't use it.
---------------------------------------------------------------------------
local function context(class, specKey, level)
    local spec = ns:GetSpecInfo(class, specKey)
    local key = spec and spec.key
    local weights = ns:GetWeights(class, key, level)
    return weights, { class = class, spec = key, role = spec and spec.role or "MELEE", level = level }
end

local function wornItem(link)
    if not link then return nil end
    local id = ns.LinkToId(link)
    return (ns.LinkBonus(link) and ns:ItemFromLink(link)) or (id and ns:GetItem(id)) or ns:ItemFromLink(link)
end

-- gain (number) or nil; links: { [slot] = link } of what they wear.
function Party.Gain(item, class, specKey, level, links)
    if not item or not item.eq then return nil end
    if (item.rl or 0) > (level or 1) or not ns:IsUsable(item, class, level) then return nil end
    if not ns.WeaponTypeAllowed(item, class, specKey, level) then return nil end
    local groups = ns:GroupsForItem(item, ns:WeaponSetup(class, specKey, level))
    if not groups then return nil end
    local weights, ctx = context(class, specKey, level)
    local score = ns:Score(item, weights, ctx)
    if score <= 0 then return nil end
    local best
    for _, key in ipairs(groups) do
        local g = ns.SLOT_GROUP_BY_KEY[key]
        local base
        for _, slot in ipairs(g and g.inv or {}) do
            local worn = wornItem(links[slot])
            local s = worn and ns:Score(worn, weights, ctx) or 0
            if base == nil or s < base then base = s end
        end
        local gain = score - (base or 0)
        if best == nil or gain > best then best = gain end
    end
    return best
end

-- The item record for a link or id: a random variant's own stats, else the database entry, else
-- the client cache.
function Party.ItemFor(link)
    local id = ns.LinkToId(link)
    return (ns.LinkBonus(link) and ns:ItemFromLink(link)) or (id and ns:GetItem(id)) or ns:ItemFromLink(link)
end

local function myLinks()
    local links = {}
    for _, slot in ipairs(INSPECT_SLOTS) do links[slot] = GetInventoryItemLink("player", slot) end
    return links
end

-- What an item is worth to you over what you wear (nil: you can't use it, or it isn't gear).
function Party.MyGain(link, item)
    item = item or Party.ItemFor(link)
    if not item then return nil end
    return Party.Gain(item, ns:GetPlayerClass(), ns:GetPlayerSpec(), UnitLevel("player"), myLinks())
end

-- For a loot roll: { me = gain or nil, others = { {name, class, gain}, ... }, unchecked = n }
function Party.Assess(link)
    local item = Party.ItemFor(link)
    local out = { others = {}, unchecked = 0, item = item }
    if not item then return out end
    out.me = Party.MyGain(link, item)
    for _, u in ipairs(partyUnits()) do
        local m = members[UnitGUID(u) or ""]
        if m and m.links then
            local gain = Party.Gain(item, m.class, m.spec, UnitLevel(u) or m.level, m.links)
            if gain and gain > 0.05 then out.others[#out.others + 1] = { name = m.name, class = m.class, gain = gain } end
        else
            out.unchecked = out.unchecked + 1
        end
    end
    table.sort(out.others, function(a, b) return a.gain > b.gain end)
    return out
end

local function classLabel(class)
    local t = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]
    return t or (class and (class:sub(1, 1) .. class:sub(2):lower())) or "?"
end

local function gainText(gain)
    return string.format("%+.1f", gain)
end

-- Lines for the roll tooltip and the chat summary.
function Party.Summary(a)
    local parts = {}
    if a.me and a.me > 0.05 then parts[#parts + 1] = "you (" .. gainText(a.me) .. ")" end
    for _, o in ipairs(a.others) do
        parts[#parts + 1] = string.format("%s (%s, %s)", o.name or "?", classLabel(o.class), gainText(o.gain))
    end
    return parts
end

---------------------------------------------------------------------------
-- Group loot rolls: a line on the roll frame, the roll tooltip, and one chat line per roll.
---------------------------------------------------------------------------
local function rollFrame(rollID)
    for i = 1, (NUM_GROUP_LOOT_FRAMES or 4) do
        local f = _G["GroupLootFrame" .. i]
        if f and f.rollID == rollID then return f end
    end
end

-- Our label per roll frame, kept here: writing fields onto Blizzard's frames can taint them.
local rollLabels = setmetatable({}, { __mode = "k" })
Party.rollLabels = rollLabels  -- (tests)

local function labelRoll(rollID, a)
    local f = rollFrame(rollID)
    if not f then return end
    local label = rollLabels[f]
    if not label then
        label = ns.Skin:Text(f, ns.Skin.SIZE.small, "text")
        label:SetPoint("BOTTOM", f, "TOP", 0, 2)
        rollLabels[f] = label
    end
    local text
    if a.me and a.me > 0.05 then
        text = "|cff33ff99GearGuide:|r upgrade for you " .. ns.Skin:Hex("upgrade") .. gainText(a.me) .. "|r"
    elseif a.me then
        text = "|cff33ff99GearGuide:|r |cff999999not an upgrade for you|r"
    else
        text = "|cff33ff99GearGuide:|r |cff999999you can't use this|r"
    end
    if #a.others > 0 then text = text .. "  |cffffd100" .. #a.others .. " in your party|r" end
    label:SetText(text)
    label:Show()
end

function Party.OnLootRoll(rollID)
    if GearGuideDB and GearGuideDB.lootRollHelp == false then return end
    local link = GetLootRollItemLink and GetLootRollItemLink(rollID)
    if not link then return end
    local a = Party.Assess(link)
    if not a.item or not a.item.eq or not ns.EQUIPLOC_GROUP[a.item.eq] then return end  -- not gear
    labelRoll(rollID, a)
    local who = Party.Summary(a)
    if #who > 0 then
        local note = a.unchecked > 0 and string.format(" |cff999999(%d not checked yet)|r", a.unchecked) or ""
        ns.Print(link .. " is an upgrade for " .. table.concat(who, ", ") .. "." .. note)
    end
end

local function addRollTooltip(tip, rollID)
    if GearGuideDB and GearGuideDB.lootRollHelp == false then return end
    local link = GetLootRollItemLink and GetLootRollItemLink(rollID)
    if not link then return end
    local a = Party.Assess(link)
    if not a.item or not ns.EQUIPLOC_GROUP[a.item.eq or ""] then return end
    tip:AddLine(" ")
    local who = Party.Summary(a)
    if #who > 0 then
        tip:AddLine("GearGuide: upgrade for", 0.2, 1, 0.6)
        for _, line in ipairs(who) do tip:AddLine("  " .. line, 1, 1, 1) end
    else
        tip:AddLine("GearGuide: not an upgrade for anyone checked", 0.6, 0.6, 0.6)
    end
    if a.unchecked > 0 then
        tip:AddLine(string.format("%d party member%s not checked yet (out of inspect range)", a.unchecked,
            a.unchecked == 1 and "" or "s"), 0.6, 0.6, 0.6, true)
    end
    tip:Show()
end

---------------------------------------------------------------------------
-- Inspect window button
---------------------------------------------------------------------------
local inspectButton
local function addInspectButton()
    if inspectButton or not InspectFrame then return end
    local Skin = ns.Skin
    inspectButton = Skin:Button(InspectFrame, "Inspect in GearGuide", nil, 22)
    -- Forever's Inspect window has slots right down to its edges, so the button
    -- hangs just under the bottom-right corner (the tabs hang under the left).
    inspectButton:SetPoint("TOPRIGHT", InspectFrame, "BOTTOMRIGHT", -4, -2)
    inspectButton:SetFrameStrata("HIGH")
    -- The text can measure short while the Inspect UI is still loading: re-fit on show.
    inspectButton:FitText(140)
    inspectButton:HookScript("OnShow", function(self) self:FitText(140) end)
    inspectButton:SetScript("OnClick", function()
        local unit = InspectFrame.unit or "target"
        local ok, msg = ns:SimSaveUnitGear(unit)
        if ok then
            ns.Print("Build saved: " .. msg .. ". It's open in the Build Simulator.")
            ns:ShowWindow("simulator")
        else
            ns.Print(msg)
        end
    end)
    inspectButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Inspect in GearGuide", 1, 1, 1)
        GameTooltip:AddLine("Opens this player's gear in the Build Simulator, saved as a build, so you can try it on "
            .. "and see where to get it.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    inspectButton:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

-- /gg inspect: the target's gear into the Build Simulator.
function ns:InspectTarget()
    if not UnitExists("target") or not isPlayer("target") then
        ns.Print("Target a player first.")
        return
    end
    if UnitIsUnit and UnitIsUnit("target", "player") then
        ns:SimResetToEquipped()
        ns:ShowWindow("simulator")
        return
    end
    local started = Party.Inspect("target", function(unit)
        local ok, msg = ns:SimSaveUnitGear(unit)
        ns.Print(ok and ("Build saved: " .. msg .. ". It's open in the Build Simulator.") or msg)
        if ok then ns:ShowWindow("simulator") end
    end)
    if not started then ns.Print("Can't inspect them right now (too far away, or in combat).") end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local events = CreateFrame("Frame")
for _, e in ipairs({ "INSPECT_READY", "START_LOOT_ROLL", "GROUP_ROSTER_UPDATE", "ADDON_LOADED", "PLAYER_LOGIN" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1)
    if event == "INSPECT_READY" then
        if pending and arg1 == pending.guid then
            local p = pending
            pending = nil
            if UnitGUID(p.unit) == p.guid then
                readUnit(p.unit)
                if p.callback then p.callback(p.unit) end
            end
            -- Leave the game's own Inspect window its data; otherwise let the client forget it.
            if not inspectWindowOpen() and ClearInspectPlayer then ClearInspectPlayer() end
        elseif InspectFrame and InspectFrame.unit and UnitGUID(InspectFrame.unit) == arg1 then
            readUnit(InspectFrame.unit)  -- the player inspected someone: free gear data for us
            addInspectButton()
        end
    elseif event == "START_LOOT_ROLL" then
        local rollID = arg1
        -- The roll frame gets its rollID right after this event.
        if C_Timer and C_Timer.After then C_Timer.After(0, function() Party.OnLootRoll(rollID) end)
        else Party.OnLootRoll(rollID) end
    elseif event == "GROUP_ROSTER_UPDATE" then
        local keep = {}
        for _, u in ipairs(partyUnits()) do keep[UnitGUID(u) or ""] = true end
        for guid in pairs(members) do if not keep[guid] then members[guid] = nil end end
        updateTicker()
    elseif event == "ADDON_LOADED" and arg1 == "Blizzard_InspectUI" then
        addInspectButton()
    elseif event == "PLAYER_LOGIN" then
        addInspectButton()
        updateTicker()
        if GameTooltip and GameTooltip.SetLootRollItem and hooksecurefunc then
            hooksecurefunc(GameTooltip, "SetLootRollItem", addRollTooltip)
        end
    end
end)

Party.members = members  -- (tests)
