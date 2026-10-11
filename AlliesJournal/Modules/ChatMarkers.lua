local addon = AlliesJournal
local ChatMarkers = addon:NewModule("ChatMarkers")

-- A small colored star in front of what someone with a note says in chat.
-- Hovering it shows your note (same lines as the world tooltip) and clicking
-- it opens that player in your journal. Display only: it changes how the line
-- is drawn, nothing else. Switchable in /aj options.

-- A plain one-picture star (the raid marker). The favorites icon used before is a
-- sheet of two pictures, so squeezed into one square it showed a star and a box.
local ICON = "Interface/TargetingFrame/UI-RaidTargetingIcon_1"
local SIZE = 16
local EVENTS = {
    "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
    "CHAT_MSG_WHISPER", "CHAT_MSG_CHANNEL",
}

local function Marker(nameRealm, review)
    local r, g, b = addon:GetWorstRatingRGB(review)
    return string.format("|Haddon:AlliesJournal:player:%s|h|T%s:%d:%d:0:0:1:1:0:1:0:1:%d:%d:%d|t|h ",
        nameRealm, ICON, SIZE, SIZE, math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- The line with the marker in front, or nil to leave it alone.
local function Annotate(msg, author)
    if type(msg) ~= "string" or type(author) ~= "string" then return nil end
    if issecretvalue and (issecretvalue(msg) or issecretvalue(author)) then return nil end
    local nameRealm = addon:NormalizeChatSender(author)
    if not nameRealm or nameRealm == addon:GetPlayerName() then return nil end
    local record = addon.db.global.players[nameRealm]
    if not record or #record.reviews == 0 then return nil end
    local review = addon:GetLatestReview(nameRealm)
    if not review then return nil end
    return Marker(nameRealm, review) .. msg
end

local function Filter(_, _, msg, author, ...)
    if not addon.db.global.settings.chatIcons then return false end
    local ok, marked = pcall(Annotate, msg, author)
    if ok and marked then return false, marked, author, ... end
    return false
end

local function OnHyperlinkEnter(frame, link)
    if type(link) ~= "string" then return end
    local kind, name, action, nameRealm = strsplit(":", link)
    if kind ~= "addon" or name ~= "AlliesJournal" or action ~= "player" or not nameRealm then return end
    local review = addon:GetLatestReview(nameRealm)
    if not review then return end
    GameTooltip:SetOwner(frame, "ANCHOR_CURSOR")
    local vars = addon:GetReviewTooltipVars(review, nameRealm)
    for _, line in ipairs(addon:RenderTooltipTemplate(addon.db.global.settings.tooltip.worldTemplate, vars)) do
        GameTooltip:AddLine(line, 1, 1, 1, true)
    end
    GameTooltip:AddLine("Click to open in your journal", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function OnHyperlinkLeave()
    GameTooltip:Hide()
end

-- Developer test (/aj chatstar): prints one sample line for every few players
-- with a note, drawn exactly like a real chat line, so the star, its color,
-- the hover tooltip and the click can be checked without anyone speaking.
function ChatMarkers:Preview()
    local shown = 0
    for nameRealm, record in pairs(addon.db.global.players) do
        if #record.reviews > 0 then
            local review = addon:GetLatestReview(nameRealm)
            if review then
                addon:Print(string.format("[%s]: %sthis is how %s's chat line looks", addon:GetShortName(nameRealm),
                    Marker(nameRealm, review), addon:GetShortName(nameRealm)))
                shown = shown + 1
                if shown >= 4 then return end
            end
        end
    end
    if shown == 0 then addon:Print("No player with a note yet to show a sample for.") end
end

function ChatMarkers:OnEnable()
    for _, event in ipairs(EVENTS) do
        pcall(ChatFrame_AddMessageEventFilter, event, Filter)
    end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame and frame.HookScript then
            pcall(frame.HookScript, frame, "OnHyperlinkEnter", OnHyperlinkEnter)
            pcall(frame.HookScript, frame, "OnHyperlinkLeave", OnHyperlinkLeave)
        end
    end
end
