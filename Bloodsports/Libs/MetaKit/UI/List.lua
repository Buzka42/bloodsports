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

function UI.ScrollRail(parent, o)
  o = o or {}
  local s = UI.Skin(o.skin)
  local rail = CreateFrame("Frame", nil, parent)
  rail:SetWidth(RAIL_W)
  rail.onScroll = o.onScroll
  rail.total, rail.visible, rail.offset = 0, 0, 0

  local track = CreateFrame("Button", nil, rail)
  track:SetPoint("TOP", rail, "TOP", 0, 0)
  track:SetPoint("BOTTOM", rail, "BOTTOM", 0, 0)
  track:SetWidth(RAIL_W)
  local tex = track:CreateTexture(nil, "BACKGROUND")
  tex:SetAllPoints(track)
  tex:SetColorTexture(1, 1, 1, 0.20)
  rail.track = track

  local thumb = CreateFrame("Button", nil, track)
  thumb:SetWidth(RAIL_W)
  thumb:SetHeight(24)
  local tt = thumb:CreateTexture(nil, "ARTWORK")
  tt:SetAllPoints(thumb)
  tt:SetColorTexture(UI.Tokens.accent[1], UI.Tokens.accent[2], UI.Tokens.accent[3], 0.50)
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
    local thumbH = clamp(th * self.visible / self.total, 18, th)
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
  return rail
end

---------------------------------------------------------------------------
-- List

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

  local f = CreateFrame("Frame", nil, parent)
  f.skin = s
  f:SetSize(o.width or 400, o.height or 240)
  f.data, f.offset, f.rows, f.selected, f.lastError = {}, 0, {}, false, false

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

  -- body (clipped) + rail
  local body = CreateFrame("Frame", nil, f)
  body:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -headerH)
  body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(RAIL_W + RAIL_INSET + 2), 0)
  body:SetClipsChildren(true)
  f.body = body

  local rail = UI.ScrollRail(f, { skin = s, onScroll = function(off) f:SetOffset(off) end })
  rail:SetPoint("TOPRIGHT", f, "TOPRIGHT", -RAIL_INSET, -(headerH + 2))
  rail:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -RAIL_INSET, 2)
  f.rail = rail

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
  local function fullRows() return max(1, floor(bodyHeight() / rowH)) end

  ---- columns -----------------------------------------------------------
  local function layoutColumns()
    local avail = (f:GetWidth() or 0) - RAIL_W - RAIL_INSET - 2 - 2 * PAD
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
          local size = min(rowH - 6, 18)
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
    row.selTex = row:CreateTexture(nil, "BACKGROUND")
    row.selTex:SetAllPoints(row)
    row.selTex:SetColorTexture(UI.Unpack(UI.Tokens.accentFill))
    row.selTex:Hide()
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints(row)
    row.hl:SetColorTexture(1, 1, 1, 0.06)
    local line = UI.Divider(row, s)
    line:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
    row.cells = {}
    row.data = false
    for i, c in ipairs(columns) do
      local kind = c.kind or "text"
      local cell
      if kind == "class" then
        cell = UI.ClassIcon(row, 18, s)
      elseif kind == "icon" then
        cell = UI.Icon(row, { size = 18, skin = s })
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
    row.selTex:SetShown(f.selected == idx)
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

  function f:Refresh()
    local need = ceil(bodyHeight() / rowH) + 1
    while #self.rows < need do self.rows[#self.rows + 1] = newRow(#self.rows + 1) end
    self.offset = clamp(self.offset, 0, self:MaxOffset())
    for k, row in ipairs(self.rows) do bind(row, self.offset + k, self.data[self.offset + k]) end
    local isEmpty = #self.data == 0
    empty:SetShown(isEmpty and (o.empty or "") ~= "")
    emptyHint:SetShown(isEmpty and (o.emptyHint or "") ~= "")
    rail:Update(#self.data, fullRows(), self.offset)
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
