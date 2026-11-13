local _, ns = ...

-- Shows where an item comes from on the world map: opens the map on the right zone and draws
-- GearGuide pins (creature / boss / vendor / quest giver / chest / dungeon entrance) at each spawn.
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

local pins, active = {}, nil   -- active = { map = uiMapID, points = {...}, routes = {...}, title, kind, sub }
local lines = {}
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

local function hideAll()
    for _, pin in ipairs(pins) do pin:Hide() end
    hideLines()
end

-- One straight piece of a walking route. Lines need Frame:CreateLine (modern clients); without it
-- the route simply isn't drawn and the pins still show.
local function getLine(i, parent)
    local line = lines[i]
    if not line then
        if not parent.CreateLine then return nil end
        line = parent:CreateLine(nil, "ARTWORK")
        line:SetColorTexture(LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3], LINE_COLOR[4])
        lines[i] = line
    end
    return line
end

local function drawRoutes(c, w, h)
    local n = 0
    local thickness = LINE_WIDTH / canvasScale()  -- same on-screen width at every zoom level
    for _, route in ipairs(active.routes or {}) do
        for i = 1, #route - 1 do
            if n >= MAX_SEGMENTS then break end
            local a, b = route[i], route[i + 1]
            local line = getLine(n + 1, c)
            if not line then return end
            n = n + 1
            line:SetThickness(thickness)
            line:SetStartPoint("TOPLEFT", c, a.x * w, -a.y * h)
            line:SetEndPoint("TOPLEFT", c, b.x * w, -b.y * h)
            line:Show()
        end
    end
    hideLines(n + 1)
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
    drawRoutes(c, w, h)
    for i, p in ipairs(active.points) do
        if i > MAX_PINS then break end
        local pin = getPin(i, c)
        pin:SetScale(scale)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", c, "TOPLEFT", p.x * w / scale, -p.y * h / scale)
        pin.icon:SetTexture(icon)
        pin:SetFrameLevel((c:GetFrameLevel() or 1) + 20)
        pin:Show()
    end
    for i = #active.points + 1, #pins do pins[i]:Hide() end
end

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
--         routes = { { {x, y}, {x, y}, ... }, ... } (optional: a roaming NPC's walking paths) }
function ns:ShowOnMap(loc)
    local hasRoute = loc and loc.routes and loc.routes[1] and loc.routes[1][1]
    if not loc or not loc.map or not loc.points or (#loc.points == 0 and not hasRoute) then
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
    setWaypoint(loc.map, loc.points[1] or loc.routes[1][1], loc.title)
    refreshPins()
    return true
end

function ns:ClearMapPins()
    active = nil
    hideAll()
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
end
