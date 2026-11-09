-- Dispute / appeal (contract §2.2, §2.3, §8.2): R2D in the window -> disputed; late -> R2X late; second disputer
-- logged only; uphold -> settled; amend -> recompute + verdict_amend; void -> refunds + afterVerdict; 30 min with no
-- action -> auto-void; no outbox bet rows before settled; no payout matching while disputed.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 0 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 50 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, R = ns.A, ns.Ring
A.db.config.referee.available = true
A.db.config.ring.currency = "gold"
T.money = 100000000

local function party(...)
  local names = { ... }
  T.group = { size = #names + 1, raid = false }
  for i = 1, 4 do T.units["party" .. i] = names[i] and { name = names[i], isPlayer = true } or nil end
end

local function fields(m)
  local f = {}
  for p in (m.msg .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = p end
  table.remove(f, 1)
  return f
end

local function sentTo(typ, who, from)
  T.Advance(60) -- whispers queue behind group broadcasts in the 1/s comm bucket
  local out = {}
  for i = from or 1, #T.sent do
    local m = T.sent[i]
    if m.msg:sub(1, #typ + 1) == typ .. "\t" and m.target == who then out[#out + 1] = fields(m) end
  end
  return out
end

local function trade(partner, got, gave)
  T.units.npc = { name = partner, isPlayer = true }
  T.Fire("TRADE_SHOW")
  T.trade.target, T.trade.player = got, gave
  T.Fire("TRADE_MONEY_CHANGED")
  T.Fire("TRADE_ACCEPT_UPDATE", 1, 1)
  T.Fire("TRADE_CLOSED")
  T.SetMoney(T.money + got - gave)
  T.trade.target, T.trade.player = 0, 0
  T.Advance(1.1)
  return ns.char.trades[#ns.char.trades]
end

local function r2b(sender, idx, amount)
  local s = R.session
  T.Deliver("BSPT", table.concat({ "R2B", s.id, "m1", idx, amount, 0, "beef" }, "\t"), "WHISPER", sender)
  T.Advance(2.1)
  for _, b in ipairs(R.Market("m1", s).bets) do if b.bettor == sender then return b end end
end

local function r2d(sender, code, note, mid)
  T.Deliver("BSPT", table.concat({ "R2D", R.session.id, mid or "m1", code, note or "" }, "\t"), "WHISPER", sender)
end

local function rows(from, kind, ev)
  local out = {}
  for i = from + 1, #A.db.outbox.rows do
    local r = A.db.outbox.rows[i]
    if r.kind == kind and (not ev or r.data.ev == ev) then out[#out + 1] = r.data end
  end
  return out
end

-- Ann 10 g on Fa (paid), Bob 20 g on Fb (paid), Cid 5 g on Fb (never pays). Verdict Fa -> resolving.
local function scenario()
  if R.session then R.Close(true) end
  T.Advance(60)
  R.last, ns.char.ring.last = nil, nil
  ns.char.ring.debts, ns.char.ring.unmatched = {}, {}
  party("Ann", "Bob", "Cid", "Dee")
  local s = R.Open("ratchet")
  T.ok(type(s) == "table", "host session")
  T.ok(R.SetFighters("Fa", "Fb"))
  local b = { ann = r2b("Ann-Normal", 1, 100000), bob = r2b("Bob-Normal", 2, 200000), cid = r2b("Cid-Normal", 2, 50000) }
  trade("Ann", 100000, 0)
  trade("Bob", 200000, 0)
  T.ok(b.ann.paid and b.bob.paid and not b.cid.paid, "stakes")
  local m = R.Market("m1", s)
  local from = #A.db.outbox.rows
  T.ok(R.Verdict("m1", 1))
  T.eq(m.status, "resolving")
  T.eq(m.appealUntil, m.verdictAt + 600, "10 min appeal window")
  return s, m, b, from
end

T.test("R2D inside the window -> disputed; second disputer logged only; uncounted/outsider ignored", function()
  local s, m, b, from = scenario()
  r2d("Cid-Normal", "wrong", "unpaid stake")       -- Cid's bet does not count: no standing
  r2d("Dee-Normal", "wrong", "no bet")             -- no bet, not a fighter
  T.eq(m.status, "resolving", "no standing, no dispute")
  T.Advance(100)
  r2d("Bob-Normal", "wrong", "Fb won that")
  T.eq(m.status, "disputed")
  T.eq(m.dispute.by, "Bob-Normal"); T.eq(m.dispute.code, "wrong"); T.eq(m.dispute.note, "Fb won that")
  T.eq(m.dispute.at, m.verdictAt + 100)
  local d = rows(from, "ring", "dispute")
  T.eq(#d, 1); T.eq(d[1].by, "Bob-Normal"); T.eq(d[1].code, "wrong"); T.eq(d[1].mid, "m1")
  r2d("Bob-Normal", "foul", "again")               -- one R2D per sender per market
  r2d("Ann-Normal", "early", "")
  r2d("Fa-Normal", "bogus", "fighter")             -- a fighter has standing; unknown code -> other
  T.eq(m.dispute.by, "Bob-Normal", "first dispute stays")
  T.eq(#m.dispute.extra, 2, "later disputers logged in dispute.extra")
  T.eq(m.dispute.extra[1].by, "Ann-Normal"); T.eq(m.dispute.extra[1].code, "early")
  T.eq(m.dispute.extra[2].by, "Fa-Normal"); T.eq(m.dispute.extra[2].code, "other")
  T.eq(#rows(from, "ring", "dispute"), 1, "later disputes write no new dispute row")
end)

T.test("disputed: no bet rows, no payout matching, no settle when the window passes", function()
  local s, m, b, from = scenario()
  r2d("Bob-Normal", "wrong", string.rep("x", 120))
  T.eq(m.status, "disputed")
  T.eq(#m.dispute.note, 80, "note capped at 80 bytes")
  T.eq(b.ann.payout, 300000, "provisional payout")
  local tr = trade("Ann", 0, 300000)
  T.eq(tr.kind, "payout")
  T.eq(#tr.matched, 0, "no payout trade matches a disputed market")
  T.eq(b.ann.paidOutAmount, 0)
  T.Advance(700)
  T.eq(m.status, "disputed", "appealUntil passing does not settle a disputed market")
  T.eq(#rows(from, "bet"), 0, "no outbox bet rows before settled")
  T.eq(#R.Debts(), 0, "no debts before settled")
  T.eq(#R.Owed(), 0)
end)

T.test("R2D after the window -> R2X late, market unaffected", function()
  local s, m, b = scenario()
  T.Advance(599)
  T.eq(m.status, "resolving", "one second before appealUntil")
  T.Advance(2)
  T.eq(m.status, "settled", "window over: settled")
  local mark = #T.sent + 1
  r2d("Bob-Normal", "wrong", "too late")
  T.eq(m.status, "settled")
  T.eq(m.dispute, nil)
  local x = sentTo("R2X", "Bob-Normal", mark)
  T.eq(#x, 1); T.eq(x[1][1], s.id); T.eq(x[1][2], "m1"); T.eq(x[1][4], "late")
end)

T.test("uphold -> settled with the same result; bet rows written once, at settle", function()
  local s, m, b, from = scenario()
  r2d("Bob-Normal", "wrong")
  T.ok(not R.ResolveDispute("m1", "bogus"), "unknown action refused")
  T.ok(R.ResolveDispute("m1", "uphold"))
  T.eq(m.status, "settled"); T.eq(m.result, 1)
  T.eq(m.dispute.action, "uphold"); T.ok(m.dispute.resolvedAt)
  local dr = rows(from, "ring", "dispute_resolved")
  T.eq(#dr, 1); T.eq(dr[1].action, "uphold"); T.eq(dr[1].result, 1)
  local bets = rows(from, "bet")
  T.eq(#bets, 3)
  local by = {}
  for _, r in ipairs(bets) do by[r.bettor] = r end
  T.eq(by["Ann-Normal"].result, "win"); T.eq(by["Ann-Normal"].payout, 300000)
  T.eq(by["Bob-Normal"].result, "loss"); T.eq(by["Cid-Normal"].result, "void")
  T.ok(not R.ResolveDispute("m1", "void"), "final: no second resolution")
  T.Advance(700)
  T.eq(#rows(from, "bet"), 3, "no duplicate rows")
  -- payouts unlock at settle
  local tr = trade("Ann", 0, 300000)
  T.eq(#tr.matched, 1); T.ok(b.ann.paidOut)
end)

T.test("amend -> recompute, verdict_amend, settles at once with no new window", function()
  local s, m, b, from = scenario()
  r2d("Bob-Normal", "wrong")
  T.ok(not R.ResolveDispute("m1", "amend", 9), "amend needs a real outcome")
  T.ok(R.ResolveDispute("m1", "amend", 2))
  T.eq(m.status, "settled", "no second appeal window")
  T.eq(m.result, 2)
  T.eq(b.bob.payout, 300000, "Bob takes the pool"); T.eq(b.ann.payout, 0); T.eq(b.cid.payout, 0)
  T.ok(b.cid.void, "unpaid stays void")
  local am = rows(from, "ring", "verdict_amend")
  T.eq(#am, 1); T.eq(am[1].winner, "Fb-Normal"); T.eq(am[1].loser, "Fa-Normal"); T.eq(am[1].mid, "m1")
  local dr = rows(from, "ring", "dispute_resolved")
  T.eq(dr[1].action, "amend"); T.eq(dr[1].result, 2)
  local by = {}
  for _, r in ipairs(rows(from, "bet")) do by[r.bettor] = r end
  T.eq(by["Bob-Normal"].result, "win"); T.eq(by["Bob-Normal"].payout, 300000); T.eq(by["Bob-Normal"].marketResult, 2)
  T.eq(by["Ann-Normal"].result, "loss")
  T.eq(R.Debts()[1].bettor, "Bob-Normal"); T.eq(R.Debts()[1].amount, 300000)
end)

T.test("amend to the same winner writes no verdict_amend", function()
  local s, m, b, from = scenario()
  r2d("Bob-Normal", "early")
  T.ok(R.ResolveDispute("m1", "amend", 1))
  T.eq(m.status, "settled")
  T.eq(#rows(from, "ring", "verdict_amend"), 0)
end)

T.test("void -> refunds paid stakes, afterVerdict on the ring row", function()
  local s, m, b, from = scenario()
  r2d("Bob-Normal", "foul")
  T.ok(R.ResolveDispute("m1", "void"))
  T.eq(m.status, "void"); T.eq(m.voidReason, "dispute"); T.eq(m.afterVerdict, true)
  T.eq(b.ann.payout, 100000); T.eq(b.bob.payout, 200000); T.eq(b.cid.payout, 0)
  local v = rows(from, "ring", "void")
  T.eq(#v, 1); T.eq(v[1].reason, "dispute"); T.eq(v[1].afterVerdict, true)
  T.eq(rows(from, "ring", "dispute_resolved")[1].action, "void")
  local bets = rows(from, "bet")
  T.eq(#bets, 3)
  for _, r in ipairs(bets) do T.eq(r.result, "void") end
end)

T.test("30 min with no action -> auto-void (dispute timeout)", function()
  local s, m, b, from = scenario()
  r2d("Bob-Normal", "wrong")
  local at = m.dispute.at
  T.Advance(1790)
  T.eq(m.status, "disputed", "before DISPUTE_TIMEOUT_SEC")
  T.Advance(15)
  T.eq(m.status, "void"); T.eq(m.voidReason, "dispute"); T.eq(m.afterVerdict, true)
  T.ok(m.dispute.resolvedAt >= at + 1800)
  local dr = rows(from, "ring", "dispute_resolved")
  T.eq(#dr, 1); T.eq(dr[1].action, "void"); T.eq(dr[1].auto, true)
  T.eq(b.ann.payout, 100000); T.eq(b.bob.payout, 200000)
  R.Close(true)
end)

T.noErrors()
T.done()
