-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"util_stepHandler"}

local walkAwayRadius = 100
local comeBackRadius = 95
local walkAwayTimeLimit = 300
local walkAwayWarningTime = 60
local loanedVehiclesInfo = {}
local loanedInventoryIdToVehId = {}

local markedForSpawningLoaners = {}

local function markForSpawning(offer)
  if markedForSpawningLoaners[offer.id] then
    markedForSpawningLoaners[offer.id] = nil
  else
    markedForSpawningLoaners[offer.id] = offer
  end
end
M.markForSpawning = markForSpawning

local function unmarkAllForSpawning()
  markedForSpawningLoaners = {}
end
M.unmarkAllForSpawning = unmarkAllForSpawning

local vehicleAdded = false
local function onVehicleAdded(id)
  vehicleAdded = true
  local vehId = career_modules_inventory.getVehicleIdFromInventoryId(id)
  if vehId then
    local vehs = career_modules_inventory.getVehicles()
    local info = vehs and vehs[id]
    if info and info.loanType == "work" then
      loanedInventoryIdToVehId[id] = vehId
    end
  end
end

local function spawnAllOffers()
  if not next(markedForSpawningLoaners) then return end
  vehicleAdded = false
  local sequence = {
    -- fade to black
    util_stepHandler.makeStepFadeToBlack(),
  }
  for id, offer in pairs(markedForSpawningLoaners) do
    -- spawn vehicle and trigger initialization
    local options = {model = offer.model, config = offer.config, autoEnterVehicle = false}
    local fac = freeroam_facilities.getFacility(offer.sourceFacility.type, offer.sourceFacility.id)
    table.insert(sequence, util_stepHandler.makeStepSpawnVehicle(options,
      function(step, vehId)
        local vehObj = scenetree.findObjectById(vehId)
        core_vehicleBridge.executeAction(vehObj, 'initPartConditions', {}, offer.vehMileage or 0, 1, 1)
        core_vehicleBridge.requestValue(vehObj,
          function(res)
            local vehModel = core_vehicles.getModel(vehObj:getField('JBeam','0')).model
            local spots = vehModel.Type == "Trailer" and fac.loanerTrailerSpots or fac.loanerNonTrailerSpots
            local bestParkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehId, spots)
            if bestParkingSpot then
              bestParkingSpot:moveResetVehicleTo(vehObj:getID(), nil, false, nil, nil, true, nil, false)
              offer.vehPos = bestParkingSpot.pos
            end

            local inventoryId = career_modules_inventory.addVehicle(vehId, nil, {owned = false})
            -- callback for inventory ID
            local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
            vehInfo.owningOrganization = fac.associatedOrganization
            vehInfo.loanType = offer.loanType
            loanedInventoryIdToVehId[inventoryId] = vehId
            --callback end
          end
          , 'ping')
      end
      )
    )
    table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
      function() return vehicleAdded end
    ))
  end
  table.insert(sequence, util_stepHandler.makeStepReturnTrueFunction(
      function()
        local _, offer = next(markedForSpawningLoaners)
        if offer.vehPos then
          local camDir = offer.vehPos - getPlayerVehicle(0):getPosition()
          if gameplay_walk.isWalking() then
            gameplay_walk.setRot(camDir)
          end
        end
        markedForSpawningLoaners = {}
        return true
      end
    )
  )
  table.insert(sequence, util_stepHandler.makeStepFadeFromBlack())

  -- start sequence
  util_stepHandler.startStepSequence(sequence)
end
M.spawnAllOffers = spawnAllOffers

local function returnVehicleActual(inventoryId)
  local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
  if career_modules_insurance.inventoryVehNeedsRepair(inventoryId) and vehInfo.loanType == "work" and vehInfo.owningOrganization then
    local fine = {}
    fine[vehInfo.owningOrganization .. "Reputation"] = career_modules_reputation.getValueForEvent("returnLoanerDamaged")
    career_modules_playerAttributes.addAttributes(fine, {tags={"fine"}, label=("Reputation cost for damaging the loaned vehicle")})
    guihooks.trigger("toastrMsg", {type="warning", label = "loanReturnedDamaged", title="Loaner returned damaged", msg="Lost reputation due to returning a damaged loaned vehicle."})
  end
  career_modules_inventory.removeVehicle(inventoryId)
end

local function returnVehicle(inventoryId, callback)
  if career_modules_inventory.getVehicleIdFromInventoryId(inventoryId) then
    career_modules_inventory.updatePartConditions(nil, inventoryId,
    function()
      loanedInventoryIdToVehId[inventoryId] = nil
      returnVehicleActual(inventoryId)
      if callback then callback() end
    end)
  else
    loanedInventoryIdToVehId[inventoryId] = nil
    returnVehicleActual(inventoryId)
    if callback then callback() end
  end
end

local function getLoanedVehicles()
  local result = {}
  for inventoryId, vehInfo in pairs(career_modules_inventory.getVehicles()) do
    if vehInfo.owningOrganization then
      local veh = deepcopy(vehInfo)
      veh.thumbnail = career_modules_inventory.getVehicleThumbnail(veh.id)
      table.insert(result, veh)
    end
  end
  return result
end

local function getLoanedVehiclesByOrg(organizationId)
  local result = {}
  for _, vehInfo in ipairs(getLoanedVehicles()) do
    if organizationId == vehInfo.owningOrganization then
      table.insert(result, vehInfo)
    end
  end
  return result
end

local vehPos = vec3()
local playerPos = vec3()
local function onUpdate(dtReal, dtSim, dtRaw)
  for inventoryId, vehId in pairs(loanedInventoryIdToVehId) do
    if be:getObjectByID(vehId) then
      vehPos:set(be:getObjectPositionXYZ(vehId))
      playerPos:set(be:getObjectPositionXYZ(be:getPlayerVehicleID(0)))
      if not loanedVehiclesInfo[inventoryId] and playerPos:distance(vehPos) > walkAwayRadius then
        ui_message(string.format("You are leaving a loaned vehicle behind. After %d seconds, it will be returned to the owner.", walkAwayTimeLimit), 5, "loanedVehicleTime")
        loanedVehiclesInfo[inventoryId] = {time = walkAwayTimeLimit}
        break
      end
    end
  end

  for inventoryId, loanedVehInfo in pairs(loanedVehiclesInfo) do
    local vehId = loanedInventoryIdToVehId[inventoryId]
    if not vehId or not be:getObjectByID(vehId) then
      loanedVehiclesInfo[inventoryId] = nil
      break
    end
    vehPos:set(be:getObjectPositionXYZ(vehId))
    playerPos:set(be:getObjectPositionXYZ(be:getPlayerVehicleID(0)))

    if playerPos:distance(vehPos) < comeBackRadius then
      loanedVehiclesInfo[inventoryId] = nil
      break
    end

    loanedVehInfo.time = loanedVehInfo.time - dtSim

    if loanedVehInfo.time < 0 then
      returnVehicle(inventoryId)
      break
    end

    if not loanedVehInfo.warningShown and loanedVehInfo.time < walkAwayWarningTime then
      ui_message(string.format("After %d more seconds of not returning to the loaned vehicle, it will be returned to the owner.", walkAwayWarningTime), 5, "loanedVehicleTime")
      loanedVehInfo.warningShown = true
      break
    end
  end
end

local function onVehicleRemoved(inventoryId)
  loanedInventoryIdToVehId[inventoryId] = nil
  loanedVehiclesInfo[inventoryId] = nil
end

local function refreshLoanedMapping()
  table.clear(loanedInventoryIdToVehId)
  local map = career_modules_inventory.getMapInventoryIdToVehId()
  local vehs = career_modules_inventory.getVehicles()
  for invId, vehId in pairs(map) do
    local info = vehs and vehs[invId]
    if info and info.loanType == "work" then
      loanedInventoryIdToVehId[invId] = vehId
    end
  end
end

local function onCareerModulesActivated()
  refreshLoanedMapping()
end

local function getNumberOfLoanedNonTrailers(organizationId)
  local counter = 0
  for inventoryId, vehicleInfo in pairs(career_modules_inventory.getVehicles()) do
    if vehicleInfo.owningOrganization == organizationId then
      local _, configFilename, ext = path.splitWithoutExt(vehicleInfo.config.partConfigFilename)
      local configInfo = core_vehicles.getConfig(vehicleInfo.model, configFilename)
      if not (configInfo.aggregates.Type and configInfo.aggregates.Type.Trailer) then
        counter = counter + 1
      end
    end
  end
  return counter
end

local function getLoaningOrgsOfVehicle(vehId)
  local res = {}
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
  local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
  if vehInfo and vehInfo.owningOrganization then
    res[vehInfo.owningOrganization] = true
  end

  local pullingVehicleId = core_trailerRespawn.getAttachedNonTrailer(vehId)
  local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(pullingVehicleId)
  local vehInfo = career_modules_inventory.getVehicles()[inventoryId]
  if vehInfo and vehInfo.owningOrganization then
    res[vehInfo.owningOrganization] = true
  end
  return res
end

-- Function to parse ISO 8601 date-time string
local function parse_iso8601(datetime)
  local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z"
  local year, month, day, hour, min, sec = datetime:match(pattern)

  -- Convert to Unix timestamp
  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
    isdst = false
  })
end

-- Function to calculate time difference
local function time_since(datetime)
  local past = parse_iso8601(datetime)
  local now = os.time(os.date("!*t"))
  local diff = os.difftime(now, past)
  return diff
end

local function getNumberOfLoanersToBeSpawned()
  local numberNonTrailers, numberTrailers = 0, 0
  for id, offer in pairs(markedForSpawningLoaners) do
    local configInfo = core_vehicles.getConfig(offer.model, offer.config)
    if configInfo.aggregates.Type and configInfo.aggregates.Type.Trailer then
      numberTrailers = numberTrailers + 1
    else
      numberNonTrailers = numberNonTrailers + 1
    end
  end
  return numberNonTrailers, numberTrailers
end

local function getRentalMileage(rentalVehicleInfo, organization)
  if rentalVehicleInfo.mileages then
    if rentalVehicleInfo.mileages[tostring(organization.reputation.level)] then
      return rentalVehicleInfo.mileages[tostring(organization.reputation.level)]
    else
      return select(2, next(rentalVehicleInfo.mileages))
    end
  end
  if rentalVehicleInfo.mileage then
    return rentalVehicleInfo.mileage
  end
  return 0
end

local function formatSpawnedLoanersForUi()
  local result = {}
  for _, vehInfo in ipairs(getLoanedVehicles()) do
    local veh = deepcopy(vehInfo)
    local organization = freeroam_organizations.getOrganization(veh.owningOrganization)
    local _, configFilename, ext = path.splitWithoutExt(vehInfo.config.partConfigFilename)
    local configInfo = core_vehicles.getConfig(vehInfo.model, configFilename)

    veh.loanerCut = organization.reputationLevels[organization.reputation.level+2].loanerCut
    veh.name = veh.niceName
    veh.vehMileage = career_modules_valueCalculator.getVehicleMileageById(veh.id)
    veh.organizationName = organization.name
    veh.vehOfferType = (configInfo.aggregates.Type.Trailer) and "trailer" or "vehicle"
    veh.enabled = true
    veh.isSpawnedLoaner = true

    if configInfo.capacity then
      veh.capacity = {}
      for _, cap in ipairs(configInfo.capacity) do
        if cap.type == "fluid" then
          table.insert(veh.capacity, {
            icon = career_modules_delivery_parcelMods.getModifierIcon(cap.type),
            labelShort = string.format("%dL", cap.amount),
            labelLong = string.format("Fluids: %dL", cap.amount),
          })
        end
      end
    end

    table.insert(result, veh)
  end
  return result
end

local function formatLoanerOfferForUi(facility)
  local organizationId = facility.associatedOrganization
  local organization = freeroam_organizations.getOrganization(organizationId)
  if not organization then return nil end
  local ret = {}

  local saveSlot, savePath = career_saveSystem.getCurrentSaveSlot()
  local saveData = (savePath and jsonReadFile(savePath .. "/info.json")) or {}
  local secondsSinceSaveFileCreation = time_since(saveData.creationDate)

  for idx, rentalVehicleInfo in ipairs(organization.loanableVehicles or {}) do
    local configInfo = core_vehicles.getConfig(rentalVehicleInfo.model, rentalVehicleInfo.config)
    local hasFreeParkingSpot = false
    local isTrailer = configInfo.aggregates.Type and configInfo.aggregates.Type.Trailer
    local spots = isTrailer and facility.loanerTrailerSpots or facility.loanerNonTrailerSpots

    local numberNonTrailersToBeSpawned, numberTrailersToBeSpawned = getNumberOfLoanersToBeSpawned()
    local counterSpawnedVehiclesOfSameType = isTrailer and numberTrailersToBeSpawned or numberNonTrailersToBeSpawned

    for _, parkingSpot in ipairs(spots) do
      if not parkingSpot:hasAnyVehicles() then
        counterSpawnedVehiclesOfSameType = counterSpawnedVehiclesOfSameType - 1
        if counterSpawnedVehiclesOfSameType < 0 then
          hasFreeParkingSpot = true
        end
      end
    end

    local disableReason, unlockInfo
    local enabled = true
    if not hasFreeParkingSpot then
      enabled = false
      disableReason = {
        type = "noSpace",
        label  = "There are no free parking spots for loaner vehicles of this type.",
      }
    end

    if not isTrailer and (getNumberOfLoanedNonTrailers(organizationId) + numberNonTrailersToBeSpawned) > 0 then
      enabled = false
      disableReason = {
        type = "limit",
        label = "You already have a loaned vehicle of that type from this organization.",
      }
    end

    if rentalVehicleInfo.reputationLvl > organization.reputation.level then
      enabled = false
      disableReason = {
        type = "locked", icon = "peopleOutline", level = rentalVehicleInfo.reputationLvl,
        label = string.format("Requires Reputation '%s' with %s", organization.reputationLevels[rentalVehicleInfo.reputationLvl+2].label, organization.name)
      }
      unlockInfo = {
        type = "minLevel", icon = "peopleOutline", longLabel = string.format("Requires Reputation '%s' with %s", organization.reputationLevels[rentalVehicleInfo.reputationLvl+2].label, organization.name), shortLabel = string.format("%s (lvl %d)", organization.reputationLevels[rentalVehicleInfo.reputationLvl+2].label, rentalVehicleInfo.reputationLvl)
      }
    end

    if rentalVehicleInfo.deliveryLvl > career_branches.getBranchLevel('delivery') then
      enabled = false
      disableReason = {
        type = "locked", icon = "cardboardBox", level = rentalVehicleInfo.deliveryLvl,
        label = string.format("Requires Skill 'Cargo Delivery' lvl %d", rentalVehicleInfo.deliveryLvl )
      }
      unlockInfo = {
        type = "minLevel", icon = "cardboardBox", longLabel = string.format("Requires Skill 'Cargo Delivery' lvl %d", rentalVehicleInfo.deliveryLvl ), shortLabel = string.format("lvl %d", rentalVehicleInfo.deliveryLvl )
      }
    end

    local id = string.format("%s-%d", organizationId, idx)

    --ignore enable state when already bringin out this loaner
    if markedForSpawningLoaners[id] then
      enabled = true
      disableReason = nil
    end
    local item = {
      id = id,
      model = rentalVehicleInfo.model,
      config = rentalVehicleInfo.config,
      loanerCut = organization.reputationLevels[organization.reputation.level+2].loanerCut,
      vehOfferType = (configInfo.aggregates.Type.Trailer) and "trailer" or "vehicle",
      name = configInfo.Name,
      vehMileage = getRentalMileage(rentalVehicleInfo, organization) + (5.8 + 5.8 * ((math.random() * 0.2) - 0.1)) * secondsSinceSaveFileCreation, -- this roughly equates to adding 500km per day since the save was created
      thumbnail = configInfo.preview or '/ui/images/appDefault.png',
      connector = "ConName",
      reputationLvl = rentalVehicleInfo.reputationLvl,
      enabled = enabled,
      disableReason = disableReason,
      unlockInfo = unlockInfo,
      organizationName = organization.name,
      capacity = rentalVehicleInfo.capacity or {},
      sourceFacility = {type = "deliveryProvider", id = facility.id},
      loanType="work",
      spawnWhenCommitingCargo = markedForSpawningLoaners[id] and true or false,
    }
    if configInfo.capacity then
      item.capacity = {}
      for _, cap in ipairs(configInfo.capacity) do
        if cap.type == "fluid" then
          table.insert(item.capacity, {
            icon = career_modules_delivery_parcelMods.getModifierIcon(cap.type),
            labelShort = string.format("%dL", cap.amount),
            labelLong = string.format("Fluids: %dL", cap.amount),
          })
        end
      end
    end

    if enabled then
      local repLabel = string.format("%s (lvl %d)", organization.reputationLevels[rentalVehicleInfo.reputationLvl+2].label, rentalVehicleInfo.reputationLvl)
      item.unlockInfo = {
        type = "minLevel", icon = "peopleOutline", longLabel = string.format("Requires reputation: %s",repLabel), shortLabel = repLabel
      }
    end

    table.insert(ret, item)
  end
  return ret
end

M.spawnAndLoanVehicle = spawnAndLoanVehicle
M.returnVehicle = returnVehicle
M.getLoanedVehiclesByOrg = getLoanedVehiclesByOrg
M.formatLoanerOfferForUi = formatLoanerOfferForUi
M.formatSpawnedLoanersForUi = formatSpawnedLoanersForUi
M.getLoaningOrgsOfVehicle = getLoaningOrgsOfVehicle

M.onUpdate = onUpdate
M.onVehicleAdded = onVehicleAdded
M.onVehicleRemoved = onVehicleRemoved
M.onCareerModulesActivated = onCareerModulesActivated

return M
