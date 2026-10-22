-- Clubs tab: fight-club venues, champion roster (faction x class), my streak, Challenge, open challenges.
-- Also owns the CLUB_CHALLENGED popup.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI
local M = A:NewModule("UIClubs")

local DAY = 86400
local NEEDED = 10
local venue

local function champRows(venueId)
  local data = ns.Club and ns.Club.Champions and UI.Try(ns.Club.Champions, venueId) or {}
  local rows = {}
  for faction, classes in pairs(data) do
    for class, c in pairs(classes) do
      rows[#rows + 1] = { faction = faction, class = class, className = UI.ClassText(class), name = UI.Short(c.name),
        streak = c.streak or 0, since = type(c.since) == "number" and date("%b %d", c.since) or "-" }
    end
  end
  table.sort(rows, function(a, b)
    if a.faction ~= b.faction then return a.faction < b.faction end
    return a.class < b.class
  end)
  return rows
end

local function remaining(t)
  if type(t) ~= "number" then return "-" end
  local left = t + 7 * DAY - MK.Util.ServerTime()
  if left <= 0 then return "expired" end
  return MK.Util.Duration(left)
end

local function challengeRows()
  local rows = {}
  local function add(c)
    if type(c) ~= "table" then return end
    rows[#rows + 1] = { champion = UI.Short(c.champion or c.target), venueName = UI.VenueName(c.venue),
      className = c.class and UI.ClassText(c.class) or "-", status = c.status or "open", left = remaining(c.t), t = c.t or 0 }
  end
  for _, c in pairs(ns.char and ns.char.challenges or {}) do add(c) end
  local site = MK.Wom and UI.Try(MK.Wom, "bloodsports", "challenges")
  for _, c in ipairs(type(site) == "table" and site or {}) do add(c) end
  table.sort(rows, function(a, b) return a.t > b.t end)
  return rows
end

local function build(pane)
  local k = UI.Kit()
  local items = {}
  for _, v in ipairs(UI.Venues("club")) do items[#items + 1] = { value = v.id, text = v.name } end
  venue = venue or (items[1] and items[1].value)
  local dd = k.Dropdown(pane, { width = 150, items = items, onSelect = function(v) venue = UI.Val(v); UI.Refresh() end })
  dd:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
  if dd.SetValue and venue then dd:SetValue(venue) end
  local streak = k.Label(pane, { text = "", font = "body" })
  streak:SetPoint("LEFT", dd, "RIGHT", 12, 0)
  local btn = k.Button(pane, { text = "Challenge", width = 100, height = 24, variant = "accent",
    tooltip = "Win " .. NEEDED .. " in a row here to challenge the champion of your class.",
    onClick = function()
      if not (ns.Club and ns.Club.Challenge) then A:Print("Clubs unavailable.") return end
      UI.Try(ns.Club.Challenge, venue)
    end })
  btn:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, 0)
  local h1 = k.Label(pane, { text = "Champions", font = "body", color = "accent", skin = UI.SKIN })
  h1:SetPoint("TOPLEFT", pane, "TOPLEFT", 8, -38)
  local champs = k.List(pane, { skin = UI.SKIN, rowHeight = 22, columns = {
    { key = "faction", title = "Faction", width = 80, kind = "text" },
    { key = "class", title = "", width = 28, kind = "class" },
    { key = "className", title = "Class", width = 90, kind = "text" },
    { key = "name", title = "Champion", width = 140, kind = "text" },
    { key = "streak", title = "Streak", width = 60, kind = "text", align = "RIGHT" },
    { key = "since", title = "Since", width = 70, kind = "text", align = "RIGHT" },
  } })
  champs:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, -62)
  champs:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 160)
  local h2 = k.Label(pane, { text = "Open challenges (7 days to answer)", font = "body", color = "accent", skin = UI.SKIN })
  h2:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 8, 138)
  local open = k.List(pane, { skin = UI.SKIN, rowHeight = 22, columns = {
    { key = "champion", title = "Champion", width = 120, kind = "text" },
    { key = "venueName", title = "Venue", width = 110, kind = "text" },
    { key = "className", title = "Class", width = 90, kind = "text" },
    { key = "status", title = "Status", width = 80, kind = "text" },
    { key = "left", title = "Time left", width = 90, kind = "text", align = "RIGHT" },
  } })
  open:SetPoint("TOPLEFT", pane, "BOTTOMLEFT", 0, 134)
  open:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, 0)
  pane.champs, pane.open = champs, open

  return function()
    if not (ns.Club and venue) then
      streak:SetText("Fight clubs unavailable.")
      btn:SetEnabledState(false)
      champs:SetData({}); open:SetData(challengeRows())
      return
    end
    local mine = UI.Try(ns.Club.MyStreak, venue) or 0
    local can = UI.Try(ns.Club.CanChallenge, venue) and true or false
    streak:SetText("Your streak here: " .. UI.Tint("accent", mine) .. " / " .. NEEDED)
    btn:SetEnabledState(can)
    champs:SetData(champRows(venue))
    open:SetData(challengeRows())
  end
end

UI.RegisterTab("clubs", build)

function M:OnLogin()
  A:Listen("CLUB_CHALLENGED", function(sender, venueId)
    UI.Popup({ title = "You have been challenged!",
      text = UI.Short(sender) .. " challenges you at " .. UI.VenueName(venueId) .. ".\nMeet them there and settle it with a duel.",
      accept = "Whisper them", cancel = "Later", onAccept = function() UI.Whisper(sender) end })
  end)
end
