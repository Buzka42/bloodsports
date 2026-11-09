-- Payout vectors (contract §8.1/§8.2): V1-V9 through Ring.ComputePayouts v2, V1-V4 through the v1 2-way path,
-- F1 through Ring.FixedPayout, and the §3.2 worked example (V5) end to end through wire bets on a bo3 score market.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 0 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 50 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, R = ns.A, ns.Ring
local FX = dofile("tests/fixtures/payout_vectors.lua")
A.db.config.referee.available = true
A.db.config.ring.currency = "gold"
T.money = 100000000

local function all() return true end

-- v2 bets { name, outcome, amount } in fixture order.
local function v2bets(vec)
  local bets = {}
  for i, st in ipairs(vec.stakes) do bets[i] = { name = st[1], outcome = st[2], amount = st[3] } end
  return bets
end

local function nOutcomes(vec)
  local n = 2
  for _, st in ipairs(vec.stakes) do if st[2] > n then n = st[2] end end
  return n
end

local function check(vec, bets, out, label)
  local sum = 0
  for _, b in ipairs(bets) do
    T.eq(out[b], vec.payouts[b.name], label .. " " .. vec.id .. " payout " .. b.name)
    sum = sum + out[b]
  end
  return sum
end

T.test("V1-V9: exact payouts, pools and dust through ComputePayouts v2", function()
  T.eq(#FX.pari, 9, "nine pari vectors")
  for _, vec in ipairs(FX.pari) do
    local bets = v2bets(vec)
    local out, P, dust = R.ComputePayouts(bets, vec.result, all, nOutcomes(vec))
    local sum = check(vec, bets, out, "v2")
    local total, pools = 0, {}
    for _, b in ipairs(bets) do
      total = total + b.amount
      pools[b.outcome] = (pools[b.outcome] or 0) + b.amount
    end
    for k, p in pairs(pools) do T.eq(P[k], p, vec.id .. " pool " .. k) end
    T.eq(dust, vec.dust, vec.id .. " dust")
    T.eq(total - sum, vec.dust, vec.id .. " dust = T - sum(payouts)")
  end
end)

T.test("remainder rule: dust is below 1 c per winning bet and independent of bet order", function()
  for _, vec in ipairs(FX.pari) do
    local bets = v2bets(vec)
    local _, P, dust = R.ComputePayouts(bets, vec.result, all, nOutcomes(vec))
    local winners = 0
    for _, b in ipairs(bets) do if vec.result and b.outcome == vec.result then winners = winners + 1 end end
    if vec.result and (P[vec.result] or 0) > 0 then
      T.ok(dust >= 0 and dust < winners, vec.id .. ": 0 <= dust < #winning bets")
    else
      T.eq(dust, 0, vec.id .. ": refunds leave no dust")
    end
    local rev = {}
    for i = #bets, 1, -1 do rev[#rev + 1] = bets[i] end
    local out2, _, dust2 = R.ComputePayouts(rev, vec.result, all, nOutcomes(vec))
    check(vec, rev, out2, "reversed")
    T.eq(dust2, vec.dust, vec.id .. " dust (reversed order)")
  end
end)

T.test("V1-V4 through the v1 2-way path (side a/b, winner side string)", function()
  for i = 1, 4 do
    local vec = FX.pari[i]
    local bets = {}
    for j, st in ipairs(vec.stakes) do bets[j] = { name = st[1], side = st[2] == 1 and "a" or "b", amount = st[3] } end
    local r = vec.result == 1 and "a" or "b"
    local out, pool = R.ComputePayouts(bets, r, all)
    check(vec, bets, out, "v1")
    local a, b = 0, 0
    for _, x in ipairs(bets) do if x.side == "a" then a = a + x.amount else b = b + x.amount end end
    T.eq(pool.a, a, vec.id .. " v1 pool a"); T.eq(pool.b, b, vec.id .. " v1 pool b")
  end
end)

T.test("§3.1: an uncounted (unpaid) stake neither enters the pool nor gets paid", function()
  local vec = FX.pari[1]
  local bets = v2bets(vec)
  local unpaid = { name = "C", outcome = 1, amount = 50000 }
  bets[#bets + 1] = unpaid
  local out, P, dust = R.ComputePayouts(bets, 1, function(b) return b ~= unpaid end, 2)
  T.eq(out[bets[1]], 400000, "A unchanged"); T.eq(out[bets[2]], 0)
  T.eq(out[unpaid], 0, "unpaid C gets nothing")
  T.eq(P[1], 100000, "C not in pool 1"); T.eq(dust, 0)
end)

T.test("F1: fixed payout floor(amount x price / 100), stake included", function()
  for _, f in ipairs(FX.fixed) do
    T.eq(R.FixedPayout(f.amount, f.price), f.payout, f.id)
  end
end)

-- §3.2 worked example on the wire: bo3 score market, gold, every stake paid by trade.
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
end

local function rowsSince(from, kind, ev)
  local out = {}
  for i = from + 1, #A.db.outbox.rows do
    local r = A.db.outbox.rows[i]
    if r.kind == kind and (not ev or r.data.ev == ev) then out[#out + 1] = r.data end
  end
  return out
end

T.test("V5 end to end: bo3 score market from wire bets settles to 344705 / 143627 with 1 c dust", function()
  T.group = { size = 0, raid = false }
  local s = R.Open("ratchet")
  T.ok(type(s) == "table" and s.public, "public host session")
  A:Fire("SERIES_START", { id = "s1", bo = 3, a = "Fa", b = "Fb" })
  local m = R.AddMarket({ kind = "score", open = true })
  T.ok(type(m) == "table", "score market")
  T.eq(m.mid, "m1"); T.eq(#m.outcomes, 4)
  T.eq(m.outcomes[1].label, "2-0"); T.eq(m.outcomes[4].label, "0-2")
  local vec = FX.pari[5]
  for i, st in ipairs(vec.stakes) do
    T.Deliver("BSPT", table.concat({ "R2B", s.id, "m1", st[2], st[3], 0, "n00" .. i }, "\t"), "WHISPER", st[1] .. "-Normal")
    T.Advance(2.1)
  end
  T.eq(#m.bets, 5, "five wire bets accepted")
  for _, st in ipairs(vec.stakes) do trade(st[1], st[3], 0) end
  for _, b in ipairs(m.bets) do T.ok(b.paid, b.bettor .. " paid") end
  local from = #A.db.outbox.rows
  A:Fire("SERIES_DONE", { id = "s1", winner = "Fa", scoreA = 2, scoreB = 0 })
  T.eq(m.status, "resolving", "auto verdict passes through resolving")
  T.eq(m.result, 1); T.ok(m.auto)
  local by = {}
  for _, b in ipairs(m.bets) do by[b.bettor] = b end
  for name, p in pairs(vec.payouts) do T.eq(by[name .. "-Normal"].payout, p, "provisional payout " .. name) end
  T.eq(m.dust, 1, "1 c dust to the referee")
  T.eq(#rowsSince(from, "bet"), 0, "no bet rows before settled")
  T.Advance(601)
  T.eq(m.status, "settled")
  local settle = rowsSince(from, "ring", "settle")
  T.eq(#settle, 1)
  T.eq(settle[1].dust, 1); T.eq(settle[1].result, 1); T.eq(settle[1].mode, "pari")
  T.eq(settle[1].pools[1], 170000); T.eq(settle[1].pools[2], 75000)
  T.eq(settle[1].pools[3], 33333); T.eq(settle[1].pools[4], 210000)
  local rows = rowsSince(from, "bet")
  T.eq(#rows, 5, "one bet row per bet")
  local rb = {}
  for _, r in ipairs(rows) do rb[r.bettor] = r end
  T.eq(rb["Ann-Normal"].payout, 344705); T.eq(rb["Ann-Normal"].result, "win")
  T.eq(rb["Bob-Normal"].payout, 143627); T.eq(rb["Bob-Normal"].result, "win")
  T.eq(rb["Eve-Normal"].payout, 0); T.eq(rb["Eve-Normal"].result, "loss")
  T.eq(rb["Ann-Normal"].outcomeCount, 4); T.eq(rb["Ann-Normal"].side, nil, "no side on a 4-outcome market")
  T.eq(rb["Ann-Normal"].series, "s1"); T.eq(rb["Ann-Normal"].bo, 3)
  local owed = {}
  for _, o in ipairs(R.Owed()) do owed[o.bettor] = o.amount end
  T.eq(owed["Ann-Normal"], 344705, "trade Ann 34g 47s 05c")
  T.eq(owed["Bob-Normal"], 143627)
  R.Close(true)
end)

T.noErrors()
T.done()
