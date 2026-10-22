-- UI kit: ExportBox, a selectable read-only text window (export strings, URLs). Ctrl+C copies the selection.
--   UI.ExportBox{ title, text, skin, hint }  -> window (reused per skin)

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI

local boxes = {}

local function build(s, key)
  local win = UI.Window({ name = "MetaKitExportBox_" .. key, skin = s, width = 520, height = 340, title = "Export",
    subtitle = "" })
  local c = win.content
  local back = CreateFrame("Frame", nil, c, "BackdropTemplate")   -- created first so it draws under the scroll frame
  local scroll = CreateFrame("ScrollFrame", nil, c)
  scroll:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)
  scroll:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", -14, 36)
  back:SetPoint("TOPLEFT", scroll, "TOPLEFT", -3, 3)
  back:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 3, -3)
  UI.Backdrop(back, "tip", s, UI.Dim(s.bg, 0.7, 0.97), UI.WithAlpha(s.edge, 0.7))

  local edit = UI.EditBox(scroll, { skin = s, multiline = true, readOnly = true, bare = true, width = 470, height = 400 })
  scroll:SetScrollChild(edit)
  win.edit, win.scroll = edit, scroll

  local rail = UI.ScrollRail(c, { skin = s, onScroll = function(off) win.scrollPos = off; scroll:SetVerticalScroll(off) end })
  rail:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, 0)
  rail:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 36)
  win.rail = rail

  function win:UpdateRail()
    local range = scroll:GetVerticalScrollRange() or 0
    local view = scroll:GetHeight() or 0
    if view <= 0 then view = 250 end
    rail:Update(range + view, view, win.scrollPos or 0)
  end
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(_, delta)
    local range = scroll:GetVerticalScrollRange() or 0
    win.scrollPos = MK.Util.Clamp((win.scrollPos or 0) - delta * 40, 0, range)
    scroll:SetVerticalScroll(win.scrollPos)
    win:UpdateRail()
  end)
  scroll:SetScript("OnScrollRangeChanged", function() win:UpdateRail() end)

  local selectBtn = UI.Button(c, { skin = s, text = "Select all", width = 110, height = 26, variant = "accent",
    onClick = function() win:SelectAll() end })
  selectBtn:SetPoint("BOTTOMLEFT", c, "BOTTOMLEFT", 0, 0)
  local closeBtn = UI.Button(c, { skin = s, text = "Close", width = 90, height = 26, onClick = function() win:Hide() end })
  closeBtn:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 0)
  win.hintText = UI.Label(c, { skin = s, font = "small", color = "muted" })
  win.hintText:SetPoint("LEFT", selectBtn, "RIGHT", 12, 0)

  function win:SelectAll()
    edit:SetFocus()
    edit:HighlightText()
  end
  function win:SetExport(title, text, hint)
    self:SetTitle(title or "Export")
    self:SetSubtitle(nil)
    self.hintText:SetText(hint or "Ctrl+A, then Ctrl+C to copy. Esc closes.")
    edit:SetText(text or "")
    win.scrollPos = 0
    scroll:SetVerticalScroll(0)
    self:UpdateRail()
  end
  win:SetScript("OnShow", function(self)
    UI.Sound("open")
    self:SelectAll()
  end)
  edit:SetScript("OnEscapePressed", function() win:Hide() end)
  return win
end

function UI.ExportBox(o)
  o = o or {}
  local s = UI.Skin(o.skin)
  local key = s.name or "custom"
  local win = boxes[key]
  if not win then
    win = build(s, key)
    boxes[key] = win
  end
  win:SetExport(o.title, o.text, o.hint)
  win:Show()
  return win
end
