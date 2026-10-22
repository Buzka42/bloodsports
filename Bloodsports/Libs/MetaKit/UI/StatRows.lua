-- UI kit: StatRows, a scrollable list of titled sections with icon / label / sub / right-aligned value rows.
-- Entries have different heights (section header vs stat row), so the scroll offset is in pixels and the
-- pooled row frames are rebound to whichever entries intersect the viewport.

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI
local T = UI.Tex

local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil
local clamp = MK.Util.Clamp

local HEADER_H, PAD = UI.Metrics.section, UI.Metrics.gutter
local SUB_ROW_H = 30   -- a row with a sub-line needs 12 + 10 pt of text

function UI.StatRows(parent, o)
  o = o or {}
  local s = UI.Skin(o.skin)
  local rowH = o.rowHeight or UI.Metrics.row
  local headGap = o.headerGap or UI.Metrics.sectionGap          -- extra space above each section header
  local railInset = o.railInset or 6        -- gap between the scrollbar and the right edge
  local bodyInset = railInset + UI.RailWidth + 2
  local f = CreateFrame("Frame", nil, parent)
  f.skin = s
  f:SetSize(o.width or 400, o.height or 300)
  f.items, f.rows, f.offset, f.contentH = {}, {}, 0, 0

  local body = CreateFrame("Frame", nil, f)
  body:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -bodyInset, 0)
  body:SetClipsChildren(true)
  f.body = body

  local rail = UI.ScrollRail(f, { skin = s, onScroll = function(off) f:SetOffset(off) end })
  rail:SetPoint("TOPRIGHT", f, "TOPRIGHT", -railInset, -2)
  rail:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -railInset, 2)
  -- (o.railTrack / o.headerRule are accepted for old callers; the flat kit draws no rail art and always rules headers)
  f.rail = rail

  local function viewH()
    local h = f:GetHeight()
    if not h or h <= 0 then h = 300 end
    return h
  end
  local function viewW()
    local w = f:GetWidth()
    if not w or w <= 0 then w = 400 end
    return w - bodyInset
  end

  local function newRow()
    local row = CreateFrame("Button", nil, body)
    row.entry = false
    row.hl = row:CreateTexture(nil, "HIGHLIGHT")
    row.hl:SetAllPoints(row)
    row.hl:SetColorTexture(1, 1, 1, 0.06)
    row.line = UI.Divider(row, s)
    row.icon = UI.Icon(row, { size = 22, skin = s })
    row.icon:SetPoint("LEFT", row, "LEFT", PAD, 0)
    row.label = UI.Label(row, { skin = s, font = "body", color = "text" })
    row.label:SetWordWrap(false)
    row.sub = UI.Label(row, { skin = s, font = "small", color = "muted" })
    row.sub:SetWordWrap(false)
    row.value = UI.Label(row, { skin = s, font = "body", justify = "RIGHT", color = "text" })
    row.value:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
    row.value:SetWordWrap(false)
    row.head = UI.Label(row, { skin = s, font = "body", color = "accent" })
    row:SetScript("OnEnter", function(self)
      if self.entry and self.entry.tooltip then UI.ShowTip(self, self.entry.tooltip, "ANCHOR_RIGHT") end
    end)
    row:SetScript("OnLeave", function(self)
      if self.entry and self.entry.tooltip then UI.HideTip() end
    end)
    return row
  end

  local function bind(row, item, y)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", body, "TOPLEFT", 0, -y)
    row:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, -y)
    row:SetHeight(item.h)
    row:Show()
    row.line:ClearAllPoints()
    if item.header then
      row.entry = false
      row.hl:Hide()
      row.line:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
      row.line:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
      row.line:Show()
      row.icon:Hide(); row.label:Hide(); row.sub:Hide(); row.value:Hide()
      row.head:Show()
      row.head:ClearAllPoints()
      row.head:SetPoint("LEFT", row, "LEFT", PAD, -(headGap / 2))
      row.head:SetText(item.title or "")
      return
    end
    row.hl:Show()
    row.line:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", PAD, 0)
    row.line:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -PAD, 0)
    local e = item.row
    row.entry = e
    row.head:Hide()
    row.line:Show()
    local x = PAD
    if e.icon then
      row.icon:Show()
      if type(e.icon) == "table" then row.icon:SetIcon(e.icon[1], e.icon[2]) else row.icon:SetIcon(e.icon) end
      x = PAD + 22 + 8
    else
      row.icon:Hide()
    end
    local w = viewW()
    row.label:Show()
    row.label:ClearAllPoints()
    row.label:SetWidth(max(40, w - x - w * 0.38 - 12))
    row.label:SetText(e.label or "")
    row.value:Show()
    row.value:SetWidth(w * 0.38)
    row.value:SetText(e.value ~= nil and tostring(e.value) or "")
    row.value:SetTextColor(UI.Color(s, e.color or "text")) -- "good" / "bad" only when the caller passes them
    if e.sub and e.sub ~= "" then
      row.label:SetPoint("LEFT", row, "LEFT", x, 6)
      row.sub:Show()
      row.sub:ClearAllPoints()
      row.sub:SetPoint("LEFT", row, "LEFT", x, -8)
      row.sub:SetWidth(max(40, w - x - w * 0.38 - 12))
      row.sub:SetText(e.sub)
    else
      row.label:SetPoint("LEFT", row, "LEFT", x, 0)
      row.sub:Hide()
    end
  end

  function f:GetPoolSize() return #self.rows end
  function f:GetContentHeight() return self.contentH end
  function f:GetOffset() return self.offset end
  function f:MaxOffset() return max(0, self.contentH - viewH()) end

  function f:Refresh()
    local vh = viewH()
    self.offset = clamp(self.offset, 0, self:MaxOffset())
    local used = 0
    for _, item in ipairs(self.items) do
      if item.y + item.h > self.offset and item.y < self.offset + vh then
        used = used + 1
        local row = self.rows[used]
        if not row then
          row = newRow()
          self.rows[used] = row
        end
        bind(row, item, item.y - self.offset)
      end
    end
    for i = used + 1, #self.rows do
      self.rows[i]:Hide()
      self.rows[i].entry = false
    end
    rail:Update(self.contentH, vh, self.offset)
  end

  function f:SetSections(sections)
    local items, y, n = {}, 0, 0
    for _, sec in ipairs(sections or {}) do
      if sec.title then
        items[#items + 1] = { header = true, title = sec.title, y = y, h = HEADER_H + headGap }
        y = y + HEADER_H + headGap
      end
      for _, r in ipairs(sec.rows or {}) do
        n = n + 1
        local h = (r.sub and r.sub ~= "") and max(rowH, SUB_ROW_H) or rowH
        items[#items + 1] = { row = r, n = n, y = y, h = h }
        y = y + h
      end
    end
    self.items, self.contentH = items, y
    self:Refresh()
  end

  function f:SetOffset(px)
    px = clamp(floor(px + 0.5), 0, self:MaxOffset())
    if px ~= self.offset then
      self.offset = px
      self:Refresh()
    end
  end
  function f:ScrollToTop() self:SetOffset(0) end

  f:EnableMouseWheel(true)
  f:SetScript("OnMouseWheel", function(self, delta) self:SetOffset(self.offset - delta * rowH * 2) end)
  f:SetScript("OnSizeChanged", function() f:Refresh() end)
  return f
end
