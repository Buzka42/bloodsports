-- Addon object: lifecycle, modules, events, internal messages, timers, printing, slash commands.
--
--   local A = MetaKit.NewAddon("Elders", { color = "3fbf6a" })
--   local M = A:NewModule("Pace")
--   function M:OnInit(db) end      -- ADDON_LOADED, after A.db exists (A:InitDB must be called in A.OnInit)
--   function M:OnLogin() end       -- PLAYER_LOGIN
--   A:On("PLAYER_XP_UPDATE", function(event, unit) end)
--   A:Listen("LEVEL_UP", function(level) end); A:Fire("LEVEL_UP", 12)
--
-- Every handler runs in pcall; failures are reported once per handler via A:Error.

if MetaKit_SkipLoad then return end
local MK = MetaKit

local Addon = {}
Addon.__index = Addon
MK.AddonMethods = Addon

function MK.NewAddon(name, opts)
  opts = opts or {}
  local A = setmetatable({
    name = name, color = opts.color or "ffd100", modules = {}, moduleList = {},
    handlers = {}, unitHandlers = {}, listeners = {}, errors = {}, commands = {},
  }, Addon)
  A.frame = CreateFrame("Frame")
  A.frame:SetScript("OnEvent", function(_, event, ...) A:Dispatch(event, ...) end)
  A.frame:RegisterEvent("ADDON_LOADED")
  A.frame:RegisterEvent("PLAYER_LOGIN")
  MK.addons[name] = A
  return A
end

function Addon:Print(msg)
  print("|cff" .. self.color .. self.name .. "|r " .. tostring(msg))
end

function Addon:Debug(msg)
  if self.db and self.db.config and self.db.config.debug then
    self:Print("|cff888888[debug]|r " .. tostring(msg))
  end
end

function Addon:Error(where, err)
  local key = where .. tostring(err)
  if self.errors[key] then return end
  self.errors[key] = true
  self:Print("|cffff4040error in " .. where .. ":|r " .. tostring(err))
end

local function run(A, where, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then A:Error(where, err) end
  return ok
end

---------------------------------------------------------------------------
-- Modules

function Addon:NewModule(name)
  local M = { name = name, addon = self }
  self.modules[name] = M
  table.insert(self.moduleList, M)
  return M
end

function Addon:GetModule(name)
  return self.modules[name]
end

---------------------------------------------------------------------------
-- Events (WoW) — several handlers per event, registered lazily.

function Addon:On(event, handler)
  local list = self.handlers[event]
  if not list then
    if event ~= "ADDON_LOADED" and event ~= "PLAYER_LOGIN" then
      local ok = pcall(self.frame.RegisterEvent, self.frame, event)
      if not ok then
        self:Debug("event not available: " .. event)
        return false
      end
    end
    list = {}
    self.handlers[event] = list
  end
  table.insert(list, handler)
  return true
end

function Addon:Off(event, handler)
  local list = self.handlers[event]
  if not list then return end
  for i = #list, 1, -1 do
    if list[i] == handler then table.remove(list, i) end
  end
  if #list == 0 and event ~= "ADDON_LOADED" and event ~= "PLAYER_LOGIN" then
    self.handlers[event] = nil
    pcall(self.frame.UnregisterEvent, self.frame, event)
  end
end

-- Unit-filtered event (e.g. UNIT_AURA for "player") on its own frame.
function Addon:OnUnit(event, unit, handler)
  local f = CreateFrame("Frame")
  local ok = pcall(f.RegisterUnitEvent, f, event, unit)
  if not ok then return false end
  f:SetScript("OnEvent", function(_, ev, ...) run(self, ev, handler, ev, ...) end)
  table.insert(self.unitHandlers, f)
  return f
end

function Addon:Dispatch(event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= self.name then return end
    self.loaded = true
    if self.OnInit then run(self, "OnInit", self.OnInit, self) end
    for _, M in ipairs(self.moduleList) do
      if M.OnInit then run(self, M.name .. ".OnInit", M.OnInit, M, self.db) end
    end
  elseif event == "PLAYER_LOGIN" then
    if self.OnLogin then run(self, "OnLogin", self.OnLogin, self) end
    for _, M in ipairs(self.moduleList) do
      if M.OnLogin then run(self, M.name .. ".OnLogin", M.OnLogin, M) end
    end
    self.ready = true
  end
  local list = self.handlers[event]
  if not list then return end
  for i = 1, #list do
    run(self, event, list[i], event, ...)
  end
end

---------------------------------------------------------------------------
-- Internal messages between modules

function Addon:Listen(msg, fn)
  self.listeners[msg] = self.listeners[msg] or {}
  table.insert(self.listeners[msg], fn)
end

function Addon:Fire(msg, ...)
  local list = self.listeners[msg]
  if not list then return end
  for i = 1, #list do run(self, "msg " .. msg, list[i], ...) end
end

---------------------------------------------------------------------------
-- Timers

function Addon:After(sec, fn)
  C_Timer.After(sec, function() run(self, "timer", fn) end)
end

function Addon:Every(sec, fn)
  return C_Timer.NewTicker(sec, function() run(self, "ticker", fn) end)
end

-- Runs fn once, `delay` seconds after the last call with the same key.
function Addon:Debounce(key, delay, fn)
  self.debounce = self.debounce or {}
  local token = {}
  self.debounce[key] = token
  C_Timer.After(delay, function()
    if self.debounce[key] == token then
      self.debounce[key] = nil
      run(self, "debounce " .. key, fn)
    end
  end)
end

---------------------------------------------------------------------------
-- Slash commands: A:Slash({"/elders", "/eld"}); A:Command("link", "link CODE - bind to site account", fn)

function Addon:Slash(aliases)
  local id = self.name:upper()
  for i, alias in ipairs(aliases) do _G["SLASH_" .. id .. i] = alias end
  SlashCmdList[id] = function(msg)
    local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()
    local entry = self.commands[cmd]
    if entry then
      run(self, "/" .. cmd, entry.fn, rest)
    else
      self:Print("commands:")
      for name, e in pairs(self.commands) do
        if name ~= "" then print("  /" .. aliases[1]:sub(2) .. " " .. e.help) end
      end
    end
  end
end

function Addon:Command(name, help, fn)
  self.commands[name] = { help = help, fn = fn }
end
