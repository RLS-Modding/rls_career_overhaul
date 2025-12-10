-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehicleTasks, dTasklist, dParcelMods, dVehOfferManager, dTutorial
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
  dTutorial = career_modules_delivery_tutorial
  step = util_stepHandler
end


-- Tutorial status cache
local tutorialStatusCache = {}
M.isCargoDeliveryTutorialActive = function()
  return false
end

M.isVehicleDeliveryTutorialActive = function()
  return false
end

M.isMaterialsDeliveryTutorialActive = function()

  return false
end

M.onPlayerAttributesChanged = function(change, reason)
  -- Clear tutorial status cache when delivery branch XP changes
  if change["logistics-delivery"] then
    tutorialStatusCache['logistics-delivery'] = nil
  end
  if change["logistics-vehicleDelivery"] then
    tutorialStatusCache['logistics-vehicleDelivery'] = nil
  end
  if change["logistics-materials"] then
    tutorialStatusCache['logistics-materials'] = nil
  end
end


local maxDistance = 20
local function currentOrNearbyVehicleHasContainer(type)
  local playerVehId = be:getPlayerVehicleID(0)
  local playerPosition = getPlayerVehicle(0) and getPlayerVehicle(0):getPosition() or core_camera.getPosition()

  local containers = dGeneral.getMostRecentCargoContainerData()
  for _, container in ipairs(containers) do
    local dist = (container.position - playerPosition):length()
    if (container.vehId == playerVehId or dist <= maxDistance) and container.attachmentStatus == "attached" and (type == nil or container.cargoTypesLookup[type]) then
      return true
    end
  end

  return false
end

local function currentVehicleHasTutorialCargo()
  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId then return false end

  local playerCargo = dParcelManager.getAllCargoInVehicles(true)
  for _, cargo in ipairs(playerCargo) do
    if cargo.location.vehId == playerVehId then
      local template = dGenerator.getParcelTemplateById(cargo.templateId)
      if template and template.isTutorialParcel then
        return true
      end
    end
  end

  return false
end

local function tutorialVehicleTakenOutOfFacility()
  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId then return false end

  -- Check if current vehicle is a tutorial vehicle
  local vehicleTasks = dVehicleTasks.getVehicleTasks()
  for _, task in ipairs(vehicleTasks) do
    if task.offer and task.offer.data and task.offer.data.isTutorialVehicle then
      return true
    end
  end

  return false
end

local function currentVehicleHasDryBulkContainer() return false end
local function currentVehicleHasTutorialMaterials() return false end

M.getTutorialInfo = function()
  local tutorialInfo = {
    parcel = {
      unlocked = true,
      isActive = M.isCargoDeliveryTutorialActive(),
      tasks = {},
    },
    vehicle = {
      unlocked = true,
      isActive = M.isVehicleDeliveryTutorialActive(),
      tasks = {},
    },
  }
  M.onCareerProgressPageGetTasklistData(tutorialInfo.parcel, "delivery-introduction")
  M.onCareerProgressPageGetTasklistData(tutorialInfo.vehicle, "vehicle-delivery-introduction")
  return tutorialInfo
end

M.onCareerProgressPageGetTasklistData = function(tasklistData, tasklistId)
  if tasklistId == "delivery-introduction" then
    local allFinished = not M.isCargoDeliveryTutorialActive()
    tasklistData.headerLabel = "Delivery Introduction"
    if allFinished then
      tasklistData.tasks = {
        {
          label = "Cargo Delivery Tutorial Completed",
          description = "You have completed the cargo delivery tutorial. You can now start delivering cargo and earn money and XP.",
          done = true
        },
      }
    else
      tasklistData.tasks = {
        {
          label = "Install a cargo container in your vehicle.",
          description = "Visit a garage and select 'Part Customization', then 'Cargo parts'.",
          done = allFinished or currentOrNearbyVehicleHasContainer("parcel")
        },
        {
          label = "Load the Tutorial Package into your vehicle.",
          description = "Inspect the cargo in front of the Belasco City Garage.",
          done = allFinished or currentVehicleHasTutorialCargo(),
        },
        {
          label = "Deliver cargo to the destination.",
          description = "Drop off the cargo at Jerry Riggs.",
          done = allFinished,
        },
      }
    end
  end
  if tasklistId == "vehicle-delivery-introduction" then
    local allFinished = not M.isVehicleDeliveryTutorialActive()
    tasklistData.headerLabel = "Vehicle Delivery Introduction"
    if allFinished then
      tasklistData.tasks = {
        {
          label = "Vehicle Delivery Tutorial Completed",
          description = "You have completed the vehicle delivery tutorial. You can now start delivering vehicles and earn money and XP.",
          done = true
        },
      }
    else
      tasklistData.tasks = {
        {
          label = "Bring out the tutorial vehicle from Belasco Auto.",
          description = "Visit the Belasco Auto delivery facility and select the tutorial vehicle under 'Car Jockey'.",
          done = allFinished or tutorialVehicleTakenOutOfFacility(),
        },
        {
          label = "Drive the vehicle to the destination.",
          description = "Drive the vehicle to the destination and drop it off.",
          done = allFinished,
        },
      }
    end
  end
  if tasklistId == "materials-introduction" then
    local allFinished = not M.isMaterialsDeliveryTutorialActive()
    tasklistData.headerLabel = "Materials Introduction"
    if allFinished then
      tasklistData.tasks = {
        {
          label = "Materials Delivery Tutorial Completed",
          description = "You have completed the materials delivery tutorial. You can now start delivering materials and earn money and XP.",
          done = true
        },
      }
    else
      tasklistData.tasks = {
        {
          label = "Install a dry bulk container in your vehicle.",
          description = "Visit a garage and select 'Part Customization', then 'Cargo parts'.",
          done = allFinished or currentOrNearbyVehicleHasContainer("dryBulk"),
        },
        {
          label = "Load the introduction materials into your vehicle.",
          description = "Inspect the materials at the Quarry facility.",
          done = allFinished or currentVehicleHasTutorialMaterials(),
        },
        {
          label = "Deliver materials to the destination.",
          description = "Drop off all of the materials at the Belasco City Construction Site.",
          done = allFinished,
        },
      }
    end
  end
end



return M