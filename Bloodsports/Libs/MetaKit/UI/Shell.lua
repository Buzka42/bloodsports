-- UI kit: Shell, the one integrated World of Meta window. Blizzard's portrait-frame chrome, a row of top tabs (one per
-- loaded addon) and, per tab, a left sidebar of sections; the content pane builds each section lazily, once.
--
--   local shell = MK.UI.Shell{ name = "WorldOfMetaShell", title = "World of Meta", subtitle = "...", db = tbl,
--     width = 900, height = 600, ns = ns, portrait = "Interface\\Icons\\...",
--     compact = true,                                -- 820 x 520 default size and a 220 px sidebar
--     footerText = "Sync now", onFooter = function(shell, plate) end }  -- optional plate on the sidebar bottom
--   v3 options (all optional; nil keeps the v2 look):
--     chrome = "dialog" | "portrait" | "flat"  -- depth: 12 px multi-band edge (or the probed UI-DialogBox-Border for
--       "dialog"), corner brackets, an inset well round sidebar + pane. "dialog" / "flat" skip the portrait
--       templates (plain frame); "portrait" keeps the template chain and draws the band inside its edge.
--     sidebar = "parchment" | "flat"            -- 26 px nav rows (16 px icons, 3 px gold selection strip); parchment
--       is the probed Achievement parchment darkened by SiteTokens.parchTint, else it falls back to "flat".
--     summary = lines | function(shell, tabId) return lines end  -- block under the sections (also AddTab{summary=})
--       anchored to the sidebar bottom, 8 px above the footer; lines that do not fit drop from the top of the block
--     sidebarInk = { label =, labelSoft =, selected =, summaryLabel =, value =, good =, bad =, focal =, rule =,
--       strip = }  -- v6: strip = the 3 px nav selection strip colour on parchment
--       -- v7: the summary block reads shell.summaryInk (SiteTokens.summaryInk + these summary keys), 12 px forced
--     footerVariant = "dark"                    -- v7: dark plate + gold label for the footer (else footerKind)
--       -- parchment only: overrides single SiteTokens.sidebarInk colours (all sidebar text is dark ink there)
--     nativeButtons = true                      -- footer as UIPanelButtonTemplate when present, else the plate
--     chromeTint = { r, g, b }                  -- dialog border tint (default UI.ShellDialogTint, bronze-gold)
--   v4: "dialog" / "flat" chrome cast a drop shadow (shell.shadow; nil when a call errors). v5: "portrait" too.
--     sidebarExtra = function(parent, shell, tabId) return frame end  -- v5: filler between the section rows and the
--       bottom summary (also AddTab{extra=}); built once per tab under pcall, hidden when the gap is shorter than
--       frame.minHeight (default 40). shell.lastError keeps a builder error.
--   v8 art (each = true -> MK.UI.Art(o.ns, token), or a texture path; missing / failing art = off, v7 look kept):
--     titleArt = true | path      -- "logo_main" wordmark, UI.ShellArt.titleWidth wide (v9: 240; 800:344), centred,
--       10 px over the top edge; hides the Cinzel title (shell.titleArt) and pushes the tab strip below it (v9: the
--       strip tucks UI.ShellArt.titleTuck px under the wordmark's narrow bottom tip)
--     portraitArt = true | path   -- "logo_m" in the native portrait socket (shell.portraitArt), else o.portrait
--     corners = true | "all" | "bottom" | path  -- "ornament_corner", 72 px in all four corners, mirrored by
--       SetTexCoord, above the border and below the title art (shell.corners = { host, textures, path, mode }).
--       v9: "bottom" draws only BL / BR (the top pair hides under the portrait medallion and the close button)
--   v10: flankArt = { left = v, right = v }  -- crests flanking the wordmark in the title band: 44 px
--       (UI.ShellArt.flankSize), centred vertically between the frame top and the tab strip, left edge at +64 (clears
--       the portrait medallion), right edge mirrored at -64 (clears the close plate). v = true (the side's default
--       tokens, UI.ShellArt.flankTokens: left "crest_bloodsports", right "crest_elders" then "crest_tournament"), a
--       token name, a texture path (contains a slash), or a list of those tried in order. Tokens resolve through
--       MK.UI.Art(o.ns, name) (or o.art). Missing / failing art hides that side (shell.flanks.left / .right = nil).
--       v11: 52 px; with title art the crests anchor to the wordmark (left crest's right edge UI.ShellArt.flankGap =
--       18 px left of the logo's left edge, right mirrored), else the +-64 frame-edge insets. Each crest also draws a
--       soft halo: the same texture at UI.ShellArt.flankHalo (60 px), alpha flankHaloAlpha (0.25), centred behind it
--       (fl[side].halo; a failing halo texture is skipped, the crest stays).
--   v9: closeStyle = "plate"      -- a 24 x 24 dark plate with a gold X (two 1.5 px gold bars turned +-45 degrees by
--       SetRotation, else a gold "X" font string) replaces the stock red close; shell.closeStyle = "plate" | "native",
--       shell.closeButton.mkGlyph = "strokes" | "text". A plate that fails to build keeps the native close.
--   shell:AddTab{ id = "bloodsports", label = "Bloodsports", owner = "Bloodsports", order = 1 }
--   shell:AddSection{ tab = "bloodsports", id = "ring", label = "The Ring", order = 1, icon = path, build = function(parent) ... end }
--   shell:Select(tabId, sectionId)   shell:Toggle(tabId)   shell:Refresh()   shell:RemoveTab(id)
--
--   v12: sections take onShow = function(frame, shell, sec) (fires each time the section comes into view); Toggle takes
--   (tabId, sectionId).
--   v12 shared shell: MK.UI.SharedShell(db, ns) -- the one lazily created, singleton World of Meta window (frame name
--   "WorldOfMetaShell", the /mkchrome look: portrait chrome, logo_main wordmark, logo_m medallion, bottom corners,
--   crest flanks, parchment sidebar, dark "Sync now" footer). The first caller's db wins and the shell is stored on
--   MK.UI._sharedShell; later calls return it (a later ns is only added to the art lookup). Addons call
--   MK.UI.RegisterSharedTab{...} / MK.UI.RegisterSharedSection{...} (same tables as shell:AddTab / AddSection); they
--   queue until the shell exists and are applied in registration order (tabs first). MK.UI.SharedShellNamespace(ns)
--   adds an addon's ns to the art lookup (first hit wins). MK.UI.SharedShellOpen(db, ns, tabId, sectionId) =
--   SharedShell(...):Toggle(...)-or-Select+Show for callers that name a section.
--
-- Also: MK.UI.Display(fontString, size, bold) (Cinzel headings with a locale-safe fallback) and MK.UI.Plate(parent, o)
-- (gold / dark plate buttons drawn from WHITE8X8 + vertex colours).
--
-- CONTRACT NOTE: chrome falls back PortraitFrameTemplate -> PortraitFrameFlatTemplate -> plain Frame. With a native
-- template the template's own body shows; the cover (art 9-slice, or the flat #140f0b fill + #3d2e20 1 px border) is
-- drawn when the chrome is plain, and over a native body only when cover art is registered.
-- CONTRACT NOTE: cover art tokens are "cover-tl", "cover-tr", "cover-bl", "cover-br", "cover-top", "cover-bottom",
-- "cover-left", "cover-right", "cover-page" (grain) and "cover-vignette", resolved by MK.UI.Art(o.ns, token) (else
-- ns.Media.has/path) or by o.art(token) when given. Every piece is optional.
-- CONTRACT NOTE: db keys written: db.pos = { point, relativePoint, x, y }, db.width, db.height, db.tab (last tab id),
-- db.sections[tabId] (last section id per tab).
-- CONTRACT NOTE: a tab with an `owner` shows only while C_AddOns.IsAddOnLoaded(owner) (or the old IsAddOnLoaded) says
-- so; when no probe exists or it errors, the tab shows. A tab with no owner always shows.
-- CONTRACT NOTE: a section's build(parent) runs once, the first time it is shown, under pcall. If it returns a frame
-- with no anchors, that frame is fitted to the parent. A build error leaves a one-line notice in the pane and is
-- kept in shell.lastError; it is not retried.
-- CONTRACT NOTE: the sidebar does not scroll in v1: rows that do not fit the sidebar height (less the footer plate,
-- when one is set) are hidden (about 16 rows at the default 600 px height).
-- CONTRACT NOTE: the dark plate's hover wash (gold at alpha 0.12) is not measured from the reference; the gold
-- plate's (alpha 0.35) is.

if MetaKit_SkipLoad then return end
local ADDON = ...
local MK = MetaKit
local UI = MK.UI

local min, max, floor = math.min, math.max, math.floor
local tinsert, tremove, tsort = table.insert, table.remove, table.sort

local WHITE = "Interface\\Buttons\\WHITE8X8"
local EDGE_LEVEL = 510  -- the portrait template draws its edge art ~500 levels up; title-bar parts stand above it
local MIN_W, MIN_H = 760, 480
local ROW_H, ROW_GAP, SIDE_PAD, SIDE_HEAD = 24, 4, 8, 32
local PANE_PAD = 8
local FOOT_GAP = 8      -- sidebar footer plate: gap between its gold rule and the plate
local SUB_H = 12        -- subtitle line height (small font)

local function K() return UI.SiteTokens end
local function M() return UI.ShellMetrics end

---------------------------------------------------------------------------
-- Texture helpers (every SetTexture / SetFont goes through pcall)

local function setTex(tex, path, h, v)
  if not tex or not path then return false end
  local ok, res
  if h then ok, res = pcall(tex.SetTexture, tex, path, h, v) else ok, res = pcall(tex.SetTexture, tex, path) end
  return ok and res ~= false
end

-- Solid colour: WHITE8X8 tinted, else a colour texture.
local function solid(tex, c)
  if setTex(tex, WHITE) then
    pcall(tex.SetVertexColor, tex, c[1], c[2], c[3], c[4] or 1)
  else
    pcall(tex.SetColorTexture, tex, c[1], c[2], c[3], c[4] or 1)
  end
end

-- Vertical gradient top -> bottom on a WHITE8X8 texture; a flat mid colour when no gradient API takes.
local function gradient(tex, top, bottom)
  solid(tex, { 1, 1, 1, 1 })
  local ta, ba = top[4] or 1, bottom[4] or 1
  if tex.SetGradient and type(CreateColor) == "function" then
    local ok = pcall(tex.SetGradient, tex, "VERTICAL", CreateColor(bottom[1], bottom[2], bottom[3], ba),
      CreateColor(top[1], top[2], top[3], ta))
    if ok then return true end
  end
  if tex.SetGradientAlpha then
    local ok = pcall(tex.SetGradientAlpha, tex, "VERTICAL", bottom[1], bottom[2], bottom[3], ba, top[1], top[2], top[3], ta)
    if ok then return true end
  end
  pcall(tex.SetVertexColor, tex, (top[1] + bottom[1]) / 2, (top[2] + bottom[2]) / 2, (top[3] + bottom[3]) / 2, (ta + ba) / 2)
  return false
end

local function newTex(frame, layer, sub)
  return frame:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
end

-- Flat fill + 1 px border (four edge textures). Returns { fill, top, bottom, left, right }.
local function box(frame, fillC, edgeC, layer)
  local b = {}
  if fillC then
    b.fill = newTex(frame, layer or "BACKGROUND", -8)
    b.fill:SetAllPoints(frame)
    solid(b.fill, fillC)
  end
  if edgeC then
    for _, e in ipairs({ { "top", "TOPLEFT", "TOPRIGHT" }, { "bottom", "BOTTOMLEFT", "BOTTOMRIGHT" },
        { "left", "TOPLEFT", "BOTTOMLEFT" }, { "right", "TOPRIGHT", "BOTTOMRIGHT" } }) do
      local t = newTex(frame, "BORDER", -8)
      t:SetPoint(e[2], frame, e[2], 0, 0)
      t:SetPoint(e[3], frame, e[3], 0, 0)
      if e[1] == "top" or e[1] == "bottom" then t:SetHeight(1) else t:SetWidth(1) end
      solid(t, edgeC)
      b[e[1]] = t
    end
  end
  return b
end

---------------------------------------------------------------------------
-- Display font: Cinzel for headings, the game's face where Cinzel cannot carry the letters.

local NON_LATIN = { ruRU = true, zhCN = true, zhTW = true, koKR = true }
UI.NonLatinLocales = NON_LATIN

local function fontCandidates(bold)
  local files = bold and { "Cinzel-Bold.ttf" } or { "Cinzel-Regular.ttf", "Cinzel-Bold.ttf" }
  local addons, seen = {}, {}
  local names = { "Elders", "Bloodsports" }
  if type(ADDON) == "string" then tinsert(names, 1, ADDON) end -- the addon whose MetaKit copy loaded comes first
  for _, a in ipairs(names) do
    if not seen[a] then seen[a] = true; addons[#addons + 1] = a end
  end
  local out = {}
  for _, file in ipairs(files) do
    for _, a in ipairs(addons) do out[#out + 1] = "Interface\\AddOns\\" .. a .. "\\Fonts\\" .. file end
  end
  return out
end
UI.DisplayFontCandidates = fontCandidates

local function latinClient()
  if type(GetLocale) ~= "function" then return true end
  local ok, loc = pcall(GetLocale)
  return not (ok and NON_LATIN[loc])
end

-- Sets Cinzel (bold or regular) at `size` (minimum 10) on a FontString. Returns true when Cinzel took; otherwise the
-- string gets GameFontNormalLarge (size >= 14) or GameFontNormal and false is returned.
function UI.Display(fs, size, bold)
  if not fs then return false end
  size = max(10, tonumber(size) or 16)
  if latinClient() and fs.SetFont then
    for _, path in ipairs(fontCandidates(bold)) do
      local ok, res = pcall(fs.SetFont, fs, path, size, "")
      if ok and res ~= false then
        fs.mkDisplayFont = path
        return true
      end
    end
  end
  fs.mkDisplayFont = false
  local obj = _G[size >= 14 and "GameFontNormalLarge" or "GameFontNormal"] or _G.GameFontNormal
  if obj and fs.SetFontObject then pcall(fs.SetFontObject, fs, obj) end
  return false
end

---------------------------------------------------------------------------
-- Plate: a code-drawn button. kind "gold" (selected / primary) or "dark".

-- Inner fill / wash / shade insets; an open-bottom plate (the active tab) runs its fill over the bottom edge.
local function placeInner(b)
  local bottom = b.openBottom and 0 or 1
  for _, t in ipairs({ b.fill, b.wash }) do
    t:ClearAllPoints()
    t:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    t:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, bottom)
  end
end

local function paintPlate(b)
  local k = K()
  if b.kind == "gold" then
    solid(b.edge, k.plateGoldEdge)
    gradient(b.fill, k.plateGoldTop, k.plateGoldBottom)
    solid(b.wash, k.plateGoldHover)
    solid(b.hi, k.plateGoldHighlight)
    solid(b.shade, k.plateGoldShade)
    b.hi:Show()
    b.shade:SetShown(not b.openBottom)
    b.label:SetTextColor(UI.Unpack(k.plateGoldLabel))
    b.label:SetShadowOffset(0, 0)
  else
    solid(b.edge, k.plateDarkEdge)
    gradient(b.fill, k.plateDarkFill, k.plateDarkFill) -- uniform gradient clears a previous gold one
    local h = k.plateGoldHover
    solid(b.wash, { h[1], h[2], h[3], 0.12 })
    b.hi:Hide()
    b.shade:Hide()
    b.label:SetTextColor(UI.Unpack(b.labelColor or k.plateDarkLabel)) -- v7: o.labelColor (dark plates only)
    b.label:SetShadowOffset(1, -1)
    b.label:SetShadowColor(0, 0, 0, 1)
  end
  b.wash:SetShown(b.hover and b.mkEnabled and true or false)
  b:SetAlpha(b.mkEnabled and 1 or 0.5)
end

-- o = { kind = "gold"|"dark", text, icon, iconSize, width, height, justify = "CENTER"|"LEFT", onClick, tooltip,
--       minWidth, padX, labelColor }  -- v7: labelColor = {r,g,b,a} for the DARK kind's label (default plateDarkLabel)
-- Without `width` the plate sizes itself to its label (label + 2 * padX, at least minWidth; an icon-less label is
-- centred); with it (or with two anchors) the label fills the plate.
function UI.Plate(parent, o)
  o = o or {}
  local h = o.height or M().button
  local b = CreateFrame("Button", nil, parent)
  b.kind, b.hover, b.mkEnabled, b.openBottom = o.kind == "gold" and "gold" or "dark", false, true, false
  b.labelColor = type(o.labelColor) == "table" and o.labelColor or nil
  b:SetSize(o.width or 96, h)
  b.edge = newTex(b, "BACKGROUND", -8)
  b.edge:SetAllPoints(b)
  b.fill = newTex(b, "BACKGROUND", -7)
  b.wash = newTex(b, "ARTWORK", 0)
  b.wash:Hide()
  placeInner(b)
  -- 1 px bevel inside the edge: highlight on top, shade on the bottom (gold only)
  b.hi = newTex(b, "BACKGROUND", -6)
  b.hi:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
  b.hi:SetPoint("TOPRIGHT", b, "TOPRIGHT", -1, -1)
  b.hi:SetHeight(1)
  b.shade = newTex(b, "BACKGROUND", -6)
  b.shade:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 1, 1)
  b.shade:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
  b.shade:SetHeight(1)
  local iconSize = o.iconSize or UI.clamp(h - 6, 16, 20)
  b.icon = newTex(b, "OVERLAY", 0)
  b.icon:SetSize(iconSize, iconSize)
  b.icon:SetPoint("LEFT", b, "LEFT", 8, 0)
  pcall(b.icon.SetTexCoord, b.icon, 0.07, 0.93, 0.07, 0.93)
  b.label = b:CreateFontString(nil, "OVERLAY")
  UI.SetFont(b.label, "body")
  b.label:SetWordWrap(false)
  local justify = o.justify or "CENTER"
  local auto = not o.width
  local hasIcon = false

  -- pressed: the label (and icon) nudge 1 px down-right while the mouse is held
  local function layout()
    b.label:ClearAllPoints()
    local pad = o.padX or 8
    local left = hasIcon and (8 + iconSize + 8) or pad
    local dx, dy = b.pressed and 1 or 0, b.pressed and -1 or 0
    b.icon:ClearAllPoints()
    b.icon:SetPoint("LEFT", b, "LEFT", 8 + dx, dy)
    if auto then
      local sw = math.ceil(b.label:GetStringWidth() or 0)
      b:SetWidth(max(o.minWidth or 60, sw + left + pad))
      if hasIcon then
        b.label:SetJustifyH("LEFT")
        b.label:SetPoint("LEFT", b, "LEFT", left + dx, dy)
      else
        b.label:SetJustifyH("CENTER")
        b.label:SetPoint("CENTER", b, "CENTER", dx, dy)
      end
    else
      b.label:SetJustifyH(justify)
      b.label:SetPoint("LEFT", b, "LEFT", left + dx, dy)
      b.label:SetPoint("RIGHT", b, "RIGHT", -8 + dx, dy)
    end
  end
  function b:SetPressed(v)
    v = v and self.mkEnabled and true or false
    if v ~= (self.pressed or false) then self.pressed = v; layout() end
  end
  function b:SetText(t) self.label:SetText(t or ""); layout() end
  function b:GetText() return self.label:GetText() end
  function b:SetIcon(path)
    hasIcon = false
    if path and setTex(self.icon, path) then hasIcon = true
    elseif path then hasIcon = setTex(self.icon, UI.Tex.unknown) end
    self.icon:SetShown(hasIcon)
    layout()
  end
  function b:SetKind(kind) self.kind = kind == "gold" and "gold" or "dark"; paintPlate(self) end
  function b:SetOpenBottom(v) self.openBottom = v and true or false; placeInner(self); paintPlate(self) end
  function b:SetSelected(v) self:SetKind(v and "gold" or "dark") end
  function b:SetEnabledState(v)
    self.mkEnabled = v and true or false
    if self.mkEnabled then self:Enable() else self:Disable() end
    if not self.mkEnabled then self.hover = false end
    paintPlate(self)
  end
  b:RegisterForClicks("LeftButtonUp")
  b:SetScript("OnEnter", function(self)
    self.hover = true
    paintPlate(self)
    if o.tooltip then UI.ShowTip(self, o.tooltip, "ANCHOR_RIGHT") end
  end)
  b:SetScript("OnLeave", function(self)
    self.hover = false
    paintPlate(self)
    if o.tooltip then UI.HideTip() end
  end)
  b:SetScript("OnMouseDown", function(self) self:SetPressed(true) end)
  b:SetScript("OnMouseUp", function(self) self:SetPressed(false) end)
  b:SetScript("OnHide", function(self) self:SetPressed(false) end)
  b:SetScript("OnClick", function(self, button)
    if not self.mkEnabled then return end
    UI.Sound("click")
    if self.onClick then self.onClick(self, button) end
  end)
  b.onClick = o.onClick
  b:SetIcon(o.icon)
  b:SetText(o.text)
  paintPlate(b)
  return b
end

---------------------------------------------------------------------------
-- Cover: optional 9-slice from art tokens, flat fallback when none is registered.

local function artResolver(o)
  if type(o.art) == "function" then
    return function(name)
      local ok, p = pcall(o.art, name)
      return ok and type(p) == "string" and p or nil
    end
  end
  local ns = o.ns
  return function(name)
    if type(UI.Art) == "function" then
      local ok, p = pcall(UI.Art, ns, name)
      return ok and type(p) == "string" and p or nil
    end
    local m = ns and ns.Media
    if type(m) == "table" and m.path and type(m.has) == "table" and m.has[name] then return m.path .. name end
    return nil
  end
end

-- Draws on `frame`. `flat` = draw the flat fill/border where art is missing. Returns the textures it made.
local function drawCover(frame, resolve, flat)
  local cv = { art = {} }
  local corner = M().corner
  local inset = floor(corner * 0.3 + 0.5)
  local function piece(token, layer, sub, h, v)
    local path = resolve(token)
    if not path then return nil end
    local t = newTex(frame, layer, sub)
    if not setTex(t, path, h, v) then t:Hide(); return nil end
    cv.art[token] = t
    return t
  end
  local page = piece("cover-page", "BACKGROUND", -6, "REPEAT", "REPEAT")
  if page then
    page:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
    page:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
    pcall(page.SetHorizTile, page, true)
    pcall(page.SetVertTile, page, true)
  end
  local vig = piece("cover-vignette", "BACKGROUND", -5)
  if vig then
    vig:SetPoint("TOPLEFT", frame, "TOPLEFT", inset, -inset)
    vig:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -inset, inset)
  end
  local corners = {}
  for _, c in ipairs({ { "cover-tl", "TOPLEFT" }, { "cover-tr", "TOPRIGHT" }, { "cover-bl", "BOTTOMLEFT" }, { "cover-br", "BOTTOMRIGHT" } }) do
    local t = piece(c[1], "BORDER", 0)
    if t then
      t:SetSize(corner, corner)
      t:SetPoint(c[2], frame, c[2], 0, 0)
      corners[c[2]] = t
    end
  end
  local top = piece("cover-top", "BORDER", -1, "REPEAT", "CLAMP")
  local bottom = piece("cover-bottom", "BORDER", -1, "REPEAT", "CLAMP")
  for _, e in ipairs({ { top, "TOP" }, { bottom, "BOTTOM" } }) do
    local t = e[1]
    if t then
      t:SetPoint(e[2] .. "LEFT", frame, e[2] .. "LEFT", corner, 0)
      t:SetPoint(e[2] .. "RIGHT", frame, e[2] .. "RIGHT", -corner, 0)
      t:SetHeight(corner)
      pcall(t.SetHorizTile, t, true)
    end
  end
  local left = piece("cover-left", "BORDER", -1, "CLAMP", "REPEAT")
  local right = piece("cover-right", "BORDER", -1, "CLAMP", "REPEAT")
  for _, e in ipairs({ { left, "LEFT" }, { right, "RIGHT" } }) do
    local t = e[1]
    if t then
      t:SetPoint("TOP" .. e[2], frame, "TOP" .. e[2], 0, -corner)
      t:SetPoint("BOTTOM" .. e[2], frame, "BOTTOM" .. e[2], 0, corner)
      t:SetWidth(corner)
      pcall(t.SetVertTile, t, true)
    end
  end
  local anyEdge = next(corners) or top or bottom or left or right
  if flat then
    local k = K()
    local s1 = k.stone1
    cv.flat = box(frame, (not page) and { s1[1], s1[2], s1[3], 0.95 } or nil, (not anyEdge) and k.stoneEdge or nil)
  end
  cv.hasArt = next(cv.art) ~= nil
  return cv
end

UI.ShellCoverTokens = { "cover-tl", "cover-tr", "cover-bl", "cover-br", "cover-top", "cover-bottom", "cover-left",
  "cover-right", "cover-page", "cover-vignette" }

---------------------------------------------------------------------------
-- Depth chrome (o.chrome = "dialog" | "portrait" | "flat"): a 12 px multi-band edge, corner brackets and an inset
-- content well, layered over whatever the chrome chain produced. Blizzard textures only, probed first.

UI.ShellChromeKinds = { dialog = true, portrait = true, flat = true }
UI.ShellTextures = {
  dialogBorder = "Interface\\DialogFrame\\UI-DialogBox-Border",
  dialogBg = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
  achParchment = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal",
  achParchmentAlt = "Interface\\AchievementFrame\\UI-Achievement-Parchment",
  achMetal = "Interface\\AchievementFrame\\UI-Achievement-MetalBorder-Left",
  achMetalJoint = "Interface\\AchievementFrame\\UI-Achievement-MetalBorder-Joint",
  achStatsBg = "Interface\\AchievementFrame\\UI-Achievement-StatsBackground",
}
UI.ShellParchmentCandidates = { "achParchment", "achParchmentAlt" }
-- v8 shell art geometry (o.titleArt / o.corners). titleTexCoord crops the converted logo_main TGA (512 x 256, art in
-- rows 18-238) back to its 800 x 344 source; cornerCoords mirror one top-left ornament into all four corners.
-- v9: titleWidth 280 -> 240 (it8: oversized, dead title-bar flanks); titleTuck = px the tab strip may ride under the
-- wordmark's bottom (its last ~8 px at 240 wide are a narrow centred tip). close* = the closeStyle "plate" geometry.
-- v10: titleTuck 3 -> 6 (it9: the wordmark crowded the tab row); flank* = the o.flankArt crest geometry.
UI.ShellArt = { titleWidth = 240, titleAspect = 344 / 800, titleLift = 10, titleTuck = 6,
  flankSize = 52, flankInset = 64, flankGap = 18, flankHalo = 60, flankHaloAlpha = 0.25,
  flankTokens = { left = { "crest_bloodsports" }, right = { "crest_elders", "crest_tournament" } },
  titleTexCoord = { 0, 1, 18 / 256, 238 / 256 },
  corner = 72, cornerCoords = { { "TOPLEFT", 0, 1, 0, 1 }, { "TOPRIGHT", 1, 0, 0, 1 }, { "BOTTOMLEFT", 0, 1, 1, 0 },
    { "BOTTOMRIGHT", 1, 0, 1, 0 } },
  closeSize = 24, closeStroke = 1.5, closeLen = 14 }

-- v9 o.closeStyle = "plate": dark plate (plateDarkFill, goldDim 1 px rim) with a gold X. The X is two thin gold bars
-- turned +-45 degrees (SetRotation under pcall, pixel snapping off so 1.5 px stays 1.5); when any rotation call is
-- missing or errors the bars go and a gold Cinzel / GameFont "X" is drawn instead. Hover washes the plate gold.
local function buildClosePlate(f)
  local k, A = K(), UI.ShellArt
  local b = CreateFrame("Button", nil, f)
  b:SetSize(A.closeSize, A.closeSize)
  local edge = newTex(b, "BACKGROUND", -8)
  edge:SetAllPoints(b)
  solid(edge, k.goldDim)
  local fill = newTex(b, "BACKGROUND", -7)
  fill:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
  local d = k.plateDarkFill
  solid(fill, { d[1], d[2], d[3], 1 })
  local wash = newTex(b, "ARTWORK", 0)
  wash:SetAllPoints(fill)
  local hv = k.plateGoldHover
  solid(wash, { hv[1], hv[2], hv[3], 0.18 })
  wash:Hide()
  b.edge, b.fill, b.wash = edge, fill, wash
  local strokes, rotated = {}, true
  for i, ang in ipairs({ math.pi / 4, -math.pi / 4 }) do
    local t = newTex(b, "OVERLAY", 0)
    solid(t, k.gold)
    t:SetSize(A.closeLen, A.closeStroke)
    t:SetPoint("CENTER", b, "CENTER", 0, 0)
    pcall(t.SetSnapToPixelGrid, t, false)
    pcall(t.SetTexelSnappingBias, t, 0)
    local ok = type(t.SetRotation) == "function" and pcall(t.SetRotation, t, ang)
    if not ok then rotated = false end
    strokes[i] = t
  end
  if rotated then
    b.strokes, b.mkGlyph = strokes, "strokes"
  else
    for _, t in ipairs(strokes) do t:Hide() end
    local x = b:CreateFontString(nil, "OVERLAY")
    UI.Display(x, 14, true)
    x:SetTextColor(UI.Unpack(k.gold))
    x:SetShadowOffset(1, -1)
    x:SetShadowColor(0, 0, 0, 1)
    x:SetPoint("CENTER", b, "CENTER", 0, 0)
    x:SetText("X")
    b.glyph, b.mkGlyph = x, "text"
  end
  b:SetScript("OnEnter", function() wash:Show() end)
  b:SetScript("OnLeave", function() wash:Hide() end)
  return b
end
UI.ShellClosePlate = buildClosePlate

-- What this client has, by UI.ShellTextures key plus the native templates the shell can use. Cheap after the first
-- call (probe results are cached). In-game: /run for k,v in pairs(MetaKit.UI.ShellProbe()) do print(k,v) end
function UI.ShellProbe()
  local out = {}
  for key, path in pairs(UI.ShellTextures) do out[key] = UI.ProbeTexture(path) and true or false end
  for _, tpl in ipairs({ "BackdropTemplate", "UIPanelButtonTemplate", "UIPanelScrollBarTemplate", "UIPanelCloseButton",
      "PortraitFrameTemplate" }) do
    out[tpl] = UI.HasTemplate(tpl)
  end
  return out
end

-- Outer -> inner, 12 px: black hairline, stone, gold-dim rule, stone body, deep-gold rule, inner shadow.
local function bandSpec()
  local k = K()
  return { { 1, { 0, 0, 0, 0.95 } }, { 2, k.stone3 }, { 1, k.goldDim }, { 5, k.stone2 },
    { 1, { k.goldDeep[1], k.goldDeep[2], k.goldDeep[3], 0.7 } }, { 2, { 0, 0, 0, 0.6 } } }
end
UI.ShellBandSpec = bandSpec

-- Nested 1-sided outlines on `frame`; returns the textures and the total thickness.
local function rim(frame, bands)
  local out, off = {}, 0
  for i, b in ipairs(bands) do
    local t, c = b[1], b[2]
    local sub = min(7, i - 8)
    local top = newTex(frame, "BORDER", sub)
    top:SetPoint("TOPLEFT", frame, "TOPLEFT", off, -off)
    top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -off, -off)
    top:SetHeight(t)
    local bottom = newTex(frame, "BORDER", sub)
    bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", off, off)
    bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -off, off)
    bottom:SetHeight(t)
    local left = newTex(frame, "BORDER", sub)
    left:SetPoint("TOPLEFT", frame, "TOPLEFT", off, -(off + t))
    left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", off, off + t)
    left:SetWidth(t)
    local right = newTex(frame, "BORDER", sub)
    right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -off, -(off + t))
    right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -off, off + t)
    right:SetWidth(t)
    for _, tx in ipairs({ top, bottom, left, right }) do solid(tx, c); out[#out + 1] = tx end
    off = off + t
  end
  return out, off
end

-- Corner brackets: a 2 px gold-dim L (m.bracket long) per corner, `inset` px in from the corner (4 over the code
-- band, inside the metal over the dialog border), with a 4 px gold rivet.
local function brackets(frame, inset)
  local k, len = K(), M().bracket or 24
  local d = inset or 4
  local out = {}
  for _, c in ipairs({ { "TOPLEFT", 1, -1 }, { "TOPRIGHT", -1, -1 }, { "BOTTOMLEFT", 1, 1 }, { "BOTTOMRIGHT", -1, 1 } }) do
    local pt, sx, sy = c[1], c[2], c[3]
    local h = newTex(frame, "ARTWORK", 1)
    h:SetSize(len, 2)
    h:SetPoint(pt, frame, pt, d * sx, d * sy)
    solid(h, k.goldDim)
    local v = newTex(frame, "ARTWORK", 1)
    v:SetSize(2, len)
    v:SetPoint(pt, frame, pt, d * sx, d * sy)
    solid(v, k.goldDim)
    local rivet = newTex(frame, "ARTWORK", 2)
    rivet:SetSize(4, 4)
    rivet:SetPoint(pt, frame, pt, d * sx, d * sy)
    solid(rivet, k.goldDeep)
    out[#out + 1] = { h = h, v = v, rivet = rivet }
  end
  return out
end

-- The classic dialog border as a backdrop on `frame` (BackdropTemplate or a native SetBackdrop). Bronze-gold tint
-- over the stock silver metal (v4: brighter than v3's 0.80 / 0.68 / 0.45, which read as one flat line). Returns true
-- when it took.
UI.ShellDialogTint = { 0.85, 0.68, 0.38, 1 }
local function dialogBackdrop(frame, tint)
  if not frame.SetBackdrop and BackdropTemplateMixin and type(Mixin) == "function" then
    pcall(Mixin, frame, BackdropTemplateMixin)
  end
  if type(frame.SetBackdrop) ~= "function" then return false end
  local T = UI.ShellTextures
  local bg = UI.ProbeTexture(T.dialogBg) and T.dialogBg or nil
  local ok = pcall(frame.SetBackdrop, frame, { bgFile = bg, edgeFile = T.dialogBorder, tile = true, tileSize = 32,
    edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } })
  if not ok then return false end
  tint = tint or UI.ShellDialogTint
  pcall(frame.SetBackdropBorderColor, frame, tint[1], tint[2], tint[3], tint[4] or 1)
  if bg then pcall(frame.SetBackdropColor, frame, 1, 1, 1, 0.9) end
  return true
end

-- Builds shell.depth on the frame. `native` = a portrait template is underneath (the band then starts below its
-- title bar, inside its edge, and the template's own edge art stays on top).
local function buildDepth(shell, kind, o, base)
  local f, m = shell.frame, M()
  local d = { kind = kind, dialogBorder = false }
  local host
  if kind == "dialog" then
    local ok, fr = pcall(CreateFrame, "Frame", nil, f, "BackdropTemplate")
    host = ok and fr or CreateFrame("Frame", nil, f)
    host:SetAllPoints(f)
    if UI.ProbeTexture(UI.ShellTextures.dialogBorder) then d.dialogBorder = dialogBackdrop(host, o.chromeTint) end
  else
    host = CreateFrame("Frame", nil, f)
    if shell.native then
      host:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -21)
      host:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
    else
      host:SetAllPoints(f)
    end
  end
  pcall(host.SetFrameLevel, host, base + 2)
  d.host = host
  if not d.dialogBorder then
    d.bands, d.thickness = rim(host, bandSpec())
    d.brackets = brackets(host, 4)
  else
    d.thickness = m.band or 12
    d.brackets = brackets(host, m.band or 12) -- inside the metal, where the art leaves the corner bare
  end
  -- inset content well: wraps sidebar + pane (anchored in LayoutBody), rim 4 px; recessed = dark fill, shadow on
  -- the top / left inner edge, a faint highlight on the bottom / right one, gold-dim outer line
  local well = CreateFrame("Frame", nil, f)
  pcall(well.SetFrameLevel, well, base + 2)
  local k = K()
  local wb = box(well, { 0, 0, 0, 0.35 }, { k.goldDim[1], k.goldDim[2], k.goldDim[3], 0.5 })
  local function line(p1, p2, x1, y1, x2, y2, horiz, c)
    local t = newTex(well, "BORDER", -6)
    t:SetPoint(p1, well, p1, x1, y1)
    t:SetPoint(p2, well, p2, x2, y2)
    if horiz then t:SetHeight(1) else t:SetWidth(1) end
    solid(t, c)
    return t
  end
  wb.shadeTop = line("TOPLEFT", "TOPRIGHT", 1, -1, -1, -1, true, { 0, 0, 0, 0.8 })
  wb.shadeLeft = line("TOPLEFT", "BOTTOMLEFT", 1, -1, 1, 1, false, { 0, 0, 0, 0.8 })
  wb.lightBottom = line("BOTTOMLEFT", "BOTTOMRIGHT", 1, 1, -1, 1, true, { k.parch[1], k.parch[2], k.parch[3], 0.10 })
  wb.lightRight = line("TOPRIGHT", "BOTTOMRIGHT", -1, -1, -1, 1, false, { k.parch[1], k.parch[2], k.parch[3], 0.10 })
  d.well, d.wellParts = well, wb
  return d
end

-- Drop shadow (dialog / flat chrome): a plain black texture m.shadowGrow px larger than the window on every side and
-- m.shadowDrop px lower, alpha m.shadowAlpha, on the window's own lowest layer so every child frame draws over it.
-- Returns nil when any call errors (no shadow; nothing else changes).
local function buildShadow(f)
  local m = M()
  local g, dy, a = m.shadowGrow or 6, m.shadowDrop or 6, m.shadowAlpha or 0.45
  local ok, t = pcall(f.CreateTexture, f, nil, "BACKGROUND", nil, -8)
  if not ok or type(t) ~= "table" then return nil end
  local placed = pcall(function()
    t:SetPoint("TOPLEFT", f, "TOPLEFT", -g, g - dy)
    t:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", g, -g - dy)
  end)
  local painted = placed and ((setTex(t, WHITE) and pcall(t.SetVertexColor, t, 0, 0, 0, a))
    or pcall(t.SetColorTexture, t, 0, 0, 0, a))
  if not painted then pcall(t.Hide, t); return nil end
  t.mkShadow = { grow = g, drop = dy, alpha = a }
  return t
end
UI.ShellBuildShadow = buildShadow

---------------------------------------------------------------------------
-- Shell

local function addSpecial(name)
  if not name or type(UISpecialFrames) ~= "table" then return end
  for _, n in ipairs(UISpecialFrames) do if n == name then return end end
  tinsert(UISpecialFrames, name)
end

local function addonLoaded(owner)
  if not owner then return true end
  local fn = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
  if type(fn) ~= "function" then return true end
  local ok, loaded = pcall(fn, owner)
  if not ok then return true end
  return loaded and true or false
end
UI.ShellAddonLoaded = addonLoaded

local function byOrder(a, b)
  if (a.order or 0) ~= (b.order or 0) then return (a.order or 0) < (b.order or 0) end
  return a.seq < b.seq
end

-- A template child (frame / region) or nil: anything that is not a table is treated as absent.
local function part(t, ...)
  for i = 1, select("#", ...) do
    if type(t) ~= "table" then return nil end
    t = t[(select(i, ...))]
  end
  return type(t) == "table" and t or nil
end

local function createChrome(name, plainOnly)
  if not plainOnly then
    for _, tpl in ipairs({ "PortraitFrameTemplate", "PortraitFrameFlatTemplate" }) do
      local ok, f = pcall(CreateFrame, "Frame", name, UIParent, tpl)
      if ok and f then return f, tpl end
    end
  end
  return CreateFrame("Frame", name, UIParent), nil
end

-- UIPanelButtonTemplate when the client has it (probe first), else nil; the caller keeps its plate.
local function nativeButton(parent, text, h)
  if UI.HasTemplate("UIPanelButtonTemplate") == false then return nil end
  local ok, b = pcall(CreateFrame, "Button", nil, parent, "UIPanelButtonTemplate")
  if not ok or not b then return nil end
  pcall(b.SetText, b, text or "")
  pcall(b.SetHeight, b, h)
  return b
end
UI.ShellNativeButton = nativeButton

local function savePos(shell)
  local db, f = shell.db, shell.frame
  if not db then return end
  local point, _, rel, x, y = f:GetPoint(1)
  if not point then return end
  db.pos = { point, rel or point, floor((x or 0) * 10 + 0.5) / 10, floor((y or 0) * 10 + 0.5) / 10 }
end

local Shell = {}
Shell.__index = Shell

function UI.Shell(o)
  o = o or {}
  local m, k = M(), K()
  local name = o.name or "WorldOfMetaShell"
  local db = type(o.db) == "table" and o.db or {}
  db.sections = type(db.sections) == "table" and db.sections or {}
  local shell = setmetatable({ name = name, db = db, tabs = {}, tabById = {}, sections = {}, seq = 0,
    current = nil, lastError = false, opts = o }, Shell)

  local kind = UI.ShellChromeKinds[o.chrome] and o.chrome or nil -- nil keeps the v2 chrome exactly
  local f, tpl = createChrome(name, kind == "dialog" or kind == "flat")
  shell.frame, shell.template = f, tpl
  shell.chrome = tpl and "portrait" or "plain"
  shell.chromeKind = kind
  local native = tpl ~= nil
  local base = (f.GetFrameLevel and f:GetFrameLevel()) or 1

  local defW = o.compact and m.compactWidth or (o.width or m.width)
  local defH = o.compact and m.compactHeight or (o.height or m.height)
  local w = UI.clamp(tonumber(db.width) or defW, MIN_W, 4000)
  local h = UI.clamp(tonumber(db.height) or defH, MIN_H, 3000)
  shell.defaultWidth, shell.defaultHeight = defW, defH
  shell.sidebarWidth = o.sidebarWidth or (o.compact and m.compactSidebar) or m.sidebar
  f:SetSize(w, h)
  f:SetFrameStrata("HIGH")
  f:SetToplevel(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  pcall(f.SetResizable, f, true)
  if f.SetResizeBounds then pcall(f.SetResizeBounds, f, MIN_W, MIN_H) elseif f.SetMinResize then pcall(f.SetMinResize, f, MIN_W, MIN_H) end
  local pos = db.pos
  if type(pos) == "table" and type(pos[1]) == "string" then
    f:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end

  -- template title goes clear; ours is drawn in Cinzel on the title host. A plain frame under depth chrome gets its
  -- own text host above the depth layer (the dialog backdrop's body would cover text drawn on the frame itself).
  local titleBox = native and part(f, "TitleContainer") or nil
  local tt = part(f, "TitleContainer", "TitleText") or part(f, "TitleText")
  if tt then
    pcall(tt.SetText, tt, "")
    pcall(tt.SetAlpha, tt, 0)
  end
  local resolve = artResolver(o)
  -- v8 art options: true resolves the token (MK.UI.Art(o.ns, token), or o.art), a string is used as the path
  local function artOpt(v, token)
    if v == true then return resolve(token) end
    if type(v) == "string" and v ~= "" then return v end
    return nil
  end
  local textHost = f
  if kind and not native then
    textHost = CreateFrame("Frame", nil, f)
    textHost:SetAllPoints(f)
    pcall(textHost.SetFrameLevel, textHost, base + 4)
  end
  shell.textHost = textHost
  local host = titleBox or textHost
  local title = host:CreateFontString(nil, "OVERLAY")
  UI.Display(title, m.titleSize or 20, true)
  title:SetTextColor(UI.Unpack(k.title))
  title:SetShadowOffset(m.titleShadowX or 2, m.titleShadowY or -2)
  title:SetShadowColor(UI.Unpack(k.titleShadow))
  title:SetText(o.title or "")
  if native and tt then title:SetPoint("CENTER", tt, "CENTER", 0, 0)
  elseif native then title:SetPoint("TOP", f, "TOP", 0, -2)
  elseif kind then title:SetPoint("TOP", f, "TOP", 0, -((m.band or 12) + 4))
  else title:SetPoint("TOP", f, "TOP", 0, -8) end
  shell.title = title

  -- portrait (native chrome only)
  local hasPortrait = false
  if native then
    local p
    if type(f.GetPortrait) == "function" then
      local ok, r = pcall(f.GetPortrait, f)
      if ok and type(r) == "table" then p = r end
    end
    p = p or part(f, "PortraitContainer", "portrait") or part(f, "portrait")
    if p and type(p.SetTexture) == "function" then
      hasPortrait = true
      -- v8: o.portraitArt fills the socket (the template's own portrait mask clips it); else the v2 portrait
      local pArt = artOpt(o.portraitArt, "logo_m")
      if pArt and setTex(p, pArt) then
        pcall(p.SetTexCoord, p, 0, 1, 0, 1)
        shell.portraitArt = pArt
      elseif not setTex(p, o.portrait or UI.Tex.unknown) then setTex(p, UI.Tex.unknown) end
      shell.portrait = p
    end
  end
  local leftX = hasPortrait and 62 or m.margin
  shell.native, shell.hasPortrait, shell.leftX = native, hasPortrait, leftX

  -- subtitle sits under the title band (placed by LayoutBody); nil / "" collapses its row
  local sub = textHost:CreateFontString(nil, "OVERLAY")
  UI.SetFont(sub, "small")
  sub:SetTextColor(UI.Unpack(k.parch))
  sub:SetShadowOffset(1, -1)
  sub:SetShadowColor(0, 0, 0, 1)
  sub:SetJustifyH("LEFT")
  sub:SetText(o.subtitle or "")
  sub:SetShown(o.subtitle ~= nil and o.subtitle ~= "")
  shell.subtitle = sub

  -- cover: plain chrome always (art or flat), native chrome only when art is registered
  local coverHost = CreateFrame("Frame", nil, f)
  if native then
    coverHost:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -21)
    coverHost:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  else
    coverHost:SetAllPoints(f)
  end
  pcall(coverHost.SetFrameLevel, coverHost, base + 1)
  local anyArt = false
  for _, token in ipairs(UI.ShellCoverTokens) do if resolve(token) then anyArt = true break end end
  if not native or anyArt then shell.cover = drawCover(coverHost, resolve, not native) end
  shell.coverHost = coverHost
  if kind then shell.depth = buildDepth(shell, kind, o, base) end
  if kind then -- v5: portrait casts it too
    local ok, t = pcall(buildShadow, f)
    shell.shadow = ok and t or nil
  end

  -- title band: drag handle
  local band = CreateFrame("Frame", nil, f)
  band:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  band:SetPoint("TOPRIGHT", f, "TOPRIGHT", -32, 0)
  band:SetHeight(m.titleBand)
  pcall(band.SetFrameLevel, band, base + 2)
  band:EnableMouse(true)
  band:RegisterForDrag("LeftButton")
  band:SetScript("OnMouseDown", function() f:Raise() end)
  band:SetScript("OnDragStart", function() f:StartMoving() end)
  band:SetScript("OnDragStop", function() f:StopMovingOrSizing(); savePos(shell) end)
  shell.titleBand = band
  function shell:SavePosition() savePos(self) end

  -- close: the template's own, else UIPanelCloseButton, else a small dark plate
  local close = native and part(f, "CloseButton") or nil
  if not close then
    local ok, b = pcall(CreateFrame, "Button", nil, f, "UIPanelCloseButton")
    if ok and b then
      close = b
      close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    else
      close = UI.Plate(f, { text = "X", width = 22, height = 22 })
      close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
    end
    pcall(close.SetFrameLevel, close, base + EDGE_LEVEL)
  end
  shell.closeStyle = "native"
  if o.closeStyle == "plate" then
    -- v9: the plate takes the stock close's spot (centred on it), else the plain-chrome plate spot
    local ok, plate = pcall(buildClosePlate, f)
    if ok and plate then
      local placed = pcall(function()
        if close.GetNumPoints and close:GetNumPoints() > 0 then plate:SetPoint("CENTER", close, "CENTER", 0, 0)
        else plate:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8) end
      end)
      if not placed then plate:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8) end
      pcall(close.Hide, close)
      pcall(plate.SetFrameLevel, plate, base + EDGE_LEVEL)
      shell.nativeClose, close, shell.closeStyle = close, plate, "plate"
    end
  end
  close:SetScript("OnClick", function() f:Hide() end)
  shell.closeButton = close

  -- v8 art: o.corners (4 mirrored ornaments) above the border and the template's edge art, o.titleArt (wordmark)
  -- above the corners; the close button is lifted over both. Any failing call leaves that piece off.
  local A = UI.ShellArt
  local artLevel = base + EDGE_LEVEL - 2
  -- v9: "all" / "bottom" are modes of the token art, any other string is a path (all four)
  local cornerMode = o.corners == "bottom" and "bottom" or "all"
  local cornerPath
  if o.corners == "bottom" or o.corners == "all" then cornerPath = resolve("ornament_corner")
  else cornerPath = artOpt(o.corners, "ornament_corner") end
  if cornerPath then
    local okH, host = pcall(CreateFrame, "Frame", nil, f)
    local ok, made = false, nil
    if okH then ok, made = pcall(function()
      host:SetAllPoints(f)
      pcall(host.SetFrameLevel, host, artLevel)
      local out = {}
      for _, c in ipairs(A.cornerCoords) do
        if cornerMode == "all" or c[1]:find("^BOTTOM") then
        local t = newTex(host, "ARTWORK")
        if not setTex(t, cornerPath) then error("corner texture") end
        t:SetSize(A.corner, A.corner)
        t:SetPoint(c[1], f, c[1], 0, 0)
        t:SetTexCoord(c[2], c[3], c[4], c[5])
        out[#out + 1] = t
        end
      end
      return out
    end) end
    if ok then shell.corners = { host = host, textures = made, path = cornerPath, mode = cornerMode }
    elseif okH and type(host) == "table" then pcall(host.Hide, host) end
  end
  local titlePath = artOpt(o.titleArt, "logo_main")
  if titlePath then
    local okH, host = pcall(CreateFrame, "Frame", nil, f)
    local w = A.titleWidth
    local h = floor(w * A.titleAspect + 0.5)
    local tc = o.titleArt == true and A.titleTexCoord or nil -- crop the pow2 padding of the converted logo_main
    local ok, t = false, nil
    if okH then ok, t = pcall(function()
      host:SetAllPoints(f)
      pcall(host.SetFrameLevel, host, artLevel + 1)
      local t = newTex(host, "ARTWORK")
      if not setTex(t, titlePath) then error("title texture") end
      t:SetSize(w, h)
      t:SetPoint("TOP", f, "TOP", 0, A.titleLift)
      if tc then t:SetTexCoord(tc[1], tc[2], tc[3], tc[4]) end
      return t
    end) end
    if ok then
      title:Hide()
      shell.titleArt = { host = host, texture = t, path = titlePath, width = w, height = h,
        bottom = h - A.titleLift - (A.titleTuck or 0) }
    elseif okH and type(host) == "table" then
      pcall(host.Hide, host)
    end
  end
  -- v10 o.flankArt: crests either side of the wordmark, one level under it; placed by LayoutBody (band centre)
  if type(o.flankArt) == "table" then
    local okH, host = pcall(CreateFrame, "Frame", nil, f)
    if okH and type(host) == "table" then
      local fl = { host = host }
      pcall(host.SetAllPoints, host, f)
      pcall(host.SetFrameLevel, host, artLevel)
      local function pick(v, side)
        local list
        if v == true then list = A.flankTokens and A.flankTokens[side] or {}
        elseif type(v) == "string" then list = { v }
        elseif type(v) == "table" then list = v
        else return nil end
        for _, name in ipairs(list) do
          if type(name) == "string" and name ~= "" then
            local path = name:find("[\\/]") and name or resolve(name)
            if path then return path, name end
          end
        end
        return nil
      end
      for _, side in ipairs({ "left", "right" }) do
        local path, name = pick(o.flankArt[side], side)
        if path then
          local ok, t = pcall(function()
            local t = newTex(host, "ARTWORK", 1)
            if not setTex(t, path) then error("flank texture") end
            t:SetSize(A.flankSize, A.flankSize)
            return t
          end)
          if ok and t then
            -- v11 halo: the same crest, larger and faint, one sublevel under it; skipped if it fails
            local okH2, h = pcall(function()
              local h = newTex(host, "ARTWORK", -1)
              if not setTex(h, path) then pcall(h.Hide, h); error("halo texture") end
              h:SetSize(A.flankHalo, A.flankHalo)
              h:SetAlpha(A.flankHaloAlpha)
              h:SetPoint("CENTER", t, "CENTER", 0, 0)
              return h
            end)
            fl[side] = { texture = t, path = path, token = name, halo = okH2 and h or nil }
          elseif type(t) == "table" then pcall(t.Hide, t) end
        end
      end
      if fl.left or fl.right then shell.flanks = fl else pcall(host.Hide, host) end
    end
  end
  if shell.corners or shell.titleArt or shell.flanks then
    local okL, lvl = pcall(close.GetFrameLevel, close)
    if not okL or type(lvl) ~= "number" or lvl < base + EDGE_LEVEL then pcall(close.SetFrameLevel, close, base + EDGE_LEVEL) end
  end

  -- layout regions: sidebar + content pane share one top edge (LayoutBody); the tab strip sits on the pane's top
  -- edge, its tabs overlapping the pane border by m.tabOverlap. Depth chrome adds m.depthInset (band + well rim).
  local inL = kind and (m.depthInset or 8) or (native and 4 or 0)
  shell.inset = inL

  local side = CreateFrame("Frame", nil, f)
  side:SetWidth(shell.sidebarWidth)
  pcall(side.SetFrameLevel, side, base + 3)
  local s0 = k.stone0
  box(side, { s0[1], s0[2], s0[3], 0.6 }, k.stoneEdge)
  shell.sidebar = side

  -- sidebar material (o.sidebar = "parchment" | "flat"): nav rows replace the plates; parchment is the Achievement
  -- parchment darkened by k.parchTint, and drops to "flat" when no candidate texture exists
  local mat = (o.sidebar == "parchment" or o.sidebar == "flat") and o.sidebar or nil
  if mat == "parchment" then
    local path
    for _, key in ipairs(UI.ShellParchmentCandidates) do
      local p = UI.ShellTextures[key]
      if p and UI.ProbeTexture(p) then path = p break end
    end
    local tex = path and newTex(side, "BACKGROUND", -7) or nil
    if tex and setTex(tex, path) then
      tex:SetPoint("TOPLEFT", side, "TOPLEFT", 1, -1)
      tex:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", -1, 1)
      local t = k.parchTint
      pcall(tex.SetVertexColor, tex, t[1], t[2], t[3], t[4] or 1)
      shell.sidebarTexture = tex
    else
      if tex then tex:Hide() end
      mat = "flat"
    end
  end
  shell.sidebarMaterial, shell.navRows = mat, mat ~= nil
  -- dark ink for every sidebar text on parchment (SiteTokens.sidebarInk, single keys overridable by o.sidebarInk);
  -- nil on a flat sidebar, which keeps its light text
  if mat == "parchment" then
    local ink = {}
    for key, c in pairs(k.sidebarInk or {}) do ink[key] = c end
    if type(o.sidebarInk) == "table" then
      for key, c in pairs(o.sidebarInk) do if type(c) == "table" then ink[key] = c end end
    end
    shell.ink = ink
    -- v7: the summary block's own parchment palette (SiteTokens.summaryInk), with the o.sidebarInk summary keys on top
    local sink = {}
    for key, c in pairs(k.summaryInk or {}) do sink[key] = c end
    local so = type(o.sidebarInk) == "table" and o.sidebarInk or {}
    local map = { label = "summaryLabel", value = "value", good = "good", bad = "bad", focal = "focal" }
    for key, from in pairs(map) do if type(so[from]) == "table" then sink[key] = so[from] end end
    shell.summaryInk = sink
  end

  local pane = CreateFrame("Frame", nil, f)
  pcall(pane.SetFrameLevel, pane, base + 3)
  box(pane, { s0[1], s0[2], s0[3], 0.6 }, k.stoneEdge)
  shell.content = pane

  local strip = CreateFrame("Frame", nil, f)
  strip:SetPoint("BOTTOMLEFT", pane, "TOPLEFT", PANE_PAD, -(m.tabOverlap or 2))
  strip:SetPoint("BOTTOMRIGHT", pane, "TOPRIGHT", -PANE_PAD, -(m.tabOverlap or 2))
  strip:SetHeight(m.tab or 24)
  pcall(strip.SetFrameLevel, strip, base + 8) -- above the pane and its section hosts
  shell.tabStrip = strip

  -- optional footer on the sidebar bottom (o.footerText / o.onFooter), with a gold rule above it: a plate, or with
  -- o.nativeButtons the client's UIPanelButtonTemplate when it exists (probe first, plate otherwise)
  local footH = shell.navRows and (m.navRow or 26) or ROW_H
  shell.footerHeight = footH
  if o.footerText then
    local function fire(btn, button) if type(o.onFooter) == "function" then o.onFooter(shell, btn, button) end end
    local foot = o.nativeButtons and nativeButton(side, o.footerText, footH) or nil
    if foot then
      foot:SetScript("OnClick", function(self, button) fire(self, button) end)
      if o.footerTooltip then
        pcall(foot.HookScript, foot, "OnEnter", function(self) UI.ShowTip(self, o.footerTooltip, "ANCHOR_RIGHT") end)
        pcall(foot.HookScript, foot, "OnLeave", function() UI.HideTip() end)
      end
      shell.footerNative = true
    else
      -- v7: o.footerVariant = "dark" -> a dark plate with a gold label (beats footerKind); otherwise footerKind as before
      local darkGold = o.footerVariant == "dark"
      foot = UI.Plate(side, { kind = (not darkGold and o.footerKind == "gold") and "gold" or "dark", text = o.footerText,
        icon = o.footerIcon, height = footH, width = shell.sidebarWidth - 2 * SIDE_PAD,
        justify = o.footerIcon and "LEFT" or "CENTER", tooltip = o.footerTooltip, onClick = fire,
        labelColor = darkGold and K().gold or nil })
      shell.footerVariant = darkGold and "dark" or foot.kind
      shell.footerNative = false
    end
    foot:SetPoint("BOTTOMLEFT", side, "BOTTOMLEFT", SIDE_PAD, SIDE_PAD)
    foot:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", -SIDE_PAD, SIDE_PAD)
    pcall(foot.SetFrameLevel, foot, base + 6)
    local rule = newTex(side, "ARTWORK", 0)
    rule:SetHeight(1)
    rule:SetPoint("BOTTOMLEFT", side, "BOTTOMLEFT", SIDE_PAD, SIDE_PAD + footH + FOOT_GAP)
    rule:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", -SIDE_PAD, SIDE_PAD + footH + FOOT_GAP)
    solid(rule, mat == "parchment" and K().goldDeep or K().goldDim)
    shell.footer, shell.footerRule = foot, rule
  end

  shell:LayoutBody()

  local empty = pane:CreateFontString(nil, "OVERLAY")
  UI.SetFont(empty, "body")
  empty:SetTextColor(UI.Unpack(UI.Tokens.muted))
  empty:SetPoint("CENTER", pane, "CENTER", 0, 0)
  empty:Hide()
  shell.emptyText = empty

  -- resize grip (bottom-right), remembers db.width / db.height
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
  pcall(grip.SetFrameLevel, grip, base + EDGE_LEVEL + 2)
  pcall(grip.SetNormalTexture, grip, "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  pcall(grip.SetPushedTexture, grip, "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  pcall(grip.SetHighlightTexture, grip, "Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:RegisterForDrag("LeftButton")
  grip:SetScript("OnDragStart", function() pcall(f.StartSizing, f, "BOTTOMRIGHT") end)
  grip:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    shell:SetSize(f:GetWidth(), f:GetHeight())
    savePos(shell)
  end)
  shell.grip = grip

  f:HookScript("OnShow", function() UI.Sound("open"); shell.showCount = (shell.showCount or 0) + 1; shell:Refresh() end)
  f:HookScript("OnHide", function() UI.Sound("close") end)
  addSpecial(name)
  f:Hide()
  return shell
end

---------------------------------------------------------------------------
-- Shell methods

function Shell:Show() self.frame:Show() end
function Shell:Hide() self.frame:Hide() end
function Shell:IsShown() return self.frame:IsShown() and true or false end
function Shell:SetTitle(t) self.title:SetText(t or "") end
function Shell:SetSubtitle(t)
  self.subtitle:SetText(t or "")
  self.subtitle:SetShown(t ~= nil and t ~= "")
  self:LayoutBody()
end

-- Vertical rhythm, top down: title bar | subtitle row (only when shown) | tab strip | pane. Every step is one
-- m.gap-sized gap; with a portrait the body clears its bottom edge. Sets self.bodyTop (pane / sidebar top, px).
-- Depth chrome: the title bar ends below the band (native: band under the template bar; plain: band + 4 + title 20
-- + 4) and the well hugs sidebar + pane with an m.wellPad rim.
function Shell:LayoutBody()
  local m, f = M(), self.frame
  local inL = self.inset or 0
  local top0 = self.native and 22 or 36   -- bottom of the title bar
  if self.depth then top0 = self.native and 36 or ((m.band or 12) + 4 + (m.titleSize or 20) + 4) end
  local y = top0
  self.subtitle:ClearAllPoints()
  if self.subtitle:IsShown() then
    self.subtitle:SetPoint("TOPLEFT", f, "TOPLEFT", self.leftX or m.margin, -(top0 + 4))
    y = top0 + 4 + SUB_H
  end
  local tabTop = y + m.gap
  local bodyTop = tabTop + (m.tab or 24) - (m.tabOverlap or 2)
  if self.hasPortrait then bodyTop = max(bodyTop, 58) end
  -- v8: the title art hangs below the title band; the tab strip starts m.gap under it
  local art = self.titleArt
  if art then bodyTop = max(bodyTop, art.bottom + m.gap + (m.tab or 24) - (m.tabOverlap or 2)) end
  self.bodyTop, self.tabTop = bodyTop, bodyTop - (m.tab or 24) + (m.tabOverlap or 2)
  -- v10: flank crests centred in the title band (frame top -> tab strip top) at the fixed side insets
  -- v11: with title art, anchored to the wordmark instead (flankGap px outside its left / right edge)
  local fl = self.flanks
  if fl then
    local A, cy = UI.ShellArt, self.tabTop / 2
    local logo = art and art.texture
    for side, spec in pairs({ left = { "LEFT", "TOPLEFT", 1, "RIGHT" }, right = { "RIGHT", "TOPRIGHT", -1, "LEFT" } }) do
      local t = fl[side] and fl[side].texture
      if t then pcall(function()
        t:ClearAllPoints()
        if logo then
          -- the logo's TOP sits titleLift px above the frame top
          t:SetPoint(spec[4], logo, spec[2], -spec[3] * (A.flankGap or 18), -(cy + (A.titleLift or 0)))
        else
          t:SetPoint(spec[1], f, spec[2], spec[3] * A.flankInset, -cy)
        end
      end) end
    end
  end
  local side, pane = self.sidebar, self.content
  side:ClearAllPoints()
  side:SetPoint("TOPLEFT", f, "TOPLEFT", m.margin + inL, -bodyTop)
  side:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", m.margin + inL, m.margin + inL)
  pane:ClearAllPoints()
  pane:SetPoint("TOPLEFT", side, "TOPRIGHT", m.gap, 0)
  pane:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(m.margin + inL), m.margin + inL)
  local well = self.depth and self.depth.well
  if well then
    local p = m.wellPad or 4
    well:ClearAllPoints()
    well:SetPoint("TOPLEFT", side, "TOPLEFT", -p, p)
    well:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", p, -p)
  end
end

function Shell:SetSize(w, h)
  w = UI.clamp(floor((tonumber(w) or self.defaultWidth or M().width) + 0.5), MIN_W, 4000)
  h = UI.clamp(floor((tonumber(h) or self.defaultHeight or M().height) + 0.5), MIN_H, 3000)
  self.frame:SetSize(w, h)
  self.db.width, self.db.height = w, h
  self:Refresh()
end

function Shell:AddTab(o)
  o = o or {}
  if not o.id then return nil end
  local tab = self.tabById[o.id]
  if not tab then
    self.seq = self.seq + 1
    tab = { id = o.id, seq = self.seq }
    self.tabById[o.id] = tab
    tinsert(self.tabs, tab)
  end
  tab.label, tab.owner, tab.order = o.label or tostring(o.id), o.owner, o.order or tab.order or 0
  if o.summary ~= nil then tab.summary = o.summary end
  if o.extra ~= nil then tab.extra = o.extra end
  self.sections[o.id] = self.sections[o.id] or {}
  if tab.plate then tab.plate:SetText(tab.label) end
  if tab.heading then tab.heading:SetText(tab.label) end
  self:Refresh()
  return tab
end

function Shell:AddSection(o)
  o = o or {}
  if not (o.tab and o.id) then return nil end
  local list = self.sections[o.tab] or {}
  self.sections[o.tab] = list
  local sec
  for _, s in ipairs(list) do if s.id == o.id then sec = s end end
  if sec and sec.host then sec.host:Hide() end
  if not sec then
    self.seq = self.seq + 1
    sec = { id = o.id, tab = o.tab, seq = self.seq }
    tinsert(list, sec)
  end
  sec.label, sec.order, sec.icon, sec.build = o.label or tostring(o.id), o.order or 0, o.icon, o.build
  sec.onShow = type(o.onShow) == "function" and o.onShow or nil
  sec.built, sec.host, sec.frame, sec.shown, sec.buildCount = false, nil, nil, false, 0
  if self.notifiedSec == sec then self.notifiedSec = nil end
  local tab = self.tabById[o.tab]
  if tab then tab.dirty = true end
  self:Refresh()
  return sec
end

function Shell:RemoveTab(id)
  local tab = self.tabById[id]
  if not tab then return false end
  for i = #self.tabs, 1, -1 do if self.tabs[i] == tab then tremove(self.tabs, i) end end
  self.tabById[id] = nil
  if tab.plate then tab.plate:Hide() end
  if tab.side then tab.side:Hide() end
  for _, sec in ipairs(self.sections[id] or {}) do
    if sec.host then sec.host:Hide() end
    if sec.frame and sec.frame ~= sec.host then sec.frame:Hide() end
  end
  self.sections[id] = nil
  if self.current == id then self.current = nil end
  self:Refresh()
  return true
end

function Shell:VisibleTabs()
  local out = {}
  for _, tab in ipairs(self.tabs) do
    if addonLoaded(tab.owner) then out[#out + 1] = tab end
  end
  tsort(out, byOrder)
  return out
end

function Shell:SortedSections(tabId)
  local out = {}
  for _, s in ipairs(self.sections[tabId] or {}) do out[#out + 1] = s end
  tsort(out, byOrder)
  return out
end

local function findSection(list, id)
  for _, s in ipairs(list) do if s.id == id then return s end end
  return nil
end

-- Resolves the section to show for a tab: wanted -> remembered -> first.
function Shell:SectionFor(tabId, wanted)
  local list = self:SortedSections(tabId)
  return findSection(list, wanted) or findSection(list, self.db.sections[tabId]) or list[1]
end

function Shell:Select(tabId, sectionId)
  local tab = self.tabById[tabId or self.current or ""]
  if not tab or not addonLoaded(tab.owner) then return false end
  self.current = tab.id
  self.db.tab = tab.id
  local sec = self:SectionFor(tab.id, sectionId)
  if sec then self.db.sections[tab.id] = sec.id end
  self:Refresh()
  return true
end

-- Toggle(tabId, sectionId): hides the window when it already shows that tab (and, when a section is named, that
-- section); otherwise selects tab / section and shows it. Returns true when the window is shown afterwards.
function Shell:Toggle(tabId, sectionId)
  local f = self.frame
  if f:IsShown() and (tabId == nil or tabId == self.current)
      and (sectionId == nil or sectionId == self.currentSection) then
    f:Hide()
    return false
  end
  if tabId then self:Select(tabId, sectionId) end
  if not f:IsShown() then f:Show() else self:Refresh() end
  return true
end

-- Builds a section once, under pcall, into its own host frame in the content pane.
function Shell:BuildSection(sec)
  if sec.built then return sec.frame end
  sec.built = true
  local hostF = CreateFrame("Frame", nil, self.content)
  hostF:SetPoint("TOPLEFT", self.content, "TOPLEFT", PANE_PAD, -PANE_PAD)
  hostF:SetPoint("BOTTOMRIGHT", self.content, "BOTTOMRIGHT", -PANE_PAD, PANE_PAD)
  hostF:Hide()
  sec.host, sec.frame, sec.shown = hostF, hostF, false
  sec.buildCount = (sec.buildCount or 0) + 1
  if type(sec.build) == "function" then
    local ok, ret = pcall(sec.build, hostF)
    if not ok then
      sec.error = tostring(ret)
      self.lastError = sec.error
      local note = hostF:CreateFontString(nil, "OVERLAY")
      UI.SetFont(note, "body")
      note:SetTextColor(UI.Unpack(UI.Tokens.muted))
      note:SetPoint("CENTER", hostF, "CENTER", 0, 0)
      note:SetText("This section could not be built.")
      sec.note = note
    elseif type(ret) == "table" and ret.SetShown then
      sec.frame = ret
      if ret ~= hostF and ret.GetNumPoints and ret:GetNumPoints() == 0 then pcall(ret.SetAllPoints, ret, hostF) end
    end
  end
  return sec.frame
end

local function setSectionShown(sec, v)
  if not sec.host or sec.shown == v then return end
  sec.shown = v
  sec.host:SetShown(v)
  if sec.frame and sec.frame ~= sec.host then sec.frame:SetShown(v) end
end

-- Tab strip: one plate per visible tab, sized to its label (at least m.tabMin), labels m.tabLabel px. The current tab
-- is gold, m.tab high and open at the bottom, sitting over the pane's top border, with a pane-coloured joint over its
-- bottom m.tabOverlap px so the tab runs into the pane instead of sitting on its border line; the others are dark,
-- m.tabInactive high, resting on it.
local function setFontSize(fs, size)
  if not (fs and type(fs.GetFont) == "function" and type(fs.SetFont) == "function") then return false end
  local ok, face, _, flags = pcall(fs.GetFont, fs)
  if not ok or type(face) ~= "string" then return false end
  local ok2, res = pcall(fs.SetFont, fs, face, size, flags or "")
  return ok2 and res ~= false
end

function Shell:LayoutTabs(visible)
  local m = M()
  local x = 0
  local inStrip = {}
  local overlap = m.tabOverlap or 2
  for _, tab in ipairs(visible) do
    inStrip[tab] = true
    if not tab.plate then
      local shell = self
      local p = UI.Plate(self.tabStrip, { text = tab.label, height = m.tab or 28, minWidth = m.tabMin or 110,
        padX = m.tabPad or 16, onClick = function() shell:Select(tab.id) end })
      if setFontSize(p.label, m.tabLabel or 12) then
        p.labelSize = m.tabLabel or 12
        p:SetText(tab.label) -- re-measure the label at its new size
      end
      local j = newTex(p, "ARTWORK", 2)
      j:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 1, 0)
      j:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -1, 0)
      j:SetHeight(overlap)
      local s0 = K().stone0
      solid(j, { s0[1], s0[2], s0[3], 1 })
      j:Hide()
      p.joint = j
      tab.plate = p
    end
    local active = tab.id == self.current
    tab.plate:ClearAllPoints()
    tab.plate:SetHeight(active and (m.tab or 28) or (m.tabInactive or 24))
    tab.plate:SetPoint("BOTTOMLEFT", self.tabStrip, "BOTTOMLEFT", x, active and 0 or overlap)
    tab.plate:SetOpenBottom(active)
    tab.plate:SetKind(active and "gold" or "dark")
    if tab.plate.joint then tab.plate.joint:SetShown(active) end
    tab.plate:Show()
    x = x + (tab.plate:GetWidth() or m.tabMin or 110) + (m.tabGap or 4)
  end
  for _, tab in ipairs(self.tabs) do
    if tab.plate and not inStrip[tab] then tab.plate:Hide() end
  end
end

-- Nav row (material sidebar): flat 26 px row with a 16 px icon, a 3 px gold selection strip, a selection wash and a
-- 1 px separator. Same surface as a plate for LayoutSidebar: SetText / GetText / SetIcon / SetKind / kind / onClick.
-- `ink` = the shell's sidebar ink table on parchment (dark labels: labelSoft, selected near-black), nil on flat.
local function navRow(parent, ink)
  local m, k = M(), K()
  if ink and type(ink) ~= "table" then ink = k.sidebarInk or {} end -- v3 callers passed `true`
  local r = CreateFrame("Button", nil, parent)
  r:SetHeight(m.navRow or 26)
  r.kind, r.mkEnabled, r.ink = "dark", true, ink or false
  r.wash = newTex(r, "BACKGROUND", 1)
  r.wash:SetAllPoints(r)
  -- v6: parchment wash k.parchSelWash (0.22) and strip ink.strip (dark bronze gold); recorded for tests
  r.washColor = ink and (k.parchSelWash or { 0, 0, 0, 0.22 }) or { k.gold[1], k.gold[2], k.gold[3], 0.12 }
  solid(r.wash, r.washColor)
  r.hl = newTex(r, "HIGHLIGHT", 0)
  r.hl:SetAllPoints(r)
  solid(r.hl, ink and { 0, 0, 0, 0.08 } or { 1, 1, 1, 0.06 })
  r.strip = newTex(r, "ARTWORK", 1)
  r.strip:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 0)
  r.strip:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
  r.strip:SetWidth(m.navStrip or 3)
  r.stripColor = ink and (ink.strip or k.goldDeep) or k.gold
  solid(r.strip, r.stripColor)
  r.sep = newTex(r, "BORDER", 0)
  r.sep:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", 0, 0)
  r.sep:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, 0)
  r.sep:SetHeight(1)
  local s = k.inkSoft
  solid(r.sep, ink and { s[1], s[2], s[3], 0.25 } or k.listSep)
  local isz = m.navIcon or 16
  r.icon = newTex(r, "ARTWORK", 0)
  r.icon:SetSize(isz, isz)
  pcall(r.icon.SetTexCoord, r.icon, 0.07, 0.93, 0.07, 0.93)
  r.label = r:CreateFontString(nil, "OVERLAY")
  UI.SetFont(r.label, "body")
  r.label:SetWordWrap(false)
  r.label:SetJustifyH("LEFT")
  if ink then r.label:SetShadowOffset(0, 0) else r.label:SetShadowOffset(1, -1); r.label:SetShadowColor(0, 0, 0, 1) end
  local hasIcon = false
  local function layout()
    local dx, dy = r.pressed and 1 or 0, r.pressed and -1 or 0
    r.icon:ClearAllPoints()
    r.icon:SetPoint("LEFT", r, "LEFT", 8 + dx, dy)
    r.label:ClearAllPoints()
    r.label:SetPoint("LEFT", r, "LEFT", (hasIcon and (8 + isz + 8) or 12) + dx, dy)
    r.label:SetPoint("RIGHT", r, "RIGHT", -8 + dx, dy)
  end
  local function paint()
    local sel = r.kind == "gold"
    r.strip:SetShown(sel)
    r.wash:SetShown(sel)
    local c
    if ink then c = sel and (ink.selected or k.ink) or (ink.labelSoft or k.inkSoft) else c = sel and k.gold or k.parch end
    r.label:SetTextColor(UI.Unpack(c))
  end
  function r:SetText(t) self.label:SetText(t or "") end
  function r:GetText() return self.label:GetText() end
  function r:SetIcon(path)
    hasIcon = false
    if path and setTex(self.icon, path) then hasIcon = true
    elseif path then hasIcon = setTex(self.icon, UI.Tex.unknown) end
    self.icon:SetShown(hasIcon)
    layout()
  end
  function r:SetKind(kind) self.kind = kind == "gold" and "gold" or "dark"; paint() end
  function r:SetSelected(v) self:SetKind(v and "gold" or "dark") end
  function r:SetPressed(v)
    v = v and true or false
    if v ~= (self.pressed or false) then self.pressed = v; layout() end
  end
  r:RegisterForClicks("LeftButtonUp")
  r:SetScript("OnMouseDown", function(self) self:SetPressed(true) end)
  r:SetScript("OnMouseUp", function(self) self:SetPressed(false) end)
  r:SetScript("OnHide", function(self) self:SetPressed(false) end)
  -- hover changes only the HIGHLIGHT layer; the label colour is re-asserted on both edges so no hover / state
  -- change can leave a row in anything but its kind's ink
  r:SetScript("OnEnter", function() paint() end)
  r:SetScript("OnLeave", function() paint() end)
  r.Repaint = paint
  r:SetScript("OnClick", function(self, button)
    UI.Sound("click")
    if self.onClick then self.onClick(self, button) end
  end)
  layout()
  paint()
  return r
end
UI.ShellNavRow = navRow

-- Summary lines for a tab: tab.summary (AddTab{ summary = }) else o.summary; a function(shell, tabId) runs under
-- pcall. A line is a string, { label, value, color } or { label =, value =, color = } (color "good" | "bad" |
-- "gold" | {r,g,b,a}).
function Shell:SummaryLines(tab)
  local src = tab and tab.summary
  if src == nil then src = self.opts.summary end
  if type(src) == "function" then
    local ok, res = pcall(src, self, tab and tab.id)
    if not ok then self.lastError = tostring(res); return {} end
    src = res
  end
  if type(src) ~= "table" then return {} end
  local out = {}
  for _, line in ipairs(src) do
    if type(line) == "string" then out[#out + 1] = { text = line }
    elseif type(line) == "table" then
      local label, value = line.label or line[1], line.value or line[2]
      out[#out + 1] = { label = label ~= nil and tostring(label) or "", value = value ~= nil and tostring(value) or nil,
        color = line.color or line[3] }
    end
  end
  return out
end

-- `ink` = the shell's summary palette on parchment (shell.summaryInk: dark green / red / ink), nil on a flat sidebar.
local function summaryColor(c, ink)
  local k = K()
  if type(c) == "table" then return c end
  if c == "good" then return ink and ink.good or k.emerald end
  if c == "bad" then return ink and ink.bad or UI.Tokens.bad end
  if c == "gold" or c == "focal" then return ink and ink.focal or k.gold end
  return ink and ink.value or k.parch
end
UI.ShellSummaryColor = summaryColor

-- Distance from the sidebar bottom to the summary block's bottom: m.summaryGap above the footer's gold rule, or
-- SIDE_PAD above the sidebar edge when there is no footer.
function Shell:SummaryBottomOffset()
  if self.footer then
    return SIDE_PAD + (self.footerHeight or ROW_H) + FOOT_GAP + 1 + (M().summaryGap or 8)
  end
  return SIDE_PAD
end

-- Draws the summary block anchored to the sidebar BOTTOM (just above the footer), with a 1 px rule 8 px above its
-- first line. minTop = the highest point (px below the sidebar top) the block may reach without touching the
-- section rows; sideH = the sidebar height (0 when unknown: every line shows). Lines that do not fit are dropped
-- from the TOP of the block, never overlapping the sections. Sets tab.summaryShown (lines drawn), tab.summaryFirst
-- (index of the first drawn line) and, with a known height, tab.summaryTop (px below the sidebar top of the rule).
function Shell:LayoutSummary(tab, minTop, sideH)
  local m, k = M(), K()
  local ink = self.ink
  local sink = ink and (self.summaryInk or k.summaryInk or ink) or nil -- v7: the summary's own parchment palette
  local lines = self:SummaryLines(tab)
  local sm = tab.summaryUI
  if not sm then
    sm = { rows = {} }
    sm.rule = newTex(tab.side, "ARTWORK", 0)
    sm.rule:SetHeight(1)
    tab.summaryUI = sm
  end
  local lh = m.summaryLine or 16
  local n = #lines
  local bo = self:SummaryBottomOffset()
  local head = 1 + 8 -- the rule and the gap under it
  local keep = n
  if (sideH or 0) > 0 then
    keep = max(0, min(n, floor((sideH - bo - (minTop or 0) - head) / lh)))
  end
  local first = n - keep + 1
  local ruleY = bo + keep * lh + 8
  sm.rule:ClearAllPoints()
  sm.rule:SetPoint("BOTTOMLEFT", tab.side, "BOTTOMLEFT", SIDE_PAD, ruleY)
  sm.rule:SetPoint("BOTTOMRIGHT", tab.side, "BOTTOMRIGHT", -SIDE_PAD, ruleY)
  solid(sm.rule, ink and (ink.rule or k.goldDeep) or k.goldDim)
  sm.rule:SetShown(keep > 0)
  for i, line in ipairs(lines) do
    local r = sm.rows[i]
    if not r then
      r = { label = tab.side:CreateFontString(nil, "OVERLAY"), value = tab.side:CreateFontString(nil, "OVERLAY") }
      UI.SetFont(r.label, ink and "body" or "small") -- v5: 12 px ink labels on parchment; 10 px AA washed out
      UI.SetFont(r.value, "body")
      if ink then -- v7: force the px size on parchment (the font object's own size is client dependent)
        for _, fs in ipairs({ r.label, r.value }) do
          local okF, file, _, flags = pcall(fs.GetFont, fs)
          local px = k.summarySize or 12
          if okF and file then pcall(fs.SetFont, fs, file, px, flags or "") end
          fs.mkSize = px
        end
      end
      r.label:SetJustifyH("LEFT"); r.value:SetJustifyH("RIGHT")
      r.label:SetWordWrap(false); r.value:SetWordWrap(false)
      sm.rows[i] = r
    end
    for _, fs in ipairs({ r.label, r.value }) do
      if ink then fs:SetShadowOffset(0, 0) else fs:SetShadowOffset(1, -1); fs:SetShadowColor(0, 0, 0, 1) end
    end
    r.label:ClearAllPoints()
    r.value:ClearAllPoints()
    local yb = bo + (n - i) * lh -- bottom of line i; the last line sits on the block bottom
    r.label:SetPoint("BOTTOMLEFT", tab.side, "BOTTOMLEFT", SIDE_PAD + 4, yb)
    r.value:SetPoint("BOTTOMRIGHT", tab.side, "BOTTOMRIGHT", -(SIDE_PAD + 4), yb)
    if line.text then
      r.label:SetPoint("BOTTOMRIGHT", tab.side, "BOTTOMRIGHT", -(SIDE_PAD + 4), yb)
      r.label:SetText(line.text)
      r.value:SetText("")
    else
      r.label:SetText(line.label)
      r.value:SetText(line.value or "")
    end
    r.label:SetTextColor(UI.Unpack(sink and sink.label or UI.Tokens.muted)) -- v7: text lines too: summary label ink
    r.value:SetTextColor(UI.Unpack(summaryColor(line.color, sink)))
    local fits = i >= first
    r.label:SetShown(fits); r.value:SetShown(fits and not line.text)
  end
  for i = n + 1, #sm.rows do sm.rows[i].label:Hide(); sm.rows[i].value:Hide() end
  tab.summaryShown, tab.summaryFirst, tab.summaryLines = keep, first, lines
  tab.summaryTop = (sideH or 0) > 0 and (sideH - ruleY - 1) or nil
  tab.summaryRuleY = keep > 0 and ruleY or nil
end

-- v5 filler between the section rows and the summary: tab.extra (AddTab{ extra = }) else o.sidebarExtra, a
-- function(parent, shell, tabId) -> frame, built once per tab under pcall into tab.extraHost. Spans from `top` (px
-- below the sidebar top) down to 8 px over the summary rule (or the summary bottom offset when no line shows).
function Shell:LayoutExtra(tab, top, sideH)
  local src = tab.extra
  if src == nil then src = self.opts.sidebarExtra end
  if type(src) ~= "function" then
    if tab.extraHost then tab.extraHost:Hide() end
    return
  end
  local host = tab.extraHost
  if not host then
    host = CreateFrame("Frame", nil, tab.side)
    tab.extraHost, tab.extraFrame = host, host
    local ok, ret = pcall(src, host, self, tab.id)
    if not ok then
      tab.extraError = tostring(ret)
      self.lastError = tab.extraError
    elseif type(ret) == "table" and ret.SetShown then
      tab.extraFrame = ret
      if ret ~= host and ret.GetNumPoints and ret:GetNumPoints() == 0 then pcall(ret.SetAllPoints, ret, host) end
    end
  end
  local bottom = tab.summaryRuleY and (tab.summaryRuleY + 1 + 8) or self:SummaryBottomOffset()
  host:ClearAllPoints()
  host:SetPoint("TOPLEFT", tab.side, "TOPLEFT", SIDE_PAD, -top)
  host:SetPoint("BOTTOMRIGHT", tab.side, "BOTTOMRIGHT", -SIDE_PAD, bottom)
  local need = (type(tab.extraFrame) == "table" and tonumber(tab.extraFrame.minHeight)) or 40
  local avail = (sideH or 0) > 0 and (sideH - top - bottom) or nil
  tab.extraTop, tab.extraBottom, tab.extraAvail = top, bottom, avail
  host:SetShown(tab.extraError == nil and (avail == nil or avail >= need))
end

-- Sidebar for one tab: heading in Cinzel + one row per section (plates, or nav rows on a material sidebar) and the
-- optional summary block under them.
function Shell:LayoutSidebar(tab, current)
  local nav, ink = self.navRows, self.ink
  if not tab.side then
    local side = CreateFrame("Frame", nil, self.sidebar)
    side:SetAllPoints(self.sidebar)
    tab.side, tab.rows = side, {}
    local head = side:CreateFontString(nil, "OVERLAY")
    UI.Display(head, 14, true)
    if ink then
      head:SetTextColor(UI.Unpack(ink.heading or K().inkRed))
      head:SetShadowOffset(1, -1)
      head:SetShadowColor(1, 1, 1, 0.25) -- a faint emboss on parchment
    else
      head:SetTextColor(UI.Unpack(K().gold))
      head:SetShadowOffset(1, -1)
      head:SetShadowColor(UI.Unpack(K().titleShadow))
    end
    head:SetJustifyH("LEFT")
    head:SetPoint("TOPLEFT", side, "TOPLEFT", SIDE_PAD + 4, -8)
    head:SetText(tab.label)
    tab.heading = head
    local rule = newTex(side, "ARTWORK", 0)
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", side, "TOPLEFT", SIDE_PAD, -(SIDE_HEAD - 4))
    rule:SetPoint("TOPRIGHT", side, "TOPRIGHT", -SIDE_PAD, -(SIDE_HEAD - 4))
    solid(rule, ink and K().goldDeep or K().goldDim)
  end
  local rowH = nav and (M().navRow or 26) or ROW_H
  local gap = nav and 0 or ROW_GAP
  local list = self:SortedSections(tab.id)
  local sideH = self.sidebar:GetHeight() or 0
  local bottom = sideH - SIDE_PAD
  if self.footer then bottom = bottom - ((self.footerHeight or ROW_H) + FOOT_GAP + 1 + FOOT_GAP) end
  local avail = bottom - SIDE_HEAD
  local fit = (sideH > 0 and avail > 0) and floor((avail + gap) / (rowH + gap)) or #list
  local shell = self
  local shownRows = 0
  for i, sec in ipairs(list) do
    local row = tab.rows[i]
    if not row then
      local y = -(SIDE_HEAD + (i - 1) * (rowH + gap))
      if nav then
        row = navRow(tab.side, ink)
      else
        row = UI.Plate(tab.side, { height = ROW_H, width = (self.sidebarWidth or M().sidebar) - 2 * SIDE_PAD, justify = "LEFT" })
      end
      row:SetPoint("TOPLEFT", tab.side, "TOPLEFT", SIDE_PAD, y)
      row:SetPoint("TOPRIGHT", tab.side, "TOPRIGHT", -SIDE_PAD, y)
      tab.rows[i] = row
    end
    if row.sectionId ~= sec.id or row.iconPath ~= sec.icon or row:GetText() ~= sec.label then
      row.sectionId, row.iconPath = sec.id, sec.icon
      row:SetIcon(sec.icon)
      row:SetText(sec.label)
    end
    local id = sec.id
    row.onClick = function() shell:Select(tab.id, id) end
    row:SetKind(current and current.id == sec.id and "gold" or "dark")
    row:SetShown(i <= fit)
    if i <= fit then shownRows = shownRows + 1 end
  end
  for i = #list + 1, #tab.rows do tab.rows[i]:Hide() end
  -- summary: anchored to the sidebar bottom; it may rise to 12 px under the last shown row, no higher
  local minTop = SIDE_HEAD + (shownRows > 0 and (shownRows * (rowH + gap) - gap) or 0) + 12
  self:LayoutSummary(tab, minTop, sideH)
  self:LayoutExtra(tab, minTop, sideH)
  tab.dirty = false
end

function Shell:Refresh()
  local visible = self:VisibleTabs()
  local cur = self.current and self.tabById[self.current]
  local curVisible = false
  for _, t in ipairs(visible) do if t == cur then curVisible = true end end
  if not curVisible then
    local remembered = self.db.tab and self.tabById[self.db.tab]
    cur = nil
    for _, t in ipairs(visible) do if t == remembered then cur = t end end
    cur = cur or visible[1]
    self.current = cur and cur.id or nil
  end
  self:LayoutTabs(visible)

  local sec = cur and self:SectionFor(cur.id) or nil
  for _, tab in ipairs(self.tabs) do
    if tab.side and tab ~= cur then tab.side:Hide() end
  end
  if cur then
    self:LayoutSidebar(cur, sec)
    cur.side:Show()
  end

  local shown = self.frame:IsShown()
  if sec and shown then self:BuildSection(sec) end
  for _, list in pairs(self.sections) do
    for _, s in ipairs(list) do setSectionShown(s, shown and s == sec) end
  end

  -- v12: sec.onShow(frame, shell, sec) fires once each time a section comes into view (selected, or the window
  -- re-opened on it), after its first build; under pcall (an error goes to shell.lastError).
  if sec and shown and sec.built and type(sec.onShow) == "function"
      and (self.notifiedSec ~= sec or self.notifiedAt ~= self.showCount) then
    self.notifiedSec, self.notifiedAt = sec, self.showCount
    local ok, err = pcall(sec.onShow, sec.frame, self, sec)
    if not ok then self.lastError = tostring(err) end
  end

  local msg
  if not cur then msg = "Nothing to show yet: none of the World of Meta addons is loaded."
  elseif not sec then msg = "No sections yet." end
  self.emptyText:SetText(msg or "")
  self.emptyText:SetShown(msg ~= nil)
  self.currentSection = sec and sec.id or nil
end

---------------------------------------------------------------------------
-- Shared shell (v12): one World of Meta window for every addon that ships MetaKit

local shared = UI._sharedState or { tabs = {}, sections = {}, namespaces = {} }
UI._sharedState = shared

function UI.SharedShellNamespace(ns)
  if type(ns) ~= "table" then return end
  for _, n in ipairs(shared.namespaces) do if n == ns then return end end
  tinsert(shared.namespaces, ns)
end

-- Art token -> path through every registered addon ns, first hit wins.
local function sharedArt(token)
  for _, ns in ipairs(shared.namespaces) do
    if type(UI.Art) == "function" then
      local ok, p = pcall(UI.Art, ns, token)
      if ok and type(p) == "string" then return p end
    end
  end
  return nil
end

local function sharedSync()
  local ok = pcall(function() if type(ReloadUI) == "function" then ReloadUI() end end)
  return ok
end

function UI.SharedShell(db, ns, extra)
  UI.SharedShellNamespace(ns)
  if UI._sharedShell then return UI._sharedShell end
  local o = {
    name = "WorldOfMetaShell", title = "World of Meta", db = type(db) == "table" and db or {}, width = 960, height = 640,
    sidebarWidth = UI.ShellMetrics.compactSidebar,
    portrait = "Interface\\Icons\\INV_Misc_Book_09", footerText = "Sync now", footerVariant = "dark",
    chrome = "portrait", sidebar = "parchment", nativeButtons = false,
    ns = shared.namespaces[1], art = sharedArt, titleArt = true, portraitArt = true, corners = "bottom",
    closeStyle = "plate", flankArt = { left = "crest_bloodsports", right = { "crest_elders", "crest_tournament" } },
    footerTooltip = { "Sync now", { "Reloads the UI so the uploader can pick up your data." } },
    onFooter = sharedSync,
  }
  if type(extra) == "table" then for k2, v in pairs(extra) do o[k2] = v end end
  local shell = UI.Shell(o)
  UI._sharedShell = shell
  local tabs, sections = shared.tabs, shared.sections
  shared.tabs, shared.sections = {}, {}
  for _, def in ipairs(tabs) do shell:AddTab(def) end
  for _, def in ipairs(sections) do shell:AddSection(def) end
  return shell
end

function UI.RegisterSharedTab(def)
  if type(def) ~= "table" or not def.id then return false end
  if UI._sharedShell then UI._sharedShell:AddTab(def) else tinsert(shared.tabs, def) end
  return true
end

function UI.RegisterSharedSection(def)
  if type(def) ~= "table" or not (def.tab and def.id) then return false end
  if UI._sharedShell then UI._sharedShell:AddSection(def) else tinsert(shared.sections, def) end
  return true
end

-- Opens the shared shell on a tab. With a section: select it and show (never closes the window); without: Toggle.
function UI.SharedShellOpen(db, ns, tabId, sectionId)
  local shell = UI.SharedShell(db, ns)
  if sectionId then
    shell:Select(tabId, sectionId)
    shell:Show()
    return true
  end
  return shell:Toggle(tabId)
end
