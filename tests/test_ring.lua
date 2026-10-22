-- Ring: host session lifecycle, bets, trade recording, auto verdict, parimutuel payouts, refunds, points, mirrors.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 5 end
UnitIsGroupLeader = function() return T.leader ~= false end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 100 } } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, R = ns.A, ns.Ring

local function msgs(typ, from)
  local out = {}
  for i = from or 1, #T.sent do
    local m = T.sent[i]
    if m.msg == typ or m.msg:sub(1, #typ + 1) == typ .. "\t" then
      local f = {}
      for p in (m.msg .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = p end
      table.remove(f, 1)
      out[#out + 1] = { fields = f, channel = m.channel, target = m.target }
    end
  end
  return out
end
local function flush() T.Advance(3) end
local function lastState()
  flush()
  local l = msgs("RS")
  return l[#l] and l[#l].fields
end
local function deliver(sender, text, channel) T.Deliver("BSPT", text, channel or "WHISPER", sender) end
local function bet(sender, on, amount, id)
  deliver(sender, table.concat({ "RB", id or R.session.id, on, amount }, "\t"))
end
local function party(...)
  local names = { ... }
  T.group = { size = #names + 1, raid = false }
  for i = 1, 4 do T.units["party" .. i] = names[i] and { name = names[i], isPlayer = true } or nil end
end
-- one gold stake trade: partner pays `got` (and we pay `gave`); moneyDelta lets tests fake a mismatch.
local function trade(partner, got, gave, moneyDelta)
  T.units.npc = { name = partner, isPlayer = true }
  T.Fire("TRADE_SHOW")
  T.trade.target, T.trade.player = got, gave
  T.Fire("TRADE_ACCEPT_UPDATE", 1, 1)
  local d = moneyDelta or (got - gave)
  if d ~= 0 then T.SetMoney(T.money + d) end
  T.Fire("TRADE_CLOSED")
  T.trade.target, T.trade.player = 0, 0
  T.Advance(1.5)
end
local function betOf(s, who)
  for _, b in ipairs(s.bets) do if b.bettor == who then return b end end
end

T.test("Open guards: referee flag, leader, config", function()
  party("Alice", "Bob", "Carl")
  local s, why = R.Open("ratchet")
  T.eq(s, false); T.eq(why, "referee")
  A.db.config.referee.available = true
  T.leader = false
  s, why = R.Open("ratchet")
  T.eq(why, "leader")
  T.leader = true
  A.db.config.ring.enabled = false
  s, why = R.Open("ratchet")
  T.eq(why, "disabled")
  A.db.config.ring.enabled = true
end)

T.test("Open broadcasts state; fighters set", function()
  T.sent = {}
  local s = R.Open("ratchet")
  T.ok(s and s.isHost, "session")
  T.eq(s.status, "open"); T.eq(s.currency, "gold"); T.eq(s.venue, "ratchet")
  T.eq(s.cap, 1000000, "site cap 100 g (in copper)")
  local rs = lastState()
  T.eq(rs[1], s.id); T.eq(rs[2], "open"); T.eq(rs[4], "gold"); T.eq(rs[11], "1000000")
  T.eq(msgs("RS")[1].channel, "PARTY")
  local ok2 = R.Open("ratchet")
  T.eq(ok2, false, "second open refused")
  T.ok(not R.SetFighters("Fa", "Fa"), "same fighter refused")
  T.ok(R.SetFighters("Fa", "Fb"))
  T.eq(s.fighters.a, "Fa-Normal"); T.eq(s.fighters.b, "Fb-Normal")
end)

T.test("bets are validated: group, fighters, amount, duplicates, id", function()
  local s = R.session
  bet("Alice-Normal", "Fa-Normal", "100000")
  bet("Bob-Normal", "Fb", "300000")
  bet("Carl-Normal", "Fb-Normal", "100000")
  T.eq(#s.bets, 3)
  bet("Mallory-Normal", "Fa-Normal", "5")      -- not in group
  bet("Fa-Normal", "Fb-Normal", "5")           -- fighter
  bet("Dave-Normal", "Fa-Normal", "5", "deadbeef") -- wrong id
  bet("Alice-Normal", "Fb-Normal", "5")        -- duplicate
  party("Alice", "Bob", "Carl", "Dave")
  bet("Dave-Normal", "Nobody-Normal", "5")     -- unknown fighter
  bet("Dave-Normal", "Fa-Normal", "0")
  bet("Dave-Normal", "Fa-Normal", "-4")
  bet("Dave-Normal", "Fa-Normal", "abc")
  bet("Dave-Normal", "Fa-Normal", "1000001")   -- over cap
  T.eq(#s.bets, 3, "only valid bets accepted")
  T.eq(s.bets[1].amount, 100000); T.eq(s.bets[1].side, "a"); T.eq(s.bets[2].on, "Fb-Normal")
  T.ok(not s.bets[1].paid)
  party("Alice", "Bob", "Carl")
  flush()
  T.eq(#msgs("RL"), 3, "one RL per accepted bet")
  T.eq(msgs("RL")[1].fields[2], "Alice-Normal")
  T.ok(not R.SetFighters("X", "Y"), "fighters locked once bets exist")
end)

T.test("trades: stake marks paid only when money delta confirms", function()
  local s = R.session
  trade("Bob", 300000, 0, 0)       -- accepted but no money change -> unconfirmed
  T.ok(not betOf(s, "Bob-Normal").paid, "unconfirmed trade not accepted")
  T.eq(ns.char.trades[#ns.char.trades].confirmed, false)
  trade("Alice", 90000, 0)         -- wrong amount
  T.ok(not betOf(s, "Alice-Normal").paid)
  trade("Alice", 100000, 0)
  trade("Bob", 300000, 0)
  T.ok(betOf(s, "Alice-Normal").paid and betOf(s, "Bob-Normal").paid, "paid")
  local row = ns.char.trades[#ns.char.trades]
  T.eq(row.partner, "Bob-Normal"); T.eq(row.got, 300000); T.eq(row.confirmed, true); T.eq(row.ring, s.id)
  local pa, pb, n = R.Pools(s)
  T.eq(pa, 100000); T.eq(pb, 300000, "unpaid Carl not in pool"); T.eq(n, 3)
  local rs = lastState()
  T.eq(rs[7], "100000"); T.eq(rs[8], "300000"); T.eq(rs[9], "3")
end)

T.test("Lock stops bets", function()
  T.ok(R.Lock())
  bet("Carl-Normal", "Fa-Normal", "10")
  T.eq(R.session.status, "locked")
  T.eq(lastState()[2], "locked")
  party("Alice", "Bob", "Carl", "Dave")
  bet("Dave-Normal", "Fa-Normal", "10")
  T.eq(#R.session.bets, 3)
end)

T.test("auto verdict from DUEL_WINNER messages; payouts parimutuel with unpaid voided", function()
  local s = R.session
  T.Fire("CHAT_MSG_SYSTEM", "Stranger has defeated Other in a duel")
  T.Fire("CHAT_MSG_SYSTEM", "Fa has defeated Zed in a duel")
  T.eq(s.status, "locked", "unrelated duels ignored")
  T.sent = {}
  T.Fire("CHAT_MSG_SYSTEM", "Fb has fled from Fa in a duel")   -- retreat: Fa wins (arg1 = winner)
  T.eq(s.status, "settled"); T.eq(s.winner, "Fa-Normal"); T.ok(s.auto)
  T.eq(betOf(s, "Alice-Normal").payout, 100000 + 300000)
  T.eq(betOf(s, "Bob-Normal").payout, 0)
  T.eq(betOf(s, "Carl-Normal").payout, 0); T.ok(betOf(s, "Carl-Normal").void)
  flush()
  local rl = msgs("RL")
  local mine
  for _, l in ipairs(rl) do
    if l.fields[2] == "Alice-Normal" and l.channel == "WHISPER" and l.target == "Alice-Normal" then mine = l end
  end
  T.ok(mine, "settled line whispered to the bettor")
  T.eq(mine.fields[6], "400000")
  local rs = lastState()
  T.eq(rs[2], "settled"); T.eq(rs[10], "Fa-Normal")
  T.eq(ns.char.bets[#ns.char.bets].status, "settled")
  T.eq(ns.char.bets[#ns.char.bets].role, "host")
  local last = A.db.outbox.rows[#A.db.outbox.rows]
  T.eq(last.kind, "ring"); T.eq(last.data.ev, "settle"); T.eq(last.data.winner, "Fa-Normal")
  T.ok(not R.Verdict("Fb"), "cannot settle twice")
end)

T.test("payout trade marks paidOut; Owed tracks it", function()
  local s = R.session
  T.eq(#R.Owed(), 1); T.eq(R.Owed()[1].bettor, "Alice-Normal"); T.eq(R.Owed()[1].amount, 400000)
  trade("Alice", 0, 399999)
  T.ok(not betOf(s, "Alice-Normal").paidOut, "wrong amount ignored")
  trade("Alice", 0, 400000)
  T.ok(betOf(s, "Alice-Normal").paidOut)
  T.eq(#R.Owed(), 0)
  T.eq(A.db.outbox.rows[#A.db.outbox.rows].data.ev, "payout")
end)

T.test("Close ends the session and tells the group", function()
  T.sent = {}
  T.ok(R.Close())
  T.eq(R.session, nil)
  T.eq(lastState()[2], "closed")
  T.eq(R.last.status, "closed")
end)

T.test("payout math: floors, multiple winners (points currency, no trades)", function()
  A.db.config.ring.currency = "points"
  local s = R.Open("ratchet")
  T.eq(s.currency, "points"); T.eq(s.cap, 1000)
  R.SetFighters("Fa", "Fb")
  bet("Alice-Normal", "Fa", "7")
  bet("Bob-Normal", "Fa", "13")
  bet("Carl-Normal", "Fb", "29")
  T.ok(betOf(s, "Alice-Normal").paid, "points bets are paid immediately")
  T.eq(select(3, R.Pools(s)), 3)
  T.ok(R.Verdict("Fa"))
  T.eq(s.status, "settled")
  T.eq(betOf(s, "Alice-Normal").payout, 7 + math.floor(29 * 7 / 20))
  T.eq(betOf(s, "Bob-Normal").payout, 13 + math.floor(29 * 13 / 20))
  T.eq(betOf(s, "Carl-Normal").payout, 0)
  T.ok(betOf(s, "Alice-Normal").paidOut, "points need no hand-over")
  T.eq(#R.Owed(), 0)
  T.ok(R.Close())
end)

T.test("no bets on the winner -> refunds", function()
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb")
  bet("Alice-Normal", "Fb", "100")
  bet("Bob-Normal", "Fb", "250")
  R.Lock()
  T.ok(R.Verdict("Fa"))
  T.eq(betOf(s, "Alice-Normal").payout, 100)
  T.eq(betOf(s, "Bob-Normal").payout, 250)
  R.Close()
end)

T.test("only bets on one side = stakes returned; void refunds all", function()
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb")
  bet("Alice-Normal", "Fa", "100")
  bet("Carl-Normal", "Fb", "50")
  T.ok(R.Void())
  T.eq(s.status, "void")
  T.eq(betOf(s, "Alice-Normal").payout, 100); T.eq(betOf(s, "Carl-Normal").payout, 50)
  T.ok(not R.Verdict("Fa"))
  R.Close()
  local s2 = R.Open("ratchet")
  R.SetFighters("Fa", "Fb")
  bet("Alice-Normal", "Fa", "100")
  R.Verdict("Fa")
  T.eq(betOf(s2, "Alice-Normal").payout, 100)
  R.Close()
end)

T.test("gold void refunds only paid stakes; closing flags unpaid payouts", function()
  A.db.config.ring.currency = "gold"
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb")
  bet("Alice-Normal", "Fa", "5000")
  bet("Bob-Normal", "Fb", "7000")
  trade("Alice", 5000, 0)
  R.Void()
  T.eq(betOf(s, "Alice-Normal").payout, 5000)
  T.eq(betOf(s, "Bob-Normal").payout, 0)
  T.eq(#R.Owed(), 1)
  R.Close()
  T.eq(R.last.unpaidOut, 1)
end)

T.test("payout math is exact at the caps", function()
  local bets = {}
  for i = 1, 40 do bets[i] = { side = i <= 20 and "a" or "b", amount = 9999999 } end
  local out, pool = R.ComputePayouts(bets, "a", function() return true end)
  T.eq(pool.a, 20 * 9999999)
  T.eq(out[bets[1]], 2 * 9999999)
  bets = { { side = "a", amount = 3 }, { side = "a", amount = 3 }, { side = "b", amount = 1 } }
  out = R.ComputePayouts(bets, "a", function() return true end)
  T.eq(out[bets[1]], 3); T.eq(out[bets[2]], 3, "dust stays with the host")
end)

-- Bettor side: the same addon instance, now a client of someone else's ring.
T.test("mirror: only group-member hosts on group channels create sessions", function()
  party("Host")
  local rs = function(id, status, extra)
    return table.concat({ "RS", id, status, "ratchet", "gold", "Fa-Normal", "Fb-Normal", "0", "0", "0", "", extra or "500000" }, "\t")
  end
  deliver("Stranger-Normal", rs("abc123", "open"), "PARTY")
  T.eq(R.session, nil, "not in my group")
  deliver("Host-Normal", rs("abc123", "open"), "CHANNEL")
  T.eq(R.session, nil, "wrong channel")
  deliver("Host-Normal", "RS\tzzz\topen\tratchet\tgold\tA\tB\t0\t0\t0\t\t5", "PARTY")
  deliver("Host-Normal", "RS\tabc123\tbogus\tratchet\tgold\tA\tB\t0\t0\t0\t\t5", "PARTY")
  T.eq(R.session, nil, "bad id / bad status")
  deliver("Host-Normal", rs("abc123", "open"), "PARTY")
  local s = R.session
  T.ok(s and not s.isHost, "mirror created")
  T.eq(s.host, "Host-Normal"); T.eq(s.fighters.a, "Fa-Normal"); T.eq(s.cap, 500000)
  deliver("Other-Normal", rs("ffff", "open"), "PARTY")
  T.eq(R.session.id, "abc123", "second host ignored")
  T.ok(not R.Open("ratchet"), "cannot host while joined")
end)

T.test("mirror: PlaceBet validation and RB to host", function()
  T.Advance(60) -- drain the host-phase broadcast backlog
  T.money = 10000
  T.sent = {}
  local ok, why = R.PlaceBet("Nobody", 100)
  T.ok(not ok); T.eq(why, "fighter")
  ok, why = R.PlaceBet("Fa", 0); T.eq(why, "amount")
  ok, why = R.PlaceBet("Fa", 500001); T.eq(why, "amount")
  ok, why = R.PlaceBet("Fa", 20000); T.eq(why, "money")
  T.ok(R.PlaceBet("Fa", 5000))
  flush()
  local m = msgs("RB")[1]
  T.eq(m.channel, "WHISPER"); T.eq(m.target, "Host-Normal")
  T.eq(m.fields[1], "abc123"); T.eq(m.fields[2], "Fa-Normal"); T.eq(m.fields[3], "5000")
  T.ok(R.session.pending)
end)

T.test("mirror: RL only from the host and for the session; payouts and settlement mirrored", function()
  local s = R.session
  deliver("Evil-Normal", "RL\tabc123\tTester-Normal\tFa-Normal\t5000\t1\t99999\t1", "PARTY")
  deliver("Host-Normal", "RL\tffff\tTester-Normal\tFa-Normal\t5000\t1\t0\t0", "PARTY")
  T.eq(#s.bets, 0)
  deliver("Host-Normal", "RL\tabc123\tTester-Normal\tFa-Normal\t5000\t0\t0\t0", "PARTY")
  deliver("Host-Normal", "RL\tabc123\tOther-Normal\tFb-Normal\t15000\t1\t0\t0", "PARTY")
  T.eq(#s.bets, 2)
  T.eq(s.pending, nil, "pending cleared when my line arrives")
  T.eq(R.MyBet().amount, 5000); T.ok(not R.MyBet().paid)
  deliver("Host-Normal", "RL\tabc123\tTester-Normal\tFa-Normal\t5000\t1\t0\t0", "PARTY")
  T.ok(R.MyBet().paid)
  deliver("Host-Normal", "RL\tabc123\tTester-Normal\tFa-Normal\t5000\t1\t20000\t0", "PARTY")
  deliver("Host-Normal", "RS\tabc123\tsettled\tratchet\tgold\tFa-Normal\tFb-Normal\t5000\t15000\t2\tFa-Normal\t500000", "PARTY")
  T.eq(s.status, "settled"); T.eq(s.winner, "Fa-Normal")
  local a, b, n = R.Pools(s)
  T.eq(a, 5000); T.eq(b, 15000); T.eq(n, 2)
  T.eq(R.MyBet().payout, 20000)
  local rec = ns.char.bets[#ns.char.bets]
  T.eq(rec.role, "bettor"); T.eq(rec.bet.payout, 20000)
  local ok = R.PlaceBet("Fa", 1)
  T.ok(not ok, "closed for bets")
  deliver("Host-Normal", "RS\tabc123\tclosed\tratchet\tgold\tFa-Normal\tFb-Normal\t5000\t15000\t2\tFa-Normal\t500000", "PARTY")
  T.eq(R.session, nil)
end)

T.test("mirror dropped when leaving the group; points ledger", function()
  deliver("Host-Normal", "RS\tabc999\topen\tratchet\tpoints\tFa-Normal\tFb-Normal\t0\t0\t0\t\t1000", "PARTY")
  T.ok(R.session)
  T.group = { size = 0, raid = false }
  T.Fire("GROUP_ROSTER_UPDATE")
  T.eq(R.session, nil)
  table.insert(ns.char.bets, { role = "bettor", currency = "points", status = "settled", bet = { amount = 100, payout = 250 } })
  table.insert(ns.char.bets, { role = "bettor", currency = "points", status = "settled", bet = { amount = 40, payout = 0 } })
  T.eq(R.PointsBalance(), 110)
end)

T.noErrors()
T.done()
