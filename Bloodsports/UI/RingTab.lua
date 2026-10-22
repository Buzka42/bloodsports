-- Ring tab: referee list + Ask invite while outside a session; full session view (bets, pools, bettor and host
-- controls) while inside one. Only the host (referee) sees invite and verdict controls.
-- CONTRACT NOTE: session.fighters accepted as { a, b } array or { a = , b = }; pools are computed from session.bets
-- (falling back to session.totals = { a, b }); fighter dropdown uses "Fighter A/B" so the strip shows the names.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI

local STATUS = {
  open = "Place yer bets!", locked = "No more bets! Fight's on.", settled = "We have a winner!", paid = "Payouts done. Pleasure!",
  void = "Fight's off. Stakes back to ya.",
}

---------------------------------------------------------------------------
-- Session helpers (also used by RingHUD)

function UI.Session()
  local s = ns.Ring and ns.Ring.session
  if type(s) == "table" and s.status ~= "closed" then return s end
end

function UI.IsHost(s)
  local key, name = MK.PlayerKey()
  return s and (UI.SameName(s.host, key) or UI.SameName(s.host, name)) or false
end

function UI.Fighters(s)
  local f = s.fighters or {}
  return f[1] or f.a, f[2] or f.b
end

function UI.Pools(s)
  local fa, fb = UI.Fighters(s)
  local a, b, n = 0, 0, 0
  for _, bet in pairs(s.bets or {}) do
    n = n + 1
    local amt = tonumber(bet.amount) or 0
    if fa and UI.SameName(bet.on, fa) then a = a + amt elseif fb and UI.SameName(bet.on, fb) then b = b + amt end
  end
  if n == 0 and type(s.totals) == "table" then a, b = s.totals[1] or s.totals.a or 0, s.totals[2] or s.totals.b or 0 end
  return a, b, a + b
end

local function roster()
  local out = {}
  local _, me = MK.PlayerKey()
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

local function build(pane)
  local k = UI.Kit()
  local db = UI.Db()
  local st = { pick = "a", amount = "" }
  local function noRing() A:Print("Ring unavailable.") end

  ---- idle view -----------------------------------------------------------
  local idle = CreateFrame("Frame", nil, pane)
  idle:SetAllPoints(pane)
  local ih = k.Label(idle, { text = "Referees on duty", font = "body", color = "accent", skin = UI.SKIN })
  ih:SetPoint("TOPLEFT", idle, "TOPLEFT", 8, -8)
  local ihint = k.Label(idle, { text = "Ask a referee for an invite and accept the party invite. That puts ya in the ring's layer.", font = "small", color = "muted" })
  ihint:SetPoint("TOPLEFT", idle, "TOPLEFT", 8, -30)
  local refCheck = k.Checkbox(idle, { label = "Become referee", checked = false, onChange = function(on)
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
  local nobody = k.Label(idle, { text = "No referee about. Goblins are on lunch.", font = "body", color = "muted" })
  nobody:SetPoint("CENTER", idle, "CENTER", 0, -20)
  local function ask(row)
    if not (ns.Finder and ns.Finder.RequestInvite) then A:Print("Finder unavailable.") return end
    UI.Try(ns.Finder.RequestInvite, row.full, "ref", row.venue)
  end
  local refList = k.List(idle, { skin = UI.SKIN, rowHeight = 22, columns = {
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
  refList:SetPoint("BOTTOMRIGHT", idle, "BOTTOMRIGHT", 0, 0)

  ---- live view -----------------------------------------------------------
  local live = CreateFrame("Frame", nil, pane)
  live:SetAllPoints(pane)
  local status = k.Label(live, { text = "", font = "body", color = "accent", skin = UI.SKIN })
  status:SetPoint("TOPLEFT", live, "TOPLEFT", 8, -6)
  local fightersL = k.Label(live, { text = "", font = "body" })
  fightersL:SetPoint("TOPLEFT", live, "TOPLEFT", 8, -28)
  local poolsL = k.Label(live, { text = "", font = "body" })
  poolsL:SetPoint("TOPLEFT", live, "TOPLEFT", 8, -46)
  local betList = k.List(live, { skin = UI.SKIN, rowHeight = 22, columns = {
    { key = "bettor", title = "Bettor", width = 100, kind = "text" },
    { key = "on", title = "On", width = 90, kind = "text" },
    { key = "amount", title = "Stake", width = 80, kind = "text", align = "RIGHT" },
    { key = "paid", title = "Paid", width = 40, kind = "text" },
  } })
  betList:SetPoint("TOPLEFT", live, "TOPLEFT", 0, -68)
  betList:SetPoint("BOTTOMLEFT", live, "BOTTOMLEFT", 0, 0)
  betList:SetWidth(320)

  local right = CreateFrame("Frame", nil, live)
  right:SetPoint("TOPLEFT", live, "TOPLEFT", 332, -6)
  right:SetPoint("BOTTOMRIGHT", live, "BOTTOMRIGHT", 0, 0)

  local bettor = CreateFrame("Frame", nil, right)
  bettor:SetPoint("TOPLEFT", right, "TOPLEFT", 0, 0)
  bettor:SetPoint("TOPRIGHT", right, "TOPRIGHT", 0, 0)
  bettor:SetHeight(110)
  local bh = k.Label(bettor, { text = "Yer bet", font = "body", color = "accent", skin = UI.SKIN })
  bh:SetPoint("TOPLEFT", bettor, "TOPLEFT", 0, 0)
  local pick = k.Dropdown(bettor, { width = 110, items = { { value = "a", text = "Fighter A" }, { value = "b", text = "Fighter B" } },
    onSelect = function(v) st.pick = UI.Val(v) or "a" end })
  pick:SetPoint("TOPLEFT", bettor, "TOPLEFT", 0, -24)
  if pick.SetValue then pick:SetValue("a") end
  local amount = k.EditBox(bettor, { width = 80, height = 22, maxLetters = 8, placeholder = "Amount", onChange = function(t)
    st.amount = type(t) == "string" and t or ""
  end })
  amount:SetPoint("LEFT", pick, "RIGHT", 6, 0)
  local unit = k.Label(bettor, { text = "", font = "small", color = "muted" })
  unit:SetPoint("LEFT", amount, "RIGHT", 6, 0)
  local place = k.Button(bettor, { text = "Place bet", width = 100, height = 24, variant = "accent", onClick = function()
    local s = UI.Session()
    if not (s and ns.Ring and ns.Ring.PlaceBet) then return noRing() end
    local fa, fb = UI.Fighters(s)
    local who = st.pick == "b" and fb or fa
    local amt = UI.ParseAmount(st.amount, s.currency)
    if not who then A:Print("No fighters yet.") return end
    if not amt then A:Print("Type an amount first (" .. (s.currency == "points" and "points" or "gold") .. ").") return end
    local _, why = UI.Try(ns.Ring.PlaceBet, who, amt)
    if why == "amount" then
      local min = s.currency == "points" and 1 or ns.Ring.LIMITS.minCopper
      A:Print("Bets run from " .. UI.Amount(min, s.currency) .. " to the table cap of " .. UI.Amount(s.cap, s.currency) .. ".")
    elseif why == "band" then
      local level, max = ns.Ring.Band(s.host)
      A:Print("Bookie level " .. level .. " takes bets up to " .. UI.Amount(max, "gold") .. ".")
    end
  end })
  place:SetPoint("TOPLEFT", bettor, "TOPLEFT", 0, -56)

  local host = CreateFrame("Frame", nil, right)
  host:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -112)
  host:SetPoint("BOTTOMRIGHT", right, "BOTTOMRIGHT", 0, 0)
  local hh = k.Label(host, { text = "Referee's table", font = "body", color = "accent", skin = UI.SKIN })
  hh:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
  local pickers = {}
  local sel = { a = nil, b = nil }
  local function pickerFor(key, names)
    if pickers[key] then return pickers[key] end
    local items = {}
    for _, n in ipairs(names) do items[#items + 1] = { value = n, text = n } end
    local set = {}
    for i, which in ipairs({ "a", "b" }) do
      local dd = k.Dropdown(host, { width = 110, items = items, onSelect = function(v) sel[which] = UI.Val(v) end })
      dd:SetPoint("TOPLEFT", host, "TOPLEFT", (i - 1) * 116, -22)
      set[which] = dd
    end
    pickers[key] = set
    return set
  end
  local function hostBtn(text, x, y, w, fn, variant)
    local b = k.Button(host, { text = text, width = w, height = 22, variant = variant, onClick = fn })
    b:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
    return b
  end
  local function ringCall(name, ...)
    if not (ns.Ring and ns.Ring[name]) then return noRing() end
    UI.Try(ns.Ring[name], ...)
  end
  hostBtn("Set fighters", 0, -48, 100, function()
    if sel.a and sel.b and sel.a ~= sel.b then ringCall("SetFighters", sel.a, sel.b) else A:Print("Pick two different fighters.") end
  end)
  hostBtn("Lock bets", 106, -48, 80, function() ringCall("Lock") end)
  hostBtn("A wins", 0, -74, 70, function()
    local s = UI.Session(); local fa = s and UI.Fighters(s)
    if fa then ringCall("Verdict", fa) end
  end)
  hostBtn("B wins", 76, -74, 70, function()
    local s = UI.Session(); local _, fb = s and UI.Fighters(s)
    if fb then ringCall("Verdict", fb) end
  end)
  hostBtn("Void", 152, -74, 54, function() ringCall("Void") end, "danger")
  hostBtn("Close ring", 212, -74, 80, function() ringCall("Close") end, "danger")
  local inviteL = k.Label(host, { text = "Invite from the finder", font = "small", color = "muted" })
  inviteL:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -102)
  local inviteList = k.List(host, { skin = UI.SKIN, rowHeight = 22, columns = {
    { key = "class", title = "", width = 28, kind = "class" },
    { key = "name", title = "Name", width = 90, kind = "text" },
    { key = "level", title = "Lvl", width = 30, kind = "text" },
    { key = "i", title = "", width = 60, kind = "button", buttonText = "Invite", onClick = function(r)
      if not (ns.Finder and ns.Finder.Invite) then A:Print("Finder unavailable.") return end
      local s = UI.Session()
      UI.Try(ns.Finder.Invite, r.full, { kind = "ring", venue = s and s.venue, note = "" })
    end },
  } })
  inviteList:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -118)
  inviteList:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
  pane.idle, pane.live, pane.betList, pane.refList = idle, live, betList, refList

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

  return function()
    local s = UI.Session()
    idle:SetShown(not s)
    live:SetShown(s and true or false)
    if not s then
      local on = A.db.config.referee.available
      refCheck:SetChecked(on)
      openBtn:SetShown(on and true or false)
      local rows = finderRows({ "ref" })
      refList:SetData(rows)
      nobody:SetShown(#rows == 0)
      if not ns.Finder then nobody:SetText("Finder unavailable.") end
      return
    end
    local isHost = UI.IsHost(s)
    local fa, fb = UI.Fighters(s)
    local a, b, total = UI.Pools(s)
    local cur = s.currency
    status:SetText(STATUS[s.status] or tostring(s.status or "?"))
    fightersL:SetText(UI.Tint("accent", "A") .. " " .. (fa and UI.Short(fa) or "?") .. "   vs   " .. UI.Tint("accent", "B") .. " " .. (fb and UI.Short(fb) or "?")
      .. "   " .. UI.Tint("muted", "(ref " .. UI.Short(s.host) .. ")"))
    poolsL:SetText("Pot " .. UI.Amount(total, cur) .. "   A: " .. UI.Amount(a, cur) .. "   B: " .. UI.Amount(b, cur))
    local rows = {}
    for _, bet in pairs(s.bets or {}) do
      rows[#rows + 1] = { bettor = UI.Short(bet.bettor), on = UI.Short(bet.on), amount = UI.Amount(bet.amount, cur),
        paid = bet.paid and UI.Tint("good", "yes") or "-" }
    end
    betList:SetData(rows)
    bettor:SetShown(not isHost)
    host:SetShown(isHost)
    unit:SetText(cur == "points" and "points" or "gold")
    if isHost then
      local names = roster()
      local key = table.concat(names, ",")
      for pk, set in pairs(pickers) do
        set.a:SetShown(pk == key); set.b:SetShown(pk == key)
      end
      pickerFor(key, names)
      pickers[key].a:Show(); pickers[key].b:Show()
      inviteList:SetData(finderRows({ "duel", "ring" }))
    end
  end
end

UI.RegisterTab("ring", build)
