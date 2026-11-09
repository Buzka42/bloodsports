-- Fixed odds (contract §3.3, §3.4, §3.5, §5.5): price locks at acceptance, stale price refused, the §3.3 worked
-- table (bank 25 g, 1.80 / 2.10), BANK_MAX at OpenMarket, settle payouts, bookie short -> debts due -> owes, partial pay.
local T = dofile(os.getenv("WOW_STUB") or "tests/wow_stub.lua")
GetChannelName = function() return 0 end
UnitIsGroupLeader = function() return true end
WorldOfMetaData = { bloodsports = { referees = { ["Tester-Normal"] = { cap = 50 } },
  bookies = { ["Tester-Normal"] = { level = 5, positiveRatings = 20 } } } }
local ns = T.LoadAddon("Bloodsports/Bloodsports.toc")
local A, R = ns.A, ns.Ring
A.db.config.referee.available = true
A.db.config.ring.currency = "gold"
T.money = 100000000 -- 10000 g: GetMoney covers every bank below

local function party(...)
  local names = { ... }
  T.group = { size = #names + 1, raid = false }
  for i = 1, 4 do T.units["party" .. i] = names[i] and { name = names[i], isPlayer = true } or nil end
end

local function fields(m)
  local f = {}
  for p in (m.msg .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = p end
  table.remove(f, 1)
  return f
end

-- R2X replies whispered to `who` since index `from` of T.sent.
local function refusals(who, from)
  T.Advance(60) -- whispers queue behind group broadcasts in the 1/s comm bucket (FIFO)
  local out = {}
  for i = (from or 1), #T.sent do
    local m = T.sent[i]
    if m.msg:sub(1, 4) == "R2X\t" and m.target == who then out[#out + 1] = fields(m) end
  end
  return out
end

local nonce = 0
local function r2b(sender, mid, idx, amount, price)
  nonce = nonce + 1
  local s = R.session
  T.Deliver("BSPT", table.concat({ "R2B", s.id, mid, idx, amount, price, string.format("%04x", nonce) }, "\t"), "WHISPER", sender)
  T.Advance(2.1)
  local m = R.Market(mid, s)
  for _, b in ipairs(m.bets) do if b.bettor == sender then return b end end
end

local function trade(partner, got, gave)
  T.units.npc = { name = partner, isPlayer = true }
  T.Fire("TRADE_SHOW")
  T.trade.target, T.trade.player = got, gave
  T.Fire("TRADE_MONEY_CHANGED")
  T.Fire("TRADE_ACCEPT_UPDATE", 1, 1)
  T.Fire("TRADE_CLOSED")
  T.SetMoney(T.money + got - gave)
  T.trade.target, T.trade.player = 0, 0
  T.Advance(1.1)
  return ns.char.trades[#ns.char.trades]
end

-- Fresh host session: no earlier session, refund or debt may leak into the next case's trade matching.
local function open()
  if R.session then R.Close(true) end
  T.Advance(60)
  R.last, ns.char.ring.last = nil, nil
  ns.char.ring.debts, ns.char.ring.unmatched = {}, {}
  return R.Open("ratchet")
end

local function fixedMarket(prices, bank)
  return R.AddMarket({ kind = "winner", a = "Fa", b = "Fb", mode = "fixed", prices = prices, bank = bank, open = true })
end

local G = 10000

T.test("OpenMarket: bank above BANK_MAX (10 x band) is refused; missing/out-of-range prices refused", function()
  party("Ann", "Bob", "Cid")
  local s = open()
  T.ok(type(s) == "table", "host session")
  T.eq(R.BankMax(s.host), 500 * G, "level 5: BANK_MAX 500 g")
  local ok, why = fixedMarket({ 180, 210 }, 500 * G + 1)
  T.eq(ok, false); T.eq(why, "bank", "500 g + 1 c over BANK_MAX")
  ok, why = fixedMarket({ 180, 100 }, 25 * G)
  T.eq(why, "price", "price 1.00 below PRICE_MIN")
  ok, why = fixedMarket({ 180, 1001 }, 25 * G)
  T.eq(why, "price", "price 10.01 above PRICE_MAX")
  ok, why = fixedMarket({ 180, 210 }, 0)
  T.eq(why, "bank", "no bank")
  WorldOfMetaData.bloodsports.bookies["Tester-Normal"].level = 1
  ok, why = fixedMarket({ 180, 210 }, 100 * G + 1)
  T.eq(why, "bank", "level 1: BANK_MAX 100 g")
  WorldOfMetaData.bloodsports.bookies["Tester-Normal"].level = 5
  T.eq(next(s.markets), nil, "refused markets are not kept")
  R.Close(true)
end)

T.test("§3.3 worked table: Ann 20 g @1.80, Bob 30 g @2.10, Cid 50 g refused bank max 487500, Cid 45 g accepted", function()
  party("Ann", "Bob", "Cid")
  local s = open()
  local m = fixedMarket({ 180, 210 }, 25 * G)
  T.ok(type(m) == "table", "fixed market open")
  T.eq(m.status, "open"); T.eq(m.bank, 250000)

  local ann = r2b("Ann-Normal", m.mid, 1, 20 * G, 180)
  T.ok(ann, "Ann accepted")
  T.eq(ann.price, 180, "price locked into the bet")
  T.eq(R.Liability(m.mid, 1), 16 * G, "L1 after Ann = 16 g")
  T.eq(R.Liability(m.mid, 2), 0, "L2 after Ann = 0 (Ann unpaid at acceptance)")
  trade("Ann", 20 * G, 0)
  T.ok(ann.paid, "Ann paid before the next bet")

  local bob = r2b("Bob-Normal", m.mid, 2, 30 * G, 210)
  T.ok(bob, "Bob accepted")
  T.eq(R.Liability(m.mid, 1), 16 * G, "L1 after Bob = 16 g")
  T.eq(R.Liability(m.mid, 2), 13 * G, "L2 after Bob = 33 - 20 = 13 g")
  trade("Bob", 30 * G, 0)
  T.ok(bob.paid)

  local from = #T.sent + 1
  T.eq(r2b("Cid-Normal", m.mid, 1, 50 * G, 180), nil, "Cid 50 g refused")
  local x = refusals("Cid-Normal", from)
  T.eq(#x, 1)
  T.eq(x[1][4], "bank"); T.eq(x[1][5], "487500", "R2X bank returns smax = 487500 c")
  T.eq(R.Liability(m.mid, 1), 16 * G - 30 * G, "refused bet leaves L1 untouched (Bob now paid)")

  local cid = r2b("Cid-Normal", m.mid, 1, 45 * G, 180)
  T.ok(cid, "Cid 45 g accepted")
  T.eq(R.Liability(m.mid, 1), 22 * G, "L1 = 16 + 36 - 30 = 22 g")
  T.eq(R.Liability(m.mid, 2), 13 * G, "L2 unchanged = 13 g")
  trade("Cid", 45 * G, 0)
  T.ok(cid.paid)
  T.ok(R.Liability(m.mid, 1) <= m.bank, "cover rule holds")

  -- If o1 wins: stakes 95 g in, payouts 36 + 81 = 117 g out, bookie net -22 g = L1.
  T.ok(R.Verdict(m.mid, 1))
  T.eq(ann.payout, 36 * G); T.eq(cid.payout, 81 * G); T.eq(bob.payout, 0)
  T.eq((ann.amount + bob.amount + cid.amount) - (ann.payout + cid.payout), -22 * G, "bookie net = -L1")
  T.eq(m.dust, 0, "fixed odds keep no dust")
  R.Close(true)
end)

T.test("smax boundary: a stake of exactly smax brings L1 to the bank", function()
  party("Ann", "Bob", "Dan")
  local s = open()
  local m = fixedMarket({ 180, 210 }, 25 * G)
  r2b("Ann-Normal", m.mid, 1, 20 * G, 180); trade("Ann", 20 * G, 0)
  r2b("Bob-Normal", m.mid, 2, 30 * G, 210); trade("Bob", 30 * G, 0)
  T.eq(R.Liability(m.mid, 1), -140000)
  local dan = r2b("Dan-Normal", m.mid, 1, 487500, 180)
  T.ok(dan, "smax 487500 accepted")
  T.eq(R.Liability(m.mid, 1), 250000, "L1 = bank exactly")
  R.Close(true)
end)

T.test("price changes only while open; a stale price is refused (R2X price); accepted bets keep their price", function()
  party("Ann", "Bob", "Cid")
  local s = open()
  local m = fixedMarket({ 180, 210 }, 100 * G)
  local ann = r2b("Ann-Normal", m.mid, 1, 10 * G, 180)
  T.ok(ann)
  local rev = s.rev
  T.ok(R.SetPrice(m.mid, 1, 150), "reprice while open")
  T.ok(s.rev > rev, "price change bumps rev")
  T.eq(m.outcomes[1].price, 150)
  T.eq(ann.price, 180, "Ann's accepted price is locked")
  local from = #T.sent + 1
  T.eq(r2b("Bob-Normal", m.mid, 1, 10 * G, 180), nil, "Bob saw the old 1.80")
  local x = refusals("Bob-Normal", from)
  T.eq(#x, 1); T.eq(x[1][4], "price"); T.eq(x[1][5], "0")
  T.Advance(2.1)
  local bob = r2b("Bob-Normal", m.mid, 1, 10 * G, 150)
  T.ok(bob, "current price accepted"); T.eq(bob.price, 150)
  T.eq(R.SetPrice(m.mid, 1, 101), true)
  T.eq(R.SetPrice(m.mid, 1, 100), false, "below PRICE_MIN")
  T.ok(R.Lock(m.mid))
  T.eq(R.SetPrice(m.mid, 1, 200), false, "locked: price frozen")
  trade("Ann", 10 * G, 0)
  trade("Bob", 10 * G, 0)
  T.ok(ann.paid and bob.paid)
  T.ok(R.Verdict(m.mid, 1))
  T.eq(ann.payout, 180000, "Ann paid at her locked 1.80")
  T.eq(bob.payout, 150000, "Bob paid at his 1.50")
  R.Close(true)
end)

T.test("void and unpaid: fixed refunds paid stakes only", function()
  party("Ann", "Bob", "Cid")
  local s = open()
  local m = fixedMarket({ 180, 210 }, 100 * G)
  local ann = r2b("Ann-Normal", m.mid, 1, 10 * G, 180)
  local bob = r2b("Bob-Normal", m.mid, 2, 20 * G, 210)
  trade("Ann", 10 * G, 0)
  T.ok(R.Void(m.mid))
  T.eq(ann.payout, 10 * G, "paid stake refunded")
  T.eq(bob.payout, 0, "unpaid stake: nothing to refund")
  T.ok(bob.void); T.eq(bob.voidReason, "unpaid")
  R.Close(true)
end)

local function rowsSince(from, ev)
  local out = {}
  for i = from + 1, #A.db.outbox.rows do
    local r = A.db.outbox.rows[i]
    if r.kind == "ring" and r.data.ev == ev then out[#out + 1] = r.data end
  end
  return out
end

T.test("settle: fixed payouts, bet rows with price, debts due -> owes after a later fight + 600 s, partial payout", function()
  party("Ann", "Bob", "Cid")
  local s = open()
  local m = fixedMarket({ 180, 210 }, 25 * G)
  local ann = r2b("Ann-Normal", m.mid, 1, 20 * G, 180); trade("Ann", 20 * G, 0)
  local bob = r2b("Bob-Normal", m.mid, 2, 30 * G, 210); trade("Bob", 30 * G, 0)
  local cid = r2b("Cid-Normal", m.mid, 1, 45 * G, 180); trade("Cid", 45 * G, 0)
  T.ok(R.Lock(m.mid))
  local fight1 = m.fight
  local from = #A.db.outbox.rows
  T.ok(R.Verdict(m.mid, 1))
  T.Advance(601)
  T.eq(m.status, "settled")
  local bets = {}
  for i = from + 1, #A.db.outbox.rows do
    local r = A.db.outbox.rows[i]
    if r.kind == "bet" then bets[r.data.bettor] = r.data end
  end
  T.eq(bets["Ann-Normal"].mode, "fixed"); T.eq(bets["Ann-Normal"].price, 180)
  T.eq(bets["Ann-Normal"].payout, 360000); T.eq(bets["Ann-Normal"].result, "win")
  T.eq(bets["Cid-Normal"].payout, 810000)
  T.eq(bets["Bob-Normal"].price, 210); T.eq(bets["Bob-Normal"].result, "loss"); T.eq(bets["Bob-Normal"].payout, 0)
  local settle = rowsSince(from, "settle")[1]
  T.eq(settle.prices[1], 180); T.eq(settle.prices[2], 210); T.eq(settle.mode, "fixed")

  -- the bookie pays nobody yet: one debt per winning bet, due
  local debts = R.Debts()
  T.eq(#debts, 2)
  local d = {}
  for _, x in ipairs(debts) do d[x.bettor] = x end
  T.eq(d["Ann-Normal"].amount, 360000); T.eq(d["Cid-Normal"].amount, 810000)
  T.eq(d["Ann-Normal"].status, "due"); T.eq(d["Ann-Normal"].fight, fight1)
  T.eq(d["Ann-Normal"].id, s.id .. "." .. m.mid)

  -- grace alone does not flip to owes without a later fight (backstop is 24 h)
  T.Advance(700)
  T.eq(d["Ann-Normal"].status, "due", "no later fight yet")

  -- partial payout to Ann while due
  trade("Ann", 0, 100000)
  T.eq(ann.paidOutAmount, 100000); T.eq(ann.paidOut, false)
  T.eq(d["Ann-Normal"].paid, 100000); T.eq(d["Ann-Normal"].status, "due")

  -- a later fight settles: open debts become owes
  local m2 = R.AddMarket({ kind = "winner", a = "Fa", b = "Fb", mode = "pari", open = true })
  T.ok(R.Lock(m2.mid))
  T.ok(m2.fight > fight1, "later fight")
  T.ok(R.Verdict(m2.mid, 1))
  T.eq(d["Ann-Normal"].status, "due", "still due while the later market is resolving")
  T.Advance(601)
  T.eq(m2.status, "settled")
  T.eq(d["Ann-Normal"].status, "owes"); T.eq(d["Cid-Normal"].status, "owes")

  -- remaining payout clears the debt
  trade("Ann", 0, 260000)
  T.ok(ann.paidOut); T.eq(ann.paidOutAmount, 360000)
  T.eq(d["Ann-Normal"].status, "cleared"); T.eq(d["Ann-Normal"].clearedBy, "host")
  T.eq(d["Cid-Normal"].status, "owes", "Cid still owed")
  R.Close(true)
end)

T.test("owes backstop: an open debt flips after 24 h with no further fights", function()
  party("Ann", "Bob")
  open()
  local m = fixedMarket({ 200, 200 }, 25 * G)
  r2b("Ann-Normal", m.mid, 1, 10 * G, 200); trade("Ann", 10 * G, 0)
  T.ok(R.Verdict(m.mid, 1))
  T.Advance(601)
  local d = R.Debts()[1]
  T.eq(d.amount, 20 * G); T.eq(d.status, "due")
  R.Close(true)
  T.Advance(86400 - 601)
  T.eq(d.status, "due", "just before the backstop")
  T.Advance(601)
  T.eq(d.status, "owes", "24 h backstop")
end)

T.noErrors()
T.done()
