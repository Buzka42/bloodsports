-- Bloodsports UI: drives every tab, popup, toast, card, HUD and the tooltip hook. Uses a fake UI kit (this file only)
-- when MetaKit.UI.Window is absent, so the UI code is exercised before the real kit lands.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc", { login = false })
local MK = MetaKit
local A = ns.A

local made = { toasts = {}, confirms = {}, lists = {}, buttons = {}, dropdowns = {}, checks = {}, edits = {} }
local UI = MK.UI
local fake = not UI.Window

local function frame(parent) return CreateFrame("Frame", nil, parent or UIParent) end
if fake then
  io.write("  (MetaKit.UI.Window absent: using fake kit from this test)\n")
  local skins = {}
  function UI.RegisterSkin(n, t) skins[n] = t end
  function UI.Skin(n) skins[n] = skins[n] or {}; return skins[n] end
  function UI.Art(nsx, name) return nsx.Media and nsx.Media.has[name] and (nsx.Media.path .. name) or nil end
  function UI.Color() return 0.1, 0.1, 0.1, 1 end
  function UI.Window(o)
    local f = frame(); f.content = frame(f); f._shown = false
    function f:Toggle() self:SetShown(not self:IsShown()) end
    return f
  end
  function UI.Tabs(p, o)
    local f = frame(p)
    function f:Select(i) o.onSelect(i) end
    return f
  end
  function UI.Button(p, o)
    local f = frame(p)
    f:SetScript("OnClick", function() if o.onClick then o.onClick() end end)
    function f:SetEnabledState(v) self.enabled = v end
    return f
  end
  function UI.Label(p, o) local f = frame(p); f:SetText(o.text); return f end
  function UI.ClassIcon(p) local f = frame(p); function f:SetClass(c) self.class = c end; return f end
  function UI.Dropdown(p) local f = frame(p); function f:SetValue(v) self.value = v end; return f end
  function UI.Checkbox(p, o)
    local f = frame(p)
    f:SetScript("OnClick", function(self) self:SetChecked(not self:GetChecked()); o.onChange(self:GetChecked()) end)
    return f
  end
  function UI.EditBox(p) return frame(p) end
  function UI.List(p) local f = frame(p); f.data = {}; function f:SetData(d) self.data = d end; return f end
end
-- Record every widget the UI creates (wrapping real or fake constructors).
for name, bucket in pairs({ Button = "buttons", Dropdown = "dropdowns", Checkbox = "checks", EditBox = "edits", List = "lists" }) do
  local orig = UI[name]
  UI[name] = function(p, o) local f = orig(p, o); f._opts = o; table.insert(made[bucket], f); return f end
end
do
  local origC, origT = UI.Confirm, UI.Toast
  UI.Confirm = function(o) table.insert(made.confirms, o); if origC then return origC(o) end end
  UI.Toast = function(o) table.insert(made.toasts, o); if origT then return origT(o) end end
  local origM, origS = UI.MinimapButton, UI.Settings
  UI.MinimapButton = function(o) made.minimap = o; if origM then return origM(o) end return frame() end
  UI.Settings = function(o) made.settings = o; if origS then return origS(o) end return {} end
end
T.Fire("PLAYER_LOGIN")
T.Fire("PLAYER_ENTERING_WORLD", true, false)

-- Test doubles for the logic modules (always; keeps the data deterministic whatever has landed).
local fakes = { finder = true, club = true, ring = true }
ns.Finder = { entries = { duel = {}, club = {}, ring = {}, ref = {} }, calls = {} }
function ns.Finder.List(kind, venue) return ns.Finder.entries[kind] or {} end
function ns.Finder.Invite(name, c) table.insert(ns.Finder.calls, { "invite", name, c }) end
function ns.Finder.RequestInvite(name, kind, venue) table.insert(ns.Finder.calls, { "ask", name, kind, venue }) end
function ns.Finder.SetLooking(kind, venue, note) table.insert(ns.Finder.calls, { "look", kind, venue, note }) end
function ns.Finder.StopLooking() table.insert(ns.Finder.calls, { "stop" }) end
ns.Club = { calls = {} }
function ns.Club.Champions(v) return { Horde = { ROGUE = { name = "Champ-Realm", streak = 14, since = 1760000000 } } } end
function ns.Club.MyStreak(v) return 10 end
function ns.Club.CanChallenge(v) return true end
function ns.Club.Challenge(v) table.insert(ns.Club.calls, v) end
ns.Ring = { calls = {} }
for _, fn in ipairs({ "Open", "SetFighters", "Lock", "Verdict", "Void", "Close", "PlaceBet" }) do
  ns.Ring[fn] = function(...) table.insert(ns.Ring.calls, { fn, ... }) end
end

local function ago(s) return GetServerTime() - s end
local function seed()
  local d = ns.char.duels
  for i = 1, 6 do
    table.insert(d, { id = "m" .. i, t = ago(100 * i), dur = 30 + i, venue = i % 2 == 0 and "crossroads" or "honorroad",
      venueKind = i % 2 == 0 and "practice" or "club", opp = { name = "Foe" .. i .. "-Normal", class = i % 3 == 0 and "MAGE" or "ROGUE", level = 10 + i },
      me = { class = "WARRIOR", level = 12, hpEnd = 50 }, result = i == 5 and "void" or (i % 3 == 0 and "loss" or "win"),
      how = "knockout", firstBlood = i % 2 == 0 and "me" or "opp", confirmed = i == 1 and "both" or "self" })
  end
  ns.char.streak.cur, ns.char.streak.best = 3, 7
end


T.test("main window opens and every tab builds with seeded data", function()
  seed()
  T.Fire("PLAYER_ENTERING_WORLD", true, false)   -- minimap init after the (fake) kit exists
  SlashCmdList.BLOODSPORTS("")
  local win = ns.UI.MainWindow()
  T.ok(win and win:IsShown(), "window shown")
  for _, id in ipairs({ "duels", "matchups", "finder", "clubs", "ring" }) do
    A:Fire("TOGGLE_MAIN", id)
    T.ok(win:IsShown(), "shown on " .. id)
  end
  T.noErrors()
end)

T.test("duels tab lists newest first and respects the filter", function()
  A:Fire("TOGGLE_MAIN", "duels")
  local list
  for _, l in ipairs(made.lists) do if l._opts.columns[1].key == "result" then list = l end end
  T.ok(list, "duel list")
  T.eq(#list.data, 6)
  T.eq(list.data[1].raw.id, "m6")
  for _, dd in ipairs(made.dropdowns) do
    if dd._opts.items[1] and dd._opts.items[1].value == "all" then dd._opts.onSelect("club") end
  end
  T.eq(#list.data, 3)
end)

T.test("matchups tab tallies classes and venues", function()
  A:Fire("TOGGLE_MAIN", "matchups")
  local classes, venues
  for _, l in ipairs(made.lists) do
    if l._opts.columns[1].title == "Class" then classes = l end
    if l._opts.columns[1].title == "Venue" and l._opts.columns[1].key == "name" and #l._opts.columns == 6 then venues = l end
  end
  T.ok(classes and #classes.data == 2, "two classes")
  T.ok(venues and #venues.data == 2, "two venues")
end)

T.test("finder tab: rows, buttons, list-me, popups", function()
  ns.Finder.entries.duel = { { name = "Bob-Normal", kind = "duel", venue = "crossroads", class = "ROGUE", level = 20, streak = 3, seen = GetTime() - 30, note = "gg" } }
  ns.Finder.entries.ref = { { name = "Goblin-Normal", kind = "ref", venue = "ratchet", class = "MAGE", level = 40, rating = 4.5, seen = GetTime() - 5 } }
  A:Fire("TOGGLE_MAIN", "finder")
  local people, refs
  for _, l in ipairs(made.lists) do
    for _, c in ipairs(l._opts.columns) do if c.buttonText == "Invite" and c.key == "i" and #l._opts.columns == 9 then people = l end end
    for _, c in ipairs(l._opts.columns) do if c.buttonText == "Ask invite" and #l._opts.columns == 8 and l._opts.columns[7].buttonText == "Whisper" and l._opts.columns[1].key == "class" and l._opts.columns[2].title == "Name" then refs = l end end
  end
  T.ok(people and #people.data == 1, "people row")
  local row = people.data[1]
  local cols = people._opts.columns
  cols[8].onClick(row)   -- Invite
  T.eq(ns.Finder.calls[#ns.Finder.calls][1], "invite")
  cols[9].onClick(row)
  T.eq(ns.Finder.calls[#ns.Finder.calls][1], "ask")
  cols[7].onClick(row)   -- whisper (stub: no-op)
  for _, c in ipairs(made.checks) do if c._opts.label == "List me" then c:Click(); c:Click() end end
  T.eq(ns.Finder.calls[#ns.Finder.calls][1], "stop")
  -- popups
  local n = #made.confirms
  A:Fire("FINDER_INVITED", "Bob-Normal", "duel", "crossroads", "come fight")
  A:Fire("FINDER_REQUEST", "Gob-Normal", "ref", "ratchet", "")
  T.eq(#made.confirms, n + 2)
  made.confirms[#made.confirms].onAccept()
  T.eq(ns.Finder.calls[#ns.Finder.calls][1], "invite")
  T.noErrors()
end)

T.test("clubs tab roster, challenge button, popup", function()
  A:Fire("TOGGLE_MAIN", "clubs")
  local champs
  for _, l in ipairs(made.lists) do if l._opts.columns[4] and l._opts.columns[4].title == "Champion" then champs = l end end
  T.ok(champs and #champs.data == 1, "champion row")
  for _, b in ipairs(made.buttons) do
    if b._opts.text == "Challenge" then b:Click() end
  end
  if fakes.club then T.eq(ns.Club.calls[1], "honorroad") end
  local n = #made.confirms
  A:Fire("CLUB_CHALLENGED", "Rival-Normal", "honorroad")
  T.eq(#made.confirms, n + 1)
end)

T.test("ring tab: referee list, then host and bettor session views, HUD", function()
  A:Fire("TOGGLE_MAIN", "ring")
  local refList
  for _, l in ipairs(made.lists) do if l._opts.columns[2] and l._opts.columns[2].title == "Referee" then refList = l end end
  T.ok(refList and #refList.data == 1, "referee row")
  ns.Ring.session = { id = "r1", host = "Ref-Normal", venue = "ratchet", fighters = { "Aaa-Normal", "Bbb-Normal" }, status = "open",
    currency = "gold", bets = { { bettor = "Me-Normal", on = "Aaa-Normal", amount = 50000, paid = true } } }
  A:Fire("RING_UPDATED")
  T.Advance(1)
  T.ok(ns.UI.Session(), "session visible")
  local hud
  for _, f in ipairs(UIParent._children) do if f.pot then hud = f end end
  T.ok(hud and hud:IsShown(), "hud shown")
  T.ok(hud.pot:GetText():find("5g"), "pot text " .. tostring(hud.pot:GetText()))
  for _, b in ipairs(made.buttons) do if b._opts.text == "Place bet" then b:Click() end end   -- no amount: just prints
  for _, e in ipairs(made.edits) do if e._opts.placeholder == "Amount" then e._opts.onChange("2") end end
  for _, b in ipairs(made.buttons) do if b._opts.text == "Place bet" then b:Click() end end
  if fakes.ring then
    local c = ns.Ring.calls[#ns.Ring.calls]
    T.eq(c[1], "PlaceBet"); T.eq(c[2], "Aaa-Normal"); T.eq(c[3], 20000)
  end
  -- host view
  ns.Ring.session.host = "Tester-Normal"
  T.units.player = T.units.player or {}
  A:Fire("RING_UPDATED"); T.Advance(1)
  for _, name in ipairs({ "Lock bets", "A wins", "B wins", "Void", "Close ring" }) do
    for _, b in ipairs(made.buttons) do if b._opts.text == name then b:Click() end end
  end
  if fakes.ring then
    local seen = {}
    for _, c in ipairs(ns.Ring.calls) do seen[c[1]] = true end
    T.ok(seen.Lock and seen.Verdict and seen.Void and seen.Close, "host calls")
  end
  ns.Ring.session.status = "closed"
  A:Fire("RING_UPDATED")
  T.ok(not hud:IsShown(), "hud hidden after close")
  T.noErrors()
end)

T.test("duel card, toasts and confirmation", function()
  local rec = { id = "x1", t = GetServerTime(), dur = 20, venue = "crossroads", venueKind = "practice", opp = { name = "Foe1-Normal", class = "ROGUE", level = 12, hpEnd = 0, minHp = 0 },
    me = { class = "WARRIOR", race = "Human", level = 12, hpEnd = 40, minHp = 40 }, result = "win", how = "knockout", confirmed = "self", group = { raid = false, size = 1 } }
  A:Fire("DUEL_COUNTDOWN", rec)
  local card
  for _, f in ipairs(UIParent._children) do if f.line2 then card = f end end
  T.ok(card and card:IsShown(), "card shown")
  T.Advance(7)
  T.ok(not card:IsShown(), "card hidden after 6s")
  local n = #made.toasts
  A:Fire("DUEL_RESOLVED", rec)
  rec.confirmed = "both"
  A:Fire("DUEL_CONFIRMED", rec)
  T.eq(#made.toasts, n + 2)
  T.eq(made.toasts[n + 1].banner, "good")
  local loss = {}; for k2, v2 in pairs(rec) do loss[k2] = v2 end; loss.result = "loss"
  A:Fire("DUEL_RESOLVED", loss)
  T.eq(made.toasts[#made.toasts].banner, "bad")
  T.noErrors()
end)

T.test("tooltip hook adds record line for a player unit", function()
  T.units.mouseover = { name = "Foe1", realm = "Normal", class = "ROGUE", level = 11, isPlayer = true }
  function GameTooltip:GetUnit() return "Foe1", "mouseover" end
  GameTooltip:SetOwner()
  GameTooltip._scripts.OnTooltipSetUnit(GameTooltip)
  local found
  for _, l in ipairs(GameTooltip.lines) do if tostring(l):find("duels vs") then found = true end end
  T.ok(found, "record line")
  T.noErrors()
end)

T.test("minimap and settings registered; settings proxy maps flat keys", function()
  T.ok(made.minimap or not fake, "minimap button")
  if made.minimap then
    T.eq(made.minimap.name, "BloodsportsMinimapButton")
    made.minimap.onClick("LeftButton")
    local tt = { AddLine = function() end }
    made.minimap.tooltip(tt)
  end
  if made.settings then
    made.settings.db.ringPoints = true
    T.eq(A.db.config.ring.currency, "points")
    made.settings.db.autoList = true
    T.eq(A.db.config.finder.autoListAtVenue, true)
  end
  T.noErrors()
end)

T.test("graceful when modules are missing", function()
  local f, c, r = ns.Finder, ns.Club, ns.Ring
  ns.Finder, ns.Club, ns.Ring = nil, nil, nil
  for _, id in ipairs({ "finder", "clubs", "ring" }) do A:Fire("TOGGLE_MAIN", id) end
  A:Fire("RING_UPDATED")
  T.Advance(1)
  ns.Finder, ns.Club, ns.Ring = f, c, r
  T.noErrors()
end)

T.done()
