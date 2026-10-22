-- UI kit core widgets: Window, Panel, Button, Label, Divider, Icon, ClassIcon, Tabs, EditBox, Dropdown,
-- Checkbox, Confirm. All take a `skin` (name or table). Chrome (window, tabs, buttons) is flat: colour fills,
-- 1 px lines and the three font objects, drawn from UI.Tokens; skin art is never drawn.

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI
local T = UI.Tex

local min, max, floor = math.min, math.max, math.floor
local unpack = unpack

local function skinOf(o) return UI.Skin(o and o.skin) end

local function addSpecial(name)
  if not name or not UISpecialFrames then return end
  for _, n in ipairs(UISpecialFrames) do if n == name then return end end
  table.insert(UISpecialFrames, name)
end

---------------------------------------------------------------------------
-- Label / Divider / Panel

function UI.Label(parent, o)
  o = o or {}
  local s = skinOf(o)
  local kind = o.font or "body"
  local fs = parent:CreateFontString(nil, o.layer or "OVERLAY")
  UI.SetFont(fs, kind)
  fs:SetTextColor(UI.Color(s, o.color or UI.FontColor[kind] or "text"))
  if kind == "title" then fs:SetShadowOffset(2, -2) else fs:SetShadowOffset(1, -1) end
  fs:SetShadowColor(0, 0, 0, 1)
  fs:SetJustifyH(o.justify or "LEFT")
  if o.width then fs:SetWidth(o.width) end
  fs:SetWordWrap(o.wrap and true or false)
  if o.text then fs:SetText(o.text) end
  function fs:SetColorKey(key) self:SetTextColor(UI.Color(s, key)) end
  return fs
end

-- A 1px line; the caller anchors it (LEFT/RIGHT).
function UI.Divider(parent, skin)
  local t = parent:CreateTexture(nil, "ARTWORK")
  t:SetColorTexture(UI.Color(skin, "divider"))
  t:SetHeight(1)
  return t
end

function UI.Panel(parent, skin)
  local p = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  UI.Backdrop(p, "tip", skin)
  p.skin = UI.Skin(skin)
  return p
end

---------------------------------------------------------------------------
-- Icon / ClassIcon

function UI.Icon(parent, o)
  o = o or {}
  local s = skinOf(o)
  local size = o.size or 24
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(size, size)
  local tex = f:CreateTexture(nil, "ARTWORK")
  tex:SetAllPoints(f)
  f.tex = tex
  if o.circle then
    local mask = f:CreateMaskTexture()
    mask:SetAllPoints(tex)
    mask:SetTexture(T.maskSmall, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    tex:AddMaskTexture(mask)
    f.mask = mask
  end
  if o.ring then
    local ring = f:CreateTexture(nil, "OVERLAY")
    ring:SetTexture(T.ring)
    ring:SetPoint("TOPLEFT", f, "TOPLEFT", -3, 3)
    ring:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 3, -3)
    ring:SetVertexColor(UI.Color(s, o.ring))
    f.ring = ring
  end
  function f:SetIcon(texture, coords)
    tex:SetTexture(texture or T.unknown)
    if type(coords) == "table" and #coords >= 4 then tex:SetTexCoord(unpack(coords)) else tex:SetTexCoord(0.07, 0.93, 0.07, 0.93) end
    tex:SetDesaturated(false)
    tex:SetVertexColor(1, 1, 1)
  end
  function f:SetDesaturated(v) tex:SetDesaturated(v and true or false) end
  f:SetIcon(o.texture, o.coords)
  return f
end

function UI.ClassIcon(parent, size, skin)
  local f = UI.Icon(parent, { size = size or 20, texture = T.classes, skin = skin })
  function f:SetClass(token)
    local c = type(token) == "string" and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
    f.class = token
    if c then
      f.tex:SetTexture(T.classes)
      f.tex:SetTexCoord(unpack(c))
      f.tex:SetDesaturated(false)
    else
      f.tex:SetTexture(T.unknown)
      f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
      f.tex:SetDesaturated(true)
    end
  end
  f:SetClass(nil)
  return f
end

---------------------------------------------------------------------------
-- Button

local function darker(c, d)
  return { max(0, c[1] - d), max(0, c[2] - d), max(0, c[3] - d), c[4] }
end

-- Flat button colours from the tokens. variant "accent"/"danger" and SetActive only change border/label/fill tint.
local function buttonColors(variant, active)
  local K = UI.Tokens
  local bg, border, label = { K.bg[1], K.bg[2], K.bg[3], 0.60 }, K.border, K.text
  if variant == "accent" then
    border, label = K.accent, K.accent
  elseif variant == "danger" then
    border, label = K.bad, K.bad
  end
  if active then
    local base = variant == "danger" and K.bad or K.accent
    bg, border, label = { base[1], base[2], base[3], 0.25 }, base, base
  end
  return bg, border, label
end

local function paintButton(b)
  local K = UI.Tokens
  local bg, border, label = buttonColors(b.variant, b.active)
  if not b.mkEnabled then
    label = K.muted
  else
    if b.hover then
      bg, label = K.accentFill, K.accent
    end
    if b.down then bg = darker(bg, 0.05) end
  end
  if b.SetBackdropColor then
    b:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    b:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
  end
  b.label:SetTextColor(label[1], label[2], label[3], label[4] or 1)
  b.icon:SetDesaturated(not b.mkEnabled)
end

function UI.Button(parent, o)
  o = o or {}
  local s = skinOf(o)
  local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
  b.skin, b.variant, b.mkEnabled, b.active = s, o.variant or "default", true, false
  b.hover, b.down, b.iconTexture = false, false, o.icon or false
  UI.Backdrop(b, "flat", s)
  local h = o.height or 24
  local label = b:CreateFontString(nil, "OVERLAY")
  UI.SetFont(label, "body")
  label:SetShadowOffset(1, -1)
  label:SetJustifyH("CENTER")
  b.label = label
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(h - 8, h - 8)
  icon:SetPoint("LEFT", b, "LEFT", 6, 0)
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  b.icon = icon

  local function layout()
    local hasIcon = b.iconTexture ~= nil
    icon:SetShown(hasIcon)
    if hasIcon then icon:SetTexture(b.iconTexture) end
    label:ClearAllPoints()
    label:SetPoint("LEFT", b, "LEFT", hasIcon and (h - 2) or 6, 0)
    label:SetPoint("RIGHT", b, "RIGHT", -6, 0)
  end
  function b:SetText(t) label:SetText(t or "") end
  function b:GetText() return label:GetText() end
  function b:SetIcon(tex) self.iconTexture = tex or false; layout(); paintButton(self) end
  function b:SetActive(v) self.active = v and true or false; paintButton(self) end
  function b:SetVariant(v) self.variant = v or "default"; paintButton(self) end
  function b:SetEnabledState(v)
    self.mkEnabled = v and true or false
    if self.mkEnabled then self:Enable() else self:Disable() end
    if not self.mkEnabled then self.hover, self.down = false, false end
    paintButton(self)
  end
  b:SetSize(o.width or 96, h)
  b:RegisterForClicks("LeftButtonUp")
  b:SetText(o.text)
  layout()
  if not o.width and o.text then
    b:SetWidth(max(60, label:GetStringWidth() + 24 + (o.icon and h or 0)))
  end
  b:SetScript("OnEnter", function(self)
    self.hover = true
    paintButton(self)
    if o.tooltip then UI.ShowTip(self, o.tooltip, "ANCHOR_TOP") end
  end)
  b:SetScript("OnLeave", function(self)
    self.hover, self.down = false, false
    paintButton(self)
    if o.tooltip then UI.HideTip() end
  end)
  b:SetScript("OnMouseDown", function(self) self.down = true; paintButton(self) end)
  b:SetScript("OnMouseUp", function(self) self.down = false; paintButton(self) end)
  b:SetScript("OnClick", function(self, button)
    if not self.mkEnabled then return end
    UI.Sound("click")
    if o.onClick then o.onClick(self, button) end
  end)
  paintButton(b)
  return b
end

---------------------------------------------------------------------------
-- Window

local function savePos(f)
  local db = f.db
  if not db then return end
  local point, _, rel, x, y = f:GetPoint(1)
  if not point then return end
  db.pos = { point, rel or point, floor((x or 0) * 10 + 0.5) / 10, floor((y or 0) * 10 + 0.5) / 10 }
end

function UI.Window(o)
  o = o or {}
  local s = skinOf(o)
  local w, h = o.width or 460, o.height or 560
  local f = CreateFrame("Frame", o.name, UIParent, "BackdropTemplate")
  f.skin, f.db, f.onClose = s, o.db or false, o.onClose or false
  f:SetSize(w, h)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  UI.Backdrop(f, "window", s)

  local pos = o.db and o.db.pos
  if type(pos) == "table" and type(pos[1]) == "string" then
    f:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); savePos(self) end)
  f:SetScript("OnMouseDown", function(self) self:Raise() end)
  f:SetScript("OnShow", function() UI.Sound("open") end)
  f:SetScript("OnHide", function(self)
    UI.Sound("close")
    if self.onClose then self.onClose(self) end
  end)
  function f:SavePosition() savePos(self) end

  -- Flat chrome (no skin art): 36 px title bar, 1 px accent rule, close X as two 1.5 px lines.
  local K, M = UI.Tokens, UI.Metrics
  local hasSub = o.subtitle ~= nil
  f.title = UI.Label(f, { font = "title", skin = s, text = o.title or "", color = "text" })
  f.title:SetPoint("TOPLEFT", f, "TOPLEFT", M.gutter, hasSub and -4 or -10)
  f.title:SetPoint("RIGHT", f, "RIGHT", -(M.gutter + 16 + M.gutter), 0)
  f.subtitle = UI.Label(f, { font = "small", skin = s, text = o.subtitle or "", color = "muted" })
  f.subtitle:SetPoint("TOPLEFT", f, "TOPLEFT", M.gutter, -23)
  f.subtitle:SetPoint("RIGHT", f, "RIGHT", -(M.gutter + 16 + M.gutter), 0)
  if not hasSub then f.subtitle:Hide() end
  local rule = f:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(K.accent[1], K.accent[2], K.accent[3], 1)
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -M.titleBar)
  rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -M.titleBar)
  f.titleRule = rule

  local close = CreateFrame("Button", nil, f)
  close:SetSize(16, 16)
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -8, -8)
  close:RegisterForClicks("LeftButtonUp")
  close.label = close:CreateFontString(nil, "OVERLAY") -- kept so callers that expect a label keep working
  UI.SetFont(close.label, "small")
  close.lines = {}
  for i, pts in ipairs({ { "TOPLEFT", "BOTTOMRIGHT", 3, -3, -3, 3 }, { "TOPRIGHT", "BOTTOMLEFT", -3, -3, 3, 3 } }) do
    local ln = close:CreateLine(nil, "OVERLAY")
    ln:SetThickness(1.5)
    ln:SetColorTexture(K.muted[1], K.muted[2], K.muted[3], 1)
    ln:SetStartPoint(pts[1], close, pts[3], pts[4])
    ln:SetEndPoint(pts[2], close, pts[5], pts[6])
    close.lines[i] = ln
  end
  local function paintClose(c)
    local col = c.hover and K.accent or K.muted
    for _, ln in ipairs(c.lines) do ln:SetColorTexture(col[1], col[2], col[3], 1) end
  end
  close:SetScript("OnEnter", function(self) self.hover = true; paintClose(self) end)
  close:SetScript("OnLeave", function(self) self.hover = false; paintClose(self) end)
  close:SetScript("OnClick", function() UI.Sound("click"); f:Hide() end)
  f.closeButton = close

  local content = CreateFrame("Frame", nil, f)
  content:SetPoint("TOPLEFT", f, "TOPLEFT", M.gutter, -(M.titleBar + M.gutter))
  content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -M.gutter, M.gutter)
  f.content = content

  function f:SetTitle(t) self.title:SetText(t or "") end
  function f:SetSubtitle(t)
    self.subtitle:SetText(t or "")
    self.subtitle:SetShown(t ~= nil and t ~= "")
  end
  function f:Toggle()
    if self:IsShown() then self:Hide() else self:Show() end
  end
  addSpecial(o.name)
  f:Hide()
  return f
end

---------------------------------------------------------------------------
-- Tabs

local TAB_GAP = 4

local function paintTab(b)
  local K = UI.Tokens
  local c = (b.active or b.hover) and K.text or K.muted
  b.label:SetTextColor(c[1], c[2], c[3], 1)
  b.underline:SetShown(b.active and true or false)
end

-- Text tabs: no box, 2 px accent underline under the selected one. With `width` the tabs share it equally
-- (4 px gap); without it each tab is as wide as its label.
function UI.Tabs(parent, o)
  o = o or {}
  local s = skinOf(o)
  local K = UI.Tokens
  local labels = o.labels or {}
  local f = CreateFrame("Frame", nil, parent)
  f.buttons, f.labels, f.selected = {}, labels, false
  local height = o.height or 24
  f:SetHeight(height)
  local n = #labels
  local each = o.width and n > 0 and floor((o.width - (n - 1) * TAB_GAP) / n) or nil
  local x = 0
  for i, text in ipairs(labels) do
    -- BackdropTemplate + a clear backdrop keep the Button-shaped API (SetBackdropColor etc.) callable.
    local b = CreateFrame("Button", nil, f, "BackdropTemplate")
    b.skin, b.active, b.hover, b.mkEnabled = s, false, false, true
    UI.Backdrop(b, "flat", s, { 0, 0, 0, 0 }, { 0, 0, 0, 0 })
    b.label = b:CreateFontString(nil, "OVERLAY")
    UI.SetFont(b.label, "body")
    b.label:SetShadowOffset(1, -1)
    b.label:SetJustifyH("CENTER")
    b.label:SetPoint("LEFT", b, "LEFT", 2, 0)
    b.label:SetPoint("RIGHT", b, "RIGHT", -2, 0)
    b.label:SetText(text)
    b.underline = b:CreateTexture(nil, "OVERLAY")
    b.underline:SetColorTexture(K.accent[1], K.accent[2], K.accent[3], 1)
    b.underline:SetHeight(2)
    b.underline:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
    b.underline:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
    function b:SetText(t) self.label:SetText(t or "") end
    function b:GetText() return self.label:GetText() end
    function b:SetActive(v) self.active = v and true or false; paintTab(self) end
    b:RegisterForClicks("LeftButtonUp")
    b:SetScript("OnEnter", function(self) self.hover = true; paintTab(self) end)
    b:SetScript("OnLeave", function(self) self.hover = false; paintTab(self) end)
    b:SetScript("OnClick", function() UI.Sound("click"); f:Select(i) end)
    local bw = each or max(48, b.label:GetStringWidth() + 22)
    b:SetSize(bw, height)
    b:SetPoint("LEFT", f, "LEFT", x, 0)
    x = x + bw + TAB_GAP
    f.buttons[i] = b
    paintTab(b)
  end
  f:SetWidth(max(1, x - TAB_GAP))
  function f:Select(i, silent)
    if not self.buttons[i] then return end
    for j, b in ipairs(self.buttons) do b:SetActive(j == i) end
    self.selected = i
    if o.onSelect and not silent then o.onSelect(i, labels[i]) end
  end
  function f:GetSelected() return self.selected or nil end
  if o.selected then f:Select(o.selected, true) end
  return f
end

---------------------------------------------------------------------------
-- EditBox (returns a real EditBox, so GetText/SetText/GetNumLetters/SetFocus all work)

function UI.EditBox(parent, o)
  o = o or {}
  local s = skinOf(o)
  local e = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
  e:SetSize(o.width or 200, o.height or (o.multiline and 90 or 24))
  if not o.bare then UI.Backdrop(e, "tip", s, UI.WithAlpha(UI.Tokens.bg, 0.95), UI.Tokens.border) end
  if GameFontHighlight then e:SetFontObject(GameFontHighlight) end
  e:SetTextColor(UI.Color(s, "text"))
  e:SetAutoFocus(false)
  e:SetTextInsets(6, 6, 4, 4)
  if o.multiline then
    e:SetMultiLine(true)
    e:SetJustifyH("LEFT")
    e:SetJustifyV("TOP")
  else
    e:SetMultiLine(false)
  end
  if o.maxLetters then e:SetMaxLetters(o.maxLetters) end

  local ph = e:CreateFontString(nil, "OVERLAY")
  UI.SetFont(ph, "body")
  ph:SetTextColor(UI.Color(s, "muted"))
  ph:SetPoint(o.multiline and "TOPLEFT" or "LEFT", e, o.multiline and "TOPLEFT" or "LEFT", 6, o.multiline and -4 or 0)
  ph:SetText(o.placeholder or "")
  local baseSetText = e.SetText
  local function refresh()
    local t = e:GetText()
    ph:SetShown(o.placeholder ~= nil and (t == nil or t == ""))
  end
  e.mkText = ""
  function e:SetText(t)
    t = t or ""
    self.mkText = t
    baseSetText(self, t)
    refresh()
  end
  function e:SetPlaceholder(t) o.placeholder = t; ph:SetText(t or ""); refresh() end
  function e:SetEnabledState(v)
    self:SetEnabled(v and true or false)
    self:SetAlpha(v and 1 or 0.5)
  end
  e:SetScript("OnTextChanged", function(self, userInput)
    if o.readOnly and userInput then
      baseSetText(self, self.mkText)
      self:HighlightText()
      return
    end
    if userInput then self.mkText = self:GetText() or "" end
    refresh()
    if o.onChange then o.onChange(self:GetText(), userInput and true or false) end
  end)
  e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  if not o.multiline then e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end) end
  if not o.bare then
    e:SetScript("OnEditFocusGained", function(self)
      self:SetBackdropBorderColor(UI.Color(s, "accent"))
    end)
    e:SetScript("OnEditFocusLost", function(self)
      self:SetBackdropBorderColor(UI.Unpack(UI.Tokens.border))
    end)
  end
  refresh()
  return e
end

---------------------------------------------------------------------------
-- Checkbox

function UI.Checkbox(parent, o)
  o = o or {}
  local s = skinOf(o)
  local c = CreateFrame("Button", nil, parent)
  c:SetSize(o.width or 220, 22)
  local box = CreateFrame("Frame", nil, c, "BackdropTemplate")
  box:SetSize(18, 18)
  box:SetPoint("LEFT", c, "LEFT", 0, 0)
  UI.Backdrop(box, "tip", s, UI.WithAlpha(UI.Tokens.bg, 0.95), UI.Tokens.border)
  local mark = box:CreateTexture(nil, "OVERLAY")
  mark:SetTexture(T.check)
  mark:SetPoint("TOPLEFT", box, "TOPLEFT", -3, 3)
  mark:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 3, -3)
  local text = UI.Label(c, { skin = s, text = o.label or "", color = "text" })
  text:SetPoint("LEFT", box, "RIGHT", 8, 0)
  c.checked, c.box, c.text = false, box, text
  function c:SetChecked(v) self.checked = v and true or false; mark:SetShown(self.checked) end
  function c:GetChecked() return self.checked end
  function c:SetLabel(t) text:SetText(t or "") end
  function c:SetEnabledState(v)
    self.mkEnabled = v and true or false
    self:SetAlpha(v and 1 or 0.5)
  end
  c.mkEnabled = true
  c:SetChecked(o.checked)
  c:RegisterForClicks("LeftButtonUp")
  c:SetScript("OnClick", function(self)
    if not self.mkEnabled then return end
    UI.Sound("click")
    self:SetChecked(not self.checked)
    if o.onChange then o.onChange(self.checked) end
  end)
  c:SetScript("OnEnter", function(self)
    box:SetBackdropBorderColor(UI.Color(s, "title"))
    if o.tooltip then UI.ShowTip(self, o.tooltip, "ANCHOR_RIGHT") end
  end)
  c:SetScript("OnLeave", function()
    box:SetBackdropBorderColor(UI.Unpack(UI.Tokens.border))
    if o.tooltip then UI.HideTip() end
  end)
  return c
end

---------------------------------------------------------------------------
-- Dropdown (own menu; avoids UIDropDownMenu taint)

local MENU_ROWS, MENU_ROW_H = 12, 22

local function itemValue(it)
  if it.value ~= nil then return it.value end
  return it[1]
end

local function itemText(it)
  return it.text or it[2] or tostring(itemValue(it))
end

function UI.Dropdown(parent, o)
  o = o or {}
  local s = skinOf(o)
  local d = UI.Button(parent, { skin = s, width = o.width or 160, height = o.height or 24, text = "", tooltip = o.tooltip })
  d.label:SetJustifyH("LEFT")
  d.label:ClearAllPoints()
  d.label:SetPoint("LEFT", d, "LEFT", 8, 0)
  d.label:SetPoint("RIGHT", d, "RIGHT", -22, 0)
  local arrow = d:CreateTexture(nil, "OVERLAY")
  arrow:SetTexture(T.arrowDown)
  arrow:SetSize(16, 16)
  arrow:SetPoint("RIGHT", d, "RIGHT", -3, 0)
  d.items, d.menuOffset = o.items or {}, 0
  local cur

  local menu, catcher, rows
  local function closeMenu()
    if menu then menu:Hide() end
    if catcher then catcher:Hide() end
  end
  local function renderMenu()
    local n = #d.items
    local shown = min(n, MENU_ROWS)
    d.menuOffset = max(0, min(d.menuOffset, n - shown))
    menu:SetSize(d:GetWidth(), shown * MENU_ROW_H + 8)
    for i = 1, MENU_ROWS do
      local row = rows[i]
      local it = d.items[d.menuOffset + i]
      if i <= shown and it then
        row.item = it
        row.text:SetText(itemText(it))
        local sel = itemValue(it) == cur
        row.text:SetTextColor(UI.Color(s, sel and "title" or "text"))
        row.sel:SetShown(sel)
        row:Show()
      else
        row:Hide()
      end
    end
  end
  local function buildMenu()
    catcher = CreateFrame("Button", nil, UIParent)
    catcher:SetAllPoints(UIParent)
    catcher:SetFrameStrata("FULLSCREEN_DIALOG")
    catcher:SetFrameLevel(900)
    catcher:SetScript("OnClick", closeMenu)
    catcher:Hide()
    menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetFrameLevel(910)
    UI.Backdrop(menu, "tip", s, UI.WithAlpha(UI.Tokens.bg, 0.98), UI.Tokens.border)
    menu:EnableMouseWheel(true)
    menu:SetScript("OnMouseWheel", function(_, delta)
      d.menuOffset = d.menuOffset - delta
      renderMenu()
    end)
    menu:Hide()
    rows = {}
    for i = 1, MENU_ROWS do
      local row = CreateFrame("Button", nil, menu)
      row:SetHeight(MENU_ROW_H)
      row:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -4 - (i - 1) * MENU_ROW_H)
      row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -4, -4 - (i - 1) * MENU_ROW_H)
      row.sel = row:CreateTexture(nil, "BACKGROUND")
      row.sel:SetAllPoints(row)
      row.sel:SetColorTexture(UI.Unpack(UI.Tokens.accentFill))
      local hl = row:CreateTexture(nil, "HIGHLIGHT")
      hl:SetAllPoints(row)
      hl:SetColorTexture(UI.Unpack(UI.Tokens.accentFill))
      row.text = UI.Label(row, { skin = s, font = "small" })
      row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
      row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
      row:SetScript("OnClick", function(self)
        local it = self.item
        closeMenu()
        if it then
          d:SetValue(itemValue(it))
          if o.onSelect then o.onSelect(itemValue(it), it) end
        end
      end)
      rows[i] = row
    end
    d.menu, d.menuRows = menu, rows
  end
  function d:OpenMenu()
    if not menu then buildMenu() end
    renderMenu()
    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
    catcher:Show()
    menu:Show()
  end
  function d:CloseMenu() closeMenu() end
  function d:IsMenuShown() return menu ~= nil and menu:IsShown() end
  function d:SetItems(items)
    self.items = items or {}
    self:SetValue(cur)
  end
  function d:SetValue(v)
    cur = v
    local text
    for _, it in ipairs(self.items) do
      if itemValue(it) == v then text = itemText(it) end
    end
    self:SetText(text or o.placeholder or "")
  end
  function d:GetValue() return cur end
  d:SetScript("OnClick", function(self)
    if not self.mkEnabled then return end
    if self:IsMenuShown() then closeMenu() else self:OpenMenu() end
  end)
  d:SetScript("OnHide", closeMenu)
  if o.value ~= nil then d:SetValue(o.value) else d:SetValue(nil) end
  return d
end

---------------------------------------------------------------------------
-- Confirm: small modal dialog, one reusable frame per skin.

local confirms = {}

local function buildConfirm(s, key)
  local blocker = CreateFrame("Button", nil, UIParent)
  blocker:SetAllPoints(UIParent)
  blocker:SetFrameStrata("FULLSCREEN_DIALOG")
  blocker:SetFrameLevel(100)
  blocker:EnableMouse(true)
  local dim = blocker:CreateTexture(nil, "BACKGROUND")
  dim:SetAllPoints(blocker)
  dim:SetColorTexture(0, 0, 0, 0.55)
  blocker:Hide()

  local name = "MetaKitConfirm_" .. key
  local c = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
  c.skin, c.blocker = s, blocker
  c:SetSize(380, 170)
  c:SetFrameStrata("FULLSCREEN_DIALOG")
  c:SetFrameLevel(110)
  c:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
  c:EnableMouse(true)
  UI.Backdrop(c, "window", s)
  c.title = UI.Label(c, { skin = s, font = "big", justify = "CENTER" })
  c.title:SetPoint("TOP", c, "TOP", 0, -20)
  c.title:SetWidth(340)
  c.body = UI.Label(c, { skin = s, font = "body", justify = "CENTER", wrap = true, width = 330 })
  c.body:SetPoint("TOP", c.title, "BOTTOM", 0, -12)
  c.acceptBtn = UI.Button(c, { skin = s, text = "OK", width = 120, height = 26, variant = "accent",
    onClick = function() c:Resolve(true) end })
  c.cancelBtn = UI.Button(c, { skin = s, text = "Cancel", width = 120, height = 26,
    onClick = function() c:Resolve(false) end })

  function c:Resolve(accepted)
    if self.resolved then return end
    self.resolved = true
    local cb = accepted and self.onAccept or self.onCancel
    self:Hide()
    if cb then cb() end
  end
  function c:Close() self:Resolve(false) end
  function c:Configure(o)
    if self:IsShown() and not self.resolved then self:Resolve(false) end
    self.resolved = false
    self.onAccept, self.onCancel = o.onAccept, o.onCancel
    self.title:SetText(o.title or "")
    self.body:SetText(o.text or "")
    self.acceptBtn:SetText(o.accept or ACCEPT or "OK")
    local showCancel = o.cancel ~= false
    self.cancelBtn:SetText(o.cancel or CANCEL or "Cancel")
    self.cancelBtn:SetShown(showCancel)
    self.acceptBtn:ClearAllPoints()
    self.cancelBtn:ClearAllPoints()
    if showCancel then
      self.acceptBtn:SetPoint("BOTTOMRIGHT", self, "BOTTOM", -6, 20)
      self.cancelBtn:SetPoint("BOTTOMLEFT", self, "BOTTOM", 6, 20)
    else
      self.acceptBtn:SetPoint("BOTTOM", self, "BOTTOM", 0, 20)
    end
    local bodyH = self.body:GetStringHeight() or 12
    self:SetHeight(max(150, 20 + 24 + 12 + bodyH + 20 + 26 + 20))
  end
  c:SetScript("OnShow", function(self)
    blocker:Show()
    self:Raise()
  end)
  c:SetScript("OnHide", function(self)
    blocker:Hide()
    if not self.resolved then self:Resolve(false) end
  end)
  addSpecial(name)
  c:Hide()
  return c
end

function UI.Confirm(o)
  o = o or {}
  local s = skinOf(o)
  local key = s.name or "custom"
  local c = confirms[key]
  if not c then
    c = buildConfirm(s, key)
    confirms[key] = c
  end
  c:Configure(o)
  c:Show()
  return c
end
