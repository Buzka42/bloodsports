-- Hostile QA, money math (BETTING_CONTRACT §3.2 / §3.3): randomized pools through the real pari / fixed payout code,
-- against an independent reference (payout = a + floor(L*a/W), exact in doubles below 2^53), the conservation law
-- sum(payouts) + dust == counted pool, dust bounds, order independence, the mirror's recompute, and end to end
-- through a hosted session (m.dust, debts, settle row pools).
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 0 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 50 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, R = ns.A, ns.Ring
A.db.config.referee.available = true
A.db.config.ring.currency = "gold"
T.money = 100000000000

math.randomseed(20261110)
local rnd = math.random

local function counted(b) return b.paid end

-- Reference: written from the contract text, not from Ring.lua.
local function reference(bets, r)
  local T_, pool = 0, {}
  for _, b in ipairs(bets) do
    if b.paid then T_ = T_ + b.amount; pool[b.outcome] = (pool[b.outcome] or 0) + b.amount end
  end
  local W = r and pool[r] or 0
  local out = {}
  for i, b in ipairs(bets) do
    if not b.paid then out[i] = 0
    elseif not r or W == 0 then out[i] = b.amount
    elseif b.outcome == r then out[i] = b.amount + math.floor((T_ - W) * b.amount / W)
    else out[i] = 0 end
  end
  return out, T_, W, pool
end

local function randomBets(maxAmount, nOut, nBets)
  local bets = {}
  for i = 1, nBets do
    local amount
    local kind = rnd(1, 6)
    if kind == 1 then amount = 1                       -- points-sized stakes
    elseif kind == 2 then amount = maxAmount           -- cap edge
    elseif kind == 3 then amount = 10000               -- gold minimum
    else amount = rnd(1, maxAmount) end
    bets[i] = { bettor = "P" .. i, outcome = rnd(1, nOut), amount = amount, paid = rnd(1, 8) ~= 1 }
  end
  return bets
end

T.test("pari: 3000 random markets match the reference; conservation, dust bound, refunds, winners never lose stake", function()
  for trial = 1, 3000 do
    local nOut = rnd(2, 8)
    local maxAmount = ({ 500000, 2000000, 1000, 50 })[rnd(1, 4)]
    local bets = randomBets(maxAmount, nOut, rnd(1, 30))
    local r = rnd(0, nOut)
    if r == 0 then r = nil end
    local out, P, dust = R.ComputePayouts(bets, r, counted, nOut)
    local want, total, W = reference(bets, r)
    local sum, winners = 0, 0
    for i, b in ipairs(bets) do
      local p = out[b]
      local ctx = string.format("trial %d bet %d (outcome %d amount %d paid %s r %s)", trial, i, b.outcome, b.amount, tostring(b.paid), tostring(r))
      T.eq(p, want[i], ctx)
      T.ok(p >= 0 and p == math.floor(p), "non-negative integer: " .. ctx)
      if not b.paid then T.eq(p, 0, "unpaid pays nothing: " .. ctx) end
      if b.paid and r and W > 0 and b.outcome == r then
        T.ok(p >= b.amount, "winner keeps at least the stake: " .. ctx)
        winners = winners + 1
      end
      sum = sum + p
    end
    T.eq(sum + dust, total, "conservation, trial " .. trial)
    T.ok(dust >= 0, "dust never negative")
    if r and W > 0 then T.ok(dust < winners, string.format("trial %d: dust %d < %d winning bets", trial, dust, winners))
    else T.eq(dust, 0, "refund rounds nothing") end
    local pool = 0
    for k = 1, nOut do pool = pool + P[k] end
    T.eq(pool, total, "pools add up to the counted total")
  end
end)

T.test("pari: payouts do not depend on bet order; the referee's dust is the same however the bets arrive", function()
  for trial = 1, 300 do
    local nOut = rnd(2, 6)
    local bets = randomBets(500000, nOut, rnd(2, 30))
    local r = rnd(1, nOut)
    local out, _, dust = R.ComputePayouts(bets, r, counted, nOut)
    local shuffled = {}
    for i, b in ipairs(bets) do shuffled[i] = b end
    for i = #shuffled, 2, -1 do local j = rnd(1, i); shuffled[i], shuffled[j] = shuffled[j], shuffled[i] end
    local out2, _, dust2 = R.ComputePayouts(shuffled, r, counted, nOut)
    T.eq(dust2, dust, "dust, trial " .. trial)
    for _, b in ipairs(bets) do T.eq(out2[b], out[b], "payout, trial " .. trial) end
  end
end)

T.test("pari: extreme pool (30 bettors x 20g, 2e6 copper stakes) stays exact below 2^53", function()
  local bets = {}
  for i = 1, 30 do bets[i] = { bettor = "P" .. i, outcome = i <= 11 and 1 or 2, amount = 2000000, paid = true } end
  local out, _, dust = R.ComputePayouts(bets, 1, counted, 2)
  local want = reference(bets, 1)
  local sum = 0
  for i, b in ipairs(bets) do T.eq(out[b], want[i]); sum = sum + out[b] end
  T.eq(sum + dust, 60000000)
  -- worst case rem * amount: one huge winner vs 29 other bettors
  bets = { { bettor = "W", outcome = 1, amount = 1, paid = true } }
  for i = 2, 30 do bets[i] = { bettor = "L" .. i, outcome = 2, amount = 2000000, paid = true } end
  out = R.ComputePayouts(bets, 1, counted, 2)
  T.eq(out[bets[1]], 1 + 58000000, "one copper wins the whole losing pool")
end)

T.test("fixed odds: floor(amount*price/100) for the whole range, never below the stake, exact at 2e6*1000", function()
  for _ = 1, 3000 do
    local amount = rnd(1, 2000000)
    local price = rnd(101, 1000)
    local p = R.FixedPayout(amount, price)
    T.eq(p, math.floor(amount * price / 100))
    T.ok(p >= amount, "price >= 1.01 never pays less than the stake except by rounding of tiny stakes: " .. amount .. "@" .. price)
    T.ok(p == math.floor(p))
  end
  T.eq(R.FixedPayout(12345, 215), 26541, "contract F1")
  T.eq(R.FixedPayout(2000000, 1000), 20000000)
end)

T.test("mirror recompute (LocalPayout) equals the host's payout for every bettor, 300 random markets", function()
  local MK = MetaKit
  local mine = MK.CommKey()
  for trial = 1, 300 do
    local nOut = rnd(2, 8)
    local bets = randomBets(500000, nOut, rnd(1, 30))
    local r = rnd(1, nOut)
    local out = R.ComputePayouts(bets, r, counted, nOut)
    local pools, ns_ = {}, {}
    for k = 1, nOut do pools[k], ns_[k] = 0, 0 end
    for _, b in ipairs(bets) do
      ns_[b.outcome] = ns_[b.outcome] + 1
      if b.paid then pools[b.outcome] = pools[b.outcome] + b.amount end
    end
    for i, b in ipairs(bets) do
      local outcomes = {}
      for k = 1, nOut do outcomes[k] = { label = "o" .. k, pool = pools[k], n = ns_[k] } end
      local mirror = { v2 = true, isHost = false, currency = "gold", id = "abcd", host = "Host-Normal", status = "open",
        markets = { m1 = { mid = "m1", mode = "pari", status = "resolving", result = r, outcomes = outcomes,
          bets = { { bettor = mine, outcome = b.outcome, amount = b.amount, paid = b.paid, price = 0 } } } } }
      local got = R.LocalPayout("m1", mirror)
      T.eq(got, out[b], string.format("trial %d bet %d", trial, i))
    end
  end
end)

---------------------------------------------------------------------------
-- End to end through a hosted session

local function party(...)
  local names = { ... }
  T.group = { size = #names + 1, raid = false }
  for i = 1, 4 do T.units["party" .. i] = names[i] and { name = names[i], isPlayer = true } or nil end
end
local nonce = 0
local function r2b(sender, mid, idx, amount)
  nonce = nonce + 1
  T.Deliver("BSPT", table.concat({ "R2B", R.session.id, mid, idx, amount, 0, string.format("%04x", nonce) }, "\t"), "WHISPER", sender)
  T.Advance(2.1)
  for _, b in ipairs(R.Market(mid).bets) do if b.bettor == sender then return b end end
end
local function trade(partner, got)
  T.units.npc = { name = partner, isPlayer = true }
  T.Fire("TRADE_SHOW")
  T.trade.target, T.trade.player = got, 0
  T.Fire("TRADE_MONEY_CHANGED")
  T.Fire("TRADE_ACCEPT_UPDATE", 1, 1)
  T.Fire("TRADE_CLOSED")
  T.SetMoney(T.money + got)
  T.trade.target, T.trade.player = 0, 0
  T.Advance(1.1)
end

T.test("hosted markets (random bettors, paid and unpaid): m.dust, debts, settle row and bet rows obey conservation", function()
  for trial = 1, 25 do
    if R.session then R.Close(true) end
    T.Advance(60)
    R.last, ns.char.ring.last = nil, nil
    ns.char.ring.debts, ns.char.ring.unmatched = {}, {}
    party("Ann")
    local s = R.Open("ratchet")
    T.ok(R.SetFighters("Fa", "Fb"))
    local mk = R.AddMarket({ kind = "custom", labels = { "a", "b", "c", "d" }, open = true })
    local m = R.Market(mk.mid)
    local nb = rnd(1, 12)
    for i = 1, nb do
      local who = string.format("B%d_%d-Normal", trial, i)
      local amt = rnd(1, 50) * 10000 + (rnd(1, 3) == 1 and rnd(0, 9999) or 0)
      if amt > 500000 then amt = 500000 end
      local b = r2b(who, mk.mid, rnd(1, 4), amt)
      if b and rnd(1, 6) ~= 1 then trade(who:match("^[^-]+"), amt) end
    end
    local r = rnd(1, 4)
    local from = #A.db.outbox.rows
    T.ok(R.Verdict(mk.mid, r))
    T.Advance(601)
    T.eq(m.status, "settled")
    local want, total = reference(m.bets, r)
    local sum, owed = 0, 0
    for i, b in ipairs(m.bets) do
      T.eq(b.payout, want[i], "trial " .. trial)
      sum = sum + b.payout
    end
    T.eq(sum + m.dust, total, "referee keeps exactly the rounding remainder")
    for _, d in ipairs(R.Debts()) do owed = owed + d.amount end
    T.eq(owed, sum, "debts == payouts")
    local settle
    for i = from + 1, #A.db.outbox.rows do
      local row = A.db.outbox.rows[i]
      if row.kind == "ring" and row.data.ev == "settle" and row.data.mid == mk.mid then settle = row.data end
    end
    T.ok(settle, "settle row")
    T.eq(settle.dust, m.dust)
    local rowPool = 0
    for k = 1, 4 do rowPool = rowPool + settle.pools[k] end
    T.eq(rowPool, total, "settle row pools == counted stakes")
    local rowPay = 0
    for i = from + 1, #A.db.outbox.rows do
      local row = A.db.outbox.rows[i]
      if row.kind == "bet" and row.data.market == mk.mid then rowPay = rowPay + row.data.payout end
    end
    T.eq(rowPay, sum, "bet rows carry the same payouts")
  end
end)

T.noErrors()
T.done()
