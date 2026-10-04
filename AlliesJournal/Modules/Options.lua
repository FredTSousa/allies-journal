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
    "Each line below becomes one tooltip line. Color codes work directly - e.g. ||cffff0000red text||r for red (use || instead of | so it isn't rendered here).",
    " ",
    "Placeholders (used as {name}):",
    "  {social} / {performance} - how it went, as colored text (Great to play with / Fine / Not for me, and Strong / Solid / Struggled)",
    "  {socialNote} / {performanceNote} - the text of the notes on it. A line containing ONLY one of these is dropped entirely when that note is empty.",
    "  {count} - how many notes this player has",
    "  {author} - who wrote the most recent note",
    "  {date} - that note's date (YYYY-MM-DD)",
    "  {encounter} - what was happening when it was written",
    "  {role} - the role recorded on it, if any",
    "  {roleIcon} - the tank/healer/DPS icon for that role (blank when there is none)",
    "  {memberNote} - Group Finder template ONLY. Blank when the player with a note is the group's leader/poster; otherwise \"Group member: Name\" for whichever other member matched (checked via the real group roster, not just the listing's poster).",
}, "\n")

-- Settings are grouped into tabs, and each group into a titled section box.
-- A section is built completely BEFORE it's added to its parent, so the
-- parent lays it out at its real height (a container that grows after it
-- was added leaves whatever follows it overlapping).
local function Section(parent, title, build)
    local group = AceGUI:Create("InlineGroup")
    group:SetTitle(title)
    group:SetFullWidth(true)
    group:SetLayout("Flow")
    -- Same dark panel the /pr list sits on, so the sections read as
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
    group:SetCallback("OnRelease", function() panel:Hide() end)
    build(group)
    parent:AddChild(group)
end

-- Muted explanatory text under a control or at the top of a section.
local function AddNote(container, text)
    local label = AceGUI:Create("Label")
    label:SetText(text)
    label:SetFullWidth(true)
    label:SetColor(0.62, 0.62, 0.68)
    container:AddChild(label)
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
end

local function AddCheckbox(container, label, get, set)
    local cb = AceGUI:Create("CheckBox")
    cb:SetLabel(label)
    cb:SetValue(get())
    cb:SetFullWidth(true)
    cb:SetCallback("OnValueChanged", function(widget, event, value)
        set(value)
    end)
    container:AddChild(cb)
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
end

local function AddTextInput(container, label, get, set, relWidth)
    local box = AceGUI:Create("EditBox")
    box:SetLabel(label)
    SetWidthOf(box, relWidth)
    box:SetText(get() or "")
    box:SetCallback("OnEnterPressed", function(widget, event, text)
        set(text)
        Options:Refresh()
    end)
    container:AddChild(box)
    return box
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
--------------------------------------------------------------------------

local function BuildGeneral(scroll)
    local settings = addon.db.global.settings

    Section(scroll, "Note window", function(group)
        AddNote(group, "Size of the window that opens to write about a player. Changes apply to an open window right away.")
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
    end)

    Section(scroll, "Player list", function(group)
        local browserList = settings.browserList
        AddNote(group, "Size of the /aj window. You can also drag its bottom-right corner; the new size is remembered.")
        local browserWindow = settings.browserWindow
        AddSlider(group, "Window width", 460, 1000, 10,
            function() return browserWindow.width end,
            function(v)
                browserWindow.width = v
                addon:GetModule("Browser"):ApplyWindowSize()
            end, 0.5)
        AddSlider(group, "Window height", 500, 1100, 10,
            function() return browserWindow.height end,
            function(v)
                browserWindow.height = v
                addon:GetModule("Browser"):ApplyWindowSize()
            end, 0.5)
        AddSlider(group, "Spacing between player cards", 0, 20, 1,
            function() return browserList.rowPadding end,
            function(v)
                browserList.rowPadding = v
                addon:GetModule("Browser"):RefreshList()
            end)
    end)

    Section(scroll, "Group Finder listing: leader location", function(group)
        local lfgSettings = addon.db.global.settings.lfg
        AddCheckbox(group, "Show where the leader is, right after the activity name",
            function() return lfgSettings.showLocation end,
            function(v)
                lfgSettings.showLocation = v
                addon:GetModule("LFGAnnotate"):ScanBrowseResults()
            end)
        AddNote(group, "Shown as \"Wailing Caverns - The Barrens\" on every listing, with or without a note.")
    end)

    Section(scroll, "Recent Allies", function(group)
        AddCheckbox(group, "Also pin players I marked 'Not for me' or 'Struggled'",
            function() return settings.recentAllies.pinBad end,
            function(v) settings.recentAllies.pinBad = v end)
        AddNote(group, "Players with notes are pinned in Blizzard's Recent Allies list with a short note. By default a player you marked 'Not for me' (Social) or 'Struggled' (Performance) is left out. This applies everywhere a pin is made: saving a note, regrouping, Pin Journal, and resyncing. It doesn't remove pins that already exist.")
    end)

    Section(scroll, "Minimap button", function(group)
        local minimapSettings = settings.minimap
        AddCheckbox(group, "Show the minimap button",
            function() return not minimapSettings.hide end,
            function(v)
                minimapSettings.hide = not v
                addon:GetModule("MinimapButton"):Refresh()
            end)
        AddNote(group, "Left-click opens your notes, right-click opens these options, drag to move it. /aj minimap also toggles it.")
    end)

    Section(scroll, "Chat", function(group)
        local departureSummary = settings.departureSummary
        AddCheckbox(group, "Announce a recap when someone leaves before a note would show",
            function() return departureSummary.enabled end,
            function(v) departureSummary.enabled = v end)
        AddNote(group, "Right-clicking their name always offers \"Add Note\" with their real fight and chat data attached, whether or not the announcement is on.")
    end)

    -- Developer tools are switched on with a hidden slash command only; the
    -- extra settings below just appear while they're on.
    if settings.developerTools then
        Section(scroll, "Player list colors (developer)", function(group)
            AddNote(group, "Colors and opacity of the /aj window. Changes show on an open window right away.")
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
            local resetBtn = AceGUI:Create("Button")
            resetBtn:SetText("Reset colors")
            resetBtn:SetWidth(140)
            resetBtn:SetCallback("OnClick", function()
                settings.browserColors = {}
                for key, color in pairs(addon.DEFAULT_BROWSER_COLORS) do
                    settings.browserColors[key] = { unpack(color) }
                end
                settings.browserList.cardFade = 0.25
                settings.browserList.offlineDim = 0.55
                Browser:ApplyColors()
                Options:Show()
            end)
            group:AddChild(resetBtn)
        end)
    end

    Section(scroll, "Reset", function(group)
        AddNote(group, "Puts every setting on all tabs back to its default. Your notes and player data are not touched.")
        local resetBtn = AceGUI:Create("Button")
        resetBtn:SetText("Reset all settings to defaults")
        resetBtn:SetWidth(240)
        resetBtn:SetCallback("OnClick", function()
            StaticPopup_Show("ALLIESJOURNAL_RESET_SETTINGS")
        end)
        group:AddChild(resetBtn)
    end)
end

local function BuildSessions(scroll)
    local settings = addon.db.global.settings
    local sessionGate = settings.sessionGate
    local retention = settings.retention

    Section(scroll, "When a note window opens", function(group)
        AddNote(group, "After a dungeon, or when someone leaves your group, a note window opens for anyone you were grouped with for at least this long. Shorter than this, you only get a recap line in chat, and you can still right-click their name to write a note.")
        AddSlider(group, "Minimum time grouped (minutes)", 1, 60, 1,
            function() return settings.gateMinutes or 10 end,
            function(v) settings.gateMinutes = v end)
    end)

    Section(scroll, "When a session is recorded", function(group)
        AddNote(group, "A session (grouped time, combat time, DPS/HPS) is saved only when BOTH minimums below are met. This keeps out non-combat grouping and trivial world mob-tagging.")
        AddSlider(group, "Minimum time grouped (minutes)", 0, 30, 1,
            function() return math.floor(sessionGate.minGroupedSeconds / 60) end,
            function(v) sessionGate.minGroupedSeconds = v * 60 end, 0.5)
        AddSlider(group, "Minimum time in combat (minutes)", 0, 30, 1,
            function() return math.floor(sessionGate.minCombatSeconds / 60) end,
            function(v) sessionGate.minCombatSeconds = v * 60 end, 0.5)
    end)

    Section(scroll, "Clean Up", function(group)
        AddNote(group, "The Clean Up button in /aj offers to delete sessions older than this, for players you never wrote a note for. It always asks first, and sessions for players with notes are never included.")
        AddSlider(group, "Sessions older than (days)", 7, 180, 1,
            function() return retention.purgeDays end,
            function(v) retention.purgeDays = v end)
    end)
end

local function BuildBadges(scroll)
    local badgeSettings = addon.db.global.settings.badge
    local iconSettings = badgeSettings.icon

    Section(scroll, "Unit frames (target and party)", function(group)
        BuildBadgePlacement(group, badgeSettings, "unit",
            "Badge corner", "Frame corner it attaches to")
    end)

    Section(scroll, "Party and raid frames", function(group)
        BuildBadgePlacement(group, badgeSettings, "group",
            "Badge corner", "Frame corner it attaches to")
    end)

    Section(scroll, "Group Finder rows", function(group)
        BuildBadgePlacement(group, badgeSettings, "lfg",
            "Badge corner", "Element corner it attaches to")
        AddDropdown(group, "Attach to which element",
            LFG_ANCHOR_TARGET_LABELS, LFG_ANCHOR_TARGETS,
            function() return badgeSettings.lfgAnchorTarget end,
            function(v) badgeSettings.lfgAnchorTarget = v end)
    end)

    Section(scroll, "Badge icon", function(group)
        AddNote(group, "Shared by both badges, tinted by how it went with that player (the worse of Social and Performance). A blank path draws a flat color square. Tex coords slice one image out of a sprite sheet (the Star preset shows half its file); 0,1,0,1 is the whole image.")

        local pathBox, coordBox
        local function CoordText()
            return string.format("%.2f,%.2f,%.2f,%.2f",
                iconSettings.left, iconSettings.right, iconSettings.top, iconSettings.bottom)
        end

        pathBox = AddTextInput(group, "Texture path",
            function() return iconSettings.path end,
            function(v) iconSettings.path = v end, 0.5)
        coordBox = AddTextInput(group, "Tex coords (left, right, top, bottom)",
            CoordText,
            function(v)
                local l, r, t, b = v:match("^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$")
                l, r, t, b = tonumber(l), tonumber(r), tonumber(t), tonumber(b)
                if l and r and t and b then
                    iconSettings.left, iconSettings.right, iconSettings.top, iconSettings.bottom = l, r, t, b
                end
            end, 0.5)

        for _, preset in ipairs(ICON_PRESETS) do
            local btn = AceGUI:Create("Button")
            btn:SetText(preset.label)
            btn:SetWidth(110)
            btn:SetCallback("OnClick", function()
                iconSettings.path = preset.path
                iconSettings.left, iconSettings.right, iconSettings.top, iconSettings.bottom =
                    preset.left, preset.right, preset.top, preset.bottom
                pathBox:SetText(preset.path)
                coordBox:SetText(CoordText())
                Options:Refresh()
            end)
            group:AddChild(btn)
        end
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

            local resetBtn = AceGUI:Create("Button")
            resetBtn:SetText("Reset to default")
            resetBtn:SetWidth(150)
            resetBtn:SetCallback("OnClick", function()
                set(default)
                box:SetText(default)
            end)
            group:AddChild(resetBtn)
        end)
    end

    Section(scroll, "Tooltip content", function(group)
        AddNote(group, "Each line below becomes one tooltip line. World and Group Finder tooltips have separate templates: the world one starts with a blank line to set it apart from Blizzard's own text above it, the Group Finder one doesn't need that.")
        AddNote(group, TEMPLATE_HELP)
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

local TABS = {
    { value = "general", text = "General", build = BuildGeneral },
    { value = "sessions", text = "Sessions", build = BuildSessions },
    { value = "badges", text = "Badges", build = BuildBadges },
    { value = "tooltips", text = "Tooltips", build = BuildTooltips },
}

--------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------

function Options:ResetAll()
    local settings = addon.db.global.settings
    settings.badge = {
        unitSize = 32, unitAnchorPoint = "CENTER", unitRelPoint = "TOPLEFT", unitOffsetX = 10, unitOffsetY = -35,
        lfgSize = 42, lfgAnchorPoint = "CENTER", lfgRelPoint = "CENTER", lfgOffsetX = 193, lfgOffsetY = -5,
        lfgAnchorTarget = "frame",
        groupSize = 16, groupAnchorPoint = "TOPRIGHT", groupRelPoint = "TOPRIGHT", groupOffsetX = -3, groupOffsetY = -3,
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

StaticPopupDialogs["ALLIESJOURNAL_RESET_SETTINGS"] = {
    text = "Reset every Allies Journal setting to its default?\n\nYour notes and player data are not affected.",
    button1 = YES,
    button2 = NO,
    OnAccept = function() addon:GetModule("Options"):ResetAll() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function Options:Show()
    if not self.frame then
        local frame = AceGUI:Create("Window")
        frame.frame:SetFrameStrata("DIALOG") -- AceGUI defaults to FULLSCREEN_DIALOG, which sits above the game's confirmation popups
        frame:SetTitle("Allies Journal - Options")
        frame:SetLayout("Fill")
        frame:SetWidth(560)
        frame:SetHeight(640)
        frame:EnableResize(false)
        frame:SetCallback("OnClose", function(widget) widget:Hide() end)
        -- Same steady dark fill as the /pr window (see Browser:Show).
        self.windowFill = frame.frame:CreateTexture(nil, "BACKGROUND", nil, 2)
        self.windowFill:SetPoint("TOPLEFT", frame.frame, "TOPLEFT", 8, -8)
        self.windowFill:SetPoint("BOTTOMRIGHT", frame.frame, "BOTTOMRIGHT", -8, 8)
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
        container:AddChild(scroll)
        for _, tab in ipairs(TABS) do
            if tab.value == value then tab.build(scroll) end
        end
    end)
    frame:AddChild(tabs)
    tabs:SelectTab(self.selectedTab or "general")
end
