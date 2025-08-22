-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"core_vehicleBridge"}
local moduleVersion = 42
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehicleTasks, dTasklist, dParcelMods, dVehOfferManager
local step
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dVehicleTasks = career_modules_delivery_vehicleTasks
  dTasklist = career_modules_delivery_tasklist
  dParcelMods = career_modules_delivery_parcelMods
  dVehOfferManager = career_modules_delivery_vehicleOfferManager
  step = util_stepHandler
end

local deliveryGameTime = 0
local deliveryGameTimePaused = false

local deliveryModeActive = false
local deliveryAbandonPenaltyFactor = 0.1
M.getDeliveryAbandonPenaltyFactor = function() return deliveryAbandonPenaltyFactor end

-- Career general systems interaction (save/load, level setup)

local saveFile = "logisticsDatabase.json"
local loadData = {}
local function loadSaveData()
  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  if not saveSlot then return end

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local outdated = not saveInfo or saveInfo.version < moduleVersion

  local data = (not outdated and savePath and jsonReadFile(savePath .. "/career/"..saveFile)) or {}

  loadData = data
  dProgress.setProgress(loadData.progress)
  dParcelMods.setProgress(loadData.parcelModProgress)
  loadData.facilities = loadData.facilities or {}
  loadData.settings = data.settings or {}

  if loadData.settings.automaticRoute == nil then
    loadData.settings.automaticRoute = true
  end

  deliveryGameTime = loadData.general and loadData.general.gameTime or deliveryGameTime
  if loadData.general and loadData.general.osTime then
    log("I","",string.format("Save data age: %ds",os.time() - loadData.general.osTime))
    -- delete save data if the save is older than an hour
    if os.time() - loadData.general.osTime > 3600 then
      log("I","",string.format("Save data is older than 3600s (%d), wiping cargo and facility timers",os.time() - loadData.general.osTime))
      loadData.cargo = {}
      for key, fac in pairs(loadData.facilities) do
        fac.logisticGenerators = nil
      end
    end
  end

  --log("I","",string.format("Loaded save data for logistics: %d cargo", #loadData.cargo))
end
M.loadSaveData = loadSaveData
local function saveableCargoFilter(cargo)
  return cargo.offerExpiresAt > M.time() and cargo.location.type == "facilityParkingspot"
end
local function onSaveCurrentSaveSlot(currentSavePath)
  local filePath = currentSavePath .. "/career/" .. saveFile
  local saveData = {
    general = {},
    penalty = M.getDeliveryModePenalty(),
    parcels = {},
    vehicleOffers = {},
    facilities = {},
    settings = loadData.settings or {}
  }

  -- general data
  saveData.general.gameTime = M.time()
  saveData.general.osTime = os.time()
  saveData.progress = dProgress.getProgress()
  saveData.parcelModProgress = dParcelMods.getProgress()

  -- facility data

  -- parcels
  local saveableCargo = dParcelManager.getAllCargoCustomFilter(saveableCargoFilter)
  local maxGroupId = 0
  local groupMap = {}
  for _, cargo in ipairs(saveableCargo) do
    local elem = {
      rewards = cargo.rewards,
      templateId = cargo.templateId,
      name = cargo.name,
      type = cargo.type,
      slots = cargo.slots,
      offerExpiresAt = cargo.offerExpiresAt,
      location = cargo.location,
      origin = cargo.origin,
      destination = cargo.destination,
      data = cargo.data,
      generatorLabel = cargo.generatorLabel,
      modifiers = cargo.modifiers,
      generatedAtTimestamp = cargo.generatedAtTimestamp,
      weight = cargo.weight,
      density = cargo.density,
      groupSeed = cargo.groupSeed,
      automaticDropOff = cargo.automaticDropOff,
      organization = cargo.organization,
    }
    if not groupMap[cargo.groupId] then
      maxGroupId = maxGroupId + 1
      groupMap[cargo.groupId] = maxGroupId
    end
    elem.groupId = groupMap[cargo.groupId]
    table.insert(saveData.parcels, elem)
  end
  saveData.general.maxGroupId = maxGroupId

  local saveableVehicleOffers = dVehOfferManager.getAllOfferUnexpired()
  for _, offer in ipairs(saveableVehicleOffers) do
    -- vehicle offers dont need to be trunkated/cut before saving
    table.insert(saveData.vehicleOffers, offer)
  end

  -- facility data
  for _, facility in ipairs(dGenerator.getFacilities()) do
    local elem = {
      logisticGenerators = {},
      progress = facility.progress,
      materialStorages = facility.materialStorages,
    }
    for i, generator in ipairs(facility.logisticGenerators or {}) do
      elem.logisticGenerators[i] = {
        nextGenerationTimestamp = generator.nextGenerationTimestamp
      }
    end
    saveData.facilities[facility.id] = elem
  end

  -- save the data to file
  career_saveSystem.jsonWriteFileSafe(filePath, saveData, true)
end
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

local function onCareerModulesActivated(alreadyInLevel)
  if alreadyInLevel then
    loadSaveData()
    map.assureLoad()
    dGenerator.setup(loadData)
  end
end
M.onCareerModulesActivated = onCareerModulesActivated

local function onClientStartMission(levelPath)
  loadSaveData()
  map.assureLoad()
  dGenerator.setup(loadData)
end
M.onClientStartMission = onClientStartMission


local fast = 1
M.time = function() return deliveryGameTime end



-- vehicle management

local function getVehicleName(vehId)
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  local niceVehicleName = inventoryId and career_modules_inventory.getVehicles()[inventoryId].niceName
  return niceVehicleName and niceVehicleName or ("Vehicle " .. vehId)
end
M.getVehicleName = getVehicleName


local mostRecentCargoContainerData = {}
local nearbyRadius = 25*25
local sortByVehIdAndContainerId = function(a,b) if a.vehId == b.vehId then return a.containerId < b.containerId else return a.vehId < b.vehId end end
local function getNearbyVehicleCargoContainers(callback)
  if not core_vehicleBridge then return {} end
  local vehCargoData = {}
  local playerPos = getPlayerVehicle(0)
  playerPos = playerPos and playerPos:getPosition() or core_camera.getPosition()
  local vehs = {}
  local refNodeClusterIdByVehId = {}
  for vehId, veh in activeVehiclesIterator() do
    if veh:getJBeamFilename() ~= "unicycle" and veh.playerUsable ~= false and (playerPos-veh:getPosition()):squaredLength() < nearbyRadius then
      vehCargoData[vehId] = -1
      vehs[vehId] = veh
      refNodeClusterIdByVehId[vehId] = veh:getNodeClusterId(veh:getRefNodeId())
    end
  end
  for vehId, veh in pairs(vehs) do

    core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
      vehCargoData[vehId] = {}

      for _, container in ipairs(vehCargoContainerData[1]) do
        local vehName = getVehicleName(vehId)
        local elem = {
          vehId = vehId,
          containerId = container.id,
          location = {type = "vehicle", vehId = veh:getID(), containerId = container.id},
          vehName = vehName,
          name = container.name,
          moveToLabel = vehName .. " " .. container.name,
          cargoTypesLookup = tableValuesAsLookupDict(container.cargoTypes),
          cargoTypesString = table.concat(container.cargoTypes,", "),
          totalCargoSlots = container.capacity,
          usedCargoSlots = 0,
          transientCargoSlots = 0,
          freeCargoSlots = container.capacity,
          refNodeClusterId = refNodeClusterIdByVehId[vehId],
          clusterId = container.nodeId and veh:getNodeClusterId(container.nodeId),
          position = (container.nodeId and veh:getNodePosition(container.nodeId) or vec3(0,0,0)) + veh:getPosition(),
        }


        if not elem.clusterId or elem.refNodeClusterId == elem.clusterId then
          elem.attachmentStatus = "attached"
        else
          local dist = (elem.position-veh:getPosition()):length()
          if dist < 10 then
            elem.attachmentStatus = "nearby"
          else
            elem.attachmentStatus = "lost"
          end
        end
        elem.rawCargo = dParcelManager.getAllCargoForLocation(elem.location)

        elem.transientCargo = dParcelManager.getTransientMovesForTargetLocationWithCargo(elem.location)


        --for key, amount in pairs(elem.totalCargoSlots) do
        --  elem.usedCargoSlots[key] = 0
        --end
        for _, cargo in ipairs(elem.rawCargo) do
          elem.usedCargoSlots = elem.usedCargoSlots + cargo.slots
          elem.freeCargoSlots = elem.freeCargoSlots - cargo.slots
        end

        for _, cargo in ipairs(elem.transientCargo) do
          elem.usedCargoSlots = elem.usedCargoSlots + cargo.slots
          elem.transientCargoSlots = elem.transientCargoSlots + cargo.slots
          elem.freeCargoSlots = elem.freeCargoSlots - cargo.slots
        end

        table.insert(vehCargoData[vehId], elem)
      end

      -- check if all cargo was sent
      for key, val in pairs(vehCargoData) do
        if val == -1 then return end
      end

      -- if we're still here, call the function callback to send data back
      local ret = {}
      for _, list in pairs(vehCargoData) do
        for _, elem in ipairs(list) do
          table.insert(ret, elem)
        end
      end
      table.sort(ret, sortByVehIdAndContainerId)
      mostRecentCargoContainerData = ret
      callback(ret)

    end, "getCargoContainers")
  end
  if not next(vehs) then
    callback({})
  end

end
M.getNearbyVehicleCargoContainers = getNearbyVehicleCargoContainers


local function defaultDelayCallback(data)
  local maxDelay = 0
  for _, delay in pairs(data) do
    maxDelay = math.max(delay, maxDelay)
  end
  if maxDelay > 0 then
    maxDelay = math.max(maxDelay, 1)
    -- make
    local sequence = {
      step.makeStepWait(maxDelay+0.5),
      step.makeStepReturnTrueFunction(function()
        for vehId, data in pairs(data) do
          local veh = scenetree.findObjectById(vehId)
          core_vehicleBridge.executeAction(veh, 'setFreeze', false)
        end
        gameplay_markerInteraction.setForceReevaluateOpenPrompt()
      return true
      end
      )
    }
    step.startStepSequence(sequence, callback)
    -- add loading progress bar
    guihooks.trigger("OpenSimpleDelayPopup",{timer=maxDelay, heading="Loading Cargo..."})
  else
    -- 1s delay, no freeze
    for vehId, data in pairs(data) do
      local veh = scenetree.findObjectById(vehId)
      core_vehicleBridge.executeAction(veh, 'setFreeze', false)
    end
    gameplay_markerInteraction.setForceReevaluateOpenPrompt()
  end
  log("I","",string.format("%0.2fs delay after adjusting weights for cargo.", maxDelay))
end

local updateWeightsScheduled = false
M.requestUpdateContainerWeights = function() updateWeightsScheduled = true end
local function updateContainerWeights(delayCallback)
  if not updateWeightsScheduled then
    return
  end
  delayCallback = delayCallback or defaultDelayCallback
  updateWeightsScheduled = false
  log("I","","updateContainerWeights...")
  local updatePerVehicle = {}
  for vehId, veh in activeVehiclesIterator() do
    if veh:getJBeamFilename() ~= "unicycle" and veh.playerUsable ~= false then
      updatePerVehicle[vehId] = {}
    end
  end
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
    updatePerVehicle[cargo.location.vehId][cargo.location.containerId] = updatePerVehicle[cargo.location.vehId][cargo.location.containerId] or {
      volume = 0,
      density = 1,
      containerId = cargo.location.containerId
    }
    if not cargo.weight then log("W","","No weight on cargo? " .. dumps(cargo.name)) dump(cargo) end

    if cargo.type == "parcel" then
      -- add up load/weight
      updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume = updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume + (cargo.weight or 0)
    end

    if cargo.type == "fluid" or cargo.type == "dryBulk" or cargo.type == "cement" or cargo.type == "cash" then
      -- add up volume
      updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume = updatePerVehicle[cargo.location.vehId][cargo.location.containerId].volume + (cargo.slots or 0)
      -- only keep one density, since all cargo in one container have the same density
      updatePerVehicle[cargo.location.vehId][cargo.location.containerId].density = (cargo.weight/cargo.slots or 1)
    end

  end
  --if next(updatePerVehicle) then
  for vehId, data in pairs(updatePerVehicle) do
    local veh = scenetree.findObjectById(vehId)

    core_vehicleBridge.executeAction(veh, "setCargoContainers", updatePerVehicle[vehId] or {}, "updateAll")
    core_vehicleBridge.executeAction(veh, 'setFreeze', true)

    for _, con in pairs(updatePerVehicle[vehId]) do
      log("I","",string.format("Container %d => volume %0.1f | density: %0.1f",con.containerId, con.volume or 0, con.density or 1))
    end
  end

  -- check loading delay
  local delayData = {}
  for vehId, data in pairs(updatePerVehicle) do
    delayData[vehId] = -1
  end

  for vehId, data in pairs(updatePerVehicle) do
    local veh = scenetree.findObjectById(vehId)
    core_vehicleBridge.requestValue(veh, function(vehCargoContainerData)
      local maxForContainer = 0
      for _, container in ipairs(vehCargoContainerData[1]) do
        maxForContainer = math.max(maxForContainer, container.reachTargetTimeRemaining)
      end
      delayData[vehId] = maxForContainer


      for key, val in pairs(delayData) do
        if val == -1 then return end
      end
      delayCallback(delayData)

    end, "getCargoContainers")
  end
  if not next(updatePerVehicle) then
    delayCallback(delayData)
  end

end
M.updateContainerWeights = updateContainerWeights


local colorForAttachmentDebug = {
  attached = ColorF(0.2,1,0.2, 0.75),
  nearby = ColorF(1,1,0.2, 0.75),
  lost = ColorF(1,0.2,0.2, 0.75),
}
local tickTimer = 0
M.setDeliveryTimePaused = function(paused) deliveryGameTimePaused = paused end
M.onUpdate = function(dtReal, dtSim, dtRaw)
  profilerPushEvent("Delivery DeliveryManager")
  -- update game time
  --if freeroam_bigMapMode.bigMapActive() and not freeroam_bigMapMode.isTransitionActive() and not deliveryGameTimePaused then
    --deliveryGameTime = deliveryGameTime + dtReal * fast
  --else
  --end
  if not deliveryGameTimePaused then
    deliveryGameTime = deliveryGameTime + dtSim * fast
  end

  -- handle penalty from previous save
  if loadData.penalty and next(loadData.penalty) then
    local anyValue = false
    for key, value in pairs(loadData.penalty) do
      if value ~= 0 then
        anyValue = true
      end
    end
    if anyValue then
      guihooks.trigger("toastrMsg", {type="warning", title="Cargo abandoned", msg=string.format("Cargo from last save was abandoned. Penalty: %0.2f$", -loadData.penalty.money or 0)})
      career_modules_playerAttributes.addAttributes(loadData.penalty, {tags={"gameplay", "delivery","fine"}, label="Penalty for abandoning cargo."})
    end
    loadData.penalty = nil
  end

  tickTimer = tickTimer + dtSim
  if tickTimer > 1 then
    M.getNearbyVehicleCargoContainers(nop)
    tickTimer = tickTimer - 1
  end

  -- check if container weights need to be updated, only if unpauses
  if dtSim > 10e-10 then
    M.updateContainerWeights()
  end

  -- debug display for cargo boxes
  --[[
  if deliveryModeActive then
    for _, container in ipairs(mostRecentCargoContainerData) do
      simpleDebugText3d(container.name, container.position, 0.15, colorForAttachmentDebug[container.attachmentStatus])
    end
  end
  ]]

  profilerPopEvent("Delivery DeliveryManager")
end


local function addInteractivePoi(list, id, field, elem)
  if not list[id] then list[id] = {dropOffs = {}, pickUps = {}, vehicles = {}} end
  table.insert(list[id][field], elem)
end
local function getInteractivePois()
  local interactiveParkingSpots = {}
  for _, cargo in ipairs(dParcelManager.getAllCargoInVehicles()) do
    if cargo.destination.type == "facilityParkingspot" then
      addInteractivePoi(interactiveParkingSpots, cargo.destination.psPath, "dropOffs", cargo)

    elseif cargo.destination.type == "multi" then
      for _, dest in ipairs(cargo.destination.destinations) do
        addInteractivePoi(interactiveParkingSpots, dest.psPath, "dropOffs", cargo)
      end
    end
  end

  for _, cargo in ipairs(dParcelManager.getTransientMoveCargo()) do
    local locPsPath = cargo.location.psPath
    addInteractivePoi(interactiveParkingSpots, locPsPath, "pickUps", cargo)
  end

  -- figure out which facilities need to be active in order to drop of vehicles.
  local trailerTargetDestinations = dVehicleTasks.getTargetDestinationsForActiveTasks()
  local targetFacilityIds = {}
  for _, destination in ipairs(trailerTargetDestinations) do
    targetFacilityIds[destination.facId] = true
    addInteractivePoi(interactiveParkingSpots, destination.psPath, "vehicles", "vehicle")
  end
  return interactiveParkingSpots, targetFacilityIds
end
-- poi list stuff
local function onGetRawPoiListForLevel(levelIdentifier, elements)

  --local nearbyVehicles = M.getNearbyVehicleCargoContainers()
  local interactiveParkingSpots, targetFacilityIds = getInteractivePois()

  for _, fac in ipairs(freeroam_facilities.getFacilitiesByType("deliveryProvider")) do
    -- only process facilities if the facility is visible
    local includeFac = dProgress.isFacilityVisible(fac.id) or targetFacilityIds[fac.id]

    if includeFac then
      local totalCargoCount = 0
      local lastPsPos = nil

      -- look up all relevant parking spots for this facility
      local spotsForThisFacLookup = {}

      for name, ap in pairs(fac.accessPointsByName) do
        local ps = ap.ps
        local id = string.format("delivery-parking-%s-%s", fac.id, ps:getPath())
        local loc = {type = "facilityParkingspot", facId = fac.id, psPath = ps:getPath()}
        local cargoCount = #dParcelManager.getAllCargoForLocationUnexpiredUndelivered(loc)
        totalCargoCount = totalCargoCount + cargoCount
        lastPsPos = ps.pos
        local icon = "poi_pickup_round"
        if interactiveParkingSpots[ps:getPath()] then
          icon = "poi_dropoff_round"
        end

        local focus = interactiveParkingSpots[ps:getPath()] ~= nil
        local elem = {
          id = id,
          data = {type = "logisticsParking", facId = fac.id, psPath = ps:getPath(), canInspectCargo = ap.isInspectSpot, hasPlayerCargo = interactiveParkingSpots[ps:getPath()] and true or false },
          markerInfo = {
            -- only include parking marker if there is an action
            parkingMarker = cargoCount and {path = ps:getPath(), pos = ps.pos, rot = ps.rot, scl = ps.scl, icon = icon, focus = focus} or nil,
          }
        }
        --print(string.format("including: %s-%s (%s). visible: %s, target: %s",
        --  fac.id, ps.id,
        --  dParcelManager.getLocationLabelShort({type="facilityParkingspot", facId = fac.id, psPath = ps:getPath()}),
        --  dumps(dProgress.isFacilityVisible(fac.id)),
        --  dumps(targetFacilityIds[fac.id] and true or false)
        --  ))
        if dCargoScreen.isCargoScreenOpen() then
          elem.markerInfo.bigmapMarker = {pos = ps.pos, name = "Pickup "..fac.name, icon = icon}
        else
          if interactiveParkingSpots[ps:getPath()] then

            local tasks = {}
            if next(interactiveParkingSpots[ps:getPath()].dropOffs) then
              table.insert(tasks, string.format("Deliver %d cargo items here.", #interactiveParkingSpots[ps:getPath()].dropOffs))
            end
            if next(interactiveParkingSpots[ps:getPath()].pickUps) then
              table.insert(tasks, string.format("Pick up %d cargo items here.", #interactiveParkingSpots[ps:getPath()].pickUps))
            end
            if next(interactiveParkingSpots[ps:getPath()].vehicles) then
              table.insert(tasks, string.format("Deliver %d vehicles here.", #interactiveParkingSpots[ps:getPath()].vehicles))
            end

            local desc = table.concat(tasks, '<br/>')
            elem.markerInfo.bigmapMarker = {
              pos = ps.pos,
              name = dParcelManager.getLocationLabelShort(loc),
              description = desc,
              icon = "poi_dropoff_round",
              previews = {fac.preview},
              thumbnail = fac.preview,
            }
          end
        end
        if interactiveParkingSpots[ps:getPath()] or ap.isInspectSpot or dCargoScreen.isCargoScreenOpen() then
          --dump(string.format("%s -> %s", fac.name, name))
          --dumpz(ap, 1)
          table.insert(elements, elem)
        end
      end
      --[[
      -- add trailer spots in a separate entry.
      if dCargoScreen.isCargoScreenOpen() then
        for _, ps in ipairs(fac.trailerSpots) do

          local id = string.format("delivery-parking-%s-%s", fac.id, ps:getPath())
          local loc = {type = "facilityParkingspot", facId = fac.id, psPath = ps:getPath()}

          local icon = "poi_pickup_round"
          if interactiveParkingSpots[ps:getPath()] then
            icon = "poi_dropoff_round"
          end

          local elem = {
            id = id,
            data = {type = "logisticsParking", facId = fac.id, psPath = ps:getPath(), hasPlayerCargo = interactiveParkingSpots[ps:getPath()] and true or false },
            markerInfo = {
              bigmapMarker = {pos = ps.pos, name = "Pickup "..fac.name, icon = icon}
            }
          }
          table.insert(elements, elem)

        end

     end
]]
      -- one POI for the whole facility to display on bigmap under labourer branch.
      if not dCargoScreen.isCargoScreenOpen() then
        if dProgress.isFacilityUnlocked(fac.id) and next(fac.logisticTypesProvided) then
          local id = string.format("logisticsFacility-%s", fac.id)
          local elems = {}
          if fac.doors and next(fac.doors) then
            freeroam_facilities.walkingMarkerFormatFacility(fac, elems)
          end

          local pos = lastPsPos
          for name, ap in pairs(fac.accessPointsByName) do
            if ap.isInspectSpot then
              pos = ap.ps.pos
            end
          end

          local elem = {
            id = id,
            data = {type = "logisticsOffice", facId = fac.id},
            markerInfo = {
              walkingMarker = next(elems) and elems[1].markerInfo.walkingMarker or nil,
              bigmapMarker = {pos = pos, name = fac.name, description = string.format("%s\n\n%d Item%s available here.",fac.description, totalCargoCount, totalCargoCount ~= 1 and "s" or ""), icon="poi_delivery_round", previews = {fac.preview}, thumbnail = fac.preview,} or nil
            }
          }
          table.insert(elements, elem)
        end
      end
    end
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel



local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData) do
    if elem.type == "logisticsOffice" then
      local data = {
        icon = "poi_delivery_round",
        heading = dGenerator.getFacilityById(elem.facId).name,
        preheadings = {"Logistics Office"},
        sorting = {
          type = elem.type,
          id = elem.id
        },
        props = {{
          icon = "checkmark",
          keyLabel = "Cargo Overview"
        },{
          icon = "checkmark",
          keyLabel = "No Cargo Pickup"
        }},
        buttonLabel = "Inspect Cargo",
        buttonFun = function() dCargoScreen.enterCargoOverviewScreen(elem.facId) end
      }
      table.insert(activityData, data)
    elseif elem.type == "logisticsParking" then

      -- cargo menu button
      local loc = {type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath}
      local poiTemplate = {
        icon = "poi_pickup_round",
        preheadings =  {dParcelManager.getLocationLabelShort({type = "facilityParkingspot", facId = elem.facId, psPath = elem.psPath})},
        props = {},
        sorting = {
          type = elem.type,
          id = elem.id
        },
      }

      -- dropoff data and props
      local psPos = dGenerator.getParkingSpotByPath(elem.psPath).pos
      local dropOffableCargoByCargoType = {
        parcel = 0,
        fluid = 0,
        dryBulk = 0,
        cement = 0,
        cash = 0
      }
      for _, container in ipairs(mostRecentCargoContainerData) do
        for _, cargo in ipairs(container.rawCargo) do
          local add = 1
          local type = cargo.type
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.type == "cement" then
            add = cargo.slots
          end
          if cargo.type == "cash" then
            add = cargo.slots
          end
          if cargo.destination.type == "facilityParkingspot" then
            dropOffableCargoByCargoType[cargo.type]  = dropOffableCargoByCargoType[type] + ((cargo.destination.psPath == elem.psPath and (container.position - psPos):squaredLength() < 25*25) and add or 0)
          elseif cargo.destination.type == "multi" then
            for _, dest in ipairs(cargo.destination.destinations) do
              dropOffableCargoByCargoType[type]  = dropOffableCargoByCargoType[type] + ((dest.psPath == elem.psPath and (container.position - psPos):squaredLength() < 25*25) and add or 0)
            end
          end
        end
      end
      local vehsClose, trailersClose = dVehicleTasks.canDropOffCargoAtPsPath(elem.psPath)
      local anyCargoDropOffable = (dropOffableCargoByCargoType.parcel > 0 or dropOffableCargoByCargoType.fluid > 0 or dropOffableCargoByCargoType.dryBulk > 0 or dropOffableCargoByCargoType.cement > 0 or dropOffableCargoByCargoType.cash > 0) or vehsClose > 0 or trailersClose > 0
      -- dropoff props
      if dropOffableCargoByCargoType.parcel > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%sParcel%s dropoff", dropOffableCargoByCargoType.parcel > 1 and ((dropOffableCargoByCargoType.parcel).." ") or "", dropOffableCargoByCargoType.parcel > 1 and "s" or "")
        })
      end
      if dropOffableCargoByCargoType.fluid > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%dL fluid dropoff", dropOffableCargoByCargoType.fluid)
        })
      end
      if dropOffableCargoByCargoType.dryBulk > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%dL dry bulk dropoff", dropOffableCargoByCargoType.dryBulk)
        })
      end
      if dropOffableCargoByCargoType.cement > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%dL cement dropoff", dropOffableCargoByCargoType.cement)
        })
      end
      if dropOffableCargoByCargoType.cash > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%d cash dropoff", dropOffableCargoByCargoType.cash)
        })
      end
      if vehsClose > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = "Vehicle dropoff"
        })
      end
      if trailersClose > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = "Trailer dropoff"
        })
      end


      -- pickup data and props
      local pickUpAbleCargoByCargoType = {
        parcel = 0,
        fluid = 0,
        dryBulk = 0,
        cement = 0,
        cash = 0
      }
      for _, container in ipairs(mostRecentCargoContainerData) do
        for _, cargo in ipairs(container.transientCargo) do
          local add = 1
          local type = cargo.type
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.type == "cement" then
            add = cargo.slots
          end
          if cargo.type == "cash" then
            add = cargo.slots
          end
          if cargo.location.type == "facilityParkingspot" then
            pickUpAbleCargoByCargoType[cargo.type]  = pickUpAbleCargoByCargoType[type] + ((cargo.location.psPath == elem.psPath and (container.position - psPos):squaredLength() < 25*25) and add or 0)
          end
        end
      end
      local anyCargoPickUpAble = (pickUpAbleCargoByCargoType.parcel > 0 or pickUpAbleCargoByCargoType.fluid > 0 or pickUpAbleCargoByCargoType.dryBulk > 0 or pickUpAbleCargoByCargoType.cement > 0 or pickUpAbleCargoByCargoType.cash > 0)
      if pickUpAbleCargoByCargoType.parcel > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%sParcel%s pickup", pickUpAbleCargoByCargoType.parcel > 1 and ((pickUpAbleCargoByCargoType.parcel).." ") or "", pickUpAbleCargoByCargoType.parcel > 1 and "s" or "")
        })
      end
      if pickUpAbleCargoByCargoType.fluid > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%dL fluid pickup", pickUpAbleCargoByCargoType.fluid)
        })
      end
      if pickUpAbleCargoByCargoType.dryBulk > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%dL dry bulk pickup", pickUpAbleCargoByCargoType.dryBulk)
        })
      end    
      if pickUpAbleCargoByCargoType.cement > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%dL cement pickup", pickUpAbleCargoByCargoType.cement)
        })
      end
      if pickUpAbleCargoByCargoType.cash > 0 then
        table.insert(poiTemplate.props, {
          icon = "checkmark",
          keyLabel = string.format("%d cash pickup", pickUpAbleCargoByCargoType.cash)
        })
      end


      if elem.canInspectCargo then
        -- available cargo data and props
        local availableCargoCountByCargoType = {
          parcel = 0,
          fluid = 0,
          dryBulk = 0,
          cement = 0,
          cash = 0,
        }
        for _, cargo in ipairs(dParcelManager.getAllCargoForFacilityUnexpiredUndelivered(elem.facId)) do
          local add = 1
          local type = cargo.type
          if cargo.type == "fluid" then
            type = "fluid"
            add = cargo.slots
          end
          if cargo.type == "dryBulk" then
            add = cargo.slots
          end
          if cargo.type == "cement" then
            add = cargo.slots
          end
          if cargo.type == "cash" then
            add = cargo.slots
          end
          availableCargoCountByCargoType[type] = availableCargoCountByCargoType[type] + add
        end
        -- add storages
        local fac = dGenerator.getFacilityById(elem.facId)
        for materialType, storage in pairs(fac.materialStorages) do
          if storage.isProvider then
            local type = dGenerator.getMaterialsTemplatesById(materialType).type
            availableCargoCountByCargoType[type] = availableCargoCountByCargoType[type] + storage.storedVolume
          end
        end

        if availableCargoCountByCargoType.parcel > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%d parcel%s available", availableCargoCountByCargoType.parcel, availableCargoCountByCargoType.parcel ~= 1 and "s" or "")
          })
        end
        if availableCargoCountByCargoType.fluid > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%dL of fluid available", availableCargoCountByCargoType.fluid)
          })
        end
        if availableCargoCountByCargoType.dryBulk > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%dL of dry bulk available", availableCargoCountByCargoType.dryBulk)
          })
        end
        if availableCargoCountByCargoType.cement > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%dL of cement available", availableCargoCountByCargoType.cement)
          })
        end
        if availableCargoCountByCargoType.cash > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%d cash available", availableCargoCountByCargoType.cash)
          })
        end
        -- veh and trailer props
        local vehOffers, trailerOffers = {}, {}
        for _, offer in ipairs(dVehOfferManager.getAllOfferAtFacilityUnexpired(elem.facId)) do
          if offer.data.type == "vehicle" then
            table.insert(vehOffers, offer)
          end
          if offer.data.type == "trailer" then
            table.insert(trailerOffers, offer)
          end
        end
        if #vehOffers > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%d vehicle transport%s available", #vehOffers, #vehOffers ~= 1 and "s" or "")
          })
        end
        if #trailerOffers > 0 then
          table.insert(poiTemplate.props, {
            icon = "checkmark",
            keyLabel = string.format("%d trailer transport%s available", #trailerOffers, #trailerOffers ~= 1 and "s" or "")
          })
        end
      end

      -- make actual poi elemens

      if anyCargoDropOffable then
        local dropOffPoi = deepcopy(poiTemplate)
        dropOffPoi.heading = "Delivery Drop Off"
        dropOffPoi.buttonLabel = "Drop Off"
        dropOffPoi.buttonFun = function() guihooks.trigger('ChangeState', {state = 'cargoDropOff', params = {facilityId = elem.facId, parkingSpotPath = elem.psPath}}) end
        dropOffPoi.icon = "poi_dropoff_round"
        table.insert(activityData, dropOffPoi)
      end

      if anyCargoPickUpAble then
        local pickUpPoi = deepcopy(poiTemplate)
        pickUpPoi.heading = "Delivery Pick Up"
        pickUpPoi.buttonLabel = "Pick Up"
        pickUpPoi.buttonFun = function()
          dParcelManager.applyTransientMoves({type="facilityParkingspot", facId = elem.facId, psPath = elem.psPath})
          M.requestUpdateContainerWeights()
          gameplay_markerInteraction.closeViewDetailPrompt(true)
          Engine.Audio.playOnce('AudioGui', 'event:>UI>Missions>Info_Open')
          gameplay_rawPois.clear()
          dCargoScreen.onCargoPickedUp()
        end
        pickUpPoi.icon = "poi_dropoff_round"
        table.insert(activityData, pickUpPoi)
      end
      if elem.canInspectCargo then
        local inspectPoi = poiTemplate
        inspectPoi.heading = "Inspect Cargo"
        inspectPoi.buttonLabel = "Inspect"
        inspectPoi.buttonFun = function() dCargoScreen.enterCargoOverviewScreen(elem.facId, elem.psPath) end
        table.insert(activityData, inspectPoi)
      end


    end
  end
end
M.onActivityAcceptGatherData = onActivityAcceptGatherData


local deliveryActivity = {
  id = "deliveryMode",
  name = "Delivery Mode",

  vehicleModification = "warning",-- Slow and Fast Repairing, Changing and buying parts, tuning, painting
  vehicleSelling = "warning", --selling a vehicle
  vehicleStorage = "warning", --put vehicles into storage
  vehicleRepair = "warning",
  vehicleRetrieval = "allowed", --retrieve vehicles from storage

  vehicleShopping = "forbidden",

  interactRefuel = "allowed", --use the refueling POI to refuel vehicle
  interactMission = "warning", --use the mission POI to start a mission
  interactDelivery = "allowed", --use any delivery POI to start delivery mode

  recoveryFlipUpright = "allowed", --flip upright
  recoveryTowToRoad = "allowed", --tow to road
  recoveryTowToGarage = "warning", --tow to garage

  getLabel = function(tag)
    local penalty = -M.getDeliveryModePenalty().money
    if     tag == "vehicleModification" then
      return string.format("Modifying a vehicle will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "vehicleSelling" then
      return string.format("Selling a vehicle will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "vehicleStorage" then
      return string.format("Storing a vehicle will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "vehicleRepair" then
      return string.format("Repairing a vehicle will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "interactMission" then
      return string.format("Starting a Mission will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "recoveryTowToGarage" then
      return string.format("Towing to garage will end Delivery Mode (Penalty: %0.2f$)", penalty)
    elseif tag == "vehicleShopping" then
      return "Disabled during Delivery Mode."
    end
  end
}

local function onCheckPermission(tags, permissions)
  if not deliveryModeActive then return end
  for _, tag in ipairs(tags) do
    if deliveryActivity[tag] then
      table.insert(permissions, {permission = deliveryActivity[tag], label = deliveryActivity.getLabel(tag)})
      return
    end
  end
end

local function startDeliveryMode()
  if deliveryModeActive then return end
  log("I","","Delivery Mode Started.")
  deliveryModeActive = true
  gameplay_rawPois.clear()
  extensions.hook("onDeliveryModeStarted")
end

local function exitDeliveryMode()
  if not deliveryModeActive then return end
  log("I","","Delivery Mode Exited.")
  dParcelManager.clearTransientFlags()
  -- get all cargo currently in vehicles.
  local penalty = M.getDeliveryModePenalty()
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  if next(cargoInVehicles) then
    for _, cargo in ipairs(cargoInVehicles) do
      dParcelManager.changeCargoLocation(cargo.id, {type="deleted"})
    end
  end
  if penalty.money < 0 then
    guihooks.trigger("toastrMsg", {type="warning", title="Cargo abandoned", msg=string.format("Cargo was thrown away because delivery mode ended. Penalty: %0.2f$", -penalty.money)})
    log("I","",string.format("Penalty for abandoning cargo: %0.2f$", -penalty.money))
    career_modules_playerAttributes.addAttributes(penalty, {tags={"gameplay", "delivery","fine"}, label="Penalty for abandoning cargo."})
    Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  end

  dVehicleTasks.abandonAllVehicleTasks()

  dParcelManager.clearAllTransientMoves()

  deliveryModeActive = false
  gameplay_rawPois.clear()
  freeroam_bigMapMode.setNavFocus(nil)

  M.requestUpdateContainerWeights()
  dTasklist.clearAll()
  --core_gamestate.setGameState("career", "career")
  extensions.hook("onDeliveryModeStopped")
end

local function checkExitDeliveryMode()
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  local vehicleTasks = dVehicleTasks.getVehicleTasks()
  if not next(cargoInVehicles) and not next(vehicleTasks) then
    M.exitDeliveryMode()
  end
end

local function isAutomaticRouteEnabled()
  return loadData.settings.automaticRoute
end
M.isAutomaticRouteEnabled = isAutomaticRouteEnabled

local function setAutomaticRoute(enabled)
  loadData.settings.automaticRoute = enabled
  if enabled then
    career_modules_delivery_cargoScreen.setBestRoute()
  else
    core_groundMarkers.setPath(nil)
    freeroam_bigMapMode.resetRoute()
  end
  guihooks.trigger("automaticRouteSet", enabled)
end

local function setDetailedDropOff(enabled)
  loadData.settings.detailedDropOff = enabled
  guihooks.trigger("detailedDropOffSet", enabled)
end

-- Deactivate automatic route when setting a manual waypoint
local function onSetBigmapNavFocus()
  if M.isDeliveryModeActive() then
    setAutomaticRoute(false)
  end
end

local function setSetting(key, value)
  loadData.settings[key] = value
end

local function getSettings()
  return loadData.settings
end

M.setAutomaticRoute = setAutomaticRoute
M.setDetailedDropOff = setDetailedDropOff
M.onSetBigmapNavFocus = onSetBigmapNavFocus

M.setSetting = setSetting
M.getSettings = getSettings

M.startDeliveryMode = startDeliveryMode
M.exitDeliveryMode = exitDeliveryMode
M.checkExitDeliveryMode = checkExitDeliveryMode
M.isDeliveryModeActive = function() return deliveryModeActive end
M.getDeliveryModePenalty = function(onlyVehIdsAsKeys)
  local cargoInVehicles = dParcelManager.getAllCargoInVehicles(true)
  local penalty = {money = 0}
  if not onlyVehIdsAsKeys then
    local fine = dVehicleTasks.getFineForAbandonAllVehicleTasks()
    for attKey, amount in pairs(fine) do
      penalty[attKey] = (penalty[attKey] or 0) + amount
    end
  end

  if next(cargoInVehicles) then
    for _, cargo in ipairs(cargoInVehicles) do
      if (not onlyVehIdsAsKeys) or (cargo.location.vehId and onlyVehIdsAsKeys[cargo.location.vehId]) then
        local abandonFac = M.getDeliveryAbandonPenaltyFactor()
        local modFac = 0
        if cargo.modifiers then
          for _, mod in ipairs(cargo.modifiers) do
            modFac = modFac + (mod.abandonMultiplier or 0)
          end
        end
        if not cargo._transientMove then
          penalty.money = penalty.money - cargo.rewards.money * (abandonFac + modFac)
        end
        if cargo.organization and penalty[cargo.organization.."Reputation"] then
          penalty[cargo.organization.."Reputation"] = penalty[cargo.organization.."Reputation"] or 0
          penalty[cargo.organization.."Reputation"] = penalty[cargo.organization.."Reputation"] - math.ceil(cargo.rewards[cargo.organization.."Reputation"] or 0)
        end
      end
    end
  end
  return penalty
end

M.onCheckPermission = onCheckPermission

-- actions that stop delivery mode

M.onPartShoppingStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because shopping started.")
    M.exitDeliveryMode()
  end
end

M.onCareerPaintingStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because painting started.")
    M.exitDeliveryMode()
  end
end

M.onCareerTuningStarted = function()
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because tuning started.")
    M.exitDeliveryMode()
  end
end

M.onTeleportedToGarage = function(garageId, veh)
  if deliveryModeActive then
    log("I","","Stopped Delivery mode because towed to garage.")
    M.exitDeliveryMode()
  end
end

M.onAnyMissionChanged = function(change)
  if change == "started" then
    if deliveryModeActive then
      log("I","","Stopped Delivery mode because mission started.")
      M.exitDeliveryMode()
    end
  end
end

local function checkEndDeliveryModeForVehicle(vehId)
  if deliveryModeActive then
    -- TODO: this needs to check for cargo in vehicle containers, not just vehicle
    local penalty = M.getDeliveryModePenalty({[vehId] = true})
    local cargoInVehicle = dParcelManager.getAllCargoCustomFilter(function(cargo)
      if cargo.location.type == "vehicle" and cargo.location.vehId == vehId then
        return true
      end
      if cargo._transientMove and cargo.transientMove.targetLocation.vehId == vehId then
        return true
      end
    end)
    if next(cargoInVehicle) then
      for _, cargo in ipairs(cargoInVehicle) do
        dParcelManager.changeCargoLocation(cargo.id, {type="deleted"})
      end
      if penalty.money < 0 then
        guihooks.trigger("toastrMsg", {type="warning", title="Cargo abandoned", msg=string.format("Cargo was thrown away because vehicle was put into storage. Penalty: %0.2f$", -penalty.money)})
        log("I","",string.format("Penalty for abandoning cargo: %0.2f$", -penalty.money))
        career_modules_playerAttributes.addAttributes(penalty, {tags={"gameplay", "delivery","fine"}, label="Penalty for abandoning cargo."})
        Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
      end
    end
    checkExitDeliveryMode()
  end
end

M.onRepairInGarage = function(vehInfo, repairOption)
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(vehInfo.id)
  checkEndDeliveryModeForVehicle(vehId)
end

M.onInventoryPreRemoveVehicleObject = function(inventoryId, vehId)
  checkEndDeliveryModeForVehicle(vehId)
end

return M
