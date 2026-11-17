// Monte Carlo check of the payout rate: `node sim.js [spins]`
// Jackpots are counted at their starting values.
const E = require('./engine.js');
const N = Number(process.argv[2]) || 2_000_000;
const rng = E.makeRng(12345);
const bet = E.LINES; // credits, at 1 credit per line

let wagered = 0, lines = 0, free = 0, hold = 0, hits = 0, freeTrig = 0, holdTrig = 0, biggest = 0;
const jp = { mini: 0, minor: 0, major: 0, grand: 0 };
let holdOrbs = 0, xp = 0, levels = 0, levelPay = 0;

function playHold(orbs, buff) {
  const h = E.playHold(orbs, rng, buff);
  let v = 0;
  for (const o of Object.values(h.held)) { v += E.orbValue(o); if (o.jackpot) jp[o.jackpot]++; }
  if (h.full) { v += E.JACKPOTS.grand; jp.grand++; }
  holdOrbs += Object.keys(h.held).length;
  holdTrig++;
  return v * bet;
}

for (let i = 0; i < N; i++) {
  wagered += bet;
  const s = E.spin(rng), r = E.evaluate(s.grid, 1);
  let spinWin = r.total;
  lines += r.total;
  if (r.total > 0) hits++;
  if (r.orbs.triggered) { const v = playHold(s.orbs); hold += v; spinWin += v; }
  xp += E.xpGain(rng);
  if (xp >= 1) { xp = 0; levels++; const lv = E.levelUp(rng); const t0 = holdTrig, o0 = holdOrbs; const v = playHold(lv.orbs, lv.buff); holdTrig = t0; holdOrbs = o0; levelPay += v; spinWin += v; }
  let fs = r.scatter.freeSpins;
  if (fs) freeTrig++;
  while (fs > 0) {
    fs--;
    const fsn = E.spin(rng), f = E.evaluate(fsn.grid, 1, E.FREE_SPIN_MULT);
    free += f.total; spinWin += f.total;
    if (f.orbs.triggered) { const v = playHold(fsn.orbs); hold += v; spinWin += v; }
    fs += f.scatter.freeSpins;
  }
  biggest = Math.max(biggest, spinWin);
}
const pct = x => (100 * x / wagered).toFixed(2) + '%';
console.log(`spins             ${N.toLocaleString()}`);
console.log(`payout rate       ${pct(lines + free + hold + levelPay)}`);
console.log(`  base game       ${pct(lines)}`);
console.log(`  free games      ${pct(free)}`);
console.log(`  Faire bonus     ${pct(hold)}`);
console.log(`  level-up bonus  ${pct(levelPay)}  (1 in ${(N / Math.max(1, levels)).toFixed(0)} spins, avg ${(levelPay / Math.max(1, levels) / bet).toFixed(1)}x bet)`);
console.log(`hit frequency     1 in ${(N / hits).toFixed(1)} spins`);
console.log(`free games        1 in ${(N / freeTrig).toFixed(0)} spins`);
console.log(`Faire bonus       1 in ${(N / holdTrig).toFixed(0)} spins, avg ${(hold / holdTrig / bet).toFixed(1)}x bet, avg ${(holdOrbs / holdTrig).toFixed(1)} orbs`);
console.log(`jackpots per 1M   mini ${(jp.mini / N * 1e6).toFixed(0)}, minor ${(jp.minor / N * 1e6).toFixed(0)}, major ${(jp.major / N * 1e6).toFixed(1)}, grand ${(jp.grand / N * 1e6).toFixed(2)}`);
console.log(`biggest win       ${(biggest / bet).toFixed(0)}x bet`);
