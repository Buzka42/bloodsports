-- Ring tab v2 + HUD (contract §7) on fake v2 sessions: market list rows, bet slip pari / fixed previews (contract
-- worked examples), refusal + pending states, my-bet state and dispute window, host vs spectator controls, the
-- create-market flow and the HUD. Stub only: frames are recorded, never drawn, so layout is unproven here.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc", { login = false })
C_AddOns.IsAddOnLoaded = function(n) return n == "Bloodsports" end
local MK, A = MetaKit, ns.A
local K = MK.UI

local made = { buttons = {}, lists = {}, edits = {}, dropdowns = {}, checks = {}, stats = {} }
for name, bucket in pairs({ Button = "buttons", Plate = "buttons", List = "lists", EditBox = "edits", Dropdown = "dropdowns",
  Checkbox = "checks", StatRows = "stats" }) do
  local orig = K[name]
  if orig then K[name] = function(p, o) local f = orig(p, o); f._opts = o; table.insert(made[bucket], f); return f end end
end
T.Fire("PLAYER_LOGIN")
T.Fire("PLAYER_ENTERING_WORLD", true, false)
GetMoney = function() return 10000000 end

-- Real engine for the pure parts (Markets, FixedPayout, C), recorded fakes for every mutator.
local real = ns.Ring
local calls = {}
local fake = setmetatable({ calls = calls }, { __index = real })
for _, fn in ipairs({ "AddMarket", "OpenMarket", "Lock", "Verdict", "Void", "ResolveDispute", "PlaceBet", "Dispute", "Close",
  "SetPrice", "Join", "FormRaid", "InviteQueued", "SetPublic", "SetAutoInvite", "Leave" }) do
  fake[fn] = function(...) table.insert(calls, { fn, ... }); return true end
end
fake.Band = function() return 5, 500000 end
fake.BankMax = function() return 5000000, 5 end
fake.Debts = function() return {} end
fake.Browser = function() return {} end
ns.Ring = fake

local RV = ns.UI.RingView
local function last() return calls[#calls] or {} end
local function refresh() ns.UI.Refresh(); ns.UI.UpdateHUD() end
local function list(first, second)
  for i = #made.lists, 1, -1 do
    local c = made.lists[i]._opts.columns
    if c[1].title == first and (not second or c[2].title == second) then return made.lists[i] end
  end
end
local function btn(text)
  for _, b in ipairs(made.buttons) do if b._opts.text == text then return b end end
end
local function edit(placeholder)
  for _, e in ipairs(made.edits) do if e._opts.placeholder == placeholder then return e end end
end
local function rowOf(l, key, value)
  for _, r in ipairs(l.data) do if r[key] == value then return r end end
end

local function session(isHost)
  return { v2 = true, id = "ab12cd34", host = isHost and "Tester-Normal" or "Ref-Normal", isHost = isHost, venue = "ratchet",
    currency = "gold", cap = 500000, status = "open", rev = 9, public = true, watchers = {}, series = { id = "s1", bo = 3 },
    fighters = { a = "Ann-Normal", b = "Bob-Normal" },
    markets = {
      m1 = { mid = "m1", kind = "winner", mode = "pari", title = "Winner", status = "open", result = 0, bets = {},
        outcomes = { { label = "Ann", ref = "Ann-Normal", pool = 30000, n = 1 }, { label = "Bob", ref = "Bob-Normal", pool = 0, n = 0 } } },
      m2 = { mid = "m2", kind = "score", scope = "series", mode = "pari", title = "Score bo3", status = "open", result = 0,
        outcomes = { { label = "2-0", pool = 50000, n = 1 }, { label = "2-1", pool = 75000, n = 1 },
          { label = "1-2", pool = 33333, n = 1 }, { label = "0-2", pool = 210000, n = 1 } },
        bets = { { bettor = "Bob-Normal", outcome = 1, amount = 50000, paid = true },
          { bettor = "Cid-Normal", outcome = 2, amount = 75000, paid = true },
          { bettor = "Dee-Normal", outcome = 3, amount = 33333, paid = true },
          { bettor = "Eve-Normal", outcome = 4, amount = 210000, paid = true } } },
      m3 = { mid = "m3", kind = "winner", mode = "fixed", title = "Winner odds", status = "open", result = 0, bank = 250000, bets = {},
        outcomes = { { label = "Ann", price = 180, pool = 0, n = 0 }, { label = "Bob", price = 210, pool = 0, n = 0 } } },
    } }
end

local S = session(false)
fake.session = S

T.test("formatters: compact money and typed amounts", function()
  T.eq(ns.UI.Amount(344705), "34g 47s 05c")
  T.eq(ns.UI.Amount(487500), "48g 75s")
  T.eq(ns.UI.Amount(350, "points"), "350 pts")
  T.eq(ns.UI.ParseMoney("12g 50s", "gold"), 125000)
  T.eq(ns.UI.ParseMoney("3g33s33c", "gold"), 33333)
  T.eq(ns.UI.ParseMoney("12.5", "gold"), 125000)
  T.eq(ns.UI.ParseMoney("1.15", "gold"), 11500)
  T.eq(ns.UI.ParseMoney("abc", "gold"), nil)
  T.eq(ns.UI.ParseMoney("350", "points"), 350)
  T.eq(RV.Clock(581), "9:41"); T.eq(RV.Clock(-5), "0:00"); T.eq(RV.Clock(3723), "1:02:03")
end)

T.test("market list renders one row per market: kind, outcomes, odds mode, pool, status", function()
  A:Fire("TOGGLE_MAIN", "ring")
  local box = ns.UI.RingPane
  T.ok(box and box.live:IsShown() and not box.idle:IsShown(), "live view")
  local ml = list("Market", "Kind")
  T.eq(#ml.data, 3)
  local r2 = rowOf(ml, "mid", "m2")
  T.eq(r2.kind, "Score"); T.eq(r2.outs, 4); T.eq(r2.mode, "pari"); T.eq(r2.pool, "36g 83s 33c"); T.eq(r2.status, "open")
  T.eq(rowOf(ml, "mid", "m3").mode, "fixed")
  S.markets.m1.status, S.markets.m1.appealUntil = "resolving", GetServerTime() + 581
  refresh()
  T.eq(rowOf(ml, "mid", "m1").status, "appeal 9:41")
  S.markets.m1.status = "open"
  refresh()
  T.noErrors()
end)

T.test("bet slip: pari preview matches the contract example (Ann 12g on 2-0 pays 34g 47s 05c, ×2.87 est · 34%)", function()
  local pv = RV.PariPreview({ 50000, 75000, 33333, 210000 }, 1, 120000)
  T.eq(pv.payout, 344705)
  T.eq(RV.PariPill(pv), "×2.87 est · 34%")
  T.eq(RV.Share(488333, 170000, 50000), 143627, "Bob's share after Ann joins")
  local box = ns.UI.RingPane
  local ml, outs = list("Market", "Kind"), list("Outcome", "Odds")
  ml._opts.onRowClick(rowOf(ml, "mid", "m2"))
  T.eq(#outs.data, 4)
  outs._opts.onRowClick(outs.data[1])
  edit("Amount")._opts.onChange("12g")
  T.ok(box.payoutL:GetText():find("34g 47s 05c", 1, true), "payout " .. tostring(box.payoutL:GetText()))
  T.ok(box.payoutL:GetText():find("×2.87 est · 34%", 1, true), "pill in slip")
  T.eq(outs.data[1].pill, "×2.87 est · 34%")
  T.eq(box.refuseL:GetText(), "Estimate until the market locks.")
  T.ok(box.place.mkEnabled, "place enabled")
  btn("Place bet"):Click()
  local c = last()
  T.eq(c[1], "PlaceBet"); T.eq(c[2], "m2"); T.eq(c[3], 1); T.eq(c[4], 120000)
  -- nobody on the outcome yet: "—" and the first-bet hint
  ml._opts.onRowClick(rowOf(ml, "mid", "m1"))
  outs._opts.onRowClick(outs.data[2])
  T.eq(outs.data[2].pill, "—")
  T.eq(box.refuseL:GetText(), "First bet sets the odds.")
  T.eq(box.payoutL:GetText(), "Payout est 15g · —", "W = 0: estimate still shown (12g takes Ann's 3g pool)")
  T.noErrors()
end)

T.test("bet slip: fixed odds show the posted price and payout; cap refusal", function()
  T.eq(RV.FixedPill(180), "1.80 · 55%"); T.eq(RV.FixedPill(215), "2.15 · 46%"); T.eq(RV.FixedPill(0), "no price")
  T.eq(RV.FixedPayout(12345, 215), 26541, "F1")
  local box = ns.UI.RingPane
  local ml, outs = list("Market", "Kind"), list("Outcome", "Odds")
  ml._opts.onRowClick(rowOf(ml, "mid", "m3"))
  outs._opts.onRowClick(outs.data[1])
  edit("Amount")._opts.onChange("20")
  T.eq(box.payoutL:GetText(), "Pays 36g · 1.80 · 55%")
  edit("Amount")._opts.onChange("60")
  T.eq(box.refuseL:GetText(), "Over the table cap: max 50g.")
  T.ok(not box.place.mkEnabled, "place disabled on a local refusal")
  local n = #calls
  btn("Place bet"):Click()
  T.eq(#calls, n, "refused locally, nothing sent")
  T.noErrors()
end)

T.test("bet slip: host refusal (R2X bank) and pending nonce", function()
  local box = ns.UI.RingPane
  edit("Amount")._opts.onChange("50")
  S.refusal = { mid = "m3", code = "bank", max = 487500 }
  refresh()
  T.eq(box.refuseL:GetText(), "Bookie can't cover that: max 48g 75s.")
  S.refusal = nil
  S.pending = { mid = "m3", nonce = "ab12", idx = 1, amount = 500000 }
  refresh()
  T.ok(box.pendingL:GetText():find("awaiting host", 1, true), "pending line")
  T.ok(not box.place.mkEnabled, "place disabled while pending")
  S.pending = nil
  refresh()
  T.ok(box.place.mkEnabled, "place enabled again")
  T.noErrors()
end)

T.test("my bet: unpaid, paid with estimate, then the dispute window", function()
  local box = ns.UI.RingPane
  local ml = list("Market", "Kind")
  ml._opts.onRowClick(rowOf(ml, "mid", "m2"))
  local mine = { bettor = "Tester-Normal", outcome = 1, amount = 120000, paid = false }
  table.insert(S.markets.m2.bets, mine)
  refresh()
  T.ok(box.mine:IsShown() and not box.slipForm:IsShown(), "slip replaced by my bet")
  T.eq(box.mineState:GetText(), "unpaid: trade Ref 12g")
  mine.paid = true
  S.markets.m2.outcomes[1].pool = 170000
  refresh()
  T.eq(box.mineState:GetText(), "paid")
  T.ok(box.mineL:GetText():find("pays est 34g 47s 05c", 1, true), box.mineL:GetText())
  S.markets.m2.status, S.markets.m2.result, S.markets.m2.appealUntil = "resolving", 1, GetServerTime() + 581
  refresh()
  T.ok(box.mineL:GetText():find("payout 34g 47s 05c", 1, true), box.mineL:GetText())
  T.ok(box.disputeBtn:IsShown(), "dispute while resolving")
  T.eq(box.disputeL:GetText(), "closes in 9:41")
  btn("Dispute"):Click()
  T.eq(last()[1], "Dispute"); T.eq(last()[2], "m2"); T.eq(last()[3], "wrong")
  local found
  for _, it in ipairs(box.myBets.items) do
    if it.row and it.row.label:find("Score bo3", 1, true) then found = it.row end
  end
  T.ok(found and found.value == "34g 47s 05c", "my bets row " .. tostring(found and found.value))
  S.markets.m2.status = "settled"
  refresh()
  T.eq(box.mineState:GetText(), "host owes you 34g 47s 05c")
  T.noErrors()
end)

T.test("spectator vs host: control visibility and host actions per market", function()
  local box = ns.UI.RingPane
  T.ok(box.slip:IsShown() and not box.hostCtl:IsShown(), "spectator: slip, no referee table")
  T.ok(box.specBar:IsShown() and not box.hostBar:IsShown() and not box.create:IsShown(), "spectator bars")
  T.ok(box.myBets:IsShown() and not box.betsList:IsShown(), "spectator: my bets")
  S = session(true)
  fake.session = S
  refresh()
  T.ok(box.hostCtl:IsShown() and not box.slip:IsShown(), "host: referee table, no slip")
  T.ok(box.hostBar:IsShown() and not box.specBar:IsShown() and box.betsList:IsShown(), "host bars + bets table")
  local ml, outs = list("Market", "Kind"), list("Outcome", "Odds")
  ml._opts.onRowClick(rowOf(ml, "mid", "m2"))
  T.eq(#list("Bettor", "On").data, 4, "bets on m2")
  T.eq(rowOf(ml, "mid", "m2").pool, "36g 83s 33c", "host pools from bets")
  T.ok(box.lockB:IsShown() and not box.openB:IsShown() and not box.upholdB:IsShown(), "open market buttons")
  T.ok(not box.verdictB.mkEnabled, "verdict needs an outcome")
  outs._opts.onRowClick(outs.data[1])
  T.ok(box.verdictB.mkEnabled, "verdict armed")
  btn("Lock"):Click(); T.eq(last()[1], "Lock"); T.eq(last()[2], "m2")
  btn("Verdict"):Click(); T.eq(last()[1], "Verdict"); T.eq(last()[2], "m2"); T.eq(last()[3], 1)
  btn("Void"):Click(); T.eq(last()[1], "Void"); T.eq(last()[2], "m2")
  S.markets.m2.status, S.markets.m2.result = "disputed", 1
  S.markets.m2.dispute = { by = "Cid-Normal", code = "wrong", note = "Ann fled", at = GetServerTime() - 100 }
  refresh()
  T.ok(box.upholdB:IsShown() and box.amendB:IsShown() and box.voidDispB:IsShown() and not box.lockB:IsShown(), "dispute panel")
  T.ok(box.hostInfo:GetText():find("auto-void in 28:20", 1, true), box.hostInfo:GetText())
  T.ok(not box.amendB.mkEnabled, "amend needs a different outcome")
  btn("Uphold"):Click(); T.eq(last()[1], "ResolveDispute"); T.eq(last()[3], "uphold")
  outs._opts.onRowClick(outs.data[2])
  btn("Amend"):Click(); T.eq(last()[3], "amend"); T.eq(last()[4], 2)
  -- fixed draft: Open + price edit
  S.markets.m3.status = "draft"
  ml._opts.onRowClick(rowOf(ml, "mid", "m3"))
  T.ok(box.openB:IsShown() and box.priceB:IsShown(), "draft fixed: open + price")
  outs._opts.onRowClick(outs.data[2])
  box.priceBox._opts.onChange("2.35")
  btn("Set price"):Click(); T.eq(last()[1], "SetPrice"); T.eq(last()[3], 2); T.eq(last()[4], 235)
  btn("Open"):Click(); T.eq(last()[1], "OpenMarket"); T.eq(last()[2], "m3")
  T.noErrors()
end)

T.test("create market: caps, fixed prices and bank, quick winner", function()
  local box = ns.UI.RingPane
  btn("+ Market"):Click()
  T.ok(box.create:IsShown() and not box.detailBox:IsShown(), "create form shown")
  box.kindDD._opts.onSelect("custom")
  T.ok(box.labelsBox:IsShown() and not box.fighterA:IsShown(), "custom: labels, no fighters")
  box.labelsBox._opts.onChange("a, b, c, d, e, f, g, h, i")
  local n = #calls
  btn("Create & open"):Click()
  T.eq(#calls, n, "nine labels refused")
  T.eq(box.createErr:GetText(), "At most 8 outcomes per market.")
  box.labelsBox._opts.onChange("Ann KO, Bob KO, Draw")
  box.modeDD._opts.onSelect("fixed")
  T.ok(box.pricesBox:IsShown() and box.bankBox:IsShown(), "fixed: prices + bank")
  T.eq(box.bankHint:GetText(), "max 500g (self-declared)")
  box.pricesBox._opts.onChange("2.5, 3")
  btn("Create & open"):Click()
  T.eq(box.createErr:GetText(), "Fixed odds need 3 prices, 1.01 to 10.00.")
  box.pricesBox._opts.onChange("2.5, 3, 4")
  box.bankBox._opts.onChange("600")
  btn("Create & open"):Click()
  T.eq(box.createErr:GetText(), "Bank max at your level is 500g.")
  box.bankBox._opts.onChange("25g")
  btn("Create & open"):Click()
  local c = last()
  T.eq(c[1], "AddMarket")
  local spec = c[2]
  T.eq(spec.kind, "custom"); T.eq(spec.mode, "fixed"); T.eq(#spec.labels, 3); T.eq(spec.labels[3], "Draw")
  T.eq(spec.prices[1], 250); T.eq(spec.prices[3], 400); T.eq(spec.bank, 250000); T.eq(spec.open, true)
  T.ok(not box.create:IsShown(), "form closes after create")
  btn("Quick winner"):Click()
  spec = last()[2]
  T.eq(last()[1], "AddMarket"); T.eq(spec.kind, "winner"); T.eq(spec.mode, "pari")
  T.eq(spec.a, "Ann-Normal"); T.eq(spec.b, "Bob-Normal"); T.eq(spec.open, true)
  local sc = RV.ParseSpec({ kind = "score", mode = "pari" }, S)
  T.eq(sc.scope, "series")
  local none, why = RV.ParseSpec({ kind = "winner", a = "Ann-Normal", b = "Ann" }, S)
  T.eq(none, nil); T.eq(why, "Pick two different fighters.")
  local _, why2 = RV.ParseSpec({ kind = "winner", lockOn = "time", lockMin = "45" }, S)
  T.eq(why2, "Lock time: 1 to 30 minutes.")
  T.noErrors()
end)

T.test("HUD: active market name, pool and status; owed alert", function()
  local hud
  for _, f in ipairs(UIParent._children) do if f.pot and f.extra then hud = f end end
  T.ok(hud and hud:IsShown(), "hud shown")
  local ml = list("Market", "Kind")
  S.markets.m1.status = "open"
  ml._opts.onRowClick(rowOf(ml, "mid", "m1"))
  refresh()
  T.ok(hud.status:GetText():find("Winner · open", 1, true), hud.status:GetText())
  T.eq(hud.pot:GetText(), "0s")
  T.ok(hud.extra:GetText():find("Ann", 1, true), "pills: " .. hud.extra:GetText())
  fake.Debts = function() return { { role = "bettor", status = "due", amount = 344705, paid = 0 } } end
  refresh()
  T.eq(hud.extra:GetText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""), "Host owes you 34g 47s 05c")
  fake.Debts = function() return {} end
  S.status = "closed"
  refresh()
  T.ok(not hud:IsShown(), "hidden after close")
  T.ok(ns.UI.RingPane.idle:IsShown(), "back to the idle view")
  T.noErrors()
end)

T.done()
