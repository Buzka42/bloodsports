-- Hostile QA, Ledger: gold from people who are not bettors, unmatched-list expiry (120 s late window, 50-row FIFO),
-- the same trade booked twice, partial / repeated / over payouts, payouts after the session left `last`.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 0 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 50 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, R, L = ns.A, ns.Ring, ns.Ledger
A.db.config.referee.available = true
A.db.config.ring.currency = "gold"
T.money = 100000000

local function party(...)
  local names = { ... }
  T.group = { size = #names + 1, raid = false }
  for i = 1, 4 do T.units["party" .. i] = names[i] and { name = names[i], isPlayer = true } or nil end
end

local base = 0
local function host(names)
  base = #A.db.outbox.rows
  if R.session then if R.IsHost() then R.Close(true) else R.Leave() end end
  T.Advance(60)
  R.last, ns.char.ring.last = nil, nil
  ns.char.ring.debts, ns.char.ring.unmatched, ns.char.trades = {}, {}, {}
  party(unpack(names or { "Ann", "Bob", "Cid", "Dee" }))
  local s = R.Open("ratchet")
  T.ok(type(s) == "table", "host session")
  T.ok(R.SetFighters("Fa", "Fb"))
  return s
end

local nonce = 0
local function r2b(sender, mid, idx, amount)
  nonce = nonce + 1
  T.Deliver("BSPT", table.concat({ "R2B", R.session.id, mid, idx, amount, 0, string.format("%04x", nonce) }, "\t"), "WHISPER", sender)
  T.Advance(2.1)
  for _, b in ipairs(R.Market(mid).bets) do if b.bettor == sender then return b end end
end

-- A trade through the real event sequence; unit = { name, realm } of the partner. `closedTwice` fires TRADE_CLOSED again.
local function trade(partner, got, gave, closedTwice, realm)
  T.units.npc = { name = partner, realm = realm, isPlayer = true }
  T.Fire("TRADE_SHOW")
  T.trade.target, T.trade.player = got, gave
  T.Fire("TRADE_MONEY_CHANGED")
  T.Fire("TRADE_ACCEPT_UPDATE", 1, 1)
  T.Fire("TRADE_CLOSED")
  if closedTwice then T.Fire("TRADE_CLOSED") end
  T.SetMoney(T.money + got - gave)
  T.trade.target, T.trade.player = 0, 0
  T.Advance(1.1)
  return ns.char.trades[#ns.char.trades]
end

local function rowsOf(kind, ev)
  local out = {}
  for i = base + 1, #A.db.outbox.rows do
    local r = A.db.outbox.rows[i]
    if r.kind == kind and (not ev or r.data.ev == ev) then out[#out + 1] = r.data end
  end
  return out
end

-- Settled m1: Ann 100000 on Fa (wins), Bob 200000 on Fb. Ann is owed 300000.
local function settledRing()
  local s = host()
  local a, b = r2b("Ann-Normal", "m1", 1, 100000), r2b("Bob-Normal", "m1", 2, 200000)
  trade("Ann", 100000, 0); trade("Bob", 200000, 0)
  T.ok(R.Verdict("m1", 1))
  T.Advance(601)
  T.eq(R.Market("m1").status, "settled")
  T.eq(a.payout, 300000)
  return s, a, b
end

---------------------------------------------------------------------------

T.test("gold from a non-participant: unmatched 'nobet', no bet paid, nothing booked against anyone", function()
  host()
  local a = r2b("Ann-Normal", "m1", 1, 100000)
  local tr = trade("Zed", 100000, 0) -- same amount as Ann's stake, wrong person
  T.eq(tr.reason, "nobet"); T.eq(#tr.matched, 0); T.eq(a.paid, false)
  T.eq(#ns.char.ring.unmatched, 1)
  T.eq(#rowsOf("ring", "paid"), 0)
end)

T.test("same name on another realm is not the bettor", function()
  host()
  local a = r2b("Ann-Normal", "m1", 1, 100000)
  local tr = trade("Ann", 100000, 0, false, "Otherrealm")
  T.eq(a.paid, false, "Ann-Otherrealm is not Ann-Normal")
  T.eq(#tr.matched, 0)
  tr = trade("Ann", 100000, 0, false, "Normal")
  T.eq(a.paid, true, "Ann-Normal pays")
end)

T.test("payout to a non-winner / loser / stranger matches nothing and never touches the winner's debt", function()
  local s, a, b = settledRing()
  local tr = trade("Bob", 0, 200000) -- Bob lost: he is owed nothing
  T.eq(tr.reason, "nobet"); T.eq(#tr.matched, 0)
  tr = trade("Zed", 0, 300000)
  T.eq(tr.reason, "nobet")
  T.eq(a.paidOutAmount, 0); T.eq(R.Debts()[1].paid, 0); T.eq(#R.Owed(), 1)
  T.eq(#rowsOf("ring", "payout"), 0)
end)

T.test("double-fired TRADE_CLOSED books one trade row and one stake match", function()
  host()
  local a = r2b("Ann-Normal", "m1", 1, 100000)
  local b = r2b("Ann-Normal", "m1", 1, 10000) -- (dup: refused, a stays the only bet)
  T.eq(b, a)
  local before = #ns.char.trades
  trade("Ann", 100000, 0, true)
  T.eq(#ns.char.trades, before + 1, "one ledger row for one trade window")
  T.eq(#rowsOf("ring", "paid"), 1)
  T.eq(#ns.char.ring.unmatched, 0, "the second firing must not become an unmatched 'nobet' row")
end)

T.test("double-fired TRADE_CLOSED on a payout trade does not pay the next debt twice", function()
  local s, a, b = settledRing()
  local m2 = R.AddMarket({ kind = "custom", labels = { "yes", "no" }, open = true })
  local c = r2b("Ann-Normal", m2.mid, 1, 50000)
  trade("Ann", 50000, 0)
  R.Verdict(m2.mid, 1)
  T.Advance(601)
  T.eq(c.payout, 50000)
  -- Ann is owed 300000 (m1) + 50000 (m2). One 100000 payment, TRADE_CLOSED delivered twice.
  trade("Ann", 0, 100000, true)
  T.eq(a.paidOutAmount + c.paidOutAmount, 100000, "100000 gold moved once")
  T.eq(#rowsOf("ring", "payout"), 1)
end)

T.test("the same trade window replayed from the saved row (Retry) cannot double-pay a stake", function()
  host()
  local a = r2b("Ann-Normal", "m1", 1, 100000)
  trade("Ann", 100000, 0)
  T.eq(a.paid, true)
  L.Retry("Ann-Normal")
  L.Retry("Ann-Normal")
  T.eq(#rowsOf("ring", "paid"), 1)
end)

T.test("unmatched stake expires at 120 s: a bet 119 s after the trade late-matches, 121 s does not", function()
  host()
  local tr = trade("Cid", 50000, 0)
  T.eq(tr.reason, "nobet"); T.eq(#ns.char.ring.unmatched, 1)
  T.Advance(110)
  local c = r2b("Cid-Normal", "m1", 1, 50000) -- r2b spends 2.1 s; bet lands ~113 s after the trade
  T.ok(c.t - tr.t < 120, "inside the window: " .. (c.t - tr.t))
  T.eq(c.paid, true, "late-match inside 120 s")
  T.eq(#ns.char.ring.unmatched, 0)
  -- the other side of the edge
  local tr2 = trade("Dee", 50000, 0)
  T.Advance(125)
  local d = r2b("Dee-Normal", "m1", 2, 50000)
  T.eq(d.paid, false, "outside the window: not auto-assigned")
  T.eq(#ns.char.ring.unmatched, 1, "still sitting in the Unmatched list for manual assign")
  T.ok(L.Assign(1, R.session.id, "m1", "Dee-Normal"), "manual assign works")
  T.eq(d.paid, true); T.eq(d.manual, true); T.eq(#ns.char.ring.unmatched, 0)
end)

T.test("a stake trade for a bet already paid is not applied twice and lands in Unmatched", function()
  host()
  local a = r2b("Ann-Normal", "m1", 1, 100000)
  trade("Ann", 100000, 0)
  local again = trade("Ann", 100000, 0)
  T.eq(#again.matched, 0); T.eq(again.reason, "nobet")
  T.eq(#rowsOf("ring", "paid"), 1)
  T.eq(#ns.char.ring.unmatched, 1)
end)

T.test("Unmatched list is a 50-row FIFO: the 60 newest-first survivors are the last 50", function()
  host()
  for i = 1, 60 do trade("Zed", 10000 + i, 0) end
  T.eq(#ns.char.ring.unmatched, 50)
  T.eq(ns.char.ring.unmatched[1].got, 10011); T.eq(ns.char.ring.unmatched[50].got, 10060)
  T.eq(#ns.char.trades, 60)
end)

T.test("payout in three installments + 1 copper too many: debt clears exactly once, the excess is unmatched", function()
  local s, a = settledRing()
  local debt = R.Debts()[1]
  trade("Ann", 0, 100000)
  T.eq(a.paidOutAmount, 100000); T.eq(a.paidOut, false); T.eq(debt.paid, 100000); T.eq(debt.status, "due")
  T.eq(R.Owed()[1].amount, 200000)
  trade("Ann", 0, 150000)
  T.eq(a.paidOutAmount, 250000); T.eq(R.Owed()[1].amount, 50000)
  local last = trade("Ann", 0, 50001)
  T.eq(a.paidOutAmount, 300000, "never above the payout"); T.eq(a.paidOut, true)
  T.eq(debt.status, "cleared"); T.eq(debt.paid, 300000); T.eq(debt.clearedBy, "host")
  T.eq(last.reason, "excess"); T.eq(last.excess, 1)
  T.eq(#R.Owed(), 0)
  local sum = 0
  for _, r in ipairs(rowsOf("ring", "payout")) do sum = sum + r.amount end
  T.eq(sum, 300000, "payout rows add up to what was owed, not to what was handed over")
  local again = trade("Ann", 0, 5000)
  T.eq(again.reason, "nobet"); T.eq(a.paidOutAmount, 300000)
end)

T.test("an exact single-bet payout wins over oldest-first when Ann has two debts", function()
  local s, a = settledRing()
  local m2 = R.AddMarket({ kind = "custom", labels = { "yes", "no" }, open = true })
  local c = r2b("Ann-Normal", m2.mid, 1, 20000)
  trade("Ann", 20000, 0)
  R.Verdict(m2.mid, 1)
  T.Advance(601)
  T.eq(c.payout, 20000)
  trade("Ann", 0, 20000) -- exactly the newer bet
  T.eq(c.paidOut, true); T.eq(a.paidOutAmount, 0)
end)

T.test("payouts keep matching after the session has left Ring.last (debts only), then clear", function()
  local s, a = settledRing()
  local sid = s.id
  R.Close(true)
  for i = 1, 2 do -- two more sessions push the first out of Ring.last
    local s2 = R.Open("ratchet")
    T.ok(type(s2) == "table")
    R.Close(true)
  end
  T.ok(R.last.id ~= sid, "first session no longer in last")
  local debt
  for _, d in ipairs(R.Debts()) do if d.id == sid .. ".m1" then debt = d end end
  T.ok(debt and debt.amount == 300000, "debt survives")
  local tr = trade("Ann", 0, 120000)
  T.eq(#tr.matched, 1); T.eq(debt.paid, 120000)
  tr = trade("Ann", 0, 180000)
  T.eq(debt.status, "cleared"); T.eq(debt.paid, 300000)
  tr = trade("Ann", 0, 1)
  T.eq(tr.reason, "nobet")
  T.eq(debt.paid, 300000)
end)

T.test("unconfirmed money delta never matches a payout either", function()
  local s, a = settledRing()
  local before = T.money
  T.units.npc = { name = "Ann", isPlayer = true }
  T.Fire("TRADE_SHOW")
  T.trade.target, T.trade.player = 0, 300000
  T.Fire("TRADE_MONEY_CHANGED")
  T.Fire("TRADE_ACCEPT_UPDATE", 1, 1)
  T.Fire("TRADE_CLOSED")
  T.Advance(1.1) -- no PLAYER_MONEY: gold never left
  T.trade.target, T.trade.player = 0, 0
  local tr = ns.char.trades[#ns.char.trades]
  T.eq(tr.confirmed, false)
  T.eq(a.paidOutAmount, 0); T.eq(R.Debts()[1].paid, 0)
end)

T.noErrors()
T.done()
