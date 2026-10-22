-- Integration: the whole Bloodsports addon loads from its TOC and survives login + a duel-ish event burst.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")

T.test("loads and creates the DB + character record", function()
  T.ok(BloodsportsDB and BloodsportsDB.installId, "db")
  T.ok(ns.char and ns.char.id, "char")
  T.ok(ns.Data.Venues and #ns.Data.Venues > 5, "venues")
end)

T.test("survives events and time", function()
  T.units.target = { name = "Foe", class = "ROGUE", race = "Human", level = 12, isPlayer = true, health = 100, healthMax = 100, faction = "Alliance" }
  T.Fire("DUEL_REQUESTED", "Foe")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3")
  T.Advance(4)
  T.Fire("DUEL_FINISHED")
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Foe in a duel")
  T.Advance(10)
  SlashCmdList.BLOODSPORTS("venue")
  T.noErrors()
end)

if T.missing then io.write("  (skipped missing files: " .. #T.missing .. ")\n") end
T.done()
