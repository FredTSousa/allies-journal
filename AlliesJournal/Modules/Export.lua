local addon = PlayerReview
local Export = addon:NewModule("Export")
local AceGUI = LibStub("AceGUI-3.0")

function Export:ShowExport()
    local text = addon:ExportData()

    if not self.exportFrame then
        local frame = AceGUI:Create("Window")
        frame.frame:SetFrameStrata("DIALOG") -- AceGUI defaults to FULLSCREEN_DIALOG, which sits above the game's confirmation popups
        frame:SetTitle("Allies Journal - Export")
        frame:SetLayout("Flow")
        frame:SetWidth(520)
        frame:SetHeight(440)
        frame:SetCallback("OnClose", function(widget) widget:Hide() end)
        self.exportFrame = frame

        local box = AceGUI:Create("MultiLineEditBox")
        box:SetLabel("Ctrl+A, Ctrl+C to copy - save this somewhere safe. Restore it later with /aj import.")
        box:SetFullWidth(true)
        box:SetNumLines(20)
        frame:AddChild(box)
        self.exportBox = box
    end

    self.exportBox:SetText(text)
    self.exportFrame:Show()

    -- Select-all + focus so a single Ctrl+C right after opening grabs
    -- everything - editBox is the MultiLineEditBox widget's underlying
    -- real Blizzard EditBox, not part of AceGUI's documented API, so
    -- pcall guards against it changing.
    pcall(function()
        self.exportBox.editBox:HighlightText()
        self.exportBox.editBox:SetFocus()
    end)
end

function Export:ShowImport()
    if not self.importFrame then
        local frame = AceGUI:Create("Window")
        frame.frame:SetFrameStrata("DIALOG") -- AceGUI defaults to FULLSCREEN_DIALOG, which sits above the game's confirmation popups
        frame:SetTitle("Allies Journal - Import")
        frame:SetLayout("Flow")
        frame:SetWidth(520)
        frame:SetHeight(460)
        frame:SetCallback("OnClose", function(widget) widget:Hide() end)
        self.importFrame = frame

        local box = AceGUI:Create("MultiLineEditBox")
        box:SetLabel("Paste a previous /aj export here, then click Import. Existing data is kept - only new notes are added.")
        box:SetFullWidth(true)
        box:SetNumLines(16)
        frame:AddChild(box)
        self.importBox = box

        local importBtn = AceGUI:Create("Button")
        importBtn:SetText("Import")
        importBtn:SetWidth(150)
        importBtn:SetCallback("OnClick", function()
            local text = self.importBox:GetText()
            local ok, a, b, settingsRestored, sessionsMerged = addon:ImportData(text)
            if ok then
                addon:Print(string.format("Import complete: %d player(s) merged, %d new notes, %d new session(s) added%s.",
                    a, b, sessionsMerged or 0, settingsRestored and ", settings restored" or ""))
                addon:GetModule("Browser"):RefreshIfShown()
                pcall(function() addon:GetModule("Options"):Refresh() end)
                self.importFrame:Hide()
            else
                addon:Print("|cffff4040Import failed|r: " .. tostring(a))
            end
        end)
        frame:AddChild(importBtn)
    end

    self.importBox:SetText("")
    self.importFrame:Show()
end

-- Paste-and-load counterpart to ReviewCapture:SaveFightsForReplay - lets
-- a previously-saved real fight-data blob be reloaded into a review
-- prompt for repeated UI testing, without needing to regroup with
-- anyone to generate fresh test data each time.
function Export:ShowCaptureReplay()
    if not self.replayFrame then
        local frame = AceGUI:Create("Window")
        frame.frame:SetFrameStrata("DIALOG") -- AceGUI defaults to FULLSCREEN_DIALOG, which sits above the game's confirmation popups
        frame:SetTitle("Allies Journal - Replay Captured Fights")
        frame:SetLayout("Flow")
        frame:SetWidth(520)
        frame:SetHeight(460)
        frame:SetCallback("OnClose", function(widget) widget:Hide() end)
        self.replayFrame = frame

        local box = AceGUI:Create("MultiLineEditBox")
        box:SetLabel("Paste a previous /aj capturesave output here, then click Load. Opens a note window using that exact fight data.")
        box:SetFullWidth(true)
        box:SetNumLines(16)
        frame:AddChild(box)
        self.replayBox = box

        local loadBtn = AceGUI:Create("Button")
        loadBtn:SetText("Load")
        loadBtn:SetWidth(150)
        loadBtn:SetCallback("OnClick", function()
            addon:ReplayCapturedFights(self.replayBox:GetText())
            self.replayFrame:Hide()
        end)
        frame:AddChild(loadBtn)
    end

    self.replayBox:SetText("")
    self.replayFrame:Show()
end

-- Generic copyable-text viewer, reused by /pr dump for ad-hoc API
-- exploration (e.g. dumping all of C_LFGList's keys) - same
-- select-all-and-copy pattern as ShowExport, just with caller-supplied
-- title/text instead of the review database.
function Export:ShowText(title, text)
    if not self.textFrame then
        local frame = AceGUI:Create("Window")
        frame.frame:SetFrameStrata("DIALOG") -- AceGUI defaults to FULLSCREEN_DIALOG, which sits above the game's confirmation popups
        frame:SetLayout("Flow")
        frame:SetWidth(520)
        frame:SetHeight(460)
        frame:SetCallback("OnClose", function(widget) widget:Hide() end)
        self.textFrame = frame

        local box = AceGUI:Create("MultiLineEditBox")
        box:SetLabel("Ctrl+A, Ctrl+C to copy.")
        box:SetFullWidth(true)
        box:SetNumLines(22)
        frame:AddChild(box)
        self.textBox = box
    end

    self.textFrame:SetTitle(title or "Allies Journal")
    self.textBox:SetText(text)
    self.textFrame:Show()

    pcall(function()
        self.textBox.editBox:HighlightText()
        self.textBox.editBox:SetFocus()
    end)
end
