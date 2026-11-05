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

-- Record for an unresolved identity: the one already in use this session, the stored record whose comm form
-- matches (exact key, saved comm, or a unique "First Surname" name), else nil.
local function findUnresolved(A, chars, comm)
  if A.charKey and chars[A.charKey] then return A.charKey end
  if chars[comm] then return comm end
  local first, slot = comm:match("^([^-]*)%-(.*)$")
  local hit
  for k, c in pairs(chars) do
    if type(c) == "table" and (c.comm == comm or (first and c.name == first .. " " .. slot)) then
      if hit then return nil end -- ambiguous: never guess between characters
      hit = k
    end
  end
  return hit
end

-- Current character record. Identity fields (name/realm/key) are written only from a resolved identity; until
-- then the record is found by its comm form or created under CommKey, and migrated on the first resolved call.
local function Char(A)
  local key, name, realm, resolved = MK.PlayerKey()
  local chars = A.db.chars
  local comm = MK.CommKey()
  if not resolved then
    key = findUnresolved(A, chars, comm) or comm
  elseif comm ~= key and chars[comm] and not chars[key] then
    chars[key], chars[comm] = chars[comm], nil -- surname fix: keep the record (and its id) under the new key
  end
  local c = chars[key]
  if not c then
    c = { id = U.RandomHex(32), created = U.ServerTime() }
    chars[key] = c
    if not resolved then c.name, c.unresolved = name, true end
  end
  U.EnsureShape(c, A.charDefaults)
  if resolved then
    c.name, c.realm, c.comm, c.unresolved = name, realm, comm, nil
  end
  c.ruleset = MK.Call(GetRealmName) or c.ruleset or "?"
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
