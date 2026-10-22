-- UI kit: Toast. Our own 340x78 panel (Forever lacks the achievement alert atlases). Up to 3 stack from the
-- bottom centre, extras queue. The OnUpdate driver only runs while toasts exist.
--   UI.Toast{ skin, title, text, icon, banner = "good"|"bad"|nil, duration = 5, sound } -> handle { Dismiss() }
--   UI.ToastTick(dt), UI.ToastClear(), UI.ToastState() -> activeCount, queuedCount

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI
local T = UI.Tex

local W, H, GAP, BASE_Y, MAX_VISIBLE, MAX_QUEUE = 340, 78, 8, 150, 3, 20
local FADE_IN, FADE_OUT = 0.3, 0.45

local active, queue, free = {}, {}, {}
local driver

local function build()
  local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  f:SetSize(W, H)
  f:SetFrameStrata("DIALOG")
  f:SetFrameLevel(200)
  f:EnableMouse(true)
  f:Hide()
  f.banner = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  f.banner:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -3)
  f.banner:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -3, 3)
  f.strip = f:CreateTexture(nil, "ARTWORK")
  f.strip:SetWidth(4)
  f.strip:SetPoint("TOPLEFT", f, "TOPLEFT", 3, -3)
  f.strip:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 3, 3)
  f.icon = UI.Icon(f, { size = 48, ring = "edge" })
  f.icon:SetPoint("LEFT", f, "LEFT", 16, 0)
  f.title = UI.Label(f, { font = "body", color = "title", width = W - 100 })
  f.text = UI.Label(f, { font = "small", color = "text", width = W - 100, wrap = true })
  f:SetScript("OnEnter", function(self) self.mkItem.hover = true end)
  f:SetScript("OnLeave", function(self) self.mkItem.hover = false end)
  f:SetScript("OnMouseUp", function(self) self.mkItem.age = math.max(self.mkItem.age, FADE_IN + self.mkItem.duration) end)
  return f
end

local function configure(f, o)
  local s = UI.Skin(o.skin)
  local banner = o.banner
  local key = banner == "good" and "good" or banner == "bad" and "bad" or nil
  -- flat: skin banner art is ignored
  UI.Backdrop(f, "tip", s, UI.WithAlpha(UI.Tokens.bg, 0.97), key and UI.Tokens[key] or UI.Tokens.border)
  f.banner:Hide()
  if key then
    f.strip:SetColorTexture(s[key][1], s[key][2], s[key][3], 1)
    f.strip:Show()
  else
    f.strip:Hide()
  end
  f.icon:SetIcon(o.icon or s.icon or T.note)
  if f.icon.ring then f.icon.ring:SetVertexColor(UI.Color(s, "edge")) end
  f.title:SetTextColor(UI.Color(s, "title"))
  f.title:ClearAllPoints()
  f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 76, -14)
  f.title:SetText(o.title or "")
  f.text:SetTextColor(UI.Color(s, "text"))
  f.text:ClearAllPoints()
  f.text:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
  f.text:SetText(o.text or "")
end

local function slotY(i) return BASE_Y + (i - 1) * (H + GAP) end

local function place(item)
  local f = item.frame
  f:ClearAllPoints()
  f:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, item.curY + item.slide)
end

local function release(item)
  item.frame:Hide()
  item.frame.mkItem = nil
  free[#free + 1] = item.frame
  item.frame = nil
  item.done = true
end

local function start(item)
  local f = table.remove(free) or build()
  item.frame, f.mkItem = f, item
  configure(f, item.o)
  item.age, item.slide, item.alpha = 0, -24, 0
  item.curY = slotY(#active + 1)
  f:SetAlpha(0)
  place(item)
  f:Show()
  active[#active + 1] = item
  if item.o.sound then UI.Sound(item.o.sound == true and "toast" or item.o.sound) end
end

local function fillFromQueue()
  while #active < MAX_VISIBLE and #queue > 0 do start(table.remove(queue, 1)) end
end

function UI.ToastTick(dt)
  dt = dt or 0
  for i = #active, 1, -1 do
    local item = active[i]
    if not item.hover then item.age = item.age + dt end
    local a, slide = 1, 0
    if item.age < FADE_IN then
      local p = item.age / FADE_IN
      a, slide = p, -24 * (1 - p) * (1 - p)
    elseif item.age > FADE_IN + item.duration then
      a = 1 - (item.age - FADE_IN - item.duration) / FADE_OUT
    end
    if a <= 0 and item.age > FADE_IN then
      release(item)
      table.remove(active, i)
    else
      item.slide = slide
      item.frame:SetAlpha(math.min(1, a))
    end
  end
  fillFromQueue()
  for i, item in ipairs(active) do
    local target = slotY(i)
    item.curY = item.curY + (target - item.curY) * math.min(1, dt * 10)
    if math.abs(target - item.curY) < 0.5 then item.curY = target end
    place(item)
  end
  if #active == 0 and #queue == 0 and driver then driver:Hide() end
end

function UI.ToastState() return #active, #queue end

function UI.ToastClear()
  for i = #active, 1, -1 do
    release(active[i])
    active[i] = nil
  end
  for i = #queue, 1, -1 do queue[i] = nil end
  if driver then driver:Hide() end
end

function UI.Toast(o)
  o = o or {}
  if not driver then
    driver = CreateFrame("Frame")
    driver:SetScript("OnUpdate", function(_, dt) UI.ToastTick(dt) end)
  end
  local item = { o = o, duration = o.duration or 5, age = 0, slide = 0, curY = 0 }
  item.Dismiss = function(self)
    if self.frame then
      self.age = math.max(self.age, FADE_IN + self.duration)
    else
      for i, q in ipairs(queue) do
        if q == self then table.remove(queue, i) break end
      end
    end
  end
  if #queue >= MAX_QUEUE then return item end
  driver:Show()
  if #active < MAX_VISIBLE then start(item) else queue[#queue + 1] = item end
  return item
end
