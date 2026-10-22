-- Duel card: compact opponent card near top center for 6 s after the duel countdown starts.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI
local M = A:NewModule("UIDuelCard")

local card, token = nil, 0

local function build(k)
  card = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  card:SetSize(330, 66)
  card:SetPoint("TOP", UIParent, "TOP", 0, -140)
  card:SetFrameStrata("HIGH")
  UI.Backdrop(card)
  card.icon = k.ClassIcon(card, 40)
  card.icon:SetPoint("LEFT", card, "LEFT", 10, 0)
  card.name = k.Label(card, { text = "", font = "big" })
  card.name:SetPoint("TOPLEFT", card, "TOPLEFT", 58, -10)
  card.line1 = k.Label(card, { text = "", font = "small", color = "muted" })
  card.line1:SetPoint("TOPLEFT", card, "TOPLEFT", 58, -30)
  card.line2 = k.Label(card, { text = "", font = "small" })
  card.line2:SetPoint("TOPLEFT", card, "TOPLEFT", 58, -44)
  card.crest = card:CreateTexture(nil, "ARTWORK")
  card.crest:SetSize(32, 32)
  card.crest:SetPoint("RIGHT", card, "RIGHT", -10, 0)
end

local function show(rec)
  local k = UI.Kit()
  if not k or not (A.db.config.card ~= false) or type(rec) ~= "table" then return end
  if not card then build(k) end
  local opp = rec.opp or {}
  if card.icon.SetClass then card.icon:SetClass(opp.class) end
  card.name:SetText(UI.ClassText(opp.class, opp.name and UI.Short(opp.name) or "Unknown challenger"))
  card.line1:SetText((opp.level and ("Level " .. opp.level) or "Level ?") .. "  -  " .. UI.VenueName(rec.venue))
  local st = ns.char and ns.char.streak or {}
  local atStake = (rec.venue and st.venue and st.venue[rec.venue]) or st.cur or 0
  local w, l = UI.RecordVs(opp.name)
  card.line2:SetText("Streak at stake: " .. UI.Tint("accent", atStake) .. "   You vs them: " .. UI.Tint("accent", w .. "-" .. l))
  local crest = UI.Crest(rec.venue)
  if crest then card.crest:SetTexture(crest) end
  card.crest:SetShown(crest ~= nil)
  card:Show()
  token = token + 1
  local mine = token
  A:After(6, function() if mine == token and card then card:Hide() end end)
end

function M:OnLogin()
  A:Listen("DUEL_COUNTDOWN", show)
  A:Listen("DUEL_RESOLVED", function() token = token + 1; if card then card:Hide() end end)
end
