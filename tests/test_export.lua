-- Export flow (mirrors Elders' SHOW_EXPORT): payload shape, WOM1 round trip, duel cap, plain fallback, /bs export and
-- the Duels tab button. The player has a Forever surname so the whole "First Surname-Realm" key must survive.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
T.units.player.realm = "Gippity"
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local MK = MetaKit
local A = ns.A

local function duel(i)
  return { id = "m" .. i, t = GetServerTime() - 1000 + i, dur = 30, venue = "honorroad", venueKind = "club",
    me = { class = "WARRIOR", level = 12 }, opp = { name = "Foe" .. i .. "-Normal", class = "ROGUE" },
    result = i % 2 == 0 and "win" or "loss", how = "knockout", confirmed = "self" }
end

T.test("payload: whole char key, identity, streak, challenges, duels; trades and bets stay home", function()
  table.insert(ns.char.duels, duel(1))
  table.insert(ns.char.bets, { id = "b1" })
  table.insert(ns.char.trades, { id = "t1" })
  local p = ns.ExportPayload()
  T.eq(p.v, 1)
  T.eq(p.addon, "Bloodsports")
  T.eq(p.install, A.db.installId)
  T.eq(p.char.key, "Tester Gippity-Normal")
  T.eq(p.char.name, "Tester Gippity")
  T.eq(p.char.id, ns.char.id)
  T.eq(p.char.class, "WARRIOR")
  T.eq(#p.duels, 1)
  T.eq(p.duels[1].id, "m1")
  T.ok(p.streak and p.challenges, "streak and challenges")
  T.eq(p.bets, nil)
  T.eq(p.trades, nil)
end)

T.test("WOM1 string round-trips with the bloodsports tag", function()
  local s = ns.UI.ExportText()
  T.ok(s:find("^WOM1:bloodsports:"), s:sub(1, 30))
  local tag, v = MK.ImportString(s)
  T.eq(tag, "bloodsports")
  T.eq(v.char.key, "Tester Gippity-Normal")
  T.eq(v.duels[1].opp.name, "Foe1-Normal")
end)

T.test("only the newest MAX_EXPORT_DUELS duels are exported", function()
  for i = 2, ns.MAX_EXPORT_DUELS + 20 do table.insert(ns.char.duels, duel(i)) end
  local p = ns.ExportPayload()
  T.eq(#p.duels, ns.MAX_EXPORT_DUELS)
  T.eq(p.duels[#p.duels].id, "m" .. (ns.MAX_EXPORT_DUELS + 20))
  T.eq(p.duels[1].id, "m21")
end)

T.test("export text falls back to plain when Codec is missing", function()
  local keep = MK.ExportString
  MK.ExportString = nil
  T.ok(ns.UI.ExportText():find("^BLOODSPORTS%-PLAIN:"))
  MK.ExportString = keep
end)

T.test("/bs export and the Duels tab button open the export box", function()
  local shown = {}
  local keep = MK.UI.ExportBox
  MK.UI.ExportBox = function(o) shown[#shown + 1] = o; if keep then return keep(o) end end
  SlashCmdList.BLOODSPORTS("export")
  T.eq(#shown, 1)
  T.ok(shown[1].text:find("^WOM1:bloodsports:"))
  T.eq(shown[1].skin, "bloodsports")
  A:Fire("TOGGLE_MAIN", "duels")
  local pane
  for _, f in ipairs({ ns.UI.MainWindow().content:GetChildren() }) do if f.export then pane = f end end
  T.ok(pane, "duels pane has the export button")
  pane.export:Click()
  T.eq(#shown, 2)
  MK.UI.ExportBox = keep
  T.noErrors()
end)

T.done()
