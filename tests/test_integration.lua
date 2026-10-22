-- End-to-end: strict load, real modules + real UI kit. Duel with both-confirm, every tab, finder lobby + invite,
-- a gold ring session hosted by us with one bettor and an auto verdict.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 5 end
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A = ns.A
local function sentOf(kind)
  local out = {}
  for _, m in ipairs(T.sent) do if m.msg:match("^" .. kind .. "\t") or m.msg == kind then table.insert(out, m) end end
  return out
end

T.test("no missing files in the TOC", function()
  T.eq(T.missing, nil, "missing: " .. table.concat(T.missing or {}, ", "))
end)

T.test("duel at the Crossroads: card, both-confirm, toast, stats", function()
  T.map = { id = 1413, x = 0.52, y = 0.30, zone = "The Barrens", sub = "The Crossroads", name = "The Barrens" }
  T.units.target = { name = "Rival", realm = "Normal", class = "ROGUE", race = "Undead", level = 10, isPlayer = true,
    health = 100, healthMax = 100, faction = "Horde" }
  T.Fire("DUEL_REQUESTED", "Rival")
  T.Fire("CHAT_MSG_SYSTEM", "Duel starting: 3")
  local dh = sentOf("DH")[1]
  T.ok(dh, "hello whispered")
  T.Deliver("BSPT", "DH\tabcdef12\t1\tROGUE\t10", "WHISPER", "Rival-Normal")
  T.Advance(4)
  T.combat = true; T.Fire("PLAYER_REGEN_DISABLED")
  T.units.target.health = 15; T.Fire("UNIT_HEALTH", "target"); T.Advance(1)
  T.units.target.health = 0
  T.Fire("DUEL_FINISHED")
  T.Fire("CHAT_MSG_SYSTEM", "Tester has defeated Rival in a duel")
  T.combat = false; T.Fire("PLAYER_REGEN_ENABLED")
  T.Advance(1)
  local rec = ns.char.duels[#ns.char.duels]
  T.eq(rec.result, "win"); T.eq(rec.venue, "crossroads")
  T.Deliver("BSPT", "DR\t" .. rec.id .. "\tTester-Normal\tknockout\t", "WHISPER", "Rival-Normal")
  T.Advance(2)
  T.eq(ns.char.duels[#ns.char.duels].confirmed, "both")
  T.eq(ns.Stats.Summary(ns.char.duels).wins, 1)
  T.noErrors()
end)

T.test("main window: every tab", function()
  for _, tab in ipairs({ "duels", "matchups", "finder", "clubs", "ring" }) do
    A:Fire("TOGGLE_MAIN", tab)
    T.Advance(0.2)
  end
  T.ok(_G.BloodsportsMain and BloodsportsMain:IsShown(), "main shown")
  T.noErrors()
end)

T.test("finder: lobby entry shows up, invite whispers context", function()
  T.Advance(10) -- lobby joins 5 s after PLAYER_ENTERING_WORLD
  T.Deliver("BSPT", "LA\tduel\tcrossroads\tWARRIOR\t11\tHorde\t3\t0\tfirst to 3\t1", "CHANNEL", "Brawler-Normal")
  local list = ns.Finder.List("duel", "crossroads")
  T.eq(#list, 1, "one opponent listed")
  local invited
  C_PartyInfo = C_PartyInfo or {}
  C_PartyInfo.InviteUnit = function(n) invited = n end
  ns.Finder.Invite("Brawler-Normal", { kind = "duel", venue = "crossroads", note = "" })
  T.ok(invited, "party invite sent")
  T.ok(#sentOf("LI") >= 1, "LI context whispered")
  A:Fire("TOGGLE_MAIN", "finder"); T.Advance(0.5)
  T.noErrors()
end)

T.test("ring at Ratchet: host opens, bettor bets, stake traded, verdict pays out", function()
  T.map = { id = 1413, x = 0.625, y = 0.375, zone = "The Barrens", sub = "Ratchet", name = "The Barrens" }
  T.units.party1 = { name = "Gambler", realm = "Normal", class = "MAGE", level = 12, isPlayer = true }
  T.units.party2 = { name = "Ogg", realm = "Normal", class = "WARRIOR", level = 12, isPlayer = true }
  T.units.party3 = { name = "Zug", realm = "Normal", class = "ROGUE", level = 12, isPlayer = true }
  T.group = { size = 4, raid = false }
  UnitIsGroupLeader = function() return true end
  SlashCmdList.BLOODSPORTS("referee on")
  local s = ns.Ring.Open()
  T.ok(type(s) == "table", "session opened")
  T.ok(ns.Ring.SetFighters("Ogg-Normal", "Zug-Normal"), "fighters set")
  T.Deliver("BSPT", "RB\t" .. s.id .. "\tOgg-Normal\t50000", "WHISPER", "Gambler-Normal")
  T.Advance(1)
  T.eq(#s.bets, 1, "bet accepted")
  -- stake arrives by trade: 5g from Gambler
  T.units.npc = { name = "Gambler", realm = "Normal", isPlayer = true }
  T.money = 100000
  T.Fire("TRADE_SHOW"); T.trade.target = 50000
  T.Fire("TRADE_ACCEPT_UPDATE", 1, 1)
  T.Fire("TRADE_CLOSED"); T.SetMoney(150000)
  T.Advance(1)
  T.ok(s.bets[1].paid, "stake marked paid")
  T.ok(ns.Ring.Lock(), "locked")
  T.Fire("CHAT_MSG_SYSTEM", "Ogg has defeated Zug in a duel")
  T.Advance(1)
  T.eq(s.status, "settled")
  T.eq(s.bets[1].payout, 50000, "sole bettor on the winner gets stake back (no losers)")
  A:Fire("TOGGLE_MAIN", "ring"); T.Advance(0.5)
  T.noErrors()
end)

T.test("ring: fighter's countdown auto-locks the host; mid-session joiner gets bet lines", function()
  SlashCmdList.BLOODSPORTS("referee on")
  ns.Ring.Close(); T.Advance(1)
  local s = ns.Ring.Open()
  T.ok(type(s) == "table", "second session")
  ns.Ring.SetFighters("Ogg-Normal", "Zug-Normal")
  T.Deliver("BSPT", "RB\t" .. s.id .. "\tZug-Normal\t20000", "WHISPER", "Gambler-Normal")
  T.Advance(1)
  local before = #T.sent
  T.Deliver("BSPT", "RQ\t" .. s.id, "WHISPER", "Gambler-Normal")
  T.Advance(2)
  local lines = 0
  for i = before + 1, #T.sent do if T.sent[i].msg:match("^RL\t") and T.sent[i].target == "Gambler-Normal" then lines = lines + 1 end end
  T.eq(lines, 1, "bet line whispered on resync")
  T.Deliver("BSPT", "RF\t" .. s.id, "WHISPER", "Ogg-Normal")
  T.eq(s.status, "locked", "auto-locked by fighter countdown")
  local verdictRows = 0
  for _, r in ipairs(BloodsportsDB.outbox.rows) do if r.kind == "ring" and r.data.event == "verdict" then verdictRows = verdictRows + 1 end end
  T.eq(verdictRows, 1, "earlier session pushed one verdict row")
  T.noErrors()
end)

T.done()
