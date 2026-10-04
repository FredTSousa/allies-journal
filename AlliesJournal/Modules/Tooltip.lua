local addon = PlayerReview
local Tooltip = addon:NewModule("Tooltip", "AceEvent-3.0")


-- Flags a reviewed player's name in chat with a colored star, wherever it
-- shows up (general/trade chat, say/yell in the world, whispers, ...) - not
-- just while grouped with them. This is a marker prefixed onto the message
-- text, not a recolor of the name itself: Blizzard builds the clickable
-- "[Name]:" portion of a chat line separately from the message body, using
-- internal logic that doesn't expose a supported way to override just that
-- name's color per-sender. Patching the embedded hyperlink color code by
-- hand was considered and rejected - getting that pattern wrong risks
-- breaking the name's click-to-whisper/invite behavior, and there's no way
-- to verify the fix without a live client. This approach can't break
-- anything if it doesn't match: gsub just leaves the message untouched.
local CHAT_MARK_EVENTS = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_RAID_WARNING",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_OFFICER",
    "CHAT_MSG_WHISPER",
    "CHAT_MSG_WHISPER_INFORM",
    "CHAT_MSG_CHANNEL",
}

local function MarkReviewedSender(self, event, message, sender, ...)
    local nameRealm = addon:NormalizeChatSender(sender)
    local review = nameRealm and addon:GetLatestReview(nameRealm)
    if not review then return false end

    return false, "|cff" .. addon:GetWorstRatingHex(review) .. "★|r " .. message, sender, ...
end

-- Shows/hides a rating-colored badge in the corner of a unit frame (badge
-- rendering itself is shared with the LFG annotation module via
-- addon:ShowReviewBadge/HideReviewBadge in Core/Database.lua). Anchored to
-- the frame itself rather than any specific name/portrait element, so
-- unlike the abandoned name-recolor attempt this doesn't depend on knowing
-- the frame's internal field names - just that CreateTexture/SetPoint work
-- on it, which is true for any real Frame.
-- Placeholder review used by /pr badgetest so badge placement on party/raid
-- frames can be checked without being in a group.
local TEST_REVIEW = { social = "good", performance = "average" }

local function UpdateReviewBadge(frame, explicitUnit)
    if Tooltip.badgeTest then
        local b = addon.db.global.settings.badge
        if explicitUnit == "target" or explicitUnit == "focus" then
            addon:ShowReviewBadge(frame, TEST_REVIEW, b.unitSize, b.unitAnchorPoint, b.unitRelPoint, b.unitOffsetX, b.unitOffsetY)
        else
            addon:ShowReviewBadge(frame, TEST_REVIEW, b.groupSize, b.groupAnchorPoint, b.groupRelPoint, b.groupOffsetX, b.groupOffsetY)
        end
        return
    end

    -- explicitUnit lets callers that already know the unit from context
    -- (e.g. a PLAYER_TARGET_CHANGED handler) skip relying on frame.unit /
    -- frame.displayedUnit being set the way we'd guess.
    local unit = explicitUnit or frame.displayedUnit or frame.unit
    -- frame.displayedUnit/frame.unit are Blizzard-internal compact-frame
    -- fields that can be "secret" values on this client while grouped -
    -- passing one into UnitIsPlayer throws. That used to be an uncaught
    -- error; guarding it just made every party/raid frame skip the badge
    -- instead, so fall back to the secure "unit" ATTRIBUTE, which is how
    -- these buttons are actually bound to a unit and is a plain string.
    if unit and issecretvalue(unit) then unit = nil end
    if not unit and frame.GetAttribute then
        local ok, attribute = pcall(frame.GetAttribute, frame, "unit")
        if ok and attribute and not issecretvalue(attribute) then unit = attribute end
    end

    local review = nil
    if unit and UnitIsPlayer(unit) then
        local nameRealm = addon:GetFullName(unit)
        review = nameRealm and addon:GetLatestReview(nameRealm)
    end

    if Tooltip.nameDebug then
        addon:Print(string.format("[badge debug] frame=%s unit=%s reviewFound=%s",
            tostring(frame.GetName and frame:GetName()), tostring(unit), tostring(review ~= nil)))
    end

    if not review then
        addon:HideReviewBadge(frame)
        return
    end

    local b = addon.db.global.settings.badge
    if explicitUnit == "target" or explicitUnit == "focus" then
        addon:ShowReviewBadge(frame, review, b.unitSize, b.unitAnchorPoint, b.unitRelPoint, b.unitOffsetX, b.unitOffsetY)
    else
        -- Party/raid frames are much smaller than the target frame, so
        -- they get their own placement (Options > Badges).
        addon:ShowReviewBadge(frame, review, b.groupSize, b.groupAnchorPoint, b.groupRelPoint, b.groupOffsetX, b.groupOffsetY)
    end
end

-- EllesmereUI's raid frame OPTIONS preview draws its sample members as
-- anonymous frames under an anonymous container parented to UIParent, so
-- there's no name to look them up by. They do carry the _health and
-- _uniformRef fields its preview builder sets, which is how they're picked
-- out. Only used by /pr badgetest (they're fake members, never reviewed
-- players), so the walk over UIParent's children runs nowhere else.
local function ForEachEllesmerePreviewFrame(fn)
    local ok, tops = pcall(function() return { UIParent:GetChildren() } end)
    if not ok then return end
    for _, top in ipairs(tops) do
        local okKids, kids = pcall(function() return { top:GetChildren() } end)
        if okKids then
            for _, frame in ipairs(kids) do
                local isPreview = pcall(function() return frame._uniformRef and frame._health end)
                    and frame._uniformRef and frame._health
                if isPreview then pcall(fn, frame) end
            end
        end
    end
end

-- Target and focus frames: Blizzard's, and EllesmereUI's own (named
-- EllesmereUIUnitFrames_Target / _Focus - with it installed, those are the
-- ones on screen).
local UNIT_FRAMES = {
    { "TargetFrame", "target" },
    { "FocusFrame", "focus" },
    { "EllesmereUIUnitFrames_Target", "target" },
    { "EllesmereUIUnitFrames_Focus", "focus" },
}

local function RefreshUnitFrames(onlyUnit)
    for _, entry in ipairs(UNIT_FRAMES) do
        local frame = _G[entry[1]]
        if frame and (not onlyUnit or onlyUnit == entry[2]) then
            if UnitExists(entry[2]) or Tooltip.badgeTest then
                UpdateReviewBadge(frame, entry[2])
            else
                addon:HideReviewBadge(frame)
            end
        end
    end
end

-- Every party/raid frame style Blizzard can show: raid-style party frames,
-- raid frames (ungrouped and per-group), and the classic-style party
-- frames. Missing ones are simply skipped. Each is pcall'd so one odd
-- frame can't stop the rest.
local function ForEachGroupFrame(fn)
    local function Try(frame)
        if frame then pcall(fn, frame) end
    end
    for i = 1, 5 do Try(_G["CompactPartyFrameMember" .. i]) end
    for i = 1, 40 do Try(_G["CompactRaidFrame" .. i]) end
    for group = 1, 8 do
        for member = 1, 5 do Try(_G["CompactRaidGroup" .. group .. "Member" .. member]) end
    end
    for i = 1, 4 do
        Try(_G["PartyMemberFrame" .. i])
        if PartyFrame then Try(PartyFrame["MemberFrame" .. i]) end
    end

    -- EllesmereUI's RaidFrames replace Blizzard's compact frames (they hide
    -- them), so none of the above is what's on screen with it installed.
    -- Its party/raid frames are SecureGroupHeaderTemplate headers, and the
    -- buttons it shows are those headers' children, each bound to a unit
    -- through the secure "unit" attribute (which UpdateReviewBadge reads).
    local function TryHeader(header)
        if not header or not header.GetChildren then return end
        for _, child in ipairs({ header:GetChildren() }) do Try(child) end
    end
    if Tooltip.badgeTest then ForEachEllesmerePreviewFrame(Try) end
    TryHeader(_G.ERFPartyHeader)
    TryHeader(_G.ERFFlatHeader)
    for group = 1, 8 do TryHeader(_G["ERFGroupHeader" .. group]) end
    Try(_G.ERFPartySelfButton)
end

-- Blizzard's modern right-click unit menu has no single catch-all tag - each
-- frame type (party, raid, target, nameplate, chat name, friends/guild list)
-- registers its own, and the exact set has shifted across retail patches.
-- Cast a wide net; a tag that doesn't exist on this client is a harmless
-- no-op registration, not an error.
local UNIT_MENU_TAGS = {
    "MENU_UNIT_PLAYER",
    "MENU_UNIT_SELF",
    "MENU_UNIT_PARTY",
    "MENU_UNIT_RAID",
    "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_RAID_PLAYER_VEHICLE",
    "MENU_UNIT_ENEMY_PLAYER",
    "MENU_UNIT_FRIEND",
    "MENU_UNIT_BN_FRIEND",
    "MENU_UNIT_GUILD",
    "MENU_UNIT_COMMUNITIES_WOW_MEMBER",
    "MENU_UNIT_CHAT_ROSTER",
    "MENU_UNIT_WHO",
    "MENU_UNIT_VEHICLE",
    "MENU_UNIT_FOCUS",
    "MENU_UNIT_TARGET",
}

-- Chat names and /who results aren't live units at all (no unit token
-- exists for someone you're not grouped/nearby with), so contextData.unit
-- will be nil for those - this checks a handful of plausible field names
-- for the plain name string those menus are likely to carry instead.
-- Unconfirmed which one (if any) is actually right; menuDebug dumps the
-- whole table so the real field name can be confirmed instead of guessed
-- forever, and a wrong guess is low-risk here (worst case: a review filed
-- under a wrong name, which is just as deletable as any other).
local NAME_FIELD_CANDIDATES = { "name", "fullName", "presenceName", "chatName" }

local function AddReviewMenuButtons(tag, owner, rootDescription, contextData)
    local unit = contextData and contextData.unit

    if Tooltip.menuDebug then
        local parts = {}
        for k, v in pairs(contextData or {}) do
            table.insert(parts, tostring(k) .. "=" .. tostring(v))
        end
        addon:Print(string.format("[menu debug] tag=%s contextData={%s}", tostring(tag), table.concat(parts, ", ")))
    end

    if unit and not issecretvalue(unit) and UnitExists(unit) and UnitIsPlayer(unit) then
        if UnitIsUnit(unit, "player") then return end -- skip your own menu

        rootDescription:CreateButton("Add Note", function()
            addon:QueueUnitForReview(unit)
        end)

        local nameRealm = addon:GetFullName(unit)
        if nameRealm and addon:GetLatestReview(nameRealm) then
            rootDescription:CreateButton("View Journal", function()
                addon:GetModule("Browser"):ShowPlayer(nameRealm)
            end)
        end
        return
    end

    -- No unit - try the name-based path (chat names, /who results).
    local rawName
    if contextData then
        for _, field in ipairs(NAME_FIELD_CANDIDATES) do
            if type(contextData[field]) == "string" and contextData[field] ~= "" then
                rawName = contextData[field]
                break
            end
        end
    end
    if not rawName then return end

    local nameRealm = addon:NormalizeChatSender(rawName)
    if not nameRealm or nameRealm == addon:GetPlayerName() then return end

    rootDescription:CreateButton("Add Note", function()
        -- If they left the group recently enough to still have a
        -- recentDepartures snapshot (see RosterTracker), use it - that
        -- carries their real fight/chat data instead of an empty manual
        -- review. Otherwise, no /who check here unlike the /pr queuename
        -- slash command: this menu only ever exists because WoW already
        -- resolved rawName to a real entity to build it, so verifying
        -- again would just be redundant delay.
        if not addon:GetModule("RosterTracker"):QueueDeparted(nameRealm) then
            addon:DoQueueNameForReview(nameRealm)
        end
    end)

    if addon:GetLatestReview(nameRealm) then
        rootDescription:CreateButton("View Journal", function()
            addon:GetModule("Browser"):ShowPlayer(nameRealm)
        end)
    end
end

-- Each piece below is wrapped in its own pcall. This is not defensive
-- boilerplate for its own sake: GameTooltip:HookScript("OnTooltipSetUnit",
-- ...) used to be here unguarded, and on this client it throws (that script
-- was removed from GameTooltip when Blizzard replaced it with
-- TooltipDataProcessor around patch 10.2.5). Because that was the first
-- line of OnEnable, the error aborted the *entire* function - meaning the
-- chat marker, the name recolor hook, and the context-menu setup below it
-- never ran either. One incompatible API silently took down every feature.
-- Isolating each registration means a future API mismatch only disables
-- that one piece and prints why, instead of taking the whole module dark.
function Tooltip:OnEnable()
    local ok, err

    ok, err = pcall(function()
        if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall then
            -- Current API (10.2.5+): OnTooltipSetUnit was replaced by this.
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
                self:OnTooltipSetUnit(tooltip)
            end)
        elseif GameTooltip.HasScript and GameTooltip:HasScript("OnTooltipSetUnit") then
            -- Pre-10.2.5 fallback, only used if the script genuinely exists.
            GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip)
                self:OnTooltipSetUnit(tooltip)
            end)
        end
    end)
    if not ok then addon:Print("|cffff4040Tooltip hook failed|r: " .. tostring(err)) end

    ok, err = pcall(function()
        for _, event in ipairs(CHAT_MARK_EVENTS) do
            ChatFrame_AddMessageEventFilter(event, MarkReviewedSender)
        end
    end)
    if not ok then addon:Print("|cffff4040Chat marker hook failed|r: " .. tostring(err)) end

    -- Party/raid frames route name updates through this shared Blizzard
    -- function; badge it whenever that fires.
    -- UpdateName alone isn't enough: a frame whose unit gets (re)assigned
    -- or fully refreshed doesn't necessarily re-run it.
    for _, hookName in ipairs({ "CompactUnitFrame_UpdateName", "CompactUnitFrame_UpdateAll", "CompactUnitFrame_SetUnit" }) do
        ok, err = pcall(hooksecurefunc, hookName, function(frame) pcall(UpdateReviewBadge, frame) end)
        if not ok then addon:Print("|cffff4040Party/raid badge hook failed|r (" .. hookName .. "): " .. tostring(err)) end
    end

    -- Group changes (someone joins/leaves, raid converts) rearrange which
    -- frame shows whom - repaint after the frames have settled.
    -- Role assignment and name updates are what custom frame addons
    -- (EllesmereUI) react to when they reshuffle which button shows whom,
    -- so repaint on those too. (There used to be a repaint-every-2-seconds
    -- ticker for them; if badges ever land on the wrong player with such
    -- an addon, that's the thing to bring back.)
    pcall(function()
        self:RegisterEvent("GROUP_ROSTER_UPDATE")
        self:RegisterEvent("PLAYER_ROLES_ASSIGNED")
        self:RegisterEvent("UNIT_NAME_UPDATE")
    end)
    C_Timer.After(2, function() Tooltip:RefreshFrames() end)

    -- Target/Focus frames have historically used their own update path
    -- rather than CompactUnitFrame_UpdateName, so don't rely on that hook
    -- for them - just badge directly whenever the target/focus changes.
    ok, err = pcall(function()
        self:RegisterEvent("PLAYER_TARGET_CHANGED")
        self:RegisterEvent("PLAYER_FOCUS_CHANGED")
    end)
    if not ok then addon:Print("|cffff4040Target/focus hook failed|r: " .. tostring(err)) end

    -- Module OnEnable fires right after this addon's own files load, which
    -- can be before Blizzard's menu system (an on-demand-loaded UI addon)
    -- has set the `Menu` global. Registering here would silently no-op
    -- forever if `Menu` isn't ready yet, so defer to PLAYER_ENTERING_WORLD
    -- instead, by which point the rest of the UI is guaranteed loaded.
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "SetupUnitMenus")
end

function Tooltip:SetupUnitMenus()
    if self.menusRegistered then return end

    if not Menu or not Menu.ModifyMenu then
        addon:Print("Unit context menu hook unavailable - Menu.ModifyMenu not found on this client. Right-click 'Add Note'/'View Journal' won't appear; use /aj queue [unit] instead.")
        return
    end

    local attached = 0
    for _, tag in ipairs(UNIT_MENU_TAGS) do
        local ok = pcall(Menu.ModifyMenu, tag, function(owner, rootDescription, contextData)
            local ok2, err = pcall(AddReviewMenuButtons, tag, owner, rootDescription, contextData)
            if not ok2 then
                addon:Print("|cffff4040Menu hook error|r (" .. tag .. "): " .. tostring(err))
            end
        end)
        if ok then attached = attached + 1 end
    end

    self.menusRegistered = true
    addon:Print(string.format("Unit context menu hook attached (%d/%d tags).", attached, #UNIT_MENU_TAGS))
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
end

function Tooltip:OnTooltipSetUnit(tooltip)
    local ok, err = pcall(function()
        local _, unit = tooltip:GetUnit()

        -- unit can be a "secret" value in some contexts on this client
        -- (e.g. actively grouped) - passing a secret value straight into
        -- UnitIsPlayer throws even though this whole function is pcall-
        -- wrapped, which just meant it errored loudly on every single
        -- group member's tooltip. Same issecretvalue() guard
        -- ReviewCapture.lua already uses for this exact WoW security
        -- mechanism around damage-meter data.
        if not unit or issecretvalue(unit) then
            if self.nameDebug then
                addon:Print(string.format("[tooltip debug] fired, unit=%s%s",
                    tostring(unit), (unit and issecretvalue(unit)) and " (secret)" or ""))
            end
            return
        end

        if self.nameDebug then
            addon:Print(string.format("[tooltip debug] fired, unit=%s, isPlayer=%s",
                tostring(unit), tostring(UnitIsPlayer(unit))))
        end

        if not UnitIsPlayer(unit) then return end

        local nameRealm = addon:GetFullName(unit)
        local review = nameRealm and addon:GetLatestReview(nameRealm)

        if self.nameDebug then
            addon:Print(string.format("[tooltip debug] nameRealm=%s, reviewFound=%s",
                tostring(nameRealm), tostring(review ~= nil)))
        end

        if not review then return end

        local tooltipSettings = addon.db.global.settings.tooltip
        -- Extra horizontal room to the right of the tooltip's normal
        -- content width, so long note lines don't render as narrow as
        -- Blizzard's own auto-sizing would otherwise make them. Not part
        -- of every client build's GameTooltip, hence the pcall.
        if tooltipSettings.paddingRight and tooltipSettings.paddingRight > 0 then
            pcall(function() tooltip:SetPadding(tooltipSettings.paddingRight) end)
        end
        local vars = addon:GetReviewTooltipVars(review, nameRealm)
        for _, renderedLine in ipairs(addon:RenderTooltipTemplate(tooltipSettings.worldTemplate, vars)) do
            tooltip:AddLine(renderedLine, 1, 1, 1, true)
        end
        tooltip:Show()
    end)

    if not ok then
        addon:Print("|cffff4040Tooltip content error|r: " .. tostring(err))
    end
end

-- One-shot introspection tool: dumps every FontString/Texture/Frame region
-- directly on a unit's nameplate (and its .UnitFrame, if any), with each
-- FontString's current text. CompactUnitFrame_UpdateName never firing for
-- Darkotter-Pallyy's nameplate means the assumed frame.name field was never
-- actually confirmed to exist - this reads the real structure from the
-- live client instead of guessing another field/function name blind.
function Tooltip:InspectNameplate(unit)
    unit = (unit and unit ~= "") and unit or "target"
    if not UnitExists(unit) then
        addon:Print("No such unit: " .. unit)
        return
    end

    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then
        addon:Print("No nameplate found for " .. unit .. " (out of range, or nameplates off for this unit type?)")
        return
    end

    local function DumpRegions(frame, label)
        if not frame then
            addon:Print("  " .. label .. ": (does not exist)")
            return
        end
        addon:Print("  " .. label .. " exists, regions:")
        for i, region in ipairs({ frame:GetRegions() }) do
            local kind = region.GetObjectType and region:GetObjectType() or "?"
            if kind == "FontString" then
                addon:Print(string.format("    [%d] FontString text=%q", i, region:GetText() or ""))
            else
                addon:Print(string.format("    [%d] %s", i, kind))
            end
        end
    end

    addon:Print("Inspecting nameplate for " .. unit .. ":")
    DumpRegions(plate, "plate")
    DumpRegions(plate.UnitFrame, "plate.UnitFrame")
end

-- Recursively scans a root frame's descendants for any FontString whose
-- text contains searchText, printing the parent-frame path to each match.
-- Generalized so it works for any "where does this text live" question, not
-- just the nameplate case it was originally built for - e.g. a Group Finder
-- applicant name, which isn't a `unit` at all so can't go through
-- FindNameText. Bounded so a one-shot debug scan can't hang the client.
local function ScanForText(root, rootLabel, searchText)
    addon:Print(string.format("Scanning %s for FontStrings containing %q (may take a few seconds)...", rootLabel, searchText))

    local found, visited = 0, 0
    local MAX_VISITED, MAX_FOUND = 40000, 20

    local function Scan(frame, path)
        if found >= MAX_FOUND or visited >= MAX_VISITED or not frame then return end
        -- Some frames (Group Finder in particular) are marked "forbidden" -
        -- a WoW taint-security mechanism where even read-only calls like
        -- GetName() throw from addon code. Skip them (and their subtree)
        -- entirely rather than let one forbidden frame kill the whole scan.
        if frame.IsForbidden and frame:IsForbidden() then return end
        visited = visited + 1

        if frame.GetRegions then
            pcall(function()
                for _, region in ipairs({ frame:GetRegions() }) do
                    if region.GetObjectType and region:GetObjectType() == "FontString" then
                        local text = region:GetText()
                        -- Skip chat edit boxes: they'll "find" whatever you
                        -- just typed to run this very command, which is
                        -- noise, not a real result.
                        if text and text:find(searchText, 1, true) and not path:find("EditBox", 1, true) then
                            found = found + 1
                            addon:Print(string.format("  FOUND [%d]: %q  (path: %s)", found, text, path))
                        end
                    end
                end
            end)
        end

        if frame.GetChildren then
            local ok, children = pcall(function() return { frame:GetChildren() } end)
            if ok then
                for _, child in ipairs(children) do
                    if found >= MAX_FOUND or visited >= MAX_VISITED then break end
                    -- Type-checked, not just pcall-guarded: some widget on
                    -- this client returned a non-string from GetName() and
                    -- crashed the concatenation below. Whatever it is, force
                    -- it to a safe string instead of tracking down why.
                    local okName, childName = pcall(function() return child.GetName and child:GetName() end)
                    if not okName or type(childName) ~= "string" or childName == "" then
                        childName = "?"
                    end
                    Scan(child, path .. "/" .. childName)
                end
            end
        end
    end

    Scan(root, rootLabel)
    addon:Print(string.format("Scan complete: %d frames visited, %d matches found.", visited, found))
    if found == 0 then
        addon:Print("No FontString found containing that text under " .. rootLabel .. " - it's either rendered directly by the game engine (not addon-accessible), or lives outside this root.")
    end
end

function Tooltip:FindNameText(unit)
    unit = (unit and unit ~= "") and unit or "target"
    if not UnitExists(unit) then
        addon:Print("No such unit: " .. unit)
        return
    end

    local name = UnitName(unit)
    if not name then
        addon:Print("Could not get a name for " .. unit)
        return
    end

    ScanForText(UIParent, "UIParent", name)
end

-- For text that isn't tied to a live unit at all - e.g. a name in a Group
-- Finder listing, which you can't target or run UnitName() on.
function Tooltip:FindText(text)
    if not text or text == "" then
        addon:Print("Usage: /aj findtext <text to search for>")
        return
    end
    ScanForText(UIParent, "UIParent", text)
end

-- Dumps the regions (and a couple of common named sub-frames) of any global
-- frame by name - e.g. TargetFrame, PlayerFrame, CompactPartyFrameMember1,
-- CompactRaidFrame1. Unlike nameplates, party/raid/target frames are fixed,
-- persistent, globally-named frames, so this doesn't need a live unit or
-- C_NamePlate at all.
function Tooltip:InspectFrame(frameName)
    if not frameName or frameName == "" then
        addon:Print("Usage: /aj inspectframe <GlobalFrameName>  e.g. TargetFrame, PlayerFrame, CompactPartyFrameMember1")
        return
    end

    local frame = _G[frameName]
    if not frame then
        addon:Print("No such global frame: " .. frameName)
        return
    end

    local function DumpRegions(f, label)
        if not f then
            addon:Print("  " .. label .. ": (does not exist)")
            return
        end

        -- A field like `.name` is often the FontString itself, not a
        -- container to dig into further - GetRegions() only exists on
        -- Frames, so check the object's own type first instead of treating
        -- a "failure" as a dead end.
        local kind = f.GetObjectType and f:GetObjectType() or "?"
        if kind == "FontString" then
            addon:Print(string.format("  %s IS a FontString directly, text=%q", label, f:GetText() or ""))
            return
        end

        local ok, regions = pcall(function() return { f:GetRegions() } end)
        if not ok then
            addon:Print("  " .. label .. ": not a Frame, no regions (type=" .. kind .. ")")
            return
        end
        addon:Print("  " .. label .. " (" .. kind .. ") regions:")
        for i, region in ipairs(regions) do
            local rkind = region.GetObjectType and region:GetObjectType() or "?"
            if rkind == "FontString" then
                addon:Print(string.format("    [%d] FontString text=%q", i, region:GetText() or ""))
            else
                addon:Print(string.format("    [%d] %s", i, rkind))
            end
        end
    end

    addon:Print("Inspecting frame: " .. frameName)
    DumpRegions(frame, frameName)
    for _, sub in ipairs({ "name", "Name", "UnitFrame" }) do
        if frame[sub] then
            DumpRegions(frame[sub], frameName .. "." .. sub)
        end
    end
end

function Tooltip:PLAYER_TARGET_CHANGED()
    RefreshUnitFrames("target")
end

function Tooltip:PLAYER_FOCUS_CHANGED()
    RefreshUnitFrames("focus")
end

-- Repaint right away, then again once the frames have settled (a custom
-- frame addon may only move players between its buttons a moment later).
function Tooltip:GROUP_ROSTER_UPDATE()
    self:RefreshFrames()
    C_Timer.After(0.5, function() Tooltip:RefreshFrames() end)
    C_Timer.After(2, function() Tooltip:RefreshFrames() end)
end

function Tooltip:PLAYER_ROLES_ASSIGNED()
    C_Timer.After(0.5, function() Tooltip:RefreshFrames() end)
end

-- Fires for every unit in the world, so only group members matter here,
-- and bursts are collapsed into one repaint.
function Tooltip:UNIT_NAME_UPDATE(_, unit)
    if type(unit) ~= "string" or not (unit:find("^party") or unit:find("^raid")) then return end
    if self.namePending then return end
    self.namePending = true
    C_Timer.After(0.3, function()
        Tooltip.namePending = nil
        Tooltip:RefreshFrames()
    end)
end

-- A frame already on screen when a review gets saved won't necessarily
-- repaint on its own, so this is called after every save to force it -
-- directly, rather than relying solely on the hooks/events above.
-- /pr badgetest: toggles fake badges on every party/raid frame the scan
-- finds, and reports how many that is (and how many are on screen).
function Tooltip:ToggleBadgeTest()
    self.badgeTest = not self.badgeTest
    local found, visible = 0, 0
    ForEachGroupFrame(function(frame)
        found = found + 1
        if frame.IsVisible and frame:IsVisible() then visible = visible + 1 end
    end)
    self:RefreshFrames()
    addon:Print(string.format("Badge test %s - the scan found %d party/raid frame(s), %d visible.%s",
        self.badgeTest and "ON (fake badge on every found frame)" or "off",
        found, visible,
        (self.badgeTest and visible == 0) and " None are on screen: show party/raid frames (Edit Mode preview, or join a group) and run it again." or ""))
end

function Tooltip:RefreshFrames()
    RefreshUnitFrames()
    ForEachGroupFrame(UpdateReviewBadge)
end

-- Repaints now and again shortly after. Used when a review is saved: a
-- custom frame addon (EllesmereUI) may redraw its own buttons a moment
-- later, and a badge painted before that can be lost.
function Tooltip:RefreshFramesSoon()
    self:RefreshFrames()
    C_Timer.After(0.5, function() Tooltip:RefreshFrames() end)
    C_Timer.After(2, function() Tooltip:RefreshFrames() end)
end
