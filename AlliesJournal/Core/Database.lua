local addon = AlliesJournal

-- Player list colors, each {r, g, b, a}: the window behind everything, the
-- darker panel behind the cards, and the card backgrounds by state.
addon.DEFAULT_BROWSER_COLORS = {
    window   = { 0.1647, 0.1490, 0.1098, 1 },
    list     = { 0, 0, 0, 0.45 },
    online   = { 0.4392, 0.3686, 0.1176, 0.046875 },
    selected = { 0.25, 0.50, 0.95, 0.55 },
    offline  = { 0.10, 0.10, 0.10, 0.25 },
}
addon.BROWSER_COLOR_LABELS = {
    { "window", "Window background" },
    { "list", "List panel behind the cards" },
    { "online", "Online player card" },
    { "selected", "Selected player card" },
    { "offline", "Offline / not recent card" },
}

-- Default text for the two tooltip templates (see RenderTooltipTemplate
-- below). Kept as the addon's own defaults so Options.lua's reset buttons
-- and Init.lua's first-run defaults both read from one place.
--
-- The world version leads with a blank line to visually separate our
-- content from Blizzard's own tooltip text (item/unit info) already above
-- it. The LFG version has no such content above it - we're usually the
-- FIRST thing GameTooltip shows for a row - so that same blank line would
-- just be unwanted empty space at the top, hence no leading blank here.
-- The first-version defaults, kept so a saved template that is still
-- exactly one of these (never edited) is upgraded to the current default.
addon.OLD_WORLD_TOOLTIP_TEMPLATE = table.concat({
    " ", "|cffffd100Reviewed ({count})|r", "Social: {social}", "{socialNote}", "Perf: {performance}", "{performanceNote}",
}, "\n")
addon.OLD_LFG_TOOLTIP_TEMPLATE = table.concat({
    "|cffffd100Reviewed ({count})|r", "{memberNote}", "Social: {social}", "{socialNote}", "Perf: {performance}", "{performanceNote}",
}, "\n")

-- Defaults from 0.1.x ("Reviewed"), for the same upgrade check.
addon.OLD_WORLD_TOOLTIP_TEMPLATE_2 = table.concat({
    " ", "{roleIcon}|cffffd100Reviewed ({count})|r  |cff808080{date}|r", "|cff808080{encounter}|r",
    "Social: {social}", "{socialNote}", "Perf: {performance}", "{performanceNote}",
}, "\n")
addon.OLD_LFG_TOOLTIP_TEMPLATE_2 = table.concat({
    "{roleIcon}|cffffd100Reviewed ({count})|r  |cff808080{date}|r", "{memberNote}",
    "Social: {social}", "{socialNote}", "Perf: {performance}", "{performanceNote}",
}, "\n")

addon.DEFAULT_WORLD_TOOLTIP_TEMPLATE = table.concat({
    " ",
    "{roleIcon}|cffffd100Journal ({count})|r  |cff808080{date}|r",
    "|cff808080{encounter}|r",
    "Social: {social}",
    "{socialNote}",
    "Perf: {performance}",
    "{performanceNote}",
}, "\n")

addon.DEFAULT_LFG_TOOLTIP_TEMPLATE = table.concat({
    "{roleIcon}|cffffd100Journal ({count})|r  |cff808080{date}|r",
    -- Blank for the leader/poster (their name's already on the row);
    -- shows "Group member: X" when the reviewed match is someone ELSE
    -- already in the group, since that's not otherwise visible anywhere.
    "{memberNote}",
    "Social: {social}",
    "{socialNote}",
    "Perf: {performance}",
    "{performanceNote}",
}, "\n")

local function GenerateReviewID()
    return string.format("%d-%05d", time(), math.random(0, 99999))
end

-- "Name-Realm" for any unit token. On this client's classless character
-- system, UnitName(unit) behaves inconsistently between "player" and any
-- other unit: for "player" it returns the full two-part name ("First
-- Last") combined in the first value, with the real realm correctly in
-- the second. For every other unit, it splits the name across both
-- values instead ("First", "Last") and the real realm is never returned
-- at all - confirmed by reviews saving as "First-Last" (no realm) via
-- target instead of "First Last-Realm" like chat-based capture produces.
-- Since a genuine realm name should equal GetRealmName() for anyone
-- groupable with you, treat any second value that DOESN'T match your own
-- realm as part of the display name (the surname) rather than a realm,
-- and always supply the real realm ourselves.
function addon:GetFullName(unit)
    local name, realm = UnitName(unit)
    if not name then return nil end

    local myRealm = GetRealmName()
    if realm and realm ~= "" and realm ~= myRealm then
        name = name .. " " .. realm
    end

    return name .. "-" .. myRealm
end

function addon:GetPlayerName()
    return self:GetFullName("player")
end

-- Same "Name-Realm" normalization as GetFullName, but for a plain name
-- string (as returned by CHAT_MSG_* events) rather than a unit token.
function addon:NormalizeChatSender(name)
    if not name or name == "" then return nil end
    if not name:find("-", 1, true) then
        name = name .. "-" .. GetRealmName()
    end
    return name
end

function addon:GetShortName(nameRealm)
    return nameRealm and nameRealm:match("^[^-]+") or nameRealm
end

function addon:GetOrCreatePlayer(nameRealm)
    local players = self.db.global.players
    local record = players[nameRealm]
    if not record then
        record = {
            nameRealm = nameRealm,
            lastSeen = { zone = nil, date = nil },
            reviews = {},
            sessions = {},
        }
        players[nameRealm] = record
    else
        -- Migrates a player record saved before sessions existed - `or`
        -- fallback, not a reset, so nothing already there is touched.
        record.sessions = record.sessions or {}
    end
    return record
end

function addon:UpdateLastSeen(nameRealm, zone)
    local record = self:GetOrCreatePlayer(nameRealm)
    record.lastSeen.zone = zone
    record.lastSeen.date = time()
end

-- reviewData: { encounter, role, social, socialNote, performance,
-- performanceNote, dps, hps, groupMaxDps, groupMaxHps, interrupts,
-- dispels, deaths, chat, zone }
-- dps/hps/interrupts/dispels/deaths are the compact aggregate computed
-- from whichever fights the user selected in the review prompt (see
-- ReviewCapture:AggregateFights) - flat fields, not a meterSnapshot
-- sub-object, matching a session's shape. groupMaxDps/groupMaxHps are the
-- duration-weighted top performer's numbers across those same fights, so
-- dps/hps can be shown relative to the group ("73% of group's best")
-- instead of as a bare, context-free number. chat is kept ONLY on
-- reviews, never on plain sessions - it's the one place long-term chat
-- storage is worth its size, since a review is the thing actually worth
-- having context for later.
function addon:AddReview(nameRealm, reviewData)
    local record = self:GetOrCreatePlayer(nameRealm)
    local id = GenerateReviewID()

    local review = {
        id = id,
        author = self:GetPlayerName(),
        date = time(),
        encounter = reviewData.encounter,
        role = reviewData.role,
        social = reviewData.social,
        socialNote = reviewData.socialNote or "",
        performance = reviewData.performance,
        performanceNote = reviewData.performanceNote or "",
        dps = reviewData.dps,
        hps = reviewData.hps,
        groupMaxDps = reviewData.groupMaxDps,
        groupMaxHps = reviewData.groupMaxHps,
        groupTotalDps = reviewData.groupTotalDps,
        groupTotalHps = reviewData.groupTotalHps,
        interrupts = reviewData.interrupts,
        dispels = reviewData.dispels,
        deaths = reviewData.deaths,
        fightsIncluded = reviewData.fightsIncluded or 0,  -- how many fights the user kept checked in the selection UI
        chat = reviewData.chat or {},
        sessionIds = reviewData.sessionIds or {},  -- sessions recorded with this player since their last review
        -- C_RecentAllies interactions (dungeon/raid/duel/etc. completions
        -- Blizzard already tracked) that fell inside this grouped session's
        -- window - see GetRecentAllyInteractionsInWindow.
        interactions = reviewData.interactions or {},
        warcraftLogsRef = "",  -- reserved, empty in v1
    }

    self.db.global.reviews[id] = review
    table.insert(record.reviews, id)

    if reviewData.zone then
        self:UpdateLastSeen(nameRealm, reviewData.zone)
    end

    return review
end

-- The words for the three levels of each question. The stored values stay
-- good / average / bad (colors, filters and pinning all key off them); only
-- what's shown differs: Social is "how was it to play with them", Performance
-- is "how did they play".
addon.RATING_WORDS = {
    social = { good = "Great to play with", average = "Fine", bad = "Not for me" },
    performance = { good = "Strong", average = "Solid", bad = "Struggled" },
}

function addon:RatingWord(axis, value)
    local words = self.RATING_WORDS[axis]
    return words and words[value] or tostring(value or "-")
end

-- Resolves a nameRealm to its real GUID via the C_RecentAllies cache, for
-- when no live unit was available at review time (/pr queuename, or the
-- right-click "Review Player" on a chat name you're not currently
-- grouped with) - SetRecentAllyPinned/SetRecentAllyNote need a GUID, and
-- without this fallback those reviews could never sync at all. Same
-- short-name match as Browser.lua's FindRecentAlly: our own nameRealm
-- strings don't reliably match Blizzard's fullCharacterName format on
-- Forever, but do match characterData.fullName. Only finds someone
-- who's already a recognized recent ally (at least one prior
-- interaction) - someone truly never encountered still can't be pinned,
-- since there's no GUID for them anywhere to find.
function addon:FindRecentAllyGUID(nameRealm)
    if not C_RecentAllies then return nil end
    local ok, list = pcall(C_RecentAllies.GetRecentAllies)
    if not ok or not list then return nil end

    local shortName = self:GetShortName(nameRealm)
    if not shortName then return nil end

    for _, allyData in ipairs(list) do
        local charData = allyData.characterData
        if charData and charData.fullName and charData.fullName:lower() == shortName:lower() then
            return charData.guid
        end
    end
    return nil
end

-- guid -> { review, name, quiet, attempts } for allies whose pin didn't
-- stick on the first try. Blizzard's Recent Allies only knows about
-- someone once its own interaction log has caught up (right after a
-- dungeon it often hasn't yet), and SetRecentAllyPinned silently does
-- nothing for a guid it doesn't know - so a successful-looking call proves
-- nothing. SyncRecentAlly checks IsRecentAllyPinned afterwards and retries
-- (on a timer, and whenever RECENT_ALLY_DATA_UPDATED fires for that guid).
addon.pendingRecentAllies = {}

function addon:IsRecentAllyPinned(guid)
    if not guid or not C_RecentAllies or not C_RecentAllies.IsRecentAllyPinned then return false end
    local ok, pinned = pcall(C_RecentAllies.IsRecentAllyPinned, guid)
    return (ok and pinned) and true or false
end

-- The actual pin + note calls, with no verification (see SyncRecentAlly).
function addon:ApplyRecentAlly(guid, review)
    local pinOk, pinErr = pcall(C_RecentAllies.SetRecentAllyPinned, guid, true)
    if self.recentAllyDebug then
        self:Print(string.format("[recentally debug] SetRecentAllyPinned(%s, true) ok=%s%s",
            tostring(guid), tostring(pinOk), (not pinOk) and (" err=" .. tostring(pinErr)) or ""))
    end

    local ok, canNote = pcall(C_RecentAllies.CanSetRecentAllyNote, guid)
    if self.recentAllyDebug then
        self:Print(string.format("[recentally debug] CanSetRecentAllyNote ok=%s canNote=%s", tostring(ok), tostring(canNote)))
    end
    if not ok or not canNote then return end

    local social = self:RatingWord("social", review.social)
    local performance = self:RatingWord("performance", review.performance)
    -- Confirmed in-game: this field is capped at 127 chars, so the tag +
    -- ratings prefix has to stay short to leave any room at all for the
    -- one thing actually worth reading here (the note itself). This is
    -- necessarily a compressed teaser, not the full review - the real
    -- review (with both notes, chat, fight data) always stays in our own
    -- SavedVariables record; Browser is still the source of truth.
    local note = string.format("[AJ] %s, %s", social, performance)
    local extra = (review.performanceNote and review.performanceNote ~= "" and review.performanceNote)
        or (review.socialNote and review.socialNote ~= "" and review.socialNote) or nil
    if extra then
        note = note .. " - " .. extra
    end
    if #note > 127 then
        note = note:sub(1, 124) .. "..."
    end

    local noteOk, noteErr = pcall(C_RecentAllies.SetRecentAllyNote, guid, note)
    if self.recentAllyDebug then
        self:Print(string.format("[recentally debug] SetRecentAllyNote ok=%s%s note=%q",
            tostring(noteOk), (not noteOk) and (" err=" .. tostring(noteErr)) or "", note))
    end
end

-- Mirrors a review's rating onto Blizzard's own C_RecentAllies system
-- (pin + note) alongside our own SavedVariables record - NOT a
-- replacement for it. SavedVariables writes were unreliable on the beta
-- client for a while, and this Blizzard-owned cache has its OWN
-- expiration - confirmed 89 days on a pinned entry, not forever. Our own
-- stored review is the actual durable fallback: RosterTracker calls this
-- again with the stored review every time you re-group with someone
-- already reviewed (quiet), which pushes their 89-day clock back out, and
-- ReviewPrompt's Save() calls it once up front the same way.
--
-- Always verifies the pin afterwards (IsRecentAllyPinned) and tells you
-- the outcome in chat unless `quiet`; a pin that didn't stick is retried
-- for ~10 minutes rather than silently dropped. A fake/test guid or an
-- unsupported client just does nothing.
-- Whether a review should be mirrored to Recent Allies at all. A review
-- with a "bad" rating is only pinned when the player has turned that on in
-- /pr options (default off); every pinning path goes through here, so they
-- all follow the one setting.
function addon:ShouldPinReview(review)
    if not review then return false end
    if review.social == "bad" or review.performance == "bad" then
        return self.db.global.settings.recentAllies.pinBad and true or false
    end
    return true
end

function addon:SyncRecentAlly(guid, review, nameRealm, quiet)
    if not self:ShouldPinReview(review) then
        if not quiet then
            self:Print((self:GetShortName(nameRealm) or "Player") .. " is marked 'Not for me' or 'Struggled', so they aren't pinned in Recent Allies (change this in /aj options).")
        end
        return false
    end
    if not guid then
        if self.recentAllyDebug then self:Print("[recentally debug] sync skipped: no guid for this review.") end
        return
    end
    if not C_RecentAllies then
        if self.recentAllyDebug then self:Print("[recentally debug] sync skipped: C_RecentAllies doesn't exist on this client.") end
        return
    end

    local ok, supported = pcall(C_RecentAllies.IsSystemSupported)
    if not ok or not supported then
        if self.recentAllyDebug then
            self:Print(string.format("[recentally debug] sync skipped: IsSystemSupported ok=%s supported=%s", tostring(ok), tostring(supported)))
        end
        return
    end

    local name = self:GetShortName(nameRealm) or "player"
    -- Copied: callers pass a live form table that gets replaced later.
    local snapshot = {
        social = review.social, performance = review.performance,
        socialNote = review.socialNote, performanceNote = review.performanceNote,
    }

    self:ApplyRecentAlly(guid, snapshot)
    if self:IsRecentAllyPinned(guid) then
        self.pendingRecentAllies[guid] = nil
        if not quiet then self:Print(name .. " pinned in Recent Allies.") end
        return true
    end

    -- Already waiting on retries for this guid - just refresh what they'll apply.
    if self.pendingRecentAllies[guid] then
        self.pendingRecentAllies[guid].review = snapshot
        return false
    end

    local entry = { review = snapshot, name = name, quiet = quiet, attempts = 0 }
    self.pendingRecentAllies[guid] = entry
    local delays = { 4, 20, 90, 400 }
    for i, delay in ipairs(delays) do
        -- Tied to this entry: if it's replaced by a newer sync for the same
        -- guid, these timers must not act on the newer one.
        C_Timer.After(delay, function() self:RetryRecentAlly(guid, i == #delays, entry) end)
    end
    return false
end

function addon:RetryRecentAlly(guid, isLast, onlyEntry)
    local pending = self.pendingRecentAllies[guid]
    if not pending or (onlyEntry and pending ~= onlyEntry) then return end
    pending.attempts = pending.attempts + 1

    self:ApplyRecentAlly(guid, pending.review)
    if self:IsRecentAllyPinned(guid) then
        self.pendingRecentAllies[guid] = nil
        if not pending.quiet then self:Print(pending.name .. " pinned in Recent Allies.") end
    elseif isLast then
        self.pendingRecentAllies[guid] = nil
        if not pending.quiet then
            self:Print(string.format("Couldn't pin %s in Recent Allies - Blizzard doesn't seem to know them yet, or the pin list may be full. /aj resyncrecentallies tries again.", pending.name))
        end
    end
end

-- RECENT_ALLY_DATA_UPDATED(guid): Blizzard just learned something about
-- this ally, which is exactly when a pin that was ignored before can
-- start working. Capped so a pin that keeps failing can't loop through
-- its own update events.
function addon:OnRecentAllyUpdated(event, guid)
    local pending = guid and self.pendingRecentAllies[guid]
    if pending and pending.attempts < 8 then
        self:RetryRecentAlly(guid, false)
    end
end

-- Every C_RecentAllies interaction with this guid that happened between
-- sinceTime and now - the actual grouped session window (RosterTracker's
-- groupedSince), not a guess at the single "closest" interaction to some
-- point in time. RecentAllyInteraction has no ID to link against, only a
-- timestamp, so "everything Blizzard logged while we were actually
-- grouped together" is the natural boundary. Returns {} (never nil) on
-- any failure - a fake/test guid, the API missing, or nothing in range
-- are all the same "nothing to show" case to callers.
function addon:GetRecentAllyInteractionsInWindow(guid, sinceTime)
    if not guid or not sinceTime or not C_RecentAllies then return {} end

    local ok, allyData = pcall(C_RecentAllies.GetRecentAllyByGUID, guid)
    if not ok or not allyData or not allyData.interactionData then return {} end

    local interactions = allyData.interactionData.interactions
    if not interactions then return {} end

    local now = time()
    local inWindow = {}
    for _, interaction in ipairs(interactions) do
        local ts = interaction.timestamp
        if ts and ts >= sinceTime and ts <= now then
            local ctx = interaction.contextData or {}
            table.insert(inWindow, {
                description = interaction.description, timestamp = ts, type = interaction.type,
                locationName = ctx.locationName, difficultyID = ctx.activityDifficultyID,
                difficultyLevel = ctx.activityDifficultyLevel, itemID = ctx.itemID,
            })
        end
    end
    table.sort(inWindow, function(a, b) return a.timestamp < b.timestamp end)
    return inWindow
end

function addon:DeleteReview(nameRealm, id)
    self.db.global.reviews[id] = nil

    local record = self.db.global.players[nameRealm]
    if not record then return end

    for i, existingID in ipairs(record.reviews) do
        if existingID == id then
            table.remove(record.reviews, i)
            break
        end
    end
end

-- changes: any subset of { role, social, socialNote, performance,
-- performanceNote } - mutates the existing review in place (same ID,
-- same position in the player's review list, same sessionIds/author/
-- date/encounter) rather than minting a new one via AddReview, so
-- editing a review from the Browser doesn't create a duplicate.
function addon:UpdateReview(id, changes)
    local review = self.db.global.reviews[id]
    if not review then return nil end
    for k, v in pairs(changes) do
        review[k] = v
    end
    return review
end

function addon:GetReview(id)
    return self.db.global.reviews[id]
end

function addon:GetReviewsForPlayer(nameRealm)
    local record = self.db.global.players[nameRealm]
    if not record then return {} end

    local reviews = {}
    for _, id in ipairs(record.reviews) do
        local review = self.db.global.reviews[id]
        if review then table.insert(reviews, review) end
    end
    table.sort(reviews, function(a, b) return a.date > b.date end)
    return reviews
end

function addon:GetLatestReview(nameRealm)
    return (self:GetReviewsForPlayer(nameRealm))[1]
end

-- Reviewed players only - this is what LFGAnnotate's badge matching and
-- the world tooltip hook rely on, and badges should stay scoped to
-- players actually rated, not everyone ever grouped with.
function addon:GetAllPlayers()
    local list = {}
    for _, record in pairs(self.db.global.players) do
        if #record.reviews > 0 then
            table.insert(list, record)
        end
    end
    table.sort(list, function(a, b) return a.nameRealm < b.nameRealm end)
    return list
end

-- Every player with EITHER a review or a recorded session - what the
-- Browser's player-centric list is built from, since the point of session
-- history is remembering people never explicitly reviewed too.
function addon:GetAllKnownPlayers()
    local list = {}
    for _, record in pairs(self.db.global.players) do
        if #record.reviews > 0 or #record.sessions > 0 then
            table.insert(list, record)
        end
    end
    table.sort(list, function(a, b)
        local aDate = (a.lastSeen and a.lastSeen.date) or 0
        local bDate = (b.lastSeen and b.lastSeen.date) or 0
        return aDate > bDate
    end)
    return list
end

function addon:SearchPlayers(query)
    query = query and query:lower() or ""
    local list = {}
    for _, record in ipairs(self:GetAllKnownPlayers()) do
        if query == "" or record.nameRealm:lower():find(query, 1, true) then
            table.insert(list, record)
        end
    end
    return list
end

local function GenerateSessionID()
    return string.format("s%d-%05d", time(), math.random(0, 99999))
end

-- sessionData: { zone, groupedSeconds, combatSeconds, dps, hps,
-- groupMaxDps, groupMaxHps, interrupts, dispels, deaths } - deliberately
-- compact, one flat record per session with no chat and no per-fight
-- breakdown (that detail only exists transiently in ReviewCapture.fights
-- while still grouped, and only survives long-term if a review gets
-- written - see AddReview). groupMaxDps/groupMaxHps are the duration-
-- weighted top performer's numbers, same as on a review, so a session's
-- dps/hps can also be read relative to the group instead of as a bare
-- number. A session records that you played WITH this player for a
-- meaningful stretch, independent of whether a review ever gets written -
-- see RosterTracker's session-eligibility gate for when this gets called.
function addon:AddSession(nameRealm, sessionData)
    local record = self:GetOrCreatePlayer(nameRealm)
    local id = GenerateSessionID()

    local session = {
        id = id,
        date = time(),
        zone = sessionData.zone,
        groupedSeconds = sessionData.groupedSeconds or 0,
        combatSeconds = sessionData.combatSeconds or 0,
        dps = sessionData.dps,
        hps = sessionData.hps,
        groupMaxDps = sessionData.groupMaxDps,
        groupMaxHps = sessionData.groupMaxHps,
        groupTotalDps = sessionData.groupTotalDps,
        groupTotalHps = sessionData.groupTotalHps,
        interrupts = sessionData.interrupts,
        dispels = sessionData.dispels,
        deaths = sessionData.deaths,
    }

    self.db.global.sessions[id] = session
    table.insert(record.sessions, id)
    self:UpdateLastSeen(nameRealm, sessionData.zone)

    return session
end

function addon:DeleteSession(nameRealm, id)
    self.db.global.sessions[id] = nil

    local record = self.db.global.players[nameRealm]
    if not record then return end

    for i, existingID in ipairs(record.sessions) do
        if existingID == id then
            table.remove(record.sessions, i)
            break
        end
    end
end

function addon:GetSessionsForPlayer(nameRealm)
    local record = self.db.global.players[nameRealm]
    if not record then return {} end

    local sessions = {}
    for _, id in ipairs(record.sessions) do
        local session = self.db.global.sessions[id]
        if session then table.insert(sessions, session) end
    end
    table.sort(sessions, function(a, b) return a.date > b.date end)
    return sessions
end

-- Sessions recorded since this player's most recent review (or every
-- session ever recorded, if never reviewed) - used both to link session
-- IDs onto a review when it's saved, and to show "N sessions since last
-- review" in the review prompt before writing one.
function addon:GetUnlinkedSessionsForPlayer(nameRealm)
    local latestReview = self:GetLatestReview(nameRealm)
    local cutoff = latestReview and latestReview.date or 0

    local unlinked = {}
    for _, session in ipairs(self:GetSessionsForPlayer(nameRealm)) do
        if session.date > cutoff then
            table.insert(unlinked, session.id)
        end
    end
    return unlinked
end

-- Shared rating-color logic, used anywhere a review needs to become a single
-- color (chat marker, frame badges, LFG annotation): the worse of the two
-- axes wins, since "at a glance, should I be cautious" is the point.
local RATING_HEX = {
    good = "40c040",
    average = "c0c040",
    bad = "c04040",
}
local RATING_RANK = { bad = 3, average = 2, good = 1 }

function addon:GetWorstRatingHex(review)
    local worst = review.social
    if RATING_RANK[review.performance] > (RATING_RANK[worst] or 0) then
        worst = review.performance
    end
    return RATING_HEX[worst] or "ffd100"
end

function addon:GetWorstRatingRGB(review)
    local hex = self:GetWorstRatingHex(review)
    return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- One level of a question as colored text (|cff...|r wrapped),
-- for anywhere a single rating value needs to read as text rather than
-- become a swatch color - tooltips, chat lines.
local RATING_COLOR_FMT = {
    good = "|cff40c040%s|r",
    average = "|cffc0c040%s|r",
    bad = "|cffc04040%s|r",
}

function addon:FormatRatingText(value, axis)
    if not value then return "?" end
    local fmt = RATING_COLOR_FMT[value] or "%s"
    return fmt:format(self:RatingWord(axis, value))
end

-- Shared small colored-square badge, used on unit frames (target/party/raid)
-- and LFG listing rows alike. Uses SetColorTexture (a plain programmatic
-- color fill) rather than a Blizzard icon file, so there's no texture-path
-- guesswork - it always renders regardless of what art assets a given
-- client build has. anchorPoint/relPoint/xOff/yOff let callers place it
-- appropriately for very differently-shaped frames (a small square unit
-- frame vs. a wide list row); defaults suit a small unit frame.
-- anchorTo (optional) lets the badge be positioned relative to a DIFFERENT
-- object than the one it's created on/cached on - e.g. LFGAnnotate creates
-- it on the row (a real Frame, required for :CreateTexture) but anchors it
-- to the specific FontString that matched, since that's guaranteed visible
-- (its text is on screen) where the row's own bounds may not be (pooled
-- list rows can be wider than their visible content, or subject to
-- ScrollBox clipping the row's own edges don't reflect).
function addon:ShowReviewBadge(frame, review, size, anchorPoint, relPoint, xOff, yOff, anchorTo)
    local badge = frame.AlliesJournalBadge
    if not badge then
        -- Sublevel 7 is the highest OVERLAY sublevel, so this draws above
        -- any of the row/frame's own icons that might otherwise sit on top
        -- of a plain sublevel-0 texture in the same screen area.
        badge = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        frame.AlliesJournalBadge = badge
    end
    -- Size applied every call, not just on creation, so /pr options size
    -- changes take effect on already-created badges the next scan/refresh
    -- without needing to recreate the texture. Caller passes its own
    -- size (unit frame vs LFG row use separate settings) rather than this
    -- function reading one shared value.
    size = size or 12
    badge:SetSize(size, size)
    -- Re-anchored every call, not just on first creation: for a stable
    -- unit frame this is a harmless no-op (same target every time), but
    -- for a pooled/recycled frame (LFG rows) the SAME frame object can
    -- later be reused for a DIFFERENT reviewed player with a different
    -- anchorTo region - without this, the badge would stay stuck pointing
    -- at whichever FontString it first matched, going stale as the list
    -- refreshes.
    badge:ClearAllPoints()
    badge:SetPoint(anchorPoint or "TOPLEFT", anchorTo or frame, relPoint or "TOPLEFT", xOff or -4, yOff or 4)

    -- A real texture file (e.g. an icon), tinted by rating, when Options >
    -- Badge Icon has one set - otherwise the original flat color fill.
    -- Wrapped in pcall since a bad/typo'd path throws on SetTexture; falls
    -- back to plain white (still tinted, still visible) rather than
    -- leaving a texture in a broken state from a half-failed call. This
    -- previously tried Interface\COMMON\FavoritesIcon hardcoded and it was
    -- barely visible on unit frames / invisible in LFG rows - rather than
    -- guess again, this is now a live, user-editable setting so different
    -- icons can be tried in-game directly.
    local r, g, b = self:GetWorstRatingRGB(review)
    local icon = self.db.global.settings.badge.icon
    if icon and icon.path and icon.path ~= "" then
        local ok = pcall(function()
            badge:SetTexture(icon.path)
            badge:SetTexCoord(icon.left or 0, icon.right or 1, icon.top or 0, icon.bottom or 1)
        end)
        if not ok then
            badge:SetTexture(nil)
            badge:SetColorTexture(1, 1, 1)
        end
        badge:SetVertexColor(r, g, b)
    else
        badge:SetTexture(nil)
        badge:SetColorTexture(r, g, b)
    end
    badge:Show()
end

function addon:HideReviewBadge(frame)
    if frame.AlliesJournalBadge then
        frame.AlliesJournalBadge:Hide()
    end
end

-- Inline tank/healer/DPS icon (pixel coordinates into the 64x64 portrait
-- roles sheet), with a trailing space; "" when the role is unknown.
local ROLE_ICON_COORDS = { tank = "0:19:22:41", healer = "20:39:1:20", dps = "20:39:22:41" }
function addon:RoleIconText(role, size)
    local coords = role and ROLE_ICON_COORDS[role]
    if not coords then return "" end
    size = size or 14
    return string.format("|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:%d:%d:0:0:64:64:%s|t ", size, size, coords)
end

-- Placeholder values available to the tooltip template (Options > Tooltip
-- Content). nameRealm is optional (LFG rows have it via the matched
-- player record; without it, count falls back to 1 rather than 0, since a
-- review clearly exists if this is even being called). `extra`, when
-- given, is merged in on top - used by LFGAnnotate to add memberNote
-- (which reviewed member of the group matched, when it's not the
-- leader/poster) without the world tooltip needing to know that concept.
function addon:GetReviewTooltipVars(review, nameRealm, extra)
    local vars = {
        social = self:FormatRatingText(review.social, "social"),
        performance = self:FormatRatingText(review.performance, "performance"),
        socialNote = review.socialNote or "",
        performanceNote = review.performanceNote or "",
        count = tostring(nameRealm and #self:GetReviewsForPlayer(nameRealm) or 1),
        author = review.author or "",
        date = review.date and date("%Y-%m-%d", review.date) or "",
        encounter = review.encounter or "",
        role = review.role or "",
        roleIcon = self:RoleIconText(review.role),
    }
    if extra then
        for k, v in pairs(extra) do vars[k] = v end
    end
    return vars
end

-- Splits a template string on newlines and substitutes {placeholder}
-- tokens into each line using `vars`. A line that's nothing but a single
-- placeholder (e.g. a line containing only "{socialNote}") is dropped
-- entirely when that value is empty, so an unfilled optional field
-- doesn't leave a blank gap; any other line is substituted and kept as-is
-- even if that leaves parts of it empty (e.g. "Note: {socialNote}" stays
-- as "Note: " - only a SOLE placeholder line gets the drop behavior).
function addon:RenderTooltipTemplate(template, vars)
    local lines = {}
    for line in (template .. "\n"):gmatch("(.-)\n") do
        local soloKey = strtrim(line):match("^{(%a[%w]*)}$")
        if soloKey then
            local value = vars[soloKey]
            if value and value ~= "" then
                table.insert(lines, value)
            end
        else
            table.insert(lines, (line:gsub("{(%a[%w]*)}", function(key)
                return vars[key] or ("{" .. key .. "}")
            end)))
        end
    end
    return lines
end

local function SerializeValue(v)
    local t = type(v)
    if t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local parts = {}
        for k, val in pairs(v) do
            local key
            if type(k) == "number" then
                key = "[" .. k .. "]"
            else
                key = "[" .. string.format("%q", tostring(k)) .. "]"
            end
            table.insert(parts, key .. "=" .. SerializeValue(val))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "nil"
end

-- Plain-text backup/restore, independent of whatever is (or isn't)
-- surviving to disk on its own - this beta client has a known issue where
-- SavedVariables don't reliably persist. Dumps db.global as a loadable Lua
-- literal the player can copy somewhere safe and restore later via
-- ImportData.
function addon:ExportData()
    return "return " .. SerializeValue(self.db.global)
end

-- Exposes the same serializer for reuse anywhere else a Lua value needs
-- to become copyable/pasteable text - e.g. ReviewCapture's save-for-
-- replay diagnostic, so captured fight data can be dumped and reloaded
-- later without needing to regroup with someone to test the review
-- prompt's UI again.
function addon:Serialize(value)
    return SerializeValue(value)
end

-- Exposes the same serializer ExportData uses as a byte-size estimate for
-- any sub-tree, not just the whole DB - the basis for the per-category
-- breakdown below.
function addon:EstimateSize(value)
    return #SerializeValue(value)
end

-- Shared "N bytes" -> "N.N KB" formatter, used everywhere GetStorageStats/
-- PreviewSessionCleanup results get displayed (the /pr stats command,
-- Browser's header, the Clean Up confirmation).
function addon:FormatBytes(n)
    n = n or 0
    if n < 1024 then return n .. "B" end
    return string.format("%.1fKB", n / 1024)
end

-- Splits a review into its {chat, everything else} parts for size
-- accounting - chat only ever lives on reviews (sessions are always
-- chat-free), so this is where the "chat" category comes from.
local function ReviewSizeParts(addonSelf, review)
    local chatBytes = addonSelf:EstimateSize(review.chat or {})
    local rest = {}
    for k, v in pairs(review) do
        if k ~= "chat" then rest[k] = v end
    end
    return chatBytes, addonSelf:EstimateSize(rest)
end

-- Per-category size breakdown (chat/sessions/reviews/players), so storage
-- growth can be attributed to a specific category instead of guessed at
-- from one aggregate number. Sessions are deliberately compact (no chat,
-- no per-fight detail) so they get one bucket rather than a sub-split.
-- Rendered in Browser's header and reachable via /pr stats.
function addon:GetStorageStats()
    local g = self.db.global
    local chatBytes, reviewsBytes = 0, 0
    local sessionCount, reviewCount, playerCount = 0, 0, 0

    for _, review in pairs(g.reviews) do
        local c, r = ReviewSizeParts(self, review)
        chatBytes = chatBytes + c
        reviewsBytes = reviewsBytes + r
        reviewCount = reviewCount + 1
    end
    for _ in pairs(g.sessions) do sessionCount = sessionCount + 1 end
    for _ in pairs(g.players) do playerCount = playerCount + 1 end

    return {
        chatBytes = chatBytes,
        reviewsBytes = reviewsBytes,
        sessionsBytes = self:EstimateSize(g.sessions),
        playersBytes = self:EstimateSize(g.players),
        totalBytes = self:EstimateSize(g),
        sessionCount = sessionCount,
        reviewCount = reviewCount,
        playerCount = playerCount,
    }
end

-- Sessions eligible for cleanup: older than `daysThreshold` days AND
-- belonging to a player with ZERO reviews - a reviewed player's sessions
-- are never auto-suggested, since they're the reference data behind why
-- that rating was given. Unreviewed players never have chat attached to
-- their sessions anyway (only a review ever carries chat), so there's
-- nothing to sub-split here - just the compact session bytes freed.
-- Returns the eligible {nameRealm, id} list plus bytes freed, so a
-- confirmation prompt can show exactly what's being removed before
-- ApplySessionCleanup actually deletes anything - this is preview-only,
-- never called on any automatic schedule.
function addon:PreviewSessionCleanup(daysThreshold)
    local g = self.db.global
    local cutoff = time() - (daysThreshold * 86400)
    local eligible = {}
    local bytesFreed = 0

    for nameRealm, record in pairs(g.players) do
        if #record.reviews == 0 then
            for _, id in ipairs(record.sessions) do
                local session = g.sessions[id]
                if session and session.date < cutoff then
                    table.insert(eligible, { nameRealm = nameRealm, id = id })
                    bytesFreed = bytesFreed + self:EstimateSize(session)
                end
            end
        end
    end

    return eligible, bytesFreed
end

function addon:ApplySessionCleanup(eligible)
    for _, entry in ipairs(eligible) do
        self:DeleteSession(entry.nameRealm, entry.id)
    end
    return #eligible
end

-- Always merges, never replaces: existing reviews/players win, only
-- genuinely new IDs get added - so restoring an old backup can never undo
-- anything added since it was made.
function addon:ImportData(text)
    text = text and strtrim(text) or ""
    if text == "" then
        return false, "No data pasted."
    end

    local loader = loadstring or load
    local chunk, err = loader(text)
    if not chunk then
        return false, "Couldn't parse (" .. tostring(err) .. ") - make sure the full export text was pasted."
    end

    -- An export is plain data, so run it with no access to any globals: a
    -- pasted string from someone else can't call anything this way.
    if setfenv then setfenv(chunk, {}) end
    local okRun, imported = pcall(chunk)
    if not okRun or type(imported) ~= "table" then
        return false, "Pasted text didn't evaluate to a valid export."
    end

    local reviewsMerged, sessionsMerged, playersTouched = 0, 0, 0

    if type(imported.reviews) == "table" then
        for id, review in pairs(imported.reviews) do
            if not self.db.global.reviews[id] then
                self.db.global.reviews[id] = review
                reviewsMerged = reviewsMerged + 1
            end
        end
    end

    if type(imported.sessions) == "table" then
        for id, session in pairs(imported.sessions) do
            if not self.db.global.sessions[id] then
                self.db.global.sessions[id] = session
                sessionsMerged = sessionsMerged + 1
            end
        end
    end

    if type(imported.players) == "table" then
        for nameRealm, importedRecord in pairs(imported.players) do
            local record = self:GetOrCreatePlayer(nameRealm)
            local existingReviewIDs = {}
            for _, id in ipairs(record.reviews) do existingReviewIDs[id] = true end

            if type(importedRecord.reviews) == "table" then
                for _, id in ipairs(importedRecord.reviews) do
                    if not existingReviewIDs[id] then
                        table.insert(record.reviews, id)
                        existingReviewIDs[id] = true
                    end
                end
            end

            local existingSessionIDs = {}
            for _, id in ipairs(record.sessions) do existingSessionIDs[id] = true end

            if type(importedRecord.sessions) == "table" then
                for _, id in ipairs(importedRecord.sessions) do
                    if not existingSessionIDs[id] then
                        table.insert(record.sessions, id)
                        existingSessionIDs[id] = true
                    end
                end
            end

            if importedRecord.lastSeen and importedRecord.lastSeen.date
                and (not record.lastSeen.date or importedRecord.lastSeen.date > record.lastSeen.date) then
                record.lastSeen.date = importedRecord.lastSeen.date
                record.lastSeen.zone = importedRecord.lastSeen.zone
            end

            playersTouched = playersTouched + 1
        end
    end

    -- Unlike reviews/players, settings aren't additive records - there's
    -- nothing sensible to "merge" field by field, so an imported settings
    -- table replaces the current one outright (this is also how /pr
    -- options values get backed up and restored, per user request, since
    -- they're just as exposed to the same beta SavedVariables issue).
    local settingsRestored = false
    if type(imported.settings) == "table" then
        self.db.global.settings = imported.settings
        settingsRestored = true
    end

    return true, playersTouched, reviewsMerged, settingsRestored, sessionsMerged
end
