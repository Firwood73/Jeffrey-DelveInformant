-- ValeeraSanguinar.lua
-- Companion progress bar for Valeera Sanguinar via friendship reputation APIs.

local ADDON_NAME = ...

DelveInformantDB = DelveInformantDB or {}
DelveInformantDB.ValeeraSanguinar = DelveInformantDB.ValeeraSanguinar or {}

-- NOTE: this table is replaced when SavedVariables load (after this chunk
-- runs); EnsureDBDefaults() re-binds `db` to the live table on ADDON_LOADED.
local db = DelveInformantDB.ValeeraSanguinar

-- LibCrayon is not embedded and is not an OptionalDep, so it may be absent.
-- Fetch it silently and fall back to a minimal stand-in rather than erroring
-- out of the whole file.
local Crayon = LibStub and LibStub("LibCrayon-3.0", true)
if not Crayon then
  local function ToHex(r, g, b)
    return string.format("%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
  end

  Crayon = {
    GetThresholdHexColor = function(_, value, maximum)
      local max = tonumber(maximum) or 0
      local pct = 0
      if max > 0 then
        pct = (tonumber(value) or 0) / max
        if pct < 0 then pct = 0 end
        if pct > 1 then pct = 1 end
      end

      if pct >= 1 then return ToHex(0, 1, 0) end
      if pct < 0.5 then return ToHex(1, pct * 2, 0) end
      return ToHex(2 - (pct * 2), 1, 0)
    end,
    Colorize = function(_, hex, text)
      return "|cff" .. tostring(hex) .. tostring(text) .. "|r"
    end,
    Green = function(_, text)
      return "|cff00ff00" .. tostring(text) .. "|r"
    end,
  }
end

local DIUtils = _G.DelveInformantUtils or {}
local DILayout = _G.DelveInformantLayout

local UPDATE_INTERVAL = 0.25
local FADE_IN_SECONDS = 1.0
local FADE_OUT_SECONDS = FADE_IN_SECONDS

local BAR_WIDTH, BAR_HEIGHT = 250, 25
local BAR_POINT, BAR_X, BAR_Y = "CENTER", 0, -43
local LAYOUT_KEY = "valeera"
local LAYOUT_ORDER = 20
local LAYOUT_TOP_TEXT_HEIGHT = 14
local LAYOUT_ROW_GAP = 0
local LAYOUT_ROW_HEIGHT = BAR_HEIGHT + LAYOUT_TOP_TEXT_HEIGHT

local BG_R, BG_G, BG_B, BG_A = 0, 0, 0, 0.35
local BORDER_R, BORDER_G, BORDER_B, BORDER_A = 0.65, 0.05, 0.05, 0.9

local VALEERA_NAME = "Valeera Sanguinar"
local VALEERA_NAME_KEYWORD = "valeera"
local VALEERA_FRIENDSHIP_ID = 2744
local VALEERA_CLASS_FILE = "ROGUE"

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

local function GetCompanionFactionID()
  if C_Delves and C_Delves.GetCompanionFactionID then
    local factionID = tonumber(C_Delves.GetCompanionFactionID())
    if factionID and factionID > 0 then
      return factionID
    end
  end
  return VALEERA_FRIENDSHIP_ID
end

local function GetCurrentSeasonMaxLevel()
  if _G.GetCurrentSeasonMaxLevel then
    return _G.GetCurrentSeasonMaxLevel("Lvl")
  end
  return 0
end

local function GetCurrentSeasonMinLevel()
  if _G.GetCurrentSeasonMaxLevel then
    return _G.GetCurrentSeasonMaxLevel("Min")
  end
  return 0
end

-- Colour the level across the current season's band only: red at the level the
-- season starts from, full green at its cap (S2 spans 60-80, S3 spans 80-100).
-- Feeding a normalised 0-1 ratio through the (value, maximum) form keeps this
-- identical whether LibCrayon or the local stand-in above is in play.
local function GetSeasonLevelHexColor(level, minLevel, maxLevel)
  minLevel = tonumber(minLevel) or 0
  maxLevel = tonumber(maxLevel) or 0

  local span = maxLevel - minLevel
  if span <= 0 then
    return Crayon:GetThresholdHexColor(level, maxLevel)
  end

  local pct = ((tonumber(level) or 0) - minLevel) / span
  if pct < 0 then pct = 0 end
  if pct > 1 then pct = 1 end

  return Crayon:GetThresholdHexColor(pct, 1)
end

local function IsPlayerInCombat()
  return UnitAffectingCombat and UnitAffectingCombat("player")
end

local function IsValeeraFaction(factionName, factionID, targetFactionID)
  if targetFactionID and factionID and tonumber(factionID) == targetFactionID then
    return true
  end

  if type(factionName) ~= "string" then
    return false
  end

  local lowered = string.lower(factionName)
  return string.find(lowered, VALEERA_NAME_KEYWORD, 1, true) ~= nil
end

-- GetNumFactions/GetFactionInfo were removed from retail in favour of
-- C_Reputation. Prefer the modern API and keep the globals as a fallback for
-- clients that still expose them.
local function GetFactionCount()
  if C_Reputation and C_Reputation.GetNumFactions then
    return C_Reputation.GetNumFactions() or 0
  end
  if _G.GetNumFactions then
    return _G.GetNumFactions() or 0
  end
  return 0
end

local function GetFactionEntry(index)
  if C_Reputation and C_Reputation.GetFactionDataByIndex then
    local data = C_Reputation.GetFactionDataByIndex(index)
    if not data then
      return nil
    end
    return data.name, data.reaction, data.currentReactionThreshold,
      data.nextReactionThreshold, data.currentStanding, data.factionID
  end

  if _G.GetFactionInfo then
    local name, _, standingID, barMin, barMax, barValue, _, _, _, _, _, _, _, _, _, _, _, factionID = _G.GetFactionInfo(index)
    return name, standingID, barMin, barMax, barValue, factionID
  end

  return nil
end

local function GetFactionCompanionInfo(targetFactionID)
  local numFactions = GetFactionCount()
  for i = 1, numFactions do
    local name, standingID, barMin, barMax, barValue, factionID = GetFactionEntry(i)
    if name and IsValeeraFaction(name, factionID, targetFactionID) then
      local minValue = tonumber(barMin) or 0
      local maxValue = tonumber(barMax) or 0
      local value = tonumber(barValue) or 0
      local totalXP = maxValue - minValue
      local currentXP = value - minValue

      if totalXP < 0 then totalXP = 0 end
      if currentXP < 0 then currentXP = 0 end
      if totalXP > 0 and currentXP > totalXP then currentXP = totalXP end

      return {
        level = tonumber(standingID) or 0,
        currentXP = currentXP,
        totalXP = totalXP,
        factionID = factionID,
      }
    end
  end

  return nil
end

local function GetFriendshipCompanionInfo(friendshipFactionID)
  if not C_GossipInfo or not C_GossipInfo.GetFriendshipReputation then
    return nil
  end

  local r = C_GossipInfo.GetFriendshipReputation(friendshipFactionID)
  if not r then
    return nil
  end

  local start = tonumber(r.reactionThreshold) or 0
  local finish = tonumber(r.nextThreshold) or tonumber(r.maxRep) or start
  local standing = tonumber(r.standing) or 0
  local cur = standing - start
  local max = finish - start

  if max < 0 then max = 0 end
  if cur < 0 then cur = 0 end
  if max > 0 and cur > max then cur = max end

  local level = tonumber(r.reaction)
  if not level then
    local reactionText = tostring(r.reaction or "")
    level = tonumber(reactionText:match("(%d+)"))
  end

  return {
    level = level or 0,
    currentXP = cur,
    totalXP = max,
    factionID = friendshipFactionID,
  }
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

local function GetValeeraClassColor()
  local classColorTable = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
  local classColor = classColorTable and classColorTable[VALEERA_CLASS_FILE]
  if classColor then
    return classColor.r, classColor.g, classColor.b
  end
  return BORDER_R, BORDER_G, BORDER_B
end

local function EnsureDBDefaults()
  if type(DelveInformantDB) ~= "table" then
    DelveInformantDB = {}
  end
  if type(DelveInformantDB.ValeeraSanguinar) ~= "table" then
    DelveInformantDB.ValeeraSanguinar = {}
  end
  db = DelveInformantDB.ValeeraSanguinar

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

local f = CreateFrame("Frame", "DelveInformantValeeraSanguinarFrame", UIParent)
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

local Clamp = DIUtils.Clamp or function(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

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

local BORDER_SIZE = 8
local INSET_SIZE = 4
local border = _G.CreateSegmentedBorder and _G.CreateSegmentedBorder(f, {
  borderSize = BORDER_SIZE,
  alpha = BORDER_A,
  frameLevelOffset = 3,
})

local function ApplyBorderColor()
  local r, g, b = GetValeeraClassColor()
  if border and border.SetColor then
    border.SetColor(r, g, b)
  end
end

ApplyBorderColor()

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
bar:SetStatusBarColor(0.35, 0, 0, 1)

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
do
  local r, g, b = GetValeeraClassColor()
  nameText:SetTextColor(r, g, b, 1)
end

local levelText = textLayer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
levelText:SetPoint("BOTTOMRIGHT", bar, "TOPRIGHT", -2, 2)
levelText:SetJustifyH("RIGHT")
do
  local r, g, b = GetValeeraClassColor()
  levelText:SetTextColor(r, g, b, 1)
end

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
-- Legacy per-module copies (db.point/x/y) are migrated once by
-- EnsureLayoutDBDefaults in FriendshipUtils.lua and are no longer written.
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

local function GetCompanionInfo()
  local companionFactionID = GetCompanionFactionID()

  -- Preferred source order:
  -- 1) Friendship APIs (most accurate while gossip/friendship data is available)
  -- 2) Delves APIs (direct companion level/xp when exposed)
  -- 3) Faction list scan fallback (legacy-safe path)
  local friendshipInfo = GetFriendshipCompanionInfo(companionFactionID)
    or GetFriendshipCompanionInfo(VALEERA_FRIENDSHIP_ID)
  if friendshipInfo then
    return friendshipInfo
  end

  if C_Delves and C_Delves.GetCompanionLevel and C_Delves.GetCompanionXP then
    local level = tonumber(C_Delves.GetCompanionLevel(companionFactionID))
      or tonumber(C_Delves.GetCompanionLevel())
    local currentXP, totalXP = C_Delves.GetCompanionXP(companionFactionID)
    if currentXP == nil or totalXP == nil then
      currentXP, totalXP = C_Delves.GetCompanionXP()
    end

    currentXP = tonumber(currentXP)
    totalXP = tonumber(totalXP)

    if level and currentXP and totalXP then
      return {
        level = level,
        currentXP = currentXP,
        totalXP = totalXP,
        factionID = companionFactionID,
      }
    end
  end

  return GetFactionCompanionInfo(companionFactionID)
    or GetFactionCompanionInfo(VALEERA_FRIENDSHIP_ID)
end

local function UpdateDisplay()
  if moveModeActive then
    return
  end

  if IsPlayerInCombat() then
    HideFrameWithFade()
    return
  end

  local delveGroup = _G.GetCurrentDelveGroup and _G.GetCurrentDelveGroup()
  if delveGroup ~= "midnight" then
    HideFrameWithFade()
    return
  end

  local companionInfo = GetCompanionInfo()
  if not companionInfo then
    HideFrameWithFade()
    return
  end

  local level = tonumber(companionInfo.level)
  local earned = companionInfo.currentXP
  local needed = companionInfo.totalXP
  local currentMaxLevel = tonumber(GetCurrentSeasonMaxLevel())

  -- At the season cap there is no further XP to earn, so the bar stays up
  -- reading a full green level rather than disappearing.
  local atSeasonCap = not not (currentMaxLevel and currentMaxLevel > 0
    and level and level >= currentMaxLevel)
  local isCapped = needed <= 0 or atSeasonCap
  local pct = 1

  if isCapped then
    bar:SetValue(1)
  else
    pct = earned / needed
    if pct < 0 then pct = 0 end
    if pct > 1 then pct = 1 end
    bar:SetValue(pct)
  end

  local minRed = 0.35
  bar:SetStatusBarColor(minRed + ((1 - minRed) * pct), 0, 0, 1)

  lastEarned = earned
  lastNeeded = needed
  lastIsCapped = isCapped

  local HEX_LEVELVALUE = GetSeasonLevelHexColor(level, GetCurrentSeasonMinLevel(), currentMaxLevel)

  nameText:SetText(VALEERA_NAME)
  levelText:SetText(string.format("Level %s/%s", Crayon:Colorize(HEX_LEVELVALUE, level), Crayon:Green(currentMaxLevel)))
  UpdateValueText()

  ShowFrameWithFadeIfNeeded()
end

local function ApplyMoveMode(active)
  moveModeActive = not not active

  if moveModeActive then
    fadeActive = false
    SetLayoutActive(true)
    nameText:SetText(VALEERA_NAME)
    levelText:SetText(string.format("Level --/%s", Crayon:Green(tonumber(GetCurrentSeasonMaxLevel()) or 0)))
    valueText:SetText("Drag to move")
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0.5)
    bar:SetStatusBarColor(BORDER_R, 0, 0, 1)
    helperText:SetShown(true)
    f:SetAlpha(1)
    f:Show()
  else
    helperText:SetShown(not db.locked)
    UpdateDisplay()
  end
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

local evt = CreateFrame("Frame")

evt:RegisterEvent("ADDON_LOADED")
evt:RegisterEvent("PLAYER_ENTERING_WORLD")
evt:RegisterEvent("QUEST_TURNED_IN")
evt:RegisterEvent("CHAT_MSG_COMBAT_FACTION_CHANGE")
evt:RegisterEvent("UPDATE_FACTION")
evt:RegisterEvent("PLAYER_LEVEL_UP")
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

local elapsed = 0
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
