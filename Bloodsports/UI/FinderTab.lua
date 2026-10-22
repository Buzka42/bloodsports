-- Finder tab: find duel partners, fight-club rivals and ring referees; whisper / invite / ask-invite buttons.
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

local st = { kind = "duel", venue = {}, note = "", queried = 0 }

local function finderOk()
  if ns.Finder then return true end
  A:Print("Finder unavailable.")
  return false
end

local function ctx(row) return { kind = row.kind, venue = row.venue, note = st.note } end

local function toRow(e)
  local isRef = e.kind == "ref"
  local extra
  if isRef then extra = type(e.rating) == "number" and string.format("%.1f*", e.rating) or "-"
  else extra = (e.streak and e.streak > 0) and ("W" .. e.streak) or "-" end
  return {
    full = e.name, name = UI.Short(e.name), class = e.class, level = e.level or "?", kind = e.kind, venue = e.venue,
    venueName = UI.VenueName(e.venue), extra = extra, seen = UI.Ago(e.seen), note = e.note,
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

local function build(pane)
  local k = UI.Kit()
  local db = UI.Db()
  db.finder = db.finder or {}
  st.note = db.finder.note or ""
  local kindDD = k.Dropdown(pane, { width = 130, items = KINDS, onSelect = function(v) st.kind = UI.Val(v) or "duel"; UI.Refresh() end })
  kindDD:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
  if kindDD.SetValue then kindDD:SetValue("duel") end

  local venueDD = {}
  for _, kd in ipairs(KINDS) do
    if not venueDD[kd.venueKind] then
      local items = { { value = "", text = "Anywhere" } }
      for _, v in ipairs(UI.Venues(kd.venueKind)) do items[#items + 1] = { value = v.id, text = v.name } end
      local dd = k.Dropdown(pane, { width = 130, items = items, onSelect = function(v)
        for _, x in ipairs(KINDS) do if x.venueKind == kd.venueKind then st.venue[x.value] = UI.Val(v) or "" end end
        UI.Refresh()
      end })
      dd:SetPoint("LEFT", kindDD, "RIGHT", 4, 0)
      if dd.SetValue then dd:SetValue("") end
      venueDD[kd.venueKind] = dd
    end
  end

  local listing = false
  local note
  local check = k.Checkbox(pane, { label = "List me", checked = false, onChange = function(on)
    listing = on and true or false
    if st.kind == "ref" then
      A.db.config.referee.available = listing
      A:Fire("REFEREE_AVAILABILITY", listing)
    elseif finderOk() then
      if listing then UI.Try(ns.Finder.SetLooking, st.kind, st.venue[st.kind] or "", st.note)
      else UI.Try(ns.Finder.StopLooking) end
    end
  end })
  check:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -32)
  note = k.EditBox(pane, { width = 220, height = 22, maxLetters = 60, placeholder = "Note (optional)", onChange = function(t)
    if type(t) ~= "string" then t = note and note:GetText() or "" end
    st.note = t
    db.finder.note = t
  end })
  note:SetPoint("LEFT", check, "RIGHT", 90, 0)
  if note.SetText and st.note ~= "" then note:SetText(st.note) end
  local scan = k.Button(pane, { text = "Scan", width = 70, height = 22, tooltip = "Ask nearby Bloodsports users to announce themselves",
    onClick = function()
      if GetTime() - st.queried < 10 then return end
      st.queried = GetTime()
      if ns.finder and ns.finder.Query then
        local v = st.venue[st.kind]
        UI.Try(ns.finder.Query, ns.finder, st.kind, v ~= "" and v or nil)
      end
    end })
  scan:SetPoint("TOPRIGHT", pane, "TOPRIGHT", -8, -33)

  local msg = k.Label(pane, { text = "", font = "body", color = "muted" })
  msg:SetPoint("CENTER", pane, "CENTER", 0, -30)

  local function btn(key, text, fn) return { key = key, title = "", width = 62, kind = "button", buttonText = text, onClick = fn } end
  local function whisper(row) UI.Whisper(row.full) end
  local function invite(row)
    if finderOk() then UI.Try(ns.Finder.Invite, row.full, ctx(row)) end
  end
  local function ask(row)
    if row.kind ~= "ref" and row.kind ~= "club" and row.kind ~= "duel" then return end
    if finderOk() then UI.Try(ns.Finder.RequestInvite, row.full, row.kind, row.venue) end
  end
  local base = {
    { key = "class", title = "", width = 28, kind = "class" },
    { key = "name", title = "Name", width = 100, kind = "text" },
    { key = "level", title = "Lvl", width = 32, kind = "text" },
    { key = "venueName", title = "Venue", width = 90, kind = "text" },
    { key = "extra", title = "W / Rating", width = 62, kind = "text" },
    { key = "seen", title = "Seen", width = 40, kind = "text" },
  }
  local function cols(buttons)
    local c = {}
    for _, x in ipairs(base) do c[#c + 1] = x end
    for _, x in ipairs(buttons) do c[#c + 1] = x end
    return c
  end
  local function newList(buttons)
    local l = k.List(pane, { skin = UI.SKIN, rowHeight = 22, columns = cols(buttons) })
    l:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -62)
    l:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
    return l
  end
  local people = newList({ btn("w", "Whisper", whisper), btn("i", "Invite", invite), btn("a", "Ask invite", ask) })
  local refs = newList({ btn("w", "Whisper", whisper), btn("a", "Ask invite", ask) })
  pane.people, pane.refs = people, refs

  return function()
    local isRef = st.kind == "ref" or st.kind == "ring"
    people:SetShown(not isRef)
    refs:SetShown(isRef)
    local vk
    for _, kd in ipairs(KINDS) do if kd.value == st.kind then vk = kd.venueKind end end
    for key, dd in pairs(venueDD) do dd:SetShown(key == vk) end
    if st.kind == "ref" then check:SetChecked(A.db.config.referee.available) end
    local rows = fetch()
    if not rows then
      msg:SetText("Finder unavailable.")
      people:SetData({}); refs:SetData({})
    else
      msg:SetText(#rows == 0 and "Nobody listed here yet. Hit Scan, or list yourself and wait." or "")
      local target = isRef and refs or people
      target:SetData(rows)
    end
    msg:SetShown(msg:GetText() ~= "")
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
