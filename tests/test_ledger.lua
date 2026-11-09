-- Ledger: confirmed trade recording and contract §6 stake/payout matching.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 5 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = {}, bookies = {
  ["Tester-Normal"] = { level = 5, positiveRatings = 20 },
  ["Host-Normal"] = { level = 5, positiveRatings = 20 },
} } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, R, L = ns.A, ns.Ring, ns.Ledger
A.db.config.referee.available = true
A.db.config.ring.currency = "gold"
T.money = 10000000

local function party(...)
  local names = { ... }
  T.group = { size = #names + 1, raid = false }
  for i = 1, 4 do T.units["party" .. i] = names[i] and { name = names[i], isPlayer = true } or nil end
end

local function host()
  if R.session then
    if R.IsHost() then R.Close(true) else R.Leave() end
  end
  R.last = nil
  ns.char.ring.last = nil
  ns.char.ring.debts = {}
  ns.char.ring.unmatched = {}
  ns.char.trades = {}
  party("Alice", "Bob")
  local s = R.Open("ratchet")
  T.ok(type(s) == "table", "host session")
  R.SetFighters("Fa", "Fb")
  return s
end

local function addMarket(s)
  local m = R.AddMarket({ kind = "winner", mode = "pari", open = true })
  T.ok(type(m) == "table", "additional market")
  return m
end

local function bet(s, sender, mid, outcome, amount)
  T.Deliver("BSPT", table.concat({ "R2B", s.id, mid, outcome, amount, 0, "abcd" }, "\t"), "WHISPER", sender)
  T.Advance(2.1)
  return R.Market(mid, s).bets[#R.Market(mid, s).bets]
end

local function trade(partner, got, gave, moneyDelta, loot, lootAfter)
  T.units.npc = { name = partner, isPlayer = true }
  T.Fire("TRADE_SHOW")
  T.trade.target, T.trade.player = got, gave
  T.Fire("TRADE_MONEY_CHANGED")
  T.Fire("TRADE_ACCEPT_UPDATE", 1, 1)
  local delta = moneyDelta == nil and (got - gave) or moneyDelta
  if loot and not lootAfter then T.Fire("CHAT_MSG_MONEY", "You loot " .. loot .. " Copper") end
  T.Fire("TRADE_CLOSED")
  if delta ~= 0 then T.SetMoney(T.money + delta) end
  if loot and lootAfter then T.Fire("CHAT_MSG_MONEY", "You loot " .. loot .. " Copper") end
  T.trade.target, T.trade.player = 0, 0
  T.Advance(1.1)
  return ns.char.trades[#ns.char.trades]
end

T.test("Ledger records a confirmed exact stake through the real trade events", function()
  local s = host()
  local b = bet(s, "Alice-Normal", "m1", 1, 10000)
  T.eq(b.paid, false)
  local row = trade("Alice", 10000, 0)
  T.ok(row, "trade row recorded")
  if not row then return end
  T.eq(row.confirmed, true)
  T.eq(row.partner, "Alice-Normal")
  T.eq(row.kind, "stake")
  T.eq(row.sid, s.id)
  T.eq(#row.matched, 1)
  T.eq(b.paid, true)
  T.eq(#ns.char.ring.unmatched, 0)
end)

T.test("Ledger matches one incoming trade to the sum of two unpaid bets", function()
  local s = host()
  addMarket(s)
  local first = bet(s, "Alice-Normal", "m1", 1, 10000)
  local second = bet(s, "Alice-Normal", "m2", 2, 20000)
  local row = trade("Alice", 30000, 0)
  T.eq(first.paid, true)
  T.eq(second.paid, true)
  T.eq(#row.matched, 2)
  T.eq(row.reason, nil)
end)

T.test("Ledger books partial payouts oldest-first and clears the remainder", function()
  local s = host()
  local winner = bet(s, "Alice-Normal", "m1", 1, 10000)
  bet(s, "Bob-Normal", "m1", 2, 20000)
  trade("Alice", 10000, 0)
  trade("Bob", 20000, 0)
  T.ok(R.Verdict("m1", 1))
  T.Advance(601)
  T.eq(R.Market("m1", s).status, "settled")
  T.eq(winner.payout, 30000)
  local partial = trade("Alice", 0, 12000)
  T.eq(partial.kind, "payout")
  T.eq(winner.paidOutAmount, 12000)
  T.eq(winner.paidOut, false)
  T.eq(R.Debts()[1].paid, 12000)
  trade("Alice", 0, 18000)
  T.eq(winner.paidOutAmount, 30000)
  T.eq(winner.paidOut, true)
  T.eq(R.Debts()[1].status, "cleared")
end)

T.test("Ledger keeps amount/both unmatched and never matches an unconfirmed delta", function()
  local s = host()
  local b = bet(s, "Alice-Normal", "m1", 1, 10000)
  local wrong = trade("Alice", 9000, 0)
  T.eq(wrong.reason, "amount")
  T.eq(b.paid, false)
  T.eq(#ns.char.ring.unmatched, 1)
  T.eq(ns.char.ring.unmatched[1].reason, "amount")
  local unconfirmed = trade("Alice", 10000, 0, 0)
  T.eq(unconfirmed.confirmed, false)
  T.eq(b.paid, false)
  T.eq(#ns.char.ring.unmatched, 1)
  local both = trade("Alice", 10000, 10000)
  T.eq(both.reason, "both")
  T.eq(#ns.char.ring.unmatched, 2)
end)

T.test("Ledger late-matches a pre-bet trade inside 120 seconds", function()
  local s = host()
  local row = trade("Alice", 10000, 0)
  T.eq(row.reason, "nobet")
  T.eq(#ns.char.ring.unmatched, 1)
  local b = bet(s, "Alice-Normal", "m1", 1, 10000)
  T.eq(b.paid, true)
  T.eq(#ns.char.ring.unmatched, 0)
end)

T.test("Ledger refuses a pre-bet trade at 121 seconds with reason late", function()
  local s = host()
  trade("Bob", 10000, 0)
  T.Advance(121)
  local b = bet(s, "Bob-Normal", "m1", 1, 10000)
  T.eq(b.paid, false)
  T.eq(#ns.char.ring.unmatched, 1)
  T.eq(ns.char.ring.unmatched[1].reason, "late")
end)

T.test("Ledger manual Assign marks the bet and removes the unmatched row", function()
  local s = host()
  local b = bet(s, "Alice-Normal", "m1", 1, 10000)
  trade("Alice", 9000, 0)
  T.eq(type(L.Assign), "function")
  if type(L.Assign) ~= "function" then return end
  T.ok(L.Assign(1, s.id, "m1", "Alice-Normal"))
  T.eq(b.paid, true)
  T.eq(b.manual, true)
  T.eq(#ns.char.ring.unmatched, 0)
end)

T.test("Ledger subtracts loot inside the trade window before or after PLAYER_MONEY", function()
  local s = host()
  local first = bet(s, "Alice-Normal", "m1", 1, 10000)
  local second = bet(s, "Bob-Normal", "m1", 2, 20000)
  local before = trade("Alice", 10000, 0, 10025, 25, false)
  T.eq(before.confirmed, true)
  T.eq(first.paid, true)
  local after = trade("Bob", 20000, 0, 20025, 25, true)
  T.eq(after.confirmed, true)
  T.eq(second.paid, true)
end)

T.test("Ledger matches a payout to the sum across two settled markets", function()
  local s = host()
  addMarket(s)
  local first = bet(s, "Alice-Normal", "m1", 1, 10000)
  local second = bet(s, "Alice-Normal", "m2", 1, 20000)
  bet(s, "Bob-Normal", "m1", 2, 20000)
  bet(s, "Bob-Normal", "m2", 2, 30000)
  trade("Alice", 10000, 0)
  trade("Alice", 20000, 0)
  trade("Bob", 20000, 0)
  trade("Bob", 30000, 0)
  R.Verdict("m1", 1)
  R.Verdict("m2", 1)
  T.Advance(601)
  T.eq(first.payout, 30000)
  T.eq(second.payout, 50000)
  local row = trade("Alice", 0, 80000)
  T.eq(#row.matched, 2)
  T.eq(row.reason, nil)
  T.eq(first.paidOut, true)
  T.eq(second.paidOut, true)
end)

T.test("Ledger covers all payouts and keeps only the excess unmatched", function()
  local s = host()
  local winner = bet(s, "Alice-Normal", "m1", 1, 10000)
  bet(s, "Bob-Normal", "m1", 2, 20000)
  trade("Alice", 10000, 0)
  trade("Bob", 20000, 0)
  R.Verdict("m1", 1)
  T.Advance(601)
  local row = trade("Alice", 0, 30001)
  T.eq(winner.paidOut, true)
  T.eq(row.reason, "excess")
  T.eq(row.excess, 1)
  T.eq(#ns.char.ring.unmatched, 1)
  T.eq(ns.char.ring.unmatched[1].excess, 1)
end)

T.test("Ledger books a bettor payout receipt through a v2 mirror", function()
  if R.session then R.Close(true) end
  R.last = nil
  ns.char.ring.last, ns.char.ring.session = nil, nil
  ns.char.ring.debts, ns.char.ring.unmatched = {}, {}
  ns.char.trades = {}
  party("Host")
  local sid = "abc999"
  T.Deliver("BSPT", table.concat({ "R2S", 2, sid, "open", "ratchet", "gold", 500000, "", 1, 1, 1, "100" }, "\t"), "PARTY", "Host-Normal")
  local function market(status, rev)
    T.Deliver("BSPT", table.concat({ "R2M", sid, "m1", "winner", "fight", "pari", status, 2, 1, 1, 0, 0, 0, rev, "Winner" }, "\t"), "PARTY", "Host-Normal")
  end
  market("resolving", 1)
  T.Deliver("BSPT", table.concat({ "R2O", sid, "m1", 1, "Fa", 10000, 1, 0 }, "\t"), "PARTY", "Host-Normal")
  T.Deliver("BSPT", table.concat({ "R2O", sid, "m1", 2, "Fb", 20000, 1, 0 }, "\t"), "PARTY", "Host-Normal")
  T.Deliver("BSPT", table.concat({ "R2L", sid, "m1", "Tester-Normal", 1, 10000, 0, "100", 30000, 0, 1 }, "\t"), "PARTY", "Host-Normal")
  market("settled", 2)
  T.Deliver("BSPT", table.concat({ "R2S", 2, sid, "settled", "ratchet", "gold", 500000, "", 1, 1, 2, "100" }, "\t"), "PARTY", "Host-Normal")
  local row = trade("Host", 30000, 0)
  local b = R.MyBet("m1")
  T.eq(row.kind, "payout")
  T.eq(b.receivedAmount, 30000)
  T.eq(b.received, true)
  T.eq(A.db.outbox.rows[#A.db.outbox.rows].data.ev, "received")
  T.eq(A.db.outbox.rows[#A.db.outbox.rows].data.amount, 30000)
end)

T.noErrors()
T.done()
