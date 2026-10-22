-- Ring bands: gold cap clamp (1 g to 50 g), 1 g minimum, bookie-level bands checked by the bettor and the host,
-- and the "bet" outbox rows written at settlement.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 5 end
UnitIsGroupLeader = function() return T.leader ~= false end
WorldOfMetaData = { bloodsports = { referees = {}, bookies = {} } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, R = ns.A, ns.Ring
A.db.config.referee.available = true
A.db.config.ring.currency = "gold"

local function deliver(sender, text, channel) T.Deliver("BSPT", text, channel or "WHISPER", sender) end
local function bet(sender, on, amount, id)
  deliver(sender, table.concat({ "RB", id or R.session.id, on, amount }, "\t"))
end
local function party(...)
  local names = { ... }
  T.group = { size = #names + 1, raid = false }
  for i = 1, 4 do T.units["party" .. i] = names[i] and { name = names[i], isPlayer = true } or nil end
end
local function trade(partner, got, gave)
  T.units.npc = { name = partner, isPlayer = true }
  T.Fire("TRADE_SHOW")
  T.trade.target, T.trade.player = got, gave
  T.Fire("TRADE_ACCEPT_UPDATE", 1, 1)
  local d = got - gave
  if d ~= 0 then T.SetMoney(T.money + d) end
  T.Fire("TRADE_CLOSED")
  T.trade.target, T.trade.player = 0, 0
  T.Advance(1.5)
end
local function setCap(cap) WorldOfMetaData.bloodsports.referees = { ["Tester-Normal"] = { cap = cap } } end
local function setBookie(name, level) WorldOfMetaData.bloodsports.bookies[name] = level and { level = level } or nil end
local function mark() return #A.db.outbox.rows end
local function betRows(from)
  local out = {}
  local rows = A.db.outbox.rows
  for i = from + 1, #rows do
    if rows[i].kind == "bet" then out[#out + 1] = rows[i].data end
  end
  return out
end
-- Joins a session hosted by Host-Normal (bettor side). The RS line carries the host's cap.
local function mirror(id, cap)
  party("Host")
  deliver("Host-Normal", table.concat({ "RS", id, "open", "ratchet", "gold", "Fa-Normal", "Fb-Normal", "0", "0", "0", "",
    cap or "500000" }, "\t"), "PARTY")
  return R.session
end

T.money = 10000000 -- 1000 g

T.test("gold cap clamps to 1 g .. 50 g; no site cap = 50 g", function()
  for _, c in ipairs({ { 100, 500000 }, { 50, 500000 }, { 25, 250000 }, { 1, 10000 }, { 0.5, 10000 }, { 0, 500000 } }) do
    setCap(c[1])
    local s = R.Open("ratchet")
    T.eq(s.cap, c[2], "site cap " .. c[1] .. " g")
    R.Close()
  end
  WorldOfMetaData.bloodsports.referees = nil
  local s = R.Open("ratchet")
  T.eq(s.cap, 500000, "no site cap")
  R.Close()
end)

T.test("mirror takes the host's cap but never above 50 g", function()
  local s = mirror("abc002", "9999999")
  T.eq(s.cap, 500000)
  R.Leave()
end)

T.test("bettor refuses under 1 g and accepts exactly 1 g", function()
  setBookie("Host-Normal", 5)
  mirror("abc001")
  local ok, why = R.PlaceBet("Fa", 9999)
  T.ok(not ok); T.eq(why, "amount", "0.9999 g refused")
  ok, why = R.PlaceBet("Fa", 0)
  T.eq(why, "amount")
  T.ok(R.PlaceBet("Fa", 10000), "1 g accepted")
  R.Leave()
end)

T.test("Ring.Band: level L takes up to 10*L gold; no entry is level 1", function()
  setBookie("Host-Normal", nil)
  local lv, max = R.Band("Host-Normal")
  T.eq(lv, 1); T.eq(max, 100000, "no entry: 10 g")
  setBookie("Host-Normal", 3)
  lv, max = R.Band("Host-Normal")
  T.eq(lv, 3); T.eq(max, 300000)
  setBookie("Host-Normal", 9)
  lv, max = R.Band("Host-Normal")
  T.eq(lv, 5, "clamped to level 5"); T.eq(max, 500000)
  setBookie("Host-Normal", 0)
  lv = R.Band("Host-Normal")
  T.eq(lv, 1, "clamped to level 1")
  setBookie("Host-Normal", nil)
end)

T.test("bettor band: an 11 g bet is refused at level 1 and accepted at level 2", function()
  mirror("abc003")
  setBookie("Host-Normal", 1)
  local ok, why = R.PlaceBet("Fa", 110000)
  T.ok(not ok); T.eq(why, "band", "11 g at level 1")
  ok = R.PlaceBet("Fa", 100000)
  T.ok(ok, "10 g at level 1 is in band")
  setBookie("Host-Normal", 2)
  T.ok(R.PlaceBet("Fa", 110000), "11 g at level 2")
  R.Leave()
end)

T.test("bettor band: each level takes its own top band; level 5 takes 50 g", function()
  mirror("abc004")
  for lv = 1, 5 do
    setBookie("Host-Normal", lv)
    T.ok(R.PlaceBet("Fa", lv * 100000), "top of band " .. lv)
    if lv < 5 then
      local ok, why = R.PlaceBet("Fa", lv * 100000 + 10000)
      T.ok(not ok); T.eq(why, "band", "one gold over band " .. lv)
    end
  end
  R.Leave()
end)

T.test("host refuses an over-band or under-minimum bet even when the bettor's client sent it", function()
  setBookie("Tester-Normal", 1)
  setCap(100)
  party("Alice", "Bob", "Carl")
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb")
  bet("Alice-Normal", "Fa", "110000")  -- 11 g at level 1: refused
  bet("Bob-Normal", "Fa", "5000")      -- 0.5 g: refused
  T.eq(#s.bets, 0, "both refused")
  bet("Alice-Normal", "Fa", "100000")  -- 10 g: accepted
  T.eq(#s.bets, 1)
  setBookie("Tester-Normal", 2)
  bet("Bob-Normal", "Fb", "110000")    -- 11 g at level 2: accepted
  T.eq(#s.bets, 2)
  R.Close()
  setBookie("Tester-Normal", nil)
end)

T.test("void settlement emits one 'void' bet row per gold bet (host)", function()
  setBookie("Tester-Normal", 5)
  party("Alice", "Bob")
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb")
  bet("Alice-Normal", "Fa", "100000")
  bet("Bob-Normal", "Fb", "200000")
  local from = mark()
  T.ok(R.Void())
  local rows = betRows(from)
  T.eq(#rows, 2, "one row per bet")
  for _, r in ipairs(rows) do T.eq(r.result, "void") end
  T.eq(rows[1].bettor, "Alice-Normal"); T.eq(rows[2].bettor, "Bob-Normal")
  T.eq(rows[1].id, s.id)
  R.Close()
end)

T.test("win and loss: host emits a row per bet; unpaid gold bet is void", function()
  setBookie("Tester-Normal", 5)
  party("Alice", "Bob", "Carl")
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb")
  bet("Alice-Normal", "Fa", "100000")
  bet("Bob-Normal", "Fb", "200000")
  bet("Carl-Normal", "Fb", "50000")
  trade("Alice", 100000, 0)
  trade("Bob", 200000, 0)              -- Carl never pays
  local from = mark()
  T.ok(R.Verdict("Fa"))
  local rows = betRows(from)
  T.eq(#rows, 3)
  local by = {}
  for _, r in ipairs(rows) do by[r.bettor] = r end
  T.eq(by["Alice-Normal"].result, "win"); T.eq(by["Alice-Normal"].side, "a")
  T.eq(by["Bob-Normal"].result, "loss"); T.eq(by["Bob-Normal"].side, "b")
  T.eq(by["Carl-Normal"].result, "void")
  for _, r in ipairs(rows) do
    T.eq(r.bookie, "Tester-Normal"); T.eq(r.id, s.id); T.eq(r.venue, "ratchet")
  end
  R.Close()
  setBookie("Tester-Normal", nil)
end)

T.test("bet row fields are present and typed; no venue gives nil", function()
  setBookie("Tester-Normal", 5)
  party("Alice")
  local s = R.Open("")
  R.SetFighters("Fa", "Fb")
  bet("Alice-Normal", "Fa", "100000")
  trade("Alice", 100000, 0)
  local from = mark()
  T.ok(R.Verdict("Fa"))
  local rows = betRows(from)
  T.eq(#rows, 1)
  local r = rows[1]
  T.ok(type(r.id) == "string" and r.id:match("^%x+$") and r.id == s.id, "id is the session id")
  T.ok(type(r.bettor) == "string" and r.bettor:find("-", 1, true), "bettor is Name-Realm")
  T.ok(type(r.bookie) == "string" and r.bookie == "Tester-Normal", "bookie is the host Name-Realm")
  T.ok(type(r.amount) == "number" and r.amount == math.floor(r.amount) and r.amount == 100000, "amount is integer copper")
  T.ok(r.side == "a" or r.side == "b", "side a or b")
  T.ok(r.result == "win" or r.result == "loss" or r.result == "void", "result")
  T.eq(r.venue, nil, "no venue -> nil")
  T.ok(type(r.t) == "number", "t is a number")
  local n = 0
  for _ in pairs(r) do n = n + 1 end
  T.eq(n, 7, "venue absent when nil; seven fields")
  R.Close()
  setBookie("Tester-Normal", nil)
end)

T.test("points sessions emit no bet rows", function()
  A.db.config.ring.currency = "points"
  setBookie("Tester-Normal", 5)
  party("Alice")
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb")
  bet("Alice-Normal", "Fa", "5")
  local from = mark()
  T.ok(R.Verdict("Fa"))
  T.eq(#betRows(from), 0)
  T.eq(s.status, "settled")
  R.Close()
  setBookie("Tester-Normal", nil)
  A.db.config.ring.currency = "gold"
end)

T.test("bettor emits one row for its own bet: win, then loss on another session", function()
  setBookie("Host-Normal", 5)
  mirror("abc005")
  local from = mark()
  deliver("Host-Normal", "RL\tabc005\tTester-Normal\tFa-Normal\t100000\t1\t0\t0", "PARTY")
  deliver("Host-Normal", "RS\tabc005\tsettled\tratchet\tgold\tFa-Normal\tFb-Normal\t100000\t0\t1\tFa-Normal\t500000", "PARTY")
  local rows = betRows(from)
  T.eq(#rows, 1, "one row for my bet")
  T.eq(rows[1].bettor, "Tester-Normal"); T.eq(rows[1].bookie, "Host-Normal")
  T.eq(rows[1].result, "win"); T.eq(rows[1].side, "a"); T.eq(rows[1].amount, 100000)
  T.eq(rows[1].venue, "ratchet"); T.eq(rows[1].id, "abc005")
  -- a repeated settled line (rebroadcast) does not emit again
  deliver("Host-Normal", "RS\tabc005\tsettled\tratchet\tgold\tFa-Normal\tFb-Normal\t100000\t0\t1\tFa-Normal\t500000", "PARTY")
  T.eq(#betRows(from), 1, "no duplicate on rebroadcast")
  R.Leave()

  from = mark()
  mirror("abc006")
  deliver("Host-Normal", "RL\tabc006\tTester-Normal\tFa-Normal\t100000\t1\t0\t0", "PARTY")
  deliver("Host-Normal", "RS\tabc006\tsettled\tratchet\tgold\tFa-Normal\tFb-Normal\t100000\t50000\t2\tFb-Normal\t500000", "PARTY")
  rows = betRows(from)
  T.eq(#rows, 1); T.eq(rows[1].result, "loss"); T.eq(rows[1].side, "a")
  R.Leave()
  setBookie("Host-Normal", nil)
end)

T.noErrors()
T.done()
