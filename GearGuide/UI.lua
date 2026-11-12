local _, ns = ...

-- Main window: "Recommended" and "Gear Browser" tabs, item list on the left,
-- detail panel on the right, footer status line. Drawn with ns.Skin only.

local ROW_H, ROW_GAP = 30, 2         -- row pitch; rows are 28px bars with a 2px gap
local DETAIL_W = 230
local GAP = 6
local FOOTER_H = 24                   -- footer line: status text + 24px Sharing button
local MIN_W, MIN_H, MAX_W, MAX_H = 620, 400, 1400, 1000
local BODY_W = DETAIL_W - 22          -- detail panel text width (padding + slim scroll bar)

local ORANGE = "|cffff8040"
local DOT = " \194\183 "              -- " · "
local DASH = "\226\128\147"           -- "–"
local BULLET = "\226\128\162 "        -- "• "
local PLUSMINUS = "\194\177"          -- "±"

-- List column geometry. Left: 3px quality bar, 28px icon, name. Right (anchored to the row's
-- right edge): favorite star, score, completion mark, req. level, then slot and source as
-- optional columns.
local NAME_X = 3 + 1 + (ROW_H - ROW_GAP) + 7
local STAR_W, STAR_HIT = 16, 20      -- drawn star / clickable area
local SCORE_X = -(4 + STAR_HIT + 4)   -- score's right edge, left of the star's hit area
local SCORE_W, MARK_W, LVL_W, SLOT_W = 70, 24, 24, 62
local RIGHT_W = -SCORE_X + SCORE_W + 4 + MARK_W + 4 + LVL_W
local NAME_MIN = 105                  -- the name keeps at least this; source goes first, then slot
local SOURCE_MIN, SOURCE_MAX = 130, 280
local NAME_SIZE = 13

local QUALITIES = {
    { label = "Any quality", q = 0 },
    { label = "Common+",     q = 1 },
    { label = "Uncommon+",   q = 2 },
    { label = "Rare+",       q = 3 },
    { label = "Epic+",       q = 4 },
}
local SORTS = { "Score", "Level", "Name" }

local CLASS_ICONS = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local EMPTY_SLOT = "Interface\\PaperDoll\\UI-Backpack-EmptySlot"
local SLOT_NAMES = {
    [1] = "HeadSlot", [2] = "NeckSlot", [3] = "ShoulderSlot", [15] = "BackSlot", [5] = "ChestSlot",
    [9] = "WristSlot", [10] = "HandsSlot", [6] = "WaistSlot", [7] = "LegsSlot", [8] = "FeetSlot",
    [11] = "Finger0Slot", [13] = "Trinket0Slot", [16] = "MainHandSlot", [17] = "SecondaryHandSlot",
    [18] = "RangedSlot",
}

local STAT_ORDER = { "DPS", "ARMOR", "STR", "AGI", "STA", "INT", "SPI", "AP", "RAP", "SP", "HEAL",
    "CRIT", "HIT", "SCRIT", "SHIT", "HASTE", "EXPERTISE", "DEF", "DODGE", "PARRY", "BLOCK", "MP5" }
local STAT_NAMES = {
    STR = "Strength", AGI = "Agility", STA = "Stamina", INT = "Intellect", SPI = "Spirit",
    ARMOR = "Armor", DPS = "damage per second", AP = "Attack Power", RAP = "Ranged Attack Power",
    SP = "Spell Power", HEAL = "Healing", CRIT = "Critical Strike", HIT = "Hit",
    SCRIT = "Spell Critical Strike", SHIT = "Spell Hit", DEF = "Defense", DODGE = "Dodge",
    PARRY = "Parry", BLOCK = "Block", MP5 = "Mana per 5 sec.", HASTE = "Haste", EXPERTISE = "Expertise",
}
local STAT_PERCENT = { CRIT = true, HIT = true, SCRIT = true, SHIT = true, DODGE = true, PARRY = true, HASTE = true, EXPERTISE = true }

local ARMOR_TYPES = { [0] = "Miscellaneous", [1] = "Cloth", [2] = "Leather", [3] = "Mail", [4] = "Plate",
    [6] = "Shield", [7] = "Libram", [8] = "Idol", [9] = "Totem" }
local WEAPON_TYPES = { [0] = "Axe", [1] = "Axe", [2] = "Bow", [3] = "Gun", [4] = "Mace", [5] = "Mace",
    [6] = "Polearm", [7] = "Sword", [8] = "Sword", [10] = "Staff", [13] = "Fist Weapon", [15] = "Dagger",
    [16] = "Thrown", [18] = "Crossbow", [19] = "Wand", [20] = "Fishing Pole" }

local frame, list
local updateDetail     -- forward (defined in the detail panel section)
local toggleFavorite   -- forward (defined after the detail panel section)
local W = {}           -- widgets
local rowFrames = {}   -- every row frame the list has created (for the flash highlight)
local bodyLines = {}   -- detail panel FontString pool
local state = {
    tab = "recommended",
    data = {},
    selected = nil,    -- { id, class, spec (nil = the player's spec), link }
    resetScroll = false,
    flashId = nil, flashUntil = 0,
    filter = {
        text = "", class = nil, spec = nil, slot = 0, minL = nil, maxL = nil,
        quality = 1, sort = 1, usable = true, hideDone = false, favOnly = false,
    },
}

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function rgba(key)
    local c = ns.Skin.C[key] or ns.Skin.C.text
    return c.r or c[1], c.g or c[2], c.b or c[3], c.a or c[4] or 1
end

local function hideTooltip() GameTooltip:Hide() end

local function maxLevel()
    return (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
end

local function fmtNum(v)
    if v == math.floor(v) then return tostring(v) end
    return string.format("%.1f", v)
end

local function scoreText(score, delta)
    local s = string.format("%.1f", score or 0)
    if delta then
        if delta > 0.05 then
            s = s .. " " .. ns.Skin:Hex("upgrade") .. string.format("+%.1f", delta) .. "|r"
        elseif delta < -0.05 then
            s = s .. " " .. ns.Skin:Hex("downgrade") .. string.format("%.1f", delta) .. "|r"
        else
            s = s .. " " .. ns.Skin:Hex("textDim") .. PLUSMINUS .. "0|r"
        end
    end
    return s
end

local function levelText(item)
    local rl = item.rl or 0
    if rl <= 0 then return ns.Skin:Hex("textDim") .. "-|r" end
    if rl > UnitLevel("player") then return ORANGE .. rl .. "|r" end
    return tostring(rl)
end

local function classLabel(class)
    return ns:ClassColorHex(class) .. ns:ClassName(class) .. "|r"
end

local function itemLink(id)
    local _, link = ns.GetItemInfo(id)
    if not link and C_Item and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(id)
    end
    return link
end

local function insertLink(link)
    if not link then return end
    if ChatEdit_InsertLink and ChatEdit_InsertLink(link) then return end
    if ChatFrame_OpenChat then ChatFrame_OpenChat(link) end
end

local function handleModifiedClick(link)
    if not link then return false end
    if IsShiftKeyDown() then
        insertLink(link)
        return true
    elseif IsControlKeyDown() then
        if DressUpItemLink then DressUpItemLink(link) end
        return true
    end
    return false
end

-- Places GameTooltip beside the window so it never covers the list or detail panel.
local function placeTooltipBesideWindow(row)
    if not frame then return end
    GameTooltip:ClearAllPoints()
    if (frame:GetLeft() or 0) > 330 then
        GameTooltip:SetPoint("TOPRIGHT", frame, "TOPLEFT", -4, (row:GetTop() or 0) - (frame:GetTop() or 0))
    else
        GameTooltip:SetPoint("TOPLEFT", frame, "TOPRIGHT", 4, (row:GetTop() or 0) - (frame:GetTop() or 0))
    end
end

---------------------------------------------------------------------------
-- Classes and specializations
---------------------------------------------------------------------------
local function classIcon(class)
    local t = type(CLASS_ICON_TCOORDS) == "table" and CLASS_ICON_TCOORDS[class]
    if type(t) == "table" and t[4] then return CLASS_ICONS, t end
end

local function roleLabel(role)
    return (role and ns.ROLE_LABELS[role]) or role or "?"
end

-- Spec used by the gear browser: the chosen one if it belongs to the browsed class,
-- else the player's spec when browsing their own class, else the class's first spec.
local function browseSpec()
    local f = state.filter
    local class = f.class or ns:GetPlayerClass()
    if f.spec then
        for _, s in ipairs(ns:GetSpecs(class)) do
            if s.key == f.spec then return f.spec end
        end
    end
    if class == ns:GetPlayerClass() then return ns:GetPlayerSpec() end
    local first = ns:GetSpecs(class)[1]
    return first and first.key
end

-- Dropdown entries for a class's specs (icon + name, role as a dim note).
local function specItems(class)
    local out = {}
    for _, s in ipairs(ns:GetSpecs(class)) do
        out[#out + 1] = { value = s.key, text = s.label, icon = s.icon, note = roleLabel(s.role) }
    end
    return out
end

---------------------------------------------------------------------------
-- Icons (re-filled when the client finishes loading uncached items)
---------------------------------------------------------------------------
local pendingIcons = {}   -- [itemID] = true while a visible row shows the "?" fallback
local iconRefreshPending = false
local slotTexCache = {}

local function rowIcon(id)
    local icon = ns.ItemIcon(id)
    if icon == ns.QUESTION_ICON then
        pendingIcons[id] = true
        if C_Item and C_Item.RequestLoadItemDataByID then
            C_Item.RequestLoadItemDataByID(id)
        else
            ns.GetItemInfo(id)  -- also asks the server for the item
        end
    end
    return icon
end

-- Paper-doll silhouette for an empty slot group.
local function slotTexture(groupKey)
    local tex = slotTexCache[groupKey]
    if tex then return tex end
    local g = ns.SLOT_GROUP_BY_KEY[groupKey]
    local slotName = g and SLOT_NAMES[g.inv[1]]
    if slotName and GetInventorySlotInfo then
        local ok, _, t = pcall(GetInventorySlotInfo, slotName)
        if ok and t then tex = t end
    end
    tex = tex or EMPTY_SLOT
    slotTexCache[groupKey] = tex
    return tex
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
        -- Only re-fill the visible rows (and the detail icon); no data rebuild.
        if frame and frame:IsShown() and list then
            list:Refresh()
            local sel = state.selected
            if sel and W.iconTex then W.iconTex:SetTexture(ns.ItemIcon(sel.id)) end
        end
    end)
end)

---------------------------------------------------------------------------
-- List rows
---------------------------------------------------------------------------
-- Decides which optional columns fit (source goes first, then slot) and gives the name the rest.
local function applyColumns(r, w)
    if not w or w <= 0 then return end
    -- Same decision for rows and the column header (NAME_X, not r.nameX), so columns line up.
    local room = w - NAME_X - RIGHT_W - GAP          -- name + optional slot/source
    local showSlot = room - (SLOT_W + GAP) >= NAME_MIN
    local avail = room - SLOT_W - GAP * 2               -- name + source
    local showSource = showSlot and avail - SOURCE_MIN >= NAME_MIN
    local sourceW = 0
    if showSource then
        sourceW = math.max(SOURCE_MIN, math.min(SOURCE_MAX, math.floor(avail * 0.45), avail - NAME_MIN))
    end
    local indent = type(r.barIndent) == "number" and r.barIndent or 0  -- column header has no bar
    local key = (showSlot and 1 or 0) + (showSource and 2 or 0) + sourceW * 4 + indent * 100000
    if r.colKey ~= key then
        r.colKey = key
        r.source:SetWidth(math.max(1, sourceW))
        local anchor = (showSource and r.source) or (showSlot and r.slot) or r.lvl
        r.name:ClearAllPoints()
        r.name:SetPoint("LEFT", r, "LEFT", r.nameX + indent, 0)
        r.name:SetPoint("RIGHT", anchor, "LEFT", -GAP, 0)
    end
    local itemCols = (r.kind == "item" or r.kind == "colheader")
    r.slot:SetShown(itemCols and showSlot)
    r.source:SetShown(itemCols and showSource)
end

local function makeColumns(r, nameSize, nameX)
    local Skin = ns.Skin
    r.nameX = nameX or NAME_X
    r.colKey = false

    r.score = Skin:Text(r, Skin.SIZE.normal, "text")
    r.score:SetPoint("RIGHT", r, "RIGHT", SCORE_X, 0)
    r.score:SetWidth(SCORE_W)
    r.score:SetJustifyH("RIGHT")
    r.score:SetWordWrap(false)

    r.mark = Skin:Text(r, Skin.SIZE.small, "text")
    r.mark:SetPoint("RIGHT", r.score, "LEFT", -4, 0)
    r.mark:SetWidth(MARK_W)
    r.mark:SetJustifyH("CENTER")
    r.mark:SetWordWrap(false)

    r.lvl = Skin:Text(r, Skin.SIZE.small, "text")
    r.lvl:SetPoint("RIGHT", r.mark, "LEFT", -4, 0)
    r.lvl:SetWidth(LVL_W)
    r.lvl:SetJustifyH("RIGHT")

    r.slot = Skin:Text(r, Skin.SIZE.small, "textDim")
    r.slot:SetPoint("RIGHT", r.lvl, "LEFT", -GAP, 0)
    r.slot:SetWidth(SLOT_W)
    r.slot:SetWordWrap(false)

    r.source = Skin:Text(r, Skin.SIZE.small, "textDim")
    r.source:SetPoint("RIGHT", r.slot, "LEFT", -GAP, 0)
    r.source:SetWordWrap(false)

    r.name = Skin:Text(r, nameSize or NAME_SIZE, "text")
    r.name:SetPoint("LEFT", r, "LEFT", r.nameX, 0)
    r.name:SetWordWrap(false)
    r.name:SetShadowColor(0, 0, 0, 1)   -- crisp white-on-dark like the reference
end

-- Row frames are Skin:List rows decorated by Skin:BarRow (quality bar, icon, dark gradient).
local function createRow(row)
    local Skin = ns.Skin
    rowFrames[#rowFrames + 1] = row

    row.flash = row:CreateTexture(nil, "BORDER", nil, 1)
    row.flash:SetAllPoints()
    local r, g, b = rgba("accent")
    row.flash:SetColorTexture(r, g, b, 1)
    row.flash:SetAlpha(0)

    makeColumns(row, NAME_SIZE, row.barContentX or NAME_X)

    row.hLabel = Skin:Text(row, NAME_SIZE, "accent")
    row.hLabel:SetPoint("LEFT", row, "LEFT", row.nameX, 0)
    row.hLabel:SetWordWrap(false)
    row.hLabel:SetShadowColor(0, 0, 0, 1)
    row.hLink = Skin:Text(row, Skin.SIZE.small, "text")
    row.hLink:SetPoint("LEFT", row.hLabel, "RIGHT", 8, 0)
    row.hLink:SetPoint("RIGHT", row.score, "LEFT", -6, 0)
    row.hLink:SetWordWrap(false)

    -- Favorite toggle at the far right (a child button: clicking it doesn't select the row).
    row.star = Skin:StarButton(row, STAR_HIT, STAR_W)
    row.star:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    row.star.tooltip = { "Favorite", "Mark this as an item you're going for. Alt-click a row also toggles." }
    row.star.onToggle = function()
        local d = row.data
        if d and d.kind == "item" then toggleFavorite(d.id) end
    end

    row:HookScript("OnSizeChanged", function(self, w) applyColumns(self, w) end)
end

local function setItemColumnsShown(row, shown)
    row.mark:SetShown(shown)
    row.name:SetShown(shown)
    row.lvl:SetShown(shown)
    row.hLabel:SetShown(not shown)
    row.hLink:SetShown(not shown)
end

-- Acquired rows: dim name, faded icon/bar and values.
local function setRowDone(row, done)
    row.name:SetTextColor(rgba(done and "textDim" or "text"))
    row:SetBarDimmed(done)
    local a = done and 0.55 or 1
    row.slot:SetAlpha(a); row.lvl:SetAlpha(a); row.score:SetAlpha(a); row.source:SetAlpha(a)
end

local ITEM_INDENT = 18  -- Recommended tab: items sit indented under their slot / Favorites header

local function fillRow(row, d)
    row.kind = d.kind
    if row.SetBarIndent then
        row:SetBarIndent((d.kind == "item" and state.tab == "recommended") and ITEM_INDENT or 0)
    end
    applyColumns(row, row:GetWidth())
    row.flash:SetAlpha(0)
    row.star:SetShown(d.kind == "item")
    if d.kind == "item" then
        local item = d.item
        row.star:SetFavorite(ns:IsFavorite(d.id))
        row:SetBarStyle("item")
        row:SetBarQuality(item.q)
        row:SetBarIcon(rowIcon(d.id))
        setItemColumnsShown(row, true)
        row.score:Show()
        row.mark:SetText(ns:CompletionMarkup(d.id, d.class))
        row.name:SetText(item.n or ("Item " .. d.id))
        row.slot:SetText(ns.SlotLabel(item.eq))
        row.lvl:SetText(levelText(item))
        row.score:SetText(scoreText(d.score, d.delta))
        row.source:SetText(ns:SourceSummary(d.id))
        setRowDone(row, ns:GetCompletion(d.id, d.class) == "done")
    elseif d.kind == "header" then
        row:SetBarStyle("header")
        setItemColumnsShown(row, false)
        setRowDone(row, false)
        row.hLabel:SetText(d.label)
        if d.fav then
            -- "Favorites" section header on the Recommended tab
            row:SetBarIcon(ns.Skin.STAR, { 0, 1, 0, 1 })
            row:SetBarQuality(nil, "accent")
            row.hLink:SetText(ns.Skin:Hex("textDim") .. string.format("%d chosen", d.count or 0) .. "|r")
        elseif d.equippedLink then
            local eid = ns.LinkToId(d.equippedLink)
            row:SetBarIcon(eid and rowIcon(eid) or ns.QUESTION_ICON)
            row:SetBarQuality((select(3, ns.GetItemInfo(d.equippedLink))), "accent")
            row.hLink:SetText(ns.Skin:Hex("textDim") .. "Equipped:|r " .. d.equippedLink)
        else
            row:SetBarIcon(slotTexture(d.key))
            row:SetBarQuality(nil, "accent")
            row:SetBarDimmed(true)
            row.hLink:SetText(ns.Skin:Hex("textDim") .. "Nothing equipped|r")
        end
        row.score:SetShown(d.equippedScore ~= nil)
        row.score:SetText(d.equippedScore and (ns.Skin:Hex("textDim") .. string.format("%.1f", d.equippedScore) .. "|r") or "")
    else -- note
        row:SetBarStyle("plain")
        setItemColumnsShown(row, false)
        setRowDone(row, false)
        row.hLabel:SetText("")
        row.hLink:SetText(ns.Skin:Hex("textDim") .. (d.text or "") .. "|r")
        row.score:Hide()
    end
end

local function rowOnEnter(row, d)
    if d.kind == "item" then
        ns:ShowItemTooltip(row, d.id, { score = d.score, delta = d.delta, class = d.class, anchor = "ANCHOR_NONE" })
        placeTooltipBesideWindow(row)
    elseif d.kind == "header" and d.equippedLink then
        GameTooltip:SetOwner(row, "ANCHOR_NONE")
        GameTooltip:SetHyperlink(d.equippedLink)
        GameTooltip:Show()
        placeTooltipBesideWindow(row)
    end
end

local function rowOnLeave()
    ns:HideItemTooltip()
end

---------------------------------------------------------------------------
-- Selection, flash highlight
---------------------------------------------------------------------------

local function isSelected(d)
    local sel = state.selected
    return sel ~= nil and d.kind == "item" and d.id == sel.id
end

-- `link` (optional) keeps random-suffix stats for equipped items.
local function selectItem(id, class, spec, link)
    state.selected = { id = id, class = class or ns:GetPlayerClass(), spec = spec, link = link }
    W.bodyScroll:SetVerticalScroll(0)
    list:SetSelected(isSelected)
    updateDetail()
end

local function rowOnClick(row, d, button)
    if button ~= "LeftButton" then return end
    if d.kind == "item" then
        if IsAltKeyDown and IsAltKeyDown() then
            toggleFavorite(d.id)
        elseif IsShiftKeyDown() or IsControlKeyDown() then
            handleModifiedClick(itemLink(d.id))
        else
            selectItem(d.id, d.class, d.spec)
        end
    elseif d.kind == "header" and d.equippedLink then
        if not handleModifiedClick(d.equippedLink) then
            local id = ns.LinkToId(d.equippedLink)
            if id then selectItem(id, ns:GetPlayerClass(), nil, d.equippedLink) end
        end
    end
end

local function findIndex(id)
    for i, d in ipairs(state.data) do
        if d.kind == "item" and d.id == id then return i end
    end
end

local FLASH_TIME = 1.6
local function updateFlash()
    local t = state.flashUntil - GetTime()
    local a = t > 0 and 0.55 * (t / FLASH_TIME) or 0
    for _, row in ipairs(rowFrames) do
        local d = row:IsShown() and row.data
        if d and d.kind == "item" and d.id == state.flashId then
            row.flash:SetAlpha(a)
        else
            row.flash:SetAlpha(0)
        end
    end
    if t <= 0 then W.flashDriver:Hide() end
end

local function flash(id)
    state.flashId = id
    state.flashUntil = GetTime() + FLASH_TIME
    W.flashDriver:Show()
end

---------------------------------------------------------------------------
-- Row builders
---------------------------------------------------------------------------
local function emptyDatabaseNote(rows)
    if #ns:AllItemIds() == 0 then
        rows[#rows + 1] = { kind = "note",
            text = "No item data yet. Run GearGuideTools/update_db.py, or play to learn items." }
    end
end

local function buildRecommendedRows()
    local rec = ns:BuildRecommendations()
    local class = ns:GetPlayerClass()
    local spec = ns:GetSpecInfo(class, ns:GetPlayerSpec())

    local rows = {}
    emptyDatabaseNote(rows)

    -- Favorites section: everything the player has starred, in the order they picked it,
    -- scored against what's equipped in its slot.
    local favs = ns:GetFavorites()
    if #favs > 0 then
        local weights, ctx = ns:GetScoringContext()
        local eqScore = {}
        for _, g in ipairs(rec.groups) do eqScore[g.key] = g.equippedScore or 0 end
        local favRows = {}
        for _, id in ipairs(favs) do
            local item = ns:GetItem(id)
            if item then
                local score = ns:Score(item, weights, ctx)
                local key = ns.EQUIPLOC_GROUP[item.eq]
                favRows[#favRows + 1] = { kind = "item", id = id, item = item, score = score,
                    delta = key and (score - (eqScore[key] or 0)) or nil, class = class }
            end
        end
        rows[#rows + 1] = { kind = "header", fav = true, label = "Favorites", count = #favs }
        if #favRows == 0 then
            rows[#rows + 1] = { kind = "note", text = "Your favorites aren't in the item database yet" }
        end
        for _, r in ipairs(favRows) do rows[#rows + 1] = r end
    end

    for _, g in ipairs(rec.groups) do
        rows[#rows + 1] = { kind = "header", key = g.key, label = g.label,
            equippedLink = g.equippedLink, equippedScore = g.equippedScore }
        if #g.picks == 0 then
            rows[#rows + 1] = { kind = "note", text = "Nothing known in this level range" }
        end
        for _, p in ipairs(g.picks) do
            -- spec = nil: follows the player's spec (so the detail panel tracks spec changes).
            rows[#rows + 1] = { kind = "item", id = p.id, item = p.item, score = p.score, delta = p.delta,
                class = class }
        end
    end
    return rows
end

local function buildBrowserRows()
    local f = state.filter
    local spec = browseSpec()
    local weights, ctx = ns:GetScoringContext(f.class, spec)
    local level = ctx.level
    local text = (f.text or ""):lower()
    local groupKey = f.slot > 0 and ns.SLOT_GROUPS[f.slot].key or nil
    local minQ = QUALITIES[f.quality].q

    -- Favorites only: just the starred items, and the level range is ignored so a far-off
    -- favorite still shows (the other filters still apply).
    local ids = f.favOnly and ns:GetFavorites() or ns:AllItemIds()
    local minL = not f.favOnly and f.minL or nil
    local maxL = not f.favOnly and f.maxL or nil

    local rows = {}
    for _, id in ipairs(ids) do
        local item = ns:GetItem(id)
        local group = item and ns.EQUIPLOC_GROUP[item.eq]
        if group and (not groupKey or group == groupKey) and (item.q or 1) >= minQ then
            local eff = ns.EffectiveLevel(item)
            if (not minL or eff >= minL) and (not maxL or eff <= maxL)
                and (text == "" or (item.n and item.n:lower():find(text, 1, true)))
                and (not f.usable or ns:IsUsable(item, f.class, level))
                and (not f.hideDone or ns:GetCompletion(id, f.class) ~= "done") then
                rows[#rows + 1] = { kind = "item", id = id, item = item,
                    score = ns:Score(item, weights, ctx), class = f.class, spec = spec }
            end
        end
    end

    if f.sort == 1 then
        table.sort(rows, function(a, b)
            if a.score ~= b.score then return a.score > b.score end
            return a.id < b.id
        end)
    elseif f.sort == 2 then
        table.sort(rows, function(a, b)
            local la, lb = ns.EffectiveLevel(a.item), ns.EffectiveLevel(b.item)
            if la ~= lb then return la > lb end
            if a.score ~= b.score then return a.score > b.score end
            return a.id < b.id
        end)
    else
        table.sort(rows, function(a, b)
            local na, nb = a.item.n or "", b.item.n or ""
            if na ~= nb then return na < nb end
            return a.id < b.id
        end)
    end

    W.count:SetText(string.format("%d item%s", #rows, #rows == 1 and "" or "s"))
    if #rows == 0 then
        emptyDatabaseNote(rows)
        if #rows == 0 and f.favOnly and #ids == 0 then
            rows[1] = { kind = "note", text = "No favorites yet: click the star on a row, or Alt-click it." }
        elseif #rows == 0 then
            rows[1] = { kind = "note", text = "No items match these filters." }
        end
    end
    return rows
end

---------------------------------------------------------------------------
-- Detail panel
---------------------------------------------------------------------------
local bodyY, bodyCount = 0, 0

local function bodyReset() bodyY, bodyCount = 0, 0 end

local function bodyAdd(text, size, colorKey, gap, indent)
    bodyCount = bodyCount + 1
    local fs = bodyLines[bodyCount]
    if not fs then
        fs = ns.Skin:Text(W.bodyChild, ns.Skin.SIZE.small, "text")
        fs:SetWordWrap(true)
        bodyLines[bodyCount] = fs
    end
    local font, _, flags = fs:GetFont()
    fs:SetFont(font or ns.Skin.FONT, size or ns.Skin.SIZE.small, flags or "")
    fs:SetTextColor(rgba(colorKey or "text"))
    indent = indent or 0
    bodyY = bodyY + (gap or 0)
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", W.bodyChild, "TOPLEFT", indent, -bodyY)
    fs:SetWidth(BODY_W - indent)
    fs:SetText(text)
    fs:Show()
    bodyY = bodyY + math.ceil(fs:GetStringHeight() or 12) + 2
end

local function updateBodyBar()
    local sf, child, bar = W.bodyScroll, W.bodyChild, W.bodyBar
    local sfH, ch = sf:GetHeight() or 0, child:GetHeight() or 0
    local maxScroll = math.max(0, ch - sfH)
    if sf:GetVerticalScroll() > maxScroll then sf:SetVerticalScroll(maxScroll) end
    if maxScroll < 1 or sfH <= 0 then bar:Hide() return end
    local thumbH = math.max(16, sfH * sfH / ch)
    local off = sf:GetVerticalScroll() / maxScroll * (sfH - thumbH)
    bar:ClearAllPoints()
    bar:SetPoint("TOPLEFT", sf, "TOPRIGHT", 4, -off)
    bar:SetSize(2, thumbH)
    bar:Show()
end

-- Clickable source lines: an invisible button over each source line that has a map location.
local sourceButtons, sourceButtonCount = {}, 0

local function attachSourceButton(fs, source)
    sourceButtonCount = sourceButtonCount + 1
    local b = sourceButtons[sourceButtonCount]
    if not b then
        b = CreateFrame("Button", nil, W.bodyChild)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT")
        b.hl:SetAllPoints()
        b.hl:SetColorTexture(rgba("hover"))
        b:SetScript("OnClick", function(self) ns:ShowSourceOnMap(self.source) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:AddLine(self.source.n or "?")
            GameTooltip:AddLine(ns.FormatSource(self.source), 1, 1, 1, true)
            local loc = self.source.loc
            local entrance = loc and loc[1] and loc[1].e
            GameTooltip:AddLine(entrance and "Click: show the dungeon entrance on the map" or "Click: show on the map",
                0.4, 1, 0.6)
            if loc and #loc > 1 then
                GameTooltip:AddLine(string.format("Found on %d maps; click again for the next one.", #loc), 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        sourceButtons[sourceButtonCount] = b
    end
    b.source = source
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", fs, "TOPLEFT", -2, 3)        -- 3px vertical padding on the hit area
    b:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 2, -3)
    b:Show()
end

local function hideUnusedSourceButtons()
    for i = sourceButtonCount + 1, #sourceButtons do sourceButtons[i]:Hide() end
    sourceButtonCount = 0
end

local function bodyFinish()
    hideUnusedSourceButtons()
    for i = bodyCount + 1, #bodyLines do bodyLines[i]:Hide() end
    W.bodyChild:SetHeight(math.max(1, bodyY))
    updateBodyBar()
end

local function itemTypeText(item)
    local slot = (item.eq and _G[item.eq]) or ns.SlotLabel(item.eq)
    local typ
    if item.c == ns.ITEM_CLASS_ARMOR then
        if item.eq ~= "INVTYPE_CLOAK" and (item.sc or 0) ~= 0 then typ = ARMOR_TYPES[item.sc] end
    elseif item.c == ns.ITEM_CLASS_WEAPON then
        typ = WEAPON_TYPES[item.sc or -1]
    end
    if typ then return slot .. DOT .. typ end
    return slot
end

-- Returns baseline score of the weakest equipped item of the item's slot group,
-- its link, and whether the item itself is equipped there. Player's class only.
local function equippedBaseline(id, item, weights, ctx)
    local key = ns.EQUIPLOC_GROUP[item.eq]
    local grp = key and ns.SLOT_GROUP_BY_KEY[key]
    if not grp or not ns.ItemForSlot then return nil end
    local base, baseLink, isEquipped
    for _, slot in ipairs(grp.inv) do
        local eItem, link, eid = ns:ItemForSlot(slot)
        if eid == id then isEquipped = true end
        local s = eItem and ns:Score(eItem, weights, ctx) or 0
        if base == nil or s < base then base, baseLink = s, link end
    end
    return base, baseLink, isEquipped
end

-- "Favorite" / "Unfavorite" button under the detail panel's item name.
local function updateFavButton()
    local b, sel = W.favBtn, state.selected
    if not b then return end
    if not sel then b:Hide() return end
    local on = ns:IsFavorite(sel.id)
    b:SetText(on and "Unfavorite" or "Favorite")
    b:SetActive(on)
    ns.Skin:StyleStar(b.star, on, false)
    b:Show()
end

function updateDetail()
    if not W.detail then return end
    local sel = state.selected
    local id = sel and sel.id
    local item = id and ((sel.link and ns:ItemFromLink(sel.link)) or ns:GetItem(id) or ns:ItemFromLink("item:" .. id))
    updateFavButton()
    if not id then
        W.detailEmpty:Show()
        W.icon:Hide(); W.dName:Hide(); W.bodyScroll:Hide(); W.bodyBar:Hide()
        return
    end
    W.detailEmpty:Hide()
    W.icon:Show(); W.dName:Show(); W.bodyScroll:Show()
    W.iconTex:SetTexture(rowIcon(id))
    local qc = item and item.q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[item.q]
    ns.Skin:SetBorderColor(W.icon, (qc and qc.r) and { qc.r, qc.g, qc.b, 0.85 } or "borderStrong")

    local Skin = ns.Skin
    local small, hdr = Skin.SIZE.small, Skin.SIZE.header
    bodyReset()

    if not item then
        local name = ns.GetItemInfo(id)
        W.dName:SetText(name or ("Item #" .. id))
        bodyAdd("This item is not in the GearGuide database yet.", small, "textDim")
        bodyAdd("Item ID " .. id, small, "textDim", 8)
        bodyFinish()
        return
    end

    W.dName:SetText(ns.QualityHex(item.q) .. (item.n or ("Item #" .. id)) .. "|r")
    local class = sel.class or ns:GetPlayerClass()
    local playerLevel = UnitLevel("player")

    -- Basics
    bodyAdd(itemTypeText(item), small, "textDim")
    local rl = item.rl or 0
    local lvl = rl > 0 and ((rl > playerLevel and ORANGE or "") .. "Requires level " .. rl .. (rl > playerLevel and "|r" or ""))
        or "No level requirement"
    if item.il and item.il > 0 then lvl = lvl .. ns.Skin:Hex("textDim") .. DOT .. "item level " .. item.il .. "|r" end
    bodyAdd(lvl, small, "text", 2)

    -- Completion
    local cState, have, need = ns:GetCompletion(id, class)
    have, need = have or 0, need or 1
    if cState == "done" then
        bodyAdd(string.format("Acquired %d/%d", have, need), small, "done", 2)
    elseif cState == "partial" then
        bodyAdd(string.format("Acquired %d/%d", have, need), small, "partial", 2)
    else
        bodyAdd(string.format("Not acquired (0/%d)", need), small, "textDim", 2)
    end
    if not ns:IsUsable(item, class, playerLevel) then
        bodyAdd("Not usable by " .. ns:ClassName(class), small, "downgrade", 2)
    end

    -- Score
    local weights, ctx = ns:GetScoringContext(class, sel.spec)
    local score = ns:Score(item, weights, ctx)
    bodyAdd("Score for " .. classLabel(class) .. ns.Skin:Hex("textDim") .. DOT .. "|r"
        .. ns:SpecLabel(class, ctx.spec), small, "textDim", 10)
    bodyAdd(string.format("%.1f", score), hdr, "accent", 1)
    if class == ns:GetPlayerClass() then
        local base, baseLink, isEquipped = equippedBaseline(id, item, weights, ctx)
        if isEquipped then
            bodyAdd("Currently equipped", small, "done", 2)
        elseif base then
            bodyAdd(scoreText(score, score - base):gsub("^%S+ ", "") .. " vs. equipped", small, "text", 2)
            bodyAdd(baseLink and ("Equipped: " .. baseLink .. " (" .. string.format("%.1f", base) .. ")")
                or "Nothing equipped in this slot", small, "textDim", 1, 0)
        end
    else
        bodyAdd("No comparison: browsing another class", small, "textDim", 2)
    end

    -- Stats
    bodyAdd("Stats", hdr, "accent", 10)
    local st = item.st or {}
    local seen, any = {}, false
    local keys = {}
    for _, k in ipairs(STAT_ORDER) do keys[#keys + 1] = k; seen[k] = true end
    local extra = {}
    for k in pairs(st) do if not seen[k] then extra[#extra + 1] = k end end
    table.sort(extra)
    for _, k in ipairs(extra) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do
        local v = st[k]
        if type(v) == "number" and v ~= 0 then
            any = true
            local name = STAT_NAMES[k] or k
            local line
            if k == "DPS" then
                line = fmtNum(v) .. " " .. name
            elseif k == "ARMOR" then
                line = fmtNum(v) .. " " .. name
            elseif STAT_PERCENT[k] then
                line = (v > 0 and "+" or "") .. fmtNum(v) .. "% " .. name
            else
                line = (v > 0 and "+" or "") .. fmtNum(v) .. " " .. name
            end
            local relevant = weights[k] and weights[k] > 0
            bodyAdd(line, small, relevant and "text" or "textDim", 1, 6)
        end
    end
    if not any then bodyAdd("No stats", small, "textDim", 1, 6) end

    -- Sources
    bodyAdd("Where to get it", hdr, "accent", 10)
    local sources = ns:GetSources(id)
    if #sources == 0 then
        bodyAdd("Source unknown. Run GearGuideTools/update_db.py, or loot / see the item in game to learn it.",
            small, "textDim", 1, 6)
    else
        local onMap = 0
        for _, s in ipairs(sources) do
            if ns.HasLocation(s) then
                onMap = onMap + 1
                local icon = ns.MapIconFor and ns.MapIconFor(s)
                bodyAdd((icon and ("|T" .. icon .. ":12:12|t ") or BULLET) .. ns.FormatSource(s), small, "text", 4, 6)
                attachSourceButton(bodyLines[bodyCount], s)
            else
                bodyAdd(BULLET .. ns.FormatSource(s), small, "textDim", 2, 6)
            end
        end
        if onMap > 0 then bodyAdd("Click a source to show it on the map.", small, "textDim", 4, 6) end
    end

    bodyAdd("Item ID " .. id .. DOT .. "Shift-click icon: link" .. DOT .. "Ctrl-click: preview",
        small, "textDim", 10)
    bodyFinish()
end

-- Toggles a favorite and updates what's on screen right away (stars on the visible rows, the
-- detail button); Core's RequestRefresh then rebuilds the lists (Favorites section, mini tracker).
function toggleFavorite(id)
    local on = ns:ToggleFavorite(id)
    if list and frame and frame:IsShown() then list:Refresh() end
    updateFavButton()
    return on
end

---------------------------------------------------------------------------
-- Status / header
---------------------------------------------------------------------------
local function updateStatus()
    local db, learned = 0, 0
    for _ in pairs(GearGuide_Data.items) do db = db + 1 end
    for id in pairs(GearGuideLearned.items) do
        if not GearGuide_Data.items[id] then learned = learned + 1 end
    end
    local scanned = 0
    for _ in pairs(GearGuideHarvest.items) do scanned = scanned + 1 end
    local meta = GearGuide_Data.meta or {}
    local parts = {}
    if ns.dataExpired then
        parts[#parts + 1] = "API data expired (older than 30 days, re-run the updater)"
    elseif db > 0 and meta.source ~= "client" then
        -- Blizzard Developer API terms: identify Blizzard as the data source without implying endorsement.
        parts[#parts + 1] = string.format("Item data: Blizzard Battle.net API (not endorsed by Blizzard), %d items, %s",
            db, tostring(meta.generated or "?"))
    elseif db > 0 then
        parts[#parts + 1] = string.format("Database: %d items (%s%s)", db, tostring(meta.version or meta.generated or "?"),
            ns.dbOutdated and ", older game build" or "")
    end
    if scanned > 0 then parts[#parts + 1] = string.format("scanned: %d", scanned) end
    parts[#parts + 1] = string.format("learned in game: %d", learned)
    if db == 0 and scanned == 0 then parts[#parts + 1] = "type /gg scan to build the database" end
    W.status:SetText(table.concat(parts, DOT))
    if W.shareBtn then
        local on = ns.IsSharingEnabled and ns:IsSharingEnabled()
        W.shareBtn:SetText(on and "Sharing: On" or "Sharing: Off")
        if W.shareBtn.SetActive then W.shareBtn:SetActive(on) end
    end
end

local function updateHeader()
    W.specDD:Refresh()
    W.miniBtn:SetActive(GearGuideDB.mini and GearGuideDB.mini.shown)
    W.recTab:SetActive(state.tab == "recommended")
    W.browseTab:SetActive(state.tab == "browser")
end

local function updateColHeader()
    -- The list shows its scrollbar (and narrows its rows) when the rows don't all fit.
    local h = list.frame:GetHeight() or 0
    local barShown = h > 0 and #state.data > math.floor(h / ROW_H + 0.001)
    W.colHeader:SetPoint("TOPRIGHT", W.listBox, "TOPRIGHT", barShown and -9 or -1, -1)
    W.colHeader.score:SetText(state.tab == "recommended" and "Score / gain" or "Score")
    applyColumns(W.colHeader, W.colHeader:GetWidth())
end

---------------------------------------------------------------------------
-- Browser filter bar
---------------------------------------------------------------------------
local filterTimer

local function filterChanged()
    if filterTimer then filterTimer:Cancel(); filterTimer = nil end
    state.resetScroll = true
    ns:RefreshUI()
end

local function scheduleFilter()
    if filterTimer then filterTimer:Cancel() end
    filterTimer = C_Timer.NewTimer(0.25, function()
        filterTimer = nil
        filterChanged()
    end)
end

-- Lays the browser controls out left to right, wrapping into more rows when narrow.
local function layoutBrowseBar()
    local bar = W.browseBar
    local width = bar:GetWidth() or 0
    if width <= 0 then return end
    W.search:SetWidth(math.max(110, math.min(240, math.floor(width * 0.3))))
    local x, y, rowH, gap = 0, 0, 32, ns.Skin.GAP
    for _, it in ipairs(W.flow) do
        local w = it.width and it.width() or it.f:GetWidth()
        if x > 0 and x + w > width then x = 0; y = y + rowH end
        it.f:ClearAllPoints()
        it.f:SetPoint("TOPLEFT", bar, "TOPLEFT", x, -(y + (it.yo or 0)))
        x = x + w + gap + (it.extra or 0)
    end
    bar:SetHeight(y + ns.Skin.CONTROL_H)
end

local function syncBrowserControls()
    local f = state.filter
    W.search:SetText(f.text or "")
    W.minBox:SetText(f.minL and tostring(f.minL) or "")
    W.maxBox:SetText(f.maxL and tostring(f.maxL) or "")
    W.classSel:Refresh(); W.specSel:Refresh(); W.slotSel:Refresh()
    W.qualitySel:Refresh(); W.sortSel:Refresh()
    W.usableCb:SetChecked(f.usable)
    W.hideCb:SetChecked(f.hideDone)
    W.favCb:SetChecked(f.favOnly)
end

local function createBrowseBar(parent)
    local Skin = ns.Skin
    local f = state.filter
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(46)
    W.browseBar = bar

    local search = Skin:EditBox(bar, 160)
    search:SetPlaceholder("Search items...")
    search:HookScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        f.text = self:GetText() or ""
        scheduleFilter()
    end)
    W.search = search

    W.classSel = Skin:Dropdown(bar, 112, {
        getItems = function()
            local out = {}
            for _, c in ipairs(ns.CLASS_LIST) do
                local icon, coords = classIcon(c)
                out[#out + 1] = { value = c, text = classLabel(c), icon = icon, iconCoords = coords }
            end
            return out
        end,
        getValue = function() return f.class or ns:GetPlayerClass() end,
        onSelect = function(class)
            if class == f.class then return end
            f.class = class
            f.spec = nil  -- back to the default spec for the new class
            W.specSel:Refresh()
            filterChanged()
        end,
        tooltip = { "Class", "Class to browse and score gear for." },
    })

    W.specSel = Skin:Dropdown(bar, 128, {
        getItems = function() return specItems(f.class or ns:GetPlayerClass()) end,
        getValue = browseSpec,
        onSelect = function(key)
            f.spec = key
            local sel = state.selected
            if sel and sel.class == (f.class or ns:GetPlayerClass()) then sel.spec = key end
            filterChanged()
        end,
        tooltip = { "Specialization", "Spec used to score gear for the browsed class." },
    })

    W.slotSel = Skin:Dropdown(bar, 100, {
        getItems = function()
            local out = { { value = 0, text = "All slots" } }
            for i, g in ipairs(ns.SLOT_GROUPS) do
                out[#out + 1] = { value = i, text = g.label, icon = slotTexture(g.key) }
            end
            return out
        end,
        getValue = function() return f.slot end,
        onSelect = function(v) f.slot = v; filterChanged() end,
        maxVisible = 12,
        tooltip = { "Equipment slot" },
    })

    -- Level range group: "Level [min] – [max]"
    local lvl = CreateFrame("Frame", nil, bar)
    lvl:SetSize(118, 24)
    local lbl = Skin:Text(lvl, Skin.SIZE.small, "textDim")
    lbl:SetPoint("LEFT", 0, 0)
    lbl:SetText("Level")
    local minBox = Skin:EditBox(lvl, 34, true)
    minBox:SetMaxLetters(2)
    minBox:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    local dash = Skin:Text(lvl, Skin.SIZE.small, "textDim")
    dash:SetPoint("LEFT", minBox, "RIGHT", 4, 0)
    dash:SetText(DASH)
    local maxBox = Skin:EditBox(lvl, 34, true)
    maxBox:SetMaxLetters(2)
    maxBox:SetPoint("LEFT", dash, "RIGHT", 4, 0)
    local function onLevelChanged(_, userInput)
        if not userInput then return end
        f.userLevel = true  -- stop following the player's level once edited by hand
        f.minL = tonumber(minBox:GetText())
        f.maxL = tonumber(maxBox:GetText())
        scheduleFilter()
    end
    minBox:HookScript("OnTextChanged", onLevelChanged)
    maxBox:HookScript("OnTextChanged", onLevelChanged)
    minBox:SetScript("OnTabPressed", function() maxBox:SetFocus() end)
    maxBox:SetScript("OnTabPressed", function() minBox:SetFocus() end)
    W.minBox, W.maxBox, W.lvlGroup = minBox, maxBox, lvl

    W.qualitySel = Skin:Dropdown(bar, 100, {
        getItems = function()
            local out = {}
            for i, q in ipairs(QUALITIES) do
                local hex = q.q >= 1 and ns.QualityHex(q.q) or ""
                out[i] = { value = i, text = hex .. q.label .. (hex ~= "" and "|r" or "") }
            end
            return out
        end,
        getValue = function() return f.quality end,
        onSelect = function(v) f.quality = v; filterChanged() end,
        tooltip = { "Minimum item quality" },
    })

    W.sortSel = Skin:Dropdown(bar, 100, {
        getItems = function()
            local out = {}
            for i, label in ipairs(SORTS) do out[i] = { value = i, text = label } end
            return out
        end,
        getValue = function() return f.sort end,
        onSelect = function(v) f.sort = v; filterChanged() end,
        prefix = "Sort",
        tooltip = { "Sort order" },
    })

    W.usableCb = Skin:Checkbox(bar, "Usable only")
    W.usableCb.onToggle = function(_, checked) f.usable = checked; filterChanged() end
    W.hideCb = Skin:Checkbox(bar, "Hide acquired")
    W.hideCb.onToggle = function(_, checked) f.hideDone = checked; filterChanged() end
    W.favCb = Skin:Checkbox(bar, "Favorites only")
    W.favCb.onToggle = function(_, checked) f.favOnly = checked; filterChanged() end

    W.count = Skin:Text(bar, Skin.SIZE.small, "textDim")
    W.count:SetWidth(80)
    W.count:SetWordWrap(false)

    -- All controls are 24px tall; yo centers the count text on the line.
    W.flow = {
        { f = search },
        { f = W.classSel }, { f = W.specSel }, { f = W.slotSel },
        { f = lvl },
        { f = W.qualitySel }, { f = W.sortSel },
        { f = W.usableCb }, { f = W.hideCb }, { f = W.favCb },
        { f = W.count, yo = 6, width = function() return 80 end },
    }
    bar:SetScript("OnSizeChanged", layoutBrowseBar)
    return bar
end

-- The Recommended tab has no filter bar: an empty 1px anchor keeps applyTab simple.
local function createRecBar(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(1)
    W.recBar = bar
    return bar
end

-- Window subtitle: "<Class> · <Spec> (<role>) · req. level X–Y" (same range as the recommendations).
local function updateSubtitle()
    if not frame.subtitle then return end
    local class = ns:GetPlayerClass()
    local spec = ns:GetSpecInfo(class, ns:GetPlayerSpec())
    local level = UnitLevel("player")
    local minL = math.max(1, level - (GearGuideDB.levelBehind or 5))
    local maxL = level + (GearGuideDB.levelAhead or 3)
    frame.subtitle:SetText(classLabel(class) .. DOT .. (spec and spec.label or "?")
        .. " (" .. roleLabel(spec and spec.role) .. ")" .. DOT
        .. string.format("req. level %d%s%d", minL, DASH, maxL))
end

---------------------------------------------------------------------------
-- Tabs
---------------------------------------------------------------------------
local function applyTab(tab)
    state.tab = (tab == "browser") and "browser" or "recommended"
    local active = state.tab == "browser" and W.browseBar or W.recBar
    W.recBar:SetShown(state.tab == "recommended")
    W.browseBar:SetShown(state.tab == "browser")
    W.listBox:ClearAllPoints()
    W.listBox:SetPoint("TOPLEFT", active, "BOTTOMLEFT", 0, state.tab == "browser" and -4 or -1)
    W.listBox:SetPoint("BOTTOMRIGHT", W.left, "BOTTOMRIGHT", 0, 0)
    W.recTab:SetActive(state.tab == "recommended")
    W.browseTab:SetActive(state.tab == "browser")
    if state.tab == "browser" then layoutBrowseBar() end
    state.resetScroll = true
end

local function setTab(tab)
    applyTab(tab)
    ns:RefreshUI()
end

---------------------------------------------------------------------------
-- Window construction
---------------------------------------------------------------------------
local function clampSize(w, h)
    w = math.max(MIN_W, math.min(MAX_W, tonumber(w) or 760))
    h = math.max(MIN_H, math.min(MAX_H, tonumber(h) or 480))
    return w, h
end

local function savePosition(f)
    local db = GearGuideDB.window
    local point, _, relPoint, x, y = f:GetPoint(1)
    if point then
        db.point, db.relPoint, db.x, db.y = point, relPoint, x, y
    end
end

local function saveSize(f)
    local db = GearGuideDB.window
    db.w = math.floor(f:GetWidth() + 0.5)
    db.h = math.floor(f:GetHeight() + 0.5)
    savePosition(f)
end

local function createDetail(content)
    local Skin = ns.Skin
    local detail = Skin:Panel(content, "panel", "border")
    detail:SetWidth(DETAIL_W)
    detail:SetPoint("TOPRIGHT", W.tabStrip, "BOTTOMRIGHT", 0, -GAP)
    detail:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, FOOTER_H + 6)
    W.detail = detail

    local icon = CreateFrame("Button", nil, detail, "BackdropTemplate")
    icon:SetSize(40, 40)
    icon:SetPoint("TOPLEFT", 8, -8)
    Skin:SetBackdrop(icon, "bg", "borderStrong")
    local tex = icon:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", 1, -1)
    tex:SetPoint("BOTTOMRIGHT", -1, 1)
    tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    W.icon, W.iconTex = icon, tex
    icon:SetScript("OnEnter", function(self)
        local sel = state.selected
        if not sel then return end
        ns:ShowItemTooltip(self, sel.id, { class = sel.class })
    end)
    icon:SetScript("OnLeave", hideTooltip)
    icon:SetScript("OnClick", function()
        if state.selected then handleModifiedClick(itemLink(state.selected.id)) end
    end)

    local name = Skin:Text(detail, Skin.SIZE.header, "text")
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    name:SetPoint("RIGHT", detail, "RIGHT", -8, 0)
    name:SetWordWrap(true)
    if name.SetMaxLines then name:SetMaxLines(2) end
    W.dName = name

    -- Favorite toggle under the icon/name (star + label; accent "active" look when favorited).
    local fav = Skin:Button(detail, "Favorite", 112, Skin.CONTROL_H)
    fav:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -8)
    fav.star = fav:CreateTexture(nil, "OVERLAY")
    fav.star:SetSize(14, 14)
    fav.star:SetPoint("LEFT", 10, 0)
    fav.star:SetTexture(Skin.STAR)
    fav.text:ClearAllPoints()
    fav.text:SetPoint("LEFT", fav.star, "RIGHT", 4, 0)
    fav.text:SetPoint("RIGHT", -10, 0)
    fav:SetScript("OnMouseDown", nil)  -- keep the label anchored next to the star
    fav:SetScript("OnMouseUp", nil)
    fav:SetScript("OnClick", function()
        if state.selected then toggleFavorite(state.selected.id) end
    end)
    fav:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Favorite", 1, 1, 1)
        GameTooltip:AddLine("Favorites are listed first on the Recommended tab and in the mini tracker.",
            0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    fav:SetScript("OnLeave", hideTooltip)
    fav:Hide()
    W.favBtn = fav

    local sf = CreateFrame("ScrollFrame", nil, detail)
    sf:SetPoint("TOPLEFT", fav, "BOTTOMLEFT", 0, -8)
    sf:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -12, 8)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(BODY_W, 1)
    sf:SetScrollChild(child)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local maxScroll = math.max(0, child:GetHeight() - self:GetHeight())
        local v = math.max(0, math.min(maxScroll, self:GetVerticalScroll() - delta * 28))
        self:SetVerticalScroll(v)
        updateBodyBar()
    end)
    sf:SetScript("OnSizeChanged", updateBodyBar)
    W.bodyScroll, W.bodyChild = sf, child

    local bar = detail:CreateTexture(nil, "ARTWORK")
    bar:SetColorTexture(rgba("thumb"))
    bar:Hide()
    W.bodyBar = bar

    local empty = Skin:Text(detail, Skin.SIZE.normal, "textDim")
    empty:SetPoint("LEFT", 16, 0)
    empty:SetPoint("RIGHT", -16, 0)
    empty:SetJustifyH("CENTER")
    empty:SetWordWrap(true)
    empty:SetText("Select an item in the list to see its stats and where to get it.")
    W.detailEmpty = empty
end

local function createListBox(left)
    local Skin = ns.Skin
    local box = Skin:Panel(left, "listBg", "border")  -- darker than the rows: shows in the gaps
    W.listBox = box

    local ch = CreateFrame("Frame", nil, box)
    ch:SetHeight(16)
    ch:SetPoint("TOPLEFT", box, "TOPLEFT", 1, -1)
    ch:SetPoint("TOPRIGHT", box, "TOPRIGHT", -1, -1)
    local chBg = ch:CreateTexture(nil, "BACKGROUND")
    chBg:SetAllPoints()
    chBg:SetColorTexture(rgba("header"))
    makeColumns(ch, Skin.SIZE.small, 5)  -- "Item" spans the bar, icon and name columns
    ch.kind = "colheader"
    ch.name:SetShadowColor(0, 0, 0, 0.85)
    for _, k in ipairs({ "mark", "name", "slot", "lvl", "score", "source" }) do
        ch[k]:SetTextColor(rgba("textDim"))
    end
    ch.name:SetText("Item")
    ch.slot:SetText("Slot")
    ch.lvl:SetText("Req")
    ch.score:SetText("Score")
    ch.source:SetText("Source")
    local chStar = ch:CreateTexture(nil, "ARTWORK")  -- column hint for the favorite stars
    chStar:SetSize(12, 12)
    chStar:SetPoint("RIGHT", ch, "RIGHT", -8, 0)
    chStar:SetTexture(Skin.STAR)
    Skin:StyleStar(chStar, false, true)
    ch:SetScript("OnSizeChanged", function(self, w) applyColumns(self, w) end)
    local line = Skin:Divider(ch, "border")
    line:SetPoint("BOTTOMLEFT")
    line:SetPoint("BOTTOMRIGHT")
    W.colHeader = ch

    list = Skin:List(box, {
        rowHeight = ROW_H,
        rowGap = ROW_GAP,
        barRows = true,
        createRow = createRow,
        fillRow = fillRow,
        onClick = rowOnClick,
        onEnter = rowOnEnter,
        onLeave = rowOnLeave,
    })
    list.frame:SetPoint("TOPLEFT", ch, "BOTTOMLEFT", 0, -ROW_GAP)
    list.frame:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -1, 1)
    list.frame:HookScript("OnSizeChanged", function() updateColHeader() end)
    if frame.watermark then
        frame.watermark:ClearAllPoints()
        frame.watermark:SetPoint("CENTER", box, "CENTER", 0, 0)
        box:HookScript("OnSizeChanged", function(_, w, h)
            local size = math.max(120, math.min(320, math.floor(math.min(w or 0, h or 0) * 0.7)))
            frame.watermark:SetSize(size, size)
        end)
    end
    list:SetSelected(isSelected)
end

local function createWindow()
    if frame then return end
    local Skin = ns.Skin
    local db = GearGuideDB.window
    local w, h = clampSize(db.w, db.h)

    frame = Skin:CreateWindow("GearGuideFrame", {
        title = "GearGuide", subtitle = "", titleSize = 17, headerHeight = 40,
        watermark = "Interface\\AddOns\\GearGuide\\Media\\logo", watermarkAlpha = 0.22, vignette = 140,
        width = w, height = h, onMoved = savePosition, escClose = true,
    })
    if UISpecialFrames then
        local found = false
        for _, n in ipairs(UISpecialFrames) do if n == "GearGuideFrame" then found = true end end
        if not found then tinsert(UISpecialFrames, "GearGuideFrame") end
    end
    if db.point then
        frame:ClearAllPoints()
        frame:SetPoint(db.point, UIParent, db.relPoint or db.point, db.x or 0, db.y or 0)
    end
    frame:Hide()
    Skin:ResizeGrip(frame, MIN_W, MIN_H, MAX_W, MAX_H, saveSize)

    -- Header: title / dim subtitle (class · spec · level range) ........ Mini | Spec | x
    local header = frame.header

    -- The player's spec: drives the Recommended tab and the mini tracker.
    W.specDD = Skin:Dropdown(header, 184, {
        getItems = function()
            local items = {}
            local detected = ns:GetSpecInfo(nil, ns:DetectPlayerSpec())
            items[1] = { value = "AUTO", text = "Auto (" .. (detected and detected.label or "?") .. ")",
                icon = detected and detected.icon, note = "from talents" }
            for _, it in ipairs(specItems(ns:GetPlayerClass())) do items[#items + 1] = it end
            return items
        end,
        getValue = function() return ns:IsSpecAuto() and "AUTO" or ns:GetPlayerSpec() end,
        onSelect = function(key)
            ns:SetPlayerSpec(key)  -- refreshes the window and the mini tracker (debounced)
        end,
        prefix = "Spec",
        tooltip = { "Your specialization", "Used to score the Recommended tab and the mini tracker. "
            .. "Auto follows your talents." },
    })
    W.specDD:SetPoint("RIGHT", frame.closeButton, "LEFT", -Skin.GAP, 0)

    W.miniBtn = Skin:Button(header, "Mini")  -- text + 10px padding, 24px tall
    W.miniBtn:SetPoint("RIGHT", W.specDD, "LEFT", -Skin.GAP, 0)
    W.miniBtn:SetScript("OnClick", function(self)
        ns:ToggleMini()
        self:SetActive(GearGuideDB.mini and GearGuideDB.mini.shown)
    end)
    W.miniBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Toggle the compact top-picks window", 1, 1, 1)
        GameTooltip:Show()
    end)
    W.miniBtn:SetScript("OnLeave", hideTooltip)
    frame.subtitle:SetPoint("RIGHT", W.miniBtn, "LEFT", -10, -8)  -- truncates instead of overlapping

    local content = frame.content

    -- Tab strip under the header: text tabs with a copper underline on the active one.
    local strip = CreateFrame("Frame", nil, content)
    strip:SetHeight(30)
    strip:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    strip:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    local stripLine = Skin:Divider(strip, "edge")
    stripLine:SetPoint("BOTTOMLEFT")
    stripLine:SetPoint("BOTTOMRIGHT")
    stripLine:SetAlpha(0.5)
    W.tabStrip = strip
    W.recTab = Skin:Tab(strip, "Recommended", 30)
    W.recTab:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", 0, 0)
    W.recTab:SetScript("OnClick", function() setTab("recommended") end)
    W.browseTab = Skin:Tab(strip, "Gear Browser", 30)
    W.browseTab:SetPoint("LEFT", W.recTab, "RIGHT", 6, 0)
    W.browseTab:SetScript("OnClick", function() setTab("browser") end)

    -- Footer
    -- Opt-out for in-game source sharing (Comm.lua)
    -- 24px tall; kept clear of the window's resize grip in the bottom-right corner.
    W.shareBtn = Skin:Button(content, "Sharing: Off", 104, Skin.CONTROL_H)
    W.shareBtn:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -14, 0)
    W.shareBtn:SetScript("OnClick", function() ns:SetSharing(not ns:IsSharingEnabled()) end)
    W.shareBtn:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("Source sharing")
        GameTooltip:AddLine("Shares item sources you discover (which creature, quest or vendor gives an item) "
            .. "with GearGuide users in your guild and group, and receives theirs. Invisible, no chat messages, "
            .. "no character data.", 1, 1, 1, true)
        GameTooltip:AddLine("Click to turn " .. (ns:IsSharingEnabled() and "off" or "on") .. ".", 0.4, 1, 0.6)
        GameTooltip:Show()
    end)
    W.shareBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
    W.status = Skin:Text(content, Skin.SIZE.small, "textDim")
    W.status:SetPoint("LEFT", content, "BOTTOMLEFT", 2, FOOTER_H / 2)
    W.status:SetPoint("RIGHT", W.shareBtn, "LEFT", -Skin.GAP - 4, 0)
    W.status:SetWordWrap(false)

    createDetail(content)

    local left = CreateFrame("Frame", nil, content)
    left:SetPoint("TOPLEFT", W.tabStrip, "BOTTOMLEFT", 0, -GAP)
    left:SetPoint("BOTTOMRIGHT", W.detail, "BOTTOMLEFT", -GAP, 0)
    W.left = left

    local recBar = createRecBar(left)
    recBar:SetPoint("TOPLEFT", left, "TOPLEFT")
    recBar:SetPoint("TOPRIGHT", left, "TOPRIGHT")
    local browseBar = createBrowseBar(left)
    browseBar:SetPoint("TOPLEFT", left, "TOPLEFT")
    browseBar:SetPoint("TOPRIGHT", left, "TOPRIGHT")

    createListBox(left)

    W.flashDriver = CreateFrame("Frame", nil, frame)
    W.flashDriver:Hide()
    W.flashDriver:SetScript("OnUpdate", updateFlash)

    -- Browser defaults: player's class, level range around the player.
    local f = state.filter
    local level = UnitLevel("player")
    f.class = ns:GetPlayerClass()
    f.minL = math.max(1, level - 5)
    f.maxL = math.min(maxLevel(), level + 5)
    f.rangeLevel = level
    syncBrowserControls()

    frame:HookScript("OnShow", function() ns:RefreshUI() end)
    frame:HookScript("OnHide", function()
        if filterTimer then filterTimer:Cancel(); filterTimer = nil end
        hideTooltip()
        for k in pairs(pendingIcons) do pendingIcons[k] = nil end
    end)

    applyTab("recommended")
    updateDetail()
end

---------------------------------------------------------------------------
-- Making sure an item is visible in the browser (used by ShowItem)
---------------------------------------------------------------------------
local function revealInBrowser(id, item)
    local f = state.filter
    local pclass = ns:GetPlayerClass()
    local level = UnitLevel("player")
    if f.text ~= "" and not (item.n and item.n:lower():find(f.text:lower(), 1, true)) then f.text = "" end
    local key = ns.EQUIPLOC_GROUP[item.eq]
    if f.slot > 0 and ns.SLOT_GROUPS[f.slot].key ~= key then f.slot = 0 end
    local eff = ns.EffectiveLevel(item)
    if f.minL and eff < f.minL then f.minL = eff end
    if f.maxL and eff > f.maxL then f.maxL = eff end
    if (item.q or 1) < QUALITIES[f.quality].q then f.quality = 1 end
    if f.usable and not ns:IsUsable(item, f.class, level) then
        if f.class ~= pclass and ns:IsUsable(item, pclass, level) then
            f.class, f.spec = pclass, nil
        else
            f.usable = false
        end
    end
    if f.hideDone and ns:GetCompletion(id, f.class) == "done" then f.hideDone = false end
    if f.favOnly and not ns:IsFavorite(id) then f.favOnly = false end
    syncBrowserControls()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
function ns:RefreshUI()
    if not frame or not frame:IsShown() then return end
    -- Browser level range follows level-ups until the user edits it.
    local f, level = state.filter, UnitLevel("player")
    if not f.userLevel and f.rangeLevel ~= level then
        f.minL = math.max(1, level - 5)
        f.maxL = math.min(maxLevel(), level + 5)
        f.rangeLevel = level
        syncBrowserControls()
    end
    updateHeader()
    updateSubtitle()
    W.classSel:Refresh()
    W.specSel:Refresh()  -- follows the player's spec when browsing their own class
    local data
    if state.tab == "recommended" then
        data = buildRecommendedRows()
    else
        data = buildBrowserRows()
    end
    state.data = data
    list:SetData(data)
    list:SetSelected(isSelected)
    if state.resetScroll then
        state.resetScroll = false
        list:ScrollToTop()
    end
    updateColHeader()
    updateStatus()
    updateDetail()
end

function ns:ShowWindow(tab)
    createWindow()
    applyTab(tab == "browser" and "browser" or "recommended")
    if frame:IsShown() then
        self:RefreshUI()
    else
        frame:Show() -- OnShow refreshes
    end
end

function ns:ToggleWindow()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:ShowWindow("recommended")
    end
end

function ns:ShowItem(id)
    id = ns.LinkToId(id)
    if not id then return end
    createWindow()
    local item = self:GetItem(id)

    local inRec = false
    for _, g in ipairs(self:BuildRecommendations().groups) do
        for _, p in ipairs(g.picks) do
            if p.id == id then inRec = true break end
        end
        if inRec then break end
    end

    -- Favorites are listed in the Recommended tab's Favorites section.
    if inRec or (item and self:IsFavorite(id)) then
        applyTab("recommended")
        state.selected = { id = id, class = self:GetPlayerClass() }  -- spec nil = player's spec
    else
        if item then revealInBrowser(id, item) end
        applyTab("browser")
        state.selected = { id = id, class = state.filter.class, spec = browseSpec() }
    end
    W.bodyScroll:SetVerticalScroll(0)

    if frame:IsShown() then
        self:RefreshUI()
    else
        frame:Show() -- OnShow refreshes
    end

    local idx = findIndex(id)
    if idx then
        list:ScrollToIndex(idx)
        flash(id)
    end
end
