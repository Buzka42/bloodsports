-- Confirm handshake: DH nonce exchange, DR agree/dispute, DV referee verdicts, peers table (comm messages via T.Deliver).
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
local confirmedLog = {}
ns.A:Listen("DUEL_CONFIRMED", function(rec) table.insert(confirmedLog, rec) end)

local function fresh()
  D.Cancel()
  T.Advance(70)
  ns.char.duels, ns.char.streak = {}, { cur = 0, best = 0, venue = {} }
  ns.A.db.referees, ns.A.db.peers = {}, {}
  ns.Ring = nil
  confirmedLog = {}
  T.Advance(130) -- expires stashed early messages
  T.sent = {}
  T.units.player.health, T.units.player.healthMax = 100, 100
  T.units.target = { name = "Foe", class = "ROGUE", race = "Human", level = 12, isPlayer = true, health = 100, healthMax = 100, faction = "Alliance" }
  T.group = { size = 1, raid = false }
end

local function sent(kind)
  local out = {}
  for _, s in ipairs(T.sent) do
    if s.prefix == "BSPT" then
      local f = { strsplit("\t", s.msg) }
      if f[1] == kind then table.remove(f, 1); table.insert(out, { f = f, target = s.target, channel = s.channel }) end
    end
  end
  return out
end

local function deliver(kind, sender, ...)
  T.Deliver("BSPT", kind .. "\t" .. table.concat({ ... }, "\t"), "WHISPER", sender)
end

local function countdownAndHello(oppNonce)
  T.Fire("DUEL_REQUESTED", "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3")
  local dh = sent("DH")[1]
  T.ok(dh, "DH sent at countdown")
  if oppNonce then deliver("DH", "Foe-Normal", oppNonce, "1", "ROGUE", "12") end
  T.Advance(3.2)
  return dh
end

local function win()
  T.Fire("DUEL_FINISHED")
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  return ns.char.duels[#ns.char.duels]
end

T.test("DH at countdown: fields, target, matchId from both nonces; peers recorded", function()
  fresh()
  local dh = countdownAndHello("aaaa1111")
  T.eq(dh.target, "Foe-Normal"); T.eq(dh.channel, "WHISPER")
  T.ok(dh.f[1]:match("^%x%x%x%x%x%x%x%x$"), "nonce 8 hex"); T.eq(dh.f[2], tostring(ns.VERSION))
  T.eq(dh.f[3], "WARRIOR"); T.eq(dh.f[4], "10")
  T.eq(#sent("DH"), 1, "no duplicate DH")
  local mine = dh.f[1]
  local want = mine < "aaaa1111" and (mine .. "aaaa1111") or ("aaaa1111" .. mine)
  local rec = win()
  T.eq(rec.id, want)
  local peer = ns.A.db.peers["Foe-Normal"]
  T.ok(peer, "peer"); T.eq(peer.class, "ROGUE"); T.eq(peer.level, 12); T.eq(peer.version, 1); T.ok(peer.seen)
  T.noErrors()
end)

T.test("DH arriving before our countdown gets a reply and the id is shared", function()
  fresh()
  T.Fire("DUEL_REQUESTED", "Foe")
  deliver("DH", "Foe-Normal", "0000ffff", "1", "ROGUE", "12")
  T.eq(#sent("DH"), 1, "reply")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3")
  T.eq(#sent("DH"), 1, "countdown does not resend")
  T.Advance(3.2)
  local rec = win()
  T.eq(rec.id:sub(1, 8), "0000ffff")
end)

T.test("both confirm: DR sent, agreeing DR upgrades to both", function()
  fresh()
  countdownAndHello("bbbb2222")
  T.units.target.health = 42
  T.Fire("UNIT_HEALTH", "target"); T.Advance(0.6)
  local rec = win()
  local dr = sent("DR")[1]
  T.ok(dr, "DR sent"); T.eq(dr.target, "Foe-Normal")
  T.eq(dr.f[1], rec.id); T.eq(dr.f[2], "Tester"); T.eq(dr.f[3], "knockout"); T.eq(dr.f[4], "100")
  T.eq(rec.confirmed, "self")
  deliver("DR", "Foe-Normal", rec.id, "Tester", "knockout", "42")
  T.eq(rec.confirmed, "both"); T.eq(rec.opp.hpEnd, 42) -- their own report fills nothing: ours (42) is kept
  T.eq(#confirmedLog, 1); T.eq(ns.char.streak.cur, 1)
  local row = ns.A.db.outbox.rows[#ns.A.db.outbox.rows]
  T.eq(row.kind, "duel_confirm"); T.eq(row.data.id, rec.id); T.eq(row.data.confirmed, "both")
  deliver("DR", "Foe-Normal", rec.id, "Tester", "knockout", "42") -- replay is a no-op
  T.eq(#confirmedLog, 1)
  T.noErrors()
end)

T.test("opponent's hpEnd from DR fills a secret/unknown value", function()
  fresh()
  T.Fire("DUEL_REQUESTED", "Foe")
  T.units.target.health = T.Secret(5)
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3")
  local dh = sent("DH")[1]
  deliver("DH", "Foe-Normal", "cccc3333", "1", "ROGUE", "12")
  T.Advance(3.2)
  local rec = win()
  T.eq(rec.opp.hpEnd, nil)
  deliver("DR", "Foe-Normal", rec.id, "Tester", "knockout", "7")
  T.eq(rec.opp.hpEnd, 7); T.eq(rec.confirmed, "both")
end)

T.test("no DH within 5 s: matchId is our nonce and the record stays self", function()
  fresh()
  local dh = countdownAndHello(nil)
  T.Advance(5)
  local rec = win()
  T.eq(rec.id, dh.f[1]); T.eq(rec.confirmed, "self")
  T.eq(#sent("DR"), 1)
end)

T.test("dispute: opponent reports a different winner", function()
  fresh()
  countdownAndHello("dddd4444")
  local rec = win()
  T.eq(ns.char.streak.cur, 1)
  deliver("DR", "Foe-Normal", rec.id, "Foe", "knockout", "")
  T.eq(rec.confirmed, "disputed"); T.eq(ns.char.streak.cur, 0, "disputed win does not count")
  T.eq(#confirmedLog, 1)
  local row = ns.A.db.outbox.rows[#ns.A.db.outbox.rows]
  T.eq(row.data.confirmed, "disputed")
  T.noErrors()
end)

T.test("DR that arrives before our own resolution is applied afterwards", function()
  fresh()
  countdownAndHello("eeee5555")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 1") ; T.Advance(1.2)
  T.eq(D.state, "ACTIVE")
  local id = D.rec.id
  deliver("DR", "Foe-Normal", id, "Tester", "knockout", "30")
  T.Fire("DUEL_FINISHED")
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  local rec = ns.char.duels[1]
  T.eq(rec.confirmed, "both"); T.eq(rec.opp.hpEnd, 100, "our own sample is kept")
end)

T.test("DR from a stranger or with another matchId is ignored", function()
  fresh()
  countdownAndHello("ffff6666")
  local rec = win()
  deliver("DR", "Mallory-Normal", rec.id, "Mallory", "knockout", "")
  deliver("DR", "Foe-Normal", "nonsense", "Foe", "knockout", "")
  T.eq(rec.confirmed, "self"); T.eq(#confirmedLog, 0)
  T.ok(ns.A.db.peers["Mallory-Normal"], "still listed as a peer")
end)

T.test("void duels send no DR", function()
  fresh()
  countdownAndHello("11112222")
  T.Fire("DUEL_FINISHED"); T.Advance(3)
  T.eq(ns.char.duels[1].result, "void")
  T.eq(#sent("DR"), 0)
end)

T.test("referee verdict from db.referees sets confirmed=referee", function()
  fresh()
  ns.A.db.referees["Ref-Normal"] = { seen = 1 }
  countdownAndHello("22223333")
  local rec = win()
  deliver("DV", "Rando-Normal", "", "Tester", "Foe")
  T.eq(rec.confirmed, "self", "non-referee ignored")
  deliver("DV", "Ref-Normal", rec.id, "Tester", "Foe")
  T.eq(rec.confirmed, "referee"); T.eq(rec.referee, "Ref-Normal"); T.eq(rec.result, "win")
  T.eq(#confirmedLog, 1)
  T.eq(ns.A.db.outbox.rows[#ns.A.db.outbox.rows].data.referee, "Ref-Normal")
  T.noErrors()
end)

T.test("referee verdict from the ring host; wrong names or stale times are ignored", function()
  fresh()
  ns.Ring = { session = { host = "Host-Normal" } }
  countdownAndHello(nil)
  local rec = win()
  deliver("DV", "Host-Normal", "", "Alice", "Bob")
  T.eq(rec.confirmed, "self")
  T.Advance(130)
  deliver("DV", "Host-Normal", "", "Tester", "Foe")
  T.eq(rec.confirmed, "self", "older than 120 s")
end)

T.test("referee verdict overrides a disputed result and can flip it", function()
  fresh()
  ns.A.db.referees["Ref-Normal"] = {}
  countdownAndHello("33334444")
  local rec = win()
  deliver("DR", "Foe-Normal", rec.id, "Foe", "knockout", "")
  T.eq(rec.confirmed, "disputed"); T.eq(ns.char.streak.cur, 0)
  deliver("DV", "Ref-Normal", "", "Foe", "Tester")
  T.eq(rec.confirmed, "referee"); T.eq(rec.result, "loss"); T.eq(ns.char.streak.cur, 0)
  deliver("DV", "Ref-Normal", "", "Tester", "Foe") -- already refereed: ignored
  T.eq(rec.result, "loss")
end)

T.test("referee verdict that arrives before our resolution, and a fighter cannot referee", function()
  fresh()
  ns.A.db.referees["Ref-Normal"] = {}
  ns.A.db.referees["Foe-Normal"] = {}
  countdownAndHello("44445555")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 1"); T.Advance(1.2)
  deliver("DV", "Ref-Normal", "", "Tester", "Foe")
  local rec = win()
  T.eq(rec.confirmed, "referee")
  fresh()
  ns.A.db.referees["Foe-Normal"] = {}
  countdownAndHello(nil)
  rec = win()
  deliver("DV", "Foe-Normal", "", "Foe", "Tester")
  T.eq(rec.confirmed, "self")
end)

T.test("referee verdict upgrades a void duel", function()
  fresh()
  ns.A.db.referees["Ref-Normal"] = {}
  countdownAndHello(nil)
  T.Fire("DUEL_FINISHED"); T.Advance(3)
  local rec = ns.char.duels[1]
  T.eq(rec.result, "void")
  deliver("DV", "Ref-Normal", "", "Foe", "Tester")
  T.eq(rec.result, "loss"); T.eq(rec.confirmed, "referee"); T.eq(rec.how, "referee")
end)

T.test("malformed or hostile messages never error", function()
  fresh()
  deliver("DH", "Foe-Normal")
  deliver("DR", "Foe-Normal")
  deliver("DV", "Foe-Normal")
  T.Deliver("BSPT", "DH\t" .. string.rep("x", 200) .. "\t\t\t", "WHISPER", "Foe-Normal")
  T.Deliver("BSPT", "DR", "WHISPER", "Foe-Normal")
  countdownAndHello("zzzz")
  T.noErrors()
end)

T.done()
