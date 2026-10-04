local addon = PlayerReview
local LFGAnnotate = addon:NewModule("LFGAnnotate", "AceEvent-3.0")

-- Mouse-wheel scrolling is covered instantly by the OnMouseWheel hook
-- below, but dragging the scrollbar thumb doesn't reliably fire the
-- OnValueChanged hook the same way (confirmed in-game: wheel scrolling
-- has no flicker, dragging still does), so this ticker is the real
-- fallback for that case, not just a rare edge case - it needs to be
-- reasonably tight. Now cheap regardless of interval: resultID is read
-- directly off each frame (see UpdateRowBadge), so there's no more
-- O(total active results) prebuild cost per tick to worry about.
local SCAN_INTERVAL = 0.2
local MAX_DEPTH = 4

-- Confirmed via /pr findtext: a reviewed player's name showed up at
-- UIParent/LFGParentFrame/LFGBrowseFrame/LFGBrowseFrameScrollBox/?/? - two
-- unnamed levels below the ScrollBox. The ScrollBox is a virtualized list
-- (ScrollBoxListViewMixin): row frames are pooled/recycled as you scroll,
-- with no fixed global names, so this can't hook a specific named frame the
-- way the target/party frame badges do. Instead it re-scans the ScrollBox's
-- direct children (the row frames) every SCAN_INTERVAL and on search
-- results arriving.
--
-- WHO is reviewed comes from the real C_LFGList per-result and per-member
-- API (see FindReviewedMember below) checking every member of every
-- group, not from scanning row text against known reviewed players (that
-- could only ever see the listing's poster). Each matched frame's own
-- `.resultID` field (confirmed via /pr lfginspect) is what ties a visible
-- row to its real search result - no text-matching needed for that part
-- either. Row text is still collected here for one purpose: anchoring
-- the badge to something guaranteed visible. Collects {text=, region=}
-- pairs rather than plain strings for that anchoring: the FontString
-- region is guaranteed visible (its text is what's on screen), unlike
-- the outer row frame, whose bounds/clipping don't necessarily match its
-- visible content in a pooled ScrollBox list.
local function CollectFontStrings(frame, depth, out)
    if depth > MAX_DEPTH or not frame then return end
    if frame.IsForbidden and frame:IsForbidden() then return end

    if frame.GetRegions then
        pcall(function()
            for _, region in ipairs({ frame:GetRegions() }) do
                if region.GetObjectType and region:GetObjectType() == "FontString" then
                    local text = region:GetText()
                    if text and text ~= "" then table.insert(out, { text = text, region = region }) end
                end
            end
        end)
    end

    if frame.GetChildren then
        local ok, children = pcall(function() return { frame:GetChildren() } end)
        if ok then
            for _, child in ipairs(children) do
                CollectFontStrings(child, depth + 1, out)
            end
        end
    end
end

-- LFG rows aren't units, so the world-tooltip hook (Tooltip.lua's
-- OnTooltipSetUnit) can't reach them at all - GameTooltip only knows about
-- units, not arbitrary frames. Several approaches tried for WHERE our
-- lines land relative to Blizzard's own group-info content:
--   - Appending immediately in OnEnter: content shows reliably, but lands
--     ABOVE (visually overlapping) Blizzard's own first line instead of
--     below it.
--   - Deferred 150ms, 50ms, and via a global GameTooltip OnShow hook, all
--     hoping to land after Blizzard's content populates: every one of
--     these broke content from showing at all (GameTooltip:IsShown() or
--     GetOwner() no longer matched by the time the deferred code ran).
--     Even 50ms wasn't safe, which rules out "the mouse just moved away
--     during testing" as the explanation - whatever tooltip state exists
--     immediately on hover doesn't survive into the next tick reliably.
--   - A ClearAllPoints/SetPoint override to force the tooltip further
--     right: had no visible effect at all, meaning something (most likely
--     Blizzard's own logic) re-asserts its own position afterward.
-- Settled on immediate, undeferred appending: the only version confirmed
-- to reliably show content at all. The visual overlap with Blizzard's own
-- first line is a real but accepted cosmetic limitation - winning that
-- fight would need continuously re-asserting content/position (e.g. via
-- OnUpdate) against whatever Blizzard does, which is real ongoing cost for
-- a purely cosmetic fix.
local function AppendReviewToTooltip(row, review, nameRealm, memberNote)
    local tooltipSettings = addon.db.global.settings.tooltip
    if not GameTooltip:IsOwned(row) then
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT", tooltipSettings.lfgOffsetX, tooltipSettings.lfgOffsetY)
    end
    if tooltipSettings.paddingRight and tooltipSettings.paddingRight > 0 then
        pcall(function() GameTooltip:SetPadding(tooltipSettings.paddingRight) end)
    end
    local vars = addon:GetReviewTooltipVars(review, nameRealm, { memberNote = memberNote or "" })
    for _, renderedLine in ipairs(addon:RenderTooltipTemplate(tooltipSettings.lfgTemplate, vars)) do
        GameTooltip:AddLine(renderedLine, 1, 1, 1, true)
    end
    GameTooltip:Show()
end

-- A listing row is: leader name + level, then the gray activity name
-- ("Wailing Caverns"), then the playstyle. This finds that activity
-- FontString by position - the second line of the left-aligned text
-- column - so the leader's area can be drawn right after it. (The level
-- and "Roles:" texts are excluded by not sharing the column's left edge.)
local function FindActivityFontString(frame, entries)
    local candidates = {}
    for _, entry in ipairs(entries) do
        local region = entry.region
        if region and region ~= frame.PlayerReviewAreaText and region:GetParent() == frame
            and entry.text and entry.text ~= "" then
            local ok, top, left = pcall(function() return region:GetTop(), region:GetLeft() end)
            if ok and top and left then
                table.insert(candidates, { region = region, top = top, left = left })
            end
        end
    end
    if #candidates < 2 then return nil end

    local minLeft = math.huge
    for _, c in ipairs(candidates) do
        if c.left < minLeft then minLeft = c.left end
    end
    local column = {}
    for _, c in ipairs(candidates) do
        if c.left - minLeft < 3 then table.insert(column, c) end
    end
    table.sort(column, function(x, y) return x.top > y.top end)
    return column[2] and column[2].region or nil
end

-- The listing leader's current area ("The Barrens"), drawn on the row
-- itself as "- <area>" right after the activity name. GetSearchResultLeaderInfo
-- carries an areaName for every listing (confirmed via /pr lfgapi2),
-- reviewed or not. The FontString is created once per row frame and
-- stashed on it (the scroll list recycles these frames, and this text is
-- re-set - or hidden - on every scan, so a recycled row never keeps
-- another listing's area). If the activity text can't be found it falls
-- back to a fixed corner of the row (settings.lfg.loc*).
local function UpdateRowLocation(frame, area, activityFS)
    local text = frame.PlayerReviewAreaText
    if not area then
        if text then text:Hide() end
        return
    end

    if not text then
        text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        text:SetTextColor(0.62, 0.78, 1)
        frame.PlayerReviewAreaText = text
    end
    text:ClearAllPoints()
    if activityFS then
        text:SetPoint("LEFT", activityFS, "RIGHT", 4, 0)
        text:SetText("- " .. area)
    else
        local s = addon.db.global.settings.lfg
        text:SetPoint(s.locAnchor, frame, s.locRel, s.locX, s.locY)
        text:SetText(area)
    end
    text:Show()
end

local function SetupRowHover(row)
    if row.PlayerReviewHoverHooked then return end

    local ok, err = pcall(function()
        row:HookScript("OnEnter", function(self)
            local review = self.PlayerReviewCurrent
            if LFGAnnotate.debug then
                addon:Print(string.format("[lfg debug] OnEnter fired, self=%s, review=%s", tostring(self), tostring(review ~= nil)))
            end
            if not review then return end
            AppendReviewToTooltip(self, review, self.PlayerReviewNameRealm, self.PlayerReviewMemberNote)
        end)

        -- Missing in a recent edit - without this, nothing ever hides the
        -- tooltip, so re-hovering the same row calls AddLine again on
        -- content that's still there, stacking up duplicate "Reviewed"
        -- blocks instead of starting fresh each time.
        row:HookScript("OnLeave", function(self)
            if GameTooltip:GetOwner() == self then
                GameTooltip:Hide()
            end
        end)
    end)

    if not ok then
        addon:Print("|cffff4040LFG row hover hook failed|r: " .. tostring(err))
        return
    end

    row.PlayerReviewHoverHooked = true
end

-- Checks EVERY member of one group (not just the leader/poster) against
-- reviews - this is what lets a group get flagged as "contains a
-- reviewed player" even when the reviewed player didn't post the
-- listing. Returns the review, the matched member's raw name, and
-- whether they're the leader, or nil if nobody in the group is reviewed.
local function FindReviewedMember(resultID, numMembers)
    for memberIndex = 1, numMembers do
        local ok, member = pcall(C_LFGList.GetSearchResultPlayerInfo, resultID, memberIndex)
        if ok and type(member) == "table" and member.name and member.name ~= "" then
            local nameRealm = addon:NormalizeChatSender(member.name)
            local review = nameRealm and addon:GetLatestReview(nameRealm)
            if LFGAnnotate.debug then
                addon:Print(string.format("[lfg debug]   member[%d] name=%q -> nameRealm=%q reviewed=%s",
                    memberIndex, tostring(member.name), tostring(nameRealm), tostring(review ~= nil)))
            end
            if review then
                return review, member.name, member.isLeader
            end
        elseif LFGAnnotate.debug then
            addon:Print(string.format("[lfg debug]   member[%d] GetSearchResultPlayerInfo failed/empty: ok=%s member=%s",
                memberIndex, tostring(ok), tostring(member)))
        end
    end
    return nil
end

-- Confirmed via /pr lfginspect: each matched entry's inner frame (the
-- FontString's own parent) carries a real `.resultID` field directly -
-- no text-matching or guessing needed at all. This replaced an earlier
-- approach that probed C_LFGList.GetSearchResultInfo(1..count) assuming
-- sequential IDs; that assumption was wrong (confirmed real IDs like
-- 617/647/654/659/663/667/698/705 on a single row, nowhere near 1-100),
-- which is exactly why that approach intermittently (and eventually
-- consistently) found nothing despite rows being visibly populated.
-- Adds each match's inner frame to `activeFrames` so the caller can hide
-- badges on frames that stop matching. Returns the number of badges
-- shown, for debug counting.
local function UpdateRowBadge(row, textCounter, activeFrames)
    local entries = {}
    CollectFontStrings(row, 0, entries)
    if textCounter then textCounter[1] = textCounter[1] + #entries end

    local shown = 0
    local matchedFrames = {}  -- guards one inner frame from being processed twice in the same row

    -- Badge/hover setup (CreateTexture etc.) on a forbidden frame could
    -- plausibly throw - pcall so one bad row can't kill the whole scan
    -- pass silently.
    local ok = pcall(function()
        for _, entry in ipairs(entries) do
            local innerFrame = entry.region:GetParent()
            local resultID = innerFrame and innerFrame.resultID
            if resultID and not matchedFrames[innerFrame] then
                matchedFrames[innerFrame] = true
                local okInfo, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
                if okInfo and type(info) == "table" then
                    if LFGAnnotate.debug then
                        addon:Print(string.format("[lfg debug] resultID=%d (%q) numMembers=%s",
                            resultID, tostring(entry.text), tostring(info.numMembers)))
                    end
                    local review, memberName, isLeader = FindReviewedMember(resultID, info.numMembers or 1)

                    -- The leader's current area, shown on the row.
                    local area
                    if addon.db.global.settings.lfg.showLocation then
                        local okLeader, leader = pcall(C_LFGList.GetSearchResultLeaderInfo, resultID)
                        if okLeader and type(leader) == "table" and leader.areaName and leader.areaName ~= "" then
                            area = leader.areaName
                        end
                    end
                    UpdateRowLocation(innerFrame, area, area and FindActivityFontString(innerFrame, entries))

                    if review then
                        innerFrame.PlayerReviewCurrent = review
                        innerFrame.PlayerReviewNameRealm = addon:NormalizeChatSender(memberName)
                        -- Blank for the leader/poster (redundant - the
                        -- row already shows their name); a real value
                        -- when a DIFFERENT group member is the
                        -- reviewed one, since that's not otherwise
                        -- visible anywhere on the row.
                        innerFrame.PlayerReviewMemberNote = (not isLeader)
                            and ("|cffffd100Group member:|r " .. memberName) or ""
                        SetupRowHover(innerFrame)
                        local b = addon.db.global.settings.badge
                        -- "name" (the matched FontString) is the default
                        -- but shifts between a leader's and a regular
                        -- member's row layout; the other options are
                        -- stable regardless. Falls back to the name
                        -- region if the chosen sub-element doesn't exist
                        -- on this particular frame (e.g. a client build
                        -- without ClassIcon), rather than erroring.
                        local anchorTo = entry.region
                        if b.lfgAnchorTarget == "frame" then
                            anchorTo = innerFrame
                        elseif b.lfgAnchorTarget == "classIcon" and innerFrame.ClassIcon then
                            anchorTo = innerFrame.ClassIcon
                        elseif b.lfgAnchorTarget == "resultBG" and innerFrame.ResultBG then
                            anchorTo = innerFrame.ResultBG
                        end
                        addon:ShowReviewBadge(innerFrame, review, b.lfgSize, b.lfgAnchorPoint, b.lfgRelPoint,
                            b.lfgOffsetX, b.lfgOffsetY, anchorTo)
                        activeFrames[innerFrame] = true
                        shown = shown + 1
                    else
                        addon:HideReviewBadge(innerFrame)
                        -- Recycled frame: don't leave the previous
                        -- listing's review for the hover to pick up.
                        innerFrame.PlayerReviewCurrent = nil
                        innerFrame.PlayerReviewNameRealm = nil
                        innerFrame.PlayerReviewMemberNote = nil
                    end
                elseif LFGAnnotate.debug then
                    addon:Print(string.format("[lfg debug] resultID=%d found on frame but GetSearchResultInfo failed: ok=%s info=%s",
                        resultID, tostring(okInfo), tostring(info)))
                end
            end
        end
    end)

    return ok and shown or 0
end

-- No longer takes a forceRebuildIndex param - that existed to gate an
-- O(total active results) prebuild step which resultID-on-frame reading
-- (see UpdateRowBadge) made unnecessary. Callers that still pass an
-- argument (the ticker, LFG_LIST_SEARCH_RESULTS_RECEIVED) are harmless -
-- Lua just ignores the extra value.
function LFGAnnotate:ScanBrowseResults()
    local scrollBox = _G["LFGBrowseFrameScrollBox"]
    if not scrollBox then
        if self.debug then addon:Print("[lfg debug] LFGBrowseFrameScrollBox not found") end
        return
    end

    -- Attached lazily here (not in OnEnable) since the LFG panel's frames
    -- don't exist until Blizzard_LookingForGroupUI has actually loaded,
    -- which OnEnable can't wait for. Scrolling forces an immediate rescan
    -- instead of waiting up to SCAN_INTERVAL, covering both mouse-wheel
    -- and scrollbar-drag - the internal structure isn't guaranteed across
    -- client builds, so this is pcall'd and just no-ops (falling back to
    -- the ticker alone) if either hook point doesn't exist.
    if not self.scrollHooked then
        pcall(function()
            scrollBox:HookScript("OnMouseWheel", function() LFGAnnotate:ScanBrowseResults() end)
        end)
        pcall(function()
            if scrollBox.ScrollBar then
                scrollBox.ScrollBar:HookScript("OnValueChanged", function() LFGAnnotate:ScanBrowseResults() end)
            end
        end)
        -- Confirmed via /pr lfginspect + this diagnostic block itself:
        -- this scrollBox is CallbackRegistryMixin-based (ScrollBoxListView
        -- Mixin), and there's no "OnScroll" event - the real ones are
        -- OnReleasedFrame/OnAcquiredFrame/OnDataChanged/OnInitializedFrame/
        -- OnDataProviderReassigned. OnAcquiredFrame is the right fit: it
        -- fires whenever a row frame gets populated with new content from
        -- the pool, which happens exactly when rows get recycled during
        -- scrolling - wheel or scrollbar-drag alike - unlike the
        -- ScrollBar.OnValueChanged HookScript above, which only reliably
        -- fires for wheel ticks.
        local callbackOk, callbackAttached = pcall(function()
            if scrollBox.RegisterCallback and ScrollBoxListViewMixin and ScrollBoxListViewMixin.Event
                and ScrollBoxListViewMixin.Event.OnAcquiredFrame then
                scrollBox:RegisterCallback(ScrollBoxListViewMixin.Event.OnAcquiredFrame, function()
                    LFGAnnotate:ScanBrowseResults()
                end, LFGAnnotate)
                return true
            end
            return false
        end)
        if not (callbackOk and callbackAttached) then
            addon:Print("|cffff4040LFG scroll-acquire hook failed|r - drag-scrolling may lag behind the ticker: "
                .. tostring(callbackAttached))
        end
        self.scrollHooked = true
    end

    if not scrollBox.IsShown or not scrollBox:IsShown() then
        if self.debug then addon:Print("[lfg debug] LFGBrowseFrameScrollBox found but not shown") end
        return
    end

    local ok, rows = pcall(function() return { scrollBox:GetChildren() } end)
    if not ok then
        if self.debug then addon:Print("[lfg debug] GetChildren() failed: " .. tostring(rows)) end
        return
    end

    -- No more result-index prebuild/cache needed - resultID is read
    -- directly off each matched frame now, so this is already cheap
    -- (a handful of frames, not O(total active results)) without needing
    -- a snapshot-and-reuse strategy.
    local textCounter = { 0 }
    local badgeCount = 0
    local activeFrames = {}
    for _, row in ipairs(rows) do
        badgeCount = badgeCount + UpdateRowBadge(row, textCounter, activeFrames)
    end

    -- Badges now live on inner frames rather than the row itself, so a
    -- frame badged on a previous tick that no longer matches (the list
    -- scrolled, a different/unreviewed player is now shown there) needs
    -- to be explicitly hidden - nothing else will notice it's stale.
    for frame in pairs(self.previousActiveFrames or {}) do
        if not activeFrames[frame] then
            addon:HideReviewBadge(frame)
        end
    end
    self.previousActiveFrames = activeFrames

    if self.debug then
        addon:Print(string.format("[lfg debug] rows=%d, texts collected=%d, badges shown=%d, reviewed players known=%d",
            #rows, textCounter[1], badgeCount, #addon:GetAllPlayers()))
    end
end

-- Read-only exploration of one visible row's full frame tree, to check
-- two things without risking any live behavior: (1) whether OTHER group
-- members' names - not just the poster's, which is all UpdateRowBadge
-- currently matches against - are present anywhere as text in the row,
-- even if not visually obvious, and (2) whether the row (or any of its
-- FontStrings' parent frames) stores a real resultID/table Blizzard uses
-- internally, as opposed to the sequential 1/2/3 guesses InspectAPI tried
-- - which all came back nil, but a real ID pulled from the row itself
-- might behave completely differently.
function LFGAnnotate:InspectRow(rowIndex)
    local scrollBox = _G["LFGBrowseFrameScrollBox"]
    if not scrollBox then
        addon:Print("LFGBrowseFrameScrollBox not found - open Group Finder first.")
        return
    end

    local ok, rows = pcall(function() return { scrollBox:GetChildren() } end)
    if not ok or #rows == 0 then
        addon:Print("No rows found.")
        return
    end

    rowIndex = tonumber(rowIndex) or 1
    local row = rows[rowIndex]
    if not row then
        addon:Print(string.format("Only %d row(s) currently exist - try a number in that range.", #rows))
        return
    end

    local lines = { string.format("-- Inspecting row %d of %d --", rowIndex, #rows) }

    local entries = {}
    CollectFontStrings(row, 0, entries)
    table.insert(lines, string.format("FontStrings found (%d):", #entries))
    for i, entry in ipairs(entries) do
        table.insert(lines, string.format("  [%d] %q", i, entry.text))
    end

    local function DumpFields(label, frame)
        if not frame then return end
        local ok2, err = pcall(function()
            table.insert(lines, "Fields on " .. label .. ":")
            local count = 0
            for k, v in pairs(frame) do
                local t = type(v)
                if t == "number" or t == "string" or t == "boolean" then
                    table.insert(lines, string.format("  %s (%s) = %s", tostring(k), t, tostring(v)))
                    count = count + 1
                elseif t == "table" then
                    table.insert(lines, string.format("  %s (table)", tostring(k)))
                    count = count + 1
                end
            end
            if count == 0 then table.insert(lines, "  (nothing readable)") end
        end)
        if not ok2 then table.insert(lines, "  (failed: " .. tostring(err) .. ")") end
    end

    DumpFields("the row itself", row)
    local seenParents = {}
    for _, entry in ipairs(entries) do
        local parent = entry.region:GetParent()
        if not seenParents[parent] then
            seenParents[parent] = true
            DumpFields(string.format("parent of %q", entry.text), parent)
        end
    end

    addon:GetModule("Export"):ShowText("LFG Row " .. rowIndex .. " Inspect", table.concat(lines, "\n"))
end

-- One-shot exploration of C_LFGList, the official documented API for
-- Group Finder data - if it exposes member names directly, that would
-- replace the entire FontString-scraping approach above with a proper
-- data lookup instead of scanning on-screen text, sidestepping the pooled-
-- row/clipping/ordering fragility that's caused most of tonight's issues.
-- Pcall'd per-call since we have no idea yet which of these functions
-- exist or what shape they return on this client.
function LFGAnnotate:InspectAPI()
    if not C_LFGList then
        addon:Print("C_LFGList does not exist on this client.")
        return
    end

    local ok, results = pcall(C_LFGList.GetSearchResults)
    if not ok or not results then
        addon:Print("C_LFGList.GetSearchResults() failed or returned nothing: " .. tostring(results))
        return
    end

    -- On this client, GetSearchResults() returns a plain number rather than
    -- a table of result IDs - an older API shape (pre-7.1 Legion) where
    -- results are addressed by 1-based index/count rather than by a
    -- separate resultID. Handle both shapes: a table of IDs (modern), or a
    -- number meaning "this many results, indexed 1..N" (this client).
    local resultList
    if type(results) == "table" then
        addon:Print(string.format("GetSearchResults() returned a table of %d result ID(s).", #results))
        resultList = results
    elseif type(results) == "number" then
        addon:Print(string.format("GetSearchResults() returned a number: %d (treating as result count, indexed 1..%d).", results, results))
        resultList = {}
        for i = 1, results do resultList[i] = i end
    else
        addon:Print("GetSearchResults() returned an unexpected type: " .. type(results))
        return
    end

    local function DumpTable(label, t)
        local parts = {}
        for k, v in pairs(t) do
            table.insert(parts, tostring(k) .. "=" .. tostring(v))
        end
        addon:Print(string.format("  %s: {%s}", label, table.concat(parts, ", ")))
    end

    for i, resultID in ipairs(resultList) do
        if i > 3 then
            addon:Print("  ...(stopping after 3 results)")
            break
        end

        addon:Print(string.format("Result #%d, id=%s:", i, tostring(resultID)))

        local okInfo, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
        if okInfo and type(info) == "table" then
            DumpTable("GetSearchResultInfo", info)
        else
            addon:Print("  GetSearchResultInfo failed/nil: " .. tostring(info))
        end

        if C_LFGList.GetSearchResultMembers then
            local okMem, members = pcall(C_LFGList.GetSearchResultMembers, resultID)
            if okMem and type(members) == "table" then
                addon:Print(string.format("  GetSearchResultMembers: %d entries", #members))
                for j, m in ipairs(members) do
                    if type(m) == "table" then
                        DumpTable("    member[" .. j .. "]", m)
                    else
                        addon:Print(string.format("    member[%d]: %s", j, tostring(m)))
                    end
                end
            else
                addon:Print("  GetSearchResultMembers failed/nil: " .. tostring(members))
            end
        else
            addon:Print("  C_LFGList.GetSearchResultMembers does not exist.")
        end

        if C_LFGList.GetSearchResultLeaderInfo then
            local okLead, leaderInfo = pcall(C_LFGList.GetSearchResultLeaderInfo, resultID)
            if okLead and type(leaderInfo) == "table" then
                DumpTable("GetSearchResultLeaderInfo", leaderInfo)
            elseif okLead then
                addon:Print("  GetSearchResultLeaderInfo: " .. tostring(leaderInfo))
            else
                addon:Print("  GetSearchResultLeaderInfo failed: " .. tostring(leaderInfo))
            end
        end
    end
end

-- Second-pass exploration using the real function names from the full
-- C_LFGList key dump (/pr dump C_LFGList): GetSearchResultMembers, which
-- InspectAPI guessed at, doesn't actually exist on this client - the real
-- per-result getters are named differently (GetSearchResultPlayerInfo,
-- GetSearchResultMemberCounts, GetSearchResultFriends, etc.), and none of
-- those were tried before. Routes through the copyable text window
-- (Export module) instead of chat, since this produces far more output
-- than InspectAPI did.
function LFGAnnotate:InspectAPI2()
    if not C_LFGList then
        addon:Print("C_LFGList does not exist on this client.")
        return
    end

    local lines = {}
    local function log(fmt, ...)
        table.insert(lines, string.format(fmt, ...))
    end
    local function DumpValue(label, v)
        if type(v) == "table" then
            local parts = {}
            for k, val in pairs(v) do
                table.insert(parts, tostring(k) .. "=" .. tostring(val))
            end
            log("  %s: {%s}", label, table.concat(parts, ", "))
        else
            log("  %s: %s", label, tostring(v))
        end
    end

    -- GetSearchResults() previously returned a plain number instead of a
    -- table of IDs on this client - try GetFilteredSearchResults() first
    -- in case it behaves differently, falling back to the same
    -- number-as-count handling as InspectAPI if not.
    local resultList = {}
    local okFiltered, filtered = pcall(C_LFGList.GetFilteredSearchResults)
    if okFiltered and type(filtered) == "table" and #filtered > 0 then
        log("GetFilteredSearchResults() returned a table of %d result ID(s).", #filtered)
        resultList = filtered
    else
        log("GetFilteredSearchResults() didn't give usable IDs (ok=%s, type=%s) - falling back to GetSearchResults().",
            tostring(okFiltered), type(filtered))
        local ok, results = pcall(C_LFGList.GetSearchResults)
        if ok and type(results) == "table" then
            log("GetSearchResults() returned a table of %d result ID(s).", #results)
            resultList = results
        elseif ok and type(results) == "number" then
            log("GetSearchResults() returned a number: %d (treating as count, indexed 1..%d).", results, results)
            for i = 1, results do resultList[i] = i end
        else
            log("GetSearchResults() failed/unusable: %s", tostring(results))
        end
    end

    if #resultList == 0 then
        log("No result IDs to inspect - make sure a Group Finder search with results is open.")
    end

    for i, resultID in ipairs(resultList) do
        if i > 5 then
            log("...(stopping after 5 results)")
            break
        end
        log("")
        log("=== Result #%d, id=%s ===", i, tostring(resultID))

        local okHas, has = pcall(C_LFGList.HasSearchResultInfo, resultID)
        log("  HasSearchResultInfo: ok=%s value=%s", tostring(okHas), tostring(has))

        local okInfo, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
        if okInfo then DumpValue("GetSearchResultInfo", info)
        else log("  GetSearchResultInfo failed: %s", tostring(info)) end

        -- Signature unknown - try both resultID alone and resultID+index,
        -- since the applicant-side sibling (GetApplicantMemberInfo) takes
        -- an index as a second argument.
        local okPlayer, playerInfo = pcall(C_LFGList.GetSearchResultPlayerInfo, resultID)
        if okPlayer then DumpValue("GetSearchResultPlayerInfo(resultID)", playerInfo)
        else log("  GetSearchResultPlayerInfo(resultID) failed: %s", tostring(playerInfo)) end
        local okPlayer2, playerInfo2 = pcall(C_LFGList.GetSearchResultPlayerInfo, resultID, 1)
        if okPlayer2 then DumpValue("GetSearchResultPlayerInfo(resultID, 1)", playerInfo2)
        else log("  GetSearchResultPlayerInfo(resultID, 1) failed: %s", tostring(playerInfo2)) end

        local okCounts, counts = pcall(C_LFGList.GetSearchResultMemberCounts, resultID)
        if okCounts then DumpValue("GetSearchResultMemberCounts", counts)
        else log("  GetSearchResultMemberCounts failed: %s", tostring(counts)) end

        local okLeader, leaderInfo = pcall(C_LFGList.GetSearchResultLeaderInfo, resultID)
        if okLeader then DumpValue("GetSearchResultLeaderInfo", leaderInfo)
        else log("  GetSearchResultLeaderInfo failed: %s", tostring(leaderInfo)) end

        local okFriends, friends = pcall(C_LFGList.GetSearchResultFriends, resultID)
        if okFriends then DumpValue("GetSearchResultFriends", friends)
        else log("  GetSearchResultFriends failed: %s", tostring(friends)) end

        local okEnc, encInfo = pcall(C_LFGList.GetSearchResultEncounterInfo, resultID)
        if okEnc then DumpValue("GetSearchResultEncounterInfo", encInfo)
        else log("  GetSearchResultEncounterInfo failed: %s", tostring(encInfo)) end
    end

    addon:GetModule("Export"):ShowText("C_LFGList probe 2", table.concat(lines, "\n"))
end

function LFGAnnotate:OnEnable()
    local ok, err = pcall(function()
        self:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED", function() self:ScanBrowseResults() end)
    end)
    if not ok then addon:Print("|cffff4040LFG event hook failed|r: " .. tostring(err)) end

    -- Belt-and-suspenders: the event above catches a fresh search, but
    -- scrolling recycles rows into view without necessarily re-firing it,
    -- so a cheap periodic re-scan while the panel is open catches that too.
    ok, err = pcall(function()
        self.ticker = C_Timer.NewTicker(SCAN_INTERVAL, function() self:ScanBrowseResults() end)
    end)
    if not ok then addon:Print("|cffff4040LFG ticker failed|r: " .. tostring(err)) end
end
