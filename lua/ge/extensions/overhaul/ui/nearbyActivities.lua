-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/ui/pause/providers/nearbyActivities.lua (BeamNG 0.40).
-- Pause menu nearby activities for Overhaul; the game's provider forwards here while Overhaul runs.
-- Lists the nearest world activities, six at most, each with a view action and a set-route action.

local M = {}

M.dependencies = {"overhaul_shell_patches"}

local buttonModule = require("ge/extensions/ui/gridSelectorUtils/buttonModule")

-- Config ------------------------------------------------------------------------------------------

local PATCH_ID = "nearbyActivities"
local MAX_ITEMS = 6
-- Activities this close always show; the sampler only fills the slots left over.
local NEAR_RADIUS_M = 250
-- Zoom in the bigmap when viewing a nearby activity: 0..1. Current value chosen empirically.
local NEARBY_ACTIVITY_MAP_ZOOM_FACTOR = 0.75

-- World activities only (no garages/gas/dealerships/phone gigs).
local CAREER_ACTIVITY_POI_TYPES = {
  events = true,
  driftSpot = true,
  dragstrip = true,
  crawl = true,
  busWork = true,
  paramedicWork = true,
  policeWork = true,
  miningHaul = true,
  facilityWork = true,
}

-- Roleplay work that a roleplay shift in the career blocks.
local ROLEPLAY_POI_TYPES = {"busWork", "paramedicWork", "policeWork"}

-- Freeroam: vanilla-style activities + RLS freeroam events only.
local FREEROAM_ACTIVITY_POI_TYPES = {
  events = true,
  driftSpot = true,
  dragstrip = true,
  crawl = true,
}

-- Translation keys (ui.*) or plain names for each POI type.
local POI_TYPE_LABELS = {
  mission = "ui.pause.nearbyActivities.poiType.mission",
  spawnPoint = "ui.pause.nearbyActivities.poiType.spawnPoint",
  garage = "ui.pause.nearbyActivities.poiType.garage",
  gasStation = "ui.pause.nearbyActivities.poiType.gasStation",
  dealership = "ui.pause.nearbyActivities.poiType.dealership",
  logisticsParking = "ui.pause.nearbyActivities.poiType.logisticsParking",
  logisticsOffice = "ui.pause.nearbyActivities.poiType.logisticsOffice",
  driftSpot = "ui.pause.nearbyActivities.poiType.driftSpot",
  dragstrip = "ui.pause.nearbyActivities.poiType.dragstrip",
  crawl = "ui.pause.nearbyActivities.poiType.crawl",
  playerVehicle = "ui.pause.nearbyActivities.poiType.playerVehicle",
  events = "Events",
  busWork = "Bus Work",
  paramedicWork = "Paramedic Work",
  policeWork = "Police Work",
  miningHaul = "Mining Company",
  facilityWork = "Facility Work",
}

-- State -------------------------------------------------------------------------------------------

local buttonInstance = buttonModule.create()
local actionButtonsByPoiId = {}

-- Action buttons ----------------------------------------------------------------------------------

-- Buttons are created once per activity and reused on every refresh.
local function cachedButton(poiId, action, makeButton)
  actionButtonsByPoiId[poiId] = actionButtonsByPoiId[poiId] or {}
  local cached = actionButtonsByPoiId[poiId][action]
  if cached then return cached end
  local meta = makeButton()
  actionButtonsByPoiId[poiId][action] = meta
  return meta
end

local function setRouteButton(poiId)
  return cachedButton(poiId, "setRoute", function()
    return buttonInstance.addButton(function()
      if freeroam_bigMapMode and freeroam_bigMapMode.navigateToMission then
        freeroam_bigMapMode.navigateToMission(poiId)
      end
      return true
    end, {
      label = _tr("ui.pause.nearbyActivities.action.setRoute"),
      action = "setRoute",
      poiId = poiId,
    })
  end)
end

local function viewButton(poiId)
  return cachedButton(poiId, "view", function()
    return buttonInstance.addButton(function()
      log("I", "NearbyActivities", "View nearby activity " .. tostring(poiId))
      if not (freeroam_bigMapMode and freeroam_bigMapMode.enterBigMap) then return false end
      -- autoSelectPoiId is picked up by the Vue bigmap once it has mounted, see getAndClearPendingAutoSelectPoiId
      freeroam_bigMapMode.enterBigMap({
        instant = true,
        routeTarget = "pause.bigmap",
        autoSelectPoiId = poiId,
        autoSelectZoomFactor = NEARBY_ACTIVITY_MAP_ZOOM_FACTOR,
      })
      return true
    end, {
      label = _tr("ui.pause.nearbyActivities.action.view"),
      action = "view",
      poiId = poiId,
    })
  end)
end

-- Route setting is off during a market test drive.
local function canSetRoute()
  return not (overhaul_career_market_testDrive and overhaul_career_market_testDrive.isActive())
end

local function actionEntry(button, icon, uiEvent, disabled)
  return {
    buttonId = button.buttonId,
    label = button.label,
    action = button.action,
    icon = icon,
    uiEvent = uiEvent,
    disabled = disabled,
  }
end

local function getActionsForPoi(poiId, isBigMapAllowed)
  return {
    view = actionEntry(viewButton(poiId), "mapWithEmitter", "ok", not isBigMapAllowed),
    route = actionEntry(setRouteButton(poiId), "routeSimple", "action_2", not canSetRoute()),
  }
end

-- Activity types and labels -----------------------------------------------------------------------

local function getActivityPoiTypes()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then
    return FREEROAM_ACTIVITY_POI_TYPES
  end
  local types = {}
  for poiType, listed in pairs(CAREER_ACTIVITY_POI_TYPES) do types[poiType] = listed end
  local employment = overhaul_career_work_employment
  if employment and employment.blocksRoleplay and employment.blocksRoleplay() then
    for _, poiType in ipairs(ROLEPLAY_POI_TYPES) do types[poiType] = nil end
  end
  return types
end

local function prettyPoiType(poiType)
  local label = POI_TYPE_LABELS[poiType]
  if not label then
    return tostring(poiType or _tr("ui.pause.nearbyActivities.poiType.activity"))
  end
  if label:find("^ui%.", 1) then return _tr(label) end
  return label
end

local function formatNearbyTitle(poiType, poiName)
  local typeLabel = prettyPoiType(poiType)
  local name = poiName and tostring(poiName) or ""
  if name == "" then return typeLabel end
  if typeLabel == "" or typeLabel == tostring(poiType) then return _tr(name) end
  return typeLabel .. " - " .. _tr(name)
end

-- Player and POI data -----------------------------------------------------------------------------

local function getPlayerPos()
  if core_camera then
    return core_camera.getPosition()
  end
  return nil
end

-- Raw POIs keyed by id, for the bigmap markers the POI list lacks; empty when the raw list is missing.
local function getRawPoiById()
  local byId = {}
  if not gameplay_rawPois or not gameplay_rawPois.getRawPoiListByLevel then return byId end

  gameplay_rawPois.clear()
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  for _, poi in ipairs(gameplay_rawPois.getRawPoiListByLevel(levelId) or {}) do
    if poi and poi.id then byId[poi.id] = poi end
  end
  return byId
end

-- Metres from the player to the POI's edge; nil when the POI has no position.
local function getDistanceFromPlayer(playerPos, poi, rawPoi)
  if not playerPos then return nil end

  local pos = poi and poi.pos or nil
  local radius = (poi and poi.radius) or 0
  if (not pos) and rawPoi and rawPoi.markerInfo and rawPoi.markerInfo.bigmapMarker then
    pos = rawPoi.markerInfo.bigmapMarker.pos
    radius = rawPoi.markerInfo.bigmapMarker.radius or radius
  end
  if not pos then return nil end

  -- Accept vec3 or plain {x,y,z}/[1,2,3] tables from cached POI data.
  if type(pos) == "table" and not pos.squaredLength then
    pos = vec3(pos.x or pos[1] or 0, pos.y or pos[2] or 0, pos.z or pos[3] or 0)
  end

  return math.max(0, (pos - playerPos):length() - (radius or 0))
end

-- Selection ---------------------------------------------------------------------------------------

local function sortByDistance(a, b)
  if a.distanceM and b.distanceM then return a.distanceM < b.distanceM end
  if a.distanceM then return true end
  if b.distanceM then return false end
  return tostring(a.id) < tostring(b.id)
end

local function addUniqueSelection(selection, selectedIds, item)
  if not item or selectedIds[item.id] then return false end
  selectedIds[item.id] = true
  table.insert(selection, item)
  return true
end

local function getUnselectedItems(items, selectedIds)
  local remaining = {}
  for _, item in ipairs(items) do
    if not selectedIds[item.id] then table.insert(remaining, item) end
  end
  return remaining
end

local function addNearestSelections(selection, selectedIds, items, count)
  for _, item in ipairs(items) do
    if count <= 0 then return end
    if addUniqueSelection(selection, selectedIds, item) then count = count - 1 end
  end
end

local function addMediumDistanceSelections(selection, selectedIds, items, count)
  local remaining = getUnselectedItems(items, selectedIds)
  if #remaining == 0 then return end

  local startIndex = math.max(1, math.floor((#remaining - count) / 2) + 1)
  for i = startIndex, #remaining do
    if count <= 0 then return end
    if addUniqueSelection(selection, selectedIds, remaining[i]) then count = count - 1 end
  end
end

local function addRandomSelections(selection, selectedIds, items, count)
  local remaining = getUnselectedItems(items, selectedIds)
  while count > 0 and #remaining > 0 do
    local index = math.random(#remaining)
    if addUniqueSelection(selection, selectedIds, remaining[index]) then count = count - 1 end
    table.remove(remaining, index)
  end
end

-- Near activities first (nearest first), then the nearest, medium and random far ones fill the rest.
local function splitByNearRadius(items)
  local near, far = {}, {}
  for _, item in ipairs(items) do
    if item.distanceM and item.distanceM <= NEAR_RADIUS_M then
      table.insert(near, item)
    else
      table.insert(far, item)
    end
  end
  table.sort(near, sortByDistance)
  table.sort(far, sortByDistance)
  return near, far
end

local function selectActivityItems(items, maxItems)
  local selection = {}
  local selectedIds = {}
  local targetCount = maxItems or MAX_ITEMS

  local near, far = splitByNearRadius(items)
  for _, item in ipairs(near) do
    if #selection >= targetCount then break end
    addUniqueSelection(selection, selectedIds, item)
  end

  if #selection < targetCount then
    addNearestSelections(selection, selectedIds, far, math.min(2, targetCount - #selection))
    addMediumDistanceSelections(selection, selectedIds, far, math.min(2, targetCount - #selection))
    addRandomSelections(selection, selectedIds, far, targetCount - #selection)
  end

  table.sort(selection, sortByDistance)
  return selection
end

-- Rows --------------------------------------------------------------------------------------------

local function activityRow(poiId, poi, distance, isBigMapAllowed)
  local rawId = poi.id or poiId
  return {
    id = tostring(rawId),
    title = formatNearbyTitle(poi.type, poi.name or tostring(rawId)),
    icon = poi.icon,
    description = prettyPoiType(poi.type),
    actionLabel = _tr("ui.pause.nearbyActivities.action.open"),
    poiType = poi.type,
    distanceM = math.floor(distance + 0.5),
    actions = getActionsForPoi(rawId, isBigMapAllowed),
  }
end

local function getNearbyActivityItems(maxItems, isBigMapAllowed)
  if not freeroam_vueBigMap or not freeroam_vueBigMap.getPoiData then return {} end

  local playerPos = getPlayerPos()
  local poiData = freeroam_vueBigMap.getPoiData() or {}
  local rawPoiById = getRawPoiById()
  local activityTypes = getActivityPoiTypes()
  local rows = {}
  for poiId, poi in pairs(poiData) do
    if activityTypes[poi.type] then
      local distance = getDistanceFromPlayer(playerPos, poi, rawPoiById[poiId])
      if distance then table.insert(rows, activityRow(poiId, poi, distance, isBigMapAllowed)) end
    end
  end
  table.sort(rows, sortByDistance)
  return selectActivityItems(rows, maxItems)
end

-- Public API --------------------------------------------------------------------------------------

function M.executeNearbyActivityAction(buttonId, payload)
  if not buttonId then return false end
  return buttonInstance.executeButton(buttonId, payload)
end

local function noActivityItem()
  return {
    id = "nearby.none",
    title = _tr("ui.pause.nearbyActivities.none.title"),
    description = _tr("ui.pause.nearbyActivities.none.description"),
    actionLabel = _tr("ui.pause.nearbyActivities.none.openMap"),
  }
end

function M.getData(context)
  local mode = context and context.mode or "freeroam"
  local items = getNearbyActivityItems(MAX_ITEMS, context and context.isBigMapAllowed)
  if #items == 0 then items = {noActivityItem()} end

  return {
    mode = mode,
    sections = {
      {
        id = "nearbyActivities",
        title = _tr("ui.pause.nearbyActivities.sectionTitle"),
        items = items,
      },
    },
  }
end

-- Game hooks --------------------------------------------------------------------------------------

-- A provider field that hands the call to this module's function of the same name.
local function forwardTo(key)
  return function(original)
    return function(...)
      return M[key](...)
    end
  end
end

M.onExtensionLoaded = function()
  overhaul_shell_patches.registerFields(PATCH_ID, overhaul_shell_patches.loadedExtension("ui_pause_providers_nearbyActivities"), {
    getData = forwardTo("getData"),
    executeNearbyActivityAction = forwardTo("executeNearbyActivityAction"),
  })
end

M.onExtensionUnloaded = function()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

return M
