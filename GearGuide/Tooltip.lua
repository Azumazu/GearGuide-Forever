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
    if cx < UIParent:GetWidth() / 2 then
        tip:SetPoint("TOPLEFT", owner, "TOPRIGHT", (outer:GetRight() or 0) - (owner:GetRight() or 0) + gap, 0)
    else
        tip:SetPoint("TOPRIGHT", owner, "TOPLEFT", (outer:GetLeft() or 0) - (owner:GetLeft() or 0) - gap, 0)
    end
end

-- info (optional): { score = n, delta = n, class = "MAGE", anchor = "ANCHOR_RIGHT",
--                    beside = frame (place the tooltip outside this frame instead of using anchor) }
function ns:ShowItemTooltip(owner, id, info)
    info = info or {}
    pendingTip = nil
    if not ns.GetItemInfo(id) then  -- this call also asks the server for the item
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
        pendingTip = { owner = owner, id = id, info = info }
    end
    local tip = GameTooltip
    if info.beside then
        anchorBeside(tip, owner, info.beside)
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

    local sources = self:GetSources(id)
    if #sources == 0 then
        tip:AddLine("Source unknown. Run the updater, or loot/see the item in game.", 0.6, 0.6, 0.6, true)
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
end

function ns:HideItemTooltip()
    GameTooltip:Hide()
end
