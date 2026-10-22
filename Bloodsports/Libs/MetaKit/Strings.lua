-- Client global strings (with fallbacks) turned into Lua patterns, so system/chat messages parse on any locale.
-- CONTRACT NOTE: Match returns captures as strings (also for %d); a format with no placeholders returns `true` on match.

if MetaKit_SkipLoad then return end
local MK = MetaKit

local compiled = {}

-- Client global string, else fallback value, else nil.
function MK.GS(name)
  local v = _G[name]
  if type(v) == "string" then return v end
  local fb = MK.GlobalStringsFallback
  v = fb and fb[name]
  if type(v) == "string" then return v end
end

local function escape(c)
  return (c:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local CAPTURE = { s = "(.+)", d = "(%-?%d+)", i = "(%-?%d+)", f = "(%-?[%d%.]+)" }

local function compile(fmt)
  local out, order, count, maxPos = { "^" }, {}, 0, 0
  local i, len = 1, #fmt
  while i <= len do
    local c = fmt:sub(i, i)
    if c == "%" then
      local pos, conv = fmt:match("^%%(%d+)%$[%-%d%.]*([sdif])", i)
      local whole = fmt:match("^%%%d+%$[%-%d%.]*[sdif]", i)
      if not whole then
        conv = fmt:match("^%%[%-%d%.]*([sdif])", i)
        whole = fmt:match("^%%[%-%d%.]*[sdif]", i)
        pos = nil
      end
      if whole then
        count = count + 1
        pos = tonumber(pos) or count
        order[count] = pos
        if pos > maxPos then maxPos = pos end
        out[#out + 1] = CAPTURE[conv]
        i = i + #whole
      elseif fmt:sub(i, i + 1) == "%%" then
        out[#out + 1] = "%%"
        i = i + 2
      else
        out[#out + 1] = "%%"
        i = i + 1
      end
    else
      out[#out + 1] = escape(c)
      i = i + 1
    end
  end
  out[#out + 1] = "$"
  return { pattern = table.concat(out), order = order, count = count, maxPos = maxPos }
end

-- Compiled { pattern, order = {captureIndex -> argPosition}, count, maxPos } or nil when the string is unknown.
function MK.Pattern(name)
  local src = MK.GS(name)
  if not src then return nil end
  local c = compiled[name]
  if c and c.src == src then return c end
  c = compile(src)
  c.src = src
  compiled[name] = c
  return c
end

-- Args in ARGUMENT order (positional-aware) or nil. nil for secret / non-string text.
function MK.Match(name, text)
  if type(text) ~= "string" or MK.IsSecret(text) then return nil end
  local p = MK.Pattern(name)
  if not p then return nil end
  if p.count == 0 then return text:find(p.pattern) and true or nil end
  local caps = { text:match(p.pattern) }
  if #caps == 0 then return nil end
  local args = {}
  for i = 1, p.count do args[p.order[i]] = caps[i] end
  return unpack(args, 1, p.maxPos)
end
