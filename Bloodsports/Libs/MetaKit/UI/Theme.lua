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
  muted = { 0.68, 0.64, 0.57, 1 }, -- raised from 0.54/0.50/0.44: 10 pt sub-lines were unreadable over the world
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

-- Site palette for the integrated Shell (MK.UI.Shell). Separate from UI.Tokens, which the flat widgets depend on.
UI.SiteTokens = {
  stone0 = hex("0b0806"), stone1 = hex("140f0b"), stone2 = hex("1f1710"), stone3 = hex("2c2117"),
  stoneEdge = hex("3d2e20"), gold = hex("f8d16b"), goldDeep = hex("b8862b"), goldDim = hex("8a6a2e"),
  parch = hex("e8d5a8"), inkRed = hex("7a1a12"), emerald = hex("3fbf6a"), silver = hex("c9ccd3"),
  -- code-drawn plates (WHITE8X8 + vertex colours), measured from the reference addon
  plateGoldTop = { 1.00, 0.86, 0.42, 1 }, plateGoldBottom = { 0.74, 0.55, 0.08, 1 }, plateGoldEdge = { 0.34, 0.24, 0.02, 1 },
  plateGoldHover = { 1, 0.86, 0.42, 0.35 }, plateGoldLabel = { 0.13, 0.09, 0.01, 1 },
  plateDarkFill = { 0.08, 0.07, 0.06, 0.92 }, plateDarkEdge = { 1, 1, 1, 0.12 },
  -- dark plate label raised from (1, 0.86, 0.45) for contrast on the near-black fill (the reference value stays as
  -- plateDarkLabelRef); the gold plate gets a 1 px top highlight and a 1 px darker bottom shade inside its edge
  plateDarkLabel = { 1, 0.90, 0.55, 1 }, plateDarkLabelRef = { 1, 0.86, 0.45, 1 },
  plateGoldHighlight = { 1, 1, 0.86, 0.5 }, plateGoldShade = { 0.50, 0.36, 0.04, 1 },
  -- list zebra (UI.List o.zebra): low-alpha stone bands on the dark pane
  rowEven = { 0x2c / 255, 0x21 / 255, 0x17 / 255, 0.45 }, rowOdd = { 0x0b / 255, 0x08 / 255, 0x06 / 255, 0.25 },
  title = { 1, 0.82, 0, 1 }, titleShadow = { 0, 0, 0, 0.85 },
  -- v3: list separators (#4a351d @ 55%), ink for text on parchment, the parchment darkening tint (~18%)
  -- v5: parchTint 0.82 -> 0.92: dark ink needs a lighter ground (it4 crop: ~2.4:1 effective on the 0.82 tan)
  -- v9: parchTint 0.92 -> 0.87: the sidebar read brighter than the main pane and pulled the eye left (it8); the labels
  -- are #21150d since v7, so the it5 contrast margin covers the darker ground
  listSep = hex("4a351d", 0.55), ink = hex("2a1a0c"), inkSoft = hex("5a4026"), parchTint = { 0.87, 0.87, 0.87, 1 },
  -- v4: every text colour on the parchment sidebar is dark ink at full alpha (light or grey text on tan read as
  -- disabled in it3). Shell o.sidebarInk = { key = colour } overrides single keys. A flat sidebar keeps light text.
  sidebarInk = {
    label = hex("21150d"),        -- section label base ink
    labelSoft = hex("3a2810"),    -- unselected section label. v5: 4a3418 -> 3a2810; the it4 crop showed 4a3418
                                  -- reaching the glyphs but blending to #59401e (light taupe) at ~83% AA coverage
    selected = hex("0e0904"),     -- selected section label, on the gold strip + wash
    -- v7: 3a2810 -> 21150d. it6 pixel samples had the 3a2810 labels rendering LIGHTER than the green values (taupe)
    summaryLabel = hex("21150d"), -- summary block labels (Record, Win rate, ...)
    value = hex("21150d"),        -- summary values
    -- v6: good 1f7a12 -> 14550c (it5: W letters / win rate measured ~1.4-1.8:1 on the tan); bad stays 8c1d10
    good = hex("14550c"), bad = hex("8c1d10"), -- semantic green / red darkened for parchment
    -- v6: the "gold" / focal summary value (money: Net purse) is value ink; 6a4708 rendered pale gold-grey in it5
    focal = hex("21150d"),
    rule = hex("3a2810", 0.6),    -- 1 px ink rule above the summary block
    heading = hex("6e130c"),      -- v5: the tab heading (BLOODSPORTS) in ink-red darkened for parchment
    -- v6: the 3 px selection strip on parchment. goldDeep (b8862b) sat at the parchment's own luminance (invisible
    -- in it5); dark bronze gold reads as a strip on the tan
    strip = hex("6a4708"),
  },
  -- v7: the sidebar SUMMARY block's own parchment palette (Shell builds shell.summaryInk from it; o.sidebarInk's
  -- summaryLabel / value / good / bad / focal still override). Never the dark-pane tokens (muted / parch / emerald).
  summaryInk = {
    label = hex("21150d"), value = hex("21150d"), good = hex("14550c"), bad = hex("8c1d10"), focal = hex("21150d"),
  },
  summarySize = 12,               -- v7: summary label / value px on parchment (forced, not the font object's size)
  -- v6: selected nav row wash on parchment (was black @ 0.14, read as weak on the Elders sidebar)
  parchSelWash = { 0, 0, 0, 0.22 },
}

-- Shell metrics (Talents Forever): margin, gap, title band, tab strip, sidebar, row, button, default size, cover art.
-- v2: title 20 (Cinzel Bold, shadow 2,-2), tabs 24 high / min 110 wide / 16 px label padding / 2 px pane overlap,
-- compact window 820 x 520 with a 220 px sidebar.
-- v3: gap 10 -> 8 (4/8/12/16 spacing grid); depth chrome (o.chrome): 12 px band, 8 px extra body inset, 4 px well
-- rim; material sidebar (o.sidebar): 26 px rows, 16 px icons, 3 px selection strip; summary lines 16 px.
-- v4: active tab 28 / inactive 24 with 12 px labels; corner brackets 24; drop shadow 6 px larger, 6 px down, 45%
-- (dialog / flat chrome); summary block 8 px above the footer; proportional scroll thumb 10 px wide, min 24.
UI.ShellMetrics = { margin = 12, gap = 8, titleBand = 50, tabStrip = 25, sidebar = 340, row = 22, button = 24,
  width = 900, height = 600, corner = 64, grain = 128,
  titleSize = 20, titleShadowX = 2, titleShadowY = -2,
  tab = 28, tabInactive = 24, tabMin = 110, tabPad = 16, tabOverlap = 2, tabGap = 4, tabLabel = 12,
  compactWidth = 820, compactHeight = 520, compactSidebar = 220,
  band = 12, depthInset = 8, wellPad = 4, bracket = 24,
  shadowGrow = 6, shadowDrop = 6, shadowAlpha = 0.45,
  navRow = 26, navIcon = 16, navStrip = 3, summaryLine = 16, summaryGap = 8,
  thumbTrack = 10, thumbMin = 24 }

---------------------------------------------------------------------------
-- Probes (probe first, degrade silently). Results are cached per path / template name.

local texProbe, texCache, tplCache = nil, {}, {}

-- True when a Blizzard texture file exists: GetFileIDFromPath names it, or a hidden probe texture takes it
-- (SetTexture neither raises nor returns false, and GetTextureFileID, when present, names a file).
function UI.ProbeTexture(path)
  if type(path) ~= "string" or path == "" then return false end
  local cached = texCache[path]
  if cached ~= nil then return cached end
  local found = false
  if type(GetFileIDFromPath) == "function" then
    local ok, id = pcall(GetFileIDFromPath, path)
    found = ok and id ~= nil and id ~= 0
  end
  if not found then -- no path API, or it said no: the probe texture has the last word
    if not texProbe and UIParent and UIParent.CreateTexture then
      local ok, t = pcall(UIParent.CreateTexture, UIParent, nil, "BACKGROUND")
      if ok and t then texProbe = t; pcall(t.Hide, t) end
    end
    local t = texProbe
    if t then
      local ok, res = pcall(t.SetTexture, t, path)
      found = ok and res ~= false
      if found and type(t.GetTextureFileID) == "function" then
        local okId, id = pcall(t.GetTextureFileID, t)
        if okId and (id == nil or id == 0) then found = false end
      end
      pcall(t.SetTexture, t, nil)
    end
  end
  texCache[path] = found
  return found
end

-- true / false when the client can say whether an XML template exists (C_XMLUtil.GetTemplateInfo), nil when it
-- cannot (the caller then tries CreateFrame under pcall).
function UI.HasTemplate(name)
  if type(name) ~= "string" then return false end
  if tplCache[name] ~= nil then return tplCache[name] end
  local fn = C_XMLUtil and C_XMLUtil.GetTemplateInfo
  if type(fn) ~= "function" then return nil end
  local ok, info = pcall(fn, name)
  local has = ok and info ~= nil
  tplCache[name] = has
  return has
end

function UI.ResetProbes()
  texProbe, texCache, tplCache = nil, {}, {}
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
