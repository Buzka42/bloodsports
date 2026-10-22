-- Deterministic serializer + safe parser (never loadstring), base64, adler32 and the WOM1 export-string wrapper.
-- CONTRACT NOTE: wire format is length-prefixed strings (binary safe), not escaped quotes. Unsupported value types
-- (functions, userdata, booleans as keys) are dropped from tables; nan serializes as nil.

if MetaKit_SkipLoad then return end
local MK = MetaKit

local MAX_DEPTH, MAX_LEN = 32, 4 * 1024 * 1024
local floor, format, byte, char = math.floor, string.format, string.byte, string.char

---------------------------------------------------------------------------
-- Serialize

local function numRepr(v)
  if v ~= v then return nil end
  if v == math.huge then return "inf" elseif v == -math.huge then return "-inf" end
  if v == floor(v) and math.abs(v) < 1e15 then return format("%d", v) end
  local s = format("%.14g", v)
  if tonumber(s) ~= v then s = format("%.17g", v) end
  return s
end

local function keyLess(a, b)
  local ta, tb = type(a), type(b)
  if ta ~= tb then return ta == "number" end
  return a < b
end

local function supported(v)
  local t = type(v)
  return t == "string" or t == "boolean" or t == "table" or (t == "number" and v == v)
end

local function ser(v, buf, depth)
  local t = type(v)
  if t == "number" then
    local r = numRepr(v)
    buf[#buf + 1] = r and ("#" .. r .. ";") or "~"
  elseif t == "string" then
    buf[#buf + 1] = '"' .. #v .. ":" .. v
  elseif t == "boolean" then
    buf[#buf + 1] = v and "T" or "F"
  elseif t == "table" then
    if depth >= MAX_DEPTH then error("table nesting too deep", 0) end
    buf[#buf + 1] = "{"
    local n = 0
    while v[n + 1] ~= nil do n = n + 1 end
    for i = 1, n do ser(v[i], buf, depth + 1) end
    buf[#buf + 1] = ";"
    local keys = {}
    for k, val in pairs(v) do
      local kt = type(k)
      local inArray = kt == "number" and k >= 1 and k <= n and k == floor(k)
      if not inArray and (kt == "string" or (kt == "number" and k == k)) and supported(val) then
        keys[#keys + 1] = k
      end
    end
    table.sort(keys, keyLess)
    for _, k in ipairs(keys) do
      ser(k, buf, depth + 1)
      ser(v[k], buf, depth + 1)
    end
    buf[#buf + 1] = "}"
  else
    buf[#buf + 1] = "~"
  end
end

function MK.Serialize(value)
  local buf = {}
  local ok, err = pcall(ser, value, buf, 0)
  if not ok then return nil, err end
  return table.concat(buf)
end

---------------------------------------------------------------------------
-- Deserialize

local parse

local function parseNumber(s, pos)
  local e = s:find(";", pos + 1, true)
  if not e then error("unterminated number", 0) end
  local str = s:sub(pos + 1, e - 1)
  if str == "inf" then return math.huge, e + 1 end
  if str == "-inf" then return -math.huge, e + 1 end
  if not str:match("^%-?[%d%.]+[eE]?[%+%-]?%d*$") then error("bad number", 0) end
  local n = tonumber(str)
  if not n or n ~= n then error("bad number", 0) end
  return n, e + 1
end

local function parseString(s, pos)
  local colon = s:find(":", pos + 1, true)
  local digits = colon and s:sub(pos + 1, colon - 1)
  if not digits or not digits:match("^%d+$") or #digits > 9 then error("bad string header", 0) end
  local stop = colon + tonumber(digits)
  if stop > #s then error("string overruns input", 0) end
  return s:sub(colon + 1, stop), stop + 1
end

local function parseTable(s, pos, depth)
  local t, i, len = {}, 0, #s
  pos = pos + 1
  while s:sub(pos, pos) ~= ";" do
    if pos > len then error("unterminated table", 0) end
    i = i + 1
    t[i], pos = parse(s, pos, depth + 1)
  end
  pos = pos + 1
  while s:sub(pos, pos) ~= "}" do
    if pos > len then error("unterminated table", 0) end
    local k, v
    k, pos = parse(s, pos, depth + 1)
    if type(k) ~= "string" and type(k) ~= "number" then error("bad key", 0) end
    v, pos = parse(s, pos, depth + 1)
    t[k] = v
  end
  return t, pos + 1
end

parse = function(s, pos, depth)
  if depth > MAX_DEPTH then error("table nesting too deep", 0) end
  local c = s:sub(pos, pos)
  if c == "#" then return parseNumber(s, pos)
  elseif c == '"' then return parseString(s, pos)
  elseif c == "{" then return parseTable(s, pos, depth)
  elseif c == "T" then return true, pos + 1
  elseif c == "F" then return false, pos + 1
  elseif c == "~" then return nil, pos + 1
  end
  error("unexpected token at " .. pos, 0)
end

function MK.Deserialize(text)
  if type(text) ~= "string" then return nil, "not a string" end
  if #text > MAX_LEN then return nil, "too large" end
  local ok, value, pos = pcall(parse, text, 1, 0)
  if not ok then return nil, value end
  if pos ~= #text + 1 then return nil, "trailing data" end
  return value
end

---------------------------------------------------------------------------
-- Base64 + Adler32

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local enc, dec = {}, {}
for i = 1, 64 do
  enc[i - 1] = B64:sub(i, i)
  dec[byte(B64, i)] = i - 1
end

function MK.Base64Encode(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = byte(s, i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    out[#out + 1] = enc[floor(n / 262144) % 64] .. enc[floor(n / 4096) % 64]
      .. (b and enc[floor(n / 64) % 64] or "=") .. (c and enc[n % 64] or "=")
  end
  return table.concat(out)
end

function MK.Base64Decode(s)
  if type(s) ~= "string" then return nil, "not a string" end
  s = s:gsub("%s", "")
  if #s % 4 ~= 0 then return nil, "bad length" end
  if s:find("[^%w%+/=]") or s:find("=[^=]") or s:find("===") then return nil, "bad characters" end
  local out = {}
  for i = 1, #s, 4 do
    local c1, c2, c3, c4 = byte(s, i, i + 3)
    local v1, v2 = dec[c1], dec[c2]
    local v3, v4 = dec[c3] or 0, dec[c4] or 0
    if not v1 or not v2 then return nil, "bad characters" end
    local n = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
    local str = char(floor(n / 65536) % 256, floor(n / 256) % 256, n % 256)
    if c4 == 61 then str = c3 == 61 and str:sub(1, 1) or str:sub(1, 2) end
    out[#out + 1] = str
  end
  return table.concat(out)
end

function MK.Adler32(s)
  local a, b = 1, 0
  for i = 1, #s do
    a = (a + byte(s, i)) % 65521
    b = (b + a) % 65521
  end
  return b * 65536 + a
end

---------------------------------------------------------------------------
-- Export strings: WOM1:<tag>:<base64(serialized)>:<adler32 hex of serialized>

function MK.ExportString(tag, value)
  tag = tostring(tag)
  if not tag:match("^[%w_%-]+$") then return nil, "bad tag" end
  local text, err = MK.Serialize(value)
  if not text then return nil, err end
  return "WOM1:" .. tag .. ":" .. MK.Base64Encode(text) .. ":" .. format("%08x", MK.Adler32(text))
end

function MK.ImportString(s)
  if type(s) ~= "string" then return nil, "not a string" end
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  local tag, body, sum = s:match("^WOM1:([%w_%-]+):([%w%+/=%s]*):(%x%x%x%x%x%x%x%x)$")
  if not tag then return nil, "not a WOM1 string" end
  local text, err = MK.Base64Decode(body)
  if not text then return nil, err end
  if format("%08x", MK.Adler32(text)) ~= sum:lower() then return nil, "checksum mismatch" end
  local value, derr = MK.Deserialize(text)
  if value == nil and derr then return nil, derr end
  return tag, value
end
