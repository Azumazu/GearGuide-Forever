local addonName, ns = ...

---------------------------------------------------------------------------
-- "NEW" badges: after an update, a small badge marks the standout features that are brand new in
-- this version. Each shows once per account: it goes away when the player clicks the feature (or,
-- for things you just look at, once it has been seen) and never comes back. Fresh installs get no
-- badges (everything is new to them), and a badge only shows in the version its feature arrived in.
---------------------------------------------------------------------------
-- feature key -> the version it's new in. Add new standout features here with their version.
ns.NEW_FEATURES = {
    simulatorTab = "0.17.0",  -- Build Simulator tab
    instanceMenu = "0.17.0",  -- Gear Browser: dungeon and raid menu
    ignoreButton = "0.17.0",  -- item details: Ignore button
}

local function addonVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return get and get(addonName, "Version") or nil
end

-- Called at ADDON_LOADED. updating: GearGuide's saved settings existed before this load.
function ns:NoteVersion(updating)
    local db, current = GearGuideDB, addonVersion()
    if not db or not current or db.version == current then return end
    -- A new version: its features are new to players who had an older one (also older versions that
    -- didn't record theirs). A fresh install gets no badges.
    db.newIn = updating and current or nil
    db.version = current
    db.seenNew = db.seenNew or {}
end

function ns:IsNewFeature(key)
    local db = GearGuideDB
    return db ~= nil and db.newIn ~= nil and db.newIn == db.version and ns.NEW_FEATURES[key] == db.newIn
        and not (db.seenNew and db.seenNew[key])
end

function ns:MarkFeatureSeen(key)
    if not GearGuideDB then return end
    GearGuideDB.seenNew = GearGuideDB.seenNew or {}
    GearGuideDB.seenNew[key] = true
end

-- Puts a small copper "NEW" pill on target's top-right corner, if `key` is new to this player.
-- mode "click": until the target is clicked. "view": seen as soon as it's shown; the badge stays
-- while it's on screen and is gone the next time it hides.
function ns:AttachNewBadge(target, key, mode)
    if not target or not self:IsNewFeature(key) then return nil end
    local Skin = ns.Skin
    local badge = CreateFrame("Frame", nil, target)
    badge:SetSize(28, 13)
    badge:SetPoint("CENTER", target, "TOPRIGHT", -6, -1)
    if badge.SetFrameLevel and target.GetFrameLevel then badge:SetFrameLevel((target:GetFrameLevel() or 1) + 5) end
    local bg = badge:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    local c = Skin:Color("accent")
    bg:SetColorTexture(c[1], c[2], c[3], 1)
    local fs = Skin:Text(badge, 9, "bg")
    fs:SetPoint("CENTER", 0, 0)
    fs:SetText("NEW")
    fs:SetTextColor(0.12, 0.09, 0.06, 1)
    fs:SetShadowOffset(0, 0)
    badge.key = key

    local function seen()
        ns:MarkFeatureSeen(key)
    end
    if mode == "view" then
        target:HookScript("OnShow", seen)
        if target:IsVisible() then seen() end
        target:HookScript("OnHide", function()
            if GearGuideDB.seenNew and GearGuideDB.seenNew[key] then badge:Hide() end
        end)
    else
        target:HookScript("OnMouseDown", function() seen(); badge:Hide() end)
    end
    return badge
end
