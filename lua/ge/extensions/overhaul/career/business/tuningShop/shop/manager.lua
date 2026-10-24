-- Manager assignment cadence and operating costs for one tuning shop.
-- Read timer state, assignment steps, operating charges and public services.
local businessSaveState = require("overhaul/lib/business/saveState")
local installer = {}

-- Parts -------------------------------------------------------------------------------------------
function installer.new(inputs)
  -- State and callbacks ---------------------------------------------------------------------------
  local parts = inputs.parts
  local shop = inputs.shop
  local tuningShopTechs = inputs.tuningShopTechs

  -- Saved manager timers ----------------------------------------------------------------------------

  local function getManagerTimerPath(businessId)
    if not overhaul_career_career.isActive() then return nil end
    local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
    if not currentSavePath then return nil end
    return businessSaveState.businessFilePath(businessId .. "", "manager.json", currentSavePath .. "")
  end

  local function loadManagerTimer(businessId)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      return {
        elapsed = 0,
        flagActive = false,
        paused = false
      }
    end

    if shop.managerTimers[businessId] then
      if shop.managerTimers[businessId].paused == nil then
        shop.managerTimers[businessId].paused = false
      end
      return shop.managerTimers[businessId]
    end

    local filePath = getManagerTimerPath(businessId)
    if not filePath then
      shop.managerTimers[businessId] = {
        elapsed = 0,
        flagActive = false,
        paused = false
      }
      return shop.managerTimers[businessId]
    end

    local data = jsonReadFile(filePath) or {}
    shop.managerTimers[businessId] = {
      elapsed = tonumber(data.elapsed) or 0,
      flagActive = data.flagActive == true,
      paused = data.paused == true
    }
    return shop.managerTimers[businessId]
  end

  local function saveManagerTimer(businessId, currentSavePath, writer)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId or not shop.managerTimers[businessId] then return end
    if not currentSavePath then return end

    local filePath = businessSaveState.businessFilePath(businessId .. "", "manager.json", currentSavePath .. "")

    local dirPath = string.match(filePath, "^(.*)/[^/]+$")
    if dirPath and not writer.exists(dirPath) then
      writer.mkdir(dirPath)
    end

    local data = {
      elapsed = shop.managerTimers[businessId].elapsed,
      flagActive = shop.managerTimers[businessId].flagActive,
      paused = shop.managerTimers[businessId].paused == true
    }

    overhaul_career_saveSystem.jsonWriteFileSafe(filePath, data, true)
  end

  -- Manager upgrades and cadence --------------------------------------------------------------------

  local function hasManager(businessId)
    if not businessId then return false end
    local level = overhaul_career_business_skillTree.getNodeProgress(businessId, "automation", "manager")
    return level and level > 0
  end

  local function hasGeneralManager(businessId)
    if not businessId then return false end
    local level = overhaul_career_business_skillTree.getNodeProgress(businessId, "automation", "general-manager")
    return level and level > 0
  end

  local function getManagerAssignmentInterval(businessId)
    local baseInterval = 1800
    if not businessId then return baseInterval end

    local speedLevel =
      overhaul_career_business_skillTree.getNodeProgress(businessId, "automation", "manager-speed") or 0
    local interval = baseInterval - (speedLevel * 120)
    return math.max(600, interval)
  end

  local function getManagerTimerState(businessId)
    if not businessId then
      return {
        elapsed = 0,
        flagActive = false,
        paused = false
      }
    end
    local state = loadManagerTimer(businessId)
    if state.paused == nil then
      state.paused = false
    end
    return state
  end

  local function setManagerPaused(businessId, paused)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then return false end

    if not hasManager(businessId) then return false end

    local timerState = getManagerTimerState(businessId)
    timerState.paused = paused == true

    if not shop.managerTimers[businessId] then
      shop.managerTimers[businessId] = timerState
    else
      shop.managerTimers[businessId].paused = paused == true
    end

    local pausedState = paused == true
    guihooks.trigger('tuningShopManagerUpdated', {businessId = businessId, paused = pausedState})
    return true, pausedState
  end

  -- Timer updates -----------------------------------------------------------------------------------

  local function processManagerTimers(businessId, dtSim)
    if not businessId or dtSim <= 0 then return false end

    if not hasManager(businessId) then return false end

    if hasGeneralManager(businessId) then return false end

    local timerState = getManagerTimerState(businessId)

    if timerState.paused then return false end

    local interval = getManagerAssignmentInterval(businessId)

    timerState.elapsed = timerState.elapsed + dtSim

    local changed = false
    if timerState.elapsed >= interval then
      timerState.flagActive = true
      timerState.elapsed = 0
      changed = true
    end

    shop.managerTimers[businessId] = timerState
    return changed
  end

  -- Operating timer state ---------------------------------------------------------------------------

  local function loadOperatingCostTimer(businessId)
    businessId = parts.garage.normalizeBusinessId(businessId)
    if not businessId then
      return {
        elapsed = 0,
        lastChargeTime = nil
      }
    end

    if shop.operatingCostTimers[businessId] == nil then
      parts.persist.initializeBusinessData(businessId)
    end

    return shop.operatingCostTimers[businessId] or { elapsed = 0, lastChargeTime = nil }
  end

  -- Manager assignment ------------------------------------------------------------------------------

  local function selectManagerJob(businessId, jobs)
    local techMaxTier = tuningShopTechs.getTechMaxTier(businessId)
    local managerBlacklist = parts.selections.getManagerBlacklist(businessId)
    local suitableJob = nil

    for _, newJob in ipairs(jobs.new) do
      local jobTier = tonumber(newJob.tier) or 1
      if jobTier <= techMaxTier then
        local jobModelKey = newJob.vehicleConfig and newJob.vehicleConfig.model_key
        if jobModelKey and managerBlacklist[jobModelKey] then
          goto continue
        end
        suitableJob = newJob
        break
      end
      ::continue::
    end

    if not suitableJob then return nil end

    local jobId = tonumber(suitableJob.jobId) or suitableJob.jobId
    if not jobId then return nil end

    return jobId
  end

  local function assignManagerJob(businessId, jobId, idleTechs, timerState, isGeneralManager)
    local acceptSuccess = parts.settlement.acceptJob(businessId, jobId)
    if not acceptSuccess then return false end

    local idleTech = idleTechs[1]
    if not idleTech then return false end

    local assignSuccess = tuningShopTechs.assignJobToTech(businessId, idleTech.id, jobId)
    if not assignSuccess then return false end

    if not isGeneralManager then
      timerState.flagActive = false
      shop.managerTimers[businessId] = timerState
    end

    return true
  end

  local function processManagerAssignments(businessId)
    if not businessId then return false end
    if not hasManager(businessId) then return false end
    local timerState = getManagerTimerState(businessId)
    if timerState.paused == true then return false end
    local isGeneralManager = hasGeneralManager(businessId)
    local flagActive = isGeneralManager or timerState.flagActive
    if not flagActive then return false end
    local idleTechs = tuningShopTechs.getIdleTechs(businessId)
    if #idleTechs == 0 then return false end
    if not tuningShopTechs.canAssignTechToJob(businessId) then return false end
    local jobs = parts.persist.loadBusinessJobs(businessId)
    if not jobs.new or #jobs.new == 0 then return false end
    local maxActiveJobs = parts.settlement.getMaxActiveJobs(businessId)
    local currentActiveCount = #(jobs.active or {})
    if currentActiveCount >= maxActiveJobs then return false end
    local jobId = selectManagerJob(businessId, jobs)
    if not jobId then return false end
    return assignManagerJob(businessId, jobId, idleTechs, timerState, isGeneralManager)
  end

  -- Operating costs ---------------------------------------------------------------------------------

  local function readOperatingUpgrades(businessId)
    local additionalLifts, managerCost, generalManagerCost, solarPowerActive = 0, 0, 0, false
    local treeId = "shop-upgrades"

    local lift2Level = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, "lift-2") or 0
    local lift3Level = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, "lift-3") or 0
    local lift4Level = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, "lift-4") or 0

    if lift2Level > 0 then
      additionalLifts = additionalLifts + 1
    end
    if lift3Level > 0 then
      additionalLifts = additionalLifts + 1
    end
    if lift4Level > 0 then
      additionalLifts = additionalLifts + 1
    end

    local solarLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, "solar-panels") or
                         0
    solarPowerActive = solarLevel > 0

    local automationTreeId = "automation"
    local managerLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, automationTreeId,
      "manager") or 0
    local generalManagerLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, automationTreeId,
      "general-manager") or 0

    if managerLevel > 0 then
      managerCost = 5000
    end
    if generalManagerLevel > 0 then
      generalManagerCost = 25000
    end

    return additionalLifts, managerCost, generalManagerCost, solarPowerActive
  end

  local function countWorkingTechs(businessId)
    local techList = tuningShopTechs.getTechsForBusiness(businessId) or {}
    local techCount = 0
    for _, tech in ipairs(techList) do
      if not tech.fired then techCount = techCount + 1 end
    end
    return techCount
  end

  local function getOperatingCosts(businessId)
    if not businessId then
      return {baseLift = 5000, additionalLifts = 0, techs = 0, manager = 0,
        generalManager = 0, total = 5000, maxCost = 55000, solarPowerActive = false}
    end
    local baseLift = 5000
    local additionalLifts, managerCost, generalManagerCost, solarPowerActive = readOperatingUpgrades(businessId)
    local techCount = countWorkingTechs(businessId)
    local techsCost = techCount * 2500
    local additionalLiftsCost = additionalLifts * 5000
    local total = baseLift + additionalLiftsCost + techsCost + managerCost + generalManagerCost
    local maxCost = 55000
    if solarPowerActive then total = 0 end
    return {baseLift = baseLift, additionalLifts = additionalLifts, additionalLiftsCost = additionalLiftsCost,
      techs = techCount, techsCost = techsCost, manager = managerCost > 0 and 1 or 0,
      managerCost = managerCost, generalManager = generalManagerCost > 0 and 1 or 0,
      generalManagerCost = generalManagerCost, total = total, maxCost = maxCost, solarPowerActive = solarPowerActive}
  end

  local function processOperatingCosts(businessId, dtSim)
    if not businessId or dtSim <= 0 then return false end

    local operatingCosts = getOperatingCosts(businessId)
    if operatingCosts.solarPowerActive or operatingCosts.total <= 0 then return false end

    local timerState = loadOperatingCostTimer(businessId)
    local paymentInterval = 1800

    timerState.elapsed = timerState.elapsed + dtSim

    local charged = false
    if timerState.elapsed >= paymentInterval then
      local currentTime = os.time()
      local success = parts.settlement.debitBusinessAccount(businessId, operatingCosts.total, "Operating Costs",
        string.format("Operating costs: Base Lift $%d, Additional Lifts $%d, Techs $%d, Manager $%d, General Manager $%d",
          operatingCosts.baseLift, operatingCosts.additionalLiftsCost, operatingCosts.techsCost,
          operatingCosts.managerCost, operatingCosts.generalManagerCost), true)

      if success then
        timerState.elapsed = math.max(0, timerState.elapsed - paymentInterval)
        timerState.lastChargeTime = currentTime
        charged = true
      else
        timerState.elapsed = 0
      end
    end

    shop.operatingCostTimers[businessId] = timerState
    return charged
  end

  -- UI projections ----------------------------------------------------------------------------------

  local function getTechData(businessId)
    if not businessId then return nil end

    local techs = tuningShopTechs.getTechsForBusiness(businessId)
    local formattedTechs = {}
    for _, tech in ipairs(techs) do
      local formatted = tuningShopTechs.formatTechForUIEntry(businessId, tech)
      if formatted then
        table.insert(formattedTechs, formatted)
      end
    end

    return {
      businessId = tostring(businessId),
      techs = formattedTechs
    }
  end

  local function getManagerData(businessId)
    if not businessId or not hasManager(businessId) then return nil end

    local timerState = getManagerTimerState(businessId)
    local interval = getManagerAssignmentInterval(businessId)
    local generalManager = hasGeneralManager(businessId)

    return {
      businessId = tostring(businessId),
      elapsed = timerState.elapsed,
      interval = interval,
      available = timerState.flagActive or (timerState.elapsed >= interval),
      nextAvailableIn = math.max(0, interval - timerState.elapsed),
      hasGeneralManager = generalManager,
      -- fields the Techs and Drivers tabs refresh from
      hasManager = true,
      managerAssignmentInterval = interval,
      managerReadyToAssign = generalManager or timerState.flagActive == true,
      managerTimeRemaining = not generalManager and math.max(0, interval - timerState.elapsed) or nil,
      managerPaused = timerState.paused == true
    }
  end

  -- Public services -------------------------------------------------------------------------------
  return {
    getManagerAssignmentInterval = getManagerAssignmentInterval,
    getManagerData = getManagerData,
    getManagerTimerState = getManagerTimerState,
    getOperatingCosts = getOperatingCosts,
    getTechData = getTechData,
    hasGeneralManager = hasGeneralManager,
    hasManager = hasManager,
    loadManagerTimer = loadManagerTimer,
    loadOperatingCostTimer = loadOperatingCostTimer,
    processManagerAssignments = processManagerAssignments,
    processManagerTimers = processManagerTimers,
    processOperatingCosts = processOperatingCosts,
    saveManagerTimer = saveManagerTimer,
    setManagerPaused = setManagerPaused,
  }
end

return installer
