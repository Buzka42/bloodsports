-- Minimap button and the native Settings panel. Settings keys are flat; a proxy maps them onto the nested config.
-- CONTRACT NOTE: MK.UI.Settings gets db = proxy table (flat keys: card, toasts, announce, autoList, ringPoints,
-- minimapHide, debug).

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI
local M = A:NewModule("UIMinimap")

local button, category

local function proxy()
  local c = A.db.config
  local map = {
    card = { c, "card" }, toasts = { c, "toasts" }, announce = { c, "announce" }, debug = { c, "debug" },
    autoList = { c.finder, "autoListAtVenue" }, minimapHide = { A.db.minimap, "hide" },
  }
  return setmetatable({}, {
    __index = function(_, key)
      if key == "ringPoints" then return c.ring.currency == "points" end
      local m = map[key]
      return m and m[1][m[2]]
    end,
    __newindex = function(_, key, v)
      if key == "ringPoints" then
        c.ring.currency = v and "points" or "gold"
      elseif map[key] then
        map[key][1][map[key][2]] = v
      end
      if key == "minimapHide" and button and button.SetShown then button:SetShown(not v) end
      UI.Refresh()
    end,
  })
end

function UI.OpenSettings()
  if category and Settings and Settings.OpenToCategory then
    local id = type(category) == "table" and category.GetID and UI.Try(category.GetID, category) or category
    UI.Try(Settings.OpenToCategory, id)
  else
    A:Print("Settings are unavailable; use /bs debug for the debug toggle.")
  end
end

local function tip(tt)
  tt:AddLine("Bloodsports", 0.82, 0.22, 0.12)
  local w, l = 0, 0
  for _, d in ipairs(UI.Duels()) do
    if d.result == "win" then w = w + 1 elseif d.result == "loss" then l = l + 1 end
  end
  tt:AddLine("Record " .. w .. "-" .. l .. "  Streak " .. ((ns.char and ns.char.streak.cur) or 0), 1, 1, 1)
  local n = A.PendingCount and A:PendingCount() or 0
  if n > 0 then tt:AddLine(n .. " rows waiting to sync", 0.7, 0.7, 0.7) end
  tt:AddLine("Left click: open   Right click: settings", 0.7, 0.7, 0.7)
end

function M:Init()
  local k = MK.UI
  if button or not (k and k.MinimapButton) then return end
  A.db.minimap = A.db.minimap or {}
  -- Older builds saved hide as 0/1 (0 is truthy in Lua, so the button stayed hidden) and angle 200,
  -- which is Elders' default and stacked the two buttons. Normalise both.
  A.db.minimap.hide = A.db.minimap.hide == true
  if A.db.minimap.angle == nil or A.db.minimap.angle == 200 then A.db.minimap.angle = 160 end
  local ok, b = pcall(k.MinimapButton, {
    name = "BloodsportsMinimapButton", icon = UI.Art("icon_bloodsports") or "Interface\\Icons\\Ability_DualWield",
    db = A.db.minimap, tooltip = tip,
    onClick = function(btn)
      if btn == "RightButton" then UI.OpenSettings() else A:Fire("TOGGLE_MAIN") end
    end,
  })
  if ok then button = b else A:Debug("minimap failed: " .. tostring(b)) end
  if k.Settings and not category then
    category = UI.Try(k.Settings, { name = "Bloodsports", db = proxy(), options = {
      { type = "header", label = "Duels" },
      { type = "check", key = "card", label = "Show the duel card", tooltip = "Opponent card when a duel countdown starts." },
      { type = "check", key = "toasts", label = "Show result toasts" },
      { type = "check", key = "announce", label = "Announce results" },
      { type = "header", label = "Finder and ring" },
      { type = "check", key = "autoList", label = "Auto-list me at duel venues" },
      { type = "check", key = "ringPoints", label = "Ring bets in points instead of gold" },
      { type = "header", label = "Misc" },
      { type = "check", key = "minimapHide", label = "Hide the minimap button" },
      { type = "check", key = "debug", label = "Debug output" },
    } })
  end
end

function M:OnLogin()
  self:Init()
  A:On("PLAYER_ENTERING_WORLD", function() M:Init() end)
end
