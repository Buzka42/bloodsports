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
      rows[#rows + 1] = { faction = faction, class = class, className = UI.ClassText(class), name = UI.Short(c.name), full = c.name,
        streak = c.streak or 0, since = type(c.since) == "number" and date("%b %d", c.since) or UI.DASH }
    end
  end
  table.sort(rows, function(a, b)
    if a.faction ~= b.faction then return a.faction < b.faction end
    return a.class < b.class
  end)
  return rows
end

local function remaining(t)
  if type(t) ~= "number" then return UI.DASH end
  local left = t + 7 * DAY - MK.Util.ServerTime()
  if left <= 0 then return "expired" end
  return MK.Util.Duration(left)
end

local function challengeRows()
  local rows = {}
  local function add(c)
    if type(c) ~= "table" then return end
    rows[#rows + 1] = { champion = UI.Short(c.champion or c.target), venueName = UI.VenueName(c.venue),
      className = c.class and UI.ClassText(c.class) or UI.DASH, status = c.status or "open", left = remaining(c.t), t = c.t or 0 }
  end
  for _, c in pairs(ns.char and ns.char.challenges or {}) do add(c) end
  local site = MK.Wom and UI.Try(MK.Wom, "bloodsports", "challenges")
  for _, c in ipairs(type(site) == "table" and site or {}) do add(c) end
  table.sort(rows, function(a, b) return a.t > b.t end)
  return rows
end

-- v16 (judge4): "1 champion · 0 open challenges" (the club name already sits in the dropdown and the road line)
function UI.ClubsFooter(nChamps, nOpen)
  return UI.Plural(nChamps, "champion") .. " · " .. UI.Plural(nOpen, "open challenge")
end

-- v17 (judge5): the Open challenges empty hint follows the champions roster: with nobody to call out, "Press
-- Challenge" pointed at nothing, so an empty roster says how the title is won instead.
UI.CLUBS_OPEN_EMPTY = "No open challenges."
function UI.ClubsOpenHint(nChamps)
  if (tonumber(nChamps) or 0) > 0 then return "Press Challenge to call out the champion." end
  return "Build your streak here to claim the title."
end

-- v16 (judge4 clubs void): the "Your road to the title" line under Open challenges, from the same MyStreak the header
-- reads: "Streak S / 10 at <club>" + a 6 px progress bar whose gold fill is S / 10 of the content width.
UI.ROAD_TITLE, UI.ROAD_BAR_H = "Your road to the title", 6
function UI.RoadText(streak, needed, clubName)
  return "Streak " .. (tonumber(streak) or 0) .. " / " .. (tonumber(needed) or NEEDED) .. " at " .. (clubName or UI.DASH)
end
-- Fill width in px for a track `width` px wide: floor(width * clamp(streak / needed, 0, 1)).
function UI.RoadFill(streak, needed, width)
  needed = tonumber(needed) or NEEDED
  local f = needed > 0 and math.max(0, math.min(1, (tonumber(streak) or 0) / needed)) or 0
  return math.floor((tonumber(width) or 0) * f), f
end

-- The standing the sidebar YOUR CLUB card reads: { venue, name, streak, needed, champion } or nil (no club data).
function UI.ClubState()
  if not (ns.Club and venue) then return nil end
  local mine = UI.Try(ns.Club.MyStreak, venue) or 0
  local champion = false
  for _, r in ipairs(champRows(venue)) do
    if r.full and UI.SameName and UI.SameName(r.full, MK.CommKey and MK.CommKey() or "") then champion = r.className end
  end
  return { venue = venue, name = UI.VenueName(venue), streak = mine, needed = NEEDED, champion = champion }
end

local CTRL_H, DD_W, ROW_H, HEAD_H, SECTION_GAP = 22, 230, 22, 22, 16
local ROAD_H = 34 -- v16: road line (16) + 4 + bar (6) + 8 under the challenges table
local HEAD_Y, RULE_Y, LIST_TOP = -(CTRL_H + 12), -(CTRL_H + 32), -(CTRL_H + 38)

local function build(pane)
  local k = UI.Kit()
  local items = {}
  for _, v in ipairs(UI.Venues("club")) do items[#items + 1] = { value = v.id, text = v.name } end
  venue = venue or (items[1] and items[1].value)
  -- C1 / F-4: 230 px holds "Honor Road Fight Club" on one line (the kit's button label never wraps)
  local dd = k.Dropdown(pane, { width = DD_W, height = CTRL_H, items = items, onSelect = function(v) venue = UI.Val(v); UI.Refresh() end })
  dd:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, 0)
  if dd.SetValue and venue then dd:SetValue(venue) end
  local btn = k.Button(pane, { text = "Challenge", width = 100, height = CTRL_H, variant = "primary",
    tooltip = "Win " .. NEEDED .. " in a row here to challenge the champion of your class.",
    onClick = function()
      if not (ns.Club and ns.Club.Challenge) then A:Print("Clubs unavailable.") return end
      UI.Try(ns.Club.Challenge, venue)
    end })
  btn:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, 0)   -- C4: right edge on the inset edge
  local streak = k.Label(pane, { text = "", font = "body" })
  if streak.SetWordWrap then streak:SetWordWrap(false) end
  streak:SetPoint("LEFT", dd, "RIGHT", 12, 0)
  streak:SetPoint("RIGHT", btn, "LEFT", -12, 0)
  local h1 = k.Label(pane, { text = "Champions", font = "body", color = "accent", skin = UI.SKIN })
  h1:SetPoint("TOPLEFT", pane, "TOPLEFT", UI.CONTENT_X, HEAD_Y)
  local r1 = UI.SectionRule(pane)
  r1:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, RULE_Y)
  r1:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, RULE_Y)
  local champs = k.List(pane, { skin = UI.SKIN, rowHeight = ROW_H, chrome = "inset", gutter = UI.LIST_GUTTER,
    headerHeight = HEAD_H, emptyAlign = "LEFT",
    empty = "No champion holds this club.", emptyHint = "Win a challenge to claim the title.", columns = {
    { key = "faction", title = "Faction", width = 80, kind = "text" },
    { key = "class", title = "", width = UI.ICON_W, kind = "class" },
    { key = "className", title = "Class", width = 90, kind = "text" },
    { key = "name", title = "Champion", kind = "text" }, -- flex
    { key = "streak", title = "Streak", width = 60, kind = "text", align = "RIGHT" },
    { key = "since", title = "Since", width = 70, kind = "text", align = "RIGHT" },
  } })
  local h2 = k.Label(pane, { text = "Open challenges (7 days to answer)", font = "body", color = "accent", skin = UI.SKIN })
  local r2 = UI.SectionRule(pane)
  local open = k.List(pane, { skin = UI.SKIN, rowHeight = ROW_H, chrome = "inset", gutter = UI.LIST_GUTTER,
    headerHeight = HEAD_H, emptyAlign = "LEFT",
    empty = UI.CLUBS_OPEN_EMPTY, emptyHint = UI.ClubsOpenHint(0), columns = {
    { key = "champion", title = "Champion", kind = "text" }, -- flex
    { key = "venueName", title = "Venue", width = 110, kind = "text" },
    { key = "className", title = "Class", width = 90, kind = "text" },
    { key = "status", title = "Status", width = 80, kind = "text" },
    { key = "left", title = "Time left", width = 90, kind = "text", align = "RIGHT" },
  } })
  local foot = UI.PaneFooter(pane)
  -- v16: road to the title -- gold-dim title + streak text on one line, a dark track with a gold fill under it
  local road = CreateFrame("Frame", nil, pane)
  road:SetHeight(ROAD_H - 8)
  road:SetPoint("TOPLEFT", open, "BOTTOMLEFT", 0, -8)
  road:SetPoint("TOPRIGHT", open, "BOTTOMRIGHT", 0, -8)
  local roadTitle = k.Label(road, { text = UI.ROAD_TITLE, font = "body", color = "accent", skin = UI.SKIN })
  roadTitle:SetPoint("TOPLEFT", road, "TOPLEFT", UI.CONTENT_X, 0)
  local roadText = k.Label(road, { text = "", font = "body", color = "text", skin = UI.SKIN })
  if roadText.SetWordWrap then roadText:SetWordWrap(false) end
  roadText:SetJustifyH("RIGHT")
  roadText:SetPoint("TOPRIGHT", road, "TOPRIGHT", -UI.CONTENT_X, 0)
  roadText:SetPoint("LEFT", roadTitle, "RIGHT", 12, 0)
  local track = road:CreateTexture(nil, "BORDER")
  track:SetPoint("TOPLEFT", road, "TOPLEFT", UI.CONTENT_X, -20)
  track:SetPoint("TOPRIGHT", road, "TOPRIGHT", -UI.CONTENT_X, -20)
  track:SetHeight(UI.ROAD_BAR_H)
  track:SetColorTexture(0, 0, 0, 0.55)
  local fill = road:CreateTexture(nil, "ARTWORK")
  fill:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
  fill:SetHeight(UI.ROAD_BAR_H)
  local GOLD = { 0.97, 0.82, 0.42, 1 }
  fill:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], GOLD[4])
  fill.mkColor = GOLD
  fill:Hide()
  local roadStreak = 0
  local function roadLayout()
    local w = (pane:GetWidth() or 0) - 2 * UI.CONTENT_X
    local px, frac = UI.RoadFill(roadStreak, NEEDED, w)
    fill:SetWidth(math.max(px, 1))
    fill:SetShown(px > 0)
    pane.road = { streak = roadStreak, frac = frac, fillW = px, contentW = w, barH = UI.ROAD_BAR_H, text = roadText:GetText() }
  end
  pane:HookScript("OnSizeChanged", roadLayout)
  pane.roadFrame, pane.roadFill, pane.roadTrack, pane.roadText = road, fill, track, roadText

  -- C3 (the Matches rule): an empty champions table collapses to header + 2 rows and the challenges follow it up;
  -- with champions the roster fills and the challenges keep 2-4 rows on the footer band
  local function layout(nChamps, nOpen)
    local openRows = nOpen == 0 and 2 or math.max(2, math.min(4, nOpen))
    local openH = open:HeightFor(openRows)
    champs:ClearAllPoints(); open:ClearAllPoints(); h2:ClearAllPoints(); r2:ClearAllPoints()
    champs:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, LIST_TOP)
    local champH, h2Y
    if nChamps == 0 then
      champH = champs:HeightFor(2)
      champs:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, LIST_TOP)
      champs:SetHeight(champH)
      h2Y = LIST_TOP - champH - SECTION_GAP
      h2:SetPoint("TOPLEFT", pane, "TOPLEFT", UI.CONTENT_X, h2Y)
      r2:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, h2Y + (RULE_Y - HEAD_Y))
      r2:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, h2Y + (RULE_Y - HEAD_Y))
      open:SetPoint("TOPLEFT", pane, "TOPLEFT", 0, h2Y + (LIST_TOP - HEAD_Y))
      open:SetPoint("TOPRIGHT", pane, "TOPRIGHT", 0, h2Y + (LIST_TOP - HEAD_Y))
      open:SetHeight(openH)
    else
      open:SetPoint("BOTTOMLEFT", pane, "BOTTOMLEFT", 0, UI.FOOT_H + ROAD_H) -- v16: the road line under it
      open:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, UI.FOOT_H + ROAD_H)
      open:SetHeight(openH)
      local hY = UI.FOOT_H + ROAD_H + openH + (HEAD_Y - LIST_TOP)   -- header text top, px above the pane bottom
      h2:SetPoint("TOPLEFT", pane, "BOTTOMLEFT", UI.CONTENT_X, hY)
      r2:SetPoint("TOPLEFT", pane, "BOTTOMLEFT", 0, hY + (RULE_Y - HEAD_Y))
      r2:SetPoint("TOPRIGHT", pane, "BOTTOMRIGHT", 0, hY + (RULE_Y - HEAD_Y))
      champs:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", 0, hY + SECTION_GAP)
      champH, h2Y = "fill", "bottom"
    end
    pane.layout = { champRows = nChamps == 0 and 2 or "fill", champH = champH, openRows = openRows, openH = openH,
      openHeadY = h2Y, listTop = LIST_TOP, footH = UI.FOOT_H, ddW = DD_W, ctrlH = CTRL_H, roadH = ROAD_H }
  end
  layout(0, 0)
  pane.champs, pane.open, pane.footer, pane.clubDD, pane.challenge, pane.layoutFn = champs, open, foot, dd, btn, layout

  return function()
    local crows, orows = {}, challengeRows()
    roadStreak = 0
    if not (ns.Club and venue) then
      streak:SetText("Fight clubs unavailable.")
      btn:SetEnabledState(false)
    else
      local mine = UI.Try(ns.Club.MyStreak, venue) or 0
      roadStreak = tonumber(mine) or 0
      local can = UI.Try(ns.Club.CanChallenge, venue) and true or false
      streak:SetText("Your streak here: " .. UI.Tint("accent", mine) .. " / " .. NEEDED)
      btn:SetEnabledState(can)
      crows = champRows(venue)
    end
    champs:SetData(crows)
    open:SetEmptyText(UI.CLUBS_OPEN_EMPTY, UI.ClubsOpenHint(#crows))
    open:SetData(orows)
    layout(#crows, #orows)
    local nOpen = 0
    for _, r in ipairs(orows) do if r.status == "open" then nOpen = nOpen + 1 end end
    foot:SetText(UI.ClubsFooter(#crows, nOpen))
    roadText:SetText(UI.RoadText(roadStreak, NEEDED, venue and UI.VenueName(venue) or nil))
    roadLayout()
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
