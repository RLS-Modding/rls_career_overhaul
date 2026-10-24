-- Derby participant pools, damage/contact tracking and staging availability.
-- Read pool helpers, the per-load participant operations and their returned services.
local lib = {}

-- Config ------------------------------------------------------------------------------------------

local MAX_DAMAGE_PERCENT = 100
local DERBY_INFO_MARKERS = { "rlsDerby", "ovalDerby", "Derby Groups" }
local VEHICLE_INFO_ROOTS = { "vehicles/", "/vehicles/", "vehicles", "/vehicles" }
local ZONE_LINE_THICKNESS_PIXELS = 4
local ZONE_OUTLINE_HEIGHT_METERS = 1.0
local PLAY_ZONE_COLOR = { 0, 200, 180, 120 }
local ELIMINATION_ZONE_COLOR = { 255, 80, 40, 140 }
local VEHICLE_COLOR_PALETTE = {
  "0.9 0.1 0.1 1",
  "0.1 0.2 0.7 1",
  "0.95 0.75 0.05 1",
  "0.1 0.65 0.2 1",
  "0.6 0.1 0.6 1",
  "0.0 0.0 0.0 1",
  "0.85 0.4 0.0 1",
  "0.2 0.8 0.9 1",
  "0.9 0.9 0.9 1",
  "0.4 0.25 0.1 1",
}

-- Helpers -----------------------------------------------------------------------------------------

local function newFallbackVehiclePool()
  return { "etk800", "sunburst2", "bx", "covet", "pessima", "fullsize", "vivace" }
end

-- Vehicle and damage helpers ----------------------------------------------------------------------

local function getVehiclePos(vehId)
  local vehicle = be:getObjectByID(vehId)
  if not vehicle then return nil end
  return vehicle:getPosition()
end

local function despawnVehicle(vehId)
  local vehicle = be:getObjectByID(vehId)
  if vehicle then vehicle:delete() end
end

local function findMapObject(vehId)
  if not map.objects then return nil end
  return map.objects[vehId]
end

local function getRawVehicleDamage(vehId)
  local mapObject = findMapObject(vehId)
  if not mapObject then return 0 end
  return tonumber(mapObject.damage) or 0
end

-- Rows of the timeout scoreboard get the health score from the damage percent.
local function healthScoreFromDamage(damagePercent)
  return math.max(0, MAX_DAMAGE_PERCENT - (tonumber(damagePercent) or 0))
end

local function pickRandomColor()
  return VEHICLE_COLOR_PALETTE[math.random(1, #VEHICLE_COLOR_PALETTE)]
end

-- Vehicle pool helpers ----------------------------------------------------------------------------

local function isDerbyConfigGroup(configType)
  return type(configType) == "string" and (configType == "ovalDerby" or configType:match("^rlsDerby%d*$") ~= nil)
end

local function getModelAndConfigFromInfoPath(infoPath)
  local normalized = tostring(infoPath or ""):gsub("\\", "/")
  local model, config = normalized:match("/?vehicles/([^/]+)/info_(.+)%.json$")
  if model and config and model ~= "" and config ~= "" then return model, config end
  return nil, nil
end

-- The same info file is reachable with or without a leading slash or mount prefix.
local function infoPathCandidates(infoPath)
  local path = tostring(infoPath or ""):gsub("\\", "/")
  local candidates = { path }
  local relativePath = path:match("(vehicles/.+)$")
  if relativePath and relativePath ~= path then
    table.insert(candidates, relativePath)
    table.insert(candidates, "/" .. relativePath)
  end
  if path:sub(1, 1) == "/" then
    table.insert(candidates, path:sub(2))
  else
    table.insert(candidates, "/" .. path)
  end
  return candidates
end

local function readVehicleInfoFile(infoPath)
  for _, candidate in ipairs(infoPathCandidates(infoPath)) do
    local info = jsonReadFile(candidate)
    if type(info) == "table" then return info end
  end
  return nil
end

local function infoTextMentionsDerby(content)
  for _, marker in ipairs(DERBY_INFO_MARKERS) do
    if content:find(marker, 1, true) ~= nil then return true end
  end
  return false
end

local function fileLooksLikeDerbyInfo(infoPath)
  for _, candidate in ipairs(infoPathCandidates(infoPath)) do
    local ok, content = pcall(readFile, candidate)
    if ok and type(content) == "string" then return infoTextMentionsDerby(content) end
  end
  return true
end

local function addDerbyConfigToCache(cache, configTypes, model, config, label)
  if
    type(configTypes) ~= "table"
    or type(model) ~= "string"
    or model == ""
    or type(config) ~= "string"
    or config == ""
  then
    return
  end
  for _, configType in ipairs(configTypes) do
    if isDerbyConfigGroup(configType) then
      cache[configType] = cache[configType] or {}
      table.insert(cache[configType], {
        model = model,
        config = config,
        label = label or config,
      })
    end
  end
end

local function sortPoolsByModelAndConfig(cache)
  for _, pool in pairs(cache) do
    table.sort(pool, function(left, right)
      if left.model == right.model then return tostring(left.config) < tostring(right.config) end
      return tostring(left.model) < tostring(right.model)
    end)
  end
end

local function getVehiclePoolEntryKey(entry)
  if type(entry) == "table" then
    return tostring(entry.model or entry[1] or "") .. "|" .. tostring(entry.config or entry.partConfig or "")
  end
  return tostring(entry) .. "|"
end

local function vehiclePoolEntryHasConfig(entry)
  return type(entry) == "table" and (entry.config or entry.partConfig) ~= nil
end

local function normalizeVehiclePoolEntry(entry)
  if type(entry) == "table" then
    return {
      model = entry.model or entry[1],
      config = entry.config or entry.partConfig,
      label = entry.label,
    }
  end
  return { model = tostring(entry) }
end

-- Zone drawing helpers ----------------------------------------------------------------------------

local function drawZoneOutline(zone, color)
  if not zone or not zone.vertices or #zone.vertices < 3 then return end
  local vertices = zone.vertices
  for i = 1, #vertices do
    local next = (i % #vertices) + 1
    local from = vec3(vertices[i][1], vertices[i][2], vertices[i][3] + ZONE_OUTLINE_HEIGHT_METERS)
    local to = vec3(vertices[next][1], vertices[next][2], vertices[next][3] + ZONE_OUTLINE_HEIGHT_METERS)
    debugDrawer:drawLineInstance(from, to, ZONE_LINE_THICKNESS_PIXELS, ColorI(color[1], color[2], color[3], color[4]))
  end
end

-- Staging helpers ---------------------------------------------------------------------------------

local function isPlayerWalkingMode()
  return gameplay_walk and gameplay_walk.isWalking() or false
end

local function getPlayerStagingReferencePos()
  if isPlayerWalkingMode() then
    local walkX, walkY, walkZ = gameplay_walk.getPosXYZ()
    if walkX and walkY and walkZ then return vec3(walkX, walkY, walkZ) end
    if type(walkX) == "table" then
      if walkX.x and walkX.y and walkX.z then return vec3(walkX.x, walkX.y, walkX.z) end
      if walkX[1] and walkX[2] and walkX[3] then return vec3(walkX[1], walkX[2], walkX[3]) end
    end
  end
  local playerVehId = be:getPlayerVehicleID(0)
  local playerVeh = playerVehId and be:getObjectByID(playerVehId) or nil
  if playerVeh then return playerVeh:getPosition() end
  return nil
end

local function getInventoryTableEntry(entries, inventoryId)
  if type(entries) ~= "table" or inventoryId == nil then return nil end
  return entries[inventoryId] or entries[tostring(inventoryId)] or entries[tonumber(inventoryId)]
end

local function hasPositiveInsuranceId(entry)
  local insuranceId = entry and tonumber(entry.insuranceId)
  return insuranceId ~= nil and insuranceId > 0
end

local function isInventoryVehicleInsured(inventoryId)
  if not inventoryId or not overhaul_career_career.isActive() then return false end
  local vehicles = overhaul_career_garage_inventory.getVehicles() or {}
  if hasPositiveInsuranceId(getInventoryTableEntry(vehicles, inventoryId)) then return true end
  local insuranceVehicles = overhaul_career_repair_insurance.getInvVehs() or {}
  if hasPositiveInsuranceId(getInventoryTableEntry(insuranceVehicles, inventoryId)) then return true end
  local ok, info = pcall(overhaul_career_repair_insurance.getVehInsuranceInfo, inventoryId)
  if not ok or type(info) ~= "table" then return false end
  if hasPositiveInsuranceId(info) then return true end
  return type(info.insuranceInfo) == "table"
    and tonumber(info.insuranceInfo.id) ~= nil
    and tonumber(info.insuranceInfo.id) > 0
end

local function getCurrentInventoryVehicleId()
  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId or not overhaul_career_career.isActive() then return nil end
  return overhaul_career_garage_inventory.getInventoryIdFromVehicleId(playerVehId)
end

-- Participant operations --------------------------------------------------------------------------

function lib.create(ownerServices)
  local derby = ownerServices
  local derbyState = ownerServices.derbyState
  local derbyUi = ownerServices.derbyUi
  local derbyDamageScoring = ownerServices.derbyDamageScoring
  local stockOverrides = ownerServices.stockOverrides

  -- Vehicles and damage -------------------------------------------------------------------------

  local function getDamageDisplayMax(isPlayer)
    local eventCfg = derbyState.activeEventCfg or {}
    local maxDamage
    if isPlayer then
      maxDamage = tonumber(eventCfg.maxDamageForDisplayPlayer)
    else
      maxDamage = tonumber(eventCfg.maxDamageForDisplayAi)
    end
    if not maxDamage then maxDamage = tonumber(eventCfg.maxDamageForDisplay) end
    if not maxDamage or maxDamage <= 0 then maxDamage = derby.constants.MAX_DAMAGE_FOR_DISPLAY end
    return maxDamage
  end

  local function getVehicleDamageNormalized(vehId, isPlayer)
    local mapObject = findMapObject(vehId)
    if not mapObject then return 0 end
    local rawDamage = mapObject.damage or 0
    return math.min(MAX_DAMAGE_PERCENT, (rawDamage / getDamageDisplayMax(isPlayer == true)) * MAX_DAMAGE_PERCENT)
  end

  -- No-contact timer ----------------------------------------------------------------------------

  local function getNoContactTimeoutSeconds()
    local timeoutSeconds = tonumber(derbyState.activeEventCfg and derbyState.activeEventCfg.noContactTimeoutSeconds)
    if timeoutSeconds == nil then timeoutSeconds = derby.tuning.DEFAULT_NO_CONTACT_TIMEOUT_SECONDS end
    return math.max(0, timeoutSeconds)
  end

  local function getNoContactWarningSeconds()
    local warningSeconds = tonumber(derbyState.activeEventCfg and derbyState.activeEventCfg.noContactWarningSeconds)
    if warningSeconds == nil then warningSeconds = derby.tuning.DEFAULT_NO_CONTACT_WARNING_SECONDS end
    return math.max(0, warningSeconds)
  end

  local function resetNoContactState()
    derbyState.noContactTimer = 0
    derbyUi.clearDerbyCountdownWarnings()
    derbyState.lastPlayerRawDamage = derbyState.playerDerbyVehicleId
        and getRawVehicleDamage(derbyState.playerDerbyVehicleId)
      or nil
    derbyState.lastAiRawDamageById = {}
    for _, vehId in ipairs(derbyState.spawnedAiIds) do
      derbyState.lastAiRawDamageById[vehId] = getRawVehicleDamage(vehId)
    end
  end

  local function readAiDamageDelta(vehId)
    local rawDamage = getRawVehicleDamage(vehId)
    local previousDamage = derbyState.lastAiRawDamageById[vehId]
    derbyState.lastAiRawDamageById[vehId] = rawDamage
    return previousDamage and (rawDamage - previousDamage) or 0
  end

  -- Returns whether the opponent is near the player, was damaged while near, and was touched.
  local function scanOpponentContact(playerPos, playerVelocity, vehId)
    local aiVehicle = be:getObjectByID(vehId)
    local aiDamageDelta = readAiDamageDelta(vehId)
    if not (aiVehicle and playerPos) then return false, false, false end
    local distanceMeters = (playerPos - aiVehicle:getPosition()):length()
    local isNear = distanceMeters <= derby.tuning.NO_CONTACT_DISTANCE_METERS
    local wasDamaged = isNear and aiDamageDelta > derby.tuning.NO_CONTACT_DAMAGE_THRESHOLD
    local wasTouched = distanceMeters <= derby.tuning.NO_CONTACT_TOUCH_DISTANCE_METERS
      and (playerVelocity - aiVehicle:getVelocity()):length() >= derby.tuning.NO_CONTACT_TOUCH_REL_SPEED_MPS
    return isNear, wasDamaged, wasTouched
  end

  local function detectPlayerDerbyContact()
    if not derbyState.playerDerbyVehicleId then return false end
    local playerVehicle = be:getObjectByID(derbyState.playerDerbyVehicleId)
    if not playerVehicle then return false end
    local playerPos = playerVehicle:getPosition()
    local playerVelocity = playerVehicle:getVelocity()
    local playerRawDamage = getRawVehicleDamage(derbyState.playerDerbyVehicleId)
    local playerDamageDelta = derbyState.lastPlayerRawDamage and (playerRawDamage - derbyState.lastPlayerRawDamage) or 0
    derbyState.lastPlayerRawDamage = playerRawDamage
    local playerNearOpponent, nearbyOpponentDamaged, touchedOpponent = false, false, false
    for _, vehId in ipairs(derbyState.spawnedAiIds) do
      if not derbyState.eliminatedIds[vehId] then
        local isNear, wasDamaged, wasTouched = scanOpponentContact(playerPos, playerVelocity, vehId)
        playerNearOpponent = playerNearOpponent or isNear
        nearbyOpponentDamaged = nearbyOpponentDamaged or wasDamaged
        touchedOpponent = touchedOpponent or wasTouched
      end
    end
    return nearbyOpponentDamaged
      or touchedOpponent
      or (playerNearOpponent and playerDamageDelta > derby.tuning.NO_CONTACT_DAMAGE_THRESHOLD)
  end

  local function updateNoContactTimer(dtSim)
    local timeoutSeconds = getNoContactTimeoutSeconds()
    if timeoutSeconds <= 0 then return false end
    if detectPlayerDerbyContact() then
      derbyState.noContactTimer = 0
      derbyUi.clearNoContactWarning()
      return false
    end
    derbyState.noContactTimer = derbyState.noContactTimer + dtSim
    local secondsLeft = timeoutSeconds - derbyState.noContactTimer
    local warningSeconds = math.min(getNoContactWarningSeconds(), timeoutSeconds)
    if secondsLeft <= warningSeconds and secondsLeft > 0 then derbyUi.showNoContactWarning(secondsLeft) end
    return derbyState.noContactTimer >= timeoutSeconds
  end

  -- Damage scoring ------------------------------------------------------------------------------

  function derbyDamageScoring.getActiveParticipantIds()
    local ids = {}
    if derbyState.playerDerbyVehicleId and not derbyState.playerEliminated then
      table.insert(ids, derbyState.playerDerbyVehicleId)
    end
    for _, vehId in ipairs(derbyState.spawnedAiIds) do
      if not derbyState.eliminatedIds[vehId] then table.insert(ids, vehId) end
    end
    return ids
  end

  function derbyDamageScoring.reset()
    derbyDamageScoring.damageDealtById = {}
    derbyDamageScoring.lastRawDamageById = {}
    derbyDamageScoring.scoreDataById = {}
    for _, vehId in ipairs(derbyDamageScoring.getActiveParticipantIds()) do
      derbyDamageScoring.damageDealtById[vehId] = 0
      derbyDamageScoring.lastRawDamageById[vehId] = getRawVehicleDamage(vehId)
    end
  end

  function derbyDamageScoring.getNearestActiveAttackerId(damagedVehId, damagedPos)
    if not damagedPos then return nil end
    local bestId = nil
    local bestDistanceMeters = derby.tuning.DERBY_DAMAGE_ATTRIBUTION_RADIUS_METERS
    for _, candidateId in ipairs(derbyDamageScoring.getActiveParticipantIds()) do
      if candidateId ~= damagedVehId then
        local candidate = be:getObjectByID(candidateId)
        if candidate then
          local distanceMeters = (damagedPos - candidate:getPosition()):length()
          if distanceMeters <= bestDistanceMeters then
            bestDistanceMeters = distanceMeters
            bestId = candidateId
          end
        end
      end
    end
    return bestId
  end

  function derbyDamageScoring.update()
    for _, vehId in ipairs(derbyDamageScoring.getActiveParticipantIds()) do
      if derbyDamageScoring.damageDealtById[vehId] == nil then derbyDamageScoring.damageDealtById[vehId] = 0 end
      local currentRawDamage = getRawVehicleDamage(vehId)
      local previousRawDamage = derbyDamageScoring.lastRawDamageById[vehId]
      derbyDamageScoring.lastRawDamageById[vehId] = currentRawDamage
      local damageDelta = previousRawDamage and (currentRawDamage - previousRawDamage) or 0
      if damageDelta > 0 then
        local damagedVehicle = be:getObjectByID(vehId)
        local attackerId = damagedVehicle
            and derbyDamageScoring.getNearestActiveAttackerId(vehId, damagedVehicle:getPosition())
          or nil
        if attackerId then
          derbyDamageScoring.damageDealtById[attackerId] = (derbyDamageScoring.damageDealtById[attackerId] or 0)
            + damageDelta
        end
      end
    end
  end

  function derbyDamageScoring.getParticipantData(vehId, damagePct)
    local healthScore = healthScoreFromDamage(damagePct)
    if not vehId then
      return {
        healthScore = healthScore,
        damageDealt = 0,
        damageDealtScore = nil,
        derbyScore = nil,
      }
    end
    local scoreData = derbyDamageScoring.scoreDataById[vehId] or {}
    return {
      healthScore = scoreData.healthScore or healthScore,
      damageDealt = scoreData.damageDealt or derbyDamageScoring.damageDealtById[vehId] or 0,
      damageDealtScore = scoreData.damageDealtScore,
      derbyScore = scoreData.derbyScore,
    }
  end

  function derbyDamageScoring.buildTimeoutSurvivorRow(vehId, isPlayer)
    local damagePct = getVehicleDamageNormalized(vehId, isPlayer == true)
    local scoring = derbyDamageScoring.getParticipantData(vehId, damagePct)
    return {
      id = vehId,
      isPlayer = isPlayer == true,
      damagePct = damagePct,
      healthScore = scoring.healthScore,
      damageDealt = scoring.damageDealt,
      damageDealtScore = 0,
      derbyScore = 0,
    }
  end

  function derbyDamageScoring.scoreTimeoutSurvivors(survivors)
    local maxDamageDealt = 0
    for _, row in ipairs(survivors) do
      maxDamageDealt = math.max(maxDamageDealt, tonumber(row.damageDealt) or 0)
    end
    for _, row in ipairs(survivors) do
      row.healthScore = healthScoreFromDamage(row.damagePct)
      row.damageDealt = tonumber(row.damageDealt) or 0
      row.damageDealtScore = maxDamageDealt > 0 and ((row.damageDealt / maxDamageDealt) * MAX_DAMAGE_PERCENT) or 0
      if maxDamageDealt > 0 then
        row.derbyScore = (row.healthScore * derby.tuning.DERBY_TIMEOUT_HEALTH_WEIGHT)
          + (row.damageDealtScore * derby.tuning.DERBY_TIMEOUT_DAMAGE_DEALT_WEIGHT)
      else
        row.derbyScore = row.healthScore
      end
      derbyDamageScoring.scoreDataById[row.id] = {
        healthScore = row.healthScore,
        damageDealt = row.damageDealt,
        damageDealtScore = row.damageDealtScore,
        derbyScore = row.derbyScore,
      }
    end
  end

  -- Vehicle pools -------------------------------------------------------------------------------

  local function getConfigTypeValues(info, model, config)
    if type(info) ~= "table" then return nil end
    local values = {}
    local seen = {}
    local rawValues = { info["Config Type"], info.ConfigType, info.configType, info["Derby Groups"], info.derbyGroups }
    if type(info.aggregates) == "table" then
      table.insert(rawValues, info.aggregates["Config Type"])
      table.insert(rawValues, info.aggregates.ConfigType)
      table.insert(rawValues, info.aggregates["Derby Groups"])
      table.insert(rawValues, info.aggregates.derbyGroups)
    end
    for _, raw in ipairs(rawValues) do
      if type(raw) == "string" and raw ~= "" and not seen[raw] then
        seen[raw] = true
        table.insert(values, raw)
      elseif type(raw) == "table" then
        for key, value in pairs(raw) do
          if type(key) == "string" and key ~= "" and value and not seen[key] then
            seen[key] = true
            table.insert(values, key)
          end
          if type(value) == "string" and value ~= "" and not seen[value] then
            seen[value] = true
            table.insert(values, value)
          end
        end
      end
    end
    local poolKey = stockOverrides.derbyPoolKey
    if not seen[poolKey] and stockOverrides.isDerbyConfig(model or info.model_key, config or info.key) then
      table.insert(values, poolKey)
    end
    return #values > 0 and values or nil
  end

  local function addModelDerbyConfigs(cache, modelKey)
    local added = 0
    local modelData = core_vehicles.getModel(modelKey)
    local configs = modelData and modelData.configs
    if type(configs) ~= "table" then return added end
    for configKey, configInfo in pairs(configs) do
      if type(configKey) == "string" and type(configInfo) == "table" then
        local configTypes = getConfigTypeValues(configInfo)
        if configTypes then
          addDerbyConfigToCache(
            cache,
            configTypes,
            modelKey,
            configKey,
            configInfo.Configuration or configInfo.Name or configKey
          )
          added = added + 1
        end
      end
    end
    return added
  end

  local function addCoreVehicleDerbyConfigs(cache)
    local added = 0
    local modelList = core_vehicles.getModelList() or {}
    for modelKey, _ in pairs(modelList.models or {}) do
      if type(modelKey) == "string" and modelKey ~= "" then added = added + addModelDerbyConfigs(cache, modelKey) end
    end
    return added
  end

  local function addConfigListGeneratorDerbyConfigs(cache)
    if not util_configListGenerator or not util_configListGenerator.getEligibleVehicles then return 0 end
    local ok, eligible = pcall(util_configListGenerator.getEligibleVehicles, false, false)
    if not ok or type(eligible) ~= "table" then return 0 end
    local added = 0
    for _, info in ipairs(eligible) do
      if type(info) == "table" and type(info.model_key) == "string" and type(info.key) == "string" then
        local configTypes = getConfigTypeValues(info)
        if configTypes then
          addDerbyConfigToCache(
            cache,
            configTypes,
            info.model_key,
            info.key,
            info.Configuration or info.Name or info.key
          )
          added = added + 1
        end
      end
    end
    return added
  end

  local function findVehicleInfoFiles()
    local files = {}
    for _, root in ipairs(VEHICLE_INFO_ROOTS) do
      local ok, found = pcall(function()
        return FS:findFiles(root, "info_*.json", -1, true, false)
      end)
      if ok and type(found) == "table" then
        for _, path in ipairs(found) do
          files[path] = true
        end
      end
    end
    return files
  end

  local function addFileScannedDerbyConfigs(cache)
    local added = 0
    for infoPath, _ in pairs(findVehicleInfoFiles()) do
      local model, config = getModelAndConfigFromInfoPath(infoPath)
      if stockOverrides.isDerbyConfig(model, config) or fileLooksLikeDerbyInfo(infoPath) then
        local info = readVehicleInfoFile(infoPath)
        local configTypes = getConfigTypeValues(info, model, config)
        if configTypes and model and config then
          addDerbyConfigToCache(cache, configTypes, model, config, info.Configuration or config)
          added = added + 1
        end
      end
    end
    return added
  end

  local function buildDerbyConfigTypePoolCache()
    local cache = {}
    addCoreVehicleDerbyConfigs(cache)
    addConfigListGeneratorDerbyConfigs(cache)
    if next(cache) == nil then addFileScannedDerbyConfigs(cache) end
    sortPoolsByModelAndConfig(cache)
    return cache
  end

  local function getDerbyConfigTypePool(poolKey)
    if not poolKey then return nil end
    derbyState.derbyConfigTypePoolCache = derbyState.derbyConfigTypePoolCache or buildDerbyConfigTypePoolCache()
    local pool = derbyState.derbyConfigTypePoolCache[poolKey]
    if type(pool) ~= "table" or #pool <= 0 then
      local lowerKey = tostring(poolKey):lower()
      for key, candidate in pairs(derbyState.derbyConfigTypePoolCache) do
        if tostring(key):lower() == lowerKey then
          pool = candidate
          break
        end
      end
    end
    if type(pool) == "table" and #pool > 0 then return pool end
    return nil
  end

  local function appendVehiclePoolEntries(target, seen, pool, requireConfig)
    if type(pool) ~= "table" then return end
    for _, entry in ipairs(pool) do
      if requireConfig and not vehiclePoolEntryHasConfig(entry) then
        derby._log(
          "W",
          "Skipping model-only derby pool entry for strict pool: "
            .. tostring(type(entry) == "table" and (entry.model or entry[1]) or entry)
        )
      else
        local key = getVehiclePoolEntryKey(entry)
        if key ~= "|" and not seen[key] then
          seen[key] = true
          table.insert(target, entry)
        end
      end
    end
  end

  -- The strict pool: configs found by pool key first, then the event's own entries for that key.
  local function mergeStrictVehiclePool(poolKey, eventPools)
    local mergedPool = {}
    local seen = {}
    appendVehiclePoolEntries(mergedPool, seen, getDerbyConfigTypePool(poolKey), true)
    if
      poolKey
      and type(eventPools) == "table"
      and type(eventPools[poolKey]) == "table"
      and #eventPools[poolKey] > 0
    then
      appendVehiclePoolEntries(mergedPool, seen, eventPools[poolKey], true)
    end
    return mergedPool
  end

  local function countConfiguredVehiclePool(poolKey, cfg)
    if not poolKey then return 0 end
    return #mergeStrictVehiclePool(poolKey, cfg and cfg.vehiclePools)
  end

  local function getConfiguredVehiclePool(poolKey)
    local eventCfg = derbyState.activeEventCfg
    local mergedPool = mergeStrictVehiclePool(poolKey, eventCfg and eventCfg.vehiclePools)
    if #mergedPool > 0 then return mergedPool end
    if poolKey then
      derby._log("W", "No configured derby vehicle configs found for strict pool: " .. tostring(poolKey))
      return {}
    end
    if eventCfg and type(eventCfg.vehiclePool) == "table" and #eventCfg.vehiclePool > 0 then
      return eventCfg.vehiclePool
    end
    return newFallbackVehiclePool()
  end

  -- Zone debug drawing --------------------------------------------------------------------------

  local function loadForcedZoneDebugData()
    if not derbyState.configData then derbyState.configData = derby.derbyArena.loadConfigData() end
    if not derbyState.configData then return false end
    return true
  end

  local function findForcedZoneDebugTarget()
    local eventKey = derbyState.forceZoneDebugEventKey or derbyState.activeEvent or derbyUi.getActiveStagingEventKey()
    local eventCfg = eventKey and derby.derbyArena.getEventConfig(eventKey) or nil
    if not eventCfg then
      local keys = derby.derbyArena.getAvailableEventKeys()
      if #keys > 0 then
        eventKey = keys[1]
        eventCfg = derby.derbyArena.getEventConfig(eventKey)
      end
    end
    return eventKey, eventCfg
  end

  local function ensureForcedZoneDebugSpatialData()
    if not derbyState.forceZoneDebugDraw then return end
    if not loadForcedZoneDebugData() then return end
    local eventKey, eventCfg = findForcedZoneDebugTarget()
    if not eventCfg then return end
    if
      derbyState.forceZoneDebugResolvedKey ~= eventKey
      or not derbyState.resolvedPlayZone
      or not derbyState.resolvedElimZones
    then
      derby.derbyArena.resolveAllSpatialData(eventCfg)
      derbyState.forceZoneDebugResolvedKey = eventKey
    end
  end

  local function drawDebugZones()
    if derbyState.forceZoneDebugDraw then ensureForcedZoneDebugSpatialData() end
    if not derbyState.drawZonesActive and not derbyState.forceZoneDebugDraw then return end
    if not debugDrawer then return end
    if derbyState.resolvedPlayZone then drawZoneOutline(derbyState.resolvedPlayZone, PLAY_ZONE_COLOR) end
    if derbyState.resolvedElimZones then
      for _, zone in ipairs(derbyState.resolvedElimZones) do
        drawZoneOutline(zone, ELIMINATION_ZONE_COLOR)
      end
    end
  end

  -- Staging availability ------------------------------------------------------------------------

  local function isAnotherActivityActive()
    if overhaul_events_utils and overhaul_events_utils.isExternalActivityBlockingFreeroam() then return true end
    -- The host can throw nil errors before its own state exists, so a failed call counts as no race.
    local success, currentRace = pcall(overhaul_events_host.getFreeroamDisplayRaceLabel)
    return (success and currentRace and currentRace ~= "") and true or false
  end

  local function findMissingPoolReason(mode, isLoanerMode, cfgForMode)
    local aiPoolKey = mode and mode.aiPool
    if aiPoolKey and countConfiguredVehiclePool(aiPoolKey, cfgForMode) <= 0 then
      return "No derby vehicle configs found for " .. tostring(aiPoolKey) .. "."
    end
    local playerPoolKey = isLoanerMode and mode and mode.playerPool or nil
    if playerPoolKey and countConfiguredVehiclePool(playerPoolKey, cfgForMode) <= 0 then
      return "No loaner derby vehicle configs found for " .. tostring(playerPoolKey) .. "."
    end
    return nil
  end

  local function findOwnVehicleReason(playerVehId, playerVeh)
    if isPlayerWalkingMode() or not playerVeh then return "You must be in a vehicle." end
    if derby.freeroamUtils.isCarJockeyVehicle(playerVehId) then
      return "Car Jockey vehicles cannot be used for events."
    end
    return nil
  end

  local function findUninsuredRequirementReason()
    local inventoryId = getCurrentInventoryVehicleId()
    if not inventoryId then return "Derby requires a career-owned vehicle." end
    if isInventoryVehicleInsured(inventoryId) then return "Derby requires an uninsured vehicle." end
    return nil
  end

  local function findEconomyBlockReason(cfgForMode)
    if derby.derbyRewards.getDerbyEconomyMultiplier(cfgForMode) == 0 then
      return "Demolition Derby is disabled (demo multiplier set to 0)."
    end
    if overhaul_career_challengeModes.isChallengeActive() then
      local activeChallenge = overhaul_career_challengeModes.getActiveChallenge()
      if activeChallenge and activeChallenge.economyAdjuster and activeChallenge.economyAdjuster.demo == 0 then
        return string.format("Demolition Derby is disabled due to '%s' Challenge.", activeChallenge.name or "Unknown")
      end
    end
    return nil
  end

  local function findEntryFeeReason(mode)
    local entryFee = tonumber(mode and mode.entryFee) or 0
    if
      entryFee > 0
      and overhaul_career_career.isActive()
      and not overhaul_career_economy_payment.canPay({ money = { amount = entryFee, canBeNegative = false } })
    then
      return "Not enough money for the entry fee."
    end
    return nil
  end

  local function getStagingStartAvailability(maxAi, modeKey)
    local availableAiSlots = tonumber(maxAi)
    if availableAiSlots == nil then
      availableAiSlots = derbyState.resolvedSpots and math.max(#derbyState.resolvedSpots - 1, 0) or 0
    end
    if availableAiSlots < 1 then return false, "No parking spots available for AI opponents." end
    local stagingKey = derbyUi.getActiveStagingEventKey()
    local cfgForMode = derbyState.activeEventCfg or (stagingKey and derby.derbyArena.getEventConfig(stagingKey)) or nil
    local _, mode = derby.derbyRewards.getEntryModeConfig(cfgForMode, modeKey)
    local isLoanerMode = mode and mode.loaner == true
    local playerVehId = be:getPlayerVehicleID(0)
    local playerVeh = playerVehId and be:getObjectByID(playerVehId) or nil
    local reason = findMissingPoolReason(mode, isLoanerMode, cfgForMode)
    if not reason and not isLoanerMode then reason = findOwnVehicleReason(playerVehId, playerVeh) end
    if not reason and mode and mode.requireUninsured == true then reason = findUninsuredRequirementReason() end
    reason = reason or findEconomyBlockReason(cfgForMode) or findEntryFeeReason(mode)
    if reason then return false, reason end
    return true, nil
  end

  -- Snapshot ------------------------------------------------------------------------------------

  local function ensureConfigAndSites()
    return derby.derbyArena.refreshDerbyForCurrentLevel()
  end

  local function getDerbyEventSnapshot()
    return {
      eventActive = derbyState.eventActive,
      activeEventCfg = derbyState.activeEventCfg,
      playerDerbyVehicleId = derbyState.playerDerbyVehicleId,
      spawnedAiIds = derbyState.spawnedAiIds,
      spawnedAiInfo = derbyState.spawnedAiInfo,
      eliminatedIds = derbyState.eliminatedIds,
      playerEliminated = derbyState.playerEliminated,
      playerPlacement = derbyState.playerPlacement,
      eventFinishReason = derbyState.eventFinishReason,
      activeEntryModeKey = derbyState.activeEntryModeKey,
      activeEntryModeCfg = derbyState.activeEntryModeCfg,
      totalParticipants = derbyState.totalParticipants,
      lastRewardSummary = derbyState.lastRewardSummary,
      activeWinnerRepairInsurance = derbyState.activeWinnerRepairInsurance,
    }
  end

  return {
    getVehiclePos = getVehiclePos,
    despawnVehicle = despawnVehicle,
    getVehicleDamageNormalized = getVehicleDamageNormalized,
    resetNoContactState = resetNoContactState,
    updateNoContactTimer = updateNoContactTimer,
    getConfiguredVehiclePool = getConfiguredVehiclePool,
    normalizeVehiclePoolEntry = normalizeVehiclePoolEntry,
    pickRandomColor = pickRandomColor,
    drawDebugZones = drawDebugZones,
    isAnotherActivityActive = isAnotherActivityActive,
    getPlayerStagingReferencePos = getPlayerStagingReferencePos,
    getCurrentInventoryVehicleId = getCurrentInventoryVehicleId,
    getStagingStartAvailability = getStagingStartAvailability,
    ensureConfigAndSites = ensureConfigAndSites,
    getDerbyEventSnapshot = getDerbyEventSnapshot,
  }
end

return lib
