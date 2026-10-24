-- Business computer API, shared caches and routing to the owner of each business type.
-- Read state, shared helpers, parts, lifecycle, public API by topic, then game hooks.
local M = {}

local jbeamIO = require('jbeam/io')
require('jbeam/slotSystem')
local devConsole = require('overhaul/lib/lifecycle/devConsolePolicy')

-- State -------------------------------------------------------------------------------------------

-- Activation resets these caches so a new career cannot reuse the previous business context.
local cache = {
  vehicleInfoCache = nil,
  partsTreeCache = {},
  businessContexts = {},
}
local pendingCartPurchases = {}

-- Parts share the owner state and call their siblings through this table.
local parts = {}
local shared = {
  cache = cache,
  M = M,
  devConsole = devConsole,
  jbeamIO = jbeamIO,
  pendingCartPurchases = pendingCartPurchases,
  parts = parts,
}

-- Shared helpers ----------------------------------------------------------------------------------

function shared.performBusinessAction(...)
  return overhaul_career_business_manager.perform(...)
end

function shared.getBusinessTypeData(businessType)
  return overhaul_career_business_manager.getTypeData(businessType)
end

local function normalizePartsCacheKey(cacheKey)
  if cacheKey == nil then
    return "nokey"
  end
  return tostring(cacheKey)
end

local function getPartsCacheBucket(businessId, createIfMissing)
  if not businessId then
    return nil
  end
  local bucket = cache.partsTreeCache[businessId]
  if not bucket and createIfMissing then
    bucket = {}
    cache.partsTreeCache[businessId] = bucket
  end
  return bucket
end

function shared.getCachedPartsTree(businessId, cacheKey)
  local bucket = getPartsCacheBucket(businessId, false)
  if not bucket then
    return nil
  end
  return bucket[normalizePartsCacheKey(cacheKey)]
end

function shared.setCachedPartsTree(businessId, cacheKey, data)
  if not businessId then
    return
  end
  local bucket = getPartsCacheBucket(businessId, true)
  bucket[normalizePartsCacheKey(cacheKey)] = data
end

function shared.clearPartsTreeCacheForKey(businessId, cacheKey)
  local bucket = getPartsCacheBucket(businessId, false)
  if not bucket then
    return
  end
  bucket[normalizePartsCacheKey(cacheKey)] = nil
  if not next(bucket) then
    cache.partsTreeCache[businessId] = nil
  end
end

function shared.setBusinessContext(businessType, businessId)
  if not businessType or not businessId then
    return
  end
  -- Bridge may send string ids; Lua may use number keys.
  cache.businessContexts[businessId] = businessType
  cache.businessContexts[tostring(businessId)] = businessType
  local n = tonumber(businessId)
  if n ~= nil then
    cache.businessContexts[n] = businessType
  end
end

local function clearBusinessContext(businessId)
  if not businessId then return end
  cache.businessContexts[businessId] = nil
  cache.businessContexts[tostring(businessId)] = nil
  local n = tonumber(businessId)
  if n ~= nil then
    cache.businessContexts[n] = nil
  end
  cache.partsTreeCache[businessId] = nil
  cache.partsTreeCache[tostring(businessId)] = nil
  if n ~= nil then
    cache.partsTreeCache[n] = nil
  end
end

function shared.getBusinessModule(businessType)
  if not businessType then
    return nil
  end
  local manager = overhaul_career_business_manager
  return manager.getBusinessModule(businessType)
end

-- Business ids can arrive as strings or numbers; a purchase record keyed either way still matches.
local function businessIdMatchesKey(a, b)
  if a == nil or b == nil then
    return false
  end
  if a == b then
    return true
  end
  if tostring(a) == tostring(b) then
    return true
  end
  local na, nb = tonumber(a), tonumber(b)
  if na ~= nil and nb ~= nil and na == nb then
    return true
  end
  return false
end

local function purchasedBusinessTypeForId(businessId)
  local all = overhaul_career_business_manager.getAllPurchasedBusinesses()
  if type(all) ~= "table" then
    return nil, nil
  end
  for btype, list in pairs(all) do
    if type(list) == "table" then
      for k, _ in pairs(list) do
        if businessIdMatchesKey(businessId, k) then
          return btype, k
        end
      end
    end
  end
  return nil, nil
end

function shared.racingTeamRaceFlowModule()
  return overhaul_career_business_racingTeam_raceFlow
end

local function racingTeamModule()
  return overhaul_career_business_racingTeam_racingTeam
end

function shared.resolveBusinessTypeOnly(businessId)
  if not businessId then
    return nil
  end
  local businessType = cache.businessContexts[businessId]
  if not businessType then
    businessType = cache.businessContexts[tostring(businessId)]
  end
  if not businessType and type(businessId) == "string" then
    local n = tonumber(businessId)
    if n ~= nil then
      businessType = cache.businessContexts[n]
    end
  end
  if not businessType then
    local btype, matchedKey = purchasedBusinessTypeForId(businessId)
    if btype and matchedKey then
      shared.setBusinessContext(btype, matchedKey)
      shared.setBusinessContext(btype, businessId)
      businessType = btype
    end
  end
  return businessType
end

function shared.resolveBusinessModule(businessId)
  if not businessId then
    return nil, nil
  end
  local businessType = shared.resolveBusinessTypeOnly(businessId)
  if not businessType then
    log('E', 'businessComputer', 'No business context for businessId=' .. tostring(businessId))
    return nil, nil
  end
  local module = shared.getBusinessModule(businessType)
  if not module then
    log('E', 'businessComputer', 'Missing business module for type ' .. tostring(businessType))
    return nil, businessType
  end
  return module, businessType
end

local function cancelCartPurchases()
  for _, transaction in pairs(pendingCartPurchases) do
    if transaction.cancel then transaction.cancel() end
  end
end

local function getRtFleetOpts(businessId)
  local rows = {}
  local fleet = overhaul_career_business_fleet
  for _, vehicle in ipairs(fleet.getBusinessVehicles(businessId) or {}) do
    local vehicleConfig = vehicle.vehicleConfig or {}
    table.insert(rows, {
      vehicleId = vehicle.vehicleId,
      label = tostring(vehicleConfig.model_key or "?") .. " / " .. tostring(vehicleConfig.key or "?")
    })
  end
  return rows
end

-- Parts -------------------------------------------------------------------------------------------

for _, name in ipairs({"vehicles", "actions", "garage", "partsTree", "tuning", "purchase", "views"}) do
  parts[name] = require("overhaul/career/business/computer/" .. name).new(shared)
end

-- Update ------------------------------------------------------------------------------------------

local function onUpdate(dtReal)
  for _, transaction in pairs(pendingCartPurchases) do
    transaction.elapsed = transaction.elapsed + (dtReal or 0)
    if transaction.elapsed >= 30 and transaction.cancel then transaction.cancel() end
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onOverhaulModulesActivated()
  local purchased = overhaul_career_business_manager.getAllPurchasedBusinesses()
  for businessType, businesses in pairs(purchased) do
    for businessId, _ in pairs(businesses) do
      shared.setBusinessContext(businessType, businessId)
    end
  end
end

local function onExtensionLoaded()
  cache.businessContexts = {}
  if overhaul_career_business_manager.isBusinessOwnershipReady() then onOverhaulModulesActivated() end
  return true
end

local function onExtensionUnloaded()
  cancelCartPurchases()
  require("overhaul/lib/save/store").releaseHolds(M)
end

-- Public API: business data -----------------------------------------------------------------------

local function getTechData(businessId)
  local module = shared.resolveBusinessModule(businessId)
  if module and module.getTechData then
    return module.getTechData(businessId)
  end
  return nil
end

local function getManagerData(businessId)
  local module, businessType = shared.resolveBusinessModule(businessId)
  if not module or not businessType then
    return nil
  end

  shared.setBusinessContext(businessType, businessId)

  if not module.getManagerData then
    return nil
  end

  local ok, result = pcall(module.getManagerData, businessId)
  if not ok then
    log('E', 'businessComputer',
      'Error getting manager data for businessId ' .. tostring(businessId) .. ': ' .. tostring(result))
    return nil
  end

  return result
end

local function selectPersonalVehicle(businessId, inventoryId)
  local module = shared.resolveBusinessModule(businessId)
  if module and module.selectPersonalVehicle then
    return module.selectPersonalVehicle(businessId, inventoryId)
  end
  return { success = false, errorCode = "notSupported", message = "Personal vehicles not supported for this business type" }
end

local function isPersonalUseUnlocked(businessId)
  local module = shared.resolveBusinessModule(businessId)
  if module and module.isPersonalUseUnlocked then
    return module.isPersonalUseUnlocked(businessId)
  end
  return false
end

-- Public exports: UI data and business context --------------------------------------------------

M.getBusinessComputerUIData = parts.vehicles.getBusinessComputerUIData
M.getBusinessTypeForId = shared.resolveBusinessTypeOnly
M.setBusinessContext = shared.setBusinessContext
M.clearBusinessContext = clearBusinessContext
M.clearBusinessCachesForVehicle = parts.vehicles.clearCachesForVehicle
M.clearVehicleDataCaches = parts.vehicles.clearVehicleDataCaches
M.getTechData = getTechData
M.getManagerData = getManagerData
M.getRtFleetOpts = getRtFleetOpts
M.isPersonalUseUnlocked = isPersonalUseUnlocked
M.selectPersonalVehicle = selectPersonalVehicle

-- Public exports: engine shop and passive businesses ---------------------------------------------

M.performEngineShopAction = parts.actions.performEngineShopAction
M.runEngineShopInvariantTests = parts.actions.runEngineShopInvariantTests
M.getPassiveBusinessDashboardData = parts.actions.getPassiveBusinessDashboardData
M.getPassiveBusinessFinanceData = parts.actions.getPassiveBusinessFinanceData
M.collectPassiveBusinessEarnings = parts.actions.collectPassiveBusinessEarnings
M.purchasePassiveBusinessStorageUpgrade = parts.actions.purchasePassiveBusinessStorageUpgrade
M.purchasePassiveBusinessWholesale = parts.actions.purchasePassiveBusinessWholesale
M.orderPassiveBusinessSupply = parts.actions.orderPassiveBusinessSupply
M.setPassiveBusinessOperating = parts.actions.setPassiveBusinessOperating
M.setPassiveBusinessSupplyRoute = parts.actions.setPassiveBusinessSupplyRoute
M.requestPassiveBusinessSaleData = parts.actions.requestPassiveBusinessSaleData
M.sellPassiveBusiness = parts.actions.sellPassiveBusiness
M.closePassiveBusinessManagement = parts.actions.closePassiveBusinessManagement

-- Public exports: jobs, racing team proxy races and techs ----------------------------------------

M.acceptJob = parts.actions.acceptJob
M.declineJob = parts.actions.declineJob
M.abandonJob = parts.actions.abandonJob
M.assignTechToJob = parts.actions.assignTechToJob
M.renameTech = parts.actions.renameTech
M.completeJob = parts.views.completeJob
M.canCompleteJob = parts.views.canCompleteJob
M.getJobCompletionStatus = parts.views.getJobCompletionStatus
M.getAbandonPenalty = parts.views.getAbandonPenalty
M.getActiveJobs = parts.garage.getActiveJobs
M.getNewJobs = parts.garage.getNewJobs
M.beginRacingTeamProxyRaceFromBusinessComputer = parts.actions.beginRacingTeamProxyRaceFromBusinessComputer
M.enterRacingTeamProxyStagingLoadingEarly = parts.actions.enterRacingTeamProxyStagingLoadingEarly
M.preflightRacingTeamProxySpectateUi = parts.actions.preflightRacingTeamProxySpectateUi
M.refreshRacingTeamProxySpectatorUiMinimal = parts.actions.refreshRacingTeamProxySpectatorUiMinimal
M.simulateRacingTeamProxyRace = parts.actions.simulateRacingTeamProxyRace
M.isProxyScheduledDriverFleetOverpowered = parts.actions.isProxyScheduledDriverFleetOverpowered
M.isArmedProxyFleetOverpoweredForRequest = parts.actions.isArmedProxyFleetOverpoweredForRequest
M.cancelRacingTeamProxySession = parts.actions.cancelRacingTeamProxySession
M.cancelRacingTeamProxyScheduledRace = parts.actions.cancelRacingTeamProxyScheduledRace
M.isScheduledRaceReadyForDriver = parts.actions.isScheduledRaceReadyForDriver
M.getRacingTeamCareerSimTime = parts.actions.getRacingTeamCareerSimTime
M.tickRacingTeamScheduledRaceToasts = parts.actions.tickRacingTeamScheduledRaceToasts

-- Public exports: vehicles, garage and repair ----------------------------------------------------

M.sellVehicle = parts.actions.sellVehicle
M.setActiveVehicle = parts.views.setActiveVehicle
M.getActiveVehicle = parts.views.getActiveVehicle
M.getJobsOnly = parts.views.getJobsOnly
M.getVehiclesOnly = parts.views.getVehiclesOnly
M.getTechsOnly = parts.views.getTechsOnly
M.getStatsOnly = parts.views.getStatsOnly
M.getManagerDataOnly = parts.views.getManagerDataOnly
M.enterShoppingVehicle = parts.views.enterShoppingVehicle
M.exitShoppingVehicle = parts.views.exitShoppingVehicle
M.getPersonalVehicleData = parts.vehicles.getPersonalVehicleData
M.getInventoryIdFromPersonalVehicleId = parts.vehicles.getInventoryIdFromPersonalVehicleId
M.pullOutVehicle = parts.garage.pullOutVehicle
M.putAwayVehicle = parts.garage.putAwayVehicle
M.repairBusinessVehicleDamage = parts.garage.repairBusinessVehicleDamage
M.startVehiclePainting = parts.garage.startVehiclePainting
M.startVehicleRefueling = parts.garage.startVehicleRefueling
M.getBusinessVehicleRepairQuote = function(businessId, vehicleId)
  local cost, damage, thr = parts.garage.computeBusinessVehicleRepairCost(businessId, vehicleId)
  if cost == nil then
    return nil
  end
  return { cost = cost, damage = damage, threshold = thr }
end
M.getBrandSelection = parts.garage.getBrandSelection
M.setBrandSelection = parts.garage.setBrandSelection
M.getRaceSelection = parts.garage.getRaceSelection
M.setRaceSelection = parts.garage.setRaceSelection
M.getAvailableBrands = parts.garage.getAvailableBrands
M.getAvailableRaceTypes = parts.garage.getAvailableRaceTypes
M.requestAvailableBrands = parts.garage.requestAvailableBrands
M.requestAvailableRaceTypes = parts.garage.requestAvailableRaceTypes

-- Public exports: parts, tuning and cart purchases -----------------------------------------------

M.requestPartInventory = parts.actions.requestPartInventory
M.sellPart = parts.actions.sellPart
M.sellAllParts = parts.actions.sellAllParts
M.sellPartsByVehicle = parts.actions.sellPartsByVehicle
M.requestVehiclePartsTree = parts.partsTree.requestVehiclePartsTree
M.getPartSupplierDiscountMultiplier = parts.partsTree.getPartSupplierDiscountMultiplier
M.getVehicleTuningData = parts.tuning.getVehicleTuningData
M.requestVehicleTuningData = parts.tuning.requestVehicleTuningData
M.applyVehicleTuning = parts.tuning.applyVehicleTuning
M.loadWheelDataExtension = parts.tuning.loadWheelDataExtension
M.unloadWheelDataExtension = parts.tuning.unloadWheelDataExtension
M.onVehicleWheelDataUpdate = parts.tuning.onVehicleWheelDataUpdate
M.getBusinessAccountBalance = parts.purchase.getBusinessAccountBalance
M.getBusinessXP = parts.purchase.getBusinessXP
M.purchaseCartItems = parts.purchase.purchaseCartItems
M.installPartOnVehicle = parts.tuning.installPartOnVehicle
M.initializePreviewVehicle = parts.tuning.initializePreviewVehicle
M.applyTuningToVehicle = parts.tuning.applyTuningToVehicle
M.calculateTuningCost = parts.tuning.calculateTuningCost
M.getTuningShoppingCart = parts.tuning.getTuningShoppingCart
M.addTuningToCart = parts.tuning.addTuningToCart
M.getVehiclePowerWeight = parts.purchase.getVehiclePowerWeight
M.resetVehicleToOriginal = parts.tuning.resetVehicleToOriginal
M.applyBuildToVehicle = parts.tuning.applyBuildToVehicle
M.cancelBuildOperation = parts.tuning.cancelBuildOperation
M.applyPartsToVehicle = parts.tuning.applyPartsToVehicle
M.applyCartPartsToVehicle = parts.tuning.applyCartPartsToVehicle
M.getAllRequiredParts = parts.tuning.getAllRequiredParts
M.addPartToCart = parts.tuning.addPartToCart
M.onPowerWeightReceived = parts.purchase.onPowerWeightReceived

M.requestFinancesData = function(businessType, businessId)
  if not businessType or not businessId then
    guihooks.trigger('businessComputer:onFinancesData', {
      success = false,
      error = "Missing parameters"
    })
    return
  end

  local module = shared.getBusinessModule(businessType)
  if module and module.requestFinancesData then
    module.requestFinancesData(businessId)
  else
    guihooks.trigger('businessComputer:onFinancesData', {
      success = false,
      error = "Finances not available for this business type",
      businessType = businessType,
      businessId = businessId
    })
  end
end

M.requestSimulationTime = function()
  local tuningShop = overhaul_career_business_tuningShop_tuningShop
  if tuningShop and tuningShop.requestSimulationTime then
    tuningShop.requestSimulationTime()
    return
  end
  guihooks.trigger('businessComputer:onSimulationTime', {
    success = true,
    simulationTime = os.time()
  })
end

M.isSettlementPending = function() return next(pendingCartPurchases) ~= nil end

M.setBusinessName = function(businessType, businessId, name)
  local ok = overhaul_career_business_manager.setBusinessName(businessType, businessId, name)
  guihooks.trigger('businessComputer:onBusinessNameUpdated', {
    success = ok,
    businessType = businessType,
    businessId = businessId,
    businessName = ok and name or nil
  })
end

-- Public exports: kits ----------------------------------------------------------------------------

M.createKit = function(businessId, jobId, kitName)
  local module = shared.resolveBusinessModule(businessId)
  if module and module.createKit then
    return module.createKit(businessId, jobId, kitName)
  end
  return false
end

M.deleteKit = function(businessId, kitId)
  local module = shared.resolveBusinessModule(businessId)
  if module and module.deleteKit then
    return module.deleteKit(businessId, kitId)
  end
  return false
end

M.applyKit = function(businessId, vehicleId, kitId)
  local module = shared.resolveBusinessModule(businessId)
  if module and module.applyKit then
    return module.applyKit(businessId, vehicleId, kitId)
  end
  return {
    success = false,
    error = "Module not found"
  }
end

-- Public exports: racing team dev console ---------------------------------------------------------

-- Calls the racing team's dev console method by name, or reports it unavailable.
local function callRacingTeamDevConsole(methodName, ...)
  local racingTeam = racingTeamModule()
  local method = racingTeam and racingTeam[methodName]
  if method then
    return method(...)
  end
  return { ok = false, error = "unavailable" }
end

M.devConsoleRacingTeamClearCooldowns = function(businessId)
  return callRacingTeamDevConsole("devConsoleClearCooldowns", businessId)
end

M.devConsoleRacingTeamRefreshRaceOffers = function(businessId)
  return callRacingTeamDevConsole("devConsoleRefreshRaceOffers", businessId)
end

M.devConsoleRacingTeamForceLeagueInvite = function(businessId)
  return callRacingTeamDevConsole("devConsoleForceLeagueInvite", businessId)
end

M.devConsoleRacingTeamCompleteCurrentGoal = function(businessId)
  return callRacingTeamDevConsole("devConsoleCompleteCurrentGoal", businessId)
end

M.devConsoleRacingTeamCompleteAllLeagueGoals = function(businessId)
  return callRacingTeamDevConsole("devConsoleCompleteAllLeagueGoals", businessId)
end

M.devConsoleRacingTeamResetCurrentLeagueGoals = function(businessId)
  return callRacingTeamDevConsole("devConsoleResetCurrentLeagueGoals", businessId)
end

M.devConsoleRacingTeamMaxAllSkills = function(businessId)
  return callRacingTeamDevConsole("devConsoleMaxAllSkills", businessId)
end

M.devConsoleRacingTeamGetDevLog = function(businessId)
  return callRacingTeamDevConsole("devConsoleGetDevLog", businessId)
end

M.devConsoleRacingTeamClearDevLog = function()
  return callRacingTeamDevConsole("devConsoleClearDevLog")
end

M.devConsoleRacingTeamResetBusiness = function(businessId)
  return callRacingTeamDevConsole("devConsoleResetBusiness", businessId)
end

M.devConsoleRacingTeamResetBusinessSoft = function(businessId)
  return callRacingTeamDevConsole("devConsoleResetBusinessSoft", businessId)
end

M.devConsoleRacingTeamResetBusinessHard = function(businessId)
  return callRacingTeamDevConsole("devConsoleResetBusinessHard", businessId)
end

M.devConsoleRacingTeamInjectXp = function(businessId)
  return callRacingTeamDevConsole("devConsoleInjectXp", businessId)
end

M.devConsoleRacingTeamInjectMoney = function(businessId)
  return callRacingTeamDevConsole("devConsoleInjectMoney", businessId)
end

-- Game hooks --------------------------------------------------------------------------------------

M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onUpdate = onUpdate

M.onExtensionUnloaded = onExtensionUnloaded

M.onOverhaulBeforeSetProfile = cancelCartPurchases
M.onOverhaulActive = function(active) if not active then cancelCartPurchases() end end

return M
