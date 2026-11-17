(() => {
  'use strict';
  const E = window.SlotEngine;
  const $ = id => document.getElementById(id);
  const KEY = 'lions-pride-v1';
  const START_CENTS = 10000; // $100.00
  const wait = ms => new Promise(r => setTimeout(r, ms));

  // ---------- state ----------
  const fresh = () => ({
    cents: START_CENTS, denomIdx: 2, betIdx: 0, muted: false, music: true, showCredits: false,
    free: null, // { left, total, played, wonCents } while free games are running
    level: 1, xp: 0.3, // xp is progress through the current level, 0..1
    jackpots: { major: E.JACKPOTS.major, grand: E.JACKPOTS.grand }, // in multiples of the total bet
    stats: { spins: 0, wagered: 0, won: 0, biggest: 0, freeGames: 0, goldRush: 0, levels: 0, mini: 0, minor: 0, major: 0, grand: 0, bills: 0 },
  });
  let state = fresh();
  try {
    const saved = JSON.parse(localStorage.getItem(KEY));
    if (saved) state = { ...fresh(), ...saved, jackpots: { ...fresh().jackpots, ...saved.jackpots }, stats: { ...fresh().stats, ...saved.stats } };
  } catch {}
  const save = () => { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch {} };

  let busy = false, auto = false, cycleTimer = null;
  let hidden = 0;    // cents already banked but not yet shown (paid out during a feature's tally)
  let winShown = 0;  // cents on the WIN meter

  const denom = () => E.DENOMS[state.denomIdx];
  const betMult = () => E.BET_MULTS[state.betIdx];
  const betCredits = () => E.LINES * betMult();
  const betCents = () => betCredits() * denom();
  const inFree = () => !!state.free && state.free.left > 0;
  const jpVals = () => ({ mini: E.JACKPOTS.mini, minor: E.JACKPOTS.minor, major: state.jackpots.major, grand: state.jackpots.grand });
  const money = c => '$' + (c / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const int = n => Math.round(n).toLocaleString('en-US');
  const denomLabel = d => d + '¢';

  // ---------- sound ----------
  const sfx = (() => {
    let ctx;
    const ac = () => (ctx = ctx || new (window.AudioContext || window.webkitAudioContext)());
    function tone(freq, dur, type = 'sine', vol = .05, when = 0, endFreq) {
      if (state.muted) return;
      try {
        const c = ac(), t = c.currentTime + when, o = c.createOscillator(), g = c.createGain();
        o.type = type; o.frequency.setValueAtTime(freq, t);
        if (endFreq) o.frequency.exponentialRampToValueAtTime(endFreq, t + dur);
        g.gain.setValueAtTime(vol, t); g.gain.exponentialRampToValueAtTime(.0001, t + dur);
        o.connect(g).connect(c.destination); o.start(t); o.stop(t + dur + .02);
      } catch {}
    }
    const cache = {};
    const get = src => cache[src] || (cache[src] = Object.assign(new Audio(src), { preload: 'auto' }));
    const path = n => n.includes('/') ? n : `assets/sfx/${n}${n.startsWith('fanfare') ? '.mp3' : '.ogg'}`;
    function play(name, vol = .6, rate = 1) {
      if (state.muted) return null;
      try {
        const a = get(path(name)).cloneNode();
        a.volume = vol; a.preservesPitch = false; a.playbackRate = rate; a.play().catch(() => {});
        return a;
      } catch { return null; }
    }
    let loop = null;
    const loopStop = () => { if (loop) { loop.pause(); loop = null; } };
    function loopStart(name, vol) {
      loopStop();
      if (state.muted) return;
      try { loop = get(path(name)).cloneNode(); loop.loop = true; loop.volume = vol; loop.play().catch(() => {}); } catch {}
    }
    // The count-up tick: a short coin clink, loaded once and replayed cheaply at any pitch.
    let tickBuf = null, tickLoading = false;
    function loadTick() {
      if (tickBuf || tickLoading) return; tickLoading = true;
      fetch('assets/sfx/cointick.ogg').then(r => r.arrayBuffer()).then(b => ac().decodeAudioData(b)).then(buf => { tickBuf = buf; }).catch(() => { tickLoading = false; });
    }
    // Suspense: a rising, quickening whine with a heartbeat under it. Returns a function that cuts it off.
    function riser(ms) {
      if (state.muted) return () => {};
      try {
        const c = ac(), t = c.currentTime, d = ms / 1000;
        const o = c.createOscillator(), g = c.createGain(), f = c.createBiquadFilter(), lfo = c.createOscillator(), lg = c.createGain();
        o.type = 'sawtooth'; o.frequency.setValueAtTime(170, t); o.frequency.exponentialRampToValueAtTime(880, t + d);
        f.type = 'lowpass'; f.frequency.setValueAtTime(900, t); f.frequency.linearRampToValueAtTime(3200, t + d);
        g.gain.setValueAtTime(.015, t); g.gain.linearRampToValueAtTime(.07, t + d);
        lfo.frequency.setValueAtTime(5, t); lfo.frequency.linearRampToValueAtTime(20, t + d); lg.gain.value = .03;
        lfo.connect(lg).connect(g.gain); o.connect(f).connect(g).connect(c.destination);
        o.start(t); lfo.start(t); o.stop(t + d + .05); lfo.stop(t + d + .05);
        for (let at = 0, gap = .36; at < d; at += gap, gap = Math.max(.12, gap * .86)) tone(70, .12, 'sine', .22, at, 40);
        return () => { try { g.gain.cancelScheduledValues(c.currentTime); g.gain.setTargetAtTime(0, c.currentTime, .02); } catch {} };
      } catch { return () => {}; }
    }
    ['bonusroll_loop', 'bonusroll_start', 'bonusroll_end', 'scrollbutton', 'lootcoinsmall', 'lootcoinlarge', 'questaccept'].forEach(n => get(path(n)));
    return {
      play, riser, silence: loopStop,
      // A symbol's sound: one file, or a random pick from a list.
      voice: (sound, vol = .65) => { if (sound) play(Array.isArray(sound) ? sound[Math.floor(Math.random() * sound.length)] : sound, vol); },
      click: () => play('scrollbutton', .5),
      start: () => { play('bonusroll_start', .5); loopStart('bonusroll_loop', .28); },
      reelStop: last => { play('scrollbutton', .7); if (last) { loopStop(); play('bonusroll_end', .4); } },
      // Portal lands: the quest-accepted sound, a touch higher with each one.
      boom: n => play('questaccept', .65, 1 + .06 * (n - 1)),
      questFailed: () => play('questfailed', .5),
      orbLand: n => { play('lootcoinlarge', .65, .9 + .05 * Math.min(n, 8)); tone(520 + 60 * Math.min(n, 8), .18, 'triangle', .07); },
      miss: () => tone(140, .35, 'sawtooth', .05, 0, 60),
      win: x => play(x >= 5 ? 'lootcoinlarge' : 'lootcoinsmall', .7),
      coin: i => play('lootcoinsmall', .5, 1 + .03 * Math.min(i, 12)),
      bank: () => play('moneyopen', .7),
      // Ceremony: a tick for every credit (climbing in pitch), the ba-da-BOOM drum, and the big hit on a tier-up.
      tick(p) {
        if (state.muted) return;
        try {
          const c = ac();
          if (!tickBuf) { loadTick(); tone(900 + 700 * p, .04, 'triangle', .09); return; }
          const s = c.createBufferSource(), g = c.createGain();
          s.buffer = tickBuf; s.playbackRate.value = .85 + .8 * p; g.gain.value = .55;
          s.connect(g).connect(c.destination); s.start();
        } catch {}
      },
      loadTick,
      badaboom: () => { tone(125, .09, 'sine', .22, 0, 85); tone(125, .09, 'sine', .22, .13, 85); tone(78, .5, 'sine', .42, .27, 34); },
      bigBoom: () => { tone(64, .9, 'sine', .5, 0, 28); tone(128, .25, 'triangle', .2, 0, 50); play('levelup', .7); },
      firework: () => { if (Math.random() < .4) play('whistle' + (1 + Math.floor(Math.random() * 2)), .35); play('firework' + (1 + Math.floor(Math.random() * 6)), .6); },
      cheer: () => play('cheer' + (1 + Math.floor(Math.random() * 2)), .6),
    };
  })();

  // ---------- music ----------
  const music = (() => {
    const lists = {
      elwynn: ['assets/music/dayforest01.mp3', 'assets/music/dayforest02.mp3', 'assets/music/dayforest03.mp3'],
      faire: ['assets/music/faire1.mp3', 'assets/music/faire2.mp3'],
    };
    let el = null, mood = 'elwynn', k = 0, duck = 1;
    const vol = () => .3 * duck;
    function load() {
      if (el) el.pause();
      el = new Audio(lists[mood][k % lists[mood].length]); el.volume = vol();
      el.addEventListener('ended', () => { k++; load(); sync(); });
    }
    function sync() {
      const want = state.music && !state.muted;
      if (want && !el) load();
      if (el) want ? el.play().catch(() => {}) : el.pause();
    }
    return {
      sync,
      // Change playlist with a short fade so the music does not cut.
      set(m) {
        if (m === mood) return; mood = m; k = 0;
        if (!el) return;
        const old = el; let v = old.volume;
        const t = setInterval(() => { v -= .03; if (v <= 0 || el !== old) { clearInterval(t); if (el === old) { load(); sync(); } } else old.volume = v; }, 40);
      },
      // Pull the music down while a fanfare plays.
      duck(on) { duck = on ? .25 : 1; if (el) el.volume = vol(); },
    };
  })();

  // ---------- rendering ----------
  function ballHTML(orb) {
    const label = orb.jackpot ? orb.jackpot.toUpperCase() : int(orb.x * betCredits());
    const size = orb.jackpot ? '' : label.length >= 5 ? 's' : label.length === 4 ? 'm' : '';
    return `<div class="ball${orb.jackpot ? ' j-' + orb.jackpot : ''}"><i></i><b class="${size}">${label}</b></div>`;
  }
  function cellHTML(id, orb) {
    const s = E.SYM[id];
    if (s.orb) return `<div class="cell orb" data-sym="orb">${ballHTML(orb || E.rollOrb())}</div>`;
    return `<div class="cell q-${s.quality}" data-sym="${id}"><img src="${s.img}" alt="${s.name}"></div>`;
  }
  const randomCell = () => cellHTML(E.pick());
  // A Darkmoon prize ticket: what lands during the bonus.
  function ticketHTML(orb) {
    const label = orb.jackpot ? orb.jackpot.toUpperCase() : int(orb.x * betCredits());
    return `<div class="tix${orb.jackpot ? ' j-' + orb.jackpot : ''}"><img src="assets/icons/ticket.png" alt="Ticket"><b>${label}</b></div>`;
  }

  // Particles on a canvas over the whole window: firework sparks, and gold coins that
  // burst up out of the reel window, flip as they fly and fall away.
  const fx = (() => {
    const cv = $('fx'), g = cv.getContext('2d');
    const colors = ['#d24bff', '#ff4fd8', '#ffd100', '#7dff7d', '#69ccf0', '#ffffff'];
    const coinImg = new Image(); coinImg.src = 'assets/ui/coin.png';
    let parts = [], running = false, last = 0;
    const size = () => { cv.width = innerWidth; cv.height = innerHeight; };
    addEventListener('resize', size); size();
    function start() { if (!running) { running = true; last = performance.now(); requestAnimationFrame(frame); } }
    function frame(t) {
      const dt = Math.min(2.5, (t - last) / 16.7); last = t;
      g.clearRect(0, 0, cv.width, cv.height);
      parts = parts.filter(p => p.life > 0 && p.y < cv.height + 80);
      for (const p of parts) {
        if (p.coin) {
          p.vy += .34 * dt; p.x += p.vx * dt; p.y += p.vy * dt; p.spin += p.vs * dt; p.rot += p.vr * dt;
          const w = Math.cos(p.spin);
          g.save(); g.translate(p.x, p.y); g.rotate(p.rot); g.scale(w || .02, 1);
          g.globalAlpha = 1; g.drawImage(coinImg, -p.r, -p.r, p.r * 2, p.r * 2);
          g.globalAlpha = (1 - Math.abs(w)) * .5; g.fillStyle = '#3a1f00';   // darker as it turns edge-on
          g.beginPath(); g.arc(0, 0, p.r, 0, 6.3); g.fill();
          g.restore();
        } else {
          p.vx *= Math.pow(.985, dt); p.vy = p.vy * Math.pow(.985, dt) + .045 * dt; p.x += p.vx * dt; p.y += p.vy * dt; p.life -= p.decay * dt;
          g.globalAlpha = Math.max(0, p.life); g.fillStyle = p.col;
          g.beginPath(); g.arc(p.x, p.y, 2.3, 0, 6.3); g.fill();
        }
      }
      g.globalAlpha = 1;
      if (parts.length) requestAnimationFrame(frame); else running = false;
    }
    function burst() {
      const x = innerWidth * (.12 + Math.random() * .76), y = innerHeight * (.08 + Math.random() * .42);
      const col = colors[Math.floor(Math.random() * colors.length)], col2 = colors[Math.floor(Math.random() * colors.length)];
      for (let i = 0; i < 54; i++) {
        const a = Math.random() * Math.PI * 2, v = 1.4 + Math.random() * 4.4;
        parts.push({ x, y, vx: Math.cos(a) * v, vy: Math.sin(a) * v, life: 1, decay: .011 + Math.random() * .012, col: i % 3 ? col : col2 });
      }
      start();
    }
    return {
      fireworks(count = 1, gap = 260, quiet = false) {
        for (let i = 0; i < count; i++) setTimeout(() => { burst(); if (!quiet) sfx.firework(); }, i * gap * (.6 + Math.random() * .8));
      },
      // n coins fountain up from the middle of the reel window over `spread` ms.
      coins(n, spread = 900) {
        const r = machine.getBoundingClientRect(), k = r.width / 560;
        const ox = r.left + r.width / 2, oy = r.top + r.height * .58;
        for (let i = 0; i < n; i++) setTimeout(() => {
          const a = -Math.PI / 2 + (Math.random() - .5) * 1.5, v = (9 + Math.random() * 8) * k;
          parts.push({ coin: true, life: 1, x: ox + (Math.random() - .5) * 70 * k, y: oy, vx: Math.cos(a) * v * .8, vy: Math.sin(a) * v,
            r: (10 + Math.random() * 10) * k, spin: Math.random() * 6, vs: .16 + Math.random() * .22, rot: Math.random() * 6, vr: (Math.random() - .5) * .06 });
          start();
        }, Math.random() * spread);
      },
    };
  })();
  const fireworks = fx.fireworks, coinShower = (n, spread) => fx.coins(n, spread);

  const reelsEl = $('reels'), holdEl = $('hold'), machine = $('machine');
  reelsEl.innerHTML = Array.from({ length: E.REELS }, () => '<div class="reel"><div class="strip"></div></div>').join('');
  const reels = [...reelsEl.children];
  let lastHTML = reels.map(() => Array.from({ length: E.ROWS }, randomCell));
  reels.forEach((r, i) => { r.firstChild.innerHTML = lastHTML[i].join(''); });
  const cellAt = (reel, row) => reels[reel].firstChild.children[row];

  function animateReel(i, finalCol, duration, slow) {
    return new Promise(resolve => {
      const reel = reels[i], strip = reel.firstChild;
      const filler = Array.from({ length: Math.round(duration * .024) }, randomCell);
      const cells = [...finalCol, ...filler, ...lastHTML[i]];
      strip.innerHTML = cells.join('');
      const h = reel.clientHeight / E.ROWS;
      strip.style.transition = 'none';
      strip.style.transform = `translateY(${-(cells.length - E.ROWS) * h}px)`;
      void strip.offsetHeight;
      strip.style.transition = `transform ${duration}ms ${slow ? 'cubic-bezier(.3,.45,.4,1)' : 'cubic-bezier(.12,.55,.25,1)'}`;
      strip.style.transform = 'translateY(0)';
      let finished = false;
      const done = () => {
        if (finished) return; finished = true;
        strip.style.transition = 'none'; strip.style.transform = 'none';
        strip.innerHTML = finalCol.join('');
        reel.classList.remove('land'); void reel.offsetWidth; reel.classList.add('land');
        resolve();
      };
      strip.addEventListener('transitionend', done, { once: true });
      setTimeout(done, duration + 150); // in case transitionend never fires (hidden tab)
    });
  }

  function clearWins() {
    clearInterval(cycleTimer); cycleTimer = null;
    $('lines').innerHTML = '';
    reelsEl.querySelectorAll('.cell').forEach(c => c.classList.remove('win', 'dim', 'slam', 'hot'));
  }
  function linePoints(win) {
    const box = $('lines').getBoundingClientRect(), k = box.width / $('lines').clientWidth || 1;
    return E.PAYLINES[win.line].map((row, reel) => {
      const r = cellAt(reel, row).getBoundingClientRect();
      return `${(r.left - box.left + r.width / 2) / k},${(r.top - box.top + r.height / 2) / k}`;
    }).join(' ');
  }
  function highlight(cells) {
    reelsEl.querySelectorAll('.cell').forEach(c => { c.classList.remove('win'); c.classList.add('dim'); });
    cells.forEach(([reel, row]) => { const c = cellAt(reel, row); c.classList.remove('dim'); c.classList.add('win'); });
  }
  function showWins(ev) {
    const svg = $('lines');
    svg.setAttribute('viewBox', `0 0 ${svg.clientWidth} ${svg.clientHeight}`);
    const d = denom();
    const items = ev.wins.map(w => ({
      cells: w.cells, poly: `<polyline points="${linePoints(w)}"/>`,
      text: `Line ${w.line + 1} · ${w.count}× ${E.SYM[w.symbol].name} · ${money(w.amount * d)}`,
    }));
    if (ev.scatter.win) items.push({ cells: ev.scatter.cells, poly: '', text: `${ev.scatter.count}× Portal · ${money(ev.scatter.win * d)}` });
    if (!items.length) return;
    highlight(items.flatMap(i => i.cells));
    svg.innerHTML = items.map(i => i.poly).join('');
    setStatus(items.length === 1 ? items[0].text : `${items.length} winning lines`);
    if (items.length < 2) return;
    let k = -1;
    cycleTimer = setInterval(() => {
      k = (k + 1) % items.length;
      highlight(items[k].cells); svg.innerHTML = items[k].poly; setStatus(items[k].text);
    }, 1100);
  }

  const setStatus = text => { $('status').textContent = text; };
  // Resting status line: the small legend of what triggers each bonus.
  function idleStatus() {
    $('status').innerHTML = `<span><img src="assets/icons/orb.png" alt="Gold Orb">×${E.HOLD.trigger} <b>Bonus Reels</b>` +
      `<img src="assets/icons/portal.png" alt="Portal">×3 <b>${E.SCATTER_SPINS[3]} Free Games</b></span>`;
  }
  // The XP bar. It is drawn on a curve (see LEVEL.curve in engine.js) so it spends most of its time looking nearly full.
  function updateXP() {
    const shown = E.xpShown(state.xp);
    $('xpFill').style.width = (shown * 100).toFixed(1) + '%';
    $('xpBox').classList.toggle('hot', shown >= .9);
  }
  function countTo(el, from, to, ms, fmt) {
    const t0 = performance.now();
    const step = t => {
      const p = Math.min(1, (t - t0) / ms);
      el.textContent = fmt(from + (to - from) * (1 - Math.pow(1 - p, 3)));
      if (p < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }
  const meterText = c => state.showCredits ? int(Math.floor(c / denom())) : money(c);
  function setWin(cents, animate = true) {
    const from = winShown; winShown = cents;
    if (animate && cents > from) {
      countTo($('win'), from, cents, 600, meterText);
      const m = $('winMeter'); m.classList.remove('won'); void m.offsetWidth; m.classList.add('won');
    } else $('win').textContent = meterText(cents);
  }

  function panel(mode, title = '', amount = '', tag = '') {
    const p = $('panel');
    p.dataset.mode = mode;
    $('pTitle').textContent = title; $('pAmount').textContent = amount; $('pTag').textContent = tag;
    p.classList.remove('pop'); void p.offsetWidth; if (mode !== 'idle') p.classList.add('pop');
  }
  function bumpTag(text) {
    const t = $('pTag'); t.textContent = text;
    t.classList.remove('bump'); void t.offsetWidth; t.classList.add('bump');
  }
  function restingPanel() {
    if (inFree()) panel('feature', 'Free Games', '', `${state.free.played} of ${state.free.total} · wins ×${E.FREE_SPIN_MULT}`);
    else panel('idle');
  }

  // Small wins: banner, quick count, a sound.
  // Big wins (15x the bet and up): the full ceremony below.
  async function celebrate(cents, title) {
    const x = cents / betCents();
    if (x >= 15) return ceremony(cents, title);
    title = title || 'Winner';
    panel('win', title, money(0));
    countTo($('pAmount'), 0, cents, 1500, money);
    music.duck(true);
    sfx.play(x >= 10 ? 'fanfare' : 'levelup', .75);
    coinShower(Math.min(70, Math.round(12 + x)));
    if (document.body.classList.contains('faire')) { fireworks(9, 320); sfx.cheer(); }
    await wait(x >= 10 ? 4200 : 2800);
    music.duck(false);
  }

  // The big-win ceremony. Every credit is counted one at a time with a tick, a ba-da-BOOM drum keeps
  // the beat, and the title climbs Big Win -> Epic Win -> Legendary Win as the count passes each mark.
  // Space or a click jumps to the end.
  const TIERS = [{ x: 0, name: 'Big Win' }, { x: 40, name: 'Epic Win' }, { x: 100, name: 'Legendary Win' }];
  async function ceremony(cents, title) {
    const d = denom(), bet = betCents(), x = cents / bet, credits = Math.round(cents / d);
    const box = $('ceremony');
    const duration = Math.min(26000, 6000 + 150 * x);            // 15x ~8s, 50x ~13s, 130x+ ~26s
    const perStep = Math.max(1, Math.ceil(credits / (duration / 1000 * 30))); // one credit a tick when the count allows it
    const setTitle = name => { const t = $('cTitle'); t.textContent = name; t.classList.remove('pop'); void t.offsetWidth; t.classList.add('pop'); };
    const thud = () => { machine.classList.remove('thud'); void machine.offsetWidth; machine.classList.add('thud'); };
    let tier = 0, shown = -1, skip = false, lastTick = 0, lastBeat = -1;
    const onSkip = e => { if (e.type === 'keydown' && e.code !== 'Space') return; skip = true; };

    clearInterval(cycleTimer); cycleTimer = null;
    panel('win', title || 'Winner', '', '');
    setTitle(title && x < TIERS[1].x ? title : TIERS[0].name);
    $('cAmount').textContent = money(0); $('cCredits').textContent = '0 credits';
    box.classList.add('on');
    music.duck(true);
    sfx.loadTick(); sfx.bigBoom(); thud(); coinShower(16, 500);
    await wait(900);
    addEventListener('keydown', onSkip); box.addEventListener('pointerdown', onSkip);

    // Fireworks and coins keep going for the whole count.
    let volley = 0;
    const show = setInterval(() => { if (!skip) { fireworks(1, 0, volley++ % 3 !== 0); coinShower(6, 380); } }, 400);
    const t0 = performance.now();
    await new Promise(resolve => {
      const timer = setInterval(() => {
        const t = performance.now() - t0, p = skip ? 1 : Math.min(1, t / duration);
        const eased = 1 - Math.pow(1 - p, 1.5);                      // slows down as it nears the total
        const c = p >= 1 ? credits : Math.min(credits, Math.floor(eased * credits / perStep) * perStep);
        if (c !== shown) {
          shown = c;
          $('cAmount').textContent = money(c * d);
          $('cCredits').textContent = `${int(c)} credit${c === 1 ? '' : 's'}`;
          if (t - lastTick > 55 && !skip) { lastTick = t; sfx.tick(p); }
        }
        const beat = Math.floor(t / 900);
        if (beat !== lastBeat && !skip) {
          lastBeat = beat; sfx.badaboom();
          setTimeout(() => { if (!skip) { const a = $('cAmount'); a.classList.remove('thump'); void a.offsetWidth; a.classList.add('thump'); } }, 270);
        }
        while (tier + 1 < TIERS.length && c * d / bet >= TIERS[tier + 1].x) {
          tier++; setTitle(TIERS[tier].name);
          if (!skip) { sfx.bigBoom(); thud(); fireworks(5, 160); coinShower(36, 700); }
        }
        if (p >= 1) { clearInterval(timer); clearInterval(show); resolve(); }
      }, 16);
    });
    removeEventListener('keydown', onSkip); box.removeEventListener('pointerdown', onSkip);

    // Finale.
    $('cAmount').textContent = money(cents); $('cCredits').textContent = `${int(credits)} credits`;
    $('pAmount').textContent = money(cents);
    setTitle(TIERS[tier].name);
    sfx.badaboom(); setTimeout(() => { sfx.bigBoom(); thud(); }, 420);
    sfx.play(x >= TIERS[1].x ? 'fanfare_long' : 'fanfare', .8);
    setTimeout(() => sfx.voice(['assets/sfx/human_outstanding.ogg', 'assets/sfx/human_excellent.ogg'], .85), 900);
    coinShower(90, 2200); fireworks(x >= TIERS[1].x ? 22 : 14, 260); sfx.cheer();
    await wait(x >= TIERS[1].x ? 6500 : 4200);
    box.classList.remove('on');
    music.duck(false);
  }

  function updateJackpots() {
    const b = betCents(), j = jpVals();
    $('jpGrand').textContent = money(Math.round(j.grand * b));
    $('jpMajor').textContent = money(Math.round(j.major * b));
    $('jpMinor').textContent = money(j.minor * b);
    $('jpMini').textContent = money(j.mini * b);
  }
  function updateUI() {
    const locked = busy || inFree();
    $('credit').textContent = meterText(state.cents - hidden);
    $('bet').textContent = meterText(betCents());
    $('win').textContent = meterText(winShown);
    $('denomVal').textContent = denomLabel(denom());
    $('minBet').textContent = `MIN BET ${E.LINES}`;
    $('denomBtn').disabled = locked;
    document.querySelectorAll('.betbtn').forEach((b, i) => { b.classList.toggle('sel', i === state.betIdx); b.disabled = locked; });
    $('spinBtn').disabled = locked;
    $('spinBtn').textContent = inFree() ? state.free.left : 'SPIN';
    $('autoBtn').classList.toggle('on', auto);
    $('musicBtn').classList.toggle('on', !!state.music);
    $('muteBtn').textContent = state.muted ? '🔇' : '🔊';
    machine.classList.toggle('free', !!state.free);
    updateJackpots(); updateXP();
  }

  // ---------- Darkmoon Faire bonus (hold and spin) ----------
  async function goldRush(startOrbs, buff = {}) {
    const bc = betCredits(), d = denom(), jp = jpVals();
    const play = E.playHold(startOrbs, Math.random, buff);
    const creditsOf = orb => Math.round(E.orbValue(orb, jp) * bc);

    // Bank the whole result first so a reload mid-feature can't lose it; reveal it during the tally.
    let credits = 0;
    for (const o of Object.values(play.held)) { credits += creditsOf(o); if (o.jackpot) state.stats[o.jackpot]++; }
    const grandCredits = play.full ? Math.round(jp.grand * bc) : 0;
    credits += grandCredits;
    const cents = credits * d;
    state.cents += cents; hidden += cents;
    state.stats.won += cents; state.stats.goldRush++;
    if (Object.values(play.held).some(o => o.jackpot === 'major')) state.jackpots.major = E.JACKPOTS.major;
    if (play.full) { state.jackpots.grand = E.JACKPOTS.grand; state.stats.grand++; }
    save();

    // Set the stage.
    clearWins();
    music.set('faire');
    if (!buff.id) sfx.play('levelup', .7);
    document.body.classList.add('faire');
    machine.classList.add('rush');
    fireworks(6, 300); sfx.cheer();
    panel('feature', 'Darkmoon Faire', '', `${play.respins} SPINS LEFT`);
    setStatus(buff.id ? `${buff.name}: ${buff.desc}` : 'The Faire is in town! Win tickets: each new one resets your spins.');
    const held = { ...startOrbs };
    holdEl.innerHTML = '';
    const hcell = {};
    for (let row = 0; row < E.ROWS; row++) for (let reel = 0; reel < E.REELS; reel++) {
      const k = E.key(reel, row), el = document.createElement('div');
      el.className = 'hcell' + (held[k] ? ' locked' : '');
      if (held[k]) el.innerHTML = ballHTML(held[k]);
      holdEl.appendChild(el); hcell[k] = el;
    }
    await wait(1100); // let the Faire fade in before the board appears
    holdEl.classList.add('on');
    let count = Object.keys(held).length;
    await wait(1500);

    for (const round of play.rounds) {
      const landing = Object.fromEntries(round.landed.map(l => [E.key(l.reel, l.row), l.orb]));
      const empties = [];
      for (let reel = 0; reel < E.REELS; reel++) for (let row = 0; row < E.ROWS; row++) {
        const k = E.key(reel, row);
        if (!held[k]) empties.push(k);
      }
      empties.forEach(k => hcell[k].classList.add('spinning'));
      setStatus(`${count} prizes locked`);
      sfx.start();
      await wait(700);
      for (let i = 0; i < empties.length; i++) {
        const k = empties[i], el = hcell[k];
        // One spot from the Grand: make them sweat.
        if (count === E.REELS * E.ROWS - 1) {
          el.classList.add('suspense'); setStatus('One more for the GRAND…');
          const cut = sfx.riser(2600); await wait(2600); cut(); el.classList.remove('suspense');
        } else await wait(150);
        el.classList.remove('spinning');
        if (landing[k]) {
          held[k] = landing[k]; count++;
          el.classList.add('locked', 'slam'); el.innerHTML = ticketHTML(landing[k]);
          sfx.orbLand(count); sfx.play('fairebell', .4); fireworks(landing[k].jackpot ? 4 : 1);
          if (landing[k].jackpot) { sfx.play('success_stinger', .7); flashJackpot(landing[k].jackpot); await wait(500); }
        }
      }
      sfx.silence();
      if (round.landed.length) { bumpTag(`${round.left} SPINS LEFT`); setStatus(`New ticket! Spins reset to ${play.respins}`); }
      else { $('pTag').textContent = round.left === 1 ? 'LAST SPIN' : `${round.left} SPINS LEFT`; if (round.left === 0) sfx.miss(); }
      await wait(round.landed.length ? 1100 : 650);
      Object.values(hcell).forEach(el => el.classList.remove('slam'));
    }

    // Tally: every orb pays into the total, one at a time.
    setStatus(play.full ? 'Full board!' : 'Cashing in your prizes');
    panel('feature', 'Darkmoon Faire', money(0), '');
    let run = 0, n = 0;
    for (let reel = 0; reel < E.REELS; reel++) for (let row = 0; row < E.ROWS; row++) {
      const k = E.key(reel, row), orb = held[k];
      if (!orb) continue;
      const ball = hcell[k].firstElementChild;
      ball.classList.add('collect');
      run += creditsOf(orb) * d;
      $('pAmount').textContent = money(run);
      if (orb.jackpot) {
        const label = orb.jackpot === 'major' ? 'MAJOR JACKPOT' : orb.jackpot.toUpperCase() + ' BONUS';
        $('pTag').textContent = `${label} · ${money(creditsOf(orb) * d)}`;
        flashJackpot(orb.jackpot);
        sfx.play(orb.jackpot === 'major' ? 'fanfare' : orb.jackpot === 'minor' ? 'legendary' : 'epicloot', .75);
        await wait(orb.jackpot === 'major' ? 4500 : 2200);
        $('pTag').textContent = '';
      } else { sfx.coin(n++); await wait(240); }
    }
    if (play.full) {
      run += grandCredits * d;
      $('pTag').textContent = `GRAND JACKPOT · ${money(grandCredits * d)}`;
      $('pAmount').textContent = money(run);
      flashJackpot('grand'); coinShower(70); fireworks(20, 350);
      music.duck(true); sfx.play('fanfare_long', .8); await wait(8000); music.duck(false);
    }
    await celebrate(cents, 'Winner');
    hidden -= cents;
    setWin(winShown + cents);
    updateUI();

    holdEl.classList.add('leaving'); await wait(500);
    holdEl.classList.remove('on', 'leaving'); holdEl.innerHTML = '';
    machine.classList.remove('rush');
    document.body.classList.remove('faire');
    music.set('elwynn');
    return cents;
  }
  // Level up: DING, a buff, and straight into the Darkmoon Faire.
  async function levelUpBonus() {
    state.level++; state.xp = .1 + Math.random() * .12; state.stats.levels++;
    const lv = E.levelUp();
    save();
    clearWins();
    sfx.play('levelup', .85); fireworks(5, 280);
    const box = $('xpBox'); box.classList.remove('ding'); void box.offsetWidth; box.classList.add('ding');
    $('xpFill').style.width = '100%';
    setStatus('Level up!');
    await wait(1100);
    panel('feature', `Level ${state.level}!`, '', `${lv.buff.name}: ${lv.buff.desc}`);
    setStatus('Level up! The Darkmoon Faire opens with a buff');
    setTimeout(() => sfx.voice(['assets/sfx/human_outstanding.ogg', 'assets/sfx/human_excellent.ogg'], .8), 300);
    await wait(3000);
    return goldRush(lv.orbs, lv.buff);
  }

  function flashJackpot(kind) {
    const el = $({ mini: 'jpMiniBox', minor: 'jpMinorBox', major: 'jpMajorBox', grand: 'jpGrandBox' }[kind]);
    el.classList.remove('hit'); void el.offsetWidth; el.classList.add('hit');
  }

  // ---------- one spin ----------
  async function spin() {
    if (busy) return;
    const free = inFree(), bet = betCents(), d = denom();
    if (!free) {
      if (state.cents - hidden < bet) {
        auto = false; setStatus('Not enough credit. Insert a bill to keep playing.'); sfx.play('human_forgetsomething', .7);
        const b = $('billBtn'); b.classList.remove('nudge'); void b.offsetWidth; b.classList.add('nudge');
        updateUI(); return;
      }
      state.cents -= bet;
      state.stats.wagered += bet; state.stats.spins++;
      state.jackpots.major += E.JACKPOT_GROWTH.major; state.jackpots.grand += E.JACKPOT_GROWTH.grand;
      state.xp = Math.min(1, state.xp + E.xpGain());
      setWin(0, false);
    } else {
      state.free.left--; state.free.played++;
    }
    busy = true;
    clearWins();
    restingPanel();
    setStatus(free ? `Free game ${state.free.played} of ${state.free.total}` : 'Good luck!');
    save(); updateUI();
    sfx.start();

    const res = E.spin();
    const ev = E.evaluate(res.grid, betMult(), free ? E.FREE_SPIN_MULT : 1);
    const finalHTML = res.grid.map((col, reel) => col.map((id, row) => cellHTML(id, res.orbs[E.key(reel, row)])));
    const isScatter = id => E.SYM[id].scatter, isOrb = id => E.SYM[id].orb;

    // Work out when each reel stops. A reel that could complete a feature spins on, in suspense.
    const plan = [];
    for (let i = 0, t = 650, scat = 0, orbs = 0; i < E.REELS; i++) {
      const tease = i === 0 ? null : scat === 2 ? 'scatter' : (orbs >= E.HOLD.trigger - 2 && orbs < E.HOLD.trigger) ? 'orb' : null;
      t += i === 0 ? 0 : tease ? 1900 : 240;
      plan.push({ t, tease, scatBefore: scat, orbsBefore: orbs });
      scat += res.grid[i].filter(isScatter).length; orbs += res.grid[i].filter(isOrb).length;
    }

    let cutRiser = null;
    await Promise.all(res.grid.map((col, i) => animateReel(i, finalHTML[i], plan[i].t, !!plan[i].tease).then(() => {
      const p = plan[i], next = plan[i + 1];
      reels[i].classList.remove('antic');
      if (cutRiser) { cutRiser(); cutRiser = null; }
      sfx.reelStop(i === E.REELS - 1);
      let s = p.scatBefore, o = p.orbsBefore;
      col.forEach((id, row) => {
        if (isScatter(id)) { s++; cellAt(i, row).classList.add('slam'); sfx.boom(s); }
        if (isOrb(id)) { o++; cellAt(i, row).classList.add('slam'); sfx.orbLand(o); }
      });
      if (p.tease && ((p.tease === 'scatter' && s === p.scatBefore) || (p.tease === 'orb' && o === p.orbsBefore)) && !(next && next.tease)) (p.tease === 'scatter' ? sfx.questFailed : sfx.miss)();
      if (next && next.tease) {
        reels[i + 1].classList.add('antic');
        // Light up what has landed so far so the eye knows what it is waiting for.
        for (let r = 0; r <= i; r++) res.grid[r].forEach((id, row) => {
          if ((next.tease === 'scatter' && isScatter(id)) || (next.tease === 'orb' && isOrb(id))) cellAt(r, row).classList.add('hot');
        });
        setStatus(next.tease === 'scatter' ? 'One more Portal for Free Games…' : `${E.HOLD.trigger - o} more for the Darkmoon Faire…`);
        cutRiser = sfx.riser(next.t - p.t);
      }
    })));
    lastHTML = finalHTML;
    reelsEl.querySelectorAll('.hot').forEach(c => c.classList.remove('hot'));

    // Line and scatter pays.
    let spinCents = ev.total * d;
    if (ev.total > 0) {
      state.cents += spinCents; state.stats.won += spinCents;
      const big = spinCents >= bet * 15;
      if (big) hidden += spinCents; else setWin(winShown + spinCents);
      updateUI();
      showWins(ev);
      if (!big) sfx.win(spinCents / bet);
      // The best line's symbol makes its sound; if a wild helped, the Alliance speaks too.
      const best = ev.wins.slice().sort((a, b) => b.amount - a.amount)[0];
      if (best) {
        const wild = E.SYMBOLS.find(s => s.wild);
        sfx.voice(E.SYM[best.symbol].sound, .65);
        if (best.symbol !== wild.id && best.cells.some(([reel, row]) => res.grid[reel][row] === wild.id)) setTimeout(() => sfx.voice(wild.sound, .65), 800);
      }
      if (big) { await wait(1300); await celebrate(spinCents); hidden -= spinCents; setWin(winShown + spinCents); updateUI(); restingPanel(); }
    } else if (!ev.orbs.triggered && !ev.scatter.freeSpins && state.xp < 1) { if (free) setStatus(`Free game ${state.free.played} of ${state.free.total}`); else idleStatus(); }

    // Features.
    if (ev.orbs.triggered) {
      await wait(ev.total > 0 ? 1200 : 500);
      spinCents += await goldRush(res.orbs);
      restingPanel(); if (!state.free) idleStatus();
    }
    // A full XP bar pops after everything else on this spin has paid.
    if (state.xp >= 1) {
      await wait(ev.total > 0 && !ev.orbs.triggered ? 1400 : 500);
      spinCents += await levelUpBonus();
      restingPanel(); updateXP(); if (!state.free) idleStatus();
    }
    if (ev.scatter.freeSpins) {
      const n = ev.scatter.freeSpins;
      if (state.free && state.free.left >= 0 && free) { state.free.left += n; state.free.total += n; }
      else state.free = { left: n, total: n, played: 0, wonCents: 0 };
      state.stats.freeGames++;
      panel('feature', 'Free Games', '', `${free ? '+' : ''}${n} FREE GAMES · wins ×${E.FREE_SPIN_MULT}`);
      setStatus(`${ev.scatter.count} Portals!`);
      sfx.play('questcomplete', .7);
      await wait(3200);
    }
    if (state.free) state.free.wonCents += free || ev.scatter.freeSpins ? spinCents : 0;
    state.stats.biggest = Math.max(state.stats.biggest, spinCents);

    // Free games finished: show the total.
    let ended = false;
    if (state.free && state.free.left === 0) {
      const total = state.free.wonCents;
      state.free = null; ended = true;
      clearWins(); setStatus('Free Games completed');
      machine.classList.remove('free');
      if (total > 0) await celebrate(total, 'Winner'); else { panel('feature', 'Free Games', '', 'COMPLETED'); await wait(1800); }
      panel('idle');
    }
    busy = false;
    save(); updateUI();

    if (inFree()) setTimeout(spin, ev.total ? 1500 : 650);
    else if (auto) setTimeout(() => auto && spin(), ended ? 1200 : ev.total ? 1400 : 450);
  }

  // ---------- dialogs ----------
  function renderRules() {
    const bm = betMult(), d = denom();
    $('payNote').textContent = `Wins pay left to right on ${E.LINES} lines, only the best win on each line. Shown at your current bet of ${money(betCents())}.`;
    const art = s => `<img src="${s.img}" alt="">`;
    const rows = E.SYMBOLS.filter(s => s.pays).slice().reverse().map(s =>
      `<tr class="q-${s.quality}"><td>${art(s)}</td><td class="qname">${s.name}${s.wild ? ' <span class="small">(wild)</span>' : ''}</td>` +
      [3, 4, 5].map(n => `<td class="num">${n}× ${money(s.pays[n] * bm * d)}</td>`).join('') + '</tr>');
    const sc = E.SYMBOLS.find(s => s.scatter);
    rows.push(`<tr class="q-${sc.quality}"><td>${art(sc)}</td><td class="qname">${sc.name} <span class="small">(anywhere)</span></td>` +
      [3, 4, 5].map(n => `<td class="num">${n}× ${money(E.SCATTER_PAYS[n] * betCents())}</td>`).join('') + '</tr>');
    $('payTable').innerHTML = rows.join('');
    const wild = E.SYMBOLS.find(s => s.wild);
    $('rushNote').textContent = `${E.HOLD.trigger} or more Gold Orbs anywhere open the Darkmoon Faire. The orbs lock in place and you get ${E.HOLD.respins} respins of the empty spots. Any prize ticket that lands locks too and resets the respins to ${E.HOLD.respins}. When the respins run out, every orb and ticket pays the credits shown on it. Tickets can also carry the Mini, Minor or Major. Fill all 15 spots to win the Grand.`;
    $('levelNote').textContent = `Every paid spin earns experience. When the bar fills you level up, and the Darkmoon Faire opens at once with ${E.LEVEL.startOrbs} orbs and one buff: ${E.LEVEL_BUFFS.map(b => `${b.name} (${b.desc.toLowerCase()})`).join(', ')}. It takes about ${E.LEVEL.spins} spins a level on average.`;
    $('freeNote').textContent = `3, 4 or 5 Portals anywhere win ${E.SCATTER_SPINS[3]}, ${E.SCATTER_SPINS[4]} or ${E.SCATTER_SPINS[5]} free games. All line wins in free games are multiplied by ${E.FREE_SPIN_MULT}, and more Portals add more games. ${wild.name} is wild and substitutes for everything except Portals and Gold Orbs.`;
    $('jpNote').textContent = `Mini pays ${E.JACKPOTS.mini}× and Minor ${E.JACKPOTS.minor}× your total bet. Major starts at ${E.JACKPOTS.major}× and Grand at ${int(E.JACKPOTS.grand)}× your total bet, and both grow a little with every spin until someone (you) wins them. All four scale with your bet and denomination.`;
  }
  function renderStats() {
    const s = state.stats;
    const rows = [['Spins', int(s.spins)], ['Wagered', money(s.wagered)], ['Won', money(s.won)],
      ['Return', s.wagered ? (100 * s.won / s.wagered).toFixed(1) + '%' : '—'], ['Biggest win', money(s.biggest)],
      ['Level', int(state.level)], ['Darkmoon Faire bonuses', int(s.goldRush)], ['of which from level-ups', int(s.levels)], ['Free Games bonuses', int(s.freeGames)],
      ['Mini / Minor / Major / Grand', `${s.mini} / ${s.minor} / ${s.major} / ${s.grand}`], ['Bills inserted', money(s.bills)]];
    $('statsList').innerHTML = rows.map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join('');
  }
  function renderDenoms() {
    $('denomChoices').innerHTML = E.DENOMS.map((d, i) =>
      `<button class="chip${i === state.denomIdx ? ' sel' : ''}" data-denom="${i}"><b>${denomLabel(d)}</b><small>bets ${money(E.LINES * d)} to ${money(E.LINES * d * E.BET_MULTS[E.BET_MULTS.length - 1])}</small></button>`).join('');
  }
  document.querySelectorAll('[data-close]').forEach(b => b.addEventListener('click', () => b.closest('dialog').close()));

  // ---------- controls ----------
  $('bets').innerHTML = E.BET_MULTS.map((m, i) => `<button class="betbtn" data-bet="${i}"><small>BET</small><b>${E.LINES * m}</b></button>`).join('');
  $('bets').addEventListener('click', e => {
    const b = e.target.closest('[data-bet]'); if (!b || b.disabled) return;
    state.betIdx = +b.dataset.bet; sfx.click(); save(); updateUI();
  });
  $('spinBtn').addEventListener('click', spin);
  $('autoBtn').addEventListener('click', () => { auto = !auto; sfx.click(); updateUI(); if (auto && !busy && !inFree()) spin(); });
  $('muteBtn').addEventListener('click', () => { state.muted = !state.muted; if (state.muted) sfx.silence(); music.sync(); save(); updateUI(); });
  $('musicBtn').addEventListener('click', () => { state.music = !state.music; music.sync(); save(); updateUI(); });
  $('rulesBtn').addEventListener('click', () => { renderRules(); $('rulesDialog').showModal(); });
  $('statsBtn').addEventListener('click', () => { renderStats(); $('statsDialog').showModal(); });
  $('denomBtn').addEventListener('click', () => { renderDenoms(); $('denomDialog').showModal(); });
  $('denomChoices').addEventListener('click', e => {
    const b = e.target.closest('[data-denom]'); if (!b) return;
    state.denomIdx = +b.dataset.denom; sfx.click(); save(); updateUI(); $('denomDialog').close();
  });
  $('billBtn').addEventListener('click', () => $('billDialog').showModal());
  $('billDialog').addEventListener('click', e => {
    const b = e.target.closest('[data-bill]'); if (!b) return;
    const c = +b.dataset.bill;
    state.cents += c; state.stats.bills += c; sfx.bank(); setTimeout(() => sfx.play('human_buyandtrade', .7), 350);
    setStatus(`${money(c)} inserted`); save(); updateUI(); $('billDialog').close();
  });
  $('creditMeter').addEventListener('click', () => { state.showCredits = !state.showCredits; save(); updateUI(); });
  $('resetBtn').addEventListener('click', () => {
    if (busy || !confirm('Reset credit, jackpots and stats?')) return;
    const keep = { muted: state.muted, music: state.music };
    state = { ...fresh(), ...keep }; auto = false; hidden = 0; winShown = 0;
    save(); renderStats(); panel('idle'); updateUI(); setStatus('Fresh start');
  });
  document.addEventListener('keydown', e => {
    if (e.code === 'Space' && !document.querySelector('dialog[open]')) { e.preventDefault(); if (!inFree()) spin(); }
  });
  // Browsers only allow music after a click or key press, so start it on the first one.
  const startMusic = () => { music.sync(); removeEventListener('pointerdown', startMusic); removeEventListener('keydown', startMusic); };
  addEventListener('pointerdown', startMusic); addEventListener('keydown', startMusic);

  // Scale the 600 x 1034 machine to fit the window.
  const STAGE_H = 1034;
  function fit() {
    const s = Math.min(innerWidth / 600, innerHeight / STAGE_H);
    const stage = $('stage');
    stage.style.transform = `scale(${s})`;
    stage.style.top = Math.max(0, (innerHeight - STAGE_H * s) / 2) + 'px';
  }
  addEventListener('resize', fit); fit();

  restingPanel();
  updateUI();
  idleStatus();
  // Resume free games interrupted by a reload.
  if (inFree()) { setStatus(`Resuming free games · ${state.free.left} left`); setTimeout(spin, 1500); }
})();
