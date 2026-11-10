-- Channel / spectator path (contract §4, §8.2): R2A on the WoMRing CHANNEL fills the ring browser; a non-group
-- spectator's R2B is accepted on a public session and refused on a private one; whisper fallback with the channel
-- unjoined (watchers get R2S on status changes only); 31st bettor `full`; flood guard; v1 RB on winner/pari m1;
-- every message type at maximum field widths <= 255 bytes; a v=3 R2S makes the mirror read-only.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local CHAN = 5
GetChannelName = function() return CHAN end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 50 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, R = ns.A, ns.Ring
A.db.config.referee.available = true
A.db.config.ring.currency = "gold"
T.money = 100000000

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

-- Sent messages of type `typ` since index `from`, after draining the comm queue. pred(m) filters channel/target.
local function sent(typ, from, pred)
  T.Advance(60)
  local out = {}
  for i = from or 1, #T.sent do
    local m = T.sent[i]
    if m.msg:sub(1, #typ + 1) == typ .. "\t" and (not pred or pred(m)) then
      out[#out + 1] = { fields = fields(m), channel = m.channel, target = m.target, t = m.t }
    end
  end
  return out
end
local function to(who) return function(m) return m.channel == "WHISPER" and m.target == who end end
local function onChannel(m) return m.channel == "CHANNEL" end

-- CHAT_MSG_ADDON on a numbered chat channel: (prefix, text, "CHANNEL", sender, target, zoneID, localID, name).
local function channelMsg(sender, text, name, localID)
  T.Fire("CHAT_MSG_ADDON", "BSPT", text, "CHANNEL", sender, "", 0, localID or 5, name or "WoMRing", 0)
end
local function deliver(sender, text, channel) T.Deliver("BSPT", text, channel or "WHISPER", sender) end

local nonce = 0
local function r2b(sender, mid, idx, amount, price)
  nonce = nonce + 1
  deliver(sender, table.concat({ "R2B", R.session.id, mid, idx, amount, price or 0, string.format("%04x", nonce) }, "\t"))
  T.Advance(2.1)
  for _, b in ipairs(R.Market(mid).bets) do if b.bettor == sender then return b end end
end

local function fresh(currency)
  if R.session then if R.IsHost() then R.Close(true) else R.Leave() end end
  T.Advance(60)
  A.db.config.ring.currency = currency or "gold"
  A.db.config.ring.public = true
end

local function browserEntry(host)
  for _, e in ipairs(R.Browser()) do if e.host == host then return e end end
end

T.test("R2A on the WoMRing CHANNEL fills the browser; other channels and group chat are ignored", function()
  channelMsg("Bookie-Normal", table.concat({ "R2A", 2, "abc123", "ratchet", "gold", "open", 3, 12, 500000, 3, 1 }, "\t"))
  local e = browserEntry("Bookie-Normal")
  T.ok(e, "browser entry")
  T.eq(e.sid, "abc123"); T.eq(e.venue, "ratchet"); T.eq(e.currency, "gold"); T.eq(e.status, "open")
  T.eq(e.nMarkets, 3); T.eq(e.nBettors, 12); T.eq(e.cap, 500000); T.eq(e.bo, 3); T.eq(e.raid, true)
  T.eq(e.level, 1, "level from the bookie data"); T.eq(e.update, false)
  channelMsg("Other-Normal", table.concat({ "R2A", 2, "abc124", "ratchet", "gold", "open", 1, 1, 500000, 0, 0 }, "\t"),
    "General", 1)
  T.eq(browserEntry("Other-Normal"), nil, "another chat channel is not the ring channel")
  deliver("Party-Normal", table.concat({ "R2A", 2, "abc125", "ratchet", "gold", "open", 1, 1, 500000, 0, 0 }, "\t"), "PARTY")
  T.eq(browserEntry("Party-Normal"), nil, "R2A rides the channel (or a whisper), not group chat")
  channelMsg("Future-Normal", table.concat({ "R2A", 3, "abc126", "ratchet", "points", "open", 1, 1, 1000, 0, 0 }, "\t"))
  T.eq(browserEntry("Future-Normal").update, true, "v > 2 shows 'update Bloodsports'")
end)

T.test("public session: Open announces R2A on the channel; a non-group spectator's R2B is accepted", function()
  fresh("gold")
  party("Ann")
  local mark, t0 = #T.sent + 1, T.clock
  local s = R.Open("ratchet")
  T.ok(type(s) == "table" and s.public, "public by default")
  local r2a = sent("R2A", mark, onChannel)
  T.ok(#r2a >= 1, "R2A on the channel")
  T.eq(r2a[1].t, t0, "announced at Open"); T.eq(r2a[1].target, 5)
  T.eq(r2a[1].fields[1], "2"); T.eq(r2a[1].fields[2], s.id); T.eq(r2a[1].fields[5], "open")
  for i = 2, #r2a do T.ok(r2a[i].t - r2a[i - 1].t >= 60, "re-announced every 60 s, not faster") end
  T.ok(R.SetFighters("Fa", "Fb"))
  mark = #T.sent + 1
  local zed = r2b("Zed-Normal", "m1", 1, 100000)
  T.ok(zed, "spectator bet accepted on a public session")
  T.eq(s.watchers[1], "Zed-Normal", "outside bettor becomes a watcher")
  local line = sent("R2L", mark, to("Zed-Normal"))
  T.eq(#line, 1, "own line whispered to the outside bettor"); T.eq(line[1].fields[3], "Zed-Normal")
  T.eq(#sent("R2X", mark, to("Zed-Normal")), 0)
end)

T.test("private session: outside R2B refused (R2X closed); group members still bet", function()
  local s = R.session
  T.ok(R.SetPublic(false))
  local mark = #T.sent + 1
  T.eq(r2b("Yan-Normal", "m1", 1, 100000), nil, "refused")
  local x = sent("R2X", mark, to("Yan-Normal"))
  T.eq(#x, 1); T.eq(x[1].fields[4], "closed")
  T.ok(r2b("Ann-Normal", "m1", 2, 100000), "group member accepted on a private session")
  T.ok(R.SetPublic(true))
end)

T.test("channel joined: state goes to the channel; unjoined: watchers get R2S whispers on status changes only", function()
  local s = R.session
  CHAN = 5
  local mark = #T.sent + 1
  local m2 = R.AddMarket({ kind = "winner", mode = "pari", open = true })
  T.ok(m2, "m2")
  T.ok(#sent("R2S", mark, onChannel) >= 1, "R2S on the channel while it is joined")
  T.ok(#sent("R2M", mark, onChannel) >= 1, "R2M on the channel")
  mark = #T.sent + 1
  T.ok(r2b("Ann-Normal", m2.mid, 1, 100000))
  T.ok(#sent("R2O", mark, onChannel) >= 1, "debounced pool update reaches the channel")

  CHAN = 0 -- slot limit / lockdown: the channel is never required
  T.eq(R.ChannelJoined(), false)
  mark = #T.sent + 1
  T.ok(R.Lock())
  local rs = sent("R2S", mark, to("Zed-Normal"))
  T.ok(#rs >= 1, "watcher gets R2S by whisper on a status change")
  T.eq(rs[#rs].fields[2], s.id)
  T.ok(#sent("R2M", mark, to("Zed-Normal")) >= 1, "and the market headers")
  T.eq(#sent("R2S", mark, onChannel), 0, "nothing on the unjoined channel")
  local m3 = R.AddMarket({ kind = "winner", mode = "pari", open = true })
  mark = #T.sent + 1
  T.ok(r2b("Ann-Normal", m3.mid, 1, 100000))
  T.eq(#sent("R2O", mark, to("Zed-Normal")), 0, "bet-only changes are not whispered to watchers")
  T.eq(#sent("R2S", mark, to("Zed-Normal")), 0)
  CHAN = 5
end)

T.test("31st distinct bettor is refused `full`; a counted bettor may still use another market", function()
  fresh("points")
  CHAN = 0
  party()
  local s = R.Open("ratchet")
  T.ok(R.SetFighters("Fa", "Fb"))
  local m2 = R.AddMarket({ kind = "winner", mode = "pari", open = true })
  for i = 1, 30 do T.ok(r2b("Punter" .. i .. "-Normal", "m1", 1 + i % 2, 10), "bettor " .. i) end
  T.eq(#R.Market("m1").bets, 30)
  local mark = #T.sent + 1
  T.eq(r2b("Punter31-Normal", "m1", 1, 10), nil, "31st refused")
  local x = sent("R2X", mark, to("Punter31-Normal"))
  T.eq(#x, 1); T.eq(x[1].fields[4], "full")
  T.ok(r2b("Punter1-Normal", m2.mid, 1, 10), "already one of the 30: may bet in m2")
  CHAN = 5
end)

T.test("flood: R2B within 2 s dropped; after 5 refusals the 6th gets one R2X flood, then silence", function()
  fresh("gold")
  party()
  local s = R.Open("ratchet")
  T.ok(R.SetFighters("Fa", "Fb"))
  local mark = #T.sent + 1
  deliver("Spam-Normal", table.concat({ "R2B", s.id, "m1", 1, 0, 0, "aaaa" }, "\t"))
  deliver("Spam-Normal", table.concat({ "R2B", s.id, "m1", 1, 0, 0, "aaab" }, "\t"))
  T.eq(#sent("R2X", mark, to("Spam-Normal")), 1, "second R2B inside 2 s dropped")
  for i = 2, 5 do r2b("Spam-Normal", "m1", 1, 5) end -- under 1 g: refused `amount`
  local x = sent("R2X", mark, to("Spam-Normal"))
  T.eq(#x, 5)
  for _, r in ipairs(x) do T.eq(r.fields[4], "amount") end
  T.eq(r2b("Spam-Normal", "m1", 1, 5), nil)
  x = sent("R2X", mark, to("Spam-Normal"))
  T.eq(#x, 6); T.eq(x[6].fields[4], "flood", "6th refused R2B silences the sender")
  T.eq(r2b("Spam-Normal", "m1", 1, 100000), nil, "silenced: even a valid bet is ignored")
  T.eq(#sent("R2X", mark, to("Spam-Normal")), 6, "exactly one flood reply")
  T.ok(r2b("Calm-Normal", "m1", 1, 100000), "other senders unaffected")
end)

T.test("v1 RB on winner/pari m1 is accepted and RS/RL are still emitted; RB on a fixed m1 is refused silently", function()
  fresh("gold")
  party("Ann", "Bob")
  local s = R.Open("ratchet")
  T.ok(R.SetFighters("Fa", "Fb"))
  local mark = #T.sent + 1
  deliver("Ann-Normal", table.concat({ "RB", s.id, "Fa-Normal", 100000 }, "\t"))
  T.Advance(2.1)
  local b = R.Market("m1").bets[1]
  T.ok(b, "v1 RB accepted"); T.eq(b.bettor, "Ann-Normal"); T.eq(b.outcome, 1); T.eq(b.amount, 100000)
  local rl = sent("RL", mark, function(m) return m.channel == "PARTY" end)
  T.ok(#rl >= 1, "v1 RL emitted"); T.eq(rl[1].fields[2], "Ann-Normal"); T.eq(rl[1].fields[3], "Fa-Normal")
  local rs = sent("RS", mark, function(m) return m.channel == "PARTY" end)
  T.ok(#rs >= 1, "v1 RS emitted"); T.eq(rs[#rs].fields[1], s.id)
  T.ok(#sent("R2L", mark, function(m) return m.channel == "PARTY" end) >= 1, "v2 line too")
  deliver("Out-Normal", table.concat({ "RB", s.id, "Fa-Normal", 100000 }, "\t"))
  T.Advance(2.1)
  T.eq(#R.Market("m1").bets, 1, "v1 RB stays a group-only path")

  fresh("gold")
  party("Ann", "Bob")
  s = R.Open("ratchet")
  local m = R.AddMarket({ kind = "winner", a = "Fa", b = "Fb", mode = "fixed", prices = { 180, 210 }, bank = 250000, open = true })
  T.eq(m.mid, "m1")
  mark = #T.sent + 1
  deliver("Bob-Normal", table.concat({ "RB", s.id, "Fa-Normal", 100000 }, "\t"))
  T.Advance(2.1)
  T.eq(#m.bets, 0, "v1 RB on a fixed m1 refused")
  T.eq(#sent("R2X", mark, to("Bob-Normal")), 0, "silently: v1 has no R2X")
  T.eq(#sent("RS", mark), 0, "no v1 state for a fixed m1")
end)

-- True when s is valid UTF-8 (no split multi-byte sequence).
local function validUtf8(s)
  local i, n = 1, #s
  while i <= n do
    local c = s:byte(i)
    local len = c < 0x80 and 1 or c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 0
    if len == 0 or i + len - 1 > n then return false end
    for j = i + 1, i + len - 1 do
      local d = s:byte(j)
      if d < 0x80 or d >= 0xC0 then return false end
    end
    i = i + len
  end
  return true
end

T.test("every message type at maximum field widths stays <= 255 bytes; text truncates on UTF-8 boundaries", function()
  local W = R.Wire
  local BIG = 1e12
  local name = "a" .. string.rep("\195\169", 40) .. "-Realm" -- 87 bytes, 2-byte chars
  local s = { id = string.rep("f", 16), venue = string.rep("v", 40), currency = "points", status = "closing", cap = BIG,
    series = { id = string.rep("s", 30), bo = 5 }, rev = BIG, public = true, raidOpen = true, autoInvite = true,
    isHost = true, markets = {} }
  for k = 1, 8 do
    local m = { mid = "m" .. k, kind = "custom", scope = "series", mode = "fixed", status = "resolving", result = 8,
      fight = BIG, lockAt = BIG, appealUntil = BIG, bank = BIG, rev = BIG, title = "a" .. string.rep("\195\188", 40),
      outcomes = {}, bets = {} }
    for i = 1, 8 do m.outcomes[i] = { label = "a" .. string.rep("\195\169", 30), price = 1000 } end
    for i = 1, 30 do
      m.bets[i] = { bettor = i .. name, outcome = 8, amount = BIG, price = 1000, paid = true, void = true, paidOut = true,
        payout = BIG, paidOutAmount = BIG, rev = BIG }
    end
    s.markets[m.mid] = m
  end
  local m, b = s.markets.m8, s.markets.m8.bets[30]
  local msgs = {
    R2A = W.R2A(s), R2S = W.R2S(s), R2M = W.R2M(s, m), R2O = W.R2O(s, m, 8), R2L = W.R2L(s, m, b),
    R2B = W.R2B(s.id, "m8", 8, BIG, 1000, "ffffffff"), R2X = W.R2X(s.id, "m8", "ffffffff", "version", BIG),
    R2D = W.R2D(s.id, "m8", "wrong", string.rep("\195\159", 60)), R2Q = W.R2Q(s.id, BIG, "l"), R2J = W.R2J(s.id),
    R2R = W.R2R(s, "done", { a = name, b = name, winner = name, bo = 5, scoreA = 3, scoreB = 2, round = 9, champion = true,
      void = true, id = string.rep("f", 16) }),
  }
  for typ, f in pairs(msgs) do
    local wire = typ .. "\t" .. table.concat(f, "\t")
    T.ok(#wire <= 255, typ .. " is " .. #wire .. " bytes")
    T.ok(validUtf8(wire), typ .. " is valid UTF-8")
    T.ok(ns.comm:Send(typ, f, "WHISPER", "Zed-Normal"), typ .. " accepted by Comm:Send")
  end
  T.eq(msgs.R2O[4], "a" .. string.rep("\195\169", 11), "label: 24-byte cap cut back to a character boundary (23)")
  T.ok(#msgs.R2M[14] <= 32, "title <= 32 bytes"); T.ok(#msgs.R2L[3] <= 48, "name <= 48 bytes")
  T.ok(#msgs.R2D[4] <= 80, "note <= 80 bytes"); T.ok(#msgs.R2A[3] <= 24, "venue <= 24 bytes")
  T.eq(msgs.R2A[7], "30", "bettor count"); T.eq(msgs.R2S[9], "8", "market count")
  T.Advance(60) -- the stub asserts every delivered addon message is <= 255 bytes
end)

T.test("mirror: a v=3 R2S makes the ring read-only; channel traffic only from the session host", function()
  fresh("gold")
  party("Host")
  local function r2s(v, rev, status)
    return table.concat({ "R2S", v, "abc777", status or "open", "ratchet", "gold", 500000, "", 0, 1, rev, "100" }, "\t")
  end
  deliver("Host-Normal", r2s(3, 1), "PARTY")
  local s = R.session
  T.ok(s and not s.isHost, "mirror")
  T.eq(s.readOnly, true)
  deliver("Host-Normal", table.concat({ "R2M", "abc777", "m1", "winner", "fight", "pari", "open", 2, 0, 0, 0, 0, 0, 1, "Winner" }, "\t"), "PARTY")
  deliver("Host-Normal", table.concat({ "R2O", "abc777", "m1", 1, "Fa", 0, 0, 0 }, "\t"), "PARTY")
  deliver("Host-Normal", table.concat({ "R2O", "abc777", "m1", 2, "Fb", 0, 0, 0 }, "\t"), "PARTY")
  local ok, why = R.PlaceBet("m1", 1, 100000)
  T.eq(ok, false); T.eq(why, "version", "read-only: update Bloodsports")
  deliver("Host-Normal", r2s(2, 2), "PARTY")
  T.eq(s.readOnly, nil, "a v=2 state clears read-only")
  channelMsg("Host-Normal", table.concat({ "R2O", "abc777", "m1", 1, "Fa", 70000, 3, 0 }, "\t"))
  T.eq(R.Market("m1", s).outcomes[1].pool, 70000, "host state accepted on the WoMRing channel")
  channelMsg("Evil-Normal", table.concat({ "R2O", "abc777", "m1", 1, "Fa", 1, 1, 0 }, "\t"))
  T.eq(R.Market("m1", s).outcomes[1].pool, 70000, "only the session host is heard")
  channelMsg("Host-Normal", table.concat({ "R2O", "abc777", "m1", 1, "Fa", 5, 1, 0 }, "\t"), "General", 1)
  T.eq(R.Market("m1", s).outcomes[1].pool, 70000, "not on another chat channel")
  R.Leave()
end)

T.noErrors()
T.done()
