-- Outbox: append-only rows the Meta Uploader ships to the site.
--
--   A:Push("rating", { bracket = 2, pve = 4, pvp = 3 })
--
-- Rows carry a monotonically increasing seq. The uploader cannot edit SavedVariables (the client
-- overwrites the file at logout), so acknowledgements come back through WorldOfMetaData.acked[addon][installId];
-- A:CompactOutbox() drops acked rows on login. Unacked rows are capped so the file never grows unbounded.

if MetaKit_SkipLoad then return end
local MK = MetaKit
local Addon = MK.AddonMethods
local U = MK.Util

local MAX_ROWS = 3000

function Addon:Push(kind, data)
  local box = self.db.outbox
  box.seq = box.seq + 1
  local row = { seq = box.seq, t = U.ServerTime(), kind = kind, char = self.charKey, data = data }
  table.insert(box.rows, row)
  while #box.rows > MAX_ROWS do table.remove(box.rows, 1) end
  self:Fire("OUTBOX_PUSH", row)
  return box.seq
end

-- Highest seq the site has confirmed for this install, from the downloaded data addon.
function Addon:AckedSeq()
  local acked = MK.Wom("acked", self.name, self.db.installId)
  return type(acked) == "number" and acked or 0
end

function Addon:CompactOutbox()
  local acked = self:AckedSeq()
  if acked <= 0 then return 0 end
  local rows, kept = self.db.outbox.rows, {}
  for _, row in ipairs(rows) do
    if row.seq > acked then table.insert(kept, row) end
  end
  local dropped = #rows - #kept
  self.db.outbox.rows = kept
  return dropped
end

function Addon:PendingCount()
  return #self.db.outbox.rows
end

---------------------------------------------------------------------------
-- WorldOfMetaData: table written by the uploader into the WorldOfMeta_Data addon (read-only here).

-- MK.Wom("bloodsports", "champions", "tram") -> value or nil, walking the path safely.
function MK.Wom(...)
  local node = _G.WorldOfMetaData
  for i = 1, select("#", ...) do
    if type(node) ~= "table" then return nil end
    node = node[select(i, ...)]
  end
  return node
end

-- Age of the downloaded data in seconds, or nil when there is no data addon.
function MK.WomAge()
  local at = MK.Wom("generatedAt")
  if type(at) ~= "number" then return nil end
  return U.ServerTime() - at
end
