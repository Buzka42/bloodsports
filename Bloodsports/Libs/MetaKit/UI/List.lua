-- UI kit: ScrollRail (flat 6 px scrollbar, shared with StatRows) and List (virtualised table with a pooled row set).
-- Rows are built once for the visible window; scrolling only rebinds them, so the pool never grows with data.

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI
local T = UI.Tex

local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local clamp = MK.Util.Clamp

local RAIL_W, PAD, RAIL_INSET = 6, 4, 6
UI.RailWidth = RAIL_W

---------------------------------------------------------------------------
-- ScrollRail: units are whatever the owner scrolls in (rows for List, pixels for StatRows).
--   rail:Update(total, visible, offset)   rail.onScroll(offset) fires on user drags/clicks.
--   Optional look (defaults keep the v2 6 px rail): o.width, o.minThumb (18), o.trackColor ({1,1,1,0.20}),
--   o.thumbColor (accent at 50%).

-- Proportional thumb: track * visible / total, at least minH, never taller than the track (0 for no track).
local function thumbSize(track, visible, total, minH)
  track = tonumber(track) or 0
  if track <= 0 then return 0 end
  total = max(1, tonumber(total) or 1)
  local frac = min(1, max(0, tonumber(visible) or 0) / total)
  return min(track, max(minH or 18, track * frac))
end
UI.ScrollThumbSize = thumbSize

function UI.ScrollRail(parent, o)
  o = o or {}
  local s = UI.Skin(o.skin)
  local w = o.width or RAIL_W
  local minThumb = o.minThumb or 18
  local rail = CreateFrame("Frame", nil, parent)
  rail:SetWidth(w)
  rail.onScroll = o.onScroll
  rail.total, rail.visible, rail.offset = 0, 0, 0
  rail.railWidth, rail.minThumb = w, minThumb

  local track = CreateFrame("Button", nil, rail)
  track:SetPoint("TOP", rail, "TOP", 0, 0)
  track:SetPoint("BOTTOM", rail, "BOTTOM", 0, 0)
  track:SetWidth(w)
  local tex = track:CreateTexture(nil, "BACKGROUND")
  tex:SetAllPoints(track)
  tex:SetColorTexture(UI.Unpack(o.trackColor or { 1, 1, 1, 0.20 }))
  rail.track, rail.trackTex = track, tex

  local thumb = CreateFrame("Button", nil, track)
  thumb:SetWidth(w)
  thumb:SetHeight(24)
  local tt = thumb:CreateTexture(nil, "ARTWORK")
  tt:SetAllPoints(thumb)
  local a = UI.Tokens.accent
  tt:SetColorTexture(UI.Unpack(o.thumbColor or { a[1], a[2], a[3], 0.50 }))
  rail.thumb, rail.thumbTex = thumb, tt

  function rail:MaxOffset() return max(0, self.total - self.visible) end

  function rail:TrackHeight()
    local h = track:GetHeight()
    if not h or h <= 0 then h = self:GetHeight() end
    if not h or h <= 0 then h = 100 end
    return h
  end

  function rail:Update(total, visible, offset)
    self.total, self.visible, self.offset = total or 0, max(1, visible or 1), offset or 0
    local maxOff = self:MaxOffset()
    self.needed = maxOff > 0
    if not self.needed then
      self:Hide()
      return
    end
    self:Show()
    local th = self:TrackHeight()
    local thumbH = thumbSize(th, self.visible, self.total, minThumb)
    local pos = (th - thumbH) * clamp(self.offset, 0, maxOff) / maxOff
    thumb:SetHeight(thumbH)
    thumb:ClearAllPoints()
    thumb:SetPoint("TOP", track, "TOP", 0, -pos)
  end

  function rail:ScrollToFraction(f)
    local off = floor(clamp(f, 0, 1) * self:MaxOffset() + 0.5)
    self:Update(self.total, self.visible, off)
    if self.onScroll then self.onScroll(off) end
    return off
  end

  -- Drag math: cursor y (UI coordinates) and `grab` (distance from the thumb top to where it was grabbed).
  function rail:CursorToFraction(cy, grab)
    local usable = self:TrackHeight() - thumb:GetHeight()
    if usable <= 0 then return 0 end
    local top = track:GetTop() or 0
    return clamp((top - (cy + grab)) / usable, 0, 1)
  end

  local function cursorY()
    local _, y = GetCursorPosition()
    return (y or 0) / (track:GetEffectiveScale() or 1)
  end
  local function startDrag(grab)
    rail.dragging = true
    thumb:SetScript("OnUpdate", function()
      rail:ScrollToFraction(rail:CursorToFraction(cursorY(), grab))
    end)
  end
  local function stopDrag()
    rail.dragging = false
    thumb:SetScript("OnUpdate", nil)
  end
  thumb:SetScript("OnMouseDown", function()
    startDrag((thumb:GetTop() or 0) - cursorY())
  end)
  thumb:SetScript("OnMouseUp", stopDrag)
  track:SetScript("OnMouseDown", function()
    local grab = -thumb:GetHeight() / 2
    rail:ScrollToFraction(rail:CursorToFraction(cursorY(), grab))
    startDrag(grab)
  end)
  track:SetScript("OnMouseUp", stopDrag)
  rail:SetScript("OnHide", stopDrag)
  -- a resized track re-sizes the thumb (the owner's Refresh does too; this covers owners that do not)
  rail:SetScript("OnSizeChanged", function(self)
    if self.needed then self:Update(self.total, self.visible, self.offset) end
  end)
  return rail
end

---------------------------------------------------------------------------
-- NativeScrollBar: the client's UIPanelScrollBarTemplate slider (probe first) behind the ScrollRail interface
-- (Update(total, visible, offset), needed, onScroll). nil when no template takes; the caller keeps its rail.

UI.NativeScrollTemplates = { "UIPanelScrollBarTemplate", "UIPanelScrollBarTemplateLightBorder" }
local nativeSeq = 0

function UI.NativeScrollBar(parent, o)
  o = o or {}
  local bar, tpl
  for _, name in ipairs(UI.NativeScrollTemplates) do
    if UI.HasTemplate == nil or UI.HasTemplate(name) ~= false then
      nativeSeq = nativeSeq + 1
      -- a global name: the template's arrow buttons are $parent-named
      local ok, b = pcall(CreateFrame, "Slider", "MetaKitScrollBar" .. nativeSeq, parent, name)
      if ok and b then bar, tpl = b, name break end
    end
  end
  if not bar then return nil end
  local sb = { bar = bar, template = tpl, width = 16, total = 0, visible = 0, offset = 0, needed = false,
    onScroll = o.onScroll }
  bar.scrollStep = 1 -- the arrow buttons step the slider by its scrollStep: one row
  pcall(bar.SetValueStep, bar, 1)
  pcall(bar.SetObeyStepOnDrag, bar, true)
  -- the template's own scripts drive a ScrollFrame parent (SetVerticalScroll); ours drive the owner's offset
  bar:SetScript("OnValueChanged", function(_, value)
    if sb.updating then return end
    local off = floor((value or 0) + 0.5)
    if off ~= sb.offset then
      sb.offset = off
      if sb.onScroll then sb.onScroll(off) end
    end
  end)
  bar:SetScript("OnMouseWheel", function(_, delta) if o.onWheel then o.onWheel(delta) end end)
  function sb:Update(total, visible, offset)
    self.total, self.visible, self.offset = total or 0, max(1, visible or 1), offset or 0
    local maxOff = max(0, self.total - self.visible)
    self.needed = maxOff > 0
    bar:SetShown(self.needed)
    self.updating = true
    pcall(bar.SetMinMaxValues, bar, 0, maxOff)
    pcall(bar.SetValue, bar, clamp(self.offset, 0, maxOff))
    self.updating = false
  end
  function sb:SetPoint(...) return bar:SetPoint(...) end
  function sb:Hide() bar:Hide() end
  return sb
end

---------------------------------------------------------------------------
-- List
--   o.zebra: true (SiteTokens rowEven / rowOdd) or { evenColour, oddColour } alternating row tint; off by default.
--   o.selectable: a left click selects the row (accentFill wash + 2 px accent bar); off by default. f:SetSelected(i)
--   selects from code either way; f:GetSelected() reads it.
--   v3 (all optional): o.separators (1 px SiteTokens.listSep under each row; defaults on when zebra is on),
--   o.selectedStrip (true = 3 px, or a width: the selection bar in SiteTokens.gold), o.iconSize (class / icon cells,
--   default min(row - 6, 18)), o.headerHeight (22 for the shell look), o.nativeScrollbar (UI.NativeScrollBar, the
--   flat rail when it does not take).
--   v4: o.thumbScrollbar = true: a proportional thumb (10 px track at white 8%, full body height, SiteTokens.goldDim
--   thumb at least 24 px, height = track * visible / total); it is also what a nativeScrollbar list falls back to
--   when no template takes. A working native slider still wins. f:VisibleCount() = data rows the last Refresh laid
--   out inside the body, counted from the row pool. o.onRefresh(list) runs after every Refresh (scroll, resize, data).
--   v10: rows snap to FULL rows: a pool row that would not fit entirely inside the body is hidden (never drawn
--   half-clipped), so VisibleCount() <= VisibleRows() and a footer built on it matches what is on screen. The scroll
--   range stays total - VisibleRows(); the last page may show fewer rows.
local function cellValue(list, col, data)
  if col.format then
    local ok, v = pcall(col.format, data)
    if ok then return v end
    list.lastError = v
    return nil
  end
  return data[col.key]
end

function UI.List(parent, o)
  o = o or {}
  local s = UI.Skin(o.skin)
  local rowH = o.rowHeight or UI.Metrics.row
  local columns = {}
  for i, c in ipairs(o.columns or {}) do
    local copy = {}
    for k, v in pairs(c) do copy[k] = v end
    columns[i] = copy
  end
  local hasTitles = false
  for _, c in ipairs(columns) do if c.title then hasTitles = true end end
  local headerH = hasTitles and (o.headerHeight or UI.Metrics.header) or 0
  local zebra = nil
  if type(o.zebra) == "table" and type(o.zebra[1]) == "table" and type(o.zebra[2]) == "table" then
    zebra = { o.zebra[1], o.zebra[2] }
  elseif o.zebra then
    local k = UI.SiteTokens or {}
    zebra = { k.rowEven or { 1, 1, 1, 0.04 }, k.rowOdd or { 0, 0, 0, 0.12 } }
  end

  local separators = o.separators
  if separators == nil then separators = zebra ~= nil end
  local strip = o.selectedStrip == true and 3 or (type(o.selectedStrip) == "number" and o.selectedStrip) or nil
  local iconSize = o.iconSize or min(rowH - 6, 18)

  local f = CreateFrame("Frame", nil, parent)
  f.skin = s
  f:SetSize(o.width or 400, o.height or 240)
  f.data, f.offset, f.rows, f.selected, f.lastError = {}, 0, {}, false, false
  f.separators, f.selectedStrip, f.iconSize = separators and true or false, strip or false, iconSize
  f.columns = columns -- v6: read-only view of the (copied) column specs, for callers / tests

  -- header band
  local header = CreateFrame("Frame", nil, f)
  header:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  header:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
  header:SetHeight(max(headerH, 1))
  header:SetShown(headerH > 0)
  local hline = UI.Divider(header, s)
  hline:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
  hline:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
  f.headerTitles = {}
  for i, c in ipairs(columns) do
    local fs = UI.Label(header, { skin = s, font = "small", color = "muted", justify = c.align or "LEFT" })
    fs:SetText(c.title or "")
    f.headerTitles[i] = fs
  end

  -- scroll: the native slider when asked for and present (arrows take 16 px above and below it), else the rail
  local native = o.nativeScrollbar and UI.NativeScrollBar(f, { onScroll = function(off) f:SetOffset(off) end,
    onWheel = function(delta) f:SetOffset(f.offset - delta * (o.wheelStep or 3)) end }) or nil
  local thumbStyle = not native and (o.thumbScrollbar or o.nativeScrollbar) and true or false
  local k = UI.SiteTokens or {}
  local m = UI.ShellMetrics or {}
  local railW = thumbStyle and (m.thumbTrack or 10) or RAIL_W
  local railInset = thumbStyle and 2 or RAIL_INSET
  local scrollW = native and (native.width + 8) or (railW + railInset + 2)

  -- body (clipped) + rail
  local body = CreateFrame("Frame", nil, f)
  body:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -headerH)
  body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -scrollW, 0)
  body:SetClipsChildren(true)
  f.body = body

  local railOpts = { skin = s, onScroll = function(off) f:SetOffset(off) end }
  if thumbStyle then
    local gd = k.goldDim or UI.Tokens.accent
    railOpts.width, railOpts.minThumb = railW, m.thumbMin or 24
    railOpts.trackColor, railOpts.thumbColor = { 1, 1, 1, 0.08 }, { gd[1], gd[2], gd[3], 1 }
  end
  local rail = UI.ScrollRail(f, railOpts)
  -- the thumb track runs the full body height (header bottom to list bottom); the v2 rail keeps its 2 px insets
  local ry = thumbStyle and 0 or 2
  rail:SetPoint("TOPRIGHT", f, "TOPRIGHT", -railInset, -(headerH + ry))
  rail:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -railInset, ry)
  f.rail, f.thumbScroll = rail, thumbStyle
  if native then
    rail:Hide()
    native:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -(headerH + 16))
    native:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 16)
    f.scrollbar = native
  end
  f.nativeScroll = native and true or false

  -- empty state: one centred line (12, muted) plus a hint line (10, muted) below it
  local empty = UI.Label(body, { skin = s, font = "body", color = "muted", justify = "CENTER", text = o.empty or "" })
  empty:SetPoint("CENTER", body, "CENTER", 0, 6)
  local emptyHint = UI.Label(body, { skin = s, font = "small", color = "muted", justify = "CENTER", text = o.emptyHint or "" })
  emptyHint:SetPoint("TOP", empty, "BOTTOM", 0, -6)
  f.emptyText, f.emptyHintText = empty, emptyHint

  local function bodyHeight()
    local h = f:GetHeight() - headerH
    if not h or h < rowH then h = rowH * 10 end
    return h
  end
  -- whole rows that fit the body (1e-6 absorbs float heights like 311.9999); the epsilon never admits a clipped row
  local function fullRows() return max(1, floor(bodyHeight() / rowH + 1e-6)) end

  ---- columns -----------------------------------------------------------
  local function layoutColumns()
    local avail = (f:GetWidth() or 0) - scrollW - 2 * PAD
    if avail <= 0 then avail = 400 end
    local fixed, flex = 0, 0
    for _, c in ipairs(columns) do
      if c.width then fixed = fixed + c.width else flex = flex + 1 end
    end
    local flexW = flex > 0 and max(30, (avail - fixed) / flex) or 0
    local x = PAD
    for i, c in ipairs(columns) do
      c.x, c.w = x, c.width or flexW
      x = x + c.w
      local fs = f.headerTitles[i]
      fs:ClearAllPoints()
      fs:SetPoint("LEFT", header, "LEFT", c.x + 2, 0)
      fs:SetWidth(c.w - 4)
    end
    for _, row in ipairs(f.rows) do f:PlaceCells(row) end
  end

  function f:PlaceCells(row)
    for i, c in ipairs(columns) do
      local cell = row.cells[i]
      if cell and c.x then
        if c.kind == "class" or c.kind == "icon" then
          local size = iconSize
          local dx = c.x + 2
          if c.align == "CENTER" then dx = c.x + (c.w - size) / 2 elseif c.align == "RIGHT" then dx = c.x + c.w - size - 2 end
          cell:ClearAllPoints()
          cell:SetSize(size, size)
          cell:SetPoint("LEFT", row, "LEFT", dx, 0)
        elseif c.kind == "button" then
          cell:ClearAllPoints()
          cell:SetSize(max(20, c.w - 6), rowH - 6)
          cell:SetPoint("LEFT", row, "LEFT", c.x + 3, 0)
        else
          cell:ClearAllPoints()
          cell:SetPoint("LEFT", row, "LEFT", c.x + 2, 0)
          cell:SetWidth(c.w - 4)
        end
      end
    end
  end

  ---- row pool ----------------------------------------------------------
  local function newRow(k)
    local row = CreateFrame("Button", nil, body)
    row:SetHeight(rowH)
    row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -(k - 1) * rowH)
    row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -(k - 1) * rowH)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.zebra = row:CreateTexture(nil, "BACKGROUND", nil, -2)
    row.zebra:SetAllPoints(row)
    row.zebra:Hide()
    row.selTex = row:CreateTexture(nil, "BACKGROUND")
    row.selTex:SetAllPoints(row)
    row.selTex:SetColorTexture(UI.Unpack(UI.Tokens.accentFill))
    row.selTex:Hide()
    row.selBar = row:CreateTexture(nil, "ARTWORK")
    row.selBar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    row.selBar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    row.selBar:SetWidth(strip or 2)
    row.selBar:SetColorTexture(UI.Unpack(strip and UI.SiteTokens and UI.SiteTokens.gold or UI.Tokens.accent))
    row.selBar:Hide()
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints(row)
    row.hl:SetColorTexture(1, 1, 1, 0.06)
    local line = UI.Divider(row, s)
    line:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    if separators then line:SetColorTexture(UI.Unpack((UI.SiteTokens or {}).listSep or { 0x4a / 255, 0x35 / 255, 0x1d / 255, 0.55 })) end
    row.line = line
    row.cells = {}
    row.data = false
    for i, c in ipairs(columns) do
      local kind = c.kind or "text"
      local cell
      if kind == "class" then
        cell = UI.ClassIcon(row, iconSize, s)
      elseif kind == "icon" then
        cell = UI.Icon(row, { size = iconSize, skin = s })
      elseif kind == "button" then
        cell = UI.Button(row, { skin = s, text = c.buttonText or "", width = 60, height = rowH - 6,
          onClick = function() if c.onClick and row.data then c.onClick(row.data, row.index) end end })
      else
        cell = UI.Label(row, { skin = s, font = "body", justify = c.align or "LEFT", color = c.color })
        cell:SetWordWrap(false)
      end
      row.cells[i] = cell
    end
    f:PlaceCells(row)
    row:SetScript("OnClick", function(self, button)
      if self.data and o.selectable and button ~= "RightButton" then f:SetSelected(self.index) end
      if self.data and o.onRowClick then o.onRowClick(self.data, self, button) end
    end)
    row:SetScript("OnEnter", function(self)
      if self.data and o.onRowEnter then o.onRowEnter(self.data, self) end
    end)
    row:SetScript("OnLeave", function(self)
      if self.data and o.onRowLeave then o.onRowLeave(self.data, self) end
    end)
    return row
  end

  local function bind(row, idx, data)
    row.index, row.data = idx, data or false
    if not data then
      row:Hide()
      return
    end
    row:Show()
    local sel = f.selected == idx
    row.selTex:SetShown(sel)
    row.selBar:SetShown(sel)
    if zebra then
      local c = idx % 2 == 0 and zebra[1] or zebra[2]
      row.zebra:SetColorTexture(UI.Unpack(c))
      row.zebra:SetShown(not sel)
    end
    for i, c in ipairs(columns) do
      local cell, kind = row.cells[i], c.kind or "text"
      local v = cellValue(f, c, data)
      if kind == "class" then
        cell:SetClass(v)
      elseif kind == "icon" then
        if type(v) == "table" then cell:SetIcon(v[1], v[2]) else cell:SetIcon(v) end
        cell:SetShown(v ~= nil)
      elseif kind == "button" then
        cell:SetShown(v ~= false)
        if type(v) == "string" then cell:SetText(v) end
      elseif kind == "money" then
        cell:SetText(v ~= nil and (type(v) == "number" and MK.Util.Money(v) or tostring(v)) or "")
      else
        cell:SetText(v ~= nil and tostring(v) or "")
      end
    end
  end

  ---- public ------------------------------------------------------------
  function f:GetPoolSize() return #self.rows end
  function f:GetData() return self.data end
  function f:GetOffset() return self.offset end
  function f:VisibleRows() return fullRows() end
  function f:MaxOffset() return max(0, #self.data - fullRows()) end

  -- Data rows the last Refresh laid out on screen: pool rows bound to data that lie wholly inside the body.
  function f:VisibleCount() return self.visibleCount or 0 end

  function f:Refresh()
    local bh = bodyHeight()
    local need = ceil(bh / rowH) + 1
    while #self.rows < need do self.rows[#self.rows + 1] = newRow(#self.rows + 1) end
    self.offset = clamp(self.offset, 0, self:MaxOffset())
    local full, shown = fullRows(), 0
    for k, row in ipairs(self.rows) do
      -- v10: a pool slot past the last full row stays empty (hidden), so no row is ever drawn half-clipped
      bind(row, self.offset + k, k <= full and self.data[self.offset + k] or nil)
      if row.data and row:IsShown() then shown = shown + 1 end
    end
    self.visibleCount = shown
    local isEmpty = #self.data == 0
    empty:SetShown(isEmpty and (o.empty or "") ~= "")
    emptyHint:SetShown(isEmpty and (o.emptyHint or "") ~= "")
    if native then native:Update(#self.data, fullRows(), self.offset) else rail:Update(#self.data, fullRows(), self.offset) end
    if o.onRefresh then
      local ok, err = pcall(o.onRefresh, self)
      if not ok then self.lastError = err end
    end
  end

  function f:SetData(rows)
    self.data = rows or {}
    self:Refresh()
  end

  function f:SetOffset(n)
    n = clamp(floor(n + 0.5), 0, self:MaxOffset())
    if n ~= self.offset then
      self.offset = n
      self:Refresh()
    end
  end

  function f:ScrollTo(index)
    self:SetOffset(index - 1)
  end

  function f:SetSelected(index)
    self.selected = index
    self:Refresh()
  end
  function f:GetSelected() return self.selected end
  f.zebraColors = zebra

  function f:SetEmptyText(t, hint)
    o.empty = t
    if hint ~= nil then o.emptyHint = hint; emptyHint:SetText(hint or "") end
    empty:SetText(t or "")
    self:Refresh()
  end

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(self, delta) self:SetOffset(self.offset - delta * (o.wheelStep or 3)) end)
  f:SetScript("OnSizeChanged", function() layoutColumns(); f:Refresh() end)

  layoutColumns()
  f:Refresh()
  return f
end
