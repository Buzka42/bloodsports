-- Ledger.lua: confirmed trade recording and Ring trade matching (contract §6).
-- The addon records gold only; it never accepts, moves, or creates money.
local _, ns = ...
local MK = MetaKit
local U = MK.Util
local A = ns.A

local L = A:NewModule("Ledger")
ns.Ledger = L

local MAX_TRADES, MAX_UNMATCHED = 200, 50
local current, lastMoney

local function sameName(a, b)
  if type(a) ~= "string" or type(b) ~= "string" then return false end
  return MK.FullName(a):lower() == MK.FullName(b):lower()
end

local function unmatched()
  return ns.char and ns.char.ring and ns.char.ring.unmatched or nil
end

local function storeUnmatched(row)
  local list = unmatched()
  if not list then return end
  table.insert(list, row)
  while #list > MAX_UNMATCHED do table.remove(list, 1) end
end

local function money(fn)
  local value = MK.Call(fn)
  return type(value) == "number" and value or nil
end

local function readAmounts(tr)
  tr.got = money(GetTargetTradeMoney)
  tr.gave = money(GetPlayerTradeMoney)
end

local function finalize(tr)
  if current == tr then current = nil end
  if type(tr.got) ~= "number" or type(tr.gave) ~= "number" then return end
  if tr.got == 0 and tr.gave == 0 then return end
  if not ns.char or not ns.char.trades then return end

  tr.t = U.ServerTime()
  tr.confirmed = tr.delta == tr.got - tr.gave
  tr.matched = {}
  if tr.confirmed and ns.Ring and ns.Ring.MatchTrade then ns.Ring.MatchTrade(tr) end

  local row = {
    t = tr.t, partner = tr.partner, got = tr.got, gave = tr.gave, confirmed = tr.confirmed,
    sid = tr.sid, kind = tr.kind, matched = tr.matched, reason = tr.reason, excess = tr.excess,
    ring = tr.sid, -- v1 SavedVariables/UI compatibility; sid is the v2 field.
  }
  table.insert(ns.char.trades, row)
  while #ns.char.trades > MAX_TRADES do table.remove(ns.char.trades, 1) end
  if row.reason then storeUnmatched(row) end
end

local function amountPart(text, globalName)
  local compiled = MK.Pattern(globalName)
  if not compiled then return nil end
  local pattern = compiled.pattern:gsub("^%^", ""):gsub("%$$", "")
  local value = text:match(pattern)
  value = value and tonumber((value:gsub("[^%d%-]", "")))
  return value
end

local function lootAmount(text)
  text = MK.Safe(text)
  if type(text) ~= "string" then return nil end
  local amount
  for _, name in ipairs({ "YOU_LOOT_MONEY", "YOU_LOOT_MONEY_MOD", "YOU_LOOT_MONEY_GUILD", "LOOT_MONEY_SPLIT" }) do
    amount = MK.Match(name, text)
    if type(amount) == "string" then break end
  end
  if type(amount) ~= "string" then return nil end
  local gold = amountPart(amount, "GOLD_AMOUNT")
  local silver = amountPart(amount, "SILVER_AMOUNT")
  local copper = amountPart(amount, "COPPER_AMOUNT")
  if not (gold or silver or copper) then return nil end
  return (gold or 0) * 10000 + (silver or 0) * 100 + (copper or 0)
end

A:On("CHAT_MSG_MONEY", function(_, text)
  if not current then return end -- loot is a trade-window correction, never independent evidence
  local amount = lootAmount(text)
  if amount then current.delta = current.delta - amount end
end)

A:On("TRADE_SHOW", function()
  local info = MK.UnitInfo("npc")
  local name = info and info.name
  local partner = name and ((info.realm and info.realm ~= "") and (name .. "-" .. info.realm) or MK.FullName(name))
  lastMoney = money(GetMoney) or lastMoney
  current = { partner = partner, delta = 0 }
end)

A:On("TRADE_MONEY_CHANGED", function()
  if current then readAmounts(current) end
end)

A:On("TRADE_ACCEPT_UPDATE", function(_, playerAccepted, targetAccepted)
  if not current then return end
  if (playerAccepted == 1 or playerAccepted == true) and (targetAccepted == 1 or targetAccepted == true) then
    current.both = true
    readAmounts(current)
  else
    current.both = false
  end
end)

A:On("TRADE_CLOSED", function()
  local tr = current
  if not tr then return end
  if tr.both and tr.partner then
    A:After(1, function() finalize(tr) end)
  else
    current = nil
  end
end)

A:On("PLAYER_MONEY", function()
  local value = money(GetMoney)
  if type(value) ~= "number" then return end
  if current and lastMoney then current.delta = current.delta + (value - lastMoney) end
  lastMoney = value
end)

function L.Unmatched()
  return unmatched() or {}
end

-- Re-tries only incoming stake trades for this partner. Ring enforces the 120 s pre-window and market state.
function L.Retry(bettor)
  local list = unmatched()
  if not list or not ns.Ring or not ns.Ring.MatchTrade then return end
  for i = #list, 1, -1 do
    local tr = list[i]
    if tr.confirmed and tr.got > 0 and tr.gave == 0 and sameName(tr.partner, bettor) then
      tr.reason = nil
      ns.Ring.MatchTrade(tr)
      if #tr.matched > 0 and not tr.reason then table.remove(list, i) end
    end
  end
end

-- Manual escape hatch for the host's Unmatched list. Ring validates the target and writes manual=true rows.
function L.Assign(which, sid, mid, bettor)
  local list = unmatched()
  if not list or not ns.Ring or not ns.Ring.AssignTrade then return false end
  local index = type(which) == "number" and which or nil
  local tr = type(which) == "table" and which or list[index]
  if not tr then return false end
  if not index then
    for i, row in ipairs(list) do if row == tr then index = i break end end
  end
  if not index or not ns.Ring.AssignTrade(tr, sid, mid, bettor) then return false end
  table.remove(list, index)
  return true
end

function L:OnLogin()
  lastMoney = money(GetMoney)
end
