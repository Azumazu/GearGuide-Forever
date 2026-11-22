local _, ns = ...

-- In-game source sharing between GearGuide users (realm, guild and group), opt-out via the
-- "Sharing" button or /gg sharing off.
--   Sent:     item ID, source type, creature/quest/vendor name, zone. Nothing about the player:
--             no inventory, gear, level, gold or play time.
--   Channels: invisible addon messages to GUILD / PARTY / RAID, and to a hidden custom chat channel
--             (CHANNEL_NAME) that every GearGuide copy with sharing on joins, so users on the same
--             realm reach each other without meeting. The channel is taken out of the chat windows
--             and its notices are filtered: nothing appears in chat. Left when sharing is turned
--             off. If joining fails (all channel slots used, or a client that blocks it), guild and
--             group sharing still work.
--   Load:     only sources this player saw for the first time, batched, max one message per
--             SEND_INTERVAL, never in combat or instances (Blizzard UI Add-On Policy rule 3).
--   Received: validated, only for items in our database, capped per sender; stored separately in
--             GearGuideLearned.shared with a count of distinct senders per session (names are not
--             stored). Releases ship a shared source only after 3+ reports (build_db.py).
--   Version:  "V^1.2.3" rides along (once per session per channel kind). Hearing a newer version
--             prints an update notice once; hearing an older one answers with ours so its owner
--             gets the notice. Addons can't reach the internet: this is how GearGuide learns that a
--             new version is out. Older versions ignore the entry (it isn't a valid source).

local PREFIX = "GGSRC1"            -- addon message prefix (max 16 chars), versioned
local SEND_INTERVAL = 10           -- seconds between messages
local MAX_MESSAGE = 240            -- addon messages are limited to 255 bytes
local OUTBOX_LIMIT = 200
local RECENT_LIMIT = 40            -- own observations re-shared once when joining a group / logging in
local MAX_PER_SENDER = 300         -- accepted entries per sender per session
local MAX_NAME, MAX_ZONE = 60, 40
local CHANNEL_NAME = "GearGuideShare"
local JOIN_DELAY = 15              -- seconds after login, so General/Trade/LocalDefense keep numbers 1-4
local TYPE_CODE = { drop = "d", quest = "q", vendor = "v", craft = "c" }
local CODE_TYPE = { d = "drop", q = "quest", v = "vendor", c = "craft" }

local sendAddon = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage
local registerPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix

local outbox = {}
local REPLY_COOLDOWN = 300         -- seconds between version answers to older versions
local lastReply = -REPLY_COOLDOWN
local heardFrom = {}       -- sourceKey -> { [sender] = true } this session only (not saved)
local senderCount = {}     -- sender -> entries accepted this session
local sharedRecentDone = { GUILD = false, GROUP = false, CHANNEL = false }
local ticker

function ns:IsSharingEnabled()
    return GearGuideDB and GearGuideDB.sharing ~= false
end

---------------------------------------------------------------------------
-- Encoding: "<id>^<t>^<name>^<zone>" entries joined by ";"; zone "#123" = area ID
---------------------------------------------------------------------------
local function clean(text, limit)
    text = tostring(text or ""):gsub("[%^;|%c]", " ")
    return text:sub(1, limit)
end

local function encode(id, src)
    local zone = src.z
    if type(zone) == "number" then zone = "#" .. zone else zone = clean(zone, MAX_ZONE) end
    return table.concat({ id, TYPE_CODE[src.t] or "d", clean(src.n, MAX_NAME), zone }, "^")
end

local function decode(entry)
    local id, code, name, zone = entry:match("^(%d+)%^(%a)%^([^%^]*)%^([^%^]*)$")
    id = tonumber(id)
    if not id or not CODE_TYPE[code] or name == "" or #name > MAX_NAME or #zone > MAX_ZONE + 1 then return nil end
    local z = zone:match("^#(%d+)$")
    return id, { t = CODE_TYPE[code], n = name, z = z and tonumber(z) or (zone ~= "" and zone or nil) }
end

---------------------------------------------------------------------------
-- Version check
---------------------------------------------------------------------------
local function myVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local v = get and get("GearGuide", "Version")
    return type(v) == "string" and v:match("^%d+%.%d+%.%d+$") and v or nil
end

-- Is version a newer than b? ("0.13.0" > "0.12.10")
function ns.VersionNewer(a, b)
    local a1, a2, a3 = a:match("^(%d+)%.(%d+)%.(%d+)$")
    local b1, b2, b3 = b:match("^(%d+)%.(%d+)%.(%d+)$")
    if not (a1 and b1) then return false end
    a1, a2, a3, b1, b2, b3 = tonumber(a1), tonumber(a2), tonumber(a3), tonumber(b1), tonumber(b2), tonumber(b3)
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    return a3 > b3
end

local function versionEntry()
    local v = myVersion()
    return v and ("V^" .. v) or nil
end

local enqueue  -- (defined below)
local function heardVersion(v)
    local mine = myVersion()
    if not mine or v == mine then return end
    if ns.VersionNewer(v, mine) then
        if not ns.newerVersion or ns.VersionNewer(v, ns.newerVersion) then
            local first = ns.newerVersion == nil
            ns.newerVersion = v
            if first then
                ns.Print(string.format("A newer version of GearGuide is out (%s, you have %s). "
                    .. "Update it from CurseForge or your addon manager.", v, mine))
            end
            if ns.RefreshUI then ns:RefreshUI() end
        end
    elseif ns.VersionNewer(mine, v) and GetTime() - lastReply >= REPLY_COOLDOWN then
        lastReply = GetTime()
        enqueue(versionEntry())  -- tell the older copy that a newer one exists
    end
end

local function sourceKey(id, s)
    return id .. "^" .. (s.t or "") .. "^" .. (s.n or "") .. "^" .. tostring(s.z or "")
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
local function canSendNow()
    if not ns:IsSharingEnabled() then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    if IsInInstance then
        local inInstance = IsInInstance()
        if inInstance then return false end
    end
    return true
end

-- The hidden channel's number in this session's channel list (0 = not joined).
local function channelIndex()
    if not GetChannelName then return 0 end
    local ok, id = pcall(GetChannelName, CHANNEL_NAME)
    id = ok and ns.Plain(id)
    return type(id) == "number" and id or 0
end
ns.ShareChannelIndex = channelIndex

-- Targets: "GUILD" / "PARTY" / "RAID", or { "CHANNEL", number } for the hidden channel.
local function channels()
    local list = {}
    local chan = channelIndex()
    if chan > 0 then list[#list + 1] = { "CHANNEL", chan } end
    if IsInGuild and IsInGuild() then list[#list + 1] = "GUILD" end
    if IsInRaid and IsInRaid() then
        list[#list + 1] = "RAID"
    elseif IsInGroup and IsInGroup() then
        list[#list + 1] = "PARTY"
    end
    return list
end

local function flush()
    if #outbox == 0 or not canSendNow() or not sendAddon then return end
    local targets = channels()
    if #targets == 0 then return end
    -- Pack as many entries as fit into one message.
    local parts, size = {}, 0
    while #outbox > 0 do
        local entry = outbox[1]
        if size + #entry + 1 > MAX_MESSAGE and #parts > 0 then break end
        table.remove(outbox, 1)
        parts[#parts + 1] = entry
        size = size + #entry + 1
    end
    local message = table.concat(parts, ";")
    for _, channel in ipairs(targets) do
        if type(channel) == "table" then
            pcall(sendAddon, PREFIX, message, channel[1], channel[2])
        else
            pcall(sendAddon, PREFIX, message, channel)
        end
    end
end

function enqueue(entry)
    if not entry then return end
    for _, e in ipairs(outbox) do if e == entry then return end end
    if #outbox >= OUTBOX_LIMIT then table.remove(outbox, 1) end
    outbox[#outbox + 1] = entry
end

-- Called by Sources.lua when this player sees a source for the first time.
function ns:QueueShare(id, src)
    if not self:IsSharingEnabled() or not id or not src or src.shared then return end
    local entry = encode(id, src)
    enqueue(entry)
    local recent = GearGuideLearned.recentShared
    recent[#recent + 1] = entry
    while #recent > RECENT_LIMIT do table.remove(recent, 1) end
end

-- Once per session per channel kind: re-share recent own observations (helps guildmates who were offline).
local function shareRecent(kind)
    if sharedRecentDone[kind] or not ns:IsSharingEnabled() then return end
    sharedRecentDone[kind] = true
    enqueue(versionEntry())
    for _, entry in ipairs(GearGuideLearned.recentShared) do enqueue(entry) end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local function isSelf(sender)
    local me = ns.Plain(UnitName("player"))
    if not sender or not me then return false end
    local short = Ambiguate and Ambiguate(sender, "none") or sender:match("^[^-]+")
    return short == me
end

local function receive(message, sender)
    if not ns:IsSharingEnabled() or isSelf(sender) or #message > 255 then return end
    local accepted = senderCount[sender] or 0
    for entry in message:gmatch("[^;]+") do
        local v = entry:match("^V%^(%d+%.%d+%.%d+)$")
        if v then heardVersion(v) end
        if accepted >= MAX_PER_SENDER then break end
        local id, src = decode(entry)
        if id and ns:GetItem(id) then  -- only items we know: no junk IDs from strangers
            local key = sourceKey(id, src)
            heardFrom[key] = heardFrom[key] or {}
            if not heardFrom[key][sender] then
                heardFrom[key][sender] = true
                accepted = accepted + 1
                local list = GearGuideLearned.shared[id]
                if not list then list = {}; GearGuideLearned.shared[id] = list end
                local found
                for _, s in ipairs(list) do
                    if sourceKey(id, s) == key then found = s break end
                end
                if found then
                    found.c = math.min((found.c or 1) + 1, 99)
                elseif #list < 12 and not (ns.IsJunkSourceName and ns.IsJunkSourceName(src.n)) then
                    list[#list + 1] = { t = src.t, n = src.n, z = src.z, c = 1 }
                    ns:RequestRefresh()  -- a first source can make the item listable
                end
            end
        end
    end
    senderCount[sender] = accepted
end

-- Shared sources for an item, for display (marked so the tooltip can label them).
function ns:GetSharedSources(id)
    local list = GearGuideLearned.shared and GearGuideLearned.shared[id]
    if not list then return nil end
    local out = {}
    for _, s in ipairs(list) do out[#out + 1] = { t = s.t, n = s.n, z = s.z, shared = s.c or 1 } end
    return out
end

---------------------------------------------------------------------------
-- The hidden realm channel
---------------------------------------------------------------------------
local function hideChannel()
    if not ChatFrame_RemoveChannel then return end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local cf = _G["ChatFrame" .. i]
        if cf then pcall(ChatFrame_RemoveChannel, cf, CHANNEL_NAME) end
    end
end

local function joinChannel()
    if not ns:IsSharingEnabled() or not JoinTemporaryChannel then return end
    if InCombatLockdown and InCombatLockdown() then  -- chat channel calls are blocked then: retry
        C_Timer.After(JOIN_DELAY, joinChannel)
        return
    end
    if channelIndex() == 0 then pcall(JoinTemporaryChannel, CHANNEL_NAME) end
    C_Timer.After(3, function()
        hideChannel()
        if channelIndex() > 0 then shareRecent("CHANNEL") end
    end)
end

local function leaveChannel()
    if channelIndex() > 0 and LeaveChannelByName then pcall(LeaveChannelByName, CHANNEL_NAME) end
    sharedRecentDone.CHANNEL = false
end

-- Chat filter: hides "Joined Channel: GearGuideShare" and the channel's other notices.
local OUR_CHANNEL = CHANNEL_NAME:lower()
local function isOurNotice(_, _, ...)
    for i = 4, 9 do
        local v = ns.Plain((select(i, ...)))
        if type(v) == "string" and v:lower():find(OUR_CHANNEL, 1, true) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Setup and opt-out
---------------------------------------------------------------------------
function ns:SetSharing(on)
    GearGuideDB.sharing = on and true or false
    if on then joinChannel() else wipe(outbox); leaveChannel() end
    ns.Print(on and "Source sharing is on: new item sources you find are shared with GearGuide users on your realm, "
        .. "in your guild and in your group."
        or "Source sharing is off: GearGuide no longer sends or receives item sources.")
    if ns.RefreshUI then ns:RefreshUI() end
end

function ns:StartComm()
    GearGuideLearned.shared = GearGuideLearned.shared or {}
    GearGuideLearned.recentShared = GearGuideLearned.recentShared or {}
    if GearGuideDB.sharing == nil then GearGuideDB.sharing = true end
    -- Notice version 2: shown again once, since sharing now reaches the realm, not only guild and group.
    if GearGuideDB.sharingNotice ~= 2 and GearGuideDB.sharing then
        ns.Print("GearGuide shares item sources (which creature, quest or vendor gives an item) with other "
            .. "GearGuide users on your realm, in your guild and in your group, invisibly and without any "
            .. "character data: never your inventory, gear, level or gold. "
            .. "Turn it off with the Sharing button in the window or /gg sharing off.")
    end
    GearGuideDB.sharingNotice = 2
    if registerPrefix then pcall(registerPrefix, PREFIX) end

    local f = CreateFrame("Frame")
    for _, e in ipairs({ "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE", "PLAYER_GUILD_UPDATE" }) do
        pcall(f.RegisterEvent, f, e)
    end
    f:SetScript("OnEvent", function(_, event, prefix, message, _, sender)
        if event == "CHAT_MSG_ADDON" then
            -- Secret (client-protected) values can't be used as keys or parsed: skip those messages.
            prefix, message, sender = ns.Plain(prefix), ns.Plain(message), ns.Plain(sender)
            if prefix == PREFIX and type(message) == "string" and type(sender) == "string" then
                receive(message, sender)
            end
        elseif event == "GROUP_ROSTER_UPDATE" then
            if IsInGroup and IsInGroup() then shareRecent("GROUP") else sharedRecentDone.GROUP = false end
        end
    end)
    C_Timer.After(60, function()
        if IsInGuild and IsInGuild() then shareRecent("GUILD") end
    end)
    if ChatFrame_AddMessageEventFilter then
        for _, e in ipairs({ "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER" }) do
            ChatFrame_AddMessageEventFilter(e, isOurNotice)
        end
    end
    C_Timer.After(JOIN_DELAY, joinChannel)
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(SEND_INTERVAL, flush)
end
