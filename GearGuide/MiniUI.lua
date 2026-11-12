local _, ns = ...

-- Compact, quest-tracker sized list of the best gear pieces for the player's level.
-- Public: ns:ShowMini(), ns:HideMini(), ns:ToggleMini(), ns:SetMiniCount(n), ns:RefreshMini()

local WIDTH = 260
local HEADER_H = 20
local ROW_H = 24      -- bar rows (Skin:BarRow): 3px quality bar, 24px icon
local ROW_GAP = 2
local PITCH = ROW_H + ROW_GAP
local PAD = 4
local MAX_ROWS = 20
local FONT_SIZE = 11

local READY = "Interface\\RaidFrame\\ReadyCheck-Ready"

local frame          -- created lazily on first ShowMini
local rows = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function color(key)
    local c = ns.Skin.C[key]
    return c[1] or c.r, c[2] or c.g, c[3] or c.b, c[4] or c.a or 1
end

local function clampCount(n)
    n = math.floor(tonumber(n) or 10)
    if n < 1 then n = 1 elseif n > MAX_ROWS then n = MAX_ROWS end
    return n
end

local function simpleTooltip(owner, title, line)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:AddLine(title)
    if line then GameTooltip:AddLine(line, 1, 1, 1, true) end
    GameTooltip:Show()
end

local function addTooltip(button, title, lineFn)
    button:HookScript("OnEnter", function(self)
        simpleTooltip(self, title, lineFn and lineFn())
    end)
    button:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local function savePosition(f)
    local point, _, relPoint, x, y = f:GetPoint(1)
    local db = GearGuideDB.mini
    db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
end

local function restorePosition(f)
    local db = GearGuideDB.mini
    f:ClearAllPoints()
    if db.point then
        f:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x or 0, db.y or 0)
    else
        f:SetPoint("RIGHT", UIParent, "RIGHT", -80, 120)
    end
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function rowOnEnter(row)
    if not row.pick then return end
    ns:ShowItemTooltip(row, row.pick.id, {
        score = row.pick.score, delta = row.pick.delta, anchor = "ANCHOR_LEFT",
    })
end

local function rowOnLeave(row)
    ns:HideItemTooltip()
end

local function rowOnClick(row)
    local pick = row.pick
    if not pick then return end
    if IsShiftKeyDown() then
        local link = select(2, ns.GetItemInfo(pick.id))
        if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
        return
    end
    ns:ShowItem(pick.id)
end

local function createRow(parent, index)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -(HEADER_H + PAD + (index - 1) * PITCH))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD, -(HEADER_H + PAD + (index - 1) * PITCH))
    row:RegisterForClicks("LeftButtonUp")
    ns.Skin:BarRow(row, ROW_H)   -- quality bar, full-height icon, dark gradient, hover

    -- Right side: [slot] [mark] [+delta]
    row.delta = ns.Skin:Text(row, FONT_SIZE, "upgrade")
    row.delta:SetPoint("RIGHT", row, "RIGHT", -5, 0)
    row.delta:SetWidth(34)
    row.delta:SetJustifyH("RIGHT")

    row.mark = ns.Skin:Text(row, 10)
    row.mark:SetPoint("RIGHT", row.delta, "LEFT", -2, 0)
    row.mark:SetWidth(18)
    row.mark:SetJustifyH("CENTER")

    row.slot = ns.Skin:Text(row, 10, "textDim")
    row.slot:SetPoint("RIGHT", row.mark, "LEFT", -2, 0)
    row.slot:SetWidth(52)
    row.slot:SetJustifyH("RIGHT")
    row.slot:SetWordWrap(false)

    row.name = ns.Skin:Text(row, FONT_SIZE + 1)
    row.name:SetPoint("LEFT", row, "LEFT", row.barContentX or (ROW_H + 11), 0)
    row.name:SetPoint("RIGHT", row.slot, "LEFT", -4, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetShadowColor(0, 0, 0, 1)

    row:SetScript("OnEnter", rowOnEnter)
    row:SetScript("OnLeave", rowOnLeave)
    row:SetScript("OnClick", rowOnClick)
    return row
end

-- Uncached items show the "?" icon; ask for them and re-fill the rows when they arrive.
local pendingIcons = {}
local iconRefreshPending = false

local function rowIcon(id)
    local icon = ns.ItemIcon(id)
    if icon == ns.QUESTION_ICON then
        pendingIcons[id] = true
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(id)
        else
            ns.GetItemInfo(id)
        end
    end
    return icon
end

local function fillRow(row, pick)
    row.pick = pick
    local item = pick.item or ns:GetItem(pick.id) or {}
    row.mark:SetText(ns:CompletionMarkup(pick.id))
    row:SetBarQuality(item.q)
    row:SetBarIcon(rowIcon(pick.id))
    local done = ns:GetCompletion(pick.id, ns:GetPlayerClass()) == "done"
    row:SetBarDimmed(done)
    row.name:SetText(item.n or ("item:" .. pick.id))
    row.name:SetTextColor(color(done and "textDim" or "text"))
    row.slot:SetText(pick.groupLabel or (item.eq and ns.SlotLabel(item.eq)) or "")
    if pick.delta and pick.delta > 0 then
        row.delta:SetText(string.format("+%.1f", pick.delta))
    else
        row.delta:SetText("")
    end
    row:Show()
end

local iconEvents = CreateFrame("Frame")
iconEvents:RegisterEvent("GET_ITEM_INFO_RECEIVED")
iconEvents:SetScript("OnEvent", function(_, _, itemID)
    itemID = tonumber(itemID)
    if not itemID or not pendingIcons[itemID] then return end
    pendingIcons[itemID] = nil
    if iconRefreshPending or not frame or not frame:IsShown() then return end
    iconRefreshPending = true
    C_Timer.After(0.2, function()
        iconRefreshPending = false
        if not frame or not frame:IsShown() then return end
        -- Re-fill the rows already shown; no need to rebuild the picks.
        for _, row in ipairs(rows) do
            if row.pick and row:IsShown() then fillRow(row, row.pick) end
        end
    end)
end)

---------------------------------------------------------------------------
-- Frame
---------------------------------------------------------------------------
local function updateHeader()
    local db = GearGuideDB.mini
    frame.countText:SetText(tostring(db.count))
    if db.count <= 1 then frame.minus:Disable() else frame.minus:Enable() end
    if db.count >= MAX_ROWS then frame.plus:Disable() else frame.plus:Enable() end
    frame.doneIcon:SetAlpha(db.hideCompleted and 1 or 0.3)
end

local function createFrame()
    local f = CreateFrame("Frame", "GearGuideMiniFrame", UIParent, "BackdropTemplate")
    f:SetSize(WIDTH, HEADER_H + PAD * 2 + ROW_H)
    f:SetFrameStrata("MEDIUM")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    ns.Skin:SetBackdrop(f, "bg", "border")
    f:Hide()

    -- Header: drag handle + controls
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        savePosition(f)
    end)
    f.header = header

    local headerBg = header:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetColorTexture(color("header"))

    local title = ns.Skin:Text(header, 12, "accent")
    title:SetPoint("LEFT", header, "LEFT", 6, 0)
    title:SetText("GearGuide")
    f.title = title

    local BTN = 16
    local close = ns.Skin:IconButton(header, "x", BTN)
    close:SetPoint("RIGHT", header, "RIGHT", -2, 0)
    close:SetScript("OnClick", function() ns:HideMini() end)
    addTooltip(close, "Close", function() return "Reopen with /gg mini or Shift-click the minimap icon." end)

    local open = ns.Skin:IconButton(header, ">", BTN)
    open:SetPoint("RIGHT", close, "LEFT", -2, 0)
    open:SetScript("OnClick", function() ns:ToggleWindow() end)
    addTooltip(open, "Open main window")

    local done = ns.Skin:IconButton(header, "", BTN)
    done:SetPoint("RIGHT", open, "LEFT", -2, 0)
    local doneIcon = done:CreateTexture(nil, "OVERLAY")
    doneIcon:SetTexture(READY)
    doneIcon:SetSize(BTN - 4, BTN - 4)
    doneIcon:SetPoint("CENTER")
    f.doneIcon = doneIcon
    done:SetScript("OnClick", function()
        GearGuideDB.mini.hideCompleted = not GearGuideDB.mini.hideCompleted
        ns:RefreshMini()
    end)
    addTooltip(done, "Hide acquired items", function()
        return GearGuideDB.mini.hideCompleted and "On: acquired items are hidden." or "Off: acquired items are shown."
    end)

    local plus = ns.Skin:IconButton(header, "+", BTN)
    plus:SetPoint("RIGHT", done, "LEFT", -6, 0)
    plus:SetScript("OnClick", function() ns:SetMiniCount(GearGuideDB.mini.count + 1) end)
    addTooltip(plus, "Show more items")
    f.plus = plus

    local countText = ns.Skin:Text(header, FONT_SIZE, "text")
    countText:SetPoint("RIGHT", plus, "LEFT", -2, 0)
    countText:SetWidth(18)
    countText:SetJustifyH("CENTER")
    f.countText = countText

    local minus = ns.Skin:IconButton(header, "-", BTN)
    minus:SetPoint("RIGHT", countText, "LEFT", -2, 0)
    minus:SetScript("OnClick", function() ns:SetMiniCount(GearGuideDB.mini.count - 1) end)
    addTooltip(minus, "Show fewer items")
    f.minus = minus

    -- One-line note when there is nothing to list
    local note = ns.Skin:Text(f, FONT_SIZE, "textDim")
    note:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 4, -(HEADER_H + PAD))
    note:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD - 4, -(HEADER_H + PAD))
    note:SetHeight(ROW_H)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(false)
    note:Hide()
    f.note = note

    restorePosition(f)
    return f
end

local function emptyMessage()
    if #ns:AllItemIds() == 0 then
        return "Item database is empty."
    elseif GearGuideDB.mini.hideCompleted then
        return "Nothing left to get at your level."
    end
    return "No recommendations for your level."
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function ns:RefreshMini()
    if not frame or not frame:IsShown() then return end
    local db = GearGuideDB.mini
    db.count = clampCount(db.count)
    updateHeader()

    local picks = self:GetTopPicks(db.count, db.hideCompleted) or {}
    local n = math.min(#picks, MAX_ROWS)
    for i = 1, n do
        rows[i] = rows[i] or createRow(frame, i)
        fillRow(rows[i], picks[i])
    end
    for i = n + 1, #rows do
        rows[i].pick = nil
        rows[i]:Hide()
    end

    if n == 0 then
        frame.note:SetText(emptyMessage())
        frame.note:Show()
        frame:SetHeight(HEADER_H + PAD * 2 + ROW_H + 2)
    else
        frame.note:Hide()
        frame:SetHeight(HEADER_H + PAD * 2 + n * PITCH - ROW_GAP + 2)
    end

    -- Keep the tooltip in sync if the list changed under the cursor.
    for i = 1, n do
        if rows[i]:IsMouseOver() and GameTooltip:IsOwned(rows[i]) then rowOnEnter(rows[i]) end
    end
end

function ns:ShowMini()
    if not frame then frame = createFrame() end
    GearGuideDB.mini.shown = true
    frame:Show()
    self:RefreshMini()
    if self.RefreshUI then self:RefreshUI() end  -- keep the main window's "Mini" button in sync
end

function ns:HideMini()
    GearGuideDB.mini.shown = false
    if frame then frame:Hide() end
    for k in pairs(pendingIcons) do pendingIcons[k] = nil end
    for _, row in ipairs(rows) do
        if GameTooltip:IsOwned(row) then ns:HideItemTooltip() break end
    end
    if self.RefreshUI then self:RefreshUI() end
end

function ns:ToggleMini()
    if frame and frame:IsShown() then self:HideMini() else self:ShowMini() end
end

function ns:SetMiniCount(n)
    GearGuideDB.mini.count = clampCount(n)
    self:RefreshMini()
end
