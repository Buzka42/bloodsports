-- UI kit: Rating, a row of clickable glyphs (leaves, blades, stars). Defaults to the stock raid-star icon,
-- drawn desaturated and dim for empty glyphs, so it works with no custom art.

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI
local T = UI.Tex

function UI.Rating(parent, o)
  o = o or {}
  local s = UI.Skin(o.skin)
  local count, size = o.count or 5, o.size or 26
  local full = o.full or s.glyphFull
  local empty = o.empty or s.glyphEmpty
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(count * (size + 4) - 4, size)
  f.value, f.hover, f.glyphs = 0, false, {}

  local function paint()
    local shown = f.hover or f.value
    for i, g in ipairs(f.glyphs) do
      local on = i <= shown
      if on then
        g.tex:SetTexture(full or T.star)
        g.tex:SetDesaturated(false)
        g.tex:SetAlpha(f.hover and 0.8 or 1)
      else
        g.tex:SetTexture(empty or full or T.star)
        g.tex:SetDesaturated(empty == nil)
        g.tex:SetAlpha(empty and 1 or 0.35)
      end
    end
  end

  for i = 1, count do
    local g = CreateFrame("Button", nil, f)
    g:SetSize(size, size)
    g:SetPoint("LEFT", f, "LEFT", (i - 1) * (size + 4), 0)
    g.tex = g:CreateTexture(nil, "ARTWORK")
    g.tex:SetAllPoints(g)
    g:RegisterForClicks("LeftButtonUp")
    g:SetScript("OnEnter", function() f.hover = i; paint() end)
    g:SetScript("OnLeave", function() f.hover = false; paint() end)
    g:SetScript("OnClick", function()
      if not f.mkEnabled then return end
      UI.Sound("click")
      f:SetValue(i)
      if o.onChange then o.onChange(i) end
    end)
    f.glyphs[i] = g
  end
  f.mkEnabled = true

  function f:GetValue() return self.value end
  function f:SetValue(n)
    self.value = MK.Util.Clamp(math.floor(tonumber(n) or 0), 0, count)
    paint()
  end
  function f:SetEnabledState(v)
    self.mkEnabled = v and true or false
    self:SetAlpha(v and 1 or 0.5)
  end
  f:SetValue(o.value or 0)
  return f
end
