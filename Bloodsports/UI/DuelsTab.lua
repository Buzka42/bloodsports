-- Duels tab: a filter-scoped record line, Export + the venue filter, the duel history list and a footer status line.
-- v15 (JUDGE3 D1-D3 / F-3 / F-5 / F-9 / F-12): the record line is scoped to the venue filter (it changes with the
-- dropdown, so it no longer repeats the sidebar's lifetime stats); full-label columns that fit the 674 px inset with
-- 16 px gutters; Export (secondary) and the filter both 22 px tall, tops and bottoms on one line, 12 px apart; one
-- placeholder dash (UI.DASH); "N duels · venue: X" footer at the pane bottom.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI

local FILTERS = {
  { value = "all", text = "All venues" }, { value = "practice", text = "Duel practice" },
  { value = "club", text = "Fight clubs" }, { value = "ring", text = "Gambling rings" }, { value = "koth", text = "Arena" },
}
local FILTER_TEXT = {}
for _, f in ipairs(FILTERS) do FILTER_TEXT[f.value] = f.text end
local RESULT = { win = UI.Tint("good", "WIN"), loss = UI.Tint("bad", "LOSS"), void = UI.Tint("muted", "VOID") }
local CONF = { both = UI.Tint("good", "Both"), referee = UI.Tint("accent", "Referee"), self = "Self", disputed = UI.Tint("bad", "Disputed") }
local FIRST = { me = "Me", opp = "Foe" }

local function toRow(d)
  local opp = d.opp or {}
  local name = (opp.name and UI.Short(opp.name) or "Unknown") .. (opp.level and (" (" .. opp.level .. ")") or "")
  return {
    result = RESULT[d.result] or RESULT.void, class = opp.class,
    opp = opp.class and UI.ClassText(opp.class, name) or name,   -- the class reads as the name's colour
    venueName = d.venue and UI.VenueName(d.venue) or UI.DASH,
    dur = type(d.dur) == "number" and MK.Util.Duration(d.dur) or UI.DASH,
    hp = d.me and type(d.me.hpEnd) == "number" and (math.floor(d.me.hpEnd) .. "%") or UI.DASH,
    first = FIRST[d.firstBlood] or UI.DASH, conf = CONF[d.confirmed] or UI.DASH, raw = d,
  }
end

-- Columns (v15 F-3): Opponent is the flex column (180 px at the 674 px inset); every fixed column holds its full
-- header label inside its text box (width - 16 px gutter) at the stub's 6 px/char measure.
UI.DuelColumns = {
  { key = "result", title = "Result", width = 70, kind = "text" },
  { key = "opp", title = "Opponent", kind = "text" },
  { key = "venueName", title = "Venue", width = 130, kind = "text" },
  { key = "dur", title = "Time", width = 60, kind = "text", align = "RIGHT" },
  { key = "hp", title = "HP left", width = 60, kind = "text", align = "RIGHT" },
  { key = "first", title = "First blood", width = 84, kind = "text" },
  { key = "conf", title = "Seal", width = 66, kind = "text" },
}

local function matches(d, filter) return filter == "all" or d.venueKind == filter end

-- v15 (D2 / F-5): the record line for the filter in view, from the duel history (newest last in the store):
-- "<filter>: W-L · win% · streak N" (win% is UI.DASH with no decided duel; the streak counts the newest consecutive
-- wins inside the filter, voids skipped).
function UI.DuelStrip(duels, filter)
  filter = filter or "all"
  local w, l, streak, open = 0, 0, 0, true
  for i = #(duels or {}), 1, -1 do
    local d = duels[i]
    if matches(d, filter) then
      if d.result == "win" then
        w = w + 1
        if open then streak = streak + 1 end
      elseif d.result == "loss" then
        l = l + 1
        open = false
      end
    end
  end
  return string.format("%s: %d-%d · %s · streak %d", FILTER_TEXT[filter] or FILTER_TEXT.all, w, l, UI.Pct(w, w + l), streak)
end

-- v15 (S5): "0 duels · venue: All" / "3 duels · venue: Fight clubs"
function UI.DuelsFooter(n, filter)
  local v = (filter == nil or filter == "all") and "All" or (FILTER_TEXT[filter] or tostring(filter))
  return UI.Plural(n, "duel") .. " · venue: " .. v
end

local ROW_H, CTRL_H, CTRL_GAP, FILTER_W, EXPORT_W = 22, 22, 12, 130, 80

local function build(pane)
  local k = UI.Kit()
  local filter = "all"
  local dd = k.Dropdown(pane, { width = FILTER_W, height = CTRL_H, skin = UI.SKIN, items = FILTERS,
    onSelect = function(v) filter = UI.Val(v) or "all"; UI.Refresh() end })
  dd:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, 0)   -- right edge matches the list below
  if dd.SetValue then dd:SetValue("all") end
  local export = k.Button(pane, { text = "Export", width = EXPORT_W, height = CTRL_H, variant = "secondary", skin = UI.SKIN,
    tooltip = "Copy your duels as a string for the website.", onClick = function() A:Fire("SHOW_EXPORT") end })
  export:SetPoint("TOPRIGHT", dd, "TOPLEFT", -CTRL_GAP, 0)   -- same top + same height: bottoms on one line
  local strip = k.Label(pane, { text = "", font = "body", color = "text", skin = UI.SKIN })
  if strip.SetWordWrap then strip:SetWordWrap(false) end
  strip:SetPoint("LEFT", pane, "TOPLEFT", UI.CONTENT_X, -CTRL_H / 2)
  strip:SetPoint("RIGHT", export, "LEFT", -CTRL_GAP, 0)
  local list = k.List(pane, { skin = UI.SKIN, rowHeight = ROW_H, chrome = "inset", gutter = UI.LIST_GUTTER,
    headerHeight = 22, columns = UI.DuelColumns,
    empty = "No duels yet. Challenge someone at the Crossroads or Honor Road.", emptyHint = "Finished duels appear here." })
  list:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -(CTRL_H + 8))
  list:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, UI.FOOT_H)
  local foot = UI.PaneFooter(pane)
  pane.list, pane.strip, pane.export, pane.filterDD = list, strip, export, dd
  pane.layout = { ctrlH = CTRL_H, gap = CTRL_GAP, listTop = -(CTRL_H + 8), footH = UI.FOOT_H }

  return function()
    local duels, rows = UI.Duels(), {}
    for i = #duels, 1, -1 do
      if matches(duels[i], filter) then rows[#rows + 1] = toRow(duels[i]) end
    end
    strip:SetText(UI.DuelStrip(duels, filter))
    foot:SetText(UI.DuelsFooter(#rows, filter))
    list:SetData(rows)
  end
end

UI.RegisterTab("duels", build)
