-- Contract §8.1 mirror vectors (canonical: elders/docs/BETTING_CONTRACT.md). Mirrored in
-- wom-backend/tests/fixtures/payout_vectors.json. Every stake is counted. result = nil means void.
-- payouts lists every bettor (losers 0); dust = T - sum(payouts), kept by the referee.
local V = {
  { id = "V1", stakes = { { "A", 1, 100000 }, { "B", 2, 300000 } }, result = 1,
    payouts = { A = 400000, B = 0 }, dust = 0 },
  { id = "V2", stakes = { { "A", 1, 7 }, { "B", 1, 13 }, { "C", 2, 29 } }, result = 1,
    payouts = { A = 17, B = 31, C = 0 }, dust = 1 },
  { id = "V3", stakes = { { "A", 1, 3 }, { "B", 1, 3 }, { "C", 2, 1 } }, result = 1,
    payouts = { A = 3, B = 3, C = 0 }, dust = 1 },
  { id = "V4", stakes = { { "A", 2, 100 }, { "B", 2, 250 } }, result = 1,
    payouts = { A = 100, B = 250 }, dust = 0 },
  { id = "V5", stakes = { { "Ann", 1, 120000 }, { "Bob", 1, 50000 }, { "Cid", 2, 75000 }, { "Dee", 3, 33333 },
      { "Eve", 4, 210000 } }, result = 1,
    payouts = { Ann = 344705, Bob = 143627, Cid = 0, Dee = 0, Eve = 0 }, dust = 1 },
  { id = "V6", stakes = { { "A", 1, 10000 }, { "B", 2, 10001 }, { "C", 3, 20000 }, { "D", 3, 33333 }, { "E", 5, 499999 },
      { "F", 6, 12345 }, { "G", 3, 7 } }, result = 3,
    payouts = { A = 0, B = 0, C = 219604, D = 366003, E = 0, F = 0, G = 76 }, dust = 2 },
  { id = "V7", stakes = { { "A", 1, 10000 }, { "B", 2, 20000 } }, result = nil,
    payouts = { A = 10000, B = 20000 }, dust = 0 },
  { id = "V9", stakes = { { "A", 1, 10000 }, { "B", 1, 10000 }, { "C", 1, 10000 }, { "D", 2, 10000 } }, result = 1,
    payouts = { A = 13333, B = 13333, C = 13333, D = 0 }, dust = 1 },
}

-- V8: P0..P10 on 1, P11..P29 on 2, each 500000; result 1 -> P0..P10 1363636 each, others 0; dust 4.
local v8 = { id = "V8", stakes = {}, result = 1, payouts = {}, dust = 4 }
for i = 0, 29 do
  local name = "P" .. i
  v8.stakes[#v8.stakes + 1] = { name, i <= 10 and 1 or 2, 500000 }
  v8.payouts[name] = i <= 10 and 1363636 or 0
end
table.insert(V, 8, v8)

local F = {
  { id = "F1", amount = 12345, price = 215, payout = 26541 },
}

return { pari = V, fixed = F }
