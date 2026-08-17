-- NemesisStrongbox.lua
-- Reads C_Spell.GetSpellDescription(activeDelveSpellID) and parses "x / y".
-- Spell reports REMAINING / TOTAL (starts 4/4 then 3/4...).
-- Spell can sometimes report "0 / 0" on completion/reload; we coerce that to 0 / MAX_SUPPORTED_TOTAL.
--
-- VISIBILITY:
--   - Hides ONLY during specific scenario steps in HIDE_IF_SCENARIO_STEP_NAMES
--   - Still hides outside scenario instances (ONLY_IN_SCENARIO_INSTANCES)
--   - DOES NOT hide when remaining reaches 0 (instead: ticks fade out, text fades in)
--
-- BEHAVIOR:
--   - Bar value animates smoothly between changes (instead of jumping)
--   - Before fading the frame IN, bar snaps to the CURRENT parsed value (no showing stale/cached values)
--   - Supports dynamic layouts for totals 1..4 (0..3 inner dividers)

local ADDON_NAME = ...

DelveInformantDB = DelveInformantDB or {}
DelveInformantDB.NemesisStrongbox = DelveInformantDB.NemesisStrongbox or {}

-- NOTE: this table is replaced when SavedVariables load (after this chunk
-- runs); EnsureDBDefaults() re-binds `db` to the live table on ADDON_LOADED.
local db = DelveInformantDB.NemesisStrongbox
local DIUtils = _G.DelveInformantUtils or {}
local DILayout = _G.DelveInformantLayout

-- =========================
-- LibSharedMedia (optional)
-- =========================
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
local LSM_STATUSBAR = (LSM and LSM.MediaType and LSM.MediaType.STATUSBAR) or "statusbar"
local LSM_TEXTURE_NAME = "Flat"

local FetchStatusbarTexture = DIUtils.FetchStatusbarTexture or function()
  if LSM and LSM.Fetch then
    local tex = LSM:Fetch(LSM_STATUSBAR, LSM_TEXTURE_NAME, true)
    if tex and tex ~= "" then
      return tex
    end
  end
  return "Interface\\TARGETINGFRAME\\UI-StatusBar"
end

-- =========================
-- Config
-- =========================
local DEFAULT_SPELL_ID = 1239535

local TWW_DELVE_SPELL_ID = 1239535
local MIDNIGHT_DELVE_SPELL_ID = 1270179

-- TWW delve theme HEX: 9a693b
local TWW_THEME_R, TWW_THEME_G, TWW_THEME_B = 0.6039, 0.4118, 0.2314

local HIDE_IF_SCENARIO_STEP_NAMES = {
  "Ethereal Routing Station",
  "Treasure Room",
  "Collect Your Reward",
}

local ONLY_IN_SCENARIO_INSTANCES = true
local MIN_SUPPORTED_TOTAL = 1
local MAX_SUPPORTED_TOTAL = 4
local MIN_DELVE_LEVEL_TO_SHOW = 4

local UPDATE_INTERVAL = 0.5
local INSTANCE_LOAD_GRACE_SECONDS = 2.0

local FADE_IN_SECONDS = 1.0
local FADE_OUT_SECONDS = FADE_IN_SECONDS

local BAR_VALUE_ANIM_SECONDS = 0.25

local TICKS_FADE_SECONDS = 0.5
local MSG_FADE_SECONDS   = 0.5

local BAR_WIDTH, BAR_HEIGHT = 250, 25
local BAR_POINT, BAR_X, BAR_Y = "CENTER", 0, 0
local BAR_SCALE = 1
local LAYOUT_KEY = "strongbox"
local LAYOUT_ORDER = 10
local LAYOUT_TOP_TEXT_HEIGHT = 14
local LAYOUT_ROW_GAP = 0
local LAYOUT_ROW_HEIGHT = BAR_HEIGHT + LAYOUT_TOP_TEXT_HEIGHT

local TICK_WIDTH = 28
local TICK_HEIGHT_EXTRA = 8

local INSET_L, INSET_R, INSET_T, INSET_B = 4, 4, 4, 4

local BG_R, BG_G, BG_B, BG_A = 0, 0, 0, 0.35

-- Requested RGB 151,134,247
local BORDER_R, BORDER_G, BORDER_B, BORDER_A =
  0.592156862745098, 0.5254901960784314, 0.9686274509803922, 0.76

local DEBUG_STEP_LOG = false
local DEBUG_HIDE_REASONS = false

-- =========================
-- Pixel perfect helpers
-- =========================
local Snap = DIUtils.Snap or function(frame, value)
  local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale())
    or (UIParent and UIParent:GetEffectiveScale())
    or 1
  local rounded = value and (value * scale) or 0
  if rounded >= 0 then
    rounded = math.floor(rounded + 0.5)
  else
    rounded = math.ceil(rounded - 0.5)
  end
  return rounded / scale
end

local SnapPoint = DIUtils.SnapPoint or function(frame, x, y)
  return Snap(frame, x or 0), Snap(frame, y or 0)
end

-- =========================
-- Helpers
-- =========================
local function SafeToNumber(x)
  local n = tonumber(x)
  return n or 0
end

local function NS_Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cFF69CCF0DelveInformant|r: " .. tostring(msg))
end

local function GetDebugChatFrame()
  if not NUM_CHAT_WINDOWS or not GetChatWindowInfo then
    return nil
  end

  for i = 1, NUM_CHAT_WINDOWS do
    local windowName = GetChatWindowInfo(i)
    if windowName == "Debug" then
      return _G["ChatFrame" .. i]
    end
  end

  return nil
end

local function NS_DebugPrint(msg)
  local chatFrame = GetDebugChatFrame() or DEFAULT_CHAT_FRAME
  chatFrame:AddMessage("|cFF69CCF0DelveInformant (Debug)|r: " .. tostring(msg))
end

local Clamp = DIUtils.Clamp or function(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function GetCurrentSeasonMaxLevel()
  if _G.GetCurrentSeasonMaxLevel then
    return _G.GetCurrentSeasonMaxLevel("Title")
  end
  return 0
end

local function NormalizeScenarioText(s)
  if s == nil then return nil end
  s = tostring(s)
  s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
  s = s:gsub("|r", "")
  s = s:gsub("%s+", " ")
  s = s:gsub("^%s+", "")
  s = s:gsub("%s+$", "")
  s = s:gsub("[!.]+$", "")
  return s
end

local function GetScenarioStepName()
  if not C_Scenario or not C_Scenario.GetStepInfo then return nil end
  return C_Scenario.GetStepInfo()
end

local function InScenarioInstance()
  local _, instanceType = IsInInstance()
  return instanceType == "scenario"
end

local function IsPlayerInCombat()
  return UnitAffectingCombat and UnitAffectingCombat("player")
end

local function GetActiveSpellID()
  local delveGroup = _G.GetCurrentDelveGroup and _G.GetCurrentDelveGroup()
  if delveGroup == "tww" then
    return TWW_DELVE_SPELL_ID
  end
  if delveGroup == "midnight" then
    return MIDNIGHT_DELVE_SPELL_ID
  end
  return DEFAULT_SPELL_ID
end

local function GetSpellDesc()
  if not C_Spell or not C_Spell.GetSpellDescription then return nil end
  local desc = C_Spell.GetSpellDescription(GetActiveSpellID())
  if not desc or desc == "" then return nil end
  return desc
end

local function GetCurrentDelveLevel()
    if not C_PartyInfo.IsDelveInProgress or not C_PartyInfo.IsDelveInProgress() then
        return nil
    end
    
    local info = C_UIWidgetManager.GetScenarioHeaderDelvesWidgetVisualizationInfo(6183)
    if info and info.tierText then
        return tonumber(info.tierText)
    end
    
    return nil
end

local function ParseRemainingTotalFromSpellDesc()
  local desc = GetSpellDesc()
  if not desc then return nil end

  local a, b = desc:match("(%d+)%s*/%s*(%d+)")
  if not a or not b then return nil end

  local remaining = SafeToNumber(a)
  local total = SafeToNumber(b)
  local rawWasZeroZero = (remaining == 0 and total == 0)

  -- Some end-states/reloads report "0 / 0". Treat as completed with expected total.
  if rawWasZeroZero and MAX_SUPPORTED_TOTAL and MAX_SUPPORTED_TOTAL > 0 then
    total = MAX_SUPPORTED_TOTAL
  end

  return remaining, total, rawWasZeroZero
end

local function ComputeFound(remaining, total)
  if total <= 0 then return 0 end
  remaining = Clamp(remaining or 0, 0, total)
  local found = total - remaining
  found = Clamp(found, 0, total)
  return found
end

local function ShouldHideForScenarioStep()
  if type(HIDE_IF_SCENARIO_STEP_NAMES) ~= "table" or #HIDE_IF_SCENARIO_STEP_NAMES == 0 then
    return false, nil
  end

  local stepName = NormalizeScenarioText(GetScenarioStepName())
  if not stepName or stepName == "" then
    return false, nil
  end

  for i = 1, #HIDE_IF_SCENARIO_STEP_NAMES do
    local hideName = NormalizeScenarioText(HIDE_IF_SCENARIO_STEP_NAMES[i])
    if hideName and hideName ~= "" and stepName == hideName then
      return true, hideName
    end
  end

  return false, nil
end

-- =========================
-- Scenario Step Logger
-- =========================
local lastLoggedStepName = nil

local function LogScenarioStepNameIfChanged(force)
  if not DEBUG_STEP_LOG then return end

  local stepName = GetScenarioStepName()
  if stepName == "" then stepName = nil end

  if force or stepName ~= lastLoggedStepName then
    lastLoggedStepName = stepName
    if stepName then
      NS_DebugPrint('Scenario step: "' .. tostring(stepName) .. '"')
    else
      NS_DebugPrint("Scenario step: (none)")
    end
  end
end

-- =========================
-- Hide reason logger
-- =========================
local lastHideReason = nil

local function LogHideReason(reason)
  if not DEBUG_HIDE_REASONS then return end
  if reason ~= lastHideReason then
    lastHideReason = reason
    NS_DebugPrint("Hidden: " .. reason)
  end
end

local function ClearHideReason()
  lastHideReason = nil
end

-- =========================
-- Grace period handling
-- =========================
local graceUntil = 0

local function StartGraceWindow()
  graceUntil = GetTime() + (INSTANCE_LOAD_GRACE_SECONDS or 0)
end

local function InGraceWindow()
  return GetTime() < (graceUntil or 0)
end

-- =========================
-- ROOT FRAME (movable)
-- =========================
local f = CreateFrame("Frame", "DelveInformantFrame", UIParent)
f:SetScale(BAR_SCALE)
f:SetSize(Snap(f, BAR_WIDTH), Snap(f, BAR_HEIGHT))
f:SetAlpha(0)
f:Hide()
f:SetMovable(true)
f:SetClampedToScreen(true)

-- =========================
-- Fade system for main frame (in + out)
-- =========================
local fadeActive, fadeElapsed, fadeDuration = false, 0, 0
local fadeFrom, fadeTo = 0, 0
local fadeHideOnDone = false
local lastShownState = false
local moveModeActive = false
local ResetToHiddenEmptyState
local ApplyVisualsFromFound
local UpdateDisplay

-- Last successfully parsed reading. Declared up here because ApplyLockState's
-- drag handlers (defined well above the update logic) need lastGoodTotal.
local lastGoodFound = 0
local lastGoodTotal = 0

local function SetLayoutActive(active)
  if DILayout and DILayout.SetActive then
    DILayout.SetActive(LAYOUT_KEY, active)
  end
end

-- Resetting to the empty 4-ally layout has to wait until the frame is actually
-- gone. Doing it when the hide was *requested* meant every fade-out played on a
-- wiped bar rather than on the state the player was looking at.
local function FinishHide()
  f:Hide()
  SetLayoutActive(false)
  if ResetToHiddenEmptyState then
    ResetToHiddenEmptyState()
  end
end

local function StartFadeTo(targetAlpha, duration, hideOnDone)
  targetAlpha = Clamp(targetAlpha or 0, 0, 1)
  duration = tonumber(duration) or 0
  hideOnDone = not not hideOnDone

  if fadeActive and fadeTo == targetAlpha and fadeHideOnDone == hideOnDone then
    return
  end

  local currentAlpha = Clamp(f:GetAlpha() or 0, 0, 1)
  if not fadeActive and math.abs(currentAlpha - targetAlpha) < 0.0001 and not hideOnDone then
    return
  end

  if not f:IsShown() then
    f:Show()
  end

  fadeActive = true
  fadeElapsed = 0
  fadeDuration = math.max(0, duration)
  fadeFrom = currentAlpha
  fadeTo = targetAlpha
  fadeHideOnDone = hideOnDone

  if fadeDuration == 0 then
    f:SetAlpha(fadeTo)
    fadeActive = false
    if fadeHideOnDone and fadeTo <= 0 then
      FinishHide()
    end
  end
end

local function StopFade()
  fadeActive = false
  fadeElapsed = 0
  fadeDuration = 0
  fadeFrom = f:GetAlpha() or 0
  fadeTo = fadeFrom
  fadeHideOnDone = false
end

local function HideFrameWithFade()
  lastShownState = false

  if not f:IsShown() and (f:GetAlpha() or 0) <= 0 then
    f:SetAlpha(0)
    StopFade()
    FinishHide()
    return
  end

  if fadeActive and fadeTo == 0 and fadeHideOnDone then
    return
  end

  StartFadeTo(0, FADE_OUT_SECONDS, true)
end

-- =========================
-- Statusbar
-- =========================
local bar = CreateFrame("StatusBar", nil, f)
local BAR_EXPAND_PX = 1

local function ApplyBarPoints()
  local l = Snap(f, INSET_L)
  local r = Snap(f, INSET_R)
  local t = Snap(f, INSET_T)
  local b = Snap(f, INSET_B)

  bar:ClearAllPoints()
  bar:SetPoint("TOPLEFT", f, "TOPLEFT", l - BAR_EXPAND_PX, -t + BAR_EXPAND_PX)
  bar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -r + BAR_EXPAND_PX, b - BAR_EXPAND_PX)
end

ApplyBarPoints()

bar:SetMinMaxValues(0, 1)
bar:SetValue(0)
bar:SetFrameLevel(f:GetFrameLevel() + 1)
bar:EnableMouse(false)

local barBG = bar:CreateTexture(nil, "BACKGROUND")
barBG:SetAllPoints(true)
barBG:SetColorTexture(BG_R, BG_G, BG_B, BG_A)

local function ApplyStatusBarTexture()
  local texPath = FetchStatusbarTexture()
  bar:SetStatusBarTexture(texPath)
  local tex = bar:GetStatusBarTexture()
  if tex then
    tex:SetDrawLayer("ARTWORK", 1)
  end
end

ApplyStatusBarTexture()

local function OnLSMChanged(_, mediaType, key)
  if mediaType == LSM_STATUSBAR then
    if not key or key == LSM_TEXTURE_NAME then
      ApplyStatusBarTexture()
    end
  end
end

if LSM and LSM.RegisterCallback then
  LSM:RegisterCallback("LibSharedMedia_Registered", OnLSMChanged)
  LSM:RegisterCallback("LibSharedMedia_SetGlobal", OnLSMChanged)
end

-- =========================
-- Smooth bar value animation
-- =========================
local barAnimActive, barAnimElapsed, barAnimDur = false, 0, 0
local barFrom, barTarget = 0, 0

local function SetBarInstant(v)
  v = Clamp(v or 0, 0, 1)
  barFrom = v
  barTarget = v
  barAnimActive = false
  barAnimElapsed = 0
  barAnimDur = 0
  bar:SetValue(v)
end

local function SetBarTarget(v, dur)
  v = Clamp(v or 0, 0, 1)
  dur = tonumber(dur) or BAR_VALUE_ANIM_SECONDS

  if math.abs((barTarget or 0) - v) < 0.0001 then
    return
  end

  barFrom = Clamp(bar:GetValue() or 0, 0, 1)
  barTarget = v
  barAnimElapsed = 0
  barAnimDur = math.max(0, dur)
  barAnimActive = (barAnimDur > 0)
  if not barAnimActive then
    bar:SetValue(barTarget)
    barFrom = barTarget
  end
end

-- =========================
-- Tick layer (ABOVE bar, BELOW border)
-- =========================
local tickLayer = CreateFrame("Frame", nil, f)
tickLayer:SetAllPoints(true)
tickLayer:SetFrameLevel(f:GetFrameLevel() + 2)
tickLayer:EnableMouse(false)
tickLayer:SetAlpha(1)

local border = _G.CreateSegmentedBorder and _G.CreateSegmentedBorder(f, {
  borderSize = 8,
  alpha = BORDER_A,
  frameLevelOffset = 3,
})

-- =========================
-- Text overlay layer (ensures message draws above statusbar)
-- =========================
local textLayer = CreateFrame("Frame", nil, f)
textLayer:SetAllPoints(true)
textLayer:SetFrameLevel(f:GetFrameLevel() + 10)
textLayer:EnableMouse(false)

-- =========================
-- Ticks (atlas markers) — dynamic inner ticks for totals 1..4
-- =========================
local function MakeTick()
  local t = tickLayer:CreateTexture(nil, "OVERLAY")
  t:SetAtlas("genericwidgetbar-marker-plain", true)
  t:SetVertexColor(BORDER_R, BORDER_G, BORDER_B, BORDER_A)
  t:SetSize(
    Snap(f, TICK_WIDTH),
    Snap(f, (BAR_HEIGHT - INSET_T - INSET_B) + TICK_HEIGHT_EXTRA)
  )
  return t
end

local tickQ1 = MakeTick()
local tickQ2 = MakeTick()
local tickQ3 = MakeTick()
local tickTextures = { tickQ1, tickQ2, tickQ3 }
local titleText
local activeThemeGroup = nil

local function SetTickAndBorderTheme(delveGroup)
  if delveGroup == "tww" then
    if border and border.SetColor then
      border.SetColor(TWW_THEME_R, TWW_THEME_G, TWW_THEME_B)
    end
    for i = 1, #tickTextures do
      tickTextures[i]:SetVertexColor(TWW_THEME_R, TWW_THEME_G, TWW_THEME_B, BORDER_A)
    end
    titleText:SetTextColor(TWW_THEME_R, TWW_THEME_G, TWW_THEME_B, 1)
    return
  end

  if border and border.SetColor then
    border.SetColor(BORDER_R, BORDER_G, BORDER_B)
  end
  for i = 1, #tickTextures do
    tickTextures[i]:SetVertexColor(BORDER_R, BORDER_G, BORDER_B, BORDER_A)
  end
  titleText:SetTextColor(BORDER_R, BORDER_G, BORDER_B, 1)
end

local function SetTickAndBorderThemeForCurrentState()
  local delveGroup = _G.GetCurrentDelveGroup and _G.GetCurrentDelveGroup()

  if delveGroup then
    activeThemeGroup = delveGroup
  elseif f:IsShown() or fadeActive then
    delveGroup = activeThemeGroup
  else
    activeThemeGroup = nil
  end

  SetTickAndBorderTheme(delveGroup)
end

local function PositionTick(tick, frac)
  tick:ClearAllPoints()

  local w = bar:GetWidth()
  if not w or w <= 0 then
    w = (BAR_WIDTH - INSET_L - INSET_R)
  end

  local x = Snap(f, w * frac)
  tick:SetPoint("CENTER", bar, "LEFT", x, 0)
end

local function PositionAllTicks(total)
  total = tonumber(total) or MAX_SUPPORTED_TOTAL
  total = Clamp(total, MIN_SUPPORTED_TOTAL, MAX_SUPPORTED_TOTAL)

  local dividerCount = math.max(0, total - 1)

  for i = 1, #tickTextures do
    local tick = tickTextures[i]
    if i <= dividerCount then
      PositionTick(tick, i / total)
      tick:SetShown(true)
    else
      tick:SetShown(false)
    end
  end
end

PositionAllTicks(MAX_SUPPORTED_TOTAL)

-- =========================
-- Text
-- =========================
titleText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
do
  local x, y = SnapPoint(f, 0, 2)
  titleText:SetPoint("BOTTOM", bar, "TOP", x, y)
end
titleText:SetJustifyH("CENTER")
titleText:SetText(GetCurrentSeasonMaxLevel())
titleText:SetTextColor(BORDER_R, BORDER_G, BORDER_B, 1)

local msg = textLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
msg:SetPoint("CENTER", bar, "CENTER", 0, 0)
msg:SetJustifyH("CENTER")
msg:SetJustifyV("MIDDLE")
msg:SetText("")
msg:SetAlpha(0)

local dragSurface = CreateFrame("Frame", nil, f)
dragSurface:SetAllPoints(f)
dragSurface:SetFrameLevel(f:GetFrameLevel() + 20)
dragSurface:EnableMouse(false)
dragSurface:RegisterForDrag("LeftButton")

-- =========================
-- DB: position + lock state
-- =========================
local function EnsureDBDefaults()
  if type(DelveInformantDB) ~= "table" then
    DelveInformantDB = {}
  end

  if type(DelveInformantDB.NemesisStrongbox) ~= "table" then
    DelveInformantDB.NemesisStrongbox = {}
  end

  db = DelveInformantDB.NemesisStrongbox

  if DelveInformantDB.locked == nil then
    if db.locked ~= nil then
      DelveInformantDB.locked = not not db.locked
    else
      DelveInformantDB.locked = true
    end
  end
  db.locked = DelveInformantDB.locked

  if type(DelveInformantDB.Layout) ~= "table" then
    DelveInformantDB.Layout = {}
  end
end

-- Position lives solely in DelveInformantDB.Layout, owned by DelveInformantLayout.
-- Legacy per-module copies (db.pos.* and db.point/x/y) are migrated once by
-- EnsureLayoutDBDefaults in FriendshipUtils.lua and are no longer written.
local function RestorePosition()
  if DILayout and DILayout.RestoreBase then
    DILayout.RestoreBase(BAR_POINT, BAR_POINT, BAR_X, BAR_Y)
    return
  end

  f:ClearAllPoints()
  f:SetPoint(BAR_POINT, UIParent, BAR_POINT, Snap(f, BAR_X), Snap(f, BAR_Y))
end

local function ApplyLockState(locked)
  if locked == nil then
    if DILayout and DILayout.IsLocked then
      locked = DILayout.IsLocked()
    else
      locked = db.locked
    end
  end

  locked = not not locked
  db.locked = locked

  if locked then
    f:EnableMouse(false)
    f:RegisterForDrag()
    f:SetScript("OnDragStart", nil)
    f:SetScript("OnDragStop", nil)
    dragSurface:EnableMouse(false)
    dragSurface:RegisterForDrag()
    dragSurface:SetScript("OnDragStart", nil)
    dragSurface:SetScript("OnDragStop", nil)
  else
    local function OnDragStart()
      if DILayout and DILayout.StartGroupDrag then
        DILayout.StartGroupDrag(LAYOUT_KEY)
      elseif f.StartMoving then
        f:StartMoving()
      end
    end

    local function OnDragStop()
      if DILayout and DILayout.StopGroupDrag then
        DILayout.StopGroupDrag()
      else
        if f.StopMovingOrSizing then
          f:StopMovingOrSizing()
        end
        if DILayout and DILayout.SetBaseFromEntryFrame then
          DILayout.SetBaseFromEntryFrame(LAYOUT_KEY, f)
        end
      end
      PositionAllTicks(lastGoodTotal)
    end

    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", OnDragStart)
    f:SetScript("OnDragStop", OnDragStop)
    dragSurface:EnableMouse(true)
    dragSurface:RegisterForDrag("LeftButton")
    dragSurface:SetScript("OnDragStart", OnDragStart)
    dragSurface:SetScript("OnDragStop", OnDragStop)
  end
end

local function ApplyMoveMode(active)
  moveModeActive = not not active

  if moveModeActive then
    StopFade()
    lastShownState = true
    SetLayoutActive(true)
    titleText:SetText(GetCurrentSeasonMaxLevel())
    ApplyVisualsFromFound(2, MAX_SUPPORTED_TOTAL, true)
    f:SetAlpha(1)
    f:Show()
  else
    msg:SetText("")
    UpdateDisplay()
  end
end

-- =========================
-- Coloring (based on absolute FOUND count)
-- 1-2 = green, 3 = blue, 4+ = purple
-- =========================
local function SetBarColorForFound(found, total)
  found = tonumber(found) or 0

  if found >= 4 then
    bar:SetStatusBarColor(0.6392, 0.2078, 0.9333, 1) -- purple
  elseif found >= 3 then
    bar:SetStatusBarColor(0.0, 0.4392, 0.8666, 1)    -- blue
  else
    bar:SetStatusBarColor(0.1176, 1.0, 0.0, 1)       -- green (0-2)
  end
end

-- =========================
-- Ticks/Text alpha fades (independent)
-- =========================
local ticksFadeActive, ticksFadeElapsed, ticksFadeDur, ticksFromA, ticksToA = false, 0, 0, 1, 1
local msgFadeActive, msgFadeElapsed, msgFadeDur, msgFromA, msgToA = false, 0, 0, 0, 0

local function StartTicksFadeTo(a, dur)
  a = Clamp(a or 0, 0, 1)
  dur = tonumber(dur) or 0
  if ticksFadeActive and ticksToA == a then return end
  ticksFadeActive = true
  ticksFadeElapsed = 0
  ticksFadeDur = math.max(0, dur)
  ticksFromA = Clamp(tickLayer:GetAlpha() or 0, 0, 1)
  ticksToA = a
  if ticksFadeDur == 0 then
    tickLayer:SetAlpha(ticksToA)
    ticksFadeActive = false
  end
end

local function StartMsgFadeTo(a, dur)
  a = Clamp(a or 0, 0, 1)
  dur = tonumber(dur) or 0
  if msgFadeActive and msgToA == a then return end
  msgFadeActive = true
  msgFadeElapsed = 0
  msgFadeDur = math.max(0, dur)
  msgFromA = Clamp(msg:GetAlpha() or 0, 0, 1)
  msgToA = a
  if msgFadeDur == 0 then
    msg:SetAlpha(msgToA)
    msgFadeActive = false
  end
end

local function SetFoundAllVisualState(isFoundAll)
  if isFoundAll then
    msg:SetText("You've fully upgraded the Strongbox!")
    StartTicksFadeTo(0, TICKS_FADE_SECONDS)
    StartMsgFadeTo(1, MSG_FADE_SECONDS)
  else
    StartTicksFadeTo(1, TICKS_FADE_SECONDS)
    StartMsgFadeTo(0, MSG_FADE_SECONDS)
    msg:SetText("")
  end
end

-- =========================
-- Visual state cache
-- =========================
ApplyVisualsFromFound = function(found, total, snapBarNow)
  found = tonumber(found) or 0
  total = tonumber(total) or 0

  local frac = 0
  if total > 0 then
    frac = found / total
  end
  frac = Clamp(frac, 0, 1)

  bar:SetMinMaxValues(0, 1)
  SetBarColorForFound(found, total)

  if snapBarNow then
    SetBarInstant(frac)
  else
    SetBarTarget(frac, BAR_VALUE_ANIM_SECONDS)
  end

  PositionAllTicks(total)

  SetFoundAllVisualState(total > 0 and found >= total)
end

ResetToHiddenEmptyState = function()
  lastGoodFound = 0
  lastGoodTotal = 0
  ApplyVisualsFromFound(0, MAX_SUPPORTED_TOTAL, true)
end

-- =========================
-- Show/hide rules
-- =========================
local function ShouldShowNow(total)
  if IsPlayerInCombat() then
    return false, "Player is in combat"
  end

  if ONLY_IN_SCENARIO_INSTANCES and not InScenarioInstance() then
    return false, "Not in scenario instance (instanceType != scenario)"
  end

  local hideNow, matched = ShouldHideForScenarioStep()
  if hideNow then
    return false, 'Scenario step matches hidden step "' .. tostring(matched) .. '"'
  end

  local delveLevel = GetCurrentDelveLevel()
  if not delveLevel then
    return false, "Delve level unavailable"
  end

  if delveLevel < MIN_DELVE_LEVEL_TO_SHOW then
    return false, "Delve level is " .. tostring(delveLevel) .. " (minimum " .. tostring(MIN_DELVE_LEVEL_TO_SHOW) .. ")"
  end

  if total < MIN_SUPPORTED_TOTAL or total > MAX_SUPPORTED_TOTAL then
    return false, "Total is " .. tostring(total) .. " (supported totals: " .. tostring(MIN_SUPPORTED_TOTAL) .. "-" .. tostring(MAX_SUPPORTED_TOTAL) .. ")"
  end

  return true, nil
end

-- =========================
-- Show frame with fade (IMPORTANT: snap to FRESH values before fade-in)
-- =========================
local function ShowFrameWithFadeIfNeeded(dataFresh, foundFresh, totalFresh)
  if not dataFresh then
    HideFrameWithFade()
    return
  end

  -- If transitioning hidden -> shown, snap to CURRENT parsed value first (not cached)
  if not lastShownState then
    ApplyVisualsFromFound(foundFresh or lastGoodFound, totalFresh or lastGoodTotal, true)

    lastShownState = true
    SetLayoutActive(true)
    f:SetAlpha(0)
    f:Show()
    StartFadeTo(1, FADE_IN_SECONDS, false)
    return
  end

  SetLayoutActive(true)
  f:Show()
  if (fadeActive and fadeTo == 1 and not fadeHideOnDone) or ((f:GetAlpha() or 0) >= 0.999 and not fadeActive) then
    return
  end
  StartFadeTo(1, FADE_IN_SECONDS, false)
end

-- =========================
-- Update logic
-- =========================
UpdateDisplay = function()
  if moveModeActive then
    return
  end

  LogScenarioStepNameIfChanged(false)
  SetTickAndBorderThemeForCurrentState()

  -- Parse directly from the active delve spell tooltip text.
  -- We keep the most recent valid reading cached so the UI can remain stable
  -- through brief API/transient loading gaps.
  local dataFresh = false
  local remaining, total, rawWasZeroZero = ParseRemainingTotalFromSpellDesc()

  local found = nil
  local parsedTotal = nil

  if remaining ~= nil and total ~= nil and total > 0 then
    -- While loading into a delve, ignore transient "0 / 0" reads so we don't flash a full bar.
    if rawWasZeroZero and InGraceWindow() then
      dataFresh = false
    else
      dataFresh = true
      found = ComputeFound(remaining, total)
      parsedTotal = total

      lastGoodFound = found
      lastGoodTotal = total
      -- Normal updates while showing: animate bar smoothly
      ApplyVisualsFromFound(found, total, false)
    end
  end

  -- If we can't parse yet, keep hidden during grace window
  if not dataFresh and InGraceWindow() then
    if lastShownState and lastGoodTotal > 0 then
      ClearHideReason()
      return
    end
    HideFrameWithFade()
    ClearHideReason()
    return
  end

  local ok, reason = ShouldShowNow((parsedTotal or total) or 0)
  if not ok then
    HideFrameWithFade()
    LogHideReason(reason or "Hidden by rule")
    return
  end

  ClearHideReason()

  -- Show (but ONLY after we have fresh data and have snapped visuals on first show)
  ShowFrameWithFadeIfNeeded(dataFresh, found, parsedTotal)
end

-- =========================
-- OnUpdate: periodic updates + animations
-- =========================
local elapsedUpdate = 0
f:SetScript("OnUpdate", function(self, dt)
  -- main frame fade
  if fadeActive then
    fadeElapsed = fadeElapsed + dt
    if fadeDuration <= 0 then
      f:SetAlpha(fadeTo)
      fadeActive = false
      if fadeHideOnDone and fadeTo <= 0 then
        FinishHide()
      end
    else
      local t = fadeElapsed / fadeDuration
      if t >= 1 then t = 1 end
      f:SetAlpha(Clamp(fadeFrom + (fadeTo - fadeFrom) * t, 0, 1))

      if t >= 1 then
        fadeActive = false
        if fadeHideOnDone and fadeTo <= 0 then
          FinishHide()
        end
      end
    end
  end

  -- smooth bar value anim
  if barAnimActive then
    barAnimElapsed = barAnimElapsed + dt
    local dur = barAnimDur
    if dur <= 0 then
      bar:SetValue(barTarget)
      barAnimActive = false
      barFrom = barTarget
    else
      local t = barAnimElapsed / dur
      if t >= 1 then t = 1 end
      bar:SetValue(Clamp(barFrom + (barTarget - barFrom) * t, 0, 1))
      if t >= 1 then
        barAnimActive = false
        barFrom = barTarget
      end
    end
  end

  -- ticks alpha fade
  if ticksFadeActive then
    ticksFadeElapsed = ticksFadeElapsed + dt
    local dur = ticksFadeDur
    if dur <= 0 then
      tickLayer:SetAlpha(ticksToA)
      ticksFadeActive = false
    else
      local t = ticksFadeElapsed / dur
      if t >= 1 then t = 1 end
      tickLayer:SetAlpha(Clamp(ticksFromA + (ticksToA - ticksFromA) * t, 0, 1))
      if t >= 1 then
        ticksFadeActive = false
      end
    end
  end

  -- msg alpha fade
  if msgFadeActive then
    msgFadeElapsed = msgFadeElapsed + dt
    local dur = msgFadeDur
    if dur <= 0 then
      msg:SetAlpha(msgToA)
      msgFadeActive = false
    else
      local t = msgFadeElapsed / dur
      if t >= 1 then t = 1 end
      msg:SetAlpha(Clamp(msgFromA + (msgToA - msgFromA) * t, 0, 1))
      if t >= 1 then
        msgFadeActive = false
      end
    end
  end
end)

local evt = CreateFrame("Frame")
evt:RegisterEvent("ADDON_LOADED")
evt:RegisterEvent("PLAYER_ENTERING_WORLD")
evt:RegisterEvent("ZONE_CHANGED_NEW_AREA")
evt:RegisterEvent("SCENARIO_UPDATE")
evt:RegisterEvent("SPELL_TEXT_UPDATE")
evt:RegisterEvent("PLAYER_REGEN_DISABLED")
evt:RegisterEvent("PLAYER_REGEN_ENABLED")
evt:SetScript("OnEvent", function(_, event, loadedAddon)
  -- SavedVariables land after this file executes, so everything seeded at load
  -- time came from defaults. Re-bind `db` and re-apply saved state here.
  if event == "ADDON_LOADED" then
    if loadedAddon ~= ADDON_NAME then
      return
    end

    evt:UnregisterEvent("ADDON_LOADED")
    EnsureDBDefaults()
    RestorePosition()

    if DILayout and DILayout.ApplyLockStates then
      DILayout.ApplyLockStates()
    else
      ApplyLockState()
    end

    UpdateDisplay()
    return
  end

  if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
    StartGraceWindow()
    C_Timer.After(0.1, function()
      ApplyBarPoints()
      PositionAllTicks(lastGoodTotal)
    end)
  end
  UpdateDisplay()
end)

-- The bar frame hides itself, and hidden frames do not run OnUpdate, so the
-- periodic poll has to live on this always-shown event frame. Keeping it on
-- the bar meant polling stopped exactly when we needed it to notice the bar
-- should come back.
evt:SetScript("OnUpdate", function(_, dt)
  elapsedUpdate = elapsedUpdate + dt
  if elapsedUpdate >= UPDATE_INTERVAL then
    elapsedUpdate = 0
    UpdateDisplay()
  end
end)

-- =========================
-- Init
-- =========================
EnsureDBDefaults()
RestorePosition()
if DILayout and DILayout.Register then
  DILayout.Register(LAYOUT_KEY, f, LAYOUT_ORDER, { rowHeight = LAYOUT_ROW_HEIGHT, rowGap = LAYOUT_ROW_GAP })
end
if DILayout and DILayout.RegisterLockable then
  DILayout.RegisterLockable(LAYOUT_KEY, ApplyLockState)
else
  ApplyLockState()
end
if DILayout and DILayout.RegisterMoveMode then
  DILayout.RegisterMoveMode(LAYOUT_KEY, ApplyMoveMode)
else
  ApplyMoveMode(false)
end

StartGraceWindow()
UpdateDisplay()
