-- Addon-message transport: tab-separated wire format, token-bucket send queue, flood guard, lockdown refusal.
-- CONTRACT NOTE: handlers get a 4th arg `info` = { target, localID, name } (channel details of CHAT_MSG_ADDON).
-- comm.A is the owning addon. Send cleans every field with Comm.Clean.

if MetaKit_SkipLoad then return end
local MK = MetaKit

local BURST, REFILL = 8, 1          -- bucket size, tokens per second
local WHISPER_PER_SEC = 4
local MAX_QUEUE = 100
local FLOOD_COUNT, FLOOD_WINDOW, FLOOD_BAN = 30, 10, 120

local Comm = {}
Comm.__index = Comm
MK.Comm = { Methods = Comm }

-- Strips tabs, newlines and pipes (chat escape char) from user text.
function MK.Comm.Clean(s)
  return (tostring(s == nil and "" or s):gsub("[\t\r\n|]", ""))
end
local clean = MK.Comm.Clean

function MK.Comm.New(A, prefix)
  local self = setmetatable({
    A = A, prefix = prefix, handlers = {}, queue = {}, tokens = BURST, last = GetTime(),
    wtimes = {}, senders = {}, nSenders = 0,
  }, Comm)
  pcall(C_ChatInfo.RegisterAddonMessagePrefix, prefix)
  A:On("CHAT_MSG_ADDON", function(_, ...) self:OnAddon(...) end)
  return self
end

function Comm:On(msgType, fn)
  local list = self.handlers[msgType]
  if not list then list = {}; self.handlers[msgType] = list end
  list[#list + 1] = fn
end

function Comm:Off(msgType, fn)
  local list = self.handlers[msgType]
  if not list then return end
  for i = #list, 1, -1 do if list[i] == fn then table.remove(list, i) end end
end

---------------------------------------------------------------------------
-- Sending

local function build(msgType, fields)
  local parts = { clean(msgType) }
  for i = 1, fields and #fields or 0 do parts[#parts + 1] = clean(fields[i]) end
  return table.concat(parts, "\t")
end

local function report(self, code, item)
  if self.onResult and code ~= 0 then pcall(self.onResult, code, item.msgType, item.target) end
end

local function sendNow(self, item)
  if MK.ChatLocked() then return report(self, Enum.SendAddonMessageResult.AddOnMessageLockdown, item) end
  local target = item.channel == "CHANNEL" and tonumber(item.target) or item.target
  local fn = C_ChatInfo.SendAddonMessage
  local ok, res = pcall(securecall, fn, self.prefix, item.msg, item.channel, target)
  local code = 0
  if not ok then code = -2
  elseif type(res) == "number" then code = res
  elseif res == false then code = -1 end
  report(self, code, item)
end

-- Sends queued items the bucket / whisper window allows; keeps the ticker alive while work remains.
function Comm:Drain()
  local now = GetTime()
  self.tokens = math.min(BURST, self.tokens + (now - self.last) * REFILL)
  self.last = now
  local inInstance = MK.InstanceState()
  local wt = self.wtimes
  while #wt > 0 and now - wt[1] >= 1 do table.remove(wt, 1) end
  while #self.queue > 0 do
    local item = self.queue[1]
    local direct = item.channel == "WHISPER" and not inInstance
    if direct then
      if #wt >= WHISPER_PER_SEC then break end
      wt[#wt + 1] = now
    else
      if self.tokens < 1 then break end
      self.tokens = self.tokens - 1
    end
    table.remove(self.queue, 1)
    sendNow(self, item)
  end
  if #self.queue > 0 then
    if not self.ticker then self.ticker = self.A:Every(0.25, function() self:Drain() end) end
  elseif self.ticker then
    self.ticker:Cancel()
    self.ticker = nil
  end
end

-- Queues a message. Returns false when refused (lockdown, too long, queue full, bad channel).
function Comm:Send(msgType, fields, channel, target)
  if not channel or MK.ChatLocked() then return false end
  if channel == "WHISPER" and (not target or target == "") then return false end
  local msg = build(msgType, fields)
  if #msg > 255 then return false end
  if #self.queue >= MAX_QUEUE then return false end
  self.queue[#self.queue + 1] = { msg = msg, msgType = msgType, channel = channel, target = target }
  self:Drain()
  return true
end

function Comm:Broadcast(msgType, fields)
  local channel = (IsInRaid() and "RAID") or (IsInGroup() and "PARTY") or nil
  if not channel then return false end
  return self:Send(msgType, fields, channel)
end

---------------------------------------------------------------------------
-- Receiving

local function split(s)
  local out, start = {}, 1
  while true do
    local i = s:find("\t", start, true)
    if not i then out[#out + 1] = s:sub(start); break end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
  return out
end

-- True when this sender is (or just became) flood-banned.
local function flooded(self, sender, now)
  local s = self.senders[sender]
  if not s then
    if self.nSenders > 300 then self.senders, self.nSenders = {}, 0 end
    s = { start = now, n = 0, ban = 0 }
    self.senders[sender] = s
    self.nSenders = self.nSenders + 1
  end
  if now < s.ban then return true end
  if now - s.start > FLOOD_WINDOW then s.start, s.n = now, 0 end
  s.n = s.n + 1
  if s.n > FLOOD_COUNT then
    s.ban = now + FLOOD_BAN
    return true
  end
  return false
end

function Comm:OnAddon(prefix, text, channel, sender, target, zoneID, localID, chName)
  if MK.IsSecret(prefix) or MK.IsSecret(text) or MK.IsSecret(sender) or MK.IsSecret(channel) then return end
  if prefix ~= self.prefix or type(text) ~= "string" or type(sender) ~= "string" then return end
  sender = MK.FullName(sender)
  if not sender or sender == MK.PlayerKey() then return end
  if flooded(self, sender, GetTime()) then return end
  local fields = split(text)
  local msgType = table.remove(fields, 1)
  local list = self.handlers[msgType]
  if not list then return end
  local info = { target = target, localID = localID, name = chName }
  for i = 1, #list do
    local ok, err = pcall(list[i], sender, fields, channel, info)
    if not ok then self.A:Error("comm " .. tostring(msgType), err) end
  end
end
