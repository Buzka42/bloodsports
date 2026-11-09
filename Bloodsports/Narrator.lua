-- Narrator: public ring announcements and live duel beats, every line through the shared MK.Chat sink (category
-- "bloodsports"): paced, deduped, capped per duel / series / ring session, and silent while chat is locked.
--
-- Sources (nothing is read from the game here, and nothing from the combat log):
--   DUEL_COUNTDOWN / DUEL_STARTED / DUEL_RESOLVED   Duel.lua's own messages
--   duel beats between start and finish            a 1 Hz look at ns.Duel.rec, the record Duel's own sampler fills
--                                                  (firstBlood, me.hpEnd / opp.hpEnd); a side with unreadable HP has nil there
--   SERIES_START / SERIES_ROUND / SERIES_DONE       Series.lua (best-of series only: a bo1 is just the duel)
--   RING_UPDATED                                    Ring.lua has no per-step messages, so a host's session is diffed against the
--                                                  last look: ring opened, betting open, locked, verdict, void, settled (payouts)
--
-- Config: BloodsportsDB.config.chat.cats.bloodsports = { on, route, level }
--   level "off"       nothing
--   level "headline"  (default) duel start / first blood / a side under 20% HP / finish; series result; ring opened,
--                     betting open, locked, verdict, void, payouts summary
--   level "full"      adds the countdown, the half-health beat, each series round, the pool at lock, disputes, ring closed
-- Ring lines are only said by the host; a ring that is not public goes to the group instead of /say.
-- CONTRACT NOTE: a ring found already running when the addon loads (reload) is adopted silently: only changes after that
--   are announced, never a replay of old states.

local _, ns = ...
local MK = MetaKit
local U = MK.Util
local A = ns.A
local D = ns.Duel

local M = A:NewModule("Narrator")
local N = {}
ns.Narrator = N

local CAT = "bloodsports"
local LEVEL = { off = 0, headline = 1, full = 2 }
N.LEVEL = LEVEL
local LOW_HP, HALF_HP = 20, 50
local FRESH_SEC = 5          -- a ring older than this at first sight was already running: adopt it silently

local duelSeq = 0
local duel = nil             -- per-duel beat state { scope, fb, low = {}, half = {}, ticker }
local ring = { sid = nil, markets = {}, status = nil }

---------------------------------------------------------------------------
-- Config / sink

function N.Level()
  local c = MK.Chat and MK.Chat.Cat(CAT)
  return c and LEVEL[c.level] or (c and LEVEL.headline) or LEVEL.off
end

-- Says a line when the configured level reaches `min` (1 headline, 2 full). opts: scope, important, route.
local function say(min, text, opts)
  if not MK.Chat or N.Level() < min then return false, "level" end
  return MK.Chat.Say(CAT, text, opts)
end
N.Say = say

local function short(n) return D.Short(n) end

-- Extension narrators (MK.Ext kind "narrator"): said right after our own line for the same event, same scope and
-- route, through the same sink, so MK.Chat's pacing, dedupe and caps apply. Never important: a capped sink drops them
-- before our own lines. A missing MK.Ext (older MetaKit copy) or a failing provider changes nothing.
-- categories: fight_start first_blood kill flee series_done ring_verdict. ctx is best-effort, always has `source`.
local function extSay(category, ctx, opts)
  local E = MK.Ext
  if type(E) ~= "table" or type(E.NarratorLines) ~= "function" then return end
  ctx = ctx or {}
  ctx.source = CAT
  local ok, list = pcall(E.NarratorLines, category, ctx)
  if not ok or type(list) ~= "table" then return end
  for _, line in ipairs(list) do
    if type(line) == "string" and line ~= "" then
      say(1, line, { scope = opts and opts.scope, route = opts and opts.route })
    end
  end
end

local function myName()
  return D.meName or short((MK.PlayerKey())) or "Me"
end

local function oppName(rec)
  return rec and rec.opp and short(rec.opp.name) or "the opponent"
end

---------------------------------------------------------------------------
-- Duel

local function stopTicker()
  if duel and duel.ticker then duel.ticker:Cancel() duel.ticker = nil end
end

local function beats()
  local r = D.rec
  if not r or D.state == "IDLE" then return stopTicker() end -- cancelled / resolved without a DUEL_RESOLVED for us
  if not duel or (D.state ~= "ACTIVE" and D.state ~= "OOB") then return end
  local scope = duel.scope
  if r.firstBlood and not duel.fb then
    duel.fb = true
    -- rec.firstBlood is the side that bled first; the other one drew it
    local drew = r.firstBlood == "me" and oppName(r) or myName()
    say(1, string.format("First blood to %s!", drew), { scope = scope })
    extSay("first_blood", { winner = drew, loser = r.firstBlood == "me" and myName() or oppName(r) }, { scope = scope })
  end
  for _, side in ipairs({ "me", "opp" }) do
    local hp = r[side] and r[side].hpEnd
    if type(hp) == "number" then
      local who = side == "me" and myName() or oppName(r)
      if hp < LOW_HP and not duel.low[side] then
        duel.low[side] = true
        say(1, string.format("%s is on the ropes, under %d%% health!", who, LOW_HP), { scope = scope })
      elseif hp < HALF_HP and hp >= LOW_HP and not duel.half[side] then
        duel.half[side] = true
        say(2, string.format("%s is down to half health.", who), { scope = scope })
      end
    end
  end
end

local function onCountdown(rec)
  say(2, string.format("Duel incoming: %s vs %s. Get ready!", myName(), oppName(rec)),
    { scope = "duel:" .. (duelSeq + 1) })
end

local function onStarted(rec)
  stopTicker()
  duelSeq = duelSeq + 1
  duel = { scope = "duel:" .. duelSeq, low = {}, half = {} }
  local tag = type(rec) == "table" and rec.series
  local head = "Duel"
  if type(tag) == "table" and (tag.bo or 1) > 1 then
    head = string.format(tag.champion and "Champion challenge, round %d of BO%d" or "Round %d of BO%d", tag.round or 1, tag.bo)
  end
  say(1, string.format("%s: %s vs %s. Fight!", head, myName(), oppName(rec)), { scope = duel.scope, important = true })
  extSay("fight_start", { a = myName(), b = oppName(rec), head = head }, { scope = duel.scope })
  duel.ticker = A:Every(1, beats)
end

local function finishText(rec)
  local me, opp = myName(), oppName(rec)
  local dur = (rec.dur or 0) > 0 and (" in " .. U.Duration(rec.dur)) or ""
  local text
  if rec.result == "win" then
    text = rec.how == "retreat" and string.format("%s fled! %s wins%s.", opp, me, dur)
      or string.format("%s defeats %s by knockout%s.", me, opp, dur)
  elseif rec.result == "loss" then
    text = rec.how == "retreat" and string.format("%s fled the duel. %s wins%s.", me, opp, dur)
      or string.format("%s defeats %s by knockout%s.", opp, me, dur)
  else
    return "The duel was called off, no result."
  end
  if rec.comeback then text = text .. " What a comeback!" end
  return text
end

local function onResolved(rec)
  if type(rec) ~= "table" then return end
  local scope = duel and duel.scope or ("duel:" .. duelSeq)
  stopTicker()
  say(1, finishText(rec), { scope = scope, important = true })
  if rec.result == "win" or rec.result == "loss" then
    local won = rec.result == "win"
    extSay(rec.how == "retreat" and "flee" or "kill", { winner = won and myName() or oppName(rec),
      loser = won and oppName(rec) or myName(), dur = rec.dur, comeback = rec.comeback and true or false }, { scope = scope })
  end
  if N.Level() >= 2 and rec.result ~= "void" and rec.me and type(rec.me.hpEnd) == "number" then
    say(2, string.format("%s finished on %d%% health.", myName(), rec.me.hpEnd), { scope = scope })
  end
  duel = nil
end

---------------------------------------------------------------------------
-- Series (best-of only)

local function onSeriesStart(ev)
  if type(ev) ~= "table" or (ev.bo or 1) < 2 then return end
  say(ev.champion and 1 or 2, string.format("%sBest of %d: %s vs %s.", ev.champion and "Champion challenge! " or "",
    ev.bo, short(ev.a) or "?", short(ev.b) or "?"), { scope = "series:" .. tostring(ev.id) })
end

local function onSeriesRound(ev)
  local s = ns.Series and ns.Series.Active()
  if type(ev) ~= "table" or not s or s.id ~= ev.id or (s.bo or 1) < 2 then return end -- a bo1 is just the duel
  say(2, string.format("Round %d to %s. Series %d-%d.", ev.round or 0, short(ev.winner) or "?", ev.scoreA or 0, ev.scoreB or 0),
    { scope = "series:" .. tostring(ev.id) })
end

local function onSeriesDone(ev)
  if type(ev) ~= "table" or (ev.bo or 1) < 2 then return end
  local scope = "series:" .. tostring(ev.id)
  if not ev.winner then
    say(1, string.format("The best-of-%d series was called off.", ev.bo), { scope = scope, important = true })
    return
  end
  local a, b = ev.scoreA or 0, ev.scoreB or 0
  if ev.winner ~= ev.a then a, b = b, a end
  say(1, string.format("%s wins the best-of-%d series %d-%d!", short(ev.winner) or "?", ev.bo, a, b),
    { scope = scope, important = true })
  extSay("series_done", { winner = short(ev.winner), bo = ev.bo, scoreA = ev.scoreA, scoreB = ev.scoreB }, { scope = scope })
end

---------------------------------------------------------------------------
-- Ring (host only)

local function amount(s, n)
  n = tonumber(n) or 0
  if s.currency == "points" then return string.format("%d pts", n) end
  if n % 10000 == 0 then return string.format("%dg", n / 10000) end
  return U.Money(n)
end

local function labels(m)
  local out = {}
  for i, o in ipairs(m.outcomes or {}) do out[i] = o.label or "?" end
  return table.concat(out, " / ")
end

local function counted(m)
  local n, paid, staked = 0, 0, 0
  for _, b in ipairs(m.bets or {}) do
    if not b.void then n = n + 1; paid = paid + (b.payout or 0); staked = staked + (b.amount or 0) end
  end
  return n, paid, staked
end

local function ringSay(s, min, text, important)
  return say(min, text, { scope = "ring:" .. tostring(s.id), important = important, route = (not s.public) and "group" or nil })
end

local function onMarket(s, m, prev)
  local cur, title = m.status, m.title or m.mid
  if cur == "open" and prev == "draft" then
    ringSay(s, 1, string.format("Betting is OPEN on %s: %s.", title, labels(m)))
  elseif cur == "locked" then
    local n, _, staked = counted(m)
    ringSay(s, 1, N.Level() >= 2 and string.format("Bets LOCKED on %s: %d bets, %s in the pool. Fight!", title, n, amount(s, staked))
      or string.format("Bets LOCKED on %s. Fight!", title))
  elseif cur == "resolving" then
    local o = m.outcomes and m.outcomes[m.result]
    ringSay(s, 1, string.format("Verdict on %s: %s!", title, o and o.label or "?"), true)
    extSay("ring_verdict", { title = title, kind = m.kind, outcome = o and o.label, ref = o and o.ref },
      { scope = "ring:" .. tostring(s.id), route = (not s.public) and "group" or nil })
  elseif cur == "void" then
    ringSay(s, 1, string.format("%s is void, all bets refunded.", title), true)
  elseif cur == "settled" then
    local n, paid = counted(m)
    ringSay(s, 1, n == 0 and string.format("%s settled: no bets.", title)
      or string.format("%s settled: %d bets, %s paid out.", title, n, amount(s, paid)), true)
  elseif cur == "disputed" then
    ringSay(s, 2, string.format("A dispute was raised on %s.", title))
  end
end

local function onRing()
  local R = ns.Ring
  local s = R and R.session
  if not s or not s.isHost then
    -- Ring.Close drops the session the moment it is closed: the finished one waits in Ring.last
    local last = R and R.last
    if ring.sid and last and last.id == ring.sid and last.isHost and last.status == "closed" then
      ringSay(last, 2, "The ring is closed. Thanks for betting!")
    end
    ring = { sid = nil, markets = {}, status = nil }
    return
  end
  local list = R.Markets and R.Markets(s) or {}
  if ring.sid ~= s.id then
    local fresh = (U.ServerTime() - (s.createdAt or 0)) <= FRESH_SEC
    ring = { sid = s.id, markets = {}, status = s.status }
    if not fresh then -- adopt silently
      for _, m in ipairs(list) do ring.markets[m.mid] = m.status end
      return
    end
    ringSay(s, 1, string.format("%s opens a betting ring (%s, bets up to %s).", short(s.host) or "The referee",
      s.currency == "points" and "points" or "gold", amount(s, s.cap)))
  end
  for _, m in ipairs(list) do
    local prev = ring.markets[m.mid] or "draft"
    if prev ~= m.status then
      ring.markets[m.mid] = m.status
      onMarket(s, m, prev)
    end
  end
  ring.status = s.status
end

---------------------------------------------------------------------------
-- Wiring

function M:OnInit(db)
  if MK.Chat then MK.Chat.Configure(db.config.chat) end
end

A:Listen("DUEL_COUNTDOWN", onCountdown)
A:Listen("DUEL_STARTED", onStarted)
A:Listen("DUEL_RESOLVED", onResolved)
A:Listen("SERIES_START", onSeriesStart)
A:Listen("SERIES_ROUND", onSeriesRound)
A:Listen("SERIES_DONE", onSeriesDone)
A:Listen("RING_UPDATED", onRing)
