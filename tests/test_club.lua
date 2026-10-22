-- Club: champions lookup, distinct-opponent streak rule, challenge eligibility, challenge record + CC, site merge.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 5 end
local now = 1760000000 + 1000
WorldOfMetaData = { bloodsports = { champions = { honorroad = {
  Horde = { WARRIOR = { name = "Champ-Normal", streak = 14, since = now - 86400 * 3 },
            ROGUE = { name = "Tester-Normal", streak = 11, since = now } },
  Alliance = { WARRIOR = { name = "Ally-Normal", streak = 10, since = now } },
} } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, C = ns.A, ns.Club
local DAY = 86400

local function sent(typ)
  local out = {}
  for _, m in ipairs(T.sent) do
    if m.msg == typ or m.msg:sub(1, #typ + 1) == typ .. "\t" then out[#out + 1] = m end
  end
  return out
end
local n = 0
local function duel(venue, result, opp, confirmed, t)
  n = n + 1
  table.insert(ns.char.duels, { id = "d" .. n, t = t or now, venue = venue, result = result, confirmed = confirmed or "both",
    opp = { name = opp } })
end
local function reset() ns.char.duels = {}; ns.char.challenges = {} end

T.test("champions lookup from site data", function()
  local c = C.Champions("honorroad")
  T.eq(c.Horde.WARRIOR.name, "Champ-Normal")
  T.eq(C.Champion("honorroad", "Horde", "WARRIOR").streak, 14)
  T.eq(C.Champion("honorroad", "Horde", "MAGE"), nil)
  T.eq(next(C.Champions("nowhere")), nil)
end)

T.test("streak counts distinct confirmed wins at the venue only", function()
  reset()
  for i = 1, 5 do duel("honorroad", "win", "Opp" .. i) end
  T.eq(C.MyStreak("honorroad"), 5)
  duel("elsewhere", "win", "Other")
  T.eq(C.MyStreak("honorroad"), 5, "other venue ignored")
  duel("honorroad", "win", "Selfie", "self")
  duel("honorroad", "win", "Disp", "disputed")
  duel("honorroad", "void", "Void", "self")
  T.eq(C.MyStreak("honorroad"), 5, "unconfirmed/disputed/void neither count nor break")
  duel("honorroad", "win", "Ref", "referee")
  T.eq(C.MyStreak("honorroad"), 6, "referee confirmation counts")
  duel("honorroad", "loss", "Opp1")
  T.eq(C.MyStreak("honorroad"), 0, "loss breaks")
end)

T.test("same opponent counts at most twice per day", function()
  reset()
  for _ = 1, 5 do duel("honorroad", "win", "Farmed-Normal") end
  T.eq(C.MyStreak("honorroad"), 2)
  duel("honorroad", "win", "Farmed-Normal", "both", now + DAY)
  T.eq(C.MyStreak("honorroad"), 3, "new day, counts again")
  duel("honorroad", "win", "Fresh", "both", now + DAY)
  T.eq(C.MyStreak("honorroad"), 4)
end)

T.test("CanChallenge: venue, streak, champion", function()
  reset()
  local ok, why = C.CanChallenge("crossroads")
  T.ok(not ok); T.eq(why, "venue")
  ok, why = C.CanChallenge("honorroad")
  T.ok(not ok); T.eq(why, "streak")
  for i = 1, 9 do duel("honorroad", "win", "O" .. i) end
  ok, why = C.CanChallenge("honorroad")
  T.ok(not ok, "9 is not enough")
  duel("honorroad", "win", "O10")
  local champ
  ok, why, champ = C.CanChallenge("honorroad")
  T.ok(ok); T.eq(why, "challenge"); T.eq(champ.name, "Champ-Normal")
  T.units.player.class = "MAGE"
  ok, why = C.CanChallenge("honorroad")
  T.ok(ok); T.eq(why, "claim", "no champion for the class -> claim")
  T.units.player.class = "ROGUE"
  ok, why = C.CanChallenge("honorroad")
  T.ok(not ok); T.eq(why, "champion", "I am the champion")
  T.units.player.class = "WARRIOR"
end)

T.test("farmed wins do not unlock challenges", function()
  reset()
  for _ = 1, 30 do duel("honorroad", "win", "Same") end
  T.ok(not C.CanChallenge("honorroad"))
end)

T.test("Challenge writes record, outbox row and CC whisper", function()
  reset()
  for i = 1, 10 do duel("honorroad", "win", "O" .. i) end
  local fired = 0
  A:Listen("CLUB_UPDATED", function() fired = fired + 1 end)
  T.sent = {}
  local rec = C.Challenge("honorroad")
  T.ok(rec, "record")
  T.eq(rec.status, "open"); T.eq(rec.champion, "Champ-Normal"); T.eq(rec.class, "WARRIOR"); T.eq(rec.faction, "Horde")
  T.eq(ns.char.challenges[rec.id], rec)
  T.eq(A.db.outbox.rows[#A.db.outbox.rows].kind, "challenge")
  T.Advance(1)
  local m = sent("CC")[1]
  T.eq(m.channel, "WHISPER"); T.eq(m.target, "Champ-Normal"); T.eq(m.msg, "CC\t" .. rec.id .. "\thonorroad\tWARRIOR")
  T.eq(fired, 1)
  local again, why = C.Challenge("honorroad")
  T.eq(again, nil); T.eq(why, "open")
end)

T.test("incoming CC fires CLUB_CHALLENGED, junk ignored", function()
  local got = {}
  A:Listen("CLUB_CHALLENGED", function(s, v) table.insert(got, { s, v }) end)
  T.Deliver("BSPT", "CC\tabcdef12\thonorroad\tWARRIOR", "WHISPER", "Chal-Normal")
  T.eq(#got, 1); T.eq(got[1][1], "Chal-Normal"); T.eq(got[1][2], "honorroad")
  T.Deliver("BSPT", "CC\tnothex!\thonorroad\tWARRIOR", "WHISPER", "Chal-Normal")
  T.Deliver("BSPT", "CC\tabcdef12\tcrossroads\tWARRIOR", "WHISPER", "Chal-Normal")
  T.Deliver("BSPT", "CC\tabcdef12\tnope\tWARRIOR", "WHISPER", "Chal-Normal")
  T.eq(#got, 1)
end)

T.test("challenges merge with site data and carry a 7 day deadline", function()
  local mine
  for _, c in pairs(ns.char.challenges) do mine = c end
  WorldOfMetaData.bloodsports.challenges = {
    { id = mine.id, status = "closed", t = mine.t },
    { id = "site1", venue = "honorroad", champion = "Tester-Normal", challenger = "Foe-Normal", t = now - 8 * DAY, status = "open" },
    { id = "site2", venue = "honorroad", champion = "Champ-Normal", t = now - DAY, status = "open" },
    "junk", { id = 5 },
  }
  local list = C.Challenges()
  T.eq(#list, 3, "deduped by id, junk dropped")
  local byId = {}
  for _, c in ipairs(list) do byId[c.id] = c end
  T.eq(byId[mine.id].status, "closed", "site status wins")
  T.eq(byId[mine.id].deadline, mine.t + 7 * DAY)
  T.ok(byId.site1.expired, "8 days old is expired")
  T.ok(not byId.site2.expired)
  T.eq(byId.site2.remaining, now + 6 * DAY - GetServerTime())
  T.ok(list[1].t >= list[2].t, "newest first")
  local inc = C.Incoming()
  T.eq(#inc, 1); T.eq(inc[1].id, "site1")
  WorldOfMetaData.bloodsports.challenges = nil
end)

T.test("resolved duel against the champion closes my open challenge", function()
  reset()
  for i = 1, 10 do duel("honorroad", "win", "O" .. i) end
  local rec = C.Challenge("honorroad")
  A:Fire("DUEL_RESOLVED", { venue = "honorroad", me = {}, opp = { name = "Champ" }, result = "win", confirmed = "both" })
  T.eq(ns.char.challenges[rec.id].status, "won")
  T.eq(A.db.outbox.rows[#A.db.outbox.rows].kind, "challenge")
end)

T.noErrors()
T.done()
