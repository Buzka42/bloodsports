-- Bloodsports UI helpers: art lookup, formatting, venue lookups, tab registry, combat-safe popups.
-- CONTRACT NOTE: all UI modules guard on ns.UI.Kit() (MetaKit.UI.Window present) and degrade to a chat message.
-- CONTRACT NOTE: the window is flat (kit tokens); no skin art is registered.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A

local UI = {}
ns.UI = UI
UI.SKIN = "bloodsports"
UI.tabDefs = {}   -- id -> build(parent) -> frame, refreshFn

local M = A:NewModule("UITheme")

---------------------------------------------------------------------------
-- Kit / art

function UI.Kit()
  local k = MK.UI
  if k and k.Window then return k end
end

function UI.Art(name)
  local k = MK.UI
  if k and k.Art then return k.Art(ns, name) end
  if ns.Media and ns.Media.has and ns.Media.has[name] then return ns.Media.path .. name end
end

-- Wraps text in an inline colour escape taken from a kit token ("good", "bad", "accent", "muted", "text").
function UI.Tint(token, text)
  local K = MK.UI and MK.UI.Tokens
  local c = K and K[token]
  if not c then return text end
  return string.format("|cff%02x%02x%02x%s|r", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5),
    math.floor(c[3] * 255 + 0.5), text)
end

function UI.Crest(venueId)
  return venueId and UI.Art("crest_" .. venueId) or nil
end

function UI.Color(key, fallback)
  local k = MK.UI
  if k and k.Color then
    local r, g, b, a = k.Color(UI.SKIN, key)
    if r then return r, g, b, a end
  end
  return unpack(fallback or { 0.1, 0.08, 0.08, 0.9 })
end

-- Flat panel (kit tokens: fill, 1 px border) for our own small frames (card, HUD).
function UI.Backdrop(f)
  local k = MK.UI
  if k and k.Backdrop then k.Backdrop(f, "tip", UI.SKIN) end
end

---------------------------------------------------------------------------
-- Formatting

function UI.Short(name)
  if type(name) ~= "string" then return "?" end
  return name:match("^([^-]+)") or name
end

function UI.SameName(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  if a == b then return true end
  local an, ar = a:match("^([^-]+)-?(.*)$")
  local bn, br = b:match("^([^-]+)-?(.*)$")
  return an == bn and (ar == "" or br == "" or ar == br)
end

function UI.ClassName(token)
  local names = LOCALIZED_CLASS_NAMES_MALE
  if names and names[token] then return names[token] end
  if type(token) ~= "string" then return "?" end
  return token:sub(1, 1) .. token:sub(2):lower()
end

function UI.ClassText(token, text)
  local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
  text = text or UI.ClassName(token)
  if c and c.colorStr then return "|c" .. c.colorStr .. text .. "|r" end
  return text
end

-- Age of a timestamp that may be GetTime() or server time.
function UI.Ago(t)
  if type(t) ~= "number" then return "-" end
  local now = t > 1e9 and MK.Util.ServerTime() or GetTime()
  local d = math.max(0, now - t)
  if d < 60 then return math.floor(d) .. "s" end
  if d < 3600 then return math.floor(d / 60) .. "m" end
  return math.floor(d / 3600) .. "h"
end

function UI.Pct(w, n)
  if not n or n <= 0 then return "-" end
  return math.floor(w / n * 100 + 0.5) .. "%"
end

function UI.Currency()
  local r = A.db and A.db.config and A.db.config.ring
  return (r and r.currency) or "gold"
end

function UI.Amount(v, currency)
  v = tonumber(v) or 0
  if (currency or UI.Currency()) == "points" then return v .. " pts" end
  return MK.Util.Money(v)
end

-- "10" typed by the user -> internal amount (copper for gold, raw for points).
function UI.ParseAmount(text, currency)
  local n = tonumber(text)
  if not n or n <= 0 then return nil end
  if (currency or UI.Currency()) == "points" then return math.floor(n) end
  return math.floor(n * 10000)
end

---------------------------------------------------------------------------
-- Data helpers

function UI.Venues(kind)
  local out = {}
  local rows = ns.Data and ns.Data.Venues or {}
  for _, v in ipairs(rows) do
    -- Unverified venues cannot be matched or challenged yet, so players do not see them in pickers.
    if not v.dormant and not v.unverified and (not kind or v.kind == kind) then out[#out + 1] = v end
  end
  return out
end

function UI.VenueName(id)
  if not id or id == "" then return "-" end
  for _, v in ipairs(ns.Data and ns.Data.Venues or {}) do
    if v.id == id then return v.name end
  end
  return id
end

function UI.Duels()
  return ns.char and ns.char.duels or {}
end

-- Groups duels by keyFn(duel) -> { [key] = { n, w, l, dur, durN } }; voids are skipped.
function UI.Tally(duels, keyFn)
  local out = {}
  for _, d in ipairs(duels) do
    local key = keyFn(d)
    if key and (d.result == "win" or d.result == "loss") then
      local t = out[key]
      if not t then t = { n = 0, w = 0, l = 0, dur = 0, durN = 0 }; out[key] = t end
      t.n = t.n + 1
      if d.result == "win" then t.w = t.w + 1 else t.l = t.l + 1 end
      if type(d.dur) == "number" then t.dur = t.dur + d.dur; t.durN = t.durN + 1 end
    end
  end
  return out
end

function UI.AvgDur(t)
  if t.durN > 0 then return MK.Util.Duration(t.dur / t.durN) end
  return "-"
end

-- My wins/losses against one opponent name.
function UI.RecordVs(name)
  local w, l = 0, 0
  for _, d in ipairs(UI.Duels()) do
    if d.opp and UI.SameName(d.opp.name, name) then
      if d.result == "win" then w = w + 1 elseif d.result == "loss" then l = l + 1 end
    end
  end
  return w, l
end

function UI.Try(fn, ...)
  if type(fn) ~= "function" then return nil end
  local ok, a, b = pcall(fn, ...)
  if ok then return a, b end
end

function UI.Whisper(name)
  if name and ChatFrame_SendTell then UI.Try(ChatFrame_SendTell, name) end
end

-- Selected value from a Dropdown onSelect callback (value or item table).
function UI.Val(v)
  if type(v) == "table" then return v.value end
  return v
end

function UI.Db()
  A.db.ui = A.db.ui or {}
  return A.db.ui
end

---------------------------------------------------------------------------
-- Tabs and popups

function UI.RegisterTab(id, build) UI.tabDefs[id] = build end

local pending = {}

function UI.Popup(opts)
  local k = UI.Kit()
  if not (k and k.Confirm) then A:Print(opts.text or opts.title or "") return false end
  if MK.InCombat() then table.insert(pending, opts) return true end
  opts.skin = UI.SKIN
  k.Confirm(opts)
  return true
end

function M:OnLogin()
  A:On("PLAYER_REGEN_ENABLED", function()
    local list = pending
    pending = {}
    for _, o in ipairs(list) do UI.Popup(o) end
  end)
end
