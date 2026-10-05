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
        frame = addon:CreateWindow()
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
-- In numbers: a "wrapped" for your journal
----------------------------------------------------------------------

local PERIODS = { "all", "year", "month", "week" }
local PERIOD_LABELS = { all = "All time", year = "Last year", month = "Last 30 days", week = "Last 7 days" }
local PERIOD_SECONDS = { year = 365 * 86400, month = 30 * 86400, week = 7 * 86400 }

local function Plural(n, one, many)
    return n .. " " .. (n == 1 and one or many)
end

-- A horizontal bar drawn with an inline, tinted texture (no extra frames).
local function Bar(fraction, r, g, b)
    local width = math.max(3, math.floor(fraction * 200))
    return string.format("|TInterface\\Buttons\\WHITE8X8:10:%d:0:0:8:8:0:8:0:8:%d:%d:%d|t", width, r, g, b)
end

-- A big highlighted figure with a short caption under it.
local function AddStat(container, big, caption)
    local value = AceGUI:Create("Label")
    value:SetFullWidth(true)
    value:SetFontObject(GameFontNormalLarge)
    value:SetColor(1, 0.82, 0)
    value:SetText(big)
    container:AddChild(value)
    if caption and caption ~= "" then
        AddLabel(container, GRAY .. caption .. "|r")
    end
end

-- A name on the left and its bar/figure on the right, so a list lines up.
local function AddRow(container, left, right)
    local row = AceGUI:Create("SimpleGroup")
    row:SetFullWidth(true)
    row:SetLayout("Flow")
    local a = AceGUI:Create("Label")
    a:SetRelativeWidth(0.36)
    a:SetText(left)
    row:AddChild(a)
    local b = AceGUI:Create("Label")
    b:SetRelativeWidth(0.62)
    b:SetText(right)
    row:AddChild(b)
    container:AddChild(row)
end

-- Small facts two to a row: a gray title over the value.
local function AddTiles(container, tiles)
    local grid = AceGUI:Create("SimpleGroup")
    grid:SetFullWidth(true)
    grid:SetLayout("Flow")
    for _, tile in ipairs(tiles) do
        local label = AceGUI:Create("Label")
        label:SetRelativeWidth(0.49)
        label:SetText(GRAY .. tile[1] .. "|r\n|cffffd100" .. tile[2] .. "|r" .. (tile[3] and ("\n" .. GRAY .. tile[3] .. "|r") or ""))
        grid:AddChild(label)
    end
    container:AddChild(grid)
end

local function TopN(list, n)
    local out = {}
    for i = 1, math.min(n, #list) do out[i] = list[i] end
    return out
end

local TIME_OF_DAY = {
    { from = 5, to = 12, label = "mornings" },
    { from = 12, to = 18, label = "afternoons" },
    { from = 18, to = 24, label = "evenings" },
    { from = 0, to = 5, label = "late at night" },
}

function Diary:ShowNumbers(period)
    period = PERIOD_LABELS[period or ""] and period or self.numbersPeriod or "all"
    self.numbersPeriod = period
    local cutoff = PERIOD_SECONDS[period] and (time() - PERIOD_SECONDS[period]) or 0

    local frame = OpenWindow(self, "numbersFrame", "Allies Journal - In numbers", 500, 640)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    frame:AddChild(scroll)

    local picker = AceGUI:Create("Dropdown")
    picker:SetLabel("Period")
    picker:SetWidth(200)
    picker:SetList(PERIOD_LABELS, PERIODS)
    picker:SetValue(period)
    picker:SetCallback("OnValueChanged", function(_, _, value)
        -- Rebuilt a moment later: this window's widgets are released by it.
        C_Timer.After(0, function() self:ShowNumbers(value) end)
    end)
    scroll:AddChild(picker)

    local g = addon.db.global

    -- Runs in the period
    local runs = {}
    for _, run in ipairs(addon:GetRuns()) do
        if run.date >= cutoff then table.insert(runs, run) end
    end

    -- People: time together in the period, and how many sessions in all
    local people = {}
    for nameRealm, record in pairs(g.players) do
        local seconds, count, total, first = 0, 0, 0, nil
        for _, sessionId in ipairs(record.sessions or {}) do
            local session = g.sessions[sessionId]
            if session and session.date then
                total = total + 1
                first = first and math.min(first, session.date) or session.date
                if session.date >= cutoff then
                    seconds = seconds + (session.groupedSeconds or 0)
                    count = count + 1
                end
            end
        end
        if count > 0 then
            table.insert(people, { nameRealm = nameRealm, name = addon:GetShortName(nameRealm),
                seconds = seconds, count = count, total = total, first = first })
        end
    end
    table.sort(people, function(a, b)
        if a.seconds ~= b.seconds then return a.seconds > b.seconds end
        return a.name < b.name
    end)

    -- Notes written in the period
    local notes, words = 0, { good = 0, average = 0, bad = 0 }
    local firstDate, lastDate
    for nameRealm in pairs(g.players) do
        for _, review in ipairs(addon:GetReviewsForPlayer(nameRealm)) do
            if review.date >= cutoff then
                notes = notes + 1
                words[review.social] = (words[review.social] or 0) + 1
                firstDate = firstDate and math.min(firstDate, review.date) or review.date
                lastDate = lastDate and math.max(lastDate, review.date) or review.date
            end
        end
    end

    if #runs == 0 and notes == 0 then
        AddLabel(scroll, " ")
        AddLabel(scroll, GRAY .. "Nothing in this period yet - it fills in as you group with people and write notes.|r")
        return
    end

    -- Totals from the runs
    local totalGrouped, longest = 0, nil
    local byZone, byWeekday, byPart = {}, {}, {}
    local members = 0
    for _, run in ipairs(runs) do
        totalGrouped = totalGrouped + run.groupedSeconds
        members = members + #run.members
        byZone[run.zone] = (byZone[run.zone] or 0) + 1
        local weekday = date("%A", run.date)
        byWeekday[weekday] = (byWeekday[weekday] or 0) + 1
        local hour = tonumber(date("%H", run.date)) or 0
        for _, part in ipairs(TIME_OF_DAY) do
            if hour >= part.from and hour < part.to then
                byPart[part.label] = (byPart[part.label] or 0) + 1
            end
        end
        firstDate = firstDate and math.min(firstDate, run.date) or run.date
        lastDate = lastDate and math.max(lastDate, run.date) or run.date
        if not longest or run.groupedSeconds > longest.groupedSeconds then longest = run end
    end

    local function Ranked(map)
        local list = {}
        for key, count in pairs(map) do table.insert(list, { key = key, count = count }) end
        table.sort(list, function(a, b)
            if a.count ~= b.count then return a.count > b.count end
            return tostring(a.key) < tostring(b.key)
        end)
        return list
    end
    local zones, weekdays, parts = Ranked(byZone), Ranked(byWeekday), Ranked(byPart)

    local function Spacer() AddLabel(scroll, " ") end

    -- Headline
    Spacer()
    AddStat(scroll, FormatDuration(totalGrouped),
        string.format("grouped with %s across %s", Plural(#people, "different person", "different people"), Plural(#runs, "run", "runs")))
    Spacer()

    -- Companions
    if #people > 0 then
        AddHeading(scroll, "Companions")
        Spacer()
        AddStat(scroll, people[1].name,
            string.format("your most-played-with: %s over %s", FormatDuration(people[1].seconds), Plural(people[1].count, "session", "sessions")))
        Spacer()
        local top = TopN(people, 5)
        for _, person in ipairs(top) do
            AddRow(scroll, person.name, Bar(person.seconds / top[1].seconds, 255, 209, 0) .. "  " .. GRAY .. FormatDuration(person.seconds) .. "|r")
        end
        Spacer()
    end

    -- Highlights, two to a row
    local tiles = {}
    if zones[1] then
        local others = {}
        for i = 2, math.min(3, #zones) do others[#others + 1] = string.format("%s (%d)", zones[i].key, zones[i].count) end
        table.insert(tiles, { "Favorite place", zones[1].key, Plural(zones[1].count, "run", "runs")
            .. (#others > 0 and (", then " .. table.concat(others, ", ")) or "") })
    end
    if weekdays[1] then
        table.insert(tiles, { "Busiest day", weekdays[1].key, Plural(weekdays[1].count, "run", "runs")
            .. (parts[1] and (", mostly " .. parts[1].key) or "") })
    end
    if longest then
        table.insert(tiles, { "Longest run", FormatDuration(longest.groupedSeconds), longest.zone .. ", " .. date("%Y-%m-%d", longest.date) })
    end
    if #runs > 0 then
        table.insert(tiles, { "Average group", string.format("%.1f other players", members / #runs) })
    end

    local again = 0
    for _, person in ipairs(people) do if person.total >= 2 then again = again + 1 end end
    if #people > 0 then
        if cutoff > 0 then
            local fresh = 0
            for _, person in ipairs(people) do if person.first and person.first >= cutoff then fresh = fresh + 1 end end
            table.insert(tiles, { "New faces", tostring(fresh), again > 0 and (again .. " you had met before") or "all first meetings" })
        elseif again > 0 then
            table.insert(tiles, { "Played with again", Plural(again, "person", "people") })
        end
    end

    if #tiles > 0 then
        AddHeading(scroll, "Highlights")
        Spacer()
        AddTiles(scroll, tiles)
        if #people >= 3 then
            local share = again / #people
            local style = share >= 0.6 and "|cffffd100The Regular|r - you keep coming back to the same people."
                or share <= 0.25 and "|cffffd100The Explorer|r - you're always meeting someone new."
                or "|cffffd100The Balanced Adventurer|r - a good mix of old friends and new faces."
            AddLabel(scroll, "Your style: " .. style)
        end
        Spacer()
    end

    -- How it went
    if notes > 0 then
        AddHeading(scroll, "How it went")
        Spacer()
        AddLabel(scroll, GRAY .. Plural(notes, "note", "notes") .. " written|r")
        local rows = {
            { "Great to play with", words.good, 64, 255, 64 },
            { "Fine", words.average, 255, 209, 0 },
            { "Not for me", words.bad, 255, 64, 64 },
        }
        for _, row in ipairs(rows) do
            AddRow(scroll, row[1], Bar(row[2] / notes, row[3], row[4], row[5]) .. "  " .. GRAY .. row[2] .. "|r")
        end

        local roleCount = { tank = 0, healer = 0, dps = 0 }
        local anyRole = false
        for _, person in ipairs(people) do
            local latest = addon:GetLatestReview(person.nameRealm)
            if latest and roleCount[latest.role or ""] then
                roleCount[latest.role] = roleCount[latest.role] + 1
                anyRole = true
            end
        end
        if anyRole then
            Spacer()
            AddLabel(scroll, GRAY .. string.format("Roles you've grouped with, from your notes: %d tank%s, %d healer%s, %d DPS.|r",
                roleCount.tank, roleCount.tank == 1 and "" or "s", roleCount.healer, roleCount.healer == 1 and "" or "s", roleCount.dps))
        end
    end

    if firstDate then
        Spacer()
        AddLabel(scroll, GRAY .. string.format("From %s to %s.|r", date("%Y-%m-%d", firstDate), date("%Y-%m-%d", lastDate)))
    end
end
