local addon = AlliesJournal
local Diary = addon:NewModule("Diary")
local AceGUI = LibStub("AceGUI-3.0")

-- Two read-mostly windows built from what the journal already holds:
--  * Runs: every outing you've recorded, newest first, who was there, and a
--    note you can write about the whole run.
--  * In numbers: a few totals about the people and runs in your journal.

local GRAY = "|cff909090"

local function FormatDuration(seconds)
    seconds = math.floor(seconds or 0)
    local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    if m > 0 then return string.format("%dm", m) end
    return seconds .. "s"
end

-- One reusable window per kind, dressed like the /aj window.
local function OpenWindow(self, key, title, width, height)
    local frame = self[key]
    if not frame then
        frame = AceGUI:Create("Window")
        frame.frame:SetFrameStrata("DIALOG")
        frame:SetTitle(title)
        frame:SetLayout("Fill")
        frame:SetWidth(width)
        frame:SetHeight(height)
        local fill = frame.frame:CreateTexture(nil, "BACKGROUND", nil, 2)
        fill:SetPoint("TOPLEFT", frame.frame, "TOPLEFT", 8, -8)
        fill:SetPoint("BOTTOMRIGHT", frame.frame, "BOTTOMRIGHT", -8, 8)
        frame.fill = fill
        frame:SetCallback("OnClose", function(widget) widget:Hide() end)
        self[key] = frame
    end
    local c = addon.db.global.settings.browserColors.window
    frame.fill:SetColorTexture(c[1], c[2], c[3], c[4])
    frame:ReleaseChildren()
    frame:Show()
    frame.frame:Raise()
    return frame
end

local function AddLabel(container, text)
    local label = AceGUI:Create("Label")
    label:SetFullWidth(true)
    label:SetText(text)
    container:AddChild(label)
    return label
end

local function AddHeading(container, text)
    local heading = AceGUI:Create("Heading")
    heading:SetText(text or "")
    heading:SetFullWidth(true)
    container:AddChild(heading)
end

----------------------------------------------------------------------
-- Runs
----------------------------------------------------------------------

function Diary:ShowRuns()
    local frame = OpenWindow(self, "runsFrame", "Allies Journal - Runs", 540, 620)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    frame:AddChild(scroll)

    local runs = addon:GetRuns()
    if #runs == 0 then
        AddLabel(scroll, "No runs yet. Once you've grouped with someone long enough for a session to be recorded, it shows up here.")
        return
    end

    AddLabel(scroll, GRAY .. #runs .. " run(s), newest first. Write a note on any of them - it's saved as you type.|r")
    AddHeading(scroll)

    for _, run in ipairs(runs) do
        local names = {}
        for _, nameRealm in ipairs(run.members) do
            table.insert(names, addon:GetShortName(nameRealm))
        end
        table.sort(names)

        AddLabel(scroll, string.format("|cffffd100%s|r  %s%s  -  %s grouped|r\nWith: %s",
            run.zone, GRAY, date("%Y-%m-%d %H:%M", run.date), FormatDuration(run.groupedSeconds),
            #names > 0 and table.concat(names, ", ") or "nobody recorded"))

        local note = AceGUI:Create("EditBox")
        note:SetFullWidth(true)
        note:SetLabel("Your note on this run")
        note:SetText(run.note or "")
        note:SetCallback("OnTextChanged", function(_, _, text)
            addon:SetRunNote(run.id, text)
        end)
        scroll:AddChild(note)

        AddHeading(scroll)
    end
end

----------------------------------------------------------------------
-- In numbers
----------------------------------------------------------------------

local function Plural(n, one, many)
    return n .. " " .. (n == 1 and one or many)
end

function Diary:ShowNumbers()
    local frame = OpenWindow(self, "numbersFrame", "Allies Journal - In numbers", 460, 560)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    frame:AddChild(scroll)

    local g = addon.db.global

    -- People and notes
    local players, withNotes, notes = 0, 0, 0
    local latestWords = { good = 0, average = 0, bad = 0 }
    local firstDate, lastDate
    local function Seen(when)
        if not when then return end
        firstDate = firstDate and math.min(firstDate, when) or when
        lastDate = lastDate and math.max(lastDate, when) or when
    end

    for nameRealm, record in pairs(g.players) do
        players = players + 1
        local reviews = addon:GetReviewsForPlayer(nameRealm)
        if #reviews > 0 then
            withNotes = withNotes + 1
            notes = notes + #reviews
            local latest = reviews[1]
            latestWords[latest.social] = (latestWords[latest.social] or 0) + 1
            for _, review in ipairs(reviews) do Seen(review.date) end
        end
    end

    -- Time and places, from the runs
    local runs = addon:GetRuns()
    local totalGrouped, byZone = 0, {}
    for _, run in ipairs(runs) do
        totalGrouped = totalGrouped + run.groupedSeconds
        byZone[run.zone] = (byZone[run.zone] or 0) + 1
        Seen(run.date)
    end

    -- Who you've played with most, from the recorded sessions
    local perPlayer = {}
    for nameRealm, record in pairs(g.players) do
        local seconds, count = 0, 0
        for _, sessionId in ipairs(record.sessions or {}) do
            local session = g.sessions[sessionId]
            if session then
                seconds = seconds + (session.groupedSeconds or 0)
                count = count + 1
            end
        end
        if count > 0 then
            table.insert(perPlayer, { name = addon:GetShortName(nameRealm), seconds = seconds, count = count })
        end
    end
    table.sort(perPlayer, function(a, b)
        if a.seconds ~= b.seconds then return a.seconds > b.seconds end
        return a.name < b.name
    end)

    local zones = {}
    for zone, count in pairs(byZone) do table.insert(zones, { zone = zone, count = count }) end
    table.sort(zones, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.zone < b.zone
    end)

    AddHeading(scroll, "People")
    AddLabel(scroll, string.format("%s in your journal, %d with a note.", Plural(players, "player", "players"), withNotes))
    AddLabel(scroll, string.format("%s written. Where each player's latest note landed: |cff40ff40%d Great|r, |cffffd100%d Fine|r, |cffff4040%d Not for me|r.",
        Plural(notes, "note", "notes"), latestWords.good, latestWords.average, latestWords.bad))

    AddHeading(scroll, "Playing together")
    AddLabel(scroll, string.format("%s recorded, %s spent grouped.", Plural(#runs, "run", "runs"), FormatDuration(totalGrouped)))
    if #perPlayer > 0 then
        local lines = {}
        for i = 1, math.min(5, #perPlayer) do
            local p = perPlayer[i]
            table.insert(lines, string.format("%d. %s - %s, %s", i, p.name, Plural(p.count, "session", "sessions"), FormatDuration(p.seconds)))
        end
        AddLabel(scroll, "Most time together:\n" .. table.concat(lines, "\n"))
    end
    if #zones > 0 then
        local lines = {}
        for i = 1, math.min(5, #zones) do
            table.insert(lines, string.format("%d. %s - %s", i, zones[i].zone, Plural(zones[i].count, "run", "runs")))
        end
        AddLabel(scroll, "Where you've been most:\n" .. table.concat(lines, "\n"))
    end

    if firstDate then
        AddHeading(scroll, "Timeline")
        AddLabel(scroll, string.format("First record: %s. Latest: %s.", date("%Y-%m-%d", firstDate), date("%Y-%m-%d", lastDate)))
    end

    if #perPlayer == 0 and notes == 0 then
        AddLabel(scroll, GRAY .. "Nothing here yet - it fills in as you group with people and write notes.|r")
    end
end
