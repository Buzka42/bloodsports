-- Series -> referee relay (R2R) and series markets created before the series starts (G1 + G2 engine side).
--   fighter side: a client joined to somebody else's ring whispers SERIES_START / ROUND / DONE of its real Series
--   referee side: Ring.OnSeriesRelay feeds the Ring handlers; first report per phase wins, the other fighter's copy is a
--                 dupe; a referee who fights ignores relays; senders outside the context are refused
--   markets:      scope "series" before SERIES_START binds at the start (or refunds when another series starts)
-- The two clients are simulated in one process: the fighter's wire is captured from T.sent, then delivered (renamed,
-- and mirrored for the second fighter) to the host-side ring.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 0 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = {
  referees = { ["Tester-Normal"] = { cap = 50 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } },
} }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc", { login = false })
local A, D, S, R = ns.A, ns.Duel, ns.Series, ns.Ring
T.Fire("PLAYER_LOGIN")
T.Fire("PLAYER_ENTERING_WORLD", true, false)

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

local function r2r(from)
  T.Advance(60)
  local out = {}
  for i = from or 1, #T.sent do
    local m = T.sent[i]
    if m.msg:sub(1, 4) == "R2R\t" then out[#out + 1] = { f = fields(m), channel = m.channel, target = m.target } end
  end
  return out
end

---------------------------------------------------------------------------
-- Fighter side

local function setupUnits()
  T.units.player.health, T.units.player.healthMax = 100, 100
  T.units.target = { name = "Foe", class = "ROGUE", race = "Human", level = 12, isPlayer = true, health = 100, healthMax = 100, faction = "Alliance" }
end

local function countdown(target)
  T.Fire("DUEL_REQUESTED", target or "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 2"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 1"); T.Advance(1.2)
end

local function joinedTo(host, id)
  party(host:match("^[^-]+"))
  T.Deliver("BSPT", table.concat({ "R2S", 2, id, "open", "ratchet", "gold", 500000, "", 0, 0, 1, "100" }, "\t"), "PARTY", host)
  return R.session
end

local fighterWire

T.test("fighter in a ring session whispers series start, rounds and done to the referee", function()
  D.Cancel(); T.Advance(70)
  ns.char.duels, ns.char.streak, ns.char.series, ns.char.challenges = {}, { cur = 0, best = 0, venue = {} }, {}, {}
  A.db.config.bo = 3
  setupUnits()
  T.sent = {}
  local s = joinedTo("Ref-Normal", "abcd1234")
  T.ok(s and not s.isHost and s.v2, "mirror of Ref's ring")
  countdown("Foe")
  T.ok(S.Active() and S.Active().bo == 3, "bo3 series started")
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  countdown("Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  T.eq(S.Active(), nil, "2-0 finishes the series")
  local w = r2r()
  T.eq(#w, 4, "start, round, round, done")
  local phases = {}
  for i, m in ipairs(w) do
    T.eq(m.channel, "WHISPER"); T.eq(m.target, "Ref-Normal"); T.eq(m.f[1], "abcd1234", "session id")
    phases[i] = m.f[2]
    T.ok(#("R2R\t" .. table.concat(m.f, "\t")) <= 255, "within the 255-byte habit")
  end
  T.eq(table.concat(phases), "srrd")
  local st, d = w[1].f, w[4].f
  T.eq(st[3], "Tester-Normal"); T.eq(st[4], "Foe-Normal"); T.eq(st[5], "3"); T.eq(st[9], "00")
  T.eq(w[3].f[10], "2", "round number"); T.eq(w[3].f[6], "2"); T.eq(w[3].f[7], "0")
  T.eq(d[8], "Tester-Normal", "winner"); T.eq(d[6], "2"); T.eq(d[7], "0")
  T.eq(st[11], d[11], "same series id across the phases")
  fighterWire = w
  R.Leave()
end)

T.test("no relay for a bo1 duel, outside a ring, or from the host's own client", function()
  D.Cancel(); T.Advance(70)
  A.db.config.bo = 1
  setupUnits(); T.sent = {}
  joinedTo("Ref-Normal", "abcd1235")
  countdown("Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  T.eq(#r2r(), 0, "bo1 is just the duel")
  R.Leave()
  A.db.config.bo = 3
  D.Cancel(); T.Advance(70); T.sent = {}
  countdown("Foe")
  S.Cancel("test")
  T.eq(#r2r(), 0, "not in a ring: nothing to tell")
  A.db.config.referee.available = true
  A.db.config.ring.currency = "gold"
  party("Cid")
  D.Cancel(); T.Advance(70); T.sent = {}
  T.ok(type(R.Open("ratchet")) == "table", "own ring")
  countdown("Foe")
  S.Cancel("test")
  T.eq(#r2r(), 0, "the host hears its own events directly")
  R.Close(true)
  D.Cancel(); T.Advance(70)
end)

---------------------------------------------------------------------------
-- Referee side

local nonce = 0
local function r2b(sender, mid, idx, amount)
  nonce = nonce + 1
  T.Deliver("BSPT", table.concat({ "R2B", R.session.id, mid, idx, amount, 0, string.format("%04x", nonce) }, "\t"), "WHISPER", sender)
  T.Advance(2.1)
  for _, b in ipairs(R.Market(mid).bets) do if b.bettor == sender then return b end end
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

local function host()
  if R.session and R.IsHost() then R.Close(true) end
  D.Cancel(); T.Advance(70)
  A.db.config.referee.available = true
  A.db.config.ring.currency = "gold"
  T.money = 100000000
  R.last, ns.char.ring.last = nil, nil
  ns.char.ring.debts, ns.char.ring.unmatched = {}, {}
  party("Cid", "Dan")
  local s = R.Open("ratchet")
  T.ok(type(s) == "table", "host ring")
  return s
end

-- The captured wire of the fighter run, renamed Tester -> Ann and Foe -> Bob; `side` "bob" is the other fighter's copy
-- (names and score swapped, its own series id).
local function wire(i, side, newId)
  local f = {}
  for k, v in ipairs(fighterWire[i].f) do f[k] = v end
  local function ren(x) return (x:gsub("Tester%-Normal", "Ann-Normal"):gsub("Foe%-Normal", "Bob-Normal")) end
  f[3], f[4], f[8] = ren(f[3]), ren(f[4]), ren(f[8])
  f[1] = R.session.id
  if side == "bob" then
    f[3], f[4] = f[4], f[3]
    f[6], f[7] = f[7], f[6]
    f[11] = "bb" .. f[11]
  else
    f[11] = "aa" .. f[11]
  end
  if newId then f[11] = newId end
  return "R2R\t" .. table.concat(f, "\t"), side == "bob" and "Bob-Normal" or "Ann-Normal"
end
local function deliver(i, side, newId)
  local text, sender = wire(i, side, newId)
  T.Deliver("BSPT", text, "WHISPER", sender)
  T.Advance(0.2)
end

T.test("pending series market: created before the start, bound by the relayed start, settled by the relayed done", function()
  local s = host()
  T.eq(s.series, nil, "no series yet")
  local w, why = R.AddMarket({ kind = "winner", scope = "series", a = "Ann-Normal", b = "Bob-Normal", bo = 3, open = true })
  T.ok(w, tostring(why))
  local sc = R.AddMarket({ kind = "score", a = "Ann-Normal", b = "Bob-Normal", bo = 3, open = true })
  T.ok(sc, "score market before the start")
  local rnd = R.AddMarket({ kind = "winner", a = "Ann-Normal", b = "Bob-Normal", open = true })
  T.eq(w.scope, "series"); T.eq(w.pending, true); T.eq(w.sid, nil); T.eq(w.title, "Series winner")
  T.eq(w.outcomes[1].ref, "Ann-Normal"); T.eq(#sc.outcomes, 4); T.eq(s.pendingSeries.bo, 3)
  T.eq(rnd.scope, "fight"); T.eq(rnd.pending, nil); T.eq(rnd.sid, nil)
  local a = r2b("Cid-Normal", w.mid, 1, 100000)
  local b = r2b("Dan-Normal", w.mid, 2, 100000)
  local c = r2b("Cid-Normal", sc.mid, 1, 50000)
  trade("Cid", 100000, 0); trade("Dan", 100000, 0); trade("Cid", 50000, 0)
  -- the same fighter pair with another bo, or a different pair, cannot join the waiting context
  local _, why2 = R.AddMarket({ kind = "winner", scope = "series", a = "Ann-Normal", b = "Bob-Normal", bo = 5 })
  T.eq(why2, "pending")
  local _, why3 = R.AddMarket({ kind = "winner", scope = "series", a = "Cid-Normal", b = "Dan-Normal", bo = 3 })
  T.eq(why3, "pending")
  -- Ann's start, then Bob's copy: one series
  deliver(1, "ann")
  T.ok(s.series and s.series.relay and s.series.bo == 3 and s.series.a == "Ann-Normal", "series from the relay")
  T.eq(s.pendingSeries, nil, "context consumed")
  T.eq(w.pending, nil); T.eq(w.sid, s.series.id, "bound to the series"); T.eq(sc.sid, s.series.id)
  T.eq(rnd.sid, nil, "the fight-scope market is not a series market")
  local id = s.series.id
  deliver(1, "bob")
  T.eq(s.series.id, id, "the second fighter's start is a dupe")
  T.eq(w.status, "open")
  -- rounds: Ann wins both (the captured run), Bob's copy of each is a dupe
  deliver(2, "ann"); deliver(2, "bob")
  T.eq(s.series.round, 1); T.eq(s.series.scoreA, 1)
  deliver(3, "bob"); deliver(3, "ann")
  T.eq(s.series.round, 2); T.eq(s.series.scoreA, 2); T.eq(s.series.scoreB, 0)
  T.eq(w.status, "open", "markets wait for the done")
  deliver(4, "ann"); deliver(4, "bob")
  T.ok(s.series.done, "series finished")
  T.eq(w.status, "resolving"); T.eq(w.result, 1, "Ann is outcome 1"); T.eq(a.payout, 200000); T.eq(b.payout, 0)
  T.eq(sc.status, "resolving"); T.eq(sc.outcomes[sc.result].label, "2-0"); T.eq(c.payout, 50000)
  T.eq(rnd.status, "open", "the round market is untouched by the series")
  T.noErrors()
end)

T.test("score reads from the market's first fighter even when the other fighter's report arrives first", function()
  local s = host()
  local sc = R.AddMarket({ kind = "score", a = "Ann-Normal", b = "Bob-Normal", bo = 3, open = true })
  local w = R.AddMarket({ kind = "winner", scope = "series", a = "Ann-Normal", b = "Bob-Normal", bo = 3, open = true })
  deliver(1, "bob")
  T.eq(s.series.a, "Bob-Normal", "Bob's client names itself first")
  deliver(1, "ann"); deliver(3, "bob"); deliver(4, "bob"); deliver(4, "ann")
  T.eq(s.series.winner, "Ann-Normal")
  T.eq(w.outcomes[w.result].ref, "Ann-Normal")
  T.eq(sc.outcomes[sc.result].label, "2-0", "Ann won 2-0 whoever reported")
  T.noErrors()
end)

T.test("a different series starting voids the markets that waited for another one", function()
  local s = host()
  local w = R.AddMarket({ kind = "winner", scope = "series", a = "Ann-Normal", b = "Bob-Normal", bo = 3, open = true })
  local b = r2b("Cid-Normal", w.mid, 1, 100000)
  trade("Cid", 100000, 0)
  T.units.npc = nil
  -- Eve and Fay are named by nothing the host set up, and Eve is not in the group: refused
  local ev = { phase = "start", id = "ab01", a = "Eve-Normal", b = "Fay-Normal", bo = 3 }
  T.eq(select(2, R.OnSeriesRelay(ev, "Eve-Normal")), "sender")
  T.eq(w.pending, true, "still waiting")
  party("Cid", "Dan", "Eve")
  T.ok(R.OnSeriesRelay(ev, "Eve-Normal"), "a group member may report")
  T.eq(w.status, "void"); T.eq(b.payout, 100000, "stake refunded")
  T.eq(s.pendingSeries, nil)
  T.eq(s.series.a, "Eve-Normal")
  T.noErrors()
end)

T.test("a referee who is a fighter trusts local events only; bad senders and malformed reports are refused", function()
  local s = host()
  local ok, why = R.OnSeriesRelay({ phase = "start", id = "ab02", a = "Tester-Normal", b = "Bob-Normal", bo = 3 }, "Bob-Normal")
  T.eq(ok, false); T.eq(why, "local"); T.eq(s.series, nil)
  R.SetFighters("Ann", "Bob")
  local function try(ev, sender) local o, y = R.OnSeriesRelay(ev, sender) return o, y end
  local o, y = try({ phase = "start", id = "ab03", a = "Ann-Normal", b = "Bob-Normal", bo = 3 }, "Cid-Normal")
  T.eq(o, false); T.eq(y, "sender", "a third party cannot report for Ann and Bob")
  o, y = try({ phase = "start", id = "ab03", a = "Ann-Normal", b = "Ann-Normal", bo = 3 }, "Ann-Normal"); T.eq(y, "event")
  o, y = try({ phase = "start", id = "ab03", a = "Ann-Normal", b = "Bob-Normal", bo = 4 }, "Ann-Normal"); T.eq(y, "event")
  o, y = try({ phase = "wat", id = "ab03", a = "Ann-Normal", b = "Bob-Normal", bo = 3 }, "Ann-Normal"); T.eq(y, "event")
  o, y = try({ phase = "start", id = "", a = "Ann-Normal", b = "Bob-Normal", bo = 3 }, "Ann-Normal"); T.eq(y, "event")
  T.eq(s.series, nil)
  -- hostile wire: wrong session id, missing fields, junk
  for _, text in ipairs({ "R2R\twrongid\ts\tAnn-Normal\tBob-Normal\t3\t0\t0\t\t00\t0\tab04", "R2R\t" .. s.id, "R2R\t" .. s.id .. "\ts\tAnn-Normal\tBob-Normal\t3\t0\t0\t\t00\t0\tzz|zz",
    "R2R" }) do
    T.Deliver("BSPT", text, "WHISPER", "Ann-Normal")
  end
  T.Advance(1)
  T.eq(s.series, nil, "nothing accepted")
  -- a live local series beats any relay
  A:Fire("SERIES_START", { id = "cafe01", bo = 3, a = "Tester-Normal", b = "Foe-Normal" })
  T.ok(s.series and not s.series.relay, "local series")
  o, y = try({ phase = "start", id = "ab05", a = "Ann-Normal", b = "Bob-Normal", bo = 3 }, "Ann-Normal")
  T.eq(y, "local"); T.eq(s.series.id, "cafe01")
  T.noErrors()
end)

T.test("lost start: a relayed done creates and settles the series; a void report refunds; stale dupes are ignored", function()
  local s = host()
  party("Cid", "Dan", "Ann")
  local w = R.AddMarket({ kind = "winner", scope = "series", a = "Ann-Normal", b = "Bob-Normal", bo = 3, open = true })
  local a = r2b("Cid-Normal", w.mid, 2, 100000)
  local d = r2b("Dan-Normal", w.mid, 1, 100000)
  trade("Cid", 100000, 0); trade("Dan", 100000, 0)
  -- Bob's done only (his start was lost): Ann is outcome 1 and won
  deliver(4, "bob")
  T.ok(s.series.done and s.series.relay)
  T.eq(w.status, "resolving"); T.eq(w.result, 1); T.eq(a.payout, 0); T.eq(d.payout, 200000)
  local id = s.series.id
  deliver(4, "ann")
  T.eq(s.series.id, id, "the other fighter's done is a dupe")
  deliver(1, "ann")
  T.eq(s.series.id, id, "a late start copy within the dupe window does not restart the series")
  T.Advance(30)
  -- a real rematch afterwards: new start, then a void done
  local w2 = R.AddMarket({ kind = "winner", scope = "series", a = "Ann-Normal", b = "Bob-Normal", bo = 3, open = true })
  T.eq(w2.pending, true, "a finished series is no context for new markets")
  deliver(1, "ann", "ee01")
  T.ok(s.series.id ~= id and not s.series.done, "rematch is a new series"); T.eq(w2.sid, s.series.id)
  local text, sender = wire(4, "ann", "ee01")
  local f = {}
  for p in (text .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = p end
  f[10] = "01"; f[9] = ""   -- f[1] is the message type: winner is field 8, flags field 9
  T.Deliver("BSPT", table.concat(f, "\t"), "WHISPER", sender)
  T.Advance(1)
  T.ok(s.series.done and s.series.void)
  T.eq(w2.status, "void", "void series refunds")
  T.noErrors()
end)

T.test("a series market needs a live series or a bo3 / bo5 context", function()
  local s = host()
  local _, why = R.AddMarket({ kind = "winner", scope = "series", a = "Ann-Normal", b = "Bob-Normal" })
  T.eq(why, "series")
  _, why = R.AddMarket({ kind = "score" })
  T.eq(why, "series")
  _, why = R.AddMarket({ kind = "winner", scope = "series", bo = 3, a = "Ann-Normal", b = "Ann" })
  T.eq(why, "fighters")
  T.eq(R.SetPendingSeries("Ann", "Bob", 1), true, "bo1 clears the context")
  local ctx = R.SetPendingSeries("Ann", "Bob", 5)
  T.eq(ctx.bo, 5); T.eq(ctx.a, "Ann-Normal")
  T.ok(R.AddMarket({ kind = "score", bo = 5 }), "score market from the context alone")
  T.eq(select(2, R.SetPendingSeries("Ann", "Bob", 3)), "pending", "the waiting market pins the context")
  R.Close(true)
  T.noErrors()
end)

T.noErrors()
T.done()
