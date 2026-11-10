-- Finder tab: find duel partners, fight-club rivals and ring referees; whisper / invite / ask-invite buttons.
-- v15 (JUDGE3 F1-F4): cumulative full-label columns, a centred empty state, List me / Note / Scan on one row, the
-- native check, and a "Listed: yes|no · last scan T" footer.
-- Also owns the FINDER_INVITED and FINDER_REQUEST popups. Invite buttons call ns.Finder.Invite from OnClick only.
-- CONTRACT NOTE: ns.Finder.Invite(name, context) gets context = { kind, venue, note }.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI
local M = A:NewModule("UIFinder")

local KINDS = {
  { value = "duel", text = "Duel practice", venueKind = "practice" },
  { value = "club", text = "Fight club", venueKind = "club" },
  { value = "ring", text = "Gambling ring", venueKind = "ring" },
  { value = "ref", text = "Referees", venueKind = "ring" },
}
local KIND_TEXT = { duel = "a practice duel", club = "a fight club bout", ring = "a gambling ring", ref = "refereeing a ring" }

local st = { kind = "duel", venue = {}, note = "", queried = 0, listed = false, scanAt = nil }

local function finderOk()
  if ns.Finder then return true end
  A:Print("Finder unavailable.")
  return false
end

local function ctx(row) return { kind = row.kind, venue = row.venue, note = st.note } end

-- v15 (JUDGE3 F1 / F-1): separate W/L (my record against them) and Rating (referees) columns; placeholders use UI.DASH
local function toRow(e)
  local isRef = e.kind == "ref"
  local w, l = UI.RecordVs(e.name)
  return {
    full = e.name, name = UI.Short(e.name), class = e.class, level = e.level or "?", kind = e.kind, venue = e.venue,
    venueName = e.venue and UI.VenueName(e.venue) or UI.DASH,
    wl = (w + l > 0) and (w .. "-" .. l) or UI.DASH,
    rating = (isRef and type(e.rating) == "number") and string.format("%.1f", e.rating)
      or ((e.streak and e.streak > 0) and ("W" .. e.streak) or UI.DASH),
    seen = UI.Ago(e.seen), note = e.note,
  }
end

local function fetch()
  if not (ns.Finder and ns.Finder.List) then return nil end
  local venue = st.venue[st.kind]
  if venue == "" then venue = nil end
  local rows = {}
  local function add(kind, v)
    local list = UI.Try(ns.Finder.List, kind, v)
    for _, e in ipairs(list or {}) do rows[#rows + 1] = toRow(e) end
  end
  if st.kind == "ring" then add("ref", nil) end   -- referees first: only they can invite
  add(st.kind, venue)
  return rows
end

-- v15 (F-1): the data columns both Finder lists share, cumulative left to right, Name the flex column. At the 674 px
-- inset (650 px of columns after the rail, PAD and edges) with the people list's three buttons (196 px), Name gets
-- 110 px; every fixed header fits its text box (width - 16 px gutter) at the stub's 6 px/char measure.
UI.FinderDataColumns = {
  { key = "class", title = "", width = 22, kind = "class" },
  { key = "name", title = "Name", kind = "text" },
  { key = "level", title = "Lvl", width = 40, kind = "text", align = "RIGHT" },
  { key = "venueName", title = "Venue", width = 110, kind = "text" },
  { key = "wl", title = "W/L", width = 56, kind = "text", align = "RIGHT" },
  { key = "rating", title = "Rating", width = 60, kind = "text", align = "RIGHT" },
  { key = "seen", title = "Seen", width = 56, kind = "text", align = "RIGHT" },
}
UI.FinderButtonW = { Whisper = 64, Invite = 56, ["Ask invite"] = 76 }

-- v15 (S5 / F-12): "Listed: yes · last scan 2m" / "Listed: no · last scan —"
function UI.FinderFooter(listed, scanAt)
  return "Listed: " .. (listed and "yes" or "no") .. " · last scan " .. (scanAt and UI.Ago(scanAt) or UI.DASH)
end

-- The listing state the Finder footer and the sidebar LISTING card read: listed (own Finder listing, or referee
-- availability while the Referees kind is in view) and the server time of the last Scan (nil before any).
function UI.FinderState()
  local listed
  if st.kind == "ref" then
    listed = A.db and A.db.config and A.db.config.referee and A.db.config.referee.available and true or false
  elseif ns.Finder and ns.Finder.IsLooking then
    listed = UI.Try(ns.Finder.IsLooking) and true or false
  else
    listed = st.listed and true or false
  end
  return { listed = listed, scanAt = st.scanAt, kind = st.kind }
end

local CTRL_H, KIND_W, VENUE_W, ROW_GAP, SCAN_W = 22, 150, 150, 8, 70

local function build(pane)
  local k = UI.Kit()
  local db = UI.Db()
  db.finder = db.finder or {}
  st.note = db.finder.note or ""
  -- row 1: the two filters, 150 px each, 12 px apart
  local kindDD = k.Dropdown(pane, { width = KIND_W, height = CTRL_H, items = KINDS,
    onSelect = function(v) st.kind = UI.Val(v) or "duel"; UI.Refresh() end })
  kindDD:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
  if kindDD.SetValue then kindDD:SetValue("duel") end

  local venueDD = {}
  for _, kd in ipairs(KINDS) do
    if not venueDD[kd.venueKind] then
      local items = { { value = "", text = "Anywhere" } }
      for _, v in ipairs(UI.Venues(kd.venueKind)) do items[#items + 1] = { value = v.id, text = v.name } end
      local dd = k.Dropdown(pane, { width = VENUE_W, height = CTRL_H, items = items, onSelect = function(v)
        for _, x in ipairs(KINDS) do if x.venueKind == kd.venueKind then st.venue[x.value] = UI.Val(v) or "" end end
        UI.Refresh()
      end })
      dd:SetPoint("LEFT", kindDD, "RIGHT", 12, 0)
      if dd.SetValue then dd:SetValue("") end
      dd:SetShown(kd.venueKind == "practice")
      venueDD[kd.venueKind] = dd
    end
  end

  -- row 2: List me (native check) | Note (120 px after the check's left edge, to 8 px before Scan) | Scan, flush right
  local ROW2_Y = -(CTRL_H + ROW_GAP)
  local note
  local check = k.Checkbox(pane, { label = "List me", checked = false, native = true, size = 30, onChange = function(on)
    st.listed = on and true or false
    if st.kind == "ref" then
      A.db.config.referee.available = st.listed
      A:Fire("REFEREE_AVAILABILITY", st.listed)
    elseif finderOk() then
      if st.listed then UI.Try(ns.Finder.SetLooking, st.kind, st.venue[st.kind] or "", st.note)
      else UI.Try(ns.Finder.StopLooking) end
    end
    UI.Refresh()
  end })
  if check.MeasuredWidth then check:SetWidth(check:MeasuredWidth()) end
  check:SetPoint("LEFT", pane, "TOPLEFT", 0, ROW2_Y - CTRL_H / 2)
  local scan = k.Button(pane, { text = "Scan", width = SCAN_W, height = CTRL_H, variant = "primary",
    tooltip = "Ask nearby Bloodsports users to announce themselves",
    onClick = function()
      if GetTime() - st.queried < 10 then return end
      st.queried = GetTime()
      st.scanAt = MK.Util.ServerTime()
      if ns.finder and ns.finder.Query then
        local v = st.venue[st.kind]
        UI.Try(ns.finder.Query, ns.finder, st.kind, v ~= "" and v or nil)
      end
      UI.Refresh()
    end })
  scan:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, ROW2_Y)   -- flush with the inset's right edge
  note = k.EditBox(pane, { height = CTRL_H, maxLetters = 60, placeholder = "Note (optional)", onChange = function(t)
    if type(t) ~= "string" then t = note and note:GetText() or "" end
    st.note = t
    db.finder.note = t
  end })
  note:SetPoint("TOPLEFT", pane, "TOPLEFT", 120, ROW2_Y)
  note:SetPoint("RIGHT", scan, "LEFT", -8, 0)
  if note.SetText and st.note ~= "" then note:SetText(st.note) end

  local function btn(key, text, fn)
    return { key = key, title = "", width = UI.FinderButtonW[text] or 64, kind = "button", buttonText = text, onClick = fn }
  end
  local function whisper(row) UI.Whisper(row.full) end
  local function invite(row)
    if finderOk() then UI.Try(ns.Finder.Invite, row.full, ctx(row)) end
  end
  local function ask(row)
    if row.kind ~= "ref" and row.kind ~= "club" and row.kind ~= "duel" then return end
    if finderOk() then UI.Try(ns.Finder.RequestInvite, row.full, row.kind, row.venue) end
  end
  local function cols(buttons)
    local c = {}
    for _, x in ipairs(UI.FinderDataColumns) do c[#c + 1] = x end
    for _, x in ipairs(buttons) do c[#c + 1] = x end
    return c
  end
  local LIST_TOP = ROW2_Y - CTRL_H - ROW_GAP
  local EMPTY, HINT = "No duellists listed nearby.", "Tick List me to be found, or press Scan to look again."
  local function newList(buttons)
    local l = k.List(pane, { skin = UI.SKIN, rowHeight = 22, chrome = "inset", gutter = UI.LIST_GUTTER, headerHeight = 22,
      columns = cols(buttons), empty = EMPTY, emptyHint = HINT })
    l:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, LIST_TOP)
    l:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, UI.FOOT_H)
    return l
  end
  local people = newList({ btn("w", "Whisper", whisper), btn("i", "Invite", invite), btn("a", "Ask invite", ask) })
  local refs = newList({ btn("w", "Whisper", whisper), btn("a", "Ask invite", ask) })
  -- F-1: only one list's header may ever draw; the refs list stays hidden until a referee kind is picked (the two
  -- headers drawn on top of each other read as overlapping, truncated labels)
  refs:Hide()
  local foot = UI.PaneFooter(pane)
  pane.people, pane.refs, pane.check, pane.note, pane.scan, pane.footer = people, refs, check, note, scan, foot
  pane.kindDD, pane.venueDD = kindDD, venueDD
  pane.layout = { ctrlH = CTRL_H, row2Y = ROW2_Y, noteLeft = 120, listTop = LIST_TOP, footH = UI.FOOT_H }

  return function()
    local isRef = st.kind == "ref" or st.kind == "ring"
    people:SetShown(not isRef)
    refs:SetShown(isRef)
    local vk
    for _, kd in ipairs(KINDS) do if kd.value == st.kind then vk = kd.venueKind end end
    for key, dd in pairs(venueDD) do dd:SetShown(key == vk) end
    local state = UI.FinderState()
    check:SetChecked(state.listed)
    local rows = fetch()
    local target = isRef and refs or people
    if not rows then
      target:SetEmptyText("Finder unavailable.", "")
      people:SetData({}); refs:SetData({})
    else
      if target.SetEmptyText and target.emptyText and target.emptyText:GetText() ~= EMPTY then target:SetEmptyText(EMPTY, HINT) end
      target:SetData(rows)
    end
    foot:SetText(UI.FinderFooter(state.listed, state.scanAt))
  end
end

UI.RegisterTab("finder", build)

function M:OnLogin()
  A:Listen("FINDER_INVITED", function(sender, kind, venue, note)
    local where = (venue and venue ~= "") and (" at " .. UI.VenueName(venue)) or ""
    local text = UI.Short(sender) .. " invites you to " .. (KIND_TEXT[kind] or "play") .. where .. "."
    if note and note ~= "" then text = text .. "\n\"" .. note .. "\"" end
    UI.Popup({ title = "Layer invite", text = text .. "\nAccept the party invite to join their layer.",
      accept = "Got it", cancel = "Whisper", onCancel = function() UI.Whisper(sender) end })
  end)
  A:Listen("FINDER_REQUEST", function(sender, kind, venue, note)
    local where = (venue and venue ~= "") and (" at " .. UI.VenueName(venue)) or ""
    local text = UI.Short(sender) .. " asks to join your layer for " .. (KIND_TEXT[kind] or "a fight") .. where .. "."
    if note and note ~= "" then text = text .. "\n\"" .. note .. "\"" end
    UI.Popup({ title = "Invite request", text = text, accept = "Invite", cancel = "Ignore",
      onAccept = function()
        if finderOk() then UI.Try(ns.Finder.Invite, sender, { kind = kind, venue = venue, note = note }) end
      end })
  end)
end
