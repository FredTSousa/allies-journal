local addon = AlliesJournal
local Notices = addon:NewModule("Notices", "AceEvent-3.0")

-- Two small reminders, both just chat lines and both switchable in the
-- options:
--  * someone you have a note on joins your group ("you've played with them")
--  * someone you noted as Great comes online
-- Everything here only reads your own journal; nothing is sent anywhere.

local JOIN_COOLDOWN = 600     -- seconds before the same person can trigger the join line again
local ONLINE_COOLDOWN = 1800  -- same, for the "is online" line
local NOTE_PREVIEW = 70       -- characters of your note shown in chat

Notices.online = {}      -- guid -> true/false, last online state seen in Recent Allies
Notices.lastShown = {}   -- "kind:nameRealm" -> GetTime() of the last line
Notices.quietUntil = 0   -- no join lines for a few seconds after a reload (everyone looks "new")

local LEVEL_COLORS = { good = "|cff40ff40", average = "|cffffd100", bad = "|cffff4040" }

local function Settings()
    return addon.db.global.settings.notices
end

local function ColoredName(shortName, classFile)
    local color = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if color and color.colorStr then return "|c" .. color.colorStr .. shortName .. "|r" end
    return "|cffffd100" .. shortName .. "|r"
end

-- "Great to play with, 3 sessions together - your note: friendly healer", or
-- nil when there's no note on this player. withoutNote leaves your own
-- words out (for a compact list).
function Notices:Describe(nameRealm, withoutNote)
    local review = addon:GetLatestReview(nameRealm)
    if not review then return nil end

    local axis = review.mode == "simple" and "simple" or "social"
    local word = (LEVEL_COLORS[review.social] or "|cffffffff") .. addon:RatingWord(axis, review.social) .. "|r"
    local text = word

    local record = addon.db.global.players[nameRealm]
    local sessions = record and record.sessions and #record.sessions or 0
    if sessions > 0 then
        text = text .. string.format(", %d session%s together", sessions, sessions == 1 and "" or "s")

        -- A long gap since the last time: "last together 45 days ago".
        local last
        for _, id in ipairs(record.sessions) do
            local session = addon.db.global.sessions[id]
            if session and session.date then last = math.max(last or 0, session.date) end
        end
        if last and time() - last >= 14 * 86400 then
            local days = math.floor((time() - last) / 86400)
            text = text .. ", last together " .. (days < 60 and (days .. " days ago") or (math.floor(days / 30) .. " months ago"))
        end
    end

    local note = strtrim(review.socialNote or "")
    if note == "" then note = strtrim(review.performanceNote or "") end
    if note ~= "" and not withoutNote and not addon:IsStreamerMode() then
        if #note > NOTE_PREVIEW then note = note:sub(1, NOTE_PREVIEW - 3) .. "..." end
        text = text .. " - your note: |cffdddddd" .. note .. "|r"
    end
    return text
end

-- An optional small panel listing the people you know who just joined, on
-- top of the chat lines. Gathered for a moment so a whole group shows as one.
Notices.panelLines = {}

function Notices:ShowJoinPanel()
    local lines = self.panelLines
    self.panelLines = {}
    self.panelTimer = nil
    if #lines == 0 then return end
    pcall(function()
        local frame = self.joinPanel
        if not frame then
            frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
            frame:SetWidth(320)
            frame:SetPoint("TOP", UIParent, "TOP", 0, -150)
            frame:SetFrameStrata("DIALOG")
            frame:SetBackdrop({ bgFile = "Interface/Tooltips/UI-Tooltip-Background",
                edgeFile = "Interface/Tooltips/UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 14,
                insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            frame:SetBackdropColor(0.05, 0.05, 0.05, 0.92)
            frame:EnableMouse(true)
            frame:SetScript("OnMouseUp", function(self) self:Hide() end)
            frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            frame.title:SetPoint("TOPLEFT", 10, -8)
            frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            frame.text:SetPoint("TOPLEFT", 10, -26)
            frame.text:SetWidth(300)
            frame.text:SetJustifyH("LEFT")
            self.joinPanel = frame
        end
        frame.title:SetText("Allies Journal - people you know")
        frame.text:SetText(table.concat(lines, "\n"))
        frame:SetHeight(36 + frame.text:GetStringHeight())
        frame:Show()
        local token = (frame.token or 0) + 1
        frame.token = token
        C_Timer.After(12, function() if frame.token == token then frame:Hide() end end)
    end)
end

function Notices:QueuePanelLine(text)
    if #self.panelLines >= 6 then return end
    table.insert(self.panelLines, text)
    if not self.panelTimer then
        self.panelTimer = true
        C_Timer.After(1.5, function() self:ShowJoinPanel() end)
    end
end

local function OnCooldown(self, kind, nameRealm, seconds)
    local key = kind .. ":" .. nameRealm
    local last = self.lastShown[key]
    if last and GetTime() - last < seconds then return true end
    self.lastShown[key] = GetTime()
    return false
end

-- Called by RosterTracker for someone who has just appeared in your group.
function Notices:PlayerJoined(nameRealm, classFile)
    local s = Settings()
    if not s or not s.joinNotice then return end
    if GetTime() < self.quietUntil then return end

    local description = self:Describe(nameRealm)
    if not description then return end
    if OnCooldown(self, "join", nameRealm, JOIN_COOLDOWN) then return end

    addon:Print(string.format("%s joined - %s", ColoredName(addon:GetShortName(nameRealm), classFile), description))
    if s.joinPanel then
        self:QueuePanelLine(string.format("%s - %s", ColoredName(addon:GetShortName(nameRealm), classFile),
            self:Describe(nameRealm, true) or description))
    end

    -- Optional louder warning for someone you marked Not for me.
    local review = addon:GetLatestReview(nameRealm)
    if s.warnBad and review and review.social == "bad" then
        local axis = review.mode == "simple" and "simple" or "social"
        pcall(function()
            UIErrorsFrame:AddMessage(string.format("Heads up: %s is in your group (you noted: %s)",
                addon:GetShortName(nameRealm), addon:RatingWord(axis, review.social)), 1, 0.3, 0.3, 1, 6)
            PlaySound((SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959)
        end)
    end
end

-- At the end of a dungeon: who in the group you already have a note on.
-- candidates is the same roster list RosterTracker uses for the prompts.
-- Said once per run, however many completion triggers fire.
Notices.facesShown = {}

function Notices:FamiliarFaces(candidates, runId)
    local s = Settings()
    if not s or not s.facesSummary or not runId or self.facesShown[runId] then return end

    local entries = {}
    for _, c in ipairs(candidates) do
        local nameRealm = c.data and c.data.nameRealm
        local description = nameRealm and self:Describe(nameRealm, true)
        if description then
            local okClass, _, classFile = pcall(GetPlayerInfoByGUID, c.guid)
            table.insert(entries, string.format("%s (%s)",
                ColoredName(addon:GetShortName(nameRealm), okClass and classFile or nil), description))
        end
    end
    if #entries == 0 then return end
    self.facesShown[runId] = true

    local shown = {}
    for i = 1, math.min(#entries, 6) do shown[i] = entries[i] end
    local line = "Familiar faces this run: " .. table.concat(shown, ", ")
    if #entries > 6 then line = line .. string.format(" and %d more", #entries - 6) end
    addon:Print(line)
end

-- At the end of a dungeon: a short recap of the run, from the counters
-- RosterTracker keeps while you are grouped. Said once per run; skipped for
-- very short visits.
Notices.recapShown = {}

local function RecapDuration(seconds)
    seconds = math.floor(seconds or 0)
    local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

function Notices:RunRecap(candidates, runId)
    local s = Settings()
    if not s or not s.runRecap or not runId or self.recapShown[runId] then return end
    local tracker = addon:GetModule("RosterTracker")
    local started = tracker.runStart[runId]
    if not started or #candidates == 0 then return end
    local seconds = time() - started
    if seconds < 240 then return end
    self.recapShown[runId] = true

    local tally = tracker:GetTally(candidates[1].guid, runId)
    local parts = { RecapDuration(seconds) }
    local function Add(count, one, many)
        if (count or 0) > 0 then table.insert(parts, count .. " " .. (count == 1 and one or many)) end
    end
    Add(tally.bosses, "boss", "bosses")
    Add(tally.mobs, "mob", "mobs")
    Add(tally.quests, "quest", "quests")
    if (tally.bosses or 0) > 0 and (tally.wipes or 0) == 0 then
        table.insert(parts, "no wipes")
    else
        Add(tally.wipes, "group wipe", "group wipes")
    end

    addon:Print(string.format("Run recap - %s with %d other%s: %s. |cff40ff40|Haddon:AlliesJournal:runs|h[Open runs]|h|r",
        tracker:PlaceName() or "the dungeon", #candidates, #candidates == 1 and "" or "s", table.concat(parts, ", ")))
end

----------------------------------------------------------------------
-- Coming online
----------------------------------------------------------------------

local function FindRecord(shortName)
    local lower = shortName and shortName:lower()
    if not lower then return nil end
    for nameRealm in pairs(addon.db.global.players) do
        local short = addon:GetShortName(nameRealm)
        if short and short:lower() == lower then return nameRealm end
    end
    return nil
end

-- Worth a heads-up: the latest note is Great and nothing on it is Not for me / Struggled.
local function IsGreat(review)
    return review and review.social == "good" and review.performance ~= "bad"
end

local function ClassFileOf(ally)
    local classID = ally.characterData and ally.characterData.classID
    if not classID or not GetClassInfo then return nil end
    local ok, _, classFile = pcall(GetClassInfo, classID)
    return ok and classFile or nil
end

-- Records everyone's current online state without saying anything, so the
-- first update after login isn't mistaken for a wave of people logging in.
function Notices:OnAlliesReady()
    if not C_RecentAllies then return end
    C_Timer.After(2, function() pcall(addon.SnapshotRecentAllies, addon) end)
    local ok, list = pcall(C_RecentAllies.GetRecentAllies)
    if not ok or type(list) ~= "table" then return end
    for _, ally in ipairs(list) do
        local guid = ally.characterData and ally.characterData.guid
        if guid and ally.stateData then
            self.online[guid] = ally.stateData.isOnline and true or false
        end
    end
end

function Notices:OnAllyUpdated(_, guid)
    -- Keep what Recent Allies knows about people in the journal (at most once a minute).
    if GetTime() - (self.lastSnapshot or 0) > 60 then
        self.lastSnapshot = GetTime()
        pcall(addon.SnapshotRecentAllies, addon)
    end
    local s = Settings()
    if not s or not s.onlineAlerts or not guid then return end

    local ok, ally = pcall(C_RecentAllies.GetRecentAllyByGUID, guid)
    if not ok or type(ally) ~= "table" or not ally.stateData or not ally.characterData then return end

    local online = ally.stateData.isOnline and true or false
    local was = self.online[guid]
    self.online[guid] = online

    -- Only a real offline -> online change counts (nil = never seen before).
    if not online or was ~= false then return end

    local fullName = ally.characterData.fullName
    local nameRealm = FindRecord(fullName)
    if not nameRealm or not IsGreat(addon:GetLatestReview(nameRealm)) then return end
    if OnCooldown(self, "online", nameRealm, ONLINE_COOLDOWN) then return end

    local description = self:Describe(nameRealm)
    addon:Print(string.format("%s is online%s", ColoredName(addon:GetShortName(nameRealm), ClassFileOf(ally)),
        description and (" - " .. description) or ""))
end

function Notices:OnEnable()
    pcall(function()
        self:RegisterEvent("RECENT_ALLIES_DATA_READY", "OnAlliesReady")
        self:RegisterEvent("RECENT_ALLY_DATA_UPDATED", "OnAllyUpdated")
    end)
    -- Already ready by the time this loads (e.g. after a /reload).
    C_Timer.After(3, function() self:OnAlliesReady() end)
end
