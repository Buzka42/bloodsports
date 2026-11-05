-- Safe API access under Midnight-family restrictions: secret values become nil, errors become nil.
-- Rule for every module: read unit/aura/chat values only through these helpers, never compare a raw value
-- that might be secret, never use one as a table key.

if MetaKit_SkipLoad then return end
local MK = MetaKit

local isSecret = issecretvalue or function() return false end
local canAccess = canaccessvalue or function() return true end

function MK.IsSecret(v)
  return isSecret(v) or not canAccess(v)
end

-- Returns v, or nil if it is secret.
function MK.Safe(v)
  if v == nil or MK.IsSecret(v) then return nil end
  return v
end

local function clean(ok, ...)
  if not ok then return end
  local n = select("#", ...)
  if n == 0 then return end
  local out = { ... }
  for i = 1, n do
    if out[i] ~= nil and MK.IsSecret(out[i]) then out[i] = nil end
  end
  return unpack(out, 1, n)
end

-- pcall(fn, ...) with every secret return replaced by nil. Missing fn returns nothing.
function MK.Call(fn, ...)
  if type(fn) ~= "function" then return end
  return clean(pcall(fn, ...))
end

function MK.InCombat()
  return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and MK.Call(UnitAffectingCombat, "player")) or false
end

-- inInstance (bool), instanceType ("none"|"party"|"raid"|"pvp"|"arena"|"scenario"), instanceID
function MK.InstanceState()
  local inInstance, instanceType = MK.Call(IsInInstance)
  local instanceID = select(8, MK.Call(GetInstanceInfo))
  return inInstance or false, instanceType or "none", instanceID
end

-- True when chat/addon messaging is locked down (secret chat, no addon sends).
function MK.ChatLocked()
  local fn = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
  return fn and MK.Call(fn) or false
end

-- Safe snapshot of a unit. Fields are nil when unreadable. class/race are English tokens.
function MK.UnitInfo(unit)
  if not MK.Call(UnitExists, unit) then return nil end
  local info = {}
  info.name, info.realm = MK.Call(UnitName, unit)
  if info.realm == "" then info.realm = nil end
  info.className, info.class = MK.Call(UnitClass, unit)
  info.raceName, info.race = MK.Call(UnitRace, unit)
  info.level = MK.Call(UnitLevel, unit)
  info.guid = MK.Call(UnitGUID, unit)
  info.faction = MK.Call(UnitFactionGroup, unit)
  info.isPlayer = MK.Call(UnitIsPlayer, unit)
  info.classification = MK.Call(UnitClassification, unit)
  return info
end

-- Health percent 0-100 or nil when secret/unavailable. Uses health/max when readable (unambiguous); otherwise
-- UnitHealthPercent, whose scale on Forever is unconfirmed: MK.healthPctScale is 1 for a 0-1 result, 100 for 0-100
-- (default 1 per the 12.x docs; MetaProbe's unit samples settle it).
MK.healthPctScale = 1
function MK.HealthPct(unit)
  local hp, max = MK.Call(UnitHealth, unit), MK.Call(UnitHealthMax, unit)
  if type(hp) == "number" and type(max) == "number" and max > 0 then return hp / max * 100 end
  if UnitHealthPercent then
    local pct = MK.Call(UnitHealthPercent, unit)
    if type(pct) == "number" then return MK.healthPctScale == 1 and pct * 100 or pct end
  end
end

local function squash(s) return (s:gsub("%s", "")) end

-- Player identity. WoW Forever puts a 2-part character's surname in UnitFullName's realm slot
-- (("Chad","Gippity") on realm "CAMWOWEU4Realm2PvP"): a slot matching no readable realm form is a surname.
-- Returns name, realm, comm ("Name-Slot", how WoW itself names the player in addon-message senders), resolved.
-- resolved is false while the player name or both realm APIs are unreadable (load time, secret scrub): the slot
-- can then be neither a surname nor a realm, so realm is nil and callers must not persist name/realm.
local function identity()
  local first, slot = MK.Call(UnitFullName, "player")
  first = first or MK.Call(UnitName, "player")
  if slot == "" then slot = nil end
  local norm, label = MK.Call(GetNormalizedRealmName), MK.Call(GetRealmName)
  local realm = norm or label
  local comm = (first or "Unknown") .. "-" .. (slot or realm or "Realm")
  if not first or not realm then return first or "Unknown", nil, comm, false end
  if slot and squash(slot) ~= squash(norm or "") and squash(slot) ~= squash(label or "") then
    return first .. " " .. slot, realm, comm, true
  end
  return first, slot or realm, comm, true
end

-- "Name-Realm" for the player (storage / site identity); Name may be "First Surname" on Forever.
-- Returns key, name, realm, resolved. Unresolved: key is CommKey (the legacy key, migrated by Char once the
-- identity resolves) and realm is the "Realm" placeholder; never persist either.
function MK.PlayerKey()
  local name, realm, comm, resolved = identity()
  if not resolved then return comm, name, "Realm", false end
  return name .. "-" .. realm, name, realm, true
end

-- The player's own name as WoW reports it to peers (comm sender form); also the pre-surname-fix PlayerKey.
function MK.CommKey()
  local _, _, comm = identity()
  return comm
end

-- True when a (normalized) comm sender is the player.
function MK.IsSelf(sender)
  return sender ~= nil and (sender == MK.CommKey() or sender == (MK.PlayerKey()))
end

-- Normalizes "Name" or "Name-Realm" to "Name-Realm" using the player's realm.
function MK.FullName(name)
  if not name or name == "" then return nil end
  if name:find("-", 1, true) then return name end
  local _, _, realm, resolved = MK.PlayerKey()
  if not resolved then realm = MK.CommKey():match("%-(.*)$") end -- the slot, as WoW names same-realm peers
  return name .. "-" .. realm
end

-- Ruleset/realm label used to split data on the site (what GetRealmName returns on Forever).
function MK.Ruleset()
  return MK.Call(GetRealmName) or "?"
end
