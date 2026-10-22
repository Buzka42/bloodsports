-- Venue registry: unverified and dormant rows are never matched; the active list and kinds are as designed.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")

local function row(id)
  for _, v in ipairs(ns.Data.Venues) do if v.id == id then return v end end
end
local function at(map, x, y, sub)
  T.map = { id = map, x = x, y = y, zone = "Zone", sub = sub or "", name = "Zone" }
  ns.venues:Invalidate()
  return ns.venues:Current()
end

T.test("coldridge: fight club, unverified, no coordinates, never indexed by the matcher", function()
  local v = row("coldridge")
  T.ok(v, "row present")
  T.eq(v.kind, "club"); T.eq(v.name, "Coldridge Pass Fight Club"); T.ok(v.unverified, "unverified flag")
  T.ok(v.mapID == nil and v.x == nil and v.y == nil and v.r == nil, "no guessed coordinates")
  T.ok(ns.venues:Get("coldridge") == nil, "matcher does not index an unverified venue")
end)

T.test("matcher rows hold only active, verified venues", function()
  T.ok(#ns.venues.rows > 0, "rows present")
  for _, r in ipairs(ns.venues.rows) do T.ok(not r.unverified and not r.dormant, "matcher row " .. tostring(r.id)) end
end)

T.test("unverified venue is never matched, even by its subzone text", function()
  T.ok(at(1411, 0.5, 0.5, "Coldridge Pass") == nil, "subzone text ignored")
  T.ok(at(1411, nil, nil, "Coldridge Pass") == nil, "no position, subzone text ignored")
end)

T.test("dormant gurubashi (koth) is not matched and not in the active list", function()
  T.eq(row("gurubashi").kind, "koth"); T.ok(row("gurubashi").dormant, "dormant flag")
  T.ok(at(1434, 0.305, 0.475, "Gurubashi Arena") == nil, "position inside arena does not match")
  T.ok(ns.venues:Get("gurubashi") == nil, "not indexed")
  local ids = {}
  for _, v in ipairs(ns.UI.Venues()) do ids[v.id] = true end
  T.ok(not ids.gurubashi, "not in active list")
  T.eq(ns.UI.VenueName("gurubashi"), "Gurubashi Arena", "history still resolves its name")
end)

T.test("verified venues still match at their coordinates", function()
  T.eq(at(1411, 0.455, 0.13).id, "honorroad")
  T.eq(at(1413, 0.52, 0.30).id, "crossroads")
  T.eq(at(1446, 0.515, 0.28).id, "gadgetzan")
end)

T.test("active list by kind: club and practice and ring branches", function()
  local function ids(kind) local out = {} for _, v in ipairs(ns.UI.Venues(kind)) do out[#out + 1] = v.id end return table.concat(out, ",") end
  -- coldridge is unverified until its coordinates are measured, so pickers do not list it yet
  T.eq(ids("club"), "honorroad")
  T.eq(ids("practice"), "crossroads,goldshire")
  T.eq(ids("ring"), "ratchet,everlook,gadgetzan,bootybay")
  T.eq(ns.UI.VenueName("honorroad"), "Honor Road Fight Club"); T.eq(ns.UI.VenueName("bootybay"), "Booty Bay Goblin Ring")
end)

T.test("no tram anywhere in the venue registry", function()
  for _, v in ipairs(ns.Data.Venues) do T.ok(v.id ~= "tram" and not tostring(v.name):find("Tram"), "tram removed") end
end)

T.done()
