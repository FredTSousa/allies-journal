AlliesJournal = LibStub("AceAddon-3.0"):NewAddon("AlliesJournal", "AceEvent-3.0", "AceConsole-3.0")

-- Persistence is hand-rolled (no AceDB-3.0): this addon never used AceDB's
-- profiles/namespaces, just a flat `global` table, so a plain table with
-- the same shape is a straight swap - self.db.global.* is unchanged from
-- the AceDB version, so no other file needed to change.
local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = DeepCopy(v) end
    return copy
end

-- Adds anything in this character's old per-character data (PRTrackerDB)
-- that the account-wide data doesn't have yet. Never overwrites: reviews
-- and sessions are keyed by unique id, so an id already present wins, and a
-- player known to both gets the union of their review/session ids. Settings
-- are only taken from the old data when the account has none yet (the first
-- character to log in). The old data is left exactly as it was, and a flag
-- on it means this runs once per character.
function AlliesJournal.MergeLegacyCharacterData(g)
    local legacy = PRTrackerDB
    if type(legacy) ~= "table" or legacy.migratedToAccount then return end
    local old = legacy.global
    if type(old) ~= "table" then return end

    g.players = g.players or {}
    g.reviews = g.reviews or {}
    g.sessions = g.sessions or {}

    for id, review in pairs(old.reviews or {}) do
        if g.reviews[id] == nil then g.reviews[id] = DeepCopy(review) end
    end
    for id, session in pairs(old.sessions or {}) do
        if g.sessions[id] == nil then g.sessions[id] = DeepCopy(session) end
    end

    local function AddMissingIds(into, from)
        local seen = {}
        for _, id in ipairs(into) do seen[id] = true end
        for _, id in ipairs(from or {}) do
            if not seen[id] then table.insert(into, id) end
        end
    end
    for nameRealm, record in pairs(old.players or {}) do
        local mine = g.players[nameRealm]
        if not mine then
            g.players[nameRealm] = DeepCopy(record)
        else
            mine.reviews = mine.reviews or {}
            mine.sessions = mine.sessions or {}
            AddMissingIds(mine.reviews, record.reviews)
            AddMissingIds(mine.sessions, record.sessions)
            local theirs = record.lastSeen and record.lastSeen.date or 0
            local ours = mine.lastSeen and mine.lastSeen.date or 0
            if theirs > ours then mine.lastSeen = DeepCopy(record.lastSeen) end
        end
    end

    if g.settings == nil and type(old.settings) == "table" then
        g.settings = DeepCopy(old.settings)
    end

    legacy.migratedToAccount = true
end

function AlliesJournal:OnInitialize()
    -- Saved data lives in AlliesJournalDB, one account-wide set shared by
    -- every character. Earlier versions (Player Reviews) saved it as
    -- PRTrackerAccountDB, which the .toc still declares so it can be read
    -- here: it is moved over once (the very same table, now saved under the
    -- new name) and the old variable is dropped so it isn't stored twice.
    -- PRTrackerDB is the OLD per-character store: still declared and left
    -- untouched as a backup, and each character's copy is merged into the
    -- account data once (see MergeLegacyCharacterData).
    AlliesJournalDB = AlliesJournalDB or {}
    if type(PRTrackerAccountDB) == "table" and type(PRTrackerAccountDB.global) == "table" then
        if not (type(AlliesJournalDB.global) == "table" and next(AlliesJournalDB.global) ~= nil) then
            AlliesJournalDB.global = PRTrackerAccountDB.global
            PRTrackerAccountDB = nil
        end
    end
    AlliesJournalDB.global = AlliesJournalDB.global or {}
    local g = AlliesJournalDB.global
    AlliesJournal.MergeLegacyCharacterData(g)
    g.players = g.players or {}    -- [nameRealm] = playerRecord
    g.reviews = g.reviews or {}    -- [reviewId]  = review
    g.runNotes = g.runNotes or {}  -- [runId] = your note about a whole run (see GetRuns)
    g.sessions = g.sessions or {}  -- [sessionId] = session (see RosterTracker's session-eligibility gate)
    g.settings = g.settings or { gateMinutes = 10 }  -- minutes grouped together before a review can queue
    -- Session history thresholds: a session only gets recorded when BOTH
    -- are cleared (not either) - deliberately excludes non-combat grouping
    -- and trivial world mob-tagging. Independent of gateMinutes above,
    -- which only gates the review PROMPT, not session recording.
    g.settings.sessionGate = g.settings.sessionGate or {}
    do
        local sg = g.settings.sessionGate
        sg.minGroupedSeconds = sg.minGroupedSeconds or 240  -- 4 min
        sg.minCombatSeconds = sg.minCombatSeconds or 120    -- 2 min
    end
    -- Retention: how old (in days) an unreviewed player's session needs to
    -- be before /pr's Clean Up flow will suggest removing it. Never
    -- applied automatically - see Browser's Clean Up button.
    g.settings.retention = g.settings.retention or {}
    g.settings.retention.purgeDays = g.settings.retention.purgeDays or 60
    -- Toggleable, per user request - a chat recap ("grouped 6m, 3m
    -- combat") with a clickable name to open a full review, for exactly
    -- the case a review prompt DOESN'T fire (below gateMinutes) so a
    -- short grouping doesn't just silently vanish with no way to look
    -- back at it. See RosterTracker's departure handling.
    g.settings.departureSummary = g.settings.departureSummary or {}
    if g.settings.departureSummary.enabled == nil then
        g.settings.departureSummary.enabled = true
    end
    -- Debug/test slash commands (/pr dump, /pr testgroup, /pr lfginspect...)
    -- stay off the normal command list and refuse to run unless this is on
    -- (a hidden /pr dev command; deliberately not in help or options).
    if g.settings.developerTools == nil then g.settings.developerTools = false end
    -- Minimap button: hidden flag, and its angle around the minimap edge
    -- (degrees), saved whenever it's dragged.
    g.settings.minimap = g.settings.minimap or {}
    if g.settings.minimap.hide == nil then g.settings.minimap.hide = false end
    g.settings.minimap.angle = g.settings.minimap.angle or 215
    -- Group Finder: the listing leader's current area, drawn on the row.
    -- The anchor/offsets are where that text sits within the row - a first
    -- guess (bottom right), meant to be tuned in /pr options.
    g.settings.lfg = g.settings.lfg or {}
    do
        local l = g.settings.lfg
        if l.showLocation == nil then l.showLocation = true end
        l.locAnchor = l.locAnchor or "BOTTOMRIGHT"
        l.locRel = l.locRel or "BOTTOMRIGHT"
        l.locX = l.locX or -8
        l.locY = l.locY or 6
    end
    -- Size of the /pr window: set from /pr options, or by dragging its
    -- corner (which saves the new size).
    g.settings.browserWindow = g.settings.browserWindow or {}
    g.settings.browserWindow.width = g.settings.browserWindow.width or 550
    g.settings.browserWindow.height = g.settings.browserWindow.height or 700
    -- Browser's player list card spacing, editable via /pr options.
    g.settings.browserList = g.settings.browserList or {}
    g.settings.browserList.rowPadding = g.settings.browserList.rowPadding or 4
    -- Player list colors {r, g, b, a}, tunable from /pr options when
    -- developer tools are on. Missing entries get their default.
    -- (Bumping the version replaces saved colors with the current
    -- defaults once: 2 = cards became fades, 3 = tuned defaults.)
    if g.settings.browserColorsVersion ~= 3 then
        g.settings.browserColors = {}
        g.settings.browserColorsVersion = 3
    end
    g.settings.browserColors = g.settings.browserColors or {}
    for key, color in pairs(AlliesJournal.DEFAULT_BROWSER_COLORS) do
        g.settings.browserColors[key] = g.settings.browserColors[key] or { unpack(color) }
    end
    -- Recent Allies pinning: players with a bad rating are not pinned
    -- unless this is turned on (every pin path follows it).
    g.settings.recentAllies = g.settings.recentAllies or {}
    if g.settings.recentAllies.pinBad == nil then g.settings.recentAllies.pinBad = false end
    -- One "How was it?" question instead of Social + Performance when writing
    -- a note. Notes remember the mode they were written in, so flipping this
    -- never changes an existing note.
    if g.settings.simpleNotes == nil then g.settings.simpleNotes = false end
    -- Experimental (developer option): a group at the end of a run shares one window with a strip of names.
    if g.settings.playerStrip == nil then g.settings.playerStrip = false end
    -- Small chat reminders: someone you have a note on joins your group, and
    -- someone you noted as Great comes online.
    g.settings.notices = g.settings.notices or {}
    if g.settings.notices.joinNotice == nil then g.settings.notices.joinNotice = true end
    if g.settings.notices.onlineAlerts == nil then g.settings.notices.onlineAlerts = true end
    if g.settings.notices.facesSummary == nil then g.settings.notices.facesSummary = true end
    g.settings.browserList.cardFade = g.settings.browserList.cardFade or 0.25
    g.settings.browserList.offlineDim = g.settings.browserList.offlineDim or 0.55
    -- Visual settings, editable live via /pr options. Every field uses its
    -- own `or` fallback (not just the containing table) so a saved
    -- settings table from before a given field existed gains it without
    -- resetting fields that were already there.
    g.settings.badge = g.settings.badge or {}
    do
        -- Defaults tuned and confirmed in-game: unit frame badge size 32,
        -- anchored Center to the frame's Top Left at (10, -35); LFG row
        -- badge size 42, anchored Center to its own row frame's Center
        -- at (193, -5) - anchoring to the row frame itself (not the name
        -- text) so position stays stable whether the reviewed player is
        -- the group leader or a regular member, since their row layouts
        -- differ. Both use the full-image FavoritesIcon star (tinted by
        -- rating) rather than the flat color square.
        local b = g.settings.badge
        b.unitSize = b.unitSize or b.size or 32
        b.unitAnchorPoint = b.unitAnchorPoint or "CENTER"
        b.unitRelPoint = b.unitRelPoint or "TOPLEFT"
        b.unitOffsetX = b.unitOffsetX or 10
        b.unitOffsetY = b.unitOffsetY or -35
        b.lfgSize = b.lfgSize or b.size or 42
        b.lfgAnchorPoint = b.lfgAnchorPoint or "CENTER"
        b.lfgRelPoint = b.lfgRelPoint or "CENTER"
        b.lfgOffsetX = b.lfgOffsetX or 193
        b.lfgOffsetY = b.lfgOffsetY or -5
        b.size = nil  -- superseded by unitSize/lfgSize
        -- What the LFG badge anchors to - "frame" (the row's own
        -- container) is stable regardless of leader/member layout;
        -- "name" (the matched name FontString) shifts between them.
        -- "classIcon"/"resultBG" are other stable options - see
        -- /pr lfginspect for the field names they came from.
        b.lfgAnchorTarget = b.lfgAnchorTarget or "frame"
        -- Party/raid frames: much smaller than the target frame, so their
        -- own placement - a small badge in the frame's top right corner.
        b.groupSize = b.groupSize or 16
        b.groupAnchorPoint = b.groupAnchorPoint or "TOPRIGHT"
        b.groupRelPoint = b.groupRelPoint or "TOPRIGHT"
        b.groupOffsetX = b.groupOffsetX or -3
        b.groupOffsetY = b.groupOffsetY or -3
        -- Icon texture (shared between unit frame and LFG badges, both
        -- tinted the same way) - blank path means the flat color square.
        -- left/right/top/bottom are SetTexCoord slicing, for sprite-sheet
        -- icons that pack multiple states into one file; the default here
        -- uses the full image (0,1,0,1), not a slice.
        b.icon = b.icon or {}
        b.icon.path = b.icon.path or "Interface\\COMMON\\FavoritesIcon"
        b.icon.left = b.icon.left or 0
        b.icon.right = b.icon.right or 1
        b.icon.top = b.icon.top or 0
        b.icon.bottom = b.icon.bottom or 1
    end
    g.settings.tooltip = g.settings.tooltip or {}
    do
        local t = g.settings.tooltip
        t.lfgOffsetX = t.lfgOffsetX or 8
        t.lfgOffsetY = t.lfgOffsetY or 37
        t.paddingRight = t.paddingRight or 0
        -- Split from one shared `template` into worldTemplate/lfgTemplate
        -- so the LFG tooltip's leading blank line (unwanted - see
        -- DEFAULT_LFG_TOOLTIP_TEMPLATE's comment) can be removed without
        -- affecting the world tooltip. `t.template` is the old shared
        -- field from before the split; reuse it as the world template's
        -- starting point if present, so an existing customization isn't
        -- silently lost.
        t.worldTemplate = t.worldTemplate or t.template or AlliesJournal.DEFAULT_WORLD_TOOLTIP_TEMPLATE
        t.lfgTemplate = t.lfgTemplate or AlliesJournal.DEFAULT_LFG_TOOLTIP_TEMPLATE
        -- A template that's still exactly the first-version default (color
        -- codes aside) was never edited, so it picks up the new default
        -- (role icon + date + place); an edited one is left alone.
        local function Plain(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
        for _, old in ipairs({ AlliesJournal.OLD_WORLD_TOOLTIP_TEMPLATE, AlliesJournal.OLD_WORLD_TOOLTIP_TEMPLATE_2, AlliesJournal.OLD_WORLD_TOOLTIP_TEMPLATE_3 }) do
            if Plain(t.worldTemplate) == Plain(old) then
                t.worldTemplate = AlliesJournal.DEFAULT_WORLD_TOOLTIP_TEMPLATE
            end
        end
        for _, old in ipairs({ AlliesJournal.OLD_LFG_TOOLTIP_TEMPLATE, AlliesJournal.OLD_LFG_TOOLTIP_TEMPLATE_2, AlliesJournal.OLD_LFG_TOOLTIP_TEMPLATE_3 }) do
            if Plain(t.lfgTemplate) == Plain(old) then
                t.lfgTemplate = AlliesJournal.DEFAULT_LFG_TOOLTIP_TEMPLATE
            end
        end
        -- superseded by the two fields above
        t.template = nil
        -- superseded by the template itself - a line can just be deleted
        -- from it instead of toggled off
        t.showSocialNote = nil
        t.showPerformanceNote = nil
        t.showReviewCount = nil
    end
    -- Review prompt window size, editable via /pr options - the window's
    -- own ScrollFrame content (fight checklist + DPS chart + chat) can
    -- run long, so a bigger default than the original 440x560 is worth
    -- offering without hardcoding one size for everyone.
    g.settings.reviewWindow = g.settings.reviewWindow or {}
    -- Same idea for width: exactly 440 was the old default, so it moves to
    -- the new 550.
    if not g.settings.reviewWindow.width or g.settings.reviewWindow.width == 440 then
        g.settings.reviewWindow.width = 550
    end
    -- 560 was the old default; anyone still on exactly that never chose it,
    -- so they move to the new 700 default (a different value was a choice
    -- and is left alone).
    if not g.settings.reviewWindow.height or g.settings.reviewWindow.height == 560 then
        g.settings.reviewWindow.height = 700
    end

    self.db = { global = g }
    self:RegisterChatCommand("aj", "SlashCommand")
    self:RegisterChatCommand("alliesjournal", "SlashCommand")
    self:RegisterChatCommand("journal", "SlashCommand")
    -- The old /pr, so nothing breaks for anyone used to it (undocumented).
    self:RegisterChatCommand("pr", "SlashCommand")

    local playerCount, reviewCount, sessionCount = 0, 0, 0
    for _ in pairs(self.db.global.players) do playerCount = playerCount + 1 end
    for _ in pairs(self.db.global.reviews) do reviewCount = reviewCount + 1 end
    for _ in pairs(self.db.global.sessions) do sessionCount = sessionCount + 1 end

    self:Print(string.format(
        "Loaded %d player(s), %d notes, %d session(s) from SavedVariables.", playerCount, reviewCount, sessionCount))

    self:RegisterEvent("WHO_LIST_UPDATE", "OnWhoListUpdate")
    -- Recent Allies events: pcall'd since registering an event this
    -- client doesn't know throws. UPDATED retries pins that didn't stick;
    -- DATA_READY triggers the once-per-session catch-up below.
    pcall(self.RegisterEvent, self, "RECENT_ALLY_DATA_UPDATED", "OnRecentAllyUpdated")
    pcall(self.RegisterEvent, self, "RECENT_ALLIES_DATA_READY", "OnRecentAlliesReady")
    C_Timer.After(25, function() self:OnRecentAlliesReady() end)
end

function AlliesJournal:OnEnable()
    self:Print("loaded. Type /aj to open your journal, or /aj help for all commands.")
end

-- Debug dumps and fake-data generators: kept, but only usable with
-- developer tools on, so they don't clutter the normal command list.
local DEV_COMMANDS = {
    test = true,
    testgroup = true,
    testbatch = true,
    capturesave = true,
    capturereplay = true,
    menudebug = true,
    namedebug = true,
    inspect = true,
    findname = true,
    findtext = true,
    inspectframe = true,
    lfgdebug = true,
    lfgapi = true,
    lfgapi2 = true,
    lfginspect = true,
    dump = true,
    capturedebug = true,
    capturestate = true,
    recentallies = true,
    recentallydebug = true,
    allyinfo = true,
    badgetest = true,
    export = true,
    import = true,
}

function AlliesJournal:SlashCommand(input)
    input = strtrim(input or "")
    local cmd, rest = input:match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if DEV_COMMANDS[cmd] and not self.db.global.settings.developerTools then
        self:Print("Unknown command. /aj help lists what's available.")
        return
    end

    if cmd == "dev" then
        local settings = self.db.global.settings
        settings.developerTools = not settings.developerTools
        self:Print("Developer tools " .. (settings.developerTools and "ON - /aj help lists the extra commands." or "off."))
    elseif cmd == "" or cmd == "browse" then
        self:GetModule("Browser"):Toggle()
    elseif cmd == "test" then
        self:QueueTestReview()
    elseif cmd == "testgroup" then
        self:QueueTestGroupReview()
    elseif cmd == "testbatch" then
        self:QueueTestBatch()
    elseif cmd == "capturesave" then
        self:GetModule("ReviewCapture"):SaveFightsForReplay(rest)
    elseif cmd == "capturereplay" then
        self:GetModule("Export"):ShowCaptureReplay()
    elseif cmd == "queue" then
        self:QueueUnitForReview(rest ~= "" and rest or "target")
    elseif cmd == "queuename" then
        self:QueueNameForReview(rest)
    elseif cmd == "gate" then
        self:HandleGateCommand(rest)
    elseif cmd == "menudebug" then
        local tooltip = self:GetModule("Tooltip")
        tooltip.menuDebug = not tooltip.menuDebug
        self:Print("Menu debug " .. (tooltip.menuDebug and "ON - right-click any player and check chat for the tag name." or "off."))
    elseif cmd == "namedebug" then
        local tooltip = self:GetModule("Tooltip")
        tooltip.nameDebug = not tooltip.nameDebug
        self:Print("Name recolor debug " .. (tooltip.nameDebug and "ON - look at a journaled player's nameplate/frame and check chat." or "off."))
    elseif cmd == "inspect" then
        self:GetModule("Tooltip"):InspectNameplate(rest)
    elseif cmd == "findname" then
        self:GetModule("Tooltip"):FindNameText(rest)
    elseif cmd == "findtext" then
        self:GetModule("Tooltip"):FindText(rest)
    elseif cmd == "inspectframe" then
        self:GetModule("Tooltip"):InspectFrame(rest)
    elseif cmd == "lfgdebug" then
        local lfg = self:GetModule("LFGAnnotate")
        lfg.debug = not lfg.debug
        self:Print("LFG debug " .. (lfg.debug and "ON - open Group Finder and check chat for scan results." or "off."))
    elseif cmd == "lfgapi" then
        self:GetModule("LFGAnnotate"):InspectAPI()
    elseif cmd == "lfgapi2" then
        self:GetModule("LFGAnnotate"):InspectAPI2()
    elseif cmd == "lfginspect" then
        self:GetModule("LFGAnnotate"):InspectRow(rest)
    elseif cmd == "dump" then
        self:DumpGlobalTable(rest)
    elseif cmd == "export" then
        self:GetModule("Export"):ShowExport()
    elseif cmd == "import" then
        self:GetModule("Export"):ShowImport()
    elseif cmd == "lfgoffset" then
        local tooltipSettings = self.db.global.settings.tooltip
        if rest == "" then
            self:Print(string.format("LFG tooltip offset is x=%d, y=%d. (Also editable via /aj options.)", tooltipSettings.lfgOffsetX, tooltipSettings.lfgOffsetY))
        else
            local x, y = rest:match("^(%-?%d+)%s+(%-?%d+)$")
            x, y = tonumber(x), tonumber(y)
            if not x or not y then
                self:Print("Usage: /aj lfgoffset <x> <y>")
            else
                tooltipSettings.lfgOffsetX, tooltipSettings.lfgOffsetY = x, y
                self:Print(string.format("LFG tooltip offset set to x=%d, y=%d. Hover a journal row to see it.", x, y))
            end
        end
    elseif cmd == "options" or cmd == "config" then
        self:GetModule("Options"):Show()
    elseif cmd == "stats" then
        self:PrintStorageStats()
    elseif cmd == "capturedebug" then
        local capture = self:GetModule("ReviewCapture")
        capture.debug = not capture.debug
        self:Print("Damage meter capture debug " .. (capture.debug and "ON - fight something and check chat for what C_DamageMeter returns." or "off."))
    elseif cmd == "capturestate" then
        self:GetModule("ReviewCapture"):DumpState()
    elseif cmd == "recentallies" then
        self:DumpRecentAllies()
    elseif cmd == "runs" then
        self:GetModule("Diary"):ShowRuns()
    elseif cmd == "numbers" then
        self:GetModule("Diary"):ShowNumbers()
    elseif cmd == "minimap" then
        local mm = self.db.global.settings.minimap
        mm.hide = not mm.hide
        self:GetModule("MinimapButton"):Refresh()
        self:Print("Minimap button " .. (mm.hide and "hidden (/aj minimap shows it again)." or "shown."))
    elseif cmd == "recentallydebug" then
        self.recentAllyDebug = not self.recentAllyDebug
        self:Print("Recent Allies sync debug " .. (self.recentAllyDebug and "ON - save/edit a note and check chat for what SetRecentAllyPinned/SetRecentAllyNote actually returned." or "off."))
    elseif cmd == "allyinfo" then
        self:DumpRecentAllyDetails(rest)
    elseif cmd == "badgetest" then
        self:GetModule("Tooltip"):ToggleBadgeTest()
    elseif cmd == "pinjournal" then
        self:PinReviewedAllies()
    elseif cmd == "resyncrecentallies" then
        self:ResyncAllRecentAllies()
    else
        self:Print("Usage:")
        self:Print("  /aj - open your journal")
        self:Print("  /aj queue [unit] - force-queue a real note for a unit (default: target), skipping the time gate")
        self:Print("  /aj queuename <Name> or <Name-Realm> - queue a note by name alone, for players you can't target (e.g. an LFG listing)")
        self:Print("  /aj gate [minutes] - show or set the grouped-time gate (set to 0 to test real triggers instantly)")
        self:Print("  /aj lfgoffset [x y] - show or set the Group Finder tooltip's x/y offset live")
        self:Print("  /aj options (or /aj config) - open the settings window")
        self:Print("  /aj stats - print the per-category storage size breakdown (chat/meter/sessions/notes) without opening the browser")
        self:Print("  /aj runs - your recorded runs, with who was there and a note for each")
        self:Print("  /aj numbers - your journal in numbers")
        self:Print("  /aj minimap - show or hide the minimap button")
        self:Print("  /aj pinjournal - pin every player with a note who isn't pinned in Recent Allies yet (skips anyone marked 'Not for me' or 'Struggled' unless that's turned on in /aj options)")
        self:Print("  /aj resyncrecentallies - re-applies the pin/note to every journaled player's C_RecentAllies entry using their latest note, for notes saved before the name-based GUID fallback existed")
        if self.db.global.settings.developerTools then
            self:Print("Developer tools (/aj dev turns these off):")
            self:Print("  /aj export - show all note data as copyable text, to back them up")
            self:Print("  /aj import - paste back a previous /aj export; merges in, never overwrites existing data")
            self:Print("  /aj test - queue a fake note window, no group needed (tests the UI only)")
            self:Print("  /aj testgroup - like /aj test but with 3 fake fights and 4 fake group members, to test the fight checklist and DPS bar chart without needing anyone else")
            self:Print("  /aj testbatch - queue three fake players at once, to try the group window (developer experiment)")
            self:Print("  /aj capturesave [unit] - save real captured fight data for a unit (default: target) as copyable text, to replay later via /aj capturereplay")
            self:Print("  /aj capturereplay - paste back a previous /aj capturesave and open a note window using that exact real data, for repeated UI testing")
            self:Print("  /pr menudebug - toggle printing every right-click menu tag seen, to debug the context menu button")
            self:Print("  /pr namedebug - toggle printing what the name-recolor hook sees, to debug the floating name color")
            self:Print("  /pr lfgdebug - toggle printing Group Finder scan results (rows found, matches, badges shown)")
            self:Print("  /aj lfgapi - dump what C_LFGList.GetSearchResults/GetSearchResultInfo/GetSearchResultMembers return, with a Group Finder search active")
            self:Print("  /aj lfgapi2 - deeper C_LFGList probe using the real function names (GetSearchResultPlayerInfo, GetSearchResultMemberCounts, etc.) into a copyable window")
            self:Print("  /aj lfginspect [row#] - dump every FontString and readable field found on a visible Group Finder row (default row 1), to check for group-member data beyond the poster's name")
            self:Print("  /aj dump <GlobalTableName> - dump every key + value type from any global table (e.g. /aj dump C_LFGList) into a copyable window, for exploring unfamiliar APIs on this client")
            self:Print("  /pr capturedebug - toggle live logging of what C_DamageMeter returns during combat, to debug missing DPS/HPS")
            self:Print("  /aj capturestate - dump currently-held capture state (snapshots + combat seconds) into a copyable window")
            self:Print("  /aj inspect [unit] - dump a unit's nameplate frame structure, if it has one (default: target)")
            self:Print("  /aj findname [unit] - scan all frames for the floating name text itself, wherever it lives (default: target)")
            self:Print("  /aj findtext <text> - like findname, but for text not tied to a unit (e.g. a Group Finder listing name)")
            self:Print("  /aj inspectframe <GlobalFrameName> - dump a named frame's regions, e.g. TargetFrame, CompactPartyFrameMember1")
            self:Print("  /aj recentallies - dump C_RecentAllies system status + every cached entry, and cross-check it against your players with notes, into a copyable window")
            self:Print("  /pr recentallydebug - toggle live logging of what SetRecentAllyPinned/SetRecentAllyNote actually return when a review is saved, to debug a pin/note that isn't sticking")
            self:Print("  /aj allyinfo [name] - dump EVERYTHING Recent Allies knows about a player (every interaction with its type, location, difficulty, item, plus raw data) into a copyable window; defaults to the selected player or your target")
            self:Print("  /aj badgetest - toggle a fake badge on every party/raid frame found, to check placement without a group")
        end
    end
end

function AlliesJournal:PrintStorageStats()
    local s = self:GetStorageStats()
    self:Print(string.format("%d player(s), %d session(s), %d notes.",
        s.playerCount, s.sessionCount, s.reviewCount))
    self:Print(string.format("Chat %s | Sessions %s | Notes %s | Players %s | Total %s",
        self:FormatBytes(s.chatBytes), self:FormatBytes(s.sessionsBytes),
        self:FormatBytes(s.reviewsBytes), self:FormatBytes(s.playersBytes), self:FormatBytes(s.totalBytes)))
end

-- One-shot catch-up for reviews saved before ReviewPrompt's Save()
-- gained the FindRecentAllyGUID fallback - those never had a GUID to
-- pin/note with at the time, so this re-applies each reviewed player's
-- LATEST review now that a name-based lookup exists. Only finds someone
-- who's already a recognized recent ally; someone never encountered
-- (or who's since aged out of Blizzard's 89-day window) still can't be
-- found this way.
-- Once per session, quietly pins any reviewed player who's a known recent
-- ally but isn't pinned yet - self-heals reviews saved while the pin
-- couldn't stick. Runs on RECENT_ALLIES_DATA_READY, or after 25s if that
-- already fired before we registered.
function AlliesJournal:OnRecentAlliesReady()
    if self.autoResyncDone then return end
    self.autoResyncDone = true
    C_Timer.After(3, function() self:ResyncAllRecentAllies(true, true) end)
end

function AlliesJournal:ResyncAllRecentAllies(quiet, onlyUnpinned)
    local total, synced = 0, 0
    for _, record in ipairs(self:GetAllPlayers()) do
        total = total + 1
        local review = self:GetLatestReview(record.nameRealm)
        if review then
            local guid = self:FindRecentAllyGUID(record.nameRealm)
            if guid and not (onlyUnpinned and self:IsRecentAllyPinned(guid)) then
                self:SyncRecentAlly(guid, review, record.nameRealm, quiet)
                synced = synced + 1
            end
        end
    end
    if not quiet then
        self:Print(string.format("Resynced %d of %d player(s) with notes to Recent Allies (the rest have no matching Recent Allies entry right now).", synced, total))
    end
end

-- Dumps everything C_RecentAllies has on a player, for finding out which
-- fields are worth surfacing: character/state data, every interaction
-- (readable type name, description, timestamp, and the full contextData),
-- the note, and finally the entire raw record. Matches by (partial,
-- case-insensitive) name against fullName; with no name it uses the player
-- selected in /pr, else your target.
function AlliesJournal:DumpRecentAllyDetails(query)
    if not C_RecentAllies then
        self:Print("C_RecentAllies doesn't exist on this client.")
        return
    end
    query = strtrim(query or "")
    if query == "" then
        local selected = self:GetModule("Browser").selectedNameRealm
        if selected then
            query = self:GetShortName(selected)
        elseif UnitExists("target") then
            query = UnitName("target") or ""
        end
    end
    if query == "" then
        self:Print("Usage: /aj allyinfo <name> (or select a player in /aj, or target someone)")
        return
    end

    local ok, list = pcall(C_RecentAllies.GetRecentAllies)
    if not ok or not list then
        self:Print("GetRecentAllies() failed.")
        return
    end

    local rolodexNames = {}
    for key, value in pairs(Enum.RolodexType or {}) do rolodexNames[value] = key end

    local needle = query:lower()
    local lines, matches = {}, 0
    for _, ally in ipairs(list) do
        local char = ally.characterData or {}
        if char.fullName and char.fullName:lower():find(needle, 1, true) then
            matches = matches + 1
            table.insert(lines, string.format("=== %s (level %s, classID %s, raceID %s) ===",
                tostring(char.fullName), tostring(char.level), tostring(char.classID), tostring(char.raceID)))
            table.insert(lines, "character: " .. self:Serialize(char))
            table.insert(lines, "state: " .. self:Serialize(ally.stateData or {}))
            table.insert(lines, "note: " .. tostring(ally.interactionData and ally.interactionData.note))

            local interactions = {}
            for _, interaction in ipairs(ally.interactionData and ally.interactionData.interactions or {}) do
                table.insert(interactions, interaction)
            end
            table.sort(interactions, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
            table.insert(lines, string.format("interactions (%d, newest first):", #interactions))
            for _, interaction in ipairs(interactions) do
                table.insert(lines, string.format("  [%s] type=%s(%s) description=%q",
                    date("%Y-%m-%d %H:%M", interaction.timestamp or 0),
                    tostring(rolodexNames[interaction.type] or "?"), tostring(interaction.type),
                    tostring(interaction.description)))
                table.insert(lines, "      contextData: " .. self:Serialize(interaction.contextData or {}))
            end

            table.insert(lines, "")
            table.insert(lines, "raw record:")
            table.insert(lines, self:Serialize(ally))
            table.insert(lines, "")
        end
    end

    if matches == 0 then
        self:Print(string.format("No Recent Allies entry matches '%s'.", query))
        return
    end
    self:GetModule("Export"):ShowText("Recent Ally: " .. query, table.concat(lines, "\n"))
end

-- Pins every reviewed player who isn't pinned in Recent Allies yet, except
-- anyone whose latest review is bad (either rating) - those aren't worth
-- keeping on the 89-day pin list. Reports what it did, including players
-- Blizzard has no Recent Allies entry for (nothing to pin until they have
-- one). Pins that don't stick right away are retried by SyncRecentAlly.
function AlliesJournal:PinReviewedAllies()
    local pinned, queued, alreadyPinned, skippedBad, notKnown = 0, 0, 0, 0, 0
    for _, record in ipairs(self:GetAllPlayers()) do
        local review = self:GetLatestReview(record.nameRealm)
        if review then
            if not self:ShouldPinReview(review) then
                skippedBad = skippedBad + 1
            else
                local guid = self:FindRecentAllyGUID(record.nameRealm)
                if not guid then
                    notKnown = notKnown + 1
                elseif self:IsRecentAllyPinned(guid) then
                    alreadyPinned = alreadyPinned + 1
                else
                    if self:SyncRecentAlly(guid, review, record.nameRealm, true) then
                        pinned = pinned + 1
                    else
                        queued = queued + 1
                    end
                end
            end
        end
    end
    self:Print(string.format(
        "Pin journal: %d pinned, %d still retrying, %d already pinned, %d skipped (marked Not for me / Struggled), %d not in Recent Allies.",
        pinned, queued, alreadyPinned, skippedBad, notKnown))
end

-- Queues a fully synthetic review prompt. No group, no target, no real data
-- involved - just exercises ReviewPrompt's UI, validation, and Save/Skip
-- flow (and writes a real DB entry for "Testmann-<yourrealm>" on Save, same
-- as any other review).
function AlliesJournal:QueueTestReview()
    self:GetModule("ReviewPrompt"):QueueBatch({
        {
            nameRealm = "Testmann-" .. GetRealmName(),
            encounter = "Test Encounter",
            role = "tank",
            fights = { { duration = 60, dps = 123456, hps = 0 } },
        },
    })
end

-- Same purpose as QueueTestReview (exercise the UI with no group/target
-- needed) but with multiple fake fights, each carrying a fake
-- groupBreakdown of several other "players" - the fight checklist and
-- the group DPS bar chart both need more than one fight/one member to
-- actually be worth looking at, and neither can be tested solo any other
-- way without asking someone else to group up. Numbers are randomized
-- (not fixed) so re-running this gives a fresh mix each time, closer to
-- what real variance looks like.
-- Three fake players at once, each with their own fights and chat, to try the
-- group window (the "strip" developer option) without a real dungeon.
function AlliesJournal:QueueTestBatch()
    local realm = GetRealmName()
    local members = {
        { guid = "Fake-1", nameRealm = "Testmann-" .. realm, class = "WARRIOR", role = "tank" },
        { guid = "Fake-2", nameRealm = "Fakename Two-" .. realm, class = "MAGE", role = "dps" },
        { guid = "Fake-3", nameRealm = "Fakename Three-" .. realm, class = "PRIEST", role = "healer" },
        { guid = "Fake-4", nameRealm = "Fakename Four-" .. realm, class = "ROGUE", role = "dps" },
    }
    local fightNames = { "Elder Mottled Boar", "Bloodtalon Taillasher", "Deviate Slayer" }
    local chatLog = self:GetModule("ChatLog")
    local list = {}
    for index = 1, 3 do
        local subject = members[index]
        local fights = {}
        for f = 1, 3 do
            local breakdown = {}
            for _, m in ipairs(members) do
                table.insert(breakdown, { guid = m.guid, nameRealm = m.nameRealm, dps = math.random(200, 900) + math.random(),
                    hps = 0, class = m.class, role = m.role })
            end
            table.sort(breakdown, function(a, b) return a.dps > b.dps end)
            local rank, dps, total = nil, nil, 0
            for r, m in ipairs(breakdown) do
                total = total + m.dps
                if m.guid == subject.guid then rank, dps = r, m.dps end
            end
            table.insert(fights, {
                duration = 15 + math.random(0, 30), dps = dps, hps = 0, dpsRank = rank, groupDpsCount = #breakdown,
                groupMaxDps = breakdown[1].dps, groupTotalDps = total, groupBreakdown = breakdown, name = fightNames[f],
            })
        end
        chatLog.messages[subject.guid] = nil
        chatLog:AppendMessage(subject.guid, "Party", "gg, thanks for the run", "them")
        chatLog:AppendMessage(subject.guid, "Party", "thanks!", "self")
        list[index] = { nameRealm = subject.nameRealm, encounter = "Test Dungeon", role = subject.role, guid = subject.guid, fights = fights }
    end
    self:GetModule("ReviewPrompt"):QueueBatch(list)
end

function AlliesJournal:QueueTestGroupReview()
    local myRealm = GetRealmName()
    local fakeMembers = {
        { guid = "Fake-1", nameRealm = "Testmann-" .. myRealm, class = "WARRIOR", role = "tank" },
        { guid = "Fake-2", nameRealm = "Fakename Two-" .. myRealm, class = "MAGE", role = "dps" },
        { guid = "Fake-3", nameRealm = "Fakename Three-" .. myRealm, class = "PRIEST", role = "healer" },
        { guid = "Fake-4", nameRealm = "Fakename Four-" .. myRealm, class = "ROGUE", role = "dps" },
    }
    local reviewedGuid = fakeMembers[1].guid
    local reviewedName = fakeMembers[1].nameRealm

    local fakeFightNames = { "Elder Mottled Boar", "Bloodtalon Taillasher", "Deviate Slayer" }

    local fights = {}
    for f = 1, 3 do
        local duration = 15 + math.random(0, 30)
        local breakdown = {}
        for _, member in ipairs(fakeMembers) do
            table.insert(breakdown, {
                guid = member.guid,
                nameRealm = member.nameRealm,
                dps = math.random(200, 900) + math.random(),
                hps = 0,
                class = member.class,
                role = member.role,
            })
        end
        table.sort(breakdown, function(a, b) return a.dps > b.dps end)

        local reviewedDps, reviewedRank
        for rank, m in ipairs(breakdown) do
            if m.guid == reviewedGuid then
                reviewedDps, reviewedRank = m.dps, rank
                break
            end
        end

        local groupTotalDps = 0
        for _, m in ipairs(breakdown) do
            groupTotalDps = groupTotalDps + (m.dps or 0)
        end

        table.insert(fights, {
            duration = duration,
            dps = reviewedDps,
            hps = 0,
            dpsRank = reviewedRank,
            groupDpsCount = #breakdown,
            groupMaxDps = breakdown[1].dps,
            groupTotalDps = groupTotalDps,
            groupBreakdown = breakdown,
            name = fakeFightNames[f],
        })
    end

    -- Fake chat, filed directly on the ChatLog buffer this fake guid
    -- shares with AddChatLogSection - a real review always has a guid
    -- (set by RosterTracker) and whatever chat happened to accumulate for
    -- it, so this emulates that instead of leaving the prompt's chat
    -- section empty for synthetic test data.
    local chatLog = self:GetModule("ChatLog")
    chatLog:AppendMessage(reviewedGuid, "Party", "gj on the boar pull", "self")
    chatLog:AppendMessage(reviewedGuid, "Party", "ty, that add phase was rough", "them")
    chatLog:AppendMessage(reviewedGuid, "Party", "ready for next pull whenever", "them")

    self:GetModule("ReviewPrompt"):QueueBatch({
        {
            nameRealm = reviewedName,
            encounter = "Test Encounter (synthetic group)",
            role = "dps",
            guid = reviewedGuid,
            fights = fights,
        },
    })
end

-- Loads a previously /pr capturesave'd fight-data blob and queues a
-- review prompt using that EXACT real data - lets a real captured
-- scenario (actual DPS numbers, actual group members) be replayed
-- repeatedly for UI testing without needing to regroup with anyone.
function AlliesJournal:ReplayCapturedFights(text)
    text = text and strtrim(text) or ""
    if text == "" then
        self:Print("No data pasted.")
        return
    end

    local loader = loadstring or load
    local chunk, err = loader(text)
    if not chunk then
        self:Print("Couldn't parse (" .. tostring(err) .. ") - make sure the full /aj capturesave text was pasted.")
        return
    end
    if setfenv then setfenv(chunk, {}) end  -- pasted data only, no globals

    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.fights) ~= "table" then
        self:Print("Pasted text didn't evaluate to valid captured fight data.")
        return
    end

    self:GetModule("ReviewPrompt"):QueueBatch({
        {
            nameRealm = data.nameRealm or ("ReplayTest-" .. GetRealmName()),
            encounter = "Replayed capture",
            role = data.role,
            fights = data.fights,
        },
    })
end

-- Force-queues a review for a real unit (party/raid member, target,
-- mouseover, ...), bypassing the groupedSince time gate entirely. Reads role
-- and any fights captured so far the same way the real triggers do, so this
-- exercises the actual capture pipeline without waiting on it.
function AlliesJournal:QueueUnitForReview(unit)
    if not UnitExists(unit) then
        self:Print("No such unit: " .. unit)
        return
    end
    if not UnitIsPlayer(unit) then
        self:Print(unit .. " is not a player.")
        return
    end

    local capture = self:GetModule("ReviewCapture")
    local guid = UnitGUID(unit)

    self:GetModule("ReviewPrompt"):QueueBatch({
        {
            nameRealm = self:GetFullName(unit),
            encounter = self:GetModule("RosterTracker").currentEncounterName or GetInstanceInfo() or "Manual test",
            role = capture:GetRole(unit),
            fights = guid and capture:GetFights(guid) or {},
            guid = guid,
        },
    })
end

-- Queues a review from a plain name string rather than a unit - for players
-- you can't target at all, like an LFG listing entry. No role, no meter
-- snapshot (nothing to read from a unit that doesn't exist as far as the
-- game is concerned), no gate, no guid, so nothing to base a chat-log
-- recap on either - just the name and manual rating/notes.
--
-- Runs a /who first to confirm the name is a real player before queuing -
-- catches typos from copying a name off an LFG listing. This warns rather
-- than blocks on a miss: /who can legitimately miss a real player (server
-- throttling, connected-realm quirks, them going offline mid-lookup), so a
-- failed lookup isn't strong enough evidence to refuse the review outright.
function AlliesJournal:QueueNameForReview(nameRealm)
    nameRealm = strtrim(nameRealm or "")
    if nameRealm == "" then
        self:Print("Usage: /aj queuename <Name> or <Name-Realm>")
        return
    end

    nameRealm = self:NormalizeChatSender(nameRealm)
    local shortName = self:GetShortName(nameRealm)

    self.pendingWhoNameRealm = nameRealm
    self.pendingWhoShortName = shortName

    local ok = pcall(function()
        if C_FriendList and C_FriendList.SendWho then
            C_FriendList.SendWho(shortName)
        else
            SendWho(shortName)
        end
    end)

    if not ok then
        self:Print("Couldn't run /who on this client - queuing " .. shortName .. " without verification.")
        self.pendingWhoNameRealm = nil
        self:DoQueueNameForReview(nameRealm)
        return
    end

    self:Print("Looking up " .. shortName .. " via /who...")
    C_Timer.After(5, function()
        if self.pendingWhoNameRealm ~= nameRealm then return end  -- already resolved by OnWhoListUpdate
        self:Print("No /who response for " .. shortName .. " after 5s (throttled, offline, or wrong name?) - queuing anyway.")
        self.pendingWhoNameRealm = nil
        self:DoQueueNameForReview(nameRealm)
    end)
end

function AlliesJournal:OnWhoListUpdate()
    local nameRealm = self.pendingWhoNameRealm
    if not nameRealm then return end
    local shortName = self.pendingWhoShortName

    local found = false
    local ok, numResults = pcall(function()
        if C_FriendList and C_FriendList.GetNumWhoResults then
            return (C_FriendList.GetNumWhoResults())
        end
        return GetNumWhoResults()
    end)

    if ok and numResults and numResults > 0 then
        for i = 1, numResults do
            local name
            local okInfo, info = pcall(function()
                return C_FriendList and C_FriendList.GetWhoInfo and C_FriendList.GetWhoInfo(i)
            end)
            if okInfo and type(info) == "table" then
                name = info.fullName or info.name
            else
                local okOld, oldName = pcall(GetWhoInfo, i)
                if okOld then name = oldName end
            end
            if name and (name == shortName or self:NormalizeChatSender(name) == nameRealm) then
                found = true
                break
            end
        end
    end

    self.pendingWhoNameRealm = nil
    self:Print(found
        and (shortName .. " confirmed via /who.")
        or (shortName .. " not found via /who (offline, wrong name, or a connected-realm quirk) - queuing anyway."))
    self:DoQueueNameForReview(nameRealm)
end

function AlliesJournal:DoQueueNameForReview(nameRealm)
    self:GetModule("ReviewPrompt"):QueueBatch({
        {
            nameRealm = nameRealm,
            encounter = "Manual",
            role = nil,
        },
    })
end

-- The real gate defaults to 10 minutes grouped-together before a leave/kick
-- or instance-complete trigger will queue a prompt. Set it to 0 (or a small
-- decimal, e.g. 0.1 for ~6 seconds) to test the actual GROUP_ROSTER_UPDATE /
-- CHALLENGE_MODE_COMPLETED / dungeon-exit triggers without a real wait.
-- Generic table dump for ad-hoc API exploration (e.g. /pr dump C_LFGList),
-- not scoped to LFG specifically - useful whenever this client's actual
-- API surface for something needs checking rather than assuming. Prints
-- into a copyable window (Export module) rather than chat, since a table
-- can easily have more keys than are practical to read off scrolling chat
-- output or capture in a screenshot.
function AlliesJournal:DumpGlobalTable(name)
    name = strtrim(name or "")
    if name == "" then
        self:Print("Usage: /aj dump <GlobalTableName> (e.g. /aj dump C_LFGList)")
        return
    end

    local t = _G[name]
    if type(t) ~= "table" then
        self:Print(name .. " is not a table (or doesn't exist) on this client: " .. tostring(t))
        return
    end

    local keys = {}
    for k in pairs(t) do
        table.insert(keys, tostring(k))
    end
    table.sort(keys)

    local lines = { string.format("-- %s (%d keys)", name, #keys) }
    for _, k in ipairs(keys) do
        table.insert(lines, k .. " = " .. type(t[k]))
    end

    self:GetModule("Export"):ShowText(name, table.concat(lines, "\n"))
end

-- Diagnostic for the "not recent" false-negative reported in Browser: dumps
-- the raw system status + every cached RecentAllies entry (guid, name,
-- fullName, realmName, online/pinned/note state), then cross-checks each
-- REVIEWED player against that list using the exact short-name match
-- Browser.lua's FindRecentAlly uses, so a mismatch is directly visible
-- rather than guessed at.
function AlliesJournal:DumpRecentAllies()
    if not C_RecentAllies then
        self:Print("C_RecentAllies doesn't exist on this client.")
        return
    end

    local lines = {}
    local okEnabled, enabled = pcall(C_RecentAllies.IsSystemEnabled)
    local okSupported, supported = pcall(C_RecentAllies.IsSystemSupported)
    local okReadyBefore, readyBefore = pcall(C_RecentAllies.IsRecentAllyDataReady)
    table.insert(lines, string.format("IsSystemEnabled: %s", tostring(okEnabled and enabled)))
    table.insert(lines, string.format("IsSystemSupported: %s", tostring(okSupported and supported)))
    table.insert(lines, string.format("IsRecentAllyDataReady: %s", tostring(okReadyBefore and readyBefore)))
    -- TryRequestRecentAlliesData is NOT called here - confirmed protected
    -- (HasRestrictions, not AllowedWhenUntainted): calling it from here
    -- threw ADDON_ACTION_FORBIDDEN even wrapped in pcall, which doesn't
    -- catch a taint violation the way it catches a normal Lua error.
    -- IsRecentAllyDataReady was already true without ever calling it, so
    -- it isn't needed anyway.

    local okList, list = pcall(C_RecentAllies.GetRecentAllies)
    table.insert(lines, "")
    if not okList or not list then
        table.insert(lines, "GetRecentAllies() call failed or returned nil.")
    else
        table.insert(lines, string.format("GetRecentAllies() returned %d entries:", #list))
        for _, allyData in ipairs(list) do
            local c = allyData.characterData or {}
            local s = allyData.stateData or {}
            local i = allyData.interactionData or {}
            local okPinned, pinned = pcall(C_RecentAllies.IsRecentAllyPinned, c.guid)
            table.insert(lines, string.format(
                "guid=%s name=%s fullName=%s realmName=%s online=%s pinned=%s pinExpires=%s interactions=%d note=%s",
                tostring(c.guid), tostring(c.name), tostring(c.fullName), tostring(c.realmName),
                tostring(s.isOnline), tostring(okPinned and pinned), tostring(s.pinExpirationDate),
                (i.interactions and #i.interactions or 0), tostring(i.note)))
        end
    end

    table.insert(lines, "")
    table.insert(lines, "-- Cross-check against players with notes (short-name match, same as Browser.lua) --")
    for _, record in ipairs(self:GetAllPlayers()) do
        local shortName = self:GetShortName(record.nameRealm)
        local found = false
        if okList and list then
            for _, allyData in ipairs(list) do
                local c = allyData.characterData
                if c and c.fullName and shortName and c.fullName:lower() == shortName:lower() then
                    found = true
                    break
                end
            end
        end
        table.insert(lines, string.format("%s (short name used for matching: %s) -> %s",
            record.nameRealm, tostring(shortName), found and "MATCH" or "no match"))
    end

    self:GetModule("Export"):ShowText("Recent Allies Debug", table.concat(lines, "\n"))
end

function AlliesJournal:HandleGateCommand(rest)
    if rest == "" then
        self:Print("Gate is currently " .. self.db.global.settings.gateMinutes .. " minute(s).")
        return
    end

    local minutes = tonumber(rest)
    if not minutes or minutes < 0 then
        self:Print("Usage: /aj gate <minutes>")
        return
    end

    self.db.global.settings.gateMinutes = minutes
    self:Print("Gate set to " .. minutes .. " minute(s).")
end
