local addon = AlliesJournal
local Browser = addon:NewModule("Browser")
local AceGUI = LibStub("AceGUI-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("AlliesJournal")

local ROLE_FILTERS = { "All", "tank", "healer", "dps" }

-- Extra detail Recent Allies attaches to an interaction (its contextData,
-- plus the interaction type): where it happened, which difficulty and
-- level, and an item if one's involved. Appended in gray after the
-- description. Works on both a live interaction (nested contextData) and
-- one stored on a review (flattened fields, see Database).
local function InteractionDetails(interaction)
    local ctx = interaction.contextData or interaction
    local parts = {}
    local location = ctx.locationName
    if location and location ~= "" and not (interaction.description or ""):find(location, 1, true) then
        table.insert(parts, location)
    end
    local difficultyID = ctx.activityDifficultyID or ctx.difficultyID
    if difficultyID and GetDifficultyInfo then
        local ok, name = pcall(GetDifficultyInfo, difficultyID)
        if ok and name and name ~= "" then table.insert(parts, name) end
    end
    local level = ctx.activityDifficultyLevel or ctx.difficultyLevel
    if level and level > 0 then table.insert(parts, "level " .. level) end
    if ctx.itemID then
        local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(ctx.itemID)
        table.insert(parts, name or ("item " .. ctx.itemID))
    end
    if #parts == 0 then return "" end
    return "  |cff888888(" .. table.concat(parts, ", ") .. ")|r"
end

local function IsRealPlace(place)
    return place and place ~= "" and place ~= "Manual" and place ~= "Unknown"
end

-- Where you last were with this player. Newest first, skipping records
-- that have no real place (a review written later or by name is stored
-- as "Manual"/"Unknown", and it also overwrites the record's last-seen
-- zone): the record's stamped zone, then each earlier review, then each
-- earlier session, then Blizzard's own Recent Allies log - its
-- interactions carry a locationName (or at least a readable description),
-- which covers players whose places we never captured at all.
local function PlaceFor(record, allyData)
    if IsRealPlace(record.lastSeen.zone) then return record.lastSeen.zone end

    for _, review in ipairs(addon:GetReviewsForPlayer(record.nameRealm)) do
        if IsRealPlace(review.encounter) then return review.encounter end
    end
    for _, session in ipairs(addon:GetSessionsForPlayer(record.nameRealm)) do
        if IsRealPlace(session.zone) then return session.zone end
    end

    local interactions = allyData and allyData.interactionData and allyData.interactionData.interactions
    if interactions then
        local bestPlace, bestTime = nil, -1
        local bestDescription, bestDescriptionTime = nil, -1
        for _, interaction in ipairs(interactions) do
            local stamp = interaction.timestamp or 0
            local place = interaction.contextData and interaction.contextData.locationName
            if IsRealPlace(place) and stamp > bestTime then
                bestPlace, bestTime = place, stamp
            end
            if IsRealPlace(interaction.description) and stamp > bestDescriptionTime then
                bestDescription, bestDescriptionTime = interaction.description, stamp
            end
        end
        return bestPlace or bestDescription
    end
    return nil
end
local ROLE_FILTER_LABELS = { All = "All", tank = "Tank", healer = "Healer", dps = "DPS" }

-- Review filter uses the same classification as the card's accent bar:
-- bad = either rating is bad, good = both good, average = any other
-- reviewed player, none = never reviewed.
-- Whether Blizzard's Recent Allies has an entry for the player.
local SOURCE_FILTERS = { "All", "recent", "other" }
local SOURCE_FILTER_LABELS = { All = "All", recent = "In Recent Allies", other = "Not in Recent Allies" }
local RATING_FILTERS = { "All", "good", "average", "bad", "none" }
local RATING_FILTER_LABELS = { All = "All", good = "Great", average = "Mixed", bad = "Not great", none = "No note" }

local function ReviewClass(review)
    if not review then return "none" end
    if review.social == "bad" or review.performance == "bad" then return "bad" end
    if review.social == "good" and review.performance == "good" then return "good" end
    return "average"
end

-- Custom AceGUI widget for one row of the player list. Built as its own
-- widget type (instead of decorating InteractiveLabel/Label) because:
--  * Label recomputes its own height from its text whenever List layout
--    resizes it, so any spacer made from one gets reset to 1px - the gap
--    between cards has to live inside the card widget's own height.
--  * Its own pool means every region here is created once per widget and
--    reused, with nothing shared with other parts of the addon.
-- The widget's frame is CARD_HEIGHT + padding tall; the visible card only
-- fills the top CARD_HEIGHT, and the leftover strip is the gap before the
-- next card. Padding comes from /pr options (Player List).
local CARD_HEIGHT = 46
-- The review star, vertically centered on the card's left side; both text
-- lines start to its right (always - so names line up from card to card
-- whether or not a given player has a review).
local BADGE_SIZE = 28
local CARD_TEXT_X = 12 + BADGE_SIZE + 8
do
    local Type, Version = "PRPlayerCard", 1

    local function Strip(parent)
        local t = parent:CreateTexture(nil, "BORDER")
        t:SetColorTexture(1, 1, 1, 1)
        return t
    end

    local methods = {
        OnAcquire = function(self)
            self:SetWidth(300)
            self:SetPadding(4)
            self.card:Show()
            self:SetSelected(false)
        end,

        -- Turns the widget into an empty gap of the given height.
        SetSpacer = function(self, height)
            self.card:Hide()
            self:SetHeight(math.max(height or 0, 1))
        end,

        SetPadding = function(self, padding)
            self.padding = padding or 0
            self:SetHeight(CARD_HEIGHT + self.padding)
        end,

        -- d: { name, info, summary, lastSeen, accent = {r,g,b}, selected }
        SetCard = function(self, d)
            self.nameText:SetText(d.name or "")
            self.infoText:SetText(d.info or "")
            self.summaryText:SetText(d.summary or "")
            self.seenText:SetText(d.lastSeen or "")
            local a = d.accent or { 0.4, 0.4, 0.4 }
            self.accent:SetColorTexture(a[1], a[2], a[3], 1)

            -- The review: the same star badge used on unit frames and
            -- Group Finder rows (icon + tex coords from the Badge icon
            -- setting), tinted by the player's worst rating. Nothing is
            -- shown for someone never reviewed, and the name makes room
            -- for it when there is one.
            local b = d.badge
            if b then
                local icon = addon.db.global.settings.badge.icon
                if icon and icon.path and icon.path ~= "" then
                    local ok = pcall(function()
                        self.badge:SetTexture(icon.path)
                        self.badge:SetTexCoord(icon.left or 0, icon.right or 1, icon.top or 0, icon.bottom or 1)
                    end)
                    if not ok then
                        self.badge:SetTexture(nil)
                        self.badge:SetColorTexture(1, 1, 1)
                    end
                    self.badge:SetVertexColor(b[1], b[2], b[3])
                else
                    self.badge:SetTexture(nil)
                    self.badge:SetColorTexture(b[1], b[2], b[3])
                end
                self.badge:Show()
            else
                self.badge:Hide()
            end
            self.nameText:ClearAllPoints()
            self.nameText:SetPoint("TOPLEFT", self.card, "TOPLEFT", CARD_TEXT_X, -8)
            self.nameText:SetPoint("TOPRIGHT", self.infoText, "TOPLEFT", -8, 0)
            self.summaryText:ClearAllPoints()
            self.summaryText:SetPoint("BOTTOMLEFT", self.card, "BOTTOMLEFT", CARD_TEXT_X, 8)
            self.summaryText:SetPoint("BOTTOMRIGHT", self.seenText, "BOTTOMLEFT", -8, 0)

            self.online = d.online
            self:SetSelected(d.selected)
        end,

        SetSelected = function(self, selected)
            -- Like the Recent Allies rows, no frame: blue when selected, a
            -- dim warm tint for online players, a plain dark wash
            -- otherwise (colors from /pr options, developer tools).
            -- The color's opacity is the left edge; the right edge keeps
            -- cardFade of it.
            local settings = addon.db.global.settings
            local colors = settings.browserColors
            local c = selected and colors.selected or (self.online and colors.online or colors.offline)
            local fade = settings.browserList.cardFade or 0.25
            -- Offline (or not in Recent Allies) cards are dimmed, as
            -- Recent Allies does with its offline rows; selecting one
            -- brings it back to full strength.
            local dim = (selected or self.online) and 1 or (settings.browserList.offlineDim or 0.55)
            self.nameText:SetAlpha(dim)
            self.infoText:SetAlpha(dim)
            self.summaryText:SetAlpha(dim)
            self.seenText:SetAlpha(dim)
            self.badge:SetAlpha(dim)
            self.border:SetColor(0, 0, 0, 0)
            self.bg:SetColorTexture(c[1], c[2], c[3], 1)
            local ok = pcall(self.bg.SetGradient, self.bg, "HORIZONTAL",
                CreateColor(c[1], c[2], c[3], c[4]), CreateColor(c[1], c[2], c[3], c[4] * fade))
            if not ok then
                self.bg:SetColorTexture(c[1], c[2], c[3], c[4])
            end
        end,
    }

    local function Constructor()
        local frame = CreateFrame("Frame", nil, UIParent)
        frame:Hide()

        -- The visible card; only it takes mouse input, so clicking the
        -- gap between cards does nothing.
        local card = CreateFrame("Frame", nil, frame)
        card:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        card:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        card:SetHeight(CARD_HEIGHT)
        card:EnableMouse(true)

        local bg = card:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(card)

        local top, bottom, left, right = Strip(card), Strip(card), Strip(card), Strip(card)
        top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(1)
        bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT"); bottom:SetHeight(1)
        left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT"); left:SetWidth(1)
        right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT"); right:SetWidth(1)
        local border = {
            SetColor = function(_, r, g, b, a)
                for _, t in ipairs({ top, bottom, left, right }) do
                    t:SetColorTexture(r, g, b, a)
                end
            end,
        }

        -- Left accent bar: the player's online status (colored by
        -- StatusAccentFor). The review rating is the star badge below.
        local accent = card:CreateTexture(nil, "ARTWORK")
        accent:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
        accent:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 1, 1)
        accent:SetWidth(3)

        -- Hover feedback. HIGHLIGHT-layer textures are shown by the client
        -- only while the mouse is over this frame, which is exactly what
        -- we want here (unlike for a persistent background).
        local hover = card:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints(card)
        hover:SetColorTexture(1, 0.9, 0.6, 0.08)
        hover:SetBlendMode("ADD")

        local infoText = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        infoText:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -9)
        infoText:SetWidth(190)
        infoText:SetJustifyH("RIGHT")
        infoText:SetWordWrap(false)
        infoText:SetTextColor(0.62, 0.62, 0.66)

        local nameText = card:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        nameText:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -8)
        nameText:SetPoint("TOPRIGHT", infoText, "TOPLEFT", -8, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetWordWrap(false)

        local badge = card:CreateTexture(nil, "OVERLAY")
        badge:SetSize(BADGE_SIZE, BADGE_SIZE)
        badge:SetPoint("LEFT", card, "LEFT", 12, 0)
        badge:Hide()

        local seenText = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        seenText:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -10, 8)
        seenText:SetWidth(240)
        seenText:SetJustifyH("RIGHT")
        seenText:SetWordWrap(false)
        seenText:SetTextColor(0.5, 0.5, 0.54)

        local summaryText = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        summaryText:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 8)
        summaryText:SetPoint("BOTTOMRIGHT", seenText, "BOTTOMLEFT", -8, 0)
        summaryText:SetJustifyH("LEFT")
        summaryText:SetWordWrap(false)

        local widget = {
            frame = frame, card = card, bg = bg, border = border, accent = accent, badge = badge,
            nameText = nameText, infoText = infoText,
            summaryText = summaryText, seenText = seenText,
            type = Type,
        }
        for name, func in pairs(methods) do
            widget[name] = func
        end

        card:SetScript("OnMouseUp", function(_, button)
            widget:Fire("OnClick", button)
            AceGUI:ClearFocus()
        end)

        return AceGUI:RegisterAsWidget(widget)
    end

    AceGUI:RegisterWidgetType(Type, Constructor, Version)
end

local RATING_COLORS = { good = "|cff40ff40", average = "|cffffd100", bad = "|cffff4040" }

local function RatingText(axis, rating)
    local color = RATING_COLORS[rating]
    if not color then return tostring(rating or "-") end
    return color .. addon:RatingWord(axis, rating) .. "|r"
end

-- Card accent bar = online status, matching the status icon: green online,
-- yellow away, red do-not-disturb, gray offline, darker gray when Recent
-- Allies has no entry for them. (The review is the star badge, not this.)
local function StatusAccentFor(allyData)
    if not allyData then return { 0.3, 0.3, 0.32 } end
    local state = allyData.stateData
    if not state or not state.isOnline then return { 0.5, 0.5, 0.55 } end
    if state.isDND then return { 1, 0.25, 0.25 } end
    if state.isAFK then return { 1, 0.82, 0 } end
    return { 0.25, 1, 0.25 }
end

-- C_RecentAllies notes are too small (127 chars, confirmed in-game) to
-- hold a full review, so it's not a backend replacement - but its pin
-- tracks its own online/DND/AFK state, class/level, and current
-- location for free, refreshed automatically every time you regroup
-- with someone already reviewed (see addon:SyncRecentAlly /
-- RosterTracker). Reading that here means this list can show which
-- reviewed players are still "recent" (grouped with in the last ~89
-- days), their live status, and what we know about them, without
-- sending a /who for every single name.
--
-- GetRecentAllyByFullName(nameRealm) doesn't work here: our nameRealm
-- strings are a workaround WE built for Forever's "classless" two-part
-- names (see GetFullName), and don't reliably match whatever exact
-- string Blizzard's own RecentAllies data considers the full name on
-- this client. Scanning the real list sidesteps that - but confirmed via
-- /pr recentallies that characterData.name is only the FIRST name
-- ("De"), not the full two-part name; characterData.fullName ("De Zivu")
-- is the one that actually matches what GetShortName extracts from our
-- own nameRealm strings.
local function GetRecentAlliesList()
    if not C_RecentAllies then return nil end
    local ok, list = pcall(C_RecentAllies.GetRecentAllies)
    if not ok then return nil end
    return list
end

-- Matches within an already-fetched list (RefreshList fetches once for
-- the whole player list, not once per row) - FindRecentAlly below is the
-- one-off convenience wrapper for a single lookup (ShowHistory).
local function FindRecentAllyInList(list, nameRealm)
    if not list then return nil end
    local shortName = addon:GetShortName(nameRealm)
    if not shortName then return nil end
    for _, allyData in ipairs(list) do
        local charData = allyData.characterData
        if charData and charData.fullName and charData.fullName:lower() == shortName:lower() then
            return allyData
        end
    end
    return nil
end

local function FindRecentAlly(nameRealm)
    return FindRecentAllyInList(GetRecentAlliesList(), nameRealm)
end

-- The Recent Allies interactions that belong to one review. A review saves
-- whatever Blizzard had logged when it was written, but entries like
-- "Fought Together" are often logged afterwards (or the review was made
-- by name, with no grouped window), so that snapshot is frequently empty.
-- In that case, look at Blizzard's current log for this player and take
-- what falls in the review's own time span: from when the first linked
-- session began (or a few hours before the review) to shortly after it.
local function ReviewInteractions(review, nameRealm)
    if #(review.interactions or {}) > 0 then return review.interactions end

    local allyData = FindRecentAlly(nameRealm)
    local all = allyData and allyData.interactionData and allyData.interactionData.interactions
    if not all then return {} end

    local from
    for _, sessionId in ipairs(review.sessionIds or {}) do
        local session = addon.db.global.sessions[sessionId]
        if session and session.date and session.groupedSeconds then
            local start = session.date - session.groupedSeconds - 60
            from = from and math.min(from, start) or start
        end
    end
    from = from or (review.date - 3 * 3600)
    local to = review.date + 600

    local found = {}
    for _, interaction in ipairs(all) do
        local stamp = interaction.timestamp
        if stamp and stamp >= from and stamp <= to then
            table.insert(found, interaction)
        end
    end
    table.sort(found, function(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end)
    return found
end

-- Blizzard's own Friends List status icons, embedded inline via the
-- standard |T...|t texture escape - no raw frames needed for this (an
-- ordinary FontString/Label already renders |T just fine), which is what
-- makes this a much lower-risk way to get real in-game iconography into
-- the list than mixing in more CreateTexture/CreateFrame calls like the
-- DPS bar chart needed.
local function StatusIconFor(allyData)
    if not allyData then return "|cff707070(not recent)|r" end
    local state = allyData.stateData
    if not state or not state.isOnline then
        return "|TInterface\\FriendsFrame\\StatusIcon-Offline:14|t"
    elseif state.isDND then
        return "|TInterface\\FriendsFrame\\StatusIcon-DnD:14|t"
    elseif state.isAFK then
        return "|TInterface\\FriendsFrame\\StatusIcon-Away:14|t"
    else
        return "|TInterface\\FriendsFrame\\StatusIcon-Online:14|t"
    end
end

-- Same atlas/coordinates as the review prompt's DPS bar chart role icons
-- (ReviewPrompt.lua), just expressed as PIXEL coordinates rather than 0-1
-- fractions - the inline |T...|t syntax takes pixel offsets into the
-- given texWidth/texHeight, not SetTexCoord's 0-1 floats.
local ROLE_ICON_PIXEL_COORDS = {
    tank = "0:19:22:41",
    healer = "20:39:1:20",
    dps = "20:39:22:41",
}

local function RoleIconFor(role)
    local coords = role and ROLE_ICON_PIXEL_COORDS[role]
    if not coords then return "" end
    return string.format("|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:20:20:0:0:64:64:%s|t ", coords)
end

-- classID -> (RAID_CLASS_COLORS entry, localized class name), both nil if
-- unavailable - C_CreatureInfo.GetClassInfo is the standard way to turn
-- the numeric classID RecentAllies hands back into the englishClass token
-- RAID_CLASS_COLORS is keyed by (same lookup the DPS bar chart uses).
local function GetClassColor(classID)
    if not classID or not C_CreatureInfo then return nil, nil end
    local ok, info = pcall(C_CreatureInfo.GetClassInfo, classID)
    if not ok or not info or not info.classFile then return nil, nil end
    return RAID_CLASS_COLORS and RAID_CLASS_COLORS[info.classFile], info.className
end

-- Class-colored short name when we have class data for them, plain
-- short name otherwise.
local function ColoredShortName(nameRealm, allyData)
    local shortName = addon:GetShortName(nameRealm) or nameRealm
    local classColor = allyData and allyData.characterData and GetClassColor(allyData.characterData.classID)
    if classColor and classColor.colorStr then
        return "|c" .. classColor.colorStr .. shortName .. "|r"
    end
    return shortName
end

-- Everything RecentAllies knows that's worth surfacing beyond the pin/note
-- we already write - class, level, and current location (while online).
-- Returns "" when there's no cached entry (nothing pinned/never synced).
local function InfoTextFor(allyData)
    if not allyData then return "" end
    local char = allyData.characterData or {}
    local state = allyData.stateData or {}
    local parts = {}
    if char.level then table.insert(parts, "Lvl " .. char.level) end
    local _, className = GetClassColor(char.classID)
    if className then table.insert(parts, className) end
    if state.isOnline and state.currentLocation and state.currentLocation ~= "" then
        table.insert(parts, state.currentLocation)
    end
    if #parts == 0 then return "" end
    return table.concat(parts, ", ")
end

StaticPopupDialogs["ALLIESJOURNAL_DELETE_REVIEW"] = {
    text = "Delete this note for %s (%s)?",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data)
        addon:DeleteReview(data.nameRealm, data.reviewID)
        local browser = addon:GetModule("Browser")
        browser:RefreshList()
        browser:RefreshStats()
        browser:ShowHistory(data.nameRealm)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- text is pre-formatted and passed as arg1 (rather than using this
-- dialog's own %s substitution, which Blizzard caps at two args) since
-- the confirmation needs to show count/day-threshold/bytes-freed all at
-- once - see Browser:ShowCleanupConfirm.
StaticPopupDialogs["ALLIESJOURNAL_CLEANUP_SESSIONS"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data)
        local removed = addon:ApplySessionCleanup(data.eligible)
        addon:Print(string.format("Cleaned up %d old session(s).", removed))
        local browser = addon:GetModule("Browser")
        browser:RefreshList()
        browser:RefreshStats()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function Browser:OnEnable()
    self.searchText = ""
    self.roleFilter = "All"
    self.ratingFilter = "All"
    self.sourceFilter = "All"
end

function Browser:Toggle()
    if self.frame and self.frame:IsShown() then
        self.frame:Hide()
    else
        self:Show()
    end
end

-- Called after a review is saved so an already-open browser reflects it
-- immediately, instead of only updating the next time it's closed/reopened.
function Browser:RefreshIfShown()
    if self.frame and self.frame:IsShown() then
        self:RefreshList()
        self:RefreshStats()
    end
end

-- Applies the saved colors to the window fill and list panel, and redraws
-- the cards (their colors are read when each one is built).
function Browser:ApplyColors(skipRedraw)
    local colors = addon.db.global.settings.browserColors
    if self.windowFill then
        local c = colors.window
        self.windowFill:SetColorTexture(c[1], c[2], c[3], c[4])
    end
    if self.listInset then
        local c = colors.list
        self.listInset:SetColorTexture(c[1], c[2], c[3], c[4])
    end
    if not skipRedraw and self.frame and self.frame:IsShown() and self.listContainer then
        self:RefreshList()
    end
end

function Browser:Show()
    if not self.frame then
        local frame = AceGUI:Create("Window")
        frame.frame:SetFrameStrata("DIALOG") -- AceGUI defaults to FULLSCREEN_DIALOG, which sits above the game's confirmation popups
        frame:SetTitle("Allies Journal")
        frame:SetLayout("Flow")
        local size = addon.db.global.settings.browserWindow
        frame:SetWidth(size.width)
        frame:SetHeight(size.height)
        -- Dragging the corner resizes the window; once the size settles,
        -- remember it and rebuild so the list and detail areas grow or
        -- shrink with it (they have fixed heights otherwise).
        frame.frame:HookScript("OnSizeChanged", function()
            local token = {}
            self.resizeToken = token
            C_Timer.After(0.3, function()
                if self.resizeToken ~= token then return end
                local w, h = math.floor(frame.frame:GetWidth() + 0.5), math.floor(frame.frame:GetHeight() + 0.5)
                -- Read fresh: "Reset all settings" replaces this table.
                local current = addon.db.global.settings.browserWindow
                current.width, current.height = w, h
                if self.frame and self.frame:IsShown() and h ~= self.builtHeight then
                    self:Refresh()
                end
            end)
        end)
        -- The stock Window background is see-through, so whatever is
        -- behind it (grass, a mob) changes how dark each card looks. A
        -- steady dark fill under the content makes it uniform.
        local fill = frame.frame:CreateTexture(nil, "BACKGROUND", nil, 2)
        fill:SetPoint("TOPLEFT", frame.frame, "TOPLEFT", 8, -8)
        fill:SetPoint("BOTTOMRIGHT", frame.frame, "BOTTOMRIGHT", -8, 8)
        self.windowFill = fill
        self.frame = frame
        self:ApplyColors(true)
    end
    self.frame:Show()
    self.frame.frame:Raise()
    self:Refresh()
end

-- Sets the window to the size saved in settings (from /pr options).
function Browser:ApplyWindowSize()
    if not self.frame then return end
    local size = addon.db.global.settings.browserWindow
    self.frame:SetWidth(size.width)
    self.frame:SetHeight(size.height)
end

-- Heights for the list and (when a player is selected) the detail area,
-- from the window's current height. 190 is everything else in the window
-- (title, stats, buttons, filters, margins).
function Browser:AreaHeights(hasSelection)
    local content = math.max(math.floor(self.frame.frame:GetHeight() + 0.5) - 215, 200)
    if not hasSelection then return content, 0 end
    local list = math.floor(content * 0.40)
    return list, content - list
end

-- Opens the browser straight to one player's history (used by the "View
-- Reviews" right-click menu button).
function Browser:ShowPlayer(nameRealm)
    self:Show()
    self:ShowHistory(nameRealm)
end

function Browser:Refresh()
    local frame = self.frame
    frame:ReleaseChildren()

    -- Breathing room below the window's title bar, before any real
    -- content starts.
    local topSpacer = AceGUI:Create("Label")
    topSpacer:SetFullWidth(true)
    topSpacer:SetText(" ")
    frame:AddChild(topSpacer)

    -- Per-category size breakdown, visible every time the browser is
    -- open (not just on request via /pr stats) - the user's biggest
    -- stated concern is storage growth, and this is meant to make it
    -- obvious at a glance which category (chat/meter/sessions/reviews)
    -- is actually driving it.
    local stats = AceGUI:Create("Label")
    stats:SetFullWidth(true)
    frame:AddChild(stats)
    self.statsLabel = stats
    -- Set the real (two-line) text BEFORE any sibling below it gets
    -- added - Flow layout positions each new child using the CURRENT
    -- height of everything already added, so setting this after
    -- search/role were already placed (as RefreshStats used to be
    -- called, at the very end of this function) left them stacked at
    -- the offset an empty single-line stats label implied, with the
    -- real two-line text then drawing over them. Same class of bug
    -- already fixed twice in ReviewPrompt's chart section.
    self:RefreshStats()

    local buttonRow = AceGUI:Create("SimpleGroup")
    buttonRow:SetFullWidth(true)
    buttonRow:SetLayout("Flow")
    frame:AddChild(buttonRow)

    local cleanupBtn = AceGUI:Create("Button")
    cleanupBtn:SetText("Clean Up...")
    cleanupBtn:SetWidth(120)
    cleanupBtn:SetCallback("OnClick", function() self:ShowCleanupConfirm() end)
    buttonRow:AddChild(cleanupBtn)

    local refreshBtn = AceGUI:Create("Button")
    refreshBtn:SetText("Refresh")
    refreshBtn:SetWidth(100)
    refreshBtn:SetCallback("OnClick", function()
        -- TryRequestRecentAlliesData is a protected call (HasRestrictions,
        -- not AllowedWhenUntainted - confirmed via an ADDON_ACTION_FORBIDDEN
        -- error even inside pcall, which doesn't catch a taint violation
        -- the way it catches a normal Lua error) - not called here.
        -- GetRecentAllies() alone is enough: /pr recentallies already
        -- showed IsRecentAllyDataReady is true without ever requesting it,
        -- so this button just re-reads whatever's already cached.
        self:RefreshList()
        self:RefreshStats()
    end)
    buttonRow:AddChild(refreshBtn)

    local pinBtn = AceGUI:Create("Button")
    pinBtn:SetText("Pin Journal")
    pinBtn:SetWidth(120)
    pinBtn:SetCallback("OnClick", function()
        addon:PinReviewedAllies()
        -- Pins that stick immediately flip the status icons right away;
        -- retried ones show up on the next Refresh.
        self:RefreshList()
    end)
    buttonRow:AddChild(pinBtn)

    local whoBtn = AceGUI:Create("Button")
    do
        local text, disabled = addon:GetModule("WhoCheck"):ButtonState()
        whoBtn:SetText(text)
        whoBtn:SetDisabled(disabled)
    end
    whoBtn:SetWidth(260)
    self.whoBtn = whoBtn
    whoBtn:SetCallback("OnClick", function() self:CheckOfflineStatus() end)
    whoBtn:SetCallback("OnEnter", function(widget)
        GameTooltip:SetOwner(widget.frame, "ANCHOR_TOP")
        GameTooltip:SetText("Check players not in Recent Allies", 1, 1, 1)
        GameTooltip:AddLine("Players marked [NR] aren't in Blizzard's Recent Allies, so their online status is unknown. This runs /who on them to see whether they are online, plus their level, class and location. The game only allows one /who per click, so click once per player (at least 5 seconds apart).", nil, nil, nil, true)
        local progress = addon:GetModule("WhoCheck"):ProgressLines()
        if progress then
            GameTooltip:AddLine(" ")
            for _, line in ipairs(progress) do GameTooltip:AddLine(line) end
        end
        GameTooltip:Show()
    end)
    whoBtn:SetCallback("OnLeave", function() GameTooltip:Hide() end)
    -- A second row for the two views of your history that sit beside the list.
    local viewRow = AceGUI:Create("SimpleGroup")
    viewRow:SetFullWidth(true)
    viewRow:SetLayout("Flow")
    frame:AddChild(viewRow)

    local runsBtn = AceGUI:Create("Button")
    runsBtn:SetText("Runs")
    runsBtn:SetWidth(120)
    runsBtn:SetCallback("OnClick", function() addon:GetModule("Diary"):ShowRuns() end)
    viewRow:AddChild(runsBtn)

    local numbersBtn = AceGUI:Create("Button")
    numbersBtn:SetText("In numbers")
    numbersBtn:SetWidth(120)
    numbersBtn:SetCallback("OnClick", function() addon:GetModule("Diary"):ShowNumbers() end)
    viewRow:AddChild(numbersBtn)
    -- The /who check lives here, where its longer label (name, count and
    -- countdown) has room.
    viewRow:AddChild(whoBtn)

    local search = AceGUI:Create("EditBox")
    search:SetLabel("Search names and notes")
    search:SetText(self.searchText)
    search:SetWidth(140)
    search:SetCallback("OnTextChanged", function(widget, event, text)
        self.searchText = text
        self:RefreshList()
    end)
    frame:AddChild(search)

    local roleDropdown = AceGUI:Create("Dropdown")
    roleDropdown:SetLabel(L["Role"])
    roleDropdown:SetWidth(100)
    roleDropdown:SetList(ROLE_FILTER_LABELS, ROLE_FILTERS)
    roleDropdown:SetValue(self.roleFilter)
    roleDropdown:SetCallback("OnValueChanged", function(widget, event, value)
        self.roleFilter = value
        self:RefreshList()
    end)
    frame:AddChild(roleDropdown)

    local ratingDropdown = AceGUI:Create("Dropdown")
    ratingDropdown:SetLabel("How it went")
    ratingDropdown:SetWidth(120)
    ratingDropdown:SetList(RATING_FILTER_LABELS, RATING_FILTERS)
    ratingDropdown:SetValue(self.ratingFilter)
    ratingDropdown:SetCallback("OnValueChanged", function(widget, event, value)
        self.ratingFilter = value
        self:RefreshList()
    end)
    frame:AddChild(ratingDropdown)

    local sourceDropdown = AceGUI:Create("Dropdown")
    sourceDropdown:SetLabel("Recent Allies")
    sourceDropdown:SetWidth(130)
    sourceDropdown:SetList(SOURCE_FILTER_LABELS, SOURCE_FILTERS)
    sourceDropdown:SetValue(self.sourceFilter)
    sourceDropdown:SetCallback("OnValueChanged", function(widget, event, value)
        self.sourceFilter = value
        self:RefreshList()
    end)
    frame:AddChild(sourceDropdown)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    scroll:SetFullWidth(true)
    -- With nobody selected the list takes the whole window; selecting a
    -- player shrinks it and adds the detail area below. Switching between
    -- those two modes rebuilds the window (see ShowHistory/ClearSelection)
    -- since AceGUI can't cleanly remove just one child from a Flow layout.
    local hasSelection = self.selectedNameRealm ~= nil
    local listHeight, detailHeight = self:AreaHeights(hasSelection)
    self.builtHeight = math.floor(frame.frame:GetHeight() + 0.5)
    scroll:SetHeight(listHeight)
    -- Dark inset behind the cards, like the Recent Allies list area. The
    -- scroll widget is pooled, so the texture is hidden again on release.
    local inset = scroll.frame.prInset
    if not inset then
        inset = scroll.frame:CreateTexture(nil, "BACKGROUND")
        scroll.frame.prInset = inset
    end
    inset:SetAllPoints(scroll.frame)
    inset:Show()
    self.listInset = inset
    self:ApplyColors(true)
    scroll:SetCallback("OnRelease", function() inset:Hide() end)
    frame:AddChild(scroll)
    self.listContainer = scroll

    if hasSelection then
        -- Detail area is a scrolling container (not a single InlineGroup
        -- like before) since it holds two separate sections - Reviews and
        -- Sessions - populated fresh by ShowHistory.
        local detail = AceGUI:Create("ScrollFrame")
        detail:SetLayout("List")
        detail:SetFullWidth(true)
        detail:SetHeight(detailHeight)
        frame:AddChild(detail)
        self.detailContainer = detail
    else
        self.detailContainer = nil
    end

    self:RefreshList()
    if hasSelection then
        self:ShowHistory(self.selectedNameRealm)
    end
end

-- Clicking the already-selected card again deselects it, returning the
-- list to full-window size.
function Browser:ClearSelection()
    self.selectedNameRealm = nil
    self:Refresh()
end

function Browser:RefreshStats()
    if not self.statsLabel then return end
    local s = addon:GetStorageStats()
    self.statsLabel:SetText(string.format(
        "%d player(s) | %d session(s) | %d notes\nChat %s  ·  Sessions %s  ·  Notes %s  ·  Players %s  ·  Total %s",
        s.playerCount, s.sessionCount, s.reviewCount,
        addon:FormatBytes(s.chatBytes), addon:FormatBytes(s.sessionsBytes),
        addon:FormatBytes(s.reviewsBytes), addon:FormatBytes(s.playersBytes), addon:FormatBytes(s.totalBytes)))
end

function Browser:ShowCleanupConfirm()
    local days = addon.db.global.settings.retention.purgeDays
    local eligible, bytesFreed = addon:PreviewSessionCleanup(days)

    if #eligible == 0 then
        addon:Print(string.format("Nothing eligible for cleanup right now (sessions older than %d days, players without notes only).", days))
        return
    end

    local message = string.format(
        "Remove %d old session(s) from players without notes (older than %d days)?\nFrees about %s.\nSessions for players with notes are never included.",
        #eligible, days, addon:FormatBytes(bytesFreed))

    StaticPopup_Show("ALLIESJOURNAL_CLEANUP_SESSIONS", message, nil, { eligible = eligible })
end

-- /who every listed player Recent Allies has no entry for.
-- Uses the players currently shown (RefreshList records them), so the
-- search, role, review and Recent Allies filters all apply.
function Browser:CheckOfflineStatus()
    local names = {}
    for _, nameRealm in ipairs(self.shownNonRecent or {}) do
        table.insert(names, nameRealm)
    end
    addon:GetModule("WhoCheck"):Click(names)
end

-- Keeps the Check Status button's label (and its remaining count) current.
function Browser:UpdateWhoButton()
    if self.whoBtn and self.frame and self.frame:IsShown() then
        local text, disabled = addon:GetModule("WhoCheck"):ButtonState()
        self.whoBtn:SetText(text)
        self.whoBtn:SetDisabled(disabled)
    end
end

function Browser:RefreshList()
    local scroll = self.listContainer
    if not scroll then return end
    scroll:ReleaseChildren()

    -- Fetched once for the whole list, not once per row - GetRecentAllies
    -- itself is cheap (it's just reading an already-populated client-side
    -- cache), but there's no reason to call it N times for N rows.
    local recentList = GetRecentAlliesList()

    -- Filter first, then order: online players first (then offline, then
    -- ones with no Recent Allies entry), most recently seen first within
    -- each group.
    local entries = {}
    self.shownNonRecent = {}
    for _, record in ipairs(addon:SearchPlayers(self.searchText)) do
        local latest = addon:GetLatestReview(record.nameRealm)
        local passesRole = self.roleFilter == "All" or (latest and latest.role == self.roleFilter)
        local passesRating = self.ratingFilter == "All" or ReviewClass(latest) == self.ratingFilter
        local allyData = FindRecentAllyInList(recentList, record.nameRealm)
        local passesSource = self.sourceFilter == "All"
            or (self.sourceFilter == "recent") == (allyData ~= nil)
        if passesRole and passesRating and passesSource then
            -- Not in Recent Allies: use what a /who check found, if run.
            if not allyData then
                table.insert(self.shownNonRecent, record.nameRealm)
                allyData = addon:GetModule("WhoCheck"):GetPseudoAlly(record.nameRealm)
            end
            local presence = 2
            if allyData then
                presence = (allyData.stateData and allyData.stateData.isOnline) and 0 or 1
            end
            table.insert(entries, { record = record, latest = latest, allyData = allyData, presence = presence })
        end
    end
    table.sort(entries, function(x, y)
        if x.presence ~= y.presence then return x.presence < y.presence end
        local xs = x.record.lastSeen.date or 0
        local ys = y.record.lastSeen.date or 0
        if xs ~= ys then return xs > ys end
        return x.record.nameRealm < y.record.nameRealm
    end)

    -- Same gap above the first card as between cards.
    local topPad = AceGUI:Create('PRPlayerCard')
    topPad:SetFullWidth(true)
    topPad:SetSpacer(addon.db.global.settings.browserList.rowPadding)
    scroll:AddChild(topPad)

    for _, entry in ipairs(entries) do
        local record, latest, allyData = entry.record, entry.latest, entry.allyData
        do
            local lastSeen = record.lastSeen.date and ('Seen ' .. date('%Y-%m-%d', record.lastSeen.date)) or ''
            -- Where that was: lastSeen.zone is stamped by both sessions and
            -- reviews, so it's the most recent of either (including the
            -- one a review was written for). Placeholder values from
            -- manual/unknown reviews aren't worth showing.
            local zone = PlaceFor(record, allyData)
            if lastSeen ~= '' and zone then
                lastSeen = lastSeen .. ' - ' .. zone
            end
            local summary
            if latest then
                if latest.mode == 'simple' then
                    summary = 'How was it: ' .. RatingText('simple', latest.social)
                else
                    summary = string.format('Social: %s   Perf: %s', RatingText("social", latest.social), RatingText("performance", latest.performance))
                end
            else
                summary = string.format('|cff888888No reviews yet - %d session(s)|r', #record.sessions)
            end

            local infoText = allyData and InfoTextFor(allyData) or ''
            if not allyData then
                infoText = 'not recent'
            elseif allyData.fromWho and infoText == '' then
                infoText = 'not online'
            end

            -- Online status is the card's left bar now, so no status icon here.
            -- [NR] = Not in Recent Allies (whether or not a /who check has
            -- filled in their info since).
            local nameLine = RoleIconFor(latest and latest.role) .. ColoredShortName(record.nameRealm, allyData)
            if not allyData or allyData.fromWho then
                nameLine = nameLine .. ' |cff909090[NR]|r'
            end

            local card = AceGUI:Create('PRPlayerCard')
            card:SetFullWidth(true)
            card:SetPadding(addon.db.global.settings.browserList.rowPadding)
            card:SetCard({
                name = nameLine,
                info = infoText,
                summary = summary,
                lastSeen = lastSeen,
                accent = StatusAccentFor(allyData),
                online = allyData and allyData.stateData and allyData.stateData.isOnline or false,
                badge = latest and { addon:GetWorstRatingRGB(latest) } or nil,
                selected = (self.selectedNameRealm == record.nameRealm),
            })
            card:SetCallback('OnClick', function(widget, event, button)
                if button == 'RightButton' then
                    self:ShowCardMenu(widget.card or widget.frame, record.nameRealm)
                    return
                end
                if self.selectedNameRealm == record.nameRealm then
                    self:ClearSelection()
                else
                    self:ShowHistory(record.nameRealm)
                end
            end)
            scroll:AddChild(card)
        end
    end
end

-- Small helpers for the Reviews / Sessions sections: each entry is a few
-- short lines (title, ratings, numbers) instead of one long sentence.
local GRAY = "|cff909090"

local function FormatDuration(seconds)
    seconds = math.floor(seconds or 0)
    local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    if m > 0 then return string.format("%dm", m) end
    return seconds .. "s"
end

-- A rating note, in quotes and muted, after the rating word.
local function NoteText(note)
    if not note or note == "" then return "" end
    return "  |cffbbbbbb\"" .. note .. "\"|r"
end

-- "Damage: 27 DPS  -  83% of the group's best  -  23% of the group total".
-- nil when there's nothing worth showing (under 1 per second).
local function StatLine(label, unit, value, groupMax, groupTotal)
    if not value or value < 1 then return nil end
    local parts = {}
    if groupMax and groupMax > 0 then
        table.insert(parts, string.format("%d%% of the group's best", math.floor(value / groupMax * 100)))
    end
    if groupTotal and groupTotal > 0 then
        table.insert(parts, string.format("%d%% of the group total", math.floor(value / groupTotal * 100)))
    end
    local text = string.format("%s: |cffffffff%d %s|r", label, math.floor(value), unit)
    if #parts > 0 then
        text = text .. "  " .. GRAY .. table.concat(parts, "  -  ") .. "|r"
    end
    return text
end

-- A thin line between two entries.
local function AddSeparator(container)
    local line = AceGUI:Create("Heading")
    line:SetText("")
    line:SetFullWidth(true)
    container:AddChild(line)
end

-- What you can do with someone from the journal, offered in the right-click
-- menu on a card. Each only works if
-- the game lets an addon do it from a click, so a failure is reported
-- rather than ignored.
function Browser:PlayerActions(nameRealm)
    local shortName = addon:GetShortName(nameRealm)
    local function Safe(fn)
        return function()
            local ok, err = pcall(fn)
            if not ok then addon:Print("Couldn't do that: " .. tostring(err)) end
        end
    end
    return {
        { text = "Whisper", tip = "Start a whisper to " .. shortName .. ".",
          run = Safe(function() ChatFrame_SendTell(shortName) end) },
        { text = "Invite", tip = "Invite " .. shortName .. " to your group (they need to be online).",
          run = Safe(function() C_PartyInfo.InviteUnit(shortName) end) },
        { text = "Add Friend", tip = "Add " .. shortName .. " to your friends list. Your note stays here in the journal.",
          run = Safe(function()
              C_FriendList.AddFriend(shortName)
              addon:Print("Sent a friend request to " .. shortName .. ".")
          end) },
        { text = "Add Note", tip = "Write a new note on " .. shortName .. ".",
          run = Safe(function()
              if not addon:GetModule("RosterTracker"):QueueDeparted(nameRealm) then
                  addon:DoQueueNameForReview(nameRealm)
              end
          end) },
    }
end

-- Right-click on a card in the list.
function Browser:ShowCardMenu(owner, nameRealm)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        addon:Print("The game's menu isn't available here - use the buttons under their name.")
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(addon:GetShortName(nameRealm))
        for _, action in ipairs(self:PlayerActions(nameRealm)) do
            root:CreateButton(action.text, action.run)
        end
        root:CreateButton("View history", function() self:ShowHistory(nameRealm) end)
    end)
end

function Browser:ShowHistory(nameRealm)
    -- First selection (no detail area yet): rebuild the window with the
    -- list shrunk and the detail area present - Refresh calls back into
    -- here once it exists.
    if not self.detailContainer then
        self.selectedNameRealm = nameRealm
        self:Refresh()
        return
    end

    local detail = self.detailContainer
    detail:ReleaseChildren()

    -- Refreshes the list's card highlighting so the newly-selected player
    -- stands out from the rest.
    if self.selectedNameRealm ~= nameRealm then
        self.selectedNameRealm = nameRealm
        self:RefreshList()
    end

    local allyData = FindRecentAlly(nameRealm)

    -- Class-colored name, like the card, with the realm part left plain.
    local title = AceGUI:Create("Heading")
    local realmPart = nameRealm:match("(%-.+)$") or ""
    title:SetText(ColoredShortName(nameRealm, allyData) .. "|cffffd100" .. realmPart .. "|r")
    title:SetFullWidth(true)
    detail:AddChild(title)

    -- How much you've played together so far, from the recorded sessions.
    local sessionList = addon:GetSessionsForPlayer(nameRealm)
    if #sessionList > 0 then
        local totalGrouped, first, last = 0, nil, nil
        for _, recorded in ipairs(sessionList) do
            totalGrouped = totalGrouped + (recorded.groupedSeconds or 0)
            local when = recorded.date
            if when then
                first = first and math.min(first, when) or when
                last = last and math.max(last, when) or when
            end
        end
        local together = AceGUI:Create("Label")
        together:SetFullWidth(true)
        together:SetText(string.format("|cffffd100Together so far:|r %d session%s, %s grouped in total  %s(first %s, last %s)|r",
            #sessionList, #sessionList == 1 and "" or "s", FormatDuration(totalGrouped), GRAY,
            first and date("%Y-%m-%d", first) or "?", last and date("%Y-%m-%d", last) or "?"))
        detail:AddChild(together)
    end


    if allyData then
        local info = AceGUI:Create("Label")
        info:SetFullWidth(true)
        local infoText = InfoTextFor(allyData)
        -- Recent Allies also says when the pin runs out (pinExpirationDate,
        -- a unix time) - shown so it's clear how long they'll stay listed
        -- without being regrouped with.
        local pinText = ""
        local expires = allyData.stateData and allyData.stateData.pinExpirationDate
        if expires then
            local days = math.ceil((expires - time()) / 86400)
            pinText = days > 0 and ("   |cff888888pinned, " .. days .. " day(s) left|r") or "   |cffff9933pin expired|r"
        end
        info:SetText(StatusIconFor(allyData) .. " " .. (infoText ~= "" and infoText or "no class/level data") .. pinText)
        detail:AddChild(info)

        -- What Blizzard's own RecentAllies system already tracked about
        -- this player independently of our reviews - dungeon/raid/duel/
        -- etc. history, each with a ready-made human-readable description
        -- (interaction.description) and timestamp, free of any tracking
        -- work on our side.
        local interactions = allyData.interactionData and allyData.interactionData.interactions
        if interactions and #interactions > 0 then
            local interactionsGroup = AceGUI:Create("InlineGroup")
            interactionsGroup:SetTitle("Together (Recent Allies)")
            interactionsGroup:SetLayout("List")
            interactionsGroup:SetFullWidth(true)
            detail:AddChild(interactionsGroup)

            local sorted = {}
            for _, interaction in ipairs(interactions) do table.insert(sorted, interaction) end
            table.sort(sorted, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)

            for _, interaction in ipairs(sorted) do
                local line = AceGUI:Create("Label")
                line:SetFullWidth(true)
                line:SetText(string.format("[%s] %s%s",
                    date("%Y-%m-%d %H:%M", interaction.timestamp or 0), interaction.description or "?",
                    InteractionDetails(interaction)))
                interactionsGroup:AddChild(line)
            end
        end
    end

    local reviewsGroup = AceGUI:Create("InlineGroup")
    reviewsGroup:SetTitle("Notes")
    reviewsGroup:SetLayout("List")
    reviewsGroup:SetFullWidth(true)
    detail:AddChild(reviewsGroup)

    local reviews = addon:GetReviewsForPlayer(nameRealm)
    if #reviews == 0 then
        local empty = AceGUI:Create("Label")
        empty:SetText("No notes yet.")
        empty:SetFullWidth(true)
        reviewsGroup:AddChild(empty)
    end

    for _, review in ipairs(reviews) do
        local dateStr = date("%Y-%m-%d %H:%M", review.date)

        if review ~= reviews[1] then AddSeparator(reviewsGroup) end

        local row = AceGUI:Create("SimpleGroup")
        row:SetFullWidth(true)
        row:SetLayout("Flow")

        local reviewInteractions = ReviewInteractions(review, nameRealm)

        local label = AceGUI:Create("Label")
        -- Full width, so the buttons below it get their own line and
        -- keep full-length labels.
        label:SetFullWidth(true)
        local roleText = review.role and (addon:RoleIconText(review.role, 14) .. review.role:upper()) or ""
        local lines = {
            string.format("|cffffd100%s|r  %s%s  %s", review.encounter or "Unknown", GRAY, dateStr, roleText) .. "|r",
        }
        if review.mode == "simple" then
            table.insert(lines, "How was it: " .. RatingText("simple", review.social) .. NoteText(review.socialNote))
        else
            table.insert(lines, "Social: " .. RatingText("social", review.social) .. NoteText(review.socialNote))
            table.insert(lines, "Perf: " .. RatingText("performance", review.performance) .. NoteText(review.performanceNote))
        end
        local dmg = StatLine("Damage", "DPS", review.dps, review.groupMaxDps, review.groupTotalDps)
        local heal = StatLine("Healing", "HPS", review.hps, review.groupMaxHps, review.groupTotalHps)
        if dmg then table.insert(lines, dmg) end
        if heal then table.insert(lines, heal) end
        local extra = { string.format("%d fight(s)", review.fightsIncluded or 0) }
        if #reviewInteractions > 0 then
            table.insert(extra, string.format("%d Recent Allies interaction(s)", #reviewInteractions))
        end
        table.insert(lines, GRAY .. table.concat(extra, "  -  ") .. "|r")
        label:SetText(table.concat(lines, "\n"))
        row:AddChild(label)

        local reviewID = review.id

        local chatBtn = AceGUI:Create("Button")
        chatBtn:SetText("View Chat")
        chatBtn:SetWidth(110)
        chatBtn:SetCallback("OnClick", function()
            local lines = {}
            for _, msg in ipairs(review.chat or {}) do
                table.insert(lines, string.format("[%s] %s (%s): %s",
                    date("%H:%M", msg.time), msg.from == "self" and "You" or addon:GetShortName(nameRealm),
                    msg.channel, msg.text))
            end
            if #lines == 0 then lines = { "(no chat captured for this note)" } end
            addon:GetModule("Export"):ShowText("Chat - " .. nameRealm .. " - " .. dateStr, table.concat(lines, "\n"))
        end)
        row:AddChild(chatBtn)

        local togetherBtn = AceGUI:Create("Button")
        togetherBtn:SetText("Together")
        togetherBtn:SetWidth(110)
        togetherBtn:SetCallback("OnClick", function()
            local lines = {}
            for _, interaction in ipairs(ReviewInteractions(review, nameRealm)) do
                table.insert(lines, string.format("[%s] %s%s",
                    date("%Y-%m-%d %H:%M", interaction.timestamp or 0), interaction.description or "?",
                    (InteractionDetails(interaction):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))))
            end
            if #lines == 0 then lines = { "(Recent Allies has nothing logged for this player during this note's session)" } end
            addon:GetModule("Export"):ShowText("Together - " .. nameRealm .. " - " .. dateStr, table.concat(lines, "\n"))
        end)
        -- Duplicates the "Together (Recent Allies)" section above, so it
        -- only shows with developer tools on (useful for copying the
        -- per-review list out).
        if addon.db.global.settings.developerTools then
            row:AddChild(togetherBtn)
        else
            AceGUI:Release(togetherBtn)
        end

        local editBtn = AceGUI:Create("Button")
        editBtn:SetText("Edit")
        editBtn:SetWidth(70)
        editBtn:SetCallback("OnClick", function()
            addon:GetModule("ReviewPrompt"):EditReview(nameRealm, reviewID)
        end)
        row:AddChild(editBtn)

        local deleteBtn = AceGUI:Create("Button")
        deleteBtn:SetText(L["Delete"])
        deleteBtn:SetWidth(70)
        deleteBtn:SetCallback("OnClick", function()
            StaticPopup_Show("ALLIESJOURNAL_DELETE_REVIEW", addon:GetShortName(nameRealm), dateStr,
                { nameRealm = nameRealm, reviewID = reviewID })
        end)
        row:AddChild(deleteBtn)

        reviewsGroup:AddChild(row)
    end

    local sessionsGroup = AceGUI:Create("InlineGroup")
    sessionsGroup:SetTitle("Sessions")
    sessionsGroup:SetLayout("List")
    sessionsGroup:SetFullWidth(true)
    detail:AddChild(sessionsGroup)

    local sessions = addon:GetSessionsForPlayer(nameRealm)
    if #sessions == 0 then
        local empty = AceGUI:Create("Label")
        empty:SetText("No sessions recorded yet.")
        empty:SetFullWidth(true)
        sessionsGroup:AddChild(empty)
    end

    -- Your note on the whole run, shown under the session it belongs to.
    local runNoteBySession = {}
    for _, run in ipairs(addon:GetRuns()) do
        if run.note ~= "" then
            for sessionId in pairs(run.sessionIds) do runNoteBySession[sessionId] = run.note end
        end
    end

    for _, session in ipairs(sessions) do
        local dateStr = date("%Y-%m-%d %H:%M", session.date)
        if session ~= sessions[1] then AddSeparator(sessionsGroup) end

        local row = AceGUI:Create("SimpleGroup")
        row:SetFullWidth(true)
        row:SetLayout("Flow")

        -- No chat here by design - sessions are the compact, chat-free
        -- record; chat only ever persists on a review (see the Reviews
        -- section above).
        local label = AceGUI:Create("Label")
        label:SetFullWidth(true)
        local lines = {
            string.format("|cffffd100%s|r  %s%s|r", session.zone or "Unknown", GRAY, dateStr),
            string.format("Grouped %s  -  in combat %s", FormatDuration(session.groupedSeconds), FormatDuration(session.combatSeconds)),
        }
        local dmg = StatLine("Damage", "DPS", session.dps, session.groupMaxDps, session.groupTotalDps)
        local heal = StatLine("Healing", "HPS", session.hps, session.groupMaxHps, session.groupTotalHps)
        if dmg then table.insert(lines, dmg) end
        if heal then table.insert(lines, heal) end
        local runNote = runNoteBySession[session.id]
        if runNote then
            table.insert(lines, "|cffffd100Run note:|r |cffbbbbbb\"" .. runNote .. "\"|r")
        end
        label:SetText(table.concat(lines, "\n"))
        row:AddChild(label)

        sessionsGroup:AddChild(row)
    end

    -- The entries are several lines tall now, and their real heights are
    -- only known once the width has been applied; the groups and the
    -- scroll area were sized before that, which left Sessions hanging
    -- below the visible area. Lay them out again, innermost first, once
    -- this frame's layout has finished.
    C_Timer.After(0, function()
        if self.detailContainer ~= detail then return end
        pcall(function()
            reviewsGroup:DoLayout()
            sessionsGroup:DoLayout()
            detail:DoLayout()
        end)
    end)
end
