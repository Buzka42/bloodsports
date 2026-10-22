-- Tooltip hook: champion badges and my record against a player unit. Every unit read goes through MK.Call.

local ADDON, ns = ...
local MK = MetaKit
local A = ns.A
local UI = ns.UI
local M = A:NewModule("UITooltip")

local function badgesFor(name, realm)
  if not MK.Wom then return nil end
  local keys = { realm and (name .. "-" .. realm) or MK.FullName(name), name }
  for _, key in ipairs(keys) do
    local b = UI.Try(MK.Wom, "bloodsports", "badges", key)
    if b then
      if type(b) == "string" then return b end
      if type(b) == "table" then
        local parts = {}
        for _, v in ipairs(b) do parts[#parts + 1] = type(v) == "table" and (v.label or v.name or v.id) or tostring(v) end
        if #parts > 0 then return table.concat(parts, ", ") end
      end
    end
  end
end

local function onUnit(tooltip)
  if tooltip ~= GameTooltip or not tooltip.GetUnit then return end
  local _, unit = MK.Call(tooltip.GetUnit, tooltip)
  if type(unit) ~= "string" then return end
  if not MK.Call(UnitIsPlayer, unit) then return end
  local name, realm = MK.Call(UnitName, unit)
  if type(name) ~= "string" then return end
  if realm == "" then realm = nil end
  local added = false
  local badges = badgesFor(name, realm)
  if badges then
    tooltip:AddLine("|cffd1381fBloodsports:|r " .. badges)
    added = true
  end
  local w, l = UI.RecordVs(realm and (name .. "-" .. realm) or name)
  if w + l > 0 then
    tooltip:AddLine("Your duels vs them: |cffffd100" .. w .. "-" .. l .. "|r")
    added = true
  end
  if added and tooltip.Show then tooltip:Show() end
end

function M:OnLogin()
  local tdp = TooltipDataProcessor
  local unitType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit
  if tdp and tdp.AddTooltipPostCall and unitType then
    tdp.AddTooltipPostCall(unitType, function(tooltip) onUnit(tooltip) end)
  elseif GameTooltip and GameTooltip.HookScript then
    GameTooltip:HookScript("OnTooltipSetUnit", function(tooltip) onUnit(tooltip) end)
  end
end
