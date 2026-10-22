-- Hidden custom channel used for discovery ("who is looking for a duel/club/ring/referee"). Never required:
-- if the channel cannot be joined everything else keeps working and the list stays empty.
-- CONTRACT NOTE: lobby:Start() is called by New; lobby:SendTo(name, msgType, fields) whispers via comm;
-- entries also accept LA whispers (query replies). lobby:IsJoined() / lobby.channelNumber expose state.

if MetaKit_SkipLoad then return end
local MK = MetaKit

local EXPIRY, REANNOUNCE, REPLY_COOLDOWN, MAX_ENTRIES = 180, 60, 30, 500
local MAX_ATTEMPTS = 4

local Lobby = {}
Lobby.__index = Lobby
MK.Lobby = { Methods = Lobby }

function MK.Lobby.New(comm, opts)
  opts = opts or {}
  local A = comm.A
  local self = setmetatable({
    comm = comm, A = A, channel = opts.channel or "WoMLobby", entries = {}, gen = 0, attempt = 0,
    lastReply = {},
  }, Lobby)
  local v = C_AddOns and C_AddOns.GetAddOnMetadata and MK.Call(C_AddOns.GetAddOnMetadata, A.name, "Version")
  self.version = opts.version or v or ""
  comm:On("LA", function(sender, f, ch) self:OnAnnounce(sender, f, ch) end)
  comm:On("LX", function(sender) self:OnRemove(sender) end)
  comm:On("LQ", function(sender, f) self:OnQuery(sender, f) end)
  self.expiry = A:Every(15, function() self:Purge() end)
  self:Start()
  return self
end

---------------------------------------------------------------------------
-- Channel join

function Lobby:ChannelNumber()
  local n = tonumber((MK.Call(GetChannelName, self.channel)))
  if n and n > 0 then return n end
end

function Lobby:IsJoined() return self.joined and self:ChannelNumber() ~= nil end

function Lobby:Start()
  if self.started then return end
  self.started = true
  self.A:On("PLAYER_ENTERING_WORLD", function() self:Schedule(5, true) end)
end

function Lobby:Schedule(delay, reset)
  if reset then self.attempt = 0 end
  self.gen = self.gen + 1
  local gen = self.gen
  self.A:After(delay, function() if gen == self.gen then self:TryJoin() end end)
end

local function hideFromChat(channel)
  local remove = ChatFrame_RemoveChannel or (ChatFrameUtil and ChatFrameUtil.RemoveChannel)
  if not remove then return end
  for i = 1, NUM_CHAT_WINDOWS or 10 do
    local frame = _G["ChatFrame" .. i]
    if frame then pcall(remove, frame, channel) end
  end
end

function Lobby:OnJoined()
  local first = not self.joined
  self.joined = true
  hideFromChat(self.channel)
  if first then
    self.A:Debug("lobby joined channel " .. tostring(self:ChannelNumber()))
    if self.mine then self:SendAnnounce() end
  end
end

function Lobby:TryJoin()
  if self:ChannelNumber() then return self:OnJoined() end
  self.joined = false
  if MK.InstanceState() or MK.ChatLocked() then return self:Schedule(30) end
  if self.attempt >= MAX_ATTEMPTS then
    self.failed = true
    return
  end
  self.attempt = self.attempt + 1
  pcall(securecall, JoinChannelByName, self.channel)
  local attempt = self.attempt
  self.A:After(2, function()
    if self:ChannelNumber() then self:OnJoined() else self:Schedule(5 * 2 ^ (attempt - 1)) end
  end)
end

---------------------------------------------------------------------------
-- Sending

function Lobby:SendTo(name, msgType, fields)
  return self.comm:Send(msgType, fields, "WHISPER", name)
end

function Lobby:ToChannel(msgType, fields)
  local n = self:ChannelNumber()
  if not n then return false end
  return self.comm:Send(msgType, fields, "CHANNEL", n)
end

function Lobby:AnnounceFields()
  local m = self.mine
  local info = MK.UnitInfo("player") or {}
  return {
    m.kind or "duel", m.venue or "", info.class or "", info.level or "", info.faction or "",
    m.streak or "", m.rating or "", MK.Util.Truncate(MK.Comm.Clean(m.note), 60), self.version,
  }
end

function Lobby:SendAnnounce()
  if not self.mine then return false end
  return self:ToChannel("LA", self:AnnounceFields())
end

-- entry = { kind, venue, note, streak, rating }. Re-announces every 60 s until Unlist.
function Lobby:Announce(entry)
  self.mine = MK.Util.Copy(entry or {})
  if not self.ticker then
    self.ticker = self.A:Every(REANNOUNCE, function() self:SendAnnounce() end)
  end
  return self:SendAnnounce()
end

function Lobby:Unlist()
  if self.ticker then self.ticker:Cancel(); self.ticker = nil end
  if not self.mine then return false end
  self.mine = nil
  return self:ToChannel("LX", {})
end

function Lobby:Query(kind, venue)
  return self:ToChannel("LQ", { kind or "", venue or "" })
end

---------------------------------------------------------------------------
-- Receiving

function Lobby:OnAnnounce(sender, f, channel)
  if channel ~= "CHANNEL" and channel ~= "WHISPER" then return end
  local kind = f[1]
  if not kind or kind == "" or #kind > 12 then return end
  if not self.entries[sender] then
    local n = 0
    for _ in pairs(self.entries) do n = n + 1 end
    if n >= MAX_ENTRIES then return end
  end
  self.entries[sender] = {
    name = sender, kind = kind, venue = f[2] or "", class = f[3] or "", level = tonumber(f[4]),
    faction = f[5] or "", streak = tonumber(f[6]), rating = tonumber(f[7]),
    note = MK.Util.Truncate(f[8] or "", 60), version = f[9] or "", seen = GetTime(),
  }
  self.A:Fire("LOBBY_UPDATED")
end

function Lobby:OnRemove(sender)
  if self.entries[sender] then
    self.entries[sender] = nil
    self.A:Fire("LOBBY_UPDATED")
  end
end

function Lobby:OnQuery(sender, f)
  local m = self.mine
  if not m then return end
  if f[1] and f[1] ~= "" and f[1] ~= m.kind then return end
  if f[2] and f[2] ~= "" and f[2] ~= (m.venue or "") then return end
  local now = GetTime()
  local last = self.lastReply[sender]
  if last and now - last < REPLY_COOLDOWN then return end
  self.lastReply[sender] = now
  self.A:After(math.random() * 3, function()
    if self.mine then self:SendTo(sender, "LA", self:AnnounceFields()) end
  end)
end

function Lobby:Purge()
  local now, removed = GetTime(), false
  for name, e in pairs(self.entries) do
    if now - e.seen > EXPIRY then self.entries[name] = nil; removed = true end
  end
  for name, t in pairs(self.lastReply) do
    if now - t >= REPLY_COOLDOWN then self.lastReply[name] = nil end
  end
  if removed then self.A:Fire("LOBBY_UPDATED") end
end

-- Entries newest first, optionally filtered by filterFn(entry).
function Lobby:List(filterFn)
  self:Purge()
  local out = {}
  for _, e in pairs(self.entries) do
    if not filterFn or filterFn(e) then out[#out + 1] = e end
  end
  table.sort(out, function(a, b)
    if a.seen ~= b.seen then return a.seen > b.seen end
    return a.name < b.name
  end)
  return out
end
