-- Bloodsports core: DB schema, venue registry wiring, slash commands. Feature modules: Duel, Confirm, Stats,
-- Club, Ring, Finder (logic) and UI/*.lua. Modules talk through A:Fire/A:Listen messages listed in IMPLEMENTATION.md.

local ADDON, ns = ...
local MK = MetaKit
local U = MK.Util

local A = MK.NewAddon(ADDON, { color = "d1381f" })
ns.A = A
Bloodsports = A -- global for debugging (/dump Bloodsports.db)

ns.PREFIX = "BSPT"
ns.VERSION = 1

local DEFAULTS = {
  config = {
    card = true, toasts = true, announce = true,
    ring = { enabled = true, currency = "gold" },   -- currency "gold" | "points" (fallback if gold betting gets banned)
    finder = { autoListAtVenue = false },
    referee = { available = false },               -- I'm offering to referee
  },
  peers = {},       -- ["Name-Realm"] = { class, level, version, seen }   addon users met via comm
  referees = {},    -- ["Name-Realm"] = { seen, rating }                 referees heard on the lobby
}

local CHAR_DEFAULTS = {
  duels = {},       -- array of duel records (newest last), capped at MAX_DUELS
  streak = { cur = 0, best = 0, venue = {} },
  challenges = {},  -- [id] = challenge record
  bets = {},        -- array of bet/ring records
  trades = {},      -- array of recorded trades (ring settlement evidence)
}
ns.MAX_DUELS = 1000

local MIGRATIONS = {}

function A:OnInit()
  self:InitDB("BloodsportsDB", DEFAULTS, MIGRATIONS, CHAR_DEFAULTS)
end

-- Rows the matcher may use: active (not dormant) and verified (measured position). See Data/Venues.lua.
local function matchable(rows)
  local out = {}
  for _, v in ipairs(rows) do if not v.dormant and not v.unverified then out[#out + 1] = v end end
  return out
end

function A:OnLogin()
  ns.char = self:Char()
  self:CompactOutbox()
  ns.venues = MK.Venue and MK.Venue.New(matchable(ns.Data and ns.Data.Venues or {})) or nil
  if MK.Comm then ns.comm = MK.Comm.New(self, ns.PREFIX) end
end

-- Appends a duel record, trims history, pushes to the outbox.
function ns.SaveDuel(rec)
  local list = ns.char.duels
  table.insert(list, rec)
  while #list > ns.MAX_DUELS do table.remove(list, 1) end
  A:Push("duel", rec)
end

---------------------------------------------------------------------------
-- Slash commands

A:Slash({ "/bloodsports", "/bs" })
A:Command("", "toggle the main window", function() A:Fire("TOGGLE_MAIN") end)
A:Command("show", "show - toggle the main window", function() A:Fire("TOGGLE_MAIN") end)
A:Command("find", "find - open the opponent finder", function() A:Fire("TOGGLE_MAIN", "finder") end)
A:Command("ring", "ring - open the gambling ring tab", function() A:Fire("TOGGLE_MAIN", "ring") end)
A:Command("referee", "referee on|off - offer yourself as a referee", function(arg)
  A.db.config.referee.available = (arg == "on")
  A:Fire("REFEREE_AVAILABILITY", A.db.config.referee.available)
  A:Print("referee availability " .. (A.db.config.referee.available and "ON" or "OFF"))
end)
A:Command("link", "link CODE - bind this character to your World of Meta account", function(code)
  code = (code or ""):upper():gsub("%s", "")
  if #code ~= 8 or not code:match("^%w+$") then
    A:Print("usage: /bs link CODE (8 letters or digits from the World of Meta site)")
    return
  end
  A:Push("link", { code = code, charId = ns.char.id })
  A:Print("link code stored; sent on next logout or /bs sync.")
end)
A:Command("sync", "sync - reload so the Meta Uploader picks up results", function() ReloadUI() end)
A:Command("venue", "venue - print the venue you are standing in", function()
  local v = ns.venues and ns.venues:Current()
  A:Print(v and (v.name .. " (" .. v.kind .. ")") or "not at a Bloodsports venue")
end)
A:Command("debug", "debug - toggle debug output", function()
  A.db.config.debug = not A.db.config.debug
  A:Print("debug " .. (A.db.config.debug and "on" or "off"))
end)
