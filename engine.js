/*
 * Lion's Pride slot engine — pure game logic, no DOM.
 *
 * Money model: 1 credit = one denomination (1¢, 2¢, 5¢ or 10¢). Every spin
 * plays all 25 lines at 1–10 credits per line, so the total bet is
 * 25 × credits-per-line × denomination.
 *
 * RESKINNING: each symbol's `img` is the icon on the reels, `name` shows in
 * the rules, `quality` picks the border colour (WoW rarity colours) and
 * `sound` plays when that symbol wins (a list means one is picked at random).
 *
 * TUNING: `weight` is how often a symbol lands, `pays` are credits per line
 * credit for 3/4/5 in a row. After changing anything here run `node sim.js`
 * to see the new payout rate.
 */
(function (root) {
  'use strict';

  const DENOMS = [1, 2, 5, 10];        // cents per credit
  const BET_MULTS = [1, 2, 3, 5, 10];  // credits per line
  const REELS = 5, ROWS = 3;

  const SYMBOLS = [
    { id: 'peacebloom', name: 'Peacebloom',     img: 'assets/icons/peacebloom.png', quality: 'common',    weight: 22, pays: { 3: 10, 4: 40,  5: 100 },  sound: 'assets/sfx/loot_herb.ogg' },
    { id: 'linen',      name: 'Linen Cloth',    img: 'assets/icons/linen.png',      quality: 'common',    weight: 21, pays: { 3: 10, 4: 40,  5: 100 },  sound: 'assets/sfx/loot_cloth.ogg' },
    { id: 'copper',     name: 'Copper Ore',     img: 'assets/icons/copper.png',     quality: 'common',    weight: 20, pays: { 3: 10, 4: 50,  5: 125 },  sound: 'assets/sfx/loot_ore.ogg' },
    { id: 'candle',     name: 'Kobold Candle',  img: 'assets/icons/candle.png',     quality: 'common',    weight: 19, pays: { 3: 15, 4: 60,  5: 150 },  sound: ['assets/sfx/kobold.ogg', 'assets/sfx/kobold2.ogg', 'assets/sfx/kobold3.ogg'] },
    { id: 'boar',       name: 'Boar',           img: 'assets/icons/boar.png',       quality: 'uncommon',  weight: 13, pays: { 3: 25, 4: 100, 5: 250 },  sound: ['assets/sfx/boar1.ogg', 'assets/sfx/boar2.ogg', 'assets/sfx/boar3.ogg'] },
    { id: 'murloc',     name: 'Murloc',         img: 'assets/icons/murloc.png',     quality: 'uncommon',  weight: 11, pays: { 3: 30, 4: 120, 5: 300 },  sound: 'assets/sfx/murloc.ogg' },
    { id: 'defias',     name: 'Defias Bandit',  img: 'assets/icons/defias.png',     quality: 'rare',      weight: 9,  pays: { 3: 40, 4: 150, 5: 500 },  sound: ['assets/sfx/defias1.ogg', 'assets/sfx/defias2.ogg', 'assets/sfx/defias3.ogg', 'assets/sfx/defias4.ogg'] },
    { id: 'hogger',     name: 'Hogger',         img: 'assets/icons/hogger.png',     quality: 'epic',      weight: 7,  pays: { 3: 50, 4: 200, 5: 1000 }, sound: ['assets/sfx/gnoll1.ogg', 'assets/sfx/gnoll2.ogg', 'assets/sfx/gnoll3.ogg'] },
    { id: 'human',      name: 'Stormwind Guard', img: 'assets/icons/human.png',     quality: 'epic',      weight: 5,  pays: { 3: 75, 4: 300, 5: 1500 }, sound: ['assets/sfx/human_wellmet.ogg', 'assets/sfx/human_greetings.ogg', 'assets/sfx/human_kingshonor.ogg', 'assets/sfx/human_lightbewithyou.ogg'] },
    { id: 'wild',       name: 'Alliance',       img: 'assets/icons/wild.png',       quality: 'legendary', weight: 4,  wild: true, pays: { 3: 100, 4: 500, 5: 2500 }, sound: ['assets/sfx/alliance1.ogg', 'assets/sfx/alliance2.ogg'] },
    { id: 'scatter',    name: 'Portal',         img: 'assets/icons/portal.png',     quality: 'arcane',    weight: 4,  scatter: true },
    { id: 'orb',        name: 'Gold',           img: 'assets/icons/orb.png',        quality: 'artifact',  weight: 18, orb: true },
  ];

  // Portals: pay × total bet and award free games (all free-game line wins are multiplied).
  const SCATTER_PAYS = { 3: 2, 4: 10, 5: 50 };
  const SCATTER_SPINS = { 3: 10, 4: 15, 5: 25 };
  const FREE_SPIN_MULT = 3;

  // Darkmoon Faire bonus (hold and spin): 6+ gold orbs lock in place and award 3 respins.
  // Every prize ticket that lands resets the count to 3. Fill all 15 spots for the Grand.
  const HOLD = { trigger: 6, respins: 3, landChance: 0.045 };
  // What an orb is worth, in multiples of the total bet (or a jackpot).
  const ORB_TABLE = [
    { x: 1, w: 380 }, { x: 2, w: 260 }, { x: 3, w: 140 }, { x: 4, w: 80 }, { x: 5, w: 60 },
    { x: 8, w: 35 }, { x: 10, w: 25 }, { x: 20, w: 10 },
    { jackpot: 'mini', w: 20 }, { jackpot: 'minor', w: 6 }, { jackpot: 'major', w: 1 },
  ];
  // Jackpots in multiples of the total bet. Major and Grand are starting values; they grow as you play.
  const JACKPOTS = { mini: 20, minor: 50, major: 250, grand: 2500 };
  const JACKPOT_GROWTH = { major: 0.01, grand: 0.05 }; // added per paid spin, in bet multiples

  // Experience: every paid spin earns XP. A full bar is a level-up, which opens the
  // Darkmoon Faire straight away with one of these buffs.
  const LEVEL = {
    spins: 200,   // average paid spins per level
    // The bar is a carrot on a stick. It never looks less than `barFloor` full, races up early, then
    // creeps toward `barCeil`. It only reaches 100% on the spin that actually levels you up.
    barFloor: 0.55, barCeil: 0.97, curve: 0.6,
    startOrbs: 5, // orbs you begin the level-up Faire with
  };
  const LEVEL_BUFFS = [
    { id: 'wellfed',   name: 'Well Fed',        desc: 'Every prize is worth double', mult: 2 },
    { id: 'haste',     name: 'Haste',           desc: '4 spins instead of 3',        respins: 4 },
    { id: 'headstart', name: 'Rested',          desc: 'Start with 7 orbs',           startOrbs: 7 },
  ];

  // Row index (0 = top) for each reel, left to right.
  const PAYLINES = [
    [1, 1, 1, 1, 1], [0, 0, 0, 0, 0], [2, 2, 2, 2, 2], [0, 1, 2, 1, 0], [2, 1, 0, 1, 2],
    [0, 0, 1, 0, 0], [2, 2, 1, 2, 2], [1, 0, 0, 0, 1], [1, 2, 2, 2, 1], [0, 1, 1, 1, 0],
    [2, 1, 1, 1, 2], [1, 0, 1, 0, 1], [1, 2, 1, 2, 1], [0, 1, 0, 1, 0], [2, 1, 2, 1, 2],
    [1, 1, 0, 1, 1], [1, 1, 2, 1, 1], [0, 0, 1, 2, 2], [2, 2, 1, 0, 0], [0, 1, 2, 2, 2],
    [2, 1, 0, 0, 0], [1, 0, 1, 2, 1], [1, 2, 1, 0, 1], [0, 0, 2, 0, 0], [2, 2, 0, 2, 2],
  ];
  const LINES = PAYLINES.length;

  const SYM = Object.fromEntries(SYMBOLS.map(s => [s.id, s]));
  const WILD = SYMBOLS.find(s => s.wild);
  const TOTAL_WEIGHT = SYMBOLS.reduce((a, s) => a + s.weight, 0);
  const ORB_WEIGHT = ORB_TABLE.reduce((a, o) => a + o.w, 0);
  const key = (reel, row) => reel + ',' + row;

  function pick(rng = Math.random) {
    let r = rng() * TOTAL_WEIGHT;
    for (const s of SYMBOLS) { if ((r -= s.weight) < 0) return s.id; }
    return SYMBOLS[SYMBOLS.length - 1].id;
  }

  function rollOrb(rng = Math.random) {
    let r = rng() * ORB_WEIGHT;
    for (const o of ORB_TABLE) { if ((r -= o.w) < 0) return o.jackpot ? { jackpot: o.jackpot } : { x: o.x }; }
    return { x: 1 };
  }

  // One spin: grid[reel][row] of symbol ids, plus what each orb on it is worth.
  function spin(rng = Math.random) {
    const grid = [], orbs = {};
    for (let reel = 0; reel < REELS; reel++) {
      grid.push([]);
      for (let row = 0; row < ROWS; row++) {
        const id = pick(rng);
        grid[reel].push(id);
        if (SYM[id].orb) orbs[key(reel, row)] = rollOrb(rng);
      }
    }
    return { grid, orbs };
  }

  // Line and scatter wins, in credits. `betMult` = credits per line.
  function evaluate(grid, betMult, mult = 1) {
    const wins = [];
    let total = 0;

    PAYLINES.forEach((line, li) => {
      const syms = line.map((row, reel) => grid[reel][row]);
      let best = null;
      let wildRun = 0;
      while (wildRun < REELS && SYM[syms[wildRun]].wild) wildRun++;
      if (wildRun >= 3) best = { symbol: WILD.id, count: wildRun, pay: WILD.pays[wildRun] };

      const base = syms.find(s => !SYM[s].wild);
      if (base && SYM[base].pays) {
        let count = 0;
        while (count < REELS && (syms[count] === base || SYM[syms[count]].wild)) count++;
        const pay = SYM[base].pays[count];
        if (count >= 3 && pay && (!best || pay > best.pay)) best = { symbol: base, count, pay };
      }
      if (best) {
        const amount = best.pay * betMult * mult;
        total += amount;
        wins.push({ line: li, symbol: best.symbol, count: best.count, amount,
          cells: line.slice(0, best.count).map((row, reel) => [reel, row]) });
      }
    });

    const scatterCells = [], orbCells = [];
    grid.forEach((col, reel) => col.forEach((s, row) => {
      if (SYM[s].scatter) scatterCells.push([reel, row]);
      if (SYM[s].orb) orbCells.push([reel, row]);
    }));
    const n = Math.min(scatterCells.length, 5);
    let scatterWin = 0, freeSpins = 0;
    if (n >= 3) {
      scatterWin = SCATTER_PAYS[n] * betMult * LINES * mult;
      freeSpins = SCATTER_SPINS[n];
      total += scatterWin;
    }
    return {
      wins, total,
      scatter: { count: scatterCells.length, cells: scatterCells, win: scatterWin, freeSpins },
      orbs: { count: orbCells.length, cells: orbCells, triggered: orbCells.length >= HOLD.trigger },
    };
  }

  // XP earned by one paid spin, as a fraction of a level.
  function xpGain(rng = Math.random) { return (0.5 + rng()) / LEVEL.spins; }
  // How full the bar is drawn for a given real progress (0..1).
  function xpShown(xp) {
    if (xp >= 1) return 1;
    return LEVEL.barFloor + (LEVEL.barCeil - LEVEL.barFloor) * Math.pow(Math.max(0, xp), LEVEL.curve);
  }

  // A level-up: picks a buff and deals the starting orbs for its Faire.
  function levelUp(rng = Math.random) {
    const buff = LEVEL_BUFFS[Math.floor(rng() * LEVEL_BUFFS.length)];
    const boost = o => (buff.mult && !o.jackpot) ? { x: o.x * buff.mult } : o;
    const cells = [];
    for (let reel = 0; reel < REELS; reel++) for (let row = 0; row < ROWS; row++) cells.push(key(reel, row));
    const orbs = {};
    for (let n = buff.startOrbs || LEVEL.startOrbs; n > 0; n--) {
      const k = cells.splice(Math.floor(rng() * cells.length), 1)[0];
      orbs[k] = boost(rollOrb(rng));
    }
    return { buff, orbs };
  }

  // Plays a whole Darkmoon Faire bonus from the starting orbs. Returns each respin's new prizes.
  // `buff` (from a level-up) can double prize values or give extra respins.
  function playHold(startOrbs, rng = Math.random, buff = {}) {
    const held = Object.assign({}, startOrbs);
    const rounds = [];
    const respins = buff.respins || HOLD.respins;
    const boost = o => (buff.mult && !o.jackpot) ? { x: o.x * buff.mult } : o;
    let left = respins, count = Object.keys(held).length;
    while (left > 0 && count < REELS * ROWS) {
      left--;
      const landed = [];
      for (let reel = 0; reel < REELS; reel++) for (let row = 0; row < ROWS; row++) {
        const k = key(reel, row);
        if (!held[k] && rng() < HOLD.landChance) {
          held[k] = boost(rollOrb(rng));
          landed.push({ reel, row, orb: held[k] });
          count++;
        }
      }
      if (landed.length) left = respins;
      rounds.push({ landed, left });
    }
    return { rounds, held, respins, full: count === REELS * ROWS };
  }

  // An orb's worth in multiples of the total bet. `jackpots` holds the current values.
  function orbValue(orb, jackpots = JACKPOTS) {
    return orb.jackpot ? jackpots[orb.jackpot] : orb.x;
  }

  function makeRng(seed) {
    let a = seed >>> 0;
    return function () {
      a = (a + 0x6D2B79F5) >>> 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  const api = {
    DENOMS, BET_MULTS, REELS, ROWS, LINES, SYMBOLS, SYM, PAYLINES,
    SCATTER_PAYS, SCATTER_SPINS, FREE_SPIN_MULT, HOLD, ORB_TABLE, JACKPOTS, JACKPOT_GROWTH, LEVEL, LEVEL_BUFFS,
    key, pick, rollOrb, spin, evaluate, playHold, orbValue, xpGain, xpShown, levelUp, makeRng,
  };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  root.SlotEngine = api;
})(typeof globalThis !== 'undefined' ? globalThis : this);
