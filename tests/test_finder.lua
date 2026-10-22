-- Finder: lobby listing/filter/expiry, listing myself, invites (LI/LR both directions), referees, auto-list.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 5 end
local invited = {}
C_PartyInfo = { InviteUnit = function(n) table.insert(invited, n) end }
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { rating = 4.5 } } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, F = ns.A, ns.Finder

local function sent(typ)
  local out = {}
  for _, m in ipairs(T.sent) do
    if m.msg == typ or m.msg:sub(1, #typ + 1) == typ .. "\t" then out[#out + 1] = m end
  end
  return out
end
local function clear() T.sent = {} end
local function announce(name, kind, venue, class, level, faction, streak, rating, note)
  T.Deliver("BSPT", table.concat({ "LA", kind, venue, class, level, faction, streak or "", rating or "", note or "", "1" }, "\t"),
    "CHANNEL", name)
end

T.test("lobby is created on login", function()
  T.ok(ns.finder, "ns.finder")
  T.eq(ns.finder.channel, "WoMLobby")
end)

T.test("list filters by kind, venue and faction; rings/refs cross faction", function()
  announce("Foo-Normal", "duel", "crossroads", "ROGUE", 12, "Horde", 3, nil, "hi")
  announce("Bar-Normal", "duel", "crossroads", "MAGE", 11, "Alliance")
  announce("Baz-Normal", "duel", "goldshire", "MAGE", 11, "Horde")
  announce("Champ-Normal", "club", "honorroad", "WARRIOR", 60, "Horde", 12)
  announce("RefA-Normal", "ref", "ratchet", "PRIEST", 40, "Alliance", nil, 4.5)
  announce("RingGuy-Normal", "ring", "ratchet", "ROGUE", 30, "Alliance")
  local d = F.List("duel", "crossroads")
  T.eq(#d, 1); T.eq(d[1].name, "Foo-Normal"); T.eq(d[1].note, "hi"); T.eq(d[1].streak, 3)
  T.eq(#F.List("duel"), 2, "two Horde duel entries")
  T.eq(#F.List("duel", "goldshire"), 1)
  T.eq(#F.List("club", "honorroad"), 1)
  T.eq(#F.List("ref"), 1, "alliance referee visible to horde")
  T.eq(#F.List("ring", "ratchet"), 1)
  T.eq(#F.Referees(), 1)
end)

T.test("referee entries update db.referees", function()
  local r = A.db.referees["RefA-Normal"]
  T.ok(r and r.seen, "seen")
  T.eq(r.rating, 4.5)
end)

T.test("own entry never listed", function()
  announce("Tester-Normal", "duel", "crossroads", "WARRIOR", 10, "Horde")
  for _, e in ipairs(F.List("duel")) do T.ok(e.name ~= "Tester-Normal") end
end)

T.test("entries expire after 180 s", function()
  T.Advance(100)
  announce("Foo-Normal", "duel", "crossroads", "ROGUE", 12, "Horde") -- refreshed
  T.Advance(100)
  local l = F.List("duel")
  T.eq(#l, 1, "only the refreshed one remains")
  T.eq(l[1].name, "Foo-Normal")
  T.Advance(100)
  T.eq(#F.List("duel"), 0)
end)

T.test("SetLooking / StopLooking announce and unlist", function()
  clear()
  ns.char.streak.venue.crossroads = 4
  T.ok(F.SetLooking("duel", "crossroads", "bring it"))
  T.Advance(1)
  local m = sent("LA")[1]
  T.ok(m, "LA sent")
  T.eq(m.channel, "CHANNEL"); T.eq(m.target, 5)
  T.eq(m.msg, "LA\tduel\tcrossroads\tWARRIOR\t10\tHorde\t4\t\tbring it\t" .. (ns.finder.version or ""))
  T.ok(F.IsLooking())
  T.ok(not F.SetLooking("bogus", "x", ""), "bad kind rejected")
  clear()
  T.ok(F.StopLooking())
  T.Advance(1)
  T.eq(#sent("LX"), 1)
  T.ok(not F.IsLooking())
end)

T.test("Invite sends party invite + LI whisper with context", function()
  clear(); invited = {}
  T.ok(F.Invite("Foo-Normal", { kind = "club", venue = "honorroad", note = "layer pls" }))
  T.eq(invited[1], "Foo-Normal")
  T.Advance(1)
  local m = sent("LI")[1]
  T.eq(m.channel, "WHISPER"); T.eq(m.target, "Foo-Normal")
  T.eq(m.msg, "LI\tclub\thonorroad\tlayer pls")
  T.ok(not F.Invite("bad name|x", {}), "invalid names rejected")
  T.ok(not F.Invite(nil), "nil rejected")
end)

T.test("Invite falls back to global InviteUnit", function()
  local saved = C_PartyInfo
  C_PartyInfo = nil
  local got
  InviteUnit = function(n) got = n end
  T.ok(F.Invite("Foo"))
  T.eq(got, "Foo")
  C_PartyInfo = saved
  InviteUnit = nil
end)

T.test("RequestInvite sends LR", function()
  clear()
  T.ok(F.RequestInvite("RefA-Normal", "ring", "ratchet", "pls"))
  T.Advance(1)
  local m = sent("LR")[1]
  T.eq(m.msg, "LR\tring\tratchet\tpls"); T.eq(m.target, "RefA-Normal")
end)

T.test("incoming LI / LR fire messages with sanitised args; deduped", function()
  local got = {}
  A:Listen("FINDER_INVITED", function(...) table.insert(got, { "inv", ... }) end)
  A:Listen("FINDER_REQUEST", function(...) table.insert(got, { "req", ... }) end)
  T.Deliver("BSPT", "LI\tclub\thonorroad\tjoin my layer", "WHISPER", "Foo-Normal")
  T.eq(got[1][1], "inv"); T.eq(got[1][2], "Foo-Normal"); T.eq(got[1][3], "club")
  T.eq(got[1][4], "honorroad"); T.eq(got[1][5], "join my layer")
  T.Deliver("BSPT", "LI\tclub\thonorroad\tspam", "WHISPER", "Foo-Normal")
  T.eq(#got, 1, "deduped within 3 s")
  T.Advance(4)
  T.Deliver("BSPT", "LR\tevil\tbad venue!\tnote", "WHISPER", "Baz-Normal")
  T.eq(got[2][1], "req"); T.eq(got[2][3], "duel", "unknown kind -> duel"); T.eq(got[2][4], "")
  T.Advance(4)
  T.Deliver("BSPT", "LR\tref\t\t", "WHISPER", "Baz-Normal")
  T.eq(got[3][3], "ref")
end)

T.test("referee availability lists a ref entry at the ring venue with rating", function()
  T.map = { id = 1413, x = 0.625, y = 0.375, zone = "The Barrens", sub = "Ratchet", name = "The Barrens" }
  T.Advance(2)
  clear()
  A:Fire("REFEREE_AVAILABILITY", true)
  T.Advance(1)
  local m = sent("LA")[1]
  T.ok(m, "LA sent")
  T.eq(m.msg:match("^LA\t(%a+)\t(%w*)"), "ref")
  local f = {}
  for p in (m.msg .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = p end
  T.eq(f[3], "ratchet"); T.eq(f[8], "4.5")
  clear()
  A:Fire("REFEREE_AVAILABILITY", false)
  T.Advance(1)
  T.eq(#sent("LX"), 1)
  T.ok(not F.IsLooking())
end)

T.test("auto-list at practice venue, stop when leaving; manual listing untouched", function()
  A.db.config.finder.autoListAtVenue = true
  T.map = { id = 1413, x = 0.52, y = 0.30, zone = "The Barrens", sub = "The Crossroads", name = "The Barrens" }
  T.Advance(6)
  T.ok(F.IsLooking(), "listed")
  T.eq(F.Looking().kind, "duel"); T.eq(F.Looking().venue, "crossroads")
  T.map = { id = 1413, x = 0.10, y = 0.90, zone = "The Barrens", sub = "", name = "The Barrens" }
  T.Advance(6)
  T.ok(not F.IsLooking(), "unlisted after leaving")
  F.SetLooking("duel", "crossroads", "manual")
  T.Advance(6)
  T.ok(F.IsLooking(), "manual listing kept when away from venues")
  F.StopLooking()
  A.db.config.finder.autoListAtVenue = false
end)

T.noErrors()
T.done()
