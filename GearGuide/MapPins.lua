local _, ns = ...

-- Shows where an item comes from on the world map: opens the map on the right zone and draws
-- GearGuide pins (creature / boss / vendor / quest giver / chest / dungeon entrance). Where a creature
-- spawns in groups, the whole area it lives in is shaded and outlined, with one pin in its middle.
-- Optional extras, only when available: the game's own user waypoint (arrow + minimap) and TomTom.
-- Pins live on the world map canvas and only show while that map is displayed.

local MAX_PINS = 40
local PIN_SIZE = 18
local ICONS = {
    drop     = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",   -- skull
    boss     = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",
    vendor   = "Interface\\GossipFrame\\VendorGossipIcon",
    quest    = "Interface\\GossipFrame\\AvailableQuestIcon",
    object   = "Interface\\Icons\\INV_Box_01",
    craft    = "Interface\\GossipFrame\\TrainerGossipIcon",
    entrance = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_6",   -- square (doorway)
}

local MAX_SEGMENTS = 400
local LINE_WIDTH = 3
local LINE_COLOR = { 0.86, 0.65, 0.5, 0.85 }  -- skin accent
local AREA_FILL = { 0.86, 0.65, 0.5, 0.22 }
local MAX_TRIANGLES = 240

local pins, active = {}, nil   -- active = { map = uiMapID, points = {...}, routes = {...}, title, kind, sub }
local lines = {}
local triangles = {}
local drawn = {}  -- what the last refresh drew (for /gg dev)
local watcher

local function canvas()
    if not WorldMapFrame then return nil end
    if WorldMapFrame.GetCanvas then return WorldMapFrame:GetCanvas() end
    return WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
end

local function canvasScale()
    local sc = WorldMapFrame and WorldMapFrame.ScrollContainer
    return (sc and sc.GetCanvasScale and sc:GetCanvasScale()) or 1
end

local function pinOnEnter(self)
    if not active then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(active.title or "GearGuide")
    if active.sub then GameTooltip:AddLine(active.sub, 1, 1, 1, true) end
    GameTooltip:AddLine("GearGuide: right-click a pin to clear", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function getPin(i, parent)
    local pin = pins[i]
    if not pin then
        pin = CreateFrame("Button", nil, parent)
        pin:SetSize(PIN_SIZE, PIN_SIZE)
        pin.icon = pin:CreateTexture(nil, "OVERLAY")
        pin.icon:SetAllPoints()
        pin.glow = pin:CreateTexture(nil, "BACKGROUND")
        pin.glow:SetPoint("CENTER")
        pin.glow:SetSize(PIN_SIZE * 1.8, PIN_SIZE * 1.8)
        pin.glow:SetTexture("Interface\\Buttons\\UI-Quickslot2")  -- soft ring behind the icon
        pin.glow:SetVertexColor(0.86, 0.65, 0.5, 0.9)              -- skin accent
        pin:RegisterForClicks("RightButtonUp")
        pin:SetScript("OnEnter", pinOnEnter)
        pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pin:SetScript("OnClick", function() ns:ClearMapPins() end)
        pins[i] = pin
    end
    if pin:GetParent() ~= parent then pin:SetParent(parent) end
    return pin
end

local function hideLines(from)
    for i = from or 1, #lines do lines[i]:Hide() end
end

local function hideTriangles(from)
    for i = from or 1, #triangles do triangles[i]:Hide() end
end

local function hideAll()
    for _, pin in ipairs(pins) do pin:Hide() end
    hideLines()
    hideTriangles()
end

-- Routes, area outlines and area fills are drawn on one overlay frame above the map tiles (and
-- below the pins). Drawn on the canvas itself they end up underneath the map's tile frames.
local overlay
local function getOverlay(c)
    if not overlay then
        overlay = CreateFrame("Frame", nil, c)
    end
    if overlay:GetParent() ~= c then overlay:SetParent(c) end
    overlay:ClearAllPoints()
    overlay:SetAllPoints(c)
    overlay:SetFrameLevel((c:GetFrameLevel() or 1) + 15)
    overlay:Show()
    return overlay
end

-- One straight piece of a route or area outline. Lines need Frame:CreateLine (modern clients);
-- without it they simply aren't drawn and the pins still show.
local function getLine(i, c)
    local parent = getOverlay(c)
    local line = lines[i]
    if not line then
        if not parent.CreateLine then return nil end
        line = parent:CreateLine(nil, "OVERLAY")
        if not line then return nil end
        line:SetColorTexture(LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3], LINE_COLOR[4])
        lines[i] = line
    end
    return line
end

-- Draws the paths (lists of {x, y}) as lines; closed = also join the last point to the first.
-- Returns the number of lines used so far (continuing from `n`).
local function drawPaths(c, w, h, paths, closed, n)
    local thickness = LINE_WIDTH / canvasScale()  -- same on-screen width at every zoom level
    for _, path in ipairs(paths or {}) do
        local count = #path
        for i = 1, closed and count or count - 1 do
            if n >= MAX_SEGMENTS then return n end
            local a, b = path[i], path[i % count + 1]
            local line = getLine(n + 1, c)
            if not line then return n end
            n = n + 1
            line:SetThickness(thickness)
            line:SetStartPoint("TOPLEFT", overlay, a.x * w, -a.y * h)
            line:SetEndPoint("TOPLEFT", overlay, b.x * w, -b.y * h)
            line:Show()
        end
    end
    return n
end

local function drawRoutes(c, w, h)
    local n = drawPaths(c, w, h, active.areas, true, 0)  -- area outlines always show
    if not (GearGuideDB and GearGuideDB.map and GearGuideDB.map.routes == false) then
        n = drawPaths(c, w, h, active.routes, false, n)
    end
    hideLines(n + 1)
    drawn.lines = n
end

-- A filled triangle: a plain texture over the triangle's bounding box with its four corners moved
-- onto the triangle (two share a point). Needs Texture:SetVertexOffset (modern clients); without
-- it areas are only outlined.
local function getTriangle(i, c)
    local layer = getOverlay(c)
    local t = triangles[i]
    if not t then
        t = layer:CreateTexture(nil, "ARTWORK")
        t:SetColorTexture(AREA_FILL[1], AREA_FILL[2], AREA_FILL[3], AREA_FILL[4])
        triangles[i] = t
    end
    return t
end

local function drawTriangle(t, c, ax, ay, bx, by, cx, cy)  -- canvas units, y pointing down
    local minX, maxX = math.min(ax, bx, cx), math.max(ax, bx, cx)
    local minY, maxY = math.min(ay, by, cy), math.max(ay, by, cy)
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", overlay, "TOPLEFT", minX, -minY)
    t:SetSize(math.max(1, maxX - minX), math.max(1, maxY - minY))
    -- corners: 1 upper left, 2 lower left, 3 upper right, 4 lower right; offsets have y pointing up
    t:SetVertexOffset(1, ax - minX, -(ay - minY))
    t:SetVertexOffset(2, bx - minX, -(by - maxY))
    t:SetVertexOffset(3, cx - maxX, -(cy - minY))
    t:SetVertexOffset(4, cx - maxX, -(cy - maxY))
    t:Show()
end

local function drawAreaFills(c, w, h)
    local n, failed = 0, 0
    for _, poly in ipairs(active.areas or {}) do
        local mx, my = 0, 0  -- areas are convex: a fan of triangles from the middle
        for _, p in ipairs(poly) do mx, my = mx + p.x, my + p.y end
        mx, my = mx / #poly * w, my / #poly * h
        for i = 1, #poly do
            if n >= MAX_TRIANGLES then break end
            local a, b = poly[i], poly[i % #poly + 1]
            local t = getTriangle(n + 1, c)
            if not t.SetVertexOffset then hideTriangles(); drawn.fill = "no SetVertexOffset" return end
            n = n + 1
            local ok, err = pcall(drawTriangle, t, c, mx, my, a.x * w, a.y * h, b.x * w, b.y * h)
            if not ok then t:Hide(); failed = failed + 1; drawn.fillError = drawn.fillError or tostring(err) end
        end
    end
    hideTriangles(n + 1)
    drawn.triangles, drawn.failed = n - failed, failed
end

-- Places pins when the displayed map is the one we want; called on a light timer while the map is open.
local function refreshPins()
    local c = canvas()
    if not active or not c or not WorldMapFrame:IsShown() then hideAll() return end
    local mapID = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
    if mapID ~= active.map then hideAll() return end
    local w, h = c:GetWidth(), c:GetHeight()
    local scale = 1 / canvasScale()  -- keep pins the same size when zooming
    local icon = ICONS[active.kind] or ICONS.drop
    drawAreaFills(c, w, h)
    drawRoutes(c, w, h)
    local shown = active.pins or active.points
    for i, p in ipairs(shown) do
        if i > MAX_PINS then break end
        local pin = getPin(i, c)
        pin:SetScale(scale)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", c, "TOPLEFT", p.x * w / scale, -p.y * h / scale)
        pin.icon:SetTexture(icon)
        pin:SetFrameLevel((c:GetFrameLevel() or 1) + 20)
        pin:Show()
    end
    for i = math.min(#shown, MAX_PINS) + 1, #pins do pins[i]:Hide() end
end

-- Is p inside the polygon (list of {x, y})? Ray casting.
local function inside(p, poly)
    local hit, j = false, #poly
    for i = 1, #poly do
        local a, b = poly[i], poly[j]
        if (a.y > p.y) ~= (b.y > p.y) and p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x then
            hit = not hit
        end
        j = i
    end
    return hit
end

-- Pins to draw: one in the middle of each area (biggest first), then every spawn outside the areas.
local function pinPoints(loc)
    local out = {}
    for _, poly in ipairs(loc.areas or {}) do
        local mx, my = 0, 0
        for _, p in ipairs(poly) do mx, my = mx + p.x, my + p.y end
        out[#out + 1] = { x = mx / #poly, y = my / #poly }
    end
    for _, p in ipairs(loc.points or {}) do
        local covered = false
        for _, poly in ipairs(loc.areas or {}) do
            if inside(p, poly) then covered = true break end
        end
        if not covered then out[#out + 1] = p end
    end
    return out
end
ns.MapPinPoints = pinPoints  -- (tests)

local function startWatcher()
    if watcher then return end
    watcher = CreateFrame("Frame")
    local elapsed = 0
    watcher:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.2 then return end
        elapsed = 0
        refreshPins()
    end)
end

local function openMap(mapID)
    if type(OpenWorldMap) == "function" then
        OpenWorldMap(mapID)
    elseif WorldMapFrame then
        if not WorldMapFrame:IsShown() then
            if ToggleWorldMap then ToggleWorldMap() else ShowUIPanel(WorldMapFrame) end
        end
        if WorldMapFrame.SetMapID then WorldMapFrame:SetMapID(mapID) end
    end
end

local function setWaypoint(mapID, p, title)
    -- The game's own user waypoint, where this client supports it.
    if C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
        local can = not C_Map.CanSetUserWaypointOnMap or C_Map.CanSetUserWaypointOnMap(mapID)
        if can then
            pcall(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(mapID, p.x, p.y))
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
                pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
            end
        end
    end
    -- TomTom, only if the player has it installed.
    local tomtom = rawget(_G, "TomTom")
    if tomtom and type(tomtom.AddWaypoint) == "function" then
        pcall(tomtom.AddWaypoint, tomtom, mapID, p.x, p.y, { title = title, persistent = false, minimap = true, world = true })
    end
end

-- Icon for a source line in the detail panel (same icons as the map pins).
function ns.MapIconFor(source)
    local loc = source and source.loc
    if loc and loc[1] and loc[1].e then return ICONS.entrance end
    if source and source.k == "object" then return ICONS.object end
    return ICONS[source and source.t] or ICONS.drop
end

-- loc = { map = uiMapID, points = { {x = 0..1, y = 0..1}, ... }, title = "Old Serra'kis",
--         sub = "Drop · Blackfathom Deeps (entrance)", kind = "drop"|"boss"|"vendor"|"quest"|"object"|"entrance",
--         routes = { { {x, y}, {x, y}, ... }, ... } (optional: a roaming NPC's walking paths),
--         areas = { { {x, y}, ... }, ... } (optional: convex outlines of where it spawns) }
function ns:ShowOnMap(loc)
    local hasRoute = loc and loc.routes and loc.routes[1] and loc.routes[1][1]
    if loc and loc.points then loc.pins = pinPoints(loc) end
    if not loc or not loc.map or not loc.points or (#loc.pins == 0 and not hasRoute) then
        ns.Print("No map location is known for this source yet.")
        return false
    end
    if InCombatLockdown and InCombatLockdown() and not (WorldMapFrame and WorldMapFrame:IsShown()) then
        ns.Print("The map can't be opened in combat; try again afterwards.")
        return false
    end
    active = loc
    openMap(loc.map)
    startWatcher()
    if not (GearGuideDB and GearGuideDB.map and GearGuideDB.map.waypoint == false) then
        setWaypoint(loc.map, loc.pins[1] or loc.routes[1][1], loc.title)  -- the biggest area first
    end
    wipe(drawn)
    refreshPins()
    if GearGuideDB and GearGuideDB.maintainer then
        ns.Print(string.format("Map: %d area(s), %d pin(s); drew %s filled triangles, %s outline/route lines%s%s",
            #(loc.areas or {}), #loc.pins, tostring(drawn.triangles or 0), tostring(drawn.lines or 0),
            drawn.fill and (", fill: " .. drawn.fill) or "",
            drawn.failed and drawn.failed > 0 and (", " .. drawn.failed .. " failed: " .. drawn.fillError) or ""))
    end
    return true
end

function ns:ClearMapPins()
    active = nil
    hideAll()
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
end
