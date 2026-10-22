-- Pure statistics over duel record arrays (char.duels), no state, no WoW API. Rates are fractions 0..1.
--
-- CONTRACT NOTE: Summary.n counts every record incl. voids; winRate = wins / (wins + losses), 0 when none decided.
--   firstBloodRate = share of decided duels (with firstBlood known) where the OPPONENT bled first. Disputed records are
--   excluded from bestStreak. Matchups/ByVenue/ByClassDuration only count decided (win/loss) duels.

local _, ns = ...

local S = {}
ns.Stats = S

local function decided(d) return d.result == "win" or d.result == "loss" end

function S.Summary(duels)
  local s = { n = 0, wins = 0, losses = 0, voids = 0, winRate = 0, avgDur = 0, firstBloodRate = 0, comebacks = 0, bestStreak = 0 }
  local durSum, durN, fbN, fbGood, run = 0, 0, 0, 0, 0
  for _, d in ipairs(duels or {}) do
    s.n = s.n + 1
    if d.result == "win" then s.wins = s.wins + 1
    elseif d.result == "loss" then s.losses = s.losses + 1
    else s.voids = s.voids + 1 end
    if decided(d) then
      if type(d.dur) == "number" and d.dur > 0 then durSum, durN = durSum + d.dur, durN + 1 end
      if d.firstBlood then
        fbN = fbN + 1
        if d.firstBlood == "opp" then fbGood = fbGood + 1 end
      end
      if d.comeback then s.comebacks = s.comebacks + 1 end
      if d.confirmed ~= "disputed" then
        if d.result == "win" then
          run = run + 1
          if run > s.bestStreak then s.bestStreak = run end
        else
          run = 0
        end
      end
    end
  end
  local dec = s.wins + s.losses
  if dec > 0 then s.winRate = s.wins / dec end
  if durN > 0 then s.avgDur = durSum / durN end
  if fbN > 0 then s.firstBloodRate = fbGood / fbN end
  return s
end

local function group(duels, keyFn)
  local out = {}
  for _, d in ipairs(duels or {}) do
    if decided(d) then
      local k = keyFn(d)
      local g = out[k]
      if not g then g = { n = 0, wins = 0, losses = 0, winRate = 0, durSum = 0, durN = 0 } out[k] = g end
      g.n = g.n + 1
      if d.result == "win" then g.wins = g.wins + 1 else g.losses = g.losses + 1 end
      if type(d.dur) == "number" and d.dur > 0 then g.durSum, g.durN = g.durSum + d.dur, g.durN + 1 end
    end
  end
  for _, g in pairs(out) do
    g.winRate = g.wins / g.n
    g.avgDur = g.durN > 0 and g.durSum / g.durN or 0
    g.durSum, g.durN = nil, nil
  end
  return out
end

function S.Matchups(duels)
  return group(duels, function(d) return d.opp and d.opp.class or "UNKNOWN" end)
end

function S.ByVenue(duels)
  return group(duels, function(d) return d.venue or "none" end)
end

function S.ByClassDuration(duels)
  local out = {}
  for class, g in pairs(S.Matchups(duels)) do out[class] = g.avgDur end
  return out
end

-- filter: { venueKind, confirmedOnly (both/referee), since (server time), oppClass }
function S.Filter(duels, filter)
  filter = filter or {}
  local out = {}
  for _, d in ipairs(duels or {}) do
    local ok = true
    if filter.venueKind and d.venueKind ~= filter.venueKind then ok = false end
    if filter.confirmedOnly and d.confirmed ~= "both" and d.confirmed ~= "referee" then ok = false end
    if filter.since and (d.t or 0) < filter.since then ok = false end
    if filter.oppClass and not (d.opp and d.opp.class == filter.oppClass) then ok = false end
    if ok then out[#out + 1] = d end
  end
  return out
end
