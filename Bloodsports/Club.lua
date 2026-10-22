-- Club: fight-club champions (per class per faction), win streaks with the distinct-opponent rule, challenges.
-- CONTRACT NOTE: MyStreak counts only wins confirmed "both" or "referee" (self-reported wins neither count nor break
-- the streak; losses always break it; voids/disputed are skipped). Max 2 counted wins per opponent per UTC day.
-- A claim (no champion yet) is a challenge record with champion = "" and claim = true; nothing is whispered.

local _, ns = ...
local MK = MetaKit
local U = MK.Util
local A = ns.A

local M = A:NewModule("Club")
local Club = {}
ns.Club = Club

Club.STREAK_NEEDED = 10
Club.DEADLINE = 7 * 86400
local WINS_PER_OPP_DAY = 2
local COUNTED = { both = true, referee = true }

local function me() return (MK.PlayerKey()) end

local function shortName(n)
  return type(n) == "string" and (n:match("^([^-]+)") or n) or ""
end

local function playerClassFaction()
  local info = MK.UnitInfo("player") or {}
  return info.class, info.faction
end

---------------------------------------------------------------------------
-- Champions

-- { [faction] = { [class] = { name, streak, since } } } from the site data, or {}.
function Club.Champions(venueId)
  local t = MK.Wom("bloodsports", "champions", venueId)
  return type(t) == "table" and t or {}
end

function Club.Champion(venueId, faction, class)
  local f = Club.Champions(venueId)[faction]
  local c = type(f) == "table" and f[class]
  if type(c) == "table" and type(c.name) == "string" and c.name ~= "" then return c end
end

local function isMe(name)
  return type(name) == "string" and (name == me() or shortName(name) == shortName(me()))
end

---------------------------------------------------------------------------
-- Streak

-- Confirmed consecutive wins at the venue; wins over the same opponent count at most twice per UTC day.
function Club.MyStreak(venueId)
  local streak, perOpp = 0, {}
  for _, d in ipairs(ns.char.duels) do
    if d.venue == venueId and type(d.opp) == "table" then
      if d.result == "loss" then
        streak = 0
      elseif d.result == "win" and COUNTED[d.confirmed] then
        local day = math.floor((tonumber(d.t) or 0) / 86400)
        local key = shortName(d.opp.name) .. "@" .. day
        perOpp[key] = (perOpp[key] or 0) + 1
        if perOpp[key] <= WINS_PER_OPP_DAY then streak = streak + 1 end
      end
    end
  end
  return streak
end

local function openChallengeAt(venueId)
  for _, c in pairs(ns.char.challenges) do
    if c.venue == venueId and c.status == "open" and (tonumber(c.t) or 0) + Club.DEADLINE > U.ServerTime() then
      return c
    end
  end
end

-- ok, reason, champion. reason: "challenge" | "claim" | "streak" | "champion" | "open" | "venue".
function Club.CanChallenge(venueId)
  local v = ns.venues and ns.venues:Get(venueId)
  if not v or v.kind ~= "club" then return false, "venue" end
  if Club.MyStreak(venueId) < Club.STREAK_NEEDED then return false, "streak" end
  local class, faction = playerClassFaction()
  if not class or not faction then return false, "venue" end
  if openChallengeAt(venueId) then return false, "open" end
  local champ = Club.Champion(venueId, faction, class)
  if not champ then return true, "claim" end
  if isMe(champ.name) then return false, "champion", champ end
  return true, "challenge", champ
end

---------------------------------------------------------------------------
-- Challenges

function Club.Challenge(venueId)
  local ok, reason, champ = Club.CanChallenge(venueId)
  if not ok then return nil, reason end
  local class, faction = playerClassFaction()
  local rec = {
    id = U.RandomHex(12), venue = venueId, champion = champ and champ.name or "", class = class,
    faction = faction, t = U.ServerTime(), status = "open", claim = (not champ) or nil,
  }
  ns.char.challenges[rec.id] = rec
  A:Push("challenge", rec)
  if champ and ns.comm then
    ns.comm:Send("CC", { rec.id, venueId, class }, "WHISPER", champ.name)
  end
  A:Fire("CLUB_UPDATED")
  return rec
end

-- Mine + site challenges (site wins on status), newest first, with deadline / remaining / expired.
function Club.Challenges()
  local byId, now = {}, U.ServerTime()
  for id, c in pairs(ns.char.challenges) do byId[id] = U.Copy(c) end
  local site = MK.Wom("bloodsports", "challenges")
  if type(site) == "table" then
    for _, c in ipairs(site) do
      if type(c) == "table" and type(c.id) == "string" and type(c.t) == "number" then
        local row = byId[c.id] or {}
        for k, v in pairs(c) do
          if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then row[k] = v end
        end
        row.fromSite = true
        byId[c.id] = row
      end
    end
  end
  local out = {}
  for _, c in pairs(byId) do
    c.deadline = (tonumber(c.t) or 0) + Club.DEADLINE
    c.remaining = c.deadline - now
    c.expired = c.status == "open" and c.remaining <= 0
    out[#out + 1] = c
  end
  table.sort(out, function(a, b)
    if a.t ~= b.t then return a.t > b.t end
    return tostring(a.id) < tostring(b.id)
  end)
  return out
end

-- Challenges where I am the champion (received via CC this session or listed on the site).
function Club.Incoming()
  local out = {}
  for _, c in ipairs(Club.Challenges()) do
    if isMe(c.champion) then out[#out + 1] = c end
  end
  return out
end

---------------------------------------------------------------------------
-- Messages

local function onChallenged(sender, f)
  local id, venue = f[1] or "", f[2] or ""
  if not id:match("^%x+$") or #id > 16 or not venue:match("^[%w_]+$") or #venue > 24 then return end
  local v = ns.venues and ns.venues:Get(venue)
  if ns.venues and (not v or v.kind ~= "club") then return end
  A:Fire("CLUB_CHALLENGED", sender, venue)
end

-- A resolved duel against the champion closes my open challenge.
local function onDuel(rec)
  if type(rec) ~= "table" or type(rec.opp) ~= "table" or rec.result == "void" then return end
  for _, c in pairs(ns.char.challenges) do
    if c.status == "open" and c.venue == rec.venue and c.champion ~= ""
        and shortName(c.champion) == shortName(rec.opp.name) then
      c.status = rec.result == "win" and "won" or "lost"
      c.resolvedAt = U.ServerTime()
      A:Push("challenge", c)
    end
  end
  A:Fire("CLUB_UPDATED")
end

function M:OnLogin()
  if ns.comm then ns.comm:On("CC", onChallenged) end
  A:Listen("DUEL_RESOLVED", onDuel)
  A:Listen("DUEL_CONFIRMED", function() A:Fire("CLUB_UPDATED") end)
end
