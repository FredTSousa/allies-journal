local addon = PlayerReview
local ReviewPrompt = addon:NewModule("ReviewPrompt")
local AceGUI = LibStub("AceGUI-3.0")
local L = LibStub("AceLocale-3.0"):GetLocale("PlayerReview")

local RATING_ORDER = { "good", "average", "bad" }
local RATING_LABELS = { good = "Good", average = "Average", bad = "Bad" }
local ROLE_ORDER = { "tank", "healer", "dps" }
local ROLE_LABELS = { tank = "Tank", healer = "Healer", dps = "DPS" }

ReviewPrompt.queue = {}
ReviewPrompt.active = false
ReviewPrompt.batchTotal = 0
ReviewPrompt.shownCount = 0

-- data: { nameRealm, encounter, role, guid, fights }
function ReviewPrompt:QueueBatch(list)
    for _, data in ipairs(list) do
        table.insert(self.queue, data)
    end

    if not self.active then
        self.batchTotal = #self.queue
        self.shownCount = 0
        self:ShowNext()
    else
        self.batchTotal = self.batchTotal + #list
    end
end

function ReviewPrompt:ShowNext()
    local data = table.remove(self.queue, 1)
    if not data then
        self.active = false
        if self.frame then self.frame:Hide() end
        return
    end

    self.active = true
    self.shownCount = self.shownCount + 1
    self.current = data
    self.form = {
        social = "average",
        performance = "average",
        socialNote = "",
        performanceNote = "",
        role = data.role,  -- pre-selected when auto-filled, editable regardless
        selectedFights = {},  -- fightIndex -> true, all checked by default
    }
    for i in ipairs(data.fights or {}) do
        self.form.selectedFights[i] = true
    end
    self:BuildFrame()

    -- Fade in only here, on a genuinely new player being shown - not
    -- inside BuildFrame() itself, since BuildFrame() also re-runs on every
    -- in-place rebuild (e.g. clicking a Good/Average/Bad radio), which
    -- doesn't warrant a fresh fade-in each time. UIFrameFadeIn is
    -- Blizzard's own long-standing fade helper. pcall'd since frame.frame
    -- (the real underlying Frame behind the AceGUI Window widget) isn't
    -- part of AceGUI's documented API.
    pcall(function()
        self.frame.frame:SetAlpha(0)
        UIFrameFadeIn(self.frame.frame, 0.25, 0, 1)
    end)
end

function ReviewPrompt:Skip()
    if self.editingReviewID then
        -- Cancel edit: just close, don't touch the queue - there may be
        -- an unrelated pending batch this edit interrupted.
        self.editingReviewID = nil
        self.active = false
        if self.frame then self.frame:Hide() end
        return
    end
    addon:GetModule("ChatLog"):Clear(self.current and self.current.guid)
    self:ShowNext()
end

function ReviewPrompt:Save()
    local form = self.form

    if form.social ~= "average" and strtrim(form.socialNote or "") == "" then
        self:ShowValidationError(L["A note is required when Social is not Average."])
        return
    end
    if form.performance ~= "average" and strtrim(form.performanceNote or "") == "" then
        self:ShowValidationError(L["A note is required when Performance is not Average."])
        return
    end

    local data = self.current

    if self.editingReviewID then
        -- Mutates the existing review in place (same ID) instead of
        -- minting a new one - see EditReview below.
        addon:UpdateReview(self.editingReviewID, {
            role = form.role,
            social = form.social,
            socialNote = form.socialNote or "",
            performance = form.performance,
            performanceNote = form.performanceNote or "",
        })
        self.editingReviewID = nil
        self.active = false
        if self.frame then self.frame:Hide() end
        addon:GetModule("Tooltip"):RefreshFramesSoon()
        addon:GetModule("Browser"):RefreshIfShown()
        pcall(function() addon:GetModule("LFGAnnotate"):ScanBrowseResults() end)
        return
    end

    -- Aggregates only the fights still checked in the selection UI (all
    -- of them, by default) into the review's own compact dps/hps/
    -- interrupts/dispels/deaths - see AddRatingSection's sibling,
    -- AddFightSelectionSection, for the checklist itself.
    local selectedIndices = {}
    for i in ipairs(data.fights or {}) do
        if form.selectedFights[i] then table.insert(selectedIndices, i) end
    end
    local aggregate = addon:GetModule("ReviewCapture"):AggregateFights(data.fights, selectedIndices)

    addon:AddReview(data.nameRealm, {
        encounter = data.encounter,
        role = form.role,
        social = form.social,
        socialNote = form.socialNote or "",
        performance = form.performance,
        performanceNote = form.performanceNote or "",
        dps = aggregate.dps,
        hps = aggregate.hps,
        groupMaxDps = aggregate.groupMaxDps,
        groupMaxHps = aggregate.groupMaxHps,
        groupTotalDps = aggregate.groupTotalDps,
        groupTotalHps = aggregate.groupTotalHps,
        interrupts = aggregate.interrupts,
        dispels = aggregate.dispels,
        deaths = aggregate.deaths,
        fightsIncluded = #selectedIndices,
        -- Chat only ever persists long-term via a review, never a plain
        -- session - read right before Clear() below wipes the live
        -- buffer, so this is everything captured up to this exact save.
        chat = addon:GetModule("ChatLog"):GetMessages(data.guid),
        -- Every session recorded for this player since their last review
        -- (or ever, if this is their first) gets linked onto this one.
        sessionIds = addon:GetUnlinkedSessionsForPlayer(data.nameRealm),
        -- Whatever C_RecentAllies logged for this guid during the actual
        -- grouped window (data.since -> now) - nil-safe, since data.since
        -- is only set when this came through RosterTracker (not /pr
        -- test/testgroup or an edit).
        interactions = data.since and addon:GetRecentAllyInteractionsInWindow(data.guid, data.since) or {},
        zone = data.encounter,
    })

    -- Falls back to a name-based GUID lookup when there's no live unit
    -- (e.g. /pr queuename, or "Review Player" on a chat name you're not
    -- currently grouped with) - otherwise a review saved that way could
    -- never sync to C_RecentAllies at all, confirmed in-game as the
    -- actual cause of two real reviews showing up unpinned.
    addon:SyncRecentAlly(data.guid or addon:FindRecentAllyGUID(data.nameRealm), form, data.nameRealm)

    addon:GetModule("ChatLog"):Clear(data.guid)
    addon:GetModule("Tooltip"):RefreshFramesSoon()
    addon:GetModule("Browser"):RefreshIfShown()
    -- Otherwise the new badge/tooltip only appears after LFGAnnotate's own
    -- 1s ticker happens to fire next, or a full /reload - force an
    -- immediate rescan the same way the other two modules refresh here.
    pcall(function() addon:GetModule("LFGAnnotate"):ScanBrowseResults() end)
    self:ShowNext()
end

-- Separate entry point from the queue-driven ShowNext/QueueBatch flow
-- above - editing an existing review isn't part of a batch of pending
-- prompts, it's a one-off triggered from Browser's Edit button.
function ReviewPrompt:EditReview(nameRealm, reviewId)
    local review = addon:GetReview(reviewId)
    if not review then return end

    self.editingReviewID = reviewId
    self.active = true
    self.shownCount = 1
    self.batchTotal = 1
    self.current = {
        nameRealm = nameRealm,
        encounter = review.encounter,
        -- No live unit/guid to read a fresh meter snapshot or chat log
        -- from when editing an old review - BuildFrame's meter/chat
        -- sections already no-op cleanly without one.
        guid = nil,
    }
    self.form = {
        social = review.social,
        performance = review.performance,
        socialNote = review.socialNote or "",
        performanceNote = review.performanceNote or "",
        role = review.role,
    }
    self:BuildFrame()

    pcall(function()
        self.frame.frame:SetAlpha(0)
        UIFrameFadeIn(self.frame.frame, 0.25, 0, 1)
    end)
end

function ReviewPrompt:ShowValidationError(msg)
    if self.frame then
        self.frame:SetStatusText(msg)
    end
end

local RATING_COLORS = { good = "|cff40ff40", average = "|cffffd100", bad = "|cffff4040" }

-- One-click tags under each note: clicking one appends it to the note, so
-- a required note (Good/Bad) can be satisfied without typing, and an
-- optional Average note takes one click too.
local TAGS = {
    social = {
        good = { "Friendly", "Great communicator", "Patient", "Helpful" },
        average = { "Quiet", "Polite", "Didn't say much", "Nothing notable" },
        bad = { "Rude", "Toxic chat", "Left early", "Ignored the group" },
    },
    performance = {
        good = { "Strong output", "Knew the mechanics", "Great utility", "Carried" },
        average = { "Did their job", "Decent output", "No issues", "Learning the fights" },
        bad = { "Low output", "Died a lot", "Didn't know the fights", "Pulled too much", "AFK / distracted" },
    },
}

-- The Recent Allies note mirrors the review in 127 characters, and its
-- fixed "[PR] Social: X, Perf: Y - " prefix uses up to ~36 of those, so
-- roughly this much of a note survives there.
local NOTE_SOFT_LIMIT = 90

-- Resizes an already-open review window to the current /pr options size
-- without rebuilding it (so nothing typed or scrolled is lost). BuildFrame
-- applies the same numbers on every build, which covers the next review.
function ReviewPrompt:ApplyWindowSize()
    local outer = self.frame
    if not outer or not outer.frame:IsShown() then return end
    local windowSettings = addon.db.global.settings.reviewWindow
    outer:SetWidth(windowSettings.width)
    outer:SetHeight(windowSettings.height)
    if self.formScroll then
        self.formScroll:SetHeight(windowSettings.height - 110)
    end
    outer:DoLayout()
    if self.formScroll then self.formScroll:DoLayout() end
end

function ReviewPrompt:BuildFrame()
    local data = self.current

    if not self.frame then
        local frame = AceGUI:Create("Window")
        frame.frame:SetFrameStrata("DIALOG") -- AceGUI defaults to FULLSCREEN_DIALOG, which sits above the game's confirmation popups
        -- List (not Fill): the form scrolls in the top part and a fixed
        -- footer (status line + Skip/Save) sits underneath it, so Save is
        -- always visible instead of at the bottom of the scroll content.
        frame:SetLayout("List")
        frame:EnableResize(false)
        frame:SetCallback("OnClose", function()
            -- closing the window counts as skipping the current player
            self:Skip()
        end)
        self.frame = frame
    end

    local outer = self.frame
    -- Applied on every build (not just first creation) so a size change
    -- made in /pr options takes effect on the very next review prompt,
    -- without needing a /reload - the frame widget itself is created once
    -- and reused for every subsequent review.
    local windowSettings = addon.db.global.settings.reviewWindow
    outer:SetWidth(windowSettings.width)
    outer:SetHeight(windowSettings.height)
    outer:ReleaseChildren()
    outer:SetTitle(self.editingReviewID
        and ("Edit Review: " .. addon:GetShortName(data.nameRealm))
        or string.format("Review: %s   %d of %d", addon:GetShortName(data.nameRealm), self.shownCount, self.batchTotal))
    outer:Show()

    -- Scrollable so a long form doesn't overflow the fixed-height window.
    -- Its height leaves room under it for the fixed footer (status line +
    -- buttons) added to `outer` at the end of this function.
    local frame = AceGUI:Create("ScrollFrame")
    frame:SetLayout("List")
    frame:SetFullWidth(true)
    frame:SetHeight(windowSettings.height - 110)
    outer:AddChild(frame)

    -- Everything below belongs to this build only - rating clicks update
    -- these widgets in place rather than rebuilding the whole window.
    self.formScroll = frame
    self.noteBoxes = {}
    self.ratingBoxes = {}
    self.chipRows = {}
    self.noteHint = nil
    self.saveBtn = nil

    local header = AceGUI:Create("Label")
    header:SetFullWidth(true)
    local headerText = data.encounter or "Unknown"
    local remaining = (self.batchTotal or 0) - (self.shownCount or 0)
    if not self.editingReviewID and remaining > 0 then
        headerText = headerText .. "   |cff999999- " .. remaining .. " more after this one|r"
    end
    header:SetText(headerText)
    frame:AddChild(header)

    -- Visible before writing/editing a review so a repeat encounter with
    -- the same "random" isn't invisible - doesn't list them inline here,
    -- just the count; full history with chat/meter per session lives in
    -- Browser's Sessions section.
    local sessionCount = #addon:GetSessionsForPlayer(data.nameRealm)
    if sessionCount > 0 then
        local sessionNote = AceGUI:Create("Label")
        sessionNote:SetFullWidth(true)
        sessionNote:SetText(string.format("|cffffd100%d previous session(s)|r with this player - see Browser for full history.", sessionCount))
        frame:AddChild(sessionNote)
    end

    local roleDropdown = AceGUI:Create("Dropdown")
    roleDropdown:SetLabel(data.role and "Role (auto-filled, editable)" or "Role (not detected - pick one)")
    roleDropdown:SetList(ROLE_LABELS, ROLE_ORDER)
    roleDropdown:SetValue(self.form.role)
    roleDropdown:SetWidth(200)
    roleDropdown:SetCallback("OnValueChanged", function(widget, event, value)
        self.form.role = value
    end)
    frame:AddChild(roleDropdown)

    self:AddRatingSection(frame, "social", L["Social"])
    self:AddRatingSection(frame, "performance", L["Performance"])

    -- Plain divider line between the rating form above and the fight
    -- data/chat below - AceGUI's own "Heading" widget draws a full-width
    -- horizontal line, an empty label is enough to get just the line.
    local divider = AceGUI:Create("Heading")
    divider:SetText("Fight details")
    divider:SetFullWidth(true)
    frame:AddChild(divider)

    self:AddDetails(frame, data)

    -- Fixed footer, outside the scrolling form: a one-line status that
    -- always says whether the review can be saved (and what's missing),
    -- then Skip/Save. The status is one line in both states, so its
    -- height never changes when its text does (no relayout needed).
    local hint = AceGUI:Create("Label")
    hint:SetFullWidth(true)
    hint:SetText(" ")
    outer:AddChild(hint)
    self.noteHint = hint

    local buttonRow = AceGUI:Create("SimpleGroup")
    buttonRow:SetFullWidth(true)
    buttonRow:SetLayout("Flow")

    local skipBtn = AceGUI:Create("Button")
    skipBtn:SetText(self.editingReviewID and "Cancel" or L["Skip"])
    skipBtn:SetWidth(100)
    skipBtn:SetCallback("OnClick", function() self:Skip() end)
    buttonRow:AddChild(skipBtn)

    -- Reads "Save as Average" while nothing has been touched (see
    -- RefreshRequirements) - the one-click path for an unremarkable run.
    local saveBtn = AceGUI:Create("Button")
    saveBtn:SetText(L["Save"])
    saveBtn:SetWidth(150)
    saveBtn:SetCallback("OnClick", function() self:Save() end)
    buttonRow:AddChild(saveBtn)
    self.saveBtn = saveBtn

    outer:AddChild(buttonRow)

    self:RefreshRequirements()
end

-- Tints the EditBox's own border art (the Left/Middle/Right textures of
-- Blizzard's InputBoxTemplate) rather than drawing anything extra around
-- it. White (1,1,1) is "no tint". EditBox widgets are pooled and shared
-- with other parts of the addon (Browser's search box), so the tint is
-- also cleared whenever the widget is released - otherwise a recycled box
-- could keep a stale red border somewhere it doesn't belong.
local function TintInputBorder(note, r, g, b)
    if not note.prtrackerTintHooked then
        note.prtrackerTintHooked = true
        local originalOnRelease = note.OnRelease
        note.OnRelease = function(self, ...)
            for _, region in ipairs({ self.editbox:GetRegions() }) do
                if region.IsObjectType and region:IsObjectType("Texture") then
                    region:SetVertexColor(1, 1, 1)
                end
            end
            if originalOnRelease then return originalOnRelease(self, ...) end
        end
    end
    for _, region in ipairs({ note.editbox:GetRegions() }) do
        if region.IsObjectType and region:IsObjectType("Texture") then
            region:SetVertexColor(r, g, b)
        end
    end
end

local function CounterText(text)
    local n = #strtrim(text or "")
    if n == 0 then return "" end
    if n > NOTE_SOFT_LIMIT then
        return "  |cffff9933" .. n .. "/" .. NOTE_SOFT_LIMIT .. " - cut short in Recent Allies|r"
    end
    return "  |cff777777" .. n .. "/" .. NOTE_SOFT_LIMIT .. "|r"
end

-- Recomputes everything that depends on which notes are required and
-- filled in: each note's label, character counter and red border, the
-- footer status line, and Save's enabled state and caption. Called after
-- every build and on every keystroke in a note box.
function ReviewPrompt:RefreshRequirements()
    local form = self.form
    local missing = {}

    for _, entry in ipairs({ { "social", "Social" }, { "performance", "Performance" } }) do
        local key, name = entry[1], entry[2]
        local required = form[key] ~= "average"
        local noteText = form[key .. "Note"] or ""
        local empty = strtrim(noteText) == ""
        local note = self.noteBoxes and self.noteBoxes[key]

        if note then
            if required and empty then
                note:SetLabel("|cffff4040" .. name .. " note - required for a " .. RATING_LABELS[form[key]] .. " rating|r")
            elseif required then
                note:SetLabel(name .. " note (required for a " .. RATING_LABELS[form[key]] .. " rating)" .. CounterText(noteText))
            else
                note:SetLabel("|cff999999" .. name .. " note (optional)|r" .. CounterText(noteText))
            end
            if required and empty then
                TintInputBorder(note, 1, 0.25, 0.25)
            else
                TintInputBorder(note, 1, 1, 1)
            end
        end

        if required and empty then table.insert(missing, name) end
    end

    if self.noteHint then
        if #missing > 0 then
            self.noteHint:SetText("|cffff4040Add a note for " .. table.concat(missing, " and ") .. " to save.|r")
        else
            self.noteHint:SetText("|cff40ff40Ready to save.|r")
        end
    end
    if self.saveBtn then
        self.saveBtn:SetDisabled(#missing > 0)
        local untouched = form.social == "average" and form.performance == "average"
            and strtrim(form.socialNote or "") == "" and strtrim(form.performanceNote or "") == ""
        self.saveBtn:SetText(untouched and "Save as Average" or L["Save"])
    end
end

-- Switches a rating in place (no window rebuild, so scroll position and
-- anything typed stay put): updates the radios, swaps the quick tags, and
-- jumps into the note when it just became required.
function ReviewPrompt:SelectRating(key, value)
    self.form[key] = value
    for v, cb in pairs(self.ratingBoxes[key]) do
        cb:SetValue(v == value)
    end
    self:FillChips(key)
    self:RefreshRequirements()
    -- The chip row's height changed after the form was laid out.
    if self.formScroll then self.formScroll:DoLayout() end
    if value ~= "average" and self.noteBoxes[key] then
        self.noteBoxes[key]:SetFocus()
    end
end

-- Rebuilds one section's quick-tag buttons for its current rating.
function ReviewPrompt:FillChips(key)
    local row = self.chipRows[key]
    row:ReleaseChildren()

    local tags = TAGS[key][self.form[key]]
    if tags then
        for _, tag in ipairs(tags) do
            local btn = AceGUI:Create("Button")
            btn:SetText(tag)
            btn:SetAutoWidth(true)
            btn:SetHeight(20)
            btn:SetCallback("OnClick", function() self:AddTag(key, tag) end)
            row:AddChild(btn)
        end
    else
        row:DoLayout()
    end
end

function ReviewPrompt:AddTag(key, tag)
    local noteKey = key .. "Note"
    local current = strtrim(self.form[noteKey] or "")
    -- Already there (clicked twice, or typed by hand) - nothing to add.
    if current:lower():find(tag:lower(), 1, true) then return end

    local updated = current == "" and tag or (current .. ", " .. tag)
    self.form[noteKey] = updated
    -- SetText doesn't fire OnTextChanged (the widget treats it as its own
    -- change), so the form and requirements are updated here directly.
    self.noteBoxes[key]:SetText(updated)
    self:RefreshRequirements()
end

-- Three CheckBox widgets styled as radios (AceGUI has no native radio-group
-- widget), updated in place by SelectRating. The note field is always shown
-- (optional for Average, required otherwise - see RefreshRequirements) so an
-- Average rating can still carry context.
function ReviewPrompt:AddRatingSection(frame, key, label)
    local heading = AceGUI:Create("Label")
    heading:SetFullWidth(true)
    heading:SetText(label)
    frame:AddChild(heading)

    local row = AceGUI:Create("SimpleGroup")
    row:SetFullWidth(true)
    row:SetLayout("Flow")

    self.ratingBoxes[key] = {}
    for _, value in ipairs(RATING_ORDER) do
        local cb = AceGUI:Create("CheckBox")
        cb:SetLabel(RATING_COLORS[value] .. RATING_LABELS[value] .. "|r")
        cb:SetType("radio")
        cb:SetWidth(120)
        cb:SetValue(self.form[key] == value)
        cb:SetCallback("OnValueChanged", function(widget, event, checked)
            if not checked then
                -- A radio can't be un-chosen - put the check back.
                widget:SetValue(self.form[key] == value)
                return
            end
            self:SelectRating(key, value)
        end)
        row:AddChild(cb)
        self.ratingBoxes[key][value] = cb
    end
    frame:AddChild(row)

    local noteKey = key .. "Note"
    local note = AceGUI:Create("EditBox")
    note:SetFullWidth(true)
    -- Real label text, border tint and Save state are all applied by
    -- RefreshRequirements (once every widget exists, and again on every
    -- keystroke) - this is just a placeholder until then.
    note:SetLabel(" ")
    note:SetText(self.form[noteKey] or "")
    note:SetCallback("OnTextChanged", function(widget, event, text)
        self.form[noteKey] = text
        self:RefreshRequirements()
    end)
    -- Enter walks the form: Social -> Performance -> save (when valid),
    -- which makes a run of queued reviews doable from the keyboard.
    note:SetCallback("OnEnterPressed", function(widget, event, text)
        self.form[noteKey] = text
        self:RefreshRequirements()
        if key == "social" then
            if self.noteBoxes.performance then self.noteBoxes.performance:SetFocus() end
        elseif self.saveBtn and not self.saveBtn.disabled then
            self:Save()
        end
    end)
    frame:AddChild(note)
    self.noteBoxes[key] = note

    -- Quick tags are filled before the row is added, so it has its final
    -- height by the time anything is laid out under it.
    local chips = AceGUI:Create("SimpleGroup")
    chips:SetFullWidth(true)
    chips:SetLayout("Flow")
    self.chipRows[key] = chips
    self:FillChips(key)
    frame:AddChild(chips)
end

-- Fight stats, the DPS chart and the chat log, shown inline under the
-- "Fight details" heading. When there's nothing to show, an empty state
-- says why (instead of the section just silently being absent).
function ReviewPrompt:AddDetails(frame, data)
    local hasFights = data.fights and #data.fights > 0
    local hasChat = data.guid and #addon:GetModule("ChatLog"):GetMessages(data.guid) > 0

    if hasFights or hasChat then
        self:AddFightSelectionSection(frame, data)
        self:AddChatLogSection(frame, data)
        return
    end

    local reason
    if self.editingReviewID then
        reason = "Fight stats and chat aren't available when editing a saved review."
    elseif not data.guid then
        reason = "This review was started by name, so no fight stats or chat were captured. They're only recorded while you're grouped with someone."
    else
        reason = "No fights or chat were recorded while you were grouped with this player."
    end

    local empty = AceGUI:Create("Label")
    empty:SetFullWidth(true)
    empty:SetText("|cff888888" .. reason .. "|r")
    frame:AddChild(empty)
end

-- One checkbox per fight recorded while grouped with this player (all
-- checked by default), plus a live preview of what the resulting
-- aggregate DPS/HPS would be from whatever's currently checked - lets a
-- fight that isn't representative (a wipe, AFK time counted as combat,
-- whatever) get excluded before it skews the review's own numbers.
-- Nothing shown when there's nothing to pick from (editing an old review,
-- or the synthetic /pr test prompt, both of which have no live fight data).
function ReviewPrompt:AddFightSelectionSection(frame, data)
    local fights = data.fights
    if not fights or #fights == 0 then return end

    local heading = AceGUI:Create("Label")
    heading:SetFullWidth(true)
    heading:SetText("Fights (uncheck any that shouldn't count):")
    frame:AddChild(heading)

    local preview = AceGUI:Create("Label")
    preview:SetFullWidth(true)
    frame:AddChild(preview)

    -- Two earlier attempts at a real graphical StatusBar (raw CreateFrame,
    -- either positioned by hand against a shared container, or wrapped in
    -- its own AceGUI row) both broke the layout of everything below the
    -- chart. The actual root cause wasn't that raw frames don't work in
    -- AceGUI - it was that chartContainer grew AFTER the widgets below it
    -- (fight checkboxes, chat, Skip/Save) were already positioned by
    -- frame's own List layout, and nothing told frame to recompute. This
    -- version fixes that directly: chartContainer gets an explicit
    -- SetHeight() driven by our own pixel math (it holds no AceGUI
    -- children for the layout engine to measure on its own), and every
    -- refresh forces frame:DoLayout() afterward so everything below
    -- re-flows to match.
    local chartHeading = AceGUI:Create("Label")
    chartHeading:SetFullWidth(true)
    chartHeading:SetText("Group DPS (selected fights) - highlighted background is who you're reviewing:")
    frame:AddChild(chartHeading)

    local chartContainer = AceGUI:Create("SimpleGroup")
    chartContainer:SetFullWidth(true)
    chartContainer:SetLayout(nil)
    frame:AddChild(chartContainer)

    local BAR_ROW_HEIGHT = 20
    local BAR_HEIGHT = 14
    local ROLE_ICON_SIZE = 14
    local NAME_WIDTH = 112
    local BAR_WIDTH = 160
    -- Breathing room between chartHeading's text and the first bar row -
    -- included in chartContainer's own SetHeight below so the fight
    -- checkboxes underneath still get pushed down to account for it.
    local CHART_TOP_PADDING = 6

    -- Role icons use Blizzard's long-standing LFG role atlas rather than
    -- a modern Atlas name, since it's confirmed present across every
    -- client flavor including Classic-style ones - safer bet for Forever.
    local ROLE_ICON_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
    local ROLE_TCOORDS = {
        tank = { 0, 19 / 64, 22 / 64, 41 / 64 },
        healer = { 20 / 64, 39 / 64, 1 / 64, 20 / 64 },
        dps = { 20 / 64, 39 / 64, 22 / 64, 41 / 64 },
    }

    -- Kept on the MODULE (self.chartBarRows), not a local here - this
    -- whole function re-runs from scratch every BuildFrame (every new
    -- review shown, every in-place rebuild), which creates a brand new
    -- chartContainer widget each time. AceGUI's own ReleaseChildren only
    -- knows how to release AceGUI-tracked widgets - the raw FontStrings/
    -- Textures/StatusBar we create directly on chartContainer.frame are
    -- invisible to it, so a local `barRows = {}` here would just leave
    -- the previous review's bars behind, un-hidden, every single time
    -- (confirmed in-game: repeated /pr testgroup runs pile up bars on
    -- top of each other). Reusing the same small set of raw frames for
    -- the module's whole lifetime, and re-parenting/repositioning them
    -- onto whatever the CURRENT chartContainer is, means there's only
    -- ever one live copy of each row - nothing is ever left orphaned on
    -- a frame nothing points to anymore.
    self.chartBarRows = self.chartBarRows or {}

    local function GetBarRow(index)
        local row = self.chartBarRows[index]
        local yOffset = -CHART_TOP_PADDING - (index - 1) * BAR_ROW_HEIGHT

        if row then
            row.roleIcon:SetParent(chartContainer.frame)
            row.roleIcon:ClearAllPoints()
            row.roleIcon:SetPoint("TOPLEFT", chartContainer.frame, "TOPLEFT", 0, yOffset - 1)

            row.nameText:SetParent(chartContainer.frame)
            row.nameText:ClearAllPoints()
            row.nameText:SetPoint("TOPLEFT", row.roleIcon, "TOPRIGHT", 4, 1)

            row.bg:SetParent(chartContainer.frame)
            row.bg:ClearAllPoints()
            row.bg:SetPoint("LEFT", row.nameText, "RIGHT", 6, 0)

            row.bar:SetParent(chartContainer.frame)
            row.bar:ClearAllPoints()
            row.bar:SetPoint("TOPLEFT", row.bg, "TOPLEFT", 0, 0)

            row.dpsText:SetParent(chartContainer.frame)
            row.dpsText:ClearAllPoints()
            row.dpsText:SetPoint("LEFT", row.bar, "RIGHT", 6, 0)

            row.outline:SetParent(chartContainer.frame)
            row.outline:ClearAllPoints()
            row.outline:SetPoint("TOPLEFT", row.bar, "TOPLEFT", 0, 0)

            return row
        end

        local roleIcon = chartContainer.frame:CreateTexture(nil, "OVERLAY")
        roleIcon:SetSize(ROLE_ICON_SIZE, ROLE_ICON_SIZE)
        roleIcon:SetPoint("TOPLEFT", chartContainer.frame, "TOPLEFT", 0, yOffset - 1)

        local nameText = chartContainer.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameText:SetJustifyH("LEFT")
        nameText:SetWidth(NAME_WIDTH)
        nameText:SetPoint("TOPLEFT", roleIcon, "TOPRIGHT", 4, 1)

        local bg = chartContainer.frame:CreateTexture(nil, "BACKGROUND")
        bg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
        bg:SetPoint("LEFT", nameText, "RIGHT", 6, 0)
        bg:SetSize(BAR_WIDTH, BAR_HEIGHT)

        local bar = CreateFrame("StatusBar", nil, chartContainer.frame)
        bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        bar:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)
        bar:SetSize(BAR_WIDTH, BAR_HEIGHT)
        bar:SetMinMaxValues(0, 1)

        local dpsText = chartContainer.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dpsText:SetJustifyH("LEFT")
        dpsText:SetPoint("LEFT", bar, "RIGHT", 6, 0)

        -- Marks "who you're reviewing" as a white outline traced around
        -- just the FILLED portion of their bar (width set per-refresh to
        -- match their actual dps fraction, not the whole track) - a solid
        -- background tint was tried first but a warm amber color reads as
        -- easily confusable with Rogue's class color on that member's bar,
        -- and filling the whole row regardless of their actual value was
        -- also more visual weight than wanted.
        --
        -- Built from four plain color textures rather than SetBackdrop -
        -- confirmed in-game that a flat SetBackdrop edgeFile (WHITE8X8)
        -- doesn't render a visible border at this size: the backdrop
        -- system expects an edge texture laid out as a proper multi-
        -- segment border sprite (like the default tooltip border), not a
        -- flat solid-color square, so it likely collapsed to nothing at
        -- edgeSize 1. Four independently-anchored strips sidestep that
        -- entirely and are guaranteed visible regardless of size.
        local OUTLINE_THICKNESS = 2
        local outline = CreateFrame("Frame", nil, chartContainer.frame)
        outline:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
        outline:SetHeight(BAR_HEIGHT)

        -- Gold (1, 0.82, 0) - the same accent color used everywhere else
        -- in this form (the reviewed player's dps text, |cffffd100 etc.).
        local outlineTop = outline:CreateTexture(nil, "OVERLAY")
        outlineTop:SetColorTexture(1, 0.82, 0, 1)
        outlineTop:SetPoint("TOPLEFT", outline, "TOPLEFT", 0, 0)
        outlineTop:SetPoint("TOPRIGHT", outline, "TOPRIGHT", 0, 0)
        outlineTop:SetHeight(OUTLINE_THICKNESS)

        local outlineBottom = outline:CreateTexture(nil, "OVERLAY")
        outlineBottom:SetColorTexture(1, 0.82, 0, 1)
        outlineBottom:SetPoint("BOTTOMLEFT", outline, "BOTTOMLEFT", 0, 0)
        outlineBottom:SetPoint("BOTTOMRIGHT", outline, "BOTTOMRIGHT", 0, 0)
        outlineBottom:SetHeight(OUTLINE_THICKNESS)

        local outlineLeft = outline:CreateTexture(nil, "OVERLAY")
        outlineLeft:SetColorTexture(1, 0.82, 0, 1)
        outlineLeft:SetPoint("TOPLEFT", outline, "TOPLEFT", 0, 0)
        outlineLeft:SetPoint("BOTTOMLEFT", outline, "BOTTOMLEFT", 0, 0)
        outlineLeft:SetWidth(OUTLINE_THICKNESS)

        local outlineRight = outline:CreateTexture(nil, "OVERLAY")
        outlineRight:SetColorTexture(1, 0.82, 0, 1)
        outlineRight:SetPoint("TOPRIGHT", outline, "TOPRIGHT", 0, 0)
        outlineRight:SetPoint("BOTTOMRIGHT", outline, "BOTTOMRIGHT", 0, 0)
        outlineRight:SetWidth(OUTLINE_THICKNESS)

        outline:Hide()

        row = { roleIcon = roleIcon, nameText = nameText, bg = bg, bar = bar, dpsText = dpsText, outline = outline }
        self.chartBarRows[index] = row
        return row
    end

    -- "X% of top, Y% of total" - how the aggregate dps compares to both
    -- the group's best performer and the group's combined output,
    -- duration-weighted the same way dps itself is, so it stays
    -- meaningful even across fights with different top performers.
    -- Doesn't try to average RANK across fights (1st in one, 3rd in
    -- another doesn't collapse into one honest number) - rank is only
    -- ever shown per-fight, below.
    local function RelativeSuffix(value, groupMax, groupTotal)
        if not value then return "" end
        local parts = {}
        if groupMax and groupMax > 0 then
            table.insert(parts, string.format("%d%% of group's best", math.floor(value / groupMax * 100)))
        end
        if groupTotal and groupTotal > 0 then
            table.insert(parts, string.format("%d%% of group total", math.floor(value / groupTotal * 100)))
        end
        if #parts == 0 then return "" end
        return " (" .. table.concat(parts, ", ") .. ")"
    end

    local function RefreshChart(breakdown)
        local maxDps, totalDps = 0, 0
        for _, m in ipairs(breakdown) do
            if m.dps and m.dps > maxDps then maxDps = m.dps end
            totalDps = totalDps + (m.dps or 0)
        end

        for i, m in ipairs(breakdown) do
            local row = GetBarRow(i)
            local isReviewed = (m.guid == data.guid)

            local coords = m.role and ROLE_TCOORDS[m.role]
            if coords then
                row.roleIcon:SetTexture(ROLE_ICON_TEXTURE)
                row.roleIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                row.roleIcon:Show()
            else
                row.roleIcon:Hide()
            end

            -- Class color (same RAID_CLASS_COLORS every unit frame/chat
            -- line uses) identifies WHO each bar is; a white outline
            -- traced around just the filled portion (below) marks WHICH
            -- one is being reviewed, so both pieces of information stay
            -- visible at once instead of one overriding the other.
            local classColor = m.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[m.class]
            local r, g, b = 0.9, 0.9, 0.9
            if classColor then
                r, g, b = classColor.r, classColor.g, classColor.b
            end

            row.nameText:SetText(addon:GetShortName(m.nameRealm))
            row.nameText:SetTextColor(r, g, b)
            row.bar:SetStatusBarColor(r, g, b)
            row.bg:SetColorTexture(0.15, 0.15, 0.15, 0.8)

            row.bar:SetMinMaxValues(0, maxDps > 0 and maxDps or 1)
            row.bar:SetValue(m.dps or 0)

            if isReviewed then
                -- Same fraction the StatusBar itself uses internally to
                -- size its fill texture, so the outline traces exactly
                -- the filled portion rather than the bar's whole track.
                local filledWidth = maxDps > 0 and math.max(2, (m.dps or 0) / maxDps * BAR_WIDTH) or 2
                row.outline:SetWidth(filledWidth)
                row.outline:Show()
            else
                row.outline:Hide()
            end

            -- Percentage of GROUP TOTAL for this exact set of bars - uses
            -- totalDps summed from this same breakdown rather than the
            -- separately-computed aggregate.groupTotalDps, so the
            -- percentage shown always matches what's actually drawn here
            -- (same reasoning as the groupMaxDps fix above).
            local pct = totalDps > 0 and math.floor((m.dps or 0) / totalDps * 100 + 0.5) or 0
            row.dpsText:SetText(string.format("(%d%%) %d DPS", pct, math.floor(m.dps or 0)))
            if isReviewed then
                row.dpsText:SetTextColor(1, 0.82, 0)
            else
                row.dpsText:SetTextColor(1, 1, 1)
            end

            row.nameText:Show()
            row.bg:Show()
            row.bar:Show()
            row.dpsText:Show()
        end

        -- Anything left over from a previous, larger breakdown (fewer
        -- fights selected can mean fewer distinct group members) is
        -- hidden rather than destroyed, ready to be reused if the count
        -- grows again on a later checkbox toggle.
        for i = #breakdown + 1, #self.chartBarRows do
            local row = self.chartBarRows[i]
            row.roleIcon:Hide()
            row.nameText:Hide()
            row.bg:Hide()
            row.bar:Hide()
            row.dpsText:Hide()
            row.outline:Hide()
        end

        -- chartContainer holds no AceGUI children (every bar above is a
        -- raw frame positioned by hand), so AceGUI has no way to know how
        -- tall it needs to be - tell it explicitly, then force frame's
        -- own List layout to recompute so everything below (fight
        -- checkboxes, chat, Skip/Save) re-flows to the chart's real
        -- height instead of staying stuck at its old (empty) offset.
        chartContainer:SetHeight(CHART_TOP_PADDING + math.max(#breakdown, 1) * BAR_ROW_HEIGHT)
        frame:DoLayout()
    end

    local UpdateAllRow

    local function RefreshPreview()
        local selectedIndices = {}
        for i in ipairs(fights) do
            if self.form.selectedFights[i] then table.insert(selectedIndices, i) end
        end
        local aggregate = addon:GetModule("ReviewCapture"):AggregateFights(fights, selectedIndices)
        preview:SetText(string.format("|cffffd100%d fight(s) selected|r - %s DPS%s / %s HPS%s",
            #selectedIndices,
            aggregate.dps and math.floor(aggregate.dps) or "-", RelativeSuffix(aggregate.dps, aggregate.groupMaxDps, aggregate.groupTotalDps),
            aggregate.hps and math.floor(aggregate.hps) or "-", RelativeSuffix(aggregate.hps, aggregate.groupMaxHps, aggregate.groupTotalHps)))
        RefreshChart(aggregate.groupBreakdown or {})
        if UpdateAllRow then UpdateAllRow() end
    end

    -- By default just "All fights (N)" - the per-fight list is what ate
    -- the vertical space, and most reviews keep every fight. "Choose
    -- fights..." expands it for picking individual ones.
    self.fightListExpanded = false
    local fightCount = #fights
    local fightBoxes = {}

    local selectRow = AceGUI:Create("SimpleGroup")
    selectRow:SetFullWidth(true)
    selectRow:SetLayout("Flow")

    local allCb = AceGUI:Create("CheckBox")
    allCb:SetWidth(230)
    selectRow:AddChild(allCb)

    local toggleBtn = AceGUI:Create("Button")
    toggleBtn:SetText("Choose fights...")
    toggleBtn:SetWidth(150)
    selectRow:AddChild(toggleBtn)
    frame:AddChild(selectRow)

    local listGroup = AceGUI:Create("SimpleGroup")
    listGroup:SetFullWidth(true)
    listGroup:SetLayout("List")
    frame:AddChild(listGroup)

    UpdateAllRow = function()
        local n = 0
        for i in ipairs(fights) do
            if self.form.selectedFights[i] then n = n + 1 end
        end
        allCb:SetValue(n == fightCount)
        allCb:SetLabel(n == fightCount and string.format("All fights (%d)", fightCount)
            or string.format("%d of %d fights selected", n, fightCount))
    end

    allCb:SetCallback("OnValueChanged", function(widget, event, checked)
        for i in ipairs(fights) do
            self.form.selectedFights[i] = checked or nil
        end
        for _, cb in pairs(fightBoxes) do
            cb:SetValue(checked and true or false)
        end
        RefreshPreview()
    end)

    -- Rebuilt on every expand/collapse; the list changes height after the
    -- form was laid out, so both containers re-flow.
    local function FillFightList()
        listGroup:ReleaseChildren()
        fightBoxes = {}
        -- Never leave the group empty: a List container with no children
        -- is sized to exactly 0, and a zero-height frame has no usable
        -- rectangle, so whatever is anchored below it (the chat box) was
        -- landing on top of the form. A blank Label is always at least 1px.
        local keepAlive = AceGUI:Create("Label")
        keepAlive:SetFullWidth(true)
        keepAlive:SetText("")
        listGroup:AddChild(keepAlive)
        if self.fightListExpanded then
            for i, fight in ipairs(fights) do
                local rankText = ""
                if fight.dpsRank and fight.groupDpsCount then
                    rankText = string.format(" - #%d of %d", fight.dpsRank, fight.groupDpsCount)
                end
                local fightLabel = fight.name and (fight.name .. " (Fight " .. i .. ")") or ("Fight " .. i)
                local cb = AceGUI:Create("CheckBox")
                cb:SetLabel(string.format("%s: %ds - %s DPS%s / %s HPS", fightLabel, fight.duration or 0,
                    fight.dps and math.floor(fight.dps) or "-", rankText, fight.hps and math.floor(fight.hps) or "-"))
                cb:SetFullWidth(true)
                cb:SetValue(self.form.selectedFights[i] or false)
                cb:SetCallback("OnValueChanged", function(widget, event, checked)
                    self.form.selectedFights[i] = checked or nil
                    RefreshPreview()
                end)
                listGroup:AddChild(cb)
                fightBoxes[i] = cb
            end
        end
        listGroup:DoLayout()
        frame:DoLayout()
    end

    toggleBtn:SetCallback("OnClick", function()
        self.fightListExpanded = not self.fightListExpanded
        toggleBtn:SetText(self.fightListExpanded and "Hide fight list" or "Choose fights...")
        FillFightList()
    end)

    FillFightList()

    RefreshPreview()
end

-- Read-only recap of party/say/whisper chat captured while grouped with
-- this player (yours and theirs - not other party members' chatter), so
-- there's something to go on besides raw stats when writing the note.
-- Saving this review is what actually persists this chat long-term - see
-- Save(). Nothing shown for the synthetic /pr test prompt (no guid), when
-- editing an old review (also no guid), or once nobody said anything.
function ReviewPrompt:AddChatLogSection(frame, data)
    if not data.guid then return end

    local messages = addon:GetModule("ChatLog"):GetMessages(data.guid)
    if #messages == 0 then return end

    local heading = AceGUI:Create("Label")
    heading:SetFullWidth(true)
    heading:SetText("Chat while grouped (saved with this review):")
    frame:AddChild(heading)

    local lines = {}
    for _, msg in ipairs(messages) do
        table.insert(lines, string.format("[%s] %s: %s", date("%H:%M", msg.time), msg.channel, msg.text))
    end

    local box = AceGUI:Create("MultiLineEditBox")
    box:SetLabel("")
    box:SetFullWidth(true)
    box:SetNumLines(6)
    box:SetText(table.concat(lines, "\n"))
    box:SetDisabled(true)
    frame:AddChild(box)
end
