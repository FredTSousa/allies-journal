local addon = AlliesJournal
local MinimapButton = addon:NewModule("MinimapButton")

-- The minimap button comes from LibDBIcon (the standard one most addons
-- use), so it also shows up in minimap-button collectors and Broker
-- displays. Its position and hidden flag live in settings.minimap
-- (`minimapPos` is its angle in degrees; `angle` is what an older
-- hand-made button saved and is carried over once).
local NAME = "AlliesJournal"
local ICON = "Interface\\AddOns\\AlliesJournal\\Media\\icon"

function MinimapButton:OnEnable()
    local LDB = LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub("LibDBIcon-1.0", true)
    if not (LDB and DBIcon) then return end

    local settings = addon.db.global.settings.minimap
    settings.minimapPos = settings.minimapPos or settings.angle or 215

    local launcher = LDB:NewDataObject(NAME, {
        type = "launcher",
        text = "Allies Journal",
        icon = ICON,
        OnClick = function(_, mouseButton)
            if mouseButton == "RightButton" then
                addon:GetModule("Options"):Show()
            elseif addon:GetModule("ReviewPrompt"):HasWaiting() and not IsShiftKeyDown() then
                -- Notes put off with "Later" come first; Shift opens the journal.
                addon:GetModule("ReviewPrompt"):GroupReopen()
            else
                addon:GetModule("Browser"):Toggle()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Allies Journal")
            if addon:GetModule("ReviewPrompt"):HasWaiting() then
                local waiting = addon:GetModule("ReviewPrompt"):PendingCount()
                tooltip:AddLine(string.format("You have %d note%s to write", waiting, waiting == 1 and "" or "s"), 0.4, 1, 0.4)
                tooltip:AddLine("Left-click: write them", 1, 1, 1)
                tooltip:AddLine("Shift-left-click: open your journal", 1, 1, 1)
            else
                tooltip:AddLine("Left-click: open notes", 1, 1, 1)
            end
            tooltip:AddLine("Right-click: options", 1, 1, 1)
            tooltip:AddLine("Drag: move this button", 0.6, 0.6, 0.6)
        end,
    })

    DBIcon:Register(NAME, launcher, settings)
    self.DBIcon = DBIcon
    self:Refresh()
end

-- Applies the current settings (position + shown/hidden) - called on
-- load and whenever the options checkbox, /pr minimap or a settings reset
-- changes them.
function MinimapButton:Refresh()
    local DBIcon = self.DBIcon
    if not DBIcon then return end
    local settings = addon.db.global.settings.minimap
    DBIcon:Refresh(NAME, settings)
    if settings.hide then
        DBIcon:Hide(NAME)
    else
        DBIcon:Show(NAME)
    end
end

-- Tints (and softly flashes) the button while notes are waiting.
function MinimapButton:SetAttention(on)
    local DBIcon = self.DBIcon
    if not DBIcon then return end
    local button = DBIcon:GetMinimapButton(NAME)
    if not button then return end
    if button.icon then
        if on then button.icon:SetVertexColor(0.4, 1, 0.4) else button.icon:SetVertexColor(1, 1, 1) end
    end
    pcall(function()
        if on then
            UIFrameFlash(button, 0.6, 0.6, -1, false, 0.4, 0.4)
        else
            UIFrameFlashStop(button)
            button:SetAlpha(1)
        end
    end)
end
