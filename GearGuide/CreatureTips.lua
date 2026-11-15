local _, ns = ...

-- Creature tooltips: the gear GearGuide recommends to the player (the Recommended list and favorites)
-- that this creature drops, with drop chances and the score gain over what's equipped.

local MAX_LINES = 6
local IGNORED = { Container = true, Unknown = true }  -- placeholder names, never a real creature

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

-- { {id, dc}, ... } for every item this creature drops: shipped sources plus ones learned in game.
function ns:GetCreatureDrops(name)
    if not name or IGNORED[name] then return {} end
    if not shippedIndex then buildShippedIndex() end
    local found = {}
    for id, dc in pairs(shippedIndex[name] or {}) do found[id] = dc end
    for id, list in pairs(GearGuideLearned and GearGuideLearned.sources or {}) do
        if not found[id] and type(list) == "table" then
            for _, s in ipairs(list) do
                if s.t == "drop" and s.n == name then found[id] = 0 break end
            end
        end
    end
    local out = {}
    for id, dc in pairs(found) do
        if self:GetItem(id) and self:ShowsItem(id) then out[#out + 1] = { id = id, dc = dc > 0 and dc or nil } end
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

local function addDrops(tip)
    if not (GearGuideDB and GearGuideDB.creatureTips) or not tip.GetUnit then return end
    local name, unit = tip:GetUnit()
    name, unit = ns.Plain(name), ns.Plain(unit)
    if not name or (unit and ns.Plain(UnitIsPlayer(unit)) ~= false) then return end
    local wanted = recommended()
    local drops = {}
    for _, d in ipairs(ns:GetCreatureDrops(name)) do
        if wanted[d.id] then d.gain = wanted[d.id]; drops[#drops + 1] = d end
    end
    if #drops == 0 then return end
    table.sort(drops, function(a, b)  -- biggest upgrade first, then the likeliest drop
        if a.gain ~= b.gain then return a.gain > b.gain end
        if (a.dc or 0) ~= (b.dc or 0) then return (a.dc or 0) > (b.dc or 0) end
        return a.id < b.id
    end)
    tip:AddLine(" ")
    tip:AddLine("GearGuide - recommended and favorite drops:", 1, 0.82, 0)
    local class = ns:GetPlayerClass()
    for i = 1, math.min(#drops, MAX_LINES) do
        local d = drops[i]
        local item = ns:GetItem(d.id)
        local icon = ns.ItemIcon(d.id)
        local left = (icon and ("|T" .. icon .. ":14:14|t ") or "")
            .. ns.QualityHex(item.q) .. (item.n or ("item " .. d.id)) .. "|r"
        local mark = ns:CompletionMarkup(d.id, class)
        if mark ~= "" then left = left .. " " .. mark end
        if ns:IsFavorite(d.id) then left = left .. " |cffffd100*|r" end
        if d.gain > 0 then left = left .. string.format(" |cff66ff99+%.1f|r", d.gain) end
        tip:AddDoubleLine(left, d.dc and ns.FormatChance(d.dc) or "", 1, 1, 1, 1, 0.82, 0)
    end
    if #drops > MAX_LINES then
        tip:AddLine(string.format("...and %d more", #drops - MAX_LINES), 0.6, 0.6, 0.6)
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
