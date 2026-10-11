local addon = AlliesJournal
local Trades = addon:NewModule("Trades", "AceEvent-3.0")

-- Counts completed trades with people already in the journal: how many and
-- the last date. No items or amounts are kept.

function Trades:OnEnable()
    pcall(self.RegisterEvent, self, "TRADE_SHOW", "OnTradeShow")
    pcall(self.RegisterEvent, self, "TRADE_CLOSED", "OnTradeClosed")
    pcall(self.RegisterEvent, self, "UI_INFO_MESSAGE", "OnInfoMessage")
end

function Trades:OnTradeShow()
    local ok, name = pcall(function() return addon:GetFullName("NPC") end)
    self.partner = ok and name or nil
end

-- The "Trade complete." message can arrive just after the window closes.
function Trades:OnTradeClosed()
    C_Timer.After(1, function() self.partner = nil end)
end

function Trades:OnInfoMessage(_, _, message)
    if not self.partner then return end
    local ok, complete = pcall(function() return ERR_TRADE_COMPLETE and message == ERR_TRADE_COMPLETE end)
    if not (ok and complete) then return end
    local record = addon.db.global.players[self.partner]
    if record then
        local trades = record.trades or {}
        record.trades = trades
        trades.count = (trades.count or 0) + 1
        trades.last = time()
    end
    self.partner = nil
end
