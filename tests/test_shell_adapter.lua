-- Bloodsports on the shared World of Meta shell: singleton, tab + five sections, lazy single build, TOGGLE_MAIN routing,
-- owner gating, event refresh. (The stub cannot show real layout, art or fonts: see the report, not this file.)
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local loaded = { Bloodsports = true }
C_AddOns.IsAddOnLoaded = function(n) return loaded[n] and true or false end   -- the stub says nothing is loaded
local MK, A, UI = MetaKit, ns.A, ns.UI
local IDS = { "duels", "matchups", "finder", "clubs", "ring" }

local function sec(shell, id)
  for _, s in ipairs(shell.sections.bloodsports or {}) do if s.id == id then return s end end
end

T.test("login queues the tab and sections; the shell is not built until first use", function()
  T.eq(MK.UI._sharedShell, nil, "no shell yet")
  local q = MK.UI._sharedState
  T.eq(#q.tabs, 1); T.eq(q.tabs[1].id, "bloodsports"); T.eq(q.tabs[1].owner, "Bloodsports")
  T.eq(#q.sections, 5)
end)

T.test("first TOGGLE_MAIN creates the shared shell with the bloodsports tab and 5 sections", function()
  A:Fire("TOGGLE_MAIN")
  local shell = MK.UI._sharedShell
  T.ok(shell, "shell created")
  T.eq(shell.name, "WorldOfMetaShell"); T.eq(_G.WorldOfMetaShell, shell.frame)
  T.eq(ns.UI.MainWindow(), shell)
  T.ok(shell:IsShown(), "shown")
  T.eq(#MK.UI._sharedState.tabs + #MK.UI._sharedState.sections, 0, "queue drained")
  local tab = shell.tabById.bloodsports
  T.ok(tab, "tab"); T.eq(tab.label, "Bloodsports"); T.eq(tab.owner, "Bloodsports"); T.eq(type(tab.summary), "function")
  T.eq(#shell.sections.bloodsports, 5)
  for i, id in ipairs(IDS) do
    local s = sec(shell, id)
    T.ok(s, "section " .. id); T.eq(s.order, i); T.eq(type(s.build), "function")
  end
  T.eq(shell.current, "bloodsports")
  T.noErrors()
end)

T.test("shared shell is a singleton: a second SharedShell call (other db) returns the same object", function()
  local a = MK.UI.SharedShell({})
  local b = MK.UI.SharedShell({ pos = { "TOP", "TOP", 0, 0 } }, { Media = {} })
  T.eq(a, b); T.eq(a, MK.UI._sharedShell); T.eq(a, ns.UI.SharedShell())
  T.eq(a.db, A.db.ui.shell, "db is the first caller's (Bloodsports' ui.shell)")
end)

T.test("each section's build runs once, however often it is selected or refreshed", function()
  local shell = MK.UI._sharedShell
  for _ = 1, 3 do
    for _, id in ipairs(IDS) do A:Fire("TOGGLE_MAIN", id); shell:Refresh() end
  end
  A:Fire("RING_UPDATED"); T.Advance(1)
  for _, id in ipairs(IDS) do
    local s = sec(shell, id)
    T.eq(s.buildCount, 1, id .. " built once")
    T.ok(s.built and not s.error, id .. " built without error")
  end
  T.eq(shell.lastError, false, "no shell error")
  T.noErrors()
end)

T.test("TOGGLE_MAIN selects the bloodsports tab (and a named section) from any other tab", function()
  local shell = MK.UI._sharedShell
  loaded.Other = true
  MK.UI.RegisterSharedTab({ id = "other", label = "Other", owner = "Other", order = 0 })
  MK.UI.RegisterSharedSection({ tab = "other", id = "x", label = "X", build = function(p) return CreateFrame("Frame", nil, p) end })
  shell:Select("other")
  T.eq(shell.current, "other")
  A:Fire("TOGGLE_MAIN", "finder")
  T.eq(shell.current, "bloodsports"); T.eq(shell.currentSection, "finder"); T.ok(shell:IsShown())
  A:Fire("TOGGLE_MAIN", "finder")
  T.ok(shell:IsShown(), "a named section never closes the window")
  shell:Select("other")
  A:Fire("TOGGLE_MAIN")
  T.eq(shell.current, "bloodsports"); T.ok(shell:IsShown(), "no argument from another tab: switches, stays open")
  A:Fire("TOGGLE_MAIN")
  T.ok(not shell:IsShown(), "no argument on the bloodsports tab: closes")
  A:Fire("TOGGLE_MAIN", "nonsense")
  T.ok(shell:IsShown(), "an unknown section id just toggles (opens a closed window)")
  A:Fire("TOGGLE_MAIN", "nonsense")
  T.ok(not shell:IsShown(), "... and closes an open one on the bloodsports tab")
  SlashCmdList.BLOODSPORTS("ring"); T.eq(shell.currentSection, "ring"); T.ok(shell:IsShown())
  T.noErrors()
end)

T.test("owner gating: Bloodsports alone shows only its tab", function()
  local shell = MK.UI._sharedShell
  loaded.Other = nil
  local vis = shell:VisibleTabs()
  T.eq(#vis, 1); T.eq(vis[1].id, "bloodsports")
  shell:Refresh()
  T.eq(shell.current, "bloodsports")
  T.eq(shell:Select("other"), false, "unloaded tab cannot be selected")
end)

T.test("sections refresh on show and on duel events; the sidebar summary follows the record", function()
  local shell = MK.UI._sharedShell
  A:Fire("TOGGLE_MAIN", "duels")
  local pane = sec(shell, "duels").frame
  T.ok(pane and pane.list, "duels pane built into the section host")
  T.eq(#pane.list.data, 0)
  table.insert(ns.char.duels, { id = "s1", t = GetServerTime(), dur = 20, venue = "crossroads", venueKind = "practice",
    opp = { name = "Foe-Normal", class = "MAGE", level = 12 }, me = { class = "WARRIOR", level = 12, hpEnd = 40 },
    result = "win", firstBlood = "me", confirmed = "self" })
  A:Fire("CLUB_UPDATED"); T.Advance(0.5)   -- one of the events the adapter refreshes on
  T.eq(#pane.list.data, 1, "list refreshed by the event")
  local lines = shell:SummaryLines(shell.tabById.bloodsports)
  T.eq(lines[1].label, "Record"); T.eq(lines[1].value, "1-0")
  -- re-selecting another section and back refreshes the pane again
  table.insert(ns.char.duels, { id = "s2", t = GetServerTime(), dur = 20, venue = "crossroads", venueKind = "practice",
    opp = { name = "Foe2-Normal", class = "ROGUE", level = 12 }, me = { class = "WARRIOR", level = 12, hpEnd = 40 },
    result = "loss", firstBlood = "opp", confirmed = "self" })
  A:Fire("TOGGLE_MAIN", "matchups"); A:Fire("TOGGLE_MAIN", "duels")
  T.eq(#pane.list.data, 2, "onShow refresh")
  T.noErrors()
end)

T.test("a failing section build is logged and shown as a notice, not retried", function()
  local shell = MK.UI._sharedShell
  local good = UI.tabDefs.clubs
  local s = sec(shell, "clubs")
  UI.tabDefs.clubs = function() error("boom") end
  MK.UI.RegisterSharedSection({ tab = "bloodsports", id = "clubs", label = "Clubs", order = 4, build = s.build, onShow = s.onShow })
  A:Fire("TOGGLE_MAIN", "clubs")
  local s2 = sec(shell, "clubs")
  T.ok(s2.error and s2.error:find("boom"), "build error kept on the section")
  T.eq(s2.buildCount, 1)
  A:Fire("TOGGLE_MAIN", "clubs"); shell:Refresh()
  T.eq(s2.buildCount, 1, "not retried")
  UI.tabDefs.clubs = good
  local logged = false
  for _, line in ipairs(T.printed) do if line:find("build clubs", 1, true) then logged = true end end
  T.ok(logged, "the build error was logged through A:Error")
end)

T.done()
