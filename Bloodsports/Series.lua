-- Series: bo1 / bo3 / bo5 state machine layered over Duel.lua. Every round is one ordinary duel (one DUEL_RESOLVED); the
-- series only tracks per-round results, the score and the winner, then resets the duel engine between rounds.
--
-- Messages fired (BETTING_CONTRACT 1.7, Ring links on them):
--   SERIES_START { id, bo, a, b, champion, challenge, venue }   a = me, b = opponent (Name-Realm)
--   SERIES_ROUND { id, round, winner, how, scoreA, scoreB }     winner = Name-Realm, how = Duel end reason (knockout|retreat)
--   SERIES_DONE  { id, winner, scoreA, scoreB, bo, ... }        winner nil + void = true when nobody won (see reasons)
-- Internal: SERIES_RESET (duel engine reset between rounds), SERIES_UPDATED (UI refresh).
--
-- CONTRACT NOTE: a round ends with Duel's own reasons. knockout / retreat decide the round (the one who fled loses it).
--   void duels (timeout, unknown) do NOT count and the round is replayed; MAX_VOIDS in a row void the series.
-- CONTRACT NOTE: Series.Forfeit(side) hands the series to the other side (scores as they stand, reason "forfeit").
--   Nobody moving for IDLE_SEC voids the series (reason "timeout"): we cannot know who left, so bets are refunded.
-- CONTRACT NOTE: champion challenge duels (Club) are always bo5, whatever the picker says (Series.FormatFor).
-- CONTRACT NOTE: state lives in ns.char.series = { active = <series>, last = <summary> } inside BloodsportsDB, read lazily,
--   so a /reload resumes mid-series. Duel records carry rec.series = { id, round, bo, champion }.

local _, ns = ...
local MK = MetaKit
local U = MK.Util
local A = ns.A
local D = ns.Duel

local M = A:NewModule("Series")
local Series = {}
ns.Series = Series
D.FormatFor = function(ctx) return Series.FormatFor(ctx) end -- entry point for Duel / Confirm UI

Series.IDLE_SEC = 1800
Series.MAX_VOIDS = 2
local VALID = { [1] = true, [3] = true, [5] = true }

---------------------------------------------------------------------------
-- Store

local function store()
  local c = ns.char
  if not c then return nil end
  c.series = type(c.series) == "table" and c.series or {}
  return c.series
end

function Series.Active()
  local st = store()
  return st and st.active or nil
end

function Series.Last()
  local st = store()
  return st and st.last or nil
end

local function now() return U.ServerTime() end

local function myName() return (MK.PlayerKey()) end

local function oppFull(opp)
  if type(opp) ~= "table" or type(opp.name) ~= "string" or opp.name == "" then return nil end
  if opp.name:find("-", 1, true) then return opp.name end
  if type(opp.realm) == "string" and opp.realm ~= "" then return opp.name .. "-" .. opp.realm end
  return MK.FullName(opp.name)
end

local function sameOpp(a, b) return D.SameName(a, b) end

---------------------------------------------------------------------------
-- Format

function Series.Preferred()
  local bo = A.db and A.db.config and tonumber(A.db.config.bo)
  return VALID[bo] and bo or 1
end

function Series.SetPreferred(bo)
  bo = tonumber(bo)
  if not VALID[bo] then return false end
  A.db.config.bo = bo
  A:Fire("SERIES_UPDATED")
  return true
end

-- bo, champion, challengeId for a duel context { champion?, challenge?, venue?, opp? (name), bo? }.
-- A Club challenge against its champion (explicit flag, or an open challenge at this venue vs this opponent) is bo5 no
-- matter what ctx.bo / the saved preference say; everything else is ctx.bo, else the preference, else bo1.
function Series.FormatFor(ctx)
  ctx = type(ctx) == "table" and ctx or {}
  local champion, challenge = ctx.champion and true or false, ctx.challenge
  if not champion and ns.Club and ns.Club.OpenChallengeAgainst and ctx.venue and ctx.opp then
    local c = ns.Club.OpenChallengeAgainst(ctx.venue, ctx.opp)
    if c then champion, challenge = true, c.id end
  end
  if champion then return 5, true, challenge end
  local bo = tonumber(ctx.bo)
  return VALID[bo] and bo or Series.Preferred(), false, nil
end

---------------------------------------------------------------------------
-- Lifecycle

local function firstTo(bo) return (bo + 1) / 2 end

local function touch(s) s.updatedAt = now() end

local function finish(s, side, reason)
  local st = store()
  if st and st.active == s then st.active = nil end
  s.done = true
  local winner = side and (side == "a" and s.a or s.b) or nil
  local ev = {
    id = s.id, bo = s.bo, a = s.a, b = s.b, winner = winner, scoreA = s.scoreA, scoreB = s.scoreB,
    champion = s.champion, challenge = s.challenge, venue = s.venue, reason = reason, void = (winner == nil) or nil,
  }
  if st then
    st.last = { id = s.id, bo = s.bo, a = s.a, b = s.b, winner = winner, scoreA = s.scoreA, scoreB = s.scoreB,
      champion = s.champion, challenge = s.challenge, reason = reason, rounds = #s.rounds, t = now() }
  end
  A:Fire("SERIES_DONE", ev)
  A:Fire("SERIES_UPDATED")
  return ev
end

-- Creates the active series. opts: { bo, champion, challenge, venue }. Returns the series, or nil, "active".
function Series.Start(oppName, opts)
  local st = store()
  if not st or type(oppName) ~= "string" or oppName == "" then return nil, "opponent" end
  opts = opts or {}
  if st.active then
    if #st.active.rounds > 0 then return nil, "active" end
    finish(st.active, nil, "replaced")
  end
  local bo, champion, challenge = Series.FormatFor({ bo = opts.bo, champion = opts.champion, challenge = opts.challenge,
    venue = opts.venue, opp = oppName })
  local s = {
    id = U.RandomHex(8), bo = bo, firstTo = firstTo(bo), a = myName(), b = MK.FullName(oppName) or oppName,
    champion = champion or nil, challenge = challenge, venue = opts.venue,
    scoreA = 0, scoreB = 0, rounds = {}, voids = 0, startedAt = now(), updatedAt = now(),
  }
  st.active = s
  A:Fire("SERIES_START", { id = s.id, bo = s.bo, a = s.a, b = s.b, champion = s.champion and true or false,
    challenge = s.challenge, venue = s.venue })
  A:Fire("SERIES_UPDATED")
  return s
end

-- Duel engine back to a clean slate between rounds (the existing reset path: Duel.Cancel). Never while a duel is live.
local function resetRound(s)
  if D.state == "IDLE" then D.Cancel() end
  A:Fire("SERIES_RESET", s)
  A:Fire("SERIES_UPDATED")
end

-- Ends the series in favour of the other side. side = who forfeits ("a" = me, "b" = opponent).
function Series.Forfeit(side)
  local s = Series.Active()
  if not s or (side ~= "a" and side ~= "b") then return nil end
  return finish(s, side == "a" and "b" or "a", "forfeit")
end

-- Voids the active series (nobody wins; markets refund).
function Series.Cancel(reason)
  local s = Series.Active()
  if not s then return nil end
  return finish(s, nil, reason or "cancelled")
end

local function onRound(s, rec)
  local side = rec.result == "win" and "a" or "b"
  local n = #s.rounds + 1
  s.rounds[n] = { n = n, winner = side, how = rec.how, duel = rec.id, t = rec.t }
  if side == "a" then s.scoreA = s.scoreA + 1 else s.scoreB = s.scoreB + 1 end
  s.voids = 0
  touch(s)
  A:Fire("SERIES_ROUND", { id = s.id, round = n, winner = side == "a" and s.a or s.b, how = rec.how,
    scoreA = s.scoreA, scoreB = s.scoreB })
  local need = s.firstTo
  if s.scoreA >= need then return finish(s, "a", "score") end
  if s.scoreB >= need then return finish(s, "b", "score") end
  resetRound(s)
end

local function onResolved(rec)
  local s = Series.Active()
  local tag = type(rec) == "table" and rec.series
  if not s or type(tag) ~= "table" or tag.id ~= s.id then return end
  -- a duel is one round (or one void) however often its record is announced
  if rec.id then
    if s.lastRec == rec.id then return end
    for _, r in ipairs(s.rounds) do if r.duel == rec.id then return end end
    s.lastRec = rec.id
  end
  if rec.result == "win" or rec.result == "loss" then return onRound(s, rec) end
  -- void duel (timeout / unknown): replay the round; repeated voids void the series
  s.voids = (s.voids or 0) + 1
  touch(s)
  if s.voids >= Series.MAX_VOIDS then return finish(s, nil, rec.how or "void") end
  resetRound(s)
end

local function onCountdown(rec)
  local st = store()
  if not st or type(rec) ~= "table" or type(rec.opp) ~= "table" or not rec.opp.name then return end
  local opp = oppFull(rec.opp)
  if not opp then return end
  local s = st.active
  local bo, champion = Series.FormatFor({ venue = rec.venue, opp = opp })
  if s then
    local fresh = #s.rounds == 0
    if sameOpp(s.b, opp) and not (fresh and (s.bo ~= bo or (s.champion and true or false) ~= champion)) then
      touch(s) -- next round of the running series
    elseif fresh then
      s = nil -- never played / cancelled before the first round: replaced below
    else
      return -- somebody else, mid-series: this duel is not part of it
    end
  end
  if not s then
    local chal = champion and ns.Club and ns.Club.OpenChallengeAgainst(rec.venue, opp)
    s = Series.Start(opp, { bo = bo, champion = champion, venue = rec.venue, challenge = chal and chal.id or nil })
    if not s then return end
  end
  rec.series = { id = s.id, round = #s.rounds + 1, bo = s.bo, champion = s.champion or nil }
end

---------------------------------------------------------------------------
-- Idle expiry

function Series.Tick()
  local s = Series.Active()
  if s and now() - (s.updatedAt or s.startedAt or 0) > Series.IDLE_SEC then
    finish(s, nil, "timeout")
  end
end

---------------------------------------------------------------------------
-- Display

-- "BO3 round 2 (1-0)" from my side; nil with no series.
function Series.Describe(s)
  s = s or Series.Active()
  if not s then return nil end
  return string.format("BO%d round %d (%d-%d)", s.bo, math.min(#s.rounds + 1, s.bo), s.scoreA, s.scoreB)
end

---------------------------------------------------------------------------
-- Slash: /bs bo [1|3|5|forfeit|cancel]

A:Command("bo", "bo <1|3|5> - best-of format for your next duels; bo forfeit | bo cancel - end the running series", function(arg)
  arg = (arg or ""):lower():gsub("%s", "")
  if arg == "forfeit" then
    if not Series.Forfeit("a") then A:Print("no series running") end
    return
  elseif arg == "cancel" then
    if not Series.Cancel("cancelled") then A:Print("no series running") end
    return
  elseif arg ~= "" then
    local bo = tonumber(arg:match("^bo(%d)$") or arg)
    if not Series.SetPreferred(bo) then
      A:Print("usage: /bs bo <1|3|5>")
      return
    end
    A:Print("next duels: best of " .. bo .. " (Club champion challenges are always best of 5)")
    return
  end
  local s = Series.Active()
  A:Print("format: best of " .. Series.Preferred() .. (s and ("; running: " .. Series.Describe(s) .. " vs " .. (s.b or "?")) or ""))
end)

---------------------------------------------------------------------------
-- Wiring. Listeners register in OnLogin: after the load-time listeners (Confirm, Ring) so SERIES_ROUND / SERIES_DONE
-- follow their DUEL_RESOLVED, and before the UI modules (later in the TOC) so the card sees the series tag.

function M:OnLogin()
  A:Listen("DUEL_COUNTDOWN", onCountdown)
  A:Listen("DUEL_RESOLVED", onResolved)
  Series.Tick() -- a series older than IDLE_SEC at login is void; a fresh one simply resumes
  A:Every(15, Series.Tick)
  A:Fire("SERIES_UPDATED")
end
