-- Ring HUD: small draggable pot/status readout (coin icon, gold-coloured amount) shown while in a ring session.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI
local M = A:NewModule("UIRingHUD")

local hud

local function build()
  hud = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  hud:SetSize(168, 46)
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
  coin:SetSize(16, 16)
  coin:SetPoint("TOPLEFT", hud, "TOPLEFT", 8, -8)
  coin:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
  hud.pot = hud:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  hud.pot:SetPoint("LEFT", coin, "RIGHT", 5, 0)
  hud.pot:SetTextColor(1, 0.85, 0.3)
  pcall(hud.pot.SetFont, hud.pot, "Fonts\\MORPHEUS.TTF", 14)
  hud.status = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hud.status:SetPoint("BOTTOMLEFT", hud, "BOTTOMLEFT", 10, 7)
  hud:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" then A:Fire("TOGGLE_MAIN", "ring") end
  end)
end

local STATUS = { open = "Bets open", locked = "Bets locked", settled = "Winner called", paid = "Paid out", void = "Void" }

function UI.UpdateHUD()
  local s = UI.Session()
  if not s then
    if hud then hud:Hide() end
    return
  end
  if not hud then build() end
  local _, _, total = UI.Pools(s)
  hud.pot:SetText(UI.Amount(total, s.currency))
  local fa, fb = UI.Fighters(s)
  local fight = (fa and fb) and (UI.Short(fa) .. " v " .. UI.Short(fb)) or "Awaiting fighters"
  hud.status:SetText((STATUS[s.status] or "?") .. " - " .. fight)
  hud:Show()
end

function M:OnLogin()
  A:Listen("RING_UPDATED", UI.UpdateHUD)
end
