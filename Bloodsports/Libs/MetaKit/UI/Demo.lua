-- UI kit: Demo. /mkdemo [elders|bloodsports] builds one of every widget with fake data (visual smoke test).
-- /mkchrome [dialog|portrait|flat] [buttons] opens the integrated Shell (UI.Shell, 960 x 640) with two tabs and
-- eight sections of realistic fake data.

if MetaKit_SkipLoad then return end
local _, demoNs = ... -- the loading addon's ns: its Media.lua (ns.Media) carries the shared shell art
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

---------------------------------------------------------------------------
-- /mkchrome [dialog|portrait|flat] [buttons]: the integrated Shell (960 x 640, 220 px sidebar) with realistic fake data. Bloodsports:
-- The Ring, Season Stats, Clubs, Finder, My Duels. Elders: Overview, Pace, Combat. The first view is The Ring,
-- filled; Season Stats is one click away. With no chrome word the demo uses "portrait" (v5: the best-scored look;
-- "dialog" stays opt-in); "buttons" asks for the native footer button. Each tab fills the sidebar gap between its
-- sections and its summary with a RECENT mini-list (Shell o.sidebarExtra / AddTab{ extra = }). UI.Shell is looked
-- up when the command runs (Shell.lua loads after this file).

local chromes, chromeDbs = {}, {}

local function gold(g, s) return (g or 0) * 10000 + (s or 0) * 100 end
local GOOD, BAD = "|cff3fbf6a", "|cffd0503c"
-- v7: demo money is fully compact: MK.Util.Money (normalised g / s / c) minus every trailing zero unit: 0c AND 0s
-- are dropped ("412g 35s", "+184g 20s", "2840g", "-12g", "50s"; 0 is "0s"); a non-zero copper keeps the full
-- MK.Util.Money form. MK.Util.Money itself is unchanged for every other caller. `sign` prefixes "+" on gains. Every demo purse / treasury string is <= 12
-- chars (at ~7 px a char that fits the 96-120 px money columns without an ellipsis).
local function money(copper, sign)
  copper = math.floor(copper or 0)
  local a = math.abs(copper)
  local txt
  if a % 100 ~= 0 then
    txt = MK.Util.Money(copper)
  else
    local g, s = math.floor(a / 10000), math.floor(a / 100) % 100
    local body
    if g > 0 then body = s > 0 and string.format("%dg %02ds", g, s) or string.format("%dg", g)
    else body = string.format("%ds", s) end
    txt = (copper < 0 and "-" or "") .. body
  end
  if sign and copper >= 0 then txt = "+" .. txt end
  return txt
end
UI.ChromeDemoMoney = money
local function moneyCell(row) return money(row.copper) end
local function signed(copper)
  return (copper >= 0 and GOOD or BAD) .. money(copper, true) .. "|r"
end

local RING = {
  { "Brakka", "WARRIOR", "Iron Circle", 41, 17, "W5", 60, gold(412, 35) },
  { "Velissa", "MAGE", "Red Sand", 38, 15, "W2", 60, gold(388, 10) },
  { "Moraine", "PRIEST", "Gilded Blades", 33, 14, "W3", 58, gold(351, 60) },
  { "Thornwick", "ROGUE", "Ashen Fist", 35, 19, "L1", 60, gold(297, 80) },
  { "Kezrin", "WARLOCK", "Night Owls", 31, 20, "W1", 60, gold(276, 15) },
  { "Seraphine", "DRUID", "Gilded Blades", 27, 16, "W1", 60, gold(254, 40) },
  { "Aldous", "PALADIN", "Iron Circle", 30, 18, "L2", 57, gold(231, 5) },
  { "Grimtusk", "SHAMAN", "Red Sand", 29, 21, "W4", 55, gold(208, 90) },
  { "Lunelle", "MAGE", "Night Owls", 25, 13, "W6", 49, gold(187, 25) },
  { "Ozrik", "HUNTER", "Ashen Fist", 26, 22, "L3", 52, gold(164, 70) },
  { "Dravos", "WARRIOR", "Red Sand", 24, 19, "L1", 48, gold(142, 50) },
  { "Hestia", "PRIEST", "Iron Circle", 22, 18, "W2", 45, gold(121, 30) },
  { "Ysolde", "ROGUE", "Gilded Blades", 20, 11, "W2", 40, gold(98, 75) },
  { "Korgath", "SHAMAN", "Ashen Fist", 21, 24, "L4", 44, gold(86, 20) },
  { "Brannoc", "PALADIN", "Night Owls", 18, 15, "L1", 38, gold(64, 45) },
  { "Vexa", "WARLOCK", "Red Sand", 17, 12, "W1", 34, gold(51, 10) },
  { "Tamsin", "DRUID", "Iron Circle", 15, 16, "L2", 30, gold(37, 85) },
  { "Ulfric", "HUNTER", "Ashen Fist", 12, 14, "W1", 27, gold(22, 40) },
}

local CLUBS = {
  { "Iron Circle", "Gurubashi Arena", 42, 1912, gold(2840), "INV_BannerPVP_02" },
  { "Red Sand", "Gurubashi Arena", 38, 1876, gold(2315, 50), "INV_Sword_04" },
  { "Gilded Blades", "Booty Bay", 35, 1840, gold(1990), "INV_Jewelry_Ring_03" },
  { "Ashen Fist", "Orgrimmar Gates", 33, 1797, gold(1764, 20), "INV_Gauntlets_04" },
  { "Night Owls", "Darnassus Terrace", 29, 1755, gold(1402), "INV_Misc_Bone_HumanSkull_01" },
  { "Crossroads Brawlers", "The Crossroads", 27, 1702, gold(1188, 75), "INV_Axe_02" },
  { "Goldshire Duelists", "Goldshire", 26, 1671, gold(1040), "INV_Mace_01" },
  { "Tarren Mill Wardens", "Tarren Mill", 24, 1648, gold(912, 40), "INV_Shield_04" },
  { "Southshore Militia", "Southshore", 22, 1615, gold(806), "INV_Helmet_03" },
  { "Bay Cutthroats", "Booty Bay", 21, 1590, gold(745, 10), "Ability_DualWield" },
  { "Razor Hill Raiders", "Razor Hill", 19, 1561, gold(633), "Ability_Warrior_BattleShout" },
  { "Dun Morogh Bruisers", "Ironforge Gates", 17, 1534, gold(520, 60), "INV_Hammer_05" },
  { "Silverpine Shades", "The Sepulcher", 14, 1502, gold(415), "Spell_Shadow_ShadowWordPain" },
  { "Needles Outriders", "Thousand Needles", 12, 1477, gold(298, 30), "INV_Misc_Head_Centaur_01" },
}

local DUELS = {
  { "Nov 8", "ROGUE", "Thornwick", "Gurubashi Arena", true, 60, gold(18, 50) },
  { "Nov 8", "MAGE", "Velissa", "Gurubashi Arena", false, 60, -gold(12) },
  { "Nov 7", "SHAMAN", "Grimtusk", "Orgrimmar Gates", true, 55, gold(9, 75) },
  { "Nov 7", "PRIEST", "Hestia", "Goldshire", true, 45, gold(6, 20) },
  { "Nov 6", "WARLOCK", "Kezrin", "Booty Bay", false, 60, -gold(15, 40) },
  { "Nov 6", "HUNTER", "Ozrik", "The Crossroads", true, 52, gold(11) },
  { "Nov 5", "DRUID", "Seraphine", "Booty Bay", true, 60, gold(14, 60) },
  { "Nov 5", "WARRIOR", "Dravos", "Razor Hill", true, 48, gold(7, 35) },
  { "Nov 4", "PALADIN", "Aldous", "Ironforge Gates", false, 57, -gold(8, 80) },
  { "Nov 4", "ROGUE", "Ysolde", "Tarren Mill", true, 40, gold(5, 10) },
  { "Nov 3", "SHAMAN", "Korgath", "Orgrimmar Gates", true, 44, gold(6, 90) },
  { "Nov 2", "MAGE", "Lunelle", "Darnassus Terrace", false, 49, -gold(10) },
  { "Nov 2", "WARLOCK", "Vexa", "The Sepulcher", true, 34, gold(3, 45) },
  { "Nov 1", "PALADIN", "Brannoc", "Southshore", true, 38, gold(4, 25) },
  { "Oct 31", "DRUID", "Tamsin", "Goldshire", true, 30, gold(2, 80) },
  { "Oct 30", "HUNTER", "Ulfric", "Thousand Needles", false, 27, -gold(1, 50) },
}

local MISS = { 4.1, 5.0, 4.6, 3.9, 2.8, 0, 0, 3.2, 4.4, 3.6, 5.1, 2.9, 4.8, 3.3 } -- % per COMBAT row
local COMBAT = {
  { "Mortal Strike", "Ability_Warrior_SavageBlow", 1284, 31.2, 612, 148.6, 27.4 },
  { "Melee", "INV_Sword_04", 4120, 24.8, 171, 131.0, 24.1 },
  { "Whirlwind", "Ability_Whirlwind", 702, 29.5, 488, 63.9, 11.8 },
  { "Heroic Strike", "Ability_Rogue_Ambush", 866, 27.1, 342, 54.9, 10.1 },
  { "Execute", "INV_Sword_48", 214, 35.0, 1105, 43.8, 8.1 },
  { "Overpower", "Ability_MeleeDamage", 391, 41.7, 402, 29.1, 5.4 },
  { "Deep Wounds", "Ability_BackStab", 958, 0, 118, 21.0, 3.9 },
  { "Rend", "Ability_Gouge", 1176, 0, 74, 16.2, 3.0 },
  { "Cleave", "Ability_Warrior_Cleave", 288, 26.4, 251, 13.4, 2.5 },
  { "Slam", "Ability_Warrior_DecisiveStrike", 132, 28.0, 465, 11.4, 2.1 },
  { "Thunder Clap", "Spell_Nature_ThunderClap", 167, 22.8, 196, 6.1, 1.1 },
  { "Revenge", "Ability_Warrior_Revenge", 94, 30.9, 288, 5.0, 0.9 },
  { "Hamstring", "Ability_ShockWave", 241, 19.5, 52, 2.3, 0.4 },
  { "Shield Slam", "INV_Shield_05", 18, 33.3, 402, 1.4, 0.3 },
}

local function icon(name) return "Interface\\Icons\\" .. name end

-- One stat row; good = true / false colours the value "good" / "bad", "focal" marks the one gold value of a
-- section, nil leaves it plain.
local function stat(ic, label, value, sub, good)
  return { icon = icon(ic), label = label, value = value, sub = sub,
    color = good == true and "good" or good == false and "bad" or good == "focal" and "focal" or nil,
    tooltip = { label, { "Demo data." } } }
end

local SEASON = {
  { title = "Record", rows = {
    stat("INV_Sword_04", "Duels fought", "58  (+9)", "this week", true),
    stat("Achievement_Arena_2v2_1", "Wins", "41  (+7)", "70.7% win rate", true),
    stat("Ability_Rogue_FeignDeath", "Losses", "17  (+2)", "two at the Gurubashi Arena", false),
    stat("Spell_Holy_BorrowedTime", "Longest streak", "9", "Oct 12 to Oct 19"),
    stat("INV_Misc_Note_01", "Rating", "1,842  (+38)", "rank 3 of 214", "focal"),
    stat("Ability_Warrior_BattleShout", "Club standing", "-1 place", "Iron Circle, 2nd of 14", false),
  } },
  { title = "Purse", rows = {
    stat("INV_Misc_Coin_01", "Gold won", money(gold(412, 35), true), nil, true),
    stat("INV_Misc_Coin_03", "Gold lost", money(-gold(96, 20), true), nil, false),
    stat("INV_Misc_Bag_10", "Ring fees", money(-gold(18, 40), true), "paid to the house", false),
    stat("INV_Misc_Coin_02", "Bets won", money(gold(64, 10), true), "23 bets placed", true),
    stat("INV_Misc_Coin_05", "Net this season", money(gold(361, 85), true), nil, "focal"),
  } },
}

local FINDER = {
  { title = "Nearby", rows = {
    stat("Ability_Hunter_SniperShot", "Duelists in range", "14  (+3)", "within 200 yards", true),
    stat("INV_Misc_Note_02", "Open challenges", "6", "two at your level"),
    stat("Spell_Holy_BorrowedTime", "Average wait", "2m 10s  (-25s)", "last hour", true),
    stat("Ability_Warrior_Challange", "Level-matched (3 levels)", "9  (+1)", nil, true),
    stat("Ability_Rogue_Sprint", "Declined today", "-2", "they walked away", false),
    stat("INV_Misc_Bag_10", "Ring fee", money(-gold(1, 50), true), "per duel at the arena", false),
    stat("INV_Misc_Coin_02", "Best odds offered", "+1.8x", "on Brakka vs Velissa", true),
    stat("Spell_Nature_TimeStop", "Your queue position", "#3", "of 11 waiting", "focal"),
  } },
}

-- v7: Finder is a LIST of nearby duelists (it6: eight aggregate stat rows left ~45% of the pane empty). The old stat
-- sections stay exported as ChromeDemoData().finderStats.
local CLASS_HEX = { WARRIOR = "c79c6e", PALADIN = "f58cba", HUNTER = "abd473", ROGUE = "fff569", PRIEST = "ffffff",
  SHAMAN = "0070de", MAGE = "69ccf0", WARLOCK = "9482c9", DRUID = "ff7d0a" }
local DUELISTS = {
  { "Brakka", "WARRIOR", 60, 18, "Wants a rematch" },
  { "Velissa", "MAGE", 60, 24, "Bets open, 1.8x" },
  { "Thornwick", "ROGUE", 58, 31, "Level-matched" },
  { "Grimtusk", "SHAMAN", 59, 40, "In the ring queue" },
  { "Hestia", "PRIEST", 60, 46, "Accepts any challenge" },
  { "Kezrin", "WARLOCK", 57, 52, "Level-matched" },
  { "Aldric", "PALADIN", 60, 63, "Club: Iron Circle" },
  { "Mossbark", "DRUID", 56, 70, "New this week" },
  { "Sylvaine", "HUNTER", 60, 85, "Wants a rematch" },
  { "Orrin", "WARRIOR", 55, 97, "Out of your range" },
  { "Nyx", "ROGUE", 60, 112, "Club: Red Sand" },
  { "Darrow", "MAGE", 58, 140, "Busy - questing" },
}
UI.ChromeDemoDuelists = DUELISTS

local OVERVIEW = {
  { title = "Character", rows = {
    stat("Achievement_Level_10", "Level", "24  (+3)", "this week", "focal"),
    stat("Spell_Holy_BorrowedTime", "Time played", "2d 4h", "9h this week"),
    stat("INV_Misc_Coin_01", "Gold", money(gold(184, 20), true), "since level 10", true),
    stat("Ability_Rogue_FeignDeath", "Deaths", "7  (+2)", "two to falling", false),
    stat("INV_Misc_Note_01", "Quests completed", "112  (+18)", nil, true),
    stat("INV_Misc_Key_03", "Dungeons cleared", "6", "Deadmines twice"),
    stat("Trade_Mining", "Mining", "187 / 300", "+42 this week", true),
    stat("Spell_Nature_Sleep", "Rested bonus", "+38%", "logged out at an inn", true),
  } },
  -- v6: a second section so the page is not 40% empty under eight rows
  { title = "This week", rows = {
    stat("Spell_Holy_SurgeOfLight", "Experience gained", "212,400", "3.4 levels' worth", true),
    stat("INV_Misc_Coin_02", "Gold looted", money(gold(46, 75), true), "vendor trash included", true),
    stat("INV_Misc_Bag_10", "Repairs", money(-gold(4, 10), true), "two deaths, one wipe", false),
    stat("Ability_Rogue_Sprint", "Zones visited", "5", "Duskwood the longest"),
  } },
}

local PACE = {
  { title = "Against the realm median", rows = {
    stat("Spell_Holy_SurgeOfLight", "XP per hour", "41,200  (+12%)", "median 36,800", true),
    stat("Achievement_Level_10", "Levels per day played", "4.1  (-0.3)", "median 4.4", false),
    stat("Spell_Nature_Sleep", "Downtime", "14%  (-3%)", "eating, drinking, resting", true),
    stat("Ability_DualWield", "Time in combat", "38%", "median 35%"),
    stat("Ability_Rogue_FeignDeath", "Deaths per level", "0.29  (+0.05)", "median 0.24", false),
    stat("INV_Misc_Coin_01", "Gold per hour", money(gold(8, 40), true), "median " .. money(gold(6, 10)), true),
    stat("Ability_Rogue_Sprint", "Travel time", "22%  (+4%)", "median 18%", false),
    stat("INV_Misc_Note_01", "Realm rank", "#212", "of 1,804 levelling now", "focal"),
  } },
  -- v6: second section (see OVERVIEW)
  { title = "This week", rows = {
    stat("Spell_Holy_SurgeOfLight", "XP per hour", "44,900  (+9%)", "best week so far", true),
    stat("Achievement_Level_10", "Levels gained", "3", "21 to 24"),
    stat("Spell_Nature_Sleep", "Downtime", "11%  (-3%)", "fewer rest stops", true),
    stat("Ability_Rogue_FeignDeath", "Deaths", "2  (+1)", "both to falling", false),
  } },
}

local function countRows(sections)
  local n = 0
  for _, s in ipairs(sections) do n = n + #s.rows end
  return n
end

-- A section page: Cinzel title + muted subtitle on one header line, a gold rule, the body, and a footer line.
-- Gaps (4/8 grid): head 4 from the top, rule 4 under it, body 8 under the rule; footer text 4 from the bottom, its
-- rule 4 above it, body 8 above that.
local function page(parent, title, subtitle)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)
  local k = UI.SiteTokens
  local head = f:CreateFontString(nil, "OVERLAY")
  if UI.Display then UI.Display(head, 15, true) else UI.SetFont(head, "title") end
  head:SetTextColor(UI.Unpack(k.gold))
  head:SetShadowOffset(1, -1)
  head:SetShadowColor(0, 0, 0, 0.85)
  head:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
  head:SetText(title)
  local sub = f:CreateFontString(nil, "OVERLAY")
  UI.SetFont(sub, "small")
  sub:SetTextColor(UI.Unpack(k.parch))
  sub:SetAlpha(0.8)
  sub:SetPoint("BOTTOMLEFT", head, "BOTTOMRIGHT", 8, 1) -- +1: baseline match against the 15 px heading
  sub:SetText(subtitle or "")
  local rule = f:CreateTexture(nil, "ARTWORK")
  rule:SetHeight(1)
  rule:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -24)
  rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -24)
  rule:SetColorTexture(k.goldDim[1], k.goldDim[2], k.goldDim[3], 0.8)
  local frule = f:CreateTexture(nil, "ARTWORK")
  frule:SetHeight(1)
  frule:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 20)
  frule:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 20)
  frule:SetColorTexture(1, 1, 1, 0.12)
  local foot = f:CreateFontString(nil, "OVERLAY")
  UI.SetFont(foot, "small")
  foot:SetTextColor(UI.Unpack(UI.Tokens.muted))
  foot:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 4, 4)
  local body = CreateFrame("Frame", nil, f)
  body:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -32)
  body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 28)
  f.head, f.sub, f.foot, f.body = head, sub, foot, body
  return f
end

-- Footer lines say what is on screen: when not every row fits, the count of rows on screen and "scroll for more".
local function footer(n, noun, shown)
  if shown and shown < n then return string.format("%d %s - %d shown, scroll for more", n, noun, shown) end
  return string.format("%d %s - updated just now", n, noun)
end
UI.ChromeDemoFooter = footer

-- The list uses the proportional thumb (thumbScrollbar), and its footer counts the rows the list actually laid out
-- (VisibleCount), refreshed by every list Refresh: scroll, resize and data stay in step with the thumb.
-- v7: `foot` = optional function(n, shown) -> footer text (the Finder says "12 duelists nearby").
local function listPage(parent, title, subtitle, columns, rows, selected, foot)
  local pg = page(parent, title, subtitle)
  local list
  local function update()
    if not list then return end
    local n, shown = #list:GetData(), list:VisibleCount()
    pg.foot:SetText(foot and foot(n, shown) or footer(n, "rows", shown))
  end
  list = UI.List(pg.body, { rowHeight = 24, headerHeight = 22, iconSize = 18, empty = "Nothing here",
    zebra = true, separators = true, selectable = true, selectedStrip = true, thumbScrollbar = true, columns = columns,
    onRefresh = update })
  list:SetAllPoints(pg.body)
  list:SetData(rows)
  if selected then list:SetSelected(selected) end
  update()
  pg.list, pg.updateFooter = list, update
  return pg
end

-- v7: stat sub-lines in a lighter parchment grey (#b9a98a) via StatRows o.subColor; the global muted token is untouched
local SUB_COLOR = { 0xb9 / 255, 0xa9 / 255, 0x8a / 255, 1 }
UI.ChromeDemoSubColor = SUB_COLOR
local function finderFooter(n, shown)
  if shown and shown < n then return string.format("%d duelists nearby - %d shown, scroll for more", n, shown) end
  return string.format("%d duelists nearby", n)
end
UI.ChromeDemoFinderFooter = finderFooter

local function statsPage(parent, title, subtitle, sections)
  local pg = page(parent, title, subtitle)
  -- v6: 28 px rows and a 110 px value column (90 cut "+184g 20s..." and "2m 10s  (-2...")
  local stats = UI.StatRows(pg.body, { rowHeight = 28, valueWidth = 110, subColor = SUB_COLOR })
  stats:SetAllPoints(pg.body)
  stats:SetSections(sections)
  local n = countRows(sections)
  local function update()
    local more = stats:MaxOffset() > 0
    pg.foot:SetText(more and string.format("%d stats - scroll for more", n) or footer(n, "stats"))
  end
  update()
  pcall(stats.HookScript, stats, "OnSizeChanged", update)
  pg.stats, pg.updateFooter = stats, update
  return pg
end

-- Sidebar summary block per tab (record / streak / best), so the sidebar never ends in empty stone.
local SUMMARY = {
  bloodsports = { { "Record", "41-17" }, { "Win rate", "70.7%", "good" }, { "Streak", "W5", "good" },
    { "Best streak", "9" }, { "Net purse", money(gold(361, 85), true), "gold" } },
  elders = { { "Level", "24", "gold" }, { "Played", "2d 4h" }, { "XP per hour", "41,200", "good" },
    { "Realm rank", "#212" } },
}
UI.ChromeDemoSummary = SUMMARY

-- Sidebar RECENT mini-list per tab: { left, result, "good" | "bad", right, "good" | "bad" | nil }. Bloodsports: the
-- last five duels (opponent, W / L, purse as g + s); Elders: the last five milestones.
-- v6: the purse is the compact demo money (copper dropped when 0), signed
local function shortMoney(copper) return money(copper, true) end
local RECENT = { bloodsports = {}, elders = {
  { "Level 24", "Up", "good", "2h ago" },
  { "Deadmines", "Clear", "good", "5h ago" },
  { "Fell to death", "Died", "bad", "6h ago" },
  { "Level 23", "Up", "good", "1d ago" },
  { "Mining 187", "+12", "good", "1d ago" },
} }
for i = 1, 5 do
  local d = DUELS[i]
  RECENT.bloodsports[i] = { d[3], d[5] and "W" or "L", d[5] and "good" or "bad", shortMoney(d[7]), d[7] >= 0 and "good" or "bad" }
end
UI.ChromeDemoRecent = RECENT

local RECENT_LINE, RECENT_HEAD = 18, 22
-- Builds the RECENT block into `parent` (the shell's extra host): a Cinzel "RECENT" heading in ink, a 1 px ink rule
-- and one row per entry (left label, result, right value), all in the shell's parchment ink (light text on flat).
local function recentExtra(tabId)
  return function(parent, shell)
    local k = UI.SiteTokens
    local ink = shell and shell.ink
    local function col(key)
      if ink then return ink[key] or k.ink end
      if key == "good" then return k.emerald elseif key == "bad" then return UI.Tokens.bad end
      return k.parch
    end
    local f = CreateFrame("Frame", nil, parent)
    f:SetAllPoints(parent)
    local head = f:CreateFontString(nil, "OVERLAY")
    if UI.Display then UI.Display(head, 12, true) else UI.SetFont(head, "body") end
    head:SetTextColor(UI.Unpack(ink and (ink.label or k.ink) or k.gold))
    head:SetShadowOffset(0, 0)
    head:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
    head:SetText("RECENT")
    local rule = f:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -RECENT_HEAD)
    rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -RECENT_HEAD)
    local rc = ink and (ink.rule or k.goldDeep) or k.goldDim
    rule:SetColorTexture(rc[1], rc[2], rc[3], rc[4] or 1)
    f.head, f.rule, f.rows = head, rule, {}
    for i, e in ipairs(RECENT[tabId] or {}) do
      local y = -(RECENT_HEAD + 4 + (i - 1) * RECENT_LINE)
      local function fs(justify)
        local t = f:CreateFontString(nil, "OVERLAY")
        UI.SetFont(t, "body")
        t:SetJustifyH(justify)
        t:SetWordWrap(false)
        if ink then t:SetShadowOffset(0, 0) else t:SetShadowOffset(1, -1); t:SetShadowColor(0, 0, 0, 1) end
        return t
      end
      local left, mid, right = fs("LEFT"), fs("CENTER"), fs("RIGHT")
      left:SetPoint("TOPLEFT", f, "TOPLEFT", 4, y)
      left:SetWidth(96)
      mid:SetPoint("TOPLEFT", f, "TOPLEFT", 100, y)
      mid:SetWidth(34)
      right:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, y)
      left:SetText(e[1]); mid:SetText(e[2]); right:SetText(e[4])
      left:SetTextColor(UI.Unpack(col("label")))
      mid:SetTextColor(UI.Unpack(col(e[3])))
      right:SetTextColor(UI.Unpack(e[5] and col(e[5]) or col("value")))
      f.rows[i] = { left = left, result = mid, right = right }
    end
    f.minHeight = RECENT_HEAD + 4 + #f.rows * RECENT_LINE
    return f
  end
end
UI.ChromeDemoRecentExtra = recentExtra

function UI.ChromeDemoData()
  local ring, clubs, duels, combat = {}, {}, {}, {}
  for i, r in ipairs(RING) do
    ring[i] = { rank = i, name = r[1], class = r[2], club = r[3], record = r[4] .. "-" .. r[5],
      streak = (r[6]:sub(1, 1) == "W" and GOOD or BAD) .. r[6] .. "|r", level = r[7], copper = r[8] }
  end
  for i, c in ipairs(CLUBS) do
    clubs[i] = { rank = i, name = c[1], venue = c[2], members = c[3], rating = c[4], copper = c[5], icon = icon(c[6]) }
  end
  for i, d in ipairs(DUELS) do
    duels[i] = { when = d[1], class = d[2], name = d[3], venue = d[4],
      result = d[5] and (GOOD .. "Won|r") or (BAD .. "Lost|r"), level = d[6], purse = signed(d[7]) }
  end
  for i, c in ipairs(COMBAT) do
    combat[i] = { name = c[1], icon = icon(c[2]), hits = c[3], crit = c[4] > 0 and string.format("%.1f%%", c[4]) or "-",
      avg = c[5], max = math.floor(c[5] * 1.85), miss = MISS[i] > 0 and string.format("%.1f%%", MISS[i]) or "-",
      dps = string.format("%.1f", c[6]), share = string.format("%.1f%%", c[7]) }
  end
  local finder = {}
  for i, d in ipairs(DUELISTS) do
    finder[i] = { name = d[1], class = d[2], className = "|cff" .. CLASS_HEX[d[2]] .. d[2]:sub(1, 1) .. d[2]:sub(2):lower()
      .. "|r", level = d[3], dist = d[4] .. " yd", note = d[5] }
  end
  return { ring = ring, clubs = clubs, duels = duels, combat = combat, season = SEASON, finder = finder,
    finderStats = FINDER, overview = OVERVIEW, pace = PACE }
end

-- "dialog" when the client has the dialog border, else "portrait" (the native template chain). v5: no longer the
-- demo default (UI.ChromeDemoDefaultChrome); kept for callers.
UI.ChromeDemoDefaultChrome = "portrait"
function UI.ChromeDemoBestChrome()
  local probe = type(UI.ShellProbe) == "function" and UI.ShellProbe() or {}
  return probe.dialogBorder and "dialog" or "portrait"
end

function UI.ChromeDemo(msg)
  if type(UI.Shell) ~= "function" then
    print("MetaKit: the Shell is not loaded.")
    return nil
  end
  local want, buttons = nil, false
  for word in tostring(msg or ""):lower():gmatch("%a+") do
    if UI.ShellChromeKinds and UI.ShellChromeKinds[word] then want = word
    elseif word == "buttons" then buttons = true end
  end
  local key = (want or "auto") .. (buttons and "+buttons" or "")
  for k2, other in pairs(chromes) do if k2 ~= key then other:Hide() end end
  local chrome = chromes[key]
  if not chrome then
    local data = UI.ChromeDemoData()
    local kind = want or UI.ChromeDemoDefaultChrome
    local name = key == "auto" and "MetaKitChromeDemo" or ("MetaKitChromeDemo_" .. key:gsub("%W", "_"))
    chromeDbs[key] = chromeDbs[key] or {}
    chrome = UI.Shell({ name = name, title = "World of Meta", db = chromeDbs[key], width = 960, height = 640,
      sidebarWidth = UI.ShellMetrics.compactSidebar,
      portrait = "Interface\\Icons\\INV_Misc_Book_09", footerText = "Sync now", footerVariant = "dark",
      chrome = kind, sidebar = "parchment", nativeButtons = buttons,
      -- v8 art: wordmark title, M medallion portrait, mirrored corner ornaments (each off when the art is missing)
      -- v9: 640 high (it8 Ring footer: 14 shown), bottom corners only, the gold-X plate close (native if it fails)
      ns = type(demoNs) == "table" and demoNs or nil, titleArt = true, portraitArt = true, corners = "bottom",
      closeStyle = "plate",
      -- v10: crests flank the wordmark (Bloodsports Media has no crest_elders: the right side falls to
      -- crest_tournament; either side hides when the loading addon's Media lacks it)
      flankArt = { left = "crest_bloodsports", right = { "crest_elders", "crest_tournament" } },
      summary = function(_, tabId) return SUMMARY[tabId] end,
      footerTooltip = { "Sync now", { "Reloads the UI so the uploader can pick up your data." } },
      onFooter = function() print("MetaKit demo: sync requested (the real addons reload the UI here).") end })
    chromes[key] = chrome
    chrome.demoData, chrome.demoLists, chrome.demoStatPages, chrome.demoPages = data, {}, {}, {}
    -- no owners: the demo shows both tabs whichever addons are loaded
    chrome:AddTab({ id = "bloodsports", label = "Bloodsports", order = 1, extra = recentExtra("bloodsports") })
    chrome:AddTab({ id = "elders", label = "Elders", order = 2, extra = recentExtra("elders") })

    local function listSection(tab, id, order, label, ic, subtitle, columns, rows, selected, foot)
      chrome:AddSection({ tab = tab, id = id, label = label, order = order, icon = icon(ic), build = function(parent)
        local pg = listPage(parent, label, subtitle, columns, rows, selected, foot)
        chrome.demoLists[id], chrome.demoPages[id] = pg.list, pg
        return pg
      end })
    end
    local function statSection(tab, id, order, label, ic, subtitle, sections)
      chrome:AddSection({ tab = tab, id = id, label = label, order = order, icon = icon(ic), build = function(parent)
        local pg = statsPage(parent, label, subtitle, sections)
        chrome.demoStatPages[id], chrome.demoPages[id] = pg.stats, pg
        if id == "stats" then chrome.demoStats = pg.stats end
        return pg
      end })
    end

    listSection("bloodsports", "ring", 1, "The Ring", "INV_Sword_04", "Duels, clubs and the ring", {
      { key = "rank", title = "#", width = 26 },
      { key = "class", title = "", width = 24, kind = "class" },
      { key = "name", title = "Name" },
      { key = "club", title = "Club" },
      { key = "record", title = "W-L", width = 52, align = "CENTER" },
      { key = "streak", title = "Streak", width = 48, align = "CENTER" },
      { key = "level", title = "Lvl", width = 34, align = "CENTER" },
      { key = "copper", title = "Purse", width = 96, kind = "money", align = "RIGHT", format = moneyCell },
    }, data.ring, 3)
    statSection("bloodsports", "stats", 2, "Season Stats", "INV_Misc_Note_01", "Season 3, week 6", data.season)
    listSection("bloodsports", "clubs", 3, "Clubs", "INV_BannerPVP_02", "Clubs fighting on this realm", {
      { key = "rank", title = "#", width = 26 },
      { key = "icon", title = "", width = 24, kind = "icon" },
      { key = "name", title = "Club" },
      { key = "venue", title = "Home venue" },
      { key = "members", title = "Members", width = 58, align = "CENTER" },
      { key = "rating", title = "Rating", width = 50, align = "CENTER" },
      -- v6: Treasury 96 -> 120 (+24, "2840g 00s 0..." was cut); Home venue is the flexible column and gives it up
      { key = "copper", title = "Treasury", width = 120, kind = "money", align = "RIGHT", format = moneyCell },
    }, data.clubs, 1)
    -- v7: a list of nearby duelists (zebra + selected strip), footer "12 duelists nearby"
    listSection("bloodsports", "finder", 4, "Finder", "Ability_Hunter_SniperShot", "Who wants a duel nearby", {
      { key = "class", title = "", width = 24, kind = "class" },
      { key = "name", title = "Name" },
      { key = "className", title = "Class", width = 72 },
      { key = "level", title = "Lvl", width = 34, align = "CENTER" },
      { key = "dist", title = "Dist", width = 52, align = "RIGHT" },
      { key = "note", title = "Note" },
    }, data.finder, 2, finderFooter)
    listSection("bloodsports", "duels", 5, "My Duels", "Ability_DualWield", "Your last 16 duels", {
      { key = "when", title = "Date", width = 50 },
      { key = "class", title = "", width = 24, kind = "class" },
      { key = "name", title = "Opponent" },
      { key = "venue", title = "Venue" },
      { key = "result", title = "Result", width = 50, align = "CENTER" },
      { key = "level", title = "Lvl", width = 34, align = "CENTER" },
      { key = "purse", title = "Purse", width = 96, align = "RIGHT" },
    }, data.duels, 2)

    statSection("elders", "overview", 1, "Overview", "INV_Misc_Book_09", "Your character at a glance", data.overview)
    statSection("elders", "pace", 2, "Pace", "Spell_Holy_BorrowedTime", "Levelling speed against the realm", data.pace)
    listSection("elders", "combat", 3, "Combat", "Ability_Warrior_SavageBlow", "Damage by ability, last 30 days", {
      { key = "icon", title = "", width = 24, kind = "icon" },
      { key = "name", title = "Ability" },
      { key = "hits", title = "Hits", width = 50, align = "CENTER" },
      { key = "crit", title = "Crit", width = 50, align = "CENTER" },
      { key = "miss", title = "Miss", width = 50, align = "CENTER" },
      { key = "avg", title = "Avg hit", width = 56, align = "RIGHT" },
      { key = "max", title = "Max hit", width = 56, align = "RIGHT" },
      { key = "dps", title = "DPS", width = 56, align = "RIGHT" },
      { key = "share", title = "Share", width = 56, align = "RIGHT" },
    }, data.combat, 1)
    chrome:Select("bloodsports", "ring") -- the first view is The Ring, filled
  end
  chrome:Show()
  chrome:Select(chrome.current or "bloodsports")
  chrome.demoList = chrome.demoLists.ring
  return chrome
end

if type(SlashCmdList) == "table" and not SlashCmdList.METAKITCHROME then
  SLASH_METAKITCHROME1 = "/mkchrome"
  SlashCmdList.METAKITCHROME = function(msg) UI.ChromeDemo(msg) end
end
