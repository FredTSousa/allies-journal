local addon = AlliesJournal
local AceGUI = LibStub("AceGUI-3.0")

-- The addon's window: Blizzard's own PortraitFrameTemplate (the frame the
-- Professions and Collections windows use - dark panel, metal border, round
-- portrait with the journal icon, red close button) wrapped as an AceGUI
-- container with the same API as AceGUI's stock "Window". Callers use
-- addon:CreateWindow(), which falls back to the stock Window if the template
-- isn't there.

local PLAYER_ICON = "Interface\\AddOns\\AlliesJournal\\Media\\icon"

-- Space between the frame edge and the content area. TOP leaves room for the
-- title bar and the portrait ring that hangs into the corner.
local TOP, BOTTOM, SIDE = 58, 13, 17

local templateOk = pcall(function()
    local probe = CreateFrame("Frame", nil, UIParent, "PortraitFrameTemplate")
    probe:Hide()
    assert(probe.CloseButton)
end)

-- How much taller than the stock Window's content area (which is 32 from the
-- top and 13 from the bottom) this one's chrome makes the window: layouts that
-- subtract a fixed amount from the window height add this as well.
addon.windowExtra = templateOk and (TOP + BOTTOM - 45) or 0

function addon:CreateWindow()
    return AceGUI:Create(templateOk and "AJWindow" or "Window")
end

if not templateOk then return end

do
    local Type, Version = "AJWindow", 1

    local function frameOnShow(this) this.obj:Fire("OnShow") end
    local function frameOnClose(this) this.obj:Fire("OnClose") end

    local function closeOnClick(this)
        PlaySound(799) -- SOUNDKIT.GS_TITLE_OPTION_EXIT
        this.obj:Hide()
    end

    local function SaveStatus(frame)
        local self = frame.obj
        local status = self.status or self.localstatus
        status.width = frame:GetWidth()
        status.height = frame:GetHeight()
        status.top = frame:GetTop()
        status.left = frame:GetLeft()
    end

    local function titleOnMouseDown(this)
        this:GetParent():StartMoving()
        AceGUI:ClearFocus()
    end

    local function titleOnMouseUp(this)
        local frame = this:GetParent()
        frame:StopMovingOrSizing()
        SaveStatus(frame)
    end

    local function sizerOnMouseUp(this)
        local frame = this:GetParent()
        frame:StopMovingOrSizing()
        SaveStatus(frame)
    end

    local methods = {
        SetTitle = function(self, title)
            if self.frame.SetTitle then
                self.frame:SetTitle(title or "")
            elseif self.frame.TitleContainer and self.frame.TitleContainer.TitleText then
                self.frame.TitleContainer.TitleText:SetText(title or "")
            end
        end,

        SetStatusText = function() end,

        Hide = function(self) self.frame:Hide() end,
        Show = function(self) self.frame:Show() end,

        OnAcquire = function(self)
            self.frame:SetParent(UIParent)
            self.frame:SetFrameStrata("DIALOG")
            self:ApplyStatus()
            self:EnableResize(true)
            self:Show()
        end,

        OnRelease = function(self)
            self.status = nil
            for k in pairs(self.localstatus) do self.localstatus[k] = nil end
        end,

        -- called to set an external table to store status in
        SetStatusTable = function(self, status)
            assert(type(status) == "table")
            self.status = status
            self:ApplyStatus()
        end,

        ApplyStatus = function(self)
            local status = self.status or self.localstatus
            local frame = self.frame
            self:SetWidth(status.width or 700)
            self:SetHeight(status.height or 500)
            if status.top and status.left then
                frame:ClearAllPoints()
                frame:SetPoint("TOP", UIParent, "BOTTOM", 0, status.top)
                frame:SetPoint("LEFT", UIParent, "LEFT", status.left, 0)
            else
                frame:ClearAllPoints()
                frame:SetPoint("CENTER", UIParent, "CENTER")
            end
        end,

        -- What the layouts see is a little smaller than the real content
        -- area on purpose: the form heights used by the callers were tuned
        -- against that.
        OnWidthSet = function(self, width)
            local contentWidth = math.max(0, width - SIDE * 2)
            self.content:SetWidth(contentWidth)
            self.content.width = contentWidth
        end,

        OnHeightSet = function(self, height)
            local contentHeight = math.max(0, height - TOP - BOTTOM - 12)
            self.content:SetHeight(contentHeight)
            self.content.height = contentHeight
        end,

        EnableResize = function(self, state)
            local func = state and "Show" or "Hide"
            self.sizer_se[func](self.sizer_se)
            self.sizer_s[func](self.sizer_s)
            self.sizer_e[func](self.sizer_e)
        end,
    }

    local function Constructor()
        local frame = CreateFrame("Frame", nil, UIParent, "PortraitFrameTemplate")
        local self = { type = Type, localstatus = {} }
        for name, func in pairs(methods) do self[name] = func end

        self.frame = frame
        frame.obj = self
        frame:SetWidth(700)
        frame:SetHeight(500)
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        frame:EnableMouse(true)
        frame:SetMovable(true)
        frame:SetResizable(true)
        frame:SetClampedToScreen(true)
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)
        frame:SetScript("OnMouseDown", function() AceGUI:ClearFocus() end)
        frame:SetScript("OnShow", frameOnShow)
        frame:SetScript("OnHide", frameOnClose)
        if frame.SetResizeBounds then
            frame:SetResizeBounds(240, 240)
        else
            frame:SetMinResize(240, 240)
        end

        -- The journal icon in the portrait ring. Which setter exists depends
        -- on the client, so try each.
        if not pcall(frame.SetPortraitTextureRaw, frame, PLAYER_ICON) then
            pcall(frame.SetPortraitToAsset, frame, PLAYER_ICON)
        end

        local close = frame.CloseButton
        close.obj = self
        close:SetScript("OnClick", closeOnClick)
        self.closebutton = close

        -- The title bar drags the window.
        local title = CreateFrame("Button", nil, frame)
        title:SetPoint("TOPLEFT", frame, "TOPLEFT", 64, -2)
        title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -2)
        title:SetHeight(24)
        title:EnableMouse(true)
        title:SetScript("OnMouseDown", titleOnMouseDown)
        title:SetScript("OnMouseUp", titleOnMouseUp)
        self.title = title

        -- Resize: corner and the two edges, with Blizzard's chat grabber on the corner.
        local sizer_se = CreateFrame("Frame", nil, frame)
        sizer_se:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -3, 3)
        sizer_se:SetSize(22, 22)
        sizer_se:EnableMouse(true)
        sizer_se:SetScript("OnMouseDown", function(this) frame:StartSizing("BOTTOMRIGHT"); AceGUI:ClearFocus() end)
        sizer_se:SetScript("OnMouseUp", sizerOnMouseUp)
        local grip = sizer_se:CreateTexture(nil, "OVERLAY")
        grip:SetAllPoints(sizer_se)
        grip:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
        self.sizer_se = sizer_se

        local sizer_s = CreateFrame("Frame", nil, frame)
        sizer_s:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -25, 0)
        sizer_s:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 8, 0)
        sizer_s:SetHeight(8)
        sizer_s:EnableMouse(true)
        sizer_s:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOM"); AceGUI:ClearFocus() end)
        sizer_s:SetScript("OnMouseUp", sizerOnMouseUp)
        self.sizer_s = sizer_s

        local sizer_e = CreateFrame("Frame", nil, frame)
        sizer_e:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 25)
        sizer_e:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -30)
        sizer_e:SetWidth(8)
        sizer_e:EnableMouse(true)
        sizer_e:SetScript("OnMouseDown", function() frame:StartSizing("RIGHT"); AceGUI:ClearFocus() end)
        sizer_e:SetScript("OnMouseUp", sizerOnMouseUp)
        self.sizer_e = sizer_e

        -- Container support
        local content = CreateFrame("Frame", nil, frame)
        self.content = content
        content.obj = self
        content:SetPoint("TOPLEFT", frame, "TOPLEFT", SIDE, -TOP)
        content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -SIDE, BOTTOM)

        AceGUI:RegisterAsContainer(self)
        return self
    end

    AceGUI:RegisterWidgetType(Type, Constructor, Version)
end
