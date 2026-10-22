-- UI kit: MinimapButton, LibDBIcon geometry (33px button, 53px border, 20px icon). Dragging (either button) moves it
-- around the minimap; position is db.angle in DEGREES (0 = east, counter-clockwise), db.hide hides it.
-- Create it early (ADDON_LOADED) with a global name ending in "MinimapButton" so button-collector addons see it.
--   UI.MinimapPosition(angleDeg, minimapWidth) -> x, y ; UI.MinimapAngle(cx, cy, mx, my) -> degrees

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI
local T = UI.Tex

local rad, deg, cos, sin = math.rad, math.deg, math.cos, math.sin

function UI.MinimapPosition(angle, width)
  local r = (width or 140) / 2 + 10
  local a = rad(angle or 200)
  return cos(a) * r, sin(a) * r
end

function UI.MinimapAngle(cx, cy, mx, my)
  local a = deg(math.atan2(my - cy, mx - cx))
  if a < 0 then a = a + 360 end
  return a
end

function UI.MinimapButton(o)
  o = o or {}
  local db = o.db or {}
  if db.angle == nil then db.angle = 200 end
  local b = CreateFrame("Button", o.name, Minimap)
  b.db, b.dragging = db, false
  b:SetSize(33, 33)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b:RegisterForDrag("LeftButton", "RightButton")
  b:SetHighlightTexture(T.mmHighlight)

  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture(T.mmBorder)
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
  local bg = b:CreateTexture(nil, "BACKGROUND")
  bg:SetTexture(T.mmBackground)
  bg:SetSize(20, 20)
  bg:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -5)
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetSize(20, 20)
  icon:SetPoint("TOPLEFT", b, "TOPLEFT", 7, -5)
  icon:SetTexture(o.icon or T.unknown)
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  b.icon = icon

  function b:UpdatePosition()
    local x, y = UI.MinimapPosition(self.db.angle, Minimap:GetWidth())
    self:ClearAllPoints()
    self:SetPoint("CENTER", Minimap, "CENTER", x, y)
  end
  function b:SetAngle(a)
    self.db.angle = (tonumber(a) or 200) % 360
    self:UpdatePosition()
  end
  function b:SetHidden(v)
    self.db.hide = v and true or false
    self:SetShown(not self.db.hide)
  end

  -- one step of the drag: where is the cursor relative to the minimap centre?
  function b:DragStep()
    local mx, my = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale() or 1
    local cx, cy = Minimap:GetCenter()
    if not cx then return end
    self:SetAngle(UI.MinimapAngle(cx, cy, (mx or 0) / scale, (my or 0) / scale))
  end

  b:SetScript("OnDragStart", function(self)
    self.dragging = true
    UI.HideTip()
    self:SetScript("OnUpdate", self.DragStep)
  end)
  b:SetScript("OnDragStop", function(self)
    self.dragging = false
    self:SetScript("OnUpdate", nil)
  end)
  b:SetScript("OnMouseDown", function() icon:SetTexCoord(0, 1, 0, 1) end)
  b:SetScript("OnMouseUp", function() icon:SetTexCoord(0.05, 0.95, 0.05, 0.95) end)
  b:SetScript("OnClick", function(self, button)
    if self.dragging then return end
    if o.onClick then o.onClick(button, self) end
  end)
  b:SetScript("OnEnter", function(self)
    if self.dragging or not o.tooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    pcall(o.tooltip, GameTooltip)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", UI.HideTip)

  b:UpdatePosition()
  b:SetShown(db.hide ~= true)
  return b
end
