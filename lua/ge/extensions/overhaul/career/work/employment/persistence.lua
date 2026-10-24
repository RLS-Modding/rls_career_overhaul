-- Employment cache, rehire blocks, saved freight and profile persistence.
-- Reading order: save adapter, rehire blocks, map cache, kind recovery, save/load and construction.
local part = {}

-- Save feature -----------------------------------------------------------------------------------

local function addSaveFeatureApi(api, inputs)
  local runtime, saveFile = inputs.runtime, inputs.saveFile

  api.persistenceFeature = function()
    local saveSystem = overhaul_career_saveSystem
    if runtime.saveFeature and runtime.saveFeatureSystem == saveSystem and runtime.saveFeature.isCurrent() then return runtime.saveFeature end
    if runtime.saveFeature then runtime.saveFeature.dispose() end
    runtime.saveFeatureSystem = saveSystem
    runtime.saveFeature = assert(require('overhaul/lib/save/store').bind(saveSystem).feature('work.employment', {
      owner = 'overhaul_career_work_employment', files = {saveFile:sub(2)},
      root = 'slot', phase = 'profile', required = true, writer = {pretty = true},
    }))
    return runtime.saveFeature
  end
end

-- Kind outcome -----------------------------------------------------------------------------------

-- A kind outcome belongs to one shift record, so a later shift of the same kind is judged on its own.
local function addKindOutcomeApi(api, inputs)
  local runtime, shared, state = inputs.runtime, inputs.shared, inputs.state

  api.checkSavedKind = function()
    runtime.kindLoadOutcome, runtime.kindLoadOutcomeShift = nil, nil
    if not state.shift then return end
    if not runtime.kindCatalog then runtime.kindCatalog = shared.jobKinds.load() end
    runtime.kindLoadOutcome, runtime.kindLoadOutcomeShift = shared.jobKinds.outcome(runtime.kindCatalog, state.shift.jobKind), state.shift
    return runtime.kindLoadOutcome
  end

  api.savedKindUnavailable = function()
    local outcome = api.currentKindLoadOutcome()
    return outcome ~= nil and outcome.status == 'missingKind'
  end

  api.currentKindLoadOutcome = function()
    if state.shift == nil or state.shift ~= runtime.kindLoadOutcomeShift then return nil end
    return runtime.kindLoadOutcome
  end
end

-- Rehire blocks ----------------------------------------------------------------------------------

local function addRehireApi(api, inputs)
  local config, shared, state = inputs.config, inputs.shared, inputs.state

  api.setRehireBlock = function(orgId)
    if not orgId then return end
    local now = shared.nowWorldMinutes()
    if now == nil then return end
    orgId = tostring(orgId)
    state.rehireBlockedUntil[orgId] = now + config.REHIRE_COOLDOWN_DAYS * config.WORLD_MINUTES_PER_DAY
  end

  api.clearRehireBlock = function(orgId)
    if not orgId or not state.rehireBlockedUntil then return end
    state.rehireBlockedUntil[tostring(orgId)] = nil
  end

  api.getRehireBlockUntil = function(orgId)
    if not orgId then return nil end
    local now = shared.nowWorldMinutes()
    if now == nil then return nil end
    local blockedUntilWorldMinute = tonumber(state.rehireBlockedUntil[tostring(orgId)])
    if blockedUntilWorldMinute and blockedUntilWorldMinute > now then
      return blockedUntilWorldMinute
    end
    return nil
  end

  api.canRehireOrg = function(orgId)
    return api.getRehireBlockUntil(orgId) == nil
  end

  api.ensureRehireSaveV3 = function()
    if state._rehireV3Done then return end
    state._rehireV3Done = true
    if (tonumber(state.version) or 1) < 3 then
      state.rehireBlockedUntil = {}
      state.version = config.SAVE_VERSION
    end
  end

  -- Older saves used the simulation clock; preserve the remaining cooldown on the world clock.
  api.applyPendingLastWorkRefresh = function(nowWorldMinute)
    if not state.refreshLastWorkAt then return end
    nowWorldMinute = tonumber(nowWorldMinute) or shared.nowWorldMinutes()
    if nowWorldMinute == nil then return end
    local nowSimSeconds = shared.nowSim()
    for orgId, blockedUntilSimSeconds in pairs(state.rehireBlockedUntil or {}) do
      local remainingSimSeconds = (tonumber(blockedUntilSimSeconds) or 0) - nowSimSeconds
      if remainingSimSeconds > 0 then
        state.rehireBlockedUntil[orgId] = nowWorldMinute + remainingSimSeconds / config.SIM_SECONDS_PER_GAME_DAY * config.WORLD_MINUTES_PER_DAY
      else
        state.rehireBlockedUntil[orgId] = nil
      end
    end
    state.refreshLastWorkAt = nil
    if state.employerOrgId then
      state.lastWorkAt = nowSimSeconds
      state.lastWorkWorldMinute = nowWorldMinute
    end
    for _, employment in pairs(state.employments or {}) do
      if employment and employment.employerOrgId then
        employment.lastWorkAt = nowSimSeconds
        employment.lastWorkWorldMinute = nowWorldMinute
      end
    end
    api.flushEmploymentCache()
  end
end

-- Per-map cache ----------------------------------------------------------------------------------

local function addCacheApi(api, inputs)
  local hiring, lifecycle, runtime, shared, state = inputs.hiring, inputs.lifecycle, inputs.runtime, inputs.shared, inputs.state

  api.flushEmploymentCache = function()
    if not state.activeMapId or state.activeMapId == "" then
      state.activeMapId = shared.currentMapId()
    end
    local mapId = state.activeMapId
    if not mapId or mapId == "" then return end
    local pendingApplication = state.pendingApplications and state.pendingApplications[1]
    if state.employerOrgId then
      state.employments[mapId] = {
        employerOrgId = state.employerOrgId,
        homeFacId = state.homeFacId,
        hiredAt = state.hiredAt,
        lastWorkAt = state.lastWorkAt or state.hiredAt,
        hiredWorldMinute = state.hiredWorldMinute,
        lastWorkWorldMinute = state.lastWorkWorldMinute or state.hiredWorldMinute,
        pendingApplications = state.pendingApplications or {},
        shift = state.shift,
        escrow = state.escrow or { money = 0, legs = {} },
        completedAssignments = state.completedAssignments or 0,
        damageRecord = state.damageRecord or { strikes = 0 },
      }
    elseif state.shift or pendingApplication then
      local pendingFacId = pendingApplication and state.pendingApplications[1].facId or nil
      state.employments[mapId] = {
        employerOrgId = nil,
        homeFacId = (state.shift and state.shift.originFacId) or state.homeFacId or pendingFacId,
        hiredAt = nil,
        lastWorkAt = state.lastWorkAt,
        hiredWorldMinute = nil,
        lastWorkWorldMinute = state.lastWorkWorldMinute,
        pendingApplications = state.pendingApplications or {},
        shift = state.shift,
        escrow = state.escrow or { money = 0, legs = {} },
        completedAssignments = state.completedAssignments or 0,
        damageRecord = state.damageRecord or { strikes = 0 },
      }
    else
      state.employments[mapId] = nil
    end
  end

  api.saveEmploymentProgress = function()
    api.flushEmploymentCache()
    overhaul_career_saveSystem.saveCurrent()
  end

  api.clearEmploymentCache = function()
    state.employerOrgId = nil
    state.homeFacId = nil
    state.hiredAt = nil
    state.lastWorkAt = nil
    state.hiredWorldMinute = nil
    state.lastWorkWorldMinute = nil
    state.pendingApplications = {}
    state.shift = nil
    runtime.bindAssignedInFlight = false
    state.escrow = { money = 0, legs = {} }
    state.completedAssignments = 0
    state.damageRecord = { strikes = 0 }
  end

  api.loadEmploymentCache = function(mapId, skipFlush)
    mapId = mapId or shared.currentMapId()
    if state.activeMapId and state.activeMapId ~= mapId then
      if not skipFlush then
        api.flushEmploymentCache()
      end
      hiring.clearOfferedListings()
    end
    state.activeMapId = mapId
    if not mapId or mapId == "" then
      api.clearEmploymentCache()
      return
    end
    local employment = state.employments[mapId]
    if employment and employment.employerOrgId then
      state.employerOrgId = employment.employerOrgId
      state.homeFacId = employment.homeFacId
      state.hiredAt = employment.hiredAt
      state.lastWorkAt = employment.lastWorkAt or employment.hiredAt
      state.hiredWorldMinute = employment.hiredWorldMinute
      state.lastWorkWorldMinute = employment.lastWorkWorldMinute or employment.hiredWorldMinute
      state.pendingApplications = employment.pendingApplications or {}
      state.shift = employment.shift
      state.escrow = employment.escrow or { money = 0, legs = {} }
      state.completedAssignments = employment.completedAssignments or 0
      state.damageRecord = employment.damageRecord or { strikes = 0 }
    elseif employment and (employment.shift or (employment.pendingApplications and employment.pendingApplications[1])) then
      api.clearEmploymentCache()
      state.homeFacId = employment.homeFacId
      state.lastWorkAt = employment.lastWorkAt
      state.lastWorkWorldMinute = employment.lastWorkWorldMinute
      state.pendingApplications = employment.pendingApplications or {}
      state.shift = employment.shift
      state.escrow = employment.escrow or { money = 0, legs = {} }
      state.completedAssignments = employment.completedAssignments or 0
      state.damageRecord = employment.damageRecord or { strikes = 0 }
    else
      api.clearEmploymentCache()
    end
    if state.damageRecord.strikes == nil and (state.damageRecord.warnings or state.damageRecord.completedRuns) then
      state.damageRecord = { strikes = tonumber(state.damageRecord.warnings) or 0 }
    end
    if not state.shift then
      state.damageRecord = { strikes = 0 }
    end
  end

  api.touchLastWorkAt = function()
    if not lifecycle.isEmployed() then return end
    state.lastWorkAt = shared.nowSim()
    local nowWorldMinute = shared.nowWorldMinutes()
    if nowWorldMinute ~= nil then
      state.lastWorkWorldMinute = nowWorldMinute
    end
    api.flushEmploymentCache()
  end

  api.employmentShiftBlocksInactivity = function(mapId, employment)
    if employment and employment.shift then return true end
    if not mapId then return false end
    if mapId ~= (state.activeMapId or shared.currentMapId()) then return false end
    return state.shift ~= nil
  end
end

-- Save data migration ----------------------------------------------------------------------------

local function addMigrationApi(api, inputs)
  local config, shared = inputs.config, inputs.shared

  api.migrateEmploymentSaveData = function(data)
    data = data or {}
    local version = tonumber(data.version) or 1
    if version < 2 then
      data.employments = data.employments or {}
      if data.employerOrgId and not next(data.employments) then
        local mapId = data.homeMapId or shared.currentMapId()
        if mapId and mapId ~= "" then
          data.employments[mapId] = {
            employerOrgId = data.employerOrgId,
            homeFacId = data.homeFacId,
            hiredAt = data.hiredAt,
            lastWorkAt = data.lastWorkAt or data.hiredAt,
            pendingApplications = data.pendingApplications or {},
            shift = data.shift,
            escrow = data.escrow or { money = 0, legs = {} },
            completedAssignments = tonumber(data.completedAssignments) or 0,
            damageRecord = data.damageRecord or { strikes = 0 },
          }
        end
      end
      for _, employment in pairs(data.employments) do
        if type(employment) == "table" and employment.damageRecord
            and employment.damageRecord.strikes == nil
            and (employment.damageRecord.warnings or employment.damageRecord.completedRuns) then
          employment.damageRecord = { strikes = tonumber(employment.damageRecord.warnings) or 0 }
        end
      end
      version = 2
    end
    if version < 3 then
      data.rehireBlockedUntil = {}
      version = 3
    end
    if version < 4 then
      data.refreshLastWorkAt = true
      version = 4
    end
    if version < 5 then
      data.refreshLastWorkAt = true
      version = 5
    end
    if version < 6 then
      for _, employment in pairs(data.employments or {}) do
        if type(employment) == "table" and not employment.shift then
          employment.damageRecord = { strikes = 0 }
        end
      end
      version = 6
    end
    data.version = config.SAVE_VERSION
    return data
  end
end

-- Shift recovery on load -------------------------------------------------------------------------

local function addRecoveryApi(api, inputs)
  local endDay, projections, shared, state = inputs.endDay, inputs.projections, inputs.shared, inputs.state

  api.softClearStickyShift = function(reason)
    if not state.shift then return false end
    shared.shiftLog("softClearStickyShift", tostring(reason or "irrecoverable"))
    local removed = endDay.clearShiftKeepEmployment()
    projections.firePhoneNotification(
      "employment.shiftEnded",
      "Shift cleared",
      "Company equipment returned. You are still employed — clock in for a new assignment.",
      "info")
    ui_message(
      string.format(
        "Could not recover that shift (%d truck%s returned). You are still employed.",
        removed,
        removed == 1 and "" or "s"),
      8,
      "warning")
    projections.notifyUi()
    projections.closeShiftUi()
    projections.closeDropOffUi()
    return true
  end

  api.abortInterruptedShiftOnLoad = function()
    if api.savedKindUnavailable() then return false end
    return inputs.recovery.abortInterruptedShiftOnLoad()
  end

  -- Called for every cargo item of a save; the lookup needs no recovery context.
  api.isAssignedFreight = require("overhaul/career/work/employment/shiftRecovery").isAssignedFreight

  api.reconcileLoadedShift = function()
    if api.savedKindUnavailable() then return false end
    return inputs.recovery.reconcileLoadedShift()
  end
end

-- Save and load ---------------------------------------------------------------------------------

local function addSaveLoadApi(api, inputs)
  local config, recovery, runtime, state = inputs.config, inputs.recovery, inputs.runtime, inputs.state

  function api.loadState()
    runtime.loadedShiftReconciled = nil
    runtime.headhunterCheckContext = nil
    local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
    if not currentSavePath then return end
    local data = api.migrateEmploymentSaveData(jsonReadFile(api.persistenceFeature().path(currentSavePath)) or {})
    state.version = config.SAVE_VERSION
    state.employments = data.employments or {}
    state.rehireBlockedUntil = data.rehireBlockedUntil or {}
    state.activeMapId = data.activeMapId
    state.offeredFacIds = data.offeredFacIds or data.offeredOrgIds or {}
    state.offeredListingsAt = data.offeredListingsAt
    state.headhunter = data.headhunter or { offered = {}, pending = nil }
    state.headhunter.offered = state.headhunter.offered or {}
    state.refreshLastWorkAt = data.refreshLastWorkAt and true or nil
    api.loadEmploymentCache(inputs.shared.currentMapId(), true)
    api.checkSavedKind()
    state.restoringFreight = state.shift and (state.shift.freight or state.shift.plannerFreight) and true or nil
    if data.pendingApplications and data.pendingApplications[1] and not state.employerOrgId then
      state.pendingApplications = data.pendingApplications
    end
  end

  api.employmentsForSave = function(employments)
    local savedEmployments = {}
    for mapId, employment in pairs(employments or {}) do
      local entry = {}
      for key, value in pairs(employment) do entry[key] = value end
      if employment.shift and employment.shift.spawnBlocked then
        entry.shift = {}
        for key, value in pairs(employment.shift) do entry.shift[key] = value end
        local blockedSpawn = employment.shift.spawnBlocked
        entry.shift.spawnBlocked = {
          token = blockedSpawn.token,
          needCompanyLoaner = blockedSpawn.needCompanyLoaner == true,
          needAssignedOffers = blockedSpawn.needAssignedOffers == true,
          retryKind = blockedSpawn.retryKind,
          ready = false,
          accum = 0,
        }
      end
      savedEmployments[mapId] = entry
    end
    return savedEmployments
  end

  function api.saveState(currentSavePath, _, writer)
    writer = writer or overhaul_career_saveSystem.getSaveWriter()
    if not currentSavePath then
      local _, profileSavePath = overhaul_career_saveSystem.getCurrentProfile()
      currentSavePath = profileSavePath
      if not currentSavePath then return end
    end
    if state.shift and not api.savedKindUnavailable() then
      -- Keep a pending restored snapshot intact if save is called before world-ready.
      state.shift.freight = state.restoringFreight and (state.shift.freight or state.shift.plannerFreight) or recovery.captureFreight(state.shift, {
        parcels = overhaul_career_logistics_parcelManager, vehicles = overhaul_career_logistics_vehicleOfferManager,
      })
    end
    api.flushEmploymentCache()
    local dirPath = currentSavePath .. inputs.saveDir
    if not writer.exists(dirPath) then writer.mkdir(dirPath) end
    api.persistenceFeature().write(currentSavePath, {
      version = config.SAVE_VERSION,
      employments = api.employmentsForSave(state.employments),
      rehireBlockedUntil = state.rehireBlockedUntil,
      activeMapId = state.activeMapId,
      offeredFacIds = state.offeredFacIds,
      offeredListingsAt = state.offeredListingsAt,
      headhunter = state.headhunter or { offered = {}, pending = nil },
      refreshLastWorkAt = state.refreshLastWorkAt or nil,
    })
  end
end

-- Constructor ------------------------------------------------------------------------------------

function part.new(inputs)
  local api = inputs.api or {}

  addSaveFeatureApi(api, inputs)
  addKindOutcomeApi(api, inputs)
  addRehireApi(api, inputs)
  addCacheApi(api, inputs)
  addMigrationApi(api, inputs)
  addRecoveryApi(api, inputs)
  addSaveLoadApi(api, inputs)
  return api
end

return part
