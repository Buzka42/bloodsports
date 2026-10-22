-- Main window: tab strip (Duels / Matches / Finder / Clubs / Ring), lazy pane creation, refresh plumbing.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI
local M = A:NewModule("UIMain")

local TAB_H = 28   -- tab height 24 plus 4 px gap
local TABS = {
  { id = "duels", label = "Duels" }, { id = "matchups", label = "Matches" }, { id = "finder", label = "Finder" },
  { id = "clubs", label = "Clubs" }, { id = "ring", label = "Ring" },
}
local win, tabs, panes, current

local WIN_W, GUTTER = 640, 8

-- Content width of the window (window width minus both gutters); the stub reports 0 before layout.
local function contentWidth()
  local w = win and win.content and win.content:GetWidth()
  if not w or w <= 0 then w = WIN_W - 2 * GUTTER end
  return w
end

local function indexOf(id)
  for i, t in ipairs(TABS) do if t.id == id then return i end end
end

local function refreshCurrent()
  local p = current and panes[current]
  if p and p.refresh and win and win:IsShown() then
    local ok, err = pcall(p.refresh)
    if not ok then A:Error("tab " .. current, err) end
  end
end
UI.Refresh = refreshCurrent

local function showTab(i)
  local id = TABS[i] and TABS[i].id
  if not id then return end
  if not panes[id] then
    local build = UI.tabDefs[id]
    local pane = CreateFrame("Frame", nil, win.content)
    pane:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, -TAB_H)
    pane:SetPoint("BOTTOMRIGHT", win.content, "BOTTOMRIGHT", 0, 0)
    local ok, refresh = true, nil
    if build then ok, refresh = pcall(build, pane) end
    if not ok then A:Error("build " .. id, refresh) refresh = nil end
    panes[id] = { frame = pane, refresh = refresh }
  end
  for pid, p in pairs(panes) do p.frame:SetShown(pid == id) end
  current = id
  UI.Db().tab = id
  refreshCurrent()
end

local function ensureWindow()
  local k = UI.Kit()
  if not k then A:Print("UI kit missing - reinstall the addon.") return false end
  if win then return true end
  panes = {}
  win = k.Window({ name = "BloodsportsMain", skin = UI.SKIN, width = WIN_W, height = 520, title = "Bloodsports",
    subtitle = "Duels, clubs and the ring", db = UI.Db() })
  local labels = {}
  for i, t in ipairs(TABS) do labels[i] = t.label end
  tabs = k.Tabs(win.content, { labels = labels, width = contentWidth(), skin = UI.SKIN, onSelect = showTab })
  tabs:SetPoint("TOPLEFT", win.content, "TOPLEFT", 0, 0)
  A:Every(5, refreshCurrent)
  return true
end

function UI.Open(tabId)
  if not ensureWindow() then return end
  local want = tabId and indexOf(tabId)
  if not want then
    win:Toggle()
    if not win:IsShown() then return end
    want = indexOf(current or UI.Db().tab) or 1
  else
    win:Show()
  end
  if tabs and tabs.Select then tabs:Select(want) else showTab(want) end
  if current ~= TABS[want].id then showTab(want) end
  refreshCurrent()
end

function UI.MainWindow() return win end

function M:OnLogin()
  A:Listen("TOGGLE_MAIN", UI.Open)
  local function soon() A:Debounce("bsui", 0.2, refreshCurrent) end
  for _, msg in ipairs({ "DUEL_RESOLVED", "DUEL_CONFIRMED", "LOBBY_UPDATED", "CLUB_UPDATED", "RING_UPDATED" }) do
    A:Listen(msg, soon)
  end
end
