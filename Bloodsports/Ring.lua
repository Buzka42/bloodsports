-- Ring v2: referee-run betting session (host = referee = bookie) with up to 8 markets, and its mirrors on bettors.
-- The addon never moves gold: it records trades (Ledger.lua), computes payouts and prints instructions.
-- Spec: elders/docs/BETTING_CONTRACT.md (data model §1, state machines §2, odds math §3, wire §4, outbox §5, ledger §6).
-- CONTRACT NOTE: session.markets is keyed by mid ("m1".."m8", never reused; s.nextMid counts them); Ring.Markets(s)
--   returns them in mid order. The session is write-through into BloodsportsDB.chars[key].ring.session.
-- CONTRACT NOTE: v1 API kept as thin wrappers over market m1: SetFighters creates m1 (winner, pari, open),
--   Verdict(name)/Lock()/Void() act on m1 (Lock()/Void() with no mid act on every non-final market). s.bets / s.winner /
--   s.auto / s.totals read m1 through a metatable (not persisted). Session status is open|closing|closed|stale; market
--   status lives on the market. Verdicts pass through "resolving" (10 min appeal) before "settled".
-- CONTRACT NOTE: v1 RB is accepted for m1 only when m1 is winner+pari and the sender is in the group (v1 clients only
--   see rings through their group); v1 RS/RL are still emitted for m1. v1 bettors (only RS seen) keep the v1 mirror.
-- CONTRACT NOTE: R2S/R2M/R2O go to the WoMRing channel only while the session has outside watchers (R2J senders or
--   non-group bettors); without the channel they are whispered to those watchers on status changes only.

local _, ns = ...
local MK = MetaKit
local U = MK.Util
local A = ns.A

local M = A:NewModule("Ring")
local Ring = {}
ns.Ring = Ring

---------------------------------------------------------------------------
-- Constants (§1.1, mirrored in wom-backend logic.ts)

local COPPER_PER_GOLD = 10000
local GAMBLE_MIN_COPPER = 1 * COPPER_PER_GOLD    -- BET_MIN_COPPER
local GAMBLE_MAX_COPPER = 50 * COPPER_PER_GOLD   -- BET_CEILING_COPPER (2000000 in 1.2)
local DEFAULT_CAP_GOLD, DEFAULT_CAP_POINTS = GAMBLE_MAX_COPPER, 1000
local BAND_GOLD_PER_LEVEL, MAX_LEVEL = 10, 5
local MAX_MARKETS, MAX_OUTCOMES, MAX_BETTORS = 8, 8, 30
local PRICE_MIN, PRICE_MAX = 101, 1000
local APPEAL_SEC, DISPUTE_TIMEOUT_SEC, OPEN_MAX_SEC, STALE_SEC = 600, 1800, 3600, 7200
local OWES_GRACE_SEC, OWES_BACKSTOP_SEC = 600, 86400
local LATE_MATCH_SEC, LOCK_AT_MAX_SEC = 120, 1800
local MAX_RECORDS, MAX_DEBTS, DEBT_PRUNE_SEC = 200, 100, 30 * 86400
local WIRE_V, WIRE_MAX = 2, 1e12
local CHANNEL_NAME = "WoMRing"
local NAME_MAX, LABEL_MAX, TITLE_MAX, NOTE_MAX = 48, 24, 32, 80

Ring.C = {
  BET_MIN_COPPER = GAMBLE_MIN_COPPER, BET_CEILING_COPPER = GAMBLE_MAX_COPPER, DEFAULT_CAP_POINTS = DEFAULT_CAP_POINTS,
  MAX_MARKETS = MAX_MARKETS, MAX_OUTCOMES = MAX_OUTCOMES, MAX_BETTORS = MAX_BETTORS, PRICE_MIN = PRICE_MIN,
  PRICE_MAX = PRICE_MAX, APPEAL_SEC = APPEAL_SEC, DISPUTE_TIMEOUT_SEC = DISPUTE_TIMEOUT_SEC, OPEN_MAX_SEC = OPEN_MAX_SEC,
  STALE_SEC = STALE_SEC, OWES_BACKSTOP_SEC = OWES_BACKSTOP_SEC, OWES_GRACE_SEC = OWES_GRACE_SEC,
  LATE_MATCH_SEC = LATE_MATCH_SEC, WIRE_V = WIRE_V, CHANNEL = CHANNEL_NAME,
}
Ring.LIMITS = { minCopper = GAMBLE_MIN_COPPER, maxCopper = GAMBLE_MAX_COPPER }

local SESSION_STATUS = { open = true, closing = true, closed = true, stale = true }
local MARKET_STATUS = { draft = true, open = true, locked = true, resolving = true, disputed = true, settled = true, void = true }
local FINAL = { settled = true, void = true }
local V1_STATUS = { open = true, locked = true, settled = true, void = true, closed = true }
local KINDS = { winner = true, method = true, score = true, custom = true }
local LOCK_ON = { fight = true, manual = true, time = true }
local DISPUTE_CODES = { wrong = true, early = true, foul = true, other = true }
local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true, WHISPER = true }
local SCORE_LABELS = { [3] = { "2-0", "2-1", "1-2", "0-2" }, [5] = { "3-0", "3-1", "3-2", "2-3", "1-3", "0-3" } }

Ring.session = nil
Ring.last = nil
Ring.browser = {}   -- [host] = R2A entry (bettor ring browser)

local floor = math.floor
local function now() return U.ServerTime() end
local function fmt(n) return string.format("%.0f", tonumber(n) or 0) end

---------------------------------------------------------------------------
-- Helpers

-- Truncates to n bytes without splitting a UTF-8 sequence.
local function utf8trunc(s, n)
  if #s <= n then return s end
  local cut = n
  while cut > 0 do
    local c = s:byte(cut + 1)
    if not c or c < 0x80 or c >= 0xC0 then break end
    cut = cut - 1
  end
  return s:sub(1, cut)
end
Ring.Utf8Trunc = utf8trunc

local function clean(s, max)
  s = tostring(s == nil and "" or s):gsub("[%c|]", "")
  return utf8trunc(s, max or 40)
end

local function validId(s) return type(s) == "string" and s:match("^%x+$") and #s <= 16 end
local function validMid(s) return type(s) == "string" and s:match("^m[1-8]$") ~= nil end

local function full(name)
  name = clean(name, NAME_MAX)
  if name == "" or name:find("%s") then return nil end
  return MK.FullName(name)
end

local function same(a, b)
  if not a or not b then return false end
  a, b = full(a), full(b)
  return a and b and a:lower() == b:lower() or false
end

local function shortName(n) return (tostring(n or ""):match("^([^-]+)") or tostring(n or "")) end
local function shortLower(n) return shortName(n):lower() end

local function num(s, lo, hi)
  local n = tonumber(s)
  if not n or n ~= n then return lo end
  return U.Clamp(floor(n), lo, hi)
end

local function me() return MK.CommKey() end

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

local function isHost(s) return s and s.isHost end
local function ringDB() return ns.char and ns.char.ring end

local function marketList(s)
  local out = {}
  for _, m in pairs(s and s.markets or {}) do out[#out + 1] = m end
  table.sort(out, function(a, b) return a.mid < b.mid end)
  return out
end

local function counts(s, b) return s.currency == "points" or b.paid == true end

local function findBet(m, bettor)
  for _, b in ipairs(m and m.bets or {}) do
    if same(b.bettor, bettor) then return b end
  end
end

local function outcomeOfRef(m, name)
  if not m or not name then return nil end
  for i, o in ipairs(m.outcomes) do
    if o.ref and same(o.ref, name) then return i end
  end
  local sl = shortLower(name)
  for i, o in ipairs(m.outcomes) do
    if (o.ref and shortLower(o.ref) == sl) or (not o.ref and o.label and o.label:lower() == sl) then return i end
  end
end

local function betKey(s, m, b) return s.id .. "." .. m.mid .. "." .. b.bettor end

-- Live and last session, skipping nils: an ipairs over a literal { live, last } stops at a nil live session.
local function liveAndLast()
  local out = {}
  if Ring.session then out[#out + 1] = Ring.session end
  if Ring.last then out[#out + 1] = Ring.last end
  return out
end

---------------------------------------------------------------------------
-- Session view for v1 callers and the current UI (not persisted: SavedVariables drop metatables)

local SessionMT = {
  __index = function(t, k)
    local markets = rawget(t, "markets")
    local m1 = markets and markets.m1
    if k == "bets" then return m1 and m1.bets or {} end
    if k == "winner" then
      local r = m1 and m1.result or 0
      return r > 0 and m1.status ~= "void" and (m1.outcomes[r].ref or m1.outcomes[r].label) or nil
    end
    if k == "auto" then return m1 and m1.auto or nil end
    if k == "totals" and not rawget(t, "isHost") and m1 then
      local a, b = m1.outcomes[1] and m1.outcomes[1].pool or 0, m1.outcomes[2] and m1.outcomes[2].pool or 0
      return { a = a, b = b, count = #m1.bets }
    end
  end,
}
local function view(s) if type(s) == "table" and s.v2 then setmetatable(s, SessionMT) end return s end

---------------------------------------------------------------------------
-- Caps, bands, refusals

function Ring.Cap(s)
  s = s or Ring.session
  return s and s.cap or 0
end

local function hostCap(currency, hostName)
  if currency == "points" then return DEFAULT_CAP_POINTS end
  local g = MK.Wom("bloodsports", "referees", hostName, "cap")
  if type(g) ~= "number" then g = MK.Wom("bloodsports", "referees", (select(2, MK.PlayerKey())), "cap") end
  if type(g) == "number" and g > 0 then
    return U.Clamp(floor(g * COPPER_PER_GOLD), GAMBLE_MIN_COPPER, GAMBLE_MAX_COPPER)
  end
  return DEFAULT_CAP_GOLD
end

local function bookieLevel(hostName)
  local b = MK.Wom("bloodsports", "bookies", hostName)
  local lv = type(b) == "table" and tonumber(b.level) or nil
  if not lv or lv ~= lv then return 1 end
  return U.Clamp(floor(lv), 1, MAX_LEVEL)
end

-- Bookie level and the largest gold bet (copper) that level takes.
function Ring.Band(hostName)
  local level = bookieLevel(hostName)
  return level, level * BAND_GOLD_PER_LEVEL * COPPER_PER_GOLD
end

-- Largest fixed-odds bank (copper) a bookie level may declare: 10 x band.
function Ring.BankMax(hostName)
  local level, band = Ring.Band(hostName)
  return 10 * band, level
end

-- "amount" (below min / above cap) or "band" (gold above the bookie band); nil when allowed. Shared by slip and host.
local function refusal(currency, amount, cap, hostName)
  local min = currency == "gold" and GAMBLE_MIN_COPPER or 1
  if amount < min or amount > (cap or 0) then return "amount" end
  if currency == "gold" then
    local _, max = Ring.Band(hostName)
    if amount > max then return "band" end
  end
end

---------------------------------------------------------------------------
-- Odds math (§3, integers only)

-- Parimutuel over v2 bets ({ outcome, amount }); r = winning index or nil (void). Returns payouts keyed by bet,
-- counted pools P[k] and the dust kept by the referee.
local function pari(bets, r, countFn, nOutcomes)
  local P, T = {}, 0
  for k = 1, nOutcomes or 0 do P[k] = 0 end
  for _, b in ipairs(bets) do
    if countFn(b) then
      P[b.outcome] = (P[b.outcome] or 0) + b.amount
      T = T + b.amount
    end
  end
  local W = r and P[r] or 0
  local q, rem
  if r and W > 0 then
    q = floor((T - W) / W)
    rem = (T - W) - q * W
  end
  local out, sum = {}, 0
  for _, b in ipairs(bets) do
    local p = 0
    if countFn(b) then
      if not r or W == 0 then p = b.amount
      elseif b.outcome == r then p = b.amount + q * b.amount + floor(rem * b.amount / W) end
    end
    out[b] = p
    sum = sum + p
  end
  return out, P, T - sum
end

function Ring.FixedPayout(amount, price) return floor(amount * price / 100) end

-- v2: ComputePayouts(bets, r, counts[, nOutcomes]) -> payouts by bet, pools array, dust.
-- v1: ComputePayouts(bets, "a"|"b"|nil, counts) on { side, amount } bets -> payouts by bet, { a, b }.
function Ring.ComputePayouts(bets, r, countFn, nOutcomes)
  countFn = countFn or function() return true end
  local first = bets[1]
  if type(r) == "string" or (r == nil and first and first.outcome == nil and first.side ~= nil) then
    local shadow, back = {}, {}
    for i, b in ipairs(bets) do
      shadow[i] = { outcome = b.side == "b" and 2 or 1, amount = b.amount }
      back[shadow[i]] = b
    end
    local out, P = pari(shadow, r and (r == "b" and 2 or 1) or nil, function(sb) return countFn(back[sb]) end, 2)
    local mapped = {}
    for sb, p in pairs(out) do mapped[back[sb]] = p end
    return mapped, { a = P[1] or 0, b = P[2] or 0 }
  end
  return pari(bets, r, countFn, nOutcomes)
end

-- Fixed-odds liability if outcome k wins: sum over accepted bets on k of (payout - stake) minus paid stakes elsewhere.
local function liability(s, m, k)
  local L = 0
  for _, b in ipairs(m.bets) do
    if not b.void then
      if b.outcome == k then L = L + Ring.FixedPayout(b.amount, b.price) - b.amount
      elseif counts(s, b) then L = L - b.amount end
    end
  end
  return L
end

function Ring.Liability(mid, k, s)
  s = s or Ring.session
  local m = s and s.markets and s.markets[mid]
  return m and liability(s, m, k) or 0
end

-- Pools P[k] (counted) and bettors n[k]. Host computes from bets; mirrors read the R2O numbers.
local function poolsOf(s, m)
  local P, n = {}, {}
  for k = 1, #m.outcomes do P[k], n[k] = 0, 0 end
  if not isHost(s) then
    for k, o in ipairs(m.outcomes) do P[k], n[k] = o.pool or 0, o.n or 0 end
    return P, n
  end
  for _, b in ipairs(m.bets) do
    if b.outcome and P[b.outcome] then
      n[b.outcome] = n[b.outcome] + 1
      if counts(s, b) then P[b.outcome] = P[b.outcome] + b.amount end
    end
  end
  return P, n
end
Ring.MarketPools = poolsOf

-- poolA, poolB, count of market m1 (v1 view).
function Ring.Pools(s)
  s = s or Ring.session
  if not s then return 0, 0, 0 end
  if not s.v2 then
    if not isHost(s) and s.totals then return s.totals.a, s.totals.b, s.totals.count end
    return 0, 0, 0
  end
  local m = s.markets.m1
  if not m then return 0, 0, 0 end
  local P = poolsOf(s, m)
  return P[1] or 0, P[2] or 0, #m.bets
end

---------------------------------------------------------------------------
-- Outbox rows

local function push(ev, s, extra)
  local row = { ev = ev, event = ev, id = s.id, host = s.host, venue = s.venue, currency = s.currency, v = 2 }
  for k, v in pairs(extra or {}) do row[k] = v end
  A:Push("ring", row)
end

local function updated() A:Fire("RING_UPDATED") end

local function touch(s)
  s.rev = (s.rev or 0) + 1
  s.lastActivity = now()
end

---------------------------------------------------------------------------
-- Wire field builders (§4.2; every field a string). Exposed for the byte-budget test.

local W = {}
Ring.Wire = W

local function flags(s)
  return (s.public and "1" or "0") .. (s.raidOpen and "1" or "0") .. (s.autoInvite and "1" or "0")
end

local function bettorCount(s)
  local seen, n = {}, 0
  for _, m in pairs(s.markets) do
    for _, b in ipairs(m.bets) do
      local k = b.bettor:lower()
      if not seen[k] then seen[k] = true; n = n + 1 end
    end
  end
  return n, seen
end

local function marketCount(s)
  local n = 0
  for _ in pairs(s.markets) do n = n + 1 end
  return n
end

function W.R2A(s)
  return { tostring(WIRE_V), s.id, clean(s.venue, 24), s.currency, s.status, tostring(marketCount(s)),
    tostring((bettorCount(s))), fmt(s.cap), tostring(s.series and s.series.bo or 0), s.raidOpen and "1" or "0" }
end

function W.R2S(s)
  return { tostring(WIRE_V), s.id, s.status, clean(s.venue, 24), s.currency, fmt(s.cap),
    s.series and clean(s.series.id, 16) or "", tostring(s.series and s.series.bo or 0), tostring(marketCount(s)),
    fmt(s.rev), flags(s) }
end

function W.R2M(s, m)
  return { s.id, m.mid, m.kind, m.scope, m.mode, m.status, tostring(#m.outcomes), tostring(m.result or 0),
    fmt(m.fight or 0), fmt(m.lockAt or 0), fmt(m.appealUntil or 0), fmt(m.bank or 0), fmt(m.rev or s.rev),
    clean(m.title, TITLE_MAX) }
end

function W.R2O(s, m, idx)
  local P, n = poolsOf(s, m)
  local o = m.outcomes[idx]
  return { s.id, m.mid, tostring(idx), clean(o.label, LABEL_MAX), fmt(P[idx]), tostring(n[idx]),
    tostring(m.mode == "fixed" and (o.price or 0) or 0) }
end

local function lineState(b)
  return (b.paid and "1" or "0") .. (b.void and "1" or "0") .. (b.paidOut and "1" or "0")
end

function W.R2L(s, m, b)
  return { s.id, m.mid, clean(b.bettor, NAME_MAX), tostring(b.outcome), fmt(b.amount), tostring(b.price or 0),
    lineState(b), fmt(b.payout or 0), fmt(b.paidOutAmount or 0), fmt(b.rev or s.rev) }
end

function W.R2X(sid, mid, nonce, code, max) return { sid, mid or "", nonce or "", code, fmt(max or 0) } end
function W.R2B(sid, mid, idx, amount, price, nonce) return { sid, mid, tostring(idx), fmt(amount), tostring(price or 0), nonce } end
function W.R2D(sid, mid, code, note) return { sid, mid, code, clean(note, NOTE_MAX) } end
function W.R2Q(sid, since, what) return { sid, fmt(since or 0), what or "" } end
function W.R2J(sid) return { sid } end

---------------------------------------------------------------------------
-- Transport (§4.1)

local function chanNum()
  local n = tonumber((MK.Call(GetChannelName, CHANNEL_NAME)))
  if n and n > 0 then return n end
end

function Ring.ChannelJoined() return chanNum() ~= nil end

local function channelOn() return A.db.config.ring.channel ~= false and chanNum() or nil end

local function whisper(typ, fields, target)
  return ns.comm and target and ns.comm:Send(typ, fields, "WHISPER", target) or false
end

-- Host state message to the group, plus the channel (outside watchers present) or a whisper fan-out (status only).
local function publish(s, typ, fields, statusChange)
  local comm = ns.comm
  if not comm then return end
  if IsInGroup() then comm:Broadcast(typ, fields) end
  if #(s.watchers or {}) == 0 then return end
  local n = s.public and channelOn()
  if n then
    comm:Send(typ, fields, "CHANNEL", n)
  elseif statusChange then
    for _, w in ipairs(s.watchers) do
      if not inGroup(w) then comm:Send(typ, fields, "WHISPER", w) end
    end
  end
end

local function addWatcher(s, name)
  s.watchers = s.watchers or {}
  for _, w in ipairs(s.watchers) do if same(w, name) then return end end
  if #s.watchers >= MAX_BETTORS then return end
  s.watchers[#s.watchers + 1] = name
end

local lastR2A = 0
local function sendAnnounce(s, force)
  if not ns.comm or not s.public or s.status ~= "open" then return end
  local n = channelOn()
  if not n then return end
  local t = GetTime()
  if not force and t - lastR2A < 60 then return end
  if t - lastR2A < 10 then return end
  lastR2A = t
  ns.comm:Send("R2A", W.R2A(s), "CHANNEL", n)
end

-- v1 compatibility for market m1 (winner + pari) or a session with no market yet.
local function v1compat(s)
  local m = s.markets.m1
  return not m or (m.kind == "winner" and m.mode == "pari")
end

local V1_MAP = { draft = "open", open = "open", locked = "locked", resolving = "locked", disputed = "locked",
  settled = "settled", void = "void" }

local function sendStateV1(s)
  if not ns.comm or not v1compat(s) or not IsInGroup() then return end
  local m = s.markets.m1
  local status = s.status == "closed" and "closed" or (m and V1_MAP[m.status]) or (s.status == "open" and "open" or "locked")
  local pa, pb, count = Ring.Pools(s)
  local winner = (m and m.status == "settled" and m.result > 0) and m.outcomes[m.result].ref or ""
  ns.comm:Broadcast("RS", { s.id, status, s.venue or "", s.currency, s.fighters and s.fighters.a or "",
    s.fighters and s.fighters.b or "", fmt(pa), fmt(pb), count, winner, s.cap })
end

local function sendLineV1(s, b, whisperTo)
  if not ns.comm or not v1compat(s) or not b.on then return end
  local f = { s.id, b.bettor, b.on, fmt(b.amount), b.paid and 1 or 0, fmt(b.payout or 0), b.paidOut and 1 or 0 }
  if whisperTo then ns.comm:Send("RL", f, "WHISPER", whisperTo) elseif IsInGroup() then ns.comm:Broadcast("RL", f) end
end

-- Bet line to the group (accept/paid/payout); bettors outside the group also get it whispered.
local function sendLine(s, m, b, whisperOnly)
  if not ns.comm then return end
  local f = W.R2L(s, m, b)
  if not whisperOnly and IsInGroup() then ns.comm:Broadcast("R2L", f) end
  if whisperOnly or not inGroup(b.bettor) then whisper("R2L", f, b.bettor) end
  if m.mid == "m1" and not whisperOnly then sendLineV1(s, b) end
end

-- Dirty tracking: state messages after bet changes are batched (debounced 2 s); status changes flush at once.
local dirty = {}
local function markDirty(s, m, idx, sessionToo)
  local d = dirty[s.id] or { markets = {} }
  dirty[s.id] = d
  if sessionToo then d.session = true end
  if m then
    local dm = d.markets[m.mid] or { o = {} }
    d.markets[m.mid] = dm
    if idx == "all" then dm.header, dm.all = true, true
    elseif idx == "header" then dm.header = true
    elseif idx then dm.o[idx] = true end
  end
end

local function flush(s, statusChange)
  if not s or not isHost(s) then return end
  local d = dirty[s.id]
  dirty[s.id] = nil
  if not d then return end
  if d.session or statusChange then publish(s, "R2S", W.R2S(s), statusChange) end
  local mids = {}
  for mid in pairs(d.markets) do mids[#mids + 1] = mid end
  table.sort(mids)
  for _, mid in ipairs(mids) do
    local m, dm = s.markets[mid], d.markets[mid]
    if m then
      if dm.header then publish(s, "R2M", W.R2M(s, m), statusChange) end
      for idx = 1, #m.outcomes do
        if dm.all or dm.o[idx] then publish(s, "R2O", W.R2O(s, m, idx), statusChange) end
      end
    end
  end
  if d.session or d.markets.m1 then sendStateV1(s) end
end

local function flushSoon(s)
  A:Debounce("ringOut", 2, function() flush(Ring.session) end)
end

local function flushNow(s)
  markDirty(s, nil, nil, true)
  flush(s, true)
end

---------------------------------------------------------------------------
-- Records (char.bets), outbox bet rows, debts

local function betResult(s, m, b)
  if m.status == "void" or not counts(s, b) or (m.result or 0) == 0 then return "void" end
  if m.mode == "pari" then
    local P = isHost(s) and poolsOf(s, m) or poolsOf(s, m)
    if (P[m.result] or 0) <= 0 then return "void" end
  end
  return b.outcome == m.result and "win" or "loss"
end

local function pushBetRow(s, m, b, payout)
  local row = { schema = 2, id = m.mid == "m1" and s.id or s.id .. "." .. m.mid, bettor = b.bettor, bookie = s.host, amount = floor(b.amount),
    result = betResult(s, m, b), venue = s.venue ~= "" and s.venue or nil, t = now(), currency = s.currency,
    market = m.mid, kind = m.kind, mode = m.mode, outcome = b.outcome, outcomeCount = #m.outcomes,
    marketResult = m.status == "void" and 0 or (m.result or 0), price = m.mode == "fixed" and (b.price or 0) or 0,
    paid = counts(s, b), payout = floor(payout or b.payout or 0) }
  if #m.outcomes == 2 then row.side = b.outcome == 1 and "a" or "b" end
  if s.series then row.series, row.bo = s.series.id, s.series.bo end
  if (m.fight or 0) > 0 then row.fight = m.fight end
  A:Push("bet", row)
end

local function findDebt(id, bettor, role)
  for _, d in ipairs(ringDB().debts) do
    if d.id == id and same(d.bettor, bettor) and (d.role or "host") == (role or "host") then return d end
  end
end

local function addDebt(d)
  local list = ringDB().debts
  if findDebt(d.id, d.bettor, d.role) then return end
  list[#list + 1] = d
  while #list > MAX_DEBTS do
    local drop = 1
    for i, x in ipairs(list) do if x.status == "cleared" then drop = i break end end
    table.remove(list, drop)
  end
end

local function debtsFor(s, m)
  if s.currency ~= "gold" then return end
  local t = now()
  for _, b in ipairs(m.bets) do
    if (b.payout or 0) > 0 and not b.paidOut then
      addDebt({ id = s.id .. "." .. m.mid, bettor = b.bettor, bookie = s.host, amount = b.payout,
        paid = b.paidOutAmount or 0, settledAt = t, fight = m.fight or 0, status = "due", role = "host" })
    end
  end
end

local function findRecord(s, role)
  local list = ns.char.bets
  for i = #list, 1, -1 do
    local r = list[i]
    if r.v == 2 and r.id == s.id and r.role == role then return r end
  end
end

local function recordMarket(s, m, mine, payout)
  local role = isHost(s) and "host" or "bettor"
  if role == "bettor" and not mine then return end
  local rec = findRecord(s, role)
  if not rec then
    rec = { v = 2, id = s.id, t = now(), role = role, host = s.host, venue = s.venue, currency = s.currency,
      series = s.series and s.series.id or nil, markets = {} }
    table.insert(ns.char.bets, rec)
    while #ns.char.bets > MAX_RECORDS do table.remove(ns.char.bets, 1) end
  end
  local P = poolsOf(s, m)
  local entry = { kind = m.kind, mode = m.mode, result = m.result or 0, status = m.status, pools = P }
  if role == "host" then
    entry.bets = U.Copy(m.bets)
  else
    entry.bet = U.Copy(mine)
    entry.bet.payout = payout
  end
  rec.markets[m.mid] = entry
end

-- Net points over my bettor records, v1 and v2 shapes (no authority enforces it; the site owns the balance).
function Ring.PointsBalance()
  local sum = 0
  for _, r in ipairs(ns.char.bets) do
    if r.role == "bettor" and r.currency == "points" then
      if r.v == 2 then
        for _, e in pairs(r.markets or {}) do
          if e.bet and FINAL[e.status] then sum = sum + (e.bet.payout or 0) - (e.bet.amount or 0) end
        end
      elseif r.bet and r.status ~= "closed" then
        sum = sum + (r.bet.payout or 0) - (r.bet.amount or 0)
      end
    end
  end
  return sum
end

---------------------------------------------------------------------------
-- Host: session lifecycle

function Ring.IsHost() return isHost(Ring.session) or false end

local function persist(s)
  local ring = ringDB()
  if ring and s.v2 then ring.session = s end
end

function Ring.Open(venueId)
  local s = Ring.session
  if s and s.status ~= "closed" and not (s.v2 == nil and (s.status == "settled" or s.status == "void")) then
    if not isHost(s) then return false, "joined" end
    return false, "active"
  end
  if s and not isHost(s) then return false, "joined" end
  local cfg = A.db.config.ring
  if not cfg.enabled then return false, "disabled" end
  if not A.db.config.referee.available then return false, "referee" end
  if IsInGroup() and type(UnitIsGroupLeader) == "function" and not MK.Call(UnitIsGroupLeader, "player") then
    return false, "leader"
  end
  if venueId == nil and ns.venues then
    local v = ns.venues:Current()
    venueId = v and v.id
  end
  local venue = utf8trunc(tostring(venueId or ""):match("^[%w_]+$") or "", 24)
  local currency = cfg.currency == "points" and "points" or "gold"
  local t = now()
  s = view({ v2 = true, id = U.RandomHex(8), host = me(), isHost = true, venue = venue, currency = currency,
    public = cfg.public ~= false, autoInvite = cfg.autoInvite and true or false, raidOpen = false, status = "open",
    markets = {}, nextMid = 0, rev = 1, watchers = {}, fighters = {}, createdAt = t, lastActivity = t })
  s.cap = hostCap(currency, me())
  Ring.session = s
  persist(s)
  push("open", s, { cap = s.cap, public = s.public, series = s.series and s.series.id or nil })
  flushNow(s)
  sendAnnounce(s, true)
  updated()
  return s
end

local function fightersOf(s, m)
  if m and m.a then return m.a, m.b end
  if s.series and s.series.a then return s.series.a, s.series.b end
  return s.fighters and s.fighters.a, s.fighters and s.fighters.b
end

local function isFighter(s, m, name)
  local a, b = fightersOf(s, m)
  if not isHost(s) and m then
    -- mirrors only know outcome labels (short names)
    local sl = shortLower(name)
    if m.kind == "winner" or m.kind == "method" then
      for _, o in ipairs(m.outcomes) do
        if o.label and shortLower(o.label:gsub(" %a+$", "")) == sl then return true end
      end
    end
  end
  return same(name, a) or same(name, b)
end

-- Extension market kinds (MK.Ext, kind "market"): the registry entry for a kind that is not built in, or nil.
-- MK.Ext can be missing (older MetaKit copy) or misbehave; neither ever reaches the caller.
local function extMarket(kind)
  local E = MK.Ext
  if type(kind) ~= "string" or KINDS[kind] or type(E) ~= "table" or type(E.Get) ~= "function" then return nil end
  local ok, info = pcall(E.Get, "market", kind)
  if ok and type(info) == "table" and type(info.def) == "table" then return info end
end

local function defaultTitle(kind, bo)
  if kind == "winner" then return "Winner" end
  if kind == "method" then return "Method" end
  if kind == "score" then return "Score bo" .. tostring(bo) end
  return "Custom"
end

-- spec = { kind, scope, title, labels (custom), a, b (fighters), mode, prices = { ... }, bank, lockOn, lockAt, open }
function Ring.AddMarket(spec)
  local s = Ring.session
  if not isHost(s) or s.status ~= "open" then return false, "session" end
  spec = spec or {}
  if (s.nextMid or 0) >= MAX_MARKETS then return false, "markets" end
  local ext = extMarket(spec.kind)
  local kind = (KINDS[spec.kind] or ext) and spec.kind or "winner"
  local scope = spec.scope == "series" and "series" or "fight"
  if ext then scope = (ext.def.scope or scope) == "series" and "series" or "fight" end
  if kind == "score" then scope = "series" end
  if scope == "series" and not s.series then return false, "series" end
  local mode = spec.mode == "fixed" and "fixed" or "pari"
  local fa, fb = full(spec.a or (s.series and s.series.a) or s.fighters.a), full(spec.b or (s.series and s.series.b) or s.fighters.b)
  local outcomes, bo = {}, s.series and s.series.bo or nil
  if kind == "winner" or kind == "method" then
    if not fa or not fb or fa:lower() == fb:lower() then return false, "fighters" end
    if kind == "winner" then
      outcomes = { { label = clean(shortName(fa), LABEL_MAX), ref = fa }, { label = clean(shortName(fb), LABEL_MAX), ref = fb } }
    else
      outcomes = {
        { label = clean(shortName(fa), LABEL_MAX - 5) .. " KO", ref = fa },
        { label = clean(shortName(fa), LABEL_MAX - 5) .. " flee", ref = fa },
        { label = clean(shortName(fb), LABEL_MAX - 5) .. " KO", ref = fb },
        { label = clean(shortName(fb), LABEL_MAX - 5) .. " flee", ref = fb },
      }
    end
  elseif kind == "score" then
    for _, l in ipairs(SCORE_LABELS[bo] or {}) do outcomes[#outcomes + 1] = { label = l } end
  elseif ext then
    local okB, list = pcall(MK.Ext.BuildOutcomes, kind, { a = fa, b = fb, bo = bo, series = s.series and s.series.id or nil, session = s.id })
    if not okB or type(list) ~= "table" then return false, "outcomes" end
    for _, o in ipairs(list) do
      local l = clean(o.label, LABEL_MAX)
      if l ~= "" then outcomes[#outcomes + 1] = { label = l, ref = type(o.ref) == "string" and clean(o.ref, NAME_MAX) or nil } end
    end
  else
    for _, l in ipairs(spec.labels or {}) do
      l = clean(l, LABEL_MAX)
      if l ~= "" then outcomes[#outcomes + 1] = { label = l } end
    end
  end
  if #outcomes < 2 or #outcomes > MAX_OUTCOMES then return false, "outcomes" end
  if mode == "fixed" then
    for i, o in ipairs(outcomes) do o.price = spec.prices and tonumber(spec.prices[i]) and floor(spec.prices[i]) or 0 end
  end
  local lockOn = LOCK_ON[spec.lockOn] and spec.lockOn or (ext and (ext.def.lockOn or "manual") or (kind == "custom" and "manual" or "fight"))
  local lockAt = 0
  if lockOn == "time" then
    lockAt = floor(tonumber(spec.lockAt) or 0)
    if lockAt <= now() or lockAt > now() + LOCK_AT_MAX_SEC then return false, "lockAt" end
  end
  s.nextMid = (s.nextMid or 0) + 1
  touch(s)
  local m = { mid = "m" .. s.nextMid, kind = kind, scope = scope, title = clean(spec.title or (ext and ext.def.label) or defaultTitle(kind, bo), TITLE_MAX),
    outcomes = outcomes, mode = mode, bank = mode == "fixed" and floor(tonumber(spec.bank) or 0) or 0, status = "draft",
    lockOn = lockOn, lockAt = lockAt, result = 0, fight = 0, auto = false, dust = 0, bets = {}, a = fa, b = fb, rev = s.rev }
  s.markets[m.mid] = m
  markDirty(s, m, "all", true)
  if spec.open then
    local ok, why = Ring.OpenMarket(m.mid)
    if not ok then
      s.markets[m.mid] = nil
      return false, why
    end
  else
    flushSoon(s)
    updated()
  end
  return m
end

function Ring.OpenMarket(mid)
  local s = Ring.session
  local m = isHost(s) and s.markets[mid]
  if not m or m.status ~= "draft" or s.status ~= "open" then return false, "closed" end
  if #m.outcomes < 2 then return false, "outcomes" end
  if m.mode == "fixed" then
    for _, o in ipairs(m.outcomes) do
      if not o.price or o.price < PRICE_MIN or o.price > PRICE_MAX then return false, "price" end
    end
    if m.bank <= 0 or m.bank > Ring.BankMax(s.host) then return false, "bank" end
    local have = MK.Call(GetMoney)
    if s.currency == "gold" and type(have) == "number" and have < m.bank then return false, "money" end
  end
  touch(s)
  m.status, m.openedAt, m.rev = "open", now(), s.rev
  local labels, prices = {}, {}
  for i, o in ipairs(m.outcomes) do labels[i], prices[i] = o.label, o.price or 0 end
  push("market", s, { mid = mid, kind = m.kind, mode = m.mode, labels = labels, prices = prices, bank = m.bank,
    fight = m.fight, scope = m.scope })
  markDirty(s, m, "all", true)
  flushNow(s)
  updated()
  return true
end

function Ring.SetPrice(mid, idx, price)
  local s = Ring.session
  local m = isHost(s) and s.markets[mid]
  price = tonumber(price) and floor(price)
  if not m or m.mode ~= "fixed" or (m.status ~= "open" and m.status ~= "draft") then return false end
  if not m.outcomes[idx] or not price or price < PRICE_MIN or price > PRICE_MAX then return false end
  touch(s)
  m.outcomes[idx].price, m.rev = price, s.rev
  markDirty(s, m, idx)
  flush(s)
  updated()
  return true
end

function Ring.SetFighters(a, b)
  local s = Ring.session
  if not isHost(s) or s.status ~= "open" then return false end
  a, b = full(a), full(b)
  if not a or not b or a:lower() == b:lower() then return false end
  local m1 = s.markets.m1
  if m1 and (#m1.bets > 0 or (m1.status ~= "open" and m1.status ~= "draft")) then return false end
  s.fighters = { a = a, b = b }
  if m1 and m1.kind == "winner" then
    touch(s)
    m1.a, m1.b, m1.rev = a, b, s.rev
    m1.outcomes[1].label, m1.outcomes[1].ref = clean(shortName(a), LABEL_MAX), a
    m1.outcomes[2].label, m1.outcomes[2].ref = clean(shortName(b), LABEL_MAX), b
    markDirty(s, m1, "all", true)
    flushNow(s)
    updated()
  elseif not m1 then
    if not Ring.AddMarket({ kind = "winner", mode = "pari", open = true }) then return false end
  end
  return true
end

local function newFight(s)
  local ring = ringDB()
  ring.fightSeq = (ring.fightSeq or 0) + 1
  s.curFight, s.fightLive = ring.fightSeq, true
  return ring.fightSeq
end

local function lockMarket(s, m, fight)
  touch(s)
  m.status, m.lockedAt, m.rev = "locked", now(), s.rev
  m.fight = fight or (s.fightLive and s.curFight) or newFight(s)
  push("lock", s, { mid = m.mid, fight = m.fight, count = #m.bets })
  markDirty(s, m, "header")
end

-- Lock(mid) locks one market; Lock() (v1 "Lock bets") locks every open market as one fight.
function Ring.Lock(mid)
  local s = Ring.session
  if not isHost(s) then return false end
  if mid then
    local m = s.markets[mid]
    if not m or m.status ~= "open" then return false end
    lockMarket(s, m)
  else
    local any
    for _, m in ipairs(marketList(s)) do
      if m.status == "open" then
        if not any then any = s.fightLive and s.curFight or newFight(s) end
        lockMarket(s, m, any)
      end
    end
    if not any then return false end
  end
  flushNow(s)
  updated()
  return true
end

-- Payouts at a verdict (r) or a void (r = nil); unpaid gold bets become void.
local function computeMarket(s, m, r)
  for _, b in ipairs(m.bets) do b.void, b.voidReason = nil, nil end
  local countFn = function(b) return counts(s, b) end
  if m.mode == "fixed" then
    for _, b in ipairs(m.bets) do
      if not countFn(b) then b.payout = 0
      elseif r == nil then b.payout = b.amount
      else b.payout = b.outcome == r and Ring.FixedPayout(b.amount, b.price) or 0 end
    end
    m.dust = 0
  else
    local out, _, dust = pari(m.bets, r, countFn, #m.outcomes)
    for _, b in ipairs(m.bets) do b.payout = out[b] end
    m.dust = dust
  end
  for _, b in ipairs(m.bets) do
    if not countFn(b) then b.void, b.voidReason = true, "unpaid"
    elseif r == nil then b.void, b.voidReason = true, "market" end
  end
end

local function fightWinner(m, idx)
  if (m.kind == "winner" or m.kind == "method") and idx and m.outcomes[idx] then
    local w = m.outcomes[idx].ref
    return w, same(w, m.a) and m.b or m.a
  end
end

local function whisperPayouts(s, m)
  for _, b in ipairs(m.bets) do
    if (b.payout or 0) > 0 then sendLine(s, m, b, true) end
  end
end

local function verdict(s, m, idx, auto)
  if not m or (m.status ~= "open" and m.status ~= "locked") then return false end
  idx = tonumber(idx)
  if not idx or not m.outcomes[idx] then return false end
  if m.status == "open" then lockMarket(s, m) end
  computeMarket(s, m, idx)
  touch(s)
  local t = now()
  m.result, m.status, m.verdictAt, m.appealUntil, m.auto, m.rev = idx, "resolving", t, t + APPEAL_SEC, auto and true or false, s.rev
  s.fightLive = false
  local w, l = fightWinner(m, idx)
  if w and m.scope == "fight" then
    -- referee verdict row: the site verifies the fighters' duel reports against it (120 s window)
    push("verdict", s, { mid = m.mid, winner = w, loser = l, auto = auto and true or false })
  end
  push("resolve", s, { mid = m.mid, result = idx, appealUntil = m.appealUntil })
  markDirty(s, m, "all")
  flushNow(s)
  whisperPayouts(s, m)
  updated()
  return true
end

-- Verdict(mid, idx[, auto]) or v1 Verdict(winnerName[, auto]) on m1.
function Ring.Verdict(a1, a2, a3)
  local s = Ring.session
  if not isHost(s) then return false end
  if validMid(a1) and s.markets[a1] then return verdict(s, s.markets[a1], a2, a3) end
  local m = s.markets.m1
  if not m or m.kind ~= "winner" then return false end
  return verdict(s, m, outcomeOfRef(m, a1), a2)
end

local function advanceOwes()
  local ring = ringDB()
  if not ring then return end
  local t = now()
  for i = #ring.debts, 1, -1 do
    local d = ring.debts[i]
    if d.status == "due" then
      local later = (ring.settledFight or 0) > (d.fight or 0) and t >= d.settledAt + OWES_GRACE_SEC
      if later or t >= d.settledAt + OWES_BACKSTOP_SEC then
        d.status, d.owesAt = "owes", t
        if d.role == "bettor" and not d.unpaidSent then
          d.unpaidSent = true
          A:Push("ring", { ev = "unpaid", event = "unpaid", id = d.sid or d.id, mid = d.mid, v = 2, bookie = d.bookie,
            amount = d.amount - (d.paid or 0) })
        end
      end
    elseif d.status == "cleared" and d.clearedAt and t - d.clearedAt > DEBT_PRUNE_SEC then
      table.remove(ring.debts, i)
    end
  end
end

local closeSession

local function maybeFinishClosing(s)
  if s.status ~= "closing" then return end
  for _, m in pairs(s.markets) do
    if not FINAL[m.status] then return end
  end
  closeSession(s)
end

local function settleMarket(s, m)
  touch(s)
  local t = now()
  m.status, m.settledAt, m.rev = "settled", t, s.rev
  for _, b in ipairs(m.bets) do
    if s.currency == "points" and (b.payout or 0) > 0 then b.paidOut, b.paidOutAmount = true, b.payout end
  end
  local ring = ringDB()
  if (m.fight or 0) > (ring.settledFight or 0) then ring.settledFight = m.fight end
  if not m.rowsDone then
    m.rowsDone = true
    for _, b in ipairs(m.bets) do pushBetRow(s, m, b) end
  end
  debtsFor(s, m)
  recordMarket(s, m)
  local P = poolsOf(s, m)
  local prices = {}
  for i, o in ipairs(m.outcomes) do prices[i] = o.price or 0 end
  local w = fightWinner(m, m.result)
  push("settle", s, { mid = m.mid, result = m.result, mode = m.mode, pools = P, prices = prices, fight = m.fight,
    dust = m.dust, count = #m.bets, winner = w, poolA = #P == 2 and P[1] or nil, poolB = #P == 2 and P[2] or nil })
  markDirty(s, m, "all")
  flushNow(s)
  whisperPayouts(s, m)
  if m.mid == "m1" then
    for _, b in ipairs(m.bets) do sendLineV1(s, b, b.bettor) end
    sendStateV1(s)
  end
  advanceOwes()
  updated()
  maybeFinishClosing(s)
end

local function voidMarket(s, m, reason)
  if FINAL[m.status] then return false end
  local afterVerdict = m.status == "resolving" or m.status == "disputed"
  computeMarket(s, m, nil)
  touch(s)
  local t = now()
  m.status, m.result, m.voidReason, m.settledAt, m.rev = "void", 0, reason, t, s.rev
  m.afterVerdict = afterVerdict or nil
  if m.dispute and not m.dispute.resolvedAt then
    m.dispute.resolvedAt = t
    m.dispute.action = m.dispute.action or "void"
  end
  for _, b in ipairs(m.bets) do
    if s.currency == "points" and (b.payout or 0) > 0 then b.paidOut, b.paidOutAmount = true, b.payout end
  end
  if not m.rowsDone then
    m.rowsDone = true
    for _, b in ipairs(m.bets) do pushBetRow(s, m, b) end
  end
  debtsFor(s, m)
  recordMarket(s, m)
  push("void", s, { mid = m.mid, reason = reason, afterVerdict = afterVerdict, count = #m.bets })
  markDirty(s, m, "all")
  if m.mid == "m1" then
    for _, b in ipairs(m.bets) do sendLineV1(s, b, b.bettor) end
  end
  return true
end

-- Void(mid) voids one market (referee final say); Void() voids every non-final market.
function Ring.Void(mid)
  local s = Ring.session
  if not isHost(s) then return false end
  local any = false
  for _, m in ipairs(marketList(s)) do
    if (not mid or m.mid == mid) and voidMarket(s, m, "referee") then any = true end
  end
  if not any then return false end
  flushNow(s)
  updated()
  maybeFinishClosing(s)
  return true
end

-- Host resolves an open dispute: "uphold" | "amend" (idx) | "void". Final, no second appeal.
function Ring.ResolveDispute(mid, action, idx)
  local s = Ring.session
  local m = isHost(s) and s.markets[mid]
  if not m or m.status ~= "disputed" then return false end
  local t = now()
  if action == "uphold" then
    m.dispute.action, m.dispute.resolvedAt = "uphold", t
    push("dispute_resolved", s, { mid = mid, action = "uphold", result = m.result })
    settleMarket(s, m)
  elseif action == "amend" then
    idx = tonumber(idx)
    if not idx or not m.outcomes[idx] then return false end
    local oldW = fightWinner(m, m.result)
    computeMarket(s, m, idx)
    m.result = idx
    m.dispute.action, m.dispute.resolvedAt, m.dispute.result = "amend", t, idx
    push("dispute_resolved", s, { mid = mid, action = "amend", result = idx })
    local w, l = fightWinner(m, idx)
    if w and not same(w, oldW) then push("verdict_amend", s, { mid = mid, winner = w, loser = l }) end
    settleMarket(s, m)
  elseif action == "void" then
    m.dispute.action = "void"
    push("dispute_resolved", s, { mid = mid, action = "void", result = 0 })
    voidMarket(s, m, "dispute")
    flushNow(s)
    updated()
    maybeFinishClosing(s)
  else
    return false
  end
  return true
end

closeSession = function(s)
  local owed = 0
  for _, m in pairs(s.markets) do
    for _, b in ipairs(m.bets) do
      if (b.payout or 0) > 0 and not b.paidOut then owed = owed + 1 end
    end
  end
  touch(s)
  s.unpaidOut, s.status, s.closedAt = owed, "closed", now()
  push("close", s, { unpaidOut = owed })
  flushNow(s)
  local ring = ringDB()
  if ring then ring.last, ring.session = s, nil end
  Ring.last, Ring.session = s, nil
  updated()
end

-- Close(): voids draft/open/locked markets; markets in their appeal window keep the session "closing" until final.
-- Close(true), or Close() while already closing, voids everything (open disputes included) and closes.
function Ring.Close(force)
  local s = Ring.session
  if not isHost(s) or s.status == "closed" then return false end
  local pending = false
  for _, m in pairs(s.markets) do
    if m.status == "resolving" or m.status == "disputed" then pending = true end
  end
  if pending and not force and s.status ~= "closing" then
    for _, m in ipairs(marketList(s)) do
      if m.status ~= "resolving" and m.status ~= "disputed" then voidMarket(s, m, "close") end
    end
    touch(s)
    s.status = "closing"
    flushNow(s)
    updated()
    return true, "closing"
  end
  for _, m in ipairs(marketList(s)) do voidMarket(s, m, "close") end
  closeSession(s)
  return true
end

-- Payouts still to hand out (host, gold), live and last session: { bettor, amount (outstanding), mid, sid }.
function Ring.Owed()
  local out = {}
  for _, s in ipairs(liveAndLast()) do
    if isHost(s) and s.v2 then
      for _, m in ipairs(marketList(s)) do
        if FINAL[m.status] then
          for _, b in ipairs(m.bets) do
            local left = (b.payout or 0) - (b.paidOutAmount or 0)
            if left > 0 and not b.paidOut then out[#out + 1] = { bettor = b.bettor, amount = left, mid = m.mid, sid = s.id } end
          end
        end
      end
    end
  end
  return out
end

function Ring.Debts() return ringDB() and ringDB().debts or {} end
function Ring.Markets(s) return marketList(s or Ring.session) end
function Ring.Market(mid, s)
  s = s or Ring.session
  return s and s.markets and s.markets[mid]
end

function Ring.SetPublic(on)
  local s = Ring.session
  if not isHost(s) then return false end
  s.public = on and true or false
  touch(s)
  flushNow(s)
  return true
end

function Ring.SetAutoInvite(on)
  local s = Ring.session
  if not isHost(s) then return false end
  s.autoInvite = on and true or false
  touch(s)
  flushNow(s)
  return true
end

-- Button click only: converts the group to a raid (hardware event).
function Ring.FormRaid()
  local s = Ring.session
  if not isHost(s) then return false end
  local fn = (C_PartyInfo and C_PartyInfo.ConvertToRaid) or ConvertToRaid
  if fn then pcall(fn) end
  s.raidOpen = true
  touch(s)
  flushNow(s)
  return true
end

-- Button click only: invites the queued R2J senders. Returns how many invites went out.
function Ring.InviteQueued()
  local s = Ring.session
  if not isHost(s) then return 0 end
  local fn = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
  local n = 0
  for _, name in ipairs(s.inviteQueue or {}) do
    if fn and pcall(fn, name) then n = n + 1 end
  end
  s.inviteQueue = {}
  updated()
  return n
end

---------------------------------------------------------------------------
-- Host: inbound bets (R2B, v1 RB)

local function sendX(target, sid, mid, nonce, code, max)
  whisper("R2X", W.R2X(sid, mid, nonce, code, max), target)
end

-- §3.4 order: closed, dup, fighter, full, amount, band, price, bank. Returns code, allowed max.
local function betRefusal(s, m, bettor, idx, amount, price)
  if s.status ~= "open" or m.status ~= "open" then return "closed", 0 end
  if not m.outcomes[idx] then return "market", 0 end
  if findBet(m, bettor) then return "dup", 0 end
  if same(bettor, s.host) or isFighter(s, m, bettor) then return "fighter", 0 end
  local n, seen = bettorCount(s)
  if not seen[bettor:lower()] and n >= MAX_BETTORS then return "full", 0 end
  local _, band = Ring.Band(s.host)
  local why = refusal(s.currency, amount, s.cap, s.host)
  if why == "amount" then return "amount", s.cap end
  if why == "band" then return "band", band end
  if m.mode == "fixed" then
    local cur = m.outcomes[idx].price
    if price ~= cur then return "price", 0 end
    local L = liability(s, m, idx)
    if L + Ring.FixedPayout(amount, cur) - amount > m.bank then
      local max = floor((m.bank - L) * 100 / (cur - 100))
      max = math.min(max, s.cap)
      if s.currency == "gold" then max = math.min(max, band, GAMBLE_MAX_COPPER) end
      return "bank", math.max(0, max)
    end
  end
end

local function acceptBet(s, m, bettor, idx, amount, price, nonce)
  touch(s)
  local b = { bettor = bettor, outcome = idx, amount = amount, price = m.mode == "fixed" and m.outcomes[idx].price or 0,
    t = now(), paid = s.currency == "points", payout = 0, paidOutAmount = 0, paidOut = false, nonce = nonce, rev = s.rev }
  if m.kind == "winner" then b.side, b.on = idx == 1 and "a" or "b", m.outcomes[idx].ref end
  table.insert(m.bets, b)
  if not inGroup(bettor) then addWatcher(s, bettor) end
  push("bet", s, { mid = m.mid, bettor = bettor, outcome = idx, amount = amount, price = b.price, on = b.on })
  sendLine(s, m, b)
  markDirty(s, m, idx)
  flushSoon(s)
  if ns.Ledger and ns.Ledger.Retry then ns.Ledger.Retry(bettor) end
  updated()
  return b
end

local inbound = {}   -- [sid][sender] = { lastB, refused, silenced, lastQ, lastJ }
local function inState(s, sender)
  inbound[s.id] = inbound[s.id] or {}
  local k = sender:lower()
  inbound[s.id][k] = inbound[s.id][k] or { refused = 0 }
  return inbound[s.id][k]
end

local function onR2B(sender, f, channel)
  local s = Ring.session
  if not isHost(s) or channel ~= "WHISPER" or f[1] ~= s.id then return end
  local st = inState(s, sender)
  local mid, nonce = f[2], clean(f[6], 8)
  if st.silenced then return end
  if st.refused >= 5 then
    st.silenced = true
    return sendX(sender, s.id, mid, nonce, "flood", 0)
  end
  if st.lastB and GetTime() - st.lastB < 2 then return end
  st.lastB = GetTime()
  local m = validMid(mid) and s.markets[mid]
  local code, max
  if not s.public and not inGroup(sender) then code = "closed"
  elseif not m then code = "market"
  else
    code, max = betRefusal(s, m, sender, num(f[3], 0, 99), num(f[4], 0, WIRE_MAX), num(f[5], 0, 99999))
  end
  if code then
    st.refused = st.refused + 1
    return sendX(sender, s.id, mid, nonce, code, max)
  end
  acceptBet(s, m, sender, num(f[3], 0, 99), num(f[4], 0, WIRE_MAX), num(f[5], 0, 99999), nonce)
end

-- v1 RB(id, on, amount): m1 winner + pari only, group members only, refused silently (v1 has no R2X).
local function onBetV1(sender, f)
  local s = Ring.session
  if not isHost(s) or f[1] ~= s.id or not v1compat(s) or not inGroup(sender) then return end
  local m = s.markets.m1
  if not m then return end
  local idx = outcomeOfRef(m, f[2] or "")
  local amount = num(f[3], 0, WIRE_MAX)
  if not idx or betRefusal(s, m, sender, idx, amount, 0) then return end
  acceptBet(s, m, sender, idx, amount, 0, "")
end

---------------------------------------------------------------------------
-- Host: disputes, resync, joins, fight start

local function onR2D(sender, f, channel)
  local s = Ring.session
  if not isHost(s) or channel ~= "WHISPER" or f[1] ~= s.id then return end
  if not s.public and not inGroup(sender) then return end
  local m = validMid(f[2]) and s.markets[f[2]]
  if not m then return end
  local code = DISPUTE_CODES[f[3]] and f[3] or "other"
  local t = now()
  if (m.status ~= "resolving" and m.status ~= "disputed") or t < (m.verdictAt or 0) or t >= (m.appealUntil or 0) then
    return sendX(sender, s.id, m.mid, "", "late", 0)
  end
  local b = findBet(m, sender)
  if not ((b and counts(s, b)) or isFighter(s, m, sender)) then return end
  m.disputers = m.disputers or {}
  local k = sender:lower()
  if m.disputers[k] then return end
  m.disputers[k] = true
  local note = clean(f[4], NOTE_MAX)
  if m.status == "resolving" then
    touch(s)
    m.status, m.rev = "disputed", s.rev
    m.dispute = { by = sender, code = code, note = note, at = t, extra = {} }
    push("dispute", s, { mid = m.mid, by = sender, code = code })
    markDirty(s, m, "header")
    flushNow(s)
    updated()
  elseif #m.dispute.extra < 5 then
    table.insert(m.dispute.extra, { by = sender, code = code, note = note, at = t })
  end
end

local function sendSnapshot(s, target, since, what)
  whisper("R2S", W.R2S(s), target)
  for _, m in ipairs(marketList(s)) do
    if (m.rev or 0) > since then
      whisper("R2M", W.R2M(s, m), target)
      for idx = 1, #m.outcomes do whisper("R2O", W.R2O(s, m, idx), target) end
    end
    for _, b in ipairs(m.bets) do
      if (what == "l" and (b.rev or 0) > since) or (what == "" and same(b.bettor, target)) then
        whisper("R2L", W.R2L(s, m, b), target)
      end
    end
  end
end

local function onR2Q(sender, f, channel)
  local s = Ring.session
  if not isHost(s) or channel ~= "WHISPER" or f[1] ~= s.id then return end
  if not s.public and not inGroup(sender) then return end
  local since = num(f[2], 0, WIRE_MAX)
  local what = (f[3] == "s" or f[3] == "l") and f[3] or ""
  local st = inState(s, sender)
  local gap = since == 0 and 15 or 2
  if st.lastQ and GetTime() - st.lastQ < gap then return end
  st.lastQ = GetTime()
  sendSnapshot(s, sender, since, what)
end

local function onR2J(sender, f, channel)
  local s = Ring.session
  if not isHost(s) or channel ~= "WHISPER" or f[1] ~= s.id then return end
  if not s.public and not inGroup(sender) then return end
  local st = inState(s, sender)
  if st.lastJ and GetTime() - st.lastJ < 30 then return end
  st.lastJ = GetTime()
  if not inGroup(sender) then addWatcher(s, sender) end
  if s.autoInvite and not inGroup(sender) then
    s.inviteQueue = s.inviteQueue or {}
    local dup = false
    for _, n in ipairs(s.inviteQueue) do if same(n, sender) then dup = true end end
    if not dup and #s.inviteQueue < MAX_BETTORS then table.insert(s.inviteQueue, sender) end
  end
  sendSnapshot(s, sender, 0, "s")
  updated()
end

-- A fighter's addon reports the duel countdown: lock every open market with lockOn = fight (one new fight).
local function onFightStart(sender, f)
  local s = Ring.session
  if not isHost(s) or f[1] ~= s.id then return end
  local fighter = same(sender, s.fighters.a) or same(sender, s.fighters.b)
    or (s.series and (same(sender, s.series.a) or same(sender, s.series.b)))
  if not fighter then
    for _, m in pairs(s.markets) do
      if m.status == "open" and (same(sender, m.a) or same(sender, m.b)) then fighter = true end
    end
  end
  if not fighter then return end
  local fight
  for _, m in ipairs(marketList(s)) do
    if m.status == "open" and m.lockOn == "fight" then
      fight = fight or newFight(s)
      lockMarket(s, m, fight)
    end
  end
  if fight then
    flushNow(s)
    updated()
  end
end

-- v1 resync: whisper the m1 lines in v1 RL format (group members, 10 s).
local resyncAt = {}
local function onResyncV1(sender, f)
  local s = Ring.session
  if not isHost(s) or f[1] ~= s.id or not inGroup(sender) or not s.markets.m1 then return end
  local key = sender:lower()
  if resyncAt[key] and GetTime() - resyncAt[key] < 10 then return end
  resyncAt[key] = GetTime()
  for _, b in ipairs(s.markets.m1.bets) do sendLineV1(s, b, sender) end
end

---------------------------------------------------------------------------
-- Auto verdicts: duel system messages (fight scope) and Series.lua events (series scope)

local FALLBACK = { "^(.+) has defeated (.+) in a duel$", "^(.+) has fled from (.+) in a duel$" }
local function parseWinner(text)
  if MK.Match then
    local w, l = MK.Match("DUEL_WINNER_KNOCKOUT", text)
    if w then return w, l, "ko" end
    w, l = MK.Match("DUEL_WINNER_RETREAT", text)
    if w then return w, l, "flee" end
    return
  end
  local w, l = text:match(FALLBACK[1])
  if w then return w, l, "ko" end
  l, w = text:match(FALLBACK[2]) -- "%2$s has fled from %1$s": first capture is the loser
  if w then return w, l, "flee" end
end

-- Extension markets: offer an event to the settle hook of every open or locked market of an extension kind.
-- nil leaves the market to the referee (existing flow), an outcome index is an auto verdict, false voids it.
-- `fighters` (winner, loser) restricts fight events to the markets that are about those two.
local function extSettle(s, event, scope, winner, loser)
  local E = MK.Ext
  if type(E) ~= "table" or type(E.Settle) ~= "function" then return end
  local acted
  for _, m in ipairs(marketList(s)) do
    if (m.status == "open" or m.status == "locked") and (not scope or m.scope == scope) and extMarket(m.kind) then
      local involved = true
      if winner and m.a and m.b then
        local fa, fb, wl, ll = shortLower(m.a), shortLower(m.b), shortLower(winner), shortLower(loser)
        involved = (wl == fa and ll == fb) or (wl == fb and ll == fa)
      end
      if involved then
        local snap = { mid = m.mid, kind = m.kind, title = m.title, scope = m.scope, a = m.a, b = m.b, outcomes = {} }
        for i, o in ipairs(m.outcomes) do snap.outcomes[i] = { label = o.label, ref = o.ref } end
        local ev = {}
        for k, v in pairs(event) do ev[k] = v end
        local ok, res = pcall(E.Settle, m.kind, snap, ev)
        if ok and type(res) == "number" then
          if verdict(s, m, res, true) then acted = true end
        elseif ok and res == false then
          if voidMarket(s, m, "extension") then acted = true end
        end
      end
    end
  end
  if acted then
    flushNow(s)
    updated()
    maybeFinishClosing(s)
  end
end

-- Host-side manual event for extension markets: Ring.ExtSettle({ type = "manual" }) offers it to every extension market.
function Ring.ExtSettle(event)
  local s = Ring.session
  if not isHost(s) or s.status == "closed" or type(event) ~= "table" then return false end
  extSettle(s, event)
  return true
end

local function onSystem(_, text)
  local s = Ring.session
  if not isHost(s) or s.status == "closed" then return end
  text = MK.Safe(text)
  if type(text) ~= "string" then return end
  local w, l, how = parseWinner(text)
  if type(w) ~= "string" or type(l) ~= "string" then return end
  local wl, ll = shortLower(w), shortLower(l)
  for _, m in ipairs(marketList(s)) do
    if m.scope == "fight" and (m.kind == "winner" or m.kind == "method") and (m.status == "open" or m.status == "locked") then
      local fa, fb = shortLower(m.a), shortLower(m.b)
      if (wl == fa and ll == fb) or (wl == fb and ll == fa) then
        local idx
        if m.kind == "winner" then idx = wl == fa and 1 or 2
        else idx = (wl == fa and 0 or 2) + (how == "flee" and 2 or 1) end
        verdict(s, m, idx, true)
      end
    end
  end
  extSettle(s, { type = "fight_end", winner = w, loser = l, how = how }, "fight", w, l)
end

local function onSeriesStart(ev)
  local s = Ring.session
  if not isHost(s) or s.status ~= "open" or type(ev) ~= "table" then return end
  local bo = ev.champion and 5 or (ev.bo == 5 and 5 or ev.bo == 3 and 3 or 1)
  s.series = { id = clean(ev.id, 16), bo = bo, champion = ev.champion and true or false, a = full(ev.a), b = full(ev.b) }
  if s.series.a and s.series.b and not s.fighters.a then s.fighters = { a = s.series.a, b = s.series.b } end
  touch(s)
  push("open", s, { cap = s.cap, public = s.public, series = s.series.id })
  flushNow(s)
  updated()
end

local function onSeriesDone(ev)
  local s = Ring.session
  if not isHost(s) or type(ev) ~= "table" or not s.series or tostring(ev.id) ~= s.series.id then return end
  local score = tostring(ev.scoreA or 0) .. "-" .. tostring(ev.scoreB or 0)
  for _, m in ipairs(marketList(s)) do
    if m.scope == "series" and (m.status == "open" or m.status == "locked") then
      local idx
      if m.kind == "winner" then idx = outcomeOfRef(m, ev.winner)
      elseif m.kind == "score" then
        for i, o in ipairs(m.outcomes) do if o.label == score then idx = i end end
      end
      if idx then verdict(s, m, idx, true) end
    end
  end
  extSettle(s, { type = "series_done", winner = ev.winner, scoreA = ev.scoreA, scoreB = ev.scoreB, bo = s.series.bo }, "series")
end

---------------------------------------------------------------------------
-- Trade matching (§6). Ledger.lua records the trade and calls Ring.MatchTrade(tr).

local function applyPaid(s, m, b, tr, manual)
  touch(s)
  b.paid, b.paidAt, b.rev = true, now(), s.rev
  if manual then b.manual = true end
  if tr then
    tr.matched[#tr.matched + 1] = betKey(s, m, b)
    tr.sid = s.id
  end
  push("paid", s, { mid = m.mid, bettor = b.bettor, amount = b.amount, manual = manual or nil })
  sendLine(s, m, b)
  markDirty(s, m, b.outcome)
  flushSoon(s)
  updated()
end

-- Splits `amount` over candidates { left } (oldest first): one exact, else the exact sum, else partial, else excess.
local function allocate(cands, amount)
  local total = 0
  for _, c in ipairs(cands) do
    if c.left == amount then return { { c, amount } }, 0 end
    total = total + c.left
  end
  local out, rest = {}, amount
  for _, c in ipairs(cands) do
    if rest <= 0 then break end
    local x = math.min(c.left, rest)
    out[#out + 1] = { c, x }
    rest = rest - x
  end
  return out, math.max(0, amount - total)
end

local function clearDebt(d, x, by)
  d.paid = (d.paid or 0) + x
  if d.paid >= d.amount and d.status ~= "cleared" then
    d.status, d.clearedAt, d.clearedBy = "cleared", now(), by
  end
end

local function sortCands(c)
  table.sort(c, function(x, y)
    if (x.at or 0) ~= (y.at or 0) then return (x.at or 0) < (y.at or 0) end
    return x.key < y.key
  end)
end

local function hostPayoutCands(partner)
  local cands, seen = {}, {}
  for _, s in ipairs(liveAndLast()) do
    if isHost(s) and s.v2 and s.currency == "gold" then
      for _, m in ipairs(marketList(s)) do
        if FINAL[m.status] then
          seen[s.id .. "." .. m.mid] = true
          for _, b in ipairs(m.bets) do
            local left = (b.payout or 0) - (b.paidOutAmount or 0)
            if left > 0 and same(b.bettor, partner) then
              cands[#cands + 1] = { s = s, m = m, b = b, left = left, at = m.settledAt, key = betKey(s, m, b) }
            end
          end
        end
      end
    end
  end
  for _, d in ipairs(ringDB().debts) do
    if (d.role or "host") == "host" and d.status ~= "cleared" and not seen[d.id] and same(d.bettor, partner) then
      local left = d.amount - (d.paid or 0)
      if left > 0 then cands[#cands + 1] = { d = d, left = left, at = d.settledAt, key = d.id .. "." .. d.bettor } end
    end
  end
  sortCands(cands)
  return cands
end

local function applyPayout(c, x, tr, manual)
  if c.b then
    local s, m, b = c.s, c.m, c.b
    touch(s)
    b.paidOutAmount = (b.paidOutAmount or 0) + x
    if b.paidOutAmount >= (b.payout or 0) then b.paidOut, b.paidAt = true, now() end
    if manual then b.manual = true end
    b.rev = s.rev
    push("payout", s, { mid = m.mid, bettor = b.bettor, amount = x, manual = manual or nil })
    local d = findDebt(s.id .. "." .. m.mid, b.bettor, "host")
    if d then clearDebt(d, x, manual and "manual" or "host") end
    sendLine(s, m, b, s ~= Ring.session)
    if tr then tr.matched[#tr.matched + 1] = c.key; tr.sid = s.id end
  else
    local d = c.d
    clearDebt(d, x, manual and "manual" or "host")
    local sid, mid = d.id:match("^(%x+)%.(m%d)$")
    A:Push("ring", { ev = "payout", event = "payout", id = sid or d.id, mid = mid, v = 2, host = d.bookie,
      bettor = d.bettor, amount = x, manual = manual or nil })
    if tr then tr.matched[#tr.matched + 1] = c.key; tr.sid = sid end
  end
  updated()
end

local function matchStake(tr)
  tr.kind = "stake"
  local s = Ring.session
  if not (isHost(s) and s.v2 and s.currency == "gold") then tr.reason = "nobet" return end
  local open, late = {}, false
  for _, m in ipairs(marketList(s)) do
    for _, b in ipairs(m.bets) do
      if same(b.bettor, tr.partner) and not b.paid and not b.void then
        if m.status == "open" or m.status == "locked" then
          if b.t - LATE_MATCH_SEC <= tr.t then
            open[#open + 1] = { m = m, b = b, left = b.amount, at = b.t, key = betKey(s, m, b) }
          else
            late = true
          end
        else
          late = true
        end
      end
    end
  end
  if #open == 0 then tr.reason = late and "late" or "nobet" return end
  sortCands(open)
  local pick
  for _, c in ipairs(open) do
    if c.b.amount == tr.got then pick = { c } break end
  end
  if not pick then
    local sum = 0
    for _, c in ipairs(open) do sum = sum + c.b.amount end
    if sum == tr.got then pick = open end
  end
  if not pick then tr.reason = "amount" return end
  for _, c in ipairs(pick) do applyPaid(s, c.m, c.b, tr) end
  tr.reason = nil
end

local function matchPayout(tr)
  tr.kind = "payout"
  local cands = hostPayoutCands(tr.partner)
  if #cands == 0 then tr.reason = "nobet" return end
  local parts, excess = allocate(cands, tr.gave)
  for _, p in ipairs(parts) do applyPayout(p[1], p[2], tr) end
  if excess > 0 then tr.reason, tr.excess = "excess", excess else tr.reason = nil end
end

-- Mirror sessions (live or last) of the host `partner` with gold stakes.
local function bettorSessions(partner)
  local out = {}
  for _, s in ipairs(liveAndLast()) do
    if s and s.v2 and not isHost(s) and s.currency == "gold" and same(s.host, partner) then out[#out + 1] = s end
  end
  return out
end

local localPayout

local function matchBettor(tr, sessions)
  local mine = me()
  if tr.gave > 0 then
    tr.kind = "stake"
    for _, s in ipairs(sessions) do
      for _, m in ipairs(marketList(s)) do
        local b = findBet(m, mine)
        if b and not b.paid and b.amount == tr.gave and (m.status == "open" or m.status == "locked") then
          b.stakeSent = true
          tr.matched[#tr.matched + 1] = betKey(s, m, b)
          tr.sid = s.id
          updated()
          return
        end
      end
    end
    return
  end
  tr.kind = "payout"
  local cands, seen = {}, {}
  for _, s in ipairs(sessions) do
    for _, m in ipairs(marketList(s)) do
      local b = findBet(m, mine)
      if b and m.status == "settled" or (b and m.status == "void") then
        seen[s.id .. "." .. m.mid] = true
        local left = (localPayout(s, m, b) or 0) - (b.receivedAmount or 0)
        if left > 0 then cands[#cands + 1] = { s = s, m = m, b = b, left = left, at = m.settledAt or 0, key = betKey(s, m, b) } end
      end
    end
  end
  for _, d in ipairs(ringDB().debts) do
    if d.role == "bettor" and d.status ~= "cleared" and not seen[d.id] and same(d.bookie, tr.partner) then
      local left = d.amount - (d.paid or 0)
      if left > 0 then cands[#cands + 1] = { d = d, left = left, at = d.settledAt, key = d.id } end
    end
  end
  if #cands == 0 then tr.reason = "nobet" return end
  sortCands(cands)
  local parts, excess = allocate(cands, tr.got)
  for _, p in ipairs(parts) do
    local c, x = p[1], p[2]
    local id = c.d and c.d.id or (c.s.id .. "." .. c.m.mid)
    if c.b then
      c.b.receivedAmount = (c.b.receivedAmount or 0) + x
      if c.b.receivedAmount >= (localPayout(c.s, c.m, c.b) or 0) then c.b.received = true end
    end
    local d = c.d or findDebt(id, mine, "bettor")
    if d then clearDebt(d, x, "bettor") end
    local sid, mid = id:match("^(%x+)%.(m%d)$")
    A:Push("ring", { ev = "received", event = "received", id = sid or id, mid = mid, v = 2, bookie = tr.partner, amount = x })
    tr.matched[#tr.matched + 1] = c.key
    tr.sid = sid
  end
  if excess > 0 then tr.reason, tr.excess = "excess", excess end
  updated()
end

-- Matches a finalized, confirmed trade { t, partner, got, gave, confirmed } to bets. Fills tr.kind, tr.matched,
-- tr.sid and tr.reason (amount|nobet|late|both|excess) when it belongs to ring business but matched nothing.
function Ring.MatchTrade(tr)
  tr.matched = tr.matched or {}
  if not tr.confirmed or not tr.partner or not ringDB() then return tr end
  tr.t = tr.t or now()
  local hostCtx = (isHost(Ring.session) and Ring.session.v2 and Ring.session.currency == "gold")
    or (isHost(Ring.last) and Ring.last.v2 and Ring.last.currency == "gold")
  if not hostCtx then
    for _, d in ipairs(ringDB().debts) do
      if (d.role or "host") == "host" and d.status ~= "cleared" then hostCtx = true break end
    end
  end
  local sessions = bettorSessions(tr.partner)
  local bettorCtx = #sessions > 0
  if not bettorCtx then
    for _, d in ipairs(ringDB().debts) do
      if d.role == "bettor" and d.status ~= "cleared" and same(d.bookie, tr.partner) then bettorCtx = true break end
    end
  end
  if tr.got > 0 and tr.gave > 0 then
    if hostCtx or bettorCtx then tr.reason = "both" end
    return tr
  end
  if bettorCtx and (tr.gave > 0 or not hostCtx or #hostPayoutCands(tr.partner) == 0) and not (hostCtx and tr.got > 0 and isHost(Ring.session)) then
    matchBettor(tr, sessions)
  elseif hostCtx then
    if tr.got > 0 then matchStake(tr) elseif tr.gave > 0 then matchPayout(tr) end
  end
  return tr
end

-- Host: assign an unmatched trade to one bet by hand (RingTab "Assign"). Sets manual = true.
function Ring.AssignTrade(tr, sid, mid, bettor)
  for _, s in ipairs(liveAndLast()) do
    if isHost(s) and s.v2 and s.id == sid and s.markets[mid] then
      local m = s.markets[mid]
      local b = findBet(m, bettor)
      if not b then return false end
      tr.matched = tr.matched or {}
      if (tr.got or 0) > 0 and (tr.gave or 0) == 0 then
        if b.paid or FINAL[m.status] then return false end
        applyPaid(s, m, b, tr, true)
      elseif (tr.gave or 0) > 0 and (tr.got or 0) == 0 then
        local left = (b.payout or 0) - (b.paidOutAmount or 0)
        if not FINAL[m.status] or left <= 0 then return false end
        applyPayout({ s = s, m = m, b = b, key = betKey(s, m, b) }, math.min(left, tr.gave), tr, true)
      else
        return false
      end
      b.manual = true
      tr.reason, tr.manual = nil, true
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- Bettor (mirror) side

-- Own payout recomputed from the host's pools (§3.2 on the mirror). nil before a verdict.
localPayout = function(s, m, b)
  if not counts(s, b) then return 0 end
  if m.status == "void" then return b.amount end
  local r = m.result or 0
  if r == 0 then return nil end
  if m.mode == "fixed" then return b.outcome == r and Ring.FixedPayout(b.amount, b.price or 0) or 0 end
  local P = poolsOf(s, m)
  local T = 0
  for _, p in ipairs(P) do T = T + p end
  local Wr = P[r] or 0
  if Wr == 0 then return b.amount end
  if b.outcome ~= r then return 0 end
  local q = floor((T - Wr) / Wr)
  local rem = (T - Wr) - q * Wr
  return b.amount + q * b.amount + floor(rem * b.amount / Wr)
end
Ring.LocalPayout = function(mid, s)
  s = s or Ring.session
  local m = s and s.v2 and s.markets[mid]
  local b = m and findBet(m, me())
  return b and localPayout(s, m, b)
end

-- True when the host's R2L payout differs from this client's recompute (slip shows "payout mismatch").
function Ring.PayoutMismatch(mid, s)
  s = s or Ring.session
  local m = s and s.v2 and s.markets[mid]
  local b = m and findBet(m, me())
  if not b or not b.hostPayout or (m.status ~= "resolving" and m.status ~= "settled") then return false end
  local mine = localPayout(s, m, b)
  return mine ~= nil and mine ~= b.hostPayout
end

function Ring.MyBet(mid)
  local s = Ring.session
  if not s then return nil end
  if not s.v2 then
    for _, b in ipairs(s.bets or {}) do if same(b.bettor, me()) then return b end end
    return nil
  end
  return findBet(s.markets[mid or "m1"], me())
end

local function sideV1(s, name)
  if not s.fighters then return nil end
  if same(name, s.fighters.a) then return "a" end
  if same(name, s.fighters.b) then return "b" end
end

local function placeBetV1(s, fighterName, amount)
  if s.status ~= "open" then return false, "closed" end
  local on = sideV1(s, fighterName)
  if not on then return false, "fighter" end
  amount = num(amount, 0, WIRE_MAX)
  local why = refusal(s.currency, amount, s.cap, s.host)
  if why then return false, why end
  if sideV1(s, me()) then return false, "fighter" end
  for _, b in ipairs(s.bets) do if same(b.bettor, me()) then return false, "duplicate" end end
  if s.currency == "gold" then
    local have = MK.Call(GetMoney)
    if type(have) == "number" and have < amount then return false, "money" end
  end
  if not ns.comm or not ns.comm:Send("RB", { s.id, s.fighters[on], fmt(amount) }, "WHISPER", s.host) then
    return false, "send"
  end
  s.pending = { on = s.fighters[on], amount = amount, t = GetTime() }
  updated()
  return true
end

-- PlaceBet(mid, idx, amount) on a v2 ring; PlaceBet(fighterName, amount) on m1 (or a v1 ring).
function Ring.PlaceBet(a1, a2, a3)
  local s = Ring.session
  if not s then return false, "session" end
  if not s.v2 then return placeBetV1(s, a1, a2) end
  if s.readOnly then return false, "version" end
  local m, idx, amount
  if validMid(a1) then
    m, idx, amount = s.markets[a1], tonumber(a2), a3
  else
    m = s.markets.m1
    if not m or m.kind ~= "winner" then return false, "fighter" end
    idx, amount = outcomeOfRef(m, a1), a2
    if not idx then return false, "fighter" end
  end
  if s.status ~= "open" or not m or m.status ~= "open" then return false, "closed" end
  if not idx or not m.outcomes[idx] then return false, "market" end
  if findBet(m, me()) then return false, "dup" end
  if isFighter(s, m, me()) then return false, "fighter" end
  amount = num(amount, 0, WIRE_MAX)
  local why = refusal(s.currency, amount, s.cap, s.host)
  if why then return false, why end
  if isHost(s) then return false, "session" end
  if s.currency == "gold" then
    local have = MK.Call(GetMoney)
    if type(have) == "number" and have < amount then return false, "money" end
  end
  local nonce = U.RandomHex(4)
  local price = m.mode == "fixed" and (m.outcomes[idx].price or 0) or 0
  if not whisper("R2B", W.R2B(s.id, m.mid, idx, amount, price, nonce), s.host) then return false, "send" end
  s.pending = { mid = m.mid, idx = idx, amount = amount, price = price, nonce = nonce, t = GetTime() }
  s.refusal = nil
  updated()
  return true
end

-- Bettor or fighter disputes a verdict while the market is resolving (host clock decides; late -> R2X late).
function Ring.Dispute(mid, code, note)
  local s = Ring.session
  if not s or not s.v2 or isHost(s) then return false, "session" end
  local m = s.markets[mid]
  if not m or (m.status ~= "resolving" and m.status ~= "disputed") then return false, "late" end
  if m.disputeSent then return false, "dup" end
  code = DISPUTE_CODES[code] and code or "other"
  if not whisper("R2D", W.R2D(s.id, mid, code, note), s.host) then return false, "send" end
  m.disputeSent = true
  updated()
  return true
end

-- Spectator: ask a host (seen in the browser) to add me as a watcher and send its state.
function Ring.Join(host, sid)
  host = full(host)
  if not host or not validId(sid) then return false end
  Ring.joining = { host = host, sid = sid, t = GetTime() }
  whisper("R2J", W.R2J(sid), host)
  return true
end

function Ring.Browser()
  local out, t = {}, GetTime()
  for k, e in pairs(Ring.browser) do
    if t - e.seen > 180 then Ring.browser[k] = nil else out[#out + 1] = e end
  end
  table.sort(out, function(a, b) return a.seen > b.seen end)
  return out
end

-- Accepts host traffic on group, WHISPER and the WoMRing CHANNEL.
local function ringChannel(channel, info)
  if GROUP_CHANNELS[channel] then return true end
  if channel ~= "CHANNEL" then return false end
  local nm = info and (MK.Safe(info.name) or MK.Safe(info.target))
  if type(nm) == "string" and (nm:gsub("^%d+%.%s*", "")):lower() == CHANNEL_NAME:lower() then return true end
  local id = info and tonumber(MK.Safe(info.localID))
  return id ~= nil and id == chanNum()
end

local function onR2A(sender, f, channel, info)
  if channel ~= "WHISPER" and not (channel == "CHANNEL" and ringChannel(channel, info)) then return end
  local sid = f[2]
  if not validId(sid) or (f[4] ~= "gold" and f[4] ~= "points") then return end
  local n = 0
  for _ in pairs(Ring.browser) do n = n + 1 end
  local key = sender:lower()
  if not Ring.browser[key] and n >= 50 then return end
  local v = num(f[1], 0, 99)
  Ring.browser[key] = { host = sender, v = v, sid = sid, venue = (clean(f[3], 24):match("^[%w_]*$")) or "",
    currency = f[4], status = SESSION_STATUS[f[5]] and f[5] or "open", nMarkets = num(f[6], 0, MAX_MARKETS),
    nBettors = num(f[7], 0, MAX_BETTORS), cap = num(f[8], 0, WIRE_MAX), bo = num(f[9], 0, 5), raid = f[10] == "1",
    level = (Ring.Band(sender)), update = v > WIRE_V, seen = GetTime() }
  A:Fire("RING_BROWSER")
end

local function mirrorOf(sender, sid)
  local s = Ring.session
  if not s or isHost(s) or not s.v2 or s.id ~= sid or not same(sender, s.host) then return nil end
  s.lastHeard, s.rejoining, s.hostOffline = now(), nil, nil
  return s
end

local recordMine

local function onR2S(sender, f, channel, info)
  if not ringChannel(channel, info) then return end
  local v, sid, status, currency = num(f[1], 0, 99), f[2], f[3], f[5]
  if not validId(sid) or not SESSION_STATUS[status] or (currency ~= "gold" and currency ~= "points") then return end
  local s = Ring.session
  if s and isHost(s) then return end
  if s and not same(sender, s.host) then return end
  if s and s.id ~= sid then
    if s.v2 and s.status ~= "closed" then return end
    if not s.v2 and s.status ~= "settled" and s.status ~= "void" and s.status ~= "closed" then return end
    s = nil
  end
  if s and not s.v2 then s = nil end -- v1 mirror of a v2 host: upgrade
  if not s then
    if status == "closed" or status == "stale" then return end
    local viaGroup = channel ~= "WHISPER" and channel ~= "CHANNEL" and inGroup(sender)
    local joining = Ring.joining and same(Ring.joining.host, sender) and Ring.joining.sid == sid
    if not viaGroup and not joining then return end
    s = view({ v2 = true, id = sid, host = sender, isHost = false, venue = "", currency = currency, status = status,
      markets = {}, rev = 0, fighters = {}, viaGroup = viaGroup or nil })
    Ring.session = s
    persist(s)
    Ring.joining = nil
  end
  local rev = num(f[10], 0, WIRE_MAX)
  if rev < (s.rev or 0) then return end
  s.lastHeard, s.rejoining, s.hostOffline = now(), nil, nil
  s.readOnly = v > WIRE_V or nil
  s.rev, s.status = rev, status
  s.venue = (clean(f[4], 24):match("^[%w_]*$")) or ""
  s.cap = num(f[6], 0, currency == "points" and WIRE_MAX or GAMBLE_MAX_COPPER)
  local seriesId = clean(f[7], 16)
  s.series = seriesId ~= "" and { id = seriesId, bo = num(f[8], 1, 5) } or nil
  s.nMarkets = num(f[9], 0, MAX_MARKETS)
  local fl = tostring(f[11] or "")
  s.public, s.raidOpen, s.autoInvite = fl:sub(1, 1) == "1", fl:sub(2, 2) == "1", fl:sub(3, 3) == "1"
  if status == "closed" or status == "stale" then
    for _, m in pairs(s.markets) do if FINAL[m.status] then recordMine(s, m) end end
    local ring = ringDB()
    if ring then ring.last, ring.session = s, nil end
    Ring.last, Ring.session = s, nil
  end
  updated()
end

local function scheduleRecord(s, m)
  if not FINAL[m.status] or m.recorded then return end
  A:Debounce("ringRec" .. s.id .. m.mid, 3, function() recordMine(s, m) end)
end

recordMine = function(s, m)
  if m.recorded or not FINAL[m.status] then return end
  local b = findBet(m, me())
  if not b then return end
  m.recorded = true
  local payout = localPayout(s, m, b) or 0
  b.payout = payout
  if s.currency == "points" and payout > 0 then b.paidOut, b.paidOutAmount = true, payout end
  pushBetRow(s, m, b, payout)
  recordMarket(s, m, b, payout)
  if s.currency == "gold" and payout > 0 and not b.received then
    addDebt({ id = s.id .. "." .. m.mid, sid = s.id, mid = m.mid, bettor = b.bettor, bookie = s.host, amount = payout,
      paid = b.receivedAmount or 0, settledAt = now(), fight = m.fight or 0, status = "due", role = "bettor" })
  end
  local ring = ringDB()
  if ring and m.status == "settled" and (m.fight or 0) > (ring.settledFight or 0) then ring.settledFight = m.fight end
  updated()
end

local function mirrorMarket(s, mid)
  local m = s.markets[mid]
  if not m then
    local n = 0
    for _ in pairs(s.markets) do n = n + 1 end
    if n >= MAX_MARKETS then return nil end
    m = { mid = mid, kind = "custom", scope = "fight", mode = "pari", status = "open", outcomes = {}, bets = {}, result = 0, rev = 0 }
    s.markets[mid] = m
  end
  return m
end

local function onR2M(sender, f, channel, info)
  if not ringChannel(channel, info) or not validMid(f[2]) then return end
  local s = mirrorOf(sender, f[1])
  if not s then return end
  local rev = num(f[13], 0, WIRE_MAX)
  local m = mirrorMarket(s, f[2])
  if not m or rev < (m.rev or 0) then return end
  local status = MARKET_STATUS[f[6]] and f[6] or m.status
  m.kind = KINDS[f[3]] and f[3] or m.kind
  m.scope = f[4] == "series" and "series" or "fight"
  m.mode = f[5] == "fixed" and "fixed" or "pari"
  m.status, m.rev = status, rev
  local n = num(f[7], 2, MAX_OUTCOMES)
  for i = #m.outcomes + 1, n do m.outcomes[i] = { label = "", pool = 0, n = 0, price = 0 } end
  for i = #m.outcomes, n + 1, -1 do m.outcomes[i] = nil end
  m.result = num(f[8], 0, MAX_OUTCOMES)
  m.fight, m.lockAt, m.appealUntil = num(f[9], 0, WIRE_MAX), num(f[10], 0, WIRE_MAX), num(f[11], 0, WIRE_MAX)
  m.bank = num(f[12], 0, WIRE_MAX)
  m.title = clean(f[14], TITLE_MAX)
  scheduleRecord(s, m)
  updated()
end

local function onR2O(sender, f, channel, info)
  if not ringChannel(channel, info) or not validMid(f[2]) then return end
  local s = mirrorOf(sender, f[1])
  if not s then return end
  local m = mirrorMarket(s, f[2])
  local idx = num(f[3], 0, MAX_OUTCOMES)
  if not m or idx < 1 then return end
  for i = #m.outcomes + 1, idx do m.outcomes[i] = { label = "", pool = 0, n = 0, price = 0 } end
  local o = m.outcomes[idx]
  o.label, o.pool, o.n, o.price = clean(f[4], LABEL_MAX), num(f[5], 0, WIRE_MAX), num(f[6], 0, 999), num(f[7], 0, PRICE_MAX)
  if m.mid == "m1" and #m.outcomes == 2 and m.outcomes[1].label ~= "" and m.outcomes[2].label ~= "" then
    s.fighters = { a = m.outcomes[1].label, b = m.outcomes[2].label }
  end
  scheduleRecord(s, m)
  updated()
end

local function onR2L(sender, f, channel, info)
  if not ringChannel(channel, info) or not validMid(f[2]) then return end
  local s = mirrorOf(sender, f[1])
  if not s then return end
  local bettor = full(f[3] or "")
  local m = mirrorMarket(s, f[2])
  if not bettor or not m then return end
  local rev = num(f[10], 0, WIRE_MAX)
  local b = findBet(m, bettor)
  if not b then
    if #m.bets >= MAX_BETTORS then return end
    b = { bettor = bettor, rev = 0 }
    table.insert(m.bets, b)
  end
  if rev < (b.rev or 0) then return end
  local st = tostring(f[7] or "")
  b.outcome, b.amount, b.price = num(f[4], 1, MAX_OUTCOMES), num(f[5], 0, WIRE_MAX), num(f[6], 0, PRICE_MAX)
  b.paid, b.void, b.paidOut = st:sub(1, 1) == "1", st:sub(2, 2) == "1" or nil, st:sub(3, 3) == "1"
  b.hostPayout, b.paidOutAmount, b.rev = num(f[8], 0, WIRE_MAX), num(f[9], 0, WIRE_MAX), rev
  b.payout = b.hostPayout
  if m.kind == "winner" then b.side = b.outcome == 1 and "a" or "b"; b.on = m.outcomes[b.outcome] and m.outcomes[b.outcome].label end
  if same(bettor, me()) and s.pending and s.pending.mid == m.mid then s.pending = nil end
  scheduleRecord(s, m)
  updated()
end

local function onR2X(sender, f)
  local s = Ring.session
  if not s or isHost(s) or not s.v2 or f[1] ~= s.id or not same(sender, s.host) then return end
  local nonce = f[3] or ""
  if s.pending and (nonce == s.pending.nonce or nonce == "") then s.pending = nil end
  s.refusal = { mid = f[2], code = clean(f[4], 12), max = num(f[5], 0, WIRE_MAX), t = GetTime() }
  updated()
end

---------------------------------------------------------------------------
-- v1 mirror path (a v1 host only sends RS/RL)

local function onStateV1(sender, f, channel)
  if not GROUP_CHANNELS[channel] then return end
  local id, status, currency = f[1], f[2], f[4]
  if not validId(id) or not V1_STATUS[status] or (currency ~= "gold" and currency ~= "points") then return end
  local s = Ring.session
  if s and isHost(s) then return end
  if s and not same(sender, s.host) then return end
  if s and s.v2 then return end -- v2 host: R2S is the truth
  if s and s.id ~= id then
    if s.status ~= "settled" and s.status ~= "void" and s.status ~= "closed" then return end
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
  s.cap = num(f[11], 0, currency == "points" and WIRE_MAX or GAMBLE_MAX_COPPER)
  if status == "settled" or status == "void" then
    -- v1 record + v1 outbox row (no schema), unchanged
    if not s.recorded then
      s.recorded = true
      local mine
      for _, b in ipairs(s.bets) do if same(b.bettor, me()) then mine = b end end
      if mine then
        local rec = { id = s.id, t = now(), role = "bettor", host = s.host, venue = s.venue, currency = s.currency,
          a = s.fighters.a, b = s.fighters.b, winner = s.winner, status = s.status, poolA = s.totals.a,
          poolB = s.totals.b, count = s.totals.count, bet = U.Copy(mine) }
        table.insert(ns.char.bets, rec)
        while #ns.char.bets > MAX_RECORDS do table.remove(ns.char.bets, 1) end
        if s.currency == "gold" and mine.side then
          local wside = s.winner and sideV1(s, s.winner)
          local res = "void"
          if wside and mine.paid and (wside == "a" and s.totals.a or s.totals.b) > 0 then
            res = mine.side == wside and "win" or "loss"
          end
          A:Push("bet", { id = s.id, bettor = mine.bettor, bookie = s.host, amount = floor(mine.amount), side = mine.side,
            result = res, venue = s.venue ~= "" and s.venue or nil, t = now() })
        end
      end
    end
  end
  if status == "closed" then
    Ring.last = s
    Ring.session = nil
  end
  updated()
end

local function onLineV1(sender, f, channel)
  local s = Ring.session
  if not GROUP_CHANNELS[channel] or not s or isHost(s) or s.v2 or not same(sender, s.host) or f[1] ~= s.id then return end
  local bettor, on = full(f[2] or ""), clean(f[3])
  if not bettor or on == "" then return end
  local b
  for _, x in ipairs(s.bets) do if same(x.bettor, bettor) then b = x end end
  if not b then
    if #s.bets >= 60 then return end
    b = { bettor = bettor }
    table.insert(s.bets, b)
  end
  b.on = on
  b.side = sideV1(s, on)
  b.amount = num(f[4], 0, WIRE_MAX)
  b.paid = f[5] == "1"
  b.payout = num(f[6], 0, 1e12)
  b.paidOut = f[7] == "1"
  if same(bettor, me()) then s.pending = nil end
  updated()
end

local function hasOwnBet(s)
  for _, m in pairs(s.markets or {}) do if findBet(m, me()) then return true end end
  return false
end

local function onRoster()
  local s = Ring.session
  if s and not isHost(s) and not IsInGroup() then
    if s.v2 and (not s.viaGroup or hasOwnBet(s)) then return end -- outside watcher or own bets: stay (whisper path)
    Ring.session = nil
    if s.v2 and ringDB() then ringDB().session = nil end
    updated()
  elseif isHost(s) then
    A:Debounce("ringRoster", 2, function()
      local h = Ring.session
      if isHost(h) and h.status ~= "closed" then flushNow(h) end
    end)
  end
end

function Ring.Leave()
  local s = Ring.session
  if s and not isHost(s) then
    Ring.session = nil
    if s.v2 and ringDB() then ringDB().session = nil end
    updated()
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- Timers (rebuilt from timestamps: one 1 s tick reads every deadline, so a resumed session needs no re-arming)

local function hostTick(s)
  local t = now()
  for _, m in ipairs(marketList(s)) do
    if m.status == "open" then
      if (m.lockOn == "time" and (m.lockAt or 0) > 0 and t >= m.lockAt) or (m.openedAt and t - m.openedAt >= OPEN_MAX_SEC) then
        lockMarket(s, m)
        flushNow(s)
        updated()
      end
    elseif m.status == "resolving" and t >= (m.appealUntil or 0) then
      settleMarket(s, m)
    elseif m.status == "disputed" and m.dispute and t >= m.dispute.at + DISPUTE_TIMEOUT_SEC then
      m.dispute.action, m.dispute.auto = "void", true
      push("dispute_resolved", s, { mid = m.mid, action = "void", result = 0, auto = true })
      voidMarket(s, m, "dispute")
      flushNow(s)
      updated()
    end
    if Ring.session ~= s then return end
  end
  if s.status == "closing" then maybeFinishClosing(s) end
  if Ring.session == s and (s.status == "open" or s.status == "closing") and t - (s.lastActivity or t) >= STALE_SEC then
    for _, m in ipairs(marketList(s)) do voidMarket(s, m, "stale") end
    closeSession(s)
    return
  end
  if Ring.session == s then sendAnnounce(s) end
end

local function tick()
  local s = Ring.session
  if isHost(s) and s.v2 then
    hostTick(s)
  elseif s and s.v2 and s.rejoining and not s.hostOffline and now() - (s.rejoinAt or 0) >= 60 then
    s.hostOffline = true
    updated()
  end
  advanceOwes()
end
Ring.Tick = tick

---------------------------------------------------------------------------
-- WoMRing channel join (MK.Lobby pattern: JoinChannelByName, 4 attempts with back-off, never required)

local join = { attempt = 0, gen = 0 }
local function tryJoin()
  if A.db.config.ring.channel == false then return end
  if chanNum() then join.joined = true return end
  if MK.InstanceState() or MK.ChatLocked() then
    join.gen = join.gen + 1
    local g = join.gen
    A:After(30, function() if g == join.gen then tryJoin() end end)
    return
  end
  if join.attempt >= 4 then join.failed = true return end
  join.attempt = join.attempt + 1
  pcall(securecall or function(fn, ...) return fn(...) end, JoinChannelByName, CHANNEL_NAME)
  local attempt = join.attempt
  A:After(2, function()
    if chanNum() then
      join.joined = true
      local remove = ChatFrame_RemoveChannel or (ChatFrameUtil and ChatFrameUtil.RemoveChannel)
      if remove then
        for i = 1, NUM_CHAT_WINDOWS or 10 do
          local frame = _G["ChatFrame" .. i]
          if frame then pcall(remove, frame, CHANNEL_NAME) end
        end
      end
    else
      join.gen = join.gen + 1
      local g = join.gen
      A:After(5 * 2 ^ (attempt - 1), function() if g == join.gen then tryJoin() end end)
    end
  end)
end

---------------------------------------------------------------------------
-- Resume after reload/logout (§1.6)

local function resume()
  local ring = ringDB()
  if not ring then return end
  ring.v = 2
  if type(ring.last) == "table" then Ring.last = view(ring.last) end
  local s = ring.session
  if type(s) ~= "table" or not s.v2 then ring.session = nil return end
  view(s)
  Ring.session = s
  if s.isHost then
    if not same(s.host, me()) then
      Ring.session, ring.session = nil, nil
      return
    end
    if now() - (s.lastActivity or 0) <= STALE_SEC then
      hostTick(s) -- resolving past appealUntil settles now, disputed past timeout voids
      if Ring.session == s then
        for _, m in pairs(s.markets) do markDirty(s, m, "all") end
        A:After(1, function() if Ring.session == s then flushNow(s) end end)
      end
    else
      s.status = "stale"
      for _, m in ipairs(marketList(s)) do voidMarket(s, m, "stale") end
      closeSession(s)
    end
  else
    s.rejoining, s.rejoinAt, s.hostOffline = true, now(), nil
    whisper("R2Q", W.R2Q(s.id, 0, ""), s.host)
  end
end

---------------------------------------------------------------------------
-- Fighter side: tell the host the duel countdown began

A:Listen("DUEL_COUNTDOWN", function(rec)
  local s = Ring.session
  if not s or isHost(s) or not ns.comm then return end
  local opp = rec and rec.opp and rec.opp.name and full(rec.opp.name)
  if not opp then return end
  if s.v2 then
    for _, m in pairs(s.markets) do
      if m.status == "open" and isFighter(s, m, me()) and isFighter(s, m, opp) then
        return whisper("RF", { s.id }, s.host)
      end
    end
  elseif s.status == "open" and sideV1(s, me()) and sideV1(s, opp) then
    ns.comm:Send("RF", { s.id }, "WHISPER", s.host)
  end
end)

A:Listen("RING_UPDATED", function()
  local s = Ring.session
  if not s or isHost(s) or not ns.comm then return end
  if not s.v2 then
    if s.totals and (s.totals.count or 0) > #s.bets and (not s.resyncAt or GetTime() - s.resyncAt > 15) then
      s.resyncAt = GetTime()
      ns.comm:Send("RQ", { s.id }, "WHISPER", s.host)
    end
    return
  end
  -- gap: the host counts more bettors in a market than lines we hold
  for _, m in pairs(s.markets) do
    local n = 0
    for _, o in ipairs(m.outcomes) do n = n + (o.n or 0) end
    if n > #m.bets and (not s.resyncAt or GetTime() - s.resyncAt > 15) then
      s.resyncAt = GetTime()
      whisper("R2Q", W.R2Q(s.id, 0, "l"), s.host)
      return
    end
  end
end)

A:Listen("SERIES_START", onSeriesStart)
A:Listen("SERIES_DONE", onSeriesDone)

function M:OnLogin()
  if ns.comm then
    local c = ns.comm
    c:On("RB", onBetV1)
    c:On("RS", onStateV1)
    c:On("RL", onLineV1)
    c:On("RF", onFightStart)
    c:On("RQ", onResyncV1)
    c:On("R2A", onR2A)
    c:On("R2S", onR2S)
    c:On("R2M", onR2M)
    c:On("R2O", onR2O)
    c:On("R2L", onR2L)
    c:On("R2X", onR2X)
    c:On("R2B", onR2B)
    c:On("R2D", onR2D)
    c:On("R2Q", onR2Q)
    c:On("R2J", onR2J)
  end
  A:On("CHAT_MSG_SYSTEM", onSystem)
  A:On("GROUP_ROSTER_UPDATE", onRoster)
  A:On("PLAYER_ENTERING_WORLD", function()
    join.attempt = 0
    join.gen = join.gen + 1
    local g = join.gen
    A:After(6, function() if g == join.gen then tryJoin() end end)
  end)
  resume()
  A:Every(1, tick)
end
