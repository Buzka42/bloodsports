-- Hostile QA, Series / Duel / Club event paths: a duel record fired twice, forfeit during the countdown, void rounds
-- (consecutive vs separated), the idle boundary, champion bo5, expired challenges, Duel's winner-message spoofing, the
-- Club streak rules, and Series -> Ring end to end (void / forfeit series refund the series markets). Persistence:
-- a void-round counter survives a reload.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 0 end
UnitIsGroupLeader = function() return true end
local TOC = "Bloodsports/Bloodsports.toc"
local RESUME = arg and arg[1] == "--resume"
local now = 1760000000 + 1000
WorldOfMetaData = { bloodsports = {
  referees = { ["Tester-Normal"] = { cap = 50 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } },
  champions = { honorroad = { Horde = { WARRIOR = { name = "Champ-Normal", streak = 14, since = now - 86400 * 3 } } } },
} }

local ns, A, D, S, R
local log = {}
local function evs(name) local o = {} for _, e in ipairs(log) do if e[1] == name then o[#o + 1] = e[2] end end return o end

local function boot(opts)
  opts = opts or {}
  opts.login = false
  ns = T.LoadAddon(TOC, opts)
  A, D, S, R = ns.A, ns.Duel, ns.Series, ns.Ring
  for _, m in ipairs({ "SERIES_START", "SERIES_ROUND", "SERIES_DONE", "DUEL_RESOLVED" }) do
    A:Listen(m, function(p) log[#log + 1] = { m, p } end)
  end
  T.Fire("PLAYER_LOGIN")
  T.Fire("PLAYER_ENTERING_WORLD", true, false)
end

local function setupUnits()
  T.units.player.health, T.units.player.healthMax = 100, 100
  T.units.target = { name = "Foe", class = "ROGUE", race = "Human", level = 12, isPlayer = true, health = 100, healthMax = 100, faction = "Alliance" }
  T.group = { size = 1, raid = false }
end

local function fresh(bo)
  D.Cancel()
  T.Advance(70)
  if R.session then if R.IsHost() then R.Close(true) end end
  ns.char.duels, ns.char.streak, ns.char.series, ns.char.challenges = {}, { cur = 0, best = 0, venue = {} }, {}, {}
  A.db.config.bo = bo
  log = {}
  T.sent = {}
  setupUnits()
  ns.venues = nil
end

local function countdown(target)
  T.Fire("DUEL_REQUESTED", target or "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 2"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 1"); T.Advance(1.2)
end

local function say(text) T.Fire("CHAT_MSG_SYSTEM", text) end

local function round(kind, target)
  target = target or "Foe"
  countdown(target)
  if kind == "win" then say("Tester has defeated " .. target .. " in a duel")
  elseif kind == "loss" then say(target .. " has defeated Tester in a duel")
  elseif kind == "flee" then say("Tester has fled from " .. target .. " in a duel")
  elseif kind == "foeflee" then say(target .. " has fled from Tester in a duel")
  elseif kind == "void" then T.Fire("DUEL_FINISHED"); T.Advance(3) end
end

local function me() return (MetaKit.PlayerKey()) end

---------------------------------------------------------------------------
-- Resumed client (void counter)

local CHILD = {}
CHILD.voids = { run = function(X)
  T.test("resumed client: the consecutive-void counter survived; one more void voids the series", function()
    local s = S.Active()
    T.ok(s and s.id == X.id, "series restored")
    T.eq(s.voids, 1); T.eq(#s.rounds, 0)
    round("void")
    T.eq(S.Active(), nil, "second consecutive void voids it, across the reload")
    local d = evs("SERIES_DONE")[1]
    T.eq(d.void, true); T.eq(d.winner, nil); T.eq(d.id, X.id)
  end)
end }

if RESUME then
  local case, path, at = arg[2], arg[3], tonumber(arg[4])
  local db, X = dofile(path)
  T.serverBase = at - math.floor(T.clock)
  boot({ saved = { BloodsportsDB = db } })
  setupUnits()
  CHILD[case].run(X)
  T.noErrors()
  T.done()
end

boot()

---------------------------------------------------------------------------
-- Series

T.test("the same duel record delivered twice scores one round, not two", function()
  fresh(3)
  round("win")
  local s = S.Active()
  T.eq(s.scoreA, 1)
  local rec = ns.char.duels[#ns.char.duels]
  T.ok(rec.series and rec.series.id == s.id, "record is tagged")
  A:Fire("DUEL_RESOLVED", rec)
  T.eq(s.scoreA, 1, "replayed DUEL_RESOLVED must not add a second round")
  T.eq(#s.rounds, 1)
  T.ok(S.Active(), "a bo3 is not decided by a replayed event")
  T.eq(#evs("SERIES_ROUND"), 1)
end)

T.test("forfeit during the countdown of round 1: series ends 0-0 for the other side; the duel that follows scores nothing", function()
  fresh(3)
  T.Fire("DUEL_REQUESTED", "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3"); T.Advance(1)
  local s = S.Active()
  T.ok(s and #s.rounds == 0, "series created at the countdown")
  S.Forfeit("a")
  T.eq(S.Active(), nil)
  local d = evs("SERIES_DONE")[1]
  T.eq(d.winner, "Foe-Normal"); T.eq(d.reason, "forfeit"); T.eq(d.scoreA, 0); T.eq(d.scoreB, 0)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 2"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 1"); T.Advance(1.2)
  say("Tester has defeated Foe in a duel")
  T.eq(#evs("SERIES_ROUND"), 0, "the finished series takes no round")
  T.eq(#evs("SERIES_DONE"), 1, "no second SERIES_DONE")
  T.eq(S.Active(), nil)
  T.eq(S.Last().winner, "Foe-Normal")
  T.eq(#ns.char.duels, 1, "the duel itself is still recorded")
  round("win")
  T.ok(S.Active() and S.Active().id ~= s.id, "next duel is a fresh series")
  T.noErrors()
end)

T.test("forfeit while a round is live, then the live duel resolves: no resurrection, no extra event", function()
  fresh(5)
  round("win")
  countdown("Foe")
  S.Forfeit("b")
  T.eq(evs("SERIES_DONE")[1].winner, me())
  say("Foe has defeated Tester in a duel")
  T.eq(#evs("SERIES_ROUND"), 1); T.eq(#evs("SERIES_DONE"), 1)
  T.eq(S.Last().scoreB, 0, "last summary keeps the score at the forfeit")
end)

T.test("void rounds: two in a row void the series; a real round between them resets the counter", function()
  fresh(3)
  round("void")
  T.eq(S.Active().voids, 1); T.eq(#S.Active().rounds, 0, "void round not scored")
  round("win")
  T.eq(S.Active().voids, 0, "a decided round resets the void counter")
  round("void")
  T.ok(S.Active(), "void, win, void: still running")
  T.eq(S.Active().scoreA, 1)
  round("void")
  T.eq(S.Active(), nil)
  local d = evs("SERIES_DONE")[1]
  T.eq(d.void, true); T.eq(d.winner, nil); T.eq(d.scoreA, 1); T.eq(d.scoreB, 0)
  T.eq(d.reason, "unknown")
end)

T.test("idle boundary: exactly IDLE_SEC stays, IDLE_SEC + 1 voids; a countdown refreshes the clock", function()
  fresh(3)
  round("win")
  local t0 = S.Active().updatedAt
  T.Advance(S.IDLE_SEC - (GetServerTime() - t0)); S.Tick()
  T.ok(S.Active(), "idle exactly IDLE_SEC is not yet void")
  T.Advance(1); S.Tick()
  T.eq(S.Active(), nil)
  T.eq(evs("SERIES_DONE")[1].reason, "timeout")
  fresh(3)
  round("win")
  T.Advance(S.IDLE_SEC - 30)
  countdown("Foe")
  say("Tester has defeated Foe in a duel")
  T.Advance(S.IDLE_SEC - 30); S.Tick()
  T.eq(S.Active(), nil, "2-0 already ended it")
  T.eq(evs("SERIES_DONE")[1].winner, me())
end)

T.test("champion: Series.Start forces bo5 / first-to-3 whatever was asked; an expired challenge no longer does", function()
  fresh(1)
  local s = S.Start("Champ", { bo = 1, champion = true, challenge = "abc123" })
  T.eq(s.bo, 5); T.eq(s.firstTo, 3); T.eq(s.champion, true)
  T.eq(evs("SERIES_START")[1].bo, 5)
  S.Cancel()
  ns.char.challenges = { c1 = { id = "c1", venue = "honorroad", champion = "Champ-Normal", status = "open", t = now - 8 * 86400 } }
  T.eq(ns.Club.OpenChallengeAgainst("honorroad", "Champ"), nil, "8 days old: expired")
  T.eq(S.FormatFor({ venue = "honorroad", opp = "Champ", bo = 1 }), 1, "expired challenge does not force bo5")
  ns.char.challenges.c1.t = now - 6 * 86400
  T.eq(S.FormatFor({ venue = "honorroad", opp = "Champ", bo = 1 }), 5)
  T.eq(S.FormatFor({ venue = "honorroad", opp = "Somebody", bo = 1 }), 1, "other opponent: no override")
end)

T.test("a persistent void counter: one void, reload, one more void -> void series", function()
  fresh(3)
  round("void")
  T.eq(S.Active().voids, 1)
  local dir = os.getenv("TMPDIR") or "/tmp"
  local path = string.format("%s/bs_hostile_series_%d.lua", dir, os.time())
  local function ser(v, out)
    local t = type(v)
    if t == "number" then out[#out + 1] = string.format("%.17g", v)
    elseif t == "string" then out[#out + 1] = string.format("%q", v)
    elseif t == "boolean" then out[#out + 1] = tostring(v)
    elseif t == "table" then
      out[#out + 1] = "{"
      for k, x in pairs(v) do
        local kt, xt = type(k), type(x)
        if (kt == "string" or kt == "number") and (xt == "table" or xt == "string" or xt == "number" or xt == "boolean") then
          out[#out + 1] = "["; ser(k, out); out[#out + 1] = "]="; ser(x, out); out[#out + 1] = ","
        end
      end
      out[#out + 1] = "}"
    else out[#out + 1] = "nil" end
  end
  local out = { "return " }
  ser(BloodsportsDB, out); out[#out + 1] = ", "; ser({ id = S.Active().id }, out)
  local f = assert(io.open(path, "w")); f:write(table.concat(out)); f:close()
  local p = assert(io.popen(string.format("lua5.1 %q --resume voids %q %.0f 2>&1", arg[0], path, GetServerTime() + 60)))
  local text = p:read("*a"); p:close(); os.remove(path)
  for line in text:gmatch("[^\n]+") do if not line:match("^%d+ passed, %d+ failed$") then io.write("    resumed| ", line, "\n") end end
  T.ok(text:find("1 passed, 0 failed", 1, true), "resumed client passed")
end)

---------------------------------------------------------------------------
-- Duel

local function resolved() return evs("DUEL_RESOLVED") end

T.test("duel: a winner message delivered twice records one duel and bumps the streak once", function()
  fresh(1)
  countdown("Foe")
  say("Tester has defeated Foe in a duel")
  say("Tester has defeated Foe in a duel")
  T.eq(#ns.char.duels, 1); T.eq(#resolved(), 1)
  T.eq(ns.char.streak.cur, 1)
end)

T.test("duel: other people's duels, wrong opponent, and pre-ACTIVE messages are ignored", function()
  fresh(1)
  countdown("Foe")
  say("Alice has defeated Bob in a duel")                   -- not mine
  say("Tester has defeated Mallory in a duel")              -- mine, but not against my opponent
  say("Mallory has fled from Tester in a duel")
  T.eq(#ns.char.duels, 0); T.eq(D.state, "ACTIVE")
  say("Tester has defeated Foe in a duel")
  T.eq(#ns.char.duels, 1); T.eq(ns.char.duels[1].result, "win")
  -- a result message while still in the countdown (spoof) does not resolve it
  fresh(1)
  T.Fire("DUEL_REQUESTED", "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3")
  say("Foe has defeated Tester in a duel")
  T.eq(#ns.char.duels, 0, "COUNTDOWN accepts no verdict"); T.eq(D.state, "COUNTDOWN")
  D.Cancel()
end)

T.test("duel: after the engine voids ('unknown' end) a late winner message cannot rewrite history or touch the streak", function()
  fresh(1)
  countdown("Foe")
  T.Fire("DUEL_FINISHED")
  T.Advance(3)
  T.eq(ns.char.duels[1].result, "void")
  say("Tester has defeated Foe in a duel")
  T.eq(#ns.char.duels, 1); T.eq(ns.char.duels[1].result, "void"); T.eq(ns.char.streak.cur, 0)
end)

T.test("duel: the winner message inside the 2 s ENDING window still counts (flee or knockout), once", function()
  fresh(1)
  countdown("Foe")
  T.Fire("DUEL_FINISHED")
  T.Advance(1)
  say("Foe has fled from Tester in a duel")
  T.eq(#ns.char.duels, 1); T.eq(ns.char.duels[1].result, "win"); T.eq(ns.char.duels[1].how, "retreat")
  T.Advance(5)
  T.eq(#ns.char.duels, 1, "the ENDING timer must not add a void record")
  T.eq(ns.char.streak.cur, 1)
end)

T.test("duel: the 600 s cap voids a stuck duel without a streak change; a loss resets the streak, a void does not", function()
  fresh(1)
  round("win"); round("win")
  T.eq(ns.char.streak.cur, 2)
  countdown("Foe")
  T.Advance(640)
  T.eq(ns.char.duels[#ns.char.duels].result, "void"); T.eq(ns.char.duels[#ns.char.duels].how, "timeout")
  T.eq(ns.char.streak.cur, 2, "void leaves the streak alone")
  round("loss")
  T.eq(ns.char.streak.cur, 0); T.eq(ns.char.streak.best, 2)
  T.noErrors()
end)

---------------------------------------------------------------------------
-- Club

T.test("club streak: self-confirmed wins and voids do not count, 3rd win vs one opponent in a UTC day does not, loss resets", function()
  fresh(1)
  local C = ns.Club
  local day = 20000 * 86400
  local function duel(result, confirmed, opp, t)
    table.insert(ns.char.duels, { id = tostring(#ns.char.duels), t = t or day + 100, venue = "honorroad", result = result, confirmed = confirmed,
      opp = { name = opp } })
  end
  for i = 1, 4 do duel("win", "both", "Same") end   -- only 2 count
  duel("win", "self", "Other1")                      -- self-reported: neither counts nor breaks
  duel("void", "both", "Other2")
  duel("win", "referee", "Other3")
  T.eq(C.MyStreak("honorroad"), 3)
  duel("win", "both", "Same", day + 86400 + 5)       -- next UTC day: counts again
  T.eq(C.MyStreak("honorroad"), 4)
  duel("loss", "both", "Other4")
  T.eq(C.MyStreak("honorroad"), 0)
  duel("win", "both", "Other5")
  T.eq(C.MyStreak("honorroad"), 1)
  duel("win", "both", "Same", day + 86400 * 2 - 1)   -- 23:59:59 of day+1 vs day+2 00:00:00 boundary
  duel("win", "both", "Same", day + 86400 * 2)
  T.eq(C.MyStreak("honorroad"), 3)
end)

T.test("club: a win after the 7-day deadline does not win the expired challenge", function()
  fresh(1)
  local atClub = { Current = function() return { id = "honorroad", kind = "club" } end, Snapshot = function() return { mapID = 1 } end,
    Get = function(_, id) return { id = id, kind = "club" } end }
  ns.venues = atClub
  ns.char.challenges = {
    old = { id = "old", venue = "honorroad", champion = "Champ-Normal", status = "open", t = GetServerTime() - 8 * 86400 },
  }
  round("win", "Champ")
  T.eq(ns.char.duels[#ns.char.duels].venue, "honorroad", "the duel was recorded at the club")
  local c = ns.char.challenges.old
  T.eq(c.status, "open", "expired challenge stays expired, not 'won'")
  -- a fresh one still resolves
  ns.char.challenges = {
    new = { id = "new", venue = "honorroad", champion = "Champ-Normal", status = "open", t = GetServerTime() - 6 * 86400 },
  }
  ns.char.series = {}
  for _ = 1, 3 do round("win", "Champ") end            -- live challenge = champion bo5, closed by SERIES_DONE
  T.eq(ns.char.challenges.new.status, "won", "a live challenge still resolves")
  T.eq(ns.char.duels[#ns.char.duels].venue, "honorroad", "the duel was recorded at the club")
  -- the bo5 path: a SERIES_DONE for an expired challenge changes nothing either
  ns.char.challenges = { old2 = { id = "old2", venue = "honorroad", champion = "Champ-Normal", status = "open", t = GetServerTime() - 9 * 86400 } }
  A:Fire("SERIES_DONE", { id = "ffff0001", champion = true, challenge = "old2", winner = me(), a = me(), b = "Champ-Normal" })
  T.eq(ns.char.challenges.old2.status, "open")
  ns.venues = nil
end)

---------------------------------------------------------------------------
-- Series -> Ring, end to end

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

local function ringWithSeries(bo)
  fresh(bo)
  A.db.config.referee.available = true
  A.db.config.ring.currency = "gold"
  T.money = 100000000
  R.last, ns.char.ring.last = nil, nil
  ns.char.ring.debts, ns.char.ring.unmatched = {}, {}
  party("Ann", "Bob", "Cid")
  local rs = R.Open("ratchet")
  T.ok(type(rs) == "table", "ring session")
  -- the first round's countdown creates the series (SERIES_START reaches the open ring)
  countdown("Foe")
  T.ok(rs.series and rs.series.bo == bo, "ring picked up SERIES_START bo" .. bo)
  local w = R.AddMarket({ kind = "winner", scope = "series", open = true })
  local sc = R.AddMarket({ kind = "score", open = true })
  T.ok(w and sc, "series markets")
  return rs, w, sc
end

T.test("real Series void (two void rounds) refunds the Ring's series markets", function()
  local rs, w, sc = ringWithSeries(3)
  local a, b = r2b("Ann-Normal", w.mid, 1, 100000), r2b("Bob-Normal", sc.mid, 1, 50000)
  trade("Ann", 100000, 0); trade("Bob", 50000, 0)
  T.eq(D.state, "ACTIVE")
  T.Fire("DUEL_FINISHED"); T.Advance(3)   -- void 1
  round("void")                            -- void 2
  T.eq(S.Active(), nil)
  T.eq(w.status, "void"); T.eq(sc.status, "void")
  T.eq(a.payout, 100000); T.eq(b.payout, 50000)
  T.noErrors()
end)

T.test("real Series forfeit at 1-0 in a bo3: winner market pays the forfeit winner, the unreachable score market refunds", function()
  local rs, w, sc = ringWithSeries(3)
  local a, b = r2b("Ann-Normal", w.mid, 1, 100000), r2b("Bob-Normal", w.mid, 2, 100000)
  local c = r2b("Cid-Normal", sc.mid, 1, 50000)
  trade("Ann", 100000, 0); trade("Bob", 100000, 0); trade("Cid", 50000, 0)
  say("Tester has defeated Foe in a duel")             -- round 1: Tester (series side a) leads 1-0
  T.eq(S.Active().scoreA, 1)
  S.Forfeit("a")                                       -- Tester forfeits: Foe takes the series
  T.eq(w.status, "resolving"); T.eq(w.result, 2, "Foe is outcome 2")
  T.eq(b.payout, 200000); T.eq(a.payout, 0)
  T.eq(sc.status, "void", "'1-0' is not an outcome of a bo3 score market")
  T.eq(c.payout, 50000)
  T.Advance(601)
  T.eq(w.status, "settled")
  T.noErrors()
end)

T.test("an unplayed series replaced by a new opponent refunds the old series markets", function()
  local rs, w, sc = ringWithSeries(3)
  local a = r2b("Ann-Normal", w.mid, 1, 100000)
  trade("Ann", 100000, 0)
  D.Cancel()                                           -- countdown cancelled before any result
  T.units.target.name = "Other"
  countdown("Other")                                   -- new opponent: series replaced -> old one void
  T.eq(w.status, "void"); T.eq(a.payout, 100000)
  T.eq(rs.series.b, "Other-Normal", "ring follows the new series")
  D.Cancel()
end)

T.noErrors()
T.done()
