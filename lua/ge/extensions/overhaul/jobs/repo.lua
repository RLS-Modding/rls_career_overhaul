-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Owns repo job state, target vehicles, pickup, delivery and completion.
-- Read helpers and generation parts first, then ordered update phases, lifecycle and public actions.
local recordJob = require("overhaul/lib/progression/logbookFeed").register("overhaul.repoCompleted", {
  title = "Repossession completed", label = "Jobs", icon = "carCoins"
}, "jobs/repo.lua")

local M = {}
local statePush = require('overhaul/lib/ui/statePush')

M.dependencies = {
  "util_configListGenerator",
  "gameplay_parking",
}

local configListGenerator = require("util/configListGenerator")
local usedVehicleCondition = require("overhaul/lib/market/usedVehicleCondition")
local parking = require("gameplay/parking")
local parkingReservation = require("overhaul/lib/parking/reservation").service
local levelData = require("overhaul/lib/world/levelData")
local vehiclePolicy = require("overhaul/lib/vehicles/policy")
local repoRoute = require("overhaul/lib/activity/routeLease").new()
local function setRepoPath(position, options) return repoRoute.set(position, options) end

-- Config ------------------------------------------------------------------------------------------

local completionFadeDurationSeconds = 0.5
local RETURN_WARNING_DISTANCE_M = 90
local RETURN_LIMIT_DISTANCE_M = 100
local RETURN_TIMEOUT_S = 10

local REPO_SKILL_ATTRIBUTE_KEY = "careerSkills-recovery"
local REPO_SKILL_PATH_IDS = { "careerSkills-recovery", "recovery" }
local REPO_SKILL_MAX_LEVEL = 50
local REPO_FILTERS_FILE = "gameplay/overhaul/repo/repoVehicleFilters.json"
local vehiclePool = require("overhaul/jobs/repo/vehiclePool")(
  REPO_FILTERS_FILE,
  REPO_SKILL_ATTRIBUTE_KEY,
  REPO_SKILL_MAX_LEVEL,
  REPO_SKILL_PATH_IDS
)

-- State -------------------------------------------------------------------------------------------

local marker
local repoJobInstance = nil

-- Shared helpers ----------------------------------------------------------------------------------

local function stopFadeSafe()
  if ui_fadeScreen and ui_fadeScreen.stop then
    pcall(function() ui_fadeScreen.stop(completionFadeDurationSeconds) end)
  end
end

-- Vehicle cleanup and switching -----------------------------------------------------------------

local function switchPlayerToRepoVehicle(repoVehicleId)
  if not repoVehicleId then return false end
  local repoVehicle = getObjectByID(repoVehicleId)
  if repoVehicle then
    be:enterVehicle(0, repoVehicle)
    return true
  end
  ui_fadeScreen.stop(0.5)

  -- Avoid spawning/entering via inventory here because it can trigger the global loading screen.
  return false
end

local function deleteDeliveredVehicle(deliveredId)
  if not deliveredId then return end
  if gameplay_traffic then pcall(function() gameplay_traffic.removeTraffic(deliveredId) end) end
  local deliveredVehicle = getObjectByID(deliveredId)
  if deliveredVehicle then
    pcall(function() core_vehicleBridge.executeAction(deliveredVehicle, "setFreeze", true) end)
    pcall(function() deliveredVehicle:delete() end)
  end
end

local function clearRepoDeliveryMarker()
  if marker then
    pcall(function() marker:unregisterObject() end)
    pcall(function() marker:delete() end)
    marker = nil
  end
  repoRoute.clear()
end

local function createMarker(position)
  if not marker then
    marker = createObject("TSStatic")
    marker.shapeName = "art/shapes/interface/checkpoint_marker.dae"
    marker.scale = vec3(4, 4, 4)
    marker.useInstanceRenderData = true
    marker.instanceColor = ColorF(0, 0.8, 0.2, 0.7):asLinear4F()
    marker:setPosition(position)
    marker:registerObject("repo_delivery_marker")
  end
end

-- Repo job state and reservations ---------------------------------------------------------------

local VehicleRepoJob = {}
VehicleRepoJob.__index = VehicleRepoJob

function VehicleRepoJob:new()
  local instance = setmetatable({}, VehicleRepoJob)
  instance.vehicleId = nil
  instance.vehicleValue = nil
  instance.pickupLocation = nil
  instance.deliveryLocation = nil
  instance.jobStartTime = nil
  instance.isMonitoring = false
  instance.selectedDealership = nil
  instance.isJobStarted = false
  instance.returnCountdown = nil
  instance.totalDistanceTraveled = 0
  instance.spawnedVehicle = false
  instance.isCompleted = false
  instance.isCompleting = false
  instance.reservationToken = nil
  instance.reservedPickupSpot = nil
  instance.reservedDeliverySpot = nil
  instance.availableDealerships = nil
  instance.pendingDeliveredDeleteId = nil
  instance.uiStateUpdateTimer = 0
  if core_groundMarkers then repoRoute.clear() end
  instance.eligibleVehicles = nil
  instance.eligibleRepoVehiclesByDealership = nil
  instance.repoTag = nil
  instance.repoTierLabel = nil
  instance.employmentMode = false
  instance.employmentOnComplete = nil
  instance.employmentOnAbort = nil
  instance.employmentHomeFacId = nil
  instance.employmentDeliveryLabel = nil
  instance.employmentPickupFacId = nil
  instance.employmentPickupLabel = nil
  instance.employmentVehicleCandidates = nil
  return instance
end

function VehicleRepoJob:releasePickupReservation()
  if self.reservedPickupSpot and self.reservationToken then
    parkingReservation.releaseSpot(self.reservedPickupSpot, self.reservationToken)
  end
  self.reservedPickupSpot = nil
end

function VehicleRepoJob:releaseDeliveryReservation()
  if self.reservedDeliverySpot and self.reservationToken then
    parkingReservation.releaseSpot(self.reservedDeliverySpot, self.reservationToken)
  end
  self.reservedDeliverySpot = nil
end

function VehicleRepoJob:releaseReservations()
  self:releasePickupReservation()
  self:releaseDeliveryReservation()
  self.reservationToken = nil
end

-- Job resource cleanup --------------------------------------------------------------------------

local function captureEmploymentContext(self, options)
  options = type(options) == "table" and options or {}
  local preserveEmployment = options.preserveEmployment and self.employmentMode
  local employmentContext = preserveEmployment
      and {
        employmentMode = true,
        employmentOnComplete = self.employmentOnComplete,
        employmentOnAbort = self.employmentOnAbort,
        employmentHomeFacId = self.employmentHomeFacId,
        employmentDeliveryLabel = self.employmentDeliveryLabel,
        employmentPickupFacId = self.employmentPickupFacId,
        employmentPickupLabel = self.employmentPickupLabel,
        repoVehicle = self.repoVehicle,
        repoVehicleID = self.repoVehicleID,
      }
    or nil
  return employmentContext
end

local function releaseJobResources(self)
  self:releaseReservations()
  if self.vehicleId then
    if gameplay_traffic then pcall(function() gameplay_traffic.removeTraffic(self.vehicleId) end) end
    local vehicle = getObjectByID(self.vehicleId)
    if vehicle then pcall(function() vehicle:delete() end) end
  end
  if marker then
    pcall(function() marker:unregisterObject() end)
    pcall(function() marker:delete() end)
    marker = nil
  end
end

local function clearJobState(self)
  self.vehicleId = nil
  self.vehicleValue = nil
  self.pickupLocation = nil
  self.deliveryLocation = nil
  self.jobStartTime = nil
  self.isMonitoring = false
  self.selectedDealership = nil
  self.isJobStarted = false
  self.employmentPickupPrepared = nil
  self.returnCountdown = nil
  self.totalDistanceTraveled = 0
  self.spawnedVehicle = false
  self.isCompleted = false
  self.isCompleting = false
  self.reservationToken = nil
  self.reservedPickupSpot = nil
  self.reservedDeliverySpot = nil
  self.reward = nil
  self.jobCoroutine = nil
  self.randomVehicleInfo = nil
  self.vehicleConfig = nil
  self.validSpots = nil
  self.selectedSpot = nil
  self.availableDealerships = nil
  self.pendingDeliveredDeleteId = nil
  self.parkingSpots = nil
  self.playerPosition = nil
  self.vehInfo = nil
  self.paintName = nil
  self.updateTimer = nil
  self.uiStateUpdateTimer = 0
  self.eligibleVehicles = nil
  self.eligibleRepoVehiclesByDealership = nil
  self.repoTag = nil
  self.repoTierLabel = nil
  self.employmentMode = false
  self.employmentOnComplete = nil
  self.employmentOnAbort = nil
  if core_groundMarkers then repoRoute.clear() end
end

local function restoreEmploymentContext(self, employmentContext)
  if employmentContext then
    self.employmentMode = employmentContext.employmentMode
    self.employmentOnComplete = employmentContext.employmentOnComplete
    self.employmentOnAbort = employmentContext.employmentOnAbort
    self.employmentHomeFacId = employmentContext.employmentHomeFacId
    self.employmentDeliveryLabel = employmentContext.employmentDeliveryLabel
    self.employmentPickupFacId = employmentContext.employmentPickupFacId
    self.employmentPickupLabel = employmentContext.employmentPickupLabel
    self.repoVehicle = employmentContext.repoVehicle
    self.repoVehicleID = employmentContext.repoVehicleID
  else
    self.employmentHomeFacId = nil
    self.employmentDeliveryLabel = nil
    self.employmentPickupFacId = nil
    self.employmentPickupLabel = nil
    self.employmentVehicleCandidates = nil
  end
end

function VehicleRepoJob:resetToInitialState(options)
  self.completionGeneration = (self.completionGeneration or 0) + 1
  if self.completionFadeActive then stopFadeSafe(); self.completionFadeActive = nil end
  local employmentContext = captureEmploymentContext(self, options)
  releaseJobResources(self)
  clearJobState(self)
  restoreEmploymentContext(self, employmentContext)
end

function VehicleRepoJob:destroy() self:resetToInitialState() end

function VehicleRepoJob:checkVehicleExists()
  if not self.vehicleId then return true end
  local vehicle = getObjectByID(self.vehicleId)
  if not vehicle then
    self:resetToInitialState()
    return false
  end
  local success = pcall(function() vehicle:getPosition() end)
  if not success then
    self:resetToInitialState()
    return false
  end
  return true
end

-- Employment eligibility and publication --------------------------------------------------------

local function getEmploymentModule() return overhaul_career_work_employment end

local function isOnEmploymentShift()
  local employmentModule = getEmploymentModule()
  return employmentModule and employmentModule.isOnShift and employmentModule.isOnShift() or false
end

local function isPlayerInCompanyRepoTruck()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return false end
  local employmentModule = getEmploymentModule()
  if not employmentModule or not employmentModule.getEmployerOrgId then return false end
  local employerOrganizationId = employmentModule.getEmployerOrgId()
  if not employerOrganizationId then return false end
  local vehicleId = be:getPlayerVehicleID(0)
  if not vehicleId or vehicleId < 0 then return false end
  local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehicleId)
  local vehicleInfo = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
  return vehicleInfo and vehicleInfo.loanType == "company" and vehicleInfo.owningOrganization == employerOrganizationId
end

local function isRepoDisabled()
  local disabled = false
  local reason = ""
  if gameplay_walk and gameplay_walk.isWalking() then
    disabled = true
    reason = "Repo service is not available while walking"
    return disabled, reason
  end
  local repoMultiplier = (
    overhaul_career_economyAdjuster and overhaul_career_economyAdjuster.getSectionMultiplier("repo")
  ) or 1.0
  if repoMultiplier == 0 then
    disabled = true
    reason = "Repo multiplier is set to 0"
  end
  if overhaul_career_challengeModes.isChallengeActive() then
    local activeChallenge = overhaul_career_challengeModes.getActiveChallenge()
    if activeChallenge then
      if activeChallenge.economyAdjuster and activeChallenge.economyAdjuster.repo == 0 then
        disabled = true
        reason = string.format("Repo is disabled due to '%s' Challenge", activeChallenge.name or "Unknown Challenge")
      end
    end
  end
  return disabled, reason
end

local function buildRepoStateData(instance, overrides)
  local repoDisabled, disabledReason = isRepoDisabled()
  if not repoDisabled and isOnEmploymentShift() then
    repoDisabled = true
    disabledReason = "Clock out before taking independent repo jobs."
  end
  local effectiveState = repoDisabled and "disabled" or "no_mission"
  local distanceToDestination = 0
  if instance then
    if instance.deliveryLocation and instance.vehicleId then
      local vehicle = getObjectByID(instance.vehicleId)
      if vehicle then
        local success, position = pcall(function() return vehicle:getPosition() end)
        if success and position then distanceToDestination = (position - instance.deliveryLocation.pos):length() end
      end
    end
    if instance.isCompleted then
      effectiveState = repoDisabled and "disabled" or "completed"
    elseif instance.jobCoroutine and coroutine.status(instance.jobCoroutine) ~= "dead" then
      effectiveState = repoDisabled and "disabled" or "loading"
    elseif instance.isMonitoring then
      effectiveState = repoDisabled and "disabled" or (instance.isJobStarted and "dropping_off" or "picking_up")
    end
  end
  local stateFields = vehiclePool.getRepoStateFields(instance)
  local stateData = {
    state = effectiveState,
    vehicle = instance and instance.randomVehicleInfo or nil,
    deliveryLocation = instance
        and (instance.employmentMode and (instance.employmentDeliveryLabel or "the company yard") or (instance.selectedDealership and instance.selectedDealership.name))
      or "",
    distanceToDestination = distanceToDestination,
    totalDistance = instance and (instance.totalDistanceTraveled or 0) or 0,
    reward = instance and (instance.reward or 0) or 0,
    isRepoVehicle = M.isRepoVehicle(),
    repoDisabled = repoDisabled,
    disabledReason = disabledReason,
    repoTag = stateFields.repoTag,
    repoTierLabel = stateFields.repoTierLabel,
    repoSkillLevel = stateFields.repoSkillLevel,
    repoPayoutBonusPercent = stateFields.repoPayoutBonusPercent,
  }
  if type(overrides) == "table" then
    for key, value in pairs(overrides) do
      stateData[key] = value
    end
  end
  return stateData
end

-- Delivery finalization -------------------------------------------------------------------------

local function finalizeRepoDelivery(self, deliveredId, repoId, rewardText)
  clearRepoDeliveryMarker()
  self.isJobStarted = false
  self.isMonitoring = false
  self.isCompleted = true
  if deliveredId and repoId and be:getPlayerVehicleID(0) == deliveredId then switchPlayerToRepoVehicle(repoId) end
  if deliveredId and be:getPlayerVehicleID(0) ~= deliveredId then
    deleteDeliveredVehicle(deliveredId)
    self.vehicleId = nil
    self.pendingDeliveredDeleteId = nil
  else
    self.pendingDeliveredDeleteId = deliveredId
  end

  self:releaseDeliveryReservation()
  statePush.send("updateRepoState", buildRepoStateData(self, { state = "completed" }))
  if self.employmentMode then
    ui_message(rewardText, 8, "Assignment", "info")
  else
    ui_message(rewardText, 15, "Job Completed", "info")
  end
end

-- Parts -------------------------------------------------------------------------------------------

local generation = require("overhaul/jobs/repo/generation")(
  VehicleRepoJob,
  buildRepoStateData,
  configListGenerator,
  vehiclePool.getEligibleRepoVehiclesForDealership,
  parkingReservation,
  vehiclePool.pickWeightedRepoVehicleInfo,
  usedVehicleCondition
)

local function isRepoCarrier(vehicleId)
  return repoJobInstance ~= nil and repoJobInstance.repoVehicleID ~= nil
    and repoJobInstance.repoVehicleID == tonumber(vehicleId)
end

local disposeRepoRole = vehiclePolicy.registerRole("repo", "repoCarrier", isRepoCarrier, "loaded")

function VehicleRepoJob:initializePlayerVehicle()
  local playerVehicle = be:getPlayerVehicle(0)
  self.repoVehicle = playerVehicle
  if not playerVehicle then return end
  self.playerPosition = playerVehicle:getPosition()
end

function VehicleRepoJob:findParkingSpots()
  local found, spots = levelData.loadCityParkingSpots()
  if found then self.parkingSpots = spots end
  if not self.parkingSpots then
    local parkingService = overhaul_shell_gameMode.isActive() and overhaul_integration_services_parking or parking
    self.parkingSpots = parkingService.getParkingSpots()
    log("W", "repo", "Using parking module fallback for spots")
  end
  if not self.parkingSpots or not self.parkingSpots.objects then
    log("E", "repo", "No parking spots found!")
    return
  end
end

function VehicleRepoJob:spawnVehicle()
  local paintName, paint = generation.pickRepoSpawnPaint(self.randomVehicleInfo.model_key, self.vehicleConfig)
  self.paintName = paintName
  local spawnOptions = {
    config = self.vehicleConfig,
    autoEnterVehicle = false,
    pos = self.selectedSpot.pos,
    rot = self.selectedSpot.rot or quat(0, 0, 0, 1),
    cling = true,
    electrics = {
      parkingbrake = 0,
    },
  }
  if paintName and paint then
    spawnOptions.paint = paint
    spawnOptions.paintName = paintName
  end
  local newVehicle = core_vehicles.spawnNewVehicle(self.randomVehicleInfo.model_key, spawnOptions)
  if not newVehicle then return end
  self.vehicleId = newVehicle:getID()
  if paintName then core_vehicle_manager.setVehiclePaintsNames(self.vehicleId, { paintName, paintName, paintName }) end
  self.pickupLocation = self.selectedSpot.pos
  self.isMonitoring = true

  setRepoPath(self.selectedSpot.pos, { clearPathOnReachingTarget = true })
  self.totalDistanceTraveled = core_groundMarkers.getPathLength()
  self.vehInfo = self.randomVehicleInfo
  if not self.employmentMode then
    ui_message(
      "New Repo Job Available!\nSomeone missed a payment on their \n"
        .. generation.repoVehicleName(self)
        .. ".\nPick it up for a reward.",
      10,
      "New Job",
      "info"
    )
  end
end

function VehicleRepoJob:onVehicleSwitched(oldId, newId)
  self.repoVehicle = getObjectByID(newId)
  self.repoVehicleID = newId
  if self.employmentMode then return end
  if not self.isJobStarted then
    self:destroy()
    self:generateJob()
  end
end

function VehicleRepoJob:calculateReward()
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return nil end
  local elapsedSeconds = math.max(1, os.time() - (self.jobStartTime or os.time()))
  local distanceMultiplier = self.totalDistanceTraveled * 2
  local timeMultiplier = (self.totalDistanceTraveled / (elapsedSeconds * 10))
  local rewardFoundation = math.floor(
    (((5 * math.sqrt(self.vehicleValue or 1000)) + distanceMultiplier) * timeMultiplier) / 4
  ) / 15
  local baseReward = (rewardFoundation * 1.25) + 1000
  local payoutRewardBase = rewardFoundation + 500
  local repoTagData = vehiclePool.getRepoTagData(self.repoTag) or {}
  local repoSkillLevel = vehiclePool.getRepoSkillLevel()
  local repoPayoutBonusPercent = vehiclePool.getRepoPayoutBonusPercent(repoSkillLevel)
  local categoryMultiplier = tonumber(repoTagData.payMultiplier) or 1
  local payoutBase = math.floor((payoutRewardBase * categoryMultiplier * (1 + repoPayoutBonusPercent)) + 0.5)
  local adjustedReward = payoutBase
  local repoMultiplier = (
    overhaul_career_economyAdjuster and overhaul_career_economyAdjuster.getSectionMultiplier("repo")
  ) or 1.0
  adjustedReward = payoutBase * repoMultiplier
  adjustedReward = math.floor(adjustedReward + 0.5)
  return adjustedReward, baseReward, repoMultiplier
end

function VehicleRepoJob:isEmploymentHeld()
  local employment = overhaul_career_work_employment
  return self.employmentMode and employment and employment.isOnShift and not employment.isOnShift() or false
end

-- Employment cargo ------------------------------------------------------------------------------

local function employmentCargoOnFlatbed(job)
  if not job or not job.employmentMode or not job.vehicleId or not job.repoVehicleID then return false end
  local vehicleTasks = overhaul_career_logistics_vehicleTasks
  if vehicleTasks and vehicleTasks.isCargoOnHaulerBed then
    return vehicleTasks.isCargoOnHaulerBed(job.vehicleId, job.repoVehicleID) and true or false
  end
  return false
end

local function notifyEmploymentRepoHud()
  local employmentModule = overhaul_career_work_employment
  if employmentModule and employmentModule.refreshHudTasklist then employmentModule.refreshHudTasklist(true) end
end

-- Completion rewards and bookkeeping --------------------------------------------------------------

local function buildCompletionReward(self)
  local reward, baseReward = self:calculateReward()
  local vehicleInfo = self.vehInfo or {}
  local vehicleName = ((vehicleInfo.Brand or "") .. " " .. (vehicleInfo.Name or "")):gsub("^%s+", ""):gsub("%s+$", "")
  if vehicleName == "" then vehicleName = "vehicle" end
  local yardName = self.employmentDeliveryLabel
    or (self.selectedDealership and self.selectedDealership.name)
    or "the company yard"
  local rewardText
  if self.employmentMode then
    rewardText = string.format("Returned the %s to %s.", vehicleName, yardName)
  else
    rewardText = "You've Dropped Off a " .. vehicleName .. "."
    if reward then rewardText = rewardText .. "\nYou have been paid $" .. tostring(reward) end
  end
  local paidMoney = tonumber(reward) or 0
  local completionMeta = {
    skillXp = 0,
    repoTag = self.repoTag,
    repoTierLabel = self.repoTierLabel,
    vehicleLabel = vehicleName,
  }
  return reward, rewardText, paidMoney, completionMeta
end

local function awardCompletionReward(self, reward, rewardText, paidMoney, completionMeta)
  local vehicleName = completionMeta.vehicleLabel
  if overhaul_career_career and overhaul_career_career.isActive() and reward then
    local repoTagData = vehiclePool.getRepoTagData(self.repoTag) or {}
    local repoSkillXp = math.max(
      1,
      math.floor(
        (5 + (tonumber(repoTagData.baseXp) or 0) + math.floor(((self.totalDistanceTraveled or 0) / 2000) + 0.5)) * 2
          + 0.5
      )
    )
    completionMeta.skillXp = repoSkillXp
    local rewardData = {
      money = { amount = reward },
      [REPO_SKILL_ATTRIBUTE_KEY] = { amount = repoSkillXp },
    }
    overhaul_career_economy_difficultyMode.scalePaymentRewardData(rewardData, { includeMoney = false })
    paidMoney = (rewardData.money and rewardData.money.amount) or reward
    if not self.employmentMode then
      local repoBonusPercent = vehiclePool.getRepoPayoutBonusPercent(vehiclePool.getRepoSkillLevel())
      local repoBonusText = math.floor(repoBonusPercent * 100 + 0.5)
      rewardText = "You've Dropped Off a " .. vehicleName .. ".\nYou have been paid $" .. paidMoney
      rewardText = rewardText .. overhaul_career_economy_activityHeat.formatSurgeBonusText("repo")
      if self.repoTierLabel and self.repoTierLabel ~= "" then
        rewardText = rewardText .. "\nTier: " .. self.repoTierLabel
      end
      if repoBonusText > 0 then rewardText = rewardText .. "\nRepo Skill Bonus: +" .. repoBonusText .. "%" end
      -- A negative repo multiplier in saved economy data can push the pay below zero.
      local scaledSkillXp = rewardData[REPO_SKILL_ATTRIBUTE_KEY]
      local accepted, problem = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({
        amount = rewardData.money and rewardData.money.amount,
        xp = scaledSkillXp and { [REPO_SKILL_ATTRIBUTE_KEY] = scaledSkillXp.amount } or nil,
        label = rewardText,
        tags = { "gameplay", "reward", "repo", "recovery" },
        fullReward = true,
        allowNetDebit = true,
      }, "activity:repo", {vehicleRole = "player"}))
      -- A refused reward never blocked the drop-off; keep that boundary without retry.
      if accepted ~= true then log("W", "repo", "Repo payout refused: " .. tostring(problem))
      else recordJob({name = vehicleName, money = paidMoney}) end
    end
  end
  return rewardText, paidMoney
end

local function notifyEmploymentCompletion(self, paidMoney, completionMeta)
  -- Employment bookkeeping must run even if save/payment side effects fail.
  if self.employmentMode then
    local onComplete = self.employmentOnComplete
    self.employmentOnComplete = nil
    self.employmentOnAbort = nil
    local cbOk, cbErr = pcall(function()
      if onComplete then
        onComplete(paidMoney, completionMeta)
      elseif overhaul_career_work_employment then
        overhaul_career_work_employment.onRepoDeliveryComplete(paidMoney, completionMeta)
      else
        log("W", "repo", "Employment repo completed without employment callback")
      end
    end)
    if not cbOk then log("E", "repo", string.format("Employment repo callback failed: %s", tostring(cbErr))) end
  end
end

local function saveRepoCompletion(self, reward, repoId)
  if overhaul_career_career and overhaul_career_career.isActive() and reward then
    local saveOk, saveErr = pcall(function()
      overhaul_career_saveSystem.saveCurrent()
      if not self.employmentMode then
        local invId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(repoId)
        if invId then overhaul_career_garage_inventory.addRepossession(invId) end
      end
    end)
    if not saveOk then log("W", "repo", string.format("Repo post-completion save failed: %s", tostring(saveErr))) end
  end
end

local function finishRepoCompletion(self, reward, deliveredId, repoId, rewardText)
  self.reward = reward
  local finOk, finErr = pcall(finalizeRepoDelivery, self, deliveredId, repoId, rewardText)
  if not finOk then
    log("E", "repo", string.format("Repo finalize failed: %s", tostring(finErr)))
    clearRepoDeliveryMarker()
    self.isCompleted = true
    self.isMonitoring = false
    self.isJobStarted = false
  end
  self.isCompleting = false
  stopFadeSafe()
  self.completionFadeActive = nil
end

local function runRepoCompletion(job)
  local self = job.args[1]
  local generation = job.args[2]
  local function isCurrent()
    return self.completionGeneration == generation and self.isCompleting
  end
  if not isCurrent() then return end

  -- LuaJIT cannot yield across a protected call, so sleeps stay outside pcall.
  if ui_fadeScreen and ui_fadeScreen.start then
    self.completionFadeActive = true
    ui_fadeScreen.start(completionFadeDurationSeconds)
  end
  job.sleep(completionFadeDurationSeconds)
  if not isCurrent() then return end
  if self:isEmploymentHeld() then
    self.isCompleting = false
    if ui_fadeScreen and ui_fadeScreen.stop then ui_fadeScreen.stop(completionFadeDurationSeconds) end
    self.completionFadeActive = nil
    return
  end
  local deliveredId = self.vehicleId
  local repoId = self.repoVehicleID
  if deliveredId and repoId and be:getPlayerVehicleID(0) == deliveredId then
    switchPlayerToRepoVehicle(repoId)
    job.sleep(0.1)
    if not isCurrent() then return end
  end
  local reward, rewardText, paidMoney, completionMeta = buildCompletionReward(self)
  rewardText, paidMoney = awardCompletionReward(self, reward, rewardText, paidMoney, completionMeta)
  notifyEmploymentCompletion(self, paidMoney, completionMeta)
  saveRepoCompletion(self, reward, repoId)
  finishRepoCompletion(self, reward, deliveredId, repoId, rewardText)
end

-- Pickup preparation and return countdown ---------------------------------------------------------

local function prepareEmploymentPickup(self)
  if not self.employmentPickupPrepared then
    self.employmentPickupPrepared = true
    local dropName = self.employmentDeliveryLabel
      or (self.selectedDealership and self.selectedDealership.name)
      or "the yard"
    ui_message(
      string.format("Load the %s.\nHaul it back to %s.", generation.repoVehicleName(self), dropName),
      10,
      "info",
      "info"
    )
    local vehicle = getObjectByID(self.vehicleId)
    if vehicle then
      pcall(function() vehicle:queueLuaCommand('input.event("parkingbrake", 1, "FILTER_DI", nil, nil, nil, nil)') end)
    end
    gameplay_traffic.insertTraffic(self.vehicleId, true)
    local trafficVehicle = gameplay_traffic.getTrafficData()[self.vehicleId]
    if trafficVehicle then trafficVehicle:setRole("empty") end
  end
end

local function prepareStandalonePickup(self)
  self.isJobStarted = true
  local dropName = self.employmentDeliveryLabel
    or (self.selectedDealership and self.selectedDealership.name)
    or "the yard"
  local pickupMsg = string.format("Pick up the %s.\nPlease drive it to %s.", generation.repoVehicleName(self), dropName)
  ui_message(pickupMsg, 10, "info", "info")
  local vehicle = getObjectByID(self.vehicleId)
  if vehicle then
    local success = pcall(
      function() vehicle:queueLuaCommand('input.event("parkingbrake", 1, "FILTER_DI", nil, nil, nil, nil)') end
    )
    if not success then
      self:resetToInitialState()
      return false
    end
  end

  gameplay_traffic.insertTraffic(self.vehicleId, true) -- true means ignore AI control
  local trafficVehicle = gameplay_traffic.getTrafficData()[self.vehicleId]
  if trafficVehicle then
    trafficVehicle:setRole("empty")
  else
  end
  createMarker(self.deliveryLocation.pos)
  setRepoPath(self.deliveryLocation.pos, { clearPathOnReachingTarget = true })
  return true
end

local function beginLoadedHaul(self)
  if self.employmentMode and employmentCargoOnFlatbed(self) then
    self.isJobStarted = true
    self.employmentPickupPrepared = true
    local dropName = self.employmentDeliveryLabel
      or (self.selectedDealership and self.selectedDealership.name)
      or "the yard"
    ui_message(string.format("Vehicle loaded.\nHaul it back to %s.", dropName), 8, "info", "info")
    setRepoPath(self.deliveryLocation.pos, { clearPathOnReachingTarget = true })
    notifyEmploymentRepoHud()
  end
end

local function restorePickupRoute(self)
  local vehicle = getObjectByID(self.vehicleId)
  if vehicle then
    local success, position = pcall(function() return vehicle:getPosition() end)
    if success and position then setRepoPath(position, { clearPathOnReachingTarget = true }) end
  end
end

local function updateReturnCountdown(self, distanceM, hauling)
  local vehicleName = generation.repoVehicleName(self)
  if distanceM > RETURN_WARNING_DISTANCE_M and distanceM < RETURN_LIMIT_DISTANCE_M then
    local message = hauling
        and ("You have driven too far from the " .. vehicleName .. ".\nPlease return it to the parking spot.")
      or "You have driven too far from Your Repo Vehicle.\nPlease return to it."
    ui_message(message, 10, "info", "info")
  elseif distanceM > RETURN_LIMIT_DISTANCE_M and not self.employmentMode then
    if not self.returnCountdown then
      self.returnCountdown = RETURN_TIMEOUT_S
    else
      local suffix = hauling and (" seconds to return the  " .. vehicleName .. ".")
        or " seconds to return to your Repo Vehicle."
      ui_message("You have " .. math.floor(self.returnCountdown) .. suffix, 1, "info", "info")
      self.returnCountdown = self.returnCountdown - 1
      if self.returnCountdown <= 0 then
        ui_message("Someone else has picked up the " .. vehicleName .. ".", 10, "info", "info")
        self:resetToInitialState()
        return false
      end
    end
  elseif self.returnCountdown then
    local message = hauling and ("You have returned to the " .. vehicleName .. ".")
      or "You have returned to your Repo Vehicle."
    ui_message(message, 3, "info", "info")
    self.returnCountdown = nil
    restorePickupRoute(self)
    self.isJobStarted = false
  end
  return true
end

local function updatePickup(self, distance, playerPos, repoPos)
  if distance <= 20 then
    if self.employmentMode then
      prepareEmploymentPickup(self)
    elseif not prepareStandalonePickup(self) then
      return false
    end
  end
  beginLoadedHaul(self)
  return updateReturnCountdown(self, (playerPos - repoPos):length(), false)
end

local function updateHaul(self, distance)
  if self.employmentMode and not employmentCargoOnFlatbed(self) then
    self.isJobStarted = false
    self.jobStartTime = nil
    restorePickupRoute(self)
    notifyEmploymentRepoHud()
    return true
  end
  return updateReturnCountdown(self, distance, true)
end

-- Held jobs and timed publication -----------------------------------------------------------------

local function updateHeldJob(self)
  if self:isEmploymentHeld() then
    if not self.employmentMarkerHeld then
      clearRepoDeliveryMarker()
      self.employmentMarkerHeld = true
    end
    return true
  end
  if self.employmentMarkerHeld then
    self.employmentMarkerHeld = nil
    if self.isMonitoring and self.isJobStarted and self.deliveryLocation then
      if not self.employmentMode then createMarker(self.deliveryLocation.pos) end
      if core_groundMarkers then setRepoPath(self.deliveryLocation.pos, { clearPathOnReachingTarget = true }) end
    end
  end
  return false
end

local function advanceGeneration(self)
  if self.jobCoroutine and coroutine.status(self.jobCoroutine) ~= "dead" then
    local success, message = coroutine.resume(self.jobCoroutine)
    if not success then
      log("E", "repo", string.format("Repo generation coroutine failed: %s", tostring(message)))
      self.jobCoroutine = nil
      generation.abortRepoGeneration(self)
      return false
    end
  end
  return true
end

local function publishTimedState(self)
  if self.uiStateUpdateTimer >= 0.5 then
    self.uiStateUpdateTimer = 0
    if
      (self.jobCoroutine and coroutine.status(self.jobCoroutine) ~= "dead")
      or self.isMonitoring
      or self.isCompleted
    then
      statePush.refresh("updateRepoState", buildRepoStateData(self))
    end
  end
end

-- Carrier targets and delivery updates ------------------------------------------------------------

local function readCarrierPosition(self)
  local repoVehicle = self.repoVehicleID and getObjectByID(self.repoVehicleID)
  if not repoVehicle then
    self.repoVehicleID = nil
    self.repoVehicle = nil
    if self.vehicleId then
      local vehicle = getObjectByID(self.vehicleId)
      if vehicle then pcall(function() vehicle:delete() end) end
    end
    if core_groundMarkers then repoRoute.clear() end
    ui_message("Your Repo Vehicle has been removed.\nYou have lost your job.", 10, "info", "info")
    self:resetToInitialState()
    return
  end
  local repoPosSuccess, repoPosResult = pcall(function() return repoVehicle:getPosition() end)
  if not repoPosSuccess or not repoPosResult then
    self:resetToInitialState()
    return
  end
  return repoPosResult
end

local function readUpdateTargets(self)
  if not self.isMonitoring or not self.vehicleId then return end
  if not self:checkVehicleExists() then return end
  if self.updateTimer < 1 then return end
  self.updateTimer = 0
  local playerVehicle = be:getPlayerVehicle(0)
  if not playerVehicle then return end
  local playerPos = playerVehicle:getPosition()
  local vehicle = getObjectByID(self.vehicleId)
  if not vehicle then
    self:resetToInitialState()
    return
  end
  local vehiclePos
  local success, position = pcall(function() return vehicle:getPosition() end)
  if not success or not position then
    self:resetToInitialState()
    return
  end
  vehiclePos = position
  local repoPos = readCarrierPosition(self)
  if not repoPos then return end
  return playerVehicle, playerPos, repoPos, (vehiclePos - repoPos):length()
end

local function updateDelivery(self)
  if self.jobStartTime then
    local vehicle = getObjectByID(self.vehicleId)
    if not vehicle then
      self:resetToInitialState()
      return false
    end
    local success, position = pcall(function() return vehicle:getPosition() end)
    if not success or not position then
      self:resetToInitialState()
      return false
    end
    local vehiclePos = position
    local distanceFromDestination = (vehiclePos - self.deliveryLocation.pos):length()
    local velSuccess, vel = pcall(function() return vehicle:getVelocity():length() end)
    if not velSuccess or not vel then
      self:resetToInitialState()
      return false
    end
    local velocity = vel
    local completionDistanceM = self.employmentMode and 8 or 3
    local completionSpeedMps = self.employmentMode and 0.35 or 1
    if distanceFromDestination <= completionDistanceM and velocity <= completionSpeedMps then
      if self.isCompleting then return false end
      self.isCompleting = true
      self.completionGeneration = (self.completionGeneration or 0) + 1
      core_jobsystem.create(runRepoCompletion, 1, self, self.completionGeneration)
    elseif distanceFromDestination <= 10 then
      if self.employmentMode then
        ui_message("You're at the company yard.\nPark the vehicle in the marked stall.", 10, "info", "info")
      else
        ui_message(
          "You've arrived at the dealership.\nPlease return the vehicle to the parking spot.",
          10,
          "info",
          "info"
        )
      end
    else
      if
        self.deliveryLocation.pos ~= nil
        and (not core_groundMarkers.getTargetPos() or core_groundMarkers.getTargetPos() ~= self.deliveryLocation.pos)
      then
        setRepoPath(self.deliveryLocation.pos, { clearPathOnReachingTarget = true })
      end
    end
  end
  return true
end

-- Target ignition and pickup movement -------------------------------------------------------------

local function updateTargetIgnition(self, playerVehicle, distance)
  if self.jobStartTime and playerVehicle:getID() == self.vehicleId then
    if distance > 50 then
      local vehicle = getObjectByID(self.vehicleId)
      if vehicle then
        local success = pcall(
          function()
            vehicle:queueLuaCommand([[
              if electrics.values.ignition then
                electrics.setIgnitionLevel(0)
              end
            ]])
          end
        )
        if not success then
          self:resetToInitialState()
          return false
        end
      end
    end
  end
  return true
end

local function updatePickupMovement(self, distance)
  if distance <= 15 and not self.jobStartTime then
    if not (self.employmentMode and not employmentCargoOnFlatbed(self)) then
      local vehicle = getObjectByID(self.vehicleId)
      if vehicle then
        local velSuccess, vel = pcall(function() return vehicle:getVelocity():length() end)
        if velSuccess and vel and vel > 2 then
          self.jobStartTime = os.time()
          self:releasePickupReservation()
          setRepoPath(self.deliveryLocation.pos, { clearPathOnReachingTarget = true })
          self.totalDistanceTraveled = self.totalDistanceTraveled + core_groundMarkers.getPathLength()
        end
      end
    end
  end
end

-- Per-frame update --------------------------------------------------------------------------------

function VehicleRepoJob:onUpdate(dtReal, dtSim, dtRaw)
  if updateHeldJob(self) then return end
  if not self.updateTimer then self.updateTimer = 0 end
  self.updateTimer = self.updateTimer + dtSim
  if not self.uiStateUpdateTimer then self.uiStateUpdateTimer = 0 end
  self.uiStateUpdateTimer = self.uiStateUpdateTimer + dtSim
  if not advanceGeneration(self) then return end
  publishTimedState(self)
  local playerVehicle, playerPos, repoPos, distance = readUpdateTargets(self)
  if not playerVehicle then return end
  if not self.isJobStarted then
    if not updatePickup(self, distance, playerPos, repoPos) then return end
  elseif not updateHaul(self, distance) then
    return
  end
  if not updateDelivery(self) then return end
  if not updateTargetIgnition(self, playerVehicle, distance) then return end
  updatePickupMovement(self, distance)
end

function VehicleRepoJob:completeJob() self:destroy() end

local function onVehicleSwitched(oldId, newId)
  local instance = M.getRepoJobInstance()
  if not instance then return end

  -- If we finished a delivery while still inside the delivered vehicle, delete it once the player left it.
  if
    instance.pendingDeliveredDeleteId
    and oldId == instance.pendingDeliveredDeleteId
    and newId ~= instance.pendingDeliveredDeleteId
  then
    local deliveredId = instance.pendingDeliveredDeleteId
    instance.pendingDeliveredDeleteId = nil
    if gameplay_traffic then pcall(function() gameplay_traffic.removeTraffic(deliveredId) end) end
    local deliveredVehicle = getObjectByID(deliveredId)
    if deliveredVehicle then
      pcall(function() core_vehicleBridge.executeAction(deliveredVehicle, "setFreeze", true) end)
      pcall(function() deliveredVehicle:delete() end)
    end
    if instance.vehicleId == deliveredId then instance.vehicleId = nil end
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function resetRepoSession()
  if repoJobInstance then
    local ok, err = pcall(function() repoJobInstance:destroy() end)
    if not ok then log("W", "repo", "Repo session reset failed: " .. tostring(err)) end
    -- Regeneration retains the carrier, but a new career must not inherit the previous one.
    repoJobInstance.repoVehicleID = nil
    repoJobInstance.repoVehicle = nil
  end
end

-- The target and its traffic and checkpoint records must be gone before a Lua reload serializes them.
-- Left declared after unload on purpose: the session reset does nothing once no job exists.
require("overhaul/lib/vehicles/temporary").declare("repo", resetRepoSession)

-- Public job actions ------------------------------------------------------------------------------

function M.getRepoJobInstance()
  if not repoJobInstance then repoJobInstance = VehicleRepoJob:new() end
  return repoJobInstance
end

function M.generateJob()
  if isOnEmploymentShift() then
    ui_message("Clock out before taking independent repo jobs.", 10, "info", "info")
    return
  end
  local instance = M.getRepoJobInstance()
  if not M.isRepoVehicle() then
    ui_message("You must be in a vehicle to generate a repo job.", 10, "info", "info")
    return
  end
  if instance and M.isRepoVehicle() then
    instance.employmentMode = false
    instance.employmentOnComplete = nil
    instance.employmentOnAbort = nil
    instance.repoVehicle = be:getPlayerVehicle(0)
    instance.repoVehicleID = be:getPlayerVehicle(0):getID()
    instance:generateJob()
  end
end

function M.startEmploymentJob(onComplete, onAbort, options)
  local disabled, reason = isRepoDisabled()
  if disabled then
    if onAbort then onAbort(reason, true) end
    return false
  end
  if not isPlayerInCompanyRepoTruck() then
    if onAbort then onAbort("Get in the company truck first.") end
    return false
  end

  options = type(options) == "table" and options or {}
  local instance = M.getRepoJobInstance()
  -- Re-entering the flatbed must not wipe an in-progress company haul.
  if instance.employmentMode and M.isEmploymentRepoActive() then
    instance.employmentOnComplete = onComplete or instance.employmentOnComplete
    instance.employmentOnAbort = onAbort or instance.employmentOnAbort
    if options.homeFacId or options.facId then instance.employmentHomeFacId = options.homeFacId or options.facId end
    if options.deliveryLabel or options.yardName then
      instance.employmentDeliveryLabel = options.deliveryLabel or options.yardName
    end
    if options.pickupFacId then instance.employmentPickupFacId = options.pickupFacId end
    if options.pickupLabel then instance.employmentPickupLabel = options.pickupLabel end
    instance.repoVehicle = be:getPlayerVehicle(0)
    instance.repoVehicleID = be:getPlayerVehicle(0):getID()
    return true
  end
  instance.employmentMode = true
  instance.employmentOnComplete = onComplete
  instance.employmentOnAbort = onAbort
  instance.employmentHomeFacId = options.homeFacId or options.facId
  instance.employmentDeliveryLabel = options.deliveryLabel or options.yardName
  instance.employmentPickupFacId = options.pickupFacId
  instance.employmentPickupLabel = options.pickupLabel
  instance.employmentVehicleCandidates = nil
  instance.repoVehicle = be:getPlayerVehicle(0)
  instance.repoVehicleID = be:getPlayerVehicle(0):getID()
  instance:generateJob()
  return true
end

-- Employment state -------------------------------------------------------------------------------

function M.isEmploymentRepoActive()
  local instance = M.getRepoJobInstance()
  if not instance or not instance.employmentMode then return false end
  if instance.isCompleted or instance.isCompleting then return false end
  if instance.isMonitoring then return true end
  if instance.jobCoroutine and coroutine.status(instance.jobCoroutine) ~= "dead" then return true end
  return false
end

function M.isEmploymentPickupReady()
  local instance = M.getRepoJobInstance()
  if not instance or not instance.employmentMode then return false end
  if instance.isCompleted or instance.isCompleting then return false end
  return instance.isMonitoring and instance.vehicleId ~= nil
end

function M.isEmploymentRepoCompleting()
  local instance = M.getRepoJobInstance()
  return instance and instance.employmentMode and instance.isCompleting and true or false
end

function M.getEmploymentTaskGuidance()
  local instance = M.getRepoJobInstance()
  if not instance or not instance.employmentMode then return nil end
  if instance.jobCoroutine and coroutine.status(instance.jobCoroutine) ~= "dead" then
    return {
      label = "Company pickup loading",
      subtext = "Dispatcher is finding a vehicle",
    }
  end
  if not instance.isMonitoring then return nil end
  local yard = instance.employmentDeliveryLabel
    or (instance.selectedDealership and instance.selectedDealership.name)
    or "the dropoff"
  local pickup = instance.employmentPickupLabel
  local vehicleName = generation.formatRepoVehicleDisplayName(instance)
  if not instance.isJobStarted or not employmentCargoOnFlatbed(instance) then
    return {
      label = "Load the vehicle onto the flatbed",
      subtext = pickup and ("Pick up at " .. pickup) or ("Pick up the " .. vehicleName .. " first"),
    }
  end
  return {
    label = "Haul the vehicle to " .. yard,
    subtext = "Drop off the " .. vehicleName .. " at " .. yard,
  }
end

function M.cancelEmploymentJob()
  local instance = M.getRepoJobInstance()
  if not instance or not instance.employmentMode then return false end
  instance.employmentOnComplete = nil
  local onAbort = instance.employmentOnAbort
  instance.employmentOnAbort = nil
  instance:destroy()
  if onAbort then onAbort("Car haul cancelled.") end
  return true
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  local instance = M.getRepoJobInstance()
  if instance then instance:onUpdate(dtReal, dtSim, dtRaw) end
end

-- Any player vehicle can start independent repo work.
-- Phone state ------------------------------------------------------------------------------------

function M.isRepoVehicle()
  local playerVehicle = be:getPlayerVehicle(0)
  return playerVehicle ~= nil
end

function M.isRepoTarget(vehicleId)
  vehicleId = tonumber(vehicleId)
  return vehicleId ~= nil and repoJobInstance ~= nil and repoJobInstance.vehicleId == vehicleId
end

function M.onOverhaulIsRecoveryCargo(vehicleId, answer)
  if not answer.isCargo then answer.isCargo = M.isRepoTarget(vehicleId) end
end

function M.requestRepoState()
  local instance = M.getRepoJobInstance()
  if instance then
    if instance.isMonitoring and instance.vehicleId then
      if not instance:checkVehicleExists() then instance = M.getRepoJobInstance() end
    end
  end
  statePush.send("updateRepoState", buildRepoStateData(instance))
end

function M.cancelJob()
  local instance = M.getRepoJobInstance()
  if instance then instance:destroy() end
end

function M.completeJob()
  local instance = M.getRepoJobInstance()
  if instance then instance:completeJob() end
end

-- Game hooks --------------------------------------------------------------------------------------

function M.onClientEndMission() resetRepoSession() end

function M.onOverhaulActive(active)
  if active == false then resetRepoSession() end
end

function M.onExtensionUnloaded()
  disposeRepoRole()
end

M.VehicleRepoJob = VehicleRepoJob
M.onVehicleSwitched = onVehicleSwitched

-- The payload builder records economy snapshots, so the activity exposes actions without a projection.
M.activity = require("overhaul/jobs/repo/activity")(M)

return M
