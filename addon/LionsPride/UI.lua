-- Lion's Pride Casino: the game flow, the controls and the chat commands.
-- Open with /slots, /casino or /lionspride. Play money only: this addon never touches gold, items or trade.
-- Drawing, animation and sound live in View.lua.

local ADDON, ns = ...
local E, UI, S, V, A = ns.Engine, ns.UI, ns.S, ns.V, ns.A

local floor, min, max, random = math.floor, math.min, math.max, math.random
local Money, Commas, SFX = V.Money, V.Commas, A.SFX

-- ---------------------------------------------------------------- saved data
local DEFAULTS = {
  cents = 10000,            -- $100.00 of play money
  denomIdx = 3, betIdx = 1,
  muted = false, music = false, scale = 0.85,
  stopAutoInCombat = true,  -- turn auto-spin off when combat or a pet battle starts
  hideInCombat = false,     -- close the window when combat or a pet battle starts, reopen it afterwards
  minimap = { hide = false, angle = 215 }, -- the minimap button and where it sits on the rim, in degrees
  schema = 2,               -- settings layout version, for carrying old saves forward
  pos = nil,                -- { point, relativePoint, x, y } once the window has been dragged
  free = nil,               -- { left, total, played, wonCents } while free games are running
  level = 1, xp = 0.3,      -- xp is progress through the current level, 0..1
  jackpots = { major = E.JACKPOTS.major, grand = E.JACKPOTS.grand }, -- in multiples of the total bet
  stats = { spins = 0, wagered = 0, won = 0, biggest = 0, bonuses = 0, levels = 0, bills = 0 },
}
local db

local function CopyDefaults(src, dst)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      CopyDefaults(v, dst[k])
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

local G = {} -- game flow
local function Denom() return E.DENOMS[db.denomIdx] end
local function BetMult() return E.BET_MULTS[db.betIdx] end
local function BetCredits() return E.LINES * BetMult() end
local function BetCents() return BetCredits() * Denom() end
local function InFree() return db.free ~= nil and db.free.left > 0 end
local function JackpotValues()
  return { mini = E.JACKPOTS.mini, minor = E.JACKPOTS.minor, major = db.jackpots.major, grand = db.jackpots.grand }
end

-- ---------------------------------------------------------------- sequencing
-- The game flow is written as straight-line code inside a coroutine; Wait() pauses it.
local function OnFlowError(err)
  S.busy, S.auto = false, false
  geterrorhandler()(err)
end
local function Wait(seconds)
  local co = coroutine.running()
  C_Timer.After(seconds, function()
    local ok, err = coroutine.resume(co)
    if not ok then OnFlowError(err) end
  end)
  coroutine.yield()
end
local function Run(fn, ...)
  local co = coroutine.create(fn)
  local ok, err = coroutine.resume(co, ...)
  if not ok then OnFlowError(err) end
end

-- ---------------------------------------------------------------- readouts
local function SetStatus(text) UI.status:SetText(text or "") end
local function IdleStatus()
  SetStatus(E.HOLD.trigger .. " Gold Orbs: Bonus Reels   |   3 Portals: " .. E.SCATTER_SPINS[3] .. " Free Games")
end
-- The banner shares the XP panel: with no banner text, the XP bar shows.
local function SetBanner(text, r, g, b)
  text = text or ""
  UI.banner:SetText(text)
  UI.banner:SetTextColor(r or 1, g or 0.82, b or 0)
  if text == "" then UI.xp:Show() else UI.xp:Hide() end
end
local function RestingBanner()
  if db.free then
    SetBanner("Free Games  " .. db.free.played .. " of " .. db.free.total .. "  (wins x" .. E.FREE_SPIN_MULT .. ")", 0.6, 0.85, 1)
  else
    SetBanner("")
  end
end

local function Enable(button, on)
  if on then button:Enable() else button:Disable() end
end

local function Update()
  if not UI.frame then return end
  local locked = S.busy or InFree()
  local bet, jp = BetCents(), JackpotValues()
  S.betCredits = BetCredits()
  UI.credit:SetText(Money(db.cents - S.hidden))
  UI.bet:SetText(Money(bet))
  UI.win:SetText(Money(S.winShown))
  UI.jp.grand.value:SetText(Money(jp.grand * bet))
  UI.jp.major.value:SetText(Money(jp.major * bet))
  UI.jp.minor.value:SetText(Money(jp.minor * bet))
  UI.jp.mini.value:SetText(Money(jp.mini * bet))
  -- Never quite full here: the bar only reaches the top at the moment of the level-up itself
  -- (see LevelUp), so it can't sit there full while a spin, a big win or the Faire plays out.
  local shown = min(E.xpShown(db.xp), E.LEVEL.barCeil)
  UI.xp:SetValue(shown)
  V.SetXPHot(shown >= 0.93)
  for i, b in ipairs(UI.betButtons) do
    Enable(b, not locked)
    if i == db.betIdx then b:LockHighlight() else b:UnlockHighlight() end
  end
  UI.denom:SetText(Money(Denom()) .. " / credit")
  Enable(UI.denom, not locked)
  UI.spin:SetText(InFree() and ("FREE GAME  (" .. db.free.left .. " left)") or "SPIN")
  Enable(UI.spin, not S.busy)
  UI.auto:SetText(S.auto and "Auto: ON" or "Auto")
  UI.mute:SetText(db.muted and "Muted" or "Sound")
  UI.musicButton:SetText(db.music and "Music on" or "Music")
  if ns.O and ns.O.panel and ns.O.panel:IsShown() then ns.O.RefreshPanel() end
end

local function SetWin(cents) S.winShown = cents; if UI.win then UI.win:SetText(Money(cents)) end end

local function FlashJackpot(key)
  local p, c = UI.jp[key], V.JP_COLOR[key]
  V.Animate(2.4, function(t)
    if t < 1 and floor(t * 12) % 2 == 0 then p.value:SetTextColor(1, 1, 1) else p.value:SetTextColor(c[1], c[2], c[3]) end
  end)
end

-- ---------------------------------------------------------------- celebrations
local TIERS = { { x = 0, name = "Big Win" }, { x = 40, name = "Epic Win" }, { x = 100, name = "Legendary Win" } }

-- ba-da-BOOM: two light hits and a heavy one.
local function Badaboom()
  A.Snd(SFX.tick)
  C_Timer.After(0.13, function() A.Snd(SFX.tick) end)
  C_Timer.After(0.27, function() A.Snd(SFX.coinLarge) end)
end

-- Big wins (15x the bet and up): the ceremony takes over the reel window. Every credit is counted
-- with a tick, the title climbs through the tiers, coins fountain and fireworks go off throughout.
-- A click skips to the end.
local function Ceremony(cents, title)
  local d, bet = Denom(), BetCents()
  local x = cents / bet
  local credits = floor(cents / d + 0.5)
  local duration = min(24, 6 + 0.15 * x)
  local o = UI.overlay
  local tier = 1
  S.skipCount = false
  V.ClearWins()
  o.amount:SetText(Money(0))
  o.credits:SetText("0 credits")
  o:Show()
  V.TitlePop((title and x < TIERS[2].x) and title or TIERS[1].name)
  A.Snd(SFX.levelUp); V.Thud(); V.Coins(14)
  Wait(0.9)

  -- The Stormwind theme starts as the count does and carries through to the end of the ceremony.
  local theme = A.Snd(SFX.fanfare, true)
  local start, lastTick, lastBeat, lastShow = GetTime(), 0, 0, 0
  while true do
    local t = GetTime() - start
    local p = S.skipCount and 1 or min(1, t / duration)
    local eased = 1 - (1 - p) ^ 1.5 -- slows down as it nears the total
    local c = (p >= 1) and credits or floor(eased * credits)
    o.amount:SetText(Money(c * d))
    o.credits:SetText(Commas(c) .. " credits")
    if not S.skipCount then
      if t - lastTick > 0.07 then lastTick = t; A.Snd(SFX.tick) end
      if t - lastBeat > 0.9 then lastBeat = t; Badaboom() end
      if t - lastShow > 0.4 then
        lastShow = t
        V.Coins(5); V.Firework()
        if random(3) == 1 then A.Any(A.FIREWORKS) end
      end
    end
    while tier < #TIERS and (c * d) / bet >= TIERS[tier + 1].x do
      tier = tier + 1
      V.TitlePop(TIERS[tier].name)
      if not S.skipCount then
        A.Snd(SFX.levelUp); A.Any(A.FIREWORKS); V.Thud(); V.Coins(24)
        V.Firework(); V.Firework(); V.Firework()
      end
    end
    if p >= 1 then break end
    Wait(0.03)
  end

  -- Finale.
  o.amount:SetText(Money(cents))
  o.credits:SetText(Commas(credits) .. " credits")
  V.TitlePop(TIERS[tier].name)
  Badaboom(); V.Thud(); V.Coins(40)
  for _ = 1, 5 do V.Firework() end
  A.Any(A.FIREWORKS); A.Snd(SFX.cheer)
  C_Timer.After(0.9, function() A.Any(A.CHEERS) end)
  C_Timer.After(0.7, function() V.Firework(); V.Firework(); V.Coins(20) end)
  Wait(4.2)
  A.Stop(theme, 1800) -- fade the theme out as the ceremony closes
  o:Hide()
end

local function Celebrate(cents, title)
  local x = cents / BetCents()
  if x >= 15 then return Ceremony(cents, title) end
  SetBanner((title or "Winner") .. "  " .. Money(cents), 1, 0.9, 0.3)
  A.Snd(x >= 5 and SFX.levelUp or SFX.coinLarge)
  V.Coins(min(20, 6 + floor(x)))
  Wait(2.2)
end

-- ---------------------------------------------------------------- Darkmoon Faire bonus
-- Works out a whole Faire bonus and banks it straight away, so a /reload, disconnect or crash
-- part-way through can't lose it. The total stays hidden from the readouts until the tally.
local function PrepareFaire(startOrbs, buff)
  buff = buff or {}
  local p = { startOrbs = startOrbs, buff = buff, bc = BetCredits(), d = Denom(), jp = JackpotValues() }
  p.play = E.playHold(startOrbs, buff)
  function p.CreditsOf(orb) return floor(E.orbValue(orb, p.jp) * p.bc + 0.5) end
  local credits, major = 0, false
  for _, orb in pairs(p.play.held) do
    credits = credits + p.CreditsOf(orb)
    if orb.jackpot == "major" then major = true end
  end
  p.grandCredits = p.play.full and floor(p.jp.grand * p.bc + 0.5) or 0
  p.cents = (credits + p.grandCredits) * p.d
  db.cents = db.cents + p.cents; S.hidden = S.hidden + p.cents
  db.stats.won = db.stats.won + p.cents; db.stats.bonuses = db.stats.bonuses + 1
  if major then db.jackpots.major = E.JACKPOTS.major end
  if p.play.full then db.jackpots.grand = E.JACKPOTS.grand end
  return p
end

-- Plays a prepared Faire bonus on screen.
local function Faire(p)
  local startOrbs, buff, play, d = p.startOrbs, p.buff, p.play, p.d
  local CreditsOf, grandCredits, cents = p.CreditsOf, p.grandCredits, p.cents
  local CELLS = E.REELS * E.ROWS

  -- The inn fades into the Faire, then the board appears.
  V.ClearWins()
  V.FadeTheme(1, 1.3)
  A.MusicMood("faire")
  if not buff.id then A.Snd(SFX.levelUp) end
  A.Snd(SFX.cheer); A.Any(A.FIREWORKS)
  V.Firework(); V.Firework(); V.Firework()
  SetBanner(play.respins .. " SPINS LEFT", 0.95, 0.75, 1)
  SetStatus(buff.id and (buff.name .. ": " .. buff.desc) or "Win tickets. Every new one resets your spins.")
  Wait(1.0)
  V.RestReels()
  local held, count = {}, 0
  for k = 1, CELLS do
    if startOrbs[k] then
      held[k] = startOrbs[k]; count = count + 1
      V.SetCell(k, "orb", held[k])
    else
      V.SetCell(k, "empty")
    end
  end
  V.FadeBoard()
  Wait(1.4)

  for _, round in ipairs(play.rounds) do
    local landing, empties = {}, {}
    for _, l in ipairs(round.landed) do landing[l.cell] = l.orb end
    for k = 1, CELLS do if not held[k] then empties[#empties + 1] = k end end

    -- The empty spots spin.
    local loop = A.Snd(SFX.rollLoop, true)
    local settled = {}
    local flicker = C_Timer.NewTicker(0.08, function()
      for _, k in ipairs(empties) do if not settled[k] then V.SetCell(k, "ghost") end end
    end)
    Wait(0.7)
    for _, k in ipairs(empties) do
      -- One spot from the Grand: hold it longer.
      if count == CELLS - 1 then
        SetStatus("One more for the GRAND...")
        V.Glow(k, true); Wait(2.2); V.Glow(k, false)
      else
        Wait(0.12)
      end
      settled[k] = true
      if landing[k] then
        held[k] = landing[k]; count = count + 1
        V.SetCell(k, "ticket", landing[k]) -- the ticket slams in
        V.Pop(k); V.Glow(k, true)
        A.Snd(SFX.coinLarge); A.Snd(SFX.bell); A.Any(A.FIREWORKS)
        V.Firework()
        if landing[k].jackpot then
          A.Snd(SFX.stinger); FlashJackpot(landing[k].jackpot)
          V.Firework(); V.Firework()
          Wait(0.5)
        end
      else
        V.SetCell(k, "empty")
      end
    end
    flicker:Cancel()
    A.Stop(loop, 200)
    for _, k in ipairs(empties) do if not held[k] then V.SetCell(k, "empty") end end

    if #round.landed > 0 then
      SetBanner(round.left .. " SPINS LEFT", 1, 1, 1)
      SetStatus("New ticket! Spins reset to " .. play.respins)
    else
      SetBanner(round.left == 1 and "LAST SPIN" or (round.left .. " SPINS LEFT"), 0.95, 0.75, 1)
      if round.left == 0 then A.Snd(SFX.auctionClose) end
    end
    Wait(#round.landed > 0 and 1.0 or 0.6)
    for k = 1, CELLS do V.Glow(k, false) end
  end

  -- Tally: every prize pays into the total, one at a time.
  SetStatus(play.full and "Full board!" or "Cashing in your prizes")
  local run = 0
  for k = 1, CELLS do
    local orb = held[k]
    if orb then
      V.Glow(k, true); V.Pop(k)
      run = run + CreditsOf(orb) * d
      SetBanner(Money(run), 1, 0.95, 0.5)
      if orb.jackpot then
        local label = orb.jackpot == "major" and "MAJOR JACKPOT" or (V.JP_NAME[orb.jackpot] .. " BONUS")
        SetStatus(label .. "  " .. Money(CreditsOf(orb) * d))
        FlashJackpot(orb.jackpot)
        A.Snd(orb.jackpot == "major" and SFX.legendary or SFX.epicLoot)
        V.Firework(); V.Firework()
        Wait(orb.jackpot == "major" and 3.5 or 2.0)
      else
        A.Snd(SFX.coinSmall)
        Wait(0.22)
      end
    end
  end
  if play.full then
    run = run + grandCredits * d
    SetBanner(Money(run), 1, 0.6, 0.1)
    SetStatus("GRAND JACKPOT  " .. Money(grandCredits * d))
    FlashJackpot("grand")
    A.Snd(SFX.legendary); A.Any(A.FIREWORKS); A.Snd(SFX.cheer)
    V.Coins(40)
    for _ = 1, 6 do V.Firework() end
    Wait(5)
  end

  Celebrate(cents, "Winner")
  S.hidden = S.hidden - cents
  SetWin(S.winShown + cents)

  -- Back to the inn.
  V.FadeTheme(0, 1.3)
  A.MusicMood("inn")
  if S.lastSpin then V.DrawSpin(S.lastSpin) else V.RandomBoard() end
  V.FadeBoard()
  V.ClearWins()
  Update()
  return cents
end

-- Level up: ding, a buff, and straight into the Faire.
local function LevelUp()
  db.level = db.level + 1
  db.xp = 0.1 + random() * 0.12
  db.stats.levels = db.stats.levels + 1
  local lv = E.levelUp()
  local prepared = PrepareFaire(lv.orbs, lv.buff)
  V.ClearWins()
  -- The bar fills to the top and flashes: the only time it ever looks completely full.
  SetBanner("")
  UI.xp:SetValue(1)
  V.XPFlash()
  A.Snd(SFX.levelUp); A.Any(A.FIREWORKS)
  V.Firework(); V.Firework(); V.Thud()
  SetStatus("Level Up!")
  Wait(1.3)
  SetBanner("Level Up!   " .. lv.buff.name .. ": " .. lv.buff.desc, 1, 0.9, 0.3)
  SetStatus("The Darkmoon Faire opens with a buff")
  A.Any(A.CHEERS)
  Wait(3)
  return Faire(prepared)
end

-- ---------------------------------------------------------------- one spin
-- A spin only ever starts while the window is actually on screen, so nothing runs away
-- behind a closed window, a hidden interface (Alt-Z) or a cinematic.
local function RequestSpin()
  if S.busy or not UI.frame or not UI.frame:IsVisible() then return end
  Run(G.SpinFlow)
end

-- Shows the wins of a spin: every winning cell and line at once, then one line at a time.
local function ShowWins(ev, d, totalCents)
  local items, all = {}, {}
  for _, w in ipairs(ev.wins) do
    items[#items + 1] = { cells = w.cells, line = w.line,
      text = "Line " .. w.line .. ":  " .. w.count .. "x " .. E.SYM[w.symbol].name .. "  " .. Money(w.amount * d) }
    for _, k in ipairs(w.cells) do all[#all + 1] = k end
  end
  if ev.scatter.win > 0 then
    items[#items + 1] = { cells = ev.scatter.cells, text = ev.scatter.count .. "x Portal  " .. Money(ev.scatter.win * d) }
    for _, k in ipairs(ev.scatter.cells) do all[#all + 1] = k end
  end
  V.Highlight(all)
  V.HideLines()
  for _, item in ipairs(items) do if item.line then V.DrawLine(item.line) end end
  SetStatus(#items == 1 and items[1].text or (#items .. " winning lines  " .. Money(totalCents)))
  if #items > 1 then
    local n = 0
    S.cycleTicker = C_Timer.NewTicker(1.1, function()
      n = n % #items + 1
      V.Highlight(items[n].cells)
      V.HideLines()
      if items[n].line then V.DrawLine(items[n].line) end
      SetStatus(items[n].text)
    end)
  end
end

function G.SpinFlow()
  local free = InFree()
  local bet, d = BetCents(), Denom()
  if not free then
    if db.cents - S.hidden < bet then
      S.auto = false
      SetStatus("Not enough credit. Insert a bill to keep playing.")
      A.Snd(SFX.forgetSomething)
      Update()
      return
    end
    db.cents = db.cents - bet
    db.stats.wagered = db.stats.wagered + bet
    db.stats.spins = db.stats.spins + 1
    db.jackpots.major = db.jackpots.major + E.JACKPOT_GROWTH.major
    db.jackpots.grand = db.jackpots.grand + E.JACKPOT_GROWTH.grand
    db.xp = min(1, db.xp + E.xpGain())
    SetWin(0)
  else
    db.free.left = db.free.left - 1
    db.free.played = db.free.played + 1
  end
  S.busy = true
  V.ClearWins()
  RestingBanner()
  SetStatus(free and ("Free game " .. db.free.played .. " of " .. db.free.total) or "Good luck!")
  Update()

  local res = E.spin()
  local ev = E.evaluate(res.grid, BetMult(), free and E.FREE_SPIN_MULT or 1)

  -- Bank the whole outcome now, before anything is shown, so a /reload, disconnect or crash
  -- mid-spin can't lose it. Each part is revealed on the readouts as it plays out.
  local lineCents = ev.total * d
  if lineCents > 0 then
    db.cents = db.cents + lineCents; S.hidden = S.hidden + lineCents
    db.stats.won = db.stats.won + lineCents
  end
  local faire = ev.orbs.triggered and PrepareFaire(res.orbs) or nil
  local freeWon = ev.scatter.freeSpins
  if freeWon > 0 then
    if db.free then
      db.free.left = db.free.left + freeWon; db.free.total = db.free.total + freeWon
    else
      db.free = { left = freeWon, total = freeWon, played = 0, wonCents = 0 }
    end
  end

  -- Work out when each reel stops. A reel that could complete a bonus spins on, in suspense.
  local plan, t, scat, orbs = {}, 0.7, 0, 0
  for i = 1, E.REELS do
    local tease
    if i > 1 then
      if scat == 2 then tease = "scatter"
      elseif orbs >= E.HOLD.trigger - 2 and orbs < E.HOLD.trigger then tease = "orb" end
      t = t + (tease and 1.7 or 0.26)
    end
    plan[i] = { t = t, tease = tease, scatBefore = scat, orbsBefore = orbs }
    for row = 1, E.ROWS do
      local s = E.SYM[res.grid[i][row]]
      if s.scatter then scat = scat + 1 end
      if s.orb then orbs = orbs + 1 end
    end
  end

  -- Spin. The reels scroll on their own (View.lua); here we only stop them on time, left to right.
  A.Snd(SFX.rollStart)
  local loop = A.Snd(SFX.rollLoop, true)
  V.StartSpin()
  local elapsed = 0
  for i = 1, E.REELS do
    local p, nextStop = plan[i], plan[i + 1]
    Wait(p.t - elapsed); elapsed = p.t
    V.Tease(nil)
    V.Land(i, res)
    A.Snd(SFX.tick)
    local s, o = p.scatBefore, p.orbsBefore
    for row = 1, E.ROWS do
      local sym = E.SYM[res.grid[i][row]]
      if sym.scatter then s = s + 1; A.Snd(SFX.questUpdate); V.Pop(E.key(i, row)) end
      if sym.orb then o = o + 1; A.Snd(SFX.coinSmall); V.Pop(E.key(i, row)) end
    end
    if p.tease == "scatter" and s == p.scatBefore and not (nextStop and nextStop.tease) then A.Snd(SFX.questFailed) end
    if nextStop and nextStop.tease then
      V.Tease(i + 1)
      -- Light up what has landed so far, so the eye knows what it is waiting for.
      for reel = 1, i do
        for row = 1, E.ROWS do
          local sym = E.SYM[res.grid[reel][row]]
          if (nextStop.tease == "scatter" and sym.scatter) or (nextStop.tease == "orb" and sym.orb) then
            V.Glow(E.key(reel, row), true)
          end
        end
      end
      if nextStop.tease == "scatter" then SetStatus("One more Portal for Free Games...")
      else SetStatus((E.HOLD.trigger - o) .. " more for the Bonus Reels...") end
    end
  end
  A.Stop(loop, 150)
  A.Snd(SFX.rollEnd)
  S.lastSpin = res
  Wait(0.38) -- let the last reel settle
  for k = 1, E.REELS * E.ROWS do V.Glow(k, false) end

  -- Line and scatter pays.
  local spinCents = lineCents
  if ev.total > 0 then
    local big = lineCents >= bet * 15
    if not big then S.hidden = S.hidden - lineCents; SetWin(S.winShown + lineCents) end
    Update()
    ShowWins(ev, d, lineCents)
    if not big then A.Snd((lineCents / bet) >= 5 and SFX.coinLarge or SFX.coinSmall) end
    -- The best line's symbol makes its sound; if a wild helped, the Alliance speaks too.
    local best
    for _, w in ipairs(ev.wins) do if not best or w.amount > best.amount then best = w end end
    if best then
      A.Any(E.SYM[best.symbol].sounds)
      if best.symbol ~= "wild" then
        for _, k in ipairs(best.cells) do
          local reel, row = E.unkey(k)
          if res.grid[reel][row] == "wild" then
            C_Timer.After(0.8, function() A.Any(E.SYM.wild.sounds) end)
            break
          end
        end
      end
    end
    if big then
      Wait(1.3)
      Celebrate(lineCents)
      S.hidden = S.hidden - lineCents
      SetWin(S.winShown + lineCents)
      Update()
    end
  elseif not faire and freeWon == 0 and db.xp < 1 then
    if free then SetStatus("Free game " .. db.free.played .. " of " .. db.free.total) else IdleStatus() end
  end

  -- Bonuses.
  if faire then
    Wait(ev.total > 0 and 1.2 or 0.5)
    spinCents = spinCents + Faire(faire)
    RestingBanner()
  end
  if db.xp >= 1 then
    Wait((ev.total > 0 and not faire) and 1.4 or 0.5)
    spinCents = spinCents + LevelUp()
    RestingBanner()
  end
  if freeWon > 0 then
    SetBanner((free and "+" or "") .. freeWon .. " FREE GAMES  (wins x" .. E.FREE_SPIN_MULT .. ")", 0.6, 0.85, 1)
    SetStatus(ev.scatter.count .. " Portals!")
    A.Snd(SFX.questComplete)
    for _, k in ipairs(ev.scatter.cells) do V.Pop(k) end
    Wait(3)
  end
  if db.free and (free or freeWon > 0) then db.free.wonCents = db.free.wonCents + spinCents end
  db.stats.biggest = max(db.stats.biggest, spinCents)

  -- Free games finished: show the total.
  local ended = false
  if db.free and db.free.left == 0 then
    local total = db.free.wonCents
    db.free = nil; ended = true
    V.ClearWins()
    SetStatus("Free Games completed")
    if total > 0 then Celebrate(total, "Winner") end
    SetBanner("")
  end

  S.busy = false
  Update()
  if InFree() then
    C_Timer.After(ev.total > 0 and 1.5 or 0.6, RequestSpin)
  elseif S.auto then
    C_Timer.After(ended and 1.2 or (ev.total > 0 and 1.4 or 0.45), function() if S.auto then RequestSpin() end end)
  end
end

-- ---------------------------------------------------------------- window and controls
local function Button(parent, text, width, height, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, height)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

-- A plain tooltip: it is drawn by the game's own tooltip, above every window.
local function Tip(widget, title, body)
  widget:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 0.82, 0)
    if body then GameTooltip:AddLine(body, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function InsertBill(cents)
  db.cents = db.cents + cents
  db.stats.bills = db.stats.bills + cents
  A.Snd(SFX.moneyOpen)
  C_Timer.After(0.35, function() A.Snd(SFX.buyAndTrade) end)
  SetStatus(Money(cents) .. " of play money inserted")
  Update()
end

-- Where the window sits. The default is the left side of the screen, clear of the middle,
-- the chat box, the action bars and the bags. A dragged position is saved and restored.
local function PlaceWindow()
  local f = UI.frame
  f:ClearAllPoints()
  local pos = db.pos
  if type(pos) == "table" and pos[1] then
    f:SetPoint(pos[1], UIParent, pos[2] or pos[1], pos[3] or 0, pos[4] or 0)
  else
    f:SetPoint("LEFT", UIParent, "LEFT", 40, 50)
  end
end
local function SavePosition()
  local point, _, relativePoint, x, y = UI.frame:GetPoint(1)
  if point then db.pos = { point, relativePoint, x, y } end
end

local function BuildControls()
  local c = UI.controls
  -- Bet buttons: total bet in credits (25 lines x credits per line).
  UI.betButtons = {}
  for i, m in ipairs(E.BET_MULTS) do
    local b = Button(c, tostring(E.LINES * m), 62, 24, function()
      if S.busy or InFree() then return end
      db.betIdx = i; A.Snd(SFX.tick); Update()
    end)
    b:SetPoint("TOPLEFT", c, "TOPLEFT", (i - 1) * 68 + 1, 0)
    Tip(b, "Bet " .. (E.LINES * m) .. " credits", E.LINES .. " lines at " .. m .. " credit" .. (m == 1 and "" or "s") .. " a line.")
    UI.betButtons[i] = b
  end

  UI.denom = Button(c, "", 96, 22, function()
    if S.busy or InFree() then return end
    db.denomIdx = db.denomIdx % #E.DENOMS + 1; A.Snd(SFX.tick); Update()
  end)
  UI.denom:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -30)
  UI.auto = Button(c, "", 54, 22, function()
    S.auto = not S.auto; A.Snd(SFX.tick); Update()
    if S.auto then RequestSpin() end
  end)
  UI.auto:SetPoint("LEFT", UI.denom, "RIGHT", 3, 0)
  UI.mute = Button(c, "", 58, 22, function()
    db.muted = not db.muted
    if db.muted then A.StopLong() end
    A.MusicSync(); Update()
  end)
  UI.mute:SetPoint("LEFT", UI.auto, "RIGHT", 3, 0)
  UI.musicButton = Button(c, "", 58, 22, function() db.music = not db.music; A.MusicSync(); Update() end)
  UI.musicButton:SetPoint("LEFT", UI.mute, "RIGHT", 3, 0)
  local options = Button(c, "Options", 58, 22, function() ns.O.Toggle() end)
  options:SetPoint("LEFT", UI.musicButton, "RIGHT", 3, 0)

  local bill20 = Button(c, "Insert $20", 96, 22, function() InsertBill(2000) end)
  bill20:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -58)
  local bill100 = Button(c, "Insert $100", 96, 22, function() InsertBill(10000) end)
  bill100:SetPoint("TOPLEFT", bill20, "BOTTOMLEFT", 0, -4)
  UI.spin = Button(c, "SPIN", 228, 48, RequestSpin)
  UI.spin:SetPoint("TOPRIGHT", c, "TOPRIGHT", 0, -58)

  Tip(UI.denom, "Denomination", "What one credit is worth. Click to change. Bets, wins and jackpots all scale with it.")
  Tip(bill20, "Insert $20", "Play money only. It has nothing to do with your gold.")
  Tip(bill100, "Insert $100", "Play money only. It has nothing to do with your gold.")
  Tip(UI.auto, "Auto-spin", "Keeps spinning until you turn it off or close the window. Entering combat stops it too, unless you change that in Options.")
  Tip(UI.musicButton, "Music", "Elwynn Forest music while the window is open. It replaces the zone music until you turn it off or close the window.")
  Tip(options, "Options", "Combat behaviour, the minimap button, sound, music and window scale.")
end

local function Build()
  if UI.frame then return end
  local f = CreateFrame("Frame", "LionsPrideFrame", UIParent)
  -- Same layer as the game's own panels (character, bags, spellbook). Clicking it brings it to the
  -- front of that layer; dialogs, menus, tooltips and full-screen frames such as the map stay above it.
  f:SetFrameStrata("MEDIUM")
  f:SetToplevel(true)
  f:SetClampedToScreen(true) -- can't be dragged off screen
  f:SetMovable(true)
  f:EnableMouse(true)        -- takes clicks inside its own bounds only; it never takes the keyboard
  -- The corners beside the roof peak are empty, so leave them out of the clickable area.
  if f.SetHitRectInsets then f:SetHitRectInsets(0, 0, 40, 0) end
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false) -- we save the position ourselves, so keep it out of the game's layout cache
    SavePosition()
  end)
  S.betCredits = BetCredits()
  V.Build(f)
  -- Closing the window (or the interface being hidden) stops auto-spin, the music and anything still
  -- playing. A spin or bonus in progress finishes quietly in the background; its result is already banked.
  f:SetScript("OnHide", function()
    S.auto = false
    S.skipCount = true
    A.StopLong()
    A.MusicStop()
    V.ClearParticles()
    if S.cycleTicker then S.cycleTicker:Cancel(); S.cycleTicker = nil end
  end)
  f:SetScript("OnShow", function() A.MusicSync() end)
  f:SetScale(db.scale or 1)
  PlaceWindow()
  tinsert(UISpecialFrames, "LionsPrideFrame") -- Esc closes it

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -(V.Y.roofBand - 34))
  close:SetFrameLevel(f:GetFrameLevel() + 5)

  BuildControls()
  V.RandomBoard()
  RestingBanner()
  IdleStatus()
  if InFree() then SetStatus("Free games waiting: press the button to continue") end
  Update()
  f:Hide()
end

local reopenAfter = false -- the window was closed by combat or a pet battle and should come back

local function Toggle()
  Build()
  reopenAfter = false
  if UI.frame:IsShown() then
    UI.frame:Hide()
  else
    UI.frame:Show()
    if InFree() and not S.busy then SetStatus("Free games waiting: press the button to continue") end
    Update()
  end
end

-- Combat and pet battles: stop auto-spin, and (by default) get out of the way until it is over.
-- Showing and hiding this window is always allowed: it is not a protected frame and calls nothing secure.
local function Suspend()
  if db.hideInCombat and UI.frame and UI.frame:IsShown() then
    S.auto = false -- closing the window always stops auto-spin
    reopenAfter = true
    UI.frame:Hide()
  elseif db.stopAutoInCombat and S.auto then
    S.auto = false -- the spin in progress finishes and pays as normal
    Update()
  end
end
local function Resume()
  if reopenAfter and UI.frame then
    reopenAfter = false
    UI.frame:Show()
    if InFree() and not S.busy then SetStatus("Free games waiting: press the button to continue") end
    Update()
  end
end

-- ---------------------------------------------------------------- chat commands
local function Say(text) print("|cffffd100Lion's Pride Casino:|r " .. text) end

function ns.ResetPosition()
  db.pos = nil
  Build()
  PlaceWindow()
  UI.frame:Show(); Update()
  Say("Window moved back to its default spot.")
end
ns.Toggle, ns.Update, ns.Say = Toggle, Update, Say

function ns.PrintRules()
  Say("5 reels, " .. E.LINES .. " lines, wins pay left to right. Play money only: no real stakes and no gold.")
  Say(E.HOLD.trigger .. "+ Gold Orbs open the Darkmoon Faire: orbs lock, " .. E.HOLD.respins ..
    " respins, and every new ticket resets them. Fill all 15 spots for the Grand.")
  Say("3 / 4 / 5 Portals win " .. E.SCATTER_SPINS[3] .. " / " .. E.SCATTER_SPINS[4] .. " / " .. E.SCATTER_SPINS[5] ..
    " free games with line wins x" .. E.FREE_SPIN_MULT .. ".")
  Say("Every paid spin earns XP. A level-up opens the Faire with a buff.")
  Say("Commands: /slots (or /casino), /slots options, /slots rules, /slots stats, /slots music, /slots minimap, /slots scale 0.8, /slots resetpos, /slots reset")
end

local function PrintStats()
  local s = db.stats
  Say("Credit " .. Money(db.cents) .. ", spins " .. Commas(s.spins))
  Say("Wagered " .. Money(s.wagered) .. ", won " .. Money(s.won) ..
    (s.wagered > 0 and string.format(" (%.1f%% return)", 100 * s.won / s.wagered) or ""))
  Say("Biggest win " .. Money(s.biggest) .. ", bonuses " .. s.bonuses .. " (" .. s.levels .. " from level-ups), play money inserted " .. Money(s.bills))
end

SLASH_LIONSPRIDE1 = "/lionspride"
SLASH_LIONSPRIDE2 = "/slots"
SLASH_LIONSPRIDE3 = "/casino"
SlashCmdList["LIONSPRIDE"] = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "rules" or msg == "help" then
    ns.PrintRules()
  elseif msg == "stats" then
    PrintStats()
  elseif msg == "reset" then
    if S.busy then Say("Wait for the current spin to finish.") return end
    -- Settings survive a reset; credit, progress, jackpots and stats start over.
    local keep = { muted = db.muted, music = db.music, scale = db.scale, pos = db.pos,
      hideInCombat = db.hideInCombat, stopAutoInCombat = db.stopAutoInCombat, minimap = db.minimap }
    for k in pairs(db) do db[k] = nil end
    for k, v in pairs(keep) do db[k] = v end
    CopyDefaults(DEFAULTS, db)
    S.hidden, S.winShown, S.auto = 0, 0, false
    Say("Reset to " .. Money(db.cents) .. ".")
    if UI.frame then RestingBanner(); IdleStatus(); Update() end
  elseif msg == "resetpos" then
    ns.ResetPosition()
  elseif msg == "options" or msg == "config" or msg == "settings" then
    ns.O.Toggle()
  elseif msg == "minimap" then
    ns.O.SetMinimapShown(db.minimap.hide)
    Say(db.minimap.hide and "Minimap button hidden. /slots minimap brings it back." or "Minimap button shown.")
  elseif msg == "combat" then
    db.hideInCombat = not db.hideInCombat
    Say(db.hideInCombat and "The window will close when combat starts and reopen afterwards."
      or "The window will stay open in combat. See /slots options for auto-spin in combat.")
  elseif msg == "music" then
    db.music = not db.music
    A.MusicSync()
    if UI.frame then Update() end
    Say(db.music and "Music on. It plays while the window is open and replaces the zone music." or "Music off.")
  elseif msg:match("^scale") then
    local n = tonumber(msg:match("^scale%s+([%d%.]+)"))
    if n and n >= 0.5 and n <= 2 then
      db.scale = n
      if UI.frame then UI.frame:SetScale(n) end
      Say("Window scale set to " .. n)
    else
      Say("Use a number from 0.5 to 2, for example /slots scale 0.8")
    end
  else
    Toggle()
  end
end

-- ---------------------------------------------------------------- startup
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:SetScript("OnEvent", function(self, event, name)
  if event == "ADDON_LOADED" then
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    LionsPrideDB = LionsPrideDB or {}
    db = LionsPrideDB
    ns.db = db
    -- Saves from 0.1 had "close in combat" switched on by default, not by choice. It is now off
    -- unless the player turns it on, so drop the old value and let the new default apply.
    if db.schema == nil then db.hideInCombat = nil end
    CopyDefaults(DEFAULTS, db)
    ns.O.BuildMinimapButton()
    self:RegisterEvent("PLAYER_REGEN_DISABLED") -- entering combat
    self:RegisterEvent("PLAYER_REGEN_ENABLED")  -- leaving combat
    -- Pet battles only exist in some versions of the game; registering an unknown event is an error.
    pcall(self.RegisterEvent, self, "PET_BATTLE_OPENING_START")
    pcall(self.RegisterEvent, self, "PET_BATTLE_CLOSE")
    Say("loaded. Type /slots or /casino to play. Play money only, no gold involved.")
  elseif not db then
    return
  elseif event == "PLAYER_REGEN_DISABLED" or event == "PET_BATTLE_OPENING_START" then
    Suspend()
  elseif event == "PLAYER_REGEN_ENABLED" or event == "PET_BATTLE_CLOSE" then
    Resume()
  end
end)
