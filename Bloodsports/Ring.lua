-- Ring: referee-run gambling ring session (host) and its mirrors on bettors. The addon only RECORDS trades and
-- computes parimutuel payouts; it never moves gold (trade acceptance is protected).
-- CONTRACT NOTE: session.fighters = { a = "Name-Realm", b = "Name-Realm" }; bets are rows
--   { bettor, on, side="a"|"b", amount, paid, payout, paidOut, void } (one bet per bettor, max 40 per session).
-- Wire (all fields strings): RB(id,on,amount) bettor->host; RS(id,status,venue,currency,a,b,poolA,poolB,count,winner,cap)
-- and RL(id,bettor,on,amount,paid,payout,paidOut) host->group. Pools/payouts count only PAID bets for gold
-- (all bets for points); unpaid gold bets are voided at settlement. Gold caps: default 50g, site "cap" (in gold)
-- clamped to 1000g so integer math stays exact; points cap 1000. A rejected RB is silent (bettor sees no RL).
-- Settlement whispers each bettor their own RL (4/s) then broadcasts RS; roster changes re-broadcast RS only.
-- Auto verdict settles immediately (also from "open", which locks the ring). Session is not persisted across reload.

local _, ns = ...
local MK = MetaKit
local U = MK.Util
local A = ns.A

local M = A:NewModule("Ring")
local Ring = {}
ns.Ring = Ring

local MAX_BETS = 40
local MAX_AMOUNT = 10000000          -- 1000 g in copper; keeps r*amount below 2^53
local DEFAULT_CAP_GOLD, DEFAULT_CAP_POINTS = 500000, 1000
local MAX_TRADES, MAX_RECORDS = 200, 200
local STATUS = { open = true, locked = true, settled = true, void = true, closed = true }
local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true, WHISPER = true }

Ring.session = nil
Ring.last = nil

---------------------------------------------------------------------------
-- Helpers

local function clean(s, max)
  s = tostring(s == nil and "" or s):gsub("[%c|]", "")
  return U.Truncate(s, max or 40)
end

local function validId(s) return type(s) == "string" and s:match("^%x+$") and #s <= 16 end

local function full(name)
  name = clean(name)
  if name == "" or name:find("%s") then return nil end
  return MK.FullName(name)
end

local function same(a, b)
  if not a or not b then return false end
  a, b = full(a), full(b)
  return a and b and a:lower() == b:lower() or false
end

local function shortLower(n) return ((tostring(n):match("^([^-]+)") or n)):lower() end

local function num(s, lo, hi)
  local n = tonumber(s)
  if not n or n ~= n then return lo end
  return U.Clamp(math.floor(n), lo, hi)
end

local function me() return (MK.PlayerKey()) end

local function inGroup(name)
  if not name then return false end
  local raid = IsInRaid()
  for i = 1, raid and 40 or 4 do
    local unit = (raid and "raid" or "party") .. i
    local n, realm = MK.Call(UnitName, unit)
    if n then
      local fullName = (realm and realm ~= "") and (n .. "-" .. realm) or MK.FullName(n)
      if fullName and fullName:lower() == name:lower() then return true end
    end
  end
  return false
end

local function side(s, name)
  if not s.fighters then return nil end
  if same(name, s.fighters.a) then return "a" end
  if same(name, s.fighters.b) then return "b" end
end

local function isHost(s) return s and s.isHost end
local function finished(s) return s.status == "settled" or s.status == "void" or s.status == "closed" end

local function countsInPool(s, b) return s.currency == "points" or b.paid end

local function findBet(s, bettor)
  for _, b in ipairs(s.bets) do
    if same(b.bettor, bettor) then return b end
  end
end

-- poolA, poolB, count. Host computes from bets; mirrors use the totals the host sent.
function Ring.Pools(s)
  s = s or Ring.session
  if not s then return 0, 0, 0 end
  if not isHost(s) and s.totals then return s.totals.a, s.totals.b, s.totals.count end
  local pa, pb = 0, 0
  for _, b in ipairs(s.bets) do
    if countsInPool(s, b) then
      if b.side == "a" then pa = pa + b.amount else pb = pb + b.amount end
    end
  end
  return pa, pb, #s.bets
end

function Ring.Cap(s)
  s = s or Ring.session
  if not s then return 0 end
  return s.cap
end

local function hostCap(currency, hostName)
  if currency == "points" then return DEFAULT_CAP_POINTS end
  local g = MK.Wom("bloodsports", "referees", hostName, "cap")
  if type(g) ~= "number" then g = MK.Wom("bloodsports", "referees", (select(2, MK.PlayerKey())), "cap") end
  if type(g) == "number" and g > 0 then return U.Clamp(math.floor(g * 10000), 1, MAX_AMOUNT) end
  return DEFAULT_CAP_GOLD
end

local function push(ev, s, extra)
  local row = { ev = ev, event = ev, id = s.id, host = s.host, venue = s.venue, currency = s.currency }
  for k, v in pairs(extra or {}) do row[k] = v end
  A:Push("ring", row)
end

local function updated() A:Fire("RING_UPDATED") end

---------------------------------------------------------------------------
-- Host broadcasts

local function stateFields(s)
  local pa, pb, count = Ring.Pools(s)
  return { s.id, s.status, s.venue or "", s.currency, s.fighters and s.fighters.a or "",
    s.fighters and s.fighters.b or "", string.format("%.0f", pa), string.format("%.0f", pb), count,
    s.winner or "", s.cap }
end

local function sendState(s)
  if ns.comm then ns.comm:Broadcast("RS", stateFields(s)) end
end

-- Bet line to the whole group, or whispered to `whisperTo` (whispers bypass the broadcast token bucket).
local function sendBet(s, b, whisperTo)
  if not ns.comm then return end
  local f = { s.id, b.bettor, b.on, string.format("%.0f", b.amount), b.paid and 1 or 0,
    string.format("%.0f", b.payout or 0), b.paidOut and 1 or 0 }
  if whisperTo then ns.comm:Send("RL", f, "WHISPER", whisperTo) else ns.comm:Broadcast("RL", f) end
end

---------------------------------------------------------------------------
-- Records for the bettor/host ledger (char.bets)

local function record(s)
  if s.recorded then return end
  s.recorded = true
  local pa, pb, count = Ring.Pools(s)
  local rec = { id = s.id, t = U.ServerTime(), role = isHost(s) and "host" or "bettor", host = s.host, venue = s.venue,
    currency = s.currency, a = s.fighters and s.fighters.a, b = s.fighters and s.fighters.b, winner = s.winner,
    status = s.status, poolA = pa, poolB = pb, count = count }
  if isHost(s) then
    rec.bets = U.Copy(s.bets)
  else
    local mine = findBet(s, me())
    if not mine then return end
    rec.bet = U.Copy(mine)
  end
  table.insert(ns.char.bets, rec)
  while #ns.char.bets > MAX_RECORDS do table.remove(ns.char.bets, 1) end
end

-- Net points over my bettor records (points mode ledger; no authority enforces it).
function Ring.PointsBalance()
  local sum = 0
  for _, r in ipairs(ns.char.bets) do
    if r.role == "bettor" and r.currency == "points" and r.bet and r.status ~= "closed" then
      sum = sum + (r.bet.payout or 0) - (r.bet.amount or 0)
    end
  end
  return sum
end

---------------------------------------------------------------------------
-- Host: lifecycle

function Ring.IsHost() return isHost(Ring.session) or false end

function Ring.Open(venueId)
  local s = Ring.session
  if s and not finished(s) then return false, "active" end
  if s and not isHost(s) then return false, "joined" end
  if not A.db.config.ring.enabled then return false, "disabled" end
  if not A.db.config.referee.available then return false, "referee" end
  if IsInGroup() and type(UnitIsGroupLeader) == "function" and not MK.Call(UnitIsGroupLeader, "player") then
    return false, "leader"
  end
  if venueId == nil and ns.venues then
    local v = ns.venues:Current()
    venueId = v and v.id
  end
  local venue = tostring(venueId or ""):match("^[%w_]+$") or ""
  local currency = A.db.config.ring.currency == "points" and "points" or "gold"
  s = { id = U.RandomHex(8), host = me(), isHost = true, venue = venue, fighters = {}, status = "open", bets = {},
    currency = currency, t = U.ServerTime() }
  s.cap = hostCap(currency, me())
  Ring.session = s
  push("open", s, { cap = s.cap })
  sendState(s)
  updated()
  return s
end

function Ring.SetFighters(a, b)
  local s = Ring.session
  if not isHost(s) or s.status ~= "open" or #s.bets > 0 then return false end
  a, b = full(a), full(b)
  if not a or not b or a:lower() == b:lower() then return false end
  s.fighters = { a = a, b = b }
  sendState(s)
  updated()
  return true
end

function Ring.Lock()
  local s = Ring.session
  if not isHost(s) or s.status ~= "open" then return false end
  s.status = "locked"
  push("lock", s, { count = #s.bets })
  sendState(s)
  updated()
  return true
end

local function share(loserPool, winnerPool, amount)
  local q = math.floor(loserPool / winnerPool)
  local r = loserPool - q * winnerPool
  return q * amount + math.floor(r * amount / winnerPool)
end

-- Parimutuel: winner = stake + loserPool * stake / winnerPool (floored); nobody on the winner -> refunds.
-- Returns payouts keyed by bet table. Pure over (bets, countFn) for tests.
function Ring.ComputePayouts(bets, winnerSide, counts)
  local pool = { a = 0, b = 0 }
  for _, b in ipairs(bets) do
    if counts(b) then pool[b.side] = pool[b.side] + b.amount end
  end
  local wp = pool[winnerSide or "a"]
  local lp = pool[winnerSide == "a" and "b" or "a"]
  local out = {}
  for _, b in ipairs(bets) do
    local p = 0
    if winnerSide and counts(b) then
      if wp == 0 then p = b.amount
      elseif b.side == winnerSide then p = b.amount + share(lp, wp, b.amount) end
    elseif not winnerSide and counts(b) then
      p = b.amount -- void: refund
    end
    out[b] = p
  end
  return out, pool
end

local function settle(s, winnerSide)
  local payouts = Ring.ComputePayouts(s.bets, winnerSide, function(b) return countsInPool(s, b) end)
  for _, b in ipairs(s.bets) do
    b.payout = payouts[b]
    b.void = (not countsInPool(s, b)) or nil
    if s.currency == "points" then b.paidOut = true end -- ledger only, nothing to hand over
  end
  s.status = winnerSide and "settled" or "void"
  s.winner = winnerSide and s.fighters[winnerSide] or nil
  s.settledAt = U.ServerTime()
  record(s)
  local pa, pb, count = Ring.Pools(s)
  push(winnerSide and "settle" or "void", s, { winner = s.winner, poolA = pa, poolB = pb, count = count })
  for _, b in ipairs(s.bets) do sendBet(s, b, b.bettor) end -- own line first: payouts arrive before the status
  sendState(s)
  updated()
end

function Ring.Verdict(winner, auto)
  local s = Ring.session
  if not isHost(s) or finished(s) or not s.fighters.a then return false end
  local w = side(s, winner)
  if not w then return false end
  if s.status == "open" then s.status = "locked" end
  if auto then s.auto = true end
  local loser = w == "a" and s.fighters.b or s.fighters.a
  -- referee verdict row: the site uses it to verify the fighters' duel reports (winner/loser by name)
  push("verdict", s, { winner = s.fighters[w], loser = loser, auto = auto and true or false })
  settle(s, w)
  return true
end

function Ring.Void()
  local s = Ring.session
  if not isHost(s) or finished(s) then return false end
  settle(s, nil)
  return true
end

function Ring.Close()
  local s = Ring.session
  if not isHost(s) or s.status == "closed" then return false end
  if not finished(s) then settle(s, nil) end
  s.unpaidOut = #Ring.Owed()
  s.status = "closed"
  push("close", s, { unpaidOut = s.unpaidOut })
  sendState(s)
  Ring.last = s
  Ring.session = nil
  updated()
  return true
end

-- Payouts still to hand out (host, gold): array of { bettor, amount }.
function Ring.Owed()
  local s = Ring.session or Ring.last
  local out = {}
  if not isHost(s) or s.status ~= "settled" and s.status ~= "void" and s.status ~= "closed" then return out end
  for _, b in ipairs(s.bets) do
    if (b.payout or 0) > 0 and not b.paidOut then out[#out + 1] = { bettor = b.bettor, amount = b.payout } end
  end
  return out
end

---------------------------------------------------------------------------
-- Bettor

function Ring.MyBet()
  local s = Ring.session
  return s and findBet(s, me())
end

function Ring.PlaceBet(fighterName, amount)
  local s = Ring.session
  if not s or isHost(s) then return false, "session" end
  if s.status ~= "open" then return false, "closed" end
  local on = side(s, fighterName)
  if not on then return false, "fighter" end
  amount = num(amount, 0, MAX_AMOUNT)
  if amount < 1 or amount > (s.cap or 0) then return false, "amount" end
  if side(s, me()) then return false, "fighter" end
  if findBet(s, me()) then return false, "duplicate" end
  if s.currency == "gold" then
    local have = MK.Call(GetMoney)
    if type(have) == "number" and have < amount then return false, "money" end
  end
  if not ns.comm or not ns.comm:Send("RB", { s.id, s.fighters[on], string.format("%.0f", amount) }, "WHISPER", s.host) then
    return false, "send"
  end
  s.pending = { on = s.fighters[on], amount = amount, t = GetTime() }
  updated()
  return true
end

local function onBet(sender, f)
  local s = Ring.session
  if not isHost(s) or s.status ~= "open" or f[1] ~= s.id then return end
  if not s.fighters.a or not inGroup(sender) or side(s, sender) or findBet(s, sender) then return end
  if #s.bets >= MAX_BETS then return end
  local on = side(s, f[2] or "")
  local amount = num(f[3], 0, MAX_AMOUNT)
  if not on or amount < 1 or amount > s.cap then return end
  local bet = { bettor = sender, on = s.fighters[on], side = on, amount = amount, paid = s.currency == "points",
    payout = 0, paidOut = false, t = U.ServerTime() }
  table.insert(s.bets, bet)
  push("bet", s, { bettor = sender, on = bet.on, amount = amount })
  sendBet(s, bet)
  sendState(s)
  updated()
end

---------------------------------------------------------------------------
-- Mirrors

local function onState(sender, f, channel)
  if not GROUP_CHANNELS[channel] then return end
  local id, status, currency = f[1], f[2], f[4]
  if not validId(id) or not STATUS[status] or (currency ~= "gold" and currency ~= "points") then return end
  local s = Ring.session
  if s and isHost(s) then return end
  if s and not same(sender, s.host) then return end
  if s and s.id ~= id then
    if not finished(s) then return end
    s = nil
  end
  if not s then
    if status == "closed" or not inGroup(sender) then return end
    s = { id = id, host = sender, venue = "", fighters = {}, bets = {}, currency = currency, status = status,
      totals = { a = 0, b = 0, count = 0 } }
    Ring.session = s
  end
  s.status = status
  s.venue = (clean(f[3], 24):match("^[%w_]*$")) or ""
  local fa, fb = clean(f[5]), clean(f[6])
  s.fighters = { a = fa ~= "" and fa or nil, b = fb ~= "" and fb or nil }
  s.totals = { a = num(f[7], 0, 1e12), b = num(f[8], 0, 1e12), count = num(f[9], 0, 999) }
  local w = clean(f[10])
  s.winner = w ~= "" and w or nil
  s.cap = num(f[11], 0, MAX_AMOUNT)
  if status == "settled" or status == "void" then record(s) end
  if status == "closed" then
    Ring.last = s
    Ring.session = nil
  end
  updated()
end

local function onLine(sender, f, channel)
  local s = Ring.session
  if not GROUP_CHANNELS[channel] or not s or isHost(s) or not same(sender, s.host) or f[1] ~= s.id then return end
  local bettor, on = full(f[2] or ""), clean(f[3])
  if not bettor or on == "" then return end
  local b = findBet(s, bettor)
  if not b then
    if #s.bets >= 60 then return end
    b = { bettor = bettor }
    table.insert(s.bets, b)
  end
  b.on = on
  b.side = side(s, on)
  b.amount = num(f[4], 0, MAX_AMOUNT)
  b.paid = f[5] == "1"
  b.payout = num(f[6], 0, 1e12)
  b.paidOut = f[7] == "1"
  if same(bettor, me()) then s.pending = nil end
  updated()
end

local function rebroadcast()
  local s = Ring.session
  if isHost(s) and s.status ~= "closed" then sendState(s) end
end

local function onRoster()
  local s = Ring.session
  if s and not isHost(s) and not IsInGroup() then
    Ring.session = nil
    updated()
  elseif isHost(s) then
    A:Debounce("ringRoster", 2, rebroadcast)
  end
end

function Ring.Leave()
  local s = Ring.session
  if s and not isHost(s) then
    Ring.session = nil
    updated()
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- Auto verdict from the duel system messages the host sees

local FALLBACK = { "^(.+) has defeated (.+) in a duel$", "^(.+) has fled from (.+) in a duel$" }
local function parseWinner(text)
  for _, name in ipairs({ "DUEL_WINNER_KNOCKOUT", "DUEL_WINNER_RETREAT" }) do
    if MK.Match then
      local w, l = MK.Match(name, text)
      if w then return w, l end
    end
  end
  if not MK.Match then
    local w, l = text:match(FALLBACK[1])
    if w then return w, l end
    l, w = text:match(FALLBACK[2]) -- "%2$s has fled from %1$s": first capture is the loser
    if w then return w, l end
  end
end

local function onSystem(_, text)
  local s = Ring.session
  if not isHost(s) or finished(s) or not s.fighters.a then return end
  text = MK.Safe(text)
  if type(text) ~= "string" then return end
  local w, l = parseWinner(text)
  if type(w) ~= "string" or type(l) ~= "string" then return end
  local wl, ll = shortLower(w), shortLower(l)
  local fa, fb = shortLower(s.fighters.a), shortLower(s.fighters.b)
  if (wl == fa and ll == fb) or (wl == fb and ll == fa) then Ring.Verdict(w, true) end
end

---------------------------------------------------------------------------
-- Trade recording (evidence only)

local trade, lastMoney

local function tradeMoney(fn)
  local v = MK.Call(fn)
  return type(v) == "number" and v or nil
end

local function matchRing(tr)
  local s = Ring.session
  if not isHost(s) or s.currency ~= "gold" or not tr.confirmed then return end
  local b = findBet(s, tr.partner)
  if not b then return end
  if tr.got > 0 and not b.paid and tr.got == b.amount and (s.status == "open" or s.status == "locked") then
    b.paid, b.paidAt = true, U.ServerTime()
    tr.ring = s.id
    push("paid", s, { bettor = b.bettor, amount = b.amount })
    sendBet(s, b)
    sendState(s)
    updated()
  elseif tr.gave > 0 and not b.paidOut and (b.payout or 0) == tr.gave and finished(s) then
    b.paidOut = true
    tr.ring = s.id
    push("payout", s, { bettor = b.bettor, amount = tr.gave })
    sendBet(s, b)
    updated()
  end
end

local function finalize(tr)
  if trade == tr then trade = nil end
  if type(tr.got) ~= "number" or type(tr.gave) ~= "number" then return end
  if tr.got == 0 and tr.gave == 0 then return end
  tr.confirmed = tr.delta == tr.got - tr.gave
  local row = { t = U.ServerTime(), partner = tr.partner, got = tr.got, gave = tr.gave, confirmed = tr.confirmed }
  matchRing(tr)
  row.ring = tr.ring
  table.insert(ns.char.trades, row)
  while #ns.char.trades > MAX_TRADES do table.remove(ns.char.trades, 1) end
end

local function onTradeShow()
  local info = MK.UnitInfo("npc")
  local name = info and info.name
  local partner = name and ((info.realm and info.realm ~= "") and (name .. "-" .. info.realm) or MK.FullName(name))
  lastMoney = MK.Call(GetMoney) or lastMoney
  trade = { partner = partner, delta = 0 }
end

local function onTradeAccept(_, p, t)
  if not trade then return end
  if (p == 1 or p == true) and (t == 1 or t == true) then
    trade.both = true
    trade.got = tradeMoney(GetTargetTradeMoney)
    trade.gave = tradeMoney(GetPlayerTradeMoney)
  else
    trade.both = false
  end
end

local function onTradeClosed()
  local tr = trade
  if not tr then return end
  if tr.both and tr.partner then
    tr.closed = true
    A:After(1, function() finalize(tr) end)
  else
    trade = nil
  end
end

local function onMoney()
  local now = MK.Call(GetMoney)
  if type(now) ~= "number" then return end
  if trade and lastMoney then trade.delta = trade.delta + (now - lastMoney) end
  lastMoney = now
end

---------------------------------------------------------------------------

---------------------------------------------------------------------------
-- Lead integration: auto-lock when the fight starts, and bet-line resync for players who join mid-session.

-- A fighter's addon tells the host the duel countdown began; the host locks betting.
local function onFightStart(sender, f)
  local s = Ring.session
  if not isHost(s) or s.status ~= "open" or f[1] ~= s.id or not side(s, sender) then return end
  Ring.Lock()
end

-- A mirror that sees fewer lines than the host's count asks for the full list (whispered back, rate-limited).
local resyncAt = {}
local function onResyncRequest(sender, f)
  local s = Ring.session
  if not isHost(s) or f[1] ~= s.id or not inGroup(sender) then return end
  local key = sender:lower()
  if resyncAt[key] and GetTime() - resyncAt[key] < 10 then return end
  resyncAt[key] = GetTime()
  for _, b in ipairs(s.bets) do sendBet(s, b, sender) end
end

A:Listen("DUEL_COUNTDOWN", function(rec)
  local s = Ring.session
  if not s or isHost(s) or s.status ~= "open" or not ns.comm then return end
  local opp = rec and rec.opp and rec.opp.name and full(rec.opp.name)
  if side(s, me()) and opp and side(s, opp) then ns.comm:Send("RF", { s.id }, "WHISPER", s.host) end
end)

A:Listen("RING_UPDATED", function()
  local s = Ring.session
  if not s or isHost(s) or not ns.comm or not s.totals then return end
  if (s.totals.count or 0) > #s.bets and (not s.resyncAt or GetTime() - s.resyncAt > 15) then
    s.resyncAt = GetTime()
    ns.comm:Send("RQ", { s.id }, "WHISPER", s.host)
  end
end)

function M:OnLogin()
  lastMoney = MK.Call(GetMoney)
  if ns.comm then
    ns.comm:On("RB", onBet)
    ns.comm:On("RS", onState)
    ns.comm:On("RL", onLine)
    ns.comm:On("RF", onFightStart)
    ns.comm:On("RQ", onResyncRequest)
  end
  A:On("CHAT_MSG_SYSTEM", onSystem)
  A:On("GROUP_ROSTER_UPDATE", onRoster)
  A:On("TRADE_SHOW", onTradeShow)
  A:On("TRADE_ACCEPT_UPDATE", onTradeAccept)
  A:On("TRADE_CLOSED", onTradeClosed)
  A:On("PLAYER_MONEY", onMoney)
end
