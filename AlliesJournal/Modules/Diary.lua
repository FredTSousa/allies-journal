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
        fill:SetPoint("TOPLEFT", frame.content, "TOPLEFT", -6, 6)
        fill:SetPoint("BOTTOMRIGHT", frame.content, "BOTTOMRIGHT", 6, -6)
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

-- Day number in local time, so a run at 23:50 and one at 00:10 are two days.
local function DayIndex(t)
    local d = date("*t", t)
    return math.floor(time({ year = d.year, month = d.month, day = d.day, hour = 12 }) / 86400 + 0.5)
end

local PERIOD_WORDS = { week = "7 days", month = "30 days", year = "year" }

function Diary:ShowNumbers(period)
    period = PERIOD_LABELS[period or ""] and period or self.numbersPeriod or "all"
    self.numbersPeriod = period
    local now = time()
    local length = PERIOD_SECONDS[period]
    local cutoff = length and (now - length) or 0

    local frame = OpenWindow(self, "numbersFrame", "Allies Journal - In numbers", 500, 640)
    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("List")
    frame:AddChild(scroll)

    -- Filled in at the end; "Copy as text" hands it to a copyable window.
    local shareText = ""

    local top = AceGUI:Create("SimpleGroup")
    top:SetFullWidth(true)
    top:SetLayout("Flow")
    local picker = AceGUI:Create("Dropdown")
    picker:SetLabel("Period")
    picker:SetWidth(200)
    picker:SetList(PERIOD_LABELS, PERIODS)
    picker:SetValue(period)
    picker:SetCallback("OnValueChanged", function(_, _, value)
        -- Rebuilt a moment later: this window's widgets are released by it.
        C_Timer.After(0, function() self:ShowNumbers(value) end)
    end)
    top:AddChild(picker)
    local copyBtn = AceGUI:Create("Button")
    copyBtn:SetText("Copy as text")
    copyBtn:SetWidth(140)
    copyBtn:SetCallback("OnClick", function()
        if shareText ~= "" then
            addon:GetModule("Export"):ShowText("Allies Journal - " .. PERIOD_LABELS[period], shareText)
        end
    end)
    top:AddChild(copyBtn)
    scroll:AddChild(top)

    local g = addon.db.global

    -- Runs in the period, and (for a limited period) the same stretch before it
    local runs, prevRuns, prevSeconds = {}, 0, 0
    for _, run in ipairs(addon:GetRuns()) do
        if run.date >= cutoff then
            table.insert(runs, run)
        elseif length and run.date >= cutoff - length then
            prevRuns = prevRuns + 1
            prevSeconds = prevSeconds + run.groupedSeconds
        end
    end

    -- People: time together in the period, and how many sessions in all
    local people = {}
    for nameRealm, record in pairs(g.players) do
        local seconds, count, total, first = 0, 0, 0, nil
        local dates = {}
        for _, sessionId in ipairs(record.sessions or {}) do
            local session = g.sessions[sessionId]
            if session and session.date then
                total = total + 1
                dates[#dates + 1] = session.date
                first = first and math.min(first, session.date) or session.date
                if session.date >= cutoff then
                    seconds = seconds + (session.groupedSeconds or 0)
                    count = count + 1
                end
            end
        end
        if count > 0 then
            -- The longest wait before a session in this period (a month or
            -- more makes a "comeback").
            table.sort(dates)
            local gap
            for i = 2, #dates do
                if dates[i] >= cutoff and dates[i] - dates[i - 1] >= 30 * 86400 then
                    gap = math.max(gap or 0, dates[i] - dates[i - 1])
                end
            end
            table.insert(people, { nameRealm = nameRealm, name = addon:GetShortName(nameRealm),
                seconds = seconds, count = count, total = total, first = first, gap = gap })
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
    local members, weekend = 0, 0
    local bossTotal, wipeTotal, dungeonRuns, mobTotal = 0, 0, 0, 0
    local dayset = {}
    for _, run in ipairs(runs) do
        totalGrouped = totalGrouped + run.groupedSeconds
        members = members + #run.members
        bossTotal = bossTotal + (run.bosses or 0)
        wipeTotal = wipeTotal + (run.wipes or 0)
        mobTotal = mobTotal + (run.mobs or 0)
        if run.dungeon then dungeonRuns = dungeonRuns + 1 end
        byZone[run.zone] = (byZone[run.zone] or 0) + 1
        local weekday = date("%A", run.date)
        byWeekday[weekday] = (byWeekday[weekday] or 0) + 1
        local dow = tonumber(date("%w", run.date))
        if dow == 0 or dow == 6 then weekend = weekend + 1 end
        local hour = tonumber(date("%H", run.date)) or 0
        for _, part in ipairs(TIME_OF_DAY) do
            if hour >= part.from and hour < part.to then
                byPart[part.label] = (byPart[part.label] or 0) + 1
            end
        end
        dayset[DayIndex(run.date)] = true
        firstDate = firstDate and math.min(firstDate, run.date) or run.date
        lastDate = lastDate and math.max(lastDate, run.date) or run.date
        if not longest or run.groupedSeconds > longest.groupedSeconds then longest = run end
    end

    -- Days with a run, and the longest streak of days in a row
    local dayList = {}
    for day in pairs(dayset) do dayList[#dayList + 1] = day end
    table.sort(dayList)
    local streak, bestStreak, previousDay = 0, 0, nil
    for _, day in ipairs(dayList) do
        if previousDay and day == previousDay + 1 then streak = streak + 1 else streak = 1 end
        bestStreak = math.max(bestStreak, streak)
        previousDay = day
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

    local share = { "Allies Journal - " .. PERIOD_LABELS[period] }

    -- Headline
    Spacer()
    local headline = string.format("grouped with %s across %s", Plural(#people, "different person", "different people"), Plural(#runs, "run", "runs"))
    AddStat(scroll, FormatDuration(totalGrouped), headline)
    table.insert(share, FormatDuration(totalGrouped) .. " " .. headline)
    if length and prevRuns > 0 then
        local dr, ds = #runs - prevRuns, totalGrouped - prevSeconds
        AddLabel(scroll, GRAY .. string.format("Compared with the %s before: %s%s, %s%s.|r", PERIOD_WORDS[period],
            dr >= 0 and "+" or "-", Plural(math.abs(dr), "run", "runs"), ds >= 0 and "+" or "-", FormatDuration(math.abs(ds))))
    end
    Spacer()

    -- Companions
    if #people > 0 then
        AddHeading(scroll, "Companions")
        Spacer()
        AddStat(scroll, people[1].name,
            string.format("your most-played-with: %s over %s", FormatDuration(people[1].seconds), Plural(people[1].count, "session", "sessions")))
        Spacer()
        local best = TopN(people, 5)
        for _, person in ipairs(best) do
            AddRow(scroll, person.name, Bar(person.seconds / best[1].seconds, 255, 209, 0) .. "  " .. GRAY .. FormatDuration(person.seconds) .. "|r")
        end
        local shared = {}
        for i = 1, math.min(3, #best) do
            shared[i] = string.format("%s (%s)", best[i].name, FormatDuration(best[i].seconds))
        end
        table.insert(share, "Most played with: " .. table.concat(shared, ", "))
        Spacer()
    end

    -- Highlights, two to a row
    local tiles = {}
    local facts = {}
    if zones[1] then
        local others = {}
        for i = 2, math.min(3, #zones) do others[#others + 1] = string.format("%s (%d)", zones[i].key, zones[i].count) end
        table.insert(tiles, { "Favorite place", zones[1].key, Plural(zones[1].count, "run", "runs")
            .. (#others > 0 and (", then " .. table.concat(others, ", ")) or "") })
        table.insert(facts, "Favorite place: " .. zones[1].key)
    end
    if weekdays[1] then
        table.insert(tiles, { "Busiest day", weekdays[1].key, Plural(weekdays[1].count, "run", "runs")
            .. (parts[1] and (", mostly " .. parts[1].key) or "") })
        table.insert(facts, "Busiest day: " .. weekdays[1].key)
    end
    if longest then
        table.insert(tiles, { "Longest run", FormatDuration(longest.groupedSeconds), longest.zone .. ", " .. date("%Y-%m-%d", longest.date) })
        table.insert(facts, "Longest run: " .. FormatDuration(longest.groupedSeconds) .. " in " .. longest.zone)
    end
    if #runs > 0 then
        table.insert(tiles, { "Average group", string.format("%.1f other players", members / #runs) })
        table.insert(tiles, { "Active days", Plural(#dayList, "day", "days"), "with at least one run" })
        if mobTotal > 0 then
            table.insert(tiles, { "Mobs defeated", tostring(mobTotal), "that gave you experience" })
            table.insert(facts, "Mobs defeated: " .. mobTotal)
        end
        if dungeonRuns > 0 and bossTotal > 0 then
            table.insert(tiles, { "Bosses defeated", tostring(bossTotal), wipeTotal > 0
                and (Plural(wipeTotal, "group wipe", "group wipes") .. " along the way") or "and not a single wipe" })
            table.insert(facts, "Bosses defeated: " .. bossTotal .. (wipeTotal > 0 and (" (" .. Plural(wipeTotal, "group wipe", "group wipes") .. ")") or " (no wipes)"))
        end
        if bestStreak >= 2 then
            table.insert(tiles, { "Longest streak", Plural(bestStreak, "day", "days") .. " in a row" })
            table.insert(facts, "Longest streak: " .. Plural(bestStreak, "day", "days") .. " in a row")
        end
    end

    local again = 0
    for _, person in ipairs(people) do if person.total >= 2 then again = again + 1 end end
    local fresh = 0
    if #people > 0 then
        if cutoff > 0 then
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
            local ratio = again / #people
            local style = ratio >= 0.6 and "|cffffd100The Regular|r - you keep coming back to the same people."
                or ratio <= 0.25 and "|cffffd100The Explorer|r - you're always meeting someone new."
                or "|cffffd100The Balanced Adventurer|r - a good mix of old friends and new faces."
            AddLabel(scroll, "Your style: " .. style)
        end
        Spacer()
    end
    for _, fact in ipairs(facts) do table.insert(share, fact) end

    -- Badges: a few earned from how you played
    local badges = {}
    local function Percent(n) return math.floor(n / #runs * 100 + 0.5) end
    if bestStreak >= 3 then
        table.insert(badges, { "On a Roll", Plural(bestStreak, "day", "days") .. " in a row with a run" })
    end
    if longest and longest.groupedSeconds >= 7200 then
        table.insert(badges, { "Marathoner", "a single run of " .. FormatDuration(longest.groupedSeconds) })
    end
    local comeback
    for _, person in ipairs(people) do
        if person.gap and (not comeback or person.gap > comeback.gap) then comeback = person end
    end
    if comeback then
        table.insert(badges, { "Comeback Kid", string.format("back with %s after %s", comeback.name, Plural(math.floor(comeback.gap / 86400), "day", "days")) })
    end
    if #runs >= 3 then
        if (byPart["late at night"] or 0) / #runs >= 0.3 then
            table.insert(badges, { "Night Owl", Percent(byPart["late at night"]) .. "% of your runs started late at night" })
        elseif (byPart["mornings"] or 0) / #runs >= 0.4 then
            table.insert(badges, { "Early Bird", Percent(byPart["mornings"]) .. "% of your runs started in the morning" })
        end
        if #runs >= 4 and weekend / #runs >= 0.55 then
            table.insert(badges, { "Weekend Warrior", Percent(weekend) .. "% of your runs were on a weekend" })
        end
    end
    if fresh >= 5 and #people > 0 and fresh / #people >= 0.5 then
        table.insert(badges, { "Social Butterfly", Plural(fresh, "new face", "new faces") })
    end
    badges = TopN(badges, 4)
    if #badges > 0 then
        AddHeading(scroll, "Badges")
        Spacer()
        local names = {}
        for _, badge in ipairs(badges) do
            AddLabel(scroll, "|cffffd100" .. badge[1] .. "|r  " .. GRAY .. badge[2] .. "|r")
            table.insert(names, badge[1])
        end
        table.insert(share, "Badges: " .. table.concat(names, ", "))
        Spacer()
    end

    -- Activity over time: days for a week, weeks for a month, months otherwise
    do
        local buckets = {}
        local todayIndex = DayIndex(now)
        if period == "week" or period == "month" then
            local size = period == "week" and 1 or 7
            local count = period == "week" and 7 or 5
            for i = 1, count do
                local lastDay = todayIndex - (count - i) * size
                local firstDay = lastDay - size + 1
                local at = now - (todayIndex - firstDay) * 86400
                buckets[i] = { first = firstDay, last = lastDay, count = 0,
                    label = size == 1 and date("%a %d", at) or ("Week of " .. date("%b %d", at)) }
            end
            for _, run in ipairs(runs) do
                local day = DayIndex(run.date)
                for _, bucket in ipairs(buckets) do
                    if day >= bucket.first and day <= bucket.last then bucket.count = bucket.count + 1 break end
                end
            end
        else
            local nowDate = date("*t", now)
            local nowKey = nowDate.year * 12 + nowDate.month - 1
            local startKey = nowKey - 11
            if period == "all" then
                local earliest
                for _, run in ipairs(runs) do
                    local d = date("*t", run.date)
                    local key = d.year * 12 + d.month - 1
                    earliest = earliest and math.min(earliest, key) or key
                end
                if earliest then startKey = math.max(startKey, earliest) end
            end
            local index = {}
            for key = startKey, nowKey do
                local bucket = { count = 0, label = date("%b %Y", time({ year = math.floor(key / 12), month = key % 12 + 1, day = 1, hour = 12 })) }
                buckets[#buckets + 1] = bucket
                index[key] = bucket
            end
            for _, run in ipairs(runs) do
                local d = date("*t", run.date)
                local bucket = index[d.year * 12 + d.month - 1]
                if bucket then bucket.count = bucket.count + 1 end
            end
        end

        local peak = 0
        for _, bucket in ipairs(buckets) do peak = math.max(peak, bucket.count) end
        if #buckets >= 2 and peak > 0 and #runs >= 2 then
            AddHeading(scroll, "Activity")
            Spacer()
            for _, bucket in ipairs(buckets) do
                AddRow(scroll, bucket.label, bucket.count > 0
                    and (Bar(bucket.count / peak, 255, 209, 0) .. "  " .. GRAY .. bucket.count .. "|r")
                    or (GRAY .. "-|r"))
            end
            Spacer()
        end
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
        table.insert(share, string.format("Notes: %d written - %d Great to play with, %d Fine, %d Not for me",
            notes, words.good, words.average, words.bad))

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

    shareText = table.concat(share, "\n")
end
