local _, ns = ...

local PICKS_PER_SLOT = 3

-- class/spec default to the player's; pass them to score items for another class or spec (gear browser).
-- ctx.role is the spec's role (MELEE/TANK/RANGED/CASTER/HEALER), ctx.spec the spec key.
function ns:GetScoringContext(class, specKey)
    class = class or self:GetPlayerClass()
    if not specKey then
        specKey = (class == self:GetPlayerClass()) and self:GetPlayerSpec() or (self:GetSpecs(class)[1] or {}).key
    end
    local spec = self:GetSpecInfo(class, specKey)
    return self:GetWeights(class, specKey, UnitLevel("player")),
        { class = class, spec = spec and spec.key, role = spec and spec.role or "MELEE", level = UnitLevel("player") }
end

-- Best `n` picks across all slots, biggest upgrade first (used by the mini UI).
-- Returns { {id, item, score, delta, groupLabel}, ... }.
function ns:GetTopPicks(n, hideCompleted)
    local class = self:GetPlayerClass()
    local all = {}
    for _, g in ipairs(self:BuildRecommendations().groups) do
        for _, p in ipairs(g.picks) do
            if not (hideCompleted and self:GetCompletion(p.id, class) == "done") then
                p.groupLabel = g.label
                all[#all + 1] = p
            end
        end
    end
    table.sort(all, function(a, b)
        if a.delta ~= b.delta then return a.delta > b.delta end
        return a.score > b.score
    end)
    local out = {}
    for i = 1, math.min(n, #all) do out[i] = all[i] end
    return out
end

-- Returns item record, link and id for what's in an equipment slot.
function ns:ItemForSlot(slotId)
    local link = GetInventoryItemLink("player", slotId)
    if not link then return nil end
    local id = ns.LinkToId(link)
    -- Live link first: it carries random-suffix stats ("of the Bear") the database record lacks.
    return self:ItemFromLink(link) or self:GetItem(id), link, id
end

function ns:BuildRecommendations()
    local weights, ctx = self:GetScoringContext()
    local level = ctx.level
    local minL = math.max(1, level - GearGuideDB.levelBehind)
    local maxL = level + GearGuideDB.levelAhead

    local buckets = {}
    for _, id in ipairs(self:AllItemIds()) do
        local item = self:GetItem(id)
        local group = ns.EQUIPLOC_GROUP[item.eq]
        local eff = ns.EffectiveLevel(item)
        if group and eff >= minL and eff <= maxL and self:IsUsable(item, ctx.class, level) then
            local list = buckets[group]
            if not list then list = {}; buckets[group] = list end
            list[#list + 1] = { id = id, item = item, score = self:Score(item, weights, ctx) }
        end
    end

    local result = { minL = minL, maxL = maxL, groups = {} }
    for _, grp in ipairs(ns.SLOT_GROUPS) do
        -- Baseline is the weakest equipped slot of the group, so a ring that beats
        -- your worse ring still counts as an upgrade.
        local eqScore, eqLink
        local equippedIds = {}
        for _, slot in ipairs(grp.inv) do
            local item, link, id = self:ItemForSlot(slot)
            if id then equippedIds[id] = true end
            local s = item and self:Score(item, weights, ctx) or 0
            if eqScore == nil or s < eqScore then eqScore, eqLink = s, link end
        end

        local list = buckets[grp.key] or {}
        table.sort(list, function(a, b) return a.score > b.score end)
        local picks = {}
        for _, p in ipairs(list) do
            if not equippedIds[p.id] then
                p.delta = p.score - eqScore
                picks[#picks + 1] = p
                if #picks >= PICKS_PER_SLOT then break end
            end
        end
        result.groups[#result.groups + 1] = {
            key = grp.key, label = grp.label,
            equippedLink = eqLink, equippedScore = eqLink and eqScore or nil,
            picks = picks,
        }
    end
    return result
end
