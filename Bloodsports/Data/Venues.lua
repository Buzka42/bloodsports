local _, ns = ...
ns.Data = ns.Data or {}
-- Venue registry. x, y, r are 0-1 units on the zone map `mapID` (Classic uiMapIDs: Durotar 1411, Barrens 1413,
-- Elwynn 1429, STV 1434, Tanaris 1446, Winterspring 1452). Coordinates are Classic-map approximations (conf: med);
-- MetaKit.Venue also matches on subzone text, so either signal is enough. Re-measure with /probe venue in game.
-- kinds: practice = duel practice (no ranking), club = fight club (champion per class per faction),
--        ring = goblin gambling ring (referee-run), koth = Gurubashi king of the hill (dormant until V2).
-- dormant = true: not in the active list (UI.Venues) and never matched. History still resolves its name.
-- unverified = true: no measured position yet. Listed in the UI, never matched (Core.lua filters it out of the matcher).
ns.Data.Venues = {
  { id = "crossroads", kind = "practice", name = "Crossroads Duel Practice", mapID = 1413, subzone = "The Crossroads", x = 0.52, y = 0.30, r = 0.035, faction = "Horde" },
  { id = "goldshire", kind = "practice", name = "Goldshire Duel Practice", mapID = 1429, subzone = "Goldshire", x = 0.42, y = 0.65, r = 0.035, faction = "Alliance" },
  -- Honor Road: the road right outside Orgrimmar's gate in Durotar (owner, 2026-10-21). No subzone name; coordinate box only.
  { id = "honorroad", kind = "club", name = "Honor Road Fight Club", mapID = 1411, subzone = nil, x = 0.455, y = 0.13, r = 0.045, faction = "Horde" },
  -- Coldridge Pass: replaces the Deeprun Tram (owner, 2026-10-22). Faction Alliance is the owner's intent.
  -- COORDINATES NOT MEASURED. Do not guess them. To verify: stand at the fight spot and sample it with /probe venue
  -- (elders addon, MetaProbe venue sampler), then set mapID, x, y, r, drop `unverified`. Until then the matcher skips it.
  { id = "coldridge", kind = "club", name = "Coldridge Pass Fight Club", mapID = nil, subzone = nil, x = nil, y = nil, r = nil, faction = "Alliance", unverified = true },
  { id = "ratchet", kind = "ring", name = "Ratchet Goblin Ring", mapID = 1413, subzone = "Ratchet", x = 0.625, y = 0.375, r = 0.03, faction = "Both" },
  { id = "everlook", kind = "ring", name = "Everlook Goblin Ring", mapID = 1452, subzone = "Everlook", x = 0.613, y = 0.386, r = 0.03, faction = "Both" },
  { id = "gadgetzan", kind = "ring", name = "Gadgetzan Goblin Ring", mapID = 1446, subzone = "Gadgetzan", x = 0.515, y = 0.28, r = 0.03, faction = "Both" },
  { id = "bootybay", kind = "ring", name = "Booty Bay Goblin Ring", mapID = 1434, subzone = "Booty Bay", x = 0.275, y = 0.77, r = 0.03, faction = "Both" },
  { id = "gurubashi", kind = "koth", name = "Gurubashi Arena", mapID = 1434, subzone = "Gurubashi Arena", x = 0.305, y = 0.475, r = 0.02, faction = "Both", dormant = true },
}
