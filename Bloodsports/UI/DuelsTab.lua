-- Duels tab: stats strip (record, win rate, streaks) and the duel history list, filterable by venue kind.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI

local FILTERS = {
  { value = "all", text = "All venues" }, { value = "practice", text = "Duel practice" },
  { value = "club", text = "Fight clubs" }, { value = "ring", text = "Gambling rings" }, { value = "koth", text = "Arena" },
}
local RESULT = { win = UI.Tint("good", "WIN"), loss = UI.Tint("bad", "LOSS"), void = UI.Tint("muted", "VOID") }
local CONF = { both = UI.Tint("good", "Both"), referee = UI.Tint("accent", "Referee"), self = "Self", disputed = UI.Tint("bad", "Disputed") }
local FIRST = { me = "Me", opp = "Foe" }

local function toRow(d)
  local opp = d.opp or {}
  return {
    result = RESULT[d.result] or RESULT.void, class = opp.class,
    opp = (opp.name and UI.Short(opp.name) or "Unknown") .. (opp.level and (" (" .. opp.level .. ")") or ""),
    venue = UI.Crest(d.venue), venueName = UI.VenueName(d.venue),
    dur = type(d.dur) == "number" and MK.Util.Duration(d.dur) or "-",
    hp = d.me and type(d.me.hpEnd) == "number" and (math.floor(d.me.hpEnd) .. "%") or "-",
    first = FIRST[d.firstBlood] or "-", conf = CONF[d.confirmed] or "-", raw = d,
  }
end

local STRIP_H, SLOT_W = 24, 120
local STATS = { "Record", "Win rate", "Streak", "Best" }

local function build(pane)
  local k = UI.Kit()
  local filter = "all"
  -- Stats strip: label (10, muted) then value (12, text) per slot, spaced evenly from the left gutter.
  local values = {}
  for i, name in ipairs(STATS) do
    local x = 8 + (i - 1) * SLOT_W
    local lab = k.Label(pane, { text = name, font = "small", color = "muted", skin = UI.SKIN })
    lab:SetPoint("LEFT", pane, "TOPLEFT", x, -STRIP_H / 2)
    local val = k.Label(pane, { text = "", font = "body", color = "text", skin = UI.SKIN })
    val:SetPoint("LEFT", lab, "RIGHT", 6, 0)
    values[i] = val
  end
  local dd = k.Dropdown(pane, { width = 130, skin = UI.SKIN, items = FILTERS, onSelect = function(v) filter = UI.Val(v) or "all"; UI.Refresh() end })
  dd:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, 0)   -- right edge matches the list below
  if dd.SetValue then dd:SetValue("all") end
  local list = k.List(pane, { skin = UI.SKIN, rowHeight = 22, columns = {
    { key = "result", title = "Result", width = 56, kind = "text" },
    { key = "class", title = "", width = 28, kind = "class" },
    { key = "opp", title = "Opponent", width = 150, kind = "text" },
    { key = "venue", title = "Venue", width = 44, kind = "icon" },
    { key = "dur", title = "Time", width = 56, kind = "text" },
    { key = "hp", title = "HP left", width = 56, kind = "text" },
    { key = "first", title = "1st blood", width = 62, kind = "text" },
    { key = "conf", title = "Seal", width = 70, kind = "text" },
  } })
  list:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -(STRIP_H + 4))
  list:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
  if list.SetEmptyText then
    list:SetEmptyText("No duels yet. Challenge someone at the Crossroads or Honor Road.", "Finished duels appear here.")
  end
  pane.list, pane.values = list, values

  return function()
    local duels, rows, w, l = UI.Duels(), {}, 0, 0
    for i = #duels, 1, -1 do
      local d = duels[i]
      if filter == "all" or d.venueKind == filter then
        rows[#rows + 1] = toRow(d)
        if d.result == "win" then w = w + 1 elseif d.result == "loss" then l = l + 1 end
      end
    end
    local st = ns.char and ns.char.streak or {}
    values[1]:SetText(w .. "-" .. l)
    values[2]:SetText(UI.Pct(w, w + l))
    values[3]:SetText(tostring(st.cur or 0))
    values[4]:SetText(tostring(st.best or 0))
    list:SetData(rows)
  end
end

UI.RegisterTab("duels", build)
