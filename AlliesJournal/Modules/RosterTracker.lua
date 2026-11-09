local addon = AlliesJournal
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
-- guid -> runKey -> { bosses, quests, wipes }: what happened while that person
-- was in the group, counted per dungeon run (runKey is the run id, or 0 in the
-- open world) so a second dungeon with the same party stays separate. In
-- memory, plus the run cache across a /reload.
RosterTracker.tally = {}

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

-- These have to stay above OnLogout and TryRestoreRun: a local defined lower
-- down isn't visible to them, and the pcall in OnLogout would hide the error.
local function IsHandled(map, guid, runId)
    return map[guid] and map[guid][runId] or false
end

local function MarkHandled(map, guid, runId)
    map[guid] = map[guid] or {}
    map[guid][runId] = true
end

-- Saves the dungeon run in progress so a /reload, a relog or a disconnect
-- doesn't start a fresh run with no fights and a restarted time gate. Kept
-- outside `global` (in AlliesJournalDB.runCache) so it never ends up in an
-- export.
--
-- Saved every RUN_SAVE_SECONDS while in a dungeon with a group, not just at
-- logout: when the connection drops, the group can look empty (everyone
-- "leaves" at once) before the game logs out, so a save at that moment had
-- nothing left to save. An empty group therefore never overwrites a saved
-- run; the run is only thrown away when you leave the dungeon normally, are
-- back outside one, or it's too old to pick up (see TryRestoreRun).
local RUN_SAVE_SECONDS = 60
-- How often to check whether a save is due (a check is nearly free).
local RUN_CHECK_SECONDS = 15
-- How long after the last save a run can still be picked up again in the
-- same dungeon: room for a disconnect, a client restart and a login queue.
local RUN_RESTORE_SECONDS = 45 * 60

function RosterTracker:OnLogout()
    self:SaveRun()
end

-- Saves the run if the last save is a minute old or more, unless you're in
-- combat (nothing runs mid-fight).
function RosterTracker:SaveRunIfDue()
    if InCombatLockdown() then return end
    if self.lastRunSave and time() - self.lastRunSave < RUN_SAVE_SECONDS then return end
    pcall(self.SaveRun, self)
end

-- A second after a fight ends: ReviewCapture records the fight on this same
-- event, and the order the two run in isn't fixed, so waiting a moment makes
-- sure the save includes it. If the next pull has already started by then,
-- SaveRunIfDue skips and the next fight's end tries again.
function RosterTracker:OnCombatEnd()
    C_Timer.After(1, function() self:SaveRunIfDue() end)
end

function RosterTracker:SaveRun()
    local db = AlliesJournalDB
    if not db then return end
    local runId = self.currentRunId
    if not runId or not next(self.roster) or self:InRaidContext() then return end

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
            tally = self.tally,
        }
    end)
    if ok then
        db.runCache = cache
        self.lastRunSave = time()
    end
end

-- Called when a dungeon is entered: if this is a /reload, relog or
-- reconnect inside the dungeon the saved run was in, carry on with it
-- instead of starting a new one. Returns true when it did. What happened is
-- kept in self.lastRestore for "/aj why".
function RosterTracker:TryRestoreRun()
    local function Refuse(reason)
        self.lastRestore = { at = time(), ok = false, reason = reason }
        return false
    end

    local db = AlliesJournalDB
    local cache = db and db.runCache
    if not cache then
        -- Walking in from outside never has one; only a login or reload
        -- straight into a dungeon is worth reporting.
        if self.freshLoad then return Refuse("no saved run was found (the game may have closed before it could save)") end
        return false
    end
    db.runCache = nil  -- used up either way; saved again while the run goes on

    if type(cache) ~= "table" or not cache.runId or not cache.savedAt then return Refuse("the saved run was unreadable") end
    local age = time() - cache.savedAt
    if age > RUN_RESTORE_SECONDS then
        return Refuse(string.format("it was last saved %d minutes before you got back, more than the %d allowed",
            math.floor(age / 60), RUN_RESTORE_SECONDS / 60))
    end
    if cache.mapID ~= select(8, GetInstanceInfo()) then return Refuse("it was saved in a different dungeon") end
    self.lastRestore = { at = time(), ok = true, gap = age }

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

    for guid, byRun in pairs(cache.tally or {}) do
        local mine = self.tally[guid] or {}
        self.tally[guid] = mine
        for key, counts in pairs(byRun) do
            local existing = mine[key] or {}
            mine[key] = existing
            for field, value in pairs(counts) do existing[field] = math.max(existing[field] or 0, value) end
        end
    end

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

-- The handled guards only last for one dungeon run or one stretch of grouping,
-- so a group you play with often would be asked about after every dungeon, and
-- again when they leave. This one lasts: once the automatic note window has
-- asked about someone, or you've written them a note, it leaves them alone for
-- askAgainHours. It never gets in the way of writing a note by hand.
-- Kept outside `global` (in AlliesJournalDB.askedAt, by nameRealm) so it never
-- ends up in an export.
local ASKED_KEEP_SECONDS = 7 * 86400  -- longer than the options slider goes

-- Why someone counts as asked recently, or nil when they don't: "asked" (the
-- note window asked about them) or "note" (you wrote one), when that was, and
-- when the wait runs out. The later of the two decides.
function RosterTracker:AskedRecentlyInfo(nameRealm)
    local hours = addon.db.global.settings.askAgainHours or 12
    if hours <= 0 then return nil end
    local wait = hours * 3600
    local cutoff = time() - wait

    local kind, at
    local asked = AlliesJournalDB.askedAt and AlliesJournalDB.askedAt[nameRealm]
    if asked and asked > cutoff then kind, at = "asked", asked end

    local review = addon:GetLatestReview(nameRealm)
    if review and review.date and review.date > cutoff and (not at or review.date > at) then
        kind, at = "note", review.date
    end

    if not kind then return nil end
    return kind, at, at + wait
end

function RosterTracker:AskedRecently(nameRealm)
    return self:AskedRecentlyInfo(nameRealm) ~= nil
end

-- What happened each time a note window could have opened for someone, for
-- "/aj why <name>": the last few per person, newest last. Kept outside
-- `global` (in AlliesJournalDB.promptLog, by nameRealm) so it survives a
-- /reload but never ends up in an export; pruned along with askedAt.
-- outcome: "window", "waiting" (added to notes put off with Later), "chat"
-- (an [Add a note] link instead of a window) or "skipped".
local LOG_PER_PERSON = 6

function RosterTracker:LogDecision(nameRealm, trigger, outcome, detail)
    if not nameRealm or not AlliesJournalDB then return end
    AlliesJournalDB.promptLog = AlliesJournalDB.promptLog or {}
    local entries = AlliesJournalDB.promptLog[nameRealm] or {}
    AlliesJournalDB.promptLog[nameRealm] = entries
    table.insert(entries, { at = time(), trigger = trigger, outcome = outcome, detail = detail })
    while #entries > LOG_PER_PERSON do table.remove(entries, 1) end
end

-- Enough notes on someone that a window would only be in the way: they get a
-- chat line with a link instead (ReviewPrompt:OfferInChat). Only notes you
-- actually wrote count, not windows you skipped. 0 always opens the window.
function RosterTracker:KnownWell(nameRealm)
    local limit = addon.db.global.settings.windowNoteLimit or 3
    return limit > 0 and #addon:GetReviewsForPlayer(nameRealm) >= limit
end

function RosterTracker:MarkAsked(nameRealm)
    AlliesJournalDB.askedAt = AlliesJournalDB.askedAt or {}
    AlliesJournalDB.askedAt[nameRealm] = time()
end

function RosterTracker:PruneAsked()
    local cutoff = time() - ASKED_KEEP_SECONDS
    local askedAt = AlliesJournalDB.askedAt
    if askedAt then
        for nameRealm, asked in pairs(askedAt) do
            if asked < cutoff then askedAt[nameRealm] = nil end
        end
    end
    local promptLog = AlliesJournalDB.promptLog
    if promptLog then
        for nameRealm, entries in pairs(promptLog) do
            local last = type(entries) == "table" and entries[#entries]
            if not last or not last.at or last.at < cutoff then promptLog[nameRealm] = nil end
        end
    end
end

function RosterTracker:OnEnable()
    self:PruneAsked()
    self:RegisterEvent("GROUP_ROSTER_UPDATE", "OnRosterUpdate")
    self:RegisterEvent("CHALLENGE_MODE_COMPLETED", "OnChallengeModeCompleted")
    self:RegisterEvent("LFG_COMPLETION_REWARD", "OnDungeonComplete")
    self:RegisterEvent("PLAYER_ENTERING_WORLD", "OnZoneCheck")
    self:RegisterEvent("ZONE_CHANGED_NEW_AREA", "OnZoneCheck")
    -- Fires on logout and on /reload, just before the saved variables are
    -- written - the moment to save a dungeon run in progress.
    self:RegisterEvent("PLAYER_LOGOUT", "OnLogout")
    -- And all along, so a disconnect still has a recent copy (see SaveRun):
    -- checked often, saved at most once a minute and never mid-fight. A fight
    -- ending is a moment to save too, so back-to-back pulls that happen to
    -- cover every check still get saved between them.
    C_Timer.NewTicker(RUN_CHECK_SECONDS, function() self:SaveRunIfDue() end)
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnd")
    -- Boss kills, wipes and quests handed in while grouped (for "together so
    -- far"). Guarded: an event this client doesn't know must not break loading.
    pcall(self.RegisterEvent, self, "ENCOUNTER_END", "OnEncounterEnd")
    pcall(self.RegisterEvent, self, "QUEST_TURNED_IN", "OnQuestTurnedIn")
    pcall(self.RegisterEvent, self, "CHAT_MSG_COMBAT_XP_GAIN", "OnKillExperience")
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
    if seconds >= 3600 then
        return string.format("%dh%02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
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

-- Class, race, level and guild of a grouped unit, for the "how you met" line.
-- Anything the client won't give (secret, or not loaded yet) keeps the value
-- from the last update.
local function Readable(value)
    if value ~= nil and issecretvalue and issecretvalue(value) then return nil end
    return value
end

local function UnitDetails(unit, previous)
    local out = {
        class = previous and previous.class, race = previous and previous.race,
        level = previous and previous.level, guild = previous and previous.guild,
    }
    local okClass, _, classFile = pcall(UnitClass, unit)
    if okClass and Readable(classFile) then out.class = classFile end
    local okRace, race = pcall(UnitRace, unit)
    if okRace and Readable(race) then out.race = race end
    local okLevel, level = pcall(UnitLevel, unit)
    level = okLevel and Readable(level)
    if level and level > 0 then out.level = level end
    local okGuild, guild = pcall(GetGuildInfo, unit)
    if okGuild and Readable(guild) and guild ~= "" then out.guild = guild end
    return out
end

-- Counts a boss kill, a wipe or a quest hand-in for everyone in the group.
-- Raids are left out: they never produce sessions.
function RosterTracker:Tally(field)
    if self:InRaidContext() then return end
    local key = self.currentRunId or 0
    for guid in pairs(self.roster) do
        local byRun = self.tally[guid]
        if not byRun then byRun = {}; self.tally[guid] = byRun end
        local counts = byRun[key]
        if not counts then counts = {}; byRun[key] = counts end
        counts[field] = (counts[field] or 0) + 1
    end
end

function RosterTracker:GetTally(guid, runId)
    local byRun = self.tally[guid]
    return byRun and byRun[runId or 0] or {}
end

function RosterTracker:OnEncounterEnd(_, _, _, _, _, success)
    pcall(function()
        if success == 1 then self:Tally("bosses") elseif success == 0 then self:Tally("wipes") end
    end)
end

function RosterTracker:OnQuestTurnedIn()
    self:Tally("quests")
end

-- One of these per mob that dies and gives you experience ("X dies, you gain
-- N experience"): the one kill signal that doesn't need the combat log, which
-- this client restricts. So grey mobs and kills you got nothing for don't count.
function RosterTracker:OnKillExperience()
    self:Tally("mobs")
end

function RosterTracker:OnRosterUpdate()
    -- With a GUID hidden there's no telling who is still here, and anyone
    -- unmatched would count as having left. The next update catches up.
    if issecretvalue then
        for _, unit in ipairs(IterateGroupUnits()) do
            if issecretvalue(UnitGUID(unit)) then return end
        end
    end

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
                local details = UnitDetails(unit, self.roster[guid])
                newRoster[guid] = {
                    nameRealm = nameRealm,
                    unit = unit,
                    role = capture:GetRole(unit),
                    class = details.class, race = details.race,
                    level = details.level, guild = details.guild,
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
                    -- Grouped means online, when Battle.net can answer for
                    -- certain, so this also clears someone since unfriended.
                    local record = addon.db.global.players[nameRealm]
                    if record then record.friend = addon:IsFriend(guid) or nil end

                    local review = addon:GetLatestReview(nameRealm)
                    if review then
                        addon:SyncRecentAlly(guid, review, nameRealm, true)
                    end
                    -- "You've played with them" - not in raids (too many people).
                    if not raidContext then
                        local okClass, _, classFile = pcall(UnitClass, unit)
                        addon:GetModule("Notices"):PlayerJoined(nameRealm, okClass and classFile or nil)
                    end
                end
            elseif self.roster[guid] then
                -- Still in the group, but the client is hiding or hasn't
                -- loaded their name. Keep the last entry, or they'd count
                -- as having left below and lose their fights.
                newRoster[guid] = self.roster[guid]
                newRoster[guid].unit = unit
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

    if #departed > 0 then
        -- Not in a group any more means you left or the group broke up.
        local trigger = IsInGroup() and "they left the group" or "the group ended"
        if raidContext then
            for _, d in ipairs(departed) do
                self:LogDecision(d.data.nameRealm, trigger, "skipped", "it was a raid - raids never open the note window")
            end
        else
            self:QueueCandidates(departed, false, runId, trigger)
        end
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
                        "Finished grouping with %s - %s together, %s in combat. Right-click their name to add a note.",
                        link, FormatDuration(groupedSeconds), FormatDuration(combatSeconds)))
                end
            end
        end

        self.groupedSince[d.guid] = nil
        self.sessionRecorded[d.guid] = nil
        self.reviewQueued[d.guid] = nil
        self.tally[d.guid] = nil
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
    }, true)
    return true
end

-- runId: the dungeon run that just finished, or nil for open-world content.
-- trigger: a few words for "/aj why", e.g. "you left the dungeon".
function RosterTracker:QueueEntireRoster(runId, trigger)
    trigger = trigger or "the dungeon ended"
    if self:InRaidContext() then  -- no automatic prompts in raids
        for _, data in pairs(self.roster) do
            self:LogDecision(data.nameRealm, trigger, "skipped", "it was a raid - raids never open the note window")
        end
        return
    end
    local candidates = {}
    for guid, data in pairs(self.roster) do
        table.insert(candidates, { guid = guid, data = data, since = self.groupedSince[guid] })
    end
    self:QueueCandidates(candidates, true, runId, trigger)
    -- After the sessions above are recorded, so the counts include this run.
    if runId then
        addon:GetModule("Notices"):FamiliarFaces(candidates, runId)
        addon:GetModule("Notices"):RunRecap(candidates, runId)
    end
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
                local tally = self:GetTally(c.guid, runId)
                addon:AddSession(c.data.nameRealm, {
                    zone = self:PlaceName(),
                    role = c.data.role,
                    character = addon:GetShortName(addon:GetPlayerName()),
                    dungeon = runId ~= nil,
                    since = c.since,
                    bosses = tally.bosses, quests = tally.quests, wipes = tally.wipes, mobs = tally.mobs,
                    info = c.data,
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
-- trigger: what set this off, in a few words, for "/aj why".
function RosterTracker:QueueCandidates(candidates, unitStillValid, runId, trigger)
    trigger = trigger or "the group changed"
    -- "Pause recording": no new sessions and no automatic note windows.
    if addon.db.global.settings.paused then
        for _, c in ipairs(candidates) do
            self:LogDecision(c.data.nameRealm, trigger, "skipped", "recording was paused (/aj pause)")
        end
        return
    end
    self:CheckSessionEligibility(candidates, runId)

    local capture = addon:GetModule("ReviewCapture")
    local gateSeconds = self:GetGateSeconds()
    local batch, offers = {}, {}

    for _, c in ipairs(candidates) do
        local nameRealm = c.data.nameRealm
        local since = self:RunSince(c.since, runId)
        local alreadyQueued
        if runId then
            alreadyQueued = IsHandled(self.handledReview, c.guid, runId)
        else
            alreadyQueued = self.reviewQueued[c.guid]
        end
        local askedKind, askedAt, askedUntil = self:AskedRecentlyInfo(nameRealm)

        -- The same checks as always, in order; the first one that fails is
        -- what "/aj why" reports.
        local skip
        if not since then
            skip = "no record of when you grouped up with them"
        elseif time() - since < gateSeconds then
            skip = string.format("together %s of the %s needed%s", FormatDuration(time() - since),
                FormatDuration(gateSeconds), runId and " (counted from when you entered the dungeon)" or "")
        elseif alreadyQueued then
            skip = runId and "already handled earlier in this dungeon run" or "already handled since you grouped up"
        elseif askedKind then
            skip = string.format("%s %s ago, so not asked again for another %s (\"ask again after\" in /aj options)",
                askedKind == "note" and "you wrote a note on them" or "the note window already asked about them",
                FormatDuration(time() - askedAt), FormatDuration(askedUntil - time()))
        end

        if skip then
            self:LogDecision(nameRealm, trigger, "skipped", skip)
        else
            if runId then
                MarkHandled(self.handledReview, c.guid, runId)
            else
                self.reviewQueued[c.guid] = true
            end
            self:MarkAsked(c.data.nameRealm)

            local role = c.data.role
            if unitStillValid and c.data.unit and addon:GetUnitGUID(c.data.unit) == c.guid then
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

            local knownWell = self:KnownWell(nameRealm)
            if knownWell then
                self:LogDecision(nameRealm, trigger, "chat", string.format(
                    "you have %d notes on them, so you got an [Add a note] link in chat instead of the window",
                    #addon:GetReviewsForPlayer(nameRealm)))
            end
            table.insert(knownWell and offers or batch, {
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
        local prompt = addon:GetModule("ReviewPrompt")
        -- Notes put off with Later take in new people without showing anything.
        local intoWaiting = prompt.group and prompt.groupHidden and not prompt.editingReviewID
        for _, data in ipairs(batch) do
            if intoWaiting then
                self:LogDecision(data.nameRealm, trigger, "waiting",
                    "added to the notes you put off with Later, without opening - /aj notes opens them")
            else
                self:LogDecision(data.nameRealm, trigger, "window", "the note window opened for them")
            end
        end
        prompt:QueueBatch(batch)
    end
    if #offers > 0 then
        addon:GetModule("ReviewPrompt"):OfferInChat(offers)
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
    self:CloseRunSoon("you finished the Mythic+ run")
end

function RosterTracker:OnDungeonComplete()
    -- LFG_COMPLETION_REWARD only fires for Group/Raid Finder completions.
    -- Manually formed groups are caught by the zone-exit fallback below.
    self:CloseRunSoon("you finished the dungeon (Group Finder)")
end

-- Finishes the current dungeon run (prompts + sessions) a moment after the
-- completion event: the last boss fight's combat-end can arrive just after
-- it, and that fight belongs to this run. The run id is captured now, so a
-- fast zone change in between still resolves to the right run.
function RosterTracker:CloseRunSoon(trigger)
    local runId = self.currentRunId
    C_Timer.After(2, function() self:QueueEntireRoster(runId, trigger) end)
end

function RosterTracker:OnZoneCheck(event, isInitialLogin, isReloadingUi)
    -- A login or /reload, as opposed to a loading screen while playing.
    self.freshLoad = event == "PLAYER_ENTERING_WORLD" and (isInitialLogin or isReloadingUi) and true or false
    local inInstance, instanceType = IsInInstance()
    local isDungeonNow = inInstance and instanceType == "party"
    self.inRaidInstance = inInstance and instanceType == "raid"
    -- After a load screen or /reload everyone in the group looks new; stay
    -- quiet for a few seconds so that isn't announced.
    addon:GetModule("Notices").quietUntil = GetTime() + 8

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
        self:QueueEntireRoster(self.currentRunId, "you left the dungeon")
    end

    if self.wasInDungeon and not isDungeonNow then
        self.instanceExitedAt = time()
        self.currentRunId = nil  -- back in the open world (lastRunId stays)
        -- A picked-up run can carry grouped-since times for people who left
        -- while you were disconnected; they never "leave" again to clear them.
        for guid in pairs(self.groupedSince) do
            if not self.roster[guid] then self.groupedSince[guid] = nil end
        end
    end

    -- Outside a dungeon there's no run to pick up again, so a saved one
    -- can't be carried into a later visit to the same dungeon by mistake.
    if not isDungeonNow and AlliesJournalDB then
        AlliesJournalDB.runCache = nil
    end

    self.wasInDungeon = isDungeonNow
end

----------------------------------------------------------------------
-- "/aj why <name>": why the note window did or didn't open for someone
----------------------------------------------------------------------

-- A typed name, matched against everyone the addon knows by full or short
-- name (case doesn't matter); empty means your target.
function RosterTracker:ResolveWhyName(input)
    input = strtrim(input or "")
    if input == "" then
        if UnitExists("target") and UnitIsPlayer("target") then return addon:GetFullName("target") end
        return nil
    end

    local exact = addon:NormalizeChatSender(input)
    local wanted = input:lower()
    local function Matches(key)
        return type(key) == "string" and (key == exact or key:lower() == wanted
            or (addon:GetShortName(key) or ""):lower() == wanted)
    end

    for _, data in pairs(self.roster) do
        if Matches(data.nameRealm) then return data.nameRealm end
    end
    local sources = {
        self.recentDepartures,
        AlliesJournalDB.promptLog or {},
        AlliesJournalDB.askedAt or {},
        addon.db.global.players,
    }
    for _, source in ipairs(sources) do
        for key in pairs(source) do
            if Matches(key) then return key end
        end
    end
    return exact
end

local OUTCOME_LABELS = {
    window = "|cff40ff40window opened|r",
    waiting = "|cffffd100added to Later|r",
    chat = "|cff40ff40chat link|r",
    skipped = "|cffff9933no window|r",
}

function RosterTracker:ExplainPrompt(input)
    local nameRealm = self:ResolveWhyName(input)
    if not nameRealm then
        addon:Print("Usage: /aj why <name> - or target them and type /aj why")
        return
    end
    local now = time()
    local settings = addon.db.global.settings
    addon:Print("Note window for " .. addon:GetShortName(nameRealm) .. ":")

    -- What happened each time a trigger looked at them.
    local log = AlliesJournalDB.promptLog and AlliesJournalDB.promptLog[nameRealm]
    if log and #log > 0 then
        for _, e in ipairs(log) do
            addon:Print(string.format("  %s ago, when %s: %s - %s", FormatDuration(now - (e.at or now)),
                e.trigger or "?", OUTCOME_LABELS[e.outcome] or tostring(e.outcome), e.detail or ""))
        end
    else
        addon:Print("  Nothing recorded for them yet. Either nothing has ended since this started being tracked,"
            .. " or they were never tracked in your group - that happens when the game hides their name as they join.")
    end

    -- And where things stand right now.
    local lines = {}
    if settings.paused then table.insert(lines, "recording is paused (/aj pause)") end

    -- Coming back into a dungeon after a reload, relog or disconnect either
    -- carries the run on or starts it over, which restarts the clock.
    local restore = self.lastRestore
    if restore and now - restore.at < 4 * 3600 then
        if restore.ok then
            table.insert(lines, string.format("%s ago you came back into the dungeon and the run carried on (%s since it was last saved)",
                FormatDuration(now - restore.at), FormatDuration(restore.gap)))
        else
            table.insert(lines, string.format("%s ago you came back into the dungeon and the run started over, because %s",
                FormatDuration(now - restore.at), restore.reason))
        end
    end

    local guid = self:GetGUIDForName(nameRealm)
    if guid then
        local runId = self:ActiveRunId()
        local since = self:RunSince(self.groupedSince[guid], runId)
        local gate = self:GetGateSeconds()
        if self:InRaidContext() then
            table.insert(lines, "you're in a raid, which never opens the note window")
        end
        if since then
            local together = now - since
            table.insert(lines, string.format("in your group for %s%s - the window needs %s%s",
                FormatDuration(together), runId and " in this dungeon" or "", FormatDuration(gate),
                together >= gate and " (met)" or ""))
        end
        local handled
        if runId then handled = IsHandled(self.handledReview, guid, runId) else handled = self.reviewQueued[guid] end
        if handled then
            table.insert(lines, runId and "already handled in this dungeon run" or "already handled since you grouped up")
        end
    else
        local snap = self.recentDepartures[nameRealm]
        if snap and snap.since and snap.groupedSeconds then
            table.insert(lines, string.format("not in your group - left %s ago, after %s together",
                FormatDuration(now - (snap.since + snap.groupedSeconds)), FormatDuration(snap.groupedSeconds)))
        else
            table.insert(lines, "not in your group")
        end
    end

    local askedKind, askedAt, askedUntil = self:AskedRecentlyInfo(nameRealm)
    if askedKind then
        table.insert(lines, string.format("won't be asked automatically for another %s (%s %s ago)",
            FormatDuration(askedUntil - now),
            askedKind == "note" and "you wrote a note" or "the window asked",
            FormatDuration(now - askedAt)))
    end

    local noteCount = #addon:GetReviewsForPlayer(nameRealm)
    if self:KnownWell(nameRealm) then
        table.insert(lines, string.format("you have %d notes on them, so they get a chat link instead of the window", noteCount))
    end

    local prompt = addon:GetModule("ReviewPrompt")
    if prompt.group and prompt.groupHidden then
        for _, member in ipairs(prompt.group) do
            if member.status == "pending" and member.data and member.data.nameRealm == nameRealm then
                table.insert(lines, "a note for them is waiting with the ones you put off - /aj notes")
                break
            end
        end
    end

    addon:Print("  Right now: " .. table.concat(lines, "; ") .. ".")
end
