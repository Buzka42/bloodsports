-- Finder: find opponents/referees through the hidden lobby channel and bring them to your layer with a party invite.
-- CONTRACT NOTE: List() exempts kinds "ring" AND "ref" from the same-faction filter (referees serve rings, which are
-- cross-faction). Finder.Referees() = List("ref"). Finder.IsLooking()/Looking() expose the own listing.

local _, ns = ...
local MK = MetaKit
local U = MK.Util
local A = ns.A

local M = A:NewModule("Finder")
local Finder = {}
ns.Finder = Finder

local KINDS = { duel = true, club = true, ring = true, ref = true }
local VENUE_KIND = { practice = "duel", club = "club" } -- venue kind -> listing kind for auto-list
local INVITE_DEDUPE = 3 -- seconds

local looking      -- { kind, venue, note, auto }
local lastMsg = {} -- ["kind:sender"] = GetTime()

local function clean(s, max)
  s = tostring(s == nil and "" or s):gsub("[%c|]", "")
  return U.Truncate(s, max or 60)
end

local function cleanVenue(s)
  s = tostring(s == nil and "" or s)
  return s:match("^[%w_]+$") and U.Truncate(s, 24) or ""
end

local function myFaction()
  return MK.Call(UnitFactionGroup, "player")
end

local function sameFaction(f)
  local mine = myFaction()
  return not mine or f == nil or f == "" or f == "Both" or f == mine
end

local function playerLong()
  return (MK.PlayerKey())
end

---------------------------------------------------------------------------
-- Listing

function Finder.Lobby() return ns.finder end

-- Entries for kind (and venue when given). Same faction only, except rings/referees. Never lists yourself.
function Finder.List(kind, venueId)
  local lobby = ns.finder
  if not lobby then return {} end
  local me = playerLong()
  return lobby:List(function(e)
    if kind and e.kind ~= kind then return false end
    if venueId and venueId ~= "" and e.venue ~= venueId then return false end
    if e.name == me then return false end
    if kind ~= "ring" and kind ~= "ref" and not sameFaction(e.faction) then return false end
    return true
  end)
end

function Finder.Referees() return Finder.List("ref") end

function Finder.Looking() return looking end
function Finder.IsLooking() return looking ~= nil end

local function refereeRating(name)
  local key = MK.PlayerKey()
  local r = MK.Wom("bloodsports", "referees", name or key, "rating")
  if type(r) ~= "number" and (name == nil or name == key) then
    r = MK.Wom("bloodsports", "referees", (select(2, MK.PlayerKey())), "rating")
  end
  return type(r) == "number" and U.Clamp(U.Round(r, 2), 0, 5) or nil
end

function Finder.SetLooking(kind, venueId, note, auto)
  if not KINDS[kind] then return false end
  venueId = cleanVenue(venueId)
  note = clean(note, 60)
  local streak = ns.char and ns.char.streak and ns.char.streak.venue[venueId] or 0
  looking = { kind = kind, venue = venueId, note = note, auto = auto and true or nil }
  if not ns.finder then return false end
  ns.finder:Announce({ kind = kind, venue = venueId, note = note, streak = streak,
    rating = kind == "ref" and refereeRating() or nil })
  A:Fire("LOBBY_UPDATED")
  return true
end

function Finder.StopLooking()
  if not looking then return false end
  looking = nil
  if ns.finder then ns.finder:Unlist() end
  A:Fire("LOBBY_UPDATED")
  return true
end

-- Ask the lobby who is out there (replies arrive as whispers and fire LOBBY_UPDATED).
function Finder.Refresh(kind, venueId)
  if ns.finder then return ns.finder:Query(kind, venueId) end
  return false
end

---------------------------------------------------------------------------
-- Layer join: party invite + context whisper

local function validName(name)
  if type(name) ~= "string" or name == "" or #name > 60 then return nil end
  if name:find("[%c|%s]") then return nil end
  return name
end

-- Call from a button click only (InviteUnit is protected without a hardware event).
function Finder.Invite(name, context)
  name = validName(name)
  if not name then return false end
  context = type(context) == "table" and context or {}
  local kind = KINDS[context.kind] and context.kind or "duel"
  local invited = false
  if C_PartyInfo and C_PartyInfo.InviteUnit then
    invited = pcall(C_PartyInfo.InviteUnit, name)
  elseif InviteUnit then
    invited = pcall(InviteUnit, name)
  end
  if ns.comm then
    ns.comm:Send("LI", { kind, cleanVenue(context.venue), clean(context.note, 60) }, "WHISPER", name)
  end
  return invited
end

function Finder.RequestInvite(name, kind, venueId, note)
  name = validName(name)
  if not name or not ns.comm then return false end
  if not KINDS[kind] then kind = "duel" end
  return ns.comm:Send("LR", { kind, cleanVenue(venueId), clean(note, 60) }, "WHISPER", name)
end

local function incoming(tag, msg)
  return function(sender, f)
    local now = GetTime()
    local key = tag .. ":" .. sender
    if lastMsg[key] and now - lastMsg[key] < INVITE_DEDUPE then return end
    lastMsg[key] = now
    local kind = KINDS[f[1]] and f[1] or "duel"
    A:Fire(msg, sender, kind, cleanVenue(f[2]), clean(f[3], 60))
  end
end

---------------------------------------------------------------------------
-- Referee bookkeeping, auto-list, availability

local function trackReferees()
  local lobby = ns.finder
  if not lobby then return end
  local now = U.ServerTime()
  for name, e in pairs(lobby.entries) do
    if e.kind == "ref" and type(name) == "string" then
      local rec = A.db.referees[name]
      if not rec then
        rec = {}
        A.db.referees[name] = rec
      end
      rec.seen = now
      rec.rating = type(e.rating) == "number" and U.Clamp(e.rating, 0, 5) or rec.rating
    end
  end
end

local function currentRingVenue()
  local v = ns.venues and ns.venues:Current()
  return v and v.kind == "ring" and v.id or ""
end

local function applyReferee(on)
  if on then
    Finder.SetLooking("ref", currentRingVenue(), "")
  elseif looking and looking.kind == "ref" then
    Finder.StopLooking()
  end
end

-- Auto-list at practice/club venues; stop when leaving. Only touches listings this function created.
local function checkVenue()
  if not (A.db and A.db.config.finder.autoListAtVenue) then
    if looking and looking.auto then Finder.StopLooking() end
    return
  end
  local v = ns.venues and ns.venues:Current()
  local kind = v and VENUE_KIND[v.kind]
  if kind then
    if not looking or (looking.auto and (looking.venue ~= v.id or looking.kind ~= kind)) then
      Finder.SetLooking(kind, v.id, "", true)
    end
  elseif looking and looking.auto then
    Finder.StopLooking()
  end
  -- A referee listing follows the ring venue the referee is standing in.
  if looking and looking.kind == "ref" and looking.venue ~= currentRingVenue() then
    Finder.SetLooking("ref", currentRingVenue(), looking.note)
  end
end
Finder.CheckVenue = checkVenue

function M:OnLogin()
  if MK.Lobby and ns.comm then
    ns.finder = MK.Lobby.New(ns.comm, { channel = "WoMLobby" })
  end
  if ns.comm then
    ns.comm:On("LI", incoming("LI", "FINDER_INVITED"))
    ns.comm:On("LR", incoming("LR", "FINDER_REQUEST"))
  end
  A:Listen("LOBBY_UPDATED", trackReferees)
  A:Listen("REFEREE_AVAILABILITY", applyReferee)
  for _, ev in ipairs({ "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD" }) do
    A:On(ev, function() A:Debounce("finderVenue", 1, checkVenue) end)
  end
  A:Every(5, checkVenue) -- coordinate-box venues have no zone event
  if A.db.config.referee.available then A:After(8, function() applyReferee(true) end) end
end
