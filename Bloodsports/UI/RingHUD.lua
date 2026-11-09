-- Ring HUD: small draggable readout while in a ring session: pool of the active market (coin, gold amount), the
-- market title + status with its lock / appeal countdown, and one line for my bet, an owed alert, the outcome
-- pills (max 4 + "+n") or the host's invite queue. Active market = the Ring tab's selection, else the busiest one
-- (UI.RingView.ActiveMarket). Right click opens the Ring tab.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI
local M = A:NewModule("UIRingHUD")

local W, H = 210, 60
local hud

local function line(parent, y, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, y)
  fs:SetWidth(W - 20)
  fs:SetJustifyH("LEFT")
  if fs.SetWordWrap then fs:SetWordWrap(false) end
  return fs
end

local function build()
  hud = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  hud:SetSize(W, H)
  hud:SetFrameStrata("MEDIUM")
  hud:SetClampedToScreen(true)
  hud:SetMovable(true)
  hud:EnableMouse(true)
  hud:RegisterForDrag("LeftButton")
  UI.Backdrop(hud)
  local pos = UI.Db().hud
  if pos and pos.point then hud:SetPoint(pos.point, UIParent, pos.rel or pos.point, pos.x or 0, pos.y or 0)
  else hud:SetPoint("TOP", UIParent, "TOP", 0, -60) end
  hud:SetScript("OnDragStart", hud.StartMoving)
  hud:SetScript("OnDragStop", function(f)
    f:StopMovingOrSizing()
    local point, _, rel, x, y = f:GetPoint()
    UI.Db().hud = { point = point, rel = rel, x = x, y = y }
  end)
  local coin = hud:CreateTexture(nil, "ARTWORK")
  coin:SetSize(14, 14)
  coin:SetPoint("TOPLEFT", hud, "TOPLEFT", 8, -7)
  coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
  hud.pot = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hud.pot:SetPoint("LEFT", coin, "RIGHT", 5, 0)
  hud.pot:SetTextColor(1, 0.85, 0.3)
  pcall(hud.pot.SetFont, hud.pot, "Fonts\\MORPHEUS.TTF", 14)
  hud.status = line(hud, -25)
  hud.extra = line(hud, -40)
  hud:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then A:Fire("TOGGLE_MAIN", "ring") end
  end)
end

-- Short pill for the HUD: "×2.87" (pari, no slip stake) or "1.80" (fixed).
local function shortPill(RV, s, m, i)
  if m.mode == "fixed" then
    local p = tonumber(m.outcomes[i].price) or 0
    return p > 100 and string.format("%d.%02d", math.floor(p / 100), p % 100) or "-"
  end
  local pv = RV.PariPreview((RV.Pools(s, m)), i, 0)
  if pv.W == 0 or not pv.d100 then return "—" end
  return string.format("×%d.%02d", math.floor(pv.d100 / 100), pv.d100 % 100)
end

local function extraLine(RV, s, m)
  local n, sum = RV.OwedToMe()
  if n > 0 then return UI.Tint("bad", "Host owes you " .. UI.Amount(sum, s.currency)) end
  if RV.IsHost(s) then
    local q = #(rawget(s, "inviteQueue") or {})
    if q > 0 then return UI.Tint("accent", "Invite (" .. q .. ") waiting") end
  end
  if not m then return "" end
  local b = RV.MyBet(s, m)
  if b then
    local payout, final = RV.MyPayout(s, m, b)
    return "You: " .. UI.Amount(b.amount, s.currency) .. " on " .. RV.Label(m, b.outcome)
      .. (payout and ((final and " · pays " or " · est ") .. UI.Amount(payout, s.currency)) or "")
  end
  local parts = {}
  for i = 1, math.min(4, #m.outcomes) do parts[#parts + 1] = RV.Label(m, i) .. " " .. shortPill(RV, s, m, i) end
  local more = #m.outcomes - 4
  return table.concat(parts, "  ") .. (more > 0 and ("  +" .. more) or "")
end

function UI.UpdateHUD()
  local s = UI.Session()
  local RV = UI.RingView
  if not s or not RV then
    if hud then hud:Hide() end
    return
  end
  if not hud then build() end
  local m = RV.ActiveMarket(s, UI.RingSelected)
  if m then
    local _, _, T = RV.Pools(s, m)
    hud.pot:SetText(UI.Amount(T, s.currency))
    hud.status:SetText((m.title or m.mid) .. " · " .. RV.MarketStatus(m))
  else
    hud.pot:SetText(UI.Amount(0, s.currency))
    hud.status:SetText(RV.IsHost(s) and "No markets yet" or "Awaiting markets")
  end
  hud.extra:SetText(extraLine(RV, s, m))
  hud:Show()
end

function M:OnLogin()
  A:Listen("RING_UPDATED", UI.UpdateHUD)
  A:Every(1, function() if hud and hud:IsShown() then UI.UpdateHUD() end end)   -- countdowns
end
