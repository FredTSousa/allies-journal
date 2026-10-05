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
    end

    local note = strtrim(review.socialNote or "")
    if note == "" then note = strtrim(review.performanceNote or "") end
    if note ~= "" and not withoutNote then
        if #note > NOTE_PREVIEW then note = note:sub(1, NOTE_PREVIEW - 3) .. "..." end
        text = text .. " - your note: |cffdddddd" .. note .. "|r"
    end
    return text
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
