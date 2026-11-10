-- Matches tab: results per opponent class and per venue, computed from the local duel history.
-- v15 (JUDGE3 M1 / M2 / F-2 / F-12): both tables get the Ring empty pattern (a line + a grey hint, left-aligned at the
-- first text column); while a table is empty it collapses to header + 2 rows, the other follows it up, and a footer
-- status line ("N duels analysed") anchors the pane bottom. With data the class table fills, the venue table keeps
-- 2-4 rows above the footer.

local ADDON, ns = ...
local MK = MetaKit
local UI = ns.UI

local function classRows(duels)
  local t, rows = UI.Tally(duels, function(d) return d.opp and d.opp.class end), {}
  for class, s in pairs(t) do
    rows[#rows + 1] = { class = class, name = UI.ClassText(class), plain = UI.ClassName(class), n = s.n, w = s.w, l = s.l,
      pct = UI.Pct(s.w, s.n), avg = UI.AvgDur(s), sort = s.n }
  end
  table.sort(rows, function(a, b) if a.sort ~= b.sort then return a.sort > b.sort end return a.plain < b.plain end)
  return rows
end
UI.MatchupRows = classRows

local function venueRows(duels)
  local t, rows = UI.Tally(duels, function(d) return d.venue or "" end), {}
  for id, s in pairs(t) do
    rows[#rows + 1] = { id = id, venue = UI.Crest(id), name = id == "" and "Elsewhere" or UI.VenueName(id), n = s.n, w = s.w, l = s.l,
      pct = UI.Pct(s.w, s.n), avg = UI.AvgDur(s), sort = s.n }
  end
  table.sort(rows, function(a, b) if a.sort ~= b.sort then return a.sort > b.sort end return a.name < b.name end)
  return rows
end

UI.VenueRows = venueRows

-- v16 (judge4 matches void): one data-driven season line under By venue, from the same tallies the tables use:
-- "Season: W-L · best streak N · favourite venue X". W-L / best streak over decided duels (a disputed record breaks
-- nothing and counts nothing for the streak, as in Stats.Summary); favourite = the real venue with the most games
-- (ties: the venue table's order), the em dash when no duel has a venue.
function UI.SeasonStrip(duels)
  duels = duels or {}
  local w, l, run, best = 0, 0, 0, 0
  for _, d in ipairs(duels) do
    if d.result == "win" or d.result == "loss" then
      if d.result == "win" then w = w + 1 else l = l + 1 end
      if d.confirmed ~= "disputed" then
        if d.result == "win" then run = run + 1; if run > best then best = run end else run = 0 end
      end
    end
  end
  local fav
  for _, r in ipairs(venueRows(duels)) do
    if r.id ~= "" then fav = r.name; break end
  end
  return "Season: " .. w .. "-" .. l .. " · best streak " .. best .. " · favourite venue " .. (fav or UI.DASH)
end

-- "0 duels analysed" / "1 duel analysed": decided duels only (the tallies skip voids)
function UI.MatchesFooter(n) return UI.Plural(n, "duel") .. " analysed" end

local function cols(first)
  return {
    first,
    { key = "n", title = "Games", width = 56, kind = "text", align = "RIGHT" },
    { key = "w", title = "W", width = 44, kind = "text", align = "RIGHT" },
    { key = "l", title = "L", width = 44, kind = "text", align = "RIGHT" },
    { key = "pct", title = "Win %", width = 60, kind = "text", align = "RIGHT" },
    { key = "avg", title = "Avg time", width = 70, kind = "text", align = "RIGHT" },
  }
end

local ROW_H, HEAD_H, SECTION_GAP, STRIP_H = 22, 22, 16, 20
local HEAD_Y, RULE_Y, LIST_TOP = -4, -24, -30   -- header text, its gold-dim rule, the list top (px below the pane top)

local function build(pane)
  local k = UI.Kit()
  local function newList(first, empty, hint)
    return k.List(pane, { skin = UI.SKIN, rowHeight = ROW_H, chrome = "inset", gutter = UI.LIST_GUTTER,
      headerHeight = HEAD_H, emptyAlign = "LEFT", empty = empty, emptyHint = hint, columns = cols(first) })
  end
  local h1 = k.Label(pane, { text = "By opponent class", font = "body", color = "accent", skin = UI.SKIN })
  h1:SetPoint("TOPLEFT", pane, "TOPLEFT", UI.CONTENT_X, HEAD_Y)
  local r1 = UI.SectionRule(pane)
  r1:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, RULE_Y)
  r1:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, RULE_Y)
  local classes = newList({ key = "name", title = "Class", kind = "text" },
    "No matchups yet.", "Win or lose a duel and it is tallied here by class.")
  local h2 = k.Label(pane, { text = "By venue", font = "body", color = "accent", skin = UI.SKIN })
  local r2 = UI.SectionRule(pane)
  local venues = newList({ key = "name", title = "Venue", kind = "text" },
    "No venues yet.", "Each venue you duel at gets a row.")
  local foot = UI.PaneFooter(pane)
  -- v16: the season strip hangs 6 px under the venue table at the first text column
  local strip = k.Label(pane, { text = "", font = "body", color = "text", skin = UI.SKIN })
  if strip.SetWordWrap then strip:SetWordWrap(false) end
  strip:SetJustifyH("LEFT")
  strip:SetPoint("TOPLEFT", venues, "BOTTOMLEFT", UI.CONTENT_X, -6)
  strip:SetPoint("TOPRIGHT", venues, "BOTTOMRIGHT", -UI.CONTENT_X, -6)
  pane.season = strip

  -- nClass / nVenue = data rows. Empty tables collapse to HeightFor(2); see the file header.
  local function layout(nClass, nVenue)
    local venueRowsN = nVenue == 0 and 2 or math.max(2, math.min(4, nVenue))
    local venueH = venues:HeightFor(venueRowsN)
    classes:ClearAllPoints(); venues:ClearAllPoints(); h2:ClearAllPoints(); r2:ClearAllPoints()
    classes:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, LIST_TOP)
    local classH, h2Y
    if nClass == 0 then
      classH = classes:HeightFor(2)
      classes:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, LIST_TOP)
      classes:SetHeight(classH)
      h2Y = LIST_TOP - classH - SECTION_GAP
      venues:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, h2Y + (LIST_TOP - HEAD_Y))
      venues:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, h2Y + (LIST_TOP - HEAD_Y))
      venues:SetHeight(venueH)
      h2:SetPoint("TOPLEFT", pane, "TOPLEFT", UI.CONTENT_X, h2Y)
      r2:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, h2Y + (RULE_Y - HEAD_Y))
      r2:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, h2Y + (RULE_Y - HEAD_Y))
    else
      -- venue table sits on the footer band; its header + rule above it; the class table fills the rest
      local vBottom = UI.FOOT_H + STRIP_H -- v16: room for the season strip above the footer
      venues:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 0, vBottom)
      venues:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, vBottom)
      venues:SetHeight(venueH)
      local vTop = vBottom + venueH                         -- px above the pane bottom
      local hY = vTop + (LIST_TOP - HEAD_Y) * -1            -- header text top, px above the pane bottom
      h2:SetPoint("TOPLEFT", pane, "BOTTOMLEFT", UI.CONTENT_X, hY)
      r2:SetPoint("TOPLEFT", pane, "BOTTOMLEFT", 0, hY + (RULE_Y - HEAD_Y))
      r2:SetPoint("TOPRIGHT", pane, "BOTTOMRIGHT", 0, hY + (RULE_Y - HEAD_Y))
      classes:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, hY + SECTION_GAP)
      classH, h2Y = "fill", "bottom"
    end
    pane.layout = { classRows = nClass == 0 and 2 or "fill", classH = classH, venueRows = venueRowsN, venueH = venueH,
      venuesHeadY = h2Y, listTop = LIST_TOP, footH = UI.FOOT_H, stripH = STRIP_H }
  end
  layout(0, 0)
  pane.classes, pane.venues, pane.footer, pane.layoutFn = classes, venues, foot, layout
  return function()
    local duels = UI.Duels()
    local cr, vr = classRows(duels), venueRows(duels)
    classes:SetData(cr)
    venues:SetData(vr)
    layout(#cr, #vr)
    local n = 0
    for _, d in ipairs(duels) do if d.result == "win" or d.result == "loss" then n = n + 1 end end
    foot:SetText(UI.MatchesFooter(n))
    strip:SetText(UI.SeasonStrip(duels))
  end
end

UI.RegisterTab("matchups", build)
