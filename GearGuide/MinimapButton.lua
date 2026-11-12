local _, ns = ...

-- A small draggable minimap icon (no library dependency).
local button

local function updatePosition()
    local angle = math.rad(GearGuideDB.minimap.angle or 225)
    local radius = (Minimap:GetWidth() / 2) + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function onDragUpdate()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    cx, cy = cx / scale, cy / scale
    GearGuideDB.minimap.angle = math.deg(math.atan2(cy - my, cx - mx))
    updatePosition()
end

function ns:CreateMinimapButton()
    if button then return end
    button = CreateFrame("Button", "GearGuideMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\GearGuide\\Media\\icon")  -- GearGuide logo (Media/icon.tga)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")

    button:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onDragUpdate) end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            ns:ShowWindow("browser")
        elseif IsShiftKeyDown() then
            ns:ToggleMini()
        else
            ns:ToggleWindow()
        end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("GearGuide")
        GameTooltip:AddLine("Left-click: recommendations", 1, 1, 1)
        GameTooltip:AddLine("Shift-left-click: toggle mini tracker", 1, 1, 1)
        GameTooltip:AddLine("Right-click: gear browser", 1, 1, 1)
        GameTooltip:AddLine("Drag: move icon", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    self:UpdateMinimapButton()
end

function ns:UpdateMinimapButton()
    if not button then return end
    if GearGuideDB.minimap.hide then
        button:Hide()
    else
        updatePosition()
        button:Show()
    end
end
