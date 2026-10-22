-- Duel engine flows driven through the stub: challenged/challenger paths, knockout/retreat, cancel, void, timeout, OOB, secret HP.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc", { login = false })
local MK = MetaKit

-- Faithful minimal fakes, only when A2's modules are absent (see Strings.lua / Comm.lua contracts).
if not MK.Match then
  function MK.GS(n) return _G[n] or (MK.GlobalStringsFallback or {})[n] end
  function MK.Match(name, text)
    if type(text) ~= "string" or MK.IsSecret(text) then return nil end
    local fmt = MK.GS(name)
    if not fmt then return nil end
    local order, n = {}, 0
    local pat = fmt:gsub("[%^%(%)%.%[%]%*%+%-%?]", "%%%0")
    pat = pat:gsub("%%(%d*)%$?([sd])", function(p, c)
      n = n + 1
      order[n] = tonumber(p) or n
      return c == "s" and "(.+)" or "(%-?%d+)"
    end)
    local caps = { text:match("^" .. pat .. "$") }
    if #caps == 0 then return nil end
    if n == 0 then return true end
    local args = {}
    for i = 1, n do args[order[i]] = caps[i] end
    return unpack(args, 1, n)
  end
end
if not MK.Comm then
  MK.Comm = { New = function(A, prefix)
    local c = { handlers = {} }
    function c:On(t, fn) self.handlers[t] = self.handlers[t] or {}; table.insert(self.handlers[t], fn) end
    function c:Send(t, f, ch, target)
      local msg = t
      for _, v in ipairs(f) do msg = msg .. "\t" .. v end
      C_ChatInfo.SendAddonMessage(prefix, msg, ch, target)
      return true
    end
    A:On("CHAT_MSG_ADDON", function(_, p, text, ch, sender)
      if p ~= prefix then return end
      local f = { strsplit("\t", text) }
      local t = table.remove(f, 1)
      for _, fn in ipairs(c.handlers[t] or {}) do fn(MK.FullName(sender), f, ch) end
    end)
    return c
  end }
end
T.Fire("PLAYER_LOGIN")
T.Fire("PLAYER_ENTERING_WORLD", true, false)

local D = ns.Duel
local log = {}
for _, m in ipairs({ "DUEL_STARTED", "DUEL_COUNTDOWN", "DUEL_RESOLVED" }) do
  ns.A:Listen(m, function(rec) table.insert(log, { m, rec }) end)
end
local function count(m) local n = 0 for _, e in ipairs(log) do if e[1] == m then n = n + 1 end end return n end

local function fresh()
  D.Cancel()
  T.Advance(70)
  ns.char.duels, ns.char.streak = {}, { cur = 0, best = 0, venue = {} }
  log = {}
  T.sent = {}
  T.units.player.health, T.units.player.healthMax = 100, 100
  T.units.target = { name = "Foe", class = "ROGUE", race = "Human", level = 12, isPlayer = true, health = 100, healthMax = 100, faction = "Alliance" }
  T.units.focus = nil
  T.group = { size = 1, raid = false }
  ns.venues = nil
end

local function startDuel()
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 2"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 1"); T.Advance(1.2)
end

local function hp(unit, v) T.units[unit].health = v; T.Fire("UNIT_HEALTH", unit); T.Advance(0.5) end

T.test("challenged path: win by knockout with full sampling", function()
  fresh()
  T.group = { size = 3, raid = false }
  ns.venues = { Current = function() return { id = "crossroads", kind = "practice" } end, Snapshot = function() return { mapID = 1413 } end }
  T.Fire("DUEL_REQUESTED", "Foe")
  T.eq(D.state, "REQUESTED")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3")
  T.eq(D.state, "COUNTDOWN"); T.eq(count("DUEL_COUNTDOWN"), 1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 2"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 1"); T.Advance(0.9)
  T.eq(D.state, "COUNTDOWN"); T.eq(count("DUEL_COUNTDOWN"), 1, "countdown fires once")
  T.Advance(0.2)
  T.eq(D.state, "ACTIVE"); T.eq(count("DUEL_STARTED"), 1)
  hp("target", 80); hp("player", 50); hp("player", 15); hp("target", 1)
  T.Fire("DUEL_FINISHED")
  T.eq(D.state, "ENDING")
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  T.eq(D.state, "IDLE")
  local rec = ns.char.duels[1]
  T.ok(rec, "saved")
  T.eq(rec.result, "win"); T.eq(rec.how, "knockout"); T.eq(rec.firstBlood, "opp")
  T.eq(rec.me.minHp, 15); T.eq(rec.comeback, true); T.eq(rec.opp.hpEnd, 1); T.eq(rec.opp.minHp, 1)
  T.eq(rec.opp.name, "Foe"); T.eq(rec.opp.class, "ROGUE"); T.eq(rec.opp.level, 12); T.eq(rec.me.class, "WARRIOR")
  T.eq(rec.venue, "crossroads"); T.eq(rec.venueKind, "practice"); T.eq(rec.map.mapID, 1413)
  T.eq(rec.group.size, 3); T.eq(rec.confirmed, "self"); T.eq(rec.v, ns.VERSION)
  T.ok(rec.dur >= 2 and rec.dur < 10, "dur " .. tostring(rec.dur)); T.ok(rec.id and #rec.id >= 8, "id"); T.ok(rec.t > 0)
  T.eq(ns.char.streak.cur, 1); T.eq(ns.char.streak.best, 1); T.eq(ns.char.streak.venue.crossroads, 1)
  T.eq(count("DUEL_RESOLVED"), 1)
  local pushed
  for _, row in ipairs(ns.A.db.outbox.rows) do if row.kind == "duel" and row.data == rec then pushed = true end end
  T.ok(pushed, "outbox row")
  T.noErrors()
end)

T.test("we challenged (no DUEL_REQUESTED): loss by retreat, message before DUEL_FINISHED", function()
  fresh()
  ns.char.streak.cur, ns.char.streak.best = 4, 4
  T.Fire("CHAT_MSG_SYSTEM", "You have requested a duel.")
  T.eq(D.state, "REQUESTED"); T.eq(D.rec.opp.name, "Foe"); T.eq(D.rec.opp.class, "ROGUE")
  startDuel()
  T.eq(D.state, "ACTIVE")
  hp("player", 90)
  T.Fire("CHAT_MSG_SYSTEM", "Tester has fled from Foe in a duel") -- RETREAT: %1 = winner (Foe), %2 = loser (Tester)
  T.eq(D.state, "IDLE")
  local rec = ns.char.duels[1]
  T.eq(rec.result, "loss"); T.eq(rec.how, "retreat"); T.eq(rec.firstBlood, "me"); T.eq(rec.comeback, false)
  T.eq(ns.char.streak.cur, 0); T.eq(ns.char.streak.best, 4)
  T.Fire("DUEL_FINISHED") -- late finish after resolution is ignored
  T.eq(#ns.char.duels, 1)
  T.noErrors()
end)

T.test("retreat where the opponent fled is a win", function()
  fresh()
  T.Fire("DUEL_REQUESTED", "Foe"); startDuel()
  T.Fire("CHAT_MSG_SYSTEM", "Foe has fled from Tester in a duel")
  T.eq(ns.char.duels[1].result, "win"); T.eq(ns.char.duels[1].how, "retreat")
end)

T.test("other people's duel messages are ignored", function()
  fresh()
  T.Fire("DUEL_REQUESTED", "Foe"); startDuel()
  T.Fire("CHAT_MSG_SYSTEM", "Bob has defeated Alice in a duel")
  T.Fire("CHAT_MSG_SYSTEM", "Bob has defeated Foe in a duel")
  T.eq(D.state, "ACTIVE"); T.eq(#ns.char.duels, 0)
  D.Cancel()
end)

T.test("cancel: ERR_DUEL_CANCELLED, request timeout and decline record nothing", function()
  fresh()
  T.Fire("DUEL_REQUESTED", "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel canceled.")
  T.eq(D.state, "IDLE")
  T.Fire("CHAT_MSG_SYSTEM", "You have requested a duel.")
  T.eq(D.state, "REQUESTED")
  T.Advance(61)
  T.eq(D.state, "IDLE")
  T.Fire("DUEL_REQUESTED", "Foe"); T.Fire("DUEL_FINISHED") -- declined
  T.eq(D.state, "IDLE")
  T.eq(#ns.char.duels, 0); T.eq(count("DUEL_RESOLVED"), 0)
  T.noErrors()
end)

T.test("void: no winner message within 2 s", function()
  fresh()
  ns.char.streak.cur = 2
  T.Fire("DUEL_REQUESTED", "Foe"); startDuel()
  T.Fire("DUEL_FINISHED")
  T.Advance(1.5); T.eq(D.state, "ENDING")
  T.Advance(1)
  T.eq(D.state, "IDLE")
  local rec = ns.char.duels[1]
  T.eq(rec.result, "void"); T.eq(rec.how, "unknown"); T.eq(ns.char.streak.cur, 2, "streak untouched")
  T.eq(count("DUEL_RESOLVED"), 1)
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel") -- too late
  T.eq(#ns.char.duels, 1)
end)

T.test("timeout after 10 minutes", function()
  fresh()
  T.Fire("DUEL_REQUESTED", "Foe"); startDuel()
  T.Advance(601)
  T.eq(D.state, "IDLE")
  T.eq(ns.char.duels[1].result, "void"); T.eq(ns.char.duels[1].how, "timeout")
  T.noErrors()
end)

T.test("out of bounds and back", function()
  fresh()
  T.Fire("DUEL_REQUESTED", "Foe"); startDuel()
  T.Fire("DUEL_OUTOFBOUNDS"); T.eq(D.state, "OOB")
  hp("player", 95)
  T.Fire("DUEL_INBOUNDS"); T.eq(D.state, "ACTIVE")
  T.Fire("DUEL_OUTOFBOUNDS"); T.Fire("DUEL_FINISHED")
  T.Fire("CHAT_MSG_SYSTEM", "Foe has fled from Tester in a duel") -- forfeited by leaving
  local rec = ns.char.duels[1]
  T.eq(rec.result, "win"); T.eq(rec.oob, 2)
end)

T.test("first PLAYER_REGEN_DISABLED starts the duel; focus is used when target changes", function()
  fresh()
  T.Fire("DUEL_REQUESTED", "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3")
  T.Fire("PLAYER_REGEN_DISABLED")
  T.eq(D.state, "ACTIVE")
  T.units.focus = T.units.target
  T.units.target = { name = "Other", health = 100, healthMax = 100, isPlayer = true }
  hp("focus", 60)
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  T.eq(ns.char.duels[1].opp.minHp, 60)
end)

T.test("secret HP mid-duel yields nil fields and no errors", function()
  fresh()
  T.Fire("DUEL_REQUESTED", "Foe")
  T.units.player.health = T.Secret(50)
  T.units.target.health = T.Secret(10)
  startDuel()
  T.Fire("UNIT_HEALTH", "player"); T.Fire("UNIT_HEALTH", "target"); T.Advance(1)
  T.Fire("CHAT_MSG_SYSTEM", T.Secret("Tester has defeated Foe in a duel")) -- secret text ignored
  T.eq(D.state, "ACTIVE")
  T.Fire("DUEL_FINISHED")
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  local rec = ns.char.duels[1]
  T.eq(rec.result, "win")
  T.eq(rec.me.hpEnd, nil); T.eq(rec.me.minHp, nil); T.eq(rec.opp.hpEnd, nil); T.eq(rec.firstBlood, nil); T.eq(rec.comeback, false)
  T.noErrors()
end)

T.test("secret opponent name in DUEL_REQUESTED: name recovered from the target", function()
  fresh()
  T.Fire("DUEL_REQUESTED", T.Secret("Foe"))
  T.eq(D.state, "REQUESTED")
  T.eq(D.rec.opp.name, "Foe")
  D.Cancel()
  T.noErrors()
end)

T.done()
