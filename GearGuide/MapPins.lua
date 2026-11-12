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

local pins, active = {}, nil   -- active = { map = uiMapID, points = {...}, title, kind, sub }
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

local function hideAll()
    for _, pin in ipairs(pins) do pin:Hide() end
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
--         sub = "Drop · Blackfathom Deeps (entrance)", kind = "drop"|"boss"|"vendor"|"quest"|"object"|"entrance" }
function ns:ShowOnMap(loc)
    if not loc or not loc.map or not loc.points or #loc.points == 0 then
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
    setWaypoint(loc.map, loc.points[1], loc.title)
    refreshPins()
    return true
end

function ns:ClearMapPins()
    active = nil
    hideAll()
    if C_Map and C_Map.ClearUserWaypoint then pcall(C_Map.ClearUserWaypoint) end
end
