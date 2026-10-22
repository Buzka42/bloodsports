-- Toasts: victory / defeat banner on DUEL_RESOLVED, confirmation note on DUEL_CONFIRMED.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI
local M = A:NewModule("UIToasts")

local HOW = { knockout = "knockout", retreat = "retreat", yield = "yield" }

local function toast(opts)
  local k = MK.UI
  if not (k and k.Toast) or A.db.config.toasts == false then return end
  opts.skin = UI.SKIN
  UI.Try(k.Toast, opts)
end

local function resolved(rec)
  if type(rec) ~= "table" then return end
  local opp = rec.opp or {}
  local who = (opp.name and UI.Short(opp.name) or "your opponent") .. (opp.level and (" (" .. opp.level .. ")") or "")
  local how = HOW[rec.how] and (" by " .. HOW[rec.how]) or ""
  local title, banner = "No contest", nil
  if rec.result == "win" then title, banner = "Victory!", "good"
  elseif rec.result == "loss" then title, banner = "Defeat", "bad" end
  local streak = ns.char and ns.char.streak and ns.char.streak.cur or 0
  local text = (rec.result == "void") and ("Duel with " .. who .. " did not count.") or ("vs " .. who .. how)
  if rec.result == "win" and streak >= 2 then text = text .. " - streak " .. streak end
  toast({ title = title, text = text, icon = UI.Crest(rec.venue), banner = banner, duration = 5 })
end

local function confirmed(rec)
  if type(rec) ~= "table" then return end
  local text
  if rec.confirmed == "both" then text = "Confirmed by both fighters."
  elseif rec.confirmed == "referee" then text = "Verdict confirmed by referee " .. UI.Short(rec.referee) .. "."
  elseif rec.confirmed == "disputed" then text = "Result disputed. It will not count toward streaks." end
  if text then toast({ title = rec.confirmed == "disputed" and "Disputed" or "Sealed", text = text, icon = UI.Crest(rec.venue), duration = 4 }) end
end

function M:OnLogin()
  A:Listen("DUEL_RESOLVED", resolved)
  A:Listen("DUEL_CONFIRMED", confirmed)
end
