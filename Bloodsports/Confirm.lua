-- Duel confirmation handshake over ns.comm (prefix BSPT): DH hello/nonces, DR result exchange, DV referee verdicts.
-- Only participants may confirm/dispute a record, only referees (db.referees or the ring host) may issue verdicts.
--
-- CONTRACT NOTE: rec.id is the matchId: provisionally our own nonce from the countdown on, replaced by the sorted nonce
--   concat when the opponent's DH arrives (usually < 1 s). A late DH after the record is saved does not rewrite the id.
-- CONTRACT NOTE: a referee verdict that contradicts the saved result flips it (referee is authoritative) and may also
--   upgrade a void record; streaks are recomputed from history.

local _, ns = ...
local MK = MetaKit
local U = MK.Util
local A = ns.A
local D = ns.Duel

local C = {}
ns.Confirm = C

local HELLO_WAIT, VERDICT_WINDOW, STASH_TTL, MAX_PEERS = 5, 120, 120, 300

local cur            -- { rec, nonce, oppNonce, matchId, noPeer }
local earlyDR, earlyDV = {}, {}

local function norm(n) return MK.FullName(n) end

local function sameFull(a, b)
  a, b = norm(a), norm(b)
  return a ~= nil and a == b
end

local function oppFull(rec)
  local o = rec and rec.opp
  if not o or not o.name then return nil end
  return o.realm and (o.name .. "-" .. o.realm) or norm(o.name)
end

local function myName() return D.meName or D.Short((MK.PlayerKey())) end

local function winnerOf(rec)
  if rec.result == "win" then return myName() end
  if rec.result == "loss" then return rec.opp.name end
end

local function send(msgType, fields, target)
  if not (ns.comm and target) then return false end
  for i = 1, #fields do fields[i] = tostring(fields[i]) end
  return ns.comm:Send(msgType, fields, "WHISPER", target)
end

local function touchPeer(sender, class, level, version)
  local peers = A.db.peers
  local p = peers[sender] or {}
  p.class = (class and class ~= "" and class) or p.class
  p.level = tonumber(level) or p.level
  p.version = tonumber(version) or p.version
  p.seen = U.ServerTime()
  peers[sender] = p
  local n, oldest, oldKey = 0, nil, nil
  for k, v in pairs(peers) do
    n = n + 1
    if not oldest or (v.seen or 0) < oldest then oldest, oldKey = v.seen or 0, k end
  end
  if n > MAX_PEERS and oldKey then peers[oldKey] = nil end
end

local function changed(rec, extra)
  local row = { id = rec.id, confirmed = rec.confirmed }
  for k, v in pairs(extra or {}) do row[k] = v end
  A:Push("duel_confirm", row)
  A:Fire("DUEL_CONFIRMED", rec)
end

---------------------------------------------------------------------------
-- Handshake

function C.MatchId() return cur and cur.matchId end

local function begin(rec)
  if cur and cur.rec == rec then return cur end
  local c = { rec = rec, nonce = U.RandomHex(8) }
  c.matchId = c.nonce
  rec.id = c.nonce
  cur = c
  local target = oppFull(rec)
  if target then
    local me = MK.UnitInfo("player") or {}
    send("DH", { c.nonce, ns.VERSION, me.class or "", me.level or "" }, target)
  end
  A:After(HELLO_WAIT, function()
    if cur == c and not c.oppNonce then c.noPeer = true end -- opponent runs no addon: stay "self"
  end)
  return c
end

A:Listen("DUEL_COUNTDOWN", begin)

local function onHello(sender, f)
  touchPeer(sender, f[3], f[4], f[2])
  local rec = D.rec
  if not rec or not sameFull(sender, oppFull(rec)) then return end
  local nonce = f[1]
  if type(nonce) ~= "string" or not nonce:match("^%x+$") or #nonce > 16 then return end
  local c = begin(rec)
  if c.oppNonce then return end
  c.oppNonce, c.noPeer = nonce, nil
  c.matchId = c.nonce < nonce and (c.nonce .. nonce) or (nonce .. c.nonce)
  rec.id = c.matchId
  if not rec.opp.class and f[3] and f[3] ~= "" then rec.opp.class = f[3] end
  rec.opp.level = rec.opp.level or tonumber(f[4])
end

---------------------------------------------------------------------------
-- Result exchange

local function findById(id)
  local list = ns.char.duels
  for i = #list, math.max(1, #list - 20), -1 do
    if list[i].id == id and list[i].result ~= "void" then return list[i] end
  end
end

local function applyDR(rec, sender, f)
  if not sameFull(sender, oppFull(rec)) then return false end
  local hp = tonumber(f[4])
  if hp and not rec.opp.hpEnd then rec.opp.hpEnd = hp end
  if rec.confirmed ~= "self" then return true end
  if D.Short(f[2]) == D.Short(winnerOf(rec)) then
    rec.confirmed = "both"
    changed(rec)
  else
    rec.confirmed = "disputed"
    D.RecomputeStreaks()
    changed(rec)
  end
  return true
end

local function stash(list, sender, f)
  local now = GetTime()
  for i = #list, 1, -1 do if now - list[i].at > STASH_TTL then table.remove(list, i) end end
  table.insert(list, { sender = sender, f = f, at = now })
  while #list > 8 do table.remove(list, 1) end
end

local function onResult(sender, f)
  touchPeer(sender)
  local rec = f[1] and findById(f[1])
  if rec then applyDR(rec, sender, f) else stash(earlyDR, sender, f) end
end

---------------------------------------------------------------------------
-- Referee verdicts

local function isReferee(sender)
  for name in pairs(A.db.referees) do
    if sameFull(name, sender) then return true end
  end
  local host = ns.Ring and ns.Ring.session and ns.Ring.session.host
  return host ~= nil and sameFull(host, sender)
end

local function applyDV(rec, sender, f)
  local winner, loser = D.Short(f[2]), D.Short(f[3])
  local me, opp = myName(), D.Short(rec.opp.name)
  if not (winner and loser and opp) then return false end
  if not ((winner == me and loser == opp) or (winner == opp and loser == me)) then return false end
  if math.abs(U.ServerTime() - (rec.t or 0)) > VERDICT_WINDOW then return false end
  if f[1] and f[1] ~= "" and rec.id and f[1] ~= rec.id then return false end
  local result = winner == me and "win" or "loss"
  local flipped = rec.result ~= result
  rec.result = result
  if rec.how == "unknown" or rec.how == "timeout" then rec.how = "referee" end
  rec.comeback = (result == "win" and rec.me.minHp ~= nil and rec.me.minHp < 20) or false
  rec.confirmed, rec.referee = "referee", sender
  D.RecomputeStreaks()
  changed(rec, { referee = sender, result = rec.result, flipped = flipped or nil })
  return true
end

local function findForVerdict(f)
  local list = ns.char.duels
  for i = #list, math.max(1, #list - 20), -1 do
    local rec = list[i]
    if rec.opp and rec.opp.name and rec.confirmed ~= "referee" then
      local winner, loser = D.Short(f[2]), D.Short(f[3])
      local me, opp = myName(), D.Short(rec.opp.name)
      if (winner == me and loser == opp) or (winner == opp and loser == me) then return rec end
    end
  end
end

local function onVerdict(sender, f)
  touchPeer(sender)
  if not isReferee(sender) then return end
  local me = myName()
  if D.Short(f[2]) == me and D.Short(f[3]) == me then return end
  if D.Short(sender) == me then return end
  local rec = findForVerdict(f)
  if rec then
    if sameFull(sender, oppFull(rec)) then return end -- a fighter cannot referee their own duel
    applyDV(rec, sender, f)
  else
    stash(earlyDV, sender, f)
  end
end

---------------------------------------------------------------------------
-- Resolution hook + wiring

local function drain(list, fn)
  for i = #list, 1, -1 do
    local e = list[i]
    if GetTime() - e.at > STASH_TTL or fn(e) then table.remove(list, i) end
  end
end

A:Listen("DUEL_RESOLVED", function(rec)
  if rec.result == "void" then
    drain(earlyDV, function(e) return findForVerdict(e.f) == rec and applyDV(rec, e.sender, e.f) end)
    return
  end
  send("DR", { rec.id, winnerOf(rec) or "", rec.how or "", rec.me.hpEnd or "" }, oppFull(rec))
  drain(earlyDR, function(e) return e.f[1] == rec.id and applyDR(rec, e.sender, e.f) end)
  drain(earlyDV, function(e) return findForVerdict(e.f) == rec and applyDV(rec, e.sender, e.f) end)
end)

function C.OnLogin()
  if not ns.comm then return end
  ns.comm:On("DH", function(sender, f) onHello(sender, f or {}) end)
  ns.comm:On("DR", function(sender, f) onResult(sender, f or {}) end)
  ns.comm:On("DV", function(sender, f) onVerdict(sender, f or {}) end)
end

local M = A:NewModule("Confirm")
function M:OnLogin() C.OnLogin() end
