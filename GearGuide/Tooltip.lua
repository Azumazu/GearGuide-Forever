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

-- info (optional): { score = n, delta = n, class = "MAGE", anchor = "ANCHOR_RIGHT" }
function ns:ShowItemTooltip(owner, id, info)
    info = info or {}
    pendingTip = nil
    if not ns.GetItemInfo(id) then  -- this call also asks the server for the item
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
        pendingTip = { owner = owner, id = id, info = info }
    end
    local tip = GameTooltip
    tip:SetOwner(owner, info.anchor or "ANCHOR_RIGHT")
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
