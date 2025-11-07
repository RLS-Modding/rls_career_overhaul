-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- this module manages simple fueling for fuel stations. it defers to the career refueling module if career is loaded.

local M = {}

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

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  local facilities = freeroam_facilities.getFacilities(levelIdentifier)
  if career_career.isActive() or settings.getValue("enableGasStationsInFreeroam") then
    for i, gasStation in ipairs(facilities.gasStations or {}) do
      table.insert(elements, formatGasStationPoi(gasStation))
    end
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel


local function onActivityAcceptGatherData(elemData, activityData)
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
      for fuelType, _ in pairs(fuelTypes) do
        if fuelType ~= "unknown" then
          fuelTranslations[fuelTypeToFuelTranslation[fuelType]] = (fuelTranslations[fuelTypeToFuelTranslation[fuelType]] or 0) + 1
          table.insert(props, {
            icon = "fuelPump",
            keyLabel = "ui.general.fuelType."..fuelType
          })
        end
      end
      local key = next(fuelTranslations)
      if #tableKeys(fuelTranslations) > 1 then
        key = "refuelMixed"
      end
      data.props = props
      data.buttonLabel = ("ui.freeroam."..key..".prompt")
      data.buttonFun = function() M.refuelCar(elem, fuelTypes, getPlayerVehicle(0)) end
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
            if career_career.isActive() then
              career_modules_fuel.startTransaction(gasStation)
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
      else
        guihooks.trigger('Message',{msg = "ui.freeroam.refuel.failed", category = "refueling", icon = "error", ttl=8})
      end
      if not allSuccess then
        for _, fuelType in ipairs(tableKeysSorted(invalidTanks)) do
          guihooks.trigger('Message',{msg = {txt = "ui.freeroam.refuel.notFilled", context = {fuelType = translateLanguage("ui.general.fuelType."..fuelType, fuelType, true)}}, category = "refueling-"..fuelType, icon = "warning", ttl=8})
        end
      end
    end
    , 'energyStorage')
end
M.refuelCar = refuelCar

return M
