-- UI kit: Demo. /mkdemo [elders|bloodsports] builds one of every widget with fake data (visual smoke test).

if MetaKit_SkipLoad then return end
local MK = MetaKit
local UI = MK.UI

local CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local NAMES = { "Thrall", "Aldric", "Mira", "Gorn", "Sylra", "Dunmar", "Ekko", "Bryn", "Voss", "Tamsin" }

local windows, minimap = {}, nil
local positions = {}
local demoDb = { settings = { toasts = true, volume = 5 } }

local function fakeRows(n)
  local rows = {}
  for i = 1, n do
    rows[i] = { rank = i, name = NAMES[(i - 1) % #NAMES + 1] .. i, class = CLASSES[(i - 1) % #CLASSES + 1],
      level = 1 + (i * 7) % 60, copper = (i * 12345) % 900000, icon = "Interface\\Icons\\INV_Misc_Coin_0" .. (i % 2 + 1) }
  end
  return rows
end

local function fakeSections()
  local out = {}
  for _, title in ipairs({ "Pace", "Downtime", "Combat", "Economy" }) do
    local rows = {}
    for i = 1, 6 do
      rows[i] = { icon = "Interface\\Icons\\INV_Misc_Note_0" .. (i % 2 + 1), label = title .. " stat " .. i,
        value = (i * 137) % 1000 .. "/h", sub = i % 2 == 0 and "per hour of played time" or nil,
        tooltip = { title .. " stat " .. i, { "Fake data for the demo." } } }
    end
    out[#out + 1] = { title = title, rows = rows }
  end
  return out
end

local function build(skinName)
  local s = UI.Skin(skinName)
  positions[skinName] = positions[skinName] or {}
  local win = UI.Window({ name = "MetaKitDemo_" .. skinName, skin = s, width = 720, height = 560,
    title = "MetaKit UI - " .. skinName, subtitle = "Every widget with fake data", db = positions[skinName] })
  local c = win.content

  local pages = {}
  local function page() local p = CreateFrame("Frame", nil, c); p:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -34); p:SetPoint("BOTTOMRIGHT", c, "BOTTOMRIGHT", 0, 0); p:Hide(); return p end
  local tabs = UI.Tabs(c, { skin = s, labels = { "Widgets", "List", "Stats" }, width = 300, onSelect = function(i)
    for j, p in ipairs(pages) do p:SetShown(j == i) end
  end })
  tabs:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0)

  -- Widgets page
  local w = page()
  pages[1] = w
  local y = 0
  for _, kind in ipairs({ "title", "big", "body", "small", "number" }) do
    local l = UI.Label(w, { skin = s, font = kind, text = "Label font: " .. kind })
    l:SetPoint("TOPLEFT", w, "TOPLEFT", 0, -y)
    y = y + (kind == "title" and 30 or 18)
  end
  local div = UI.Divider(w, s)
  div:SetPoint("TOPLEFT", w, "TOPLEFT", 0, -y - 4)
  div:SetPoint("TOPRIGHT", w, "TOPRIGHT", 0, -y - 4)
  y = y + 14
  local x = 0
  local b1 = UI.Button(w, { skin = s, text = "Default", tooltip = "A default button" })
  local b2 = UI.Button(w, { skin = s, text = "Accent", variant = "accent" })
  local b3 = UI.Button(w, { skin = s, text = "Danger", variant = "danger" })
  local b4 = UI.Button(w, { skin = s, text = "Toggle", icon = "Interface\\Icons\\INV_Misc_Gear_01",
    onClick = function(b) b:SetActive(not b.active) end })
  local b5 = UI.Button(w, { skin = s, text = "Disabled" })
  b5:SetEnabledState(false)
  for _, b in ipairs({ b1, b2, b3, b4, b5 }) do
    b:SetPoint("TOPLEFT", w, "TOPLEFT", x, -y)
    x = x + b:GetWidth() + 8
  end
  y = y + 34
  x = 0
  local ring = UI.Icon(w, { skin = s, size = 32, circle = true, ring = "accent", texture = "Interface\\Icons\\INV_Misc_Book_09" })
  ring:SetPoint("TOPLEFT", w, "TOPLEFT", 4, -y - 3)
  x = 48
  for _, token in ipairs(CLASSES) do
    local ci = UI.ClassIcon(w, 24, s)
    ci:SetClass(token)
    ci:SetPoint("TOPLEFT", w, "TOPLEFT", x, -y)
    x = x + 28
  end
  y = y + 42
  local cb = UI.Checkbox(w, { skin = s, label = "Show toasts", checked = true, tooltip = "Checkbox tooltip" })
  cb:SetPoint("TOPLEFT", w, "TOPLEFT", 0, -y)
  local dd = UI.Dropdown(w, { skin = s, width = 170, items = { { value = "a", text = "First option" }, { value = "b", text = "Second option" }, { value = "c", text = "Third option" } },
    value = "a" })
  dd:SetPoint("TOPLEFT", w, "TOPLEFT", 240, -y)
  y = y + 32
  local eb = UI.EditBox(w, { skin = s, width = 260, placeholder = "Type something..." })
  eb:SetPoint("TOPLEFT", w, "TOPLEFT", 0, -y)
  local rating = UI.Rating(w, { skin = s, count = 5, size = 26 })
  rating:SetPoint("TOPLEFT", w, "TOPLEFT", 280, -y)
  rating:SetValue(3)
  y = y + 34
  local multi = UI.EditBox(w, { skin = s, width = 420, height = 70, multiline = true, maxLetters = 280, placeholder = "Multiline, 280 letters..." })
  multi:SetPoint("TOPLEFT", w, "TOPLEFT", 0, -y)

  local actions = {
    { "Toast (good)", function() UI.Toast({ skin = s, title = "Bracket sealed", text = "Levels 1-10 are in the books.", banner = "good", sound = true }) end },
    { "Toast (bad)", function() UI.Toast({ skin = s, title = "Defeat", text = "The duel was lost.", banner = "bad" }) end },
    { "Talking head", function()
      UI.TalkingHead({ skin = s, unit = "player", name = "The Elders", text = "Tell us how levels 1-10 felt.",
        buttons = { { text = "Later" }, { text = "Rate now" } } })
    end },
    { "Confirm", function() UI.Confirm({ skin = s, title = "Are you sure?", text = "This is a demo dialog.", onAccept = function() print("accepted") end }) end },
    { "Export box", function() UI.ExportBox({ skin = s, title = "Export", text = string.rep("WOM1:demo:ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:", 12) }) end },
    { "Settings", function()
      if not demoDb.category then
        demoDb.category = UI.Settings({ name = "MetaKit Demo", db = demoDb.settings, options = {
          { type = "header", label = "Demo" }, { type = "check", key = "toasts", label = "Toasts" },
          { type = "slider", key = "volume", label = "Volume", min = 0, max = 10, step = 1 } } })
      end
      UI.OpenSettings(demoDb.category)
    end },
  }
  for i, a in ipairs(actions) do
    local b = UI.Button(w, { skin = s, text = a[1], width = 120, onClick = a[2] })
    b:SetPoint("TOPRIGHT", w, "TOPRIGHT", 0, -(i - 1) * 30)
  end

  -- List page
  local lp = page()
  pages[2] = lp
  local list = UI.List(lp, { skin = s, rowHeight = 24, empty = "Nothing here",
    columns = {
      { key = "rank", title = "#", width = 40 },
      { key = "class", title = "", width = 30, kind = "class" },
      { key = "name", title = "Name" },
      { key = "level", title = "Lvl", width = 50, align = "CENTER" },
      { key = "icon", title = "", width = 30, kind = "icon" },
      { key = "copper", title = "Gold", width = 110, kind = "money", align = "RIGHT" },
      { title = "", width = 70, kind = "button", buttonText = "Whisper", onClick = function(row) print("whisper " .. row.name) end },
    },
    onRowClick = function(row) print("clicked " .. row.name) end })
  list:SetPoint("TOPLEFT", lp, "TOPLEFT", 0, 0)
  list:SetPoint("BOTTOMRIGHT", lp, "BOTTOMRIGHT", 0, 0)
  list:SetData(fakeRows(500))

  -- Stats page
  local sp = page()
  pages[3] = sp
  local stats = UI.StatRows(sp, { skin = s, rowHeight = 30 })
  stats:SetPoint("TOPLEFT", sp, "TOPLEFT", 0, 0)
  stats:SetPoint("BOTTOMRIGHT", sp, "BOTTOMRIGHT", 0, 0)
  stats:SetSections(fakeSections())

  win.tabs, win.list, win.stats, win.rating = tabs, list, stats, rating
  tabs:Select(1)
  return win
end

function UI.Demo(skinName)
  local s = UI.Skin(skinName)
  local key = s.name or "elders"
  local win = windows[key]
  if not win then
    win = build(key)
    windows[key] = win
  end
  if not minimap then
    minimap = UI.MinimapButton({ name = "MetaKitDemoMinimapButton", icon = "Interface\\Icons\\INV_Misc_Book_09",
      db = demoDb.minimap or {}, onClick = function() UI.Demo(key) end,
      tooltip = function(tt) tt:AddLine("MetaKit demo", 1, 0.82, 0) end })
  end
  win:Show()
  return win
end

SLASH_METAKITDEMO1 = "/mkdemo"
SlashCmdList.METAKITDEMO = function(msg)
  local name = (msg or ""):match("%a+")
  name = name and name:lower() or "elders"
  UI.Demo(name)
end
