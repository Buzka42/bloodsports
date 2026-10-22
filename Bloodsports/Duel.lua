-- Duel engine: IDLE > REQUESTED > COUNTDOWN > ACTIVE <> OOB > ENDING > RESOLVED|VOID > IDLE. Reads only safe MetaKit
-- accessors (HP may be secret mid-duel -> nil fields), parses winner system messages, saves records via ns.SaveDuel.
--
-- CONTRACT NOTE: rec.firstBlood = the side that FIRST DROPPED below 100% ("me" = I bled first), literal reading of
--   IMPLEMENTATION 4.1. Stats.Summary().firstBloodRate = share of duels where the OPPONENT bled first (we drew first blood).
-- CONTRACT NOTE: rec.t = server time at resolution; rec.venue/venueKind are nil away from a venue; void duels are saved too.
-- CONTRACT NOTE: ns.Duel (state, rec, last, RecomputeStreaks) is shared with Confirm.lua.

local _, ns = ...
local MK = MetaKit
local U = MK.Util
local A = ns.A

local M = A:NewModule("Duel")
local D = { state = "IDLE", tok = 0 }
ns.Duel = D

local MAX_DUEL_SEC, REQUEST_SEC, ENDING_SEC = 600, 60, 2

local function short(n)
  if type(n) ~= "string" then return nil end
  return n:match("^([^%-]+)")
end

local function sameName(a, b)
  a, b = short(a), short(b)
  return a ~= nil and b ~= nil and a == b
end
D.SameName = sameName
D.Short = short

local function splitName(n)
  if type(n) ~= "string" then return nil end
  local name, realm = n:match("^([^%-]+)%-(.+)$")
  return name or n, realm
end

local function rnd(x) return math.floor(x + 0.5) end

local function setState(s)
  D.state = s
  D.tok = D.tok + 1
  return D.tok
end

local function stopTicker()
  if D.ticker then D.ticker:Cancel() D.ticker = nil end
end

---------------------------------------------------------------------------
-- Snapshot (taken out of combat, while everything is readable)

local function snapshot(oppName)
  local me = MK.UnitInfo("player") or {}
  local opp = { name = splitName(oppName) }
  if oppName then opp.realm = select(2, splitName(oppName)) end
  local t = MK.UnitInfo("target")
  if t and t.name and t.isPlayer ~= false and (oppName == nil or sameName(t.name, oppName)) then
    opp = { name = t.name, realm = t.realm, class = t.class, race = t.race, level = t.level }
  end
  local venue = ns.venues and MK.Call(ns.venues.Current, ns.venues)
  local map = ns.venues and MK.Call(ns.venues.Snapshot, ns.venues)
  local raid, size = MK.Call(IsInRaid), MK.Call(GetNumGroupMembers)
  D.meName = me.name or short(MK.PlayerKey())
  return {
    venue = venue and venue.id or nil, venueKind = venue and venue.kind or nil, map = map,
    me = { class = me.class, race = me.race, level = me.level },
    opp = opp, confirmed = "self",
    group = { raid = raid and true or false, size = tonumber(size) or 1 },
    v = ns.VERSION,
  }
end

local function cancel()
  stopTicker()
  D.rec = nil
  setState("IDLE")
end
D.Cancel = cancel

local function begin(oppName)
  if D.state ~= "IDLE" and D.state ~= "REQUESTED" and D.state ~= "COUNTDOWN" then return end
  stopTicker()
  D.rec = snapshot(oppName)
  local tok = setState("REQUESTED")
  A:After(REQUEST_SEC, function()
    if D.tok == tok then cancel() end -- never reached the countdown / ACTIVE
  end)
end

---------------------------------------------------------------------------
-- Sampling

local function track(side, pct)
  if type(pct) ~= "number" then return end
  pct = rnd(pct)
  side.hpEnd = pct
  if not side.minHp or pct < side.minHp then side.minHp = pct end
end

local function oppUnit(r)
  if not r.opp.name then return nil end
  for _, u in ipairs({ "target", "focus" }) do
    local n = MK.Call(UnitName, u)
    if n and sameName(n, r.opp.name) then return u end
  end
end

-- Exact health/max when readable (MK.HealthPct would read a real 1% as a 0..1 fraction), else MK.HealthPct.
local function pct(unit)
  local hp, max = MK.Call(UnitHealth, unit), MK.Call(UnitHealthMax, unit)
  if type(hp) == "number" and type(max) == "number" and max > 0 then return hp / max * 100 end
  return MK.HealthPct(unit)
end

local function sample()
  local r = D.rec
  if not r then return end
  local mp = pct("player")
  local u = oppUnit(r)
  local op = u and pct(u) or nil
  track(r.me, mp)
  track(r.opp, op)
  if not r.firstBlood then
    local ml, ol = mp and mp < 100, op and op < 100
    if ml and ol then r.firstBlood = mp <= op and "me" or "opp"
    elseif ml then r.firstBlood = "me"
    elseif ol then r.firstBlood = "opp" end
  end
end

---------------------------------------------------------------------------
-- Resolution

local function bump(s, won)
  if won then
    s.cur = (s.cur or 0) + 1
    if s.cur > (s.best or 0) then s.best = s.cur end
  else
    s.cur = 0
  end
end

-- Rebuilds streaks from history (used when a record becomes disputed or a referee flips a result).
function D.RecomputeStreaks()
  local st = ns.char and ns.char.streak
  if not st then return end
  local cur, best, venue, vbest = 0, 0, {}, {}
  for _, d in ipairs(ns.char.duels) do
    if (d.result == "win" or d.result == "loss") and d.confirmed ~= "disputed" then
      local w = d.result == "win"
      cur = w and cur + 1 or 0
      if cur > best then best = cur end
      if d.venue then
        venue[d.venue] = w and (venue[d.venue] or 0) + 1 or 0
        if venue[d.venue] > (vbest[d.venue] or 0) then vbest[d.venue] = venue[d.venue] end
      end
    end
  end
  st.cur, st.best, st.venue = cur, best, venue
end

local function finish(result, how)
  local r = D.rec
  if not r then return end
  sample()
  stopTicker()
  r.dur = D.t0 and (math.floor((GetTime() - D.t0) * 10 + 0.5) / 10) or 0
  r.t = U.ServerTime()
  r.result, r.how = result, how
  r.comeback = (result == "win" and r.me.minHp ~= nil and r.me.minHp < 20) or false
  r.id = r.id or U.RandomHex(16)
  if result ~= "void" then
    local st = ns.char.streak
    bump(st, result == "win")
    if r.venue then
      st.venue[r.venue] = result == "win" and (st.venue[r.venue] or 0) + 1 or 0
    end
  end
  D.last, D.rec, D.t0 = r, nil, nil
  setState("IDLE")
  ns.SaveDuel(r)
  A:Fire("DUEL_RESOLVED", r)
end

local function activate()
  if D.state ~= "COUNTDOWN" then return end
  setState("ACTIVE")
  D.t0 = GetTime()
  sample()
  D.ticker = A:Every(0.5, function()
    if D.state ~= "ACTIVE" and D.state ~= "OOB" then return end
    if GetTime() - D.t0 > MAX_DUEL_SEC then finish("void", "timeout") return end
    sample()
  end)
  A:Fire("DUEL_STARTED", D.rec)
end

local function onCountdown(n)
  if D.state == "REQUESTED" then
    setState("COUNTDOWN")
    D.actTok = 0
    A:Fire("DUEL_COUNTDOWN", D.rec)
  end
  if D.state ~= "COUNTDOWN" then return end
  D.actTok = D.actTok + 1
  local tok = D.actTok
  A:After(n <= 1 and 1 or n, function()
    if D.actTok == tok then activate() end
  end)
end

local function onWinner(winner, loser, how)
  local st = D.state
  local r = D.rec
  if not r or (st ~= "ACTIVE" and st ~= "OOB" and st ~= "ENDING") then return end
  local wMe, lMe = sameName(winner, D.meName), sameName(loser, D.meName)
  if not (wMe or lMe) then return end -- somebody else's duel nearby
  local other = wMe and loser or winner
  if r.opp.name and not sameName(other, r.opp.name) then return end
  if not r.opp.name then r.opp.name, r.opp.realm = splitName(other) end
  finish(wMe and "win" or "loss", how)
end

---------------------------------------------------------------------------
-- Events

A:On("DUEL_REQUESTED", function(_, name)
  begin(MK.Safe(name))
end)

A:On("CHAT_MSG_SYSTEM", function(_, msg)
  local text = MK.Safe(msg)
  if type(text) ~= "string" then return end
  if MK.Match("ERR_DUEL_REQUESTED", text) then
    if D.state == "IDLE" then begin(nil) end
    return
  end
  if D.state == "IDLE" then return end
  if MK.Match("ERR_DUEL_CANCELLED", text) then
    if D.state == "REQUESTED" or D.state == "COUNTDOWN" then cancel() end
    return
  end
  local n = MK.Match("DUEL_COUNTDOWN", text)
  if n then
    onCountdown(tonumber(n) or 1)
    return
  end
  local w, l = MK.Match("DUEL_WINNER_KNOCKOUT", text)
  if w then onWinner(w, l, "knockout") return end
  w, l = MK.Match("DUEL_WINNER_RETREAT", text)
  if w then onWinner(w, l, "retreat") end
end)

A:On("PLAYER_REGEN_DISABLED", function()
  if D.state == "COUNTDOWN" then activate() end
end)

A:On("UNIT_HEALTH", function(_, unit)
  if D.state ~= "ACTIVE" and D.state ~= "OOB" then return end
  unit = MK.Safe(unit)
  if unit == "player" or unit == "target" or unit == "focus" then sample() end
end)

A:On("DUEL_OUTOFBOUNDS", function()
  if D.state == "ACTIVE" then
    setState("OOB")
    D.rec.oob = (D.rec.oob or 0) + 1
  end
end)

A:On("DUEL_INBOUNDS", function()
  if D.state == "OOB" then
    D.state = "ACTIVE"
    D.tok = D.tok + 1
  end
end)

A:On("DUEL_FINISHED", function()
  local st = D.state
  if st == "REQUESTED" or st == "COUNTDOWN" then cancel() return end
  if st ~= "ACTIVE" and st ~= "OOB" then return end
  sample()
  local tok = setState("ENDING")
  A:After(ENDING_SEC, function()
    if D.tok == tok and D.state == "ENDING" then finish("void", "unknown") end
  end)
end)

function M:OnLogin()
  D.state = "IDLE"
end
