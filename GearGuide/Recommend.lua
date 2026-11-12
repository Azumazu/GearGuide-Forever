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
    -- Favorites first (still wanted ones, then acquired ones), then the best upgrades.
    local out, used = {}, {}
    local weights, ctx = self:GetScoringContext()
    local wanted, owned = {}, {}
    for _, id in ipairs(self:GetFavorites()) do
        local item = self:GetItem(id)
        if item then
            local pick = { id = id, item = item, score = self:Score(item, weights, ctx), delta = 0, favorite = true,
                groupLabel = ns.SlotLabel(item.eq) }
            if self:GetCompletion(id, class) == "done" then
                if not hideCompleted then owned[#owned + 1] = pick end
            else
                wanted[#wanted + 1] = pick
            end
        end
    end
    for _, list in ipairs({ wanted, all, owned }) do
        for _, p in ipairs(list) do
            if #out >= n then break end
            if not used[p.id] then
                used[p.id] = true
                p.favorite = p.favorite or self:IsFavorite(p.id)
                out[#out + 1] = p
            end
        end
    end
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

-- The spec's weapon setup at the player's level ("dual", "twohand", "onehand", "shield", "caster").
function ns:WeaponSetup(class, specKey, level)
    class = class or self:GetPlayerClass()
    local spec = self:GetSpecInfo(class, specKey or (class == self:GetPlayerClass() and self:GetPlayerSpec()))
    local setup = spec and ns.SPEC_HANDS[class] and ns.SPEC_HANDS[class][spec.key] or "caster"
    local dwLevel = ns.DUAL_WIELD[class]
    if setup == "dual" and (not dwLevel or (level or 60) < dwLevel) then
        setup = (class == "ROGUE") and "onehand" or "twohand"  -- can't dual wield yet
    end
    return setup
end

-- Which hand groups an item counts for under a weapon setup. One-handers fill both hands when
-- dual wielding; off-hand frills and shields only where the spec uses them; no off-hand for two-handers.
local HAND_GROUPS = {
    INVTYPE_WEAPON         = { dual = { "MAINHAND", "OFFHAND" }, twohand = { "MAINHAND" }, onehand = { "MAINHAND" },
                               shield = { "MAINHAND" }, caster = { "MAINHAND" } },
    INVTYPE_WEAPONMAINHAND = { dual = { "MAINHAND" }, twohand = { "MAINHAND" }, onehand = { "MAINHAND" },
                               shield = { "MAINHAND" }, caster = { "MAINHAND" } },
    INVTYPE_2HWEAPON       = { twohand = { "MAINHAND" }, caster = { "MAINHAND" } },
    INVTYPE_WEAPONOFFHAND  = { dual = { "OFFHAND" } },
    INVTYPE_SHIELD         = { shield = { "OFFHAND" }, caster = { "OFFHAND" } },
    INVTYPE_HOLDABLE       = { caster = { "OFFHAND" } },
}
local NO_OFFHAND = { twohand = true, onehand = true }

function ns:GroupsForItem(item, setup)
    local hands = HAND_GROUPS[item.eq]
    if hands then return hands[setup] end
    local group = ns.EQUIPLOC_GROUP[item.eq]
    return group and { group } or nil
end

-- "Should use", beyond "can use": stats the spec values, and the best armor type.
local PRIMARY = { STR = true, AGI = true, INT = true, SPI = true, AP = true, RAP = true, SP = true, HEAL = true,
    MP5 = true, CRIT = true, HIT = true, SCRIT = true, SHIT = true, HASTE = true, EXPERTISE = true,
    DEF = true, DODGE = true, PARRY = true, BLOCK = true }

-- Returns statsOk, armorOk.
--   statsOk: an item carrying primary stats must have some the spec values (no Intellect robes for
--            rogues, no Strength rings for mages); weapons must score above zero for the spec.
--   armorOk: body armor is the best type the class wears at the item's level (cloaks/jewelry exempt).
function ns:IsSuitable(item, weights, ctx, score)
    local hasPrimary, core = false, 0
    for stat, v in pairs(item.st or {}) do
        if PRIMARY[stat] then
            hasPrimary = true
            core = core + v * (weights[stat] or 0)
        end
    end
    local statsOk = not (hasPrimary and core <= 0)
    if item.c == ns.ITEM_CLASS_WEAPON and (score or 0) <= 0 then statsOk = false end
    local armorOk = true
    local sc = item.sc or 0
    if item.c == ns.ITEM_CLASS_ARMOR and sc >= 1 and sc <= 4 and item.eq ~= "INVTYPE_CLOAK" then
        armorOk = sc == self:ArmorMax(ctx.class, math.max(ctx.level, item.rl or 0))
    end
    return statsOk, armorOk
end

function ns:BuildRecommendations()
    local weights, ctx = self:GetScoringContext()
    local level = ctx.level
    local minL = math.max(1, level - GearGuideDB.levelBehind)
    local maxL = level + GearGuideDB.levelAhead
    local setup = self:WeaponSetup(ctx.class, ctx.spec, level)

    local buckets = {}
    for _, id in ipairs(self:AllItemIds()) do
        local item = self:GetItem(id)
        local groups = self:GroupsForItem(item, setup)
        local eff = ns.EffectiveLevel(item)
        if groups and eff >= minL and eff <= maxL and self:IsUsable(item, ctx.class, level) then
            local score = self:Score(item, weights, ctx)
            local statsOk, armorOk = self:IsSuitable(item, weights, ctx, score)
            if statsOk then
                for _, group in ipairs(groups) do
                    local list = buckets[group]
                    if not list then list = {}; buckets[group] = list end
                    list[#list + 1] = { id = id, item = item, score = score, armorOk = armorOk }
                end
            end
        end
    end

    local result = { minL = minL, maxL = maxL, groups = {}, setup = setup }
    for _, grp in ipairs(ns.SLOT_GROUPS) do
      if not (grp.key == "OFFHAND" and NO_OFFHAND[setup]) then
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
        -- Best armor type only; lower types just when this slot has none in range (low levels).
        local anyBestArmor = false
        for _, p in ipairs(list) do
            if p.armorOk and not equippedIds[p.id] then anyBestArmor = true break end
        end
        local picks = {}
        for _, p in ipairs(list) do
            if not equippedIds[p.id] and (p.armorOk or not anyBestArmor) then
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
    end
    return result
end
