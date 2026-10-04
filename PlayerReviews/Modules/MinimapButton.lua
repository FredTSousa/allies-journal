local addon = PlayerReview
local MinimapButton = addon:NewModule("MinimapButton")

-- The minimap button comes from LibDBIcon (the standard one most addons
-- use), so it also shows up in minimap-button collectors and Broker
-- displays. Its position and hidden flag live in settings.minimap
-- (`minimapPos` is its angle in degrees; `angle` is what an older
-- hand-made button saved and is carried over once).
local NAME = "PlayerReviews"
local ICON = "Interface\\COMMON\\FavoritesIcon"

function MinimapButton:OnEnable()
    local LDB = LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub("LibDBIcon-1.0", true)
    if not (LDB and DBIcon) then return end

    local settings = addon.db.global.settings.minimap
    settings.minimapPos = settings.minimapPos or settings.angle or 215

    local launcher = LDB:NewDataObject(NAME, {
        type = "launcher",
        text = "Player Reviews",
        icon = ICON,
        OnClick = function(_, mouseButton)
            if mouseButton == "RightButton" then
                addon:GetModule("Options"):Show()
            else
                addon:GetModule("Browser"):Toggle()
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("Player Reviews")
            tooltip:AddLine("Left-click: open reviews", 1, 1, 1)
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
