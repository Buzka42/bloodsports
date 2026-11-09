-- MetaKit Ext: the public extension registry of World of Meta addons (Elders, Bloodsports).
-- Other addons register new pieces here instead of patching ours. Full guide: docs/ADDON_API.md.
--
--   MK.Ext.VERSION                      integer, bumped only for breaking changes (see ADDON_API.md, versioning)
--   MK.Ext.Register(kind, id, def)  -> true | false, message      never raises
--   MK.Ext.Get(kind, id)            -> info | nil                  { kind, id, owner, def }
--   MK.Ext.List(kind)               -> { id, ... } sorted          nil, message for an unknown kind
--   MK.Ext.Kinds()                  -> { "market", "narrator", "row", "section" }
--   MK.Ext.Compatible(minVersion)   -> boolean
--
-- Kinds and their `def`:
--   "market"   a Ring market type.  { label = "First blood", outcomes = {"Yes","No"} | function(ctx) -> labels,
--                lockOn = "fight"|"manual"|"time" (default "manual"), scope = "fight"|"series" (default "fight"),
--                settle = function(market, event) -> outcomeIndex | false | nil   (optional; no settle = host settles by hand),
--                owner = "MyAddon" }
--              Hosts call MK.Ext.BuildOutcomes(id, ctx) and MK.Ext.Settle(id, market, event); both are pcall-guarded
--              and validate what the extension returned.
--   "section"  a pane in the shared World of Meta window.  { tab = "bloodsports"|"elders"|<your tab>, label = "...",
--                build = function(parent) -> frame, order = 50, icon = path, onShow = function(frame, shell, sec),
--                owner = "MyAddon" }   Forwarded to MK.UI.RegisterSharedSection.
--   "row"      an outbox row kind.  { fields = { name = "string"|"number"|"boolean", ... }, owner = "MyAddon" }
--              Push with MK.Ext.PushRow(addon, id, data); the row is validated, then Addon:Push(id, data) runs.
--   "narrator" a line provider.  function(category, ctx) -> { "line", ... } | nil, or
--              { lines = function(category, ctx) ..., categories = { "kill", ... } (optional filter), owner = "..." }.
--              Hosts call MK.Ext.NarratorLines(category, ctx).
--
-- ids: lowercase letters, digits and underscore, starting with a letter, up to 24 chars. Unique per kind.

if MetaKit_SkipLoad then return end
local MK = MetaKit

local Ext = { VERSION = 1 }
MK.Ext = Ext

-- Mirrors the Ring limits (Bloodsports/Ring.lua MAX_OUTCOMES, LABEL_MAX). Extensions can read them; they do not change within a VERSION.
Ext.LIMITS = { ID_MAX = 24, MAX_OUTCOMES = 8, LABEL_MAX = 24, STRING_MAX = 200, LINE_MAX = 255, LINES_PER_PROVIDER = 8 }
local L = Ext.LIMITS

local KINDS = { market = true, section = true, row = true, narrator = true }
local LOCK_ON = { fight = true, manual = true, time = true }
local SCOPES = { fight = true, series = true }
local FIELD_TYPES = { string = true, number = true, boolean = true }
-- Row kinds the addons already push; an extension cannot reuse them.
local RESERVED_ROWS = { bet = true, challenge = true, duel = true, duel_confirm = true, insight = true, levelup = true,
  link = true, rating = true, ring = true, vote = true }

local store = { market = {}, section = {}, row = {}, narrator = {} }

local function validId(id)
  return type(id) == "string" and #id <= L.ID_MAX and id:match("^[a-z][a-z0-9_]*$") ~= nil
end

local function ownerOf(def)
  return type(def) == "table" and type(def.owner) == "string" and def.owner or "?"
end

local function truncate(s, n)
  return #s > n and s:sub(1, n) or s
end

---------------------------------------------------------------------------
-- Per-kind validation. Each returns the normalised definition, or nil and a message.

local function checkOutcomeList(list)
  if type(list) ~= "table" then return nil, "outcomes must be a table of labels or a function" end
  if #list < 2 or #list > L.MAX_OUTCOMES then
    return nil, "outcomes needs 2 to " .. L.MAX_OUTCOMES .. " labels"
  end
  for i = 1, #list do
    local o = list[i]
    if type(o) == "table" then o = o.label end
    if type(o) ~= "string" or o == "" then return nil, "outcome " .. i .. " has no label" end
  end
  return list
end

local function checkMarket(id, def)
  if type(def) ~= "table" then return nil, "market def must be a table" end
  if type(def.label) ~= "string" or def.label == "" then return nil, "market needs a label" end
  if type(def.outcomes) ~= "function" then
    local ok, err = checkOutcomeList(def.outcomes)
    if not ok then return nil, err end
  end
  if def.settle ~= nil and type(def.settle) ~= "function" then return nil, "settle must be a function" end
  if def.lockOn ~= nil and not LOCK_ON[def.lockOn] then return nil, "lockOn must be fight, manual or time" end
  if def.scope ~= nil and not SCOPES[def.scope] then return nil, "scope must be fight or series" end
  return def
end

-- A section may not replace a section something else already put in the shell (that is how a core pane would be lost).
local function sectionTaken(tab, id)
  local UI = MK.UI
  local function scan(list)
    for _, s in ipairs(list or {}) do
      if s.id == id and (s.tab == tab or s.tab == nil) then return true end
    end
    return false
  end
  local shell = UI._sharedShell
  if shell and shell.sections and scan(shell.sections[tab]) then return true end
  local queued = UI._sharedState and UI._sharedState.sections
  if queued then
    for _, s in ipairs(queued) do if s.tab == tab and s.id == id then return true end end
  end
  return false
end

local function checkSection(id, def)
  if type(def) ~= "table" then return nil, "section def must be a table" end
  if type(def.tab) ~= "string" or def.tab == "" then return nil, "section needs a tab id" end
  if type(def.label) ~= "string" or def.label == "" then return nil, "section needs a label" end
  if type(def.build) ~= "function" then return nil, "section needs build(parent)" end
  if def.onShow ~= nil and type(def.onShow) ~= "function" then return nil, "onShow must be a function" end
  if not (MK.UI and MK.UI.RegisterSharedSection) then return nil, "shared shell not available" end
  if sectionTaken(def.tab, id) then return nil, "tab '" .. def.tab .. "' already has a section '" .. id .. "'" end
  return def
end

local function checkRow(id, def)
  if RESERVED_ROWS[id] then return nil, "row kind '" .. id .. "' is reserved" end
  if type(def) ~= "table" then return nil, "row def must be a table" end
  if type(def.fields) ~= "table" then return nil, "row needs fields = { name = 'string'|'number'|'boolean' }" end
  local n = 0
  for name, ty in pairs(def.fields) do
    if type(name) ~= "string" or not name:match("^[a-z][a-zA-Z0-9_]*$") then return nil, "bad field name" end
    if not FIELD_TYPES[ty] then return nil, "field '" .. name .. "' has unknown type" end
    n = n + 1
  end
  if n == 0 then return nil, "row needs at least one field" end
  return def
end

local function checkNarrator(id, def)
  if type(def) == "function" then return { lines = def } end
  if type(def) ~= "table" or type(def.lines) ~= "function" then return nil, "narrator needs a function or { lines = function }" end
  if def.categories ~= nil then
    if type(def.categories) ~= "table" then return nil, "categories must be a list of strings" end
    for _, c in ipairs(def.categories) do
      if type(c) ~= "string" then return nil, "categories must be a list of strings" end
    end
  end
  return def
end

local CHECK = { market = checkMarket, section = checkSection, row = checkRow, narrator = checkNarrator }

---------------------------------------------------------------------------
-- Public API

function Ext.Register(kind, id, def)
  if not KINDS[kind] then return false, "unknown kind '" .. tostring(kind) .. "'" end
  if not validId(id) then
    return false, "bad id '" .. tostring(id) .. "' (lowercase letters, digits, underscore; starts with a letter; max " .. L.ID_MAX .. ")"
  end
  if store[kind][id] then return false, kind .. " '" .. id .. "' is already registered by " .. store[kind][id].owner end
  local ok, norm, err = pcall(CHECK[kind], id, def)
  if not ok then return false, tostring(norm) end
  if not norm then return false, err end
  if kind == "section" then
    local okReg, res = pcall(MK.UI.RegisterSharedSection, {
      tab = norm.tab, id = id, label = norm.label, order = norm.order or 50, icon = norm.icon,
      build = norm.build, onShow = norm.onShow,
    })
    if not okReg or res == false then return false, "shell refused the section" end
  end
  store[kind][id] = { kind = kind, id = id, owner = ownerOf(def), def = norm }
  return true
end

function Ext.Get(kind, id)
  local t = store[kind]
  return t and t[id] or nil
end

function Ext.List(kind)
  local t = store[kind]
  if not t then return nil, "unknown kind '" .. tostring(kind) .. "'" end
  local out = {}
  for id in pairs(t) do out[#out + 1] = id end
  table.sort(out)
  return out
end

function Ext.Kinds()
  local out = {}
  for k in pairs(KINDS) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function Ext.Compatible(minVersion)
  return type(minVersion) == "number" and Ext.VERSION >= minVersion
end

---------------------------------------------------------------------------
-- Host-side helpers: what Ring / Narrator / the outbox call. Extensions never need them.

-- ctx = { a, b (full fighter names or nil), bo, series, session }. Returns { {label=, ref=}, ... } or nil, message.
function Ext.BuildOutcomes(id, ctx)
  local info = store.market[id]
  if not info then return nil, "no market '" .. tostring(id) .. "'" end
  local raw = info.def.outcomes
  if type(raw) == "function" then
    local ok, res, why = pcall(raw, ctx or {})
    if not ok then return nil, "outcomes() failed: " .. tostring(res) end
    if res == nil then return nil, why or "outcomes() declined" end
    raw = res
  end
  local ok, err = checkOutcomeList(raw)
  if not ok then return nil, err end
  local out = {}
  for i = 1, #raw do
    local o = raw[i]
    local label = type(o) == "table" and o.label or o
    out[i] = { label = truncate(label, L.LABEL_MAX), ref = type(o) == "table" and o.ref or nil }
  end
  return out
end

-- market = { kind, outcomes = {...}, title }, event = { type = "fight_end"|"series_done"|"manual", winner, loser, scoreA, scoreB, ... }.
-- Returns an outcome index, false (void the market) or nil (not decided yet). Invalid answers count as nil.
function Ext.Settle(id, market, event)
  local info = store.market[id]
  if not info or not info.def.settle then return nil end
  local ok, res = pcall(info.def.settle, market or {}, event or {})
  if not ok then return nil, "settle() failed: " .. tostring(res) end
  if res == false then return false end
  local n = market and market.outcomes and #market.outcomes or 0
  if type(res) == "number" and res == math.floor(res) and res >= 1 and res <= n then return res end
  if res ~= nil then return nil, "settle() returned an invalid outcome" end
  return nil
end

-- Validates data against the registered fields, then Addon:Push(id, data). Returns the outbox seq or false, message.
function Ext.PushRow(addon, id, data)
  local info = store.row[id]
  if not info then return false, "row kind '" .. tostring(id) .. "' is not registered" end
  if type(addon) ~= "table" or type(addon.Push) ~= "function" then return false, "addon has no Push" end
  if type(data) ~= "table" then return false, "data must be a table" end
  local clean = {}
  for name, ty in pairs(info.def.fields) do
    local v = data[name]
    if v ~= nil then
      if type(v) ~= ty then return false, "field '" .. name .. "' must be a " .. ty end
      if ty == "number" and (v ~= v or v == math.huge or v == -math.huge) then return false, "field '" .. name .. "' is not finite" end
      if ty == "string" then v = truncate(v, L.STRING_MAX) end
      clean[name] = v
    end
  end
  for name in pairs(data) do
    if info.def.fields[name] == nil then return false, "unknown field '" .. tostring(name) .. "'" end
  end
  return addon:Push(id, clean)
end

-- Collects lines from every narrator for a category, in id order. A broken provider is skipped, never fatal.
function Ext.NarratorLines(category, ctx)
  local out = {}
  for _, id in ipairs(Ext.List("narrator")) do
    local def = store.narrator[id].def
    local wanted = true
    if def.categories then
      wanted = false
      for _, c in ipairs(def.categories) do if c == category then wanted = true end end
    end
    if wanted then
      local ok, lines = pcall(def.lines, category, ctx or {})
      if ok and type(lines) == "table" then
        local n = 0
        for _, line in ipairs(lines) do
          if type(line) == "string" and line ~= "" and n < L.LINES_PER_PROVIDER then
            n = n + 1
            out[#out + 1] = truncate(line, L.LINE_MAX)
          end
        end
      end
    end
  end
  return out
end
