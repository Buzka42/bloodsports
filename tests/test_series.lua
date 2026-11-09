-- Series (bo1/bo3/bo5) over the Duel engine, driven through system messages: format rules, early stop, champion bo5,
-- SERIES_* event order, void/retreat/forfeit/idle handling, /bs bo, and persistence (a FRESH lua5.1 process resumes the
-- series from a written BloodsportsDB, the way test_ring_persist does it).
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 5 end
local TOC = "Bloodsports/Bloodsports.toc"
local RESUME = arg and arg[1] == "--resume"
local now = 1760000000 + 1000
WorldOfMetaData = { bloodsports = { champions = { honorroad = {
  Horde = { WARRIOR = { name = "Champ-Normal", streak = 14, since = now - 86400 * 3 } },
} } } }

local ns, A, D, S
local log = {}
local function names() local o = {} for _, e in ipairs(log) do o[#o + 1] = e[1] end return table.concat(o, ",") end
local function evs(name) local o = {} for _, e in ipairs(log) do if e[1] == name then o[#o + 1] = e[2] end end return o end

local function boot(opts)
  opts = opts or {}
  opts.login = false
  ns = T.LoadAddon(TOC, opts)
  A, D, S = ns.A, ns.Duel, ns.Series
  -- listeners first, then login: like Ring/Confirm they sit ahead of Series' own (OnLogin) listeners
  for _, m in ipairs({ "SERIES_START", "SERIES_ROUND", "SERIES_DONE", "SERIES_RESET", "DUEL_RESOLVED" }) do
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
  ns.char.duels, ns.char.streak, ns.char.series, ns.char.challenges = {}, { cur = 0, best = 0, venue = {} }, {}, {}
  A.db.config.bo = bo
  log = {}
  T.sent = {}
  setupUnits()
  ns.venues = nil
end

local function startDuel(target)
  T.Fire("DUEL_REQUESTED", target or "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 2"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 1"); T.Advance(1.2)
end

-- one round: kind = win | loss | flee (I fled) | foeflee | void
local function round(kind, target)
  target = target or "Foe"
  startDuel(target)
  if kind == "win" then T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated " .. target .. " in a duel")
  elseif kind == "loss" then T.Fire("CHAT_MSG_SYSTEM", target .. " has defeated Tester in a duel")
  elseif kind == "flee" then T.Fire("CHAT_MSG_SYSTEM", "Tester has fled from " .. target .. " in a duel")
  elseif kind == "foeflee" then T.Fire("CHAT_MSG_SYSTEM", target .. " has fled from Tester in a duel")
  elseif kind == "void" then T.Fire("DUEL_FINISHED"); T.Advance(3) end
end

local function me() return (MetaKit.PlayerKey()) end

---------------------------------------------------------------------------
-- Child (resumed client)

local CHILD = {}

CHILD.resume = { run = function(X)
  T.test("resumed client: series, score and rounds come back from BloodsportsDB", function()
    local s = S.Active()
    T.ok(s, "active series restored")
    T.eq(s.id, X.id); T.eq(s.bo, 5); T.eq(s.scoreA, 1); T.eq(s.scoreB, 1); T.eq(#s.rounds, 2)
    T.eq(S.Describe(), "BO5 round 3 (1-1)")
  end)
  T.test("resumed client continues the same series to a bo5 finish (3-1)", function()
    round("win")
    T.eq(S.Active().id, X.id, "same series after a round")
    T.eq(#evs("SERIES_START"), 0, "no second SERIES_START: round 3 joined the series")
    local r = evs("SERIES_ROUND")[1]
    T.eq(r.id, X.id); T.eq(r.round, 3); T.eq(r.scoreA, 2)
    round("win")
    T.eq(S.Active(), nil)
    local d = evs("SERIES_DONE")[1]
    T.eq(d.id, X.id); T.eq(d.winner, me()); T.eq(d.scoreA, 3); T.eq(d.scoreB, 1)
    T.eq(#evs("SERIES_ROUND"), 2)
  end)
end }

CHILD.stale = { run = function(X)
  T.test("resumed client: a series idle past IDLE_SEC is void on login", function()
    T.eq(S.Active(), nil)
    local l = S.Last()
    T.eq(l.id, X.id); T.eq(l.reason, "timeout"); T.eq(l.winner, nil); T.eq(l.scoreA, 1)
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

---------------------------------------------------------------------------
-- Parent

boot()

T.test("FormatFor: champion forces bo5, otherwise the picker / preference", function()
  fresh(3)
  local bo, champ = S.FormatFor({})
  T.eq(bo, 3); T.eq(champ, false)
  bo = S.FormatFor({ bo = 1 }); T.eq(bo, 1)
  bo = S.FormatFor({ bo = 7 }); T.eq(bo, 3, "invalid pick falls back to the preference")
  bo, champ = S.FormatFor({ champion = true, bo = 1 }); T.eq(bo, 5); T.eq(champ, true)
  A.db.config.bo = nil
  T.eq(S.FormatFor(nil), 1, "no preference = bo1")
  T.eq(D.FormatFor({ champion = true }), 5, "Duel entry point")
end)

T.test("bo1 ends after one round; events SERIES_START > DUEL_RESOLVED > SERIES_ROUND > SERIES_DONE", function()
  fresh(1)
  round("win")
  T.eq(names(), "SERIES_START,DUEL_RESOLVED,SERIES_ROUND,SERIES_DONE")
  T.eq(S.Active(), nil)
  local st, r, d = evs("SERIES_START")[1], evs("SERIES_ROUND")[1], evs("SERIES_DONE")[1]
  T.eq(st.bo, 1); T.eq(st.a, me()); T.eq(st.b, "Foe-Normal"); T.eq(st.champion, false)
  T.ok(st.id:match("^%x+$") and #st.id >= 8 and #st.id <= 16, "hex id")
  T.eq(r.id, st.id); T.eq(r.round, 1); T.eq(r.winner, me()); T.eq(r.how, "knockout")
  T.eq(d.id, st.id); T.eq(d.winner, me()); T.eq(d.scoreA, 1); T.eq(d.scoreB, 0); T.eq(d.void, nil)
  T.eq(ns.char.duels[1].series.id, st.id, "duel record is tagged")
  T.eq(S.Last().id, st.id)
  T.noErrors()
end)

T.test("bo3 stops at 2-0 (no third round); each duel afterwards is a fresh series", function()
  fresh(3)
  round("win")
  T.eq(S.Active().scoreA, 1); T.eq(#evs("SERIES_DONE"), 0, "not decided after round 1")
  T.eq(D.state, "IDLE"); T.eq(#evs("SERIES_RESET"), 1, "duel engine reset between rounds")
  round("win")
  T.eq(S.Active(), nil)
  T.eq(names(), "SERIES_START,DUEL_RESOLVED,SERIES_ROUND,SERIES_RESET,DUEL_RESOLVED,SERIES_ROUND,SERIES_DONE")
  local d = evs("SERIES_DONE")[1]
  T.eq(d.scoreA, 2); T.eq(d.scoreB, 0); T.eq(d.bo, 3); T.eq(#ns.char.duels, 2, "third round was not played")
  T.eq(#evs("SERIES_START"), 1, "round 2 joined the series")
  round("win")
  T.eq(#evs("SERIES_START"), 2, "a new duel after the decision starts a new series")
  T.noErrors()
end)

T.test("bo3 goes the distance at 2-1 and scores from my side", function()
  fresh(3)
  round("win"); round("loss")
  T.eq(S.Describe(), "BO3 round 3 (1-1)")
  round("win")
  local d = evs("SERIES_DONE")[1]
  T.eq(d.winner, me()); T.eq(d.scoreA, 2); T.eq(d.scoreB, 1)
  local rs = evs("SERIES_ROUND")
  T.eq(#rs, 3); T.eq(rs[2].winner, "Foe-Normal"); T.eq(rs[1].round, 1); T.eq(rs[3].round, 3)
  T.eq(ns.char.duels[3].series.round, 3)
  fresh(3)
  round("loss"); round("loss")
  d = evs("SERIES_DONE")[1]
  T.eq(d.winner, "Foe-Normal"); T.eq(d.scoreA, 0); T.eq(d.scoreB, 2)
end)

T.test("bo5 needs 3 wins; 2-0 and 2-2 are not decisions", function()
  fresh(5)
  round("win"); round("win"); T.ok(S.Active(), "2-0 still running")
  round("loss"); round("loss"); T.ok(S.Active(), "2-2 still running")
  T.eq(S.Describe(), "BO5 round 5 (2-2)")
  round("loss")
  local d = evs("SERIES_DONE")[1]
  T.eq(d.winner, "Foe-Normal"); T.eq(d.scoreA, 2); T.eq(d.scoreB, 3); T.eq(#ns.char.duels, 5)
end)

T.test("champion challenge forces bo5 whatever the picker says; challenge closes on SERIES_DONE", function()
  fresh(1)
  ns.venues = {
    Current = function() return { id = "honorroad", kind = "club" } end,
    Snapshot = function() return { mapID = 1 } end,
    Get = function(_, id) return { id = id, kind = "club" } end,
  }
  for i = 1, 10 do
    table.insert(ns.char.duels, { id = "s" .. i, t = now, venue = "honorroad", result = "win", confirmed = "both", opp = { name = "O" .. i } })
  end
  local chal = ns.Club.Challenge("honorroad")
  T.ok(chal, "challenge made"); T.eq(chal.champion, "Champ-Normal")
  T.units.target = { name = "Champ", class = "WARRIOR", race = "Human", level = 12, isPlayer = true, health = 100, healthMax = 100 }
  log = {}
  round("win", "Champ")
  local st = evs("SERIES_START")[1]
  T.eq(st.bo, 5, "bo5 despite pref 1"); T.eq(st.champion, true); T.eq(st.challenge, chal.id)
  T.eq(chal.status, "open", "round 1 does not close the challenge")
  round("win", "Champ")
  T.eq(chal.status, "open"); T.eq(#evs("SERIES_DONE"), 0, "2-0 of bo5 is not over")
  round("win", "Champ")
  local d = evs("SERIES_DONE")[1]
  T.eq(d.id, st.id); T.eq(d.bo, 5); T.eq(d.champion, true); T.eq(d.winner, me()); T.eq(d.scoreA, 3)
  T.eq(chal.status, "won"); T.eq(chal.series, st.id)
  T.eq(ns.char.duels[#ns.char.duels].series.champion, true)
  -- a champion series that I lose
  ns.char.challenges = {}
  chal = ns.Club.Challenge("honorroad")
  T.ok(chal)
  log = {}
  A.db.config.bo = 3
  for _ = 1, 3 do round("loss", "Champ") end
  d = evs("SERIES_DONE")[1]
  T.eq(d.bo, 5); T.eq(d.winner, "Champ-Normal"); T.eq(d.scoreB, 3); T.eq(chal.status, "lost")
  T.noErrors()
end)

T.test("retreat decides a round for the other side (flee counts like Duel's end reason)", function()
  fresh(3)
  round("flee")
  local r = evs("SERIES_ROUND")[1]
  T.eq(r.winner, "Foe-Normal"); T.eq(r.how, "retreat"); T.eq(r.scoreB, 1)
  round("foeflee")
  r = evs("SERIES_ROUND")[2]
  T.eq(r.winner, me()); T.eq(r.how, "retreat"); T.eq(r.scoreA, 1)
  T.ok(S.Active(), "1-1 still running")
end)

T.test("void duels (timeout/unknown) are replayed, not scored; two in a row void the series", function()
  fresh(3)
  round("void")
  T.eq(#evs("SERIES_ROUND"), 0); T.eq(S.Active().scoreA, 0); T.eq(S.Active().voids, 1)
  round("win")
  T.eq(S.Active().scoreA, 1); T.eq(S.Active().voids, 0, "a decided round clears the void count")
  T.eq(evs("SERIES_ROUND")[1].round, 1, "the voided duel did not take a round number")
  round("void"); round("void")
  T.eq(S.Active(), nil)
  local d = evs("SERIES_DONE")[1]
  T.eq(d.winner, nil); T.eq(d.void, true); T.eq(d.reason, "unknown"); T.eq(d.scoreA, 1)
end)

T.test("Series.Forfeit hands the series to the other side; Cancel voids", function()
  fresh(5)
  round("win")
  local e = S.Forfeit("a")
  T.eq(S.Active(), nil)
  local d = evs("SERIES_DONE")[1]
  T.eq(d.winner, "Foe-Normal"); T.eq(d.reason, "forfeit"); T.eq(d.scoreA, 1); T.eq(d.scoreB, 0); T.eq(d.void, nil)
  T.eq(e.id, d.id)
  T.eq(S.Forfeit("a"), nil, "nothing to forfeit")
  fresh(5)
  round("win"); round("loss")
  S.Forfeit("b")
  T.eq(evs("SERIES_DONE")[1].winner, me())
  fresh(3)
  round("win")
  S.Cancel()
  d = evs("SERIES_DONE")[1]
  T.eq(d.void, true); T.eq(d.winner, nil); T.eq(d.reason, "cancelled")
end)

T.test("idle past IDLE_SEC voids the series (timeout); fresher activity does not", function()
  fresh(3)
  round("win")
  T.Advance(S.IDLE_SEC - 120); S.Tick()
  T.ok(S.Active(), "still within the window")
  T.Advance(300); S.Tick()
  T.eq(S.Active(), nil)
  local d = evs("SERIES_DONE")[1]
  T.eq(d.void, true); T.eq(d.reason, "timeout"); T.eq(d.scoreA, 1)
end)

T.test("a duel against someone else mid-series is not a round; an unplayed series is replaced", function()
  fresh(3)
  round("win")
  local id = S.Active().id
  T.units.target.name = "Other"
  round("win", "Other")
  T.eq(S.Active().id, id); T.eq(S.Active().scoreA, 1, "Other's duel did not count")
  T.eq(ns.char.duels[2].series, nil)
  fresh(3)
  startDuel("Foe"); D.Cancel() -- countdown started, then the duel was cancelled before any result
  local first = S.Active()
  T.ok(first and #first.rounds == 0)
  T.units.target.name = "Other"
  round("win", "Other")
  T.eq(S.Active().b, "Other-Normal"); T.ok(S.Active().id ~= first.id)
  T.eq(evs("SERIES_DONE")[1].reason, "replaced")
end)

T.test("/bs bo sets the format, shows status, forfeits and cancels", function()
  fresh(1)
  SlashCmdList.BLOODSPORTS("bo 3")
  T.eq(A.db.config.bo, 3)
  SlashCmdList.BLOODSPORTS("bo 7")
  T.eq(A.db.config.bo, 3, "invalid ignored")
  SlashCmdList.BLOODSPORTS("bo 5")
  T.eq(S.Preferred(), 5)
  round("win")
  T.printed = {}
  SlashCmdList.BLOODSPORTS("bo")
  T.ok(table.concat(T.printed, "\n"):find("best of 5", 1, true) and table.concat(T.printed, "\n"):find("BO5 round 2 (1-0)", 1, true), "status line")
  SlashCmdList.BLOODSPORTS("bo forfeit")
  T.eq(S.Active(), nil); T.eq(evs("SERIES_DONE")[1].reason, "forfeit")
  round("win")
  SlashCmdList.BLOODSPORTS("bo cancel")
  T.eq(S.Active(), nil); T.eq(evs("SERIES_DONE")[2].reason, "cancelled")
end)

T.test("duel card refresh with a series active raises no error", function()
  fresh(3)
  T.Fire("DUEL_REQUESTED", "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3")
  T.eq(S.Describe(), "BO3 round 1 (0-0)")
  D.Cancel()
  T.noErrors()
end)

---------------------------------------------------------------------------
-- Persistence: write SavedVariables like WoW does, run a fresh client from them.

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
  local path = string.format("%s/bs_series_%s_%d.lua", dir, case, os.time())
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

T.test("persistence: /reload mid-bo5 resumes the same series and finishes it", function()
  fresh(5)
  round("win"); round("loss")
  T.eq(S.Describe(), "BO5 round 3 (1-1)")
  reload("resume", 120, 2, { id = S.Active().id })
end)

T.test("persistence: a series idle past IDLE_SEC is void after the reload", function()
  fresh(3)
  round("win")
  reload("stale", S.IDLE_SEC + 60, 1, { id = S.Active().id })
end)

T.noErrors()
T.done()
