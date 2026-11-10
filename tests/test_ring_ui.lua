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

-- it11 owner defect: "Become referee" ran under "Open the ring". The stub records anchors and sizes only, so x is
-- resolved here from the TOPRIGHT-style anchors the header uses (frame right = anchor target's edge + x offset).
local function edges(f, root, W)
  if f == root then return 0, W end
  local pt, rel, rp, x = f:GetPoint(1)
  T.ok(pt and rel, "anchored")
  local rl, rr = edges(rel, root, W)
  local ax = (rp == "TOPLEFT" or rp == "BOTTOMLEFT" or rp == "LEFT") and rl or rr
  T.ok(pt == "TOPRIGHT" or pt == "RIGHT", "right-anchored header control (" .. tostring(pt) .. ")")
  local right = ax + (x or 0)
  return right - f:GetWidth(), right
end

T.test("ring header v15: native Become referee, label left, box 8 px in from the right edge on the heading line; Open the ring left of it", function()
  local box = ns.UI.RingPane
  local saved = fake.session
  fake.session = nil
  A.db.config.referee.available = true
  refresh()
  T.ok(box.idle:IsShown(), "idle view")
  local refCheck, openBtn
  for _, c in ipairs(made.checks) do if c._opts.label == "Become referee" then refCheck = c end end
  openBtn = btn("Open the ring")
  T.ok(refCheck and openBtn and openBtn:IsShown(), "both controls")
  T.eq(refCheck._opts.width, nil, "no guessed width")
  T.eq(refCheck._opts.native, true); T.eq(refCheck._opts.labelLeft, true)
  -- the stub accepts every template, so the native UICheckButtonTemplate path is the one exercised here
  -- v16 (judge4): the native box at 26 px (size passed through; the template sits pinned in a 26 px holder)
  -- judge5: 26 -> 30
  T.eq(refCheck._opts.size, 30)
  T.eq(refCheck.native, true, "native check"); T.eq(refCheck.boxSize, 30)
  T.eq(refCheck.box._template, "UICheckButtonTemplate")
  T.eq(refCheck.boxHolder:GetWidth(), 30); T.eq(refCheck.boxHolder:GetHeight(), 30)
  T.eq(refCheck.box:GetWidth(), 30)
  local labelW = refCheck.text:GetStringWidth()
  T.eq(refCheck:GetWidth(), 30 + 4 + labelW + 2, "checkbox frame = box + gap + measured label")
  T.eq(select(1, refCheck.text:GetPoint(1)), "RIGHT", "label on the box's left")
  T.eq(select(3, refCheck.text:GetPoint(1)), "LEFT")
  T.eq(openBtn._opts.variant, "primary"); T.eq(openBtn.tier, "primary"); T.eq(openBtn:GetHeight(), 22)
  T.ok(openBtn:GetWidth() >= openBtn:GetText():len() * 6, "button holds its label")
  for _, W in ipairs({ 640, 520 }) do
    box.idle:SetSize(W, 400)
    box.idle._scripts.OnSizeChanged(box.idle)
    local h = box.idleHead
    T.eq(h.stacked, false, W .. ": one row"); T.eq(h.rowW, W)
    local cl, cr = edges(refCheck, box.idle, W)
    local bl, br = edges(openBtn, box.idle, W)
    T.eq(cr, W - 8, "checkbox right edge 8 px in from the pane edge")
    T.ok(br <= cl - 8, string.format("%d: button right %d <= checkbox left %d - 8", W, br, cl))
    T.eq(cr - cl, refCheck:GetWidth())
    -- vertically centred on the heading line: RIGHT anchor at the heading's middle (top 8 + half its 12 px height)
    local pt, rel, rp, _, y = refCheck:GetPoint(1)
    T.eq(pt, "RIGHT"); T.eq(rel, box.idle); T.eq(rp, "TOPRIGHT"); T.eq(y, -14); T.eq(h.midY, -14)
    local headRight = 13 + 16 * 6   -- "Referees on duty" at the 6 px/char stub measure
    T.ok(bl >= headRight + 16, string.format("%d: button left %d clears the heading (right %d) by 16", W, bl, headRight))
  end
  -- too narrow for heading + button + checkbox: the button drops under the checkbox, still right-aligned
  box.idle:SetSize(box.idleHead.need - 1, 400)
  box.idle._scripts.OnSizeChanged(box.idle)
  T.eq(box.idleHead.stacked, true)
  local pt, rel, rp, x = openBtn:GetPoint(1)
  T.eq(pt, "TOPRIGHT"); T.eq(rel, box.idle); T.eq(x, -8)
  -- the checkbox never moves when the button hides (it owns the right edge)
  box.idle:SetSize(640, 400)
  A.db.config.referee.available = false
  refresh()
  T.eq(openBtn:IsShown(), false)
  local _, cr = edges(refCheck, box.idle, 640)
  T.eq(cr, 640 - 8, "same spot with the button hidden")
  -- session (host) view: Public / Auto-invite measured, 8 px apart, right-aligned; status clipped before them
  fake.session = session(true)
  refresh()
  box.live:SetSize(560, 400)
  box.liveHeadLayout(true)
  local lh = box.liveHead
  local pc, ac = box.pubCheck, box.autoCheck
  T.eq(pc:GetWidth(), 18 + 8 + pc.text:GetStringWidth() + 2); T.eq(ac:GetWidth(), 18 + 8 + ac.text:GetStringWidth() + 2)
  local pl, pr = edges(pc, box.live, 560)
  local al, ar = edges(ac, box.live, 560)
  T.eq(ar, 560 - 8); T.ok(al >= pr + 8, string.format("auto-invite left %d >= public right %d + 8", al, pr))
  T.ok(8 + lh.statusW + 8 <= pl, string.format("status (%d wide) ends before Public (%d)", lh.statusW, pl))
  fake.session = saved
  refresh()
  T.noErrors()
end)

-- v14 (JUDGE1 R-4..R-9). Stub limits: no real widths or rendering, so geometry is the computed column / anchor maths
-- (List:LayoutColumns at an explicit 690 px width), never pixels.
local function col(l, title) for _, c in ipairs(l.columns) do if c.title == title then return c end end end

T.test("ring lists v14: full-width columns at 690 px, 16 px gutters, Referee aligned with Host, inset chrome", function()
  local box = ns.UI.RingPane
  local refs, rings = box.refList, box.browser
  for _, l in ipairs({ refs, rings }) do
    T.eq(l._opts.chrome, "inset"); T.ok(l.chrome and l.chrome.bg and l.chrome.head, "dark inset + header strip")
    T.eq(l.gutter, 16); T.eq(l.headerHeight, 22)
    l:SetWidth(690); l:LayoutColumns()
    -- the columns span the whole content width (list - rail - 2 * PAD - 2 * inset edge)
    T.near(l.columnsWidth, 690 - l.scrollWidth - 8 - 2, 1e-6, "no empty right-hand band")
    -- every neighbouring pair of text boxes is >= 16 px apart
    local cs = l.columns
    for i = 2, #cs do
      T.ok(cs[i].textL - cs[i - 1].textR >= 16 - 1e-6, string.format("gutter %s|%s = %.1f", tostring(cs[i - 1].title),
        tostring(cs[i].title), cs[i].textL - cs[i - 1].textR))
    end
  end
  local bettors, stakes = col(rings, "Bettors"), col(rings, "Stakes")
  T.ok(stakes.textL - bettors.textR >= 16, "Bettors / Stakes no longer collide (was 9 px)")
  T.eq(bettors.align, "RIGHT"); T.eq(stakes.align, "RIGHT"); T.eq(col(rings, "Markets").align, "RIGHT")
  -- v15 (JUDGE3 R3): Referee 130 / Lvl 40 / Ring flex / Rating 64 / Seen 70; Host 170 / Ring 130 / Bookie flex
  T.eq(stakes.w, 60); T.eq(bettors.w, 62); T.eq(col(rings, "Host").w, 170); T.eq(col(rings, "Ring").w, 130)
  T.eq(col(refs, "Referee").w, 130); T.eq(col(refs, "Lvl").w, 40); T.eq(col(refs, "Rating").w, 64); T.eq(col(refs, "Seen").w, 70)
  T.eq(col(refs, "Lvl").align, "RIGHT"); T.eq(col(refs, "Seen").align, "RIGHT"); T.eq(col(refs, "Rating").align, "RIGHT")
  T.ok(col(refs, "Ring").w >= 160, "the referee Ring column takes the slack: " .. col(refs, "Ring").w)
  T.ok(col(rings, "Bookie").w >= 80, "Bookie takes the rings table's slack: " .. col(rings, "Bookie").w)
  -- one Ring x in both stacked tables (it was 936 vs 885 on screen)
  T.eq(col(refs, "Ring").x, col(rings, "Ring").x, "shared Ring column x")
  T.eq(col(refs, "Ring").textL, col(rings, "Ring").textL)
  -- the 22 px icon cell, then Referee and Host text at one x; the empty copy starts there too (F-11)
  T.eq(refs.columns[1].w, 22); T.eq(rings.columns[1].w, 22)
  T.eq(col(refs, "Referee").textL, col(rings, "Host").textL)
  local L = box.idleLayout
  T.eq(L.contentX, 13)
  T.eq(refs.emptyInset, col(refs, "Referee").textL, "empty copy at the first TEXT column, past the icon cell")
  T.eq(rings.emptyInset, col(rings, "Host").textL)
  T.eq(refs.columns[1].x + refs.gutter / 2 + 1, L.contentX, "lead icon at the content inset")
  -- header assert: no overlap, every label fits its text box, no overflow (stub 6 px/char measure)
  for _, l in ipairs({ refs, rings }) do
    T.eq(#l.headerIssues, 0, "header issues: " .. (l.headerIssues[1] and (l.headerIssues[1].kind .. " " .. tostring(l.headerIssues[1].title)) or ""))
  end
  T.eq(select(4, box.idleFoot:GetPoint(1)), L.contentX, "footer at the content inset")
  -- header plates: gold-dim small titles (kit tokens; the stub records no text colour here)
  local hi = K.ListHeaderInk
  T.near(hi[1], 0.84, 1e-6); T.near(hi[2], 0.66, 1e-6); T.near(hi[3], 0.30, 1e-6)
  T.near(K.ListInsetEdge[1], 61 / 255, 1e-6); T.near(K.ListInsetBg[4], 0.35, 1e-6)
  T.noErrors()
end)

T.test("ring idle v14: empty lists collapse to 2 rows with left copy + hints; footer status; section rules", function()
  local box = ns.UI.RingPane
  local saved = fake.session
  fake.session = nil
  local finder = ns.Finder
  ns.Finder = { List = function() return {} end }
  fake.Browser = function() return {} end
  refresh()
  local L = box.idleLayout
  T.eq(L.refRows, 2); T.eq(box.refList:GetHeight(), 22 + 2 + 2 * 22, "header + inset edges + 2 rows")
  T.eq(L.ringsH, 22 + 2 + 44); T.eq(box.browser:GetHeight(), 68)
  T.eq(box.refList:HeightFor(2) - box.refList.headerHeight - 2, 44, "body = 2 rows (44 px)")
  T.eq(box.refList.emptyText:IsShown(), true); T.eq(box.browser.emptyText:IsShown(), true)
  T.eq(box.refList.emptyText:GetText(), "No referee about. Goblins are on lunch.")
  T.eq(box.refList.emptyHintText:GetText(), "Tick Become referee to offer your services.")
  T.eq(box.browser.emptyHintText:GetText(), "Rings appear here when a host opens one nearby.")
  local pt, _, rp, x, y = box.refList.emptyText:GetPoint(1)
  T.eq(pt, "LEFT"); T.eq(rp, "TOPLEFT"); T.eq(x, box.refList.emptyInset); T.eq(y, -11, "row 1")
  T.eq(select(5, box.refList.emptyHintText:GetPoint(1)), -33, "row 2")
  -- the rings header follows the collapsed referee table (no 140 px void)
  T.eq(L.ringsHeadY, L.refTop - L.refH - 16)
  T.eq(box.idleFoot:GetText(), "0 referees · 0 rings nearby · no venue here")
  T.eq(RV.IdleFooter(1, 2, "Ratchet"), "1 referee · 2 rings nearby · venue Ratchet")
  T.eq(RV.IdleFooter(3, 1, "-"), "3 referees · 1 ring nearby · no venue here")
  -- 1 px gold-dim (138,106,46) rules under both section headers, full content width
  for _, r in ipairs({ box.ihRule, box.bhRule }) do
    T.eq(r:GetHeight(), 1)
    T.near(r.mkColor[1], 138 / 255, 1e-6); T.near(r.mkColor[2], 106 / 255, 1e-6); T.near(r.mkColor[3], 46 / 255, 1e-6)
    T.eq(r._points[1][1], "TOPLEFT"); T.eq(r._points[1][4], 0); T.eq(r._points[2][1], "TOPRIGHT")
  end
  -- helper copy: no apostrophe to mis-kern
  for _, f in ipairs(box.idle._children) do
    local t = f.GetText and f:GetText()
    if type(t) == "string" then T.ok(not t:find("ring's", 1, true), "no \"ring's\" in: " .. t) end
  end
  -- with data: referee table grows (max 6), the rings table fills down to the footer, footer counts follow
  ns.Finder = { List = function() return { { name = "Ref-Normal", class = "WARRIOR", level = 20, kind = "ref" },
    { name = "Zed-Normal", class = "MAGE", level = 30, kind = "ref" }, { name = "Kai-Normal", class = "ROGUE", level = 25, kind = "ref" } } end }
  fake.Browser = function() return { { host = "Hos-Normal", sid = "x1", venue = "ratchet", level = 2, nMarkets = 3, nBettors = 4 } } end
  refresh()
  L = box.idleLayout
  T.eq(L.refRows, 3); T.eq(box.refList:GetHeight(), box.refList:HeightFor(3))
  T.eq(L.ringsH, "fill"); T.eq(box.browser._points[2][1], "BOTTOMRIGHT"); T.eq(box.browser._points[2][5], L.footH)
  T.eq(box.idleFoot:GetText(), "3 referees · 1 ring nearby · no venue here")
  ns.Finder = finder
  fake.Browser = function() return {} end
  fake.session = saved
  refresh()
  T.noErrors()
end)

---------------------------------------------------------------------------
-- G2: series scope in the create form

T.test("create form: scope selector (Next round / Series winner) and Best-of for a series that has not started", function()
  local box = ns.UI.RingPane
  local saved = fake.session
  local H = session(true)
  fake.session = H
  refresh()
  local function reopen() if not box.create:IsShown() then btn("+ Market"):Click() end end
  reopen()
  box.modeDD._opts.onSelect("pari")   -- the earlier create test left the form on fixed odds
  box.kindDD._opts.onSelect("winner")
  -- live bo3: the scope selector shows, Best-of does not; default is the next round
  T.ok(box.scopeDD:IsShown() and not box.boDD:IsShown(), "live series: scope only")
  T.eq(box.form.scope, "fight")
  reopen()
  btn("Create & open"):Click()
  local spec = last()[2]
  T.eq(last()[1], "AddMarket"); T.eq(spec.kind, "winner"); T.eq(spec.scope, nil, "default scope is the next round")
  T.eq(spec.a, "Ann-Normal")
  reopen()
  box.scopeDD._opts.onSelect("series")
  T.ok(not box.fighterA:IsShown(), "a live series supplies its own fighters")
  reopen()
  btn("Create & open"):Click()
  spec = last()[2]
  T.eq(spec.scope, "series"); T.eq(spec.kind, "winner"); T.eq(spec.a, nil); T.eq(spec.bo, nil)
  -- no series (or a finished one): Best-of appears; scope only once bo > 1
  H.series = nil
  reopen()
  refresh()
  T.ok(box.boDD:IsShown() and not box.scopeDD:IsShown(), "no series: Best-of, no scope yet")
  box.boDD._opts.onSelect("3")
  T.ok(box.scopeDD:IsShown() and box.fighterA:IsShown(), "bo3 chosen: scope + fighters")
  box.scopeDD._opts.onSelect("series")
  box.form.a, box.form.b = "Ann-Normal", "Bob-Normal"
  reopen()
  btn("Create & open"):Click()
  spec = last()[2]
  T.eq(spec.scope, "series"); T.eq(spec.bo, 3); T.eq(spec.a, "Ann-Normal"); T.eq(spec.b, "Bob-Normal"); T.eq(spec.open, true)
  H.series = { id = "s0", bo = 3, done = true }
  reopen()
  refresh()
  T.ok(box.boDD:IsShown(), "a finished series is not a live one")
  -- score market before the start: fighters + bo
  reopen()
  box.kindDD._opts.onSelect("score")
  box.boDD._opts.onSelect("5")
  T.ok(box.fighterA:IsShown() and box.scoreL:IsShown(), "score: fighters named for the upcoming series")
  T.eq(box.scoreL:GetText(), "bo5 score, Ann first")
  reopen()
  btn("Create & open"):Click()
  spec = last()[2]
  T.eq(spec.kind, "score"); T.eq(spec.scope, "series"); T.eq(spec.bo, 5); T.eq(spec.a, "Ann-Normal")
  reopen()
  box.boDD._opts.onSelect("1")
  local n = #calls
  reopen()
  btn("Create & open"):Click()
  T.eq(#calls, n, "no bo, no score market"); T.eq(box.createErr:GetText(), "Score markets need a bo3 or bo5 series.")
  -- pure parse
  local sp = RV.ParseSpec({ kind = "winner", scope = "series", bo = 3, a = "Ann-Normal", b = "Bob-Normal" }, { fighters = {} })
  T.eq(sp.scope, "series"); T.eq(sp.bo, 3)
  local none, why = RV.ParseSpec({ kind = "winner", scope = "series", bo = 3 }, { fighters = {} })
  T.eq(none, nil); T.eq(why, "Pick two different fighters.")
  sp = RV.ParseSpec({ kind = "winner", scope = "series", bo = 1 }, { fighters = { a = "Ann-Normal", b = "Bob-Normal" } })
  T.eq(sp.scope, nil, "bo1 has no series scope")
  sp = RV.ParseSpec({ kind = "method", scope = "series", bo = 3 }, { fighters = { a = "Ann-Normal", b = "Bob-Normal" }, series = { bo = 3 } })
  T.eq(sp.scope, nil, "method markets stay fight-scoped")
  fake.session = saved
  box.form.kind, box.form.bo, box.form.scope = "winner", 1, "fight"
  box.kindDD._opts.onSelect("winner")
  btn("Cancel"):Click()
  refresh()
  T.noErrors()
end)

---------------------------------------------------------------------------
-- G4: unmatched gold

T.test("unmatched gold: candidate selection, header, five newest rows, Assign", function()
  local box = ns.UI.RingPane
  local saved = fake.session
  local t0 = GetServerTime()
  local H = session(true)
  H.series = nil
  H.markets = {
    m1 = { mid = "m1", kind = "winner", mode = "pari", title = "Winner", status = "open", result = 0,
      outcomes = { { label = "Ann", ref = "Ann-Normal", pool = 100000, n = 1 }, { label = "Bob", ref = "Bob-Normal", pool = 50000, n = 1 } },
      bets = { { bettor = "Cid-Normal", outcome = 1, amount = 100000, paid = false }, { bettor = "Dan-Normal", outcome = 2, amount = 50000, paid = false } } },
    m2 = { mid = "m2", kind = "winner", mode = "pari", title = "Old", status = "settled", result = 1,
      outcomes = { { label = "Ann", pool = 1, n = 1 }, { label = "Bob", pool = 1, n = 1 } },
      bets = { { bettor = "Cid-Normal", outcome = 1, amount = 100000, paid = true, payout = 200000, paidOutAmount = 50000 } } },
  }
  fake.session = H
  local rows = {
    { t = t0 - 3600, partner = "Eve-Normal", got = 20000, gave = 0, confirmed = true, matched = {}, reason = "nobet" },
    { t = t0 - 1800, partner = "Cid-Normal", got = 100000, gave = 0, confirmed = true, matched = {}, reason = "late" },
    { t = t0 - 600, partner = "Dan-Normal", got = 50000, gave = 0, confirmed = true, matched = {}, reason = "amount" },
    { t = t0 - 300, partner = "Cid-Normal", got = 0, gave = 150000, confirmed = true, matched = {}, reason = "late" },
    { t = t0 - 120, partner = "Zed-Normal", got = 10000, gave = 0, confirmed = true, matched = {}, reason = "nobet" },
    { t = t0 - 90, partner = "Cid-Normal", got = 30000, gave = 0, confirmed = true, matched = { "x" }, reason = "excess", excess = 5000 },
    { t = t0 - 45, partner = "Cid-Normal", got = 10000, gave = 10000, confirmed = true, matched = {}, reason = "both" },
  }
  ns.char.ring.unmatched = rows
  -- candidate rules
  local c, why = RV.UnmatchedCandidate(rows[2], H)
  T.eq(c.mid, "m1"); T.eq(c.bettor, "Cid-Normal"); T.eq(c.sid, H.id, "stake trade: Cid's one unpaid open bet")
  c = RV.UnmatchedCandidate(rows[3], H); T.eq(c.mid, "m1"); T.eq(c.bettor, "Dan-Normal")
  c = RV.UnmatchedCandidate(rows[4], H); T.eq(c.mid, "m2", "payout trade: the settled bet with a payout still owed")
  c, why = RV.UnmatchedCandidate(rows[1], H); T.eq(c, nil); T.eq(why, "none", "a stranger has no bet")
  c, why = RV.UnmatchedCandidate(rows[6], H); T.eq(c, nil); T.eq(why, "none", "partly booked rows are not one-click")
  c, why = RV.UnmatchedCandidate(rows[7], H); T.eq(c, nil); T.eq(why, "none", "a two-way trade is not one-click")
  H.markets.m2.bets[1].paidOutAmount = 200000
  c, why = RV.UnmatchedCandidate(rows[4], H); T.eq(c, nil); T.eq(why, "none", "payout already complete")
  H.markets.m2.bets[1].paidOutAmount = 50000
  -- two candidates: ambiguous until the selected market picks one
  H.markets.m3 = { mid = "m3", kind = "custom", mode = "pari", title = "Other", status = "locked", result = 0,
    outcomes = { { label = "Y", pool = 1, n = 1 }, { label = "N", pool = 1, n = 1 } },
    bets = { { bettor = "Cid-Normal", outcome = 1, amount = 100000, paid = false } } }
  c, why = RV.UnmatchedCandidate(rows[2], H); T.eq(c, nil); T.eq(why, "many")
  c = RV.UnmatchedCandidate(rows[2], H, "m3"); T.eq(c.mid, "m3", "selected market breaks the tie")
  c, why = RV.UnmatchedCandidate(rows[2], H, "m2"); T.eq(why, "many", "a market without a candidate does not")
  local V = RV.Unmatched(H, nil, t0)
  T.eq(V.count, 7); T.eq(V.sum, 20000 + 100000 + 50000 + 150000 + 10000 + 30000 + 20000)
  T.eq(V.text, "Unmatched: 38g from 7 trades"); T.eq(#V.rows, 5, "five rows at most")
  T.eq(V.rows[1].from, "Cid"); T.eq(V.rows[1].age, "45s"); T.eq(V.rows[5].from, "Dan"); T.eq(V.rows[5].age, "10m", "newest first")
  H.markets.m3 = nil
  -- the view: header, one line per row, Assign enabled only where there is something to assign to
  refresh()
  T.eq(box.umHead:GetText(), "Unmatched: 38g from 7 trades")
  T.ok(box.um:IsShown(), "unmatched block shown for the host")
  for i = 1, 5 do T.ok(box.umRows[i].frame:IsShown(), "row " .. i) end
  T.eq(box.umRows[1].text:GetText(), "1g · Cid · 45s ago")
  T.eq(box.umRows[1].button.mkEnabled, false, "two-way trade: grey")
  T.eq(box.umRows[2].button.mkEnabled, false, "partly booked: grey")
  T.eq(box.umRows[3].button.mkEnabled, false, "stranger: grey")
  T.eq(box.umRows[4].text:GetText(), "paid out 15g · Cid · 5m ago")
  T.eq(box.umRows[4].button.mkEnabled, true)
  T.eq(box.umRows[5].button.mkEnabled, true)
  T.eq(box.betsList._points[2][5], 18 + 5 * 20, "bets table gives up the strip")
  -- click Assign on Dan's stake: Ledger.Assign(tradeRow, sid, mid, bettor)
  local L, orig, got = ns.Ledger, ns.Ledger.Assign, nil
  L.Assign = function(...) got = { ... }; return true end
  box.umRows[5].button._opts.onClick()
  T.eq(got[1], rows[3], "the trade row"); T.eq(got[2], H.id); T.eq(got[3], "m1"); T.eq(got[4], "Dan-Normal")
  T.ok(T.printed[#T.printed]:find("Booked 5g from Dan to m1", 1, true), T.printed[#T.printed])
  -- ambiguous partner: hint instead of a guess
  H.markets.m3 = { mid = "m3", kind = "custom", mode = "pari", title = "Other", status = "locked", result = 0,
    outcomes = { { label = "Y", pool = 1, n = 1 }, { label = "N", pool = 1, n = 1 } },
    bets = { { bettor = "Dan-Normal", outcome = 1, amount = 50000, paid = false } } }
  got = nil
  local ml = list("Market", "Kind")
  ml._opts.onRowClick(rowOf(ml, "mid", "m2"))   -- the selected market has no bet from Dan: no tie-break
  refresh()
  T.eq(box.umRows[5].button.mkEnabled, true, "ambiguous stays clickable for the hint")
  box.umRows[5].button._opts.onClick()
  T.eq(got, nil, "nothing assigned")
  T.ok(T.printed[#T.printed]:find("Dan has several bets waiting", 1, true), T.printed[#T.printed])
  -- a failed booking says so
  H.markets.m3 = nil
  L.Assign = function() return false end
  box.umRows[5].button._opts.onClick()
  T.ok(T.printed[#T.printed]:find("Could not book that trade", 1, true), T.printed[#T.printed])
  L.Assign = orig
  -- spectators and an empty list show nothing
  fake.session = session(false)
  refresh()
  T.ok(not box.um:IsShown(), "bettors never see the host's ledger")
  fake.session = H
  ns.char.ring.unmatched = {}
  refresh()
  T.ok(not box.um:IsShown(), "empty list hides the block")
  T.eq(box.betsList._points[2][5], 0)
  ns.char.ring.unmatched = {}
  fake.session = saved
  refresh()
  T.noErrors()
end)

T.done()
