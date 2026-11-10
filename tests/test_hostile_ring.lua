-- Hostile QA, Ring money + state paths: double settle, empty/one-sided markets, void after a computed verdict,
-- bets at the cap/band/bettor-count edges and malformed amounts, fixed-odds liability + bookie cancel, series-scope
-- markets (per-round vs series end, void and forfeit series), dispute gating, extension void refunds.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 0 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 50 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, R, MK = ns.A, ns.Ring, MetaKit
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

-- Latest message of `typ` whispered to `who` (after the comm bucket drained).
local function lastTo(typ, who)
  T.Advance(30)
  local out
  for _, m in ipairs(T.sent) do
    if m.msg:sub(1, #typ + 1) == typ .. "\t" and m.target == who then out = fields(m) end
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

local nonce = 0
-- Sends R2B (amount is passed through as given, any type) and returns the accepted bet or nil + R2X code.
local function r2b(sender, mid, idx, amount, price)
  nonce = nonce + 1
  local before = #R.Market(mid).bets
  T.sent = {}
  T.Deliver("BSPT", table.concat({ "R2B", R.session.id, mid, tostring(idx), tostring(amount), tostring(price or 0),
    string.format("%04x", nonce) }, "\t"), "WHISPER", sender)
  T.Advance(2.1)
  local m = R.Market(mid)
  if #m.bets > before then return m.bets[#m.bets] end
  local x = lastTo("R2X", sender)
  return nil, x and x[4], x and tonumber(x[5])
end

local function reset(currency)
  if R.session then if R.IsHost() then R.Close(true) else R.Leave() end end
  T.Advance(60)
  R.last, ns.char.ring.last = nil, nil
  ns.char.ring.debts, ns.char.ring.unmatched = {}, {}
  ns.char.trades = {}
  WorldOfMetaData.bloodsports.bookies["Tester-Normal"].level = 5
  WorldOfMetaData.bloodsports.referees["Tester-Normal"].cap = 50
  A.db.config.ring.currency = currency or "gold"
end

local function host(opts)
  opts = opts or {}
  reset(opts.currency)
  if opts.level then WorldOfMetaData.bloodsports.bookies["Tester-Normal"].level = opts.level end
  if opts.cap then WorldOfMetaData.bloodsports.referees["Tester-Normal"].cap = opts.cap end
  party(unpack(opts.party or { "Ann", "Bob", "Cid", "Dee" }))
  local s = R.Open("ratchet")
  T.ok(type(s) == "table", "host session")
  if not opts.nofighters then T.ok(R.SetFighters("Fa", "Fb")) end
  return s
end

local function rowsOf(kind, ev, sid)
  local out = {}
  for _, r in ipairs(A.db.outbox.rows) do
    if r.kind == kind and (not ev or r.data.ev == ev) and (not sid or tostring(r.data.id):sub(1, #sid) == sid) then
      out[#out + 1] = r.data
    end
  end
  return out
end

local function sum(m, field)
  local n = 0
  for _, b in ipairs(m.bets) do n = n + (b[field] or 0) end
  return n
end

local function paidStakes(m)
  local n = 0
  for _, b in ipairs(m.bets) do if b.paid then n = n + b.amount end end
  return n
end

---------------------------------------------------------------------------
-- 1. settle twice, settle with nothing

T.test("double settle: ticks, re-verdict, re-uphold, Void and Close after settled change nothing and book once", function()
  local s = host()
  local ann, bob = r2b("Ann-Normal", "m1", 1, 100000), r2b("Bob-Normal", "m1", 2, 300000)
  trade("Ann", 100000, 0); trade("Bob", 300000, 0)
  local m = R.Market("m1")
  T.ok(R.Verdict("m1", 1))
  T.Advance(601)
  T.eq(m.status, "settled")
  local rows, debts, settledAt, payout = #rowsOf("bet", nil, s.id), #R.Debts(), m.settledAt, ann.payout
  T.eq(rows, 2); T.eq(debts, 1); T.eq(payout, 400000)
  for _ = 1, 5 do R.Tick() end
  T.Advance(5000)
  T.ok(not R.Verdict("m1", 2), "settled market takes no second verdict")
  T.ok(not R.Verdict("m1", 1))
  T.ok(not R.ResolveDispute("m1", "uphold"), "nothing to uphold")
  T.ok(not R.ResolveDispute("m1", "void"), "settled market cannot be voided through a dispute")
  T.ok(not R.Void("m1"), "settled market cannot be voided")
  local s2 = R.session or R.last
  R.Close(true)
  T.eq(m.status, "settled"); T.eq(m.result, 1); T.eq(ann.payout, payout); T.eq(bob.payout, 0)
  T.eq(m.settledAt, settledAt)
  T.eq(#rowsOf("bet", nil, s2.id), rows, "outbox bet rows written once")
  T.eq(#R.Debts(), debts, "one debt per paying bet")
  T.eq(#rowsOf("ring", "settle", s2.id), 1, "one settle row")
end)

T.test("settle with 0 bets: settles clean, no rows, no debts, no dust, no errors", function()
  local s = host()
  local m = R.Market("m1")
  T.ok(R.Verdict("m1", 2))
  T.Advance(601)
  T.eq(m.status, "settled"); T.eq(m.dust, 0)
  T.eq(#rowsOf("bet", nil, s.id), 0); T.eq(#R.Debts(), 0); T.eq(#R.Owed(), 0)
  local st = rowsOf("ring", "settle", s.id)[1]
  T.eq(st.count, 0); T.eq(st.dust, 0); T.eq(st.pools[1], 0); T.eq(st.pools[2], 0)
  T.noErrors()
end)

T.test("settle with 0 bets via void and via Close: no division by zero, session closes", function()
  local s = host()
  T.ok(R.Void("m1"))
  T.eq(R.Market("m1", s).status, "void")
  T.ok(R.Close())
  T.eq(s.status, "closed")
  T.noErrors()
end)

T.test("one-sided and empty-winner markets refund every counted stake exactly; unpaid stakes void", function()
  local s = host()
  local a, b, c = r2b("Ann-Normal", "m1", 1, 123457), r2b("Bob-Normal", "m1", 1, 10000), r2b("Cid-Normal", "m1", 1, 77777)
  trade("Ann", 123457, 0); trade("Bob", 10000, 0) -- Cid never pays
  local m = R.Market("m1")
  T.ok(R.Verdict("m1", 1)) -- only side 1 has stakes: L = 0
  T.eq(a.payout, 123457); T.eq(b.payout, 10000); T.eq(c.payout, 0); T.eq(c.void, true); T.eq(c.voidReason, "unpaid")
  T.eq(m.dust, 0)
  T.Advance(601)
  local res = {}
  for _, r in ipairs(rowsOf("bet", nil, s.id)) do res[r.bettor] = r.result end
  T.eq(res["Ann-Normal"], "win", "L = 0: winners are repaid their stake (payout == amount), row stays a win")
  T.eq(res["Cid-Normal"], "void", "unpaid stake is void")
  -- nobody on the winning outcome
  host()
  local x = r2b("Ann-Normal", "m1", 1, 50000)
  local y = r2b("Bob-Normal", "m1", 1, 20000)
  trade("Ann", 50000, 0); trade("Bob", 20000, 0)
  T.ok(R.Verdict("m1", 2))
  T.eq(x.payout, 50000); T.eq(y.payout, 20000)
  T.eq(R.Market("m1").dust, 0)
end)

---------------------------------------------------------------------------
-- 2. void after the payout calc

T.test("void after verdict (resolving): payouts become refunds of PAID stakes only, afterVerdict flagged, one debt per refund", function()
  local s = host()
  local a, b, c = r2b("Ann-Normal", "m1", 1, 100000), r2b("Bob-Normal", "m1", 2, 200000), r2b("Cid-Normal", "m1", 2, 50000)
  trade("Ann", 100000, 0); trade("Bob", 200000, 0)
  local m = R.Market("m1")
  T.ok(R.Verdict("m1", 1))
  T.eq(a.payout, 300000)
  T.ok(R.Void("m1"))
  T.eq(m.status, "void"); T.eq(m.result, 0); T.eq(m.afterVerdict, true)
  T.eq(a.payout, 100000, "winner gets her stake back, not the provisional 300000")
  T.eq(b.payout, 200000); T.eq(c.payout, 0); T.eq(m.dust, 0)
  T.eq(sum(m, "payout"), paidStakes(m), "refunds == paid stakes")
  T.eq(#R.Debts(), 2, "only paid refunds are debts")
  local v = rowsOf("ring", "void", s.id)[1]
  T.eq(v.afterVerdict, true)
  for _, r in ipairs(rowsOf("bet", nil, s.id)) do T.eq(r.result, "void"); T.eq(r.marketResult, 0) end
  T.Advance(5000)
  T.eq(m.status, "void", "timer must not settle a voided market")
  T.eq(#rowsOf("bet", nil, s.id), 3)
  -- refund trade clears the refund debt
  trade("Ann", 0, 100000)
  T.eq(a.paidOut, true)
end)

T.test("void while disputed, then the old appeal window passing: stays void, refunds only", function()
  local s = host()
  local a, b = r2b("Ann-Normal", "m1", 1, 100000), r2b("Bob-Normal", "m1", 2, 200000)
  trade("Ann", 100000, 0); trade("Bob", 200000, 0)
  local m = R.Market("m1")
  R.Verdict("m1", 1)
  T.Deliver("BSPT", table.concat({ "R2D", s.id, "m1", "wrong", "x" }, "\t"), "WHISPER", "Bob-Normal")
  T.eq(m.status, "disputed")
  T.ok(R.Void("m1"))
  T.eq(m.status, "void"); T.ok(m.dispute.resolvedAt, "dispute closed by the void")
  T.Advance(3000)
  T.eq(m.status, "void"); T.eq(a.payout, 100000); T.eq(b.payout, 200000)
  T.ok(not R.ResolveDispute("m1", "uphold"))
end)

---------------------------------------------------------------------------
-- 3. cap / band / bettor-count edges and malformed amounts

T.test("gold cap edge: exactly 50g accepted, 1 copper over refused 'amount' with the cap; min edge 1g", function()
  host()
  local b, why, max = r2b("Ann-Normal", "m1", 1, 500001)
  T.eq(b, nil); T.eq(why, "amount"); T.eq(max, 500000)
  b, why = r2b("Bob-Normal", "m1", 1, 9999)
  T.eq(b, nil); T.eq(why, "amount")
  T.ok(r2b("Cid-Normal", "m1", 1, 500000), "cap edge accepted")
  T.ok(r2b("Ann-Normal", "m1", 1, 10000), "min edge accepted (Ann's earlier bet was refused)")
end)

T.test("band edge: level 2 = 20g; 20g accepted, 20g+1c refused 'band' with max 200000", function()
  host({ level = 2 })
  local b, why, max = r2b("Ann-Normal", "m1", 1, 200001)
  T.eq(b, nil); T.eq(why, "band"); T.eq(max, 200000)
  T.ok(r2b("Bob-Normal", "m1", 2, 200000))
end)

T.test("referee cap below the band: cap 5g wins over a level-5 band", function()
  local s = host({ cap = 5 })
  T.eq(s.cap, 50000)
  local b, why, max = r2b("Ann-Normal", "m1", 1, 50001)
  T.eq(b, nil); T.eq(why, "amount"); T.eq(max, 50000)
  T.ok(r2b("Bob-Normal", "m1", 1, 50000))
end)

T.test("hostile amounts (nan, inf, negative, fractional, hex, exponent, garbage) never create a bad bet", function()
  local s = host()
  local cases = { "nan", "inf", "-inf", "-10000", "0", "10000.9", "0x2710", "1e4", "1e300", "", "abc", "10000abc", " 10000" }
  for i, amt in ipairs(cases) do
    local who = "Mal" .. i .. "-Normal"
    local b = r2b(who, "m1", 1, amt)
    if b then
      T.ok(b.amount == math.floor(b.amount) and b.amount >= 10000 and b.amount <= 500000,
        "accepted '" .. amt .. "' as a bad amount: " .. tostring(b.amount))
    end
  end
  for _, b in ipairs(R.Market("m1").bets) do
    T.ok(b.amount == math.floor(b.amount) and b.amount >= 10000 and b.amount <= 500000, "bet amount sane: " .. tostring(b.amount))
  end
  T.noErrors()
end)

T.test("one bet per market: case-variant / realm-variant names are the same bettor; host and fighters cannot bet", function()
  host()
  T.ok(r2b("Ann-Normal", "m1", 1, 10000))
  local b, why = r2b("ann-normal", "m1", 2, 10000)
  T.eq(b, nil); T.eq(why, "dup")
  b = r2b("Tester-Normal", "m1", 1, 10000) -- comm drops the host's own messages
  T.eq(b, nil, "host bets refused")
  b, why = r2b("Fa-Normal", "m1", 1, 10000)
  T.eq(b, nil); T.eq(why, "fighter")
  b, why = r2b("Bob-Normal", "m1", 3, 10000)
  T.eq(b, nil); T.eq(why, "market", "no outcome 3 on a winner market")
  T.eq(#R.Market("m1").bets, 1)
end)

T.test("31st distinct bettor refused 'full' across markets; an existing bettor can still take another market", function()
  local s = host()
  local m2 = R.AddMarket({ kind = "custom", labels = { "yes", "no" }, open = true })
  T.ok(m2)
  for i = 1, 30 do T.ok(r2b("Gambler" .. i .. "-Normal", "m1", 1 + i % 2, 10000), "bettor " .. i) end
  T.Advance(60) -- the 30 accepted bets queued a long fan-out; let the outbound bucket drain
  local b, why = r2b("Late-Normal", "m1", 1, 10000)
  T.eq(b, nil); T.eq(why, "full")
  b, why = r2b("Late-Normal", "m2", 1, 10000)
  T.eq(b, nil); T.eq(why, "full", "a new bettor is full in every market")
  T.ok(r2b("Gambler1-Normal", "m2", 1, 10000), "existing bettor, second market")
  local seen, n = {}, 0
  for _, m in ipairs(R.Markets()) do
    for _, bt in ipairs(m.bets) do if not seen[bt.bettor] then seen[bt.bettor] = true; n = n + 1 end end
  end
  T.eq(n, 30)
end)

T.test("flood guard: 5 refused bets silence a sender, even for a valid bet afterwards", function()
  host()
  for i = 1, 6 do r2b("Spam-Normal", "m1", 1, 1) end
  local b = r2b("Spam-Normal", "m1", 1, 10000)
  T.eq(b, nil, "silenced sender gets nothing accepted")
  T.ok(r2b("Clean-Normal", "m1", 1, 10000), "others unaffected")
end)

T.test("bets on a locked, resolving or settled market are refused 'closed'", function()
  host()
  T.ok(R.Lock("m1"))
  local b, why = r2b("Ann-Normal", "m1", 1, 10000)
  T.eq(b, nil); T.eq(why, "closed")
  R.Verdict("m1", 1)
  b, why = r2b("Bob-Normal", "m1", 1, 10000)
  T.eq(b, nil); T.eq(why, "closed")
  T.Advance(601)
  b, why = r2b("Cid-Normal", "m1", 1, 10000)
  T.eq(b, nil); T.eq(why, "closed")
end)

---------------------------------------------------------------------------
-- 4. fixed odds: liability, bookie cancel

local function fixedMarket(bank, p1, p2)
  local m = R.AddMarket({ kind = "winner", mode = "fixed", prices = { p1 or 180, p2 or 210 }, bank = bank or 250000 })
  T.ok(type(m) == "table", "fixed market added")
  T.ok(R.OpenMarket(m.mid), "fixed market opened")
  return m
end

T.test("fixed odds: contract §3.3 table (bank 25g, 1.80/2.10): Cid 50g refused with max 487500, 45g accepted", function()
  local s = host({ nofighters = true })
  T.ok(R.SetFighters("Fa", "Fb")) -- m1 pari
  local m = fixedMarket(250000, 180, 210)
  local a = r2b("Ann-Normal", m.mid, 1, 200000, 180); trade("Ann", 200000, 0)
  local b = r2b("Bob-Normal", m.mid, 2, 300000, 210); trade("Bob", 300000, 0)
  T.ok(a and b)
  local x, why, max = r2b("Cid-Normal", m.mid, 1, 500000, 180)
  T.eq(x, nil); T.eq(why, "bank")
  T.eq(max, 487500, "contract: max stake on o1 = 487500 (below the 50g cap)")
  local c = r2b("Cid-Normal", m.mid, 1, 450000, 180)
  T.ok(c, "45g accepted")
  T.eq(R.Liability(m.mid, 1), 220000, "L1 = 22g")
  T.eq(R.Liability(m.mid, 2), 130000, "L2 = 13g")
end)

T.test("fixed odds: stale price in R2B is refused 'price'; price change does not reprice existing bets", function()
  host()
  local m = fixedMarket(250000, 180, 210)
  local x, why = r2b("Ann-Normal", m.mid, 1, 10000, 150)
  T.eq(x, nil); T.eq(why, "price")
  local a = r2b("Bob-Normal", m.mid, 1, 100000, 180)
  T.eq(a.price, 180)
  T.ok(R.SetPrice(m.mid, 1, 500))
  T.eq(a.price, 180, "accepted bet keeps its locked price")
  trade("Bob", 100000, 0)
  R.Verdict(m.mid, 1)
  T.eq(a.payout, 180000)
end)

T.test("fixed odds: bookie cancels (Void) with a mix of paid / unpaid bets: refunds of paid stakes only, bank exposure gone", function()
  local s = host()
  local m = fixedMarket(250000, 180, 210)
  local a = r2b("Ann-Normal", m.mid, 1, 200000, 180)
  local b = r2b("Bob-Normal", m.mid, 2, 100000, 210)
  trade("Ann", 200000, 0) -- Bob never pays
  T.ok(R.Void(m.mid))
  T.eq(m.status, "void")
  T.eq(a.payout, 200000, "refund, not 360000"); T.eq(b.payout, 0); T.eq(b.void, true)
  T.eq(sum(m, "payout"), paidStakes(m))
  local rows = rowsOf("bet", nil, s.id)
  T.eq(#rows, 2)
  for _, r in ipairs(rows) do T.eq(r.result, "void") end
  T.eq(#R.Debts(), 1)
  T.eq(R.Debts()[1].amount, 200000)
end)

T.test("fixed odds: after a verdict, winning payout = floor(amount*price/100); unpaid winner gets 0 and does not eat the bank", function()
  local s = host()
  local m = fixedMarket(250000, 215, 150)
  local a = r2b("Ann-Normal", m.mid, 1, 123450, 215)
  local b = r2b("Bob-Normal", m.mid, 1, 50000, 215)
  T.ok(a and b)
  trade("Ann", 123450, 0)
  R.Verdict(m.mid, 1)
  T.eq(a.payout, math.floor(123450 * 215 / 100))
  T.eq(b.payout, 0); T.eq(b.void, true)
  T.eq(m.dust, 0)
end)

T.test("fixed odds property: with every accepted bet paid, the bookie loses at most the bank whichever outcome wins", function()
  math.randomseed(42)
  for trial = 1, 12 do
    host({ level = 5 })
    local nOut = 2
    local bank = 10000 * math.random(5, 40)
    local p1, p2 = math.random(101, 1000), math.random(101, 1000)
    local m = fixedMarket(bank, p1, p2)
    local n = 0
    for i = 1, 12 do
      local idx = math.random(1, nOut)
      local amt = 10000 * math.random(1, 50)
      local b = r2b("Prop" .. trial .. "x" .. i .. "-Normal", m.mid, idx, amt, idx == 1 and p1 or p2)
      if b then
        n = n + 1
        trade("Prop" .. trial .. "x" .. i, amt, 0)
        T.ok(b.paid, "paid")
      end
    end
    for k = 1, nOut do
      local stakes, pays = 0, 0
      for _, b in ipairs(m.bets) do
        stakes = stakes + b.amount
        if b.outcome == k then pays = pays + R.FixedPayout(b.amount, b.price) end
      end
      T.ok(pays - stakes <= bank, string.format("trial %d outcome %d: bookie net %d exceeds bank %d", trial, k, stakes - pays, bank))
      T.eq(R.Liability(m.mid, k) <= bank, true, "liability within the bank")
    end
  end
end)

---------------------------------------------------------------------------
-- 5. series-scope markets

local function system(text) T.Fire("CHAT_MSG_SYSTEM", text) end

local function seriesSession(bo)
  local s = host()
  A:Fire("SERIES_START", { id = "abcd1234", bo = bo or 3, a = "Fa-Normal", b = "Fb-Normal", champion = false })
  T.eq(s.series.bo, bo or 3)
  return s
end

local function addSeriesMarkets()
  local w = R.AddMarket({ kind = "winner", scope = "series", open = true })
  local sc = R.AddMarket({ kind = "score", open = true })
  T.ok(w and sc, "series markets")
  return w, sc
end

T.test("bo3: fight-scope market settles per round once; series markets settle once at SERIES_DONE (no double pay)", function()
  local s = seriesSession(3)
  local fight = R.Market("m1")
  local w, sc = addSeriesMarkets()
  local f1 = r2b("Ann-Normal", "m1", 1, 100000)
  local sw1, sw2 = r2b("Bob-Normal", w.mid, 1, 100000), r2b("Cid-Normal", w.mid, 2, 100000)
  local ss = r2b("Dee-Normal", sc.mid, 1, 100000)
  for _, p in ipairs({ { "Ann", 100000 }, { "Bob", 100000 }, { "Cid", 100000 }, { "Dee", 100000 } }) do trade(p[1], p[2], 0) end
  -- round 1: Fa defeats Fb
  system("Fa has defeated Fb in a duel")
  T.eq(fight.status, "resolving"); T.eq(fight.result, 1)
  T.ok(w.status == "open" or w.status == "locked", "series market not touched by a round verdict: " .. w.status)
  T.ok(sc.status == "open" or sc.status == "locked")
  -- round 2: same duel message again must not re-verdict the fight market or the series markets
  system("Fb has defeated Fa in a duel")
  T.eq(fight.result, 1, "fight market keeps round 1's result")
  T.ok(w.status == "open" or w.status == "locked")
  -- series ends 2-0 for Fa
  A:Fire("SERIES_DONE", { id = "abcd1234", winner = "Fa-Normal", scoreA = 2, scoreB = 0, bo = 3 })
  T.eq(w.status, "resolving"); T.eq(w.result, 1)
  T.eq(sc.status, "resolving"); T.eq(sc.result, 1, "2-0 is outcome 1")
  T.eq(sw1.payout, 200000); T.eq(sw2.payout, 0); T.eq(ss.payout, 100000)
  -- the very same SERIES_DONE again: nothing moves
  local rev = w.rev
  A:Fire("SERIES_DONE", { id = "abcd1234", winner = "Fb-Normal", scoreA = 0, scoreB = 2, bo = 3 })
  T.eq(w.result, 1); T.eq(w.rev, rev, "second SERIES_DONE ignored"); T.eq(sw1.payout, 200000); T.eq(sw2.payout, 0)
  T.Advance(601)
  T.eq(w.status, "settled"); T.eq(sc.status, "settled"); T.eq(fight.status, "settled")
  T.eq(#rowsOf("bet", nil, s.id), 4, "one bet row per bet, none doubled")
  local debts = 0
  for _, d in ipairs(R.Debts()) do debts = debts + d.amount end
  T.eq(debts, f1.payout + sw1.payout + ss.payout, "debts == payouts, each counted once")
end)

T.test("series SERIES_DONE of another series id does not touch this session's markets", function()
  seriesSession(3)
  local w = addSeriesMarkets()
  r2b("Ann-Normal", w.mid, 1, 10000)
  A:Fire("SERIES_DONE", { id = "deadbeef", winner = "Fa-Normal", scoreA = 2, scoreB = 0, bo = 3 })
  T.ok(w.status == "open" or w.status == "locked")
end)

T.test("series void mid-bo3 (two void rounds / cancel) with bets open: series markets void and refund paid stakes", function()
  local s = seriesSession(3)
  local w, sc = addSeriesMarkets()
  local a, b = r2b("Ann-Normal", w.mid, 1, 100000), r2b("Bob-Normal", w.mid, 2, 200000)
  local c, d = r2b("Cid-Normal", sc.mid, 3, 50000), r2b("Dee-Normal", sc.mid, 1, 70000)
  for _, p in ipairs({ { "Ann", 100000 }, { "Bob", 200000 }, { "Cid", 50000 } }) do trade(p[1], p[2], 0) end -- Dee unpaid
  A:Fire("SERIES_DONE", { id = "abcd1234", bo = 3, a = "Fa-Normal", b = "Fb-Normal", scoreA = 1, scoreB = 0, void = true, reason = "timeout" })
  T.eq(w.status, "void", "winner series market refunded when the series is void")
  T.eq(sc.status, "void", "score series market refunded when the series is void")
  T.eq(a.payout, 100000); T.eq(b.payout, 200000); T.eq(c.payout, 50000); T.eq(d.payout, 0)
  T.eq(w.result, 0); T.eq(sc.result, 0)
end)

T.test("series forfeit with a score no score-market outcome covers (1-0 in a bo3): market refunds instead of hanging open", function()
  local s = seriesSession(3)
  local w, sc = addSeriesMarkets()
  local a, c = r2b("Ann-Normal", w.mid, 1, 100000), r2b("Cid-Normal", sc.mid, 1, 50000)
  trade("Ann", 100000, 0); trade("Cid", 50000, 0)
  A:Fire("SERIES_DONE", { id = "abcd1234", bo = 3, winner = "Fa-Normal", a = "Fa-Normal", b = "Fb-Normal", scoreA = 1, scoreB = 0, reason = "forfeit" })
  T.eq(w.status, "resolving"); T.eq(w.result, 1, "the forfeit winner wins the winner market")
  T.eq(sc.status, "void", "no '1-0' outcome exists: refund")
  T.eq(c.payout, 50000)
end)

T.test("series_done reaches extension series markets as void too (no verdict from a void series)", function()
  local ok = MK.Ext and MK.Ext.Register and MK.Ext.Register("market", "hostile_series", {
    owner = "Test", label = "Hostile series", scope = "series", outcomes = { "A", "B" },
    settle = function(_, event) if event.type == "series_done" and not event.void then return 1 end end })
  if not ok then return end
  local s = seriesSession(3)
  local m = R.AddMarket({ kind = "hostile_series", scope = "series", open = true })
  T.ok(m, "ext series market")
  local a = r2b("Ann-Normal", m.mid, 1, 100000)
  trade("Ann", 100000, 0)
  A:Fire("SERIES_DONE", { id = "abcd1234", bo = 3, a = "Fa-Normal", b = "Fb-Normal", scoreA = 0, scoreB = 0, void = true, reason = "cancelled" })
  T.eq(m.status, "void")
  T.eq(a.payout, 100000)
end)

---------------------------------------------------------------------------
-- 6. dispute gating

T.test("dispute blocks settle and payout until the referee rules; uphold then lets the payout trade match, once", function()
  local s = host()
  local a, b = r2b("Ann-Normal", "m1", 1, 100000), r2b("Bob-Normal", "m1", 2, 200000)
  trade("Ann", 100000, 0); trade("Bob", 200000, 0)
  local m = R.Market("m1")
  R.Verdict("m1", 1)
  T.Deliver("BSPT", table.concat({ "R2D", s.id, "m1", "wrong", "Fb won" }, "\t"), "WHISPER", "Bob-Normal")
  T.eq(m.status, "disputed")
  T.Advance(1700)
  T.eq(m.status, "disputed", "still disputed 28 min later")
  local tr = trade("Ann", 0, 300000)
  T.eq(#tr.matched, 0); T.eq(a.paidOutAmount, 0)
  T.ok(not R.AssignTrade(tr, s.id, "m1", "Ann-Normal"), "manual assign cannot pay a disputed market either")
  T.ok(R.ResolveDispute("m1", "uphold"))
  T.eq(m.status, "settled")
  T.ok(not R.ResolveDispute("m1", "uphold"), "second uphold is a no-op")
  local before = #rowsOf("bet", nil, s.id)
  tr = trade("Ann", 0, 300000)
  T.eq(a.paidOutAmount, 300000); T.eq(a.paidOut, true)
  tr = trade("Ann", 0, 300000)
  T.eq(a.paidOutAmount, 300000, "no double payout of the same bet")
  T.eq(tr.reason, "nobet")
  T.eq(#rowsOf("bet", nil, s.id), before)
end)

T.test("dispute amend with a bad index / unknown action leaves the market disputed and untouched", function()
  local s = host()
  local a, b = r2b("Ann-Normal", "m1", 1, 100000), r2b("Bob-Normal", "m1", 2, 200000)
  trade("Ann", 100000, 0); trade("Bob", 200000, 0)
  local m = R.Market("m1")
  R.Verdict("m1", 1)
  T.Deliver("BSPT", table.concat({ "R2D", s.id, "m1", "wrong", "x" }, "\t"), "WHISPER", "Bob-Normal")
  T.ok(not R.ResolveDispute("m1", "amend", 9))
  T.ok(not R.ResolveDispute("m1", "amend", 0))
  T.ok(not R.ResolveDispute("m1", "amend", nil))
  T.ok(not R.ResolveDispute("m1", "bogus"))
  T.eq(m.status, "disputed"); T.eq(m.result, 1); T.eq(a.payout, 300000); T.eq(b.payout, 0)
  T.ok(R.ResolveDispute("m1", "amend", 2))
  T.eq(m.status, "settled"); T.eq(m.result, 2); T.eq(a.payout, 0); T.eq(b.payout, 300000)
  T.eq(#R.Debts(), 1); T.eq(R.Debts()[1].bettor, "Bob-Normal")
  T.eq(#rowsOf("bet", nil, s.id), 2)
end)

T.test("manual stake assign into a resolving market is refused (the stake would be uncounted and silently lost)", function()
  host()
  local x = r2b("Ann-Normal", "m1", 1, 100000)
  local y = r2b("Bob-Normal", "m1", 2, 200000)
  trade("Ann", 100000, 0)
  R.Verdict("m1", 1)
  T.eq(y.void, true, "Bob never paid: void at the verdict")
  local m = R.Market("m1")
  local pre = sum(m, "payout")
  local tr = { t = GetServerTime(), partner = "Bob-Normal", got = 200000, gave = 0, confirmed = true, matched = {} }
  T.eq(R.AssignTrade(tr, R.session.id, "m1", "Bob-Normal"), false, "AssignTrade must refuse a stake after the verdict")
  T.eq(y.paid, false)
  T.eq(sum(m, "payout"), pre)
  T.Advance(601)
  T.eq(m.status, "settled")
  tr.matched = {}
  T.eq(R.AssignTrade(tr, R.session.id, "m1", "Bob-Normal"), false, "nor after settlement")
end)

---------------------------------------------------------------------------
-- 7. extension market: settle false -> void

T.test("extension settle hook returning false voids with refunds of paid stakes; a later fight_end does not re-open or re-pay", function()
  if not (MK.Ext and MK.Ext.Register) then return end
  MK.Ext.Register("market", "hostile_voider", { owner = "Test", label = "Voider", outcomes = { "Yes", "No" },
    settle = function(_, event) if event.type == "fight_end" then return false end end })
  local s = host()
  local m = R.AddMarket({ kind = "hostile_voider", open = true })
  T.ok(m, "ext market")
  local a, b = r2b("Ann-Normal", m.mid, 1, 100000), r2b("Bob-Normal", m.mid, 2, 40000)
  trade("Ann", 100000, 0) -- Bob unpaid
  system("Fa has defeated Fb in a duel")
  T.eq(m.status, "void"); T.eq(m.voidReason, "extension")
  T.eq(a.payout, 100000); T.eq(b.payout, 0)
  local rows = #rowsOf("bet", nil, s.id)
  system("Fb has defeated Fa in a duel")
  T.eq(m.status, "void"); T.eq(#rowsOf("bet", nil, s.id), rows)
  T.eq(R.Market("m1").result, 1, "the core winner market still got its own verdict from the first message")
end)

T.done()
