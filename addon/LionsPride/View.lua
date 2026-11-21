-- Lion's Pride Casino: everything you see and hear.
-- The inn facade, the scrolling reels, win effects, particles, sound and music.
-- Every texture and sound is one of the game's own files (by path or file ID); nothing is shipped.
--
-- Shared tables (also used by UI.lua):
--   ns.UI  widget references      ns.S  runtime state
--   ns.V   drawing and animation  ns.A  sound and music

local _, ns = ...
local E = ns.Engine

local floor, min, max, random, sin, cos, abs, pi = math.floor, math.min, math.max, math.random, math.sin, math.cos, math.abs, math.pi

local UI, S, V, A = {}, {}, {}, {}
ns.UI, ns.S, ns.V, ns.A = UI, S, V, A

S.busy, S.auto = false, false
S.hidden = 0        -- cents already banked but not yet shown (revealed when a win or bonus plays out)
S.winShown = 0      -- cents on the WIN readout
S.skipCount = false -- set by clicking the big-win overlay
S.faire = 0         -- 0 = inn colours, 1 = Darkmoon Faire colours (animated between)

-- ---------------------------------------------------------------- layout
local W, H = 392, 676         -- window size
local POST = 14               -- timber post width
local CELL, GAP = 64, 4
local STEP = CELL + GAP
local GRID_W, GRID_H = E.REELS * STEP - GAP, E.ROWS * STEP - GAP
local EAVE = 46               -- how far the roof peak rises above the eaves
local Y = { roofBand = 84, grand = 96, major = 150, minor = 190, xp = 226, grid = 262, status = 472, meters = 498, controls = 552 }
V.W, V.H, V.CELL, V.STEP, V.Y, V.GRID_W, V.GRID_H = W, H, CELL, STEP, Y, GRID_W, GRID_H

local FONT, TITLE_FONT = "Fonts\\FRIZQT__.TTF", "Fonts\\MORPHEUS.TTF"

-- The Goldshire inn's own building textures, plus a few interface textures.
local TEX = {
  roof = 128759, beam = 129402, wall = 130052, planks = 127979, brick = 127100,
  parchment = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal",
  rail = "Interface\\MainMenuBar\\UI-MainMenuBar-Human",
  bar = "Interface\\TargetingFrame\\UI-StatusBar",
  darkmoon = "Interface\\PlayerActionBarAlt\\Darkmoon",
  levelup = "Interface\\LevelUp\\LevelUpTex",
  glow = "Interface\\Buttons\\UI-ActionButton-Border",
  star = "Interface\\Cooldown\\star4",
  circle = "Interface\\CharacterFrame\\TempPortraitAlphaMask",
  coin = "Interface\\Icons\\INV_Misc_Coin_17",
  goldIcon = "Interface\\MoneyFrame\\UI-GoldIcon",
}
local BEAM_V = 58 / 256 -- the beam texture's top band is the plain timber

local QUALITY = {
  common = { 0.85, 0.85, 0.85 }, uncommon = { 0.12, 1.00, 0.00 }, rare = { 0.00, 0.44, 0.87 },
  epic = { 0.64, 0.21, 0.93 }, legendary = { 1.00, 0.50, 0.00 }, artifact = { 0.90, 0.80, 0.50 },
  arcane = { 0.41, 0.80, 0.94 }, ticket = { 0.82, 0.29, 1.00 },
}
local JP_COLOR = {
  grand = { 1.00, 0.55, 0.10 }, major = { 0.80, 0.50, 1.00 }, minor = { 0.35, 0.72, 1.00 }, mini = { 0.35, 0.95, 0.35 },
}
local JP_NAME = { mini = "MINI", minor = "MINOR", major = "MAJOR", grand = "GRAND" }
V.JP_COLOR, V.JP_NAME = JP_COLOR, JP_NAME

function V.Commas(n)
  local s, k = tostring(floor(n + 0.5)), 0
  repeat s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
  return s
end
function V.Money(cents)
  cents = floor(cents + 0.5)
  return "$" .. V.Commas(floor(cents / 100)) .. string.format(".%02d", cents % 100)
end

-- ---------------------------------------------------------------- sound
A.SFX = {
  tick = 567407, coinSmall = 567428, coinLarge = 567413, levelUp = 567431,
  questComplete = 567439, questUpdate = 567516, questFailed = 567459,
  moneyOpen = 567483, auctionClose = 567499,
  rollStart = 642827, rollLoop = 642825, rollEnd = 642823,
  epicLoot = 642829, legendary = 1489461, stinger = 1067170,
  bell = 1100031, cheer = 568821, fanfare = 53211,
  forgetSomething = 552181, buyAndTrade = 552177,
}
A.FIREWORKS = { 566373, 566585, 566862 }
A.CHEERS = { 540694, 540707 } -- "Outstanding!", "Excellent!"

-- Sounds go through the game's SFX channel, so the player's Sound Effects volume and toggle apply.
-- Nothing plays while the window is closed or the interface is hidden (Alt-Z, cinematics).
local longSounds = {}
function A.Snd(id, long)
  local db = ns.db
  if not id or not db or db.muted then return nil end
  if not UI.frame or not UI.frame:IsVisible() then return nil end
  local ok, _, handle = pcall(PlaySoundFile, id, "SFX")
  if not ok then return nil end
  if long and handle then longSounds[#longSounds + 1] = handle end
  return handle
end
function A.Any(list)
  if list and #list > 0 then return A.Snd(list[random(#list)]) end
end
function A.Stop(handle, fadeMs)
  if handle then pcall(StopSound, handle, fadeMs or 0) end
end
function A.StopLong()
  for i = #longSounds, 1, -1 do A.Stop(longSounds[i], 200); longSounds[i] = nil end
end

-- Music uses the game's music channel. While it plays it replaces the zone music, and stopping it
-- hands the channel back, so it is off unless the player turns it on (/slots music).
local MUSIC = { inn = { 53492, 53493, 53494 }, faire = { 772749 } }
local music = { mood = "inn", on = false, idx = 0, ticker = nil }
local function MusicNext()
  local list = MUSIC[music.mood]
  music.idx = music.idx % #list + 1
  music.on = pcall(PlayMusic, list[music.idx]) and true or false
end
function A.MusicStop()
  if music.ticker then music.ticker:Cancel(); music.ticker = nil end
  if music.on then pcall(StopMusic); music.on = false end
end
function A.MusicSync()
  local db = ns.db
  local want = db and db.music and not db.muted and UI.frame and UI.frame:IsVisible()
  if want then
    if not music.on then
      MusicNext()
      music.ticker = C_Timer.NewTicker(62, function() if music.on and #MUSIC[music.mood] > 1 then MusicNext() end end)
    end
  else
    A.MusicStop()
  end
end
function A.MusicMood(mood)
  if mood == music.mood then return end
  music.mood, music.idx = mood, 0
  if music.on then MusicNext() end
end

-- ---------------------------------------------------------------- small helpers
local function Text(parent, size, flags, font)
  local fs = parent:CreateFontString(nil, "OVERLAY")
  fs:SetFont(font or FONT, size, flags or "")
  fs:SetShadowColor(0, 0, 0, 1)
  fs:SetShadowOffset(1, -1)
  return fs
end
V.Text = Text

-- A texture tiled at `tile` pixels per repeat, with (u0, v0) as the pattern origin so
-- neighbouring pieces line up.
local function Tiled(tex, file, w, h, tile, u0, v0)
  u0, v0 = u0 or 0, v0 or 0
  tex:SetTexture(file, "REPEAT", "REPEAT")
  tex:SetTexCoord(u0 / tile, (u0 + w) / tile, v0 / tile, (v0 + h) / tile)
end
-- A timber beam along its length. Vertical beams turn the texture a quarter turn.
local function Beam(tex, length, vertical)
  tex:SetTexture(TEX.beam, "REPEAT", "REPEAT")
  local u = length / 256
  if vertical then
    tex:SetTexCoord(0, 0, u, 0, 0, BEAM_V, u, BEAM_V)
  else
    tex:SetTexCoord(0, u, 0, BEAM_V)
  end
end

-- Lists of textures the Faire theme recolours.
local tint = { roof = {}, wall = {}, beam = {}, panel = {} }

local function NewBeam(parent, layer, w, h, vertical, sub)
  local t = parent:CreateTexture(nil, layer or "BORDER", nil, sub or 0)
  t:SetSize(w, h)
  Beam(t, vertical and h or w, vertical)
  tint.beam[#tint.beam + 1] = t
  return t
end

-- A dark parchment panel in a timber frame.
local function Panel(parent, w, h)
  local p = CreateFrame("Frame", nil, parent)
  p:SetSize(w, h)
  p.bg = p:CreateTexture(nil, "BACKGROUND")
  p.bg:SetAllPoints()
  p.bg:SetTexture(TEX.parchment)
  p.bg:SetTexCoord(0.03, 0.97, 0.06, 0.94)
  tint.panel[#tint.panel + 1] = p.bg
  local top = NewBeam(p, "BORDER", w, 4); top:SetPoint("TOPLEFT")
  local bottom = NewBeam(p, "BORDER", w, 4); bottom:SetPoint("BOTTOMLEFT")
  local left = NewBeam(p, "BORDER", 4, h, true); left:SetPoint("TOPLEFT")
  local right = NewBeam(p, "BORDER", 4, h, true); right:SetPoint("TOPRIGHT")
  return p
end
V.Panel = Panel

-- ---------------------------------------------------------------- animation driver
-- One OnUpdate script runs everything that moves. It only ticks while the window is on screen,
-- and every animation is timed against the clock, so anything that was paused finishes at once.
local anims, animCount = {}, 0
function V.Animate(duration, fn)
  animCount = animCount + 1
  local a = anims[animCount]
  if not a then a = {}; anims[animCount] = a end
  a.t0, a.d, a.fn = GetTime(), duration, fn
  fn(0)
end
local function RunAnims(now)
  local i = 1
  while i <= animCount do
    local a = anims[i]
    local p = (now - a.t0) / a.d
    if p >= 1 then
      a.fn(1)
      anims[i], anims[animCount] = anims[animCount], a -- keep the table for reuse
      a.fn = nil
      animCount = animCount - 1
    else
      a.fn(p)
      i = i + 1
    end
  end
end
local function EaseOut(p) return 1 - (1 - p) ^ 3 end
local function EaseOutBack(p) local c = 1.9; local q = p - 1; return 1 + (c + 1) * q ^ 3 + c * q ^ 2 end

-- ---------------------------------------------------------------- reel cells
local SPIN_ORBS = { { x = 1 }, { x = 2 }, { x = 3 }, { x = 5 } } -- shown on orbs that flash past while spinning

local function MakeCell(parent)
  local c = CreateFrame("Frame", nil, parent)
  c:SetSize(CELL, CELL)
  c.border = c:CreateTexture(nil, "BORDER")
  c.border:SetPoint("TOPLEFT", 4, -4)
  c.border:SetPoint("BOTTOMRIGHT", -4, 4)
  c.icon = c:CreateTexture(nil, "ARTWORK")
  c.icon:SetPoint("TOPLEFT", 6, -6)
  c.icon:SetPoint("BOTTOMRIGHT", -6, 6)
  if c.CreateMaskTexture then -- lets the gold orb be drawn round
    c.mask = c:CreateMaskTexture()
    c.mask:SetTexture(TEX.circle, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    c.mask:SetAllPoints(c.icon)
  end
  c.pill = c:CreateTexture(nil, "OVERLAY", nil, 1)
  c.pill:SetColorTexture(0.05, 0.0, 0.1, 0.85)
  c.pill:SetPoint("BOTTOM", 0, 3)
  c.pill:SetSize(CELL - 14, 17)
  c.pill:Hide()
  c.text = Text(c, 16, "OUTLINE")
  c.text:SetPoint("CENTER")
  c.tag = Text(c, 13, "OUTLINE")
  c.tag:SetPoint("BOTTOM", 0, 5)
  c.r, c.g, c.b = 1, 1, 1
  c.masked = false
  return c
end

-- kind: "symbol" (data = symbol id), "orb" / "ticket" (data = prize), "ghost" (a spinning empty spot), "empty"
local function Render(c, kind, data)
  c.pill:Hide()
  c.text:SetText("")
  c.tag:SetText("")
  c.icon:SetAlpha(1)
  c.border:SetAlpha(1)
  c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  c.r, c.g, c.b = 1, 1, 1
  if c.masked then c.icon:RemoveMaskTexture(c.mask); c.masked = false end
  if kind == "empty" then
    c.icon:Hide(); c.border:Hide()
    return
  end
  c.icon:Show()
  if kind == "symbol" then
    local s = E.SYM[data]
    c.icon:SetTexture(s.icon)
    local q = QUALITY[s.quality] or QUALITY.common
    c.border:SetColorTexture(q[1], q[2], q[3], 1)
    c.border:Show()
  elseif kind == "ghost" then
    c.icon:SetTexture(E.TICKET_ICON)
    c.icon:SetAlpha(0.15 + random() * 0.3)
    c.border:Hide()
  elseif kind == "orb" then
    c.icon:SetTexture(E.SYM.orb.icon)
    c.border:Hide()
    if c.mask then c.icon:AddMaskTexture(c.mask); c.masked = true end
    if data.jackpot then
      local q = JP_COLOR[data.jackpot]
      c.r, c.g, c.b = q[1], q[2], q[3]
      c.text:SetText(JP_NAME[data.jackpot])
      c.text:SetTextColor(1, 1, 1)
    else
      c.text:SetText(V.Commas(data.x * S.betCredits))
      c.text:SetTextColor(0.25, 0.1, 0.0)
    end
  else -- ticket
    c.icon:SetTexture(E.TICKET_ICON)
    local q = data.jackpot and JP_COLOR[data.jackpot] or QUALITY.ticket
    c.border:SetColorTexture(q[1], q[2], q[3], 1)
    c.border:Show()
    c.pill:Show()
    if data.jackpot then
      c.tag:SetText(JP_NAME[data.jackpot]); c.tag:SetTextColor(q[1], q[2], q[3])
    else
      c.tag:SetText(V.Commas(data.x * S.betCredits)); c.tag:SetTextColor(1, 0.9, 0.55)
    end
  end
  c.icon:SetVertexColor(c.r, c.g, c.b)
end

local function RenderRandom(c)
  local id = E.pick()
  if E.SYM[id].orb then Render(c, "orb", SPIN_ORBS[random(#SPIN_ORBS)]) else Render(c, "symbol", id) end
end

-- ---------------------------------------------------------------- reels
-- Each reel is a clipped column holding five cells: one above the window, three in it, one below.
-- Spinning slides them down and recycles the bottom cell to the top with a new symbol.
local reels = {}
local SPIN_SPEED = STEP * 16 -- pixels per second

local function PlaceReel(r)
  for i = 1, 5 do
    r.w[i]:SetPoint("TOPLEFT", r.frame, "TOPLEFT", 0, -((i - 2) * STEP + r.off))
  end
end

-- The cell showing logical position k (1..15, down each reel in turn).
function V.Cell(k)
  local reel, row = E.unkey(k)
  return reels[reel].w[row + 1]
end
function V.SetCell(k, kind, data) Render(V.Cell(k), kind, data) end

function V.StartSpin()
  for i = 1, E.REELS do reels[i].spinning = true end
end

-- Stops a reel on its final symbols: they drop in from just above and settle with a small bounce.
function V.Land(i, res)
  local r = reels[i]
  r.spinning = false
  for row = 1, E.ROWS do
    local k = E.key(i, row)
    local id = res.grid[i][row]
    if E.SYM[id].orb then Render(r.w[row + 1], "orb", res.orbs[k] or SPIN_ORBS[1]) else Render(r.w[row + 1], "symbol", id) end
  end
  RenderRandom(r.w[1]); RenderRandom(r.w[5])
  local drop = STEP * 0.6
  V.Animate(0.36, function(p)
    r.off = -drop * (1 - EaseOutBack(p))
    PlaceReel(r)
  end)
end

-- Puts every reel at rest (used before the Faire board, and when redrawing a finished spin).
function V.RestReels()
  for i = 1, E.REELS do
    local r = reels[i]
    r.spinning, r.off = false, 0
    PlaceReel(r)
  end
end

function V.DrawSpin(res)
  V.RestReels()
  for reel = 1, E.REELS do
    for row = 1, E.ROWS do
      local k = E.key(reel, row)
      local id = res.grid[reel][row]
      if E.SYM[id].orb then V.SetCell(k, "orb", res.orbs[k] or SPIN_ORBS[1]) else V.SetCell(k, "symbol", id) end
    end
  end
end

function V.RandomBoard()
  V.RestReels()
  for k = 1, E.REELS * E.ROWS do RenderRandom(V.Cell(k)) end
end

-- ---------------------------------------------------------------- win effects
local function CellCentre(k)
  local reel, row = E.unkey(k)
  return (reel - 1) * STEP + CELL / 2, -((row - 1) * STEP + CELL / 2)
end

-- A burst of light on one cell: used when a portal, orb or ticket lands.
function V.Pop(k)
  local t = UI.flash[k]
  t:Show()
  V.Animate(0.45, function(p)
    local size = CELL * (1.1 + 1.0 * p)
    t:SetSize(size, size)
    t:SetAlpha(1 - p)
    if p >= 1 then t:Hide() end
  end)
end

function V.Glow(k, on)
  if on then UI.glow[k]:Show() else UI.glow[k]:Hide() end
end

local function Dim(c, dim)
  local f = dim and 0.3 or 1
  c.icon:SetVertexColor(c.r * f, c.g * f, c.b * f)
  c.border:SetAlpha(dim and 0.3 or 1)
end

function V.HideLines()
  for i = 1, UI.lineCount do UI.lines[i]:Hide() end
  UI.lineCount = 0
end

-- Draws one payline across the reels.
function V.DrawLine(lineIndex)
  if not UI.fx.CreateLine then return end
  local line = E.PAYLINES[lineIndex]
  for reel = 1, E.REELS - 1 do
    UI.lineCount = UI.lineCount + 1
    local seg = UI.lines[UI.lineCount]
    if not seg then
      seg = UI.fx:CreateLine(nil, "OVERLAY")
      seg:SetThickness(3)
      seg:SetColorTexture(1, 0.9, 0.5, 0.9)
      UI.lines[UI.lineCount] = seg
    end
    local x1, y1 = CellCentre(E.key(reel, line[reel]))
    local x2, y2 = CellCentre(E.key(reel + 1, line[reel + 1]))
    seg:SetStartPoint("TOPLEFT", UI.fx, x1, y1)
    seg:SetEndPoint("TOPLEFT", UI.fx, x2, y2)
    seg:Show()
  end
end

-- Lights the given cells and dims the rest.
function V.Highlight(cells)
  local lit = S.lit
  for k = 1, 15 do lit[k] = false end
  for _, k in ipairs(cells) do lit[k] = true end
  for k = 1, 15 do
    V.Glow(k, lit[k])
    Dim(V.Cell(k), not lit[k])
  end
end
S.lit = {}

function V.ClearWins()
  if S.cycleTicker then S.cycleTicker:Cancel(); S.cycleTicker = nil end
  V.HideLines()
  for k = 1, 15 do
    V.Glow(k, false)
    Dim(V.Cell(k), false)
  end
  V.Tease(nil)
end

-- The pulsing gold glow on a reel that is spinning on in suspense.
function V.Tease(reel)
  S.teaseReel = reel
  for i = 1, E.REELS do
    if i == reel then UI.reelGlow[i]:Show() else UI.reelGlow[i]:Hide() end
  end
end

-- The XP bar's glow: on while the bar is nearly full.
function V.SetXPHot(hot)
  S.xpHot = hot
  if not hot and not S.xpFlashing then UI.xpGlow:SetAlpha(0) end
end
-- A bright flash on the XP bar for a level-up.
function V.XPFlash()
  S.xpFlashing = true
  V.Animate(1.3, function(p)
    UI.xpGlow:SetAlpha(1 - p)
    if p >= 1 then S.xpFlashing = false end
  end)
end

-- One clean impact: the reel window drops a few pixels and settles.
function V.Thud()
  V.Animate(0.32, function(p)
    local y = -7 * sin(pi * min(1, p * 1.6)) * (1 - p)
    UI.grid:SetPoint("TOP", UI.frame, "TOP", 0, -Y.grid + y)
  end)
end

-- ---------------------------------------------------------------- theme
local INN = { roof = { 1, 1, 1 }, wall = { 0.46, 0.54, 0.78 }, beam = { 0.80, 0.74, 0.68 }, panel = { 0.42, 0.31, 0.20 } }
local FAIRE = { roof = { 0.72, 0.42, 1.0 }, wall = { 0.40, 0.22, 0.62 }, beam = { 0.62, 0.42, 0.85 }, panel = { 0.34, 0.16, 0.44 } }

-- p = 0 is the inn, p = 1 is the Darkmoon Faire. Everything in between is a blend.
function V.SetTheme(p)
  S.faire = p
  for key, list in pairs(tint) do
    local a, b = INN[key], FAIRE[key]
    local r, g, bl = a[1] + (b[1] - a[1]) * p, a[2] + (b[2] - a[2]) * p, a[3] + (b[3] - a[3]) * p
    for i = 1, #list do list[i]:SetVertexColor(r, g, bl) end
  end
  UI.velvet:SetAlpha(p)
  UI.curtain:SetAlpha(p)
  UI.title:SetText(p > 0.5 and "Darkmoon Faire" or "Lion's Pride Casino")
  UI.title:SetTextColor(1, 0.82 - 0.27 * p, p)
end
function V.FadeTheme(to, seconds)
  local from = S.faire
  V.Animate(seconds or 1.2, function(p) V.SetTheme(from + (to - from) * EaseOut(p)) end)
end
-- Fades the reel board in (after its cells have been swapped).
function V.FadeBoard()
  V.Animate(0.7, function(p) UI.reelHolder:SetAlpha(p) end)
end

-- ---------------------------------------------------------------- particles
-- Coins and firework sparks are textures taken from fixed pools: nothing is created while playing.
local COIN_MAX, SPARK_MAX = 48, 150
local coins, sparks = {}, {}
local SPARK_COLOURS = { { 0.82, 0.29, 1 }, { 1, 0.31, 0.85 }, { 1, 0.82, 0 }, { 0.49, 1, 0.49 }, { 0.41, 0.8, 0.94 }, { 1, 1, 1 } }

local function BuildParticles(sky)
  for i = 1, COIN_MAX do
    local t = sky:CreateTexture(nil, "OVERLAY")
    if sky.CreateMaskTexture then
      t:SetTexture(TEX.coin)
      t:SetTexCoord(0.1, 0.9, 0.12, 0.92)
      local m = sky:CreateMaskTexture()
      m:SetTexture(TEX.circle, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      m:SetAllPoints(t)
      t:AddMaskTexture(m)
    else
      t:SetTexture(TEX.goldIcon)
    end
    t:Hide()
    coins[i] = { tex = t, live = false }
  end
  for i = 1, SPARK_MAX do
    local t = sky:CreateTexture(nil, "OVERLAY")
    t:SetTexture(TEX.star)
    t:SetBlendMode("ADD")
    t:SetSize(14, 14)
    t:Hide()
    sparks[i] = { tex = t, live = false }
  end
end

-- n coins fountain up out of the middle of the reel window.
function V.Coins(n)
  for i = 1, COIN_MAX do
    if n <= 0 then break end
    local c = coins[i]
    if not c.live then
      c.live = true
      local a = pi / 2 + (random() - 0.5) * 1.5
      local v = 330 + random() * 300
      c.x, c.y = (random() - 0.5) * 60, -20
      c.vx, c.vy = cos(a) * v * 0.8, sin(a) * v
      c.size = 18 + random() * 14
      c.spin, c.vs = random() * 6, 6 + random() * 9
      c.delay = random() * 0.5
      n = n - 1
    end
  end
end

-- One firework burst somewhere above the window.
function V.Firework()
  local x, y = (random() - 0.5) * (W + 160), 120 + random() * 220
  local c1, c2 = SPARK_COLOURS[random(#SPARK_COLOURS)], SPARK_COLOURS[random(#SPARK_COLOURS)]
  local n = 0
  for i = 1, SPARK_MAX do
    local s = sparks[i]
    if not s.live then
      s.live = true
      local a, v = random() * 2 * pi, 50 + random() * 190
      s.x, s.y, s.vx, s.vy = x, y, cos(a) * v, sin(a) * v
      s.life, s.decay = 1, 0.8 + random() * 0.7
      local c = (n % 3 == 0) and c2 or c1
      s.tex:SetVertexColor(c[1], c[2], c[3])
      s.tex:Show()
      n = n + 1
      if n >= 24 then break end
    end
  end
end

local function RunParticles(dt)
  for i = 1, COIN_MAX do
    local c = coins[i]
    if c.live then
      if c.delay > 0 then
        c.delay = c.delay - dt
        if c.delay <= 0 then c.tex:Show() end
      else
        c.vy = c.vy - 1050 * dt
        c.x, c.y = c.x + c.vx * dt, c.y + c.vy * dt
        c.spin = c.spin + c.vs * dt
        if c.y < -H then
          c.live = false; c.tex:Hide()
        else
          c.tex:SetSize(max(2, c.size * abs(cos(c.spin))), c.size) -- flips edge-on as it turns
          c.tex:SetPoint("CENTER", UI.grid, "CENTER", c.x, c.y)
        end
      end
    end
  end
  for i = 1, SPARK_MAX do
    local s = sparks[i]
    if s.live then
      s.life = s.life - s.decay * dt
      if s.life <= 0 then
        s.live = false; s.tex:Hide()
      else
        s.vy = s.vy - 110 * dt
        s.x, s.y = s.x + s.vx * dt, s.y + s.vy * dt
        s.tex:SetAlpha(s.life)
        s.tex:SetPoint("CENTER", UI.grid, "CENTER", s.x, s.y)
      end
    end
  end
end
function V.ClearParticles()
  for i = 1, COIN_MAX do coins[i].live = false; coins[i].tex:Hide() end
  for i = 1, SPARK_MAX do sparks[i].live = false; sparks[i].tex:Hide() end
end

-- ---------------------------------------------------------------- the driver
local function OnUpdate(_, elapsed)
  local dt = min(elapsed, 0.1)
  local now = GetTime()
  for i = 1, E.REELS do
    local r = reels[i]
    if r.spinning then
      r.off = r.off + SPIN_SPEED * dt
      while r.off >= STEP do
        r.off = r.off - STEP
        local w = r.w
        local last = w[5]
        w[5], w[4], w[3], w[2] = w[4], w[3], w[2], w[1]
        w[1] = last
        RenderRandom(last)
      end
      PlaceReel(r)
    end
  end
  if S.teaseReel then UI.reelGlow[S.teaseReel]:SetAlpha(0.20 + 0.16 * sin(now * 14)) end
  if S.xpHot and not S.xpFlashing then UI.xpGlow:SetAlpha(0.22 + 0.2 * sin(now * 7)) end
  if UI.overlay:IsShown() then
    local a = 0.55 + 0.25 * sin(now * 3.5)
    UI.overlay.glowTop:SetAlpha(a); UI.overlay.glowBottom:SetAlpha(a)
  end
  if animCount > 0 then RunAnims(now) end
  RunParticles(dt)
end

-- ---------------------------------------------------------------- building the window
local function BuildRoof(f)
  -- The peak: a stack of thin strips that widen towards the eaves. Each strip is timber with
  -- shingles inset, which leaves a timber edge running down both slopes.
  local strips, h = 23, EAVE / 23
  for i = 1, strips do
    local w = W * i / strips
    local y = (i - 1) * h
    local edge = f:CreateTexture(nil, "ARTWORK", nil, 1)
    edge:SetSize(w, h + 0.5)
    edge:SetPoint("TOP", f, "TOP", 0, -y)
    Beam(edge, w)
    tint.beam[#tint.beam + 1] = edge
    local inner = w - 16
    if inner > 4 and i > 3 then
      local sh = f:CreateTexture(nil, "ARTWORK", nil, 2)
      sh:SetSize(inner, h + 0.5)
      sh:SetPoint("TOP", f, "TOP", 0, -y)
      Tiled(sh, TEX.roof, inner, h, 128, (W - inner) / 2, y)
      tint.roof[#tint.roof + 1] = sh
    end
  end
  -- The band of roof below the eaves.
  local bandH = Y.roofBand - EAVE
  local edge = f:CreateTexture(nil, "ARTWORK", nil, 1)
  edge:SetSize(W, bandH)
  edge:SetPoint("TOP", f, "TOP", 0, -EAVE)
  Beam(edge, W)
  tint.beam[#tint.beam + 1] = edge
  local band = f:CreateTexture(nil, "ARTWORK", nil, 2)
  band:SetSize(W - 16, bandH - 7)
  band:SetPoint("TOP", f, "TOP", 0, -EAVE)
  Tiled(band, TEX.roof, W - 16, bandH - 7, 128, 8, EAVE)
  tint.roof[#tint.roof + 1] = band
  local shade = f:CreateTexture(nil, "ARTWORK", nil, 3)
  shade:SetSize(W - 2 * POST, 10)
  shade:SetPoint("TOP", f, "TOP", 0, -Y.roofBand)
  shade:SetColorTexture(0, 0, 0, 0.45)

  -- The hanging sign, wide enough for "Lion's Pride Casino".
  local SIGN_W = 290 -- stops short of the close button
  local sign = CreateFrame("Frame", nil, f)
  sign:SetSize(SIGN_W, 40)
  sign:SetPoint("TOP", f, "TOP", 0, -(Y.roofBand - 32))
  sign:SetFrameLevel(f:GetFrameLevel() + 3)
  local bg = sign:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  Tiled(bg, TEX.planks, SIGN_W, 40, 128)
  bg:SetVertexColor(0.33, 0.27, 0.22)
  local top = NewBeam(sign, "BORDER", SIGN_W, 5); top:SetPoint("TOPLEFT")
  local bottom = NewBeam(sign, "BORDER", SIGN_W, 5); bottom:SetPoint("BOTTOMLEFT")
  local left = NewBeam(sign, "BORDER", 5, 40, true); left:SetPoint("TOPLEFT")
  local right = NewBeam(sign, "BORDER", 5, 40, true); right:SetPoint("TOPRIGHT")
  UI.title = Text(sign, 25, "OUTLINE", TITLE_FONT)
  UI.title:SetPoint("CENTER", 0, 0)
end

local function BuildWalls(f)
  local wallH = H - Y.roofBand
  local wall = f:CreateTexture(nil, "BACKGROUND", nil, 0)
  wall:SetSize(W - 2 * POST, wallH)
  wall:SetPoint("TOP", f, "TOP", 0, -Y.roofBand)
  Tiled(wall, TEX.wall, W - 2 * POST, wallH, 182)
  tint.wall[1] = wall
  -- Purple velvet for the Faire, faded in over the plaster.
  UI.velvet = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  UI.velvet:SetAllPoints(wall)
  UI.velvet:SetTexture(TEX.darkmoon)
  UI.velvet:SetTexCoord(0, 1, 94 / 512, 176 / 512)
  UI.velvet:SetAlpha(0)
  -- Timber posts and the sill.
  local postH = H - EAVE
  local left = NewBeam(f, "BORDER", POST, postH, true); left:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -EAVE)
  local right = NewBeam(f, "BORDER", POST, postH, true); right:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -EAVE)
  local sill = NewBeam(f, "BORDER", W, POST, false, 1); sill:SetPoint("BOTTOMLEFT")
end

local function BuildJackpots(f)
  UI.jp = {}
  local function Row(key, w, h, size, x, y, label)
    local p = Panel(f, w, h)
    p:SetPoint("TOP", f, "TOP", x, -y)
    local c = JP_COLOR[key]
    local name = Text(p, 10, "OUTLINE")
    name:SetText(label)
    name:SetTextColor(c[1], c[2], c[3])
    local value = Text(p, size, "OUTLINE")
    value:SetTextColor(c[1], c[2], c[3])
    if key == "grand" then
      name:SetPoint("TOP", 0, -8); value:SetPoint("TOP", name, "BOTTOM", 0, -2)
    else
      name:SetPoint("RIGHT", p, "CENTER", -8, 0); value:SetPoint("LEFT", p, "CENTER", -2, 0)
    end
    p.value = value
    UI.jp[key] = p
  end
  Row("grand", GRID_W, 48, 24, 0, Y.grand, "GRAND JACKPOT")
  Row("major", GRID_W, 34, 19, 0, Y.major, "MAJOR JACKPOT")
  Row("minor", GRID_W / 2 - 3, 30, 15, -(GRID_W / 4 + 1.5), Y.minor, "MINOR")
  Row("mini", GRID_W / 2 - 3, 30, 15, GRID_W / 4 + 1.5, Y.minor, "MINI")
end

-- The XP bar as in game: purple fill under the action bar's segmented metal rail.
-- The same panel shows the banner text for wins and bonuses.
local function BuildXP(f)
  local p = Panel(f, GRID_W, 28)
  p:SetPoint("TOP", f, "TOP", 0, -Y.xp)
  UI.xpPanel = p
  local xp = CreateFrame("StatusBar", nil, p)
  UI.xp = xp
  xp:SetSize(GRID_W - 20, 14)
  xp:SetPoint("CENTER")
  xp:SetStatusBarTexture(TEX.bar)
  xp:SetStatusBarColor(0.58, 0.0, 0.55)
  xp:SetMinMaxValues(0, 1)
  local back = xp:CreateTexture(nil, "BACKGROUND")
  back:SetAllPoints()
  back:SetColorTexture(0.04, 0.0, 0.06, 0.9)
  for half = 0, 1 do -- the rail texture holds five segments; two copies make ten
    local rail = xp:CreateTexture(nil, "OVERLAY")
    rail:SetSize((GRID_W - 20) / 2, 16)
    rail:SetPoint("LEFT", xp, "LEFT", half * (GRID_W - 20) / 2, 0)
    rail:SetTexture(TEX.rail)
    rail:SetTexCoord(0, 1, 10 / 256, 22 / 256)
  end
  -- A glow over the bar: it pulses when the bar is nearly full and flashes on a level-up.
  UI.xpGlow = xp:CreateTexture(nil, "OVERLAY", nil, 2)
  UI.xpGlow:SetPoint("TOPLEFT", -4, 5)
  UI.xpGlow:SetPoint("BOTTOMRIGHT", 4, -5)
  UI.xpGlow:SetTexture(TEX.bar)
  UI.xpGlow:SetBlendMode("ADD")
  UI.xpGlow:SetVertexColor(1, 0.55, 1)
  UI.xpGlow:SetAlpha(0)
  UI.banner = Text(p, 15, "OUTLINE")
  UI.banner:SetPoint("CENTER")
  UI.banner:SetWidth(GRID_W - 16)
end

local function BuildReels(f)
  -- The reel window: a timber frame with a warm glow behind it, like the inn's lit windows.
  local glow = f:CreateTexture(nil, "BACKGROUND", nil, 2)
  glow:SetTexture(TEX.star)
  glow:SetBlendMode("ADD")
  glow:SetVertexColor(1, 0.62, 0.2, 0.55)
  glow:SetSize(GRID_W * 1.7, GRID_H * 2.1)
  glow:SetPoint("CENTER", f, "TOP", 0, -(Y.grid + GRID_H / 2))
  UI.warmGlow = glow

  local grid = CreateFrame("Frame", nil, f)
  UI.grid = grid
  grid:SetSize(GRID_W, GRID_H)
  grid:SetPoint("TOP", f, "TOP", 0, -Y.grid)
  local back = grid:CreateTexture(nil, "BACKGROUND")
  back:SetPoint("TOPLEFT", -3, 3)
  back:SetPoint("BOTTOMRIGHT", 3, -3)
  back:SetColorTexture(0.02, 0.01, 0.0, 1)
  local t = NewBeam(grid, "BORDER", GRID_W + 18, 6); t:SetPoint("BOTTOM", grid, "TOP", 0, 3)
  local b = NewBeam(grid, "BORDER", GRID_W + 18, 6); b:SetPoint("TOP", grid, "BOTTOM", 0, -3)
  local l = NewBeam(grid, "BORDER", 6, GRID_H + 6, true); l:SetPoint("RIGHT", grid, "LEFT", -3, 0)
  local r = NewBeam(grid, "BORDER", 6, GRID_H + 6, true); r:SetPoint("LEFT", grid, "RIGHT", 3, 0)

  local holder = CreateFrame("Frame", nil, grid)
  UI.reelHolder = holder
  holder:SetAllPoints()
  for i = 1, E.REELS do
    local col = CreateFrame("Frame", nil, holder)
    col:SetSize(CELL, GRID_H)
    col:SetPoint("TOPLEFT", (i - 1) * STEP, 0)
    if col.SetClipsChildren then col:SetClipsChildren(true) end
    local shade = col:CreateTexture(nil, "BACKGROUND")
    shade:SetAllPoints()
    shade:SetColorTexture(0.10, 0.06, 0.03, 1)
    local reel = { frame = col, w = {}, off = 0, spinning = false }
    for n = 1, 5 do reel.w[n] = MakeCell(col) end
    reels[i] = reel
    PlaceReel(reel)
  end

  -- Effects drawn over the reels: win glows, landing flashes, the suspense glow, paylines, the curtain.
  local fx = CreateFrame("Frame", nil, grid)
  UI.fx = fx
  fx:SetAllPoints()
  fx:SetFrameLevel(holder:GetFrameLevel() + 6)
  UI.glow, UI.flash, UI.reelGlow, UI.lines, UI.lineCount = {}, {}, {}, {}, 0
  for k = 1, E.REELS * E.ROWS do
    local x, y = CellCentre(k)
    local g = fx:CreateTexture(nil, "ARTWORK")
    g:SetTexture(TEX.glow)
    g:SetBlendMode("ADD")
    g:SetSize(CELL * 1.75, CELL * 1.75)
    g:SetPoint("CENTER", fx, "TOPLEFT", x, y)
    g:Hide()
    UI.glow[k] = g
    local fl = fx:CreateTexture(nil, "OVERLAY")
    fl:SetTexture(TEX.star)
    fl:SetBlendMode("ADD")
    fl:SetVertexColor(1, 0.9, 0.6)
    fl:SetPoint("CENTER", fx, "TOPLEFT", x, y)
    fl:Hide()
    UI.flash[k] = fl
  end
  for i = 1, E.REELS do
    local g = fx:CreateTexture(nil, "BACKGROUND")
    g:SetPoint("TOPLEFT", (i - 1) * STEP - 2, 2)
    g:SetSize(CELL + 4, GRID_H + 4)
    g:SetColorTexture(1, 0.82, 0, 1)
    g:SetBlendMode("ADD")
    g:SetAlpha(0.25)
    g:Hide()
    UI.reelGlow[i] = g
  end
  UI.curtain = fx:CreateTexture(nil, "OVERLAY", nil, 2)
  UI.curtain:SetTexture(TEX.darkmoon)
  UI.curtain:SetTexCoord(0, 1, 6 / 512, 32 / 512)
  UI.curtain:SetSize(GRID_W + 18, 24)
  UI.curtain:SetPoint("TOP", fx, "TOP", 0, 10)
  UI.curtain:SetAlpha(0)

  -- The big-win overlay, covering the reel window. Click to skip the count.
  local o = CreateFrame("Button", nil, grid)
  UI.overlay = o
  o:SetAllPoints()
  o:SetFrameLevel(holder:GetFrameLevel() + 12)
  local dark = o:CreateTexture(nil, "BACKGROUND")
  dark:SetAllPoints()
  dark:SetColorTexture(0.06, 0.03, 0.0, 0.92)
  o.glowTop = o:CreateTexture(nil, "BORDER")
  o.glowTop:SetTexture(TEX.levelup)
  o.glowTop:SetTexCoord(270 / 512, 511 / 512, 130 / 512, 238 / 512)
  o.glowTop:SetBlendMode("ADD")
  o.glowTop:SetSize(GRID_W, 86)
  o.glowTop:SetPoint("BOTTOM", o, "CENTER", 0, 8)
  o.glowBottom = o:CreateTexture(nil, "BORDER")
  o.glowBottom:SetTexture(TEX.levelup)
  o.glowBottom:SetTexCoord(270 / 512, 511 / 512, 238 / 512, 130 / 512) -- the same half-disc, flipped
  o.glowBottom:SetBlendMode("ADD")
  o.glowBottom:SetSize(GRID_W, 86)
  o.glowBottom:SetPoint("TOP", o, "CENTER", 0, 8)
  o.title = Text(o, 38, "OUTLINE", TITLE_FONT)
  o.title:SetPoint("CENTER", 0, 44)
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
  o:SetScript("OnClick", function() S.skipCount = true end)
  o:Hide()
end

-- The title slams in a little larger and settles.
function V.TitlePop(name)
  local t = UI.overlay.title
  t:SetText(name)
  V.Animate(0.4, function(p)
    t:SetAlpha(min(1, 0.3 + p * 1.4))
    if t.SetTextHeight then t:SetTextHeight(38 * (1 + 0.45 * (1 - EaseOut(p)))) end
  end)
end

local function BuildLower(f)
  -- Status text on a beam.
  local beam = CreateFrame("Frame", nil, f)
  beam:SetSize(GRID_W + 18, 22)
  beam:SetPoint("TOP", f, "TOP", 0, -Y.status)
  local wood = NewBeam(beam, "BACKGROUND", GRID_W + 18, 22)
  wood:SetAllPoints()
  local shade = beam:CreateTexture(nil, "BORDER")
  shade:SetAllPoints()
  shade:SetColorTexture(0, 0, 0, 0.45)
  UI.status = Text(beam, 12)
  UI.status:SetPoint("CENTER")
  UI.status:SetWidth(GRID_W + 8)
  UI.status:SetTextColor(0.72, 1, 0.72)

  -- Credit / bet / win: three dark readout boxes on planks.
  local planks = CreateFrame("Frame", nil, f)
  planks:SetSize(GRID_W + 18, 46)
  planks:SetPoint("TOP", f, "TOP", 0, -Y.meters)
  local pb = planks:CreateTexture(nil, "BACKGROUND")
  pb:SetAllPoints()
  Tiled(pb, TEX.planks, GRID_W + 18, 46, 128)
  pb:SetVertexColor(0.36, 0.30, 0.25)
  local function Readout(label, index)
    local w = (GRID_W + 18 - 4 * 6) / 3
    local box = CreateFrame("Frame", nil, planks)
    box:SetSize(w, 36)
    box:SetPoint("LEFT", planks, "LEFT", 6 + (index - 1) * (w + 6), 0)
    local dark = box:CreateTexture(nil, "BACKGROUND")
    dark:SetAllPoints()
    dark:SetColorTexture(0.02, 0.02, 0.02, 0.88)
    local l = Text(box, 9)
    l:SetPoint("TOP", 0, -4)
    l:SetTextColor(1, 0.82, 0)
    l:SetText(label)
    local v = Text(box, 16, "OUTLINE")
    v:SetPoint("BOTTOM", 0, 4)
    v:SetTextColor(0.82, 0.9, 1)
    return v
  end
  UI.credit = Readout("CREDIT", 1)
  UI.bet = Readout("BET", 2)
  UI.win = Readout("WIN", 3)

  -- Where UI.lua puts the buttons.
  local controls = CreateFrame("Frame", nil, f)
  controls:SetSize(GRID_W, 104)
  controls:SetPoint("TOP", f, "TOP", 0, -Y.controls)
  UI.controls = controls
end

-- Builds the whole facade inside the main frame.
function V.Build(f)
  UI.frame = f
  f:SetSize(W, H)
  BuildWalls(f)
  BuildRoof(f)
  BuildJackpots(f)
  BuildXP(f)
  BuildReels(f)
  BuildLower(f)

  -- Coins and fireworks fly on a layer above everything in the window. It takes no mouse input.
  local sky = CreateFrame("Frame", nil, f)
  sky:SetAllPoints()
  sky:SetFrameLevel(f:GetFrameLevel() + 30)
  UI.sky = sky
  BuildParticles(sky)

  local driver = CreateFrame("Frame", nil, f)
  driver:SetScript("OnUpdate", OnUpdate)
  UI.driver = driver

  V.SetTheme(0)
end
