-- judge4 fix lane, Bloodsports side: the Ring "How the ring works" plate (visible only while both idle lists are empty
-- and no session is live), the Matches season strip, the Clubs road-to-the-title line + progress bar and the footer
-- without the club name, one footer ink on every pane, the Duels card's own empty line, and 26 px native checks.
-- Stub limits: no rendering; widths are the computed anchor maths at an explicit pane width (674 px), colours are the
-- values handed to SetTextColor / SetColorTexture, and the 26 px check size is the size handed to the template (the
-- stub honours every SetSize, so a template that ignores it is not reproducible here).
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
C_AddOns.IsAddOnLoaded = function(n) return n == "Bloodsports" end
local MK, A, UI = MetaKit, ns.A, ns.UI
local DASH = "\226\128\148"

local function sec(shell, id)
  for _, s in ipairs(shell.sections.bloodsports or {}) do if s.id == id then return s end end
end
local function pane(id)
  A:Fire("TOGGLE_MAIN", id)
  return sec(MK.UI._sharedShell, id).frame
end
local function same(a, b, msg) for i = 1, 3 do T.near(a[i], b[i], 1e-6, msg) end end

SlashCmdList.BLOODSPORTS("")

T.test("Ring: How the ring works shows only with both lists empty and no live session", function()
  T.eq(UI.RingView.HowVisible(0, 0, false), true)
  T.eq(UI.RingView.HowVisible(1, 0, false), false, "a referee listed")
  T.eq(UI.RingView.HowVisible(0, 2, false), false, "a ring nearby")
  T.eq(UI.RingView.HowVisible(0, 0, true), false, "a session is live")
  local savedF, savedR = ns.Finder, ns.Ring
  local refs, rings = {}, {}
  ns.Finder = setmetatable({ List = function() return refs end }, { __index = savedF })
  ns.Ring = setmetatable({ Browser = function() return rings end, session = false }, { __index = savedR })
  rawset(ns.Ring, "session", nil)
  pane("ring")
  local box = UI.RingPane
  UI.Refresh()
  T.eq(box.idle:IsShown(), true)
  T.eq(box.how:IsShown(), true, "both empty: the plate shows")
  T.eq(box.howTitle:GetText(), "HOW THE RING WORKS")
  same(box.howTitle.mkColor, { 138 / 255, 106 / 255, 46 / 255 }, "gold-dim header")
  T.eq(#box.howLines, 3)
  T.eq(box.howLines[1]:GetText(), "1. A referee opens a ring at a venue (Ratchet, Everlook, Gadgetzan, Booty Bay).")
  T.eq(box.howLines[2]:GetText(), "2. Accept their party invite to join the ring layer.")
  T.eq(box.howLines[3]:GetText(), "3. Bet on markets, or fight when your bout is called.")
  for _, l in ipairs(box.howLines) do same(l.mkColor, UI.RingView.HOW_INK, "grey-gold line") end
  local pt, rel, rp, x, y = box.how:GetPoint(1)
  T.eq(pt, "TOPLEFT"); T.eq(rel, box.browser); T.eq(rp, "BOTTOMLEFT"); T.eq(y, -16, "a section gap under Rings")
  T.eq(box.idleLayout.howTop, box.idleLayout.ringsTop - box.idleLayout.ringsH - 16)
  -- a referee appears: hidden; gone again: back
  refs[1] = { name = "Ref-Realm", class = "WARRIOR", level = 60, venue = "ratchet", seen = GetTime() }
  UI.Refresh(); T.eq(box.how:IsShown(), false, "a referee listed hides it")
  refs[1] = nil
  rings[1] = { host = "Host-Realm", sid = "s1", venue = "ratchet" }
  UI.Refresh(); T.eq(box.how:IsShown(), false, "a ring nearby hides it")
  rings[1] = nil
  UI.Refresh(); T.eq(box.how:IsShown(), true)
  -- a live session: the idle view and the plate both hide
  rawset(ns.Ring, "session", { status = "open", host = "Host-Realm", markets = {}, members = {} })
  pcall(UI.Refresh)
  T.eq(box.how:IsShown(), false, "live session hides it")
  rawset(ns.Ring, "session", nil)
  ns.Finder, ns.Ring = savedF, savedR
end)

T.test("Matches: season strip under By venue, data-driven", function()
  T.eq(UI.SeasonStrip({}), "Season: 0-0 · best streak 0 · favourite venue " .. DASH)
  local duels = {
    { result = "win", venue = "ratchet" }, { result = "win", venue = "ratchet" }, { result = "loss", venue = "everlook" },
    { result = "win" }, { result = "win" }, { result = "win" }, { result = "void", venue = "everlook" },
    { result = "win", venue = "everlook", confirmed = "disputed" },
  }
  -- 6-1; streak runs: 2, then 3 (the disputed win counts in W-L but not the streak); ratchet 2 games vs everlook 2
  -- (decided only) -> the venue table's tie order (name), real venues only (no "Elsewhere")
  local txt = UI.SeasonStrip(duels)
  T.eq(txt, "Season: 6-1 · best streak 3 · favourite venue " .. UI.VenueName("everlook"))
  local saved = ns.char.duels
  ns.char.duels = {}
  local p = pane("matchups")
  UI.Refresh()
  T.eq(p.season:GetText(), "Season: 0-0 · best streak 0 · favourite venue " .. DASH)
  local pt, rel, rp, x, y = p.season:GetPoint(1)
  T.eq(pt, "TOPLEFT"); T.eq(rel, p.venues); T.eq(rp, "BOTTOMLEFT"); T.eq(x, UI.CONTENT_X); T.eq(y, -6)
  ns.char.duels = { { result = "win", venue = "ratchet" }, { result = "win", venue = "ratchet" }, { result = "loss", venue = "everlook" } }
  UI.Refresh()
  T.eq(p.season:GetText(), "Season: 2-1 · best streak 2 · favourite venue " .. UI.VenueName("ratchet"))
  T.eq(p.layout.stripH, 20)
  ns.char.duels = saved
  UI.Refresh()
end)

T.test("Clubs: footer drops the club name; road to the title text + gold fill = streak / 10 of the content width", function()
  T.eq(UI.ClubsFooter(1, 3), "1 champion · 3 open challenges")
  T.eq(UI.RoadText(3, 10, "Honor Road Fight Club"), "Streak 3 / 10 at Honor Road Fight Club")
  T.eq((UI.RoadFill(3, 10, 648)), 194); T.eq((UI.RoadFill(0, 10, 648)), 0); T.eq((UI.RoadFill(14, 10, 648)), 648, "clamped")
  local club, streak = ns.Club, 0
  ns.Club = { Champions = function() return {} end, MyStreak = function() return streak end,
    CanChallenge = function() return false end, Challenge = function() end }
  local p = pane("clubs")
  p:SetWidth(674)
  UI.Refresh()
  local name = UI.VenueName(p.clubDD:GetValue())
  T.eq(p.footer:GetText(), "0 champions · 0 open challenges")
  T.eq(p.roadText:GetText(), "Streak 0 / 10 at " .. name)
  T.eq(p.road.contentW, 674 - 2 * UI.CONTENT_X); T.eq(p.road.fillW, 0); T.eq(p.roadFill:IsShown(), false, "no sliver at 0")
  T.eq(p.roadTrack:GetHeight(), 6); T.eq(p.roadFill:GetHeight(), 6)
  local pt, rel, rp = p.roadFrame:GetPoint(1)
  T.eq(pt, "TOPLEFT"); T.eq(rel, p.open); T.eq(rp, "BOTTOMLEFT")
  streak = 4
  UI.Refresh()
  T.eq(p.roadText:GetText(), "Streak 4 / 10 at " .. name)
  T.eq(p.road.fillW, math.floor((674 - 2 * UI.CONTENT_X) * 0.4)); T.eq(p.roadFill:GetWidth(), p.road.fillW)
  T.eq(p.roadFill:IsShown(), true)
  same(p.roadFill.mkColor, { 0.97, 0.82, 0.42 }, "gold fill")
  -- the same source the header reads
  T.ok(p.road.text:find("4 / 10"), "road and header share MyStreak")
  ns.Club = club
end)

T.test("Footers share one brighter ink; the Duels card says None yet.; native checks are 30 px", function()
  same(UI.FOOT_INK, { 0.88, 0.80, 0.64 }, "judge5: brighter again")
  for _, id in ipairs({ "duels", "matchups", "finder", "clubs" }) do
    local p = pane(id)
    same(p.footer.mkColor, UI.FOOT_INK, id .. " footer ink")
  end
  pane("ring")
  same(UI.RingPane.idleFoot.mkColor, UI.FOOT_INK, "ring idle footer ink")
  local saved = ns.char.duels
  ns.char.duels = {}
  A:Fire("TOGGLE_MAIN", "duels")
  local tab = MK.UI._sharedShell.tabById.bloodsports
  T.eq(tab.cardLines[1], "None yet.")
  ns.char.duels = { { result = "win", opp = { name = "Foe-Realm" }, dur = 30 } }
  A:Fire("TOGGLE_MAIN", "matchups"); A:Fire("TOGGLE_MAIN", "duels")
  T.eq(tab.cardLines[1], "Win vs Foe · " .. MK.Util.Duration(30), "real results unchanged")
  ns.char.duels = saved
  local f = pane("finder")
  T.eq(f.check.boxSize, 30); T.eq(f.check.boxHolder:GetWidth(), 30)
  T.noErrors()
end)

T.done()
