-- Ring tab v2 (BETTING_CONTRACT §7): referee list + ring browser while outside a session; inside one, the market
-- list (kind, outcomes, odds mode, pool, status), the selected market's outcomes with odds pills, and either the
-- bet slip + my bets (spectator / bettor) or the referee's table (host: create market, open, lock, verdict, void,
-- dispute resolution, price edits, bets table with trade instructions).
-- CONTRACT NOTE: pure view helpers live on UI.RingView (tests and RingHUD use them). They read v2 sessions
--   (session.markets keyed by mid) and synthesize one winner/pari market "m1" for a v1 session (fighters + bets).
-- CONTRACT NOTE: pari pills follow §7: decimal T'/W' and implied floor(100*W'/T') with the slip's stake in T' and W';
--   "—" when nobody is on the outcome yet (W = 0). The payout estimate is §3.2 on that hypothetical pool.
-- CONTRACT NOTE: money is compact (MK.UI.ChromeDemoMoney via UI.Money: copper only when non-zero); points "350 pts".

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI

local floor, max, min = math.floor, math.max, math.min
local FINAL = { settled = true, void = true }
local DEF = { BET_MIN_COPPER = 10000, BET_CEILING_COPPER = 500000, DEFAULT_CAP_POINTS = 1000, MAX_MARKETS = 8,
  MAX_OUTCOMES = 8, MAX_BETTORS = 30, PRICE_MIN = 101, PRICE_MAX = 1000, APPEAL_SEC = 600, DISPUTE_TIMEOUT_SEC = 1800 }
local KIND_LABEL = { winner = "Winner", method = "Method", score = "Score", custom = "Custom" }
local KINDS = { "winner", "method", "score", "custom" }
local SESSION_LINE = { open = "Place yer bets!", closing = "Closing: last verdicts in appeal.", closed = "Ring closed.",
  stale = "Stale ring.", locked = "No more bets! Fight's on.", settled = "We have a winner!", void = "Fight's off." }
local REFUSE = {
  closed = "Market's not taking bets.", dup = "Ya already have a bet on this market.",
  fighter = "Fighters can't bet on their own fight.", full = "Ring's full: 30 bettors.",
  amount = "Over the table cap: max %s.", min = "Minimum bet is %s.", band = "Bookie band: max %s.",
  price = "Odds moved. Check the new price.", bank = "Bookie can't cover that: max %s.", money = "Not enough gold on ya.",
  flood = "Too many refused bets. Host stopped listening.", late = "Too late to dispute.", market = "Unknown market.",
  pick = "Pick an outcome.", noamount = "Type an amount (12g 50s).", send = "Could not reach the host.",
  session = "No ring session.", version = "Update Bloodsports to bet here.", duplicate = "Ya already have a bet here.",
}
local ADD_WHY = {
  session = "The ring is not open.", markets = "Eight markets is the limit.", series = "Needs a bo3 / bo5 series.",
  fighters = "Pick two different fighters.", outcomes = "2 to 8 outcomes.", lockAt = "Lock time: 1 to 30 minutes.",
  price = "Every price 1.01 to 10.00.", bank = "Bank is over your level's max.", money = "Not enough gold for that bank.",
  closed = "Market is not a draft.",
}

---------------------------------------------------------------------------
-- Session helpers (also used by RingHUD)

function UI.Session()
  local s = ns.Ring and ns.Ring.session
  if type(s) == "table" and s.status ~= "closed" then return s end
end

function UI.IsHost(s)
  local key, name = MK.CommKey(), select(2, MK.PlayerKey())
  return s and (UI.SameName(s.host, key) or UI.SameName(s.host, name)) or false
end

function UI.Fighters(s)
  local f = s.fighters or {}
  return f[1] or f.a, f[2] or f.b
end

-- v1 view: pools from session.bets by fighter name (falling back to session.totals).
function UI.Pools(s)
  local fa, fb = UI.Fighters(s)
  local a, b, n = 0, 0, 0
  local bets = rawget(s, "bets") or {}
  for _, bet in pairs(bets) do
    n = n + 1
    local amt = tonumber(bet.amount) or 0
    if fa and UI.SameName(bet.on, fa) then a = a + amt elseif fb and UI.SameName(bet.on, fb) then b = b + amt end
  end
  local t = rawget(s, "totals")
  if n == 0 and type(t) == "table" then a, b = t[1] or t.a or 0, t[2] or t.b or 0 end
  return a, b, a + b
end

local function roster()
  local out = {}
  local me = MK.CommKey():match("^([^-]+)")
  out[1] = me
  local n = (GetNumGroupMembers and GetNumGroupMembers() or 0) - 1
  for i = 1, n do
    local unit = (IsInRaid and IsInRaid() and "raid" or "party") .. i
    local name = MK.Call(UnitName, unit)
    if type(name) == "string" then out[#out + 1] = name end
  end
  return out
end

---------------------------------------------------------------------------
-- View helpers (pure; no frames)

local RV = {}
UI.RingView = RV

local function now() return MK.Util.ServerTime() end

function RV.C(key)
  local c = ns.Ring and ns.Ring.C
  local v = type(c) == "table" and c[key] or nil
  if v == nil then v = DEF[key] end
  return v
end

-- "9:41" / "1:02:03"; negative clamps to 0:00.
function RV.Clock(sec)
  sec = max(0, floor(tonumber(sec) or 0))
  local h, m, s = floor(sec / 3600), floor(sec % 3600 / 60), sec % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

function RV.IsHost(s)
  if not s then return false end
  local h = rawget(s, "isHost")
  if h ~= nil then return h and true or false end
  return UI.IsHost(s)
end

local function me() return MK.CommKey() end

local function v1Market(s)
  local fa, fb = UI.Fighters(s)
  local a, b = UI.Pools(s)
  local bets = {}
  for _, x in pairs(rawget(s, "bets") or {}) do
    local k = (fb and UI.SameName(x.on, fb) or x.side == "b") and 2 or 1
    bets[#bets + 1] = { bettor = x.bettor, outcome = k, amount = tonumber(x.amount) or 0, paid = x.paid, payout = x.payout,
      paidOut = x.paidOut, stakeSent = x.stakeSent }
  end
  local result = 0
  local w = rawget(s, "winner")
  if w then result = (fb and UI.SameName(w, fb)) and 2 or 1 end
  local st = s.status == "paid" and "settled" or s.status
  return { mid = "m1", v1 = true, kind = "winner", mode = "pari", title = "Winner", status = st, result = result,
    outcomes = { { label = fa and UI.Short(fa) or "Fighter A", ref = fa, pool = a },
      { label = fb and UI.Short(fb) or "Fighter B", ref = fb, pool = b } }, bets = bets }
end

-- Markets in mid order (v2), or the synthesized m1 of a v1 session.
function RV.Markets(s)
  if type(s) ~= "table" then return {} end
  local markets = rawget(s, "markets")
  if type(markets) ~= "table" then return { v1Market(s) } end
  local list = ns.Ring and ns.Ring.Markets and UI.Try(ns.Ring.Markets, s)
  if type(list) ~= "table" then
    list = {}
    for _, m in pairs(markets) do list[#list + 1] = m end
    table.sort(list, function(x, y) return tostring(x.mid) < tostring(y.mid) end)
  end
  return list
end

function RV.Market(s, mid)
  for _, m in ipairs(RV.Markets(s)) do if m.mid == mid then return m end end
end

local function counted(s, b) return s.currency == "points" or b.paid == true end

-- Pools P[k] (counted stakes), bettors n[k] and T. Host reads its bets; mirrors (and v1) read the host's numbers.
function RV.Pools(s, m)
  local P, n, T = {}, {}, 0
  local outs = m and m.outcomes or {}
  for k = 1, #outs do P[k], n[k] = 0, 0 end
  local fromBets = RV.IsHost(s) and not m.v1
  if not fromBets then
    for _, o in ipairs(outs) do if o.pool == nil then fromBets = true end end
  end
  if fromBets then
    for _, b in ipairs(m.bets or {}) do
      local k = b.outcome
      if k and P[k] then
        n[k] = n[k] + 1
        if counted(s, b) then P[k] = P[k] + (tonumber(b.amount) or 0) end
      end
    end
  else
    for k, o in ipairs(outs) do P[k], n[k] = tonumber(o.pool) or 0, tonumber(o.n) or 0 end
    if m.v1 then for _, b in ipairs(m.bets or {}) do if n[b.outcome] then n[b.outcome] = n[b.outcome] + 1 end end end
  end
  for _, p in ipairs(P) do T = T + p end
  return P, n, T
end

-- §3.2 share of one winning stake when the pools already hold it: amount + q*amount + floor(rem*amount/W).
function RV.Share(T, W, amount)
  if W <= 0 then return amount end
  local L = T - W
  local q = floor(L / W)
  local rem = L - q * W
  return amount + q * amount + floor(rem * amount / W)
end

-- Slip preview on the hypothetical pool (stake added to T and P[idx]).
-- Returns { W, T, T2, W2, d100 (decimal x100, floored), implied, payout (nil without a stake) }.
function RV.PariPreview(P, idx, stake)
  stake = max(0, floor(tonumber(stake) or 0))
  local T = 0
  for _, p in ipairs(P) do T = T + p end
  local W = P[idx] or 0
  local out = { W = W, T = T, T2 = T + stake, W2 = W + stake }
  if out.W2 > 0 then
    out.d100 = floor(out.T2 * 100 / out.W2)
    out.implied = floor(100 * out.W2 / out.T2)
  end
  if stake > 0 then out.payout = RV.Share(out.T2, out.W2, stake) end
  return out
end

-- "×2.87 est · 34%" (or "—" when nobody is on the outcome yet).
function RV.PariPill(pv)
  if not pv or pv.W == 0 or not pv.d100 then return "—" end
  return string.format("×%d.%02d est · %d%%", floor(pv.d100 / 100), pv.d100 % 100, pv.implied)
end

-- "1.80 · 55%" (price x100), "no price" while unset.
function RV.FixedPill(price)
  price = floor(tonumber(price) or 0)
  if price <= 100 then return "no price" end
  return string.format("%d.%02d · %d%%", floor(price / 100), price % 100, floor(10000 / price))
end

function RV.FixedPayout(amount, price)
  if ns.Ring and ns.Ring.FixedPayout then
    local v = UI.Try(ns.Ring.FixedPayout, amount, price)
    if type(v) == "number" then return v end
  end
  return floor(amount * price / 100)
end

-- Pill for outcome idx with an optional slip stake on it.
function RV.Pill(s, m, idx, stake)
  if m.mode == "fixed" then return RV.FixedPill(m.outcomes[idx] and m.outcomes[idx].price) end
  local P = RV.Pools(s, m)
  return RV.PariPill(RV.PariPreview(P, idx, stake))
end

-- Prospective payout of a slip (nil without a stake or outcome).
function RV.SlipPayout(s, m, idx, stake)
  if not (m and idx and m.outcomes[idx]) or not stake or stake <= 0 then return nil end
  if m.mode == "fixed" then
    local price = tonumber(m.outcomes[idx].price) or 0
    return price > 100 and RV.FixedPayout(stake, price) or nil
  end
  return RV.PariPreview((RV.Pools(s, m)), idx, stake).payout
end

function RV.MyBet(s, m)
  local key = me()
  for _, b in ipairs(m and m.bets or {}) do
    if UI.SameName(b.bettor, key) then return b end
  end
end

-- My payout: final once there is a verdict (§3.2 / §3.3, as the engine's localPayout), else the estimate if it wins.
function RV.MyPayout(s, m, b)
  if not b then return nil, false end
  local amount = tonumber(b.amount) or 0
  if not counted(s, b) then return 0, true end
  if m.status == "void" then return amount, true end
  local r = tonumber(m.result) or 0
  if m.mode == "fixed" then
    local p = RV.FixedPayout(amount, tonumber(b.price) or 0)
    if r > 0 then return b.outcome == r and p or 0, true end
    return p, false
  end
  local P, _, T = RV.Pools(s, m)
  if r > 0 then
    local W = P[r] or 0
    if W == 0 then return amount, true end
    return b.outcome == r and RV.Share(T, W, amount) or 0, true
  end
  return RV.Share(T, P[b.outcome] or 0, amount), false
end

-- One line for my bet's state (+ colour token).
function RV.MyBetState(s, m, b)
  if not b then return nil end
  local cur = s.currency
  local decided = FINAL[m.status] or (tonumber(m.result) or 0) > 0
  if b.void then
    if b.voidReason == "unpaid" then return "void: stake never reached the host", "bad" end
    return "void: stake back", "muted"
  end
  if not counted(s, b) then
    if decided then return "void: stake never reached the host", "bad" end
    if b.stakeSent then return "sent, awaiting host", "muted" end
    return "unpaid: trade " .. UI.Short(s.host) .. " " .. UI.Amount(b.amount, cur), "bad"
  end
  local payout, final = RV.MyPayout(s, m, b)
  if final and (payout or 0) == 0 then return "lost", "bad" end
  if final and FINAL[m.status] then
    if b.received or b.paidOut or cur == "points" then return "paid out " .. UI.Amount(payout, cur), "good" end
    return "host owes you " .. UI.Amount(payout - (tonumber(b.receivedAmount) or 0), cur), "bad"
  end
  if final then return "won: paid after the appeal window", "good" end
  if cur == "points" then return "counted", "good" end
  return "paid", "good"
end

-- Short market status for lists and the HUD (with the lock / appeal countdown).
function RV.MarketStatus(m, t)
  t = t or now()
  local st = m.status or "?"
  if st == "resolving" then return "appeal " .. RV.Clock((tonumber(m.appealUntil) or 0) - t) end
  if st == "open" and (tonumber(m.lockAt) or 0) > t then return "open " .. RV.Clock(m.lockAt - t) end
  if st == "disputed" and m.dispute and m.dispute.at then
    return "disputed " .. RV.Clock(m.dispute.at + RV.C("DISPUTE_TIMEOUT_SEC") - t)
  end
  return st
end

function RV.Label(m, idx)
  local o = m and m.outcomes and m.outcomes[idx]
  return o and o.label ~= "" and o.label or ("#" .. tostring(idx or "?"))
end

-- Market the HUD follows: the tab's selection while live, else disputed > resolving > open > locked > draft > last.
function RV.ActiveMarket(s, selected)
  local list = RV.Markets(s)
  for _, m in ipairs(list) do if selected and m.mid == selected and not FINAL[m.status] then return m end end
  for _, want in ipairs({ "disputed", "resolving", "open", "locked", "draft" }) do
    for _, m in ipairs(list) do if m.status == want then return m end end
  end
  return list[#list]
end

-- Debts owed to me (bettor role, not cleared): count, total.
function RV.OwedToMe()
  local n, sum = 0, 0
  local debts = ns.Ring and ns.Ring.Debts and UI.Try(ns.Ring.Debts) or {}
  for _, d in ipairs(type(debts) == "table" and debts or {}) do
    if d.role == "bettor" and d.status ~= "cleared" then
      local left = (tonumber(d.amount) or 0) - (tonumber(d.paid) or 0)
      if left > 0 then n, sum = n + 1, sum + left end
    end
  end
  return n, sum
end

-- Local §3.4 subset run before Place: closed, pick, dup, amount (min/cap), band, money. Returns code, max.
function RV.SlipCheck(s, m, idx, amount)
  if not s or not m then return "market", 0 end
  if s.readOnly then return "version", 0 end
  if s.status ~= "open" or m.status ~= "open" then return "closed", 0 end
  if not idx or not m.outcomes[idx] then return "pick", 0 end
  if RV.MyBet(s, m) then return "dup", 0 end
  if not amount then return "noamount", 0 end
  local gold = s.currency ~= "points"
  local minA = gold and RV.C("BET_MIN_COPPER") or 1
  local cap = tonumber(s.cap) or (gold and RV.C("BET_CEILING_COPPER") or RV.C("DEFAULT_CAP_POINTS"))
  if amount < minA then return "min", minA end
  if amount > cap then return "amount", cap end
  if gold then
    if ns.Ring and ns.Ring.Band then
      local _, band = UI.Try(ns.Ring.Band, s.host)
      if type(band) == "number" and amount > band then return "band", band end
    end
    local have = MK.Call(GetMoney)
    if type(have) == "number" and have < amount then return "money", 0 end
  end
end

function RV.RefusalText(code, maxv, currency)
  if not code then return "" end
  local t = REFUSE[code] or ("Refused: " .. tostring(code) .. ".")
  if t:find("%%s") then t = string.format(t, UI.Amount(maxv or 0, currency)) end
  return t
end

local function split(text)
  local out = {}
  for part in tostring(text or ""):gmatch("[^,;]+") do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then out[#out + 1] = part end
  end
  return out
end
RV.Split = split

-- Create-market form -> Ring.AddMarket spec, or nil + message. form = { kind, mode, a, b, labels, title, prices,
-- bank, lockOn, lockMin, open }.
function RV.ParseSpec(form, s)
  form = form or {}
  s = s or {}
  local kind = KIND_LABEL[form.kind] and form.kind or "winner"
  local mode = form.mode == "fixed" and "fixed" or "pari"
  local title = tostring(form.title or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local spec = { kind = kind, mode = mode, open = form.open and true or false, title = title ~= "" and title or nil }
  local maxOut = RV.C("MAX_OUTCOMES")
  local nOut
  if kind == "winner" or kind == "method" then
    local fa, fb = UI.Fighters(s)
    local a, b = form.a or fa, form.b or fb
    if not a or not b or UI.SameName(a, b) then return nil, "Pick two different fighters." end
    spec.a, spec.b = a, b
    nOut = kind == "winner" and 2 or 4
  elseif kind == "score" then
    local bo = s.series and tonumber(s.series.bo)
    if bo ~= 3 and bo ~= 5 then return nil, "Score markets need a bo3 or bo5 series." end
    spec.scope = "series"
    nOut = bo == 3 and 4 or 6
  else
    local labels = split(form.labels)
    if #labels < 2 then return nil, "Custom markets need 2 to " .. maxOut .. " labels, comma separated." end
    if #labels > maxOut then return nil, "At most " .. maxOut .. " outcomes per market." end
    spec.labels = labels
    nOut = #labels
  end
  if mode == "fixed" then
    local prices = {}
    for _, p in ipairs(split((tostring(form.prices or "")):gsub("%s+", ","))) do
      local v = tonumber(p)
      prices[#prices + 1] = v and floor(v * 100 + 0.5) or -1
    end
    local lo, hi = RV.C("PRICE_MIN"), RV.C("PRICE_MAX")
    local bad = #prices ~= nOut
    for _, p in ipairs(prices) do if p < lo or p > hi then bad = true end end
    if bad then return nil, string.format("Fixed odds need %d prices, 1.01 to 10.00.", nOut) end
    local bank = UI.ParseMoney(form.bank, s.currency)
    if not bank then return nil, "Fixed odds need a bank." end
    local bankMax = RV.BankMax(s)
    if bankMax and bank > bankMax then return nil, "Bank max at your level is " .. UI.Amount(bankMax, s.currency) .. "." end
    spec.prices, spec.bank = prices, bank
  end
  local lockOn = form.lockOn
  if lockOn == "time" then
    local mins = tonumber(form.lockMin)
    if not mins or mins < 1 or mins > 30 then return nil, "Lock time: 1 to 30 minutes." end
    spec.lockOn, spec.lockAt = "time", now() + floor(mins * 60)
  elseif lockOn == "fight" or lockOn == "manual" then
    spec.lockOn = lockOn
  end
  return spec
end

function RV.BankMax(s)
  if ns.Ring and ns.Ring.BankMax then
    local v = UI.Try(ns.Ring.BankMax, s and s.host)
    if type(v) == "number" then return v end
  end
end

-- Market list rows.
function RV.MarketRows(s)
  local rows, t = {}, now()
  for _, m in ipairs(RV.Markets(s)) do
    local _, _, T = RV.Pools(s, m)
    rows[#rows + 1] = { mid = m.mid, title = m.title or m.mid, kind = KIND_LABEL[m.kind] or tostring(m.kind or "?"),
      outs = #(m.outcomes or {}), mode = m.mode == "fixed" and "fixed" or "pari", pool = UI.Amount(T, s.currency),
      status = RV.MarketStatus(m, t), raw = m }
  end
  return rows
end

-- Outcome rows of one market, pills priced with the slip stake on each outcome.
function RV.OutcomeRows(s, m, stake)
  local rows = {}
  if not m then return rows end
  local P, n = RV.Pools(s, m)
  local r = tonumber(m.result) or 0
  for i, o in ipairs(m.outcomes or {}) do
    local label = RV.Label(m, i)
    if r == i and m.status ~= "void" then label = UI.Tint("good", label .. " (won)") end
    rows[#rows + 1] = { idx = i, label = label, pill = RV.Pill(s, m, i, stake), pool = UI.Amount(P[i] or 0, s.currency),
      n = tostring(n[i] or 0) }
  end
  return rows
end

---------------------------------------------------------------------------
-- Frames

local function build(pane)
  local k = UI.Kit()
  local st = { mid = nil, outIdx = nil, amount = "", create = false, dispute = "wrong",
    form = { kind = "winner", mode = "pari", lockOn = "fight", labels = "", title = "", prices = "", bank = "", lockMin = "" } }
  local box = {}
  pane.ring = box
  UI.RingPane = box   -- test / debug handle on the built widgets
  local function noRing() A:Print("Ring unavailable.") end
  local function ring(name, ...)
    if not (ns.Ring and ns.Ring[name]) then noRing() return nil end
    return UI.Try(ns.Ring[name], ...)
  end
  local function label(parent, text, font, color, width)
    local l = k.Label(parent, { text = text or "", font = font or "body", color = color, skin = UI.SKIN, width = width })
    if width and l.SetWordWrap then l:SetWordWrap(false) end
    return l
  end
  local function button(parent, text, w, fn, variant)
    return k.Button(parent, { text = text, width = w, height = 22, variant = variant, skin = UI.SKIN, onClick = fn })
  end
  local function primary(parent, text, w, fn)
    if k.Plate then
      local ok, p = pcall(k.Plate, parent, { kind = "gold", text = text, width = w, height = 24, onClick = fn })
      if ok and p then return p end
    end
    return k.Button(parent, { text = text, width = w, height = 24, variant = "accent", skin = UI.SKIN, onClick = fn })
  end
  local function enable(b, on) if b.SetEnabledState then b:SetEnabledState(on) end end
  -- Places the shown frames of a row left to right from x0 (hidden ones take no space).
  local function flow(parent, y, list, x0)
    local x = x0 or 0
    for _, f in ipairs(list) do
      if f:IsShown() then
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
        x = x + (f:GetWidth() or 80) + 6
      end
    end
  end
  local function session() return UI.Session() end
  local function market(s) return s and st.mid and RV.Market(s, st.mid) end
  local refresh   -- forward

  ---- idle view ----------------------------------------------------------
  local idle = CreateFrame("Frame", nil, pane)
  idle:SetAllPoints(pane)
  box.idle = idle
  local ih = label(idle, "Referees on duty", "body", "accent")
  ih:SetPoint("TOPLEFT", idle, "TOPLEFT", 8, -8)
  local ihint = label(idle, "Ask a referee for an invite and accept the party invite. That puts ya in the ring's layer.", "small", "muted")
  ihint:SetPoint("TOPLEFT", idle, "TOPLEFT", 8, -30)
  local refCheck = k.Checkbox(idle, { label = "Become referee", width = 120, checked = false, onChange = function(on)
    A.db.config.referee.available = on and true or false
    A:Fire("REFEREE_AVAILABILITY", A.db.config.referee.available)
    UI.Refresh()
  end })
  refCheck:SetPoint("TOPRIGHT", idle, "TOPRIGHT", -120, -6)
  local openBtn = k.Button(idle, { text = "Open the ring", width = 110, height = 22, variant = "accent", onClick = function()
    if not (ns.Ring and ns.Ring.Open) then return noRing() end
    local v = ns.venues and UI.Try(ns.venues.Current, ns.venues)
    UI.Try(ns.Ring.Open, v and v.kind == "ring" and v.id or nil)
  end })
  openBtn:SetPoint("TOPRIGHT", idle, "TOPRIGHT", -8, -6)
  local function ask(row)
    if not (ns.Finder and ns.Finder.RequestInvite) then A:Print("Finder unavailable.") return end
    UI.Try(ns.Finder.RequestInvite, row.full, "ref", row.venue)
  end
  local refList = k.List(idle, { skin = UI.SKIN, rowHeight = 22, zebra = true, empty = "No referee about. Goblins are on lunch.",
    columns = {
      { key = "class", title = "", width = 28, kind = "class" },
      { key = "name", title = "Referee", width = 120, kind = "text" },
      { key = "level", title = "Lvl", width = 32, kind = "text" },
      { key = "venueName", title = "Ring", width = 100, kind = "text" },
      { key = "rating", title = "Rating", width = 56, kind = "text" },
      { key = "seen", title = "Seen", width = 40, kind = "text" },
      { key = "w", title = "", width = 62, kind = "button", buttonText = "Whisper", onClick = function(r) UI.Whisper(r.full) end },
      { key = "a", title = "", width = 76, kind = "button", buttonText = "Ask invite", onClick = ask },
    } })
  refList:SetPoint("TOPLEFT", idle, "TOPLEFT", 0, -52)
  refList:SetPoint("RIGHT", idle, "RIGHT", 0, 0)
  refList:SetHeight(20 + 6 * 22)
  local bh = label(idle, "Rings nearby", "body", "accent")
  bh:SetPoint("TOPLEFT", idle, "TOPLEFT", 8, -214)
  local browser = k.List(idle, { skin = UI.SKIN, rowHeight = 22, zebra = true, empty = "No rings announced nearby.",
    columns = {
      { key = "name", title = "Host", width = 110, kind = "text" },
      { key = "venueName", title = "Ring", width = 110, kind = "text" },
      { key = "level", title = "Bookie", width = 50, kind = "text" },
      { key = "markets", title = "Markets", width = 56, kind = "text", align = "RIGHT" },
      { key = "bettors", title = "Bettors", width = 56, kind = "text", align = "RIGHT" },
      { key = "currency", title = "Stakes", width = 56, kind = "text" },
      { key = "join", title = "", width = 60, kind = "button", buttonText = "Join", onClick = function(r)
        ring("Join", r.host, r.sid)
      end },
    } })
  browser:SetPoint("TOPLEFT", idle, "TOPLEFT", 0, -234)
  browser:SetPoint("BOTTOMRIGHT", idle, "BOTTOMRIGHT", 0, 0)
  box.refList, box.browser = refList, browser
  pane.idle, pane.refList = idle, refList

  ---- live view: header ----------------------------------------------------
  local live = CreateFrame("Frame", nil, pane)
  live:SetAllPoints(pane)
  box.live = live
  pane.live = live
  local status = label(live, "", "body", "accent", 440)
  status:SetPoint("TOPLEFT", live, "TOPLEFT", 8, -4)
  local detail = label(live, "", "small", "muted", 680)
  detail:SetPoint("TOPLEFT", live, "TOPLEFT", 8, -24)
  box.status, box.detail = status, detail

  -- host bar
  local hostBar = CreateFrame("Frame", nil, live)
  hostBar:SetPoint("TOPLEFT", live, "TOPLEFT", 0, -42)
  hostBar:SetPoint("TOPRIGHT", live, "TOPRIGHT", 0, -42)
  hostBar:SetHeight(26)
  box.hostBar = hostBar
  local pubCheck = k.Checkbox(live, { label = "Public", width = 70, checked = true, onChange = function(on) ring("SetPublic", on) end })
  pubCheck:SetPoint("TOPRIGHT", live, "TOPRIGHT", -96, -2)
  local autoCheck = k.Checkbox(live, { label = "Auto-invite", width = 92, checked = false, onChange = function(on) ring("SetAutoInvite", on) end })
  autoCheck:SetPoint("TOPRIGHT", live, "TOPRIGHT", 0, -2)
  box.pubCheck, box.autoCheck = pubCheck, autoCheck
  local addBtn = button(hostBar, "+ Market", 76, function() st.create = not st.create; refresh() end, "accent")
  local quickBtn = button(hostBar, "Quick winner", 96, function()
    local s = session()
    local spec, err = RV.ParseSpec({ kind = "winner", mode = "pari", a = st.form.a, b = st.form.b, open = true }, s)
    if not spec then A:Print(err .. " (+ Market picks fighters.)") return end
    local ok, why = ring("AddMarket", spec)
    if ok == false then A:Print(ADD_WHY[why] or tostring(why)) end
  end)
  local raidBtn = button(hostBar, "Form raid", 76, function() ring("FormRaid") end)
  local inviteBtn = button(hostBar, "Invite (0)", 80, function() ring("InviteQueued") end)
  local closeBtn = button(hostBar, "Close ring", 80, function() ring("Close") end, "danger")
  flow(hostBar, -2, { addBtn, quickBtn, raidBtn, inviteBtn, closeBtn })
  box.addBtn, box.quickBtn, box.inviteBtn = addBtn, quickBtn, inviteBtn

  -- spectator bar
  local specBar = CreateFrame("Frame", nil, live)
  specBar:SetPoint("TOPLEFT", live, "TOPLEFT", 0, -42)
  specBar:SetPoint("TOPRIGHT", live, "TOPRIGHT", 0, -42)
  specBar:SetHeight(26)
  box.specBar = specBar
  local owedL = label(specBar, "", "body", "bad", 420)
  owedL:SetPoint("TOPLEFT", specBar, "TOPLEFT", 8, -4)
  local leaveBtn = button(specBar, "Leave ring", 80, function() ring("Leave") end)
  leaveBtn:SetPoint("TOPRIGHT", specBar, "TOPRIGHT", 0, -2)
  box.owedL = owedL

  ---- live view: left column (markets + bets) -------------------------------
  local LW, TOP = 340, -72
  local left = CreateFrame("Frame", nil, live)
  left:SetPoint("TOPLEFT", live, "TOPLEFT", 0, TOP)
  left:SetPoint("BOTTOMLEFT", live, "BOTTOMLEFT", 0, 0)
  left:SetWidth(LW)
  local marketList = k.List(left, { skin = UI.SKIN, rowHeight = 22, zebra = true, selectable = true, selectedStrip = true,
    empty = "No markets yet.", emptyHint = "The referee adds them.",
    onRowClick = function(r) st.mid, st.outIdx, st.localRefusal = r.mid, nil, nil; refresh() end,
    columns = {
      { key = "title", title = "Market", width = 88, kind = "text" },
      { key = "kind", title = "Kind", width = 52, kind = "text" },
      { key = "outs", title = "Out", width = 28, kind = "text", align = "RIGHT" },
      { key = "mode", title = "Odds", width = 38, kind = "text" },
      { key = "pool", title = "Pool", width = 62, kind = "text", align = "RIGHT" },
      { key = "status", title = "Status", width = 64, kind = "text" },
    } })
  marketList:SetPoint("TOPLEFT", left, "TOPLEFT", 0, 0)
  marketList:SetPoint("RIGHT", left, "RIGHT", 0, 0)
  marketList:SetHeight(20 + 6 * 22)
  box.marketList = marketList
  local lowerH = label(left, "", "body", "accent")
  lowerH:SetPoint("TOPLEFT", left, "TOPLEFT", 8, -160)
  box.lowerH = lowerH
  local betsList = k.List(left, { skin = UI.SKIN, rowHeight = 22, zebra = true, empty = "No bets yet.",
    columns = {
      { key = "bettor", title = "Bettor", width = 72, kind = "text" },
      { key = "on", title = "On", width = 56, kind = "text" },
      { key = "amount", title = "Stake", width = 62, kind = "text", align = "RIGHT" },
      { key = "paid", title = "Paid", width = 44, kind = "text" },
      { key = "payout", title = "Payout", width = 62, kind = "text", align = "RIGHT" },
      { key = "out", title = "Out", width = 32, kind = "text" },
    } })
  betsList:SetPoint("TOPLEFT", left, "TOPLEFT", 0, -180)
  betsList:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", 0, 0)
  box.betsList = betsList
  local myBets
  if k.StatRows then
    local ok, f = pcall(k.StatRows, left, { skin = UI.SKIN, rowHeight = 30, valueWidth = 90 })
    if ok then myBets = f end
  end
  if myBets then
    myBets:SetPoint("TOPLEFT", left, "TOPLEFT", 0, -180)
    myBets:SetPoint("BOTTOMRIGHT", left, "BOTTOMRIGHT", 0, 0)
  end
  box.myBets = myBets

  ---- live view: right column (market detail) -------------------------------
  local right = CreateFrame("Frame", nil, live)
  right:SetPoint("TOPLEFT", live, "TOPLEFT", LW + 12, TOP)
  right:SetPoint("BOTTOMRIGHT", live, "BOTTOMRIGHT", 0, 0)
  local detailBox = CreateFrame("Frame", nil, right)
  detailBox:SetAllPoints(right)
  box.detailBox = detailBox
  local mTitle = label(detailBox, "", "body", "accent", 340)
  mTitle:SetPoint("TOPLEFT", detailBox, "TOPLEFT", 4, 0)
  local mSub = label(detailBox, "", "small", "muted", 340)
  mSub:SetPoint("TOPLEFT", detailBox, "TOPLEFT", 4, -18)
  box.mTitle, box.mSub = mTitle, mSub
  local outList = k.List(detailBox, { skin = UI.SKIN, rowHeight = 20, zebra = true, selectable = true, selectedStrip = true,
    empty = "Pick a market.",
    onRowClick = function(r) st.outIdx, st.localRefusal = r.idx, nil; refresh() end,
    columns = {
      { key = "label", title = "Outcome", width = 104, kind = "text" },
      { key = "pill", title = "Odds", width = 116, kind = "text" },
      { key = "pool", title = "Pool", width = 70, kind = "text", align = "RIGHT" },
      { key = "n", title = "Bets", width = 34, kind = "text", align = "RIGHT" },
    } })
  outList:SetPoint("TOPLEFT", detailBox, "TOPLEFT", 0, -34)
  outList:SetPoint("RIGHT", detailBox, "RIGHT", 0, 0)
  outList:SetHeight(20 + 8 * 20)
  box.outList = outList

  -- bet slip (spectator)
  local slip = CreateFrame("Frame", nil, detailBox)
  slip:SetPoint("TOPLEFT", detailBox, "TOPLEFT", 0, -222)
  slip:SetPoint("BOTTOMRIGHT", detailBox, "BOTTOMRIGHT", 0, 0)
  box.slip = slip
  local slipH = label(slip, "Bet slip", "body", "accent", 340)
  slipH:SetPoint("TOPLEFT", slip, "TOPLEFT", 4, 0)
  local slipForm = CreateFrame("Frame", nil, slip)
  slipForm:SetPoint("TOPLEFT", slip, "TOPLEFT", 0, -20)
  slipForm:SetPoint("BOTTOMRIGHT", slip, "BOTTOMRIGHT", 0, 0)
  box.slipForm = slipForm
  local amountBox = k.EditBox(slipForm, { width = 110, height = 22, maxLetters = 16, placeholder = "Amount", onChange = function(t)
    st.amount = type(t) == "string" and t or ""
    st.localRefusal = nil
    if box.updateSlip then box.updateSlip() end
  end })
  amountBox:SetPoint("TOPLEFT", slipForm, "TOPLEFT", 4, 0)
  local unitL = label(slipForm, "", "small", "muted", 200)
  unitL:SetPoint("LEFT", amountBox, "RIGHT", 8, 0)
  local payoutL = label(slipForm, "", "body", nil, 340)
  payoutL:SetPoint("TOPLEFT", slipForm, "TOPLEFT", 4, -30)
  local refuseL = label(slipForm, "", "small", "bad", 340)
  refuseL:SetPoint("TOPLEFT", slipForm, "TOPLEFT", 4, -50)
  local pendingL = label(slipForm, "", "small", "muted", 200)
  box.amountBox, box.unitL, box.payoutL, box.refuseL, box.pendingL = amountBox, unitL, payoutL, refuseL, pendingL
  local place = primary(slipForm, "Place bet", 110, function()
    local s = session()
    local m = market(s)
    if not (s and ns.Ring and ns.Ring.PlaceBet) then return noRing() end
    local amount = UI.ParseMoney(st.amount, s.currency)
    local code = RV.SlipCheck(s, m, st.outIdx, amount)
    if code then
      st.localRefusal = code
      if box.updateSlip then box.updateSlip() end
      return
    end
    local ok, why
    if m.v1 then ok, why = UI.Try(ns.Ring.PlaceBet, m.outcomes[st.outIdx].ref, amount)
    else ok, why = UI.Try(ns.Ring.PlaceBet, m.mid, st.outIdx, amount) end
    st.localRefusal = (ok == false) and why or nil
    refresh()
  end)
  place:SetPoint("TOPLEFT", slipForm, "TOPLEFT", 4, -72)
  pendingL:SetPoint("LEFT", place, "RIGHT", 8, 0)
  box.place = place

  -- my bet on the selected market (replaces the form once placed)
  local mine = CreateFrame("Frame", nil, slip)
  mine:SetPoint("TOPLEFT", slip, "TOPLEFT", 0, -20)
  mine:SetPoint("BOTTOMRIGHT", slip, "BOTTOMRIGHT", 0, 0)
  box.mine = mine
  local mineL = label(mine, "", "body", nil, 340)
  mineL:SetPoint("TOPLEFT", mine, "TOPLEFT", 4, 0)
  local mineState = label(mine, "", "small", "muted", 340)
  mineState:SetPoint("TOPLEFT", mine, "TOPLEFT", 4, -20)
  local disputeDD = k.Dropdown(mine, { width = 110, items = {
    { value = "wrong", text = "Wrong winner" }, { value = "early", text = "Called early" },
    { value = "foul", text = "Foul play" }, { value = "other", text = "Other" } },
    onSelect = function(v) st.dispute = UI.Val(v) or "wrong" end })
  disputeDD:SetPoint("TOPLEFT", mine, "TOPLEFT", 4, -42)
  if disputeDD.SetValue then disputeDD:SetValue("wrong") end
  local disputeBtn = button(mine, "Dispute", 76, function()
    local s = session()
    local m = market(s)
    if not m then return end
    local ok, why = ring("Dispute", m.mid, st.dispute)
    if ok == false then A:Print(RV.RefusalText(why)) end
  end, "danger")
  disputeBtn:SetPoint("LEFT", disputeDD, "RIGHT", 6, 0)
  local disputeL = label(mine, "", "small", "muted", 140)
  disputeL:SetPoint("LEFT", disputeBtn, "RIGHT", 8, 0)
  box.mineL, box.mineState, box.disputeDD, box.disputeBtn, box.disputeL = mineL, mineState, disputeDD, disputeBtn, disputeL

  -- referee's table (host)
  local hostCtl = CreateFrame("Frame", nil, detailBox)
  hostCtl:SetPoint("TOPLEFT", detailBox, "TOPLEFT", 0, -222)
  hostCtl:SetPoint("BOTTOMRIGHT", detailBox, "BOTTOMRIGHT", 0, 0)
  box.hostCtl = hostCtl
  local hh = label(hostCtl, "Referee's table", "body", "accent", 340)
  hh:SetPoint("TOPLEFT", hostCtl, "TOPLEFT", 4, 0)
  local function sel() local s = session(); return s, market(s) end
  local openB = button(hostCtl, "Open", 56, function() local _, m = sel(); if m then ring("OpenMarket", m.mid) end end, "accent")
  local lockB = button(hostCtl, "Lock", 56, function()
    local _, m = sel()
    if m then if m.v1 then ring("Lock") else ring("Lock", m.mid) end end
  end)
  local verdictB = button(hostCtl, "Verdict", 132, function()
    local _, m = sel()
    if not m then return end
    if not st.outIdx then A:Print("Pick the winning outcome first.") return end
    if m.v1 then ring("Verdict", m.outcomes[st.outIdx].ref) else ring("Verdict", m.mid, st.outIdx) end
  end, "accent")
  local voidB = button(hostCtl, "Void", 56, function()
    local _, m = sel()
    if m then if m.v1 then ring("Void") else ring("Void", m.mid) end end
  end, "danger")
  local upholdB = button(hostCtl, "Uphold", 64, function() local _, m = sel(); if m then ring("ResolveDispute", m.mid, "uphold") end end, "accent")
  local amendB = button(hostCtl, "Amend", 120, function()
    local _, m = sel()
    if not m then return end
    if not st.outIdx then A:Print("Pick the corrected outcome first.") return end
    ring("ResolveDispute", m.mid, "amend", st.outIdx)
  end)
  local voidDispB = button(hostCtl, "Void (dispute)", 100, function()
    local _, m = sel(); if m then ring("ResolveDispute", m.mid, "void") end
  end, "danger")
  local priceBox = k.EditBox(hostCtl, { width = 60, height = 22, maxLetters = 5, placeholder = "1.80", onChange = function(t)
    st.price = type(t) == "string" and t or ""
  end })
  local priceB = button(hostCtl, "Set price", 76, function()
    local _, m = sel()
    local v = tonumber(st.price or (priceBox.GetText and priceBox:GetText()))
    if not (m and st.outIdx and v) then A:Print("Pick an outcome and type a price (1.01 to 10.00).") return end
    if ring("SetPrice", m.mid, st.outIdx, floor(v * 100 + 0.5)) == false then A:Print("Price must be 1.01 to 10.00.") end
  end)
  local hostInfo = label(hostCtl, "", "small", "muted", 340)
  hostInfo:SetPoint("TOPLEFT", hostCtl, "TOPLEFT", 4, -78)
  local hostInfo2 = label(hostCtl, "", "small", "muted", 340)
  hostInfo2:SetPoint("TOPLEFT", hostCtl, "TOPLEFT", 4, -94)
  box.openB, box.lockB, box.verdictB, box.voidB = openB, lockB, verdictB, voidB
  box.upholdB, box.amendB, box.voidDispB, box.priceBox, box.priceB = upholdB, amendB, voidDispB, priceBox, priceB
  box.hostInfo, box.hostInfo2 = hostInfo, hostInfo2

  ---- create market (host) ---------------------------------------------------
  local create = CreateFrame("Frame", nil, right)
  create:SetAllPoints(right)
  box.create = create
  local ch = label(create, "New market", "body", "accent", 340)
  ch:SetPoint("TOPLEFT", create, "TOPLEFT", 4, 0)
  local function item(v, t) return { value = v, text = t } end
  local kindItems = {}
  for _, kd in ipairs(KINDS) do kindItems[#kindItems + 1] = item(kd, KIND_LABEL[kd]) end
  local kindDD = k.Dropdown(create, { width = 96, items = kindItems, onSelect = function(v) st.form.kind = UI.Val(v) or "winner"; refresh() end })
  kindDD:SetPoint("TOPLEFT", create, "TOPLEFT", 4, -22)
  local modeDD = k.Dropdown(create, { width = 92, items = { item("pari", "Parimutuel"), item("fixed", "Fixed odds") },
    onSelect = function(v) st.form.mode = UI.Val(v) or "pari"; refresh() end })
  modeDD:SetPoint("LEFT", kindDD, "RIGHT", 6, 0)
  local lockDD = k.Dropdown(create, { width = 92, items = { item("fight", "Lock at fight"), item("manual", "Lock by hand"), item("time", "Lock in min") },
    onSelect = function(v) st.form.lockOn = UI.Val(v) or "fight"; refresh() end })
  lockDD:SetPoint("LEFT", modeDD, "RIGHT", 6, 0)
  local minBox = k.EditBox(create, { width = 40, height = 22, maxLetters = 2, placeholder = "10", onChange = function(t) st.form.lockMin = t end })
  minBox:SetPoint("LEFT", lockDD, "RIGHT", 6, 0)
  for _, dd in ipairs({ { kindDD, "winner" }, { modeDD, "pari" }, { lockDD, "fight" } }) do
    if dd[1].SetValue then dd[1]:SetValue(dd[2]) end
  end
  local fighterA = k.Dropdown(create, { width = 120, items = {}, onSelect = function(v) st.form.a = UI.Val(v) end })
  fighterA:SetPoint("TOPLEFT", create, "TOPLEFT", 4, -52)
  local fighterB = k.Dropdown(create, { width = 120, items = {}, onSelect = function(v) st.form.b = UI.Val(v) end })
  fighterB:SetPoint("LEFT", fighterA, "RIGHT", 6, 0)
  local labelsBox = k.EditBox(create, { width = 320, height = 22, maxLetters = 200, placeholder = "Outcomes, comma separated (2 to 8)",
    onChange = function(t) st.form.labels = t end })
  labelsBox:SetPoint("TOPLEFT", create, "TOPLEFT", 4, -52)
  local scoreL = label(create, "", "small", "muted", 320)
  scoreL:SetPoint("TOPLEFT", create, "TOPLEFT", 4, -56)
  local titleBox = k.EditBox(create, { width = 180, height = 22, maxLetters = 32, placeholder = "Title (optional)",
    onChange = function(t) st.form.title = t end })
  titleBox:SetPoint("TOPLEFT", create, "TOPLEFT", 4, -82)
  local pricesBox = k.EditBox(create, { width = 180, height = 22, maxLetters = 60, placeholder = "Prices: 1.80, 2.10",
    onChange = function(t) st.form.prices = t end })
  pricesBox:SetPoint("TOPLEFT", create, "TOPLEFT", 4, -112)
  local bankBox = k.EditBox(create, { width = 80, height = 22, maxLetters = 12, placeholder = "Bank 25g",
    onChange = function(t) st.form.bank = t end })
  bankBox:SetPoint("LEFT", pricesBox, "RIGHT", 6, 0)
  local bankHint = label(create, "", "small", "muted", 140)
  bankHint:SetPoint("TOPLEFT", create, "TOPLEFT", 4, -138)
  local createErr = label(create, "", "small", "bad", 340)
  createErr:SetPoint("TOPLEFT", create, "TOPLEFT", 4, -156)
  local function submit(open)
    local s = session()
    st.form.open = open
    local spec, err = RV.ParseSpec(st.form, s)
    if not spec then createErr:SetText(err) return end
    local ok, why = ring("AddMarket", spec)
    if ok == false then createErr:SetText(ADD_WHY[why] or tostring(why)) return end
    createErr:SetText("")
    st.create = false
    if type(ok) == "table" and ok.mid then st.mid, st.outIdx = ok.mid, nil end
    refresh()
  end
  local createB = primary(create, "Create & open", 120, function() submit(true) end)
  createB:SetPoint("TOPLEFT", create, "TOPLEFT", 4, -178)
  local draftB = button(create, "Save draft", 84, function() submit(false) end)
  draftB:SetPoint("LEFT", createB, "RIGHT", 6, 0)
  local cancelB = button(create, "Cancel", 64, function() st.create = false; refresh() end)
  cancelB:SetPoint("LEFT", draftB, "RIGHT", 6, 0)
  box.kindDD, box.modeDD, box.lockDD, box.minBox, box.fighterA, box.fighterB = kindDD, modeDD, lockDD, minBox, fighterA, fighterB
  box.labelsBox, box.scoreL, box.pricesBox, box.bankBox, box.bankHint, box.createErr = labelsBox, scoreL, pricesBox, bankBox, bankHint, createErr
  box.createB, box.draftB = createB, draftB
  box.form = st.form
  box.state = st

  ---- refresh helpers -------------------------------------------------------
  local function finderRows(kinds)
    local rows = {}
    for _, kind in ipairs(kinds) do
      local list = ns.Finder and ns.Finder.List and UI.Try(ns.Finder.List, kind) or {}
      for _, e in ipairs(list) do
        rows[#rows + 1] = { full = e.name, name = UI.Short(e.name), class = e.class, level = e.level or "?", kind = e.kind,
          venue = e.venue, venueName = UI.VenueName(e.venue), seen = UI.Ago(e.seen),
          rating = type(e.rating) == "number" and string.format("%.1f*", e.rating) or "-" }
      end
    end
    return rows
  end
  local function browserRows()
    local rows = {}
    local list = ns.Ring and ns.Ring.Browser and UI.Try(ns.Ring.Browser) or {}
    for _, e in ipairs(type(list) == "table" and list or {}) do
      rows[#rows + 1] = { host = e.host, sid = e.sid, name = UI.Short(e.host), venueName = UI.VenueName(e.venue),
        level = "Lv" .. tostring(e.level or 1), markets = tostring(e.nMarkets or 0), bettors = (e.nBettors or 0) .. "/" .. RV.C("MAX_BETTORS"),
        currency = e.currency == "points" and "points" or "gold", join = e.update and false or "Join" }
    end
    return rows
  end

  -- Slip labels only (runs on every keystroke; never re-sets edit text).
  function box.updateSlip()
    local s = session()
    local m = market(s)
    if not (s and m) then return end
    local cur = s.currency
    local amount = UI.ParseMoney(st.amount, cur)
    unitL:SetText(cur == "points" and "points" or "gold: 12g 50s")
    local idx = st.outIdx
    local pv
    outList:SetData(RV.OutcomeRows(s, m, amount))
    if idx and m.outcomes[idx] then
      local payout = RV.SlipPayout(s, m, idx, amount)
      local pill = RV.Pill(s, m, idx, amount)
      slipH:SetText("Bet slip: " .. RV.Label(m, idx))
      if m.mode == "fixed" then
        payoutL:SetText(payout and ("Pays " .. UI.Amount(payout, cur) .. " · " .. pill) or pill)
      else
        pv = RV.PariPreview((RV.Pools(s, m)), idx, amount)
        payoutL:SetText(payout and ("Payout est " .. UI.Amount(payout, cur) .. " · " .. pill) or pill)
      end
    else
      slipH:SetText("Bet slip")
      payoutL:SetText("")
    end
    -- local checks block Place; the host's last R2X refusal only shows (a changed stake may pass)
    local code, maxv
    if st.localRefusal then code = st.localRefusal
    elseif amount then code, maxv = RV.SlipCheck(s, m, idx, amount) end
    if code == "noamount" or code == "pick" then code = nil end
    local blocked = code ~= nil
    local refusal = rawget(s, "refusal")
    if not code and type(refusal) == "table" and refusal.mid == m.mid then code, maxv = refusal.code, refusal.max end
    local hint = ""
    if code then hint = RV.RefusalText(code, maxv, cur)
    elseif pv and pv.W == 0 then hint = "First bet sets the odds."
    elseif m.mode == "pari" and idx then hint = "Estimate until the market locks." end
    refuseL:SetText(hint)
    if refuseL.SetColorKey then refuseL:SetColorKey(code and "bad" or "muted") end
    local pending = rawget(s, "pending")
    local busy = type(pending) == "table" and (pending.mid == nil or pending.mid == m.mid)
    pendingL:SetText(busy and ("Sent, awaiting host" .. (pending.nonce and (" (" .. pending.nonce .. ")") or "")) or "")
    enable(place, (not busy) and not blocked and m.status == "open" and s.status == "open" and idx ~= nil and amount ~= nil
      and not s.readOnly)
  end

  local function headerText(s, isHost)
    local cur = s.currency == "points" and "points" or "gold"
    local cap = UI.Amount(s.cap or 0, s.currency)
    local level, band = 1, nil
    if ns.Ring and ns.Ring.Band then level, band = UI.Try(ns.Ring.Band, s.host) end
    local bandTxt = "Lv" .. tostring(level or 1) .. (band and (" · " .. UI.Amount(band, "gold")) or "")
    local bettors, seen = 0, {}
    for _, m in ipairs(RV.Markets(s)) do
      for _, b in ipairs(m.bets or {}) do
        local key = tostring(b.bettor):lower()
        if not seen[key] then seen[key], bettors = true, bettors + 1 end
      end
    end
    local line = SESSION_LINE[s.status] or tostring(s.status or "?")
    if rawget(s, "hostOffline") then line = "Host offline." elseif rawget(s, "rejoining") then line = "Rejoining the ring..." end
    if s.readOnly then line = line .. "  " .. UI.Tint("bad", "(read-only: update Bloodsports)") end
    local parts = { (isHost and "Your ring" or ("Ref " .. UI.Short(s.host))), UI.VenueName(s.venue), cur, "cap " .. cap }
    if s.currency ~= "points" then parts[#parts + 1] = bandTxt end
    parts[#parts + 1] = "bettors " .. bettors .. "/" .. RV.C("MAX_BETTORS")
    if isHost then
      local joined = ns.Ring and ns.Ring.ChannelJoined and UI.Try(ns.Ring.ChannelJoined)
      parts[#parts + 1] = joined and UI.Tint("good", "channel on") or UI.Tint("muted", "channel off")
      parts[#parts + 1] = "watchers " .. #(rawget(s, "watchers") or {})
      local owed = ns.Ring and ns.Ring.Owed and UI.Try(ns.Ring.Owed) or {}
      if type(owed) == "table" and #owed > 0 then
        local sum = 0
        for _, o in ipairs(owed) do sum = sum + (tonumber(o.amount) or 0) end
        parts[#parts + 1] = UI.Tint("bad", "owed " .. #owed .. " · " .. UI.Amount(sum, s.currency))
      end
    end
    return line, table.concat(parts, "  ·  ")
  end

  local function hostBetRows(s, m)
    local rows = {}
    for _, b in ipairs(m and m.bets or {}) do
      local paid
      if b.void then paid = UI.Tint("muted", "void")
      elseif s.currency == "points" then paid = "pts"
      elseif b.paid then paid = UI.Tint("good", "paid")
      else paid = UI.Tint("bad", "owes") end
      local payout = tonumber(b.payout) or 0
      local outAmt = tonumber(b.paidOutAmount) or 0
      local out = "-"
      if b.paidOut then out = UI.Tint("good", "done")
      elseif payout > 0 and outAmt > 0 then out = "part"
      elseif payout > 0 and FINAL[m.status] then out = UI.Tint("bad", "due") end
      local on = RV.Label(m, b.outcome)
      if m.mode == "fixed" and (tonumber(b.price) or 0) > 0 then on = on .. " @" .. string.format("%d.%02d", floor(b.price / 100), b.price % 100) end
      rows[#rows + 1] = { bettor = UI.Short(b.bettor) .. (b.manual and "*" or ""), on = on, amount = UI.Amount(b.amount, s.currency),
        paid = paid, payout = payout > 0 and UI.Amount(payout, s.currency) or "-", out = out }
    end
    return rows
  end

  local function myBetSections(s)
    local rows = {}
    for _, m in ipairs(RV.Markets(s)) do
      local b = RV.MyBet(s, m)
      if b then
        local text, color = RV.MyBetState(s, m, b)
        local payout, final = RV.MyPayout(s, m, b)
        rows[#rows + 1] = { label = (m.title or m.mid) .. ": " .. UI.Amount(b.amount, s.currency) .. " on " .. RV.Label(m, b.outcome),
          sub = text, value = payout and ((final and "" or "est ") .. UI.Amount(payout, s.currency)) or "-",
          color = color == "bad" and "bad" or (color == "good" and "good" or nil) }
      end
    end
    if #rows == 0 then rows[1] = { label = "No bets yet.", sub = "Pick a market, an outcome and a stake.", value = "" } end
    return { { rows = rows } }
  end

  local function hostControls(s, m)
    local stt = m and m.status
    local fixed = m and m.mode == "fixed"
    openB:SetShown(stt == "draft")
    lockB:SetShown(stt == "open")
    verdictB:SetShown(stt == "open" or stt == "locked")
    voidB:SetShown(m ~= nil and not FINAL[stt] and stt ~= "disputed")
    upholdB:SetShown(stt == "disputed")
    amendB:SetShown(stt == "disputed")
    voidDispB:SetShown(stt == "disputed")
    priceBox:SetShown(fixed and (stt == "draft" or stt == "open") or false)
    priceB:SetShown(fixed and (stt == "draft" or stt == "open") or false)
    local pick = st.outIdx and m and RV.Label(m, st.outIdx) or "pick"
    verdictB:SetText("Verdict » " .. pick)
    amendB:SetText("Amend » " .. pick)
    enable(verdictB, st.outIdx ~= nil)
    enable(amendB, st.outIdx ~= nil and m ~= nil and st.outIdx ~= m.result)
    flow(hostCtl, -22, { openB, lockB, verdictB, voidB }, 4)
    flow(hostCtl, -50, { upholdB, amendB, voidDispB, priceBox, priceB }, 4)
    local info, info2 = "", ""
    local t = now()
    if not m then info = "Add a market to start taking bets."
    elseif stt == "resolving" then
      info = "Appeal window " .. RV.Clock((tonumber(m.appealUntil) or 0) - t) .. ": payouts are provisional."
    elseif stt == "disputed" then
      local d = m.dispute or {}
      info = UI.Tint("bad", "Disputed") .. " by " .. UI.Short(d.by) .. " (" .. tostring(d.code or "other") .. ")"
        .. (d.at and (" · auto-void in " .. RV.Clock(d.at + RV.C("DISPUTE_TIMEOUT_SEC") - t)) or "")
      info2 = d.note and d.note ~= "" and ("\"" .. d.note .. "\"") or ""
    elseif stt == "open" and (tonumber(m.lockAt) or 0) > t then
      info = "Locks in " .. RV.Clock(m.lockAt - t) .. "."
    elseif stt == "draft" then
      info = fixed and "Set every price, then Open." or "Draft: Open it to take bets."
    elseif FINAL[stt] then
      local owed = {}
      for _, b in ipairs(m.bets or {}) do
        local left = (tonumber(b.payout) or 0) - (tonumber(b.paidOutAmount) or 0)
        if left > 0 and not b.paidOut and s.currency ~= "points" then owed[#owed + 1] = UI.Short(b.bettor) .. " " .. UI.Amount(left, s.currency) end
      end
      info = #owed > 0 and ("Trade " .. table.concat(owed, ", ")) or (stt == "void" and "Void: stakes back." or "Settled. All paid out.")
      if (tonumber(m.dust) or 0) > 0 then info2 = "Dust kept: " .. UI.Amount(m.dust, s.currency) end
    end
    if fixed and m and (tonumber(m.bank) or 0) > 0 then
      info2 = (info2 ~= "" and (info2 .. "  ·  ") or "") .. "bank " .. UI.Amount(m.bank, s.currency) .. " (self-declared)"
    end
    hostInfo:SetText(info)
    hostInfo2:SetText(info2)
  end

  local function createForm(s)
    local f = st.form
    local names = roster()
    local fa, fb = UI.Fighters(s)
    local items, seen = {}, {}
    local cands = {}
    if fa then cands[#cands + 1] = fa end
    if fb then cands[#cands + 1] = fb end
    for _, n in ipairs(names) do cands[#cands + 1] = n end
    for _, n in ipairs(cands) do
      if n and not seen[UI.Short(n):lower()] then seen[UI.Short(n):lower()] = true; items[#items + 1] = { value = n, text = UI.Short(n) } end
    end
    if fighterA.SetItems then fighterA:SetItems(items); fighterB:SetItems(items) end
    if not f.a and fa and fighterA.SetValue then f.a = fa; fighterA:SetValue(fa) end
    if not f.b and fb and fighterB.SetValue then f.b = fb; fighterB:SetValue(fb) end
    local two = f.kind == "winner" or f.kind == "method"
    fighterA:SetShown(two)
    fighterB:SetShown(two)
    labelsBox:SetShown(f.kind == "custom")
    scoreL:SetShown(f.kind == "score")
    local bo = s.series and tonumber(s.series.bo)
    scoreL:SetText((bo == 3 and "bo3: 2-0, 2-1, 1-2, 0-2") or (bo == 5 and "bo5: 3-0, 3-1, 3-2, 2-3, 1-3, 0-3")
      or "Score markets need a bo3 / bo5 series.")
    local fixed = f.mode == "fixed"
    pricesBox:SetShown(fixed)
    bankBox:SetShown(fixed)
    bankHint:SetShown(fixed)
    local bm = RV.BankMax(s)
    bankHint:SetText(bm and ("max " .. UI.Amount(bm, s.currency) .. " (self-declared)") or "self-declared")
    minBox:SetShown(f.lockOn == "time")
    local nMarkets = #RV.Markets(s)
    enable(box.createB, nMarkets < RV.C("MAX_MARKETS"))
    enable(box.draftB, nMarkets < RV.C("MAX_MARKETS"))
  end

  refresh = function()
    local s = session()
    idle:SetShown(not s)
    live:SetShown(s and true or false)
    if not s then
      local on = A.db.config.referee.available
      refCheck:SetChecked(on)
      openBtn:SetShown(on and true or false)
      local rows = finderRows({ "ref" })
      refList:SetData(rows)
      if not ns.Finder and refList.SetEmptyText then refList:SetEmptyText("Finder unavailable.") end
      browser:SetData(browserRows())
      st.mid, st.outIdx, st.create = nil, nil, false
      UI.RingSelected = nil
      return
    end
    local isHost = RV.IsHost(s)
    local markets = RV.Markets(s)
    if not (st.mid and RV.Market(s, st.mid)) then
      local a = RV.ActiveMarket(s)
      st.mid, st.outIdx = a and a.mid or nil, nil
    end
    UI.RingSelected = st.mid
    local m = market(s)
    if m and st.outIdx and not m.outcomes[st.outIdx] then st.outIdx = nil end
    local line, det = headerText(s, isHost)
    status:SetText(line)
    detail:SetText(det)
    hostBar:SetShown(isHost)
    pubCheck:SetShown(isHost)
    autoCheck:SetShown(isHost)
    specBar:SetShown(not isHost)
    if isHost then
      pubCheck:SetChecked(s.public ~= false)
      autoCheck:SetChecked(s.autoInvite and true or false)
      inviteBtn:SetText("Invite (" .. #(rawget(s, "inviteQueue") or {}) .. ")")
      enable(addBtn, s.status == "open")
      enable(quickBtn, s.status == "open" and #markets < RV.C("MAX_MARKETS"))
    else
      local n, sum = RV.OwedToMe()
      owedL:SetText(n > 0 and ("Host owes you " .. UI.Amount(sum, s.currency)) or "")
    end
    -- markets
    local rows = RV.MarketRows(s)
    marketList:SetData(rows)
    local selIdx = false
    for i, r in ipairs(rows) do if r.mid == st.mid then selIdx = i end end
    marketList:SetSelected(selIdx)
    -- detail
    local amount = UI.ParseMoney(st.amount, s.currency)
    local creating = isHost and st.create
    create:SetShown(creating and true or false)
    detailBox:SetShown(not creating)
    if m then
      local bits = { KIND_LABEL[m.kind] or "?", m.mode == "fixed" and "fixed odds" or "parimutuel", #m.outcomes .. " outcomes" }
      if m.scope == "series" then bits[#bits + 1] = "series" end
      mTitle:SetText((m.title or m.mid) .. "  " .. UI.Tint("muted", "(" .. table.concat(bits, " · ") .. ")"))
      mSub:SetText("Status: " .. RV.MarketStatus(m))
    else
      mTitle:SetText(isHost and "No markets yet: + Market or Quick winner." or "No markets yet.")
      mSub:SetText("")
    end
    outList:SetData(RV.OutcomeRows(s, m, (not isHost) and amount or nil))
    outList:SetSelected(st.outIdx or false)
    slip:SetShown(not isHost)
    hostCtl:SetShown(isHost)
    if isHost then
      lowerH:SetText(m and ("Bets on " .. (m.title or m.mid)) or "Bets")
      betsList:SetShown(true)
      if myBets then myBets:SetShown(false) end
      betsList:SetData(hostBetRows(s, m))
      hostControls(s, m)
      if creating then createForm(s) end
    else
      lowerH:SetText("My bets")
      if myBets then
        betsList:SetShown(false)
        myBets:SetShown(true)
        myBets:SetSections(myBetSections(s))
      else
        betsList:SetShown(true)
        betsList:SetData(hostBetRows(s, m))
      end
      local b = m and RV.MyBet(s, m)
      slipForm:SetShown(m ~= nil and not b)
      mine:SetShown(b ~= nil)
      if b then
        local text, color = RV.MyBetState(s, m, b)
        local payout, final = RV.MyPayout(s, m, b)
        slipH:SetText("Your bet")
        mineL:SetText(UI.Amount(b.amount, s.currency) .. " on " .. RV.Label(m, b.outcome)
          .. (payout and ("  ·  " .. (final and "payout " or "pays est ") .. UI.Amount(payout, s.currency)) or ""))
        mineState:SetText(text)
        if mineState.SetColorKey then mineState:SetColorKey(color or "muted") end
        local canDispute = m.status == "resolving" and counted(s, b) and not m.disputeSent and not s.readOnly
        disputeDD:SetShown(canDispute)
        disputeBtn:SetShown(canDispute)
        local dtext = ""
        if m.status == "resolving" then
          dtext = m.disputeSent and "Dispute sent." or ("closes in " .. RV.Clock((tonumber(m.appealUntil) or 0) - now()))
        elseif m.status == "disputed" then dtext = "Under dispute: the referee decides." end
        disputeL:SetText(dtext)
        if not canDispute then disputeL:ClearAllPoints(); disputeL:SetPoint("TOPLEFT", mine, "TOPLEFT", 4, -44)
        else disputeL:ClearAllPoints(); disputeL:SetPoint("LEFT", disputeBtn, "RIGHT", 8, 0) end
      else
        box.updateSlip()
      end
    end
  end

  return refresh
end

UI.RegisterTab("ring", build)
