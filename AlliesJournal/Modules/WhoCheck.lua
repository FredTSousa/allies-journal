local addon = AlliesJournal
local WhoCheck = addon:NewModule("WhoCheck", "AceEvent-3.0")

-- Checks, with /who, whether players that Recent Allies has no entry for
-- are online right now, and picks up their level, class and location while
-- it's at it.
--
-- SendWho is a protected function: the client only lets an addon call it
-- from a real click (a hardware event), never from a timer or an event
-- handler. So this can't run itself in the background - every name needs
-- its own click on the list's Check Status button, which sends the next
-- name in the queue. The server also throttles /who, so clicks closer
-- together than QUERY_GAP are refused here instead of being silently dropped.

local QUERY_GAP = 5      -- seconds between queries
local REPLY_TIMEOUT = 6  -- seconds to wait for one reply

-- nameRealm -> { online = bool, level, classFile, area, checked = time() }
-- Runtime only; the durable part (level/class) is copied onto the player's
-- record as `who` whenever they're found.
WhoCheck.status = {}

local function SetWhoToUi(state)
    if C_FriendList and C_FriendList.SetWhoToUi then pcall(C_FriendList.SetWhoToUi, state) end
end

local function ClassIDFromFile(classFile)
    if not classFile or not GetNumClasses or not GetClassInfo then return nil end
    for i = 1, GetNumClasses() do
        local _, file, id = GetClassInfo(i)
        if file == classFile then return id or i end
    end
    return nil
end

-- Looks like a Recent Allies entry (characterData/stateData) so the player
-- list can treat both the same way. nil when we know nothing about them.
function WhoCheck:GetPseudoAlly(nameRealm)
    local status = self.status[nameRealm]
    local record = addon.db.global.players[nameRealm]
    local saved = record and record.who
    if not status and not saved then return nil end

    local level = (status and status.level) or (saved and saved.level)
    local classFile = (status and status.classFile) or (saved and saved.classFile)
    return {
        fromWho = true,
        characterData = { level = level, classID = ClassIDFromFile(classFile) },
        stateData = {
            isOnline = status and status.online or false,
            currentLocation = status and status.online and status.area or nil,
        },
    }
end

-- What the button says and whether it can be clicked right now:
--   no check running      "Check Not Recent"
--   waiting for a reply   "Checking <name> (2/5)"      (greyed out)
--   cooling down          "Wait 3s - <name> next (3/5)" (greyed out, counts down)
--   ready for the next    "Check <name> (3/5)"
-- The wait is the server's /who throttle, so the count is how long until the
-- next click will be accepted.
function WhoCheck:ButtonState()
    if not self.queue then return "Check Not Recent", false end
    local done = self.total - #self.queue - (self.pending and 1 or 0)
    local position = string.format("(%d/%d)", done + 1, self.total)

    if self.pending then
        return string.format("Checking %s %s", addon:GetShortName(self.pending), position), true
    end

    local nextName = self.queue[1] and addon:GetShortName(self.queue[1]) or "next"
    local wait = math.ceil(QUERY_GAP - (GetTime() - (self.lastSent or -QUERY_GAP)))
    if wait > 0 then
        return string.format("Wait %ds - %s %s", wait, nextName, position), true
    end
    return string.format("Check %s %s", nextName, position), false
end

function WhoCheck:ButtonText()
    return (self:ButtonState())
end

-- Who's been checked and who's left, for the button's tooltip. Names are
-- colored by result: green online, gray not found, white still to check.
function WhoCheck:ProgressLines()
    if not self.queue then return nil end
    local lines = {}
    for nameRealm, status in pairs(self.checkedThisRun or {}) do
        local color = status and "|cff40ff40" or "|cff909090"
        table.insert(lines, color .. addon:GetShortName(nameRealm) .. (status and " - online" or " - not found") .. "|r")
    end
    table.sort(lines)
    if self.pending then
        table.insert(lines, "|cffffd100" .. addon:GetShortName(self.pending) .. " - waiting for reply...|r")
    end
    for _, nameRealm in ipairs(self.queue) do
        table.insert(lines, addon:GetShortName(nameRealm))
    end
    return lines
end

-- Called from the button's click. names: the "Name-Realm" list to check,
-- used only when no check is in progress.
function WhoCheck:Click(names)
    if self.pending then
        addon:Print("Still waiting for the last /who reply...")
        return
    end

    if not self.queue then
        if not names or #names == 0 then
            addon:Print("Everyone listed is already in Recent Allies - nothing to check.")
            return
        end
        self.queue = {}
        for _, nameRealm in ipairs(names) do table.insert(self.queue, nameRealm) end
        self.total = #names
        self.found = 0
        self.checkedThisRun = {}
        self:RegisterEvent("WHO_LIST_UPDATE", "OnWhoListUpdate")
        addon:Print(string.format("Checking %d player(s) that aren't in Recent Allies, using /who - click the button once per player (it counts down).", self.total))
        -- Keeps the button's countdown moving between clicks.
        self.ticker = C_Timer.NewTicker(0.5, function()
            addon:GetModule("Browser"):UpdateWhoButton()
        end)
    end

    local wait = QUERY_GAP - (GetTime() - (self.lastSent or -QUERY_GAP))
    if wait > 0 then
        addon:Print(string.format("/who is throttled - click again in %d second(s).", math.ceil(wait)))
        return
    end

    self:SendNext()
end

function WhoCheck:Finish()
    self:UnregisterEvent("WHO_LIST_UPDATE")
    SetWhoToUi(false)
    addon:Print(string.format("/who check done: %d of %d online.", self.found or 0, self.total or 0))
    if self.ticker then self.ticker:Cancel() self.ticker = nil end
    self.queue, self.pending, self.pendingToken = nil, nil, nil
    addon:GetModule("Browser"):UpdateWhoButton()
end

function WhoCheck:SendNext()
    local nameRealm = table.remove(self.queue, 1)
    if not nameRealm then
        self:Finish()
        return
    end

    self.pending = nameRealm
    self.lastSent = GetTime()
    local token = {}
    self.pendingToken = token

    -- Keep this reply out of chat (it's read directly); put back as soon as
    -- it resolves, so an abandoned check never leaves it changed.
    SetWhoToUi(true)
    local ok = pcall(function()
        if C_FriendList and C_FriendList.SendWho then
            C_FriendList.SendWho(addon:GetShortName(nameRealm))
        else
            SendWho(addon:GetShortName(nameRealm))
        end
    end)
    if not ok then
        addon:Print("Couldn't run /who on this client.")
        self.queue = {}
        self.pending, self.pendingToken = nil, nil
        self:Finish()
        return
    end

    -- No matching reply in time: count it as not found.
    C_Timer.After(REPLY_TIMEOUT, function()
        if self.pendingToken == token then
            self:Resolve(nameRealm, nil)
        end
    end)
    addon:GetModule("Browser"):UpdateWhoButton()
end

-- info: the matching /who row, or nil for "not found".
function WhoCheck:Resolve(nameRealm, info)
    self.pending, self.pendingToken = nil, nil
    SetWhoToUi(false)
    self.checkedThisRun[nameRealm] = info and true or false

    if info then
        self.found = (self.found or 0) + 1
        self.status[nameRealm] = {
            online = true, level = info.level, classFile = info.filename,
            area = info.area, checked = time(),
        }
        local record = addon.db.global.players[nameRealm]
        if record then
            record.who = { level = info.level, classFile = info.filename }
        end
    else
        local previous = self.status[nameRealm]
        self.status[nameRealm] = {
            online = false, level = previous and previous.level,
            classFile = previous and previous.classFile, checked = time(),
        }
    end

    local browser = addon:GetModule("Browser")
    browser:RefreshIfShown()
    if #self.queue == 0 then
        self:Finish()
    else
        addon:Print(string.format("%s: %s. Next up: %s.", addon:GetShortName(nameRealm),
            info and "online" or "not found", addon:GetShortName(self.queue[1])))
        browser:UpdateWhoButton()
    end
end

function WhoCheck:OnWhoListUpdate()
    local nameRealm = self.pending
    if not nameRealm then return end
    local shortName = addon:GetShortName(nameRealm)

    local okCount, count = pcall(function()
        return C_FriendList and C_FriendList.GetNumWhoResults and (C_FriendList.GetNumWhoResults())
    end)
    if not (okCount and count and count > 0) then return end

    for i = 1, count do
        local okInfo, info = pcall(function() return C_FriendList.GetWhoInfo(i) end)
        if okInfo and type(info) == "table" then
            local name = info.fullName or info.name
            if name and (name == shortName or addon:NormalizeChatSender(name) == nameRealm) then
                self:Resolve(nameRealm, info)
                return
            end
        end
    end
    -- Results came in but this player isn't among them: leave the check
    -- pending - the timeout counts them as not found, and a later update
    -- (the client can send more than one) can still match.
end
