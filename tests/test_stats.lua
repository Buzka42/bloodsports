-- Stats: pure functions over duel record arrays.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local S = ns.Stats

local function d(result, class, dur, extra)
  local r = { result = result, opp = { class = class }, dur = dur, t = 1000, confirmed = "self", venue = "crossroads", venueKind = "practice" }
  for k, v in pairs(extra or {}) do r[k] = v end
  return r
end

local duels = {
  d("win", "ROGUE", 30, { firstBlood = "opp" }),
  d("win", "ROGUE", 50, { firstBlood = "me", comeback = true }),
  d("win", "MAGE", 20, { firstBlood = "opp", venue = "goldshire", t = 2000 }),
  d("loss", "ROGUE", 40, { firstBlood = "me", confirmed = "both", venueKind = "club", venue = "honorroad", t = 3000 }),
  d("void", "MAGE", 5),
  d("win", "MAGE", 60, { confirmed = "disputed" }),
  d("win", "WARRIOR", 10, { confirmed = "referee", t = 4000 }),
}

T.test("Summary", function()
  local s = S.Summary(duels)
  T.eq(s.n, 7); T.eq(s.wins, 5); T.eq(s.losses, 1); T.eq(s.voids, 1)
  T.near(s.winRate, 5 / 6); T.near(s.avgDur, (30 + 50 + 20 + 40 + 60 + 10) / 6)
  T.eq(s.comebacks, 1)
  T.near(s.firstBloodRate, 2 / 4) -- opponent bled first in 2 of the 4 duels with data
  T.eq(s.bestStreak, 3, "disputed win skipped, loss resets")
end)

T.test("Summary of nothing", function()
  local s = S.Summary({})
  T.eq(s.n, 0); T.eq(s.winRate, 0); T.eq(s.avgDur, 0); T.eq(s.bestStreak, 0)
  T.eq(S.Summary(nil).n, 0)
end)

T.test("Matchups ignore voids and group by class", function()
  local m = S.Matchups(duels)
  T.eq(m.ROGUE.n, 3); T.eq(m.ROGUE.wins, 2); T.eq(m.ROGUE.losses, 1)
  T.eq(m.MAGE.n, 2); T.eq(m.MAGE.wins, 2); T.near(m.MAGE.winRate, 1)
  T.eq(m.WARRIOR.n, 1)
  T.eq(S.Matchups({ { result = "win", opp = {} } }).UNKNOWN.n, 1)
end)

T.test("ByVenue and ByClassDuration", function()
  local v = S.ByVenue(duels)
  T.eq(v.crossroads.n, 4); T.eq(v.goldshire.n, 1); T.eq(v.honorroad.losses, 1); T.near(v.honorroad.winRate, 0)
  local c = S.ByClassDuration(duels)
  T.near(c.ROGUE, 40); T.near(c.MAGE, 40); T.near(c.WARRIOR, 10)
  T.eq(S.ByVenue({ { result = "win", opp = {} } }).none.n, 1)
end)

T.test("Filter", function()
  T.eq(#S.Filter(duels, {}), 7)
  T.eq(#S.Filter(duels, { venueKind = "club" }), 1)
  T.eq(#S.Filter(duels, { confirmedOnly = true }), 2)
  T.eq(#S.Filter(duels, { since = 2500 }), 2)
  T.eq(#S.Filter(duels, { venueKind = "practice", since = 2000, confirmedOnly = true }), 1)
  T.eq(#S.Filter(nil, nil), 0)
end)

T.done()
