-- JUDGE3 fix lane (F-1 .. F-12, S6, S8): column geometry, empty states + collapse, footers, the scoped Duels strip,
-- button tiers, native checks / dropdown arrows and the sidebar context cards, on the real MetaKit kit.
-- Stub limits: no rendering and a 6 px/char text measure (GetStringWidth = #text * 6), no real font metrics, so
-- "fits" means "fits at 6 px/char" (the client's small font is narrower: ~5 px/char) and geometry is the computed
-- List:LayoutColumns / anchor maths at an explicit 674 px inset width, never pixels. The stub accepts every template,
-- so the native-check path runs; the flat fallback is proven in the kit suite.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
C_AddOns.IsAddOnLoaded = function(n) return n == "Bloodsports" end
local MK, A, UI = MetaKit, ns.A, ns.UI
local K = MK.UI
local DASH = "\226\128\148"
local INSET_W = 674   -- the main-pane list inset measured in JUDGE3

local function sec(shell, id)
  for _, s in ipairs(shell.sections.bloodsports or {}) do if s.id == id then return s end end
end
local function pane(id)
  A:Fire("TOGGLE_MAIN", id)
  return sec(MK.UI._sharedShell, id).frame
end
local function col(l, title) for _, c in ipairs(l.columns) do if c.title == title then return c end end end

-- Header x-ranges from List:LayoutColumns: pairwise disjoint, each label inside its text box, columns within the
-- shared width; and every fixed column is at least its label + the 16 px gutter wide.
local function assertHeaders(l, name)
  l:SetWidth(INSET_W); l:LayoutColumns()
  T.eq(#l.headerIssues, 0, name .. " header issues: " .. (l.headerIssues[1] and (l.headerIssues[1].kind .. " "
    .. tostring(l.headerIssues[1].title) .. " need " .. tostring(l.headerIssues[1].need) .. " room "
    .. tostring(l.headerIssues[1].room)) or ""))
  local ranges = {}
  for i, c in ipairs(l.columns) do
    if c.title and c.title ~= "" then
      ranges[#ranges + 1] = { c.headL, c.headR, c.title }
      local tw = #c.title * 6
      T.ok(c.headR - c.headL >= tw - 1e-6, name .. ": " .. c.title .. " drawn whole (no truncation)")
      if c.width then T.ok(c.w >= tw + l.gutter, string.format("%s: %s %d >= label %d + gutter", name, c.title, c.w, tw)) end
    end
    T.ok(c.x >= 0 and c.w > 0, name .. ": column " .. i .. " placed")
    if i > 1 then
      local p = l.columns[i - 1]
      T.near(c.x, p.x + p.w, 1e-6, name .. ": cumulative x at column " .. i)
    end
  end
  for i = 1, #ranges do
    for j = i + 1, #ranges do
      local a, b = ranges[i], ranges[j]
      T.ok(a[2] <= b[1] or b[2] <= a[1], string.format("%s: %s [%d,%d] and %s [%d,%d] overlap", name, a[3], a[1], a[2], b[3], b[1], b[2]))
    end
  end
  T.ok(l.columnsWidth <= l.columnsAvail + 1e-6, name .. ": columns fit the inset")
end

SlashCmdList.BLOODSPORTS("")

T.test("F-1 Finder: cumulative columns that fit the 674 px inset, disjoint headers, one list header drawn", function()
  local p = pane("finder")
  T.ok(p.people and p.refs, "both lists")
  assertHeaders(p.people, "finder people")
  assertHeaders(p.refs, "finder refs")
  local n = col(p.people, "Name")
  T.eq(n.width, nil, "Name is the flex column"); T.ok(n.w >= 100, "Name keeps >= 100 px: " .. n.w)
  T.eq(col(p.people, "Lvl").align, "RIGHT"); T.eq(col(p.people, "W/L").align, "RIGHT")
  T.eq(col(p.people, "Rating").align, "RIGHT"); T.eq(col(p.people, "Seen").align, "RIGHT")
  T.eq(p.people.columns[1].w, 22, "22 px class cell")
  -- the blocker's mechanism: the refs list's header drew on top of the people list's. Only one is ever shown.
  T.eq(p.people:IsShown(), true); T.eq(p.refs:IsShown(), false)
  T.noErrors()
end)

T.test("F-2 / F-9 / F-10 / F-12 Finder: centred empty state, List me | Note | Scan row, native check, footer", function()
  local p = pane("finder")
  T.eq(p.people.emptyText:GetText(), "No duellists listed nearby.")
  T.eq(p.people.emptyHintText:GetText(), "Tick List me to be found, or press Scan to look again.")
  T.eq(p.people.emptyText:IsShown(), true)
  T.eq(select(1, p.people.emptyText:GetPoint(1)), "CENTER", "Duels-style centred empty state")
  -- Scan: primary gold plate, 22 px, right edge flush with the inset (pane) edge
  T.eq(p.scan.tier, "primary"); T.eq(p.scan:GetHeight(), 22)
  local pt, rel, rp, x, y = p.scan:GetPoint(1)
  T.eq(pt, "TOPRIGHT"); T.eq(rel, p); T.eq(rp, "TOPRIGHT"); T.eq(x, 0); T.eq(y, p.layout.row2Y)
  -- Note: from 120 px after the check's left edge to 8 px before Scan, same row
  pt, rel, rp, x, y = p.note:GetPoint(1)
  T.eq(pt, "TOPLEFT"); T.eq(x, 120); T.eq(y, p.layout.row2Y)
  pt, rel, rp, x = p.note:GetPoint(2)
  T.eq(pt, "RIGHT"); T.eq(rel, p.scan); T.eq(rp, "LEFT"); T.eq(x, -8)
  T.eq(p.note:GetHeight(), 22)
  -- List me: native check, measured width, clear of the note box
  T.eq(p.check.native, true); T.eq(p.check:GetWidth(), p.check:MeasuredWidth())
  T.ok(p.check:GetWidth() + 8 <= 120, "List me ends before the note starts")
  -- dropdowns: 150 px, 22 px, with the 18 px native arrow
  T.eq(p.kindDD:GetWidth(), 150); T.eq(p.kindDD:GetHeight(), 22); T.eq(p.kindDD.arrow:GetWidth(), 18)
  T.eq(p.kindDD.arrow:GetTexture(), K.Tex.dropArrow)
  -- footer
  T.eq(p.footer:GetText(), "Listed: no · last scan " .. DASH)
  T.eq(UI.FinderFooter(true, nil), "Listed: yes · last scan " .. DASH)
  T.eq(UI.FinderFooter(false, GetServerTime() - 125), "Listed: no · last scan 2m")
  p.check:Click()   -- list me (the sidebar card + footer follow the live state)
  T.eq(p.footer:GetText(), "Listed: yes · last scan " .. DASH)
  p.scan:Click()
  T.ok(p.footer:GetText():find("Listed: yes · last scan 0s", 1, true), "scan time recorded: " .. p.footer:GetText())
  p.check:Click()
  T.noErrors()
end)

T.test("F-3 / F-5 / F-9 / F-12 Duels: full-label columns, scoped record line, aligned controls, footer", function()
  local p = pane("duels")
  assertHeaders(p.list, "duels")
  T.eq(col(p.list, "Opponent").w, INSET_W - p.list.scrollWidth - 8 - 2 - (70 + 130 + 60 + 60 + 84 + 66), "Opponent flex")
  T.ok(col(p.list, "Opponent").w >= 170, "Opponent ~180 px")
  for _, t in ipairs({ "Result", "Opponent", "Venue", "Time", "HP left", "First blood", "Seal" }) do
    T.ok(col(p.list, t), "full label " .. t)
  end
  T.eq(col(p.list, "Time").align, "RIGHT"); T.eq(col(p.list, "HP left").align, "RIGHT")
  -- controls: both 22 px, same top (bottoms on one line), 12 px apart; Export secondary
  T.eq(p.export:GetHeight(), 22); T.eq(p.filterDD:GetHeight(), 22)
  T.eq(p.export.tier, "secondary"); T.eq(p.export._mkVariant or p.export.variant, "secondary")
  local pt, rel, rp, x, y = p.export:GetPoint(1)
  T.eq(pt, "TOPRIGHT"); T.eq(rel, p.filterDD); T.eq(rp, "TOPLEFT"); T.eq(x, -12); T.eq(y, 0)
  -- empty: record line + footer from the data
  T.eq(p.strip:GetText(), "All venues: 0-0 · " .. DASH .. " · streak 0")
  T.eq(p.footer:GetText(), "0 duels · venue: All")
  -- data: newest last in the store
  local function add(id, result, kind)
    table.insert(ns.char.duels, { id = id, t = GetServerTime(), dur = 30, venue = kind == "club" and "honorroad" or "crossroads",
      venueKind = kind, opp = { name = "Foe" .. id .. "-Normal", class = "ROGUE", level = 12 },
      me = { class = "WARRIOR", level = 12, hpEnd = 40 }, result = result, firstBlood = "me", confirmed = "self" })
  end
  add("a", "loss", "practice"); add("b", "win", "club"); add("c", "win", "practice"); add("d", "void", "club"); add("e", "win", "club")
  ns.UI.Refresh()
  T.eq(p.strip:GetText(), "All venues: 3-1 · 75% · streak 3")
  T.eq(p.footer:GetText(), "5 duels · venue: All")
  T.eq(UI.DuelStrip(ns.char.duels, "club"), "Fight clubs: 2-0 · 100% · streak 2")
  T.eq(UI.DuelStrip(ns.char.duels, "practice"), "Duel practice: 1-1 · 50% · streak 1")
  T.eq(UI.DuelStrip(ns.char.duels, "ring"), "Gambling rings: 0-0 · " .. DASH .. " · streak 0")
  T.eq(UI.DuelsFooter(1, "club"), "1 duel · venue: Fight clubs")
  -- the dropdown's onSelect re-scopes the line
  p.filterDD:OpenMenu()
  for _, r in ipairs(p.filterDD.menuRows) do if r.item and r.item.value == "practice" then r:Click() end end
  T.eq(p.strip:GetText(), "Duel practice: 1-1 · 50% · streak 1")
  T.eq(p.footer:GetText(), "2 duels · venue: Duel practice")
  T.eq(#p.list.data, 2)
  p.filterDD:OpenMenu()
  for _, r in ipairs(p.filterDD.menuRows) do if r.item and r.item.value == "all" then r:Click() end end
  -- no ASCII placeholder hyphen in any row cell
  for _, r in ipairs(p.list.data) do
    for _, k in ipairs({ "dur", "hp", "first", "conf", "venueName" }) do T.ok(r[k] ~= "-", k .. " uses the em dash") end
  end
  T.noErrors()
end)

T.test("F-2 / F-12 Matches: Ring-pattern empty states, both tables collapse to header + 2 rows, footer", function()
  local saved = ns.char.duels
  ns.char.duels = {}
  local p = pane("matchups")
  ns.UI.Refresh()
  for _, l in ipairs({ p.classes, p.venues }) do
    T.eq(l.emptyText:IsShown(), true); T.eq(select(1, l.emptyText:GetPoint(1)), "LEFT")
    T.eq(l.emptyInset, l.columns[1].textL, "empty copy at the first text column")
    T.eq(l:GetHeight(), l:HeightFor(2)); T.eq(l:GetHeight(), 22 + 2 + 44)
    assertHeaders(l, "matches")
  end
  T.eq(p.classes.emptyText:GetText(), "No matchups yet.")
  T.eq(p.classes.emptyHintText:GetText(), "Win or lose a duel and it is tallied here by class.")
  T.eq(p.venues.emptyText:GetText(), "No venues yet.")
  T.eq(p.venues.emptyHintText:GetText(), "Each venue you duel at gets a row.")
  T.eq(p.layout.classRows, 2); T.eq(p.layout.venueRows, 2)
  T.eq(p.layout.venuesHeadY, p.layout.listTop - p.classes:HeightFor(2) - 16, "the venue section follows the collapsed table")
  T.eq(p.footer:GetText(), "0 duels analysed")
  ns.char.duels = saved
  ns.UI.Refresh()
  T.eq(p.layout.classRows, "fill"); T.ok(p.layout.venueRows >= 2)
  T.eq(p.footer:GetText(), "4 duels analysed")
  T.eq(UI.MatchesFooter(1), "1 duel analysed")
  T.noErrors()
end)

T.test("F-2 / F-4 / F-8 / F-12 Clubs: 230 px one-line selector, empty states + collapse, primary Challenge, footer", function()
  local club = ns.Club
  ns.Club = { Champions = function() return {} end, MyStreak = function() return 0 end, CanChallenge = function() return false end,
    Challenge = function() end }
  local p = pane("clubs")
  ns.UI.Refresh()
  T.eq(p.clubDD:GetWidth(), 230); T.eq(p.clubDD:GetHeight(), 22)
  T.eq(p.challenge.tier, "primary"); T.eq(p.challenge:GetHeight(), 22)
  T.eq(select(1, p.challenge:GetPoint(1)), "TOPRIGHT"); T.eq(select(4, p.challenge:GetPoint(1)), 0)
  T.eq(p.champs.emptyText:GetText(), "No champion holds this club.")
  T.eq(p.champs.emptyHintText:GetText(), "Win a challenge to claim the title.")
  T.eq(p.open.emptyText:GetText(), "No open challenges.")
  T.eq(p.open.emptyHintText:GetText(), "Build your streak here to claim the title.", "judge5: no champion to call out")
  T.eq(p.champs:GetHeight(), p.champs:HeightFor(2)); T.eq(p.open:GetHeight(), p.open:HeightFor(2))
  T.eq(p.champs.emptyInset, col(p.champs, "Faction").textL)
  assertHeaders(p.champs, "champions"); assertHeaders(p.open, "challenges")
  -- v16 (judge4): no club name in the footer (it is in the selector and the road line)
  T.eq(p.footer:GetText(), "0 champions · 0 open challenges")
  T.eq(UI.ClubsFooter(1, 2), "1 champion · 2 open challenges")
  ns.Club = club
  T.noErrors()
end)

T.test("F-6 sidebar context cards: one per section, live data, grey empty lines", function()
  local shell = MK.UI._sharedShell
  local tab = shell.tabById.bloodsports
  local saved = ns.char.duels
  ns.char.duels = {}
  local expect = { duels = "LAST RESULTS", matchups = "MATCHUPS", finder = "LISTING", clubs = "YOUR CLUB", ring = "THIS RING" }
  for id, title in pairs(expect) do
    A:Fire("TOGGLE_MAIN", id)
    T.eq(tab.cardTitle, title, id .. " card title")
    T.ok((tab.cardShown or 0) >= 1, id .. " card lines shown")
  end
  local function card(id) A:Fire("TOGGLE_MAIN", id); return tab.cardLines end
  T.eq(card("duels")[1], "None yet.", "v16: the card no longer repeats the pane's \"No duels yet.\"")
  T.eq(card("matchups")[1], "No matchups yet.")
  T.eq(card("finder")[1], "Listed: no"); T.eq(card("finder")[2], "Last scan: 0s ago", "the Scan pressed in the Finder test")
  T.eq(card("ring")[1], "No venue here.")
  -- the empty line is the soft (grey) ink on parchment, not the body ink
  A:Fire("TOGGLE_MAIN", "duels")
  local r1 = tab.cardUI.rows[1]
  T.eq(r1.mkColor, K.ShellCard.parchSoft, "grey empty line")
  T.eq(tab.cardUI.titleColor, K.ShellCard.parchTitle)
  -- with data: last three results, newest first; best / worst matchup
  ns.char.duels = saved
  A:Fire("TOGGLE_MAIN", "matchups"); A:Fire("TOGGLE_MAIN", "duels")
  local lines = tab.cardLines
  T.eq(#lines, 3)
  T.eq(lines[1], "Win vs Foee · " .. MK.Util.Duration(30)); T.eq(lines[2], "Void vs Foed · " .. MK.Util.Duration(30))
  T.ok(card("matchups")[1]:find("^Best: "), "best matchup line")
  -- the card sits under the summary block, inside the sidebar
  T.ok(tab.cardTop > tab.summaryBottom, "card under the summary")
  T.noErrors()
end)

T.test("S6 sidebar win-rate dash: full ink, outlined stroke", function()
  local shell = MK.UI._sharedShell
  local saved = ns.char.duels
  ns.char.duels = {}
  A:Fire("TOGGLE_MAIN", "duels")
  shell:Refresh()
  local tab = shell.tabById.bloodsports
  local r = tab.summaryUI.rows[2]
  T.eq(r.value:GetText(), DASH)
  T.eq(K.ShellDash, DASH, "one dash glyph suite-wide")
  T.eq(r.value.mkOutline, true, "the lone dash is drawn with an outline")
  ns.char.duels = saved
  shell:Refresh()
  T.eq(r.value.mkOutline, false, "a real value drops the outline")
  T.noErrors()
end)

T.done()
