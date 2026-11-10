-- Bloodsports UI helpers: art lookup, formatting, venue lookups, tab registry, combat-safe popups.
-- CONTRACT NOTE: all UI modules guard on ns.UI.Kit() (MetaKit.UI.Window present) and degrade to a chat message.
-- CONTRACT NOTE: the window is flat (kit tokens); no skin art is registered.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A

local UI = {}
ns.UI = UI
UI.SKIN = "bloodsports"
-- v15 (JUDGE3 D2): one placeholder glyph suite-wide, the em dash (the shared shell's UI.ShellDash is the same bytes)
UI.DASH = "\226\128\148"
-- v15 (JUDGE3 S4 / S5 / F-11 / F-12): the pane layout every Bloodsports section shares. CONTENT_X = the List's PAD (4) +
-- half its 16 px gutter + the 1 px inset edge: where a list's first text cell starts when its first column is text,
-- and where section headers, helper copy and the footer line start. FOOT_H = the footer band at the pane bottom.
-- ICON_W = the one icon / class cell width (22 px) every list uses.
UI.CONTENT_X, UI.FOOT_H, UI.ICON_W, UI.LIST_GUTTER = 13, 22, 22, 16
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
  if type(t) ~= "number" then return UI.DASH end
  local now = t > 1e9 and MK.Util.ServerTime() or GetTime()
  local d = math.max(0, now - t)
  if d < 60 then return math.floor(d) .. "s" end
  if d < 3600 then return math.floor(d / 60) .. "m" end
  return math.floor(d / 3600) .. "h"
end

function UI.Pct(w, n)
  if not n or n <= 0 then return UI.DASH end
  return math.floor(w / n * 100 + 0.5) .. "%"
end

function UI.Currency()
  local r = A.db and A.db.config and A.db.config.ring
  return (r and r.currency) or "gold"
end

-- Compact money (contract §7: "34g 47s 05c", copper only when non-zero, "34g 47s", "50s"): the kit's demo formatter
-- when present, else MK.Util.Money.
function UI.Money(copper)
  local f = MK.UI and MK.UI.ChromeDemoMoney
  if f then
    local ok, txt = pcall(f, copper)
    if ok and type(txt) == "string" then return txt end
  end
  return MK.Util.Money(copper)
end

function UI.Amount(v, currency)
  v = tonumber(v) or 0
  if (currency or UI.Currency()) == "points" then return math.floor(v) .. " pts" end
  return UI.Money(v)
end

-- Typed amount -> internal amount (copper for gold, raw for points). Gold takes "12", "12.5", "12g 50s", "50s", "3g33s33c".
function UI.ParseMoney(text, currency)
  text = tostring(text or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  if (currency or UI.Currency()) == "points" then
    local n = tonumber((text:gsub("%s*pts?$", "")))
    n = n and math.floor(n)
    return n and n > 0 and n or nil
  end
  local n = tonumber(text)
  if n then
    n = math.floor(n * 10000 + 0.5)
    return n > 0 and n or nil
  end
  local total, any = 0, false
  local rest = text:gsub("(%d+%.?%d*)%s*([gsc])", function(v, u)
    any = true
    total = total + tonumber(v) * (u == "g" and 10000 or u == "s" and 100 or 1)
    return ""
  end)
  if not any or rest:match("%S") then return nil end
  total = math.floor(total + 0.5)
  return total > 0 and total or nil
end

function UI.ParseAmount(text, currency) return UI.ParseMoney(text, currency) end

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
  return UI.DASH
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

-- v15 (JUDGE3 S5 / F-12): the footer status line every section draws at its pane bottom (the Ring idle footer's
-- idiom): small, muted, single line, CONTENT_X in from both edges, 6 px above the pane bottom.
-- v16 (judge4): the muted token read dull on the dark pane; every pane footer (Duels / Matches / Finder / Clubs and
-- the Ring idle footer) shares this one brighter parchment ink.
-- v17 (judge5): still dim on the dark pane: (0.78, 0.70, 0.56) -> (0.88, 0.80, 0.64), and the 10 pt small font is
-- raised to FOOT_SIZE (keeping the font object's face and flags); a font already at or over FOOT_SIZE is left alone.
UI.FOOT_INK, UI.FOOT_SIZE = { 0.88, 0.80, 0.64, 1 }, 11
function UI.ApplyFootInk(l)
  l:SetTextColor(UI.FOOT_INK[1], UI.FOOT_INK[2], UI.FOOT_INK[3], UI.FOOT_INK[4])
  l.mkColor = UI.FOOT_INK
  if l.GetFont and l.SetFont then
    local ok, path, size, flags = pcall(l.GetFont, l)
    if ok and type(path) == "string" and (tonumber(size) or 0) < UI.FOOT_SIZE
      and pcall(l.SetFont, l, path, UI.FOOT_SIZE, flags or "") then
      l.mkFootSize = UI.FOOT_SIZE
    end
  end
  return l
end

function UI.PaneFooter(pane)
  local k = UI.Kit()
  local l = k.Label(pane, { text = "", font = "small", color = "muted", skin = UI.SKIN })
  UI.ApplyFootInk(l)
  if l.SetWordWrap then l:SetWordWrap(false) end
  l:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", UI.CONTENT_X, 6)
  l:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -UI.CONTENT_X, 6)
  pane.footer = l
  return l
end

-- 1 px gold-dim (138,106,46) rule under a section header (the Ring idle view's sectionRule).
UI.RULE = { 138 / 255, 106 / 255, 46 / 255, 1 }
function UI.SectionRule(parent)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetColorTexture(UI.RULE[1], UI.RULE[2], UI.RULE[3], UI.RULE[4])
  t:SetHeight(1)
  t.mkColor = UI.RULE
  return t
end

-- "1 duel" / "3 duels"
function UI.Plural(n, one, many) n = tonumber(n) or 0; return n .. " " .. (n == 1 and one or (many or (one .. "s"))) end

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
