-- Persistence / resume (contract §1.6, §8.2). A /reload is simulated faithfully: the parent writes BloodsportsDB the
-- way SavedVariables do (plain data, no metatables, shared tables duplicated) and a FRESH lua5.1 process loads the
-- addon from that file with the server clock moved on. Cases: host reload while open (session, bets, rev, timers;
-- bets still accepted); reload during `resolving` past appealUntil (settles on login, bet rows once); > STALE_SEC
-- (void + close); mirror reload (R2Q resync, host offline after 60 s); v1 + v2 records in PointsBalance.
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

local function fields(m)
  local f = {}
  for p in (m.msg .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = p end
  table.remove(f, 1)
  return f
end

local function sent(typ, pred)
  local out = {}
  for _, m in ipairs(T.sent) do
    if m.msg:sub(1, #typ + 1) == typ .. "\t" and (not pred or pred(m)) then out[#out + 1] = fields(m) end
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
end

local nonce = 0
local function r2b(sender, mid, idx, amount)
  nonce = nonce + 1
  T.Deliver("BSPT", table.concat({ "R2B", R.session.id, mid, idx, amount, 0, string.format("%04x", nonce) }, "\t"),
    "WHISPER", sender)
  T.Advance(2.1)
  for _, b in ipairs(R.Market(mid).bets) do if b.bettor == sender then return b end end
end

-- Outbox rows of `kind` (and ring event `ev`) for session `sid`.
local function rowsFor(sid, kind, ev)
  local out = {}
  for _, r in ipairs(A.db.outbox.rows) do
    if r.kind == kind and (not ev or r.data.ev == ev) and type(r.data.id) == "string" and r.data.id:sub(1, #sid) == sid then
      out[#out + 1] = r.data
    end
  end
  return out
end

local function betOf(m, who)
  for _, b in ipairs(m.bets) do if b.bettor == who then return b end end
end

---------------------------------------------------------------------------
-- Resumed client (child process): each case declares its group before login and its checks after it.

local CHILD = {}

CHILD.open = { party = { "Alice", "Bob", "Carl" }, run = function(X)
  T.test("resumed host: session, bets and rev restored, write-through into SavedVariables", function()
    local s = R.session
    T.ok(s and s.isHost and R.IsHost(), "host session resumed")
    T.eq(s.id, X.sid); T.eq(s.rev, X.rev); T.eq(s.status, "open")
    T.ok(rawequal(s, ns.char.ring.session), "Ring.session points into BloodsportsDB")
    local m1 = R.Market("m1")
    T.eq(m1.status, "open"); T.eq(#m1.bets, 2); T.eq(#s.bets, 2, "v1 view rebuilt (metatable)")
    T.eq(betOf(m1, "Alice-Normal").paid, true); T.eq(betOf(m1, "Bob-Normal").paid, false)
    T.eq(betOf(m1, "Alice-Normal").amount, 100000)
    T.eq(R.Market("m2").status, "open"); T.eq(R.Market("m2").lockAt, X.lockAt)
  end)
  T.test("resumed host re-broadcasts its state", function()
    T.Advance(2)
    local rs = sent("R2S", function(m) return m.channel == "PARTY" end)
    T.ok(#rs >= 1, "R2S after resume"); T.eq(rs[#rs][2], X.sid); T.eq(rs[#rs][10], tostring(X.rev))
  end)
  T.test("resumed host still accepts bets and matches stake trades", function()
    local s = R.session
    T.ok(r2b("Carl-Normal", "m1", 1, 50000), "new bet after reload")
    T.ok(s.rev > X.rev, "rev keeps counting up")
    trade("Bob", 200000, 0)
    T.eq(betOf(R.Market("m1"), "Bob-Normal").paid, true, "Bob's stake matched after reload")
  end)
  T.test("timers are rebuilt from timestamps: lockAt and the appeal window", function()
    local m2 = R.Market("m2")
    local left = X.lockAt - GetServerTime()
    T.ok(left > 5, "lockAt still ahead")
    T.Advance(left - 2)
    T.eq(m2.status, "open", "before lockAt")
    T.Advance(3)
    T.eq(m2.status, "locked", "lockAt reached after the reload")
    T.ok(R.Verdict("m1", 1))
    T.Advance(599)
    T.eq(R.Market("m1").status, "resolving")
    T.Advance(2)
    T.eq(R.Market("m1").status, "settled")
  end)
end }

local function resolvingChecks(X)
  local m1 = R.Market("m1")
  T.eq(m1.status, "settled", "appealUntil passed while offline: settled at login")
  T.eq(#rowsFor(X.sid, "bet"), 2, "one bet row per bet")
  T.eq(#rowsFor(X.sid, "ring", "settle"), 1)
  T.eq(betOf(m1, "Alice-Normal").payout, 30); T.eq(betOf(m1, "Alice-Normal").paidOut, true)
  T.eq(betOf(m1, "Bob-Normal").payout, 0)
end

CHILD.resolving = { party = { "Alice", "Bob" }, run = function(X)
  T.test("reload during resolving past appealUntil settles on login; outbox rows once", function()
    T.ok(R.session and R.session.id == X.sid, "resumed (within STALE_SEC)")
    resolvingChecks(X)
    T.Advance(30)
    T.eq(#rowsFor(X.sid, "bet"), 2, "no second set of bet rows")
    T.eq(#rowsFor(X.sid, "ring", "settle"), 1)
  end)
end }

CHILD.resolving_early = { party = { "Alice", "Bob" }, run = function(X)
  T.test("reload inside the appeal window keeps resolving and settles at appealUntil", function()
    local m1 = R.Market("m1")
    T.eq(m1.status, "resolving")
    T.eq(#rowsFor(X.sid, "bet"), 0)
    T.Advance(X.appealUntil - GetServerTime() - 1)
    T.eq(m1.status, "resolving", "one second before appealUntil")
    T.Advance(2)
    resolvingChecks(X)
  end)
end }

CHILD.stale = { party = { "Alice", "Bob" }, run = function(X)
  T.test("older than STALE_SEC: non-final markets void (stale), the session closes", function()
    T.eq(R.session, nil, "no live session")
    T.eq(ns.char.ring.session, nil)
    local s = R.last
    T.ok(s and s.id == X.sid, "kept as the last session")
    T.eq(s.status, "closed")
    T.eq(R.Market("m1", s).status, "void"); T.eq(R.Market("m1", s).voidReason, "stale")
    T.eq(R.Market("m3", s).status, "void"); T.eq(R.Market("m3", s).voidReason, "stale")
    T.eq(R.Market("m2", s).status, "settled", "final markets untouched")
    T.eq(betOf(R.Market("m1", s), "Alice-Normal").payout, 100000, "paid stake refunded")
    T.eq(betOf(R.Market("m1", s), "Bob-Normal").payout, 0, "unpaid stake: nothing")
    local voids = rowsFor(X.sid, "ring", "void")
    T.eq(#voids, 2)
    for _, v in ipairs(voids) do T.eq(v.reason, "stale") end
    T.eq(#rowsFor(X.sid, "ring", "close"), 1)
    local owed = R.Owed()
    T.eq(#owed, 1); T.eq(owed[1].bettor, "Alice-Normal"); T.eq(owed[1].amount, 100000)
    local debt
    for _, d in ipairs(R.Debts()) do if d.id == X.sid .. ".m1" then debt = d end end
    T.ok(debt and debt.status == "due" and debt.amount == 100000, "refund owed as a debt")
  end)
  T.test("after the stale close, a payout trade matches the last session's refund (§6: live, last, debts)", function()
    local b = betOf(R.Market("m1", R.last), "Alice-Normal")
    trade("Alice", 0, 100000)
    local tr = ns.char.trades[#ns.char.trades]
    T.eq(tr.kind, "payout"); T.eq(#tr.matched, 1); T.eq(tr.reason, nil)
    T.eq(b.paidOut, true); T.eq(b.paidOutAmount, 100000)
    local debt
    for _, d in ipairs(R.Debts()) do if d.id == X.sid .. ".m1" then debt = d end end
    T.eq(debt.status, "cleared"); T.eq(debt.paid, 100000)
    T.eq(#R.Owed(), 0)
  end)
end }

CHILD.mirror = { party = { "Host" }, run = function(X)
  T.test("mirror resumes as rejoining and sends R2Q(sid, 0) to the host", function()
    local s = R.session
    T.ok(s and not s.isHost, "mirror resumed")
    T.eq(s.id, X.sid); T.eq(s.rejoining, true)
    T.eq(R.MyBet("m1").amount, 100000)
    T.Advance(1)
    local q = sent("R2Q", function(m) return m.channel == "WHISPER" and m.target == "Host-Normal" end)
    T.eq(#q, 1); T.eq(q[1][1], X.sid); T.eq(q[1][2], "0")
  end)
  T.test("no reply in 60 s: host offline, record kept", function()
    T.Advance(58)
    T.ok(not R.session.hostOffline, "not before 60 s")
    T.Advance(2)
    T.eq(R.session.hostOffline, true)
    T.eq(R.session.id, X.sid); T.eq(R.MyBet("m1").amount, 100000)
  end)
  T.test("the host's reply clears rejoining", function()
    T.Deliver("BSPT", table.concat({ "R2S", 2, X.sid, "open", "ratchet", "gold", 500000, "", 0, 1, 5, "100" }, "\t"),
      "PARTY", "Host-Normal")
    T.eq(R.session.rejoining, nil); T.eq(R.session.hostOffline, nil); T.eq(R.session.rev, 5)
  end)
end }

CHILD.balance = { party = {}, run = function(X)
  T.test("PointsBalance reads v1 and v2 bettor records after a reload", function()
    T.eq(R.PointsBalance(), X.balance)
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
-- Parent: build state, write SavedVariables, run the resumed client.

ns = T.LoadAddon(TOC)
A, R = ns.A, ns.Ring
A.db.config.referee.available = true
T.money = 100000000

-- SavedVariables writer: plain data only (functions and metatables dropped); a cycle is an error.
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
  local path = string.format("%s/bs_persist_%s_%d.lua", dir, case, os.time())
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

local function fresh(currency)
  if R.session then if R.IsHost() then R.Close(true) else R.Leave() end end
  T.Advance(60)
  R.last, ns.char.ring.last = nil, nil
  ns.char.ring.debts, ns.char.ring.unmatched = {}, {}
  A.db.config.ring.currency = currency
end

T.test("host /reload while open", function()
  fresh("gold")
  party("Alice", "Bob", "Carl")
  local s = R.Open("ratchet")
  T.ok(R.SetFighters("Fa", "Fb"))
  T.ok(r2b("Alice-Normal", "m1", 1, 100000)); trade("Alice", 100000, 0)
  T.ok(r2b("Bob-Normal", "m1", 2, 200000))
  local m2 = R.AddMarket({ kind = "custom", labels = { "yes", "no" }, lockOn = "time", lockAt = GetServerTime() + 300, open = true })
  T.ok(m2, "time-locked market")
  T.Advance(5)
  reload("open", 60, 4, { sid = s.id, rev = s.rev, lockAt = m2.lockAt })
end)

T.test("reload during resolving, past appealUntil", function()
  fresh("points")
  party("Alice", "Bob")
  local s = R.Open("ratchet")
  T.ok(R.SetFighters("Fa", "Fb"))
  T.ok(r2b("Alice-Normal", "m1", 1, 10)); T.ok(r2b("Bob-Normal", "m1", 2, 20))
  T.ok(R.Verdict("Fa"))
  T.eq(#rowsFor(s.id, "bet"), 0, "no rows before settle")
  reload("resolving", 700, 1, { sid = s.id })
end)

T.test("reload during resolving, inside the appeal window", function()
  fresh("points")
  party("Alice", "Bob")
  local s = R.Open("ratchet")
  T.ok(R.SetFighters("Fa", "Fb"))
  T.ok(r2b("Alice-Normal", "m1", 1, 10)); T.ok(r2b("Bob-Normal", "m1", 2, 20))
  T.ok(R.Verdict("Fa"))
  reload("resolving_early", 100, 1, { sid = s.id, appealUntil = R.Market("m1").appealUntil })
end)

T.test("reload after more than STALE_SEC", function()
  fresh("gold")
  party("Alice", "Bob")
  local s = R.Open("ratchet")
  T.ok(R.SetFighters("Fa", "Fb"))
  local m2 = R.AddMarket({ kind = "custom", labels = { "yes", "no" }, open = true })
  T.ok(r2b("Alice-Normal", "m1", 1, 100000)); trade("Alice", 100000, 0)
  T.ok(r2b("Bob-Normal", "m1", 2, 200000))
  T.ok(R.Verdict(m2.mid, 1)); T.Advance(601)
  T.eq(m2.status, "settled", "m2 final before the reload")
  T.ok(R.Lock("m1"))
  local m3 = R.AddMarket({ kind = "custom", labels = { "yes", "no" }, open = true })
  T.eq(m2.mid, "m2"); T.eq(m3.mid, "m3")
  reload("stale", 7201, 2, { sid = s.id })
end)

T.test("mirror /reload", function()
  fresh("gold")
  party("Host")
  local sid = "abc888"
  T.Deliver("BSPT", table.concat({ "R2S", 2, sid, "open", "ratchet", "gold", 500000, "", 0, 1, 1, "100" }, "\t"), "PARTY", "Host-Normal")
  T.Deliver("BSPT", table.concat({ "R2M", sid, "m1", "winner", "fight", "pari", "open", 2, 0, 0, 0, 0, 0, 1, "Winner" }, "\t"), "PARTY", "Host-Normal")
  T.Deliver("BSPT", table.concat({ "R2O", sid, "m1", 1, "Fa", 100000, 1, 0 }, "\t"), "PARTY", "Host-Normal")
  T.Deliver("BSPT", table.concat({ "R2O", sid, "m1", 2, "Fb", 0, 0, 0 }, "\t"), "PARTY", "Host-Normal")
  T.Deliver("BSPT", table.concat({ "R2L", sid, "m1", "Tester-Normal", 1, 100000, 0, "100", 0, 0, 1 }, "\t"), "PARTY", "Host-Normal")
  T.ok(R.session and not R.session.isHost and R.MyBet("m1"), "mirror with my bet")
  T.ok(rawequal(ns.char.ring.session, R.session), "mirror persisted")
  reload("mirror", 30, 3, { sid = sid })
end)

T.test("v1 and v2 records in PointsBalance survive a reload", function()
  fresh("points")
  party()
  local bets = ns.char.bets
  for i = #bets, 1, -1 do bets[i] = nil end
  bets[#bets + 1] = { role = "bettor", currency = "points", status = "settled", bet = { amount = 100, payout = 250 } }
  bets[#bets + 1] = { role = "bettor", currency = "points", status = "settled", bet = { amount = 40, payout = 0 } }
  bets[#bets + 1] = { role = "bettor", currency = "gold", status = "settled", bet = { amount = 10000, payout = 20000 } }
  bets[#bets + 1] = { v = 2, id = "abc1", role = "bettor", currency = "points", markets = {
    m1 = { status = "settled", bet = { amount = 10, payout = 30 } },
    m2 = { status = "void", bet = { amount = 5, payout = 5 } },
    m3 = { status = "resolving", bet = { amount = 7 } },
  } }
  bets[#bets + 1] = { v = 2, id = "abc2", role = "host", currency = "points", markets = {} }
  -- (250 - 100) + (0 - 40) + (30 - 10) + (5 - 5); gold, host and non-final entries do not count
  T.eq(R.PointsBalance(), 130)
  reload("balance", 10, 1, { balance = 130 })
end)

T.noErrors()
T.done()
