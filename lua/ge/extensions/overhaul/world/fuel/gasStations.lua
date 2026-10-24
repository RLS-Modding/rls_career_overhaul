-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/freeroam/gasStations.lua (BeamNG 0.40).

-- Gas station POIs and refuel prompts for Overhaul; the game's freeroam_gasStations pauses while Overhaul runs.

local M = {}
M.dependencies = {"overhaul_shell_patches"}

local PATCH_ID = "gasStations"

local function isOverhaulActive()
  return overhaul_shell_gameMode and overhaul_shell_gameMode.isActive and overhaul_shell_gameMode.isActive() or false
end

local ignoreFuelTypes = {
  air = true,
}

local fuelTypeToFuelTranslation = {
  gasoline = 'refuel',
  diesel = 'refuel',
  kerosine = 'refuel',
  n2o = 'refuel',
  electricEnergy = 'recharge',
  any = 'refuel',
  unknown = 'refuel'
}

-- Prompt chip order: gasoline, diesel, others A-Z, electricity last.
local fuelTypeOrder = {gasoline = 1, diesel = 2, electricEnergy = 4}
local function compareFuelTypes(a, b)
  local rankA, rankB = fuelTypeOrder[a] or 3, fuelTypeOrder[b] or 3
  if rankA ~= rankB then return rankA < rankB end
  return tostring(a) < tostring(b)
end

local soundByKey = {
  refuel = 'event:>UI>Career>Fueling_Petrol_Simple',
  recharge = 'event:>UI>Career>Fueling_Electric_Simple',
  refuelMixed = 'event:>UI>Career>Fueling_Petrol_Simple',
}

local function gasStationCenterRadius(f)
  local center, count = vec3(0,0,0), 0
  for _, pair in ipairs(f.pumps or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    end
  end
  center = center / count

  local maxDistSqr = 0
  for _, pair in ipairs(f.pumps or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      maxDistSqr = math.max(maxDistSqr, (obj:getPosition()-center):squaredLength())
    end
  end

  return center, math.sqrt(maxDistSqr)
end
M.gasStationCenterRadius = gasStationCenterRadius

local function formatGasStationPoi(gasStation)
  local center, radius = gasStationCenterRadius(gasStation)
  local isElectric = tableValuesAsLookupDict(gasStation.energyTypes or {"any"}).electricEnergy
  local elem = {
    id = gasStation.id,
    data = { type = "gasStation", facility = gasStation},
    markerInfo = {
      gasStationMarker = {pumps = gasStation.pumps, pos = center, radius = radius, electric = isElectric},
      bigmapMarker = { pos = center, icon = isElectric and "poi_charge_round" or "poi_fuel_round", name = gasStation.name, description = gasStation.description, thumbnail = gasStation.preview, previews = {gasStation.preview}, cardIcon = isElectric and "charge" or "fuelPump"}
    }
  }
  return elem
end

M.formatGasStationPoi = formatGasStationPoi

-- On foot the player vehicle is the walking unicycle, which has no tank. Pump
-- into the closest car instead: in career only one the player can pay for
-- (inventory or business fleet), in freeroam anything but ambient traffic.
local walkUpRefuelRadius = 10

local function isUnicycle(veh)
  return veh ~= nil and veh:getJBeamFilename() == "unicycle"
end

local function isAmbientVehicle(vehId)
  if gameplay_traffic and gameplay_traffic.getTrafficData and gameplay_traffic.getTrafficData()[vehId] then
    return true
  end
  if overhaul_integration_services_parking and overhaul_integration_services_parking.getParkedCarsList then
    for _, id in ipairs(overhaul_integration_services_parking.getParkedCarsList() or {}) do
      if id == vehId then return true end
    end
  end
  return false
end

local function canRefuelOnFoot(vehId)
  if overhaul_career_career.isActive() then
    if overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId) then
      return true
    end
    return overhaul_career_business_fleet ~= nil
      and overhaul_career_business_fleet.getBusinessVehicleFromSpawnedId ~= nil
      and overhaul_career_business_fleet.getBusinessVehicleFromSpawnedId(vehId) ~= nil
  end
  return not isAmbientVehicle(vehId)
end

local bbCenter, bbAxis, toPos = vec3(), vec3(), vec3()
-- Distance from pos to the vehicle's oriented bounding box (0 when inside).
local function distanceToVehicleBB(pos, vehId)
  bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
  toPos:set(pos)
  toPos:setSub(bbCenter)
  local outsideSqr = 0
  for axis = 0, 2 do
    bbAxis:set(be:getObjectOOBBHalfAxisXYZ(vehId, axis))
    local halfLen = bbAxis:length()
    if halfLen > 0 then
      local excess = math.abs(toPos:dot(bbAxis) / halfLen) - halfLen
      if excess > 0 then outsideSqr = outsideSqr + excess * excess end
    end
  end
  return math.sqrt(outsideSqr)
end

local function findNearestRefuelVehicle(pos)
  local nearest, nearestDist = nil, walkUpRefuelRadius
  for _, veh in ipairs(getAllVehicles()) do
    local vehId = veh:getID()
    if not isUnicycle(veh) and veh:getActive() and veh.playerUsable ~= false
        and be:getObjectOOBBIsInitialized(vehId) and canRefuelOnFoot(vehId) then
      local dist = distanceToVehicleBB(pos, vehId)
      if dist < nearestDist then
        nearest, nearestDist = veh, dist
      end
    end
  end
  return nearest
end

-- Returns the vehicle a pump prompt should fill and whether it was picked on foot.
local function getRefuelTarget()
  local playerVeh = getPlayerVehicle(0)
  if not isUnicycle(playerVeh) then
    return playerVeh, false
  end
  return findNearestRefuelVehicle(playerVeh:getPosition()), true
end
M.getRefuelTarget = getRefuelTarget

local function getVehicleLabel(veh)
  if overhaul_career_career.isActive() and overhaul_career_garage_inventory then
    local invId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(veh:getID())
    local vehData = invId and overhaul_career_garage_inventory.getVehicles()[invId]
    if vehData and vehData.niceName then return vehData.niceName end
  end
  local model = core_vehicles.getModel(veh:getJBeamFilename()).model
  if model and model.Name then
    return model.Brand and (model.Brand .. " " .. model.Name) or model.Name
  end
  return veh:getJBeamFilename()
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not isOverhaulActive() then return end
  local facilities = overhaul_world_facilities.getFacilities(levelIdentifier)
  if overhaul_career_career.isActive() or settings.getValue("enableGasStationsInFreeroam") then
    for i, gasStation in ipairs(facilities.gasStations or {}) do
      table.insert(elements, formatGasStationPoi(gasStation))
    end
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel


local function onActivityAcceptGatherData(elemData, activityData)
  if not isOverhaulActive() then return end
  for _, elem in ipairs(elemData) do
    if elem.type == "gasStation" then
      local playModeIconName = "poi_fuel_round"
      if tableValuesAsLookupDict(elem.facility.energyTypes or {"any"}).electricEnergy then
        playModeIconName = "poi_charge_round"
      end
      local data = {
        icon = playModeIconName,
        heading = elem.facility.name,
        preheadings = {"Gas Station"},
        sorting = {
          type = elem.type,
          id = elem.id
        }
      }
      local props = {}
      local fuelTypes = tableValuesAsLookupDict(elem.facility.energyTypes or {"any"})
      local fuelTranslations = {}
      local sortedFuelTypes = tableKeys(fuelTypes)
      table.sort(sortedFuelTypes, compareFuelTypes)
      for _, fuelType in ipairs(sortedFuelTypes) do
        if fuelType ~= "unknown" then
          fuelTranslations[fuelTypeToFuelTranslation[fuelType]] = (fuelTranslations[fuelTypeToFuelTranslation[fuelType]] or 0) + 1
          table.insert(props, {
            icon = fuelType == "electricEnergy" and "charge" or "fuelPump",
            keyLabel = "ui.general.fuelType."..fuelType
          })
        end
      end
      -- Charging-only stations are not gas stations; mixed ones still are.
      if fuelTranslations.recharge and not fuelTranslations.refuel then
        data.preheadings = {"Charging Station"}
      end
      local key = next(fuelTranslations)
      if #tableKeys(fuelTranslations) > 1 then
        key = "refuelMixed"
      end
      local target, onFoot = getRefuelTarget()
      if onFoot then
        table.insert(props, 1, {
          icon = "car",
          keyLabel = target and ("Vehicle: " .. getVehicleLabel(target)) or "No vehicle nearby",
        })
      end
      data.props = props
      data.buttonLabel = ("ui.freeroam."..key..".prompt")
      data.buttonFun = function()
        local veh, walkedUp = getRefuelTarget()
        if not veh then
          if walkedUp then
            local msg = overhaul_career_career.isActive() and "Park one of your vehicles next to the pump to refuel it" or "Park a vehicle next to the pump to refuel it"
            guihooks.trigger('Message', {msg = msg, category = "refueling", icon = "warning", ttl = 6})
          end
          return
        end
        M.refuelCar(elem, fuelTypes, veh)
      end
      data.buttonSoundClass = "bng_hover_generic"
      table.insert(activityData, data)
    end
  end
end
M.onActivityAcceptGatherData = onActivityAcceptGatherData


local function refuelCar(gasStation, fuelTypes, veh)
  --ui_missionInfo.closeDialogue()
  core_vehicleBridge.requestValue(veh,
    function(ret)
      local anySuccess, allSuccess = false, true
      local fuelTranslations = {}
      local invalidTanks = {}
      for _, tank in ipairs(ret[1]) do
        if not ignoreFuelTypes[tank.energyType] then
          local fuelType = fuelTypeToFuelTranslation[tank.energyType] and tank.energyType or "unknown"
          local valid = fuelTypes['any'] or fuelTypes[fuelType]

          anySuccess = anySuccess or valid
          allSuccess = allSuccess and valid
          fuelTranslations[fuelTypeToFuelTranslation[fuelType]] = (fuelTranslations[fuelTypeToFuelTranslation[fuelType]] or 0) + 1
          if valid then
            if overhaul_career_career.isActive() then
              overhaul_career_maintenance_fuel.startTransaction(gasStation, veh:getID())
              return
            else
              core_vehicleBridge.executeAction(veh,'setEnergyStorageEnergy', tank.name, tank.maxEnergy)
            end
          else
            invalidTanks[tank.energyType] = true
          end
        end
      end
      local key = next(fuelTranslations)
      if #tableKeys(fuelTranslations) > 1 then
        key = "refuelMixed"
      end
      if anySuccess then
        if allSuccess then
          guihooks.trigger('Message',{msg = "ui.freeroam."..key..".complete", category = "refueling", icon = "check", ttl=8})
          local pos = veh:getPosition()
          Engine.Audio.playOnce('AudioGui',soundByKey[key], {position = vec3(pos.x, pos.y, pos.z)})
        else
          guihooks.trigger('Message',{msg = "ui.freeroam."..key..".partial", category = "refueling", icon = "warning", ttl=8})
        end
        gameplay_achievement.unlockAchievement("VEHICLE_REFUELLED")
      else
        guihooks.trigger('Message',{msg = "ui.freeroam.refuel.failed", category = "refueling", icon = "error", ttl=8})
      end
      if not allSuccess then
        for _, fuelType in ipairs(tableKeysSorted(invalidTanks)) do
          guihooks.trigger('Message',{msg = {txt = "ui.freeroam.refuel.notFilled", context = {fuelType = _tr("ui.general.fuelType."..fuelType, fuelType)}}, category = "refueling-"..fuelType, icon = "warning", ttl=8})
        end
      end
    end
    , 'energyStorage')
end
M.refuelCar = refuelCar

local silenced = function() return function() end end

M.onExtensionLoaded = function()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return freeroam_gasStations end, {
    onGetRawPoiListForLevel = silenced,
    onActivityAcceptGatherData = silenced,
  })
end

M.onExtensionUnloaded = function()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

return M
