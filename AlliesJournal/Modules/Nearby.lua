local addon = AlliesJournal
local Nearby = addon:NewModule("Nearby", "AceEvent-3.0")

-- An opt-in memory of the players you pass in the open world, so that someone
-- you only decide to remember a few days later can still be added to the
-- journal. Off by default. Only friendly players, only outside instances, only
-- the open-world zone name and level/class/race - no chat, no positions - kept
-- for 7 days, at most 400 people, in its own saved table (not part of your
-- journal, a backup or an export).

local KEEP_SECONDS = 7 * 86400
local MAX_PEOPLE = 400
local THROTTLE = 60        -- seconds before the same person is looked at again
local NEW_MEETING = 600    -- seconds apart that count as seeing someone "again"

Nearby.lastLooked = {}

local function Store()
    AlliesJournalDB.nearby = AlliesJournalDB.nearby or {}
    return AlliesJournalDB.nearby
end

function Nearby:IsEnabled()
    local s = addon.db.global.settings.nearby
    return s and s.enabled and true or false
end

local function Readable(value)
    if value ~= nil and issecretvalue and issecretvalue(value) then return nil end
    return value
end

function Nearby:Observe(unit)
    if not self:IsEnabled() or not unit or (issecretvalue and issecretvalue(unit)) then return end
    if IsInInstance() then return end
    pcall(function()
        if not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") or not UnitIsFriend("player", unit) then return end
        local nameRealm = addon:GetFullName(unit)
        if not nameRealm or not Readable(nameRealm) then return end
        local now = GetTime()
        if self.lastLooked[nameRealm] and now - self.lastLooked[nameRealm] < THROTTLE then return end
        self.lastLooked[nameRealm] = now

        local store = Store()
        local entry = store[nameRealm]
        if not entry then
            entry = { first = time(), count = 0 }
            store[nameRealm] = entry
        end
        if time() - (entry.last or 0) > NEW_MEETING then entry.count = (entry.count or 0) + 1 end
        entry.last = time()
        entry.zone = Readable(GetRealZoneText()) or entry.zone

        local _, classFile = UnitClass(unit)
        if Readable(classFile) then entry.class = classFile end
        local level = Readable(UnitLevel(unit))
        if level and level > 0 then entry.level = level end
        local race = Readable(UnitRace(unit))
        if race then entry.race = race end
    end)
end

function Nearby:Prune()
    local store = Store()
    local cutoff = time() - KEEP_SECONDS
    local list = {}
    for nameRealm, entry in pairs(store) do
        if (entry.last or 0) < cutoff then
            store[nameRealm] = nil
        else
            list[#list + 1] = { nameRealm = nameRealm, last = entry.last or 0 }
        end
    end
    if #list > MAX_PEOPLE then
        table.sort(list, function(a, b) return a.last > b.last end)
        for i = MAX_PEOPLE + 1, #list do store[list[i].nameRealm] = nil end
    end
end

-- Newest first; people already in the journal are left out.
function Nearby:GetList()
    local list = {}
    for nameRealm, entry in pairs(Store()) do
        if not addon.db.global.players[nameRealm] then
            list[#list + 1] = { nameRealm = nameRealm, entry = entry }
        end
    end
    table.sort(list, function(a, b) return (a.entry.last or 0) > (b.entry.last or 0) end)
    return list
end

function Nearby:Clear()
    AlliesJournalDB.nearby = {}
end

function Nearby:OnEnable()
    pcall(self.RegisterEvent, self, "NAME_PLATE_UNIT_ADDED", function(_, unit) self:Observe(unit) end)
    pcall(self.RegisterEvent, self, "UPDATE_MOUSEOVER_UNIT", function() self:Observe("mouseover") end)
    pcall(self.RegisterEvent, self, "PLAYER_TARGET_CHANGED", function() self:Observe("target") end)
    C_Timer.After(5, function() pcall(self.Prune, self) end)
end
