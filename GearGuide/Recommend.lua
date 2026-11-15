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
    local weights
    local custom = self:IsCustomWeights() and class == self:GetPlayerClass() and specKey == self:GetPlayerSpec()
    if custom then
        -- A copy: Score caches derived tables by identity, and the saved table changes in place.
        weights = {}
        for k, v in pairs(GearGuideCharDB.custom.weights) do weights[k] = v end
    else
        weights = self:GetWeights(class, specKey, UnitLevel("player"))
    end
    return weights,
        { class = class, spec = spec and spec.key, role = spec and spec.role or "MELEE", level = UnitLevel("player"),
          custom = custom or nil }  -- custom: the player's own stat weights (Settings) are in use
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

---------------------------------------------------------------------------
-- Current zone: which recommended items can be obtained right here?
---------------------------------------------------------------------------
-- The player's location: zone (or instance) name, world map ID and whether inside an instance.
function ns:CurrentZone()
    local name = ns.Plain(GetRealZoneText and GetRealZoneText()) or ""
    local mapID = C_Map and C_Map.GetBestMapForUnit and ns.Plain(C_Map.GetBestMapForUnit("player"))
    local inInstance = IsInInstance and ns.Plain(IsInInstance()) or false
    return name, mapID, inInstance and true or false
end

-- Is this source in the given zone? Zones match by name (works for instances and the client's
-- language) or by world map for outdoor spawns. Dungeon entrances on an outdoor map don't count:
-- those drops are inside the dungeon.
function ns.SourceInZone(s, zoneName, mapID, inInstance)
    if s.t == "craft" then return false end  -- crafted: the recipe's location isn't where the item drops
    if zoneName ~= "" then
        if s.z and ns.ZoneName(s.z) == zoneName then return true end
        for _, entry in ipairs(s.loc or {}) do
            if entry.e and ns.ZoneName(entry.e) == zoneName then return true end
        end
    end
    if mapID and not inInstance then
        for _, entry in ipairs(s.loc or {}) do
            if not entry.e and entry.m == mapID then return true end
        end
    end
    return false
end

-- Recommended items obtainable in the current zone: upgrades for the player's spec and favorites
-- still wanted, best upgrade first. Each pick carries .zoneSource (the matching source).
-- Returns picks, zoneName.
function ns:GetZonePicks(n)
    local zoneName, mapID, inInstance = self:CurrentZone()
    local class = self:GetPlayerClass()
    local candidates, seen = {}, {}
    local function consider(p)
        if seen[p.id] or self:GetCompletion(p.id, class) == "done" then return end
        seen[p.id] = true
        local chest
        for _, s in ipairs(self:GetSources(p.id)) do
            if ns.SourceInZone(s, zoneName, mapID, inInstance) then
                if s.k ~= "object" then
                    p.zoneSource = s  -- a creature, boss, vendor or quest here: best kind of match
                    break
                end
                chest = chest or s
            end
        end
        p.zoneSource = p.zoneSource or chest
        if p.zoneSource then
            p.chestOnly = p.zoneSource == chest
            p.favorite = self:IsFavorite(p.id)
            candidates[#candidates + 1] = p
        end
    end
    for _, g in ipairs(self:BuildRecommendations().groups) do
        for _, p in ipairs(g.upgrades or {}) do
            p.groupLabel = g.label
            consider(p)
        end
    end
    local weights, ctx = self:GetScoringContext()
    for _, id in ipairs(self:GetFavorites()) do
        local item = self:GetItem(id)
        if item then
            consider({ id = id, item = item, score = self:Score(item, weights, ctx), delta = 0,
                groupLabel = ns.SlotLabel(item.eq) })
        end
    end
    table.sort(candidates, function(a, b)
        if (a.favorite and 1 or 0) ~= (b.favorite and 1 or 0) then return a.favorite == true end
        if (a.chestOnly and 1 or 0) ~= (b.chestOnly and 1 or 0) then return not a.chestOnly end  -- random chest loot last
        return (a.delta or 0) > (b.delta or 0)
    end)
    local out = {}
    for i = 1, math.min(n or #candidates, #candidates) do out[i] = candidates[i] end
    return out, zoneName
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

-- Specs whose talents need one weapon type in the hands (main and off hand; ranged unaffected).
-- Assassination rogues build around Backstab/Ambush and dagger talents once the tree matures.
local WEAPON_ONLY = {
    ROGUE = { ASSASSINATION = { minLevel = 40, subclasses = { [15] = true } } },  -- 15 = dagger
}
local HAND_SLOTS = { INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true, INVTYPE_WEAPONOFFHAND = true,
    INVTYPE_2HWEAPON = true }

function ns.WeaponTypeAllowed(item, class, specKey, level)
    local rule = WEAPON_ONLY[class] and WEAPON_ONLY[class][specKey]
    if not rule or (level or 1) < rule.minLevel or not HAND_SLOTS[item.eq] then return true end
    return item.c == ns.ITEM_CLASS_WEAPON and rule.subclasses[item.sc or -1] == true
end

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
        armorOk = sc == self:ArmorMax(ctx.class, math.max(ctx.level, ns.EffectiveLevel(item)))
    end
    return statsOk, armorOk
end

local MIN_QUALITY = 2  -- Enum.ItemQuality.Uncommon (default; Settings: GearGuideDB.minQuality)

function ns:BuildRecommendations()
    local minQ = tonumber(GearGuideDB.minQuality) or MIN_QUALITY
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
        -- Uncommon (green) and better only: common/poor gear is vendor filler, not worth a slot
        -- in the list (favorites are added separately and still show).
        if groups and (item.q or 1) >= minQ and eff >= minL and eff <= maxL
            and self:ShowsItem(id) and self:IsUsable(item, ctx.class, level)
            and ns.WeaponTypeAllowed(item, ctx.class, ctx.spec, level) then
            local score = self:Score(item, weights, ctx)
            local statsOk, armorOk = self:IsSuitable(item, weights, ctx, score)
            -- Nothing to recommend about an item the spec gets no value from (stat-less relics,
            -- placeholder armor): it would only crowd out real picks with "0.0".
            if statsOk and score > 0 then
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
        local picks, upgrades = {}, {}
        for _, p in ipairs(list) do
            if not equippedIds[p.id] and (p.armorOk or not anyBestArmor) then
                p.delta = p.score - eqScore
                if #picks < PICKS_PER_SLOT then picks[#picks + 1] = p end
                if p.delta > 0 then upgrades[#upgrades + 1] = p end  -- every real upgrade (zone view)
            end
        end
        result.groups[#result.groups + 1] = {
            key = grp.key, label = grp.label,
            equippedLink = eqLink, equippedScore = eqLink and eqScore or nil,
            picks = picks, upgrades = upgrades,
        }
      end
    end
    return result
end
