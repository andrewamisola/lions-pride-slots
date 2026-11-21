-- Lion's Pride Casino: the minimap button and the settings panel.
-- Both are written here from scratch; the addon ships no libraries.

local _, ns = ...
local UI, S, V, A = ns.UI, ns.S, ns.V, ns.A

local cos, sin, rad, deg, atan2 = math.cos, math.sin, math.rad, math.deg, math.atan2
local floor, min, max = math.floor, math.min, math.max

local O = {}
ns.O = O

-- ---------------------------------------------------------------- applying settings
function O.SetSound(on)
  ns.db.muted = not on
  if not on then A.StopLong() end
  A.MusicSync()
  ns.Update()
end
function O.SetMusic(on)
  ns.db.music = on and true or false
  A.MusicSync()
  ns.Update()
end
function O.SetScale(scale)
  scale = max(0.5, min(1.5, floor(scale * 20 + 0.5) / 20)) -- steps of 5%
  ns.db.scale = scale
  if UI.frame then UI.frame:SetScale(scale) end
  return scale
end
function O.SetMinimapShown(shown)
  ns.db.minimap.hide = not shown
  O.UpdateMinimapButton()
end

-- ---------------------------------------------------------------- minimap button
-- The standard look: an icon inside the minimap's round tracking border, sitting on the rim.
-- Left click opens and closes the window. Drag it around the rim; the angle is saved.
local function PlaceOnRim(button)
  local angle = rad(ns.db.minimap.angle or 215)
  local radius = (Minimap:GetWidth() / 2) + 5
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", cos(angle) * radius, sin(angle) * radius)
end

local function FollowCursor(button)
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  if not mx or not px or not scale or scale == 0 then return end
  ns.db.minimap.angle = deg(atan2(py / scale - my, px / scale - mx)) % 360
  PlaceOnRim(button)
end

function O.BuildMinimapButton()
  if O.minimapButton or not Minimap then return end
  local b = CreateFrame("Button", "LionsPrideMinimapButton", Minimap)
  O.minimapButton = b
  b:SetSize(31, 31)
  b:SetFrameStrata("MEDIUM")
  b:SetFrameLevel(8)
  b:RegisterForClicks("LeftButtonUp")
  b:RegisterForDrag("LeftButton")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local back = b:CreateTexture(nil, "BACKGROUND")
  back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  back:SetSize(20, 20)
  back:SetPoint("TOPLEFT", 7, -5)
  local icon = b:CreateTexture(nil, "ARTWORK")
  icon:SetTexture("Interface\\Icons\\INV_Misc_Gem_Pearl_04") -- the gold orb
  icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  icon:SetSize(20, 20)
  icon:SetPoint("TOPLEFT", 7, -6)
  local border = b:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")

  b:SetScript("OnClick", function() ns.Toggle() end)
  b:SetScript("OnDragStart", function(self)
    self.dragging = true
    GameTooltip:Hide()
    self:SetScript("OnUpdate", FollowCursor)
  end)
  b:SetScript("OnDragStop", function(self)
    self.dragging = false
    self:SetScript("OnUpdate", nil)
  end)
  b:SetScript("OnEnter", function(self)
    if self.dragging then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Lion's Pride Casino", 1, 0.82, 0)
    GameTooltip:AddLine("Click to open", 1, 1, 1)
    GameTooltip:AddLine("Drag to move", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Play money only. No gold involved.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b.dragging = false
  O.UpdateMinimapButton()
end

function O.UpdateMinimapButton()
  local b = O.minimapButton
  if not b then return end
  if ns.db.minimap.hide then
    b:Hide()
  else
    PlaceOnRim(b)
    b:Show()
  end
end

-- The addon compartment (the addon list on the minimap in newer versions of the game) calls this
-- global if the client supports the "AddonCompartmentFunc" line in the .toc. Older clients ignore it.
function LionsPride_OnAddonCompartmentClick()
  if ns.db then ns.Toggle() end
end

-- ---------------------------------------------------------------- settings panel
local function Check(panel, y, label, tip, get, set)
  local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y)
  local text = V.Text(panel, 12)
  text:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  text:SetText(label)
  text:SetTextColor(1, 0.95, 0.85)
  cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
  cb:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(label, 1, 0.82, 0)
    GameTooltip:AddLine(tip, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
  panel.checks[#panel.checks + 1] = { box = cb, get = get }
  return cb
end

local function SmallButton(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

function O.BuildPanel()
  if O.panel then return end
  local p = CreateFrame("Frame", "LionsPrideOptionsFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  O.panel = p
  p:SetSize(290, 318)
  p:SetFrameStrata("DIALOG") -- above the slot window, like the game's own dialogs
  p:SetToplevel(true)
  p:SetClampedToScreen(true)
  p:SetMovable(true)
  p:EnableMouse(true)
  p:RegisterForDrag("LeftButton")
  p:SetScript("OnDragStart", p.StartMoving)
  p:SetScript("OnDragStop", p.StopMovingOrSizing)
  if p.SetBackdrop then
    p:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
      tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
  else
    local bg = p:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.04, 0.03, 0.95)
  end
  tinsert(UISpecialFrames, "LionsPrideOptionsFrame") -- Esc closes it

  local title = V.Text(p, 20, "OUTLINE", "Fonts\\MORPHEUS.TTF")
  title:SetPoint("TOP", 0, -18)
  title:SetText("Casino Options")
  title:SetTextColor(1, 0.82, 0)
  local close = CreateFrame("Button", nil, p, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -6, -6)

  p.checks = {}
  Check(p, -50, "Stop auto-spin in combat",
    "When combat or a pet battle starts, auto-spin turns off. The spin in progress finishes and pays as normal.",
    function() return ns.db.stopAutoInCombat end,
    function(v) ns.db.stopAutoInCombat = v end)
  Check(p, -78, "Close window in combat",
    "When combat or a pet battle starts, close the window and reopen it afterwards. Auto-spin stops as well.",
    function() return ns.db.hideInCombat end,
    function(v) ns.db.hideInCombat = v end)
  Check(p, -106, "Show minimap button",
    "A button on the minimap that opens and closes the casino. You can still use /slots or /casino when it is hidden.",
    function() return not ns.db.minimap.hide end,
    function(v) O.SetMinimapShown(v) end)
  Check(p, -134, "Sound effects",
    "Reel, win and bonus sounds. They use the game's Sound Effects volume.",
    function() return not ns.db.muted end,
    function(v) O.SetSound(v) end)
  Check(p, -162, "Music",
    "Elwynn Forest music while the window is open. It replaces the zone music until you turn it off or close the window.",
    function() return ns.db.music end,
    function(v) O.SetMusic(v) end)

  -- Window scale: minus and plus in steps of 5%.
  local scaleLabel = V.Text(p, 12)
  scaleLabel:SetPoint("TOPLEFT", p, "TOPLEFT", 22, -200)
  scaleLabel:SetText("Window scale")
  scaleLabel:SetTextColor(1, 0.95, 0.85)
  p.scaleValue = V.Text(p, 13, "OUTLINE")
  p.scaleValue:SetPoint("TOPLEFT", p, "TOPLEFT", 176, -200)
  p.scaleValue:SetWidth(52)
  local function Nudge(step)
    O.SetScale((ns.db.scale or 1) + step)
    O.RefreshPanel()
  end
  local minus = SmallButton(p, "-", 26, function() Nudge(-0.05) end)
  minus:SetPoint("TOPLEFT", p, "TOPLEFT", 146, -195)
  local plus = SmallButton(p, "+", 26, function() Nudge(0.05) end)
  plus:SetPoint("TOPLEFT", p, "TOPLEFT", 232, -195)

  local rules = SmallButton(p, "Rules", 78, function() ns.PrintRules() end)
  rules:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 20, 48)
  local resetPos = SmallButton(p, "Reset position", 110, function() ns.ResetPosition() end)
  resetPos:SetPoint("LEFT", rules, "RIGHT", 6, 0)
  local done = SmallButton(p, "Close", 78, function() p:Hide() end)
  done:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -20, 20)
  local note = V.Text(p, 10)
  note:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 22, 26)
  note:SetTextColor(0.7, 0.65, 0.55)
  note:SetText("Play money only. No gold involved.")

  p:SetScript("OnShow", O.RefreshPanel)
  p:Hide()
end

function O.RefreshPanel()
  local p = O.panel
  if not p then return end
  for _, c in ipairs(p.checks) do c.box:SetChecked(c.get() and true or false) end
  p.scaleValue:SetText(floor((ns.db.scale or 1) * 100 + 0.5) .. "%")
end

-- Opens or closes the settings panel, beside the slot window when that is open.
function O.Toggle()
  O.BuildPanel()
  local p = O.panel
  if p:IsShown() then
    p:Hide()
    return
  end
  p:ClearAllPoints()
  if UI.frame and UI.frame:IsShown() then
    p:SetPoint("TOPLEFT", UI.frame, "TOPRIGHT", 10, -100)
  else
    p:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
  end
  p:Show()
  O.RefreshPanel()
end
