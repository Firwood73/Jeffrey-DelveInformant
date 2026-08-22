-- FriendshipUtils.lua
-- Utility slash command for printing friendship reputation progress from gossip context.

local ADDON_NAME = ...

local function ExtractLevelFromReaction(reaction)
  if type(reaction) ~= "string" then
    return nil
  end

  local level = reaction:match("(%d+)")
  return tonumber(level)
end

local function PrintFriendshipBar(friendshipFactionID)
  local r = C_GossipInfo.GetFriendshipReputation(friendshipFactionID)
  if not r then
    print("Friendship rep nil (must be in an active Gossip NPC context, or not a friendship faction):", friendshipFactionID)
    return
  end

  local start = r.reactionThreshold or 0
  local finish = r.nextThreshold or r.maxRep or start
  local cur = (r.standing or 0) - start
  local max = finish - start
  if max < 0 then max = 0 end
  if cur < 0 then cur = 0 end
  if max > 0 and cur > max then cur = max end

  local reaction = r.reaction or "Friendship"
  local level = ExtractLevelFromReaction(reaction)

  if level then
    print(string.format("Level %d (%d / %d)", level, cur, max))
  else
    print(reaction, string.format("(%d / %d)", cur, max))
  end
end

-- Membership sets used only for fast instance lookups.
local TWW_DELVE_INSTANCE_IDS = {
  [2664] = true,
  [2679] = true,
  [2680] = true,
  [2681] = true,
  [2682] = true,
  [2683] = true,
  [2684] = true,
  [2685] = true,
  [2686] = true,
  [2687] = true,
  [2688] = true,
  [2689] = true,
  [2690] = true,
}

local MIDNIGHT_DELVE_INSTANCE_IDS = {
  [2933] = true,
  [2952] = true,
  [2953] = true,
  [2961] = true,
  [2962] = true,
  [2963] = true,
  [2964] = true,
  [2965] = true,
  [2966] = true,
  [2979] = true,
  [3003] = true,
  [3038] = true,
}

local function GetCurrentDelveGroup()
  local _, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
  if instanceType ~= "scenario" then
    return nil
  end

  if TWW_DELVE_INSTANCE_IDS[instanceID] then
    return "tww"
  end

  if MIDNIGHT_DELVE_INSTANCE_IDS[instanceID] then
    return "midnight"
  end

  return nil
end

-- Each season resumes where the previous one capped, so Min is the level the
-- season starts from and Lvl is the level it ends at.
local SEASON_MAXLEVEL = {
  [1] = { Min = 0, Lvl = 60, Title = "Nemesis' Allies" },
  [2] = { Min = 60, Lvl = 80, Title = "Nemesis' Allies" },
  [3] = { Min = 80, Lvl = 100, Title = "Nemesis' Allies" },
}

local LAST_KNOWN_SEASON = #SEASON_MAXLEVEL

-- There is no Season 4, so an out-of-range or missing season number means the
-- API failed rather than that new content shipped. Clamp into the known range
-- and prefer the newest season when we have nothing at all: defaulting to
-- Season 1 would report a cap below the player's real level, which hides the
-- companion bar outright instead of just mis-colouring it.
local function GetCurrentSeasonNumber()
  local currentSeason
  if C_DelvesUI and C_DelvesUI.GetCurrentDelvesSeasonNumber then
    currentSeason = tonumber(C_DelvesUI.GetCurrentDelvesSeasonNumber())
  end

  if not currentSeason then
    return LAST_KNOWN_SEASON
  end
  if currentSeason < 1 then
    return 1
  end
  if currentSeason > LAST_KNOWN_SEASON then
    return LAST_KNOWN_SEASON
  end
  return currentSeason
end

local function GetCurrentSeasonMaxLevel(parse)
  local seasonData = SEASON_MAXLEVEL[GetCurrentSeasonNumber()]
  if parse == "Lvl" then
    return seasonData.Lvl
  elseif parse == "Min" then
    return seasonData.Min
  else
    return seasonData.Title
  end
end

_G.PrintFriendshipBar = PrintFriendshipBar
_G.GetCurrentDelveGroup = GetCurrentDelveGroup
_G.GetCurrentSeasonMaxLevel = GetCurrentSeasonMaxLevel
_G.GetCurrentDelvesSeason = GetCurrentSeasonNumber

-- Shared utility helpers for DelveInformant modules.
-- Keeping these in one place avoids duplicated helper logic in each feature file.
local DelveInformantUtils = _G.DelveInformantUtils or {}

function DelveInformantUtils.Clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

function DelveInformantUtils.Round(value)
  if value >= 0 then
    return math.floor(value + 0.5)
  end
  return math.ceil(value - 0.5)
end

function DelveInformantUtils.Snap(frame, value)
  local scale = (frame and frame.GetEffectiveScale and frame:GetEffectiveScale())
    or (UIParent and UIParent:GetEffectiveScale())
    or 1
  return DelveInformantUtils.Round((value or 0) * scale) / scale
end

function DelveInformantUtils.SnapPoint(frame, x, y)
  return DelveInformantUtils.Snap(frame, x or 0), DelveInformantUtils.Snap(frame, y or 0)
end

function DelveInformantUtils.FetchStatusbarTexture(mediaName)
  local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
  local statusbarMediaType = (lsm and lsm.MediaType and lsm.MediaType.STATUSBAR) or "statusbar"
  local textureName = mediaName or "Flat"

  if lsm and lsm.Fetch then
    local texture = lsm:Fetch(statusbarMediaType, textureName, true)
    if texture and texture ~= "" then
      return texture
    end
  end

  return "Interface\\TARGETINGFRAME\\UI-StatusBar"
end

_G.DelveInformantUtils = DelveInformantUtils

-- The segmented border art lives in the optional ChatChange addon. When it is
-- not installed the texture files resolve to nothing and the bars render with
-- no frame at all, so fall back to a Blizzard backdrop edge instead.
local SEGMENTED_BORDER_ADDON = "ChatChange"
local SEGMENTED_BORDER_TEXTURE_PATH = "Interface\\AddOns\\ChatChange\\Textures\\"

local function IsAddOnAvailable(name)
  local getAddOnInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or _G.GetAddOnInfo
  if not getAddOnInfo then
    return false
  end

  local ok, addonName = pcall(getAddOnInfo, name)
  return ok and addonName ~= nil
end

local function CreateBackdropBorder(parentFrame, borderSize, borderAlpha, frameLevelOffset)
  local borderFrame = CreateFrame("Frame", nil, parentFrame, "BackdropTemplate")
  borderFrame:SetAllPoints(parentFrame)
  borderFrame:SetFrameLevel(parentFrame:GetFrameLevel() + frameLevelOffset)
  borderFrame:EnableMouse(false)

  if borderFrame.SetBackdrop then
    borderFrame:SetBackdrop({
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      edgeSize = borderSize + 4,
    })
  end

  local function SetColor(r, g, b, a)
    local alpha = a
    if alpha == nil then
      alpha = borderAlpha
    end

    if borderFrame.SetBackdropBorderColor then
      borderFrame:SetBackdropBorderColor(r or 1, g or 1, b or 1, alpha)
    end
  end

  return {
    frame = borderFrame,
    pieces = {},
    SetColor = SetColor,
  }
end

local function CreateSegmentedBorder(parentFrame, options)
  if not parentFrame then
    return nil
  end

  options = options or {}

  local borderSize = tonumber(options.borderSize) or 8
  local borderAlpha = tonumber(options.alpha) or 1
  local texturePath = options.texturePath
  local frameLevelOffset = tonumber(options.frameLevelOffset) or 3
  local drawLayer = options.drawLayer or "BORDER"

  if not texturePath then
    if IsAddOnAvailable(SEGMENTED_BORDER_ADDON) then
      texturePath = SEGMENTED_BORDER_TEXTURE_PATH
    else
      return CreateBackdropBorder(parentFrame, borderSize, borderAlpha, frameLevelOffset)
    end
  end

  local borderFrame = CreateFrame("Frame", nil, parentFrame)
  borderFrame:SetAllPoints(parentFrame)
  borderFrame:SetFrameLevel(parentFrame:GetFrameLevel() + frameLevelOffset)
  borderFrame:EnableMouse(false)

  local borderPieces = {
    TL = borderFrame:CreateTexture(nil, drawLayer),
    T = borderFrame:CreateTexture(nil, drawLayer),
    TR = borderFrame:CreateTexture(nil, drawLayer),
    R = borderFrame:CreateTexture(nil, drawLayer),
    BR = borderFrame:CreateTexture(nil, drawLayer),
    B = borderFrame:CreateTexture(nil, drawLayer),
    BL = borderFrame:CreateTexture(nil, drawLayer),
    L = borderFrame:CreateTexture(nil, drawLayer),
  }

  borderPieces.TL:SetTexture(texturePath .. "TL.PNG")
  borderPieces.TL:SetSize(borderSize, borderSize)
  borderPieces.TL:SetPoint("TOPLEFT", borderFrame, "TOPLEFT", 0, 0)

  borderPieces.TR:SetTexture(texturePath .. "TR.PNG")
  borderPieces.TR:SetSize(borderSize, borderSize)
  borderPieces.TR:SetPoint("TOPRIGHT", borderFrame, "TOPRIGHT", 0, 0)

  borderPieces.BR:SetTexture(texturePath .. "BR.PNG")
  borderPieces.BR:SetSize(borderSize, borderSize)
  borderPieces.BR:SetPoint("BOTTOMRIGHT", borderFrame, "BOTTOMRIGHT", 0, 0)

  borderPieces.BL:SetTexture(texturePath .. "BL.PNG")
  borderPieces.BL:SetSize(borderSize, borderSize)
  borderPieces.BL:SetPoint("BOTTOMLEFT", borderFrame, "BOTTOMLEFT", 0, 0)

  borderPieces.T:SetTexture(texturePath .. "T.PNG")
  borderPieces.T:SetPoint("TOPLEFT", borderPieces.TL, "TOPRIGHT", 0, 0)
  borderPieces.T:SetPoint("TOPRIGHT", borderPieces.TR, "TOPLEFT", 0, 0)
  borderPieces.T:SetHeight(borderSize)

  borderPieces.R:SetTexture(texturePath .. "R.PNG")
  borderPieces.R:SetPoint("TOPRIGHT", borderPieces.TR, "BOTTOMRIGHT", 0, 0)
  borderPieces.R:SetPoint("BOTTOMRIGHT", borderPieces.BR, "TOPRIGHT", 0, 0)
  borderPieces.R:SetWidth(borderSize)

  borderPieces.B:SetTexture(texturePath .. "B.PNG")
  borderPieces.B:SetPoint("BOTTOMLEFT", borderPieces.BL, "BOTTOMRIGHT", 0, 0)
  borderPieces.B:SetPoint("BOTTOMRIGHT", borderPieces.BR, "BOTTOMLEFT", 0, 0)
  borderPieces.B:SetHeight(borderSize)

  borderPieces.L:SetTexture(texturePath .. "L.PNG")
  borderPieces.L:SetPoint("TOPLEFT", borderPieces.TL, "BOTTOMLEFT", 0, 0)
  borderPieces.L:SetPoint("BOTTOMLEFT", borderPieces.BL, "TOPLEFT", 0, 0)
  borderPieces.L:SetWidth(borderSize)

  local function SetColor(r, g, b, a)
    local alpha = a
    if alpha == nil then
      alpha = borderAlpha
    end

    for _, piece in pairs(borderPieces) do
      piece:SetVertexColor(r or 1, g or 1, b or 1, alpha)
    end
  end

  return {
    frame = borderFrame,
    pieces = borderPieces,
    SetColor = SetColor,
  }
end

_G.CreateSegmentedBorder = CreateSegmentedBorder

-- Shared vertical stack layout for DelveInformant bars.
-- The strongbox is the anchor row; ally bars occupy the next rows below it.
local DelveInformantLayout = _G.DelveInformantLayout or {}

DelveInformantDB = DelveInformantDB or {}
DelveInformantDB.Layout = DelveInformantDB.Layout or {}

DelveInformantLayout.rowGap = DelveInformantLayout.rowGap or 6
DelveInformantLayout.shiftSeconds = DelveInformantLayout.shiftSeconds or 0.25
DelveInformantLayout.entries = DelveInformantLayout.entries or {}
DelveInformantLayout.lockCallbacks = DelveInformantLayout.lockCallbacks or {}
DelveInformantLayout.moveModeCallbacks = DelveInformantLayout.moveModeCallbacks or {}
DelveInformantLayout.base = DelveInformantLayout.base or {
  point = "CENTER",
  relativePoint = "CENTER",
  x = 0,
  y = 0,
}
DelveInformantLayout.containerPadding = DelveInformantLayout.containerPadding or 8

local GetContainerLayoutMetrics
local UpdateGroupDrag

local function LayoutClamp01(value)
  if value < 0 then return 0 end
  if value > 1 then return 1 end
  return value
end

local function LayoutSnap(frame, value)
  if DelveInformantUtils and DelveInformantUtils.Snap then
    return DelveInformantUtils.Snap(frame, value)
  end
  return value or 0
end


local function DI_Print(msg)
  local chatFrame = DEFAULT_CHAT_FRAME
  if chatFrame and chatFrame.AddMessage then
    chatFrame:AddMessage("|cFF69CCF0DelveInformant|r: " .. tostring(msg))
  end
end

local function EnsureLayoutDBDefaults()
  DelveInformantDB = DelveInformantDB or {}
  DelveInformantDB.Layout = DelveInformantDB.Layout or {}

  if DelveInformantDB.Layout.x == nil then
    local containerPos = type(DelveInformantDB.Layout.container) == "table" and DelveInformantDB.Layout.container
    local strongboxDB = DelveInformantDB.NemesisStrongbox
    local valeeraDB = DelveInformantDB.ValeeraSanguinar
    local strongboxPos = type(strongboxDB) == "table" and strongboxDB.pos
    if type(containerPos) == "table" and containerPos.x ~= nil then
      DelveInformantDB.Layout.point = containerPos.point
      DelveInformantDB.Layout.relativePoint = containerPos.relativePoint
      DelveInformantDB.Layout.x = containerPos.x
      DelveInformantDB.Layout.y = (tonumber(containerPos.y) or 0) - (tonumber(containerPos.centerOffsetY) or 0)
    elseif type(strongboxPos) == "table" and strongboxPos.x ~= nil then
      DelveInformantDB.Layout.point = strongboxPos.point
      DelveInformantDB.Layout.relativePoint = strongboxPos.relativePoint
      DelveInformantDB.Layout.x = strongboxPos.x
      DelveInformantDB.Layout.y = strongboxPos.y
    elseif type(strongboxDB) == "table" and strongboxDB.x ~= nil then
      DelveInformantDB.Layout.point = strongboxDB.point
      DelveInformantDB.Layout.relativePoint = strongboxDB.relativePoint
      DelveInformantDB.Layout.x = strongboxDB.x
      DelveInformantDB.Layout.y = strongboxDB.y
    elseif type(valeeraDB) == "table" and valeeraDB.x ~= nil then
      DelveInformantDB.Layout.point = valeeraDB.point
      DelveInformantDB.Layout.relativePoint = valeeraDB.relativePoint
      DelveInformantDB.Layout.x = valeeraDB.x
      DelveInformantDB.Layout.y = valeeraDB.y
    end
  end

  if DelveInformantDB.moveMode == nil then
    DelveInformantDB.moveMode = false
  end

  if DelveInformantDB.locked == nil then
    local strongboxDB = DelveInformantDB.NemesisStrongbox
    local valeeraDB = DelveInformantDB.ValeeraSanguinar
    if type(strongboxDB) == "table" and strongboxDB.locked ~= nil then
      DelveInformantDB.locked = not not strongboxDB.locked
    elseif type(valeeraDB) == "table" and valeeraDB.locked ~= nil then
      DelveInformantDB.locked = not not valeeraDB.locked
    else
      DelveInformantDB.locked = true
    end
  end

  if DelveInformantDB.locked then
    DelveInformantDB.moveMode = false
  end
end

local function SaveLayoutBase()
  EnsureLayoutDBDefaults()
  local db = DelveInformantDB.Layout
  local base = DelveInformantLayout.base
  db.point = base.point or "CENTER"
  db.relativePoint = base.relativePoint or db.point
  db.x = LayoutSnap(UIParent, base.x or 0)
  db.y = LayoutSnap(UIParent, base.y or 0)

  if DelveInformantLayout.container and GetContainerLayoutMetrics then
    local _, _, centerOffsetY = GetContainerLayoutMetrics(DelveInformantLayout.container)
    db.container = db.container or {}
    db.container.point = db.point
    db.container.relativePoint = db.relativePoint
    db.container.x = db.x
    db.container.y = LayoutSnap(DelveInformantLayout.container, db.y + (centerOffsetY or 0))
    db.container.centerOffsetY = LayoutSnap(DelveInformantLayout.container, centerOffsetY or 0)
  end
end

local function SaveCurrentLayoutPosition()
  if DelveInformantLayout.drag and UpdateGroupDrag then
    UpdateGroupDrag()
  end

  local container = DelveInformantLayout.container
  if container and container.GetPoint and GetContainerLayoutMetrics and (not container.IsShown or container:IsShown()) then
    local point, _, relativePoint, x, y = container:GetPoint(1)
    if point then
      local _, _, centerOffsetY = GetContainerLayoutMetrics(container)
      local base = DelveInformantLayout.base
      base.point = point
      base.relativePoint = relativePoint or point
      base.x = LayoutSnap(container, x or 0)
      base.y = LayoutSnap(container, (y or 0) - (centerOffsetY or 0))
    end
  end

  DelveInformantLayout.drag = nil
  SaveLayoutBase()
end

local function RestoreLayoutBaseFromDB(defaultPoint, defaultRelativePoint, defaultX, defaultY)
  EnsureLayoutDBDefaults()
  local db = DelveInformantDB.Layout
  local hasSavedPosition = type(db) == "table" and db.x ~= nil and db.y ~= nil
  local base = DelveInformantLayout.base

  base.point = (hasSavedPosition and db.point) or defaultPoint or base.point or "CENTER"
  base.relativePoint = (hasSavedPosition and db.relativePoint) or defaultRelativePoint or base.relativePoint or base.point
  base.x = tonumber(hasSavedPosition and db.x or defaultX)
  if base.x == nil then base.x = 0 end
  base.y = tonumber(hasSavedPosition and db.y or defaultY)
  if base.y == nil then base.y = 0 end

  return hasSavedPosition
end

function DelveInformantLayout.RestoreBase(defaultPoint, defaultRelativePoint, defaultX, defaultY)
  local restoredSavedPosition = RestoreLayoutBaseFromDB(defaultPoint, defaultRelativePoint, defaultX, defaultY)
  if not restoredSavedPosition then
    SaveLayoutBase()
  end
end

function DelveInformantLayout.RestoreSavedPosition(applyNow)
  if DelveInformantLayout.drag or DelveInformantLayout.IsMoveMode() then
    return false
  end

  if not RestoreLayoutBaseFromDB() then
    return false
  end

  if applyNow ~= false and DelveInformantLayout.Apply then
    DelveInformantLayout.Apply(true)
  end

  return true
end

function DelveInformantLayout.IsLocked()
  EnsureLayoutDBDefaults()
  return not not DelveInformantDB.locked
end

function DelveInformantLayout.RegisterLockable(key, applyFn)
  if key and type(applyFn) == "function" then
    DelveInformantLayout.lockCallbacks[key] = applyFn
    applyFn(DelveInformantLayout.IsLocked())
  end
end

function DelveInformantLayout.ApplyLockStates()
  local locked = DelveInformantLayout.IsLocked()
  for _, applyFn in pairs(DelveInformantLayout.lockCallbacks) do
    applyFn(locked)
  end
end

function DelveInformantLayout.IsMoveMode()
  EnsureLayoutDBDefaults()
  return not not DelveInformantDB.moveMode
end

function DelveInformantLayout.RegisterMoveMode(key, applyFn)
  if key and type(applyFn) == "function" then
    DelveInformantLayout.moveModeCallbacks[key] = applyFn
    applyFn(DelveInformantLayout.IsMoveMode())
  end
end

function DelveInformantLayout.ApplyMoveModeStates()
  local active = DelveInformantLayout.IsMoveMode()
  for _, applyFn in pairs(DelveInformantLayout.moveModeCallbacks) do
    applyFn(active)
  end
end

function DelveInformantLayout.SetMoveMode(active, silent)
  EnsureLayoutDBDefaults()
  DelveInformantDB.moveMode = not not active
  DelveInformantLayout.ApplyMoveModeStates()
  if DelveInformantLayout.UpdateContainer then
    DelveInformantLayout.UpdateContainer()
  end
  if not silent then
    DI_Print(DelveInformantDB.moveMode and "Move mode enabled. Drag the DelveInformant mover box to move the group, then use /dilock or /dimove to save." or "Move mode disabled.")
  end
end

function DelveInformantLayout.SetLocked(isLocked, silent)
  EnsureLayoutDBDefaults()
  local locking = not not isLocked
  if locking then
    SaveCurrentLayoutPosition()
  else
    RestoreLayoutBaseFromDB()
  end

  DelveInformantDB.locked = locking
  if type(DelveInformantDB.NemesisStrongbox) == "table" then
    DelveInformantDB.NemesisStrongbox.locked = DelveInformantDB.locked
  end
  if type(DelveInformantDB.ValeeraSanguinar) == "table" then
    DelveInformantDB.ValeeraSanguinar.locked = DelveInformantDB.locked
  end
  DelveInformantLayout.ApplyLockStates()
  if DelveInformantLayout.UpdateContainer then
    DelveInformantLayout.UpdateContainer()
  end
  if DelveInformantDB.locked then
    DelveInformantLayout.SetMoveMode(false, true)
  end
  if not silent then
    DI_Print(DelveInformantDB.locked and "Locked." or "Unlocked. Drag the DelveInformant mover box to move the group.")
  end
end

function DelveInformantLayout.ToggleLocked()
  DelveInformantLayout.SetLocked(not DelveInformantLayout.IsLocked())
end

function DelveInformantLayout.ToggleMoveMode()
  if DelveInformantLayout.IsMoveMode() then
    DelveInformantLayout.SetLocked(true)
  else
    DelveInformantLayout.SetLocked(false, true)
    DelveInformantLayout.SetMoveMode(true)
  end
end

function DelveInformantLayout.Register(key, frame, order, options)
  if not key or not frame then
    return nil
  end

  options = options or {}
  local entry = DelveInformantLayout.entries[key] or {}
  entry.key = key
  entry.frame = frame
  entry.order = tonumber(order) or 100
  entry.rowHeight = tonumber(options.rowHeight) or (frame.GetHeight and frame:GetHeight()) or 25
  entry.rowGap = tonumber(options.rowGap) or DelveInformantLayout.rowGap
  entry.currentOffsetY = entry.currentOffsetY or 0
  entry.targetOffsetY = entry.targetOffsetY or entry.currentOffsetY
  entry.animFromOffsetY = entry.currentOffsetY
  entry.animElapsed = 0
  entry.animDuration = 0
  entry.animating = false
  entry.active = entry.active or false
  DelveInformantLayout.entries[key] = entry
  DelveInformantLayout.UpdateTargets(true)
  if DelveInformantLayout.UpdateContainer then
    DelveInformantLayout.UpdateContainer()
  end
  return entry
end

function DelveInformantLayout.SetBaseFromFrame(frame, save)
  if not frame or not frame.GetPoint then
    return
  end

  local point, _, relativePoint, x, y = frame:GetPoint(1)
  if not point then
    return
  end

  DelveInformantLayout.base.point = point
  DelveInformantLayout.base.relativePoint = relativePoint or point
  DelveInformantLayout.base.x = LayoutSnap(frame, x or 0)
  DelveInformantLayout.base.y = LayoutSnap(frame, y or 0)
  if save ~= false then
    SaveLayoutBase()
  end
  DelveInformantLayout.Apply(true)
end

function DelveInformantLayout.SetBaseFromEntryFrame(key, frame, save)
  if not key or not frame or not frame.GetPoint then
    return
  end

  local point, _, relativePoint, x, y = frame:GetPoint(1)
  if not point then
    return
  end

  local entry = DelveInformantLayout.entries[key]
  local offsetY = (entry and entry.currentOffsetY) or 0
  DelveInformantLayout.base.point = point
  DelveInformantLayout.base.relativePoint = relativePoint or point
  DelveInformantLayout.base.x = LayoutSnap(frame, x or 0)
  DelveInformantLayout.base.y = LayoutSnap(frame, (y or 0) - offsetY)
  if save ~= false then
    SaveLayoutBase()
  end
  DelveInformantLayout.Apply(true)
end

function DelveInformantLayout.SetBase(point, relativePoint, x, y, save)
  DelveInformantLayout.base.point = point or DelveInformantLayout.base.point or "CENTER"
  DelveInformantLayout.base.relativePoint = relativePoint or DelveInformantLayout.base.relativePoint or DelveInformantLayout.base.point
  DelveInformantLayout.base.x = tonumber(x) or 0
  DelveInformantLayout.base.y = tonumber(y) or 0
  if save ~= false then
    SaveLayoutBase()
  end
  DelveInformantLayout.Apply(true)
end

function DelveInformantLayout.SetActive(key, active)
  local entry = DelveInformantLayout.entries[key]
  if not entry then
    return
  end

  active = not not active
  if entry.active == active then
    return
  end

  local snapNow = active and not entry.activatedOnce
  entry.active = active
  if active then
    entry.activatedOnce = true
  end
  DelveInformantLayout.UpdateTargets(snapNow)
end

local function GetActiveEntriesSorted()
  local activeEntries = {}
  for _, entry in pairs(DelveInformantLayout.entries) do
    if entry.active then
      activeEntries[#activeEntries + 1] = entry
    end
  end

  table.sort(activeEntries, function(a, b)
    if a.order == b.order then
      return tostring(a.key) < tostring(b.key)
    end
    return a.order < b.order
  end)

  return activeEntries
end

function DelveInformantLayout.UpdateTargets(snapNow)
  local activeEntries = GetActiveEntriesSorted()
  local offsetY = 0

  for i = 1, #activeEntries do
    local entry = activeEntries[i]
    local target = offsetY
    entry.targetOffsetY = target

    if snapNow then
      entry.currentOffsetY = target
      entry.animating = false
    elseif math.abs((entry.currentOffsetY or 0) - target) > 0.001 then
      entry.animFromOffsetY = entry.currentOffsetY or 0
      entry.animElapsed = 0
      entry.animDuration = DelveInformantLayout.shiftSeconds
      entry.animating = entry.animDuration > 0
      if not entry.animating then
        entry.currentOffsetY = target
      end
    end

    offsetY = offsetY - ((entry.rowHeight or 25) + (entry.rowGap or DelveInformantLayout.rowGap))
  end

  DelveInformantLayout.Apply(false)
  if DelveInformantLayout.UpdateContainer then
    DelveInformantLayout.UpdateContainer()
  end
end

local function GetFrameSize(frame)
  local width = (frame and frame.GetWidth and frame:GetWidth()) or 0
  local height = (frame and frame.GetHeight and frame:GetHeight()) or 0
  return tonumber(width) or 0, tonumber(height) or 0
end

GetContainerLayoutMetrics = function(container)
  local activeEntries = GetActiveEntriesSorted()
  local padding = DelveInformantLayout.containerPadding or 10
  local maxWidth = 0
  local topOffset
  local bottomOffset

  for i = 1, #activeEntries do
    local entry = activeEntries[i]
    local frameWidth, actualFrameHeight = GetFrameSize(entry.frame)
    local frameHeight = tonumber(entry.rowHeight) or actualFrameHeight
    maxWidth = math.max(maxWidth, frameWidth)

    local offset = entry.currentOffsetY or 0
    local top = offset + (frameHeight / 2)
    local bottom = offset - (frameHeight / 2)
    topOffset = topOffset and math.max(topOffset, top) or top
    bottomOffset = bottomOffset and math.min(bottomOffset, bottom) or bottom
  end

  if not topOffset or not bottomOffset then
    maxWidth = 250
    topOffset = 15
    bottomOffset = -15
  end

  local width = LayoutSnap(container or UIParent, maxWidth + (padding * 2))
  local height = LayoutSnap(container or UIParent, (topOffset - bottomOffset) + (padding * 2) + 16)
  local centerOffsetY = ((topOffset + bottomOffset) / 2) - 8

  return math.max(width, 180), math.max(height, 40), centerOffsetY
end

function DelveInformantLayout.EnsureContainer()
  if DelveInformantLayout.container then
    return DelveInformantLayout.container
  end

  local container = CreateFrame("Frame", "DelveInformantMoverFrame", UIParent, "BackdropTemplate")
  container:SetFrameStrata("DIALOG")
  container:SetFrameLevel(1000)
  container:SetSize(280, 70)
  container:SetClampedToScreen(true)
  container:SetMovable(true)
  container:EnableMouse(false)
  container:RegisterForDrag("LeftButton")
  container:Hide()

  if container.SetBackdrop then
    container:SetBackdrop({
      bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    container:SetBackdropColor(0, 0, 0, 0.25)
    container:SetBackdropBorderColor(0.41, 0.8, 0.94, 0.95)
  end

  local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label:SetPoint("TOP", container, "TOP", 0, -4)
  label:SetText("DelveInformant unlocked - drag here")
  container.label = label

  local function StartContainerDrag()
    if DelveInformantLayout.StartGroupDrag then
      DelveInformantLayout.StartGroupDrag("container")
    end
  end

  local function StopContainerDrag()
    if DelveInformantLayout.StopGroupDrag then
      DelveInformantLayout.StopGroupDrag()
    end
  end

  container:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then
      StartContainerDrag()
    end
  end)
  container:SetScript("OnMouseUp", function(_, button)
    if button == "LeftButton" then
      StopContainerDrag()
    end
  end)
  container:SetScript("OnDragStart", StartContainerDrag)
  container:SetScript("OnDragStop", StopContainerDrag)

  DelveInformantLayout.container = container
  return container
end

function DelveInformantLayout.UpdateContainer()
  local container = DelveInformantLayout.EnsureContainer and DelveInformantLayout.EnsureContainer()
  if not container then
    return
  end

  local unlocked = not DelveInformantLayout.IsLocked()
  if not unlocked then
    container:EnableMouse(false)
    container:Hide()
    return
  end

  local width, height, centerOffsetY = GetContainerLayoutMetrics(container)
  local base = DelveInformantLayout.base

  container:SetSize(width, height)
  container:ClearAllPoints()
  container:SetPoint(base.point or "CENTER", UIParent, base.relativePoint or base.point or "CENTER", LayoutSnap(container, base.x or 0), LayoutSnap(container, (base.y or 0) + centerOffsetY))
  container:EnableMouse(true)
  container:Show()
end

function DelveInformantLayout.Apply(snapNow)
  if DelveInformantLayout.suspended then
    return
  end

  if DelveInformantLayout.UpdateTargets and snapNow then
    DelveInformantLayout.UpdateTargets(true)
  end

  local base = DelveInformantLayout.base
  for _, entry in pairs(DelveInformantLayout.entries) do
    local frame = entry.frame
    if frame and frame.ClearAllPoints and frame.SetPoint then
      frame:ClearAllPoints()
      local x = LayoutSnap(frame, base.x or 0)
      local y = LayoutSnap(frame, (base.y or 0) + (entry.currentOffsetY or 0))
      frame:SetPoint(base.point or "CENTER", UIParent, base.relativePoint or base.point or "CENTER", x, y)
    end
  end

  if DelveInformantLayout.UpdateContainer then
    DelveInformantLayout.UpdateContainer()
  end
end

function DelveInformantLayout.StartGroupDrag(key)
  if DelveInformantLayout.IsLocked() or not GetCursorPosition then
    return
  end

  local cursorX, cursorY = GetCursorPosition()
  local scale = (UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
  DelveInformantLayout.drag = {
    key = key,
    cursorX = cursorX or 0,
    cursorY = cursorY or 0,
    scale = scale,
    baseX = DelveInformantLayout.base.x or 0,
    baseY = DelveInformantLayout.base.y or 0,
  }
end

function DelveInformantLayout.StopGroupDrag()
  if not DelveInformantLayout.drag then
    return
  end

  SaveCurrentLayoutPosition()
  DelveInformantLayout.Apply(true)
  DI_Print("Position saved.")
end

UpdateGroupDrag = function()
  local drag = DelveInformantLayout.drag
  if not drag or not GetCursorPosition then
    return
  end

  local cursorX, cursorY = GetCursorPosition()
  local scale = drag.scale or 1
  DelveInformantLayout.base.x = LayoutSnap(UIParent, (drag.baseX or 0) + ((cursorX or 0) - (drag.cursorX or 0)) / scale)
  DelveInformantLayout.base.y = LayoutSnap(UIParent, (drag.baseY or 0) + ((cursorY or 0) - (drag.cursorY or 0)) / scale)
  DelveInformantLayout.Apply(false)
end

function DelveInformantLayout.OnUpdate(dt)
  UpdateGroupDrag()

  local anyAnimating = false

  for _, entry in pairs(DelveInformantLayout.entries) do
    if entry.animating then
      entry.animElapsed = (entry.animElapsed or 0) + (dt or 0)
      local duration = entry.animDuration or 0
      local t = 1
      if duration > 0 then
        t = LayoutClamp01(entry.animElapsed / duration)
      end
      entry.currentOffsetY = (entry.animFromOffsetY or 0) + ((entry.targetOffsetY or 0) - (entry.animFromOffsetY or 0)) * t
      if t >= 1 then
        entry.currentOffsetY = entry.targetOffsetY or entry.currentOffsetY or 0
        entry.animating = false
      else
        anyAnimating = true
      end
    end
  end

  if anyAnimating then
    DelveInformantLayout.Apply(false)
  elseif DelveInformantLayout.UpdateContainer then
    DelveInformantLayout.UpdateContainer()
  end
end

EnsureLayoutDBDefaults()
if not DelveInformantLayout.baseRestored then
  DelveInformantLayout.RestoreBase("CENTER", "CENTER", 0, 0)
  DelveInformantLayout.baseRestored = true
end

if not DelveInformantLayout.driver then
  DelveInformantLayout.driver = CreateFrame("Frame")
  DelveInformantLayout.driver:SetScript("OnUpdate", function(_, dt)
    DelveInformantLayout.OnUpdate(dt)
  end)
end

DelveInformantLayout.driver:RegisterEvent("ADDON_LOADED")
DelveInformantLayout.driver:RegisterEvent("PLAYER_ENTERING_WORLD")
DelveInformantLayout.driver:RegisterEvent("ZONE_CHANGED_NEW_AREA")
DelveInformantLayout.driver:SetScript("OnEvent", function(_, event, loadedAddon)
  -- SavedVariables are installed into the global environment after our file
  -- chunk runs, so anything read at load time saw defaults. Re-read here.
  if event == "ADDON_LOADED" then
    if loadedAddon ~= ADDON_NAME then
      return
    end

    EnsureLayoutDBDefaults()
    DelveInformantLayout.RestoreSavedPosition(true)
    DelveInformantLayout.ApplyLockStates()
    DelveInformantLayout.ApplyMoveModeStates()
    DelveInformantLayout.UpdateContainer()
    return
  end

  local function restoreSavedPosition()
    if DelveInformantLayout.RestoreSavedPosition then
      DelveInformantLayout.RestoreSavedPosition(true)
    end
  end

  if C_Timer and C_Timer.After then
    C_Timer.After(0.1, restoreSavedPosition)
  else
    restoreSavedPosition()
  end
end)

SLASH_DELVEINFORMANTLOCK1 = "/dilock"
SlashCmdList["DELVEINFORMANTLOCK"] = function() DelveInformantLayout.SetLocked(true) end

SLASH_DELVEINFORMANTUNLOCK1 = "/diunlock"
SlashCmdList["DELVEINFORMANTUNLOCK"] = function()
  DelveInformantLayout.SetLocked(false, true)
  DelveInformantLayout.SetMoveMode(true)
end

SLASH_DELVEINFORMANTMOVE1 = "/dimove"
SlashCmdList["DELVEINFORMANTMOVE"] = function() DelveInformantLayout.ToggleMoveMode() end

_G.DelveInformantLayout = DelveInformantLayout
