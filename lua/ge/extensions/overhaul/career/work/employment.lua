-- Company logistics employment: hiring, shifts, drop-offs and pay for one career.
-- Reading order: config, state, shared helpers, parts, per-frame update, lifecycle, public API and game hooks.
local M = {}
local modIdentity = require("overhaul/lib/platform/modIdentity")

local phoneLayout = require("overhaul/lib/phone/layoutOwner")
local skillLookup = require("overhaul/lib/progression/skillLookup")

-- Config ------------------------------------------------------------------------------------------

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/logisticsEmployment.json"
local config = {
  SAVE_VERSION = 6,
  HIRE_DELAY_SIM = 10, -- Developer tools shorten the application delay.
  HIRE_DELAY_SIM_RELEASE = 180,
  WORLD_MINUTES_PER_DAY = 1440,
  INACTIVITY_FIRE_DAYS = 3,
  REHIRE_COOLDOWN_DAYS = 10,
  EMPLOYMENT_SURGE_BONUS_AMOUNT = 250,
  DAMAGE_STRIKE_WARN_COUNT = 2,
  DAMAGE_STRIKE_DOCK_COUNT = 2,
  DAMAGE_STRIKE_DOCK_PERCENT = 0.10,
  LISTING_OFFER_COUNT = 5,
  LISTING_REFRESH_SIM = 300,
  INDEPENDENT_CARGO_LEVEL = 30,
  EMPLOYEE_UNLOCK_LEVEL_OFFSET = 0,
  -- Half of inventory BASE_TOW_SERVICE_COST ($250) when ending day away from yard.
  REMOTE_END_DAY_TOW_BASE = 250,
  REMOTE_END_DAY_TOW_FRACTION = 0.5,
  ACCIDENT_REBIND_M = 5,
  ACCIDENT_ROAD_OFFSET_M = 3,
  ACCIDENT_ARRIVE_M = 15,
  ACCIDENT_LIVE_DAMAGE = 1000,
}
local TRAILER_UNLOCK_FLAGS = {
  "smallTrailersDelivery",
  "logisticsTrailerMedium",
  "logisticsTrailerFlatbed",
  "logisticsTrailerFramelessDump",
  "largeTrailersDelivery",
  "logisticsTrailerDolly",
  "logisticsTrailerDryvan",
  "logisticsTrailerTanker",
  "logisticsTrailerContainer",
  "logisticsTrailerLog",
}
local MATERIALS_UNLOCK_FLAGS = {
  "logisticsFluidDelivery",
  "logisticsAggregateDelivery",
  "logisticsCementDelivery",
  "logisticsCashDelivery",
}
local MATERIAL_TYPE_UNLOCK_FLAGS = {
  fluid = "logisticsFluidDelivery",
  dryBulk = "logisticsAggregateDelivery",
  cement = "logisticsCementDelivery",
  cash = "logisticsCashDelivery",
}
local VEHICLE_UNLOCK_FLAGS = {
  "junkerVeh",
  "smallVeh",
  "fleetVeh",
  "largeVeh",
  "highEndVeh",
  "exoticVeh",
  "heavyVeh",
}
local EMPLOYMENT_PARCEL_EXCLUDED_TYPES = {
  food = true,
  takeout = true,
}
-- getBranchLevel looks up pathId, not attributeKey. "logistics-delivery" is missing; "logistics" is the domain (4 levels, different XP), not the careerSkills skill.
local LOGISTICS_ATTRIBUTE_KEY = "logistics-delivery"
local LOGISTICS_SKILL_PATH_IDS = {"careerSkills-logistics"}
local RECOVERY_SKILL_ATTRIBUTE_KEY = "careerSkills-recovery"

-- State -------------------------------------------------------------------------------------------

local state = {
  version = config.SAVE_VERSION,
  employments = {},
  rehireBlockedUntil = {},
  activeMapId = nil,
  employerOrgId = nil,
  homeFacId = nil,
  hiredAt = nil,
  lastWorkAt = nil,
  hiredWorldMinute = nil,
  lastWorkWorldMinute = nil,
  pendingApplications = {},
  shift = nil,
  escrow = { money = 0, legs = {} },
  completedAssignments = 0,
  damageRecord = { strikes = 0 },
  lastShiftActionResult = nil,
  offeredFacIds = {},
  offeredListingsAt = nil,
  headhunter = { offered = {}, pending = nil },
}

-- Screen and drop-off flags shared by the employment files (not saved).
local screen = {
  uiOpen = false,
  shiftStartPresentationPending = false,
  shiftStartPresentationReady = false,
  dropOffOpen = false,
  dropOffPsPath = nil,
  dropOffFacId = nil,
  dropOffEscrowPending = false,
  lastDropOffProgress = nil,
  lastDropOffParkingLevels = nil,
  holdDropOffForProgress = false,
  yardArriveSettleTimer = 0,
}
local function isEmployed()
  return state.employerOrgId ~= nil
end
local function isOnShift()
  return state.shift ~= nil and not state.shift.paused
end

local LOG_TAG = "employment"

-- Shared helpers ----------------------------------------------------------------------------------

local shared = {}
local runtime = {}
local parts = {}

shared.jobKinds = require('overhaul/lib/jobs/kinds')
runtime.kindCatalog = nil
shared.kindDefinition = function(kindId)
  if not runtime.kindCatalog then runtime.kindCatalog = shared.jobKinds.load() end
  return runtime.kindCatalog.byId[kindId]
end
shared.kindPolicy = function(kindId)
  local kind = shared.kindDefinition(kindId)
  return kind and kind.policy or shared.jobKinds.emptyPolicy
end
shared.kindHandler = function(kindId, name, ...)
  return shared.jobKinds.handler(shared.kindDefinition(kindId), name, ...)
end
-- Whether a kind's manifest file is still mounted. The answer is kept with the catalog it was asked for, so it is read again after every rescan; fresh asks the file system now.
shared.kindManifestMounted = function(kindId, fresh)
  local catalog = runtime.kindCatalog
  local cache = catalog and catalog.manifestMounted or {}
  if catalog then catalog.manifestMounted = cache end
  if cache[kindId] == nil or fresh then cache[kindId] = FS:fileExists(shared.jobKinds.dir .. kindId .. ".json") and true or false end
  return cache[kindId]
end
-- A shift whose kind no mounted manifest defines: its add-on was removed or disabled. The file check also catches a mod unmounted before employment hears of it, while the catalog is cached; fresh (the wage deposit asks for it) does not trust the cached answer.
shared.kindUnavailable = function(shift, fresh)
  if type(shift.jobKind) ~= "string" then return false end
  if shared.kindDefinition(shift.jobKind) == nil then return true end
  return not shared.kindManifestMounted(shift.jobKind, fresh)
end
shared.sponsors = require("overhaul/lib/ledger/sponsors")
M.sponsorPayer = {
  order = 20,
  isActive = function() return isOnShift() end,
  name = function()
    local name
    local ui = M.getUiState()
    name = ui and ui.employerName
    if not name or name == "" then
      name = M.getTasklistHeaderLabel()
    end
    if type(name) == "string" and name ~= "" then return name end
    return "Company"
  end,
}

function shared.unregisterSponsorPayer()
  local dispose = runtime.disposeSponsorPayer
  runtime.disposeSponsorPayer = nil
  if dispose then dispose() end
end

function shared.registerSponsorPayer()
  shared.unregisterSponsorPayer()
  runtime.disposeSponsorPayer = shared.sponsors.registerPayer(M, M.sponsorPayer)
end

shared.SHIFT_LOG_WARN_WORDS = {"blocked", "fail", "unavailable", "timed out", "abort", "softClear", "missing"}
shared.shiftLog = function(headline, detail, level)
  local message = tostring(headline or "employment event")
  if detail and detail ~= "" then
    message = message .. " | " .. tostring(detail)
  end
  if not level then
    level = "I"
    for _, word in ipairs(shared.SHIFT_LOG_WARN_WORDS) do
      if message:find(word, 1, true) then
        level = "W"
        break
      end
    end
  end
  log(level, LOG_TAG, message)
end

shared.publishShiftActionResult = function(result)
  state.lastShiftActionResult = result
  if type(result) == "table" then
    guihooks.trigger("employmentShiftActionResult", result)
  end
  return result
end

shared.failShift = function(reason, detail)
  reason = tostring(reason or "Shift start failed")
  shared.shiftLog("startShift blocked", reason .. (detail and detail ~= "" and (" | " .. tostring(detail)) or ""))
  ui_message(reason, 8, "warning")
  -- Avoid `ok` key: engineLua callbacks can collapse { ok = false, ... } to bare false in JS. Keep diagnose detail for logs/UI consumers; never paste it into the player toast.
  return shared.publishShiftActionResult({
    success = false,
    message = reason,
    reason = reason,
    detail = detail or "",
  })
end

shared.okShift = function(extra)
  extra = type(extra) == "table" and extra or {}
  extra.success = true
  return shared.publishShiftActionResult(extra)
end

shared.summarizeKindMap = function(kinds)
  return parts.dispatch.summarizeKindMap(kinds)
end

shared.parcelManager = function()
  return overhaul_career_logistics_parcelManager
end

shared.general = function()
  return overhaul_career_logistics_general
end

shared.generator = function()
  return overhaul_career_logistics_generator
end

shared.materials = function()
  return overhaul_career_logistics_materialContractManager
end

shared.cargoScreen = function()
  return overhaul_career_logistics_cargoScreen
end

shared.vehicleOffers = function()
  return overhaul_career_logistics_vehicleOfferManager
end

shared.loanerCapabilities = function()
  if not overhaul_career_logistics_loanerCapabilities then
    extensions.load("overhaul_career_logistics_loanerCapabilities")
  end
  return overhaul_career_logistics_loanerCapabilities
end

shared.repoJob = function()
  return overhaul_jobs_repo
end

shared.roundMoney = function(value)
  return math.floor((tonumber(value) or 0) + 0.5)
end

shared.nowSim = function()
  local general = shared.general()
  if general then return general.time() end
  return 0
end

shared.nowWorldMinutes = function()
  local weather = overhaul_world_weather
  if weather then return weather.getWorldMinutes() end
end

shared.inactivityFireWorldMinutes = function()
  return config.INACTIVITY_FIRE_DAYS * config.WORLD_MINUTES_PER_DAY
end

shared.currentMapId = function()
  return getCurrentLevelIdentifier() or ""
end

shared.simDaysRemaining = function(blockedUntilWorldMinute)
  local now = shared.nowWorldMinutes()
  if now == nil then return 0 end
  local remainingWorldMinutes = (tonumber(blockedUntilWorldMinute) or 0) - now
  if remainingWorldMinutes <= 0 then return 0 end
  return math.ceil(remainingWorldMinutes / config.WORLD_MINUTES_PER_DAY)
end

M.debugHeadhunter = function()
  local level = parts.eligibility.getDeliveryLevel()
  local lines = {
    string.format("employed=%s employer=%s level=%d offerVersion=%s pending=%s",
      tostring(isEmployed()),
      tostring(state.employerOrgId),
      level,
      tostring(state.headhunter and state.headhunter.offerVersion),
      tostring(state.headhunter and state.headhunter.pending and state.headhunter.pending.facId)),
  }
  for _, milestone in ipairs(runtime.HEADHUNTER_MILESTONES) do
    local listing = parts.hiring.findHeadhunterListing(milestone)
    table.insert(lines, string.format("%s L%d offered=%s listing=%s/%s",
      milestone.id,
      milestone.level,
      tostring(state.headhunter and state.headhunter.offered and state.headhunter.offered[milestone.id]),
      listing and listing.orgName or "nil",
      listing and listing.facName or "nil"))
  end
  local message = table.concat(lines, " | ")
  log("W", "employment", "debugHeadhunter: " .. message)
  return lines
end

shared.emptyShift = function(keepTransition)
  if not keepTransition then parts.assignment.finishNextAssignmentTransition() end
  local endedRoleplayShift = state.shift and shared.kindPolicy(state.shift.jobKind).roleplay
  parts.equipment.cancelSpawnBlockedWatch()
  parts.accidents.deleteAccidentCargoBox()
  state.shift = nil
  runtime.bindAssignedInFlight = false
  runtime.pendingCargoTaskRefresh = nil
  screen.dropOffEscrowPending = false
  parts.settlement.resetDamageStrikes()
  parts.projections.clearTaskGuidance()
  parts.eligibility.uiLibrary().resetTasklistCache()
  parts.projections.purgeIndependentTasklist()
  if endedRoleplayShift then
    guihooks.trigger("ClearTasklist")
  end
end

shared.isDevToolsEnabled = function()
  local extensionManager = overhaul_shell_extensionManager
  return extensionManager and extensionManager.isDevKeyValid() and true or false
end

shared.isOpenEndedJobKind = function(kind)
  return shared.kindPolicy(kind).openEnded
end

shared.uiSkillProgress = function(profile, facility, org)
  if not parts.eligibility.isRoleplayProfile(profile) then
    return parts.eligibility.getDeliveryLevel(), "Logistics"
  end
  local progress = require("overhaul/lib/logistics/serviceFleet").playerUnlockProgress(facility, org)
  if progress then
    return progress.skillLevel, progress.skillLabel
  end
  if shared.kindDefinition(profile) and not shared.kindPolicy(profile).emergency then
    local level = (skillLookup.hasBranchLevels() and (
      skillLookup.branchLevel("careerSkills-passenger") or skillLookup.branchLevel("passenger"))) or 0
    local kind = shared.kindDefinition(profile)
    return level, kind and kind.skillLabel or "Passenger Skill"
  end
  local level = (skillLookup.hasBranchLevels() and (
    skillLookup.branchLevel("careerSkills-emergency") or skillLookup.branchLevel("emergency"))) or 0
  local kind = shared.kindDefinition(profile)
  return level, kind and kind.skillLabel or "Paramedic Skill"
end

shared.buildRoleplaySetupUi = function(profile, facility, facId)
  if not parts.eligibility.isRoleplayProfile(profile) then return nil end
  local vehicles, unavailableReason = {}, nil
  local loanerCapabilities = shared.loanerCapabilities()
  if loanerCapabilities and loanerCapabilities.getRoleplayFleetForUi then
    vehicles, unavailableReason = loanerCapabilities.getRoleplayFleetForUi(facility)
  end
  return {
    facId = facId,
    kind = profile,
    vehicles = vehicles or {},
    unavailableReason = unavailableReason,
  }
end

-- Activity definitions ----------------------------------------------------------------------------

local function parentDefinition(call)
  return {
    id = 'employment', label = 'Employment', role = 'orchestrator', modes = {'career'},
    extension = 'overhaul_career_work_employment', lifecycle = 'employment',
    actions = {
      abandonAssignment = call('abandonAssignment'),
      acceptHeadhunterOffer = call('acceptHeadhunterOffer'),
      applyForJob = call('applyForJob'),
      claimAccidentReplacement = call('claimAccidentReplacement'),
      closeDropOffUi = call('closeDropOffUi'),
      closeRoleplaySetup = call('closeRoleplaySetup'),
      closeShiftUi = call('closeShiftUi'),
      confirmEmployeeDropOff = call('confirmEmployeeDropOff'),
      dismissHeadhunterOffer = call('dismissHeadhunterOffer'),
      endBusShiftNow = call('endBusShiftNow'),
      endDay = call('endDay'),
      getDevJobOptions = call('getDevJobOptions'),
      getDropOffUiState = call('getDropOffUiState'),
      getLastShiftActionResult = call('getLastShiftActionResult'),
      getUiState = call('getUiState'),
      navigateToYard = call('navigateToYard'),
      openShiftUi = call('openShiftUi'),
      quitJob = call('quitJob'),
      reportAccident = call('reportAccident'),
      resetShiftAndEquipment = call('resetShiftAndEquipment'),
      rollJobListings = call('rollJobListings'),
      spawnBlockedEquipment = call('spawnBlockedEquipment'),
      startNextRun = call('startNextRun'),
      startRoleplayShift = call('startRoleplayShift'),
      startShift = call('startShift'),
      startShiftWithJob = call('startShiftWithJob'),
    },
    probe = call('isOnShift'), save = call('onOverhaulSaveCurrentProfile'),
    transitions = {save = call('onOverhaulSaveCurrentProfile'), unload = call('onClientEndMission')},
    resources = {'vehicle', 'tasklist'}, settlement = 'owner', economyKeys = {'delivery'},
  }
end

local function addLegacyChildren(definitions, call)
  for _, id in ipairs({'employmentParcel', 'employmentRepo', 'employmentTrailer', 'employmentOther', 'police'}) do
    definitions[id] = {
      id = id, label = id, role = 'child', parent = 'employment', modes = {'career'},
      extension = 'overhaul_career_work_employment', lifecycle = id,
      actions = {},
      save = call('onOverhaulSaveCurrentProfile'),
      transitions = {save = call('onOverhaulSaveCurrentProfile'), unload = call('onClientEndMission')},
      resources = {'vehicle', 'tasklist'}, settlement = 'parent', economyKeys = {},
    }
  end
end

local function addKindChildren(employment, definitions, call)
  for _, kind in ipairs(employment.shiftKindDefinitions()) do
    if kind.activityOwner == 'overhaul_career_work_employment' and not definitions[kind.activity] then
      definitions[kind.activity] = {
        id = kind.activity, label = kind.id, role = 'child', parent = 'employment', modes = {'career'},
        extension = 'overhaul_career_work_employment',
        probe = function() return employment.isKindOnShift(kind.id) end,
        actions = {
          start = function(...) return employment.startKindShift(kind.id, ...) end, admission = call('shiftAdmission'),
          cancel = call('abandonAssignment'), endShift = call('endDay'),
          guidance = call('refreshKindGuidance'),
          allowsPersonalVehicle = function(...) return employment.kindAllowsPersonalVehicle(kind.id, ...) end,
        },
        resources = {'vehicle', 'tasklist'}, settlement = 'parent', economyKeys = {kind.economyKey},
      }
    end
  end
end

local function employmentActivityDefinitions(employment)
  local function call(name) return function(...) return employment[name](...) end end
  local definitions = {employment = parentDefinition(call)}
  addLegacyChildren(definitions, call)
  addKindChildren(employment, definitions, call)
  return definitions
end

-- Parts -------------------------------------------------------------------------------------------

-- Parts are created in this order. Each one keeps its API in a table that already exists, so parts
-- reach each other through `inputs.<part>` and see methods that are added by parts created later.
local PART_ORDER = {
  "persistence", "eligibility", "hiring", "projections", "settlement", "kindContract", "dropOff", "backhaul",
  "routing", "parcelLoading", "assignment", "endDay", "dispatch", "equipment", "recovery", "accidents", "parcelStrings",
}
local PART_MODULES = {
  persistence = require("overhaul/career/work/employment/persistence"),
  eligibility = require("overhaul/career/work/employment/eligibility"),
  hiring = require("overhaul/career/work/employment/hiring"),
  projections = require("overhaul/career/work/employment/projections"),
  assignment = require("overhaul/career/work/employment/assignment"),
  settlement = require("overhaul/career/work/employment/settlement"),
  kindContract = require("overhaul/career/work/employment/kindContract"),
  dropOff = require("overhaul/career/work/employment/dropOff"),
  backhaul = require("overhaul/career/work/employment/backhaul"),
  routing = require("overhaul/career/work/employment/routing"),
  parcelLoading = require("overhaul/career/work/employment/parcelLoading"),
  endDay = require("overhaul/career/work/employment/endDay"),
  dispatch = require("overhaul/career/work/employment/dispatch"),
  equipment = require("overhaul/career/work/employment/equipment"),
  recovery = require("overhaul/career/work/employment/shiftRecovery"),
  accidents = require("overhaul/career/work/employment/accidentRecovery"),
  parcelStrings = require("overhaul/career/work/employment/parcelStrings"),
}

local lifecycle = { isEmployed = isEmployed, isOnShift = isOnShift }
local partInputs = {
  EMPLOYMENT_PARCEL_EXCLUDED_TYPES = EMPLOYMENT_PARCEL_EXCLUDED_TYPES,
  LOGISTICS_ATTRIBUTE_KEY = LOGISTICS_ATTRIBUTE_KEY,
  LOGISTICS_SKILL_PATH_IDS = LOGISTICS_SKILL_PATH_IDS,
  LOG_TAG = LOG_TAG,
  M = M,
  MATERIALS_UNLOCK_FLAGS = MATERIALS_UNLOCK_FLAGS,
  MATERIAL_TYPE_UNLOCK_FLAGS = MATERIAL_TYPE_UNLOCK_FLAGS,
  RECOVERY_SKILL_ATTRIBUTE_KEY = RECOVERY_SKILL_ATTRIBUTE_KEY,
  TRAILER_UNLOCK_FLAGS = TRAILER_UNLOCK_FLAGS,
  VEHICLE_UNLOCK_FLAGS = VEHICLE_UNLOCK_FLAGS,
  config = config,
  parts = parts,
  lifecycle = lifecycle,
  runtime = runtime,
  saveDir = saveDir,
  saveFile = saveFile,
  screen = screen,
  shared = shared,
  state = state,
}
for _, name in ipairs(PART_ORDER) do
  parts[name] = {}
  partInputs[name] = parts[name]
end

local function inputsFor(name, extra)
  local inputs = {api = parts[name]}
  for key, value in pairs(partInputs) do inputs[key] = value end
  for key, value in pairs(extra or {}) do inputs[key] = value end
  return inputs
end

-- The assignment tick API is installed as soon as projections exist, which later parts already read.
local function installAssignmentTick()
  PART_MODULES.assignment.addTickApi(parts.assignment, inputsFor("assignment", {effects = parts.projections}))
  parts.projections.nextAssignmentVehicle = parts.assignment.nextAssignmentVehicle
  parts.projections.requestNextAssignmentEntry = parts.assignment.requestNextAssignmentEntry
  parts.projections.stepRetryDue = parts.assignment.stepRetryDue
  parts.projections.tickNextAssignmentTransition = parts.assignment.tickNextAssignmentTransition
end

for _, name in ipairs(PART_ORDER) do
  PART_MODULES[name].new(inputsFor(name))
  if name == "projections" then installAssignmentTick() end
end

-- Per-frame update --------------------------------------------------------------------------------

local taskGuidanceRefreshTimer = 0.25

local function updateUnavailable()
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    parts.assignment.finishNextAssignmentTransition()
    return true
  end
  if parts.persistence.savedKindUnavailable() then
    parts.assignment.finishNextAssignmentTransition()
    return true
  end
  return false
end

local function tickHiring()
  parts.projections.maybeNotifyEmploymentUnlock()
  parts.settlement.checkEmploymentInactivity()
  local pending = state.pendingApplications[1]
  if pending and shared.nowSim() >= (pending.hireAt or 0) then parts.hiring.completeHire(pending) end
  parts.hiring.maybeOfferHeadhunter()
  if state.offeredListingsAt
      and (shared.nowSim() - (tonumber(state.offeredListingsAt) or 0)) >= config.LISTING_REFRESH_SIM then
    parts.hiring.clearOfferedListings()
    parts.projections.notifyUi()
  end
end

local function clearParcelDeparture(shift)
  if not shared.kindPolicy(shift.jobKind).parcels or not shift.dropOffDepartureRequired then return end
  local destination = shift.destLocation
    or (shift.destFacId and {type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath})
  local origin = shift.originLocation
  local hasRemoteOrigin = origin and (
    (origin.facId and shift.destFacId and origin.facId ~= shift.destFacId)
    or (origin.psPath and shift.destPsPath and origin.psPath ~= shift.destPsPath))
  if (hasRemoteOrigin and parts.parcelLoading.assignedReturnCargoInVehicle(shift))
      or (destination and not parts.routing.playerNearLocation(destination, 12)) then
    shift.dropOffDepartureRequired = nil
  end
end

local function retryParcelLoading(shift)
  if not (shift.parcelLoadPending and shift.parcelLoadRetryAt and shared.nowSim() >= shift.parcelLoadRetryAt) then return false end
  shift.parcelLoadRetryAt = nil
  parts.parcelLoading.bindAssignedCargoToIssuedTruck()
  return state.shift ~= shift
end

local function tickMaterials(shift)
  if not shared.kindPolicy(shift.jobKind).materialContract then return end
  if parts.dropOff.materialsAssignmentHasWork() then
    if shift.phase == "loopComplete" and not shift.wrecked then
      shift.phase = "outbound"
      parts.projections.refreshTaskGuidance(true)
      parts.projections.notifyUi()
    end
  elseif shift.phase == "outbound" then
    parts.dropOff.afterOutboundDelivered()
  end
end

local function tickYardPrompts(shift, dtSim)
  if not runtime.nextAssignmentTransition and parts.routing.tryOpenNearbyAssignedDropOff(dtSim) then return true end
  if not runtime.nextAssignmentTransition and shift.awaitingLoopChoice and parts.routing.playerReadyAtYardInspect(dtSim) then
    screen.yardArriveSettleTimer = 0
    parts.routing.offerLoopCompleteChoice({label = "Assignments complete", subtext = "Take another job or end your day"})
  elseif not runtime.nextAssignmentTransition and shift.phase == "return"
      and not parts.dropOff.hasOutstandingReturnWork(shift)
      and parts.routing.playerReadyAtYardInspect(dtSim) and not screen.uiOpen and not screen.dropOffOpen then
    screen.yardArriveSettleTimer = 0
    parts.dropOff.afterReturnDelivered()
  elseif not runtime.nextAssignmentTransition and shift.phase == "loopComplete" and not shift.wrecked
      and parts.routing.playerReadyAtYardInspect(dtSim) and not screen.uiOpen and not screen.dropOffOpen then
    screen.yardArriveSettleTimer = 0
    parts.projections.openShiftUi(shift.originFacId or state.homeFacId)
  end
  return false
end

local function tickReturnEquipment(shift)
  if shared.kindPolicy(shift.jobKind).trailerDelivery and shift.phase == "return" and shift.returnNeedsPickup then
    parts.routing.trySpawnAssignedReturnTrailer()
  end
  if (shared.kindPolicy(shift.jobKind).vehicleDelivery and shift.phase == "return" and shift.returnNeedsPickup)
      or parts.dropOff.isBundleHaulBackhaulPending(shift) then
    parts.routing.trySpawnAssignedReturnVehicle()
  end
  parts.backhaul.rearmMissingEmploymentRepo()
  if shared.kindPolicy(shift.jobKind).repossession and shift.repoPendingStart then parts.backhaul.tryStartEmploymentRepo() end
end

local function tickActiveShift(shift, dtSim)
  clearParcelDeparture(shift)
  if retryParcelLoading(shift) then return true end
  if shift.endAfterAssignment and not screen.dropOffEscrowPending and not parts.endDay.finalAssignmentInProgress() then
    if parts.endDay.finishShift() then return true end
  end
  if shift.spawnBlocked then parts.equipment.tickSpawnBlockedWatch(dtSim) end
  tickMaterials(shift)
  parts.accidents.tickAccidentRecovery(dtSim)
  if tickYardPrompts(shift, dtSim) then return true end
  tickReturnEquipment(shift)
  return false
end

local function tickGuidance(dtSim)
  taskGuidanceRefreshTimer = taskGuidanceRefreshTimer + (tonumber(dtSim) or 0)
  if taskGuidanceRefreshTimer < 0.25 then return end
  taskGuidanceRefreshTimer = 0
  local generator = shared.generator()
  if generator and generator.withoutGeneration then
    generator.withoutGeneration(parts.projections.refreshTaskGuidance, false)
  else
    parts.projections.refreshTaskGuidance(false)
  end
end

local function onUpdate(dtReal, dtSim)
  if updateUnavailable() then return end
  parts.assignment.tickNextAssignmentTransition(dtReal, dtSim)
  if state.restoringFreight then return end
  tickHiring()
  if not state.shift or not isOnShift() then state.dropOffProximityTimer = 0 end
  if not state.shift then return end
  if isOnShift() and tickActiveShift(state.shift, dtSim) then return end
  tickGuidance(dtSim)
end

local function releaseCareerHooks()
  parts.kindContract.endKindContracts()
  shared.unregisterSponsorPayer()
  if runtime.disposeWageHolder then runtime.disposeWageHolder(); runtime.disposeWageHolder = nil end
  if runtime.saveFeature then runtime.saveFeature.dispose(); runtime.saveFeature = nil end
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function discardInvalidEmployments()
  -- A retired standalone work profile must never become a company employer.
  if not parts.eligibility.isEmploymentUnlocked() then
    if isEmployed() then
      parts.endDay.quitJob({ silent = true })
    end
    state.pendingApplications = {}
  end
  if state.employerOrgId == "vehicle_transfer" or state.homeFacId == "vehicle_transfer" then
    parts.endDay.quitJob({ silent = true })
  end
  if state.pendingApplications then
    local kept = {}
    for _, app in ipairs(state.pendingApplications) do
      if app and app.orgId ~= "vehicle_transfer" and app.facId ~= "vehicle_transfer" then
        table.insert(kept, app)
      end
    end
    state.pendingApplications = kept
  end
  if state.offeredFacIds then
    local keptOffers = {}
    for _, id in ipairs(state.offeredFacIds) do
      if id ~= "vehicle_transfer" then
        table.insert(keptOffers, id)
      end
    end
    state.offeredFacIds = keptOffers
  end
end

local function migrateIndependentRentals()
  for _, vehicleInfo in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
    if vehicleInfo.loanType == "work" and vehicleInfo.owningOrganization then
      local organization = parts.eligibility.getOrg(vehicleInfo.owningOrganization)
      if overhaul_career_logistics_loanerVehicles.usesIndependentHourlyRental(organization) then
        vehicleInfo.loanType = "rental"
        vehicleInfo.rentalHourlyRate = vehicleInfo.rentalHourlyRate or overhaul_career_logistics_loanerVehicles.getHourlyRateForOffer(vehicleInfo) or 30
        overhaul_career_logistics_loanerVehicles.initRentalBilling(vehicleInfo)
      end
    end
  end
end

local function refreshCareerGuidance()
  local retainEquipment = isOnShift() or (state.shift and state.shift.paused)
  parts.projections.clearTaskGuidance()
  if shared.materials() then shared.materials().clearTaskGuidance() end
  if not retainEquipment then parts.endDay.returnAllCompanyVehicles() end
end

local function onCareerActivated()
  runtime.kindCatalog = nil
  shared.registerSponsorPayer()
  parts.settlement.registerWageHolder()
  parts.assignment.finishNextAssignmentTransition()
  runtime.roleplayPhoneFacId = nil
  overhaul_career_work_logisticsEmploymentMode.onCareerActivated()
  parts.persistence.loadState()
  M.refreshKindActivities()
  discardInvalidEmployments()
  migrateIndependentRentals()
  refreshCareerGuidance()
  parts.projections.maybeNotifyEmploymentUnlock()
  local layout = phoneLayout.get()
  if layout then layout.ensureDefaultAppsPlaced() end
end

local function onExtensionLoaded()
  shared.registerSponsorPayer()
  -- Sponsor registration waits for career activation before reading organizations.
end

-- Public API: blocked equipment ------------------------------------------------------------------

M.getBlockedSpawnStatus = function()
  return parts.equipment.getBlockedSpawnStatus()
end

M.spawnBlockedEquipment = function()
  local status = M.getBlockedSpawnStatus()
  local blocked = state.shift and state.shift.spawnBlocked
  if not status or not status.nearby or blocked.retryInFlight then return false end
  local clear = parts.equipment.inspectSpawnBlockedOccupancy(blocked)
  blocked.ready = clear
  if not clear then
    ui_message("The spawn area is still blocked. Clear the highlighted stalls first.", 6, "warning")
    parts.projections.notifyUi()
    return false
  end
  parts.dropOff.closeWorldPrompt()
  parts.projections.closeShiftUi()
  if blocked.retryKind == "accidentReplacement" then
    parts.equipment.clearSpawnBlockedState(true)
    return parts.accidents.claimAccidentReplacement() or false
  end
  parts.equipment.attemptSpawnBlockedRetry()
  return true
end

-- Public API: employment state --------------------------------------------------------------------

M.isEndingDay = function()
  return state.shift and state.shift.endAfterAssignment == true or false
end

M.isEmployed = isEmployed
M.isOnShift = isOnShift
M.hasCompanyShift = parts.eligibility.hasCompanyShift
M.isJockeyShift = function()
  local shift = state.shift
  if not shift or not isOnShift() then return false end
  if parts.dropOff.isDistributorHaulShift(shift) then return true end
  if shared.kindPolicy(shift.jobKind).vehicleDelivery then return true end
  if parts.dropOff.isBundleShift(shift) then
    local a = shift.assignments
    if a and a.vehicle and not a.vehicle.complete then return true end
    if parts.dropOff.isBundleHaulBackhaulPending(shift) and shift.returnIsBackhaul then return true end
    return false
  end
  return false
end

-- Public API: routes and guidance -----------------------------------------------------------------

M.isBundleFlatbedPending = function()
  local shift = state.shift
  if not shift or not isOnShift() or not parts.dropOff.isBundleHaulBackhaulPending(shift) then return false end
  if shift.returnIsBackhaul and shift.assignedOfferId and parts.equipment.playerInIssuedCompanyTruck() then
    return false
  end
  return true
end

M.reassertBundleFlatbedRoute = function()
  if not M.isBundleFlatbedPending() then return false end
  if not parts.equipment.playerInIssuedCompanyTruck() then
    return parts.equipment.routeToCompanyTruck() and true or false
  end
  local shift = state.shift
  if shift.returnNeedsPickup then
    return parts.routing.routeToReturnPickup() and true or false
  end
  return false
end
M.getShiftDestLocation = function()
  local shift = state.shift
  if not shift then return nil end
  if shift.destLocation and (shift.destLocation.psPath or shift.destLocation.facId) then
    return shift.destLocation
  end
  if shift.destFacId then
    return { type = "facilityParkingspot", facId = shift.destFacId, psPath = shift.destPsPath }
  end
  return nil
end
M.onVehicleTaskStepChanged = function()
  if not isOnShift() then return end
  if M.reassertBundleFlatbedRoute() then
    parts.projections.refreshTaskGuidance(true)
    return
  end
  parts.routing.routeCurrentAssignment()
  parts.projections.refreshTaskGuidance(true)
end
M.getGuidedDeliveryFacilityId = function()
  if not isOnShift() then return nil end
  local shift = state.shift
  if not shift or not shared.kindPolicy(shift.jobKind).parcels then return nil end
  if shift.awaitingPark or shift.phase == "loopComplete" or shift.wrecked then
    return shift.originFacId or state.homeFacId
  end
  if (shift.needsRemotePickup or shift.returnNeedsPickup)
      and (not parts.parcelLoading.assignedReturnCargoInVehicle(shift)
        or parts.parcelLoading.parcelPickupPendingAtOrigin(shift)) then
    return (shift.originLocation and shift.originLocation.facId)
      or shift.returnPickupFacId or shift.pickupFacId or shift.originFacId
  end
  if shift.stringMode and shift.phase == "outbound" then
    local stop = shift.stops and shift.stops[shift.stopIndex or 1]
    return (stop and stop.destFacId) or shift.destFacId
  end
  return shift.destFacId
end
M.shouldShowDeliveryFacilityWorldPin = function(facId)
  if not facId then return true end
  local guided = M.getGuidedDeliveryFacilityId()
  if not guided then return true end
  return facId == guided
end
M.shouldShowParcelDropOffPin = function(cargo)
  if not isOnShift() then return true end
  local shift = state.shift
  if not shift or not shared.kindPolicy(shift.jobKind).parcels then return true end
  if not parts.dropOff.cargoIsAssigned(cargo) then return false end
  if shift.phase == "outbound" then
    local stop = shift.stops and shift.stops[shift.stopIndex or 1]
    if stop then
      return parts.parcelStrings.cargoMatchesStop(cargo, stop)
    end
    local dest = cargo.destination
    if shift.destFacId and dest and dest.facId == shift.destFacId then
      if not shift.destPsPath or not dest.psPath or dest.psPath == shift.destPsPath then
        return true
      end
    end
    return false
  end
  return true
end
M.ownsHudTasklist = function()
  return isOnShift()
end
M.refreshHudTasklist = function(force)
  parts.projections.refreshTaskGuidance(force and true or false)
end
-- Public API: held work ---------------------------------------------------------------------------

M.isEmployedAtRepoCompany = function()
  if not isEmployed() then return false end
  local facility = shared.generator() and shared.generator().getFacilityById(state.homeFacId)
  local loanerCapabilities = shared.loanerCapabilities()
  return facility and loanerCapabilities and loanerCapabilities.canIssueLoanersForFacility(facility, "repo", {}) or false
end
M.isAssignmentPaused = function()
  return state.shift and state.shift.paused and true or false
end
M.isAwaitingPark = function()
  return state.shift and state.shift.awaitingPark and true or false
end
M.shouldAbortInterruptedShiftOnLoad = function()
  local shift = state.shift
  return shift ~= nil and not shift.sessionVehicles and not (shift.freight or shift.plannerFreight) and not state.restoringFreight
end
M.shouldPersistVehicle = function(inventoryId)
  local shift = state.shift
  if not shift then return false end
  inventoryId = tonumber(inventoryId)
  for _, id in ipairs(shift.issuedInventoryIds or {}) do
    if tonumber(id) == inventoryId then return true end
  end
  local inventory = overhaul_career_garage_inventory
  local info = inventory and inventory.getVehicle(inventoryId)
  if info and info.loanType == "company" and info.owningOrganization == parts.eligibility.getActiveShiftOrgId() then return true end
  if not info or info.loanType ~= "delivery" then return false end
  local snapshot = shift.freight or shift.plannerFreight
  if snapshot then
    for _, offer in ipairs(snapshot.offers or {}) do
      if offer.vehicle and tonumber(offer.vehicle.inventoryId) == inventoryId then return true end
    end
  end
  local vehicleOfferManager = shared.vehicleOffers()
  for _, id in ipairs(shift.assignedOfferIds or {shift.assignedOfferId}) do
    local offer = vehicleOfferManager and vehicleOfferManager.getOfferById(id)
    if offer and offer.vehicle and tonumber(offer.vehicle.inventoryId) == inventoryId then return true end
  end
  return false
end
-- Public API: employer and hiring -----------------------------------------------------------------

M.getEmployerOrgId = parts.dropOff.getEmployerOrgId
M.getEmployerQuickTravelTarget = function()
  if not isEmployed() then return nil end
  local yard = parts.routing.getYardLocation()
  local generator = shared.generator()
  local spot = yard and yard.psPath and generator and generator.getParkingSpotByPath and generator.getParkingSpotByPath(yard.psPath)
  if not (spot and spot.pos) then return nil end
  local context = parts.backhaul.getEmployerDeliveryContext()
  return {pos = spot.pos, rot = spot.rot, label = context and context.label or "Your employer"}
end
M.getTasklistHeaderLabel = parts.projections.getEmployerTasklistHeader
M.keepDeliveryModeActive = parts.dropOff.keepDeliveryModeActive
M.applyForJob = parts.hiring.applyForJob
M.acceptHeadhunterOffer = parts.hiring.acceptHeadhunterOffer
M.dismissHeadhunterOffer = parts.hiring.dismissHeadhunterOffer
-- Phone app: drop ground markers at the employer's yard so the player can go clock in.
local function navigateToYard(facId)
  facId = facId or (state.shift and state.shift.originFacId) or state.homeFacId
  local generator = overhaul_career_logistics_generator
  local facility = facId and generator and generator.getFacilityById and generator.getFacilityById(facId)
  if not facility then return false, "No company yard to route to." end
  local pos = facility.inspectSpots and facility.inspectSpots[1] and facility.inspectSpots[1].pos
  if not pos and facility.pos then pos = vec3(facility.pos) end
  if not pos then return false, "The yard location is unavailable." end
  local general = overhaul_career_logistics_general
  pcall(general.setDeliveryNavFocus, pos)
  core_groundMarkers.setPath({pos}, {clearPathOnReachingTarget = false})
  return true, "Route to the company yard set."
end

-- Public API: shift actions -----------------------------------------------------------------------

M.quitJob = parts.endDay.quitJob
M.navigateToYard = navigateToYard
M.onLogisticsAbandoned = function()
  if not state.shift then return end
  local shouldTerminateAfterAbandon = state.shift.pendingDamageTermination
  parts.settlement.cancelEmploymentRepoJob()
  state.ignoreCompanyDamageStrikes = true
  parts.equipment.returnIssuedVehicles()
  shared.emptyShift()
  parts.settlement.resetEscrow()
  if shouldTerminateAfterAbandon then parts.settlement.terminateEmploymentForDamage() else parts.persistence.flushEmploymentCache() end
  parts.projections.notifyUi()
end
M.resetShiftAndEquipment = parts.endDay.resetShiftAndEquipment
M.rollJobListings = parts.hiring.rollJobListings
M.getDevJobOptions = parts.dispatch.getDevJobOptions
M.startShiftWithJob = function(facId, selection)
  return parts.assignment.callShiftAction("startShiftWithJob", function(id)
    return parts.assignment.startShiftWithJob(id, selection)
  end, facId)
end
M.startShift = function(facId)
  return parts.assignment.callShiftAction("startShift", parts.assignment.startShift, facId)
end
M.startRoleplayShift = function(facId, selection)
  return parts.assignment.callShiftAction("startRoleplayShift", function(id)
    local profile, _, facility = parts.eligibility.getFacilityEmployerProfile(id)
    if not parts.eligibility.isRoleplayProfile(profile) or id ~= runtime.roleplayPhoneFacId then
      return shared.failShift("Visit the service facility to start your day.")
    end
    local gate, fail = parts.assignment.startShiftGate(id)
    if not gate then return fail end
    if type(selection) ~= "table" then return shared.failShift("Choose a vehicle first.") end
    local job = parts.eligibility.makeRoleplayJob(profile)
    if selection.personal then
      local inventory = overhaul_career_garage_inventory
      local vehicleId = be:getPlayerVehicleID(0)
      local inventoryId = inventory and inventory.getInventoryIdFromVehicleId(vehicleId)
      local info = inventoryId and inventory.getVehicles()[inventoryId]
      if not info or info.owned == false or info.loanType or info.owningOrganization then
        return shared.failShift("Enter your own service vehicle first.")
      end
      local valid = M.performKindAction(profile, 'allowsPersonalVehicle', vehicleId, inventoryId)
      if not valid then return shared.failShift("This vehicle or your skill level is not eligible for this service.") end
      job.personalVehicleId = inventoryId
    else
      local loanerCapabilities = shared.loanerCapabilities()
      if not loanerCapabilities or not loanerCapabilities.getIssuedRoleplayVehicleForFacility(facility, {selection = selection}) then
        return shared.failShift("This company vehicle is no longer available.")
      end
      job.vehicleSelection = {model = selection.model, config = selection.config}
    end
    local ok, err = parts.assignment.beginAssignmentWithGuidance(id, job)
    if not ok then return shared.failShift("Could not start the shift.", err) end
    parts.persistence.saveEmploymentProgress()
    ui_message("On duty. Use End Day in Phone > Employment when you are finished.", 8, "info")
    return shared.okShift()
  end, facId)
end
M.closeRoleplaySetup = function()
  runtime.roleplayPhoneFacId = nil
  parts.projections.notifyUi()
end
M.startNextRun = function(facId)
  return parts.assignment.callShiftAction("startNextRun", parts.assignment.startNextRun, facId)
end
M.getLastShiftActionResult = function()
  return state.lastShiftActionResult or {
    success = false,
    message = "No shift action has been recorded yet.",
    detail = "",
  }
end
M.getShiftStartDiagnostics = function(facId)
  return {
    facId = facId,
    detail = parts.dispatch.diagnoseDispatch(facId, "manual"),
    kinds = shared.summarizeKindMap(parts.eligibility.getAssignableKinds(facId)),
  }
end
M.acceptReturn = parts.endDay.acceptReturn
M.endDay = parts.endDay.endDay
M.endBusShiftNow = parts.endDay.endBusShiftNow
M.abandonAssignmentQuote = parts.endDay.abandonAssignmentQuote
M.abandonAssignment = function(facId)
  return parts.assignment.callShiftAction("abandonAssignment", parts.endDay.abandonEmploymentAssignment, facId)
end
-- Public API: shift screens -----------------------------------------------------------------------

M.openShiftUi = parts.projections.openShiftUi
M.closeShiftUi = parts.projections.closeShiftUi
M.canOpenFacilityShiftUi = function(facId)
  if not facId then return false end
  if parts.eligibility.isRoleplayFacility(facId) then return true end
  return isEmployed() and parts.dropOff.facilityMatchesEmployer(facId) or false
end
M.tryOpenFacilityShiftUi = function(facId)
  if not M.canOpenFacilityShiftUi(facId) then return false end
  return parts.projections.openShiftUi(facId)
end
M.isRoleplayFacility = function(facId)
  return parts.eligibility.isRoleplayFacility(facId)
end
M.onShiftRouteLeave = parts.projections.onShiftRouteLeave
-- Public API: cargo and drop-off ------------------------------------------------------------------

M.openDropOffUi = parts.projections.openDropOffUi
M.closeDropOffUi = parts.projections.closeDropOffUi
M.onDropOffRouteLeave = parts.projections.onDropOffRouteLeave
M.willAutoOpenDropOffAt = parts.routing.willAutoOpenDropOffAt
M.shouldOpenEmployeeDropOff = parts.dropOff.shouldOpenEmployeeDropOff
M.isEmployeeDropOffBlocked = parts.routing.isEmployeeDropOffBlocked
M.confirmEmployeeDropOff = parts.dropOff.confirmEmployeeDropOff
M.tryAutoDropOffAssigned = parts.dropOff.tryAutoDropOffAssigned
M.consumeDropOffMoneyForEscrow = parts.settlement.consumeDropOffMoneyForEscrow
M.onDropOffSettlementAborted = function()
  if not screen.dropOffEscrowPending and not screen.holdDropOffForProgress then return end
  screen.dropOffEscrowPending = false
  screen.holdDropOffForProgress = false
  parts.projections.notifyUi()
end
M.recordDropOffRewardProgress = function(repDelta)
  screen.lastDropOffProgress = (type(repDelta) == "table" and repDelta.gain ~= nil) and repDelta or nil
  screen.holdDropOffForProgress = screen.lastDropOffProgress ~= nil
  if screen.dropOffOpen then parts.projections.notifyUi() end
end
M.onRepoDeliveryComplete = parts.backhaul.handleEmploymentRepoComplete
M.afterCompanyDropOff = parts.dropOff.afterCompanyDropOff
M.trySetShiftRoute = parts.dropOff.trySetShiftRoute
M.tryAutoLoadAssignedParcelsAtSpot = parts.parcelLoading.tryAutoLoadAssignedParcelsAtSpot
M.hasAssignedReturnCargoAtSpot = parts.parcelLoading.hasAssignedReturnCargoAtSpot
M.stageAssignedReturnPickup = parts.parcelLoading.stageAssignedReturnPickup
M.clearAwaitingParkIfWorking = function()
  local shift = state.shift
  if shift and shift.awaitingPark and parts.dropOff.assignmentStillInProgress() then
    shift.awaitingPark = nil
    shift.parkedNotified = nil
    shift.pendingClockOut = nil
    parts.projections.refreshTaskGuidance(true)
  end
end
M.isEmployeeDropOffOpen = function()
  return screen.dropOffOpen and true or false
end
M.isAssignedCargo = function(item) return parts.persistence.isAssignedFreight(state.shift,item,"parcel") end
-- Live materials belong to a contract rather than the saved parcel-id list.
M.isJobCargo = function(item) return parts.dropOff.cargoIsAssigned(item) end
M.isAssignedVehicleOffer = function(item) return parts.persistence.isAssignedFreight(state.shift,item,"vehicle") end
M.canMoveCargoOntoLocation = parts.dropOff.canMoveCargoOntoLocation
-- Public API: company vehicles and accidents ------------------------------------------------------

M.getIssuedTruckForJob = function(facility, jobKind, cargoType, targetLoad)
  -- The career-owned capabilities extension is absent when employment is inspected from the menu.
  local loanerCapabilities = overhaul_career_logistics_loanerCapabilities
  return loanerCapabilities and loanerCapabilities.getIssuedTruckForJob(facility, jobKind, cargoType, targetLoad) or nil, nil
end
M.getUiState = parts.projections.getUiState
M.canReportAccident = function()
  return parts.accidents.canReportAccident() or false
end
M.reportAccident = function(preferredVehId)
  return parts.accidents.reportAccident(preferredVehId) or false
end
M.claimAccidentReplacement = function()
  return parts.accidents.claimAccidentReplacement() or false
end
M.getDropOffUiState = parts.projections.getDropOffUiState
M.getListings = parts.hiring.getListings
M.isEmploymentUnlocked = parts.eligibility.isEmploymentUnlocked
M.getDeliveryLevel = parts.eligibility.getDeliveryLevel
M.isApprenticeshipEnabled = parts.eligibility.isApprenticeshipEnabled
M.isOmittedFromEmployment = parts.eligibility.isOmittedFromEmployment
M.isVehicleDistributorFacility = parts.eligibility.isVehicleDistributorFacility
M.isOwnerOpYardFacility = parts.eligibility.isOwnerOpYardFacility
M.classifyRoleplayOrg = parts.eligibility.classifyRoleplayOrg
M.allowsOwnerOpYardBoard = parts.eligibility.allowsOwnerOpYardBoard
M.isLegacyFreelanceLogistics = function()
  local mode = overhaul_career_work_logisticsEmploymentMode
  if mode and mode.isLegacyFreelance then
    return mode.isLegacyFreelance()
  end
  if mode and mode.hasChosen and not mode.hasChosen() then
    return true
  end
  return false
end
M.hasEmploymentModeChoice = function()
  local mode = overhaul_career_work_logisticsEmploymentMode
  return mode and mode.hasChosen and mode.hasChosen() or false
end
M.canUseCargoBoard = function(facId)
  if parts.eligibility.getCargoBoardBlockMessage(facId) then return false end
  return true
end
M.getCargoBoardBlockMessage = parts.eligibility.getCargoBoardBlockMessage
M.shouldShowFreelanceInspectAt = parts.eligibility.shouldShowFreelanceInspectAt
M.facilityMatchesEmployer = function(facId)
  return parts.dropOff.facilityMatchesEmployer(facId)
end
M.getMapTravelBlockMessage = parts.eligibility.getMapTravelBlockMessage
M.canLoanIndependently = function()
  return true
end
M.usesEmploymentPayForOrg = function(orgId)
  return isOnShift() and orgId ~= nil and orgId == state.employerOrgId
end
M.isRoleplayShift = function()
  if not isOnShift() or not state.shift then return false end
  local kind = state.shift.jobKind
  return shared.kindPolicy(kind).roleplay
end
M.blocksRoleplay = function()
  return isOnShift() and state.shift ~= nil and not M.isRoleplayShift()
end
-- Public API: pay ---------------------------------------------------------------------------------

M.shouldEscrowRoleplayPay = function()
  return M.isRoleplayShift()
end
M.depositRoleplayEscrow = function(label, gross, finance)
  if not M.shouldEscrowRoleplayPay() then return nil end
  local source = state.shift and state.shift.jobKind or "employment"
  if source == "paramedic" then source = "ambulance" end
  local snapshot = require("overhaul/lib/finance/metadata").copy(finance or {vehicleRole = "player"})
  snapshot.source = source
  local keep = parts.settlement.addEscrowKeep(label or "Shift pay", gross, parts.projections.getCompanyShare(),
    "roleplay", nil, snapshot)
  parts.persistence.flushEmploymentCache()
  parts.projections.notifyUi()
  return keep
end
M.applyEmploymentPayToBreakdown = function(originalRewards, breakdown, adjustedRewards)
  if not isOnShift() or not state.employerOrgId or type(breakdown) ~= "table" or type(adjustedRewards) ~= "table" then
    return originalRewards, breakdown, adjustedRewards
  end
  local filteredBreakdown, changed = {}, false
  for _, rewardBreakdown in ipairs(breakdown) do
    local stripLoanerMoney = false
    if rewardBreakdown and rewardBreakdown.simpleBreakdownType == "loaner" then
      for key, _ in pairs(rewardBreakdown.rewards or {}) do
        local orgId = type(key) == "string" and key:match("^(.*)Reputation$")
        if orgId and orgId == state.employerOrgId then
          stripLoanerMoney = true
          break
        end
      end
    end
    if stripLoanerMoney then
      local loanerDeductionMoney = tonumber(rewardBreakdown.rewards and rewardBreakdown.rewards.money) or 0
      if loanerDeductionMoney ~= 0 then
        adjustedRewards.money = (tonumber(adjustedRewards.money) or 0) - loanerDeductionMoney
        changed = true
      end
      local reputationOnlyBreakdown = { label = rewardBreakdown.label, rewards = {}, simpleBreakdownType = "loaner" }
      for key, amount in pairs(rewardBreakdown.rewards or {}) do
        if key ~= "money" then reputationOnlyBreakdown.rewards[key] = amount end
      end
      if next(reputationOnlyBreakdown.rewards) then
        table.insert(filteredBreakdown, reputationOnlyBreakdown)
      end
    else
      table.insert(filteredBreakdown, rewardBreakdown)
    end
  end
  if changed then
    return originalRewards, filteredBreakdown, adjustedRewards
  end
  return originalRewards, breakdown, adjustedRewards
end

-- Public API: returned equipment ------------------------------------------------------------------

M.onIssuedVehicleReturnedDamaged = function(inventoryId, _amount)
  if state.ignoreCompanyDamageStrikes or state.accidentReportInProgress then return end
  if not isEmployed() then return end
  local vehicleInfo = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not (vehicleInfo and vehicleInfo.loanType == "company" and vehicleInfo.owningOrganization == state.employerOrgId) then
    return
  end
  parts.settlement.handleCompanyVehicleDamaged()
end

-- Return Loaner during a shift: clear issued tracking and unlock End day payout when only yard-return / wreck recovery remains.
M.onIssuedVehicleReturned = function(inventoryId)
  if state.ignoreCompanyDamageStrikes or state.companyEquipmentHandoff or state.restoringFreight then return end
  local shift = state.shift
  if not shift then return end
  if not (isOnShift() or shift.paused) then return end
  if shift.issuedInventoryIds then
    local keep = {}
    for _, id in ipairs(shift.issuedInventoryIds) do
      if id ~= inventoryId then table.insert(keep, id) end
    end
    shift.issuedInventoryIds = keep
  end
  if state.accidentReportInProgress then
    parts.projections.notifyUi()
    return
  end
  if parts.assignment.issuedVehiclesStillPresent() then
    parts.projections.notifyUi()
    return
  end
  -- No company vehicles left in inventory: treat as recovered / returned.
  shift.assignedCargoIds = {}
  shift.assignedOfferId = nil
  shift.assignedOfferIds = nil
  shift.stops = nil
  shift.stringMode = nil
  shift.returnNeedsPickup = nil
  shift.needsRemotePickup = nil
  shift.awaitingPark = nil
  shift.pendingClockOut = nil
  shift.phase = "loopComplete"
  shift.returnLabel = "Company vehicle returned"
  shift.returnSubtext = "End day anytime to collect held pay"
  if shift.paused then
    shift.paused = false
  end
  parts.projections.refreshTaskGuidance(true)
  parts.projections.notifyUi()
  ui_message("Company vehicle returned. End day to collect held pay.", 7, "info")
end

-- Public API: shift kinds --------------------------------------------------------------------------

M.isKindOnShift = function(kindId)
  return isOnShift() and state.shift ~= nil and state.shift.jobKind == kindId or false
end
M.shiftKindDefinitions = function()
  if not runtime.kindCatalog then runtime.kindCatalog = shared.jobKinds.load() end
  return runtime.kindCatalog.list
end
shared.kindAssignmentResolver = function(kindId, selection)
  local kind = shared.kindDefinition(kindId)
  if not kind then return nil end
  return function(id)
    local job, reason
    if kind.handlers and kind.handlers.buildAssignment then
      local context = parts.dispatch.dispatchContext()
      context.kind = deepcopy(kind)
      if kind.handlers.marketOffering then
        context.facId = id
        context.fac = shared.generator() and shared.generator().getFacilityById(id)
        local offering = shared.kindHandler(kindId, 'marketOffering', context, id)
        if type(offering) ~= 'table' or offering.available ~= true then
          return nil, type(offering) == 'table' and offering.unavailableReason or 'This kind is unavailable at this yard.'
        end
      end
      job, reason = shared.kindHandler(kindId, 'buildAssignment', context, id, selection)
    else
      job, reason = parts.dispatch.resolveSelectedJob(id, selection or kindId)
    end
    if type(job) ~= 'table' or job.kind ~= kindId then
      return nil, reason or "The kind did not provide an assignment with its saved id."
    end
    return job
  end
end
M.startKindShift = function(kindId, facId, selection)
  local resolveJob = shared.kindAssignmentResolver(kindId, selection)
  if not resolveJob then return shared.failShift("Shift kind is unavailable.", tostring(kindId)) end
  if runtime.nextAssignmentTransition then return shared.okShift({preparing = true}) end
  if state.shift and state.shift.paused and state.shift.jobKind ~= kindId then
    return shared.failShift("Continue or end the held assignment before starting another kind.")
  end
  return parts.assignment.callShiftAction('startShift', function(id) return parts.assignment.startShift(id, resolveJob) end, facId)
end
M.shiftAdmission = function(facId) return parts.assignment.startShiftGate(facId) end
M.refreshKindGuidance = function(...) return parts.projections.refreshTaskGuidance(...) end
M.kindAllowsPersonalVehicle = function(kindId, ...) return shared.kindHandler(kindId, 'allowsPersonalVehicle', ...) end
M.performKindAction = function(kindId, name, ...)
  local definition = shared.kindDefinition(kindId)
  if not definition then return nil, shared.jobKinds.outcome(runtime.kindCatalog, kindId) end
  local names = require('overhaul/lib/activity/definition').SHIFT_ACTIONS
  if not names[name] then return nil, 'unknown shift action' end
  return require('overhaul/lib/activity/access').get().action(definition.activity, name, ...)
end
M.refreshKindActivities = function()
  M.activity = employmentActivityDefinitions(M)
end
M.getKindLoadOutcome = function() return parts.persistence.currentKindLoadOutcome() end
M.onModActivated = parts.kindContract.kindsChanged
M.onModDeactivated = function(modData)
  if modIdentity.isOwnMod(modData) then return end
  parts.kindContract.kindsChanged()
end
M.retryMissingKind = parts.kindContract.retryMissingKind

-- Game hooks --------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onClientStartMission = shared.registerSponsorPayer
M.onClientEndMission = function()
  releaseCareerHooks()
  parts.assignment.finishNextAssignmentTransition()
end
M.onExtensionUnloaded = function()
  releaseCareerHooks()
  parts.assignment.finishNextAssignmentTransition()
end
M.onOverhaulActive = function(active)
  if active then
    runtime.kindCatalog = nil
    shared.registerSponsorPayer()
    parts.settlement.registerWageHolder()
  else
    releaseCareerHooks()
  end
end
M.onVehicleSwitched = function()
  local shift = state.shift
  if not shift or not shift.awaitingCompanyVehicleEntry then return end
  if not parts.equipment.playerInIssuedCompanyTruck() then
    parts.equipment.routeToCompanyTruck()
    return
  end
  shift.awaitingCompanyVehicleEntry = nil
  if not shared.kindPolicy(shift.jobKind).roleplay then
    parts.routing.routeCurrentAssignment()
  end
  parts.projections.refreshTaskGuidance(true)
end
M.onUiReady = function(uiType)
  if uiType == "vue" then parts.projections.refreshActiveTaskGuidance() end
end
M.onOverhaulDeliveryCargoLoadingStarted = function(token)
  if not state.shift then return end
  runtime.pendingCargoTaskRefresh = {token = token, isCurrent = parts.projections.makeAssignmentGuard()}
end
M.onOverhaulDeliveryCargoLoadingFinished = function(token)
  local pending = runtime.pendingCargoTaskRefresh
  if not pending or pending.token ~= token then return end
  runtime.pendingCargoTaskRefresh = nil
  if pending.isCurrent() then parts.projections.refreshActiveTaskGuidance() end
end
M.onCareerActivated = onCareerActivated
M.onWorldReadyState = function(worldReadyState)
  if worldReadyState == 2 and not runtime.loadedShiftReconciled then
    runtime.loadedShiftReconciled = true
    parts.kindContract.kindLoadStarted()
    core_jobsystem.create(function(job)
      job.sleep(0)
      if overhaul_career_work_employment ~= M then return end
      local inventory = overhaul_career_garage_inventory
      for attempt = 1, 300 do
        if not (inventory and inventory.isVehicleRestorePending and inventory.isVehicleRestorePending()) then break end
        job.sleep(0.1)
        if overhaul_career_work_employment ~= M then return end
        if attempt == 300 then
          ui_message("Assignment recovery is waiting for vehicle restoration. Reload the save to retry.", 10, "warning")
          return
        end
      end
      parts.persistence.loadEmploymentCache(shared.currentMapId())
      -- Another map's shift may have come in: judge its kind the way the load did.
      if state.shift and state.shift ~= runtime.kindLoadOutcomeShift then parts.persistence.checkSavedKind() end
      if parts.persistence.savedKindUnavailable() then parts.kindContract.kindLoadAwaitingKind() return end
      -- A queued retry reconciles the shift it was asked for, never one that replaced it meanwhile.
      if parts.kindContract.kindLoadTargetCurrent() then
        parts.persistence.reconcileLoadedShift()
        state.restoringFreight=nil
        parts.accidents.restoreAccidentCargoBox()
        parts.kindContract.restoreKindShift()
      end
      parts.kindContract.kindLoadFinished()
      if isOnShift() or (state.shift and state.shift.paused) then
        parts.projections.refreshTaskGuidance(true)
      else
        parts.projections.clearTaskGuidance()
      end
      parts.projections.notifyUi()
    end)
  end
end
M.onExtensionLoaded = onExtensionLoaded
-- Reloading a career on the current map does not emit a new world-ready event. The existing reconciliation guard keeps activation and map loading idempotent.
M.onOverhaulActivationReady = function()
  M.onWorldReadyState(2)
end
M.onOverhaulSaveCurrentProfile = parts.persistence.saveState

M.refreshKindActivities()

-- Recovery menu -----------------------------------------------------------------------------------

-- Read company-vehicle availability before the return-ignoring accident action.
function M.isRecoveryReportAccidentAvailable(target)
  local ok, result = pcall(function()
    if not M.isOnShift() then return false end
    local inventory = overhaul_career_garage_inventory
    if not (inventory and inventory.getInventoryIdFromVehicleId) then return false end
    local inventoryId = inventory.getInventoryIdFromVehicleId(target and target.vehId)
    local vehicle = inventoryId and inventory.getVehicles()[inventoryId]
    return vehicle and vehicle.loanType == "company" or false
  end)
  return ok and result or false
end

function M.runRecoveryReportAccident(target)
  M.reportAccident(target and target.vehId)
end

return M
