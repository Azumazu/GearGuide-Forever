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

-- Appearance: GearGuideDB.skin field = value, applied live. A new border style starts at its own size.
function ns:SetSkin(field, value)
    local cfg = GearGuideDB.skin
    if field == "border" and cfg.border ~= value then cfg.borderSize = nil end
    cfg[field] = value
    self.Skin:ApplyTheme()
end

-- A hand-picked color over the theme ({r, g, b}), or nil to use the theme's again.
function ns:SetSkinColor(key, rgb)
    local cfg = GearGuideDB.skin
    if type(cfg.colors) ~= "table" then cfg.colors = {} end
    cfg.colors[key] = rgb
    self.Skin:ApplyTheme()
end

-- Back to the theme's colors (the theme, border and text size stay).
function ns:ResetSkinColors()
    GearGuideDB.skin.colors = {}
    self.Skin:ApplyTheme()
end

-- The game's color picker (newer clients: SetupColorPickerAndShow; older: fields + ShowUIPanel).
-- onChange(r, g, b) runs while dragging, and with the starting color on Cancel.
local function pickColor(r, g, b, onChange)
    local picker = ColorPickerFrame
    if not picker then return end
    local function changed() onChange(picker:GetColorRGB()) end
    local function cancel() onChange(r, g, b) end
    if picker.SetupColorPickerAndShow then
        picker:SetupColorPickerAndShow({ r = r, g = g, b = b, hasOpacity = false,
            swatchFunc = changed, cancelFunc = cancel })
    else
        picker.hasOpacity, picker.previousValues = false, { r = r, g = g, b = b }
        picker.func, picker.opacityFunc, picker.cancelFunc = changed, nil, cancel
        picker:SetColorRGB(r, g, b)
        if ShowUIPanel then ShowUIPanel(picker) else picker:Show() end
    end
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
        local idle = { Skin.C.accent[1], Skin.C.accent[2], Skin.C.accent[3], 0.8 }
        thumb:SetColorTexture(idle[1], idle[2], idle[3], idle[4])
        local grip
        function page.updateThumb()
            local viewH, total = scroll:GetHeight() or 0, body:GetHeight() or 0
            if total <= viewH + 1 or viewH <= 0 then thumb:Hide(); grip:Sync() return end
            local h = math.max(16, viewH * viewH / total)
            local y = (viewH - h) * (scroll:GetVerticalScroll() or 0) / (total - viewH)
            thumb:ClearAllPoints()
            thumb:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -y)
            thumb:SetHeight(h)
            thumb:Show()
            grip:Sync()
        end
        local function maxScroll() return math.max(0, (body:GetHeight() or 0) - (scroll:GetHeight() or 0)) end
        function page.scrollTo(top)
            scroll:SetVerticalScroll(math.max(0, math.min(maxScroll(), top)))
            page.updateThumb()
        end
        -- Click or drag the scroll bar.
        grip = Skin:ScrollGrip(frame, thumb, {
            idle = idle,
            get = function() local m = maxScroll() return m > 0 and (scroll:GetVerticalScroll() or 0) / m or 0 end,
            set = function(f) page.scrollTo(f * maxScroll()) end,
            wheel = function(delta) page.scrollTo((scroll:GetVerticalScroll() or 0) - delta * ROW_H * 2) end,
        })
        grip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        grip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
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
    panel.sharing = check("Share item sources with other GearGuide users",
        function() return ns:IsSharingEnabled() end,
        function(on) ns:SetSharing(on) end,
        "Shares the sources you discover (which creature, quest or vendor gives an item) with GearGuide users "
        .. "on your realm, in your guild and in your group, and receives theirs. Invisible, no chat messages, "
        .. "no character data (never your inventory, gear, level or gold).")
    panel.unknown = check("Show items not discovered yet",
        function() return GearGuideDB.showUnknown end,
        function(on) ns:SetShowUnknown(on) end,
        "Items nobody has found a source for yet. Favorites always show.")
    panel.scale = stepper("Window scale", function() return tonumber(GearGuideDB.window.scale) or 1 end,
        function(v) ns:SetWindowScale(v) end, 0.7, 1.5, 0.05, pct)

    section("Appearance", "colors and window border", "appearance")
    local skin = function() return GearGuideDB.skin end
    -- A small square of the theme's accent color before its name.
    local function swatch(c)
        return string.format("|TInterface\\Buttons\\WHITE8x8:10:10:0:0:8:8:0:8:0:8:%d:%d:%d|t ",
            math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
    end
    local themeItems = {}
    for _, t in ipairs(Skin.THEMES) do
        themeItems[#themeItems + 1] = { value = t.value, text = swatch(t.colors.accent or Skin.C.accent) .. t.text }
    end
    themeItems[1].text = swatch({ 0.863, 0.655, 0.498 }) .. Skin.THEMES[1].text  -- before any accent change
    panel.theme = dropdown("Color theme", themeItems,
        function() return skin().theme end,
        function(v) ns:SetSkin("theme", v) end,
        "Window background, outlines and accent color. Colors you pick below replace the theme's.")
    -- One row per pickable color: [label] [swatch] [Theme]. The swatch opens the game's color picker;
    -- Theme drops the hand-picked color (enabled only while there is one).
    panel.colors = {}
    local function colorRow(slot, text)
        local row = label(text or slot.text, slot.tip .. " Click the square to pick your own color; Theme "
            .. "goes back to the color theme's.")
        local sw = Skin:Button(pg.body, "", 22, 22)
        sw:SetPoint("LEFT", row, "RIGHT", 0, 0)
        local fill = sw:CreateTexture(nil, "ARTWORK")
        fill:SetPoint("TOPLEFT", 3, -3)
        fill:SetPoint("BOTTOMRIGHT", -3, 3)
        local reset = Skin:Button(pg.body, "Theme")
        reset:SetPoint("LEFT", sw, "RIGHT", 6, 0)
        sw:SetScript("OnClick", function()
            local c = Skin.C[slot.key]
            pickColor(c[1], c[2], c[3], function(r, g, b)
                ns:SetSkinColor(slot.key, { r, g, b })
                fill:SetColorTexture(r, g, b, 1)
                if reset.Enable then reset:Enable() end
            end)
        end)
        reset:SetScript("OnClick", function() ns:SetSkinColor(slot.key, nil); panel:Refresh() end)
        local c = { swatch = sw, reset = reset }
        function c:Sync()
            local a = Skin.C[slot.key]
            fill:SetColorTexture(a[1], a[2], a[3], 1)
            if Skin:CustomColor(slot.key) then reset:Enable() else reset:Disable() end
        end
        controls[#controls + 1] = c
        panel.colors[slot.key] = c
        return c
    end
    local edgeSlot
    for _, slot in ipairs(Skin.CUSTOM_COLORS) do
        if slot.key == "edge" then edgeSlot = slot else colorRow(slot) end
    end
    panel.border = dropdown("Window border", Skin.BORDERS,
        function() return Skin:BorderStyle().value end,
        function(v) ns:SetSkin("border", v) end,
        "The border around the main window and the mini tracker.")
    panel.borderSize = stepper("Border size", function() return Skin:BorderStyle().size or 1 end,
        function(v) ns:SetSkin("borderSize", v) end, Skin.BORDER_SIZE_MIN, Skin.BORDER_SIZE_MAX, 1,
        function(v)
            local s = Skin:BorderStyle()
            if s.value == "none" then return "-" end
            return (s.edge or v) .. " px"
        end,
        "How thick the window border is. Textured borders grow with it too. A new border style starts at "
        .. "its own size.")
    if edgeSlot then colorRow(edgeSlot, "Border color") end
    do
        local reset = Skin:Button(pg.body, "Use the theme's colors")
        place(reset, INDENT, Skin.CONTROL_H + 6)
        reset:SetScript("OnClick", function() ns:ResetSkinColors(); panel:Refresh() end)
        tooltip(reset, "Use the theme's colors", "Drops every color you picked by hand. The theme, border "
            .. "style and size stay.")
        local c = {}
        function c:Sync()
            local any = false
            for _, slot in ipairs(Skin.CUSTOM_COLORS) do if Skin:CustomColor(slot.key) then any = true end end
            if any then reset:Enable() else reset:Disable() end
        end
        controls[#controls + 1] = c
        panel.resetColors = reset
    end
    panel.colorblind = check("Colorblind-friendly upgrade colors",
        function() return skin().colorblind end,
        function(on) ns:SetSkin("colorblind", on and true or false); ns:InvalidateBadges(); ns:RequestRefresh() end,
        "Upgrade numbers in blue and downgrades in orange, instead of green and red: on item icons, "
        .. "tooltips, creature tooltips, the lists and the mini tracker.")
    panel.textScale = stepper("Text size", function() return tonumber(skin().textScale) or 1 end,
        function(v) skin().textScale = math.floor(v * 100 + 0.5) / 100 end, 0.85, 1.25, 0.05, pct,
        "The size of GearGuide's own text (windows, mini tracker, upgrade numbers). Takes effect after a reload.")
    do
        local hint = hintText("Backgrounds and borders change right away; text size, tabs and highlights after a reload.")
        local reload = Skin:Button(pg.body, "Reload now")
        reload:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -2)
        reload:SetScript("OnClick", function() if ReloadUI then ReloadUI() end end)
        pg.y = pg.y + Skin.CONTROL_H + 6
    end

    section("In the game", "tooltips, item icons, loot")
    panel.iconBadges = check("Upgrade numbers on items",
        function() return GearGuideDB.iconBadges ~= false end,
        function(on) ns.Badges.SetEnabled(on) end,
        "On item icons in your bags, the bank, merchants, loot and quest rewards (in any quest window), "
        .. "and in item tooltips: how the item scores against what you wear, green when it's better, "
        .. "red when it's worse.")
    panel.lootRolls = check("Loot roll help",
        function() return GearGuideDB.lootRollHelp ~= false end,
        function(on) GearGuideDB.lootRollHelp = on and true or false end,
        "On group loot rolls, shows what the item is worth to you, and in chat who in your party it's an "
        .. "upgrade for. Party members' gear is read with the game's Inspect when they're near you, so they "
        .. "don't need GearGuide.")
    panel.levelUpGear = check("Upgrades on level up",
        function() return GearGuideDB.levelUpGear ~= false end,
        function(on) GearGuideDB.levelUpGear = on and true or false end,
        "When you level up, lists the gear in your bags and bank that you can wear now and that beats what "
        .. "you have on. The bank is remembered each time you open it.")
    panel.announceDrops = check("Announce new drop locations",
        function() return GearGuideDB.announceDrops ~= false end,
        function(on) GearGuideDB.announceDrops = on and true or false end,
        "When you loot gear from a creature that isn't listed as a source for it yet, shows "
        .. "\"New drop location discovered for [item]\" on screen and in chat.")

    section("Creature tooltips", "the gear a creature drops", "creatureTips")
    local tipDrops = function() return GearGuideDB.tipDrops end
    panel.creatureTips = check("Show gear drops on creature tooltips",
        function() return GearGuideDB.creatureTips end,
        function(on) GearGuideDB.creatureTips = on and true or false end,
        "Mouse over a creature to see the gear it drops, with the drop chance and the score gain over what "
        .. "you have equipped.")
    panel.tipShow = dropdown("Which drops", ns.TIP_DROP_SHOW,
        function() return tipDrops().show end,
        function(v) tipDrops().show = v end,
        "Upgrades and favorites: the items the Recommended list picks for you. Gear your class can use: "
        .. "every drop you could wear. All gear: everything. Favorites always show.")
    panel.tipQuality = dropdown("Lowest quality", QUALITY_ITEMS,
        function() return tonumber(tipDrops().minQuality) or 2 end,
        function(v) tipDrops().minQuality = v end,
        "Drops below this quality are left off creature tooltips.")
    panel.tipBracket = dropdown("Item level bracket", ns.TIP_DROP_BRACKETS,
        function() return tipDrops().bracket end,
        function(v) tipDrops().bracket = v end,
        "Only drops whose required level is in this bracket. Your recommendation range: the levels below and "
        .. "above yours set under Recommendations.")
    panel.tipWorld = check("Include BoE world drops",
        function() return tipDrops().world ~= false end,
        function(on) tipDrops().world = on and true or false end,
        "Bind-on-equip gear that any creature of the right level can drop, usually at well under 1%. "
        .. "Listed after the creature's own loot.")

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

    -- Pawn import: a paste box over the page.
    local pawnBtn = Skin:Button(pg.body, "Import Pawn scale...")
    place(pawnBtn, INDENT)
    tooltip(pawnBtn, "Import Pawn scale", "Paste a Pawn scale string, like ( Pawn: v1: \"Fury\": Strength=2.2, "
        .. "Agility=1.4, ... ). It replaces your custom weights and switches to them. Rating stats (CritRating...) "
        .. "are converted to GearGuide's per 1% values.")
    local pawn = Skin:Panel(panel, "menu", "edge")
    pawn:SetSize(420, 112)
    pawn:SetPoint("TOP", panel, "TOP", 0, -70)
    pawn:SetFrameStrata("DIALOG")
    pawn:EnableMouse(true)
    pawn:Hide()
    local pawnTitle = Skin:Text(pawn, Skin.SIZE.header, "accent")
    pawnTitle:SetPoint("TOPLEFT", 10, -9)
    pawnTitle:SetText("Import a Pawn scale")
    local pawnHint = Skin:Text(pawn, Skin.SIZE.small, "textDim")
    pawnHint:SetPoint("TOPLEFT", pawnTitle, "BOTTOMLEFT", 0, -4)
    pawnHint:SetPoint("RIGHT", pawn, "RIGHT", -10, 0)
    pawnHint:SetJustifyH("LEFT")
    pawnHint:SetText("Paste the scale (Ctrl+V), then Import. It replaces your custom stat weights.")
    local pawnBox = Skin:EditBox(pawn, 400)
    pawnBox:SetPoint("TOPLEFT", 10, -50)
    pawnBox:SetPoint("RIGHT", pawn, "RIGHT", -10, 0)
    local pawnClose = Skin:Button(pawn, "Close", 70, Skin.CONTROL_H)
    pawnClose:SetPoint("BOTTOMRIGHT", -10, 8)
    pawnClose:SetScript("OnClick", function() pawn:Hide() end)
    local pawnGo = Skin:Button(pawn, "Import", 70, Skin.CONTROL_H)
    pawnGo:SetPoint("RIGHT", pawnClose, "LEFT", -6, 0)
    local function importPawn()
        local ok, msg = ns:ImportPawnScale(pawnBox:GetText())
        ns.Print(msg)
        if ok then pawn:Hide(); panel:Refresh() end
    end
    pawnGo:SetScript("OnClick", importPawn)
    pawnBox:HookScript("OnEnterPressed", importPawn)
    pawnBox:HookScript("OnEscapePressed", function() pawn:Hide() end)
    pawnBtn:SetScript("OnClick", function()
        pawnBox:SetText("")
        pawn:Show()
        pawnBox:SetFocus()
    end)
    panel:HookScript("OnHide", function() pawn:Hide() end)
    panel.pawnImport, panel.pawnBox, panel.pawnGo = pawnBtn, pawnBox, pawnGo  -- (tests)

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
