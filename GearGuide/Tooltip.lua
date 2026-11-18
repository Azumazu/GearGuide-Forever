local _, ns = ...

-- Shared item tooltip used by the main window and the mini UI:
-- the game's own item tooltip, then score, completion and where to get it.

local READY = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"

-- Inline status marker: check for done, "1/2" for partially acquired, "" otherwise.
function ns:CompletionMarkup(id, class)
    local state, have, need = self:GetCompletion(id, class or self:GetPlayerClass())
    if state == "done" then
        return READY
    elseif state == "partial" then
        return string.format("%s%d/%d|r", ns.Skin:Hex("partial"), have, need)
    end
    return ""
end

-- Uncached items show an empty tooltip; remember the request and redraw when the data arrives.
local pendingTip
local tipEvents = CreateFrame("Frame")
tipEvents:RegisterEvent("GET_ITEM_INFO_RECEIVED")
tipEvents:SetScript("OnEvent", function(_, _, itemID)
    local p = pendingTip
    if p and p.id == itemID then
        pendingTip = nil
        if GameTooltip:IsOwned(p.owner) then ns:ShowItemTooltip(p.owner, p.id, p.info) end
    end
end)

-- Puts the tooltip just outside `outer` (e.g. the whole mini tracker), level with `owner`'s top,
-- on whichever side of the screen has more room. A plain ANCHOR_LEFT/RIGHT on a row near the
-- screen edge gets pushed back on screen by the client, right over the frame it describes.
local function anchorBeside(tip, owner, outer)
    tip:SetOwner(owner, "ANCHOR_NONE")
    tip:ClearAllPoints()
    local scale = outer:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local cx = (outer:GetCenter() or 0) * scale
    local gap = 4
    -- The distances are measured in the owner's units; the offset is in the tooltip's (they differ
    -- when the owner is scaled, e.g. the mini tracker's scale setting).
    local k = (owner:GetEffectiveScale() or 1) / (tip:GetEffectiveScale() or 1)
    if cx < UIParent:GetWidth() / 2 then
        tip:SetPoint("TOPLEFT", owner, "TOPRIGHT", ((outer:GetRight() or 0) - (owner:GetRight() or 0)) * k + gap, 0)
    else
        tip:SetPoint("TOPRIGHT", owner, "TOPLEFT", ((outer:GetLeft() or 0) - (owner:GetLeft() or 0)) * k - gap, 0)
    end
end

-- Puts the (already filled and shown, so its size is known) tooltip beside the mouse cursor, once
-- per hovered row. Always the same rule, so it never jumps around: right of and below the cursor;
-- left of it only if it would run off the right screen edge, above it only if it would run off
-- the bottom. It stays put while the mouse moves along the row.
local CURSOR_GAP = 16
local cursorSpot  -- { owner, point, x, y } of the current cursor tooltip (kept when it is re-shown)
local function placeAtCursor(tip, owner)
    local s = UIParent:GetEffectiveScale()
    local ts = tip:GetEffectiveScale() or 1
    local k = s / ts  -- UIParent units -> tooltip units
    local spot = cursorSpot
    if not (spot and spot.owner == owner) then
        local x, y = GetCursorPosition()
        x, y = x / s, y / s
        local w = (tip:GetWidth() or 0) * ts / s
        local h = (tip:GetHeight() or 0) * ts / s
        local right = x + CURSOR_GAP + w <= UIParent:GetWidth()
        local below = y - CURSOR_GAP - h >= 0
        spot = {
            owner = owner,
            point = (below and "TOP" or "BOTTOM") .. (right and "LEFT" or "RIGHT"),
            x = x + (right and CURSOR_GAP or -CURSOR_GAP),
            y = y + (below and -CURSOR_GAP or CURSOR_GAP),
        }
        cursorSpot = spot
    end
    tip:ClearAllPoints()
    tip:SetPoint(spot.point, UIParent, "BOTTOMLEFT", spot.x * k, spot.y * k)
end

-- info (optional): { score = n, delta = n, class = "MAGE", anchor = "ANCHOR_RIGHT",
--                    beside = frame (place the tooltip outside this frame instead of using anchor),
--                    cursor = true (beside the mouse cursor, placed once per hover),
--                    place = function(owner) (positions the shown tooltip; run on every re-show) }
function ns:ShowItemTooltip(owner, id, info)
    info = info or {}
    pendingTip = nil
    if not ns.GetItemInfo(id) then  -- this call also asks the server for the item
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
        pendingTip = { owner = owner, id = id, info = info }
    end
    local tip = GameTooltip
    -- Re-shown while still up for this row (its item data just arrived): keep its spot.
    if not (tip:IsShown() and tip:IsOwned(owner)) then cursorSpot = nil end
    if info.beside then
        anchorBeside(tip, owner, info.beside)
    elseif info.cursor then
        tip:SetOwner(owner, "ANCHOR_NONE")  -- placed below, once its size is known
    else
        tip:SetOwner(owner, info.anchor or "ANCHOR_RIGHT")
    end
    tip:SetHyperlink("item:" .. id)
    tip:AddLine(" ")

    if info.score then
        local line = string.format("GearGuide score: %.1f", info.score)
        if info.delta then line = line .. string.format("  (%+.1f vs. equipped)", info.delta) end
        tip:AddLine(line, 0.4, 1, 0.6)
    end

    if self.IsFavorite and self:IsFavorite(id) then tip:AddLine("Favorite", 1, 0.82, 0) end

    local state, have, need = self:GetCompletion(id, info.class or self:GetPlayerClass())
    if state == "done" then
        tip:AddLine(need > 1 and string.format("Acquired (%d/%d)", have, need) or "Acquired", 0.3, 0.9, 0.3)
    elseif state == "partial" then
        tip:AddLine(string.format("Partially acquired (%d/%d)", have, need), 1, 0.7, 0.2)
    end

    local variants = #self:GetVariants(id)
    if variants > 0 then
        tip:AddLine(string.format("Drops with a random bonus (%d variant%s, listed in the GearGuide window)",
            variants, variants == 1 and "" or "s"), 0.6, 0.8, 1, true)
    end

    local sources = self:GetSources(id)
    if #sources == 0 then
        tip:AddLine("Not discovered yet. GearGuide learns the source when you loot, buy or see the item in game.", 0.6, 0.6, 0.6, true)
    else
        tip:AddLine("Where to get it:", 1, 0.82, 0)
        local shown, hasMap = 0, false
        for _, s in ipairs(sources) do
            hasMap = hasMap or ns.HasLocation(s)
            if shown < 8 then
                tip:AddLine("  " .. ns.FormatSource(s), 1, 1, 1, true)
                shown = shown + 1
            end
        end
        if #sources > shown then
            tip:AddLine(string.format("  ...and %d more (see the item in the GearGuide window)", #sources - shown), 0.6, 0.6, 0.6)
        end
        if hasMap then tip:AddLine("Click a source in the GearGuide window to show it on the map.", 0.5, 0.5, 0.5, true) end
    end
    tip:Show()
    if info.place then
        info.place(owner)
    elseif info.cursor then
        placeAtCursor(tip, owner)
    end
end

function ns:HideItemTooltip()
    GameTooltip:Hide()
end

-- The game's own item tooltips (bags, loot, links): a random variant names its base item.
function ns:VariantTooltipLines(link)
    local id = ns.LinkBonus(link) and ns.LinkToId(link)
    local item = id and self:GetItem(id)
    if not (item and item.n) then return nil end
    local variants = self:GetVariants(id)
    if #variants == 0 then return nil end  -- a bonus id that isn't a random bonus
    local suffix = self:LinkVariant(link)  -- nil: a bonus the shipped data doesn't list
    local chance
    for _, v in ipairs(variants) do
        if v.p == suffix then chance = v.c end
    end
    local first = "GearGuide: random variant of " .. ns.QualityHex(item.q or 1) .. item.n .. "|r"
    local second = #variants > 1 and string.format("One of %d variants%s", #variants,
        chance and string.format(" (this bonus: %s of drops)", ns.FormatChance(chance)) or "")
    return first, second
end

local function addVariantLines(tip, link)
    link = ns.Plain(link)
    if not link then
        local ok, _, l = pcall(tip.GetItem, tip)
        link = ok and ns.Plain(l) or nil
    end
    local first, second = ns:VariantTooltipLines(link)
    if not first then return false end
    tip:AddLine(first, 0.4, 1, 0.6)
    if second then tip:AddLine(second, 0.6, 0.6, 0.6) end
    return true
end
ns.AddVariantTooltipLines = addVariantLines  -- (tests)

-- Upgrade or downgrade over what you wear, on every item tooltip (bags, quest rewards in any quest
-- window, links...). Same number and setting as the icon badges.
local function addGainLine(tip, link)
    if not (ns.Badges and (not GearGuideDB or GearGuideDB.iconBadges ~= false)) then return false end
    link = ns.Plain(link)
    if not link then
        local ok, _, l = pcall(tip.GetItem, tip)
        link = ok and ns.Plain(l) or nil
    end
    local gain = link and ns.Badges.GainFor(link)
    if not gain then return false end
    local text = ns.Badges.formatGain(gain)
    if gain > 0 then
        tip:AddLine("GearGuide: " .. text .. " over what you wear", 0.33, 0.85, 0.42)
    else
        tip:AddLine("GearGuide: " .. text .. " compared to what you wear", 0.92, 0.36, 0.32)
    end
    return true
end
ns.AddGainTooltipLine = addGainLine  -- (tests)

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
    and Enum.TooltipDataType.Item then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tip, data)
        pcall(addGainLine, tip, data and data.hyperlink)
        pcall(addVariantLines, tip, data and data.hyperlink)
    end)
else
    for _, t in ipairs({ GameTooltip, ItemRefTooltip }) do
        if t and t.HookScript then
            t:HookScript("OnTooltipSetItem", function(tip)
                local ok1, gainAdded = pcall(addGainLine, tip)
                local ok2, added = pcall(addVariantLines, tip)
                if (ok1 and gainAdded) or (ok2 and added) then tip:Show() end
            end)
        end
    end
end
