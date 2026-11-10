-- judge5 fix lane, Bloodsports side: the brighter footer ink + 11 pt footer font, the 30 px native checks and the Clubs
-- Open challenges empty hint that follows the champions roster.
-- Stub limits: no rendering. The stub's font objects report 12 pt, so the 10 -> 11 pt raise is proven on a recording
-- label whose GetFont reports the client's GameFontNormalSmall (10 pt); colours are the values handed to SetTextColor.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
C_AddOns.IsAddOnLoaded = function(n) return n == "Bloodsports" end
local MK, A, UI = MetaKit, ns.A, ns.UI

local function sec(shell, id)
  for _, s in ipairs(shell.sections.bloodsports or {}) do if s.id == id then return s end end
end
local function pane(id)
  A:Fire("TOGGLE_MAIN", id)
  return sec(MK.UI._sharedShell, id).frame
end
local function same(a, b, msg) for i = 1, 3 do T.near(a[i], b[i], 1e-6, msg) end end

local function recLabel(size)
  local l = { set = nil }
  function l:SetTextColor(r, g, b, a) self.color = { r, g, b, a } end
  function l:GetFont() return "Fonts\\FRIZQT__.TTF", size, "OUTLINE" end
  function l:SetFont(path, sz, flags) self.set = { path, sz, flags } end
  return l
end

T.test("footer ink (0.88, 0.80, 0.64) on every pane; a 10 pt footer font is raised to 11, larger fonts untouched", function()
  same(UI.FOOT_INK, { 0.88, 0.80, 0.64 }); T.eq(UI.FOOT_SIZE, 11)
  for _, id in ipairs({ "duels", "matchups", "finder", "clubs" }) do same(pane(id).footer.mkColor, UI.FOOT_INK, id) end
  pane("ring")
  same(UI.RingPane.idleFoot.mkColor, UI.FOOT_INK, "ring idle footer")
  local small = UI.ApplyFootInk(recLabel(10))
  same(small.color, UI.FOOT_INK)
  T.eq(small.set[1], "Fonts\\FRIZQT__.TTF"); T.eq(small.set[2], 11); T.eq(small.set[3], "OUTLINE", "face + flags kept")
  T.eq(small.mkFootSize, 11)
  local big = UI.ApplyFootInk(recLabel(12))
  T.eq(big.set, nil, "12 pt is left alone"); T.eq(big.mkFootSize, nil)
  -- a label without font accessors still takes the ink
  local bare = { SetTextColor = function(self, r) self.r = r end }
  UI.ApplyFootInk(bare); T.near(bare.r, 0.88, 1e-6)
  T.noErrors()
end)

T.test("native List me check is 30 px", function()
  local f = pane("finder")
  T.eq(f.check.boxSize, 30); T.eq(f.check.boxHolder:GetWidth(), 30); T.eq(f.check.boxHolder:GetHeight(), 30)
  T.noErrors()
end)

T.test("Clubs: Open challenges empty hint follows the champions roster", function()
  T.eq(UI.ClubsOpenHint(0), "Build your streak here to claim the title.")
  T.eq(UI.ClubsOpenHint(nil), "Build your streak here to claim the title.")
  T.eq(UI.ClubsOpenHint(2), "Press Challenge to call out the champion.")
  local club, champs = ns.Club, {}
  ns.Club = { Champions = function() return champs end, MyStreak = function() return 0 end,
    CanChallenge = function() return false end, Challenge = function() end }
  local p = pane("clubs")
  UI.Refresh()
  T.eq(p.open.emptyText:GetText(), "No open challenges.")
  T.eq(p.open.emptyHintText:GetText(), "Build your streak here to claim the title.", "no champion: nobody to call out")
  champs = { Horde = { WARRIOR = { name = "Grak-Realm", streak = 12, since = 1700000000 } } }
  UI.Refresh()
  T.eq(p.open.emptyText:GetText(), "No open challenges.")
  T.eq(p.open.emptyHintText:GetText(), "Press Challenge to call out the champion.", "a champion holds the club")
  champs = {}
  UI.Refresh()
  T.eq(p.open.emptyHintText:GetText(), "Build your streak here to claim the title.", "and back when the title falls")
  ns.Club = club
  T.noErrors()
end)

T.done()
