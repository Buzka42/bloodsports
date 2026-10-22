-- UI kit: TalkingHead, a 570x155 speech panel (portrait, name, wrapped text, optional buttons and a custom
-- `.body` frame) in the style of Blizzard's talking head. One shows at a time, the rest queue.
--   UI.TalkingHead{ skin, portrait | unit | displayID, name, text, duration, buttons, onClose, height, key }
-- CONTRACT NOTE: duration defaults to 8 s; duration = 0 keeps the head open until closed (use it with buttons).
-- `key` is optional: a head with the same key already active or queued is returned instead of a duplicate.
-- UI.TalkingHeadTick(dt) advances the active head (its OnUpdate calls it).

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI
local T = UI.Tex

local W, DEFAULT_H, MAX_QUEUE = 570, 155, 10
local FADE_IN, FADE_OUT, TEXT_X = 0.25, 0.45, 144

local current
local queue = {}

local function setupPortrait(f, o, s)
  local pf = CreateFrame("Frame", nil, f, "BackdropTemplate")
  pf:SetSize(115, 115)
  pf:SetPoint("TOPLEFT", f, "TOPLEFT", 15, -16)
  UI.Backdrop(pf, "tip", s, UI.WithAlpha(s.bg, 1), UI.WithAlpha(s.edge, 0.9))
  local bg = pf:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("TOPLEFT", pf, "TOPLEFT", 3, -3)
  bg:SetPoint("BOTTOMRIGHT", pf, "BOTTOMRIGHT", -3, 3)
  if not UI.SetAtlas(bg, "TalkingHeads-PortraitBg") then bg:SetColorTexture(s.bg[1] * 0.7, s.bg[2] * 0.7, s.bg[3] * 0.7, 1) end
  f.portraitFrame = pf
  if o.portrait then
    local tex = pf:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", pf, "TOPLEFT", 4, -4)
    tex:SetPoint("BOTTOMRIGHT", pf, "BOTTOMRIGHT", -4, 4)
    tex:SetTexture(o.portrait)
    tex:SetTexCoord(0.04, 0.96, 0.04, 0.96)
    f.portraitTex = tex
  elseif o.unit or o.displayID then
    local m = CreateFrame("PlayerModel", nil, pf)
    m:SetPoint("TOPLEFT", pf, "TOPLEFT", 4, -4)
    m:SetPoint("BOTTOMRIGHT", pf, "BOTTOMRIGHT", -4, 4)
    if o.unit then pcall(m.SetUnit, m, o.unit) else pcall(m.SetDisplayInfo, m, o.displayID) end
    pcall(m.SetPortraitZoom, m, 1)
    pcall(m.SetCamDistanceScale, m, 0.9)
    pcall(m.SetAnimation, m, 60)
    f.model = m
  elseif s.portrait then
    local tex = pf:CreateTexture(nil, "ARTWORK")
    tex:SetPoint("TOPLEFT", pf, "TOPLEFT", 4, -4)
    tex:SetPoint("BOTTOMRIGHT", pf, "BOTTOMRIGHT", -4, 4)
    tex:SetTexture(s.portrait)
    f.portraitTex = tex
  else
    pf:Hide()
    f.noPortrait = true
  end
end

local function build(o)
  local s = UI.Skin(o.skin)
  local h = o.height or DEFAULT_H
  local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  f.skin, f.opts, f.key = s, o, o.key or false
  f.model, f.noPortrait, f.state = false, false, false
  f:SetSize(W, h)
  f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 130)
  f:SetFrameStrata("DIALOG")
  f:SetFrameLevel(120)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  f:SetAlpha(0)

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints(f)
  if UI.SetAtlas(bg, "TalkingHeads-TextBackground") then
    f.atlasBackground = true
  else
    bg:Hide()
    UI.Backdrop(f, "window", s)
  end
  setupPortrait(f, o, s)
  local tx = f.noPortrait and 24 or TEXT_X

  f.name = UI.Label(f, { skin = s, font = "big", text = o.name or "" })
  f.name:SetShadowOffset(2, -2)
  f.name:SetPoint("TOPLEFT", f, "TOPLEFT", tx, -25)
  f.name:SetWidth(W - tx - 44)
  f.text = UI.Label(f, { skin = s, font = "large", wrap = true, width = W - tx - 30, text = o.text or "" })
  f.text:SetPoint("TOPLEFT", f, "TOPLEFT", tx, -52)

  local hasButtons = type(o.buttons) == "table" and #o.buttons > 0
  f.body = CreateFrame("Frame", nil, f)
  f.body:SetPoint("TOPLEFT", f.text, "BOTTOMLEFT", 0, -6)
  f.body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, hasButtons and 46 or 16)

  f.buttons = {}
  if hasButtons then
    local x = -18
    for i = #o.buttons, 1, -1 do
      local spec = o.buttons[i]
      local b = UI.Button(f, { skin = s, text = spec.text, height = 26, variant = spec.variant or (i == #o.buttons and "accent" or "default"),
        onClick = function(btn, button)
          if spec.onClick then spec.onClick(f, btn, button) end
          if spec.close ~= false then f:Close() end
        end })
      b:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", x, 14)
      x = x - b:GetWidth() - 8
      f.buttons[i] = b
    end
  end

  local close = UI.Button(f, { skin = s, text = "X", width = 20, height = 20, onClick = function() f:Close() end })
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -12)
  f.closeButton = close

  f:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then self:Close() end
  end)
  f:Hide()
  return f
end

local function startNext()
  current = nil
  local nxt = table.remove(queue, 1)
  if not nxt then return end
  current = nxt
  nxt.state, nxt.age = "in", 0
  nxt:SetAlpha(0)
  nxt:Show()
  nxt:SetScript("OnUpdate", function(_, dt) UI.TalkingHeadTick(dt) end)
end

local function finish(f)
  f:SetScript("OnUpdate", nil)
  f:Hide()
  f.state = "done"
  if f.model then pcall(f.model.SetAnimation, f.model, 0) end
  local cb = f.opts.onClose
  if f == current then startNext() end
  if cb then cb(f) end
end

function UI.TalkingHeadTick(dt)
  local f = current
  if not f then return end
  f.age = f.age + (dt or 0)
  if f.state == "in" then
    f:SetAlpha(math.min(1, f.age / FADE_IN))
    if f.age >= FADE_IN then f.state, f.age = "hold", 0 f:SetAlpha(1) end
  elseif f.state == "hold" then
    local d = f.opts.duration
    if d == nil then d = 8 end
    if d > 0 and f.age >= d and not f:IsMouseOver() then f.state, f.age = "out", 0 end
  elseif f.state == "out" then
    f:SetAlpha(math.max(0, 1 - f.age / FADE_OUT))
    if f.age >= FADE_OUT then finish(f) end
  end
end

function UI.TalkingHead(o)
  o = o or {}
  if o.key then
    if current and current.key == o.key then return current end
    for _, q in ipairs(queue) do if q.key == o.key then return q end end
  end
  local f = build(o)
  function f:Close()
    if self.state == "out" or self.state == "done" then return end
    if self == current then
      self.state, self.age = "out", 0
      self.age = FADE_OUT * (1 - (self:GetAlpha() or 1))
    else
      for i, q in ipairs(queue) do
        if q == self then table.remove(queue, i) break end
      end
      self.state = "done"
      if self.opts.onClose then self.opts.onClose(self) end
    end
  end
  if #queue >= MAX_QUEUE then
    f.state = "done"
    return f
  end
  queue[#queue + 1] = f
  if not current then startNext() end
  return f
end

function UI.TalkingHeadState() return current, #queue end
