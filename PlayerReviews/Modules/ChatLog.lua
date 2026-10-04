local addon = PlayerReview
local ChatLog = addon:NewModule("ChatLog", "AceEvent-3.0")

local MAX_MESSAGES_PER_PLAYER = 15

-- guid -> { {time=, channel=, text=, from="self"|"them"}, ... }, in memory
-- only, same as RosterTracker's groupedSince - this is the LIVE rolling
-- buffer, still scratch context for the review prompt; RosterTracker's
-- session-eligibility check takes its own frozen copy of whatever's here
-- at that moment before this buffer keeps changing or gets cleared.
ChatLog.messages = {}

local CHANNEL_LABELS = {
    CHAT_MSG_PARTY = "Party",
    CHAT_MSG_PARTY_LEADER = "Party",
    CHAT_MSG_RAID = "Raid",
    CHAT_MSG_RAID_LEADER = "Raid",
    CHAT_MSG_SAY = "Say",
    CHAT_MSG_WHISPER = "Whisper",
    CHAT_MSG_WHISPER_INFORM = "Whisper",
}

-- Broadcast channels have no single recipient - a self-sent PARTY/RAID/SAY
-- line is directed at the whole group, so it gets filed under EVERY
-- currently-grouped player's log rather than one specific guid. Whispers
-- are inherently 1:1 (sender for WHISPER, target for WHISPER_INFORM), so
-- they're excluded here and handled directly by guid in OnChatMessage.
local BROADCAST_EVENTS = {
    CHAT_MSG_PARTY = true,
    CHAT_MSG_PARTY_LEADER = true,
    CHAT_MSG_RAID = true,
    CHAT_MSG_RAID_LEADER = true,
    CHAT_MSG_SAY = true,
}

function ChatLog:OnEnable()
    for event in pairs(CHANNEL_LABELS) do
        self:RegisterEvent(event, "OnChatMessage")
    end
end

function ChatLog:AppendMessage(guid, channel, text, from)
    local log = self.messages[guid]
    if not log then
        log = {}
        self.messages[guid] = log
    end

    table.insert(log, { time = time(), channel = channel, text = text, from = from })
    while #log > MAX_MESSAGES_PER_PLAYER do
        table.remove(log, 1)
    end
end

-- Standard CHAT_MSG_* signature: (event, text, playerName, ...). Only
-- messages from the addon user OR someone currently in our tracked roster
-- are kept - this is "mine and his" reference context for a specific
-- grouped player's review, not a general chat logger picking up everyone
-- else's chatter too.
function ChatLog:OnChatMessage(event, text, playerName)
    -- Chat payloads can be secret values where the client restricts them;
    -- those can't be inspected or stored, so skip the line.
    if issecretvalue and (issecretvalue(text) or issecretvalue(playerName)) then return end
    local nameRealm = addon:NormalizeChatSender(playerName)
    if not nameRealm then return end

    local channel = CHANNEL_LABELS[event] or "?"
    local roster = addon:GetModule("RosterTracker")

    if event == "CHAT_MSG_WHISPER_INFORM" then
        -- playerName is the outgoing whisper's TARGET, not you - an
        -- inherently 1:1 message FROM you TO that specific player.
        local guid = roster:GetGUIDForName(nameRealm)
        if guid then
            self:AppendMessage(guid, channel, text, "self")
        end
        return
    end

    if nameRealm == addon:GetPlayerName() then
        if BROADCAST_EVENTS[event] then
            -- A party/raid/say line from you has no single recipient -
            -- it's addressed to the whole group, so it goes on every
            -- currently-grouped player's log rather than one guid.
            for guid in pairs(roster.roster) do
                self:AppendMessage(guid, channel, text, "self")
            end
        end
        return
    end

    -- Everything else (party/raid/say from someone else, or an incoming
    -- CHAT_MSG_WHISPER) is FROM that resolved player, filed under their
    -- own guid only - never merged into every roster member's log, so
    -- third-party chatter stays excluded.
    local guid = roster:GetGUIDForName(nameRealm)
    if guid then
        self:AppendMessage(guid, channel, text, "them")
    end
end

function ChatLog:GetMessages(guid)
    if not guid then return {} end
    return self.messages[guid] or {}
end

function ChatLog:Clear(guid)
    if guid then
        self.messages[guid] = nil
    end
end
