local addon = AlliesJournal
local Backup = addon:NewModule("Backup", "AceEvent-3.0")

-- A local safety copy of your journal: the notes, players, sessions and run
-- notes (not the settings) are copied inside the saved variables about every
-- 12 hours, keeping the last three. It never leaves your computer and is not
-- part of an export. Restoring is only ever done from the options window, after
-- a confirmation, and saves the current journal as a backup first.
--
-- If the journal suddenly holds far less than the newest backup, no new backup
-- is taken (so a good one isn't pushed out) and a line in chat says so.

local MAX_BACKUPS = 3
local MIN_INTERVAL = 12 * 3600   -- seconds between automatic backups
local LOSS_RATIO = 0.5           -- less than this share of the newest backup counts as lost data
local KEYS = { "players", "reviews", "sessions", "runNotes" }

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = DeepCopy(v) end
    return copy
end

local function Counts(source)
    local players, sessions, notes = 0, 0, 0
    for _ in pairs(source.players or {}) do players = players + 1 end
    for _ in pairs(source.sessions or {}) do sessions = sessions + 1 end
    for _ in pairs(source.reviews or {}) do notes = notes + 1 end
    return { players = players, sessions = sessions, notes = notes }
end

local function Weight(counts)
    return counts.players + counts.sessions + counts.notes
end

-- Newest first.
function Backup:List()
    local db = AlliesJournalDB
    if type(db.backups) ~= "table" then db.backups = {} end
    return db.backups
end

function Backup:Describe(entry)
    local c = entry.counts or {}
    return string.format("%s  -  %d players, %d sessions, %d notes (%s)",
        date("%Y-%m-%d %H:%M", entry.savedAt or 0), c.players or 0, c.sessions or 0, c.notes or 0,
        entry.reason or "automatic")
end

function Backup:Snapshot(reason)
    local g = addon.db.global
    local data = {}
    for _, key in ipairs(KEYS) do data[key] = DeepCopy(g[key] or {}) end
    -- Demo people are never part of a backup.
    for nameRealm, rec in pairs(data.players) do
        if rec.demo then
            for _, id in ipairs(rec.reviews or {}) do data.reviews[id] = nil end
            for _, id in ipairs(rec.sessions or {}) do data.sessions[id] = nil end
            data.players[nameRealm] = nil
        end
    end
    local entry = { savedAt = time(), reason = reason or "automatic", counts = Counts(data), data = data }
    local list = self:List()
    table.insert(list, 1, entry)
    while #list > MAX_BACKUPS do table.remove(list) end
    return entry
end

-- Takes a backup if one is due. Called a few seconds after login and then
-- hourly (it does nothing until 12 hours have passed).
function Backup:RunAutomatic()
    local settings = addon.db.global.settings.backup
    if not settings or not settings.enabled then return end

    local now = Counts(addon.db.global)
    if Weight(now) == 0 then return end  -- never back up an empty journal

    local list = self:List()
    local newest = list[1]
    if newest then
        if Weight(now) < Weight(newest.counts or { players = 0, sessions = 0, notes = 0 }) * LOSS_RATIO then
            if not self.warnedLoss then
                self.warnedLoss = true
                addon:Print("Your journal holds a lot less than your last backup. If that is not expected, open /aj options and restore a backup from the General tab.")
            end
            return
        end
        if time() - (newest.savedAt or 0) < MIN_INTERVAL then return end
    end
    self:Snapshot("automatic")
end

-- Replaces the journal with a backup. The journal as it is now is kept as a
-- new backup first, so a restore can be undone.
function Backup:Restore(index)
    local list = self:List()
    local entry = list[index]
    if not entry or type(entry.data) ~= "table" then return false end

    if Weight(Counts(addon.db.global)) > 0 then self:Snapshot("before restore") end

    local g = addon.db.global
    for _, key in ipairs(KEYS) do g[key] = DeepCopy(entry.data[key] or {}) end

    pcall(function() addon:GetModule("Tooltip"):RefreshFramesSoon() end)
    pcall(function() addon:GetModule("Browser"):RefreshIfShown() end)
    return true
end

StaticPopupDialogs["ALLIESJOURNAL_RESTORE_BACKUP"] = {
    text = "Replace your whole journal with this backup?\n\n%s\n\nYour journal as it is now is saved as a backup first.",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data)
        if addon:GetModule("Backup"):Restore(data.index) then
            addon:Print("Restored your journal from the backup. Type /reload to be sure everything is refreshed.")
        end
        pcall(function() addon:GetModule("Options"):Show() end)
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function Backup:OnEnable()
    -- Demo people last until you log out (or reload).
    self:RegisterEvent("PLAYER_LOGOUT", function() pcall(addon.SetDemo, addon, false) end)
    C_Timer.After(1, function() pcall(addon.SetDemo, addon, false) end)
    C_Timer.After(10, function() self:RunAutomatic() end)
    C_Timer.NewTicker(3600, function() self:RunAutomatic() end)
end
