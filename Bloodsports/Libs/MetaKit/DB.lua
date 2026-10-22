-- SavedVariables: ensure-shape defaults, ordered migrations, per-character records with a random id.
--
--   function A:OnInit()
--     self:InitDB("EldersDB", DEFAULTS, MIGRATIONS, CHAR_DEFAULTS)
--   end
--   local char = A:Char()   -- current character record (created on first call)
--
-- Never trust that the DB was read back (Forever beta bug): an empty table is a valid first run.

if MetaKit_SkipLoad then return end
local MK = MetaKit
local Addon = MK.AddonMethods

local U = MK.Util

local base = {
  dbVersion = 0,
  installId = false,
  config = { debug = false, sound = true, minimap = { angle = 200, hide = false }, windows = {} },
  outbox = { seq = 0, rows = {} },
  chars = {},
}

-- migrations: array of function(db); migration i runs once when db.dbVersion < i.
local function InitDB(A, globalName, defaults, migrations, charDefaults)
  local db = _G[globalName]
  if type(db) ~= "table" then
    db = {}
    _G[globalName] = db
    A.freshDB = true
  end
  U.EnsureShape(db, base)
  if defaults then U.EnsureShape(db, defaults) end
  if not db.installId then db.installId = U.RandomHex(16) end
  for i, migrate in ipairs(migrations or {}) do
    if db.dbVersion < i then
      local ok, err = pcall(migrate, db)
      if not ok then A:Error("migration " .. i, err) break end
      db.dbVersion = i
    end
  end
  A.db = db
  A.charDefaults = charDefaults or {}
  return db
end

-- Current character record. Identity fields are refreshed on every call that has them readable.
local function Char(A)
  local key, name, realm = MK.PlayerKey()
  local chars = A.db.chars
  local c = chars[key]
  if not c then
    c = { id = U.RandomHex(32), created = U.ServerTime() }
    chars[key] = c
  end
  U.EnsureShape(c, A.charDefaults)
  c.name, c.realm, c.ruleset = name, realm, MK.Ruleset()
  local _, class = MK.Call(UnitClass, "player")
  local _, race = MK.Call(UnitRace, "player")
  c.class = class or c.class
  c.race = race or c.race
  c.faction = MK.Call(UnitFactionGroup, "player") or c.faction
  c.level = MK.Call(UnitLevel, "player") or c.level
  c.lastSeen = U.ServerTime()
  A.charKey = key
  return c, key
end

Addon.InitDB = InitDB
Addon.Char = Char
