-- AI racers config: level and race settings, race paths, staging spots, paint and the lineup snapshot.
-- aiRacers.lua creates one instance per load with its own M, state table and caches, so a reload shares nothing.

-- Reading order: configuration and state, lib.create, lib.create, lib.create, then public API and engine hooks.
-- Contract: create() binds the owning extension load; mutable event state belongs to that owner.
local lib = {}
local circuitConfig = require("overhaul/lib/events/circuitConfig")

-- Constants ---------------------------------------------------------------------------------------

-- Fallback spawns still resolve .pc files under this folder when the JSON omits aiRaceConfigSubdir.
local DEFAULT_AI_RACE_CONFIG_SUBDIR = "rls_race_ai"
local VEHICLE_POOL_TIERS = { "stock", "modified", "super", "open" }
local SPAWN_DEBUG_LOG_MAX_CHARS = 4500
local SPAWN_DEBUG_UI_MAX_CHARS = 1400
local SPAWN_DEBUG_UI_SECONDS = 30

-- Fields a race table (race_data) may still override on top of the level and per-race config.
local RACE_OVERRIDE_KEYS = {
  "spawnSameVehicleAsPlayer",
  "aiCount",
  "aiVehicles",
  "enabled",
  "maxSpawnCount",
  "driveInLane",
  "useNavgraphPathfinding",
  "scriptPathWidth",
  "scriptBootstrapDistance",
  "navTargetReachDistance",
  "launchRecoveryGraceSeconds",
  "startEngineOnSpawn",
  "recoveryEnabled",
  "recoverySpeedThresholdMps",
  "recoveryStuckSeconds",
  "recoveryCooldownSeconds",
  "despawnWreckedEnabled",
  "despawnWreckedDuringRace",
  "despawnUpsideDownSeconds",
  "despawnAfterRecoveries",
  "despawnTerminalStuckSeconds",
  "despawnAlwaysStuckSeconds",
  "delayedDespawnDefaultSeconds",
  "delayedDespawnStaggerSeconds",
  "filterPoolByPowerWeightMeetOrExceed",
  "filterPoolByPowerMeetOrExceed",
  "aiPowerExceedCapPct",
  "aiPoolCloseAbovePw",
  "aiPoolCloseAboveHp",
  "aiSpawnDebugUi",
  "aiSpawnDebugLog",
  "pathRoad",
  "raceAccelScale",
  "raceThrottleKp",
  "raceThrottleRateMult",
  "raceThrottleRecoveryMult",
  "targetSpeedSmootherRate",
  "raceWideLineTrafficBlend",
  "raceWideLineLateralStartM",
  "raceWideLineLateralEndM",
  "raceWideLineUndersteerRelax",
  "raceThrottleFloor",
  "raceHighSpeedThreshold",
  "raceHighSpeedThrottleFloor",
  "raceCornerLineLiftMaxM",
  "raceCornerCurvStart",
  "raceCornerCurvEnd",
  "raceCornerLineLiftScale",
  "raceTrafficPassBlend",
  "raceClearanceScaleMin",
  "raceAltPlanSpeedMargin",
  "raceAltPlanTimeMargin",
  "raceAwarenessCoefScale",
  "raceBlockedAheadDistMax",
  "raceClearancePassMinGainM",
  "raceClearancePassTrafficEps",
  "raceBrakeGain",
  "raceCornerGripUtil",
  "raceCornerPlanBoost",
  "raceCommitCorners",
  "raceCornerExitPush",
  "raceCornerExitPushMinGain",
  "raceCornerExitPushOvershoot",
  "raceCornerExitPushRiseRate",
  "raceCornerExitPushSlipMax",
  "raceUndersteerSlipMin",
  "raceGripLiveRiseRate",
  "raceCommitTargetOvershoot",
  "raceCommitSpeedFloorPct",
  "raceSlipTarget",
  "raceSlipGain",
  "raceFrictionMult",
}

function lib.create(ownerServices)
  local M = ownerServices.M
  local racerState = ownerServices.racerState
  local mPathCache = ownerServices.mPathCache
  local mRaceConfigCache = ownerServices.mRaceConfigCache

  -- Paint and lineup snapshot -----------------------------------------------------------------------

  local function pickRandomAiColor()
    return ownerServices.AI_COLOR_PALETTE[math.random(1, #ownerServices.AI_COLOR_PALETTE)]
  end

  -- Paints only the AI car: core_vehicle_colors.setVehicleColor merges configs into the player's car too.
  local function applyAiBasePaintOnly(vehId, colorString)
    if not vehId or not colorString then return end
    local vehicleManager = extensions.core_vehicle_manager
    if not vehicleManager or not vehicleManager.getVehicleData or not vehicleManager.liveUpdateVehicleColors then
      return
    end
    local vehicleColors = extensions.core_vehicle_colors
    local colorToTable = vehicleColors and vehicleColors.colorStringToColorTable
    if not colorToTable then return end
    local vehicleData = vehicleManager.getVehicleData(vehId)
    if not vehicleData or not vehicleData.config then return end
    vehicleData.config.paints = vehicleData.config.paints or {}
    local color = colorToTable(colorString)
    if not color then return end
    color[4] = color[4] * 2
    local paint = createVehiclePaint(
      { x = color[1], y = color[2], z = color[3], w = color[4] },
      { color[5], color[6], color[7], color[8] }
    )
    local paintIndex = 1
    vehicleData.config.paints[paintIndex] = paint
    local vehicle = getObjectByID(vehId)
    if not vehicle then return end
    vehicleManager.liveUpdateVehicleColors(vehId, vehicle, paintIndex, paint)
  end

  local function copyLineupSnapshot(lineup)
    local copy = {}
    if type(lineup) ~= "table" then return copy end
    for _, row in ipairs(lineup) do
      if type(row) == "table" and type(row.model) == "string" and type(row.config) == "string" then
        table.insert(copy, {
          model = row.model,
          config = row.config,
          matchPw = tonumber(row.matchPw) or tonumber(row.powerHp) or nil,
        })
      end
    end
    return copy
  end

  local function setLastSpawnedLineupSnapshot(lineup)
    racerState.mLastSpawnedAiLineupSnapshot = copyLineupSnapshot(lineup)
  end

  -- Level and race config ---------------------------------------------------------------------------

  local function mergedCopy(defaults, overrides)
    local merged = {}
    for key, value in pairs(defaults) do
      merged[key] = value
    end
    if type(overrides) == "table" then
      for key, value in pairs(overrides) do
        merged[key] = value
      end
    end
    return merged
  end

  local function getCurrentLevelConfig()
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then return mergedCopy(ownerServices.DEFAULT_CONFIG, nil) end
    local fromFile = jsonReadFile(
      "levels/" .. levelId .. "/" .. ownerServices.CONFIG_DIR .. "/" .. ownerServices.CONFIG_FILENAME
    )
    local cfg = mergedCopy(ownerServices.DEFAULT_CONFIG, fromFile)
    if type(cfg.defaultVehiclePool) ~= "table" or #cfg.defaultVehiclePool == 0 then
      cfg.defaultVehiclePool = ownerServices.DEFAULT_CONFIG.defaultVehiclePool
    end
    return cfg
  end

  -- Per-race overrides use event IDs, with optional route-specific settings.
  local function loadRaceConfig()
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then return { byRace = {}, definitions = {} } end
    if mRaceConfigCache[levelId] then return mRaceConfigCache[levelId] end
    local data = jsonReadFile(
      "levels/" .. levelId .. "/" .. ownerServices.CONFIG_DIR .. "/" .. ownerServices.CONFIG_RACE_FILENAME
    )
    local raceConfig = { byRace = {}, definitions = circuitConfig.loadRaceDefinitions(levelId) }
    if type(data) == "table" then
      if type(data.byRace) == "table" then raceConfig.byRace = data.byRace end
      if type(data.vehiclePool) == "table" then raceConfig.vehiclePool = data.vehiclePool end
      if data.aiRaceConfigSubdir ~= nil then raceConfig.aiRaceConfigSubdir = data.aiRaceConfigSubdir end
    end
    mRaceConfigCache[levelId] = raceConfig
    return raceConfig
  end

  local function getRoadPathKey(race)
    if not race or not race.checkpointRoad then return nil end
    if type(race.checkpointRoad) == "string" then return race.checkpointRoad end
    if type(race.checkpointRoad) == "table" then
      -- A single road reference has the same path key as its string form.
      if #race.checkpointRoad == 1 and type(race.checkpointRoad[1]) == "string" then return race.checkpointRoad[1] end
      return serialize(race.checkpointRoad)
    end
    return nil
  end

  local function getRacePathKey(race)
    local roadKey = getRoadPathKey(race)
    if not roadKey then return nil end
    if race._competitiveRaceId then
      return race._competitiveRaceId .. ":" .. (race._competitiveRouteType or "main")
    end
    return roadKey
  end

  -- Prefixes each pool config with the on-disk subdir under the vehicle folder.
  local function copyVehiclePoolWithConfigSubdir(vehiclePool, subdir)
    if type(vehiclePool) ~= "table" or type(subdir) ~= "string" or subdir == "" then return vehiclePool end
    local copy = {}
    for _, tier in ipairs(VEHICLE_POOL_TIERS) do
      local rows = vehiclePool[tier]
      if type(rows) == "table" then
        copy[tier] = {}
        for _, row in ipairs(rows) do
          if type(row) == "table" then
            local rowCopy = {}
            for key, value in pairs(row) do
              rowCopy[key] = value
            end
            if
              type(rowCopy.config) == "string"
              and rowCopy.config ~= ""
              and not string.find(rowCopy.config, "/", 1, true)
            then
              rowCopy.config = subdir .. "/" .. rowCopy.config
            end
            table.insert(copy[tier], rowCopy)
          end
        end
      end
    end
    return copy
  end

  local function applyRaceFields(merged, race)
    for _, key in ipairs(RACE_OVERRIDE_KEYS) do
      if race[key] ~= nil then merged[key] = race[key] end
    end
  end

  local function applyPoolOverrides(merged, raceConfig, overrides)
    if type(raceConfig.vehiclePool) == "table" then merged.vehiclePool = raceConfig.vehiclePool end
    if type(overrides.vehiclePool) == "table" then merged.vehiclePool = overrides.vehiclePool end
    if raceConfig.aiRaceConfigSubdir ~= nil then merged.aiRaceConfigSubdir = raceConfig.aiRaceConfigSubdir end
    if
      type(merged.vehiclePool) == "table"
      and type(merged.aiRaceConfigSubdir) == "string"
      and merged.aiRaceConfigSubdir ~= ""
    then
      merged.vehiclePool = copyVehiclePoolWithConfigSubdir(merged.vehiclePool, merged.aiRaceConfigSubdir)
    end
  end

  local function resolveRaceIdentity(race, raceName, raceConfig)
    local id = raceName or race._competitiveRaceId or race.raceName or race.id
    local routeType = race._competitiveRouteType
    if id then return id, routeType end
    local pathKey = getRoadPathKey(race)
    for name, definition in pairs(raceConfig.definitions) do
      local row = definition.race
      local route = getRoadPathKey(row) == pathKey and "main"
        or (row.altRoute and getRoadPathKey(row.altRoute) == pathKey and "alt")
      if pathKey and route then
        if id then return nil, nil end -- shared geometry needs an explicit event ID
        id, routeType = name, route
      end
    end
    return id, routeType
  end

  -- Level settings, then actual event ID/route settings, then the race's own fields.
  local function getMergedConfigForRace(race, raceName)
    local levelConfig = getCurrentLevelConfig()
    if not race then
      if not raceName then return levelConfig end
      race = {}
    end
    local pathKey = getRoadPathKey(race)
    local raceConfig = loadRaceConfig()
    local id, routeType = resolveRaceIdentity(race, raceName, raceConfig)
    local overrides = raceConfig.byRace[id] or raceConfig.byRace[pathKey] or {}
    if routeType == "alt" and type(overrides.routes) == "table" then
      overrides = mergedCopy(overrides, overrides.routes.alt)
    end
    local merged = mergedCopy(levelConfig, overrides)
    local definition = raceConfig.definitions[id]
    merged.staging = race.staging or (definition and definition.staging) or overrides.staging
    merged.competitive = definition and definition.competitive or race.competitive
    applyRaceFields(merged, race)
    applyPoolOverrides(merged, raceConfig, overrides)
    merged.sanctioned = nil
    return merged
  end

  local function aiRaceConfigSubdirForFallbackSpawn(cfg)
    if type(cfg) == "table" and type(cfg.aiRaceConfigSubdir) == "string" and cfg.aiRaceConfigSubdir ~= "" then
      return cfg.aiRaceConfigSubdir
    end
    return DEFAULT_AI_RACE_CONFIG_SUBDIR
  end

  -- Path under vehicles/<model>/ for spawning; keys already written as "subdir/basename" stay as they are.
  local function poolConfigRelPathForSpawn(_spec, _modelKey, configKey, pathConfig)
    if type(configKey) ~= "string" or configKey == "" then return nil end
    if string.find(configKey, "/", 1, true) then return configKey end
    return aiRaceConfigSubdirForFallbackSpawn(pathConfig) .. "/" .. configKey
  end

  local function fillSpawnPlanCyclingRows(plan, rows, requestedCount)
    if type(plan) ~= "table" or type(rows) ~= "table" or #rows == 0 or type(requestedCount) ~= "number" then return end
    while #plan < requestedCount do
      local row = rows[(#plan % #rows) + 1]
      table.insert(plan, { model = row.model, config = row.config, matchPw = row.pw })
    end
  end

  local function getVehiclePoolForRace(raceName, race, facilityName, levelOrMergedConfig)
    local cfg = (type(levelOrMergedConfig) == "table" and levelOrMergedConfig) or getCurrentLevelConfig()
    local byRace = cfg.vehiclePoolByRace and cfg.vehiclePoolByRace[raceName]
    if type(byRace) == "table" and #byRace > 0 then return byRace end
    local byFacility = cfg.vehiclePoolByFacility and cfg.vehiclePoolByFacility[facilityName]
    if type(byFacility) == "table" and #byFacility > 0 then return byFacility end
    if type(race) == "table" and type(race.aiVehicles) == "table" and #race.aiVehicles > 0 then
      return race.aiVehicles
    end
    return cfg.defaultVehiclePool
  end

  -- Spawn debug output ------------------------------------------------------------------------------

  local function aiSpawnDebugEnabled(cfg)
    return type(cfg) == "table" and (cfg.aiSpawnDebugUi == true or cfg.aiSpawnDebugLog == true)
  end

  local function truncated(text, maxChars)
    if #text > maxChars then return text:sub(1, maxChars) .. "..." end
    return text
  end

  -- Turned on per level with aiSpawnDebugUi / aiSpawnDebugLog in competitiveRace/aiRacers.json.
  local function showAiSpawnDebugUi(cfg, lines)
    if not aiSpawnDebugEnabled(cfg) or type(lines) ~= "table" or #lines == 0 then return end
    local text = table.concat(lines, "\n")
    if cfg.aiSpawnDebugLog == true then
      log("I", "aiRacers", "[aiSpawnDebug]\n" .. truncated(text, SPAWN_DEBUG_LOG_MAX_CHARS))
    end
    if cfg.aiSpawnDebugUi == true then
      ui_message(truncated(text, SPAWN_DEBUG_UI_MAX_CHARS), SPAWN_DEBUG_UI_SECONDS, "AI spawn debug")
    end
  end

  -- Race paths and staging spots --------------------------------------------------------------------

  -- Nodes of a DecalRoad by name; used when aiRacingConfig sets pathRoad. Checkpoints keep using race.checkpointRoad.
  local function getRoadNodesByName(roadName)
    if type(roadName) ~= "string" or roadName == "" then return nil end
    local road = scenetree.findObject(roadName)
    if not road or road:getClassName() ~= "DecalRoad" then return nil end
    local nodeCount = 0
    if road.getNodeCount then nodeCount = road:getNodeCount() end
    if nodeCount <= 0 then return nil end
    local nodeTable = {}
    if road.getNodesTable then nodeTable = road:getNodesTable() or {} end
    local roadNodes = {}
    for i = 0, nodeCount - 1 do
      local position = road:getNodePosition(i)
      if position then
        local width = (nodeTable[i + 1] and nodeTable[i + 1][2]) or nil
        table.insert(roadNodes, { x = position.x, y = position.y, z = position.z, width = width })
      end
    end
    return #roadNodes > 0 and roadNodes or nil
  end

  local function cachePathFromNodes(cacheKey, nodes)
    if not nodes or #nodes == 0 then return end
    local path = {}
    for _, node in ipairs(nodes) do
      if node.x and node.y and node.z then table.insert(path, { x = node.x, y = node.y, z = node.z }) end
    end
    if #path > 0 then mPathCache[cacheKey] = path end
  end

  -- Builds the AI path from race.checkpointRoad (or the pathRoad override), plus one path per lane when the race has lanes.
  function M.preloadPathForRace(race)
    local roadCheckpoints = overhaul_events_roadCheckpoints
    if not roadCheckpoints then return end
    local pathKey = getRacePathKey(race)
    if not pathKey then return end
    if not mPathCache[pathKey] then
      local pathRoad = getMergedConfigForRace(race).pathRoad
      pathRoad = (type(pathRoad) == "string" and pathRoad ~= "") and pathRoad or nil
      cachePathFromNodes(
        pathKey,
        pathRoad and getRoadNodesByName(pathRoad) or roadCheckpoints.getRoadNodesFromRace(race)
      )
    end
    if race.checkpointRoadLanes and type(race.checkpointRoadLanes) == "table" and #race.checkpointRoadLanes > 0 then
      for laneIndex = 0, #race.checkpointRoadLanes - 1 do
        local lanePathKey = pathKey .. "_lane_" .. tostring(laneIndex)
        if not mPathCache[lanePathKey] then
          cachePathFromNodes(lanePathKey, roadCheckpoints.getRoadNodesFromRace(race, laneIndex))
        end
      end
    end
  end

  function M.preloadPathsForRaces(racesById)
    if type(racesById) ~= "table" then return end
    for _, race in pairs(racesById) do
      if race and race.checkpointRoad then M.preloadPathForRace(race) end
    end
  end

  function M.levelHasAiRacingConfig()
    local raceConfig = loadRaceConfig()
    return type(raceConfig) == "table" and type(raceConfig.byRace) == "table" and next(raceConfig.byRace) ~= nil
  end

  local function loadStagingSpots(race, raceName)
    local cfg = getMergedConfigForRace(race, raceName)
    local staging, reason = circuitConfig.loadStaging(cfg.staging)
    return staging and staging.aiSpots, reason
  end

  return {
    pickRandomAiColor = pickRandomAiColor,
    applyAiBasePaintOnly = applyAiBasePaintOnly,
    copyLineupSnapshot = copyLineupSnapshot,
    setLastSpawnedLineupSnapshot = setLastSpawnedLineupSnapshot,
    aiSpawnDebugEnabled = aiSpawnDebugEnabled,
    showAiSpawnDebugUi = showAiSpawnDebugUi,
    aiRaceConfigSubdirForFallbackSpawn = aiRaceConfigSubdirForFallbackSpawn,
    poolConfigRelPathForSpawn = poolConfigRelPathForSpawn,
    fillSpawnPlanCyclingRows = fillSpawnPlanCyclingRows,
    getCurrentLevelConfig = getCurrentLevelConfig,
    getRacePathKey = getRacePathKey,
    getMergedConfigForRace = getMergedConfigForRace,
    loadStagingSpots = loadStagingSpots,
    getVehiclePoolForRace = getVehiclePoolForRace,
  }
end

return lib
