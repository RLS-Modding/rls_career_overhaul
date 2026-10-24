-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/testDrive.lua (BeamNG 0.40).
-- Runs one test drive from handing over the car until it is returned, abandoned or times out.

local M = {}

-- Config ------------------------------------------------------------------------------------------

local config = {
  MAX_DISTANCE_FROM_VEH = 10, -- walking farther than this from the test car abandons the drive
  DAMAGE_CHECK_INTERVAL = 2, -- sim seconds between repair checks on the test car
}

-- State -------------------------------------------------------------------------------------------

local state = {
  vehicleId = nil,
  active = nil,
  startPosRot = nil,
  testDriveInfo = nil,
  damageDetected = false,
  damageCheckTimer = 0,
  quickAccessInitialized = false,
}

-- Reused by every time-left message, so the HUD updates one entry in place.
local timeLeftMessage = {}

-- Messages ----------------------------------------------------------------------------------------

local function rtMessageJob(job)
  local message = job.args[1] or ""
  local delay = job.args[2] or 0

  job.sleep(delay)
  guihooks.trigger('ScenarioRealtimeDisplay', {msg = message})
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  job.sleep(3.5)
  guihooks.trigger('ScenarioRealtimeDisplay', {msg = ""})
end

local function rtMessage(message, delay)
  core_jobsystem.create(rtMessageJob, 1, message, delay or 0)
end

local function displayTimeLeft(seconds)
  timeLeftMessage.clear = false
  timeLeftMessage.ttl = 5
  timeLeftMessage.msg = core_locales.contextTranslate("ui.career.testDrive.timeLeft", {seconds = seconds})
  timeLeftMessage.category = "testDriveTimeLeft"
  timeLeftMessage.icon = nil
  guihooks.trigger('Message', timeLeftMessage)
end

local function showDamageWarning()
  local amount = overhaul_career_repair_insurance.getTestDriveClaimPrice()
  local msg = core_locales.contextTranslate("ui.career.testDrive.damageWarning", {amount = amount})
  ui_message(msg, 5, "testDriveDamageWarning")
end

-- Activation and data -----------------------------------------------------------------------------

local function setActive(value)
  state.active = value
  gameplay_rawPois.clear()
end

local function setTestDriveInfo(info)
  state.testDriveInfo = deepcopy(info)
end

local function resetData()
  setActive(false)
end

local function resetDataAfterTestDriveDone()
  state.testDriveInfo = nil
  state.vehicleId = nil
  if state.damageDetected then
    ui_message("", 1, "testDriveDamageWarning")
  end
  state.damageDetected = false
  state.damageCheckTimer = 0
end

-- Per-frame checks --------------------------------------------------------------------------------

-- Returns false once the time limit has run out; the clock only exists for timed drives.
local function tickTimeLimit(dtSim)
  local info = state.testDriveInfo
  if not info.timeLimit then return true end
  local timeBefore = round(info.timeLimit)
  info.timeLimit = info.timeLimit - dtSim
  if info.timeLimit < 0 then return false end
  local timeAfter = round(info.timeLimit)
  if timeBefore ~= timeAfter then
    displayTimeLeft(timeAfter)
    if state.damageDetected then
      showDamageWarning()
    end
  end
  return true
end

-- Returns nil when the test car is gone, which the caller treats as too far away.
local function checkPlayerNotTooFarFromVeh()
  local veh = getObjectByID(state.vehicleId)
  if not veh then return end
  local vehPos = veh:getPosition()
  local playerPos = getObjectByID(be:getPlayerVehicleID(0)):getPosition()
  if playerPos:distance(vehPos) > config.MAX_DISTANCE_FROM_VEH then
    return false
  end
  return true
end

local function checkDamage(dtSim)
  if state.damageDetected then return end
  state.damageCheckTimer = state.damageCheckTimer + dtSim
  if state.damageCheckTimer < config.DAMAGE_CHECK_INTERVAL then return end
  state.damageCheckTimer = 0

  overhaul_career_repair_insurance.genericVehNeedsRepair(state.vehicleId, function(needsRepair)
    if needsRepair and state.active then
      state.damageDetected = true
      overhaul_career_market_inspectVehicle.onTestDriveDamageDetected()
    end
  end)
end

-- Return to the dealership -------------------------------------------------------------------------

-- The walker must be placed after the teleport settles, or they reappear where the car was.
local function placeWalkerBesideVehicle(job, vehicle)
  if gameplay_walk.isWalking() then
    gameplay_walk.getInVehicle(vehicle) -- hack
  end
  core_vehicleBridge.executeAction(vehicle, 'setIgnitionLevel', 0)
  core_vehicleBridge.executeAction(vehicle, 'setFreeze', true)

  local vehicleData = map.objects[state.vehicleId]
  if not vehicleData then
    log("W", "testDrive", "world-map data for test drive vehicle not ready right after teleport; using default walking-mode placement")
    gameplay_walk.setWalkingMode(true)
    return
  end

  local oobb = scenetree.findObjectById(state.vehicleId):getSpawnWorldOOBB()
  local vehPos = vehicleData.pos - vec3(0, 0, 1.8)
  local dir = (oobb:getPoint(0) - vehPos)
  dir:normalize()

  job.sleep(0.1)
  local finalPos = oobb:getPoint(0) + (dir * 1.3)
  gameplay_walk.setWalkingMode(true, finalPos, quatFromDir(-dir, vec3(0, 0, 1)))
end

local function teleportVehicleToStart(job, vehicle)
  spawn.safeTeleport(vehicle, state.startPosRot.pos, state.startPosRot.rot, nil, nil, nil, nil, false)
  job.sleep(0.1)
  placeWalkerBesideVehicle(job, vehicle)
end

local function finishReturnAfterFade(vehicle)
  if not vehicle or not scenetree.findObjectById(vehicle:getID()) then
    log("W", "testDrive", "Test drive vehicle lost before onOverhaulTestDriveEndedAfterFade; tethers may not be re-armed")
  end
  extensions.ui_router.navigate('play')
  ui_fadeScreen.stop(1)
  -- fade screen changes the ui state, so we need to change it back here
  extensions.hook('onOverhaulTestDriveEndedAfterFade')
end

-- Ends the drive. Teleport (tp) returns the car to the dealership; otherwise it is despawned by its owner.
local function endTestDriveJob(job)
  local tp = job.args[1]
  if tp == nil then tp = true end

  simTimeAuthority.set(0.5)
  setActive(false)
  if tp then
    ui_fadeScreen.start(1)
  end
  job.sleep(1.5)

  local vehicle = getObjectByID(state.vehicleId)
  if vehicle and tp then
    teleportVehicleToStart(job, vehicle)
  end

  resetDataAfterTestDriveDone()
  simTimeAuthority.set(1)
  if tp then
    finishReturnAfterFade(vehicle)
  end
  job.sleep(1.5)
end

-- Abandon -----------------------------------------------------------------------------------------

local function payAbandonFee(job, abandonFees)
  job.sleep(0.2) -- job is needed to display the ui message
  if abandonFees > 0 then -- private sales don't have abandon fees
    local logBookLabel = "ui.career.testDrive.abandonLogLabel"
    local label = core_locales.contextTranslate("ui.career.testDrive.abandonFeeMessage", {fee = abandonFees})
    ui_message(label, 5, 'test1')
    overhaul_career_economy_payment.pay({money = {amount = abandonFees, canBeNegative = true}}, require("overhaul/lib/finance/metadata").tag({label = logBookLabel}, "fine", {vehicleObjectId = state.vehicleId, vehicleName = "Test drive vehicle"}))
  end
end

local function abandonTestDrive()
  if not state.active then return end

  local abandonFees = state.testDriveInfo and state.testDriveInfo.abandonFees or 0
  setActive(false)
  overhaul_career_career.setAutosaveEnabled(true)

  core_jobsystem.create(function(job)
    payAbandonFee(job, abandonFees)
    resetDataAfterTestDriveDone()
    overhaul_career_market_inspectVehicle.onTestDriveAbandoned()
  end, 1)
end

local function stop(userAborted)
  if not state.active then return end

  if userAborted ~= false then
    extensions.hook("onGameplayActivityAborted")
  end
  core_jobsystem.create(endTestDriveJob, 1)
  overhaul_career_career.setAutosaveEnabled(true)
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function start(newVehicleId, info)
  setTestDriveInfo(info)
  state.vehicleId = newVehicleId
  local vehObj = getObjectByID(state.vehicleId)
  gameplay_walk.getInVehicle(vehObj)
  state.startPosRot = {pos = vehObj:getPosition(), rot = quat(0, 0, 1, 0) * quat(vehObj:getRefNodeRotation())}

  -- the snapshot lets the car be reset to its pre-drive condition after the drive
  core_vehicleBridge.executeAction(vehObj, 'createPartConditionSnapshot', "beforeTestDrive")
  core_vehicleBridge.executeAction(vehObj, 'setPartConditionResetSnapshotKey', "beforeTestDrive")

  setActive(true)
  core_vehicleBridge.executeAction(vehObj, 'setFreeze', false)
  extensions.hook('onOverhaulTestDriveStarted')
  gameplay_rawPois.clear()
  overhaul_career_career.setAutosaveEnabled(false)
end

-- Public API: status ------------------------------------------------------------------------------

local function getTimeLeft()
  if state.testDriveInfo == nil then return nil end
  return state.testDriveInfo.timeLimit
end

local function isActive()
  return state.active
end

local function isDamageDetected()
  return state.damageDetected
end

-- Public API: map and prompts ---------------------------------------------------------------------

local function formatTestDriveToRawPoi(elements)
  local info = state.testDriveInfo
  if info == nil or not state.active or not info.endParkingSpot or not info.endParkingSpotCreated then return end
  local poiId = string.format("testDrive-%s-%s-parkingEnd", info.dealershipName, info.route)
  local eps = info.endParkingSpot
  table.insert(elements, {
    id = poiId,
    data = {type = "testDriveEnd", id = poiId},
    markerInfo = {
      parkingMarker = {path = eps:getPath(), pos = eps.pos, rot = eps.rot, scl = eps.scl},
      bigmapMarker = {pos = eps.pos, name = "ui.career.testDrive.endTestDrive", description = "ui.career.testDrive.endTestDriveDesc", thumbnail = info.dealershipPreview, previews = {info.dealershipPreview}}
    }
  })
end

local function onVehicleRepairedByInsurance(amount)
  rtMessage(core_locales.contextTranslate("ui.career.testDrive.repairCostMessage", {amount = amount}), 1.8)
end

-- Game hooks --------------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim, dtRaw)
  if not state.vehicleId then return end

  if state.active then
    if not tickTimeLimit(dtSim) then
      stop(false)
    end
    if not checkPlayerNotTooFarFromVeh() then
      abandonTestDrive()
    end
    checkDamage(dtSim)
  end
end

local function onOverhaulActive(active)
  if not active then return end
  resetData()
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  formatTestDriveToRawPoi(elements)
end

local function onPoiDetailPromptOpening(elemData, promptData)
  if state.testDriveInfo == nil or not state.active then return end

  local isTestDrivePoi = false
  for _, elem in ipairs(elemData) do
    if elem.type == "testDriveEnd" then
      isTestDrivePoi = true
    end
  end
  if isTestDrivePoi then
    local ret = {}
    ret.label = "ui.career.testDrive.endTestDrive"
    ret.buttonText = "ui.career.testDrive.stopTestDrive"
    ret.buttonFun = function() M.stop(false) end
    table.insert(promptData, ret)
  end
end

local function onBeforeRadialOpened()
  if state.quickAccessInitialized then return end
  state.quickAccessInitialized = true
  core_quickAccess.addEntry(
    {
      level = "/root/sandbox/career/",
      generator = function(entries)
        if not isActive() then return end
        table.insert(entries, {
          title = "ui.career.testDrive.stopTestDrive",
          icon = "abandon",
          priority = 90,
          enabled = true,
          uniqueID = "stopTestDrive",
          ignoreAsRecentActionForCategory = "sandbox",
          onSelect = function()
            overhaul_career_market_testDrive.stop()
            return {"hide"}
          end
        })
      end
    }
  )
end

-- Exports -----------------------------------------------------------------------------------------

M.abandonTestDrive = abandonTestDrive
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onPoiDetailPromptOpening = onPoiDetailPromptOpening
M.getTimeLeft = getTimeLeft
M.stop = stop
M.start = start
M.isActive = isActive
M.isDamageDetected = isDamageDetected
M.formatTestDriveToRawPoi = formatTestDriveToRawPoi
M.resetData = resetData

M.onUpdate = onUpdate
M.onOverhaulActive = onOverhaulActive
M.onVehicleRepairedByInsurance = onVehicleRepairedByInsurance
M.onBeforeRadialOpened = onBeforeRadialOpened

return M
