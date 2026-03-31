-- AI racers for competitive (circuit) races.
-- Spawns AI vehicles at AI_stage_* spots on staging, then releases them on GO with script-path AI.

local M = {}

M.dependencies = { 'gameplay_events_freeroam_processRoad' }

local CONFIG_DIR = "competitiveRace"
local CONFIG_FILENAME = "aiRacers.json"
local CONFIG_RACE_FILENAME = "aiRacingConfig.json"
local LEGACY_SITES_FILENAME = "competitiveRaceAI.sites.json"
local DEFAULT_CONFIG = {
    enabled = true,
    sitesFile = LEGACY_SITES_FILENAME,
    stagingPrefix = "AI_stage_",
    maxSpawnCount = 5,
    routeSpeed = 70,
    -- When false, AI speed is controlled by aggression only (like base game missions); when true, routeSpeed caps speed.
    useRouteSpeedLimit = false,
    aggressionMin = 0.6,
    aggressionMax = 0.75,
    avoidCars = "on",
    -- Circuit racing: 'off' lets AI use full track width and racing line; base game missions do not use driveInLane for race AI.
    driveInLane = "off",
    routeSpeedMode = "limit",
    useNavgraphPathfinding = true,
    -- Racing AI tuning (matches base game Race AI Parameters flowgraph). Skill 0-1: higher = tighter line, better avoidance.
    racerSkill = 0.8,
    useRacingParameters = true,
    -- Rubberband: AI eases off when ahead, pushes when behind (optional, like base missions).
    rubberBand = true,
    -- Script path width in metres at each node (prevents narrow path and corner clipping).
    scriptPathWidth = 2.5,
    navTargetReachDistance = 20,
    launchRecoveryGraceSeconds = 6,
    defaultVehiclePool = { "etk800", "sunburst", "200bx", "covet", "vivace", "grandmarshal" },
    recoveryEnabled = true,
    recoverySpeedThresholdMps = 1.0,
    recoveryStuckSeconds = 3.0,
    recoveryCooldownSeconds = 10.0,
    despawnWreckedEnabled = true,
    -- When false, no AI is despawned for stuck/wreck during race; only post-race delayed/clear despawn runs.
    despawnWreckedDuringRace = false,
    despawnUpsideDownSeconds = 8.0,
    despawnAfterRecoveries = 2,
    despawnTerminalStuckSeconds = 15.0,
    despawnAlwaysStuckSeconds = 25.0,
    delayedDespawnDefaultSeconds = 60.0,
    delayedDespawnStaggerSeconds = 4.0,
    startEngineOnSpawn = true,
    scriptBootstrapDistance = 6.0,
    -- AI pool power filter: only spawn models with power <= refHp * (1 + aiPowerExceedCapPct). No lower bound. Set false to skip filtering.
    filterPoolByPowerMeetOrExceed = true,
    aiPowerExceedCapPct = 0.25,
    -- vehiclePool: only spawn AI configs with HP in (player, player + this]; if none, 1× next-higher pool car + player clones for the rest.
    aiPoolCloseAboveHp = 75,
    -- On-screen ui_message after staging AI spawn (HP, pool plan, etc.). Per-level aiRacers.json overrides; false = off.
    aiSpawnDebugUi = false,
    -- overrideAI: multiplies lateral/longitudinal grip budget in raceplanAhead (1.0 = default, >1 = faster in corners).
    raceAccelScale = 1.1,
    raceThrottleKp = 1.12,
    -- driveToTarget: throttle pedal ramp (4 matches old state-based when raceAccelScale is set). Higher = on power sooner after braking.
    raceThrottleRateMult = 4,
    raceThrottleRecoveryMult = 1.9,
    -- driveUsingPath setParameters: higher = plan.targetSpeed follows planner faster (exit / straights).
    targetSpeedSmootherRate = 18,
    -- Wide-line racing (overrideAI): when lateral offset from plan exceeds start→end (m), blend traffic-limited speed back toward geometric cap (never above it).
    raceWideLineTrafficBlend = 0.4,
    raceWideLineLateralStartM = 0.9,
    raceWideLineLateralEndM = 2.6,
    -- Soften understeer throttle lift when wide — keeps commitment on an alternate line.
    raceWideLineUndersteerRelax = 0.45,
    -- Corner line sacrifice (overrideAI): shift plan nodes outward in tight bends (curvature ~1/m). 0 = off.
    raceCornerLineLiftMaxM = 0.22,
    raceCornerCurvStart = 0.022,
    raceCornerCurvEnd = 0.10,
    raceCornerLineLiftScale = 1.0,
}

local mSpawnedAiVehicleIds = {}
local mPathCache = {}  -- racePathKey -> array of { x, y, z }
local mRecoveryStateByVehId = {} -- [vehId] = { stuckTime, cooldown }
local mRetiredUpsideDownByVehId = {} -- [vehId] = true
local mRecoveryMonitorEnabled = false
local mRecoveryCheckAccumulator = 0
local mActiveRaceForRecovery = nil
local mActiveLapCountForRecovery = 1
local mVehicleLaneIndexByVehId = {}  -- [vehId] = laneIndex (for recovery to re-use same lane path)
local mNavStateByVehId = {} -- [vehId] = { path, targetIndex, lapsRemaining, aggression, targetX, targetY, targetZ }
local mRecoveryGraceTimer = 0
local mDelayedDespawnActive = false
local mDelayedDespawnWaiting = false
local mDelayedDespawnTimer = 0
local mDelayedDespawnStaggerSeconds = 4.0
local mPlayerUnfreezeAt = nil  -- os.clock() time when to unfreeze player after AI GO (avoids dt spikes)
local mDnfCallback = nil  -- called with vehId when an AI is despawned (DNF)
-- Cache for per-race AI config (aiRacingConfig.json byRace): [levelId] = { byRace = { pathKey -> overrides } }
local mRaceConfigCache = {}
-- Forward declarations for helpers used before their definitions.
local cancelDelayedDespawn
local queueEngineStart

-- Random colors for AI (r g b a, 0-1; a=1). Applied same-frame after spawn so no visible change.
local AI_COLOR_PALETTE = {
    "0.9 0.1 0.1 1",   -- red
    "0.1 0.2 0.7 1",   -- blue
    "0.95 0.75 0.05 1", -- gold
    "0.1 0.65 0.2 1",  -- green
    "0.6 0.1 0.6 1",   -- purple
    "0.0 0.0 0.0 1",   -- black
    "0.85 0.4 0.0 1",  -- orange
    "0.2 0.8 0.9 1",   -- cyan
    "0.9 0.9 0.9 1",   -- white
    "0.4 0.25 0.1 1",  -- brown
    "0.7 0.0 0.0 1",   -- dark red
    "0.0 0.35 0.6 1",  -- navy
}

local function pickRandomAiColor()
    local idx = math.random(1, #AI_COLOR_PALETTE)
    return AI_COLOR_PALETTE[idx]
end

local function aiSpawnDebugEnabled(cfg)
    return type(cfg) == "table" and cfg.aiSpawnDebugUi == true
end

local function showAiSpawnDebugUi(cfg, lines)
    --[[ Staging debug overlay: live player power read + AI slot picks. Uncomment to restore; set aiSpawnDebugUi: true in level competitiveRace/aiRacers.json.
    if not aiSpawnDebugEnabled(cfg) or type(lines) ~= "table" or #lines == 0 then return end
    if type(ui_message) ~= "function" then return end
    local text = table.concat(lines, "\n")
    if #text > 1400 then
        text = text:sub(1, 1400) .. "..."
    end
    pcall(function()
        ui_message(text, 30, "AI spawn debug")
    end)
    --]]
end

local function shallowCopyDefaults(defaults, fromFile)
    local out = {}
    for k, v in pairs(defaults) do out[k] = v end
    if type(fromFile) == "table" then
        for k, v in pairs(fromFile) do out[k] = v end
    end
    return out
end

local function getCurrentLevelConfig()
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then
        return shallowCopyDefaults(DEFAULT_CONFIG, nil)
    end
    local configPath = "levels/" .. levelId .. "/" .. CONFIG_DIR .. "/" .. CONFIG_FILENAME
    local fromFile = jsonReadFile(configPath)
    local cfg = shallowCopyDefaults(DEFAULT_CONFIG, fromFile)
    if type(cfg.defaultVehiclePool) ~= "table" or #cfg.defaultVehiclePool == 0 then
        cfg.defaultVehiclePool = DEFAULT_CONFIG.defaultVehiclePool
    end
    return cfg
end

-- Load aiRacingConfig.json (per-race overrides in byRace). Keys in byRace = getRacePathKey(race), e.g. "trackloop", "trackalt".
local function loadRaceConfig()
    local levelId = getCurrentLevelIdentifier()
    if not levelId or levelId == "" then return { byRace = {} } end
    if mRaceConfigCache[levelId] then return mRaceConfigCache[levelId] end
    local path = "levels/" .. levelId .. "/" .. CONFIG_DIR .. "/" .. CONFIG_RACE_FILENAME
    local data = jsonReadFile(path)
    local result = { byRace = {} }
    if type(data) == "table" then
        if type(data.byRace) == "table" then result.byRace = data.byRace end
        if type(data.vehiclePool) == "table" then result.vehiclePool = data.vehiclePool end
    end
    mRaceConfigCache[levelId] = result
    return result
end

-- True if the current level has aiRacingConfig.json with at least one byRace entry.
function M.levelHasAiRacingConfig()
    local rc = loadRaceConfig()
    return type(rc) == "table" and type(rc.byRace) == "table" and next(rc.byRace) ~= nil
end

local function getRacePathKey(race)
    if not race or not race.checkpointRoad then return nil end
    if type(race.checkpointRoad) == "string" then
        return race.checkpointRoad
    end
    if type(race.checkpointRoad) == "table" then
        -- Single-element array (e.g. ["trackloop"]) must match aiRacingConfig.byRace keys like "trackloop"
        if #race.checkpointRoad == 1 and type(race.checkpointRoad[1]) == "string" then
            return race.checkpointRoad[1]
        end
        return serialize(race.checkpointRoad)
    end
    return nil
end

-- Merged config for a race: level aiRacers.json + aiRacingConfig.byRace[pathKey] + race table (race_data) for backward compat.
-- Use this wherever we have a race and want AI settings (spawn, drive, recovery). pathKey = getRacePathKey(race), e.g. "trackloop" or "trackalt".
local function getMergedConfigForRace(race)
    local levelCfg = getCurrentLevelConfig()
    if not race then return levelCfg end
    local pathKey = getRacePathKey(race)
    if not pathKey or pathKey == "" then return levelCfg end
    local raceConfig = loadRaceConfig()
    local overrides = (raceConfig.byRace and raceConfig.byRace[pathKey]) or {}
    local merged = shallowCopyDefaults(levelCfg, overrides)
    -- Backward compat: race_data.json structure only. No tuning (state-based in overrideAI). No route speed, no rubberband here (rubberband later by XP).
    local raceKeys = {
        "spawnSameVehicleAsPlayer", "aiCount", "aiVehicles",
        "enabled", "maxSpawnCount", "driveInLane", "useNavgraphPathfinding",
        "scriptPathWidth", "scriptBootstrapDistance", "navTargetReachDistance",
        "launchRecoveryGraceSeconds", "startEngineOnSpawn", "recoveryEnabled", "recoverySpeedThresholdMps",
        "recoveryStuckSeconds", "recoveryCooldownSeconds", "despawnWreckedEnabled", "despawnWreckedDuringRace",
        "despawnUpsideDownSeconds", "despawnAfterRecoveries", "despawnTerminalStuckSeconds", "despawnAlwaysStuckSeconds",
        "delayedDespawnDefaultSeconds", "delayedDespawnStaggerSeconds",
        "filterPoolByPowerMeetOrExceed", "aiPowerExceedCapPct", "aiPoolCloseAboveHp", "aiSpawnDebugUi",
        "pathRoad",
        "raceAccelScale", "raceThrottleKp",
        "raceThrottleRateMult", "raceThrottleRecoveryMult", "targetSpeedSmootherRate",
        "raceWideLineTrafficBlend", "raceWideLineLateralStartM", "raceWideLineLateralEndM",
        "raceWideLineUndersteerRelax", "raceThrottleFloor", "raceHighSpeedThreshold", "raceHighSpeedThrottleFloor",
        "raceCornerLineLiftMaxM", "raceCornerCurvStart", "raceCornerCurvEnd", "raceCornerLineLiftScale"
    }
    for _, k in ipairs(raceKeys) do
        if race[k] ~= nil then merged[k] = race[k] end
    end
    if type(raceConfig.vehiclePool) == "table" then
        merged.vehiclePool = raceConfig.vehiclePool
    end
    if type(overrides.vehiclePool) == "table" then
        merged.vehiclePool = overrides.vehiclePool
    end
    merged.sanctioned = nil
    return merged
end

-- Get nodes from a DecalRoad by name (for AI path when pathRoad is set in aiRacingConfig). Does not touch processRoad; checkpoints stay on race.checkpointRoad.
local function getRoadNodesByName(roadName)
    if type(roadName) ~= "string" or roadName == "" then return nil end
    if not scenetree or not scenetree.findObject then return nil end
    local road = scenetree.findObject(roadName)
    if not road or road:getClassName() ~= "DecalRoad" then return nil end
    local nodeCount = 0
    if road.getNodeCount then nodeCount = road:getNodeCount() end
    if nodeCount <= 0 then return nil end
    local nodeTable = {}
    if road.getNodesTable then nodeTable = road:getNodesTable() or {} end
    local roadNodes = {}
    for i = 0, nodeCount - 1 do
        local pos = road:getNodePosition(i)
        if pos then
            local width = (nodeTable[i + 1] and nodeTable[i + 1][2]) or nil
            table.insert(roadNodes, { x = pos.x, y = pos.y, z = pos.z, width = width })
        end
    end
    return #roadNodes > 0 and roadNodes or nil
end

-- Build path from race checkpointRoad (uses processRoad). Call on level load. When pathRoad is set in aiRacingConfig.byRace, use that road for AI path only; checkpoints unchanged. When race has checkpointRoadLanes, also preloads one path per lane (lane road merged with main from first checkpoint).
function M.preloadPathForRace(race)
    local pr = gameplay_events_freeroam_processRoad
    if not pr then return end
    local pathKey = getRacePathKey(race)
    if not pathKey then return end
    if not mPathCache[pathKey] then
        local cfg = getMergedConfigForRace(race)
        local pathRoad = (cfg and type(cfg.pathRoad) == "string" and cfg.pathRoad ~= "") and cfg.pathRoad or nil
        local nodes = pathRoad and getRoadNodesByName(pathRoad) or pr.getRoadNodesFromRace(race)
        if nodes and #nodes > 0 then
            local path = {}
            for _, node in ipairs(nodes) do
                if node.x and node.y and node.z then
                    table.insert(path, { x = node.x, y = node.y, z = node.z })
                end
            end
            if #path > 0 then
                mPathCache[pathKey] = path
            end
        end
    end
    if race.checkpointRoadLanes and type(race.checkpointRoadLanes) == "table" and #race.checkpointRoadLanes > 0 then
        for laneIndex = 0, #race.checkpointRoadLanes - 1 do
            local lanePathKey = pathKey .. "_lane_" .. tostring(laneIndex)
            if not mPathCache[lanePathKey] then
                local laneNodes = pr.getRoadNodesFromRace(race, laneIndex)
                if laneNodes and #laneNodes > 0 then
                    local lanePath = {}
                    for _, node in ipairs(laneNodes) do
                        if node.x and node.y and node.z then
                            table.insert(lanePath, { x = node.x, y = node.y, z = node.z })
                        end
                    end
                    if #lanePath > 0 then
                        mPathCache[lanePathKey] = lanePath
                    end
                end
            end
        end
    end
end

-- Preload all race paths from race data (call from manager after loading race JSON).
function M.preloadPathsForRaces(racesById)
    if type(racesById) ~= "table" then return end
    for _, race in pairs(racesById) do
        if race and race.checkpointRoad then
            M.preloadPathForRace(race)
        end
    end
end

-- Load staging spots for the current level. Returns array of spots { name, pos, rot } or nil.
-- Tries CONFIG_DIR subdir first (e.g. levels/west_coast_usa/competitiveRace/competitiveRaceAI.sites.json), then level root.
local function loadStagingSpots()
    local levelId = getCurrentLevelIdentifier()
    if not levelId then return nil end
    local cfg = getCurrentLevelConfig()
    local sitesFile = cfg.sitesFile or LEGACY_SITES_FILENAME
    local preferredPath = "levels/" .. levelId .. "/" .. CONFIG_DIR .. "/" .. sitesFile
    local data = jsonReadFile(preferredPath)
    if not data or not data.parkingSpots or #data.parkingSpots == 0 then
        local fallbackPath = "levels/" .. levelId .. "/" .. sitesFile
        data = jsonReadFile(fallbackPath)
    end
    if not data or not data.parkingSpots or #data.parkingSpots == 0 then return nil end
    local prefix = cfg.stagingPrefix or "AI_stage_"
    local spots = {}
    for _, spot in ipairs(data.parkingSpots) do
        local name = spot and spot.name or ""
        if type(name) == "string" and name:sub(1, #prefix) == prefix then
            table.insert(spots, spot)
        end
    end
    table.sort(spots, function(a, b)
        local an = tonumber((a.name or ""):match("(%d+)$")) or math.huge
        local bn = tonumber((b.name or ""):match("(%d+)$")) or math.huge
        return an < bn
    end)
    return spots
end

local function getVehiclePoolForRace(raceName, race, facilityName, levelOrMergedCfg)
    local cfg = (type(levelOrMergedCfg) == "table" and levelOrMergedCfg) or getCurrentLevelConfig()
    local byRace = cfg.vehiclePoolByRace and cfg.vehiclePoolByRace[raceName]
    if type(byRace) == "table" and #byRace > 0 then return byRace end
    local byFacility = cfg.vehiclePoolByFacility and cfg.vehiclePoolByFacility[facilityName]
    if type(byFacility) == "table" and #byFacility > 0 then return byFacility end
    if type(race) == "table" and type(race.aiVehicles) == "table" and #race.aiVehicles > 0 then
        return race.aiVehicles
    end
    return cfg.defaultVehiclePool
end

-- HP class bands (same as CLASS_MAX_HP): D 0-160, C 161-370, B 371-600, A 601+.
local function getClassFromHp(power)
    if type(power) ~= "number" or power < 0 then return "D" end
    if power <= 160 then return "D" end
    if power <= 370 then return "C" end
    if power <= 600 then return "B" end
    return "A"
end

-- vehiclePool class bands: stock <320, modified 320-550, super 550-699, open 700+ HP. Used when cfg.vehiclePool is set.
local STOCK_MAX_HP = 319
local MODIFIED_MAX_HP = 549
local SUPER_MAX_HP = 699
-- Configs within this many HP of the player are preferred when picking from the pool (then by closest).
local CLOSE_HP_TOLERANCE = 25
local function getClassFromHpForVehiclePool(power)
    if type(power) ~= "number" or power < 0 then return "stock" end
    if power <= STOCK_MAX_HP then return "stock" end
    if power <= MODIFIED_MAX_HP then return "modified" end
    if power <= SUPER_MAX_HP then return "super" end
    return "open"
end

-- Pool for a given HP class. Uses cfg.vehiclePoolByHpClass[class] if set, else defaultVehiclePool.
local function getVehiclePoolForHpClass(cfg, class)
    if not cfg then return DEFAULT_CONFIG.defaultVehiclePool end
    local byClass = cfg.vehiclePoolByHpClass and cfg.vehiclePoolByHpClass[class]
    if type(byClass) == "table" and #byClass > 0 then return byClass end
    return cfg.defaultVehiclePool or DEFAULT_CONFIG.defaultVehiclePool
end

-- Power unit conversion. 1 mechanical HP = 745.7 W.
local WATTS_PER_HP = 745.7
local function powerWattsToHp(watts)
    local w = tonumber(watts)
    if not w or w < 0 then return nil end
    return w / WATTS_PER_HP
end

-- Vehicle Lua engine.maxPower (and UI activeObjectLua) often returns HP-scale numbers (~400); large values are SI watts.
-- Same >10000 threshold as getPowerHpFromConfig. Callbacks expect watts.
local function liveMaxPowerRawToWatts(raw)
    local r = tonumber(raw)
    if not r or r < 0 then return nil end
    if r == 0 then return 0 end
    if r > 10000 then return r end
    return r * WATTS_PER_HP
end

-- Extract power in HP from a config table. Uses top-level config["Power"] (like vehiclePerformance), then config.aggregates.Power.
-- Handles: number (if > 10000 assume watts and convert, else assume HP), or table { propulsionPowerCombined = watts } or { min, max }.
local function getPowerHpFromConfig(config)
    if not config then return nil end
    local p = config["Power"] or (config.aggregates and config.aggregates.Power)
    if type(p) == "number" then
        if p > 10000 then return p / WATTS_PER_HP end
        return p
    end
    if type(p) == "table" then
        local w = p.propulsionPowerCombined or p.max or p.min
        if type(w) == "number" then
            if w > 10000 then return w / WATTS_PER_HP end
            return w
        end
    end
    return nil
end

-- Power for a vehicle model from config (no spawn). Returns power in HP, or nil.
-- When configKey is provided (e.g. "AI_Pessima_stock"), uses that config; otherwise default_pc.
local function getPowerForModelConfig(modelKey, configKey)
    if not modelKey or type(modelKey) ~= "string" then return nil end
    if not core_vehicles or not core_vehicles.getModel or not core_vehicles.getConfig then return nil end
    local data = core_vehicles.getModel(modelKey)
    if not data or not data.model or not data.configs then return nil end
    if not configKey or type(configKey) ~= "string" or configKey == "" then
        configKey = data.model.default_pc
        if not configKey then
            for k, _ in pairs(data.configs) do configKey = k break end
        end
    end
    if not configKey then return nil end
    local config = core_vehicles.getConfig(modelKey, configKey)
    return getPowerHpFromConfig(config)
end

-- peakHp (or hp / powerHp) on aiRacingConfig vehiclePool entries overrides core_vehicles lookup for matching and sanctioned fallback.
local function getPowerHpForPoolEntry(entry, model, config)
    if type(entry) == "table" then
        local d = tonumber(entry.peakHp) or tonumber(entry.hp) or tonumber(entry.powerHp)
        if d and d > 0 then return d end
    end
    if type(model) == "string" and type(config) == "string" then
        return getPowerForModelConfig(model, config)
    end
    return nil
end

local STAGING_DEBUG_AI_SLOTS = 4

local function stagingDebugConfigKeyFromPlayerSpawn(configKeyOrObj)
    if type(configKeyOrObj) == "string" and configKeyOrObj ~= "" then
        return configKeyOrObj
    end
    if type(configKeyOrObj) == "table" and type(configKeyOrObj.partConfigFilename) == "string" then
        local fn = configKeyOrObj.partConfigFilename:match("([^/\\]+)%.pc$")
        return fn or "default"
    end
    return nil
end

local function stagingDebugLivePlayerLine(powerDbg)
    if type(powerDbg.liveWatts) == "number" and powerDbg.liveWatts > 0 then
        local liveHp = powerWattsToHp(powerDbg.liveWatts)
        if type(liveHp) == "number" and liveHp > 0 then
            return string.format("live player power read = %.0f HP", liveHp)
        end
    end
    if type(powerDbg.syncDetailsHp) == "number" and powerDbg.syncDetailsHp > 0 then
        return string.format("live player power read = %.0f HP", powerDbg.syncDetailsHp)
    end
    return "live player power read = n/a"
end

local function stagingDebugHpForPlanSlot(spec, pModel, pConfigOrObj, powerDbg)
    if type(spec) ~= "table" then return 0 end
    if spec.clonePlayer then
        local ck = stagingDebugConfigKeyFromPlayerSpawn(pConfigOrObj)
        if type(pModel) == "string" and pModel ~= "" and ck then
            local h = getPowerForModelConfig(pModel, ck)
            if type(h) == "number" and h > 0 then return h end
        end
        if type(powerDbg.syncDetailsHp) == "number" and powerDbg.syncDetailsHp > 0 then
            return powerDbg.syncDetailsHp
        end
        return 0
    end
    local ph = tonumber(spec.powerHp)
    if ph and ph > 0 then return ph end
    if type(spec.model) == "string" and type(spec.config) == "string" then
        local h = getPowerForModelConfig(spec.model, spec.config)
        if type(h) == "number" and h > 0 then return h end
    end
    return 0
end

local function stagingDebugConfigLabelForPlanSlot(spec, pModel, pConfigOrObj)
    if type(spec) ~= "table" then return "—" end
    if spec.clonePlayer then
        local ck = stagingDebugConfigKeyFromPlayerSpawn(pConfigOrObj) or "default"
        local m = (type(pModel) == "string" and pModel ~= "") and pModel or "player"
        return string.format("%s/%s (clone)", m, ck)
    end
    if type(spec.model) == "string" and type(spec.config) == "string" then
        return spec.model .. "/" .. spec.config
    end
    return "—"
end

local function buildStagingSpawnDebugLinesFromPlan(powerDbg, plan, pModel, pConfigOrObj)
    local lines = { stagingDebugLivePlayerLine(powerDbg) }
    for i = 1, STAGING_DEBUG_AI_SLOTS do
        local spec = plan and plan[i]
        if spec then
            local label = stagingDebugConfigLabelForPlanSlot(spec, pModel, pConfigOrObj)
            local h = stagingDebugHpForPlanSlot(spec, pModel, pConfigOrObj, powerDbg)
            lines[#lines + 1] = string.format("AI %d = %s, %.0f HP", i, label, h)
        else
            lines[#lines + 1] = string.format("AI %d = —", i)
        end
    end
    return lines
end

local function buildStagingSpawnDebugLinesFromRecentSpawned(powerDbg, spawnedCount)
    local lines = { stagingDebugLivePlayerLine(powerDbg) }
    local total = type(mSpawnedAiVehicleIds) == "table" and #mSpawnedAiVehicleIds or 0
    local n = math.max(0, tonumber(spawnedCount) or 0)
    local startIdx = (n > 0) and (total - n + 1) or (total + 1)
    for i = 1, STAGING_DEBUG_AI_SLOTS do
        local vehIdx = startIdx + i - 1
        local vehId = mSpawnedAiVehicleIds[vehIdx]
        if vehId and core_vehicles and core_vehicles.getVehicleDetails then
            local details = core_vehicles.getVehicleDetails(vehId)
            local model = details and details.current and details.current.key
            local ckey = details and details.current and details.current.config_key
            local hp = 0
            if type(model) == "string" and type(ckey) == "string" then
                hp = tonumber(getPowerForModelConfig(model, ckey)) or 0
            end
            if hp <= 0 and details and details.configs then
                hp = tonumber(getPowerHpFromConfig(details.configs)) or 0
            end
            lines[#lines + 1] = string.format("AI %d = %s/%s, %.0f HP", i, tostring(model or "?"), tostring(ckey or "?"), hp)
        else
            lines[#lines + 1] = string.format("AI %d = —", i)
        end
    end
    return lines
end

-- Filter raw pool to models with power <= playerPowerHp * (1 + capPct). Any amount below that is allowed; none over the cap.
local function filterPoolByPower(rawPool, playerPowerHp, cfg)
    if type(rawPool) ~= "table" or #rawPool == 0 then return rawPool end
    if cfg.filterPoolByPowerMeetOrExceed ~= true or type(playerPowerHp) ~= "number" or playerPowerHp < 0 then return rawPool end
    local capPct = tonumber(cfg.aiPowerExceedCapPct)
    if not capPct or capPct < 0 then capPct = tonumber(DEFAULT_CONFIG.aiPowerExceedCapPct) or 0.25 end
    local maxPower = playerPowerHp * (1 + capPct)
    local out = {}
    for _, entry in ipairs(rawPool) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or entry
        if type(model) ~= "string" then goto continue end
        local configKey = type(entry) == "table" and entry.config or nil
        local modelPowerHp = getPowerForModelConfig(model, configKey)
        if modelPowerHp and modelPowerHp <= maxPower then
            table.insert(out, entry)
        end
        ::continue::
    end
    return out
end

local function getAvailableModelLookup()
    local out = {}
    if not core_vehicles or not core_vehicles.getVehicleList then return out end
    local list = core_vehicles.getVehicleList()
    local vehicles = list and list.vehicles or {}
    for _, v in ipairs(vehicles) do
        local key = v and v.model and v.model.key
        if type(key) == "string" and key ~= "" then
            out[key] = true
        end
    end
    return out
end

-- Filter to only models that exist in the game; no fallback to "all vehicles" so we stick to aiRacers.json list (no trailers/trucks).
local function filterPoolToAvailableModels(rawPool)
    local available = getAvailableModelLookup()
    local filtered = {}
    local seen = {}
    if type(rawPool) == "table" then
        for _, entry in ipairs(rawPool) do
            local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or entry
            if type(model) == "string" and available[model] and not seen[model] then
                seen[model] = true
                table.insert(filtered, model)
            end
        end
    end
    return filtered
end

-- Filter vehiclePool (array of { model, config }) to entries whose model exists. Returns new array.
local function filterVehiclePoolToAvailable(rawPool)
    local available = getAvailableModelLookup()
    local out = {}
    if type(rawPool) ~= "table" then return out end
    for _, entry in ipairs(rawPool) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
        local config = type(entry) == "table" and entry.config or nil
        if type(model) == "string" and available[model] and type(config) == "string" and config ~= "" then
            local row = { model = model, config = config }
            if type(entry) == "table" then
                local pk = tonumber(entry.peakHp) or tonumber(entry.hp) or tonumber(entry.powerHp)
                if pk and pk > 0 then row.peakHp = pk end
            end
            table.insert(out, row)
        end
    end
    return out
end

-- Order of cfg.vehiclePool tiers when merging upward for AI power matching (soft class ceiling).
local VEHICLE_POOL_CLASS_ORDER = { "stock", "modified", "super", "open" }

local function vehiclePoolClassOrderIndex(class)
    if type(class) ~= "string" then return 1 end
    for i, c in ipairs(VEHICLE_POOL_CLASS_ORDER) do
        if c == class then return i end
    end
    return 1
end

-- Concatenate vehiclePool entries from startClass through open, deduped by model+config.
local function mergeVehiclePoolFromClassUpward(vehiclePool, startClass)
    local out = {}
    if type(vehiclePool) ~= "table" then return out end
    local seen = {}
    local from = vehiclePoolClassOrderIndex(startClass)
    for i = from, #VEHICLE_POOL_CLASS_ORDER do
        local tier = VEHICLE_POOL_CLASS_ORDER[i]
        local tierPool = vehiclePool[tier]
        if type(tierPool) == "table" then
            for _, entry in ipairs(tierPool) do
                local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
                local config = type(entry) == "table" and entry.config or nil
                if type(model) == "string" and type(config) == "string" and config ~= "" then
                    local key = model .. "\0" .. config
                    if not seen[key] then
                        seen[key] = true
                        table.insert(out, entry)
                    end
                end
            end
        end
    end
    return out
end

-- buildCloseAbovePlan: slot list of { model, config } or { clonePlayer = true }. HP in (playerHp, playerHp+closeAboveHp]; else one next-higher + clones.
-- Second return is debug metadata for aiSpawnDebugUi.
local function buildCloseAbovePlan(available, playerHp, requestedCount, closeAboveHp)
    local plan = {}
    local dbg = {
        branch = "none",
        availableCount = type(available) == "table" and #available or 0,
        playerHpUsed = 0,
        closeAboveCap = tonumber(closeAboveHp) or 50,
        bandWindow = "",
        bandUniqueCount = 0,
        bandList = {},
        resolvedRowCount = 0,
        resolvedSample = {},
        nextCar = nil,
    }
    if type(available) ~= "table" or type(requestedCount) ~= "number" or requestedCount < 1 then
        dbg.branch = "invalid_args"
        return plan, dbg
    end
    local ph = type(playerHp) == "number" and playerHp or 0
    if ph < 0 then ph = 0 end
    dbg.playerHpUsed = ph
    local cap = tonumber(closeAboveHp) or 50
    if cap < 1 then cap = 1 end
    dbg.closeAboveCap = cap
    dbg.bandWindow = string.format("(%.0f, %.0f]", ph, ph + cap)

    local rows = {}
    for _, entry in ipairs(available) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
        local config = type(entry) == "table" and entry.config or nil
        if type(model) == "string" and type(config) == "string" and config ~= "" then
            local aiHp = getPowerHpForPoolEntry(entry, model, config)
            if type(aiHp) == "number" and aiHp > 0 then
                table.insert(rows, { model = model, config = config, powerHp = aiHp })
            end
        end
    end
    dbg.resolvedRowCount = #rows
    for i = 1, math.min(#rows, 14) do
        local r = rows[i]
        table.insert(dbg.resolvedSample, string.format("%s/%s=%.0f", r.model, r.config, r.powerHp))
    end
    if #rows > 14 then
        table.insert(dbg.resolvedSample, string.format("... +%d more", #rows - 14))
    end

    local band = {}
    for _, r in ipairs(rows) do
        if r.powerHp > ph and r.powerHp <= ph + cap then
            table.insert(band, r)
        end
    end
    table.sort(band, function(a, b)
        if a.powerHp ~= b.powerHp then return a.powerHp < b.powerHp end
        return (a.model or "") < (b.model or "")
    end)

    local seen = {}
    local unique = {}
    for _, r in ipairs(band) do
        local k = (r.model or "") .. "\0" .. (r.config or "")
        if not seen[k] then
            seen[k] = true
            table.insert(unique, r)
            table.insert(dbg.bandList, string.format("%s/%s %.0fHP", r.model, r.config, r.powerHp))
        end
    end
    dbg.bandUniqueCount = #unique

    if #unique >= 1 then
        dbg.branch = "band_cycle"
        for i = 1, requestedCount do
            local r = unique[((i - 1) % #unique) + 1]
            table.insert(plan, { model = r.model, config = r.config, powerHp = r.powerHp })
        end
        return plan, dbg
    end

    local above = {}
    for _, r in ipairs(rows) do
        if r.powerHp > ph then
            table.insert(above, r)
        end
    end
    if #above == 0 then
        dbg.branch = "all_clones_no_pool_above"
        for _ = 1, requestedCount do
            table.insert(plan, { clonePlayer = true })
        end
        return plan, dbg
    end
    table.sort(above, function(a, b)
        if a.powerHp ~= b.powerHp then return a.powerHp < b.powerHp end
        return (a.model or "") < (b.model or "")
    end)
    local pick = above[1]
    dbg.branch = "fallback_one_pool_rest_clones"
    dbg.nextCar = string.format("%s/%s %.0fHP", pick.model, pick.config, pick.powerHp)
    table.insert(plan, { model = pick.model, config = pick.config, powerHp = pick.powerHp })
    for _ = 2, requestedCount do
        table.insert(plan, { clonePlayer = true })
    end
    return plan, dbg
end

-- Model + config for spawning AI clones (inventory table when available).
local function resolvePlayerCloneSpawn()
    local vehId = be and be.getPlayerVehicleID and be:getPlayerVehicleID(0)
    if vehId and career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId and career_modules_inventory.getVehicle then
        local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
        if inventoryId then
            local vehInfo = career_modules_inventory.getVehicle(inventoryId)
            if vehInfo and vehInfo.model and vehInfo.config then
                return vehInfo.model, vehInfo.config
            end
        end
    end
    return M.getPlayerVehicleModelAndConfig()
end

-- Execute a staging plan: pool .pc rows or player-clone slots (inventory config when available).
local function spawnStagingPlan(raceName, race, facilityName, slotPlan, playerModel, playerConfigOrObj)
    local cfg = getCurrentLevelConfig()
    if cfg.enabled == false then return 0 end
    if type(slotPlan) ~= "table" or #slotPlan == 0 then return 0 end
    cancelDelayedDespawn()
    local spots = loadStagingSpots()
    if not spots or #spots == 0 then return 0 end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    local n = math.max(0, math.min(#spots, requestedCount, #slotPlan))
    if n <= 0 then return 0 end

    local function configForPlayerSpawn(modelKey, configKeyOrObj)
        if type(configKeyOrObj) == "table" then
            if configKeyOrObj.partConfigFilename and type(configKeyOrObj.partConfigFilename) == "string" then
                return configKeyOrObj.partConfigFilename
            elseif configKeyOrObj.format == 4 then
                return configKeyOrObj
            end
        end
        local configOpt = (type(configKeyOrObj) == "string" and configKeyOrObj ~= "") and configKeyOrObj or "default"
        return "vehicles/" .. modelKey .. "/" .. configOpt .. ".pc"
    end

    local spawned = 0
    for i = 1, n do
        local spec = slotPlan[i]
        local spot = spots[i]
        if spec and spot and spot.pos and spot.rot then
            local modelKey, configForSpawn
            if spec.clonePlayer then
                modelKey = playerModel
                if type(modelKey) == "string" and modelKey ~= "" then
                    configForSpawn = configForPlayerSpawn(modelKey, playerConfigOrObj)
                end
            elseif type(spec.model) == "string" and spec.model ~= "" and type(spec.config) == "string" and spec.config ~= "" then
                modelKey = spec.model
                configForSpawn = "vehicles/" .. modelKey .. "/" .. spec.config .. ".pc"
            end
            if modelKey and configForSpawn then
                local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
                local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
                local spawnOptions = { pos = pos, rot = rot, config = configForSpawn, autoEnterVehicle = false }
                local ok, veh = pcall(function() return core_vehicles.spawnNewVehicle(modelKey, spawnOptions) end)
                if ok and veh and veh.getID then
                    local vehId = veh:getID()
                    table.insert(mSpawnedAiVehicleIds, vehId)
                    spawned = spawned + 1
                    if extensions.core_vehicle_colors and extensions.core_vehicle_colors.setVehicleColor then
                        pcall(function()
                            extensions.core_vehicle_colors.setVehicleColor(0, pickRandomAiColor(), vehId)
                        end)
                    end
                    local vehObj = be:getObjectByID(vehId)
                    if vehObj then
                        vehObj:queueLuaCommand("if not driver then extensions.load('driver') end")
                        vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
                        vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
                        vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
                        if cfg.startEngineOnSpawn ~= false then
                            queueEngineStart(vehObj)
                        end
                    end
                end
            end
        end
    end
    return spawned
end

-- Pick N entries from class pool: sort by closest power to playerHp, then one per model first, then fill. Random among ties. Returns list of { model, config }.
local function pickVehiclePoolByClosestWithVariety(classPool, playerPowerHp, requestedCount)
    if type(classPool) ~= "table" or #classPool == 0 or type(requestedCount) ~= "number" or requestedCount < 1 then return {} end
    local withPower = {}
    for _, entry in ipairs(classPool) do
        local model = type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
        local config = type(entry) == "table" and entry.config or nil
        if type(model) == "string" and type(config) == "string" then
            local hp = getPowerForModelConfig(model, config)
            if type(hp) == "number" and hp > 0 then
                table.insert(withPower, { model = model, config = config, powerHp = hp })
            else
                table.insert(withPower, { model = model, config = config, powerHp = playerPowerHp or 200 })
            end
        end
    end
    if #withPower == 0 then return {} end
    local ph = type(playerPowerHp) == "number" and playerPowerHp or 200
    for i = #withPower, 2, -1 do
        local j = math.random(1, i)
        withPower[i], withPower[j] = withPower[j], withPower[i]
    end
    table.sort(withPower, function(a, b)
        local ahp = a.powerHp or ph
        local bhp = b.powerHp or ph
        local da = math.abs(ahp - ph)
        local db = math.abs(bhp - ph)
        local aClose = da <= CLOSE_HP_TOLERANCE
        local bClose = db <= CLOSE_HP_TOLERANCE
        if aClose and not bClose then return true end
        if not aClose and bClose then return false end
        if aClose and bClose then return da < db end
        -- After "within 25 HP": prefer next closest but always higher (power >= player), then below player by closest
        local aAbove = ahp >= ph
        local bAbove = bhp >= ph
        if aAbove and not bAbove then return true end
        if not aAbove and bAbove then return false end
        if aAbove and bAbove then return (ahp - ph) < (bhp - ph) end
        return da < db
    end)
    local picked = {}
    local usedModel = {}
    for _, e in ipairs(withPower) do
        if not usedModel[e.model] then
            usedModel[e.model] = true
            table.insert(picked, { model = e.model, config = e.config })
            if #picked >= requestedCount then return picked end
        end
    end
    for _, e in ipairs(withPower) do
        if #picked >= requestedCount then break end
        local already = 0
        for _, p in ipairs(picked) do if p.model == e.model then already = already + 1 end end
        if already < 2 then
            table.insert(picked, { model = e.model, config = e.config })
        end
    end
    while #picked < requestedCount and #withPower > 0 do
        table.insert(picked, { model = withPower[1].model, config = withPower[1].config })
    end
    return picked
end

local function pickRandomVehicleModel(pool)
    if type(pool) ~= "table" or #pool == 0 then return DEFAULT_CONFIG.defaultVehiclePool[1] end
    local pick = pool[math.random(1, #pool)]
    if type(pick) == "table" then
        return pick.model or pick.vehicleModel or DEFAULT_CONFIG.defaultVehiclePool[1]
    end
    return pick
end

-- Internal: spawn AI at staging spots using the given raw pool (array of model keys). Returns spawned count.
-- Spawn path uses level config only (same as American Road) so spawning is reliable; drive/params use getMergedConfigForRace.
local function spawnWithPool(raceName, race, facilityName, rawPool)
    local cfg = getCurrentLevelConfig()
    if cfg.enabled == false then return 0 end
    cancelDelayedDespawn()
    local spots = loadStagingSpots()
    if not spots or #spots == 0 then return 0 end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    local spawnCount = math.max(0, math.min(#spots, requestedCount))
    if spawnCount <= 0 then return 0 end
    local pool = filterPoolToAvailableModels(rawPool or cfg.defaultVehiclePool)
    local spawned = 0
    local maxRetries = 3
    for i = 1, spawnCount do
        local spot = spots[i]
        if spot and spot.pos and spot.rot then
            local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
            local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
            local spawnOptions = { pos = pos, rot = rot, autoEnterVehicle = false }
            local veh = nil
            local candidates = {}
            local seen = {}
            for _ = 1, maxRetries do
                local model = pickRandomVehicleModel(pool)
                if model and not seen[model] then
                    seen[model] = true
                    candidates[#candidates + 1] = model
                end
            end
            for _, model in ipairs(candidates) do
                local ok, result = pcall(function() return core_vehicles.spawnNewVehicle(model, spawnOptions) end)
                if ok and result and result.getID then
                    veh = result
                    break
                end
            end
            if veh then
                local vehId = veh:getID()
                table.insert(mSpawnedAiVehicleIds, vehId)
                spawned = spawned + 1
                if extensions.core_vehicle_colors and extensions.core_vehicle_colors.setVehicleColor then
                    pcall(function()
                        extensions.core_vehicle_colors.setVehicleColor(0, pickRandomAiColor(), vehId)
                    end)
                end
                local vehObj = be:getObjectByID(vehId)
                if vehObj then
                    vehObj:queueLuaCommand("if not driver then extensions.load('driver') end")
                    vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
                    vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
                    vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
                    if cfg.startEngineOnSpawn ~= false then
                        queueEngineStart(vehObj)
                    end
                end
            end
        end
    end
    return spawned
end

-- Internal: spawn AI at staging spots using a single model+config (e.g. player's vehicle). Colors vary per AI. Returns spawned count.
-- configKeyOrObj: string config key (e.g. "default") -> build path; or table (full config object from inventory) -> use as-is so wheels/tires match player.
local function spawnWithFixedVehicle(raceName, race, facilityName, modelKey, configKeyOrObj)
    local cfg = getCurrentLevelConfig()
    if cfg.enabled == false then return 0 end
    if not modelKey or modelKey == "" then return 0 end
    cancelDelayedDespawn()
    local spots = loadStagingSpots()
    if not spots or #spots == 0 then return 0 end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    local spawnCount = math.max(0, math.min(#spots, requestedCount))
    if spawnCount <= 0 then return 0 end
    local configForSpawn
    if type(configKeyOrObj) == "table" then
        if configKeyOrObj.partConfigFilename and type(configKeyOrObj.partConfigFilename) == "string" then
            configForSpawn = configKeyOrObj.partConfigFilename
        elseif configKeyOrObj.format == 4 then
            configForSpawn = configKeyOrObj
        else
            local configOpt = "default"
            configForSpawn = "vehicles/" .. modelKey .. "/" .. configOpt .. ".pc"
        end
    else
        local configOpt = (type(configKeyOrObj) == "string" and configKeyOrObj ~= "") and configKeyOrObj or "default"
        configForSpawn = "vehicles/" .. modelKey .. "/" .. configOpt .. ".pc"
    end
    local spawned = 0
    for i = 1, spawnCount do
        local spot = spots[i]
        if spot and spot.pos and spot.rot then
            local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
            local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
            local spawnOptions = { pos = pos, rot = rot, config = configForSpawn, autoEnterVehicle = false }
            local ok, veh = pcall(function() return core_vehicles.spawnNewVehicle(modelKey, spawnOptions) end)
            if ok and veh and veh.getID then
                local vehId = veh:getID()
                table.insert(mSpawnedAiVehicleIds, vehId)
                spawned = spawned + 1
                if extensions.core_vehicle_colors and extensions.core_vehicle_colors.setVehicleColor then
                    pcall(function()
                        extensions.core_vehicle_colors.setVehicleColor(0, pickRandomAiColor(), vehId)
                    end)
                end
                local vehObj = be:getObjectByID(vehId)
                if vehObj then
                    vehObj:queueLuaCommand("if not driver then extensions.load('driver') end")
                    vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
                    vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
                    vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
                    if cfg.startEngineOnSpawn ~= false then
                        queueEngineStart(vehObj)
                    end
                end
            end
        end
    end
    return spawned
end

-- Internal: spawn AI at staging spots using a pre-ordered list of { model, config }. One entry per spot. Returns spawned count.
local function spawnWithModelConfigList(raceName, race, facilityName, list)
    local cfg = getCurrentLevelConfig()
    if cfg.enabled == false then return 0 end
    if type(list) ~= "table" or #list == 0 then return 0 end
    cancelDelayedDespawn()
    local spots = loadStagingSpots()
    if not spots or #spots == 0 then return 0 end
    local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 1
    local spawnCount = math.max(0, math.min(#spots, requestedCount, #list))
    if spawnCount <= 0 then return 0 end
    local spawned = 0
    for i = 1, spawnCount do
        local spot = spots[i]
        local entry = list[i]
        if spot and spot.pos and spot.rot and entry and entry.model and entry.config then
            local pos = vec3(spot.pos[1], spot.pos[2], spot.pos[3])
            local rot = quat(spot.rot[1], spot.rot[2], spot.rot[3], spot.rot[4])
            local configPath = "vehicles/" .. entry.model .. "/" .. entry.config .. ".pc"
            local spawnOptions = { pos = pos, rot = rot, config = configPath, autoEnterVehicle = false }
            local ok, veh = pcall(function() return core_vehicles.spawnNewVehicle(entry.model, spawnOptions) end)
            if ok and veh and veh.getID then
                local vehId = veh:getID()
                table.insert(mSpawnedAiVehicleIds, vehId)
                spawned = spawned + 1
                if extensions.core_vehicle_colors and extensions.core_vehicle_colors.setVehicleColor then
                    pcall(function()
                        extensions.core_vehicle_colors.setVehicleColor(0, pickRandomAiColor(), vehId)
                    end)
                end
                local vehObj = be:getObjectByID(vehId)
                if vehObj then
                    vehObj:queueLuaCommand("if not driver then extensions.load('driver') end")
                    vehObj:queueLuaCommand("if not ai then extensions.load('ai') end")
                    vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
                    vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
                    if cfg.startEngineOnSpawn ~= false then
                        queueEngineStart(vehObj)
                    end
                end
            end
        end
    end
    return spawned
end

-- Spawn AI vehicles at AI staging spots for this facility/race. They remain stopped until releaseAndDrive().
function M.spawnForStaging(raceName, race, facilityName)
    local cfg = getCurrentLevelConfig()
    local rawPool = getVehiclePoolForRace(raceName, race, facilityName, cfg)
    return spawnWithPool(raceName, race, facilityName, rawPool)
end

-- Spawn AI with similar power to the player vehicle: live HP via getPlayerVehiclePowerReliable(..., { preferLive = true }), then legacy D/C/B/A pool if no vehiclePool.
-- When cfg.vehiclePool is set: merge tiers from effective HP class upward; spawn only configs with HP in (player, player+aiPoolCloseAboveHp], cycling distinct configs to fill aiCount; if none in band, 1× next-higher pool car + player clones (inventory config when available).
-- When spawnSameVehicleAsPlayer is true: spawns the player's exact model+config.
-- poolReferenceHp: optional HP when player power cannot be read and there is no sanctioned spawn context (e.g. freeroam).
-- sanctionedSpawnCtx: when player HP unknown, effective HP = classHpMax for the same vehiclePool close-above rule (full pool merged from stock).
function M.spawnForStagingWithPlayerHp(raceName, race, facilityName, callback, poolReferenceHp, sanctionedSpawnCtx)
    if type(callback) ~= "function" then return end
    local cfg = race and getMergedConfigForRace(race) or getCurrentLevelConfig()
    if cfg.enabled == false then
        callback(0)
        return
    end
    if (race and race.spawnSameVehicleAsPlayer) or cfg.spawnSameVehicleAsPlayer then
        local vehId = be and be:getPlayerVehicleID(0)
        local modelKey, configKeyOrObj
        if vehId and career_modules_inventory and career_modules_inventory.getInventoryIdFromVehicleId and career_modules_inventory.getVehicle then
            local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(vehId)
            if inventoryId then
                local vehInfo = career_modules_inventory.getVehicle(inventoryId)
                if vehInfo and vehInfo.model and vehInfo.config then
                    modelKey = vehInfo.model
                    configKeyOrObj = vehInfo.config
                end
            end
        end
        if not modelKey or modelKey == "" then
            modelKey, configKeyOrObj = M.getPlayerVehicleModelAndConfig()
        end
        if modelKey and modelKey ~= "" then
            local spawned = spawnWithFixedVehicle(raceName, race, facilityName, modelKey, configKeyOrObj or "default")
            callback(spawned)
            return
        end
    end
    local function spawnFromPowerHp(powerHp, powerDbg)
        powerDbg = type(powerDbg) == "table" and powerDbg or {}
        local hp = type(powerHp) == "number" and powerHp or 0
        local requestedCount = (race and race.aiCount) or cfg.maxSpawnCount or 4
        local closeAbove = tonumber(cfg.aiPoolCloseAboveHp) or tonumber(DEFAULT_CONFIG.aiPoolCloseAboveHp) or 50
        local pModel, pConfig = resolvePlayerCloneSpawn()

        if type(cfg.vehiclePool) == "table" and type(cfg.vehiclePool.stock) == "table" then
            local effHp = hp
            if effHp <= 0 and type(sanctionedSpawnCtx) == "table" then
                local hi = tonumber(sanctionedSpawnCtx.classHpMax)
                if hi and hi > 0 then
                    effHp = hi
                end
            end
            if effHp > 0 then
                local startClass = getClassFromHpForVehiclePool(effHp)
                local merged = mergeVehiclePoolFromClassUpward(cfg.vehiclePool, startClass)
                local available = filterVehiclePoolToAvailable(merged)
                if #available > 0 then
                    local plan = buildCloseAbovePlan(available, effHp, requestedCount, closeAbove)
                    if #plan > 0 then
                        local spawned = spawnStagingPlan(raceName, race, facilityName, plan, pModel, pConfig)
                        if aiSpawnDebugEnabled(cfg) then
                            showAiSpawnDebugUi(cfg, buildStagingSpawnDebugLinesFromPlan(powerDbg, plan, pModel, pConfig))
                        end
                        callback(spawned)
                        return
                    end
                end
            end
        end
        local class = getClassFromHp(hp)
        local rawPool = getVehiclePoolForHpClass(cfg, class)
        local pool = filterPoolByPower(rawPool, hp, cfg)
        local spawned = spawnWithPool(raceName, race, facilityName, pool)
        if aiSpawnDebugEnabled(cfg) then
            showAiSpawnDebugUi(cfg, buildStagingSpawnDebugLinesFromRecentSpawned(powerDbg, spawned))
        end
        callback(spawned)
    end
    M.getPlayerVehiclePowerReliable(function(powerWatts, weight)
        local powerHp = (type(powerWatts) == "number" and powerWatts > 0) and powerWattsToHp(powerWatts) or nil
        local hp = powerHp
        local powerDbg = {
            liveWatts = powerWatts,
            syncDetailsHp = M.getPlayerVehiclePower(),
            usedPoolRefHp = false,
        }
        local sanctionedActive = type(sanctionedSpawnCtx) == "table" and tonumber(sanctionedSpawnCtx.classHpMax) and tonumber(sanctionedSpawnCtx.classHpMax) > 0
        if (not hp or hp <= 0) and not sanctionedActive and type(poolReferenceHp) == "number" and poolReferenceHp > 0 then
            hp = poolReferenceHp
            powerDbg.usedPoolRefHp = true
        end
        spawnFromPowerHp(hp or 0, powerDbg)
    end, { preferLive = true })
end

-- Build script path: first point = vehicle position + dir + up (so game does not move the car). Then track points from nearest, close loop.
local function buildScriptPathNoTeleport(path, vpos, vdir, vup)
    if not path or #path == 0 or not vpos then return nil end
    local cfg = getCurrentLevelConfig()
    local pathWidth = tonumber(cfg.scriptPathWidth) or DEFAULT_CONFIG.scriptPathWidth or 2.5
    local px, py, pz = vpos.x, vpos.y, vpos.z
    local bestI, bestD = 1, 1e30
    for i, node in ipairs(path) do
        local dx = (node.x or 0) - px
        local dy = (node.y or 0) - py
        local dz = (node.z or 0) - pz
        local d = dx*dx + dy*dy + dz*dz
        if d < bestD then bestD, bestI = d, i end
    end
    local function addRadius(node)
        local n = type(node) == "table" and node or { x = 0, y = 0, z = 0 }
        if n.r == nil then n.r = pathWidth end
        return n
    end
    local out = {}
    -- First points are local bootstrap points so script mode keeps heading and avoids start-line snaps.
    local first = addRadius({ x = px, y = py, z = pz })
    local dirx, diry, dirz
    if vdir and (vdir.x or vdir.y or vdir.z) then
        dirx, diry, dirz = vdir.x or 0, vdir.y or 0, vdir.z or 0
        first.dir = { x = dirx, y = diry, z = dirz }
        first.up = vup and { x = vup.x or 0, y = vup.y or 0, z = vup.z or 0 } or nil
    end
    if not dirx then
        local nextNode = path[bestI] or path[1]
        local dx = (nextNode.x or px) - px
        local dy = (nextNode.y or py) - py
        local dz = (nextNode.z or pz) - pz
        local mag = math.sqrt(dx * dx + dy * dy + dz * dz)
        if mag > 0.001 then
            dirx, diry, dirz = dx / mag, dy / mag, dz / mag
            first.dir = { x = dirx, y = diry, z = dirz }
        end
    end
    table.insert(out, first)
    if dirx and diry and dirz then
        local bootstrap = math.max(1, tonumber(cfg.scriptBootstrapDistance) or DEFAULT_CONFIG.scriptBootstrapDistance)
        table.insert(out, addRadius({ x = px + dirx * math.min(2.5, bootstrap * 0.5), y = py + diry * math.min(2.5, bootstrap * 0.5), z = pz + dirz * math.min(2.5, bootstrap * 0.5) }))
        table.insert(out, addRadius({ x = px + dirx * bootstrap, y = py + diry * bootstrap, z = pz + dirz * bootstrap }))
    end
    for i = bestI, #path do table.insert(out, addRadius(path[i])) end
    for i = 1, bestI - 1 do table.insert(out, addRadius(path[i])) end
    table.insert(out, out[1])
    return out
end

local function clamp(n, minValue, maxValue)
    if n < minValue then return minValue end
    if n > maxValue then return maxValue end
    return n
end

local function randomAggression(cfg, race)
    local minAgg = tonumber((race and race.aggressionMin) or cfg.aggressionMin) or DEFAULT_CONFIG.aggressionMin
    local maxAgg = tonumber((race and race.aggressionMax) or cfg.aggressionMax) or DEFAULT_CONFIG.aggressionMax
    if maxAgg < minAgg then maxAgg = minAgg end
    local raw = minAgg + math.random() * (maxAgg - minAgg)
    return clamp(raw, 0.2, 1.5)
end

local function getRacingParameters(cfg, race)
    if not cfg or cfg.useRacingParameters == false then
        return {}
    end
    local scale = tonumber(cfg.raceAccelScale)
    if scale == nil or scale <= 0 then
        scale = 1.1
    end
    local kp = tonumber(cfg.raceThrottleKp)
    if kp == nil or kp <= 0 then
        kp = 1.12
    end
    local trm = tonumber(cfg.raceThrottleRateMult)
    if trm == nil or trm <= 0 then
        trm = 4
    end
    local trc = tonumber(cfg.raceThrottleRecoveryMult)
    if trc == nil or trc <= 0 then
        trc = 1.9
    end
    local params = {
        raceAccelScale = scale,
        raceThrottleKp = kp,
        raceThrottleRateMult = trm,
        raceThrottleRecoveryMult = trc
    }
    local rwt = tonumber(cfg.raceWideLineTrafficBlend)
    if rwt == nil then rwt = tonumber(DEFAULT_CONFIG.raceWideLineTrafficBlend) or 0.4 end
    if rwt > 0 then
        params.raceWideLineTrafficBlend = rwt
        local s = tonumber(cfg.raceWideLineLateralStartM)
        params.raceWideLineLateralStartM = (s ~= nil and s > 0) and s or (tonumber(DEFAULT_CONFIG.raceWideLineLateralStartM) or 0.9)
        local e = tonumber(cfg.raceWideLineLateralEndM)
        params.raceWideLineLateralEndM = (e ~= nil and e > 0) and e or (tonumber(DEFAULT_CONFIG.raceWideLineLateralEndM) or 2.6)
    end
    local rur = tonumber(cfg.raceWideLineUndersteerRelax)
    if rur == nil then rur = tonumber(DEFAULT_CONFIG.raceWideLineUndersteerRelax) or 0.45 end
    if rur > 0 then
        params.raceWideLineUndersteerRelax = rur
        if not params.raceWideLineLateralStartM then
            params.raceWideLineLateralStartM = tonumber(cfg.raceWideLineLateralStartM) or tonumber(DEFAULT_CONFIG.raceWideLineLateralStartM) or 0.9
            params.raceWideLineLateralEndM = tonumber(cfg.raceWideLineLateralEndM) or tonumber(DEFAULT_CONFIG.raceWideLineLateralEndM) or 2.6
        end
    end
    local floor = tonumber(cfg.raceThrottleFloor)
    if floor ~= nil and floor > 0 and floor < 1 then
        params.raceThrottleFloor = floor
        local hi = tonumber(cfg.raceHighSpeedThreshold)
        if hi ~= nil and hi > 0 then
            params.raceHighSpeedThreshold = hi
            local hif = tonumber(cfg.raceHighSpeedThrottleFloor)
            if hif ~= nil and hif > 0 and hif < 1 then
                params.raceHighSpeedThrottleFloor = hif
            end
        end
    end
    local rcl = tonumber(cfg.raceCornerLineLiftMaxM)
    if rcl == nil then rcl = tonumber(DEFAULT_CONFIG.raceCornerLineLiftMaxM) or 0.22 end
    if rcl > 0 then
        params.raceCornerLineLiftMaxM = rcl
        params.raceCornerCurvStart = tonumber(cfg.raceCornerCurvStart) or tonumber(DEFAULT_CONFIG.raceCornerCurvStart) or 0.022
        params.raceCornerCurvEnd = tonumber(cfg.raceCornerCurvEnd) or tonumber(DEFAULT_CONFIG.raceCornerCurvEnd) or 0.10
        local rcs = tonumber(cfg.raceCornerLineLiftScale)
        if rcs ~= nil then params.raceCornerLineLiftScale = rcs end
    end
    return params
end

-- Freeze or unfreeze the player vehicle (e.g. during countdown until GO, same moment as AI release). Uses same pattern as bus.lua.
function M.setPlayerFreeze(freeze)
    if not core_vehicleBridge or not core_vehicleBridge.executeAction then return end
    local veh = be and be:getPlayerVehicle(0)
    if veh then
        core_vehicleBridge.executeAction(veh, 'setFreeze', freeze and true or false)
    end
end

local function getObjectSpeedMps(vehId)
    if not be or not be.getObjectVelocityXYZ or not vehId then return 0 end
    local v = be:getObjectVelocityXYZ(vehId)
    if type(v) == "number" then
        return math.abs(v)
    end
    if type(v) == "table" then
        local x = v.x or v[1] or 0
        local y = v.y or v[2] or 0
        local z = v.z or v[3] or 0
        return math.sqrt(x * x + y * y + z * z)
    end
    return 0
end

local function isUpsideDown(vehObj)
    if not vehObj or not vehObj.getDirectionVectorUp then return false end
    local up = vehObj:getDirectionVectorUp()
    if not up then return false end
    local upZ = up.z or up[3] or 0
    return upZ < 0
end

local function resetDelayedDespawnState()
    mDelayedDespawnActive = false
    mDelayedDespawnWaiting = false
    mDelayedDespawnTimer = 0
    mDelayedDespawnStaggerSeconds = 4.0
end

cancelDelayedDespawn = function()
    if not mDelayedDespawnActive then return end
    resetDelayedDespawnState()
end

queueEngineStart = function(vehObj)
    if not vehObj then return end
    -- One-shot ignition command to avoid visible restart cycling.
    if core_vehicleBridge and core_vehicleBridge.executeAction then
        pcall(function()
            core_vehicleBridge.executeAction(vehObj, 'setIgnitionLevel', 3)
        end)
    end
    vehObj:queueLuaCommand("if electrics and electrics.setIgnitionLevel then electrics.setIgnitionLevel(3) end")
end

local function despawnSingleVehicle()
    local vehId = mSpawnedAiVehicleIds[1]
    if not vehId then return false end
    if mDnfCallback then pcall(mDnfCallback, vehId) end
    local obj = be:getObjectByID(vehId)
    if obj then
        obj:delete()
    end
    table.remove(mSpawnedAiVehicleIds, 1)
    mRecoveryStateByVehId[vehId] = nil
    mRetiredUpsideDownByVehId[vehId] = nil
    mVehicleLaneIndexByVehId[vehId] = nil
    mNavStateByVehId[vehId] = nil
    return true
end

local function updateDelayedDespawn(step)
    if not mDelayedDespawnActive then return false end
    if #mSpawnedAiVehicleIds == 0 then
        resetDelayedDespawnState()
        mRecoveryMonitorEnabled = false
        return true
    end
    mDelayedDespawnTimer = (mDelayedDespawnTimer or 0) - step
    if mDelayedDespawnTimer > 0 then
        return true
    end
    if mDelayedDespawnWaiting then
        mDelayedDespawnWaiting = false
        mDelayedDespawnTimer = mDelayedDespawnStaggerSeconds
        return true
    end
    despawnSingleVehicle()
    if #mSpawnedAiVehicleIds == 0 then
        resetDelayedDespawnState()
        mRecoveryMonitorEnabled = false
        mRecoveryStateByVehId = {}
        mRetiredUpsideDownByVehId = {}
        mVehicleLaneIndexByVehId = {}
        mNavStateByVehId = {}
        mActiveRaceForRecovery = nil
        mActiveLapCountForRecovery = 1
    else
        mDelayedDespawnTimer = mDelayedDespawnStaggerSeconds
    end
    return true
end

local function despawnAiVehiclesById(toDespawn)
    if type(toDespawn) ~= "table" or next(toDespawn) == nil then return end
    for i = #mSpawnedAiVehicleIds, 1, -1 do
        local vehId = mSpawnedAiVehicleIds[i]
        if toDespawn[vehId] then
            if mDnfCallback then pcall(mDnfCallback, vehId) end
            local obj = be:getObjectByID(vehId)
            if obj then
                obj:delete()
            end
            table.remove(mSpawnedAiVehicleIds, i)
            mRecoveryStateByVehId[vehId] = nil
            mRetiredUpsideDownByVehId[vehId] = nil
            mVehicleLaneIndexByVehId[vehId] = nil
            mNavStateByVehId[vehId] = nil
        end
    end
end

local function buildNavWpTargetListFromPath(path)
    if not path or #path < 2 then return nil end
    if not map or not map.findClosestRoad then return nil end
    local wpTargetList = {}
    local seenConsecutive = nil
    -- Denser path (was 50) so AI follows track smoothly and does not cut between sparse waypoints.
    local step = math.max(1, math.floor(#path / 120))
    for i = 1, #path, step do
        local node = path[i]
        if node and node.x and node.y and node.z then
            local _, nodeIdx = map.findClosestRoad(vec3(node.x, node.y, node.z))
            if nodeIdx and nodeIdx ~= seenConsecutive then
                table.insert(wpTargetList, nodeIdx)
                seenConsecutive = nodeIdx
            end
        end
    end
    local lastNode = path[#path]
    if lastNode and lastNode.x and lastNode.y and lastNode.z then
        local _, lastNodeIdx = map.findClosestRoad(vec3(lastNode.x, lastNode.y, lastNode.z))
        if lastNodeIdx and lastNodeIdx ~= seenConsecutive then
            table.insert(wpTargetList, lastNodeIdx)
        end
    end
    if #wpTargetList < 2 then return nil end
    return wpTargetList
end

local function getMapNodePos(mapData, nodeId)
    if not mapData or not mapData.nodes then return nil end
    local n = mapData.nodes[nodeId]
    if not n or not n.pos then return nil end
    return vec3(n.pos)
end

local function orientWpTargetListForVehicle(wpTargetList, vehObj)
    if not wpTargetList or #wpTargetList < 2 or not vehObj then return wpTargetList end
    if not map or not map.getMap then return wpTargetList end
    local mapData = map.getMap()
    if not mapData or not mapData.nodes then return wpTargetList end
    local vpos = vehObj:getPosition()
    if not vpos then return wpTargetList end

    local nearestIdx, nearestDist = 1, math.huge
    for i, nodeId in ipairs(wpTargetList) do
        local npos = getMapNodePos(mapData, nodeId)
        if npos then
            local dx = (npos.x or 0) - (vpos.x or 0)
            local dy = (npos.y or 0) - (vpos.y or 0)
            local dz = (npos.z or 0) - (vpos.z or 0)
            local d = dx * dx + dy * dy + dz * dz
            if d < nearestDist then
                nearestDist = d
                nearestIdx = i
            end
        end
    end

    local rotated = {}
    for i = nearestIdx, #wpTargetList do
        rotated[#rotated + 1] = wpTargetList[i]
    end
    for i = 1, nearestIdx - 1 do
        rotated[#rotated + 1] = wpTargetList[i]
    end

    local vdir = vehObj.getDirectionVector and vehObj:getDirectionVector() or nil
    if vdir and #rotated >= 3 then
        local p0 = getMapNodePos(mapData, rotated[1])
        local pNext = getMapNodePos(mapData, rotated[2])
        local pPrev = getMapNodePos(mapData, rotated[#rotated])
        if p0 and pNext and pPrev then
            local toNext = pNext - p0
            local toPrev = pPrev - p0
            local nextLen = toNext:length()
            local prevLen = toPrev:length()
            if nextLen > 0.001 and prevLen > 0.001 then
                toNext = toNext / nextLen
                toPrev = toPrev / prevLen
                local dotNext = (vdir.x or 0) * (toNext.x or 0) + (vdir.y or 0) * (toNext.y or 0) + (vdir.z or 0) * (toNext.z or 0)
                local dotPrev = (vdir.x or 0) * (toPrev.x or 0) + (vdir.y or 0) * (toPrev.y or 0) + (vdir.z or 0) * (toPrev.z or 0)
                if dotNext < dotPrev then
                    local reversed = { rotated[1] }
                    for i = #rotated, 2, -1 do
                        reversed[#reversed + 1] = rotated[i]
                    end
                    rotated = reversed
                end
            end
        end
    end

    return rotated
end

local function queueNavDriveForVehicle(vehObj, path, noOfLaps, cfg, race)
    if not vehObj or not path or #path < 2 then return false end
    local wpTargetList = buildNavWpTargetListFromPath(path)
    if not wpTargetList or #wpTargetList < 2 then return false end
    wpTargetList = orientWpTargetListForVehicle(wpTargetList, vehObj)
    if not wpTargetList or #wpTargetList < 2 then return false end
    if wpTargetList[#wpTargetList] ~= wpTargetList[1] then
        wpTargetList[#wpTargetList + 1] = wpTargetList[1]
    end
    local wpTargetListStr = serialize(wpTargetList)
    -- Full aggression: state-based speed (no route speed limit). Rubberband later by player XP.
    local aggression = 1.0
    local driveInLane = tostring(cfg.driveInLane or DEFAULT_CONFIG.driveInLane)
    local avoidCars = tostring(cfg.avoidCars or DEFAULT_CONFIG.avoidCars)
    local targetSpeedSmootherRate = tonumber(cfg.targetSpeedSmootherRate) or DEFAULT_CONFIG.targetSpeedSmootherRate or 18
    vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")

    -- setParameters (raceAccelScale / raceThrottleKp from cfg), setAggression, setRacing, setAvoidCars, then driveUsingPath.
    if cfg.useRacingParameters ~= false and DEFAULT_CONFIG.useRacingParameters ~= false then
        local params = getRacingParameters(cfg, race)
        vehObj:queueLuaCommand('ai.setParameters(' .. serialize(params) .. ')')
    end
    vehObj:queueLuaCommand('ai.setAggression(' .. tostring(aggression) .. ')')
    vehObj:queueLuaCommand('ai.setRacing(true)')
    vehObj:queueLuaCommand('ai.setAvoidCars("' .. avoidCars .. '")')

    vehObj:queueLuaCommand([[
        local wpTargetList = ]] .. wpTargetListStr .. [[
        local noOfLaps = ]] .. tostring(noOfLaps) .. [[
        if wpTargetList and #wpTargetList > 1 and ai and ai.driveUsingPath then
            ai.driveUsingPath({
                wpTargetList = wpTargetList,
                avoidCars = ']] .. avoidCars .. [[',
                driveInLane = ']] .. driveInLane .. [[',
                aggression = ]] .. tostring(aggression) .. [[,
                noOfLaps = noOfLaps,
                targetSpeedSmootherRate = ]] .. tostring(targetSpeedSmootherRate) .. [[
            })
        end
    ]])
    return true
end

local function queueDriveForVehicle(vehObj, race, noOfLaps, cfg, laneIndex)
    if not vehObj or not race then return end
    local pathKey = getRacePathKey(race)
    if not pathKey then return end
    if type(laneIndex) == "number" and race.checkpointRoadLanes and type(race.checkpointRoadLanes) == "table" and #race.checkpointRoadLanes > 0 then
        pathKey = pathKey .. "_lane_" .. tostring(laneIndex)
    end
    local path = mPathCache[pathKey]
    if not path or #path == 0 then
        M.preloadPathForRace(race)
        path = mPathCache[pathKey]
    end
    if not path or #path == 0 then return end

    if cfg.useNavgraphPathfinding ~= false then
        if queueNavDriveForVehicle(vehObj, path, noOfLaps, cfg, race) then
            return
        end
    end

    local vpos = vehObj:getPosition()
    local vdir, vup
    if vehObj.getDirectionVector and vehObj.getDirectionVectorUp then
        vdir = vehObj:getDirectionVector()
        vup = vehObj:getDirectionVectorUp()
    end
    local scriptPath = buildScriptPathNoTeleport(path, vpos, vdir, vup)
    if not scriptPath or #scriptPath < 2 then return end

    local pathStr = serialize(scriptPath)
    -- Full aggression: state-based speed (no route speed limit). Rubberband later by player XP.
    local aggression = 1.0
    local driveInLane = tostring(cfg.driveInLane or DEFAULT_CONFIG.driveInLane)
    local avoidCars = tostring(cfg.avoidCars or DEFAULT_CONFIG.avoidCars)
    local targetSpeedSmootherRate = tonumber(cfg.targetSpeedSmootherRate) or DEFAULT_CONFIG.targetSpeedSmootherRate or 18
    vehObj:queueLuaCommand("input.event('parkingbrake', 0, 1)")

    -- setParameters (raceAccelScale / raceThrottleKp from cfg), setAggression, setRacing, setAvoidCars, then driveUsingPath.
    if cfg.useRacingParameters ~= false and DEFAULT_CONFIG.useRacingParameters ~= false then
        local params = getRacingParameters(cfg, race)
        vehObj:queueLuaCommand('ai.setParameters(' .. serialize(params) .. ')')
    end
    vehObj:queueLuaCommand('ai.setAggression(' .. tostring(aggression) .. ')')
    vehObj:queueLuaCommand('ai.setRacing(true)')
    vehObj:queueLuaCommand('ai.setAvoidCars("' .. avoidCars .. '")')

    vehObj:queueLuaCommand([[
        local path = ]] .. pathStr .. [[
        local noOfLaps = ]] .. tostring(noOfLaps) .. [[
        if path and #path > 0 and ai and ai.driveUsingPath then
            ai.driveUsingPath({
                script = path,
                avoidCars = ']] .. avoidCars .. [[',
                driveInLane = ']] .. driveInLane .. [[',
                aggression = ]] .. tostring(aggression) .. [[,
                noOfLaps = noOfLaps,
                targetSpeedSmootherRate = ]] .. tostring(targetSpeedSmootherRate) .. [[
            })
        end
    ]])
end

-- Call at countdown GO: release spawned AI for this race using script path. When race has checkpointRoadLanes, each AI gets a lane path by spawn index (laneIndex = (i-1) % numLanes).
-- Player stays frozen and is unfrozen 0.5s after AI go to account for AI reaction time (slightly behind).
function M.releaseAndDrive(race, lapCount)
    if not race then return end
    local cfg = getMergedConfigForRace(race)
    if cfg.enabled == false then
        M.setPlayerFreeze(false)
        return
    end
    cancelDelayedDespawn()
    M.preloadPathForRace(race)
    local pathKey = getRacePathKey(race)
    if not pathKey then
        M.setPlayerFreeze(false)
        return
    end
    local numLanes = (race.checkpointRoadLanes and type(race.checkpointRoadLanes) == "table") and #race.checkpointRoadLanes or 0
    -- Use a high lap count so AI keep lapping after race distance; leaderboard still uses required laps from triggers.
    local requiredLaps = (type(lapCount) == "number" and lapCount > 0) and lapCount or 1
    local noOfLaps = math.max(requiredLaps, 99)
    mActiveRaceForRecovery = race
    mActiveLapCountForRecovery = requiredLaps
    mRecoveryMonitorEnabled = true
    mRecoveryCheckAccumulator = 0
    mRecoveryGraceTimer = math.max(0, tonumber(cfg.launchRecoveryGraceSeconds) or DEFAULT_CONFIG.launchRecoveryGraceSeconds)
    for i, vehId in ipairs(mSpawnedAiVehicleIds) do
        local vehObj = be:getObjectByID(vehId)
        if vehObj then
            if cfg.startEngineOnSpawn ~= false then
                queueEngineStart(vehObj)
            end
            local laneIndex = (numLanes > 0) and ((i - 1) % numLanes) or nil
            mVehicleLaneIndexByVehId[vehId] = laneIndex
            queueDriveForVehicle(vehObj, race, noOfLaps, cfg, laneIndex)
        end
    end
    mPlayerUnfreezeAt = os.clock() + 0.5
    M.setPlayerFreeze(true)
end

function M.onUpdate(dtReal)
    local dt = tonumber(dtReal) or 0
    if dt <= 0 then return end

    -- If we asked UI for player power (Option C) and it didn't respond in time, fall back to Option B.
    if type(pendingPowerCallback) == "function" and pendingPowerVehId and M._powerRequestUiFallbackTimer and (os.clock() - M._powerRequestUiFallbackTimer) > 1.5 then
        M._powerRequestUiFallbackTimer = nil
        local vehObj = be and be:getObjectByID(pendingPowerVehId)
        if vehObj and vehObj.queueLuaCommand then
            vehObj:queueLuaCommand(string.format(M._powerRequestScriptTemplate, 0, POWER_REQUEST_MAX_RETRIES))
        else
            M.onPlayerVehiclePowerWeight(0, nil)
        end
    end

    if mPlayerUnfreezeAt and os.clock() >= mPlayerUnfreezeAt then
        mPlayerUnfreezeAt = nil
        M.setPlayerFreeze(false)
    end

    if updateDelayedDespawn(dt) then
        return
    end

    if not mRecoveryMonitorEnabled then return end
    if not mSpawnedAiVehicleIds or #mSpawnedAiVehicleIds == 0 then return end
    if not mActiveRaceForRecovery then return end

    local cfg = getCurrentLevelConfig()
    if cfg.enabled == false then return end
    -- When false, do not despawn any AI for stuck/wreck during race; only post-race cleanup runs.
    if cfg.despawnWreckedDuringRace == false then return end
    if mRecoveryGraceTimer and mRecoveryGraceTimer > 0 then
        mRecoveryGraceTimer = math.max(0, mRecoveryGraceTimer - dt)
        return
    end

    mRecoveryCheckAccumulator = mRecoveryCheckAccumulator + dt
    if mRecoveryCheckAccumulator < 0.2 then return end
    local step = mRecoveryCheckAccumulator
    mRecoveryCheckAccumulator = 0

    local recoveryEnabled = cfg.recoveryEnabled ~= false
    local speedThreshold = math.max(0, tonumber(cfg.recoverySpeedThresholdMps) or DEFAULT_CONFIG.recoverySpeedThresholdMps)
    local stuckSeconds = math.max(0.5, tonumber(cfg.recoveryStuckSeconds) or DEFAULT_CONFIG.recoveryStuckSeconds)
    local cooldownSeconds = math.max(1, tonumber(cfg.recoveryCooldownSeconds) or DEFAULT_CONFIG.recoveryCooldownSeconds)
    local despawnEnabled = cfg.despawnWreckedEnabled ~= false
    local upsideDownDespawnSeconds = math.max(2, tonumber(cfg.despawnUpsideDownSeconds) or DEFAULT_CONFIG.despawnUpsideDownSeconds)
    local despawnAfterRecoveries = math.max(1, tonumber(cfg.despawnAfterRecoveries) or DEFAULT_CONFIG.despawnAfterRecoveries)
    local terminalStuckSeconds = math.max(stuckSeconds, tonumber(cfg.despawnTerminalStuckSeconds) or DEFAULT_CONFIG.despawnTerminalStuckSeconds)
    local alwaysStuckSeconds = math.max(terminalStuckSeconds, tonumber(cfg.despawnAlwaysStuckSeconds) or DEFAULT_CONFIG.despawnAlwaysStuckSeconds)
    local toDespawn = {}

    for _, vehId in ipairs(mSpawnedAiVehicleIds) do
        local vehObj = be:getObjectByID(vehId)
        if vehObj then
            local state = mRecoveryStateByVehId[vehId] or {
                stuckTime = 0,
                cooldown = 0,
                recoveries = 0,
                upsideDownTime = 0,
                terminalStuckTime = 0,
                alwaysStuckTime = 0
            }
            local upsideDown = isUpsideDown(vehObj)
            if upsideDown then
                state.upsideDownTime = (state.upsideDownTime or 0) + step
                mRetiredUpsideDownByVehId[vehId] = true
                vehObj:queueLuaCommand("if ai and ai.setMode then ai.setMode('stop') end")
                vehObj:queueLuaCommand("input.event('parkingbrake', 1, 1)")
                if despawnEnabled and state.upsideDownTime >= upsideDownDespawnSeconds then
                    toDespawn[vehId] = true
                end
                state.stuckTime = 0
                state.terminalStuckTime = 0
                state.alwaysStuckTime = 0
                mRecoveryStateByVehId[vehId] = state
            else
                state.upsideDownTime = 0
                if not mRetiredUpsideDownByVehId[vehId] then
                    state.cooldown = math.max(0, (state.cooldown or 0) - step)

                    local speed = getObjectSpeedMps(vehId)
                    if speed <= speedThreshold then
                        state.stuckTime = (state.stuckTime or 0) + step
                        state.terminalStuckTime = (state.terminalStuckTime or 0) + step
                        state.alwaysStuckTime = (state.alwaysStuckTime or 0) + step
                    else
                        state.stuckTime = 0
                        state.terminalStuckTime = 0
                        state.alwaysStuckTime = 0
                    end

                    if recoveryEnabled and state.stuckTime >= stuckSeconds and state.cooldown <= 0 then
                        vehObj:queueLuaCommand([[
                            if recovery then
                                recovery.startRecovering()
                                recovery.stopRecovering()
                            end
                        ]])
                        queueDriveForVehicle(vehObj, mActiveRaceForRecovery, mActiveLapCountForRecovery, cfg, mVehicleLaneIndexByVehId[vehId])
                        state.recoveries = (state.recoveries or 0) + 1
                        state.stuckTime = 0
                        state.cooldown = cooldownSeconds
                    end

                    if despawnEnabled and (state.recoveries or 0) >= despawnAfterRecoveries and (state.terminalStuckTime or 0) >= terminalStuckSeconds then
                        toDespawn[vehId] = true
                    end
                    if despawnEnabled and (state.alwaysStuckTime or 0) >= alwaysStuckSeconds then
                        toDespawn[vehId] = true
                    end
                end
                mRecoveryStateByVehId[vehId] = state
            end
        end
    end

    despawnAiVehiclesById(toDespawn)
end

function M.scheduleDelayedDespawn(delaySeconds, staggerSeconds)
    if not mSpawnedAiVehicleIds or #mSpawnedAiVehicleIds == 0 then
        resetDelayedDespawnState()
        return 0
    end
    local cfg = getCurrentLevelConfig()
    local delay = tonumber(delaySeconds)
    if not delay then
        delay = tonumber(cfg.delayedDespawnDefaultSeconds) or DEFAULT_CONFIG.delayedDespawnDefaultSeconds
    end
    local stagger = tonumber(staggerSeconds)
    if not stagger then
        stagger = tonumber(cfg.delayedDespawnStaggerSeconds) or DEFAULT_CONFIG.delayedDespawnStaggerSeconds
    end
    mDelayedDespawnActive = true
    mDelayedDespawnWaiting = true
    mDelayedDespawnTimer = math.max(0, delay)
    mDelayedDespawnStaggerSeconds = math.max(0.25, stagger)
    mRecoveryMonitorEnabled = false
    mRecoveryCheckAccumulator = 0
    return #mSpawnedAiVehicleIds
end

-- One-shot ignition pass for all currently spawned AI (used during staging pre-countdown).
function M.startEnginesForSpawned()
    local cfg = getCurrentLevelConfig()
    if cfg.enabled == false then return 0 end
    local started = 0
    for _, vehId in ipairs(mSpawnedAiVehicleIds) do
        local obj = be:getObjectByID(vehId)
        if obj then
            queueEngineStart(obj)
            started = started + 1
        end
    end
    return started
end

-- Return list of spawned AI vehicle IDs (for start trigger to count AI laps).
function M.getSpawnedVehicleIds()
    return mSpawnedAiVehicleIds
end

function M.setDnfCallback(cb)
    mDnfCallback = cb
end

-- Clear spawned AI vehicles (e.g. when race is exited or session cleared). Call from competitiveRaceManager.exitRace.
function M.clearSpawned()
    for _, vehId in ipairs(mSpawnedAiVehicleIds) do
        if mDnfCallback then pcall(mDnfCallback, vehId) end
        local obj = be:getObjectByID(vehId)
        if obj then
            obj:delete()
        end
    end
    mSpawnedAiVehicleIds = {}
    mRecoveryStateByVehId = {}
    mRetiredUpsideDownByVehId = {}
    mVehicleLaneIndexByVehId = {}
    mNavStateByVehId = {}
    mRecoveryMonitorEnabled = false
    mRecoveryCheckAccumulator = 0
    mActiveRaceForRecovery = nil
    mActiveLapCountForRecovery = 1
    mRecoveryGraceTimer = 0
    resetDelayedDespawnState()
end

function M.invalidateConfigCache()
    -- no-op: config is read from disk each time getCurrentLevelConfig() is called
end

-- HP reading and class eligibility for player (race staging).
-- Class order and max HP per class (player eligible if vehicle power <= eligibilityPct * classMax).
local CLASS_ORDER = { "D", "C", "B", "A" }
local CLASS_MAX_HP = { D = 160, C = 370, B = 600, A = 9999 }
local ELIGIBILITY_PCT = 0.75
-- XP thresholds: at least this much business XP to be in that class (D=0, C=1500, B=5000, A=15000).
local XP_FOR_CLASS = { D = 0, C = 1500, B = 5000, A = 15000 }

local pendingPowerCallback = nil
local pendingPowerVehId = nil  -- used by Option B retry so we can re-queue on same vehicle
local POWER_REQUEST_MAX_RETRIES = 20

-- Fresh live HP (from vehicle VM) for staging UI and podium cap; never use stale sync alone for podium.
local mCachedLivePlayerHp = nil
local mCachedLivePlayerVehId = nil
local mCachedLivePlayerClock = nil
local LIVE_HP_CACHE_STALE_SEC = 90

local function invalidateLiveHpCacheIfVehicleChanged()
    if not be or not be.getPlayerVehicleID then return end
    local pid = be:getPlayerVehicleID(0)
    if not pid or not mCachedLivePlayerVehId or pid ~= mCachedLivePlayerVehId then
        mCachedLivePlayerHp = nil
        mCachedLivePlayerVehId = nil
        mCachedLivePlayerClock = nil
    end
end

local function liveHpSampleIsTrusted()
    invalidateLiveHpCacheIfVehicleChanged()
    if type(mCachedLivePlayerHp) ~= "number" or mCachedLivePlayerHp <= 0 then return false end
    if not mCachedLivePlayerClock then return false end
    local clk = (os and os.clock) and os.clock() or 0
    return (clk - mCachedLivePlayerClock) < LIVE_HP_CACHE_STALE_SEC
end

local function storeLiveHpCacheForVehicle(vehId, powerWatts)
    if not vehId or not be or not be.getPlayerVehicleID or vehId ~= be:getPlayerVehicleID(0) then return end
    if type(powerWatts) ~= "number" or powerWatts <= 0 then return end
    local hp = powerWattsToHp(powerWatts)
    if type(hp) ~= "number" or hp <= 0 then return end
    mCachedLivePlayerHp = hp
    mCachedLivePlayerVehId = vehId
    mCachedLivePlayerClock = os.clock()
end
-- Vehicle script: max maxPower over all "engine" devices (raw may be HP-scale or watts; GE normalizes in onPlayerVehiclePowerWeight), beam stats weight, both required before success.
-- Retries until power>0 and weight>0 or max retries (then report last values).
M._powerRequestScriptTemplate = [[
local retry = %d
local maxR = %d
local power, weight = 0, 0
local engines = powertrain.getDevicesByCategory("engine")
if engines then
  for _, eng in ipairs(engines) do
    if eng and eng.maxPower then
      local mp = eng.maxPower or 0
      if mp > power then power = mp end
    end
  end
end
local stats = obj:calcBeamStats()
if stats and stats.total_weight then weight = stats.total_weight end
local ready = power > 0 and weight > 0
if ready or retry >= maxR then
  obj:queueGameEngineLua("(function() local g = _G.career_modules_competitiveRace_aiRacers if g and type(g.onPlayerVehiclePowerWeight) == \"function\" then g.onPlayerVehiclePowerWeight(" .. tostring(power) .. "," .. tostring(weight) .. ") end end)()")
else
  obj:queueGameEngineLua("(function() local g = _G.career_modules_competitiveRace_aiRacers if g and type(g.onPlayerVehiclePowerWeightRetry) == \"function\" then g.onPlayerVehiclePowerWeightRetry(" .. tostring(retry) .. ") end end)()")
end
]]

-- One-shot VM read for staging UI refresh; does not use pendingPowerCallback (safe alongside AI spawn).
M._livePowerCacheScript = [[
local power, weight = 0, 0
local engines = powertrain.getDevicesByCategory("engine")
if engines then
  for _, eng in ipairs(engines) do
    if eng and eng.maxPower then
      local mp = eng.maxPower or 0
      if mp > power then power = mp end
    end
  end
end
local stats = obj:calcBeamStats()
if stats and stats.total_weight then weight = stats.total_weight end
if power > 0 and weight > 0 then
  local vid = obj:getID()
  obj:queueGameEngineLua("(function() local g=_G.career_modules_competitiveRace_aiRacers if g and type(g.ingestLivePowerCacheSample)==\"function\" then g.ingestLivePowerCacheSample(" .. tostring(vid) .. "," .. tostring(power) .. "," .. tostring(weight) .. ") end end)()")
end
]]

local function getEffectiveClassFromXp(cfg, businessXp)
    local xp = tonumber(businessXp) or 0
    local class = "D"
    for i = #CLASS_ORDER, 1, -1 do
        local c = CLASS_ORDER[i]
        local threshold = (cfg and cfg.horsepowerClassXp and cfg.horsepowerClassXp[c]) or XP_FOR_CLASS[c]
        if xp >= (tonumber(threshold) or 0) then
            class = c
            break
        end
    end
    return class
end

local function getEligibilityThresholdForClass(cfg, class)
    local maxHp = (cfg and cfg.horsepowerClassRanges and cfg.horsepowerClassRanges[class]) or CLASS_MAX_HP[class]
    local pct = (cfg and cfg.eligibilityPct) or ELIGIBILITY_PCT
    if not maxHp then return nil end
    return math.floor((tonumber(maxHp) or 0) * (tonumber(pct) or ELIGIBILITY_PCT))
end

-- Returns player vehicle model key and config key (e.g. "etkc", "default") or nil, nil if not available.
function M.getPlayerVehicleModelAndConfig()
    if not be or not be.getPlayerVehicleID then return nil, nil end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then return nil, nil end
    if not core_vehicles or not core_vehicles.getVehicleDetails then return nil, nil end
    local details = core_vehicles.getVehicleDetails(vehId)
    if not details or not details.current then return nil, nil end
    local modelKey = details.current.key
    local configKey = details.current.config_key or "default"
    return modelKey, configKey
end

-- GE entry from vehicle VM: updates live HP cache only (no pendingPowerCallback).
function M.ingestLivePowerCacheSample(vid, powerRaw, weightRaw)
    vid = tonumber(vid)
    if not vid or not be or not be.getPlayerVehicleID or vid ~= be:getPlayerVehicleID(0) then return end
    local pRaw = tonumber(powerRaw)
    local wRaw = tonumber(weightRaw)
    if not pRaw or not wRaw or wRaw <= 0 then return end
    local p = liveMaxPowerRawToWatts(pRaw)
    if not p or p <= 0 then return end
    storeLiveHpCacheForVehicle(vid, p)
end

-- Staging UI: prefer fresh live sample; fall back to sync getVehicleDetails (display only).
function M.getPlayerVehiclePowerForStagingUi()
    if liveHpSampleIsTrusted() then
        return mCachedLivePlayerHp, "live"
    end
    return M.getPlayerVehiclePower(), "sync"
end

-- Podium class cap: only when a trusted live sample exists; otherwise nil (fail open — do not use stale sync).
function M.getPlayerVehiclePowerForPodiumCapCheck()
    if liveHpSampleIsTrusted() then
        return mCachedLivePlayerHp
    end
    return nil
end

-- Throttled from competitiveTrackFlow while staging UI is open; skipped if a reliable power request is in flight.
function M.requestStagingUiLivePowerRefresh()
    if pendingPowerCallback ~= nil then return end
    if not be or not be.getPlayerVehicleID or not be.getObjectByID then return end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then return end
    local vehObj = be:getObjectByID(vehId)
    if not vehObj or not vehObj.queueLuaCommand then return end
    vehObj:queueLuaCommand(M._livePowerCacheScript)
end

-- Sync: may return nil if power cannot be read (e.g. no vehicle). Returns power in HP (same as filter/comparison).
function M.getPlayerVehiclePower()
    if not be or not be.getPlayerVehicleID then return nil end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then return nil end
    if not core_vehicles or not core_vehicles.getVehicleDetails then return nil end
    local details = core_vehicles.getVehicleDetails(vehId)
    if not details then return nil end
    local configs = details.configs
    if not configs then return nil end
    return getPowerHpFromConfig(configs)
end

-- Returns player power (HP) and class string ("stock" / "modified" / "super") when available.
function M.getPlayerVehiclePowerAndClass()
    local powerHp = M.getPlayerVehiclePower()
    if type(powerHp) ~= "number" or powerHp < 0 then return nil, nil end
    return powerHp, getClassFromHpForVehiclePool(powerHp)
end

-- Called from vehicle Lua (queueGameEngineLua) or from UI (careerRequestPlayerPower response) with live power/weight.
-- Power may be HP-scale or watts; normalize to watts before callback (see liveMaxPowerRawToWatts).
function M.onPlayerVehiclePowerWeight(power, weight)
    M._powerRequestUiFallbackTimer = nil
    local cb = pendingPowerCallback
    local vidForCache = pendingPowerVehId
    pendingPowerCallback = nil
    pendingPowerVehId = nil
    if type(cb) == "function" then
        local p = (type(power) == "number") and liveMaxPowerRawToWatts(power) or nil
        local w = (type(weight) == "number") and weight or nil
        if vidForCache and p and p > 0 then
            storeLiveHpCacheForVehicle(vidForCache, p)
        end
        cb(p, w)
    end
end

-- Vehicle calls this when engine not ready yet; we re-queue the script with retry+1 (Option B).
function M.onPlayerVehiclePowerWeightRetry(retryCount)
    if type(pendingPowerCallback) ~= "function" or not pendingPowerVehId then return end
    if type(retryCount) ~= "number" or retryCount >= POWER_REQUEST_MAX_RETRIES then
        M.onPlayerVehiclePowerWeight(0, nil)
        return
    end
    local vehObj = be and be:getObjectByID(pendingPowerVehId)
    if vehObj and vehObj.queueLuaCommand then
        vehObj:queueLuaCommand(string.format(M._powerRequestScriptTemplate, retryCount + 1, POWER_REQUEST_MAX_RETRIES))
    else
        M.onPlayerVehiclePowerWeight(0, nil)
    end
end

-- Request live power/weight. opts.preferLive: skip sync getVehicleDetails; use vehicle queueLuaCommand only (tuning-shop style, no UI activeObjectLua).
-- Default: Option A sync first, then Option C (UI) with vehicle fallback timer, else Option B vehicle-only.
function M.getPlayerVehiclePowerReliable(callback, opts)
    if type(callback) ~= "function" then return end
    if not be or not be.getPlayerVehicleID or not be.getObjectByID then
        callback(nil, nil)
        return
    end
    local vehId = be:getPlayerVehicleID(0)
    if not vehId then
        callback(nil, nil)
        return
    end

    local preferLive = type(opts) == "table" and opts.preferLive == true

    -- Option A: sync from vehicle details (fast but can be stale after parts/tuning until details refresh).
    if not preferLive then
        local powerHp = M.getPlayerVehiclePower()
        if type(powerHp) == "number" and powerHp > 0 then
            local details = core_vehicles and core_vehicles.getVehicleDetails and core_vehicles.getVehicleDetails(vehId)
            local weight = (details and details.configs and details.configs.total_weight) or (details and details.aggregates and details.aggregates.total_weight) or nil
            callback(powerHp * WATTS_PER_HP, weight)
            return
        end
    end

    -- Option C: UI activeObjectLua (skipped for preferLive — unreliable vs explicit vehObj:queueLuaCommand on player id).
    if not preferLive and guihooks and guihooks.trigger then
        pendingPowerCallback = callback
        pendingPowerVehId = vehId
        guihooks.trigger("careerRequestPlayerPower")
        M._powerRequestUiFallbackTimer = os.clock()
        return
    end

    local vehObj = be:getObjectByID(vehId)
    if not vehObj or not vehObj.queueLuaCommand then
        callback(nil, nil)
        return
    end
    pendingPowerCallback = callback
    pendingPowerVehId = vehId
    -- Option B: vehicle script retries until engine has maxPower or max retries (same vehicle via pendingPowerVehId).
    vehObj:queueLuaCommand(string.format(M._powerRequestScriptTemplate, 0, POWER_REQUEST_MAX_RETRIES))
end

-- Sync eligibility: returns ok, msg. Fails open if power cannot be read.
function M.isPlayerEligibleForRace(race, businessXp)
    if not race then return true, nil end
    local cfg = getCurrentLevelConfig()
    local effectiveClass = getEffectiveClassFromXp(cfg, businessXp)
    local threshold = getEligibilityThresholdForClass(cfg, effectiveClass)
    if not threshold then return true, nil end
    local power = M.getPlayerVehiclePower()
    if power == nil then return true, nil end
    if power > threshold then
        return false, string.format("Vehicle exceeds Class %s limit (%d HP max for this race).", effectiveClass, threshold)
    end
    return true, nil
end

-- Async eligibility: requests reliable power from vehicle, then checks. Fails closed if power cannot be read.
function M.isPlayerEligibleForRaceAsync(race, businessXp, callback)
    if type(callback) ~= "function" then return end
    if not race then
        callback(true, nil)
        return
    end
    local cfg = getCurrentLevelConfig()
    local effectiveClass = getEffectiveClassFromXp(cfg, businessXp)
    local threshold = getEligibilityThresholdForClass(cfg, effectiveClass)
    if not threshold then
        callback(true, nil)
        return
    end
    M.getPlayerVehiclePowerReliable(function(powerWatts, weight)
        if powerWatts == nil then
            callback(false, "Vehicle power could not be read. Try again or use a different vehicle.")
            return
        end
        local powerHp = powerWattsToHp(powerWatts)
        if not powerHp or powerHp > threshold then
            callback(false, string.format("Vehicle exceeds Class %s limit (%d HP max for this race).", effectiveClass, threshold))
            return
        end
        callback(true, nil)
    end)
end

M.getMergedConfigForRace = getMergedConfigForRace

_G.career_modules_competitiveRace_aiRacers = M

return M
