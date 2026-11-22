local _, ns = ...

-- Creature tooltips: the gear this creature drops, with drop chances and the score gain over what's
-- equipped. Which gear (Settings > General > Creature tooltips, GearGuideDB.tipDrops):
--   show       "upgrades" (recommended and favorite items), "usable" (gear your class can wear), "all"
--   minQuality lowest quality listed (favorites always show)
--   bracket    item level range: "range" (the recommendations' levels), "any", or "1-10" ... "51-60"
--   world      include BoE world drops (WorldDrops.lua: any creature of the right level can drop them)

local MAX_LINES = 6
local IGNORED = { Container = true, Unknown = true }  -- placeholder names, never a real creature
local WORLD_CHANCE = 1  -- % : a world-drop item listed at a creature with less than this is its world drop

ns.TIP_DROP_SHOW = {
    { value = "upgrades", text = "Upgrades and favorites" },
    { value = "usable", text = "Gear your class can use" },
    { value = "all", text = "All gear" },
}
ns.TIP_DROP_BRACKETS = {
    { value = "range", text = "Your recommendation range" },
    { value = "any", text = "Any level" },
    { value = "1-10", text = "Level 1-10" },
    { value = "11-20", text = "Level 11-20" },
    { value = "21-30", text = "Level 21-30" },
    { value = "31-40", text = "Level 31-40" },
    { value = "41-50", text = "Level 41-50" },
    { value = "51-60", text = "Level 51-60" },
}

-- name -> { [itemID] = chance% or 0 }, from the shipped database (built once).
local shippedIndex
local function buildShippedIndex()
    shippedIndex = {}
    local data = GearGuide_Data
    if not (data and data.items) then return end
    local pool = data.sources or {}
    for id, item in pairs(data.items) do
        if type(item.src) == "table" then
            for i, ref in ipairs(item.src) do
                local s = type(ref) == "number" and pool[ref] or ref
                if type(s) == "table" and s.t == "drop" and s.k ~= "object" and s.n and not IGNORED[s.n] then
                    local list = shippedIndex[s.n]
                    if not list then list = {}; shippedIndex[s.n] = list end
                    local dc = type(item.dc) == "table" and item.dc[i] or 0
                    list[id] = math.max(list[id] or 0, dc or 0)
                end
            end
        end
    end
end

-- { {id, dc, world}, ... } for every item this creature drops: shipped sources, world drops and
-- ones learned in game. world: the item is a BoE world drop and this creature isn't a likely source
-- of it (its loot table doesn't hold it at 1%+).
function ns:GetCreatureDrops(name)
    if not name or IGNORED[name] then return {} end
    if not shippedIndex then buildShippedIndex() end
    local found = {}
    for id, dc in pairs(shippedIndex[name] or {}) do found[id] = dc end
    for id, dc in pairs(self:WorldDropsOf(name) or {}) do
        if not found[id] or found[id] < dc then found[id] = dc end
    end
    -- Own and shared finds, only where the item's source list shows them too (GetSources hides
    -- drops a known loot table rules out, e.g. raid gear once credited to a boar).
    for _, store in ipairs({ GearGuideLearned and GearGuideLearned.sources, GearGuideLearned and GearGuideLearned.shared }) do
        for id, list in pairs(store or {}) do
            if not found[id] and type(list) == "table" then
                for _, s in ipairs(list) do
                    if type(s) == "table" and s.t == "drop" and s.n == name then
                        if self:ListsDropper(id, name) then found[id] = 0 end
                        break
                    end
                end
            end
        end
    end
    local out = {}
    for id, dc in pairs(found) do
        if self:GetItem(id) and self:ShowsItem(id) then
            local world = self:WorldDropInfo(id) ~= nil and dc < WORLD_CHANCE
            out[#out + 1] = { id = id, dc = dc > 0 and dc or nil, world = world }
        end
    end
    return out
end

-- Items recommended to the player: { [itemID] = score gain over equipped (0 for favorites) }.
-- The same picks the Recommended list shows, plus every upgrade and every favorite; rebuilt after
-- any refresh (level up, gear change, settings).
local recommendedCache
function ns:InvalidateCreatureTips() recommendedCache = nil end
local function recommended()
    if not recommendedCache then
        local rec = {}
        local function add(p)
            local gain = p.delta or 0
            if rec[p.id] == nil or gain > rec[p.id] then rec[p.id] = gain end
        end
        local ok, result = pcall(ns.BuildRecommendations, ns)
        if ok and result then
            for _, g in ipairs(result.groups or {}) do
                for _, p in ipairs(g.picks or {}) do add(p) end
                for _, p in ipairs(g.upgrades or {}) do add(p) end
            end
        end
        for _, id in ipairs(ns.GetFavorites and ns:GetFavorites() or {}) do add({ id = id, delta = 0 }) end
        recommendedCache = rec
    end
    return recommendedCache
end

-- The item levels the bracket setting allows: lowest, highest.
function ns.TipDropLevels(bracket, level)
    if bracket == "any" then return 1, math.huge end
    local lo, hi = tostring(bracket or ""):match("^(%d+)%-(%d+)$")
    if lo then return tonumber(lo), tonumber(hi) end
    level = level or 1
    return math.max(1, level - (GearGuideDB.levelBehind or 5)), level + (GearGuideDB.levelAhead or 3)
end

-- The drops the settings let through, best first: { {id, dc, world, gain}, ... }.
function ns:FilterCreatureDrops(drops)
    local cfg = GearGuideDB.tipDrops or {}
    local show = cfg.show or "upgrades"
    local minQ = tonumber(cfg.minQuality) or 2
    local class, level = self:GetPlayerClass(), ns.Plain(UnitLevel("player")) or 1
    local lo, hi = ns.TipDropLevels(cfg.bracket or "range", level)
    local wanted = recommended()
    local out = {}
    for _, d in ipairs(drops) do
        local item = self:GetItem(d.id)
        local fav = self:IsFavorite(d.id)
        local keep = item ~= nil and (cfg.world ~= false or not d.world)
        if keep and not fav then  -- favorites skip the filters: the player picked them on purpose
            local eff = ns.EffectiveLevel(item)
            keep = (item.q or 1) >= minQ and eff >= lo and eff <= hi
            if keep and show == "upgrades" then keep = wanted[d.id] ~= nil
            elseif keep and show == "usable" then keep = self:IsUsable(item, class, math.max(level, eff)) end
        end
        if keep then
            local gain = wanted[d.id]
            if gain == nil and ns.Badges and ns.Badges.GainFor then gain = ns.Badges.GainFor("item:" .. d.id) end
            d.gain, d.fav = gain or 0, fav
            out[#out + 1] = d
        end
    end
    table.sort(out, function(a, b)
        -- The creature's own loot before world drops any creature of its level has; then the
        -- biggest upgrade, then the likeliest drop.
        if a.world ~= b.world then return not a.world end
        if a.gain ~= b.gain then return a.gain > b.gain end
        if (a.dc or 0) ~= (b.dc or 0) then return (a.dc or 0) > (b.dc or 0) end
        return a.id < b.id
    end)
    return out
end

local function addDrops(tip)
    if not (GearGuideDB and GearGuideDB.creatureTips) or not tip.GetUnit then return end
    local name, unit = tip:GetUnit()
    name, unit = ns.Plain(name), ns.Plain(unit)
    if not name or (unit and ns.Plain(UnitIsPlayer(unit)) ~= false) then return end
    local drops = ns:FilterCreatureDrops(ns:GetCreatureDrops(name))
    if #drops == 0 then return end
    local show = (GearGuideDB.tipDrops or {}).show or "upgrades"
    local shown = math.min(#drops, MAX_LINES)
    -- World drops share one chance text ("<0.1%"): said once on their header, not on every line.
    local worldChance, mixed
    for i = 1, shown do
        local d = drops[i]
        if d.world then
            local c = d.dc and ns.FormatChance(d.dc) or ""
            if worldChance == nil then worldChance = c elseif worldChance ~= c then mixed = true end
        end
    end
    if mixed then worldChance = nil end
    tip:AddLine(" ")
    local title = show == "upgrades" and "GearGuide - upgrades and favorites" or "GearGuide - gear drops"
    local class = ns:GetPlayerClass()
    local worldHeader = false
    for i = 1, shown do
        local d = drops[i]
        if d.world and not worldHeader then
            -- Only world drops: one title; after the creature's own loot: a sub-header.
            local head = i == 1 and "GearGuide - BoE world drops" or "BoE world drops"
            local each = worldChance and worldChance ~= "" and (worldChance .. " each") or ""
            if i == 1 then
                tip:AddDoubleLine(head, each, 1, 0.82, 0, 0.6, 0.6, 0.6)
            else
                tip:AddDoubleLine(head, each, 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
            end
            worldHeader = true
        elseif i == 1 then
            tip:AddLine(title, 1, 0.82, 0)
        end
        local item = ns:GetItem(d.id)
        local icon = ns.ItemIcon(d.id)
        local left = (icon and ("|T" .. icon .. ":14:14|t ") or "")
            .. ns.QualityHex(item.q) .. (item.n or ("item " .. d.id)) .. "|r"
        local mark = ns:CompletionMarkup(d.id, class)
        if mark ~= "" then left = left .. " " .. mark end
        if d.fav then left = left .. " |cffffd100*|r" end
        if d.gain > 0 then left = left .. " " .. ns.Skin:Hex("upgrade") .. string.format("+%.1f|r", d.gain)
        elseif d.gain < 0 then left = left .. " " .. ns.Skin:Hex("downgrade") .. string.format("%.1f|r", d.gain) end
        local chance = (d.world and worldChance) and "" or (d.dc and ns.FormatChance(d.dc) or "")
        tip:AddDoubleLine("  " .. left, chance, 1, 1, 1, 1, 0.82, 0)
    end
    if #drops > MAX_LINES then
        tip:AddLine(string.format("  +%d more", #drops - MAX_LINES), 0.5, 0.5, 0.5)
    end
    tip:Show()  -- resize for the added lines
end

function ns:EnableCreatureTips()
    if self.creatureTipsHooked then return end
    self.creatureTipsHooked = true
    -- Newer clients (Forever) run tooltip post-calls; older ones fire OnTooltipSetUnit.
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
        and Enum.TooltipDataType.Unit then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tip)
            if tip == GameTooltip then pcall(addDrops, tip) end
        end)
    elseif GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetUnit", function(tip) pcall(addDrops, tip) end)
    end
end
