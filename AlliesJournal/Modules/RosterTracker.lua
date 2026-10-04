local addon = PlayerReview
local RosterTracker = addon:NewModule("RosterTracker", "AceEvent-3.0")

RosterTracker.roster = {}         -- guid -> { nameRealm, unit, role }
RosterTracker.groupedSince = {}   -- guid -> timestamp (in memory only, not saved)
-- nameRealm -> { guid, role, fights, chat, since, groupedSeconds,
-- combatSeconds, encounter } - a snapshot taken at the exact moment
-- ANYONE leaves the group (see OnRosterUpdate), regardless of whether
-- the review-prompt gate was met - so "Review Player" (the right-click
-- menu button, see Tooltip.lua) can always reopen a full review with the
-- real fight/chat data attached: whether the gate wasn't met and no
-- prompt ever queued, or a prompt DID queue and just got skipped/closed
-- by accident. In memory only, keyed by nameRealm since that's all a
-- chat name-link's context menu has to look up with - overwritten (not
-- accumulated) each time that player departs again.
RosterTracker.recentDepartures = {}
-- guid -> true once a session's been recorded for the CURRENT continuous
-- grouping stretch, in memory only - guards against the same stretch
-- producing more than one session record if multiple triggers fire while
-- still grouped (e.g. two dungeons back to back with the same party).
-- Cleared alongside groupedSince when the player leaves the roster.
RosterTracker.sessionRecorded = {}
-- Same guard, for the review PROMPT queue - QueueEntireRoster gets called
-- from three independent triggers (CHALLENGE_MODE_COMPLETED,
-- LFG_COMPLETION_REWARD, and the zone-exit fallback in OnZoneCheck), and
-- more than one can genuinely fire for the same dungeon clear (confirmed
-- in-game: a single run produced 6-7 queued reviews with several players
-- duplicated). sessionRecorded already prevented this for sessions;
-- nothing equivalent existed for the review queue itself until now.
RosterTracker.reviewQueued = {}
RosterTracker.wasInDungeon = false
RosterTracker.currentEncounterName = nil

-- Dungeon runs. Each time you enter a dungeon a new run starts, with its
-- own id; fights recorded inside it are tagged with that id (see
-- ReviewCapture), so a review or session for that dungeon only counts its
-- own fights and its own time, and a second dungeon with the same party is
-- a separate run. currentRunId is set only while inside (nil in the open
-- world); lastRunId stays after leaving so the exit trigger and anyone
-- leaving right afterwards still resolve to the run that just ended.
RosterTracker.runCounter = 0
RosterTracker.currentRunId = nil
RosterTracker.lastRunId = nil
RosterTracker.runStart = {}       -- runId -> time the run started
-- guid -> { [runId] = true } once a prompt / session has been handled for
-- that player in that run, so the several completion triggers of one
-- dungeon don't produce duplicates. Cleared when the player leaves.
RosterTracker.handledReview = {}
RosterTracker.handledSession = {}

-- Where this grouping happened, for session/review records and the
-- Browser's "Seen ... - <place>" text. The dungeon/M+ name when we have
-- one, otherwise the zone we're standing in - open-world groups used to
-- be recorded as "Unknown", which is why some players showed no place.
-- currentEncounterName is deliberately kept after leaving an instance
-- (the zone-exit trigger and people leaving the group a moment later both
-- still need it), so it's only trusted for 15 minutes after the exit.
function RosterTracker:PlaceName()
    if self.currentEncounterName
        and (not self.instanceExitedAt or time() - self.instanceExitedAt < 900) then
        return self.currentEncounterName
    end
    local zone = GetZoneText and GetZoneText()
    if zone and zone ~= "" then return zone end
    return "Unknown"
end

-- True while in a raid group or raid instance - or at the moment you leave
-- one (IsInRaid() is already false then, so the last known state counts).
-- Automatic review prompts and sessions are switched off for these.
function RosterTracker:InRaidContext()
    return IsInRaid() or self.inRaidInstance or self.lastRaid or false
end

-- Saves the dungeon run in progress so a /reload (or logout and straight
-- back in) doesn't start a fresh run with no fights and a restarted time
-- gate. Kept outside `global` (in PRTrackerAccountDB.runCache) so it never
-- ends up in an export, and cleared whenever there's nothing to save.
function RosterTracker:OnLogout()
    local db = PRTrackerAccountDB
    if not db then return end
    db.runCache = nil
    local runId = self.currentRunId
    if not runId or not IsInGroup() or self:InRaidContext() then return end

    local ok, cache = pcall(function()
        local grouped, handledReview, handledSession = {}, {}, {}
        for guid in pairs(self.roster) do
            grouped[guid] = self.groupedSince[guid]
            handledReview[guid] = IsHandled(self.handledReview, guid, runId) or nil
            handledSession[guid] = IsHandled(self.handledSession, guid, runId) or nil
        end
        return {
            savedAt = time(),
            mapID = select(8, GetInstanceInfo()),
            runId = runId,
            runCounter = self.runCounter,
            runStart = self.runStart[runId],
            grouped = grouped,
            handledReview = handledReview,
            handledSession = handledSession,
            cycles = addon:GetModule("ReviewCapture"):ExportRun(runId),
        }
    end)
    if ok then db.runCache = cache end
end

-- Called when a dungeon is entered: if this is just a /reload (or quick
-- relog) inside the dungeon the saved run was in, carry on with it instead
-- of starting a new one. Returns true when it did.
function RosterTracker:TryRestoreRun()
    local db = PRTrackerAccountDB
    local cache = db and db.runCache
    if not cache then return false end
    db.runCache = nil  -- used up either way; saved again at the next logout

    if type(cache) ~= "table" or not cache.runId or not cache.savedAt then return false end
    if time() - cache.savedAt > 600 then return false end
    if cache.mapID ~= select(8, GetInstanceInfo()) then return false end

    local runId = cache.runId
    self.runCounter = math.max(self.runCounter, cache.runCounter or runId)
    self.currentRunId = runId
    self.lastRunId = runId
    self.runStart[runId] = cache.runStart or time()

    -- The roster may or may not be filled in yet; either way keep the
    -- earlier of the two grouped-since times.
    for guid, since in pairs(cache.grouped or {}) do
        local existing = self.groupedSince[guid]
        self.groupedSince[guid] = existing and math.min(existing, since) or since
    end
    for guid in pairs(cache.handledReview or {}) do MarkHandled(self.handledReview, guid, runId) end
    for guid in pairs(cache.handledSession or {}) do MarkHandled(self.handledSession, guid, runId) end

    addon:GetModule("ReviewCapture"):ImportRun(cache.cycles or {}, runId)
    return true
end

-- The run a departure or manual action belongs to: the dungeon you're in,
-- or - for 15 minutes after leaving one - the one you just left (same
-- window PlaceName trusts). nil means open-world content.
function RosterTracker:ActiveRunId()
    if self.currentRunId then return self.currentRunId end
    if self.lastRunId and self.instanceExitedAt and time() - self.instanceExitedAt < 900 then
        return self.lastRunId
    end
    return nil
end

-- When counting for this run starts: for a dungeon run, the later of "first
-- grouped with them" and "entered the dungeon" (time in the open world
-- before the dungeon doesn't count towards it); otherwise the plain
-- grouped-since time.
function RosterTracker:RunSince(since, runId)
    if not since then return nil end
    if runId and self.runStart[runId] then
        return math.max(since, self.runStart[runId])
    end
    return since
end

local function IsHandled(map, guid, runId)
    return map[guid] and map[guid][runId] or false
end

local function MarkHandled(map, guid, runId)
    map[guid] = map[guid] or {}
    map[guid][runId] = true
end

function RosterTracker:OnEnable()
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnRosterUpdate")
    self:RegisterEvent("CHALLENGE_MODE_COMPLETED", "OnChallengeModeCompleted")
    self:RegisterEvent("LFG_COMPLETION_REWARD", "OnDungeonComplete")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnZoneCheck")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "OnZoneCheck")
    -- Fires on logout and on /reload, just before the saved variables are
    -- written - the moment to save a dungeon run in progress.
    self:RegisterEvent("PLAYER_LOGOUT", "OnLogout")
    -- PARTY_KICKED is intentionally not hooked: the roster diff below
    -- already detects every departure (leave, kick, or disconnect) generically,
    -- and the design explicitly doesn't try to label *why* someone left.
end

-- Used by ChatLog to resolve a chat message's sender name to a GUID, so
-- captured lines can be filed under the same key QueueCandidates hands to
-- ReviewPrompt. Only resolves against the currently-live roster (fine: chat
-- is only ever captured while the sender is still grouped with us).
function RosterTracker:GetGUIDForName(nameRealm)
    for guid, data in pairs(self.roster) do
        if data.nameRealm == nameRealm then
            return guid
        end
    end
    return nil
end

function RosterTracker:GetGateSeconds()
    local minutes = addon.db.global.settings.gateMinutes or 10
    return minutes * 60
end

function RosterTracker:GetSessionGateSeconds()
    local sg = addon.db.global.settings.sessionGate
    return sg.minGroupedSeconds, sg.minCombatSeconds
end

local function FormatDuration(seconds)
    seconds = math.floor(seconds or 0)
    if seconds < 60 then
        return seconds .. "s"
    end
    return string.format("%dm%02ds", math.floor(seconds / 60), seconds % 60)
end

local function IterateGroupUnits()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            table.insert(units, "raid" .. i)
        end
    elseif IsInGroup() then
        -- party1..partyN never include the player's own unit, so the count
        -- of other-member tokens is GetNumGroupMembers() - 1.
        for i = 1, GetNumGroupMembers() - 1 do
            table.insert(units, "party" .. i)
        end
    end
    return units
end

function RosterTracker:OnRosterUpdate()
    local capture = addon:GetModule("ReviewCapture")
    local playerGUID = UnitGUID("player")
    local newRoster = {}
    local runId = self:ActiveRunId()  -- the dungeon run this departure belongs to, if any
    -- Raids never get automatic prompts or sessions (40 people!), but all the
    -- data is still captured so any one of them can be reviewed by hand.
    -- IsInRaid() is already false by the time you've left the group, hence
    -- the remembered state from the previous update.
    local raidContext = self:InRaidContext()
    self.lastRaid = IsInRaid()

    for _, unit in ipairs(IterateGroupUnits()) do
        local guid = UnitGUID(unit)
        if guid and guid ~= playerGUID then
            local nameRealm = addon:GetFullName(unit)
            if nameRealm then
                newRoster[guid] = {
                    nameRealm = nameRealm,
                    unit = unit,
                    role = capture:GetRole(unit),
                }
                -- track groupedSince per GUID from first appearance in the roster
                if not self.groupedSince[guid] then
                    self.groupedSince[guid] = time()
                end

                -- Someone genuinely new to the roster (self.roster is
                -- still the OLD roster here) who's already been reviewed
                -- before: re-sync their pin/note to C_RecentAllies from
                -- our own stored review. That Blizzard-side pin expires
                -- after ~89 days on its own - re-applying it every time
                -- you happen to regroup with a reviewed player uses our
                -- durable SavedVariables record as the fallback that
                -- keeps pushing the clock back out, instead of just
                -- letting it silently lapse between encounters.
                if not self.roster[guid] then
                    local review = addon:GetLatestReview(nameRealm)
                    if review then
                        addon:SyncRecentAlly(guid, review, nameRealm, true)
                    end
                end
            end
        end
    end

    -- anyone tracked before but missing now left the group: quit, kick, or
    -- disconnect. Capture their last known data + grouped-since timestamp;
    -- groupedSince itself is read by QueueCandidates below (before being
    -- cleared further down), since their unit token is gone.
    local departed = {}
    for guid, data in pairs(self.roster) do
        if not newRoster[guid] then
            table.insert(departed, { guid = guid, data = data, since = self.groupedSince[guid] })
        end
    end

    self.roster = newRoster

    if #departed > 0 and not raidContext then
        self:QueueCandidates(departed, false, runId)
    end

    -- Gate state gets cleared AFTER QueueCandidates (and the session-
    -- eligibility check inside it) has had a chance to read it - clearing
    -- it earlier, before that read, would zero out combat time right
    -- before it's checked, making every departure look like zero combat
    -- regardless of what actually happened. Whatever accumulated for THIS
    -- stretch of grouping is done now that they're gone either way - a
    -- future regrouping with the same person starts fresh.
    for _, d in ipairs(departed) do
        -- Read everything BEFORE clearing below - this is the only chance
        -- to snapshot it. Every departure gets one (not just the below-
        -- gate case) - a review prompt that DID queue can still get
        -- skipped/closed by accident, or just alt-tabbed past, and this
        -- is what lets "Review Player" on their name reopen it afterward
        -- with the same real fight/chat data, same as the below-gate
        -- case always could. A tiny floor (30s) skips instant roster
        -- blips (an accidental invite/decline).
        if d.since then
            local since = self:RunSince(d.since, runId)
            local groupedSeconds = time() - since
            local gateSeconds = self:GetGateSeconds()
            if groupedSeconds >= 30 then
                local combatSeconds = capture:GetCombatSeconds(d.guid, runId)
                local fights = {}
                for i, fight in ipairs(capture:GetRunFights(d.guid, runId)) do fights[i] = fight end
                local chat = {}
                for i, msg in ipairs(addon:GetModule("ChatLog"):GetMessages(d.guid)) do chat[i] = msg end

                self.recentDepartures[d.data.nameRealm] = {
                    guid = d.guid,
                    role = d.data.role,
                    encounter = self:PlaceName(),
                    fights = fights,
                    chat = chat,
                    since = since,
                    groupedSeconds = groupedSeconds,
                    combatSeconds = combatSeconds,
                }

                -- Only announced when a review prompt did NOT also queue
                -- for this guid - a real prompt already tells you it's
                -- there; this is specifically for the case where nothing
                -- would otherwise show up at all.
                if not raidContext and addon.db.global.settings.departureSummary.enabled and groupedSeconds < gateSeconds then
                    local shortName = addon:GetShortName(d.data.nameRealm)
                    local link = string.format("|Hplayer:%s|h[%s]|h", d.data.nameRealm, shortName)
                    -- Class-colored like a normal chat name. GUID-based, so
                    -- it still works now that they've left the group;
                    -- falls back to the plain link if the client has no
                    -- class info cached for them.
                    local okClass, _, englishClass = pcall(GetPlayerInfoByGUID, d.guid)
                    local classColor = okClass and englishClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[englishClass]
                    if classColor and classColor.colorStr then
                        link = "|c" .. classColor.colorStr .. link .. "|r"
                    end
                    addon:Print(string.format(
                        "Finished grouping with %s - %s together, %s in combat. Right-click their name to add an entry.",
                        link, FormatDuration(groupedSeconds), FormatDuration(combatSeconds)))
                end
            end
        end

        self.groupedSince[d.guid] = nil
        self.sessionRecorded[d.guid] = nil
        self.reviewQueued[d.guid] = nil
        self.handledReview[d.guid] = nil
        self.handledSession[d.guid] = nil
        capture:ClearCombatSeconds(d.guid)
        -- Cleared here too, AFTER QueueCandidates (both the session
        -- aggregate above and, if a review prompt gets queued, whatever
        -- ReviewPrompt reads from it later while that prompt is still
        -- open) has had its chance - not before, same reasoning as
        -- combat seconds. If a review prompt is still pending for this
        -- guid it already captured what it needs when queued. The
        -- recentDepartures snapshot just above already has its own copy,
        -- so clearing the live state here doesn't affect it.
        capture:ClearFights(d.guid)
    end
end

-- Called from the chat-name right-click menu (Tooltip.lua) when clicking
-- a player who has no live unit - if they departed recently enough to
-- still have a recentDepartures snapshot, this queues a review carrying
-- their REAL fight/chat data instead of the bare nameRealm-only fallback.
-- Returns true if it found one and queued it, false otherwise (caller
-- falls back to the generic manual-review path).
function RosterTracker:QueueDeparted(nameRealm)
    local snap = self.recentDepartures[nameRealm]
    if not snap then return false end

    -- Restored into the live buffer so ReviewPrompt's existing chat
    -- section and Save() (both of which read ChatLog:GetMessages(guid)
    -- live, unaware this is a departed player) work completely
    -- unmodified - no special-casing needed there for this path.
    if #snap.chat > 0 then
        addon:GetModule("ChatLog").messages[snap.guid] = snap.chat
    end

    addon:GetModule("ReviewPrompt"):QueueBatch({
        {
            nameRealm = nameRealm,
            encounter = snap.encounter,
            role = snap.role,
            guid = snap.guid,
            fights = snap.fights,
            since = snap.since,
        },
    })
    return true
end

-- runId: the dungeon run that just finished, or nil for open-world content.
function RosterTracker:QueueEntireRoster(runId)
    if self:InRaidContext() then return end  -- no automatic prompts in raids
    local candidates = {}
    for guid, data in pairs(self.roster) do
        table.insert(candidates, { guid = guid, data = data, since = self.groupedSince[guid] })
    end
    self:QueueCandidates(candidates, true, runId)
end

-- Runs alongside (not instead of) the review-prompt gate below, on the
-- exact same candidates/trigger points - an independent, AND-gated check
-- (BOTH minGroupedSeconds and minCombatSeconds must clear, not either)
-- for whether this stretch of grouping is worth persisting as a session,
-- regardless of whether a review prompt also fires for the same player.
-- sessionRecorded guards against double-recording the same continuous
-- grouping if multiple triggers fire before the player leaves the roster.
--
-- Sessions never carry chat (only a review does - see ReviewPrompt's
-- Save) and never carry per-fight detail, only the compact aggregate
-- ReviewCapture:AggregateFights computes from ALL fights recorded so
-- far - there's no picker for a plain session, only for a review.
function RosterTracker:CheckSessionEligibility(candidates, runId)
    local capture = addon:GetModule("ReviewCapture")
    local minGrouped, minCombat = self:GetSessionGateSeconds()

    for _, c in ipairs(candidates) do
        local alreadyRecorded
        if runId then
            alreadyRecorded = IsHandled(self.handledSession, c.guid, runId)
        else
            alreadyRecorded = self.sessionRecorded[c.guid]
        end

        if c.since and not alreadyRecorded then
            local groupedSeconds = time() - self:RunSince(c.since, runId)
            local combatSeconds = capture:GetCombatSeconds(c.guid, runId)

            if groupedSeconds >= minGrouped and combatSeconds >= minCombat then
                local aggregate = capture:AggregateFights(capture:GetRunFights(c.guid, runId))
                addon:AddSession(c.data.nameRealm, {
                    zone = self:PlaceName(),
                    groupedSeconds = groupedSeconds,
                    combatSeconds = combatSeconds,
                    dps = aggregate.dps,
                    hps = aggregate.hps,
                    groupMaxDps = aggregate.groupMaxDps,
                    groupMaxHps = aggregate.groupMaxHps,
                    groupTotalDps = aggregate.groupTotalDps,
                    groupTotalHps = aggregate.groupTotalHps,
                    interrupts = aggregate.interrupts,
                    dispels = aggregate.dispels,
                    deaths = aggregate.deaths,
                })

                if runId then
                    MarkHandled(self.handledSession, c.guid, runId)
                else
                    self.sessionRecorded[c.guid] = true
                end
            end
        end
    end
end

-- unitStillValid: true when candidates come from the live roster (instance
-- complete) so a fresh role read is possible; false when the player has
-- already left the group (leave/kick), where only the last cached read exists.
function RosterTracker:QueueCandidates(candidates, unitStillValid, runId)
    self:CheckSessionEligibility(candidates, runId)

    local capture = addon:GetModule("ReviewCapture")
    local gateSeconds = self:GetGateSeconds()
    local batch = {}

    for _, c in ipairs(candidates) do
        local since = self:RunSince(c.since, runId)
        local alreadyQueued
        if runId then
            alreadyQueued = IsHandled(self.handledReview, c.guid, runId)
        else
            alreadyQueued = self.reviewQueued[c.guid]
        end

        if since and (time() - since) >= gateSeconds and not alreadyQueued then
            if runId then
                MarkHandled(self.handledReview, c.guid, runId)
            else
                self.reviewQueued[c.guid] = true
            end

            local role = c.data.role
            if unitStillValid and c.data.unit and UnitGUID(c.data.unit) == c.guid then
                role = capture:GetRole(c.data.unit) or role
            end

            -- Snapshotted here (shallow copy - individual fight tables
            -- are never mutated after creation, only this list grows)
            -- rather than having ReviewPrompt read capture:GetFights(guid)
            -- live when the prompt is actually shown: a queued review
            -- isn't necessarily shown immediately (it may sit behind
            -- others in the same batch), by which point ClearFights
            -- below may have already run for this guid.
            local fights = {}
            for i, fight in ipairs(capture:GetRunFights(c.guid, runId)) do
                fights[i] = fight
            end

            table.insert(batch, {
                nameRealm = c.data.nameRealm,
                encounter = self:PlaceName(),
                role = role,
                guid = c.guid,
                fights = fights,
                -- Session window (grouped-since -> now) - lets
                -- ReviewPrompt pull every C_RecentAllies interaction that
                -- happened while actually grouped with this person,
                -- rather than guessing at the single "closest" one.
                since = since,
            })
        end
    end

    if #batch > 0 then
        addon:GetModule("ReviewPrompt"):QueueBatch(batch)
    end
end

function RosterTracker:OnChallengeModeCompleted()
    local ok, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
    if ok and mapID then
        local ok2, name = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
        if ok2 and name then
            self.currentEncounterName = name .. " (M+)"
        end
    end
    self:CloseRunSoon()
end

function RosterTracker:OnDungeonComplete()
    -- LFG_COMPLETION_REWARD only fires for Group/Raid Finder completions.
    -- Manually formed groups are caught by the zone-exit fallback below.
    self:CloseRunSoon()
end

-- Finishes the current dungeon run (prompts + sessions) a moment after the
-- completion event: the last boss fight's combat-end can arrive just after
-- it, and that fight belongs to this run. The run id is captured now, so a
-- fast zone change in between still resolves to the right run.
function RosterTracker:CloseRunSoon()
    local runId = self.currentRunId
    C_Timer.After(2, function() self:QueueEntireRoster(runId) end)
end

function RosterTracker:OnZoneCheck()
    local inInstance, instanceType = IsInInstance()
    local isDungeonNow = inInstance and instanceType == "party"
    self.inRaidInstance = inInstance and instanceType == "raid"

    if isDungeonNow then
        self.currentEncounterName = GetInstanceInfo()
        self.instanceExitedAt = nil
    end

    -- Entering a dungeon starts a new run, so everything recorded inside it
    -- is kept apart from the open world and from any earlier dungeon.
    if isDungeonNow and not self.wasInDungeon and not self:TryRestoreRun() then
        self.runCounter = self.runCounter + 1
        self.currentRunId = self.runCounter
        self.lastRunId = self.runCounter
        self.runStart[self.runCounter] = time()
    end

    if self.wasInDungeon and not isDungeonNow then
        -- Best-effort catch-all "normal dungeon complete" trigger for groups
        -- that didn't go through Group Finder (no LFG_COMPLETION_REWARD).
        -- This also fires on an early group walkout; the time gate is what
        -- keeps that from producing spurious prompts. It's the loosest
        -- trigger of the three - check it in-game and tighten it if it
        -- over-fires.
        self:QueueEntireRoster(self.currentRunId)
    end

    if self.wasInDungeon and not isDungeonNow then
        self.instanceExitedAt = time()
        self.currentRunId = nil  -- back in the open world (lastRunId stays)
    end

    self.wasInDungeon = isDungeonNow
end
