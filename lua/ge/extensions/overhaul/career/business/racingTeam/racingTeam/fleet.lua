-- Racing team fleet rules: catalog and book value of team vehicles, sanctioned class branch, effective power and cooldowns.
-- Read map: catalog lookups, book and sell value, power helpers, job link, effective power, branch, damage, cooldowns, rtInternal mirrors.
local M = {}

local rtState = require('overhaul/career/business/racingTeam/racingTeam/runtimeState')
local racingTeamBuildClass = require('overhaul/career/business/racingTeam/racingTeam/buildClass')
local jbeamIO = require('jbeam/io')

local function normalizeBusinessId(v)
  return tonumber(v) or v
end

-- Catalog lookups ---------------------------------------------------------------------------------

function M.getCatalogVehicleInfo(model_key, config_key)
  if not model_key or not config_key then
    return nil
  end
  if not rtState.rtInternal.eligibleVehicleInfoByPair then
    rtState.rtInternal.eligibleVehicleInfoByPair = {}
    local list = util_configListGenerator.getEligibleVehicles(false, false) or {}
    for _, vi in ipairs(list) do
      if vi.model_key and vi.key then
        rtState.rtInternal.eligibleVehicleInfoByPair[vi.model_key .. "\0" .. vi.key] = vi
      end
    end
  end
  local vi = rtState.rtInternal.eligibleVehicleInfoByPair[model_key .. "\0" .. config_key]
  if vi then
    return vi
  end
  local stripped = tostring(config_key):match("^(.+)%.pc$")
  if stripped then
    vi = rtState.rtInternal.eligibleVehicleInfoByPair[model_key .. "\0" .. stripped]
    if vi then
      return vi
    end
  end
  return nil
end

-- Adds one parts-tree node's value to the accumulator when it is installed, and records the part by its path.
local function walkPartsTree(node, parts, installed, ioCtx, vehicleYear, vehicle, acc)
  if type(node) ~= "table" then
    return
  end
  local name = node.chosenPartName
  if type(name) == "string" and name ~= "" then
    local partData = jbeamIO.getPart(ioCtx, name)
    if partData and partData.information and partData.information.value then
      local value = tonumber(partData.information.value) or 0
      if installed then acc.total = acc.total + value end
      if node.path then
        parts[node.path] = {name = name, value = value, year = vehicleYear,
          partCondition = installed and vehicle.partConditions and vehicle.partConditions[node.partPath]
            or {odometer = vehicle.mileage or 0, integrityValue = 1}}
      end
    end
  end
  local children = node.children
  if type(children) == "table" then
    for _, child in pairs(children) do
      walkPartsTree(child, parts, installed, ioCtx, vehicleYear, vehicle, acc)
    end
  end
end

-- Loads the vehicle's JBeam parts and returns the installed value, the installed parts and the stock parts.
local function sumInstalledPartsTreeJbeamValue(partsTree, modelKey, logContext, configKey, vehicleYear, vehicle)
  if type(partsTree) ~= "table" or not modelKey or modelKey == "" then
    return nil
  end
  local ioCtx
  local acc = {total = 0}
  local installedParts, originalParts = {}, nil
  local ok, err = pcall(function()
    ioCtx = jbeamIO.startLoading({"/vehicles/" .. tostring(modelKey) .. "/", "/vehicles/common/"})
    walkPartsTree(partsTree, installedParts, true, ioCtx, vehicleYear, vehicle, acc)
    if configKey then
      local pc = jsonReadFile('/vehicles/' .. modelKey .. '/' .. configKey .. '.pc')
        or jsonReadFile('/vehicles/' .. modelKey .. '/configurations/' .. configKey .. '.pc')
      if pc then
        pc = deepcopy(pc)
        pc.mainPartName = pc.mainPartName or jbeamIO.getMainPartName(ioCtx)
        pc.mainPartPath = pc.mainPartPath or '/' .. pc.mainPartName
        local _, _, _, stockTree = require('jbeam/slotSystem').findParts(ioCtx, pc)
        if stockTree then
          originalParts = {}
          walkPartsTree(stockTree, originalParts, false, ioCtx, vehicleYear, vehicle, acc)
        end
      end
    end
  end)
  if ioCtx then jbeamIO.finishLoading() end
  if not ok then
    log("D", "Career", string.format(
      "sumInstalledPartsTreeJbeamValue failed (%s): %s",
      tostring(logContext or "racingTeamFleet"),
      tostring(err)))
    return nil
  end
  if acc.total <= 0 then
    return nil
  end
  return acc.total, installedParts, originalParts
end

-- Book and sell value -----------------------------------------------------------------------------

local function catalogVehicleYear(cfg)
  if type(cfg) ~= "table" then
    return nil
  end
  local year = tonumber(cfg.Year)
  if year and year > 0 then
    return year
  end
  local years = cfg.Years or (cfg.aggregates and cfg.aggregates.Years)
  if type(years) == "table" then
    year = tonumber(years.min) or tonumber(years.max)
    if year and year > 0 then
      return year
    end
  elseif type(years) == "number" then
    if years > 0 then
      return years
    end
  end
  return nil
end

local function catalogVehicleBaseValue(cfg)
  if type(cfg) ~= "table" then
    return nil
  end
  local value = tonumber(cfg.Value)
    or tonumber(cfg.value)
    or tonumber(cfg["Base Value"])
    or tonumber(cfg.baseValue)
    or tonumber(cfg.Price)
    or tonumber(cfg.price)
  if value and value > 0 then
    return value
  end
  return nil
end

-- The valuation from the installed parts when the stock tree is known, else the plain catalog value.
local function partsBookEstimate(valueCalculator, opts, installedParts, originalParts, vehicle)
  local valuation = valueCalculator.getVehicleValuation(opts)
  if not valuation then
    return nil
  end
  return valueCalculator.getVehicleValueFromParts(valuation.bookValue,
    originalParts, installedParts, vehicle.changedSlots, valuation.ageFactor, valuation.mileageFactor)
end

-- Returns the catalog estimate for a team vehicle, or nil when the catalog cannot value it.
local function catalogBookEstimate(vehicle, modelKey, configKey)
  local valueCalculator = overhaul_career_market_valueCalculator
  if not (modelKey and configKey) then
    return nil
  end
  local cfg = M.getCatalogVehicleInfo(modelKey, configKey)
  local catalogBaseValue = catalogVehicleBaseValue(cfg)
  local vehicleYear = catalogVehicleYear(cfg)
  local nowYear = (os.date("*t") or {}).year or 2023
  local age = vehicleYear and math.max(0, nowYear - vehicleYear) or nil
  if not catalogBaseValue or age == nil then
    return nil
  end
  local partsCatalogSum, installedParts, originalParts = nil, nil, nil
  local storedCfg = vehicle.config
  if type(storedCfg) == "table" and storedCfg.partsTree then
    partsCatalogSum, installedParts, originalParts = sumInstalledPartsTreeJbeamValue(
      storedCfg.partsTree, modelKey, "racingTeamFleet", configKey, vehicleYear, vehicle)
  end
  local opts = {
    catalogBaseValue = catalogBaseValue,
    mileageMeters = tonumber(vehicle.mileage) or 0,
    age = age,
    modelName = modelKey,
    configKey = configKey,
    logContext = "racingTeam"
  }
  if partsCatalogSum then
    opts.partsCatalogSum = partsCatalogSum
  end
  local estimate = nil
  if originalParts then
    estimate = partsBookEstimate(valueCalculator, opts, installedParts, originalParts, vehicle)
  end
  if estimate == nil then estimate = valueCalculator.getVehicleCatalogIntrinsicBookValue(opts) end
  return estimate
end

function M.getTeamVehicleBookValue(vehicle)
  if type(vehicle) ~= "table" then
    return 0
  end
  local vc = vehicle.vehicleConfig or {}
  local modelKey = vc.model_key or vehicle.model_key
  local configKey = vc.key or vc.config_key or vehicle.config_key
  local estimate = tonumber(catalogBookEstimate(vehicle, modelKey, configKey))
  if estimate and estimate >= 0 then
    return math.floor(estimate + 0.5)
  end
  local purchasePrice = tonumber(vehicle.purchasePrice) or 0
  if purchasePrice > 0 then
    return math.floor(purchasePrice + 0.5)
  end
  return 0
end

function M.getTeamVehicleSellValue(vehicle, fallbackValue)
  local value = M.getTeamVehicleBookValue(vehicle)
  if value <= 0 then
    value = math.max(0, math.floor(tonumber(fallbackValue) or 0))
  end
  local valueCalculator = overhaul_career_market_valueCalculator
  do
    local mult = tonumber(valueCalculator.getVehicleSellMarketMultiplier()) or 1
    value = value * mult
  end
  value = math.floor(math.max(0, value) + 0.5)
  if value <= 0 then
    local fallback = tonumber(fallbackValue) or 0
    if fallback > 0 then
      value = math.max(0, math.floor(fallback * 0.75))
    end
  end
  return value
end

-- Power and weight helpers ------------------------------------------------------------------------

local function vehicleInfoPowerHp(vi)
  if not vi then
    return nil
  end
  local power = tonumber(vi.Power)
  if not power and vi.aggregates and vi.aggregates.Power then
    local agg = vi.aggregates.Power
    power = tonumber(agg.min) or tonumber(agg.max)
  end
  if power and power > 0 then
    return power
  end
  return nil
end

local function vehicleInfoWeightKg(vi)
  if not vi or type(vi) ~= "table" then
    return nil
  end
  local w = tonumber(vi.total_weight)
  if not w and vi.aggregates and vi.aggregates.total_weight then
    w = tonumber(vi.aggregates.total_weight)
  end
  return w
end

local function hpPerKgFromHpAndWeightKg(hp, wkg)
  local h, w = tonumber(hp), tonumber(wkg)
  if not h or h <= 0 or not w or w <= 0 then
    return nil
  end
  return h / w
end

local function configWeightKgFromModelConfig(modelKey, configKey)
  local c = core_vehicles.getConfig(modelKey, configKey)
  if not c then
    return nil
  end
  local w = c.total_weight or (c.aggregates and c.aggregates.total_weight)
  return tonumber(w)
end

function M.getSanctionedStockPwCeiling()
  local sr = overhaul_events_fre_sanctionedRacing
  if sr and sr.getStockClassPwCeiling then
    local c = tonumber(sr.getStockClassPwCeiling())
    if c and c > 0 then
      return c
    end
  end
  return 0.2822
end

-- Job link ----------------------------------------------------------------------------------------

function M.inventoryVehicleLinkedToActiveRacingJob(businessId, vehicle)
  if not vehicle or vehicle.vehicleId == nil then
    return false
  end
  local vid = tostring(tonumber(vehicle.vehicleId) or vehicle.vehicleId)
  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  for _, v in ipairs(vehicles) do
    if tostring(tonumber(v.vehicleId) or v.vehicleId) == vid then
      return true
    end
  end
  return false
end

-- Effective power ---------------------------------------------------------------------------------


-- A dyno peak beats the catalog power; the peak's recorded weight beats the catalog weight.
function M.getEffectiveTeamJobVehicleHp(businessId, vehicle)
  if not vehicle or vehicle.vehicleId == nil then
    return nil
  end
  local vid = vehicle.vehicleId
  if vid == nil then
    return nil
  end
  local id = tostring(normalizeBusinessId(businessId))
  local vidStr = tostring(vid)
  local peaks = rtState.classOptimizationPeakHpByBusiness[id]
  local rawPeak = peaks and peaks[vidStr]
  local dyno = nil
  if type(rawPeak) == "table" then
    dyno = tonumber(rawPeak.hp)
  else
    dyno = tonumber(rawPeak)
  end
  local vc = vehicle.vehicleConfig
  local mk = vc and vc.model_key
  local ck = vc and (vc.key or vc.config_key)
  local catHp = nil
  if mk and ck then
    catHp = vehicleInfoPowerHp(M.getCatalogVehicleInfo(mk, ck))
  end
  local best = tonumber(dyno) or tonumber(catHp) or 0
  if best <= 0 then
    return nil
  end
  return best
end

function M.getEffectiveTeamJobVehiclePw(businessId, vehicle)
  local hp = M.getEffectiveTeamJobVehicleHp(businessId, vehicle)
  if not hp then
    return nil
  end
  local vc = vehicle and vehicle.vehicleConfig or {}
  local mk = vc.model_key or (vehicle and vehicle.model_key)
  local ck = vc.key or vc.config_key or (vehicle and vehicle.config_key)
  if not mk or not ck then
    return nil
  end
  local vi = M.getCatalogVehicleInfo(mk, ck)
  local idPw = tostring(normalizeBusinessId(businessId))
  local peaks = rtState.classOptimizationPeakHpByBusiness[idPw]
  local rawPeak = peaks and peaks[tostring(vehicle.vehicleId)]
  local dynoW = nil
  if type(rawPeak) == "table" then
    dynoW = tonumber(rawPeak.weightKg)
  end
  local wkg = dynoW or vehicleInfoWeightKg(vi) or configWeightKgFromModelConfig(mk, ck)
  return hpPerKgFromHpAndWeightKg(hp, wkg)
end

function M.getBestTeamJobVehicleHp(businessId)
  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  local best = nil
  for _, v in ipairs(vehicles) do
    local hp = M.getEffectiveTeamJobVehicleHp(businessId, v)
    if hp and (not best or hp > best) then
      best = hp
    end
  end
  return best
end

function M.getBestTeamJobVehiclePw(businessId)
  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  local best = nil
  for _, v in ipairs(vehicles) do
    local pw = M.getEffectiveTeamJobVehiclePw(businessId, v)
    if pw and (not best or pw > best) then
      best = pw
    end
  end
  return best
end

-- Sanctioned class branch -------------------------------------------------------------------------

function M.resolveFleetVehicleSanctionedBranch(businessId, vehicle)
  local pw = M.getEffectiveTeamJobVehiclePw(businessId, vehicle)
  local sr = overhaul_events_fre_sanctionedRacing
  local pwBr = "stock"
  if pw and sr and sr.getSanctionedBranchForPw then
    pwBr = sr.getSanctionedBranchForPw(pw)
  end
  local vc = vehicle and vehicle.vehicleConfig or {}
  local mk = vc.model_key or vehicle and vehicle.model_key
  local ck = vc.key or vc.config_key
  local pt = vehicle and vehicle.config and vehicle.config.partsTree
  return racingTeamBuildClass.resolveSanctionedBranchForFleetVehicle(mk, pt, pwBr, ck)
end

-- The best branch any team vehicle reaches; without the build-class rules, the best power decides.
function M.getSanctionedBranchFilterForBusiness(businessId)
  if not racingTeamBuildClass.ENABLED then
    local pw = M.getBestTeamJobVehiclePw(businessId)
    local sr = overhaul_events_fre_sanctionedRacing
    if sr and sr.getSanctionedBranchForPw then
      return sr.getSanctionedBranchForPw(pw)
    end
    return "stock"
  end
  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  local bestR = 0
  for _, v in ipairs(vehicles) do
    local br = M.resolveFleetVehicleSanctionedBranch(businessId, v)
    local r = racingTeamBuildClass.branchRank(br)
    if r > bestR then
      bestR = r
    end
  end
  if bestR > 0 then
    return racingTeamBuildClass.branchFromRank(bestR)
  end
  local pw = M.getBestTeamJobVehiclePw(businessId)
  local sr = overhaul_events_fre_sanctionedRacing
  if sr and sr.getSanctionedBranchForPw then
    return sr.getSanctionedBranchForPw(pw)
  end
  return "stock"
end

function M.getRandomFleetVehicleSanctionedBranch(businessId)
  local vehicles = overhaul_career_business_fleet.getBusinessVehicles(businessId) or {}
  if #vehicles == 0 then
    return M.getSanctionedBranchFilterForBusiness(businessId)
  end
  local vPick = vehicles[math.random(1, #vehicles)]
  return M.resolveFleetVehicleSanctionedBranch(businessId, vPick)
end

-- Damage ------------------------------------------------------------------------------------------

function M.getDamageThreshold(businessId)
  return 1500
end

function M.getSpawnedBusinessVehicleDamageInfo(businessId, vehicleId)
  local threshold = M.getDamageThreshold(businessId)
  local info = {
    locked = false,
    damage = 0,
    threshold = threshold
  }
  if not businessId or vehicleId == nil then
    return info
  end
  local getSid = overhaul_career_business_fleet.getSpawnedVehicleId
  local spawnedId = getSid(businessId, vehicleId)
  -- Live map data can disappear during level teardown.
  if not spawnedId or not map.objects then
    return info
  end
  local objectData = map.objects[spawnedId]
  if not objectData then
    return info
  end
  local damage = tonumber(objectData.damage) or 0
  info.damage = damage
  info.locked = damage >= threshold
  return info
end

-- Cooldowns ---------------------------------------------------------------------------------------


-- Seconds left on a cooldown: the wall-clock deadline wins when present, else the sim deadline.
local function cooldownSecondsLeft(wallEpochValue, untilSimValue)
  local wallEpoch = tonumber(wallEpochValue)
  if wallEpoch and wallEpoch > 0 then
    local rem = wallEpoch - os.time()
    if rem <= 0 then
      return 0
    end
    return math.max(0, math.ceil(rem))
  end
  local untilSim = tonumber(untilSimValue)
  if not untilSim then
    return 0
  end
  local now = rtState.parts.board.getCareerSimTimeSeconds()
  if now >= untilSim then
    return 0
  end
  return math.max(0, math.ceil(untilSim - now))
end

-- Base cooldown scaled by the driver cooldown skill node; the player and the fleet share the same node.
local function cooldownSecondsForBusiness(businessId, baseSeconds)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return baseSeconds
  end
  local lv = 0
  lv = rtState.parts.helpers.getSkillTreeNodeLevel(businessId, "driver", "cooldown") or 0
  local mult = 1 - rtState.K.RACING_TEAM_COOLDOWN_REDUCTION_PER_LEVEL * lv
  mult = math.max(0.05, mult)
  return math.max(1, math.floor(baseSeconds * mult + 0.5))
end

function M.getRacingTeamPostRaceCooldownSeconds(businessId)
  return cooldownSecondsForBusiness(businessId, rtState.K.RACING_TEAM_POST_RACE_COOLDOWN_BASE_SEC)
end

function M.getRacingTeamPlayerPostRaceCooldownSeconds(businessId)
  return cooldownSecondsForBusiness(businessId, rtState.K.RACING_TEAM_PLAYER_POST_RACE_COOLDOWN_BASE_SEC)
end

function M.getFleetVehiclePostRaceCooldownRemainingSec(businessId, vehicleId)
  if vehicleId == nil then
    return 0
  end
  local id = tostring(normalizeBusinessId(businessId))
  local vid = tostring(tonumber(vehicleId) or vehicleId)
  local rec = (rtState.vehicleCooldownByBusiness[id] or {})[vid]
  if type(rec) ~= "table" then
    return 0
  end
  return cooldownSecondsLeft(rec.wallEpoch, rec.untilSim)
end

function M.armFleetVehiclePostRaceCooldown(businessId, vehicleId)
  if vehicleId == nil then
    return
  end
  local id = tostring(normalizeBusinessId(businessId))
  local vid = tostring(tonumber(vehicleId) or vehicleId)
  local cdSec = M.getRacingTeamPostRaceCooldownSeconds(businessId)
  rtState.vehicleCooldownByBusiness[id] = rtState.vehicleCooldownByBusiness[id] or {}
  rtState.vehicleCooldownByBusiness[id][vid] = {
    untilSim = rtState.parts.board.getCareerSimTimeSeconds() + cdSec,
    wallEpoch = os.time() + cdSec,
  }
end

function M.getPlayerPostRaceCooldownRemainingSec(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  local rec = rtState.playerCooldownByBusiness[id]
  if type(rec) ~= "table" then
    return 0
  end
  return cooldownSecondsLeft(rec.wallEpoch, rec.untilSim)
end

function M.armPlayerPostRaceCooldown(businessId)
  local id = tostring(normalizeBusinessId(businessId))
  if id == "nil" then
    return
  end
  local cdSec = M.getRacingTeamPlayerPostRaceCooldownSeconds(businessId)
  rtState.playerCooldownByBusiness[id] = {
    untilSim = rtState.parts.board.getCareerSimTimeSeconds() + cdSec,
    wallEpoch = os.time() + cdSec,
  }
end

function M.getRacingTeamDriverPostRaceCooldownRemainingSec(businessId, tech)
  if not tech then
    return 0
  end
  return cooldownSecondsLeft(tech.postRaceCooldownReadyWallEpoch, tech.racingCooldownUntilSimTime)
end

-- Arms the fleet vehicle and, for a player race alongside proxies, the player cooldown; then saves the team.
function M.armFleetVehicleCooldownAfterSanctionedRaceSettled(offer)
  if type(offer) ~= "table" then
    return
  end
  if offer.racingTeamBusinessOffer ~= true and offer.league1PlayerRace ~= true then
    return
  end
  local bid = offer.businessId
  if bid == nil or bid == "" then
    return
  end
  bid = normalizeBusinessId(bid)
  if not bid then
    return
  end
  local vid = tonumber(offer.requiredFleetVehicleId) or offer.requiredFleetVehicleId
    or tonumber(offer.fleetVehicleId) or offer.fleetVehicleId
  if vid ~= nil then
    M.armFleetVehiclePostRaceCooldown(bid, vid)
  end
  -- Only league-2+ player races alongside proxies arm the player cooldown; league 1 keeps the fleet-only cooldown.
  if offer.playerProxyAlongsideRace == true then
    M.armPlayerPostRaceCooldown(bid)
  end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath then
    rtState.parts.persist.saveRacingTeamPersistedState(bid, savePath)
  end
end

return M
