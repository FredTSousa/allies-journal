local addon = PlayerReview
local ReviewCapture = addon:NewModule("ReviewCapture", "AceEvent-3.0")

-- guid -> { {duration=, dps=, hps=, interrupts=, dispels=, deaths=}, ... }
-- One entry per completed fight (PLAYER_REGEN_DISABLED -> ENABLED cycle)
-- while grouped with that guid - NOT a single overwritten snapshot. A
-- dungeon run has many separate fights; capturing "Current" (the one
-- fight that just ended) into a flat per-guid value would silently lose
-- every earlier fight's numbers each time a new one ends. Kept in memory
-- only until AggregateFights consumes them (a session records an
-- automatic aggregate of ALL fights; a review lets the user pick a
-- subset via a checklist, defaulting to all).
ReviewCapture.fights = {}
ReviewCapture.cycleCounter = 0

-- guid -> cumulative seconds spent in combat while grouped with that guid,
-- across the whole time they've been in the roster (not per-encounter) -
-- feeds the session-eligibility gate in RosterTracker, which requires
-- BOTH a minimum grouped time AND a minimum combat time before a session
-- gets recorded, to exclude non-combat grouping and trivial world
-- mob-tagging. Kept separate from fight duration (rather than summed from
-- the fights list) since it's read/reset on a different lifecycle.
ReviewCapture.combatSeconds = {}

local ROLE_MAP = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }

function ReviewCapture:OnEnable()
    self:RegisterEvent("PLAYER_REGEN_DISABLED", "OnCombatStart")
    self:RegisterEvent("PLAYER_REGEN_ENABLED", "OnCombatEnd")
end

function ReviewCapture:OnCombatStart()
    self.combatStartTime = time()
end

-- Snapshot on every PLAYER_REGEN_ENABLED. "Current" (the single fight
-- that just ended) is what the in-game meter UI shows and is confirmed
-- working via /pr capturedebug; "Overall" was tried first but reads a
-- much longer/differently-scoped cumulative window that didn't reliably
-- include the exact people just fought alongside. A read OUTSIDE this
-- handler returns secret values; do not defer this with C_Timer.After or
-- move it to a later event.
function ReviewCapture:OnCombatEnd()
    -- No matching start (e.g. a /reload mid-fight): nothing trustworthy to
    -- measure, rather than reusing the previous fight's start time.
    if not self.combatStartTime then return end
    local elapsed = time() - self.combatStartTime
    self.combatStartTime = nil
    if elapsed <= 0 then return end
    -- One id per combat, shared by every player's fight entry from it, so
    -- a saved run can store each fight's shared data once (ExportRun).
    self.cycleCounter = self.cycleCounter + 1

    if self.debug then
        local roster = addon:GetModule("RosterTracker").roster
        local parts = {}
        for guid, info in pairs(roster) do
            table.insert(parts, info.nameRealm .. "=" .. guid)
        end
        addon:Print("[capture debug] current roster: " .. (#parts > 0 and table.concat(parts, ", ") or "(empty)"))
    end

    local sessionType = Enum.DamageMeterSessionType and
        (Enum.DamageMeterSessionType.Current or Enum.DamageMeterSessionType.Overall)
    if self.debug then
        addon:Print(string.format("[capture debug] session type: %s (%s)", tostring(sessionType),
            (Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Current == sessionType) and "Current" or "Overall fallback"))
    end

    -- guid -> { dps=, hps= } for THIS fight only, filled in by the two
    -- CaptureSessionType calls below before being pushed as one fight
    -- entry per guid. Covers EVERY source in the fight, not just grouped
    -- players - that's what makes the group-relative stats below possible
    -- without any extra API calls.
    local perGuid = {}
    self:CaptureSessionType(sessionType, Enum.DamageMeterType and Enum.DamageMeterType.Dps, "dps", "amountPerSecond", perGuid)
    self:CaptureSessionType(sessionType, Enum.DamageMeterType and Enum.DamageMeterType.Hps, "hps", "amountPerSecond", perGuid)
    -- Interrupts/dispels/deaths would extend this same read pattern -
    -- confirmed via the documented Enum.DamageMeterType that Interrupts
    -- (5), Dispels (6), and Deaths (9) values exist, so this is no
    -- longer blocked on an unknown API - just not implemented yet.

    local fightName = self:GetFightName(sessionType)

    local roster = addon:GetModule("RosterTracker").roster

    -- Group-relative stats (rank + the group's top performer) computed
    -- from the same perGuid data, restricted to the current group
    -- (roster + yourself) - lets a review show "2nd of 4, top was 62
    -- DPS" instead of a bare number with nothing to compare it to.
    local playerGUID = UnitGUID("player")
    local groupGuids = { [playerGUID] = true }
    for guid in pairs(roster) do groupGuids[guid] = true end

    local function AddRankFields(fieldKey, rankKey, maxKey, countKey, totalKey)
        local values = {}
        for guid in pairs(groupGuids) do
            local entry = perGuid[guid]
            if entry and entry[fieldKey] then
                table.insert(values, entry[fieldKey])
            end
        end
        if #values == 0 then return end
        table.sort(values, function(a, b) return a > b end)

        local total = 0
        for _, v in ipairs(values) do total = total + v end

        for guid in pairs(groupGuids) do
            local entry = perGuid[guid]
            if entry and entry[fieldKey] then
                for i, v in ipairs(values) do
                    if v == entry[fieldKey] then
                        entry[rankKey] = i
                        break
                    end
                end
                entry[maxKey] = values[1]
                entry[countKey] = #values
                entry[totalKey] = total
            end
        end
    end

    AddRankFields("dps", "dpsRank", "groupMaxDps", "groupDpsCount", "groupTotalDps")
    AddRankFields("hps", "hpsRank", "groupMaxHps", "groupHpsCount", "groupTotalHps")

    -- Every group member's own dps/hps for THIS fight, sorted highest
    -- first - lets the review prompt draw a bar per member with whoever's
    -- being reviewed highlighted, not just a single relative number. Not
    -- persisted to SavedVariables (only used live while the prompt is
    -- open) - see ReviewPrompt's chart, and AggregateFights below for how
    -- multiple fights' breakdowns combine.
    local groupBreakdown = {}
    for guid in pairs(groupGuids) do
        local entry = perGuid[guid]
        if entry and entry.dps then
            local nameRealm = (guid == playerGUID) and addon:GetPlayerName() or (roster[guid] and roster[guid].nameRealm)
            if nameRealm then
                local role
                local class
                if guid == playerGUID then
                    role = self:GetRole("player")
                    class = select(2, UnitClass("player"))
                else
                    role = roster[guid] and roster[guid].role
                    -- GUID-based, no live unit token needed - works even
                    -- for someone who's already left the group by the
                    -- time this reads, as long as the client has cached
                    -- their info (true for anyone recently grouped with).
                    local ok, _, englishClass = pcall(GetPlayerInfoByGUID, guid)
                    if ok then class = englishClass end
                end
                table.insert(groupBreakdown, { guid = guid, nameRealm = nameRealm, dps = entry.dps, hps = entry.hps, role = role, class = class })
            end
        end
    end
    table.sort(groupBreakdown, function(a, b) return (a.dps or 0) > (b.dps or 0) end)

    -- Credits this fight to every guid CURRENTLY in the roster (the live
    -- grouped set at combat-end time) - simple and good enough for the
    -- session gate's purposes; doesn't try to account for someone
    -- joining/leaving mid-fight.
    for guid in pairs(roster) do
        self.combatSeconds[guid] = (self.combatSeconds[guid] or 0) + elapsed

        local fight = perGuid[guid] or {}
        fight.duration = elapsed
        -- Which dungeon run this belongs to (nil outside any dungeon), so
        -- a review or session only ever counts its own run's fights.
        fight.run = addon:GetModule("RosterTracker").currentRunId
        fight.cycle = self.cycleCounter
        fight.groupBreakdown = groupBreakdown  -- shared reference across every guid's fight entry this cycle - read-only after creation, so safe
        fight.name = fightName
        self.fights[guid] = self.fights[guid] or {}
        table.insert(self.fights[guid], fight)
    end
end

-- Infers a human-readable name for this fight: the enemy that took the
-- most damage is the boss/main target almost every time. The documented
-- DamageMeterCombatSession has no encounter-name field of its own (only
-- combatSources/maxAmount/totalAmount/durationSeconds), so this is
-- inferred from the sources instead.
--
-- EnemyDamageTaken ("damage done TO enemies") is the right meter type
-- for that. DamageTaken, tried first originally, ranks the PLAYERS who
-- took damage, so no enemy ever appeared in it and every fight stayed
-- unnamed - it's kept only as a fallback in case a client lacks the newer
-- type. Sources in an enemy session are enemies unless explicitly tagged
-- Ally (sourceDisplayType), and the local player is always excluded.
local function PickTopEnemyName(self, sessionType, meterType, label, strict)
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, meterType)
    if not ok or not session or issecretvalue(session) then
        if self.debug then
            addon:Print(string.format("[capture debug] fight name (%s): GetCombatSessionFromType ok=%s session=%s",
                label, tostring(ok), tostring(session)))
        end
        return nil
    end

    local sources = session.combatSources
    if not sources or issecretvalue(sources) then
        if self.debug then addon:Print("[capture debug] fight name (" .. label .. "): combatSources missing or secret") end
        return nil
    end

    local displayTypes = Enum.DamageMeterSourceDisplayType
    local enemyType = displayTypes and displayTypes.Enemy
    local allyType = displayTypes and displayTypes.Ally
    local bestName, bestAmount = nil, 0

    for _, src in ipairs(sources) do
        if not issecretvalue(src) then
            local isEnemy
            if strict and enemyType then
                isEnemy = src.sourceDisplayType == enemyType
            else
                isEnemy = not src.isLocalPlayer and not (allyType and src.sourceDisplayType == allyType)
            end

            local amount, name = src.totalAmount, src.name
            if isEnemy and name and not issecretvalue(name) and amount and not issecretvalue(amount) and amount > bestAmount then
                bestName, bestAmount = name, amount
            end
        end
    end

    if self.debug then
        addon:Print(string.format("[capture debug] fight name (%s): %s (%s) from %d source(s)",
            label, tostring(bestName), tostring(bestAmount), #sources))
    end
    return bestName
end

function ReviewCapture:GetFightName(sessionType)
    local types = Enum.DamageMeterType
    if not types then return nil end

    if types.EnemyDamageTaken then
        local name = PickTopEnemyName(self, sessionType, types.EnemyDamageTaken, "EnemyDamageTaken", false)
        if name then return name end
    elseif self.debug then
        addon:Print("[capture debug] fight name: Enum.DamageMeterType.EnemyDamageTaken missing on this client")
    end

    if types.DamageTaken then
        return PickTopEnemyName(self, sessionType, types.DamageTaken, "DamageTaken", true)
    end
    return nil
end

-- perGuid accumulates this fight's dps/hps per source guid across both
-- calls (dps then hps) before OnCombatEnd pushes one combined fight entry.
function ReviewCapture:CaptureSessionType(sessionType, damageMeterType, field, valueKey, perGuid)
    if not damageMeterType then
        if self.debug then addon:Print(string.format("[capture debug] %s: damageMeterType is nil (Enum.DamageMeterType missing that field on this client)", field)) end
        return
    end

    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, damageMeterType)
    if not ok or not session or issecretvalue(session) then
        if self.debug then
            addon:Print(string.format("[capture debug] %s: GetCombatSessionFromType ok=%s session=%s%s",
                field, tostring(ok), tostring(session),
                (session and issecretvalue(session)) and " (secret)" or ""))
        end
        return
    end

    local sources = session.combatSources
    if not sources or issecretvalue(sources) then
        if self.debug then addon:Print(string.format("[capture debug] %s: combatSources missing or secret", field)) end
        return
    end

    if self.debug then
        addon:Print(string.format("[capture debug] %s: %d source(s) in session", field, #sources))
        -- Checking for an encounter/segment name on the session object
        -- itself (separate from combatSources) - Blizzard's own meter UI
        -- clearly labels segments by mob name ("Elder Mottled Boar"), so
        -- that data exists somewhere; this checks whether it's exposed
        -- here rather than needing combat-log parsing to get it.
        local sessionFields = {}
        for k, v in pairs(session) do
            if k ~= "combatSources" and not issecretvalue(v) then
                table.insert(sessionFields, tostring(k) .. "=" .. tostring(v))
            end
        end
        addon:Print(string.format("[capture debug] %s: session's own fields: {%s}", field, table.concat(sessionFields, ", ")))
    end

    local roster = self.debug and addon:GetModule("RosterTracker").roster or nil

    for _, src in ipairs(sources) do
        local guid = src.sourceGUID
        if guid and not issecretvalue(guid) then
            if self.debug then
                local rosterInfo = roster[guid]
                local fieldParts = {}
                for k, v in pairs(src) do
                    if not issecretvalue(v) then
                        table.insert(fieldParts, tostring(k) .. "=" .. tostring(v))
                    end
                end
                addon:Print(string.format("[capture debug]   guid=%s%s  {%s}", tostring(guid),
                    rosterInfo and (" -> " .. rosterInfo.nameRealm .. " (IN ROSTER)") or " (not in current roster)",
                    table.concat(fieldParts, ", ")))
            end
            local value = src[valueKey]
            if value ~= nil and not issecretvalue(value) then
                perGuid[guid] = perGuid[guid] or {}
                perGuid[guid][field] = value
            end
        elseif self.debug then
            addon:Print("[capture debug]   a source's guid is missing or secret")
        end
    end
end

-- Dumps currently-held capture state (not just newly-logged events) into
-- a copyable window, so what's already been accumulated this session can
-- be inspected without waiting for a fresh fight.
function ReviewCapture:DumpState()
    local lines = { "-- EntryCapture.fights (guid -> fight list) --" }
    for guid, fights in pairs(self.fights) do
        for i, fight in ipairs(fights) do
            table.insert(lines, string.format("%s fight[%d]: duration=%s dps=%s hps=%s",
                guid, i, tostring(fight.duration), tostring(fight.dps), tostring(fight.hps)))
        end
    end
    table.insert(lines, "")
    table.insert(lines, "-- EntryCapture.combatSeconds (guid -> seconds) --")
    for guid, seconds in pairs(self.combatSeconds) do
        table.insert(lines, string.format("%s: %ss", guid, tostring(seconds)))
    end
    addon:GetModule("Export"):ShowText("ReviewCapture Debug", table.concat(lines, "\n"))
end

-- Seconds this guid has spent in combat with us during one run (see
-- RosterTracker's run ids): a dungeon run's own fights, or - with a nil
-- runId - the fights outside any dungeon. Summed from the recorded fights
-- so each run is measured on its own.
function ReviewCapture:GetCombatSeconds(guid, runId)
    local total = 0
    for _, fight in ipairs(self:GetRunFights(guid, runId)) do
        total = total + (fight.duration or 0)
    end
    return total
end

-- A dungeon run's fights in a form that can be saved across a /reload:
-- a list of fights (one per combat), each holding its shared data once
-- (duration, name, the group breakdown) and every player's own numbers
-- under perGuid. A fight is otherwise stored once per player with the
-- same breakdown repeated, which would make the saved file far bigger.
function ReviewCapture:ExportRun(runId)
    local cycles, byId = {}, {}
    for guid, list in pairs(self.fights) do
        for _, fight in ipairs(list) do
            if fight.run == runId and fight.cycle then
                local c = byId[fight.cycle]
                if not c then
                    c = { id = fight.cycle, duration = fight.duration, name = fight.name,
                          breakdown = fight.groupBreakdown, perGuid = {} }
                    byId[fight.cycle] = c
                    table.insert(cycles, c)
                end
                local entry = {}
                for k, v in pairs(fight) do
                    if k ~= "groupBreakdown" and k ~= "duration" and k ~= "name" and k ~= "run" and k ~= "cycle" then
                        entry[k] = v
                    end
                end
                c.perGuid[guid] = entry
            end
        end
    end
    table.sort(cycles, function(a, b) return a.id < b.id end)
    return cycles
end

-- Puts an ExportRun list back as per-player fights, tagged with runId.
function ReviewCapture:ImportRun(cycles, runId)
    for _, c in ipairs(cycles) do
        for guid, entry in pairs(c.perGuid or {}) do
            local fight = {}
            for k, v in pairs(entry) do fight[k] = v end
            fight.duration, fight.name, fight.run, fight.cycle = c.duration, c.name, runId, c.id
            fight.groupBreakdown = c.breakdown  -- one shared table again
            self.fights[guid] = self.fights[guid] or {}
            table.insert(self.fights[guid], fight)
        end
        if c.id and c.id > self.cycleCounter then self.cycleCounter = c.id end
    end
end

-- The fights recorded for this guid during one run: fights tagged with
-- that run id, or with a nil runId the ones recorded outside any dungeon.
-- (GetFights below returns everything, for the manual /pr queue.)
function ReviewCapture:GetRunFights(guid, runId)
    local result = {}
    for _, fight in ipairs(self.fights[guid] or {}) do
        if fight.run == runId then table.insert(result, fight) end
    end
    return result
end

-- Called once a session's been recorded for this guid (or once it's
-- clear no session will be, e.g. the player left before either gate
-- cleared) so combat time doesn't keep accumulating across what should
-- be separate future sessions with the same person.
function ReviewCapture:ClearCombatSeconds(guid)
    self.combatSeconds[guid] = nil
end

function ReviewCapture:GetFights(guid)
    return self.fights[guid] or {}
end

-- Called once fights are no longer needed - after a review has consumed
-- them into its own aggregate, or once it's clear no review is coming
-- and the auto-recorded session already has its own aggregate. Same
-- lifecycle as ClearCombatSeconds: a future regrouping starts fresh.
function ReviewCapture:ClearFights(guid)
    self.fights[guid] = nil
end

-- Dumps whatever's been captured so far for `unit` (default target) into
-- a copyable window, in a shape /pr capturereplay can load straight back
-- into a review prompt later - so a REAL captured scenario (actual DPS
-- numbers, actual group members) can be tested against the UI repeatedly
-- without regrouping with anyone each time.
function ReviewCapture:SaveFightsForReplay(unit)
    unit = (unit and unit ~= "") and unit or "target"
    if not UnitExists(unit) then
        addon:Print("No such unit: " .. unit)
        return
    end

    local guid = UnitGUID(unit)
    local fights = guid and self:GetFights(guid) or {}
    if #fights == 0 then
        addon:Print("No fight data captured yet for " .. unit .. " - fight something together first, then try again.")
        return
    end

    local data = {
        nameRealm = addon:GetFullName(unit),
        role = self:GetRole(unit),
        fights = fights,
    }
    addon:GetModule("Export"):ShowText("Saved Fight Data (for /aj capturereplay)", "return " .. addon:Serialize(data))
end

-- Collapses a subset of `fights` (an explicit list - pass self:GetFights
-- (guid) for the live list, or a snapshot already taken elsewhere, e.g.
-- ReviewPrompt's queued data.fights) into the single compact summary line
-- a session or review actually stores - duration-weighted average for
-- rate metrics (dps/hps), plain sums for count metrics (interrupts/
-- dispels/deaths, currently always nil per fight until their capture path
-- is confirmed - summed only when present, so this degrades to nil
-- rather than a misleading 0). selectedIndices (default: all of them)
-- lets a review include only a user-picked subset of fights.
function ReviewCapture:AggregateFights(fights, selectedIndices)
    fights = fights or {}
    local totalDuration, dpsWeighted, hpsWeighted = 0, 0, 0
    local groupTotalDpsWeighted, groupTotalHpsWeighted = 0, 0
    local interrupts, dispels, deaths
    -- nameRealm -> { guid=, dpsWeighted=, hpsWeighted=, duration= } - a
    -- member's own duration total (not the fight's overall duration),
    -- since someone can appear in some selected fights and not others.
    local breakdownTotals = {}

    local function ConsiderFight(fight)
        local duration = fight.duration or 0
        totalDuration = totalDuration + duration
        if fight.dps then dpsWeighted = dpsWeighted + fight.dps * duration end
        if fight.hps then hpsWeighted = hpsWeighted + fight.hps * duration end
        if fight.groupTotalDps then groupTotalDpsWeighted = groupTotalDpsWeighted + fight.groupTotalDps * duration end
        if fight.groupTotalHps then groupTotalHpsWeighted = groupTotalHpsWeighted + fight.groupTotalHps * duration end
        if fight.interrupts then interrupts = (interrupts or 0) + fight.interrupts end
        if fight.dispels then dispels = (dispels or 0) + fight.dispels end
        if fight.deaths then deaths = (deaths or 0) + fight.deaths end

        if fight.groupBreakdown then
            for _, member in ipairs(fight.groupBreakdown) do
                local t = breakdownTotals[member.nameRealm]
                if not t then
                    t = { guid = member.guid, nameRealm = member.nameRealm, dpsWeighted = 0, hpsWeighted = 0, duration = 0 }
                    breakdownTotals[member.nameRealm] = t
                end
                if member.dps then t.dpsWeighted = t.dpsWeighted + member.dps * duration end
                if member.hps then t.hpsWeighted = t.hpsWeighted + member.hps * duration end
                t.duration = t.duration + duration
                -- Static per-member info (doesn't change fight to fight) -
                -- take it from whichever fight happens to have it first.
                t.class = t.class or member.class
                t.role = t.role or member.role
            end
        end
    end

    if selectedIndices then
        for _, i in ipairs(selectedIndices) do
            if fights[i] then ConsiderFight(fights[i]) end
        end
    else
        for _, fight in ipairs(fights) do ConsiderFight(fight) end
    end

    local groupBreakdown = {}
    for _, t in pairs(breakdownTotals) do
        table.insert(groupBreakdown, {
            guid = t.guid,
            nameRealm = t.nameRealm,
            dps = t.duration > 0 and (t.dpsWeighted / t.duration) or nil,
            hps = t.duration > 0 and (t.hpsWeighted / t.duration) or nil,
            class = t.class,
            role = t.role,
        })
    end
    table.sort(groupBreakdown, function(a, b) return (a.dps or 0) > (b.dps or 0) end)

    -- "Group's best" has to be the highest of the SAME per-member
    -- aggregate numbers shown in groupBreakdown (each member's own
    -- duration-weighted average across these exact selected fights) -
    -- not a duration-weighted average of each fight's own top performer,
    -- which can silently be a different person fight to fight and drift
    -- above every individual member's aggregate, even the actual best
    -- one (e.g. reporting "92% of group's best" for the player who is,
    -- by this same breakdown, actually #1).
    local groupMaxDps, groupMaxHps
    for _, m in ipairs(groupBreakdown) do
        if m.dps and (not groupMaxDps or m.dps > groupMaxDps) then groupMaxDps = m.dps end
        if m.hps and (not groupMaxHps or m.hps > groupMaxHps) then groupMaxHps = m.hps end
    end

    return {
        dps = totalDuration > 0 and (dpsWeighted / totalDuration) or nil,
        hps = totalDuration > 0 and (hpsWeighted / totalDuration) or nil,
        groupMaxDps = groupMaxDps,
        groupMaxHps = groupMaxHps,
        groupTotalDps = totalDuration > 0 and (groupTotalDpsWeighted / totalDuration) or nil,
        groupTotalHps = totalDuration > 0 and (groupTotalHpsWeighted / totalDuration) or nil,
        groupBreakdown = groupBreakdown,
        interrupts = interrupts,
        dispels = dispels,
        deaths = deaths,
    }
end

-- Guarded role read, safe to call any time - but per the design doc this
-- should be called synchronously at the moment it's needed (roster update,
-- or review-prompt open), never deferred. UnitGroupRolesAssigned is
-- confirmed secret in arena/LFR; unconfirmed for ordinary dungeon parties,
-- so callers must keep the manual role picker as a fallback.
function ReviewCapture:GetRole(unit)
    local ok, role = pcall(UnitGroupRolesAssigned, unit)
    if not ok or not role or issecretvalue(role) then return nil end
    return ROLE_MAP[role]
end
