-- MetaKit Chat: the one paced sink for public chat lines from World of Meta addons (Bloodsports narration, Elders
-- announcements). Everything an addon wants to say goes through MK.Chat.Say; nothing calls SendChatMessage directly.
--
--   MK.Chat.Configure(db.config.chat)        -- once per addon, at OnInit; fills missing keys, keeps the live table
--   MK.Chat.Say(category, text[, opts])      -> true | false, reason
--   MK.Chat.Reset(category[, scope])         -- a new fight/session: its line budget starts over
--   MK.Chat.Clear(category)                  -- drops queued, unsent lines of a category
--   MK.Chat.Defaults(category[, extra])      -> a full config table for DEFAULTS (config.chat = MK.Chat.Defaults("x"))
--   MK.Chat.Stats() / MK.Chat.Pending() / MK.Chat.Cat(category) / MK.Chat.Wipe()   (Wipe: tests)
--
-- Config table (db.config.chat, shared shape in every addon; the sink merges the tables of all configured addons):
--   interval = 2.5   seconds between two sent lines, across all categories (the largest configured value wins; 1..30)
--   dedupe   = 30    an identical line (same category, route and text) inside this window is dropped
--   cap      = 30    hard cap of accepted lines per (category, scope); scope = opts.scope or "" (one budget per fight/session)
--   queue    = 6     most lines waiting at once; the oldest ordinary line makes room for an `important` one
--   maxAge   = 20    a queued line older than this is stale and dropped, never sent late
--   channelName = "" custom channel for route "channel" (looked up with GetChannelName)
--   blocked  = { pvp = true, arena = true }   instance types that never get a line
--   cats     = { [category] = { on = true, route = "say", ... } }   per-category toggle, route and addon-owned extras
--
-- Routes: say | yell | party | raid | group (instance group > raid > party) | channel | local | off.
-- "local" prints to your own chat frame (no pacing, nothing leaves the client). opts.route overrides the category
-- route for one line; opts.important lets a line evict an older ordinary one when the queue is full.
--
-- Refusal reasons (second return of Say): unknown, off, text, locked, nogroup, nochannel, dupe, cap, full.
-- Locked = MK.ChatLocked() or a blocked instance type: checked when the line is offered AND again when it is due,
-- so a line queued before a lockdown is dropped, never sent. Nothing here reads combat data; text comes from callers.
-- CONTRACT NOTE: SAY / YELL sent from a timer, outside an instance, may be refused by the client (hardware-event rule).
--   The send is pcall'd and counted (Stats().error); players whose client refuses it can pick route "local" or "group".

if MetaKit_SkipLoad then return end
local MK = MetaKit
local U = MK.Util

local Chat = {}
MK.Chat = Chat

local BASE = {
  interval = 2.5, dedupe = 30, cap = 30, queue = 6, maxAge = 20, channelName = "",
  blocked = { pvp = true, arena = true },
}
local ROUTES = { say = true, yell = true, party = true, raid = true, group = true, channel = true, ["local"] = true, off = true }
local CHAT_TYPE = { say = "SAY", yell = "YELL", party = "PARTY", raid = "RAID", channel = "CHANNEL" }
local MAX_LEN, MAX_SCOPES, MAX_RECENT = 255, 32, 64

local cfgs = {}        -- configured per-addon tables, in order
local queue = {}       -- { cat, route, text, t, important, scope, cfg }
local recent = {}      -- [dedupe key] = GetTime() of the accepted line
local counts = {}      -- [cat .. "\1" .. scope] = accepted lines
local nCounts = 0
local lastSend = -1e9
local ticker
local stats = { sent = 0, dropped = {}, error = 0 }

---------------------------------------------------------------------------
-- Config

function Chat.Defaults(cat, extra)
  local t = U.Copy(BASE)
  t.cats = { [cat] = U.EnsureShape(U.Copy(extra or {}), { on = true, route = "say" }) }
  return t
end

-- Registers an addon's chat table (the live saved table; missing keys are filled in place). Idempotent.
function Chat.Configure(cfg)
  if type(cfg) ~= "table" then return nil end
  U.EnsureShape(cfg, BASE)
  if type(cfg.cats) ~= "table" then cfg.cats = {} end
  for _, c in ipairs(cfgs) do if c == cfg then return cfg end end
  cfgs[#cfgs + 1] = cfg
  return cfg
end

-- Category table and its owning config, or nil for an unconfigured category.
function Chat.Cat(cat)
  for i = #cfgs, 1, -1 do
    local c = cfgs[i].cats[cat]
    if type(c) == "table" then return c, cfgs[i] end
  end
end

local function num(v, lo, hi, d)
  v = tonumber(v)
  if not v then return d end
  return U.Clamp(v, lo, hi)
end

local function interval()
  local v = 0
  for _, c in ipairs(cfgs) do v = math.max(v, num(c.interval, 1, 30, BASE.interval)) end
  return v > 0 and v or BASE.interval
end

local function dedupeWindow()
  local v = 0
  for _, c in ipairs(cfgs) do v = math.max(v, num(c.dedupe, 0, 600, BASE.dedupe)) end
  return v
end

function Chat.Wipe()
  cfgs, queue, recent, counts, nCounts, lastSend = {}, {}, {}, {}, 0, -1e9
  stats = { sent = 0, dropped = {}, error = 0 }
  if ticker then ticker:Cancel() ticker = nil end
end

---------------------------------------------------------------------------
-- Text and routes

-- Truncates to n bytes without splitting a UTF-8 sequence.
local function cut(s, n)
  if #s <= n then return s end
  local at = n
  while at > 0 do
    local c = s:byte(at + 1)
    if not c or c < 0x80 or c >= 0xC0 then break end
    at = at - 1
  end
  return s:sub(1, at)
end

-- No pipes (chat escape char), no control characters, single spaces, at most 255 bytes.
local function clean(s)
  s = s:gsub("[%c|]", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
  return cut(s, MAX_LEN)
end

local function inGroup() return MK.Call(IsInGroup) and true or false end

local function inInstanceGroup()
  return LE_PARTY_CATEGORY_INSTANCE ~= nil and MK.Call(IsInGroup, LE_PARTY_CATEGORY_INSTANCE) and true or false
end

-- chatType, target for a route right now, or nil, reason.
local function resolve(route, cfg)
  if route == "group" then
    if inInstanceGroup() then return "INSTANCE_CHAT" end
    if MK.Call(IsInRaid) then return "RAID" end
    if inGroup() then return "PARTY" end
    return nil, "nogroup"
  elseif route == "raid" then
    if MK.Call(IsInRaid) then return "RAID" end
    return nil, "nogroup"
  elseif route == "party" then
    if inGroup() then return "PARTY" end
    return nil, "nogroup"
  elseif route == "channel" then
    local name = cfg and cfg.channelName
    local id = type(name) == "string" and name ~= "" and MK.Call(GetChannelName, name) or nil
    if type(id) == "number" and id > 0 then return "CHANNEL", id end
    return nil, "nochannel"
  end
  return CHAT_TYPE[route]
end

local function locked(cfg)
  if MK.ChatLocked() then return true end
  local _, kind = MK.InstanceState()
  local blocked = cfg and cfg.blocked
  return type(blocked) == "table" and blocked[kind] == true
end

---------------------------------------------------------------------------
-- Delivery

local function drop(reason)
  stats.dropped[reason] = (stats.dropped[reason] or 0) + 1
  return false, reason
end

local function deliver(it)
  if it.route == "local" then
    print(it.text)
    stats.sent = stats.sent + 1
    return true
  end
  local c = Chat.Cat(it.cat)
  if not c or c.on == false then return drop("off") end
  if locked(it.cfg) then return drop("locked") end
  local chatType, target = resolve(it.route, it.cfg)
  if not chatType then return drop(target) end
  local fn = (C_ChatInfo and C_ChatInfo.SendChatMessage) or SendChatMessage
  if type(fn) ~= "function" then return drop("error") end
  local ok = pcall(fn, it.text, chatType, nil, target)
  if not ok then
    stats.error = stats.error + 1
    return drop("error")
  end
  stats.sent = stats.sent + 1
  return true
end

local pump

local function arm()
  if #queue > 0 and not ticker then
    ticker = C_Timer.NewTicker(0.25, function()
      local ok, err = pcall(pump)
      if not ok then Chat.lastError = tostring(err) end
    end)
  elseif #queue == 0 and ticker then
    ticker:Cancel()
    ticker = nil
  end
end

-- Sends at most one due line (stale / locked lines in front of it are dropped without spending the interval).
function pump()
  local now = GetTime()
  while #queue > 0 do
    local it = queue[1]
    if now - it.t > num(it.cfg.maxAge, 1, 600, BASE.maxAge) then
      table.remove(queue, 1)
      drop("stale")
    elseif locked(it.cfg) then
      table.remove(queue, 1)
      drop("locked")
    elseif now - lastSend < interval() then
      break
    else
      table.remove(queue, 1)
      if deliver(it) then lastSend = now end
      break
    end
  end
  arm()
end

---------------------------------------------------------------------------
-- Public API

local function countKey(cat, scope) return cat .. "\1" .. tostring(scope or "") end

local function bumpCount(key)
  if counts[key] == nil then
    if nCounts >= MAX_SCOPES then counts, nCounts = {}, 0 end
    nCounts = nCounts + 1
    counts[key] = 0
  end
  counts[key] = counts[key] + 1
end

local function pruneRecent(now, window)
  local n = 0
  for _ in pairs(recent) do n = n + 1 end
  if n < MAX_RECENT then return end
  for k, t in pairs(recent) do if now - t > window then recent[k] = nil end end
end

function Chat.Say(cat, text, opts)
  opts = type(opts) == "table" and opts or {}
  local c, cfg = Chat.Cat(cat)
  if not c then return drop("unknown") end
  if c.on == false then return drop("off") end
  local route = opts.route or c.route
  if not ROUTES[route] or route == "off" then return drop("off") end
  if type(text) ~= "string" or MK.IsSecret(text) then return drop("text") end
  text = clean(text)
  if text == "" then return drop("text") end
  if route ~= "local" then
    if locked(cfg) then return drop("locked") end
    local chatType, why = resolve(route, cfg)
    if not chatType then return drop(why) end
  end

  local now = GetTime()
  local window = dedupeWindow()
  local key = cat .. "\1" .. route .. "\1" .. text
  if recent[key] and now - recent[key] < window then return drop("dupe") end
  local ck = countKey(cat, opts.scope)
  if (counts[ck] or 0) >= num(cfg.cap, 0, 1000, BASE.cap) then return drop("cap") end

  local it = { cat = cat, route = route, text = text, t = now, important = opts.important and true or false, cfg = cfg }
  if route ~= "local" and #queue >= num(cfg.queue, 1, 50, BASE.queue) then
    local victim
    if it.important then
      for i, q in ipairs(queue) do if not q.important then victim = i break end end
    end
    if not victim then return drop("full") end
    table.remove(queue, victim)
    drop("evicted")
  end

  pruneRecent(now, window)
  recent[key] = now
  bumpCount(ck)
  if route == "local" then
    deliver(it)
    return true
  end
  queue[#queue + 1] = it
  pump()
  return true
end

-- A new fight/session for `cat`: its accepted-line budget starts over (scope nil = the default scope).
function Chat.Reset(cat, scope)
  local ck = countKey(cat, scope)
  if counts[ck] ~= nil then counts[ck] = 0 end
end

function Chat.Clear(cat)
  for i = #queue, 1, -1 do
    if queue[i].cat == cat then table.remove(queue, i) end
  end
  arm()
end

function Chat.Pending() return #queue end

function Chat.Stats()
  local d = {}
  for k, v in pairs(stats.dropped) do d[k] = v end
  return { sent = stats.sent, error = stats.error, dropped = d, pending = #queue }
end
