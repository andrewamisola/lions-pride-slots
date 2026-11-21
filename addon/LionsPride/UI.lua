-- Lion's Pride Slots: the window and the game flow.
-- Open with /slots or /lionspride. Play money only: this addon never touches gold, items or trade.

local ADDON, ns = ...
local E = ns.Engine

local floor, min, max, random = math.floor, math.min, math.max, math.random

-- ---------------------------------------------------------------- saved data
local DEFAULTS = {
  cents = 10000,            -- $100.00 of play money
  denomIdx = 3, betIdx = 1,
  muted = false, scale = 0.9,
  hideInCombat = true,      -- close the window when combat or a pet battle starts, reopen it afterwards
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

-- ---------------------------------------------------------------- state
local UI = {}                 -- frame references, filled by Build()
local busy, auto = false, false
local hidden = 0              -- cents already banked but not yet shown (revealed when a bonus is tallied)
local winShown = 0            -- cents on the WIN readout
local cycleTicker, spinTicker
local lastSpin                -- last spin result, redrawn after a bonus
local skipCount = false       -- set by clicking the big-win overlay

local function Denom() return E.DENOMS[db.denomIdx] end
local function BetMult() return E.BET_MULTS[db.betIdx] end
local function BetCredits() return E.LINES * BetMult() end
local function BetCents() return BetCredits() * Denom() end
local function InFree() return db.free ~= nil and db.free.left > 0 end
local function JackpotValues()
  return { mini = E.JACKPOTS.mini, minor = E.JACKPOTS.minor, major = db.jackpots.major, grand = db.jackpots.grand }
end

local function Commas(n)
  local s, k = tostring(n), 0
  repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return s
end
local function Money(cents)
  cents = floor(cents + 0.5)
  return "$" .. Commas(floor(cents / 100)) .. string.format(".%02d", cents % 100)
end

local QUALITY = {
  common = { 0.85, 0.85, 0.85 }, uncommon = { 0.12, 1.00, 0.00 }, rare = { 0.00, 0.44, 0.87 },
  epic = { 0.64, 0.21, 0.93 }, legendary = { 1.00, 0.50, 0.00 }, artifact = { 0.90, 0.80, 0.50 },
  arcane = { 0.41, 0.80, 0.94 }, ticket = { 0.82, 0.29, 1.00 },
}
local JP_COLOR = {
  grand = { 1.00, 0.50, 0.00 }, major = { 0.75, 0.42, 1.00 }, minor = { 0.25, 0.65, 1.00 }, mini = { 0.24, 0.89, 0.24 },
}
local JP_NAME = { mini = "MINI", minor = "MINOR", major = "MAJOR", grand = "GRAND" }

-- ---------------------------------------------------------------- sound
-- Every sound is one of the game's own files, played by file ID.
local SFX = {
  tick = 567407, coinSmall = 567428, coinLarge = 567413, levelUp = 567431,
  questComplete = 567439, questUpdate = 567516, questFailed = 567459,
  moneyOpen = 567483, auctionClose = 567499,
  rollStart = 642827, rollLoop = 642825, rollEnd = 642823,
  epicLoot = 642829, legendary = 1489461, stinger = 1067170,
  bell = 1100031, cheer = 568821, fanfare = 53211,
  forgetSomething = 552181, buyAndTrade = 552177,
}
local FIREWORKS = { 566373, 566585, 566862 }
local CHEERS = { 540694, 540707 }  -- "Outstanding!", "Excellent!"

-- Sounds go through the game's SFX channel, so the player's Sound Effects volume and toggle apply.
-- Nothing plays while the window is closed or the interface is hidden (Alt-Z, cinematics).
local longSounds = {} -- handles of sounds long enough to need cutting off when the window closes
local function Snd(id, long)
  if not id or not db or db.muted then return nil end
  if not UI.frame or not UI.frame:IsVisible() then return nil end
  local ok, _, handle = pcall(PlaySoundFile, id, "SFX")
  if not ok then return nil end
  if long and handle then longSounds[#longSounds + 1] = handle end
  return handle
end
local function SndAny(list)
  if list and #list > 0 then return Snd(list[random(#list)]) end
end
local function StopSnd(handle, fadeMs)
  if handle then pcall(StopSound, handle, fadeMs or 0) end
end
local function StopLongSounds()
  for i = #longSounds, 1, -1 do StopSnd(longSounds[i], 200); longSounds[i] = nil end
end

-- ---------------------------------------------------------------- sequencing
-- The game flow is written as straight-line code inside a coroutine; Wait() pauses it.
local function OnFlowError(err)
  busy, auto = false, false
  if spinTicker then spinTicker:Cancel(); spinTicker = nil end
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

-- ---------------------------------------------------------------- drawing
local FONT, TITLE_FONT = "Fonts\\FRIZQT__.TTF", "Fonts\\MORPHEUS.TTF"

local function Text(parent, size, flags, font)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(font or FONT, size, flags or "")
  fs:SetShadowColor(0, 0, 0, 1)
  fs:SetShadowOffset(1, -1)
  return fs
end

local CELL, GAP = 64, 4
local STEP = CELL + GAP

-- kind: "symbol" (data = symbol id), "orb" / "ticket" (data = prize), "ghost" (a spinning empty spot), "empty"
local function SetCell(k, kind, data)
  local c = UI.cells[k]
  c.glow:Hide()
  c.icon:SetVertexColor(1, 1, 1)
  c.icon:SetAlpha(1)
  c.border:SetAlpha(1)
  c.text:SetText("")
  if kind == "empty" then
    c.icon:Hide(); c.border:Hide()
    return
  end
  c.icon:Show(); c.border:Show()
  if kind == "symbol" then
    local s = E.SYM[data]
    c.icon:SetTexture(s.icon)
    local q = QUALITY[s.quality] or QUALITY.common
    c.border:SetColorTexture(q[1], q[2], q[3], 1)
  elseif kind == "ghost" then
    c.icon:SetTexture(E.TICKET_ICON)
    c.icon:SetAlpha(0.15 + random() * 0.3)
    c.border:Hide()
  else -- orb or ticket
    c.icon:SetTexture(kind == "ticket" and E.TICKET_ICON or E.SYM.orb.icon)
    local q = data.jackpot and JP_COLOR[data.jackpot] or QUALITY[kind == "ticket" and "ticket" or "artifact"]
    c.border:SetColorTexture(q[1], q[2], q[3], 1)
    if data.jackpot then
      c.text:SetText(JP_NAME[data.jackpot])
      c.text:SetTextColor(q[1], q[2], q[3])
    else
      c.text:SetText(Commas(data.x * BetCredits()))
      c.text:SetTextColor(1, 0.95, 0.6)
    end
  end
end

local function DrawSpin(res)
  for reel = 1, E.REELS do
    for row = 1, E.ROWS do
      local k = E.key(reel, row)
      local id = res.grid[reel][row]
      if E.SYM[id].orb then SetCell(k, "orb", res.orbs[k] or { x = 1 }) else SetCell(k, "symbol", id) end
    end
  end
end

local function RandomCell(k)
  local id = E.pick()
  if E.SYM[id].orb then SetCell(k, "orb", E.rollOrb()) else SetCell(k, "symbol", id) end
end

local function SetStatus(text) UI.status:SetText(text or "") end
local function IdleStatus()
  SetStatus(E.HOLD.trigger .. " Gold Orbs: Bonus Reels   |   3 Portals: " .. E.SCATTER_SPINS[3] .. " Free Games")
end
local function SetBanner(text, r, g, b)
  UI.banner:SetText(text or "")
  UI.banner:SetTextColor(r or 1, g or 0.82, b or 0)
end
local function RestingBanner()
  if db.free then
    SetBanner("Free Games  " .. db.free.played .. " of " .. db.free.total .. "  (wins x" .. E.FREE_SPIN_MULT .. ")", 0.6, 0.85, 1)
  else
    SetBanner("")
  end
end

local function ClearWins()
  if cycleTicker then cycleTicker:Cancel(); cycleTicker = nil end
  for k = 1, #UI.cells do
    local c = UI.cells[k]
    c.glow:Hide()
    c.icon:SetVertexColor(1, 1, 1)
    c.border:SetAlpha(1)
  end
  for i = 1, E.REELS do UI.reelGlow[i]:Hide() end
end

local function Highlight(cells)
  local lit = {}
  for _, k in ipairs(cells) do lit[k] = true end
  for k = 1, #UI.cells do
    local c = UI.cells[k]
    if lit[k] then
      c.glow:Show(); c.icon:SetVertexColor(1, 1, 1); c.border:SetAlpha(1)
    else
      c.glow:Hide(); c.icon:SetVertexColor(0.3, 0.3, 0.3); c.border:SetAlpha(0.3)
    end
  end
end

local function Enable(button, on)
  if on then button:Enable() else button:Disable() end
end

local function Update()
  if not UI.frame then return end
  local locked = busy or InFree()
  local bet, jp = BetCents(), JackpotValues()
  UI.credit:SetText(Money(db.cents - hidden))
  UI.bet:SetText(Money(bet))
  UI.win:SetText(Money(winShown))
  UI.jp.grand:SetText("GRAND  " .. Money(jp.grand * bet))
  UI.jp.major:SetText("MAJOR  " .. Money(jp.major * bet))
  UI.jp.minor:SetText("MINOR  " .. Money(jp.minor * bet))
  UI.jp.mini:SetText("MINI  " .. Money(jp.mini * bet))
  UI.xp:SetValue(E.xpShown(db.xp))
  UI.level:SetText("Level " .. db.level)
  for i, b in ipairs(UI.betButtons) do
    Enable(b, not locked)
    if i == db.betIdx then b:LockHighlight() else b:UnlockHighlight() end
  end
  UI.denom:SetText(Money(Denom()) .. " / credit")
  Enable(UI.denom, not locked)
  UI.spin:SetText(InFree() and ("FREE GAME  (" .. db.free.left .. " left)") or "SPIN")
  Enable(UI.spin, not busy)
  UI.auto:SetText(auto and "Auto: ON" or "Auto: off")
  UI.mute:SetText(db.muted and "Sound: off" or "Sound: ON")
end

local function SetWin(cents) winShown = cents; if UI.win then UI.win:SetText(Money(cents)) end end

-- ---------------------------------------------------------------- celebrations
local TIERS = { { x = 0, name = "Big Win" }, { x = 40, name = "Epic Win" }, { x = 100, name = "Legendary Win" } }

-- Big wins (15x the bet and up): every credit is counted up on an overlay, the title climbs
-- through the tiers, and a click skips to the end.
local function Ceremony(cents, title)
  local d, bet = Denom(), BetCents()
  local x = cents / bet
  local credits = floor(cents / d + 0.5)
  local duration = min(22, 5 + 0.12 * x)
  local o = UI.overlay
  local tier = 1
  skipCount = false
  ClearWins()
  o.title:SetText((title and x < TIERS[2].x) and title or TIERS[1].name)
  o.amount:SetText(Money(0))
  o.credits:SetText("0 credits")
  o:Show()
  Snd(SFX.levelUp)
  Wait(0.8)

  local start, lastTick, lastBeat = GetTime(), 0, 0
  while true do
    local t = GetTime() - start
    local p = skipCount and 1 or min(1, t / duration)
    local eased = 1 - (1 - p) ^ 1.5 -- slows down as it nears the total
    local c = (p >= 1) and credits or floor(eased * credits)
    o.amount:SetText(Money(c * d))
    o.credits:SetText(Commas(c) .. " credits")
    if not skipCount then
      if t - lastTick > 0.09 then lastTick = t; Snd(SFX.tick) end
      if t - lastBeat > 0.9 then lastBeat = t; Snd(SFX.coinLarge) end
    end
    while tier < #TIERS and (c * d) / bet >= TIERS[tier + 1].x do
      tier = tier + 1
      o.title:SetText(TIERS[tier].name)
      if not skipCount then Snd(SFX.levelUp); SndAny(FIREWORKS) end
    end
    if p >= 1 then break end
    Wait(0.03)
  end

  o.amount:SetText(Money(cents))
  o.credits:SetText(Commas(credits) .. " credits")
  local fanfare = Snd(SFX.fanfare, true) -- a long music file: fade it out after the opening brass
  if fanfare then C_Timer.After(8, function() StopSnd(fanfare, 1500) end) end
  SndAny(FIREWORKS); Snd(SFX.cheer)
  C_Timer.After(0.9, function() SndAny(CHEERS) end)
  Wait(4)
  o:Hide()
end

local function Celebrate(cents, title)
  local x = cents / BetCents()
  if x >= 15 then return Ceremony(cents, title) end
  SetBanner((title or "Winner") .. "  " .. Money(cents), 1, 0.9, 0.3)
  Snd(x >= 5 and SFX.levelUp or SFX.coinLarge)
  Wait(2.2)
end

-- ---------------------------------------------------------------- Darkmoon Faire bonus
local function SetFaireLook(on)
  local f = UI.frame
  if f.SetBackdropColor then
    if on then f:SetBackdropColor(0.45, 0.15, 0.7, 1) else f:SetBackdropColor(1, 1, 1, 1) end
  end
  if on then UI.title:SetText("Darkmoon Faire"); UI.title:SetTextColor(0.95, 0.55, 1)
  else UI.title:SetText("Lion's Pride"); UI.title:SetTextColor(1, 0.82, 0) end
end

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
  db.cents = db.cents + p.cents; hidden = hidden + p.cents
  db.stats.won = db.stats.won + p.cents; db.stats.bonuses = db.stats.bonuses + 1
  if major then db.jackpots.major = E.JACKPOTS.major end
  if p.play.full then db.jackpots.grand = E.JACKPOTS.grand end
  return p
end

-- Plays a prepared Faire bonus on screen.
local function Faire(p)
  local startOrbs, buff, play, d = p.startOrbs, p.buff, p.play, p.d
  local CreditsOf, grandCredits, cents = p.CreditsOf, p.grandCredits, p.cents

  -- Set the stage.
  ClearWins()
  SetFaireLook(true)
  if not buff.id then Snd(SFX.levelUp) end
  Snd(SFX.cheer); SndAny(FIREWORKS)
  SetBanner(play.respins .. " SPINS LEFT", 0.95, 0.75, 1)
  SetStatus(buff.id and (buff.name .. ": " .. buff.desc) or "Win tickets. Every new one resets your spins.")
  local held, count = {}, 0
  for k = 1, #UI.cells do
    if startOrbs[k] then
      held[k] = startOrbs[k]; count = count + 1
      SetCell(k, "orb", held[k])
    else
      SetCell(k, "empty")
    end
  end
  Wait(1.8)

  for _, round in ipairs(play.rounds) do
    local landing, empties = {}, {}
    for _, l in ipairs(round.landed) do landing[l.cell] = l.orb end
    for k = 1, #UI.cells do if not held[k] then empties[#empties + 1] = k end end

    -- The empty spots spin.
    local loop = Snd(SFX.rollLoop, true)
    local settled = {}
    local flicker = C_Timer.NewTicker(0.08, function()
      for _, k in ipairs(empties) do if not settled[k] then SetCell(k, "ghost") end end
    end)
    Wait(0.7)
    for _, k in ipairs(empties) do
      -- One spot from the Grand: hold it longer.
      if count == #UI.cells - 1 then SetStatus("One more for the GRAND..."); Wait(2.2) else Wait(0.12) end
      settled[k] = true
      if landing[k] then
        held[k] = landing[k]; count = count + 1
        SetCell(k, "ticket", landing[k])
        UI.cells[k].glow:Show()
        Snd(SFX.coinLarge); Snd(SFX.bell); SndAny(FIREWORKS)
        if landing[k].jackpot then Snd(SFX.stinger); Wait(0.5) end
      else
        SetCell(k, "empty")
      end
    end
    flicker:Cancel()
    StopSnd(loop, 200)
    for _, k in ipairs(empties) do if not held[k] then SetCell(k, "empty") end end

    if #round.landed > 0 then
      SetBanner(round.left .. " SPINS LEFT", 1, 1, 1)
      SetStatus("New ticket! Spins reset to " .. play.respins)
    else
      SetBanner(round.left == 1 and "LAST SPIN" or (round.left .. " SPINS LEFT"), 0.95, 0.75, 1)
      if round.left == 0 then Snd(SFX.auctionClose) end
    end
    Wait(#round.landed > 0 and 1.0 or 0.6)
    for k = 1, #UI.cells do UI.cells[k].glow:Hide() end
  end

  -- Tally: every prize pays into the total, one at a time.
  SetStatus(play.full and "Full board!" or "Cashing in your prizes")
  local run, n = 0, 0
  for k = 1, #UI.cells do
    local orb = held[k]
    if orb then
      UI.cells[k].glow:Show()
      run = run + CreditsOf(orb) * d
      SetBanner(Money(run), 1, 0.95, 0.5)
      if orb.jackpot then
        local label = orb.jackpot == "major" and "MAJOR JACKPOT" or (JP_NAME[orb.jackpot] .. " BONUS")
        SetStatus(label .. "  " .. Money(CreditsOf(orb) * d))
        Snd(orb.jackpot == "major" and SFX.legendary or SFX.epicLoot)
        Wait(orb.jackpot == "major" and 3.5 or 2.0)
      else
        n = n + 1
        Snd(SFX.coinSmall)
        Wait(0.22)
      end
    end
  end
  if play.full then
    run = run + grandCredits * d
    SetBanner(Money(run), 1, 0.6, 0.1)
    SetStatus("GRAND JACKPOT  " .. Money(grandCredits * d))
    Snd(SFX.legendary); SndAny(FIREWORKS); Snd(SFX.cheer)
    Wait(5)
  end

  Celebrate(cents, "Winner")
  hidden = hidden - cents
  SetWin(winShown + cents)

  -- Back to the inn.
  SetFaireLook(false)
  if lastSpin then DrawSpin(lastSpin) end
  ClearWins()
  Update()
  return cents
end

-- Level up: ding, a buff, and straight into the Faire.
local function LevelUp()
  db.level = db.level + 1
  db.xp = 0.1 + random() * 0.12
  db.stats.levels = db.stats.levels + 1
  local lv = E.levelUp()
  ClearWins()
  Snd(SFX.levelUp); SndAny(FIREWORKS)
  UI.xp:SetValue(1)
  SetBanner("LEVEL " .. db.level .. "!   " .. lv.buff.name .. ": " .. lv.buff.desc, 1, 0.9, 0.3)
  local prepared = PrepareFaire(lv.orbs, lv.buff)
  SetStatus("Level up! The Darkmoon Faire opens with a buff")
  C_Timer.After(0.6, function() SndAny(CHEERS) end)
  Wait(3)
  return Faire(prepared)
end

-- ---------------------------------------------------------------- one spin
local SpinFlow

-- A spin only ever starts while the window is actually on screen, so nothing runs away
-- behind a closed window, a hidden interface (Alt-Z) or a cinematic.
local function RequestSpin()
  if busy or not UI.frame or not UI.frame:IsVisible() then return end
  Run(SpinFlow)
end

SpinFlow = function()
  local free = InFree()
  local bet, d = BetCents(), Denom()
  if not free then
    if db.cents - hidden < bet then
      auto = false
      SetStatus("Not enough credit. Insert a bill to keep playing.")
      Snd(SFX.forgetSomething)
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
  busy = true
  ClearWins()
  RestingBanner()
  SetStatus(free and ("Free game " .. db.free.played .. " of " .. db.free.total) or "Good luck!")
  Update()

  local res = E.spin()
  local ev = E.evaluate(res.grid, BetMult(), free and E.FREE_SPIN_MULT or 1)

  -- Bank the whole outcome now, before anything is shown, so a /reload, disconnect or crash
  -- mid-spin can't lose it. Each part is revealed on the readouts as it plays out.
  local lineCents = ev.total * d
  if lineCents > 0 then
    db.cents = db.cents + lineCents; hidden = hidden + lineCents
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
  local plan, t, scat, orbs = {}, 0.6, 0, 0
  for i = 1, E.REELS do
    local tease
    if i > 1 then
      if scat == 2 then tease = "scatter"
      elseif orbs >= E.HOLD.trigger - 2 and orbs < E.HOLD.trigger then tease = "orb" end
      t = t + (tease and 1.6 or 0.22)
    end
    plan[i] = { t = t, tease = tease, scatBefore = scat, orbsBefore = orbs }
    for row = 1, E.ROWS do
      local s = E.SYM[res.grid[i][row]]
      if s.scatter then scat = scat + 1 end
      if s.orb then orbs = orbs + 1 end
    end
  end

  -- Spin: every reel still turning shows random symbols until its stop time.
  local spinning = { true, true, true, true, true }
  Snd(SFX.rollStart)
  local loop = Snd(SFX.rollLoop, true)
  spinTicker = C_Timer.NewTicker(0.06, function()
    for reel = 1, E.REELS do
      if spinning[reel] then
        for row = 1, E.ROWS do RandomCell(E.key(reel, row)) end
      end
    end
  end)

  local elapsed = 0
  for i = 1, E.REELS do
    local p, nextStop = plan[i], plan[i + 1]
    Wait(p.t - elapsed); elapsed = p.t
    spinning[i] = false
    UI.reelGlow[i]:Hide()
    Snd(SFX.tick)
    local s, o = p.scatBefore, p.orbsBefore
    for row = 1, E.ROWS do
      local k = E.key(i, row)
      local id = res.grid[i][row]
      if E.SYM[id].orb then SetCell(k, "orb", res.orbs[k]) else SetCell(k, "symbol", id) end
      if E.SYM[id].scatter then s = s + 1; Snd(SFX.questUpdate) end
      if E.SYM[id].orb then o = o + 1; Snd(SFX.coinSmall) end
    end
    if p.tease and not (nextStop and nextStop.tease) then
      if (p.tease == "scatter" and s == p.scatBefore) then Snd(SFX.questFailed) end
    end
    if nextStop and nextStop.tease then
      UI.reelGlow[i + 1]:Show()
      -- Light up what has landed so far, so the eye knows what it is waiting for.
      for reel = 1, i do
        for row = 1, E.ROWS do
          local sym = E.SYM[res.grid[reel][row]]
          if (nextStop.tease == "scatter" and sym.scatter) or (nextStop.tease == "orb" and sym.orb) then
            UI.cells[E.key(reel, row)].glow:Show()
          end
        end
      end
      if nextStop.tease == "scatter" then SetStatus("One more Portal for Free Games...")
      else SetStatus((E.HOLD.trigger - o) .. " more for the Bonus Reels...") end
    end
  end
  spinTicker:Cancel(); spinTicker = nil
  StopSnd(loop, 150)
  Snd(SFX.rollEnd)
  lastSpin = res
  for k = 1, #UI.cells do UI.cells[k].glow:Hide() end

  -- Line and scatter pays.
  local spinCents = lineCents
  if ev.total > 0 then
    local big = lineCents >= bet * 15
    if not big then hidden = hidden - lineCents; SetWin(winShown + lineCents) end
    Update()

    -- Show the wins: all at once, then one line at a time.
    local items, all = {}, {}
    for _, w in ipairs(ev.wins) do
      items[#items + 1] = { cells = w.cells,
        text = "Line " .. w.line .. ":  " .. w.count .. "x " .. E.SYM[w.symbol].name .. "  " .. Money(w.amount * d) }
      for _, k in ipairs(w.cells) do all[#all + 1] = k end
    end
    if ev.scatter.win > 0 then
      items[#items + 1] = { cells = ev.scatter.cells, text = ev.scatter.count .. "x Portal  " .. Money(ev.scatter.win * d) }
      for _, k in ipairs(ev.scatter.cells) do all[#all + 1] = k end
    end
    Highlight(all)
    SetStatus(#items == 1 and items[1].text or (#items .. " winning lines  " .. Money(spinCents)))
    if #items > 1 then
      local n = 0
      cycleTicker = C_Timer.NewTicker(1.1, function()
        n = n % #items + 1
        Highlight(items[n].cells); SetStatus(items[n].text)
      end)
    end

    if not big then Snd((spinCents / bet) >= 5 and SFX.coinLarge or SFX.coinSmall) end
    -- The best line's symbol makes its sound; if a wild helped, the Alliance speaks too.
    local best
    for _, w in ipairs(ev.wins) do if not best or w.amount > best.amount then best = w end end
    if best then
      SndAny(E.SYM[best.symbol].sounds)
      if best.symbol ~= "wild" then
        for _, k in ipairs(best.cells) do
          local reel, row = E.unkey(k)
          if res.grid[reel][row] == "wild" then
            C_Timer.After(0.8, function() SndAny(E.SYM.wild.sounds) end)
            break
          end
        end
      end
    end
    if big then
      Wait(1.3)
      Celebrate(lineCents)
      hidden = hidden - lineCents
      SetWin(winShown + lineCents)
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
    Snd(SFX.questComplete)
    Wait(3)
  end
  if db.free and (free or freeWon > 0) then db.free.wonCents = db.free.wonCents + spinCents end
  db.stats.biggest = max(db.stats.biggest, spinCents)

  -- Free games finished: show the total.
  local ended = false
  if db.free and db.free.left == 0 then
    local total = db.free.wonCents
    db.free = nil; ended = true
    ClearWins()
    SetStatus("Free Games completed")
    if total > 0 then Celebrate(total, "Winner") end
    SetBanner("")
  end

  busy = false
  Update()
  if InFree() then
    C_Timer.After(ev.total > 0 and 1.5 or 0.6, RequestSpin)
  elseif auto then
    C_Timer.After(ended and 1.2 or (ev.total > 0 and 1.4 or 0.45), function() if auto then RequestSpin() end end)
  end
end

-- ---------------------------------------------------------------- window
local function Button(parent, text, width, height, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, height)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function InsertBill(cents)
  db.cents = db.cents + cents
  db.stats.bills = db.stats.bills + cents
  Snd(SFX.moneyOpen)
  C_Timer.After(0.35, function() Snd(SFX.buyAndTrade) end)
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
    f:SetPoint("LEFT", UIParent, "LEFT", 40, 70)
  end
end
local function SavePosition()
  local f = UI.frame
  local point, _, relativePoint, x, y = f:GetPoint(1)
  if point then db.pos = { point, relativePoint, x, y } end
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

local function Build()
  if UI.frame then return end
  local f = CreateFrame("Frame", "LionsPrideFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  UI.frame = f
  f:SetSize(396, 560)
  -- Same layer as the game's own panels (character, bags, spellbook). Clicking it brings it to the
  -- front of that layer; dialogs, menus, tooltips and full-screen frames such as the map stay above it.
  f:SetFrameStrata("MEDIUM")
  f:SetToplevel(true)
  f:SetClampedToScreen(true) -- can't be dragged off screen
  f:SetMovable(true)
  f:EnableMouse(true)        -- takes clicks inside its own bounds only; it never takes the keyboard
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false) -- we save the position ourselves, so keep it out of the game's layout cache
    SavePosition()
  end)
  -- Closing the window (or the interface being hidden) stops auto-spin and silences anything still playing.
  -- A spin or bonus in progress finishes quietly in the background; its result is already banked.
  f:SetScript("OnHide", function()
    auto = false
    skipCount = true
    StopLongSounds()
    if cycleTicker then cycleTicker:Cancel(); cycleTicker = nil end
  end)
  f:SetScale(db.scale or 1)
  PlaceWindow()
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
  else
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.04, 0.03, 0.95)
  end
  tinsert(UISpecialFrames, "LionsPrideFrame") -- Esc closes it

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  UI.title = Text(f, 26, "OUTLINE", TITLE_FONT)
  UI.title:SetPoint("TOP", 0, -18)
  UI.title:SetText("Lion's Pride")
  UI.title:SetTextColor(1, 0.82, 0)

  -- Jackpots.
  UI.jp = {}
  local function Jackpot(key, size, point, x, y)
    local fs = Text(f, size, "OUTLINE")
    fs:SetPoint(point, f, "TOP", x, y)
    local c = JP_COLOR[key]
    fs:SetTextColor(c[1], c[2], c[3])
    UI.jp[key] = fs
  end
  Jackpot("grand", 20, "TOP", 0, -50)
  Jackpot("major", 16, "TOP", 0, -76)
  Jackpot("minor", 14, "TOPRIGHT", -12, -98)
  Jackpot("mini", 14, "TOPLEFT", 12, -98)

  -- XP bar.
  local xp = CreateFrame("StatusBar", nil, f)
  UI.xp = xp
  xp:SetSize(336, 12)
  xp:SetPoint("TOP", 0, -120)
  xp:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  xp:SetStatusBarColor(0.58, 0.0, 0.55)
  xp:SetMinMaxValues(0, 1)
  local xpBg = xp:CreateTexture(nil, "BACKGROUND")
  xpBg:SetAllPoints()
  xpBg:SetColorTexture(0, 0, 0, 0.7)
  UI.level = Text(xp, 10, "OUTLINE")
  UI.level:SetPoint("CENTER")

  UI.banner = Text(f, 15, "OUTLINE")
  UI.banner:SetPoint("TOP", 0, -138)

  -- Reels: a 5 x 3 grid of icon cells.
  local grid = CreateFrame("Frame", nil, f)
  UI.grid = grid
  grid:SetSize(E.REELS * STEP - GAP, E.ROWS * STEP - GAP)
  grid:SetPoint("TOP", 0, -160)
  local gridBg = grid:CreateTexture(nil, "BACKGROUND")
  gridBg:SetPoint("TOPLEFT", -4, 4)
  gridBg:SetPoint("BOTTOMRIGHT", 4, -4)
  gridBg:SetColorTexture(0, 0, 0, 0.9)

  UI.cells, UI.reelGlow = {}, {}
  for reel = 1, E.REELS do
    for row = 1, E.ROWS do
      local c = CreateFrame("Frame", nil, grid)
      c:SetSize(CELL, CELL)
      c:SetPoint("TOPLEFT", (reel - 1) * STEP, -(row - 1) * STEP)
      c.bg = c:CreateTexture(nil, "BACKGROUND")
      c.bg:SetAllPoints()
      c.bg:SetColorTexture(0.07, 0.05, 0.04, 1)
      c.border = c:CreateTexture(nil, "BORDER")
      c.border:SetPoint("TOPLEFT", 4, -4)
      c.border:SetPoint("BOTTOMRIGHT", -4, 4)
      c.icon = c:CreateTexture(nil, "ARTWORK")
      c.icon:SetPoint("TOPLEFT", 6, -6)
      c.icon:SetPoint("BOTTOMRIGHT", -6, 6)
      c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
      c.glow = c:CreateTexture(nil, "OVERLAY")
      c.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
      c.glow:SetBlendMode("ADD")
      c.glow:SetPoint("CENTER")
      c.glow:SetSize(CELL * 1.75, CELL * 1.75)
      c.glow:Hide()
      c.text = Text(c, 15, "OUTLINE")
      c.text:SetPoint("CENTER", 0, 0)
      UI.cells[E.key(reel, row)] = c
    end
    local g = grid:CreateTexture(nil, "OVERLAY")
    g:SetPoint("TOPLEFT", (reel - 1) * STEP - 2, 2)
    g:SetSize(CELL + 4, E.ROWS * STEP - GAP + 4)
    g:SetColorTexture(1, 0.82, 0, 0.22)
    g:SetBlendMode("ADD")
    g:Hide()
    UI.reelGlow[reel] = g
  end

  -- Big-win overlay, covering the reels. Click to skip the count.
  local o = CreateFrame("Button", nil, grid)
  UI.overlay = o
  o:SetAllPoints()
  o:SetFrameLevel(grid:GetFrameLevel() + 10)
  local oBg = o:CreateTexture(nil, "BACKGROUND")
  oBg:SetAllPoints()
  oBg:SetColorTexture(0.05, 0.03, 0.0, 0.9)
  o.title = Text(o, 36, "OUTLINE", TITLE_FONT)
  o.title:SetPoint("CENTER", 0, 42)
  o.title:SetTextColor(1, 0.82, 0.2)
  o.amount = Text(o, 30, "OUTLINE")
  o.amount:SetPoint("CENTER", 0, -2)
  o.amount:SetTextColor(1, 0.95, 0.5)
  o.credits = Text(o, 14, "OUTLINE")
  o.credits:SetPoint("CENTER", 0, -32)
  o.credits:SetTextColor(1, 0.82, 0)
  local hint = Text(o, 10)
  hint:SetPoint("BOTTOM", 0, 8)
  hint:SetTextColor(0.65, 0.6, 0.5)
  hint:SetText("Click to skip")
  o:SetScript("OnClick", function() skipCount = true end)
  o:Hide()

  UI.status = Text(f, 12)
  UI.status:SetPoint("TOP", grid, "BOTTOM", 0, -10)
  UI.status:SetWidth(360)
  UI.status:SetTextColor(0.7, 1, 0.7)

  -- Credit / bet / win readouts.
  local function Readout(label, x)
    local l = Text(f, 10)
    l:SetPoint("TOP", grid, "BOTTOM", x, -32)
    l:SetTextColor(1, 0.82, 0)
    l:SetText(label)
    local v = Text(f, 16, "OUTLINE")
    v:SetPoint("TOP", l, "BOTTOM", 0, -2)
    v:SetTextColor(0.8, 0.9, 1)
    return v
  end
  UI.credit = Readout("CREDIT", -116)
  UI.bet = Readout("BET", 0)
  UI.win = Readout("WIN", 116)

  -- Bet buttons: total bet in credits (25 lines x credits per line).
  UI.betButtons = {}
  for i, m in ipairs(E.BET_MULTS) do
    local b = Button(f, tostring(E.LINES * m), 62, 24, function()
      if busy or InFree() then return end
      db.betIdx = i; Snd(SFX.tick); Update()
    end)
    b:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", (i - 1) * 68 + 1, -76)
    Tip(b, "Bet " .. (E.LINES * m) .. " credits", E.LINES .. " lines at " .. m .. " credit" .. (m == 1 and "" or "s") .. " a line.")
    UI.betButtons[i] = b
  end

  UI.denom = Button(f, "", 110, 22, function()
    if busy or InFree() then return end
    db.denomIdx = db.denomIdx % #E.DENOMS + 1; Snd(SFX.tick); Update()
  end)
  UI.denom:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -106)
  Tip(UI.denom, "Denomination", "What one credit is worth. Click to change. Bets, wins and jackpots all scale with it.")
  UI.auto = Button(f, "", 80, 22, function()
    auto = not auto; Snd(SFX.tick); Update()
    if auto then RequestSpin() end
  end)
  UI.auto:SetPoint("LEFT", UI.denom, "RIGHT", 4, 0)
  UI.mute = Button(f, "", 90, 22, function() db.muted = not db.muted; Update() end)
  UI.mute:SetPoint("LEFT", UI.auto, "RIGHT", 4, 0)
  local help = Button(f, "?", 44, 22, function() ns.PrintRules() end)
  help:SetPoint("LEFT", UI.mute, "RIGHT", 4, 0)

  local bill20 = Button(f, "Insert $20", 96, 22, function() InsertBill(2000) end)
  bill20:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -134)
  local bill100 = Button(f, "Insert $100", 96, 22, function() InsertBill(10000) end)
  bill100:SetPoint("TOPLEFT", bill20, "BOTTOMLEFT", 0, -4)
  Tip(bill20, "Insert $20", "Play money only. It has nothing to do with your gold.")
  Tip(bill100, "Insert $100", "Play money only. It has nothing to do with your gold.")
  Tip(UI.auto, "Auto-spin", "Keeps spinning until you turn it off, close the window or enter combat.")
  Tip(help, "Rules", "Prints the rules and commands to chat.")

  UI.spin = Button(f, "SPIN", 228, 48, RequestSpin)
  UI.spin:SetPoint("TOPRIGHT", grid, "BOTTOMRIGHT", 0, -134)

  for k = 1, #UI.cells do RandomCell(k) end
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
    if InFree() and not busy then SetStatus("Free games waiting: press the button to continue") end
    Update()
  end
end

-- Combat and pet battles: stop auto-spin, and (by default) get out of the way until it is over.
-- Showing and hiding this window is always allowed: it is not a protected frame and calls nothing secure.
local function Suspend()
  auto = false
  if UI.frame and UI.frame:IsShown() then
    if db.hideInCombat then reopenAfter = true; UI.frame:Hide() else Update() end
  end
end
local function Resume()
  if reopenAfter and UI.frame then
    reopenAfter = false
    UI.frame:Show()
    if InFree() and not busy then SetStatus("Free games waiting: press the button to continue") end
    Update()
  end
end

-- ---------------------------------------------------------------- chat commands
local function Say(text) print("|cffffd100Lion's Pride:|r " .. text) end

function ns.PrintRules()
  Say("5 reels, " .. E.LINES .. " lines, wins pay left to right. Play money only.")
  Say(E.HOLD.trigger .. "+ Gold Orbs open the Darkmoon Faire: orbs lock, " .. E.HOLD.respins ..
    " respins, and every new ticket resets them. Fill all 15 spots for the Grand.")
  Say("3 / 4 / 5 Portals win " .. E.SCATTER_SPINS[3] .. " / " .. E.SCATTER_SPINS[4] .. " / " .. E.SCATTER_SPINS[5] ..
    " free games with line wins x" .. E.FREE_SPIN_MULT .. ".")
  Say("Every paid spin earns XP. A level-up opens the Faire with a buff.")
  Say("Commands: /slots, /slots rules, /slots stats, /slots scale 0.8, /slots resetpos, /slots combat, /slots reset")
end

local function PrintStats()
  local s = db.stats
  Say("Level " .. db.level .. ", credit " .. Money(db.cents) .. ", spins " .. Commas(s.spins))
  Say("Wagered " .. Money(s.wagered) .. ", won " .. Money(s.won) ..
    (s.wagered > 0 and string.format(" (%.1f%% return)", 100 * s.won / s.wagered) or ""))
  Say("Biggest win " .. Money(s.biggest) .. ", bonuses " .. s.bonuses .. ", play money inserted " .. Money(s.bills))
end

SLASH_LIONSPRIDE1 = "/lionspride"
SLASH_LIONSPRIDE2 = "/slots"
SlashCmdList["LIONSPRIDE"] = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "rules" or msg == "help" then
    ns.PrintRules()
  elseif msg == "stats" then
    PrintStats()
  elseif msg == "reset" then
    if busy then Say("Wait for the current spin to finish.") return end
    local keepMuted, keepScale, keepPos, keepCombat = db.muted, db.scale, db.pos, db.hideInCombat
    for k in pairs(db) do db[k] = nil end
    CopyDefaults(DEFAULTS, db)
    db.muted, db.scale, db.pos, db.hideInCombat = keepMuted, keepScale, keepPos, keepCombat
    hidden, winShown, auto = 0, 0, false
    Say("Reset to " .. Money(db.cents) .. " and Level 1.")
    if UI.frame then RestingBanner(); IdleStatus(); Update() end
  elseif msg == "resetpos" then
    db.pos = nil
    Build()
    PlaceWindow()
    UI.frame:Show(); Update()
    Say("Window moved back to its default spot.")
  elseif msg == "combat" then
    db.hideInCombat = not db.hideInCombat
    Say(db.hideInCombat and "The window will close when combat starts and reopen afterwards."
      or "The window will stay open in combat. Auto-spin still stops.")
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
    CopyDefaults(DEFAULTS, db)
    self:RegisterEvent("PLAYER_REGEN_DISABLED") -- entering combat
    self:RegisterEvent("PLAYER_REGEN_ENABLED")  -- leaving combat
    -- Pet battles only exist in some versions of the game; registering an unknown event is an error.
    pcall(self.RegisterEvent, self, "PET_BATTLE_OPENING_START")
    pcall(self.RegisterEvent, self, "PET_BATTLE_CLOSE")
    Say("loaded. Type /slots to play.")
  elseif not db then
    return
  elseif event == "PLAYER_REGEN_DISABLED" or event == "PET_BATTLE_OPENING_START" then
    Suspend()
  elseif event == "PLAYER_REGEN_ENABLED" or event == "PET_BATTLE_CLOSE" then
    Resume()
  end
end)
