-- Lion's Pride Slots: game rules. Pure Lua, no interface code.
-- This is a port of engine.js from the web version; keep the two in step.
--
-- Money model: 1 credit = one denomination (1, 2, 5 or 10 cents). Every spin plays
-- all 25 lines at 1-10 credits per line, so the total bet is
-- 25 x credits-per-line x denomination. It is play money only.

local _, ns = ...
local E = {}
ns.Engine = E

local random, floor, min, max = math.random, math.floor, math.min, math.max

E.DENOMS = { 1, 2, 5, 10 }        -- cents per credit
E.BET_MULTS = { 1, 2, 3, 5, 10 }  -- credits per line
E.REELS, E.ROWS = 5, 3

local ICON = "Interface\\Icons\\"

-- weight = how often a symbol lands; pays = credits per line credit for 3/4/5 in a row;
-- sounds = game sound file IDs, one is picked at random when the symbol wins.
E.SYMBOLS = {
  { id = "peacebloom", name = "Peacebloom",      icon = ICON .. "INV_Misc_Flower_02",               quality = "common",    weight = 22, pays = { [3] = 10,  [4] = 40,  [5] = 100 },  sounds = { 567552 } },
  { id = "linen",      name = "Linen Cloth",     icon = ICON .. "INV_Fabric_Linen_01",              quality = "common",    weight = 21, pays = { [3] = 10,  [4] = 40,  [5] = 100 },  sounds = { 567565 } },
  { id = "copper",     name = "Copper Ore",      icon = ICON .. "INV_Ore_Copper_01",                quality = "common",    weight = 20, pays = { [3] = 10,  [4] = 50,  [5] = 125 },  sounds = { 567564 } },
  { id = "candle",     name = "Kobold Candle",   icon = ICON .. "INV_Misc_Candle_01",               quality = "common",    weight = 19, pays = { [3] = 15,  [4] = 60,  [5] = 150 },  sounds = { 1255473 } },
  { id = "boar",       name = "Boar",            icon = ICON .. "Ability_Hunter_Pet_Boar",          quality = "uncommon",  weight = 13, pays = { [3] = 25,  [4] = 100, [5] = 250 },  sounds = { 545134, 545133, 545128 } },
  { id = "murloc",     name = "Murloc",          icon = ICON .. "INV_Misc_Head_Murloc_01",          quality = "uncommon",  weight = 11, pays = { [3] = 30,  [4] = 120, [5] = 300 },  sounds = { 556000 } },
  { id = "defias",     name = "Defias Bandit",   icon = ICON .. "INV_Misc_Bandana_03",              quality = "rare",      weight = 9,  pays = { [3] = 40,  [4] = 150, [5] = 500 },  sounds = { 547946, 547945, 547944, 547947 } },
  { id = "hogger",     name = "Hogger",          icon = ICON .. "INV_Misc_Head_Gnoll_01",           quality = "epic",      weight = 7,  pays = { [3] = 50,  [4] = 200, [5] = 1000 }, sounds = { 550351, 550344, 550341 } },
  { id = "human",      name = "Stormwind Guard", icon = ICON .. "Achievement_Character_Human_Male", quality = "epic",      weight = 5,  pays = { [3] = 75,  [4] = 300, [5] = 1500 }, sounds = { 552191, 552190, 552194, 552185 } },
  { id = "wild",       name = "Alliance",        icon = ICON .. "Achievement_PVP_A_A",              quality = "legendary", weight = 4,  pays = { [3] = 100, [4] = 500, [5] = 2500 }, sounds = { 552180, 552221 }, wild = true },
  { id = "scatter",    name = "Portal",          icon = ICON .. "Spell_Arcane_PortalStormWind",     quality = "arcane",    weight = 4,  scatter = true },
  { id = "orb",        name = "Gold Orb",        icon = ICON .. "INV_Misc_Gem_Pearl_04",            quality = "artifact",  weight = 18, orb = true },
}
E.TICKET_ICON = ICON .. "INV_Misc_Ticket_Darkmoon_01"

-- Portals: pay x total bet and award free games (free-game line wins are multiplied).
E.SCATTER_PAYS = { [3] = 2, [4] = 10, [5] = 50 }
E.SCATTER_SPINS = { [3] = 10, [4] = 15, [5] = 25 }
E.FREE_SPIN_MULT = 3

-- Darkmoon Faire bonus (hold and spin): 6+ gold orbs lock in place and award 3 respins.
-- Every prize ticket that lands resets the count. Fill all 15 spots for the Grand.
E.HOLD = { trigger = 6, respins = 3, landChance = 0.045 }
-- What a prize is worth, in multiples of the total bet (or a jackpot).
E.ORB_TABLE = {
  { x = 1, w = 380 }, { x = 2, w = 260 }, { x = 3, w = 140 }, { x = 4, w = 80 }, { x = 5, w = 60 },
  { x = 8, w = 35 }, { x = 10, w = 25 }, { x = 20, w = 10 },
  { jackpot = "mini", w = 20 }, { jackpot = "minor", w = 6 }, { jackpot = "major", w = 1 },
}
-- Jackpots in multiples of the total bet. Major and Grand are starting values; they grow as you play.
E.JACKPOTS = { mini = 20, minor = 50, major = 250, grand = 2500 }
E.JACKPOT_GROWTH = { major = 0.01, grand = 0.05 } -- added per paid spin, in bet multiples

-- Experience: every paid spin earns XP. A full bar is a level-up, which opens the
-- Darkmoon Faire straight away with one of these buffs.
E.LEVEL = { spins = 200, curve = 2.4, startOrbs = 5 }
E.LEVEL_BUFFS = {
  { id = "wellfed",   name = "Well Fed", desc = "Every prize is worth double", mult = 2 },
  { id = "haste",     name = "Haste",    desc = "4 spins instead of 3",        respins = 4 },
  { id = "headstart", name = "Rested",   desc = "Start with 7 orbs",           startOrbs = 7 },
}

-- Row (1 = top) for each reel, left to right.
E.PAYLINES = {
  { 2, 2, 2, 2, 2 }, { 1, 1, 1, 1, 1 }, { 3, 3, 3, 3, 3 }, { 1, 2, 3, 2, 1 }, { 3, 2, 1, 2, 3 },
  { 1, 1, 2, 1, 1 }, { 3, 3, 2, 3, 3 }, { 2, 1, 1, 1, 2 }, { 2, 3, 3, 3, 2 }, { 1, 2, 2, 2, 1 },
  { 3, 2, 2, 2, 3 }, { 2, 1, 2, 1, 2 }, { 2, 3, 2, 3, 2 }, { 1, 2, 1, 2, 1 }, { 3, 2, 3, 2, 3 },
  { 2, 2, 1, 2, 2 }, { 2, 2, 3, 2, 2 }, { 1, 1, 2, 3, 3 }, { 3, 3, 2, 1, 1 }, { 1, 2, 3, 3, 3 },
  { 3, 2, 1, 1, 1 }, { 2, 1, 2, 3, 2 }, { 2, 3, 2, 1, 2 }, { 1, 1, 3, 1, 1 }, { 3, 3, 1, 3, 3 },
}
E.LINES = #E.PAYLINES

local SYM, WILD, TOTAL_WEIGHT, ORB_WEIGHT = {}, nil, 0, 0
for _, s in ipairs(E.SYMBOLS) do
  SYM[s.id] = s
  TOTAL_WEIGHT = TOTAL_WEIGHT + s.weight
  if s.wild then WILD = s end
end
for _, o in ipairs(E.ORB_TABLE) do ORB_WEIGHT = ORB_WEIGHT + o.w end
E.SYM = SYM

local CELLS = E.REELS * E.ROWS

-- Cells are numbered 1..15, down each reel in turn.
function E.key(reel, row) return (reel - 1) * E.ROWS + row end
function E.unkey(k) return floor((k - 1) / E.ROWS) + 1, (k - 1) % E.ROWS + 1 end

function E.pick()
  local r = random() * TOTAL_WEIGHT
  for _, s in ipairs(E.SYMBOLS) do
    r = r - s.weight
    if r < 0 then return s.id end
  end
  return E.SYMBOLS[#E.SYMBOLS].id
end

function E.rollOrb()
  local r = random() * ORB_WEIGHT
  for _, o in ipairs(E.ORB_TABLE) do
    r = r - o.w
    if r < 0 then
      if o.jackpot then return { jackpot = o.jackpot } end
      return { x = o.x }
    end
  end
  return { x = 1 }
end

-- One spin: grid[reel][row] of symbol ids, plus what each orb on it is worth (by cell number).
function E.spin()
  local grid, orbs = {}, {}
  for reel = 1, E.REELS do
    grid[reel] = {}
    for row = 1, E.ROWS do
      local id = E.pick()
      grid[reel][row] = id
      if SYM[id].orb then orbs[E.key(reel, row)] = E.rollOrb() end
    end
  end
  return { grid = grid, orbs = orbs }
end

-- Line and scatter wins, in credits. betMult = credits per line.
function E.evaluate(grid, betMult, mult)
  mult = mult or 1
  local wins, total = {}, 0

  for li, line in ipairs(E.PAYLINES) do
    local syms = {}
    for reel = 1, E.REELS do syms[reel] = grid[reel][line[reel]] end

    local best
    local wildRun = 0
    while wildRun < E.REELS and SYM[syms[wildRun + 1]].wild do wildRun = wildRun + 1 end
    if wildRun >= 3 then best = { symbol = WILD.id, count = wildRun, pay = WILD.pays[wildRun] } end

    local base
    for reel = 1, E.REELS do
      if not SYM[syms[reel]].wild then base = syms[reel]; break end
    end
    if base and SYM[base].pays then
      local count = 0
      while count < E.REELS and (syms[count + 1] == base or SYM[syms[count + 1]].wild) do count = count + 1 end
      local pay = SYM[base].pays[count]
      if count >= 3 and pay and (not best or pay > best.pay) then
        best = { symbol = base, count = count, pay = pay }
      end
    end

    if best then
      local amount = best.pay * betMult * mult
      total = total + amount
      local cells = {}
      for reel = 1, best.count do cells[#cells + 1] = E.key(reel, line[reel]) end
      wins[#wins + 1] = { line = li, symbol = best.symbol, count = best.count, amount = amount, cells = cells }
    end
  end

  local scatterCells, orbCells = {}, {}
  for reel = 1, E.REELS do
    for row = 1, E.ROWS do
      local s = SYM[grid[reel][row]]
      if s.scatter then scatterCells[#scatterCells + 1] = E.key(reel, row) end
      if s.orb then orbCells[#orbCells + 1] = E.key(reel, row) end
    end
  end
  local n = min(#scatterCells, 5)
  local scatterWin, freeSpins = 0, 0
  if n >= 3 then
    scatterWin = E.SCATTER_PAYS[n] * betMult * E.LINES * mult
    freeSpins = E.SCATTER_SPINS[n]
    total = total + scatterWin
  end

  return {
    wins = wins, total = total,
    scatter = { count = #scatterCells, cells = scatterCells, win = scatterWin, freeSpins = freeSpins },
    orbs = { count = #orbCells, cells = orbCells, triggered = #orbCells >= E.HOLD.trigger },
  }
end

-- XP earned by one paid spin, as a fraction of a level.
function E.xpGain() return (0.5 + random()) / E.LEVEL.spins end
-- How full the bar is drawn for a given real progress (0..1). The curve keeps it looking nearly full.
function E.xpShown(xp) return 1 - (1 - min(1, max(0, xp))) ^ E.LEVEL.curve end

local function boosted(orb, buff)
  if buff and buff.mult and not orb.jackpot then return { x = orb.x * buff.mult } end
  return orb
end

-- A level-up: picks a buff and deals the starting orbs for its Faire.
function E.levelUp()
  local buff = E.LEVEL_BUFFS[random(#E.LEVEL_BUFFS)]
  local cells = {}
  for k = 1, CELLS do cells[k] = k end
  local orbs = {}
  for _ = 1, (buff.startOrbs or E.LEVEL.startOrbs) do
    local k = table.remove(cells, random(#cells))
    orbs[k] = boosted(E.rollOrb(), buff)
  end
  return { buff = buff, orbs = orbs }
end

-- Plays a whole Darkmoon Faire bonus from the starting orbs. Returns each respin's new prizes.
-- buff (from a level-up) can double prize values or give extra respins.
function E.playHold(startOrbs, buff)
  buff = buff or {}
  local held, count = {}, 0
  for k, orb in pairs(startOrbs) do held[k] = orb; count = count + 1 end
  local respins = buff.respins or E.HOLD.respins
  local rounds, left = {}, respins
  while left > 0 and count < CELLS do
    left = left - 1
    local landed = {}
    for k = 1, CELLS do
      if not held[k] and random() < E.HOLD.landChance then
        held[k] = boosted(E.rollOrb(), buff)
        landed[#landed + 1] = { cell = k, orb = held[k] }
        count = count + 1
      end
    end
    if #landed > 0 then left = respins end
    rounds[#rounds + 1] = { landed = landed, left = left }
  end
  return { rounds = rounds, held = held, respins = respins, full = count == CELLS }
end

-- A prize's worth in multiples of the total bet. jackpots holds the current values.
function E.orbValue(orb, jackpots)
  if orb.jackpot then return (jackpots or E.JACKPOTS)[orb.jackpot] end
  return orb.x
end
