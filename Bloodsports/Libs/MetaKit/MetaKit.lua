-- MetaKit: shared embedded library for World of Meta addons (Elders, Bloodsports).
-- Each addon ships its own copy under Libs/MetaKit. The newest MINOR wins; an equal or older
-- copy sets MetaKit_SkipLoad so the rest of its files return immediately.

local MINOR = 1
if MetaKit and MetaKit.minor >= MINOR then
  MetaKit_SkipLoad = true
  return
end
MetaKit_SkipLoad = false
MetaKit = { minor = MINOR, UI = {}, addons = {} }
local MK = MetaKit

---------------------------------------------------------------------------
-- Small utilities

local U = {}
MK.Util = U

function U.Round(x, places)
  local m = 10 ^ (places or 0)
  return math.floor(x * m + 0.5) / m
end

function U.Clamp(x, lo, hi)
  if x < lo then return lo end
  if x > hi then return hi end
  return x
end

-- Fills missing keys in `t` from `defaults`, recursing into tables. Never overwrites existing values.
function U.EnsureShape(t, defaults)
  for k, v in pairs(defaults) do
    if t[k] == nil then
      t[k] = type(v) == "table" and U.EnsureShape({}, v) or v
    elseif type(v) == "table" and type(t[k]) == "table" then
      U.EnsureShape(t[k], v)
    end
  end
  return t
end

function U.Copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = U.Copy(v) end
  return out
end

function U.RandomHex(n)
  local out = {}
  for i = 1, n do out[i] = string.format("%x", math.random(0, 15)) end
  return table.concat(out)
end

function U.Truncate(s, n)
  if type(s) ~= "string" then return s end
  return #s > n and s:sub(1, n) or s
end

-- Returns the 1-based bin index for x given ascending upper edges; values above the last edge go in the last bin.
function U.Bin(x, edges)
  for i, edge in ipairs(edges) do
    if x < edge then return i end
  end
  return #edges + 1
end

-- Seconds on the server clock (shared by all players), falling back to the local clock.
function U.ServerTime()
  return (GetServerTime and GetServerTime()) or time()
end

-- Level bracket index: 1-10 -> 1, 11-20 -> 2, ...
function U.BracketOf(level)
  return math.floor(((level or 1) - 1) / 10) + 1
end

function U.BracketLabel(b)
  return (b - 1) * 10 + 1 .. "-" .. b * 10
end

-- Formats seconds as "1h 02m", "4m 05s" or "12s".
function U.Duration(sec)
  sec = math.floor(sec or 0)
  if sec >= 3600 then return string.format("%dh %02dm", sec / 3600, (sec % 3600) / 60) end
  if sec >= 60 then return string.format("%dm %02ds", sec / 60, sec % 60) end
  return sec .. "s"
end

-- Formats copper as "12g 34s 56c" (plain text, no icons).
function U.Money(copper)
  copper = math.floor(copper or 0)
  local sign = copper < 0 and "-" or ""
  copper = math.abs(copper)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  if g > 0 then return string.format("%s%dg %02ds %02dc", sign, g, s, c) end
  if s > 0 then return string.format("%s%ds %02dc", sign, s, c) end
  return sign .. c .. "c"
end

math.randomseed(math.floor((GetTime and GetTime() or os.time()) * 1000) % 2147483647)
