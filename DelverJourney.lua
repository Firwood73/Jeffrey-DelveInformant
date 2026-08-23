-- DelverJourney.lua
-- Season progress bar for the Delver's Journey, tracked as major-faction renown
-- on the season's delve faction. Valeera is a sub-faction of that same faction,
-- so this bar is the parent track and does not duplicate the companion bar.

local ADDON_NAME = ...

DelveInformantDB = DelveInformantDB or {}
DelveInformantDB.DelverJourney = DelveInformantDB.DelverJourney or {}

-- NOTE: this table is replaced when SavedVariables load (after this chunk
-- runs); EnsureDBDefaults() re-binds `db` to the live table on ADDON_LOADED.
local db = DelveInformantDB.DelverJourney

local DIUtils = _G.DelveInformantUtils or {}
local DILayout = _G.DelveInformantLayout

local UPDATE_INTERVAL = 0.25
local FADE_IN_SECONDS = 1.0
local FADE_OUT_SECONDS = FADE_IN_SECONDS

local BAR_WIDTH, BAR_HEIGHT = 250, 25
local BAR_POINT, BAR_X, BAR_Y = "CENTER", 0, -71
local LAYOUT_KEY = "journey"
local LAYOUT_ORDER = 30
local LAYOUT_TOP_TEXT_HEIGHT = 14
local LAYOUT_ROW_GAP = 0
local LAYOUT_ROW_HEIGHT = BAR_HEIGHT + LAYOUT_TOP_TEXT_HEIGHT

local BG_R, BG_G, BG_B, BG_A = 0, 0, 0, 0.35
local BORDER_A = 0.9

-- Renown gold, kept distinct from the strongbox theme and Valeera's class colour
-- so the three stacked bars stay tellable apart at a glance.
local THEME_R, THEME_G, THEME_B = 1.0, 0.82, 0.0

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

local function ApplyStatusbarTexture(statusbar)
  if statusbar and statusbar.SetStatusBarTexture then
    statusbar:SetStatusBarTexture(FetchStatusbarTexture())
  end
end

local Clamp = DIUtils.Clamp or function(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local Snap = DIUtils.Snap or function(frame, value)
  local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale())
    or (UIParent and UIParent:GetEffectiveScale())
    or 1
  local rounded = (value or 0) * scale
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

local function FormatNumber(n)
  local s = tostring(math.floor(tonumber(n) or 0))
  while true do
    local nextS, count = s:gsub("^(%-?%d+)(%d%d%d)", "%1,%2")
    s = nextS
    if count == 0 then
      break
    end
  end
  return s
end

local function IsPlayerInCombat()
  return UnitAffectingCombat and UnitAffectingCombat("player")
end

-- =========================
-- Season data
-- =========================
local function GetSeasonNumber()
  if _G.GetCurrentDelvesSeason then
    return tonumber(_G.GetCurrentDelvesSeason()) or 0
  end
  if C_DelvesUI and C_DelvesUI.GetCurrentDelvesSeasonNumber then
    return tonumber(C_DelvesUI.GetCurrentDelvesSeasonNumber()) or 0
  end
  return 0
end

-- Cached because the faction cannot change mid-session, and the lookup runs on
-- every poll.
local seasonFactionID

local function GetSeasonFactionID()
  if seasonFactionID then
    return seasonFactionID
  end

  if C_DelvesUI and C_DelvesUI.GetDelvesFactionForSeason then
    local factionID = tonumber(C_DelvesUI.GetDelvesFactionForSeason())
    if factionID and factionID > 0 then
      seasonFactionID = factionID
      return seasonFactionID
    end
  end

  return nil
end

local function HasMaxedJourney(factionID)
  if C_MajorFactions and C_MajorFactions.HasMaximumRenown then
    local ok, maxed = pcall(C_MajorFactions.HasMaximumRenown, factionID)
    if ok then
      return not not maxed
    end
  end
  return false
end

local function GetJourneyInfo()
  local factionID = GetSeasonFactionID()
  if not factionID then
    return nil
  end

  if not C_MajorFactions or not C_MajorFactions.GetMajorFactionRenownInfo then
    return nil
  end

  local renownInfo = C_MajorFactions.GetMajorFactionRenownInfo(factionID)
  if not renownInfo then
    return nil
  end

  local earned = tonumber(renownInfo.renownReputationEarned) or 0
  local needed = tonumber(renownInfo.renownLevelThreshold) or 0

  if needed < 0 then needed = 0 end
  if earned < 0 then earned = 0 end
  if needed > 0 and earned > needed then earned = needed end

  return {
    level = tonumber(renownInfo.renownLevel) or 0,
    currentXP = earned,
    totalXP = needed,
    factionID = factionID,
    maxed = HasMaxedJourney(factionID),
  }
end

local function EnsureDBDefaults()
  if type(DelveInformantDB) ~= "table" then
    DelveInformantDB = {}
  end
  if type(DelveInformantDB.DelverJourney) ~= "table" then
    DelveInformantDB.DelverJourney = {}
  end
  db = DelveInformantDB.DelverJourney

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

-- =========================
-- Frame + fade
-- =========================
local f = CreateFrame("Frame", "DelveInformantDelverJourneyFrame", UIParent)
f:SetSize(BAR_WIDTH, BAR_HEIGHT)
f:SetFrameStrata("MEDIUM")
f:SetAlpha(0)
f:Hide()
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")

local fadeActive, fadeElapsed, fadeDuration = false, 0, 0
local fadeFrom, fadeTo = 0, 0
local fadeHideOnDone = false
local moveModeActive = false

local function SetLayoutActive(active)
  if DILayout and DILayout.SetActive then
    DILayout.SetActive(LAYOUT_KEY, active)
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
      f:Hide()
      SetLayoutActive(false)
    end
  end
end

local function ShowFrameWithFadeIfNeeded()
  SetLayoutActive(true)
  if (fadeActive and fadeTo == 1 and not fadeHideOnDone) or ((f:GetAlpha() or 0) >= 0.999 and f:IsShown() and not fadeActive) then
    return
  end
  StartFadeTo(1, FADE_IN_SECONDS, false)
end

local function HideFrameWithFade()
  if not f:IsShown() and (f:GetAlpha() or 0) <= 0 then
    f:SetAlpha(0)
    f:Hide()
    fadeActive = false
    SetLayoutActive(false)
    return
  end

  if fadeActive and fadeTo == 0 and fadeHideOnDone then
    return
  end

  StartFadeTo(0, FADE_OUT_SECONDS, true)
end

-- =========================
-- Visuals
-- =========================
local BORDER_SIZE = 8
local INSET_SIZE = 4
local border = _G.CreateSegmentedBorder and _G.CreateSegmentedBorder(f, {
  borderSize = BORDER_SIZE,
  alpha = BORDER_A,
  frameLevelOffset = 3,
})

if border and border.SetColor then
  border.SetColor(THEME_R, THEME_G, THEME_B)
end

local bg = f:CreateTexture(nil, "BACKGROUND")
bg:SetPoint("TOPLEFT", f, "TOPLEFT", INSET_SIZE, -INSET_SIZE)
bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -INSET_SIZE, INSET_SIZE - 1)
bg:SetColorTexture(BG_R, BG_G, BG_B, BG_A)

local bar = CreateFrame("StatusBar", nil, f)
bar:SetFrameLevel(f:GetFrameLevel() + 1)
bar:EnableMouse(false)
bar:SetPoint("TOPLEFT", INSET_SIZE, -INSET_SIZE)
bar:SetPoint("BOTTOMRIGHT", -INSET_SIZE, INSET_SIZE - 1)
bar:SetMinMaxValues(0, 1)
bar:SetValue(0)
ApplyStatusbarTexture(bar)

-- Brightness tracks fill, matching how the other two bars read at a glance.
local function SetBarColorForProgress(pct)
  local m = 0.35 + (0.65 * Clamp(pct or 0, 0, 1))
  bar:SetStatusBarColor(THEME_R * m, THEME_G * m, THEME_B * m, 1)
end

SetBarColorForProgress(0)

local textLayer = CreateFrame("Frame", nil, f)
textLayer:SetAllPoints(true)
textLayer:SetFrameLevel(f:GetFrameLevel() + 10)
textLayer:EnableMouse(false)

if LSM and LSM.RegisterCallback then
  LSM.RegisterCallback(bar, "LibSharedMedia_Registered", function()
    ApplyStatusbarTexture(bar)
  end)
end

local nameText = textLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
nameText:SetPoint("BOTTOMLEFT", bar, "TOPLEFT", 2, 2)
nameText:SetJustifyH("LEFT")
nameText:SetTextColor(THEME_R, THEME_G, THEME_B, 1)

local levelText = textLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
levelText:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", -2, 2)
levelText:SetJustifyH("RIGHT")
levelText:SetTextColor(THEME_R, THEME_G, THEME_B, 1)

local valueText = textLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
valueText:SetPoint("CENTER", bar, "CENTER", 0, 0)
valueText:SetJustifyH("CENTER")

local helperText = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
helperText:SetPoint("TOP", f, "BOTTOM", 0, -2)
helperText:SetText("/dilock /diunlock /dimove")
helperText:SetShown(false)

local dragSurface = CreateFrame("Frame", nil, f)
dragSurface:SetAllPoints(f)
dragSurface:SetFrameLevel(f:GetFrameLevel() + 20)
dragSurface:EnableMouse(false)
dragSurface:RegisterForDrag("LeftButton")

local isHovered = false
local lastEarned = 0
local lastNeeded = 0
local lastIsCapped = false

local function UpdateValueText()
  if lastIsCapped then
    valueText:SetText("100%")
    return
  end

  if isHovered then
    valueText:SetText(string.format("%s/%s", FormatNumber(lastEarned), FormatNumber(lastNeeded)))
  else
    local pct = 0
    if lastNeeded > 0 then
      pct = (lastEarned / lastNeeded) * 100
    end
    valueText:SetText(string.format("%.0f%%", pct))
  end
end

-- Position lives solely in DelveInformantDB.Layout, owned by DelveInformantLayout.
local function RestorePosition()
  EnsureDBDefaults()

  if DILayout and DILayout.RestoreBase then
    -- The group base is the strongbox row; this bar's vertical offset is
    -- derived by the layout, so it must not seed the base with its own
    -- stacked offset. BAR_Y only applies to the standalone fallback below.
    DILayout.RestoreBase(BAR_POINT, BAR_POINT, BAR_X, 0)
    return
  end

  f:ClearAllPoints()
  local snappedX, snappedY = SnapPoint(f, BAR_X, BAR_Y)
  f:SetPoint(BAR_POINT, UIParent, BAR_POINT, snappedX, snappedY)
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
  helperText:SetShown(not locked)

  if locked then
    -- Keep mouse input active while locked so hover can show exact progress.
    f:EnableMouse(true)
    f:RegisterForDrag()
    f:SetScript("OnDragStart", nil)
    f:SetScript("OnDragStop", nil)
    dragSurface:EnableMouse(true)
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

local function SeasonLabel()
  local season = GetSeasonNumber()
  if season > 0 then
    return string.format("Delves: Season %d", season)
  end
  return "Delves"
end

local UpdateDisplay

local function ApplyMoveMode(active)
  moveModeActive = not not active

  if moveModeActive then
    fadeActive = false
    SetLayoutActive(true)
    nameText:SetText(SeasonLabel())
    levelText:SetText("Rank --")
    valueText:SetText("Drag to move")
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0.5)
    SetBarColorForProgress(0.5)
    helperText:SetShown(true)
    f:SetAlpha(1)
    f:Show()
  else
    helperText:SetShown(not db.locked)
    UpdateDisplay()
  end
end

-- =========================
-- Update logic
-- =========================
UpdateDisplay = function()
  if moveModeActive then
    return
  end

  if IsPlayerInCombat() then
    HideFrameWithFade()
    return
  end

  -- Any delve feeds the current season's Journey, so this shows in TWW and
  -- Midnight delves alike. A nil group means we are not in a delve at all.
  local delveGroup = _G.GetCurrentDelveGroup and _G.GetCurrentDelveGroup()
  if not delveGroup then
    HideFrameWithFade()
    return
  end

  local journeyInfo = GetJourneyInfo()
  if not journeyInfo then
    HideFrameWithFade()
    return
  end

  local earned = journeyInfo.currentXP
  local needed = journeyInfo.totalXP
  -- At max renown there is no further progress to earn, so the bar reads full
  -- rather than disappearing.
  local isCapped = needed <= 0 or journeyInfo.maxed

  local pct = 1
  if isCapped then
    bar:SetValue(1)
  else
    pct = earned / needed
    pct = Clamp(pct, 0, 1)
    bar:SetValue(pct)
  end

  SetBarColorForProgress(pct)

  lastEarned = earned
  lastNeeded = needed
  lastIsCapped = isCapped

  nameText:SetText(SeasonLabel())
  levelText:SetText(string.format("Rank %d", journeyInfo.level))
  UpdateValueText()

  ShowFrameWithFadeIfNeeded()
end

local function OnEnter()
  isHovered = true
  UpdateValueText()
end

local function OnLeave()
  isHovered = false
  UpdateValueText()
end

f:SetScript("OnEnter", OnEnter)
f:SetScript("OnLeave", OnLeave)
dragSurface:SetScript("OnEnter", OnEnter)
dragSurface:SetScript("OnLeave", OnLeave)

-- =========================
-- Events
-- =========================
local evt = CreateFrame("Frame")

evt:RegisterEvent("ADDON_LOADED")
evt:RegisterEvent("PLAYER_ENTERING_WORLD")
evt:RegisterEvent("QUEST_TURNED_IN")
evt:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
evt:RegisterEvent("UPDATE_FACTION")
evt:RegisterEvent("MAJOR_FACTION_RENOWN_LEVEL_CHANGED")
evt:RegisterEvent("ZONE_CHANGED_NEW_AREA")
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
  end

  UpdateDisplay()
end)

f:SetScript("OnUpdate", function(_, dt)
  if fadeActive then
    fadeElapsed = fadeElapsed + dt
    if fadeDuration <= 0 then
      f:SetAlpha(fadeTo)
      fadeActive = false
      if fadeHideOnDone and fadeTo <= 0 then
        f:Hide()
        SetLayoutActive(false)
      end
    else
      local t = fadeElapsed / fadeDuration
      if t > 1 then t = 1 end
      f:SetAlpha(Clamp(fadeFrom + (fadeTo - fadeFrom) * t, 0, 1))
      if t >= 1 then
        fadeActive = false
        if fadeHideOnDone and fadeTo <= 0 then
          f:Hide()
          SetLayoutActive(false)
        end
      end
    end
  end
end)

-- The bar frame hides itself, and hidden frames do not run OnUpdate, so the
-- periodic poll has to live on the always-shown event frame instead.
local elapsed = 0
evt:SetScript("OnUpdate", function(_, dt)
  elapsed = elapsed + dt
  if elapsed >= UPDATE_INTERVAL then
    elapsed = 0
    UpdateDisplay()
  end
end)

EnsureDBDefaults()
RestorePosition()
if DILayout and DILayout.Register then
  DILayout.Register(LAYOUT_KEY, f, LAYOUT_ORDER, { rowHeight = LAYOUT_ROW_HEIGHT, rowGap = LAYOUT_ROW_GAP })
end
if DILayout and DILayout.RegisterLockable then
  DILayout.RegisterLockable(LAYOUT_KEY, ApplyLockState)
else
  ApplyLockState(db.locked)
end
if DILayout and DILayout.RegisterMoveMode then
  DILayout.RegisterMoveMode(LAYOUT_KEY, ApplyMoveMode)
else
  ApplyMoveMode(false)
end
UpdateDisplay()
