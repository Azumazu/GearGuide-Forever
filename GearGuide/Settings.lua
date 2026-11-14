local _, ns = ...

-- Settings tab of the main window: every user-adjustable option in one scrollable page.
-- Public: ns:CreateSettingsPanel(parent) -> panel (panel:Refresh() re-reads every control),
--         ns:SetWindowScale(s), ns:SetMinQuality(q), ns:SetLevelRange(behind, ahead)

local ROW_H = 30
local INDENT = 14
local LABEL_W = 230       -- steppers / dropdowns line up in one column after the labels
local MAX_LEVEL_BEHIND, MAX_LEVEL_AHEAD = 20, 10

local QUALITY_ITEMS = {
    { value = 1, text = "Common (white)" },
    { value = 2, text = "Uncommon (green)" },
    { value = 3, text = "Rare (blue)" },
    { value = 4, text = "Epic (purple)" },
}

local function tooltip(owner, title, line)
    owner:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(title, 1, 1, 1)
        if line then GameTooltip:AddLine(line, 0.75, 0.75, 0.75, true) end
        GameTooltip:Show()
    end)
    owner:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

---------------------------------------------------------------------------
-- Setters that need more than writing GearGuideDB
---------------------------------------------------------------------------
function ns:SetWindowScale(s)
    s = math.max(0.7, math.min(1.5, tonumber(s) or 1))
    GearGuideDB.window.scale = math.floor(s * 100 + 0.5) / 100
    if GearGuideFrame then GearGuideFrame:SetScale(GearGuideDB.window.scale) end
end

function ns:SetMinQuality(q)
    GearGuideDB.minQuality = math.max(1, math.min(4, math.floor(tonumber(q) or 2)))
    self:RequestRefresh()
end

function ns:SetLevelRange(behind, ahead)
    if behind then GearGuideDB.levelBehind = math.max(0, math.min(MAX_LEVEL_BEHIND, math.floor(behind))) end
    if ahead then GearGuideDB.levelAhead = math.max(0, math.min(MAX_LEVEL_AHEAD, math.floor(ahead))) end
    self:RequestRefresh()
end

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------
function ns:CreateSettingsPanel(parent)
    local Skin = ns.Skin
    local panel = CreateFrame("Frame", nil, parent)
    local controls = {}   -- each has :Sync() to re-read its value

    local scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -6, 0)
    local body = CreateFrame("Frame", nil, scroll)
    body:SetSize(400, 10)
    scroll:SetScrollChild(body)
    panel:HookScript("OnSizeChanged", function(_, w) body:SetWidth(math.max(300, (w or 400) - 6)) end)

    local thumb = panel:CreateTexture(nil, "OVERLAY")
    thumb:SetWidth(2)
    thumb:SetColorTexture(Skin.C.accent[1], Skin.C.accent[2], Skin.C.accent[3], 0.8)
    local function updateThumb()
        local viewH, total = scroll:GetHeight() or 0, body:GetHeight() or 0
        if total <= viewH + 1 or viewH <= 0 then thumb:Hide() return end
        local h = math.max(16, viewH * viewH / total)
        local y = (viewH - h) * (scroll:GetVerticalScroll() or 0) / (total - viewH)
        thumb:ClearAllPoints()
        thumb:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -y)
        thumb:SetHeight(h)
        thumb:Show()
    end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxY = math.max(0, (body:GetHeight() or 0) - (self:GetHeight() or 0))
        self:SetVerticalScroll(math.max(0, math.min(maxY, (self:GetVerticalScroll() or 0) - delta * ROW_H * 2)))
        updateThumb()
    end)
    scroll:HookScript("OnSizeChanged", updateThumb)

    local y = 4
    local function place(widget, x, h)
        widget:SetPoint("TOPLEFT", body, "TOPLEFT", x, -y)
        y = y + (h or ROW_H)
    end

    local function section(title, note)
        y = y + (y > 4 and 10 or 0)
        local t = Skin:Text(body, Skin.SIZE.header, "accent")
        t:SetText(title)
        t:SetPoint("TOPLEFT", body, "TOPLEFT", 2, -y)
        if note then
            local n = Skin:Text(body, Skin.SIZE.small, "textDim")
            n:SetText(note)
            n:SetPoint("LEFT", t, "RIGHT", 8, -1)
        end
        local line = Skin:Divider(body, "edge")
        line:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(y + 20))
        line:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -(y + 20))
        line:SetAlpha(0.5)
        y = y + 28
    end

    local function check(label, get, set, tip)
        local cb = Skin:Checkbox(body, label)
        place(cb, INDENT)
        cb.onToggle = function(_, on) set(on); panel:Refresh() end
        if tip then tooltip(cb, label, tip) end
        function cb:Sync() self:SetChecked(get() and true or false) end
        controls[#controls + 1] = cb
        return cb
    end

    local function label(text, tip)
        local row = CreateFrame("Frame", nil, body)
        row:SetSize(LABEL_W, Skin.CONTROL_H)
        row:EnableMouse(true)
        local fs = Skin:Text(row, Skin.SIZE.normal, "text")
        fs:SetPoint("LEFT", 0, 0)
        fs:SetText(text)
        if tip then tooltip(row, text, tip) end
        place(row, INDENT)
        return row
    end

    -- [-] value [+]; the value text shows fmt(value).
    local function stepper(text, get, set, minV, maxV, step, fmt, tip)
        local row = label(text, tip)
        local minus = Skin:IconButton(body, "-", 22)
        minus:SetPoint("LEFT", row, "RIGHT", 0, 0)
        local val = Skin:Text(body, Skin.SIZE.normal, "text")
        val:SetWidth(52)
        val:SetJustifyH("CENTER")
        val:SetPoint("LEFT", minus, "RIGHT", 4, 0)
        local plus = Skin:IconButton(body, "+", 22)
        plus:SetPoint("LEFT", val, "RIGHT", 4, 0)
        local c = { minus = minus, plus = plus, text = val }
        local function bump(d)
            local v = get() + d * step
            set(math.max(minV, math.min(maxV, v)))
            panel:Refresh()
        end
        minus:SetScript("OnClick", function() bump(-1) end)
        plus:SetScript("OnClick", function() bump(1) end)
        for _, b in ipairs({ minus, plus }) do
            b:EnableMouseWheel(true)
            b:SetScript("OnMouseWheel", function(_, delta) bump(delta) end)
        end
        function c:Sync()
            local v = get()
            val:SetText(fmt(v))
            if v <= minV + 1e-6 then minus:Disable() else minus:Enable() end
            if v >= maxV - 1e-6 then plus:Disable() else plus:Enable() end
        end
        controls[#controls + 1] = c
        return c
    end

    local function dropdown(text, items, get, set, tip)
        local row = label(text, tip)
        local dd = Skin:Dropdown(body, 160, {
            getItems = function() return items end,
            getValue = get,
            onSelect = function(v) set(v); panel:Refresh() end,
        })
        dd:SetPoint("LEFT", row, "RIGHT", 0, 0)
        function dd:Sync() self:Refresh() end
        controls[#controls + 1] = dd
        return dd
    end

    local pct = function(v) return math.floor(v * 100 + 0.5) .. "%" end
    local lv = function(v) return tostring(v) end
    local mini = function() return GearGuideDB.mini end

    -- General ---------------------------------------------------------------
    section("General")
    panel.minimap = check("Show the minimap icon",
        function() return not GearGuideDB.minimap.hide end,
        function(on) GearGuideDB.minimap.hide = not on; ns:UpdateMinimapButton() end,
        "Left-click: recommendations, Shift-click: mini tracker, right-click: gear browser. Also: /gg minimap")
    panel.sharing = check("Share item sources with guild and group",
        function() return ns:IsSharingEnabled() end,
        function(on) ns:SetSharing(on) end,
        "Shares the sources you discover (which creature, quest or vendor gives an item) with GearGuide users "
        .. "in your guild and group, and receives theirs. Invisible, no chat messages, no character data.")
    panel.unknown = check("Show items not discovered yet",
        function() return GearGuideDB.showUnknown end,
        function(on) ns:SetShowUnknown(on) end,
        "Items nobody has found a source for yet. Favorites always show.")

    -- Recommendations ----------------------------------------------------------
    section("Recommendations", "also used by the mini tracker")
    panel.behind = stepper("Levels below your level", function() return GearGuideDB.levelBehind or 5 end,
        function(v) ns:SetLevelRange(v, nil) end, 0, MAX_LEVEL_BEHIND, 1, lv,
        "Recommend items whose required level is up to this many levels below yours.")
    panel.ahead = stepper("Levels above your level", function() return GearGuideDB.levelAhead or 3 end,
        function(v) ns:SetLevelRange(nil, v) end, 0, MAX_LEVEL_AHEAD, 1, lv,
        "Also list upgrades you can't wear yet, up to this many levels ahead (things to aim for).")
    panel.quality = dropdown("Lowest quality recommended", QUALITY_ITEMS,
        function() return tonumber(GearGuideDB.minQuality) or 2 end,
        function(v) ns:SetMinQuality(v) end,
        "Items below this quality are never recommended. The gear browser has its own quality filter.")

    -- Mini tracker -----------------------------------------------------------
    section("Mini tracker")
    panel.miniShown = check("Show the mini tracker",
        function() return mini().shown end,
        function(on) if on then ns:ShowMini() else ns:HideMini() end end,
        "The compact list of your best upgrades. Also: /gg mini")
    panel.rows = stepper("Rows", function() return mini().count end,
        function(v) ns:SetMiniCount(v) end, 1, 20, 1, lv,
        "Visible rows. The mouse wheel scrolls through the rest of the list.")
    panel.miniScale = stepper("Scale", function() return tonumber(mini().scale) or 1 end,
        function(v) ns:SetMiniScale(v) end, 0.6, 1.6, 0.05, pct,
        "Size of the whole tracker: text, icons and rows. Its top-left corner stays in place. "
        .. "Also: /gg mini scale 60-160")
    panel.opacity = stepper("Background opacity", function() return tonumber(mini().opacity) or 1 end,
        function(v) ns:SetMiniOpacity(v) end, 0, 1, 0.05, pct,
        "Only the background fades; text and icons stay fully visible. Also: /gg mini opacity 0-100")
    panel.hover = check("Hover mode",
        function() return mini().hoverMode end,
        function(on) ns:SetMiniHoverMode(on) end,
        "Hides the tracker's header and background so only the item list shows. They come back while "
        .. "the mouse is over the tracker or the main window is open. Also: /gg mini hover")
    panel.hideDone = check("Hide acquired items",
        function() return mini().hideCompleted end,
        function(on) mini().hideCompleted = on; ns:RefreshMini() end)
    panel.auto = check("Open by itself in zones with upgrades",
        function() return mini().autoPopup end,
        function(on) ns:SetMiniAutoPopup(on) end,
        "Opens when you enter a zone or instance where your upgrades or favorites drop, and closes again "
        .. "when you leave (unless you opened it yourself).")
    panel.pvp = check("Hide in battlegrounds and arenas",
        function() return mini().pvpHide ~= false end,
        function(on) mini().pvpHide = on; if ns.CheckMiniZone then ns:CheckMiniZone() end end)

    -- Main window --------------------------------------------------------------
    section("Main window")
    panel.scale = stepper("Window scale", function() return tonumber(GearGuideDB.window.scale) or 1 end,
        function(v) ns:SetWindowScale(v) end, 0.7, 1.5, 0.05, pct)

    -- World map ----------------------------------------------------------------
    section("World map", "when you click a source's map button")
    panel.routes = check("Draw patrol routes",
        function() return GearGuideDB.map.routes ~= false end,
        function(on) GearGuideDB.map.routes = on end,
        "Lines showing where roaming vendors and patrolling rare mobs walk.")
    panel.waypoint = check("Set a waypoint arrow",
        function() return GearGuideDB.map.waypoint ~= false end,
        function(on) GearGuideDB.map.waypoint = on end,
        "Marks the spot with the game's waypoint (and TomTom's arrow, if you have TomTom).")

    body:SetHeight(y + 8)

    function panel:Refresh()
        for _, c in ipairs(controls) do c:Sync() end
        updateThumb()
    end
    panel:HookScript("OnShow", function() panel:Refresh() end)
    return panel
end
