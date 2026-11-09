-- Main window adapter: Bloodsports is one tab ("bloodsports") of the shared World of Meta shell (MetaKit
-- UI.SharedShell). The five section builders (DuelsTab, MatchupsTab, FinderTab, ClubsTab, RingTab) keep their
-- UI.RegisterTab(id, build(pane) -> refresh) contract; each build now runs once, into the section's host frame in the
-- shell's content pane (Shell:BuildSection), and its refresh function is called whenever the section is in view.
-- CONTRACT NOTE: the old standalone BloodsportsMain window is gone; UI.MainWindow() returns the shared shell (its
-- :IsShown(), .frame and .content work as before).
-- CONTRACT NOTE: TOGGLE_MAIN's argument is a section id (duels, matchups, finder, clubs, ring); none = toggle.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI
local M = A:NewModule("UIMain")

local TAB = "bloodsports"
local ICON = "Interface\\Icons\\"
local SECTIONS = {
  { id = "duels", label = "My Duels", icon = "Ability_DualWield" },
  { id = "matchups", label = "Matches", icon = "INV_Misc_Note_01" },
  { id = "finder", label = "Finder", icon = "Ability_Hunter_SniperShot" },
  { id = "clubs", label = "Clubs", icon = "INV_BannerPVP_02" },
  { id = "ring", label = "The Ring", icon = "INV_Sword_04" },
}

local SECTION_IDS = {}
for _, def in ipairs(SECTIONS) do SECTION_IDS[def.id] = true end

local panes = {}      -- section id -> { refresh = fn }
local registered = false

local function shell() return MK.UI and MK.UI._sharedShell end

local function currentSection()
  local s = shell()
  return s and s.current == TAB and s.currentSection or nil
end

local function refreshCurrent()
  local s, id = shell(), currentSection()
  local p = id and panes[id]
  if s and p and p.refresh and s:IsShown() then
    local ok, err = pcall(p.refresh)
    if not ok then A:Error("tab " .. id, err) end
  end
end
UI.Refresh = refreshCurrent

-- Sidebar summary block: lifetime record from the local duel history (voids skipped).
local function summary()
  local w, l = 0, 0
  for _, d in ipairs(UI.Duels()) do
    if d.result == "win" then w = w + 1 elseif d.result == "loss" then l = l + 1 end
  end
  local st = ns.char and ns.char.streak or {}
  local rate = UI.Pct(w, w + l)
  return {
    { "Record", w .. "-" .. l },
    { "Win rate", rate, (w + l > 0 and w / (w + l) >= 0.5) and "good" or nil },
    { "Streak", tostring(st.cur or 0), (st.cur or 0) > 0 and "good" or nil },
    { "Best streak", tostring(st.best or 0) },
  }
end

-- Wraps a RegisterTab build fn as a shell section build: the shell pcalls it once, into its host frame. A build error
-- is logged and re-raised so the shell keeps its "could not be built" notice and shell.lastError.
local function sectionBuild(id)
  return function(parent)
    local build = UI.tabDefs[id]
    if not build then error("no build function registered for " .. id, 0) end
    local ok, refresh = pcall(build, parent)
    if not ok then A:Error("build " .. id, refresh) error(refresh, 0) end
    panes[id] = { frame = parent, refresh = type(refresh) == "function" and refresh or nil }
  end
end

local function register()
  if registered then return true end
  local k = MK.UI
  if not (k and k.RegisterSharedTab and k.RegisterSharedSection and k.SharedShell) then return false end
  registered = true
  k.SharedShellNamespace(ns)
  k.RegisterSharedTab({ id = TAB, label = "Bloodsports", owner = ADDON, order = 1, summary = summary })
  for i, def in ipairs(SECTIONS) do
    k.RegisterSharedSection({ tab = TAB, id = def.id, label = def.label, order = i, icon = ICON .. def.icon,
      build = sectionBuild(def.id), onShow = function() refreshCurrent() end })
  end
  return true
end
UI.RegisterShared = register

function UI.SharedShell()
  if not register() then
    A:Print("UI kit missing - reinstall the addon.")
    return nil
  end
  UI.Db().shell = UI.Db().shell or {}
  return MK.UI.SharedShell(UI.Db().shell, ns)
end

-- section = a section id (open on it, never closes) or nil (toggle the window on the Bloodsports tab).
function UI.Open(section)
  local s = UI.SharedShell()
  if not s then return end
  if section and not SECTION_IDS[section] then section = nil end   -- an unknown id just toggles
  if section then
    s:Select(TAB, section)
    s:Show()
  else
    s:Toggle(TAB)
  end
  refreshCurrent()
end

function UI.MainWindow() return shell() end

function M:OnLogin()
  register()
  A:Listen("TOGGLE_MAIN", UI.Open)
  A:Every(5, refreshCurrent)
  local function soon() A:Debounce("bsui", 0.2, function()
    local s = shell()
    if s and s:IsShown() then pcall(s.Refresh, s) end   -- re-lays the sidebar summary
    refreshCurrent()
  end) end
  for _, msg in ipairs({ "DUEL_RESOLVED", "DUEL_CONFIRMED", "LOBBY_UPDATED", "CLUB_UPDATED", "RING_UPDATED" }) do
    A:Listen(msg, soon)
  end
end
