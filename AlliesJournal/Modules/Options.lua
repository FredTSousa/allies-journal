local addon = AlliesJournal
local Options = addon:NewModule("Options")
local AceGUI = LibStub("AceGUI-3.0")

local ANCHOR_POINTS = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }
local ANCHOR_LABELS = {
    TOPLEFT = "Top Left", TOP = "Top", TOPRIGHT = "Top Right",
    LEFT = "Left", CENTER = "Center", RIGHT = "Right",
    BOTTOMLEFT = "Bottom Left", BOTTOM = "Bottom", BOTTOMRIGHT = "Bottom Right",
}

local TEMPLATE_HELP = table.concat({
    "Color codes work directly - e.g. ||cffff0000red text||r for red (use || instead of | so it isn't rendered here).",
    " ",
    "Placeholders (used as {name}):",
    "  {socialLine} / {performanceLine} - whole lines for how it went (\"Social: Fine\", \"Perf: Strong\", or just \"How was it: Great\" for a simple note). A line containing only one of these is dropped when it is empty.",
    "  {social} / {performance} - just the colored word for each",
    "  {socialNote} / {performanceNote} - the text of the notes on it. A line containing ONLY one of these is dropped entirely when that note is empty.",
    "  {count} - how many notes this player has",
    "  {author} - who wrote the most recent note",
    "  {date} - that note's date (YYYY-MM-DD)",
    "  {encounter} - what was happening when it was written",
    "  {role} - the role recorded on it, if any",
    "  {roleIcon} - the tank/healer/DPS icon for that role (blank when there is none)",
    "  {memberNote} - Group Finder template ONLY. Blank when the player with a note is the group's leader/poster; otherwise \"Group member: Name\" for whichever other member matched (checked via the real group roster, not just the listing's poster).",
}, "\n")

-- Explanatory text is drawn in this muted color, always directly UNDER the
-- control it describes.
local MUTED = { 0.62, 0.62, 0.68 }
local DANGER = { 1, 0.38, 0.38 }

-- Rebuilds the open tab so it reflects changed values. Deferred a frame so
-- the button that asked for it is done before it is released. The scroll
-- position survives (see Options:Show).
local function Rebuild()
    C_Timer.After(0, function() Options:Show() end)
end

-- Settings are grouped into tabs, and each group into a titled section box.
-- A section is built completely BEFORE it's added to its parent, so the
-- parent lays it out at its real height (a container that grows after it
-- was added leaves whatever follows it overlapping).
-- danger = true marks a section of things that can't be undone (red title).
local function Section(parent, title, build, danger)
    local group = AceGUI:Create("InlineGroup")
    group:SetTitle(title)
    group:SetFullWidth(true)
    group:SetLayout("Flow")
    -- Same dark panel the /aj list sits on, so the sections read as
    -- panels on the window. InlineGroup is pooled: the texture is made
    -- once per widget and hidden again when the widget is released.
    local panel = group.frame.prPanel
    if not panel then
        panel = group.frame:CreateTexture(nil, "BACKGROUND")
        group.frame.prPanel = panel
    end
    local c = addon.db.global.settings.browserColors.list
    panel:SetPoint("TOPLEFT", group.frame, "TOPLEFT", 0, -17)
    panel:SetPoint("BOTTOMRIGHT", group.frame, "BOTTOMRIGHT", 0, 0)
    panel:SetColorTexture(c[1], c[2], c[3], c[4])
    panel:Show()
    local titleText = group.titletext
    if danger and titleText then
        titleText:SetTextColor(DANGER[1], DANGER[2], DANGER[3])
    end
    group:SetCallback("OnRelease", function()
        panel:Hide()
        -- back to the stock title color for whoever gets this widget next
        if danger and titleText then titleText:SetTextColor(1, 0.82, 0) end
    end)
    build(group)
    parent:AddChild(group)
end

-- Muted explanatory text under a control.
local function AddNote(container, text)
    local label = AceGUI:Create("Label")
    label:SetText(text)
    label:SetFullWidth(true)
    label:SetColor(MUTED[1], MUTED[2], MUTED[3])
    container:AddChild(label)
    return label
end

-- relWidth (0-1) places controls side by side in a section; omitted = full width.
local function SetWidthOf(widget, relWidth)
    if relWidth then
        widget:SetRelativeWidth(relWidth)
    else
        widget:SetFullWidth(true)
    end
end

local function AddSlider(container, label, min, max, step, get, set, relWidth)
    local slider = AceGUI:Create("Slider")
    slider:SetLabel(label)
    slider:SetSliderValues(min, max, step)
    slider:SetValue(get())
    SetWidthOf(slider, relWidth)
    slider:SetCallback("OnValueChanged", function(widget, event, value)
        set(value)
        Options:Refresh()
    end)
    container:AddChild(slider)
    return slider
end

-- AceGUI's checkbox repaints its description white whenever its value or
-- disabled state changes, so the muted color is put back after each.
local function TintDescription(cb)
    if cb.desc and not cb.disabled then
        cb.desc:SetTextColor(MUTED[1], MUTED[2], MUTED[3])
    end
end

-- A short label, with the longer explanation (desc, optional) under it.
local function AddCheckbox(container, label, desc, get, set)
    local cb = AceGUI:Create("CheckBox")
    cb:SetLabel(label)
    cb:SetValue(get() and true or false)
    cb:SetFullWidth(true)
    if desc then
        cb:SetDescription(desc)
        TintDescription(cb)
    end
    cb:SetCallback("OnValueChanged", function(widget, event, value)
        TintDescription(widget)
        set(value and true or false)
    end)
    container:AddChild(cb)
    return cb
end

local function AddDropdown(container, label, labels, order, get, set, relWidth)
    local dd = AceGUI:Create("Dropdown")
    dd:SetLabel(label)
    dd:SetList(labels, order)
    dd:SetValue(get())
    SetWidthOf(dd, relWidth)
    dd:SetCallback("OnValueChanged", function(widget, event, value)
        set(value)
        Options:Refresh()
    end)
    container:AddChild(dd)
    return dd
end

-- set may return false (and a reason) to refuse the text: the box then goes
-- back to the saved value and the reason is printed, instead of leaving
-- rejected text sitting in the box as if it had been saved.
local function AddTextInput(container, label, get, set, relWidth)
    local box = AceGUI:Create("EditBox")
    box:SetLabel(label)
    SetWidthOf(box, relWidth)
    box:SetText(get() or "")
    box:SetCallback("OnEnterPressed", function(widget, event, text)
        local ok, why = set(text)
        if ok == false then
            widget:SetText(get() or "")
            if why then addon:Print(why) end
        end
        Options:Refresh()
    end)
    container:AddChild(box)
    return box
end

local function AddButton(container, text, width, onClick)
    local btn = AceGUI:Create("Button")
    btn:SetText(text)
    btn:SetWidth(width)
    btn:SetCallback("OnClick", onClick)
    container:AddChild(btn)
    return btn
end

-- Greys out controls that have no effect right now (their switch is off).
local function SetEnabled(widgets, enabled)
    for _, widget in ipairs(widgets) do
        widget:SetDisabled(not enabled)
        if widget.type == "CheckBox" then TintDescription(widget) end
    end
end

local LFG_ANCHOR_TARGETS = { "name", "frame", "classIcon", "resultBG" }
local LFG_ANCHOR_TARGET_LABELS = {
    name = "Name text (shifts between leader/member layout)",
    frame = "Row's own frame (stable)",
    classIcon = "Class icon (stable)",
    resultBG = "Row background (stable)",
}

-- A few known Blizzard textures worth trying as a starting point - not a
-- guarantee any of these render well, just quick one-click fills so
-- testing different icons in-game doesn't require typing paths by hand.
local ICON_PRESETS = {
    { label = "Square", path = "", left = 0, right = 1, top = 0, bottom = 1 },
    { label = "Star", path = "Interface\\COMMON\\FavoritesIcon", left = 0.5, right = 1, top = 0, bottom = 1 },
    { label = "Ready Check", path = "Interface\\RaidFrame\\ReadyCheck-Ready", left = 0, right = 1, top = 0, bottom = 1 },
    { label = "Question Mark", path = "Interface\\Icons\\INV_Misc_QuestionMark", left = 0, right = 1, top = 0, bottom = 1 },
    { label = "Dot", path = "Interface\\COMMON\\Indicator-Gray", left = 0, right = 1, top = 0, bottom = 1 },
}

-- Size + two anchor corners + X/Y offset for one badge placement; the
-- two corner dropdowns and the two offsets sit side by side.
local function BuildBadgePlacement(group, s, prefix, anchorLabel, relLabel)
    AddSlider(group, "Size", 6, 64, 1,
        function() return s[prefix .. "Size"] end,
        function(v) s[prefix .. "Size"] = v end)
    AddDropdown(group, anchorLabel, ANCHOR_LABELS, ANCHOR_POINTS,
        function() return s[prefix .. "AnchorPoint"] end,
        function(v) s[prefix .. "AnchorPoint"] = v end, 0.5)
    AddDropdown(group, relLabel, ANCHOR_LABELS, ANCHOR_POINTS,
        function() return s[prefix .. "RelPoint"] end,
        function(v) s[prefix .. "RelPoint"] = v end, 0.5)
    AddSlider(group, "Offset X", -200, 200, 1,
        function() return s[prefix .. "OffsetX"] end,
        function(v) s[prefix .. "OffsetX"] = v end, 0.5)
    AddSlider(group, "Offset Y", -200, 200, 1,
        function() return s[prefix .. "OffsetY"] end,
        function(v) s[prefix .. "OffsetY"] = v end, 0.5)
end

-- Re-applies current settings to whatever's on screen right now, so
-- dragging a slider or picking a dropdown value shows its effect
-- immediately instead of needing a reload or waiting on LFGAnnotate's
-- next tick. Doesn't cover the tooltip template - GameTooltip only shows
-- on hover, so there's nothing on screen to refresh until then.
function Options:Refresh()
    pcall(function() addon:GetModule("Tooltip"):RefreshFrames() end)
    pcall(function() addon:GetModule("LFGAnnotate"):ScanBrowseResults() end)
end

--------------------------------------------------------------------------
-- Tab contents
--
-- Tabs follow what the player is trying to do, not which module owns the
-- setting: writing notes, being told things, where notes show up, and
-- what is kept on disk. Badges and Tooltips hold the fine-tuning.
--------------------------------------------------------------------------

-- Notes: writing a note, and when the window for it opens.
local function BuildNotes(scroll)
    local settings = addon.db.global.settings

    Section(scroll, "Writing a note", function(group)
        AddCheckbox(group, "Simple notes: one \"How was it?\" question",
            "Great / Fine / Not for me, with one note box and one set of quick tags, instead of Social and Performance. Only changes new notes: the ones you already wrote keep showing, and keep opening for editing, the way they were saved.",
            function() return settings.simpleNotes end,
            function(v) settings.simpleNotes = v end)
        AddCheckbox(group, "One window for the whole group",
            "At the end of a run, everyone goes in one window with a tab each, instead of a window per player.",
            function() return settings.playerStrip end,
            function(v) settings.playerStrip = v end)
        AddTextInput(group, "Thanks button message",
            function() return settings.thanksMessage end,
            function(v)
                if strtrim(v or "") == "" then
                    return false, "The Thanks message can't be empty, so the previous one was kept."
                end
                settings.thanksMessage = v
            end)
        AddNote(group, "{name} and {place} are filled in for you. Press Enter to save.")
    end)

    Section(scroll, "When the note window opens", function(group)
        AddNote(group, "After a dungeon, or when someone leaves your group, a note window opens for the people you were grouped with. These decide who it opens for. You can always right-click a name to write a note yourself.")
        AddSlider(group, "Only for players I was grouped with for at least (minutes)", 1, 60, 1,
            function() return settings.gateMinutes or 10 end,
            function(v) settings.gateMinutes = v end)
        AddNote(group, "Shorter than this, you only get a recap line in chat.")
        AddSlider(group, "Ask about the same player again after (hours)", 0, 72, 1,
            function() return settings.askAgainHours or 12 end,
            function(v) settings.askAgainHours = v end)
        AddNote(group, "Once you've been asked about someone, or written them a note, the window leaves them alone for this long, so a group you play with often doesn't come up after every dungeon. Their sessions are still recorded. 0 asks every time.")
        AddSlider(group, "Stop opening after this many notes on a player", 0, 20, 1,
            function() return settings.windowNoteLimit or 3 end,
            function(v) settings.windowNoteLimit = v end)
        AddNote(group, "After that you get a line in chat with an Add a note link instead, no more often than the wait above. Only notes you wrote count, not windows you skipped. 0 always opens the window.")
    end)

    Section(scroll, "Note window size", function(group)
        local reviewWindow = settings.reviewWindow
        AddSlider(group, "Width", 350, 900, 10,
            function() return reviewWindow.width end,
            function(v)
                reviewWindow.width = v
                addon:GetModule("ReviewPrompt"):ApplyWindowSize()
            end, 0.5)
        AddSlider(group, "Height", 400, 900, 10,
            function() return reviewWindow.height end,
            function(v)
                reviewWindow.height = v
                addon:GetModule("ReviewPrompt"):ApplyWindowSize()
            end, 0.5)
        AddNote(group, "Changes apply to an open note window right away.")
    end)
end

-- Alerts: everything the addon tells you on its own, grouped by the moment
-- it happens.
local function BuildAlerts(scroll)
    local settings = addon.db.global.settings
    local notices = settings.notices

    Section(scroll, "When someone joins your group", function(group)
        AddCheckbox(group, "Tell me about players I have a note on",
            "A line in chat with how it went and your note.",
            function() return notices.joinNotice end,
            function(v) notices.joinNotice = v end)
        AddCheckbox(group, "Also show them in a small panel",
            "A panel on screen with the people you know in the group.",
            function() return notices.joinPanel end,
            function(v) notices.joinPanel = v end)
        AddCheckbox(group, "Warn me about players I noted as Not for me",
            "A warning on screen, with a sound.",
            function() return notices.warnBad end,
            function(v) notices.warnBad = v end)
    end)

    Section(scroll, "At the end of a dungeon", function(group)
        AddCheckbox(group, "List who in the group I already know",
            "One line in chat, with how it went for each.",
            function() return notices.facesSummary end,
            function(v) notices.facesSummary = v end)
        AddCheckbox(group, "Show a short recap of the run",
            "One line in chat: how long it took, bosses and wipes, with a link to your runs.",
            function() return notices.runRecap end,
            function(v) notices.runRecap = v end)
    end)

    Section(scroll, "When someone leaves early", function(group)
        local departureSummary = settings.departureSummary
        AddCheckbox(group, "Announce a recap when they leave before a note window would open",
            "Right-clicking their name always offers \"Add Note\" with whatever was recorded while you were grouped attached, whether or not this is on.",
            function() return departureSummary.enabled end,
            function(v) departureSummary.enabled = v end)
    end)

    Section(scroll, "When someone comes online", function(group)
        AddCheckbox(group, "Tell me when someone I noted as Great comes online",
            "A line in chat. It relies on Blizzard's Recent Allies list telling the game when someone logs in.",
            function() return notices.onlineAlerts end,
            function(v) notices.onlineAlerts = v end)
        AddNote(group, "All of these are shown only to you. Nothing is sent to anyone.")
    end)
end

-- Display: where your notes show up in the game, and the journal's own look.
local function BuildDisplay(scroll)
    local settings = addon.db.global.settings

    Section(scroll, "Chat", function(group)
        AddCheckbox(group, "Star in front of players I have a note on",
            "Its color follows how it went. Hover it to read your note, click it to open them in your journal. It only changes how the line is drawn.",
            function() return settings.chatIcons end,
            function(v) settings.chatIcons = v end)
    end)

    Section(scroll, "Group Finder", function(group)
        local lfgSettings = settings.lfg
        AddCheckbox(group, "Show where the leader is",
            "Right after the activity name, as \"Wailing Caverns - The Barrens\", on every listing with or without a note.",
            function() return lfgSettings.showLocation end,
            function(v)
                lfgSettings.showLocation = v
                addon:GetModule("LFGAnnotate"):ScanBrowseResults()
            end)
        AddNote(group, "The badge and the tooltip on listings are set up on the Badges and Tooltips tabs.")
    end)

    Section(scroll, "Recent Allies", function(group)
        AddCheckbox(group, "Also pin players I marked 'Not for me' or 'Struggled'",
            "Players with notes are pinned in Blizzard's Recent Allies list with a short note. By default a player you marked 'Not for me' (Social) or 'Struggled' (Performance) is left out. This applies everywhere a pin is made: saving a note, regrouping, Pin Journal, and resyncing. It doesn't remove pins that already exist.",
            function() return settings.recentAllies.pinBad end,
            function(v) settings.recentAllies.pinBad = v end)
    end)

    Section(scroll, "Journal window", function(group)
        local browserList = settings.browserList
        local browserWindow = settings.browserWindow
        AddSlider(group, "Width", 460, 1000, 10,
            function() return browserWindow.width end,
            function(v)
                browserWindow.width = v
                addon:GetModule("Browser"):ApplyWindowSize()
            end, 0.5)
        AddSlider(group, "Height", 500, 1100, 10,
            function() return browserWindow.height end,
            function(v)
                browserWindow.height = v
                addon:GetModule("Browser"):ApplyWindowSize()
            end, 0.5)
        AddNote(group, "The /aj window. You can also drag its bottom-right corner; the new size is remembered.")
        AddSlider(group, "Spacing between player cards", 0, 20, 1,
            function() return browserList.rowPadding end,
            function(v)
                browserList.rowPadding = v
                addon:GetModule("Browser"):RefreshList()
            end)
    end)

    Section(scroll, "Minimap button", function(group)
        local minimapSettings = settings.minimap
        AddCheckbox(group, "Show the minimap button",
            "Left-click opens your notes, right-click opens these options, drag to move it. /aj minimap also toggles it.",
            function() return not minimapSettings.hide end,
            function(v)
                minimapSettings.hide = not v
                addon:GetModule("MinimapButton"):Refresh()
            end)
    end)

    -- Developer tools are switched on with a hidden slash command only; the
    -- extra settings below just appear while they're on.
    if settings.developerTools then
        Section(scroll, "Journal window colors (developer)", function(group)
            local Browser = addon:GetModule("Browser")
            for _, entry in ipairs(addon.BROWSER_COLOR_LABELS) do
                local key, label = entry[1], entry[2]
                local picker = AceGUI:Create("ColorPicker")
                picker:SetLabel(label)
                picker:SetHasAlpha(true)
                local c = settings.browserColors[key]
                picker:SetColor(c[1], c[2], c[3], c[4])
                picker:SetFullWidth(true)
                picker:SetCallback("OnValueChanged", function(_, _, r, g, b, a)
                    settings.browserColors[key] = { r, g, b, a }
                    Browser:ApplyColors()
                end)
                group:AddChild(picker)
            end
            AddSlider(group, "Fade to the right (100 = solid, 0 = fully faded)", 0, 100, 5,
                function() return math.floor((settings.browserList.cardFade or 0.25) * 100 + 0.5) end,
                function(v)
                    settings.browserList.cardFade = v / 100
                    Browser:ApplyColors()
                end)
            AddSlider(group, "Offline card text opacity", 20, 100, 5,
                function() return math.floor((settings.browserList.offlineDim or 0.55) * 100 + 0.5) end,
                function(v)
                    settings.browserList.offlineDim = v / 100
                    Browser:ApplyColors()
                end)
            AddNote(group, "Colors and opacity of the /aj window. Changes show on an open window right away.")
            AddButton(group, "Reset colors", 140, function()
                settings.browserColors = {}
                for key, color in pairs(addon.DEFAULT_BROWSER_COLORS) do
                    settings.browserColors[key] = { unpack(color) }
                end
                settings.browserList.cardFade = 0.25
                settings.browserList.offlineDim = 0.55
                Browser:ApplyColors()
                Rebuild()
            end)
        end)
    end
end

local function BuildBadges(scroll)
    local badgeSettings = addon.db.global.settings.badge
    local iconSettings = badgeSettings.icon

    -- Filled by the presets in the first section, built in the last one.
    local pathBox, coordBox
    local function CoordText()
        return string.format("%.2f,%.2f,%.2f,%.2f",
            iconSettings.left, iconSettings.right, iconSettings.top, iconSettings.bottom)
    end

    Section(scroll, "Badge icon", function(group)
        for _, preset in ipairs(ICON_PRESETS) do
            AddButton(group, preset.label, 100, function()
                iconSettings.path = preset.path
                iconSettings.left, iconSettings.right, iconSettings.top, iconSettings.bottom =
                    preset.left, preset.right, preset.top, preset.bottom
                if pathBox then pathBox:SetText(preset.path) end
                if coordBox then coordBox:SetText(CoordText()) end
                Options:Refresh()
            end)
        end
        AddNote(group, "Shared by all badges, tinted by how it went with that player (the worse of Social and Performance). The sections below place it on each kind of frame.")
    end)

    Section(scroll, "Unit frames (target and party)", function(group)
        BuildBadgePlacement(group, badgeSettings, "unit",
            "Badge corner", "Frame corner it attaches to")
    end)

    Section(scroll, "Party and raid frames", function(group)
        BuildBadgePlacement(group, badgeSettings, "group",
            "Badge corner", "Frame corner it attaches to")
    end)

    Section(scroll, "Nameplates", function(group)
        -- Everything below the switch is greyed out while it's off; the two
        -- name-relative offsets also while the badge follows the frame.
        local dependents, nameOnly = {}, {}
        local function Add(list, widget) table.insert(list, widget) end
        local function ApplyEnabled()
            local on = badgeSettings.plateEnabled and true or false
            SetEnabled(dependents, on)
            SetEnabled(nameOnly, on and badgeSettings.plateAttach ~= "plate")
        end

        AddCheckbox(group, "Show a badge on nameplates",
            "The names floating over players in the world. Needs nameplates turned on for that kind of player (friendly or enemy) in the game's options. The game hides friendly nameplates from addons inside dungeons and raids, so no badge there.",
            function() return badgeSettings.plateEnabled end,
            function(v)
                badgeSettings.plateEnabled = v
                ApplyEnabled()
                Options:Refresh()
            end)
        Add(dependents, AddDropdown(group, "Where it goes",
            { name = "Right of the name", plate = "Against the nameplate frame" }, { "name", "plate" },
            function() return badgeSettings.plateAttach end,
            function(v)
                badgeSettings.plateAttach = v
                ApplyEnabled()
            end))
        Add(dependents, AddSlider(group, "Size", 6, 64, 1,
            function() return badgeSettings.plateSize end,
            function(v) badgeSettings.plateSize = v end))
        Add(nameOnly, AddSlider(group, "Gap after name", -50, 50, 1,
            function() return badgeSettings.plateNameOffsetX end,
            function(v) badgeSettings.plateNameOffsetX = v end, 0.5))
        Add(nameOnly, AddSlider(group, "Up/down", -50, 50, 1,
            function() return badgeSettings.plateNameOffsetY end,
            function(v) badgeSettings.plateNameOffsetY = v end, 0.5))
        AddNote(group, "Used for \"Right of the name\".")
        Add(dependents, AddDropdown(group, "Badge corner", ANCHOR_LABELS, ANCHOR_POINTS,
            function() return badgeSettings.plateAnchorPoint end,
            function(v) badgeSettings.plateAnchorPoint = v end, 0.5))
        Add(dependents, AddDropdown(group, "Nameplate corner it attaches to", ANCHOR_LABELS, ANCHOR_POINTS,
            function() return badgeSettings.plateRelPoint end,
            function(v) badgeSettings.plateRelPoint = v end, 0.5))
        Add(dependents, AddSlider(group, "Offset X", -200, 200, 1,
            function() return badgeSettings.plateOffsetX end,
            function(v) badgeSettings.plateOffsetX = v end, 0.5))
        Add(dependents, AddSlider(group, "Offset Y", -200, 200, 1,
            function() return badgeSettings.plateOffsetY end,
            function(v) badgeSettings.plateOffsetY = v end, 0.5))
        AddNote(group, "Used for \"Against the nameplate frame\", and also when there's no game name text to follow (a nameplate addon drawing its own).")
        ApplyEnabled()
    end)

    Section(scroll, "Group Finder rows", function(group)
        BuildBadgePlacement(group, badgeSettings, "lfg",
            "Badge corner", "Element corner it attaches to")
        AddDropdown(group, "Attach to which element",
            LFG_ANCHOR_TARGET_LABELS, LFG_ANCHOR_TARGETS,
            function() return badgeSettings.lfgAnchorTarget end,
            function(v) badgeSettings.lfgAnchorTarget = v end)
    end)

    Section(scroll, "Custom icon (advanced)", function(group)
        pathBox = AddTextInput(group, "Texture path",
            function() return iconSettings.path end,
            function(v) iconSettings.path = v end, 0.5)
        coordBox = AddTextInput(group, "Tex coords (left, right, top, bottom)",
            CoordText,
            function(v)
                local l, r, t, b = v:match("^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$")
                l, r, t, b = tonumber(l), tonumber(r), tonumber(t), tonumber(b)
                if not (l and r and t and b) then
                    return false, "Tex coords need four numbers separated by commas, like 0,1,0,1. The previous ones were kept."
                end
                iconSettings.left, iconSettings.right, iconSettings.top, iconSettings.bottom = l, r, t, b
            end, 0.5)
        AddNote(group, "Only needed for an icon that isn't one of the presets at the top; picking a preset fills these in. A blank path draws a flat color square. Tex coords slice one image out of a sprite sheet (the Star preset shows half its file); 0,1,0,1 is the whole image. Press Enter to save.")
    end)
end

local function BuildTooltips(scroll)
    local tooltipSettings = addon.db.global.settings.tooltip

    Section(scroll, "Group Finder tooltip position", function(group)
        AddSlider(group, "Offset X", -200, 200, 1,
            function() return tooltipSettings.lfgOffsetX end,
            function(v) tooltipSettings.lfgOffsetX = v end, 0.5)
        AddSlider(group, "Offset Y", -200, 200, 1,
            function() return tooltipSettings.lfgOffsetY end,
            function(v) tooltipSettings.lfgOffsetY = v end, 0.5)
        AddSlider(group, "Extra width on the right (both tooltips)", 0, 150, 1,
            function() return tooltipSettings.paddingRight end,
            function(v) tooltipSettings.paddingRight = v end)
    end)

    local function TemplateSection(title, get, set, default)
        Section(scroll, title, function(group)
            local box = AceGUI:Create("MultiLineEditBox")
            box:SetLabel("")
            box:SetFullWidth(true)
            box:SetNumLines(7)
            box:SetText(get())
            box:SetCallback("OnTextChanged", function(widget, event, text) set(text) end)
            box:SetCallback("OnEnterPressed", function(widget, event, text) set(text) end)
            group:AddChild(box)

            AddButton(group, "Reset to default", 150, function()
                set(default)
                box:SetText(default)
            end)
        end)
    end

    Section(scroll, "Tooltip content (advanced)", function(group)
        AddNote(group, "Each line of a template below becomes one tooltip line. World and Group Finder tooltips have separate templates: the world one starts with a blank line to set it apart from Blizzard's own text above it, the Group Finder one doesn't need that.")
        -- The placeholder list is long, so it stays folded away until asked for.
        AddButton(group, Options.showPlaceholders and "Hide placeholder list" or "Show placeholder list", 190, function()
            Options.showPlaceholders = not Options.showPlaceholders
            Rebuild()
        end)
        if Options.showPlaceholders then
            AddNote(group, TEMPLATE_HELP)
        end
    end)

    TemplateSection("World tooltip template",
        function() return tooltipSettings.worldTemplate end,
        function(v) tooltipSettings.worldTemplate = v end,
        addon.DEFAULT_WORLD_TOOLTIP_TEMPLATE)

    TemplateSection("Group Finder tooltip template",
        function() return tooltipSettings.lfgTemplate end,
        function(v) tooltipSettings.lfgTemplate = v end,
        addon.DEFAULT_LFG_TOOLTIP_TEMPLATE)
end

-- Data & privacy: what is recorded and kept, and how to get rid of it.
local function BuildData(scroll)
    local settings = addon.db.global.settings
    local sessionGate = settings.sessionGate
    local retention = settings.retention

    Section(scroll, "Privacy", function(group)
        AddCheckbox(group, "Streamer mode",
            "Hides your notes, nicknames and tags: they are replaced by a short placeholder in tooltips, chat lines and the journal. Names and stars stay. /aj streamer does the same.",
            function() return settings.streamerMode end,
            function(v) settings.streamerMode = v; addon:GetModule("Browser"):RefreshIfShown() end)
    end)

    Section(scroll, "What is recorded", function(group)
        AddCheckbox(group, "Pause recording",
            "No new sessions and no automatic note windows. Notes you write yourself keep working. /aj pause does the same.",
            function() return settings.paused end,
            function(v) settings.paused = v; addon:GetModule("Browser"):RefreshIfShown() end)

        local tracking = settings.tracking
        local function TrackingChanged()
            addon:GetModule("ChatLog"):ApplySetting()
            local browser = addon:GetModule("Browser")
            browser:RefreshIfShown()
            browser:RefreshStats()
        end
        AddCheckbox(group, "Record damage and healing numbers",
            "The DPS and HPS of everyone in your group, read from the game's damage meter after each fight. With this off, the note window has no group chart or fight list, and the Damage and Healing lines are hidden in your journal. Time grouped and time in combat are still recorded.",
            function() return tracking.damage end,
            function(v) tracking.damage = v; TrackingChanged() end)
        AddCheckbox(group, "Keep chat with my notes",
            "The last few party, raid, say and whisper lines between you and someone you were grouped with, saved when you write a note on them. With this off, chat isn't read at all and the note window and journal don't show any.",
            function() return tracking.chat end,
            function(v) tracking.chat = v; TrackingChanged() end)
        AddCheckbox(group, "Remember friendly players I pass in the open world",
            "Off by default. Kept for 7 days, so you can add someone to your journal a few days after you met. See the Nearby button in the journal or /aj nearby.",
            function() return settings.nearby.enabled end,
            function(v) settings.nearby.enabled = v end)
        AddNote(group, "Turning numbers or chat off hides what is already saved without deleting it, so turning it back on brings it back. A note window that is already open changes the next time it opens. To remove it for good, see Delete and reset at the bottom of this tab.")
    end)

    Section(scroll, "What counts as a session", function(group)
        AddSlider(group, "Minimum time grouped (minutes)", 0, 30, 1,
            function() return math.floor(sessionGate.minGroupedSeconds / 60) end,
            function(v) sessionGate.minGroupedSeconds = v * 60 end, 0.5)
        AddSlider(group, "Minimum time in combat (minutes)", 0, 30, 1,
            function() return math.floor(sessionGate.minCombatSeconds / 60) end,
            function(v) sessionGate.minCombatSeconds = v * 60 end, 0.5)
        AddNote(group, "A session (grouped time, combat time, and DPS/HPS when those are recorded) is saved only when BOTH minimums are met. This keeps out non-combat grouping and trivial world mob-tagging.")
    end)

    Section(scroll, "Old sessions", function(group)
        AddSlider(group, "Clean Up offers sessions older than (days)", 7, 180, 1,
            function() return retention.purgeDays end,
            function(v) retention.purgeDays = v end)
        AddNote(group, "The Clean Up button in /aj offers to delete sessions older than this, for players you never wrote a note for. It always asks first, and sessions for players with notes are never included.")
    end)

    Section(scroll, "Backup", function(group)
        local Backup = addon:GetModule("Backup")
        AddCheckbox(group, "Keep automatic backups of my journal",
            "A copy of your notes, players and history is kept inside the saved data about every 12 hours, the last three. It stays on your computer and does not include your settings.",
            function() return settings.backup.enabled end,
            function(v) settings.backup.enabled = v end)
        AddButton(group, "Back up now", 160, function()
            Backup:Snapshot("manual")
            Rebuild()
        end)

        local list = Backup:List()
        if #list == 0 then
            AddNote(group, "No backup yet. The first one is made a few seconds after you log in.")
        end
        for index, entry in ipairs(list) do
            local row = AceGUI:Create("SimpleGroup")
            row:SetFullWidth(true)
            row:SetLayout("Flow")
            local label = AceGUI:Create("Label")
            label:SetText(Backup:Describe(entry))
            label:SetRelativeWidth(0.74)
            row:AddChild(label)
            local restoreBtn = AceGUI:Create("Button")
            restoreBtn:SetText("Restore")
            restoreBtn:SetRelativeWidth(0.24)
            restoreBtn:SetCallback("OnClick", function()
                StaticPopup_Show("ALLIESJOURNAL_RESTORE_BACKUP", Backup:Describe(entry), nil, { index = index })
            end)
            row:AddChild(restoreBtn)
            group:AddChild(row)
        end
        if #list > 0 then
            AddNote(group, "Restoring saves your current journal as a backup first.")
        end
    end)

    -- Everything that throws something away sits together, last, and apart
    -- from the everyday switches. Each button asks before doing anything.
    Section(scroll, "Delete and reset", function(group)
        AddButton(group, "Delete saved numbers", 200, function()
            StaticPopup_Show("ALLIESJOURNAL_DELETE_NUMBERS")
        end)
        AddButton(group, "Delete saved chat", 200, function()
            StaticPopup_Show("ALLIESJOURNAL_DELETE_CHAT")
        end)
        AddNote(group, "Removes the damage and healing numbers, or the chat, from every note and session for good. The notes and sessions themselves are kept.")
        AddButton(group, "Reset all settings", 200, function()
            StaticPopup_Show("ALLIESJOURNAL_RESET_SETTINGS")
        end)
        AddNote(group, "Puts every setting on all tabs back to its default. Your notes and player data are not touched.")
    end, true)
end

local TABS = {
    { value = "notes", text = "Notes", build = BuildNotes },
    { value = "alerts", text = "Alerts", build = BuildAlerts },
    { value = "display", text = "Display", build = BuildDisplay },
    { value = "badges", text = "Badges", build = BuildBadges },
    { value = "tooltips", text = "Tooltips", build = BuildTooltips },
    { value = "data", text = "Data & privacy", build = BuildData },
}

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------

function Options:ResetWindows()
    local settings = addon.db.global.settings
    settings.browserWindow = { width = 550, height = 700 }
    settings.reviewWindow = { width = 550, height = 700 }
    for _, name in ipairs({ "Browser", "ReviewPrompt" }) do
        local module = addon:GetModule(name)
        pcall(module.ApplyWindowSize, module)
        if module.frame and module.frame.frame then
            module.frame.frame:ClearAllPoints()
            module.frame.frame:SetPoint("CENTER", UIParent, "CENTER")
        end
    end
    if self.frame and self.frame.frame then
        self.frame:SetWidth(600)
        self.frame:SetHeight(660)
        self.frame.frame:ClearAllPoints()
        self.frame.frame:SetPoint("CENTER", UIParent, "CENTER")
    end
    addon:Print("Window sizes and positions reset.")
end

function Options:ResetAll()
    local settings = addon.db.global.settings
    settings.badge = {
        unitSize = 32, unitAnchorPoint = "CENTER", unitRelPoint = "TOPLEFT", unitOffsetX = 10, unitOffsetY = -35,
        lfgSize = 42, lfgAnchorPoint = "CENTER", lfgRelPoint = "CENTER", lfgOffsetX = 193, lfgOffsetY = -5,
        lfgAnchorTarget = "frame",
        groupSize = 16, groupAnchorPoint = "TOPRIGHT", groupRelPoint = "TOPRIGHT", groupOffsetX = -3, groupOffsetY = -3,
        plateEnabled = true, plateAttach = "name", plateSize = 20, plateNameOffsetX = 2, plateNameOffsetY = 0, plateAnchorPoint = "BOTTOM", plateRelPoint = "TOP", plateOffsetX = 0, plateOffsetY = 2,
        icon = { path = "Interface\\COMMON\\FavoritesIcon", left = 0, right = 1, top = 0, bottom = 1 },
    }
    settings.tooltip = {
        lfgOffsetX = 8, lfgOffsetY = 37, paddingRight = 0,
        worldTemplate = addon.DEFAULT_WORLD_TOOLTIP_TEMPLATE,
        lfgTemplate = addon.DEFAULT_LFG_TOOLTIP_TEMPLATE,
    }
    settings.sessionGate = { minGroupedSeconds = 240, minCombatSeconds = 120 }
    settings.retention = { purgeDays = 60 }
    settings.reviewWindow = { width = 550, height = 700 }
    settings.departureSummary = { enabled = true }
    settings.browserList = { rowPadding = 4, cardFade = 0.25, offlineDim = 0.55 }
    settings.recentAllies = { pinBad = false }
    settings.simpleNotes = false
    settings.playerStrip = true
    settings.askAgainHours = 12
    settings.windowNoteLimit = 3
    settings.notices = { joinNotice = true, onlineAlerts = true, facesSummary = true, runRecap = true, warnBad = false, joinPanel = false }
    settings.streamerMode = false
    settings.paused = false
    settings.tracking = { damage = true, chat = true }
    addon:GetModule("ChatLog"):ApplySetting()
    settings.nearby = { enabled = false }
    settings.thanksMessage = "Thanks for the run, {name}!"
    settings.chatIcons = true
    settings.backup = { enabled = true }
    settings.browserWindow = { width = 550, height = 700 }
    addon:GetModule("Browser"):ApplyWindowSize()
    settings.browserColors = {}
    for key, color in pairs(addon.DEFAULT_BROWSER_COLORS) do
        settings.browserColors[key] = { unpack(color) }
    end
    addon:GetModule("Browser"):ApplyColors()
    settings.gateMinutes = 10
    settings.minimap = { hide = false, angle = 215, minimapPos = 215 }
    settings.lfg = { showLocation = true, locAnchor = "BOTTOMRIGHT", locRel = "BOTTOMRIGHT", locX = -8, locY = 6 }
    addon:GetModule("MinimapButton"):Refresh()
    addon:GetModule("ReviewPrompt"):ApplyWindowSize()
    self:Refresh()
    self:Show()  -- rebuild so every control reflects the reset values
end

StaticPopupDialogs["ALLIESJOURNAL_DELETE_NUMBERS"] = {
    text = "Delete the damage and healing numbers from all your notes and sessions?\n\nThis can't be undone. The notes and sessions themselves are kept. Backups made before now still contain the numbers.",
    button1 = "Delete",
    button2 = CANCEL,
    OnAccept = function()
        local count = addon:DeleteSavedNumbers()
        addon:Print(string.format("Deleted the damage and healing numbers from %d note%s and session%s.", count, count == 1 and "" or "s", count == 1 and "" or "s"))
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["ALLIESJOURNAL_DELETE_CHAT"] = {
    text = "Delete the chat saved with all your notes?\n\nThis can't be undone. The notes themselves are kept. Backups made before now still contain the chat.",
    button1 = "Delete",
    button2 = CANCEL,
    OnAccept = function()
        local count = addon:DeleteSavedChat()
        addon:Print(string.format("Deleted the chat saved with %d note%s.", count, count == 1 and "" or "s"))
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["ALLIESJOURNAL_RESET_SETTINGS"] = {
    text = "Reset every Allies Journal setting to its default?\n\nYour notes and player data are not affected.",
    button1 = "Reset",
    button2 = CANCEL,
    OnAccept = function() addon:GetModule("Options"):ResetAll() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local WINDOW_WIDTH, WINDOW_HEIGHT = 600, 660

function Options:Show()
    if not self.frame then
        local frame = addon:CreateWindow()
        frame.frame:SetFrameStrata("DIALOG") -- AceGUI defaults to FULLSCREEN_DIALOG, which sits above the game's confirmation popups
        frame:SetTitle("Allies Journal - Options")
        frame:SetLayout("Fill")
        -- Size and position are kept here for as long as you're logged in.
        self.windowStatus = { width = WINDOW_WIDTH, height = WINDOW_HEIGHT }
        frame:SetStatusTable(self.windowStatus)
        frame:EnableResize(true)
        -- Narrower than this, the side-by-side controls stop fitting.
        if frame.frame.SetResizeBounds then
            frame.frame:SetResizeBounds(480, 360)
        elseif frame.frame.SetMinResize then
            frame.frame:SetMinResize(480, 360)
        end
        frame:SetCallback("OnClose", function(widget) widget:Hide() end)
        -- Same steady dark fill as the /aj window (see Browser:Show).
        self.windowFill = frame.frame:CreateTexture(nil, "BACKGROUND", nil, 2)
        self.windowFill:SetPoint("TOPLEFT", frame.content, "TOPLEFT", -6, 6)
        self.windowFill:SetPoint("BOTTOMRIGHT", frame.content, "BOTTOMRIGHT", 6, -6)
        self.frame = frame
    end
    do
        local c = addon.db.global.settings.browserColors.window
        self.windowFill:SetColorTexture(c[1], c[2], c[3], c[4])
    end

    local frame = self.frame
    frame:ReleaseChildren()
    frame:Show()
    frame.frame:Raise()  -- already open behind another window: bring it forward

    -- One per tab, kept between rebuilds, so a rebuild (Back up now, a
    -- reset, folding the placeholder list) doesn't jump back to the top.
    self.scrollStatus = self.scrollStatus or {}

    local tabs = AceGUI:Create("TabGroup")
    tabs:SetLayout("Fill")
    local tabList = {}
    for _, tab in ipairs(TABS) do
        table.insert(tabList, { value = tab.value, text = tab.text })
    end
    tabs:SetTabs(tabList)
    tabs:SetCallback("OnGroupSelected", function(container, event, value)
        self.selectedTab = value
        container:ReleaseChildren()
        local scroll = AceGUI:Create("ScrollFrame")
        scroll:SetLayout("List")
        self.scrollStatus[value] = self.scrollStatus[value] or {}
        scroll:SetStatusTable(self.scrollStatus[value])
        container:AddChild(scroll)
        for _, tab in ipairs(TABS) do
            if tab.value == value then tab.build(scroll) end
        end
    end)
    frame:AddChild(tabs)
    tabs:SelectTab(self.selectedTab or TABS[1].value)
end

--------------------------------------------------------------------------
-- Game options (Esc > Options > AddOns)
--------------------------------------------------------------------------

-- An entry where players look for addon settings first. It only holds a
-- button that opens the addon's own window: the settings themselves live
-- there, in one place.
function Options:RegisterGameCategory()
    if self.gameCategory then return end
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then return end

    local panel = CreateFrame("Frame")
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Allies Journal")

    local text = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    text:SetWidth(520)
    text:SetJustifyH("LEFT")
    text:SetText("Allies Journal has its own options window. You can also open it with /aj options, or by right-clicking the minimap button.")

    local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    button:SetSize(220, 24)
    button:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -14)
    button:SetText("Open Allies Journal options")
    button:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() and not InCombatLockdown() then
            HideUIPanel(SettingsPanel)
        end
        Options:Show()
    end)

    -- The game calls these on its own panels; nothing to do for this one.
    panel.OnCommit = function() end
    panel.OnDefault = function() end
    panel.OnRefresh = function() end

    local category = Settings.RegisterCanvasLayoutCategory(panel, "Allies Journal")
    Settings.RegisterAddOnCategory(category)
    self.gameCategory = category
end

function Options:OnEnable()
    -- Never worth breaking the addon over: without it /aj options still works.
    pcall(self.RegisterGameCategory, self)
end
