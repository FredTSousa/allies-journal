local addon = AlliesJournal
local Tooltip = addon:NewModule("Tooltip", "AceEvent-3.0")


-- The chat star is drawn by ChatMarkers.lua (an icon, switchable in the
-- options). A text "★" used to be added here too; the game's chat font has
-- no such character, so it showed as an empty box.

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

-- Blizzard's nameplates are built from the same CompactUnitFrame code as
-- party/raid frames, so the CompactUnitFrame_* hooks below fire for them
-- too. Nameplates get their own badge (UpdatePlateBadge), so those calls
-- are turned away here instead of painting a second, party-sized badge.
-- Checked by structure (the plate's UnitFrame field) first, since the
-- frame's unit field can be a secret value.
local function IsNameplateUnitFrame(frame)
    local parent = frame.GetParent and frame:GetParent()
    if parent and parent.UnitFrame == frame then return true end
    local unit = frame.displayedUnit or frame.unit
    return type(unit) == "string" and not issecretvalue(unit) and unit:find("^nameplate") ~= nil
end

local function UpdateReviewBadge(frame, explicitUnit)
    if not explicitUnit and IsNameplateUnitFrame(frame) then
        addon:HideReviewBadge(frame)
        return
    end

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

-- Nameplates (the floating names over players in the world). The earlier
-- try at recoloring the name text depended on Blizzard's internal nameplate
-- fields and never worked here. The badge instead sits on a small holder
-- frame covering the nameplate's base frame (what C_NamePlate returns),
-- which every nameplate has, whether Blizzard's own UnitFrame or a
-- nameplate addon draws what's inside it.
-- Plates are recycled between units, so the unit each one shows is tracked
-- from NAME_PLATE_UNIT_ADDED/REMOVED rather than read off the plate.
-- Friendly nameplates inside dungeons and raids are forbidden to addons:
-- GetNamePlateForUnit returns nil for those, so no badge there.
local activePlates = {}

local function GetPlateHolder(plate)
    local holder = plate.AlliesJournalHolder
    if not holder then
        holder = CreateFrame("Frame", nil, plate)
        holder:SetAllPoints(plate)
        plate.AlliesJournalHolder = holder
    end
    -- Above whatever the nameplate draws inside itself (Blizzard's
    -- UnitFrame or an addon's), so the badge isn't hidden under it.
    holder:SetFrameLevel(plate:GetFrameLevel() + 20)
    return holder
end

-- Where the name text ends on a Blizzard nameplate: the FontString plus the
-- point of it and X offset that land on the last letter. The FontString is
-- usually wider than its text (stretched across the health bar, text
-- centered), so its RIGHT edge alone would leave a gap; the drawn text
-- width and justification give the real end. Returns nil when there's no
-- visible Blizzard name (a nameplate addon hides UnitFrame) or the width
-- can't be read (a secret value while the game hides the name).
local function GetPlateNameEnd(plate)
    local unitFrame = plate.UnitFrame
    local nameText = unitFrame and unitFrame.name
    if not (nameText and nameText.GetStringWidth and unitFrame:IsVisible() and nameText:IsVisible()) then
        return nil
    end
    local ok, width = pcall(nameText.GetStringWidth, nameText)
    if not ok or issecretvalue(width) or type(width) ~= "number" or width <= 0 then return nil end
    local boxWidth = nameText:GetWidth()
    if not issecretvalue(boxWidth) and boxWidth > 0 and width > boxWidth then
        width = boxWidth -- truncated with "...": the text ends at the box edge
    end
    local justify = nameText:GetJustifyH()
    if justify == "LEFT" then return nameText, "LEFT", width end
    if justify == "RIGHT" then return nameText, "RIGHT", 0 end
    return nameText, "CENTER", width / 2
end

-- Returns true when a badge is shown. Most plates are NPCs or players with
-- no note, and plates come and go constantly in a city, so those return
-- before anything is created: no holder frame until a plate first needs one.
local function UpdatePlateBadge(unit, plate)
    plate = plate or activePlates[unit]
    if not plate then return false end
    local b = addon.db.global.settings.badge

    local review = nil
    if Tooltip.badgeTest then
        -- Every plate, NPCs too, so placement can be checked anywhere.
        review = TEST_REVIEW
    elseif b.plateEnabled and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
        -- GetFullName returns nil while the game hides the name; the
        -- UNIT_NAME_UPDATE handler re-checks the plate when it shows.
        local nameRealm = addon:GetFullName(unit)
        review = nameRealm and addon:GetLatestReview(nameRealm)
    end

    if Tooltip.nameDebug then
        addon:Print(string.format("[plate debug] unit=%s isPlayer=%s reviewFound=%s",
            tostring(unit), tostring(UnitIsPlayer(unit)), tostring(review ~= nil)))
    end

    if not review then
        if plate.AlliesJournalHolder then addon:HideReviewBadge(plate.AlliesJournalHolder) end
        return false
    end
    local holder = GetPlateHolder(plate)

    -- "Right of the name": just after the end of the name text, when
    -- Blizzard's own nameplate (with its name FontString) is what's shown.
    if b.plateAttach == "name" then
        local nameText, relPoint, x = GetPlateNameEnd(plate)
        if nameText then
            addon:ShowReviewBadge(holder, review, b.plateSize, "LEFT", relPoint,
                x + (b.plateNameOffsetX or 0), b.plateNameOffsetY or 0, nameText)
            return true
        end
    end
    -- Nameplate frame placement, and the fallback when there's no name
    -- text to follow (a nameplate addon drawing its own, for one).
    addon:ShowReviewBadge(holder, review, b.plateSize, b.plateAnchorPoint, b.plateRelPoint, b.plateOffsetX, b.plateOffsetY)
    return true
end

local function RefreshPlates()
    for unit, plate in pairs(activePlates) do
        pcall(UpdatePlateBadge, unit, plate)
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
            -- Secret values can't be stringified/concatenated into our own
            -- output without tainting it; just show that the field is secret.
            local shown = issecretvalue(v) and "<secret>" or tostring(v)
            table.insert(parts, tostring(k) .. "=" .. shown)
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

    -- A real (readable) unit that isn't another player - an NPC target,
    -- a pet - is not a chat/who menu, so don't go fishing for a name field.
    -- Those menus also carry the NPC's name, which can be a secret value.
    if unit and not issecretvalue(unit) and UnitExists(unit) then return end

    -- No unit - try the name-based path (chat names, /who results).
    -- contextData fields can be secret strings on this client (seen on
    -- MENU_UNIT_TARGET): comparing one (even `~= ""`) throws "attempt to
    -- compare ... a secret string value", so test issecretvalue first.
    local rawName
    if contextData then
        for _, field in ipairs(NAME_FIELD_CANDIDATES) do
            local value = contextData[field]
            if type(value) == "string" and not issecretvalue(value) and value ~= "" then
                rawName = value
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

    ok, err = pcall(function()
        self:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        self:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        -- Plates already on screen (after a /reload) may not get an ADDED
        -- event; pick them up from the plate's own unit token.
        for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
            local unit = plate.namePlateUnitToken
            if type(unit) == "string" and not issecretvalue(unit) then
                activePlates[unit] = plate
            end
        end
    end)
    if not ok then addon:Print("|cffff4040Nameplate hook failed|r: " .. tostring(err)) end

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
    if not name or issecretvalue(name) then
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
-- Group changes come in bursts (a raid forming fires many in a row), and
-- each one used to repaint every frame three times. Now a burst gets one
-- repaint on the next frame, and the two later ones count from the LAST
-- event of the burst. skipNow: the caller has just repainted itself.
function Tooltip:RepaintAfterChange(skipNow)
    if not skipNow and not self.repaintNowPending then
        self.repaintNowPending = true
        C_Timer.After(0, function()
            self.repaintNowPending = false
            self:RefreshFrames()
        end)
    end
    self.repaintToken = (self.repaintToken or 0) + 1
    local token = self.repaintToken
    C_Timer.After(0.5, function() if self.repaintToken == token then self:RefreshFrames() end end)
    C_Timer.After(2, function() if self.repaintToken == token then self:RefreshFrames() end end)
end

function Tooltip:GROUP_ROSTER_UPDATE()
    self:RepaintAfterChange()
end

function Tooltip:PLAYER_ROLES_ASSIGNED()
    self:RepaintAfterChange()
end

function Tooltip:NAME_PLATE_UNIT_ADDED(_, unit)
    if type(unit) ~= "string" or issecretvalue(unit) then return end
    local plate = C_NamePlate.GetNamePlateForUnit(unit)
    if not plate then return end
    activePlates[unit] = plate
    local ok, shown = pcall(UpdatePlateBadge, unit, plate)
    if not ok and self.nameDebug then
        addon:Print("|cffff4040Nameplate badge error|r: " .. tostring(shown))
    end
    -- Blizzard may fill in the name text after this event reaches us, and
    -- the badge follows where that text ends - place it again once it has.
    -- Only for a badge that follows the name; everyone else needs no timer.
    if ok and shown and addon.db.global.settings.badge.plateAttach == "name" then
        C_Timer.After(0.1, function()
            if activePlates[unit] == plate then pcall(UpdatePlateBadge, unit, plate) end
        end)
    end
end

function Tooltip:NAME_PLATE_UNIT_REMOVED(_, unit)
    if type(unit) ~= "string" or issecretvalue(unit) then return end
    local plate = activePlates[unit]
    activePlates[unit] = nil
    if plate and plate.AlliesJournalHolder then
        addon:HideReviewBadge(plate.AlliesJournalHolder)
    end
end

-- Fires for every unit in the world, so only group members and nameplates
-- matter here. A nameplate is re-checked on its own (its name may have
-- been hidden when it appeared); group bursts collapse into one repaint.
function Tooltip:UNIT_NAME_UPDATE(_, unit)
    if type(unit) ~= "string" or issecretvalue(unit) then return end
    if activePlates[unit] then
        pcall(UpdatePlateBadge, unit)
        return
    end
    if not (unit:find("^party") or unit:find("^raid")) then return end
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
    local plates = 0
    for _ in pairs(activePlates) do plates = plates + 1 end
    self:RefreshFrames()
    addon:Print(string.format("Badge test %s - the scan found %d party/raid frame(s), %d visible, and %d nameplate(s).%s",
        self.badgeTest and "ON (fake badge on every found frame and nameplate)" or "off",
        found, visible, plates,
        (self.badgeTest and visible == 0) and " No party/raid frames are on screen: show them (Edit Mode preview, or join a group) and run it again." or ""))
end

function Tooltip:RefreshFrames()
    RefreshUnitFrames()
    ForEachGroupFrame(UpdateReviewBadge)
    RefreshPlates()
end

-- Repaints now and again shortly after. Used when a review is saved: a
-- custom frame addon (EllesmereUI) may redraw its own buttons a moment
-- later, and a badge painted before that can be lost.
function Tooltip:RefreshFramesSoon()
    self:RefreshFrames()
    self:RepaintAfterChange(true)
end
