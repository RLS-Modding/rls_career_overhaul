-- Business computer actions: Engine Shop and passive business routing, part sales, racing team proxy races, jobs and techs.
-- Read Engine Shop, passive businesses, part sales, job acceptance, racing team proxy races, then jobs and techs.
local installer = {}

-- Each construction shares state and helpers with that owner load.
function installer.new(inputs)
  local api = {}
  local cache = inputs.cache
  local M = inputs.M

  -- Engine Shop --------------------------------------------------------------------------------------

  local function nameSet(names)
    local set = {}
    for _, name in ipairs(names) do set[name] = true end
    return set
  end

  -- The always-present bridge resolves every Engine Shop action, even when the UI booted before Engine Shop loaded.
  local engineShopDebugActions = nameSet({
    "debugAddRaw", "debugAdvanceCalendar", "debugForceCertification", "debugForceProduction",
  })
  local engineShopUIActions = nameSet({
    "assignLineBlueprint", "debugAddRaw", "debugAdvanceCalendar", "debugForceCertification", "debugForceProduction",
    "installWarehousePackage", "junkWarehousePackage", "openEnginePackages", "openMyParts", "openParts", "openRepair",
    "openTuning", "orderRawMaterials", "overhaulLine", "purchaseLineUpgrade", "purchaseUpgrade", "selectBayVehicle",
    "setBlueprintListed", "setBlueprintPrice", "setLineRunning", "startCertification",
  })

  function api.performEngineShopAction(methodName, businessId, ...)
    if not engineShopUIActions[methodName] then
      return {success = false, message = "Unknown Engine Shop action."}
    end
    if engineShopDebugActions[methodName] and not inputs.devConsole.isDevToolsEnabled() then
      return inputs.devConsole.devToolsDisabledResult()
    end
    local module = inputs.getBusinessModule("engineShop")
    local method = module and module[methodName]
    if type(method) ~= "function" then
      return {success = false, message = "Engine Shop action is unavailable."}
    end
    return method(businessId, ...)
  end

  function api.runEngineShopInvariantTests()
    if not inputs.devConsole.isDevToolsEnabled() then
      return inputs.devConsole.devToolsDisabledInvariantResult()
    end
    local module = inputs.getBusinessModule("engineShop")
    if module and type(module.runInvariantTests) == "function" then
      return module.runInvariantTests()
    end
    return {success = false, failures = {"Engine Shop module unavailable"}, checks = 0}
  end

  -- Passive businesses -------------------------------------------------------------------------------

  local function callPassiveBusiness(methodName, businessId, ...)
    local module = overhaul_career_business_passive
    local method = module and module[methodName]
    if not method then
      return {success = false, message = "Passive business manager is unavailable."}
    end
    return method(businessId, ...)
  end

  function api.getPassiveBusinessDashboardData(businessId)
    return callPassiveBusiness("getDashboardData", businessId)
  end
  function api.getPassiveBusinessFinanceData(businessId)
    return callPassiveBusiness("getFinanceData", businessId)
  end
  function api.collectPassiveBusinessEarnings(businessId)
    return callPassiveBusiness("collectEarnings", businessId)
  end
  function api.purchasePassiveBusinessStorageUpgrade(businessId)
    return callPassiveBusiness("purchaseStorageUpgrade", businessId)
  end
  function api.purchasePassiveBusinessWholesale(businessId)
    return callPassiveBusiness("purchaseWholesale", businessId)
  end
  function api.orderPassiveBusinessSupply(businessId, quantity)
    return callPassiveBusiness("orderSupply", businessId, quantity)
  end
  function api.setPassiveBusinessOperating(businessId, operating)
    return callPassiveBusiness("setOperating", businessId, operating)
  end
  function api.setPassiveBusinessSupplyRoute(businessId)
    return callPassiveBusiness("setSupplierRoute", businessId, true)
  end
  function api.requestPassiveBusinessSaleData(businessId)
    return callPassiveBusiness("requestSaleQuote", businessId)
  end
  function api.sellPassiveBusiness(businessId)
    return callPassiveBusiness("sellStore", businessId)
  end
  function api.closePassiveBusinessManagement(businessId)
    return callPassiveBusiness("closeManagementSession", businessId)
  end

  -- Part sales ---------------------------------------------------------------------------------------

  function api.requestPartInventory(businessId)
    if not businessId then
      guihooks.trigger('businessComputer:onPartInventoryData', {
        success = false,
        error = "Missing businessId"
      })
      return
    end

    local data = overhaul_career_business_partInventory.getUIData(businessId) or {}
    data.businessId = businessId
    data.success = true

    guihooks.trigger('businessComputer:onPartInventoryData', data)
  end

  local function getPartSaleAccountId(businessType, businessId)
    local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
    return account and account.id or nil
  end

  -- Pays a sale into the business account and refreshes the parts list. `sell` returns success and the amount.
  local function settlePartSale(businessId, businessType, description, sell)
    local accountId = getPartSaleAccountId(businessType, businessId)
    if not accountId then
      return false
    end

    local success, amount = sell()
    if not success or amount <= 0 then
      return false
    end

    overhaul_career_economy_bank.rewardToAccount({
      money = {
        amount = amount
      }
    }, accountId, "Sold Parts", description, require("overhaul/lib/finance/metadata").tag({category = "sale"}, "sale", {vehicleRelated = false}))
    ui_message(string.format("Sold parts $%s", tostring(math.floor(amount))), 3, "Parts Inventory", "info")

    api.requestPartInventory(businessId)

    return true
  end

  -- The vehicle model whose nice name (brand and name) matches, among this business's parts.
  local function findVehicleModelByNiceName(businessId, vehicleNiceName)
    local inventory = overhaul_career_business_partInventory.getInventory()
    for _, part in pairs(inventory) do
      if part and part.vehicleModel and tostring(part.businessId or "") == tostring(businessId) then
        local modelData = core_vehicles.getModel(part.vehicleModel)
        if modelData and modelData.model then
          local brand = modelData.model.Brand or ""
          local name = modelData.model.Name or part.vehicleModel
          local niceName = (brand .. " " .. name):match("^%s*(.-)%s*$")
          if niceName == vehicleNiceName then
            return part.vehicleModel
          end
        end
      end
    end
    return nil
  end

  function api.sellPart(businessId, partId)
    if not businessId or not partId then
      return false
    end

    local businessType = cache.businessContexts[businessId]
    if not businessType then
      return false
    end

    return settlePartSale(businessId, businessType, "Sold part", function()
      return overhaul_career_business_partInventory.sellPart(partId, businessId)
    end)
  end

  function api.sellAllParts(businessId)
    if not businessId then
      return false
    end

    local businessType = cache.businessContexts[businessId]
    if not businessType then
      return false
    end

    return settlePartSale(businessId, businessType, "Sold all parts", function()
      return overhaul_career_business_partInventory.sellAllParts(businessId)
    end)
  end

  function api.sellPartsByVehicle(businessId, vehicleNiceName)
    if not businessId or not vehicleNiceName then
      return false
    end

    local businessType = cache.businessContexts[businessId]
    if not businessType then
      return false
    end

    local vehicleModel = findVehicleModelByNiceName(businessId, vehicleNiceName)
    if not vehicleModel then
      return false
    end

    return settlePartSale(businessId, businessType, "Sold " .. vehicleNiceName .. " parts", function()
      return overhaul_career_business_partInventory.sellPartsByVehicle(vehicleModel, businessId)
    end)
  end

  -- Jobs ---------------------------------------------------------------------------------------------

  function api.acceptJob(businessId, jobId)
    local module, businessType = inputs.resolveBusinessModule(businessId)
    if module and module.acceptJob then
      local success = module.acceptJob(businessId, jobId)
      if success then
        local jobsData = M.getJobsOnly(businessId)
        local vehiclesData = M.getVehiclesOnly(businessId)
        guihooks.trigger('businessComputer:onJobAccepted', {
          businessType = businessType,
          businessId = businessId,
          jobId = jobId,
          activeJobs = jobsData.activeJobs,
          newJobs = jobsData.newJobs,
          maxActiveJobs = jobsData.maxActiveJobs,
          vehicles = vehiclesData.vehicles
        })
      end
      return success
    end
    return false
  end

  -- Racing team proxy races --------------------------------------------------------------------------

  function api.enterRacingTeamProxyStagingLoadingEarly()
    local trackFlow = overhaul_events_competitiveTrackFlow
    if trackFlow and trackFlow.enterRacingTeamProxyStagingLoadingEarly then
      trackFlow.enterRacingTeamProxyStagingLoadingEarly()
    end
  end
  function api.preflightRacingTeamProxySpectateUi(businessId)
    local trackFlow = overhaul_events_competitiveTrackFlow
    if trackFlow and trackFlow.preflightRacingTeamProxySpectateUi then
      trackFlow.preflightRacingTeamProxySpectateUi(businessId)
    end
  end
  function api.refreshRacingTeamProxySpectatorUiMinimal()
    local trackFlow = overhaul_events_competitiveTrackFlow
    if trackFlow and trackFlow.refreshRacingTeamProxySpectatorUiMinimalIfActive then
      trackFlow.refreshRacingTeamProxySpectatorUiMinimalIfActive()
    end
  end
  local function exitProxyStagingLoading(trackFlow)
    if trackFlow and trackFlow.exitRacingTeamProxyStagingLoadingScreen then
      trackFlow.exitRacingTeamProxyStagingLoadingScreen()
    end
  end

  function api.beginRacingTeamProxyRaceFromBusinessComputer(businessId)
    if not businessId then
      return { ok = false, err = "no_business" }
    end
    local racingTeamFlow = inputs.racingTeamRaceFlowModule()
    if racingTeamFlow and racingTeamFlow.beginRacingTeamProxyRaceFromBusinessComputer then
      return racingTeamFlow.beginRacingTeamProxyRaceFromBusinessComputer(businessId)
    end
    local trackFlow = overhaul_events_competitiveTrackFlow
    if not trackFlow or not trackFlow.beginRacingTeamProxyRaceFromBusinessComputer then
      return { ok = false, err = "no_track_flow" }
    end
    return trackFlow.beginRacingTeamProxyRaceFromBusinessComputer(businessId)
  end

  function api.simulateRacingTeamProxyRace(opts)
    if type(opts) ~= "table" then
      return { ok = false, err = "invalid_opts" }
    end
    local businessId = opts.businessId
    local module, businessType = inputs.resolveBusinessModule(businessId)
    if businessType ~= "racingTeam" or not module then
      return { ok = false, err = "not_racing_team" }
    end
    local racingTeamFlow = inputs.racingTeamRaceFlowModule()
    if racingTeamFlow and racingTeamFlow.simulateRacingTeamProxyRace then
      return racingTeamFlow.simulateRacingTeamProxyRace(opts)
    end
    local trackFlow = overhaul_events_competitiveTrackFlow
    local armOpts = {}
    for key, value in pairs(opts) do
      armOpts[key] = value
    end
    armOpts.spectateStaging = true
    local armRes = inputs.performBusinessAction({type = businessType, id = businessId}, "requestProxyDriverRace", armOpts)
    if not armRes or armRes.ok ~= true then
      exitProxyStagingLoading(trackFlow)
      return armRes or { ok = false, err = "request_failed" }
    end
    local beginRes = api.beginRacingTeamProxyRaceFromBusinessComputer(businessId)
    if type(beginRes) ~= "table" then
      exitProxyStagingLoading(trackFlow)
      return { ok = false, err = "begin_failed" }
    end
    if beginRes.ok ~= true then
      exitProxyStagingLoading(trackFlow)
    end
    return beginRes
  end

  function api.isProxyScheduledDriverFleetOverpowered(businessId, driverId)
    if not businessId or driverId == nil then
      return { overpowered = false }
    end
    local racingTeam = overhaul_career_business_racingTeam_racingTeam
    if not racingTeam or not racingTeam.isProxyScheduledDriverFleetOverpowered then
      return { overpowered = false }
    end
    return racingTeam.isProxyScheduledDriverFleetOverpowered(businessId, driverId) or { overpowered = false }
  end

  function api.isArmedProxyFleetOverpoweredForRequest(businessId)
    if not businessId then
      return { overpowered = false }
    end
    local racingTeam = overhaul_career_business_racingTeam_racingTeam
    if not racingTeam or not racingTeam.isArmedProxyFleetOverpoweredForRequest then
      return { overpowered = false }
    end
    return racingTeam.isArmedProxyFleetOverpoweredForRequest(businessId) or { overpowered = false }
  end

  function api.cancelRacingTeamProxySession(businessId)
    if not businessId then
      return { ok = false, err = "no_business" }
    end
    local request = inputs.performBusinessAction({type = "racingTeam", id = businessId}, "getProxyDriverRaceRequest")
    local fleetVehicleId = request and (tonumber(request.fleetVehicleId) or request.fleetVehicleId)
    local host = overhaul_events_host
    local trackFlow = overhaul_events_competitiveTrackFlow
    local rideAlong = overhaul_career_business_racingTeam_rideAlong
    local fleet = overhaul_career_business_fleet
    local abandoned = false
    if host and host.forceAbandonActiveTrackRace then
      abandoned = host.forceAbandonActiveTrackRace("Team race cancelled") == true
    end
    if not abandoned then
      if trackFlow and trackFlow.cancelCompetitiveGridFlow then
        trackFlow.cancelCompetitiveGridFlow()
      end
      if host and host.clearSanctionedDispatchStaging then
        host.clearSanctionedDispatchStaging()
      end
      if trackFlow and trackFlow.leaveTrackFlowAfterRace then
        trackFlow.leaveTrackFlowAfterRace()
      end
      if rideAlong and rideAlong.endRideAlongSession then
        rideAlong.endRideAlongSession()
      end
      if rideAlong and rideAlong.hasPreRaceWorldState and rideAlong.hasPreRaceWorldState() and rideAlong.restorePreRaceWorldState then
        rideAlong.restorePreRaceWorldState()
      end
      if fleetVehicleId and fleet and fleet.removeBusinessVehicleObject then
        fleet.removeBusinessVehicleObject(businessId, fleetVehicleId)
      end
    end
    local racingTeam = overhaul_career_business_racingTeam_racingTeam
    if racingTeam and racingTeam.clearRacingTeamProxyDriverAssignment then
      racingTeam.clearRacingTeamProxyDriverAssignment(businessId, { returnOfferToBoard = true, refundEntryFee = true, proxyRequest = request })
    end
    inputs.performBusinessAction({type = "racingTeam", id = businessId}, "clearProxyDriverRaceRequest")
    if trackFlow and trackFlow.relayRacingTeamProxyOverlay then
      trackFlow.relayRacingTeamProxyOverlay({ visible = false })
    else
      guihooks.trigger("racingTeamProxyOverlay", { visible = false })
    end
    local module = overhaul_career_business_racingTeam_racingTeam
    if module and module.getUIData then
      local uiData = module.getUIData(businessId)
      guihooks.trigger("businessComputer:onRaceOffersUpdated", {
        businessId = businessId,
        raceOffers = uiData and uiData.raceOffers or {},
        raceOffersLevelId = uiData and uiData.raceOffersLevelId,
        raceOffersNextRefreshAt = uiData and uiData.raceOffersNextRefreshAt,
        raceOffersMessage = uiData and uiData.raceOffersMessage,
        racingTeamProxyArmed = uiData and uiData.racingTeamProxyArmed,
      })
    end
    return { ok = true }
  end

  function api.cancelRacingTeamProxyScheduledRace(businessId, driverId)
    businessId = tonumber(businessId) or businessId
    driverId = tonumber(driverId)
    if not businessId or not driverId then
      return { ok = false, err = "missing_business_or_driver" }
    end
    local request = inputs.performBusinessAction({type = "racingTeam", id = businessId}, "getProxyDriverRaceRequest")
    if request and request.racingTeamProxyRace == true and tonumber(request.driverId) == driverId then
      return api.cancelRacingTeamProxySession(businessId)
    end
    local racingTeam = overhaul_career_business_racingTeam_racingTeam
    if not racingTeam or not racingTeam.cancelUnarmedScheduledRacingTeamProxyRace then
      return { ok = false, err = "no_racing_team" }
    end
    return racingTeam.cancelUnarmedScheduledRacingTeamProxyRace(businessId, driverId)
  end

  function api.isScheduledRaceReadyForDriver(businessId, techId)
    local module = overhaul_career_business_racingTeam_racingTeam
    if not module or not module.isScheduledRaceReadyForDriver then
      return true
    end
    return module.isScheduledRaceReadyForDriver(businessId, techId)
  end

  function api.getRacingTeamCareerSimTime()
    local racingTeam = overhaul_career_business_racingTeam_racingTeam
    if racingTeam and racingTeam.getCareerSimTimeForUI then
      return racingTeam.getCareerSimTimeForUI()
    end
    return nil
  end
  function api.tickRacingTeamScheduledRaceToasts()
    local racingTeam = overhaul_career_business_racingTeam_racingTeam
    if racingTeam and racingTeam.tickScheduledRaceReadyToasts then
      racingTeam.tickScheduledRaceReadyToasts()
    end
  end

  -- Jobs and techs ----------------------------------------------------------------------------------

  function api.declineJob(businessId, jobId)
    local module, businessType = inputs.resolveBusinessModule(businessId)
    if module and module.declineJob then
      local success = module.declineJob(businessId, jobId)
      if success then
        local jobsData = M.getJobsOnly(businessId)
        guihooks.trigger('businessComputer:onJobDeclined', {
          businessType = businessType,
          businessId = businessId,
          jobId = jobId,
          newJobs = jobsData.newJobs
        })
      end
      return success
    end
    return false
  end

  function api.abandonJob(businessId, jobId)
    local module, businessType = inputs.resolveBusinessModule(businessId)
    if module and module.abandonJob then
      local finished = false
      local function onComplete(success)
        if finished then return end
        finished = true
        local jobsData = M.getJobsOnly(businessId)
        if not success then
          jobsData.businessType = businessType
          guihooks.trigger('businessComputer:onJobsUpdated', jobsData)
          return
        end
        local vehiclesData = M.getVehiclesOnly(businessId)
        guihooks.trigger('businessComputer:onJobAbandoned', {
          businessType = businessType,
          businessId = businessId,
          jobId = jobId,
          activeJobs = jobsData.activeJobs,
          vehicles = vehiclesData.vehicles,
          pulledOutVehicles = vehiclesData.pulledOutVehicles
        })
      end
      local success = module.abandonJob(businessId, jobId, onComplete)
      -- Synchronous business modules can still report their outcome by return value.
      if success ~= nil then onComplete(success) end
      return success
    end
    return false
  end

  function api.sellVehicle(businessId, vehicleId)
    local module, businessType = inputs.resolveBusinessModule(businessId)
    if not module or not module.sellVehicle then
      return false
    end
    local success = module.sellVehicle(businessId, vehicleId)
    if success then
      local vehiclesData = M.getVehiclesOnly(businessId)
      guihooks.trigger('businessComputer:onVehicleSold', {
        businessType = businessType,
        businessId = businessId,
        vehicleId = vehicleId,
        vehicles = vehiclesData.vehicles,
        pulledOutVehicles = vehiclesData.pulledOutVehicles
      })
    end
    return success
  end

  function api.assignTechToJob(businessId, techId, jobId)
    if not businessId or not techId or not jobId then
      return false
    end

    local businessType = cache.businessContexts[businessId]
    if not businessType then
      return false
    end

    local module = inputs.getBusinessModule(businessType)
    if module and module.assignJobToTech then
      local ok, result = pcall(module.assignJobToTech, businessId, techId, jobId)
      if not ok then
        log('E', 'businessComputer', 'assignTechToJob failed: ' .. tostring(result))
        return false
      end
      if result then
        local jobsData = M.getJobsOnly(businessId)
        local techsData = M.getTechsOnly(businessId)
        guihooks.trigger('businessComputer:onTechAssigned', {
          businessType = businessType,
          businessId = businessId,
          techId = techId,
          jobId = jobId,
          activeJobs = jobsData.activeJobs,
          techs = techsData.techs
        })
      end
      return result
    end

    return false
  end

  function api.renameTech(businessId, techId, newName)
    if not businessId or not techId then
      return false
    end

    local businessType = cache.businessContexts[businessId]
    if not businessType then
      return false
    end

    local module = inputs.getBusinessModule(businessType)
    if module and module.updateTechName then
      local ok, result = pcall(module.updateTechName, businessId, techId, newName)
      if not ok then
        log('E', 'businessComputer', 'renameTech failed: ' .. tostring(result))
        return false
      end
      return result
    end

    return false
  end

  return api
end

return installer
