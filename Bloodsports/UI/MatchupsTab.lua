-- Matches tab: results per opponent class and per venue, computed from the local duel history.

local ADDON, ns = ...
local MK = MetaKit
local UI = ns.UI

local function classRows(duels)
  local t, rows = UI.Tally(duels, function(d) return d.opp and d.opp.class end), {}
  for class, s in pairs(t) do
    rows[#rows + 1] = { class = class, name = UI.ClassText(class), n = s.n, w = s.w, l = s.l, pct = UI.Pct(s.w, s.n),
      avg = UI.AvgDur(s), sort = s.n }
  end
  table.sort(rows, function(a, b) if a.sort ~= b.sort then return a.sort > b.sort end return a.name < b.name end)
  return rows
end

local function venueRows(duels)
  local t, rows = UI.Tally(duels, function(d) return d.venue or "" end), {}
  for id, s in pairs(t) do
    rows[#rows + 1] = { venue = UI.Crest(id), name = id == "" and "Elsewhere" or UI.VenueName(id), n = s.n, w = s.w, l = s.l,
      pct = UI.Pct(s.w, s.n), avg = UI.AvgDur(s), sort = s.n }
  end
  table.sort(rows, function(a, b) if a.sort ~= b.sort then return a.sort > b.sort end return a.name < b.name end)
  return rows
end

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

local function build(pane)
  local k = UI.Kit()
  local h1 = k.Label(pane, { text = "By opponent class", font = "body", color = "accent", skin = UI.SKIN })
  h1:SetPoint("TOPLEFT", pane, "TOPLEFT", 8, -2)
  local classes = k.List(pane, { skin = UI.SKIN, rowHeight = 22, columns = cols({ key = "name", title = "Class", width = 180, kind = "text" }) })
  classes:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -24)
  classes:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 170)
  local h2 = k.Label(pane, { text = "By venue", font = "body", color = "accent", skin = UI.SKIN })
  h2:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 8, 148)
  local venues = k.List(pane, { skin = UI.SKIN, rowHeight = 22, columns = cols({ key = "name", title = "Venue", width = 180, kind = "text" }) })
  venues:SetPoint("TOPLEFT", pane, "BOTTOMLEFT", 0, 144)
  venues:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
  pane.classes, pane.venues = classes, venues
  return function()
    local duels = UI.Duels()
    classes:SetData(classRows(duels))
    venues:SetData(venueRows(duels))
  end
end

UI.RegisterTab("matchups", build)
