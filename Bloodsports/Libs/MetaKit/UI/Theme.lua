-- UI kit foundation: flat tokens, skins (palette) and the helpers every widget shares
-- (backdrops, atlas probing, fonts, sounds, tooltips).
--
-- CONTRACT NOTE: the kit draws flat fills and 1 px lines only (UI.Tokens, spec docs/UI_REBUILD_SPEC.md).
-- A skin may still carry art tokens (tile, header, footer, logo, ...) and `headerSize` / `footerSize`;
-- `UI.RegisterSkin` still MERGES them and addons may read them, but the kit never draws them.
-- Window positions are saved as db.pos = { point, relativePoint, x, y }.

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI

local min, max, floor = math.min, math.max, math.floor

UI.Tex = {
  tipBg = "Interface\\Tooltips\\UI-Tooltip-Background",
  tipEdge = "Interface\\Tooltips\\UI-Tooltip-Border",
  dlgEdge = "Interface\\DialogFrame\\UI-DialogBox-Border",
  tile = "Interface\\Collections\\CollectionsBackgroundTile",
  white = "Interface\\Buttons\\WHITE8X8",
  highlight = "Interface\\Buttons\\UI-Panel-Button-Highlight",
  ring = "Interface\\COMMON\\RingBorder",
  maskSmall = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMaskSmall",
  classes = "Interface\\GLUES\\CHARACTERCREATE\\UI-CharacterCreate-Classes",
  unknown = "Interface\\Icons\\INV_Misc_QuestionMark",
  note = "Interface\\Icons\\INV_Misc_Note_01",
  check = "Interface\\Buttons\\UI-CheckBox-Check",
  arrowDown = "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up",
  star = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1",
  mmHighlight = "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight",
  mmBorder = "Interface\\Minimap\\MiniMap-TrackingBorder",
  mmBackground = "Interface\\Minimap\\UI-Minimap-Background",
}

---------------------------------------------------------------------------
-- Tokens: the one flat palette every kit widget draws with.

UI.Tokens = {
  bg = { 0.078, 0.059, 0.043, 0.92 },
  border = { 1, 1, 1, 0.12 },
  text = { 0.91, 0.88, 0.82, 1 },
  muted = { 0.54, 0.50, 0.44, 1 },
  accent = { 0.973, 0.820, 0.420, 1 },
  accentFill = { 0.973, 0.820, 0.420, 0.25 },
  divider = { 1, 1, 1, 0.20 },
  good = { 0.25, 0.75, 0.42, 1 },
  bad = { 0.75, 0.22, 0.18, 1 },
}

-- Font object names (three sizes only): small 10, normal 12, large 16.
UI.Fonts = { small = "GameFontNormalSmall", normal = "GameFontNormal", large = "GameFontNormalLarge" }

-- Row / chrome metrics from the spec.
UI.Metrics = { gutter = 8, row = 22, header = 20, tab = 24, button = 24, titleBar = 36, section = 22, sectionGap = 10 }

---------------------------------------------------------------------------
-- Skins

local function hex(h, a)
  return { tonumber(h:sub(1, 2), 16) / 255, tonumber(h:sub(3, 4), 16) / 255, tonumber(h:sub(5, 6), 16) / 255, a or 1 }
end

local COLOR_KEYS = { "bg", "panel", "edge", "accent", "title", "text", "muted", "good", "bad", "rowEven", "rowOdd", "divider" }
local ART_KEYS = { "tile", "header", "footer", "logo", "icon", "portrait", "bannerGood", "bannerBad", "glyphFull", "glyphEmpty" }
UI.ColorKeys, UI.ArtKeys = COLOR_KEYS, ART_KEYS

local skins = {}

local function norm(c)
  return { c[1] or 1, c[2] or 1, c[3] or 1, c[4] or 1 }
end

-- Registers a skin, or merges tokens into an existing one (use `false` to clear an art token).
function UI.RegisterSkin(name, tokens)
  tokens = tokens or {}
  local s = skins[name]
  if not s then
    s = { name = name }
    local base = skins.elders
    if base then
      for _, k in ipairs(COLOR_KEYS) do s[k] = norm(base[k]) end
    end
    skins[name] = s
  end
  for _, k in ipairs(COLOR_KEYS) do
    if type(tokens[k]) == "table" then s[k] = norm(tokens[k]) end
  end
  for _, k in ipairs(ART_KEYS) do
    local v = tokens[k]
    if v == false then s[k] = nil elseif v ~= nil then s[k] = v end
  end
  if tokens.headerSize then s.headerSize = tokens.headerSize end
  if tokens.footerSize then s.footerSize = tokens.footerSize end
  return s
end

-- Accepts a skin name, a skin table, or nil (-> "elders").
function UI.Skin(x)
  if type(x) == "table" then return x end
  return skins[x or "elders"] or skins.elders
end

function UI.SkinNames()
  local out = {}
  for name in pairs(skins) do out[#out + 1] = name end
  table.sort(out)
  return out
end

-- key is a token name ("accent") or a literal {r,g,b,a} array.
function UI.Color(skin, key)
  local c = key
  if type(key) == "string" then c = UI.Skin(skin)[key] end
  if type(c) ~= "table" then return 1, 1, 1, 1 end
  return c[1], c[2], c[3], c[4] or 1
end

-- ns.Media = { path = "Interface\\AddOns\\X\\Media\\", has = { name = true } }
function UI.Art(ns, name)
  local m = ns and ns.Media
  if m and m.path and m.has and m.has[name] then return m.path .. name end
  return nil
end

-- Both built-in skins share the flat tokens (one accent). Names stay so callers keep working.
for _, name in ipairs({ "elders", "bloodsports" }) do
  local k = UI.Tokens
  UI.RegisterSkin(name, {
    bg = k.bg, panel = { k.bg[1], k.bg[2], k.bg[3], 0.6 }, edge = k.border, accent = k.accent, title = k.accent,
    text = k.text, muted = k.muted, good = k.good, bad = k.bad, divider = k.divider,
    rowEven = { 0, 0, 0, 0 }, rowOdd = { 0, 0, 0, 0 },
  })
end

---------------------------------------------------------------------------
-- Colour helpers

function UI.Dim(c, k, a)
  return { min(1, c[1] * k), min(1, c[2] * k), min(1, c[3] * k), a or c[4] or 1 }
end

function UI.WithAlpha(c, a)
  return { c[1], c[2], c[3], a }
end

---------------------------------------------------------------------------
-- Backdrops: always a flat white fill with a 1 px edge. `kind` ("window", "tip", "flat") only picks the colours;
-- skin art (tile, header, ...) is ignored.

function UI.Backdrop(f, kind, skin, bg, border)
  if not f.SetBackdrop then return end
  local K = UI.Tokens
  local def = { bgFile = UI.Tex.white, edgeFile = UI.Tex.white, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 } }
  local bgc, bc = K.bg, K.border
  if kind == "flat" then bgc = UI.WithAlpha(K.bg, 0.6) elseif kind == "tip" then bgc = UI.WithAlpha(K.bg, 0.95) end
  bgc, bc = bg or bgc, border or bc
  f:SetBackdrop(def)
  f:SetBackdropColor(bgc[1], bgc[2], bgc[3], bgc[4] or 1)
  f:SetBackdropBorderColor(bc[1], bc[2], bc[3], bc[4] or 1)
end

---------------------------------------------------------------------------
-- Atlases: probe first (absent atlases would raise), then pcall.

function UI.HasAtlas(name)
  if type(name) ~= "string" then return false end
  if C_Texture and C_Texture.GetAtlasInfo then
    local ok, info = pcall(C_Texture.GetAtlasInfo, name)
    return ok and info ~= nil
  end
  return true
end

function UI.SetAtlas(tex, name, useSize)
  if not tex or not UI.HasAtlas(name) then return false end
  local ok = pcall(tex.SetAtlas, tex, name, useSize and true or false)
  return ok
end

---------------------------------------------------------------------------
-- Fonts: Blizzard font objects only (locale safe).

local FONTS = {
  title = UI.Fonts.large, big = UI.Fonts.large, large = UI.Fonts.large,
  body = UI.Fonts.normal, small = UI.Fonts.small, number = UI.Fonts.normal,
}
local FONT_COLOR = { title = "title", big = "title", large = "text", body = "text", small = "muted", number = "text" }
UI.FontColor = FONT_COLOR

function UI.SetFont(fs, kind)
  local obj = _G[FONTS[kind] or FONTS.body]
  if obj then fs:SetFontObject(obj) end
end

---------------------------------------------------------------------------
-- Sounds (pcall'd, SOUNDKIT names with numeric fallbacks)

local SOUNDS = { open = { "IG_MAINMENU_OPEN", 850 }, close = { "IG_MAINMENU_CLOSE", 851 },
  click = { "IG_MAINMENU_OPTION_CHECKBOX_ON", 856 }, toast = { "UI_EPICLOOT_TOAST", 31578 } }

function UI.Sound(kind)
  if type(kind) == "number" then
    pcall(PlaySound, kind)
    return
  end
  local s = SOUNDS[kind]
  if not s then return end
  local id = (SOUNDKIT and SOUNDKIT[s[1]]) or s[2]
  if id and id ~= 0 then pcall(PlaySound, id) end
end

---------------------------------------------------------------------------
-- Tooltips. `tip` = string (title) | function(GameTooltip) | { title, lines } | { title = , lines = }

local function addLine(line)
  local tt = GameTooltip
  if type(line) == "string" then
    tt:AddLine(line, 1, 1, 1, true)
  elseif type(line) == "table" then
    if line.left or line.right then
      tt:AddDoubleLine(line.left or "", line.right or "", 1, 1, 1, 1, 1, 1)
    elseif type(line[2]) == "string" then
      tt:AddDoubleLine(line[1], line[2], 1, 1, 1, 1, 1, 1)
    else
      local c = line.color
      local r, g, b = 1, 1, 1
      if type(c) == "table" then r, g, b = c[1], c[2], c[3] elseif type(line[2]) == "number" then r, g, b = line[2], line[3], line[4] end
      tt:AddLine(line.text or line[1] or "", r, g, b, true)
    end
  end
end

function UI.Tooltip(owner, title, lines, anchor)
  if not GameTooltip then return end
  GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
  if title then GameTooltip:AddLine(title, 1, 0.82, 0, true) end
  if type(lines) == "string" then lines = { lines } end
  for _, line in ipairs(lines or {}) do addLine(line) end
  GameTooltip:Show()
end

function UI.ShowTip(owner, tip, anchor)
  if not tip or not GameTooltip then return end
  if type(tip) == "function" then
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    pcall(tip, GameTooltip)
    GameTooltip:Show()
  elseif type(tip) == "string" then
    UI.Tooltip(owner, tip, nil, anchor)
  elseif type(tip) == "table" then
    UI.Tooltip(owner, tip.title or tip[1], tip.lines or tip[2], anchor)
  end
end

function UI.HideTip()
  if GameTooltip then GameTooltip:Hide() end
end

function UI.Unpack(c)
  return c[1], c[2], c[3], c[4] or 1
end

UI.clamp = MK.Util.Clamp
