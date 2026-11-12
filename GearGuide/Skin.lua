local _, ns = ...

-- Flat, dark, compact skin used by every GearGuide frame.
-- Look: warm near-black translucent panels, 1px faint borders, one warm accent color,
-- condensed font, dense rows. No Blizzard visual templates (only BackdropTemplate).

local Skin = {}
ns.Skin = Skin

local WHITE = "Interface\\Buttons\\WHITE8x8"

---------------------------------------------------------------------------
-- Palette ({r, g, b, a}, 0-1)
---------------------------------------------------------------------------
Skin.C = {
    bg        = { 0.035, 0.031, 0.027, 0.95 }, -- window background (warm near-black)
    panel     = { 0.062, 0.056, 0.050, 0.85 }, -- inset panels, edit boxes
    header    = { 0.058, 0.051, 0.045, 1.00 }, -- window title bar
    border    = { 1.000, 1.000, 1.000, 0.09 }, -- 1px hairline
    accent    = { 0.863, 0.655, 0.498, 1.00 }, -- warm copper (#DCA77F)
    text      = { 0.925, 0.910, 0.890, 1.00 },
    textDim   = { 0.580, 0.560, 0.530, 1.00 },
    hover     = { 1.000, 1.000, 1.000, 0.06 },
    selected  = { 0.863, 0.655, 0.498, 0.22 },
    done      = { 0.380, 0.800, 0.460, 1.00 },
    partial   = { 0.950, 0.760, 0.320, 1.00 },
    upgrade   = { 0.330, 0.850, 0.420, 1.00 },
    downgrade = { 0.920, 0.360, 0.320, 1.00 },
    -- extras (not part of the contract, used internally)
    button       = { 0.100, 0.089, 0.078, 0.95 },
    borderStrong = { 1.000, 1.000, 1.000, 0.22 },
    stripe       = { 1.000, 1.000, 1.000, 0.025 },
    track        = { 1.000, 1.000, 1.000, 0.05 },
    thumb        = { 0.580, 0.560, 0.530, 0.60 },
    menu         = { 0.055, 0.049, 0.043, 0.98 }, -- dropdown menus (nearly opaque)
    -- bar rows (EllesmereUI-style lists): near-black fill, slightly lighter at the left edge
    listBg       = { 0.000, 0.000, 0.000, 0.35 }, -- behind bar rows (shows in the 2px gaps)
    row          = { 0.043, 0.039, 0.035, 0.92 }, -- #0B0A09
    rowLight     = { 0.090, 0.082, 0.074, 0.92 },
    rowHeader    = { 0.060, 0.049, 0.039, 0.95 }, -- slot headers: warm accent-tinted
    rowHeaderLight = { 0.150, 0.118, 0.088, 0.95 },
    rowHover     = { 1.000, 1.000, 1.000, 0.05 },
}
local C = Skin.C

-- Arial Narrow is the client font closest to a modern condensed UI font.
-- Locales whose glyphs it lacks fall back to the client's standard font.
do
    local locale = GetLocale and GetLocale() or "enUS"
    if locale == "koKR" or locale == "zhCN" or locale == "zhTW" then
        Skin.FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
    else
        Skin.FONT = "Fonts\\ARIALN.TTF"
    end
end
Skin.SIZE = { small = 11, normal = 12, header = 13 }

local function col(key)
    if type(key) == "table" then return key end
    return C[key] or C.text
end
Skin.Color = function(_, key) return col(key) end

local function setTex(tex, key, alphaMul)
    local c = col(key)
    tex:SetColorTexture(c[1], c[2], c[3], (c[4] or 1) * (alphaMul or 1))
end

local function setTextColor(fs, key, alphaMul)
    local c = col(key)
    fs:SetTextColor(c[1], c[2], c[3], (c[4] or 1) * (alphaMul or 1))
end

function Skin:Hex(key)
    local c = col(key)
    return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255 + 0.5),
        math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end

---------------------------------------------------------------------------
-- Backdrops and text
---------------------------------------------------------------------------
local BACKDROP = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }

function Skin:SetBackdrop(frame, bgKey, borderKey)
    local bg, border = col(bgKey or "bg"), col(borderKey or "border")
    if frame.SetBackdrop then
        frame:SetBackdrop(BACKDROP)
        frame:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
        frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
        return
    end
    -- Fallback for frames created without BackdropTemplate: plain textures.
    local t = frame.ggFlat
    if not t then
        t = { bg = frame:CreateTexture(nil, "BACKGROUND", nil, -8) }
        t.bg:SetAllPoints()
        for i = 1, 4 do t[i] = frame:CreateTexture(nil, "BORDER") end
        t[1]:SetPoint("TOPLEFT"); t[1]:SetPoint("TOPRIGHT"); t[1]:SetHeight(1)
        t[2]:SetPoint("BOTTOMLEFT"); t[2]:SetPoint("BOTTOMRIGHT"); t[2]:SetHeight(1)
        t[3]:SetPoint("TOPLEFT"); t[3]:SetPoint("BOTTOMLEFT"); t[3]:SetWidth(1)
        t[4]:SetPoint("TOPRIGHT"); t[4]:SetPoint("BOTTOMRIGHT"); t[4]:SetWidth(1)
        frame.ggFlat = t
    end
    setTex(t.bg, bg)
    for i = 1, 4 do setTex(t[i], border) end
end

-- Border-only color change (used for hover/focus states).
local function setBorder(frame, key)
    local c = col(key)
    if frame.SetBackdropBorderColor then
        frame:SetBackdropBorderColor(c[1], c[2], c[3], c[4] or 1)
    elseif frame.ggFlat then
        for i = 1, 4 do setTex(frame.ggFlat[i], c) end
    end
end
Skin.SetBorderColor = function(_, frame, key) setBorder(frame, key) end

local function applyFont(obj, size, flags)
    obj:SetFont(Skin.FONT, size or Skin.SIZE.normal, flags or "")
    if not obj:GetFont() and STANDARD_TEXT_FONT then
        obj:SetFont(STANDARD_TEXT_FONT, size or Skin.SIZE.normal, flags or "")
    end
    if not flags or flags == "" then
        obj:SetShadowColor(0, 0, 0, 0.85)
        obj:SetShadowOffset(1, -1)
    else
        obj:SetShadowOffset(0, 0)
    end
end

function Skin:Text(parent, size, colorKey, flags)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    applyFont(fs, size, flags)
    setTextColor(fs, colorKey or "text")
    fs:SetJustifyH("LEFT")
    return fs
end

-- Extra: plain skinned container frame.
function Skin:Panel(parent, bgKey, borderKey)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    self:SetBackdrop(f, bgKey or "panel", borderKey or "border")
    return f
end

-- Extra: 1px horizontal line.
function Skin:Divider(parent, colorKey)
    local t = parent:CreateTexture(nil, "ARTWORK")
    setTex(t, colorKey or "border")
    t:SetHeight(1)
    return t
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------
local function isEnabled(b)
    local e = b:IsEnabled()
    return e and e ~= 0
end

local function updateButton(b)
    if not isEnabled(b) then
        setTextColor(b.text, "textDim", 0.5)
        b.activeBar:Hide()
    elseif b.active then
        setTextColor(b.text, "accent")
        b.activeBar:Show()
    else
        setTextColor(b.text, "text")
        b.activeBar:Hide()
    end
end

function Skin:Button(parent, text, width, height)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(width or 80, height or 20)
    self:SetBackdrop(b, "button", "border")

    -- HIGHLIGHT layer textures show automatically while the mouse is over the button,
    -- so hover works even if the caller replaces OnEnter/OnLeave.
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 1, -1)
    hl:SetPoint("BOTTOMRIGHT", -1, 1)
    setTex(hl, "hover")
    b.highlight = hl

    local bar = b:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("BOTTOMLEFT", 1, 1)
    bar:SetPoint("BOTTOMRIGHT", -1, 1)
    bar:SetHeight(2)
    setTex(bar, "accent")
    bar:Hide()
    b.activeBar = bar

    local fs = self:Text(b, Skin.SIZE.normal, "text")
    fs:SetPoint("LEFT", 4, 0)
    fs:SetPoint("RIGHT", -4, 0)
    fs:SetJustifyH("CENTER")
    fs:SetWordWrap(false)
    b.text = fs

    function b:SetText(t) self.text:SetText(t or "") end
    function b:GetText() return self.text:GetText() end
    function b:SetActive(on)
        self.active = on and true or false
        updateButton(self)
    end
    function b:IsActive() return self.active end

    -- Small press feedback: nudge the label while held.
    b:SetScript("OnMouseDown", function(self)
        if isEnabled(self) then self.text:SetPoint("LEFT", 5, -1); self.text:SetPoint("RIGHT", -3, -1) end
    end)
    b:SetScript("OnMouseUp", function(self)
        self.text:SetPoint("LEFT", 4, 0); self.text:SetPoint("RIGHT", -4, 0)
    end)
    b:SetScript("OnEnable", updateButton)
    b:SetScript("OnDisable", updateButton)

    b:SetText(text)
    updateButton(b)
    return b
end

function Skin:IconButton(parent, glyph, size)
    size = size or 16
    local b = self:Button(parent, glyph, size, size)
    applyFont(b.text, math.max(9, math.floor(size * 0.75 + 0.5)))
    b.text:ClearAllPoints()
    b.text:SetPoint("CENTER", 0, 1)
    b:SetScript("OnMouseDown", function(self)
        if isEnabled(self) then self.text:SetPoint("CENTER", 1, 0) end
    end)
    b:SetScript("OnMouseUp", function(self) self.text:SetPoint("CENTER", 0, 1) end)
    return b
end

---------------------------------------------------------------------------
-- Script chaining: lets a widget keep its built-in behaviour for some scripts
-- even when the caller later calls SetScript for the same script.
---------------------------------------------------------------------------
local function chainScripts(obj, internal)
    local rawSetScript = obj.SetScript
    function obj:SetScript(script, fn)
        local base = internal[script]
        if base and fn then
            rawSetScript(self, script, function(...) base(...); return fn(...) end)
        elseif base then
            rawSetScript(self, script, base)
        else
            rawSetScript(self, script, fn)
        end
    end
    for script in pairs(internal) do obj:SetScript(script, nil) end
end

---------------------------------------------------------------------------
-- Edit box
---------------------------------------------------------------------------
function Skin:EditBox(parent, width, numeric)
    local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    eb:SetSize(width or 120, 20)
    eb:SetAutoFocus(false)
    eb:SetMultiLine(false)
    applyFont(eb, Skin.SIZE.normal)
    setTextColor(eb, "text")
    eb:SetTextInsets(5, 5, 0, 0)
    if numeric then eb:SetNumeric(true) end
    self:SetBackdrop(eb, "panel", "border")

    local ph = self:Text(eb, Skin.SIZE.normal, "textDim")
    ph:SetPoint("LEFT", 6, 0)
    ph:SetPoint("RIGHT", -5, 0)
    ph:SetWordWrap(false)
    ph:Hide()
    eb.placeholder = ph

    local function update(self)
        local empty = (self:GetText() or "") == ""
        ph:SetShown(empty and not self:HasFocus() and (ph:GetText() or "") ~= "")
        setBorder(self, self:HasFocus() and "borderStrong" or "border")
    end
    local function unfocus(self) self:ClearFocus() end

    chainScripts(eb, {
        OnTextChanged = update,
        OnEditFocusGained = update,
        OnEditFocusLost = update,
        OnEscapePressed = unfocus,
        OnEnterPressed = unfocus,
    })

    function eb:SetPlaceholder(t)
        ph:SetText(t or "")
        update(self)
    end
    return eb
end

---------------------------------------------------------------------------
-- Checkbox
---------------------------------------------------------------------------
function Skin:Checkbox(parent, label)
    local cb = CreateFrame("Button", nil, parent)
    cb:SetHeight(16)

    local box = CreateFrame("Frame", nil, cb, "BackdropTemplate")
    box:SetSize(14, 14)
    box:SetPoint("LEFT", 0, 0)
    self:SetBackdrop(box, "panel", "borderStrong")
    cb.box = box

    local mark = box:CreateTexture(nil, "ARTWORK")
    mark:SetPoint("TOPLEFT", 3, -3)
    mark:SetPoint("BOTTOMRIGHT", -3, 3)
    setTex(mark, "accent")
    mark:Hide()
    cb.mark = mark

    local hl = cb:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", box, 1, -1)
    hl:SetPoint("BOTTOMRIGHT", box, -1, 1)
    setTex(hl, "hover")

    local fs = self:Text(cb, Skin.SIZE.normal, "text")
    fs:SetPoint("LEFT", box, "RIGHT", 5, 0)
    fs:SetWordWrap(false)
    cb.text = fs

    local function resize()
        cb:SetWidth(14 + 5 + math.ceil(fs:GetStringWidth() or 0) + 2)
    end
    function cb:SetText(t) fs:SetText(t or ""); resize() end
    function cb:GetText() return fs:GetText() end
    function cb:GetChecked() return self.checked == true end
    function cb:SetChecked(on)
        self.checked = on and true or false
        mark:SetShown(self.checked)
    end

    local function refreshEnabled(self)
        local on = isEnabled(self)
        setTextColor(fs, on and "text" or "textDim", on and 1 or 0.6)
        mark:SetAlpha(on and 1 or 0.4)
    end

    chainScripts(cb, {
        OnClick = function(self, ...)
            self:SetChecked(not self.checked)
            if self.onToggle then self.onToggle(self, self.checked) end
        end,
        OnEnable = refreshEnabled,
        OnDisable = refreshEnabled,
    })

    cb:SetChecked(false)
    cb:SetText(label)
    return cb
end

---------------------------------------------------------------------------
-- Resize grip
---------------------------------------------------------------------------
local function setBounds(frame, minW, minH, maxW, maxH)
    if frame.SetResizeBounds then
        if maxW and maxH then
            frame:SetResizeBounds(minW, minH, maxW, maxH)
        else
            frame:SetResizeBounds(minW, minH)
        end
    else
        if frame.SetMinResize then frame:SetMinResize(minW, minH) end
        if frame.SetMaxResize and maxW and maxH then frame:SetMaxResize(maxW, maxH) end
    end
end

function Skin:ResizeGrip(frame, minW, minH, maxW, maxH, onResized)
    minW, minH = minW or 100, minH or 60
    frame:SetResizable(true)
    setBounds(frame, minW, minH, maxW, maxH)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(11, 11)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetFrameLevel(frame:GetFrameLevel() + 10)

    -- Triangle of six 2px dots in the corner.
    grip.dots = {}
    local spots = { {0, 0}, {3, 0}, {6, 0}, {0, 3}, {3, 3}, {0, 6} }
    for i, p in ipairs(spots) do
        local d = grip:CreateTexture(nil, "OVERLAY")
        d:SetSize(2, 2)
        d:SetPoint("BOTTOMRIGHT", -1 - p[1], 1 + p[2])
        setTex(d, "textDim")
        grip.dots[i] = d
    end
    local function tint(key) for _, d in ipairs(grip.dots) do setTex(d, key) end end

    local function stop()
        if not grip.sizing then return end
        grip.sizing = false
        frame:StopMovingOrSizing()
        -- Manual clamp for clients without resize bounds.
        local w, h = frame:GetWidth(), frame:GetHeight()
        local cw = math.max(minW, maxW and math.min(w, maxW) or w)
        local ch = math.max(minH, maxH and math.min(h, maxH) or h)
        if cw ~= w or ch ~= h then frame:SetSize(cw, ch) end
        tint(grip:IsMouseOver() and "accent" or "textDim")
        if onResized then onResized(frame) end
    end

    grip:SetScript("OnEnter", function() tint("accent") end)
    grip:SetScript("OnLeave", function() if not grip.sizing then tint("textDim") end end)
    grip:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        grip.sizing = true
        frame:StartSizing("BOTTOMRIGHT")
    end)
    grip:SetScript("OnMouseUp", stop)
    grip:SetScript("OnHide", stop)
    return grip
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local HEADER_H, PAD = 24, 6

function Skin:CreateWindow(name, opts)
    opts = opts or {}
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(opts.width or 400, opts.height or 300)
    f:SetPoint("CENTER")
    -- MEDIUM like Blizzard's own panels, so the dressing room and bags can still come to the front.
    f:SetFrameStrata(opts.strata or "MEDIUM")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    -- Position is persisted by the addon (onMoved), not by the client's layout cache.
    if f.SetDontSavePosition then f:SetDontSavePosition(true) end
    self:SetBackdrop(f, "bg", "border")

    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    local hbg = header:CreateTexture(nil, "BACKGROUND")
    hbg:SetAllPoints()
    setTex(hbg, "header")
    local line = self:Divider(header, "border")
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    local mark = header:CreateTexture(nil, "ARTWORK")
    mark:SetSize(2, 12)
    mark:SetPoint("LEFT", 7, 0)
    setTex(mark, "accent")
    f.header = header

    local title = self:Text(header, Skin.SIZE.header, "text")
    title:SetPoint("LEFT", mark, "RIGHT", 6, 0)
    title:SetWordWrap(false)
    title:SetText(opts.title or "")
    f.title = title

    local close = self:IconButton(header, "x", 18)
    close:SetPoint("RIGHT", -3, 0)
    close:SetScript("OnClick", function() f:Hide() end)
    f.closeButton = close
    title:SetPoint("RIGHT", close, "LEFT", -6, 0)

    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", header, "BOTTOMLEFT", PAD, -PAD)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1 - PAD, 1 + PAD)
    f.content = content

    header:SetScript("OnDragStart", function()
        f.isDragging = true
        f:StartMoving()
    end)
    header:SetScript("OnDragStop", function()
        if not f.isDragging then return end
        f.isDragging = false
        f:StopMovingOrSizing()
        if opts.onMoved then opts.onMoved(f) end
    end)
    f:HookScript("OnHide", function()
        if f.isDragging then
            f.isDragging = false
            f:StopMovingOrSizing()
            if opts.onMoved then opts.onMoved(f) end
        end
    end)

    function f:SetTitle(t) title:SetText(t or "") end

    -- Optional (not in contract): close on Escape.
    if opts.escClose and name and UISpecialFrames then
        table.insert(UISpecialFrames, name)
    end
    return f
end

---------------------------------------------------------------------------
-- Virtual scrolling list
---------------------------------------------------------------------------
local BAR_W, BAR_GAP, THUMB_MIN = 6, 2, 16

function Skin:List(parent, opts)
    opts = opts or {}
    -- rowHeight is the row pitch; rowGap (extra, default 0) leaves that many px between rows.
    -- barRows (extra) decorates rows with Skin:BarRow (selection = accent tint + outline).
    local rowH = opts.rowHeight or 20
    local rowGap = opts.rowGap or 0
    local list = { data = {}, offset = 0, rows = {}, numVisible = 0, opts = opts }

    local frame = CreateFrame("Frame", nil, parent)
    frame:EnableMouseWheel(true)
    if frame.SetClipsChildren then frame:SetClipsChildren(true) end
    list.frame = frame

    -- Scrollbar --------------------------------------------------------
    local track = CreateFrame("Frame", nil, frame)
    track:SetWidth(BAR_W)
    track:SetPoint("TOPRIGHT")
    track:SetPoint("BOTTOMRIGHT")
    track:EnableMouse(true)
    local ttex = track:CreateTexture(nil, "BACKGROUND")
    ttex:SetAllPoints()
    setTex(ttex, "track")
    track:Hide()
    list.scrollBar = track

    local thumb = CreateFrame("Frame", nil, track)
    thumb:SetWidth(BAR_W)
    thumb:EnableMouse(true)
    local thtex = thumb:CreateTexture(nil, "ARTWORK")
    thtex:SetAllPoints()
    setTex(thtex, "thumb")
    list.thumb = thumb

    local barShown = false

    local function maxOffset()
        return math.max(0, #list.data - list.numVisible)
    end

    local function updateThumb()
        if not barShown then return end
        local trackH = track:GetHeight()
        local total = #list.data
        if trackH <= 0 or total <= 0 then return end
        local thumbH = math.max(THUMB_MIN, math.floor(trackH * list.numVisible / total + 0.5))
        thumbH = math.min(thumbH, trackH)
        thumb:SetHeight(thumbH)
        local mo = maxOffset()
        local y = (mo > 0) and (trackH - thumbH) * list.offset / mo or 0
        thumb:ClearAllPoints()
        thumb:SetPoint("TOP", track, "TOP", 0, -math.floor(y + 0.5))
        list.thumbH = thumbH
    end

    local function anchorRow(row, i)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(i - 1) * rowH)
        row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", barShown and -(BAR_W + BAR_GAP) or 0, -(i - 1) * rowH)
    end

    -- Rows ---------------------------------------------------------------
    local function createRow(i)
        local row = CreateFrame("Button", nil, frame)
        row:SetHeight(rowH - rowGap)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.list = list

        if opts.barRows then
            Skin:BarRow(row, rowH - rowGap)
        else
            local stripe = row:CreateTexture(nil, "BACKGROUND", nil, -2)
            stripe:SetAllPoints()
            setTex(stripe, "stripe")
            stripe:Hide()
            row.stripe = stripe

            local sel = row:CreateTexture(nil, "BACKGROUND", nil, -1)
            sel:SetAllPoints()
            setTex(sel, "selected")
            sel:Hide()
            row.selectedTexture = sel

            local selBar = row:CreateTexture(nil, "BORDER")
            selBar:SetPoint("TOPLEFT")
            selBar:SetPoint("BOTTOMLEFT")
            selBar:SetWidth(2)
            setTex(selBar, "accent")
            selBar:Hide()
            row.selectedBar = selBar

            local hl = row:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            setTex(hl, "hover")
            row.highlight = hl
        end

        row:SetScript("OnClick", function(self, button)
            if self.data ~= nil and opts.onClick then opts.onClick(self, self.data, button) end
        end)
        row:SetScript("OnEnter", function(self)
            self.hovered = true
            if self.data ~= nil and opts.onEnter then opts.onEnter(self, self.data) end
        end)
        row:SetScript("OnLeave", function(self)
            self.hovered = false
            if self.data ~= nil and opts.onLeave then opts.onLeave(self, self.data) end
        end)

        list.rows[i] = row
        anchorRow(row, i)
        if opts.createRow then opts.createRow(row) end
        return row
    end

    -- Core refresh ---------------------------------------------------------
    function list:Refresh()
        local data = self.data
        local mo = maxOffset()
        if self.offset > mo then self.offset = mo end
        if self.offset < 0 then self.offset = 0 end

        local needBar = #data > self.numVisible and self.numVisible > 0
        if needBar ~= barShown then
            barShown = needBar
            track:SetShown(needBar)
            for i, row in ipairs(self.rows) do anchorRow(row, i) end
        end
        updateThumb()

        local selectFn = self.selectFn
        for i = 1, math.max(self.numVisible, #self.rows) do
            local row = self.rows[i]
            local index = self.offset + i
            local d = (i <= self.numVisible) and data[index] or nil
            if d == nil then
                if row then
                    if row.hovered and row.data ~= nil and opts.onLeave then opts.onLeave(row, row.data) end
                    row.data, row.index, row.hovered = nil, nil, false
                    row:Hide()
                end
            else
                row = row or createRow(i)
                local old = row.data
                local swapped = row.hovered and row:IsShown() and old ~= d
                if swapped and old ~= nil and opts.onLeave then opts.onLeave(row, old) end
                row.data, row.index = d, index
                local isSel = selectFn and selectFn(d) and true or false
                row.selected = isSel
                if opts.barRows then
                    row:SetBarSelected(isSel)
                else
                    row.selectedTexture:SetShown(isSel)
                    row.selectedBar:SetShown(isSel)
                    row.stripe:SetShown(not isSel and index % 2 == 0)
                end
                if opts.fillRow then opts.fillRow(row, d, index) end
                row:Show()
                if swapped and opts.onEnter then opts.onEnter(row, d) end
            end
        end
    end

    -- Recompute how many rows fit (called on size changes).
    local function layout()
        local h = frame:GetHeight() or 0
        local n = (h > 0) and math.max(1, math.floor(h / rowH + 0.001)) or 0
        list.numVisible = n
        if list.pendingIndex and n > 0 then
            local i = list.pendingIndex
            list.pendingIndex = nil
            list:ScrollToIndex(i)
        else
            list:Refresh()
        end
    end
    frame:SetScript("OnSizeChanged", layout)
    frame:SetScript("OnShow", layout)
    track:SetScript("OnSizeChanged", updateThumb)

    function list:SetOffset(o)
        o = math.floor((o or 0) + 0.5)
        local mo = maxOffset()
        if o > mo then o = mo end
        if o < 0 then o = 0 end
        if o ~= self.offset then
            self.offset = o
            self:Refresh()
        end
    end
    function list:GetOffset() return self.offset end

    function list:SetData(arr)
        self.data = arr or {}
        if self.numVisible == 0 then
            local h = frame:GetHeight() or 0
            if h > 0 then self.numVisible = math.max(1, math.floor(h / rowH + 0.001)) end
        end
        self:Refresh() -- clamps offset when the new data is shorter
    end

    function list:GetData() return self.data end

    function list:SetSelected(fn)
        self.selectFn = fn
        self:Refresh()
    end

    function list:ScrollToIndex(i)
        local n = #self.data
        if n == 0 or not i then return end
        if i < 1 then i = 1 elseif i > n then i = n end
        if self.numVisible == 0 then
            self.pendingIndex = i -- not laid out yet; apply once the frame has a size
            return
        end
        local o = self.offset
        if i <= o then
            o = i - 1
        elseif i > o + self.numVisible then
            o = i - self.numVisible
        end
        self.offset = -1 -- force a refresh even if the offset is unchanged
        self:SetOffset(o)
    end

    function list:ScrollToTop() self:SetOffset(0) end

    -- Input ----------------------------------------------------------------
    frame:SetScript("OnMouseWheel", function(_, delta)
        list:SetOffset(list.offset - delta)
    end)

    local function cursorY()
        local _, y = GetCursorPosition()
        return y / track:GetEffectiveScale()
    end

    thumb:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self.dragging = true
        self.startY = cursorY()
        self.startOffset = list.offset
        setTex(thtex, "accent")
        self:SetScript("OnUpdate", function()
            local range = track:GetHeight() - (list.thumbH or THUMB_MIN)
            local mo = maxOffset()
            if range <= 0 or mo <= 0 then return end
            local dy = self.startY - cursorY()
            list:SetOffset(self.startOffset + dy / range * mo)
        end)
    end)
    local function endDrag(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
        setTex(thtex, self:IsMouseOver() and "accent" or "thumb")
    end
    thumb:SetScript("OnMouseUp", endDrag)
    thumb:SetScript("OnHide", function(self) if self.dragging then endDrag(self) end end)
    thumb:SetScript("OnEnter", function() setTex(thtex, "accent") end)
    thumb:SetScript("OnLeave", function(self) if not self.dragging then setTex(thtex, "thumb") end end)

    -- Clicking the empty track pages up/down.
    track:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        local top = track:GetTop()
        local thumbTop = thumb:GetTop()
        if not top or not thumbTop then return end
        local page = math.max(1, list.numVisible - 1)
        if cursorY() > thumbTop then
            list:SetOffset(list.offset - page)
        else
            list:SetOffset(list.offset + page)
        end
    end)

    return list
end

---------------------------------------------------------------------------
-- Favorite star
---------------------------------------------------------------------------
-- The raid-target "star" icon: shipped by every client since vanilla (chat's {star} uses it),
-- unlike FavoritesIcon/ReputationStar which only some clients have.
Skin.STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"

-- Inline markup for a star in a FontString ("|T...|t").
function Skin:StarMarkup(size)
    return "|T" .. Skin.STAR .. ":" .. (size or 0) .. "|t"
end

-- on = gold star; off = grey, faint (brighter while hovered).
function Skin:StyleStar(tex, on, hover)
    if tex.SetDesaturated then tex:SetDesaturated(not on) end
    if on then
        tex:SetVertexColor(1, 1, 1)
        tex:SetAlpha(1)
    else
        tex:SetVertexColor(0.7, 0.7, 0.7)
        tex:SetAlpha(hover and 0.85 or 0.25)
    end
end

-- Small star toggle. b:SetFavorite(on); b.onToggle = function(b) end is called on click;
-- b.tooltip = {title, line} (optional).
function Skin:StarButton(parent, size)
    size = size or 16
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b:RegisterForClicks("LeftButtonUp")
    local t = b:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints()
    t:SetTexture(Skin.STAR)
    b.tex, b.on, b.hovered, b.onToggle, b.tooltip = t, false, false, false, false

    function b:SetFavorite(on)
        self.on = on and true or false
        Skin:StyleStar(t, self.on, self.hovered)
    end
    b:SetScript("OnEnter", function(self)
        self.hovered = true
        Skin:StyleStar(t, self.on, true)
        if self.tooltip then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine(self.tooltip[1] or "", 1, 1, 1)
            if self.tooltip[2] then GameTooltip:AddLine(self.tooltip[2], 0.7, 0.7, 0.7, true) end
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self.hovered = false
        Skin:StyleStar(t, self.on, false)
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    b:SetScript("OnClick", function(self)
        if self.onToggle then self.onToggle(self) end
    end)
    b:SetFavorite(false)
    return b
end

---------------------------------------------------------------------------
-- Bar rows (EllesmereUI-style list lines; used by the main list and the mini tracker)
---------------------------------------------------------------------------
-- Horizontal gradient (left -> right) with feature detection; flat right color as fallback.
local function setGradientH(tex, leftKey, rightKey)
    local l, r = col(leftKey), col(rightKey)
    tex:SetColorTexture(1, 1, 1, 1)
    if tex.SetGradient and CreateColor then
        local ok = pcall(tex.SetGradient, tex, "HORIZONTAL",
            CreateColor(l[1], l[2], l[3], l[4] or 1), CreateColor(r[1], r[2], r[3], r[4] or 1))
        if ok then return end
    end
    if tex.SetGradientAlpha then
        local ok = pcall(tex.SetGradientAlpha, tex, "HORIZONTAL",
            l[1], l[2], l[3], l[4] or 1, r[1], r[2], r[3], r[4] or 1)
        if ok then return end
    end
    tex:SetColorTexture(r[1], r[2], r[3], r[4] or 1)
end

local BAR_Q_W = 3

-- Decorates a Button of height `height` as a bar row:
--   [3px quality bar][1px][square icon, full row height][content ... values]
-- Adds: row:SetBarStyle("item" | "header" | "plain"), row:SetBarQuality(q, fallbackKey),
--       row:SetBarIcon(texture | nil, coords?), row:SetBarSelected(on), row:SetBarDimmed(on).
-- row.barContentX = x offset where text content should start.
function Skin:BarRow(row, height)
    height = math.floor(height or row:GetHeight() or 24)

    local bg = row:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    row.barBg = bg

    -- Selected: accent tint + 1px accent outline (the left edge stays the quality bar).
    local sel = row:CreateTexture(nil, "BACKGROUND", nil, -6)
    sel:SetAllPoints()
    setTex(sel, "selected")
    sel:Hide()
    row.barSel = sel
    local outline = {}
    for i = 1, 4 do
        local t = row:CreateTexture(nil, "OVERLAY")
        setTex(t, "accent")
        t:Hide()
        outline[i] = t
    end
    outline[1]:SetPoint("TOPLEFT"); outline[1]:SetPoint("TOPRIGHT"); outline[1]:SetHeight(1)
    outline[2]:SetPoint("BOTTOMLEFT"); outline[2]:SetPoint("BOTTOMRIGHT"); outline[2]:SetHeight(1)
    outline[3]:SetPoint("TOPRIGHT"); outline[3]:SetPoint("BOTTOMRIGHT"); outline[3]:SetWidth(1)
    outline[4]:SetPoint("TOPLEFT", BAR_Q_W, 0); outline[4]:SetPoint("BOTTOMLEFT", BAR_Q_W, 0); outline[4]:SetWidth(1)
    row.barOutline = outline

    local q = row:CreateTexture(nil, "ARTWORK")
    q:SetPoint("TOPLEFT")
    q:SetPoint("BOTTOMLEFT")
    q:SetWidth(BAR_Q_W)
    row.barQ = q

    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", row, "TOPLEFT", BAR_Q_W + 1, 0)
    icon:SetSize(height, height)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.barIcon = icon

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    setTex(hl, "rowHover")
    row.barHighlight = hl

    row.barContentX = BAR_Q_W + 1 + height + 7
    row.barStyle = false

    function row:SetBarStyle(kind)
        if kind == self.barStyle then return end
        self.barStyle = kind
        if kind == "plain" then
            bg:Hide(); q:Hide(); icon:Hide()
            return
        end
        bg:Show(); q:Show(); icon:Show()
        if kind == "header" then
            setGradientH(bg, "rowHeaderLight", "rowHeader")
        else
            setGradientH(bg, "rowLight", "row")
        end
    end

    function row:SetBarQuality(quality, fallbackKey)
        local c = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
        if c and c.r then
            q:SetColorTexture(c.r, c.g, c.b, 1)
        else
            setTex(q, fallbackKey or "textDim")
        end
    end

    function row:SetBarIcon(tex, coords)
        if not tex then icon:Hide() return end
        icon:SetTexture(tex)
        if coords then
            icon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
        else
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
        icon:Show()
    end

    function row:SetBarSelected(on)
        on = on and true or false
        sel:SetShown(on)
        for i = 1, 4 do outline[i]:SetShown(on) end
    end

    function row:SetBarDimmed(on)
        if icon.SetDesaturated then icon:SetDesaturated(on and true or false) end
        icon:SetAlpha(on and 0.45 or 1)
        q:SetAlpha(on and 0.45 or 1)
    end

    row:SetBarStyle("item")
    row:SetBarQuality(nil)
    return row
end

---------------------------------------------------------------------------
-- Dropdown (flat skinned; no UIDropDownMenu / Blizzard templates)
---------------------------------------------------------------------------
-- Skin:Dropdown(parent, width, opts) -> button `dd`
-- opts = {
--   getItems   = function() return { {value=, text=, icon=?, iconCoords=?, note=?, disabled=?}, ... } end,
--   getValue   = function() return value end,
--   onSelect   = function(value) end,
--   maxVisible = 12,
--   prefix     = "Sort",              -- optional dim label shown before the value on the button
--   tooltip    = { "Title", "line" }, -- optional hover tooltip for the button
-- }
-- Item extras (optional): iconCoords {l,r,t,b} for atlas-style icons, note = dim right-aligned menu text.
-- dd:Refresh() re-reads getValue/getItems for the label; dd:Open(), dd:Close(), dd:IsOpen().
local DD_H, DD_ITEM_H, DD_PAD, DD_ICON, DD_MAX_W = 22, 20, 3, 14, 340
local ddMenu   -- one shared menu: only one dropdown can be open at a time

local function inCombat()
    return InCombatLockdown and InCombatLockdown()
end

local function setPropagate(f, on)
    if f.SetPropagateKeyboardInput and not inCombat() then
        pcall(f.SetPropagateKeyboardInput, f, on)
    end
end

local function menuThumb(m)
    local total = #m.items
    if total <= m.numVisible then m.thumb:Hide() return end
    local trackH = m.numVisible * DD_ITEM_H
    local thumbH = math.max(10, math.floor(trackH * m.numVisible / total + 0.5))
    local maxOff = total - m.numVisible
    local y = (trackH - thumbH) * m.offset / maxOff
    m.thumb:ClearAllPoints()
    m.thumb:SetPoint("TOPRIGHT", m, "TOPRIGHT", -2, -(DD_PAD + math.floor(y + 0.5)))
    m.thumb:SetSize(2, thumbH)
    m.thumb:Show()
end

local function fillMenu(m)
    local scroll = #m.items > m.numVisible
    for i, b in ipairs(m.buttons) do
        local it = (i <= m.numVisible) and m.items[m.offset + i] or nil
        b.item = it or false
        if not it then
            b:Hide()
        else
            local y = -(DD_PAD + (i - 1) * DD_ITEM_H)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", m, "TOPLEFT", 1, y)
            b:SetPoint("TOPRIGHT", m, "TOPRIGHT", scroll and -6 or -1, y)
            b.text:SetText(it.text or tostring(it.value))
            b.note:SetText(it.note or "")
            if it.icon then
                b.icon:SetTexture(it.icon)
                local c = it.iconCoords
                if c then b.icon:SetTexCoord(c[1], c[2], c[3], c[4]) else b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
                b.icon:Show()
            else
                b.icon:Hide()
            end
            b.text:ClearAllPoints()
            b.text:SetPoint("LEFT", b, "LEFT", m.hasIcons and (6 + DD_ICON + 5) or 8, 0)
            b.text:SetPoint("RIGHT", b.note, "LEFT", -6, 0)
            local cur = (it.value == m.value)
            b.sel:SetShown(cur)
            b.bar:SetShown(cur)
            b.mark:SetShown(cur)
            if it.disabled then b:Disable() else b:Enable() end
            setTextColor(b.text, it.disabled and "textDim" or "text", it.disabled and 0.6 or 1)
            b.icon:SetAlpha(it.disabled and 0.4 or 1)
            b:Show()
        end
    end
    menuThumb(m)
end

local function createMenuButton(m, i)
    local b = CreateFrame("Button", nil, m)
    b:SetHeight(DD_ITEM_H)
    b:RegisterForClicks("LeftButtonUp")

    b.sel = b:CreateTexture(nil, "BACKGROUND")
    b.sel:SetAllPoints()
    setTex(b.sel, "selected")
    b.bar = b:CreateTexture(nil, "BORDER")
    b.bar:SetPoint("TOPLEFT"); b.bar:SetPoint("BOTTOMLEFT"); b.bar:SetWidth(2)
    setTex(b.bar, "accent")
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    setTex(hl, "hover")

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(DD_ICON, DD_ICON)
    b.icon:SetPoint("LEFT", 6, 0)

    -- Current-value marker: small accent square (same language as Skin:Checkbox).
    b.mark = b:CreateTexture(nil, "ARTWORK")
    b.mark:SetSize(6, 6)
    b.mark:SetPoint("RIGHT", -7, 0)
    setTex(b.mark, "accent")

    b.note = Skin:Text(b, Skin.SIZE.small, "textDim")
    b.note:SetPoint("RIGHT", b.mark, "LEFT", -6, 0)
    b.note:SetJustifyH("RIGHT")
    b.note:SetWordWrap(false)

    b.text = Skin:Text(b, Skin.SIZE.normal, "text")
    b.text:SetWordWrap(false)

    b:SetScript("OnClick", function(self)
        local it, owner = self.item, m.owner
        if not it or it.disabled or not owner then return end
        local onSelect = owner.opts.onSelect
        if onSelect then onSelect(it.value) end
        if m:IsShown() and m.owner == owner then m:Hide() end
        owner:Refresh()
    end)
    m.buttons[i] = b
    return b
end

local function getMenu()
    if ddMenu then return ddMenu end

    -- Invisible full-screen click catcher just below the menu: any click outside closes it.
    local catcher = CreateFrame("Frame", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetFrameLevel(1)
    catcher:EnableMouse(true)
    catcher:EnableMouseWheel(true)
    catcher:Hide()

    local m = CreateFrame("Frame", "GearGuideDropdownMenu", UIParent, "BackdropTemplate")
    m:SetFrameStrata("FULLSCREEN_DIALOG")
    m:SetFrameLevel(catcher:GetFrameLevel() + 10)
    m:SetToplevel(true)
    m:SetClampedToScreen(true)
    m:EnableMouse(true)
    m:EnableMouseWheel(true)
    Skin:SetBackdrop(m, "menu", "borderStrong")
    m:Hide()
    m.catcher, m.buttons, m.items, m.offset, m.numVisible = catcher, {}, {}, 0, 0
    m.owner, m.value, m.hasIcons = false, false, false

    m.thumb = m:CreateTexture(nil, "OVERLAY")
    setTex(m.thumb, "thumb")
    m.thumb:Hide()

    m.measure = Skin:Text(m, Skin.SIZE.normal, "text")
    m.measure:Hide()
    m.measureSmall = Skin:Text(m, Skin.SIZE.small, "text")
    m.measureSmall:Hide()

    catcher:SetScript("OnMouseDown", function() m:Hide() end)
    catcher:SetScript("OnMouseWheel", function() m:Hide() end)

    m:SetScript("OnMouseWheel", function(self, delta)
        local maxOff = math.max(0, #self.items - self.numVisible)
        local o = math.max(0, math.min(maxOff, self.offset - delta))
        if o ~= self.offset then
            self.offset = o
            fillMenu(self)
        end
    end)
    m:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            setPropagate(self, false)
            self:Hide()
        else
            setPropagate(self, true)
        end
    end)
    m:SetScript("OnHide", function(self)
        self.catcher:Hide()
        if self.EnableKeyboard and not inCombat() then self:EnableKeyboard(false) end
        local owner = self.owner
        self.owner = false
        if owner then owner:UpdateLook() end
    end)

    -- In combat the keyboard handler can't stop Escape from propagating; the game's Escape
    -- handling (UISpecialFrames) still closes the menu then.
    if UISpecialFrames then table.insert(UISpecialFrames, "GearGuideDropdownMenu") end

    ddMenu = m
    return m
end

local function measure(fs, text)
    fs:SetText(text or "")
    return math.ceil(fs:GetStringWidth() or 0)
end

local function openMenu(dd)
    local m = getMenu()
    if m:IsShown() then m:Hide() end  -- only one open at a time
    local opts = dd.opts
    local items = (opts.getItems and opts.getItems()) or {}
    if #items == 0 then return end

    m.owner, m.items = dd, items
    m.value = opts.getValue and opts.getValue()
    m.numVisible = math.min(#items, math.max(1, opts.maxVisible or 12))
    m.offset = 0
    m.hasIcons = false
    local textW, noteW = 0, 0
    for i, it in ipairs(items) do
        if it.icon then m.hasIcons = true end
        textW = math.max(textW, measure(m.measure, it.text or tostring(it.value)))
        if it.note and it.note ~= "" then noteW = math.max(noteW, measure(m.measureSmall, it.note)) end
        if it.value == m.value and i > m.numVisible then
            m.offset = math.min(#items - m.numVisible, i - math.ceil(m.numVisible / 2))
        end
    end
    for i = #m.buttons + 1, m.numVisible do createMenuButton(m, i) end

    local scroll = #items > m.numVisible
    local w = (m.hasIcons and (6 + DD_ICON + 5) or 8) + textW + (noteW > 0 and (6 + noteW) or 0)
        + 6 + 6 + 7 + (scroll and 5 or 0) + 2
    w = math.max(dd:GetWidth() or 0, math.min(DD_MAX_W, w))

    -- Match the owner's scale, so the menu looks the same size as the button.
    local ui = UIParent:GetEffectiveScale() or 1
    if ui > 0 then m:SetScale((dd:GetEffectiveScale() or ui) / ui) end
    m:SetSize(w, m.numVisible * DD_ITEM_H + DD_PAD * 2)

    -- Open below the button, or above it when there is no room below.
    m:ClearAllPoints()
    local bottom = (dd:GetBottom() or 0) * (dd:GetEffectiveScale() or 1)
    local need = (m:GetHeight() or 0) * (m:GetEffectiveScale() or 1)
    if bottom - need - 4 < 0 then
        m:SetPoint("BOTTOMLEFT", dd, "TOPLEFT", 0, 2)
    else
        m:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -2)
    end

    if GameTooltip:IsOwned(dd) then GameTooltip:Hide() end
    m.catcher:Show()
    m:Show()
    m:SetFrameLevel(m.catcher:GetFrameLevel() + 10)
    m:Raise()
    if m.EnableKeyboard and not inCombat() then
        m:EnableKeyboard(true)
        setPropagate(m, true)
    end
    fillMenu(m)
    dd:UpdateLook()
end

-- Small flat down-arrow made of 1px rows (7, 5, 3, 1 px wide).
local function makeArrow(parent)
    local rows = {}
    for i = 1, 4 do
        local t = parent:CreateTexture(nil, "OVERLAY")
        t:SetSize(9 - i * 2, 1)
        if i == 1 then
            t:SetPoint("RIGHT", parent, "RIGHT", -7, 2)
        else
            t:SetPoint("TOP", rows[i - 1], "BOTTOM", 0, 0)
        end
        rows[i] = t
    end
    return rows
end

function Skin:Dropdown(parent, width, opts)
    opts = opts or {}
    local dd = CreateFrame("Button", nil, parent, "BackdropTemplate")
    dd:SetSize(width or 120, DD_H)
    dd:RegisterForClicks("LeftButtonUp")
    self:SetBackdrop(dd, "button", "border")
    dd.opts = opts
    dd.hovered = false

    local hl = dd:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", 1, -1)
    hl:SetPoint("BOTTOMRIGHT", -1, 1)
    setTex(hl, "hover")

    dd.icon = dd:CreateTexture(nil, "ARTWORK")
    dd.icon:SetSize(DD_ICON, DD_ICON)
    dd.icon:SetPoint("LEFT", 5, 0)
    dd.icon:Hide()

    dd.arrow = makeArrow(dd)

    dd.text = self:Text(dd, Skin.SIZE.normal, "text")
    dd.text:SetWordWrap(false)

    function dd:IsOpen()
        return ddMenu ~= nil and ddMenu:IsShown() and ddMenu.owner == self or false
    end

    function dd:UpdateLook()
        local open = self:IsOpen()
        local on = isEnabled(self)
        setBorder(self, open and "accent" or (self.hovered and on and "borderStrong" or "border"))
        for _, t in ipairs(self.arrow) do setTex(t, (open or self.hovered) and on and "accent" or "textDim") end
        setTextColor(self.text, on and "text" or "textDim", on and 1 or 0.6)
        self.icon:SetAlpha(on and 1 or 0.4)
    end

    function dd:Refresh()
        local o = self.opts
        local value = o.getValue and o.getValue()
        local found
        for _, it in ipairs((o.getItems and o.getItems()) or {}) do
            if it.value == value then found = it break end
        end
        local label = found and (found.text or tostring(found.value)) or (value ~= nil and tostring(value) or "")
        if o.prefix then label = Skin:Hex("textDim") .. o.prefix .. ":|r " .. label end
        self.text:SetText(label)
        self.text:ClearAllPoints()
        self.text:SetPoint("RIGHT", self, "RIGHT", -18, 0)
        if found and found.icon then
            self.icon:SetTexture(found.icon)
            local c = found.iconCoords
            if c then self.icon:SetTexCoord(c[1], c[2], c[3], c[4]) else self.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
            self.icon:Show()
            self.text:SetPoint("LEFT", self.icon, "RIGHT", 4, 0)
        else
            self.icon:Hide()
            self.text:SetPoint("LEFT", self, "LEFT", 6, 0)
        end
        -- Keep an open menu in sync too.
        if self:IsOpen() then
            ddMenu.value = value
            fillMenu(ddMenu)
        end
        self:UpdateLook()
    end

    function dd:Open() openMenu(self) end
    function dd:Close() if self:IsOpen() then ddMenu:Hide() end end

    dd:SetScript("OnClick", function(self)
        if self:IsOpen() then self:Close() else openMenu(self) end
    end)
    dd:SetScript("OnEnter", function(self)
        self.hovered = true
        self:UpdateLook()
        local tip = self.opts.tooltip
        if tip and not self:IsOpen() then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:AddLine(tip[1] or "", 1, 1, 1)
            if tip[2] then GameTooltip:AddLine(tip[2], 0.7, 0.7, 0.7, true) end
            GameTooltip:Show()
        end
    end)
    dd:SetScript("OnLeave", function(self)
        self.hovered = false
        self:UpdateLook()
        if GameTooltip:IsOwned(self) then GameTooltip:Hide() end
    end)
    dd:SetScript("OnEnable", function(self) self:UpdateLook() end)
    dd:SetScript("OnDisable", function(self) self:Close(); self:UpdateLook() end)
    dd:HookScript("OnHide", function(self) self:Close() end)

    dd:Refresh()
    return dd
end
