local _, ns = ...

-- Compact, quest-tracker sized list of the best gear pieces for the player's level.
-- In a zone/instance where recommended items can be obtained it switches to a zone view
-- ("In <zone>": those items and where they come from), and can pop up on its own there.
-- Public: ns:ShowMini(), ns:HideMini(), ns:ToggleMini(), ns:SetMiniCount(n), ns:RefreshMini(),
--         ns:SetMiniAutoPopup(on), ns:SetMiniOpacity(0..1)

local WIDTH = 300     -- room for the zone view's source column and the header buttons
local HEADER_H = 28   -- fits the 20px header buttons with 4px margins
local ROW_H = 24      -- bar rows (Skin:BarRow): 3px quality bar, 24px icon
local ROW_GAP = 2
local PITCH = ROW_H + ROW_GAP
local PAD = 4
local MAX_ROWS = 20   -- visible rows (the +/- count sets the window height)
local LIST_MAX = 60   -- items fetched; the mouse wheel scrolls through those beyond the visible rows
local FONT_SIZE = 11
-- Background opacity: click the header button to step down (right-click: up), wheel over it for 5%.
-- Only the backdrop, frame edge, header band and row stripes fade; text and icons stay readable.
local OPACITY_STEPS = { 1, 0.85, 0.7, 0.55, 0.4, 0.25, 0 }

local READY = "Interface\\RaidFrame\\ReadyCheck-Ready"
local MAP_ICON = "Interface\\Icons\\INV_Misc_Map_01"  -- item icon: present on every client
local SLOT_W, ZONE_SRC_W = 52, 104                   -- right-side dim column: slot / zone source

local frame          -- created lazily on first ShowMini
local rows = {}
local zoneMode = false     -- showing "In <zone>" picks instead of the top picks
local autoOpened = false   -- the mini was opened by the zone auto-popup (not by the user)
local list = {}            -- every pick currently listed (up to LIST_MAX)
local offset = 0           -- scroll position: index of the first visible pick, minus one

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

-- Where in the zone, short: "Old Serra'kis" (drop), "Vendor: X", "Quest: Y", ...
local SOURCE_PREFIX = { vendor = "Vendor: ", quest = "Quest: ", craft = "Crafted: " }
local function zoneSourceText(src)
    if type(src) ~= "table" then return "" end
    return (SOURCE_PREFIX[src.t] or "") .. (src.n or "?")
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function rowOnEnter(row)
    if not row.pick then return end
    ns:ShowItemTooltip(row, row.pick.id, {
        score = row.pick.score, delta = row.pick.delta, beside = frame,  -- outside the tracker, never over it
    })
    local src = row.pick.zoneSource
    if type(src) == "table" and GameTooltip:IsOwned(row) then
        GameTooltip:AddLine("Here: " .. ns.FormatSource(src), 1, 0.82, 0, true)
        if ns.HasLocation and ns.HasLocation(src) then
            GameTooltip:AddLine("Ctrl-click: show on the map", 0.4, 1, 0.6)
        end
        GameTooltip:Show()
    end
end

local function rowOnLeave(row)
    ns:HideItemTooltip()
end

local function rowOnClick(row)
    local pick = row.pick
    if not pick then return end
    if IsAltKeyDown and IsAltKeyDown() then
        ns:ToggleFavorite(pick.id)  -- Core refreshes the tracker (favorites are listed first)
        return
    end
    if IsShiftKeyDown() then
        local link = select(2, ns.GetItemInfo(pick.id))
        if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
        return
    end
    if IsControlKeyDown and IsControlKeyDown() and type(pick.zoneSource) == "table" then
        ns:ShowSourceOnMap(pick.zoneSource)
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
    if row.barBg then row.barBg:SetAlpha(tonumber(GearGuideDB.mini.opacity) or 1) end  -- background opacity

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
    row.slot:SetWidth(SLOT_W)
    row.slot:SetJustifyH("RIGHT")
    row.slot:SetWordWrap(false)

    row.contentX = row.barContentX or (ROW_H + 11)

    -- Favorite star in front of the name (only on favorite rows; display only).
    row.star = row:CreateTexture(nil, "OVERLAY")
    row.star:SetSize(12, 12)
    row.star:SetPoint("LEFT", row, "LEFT", row.contentX - 2, 0)
    row.star:SetTexture(ns.Skin.STAR)
    row.star:Hide()

    row.name = ns.Skin:Text(row, FONT_SIZE + 1)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetShadowColor(0, 0, 0, 1)
    row.nameShifted = "init"  -- forces the first anchor in fillRow

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
    local fav = pick.favorite and true or false
    row.star:SetShown(fav)
    if row.nameShifted ~= fav then  -- make room for the star
        row.nameShifted = fav
        row.name:ClearAllPoints()
        row.name:SetPoint("LEFT", row, "LEFT", row.contentX + (fav and 13 or 0), 0)
        row.name:SetPoint("RIGHT", row.slot, "LEFT", -4, 0)
    end
    row.name:SetText(item.n or ("item:" .. pick.id))
    row.name:SetTextColor(color(done and "textDim" or "text"))
    if pick.zoneSource then
        row.slot:SetWidth(ZONE_SRC_W)  -- zone view: where in this zone instead of the slot
        row.slot:SetText(zoneSourceText(pick.zoneSource))
    else
        row.slot:SetWidth(SLOT_W)
        row.slot:SetText(pick.groupLabel or (item.eq and ns.SlotLabel(item.eq)) or "")
    end
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
local function opacity()
    local o = tonumber(GearGuideDB.mini.opacity)
    if not o then return 1 end
    return math.max(0, math.min(1, o))
end

local function applyOpacity()
    local o = opacity()
    if frame.SetBackdropColor then
        local r, g, b, a = color("bg")
        frame:SetBackdropColor(r, g, b, a * o)
        r, g, b, a = color("edge")
        frame:SetBackdropBorderColor(r, g, b, a * o)
    elseif frame.ggFlat then
        for _, t in pairs(frame.ggFlat) do t:SetAlpha(o) end
    end
    for _, t in ipairs(frame.vignette or {}) do t:SetAlpha(o) end
    frame.headerBg:SetAlpha(o)
    frame.track:SetAlpha(o)
    for _, row in ipairs(rows) do
        if row.barBg then row.barBg:SetAlpha(o) end
    end
    -- the button's icon: right half shows the current opacity
    frame.opacityBtn.fill:SetAlpha(0.15 + 0.85 * o)
end

local function updateHeader()
    local db = GearGuideDB.mini
    frame.countText:SetText(tostring(db.count))
    if db.count <= 1 then frame.minus:Disable() else frame.minus:Enable() end
    if db.count >= MAX_ROWS then frame.plus:Disable() else frame.plus:Enable() end
    frame.doneIcon:SetAlpha(db.hideCompleted and 1 or 0.3)
    local on = db.autoPopup and true or false
    frame.autoBtn:SetActive(on)
    if frame.autoBtn.icon.SetDesaturated then frame.autoBtn.icon:SetDesaturated(not on) end
    frame.autoBtn.icon:SetAlpha(on and 1 or 0.35)
    applyOpacity()
end

local function createFrame()
    local f = CreateFrame("Frame", "GearGuideMiniFrame", UIParent, "BackdropTemplate")
    f:SetSize(WIDTH, HEADER_H + PAD * 2 + ROW_H)
    f:SetFrameStrata("MEDIUM")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    -- Same warm backdrop + 1px warm edge as the main window, with a lighter vignette, no watermark.
    ns.Skin:WindowBackdrop(f, { vignette = 22 })
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
    f.headerBg = headerBg

    local title = ns.Skin:Text(header, 12, "accent")
    title:SetPoint("LEFT", header, "LEFT", 8, 0)
    title:SetWordWrap(false)
    title:SetText("GearGuide")
    f.title = title

    local BTN = 20
    local close = ns.Skin:IconButton(header, "x", BTN)
    close:SetPoint("RIGHT", header, "RIGHT", -4, 0)
    close:SetScript("OnClick", function() ns:HideMini() end)
    addTooltip(close, "Close", function() return "Reopen with /gg mini or Shift-click the minimap icon." end)

    local open = ns.Skin:IconButton(header, ">", BTN)
    open:SetPoint("RIGHT", close, "LEFT", -4, 0)
    open:SetScript("OnClick", function() ns:ToggleWindow() end)
    addTooltip(open, "Open main window")

    local done = ns.Skin:IconButton(header, "", BTN)
    done:SetPoint("RIGHT", open, "LEFT", -4, 0)
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

    -- Auto-popup in zones with recommended items (on: full-color map + accent bar).
    local auto = ns.Skin:IconButton(header, "", BTN)
    auto:SetPoint("RIGHT", done, "LEFT", -4, 0)
    local autoIcon = auto:CreateTexture(nil, "OVERLAY")
    autoIcon:SetTexture(MAP_ICON)
    autoIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    autoIcon:SetSize(BTN - 6, BTN - 6)
    autoIcon:SetPoint("CENTER")
    auto.icon = autoIcon
    auto:SetScript("OnClick", function() ns:SetMiniAutoPopup(not GearGuideDB.mini.autoPopup) end)
    addTooltip(auto, "Auto-open in zones with recommended items", function()
        return (GearGuideDB.mini.autoPopup and "On" or "Off")
            .. ": the tracker opens by itself when you enter a zone or instance where your upgrades "
            .. "or favorites drop, and closes again when you leave (unless you opened it yourself). "
            .. "Also: /gg mini auto"
    end)
    f.autoBtn = auto

    -- Background opacity: a small square, left half solid, right half at the current opacity.
    local op = ns.Skin:IconButton(header, "", BTN)
    op:SetPoint("RIGHT", auto, "LEFT", -4, 0)
    local S = BTN - 10
    local solid = op:CreateTexture(nil, "OVERLAY")
    solid:SetSize(S / 2, S)
    solid:SetPoint("CENTER", -S / 4, 0)
    solid:SetColorTexture(color("accent"))
    local fill = op:CreateTexture(nil, "OVERLAY")
    fill:SetSize(S / 2, S)
    fill:SetPoint("CENTER", S / 4, 0)
    fill:SetColorTexture(color("accent"))
    op.fill = fill
    op:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    op:SetScript("OnClick", function(_, button)
        local o, n = opacity(), #OPACITY_STEPS
        if button == "RightButton" then  -- next step up (more opaque), wrapping to the lowest
            for i = n, 1, -1 do
                if OPACITY_STEPS[i] > o + 0.001 then ns:SetMiniOpacity(OPACITY_STEPS[i]) return end
            end
            ns:SetMiniOpacity(OPACITY_STEPS[n])
        else                             -- next step down (more transparent), wrapping to full
            for i = 1, n do
                if OPACITY_STEPS[i] < o - 0.001 then ns:SetMiniOpacity(OPACITY_STEPS[i]) return end
            end
            ns:SetMiniOpacity(OPACITY_STEPS[1])
        end
    end)
    op:EnableMouseWheel(true)
    op:SetScript("OnMouseWheel", function(self, delta)
        ns:SetMiniOpacity(opacity() + delta * 0.05)
        if self:IsMouseOver() and self:GetScript("OnEnter") then self:GetScript("OnEnter")(self) end
    end)
    addTooltip(op, "Background opacity", function()
        return string.format("%d%%. Click: more transparent, right-click: less. Mouse wheel: 5%% steps. "
            .. "Text and icons always stay visible. Also: /gg mini opacity 0-100", math.floor(opacity() * 100 + 0.5))
    end)
    f.opacityBtn = op

    local plus = ns.Skin:IconButton(header, "+", BTN)
    plus:SetPoint("RIGHT", op, "LEFT", -8, 0)
    plus:SetScript("OnClick", function() ns:SetMiniCount(GearGuideDB.mini.count + 1) end)
    addTooltip(plus, "Show more rows", function() return "Scroll with the mouse wheel to see the rest of the list." end)
    f.plus = plus

    local countText = ns.Skin:Text(header, FONT_SIZE, "text")
    countText:SetPoint("RIGHT", plus, "LEFT", -4, 0)
    countText:SetWidth(18)
    countText:SetJustifyH("CENTER")
    f.countText = countText

    local minus = ns.Skin:IconButton(header, "-", BTN)
    minus:SetPoint("RIGHT", countText, "LEFT", -4, 0)
    minus:SetScript("OnClick", function() ns:SetMiniCount(GearGuideDB.mini.count - 1) end)
    addTooltip(minus, "Show fewer rows", function() return "Scroll with the mouse wheel to see the rest of the list." end)
    f.minus = minus
    title:SetPoint("RIGHT", minus, "LEFT", -8, 0)  -- long zone names truncate

    -- One-line note when there is nothing to list
    local note = ns.Skin:Text(f, FONT_SIZE, "textDim")
    note:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + 4, -(HEADER_H + PAD))
    note:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD - 4, -(HEADER_H + PAD))
    note:SetHeight(ROW_H)
    note:SetJustifyH("LEFT")
    note:SetWordWrap(false)
    note:Hide()
    f.note = note

    -- Scrolling: the mouse wheel anywhere over the tracker (rows don't take wheel input, so it
    -- reaches the frame). A 2px thumb in the right padding shows the position; no extra width.
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta) ns:ScrollMini(-delta) end)
    local track = f:CreateTexture(nil, "ARTWORK")
    track:SetWidth(2)
    track:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -(HEADER_H + PAD))
    track:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, PAD)
    track:SetColorTexture(1, 1, 1, 0.08)
    f.track = track
    local thumb = f:CreateTexture(nil, "OVERLAY")
    thumb:SetWidth(2)
    thumb:SetColorTexture(color("accent"))
    f.thumb = thumb

    restorePosition(f)
    return f
end

-- Positions the scroll thumb for `visible` rows out of #list; hidden when everything fits.
local function updateScrollbar(visible)
    local total = #list
    if total <= visible or visible == 0 then
        frame.track:Hide(); frame.thumb:Hide()
        return
    end
    local trackH = visible * PITCH - ROW_GAP
    local thumbH = math.max(8, trackH * visible / total)
    local y = (trackH - thumbH) * offset / (total - visible)
    frame.thumb:SetHeight(thumbH)
    frame.thumb:ClearAllPoints()
    frame.thumb:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -(HEADER_H + PAD) - y)
    frame.track:Show(); frame.thumb:Show()
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
-- Fills the visible rows from list[offset + 1 ...]. Scrolling only calls this, no re-fetch.
local function render()
    local db = GearGuideDB.mini
    local visible = math.min(db.count, #list)
    offset = math.max(0, math.min(offset, #list - visible))
    local n = visible
    for i = 1, n do
        rows[i] = rows[i] or createRow(frame, i)
        fillRow(rows[i], list[offset + i])
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

    updateScrollbar(n)

    -- Keep the tooltip in sync if the list changed (or scrolled) under the cursor.
    for i = 1, n do
        if rows[i]:IsMouseOver() and GameTooltip:IsOwned(rows[i]) then rowOnEnter(rows[i]) end
    end
end

function ns:RefreshMini()
    if not frame or not frame:IsShown() then return end
    local db = GearGuideDB.mini
    db.count = clampCount(db.count)
    updateHeader()

    -- Zone view when recommended items can be obtained right here; otherwise the top picks.
    local picks, zoneName = {}, nil
    if self.GetZonePicks then picks, zoneName = self:GetZonePicks(LIST_MAX) end
    picks = picks or {}
    local wasZone = zoneMode
    zoneMode = #picks > 0
    if zoneMode then
        frame.title:SetText("In " .. (zoneName or "this zone"))
    else
        frame.title:SetText("GearGuide")
        picks = self:GetTopPicks(LIST_MAX, db.hideCompleted) or {}
    end
    if zoneMode ~= wasZone then offset = 0 end  -- a different list: start at its top
    list = picks
    render()  -- clamps the scroll position to the new list
end

-- delta: +1 scrolls down a row, -1 up.
function ns:ScrollMini(delta)
    if not frame or not frame:IsShown() then return end
    local before = offset
    offset = offset + delta
    render()
    return offset ~= before
end

local function showFrame()
    if not frame then frame = createFrame() end
    frame:Show()
end

local function hideFrame()
    if frame then frame:Hide() end
    for k in pairs(pendingIcons) do pendingIcons[k] = nil end
    for _, row in ipairs(rows) do
        if GameTooltip:IsOwned(row) then ns:HideItemTooltip() break end
    end
end

function ns:ShowMini()
    autoOpened = false  -- the user's choice wins over the auto-popup
    GearGuideDB.mini.shown = true
    showFrame()
    self:RefreshMini()
    if self.RefreshUI then self:RefreshUI() end  -- keep the main window's "Mini" button in sync
end

function ns:HideMini()
    autoOpened = false
    GearGuideDB.mini.shown = false
    hideFrame()
    if self.RefreshUI then self:RefreshUI() end
end

function ns:ToggleMini()
    if frame and frame:IsShown() then self:HideMini() else self:ShowMini() end
end

function ns:SetMiniCount(n)
    GearGuideDB.mini.count = clampCount(n)
    self:RefreshMini()
end

---------------------------------------------------------------------------
-- Zone auto-popup
---------------------------------------------------------------------------
local zoneTimer
local popupDeferred = false   -- entered a zone with picks during combat: pop up afterwards

local function ready()
    return GearGuideDB ~= nil and GearGuideDB.mini ~= nil and GearGuideCharDB ~= nil and ns.GetZonePicks ~= nil
end

local function zoneHasPicks()
    local ok, picks = pcall(ns.GetZonePicks, ns, 1)
    return ok and type(picks) == "table" and #picks > 0
end

-- Battlegrounds and arenas: the tracker gets out of the way on entry and comes back on exit if
-- the player had it open (GearGuideDB.mini.shown is the player's choice and is never touched).
-- Only the transition hides it, so reopening it mid-match sticks until the next entry.
local wasPvP = false
local function inPvP()
    if not IsInInstance then return false end
    local _, kind = IsInInstance()
    return kind == "pvp" or kind == "arena"
end

local function handlePvP()
    local pvp = inPvP()
    if pvp and not wasPvP then
        autoOpened, popupDeferred = false, false
        hideFrame()
    elseif not pvp and wasPvP and GearGuideDB.mini.shown and not (frame and frame:IsShown()) then
        showFrame()
        ns:RefreshMini()
    end
    wasPvP = pvp
    return pvp
end

-- Runs (debounced) after zone changes and when combat ends.
function ns:CheckMiniZone()
    if not ready() then return end
    if handlePvP() then return end  -- no zone view or auto-popup in battlegrounds/arenas
    local shown = frame and frame:IsShown()
    if shown and not autoOpened then
        self:RefreshMini()      -- the user's tracker: just switch between zone view and top picks
        return
    end
    local has = zoneHasPicks()
    if shown then               -- auto-opened: follow the zone
        if has then
            self:RefreshMini()
        else
            autoOpened = false
            hideFrame()         -- mini.shown was never set, nothing to persist
        end
        return
    end
    if has and GearGuideDB.mini.autoPopup then
        if InCombatLockdown and InCombatLockdown() then
            popupDeferred = true
            return
        end
        showFrame()             -- not persisted: GearGuideDB.mini.shown stays false
        autoOpened = true
        self:RefreshMini()
    end
end

local function scheduleZoneCheck(delay)
    if zoneTimer then zoneTimer:Cancel() end
    zoneTimer = C_Timer.NewTimer(delay or 1, function()  -- zone name/map settle after loading
        zoneTimer = nil
        ns:CheckMiniZone()
    end)
end

function ns:SetMiniOpacity(o)
    o = math.max(0, math.min(1, tonumber(o) or 1))
    GearGuideDB.mini.opacity = math.floor(o * 100 + 0.5) / 100
    if frame then applyOpacity() end
end

function ns:SetMiniAutoPopup(on)
    GearGuideDB.mini.autoPopup = on and true or false
    if frame then updateHeader() end
    if on then scheduleZoneCheck(0.1) end  -- pop up right away if this zone has picks
end

function ns:IsMiniAutoOpened() return autoOpened end

local zoneEvents = CreateFrame("Frame")
for _, e in ipairs({ "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_INDOORS",
                     "PLAYER_REGEN_ENABLED" }) do
    pcall(zoneEvents.RegisterEvent, zoneEvents, e)
end
zoneEvents:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        if popupDeferred then
            popupDeferred = false
            ns:CheckMiniZone()
        end
        return
    end
    popupDeferred = false
    -- Hide right away on entering a battleground/arena (no 1s flash after the loading screen);
    -- IsInInstance is already valid at PLAYER_ENTERING_WORLD.
    if ready() then handlePvP() end
    scheduleZoneCheck(1)
end)
