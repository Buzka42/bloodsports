-- Hostile QA, Ring persistence: a FRESH lua5.1 process resumes a session written the way SavedVariables are written.
-- Cases: mid-open pari + fixed markets (pools, bets, liability, payouts identical after the reload, bank cap still
-- enforced), a disputed market (stays disputed past the old appeal window, flag + one-dispute-per-sender survive, times
-- out into a void with refunds), and the STALE_SEC boundary.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 0 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 50 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } } } }
local TOC = "Bloodsports/Bloodsports.toc"
local RESUME = arg and arg[1] == "--resume"
local ns, A, R

local function party(...)
  local names = { ... }
  T.group = { size = #names > 0 and #names + 1 or 0, raid = false }
  for i = 1, 4 do T.units["party" .. i] = names[i] and { name = names[i], isPlayer = true } or nil end
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
end

local nonce = 0
local function r2b(sender, mid, idx, amount, price)
  nonce = nonce + 1
  T.Deliver("BSPT", table.concat({ "R2B", R.session.id, mid, idx, amount, price or 0, string.format("%04x", nonce) }, "\t"),
    "WHISPER", sender)
  T.Advance(2.1)
  for _, b in ipairs(R.Market(mid).bets) do if b.bettor == sender then return b end end
end

local function betOf(m, who)
  for _, b in ipairs(m.bets) do if b.bettor == who then return b end end
end

local function rowsFor(sid, kind, ev)
  local out = {}
  for _, r in ipairs(A.db.outbox.rows) do
    if r.kind == kind and (not ev or r.data.ev == ev) and type(r.data.id) == "string" and r.data.id:sub(1, #sid) == sid then
      out[#out + 1] = r.data
    end
  end
  return out
end

-- Everything that must survive: per market, status/result/pools/n and per bet the money fields.
local function snapshot(s)
  local snap = {}
  for _, m in ipairs(R.Markets(s)) do
    local P, n = R.MarketPools(s, m)
    local e = { status = m.status, mode = m.mode, bank = m.bank, pools = P, n = n, bets = {}, liab = {} }
    for k = 1, #m.outcomes do e.liab[k] = m.mode == "fixed" and R.Liability(m.mid, k, s) or 0 end
    for _, b in ipairs(m.bets) do
      e.bets[b.bettor] = { outcome = b.outcome, amount = b.amount, price = b.price, paid = b.paid and 1 or 0, nonce = b.nonce }
    end
    snap[m.mid] = e
  end
  return snap
end

local function sameSnap(a, b, path)
  path = path or "snap"
  T.eq(type(a), type(b), path .. " type")
  if type(a) == "table" then
    for k, v in pairs(a) do sameSnap(v, b[k], path .. "." .. tostring(k)) end
    for k in pairs(b) do T.ok(a[k] ~= nil, path .. "." .. tostring(k) .. " missing after reload") end
  else
    T.eq(a, b, path)
  end
end

---------------------------------------------------------------------------
-- Resumed client

local CHILD = {}

CHILD.pools = { party = { "Alice", "Bob", "Carl", "Dina" }, run = function(X)
  T.test("mid-open reload: pools, counts, bets, fixed liability restored exactly (incl. unpaid bets)", function()
    local s = R.session
    T.ok(s and s.isHost and s.id == X.sid, "host session resumed")
    sameSnap(X.snap, snapshot(s))
    T.eq(R.Market("m1").status, "open"); T.eq(R.Market("m2").status, "open")
    T.eq(R.Market("m2").bank, X.snap.m2.bank)
  end)
  T.test("reload does not reopen the odds: bank cap still refuses an over-liability bet; a legal one is accepted", function()
    local b = r2b("Dina-Normal", "m2", 1, 500000, 180)
    T.eq(b, nil, "L1 + payout would exceed the bank")
    T.ok(r2b("Dina-Normal", "m2", 1, 10000, 180), "small bet fits")
    local n = #R.Market("m1").bets
    r2b("Alice-Normal", "m1", 2, 10000)
    T.eq(#R.Market("m1").bets, n, "Alice already has a bet in m1: still one bet per market after reload")
  end)
  T.test("verdict after the reload pays exactly what the parent computed before it; rows and debts once", function()
    local s = R.session
    -- Dina's extra fixed bet is unpaid: it must not change anything below
    T.ok(R.Verdict("m1", 1)); T.ok(R.Verdict("m2", 2))
    T.Advance(601)
    for who, want in pairs(X.pari) do T.eq(betOf(R.Market("m1"), who).payout, want, "m1 payout " .. who) end
    for who, want in pairs(X.fixed) do T.eq(betOf(R.Market("m2"), who).payout, want, "m2 payout " .. who) end
    T.eq(R.Market("m1").dust, X.dust)
    T.eq(#rowsFor(s.id, "bet"), 7, "one row per bet (unpaid included): 4 in m1, 3 in m2")
    local owed = 0
    for _, d in ipairs(R.Debts()) do owed = owed + d.amount end
    T.eq(owed, X.owed, "debts == payouts of counted bets")
  end)
end }

CHILD.disputed = { party = { "Alice", "Bob" }, run = function(X)
  T.test("disputed market survives a reload past the old appeal window; flag and one-per-sender intact", function()
    local m = R.Market("m1")
    T.eq(m.status, "disputed", "not settled by the resume tick")
    T.eq(m.dispute.by, "Bob-Normal")
    T.eq(#rowsFor(X.sid, "bet"), 0, "no bet rows while disputed")
    T.Deliver("BSPT", table.concat({ "R2D", X.sid, "m1", "foul", "again" }, "\t"), "WHISPER", "Bob-Normal")
    T.eq(#m.dispute.extra, 0, "Bob already disputed before the reload")
    trade("Alice", 0, 300000)
    T.eq(betOf(m, "Alice-Normal").paidOutAmount, 0, "no payout matches a disputed market after reload")
  end)
  T.test("dispute timeout is rebuilt from dispute.at: voids with refunds, never settles", function()
    local m = R.Market("m1")
    T.Advance(X.timeoutIn - 5)
    T.eq(m.status, "disputed", "5 s early")
    T.Advance(10)
    T.eq(m.status, "void"); T.eq(m.voidReason, "dispute"); T.eq(m.afterVerdict, true)
    T.eq(betOf(m, "Alice-Normal").payout, 100000); T.eq(betOf(m, "Bob-Normal").payout, 200000)
    T.eq(#rowsFor(X.sid, "ring", "dispute_resolved"), 1)
    T.Advance(1000)
    T.eq(m.status, "void")
  end)
end }

CHILD.boundary = { party = { "Alice" }, run = function(X)
  T.test("one second over STALE_SEC idle: every open market voids (stale), debts owe the paid stake, session closed", function()
    T.eq(R.session, nil, "no live session")
    local s = R.last
    T.ok(s and s.id == X.sid and s.status == "closed", "closed session kept")
    local m = R.Market("m1", s)
    T.eq(m.status, "void"); T.eq(m.voidReason, "stale")
    T.eq(betOf(m, "Alice-Normal").payout, 100000)
    T.eq(#R.Owed(), 1)
  end)
end }

CHILD.fresh = { party = { "Alice" }, run = function(X)
  T.test("exactly STALE_SEC idle still resumes (contract: <= STALE_SEC); the open market is past OPEN_MAX_SEC so it locks", function()
    local s = R.session
    T.ok(s and s.id == X.sid, "live")
    T.eq(R.Market("m1").status, "locked", "locked by the OPEN_MAX_SEC timer on resume, not voided")
    T.eq(betOf(R.Market("m1"), "Alice-Normal").paid, true)
  end)
end }

if RESUME then
  local case, path, at = arg[2], arg[3], tonumber(arg[4])
  local db, X = dofile(path)
  T.serverBase = at - math.floor(T.clock)
  party(unpack(CHILD[case].party))
  ns = T.LoadAddon(TOC, { saved = { BloodsportsDB = db } })
  A, R = ns.A, ns.Ring
  T.money = 100000000
  CHILD[case].run(X)
  T.noErrors()
  T.done()
end

---------------------------------------------------------------------------
-- Parent

ns = T.LoadAddon(TOC)
A, R = ns.A, ns.Ring
A.db.config.referee.available = true
T.money = 100000000

local function serialize(v, out, seen)
  local t = type(v)
  if t == "number" then out[#out + 1] = string.format("%.17g", v)
  elseif t == "string" then out[#out + 1] = string.format("%q", v)
  elseif t == "boolean" then out[#out + 1] = tostring(v)
  elseif t == "table" then
    assert(not seen[v], "cycle in SavedVariables")
    seen[v] = true
    out[#out + 1] = "{"
    for k, x in pairs(v) do
      local kt, xt = type(k), type(x)
      if (kt == "string" or kt == "number") and (xt == "table" or xt == "string" or xt == "number" or xt == "boolean") then
        out[#out + 1] = "["; serialize(k, out, seen); out[#out + 1] = "]="; serialize(x, out, seen); out[#out + 1] = ","
      end
    end
    out[#out + 1] = "}"
    seen[v] = nil
  else
    out[#out + 1] = "nil"
  end
end

local function reload(case, delta, expected, X)
  local dir = os.getenv("TMPDIR") or "/tmp"
  local path = string.format("%s/bs_hostile_%s_%d.lua", dir, case, os.time())
  local out = { "return " }
  serialize(BloodsportsDB, out, {})
  out[#out + 1] = ", "
  serialize(X or {}, out, {})
  local f = assert(io.open(path, "w"))
  f:write(table.concat(out))
  f:close()
  local cmd = string.format("lua5.1 %q --resume %s %q %.0f 2>&1", arg[0], case, path, GetServerTime() + delta)
  local p = assert(io.popen(cmd))
  local text = p:read("*a")
  p:close()
  os.remove(path)
  local passed, failed = text:match("(%d+) passed, (%d+) failed")
  for line in text:gmatch("[^\n]+") do
    if not line:match("^%d+ passed, %d+ failed$") then io.write("    resumed| ", line, "\n") end
  end
  T.eq(tonumber(failed), 0, case .. ": resumed client failures")
  T.eq(tonumber(passed), expected, case .. ": resumed client checks run")
end

local function fresh()
  if R.session then if R.IsHost() then R.Close(true) else R.Leave() end end
  T.Advance(60)
  R.last, ns.char.ring.last = nil, nil
  ns.char.ring.debts, ns.char.ring.unmatched = {}, {}
  ns.char.bets, ns.char.trades = {}, {}
  A.db.config.ring.currency = "gold"
end

T.test("reload mid-open: pari + fixed markets with paid and unpaid bets restore exactly and settle identically", function()
  fresh()
  party("Alice", "Bob", "Carl", "Dina")
  local s = R.Open("ratchet")
  T.ok(R.SetFighters("Fa", "Fb"))
  local m2 = R.AddMarket({ kind = "winner", mode = "fixed", prices = { 180, 210 }, bank = 250000 })
  T.ok(R.OpenMarket(m2.mid))
  T.ok(r2b("Alice-Normal", "m1", 1, 123457)); trade("Alice", 123457, 0)
  T.ok(r2b("Bob-Normal", "m1", 2, 77777)); trade("Bob", 77777, 0)
  T.ok(r2b("Carl-Normal", "m1", 1, 31111)) -- unpaid
  T.ok(r2b("Dina-Normal", "m1", 2, 10000)); trade("Dina", 10000, 0)
  T.ok(r2b("Carl-Normal", "m2", 1, 200000, 180)); trade("Carl", 200000, 0)
  T.ok(r2b("Bob-Normal", "m2", 2, 300000, 210)); trade("Bob", 300000, 0)
  -- expected, computed before the reload with the pure function
  local m1 = R.Market("m1")
  local out, _, dust = R.ComputePayouts(m1.bets, 1, function(b) return b.paid end, 2)
  local pari = {}
  for _, b in ipairs(m1.bets) do pari[b.bettor] = out[b] end
  local fixed = { ["Carl-Normal"] = 0, ["Bob-Normal"] = R.FixedPayout(300000, 210) }
  local owed = 0
  for _, v in pairs(pari) do owed = owed + v end
  for _, v in pairs(fixed) do owed = owed + v end
  local snap = snapshot(s)
  T.ok(snap.m1.pools[1] == 123457 and snap.m1.n[1] == 2, "unpaid bet counted in n, not in the pool")
  reload("pools", 90, 3, { sid = s.id, snap = snap, pari = pari, fixed = fixed, dust = dust, owed = owed })
end)

T.test("reload while disputed, 28 min later: still disputed, then auto-void at dispute.at + 1800", function()
  fresh()
  party("Alice", "Bob")
  local s = R.Open("ratchet")
  T.ok(R.SetFighters("Fa", "Fb"))
  T.ok(r2b("Alice-Normal", "m1", 1, 100000)); trade("Alice", 100000, 0)
  T.ok(r2b("Bob-Normal", "m1", 2, 200000)); trade("Bob", 200000, 0)
  T.ok(R.Verdict("m1", 1))
  T.Advance(30)
  T.Deliver("BSPT", table.concat({ "R2D", s.id, "m1", "wrong", "Fb won" }, "\t"), "WHISPER", "Bob-Normal")
  local m = R.Market("m1")
  T.eq(m.status, "disputed")
  -- reload 1700 s after the dispute (well past appealUntil = verdict + 600); the 1800 s timeout is 100 s further
  reload("disputed", 1700, 2, { sid = s.id, timeoutIn = 100 })
end)

T.test("reload at exactly STALE_SEC (resumes) and one second over it (stale void)", function()
  fresh()
  party("Alice")
  local s = R.Open("ratchet")
  T.ok(R.SetFighters("Fa", "Fb"))
  T.ok(r2b("Alice-Normal", "m1", 1, 100000)); trade("Alice", 100000, 0)
  local idle = GetServerTime() - s.lastActivity
  reload("boundary", R.C.STALE_SEC - idle + 1, 1, { sid = s.id })
  reload("fresh", R.C.STALE_SEC - idle, 1, { sid = s.id })
end)

T.done()
