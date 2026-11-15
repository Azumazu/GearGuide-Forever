local _, ns = ...

-- "Gear Acquired" pop-up: when the player gets an item that GearGuide currently recommends (an
-- upgrade pick for their spec) or that they favorited, a row in the mini tracker's style slides in
-- near the top of the screen for a few seconds. Several at once queue up.
-- Fed by Tracking.lua (ns:OnGearAcquired(ids) with the item IDs whose owned count just went up).
-- Unless locked (Settings), it can be dragged anywhere and made wider or narrower with its corner
-- grip; Settings also scales it and shows a preview to place it with.
-- Public: ns:OnGearAcquired(ids), ns:ShowGearToast(id), ns:PreviewGearToast(), ns:ApplyToastLayout()

local MIN_W, MAX_W = 200, 560
local ROW_H = 30
local TITLE_H = 18
local SHOW_SECONDS = 4.5
local FADE_SECONDS = 0.4
local FONT_SIZE = 12

local frame, row, grip
local queue = {}
local showing = false

local function db() return GearGuideDB.toast end

local function savePosition()
    local p, _, rp, x, y = frame:GetPoint(1)
    db().point = { p, rp, x, y }
    db().w = math.floor(frame:GetWidth() + 0.5)
end

-- Size, scale, position and lock from the settings.
function ns:ApplyToastLayout()
    if not frame then return end
    local d = db()
    frame:SetScale(tonumber(d.scale) or 1)
    frame:SetWidth(math.max(MIN_W, math.min(MAX_W, tonumber(d.w) or 300)))
    frame:ClearAllPoints()
    local pt = d.point
    if type(pt) == "table" and pt[1] then
        frame:SetPoint(pt[1], UIParent, pt[2] or pt[1], tonumber(pt[3]) or 0, tonumber(pt[4]) or 0)
    else
        frame:SetPoint("TOP", UIParent, "TOP", 0, -150)
    end
    local locked = d.locked and true or false
    frame:EnableMouse(true)  -- clicks and tooltips work either way
    frame:SetMovable(not locked)
    if grip then grip:SetShown(not locked) end
    if frame.border then frame.border:SetShown(not locked and frame.preview or false) end
end

local function slotText(item)
    return item and item.eq and ns.SlotLabel and ns.SlotLabel(item.eq) or ""
end

local function create()
    if frame then return end
    local Skin = ns.Skin
    frame = CreateFrame("Button", "GearGuideToastFrame", UIParent)
    frame:SetSize(300, TITLE_H + ROW_H + 8)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not db().locked then self.dragging = true; self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        if not self.dragging then return end
        self.dragging = false
        self:StopMovingOrSizing()
        savePosition()
    end)
    frame:Hide()

    -- Dim outline while previewing unlocked: shows the area you can drag.
    frame.border = Skin:Panel(frame, "panel", "accent")
    frame.border:SetAllPoints()
    frame.border:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
    frame.border:SetAlpha(0.6)
    frame.border:Hide()

    frame.title = Skin:Text(frame, Skin.SIZE.header, "accent")
    frame.title:SetPoint("TOP", frame, "TOP", 0, -2)
    frame.title:SetText("Gear Acquired")
    frame.title:SetShadowColor(0, 0, 0, 1)
    frame.title:SetShadowOffset(1, -1)

    row = CreateFrame("Frame", nil, frame)
    row:SetHeight(ROW_H)
    row:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -(TITLE_H + 4))
    row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -(TITLE_H + 4))
    Skin:BarRow(row, ROW_H)   -- quality bar, full-height icon, dark gradient (same as the mini rows)
    local x = row.barContentX or (ROW_H + 11)

    row.slot = Skin:Text(row, 10, "textDim")
    row.slot:SetPoint("RIGHT", row, "RIGHT", -6, 0)
    row.slot:SetJustifyH("RIGHT")

    row.star = row:CreateTexture(nil, "OVERLAY")
    row.star:SetSize(12, 12)
    row.star:SetPoint("LEFT", row, "LEFT", x - 2, 0)
    row.star:SetTexture(Skin.STAR)

    row.name = Skin:Text(row, FONT_SIZE + 1)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.name:SetShadowColor(0, 0, 0, 1)
    row.name:SetPoint("RIGHT", row.slot, "LEFT", -6, 0)
    row.contentX = x

    -- Width only (the row height is fixed; Settings has a scale for overall size).
    local h = TITLE_H + ROW_H + 8
    grip = Skin:ResizeGrip(frame, MIN_W, h, MAX_W, h, function() savePosition() end)

    -- Left-click: show the item in the GearGuide window. Right-click: dismiss.
    frame:SetScript("OnClick", function(self, button)
        if button == "LeftButton" and self.itemID and not self.preview then ns:ShowItem(self.itemID) end
        self.preview = false
        self.elapsed = SHOW_SECONDS  -- start fading out now
    end)
    frame:SetScript("OnEnter", function(self)
        self.hovered = true
        self:SetAlpha(1)
        if self.itemID then
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. self.itemID)
            if not ok then GameTooltip:AddLine(row.name:GetText() or "") end
            GameTooltip:Show()
        end
    end)
    frame:SetScript("OnLeave", function(self)
        self.hovered = false
        GameTooltip:Hide()
    end)

    -- Fade in, hold (paused while the mouse is over it), fade out, then the next queued item.
    frame:SetScript("OnUpdate", function(self, dt)
        if self.hovered or self.dragging or self.preview or (grip and grip.sizing) then self:SetAlpha(1) return end
        self.elapsed = (self.elapsed or 0) + dt
        local t = self.elapsed
        if t < FADE_SECONDS then
            self:SetAlpha(t / FADE_SECONDS)
        elseif t < SHOW_SECONDS then
            self:SetAlpha(1)
        elseif t < SHOW_SECONDS + FADE_SECONDS then
            self:SetAlpha(1 - (t - SHOW_SECONDS) / FADE_SECONDS)
        else
            self:Hide()
            showing = false
            local nextId = table.remove(queue, 1)
            if nextId then ns:ShowGearToast(nextId) end
        end
    end)
end

local function fill(id, favorite)
    local item = ns:GetItem(id) or {}
    row:SetBarQuality(item.q)
    row:SetBarIcon(ns.ItemIcon(id))
    row.star:SetShown(favorite)
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", row, "LEFT", row.contentX + (favorite and 13 or 0), 0)
    row.name:SetPoint("RIGHT", row.slot, "LEFT", -6, 0)
    row.name:SetText(item.n or ns.GetItemInfo(id) or ("item:" .. id))
    row.slot:SetText(slotText(item))
end

function ns:ShowGearToast(id)
    create()
    if showing then
        queue[#queue + 1] = id
        return
    end
    showing = true
    frame.itemID = id
    frame.elapsed = 0
    frame.hovered = false
    frame.preview = false
    self:ApplyToastLayout()
    fill(id, self:IsFavorite(id))
    frame:SetAlpha(0)
    frame:Show()
    if PlaySound then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.UI_EPICLOOT_TOAST) or 31578) end
end

-- ids: items whose owned count just went up. Shows the ones currently recommended or favorited.
function ns:OnGearAcquired(ids)
    if GearGuideDB and GearGuideDB.toast and GearGuideDB.toast.shown == false then return end
    local wanted
    for _, id in ipairs(ids) do
        if self:IsFavorite(id) then
            self:ShowGearToast(id)
        else
            if not wanted then
                wanted = {}
                local ok, rec = pcall(self.BuildRecommendations, self)
                for _, g in ipairs(ok and rec and rec.groups or {}) do
                    for _, p in ipairs(g.picks) do wanted[p.id] = true end
                end
            end
            if wanted[id] then self:ShowGearToast(id) end
        end
    end
end

-- Settings: shows a sample that stays until clicked, to move and size the pop-up.
function ns:PreviewGearToast()
    create()
    local id
    for _, f in ipairs(self:GetFavorites() or {}) do id = id or (type(f) == "table" and f.id or f) end
    if not id then
        local ok, rec = pcall(self.BuildRecommendations, self)
        for _, g in ipairs(ok and rec and rec.groups or {}) do id = id or (g.picks[1] and g.picks[1].id) end
    end
    id = id or self:AllItemIds()[1]
    if not id then return end
    showing = true
    frame.itemID = id
    frame.elapsed = 0
    frame.preview = true
    fill(id, self:IsFavorite(id))
    frame:Show()
    self:ApplyToastLayout()
    frame:SetAlpha(1)
end
