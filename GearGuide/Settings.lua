local _, ns = ...

-- Settings tab of the main window: every user-adjustable option, on three sub tabs (General,
-- Tracker & pop-up, Stat weights), each its own scrollable page.
-- Public: ns:CreateSettingsPanel(parent) -> panel (panel:Refresh() re-reads every control,
--         panel:ShowPage(key), panel:ScrollToSection(key) opens the section's sub tab),
--         ns:SetWindowScale(s), ns:SetMinQuality(q), ns:SetLevelRange(behind, ahead)

local ROW_H = 30
local INDENT = 14
local LABEL_W = 230       -- steppers / dropdowns line up in one column after the labels
local WEIGHT_LABEL_W = 190
local WEIGHT_COL_W = WEIGHT_LABEL_W + 70 + 40  -- label + box + gap between the two columns
local SUBTAB_H = 26
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
    if GearGuideFrame then GearGuideFrame:SetScale(GearGuideDB.window.scale); ns.Skin:RefreshPixels() end
end

function ns:SetMinQuality(q)
    GearGuideDB.minQuality = math.max(1, math.min(4, math.floor(tonumber(q) or 2)))
    self:RequestRefresh()
end

-- Text typed into a custom stat weight box -> number to store, or nil to reject the input (the box
-- then shows the previous value again). Returning 0 clears the stat.
function ns.ParseWeight(text)
    text = (text or ""):match("^%s*(.-)%s*$")
    if text == "" then return 0 end                -- blank clears the stat
    local v = tonumber((text:gsub(",", ".")))      -- "0,5" (decimal comma) works too
    if not v or v ~= v then return nil end         -- not a number (or NaN)
    return math.max(-100, math.min(100, v))        -- negative = "avoid this stat"; caps typos
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

    -- Sub tabs ---------------------------------------------------------------
    local strip = CreateFrame("Frame", nil, panel)
    strip:SetPoint("TOPLEFT", 0, 0)
    strip:SetPoint("TOPRIGHT", 0, 0)
    strip:SetHeight(SUBTAB_H)
    local stripLine = Skin:Divider(panel, "edge")
    stripLine:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, 0)
    stripLine:SetPoint("TOPRIGHT", strip, "BOTTOMRIGHT", 0, 0)
    stripLine:SetAlpha(0.5)

    local pages, order, current = {}, {}, nil
    panel.pages = pages
    local sectionPage = {}   -- [section key] = page key

    -- A scrollable page under the strip, with its own thumb.
    local function newPage(key, title)
        local page = { key = key }
        local frame = CreateFrame("Frame", nil, panel)
        frame:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -6)
        frame:SetPoint("BOTTOMRIGHT", 0, 0)
        frame:Hide()
        local scroll = CreateFrame("ScrollFrame", nil, frame)
        scroll:SetPoint("TOPLEFT", 0, 0)
        scroll:SetPoint("BOTTOMRIGHT", -6, 0)
        local body = CreateFrame("Frame", nil, scroll)
        body:SetSize(400, 10)
        scroll:SetScrollChild(body)
        frame:HookScript("OnSizeChanged", function(_, w) body:SetWidth(math.max(300, (w or 400) - 6)) end)

        local thumb = frame:CreateTexture(nil, "OVERLAY")
        thumb:SetWidth(2)
        thumb:SetColorTexture(Skin.C.accent[1], Skin.C.accent[2], Skin.C.accent[3], 0.8)
        function page.updateThumb()
            local viewH, total = scroll:GetHeight() or 0, body:GetHeight() or 0
            if total <= viewH + 1 or viewH <= 0 then thumb:Hide() return end
            local h = math.max(16, viewH * viewH / total)
            local y = (viewH - h) * (scroll:GetVerticalScroll() or 0) / (total - viewH)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -y)
            thumb:SetHeight(h)
            thumb:Show()
        end
        function page.scrollTo(top)
            local maxY = math.max(0, (body:GetHeight() or 0) - (scroll:GetHeight() or 0))
            scroll:SetVerticalScroll(math.max(0, math.min(maxY, top)))
            page.updateThumb()
        end
        scroll:EnableMouseWheel(true)
        scroll:SetScript("OnMouseWheel", function(self, delta)
            page.scrollTo((self:GetVerticalScroll() or 0) - delta * ROW_H * 2)
        end)
        scroll:HookScript("OnSizeChanged", page.updateThumb)

        page.frame, page.body, page.y, page.sectionY = frame, body, 4, {}
        page.tab = Skin:Tab(strip, title, SUBTAB_H)
        if #order == 0 then
            page.tab:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", 0, 0)
        else
            page.tab:SetPoint("LEFT", pages[order[#order]].tab, "RIGHT", 2, 0)
        end
        page.tab:SetScript("OnClick", function() panel:ShowPage(key) end)
        pages[key] = page
        order[#order + 1] = key
        return page
    end

    -- Builders write to the page being built.
    local pg
    local function place(widget, x, h)
        widget:SetPoint("TOPLEFT", pg.body, "TOPLEFT", x, -pg.y)
        pg.y = pg.y + (h or ROW_H)
    end

    local function section(title, note, key)
        pg.y = pg.y + (pg.y > 4 and 10 or 0)
        if key then pg.sectionY[key] = pg.y; sectionPage[key] = pg.key end
        local t = Skin:Text(pg.body, Skin.SIZE.header, "accent")
        t:SetText(title)
        t:SetPoint("TOPLEFT", pg.body, "TOPLEFT", 2, -pg.y)
        if note then
            local n = Skin:Text(pg.body, Skin.SIZE.small, "textDim")
            n:SetText(note)
            n:SetPoint("LEFT", t, "RIGHT", 8, -1)
        end
        local line = Skin:Divider(pg.body, "edge")
        line:SetPoint("TOPLEFT", pg.body, "TOPLEFT", 0, -(pg.y + 20))
        line:SetPoint("TOPRIGHT", pg.body, "TOPRIGHT", 0, -(pg.y + 20))
        line:SetAlpha(0.5)
        pg.y = pg.y + 28
    end

    local function check(label, get, set, tip)
        local cb = Skin:Checkbox(pg.body, label)
        place(cb, INDENT)
        cb.onToggle = function(_, on) set(on); panel:Refresh() end
        if tip then tooltip(cb, label, tip) end
        function cb:Sync() self:SetChecked(get() and true or false) end
        controls[#controls + 1] = cb
        return cb
    end

    local function labelRow(text, tip, width)
        local row = CreateFrame("Frame", nil, pg.body)
        row:SetSize(width or LABEL_W, Skin.CONTROL_H)
        row:EnableMouse(true)
        local fs = Skin:Text(row, Skin.SIZE.normal, "text")
        fs:SetPoint("LEFT", 0, 0)
        fs:SetPoint("RIGHT", -6, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:SetText(text)
        if tip then tooltip(row, text, tip) end
        return row
    end
    local function label(text, tip)
        local row = labelRow(text, tip)
        place(row, INDENT)
        return row
    end

    -- [-] value [+]; the value text shows fmt(value).
    local function stepper(text, get, set, minV, maxV, step, fmt, tip)
        local row = label(text, tip)
        local minus = Skin:IconButton(pg.body, "-", 22)
        minus:SetPoint("LEFT", row, "RIGHT", 0, 0)
        local val = Skin:Text(pg.body, Skin.SIZE.normal, "text")
        val:SetWidth(52)
        val:SetJustifyH("CENTER")
        val:SetPoint("LEFT", minus, "RIGHT", 4, 0)
        local plus = Skin:IconButton(pg.body, "+", 22)
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
        local dd = Skin:Dropdown(pg.body, 160, {
            getItems = function() return items end,
            getValue = get,
            onSelect = function(v) set(v); panel:Refresh() end,
        })
        dd:SetPoint("LEFT", row, "RIGHT", 0, 0)
        function dd:Sync() self:Refresh() end
        controls[#controls + 1] = dd
        return dd
    end

    local function hintText(text)
        local hint = Skin:Text(pg.body, Skin.SIZE.small, "textDim")
        hint:SetWidth(LABEL_W + 280)
        hint:SetJustifyH("LEFT")
        hint:SetText(text)
        place(hint, INDENT, math.max(22, math.ceil(hint:GetStringHeight() or 0) + 10))
        return hint
    end

    local function finishPage()
        pg.body:SetHeight(pg.y + 8)
    end

    local pct = function(v) return math.floor(v * 100 + 0.5) .. "%" end
    local lv = function(v) return tostring(v) end
    local mini = function() return GearGuideDB.mini end

    ---------------------------------------------------------------------------
    -- Page 1: General
    ---------------------------------------------------------------------------
    pg = newPage("general", "General")

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
    panel.scale = stepper("Window scale", function() return tonumber(GearGuideDB.window.scale) or 1 end,
        function(v) ns:SetWindowScale(v) end, 0.7, 1.5, 0.05, pct)

    section("In the game", "tooltips, item icons, loot")
    panel.iconBadges = check("Upgrade numbers on items",
        function() return GearGuideDB.iconBadges ~= false end,
        function(on) ns.Badges.SetEnabled(on) end,
        "On item icons in your bags, the bank, merchants, loot and quest rewards (in any quest window), "
        .. "and in item tooltips: how the item scores against what you wear, green when it's better, "
        .. "red when it's worse.")
    panel.creatureTips = check("Show gear drops on creature tooltips",
        function() return GearGuideDB.creatureTips end,
        function(on) GearGuideDB.creatureTips = on and true or false end,
        "Mouse over a creature to see which of your recommended and favorite items it drops, with the drop chance "
        .. "and the score gain over what you have equipped.")
    panel.lootRolls = check("Loot roll help",
        function() return GearGuideDB.lootRollHelp ~= false end,
        function(on) GearGuideDB.lootRollHelp = on and true or false end,
        "On group loot rolls, shows what the item is worth to you, and in chat who in your party it's an "
        .. "upgrade for. Party members' gear is read with the game's Inspect when they're near you, so they "
        .. "don't need GearGuide.")
    panel.announceDrops = check("Announce new drop locations",
        function() return GearGuideDB.announceDrops ~= false end,
        function(on) GearGuideDB.announceDrops = on and true or false end,
        "When you loot gear from a creature that isn't listed as a source for it yet, shows "
        .. "\"New drop location discovered for [item]\" on screen and in chat.")

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
    do  -- Ignored items: how many, and a button to recommend them again
        local row = label("Ignored items", "Items you ignored (Ignore button in the item details) are never "
            .. "recommended. They still show in the gear browser, marked \"(ignored)\".")
        local count = Skin:Text(pg.body, Skin.SIZE.normal, "text")
        count:SetWidth(60)
        count:SetPoint("LEFT", row, "RIGHT", 0, 0)
        local clear = Skin:Button(pg.body, "Clear ignored items")
        clear:SetPoint("LEFT", count, "RIGHT", Skin.GAP, 0)
        clear:SetScript("OnClick", function()
            ns:ClearIgnored()
            ns.Print("No items are ignored any more.")
            panel:Refresh()
        end)
        tooltip(clear, "Clear ignored items", "Every ignored item can be recommended again.")
        local c = {}
        function c:Sync()
            local n = ns:IgnoredCount()
            count:SetText(tostring(n))
            if n > 0 then clear:Enable() else clear:Disable() end
        end
        controls[#controls + 1] = c
        panel.ignored = c
    end

    section("World map", "when you click a source's map button")
    panel.routes = check("Draw patrol routes",
        function() return GearGuideDB.map.routes ~= false end,
        function(on) GearGuideDB.map.routes = on end,
        "Lines showing where roaming vendors and patrolling rare mobs walk.")
    panel.waypoint = check("Set a waypoint arrow",
        function() return GearGuideDB.map.waypoint ~= false end,
        function(on) GearGuideDB.map.waypoint = on end,
        "Also places the game's own map pin and navigation arrow on the spot (and TomTom's arrow, if you "
        .. "have TomTom). Off by default: GearGuide's shaded areas and pins already show where to go.")
    finishPage()

    ---------------------------------------------------------------------------
    -- Page 2: Mini tracker and the Gear Acquired pop-up
    ---------------------------------------------------------------------------
    pg = newPage("tracker", "Tracker & Pop-up")

    section("Mini tracker", "/gg mini", "mini")
    panel.miniShown = check("Show the mini tracker",
        function() return mini().shown end,
        function(on) if on then ns:ShowMini() else ns:HideMini() end end,
        "The compact list of your best upgrades. Also: /gg mini")
    panel.auto = check("Open by itself in zones with upgrades",
        function() return mini().autoPopup end,
        function(on) ns:SetMiniAutoPopup(on) end,
        "Opens when you enter a zone or instance where your upgrades or favorites drop, and closes again "
        .. "when you leave (unless you opened it yourself).")
    panel.hideDone = check("Hide acquired items",
        function() return mini().hideCompleted end,
        function(on) mini().hideCompleted = on; ns:RefreshMini() end)
    panel.pvp = check("Hide in battlegrounds and arenas",
        function() return mini().pvpHide ~= false end,
        function(on) mini().pvpHide = on; if ns.CheckMiniZone then ns:CheckMiniZone() end end)
    panel.hover = check("Hover mode",
        function() return mini().hoverMode end,
        function(on) ns:SetMiniHoverMode(on) end,
        "Hides the tracker's header and background so only the item list shows. They come back while "
        .. "the mouse is over the tracker or the main window is open. Also: /gg mini hover")
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

    section("Gear Acquired pop-up", "when you get recommended or favorite gear", "toast")
    local toast = function() return GearGuideDB.toast end
    panel.toastShown = check("Show the pop-up",
        function() return toast().shown ~= false end,
        function(on) toast().shown = on end,
        "Pops up when an item GearGuide currently recommends for you, or one you favorited, lands in your bags. "
        .. "Left-click it to open the item, right-click to dismiss.")
    panel.toastLocked = check("Lock position and size",
        function() return toast().locked end,
        function(on) toast().locked = on; ns:ApplyToastLayout() end,
        "Unlocked: drag the pop-up to move it, drag its bottom-right corner to make it wider or narrower.")
    panel.toastScale = stepper("Scale", function() return tonumber(toast().scale) or 1 end,
        function(v) toast().scale = math.floor(v * 100 + 0.5) / 100; ns:ApplyToastLayout() end,
        0.6, 1.6, 0.05, pct)
    local preview = Skin:Button(pg.body, "Show preview")
    place(preview, INDENT)
    preview:SetScript("OnClick", function() ns:PreviewGearToast() end)
    tooltip(preview, "Show preview", "Shows a sample pop-up that stays until you click it, so you can place "
        .. "and size it (unlock first).")
    local resetPos = Skin:Button(pg.body, "Reset position")
    resetPos:SetPoint("LEFT", preview, "RIGHT", Skin.GAP, 0)
    resetPos:SetScript("OnClick", function()
        toast().point, toast().w, toast().scale = nil, 300, 1
        ns:ApplyToastLayout(); panel:Refresh()
    end)
    finishPage()

    ---------------------------------------------------------------------------
    -- Page 3: Custom stat weights
    ---------------------------------------------------------------------------
    pg = newPage("weights", "Stat Weights")

    section("Custom stat weights", "Spec: Custom in the window header", "custom")
    local custom = function() return GearGuideCharDB.custom end
    panel.customOn = check("Use my own stat weights",
        function() return ns:IsCustomWeights() end,
        function(on)
            if on then ns:SetPlayerSpec("CUSTOM")
            else ns:SetPlayerSpec(custom() and custom().base or "AUTO") end
        end,
        "Scores the Recommended tab, the mini tracker and tooltips with the values below instead of the "
        .. "researched ones for your spec.")
    local specList = {}
    for _, s in ipairs(ns:GetSpecs()) do specList[#specList + 1] = { value = s.key, text = s.label, icon = s.icon } end
    panel.customBase = dropdown("Based on spec", specList,
        function() return custom() and custom().base or ns:GetPlayerSpec() end,
        function(v) ns:SetCustomBase(v) end,
        "Decides your role and how you hold weapons (two-hander, dual wield, shield...). Reset copies this "
        .. "spec's researched weights.")
    local reset = Skin:Button(pg.body, "Reset to spec values")
    reset:SetPoint("LEFT", panel.customBase, "RIGHT", Skin.GAP, 0)
    reset:SetScript("OnClick", function() ns:ResetCustomWeights(); panel:Refresh() end)
    tooltip(reset, "Reset to spec values", "Replaces every custom weight with the researched value of the spec "
        .. "chosen on the left.")

    section("Weights", "value of one point of each stat")
    hintText("Percent stats like Hit and Crit: per 1%. 0 or empty ignores the stat; negative values avoid it. "
        .. "Enter or click away to apply.")

    local fmtWeight = function(v)
        if not v or v == 0 then return "" end
        local t = string.format("%.3f", v):gsub("0+$", ""):gsub("%.$", "")
        return t
    end
    local stats = {}
    for _, k in ipairs(ns.STAT_ORDER or {}) do stats[#stats + 1] = k end
    if (ns.GetPlayerClass and ns:GetPlayerClass()) == "HUNTER" then table.insert(stats, 2, "RDPS") end
    panel.weights = {}
    -- Two columns, filled top to bottom: the first half of the list on the left.
    local rows = math.ceil(#stats / 2)
    local top = pg.y
    for i, stat in ipairs(stats) do
        local name = stat == "RDPS" and "Ranged weapon DPS"
            or (ns.STAT_NAMES and ns.STAT_NAMES[stat]) or stat
        if stat == "DPS" then name = "Weapon DPS" end
        local col, line = math.floor((i - 1) / rows), (i - 1) % rows
        local row = labelRow(name, nil, WEIGHT_LABEL_W)
        row:SetPoint("TOPLEFT", pg.body, "TOPLEFT", INDENT + col * WEIGHT_COL_W, -(top + line * ROW_H))
        local eb = Skin:EditBox(pg.body, 70)
        eb:SetPoint("LEFT", row, "RIGHT", 0, 0)
        eb:SetPlaceholder("0")
        local function apply(self)
            local v = ns.ParseWeight(self:GetText())
            if v then ns:SetCustomWeight(stat, v) end
            self:SetText(fmtWeight(custom() and custom().weights[stat]))
        end
        -- Enter leaves the box (Skin:EditBox), and leaving applies: one apply, not two re-reading the rounded text.
        eb:HookScript("OnEditFocusLost", apply)
        local c = { box = eb }
        function c:Sync()
            if not eb:HasFocus() then eb:SetText(fmtWeight(custom() and custom().weights[stat])) end
            if ns:IsCustomWeights() then eb:Enable(); eb:SetAlpha(1) else eb:Disable(); eb:SetAlpha(0.45) end
        end
        controls[#controls + 1] = c
        panel.weights[stat] = eb
    end
    pg.y = top + rows * ROW_H
    controls[#controls + 1] = { Sync = function()
        if ns:IsCustomWeights() then reset:Enable(); panel.customBase:Enable()
        else reset:Disable(); panel.customBase:Disable() end
    end }
    finishPage()

    ---------------------------------------------------------------------------
    function panel:Refresh()
        for _, c in ipairs(controls) do c:Sync() end
        if current then pages[current].updateThumb() end
    end

    -- Shows one sub tab (remembered for next time).
    function panel:ShowPage(key)
        if not pages[key] then key = order[1] end
        current = key
        for k, p in pairs(pages) do
            p.frame:SetShown(k == key)
            p.tab:SetActive(k == key)
        end
        if GearGuideDB then GearGuideDB.settingsPage = key end
        pages[key].updateThumb()
    end

    -- Opens the section's sub tab and puts its title at the top of the visible page.
    function panel:ScrollToSection(key)
        local page = pages[sectionPage[key] or ""]
        if not page then return end
        self:ShowPage(page.key)
        page.scrollTo(page.sectionY[key] - 4)
    end

    panel:ShowPage(GearGuideDB and GearGuideDB.settingsPage)
    panel:HookScript("OnShow", function() panel:Refresh() end)
    return panel
end
