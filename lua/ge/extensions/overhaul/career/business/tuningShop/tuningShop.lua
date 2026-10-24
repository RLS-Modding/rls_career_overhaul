-- Tuning shop jobs, hired technicians, manager timers and customer vehicles.
-- Read configuration/state, shop services, ordered updates, lifecycle, public topics and hooks.
local M = {}

M.dependencies = {'util_configListGenerator'}

-- Requires ----------------------------------------------------------------------------------------
local businessSaveState = require("overhaul/lib/business/saveState")
local freeroamUtils = require('overhaul/lib/events/rewardPolicy').create(
  function() return overhaul_career_career.isActive() end,
  function() return overhaul_career_economyAdjuster end,
  function() return overhaul_career_economy_globalEconomy end
)
local tuningShopTechs = require('overhaul/career/business/tuningShop/techs')

-- Config ------------------------------------------------------------------------------------------
local GEN_INTERVAL_SECONDS = 120
local EXPIRY_SECONDS = 300

local BASE_DAMAGE_THRESHOLD = 1500
local updateIntervals = {UPDATE_INTERVAL_TECHS = 1.0}
updateIntervals.UPDATE_INTERVAL_MANAGER = 2.0
updateIntervals.UPDATE_INTERVAL_COSTS = 5.0

local blacklistedModels = {
  atv = true,
  citybus = true,
  lansdale = true,
  md_series = true,
  pigeon = true,
  racetruck = true,
  rockbouncer = true,
  us_semi = true,
  van = true,
  utv = true,
  wl40 = true,
  dumptruck = true,
  midtruck = true,
  PM_Pulling_Tractor = true,
  YB_mini_mod_tractor = true
}

-- State -------------------------------------------------------------------------------------------
local shop = {
  raceData = nil,
  raceDataLevel = nil,
  factoryConfigs = nil,
  brandConfigsCache = {},
  businessJobs = {},
  businessXP = {},
  cachedRaceDataByBusiness = {},
  generationTimers = {},
  lastJobRefreshTimes = {},
  managerTimers = {},
  operatingCostTimers = {},
  jobIdCounter = 0,
  techsAccumulator = 0,
  managerAccumulator = 0,
  costsAccumulator = 0,
  totalSimTime = 0,
  vehicleInfoCache = nil,
  initializedBusinesses = {},
  soldResetBusinesses = {},
  businessSelections = {},
  cachedBusinessMapInfo = {},
}

local cachedGarageZones = {}
local activePersonalVehicle = {}

-- Shared helpers ----------------------------------------------------------------------------------

local function getTuningShopKits()
  return overhaul_career_business_tuningShop_kits
end

local function getDamageThreshold(businessId)
  local level = 0
  if businessId then
    level = overhaul_career_business_skillTree.getNodeProgress(businessId, "quality-of-life", "thatll-buff-out") or 0
  end
  return BASE_DAMAGE_THRESHOLD * (1 + level)
end

-- Parts -------------------------------------------------------------------------------------------
local parts = {}
local inputs = {
  parts = parts,
  shop = shop,
  tuningShopTechs = tuningShopTechs,
  freeroamUtils = freeroamUtils,
  blacklistedModels = blacklistedModels,
  GEN_INTERVAL_SECONDS = GEN_INTERVAL_SECONDS,
  EXPIRY_SECONDS = EXPIRY_SECONDS,
  getDamageThreshold = getDamageThreshold,
  getTuningShopKits = getTuningShopKits,
  cachedGarageZones = cachedGarageZones,
  activePersonalVehicle = activePersonalVehicle,
}
for _, name in ipairs({"garage", "persist", "selections", "proof", "settlement", "generation", "manager", "views"}) do
  parts[name] = require("overhaul/career/business/tuningShop/shop/" .. name).new(inputs)
end

-- Update ------------------------------------------------------------------------------------------
local function advanceShopClocks(deltaSim)
  shop.totalSimTime = shop.totalSimTime + deltaSim
  shop.techsAccumulator = shop.techsAccumulator + deltaSim
  shop.managerAccumulator = shop.managerAccumulator + deltaSim
  shop.costsAccumulator = shop.costsAccumulator + deltaSim

  local shouldProcessTechs = shop.techsAccumulator >= updateIntervals.UPDATE_INTERVAL_TECHS
  local shouldProcessManager = shop.managerAccumulator >= updateIntervals.UPDATE_INTERVAL_MANAGER
  local shouldProcessCosts = shop.costsAccumulator >= updateIntervals.UPDATE_INTERVAL_COSTS

  return shouldProcessTechs, shouldProcessManager, shouldProcessCosts
end

local function consumeShopCadences(shouldProcessTechs, shouldProcessManager, shouldProcessCosts)
  local techsTime = shouldProcessTechs and shop.techsAccumulator or 0
  local managerTime = shouldProcessManager and shop.managerAccumulator or 0
  local costsTime = shouldProcessCosts and shop.costsAccumulator or 0

  if shouldProcessTechs then
    shop.techsAccumulator = 0
  end
  if shouldProcessManager then
    shop.managerAccumulator = 0
  end
  if shouldProcessCosts then
    shop.costsAccumulator = 0
  end

  return techsTime, managerTime, costsTime
end

local function updateOwnedShop(id, shouldProcessTechs, shouldProcessManager, shouldProcessCosts, techsTime, managerTime, costsTime)
  local jobsChanged = false

  local lastRefresh = shop.lastJobRefreshTimes[id]
  if lastRefresh == nil or (shop.totalSimTime - lastRefresh) >= 10.0 then
    if parts.generation.refreshJobs(id, false) then
      jobsChanged = true
    end
  end

  if shouldProcessTechs then
    tuningShopTechs.processTechs(id, techsTime)
    local kitsModule = getTuningShopKits()
    kitsModule.processKitInstallLocks(id)
  end

  if shouldProcessManager then
    if parts.manager.processManagerTimers(id, managerTime) then
      jobsChanged = true
    end
    if parts.manager.processManagerAssignments(id) then
      jobsChanged = true
    end
  end

  if shouldProcessCosts then
    parts.manager.processOperatingCosts(id, costsTime)
  end

  if jobsChanged then
    parts.views.notifyJobsUpdated(id)
  end
end

local function clearUnownedShopTimers(ownedBusinesses, shouldProcessManager, shouldProcessCosts)
  for id in pairs(shop.generationTimers) do
    if not ownedBusinesses[id] then
      shop.generationTimers[id] = nil
    end
  end

  if shouldProcessManager then
    for id in pairs(shop.managerTimers) do
      if not ownedBusinesses[id] then
        shop.managerTimers[id] = nil
      end
    end
  end

  if shouldProcessCosts then
    for id in pairs(shop.operatingCostTimers) do
      if not ownedBusinesses[id] then
        shop.operatingCostTimers[id] = nil
      end
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not overhaul_career_career.isActive() then return end
  local deltaSim = math.max(dtSim or 0, 0)
  if deltaSim <= 0 then return end
  local shouldProcessTechs, shouldProcessManager, shouldProcessCosts = advanceShopClocks(deltaSim)
  if not shouldProcessTechs and not shouldProcessManager and not shouldProcessCosts then return end
  local purchased = overhaul_career_business_manager.getPurchasedBusinesses("tuningShop") or {}
  local ownedBusinesses = {}
  local techsTime, managerTime, costsTime = consumeShopCadences(shouldProcessTechs, shouldProcessManager, shouldProcessCosts)
  for businessId, owned in pairs(purchased) do
    if owned then
      local id = parts.garage.normalizeBusinessId(businessId)
      ownedBusinesses[id] = true
      updateOwnedShop(id, shouldProcessTechs, shouldProcessManager, shouldProcessCosts, techsTime, managerTime, costsTime)
    end
  end
  clearUnownedShopTimers(ownedBusinesses, shouldProcessManager, shouldProcessCosts)
end

local function resetBusinessForSale(businessId)
  local normalizedId = parts.garage.normalizeBusinessId(businessId)
  if not normalizedId then return false end

  overhaul_career_business_partInventory.clearBusinessParts(normalizedId)
  overhaul_career_business_fleet.clearBusinessInventory(normalizedId)
  tuningShopTechs.clearBusinessTechs(normalizedId)
  local kits = getTuningShopKits()
  kits.clearBusinessKits(normalizedId)

  shop.businessJobs[normalizedId] = { active = {}, new = {} }
  shop.businessXP[normalizedId] = 0
  shop.cachedRaceDataByBusiness[normalizedId] = nil
  shop.generationTimers[normalizedId] = nil
  shop.lastJobRefreshTimes[normalizedId] = nil
  shop.managerTimers[normalizedId] = { elapsed = 0, flagActive = false, paused = false }
  shop.operatingCostTimers[normalizedId] = { elapsed = 0, lastChargeTime = nil }
  shop.initializedBusinesses[normalizedId] = nil
  shop.businessSelections[normalizedId] = { blacklist = {}, notificationList = {}, managerBlacklist = {} }
  shop.cachedBusinessMapInfo[normalizedId] = nil
  activePersonalVehicle[normalizedId] = nil

  shop.soldResetBusinesses[normalizedId] = true

  guihooks.trigger('businessComputer:onJobsUpdated', { businessId = tostring(normalizedId), activeJobs = {}, newJobs = {} })
  guihooks.trigger('businessComputer:onTechsUpdated', { businessId = tostring(normalizedId), techs = {} })
  return true
end

-- Registered shop methods share the extension API; only business-specific methods live here.
local businessObject = setmetatable({
  businessType = "tuningShop",
  features = {
    bankAccount = true,
    skillTrees = true,
    inventory = true,
    personalVehicle = true,
    finances = true,
    xpSystem = true,
    operatingCosts = true
  },
  resetBusinessForSale = resetBusinessForSale,
  isPlayerInBusinessZone = parts.garage.isPlayerInTuningShopZone,
  formatTechForUIEntry = function(businessId, tech) return tuningShopTechs.formatTechForUIEntry(businessId, tech) end,
  loadBusinessTechs = function(businessId) return tuningShopTechs.loadBusinessTechs(businessId) end,
  isVehicleKitLocked = function(businessId, vehicleId)
    local kits = getTuningShopKits()
    return kits.isVehicleKitLocked(businessId, vehicleId) or false
  end,
  getKitInstallTimeRemaining = function(businessId, vehicleId)
    local kits = getTuningShopKits()
    return kits.getKitInstallTimeRemaining(businessId, vehicleId) or 0
  end,
  getKitInstallLock = function(businessId, vehicleId)
    local kits = getTuningShopKits()
    return kits.getKitInstallLock(businessId, vehicleId)
  end,
  loadBusinessKits = function(businessId)
    local kits = getTuningShopKits()
    return kits.loadBusinessKits(businessId) or {}
  end,
  hasKitStorageUnlocked = function(businessId)
    local kits = getTuningShopKits()
    return kits.hasKitStorageUnlocked(businessId) or false
  end,
  getPartSupplierDiscountMultiplier = function(businessId)
    if not businessId then return 1.0 end
    local treeId = "shop-upgrades"
    local nodeId = "part-suppliers"
    local level = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, nodeId) or 0
    return 1.0 - (0.05 * level)
  end,
}, {__index = M})

-- Lifecycle ---------------------------------------------------------------------------------------
local function initializePurchasedShop(businessId)
  parts.views.ensureTabsRegistered()

  local accountId = "business_tuningShop_" .. tostring(businessId)
  local capitalInjectionAmount = overhaul_career_business_manager.getPurchaseCapitalInjectionAmount(0)
  if capitalInjectionAmount > 0 then
    overhaul_career_economy_bank.rewardToAccount({
      money = {
        amount = capitalInjectionAmount
      }
    }, accountId, "Capital Injection", "Initial operating capital", {category = "business"})
  end

  local normalizedId = parts.garage.normalizeBusinessId(businessId)

  parts.persist.loadRaceData(normalizedId)
  parts.selections.getFactoryConfigs()

  if not shop.businessJobs[normalizedId] then
    shop.businessJobs[normalizedId] = {
      active = {},
      new = {}
    }
  end

  local jobs = shop.businessJobs[normalizedId]
  if not jobs.new then
    jobs.new = {}
  end

  local newJobs = parts.generation.generateNewJobs(normalizedId, 3)

  for _, job in ipairs(newJobs) do
    table.insert(jobs.new, job)
  end

  tuningShopTechs.loadBusinessTechs(normalizedId)
  parts.manager.loadManagerTimer(normalizedId)
  parts.manager.loadOperatingCostTimer(normalizedId)

  parts.views.notifyJobsUpdated(normalizedId)
end

local function resetShopCaches()
  shop.businessJobs = {}
  shop.businessXP = {}
  shop.generationTimers = {}
  shop.businessSelections = {}
  shop.cachedRaceDataByBusiness = {}
  shop.cachedBusinessMapInfo = {}
  shop.initializedBusinesses = {}
  shop.operatingCostTimers = {}
  shop.brandConfigsCache = {}
end

local function onCareerActivated()
  shop.managerTimers = {}
  overhaul_career_business_manager.registerBusiness("tuningShop", businessObject, M)
  overhaul_career_business_manager.registerBusinessCallback("tuningShop", {
    onPurchase = initializePurchasedShop,
    onMenuOpen = parts.views.openMenu,
  })
  parts.views.ensureTabsRegistered()
  resetShopCaches()
  parts.selections.getFactoryConfigs()
  parts.generation.buildBrandConfigsCache()
  tuningShopTechs.initialize(parts)
  tuningShopTechs.resetTechs()
end

local function writeShopInfoAndRemoveLegacyFiles(businessId, currentSavePath, writer)
  log("I", "onOverhaulSaveCurrentProfile: processing businessId=" .. tostring(businessId))
  parts.persist.initializeBusinessData(businessId)

  local cachedMapInfo = shop.cachedBusinessMapInfo[businessId] or {}
  log("I", "onOverhaulSaveCurrentProfile: cachedMapInfo.mapId=" .. tostring(cachedMapInfo.mapId))

  local info = {
    xp = shop.businessXP[businessId] or 0,
    selections = shop.businessSelections[businessId] or {},
    operatingCost = shop.operatingCostTimers[businessId] or { elapsed = 0, lastChargeTime = nil },
    kitInstallLocks = {},
    mapId = cachedMapInfo.mapId,
    races = cachedMapInfo.races or {},
    raceData = cachedMapInfo.raceData or {}
  }
  log("I", "onOverhaulSaveCurrentProfile: built info, mapId=" .. tostring(info.mapId))

  local kitsModule = getTuningShopKits()
  info.kitInstallLocks = kitsModule.getKitInstallLocksForSave(businessId) or {}

  parts.persist.saveBusinessInfo(businessId, currentSavePath, info, writer)
  local businessDir = businessSaveState.businessFilePath(businessId .. "", "", currentSavePath .. "")
  for _, legacyName in ipairs({"xp.json", "selections.json", "operatingCost.json"}) do
    if FS:fileExists(businessDir .. legacyName) then
      writer.remove(businessDir .. legacyName)
    end
  end
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  -- Autosave rotation writes every owned shop into the new slot.
  if currentSavePath then
    for businessId, owned in pairs(overhaul_career_business_manager.getPurchasedBusinesses("tuningShop") or {}) do
      local id = owned and parts.garage.normalizeBusinessId(businessId)
      if id then
        parts.persist.loadBusinessXP(id)
        parts.persist.loadBusinessJobs(id)
        tuningShopTechs.loadBusinessTechs(id)
        parts.manager.loadManagerTimer(id)
      end
    end
  end
  for businessId, _ in pairs(shop.businessJobs) do
    parts.persist.saveBusinessJobs(businessId, currentSavePath, writer)
  end
  for businessId, _ in pairs(shop.businessJobs) do
    tuningShopTechs.saveBusinessTechs(businessId, currentSavePath, writer)
  end
  for businessId, _ in pairs(shop.managerTimers) do
    parts.manager.saveManagerTimer(businessId, currentSavePath, writer)
  end

  for businessId, _ in pairs(shop.businessXP) do
    businessId = parts.garage.normalizeBusinessId(businessId)
    if businessId then
      writeShopInfoAndRemoveLegacyFiles(businessId, currentSavePath, writer)
    end
  end
  require('overhaul/lib/business/saveState').clearUnownedFiles(currentSavePath,
    {"jobs.json", "info.json", "xp.json", "selections.json", "operatingCost.json", "manager.json", "techs.json"}, "tuningShop", writer)
end

local function isShopAppUnlocked(businessId)
  if not businessId then return false end

  local level = overhaul_career_business_skillTree.getNodeProgress(businessId, "quality-of-life", "shop-app")
  return level and level > 0
end

local function onOverhaulRaceResult(payload)
  if payload and payload.phase == "proof" then
    return M.captureJobCompletionProofFromLeaderboardId(payload.inventoryId)
  end
end

-- Public API --------------------------------------------------------------------------------------
M.powerToWeightToTime = parts.persist.powerToWeightToTime
M.generateJob = parts.generation.generateJob
M.loadRaceData = parts.persist.loadRaceData
M.initializeBusinessData = parts.persist.initializeBusinessData
M.openMenu = parts.views.openMenu
M.getUIData = parts.views.getUIData
M.getFormattedPersonalVehiclesInZone = parts.garage.getFormattedPersonalVehiclesInZone
M.getJobsForBusiness = parts.generation.getJobsForBusiness
M.getJobsOnly = parts.views.getJobsOnly
M.getActiveJobs = parts.views.getActiveJobs
M.getNewJobs = parts.views.getNewJobs
M.getMaxActiveJobs = parts.settlement.getMaxActiveJobs
M.acceptJob = parts.settlement.acceptJob
M.declineJob = parts.settlement.declineJob
M.abandonJob = parts.settlement.abandonJob
M.completeJob = parts.settlement.completeJob
M.canCompleteJob = parts.proof.jobCompletion.canComplete
M.getJobCompletionStatus = parts.proof.jobCompletion.getStatus
M.getJobLeaderboardBestTime = parts.proof.jobCompletion.getLeaderboardBestTime
M.clearJobLeaderboardEntry = parts.proof.jobCompletion.clearLeaderboardEntry
M.invalidateJobCompletionProof = parts.proof.jobCompletion.invalidateProof
M.captureJobCompletionProofFromLeaderboardId = parts.proof.jobCompletion.captureFromLeaderboardId
M.getAbandonPenalty = parts.settlement.getAbandonPenalty
M.isShopAppUnlocked = isShopAppUnlocked

function M.notifyOnPhoneAppInstalled()
  tuningShopTechs.notifyOnPhoneAppInstalled()
end
M.getBusinessXP = parts.persist.getBusinessXP
M.addBusinessXP = parts.persist.addBusinessXP
M.spendBusinessXP = parts.persist.spendBusinessXP
M.getMaxPulledOutVehicles = parts.generation.getMaxPulledOutVehicles
M.updateTechName = tuningShopTechs.updateTechName
M.assignJobToTech = tuningShopTechs.assignJobToTech
M.isJobLockedByTech = tuningShopTechs.isJobLockedByTech
M.fireTech = tuningShopTechs.fireTech
M.hireTech = tuningShopTechs.hireTech
M.stopTechFromJob = tuningShopTechs.stopTechFromJob
M.getTechData = parts.manager.getTechData
M.getManagerData = parts.manager.getManagerData
M.setManagerPaused = parts.manager.setManagerPaused
M.getBrandSelection = parts.persist.getBrandSelection
M.setBrandSelection = parts.selections.setBrandSelection
M.getRaceSelection = parts.selections.getRaceSelection
M.setRaceSelection = parts.selections.setRaceSelection
M.getAvailableBrands = parts.generation.getAvailableBrands
M.getAvailableRaceTypes = parts.generation.getAvailableRaceTypes
M.requestAvailableBrands = parts.views.requestAvailableBrands
M.requestAvailableRaceTypes = parts.views.requestAvailableRaceTypes
M.getOperatingCosts = parts.manager.getOperatingCosts
M.getFinancesData = parts.views.getFinancesData
M.requestFinancesData = parts.views.requestFinancesData
M.requestSimulationTime = parts.views.requestSimulationTime
M.getJobById = parts.persist.getJobById
M.getVehicleByJobId = parts.settlement.getVehicleByJobId
M.getBlacklistData = parts.selections.getBlacklistData
M.getNotificationListData = parts.selections.getNotificationListData
M.getManagerBlacklistData = parts.selections.getManagerBlacklistData
M.updateBlacklist = parts.selections.updateBlacklist
M.updateNotificationList = parts.selections.updateNotificationList
M.updateManagerBlacklist = parts.selections.updateManagerBlacklist

-- Staff -------------------------------------------------------------------------------------------
M.getTechsForBusiness = function(businessId)
  return tuningShopTechs.loadBusinessTechs(businessId)
end

-- Personal garage ---------------------------------------------------------------------------------
M.isPlayerInTuningShopZone = parts.garage.isPlayerInTuningShopZone
M.isSpawnedVehicleInGarageZone = parts.garage.isSpawnedVehicleInGarageZone
M.isPositionInGarageZone = parts.garage.isPositionInGarageZone
M.isPersonalUseUnlocked = parts.garage.isPersonalUseUnlocked
M.getInventoryVehiclesInGarageZone = parts.garage.getInventoryVehiclesInGarageZone
M.createPersonalVehicleEntry = parts.garage.createPersonalVehicleEntry
M.selectPersonalVehicle = parts.garage.selectPersonalVehicle
M.getActivePersonalVehicle = parts.garage.getActivePersonalVehicle
M.clearActivePersonalVehicle = parts.garage.clearActivePersonalVehicle
M.getDamageThreshold = getDamageThreshold
M.getBusinessObject = function() return businessObject end


-- Registered business API ------------------------------------------------------------------------

M.getLiquidationValue = parts.garage.getLiquidationValue
M.getBlacklist = parts.selections.getBlacklist
M.getNotificationList = parts.selections.getNotificationList
M.getManagerBlacklist = parts.selections.getManagerBlacklist
M.addToBlacklist = parts.selections.addToBlacklist
M.removeFromBlacklist = parts.selections.removeFromBlacklist
M.addToNotificationList = parts.selections.addToNotificationList
M.removeFromNotificationList = parts.selections.removeFromNotificationList
M.updateNotificationAutoAccept = parts.selections.updateNotificationAutoAccept
M.addToManagerBlacklist = parts.selections.addToManagerBlacklist
M.removeFromManagerBlacklist = parts.selections.removeFromManagerBlacklist

-- Game hooks --------------------------------------------------------------------------------------
M.onOverhaulRaceResult = onOverhaulRaceResult
M.onCareerActivated = onCareerActivated
M.onUpdate = onUpdate
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

M.activity = require('overhaul/career/business/tuningShop/activity')(M)
return M
