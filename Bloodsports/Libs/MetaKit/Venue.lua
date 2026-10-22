-- Venue registry: matches the player's position (instance, map coordinates, subzone text) against data rows.

if MetaKit_SkipLoad then return end
local MK = MetaKit

local Venue = {}
Venue.__index = Venue
MK.Venue = { Methods = Venue }

function MK.Venue.New(rows)
  local self = setmetatable({ rows = rows or {}, byId = {} }, Venue)
  for _, row in ipairs(self.rows) do if row.id then self.byId[row.id] = row end end
  return self
end

function Venue:Get(id) return self.byId[id] end

function Venue:All(kind)
  local out = {}
  for _, row in ipairs(self.rows) do
    if not kind or row.kind == kind then out[#out + 1] = row end
  end
  return out
end

-- Safe position snapshot: { mapID, x, y, zone, sub, instanceID } (nil fields when unreadable).
function Venue:Snapshot()
  local snap = {}
  local mapID = MK.Call(C_Map and C_Map.GetBestMapForUnit, "player")
  snap.mapID = mapID
  if mapID then
    local pos = MK.Call(C_Map.GetPlayerMapPosition, mapID, "player")
    if type(pos) == "table" then
      local ok, x, y = pcall(pos.GetXY, pos)
      if ok and type(x) == "number" and type(y) == "number" then snap.x, snap.y = x, y end
    end
  end
  snap.zone = MK.Call(GetRealZoneText)
  snap.sub = MK.Call(GetSubZoneText)
  local inInstance, _, instanceID = MK.InstanceState()
  if inInstance then snap.instanceID = instanceID end
  return snap
end

function Venue:Match()
  local s = self:Snapshot()
  if s.instanceID then
    for _, row in ipairs(self.rows) do
      if row.instanceMapID and row.instanceMapID == s.instanceID then return row end
    end
  end
  if s.mapID and s.x then
    local best, bestD
    for _, row in ipairs(self.rows) do
      if row.mapID == s.mapID and row.x and row.y and row.r then
        local d = math.sqrt((row.x - s.x) ^ 2 + (row.y - s.y) ^ 2)
        if d <= row.r and (not bestD or d < bestD) then best, bestD = row, d end
      end
    end
    if best then return best end
  end
  if s.sub and s.sub ~= "" then
    for _, row in ipairs(self.rows) do
      if row.subzone and row.subzone == s.sub and (row.mapID == nil or row.mapID == s.mapID) then return row end
    end
  end
end

-- Current venue row or nil; cached for 1 s.
function Venue:Current()
  local now = GetTime()
  if self.cachedAt and now - self.cachedAt < 1 then return self.cached end
  self.cached, self.cachedAt = self:Match(), now
  return self.cached
end

function Venue:Invalidate() self.cachedAt = nil end
