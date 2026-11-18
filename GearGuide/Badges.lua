local _, ns = ...

---------------------------------------------------------------------------
-- Upgrade badges on item icons: the score gain over what you wear, along the bottom edge of
-- every item button the game (or a bag addon) draws with an item link: bags, bank, merchant,
-- loot, quest rewards, mail... It hooks the game's own SetItemButtonQuality, which the default UI,
-- Bagnon and EllesmereUIBags all call when they show an item, so no bag addon needs special code.
---------------------------------------------------------------------------
local Badges = {}
ns.Badges = Badges

local MIN_GAIN = 0.05

local badges = setmetatable({}, { __mode = "k" })  -- button -> badge frame (never fields on Blizzard frames)
local shown = setmetatable({}, { __mode = "k" })   -- button -> link it shows a badge for
local cache = {}                                    -- link -> gain or false
Badges.badges, Badges.cache = badges, cache          -- (tests)

local function enabled()
    return not GearGuideDB or GearGuideDB.iconBadges ~= false
end

local function inCombat() return InCombatLockdown and InCombatLockdown() end

-- The equipment slots on the Character and Inspect windows show worn gear, not candidates.
local function isGearSlot(button)
    local name = button.GetName and button:GetName()
    return type(name) == "string" and (name:find("^Character") or name:find("^Inspect")) ~= nil
end

local function formatGain(gain)
    local sign = gain < 0 and "-" or "+"
    local a = math.abs(gain)
    if a >= 9.95 then return sign .. math.floor(a + 0.5) end
    return sign .. string.format("%.1f", a)
end

-- Score difference to what you wear: positive for an upgrade, negative for a downgrade, nil when
-- you can't use it or it's about the same (cached per link until gear changes).
function Badges.GainFor(link)
    if link == nil then return nil end
    local key = tostring(link)
    local v = cache[key]
    if v == nil then
        v = false
        local id = ns.LinkToId(link)
        local item = id and ns.Party.ItemFor(link)
        if item and item.eq and ns.EQUIPLOC_GROUP[item.eq] and not ns:IsIgnored(id)
            and not (IsEquippedItem and IsEquippedItem(id)) then
            local gain = ns.Party.MyGain(link, item)
            if gain and math.abs(gain) > MIN_GAIN then v = gain end
        end
        cache[key] = v
    end
    return v or nil
end

local function makeBadge(button)
    local f = CreateFrame("Frame", nil, button)
    f:SetFrameLevel((button:GetFrameLevel() or 0) + 5)  -- above bag addons' borders and overlays
    -- Just the number, along the bottom edge (gear doesn't stack, so no count sits there).
    local text = ns.Skin:Text(f, 11, "upgrade", "OUTLINE")
    text:SetPoint("BOTTOMLEFT", 1, 2)
    text:SetPoint("BOTTOMRIGHT", -1, 2)
    text:SetJustifyH("CENTER")
    f.text = text
    badges[button] = f
    return f
end

-- The button's own icon when the button is clearly wider than it: a quest reward button spans the
-- icon and the item's name, and the number belongs on the icon. nil for bag-style buttons.
local function wideButtonIcon(button)
    local name = button.GetName and button:GetName()
    local candidates = { rawget(button, "icon"), rawget(button, "Icon"), rawget(button, "IconTexture"),
                         type(name) == "string" and _G[name .. "IconTexture"] or nil }
    local icon
    for i = 1, 4 do  -- (not ipairs: it stops at the first missing one)
        if type(candidates[i]) == "table" then icon = candidates[i] break end
    end
    if type(icon) ~= "table" or not icon.GetWidth or not button.GetWidth then return nil end
    local bw, iw = tonumber(button:GetWidth()) or 0, tonumber(icon:GetWidth()) or 0
    if iw > 0 and bw > iw * 1.5 then return icon end
end

-- anchor: the icon to draw on when the button is wider than its icon (quest rewards); it sticks
-- for later redraws. Without one, a wide button's own icon is found here.
function Badges.Update(button, link, anchor)
    if type(button) ~= "table" then return end
    local gain = enabled() and link and not isGearSlot(button) and Badges.GainFor(link)
    local f = badges[button]
    if not gain then
        if f then f:Hide() end
        shown[button] = nil
        return
    end
    if not f then
        if inCombat() then return end  -- new frames on bag buttons wait until combat ends
        f = makeBadge(button)
    end
    anchor = anchor or wideButtonIcon(button) or rawget(f, "anchor") or button
    if rawget(f, "anchor") ~= anchor then
        f:ClearAllPoints()
        f:SetAllPoints(anchor)
        f.anchor = anchor
    end
    f.text:SetText(formatGain(gain))
    local c = ns.Skin:Color(gain > 0 and "upgrade" or "downgrade")
    f.text:SetTextColor(c[1], c[2], c[3], 1)
    f:Show()
    shown[button] = link
end

-- An emptied slot: some bag addons clear the icon without setting a quality.
local function onTexture(button, texture)
    if texture == nil and type(button) == "table" and badges[button] then
        badges[button]:Hide()
        shown[button] = nil
    end
end

-- Gear, level, spec or weights changed: forget the gains and redraw the badges on screen.
function Badges.Invalidate()
    for k in pairs(cache) do cache[k] = nil end
    for button, link in pairs(shown) do Badges.Update(button, link) end
end
function ns:InvalidateBadges() Badges.Invalidate() end

-- Settings toggle: hide everything at once (bags redraw their own badges when shown again).
function Badges.SetEnabled(on)
    GearGuideDB.iconBadges = on and true or false
    if on then Badges.Invalidate() return end
    for button, f in pairs(badges) do f:Hide(); shown[button] = nil end
end

---------------------------------------------------------------------------
-- Quest rewards, in whatever window shows them (the game's own, or any quest UI addon). The
-- reward list comes from the game's quest API; then every visible frame that shows a reward's
-- icon together with its name gets the number on that icon. Icon + name keeps bag slots and
-- action buttons (same icon, no name) out. Nothing here knows about any particular addon.
---------------------------------------------------------------------------
local questBadged = setmetatable({}, { __mode = "k" })  -- buttons badged by the last scan
local npcQuestOpen = false   -- between QUEST_DETAIL/QUEST_COMPLETE and QUEST_FINISHED
local rewardsPending = false -- a reward's item info wasn't cached yet: scan again when it arrives
Badges.questBadged = questBadged  -- (tests)

local function call(f, ...)
    if type(f) == "function" then return f(...) end
end

local function plainText(s)
    if type(s) ~= "string" then return nil end
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return s:match("^%s*(.-)%s*$")
end

local function addReward(list, link, name, texture)
    if not link then rewardsPending = true return end
    local itemName = ns.GetItemInfo(link)
    if not itemName then rewardsPending = true end
    if not Badges.GainFor(link) then return end
    local id = ns.LinkToId(link)
    list[#list + 1] = {
        link = link,
        names = { plainText(itemName), plainText(name) },
        icons = { texture, id and ns.ItemIcon(id) },
    }
end

-- The rewards on screen: the quest an NPC is offering or rewarding, and the quest selected in the log.
function Badges.QuestRewards()
    local list = {}
    rewardsPending = false
    if npcQuestOpen then
        for _, kind in ipairs({ "choice", "reward" }) do
            local n = call(kind == "choice" and GetNumQuestChoices or GetNumQuestRewards) or 0
            for i = 1, n do
                local name, texture = call(GetQuestItemInfo, kind, i)
                addReward(list, call(GetQuestItemLink, kind, i), name, texture)
            end
        end
    end
    local sel = call(GetQuestLogSelection)
    if sel and sel > 0 then
        for _, kind in ipairs({ "choice", "reward" }) do
            local n = call(kind == "choice" and GetNumQuestLogChoices or GetNumQuestLogRewards) or 0
            for i = 1, n do
                local name, texture = call(kind == "choice" and GetQuestLogChoiceInfo or GetQuestLogRewardInfo, i)
                addReward(list, call(GetQuestLogItemLink, kind, i), name, texture)
            end
        end
    end
    return list
end

local function regionsMatchName(names, ...)
    for i = 1, select("#", ...) do
        local r = select(i, ...)
        if r and r.GetObjectType and r:GetObjectType() == "FontString" and r:IsShown() then
            local t = plainText(r:GetText())
            if t and t ~= "" then
                for _, n in pairs(names) do if t == n then return true end end
            end
        end
    end
    return false
end

-- The item's name shown on the button, on one of its child frames, or right beside it.
local function showsName(frame, names)
    if regionsMatchName(names, frame:GetRegions()) then return true end
    for _, child in ipairs({ frame:GetChildren() }) do
        if type(child) == "table" and child.GetRegions and regionsMatchName(names, child:GetRegions()) then
            return true
        end
    end
    local parent = frame.GetParent and frame:GetParent()
    return type(parent) == "table" and parent.GetRegions ~= nil and regionsMatchName(names, parent:GetRegions())
end

local function iconRegion(frame, icons)
    for _, r in ipairs({ frame:GetRegions() }) do
        if r.GetObjectType and r:GetObjectType() == "Texture" and r:IsShown() then
            local tex = r:GetTexture()
            if tex ~= nil then
                for _, ic in pairs(icons) do
                    if tostring(tex) == tostring(ic) then return r end
                end
            end
        end
    end
end

function Badges.ScanQuestRewards()
    for button in pairs(questBadged) do
        questBadged[button] = nil
        Badges.Update(button, nil)
    end
    if not enabled() or type(EnumerateFrames) ~= "function" then return end
    local rewards = Badges.QuestRewards()
    if #rewards == 0 then return end
    local f = EnumerateFrames()
    while f do
        local usable = not (f.IsForbidden and f:IsForbidden()) and f.IsVisible and f:IsVisible()
        -- Skip our own badges, and buttons the bag hook already labels with their own item.
        if usable and not shown[f] and f.GetRegions then
            for _, rw in ipairs(rewards) do
                local icon = iconRegion(f, rw.icons)
                if icon and showsName(f, rw.names) then
                    Badges.Update(f, rw.link, icon)
                    questBadged[f] = true
                    break
                end
            end
        end
        f = EnumerateFrames(f)
    end
end

-- Quest windows lay out (and some animate in) over a few frames: look twice.
local scanQueued = false
local lastQuestShown = -100
local function queueScan(fromItemInfo)
    if fromItemInfo ~= true then lastQuestShown = (GetTime and GetTime()) or 0 end
    if not (C_Timer and C_Timer.After) then Badges.ScanQuestRewards() return end
    if scanQueued then return end
    scanQueued = true
    C_Timer.After(0.1, function() scanQueued = false; Badges.ScanQuestRewards() end)
    C_Timer.After(0.6, Badges.ScanQuestRewards)
end
Badges.queueScan = queueScan  -- (tests)

local function install()
    -- Picking a quest in any quest log goes through the game's SelectQuestLogEntry.
    if hooksecurefunc and type(SelectQuestLogEntry) == "function" then
        hooksecurefunc("SelectQuestLogEntry", queueScan)
    end
    if hooksecurefunc and type(QuestInfo_Display) == "function" then
        hooksecurefunc("QuestInfo_Display", queueScan)
    end
    if not hooksecurefunc then return end
    if type(SetItemButtonQuality) == "function" then
        hooksecurefunc("SetItemButtonQuality", function(button, _, link) Badges.Update(button, link) end)
    end
    if type(SetItemButtonTexture) == "function" then hooksecurefunc("SetItemButtonTexture", onTexture) end
    -- Item buttons created from now on get their methods from this mixin (EllesmereUIBags calls them).
    if type(ItemButtonMixin) == "table" then
        if type(ItemButtonMixin.SetItemButtonQuality) == "function" then
            hooksecurefunc(ItemButtonMixin, "SetItemButtonQuality", function(self, _, link) Badges.Update(self, link) end)
        end
        if type(ItemButtonMixin.SetItemButtonTexture) == "function" then
            hooksecurefunc(ItemButtonMixin, "SetItemButtonTexture", onTexture)
        end
    end
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_LEVEL_UP", "CHARACTER_POINTS_CHANGED",
    "ACTIVE_TALENT_GROUP_CHANGED", "GET_ITEM_INFO_RECEIVED", "QUEST_DETAIL", "QUEST_COMPLETE", "QUEST_FINISHED" }) do
    pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        install()
    elseif event == "QUEST_DETAIL" or event == "QUEST_COMPLETE" then
        npcQuestOpen = true
        queueScan()
    elseif event == "QUEST_FINISHED" then
        npcQuestOpen = false
        queueScan()  -- clears the NPC quest's badges (and keeps the quest log's)
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Only uncached items scored as "not gear" (false) could change; keep known gains.
        for k, v in pairs(cache) do if v == false then cache[k] = nil end end
        -- A reward's info arriving late: look again, only shortly after a quest was shown.
        if rewardsPending and ((GetTime and GetTime()) or 0) - lastQuestShown < 5 then queueScan(true) end
    elseif event == "PLAYER_LEVEL_UP" and C_Timer and C_Timer.After then
        C_Timer.After(0.5, Badges.Invalidate)  -- UnitLevel catches up a moment after the event
    else
        Badges.Invalidate()
    end
end)

Badges.formatGain = formatGain  -- (tests)
