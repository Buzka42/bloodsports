-- MK.Ext consumption: Ring dispatches extension market kinds (outcomes + settle hook), Narrator appends provider lines.
-- Registers fake extensions in the test setup, drives the real Ring / Duel / Narrator through the stub.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 5 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 100 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc", { login = false })
local MK = MetaKit
T.Fire("PLAYER_LOGIN")
T.Fire("PLAYER_ENTERING_WORLD", true, false)
local A, D, R = ns.A, ns.Duel, ns.Ring
local cfg = A.db.config.chat
local cat = cfg.cats.bloodsports
local Ext = MK.Ext

local function short(n) return tostring(n or ""):match("^[^-]*") end

-- Fake extensions -----------------------------------------------------------------------------------------------
local calls = { outcomes = 0, settle = 0, narr = {} }
T.ok(Ext.Register("market", "firstblood", {
  owner = "Test", label = "First blood", lockOn = "fight",
  outcomes = function(ctx)
    calls.outcomes = calls.outcomes + 1
    calls.ctx = ctx
    if not (ctx.a and ctx.b) then return nil, "needs two fighters" end
    return { { label = short(ctx.a) .. " first", ref = ctx.a }, { label = short(ctx.b) .. " first", ref = ctx.b } }
  end,
  settle = function(market, event)
    calls.settle = calls.settle + 1
    calls.market, calls.event = market, event
    if event.type ~= "fight_end" then return nil end
    for i, o in ipairs(market.outcomes) do
      if short(o.ref) == short(event.winner) then return i end
    end
  end,
}))
T.ok(Ext.Register("market", "yesno", { owner = "Test", label = "Hand settled", outcomes = { "Yes", "No" } }))
T.ok(Ext.Register("market", "voider", { owner = "Test", label = "Voider", outcomes = { "Yes", "No" },
  settle = function(_, event) if event.type == "fight_end" then return false end end }))
T.ok(Ext.Register("market", "broken", { owner = "Test", label = "Broken", outcomes = { "Yes", "No" },
  settle = function() error("boom") end }))
T.ok(Ext.Register("market", "badout", { owner = "Test", label = "Bad outcomes", outcomes = function() return nil, "declined" end }))
T.ok(Ext.Register("market", "series_ext", { owner = "Test", label = "Series ext", scope = "series", outcomes = { "A", "B" },
  settle = function(market, event) if event.type == "series_done" then return event.scoreA == 2 and 1 or 2 end end }))
T.ok(Ext.Register("market", "manual_ext", { owner = "Test", label = "Manual ext", outcomes = { "Yes", "No" },
  settle = function(_, event) if event.type == "manual" then return 2 end end }))

T.ok(Ext.Register("narrator", "ext_test_narr", { owner = "Test", lines = function(category, ctx)
  calls.narr[#calls.narr + 1] = category
  calls.nctx = ctx
  if category == "fight_start" then return { "EXT fight: " .. tostring(ctx.a) .. " v " .. tostring(ctx.b) } end
  if category == "kill" or category == "flee" then return { "EXT " .. category .. ": " .. tostring(ctx.winner) } end
  if category == "ring_verdict" then return { "EXT verdict: " .. tostring(ctx.outcome) } end
  if category == "series_done" then return { "EXT series: " .. tostring(ctx.winner) } end
  if category == "ring_dispute" then return { "EXT dispute " .. tostring(ctx.stage) .. ": " .. tostring(ctx.title) } end
  return nil
end }))
T.ok(Ext.Register("narrator", "ext_test_bad", function() error("narrator boom") end))

-- Helpers -------------------------------------------------------------------------------------------------------
local function party(...)
  local names = { ... }
  T.group = { size = #names + 1, raid = false }
  for i = 1, 4 do T.units["party" .. i] = names[i] and { name = names[i], isPlayer = true } or nil end
end

local function lines()
  T.Advance(60)
  local o = {}
  for i, c in ipairs(T.chat) do o[i] = c.text end
  return o
end

local function find(list, pat)
  for i, l in ipairs(list) do if l:find(pat) then return i, l end end
end

local function reset(level)
  D.Cancel()
  if R.session then R.Close(true) end
  T.Advance(120)
  T.chat, T.sent = {}, {}
  T.chatLocked = false
  T.instance = { inInstance = false, type = "none" }
  T.group = { size = 1, raid = false }
  cat.on, cat.level, cat.route = true, level or "headline", "say"
  cfg.cap, cfg.interval = 30, 2.5
  MK.Chat.Clear("bloodsports")
  ns.char.duels, ns.char.streak, ns.char.series, ns.char.challenges = {}, { cur = 0, best = 0, venue = {} }, {}, {}
  A.db.config.bo = 1
  A.db.config.referee.available = true
  A.db.config.ring.currency = "points"
  ns.venues = nil
  T.units.player.health, T.units.player.healthMax = 100, 100
  T.units.target = { name = "Foe", class = "ROGUE", race = "Human", level = 12, isPlayer = true, health = 100, healthMax = 100, faction = "Alliance" }
end

local function startDuel()
  T.Fire("DUEL_REQUESTED", "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 2"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 1"); T.Advance(1.2)
end

local function openRing()
  party("Alice", "Bob")
  local s = R.Open("ratchet")
  T.ok(s, "ring opened")
  R.SetFighters("Fa", "Fb")
  return s
end

-- Ring ----------------------------------------------------------------------------------------------------------

T.test("extension kind: outcomes come from BuildOutcomes, defaults from the definition", function()
  reset()
  local s = openRing()
  local m = R.AddMarket({ kind = "firstblood", open = true })
  T.ok(m, "market created")
  T.eq(m.kind, "firstblood")
  T.eq(m.title, "First blood")
  T.eq(m.lockOn, "fight", "lockOn from the definition")
  T.eq(m.scope, "fight")
  T.eq(#m.outcomes, 2)
  T.eq(m.outcomes[1].label, "Fa first"); T.eq(m.outcomes[1].ref, "Fa-Normal")
  T.eq(m.outcomes[2].label, "Fb first")
  T.eq(calls.ctx.a, "Fa-Normal"); T.eq(calls.ctx.b, "Fb-Normal"); T.eq(calls.ctx.session, s.id)
  T.eq(R.Market(m.mid, s).status, "open")
  -- no settle function and no lockOn: manual lock, outcomes as plain labels, referee decides
  local y = R.AddMarket({ kind = "yesno", labels = { "ignored", "ignored" } })
  T.eq(y.lockOn, "manual"); T.eq(y.outcomes[1].label, "Yes"); T.eq(y.outcomes[2].label, "No")
  T.eq(y.status, "draft")
  T.noErrors()
end)

T.test("an unknown kind still falls back to winner; a declining extension refuses the market", function()
  reset()
  openRing()
  local m = R.AddMarket({ kind = "ghost" })
  T.eq(m.kind, "winner"); T.eq(m.outcomes[1].label, "Fa")
  local ok, why = R.AddMarket({ kind = "badout" })
  T.eq(ok, false); T.eq(why, "outcomes")
  T.eq(R.Market("m3"), nil, "no market left behind")
  T.noErrors()
end)

T.test("settle hook: fight_end gives an auto verdict, nil leaves it to the referee, false voids, errors are ignored", function()
  reset()
  local s = openRing()
  local fb = R.AddMarket({ kind = "firstblood", open = true })
  local yes = R.AddMarket({ kind = "yesno", open = true })
  local vo = R.AddMarket({ kind = "voider", open = true })
  local br = R.AddMarket({ kind = "broken", open = true })
  local win = R.AddMarket({ kind = "winner", open = true })
  T.Fire("CHAT_MSG_SYSTEM", "Stranger has defeated Other in a duel")
  T.eq(calls.settle, 0, "unrelated duel: the hook is not asked")
  T.eq(fb.status, "open")
  calls.settle = 0
  T.Fire("CHAT_MSG_SYSTEM", "Fb has defeated Fa in a duel")
  T.eq(calls.event.type, "fight_end"); T.eq(calls.event.winner, "Fb"); T.eq(calls.event.loser, "Fa")
  T.eq(calls.market.kind, "firstblood"); T.eq(#calls.market.outcomes, 2); T.eq(calls.market.outcomes[2].ref, "Fb-Normal")
  T.eq(fb.status, "resolving"); T.eq(fb.result, 2); T.ok(fb.auto, "auto verdict")
  T.eq(yes.status, "open", "no settle function: referee decides")
  T.eq(vo.status, "void", "settle returned false"); T.eq(vo.voidReason, "extension")
  T.eq(br.status, "open", "an erroring settle changes nothing")
  T.eq(win.status, "resolving", "built-in winner market unchanged"); T.eq(win.result, 2)
  T.ok(R.Verdict(yes.mid, 1), "referee still settles the hand-settled market")
  T.eq(yes.result, 1)
  T.Advance(601)
  T.eq(fb.status, "settled")
  T.noErrors()
end)

T.test("fight events skip an extension market about other fighters; series and manual events reach theirs", function()
  reset()
  local s = openRing()
  local other = R.AddMarket({ kind = "firstblood", a = "Zed-Normal", b = "Yan-Normal", open = true })
  T.eq(other.outcomes[1].ref, "Zed-Normal")
  T.Fire("CHAT_MSG_SYSTEM", "Fa has defeated Fb in a duel")
  T.eq(other.status, "open", "the duel was not between its fighters")
  local man = R.AddMarket({ kind = "manual_ext", open = true })
  T.ok(R.ExtSettle({ type = "manual" }))
  T.eq(man.status, "resolving"); T.eq(man.result, 2); T.eq(calls.event.type, "manual")
  T.eq(other.status, "open", "firstblood returns nil for a manual event")
  R.Close(true)
  -- series scope
  reset()
  A.db.config.bo = 3
  openRing()
  startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel"); T.Advance(10)
  local sm = R.AddMarket({ kind = "series_ext", open = true })
  T.ok(sm, "series market"); T.eq(sm.scope, "series")
  startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel"); T.Advance(10)
  T.eq(sm.status, "resolving"); T.eq(sm.result, 1); T.ok(sm.auto)
  T.noErrors()
end)

T.test("MK.Ext missing (older MetaKit copy): built-in flow untouched, extension kind degrades to winner, no error", function()
  reset()
  local saved = MK.Ext
  MK.Ext = nil
  openRing()
  local m = R.AddMarket({ kind = "firstblood", open = true })
  T.eq(m.kind, "winner")
  local w = R.AddMarket({ kind = "winner", open = true })
  T.Fire("CHAT_MSG_SYSTEM", "Fa has defeated Fb in a duel")
  T.eq(w.status, "resolving"); T.eq(w.result, 1)
  T.eq(R.ExtSettle({ type = "manual" }), true)
  MK.Ext = saved
  T.noErrors()
end)

-- Narrator ------------------------------------------------------------------------------------------------------

T.test("narrator: provider lines follow our own line for the same event, in order, through the sink", function()
  reset("headline")
  calls.narr = {}
  startDuel()
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  local l = lines()
  T.eq(#l, 4, table.concat(l, " / "))
  T.eq(l[1], "Duel: Tester vs Foe. Fight!")
  T.eq(l[2], "EXT fight: Tester v Foe")
  T.ok(l[3]:find("^Tester defeats Foe by knockout"), l[3])
  T.eq(l[4], "EXT kill: Tester")
  T.eq(calls.nctx.source, "bloodsports")
  for i = 2, #T.chat do T.ok(T.chat[i].t - T.chat[i - 1].t >= 2.49, "paced: line " .. i) end
  for _, c in ipairs(T.chat) do T.eq(c.chatType, "SAY") end
  T.noErrors()
end)

T.test("narrator: a fled duel asks for flee, a loss names the opponent as winner; the failing provider is skipped", function()
  reset("headline")
  startDuel()
  T.Fire("CHAT_MSG_SYSTEM", "Foe has fled from Tester in a duel")   -- arg order: Tester wins by retreat
  local l = lines()
  T.ok(find(l, "^Tester wins") or find(l, "fled"), table.concat(l, " / "))
  T.ok(find(l, "^EXT flee: Tester$"), table.concat(l, " / "))
  reset("headline")
  startDuel()
  T.Fire("CHAT_MSG_SYSTEM", "Foe has defeated Tester in a duel")
  l = lines()
  T.ok(find(l, "^EXT kill: Foe$"), table.concat(l, " / "))
  T.noErrors()
end)

T.test("narrator: the level gate holds (off: nothing at all) and a called-off duel gets no provider line", function()
  reset("off")
  startDuel()
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  T.eq(#lines(), 0)
  reset("headline")
  startDuel()
  D.Cancel()
  local l = lines()
  T.eq(find(l, "^EXT kill"), nil)
  T.noErrors()
end)

T.test("narrator: ring verdict line comes after ours, on the ring's scope", function()
  reset("headline")
  local s = openRing()
  T.Advance(3)
  T.ok(R.Lock()); T.Advance(3)
  T.ok(R.Verdict("Fa")); T.Advance(3)
  local l = lines()
  local i = find(l, "^Verdict on Winner: Fa!$")
  T.ok(i, table.concat(l, " / "))
  T.eq(l[i + 1], "EXT verdict: Fa")
  R.Close(true)
  T.noErrors()
end)

T.test("narrator: ring dispute lines get a ring_dispute provider line for each stage", function()
  reset("headline")
  local s = openRing()
  party("Alice", "Bob")
  T.Deliver("BSPT", table.concat({ "RB", s.id, "Fa", "100" }, "\t"), "WHISPER", "Alice-Normal")
  T.Deliver("BSPT", table.concat({ "RB", s.id, "Fb", "50" }, "\t"), "WHISPER", "Bob-Normal")
  T.Advance(3)
  T.ok(R.Lock()); T.Advance(3)
  T.ok(R.Verdict("Fa")); T.Advance(3)
  T.Deliver("BSPT", table.concat({ "R2D", s.id, "m1", "wrong", "" }, "\t"), "WHISPER", "Bob-Normal"); T.Advance(3)
  T.ok(R.ResolveDispute("m1", "uphold")); T.Advance(3)
  local l = lines()
  local i = find(l, "^The verdict for Winner is disputed")
  T.ok(i, table.concat(l, " / "))
  T.eq(l[i + 1], "EXT dispute disputed: Winner")
  local j = find(l, "^The referee upholds the verdict%.$")
  T.ok(j, table.concat(l, " / "))
  T.eq(l[j + 1], "EXT dispute upheld: Winner")
  R.Close(true)
  T.noErrors()
end)

T.test("narrator: MK.Ext missing leaves only our own lines", function()
  reset("headline")
  local saved = MK.Ext
  MK.Ext = nil
  startDuel()
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  local l = lines()
  MK.Ext = saved
  T.eq(#l, 2, table.concat(l, " / "))
  T.eq(find(l, "^EXT"), nil)
  T.noErrors()
end)

T.done()
