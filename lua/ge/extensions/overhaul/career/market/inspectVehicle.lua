-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/inspectVehicle.lua (BeamNG 0.40).
-- Owns the inspection and test-drive lifetime of one listed car, including its route and maintenance previews.
-- Read config/state, tethers and travel, then inspection steps, lifecycle and the public hooks.

local M = {}

local capabilities = require("overhaul/lib/platform/capabilities")

-- Config ------------------------------------------------------------------------------------------

local config = {
  LEAVE_SALE_DIST = 25, -- the car is released once the player drives this far from it
  VEH_TO_SALE_POS_DIST = 10, -- the car moved this far from its bay cancels the sale
  ARRIVE_TO_VEH_INSPECTION_DIST = 20,
  PURCHASE_TETHER_DIST = 3,
  TEST_DRIVE_TIME = 60,
}

-- State -------------------------------------------------------------------------------------------

local state = {
  didTestDrive = nil,
  testDriveDamageDetected = false,
  leavingSale = false,
  leaveSaleTether = nil,
  purchaseTether = nil,
  testDriveInfo = nil,
  testDriveVehInfo = nil,
  timeLeftToInspectVehicle = 0,
  hasPlayerArrivedToVehInspection = false,
  checkTestDriveVehMovedFlag = false,
}

-- Reused for every distance check so the per-frame update allocates nothing.
local scratchDir = vec3()

-- Inspection routes and previews ------------------------------------------------------------------

local inspectSeam = {}
local inspectionRouteTarget
local inspectionRouteToken

local function copyRouteTarget(target)
  if not target then return nil end
  return vec3(target.x, target.y, target.z)
end

function inspectSeam.setInspectionRoute(target)
  local routeTarget = copyRouteTarget(target)
  if not routeTarget then
    return false
  end
  inspectionRouteToken = core_groundMarkers.setPath(routeTarget)
  inspectionRouteTarget = routeTarget
  capabilities.get("groundMarkerOwnership").claim("inspectVehicle")
  return true
end

-- Navigation is shared by all career activities: clear only our own route, not one set since.
function inspectSeam.clearInspectionRoute()
  capabilities.get("groundMarkerOwnership").release("inspectVehicle")
  local ownedTarget = inspectionRouteTarget
  local ownedToken = inspectionRouteToken
  inspectionRouteTarget = nil
  inspectionRouteToken = nil
  if not ownedTarget then return false end

  local currentTarget = core_groundMarkers.getTargetPos()
  if not currentTarget then return false end

  if (currentTarget - ownedTarget):length() > 1 then return false end

  -- The ownership patch adds tokens; stock groundMarkers only has setPath.
  if core_groundMarkers.clearOwnedPath then
    return core_groundMarkers.clearOwnedPath(ownedToken)
  end
  core_groundMarkers.setPath(nil)
  return true
end


-- The inspected car's tyres and maintenance state preview its listing.
function inspectSeam.registerInspection(newVeh, vehicleInfo)
  overhaul_career_maintenance_tireSystem.registerInspectionVehicle(newVeh:getID(), vehicleInfo)
  overhaul_vehicles_maintenanceBridge.registerInspectionVehicle(newVeh:getID(), vehicleInfo)
end

-- Also runs from vehicle-destroyed and mission hooks during teardown, so the owners may be gone.
function inspectSeam.unregisterInspection(inspectedVehId)
  if inspectedVehId and overhaul_career_maintenance_tireSystem then
    overhaul_career_maintenance_tireSystem.unregisterInspectionVehicle(inspectedVehId)
  end
  if inspectedVehId and overhaul_vehicles_maintenanceBridge then
    overhaul_vehicles_maintenanceBridge.unregisterInspectionVehicle(inspectedVehId)
  end
end

-- Marker interaction is per-level and may be gone when reset runs during mission teardown.
-- Walk mode only dismisses the prompt on an "out" transition; deleting the POI in place leaves it stuck.
function inspectSeam.closeDetailPrompt()
  if overhaul_integration_services_markerInteraction then
    overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true)
  end
end

-- Flagged sale cars stay in the world until deletion; stop walk mode offering them meanwhile.
function inspectSeam.retireSaleVehicle(despawnPreviousVehMode, vehId)
  if despawnPreviousVehMode ~= "dontDespawn" then
    local veh = getObjectByID(vehId)
    if veh then
      veh.playerUsable = false
    end
  end
end

-- Online and expired listings cannot be inspected. atSeller defaults to the open shop's seller.
function inspectSeam.screenInspection(vehicleInfo, atSeller)
  if not vehicleInfo then return false end
  if atSeller == nil then
    atSeller = vehicleInfo.sellerId == overhaul_career_market_vehicleShopping.getCurrentSellerId()
  end
  if overhaul_career_market_vehicleShopping.isOnlineSellerId(vehicleInfo.sellerId) then
    return false, atSeller
  end
  return true, atSeller
end

-- The previous leave job resets inspection state after its damage check.
function inspectSeam.waitForPreviousSale(job, isLeaving)
  local waited = 0
  while isLeaving() and waited < 6 do
    job.sleep(0.05)
    waited = waited + 0.05
  end
end

-- Insurance settles the test-drive damage; wait for it, 5 s at most.
function inspectSeam.checkTestDriveDamage(job, vehId)
  local damageCheckDone = false
  overhaul_career_repair_insurance.handleTestDriveEndDamage(vehId, function()
    damageCheckDone = true
  end)
  local timeout = 5
  while not damageCheckDone and timeout > 0 do
    job.sleep(0.05)
    timeout = timeout - 0.05
  end
end

-- Taxi to the inspected car, beside it and facing it. False when the taxi was refused (e.g. unpaid).
function inspectSeam.travelToInspection(parkingSpot, vehToInspect)
  local spawnPos = parkingSpot.pos
  if parkingSpot.rot then
    local side = quat(parkingSpot.rot) * vec3(2.5, 0, 0)
    side.z = 0
    spawnPos = parkingSpot.pos + side
  end
  local lookAt = vehToInspect:getPosition() or parkingSpot.pos
  return overhaul_career_garage_quickTravel.quickTravelToPos(spawnPos, true, nil, parkingSpot.rot, lookAt)
end

function inspectSeam.refreshTestDriveCharge(testDriveVehInfo)
  local insurance = overhaul_career_repair_insurance
  if testDriveVehInfo then
    insurance.refreshTestDriveChargeEstimate(testDriveVehInfo.vehId)
  end
end

-- Tethers and timers ------------------------------------------------------------------------------

local function setTimeToInspectVehicle()
  local pathLength = core_groundMarkers.getPathLength()
  local timeToInspectVehicle = pathLength / 5
  state.timeLeftToInspectVehicle = math.ceil(timeToInspectVehicle / 60) * 60
end

-- Non-player cars have no tether, so the bay check is done in the per-frame update instead.
local function addVehTetherToSalePos()
  state.checkTestDriveVehMovedFlag = true
end

local function removeVehTetherToSalePos()
  state.checkTestDriveVehMovedFlag = false
end

local function addSaleTether()
  state.leaveSaleTether = overhaul_career_maintenance_tether.startVehicleTether(state.testDriveVehInfo.vehId, config.LEAVE_SALE_DIST, false, function()
    M.leaveSaleCallback("flagForDeletion", true, true)
  end)
end

local function removeSaleTether()
  if state.leaveSaleTether then
    overhaul_career_maintenance_tether.removeTether(state.leaveSaleTether)
    state.leaveSaleTether = nil
  end
end

local function openPurchaseMenuWithTether(shopId)
  overhaul_career_market_vehicleShopping.openPurchaseMenu("inspect", shopId)
  local playerVeh = getPlayerVehicle(0)
  if not playerVeh then
    log("W", "inspectVehicle", "no player vehicle when opening purchase menu; menu will not be tethered")
    return
  end
  overhaul_career_maintenance_tether.removeTether(state.purchaseTether)
  state.purchaseTether = overhaul_career_maintenance_tether.startSphereTether(playerVeh:getPosition(), config.PURCHASE_TETHER_DIST, function() overhaul_career_career.closeAllMenus() end)
end

-- Clears every inspection field; the seam is told which car it no longer owns.
local function resetInspectionData()
  local inspectedVehId = state.testDriveVehInfo and state.testDriveVehInfo.vehId or nil
  state.didTestDrive = false
  state.testDriveDamageDetected = false
  state.leavingSale = false
  state.timeLeftToInspectVehicle = 0
  state.hasPlayerArrivedToVehInspection = false
  state.testDriveInfo = nil
  state.testDriveVehInfo = nil
  inspectSeam.unregisterInspection(inspectedVehId)

  removeSaleTether()
  removeVehTetherToSalePos()
  overhaul_career_maintenance_tether.removeTether(state.purchaseTether)
  state.purchaseTether = nil

  inspectSeam.clearInspectionRoute() -- only while the inspection route is still the active one

  gameplay_rawPois.clear() -- trigger rawPois to be updated
  inspectSeam.closeDetailPrompt()
end

-- Spawning ----------------------------------------------------------------------------------------

local function spawnVehicle(shopId)
  local vehicleInfo = overhaul_career_market_vehicleShopping.getVehicleInfoByShopId(shopId)
  if not vehicleInfo then return nil end -- the listing expired
  local spawnOptions = {}
  spawnOptions.config = vehicleInfo.key
  spawnOptions.autoEnterVehicle = false
  local newVeh = core_vehicles.spawnNewVehicle(vehicleInfo.model_key, spawnOptions)
  if newVeh then
    core_vehicleBridge.executeAction(newVeh, 'setIgnitionLevel', 0)
    core_vehicleBridge.executeAction(newVeh, 'setFreeze', true)
    local conditionMileage = vehicleInfo.wearMileage or vehicleInfo.Mileage -- wear mileage, not the listed one
    newVeh:queueLuaCommand(string.format("partCondition.initConditions(nil, %d, nil, %f)", conditionMileage, overhaul_career_market_vehicleShopping.getVisualValueFromMileage(conditionMileage)))
    inspectSeam.registerInspection(newVeh, vehicleInfo)
  end
  return newVeh
end

local function showVehicle(vehicleInfo)
  if not vehicleInfo then return end
  local vehObj = spawnVehicle(vehicleInfo.shopId)
  if not vehObj then
    log("E", "inspectVehicle", "Failed to spawn vehicle for inspection (shopId=" .. tostring(vehicleInfo.shopId) .. ")")
    return
  end
  state.testDriveVehInfo = {shopId = vehicleInfo.shopId, vehId = vehObj:getID(), name = vehicleInfo.Brand .. " " .. vehicleInfo.Name, value = vehicleInfo.Value}

  return vehObj
end

-- Drive parameters --------------------------------------------------------------------------------

-- The route is the one whose parking spot matches the spot the car was placed in.
local function routeForParkingSpot(dealership, parkingSpot)
  local route
  for _, parkingSpotRoute in pairs(dealership.testDrive.parkingSpotRoutes or {}) do
    if parkingSpotRoute.parkingSpotName == parkingSpot.name then
      route = parkingSpotRoute.route
    end
  end
  return route
end

local function dealershipTestDriveInfo(dealership, parkingSpot)
  local info = {
    timeLimit = config.TEST_DRIVE_TIME,
    areaLimit = dealership.testDrive.areaLimit,
    abandonFees = dealership.testDrive.abandonFees or 0,
    route = routeForParkingSpot(dealership, parkingSpot),
    dealershipName = _tr(dealership.name),
    dealershipPreview = dealership.preview,
  }
  if dealership.testDrive.enableEndParkingSpot then
    info.endParkingSpot = parkingSpot
  end
  return info
end

local function defineTestDriveParameters(vehicleInfo, parkingSpot, doesThePlayerHaveToDriveThere)
  if vehicleInfo.sellerId == "private" then
    state.testDriveInfo = {
      timeLimit = config.TEST_DRIVE_TIME,
      abandonFees = 0
    }
  else
    local dealership = overhaul_world_facilities.getDealership(vehicleInfo.sellerId)
    if dealership.testDrive then -- dealerships must always have testDrive rules
      state.testDriveInfo = dealershipTestDriveInfo(dealership, parkingSpot)
    else
      state.testDriveInfo = {}
      log('W', 'testDrive', "Dealership : '" .. dealership.name .. "' doesn't have any 'testDriveRules' which shouldn't be possible. At least one constraint has to be given")
    end
  end

  state.testDriveInfo.vehicleInfo = vehicleInfo
  state.testDriveInfo.startParkingSpot = parkingSpot
  state.testDriveInfo.doesThePlayerHaveToDriveThere = doesThePlayerHaveToDriveThere
end

local function turnTowardsPos(pos)
  core_vehicleBridge.requestValue(getPlayerVehicle(0), function()
    gameplay_walk.setRot(pos - getPlayerVehicle(0):getPosition())
  end, 'ping')
end

-- Leaving a sale -----------------------------------------------------------------------------------

-- Fills the optional arguments of leaveSaleCallback; false stays false, only nil takes the default.
local function leaveSaleOptions(despawnPreviousVehMode, freezePreviousVeh, checkDamage, defaultLeaveMessage)
  if despawnPreviousVehMode == nil then despawnPreviousVehMode = "dontDespawn" end
  if freezePreviousVeh == nil then freezePreviousVeh = true end
  if checkDamage == nil then checkDamage = true end
  if defaultLeaveMessage == nil then defaultLeaveMessage = _tr("ui.career.inspectVehicle.message.leftSale") end
  return despawnPreviousVehMode, freezePreviousVeh, checkDamage, defaultLeaveMessage
end

local function announceSaleLeft(defaultLeaveMessage)
  if overhaul_career_market_testDrive.isActive() then
    overhaul_career_market_testDrive.abandonTestDrive()
  elseif not dontShowLeaveSaleMessage then
    ui_message(defaultLeaveMessage, '4', 'testDriveAbandoned')
  end
end

local function disposeSaleVehicle(despawnPreviousVehMode, vehId, freezePreviousVeh)
  if despawnPreviousVehMode == "despawn" then
    local veh = getObjectByID(vehId)
    if veh then
      veh:delete()
    end
    return
  end
  if despawnPreviousVehMode == "flagForDeletion" then
    overhaul_career_garage_vehicleDeletionService.flagForDeletion(vehId)
  end
  local veh = getObjectByID(vehId)
  if veh then
    core_vehicleBridge.executeAction(veh, 'setFreeze', freezePreviousVeh)
  end
end

local function runLeaveSaleJob(job, despawnPreviousVehMode, vehId, freezePreviousVeh, checkDamage, defaultLeaveMessage)
  job.sleep(0.1)
  overhaul_career_career.closeAllMenus()
  announceSaleLeft(defaultLeaveMessage)

  if state.didTestDrive and checkDamage then
    inspectSeam.checkTestDriveDamage(job, vehId) -- insurance settles test-drive damage
  end

  disposeSaleVehicle(despawnPreviousVehMode, vehId, freezePreviousVeh)
  resetInspectionData()
end

local function leaveSaleCallback(despawnPreviousVehMode, freezePreviousVeh, checkDamage, defaultLeaveMessage)
  despawnPreviousVehMode, freezePreviousVeh, checkDamage, defaultLeaveMessage =
    leaveSaleOptions(despawnPreviousVehMode, freezePreviousVeh, checkDamage, defaultLeaveMessage)
  if not state.testDriveVehInfo then return end
  -- Latch before the leave job starts so duplicate calls cannot charge damage twice.
  if state.leavingSale then return end
  state.leavingSale = true

  -- keep the id here: the job runs after resetInspectionData may have cleared the state
  local vehId = state.testDriveVehInfo.vehId

  inspectSeam.retireSaleVehicle(despawnPreviousVehMode, vehId)
  -- Dismiss immediately; resetInspectionData also closes, but that runs after the job sleep.
  inspectSeam.closeDetailPrompt()

  core_jobsystem.create(function(job)
    runLeaveSaleJob(job, despawnPreviousVehMode, vehId, freezePreviousVeh, checkDamage, defaultLeaveMessage)
  end, 1)
end

-- Starting an inspection --------------------------------------------------------------------------

-- A previous sale is released first; the sleep lets its car despawn before the next one spawns.
local function clearPreviousSale(job)
  if not state.testDriveInfo then return end
  leaveSaleCallback("despawn")
  job.sleep(0.35)
  inspectSeam.waitForPreviousSale(job, function() return state.leavingSale end)
end

-- Private sellers have a fixed spot, and the player drives there unless they were teleported.
local function findPrivateSaleSpot(vehicleInfo, teleportToVehicle)
  local parkingSpot = overhaul_integration_services_parking.getParkingSpots().byName[vehicleInfo.parkingSpotName]
  return parkingSpot, not teleportToVehicle
end

-- Dealership cars are walked to when the seller is the one showing them and the player is not teleported.
local function findDealershipSaleSpot(vehicleInfo, vehToInspect, teleportToVehicle, atSeller)
  local dealership = overhaul_world_facilities.getDealership(vehicleInfo.sellerId)
  local parkingSpots = overhaul_world_facilities.getParkingSpotsForFacility(dealership)
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehToInspect:getID(), parkingSpots)

  if atSeller and parkingSpot then
    gameplay_walk.setWalkingMode(true)
    if not teleportToVehicle then turnTowardsPos(parkingSpot.pos) end
    return parkingSpot, false
  end
  return parkingSpot, not teleportToVehicle
end

local function findInspectionSpot(vehicleInfo, vehToInspect, teleportToVehicle, atSeller)
  if vehicleInfo.sellerId == "private" then
    return findPrivateSaleSpot(vehicleInfo, teleportToVehicle)
  end
  return findDealershipSaleSpot(vehicleInfo, vehToInspect, teleportToVehicle, atSeller)
end

-- Cars already in the bay are moved out before the inspected car is placed.
local function clearParkingSpot(parkingSpot)
  local hasVehicles, vehicleIds = parkingSpot:hasAnyVehicles()
  if hasVehicles then
    for _, vehId in ipairs(vehicleIds) do
      gameplay_traffic.forceTeleport(vehId)
    end
  end
end

-- Returns false, or false and "travelFailed" when an unpaid taxi refuses the trip.
local function placeInspectedVehicle(parkingSpot, vehToInspect, teleportToVehicle, doesThePlayerHaveToDriveThere)
  clearParkingSpot(parkingSpot)
  parkingSpot:moveResetVehicleTo(vehToInspect:getID(), nil, nil, nil, nil, true)

  if teleportToVehicle then
    if not inspectSeam.travelToInspection(parkingSpot, vehToInspect) then
      vehToInspect:delete()
      resetInspectionData()
      return false, "travelFailed"
    end
  elseif doesThePlayerHaveToDriveThere then
    inspectSeam.setInspectionRoute(parkingSpot.pos)
    setTimeToInspectVehicle()
  end
  return true
end

local function startInspectionJob(job, vehicleInfo, teleportToVehicle, atSeller)
  clearPreviousSale(job)

  local vehToInspect = showVehicle(vehicleInfo)
  if not vehToInspect then return false end

  local parkingSpot, doesThePlayerHaveToDriveThere = findInspectionSpot(vehicleInfo, vehToInspect, teleportToVehicle, atSeller)
  if not parkingSpot then
    log("E", "inspectVehicle", "startInspection: no parking spot for seller " .. tostring(vehicleInfo.sellerId))
    vehToInspect:delete()
    resetInspectionData()
    return false
  end

  local placed, refusal = placeInspectedVehicle(parkingSpot, vehToInspect, teleportToVehicle, doesThePlayerHaveToDriveThere)
  if not placed then
    return false, refusal
  end

  defineTestDriveParameters(vehicleInfo, parkingSpot, doesThePlayerHaveToDriveThere)
  if not doesThePlayerHaveToDriveThere then
    addSaleTether()
    addVehTetherToSalePos()
  end
  gameplay_rawPois.clear()
  return true
end

local function startInspection(vehicleInfo, teleportToVehicle, job, atSeller)
  local inspectable
  inspectable, atSeller = inspectSeam.screenInspection(vehicleInfo, atSeller)
  if not inspectable then return false end
  if job then
    return startInspectionJob(job, vehicleInfo, teleportToVehicle, atSeller)
  end
  core_jobsystem.create(function(job)
    startInspectionJob(job, vehicleInfo, teleportToVehicle, atSeller)
  end, 1)
end

-- Public API: sale actions ------------------------------------------------------------------------

local function buySpawnedVehicle(buyVehicleOptions)
  local ok = overhaul_career_market_vehicleShopping.buySpawnedVehicle(buyVehicleOptions) -- only a completed purchase leaves the sale
  if ok then
    leaveSaleCallback("dontDespawn", false, false, _tr("ui.career.inspectVehicle.message.purchasedVehicle"))
  end
  return ok
end

local function startTestDrive()
  overhaul_career_career.closeAllMenus()
  overhaul_career_market_testDrive.start(state.testDriveVehInfo.vehId, state.testDriveInfo)
end

local function onTestDriveAbandoned()
  leaveSaleCallback("flagForDeletion", true, true, _tr("ui.career.inspectVehicle.message.abandonedSale"))
end

local function onTestDriveDamageDetected()
  state.testDriveDamageDetected = true
  inspectSeam.refreshTestDriveCharge(state.testDriveVehInfo)
end

local function isTestDriveDamageDetected()
  return state.testDriveDamageDetected
end

local function getSpawnedVehicleInfo()
  return state.testDriveVehInfo
end

local function getDidTestDrive()
  return state.didTestDrive
end

-- Public API: map and prompts ---------------------------------------------------------------------

-- The bigmap marker only shows while the player still has to drive to the car.
local function buildInspectVehiclePoi(info)
  local id = string.format("inspectVehicle-%s-%s-parkingEnd", info.dealershipName, info.route)
  local poi = {
    data = {
      type = "inspectVehicle",
      testDriveInfo = info,
    },
    id = "inspectVehicleMarker##" .. id,
    markerInfo = {
      inspectVehicleMarker = {
        pos = info.startParkingSpot.pos,
        radius = info.startParkingSpot.scl:length() / 2 + 2,
        vehicleHeight = 4,
      },
    }
  }

  if info.doesThePlayerHaveToDriveThere then
    poi.markerInfo.bigmapMarker = {
      pos = info.startParkingSpot.pos,
      icon = "mission_drift_triangle",
      name = info.dealershipName,
      description = _tr("ui.career.inspectVehicle.bigmap.sellerAwaitingDescription"),
      thumbnail = info.dealershipPreview,
      previews = {info.dealershipPreview},
    }
  end
  return poi
end

local function getInspectVehiclePoi()
  if overhaul_career_career.isActive() and state.testDriveInfo then
    return buildInspectVehiclePoi(state.testDriveInfo)
  end
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not overhaul_career_career.isActive() then return end
  local inspectVehiclePoi = getInspectVehiclePoi()
  if inspectVehiclePoi then
    table.insert(elements, inspectVehiclePoi)
  end
end

local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData) do
    if elem.type == "inspectVehicle" then
      local vehicleInfo = elem.testDriveInfo.vehicleInfo
      local data = {
        icon = "poi_dealer_1_rect",
        heading = vehicleInfo.Brand .. " - " .. vehicleInfo.Name,
        preheadings = {_tr("ui.career.inspectVehicle.prompt.purchaseVehicle")},
        sorting = {
          type = elem.type,
          id = elem.id
        },
        props = {
          {
            icon = "carDealer",
            keyLabel = core_locales.contextTranslate("ui.career.inspectVehicle.prompt.fromSeller", {sellerName = vehicleInfo.sellerName})
          }
        }
      }

      data.buttonLabel = _tr("ui.career.inspectVehicle.prompt.seePurchaseInformation")
      data.buttonFun = function()
        openPurchaseMenuWithTether(elem.testDriveInfo.vehicleInfo.shopId)
      end
      table.insert(activityData, data)
    end
  end
end

local function onPurchaseMenuClosed()
  if state.purchaseTether then
    overhaul_career_maintenance_tether.removeTether(state.purchaseTether)
    state.purchaseTether = nil
  end
end

-- Game hooks: test drive and sale lifetime --------------------------------------------------------

local function onOverhaulTestDriveStarted()
  state.didTestDrive = true
  state.testDriveDamageDetected = false
  -- the player is in the test car now, so the sale tether would pull it back
  removeSaleTether()
  removeVehTetherToSalePos()
end

-- A player who walks off before arriving forfeits the car to the seller.
local function checkIfPlayerHasArrivedToVehInspection(playerVehObj, vehObj)
  local distanceToVeh = vehObj:getPosition():distance(playerVehObj:getPosition())
  if distanceToVeh < config.ARRIVE_TO_VEH_INSPECTION_DIST then
    scratchDir:setSub2(vehObj:getPosition(), playerVehObj:getPosition())
    local vehDist = castRayStatic(playerVehObj:getPosition(), scratchDir, config.ARRIVE_TO_VEH_INSPECTION_DIST)
    if vehDist >= distanceToVeh then
      state.hasPlayerArrivedToVehInspection = true
      addSaleTether()
      addVehTetherToSalePos()
      -- navigation stays until the ground-marker arrival distance, not the stock 20 m
    end
  end
end

local function updateTimeLeftToInspectVehicle(dtSim)
  state.timeLeftToInspectVehicle = state.timeLeftToInspectVehicle - dtSim
  if state.timeLeftToInspectVehicle <= 0 then
    leaveSaleCallback("flagForDeletion", true, false, _tr("ui.career.inspectVehicle.message.sellerTimedOut"))
  end
end

local function checkTestDriveVehMoved(vehObj)
  if state.checkTestDriveVehMovedFlag then
    local distanceToVeh = vehObj:getPosition():distance(state.testDriveInfo.startParkingSpot.pos)
    if distanceToVeh > config.VEH_TO_SALE_POS_DIST then
      M.leaveSaleCallback("flagForDeletion", false, false, _tr("ui.career.inspectVehicle.message.vehicleMovedSaleCancelled"))
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not state.testDriveVehInfo then return end

  local vehObj = getObjectByID(state.testDriveVehInfo.vehId)
  local playerVehObj = getPlayerVehicle(0)
  if not vehObj or not playerVehObj then return end

  if state.testDriveInfo then
    checkTestDriveVehMoved(vehObj) -- to avoid stealing the vehicle
    -- player on its way to the vehicle
    if state.testDriveInfo.doesThePlayerHaveToDriveThere and not state.hasPlayerArrivedToVehInspection then
      updateTimeLeftToInspectVehicle(dtSim)
      checkIfPlayerHasArrivedToVehInspection(playerVehObj, vehObj)
    end
  end
end

local function onVehicleDestroyed(vehId)
  if not state.testDriveVehInfo then return end
  if vehId == state.testDriveVehInfo.vehId then
    resetInspectionData()
  end
end

local function onAnyMissionChanged(status, id)
  if not overhaul_career_career.isActive() then return end
  if status == "started" then
    leaveSaleCallback("despawn")
  end
end

local function onOverhaulDeliveryModeStarted()
  leaveSaleCallback("despawn")
end

local function onOverhaulTestDriveEndedAfterFade()
  if state.testDriveVehInfo then
    log("D", "inspectVehicle", "onOverhaulTestDriveEndedAfterFade: re-arming tethers for vehId=" .. tostring(state.testDriveVehInfo.vehId))
    addSaleTether()
    addVehTetherToSalePos()
    gameplay_rawPois.clear()

    -- auto-open purchase screen after returning from test drive
    if state.testDriveInfo and state.testDriveInfo.vehicleInfo then
      openPurchaseMenuWithTether(state.testDriveInfo.vehicleInfo.shopId)
    end
  else
    log("W", "inspectVehicle", "onOverhaulTestDriveEndedAfterFade fired without testDriveVehInfo; sale tether will NOT be re-armed")
  end
end

local function onVehicleSwitched(oldId, newId, player)
  if state.testDriveVehInfo and newId == state.testDriveVehInfo.vehId and not overhaul_career_market_testDrive.isActive() then
    local veh = getObjectByID(newId)
    if veh then
      core_vehicleBridge.executeAction(veh, 'setFreeze', true)
    end
  end
end

-- Exports -----------------------------------------------------------------------------------------

M.onActivityAcceptGatherData = onActivityAcceptGatherData

M.showVehicle = showVehicle
M.buySpawnedVehicle = buySpawnedVehicle
M.startTestDrive = startTestDrive
M.startInspection = startInspection
M.getSpawnedVehicleInfo = getSpawnedVehicleInfo
M.getDidTestDrive = getDidTestDrive
M.getInspectVehiclePoi = getInspectVehiclePoi
M.onTestDriveDamageDetected = onTestDriveDamageDetected
M.isTestDriveDamageDetected = isTestDriveDamageDetected

M.onOverhaulDeliveryModeStarted = onOverhaulDeliveryModeStarted
M.onVehicleDestroyed = onVehicleDestroyed
M.onAnyMissionChanged = onAnyMissionChanged
M.onOverhaulTestDriveStarted = onOverhaulTestDriveStarted
M.onUpdate = onUpdate
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onPurchaseMenuClosed = onPurchaseMenuClosed
M.onTestDriveAbandoned = onTestDriveAbandoned
M.onOverhaulTestDriveEndedAfterFade = onOverhaulTestDriveEndedAfterFade
M.onVehicleSwitched = onVehicleSwitched

-- internal only: the sale tether and the bay check call back into this
M.leaveSaleCallback = leaveSaleCallback

return M
