-- Narrator.lua: duel / series / ring events -> MK.Chat lines. Drives the real Duel, Series and Ring modules through the
-- stub (system messages, health, ring API), so the mapping is checked against what the engine really fires.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 5 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 100 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } } } }
local MK = MetaKit
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc", { login = false })
MK = MetaKit
local settings
do
  local orig = MK.UI.Settings
  MK.UI.Settings = function(o) settings = o; return orig(o) end
end
T.Fire("PLAYER_LOGIN")
T.Fire("PLAYER_ENTERING_WORLD", true, false)
local A, D, R, S, N = ns.A, ns.Duel, ns.Ring, ns.Series, ns.Narrator
local cfg = A.db.config.chat
local cat = cfg.cats.bloodsports

local function lines()
  T.Advance(40)   -- let the pacing queue drain
  local o = {}
  for i, c in ipairs(T.chat) do o[i] = c.text end
  return o
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

local function hp(unit, v) T.units[unit].health = v; T.Fire("UNIT_HEALTH", unit) end

local function find(list, pat)
  for i, l in ipairs(list) do if l:find(pat) then return i, l end end
end

T.test("category is configured on the shared sink with headline as the default level", function()
  T.eq(MK.Chat.Cat("bloodsports"), cat)
  T.eq(cfg.channelName, "WoMRing"); T.eq(cfg.interval, 2.5)
  T.eq(N.Level(), 1)
end)

T.test("duel at headline level: start, first blood, under-20% beat, finish; nothing else, paced", function()
  reset("headline")
  startDuel()
  hp("player", 85); T.Advance(1)           -- I bled first: the opponent drew first blood
  hp("target", 60); T.Advance(1)           -- 50% is a full-level beat only
  hp("target", 15); T.Advance(1)
  hp("player", 45); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  local l = lines()
  T.eq(#l, 4, table.concat(l, " / "))
  T.eq(l[1], "Duel: Tester vs Foe. Fight!")
  T.eq(l[2], "First blood to Foe!")
  T.eq(l[3], "Foe is on the ropes, under 20% health!")
  T.ok(l[4]:find("^Tester defeats Foe by knockout in %d+s%.$"), l[4])
  for i = 2, #T.chat do T.ok(T.chat[i].t - T.chat[i - 1].t >= 2.49, "paced: line " .. i) end
  for _, c in ipairs(T.chat) do T.eq(c.chatType, "SAY") end
  T.noErrors()
end)

T.test("full level adds the countdown, the half-health beat and my final health", function()
  reset("full")
  startDuel()
  hp("player", 45); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Foe has defeated Tester in a duel")
  local l = lines()
  T.ok(find(l, "^Duel incoming: Tester vs Foe%. Get ready!$"), "countdown")
  T.ok(find(l, "^First blood to Foe!$"))
  T.ok(find(l, "^Tester is down to half health%.$"), "half")
  T.ok(find(l, "^Foe defeats Tester by knockout"), "loss line")
  T.ok(find(l, "^Tester finished on 45%% health%.$"), "final hp")
end)

T.test("a retreat, a comeback and a void each read right", function()
  reset("headline")
  startDuel(); hp("player", 10); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Foe has fled from Tester in a duel")
  local l = lines()
  T.ok(find(l, "^Tester is on the ropes"), "my own low-health beat")
  T.ok(find(l, "^Foe fled! Tester wins in %d+s%. What a comeback!$"), table.concat(l, " / "))
  reset("headline")
  startDuel(); T.Fire("DUEL_FINISHED"); T.Advance(3)
  l = lines()
  T.ok(find(l, "^The duel was called off, no result%.$"), table.concat(l, " / "))
end)

T.test("off level and the category toggle say nothing; a lockdown mid-fight mutes the rest", function()
  reset("off")
  startDuel(); hp("player", 10); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  T.eq(#lines(), 0, "level off")
  reset("headline"); cat.on = false
  startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  T.eq(#lines(), 0, "category off")
  reset("headline")
  startDuel()                      -- the start line goes out
  T.chatLocked = true              -- then chat locks (e.g. an encounter starts)
  hp("player", 10); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  local l = lines()
  T.eq(#l, 1, table.concat(l, " / "))
  T.eq(l[1], "Duel: Tester vs Foe. Fight!")
  reset("headline")
  T.instance = { inInstance = true, type = "arena" }
  startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  T.eq(#lines(), 0, "arena")
end)

T.test("hard cap per duel: extra beats are dropped (even the result), the next duel gets a fresh budget", function()
  reset("full")
  cfg.cap = 3
  startDuel()
  hp("player", 85); T.Advance(1); hp("target", 15); T.Advance(1); hp("player", 45); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  local l = lines(); T.eq(#l, 3, "countdown + start + one beat, then silence: " .. table.concat(l, " / "))
  T.ok(MK.Chat.Stats().dropped.cap >= 2)
  T.chat = {}
  cat.level = "headline"
  startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  local l = lines()
  T.eq(#l, 2, "fresh scope: start and result")
end)

T.test("best-of series at headline: round tags and the result, no round-by-round or series-start line", function()
  reset("headline")
  A.db.config.bo = 3
  for _ = 1, 2 do
    startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel"); T.Advance(10)
  end
  local l = lines()
  T.ok(find(l, "^Round 1 of BO3: Tester vs Foe%. Fight!$"), table.concat(l, " / "))
  T.ok(find(l, "^Round 2 of BO3: Tester vs Foe%. Fight!$"))
  T.ok(find(l, "^Tester wins the best%-of%-3 series 2%-0!$"))
  T.eq(find(l, "^Round %d to"), nil, "round results are full-level")
  T.eq(find(l, "^Best of 3"), nil, "series start is full-level (not a champion challenge)")
end)

T.test("best-of series at full: start and round lines, a lost series, a cancelled series; a bo1 adds no series line", function()
  reset("full")
  A.db.config.bo = 3
  startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Foe has defeated Tester in a duel"); T.Advance(10)
  startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel"); T.Advance(10)
  startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Foe has defeated Tester in a duel"); T.Advance(10)
  local l = lines()
  T.ok(find(l, "^Best of 3: Tester vs Foe%.$"), "series start")
  T.ok(find(l, "^Round 1 to Foe%. Series 0%-1%.$"))
  T.ok(find(l, "^Round 2 to Tester%. Series 1%-1%.$"))
  T.ok(find(l, "^Foe wins the best%-of%-3 series 2%-1!$"), table.concat(l, " / "))
  reset("headline")
  A.db.config.bo = 5
  startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel"); T.Advance(10)
  S.Cancel("cancelled")
  l = lines()
  T.ok(find(l, "^The best%-of%-5 series was called off%.$"), table.concat(l, " / "))
  reset("headline")                -- bo1: duel lines only
  startDuel(); T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  l = lines()
  T.eq(#l, 2); T.eq(find(l, "best%-of"), nil)
end)

---------------------------------------------------------------------------
-- Ring

local function deliver(sender, text) T.Deliver("BSPT", text, "WHISPER", sender) end
local function party(...)
  local names = { ... }
  T.group = { size = #names + 1, raid = false }
  for i = 1, 4 do T.units["party" .. i] = names[i] and { name = names[i], isPlayer = true } or nil end
end

T.test("hosted public ring: opened, betting open, locked, verdict, payouts summary, in order", function()
  reset("headline")
  A.db.config.referee.available = true
  A.db.config.ring.currency = "points"
  party("Alice", "Bob")
  local s = R.Open("ratchet")
  T.ok(s, "ring opened")
  R.SetFighters("Fa", "Fb")
  T.Advance(3)
  deliver("Alice-Normal", table.concat({ "RB", s.id, "Fa", "100" }, "\t"))
  deliver("Bob-Normal", table.concat({ "RB", s.id, "Fb", "50" }, "\t"))
  T.Advance(3)
  T.ok(R.Lock()); T.Advance(3)
  T.ok(R.Verdict("Fa")); T.Advance(601)
  local m = R.Market("m1", s)
  T.eq(m.status, "settled")
  local paid = 0
  for _, b in ipairs(m.bets) do paid = paid + (b.payout or 0) end
  local l = lines()
  T.eq(#l, 5, table.concat(l, " / "))
  T.eq(l[1], "Tester opens a betting ring (points, bets up to 1000 pts).")
  T.eq(l[2], "Betting is OPEN on Winner: Fa / Fb.")
  T.eq(l[3], "Bets LOCKED on Winner. Fight!")
  T.eq(l[4], "Verdict on Winner: Fa!")
  T.eq(l[5], string.format("Winner settled: 2 bets, %d pts paid out.", paid))
  T.eq(paid, 150, "pari pool paid out")
  T.eq(T.chat[1].chatType, "SAY")
  R.Close(true)
end)

T.test("full level adds the pool at lock, and the ring-closed line", function()
  reset("full")
  A.db.config.ring.currency = "points"
  party("Alice")
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb")
  deliver("Alice-Normal", table.concat({ "RB", s.id, "Fa", "40" }, "\t")); T.Advance(3)
  R.Lock(); T.Advance(3)
  R.Close(true)
  local l = lines()
  T.ok(find(l, "^Bets LOCKED on Winner: 1 bets, 40 pts in the pool%. Fight!$"), table.concat(l, " / "))
  T.ok(find(l, "^The ring is closed%."), table.concat(l, " / "))
end)

T.test("a private ring speaks to the group, never to /say; alone it says nothing", function()
  reset("headline")
  A.db.config.ring.currency = "points"
  A.db.config.ring.public = false
  party("Alice", "Bob")
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb"); T.Advance(3)
  R.Lock(); T.Advance(3)
  lines()
  T.ok(#T.chat >= 3)
  for _, c in ipairs(T.chat) do T.eq(c.chatType, "PARTY") end
  R.Close(true)
  reset("headline")
  A.db.config.ring.public = false
  party()
  T.group = { size = 1, raid = false }
  R.Open("ratchet"); R.SetFighters("Fa", "Fb"); R.Lock()
  T.eq(#lines(), 0, "no group, private ring: nothing is said")
  R.Close(true)
  A.db.config.ring.public = true
end)

T.test("a ring that was already running (reload) is adopted silently; later changes are announced", function()
  reset("headline")
  A.db.config.ring.currency = "points"
  party("Alice")
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb"); T.Advance(60)
  T.chat = {}
  local live = R.session
  R.session = nil; A:Fire("RING_UPDATED")        -- the narrator forgets (as after a reload)
  R.session = live; A:Fire("RING_UPDATED")
  T.eq(#lines(), 0, "old session adopted without a replay")
  R.Lock()
  local l = lines()
  T.eq(#l, 1); T.eq(l[1], "Bets LOCKED on Winner. Fight!")
  R.Close(true)
end)

T.test("a void market is announced as a refund; a joined (non-host) ring is never narrated", function()
  reset("headline")
  A.db.config.ring.currency = "points"
  local s = R.Open("ratchet")
  R.SetFighters("Fa", "Fb"); T.Advance(3)
  R.Void(); 
  local l = lines()
  T.ok(find(l, "^Winner is void, all bets refunded%.$"), table.concat(l, " / "))
  R.Close(true)
  reset("headline")
  T.Deliver("BSPT", "RS\tabc999\topen\tratchet\tpoints\tFa-Normal\tFb-Normal\t0\t0\t0\t\t1000", "PARTY", "Host-Normal")
  T.Advance(60)
  A:Fire("RING_UPDATED")
  T.eq(#lines(), 0, "mirror of somebody else's ring")
end)

T.test("settings: chat toggle, level, route and pacing map onto config.chat", function()
  T.ok(settings, "Bloodsports settings registered")
  local keys = {}
  for _, o in ipairs(settings.options) do if o.key then keys[o.key] = o end end
  for _, k in ipairs({ "chatOn", "chatLevel", "chatRoute", "chatInterval" }) do T.ok(keys[k], k) end
  T.eq(keys.chatLevel.min, 0); T.eq(keys.chatLevel.max, 2); T.eq(keys.chatRoute.min, 1); T.eq(keys.chatRoute.max, 5)
  local db = settings.db
  cat.on, cat.level, cat.route = true, "headline", "say"
  T.eq(db.chatOn, true); T.eq(db.chatLevel, 1); T.eq(db.chatRoute, 1)
  db.chatLevel = 2; T.eq(cat.level, "full")
  db.chatLevel = 0; T.eq(cat.level, "off"); T.eq(db.chatLevel, 0)
  db.chatLevel = 1; T.eq(cat.level, "headline")
  db.chatRoute = 3; T.eq(cat.route, "group"); T.eq(db.chatRoute, 3)
  db.chatRoute = 4; T.eq(cat.route, "channel")
  db.chatRoute = 5; T.eq(cat.route, "local")
  db.chatRoute = 1; T.eq(cat.route, "say")
  db.chatOn = false; T.eq(cat.on, false)
  db.chatOn = true
  db.chatInterval = 6; T.eq(cfg.interval, 6); T.eq(db.chatInterval, 6)
  cfg.interval = 2.5
  cat.level = "bogus"; T.eq(db.chatLevel, 1, "an unknown level reads as headline, like the narrator treats it")
  T.eq(db.minimapHide, false, "existing keys unaffected")
  T.noErrors()
end)

T.done()
