-- Racer power/class lookup, pool filtering and ordered lineup plans.
-- Pure row helpers precede the per-load power cache, pool transforms, diagnostics and plan builders.
local lib = {}

-- Constants ---------------------------------------------------------------------------------------

local WATTS_PER_HP = 745.7 -- 1 mechanical horsepower
-- Raw engine numbers above this are SI watts; at or below it they are horsepower-scale.
local RAW_POWER_WATTS_THRESHOLD = 10000
-- Configs within this many HP of the player are preferred when picking from the pool.
local CLOSE_HP_TOLERANCE = 25
local STAGING_DEBUG_AI_SLOTS = 4
local MAX_PLAN_ROWS_PER_IDENTITY = 2
local RESOLVED_SAMPLE_MAX_ROWS = 14

-- Legacy defaultVehiclePool tiers use D/C/B/A, picked by the player's hp/kg.
local DCBA_MAX_HP_PER_KG = { D = 0.1433, C = 0.2535, B = 0.3858 }
-- vehiclePool tiers by player hp/kg when cfg.vehiclePool is set; pools merge upward from the player's tier.
local STOCK_MAX_HP_PER_KG = 0.2535
local MODIFIED_MAX_HP_PER_KG = 0.3638
local SUPER_MAX_HP_PER_KG = 0.4520
local VEHICLE_POOL_CLASS_ORDER = { "stock", "modified", "super", "open" }

-- Old aiRacingConfig files used fake band ints (200, 250, ...) on peakHp; these map to a representative hp/kg.
local LEGACY_PEAKHP_BAND_TO_HP_PER_KG = {
  [200] = 0.2205,
  [250] = 0.2866,
  [300] = 0.3307,
  [350] = 0.3968,
  [500] = 0.4850,
}

-- Power units and classes ----------------------------------------------------------------------------

local function getDcbaClassFromPlayerPw(pw)
  if type(pw) ~= "number" or pw < 0 then return "D" end
  if pw <= DCBA_MAX_HP_PER_KG.D then return "D" end
  if pw <= DCBA_MAX_HP_PER_KG.C then return "C" end
  if pw <= DCBA_MAX_HP_PER_KG.B then return "B" end
  return "A"
end

local function getClassFromPwForVehiclePool(pw)
  if type(pw) ~= "number" or pw < 0 then return "stock" end
  if pw <= STOCK_MAX_HP_PER_KG then return "stock" end
  if pw <= MODIFIED_MAX_HP_PER_KG then return "modified" end
  if pw <= SUPER_MAX_HP_PER_KG then return "super" end
  return "open"
end

local function powerWattsToHp(watts)
  local value = tonumber(watts)
  if not value or value < 0 then return nil end
  return value / WATTS_PER_HP
end

-- Vehicle Lua engine.maxPower often returns HP-scale numbers (~400); callbacks expect watts.
local function liveMaxPowerRawToWatts(raw)
  local value = tonumber(raw)
  if not value or value < 0 then return nil end
  if value == 0 then return 0 end
  if value > RAW_POWER_WATTS_THRESHOLD then return value end
  return value * WATTS_PER_HP
end

local function rawPowerToHp(value)
  if value > RAW_POWER_WATTS_THRESHOLD then return value / WATTS_PER_HP end
  return value
end

-- Power in HP from config["Power"] (like vehiclePerformance) or config.aggregates.Power: a number, or a
-- table with propulsionPowerCombined / max / min.
local function getPowerHpFromConfig(config)
  if not config then return nil end
  local power = config["Power"] or (config.aggregates and config.aggregates.Power)
  if type(power) == "number" then return rawPowerToHp(power) end
  if type(power) == "table" then
    local raw = power.propulsionPowerCombined or power.max or power.min
    if type(raw) == "number" then return rawPowerToHp(raw) end
  end
  return nil
end

local function getWeightKgFromConfig(config)
  if not config then return nil end
  return tonumber(config.total_weight or (config.aggregates and config.aggregates.total_weight))
end

local function hpPerKgFromHpAndWeightKg(hp, weightKg)
  local power = tonumber(hp)
  local weight = tonumber(weightKg)
  if not power or power <= 0 or not weight or weight <= 0 then return nil end
  return power / weight
end

-- Integer tier from a config basename: _pw250, pw300 or 200pw.
local function parseFilenameTierInt(configKey)
  if type(configKey) ~= "string" or configKey == "" then return nil end
  local digits = configKey:match("_pw(%d%d%d)") or configKey:match("pw(%d%d%d)") or configKey:match("(%d%d%d)pw")
  local tier = tonumber(digits)
  if tier and tier >= 50 and tier <= 2000 then return math.floor(tier + 0.5) end
  return nil
end

-- Pool row ordering ----------------------------------------------------------------------------------

local function entryModel(entry)
  return type(entry) == "table" and (entry.model or entry.vehicleModel) or nil
end

local function entryConfig(entry)
  return type(entry) == "table" and entry.config or nil
end

local function rowKey(row)
  return (row.model or "") .. "\0" .. (row.config or "")
end

local function comparePwThenModel(left, right)
  if left.pw ~= right.pw then return left.pw < right.pw end
  return (left.model or "") < (right.model or "")
end

local function shuffleInPlace(list)
  for i = #list, 2, -1 do
    local j = math.random(1, i)
    list[i], list[j] = list[j], list[i]
  end
end

local function nonNegativePlayerPw(playerPw)
  local pw = type(playerPw) == "number" and playerPw or 0
  if pw < 0 then pw = 0 end
  return pw
end

local function describeResolvedRows(planDebug, rows)
  planDebug.resolvedRowCount = #rows
  for i = 1, math.min(#rows, RESOLVED_SAMPLE_MAX_ROWS) do
    local row = rows[i]
    table.insert(planDebug.resolvedSample, string.format("%s/%s=%.4f", row.model, row.config, row.pw))
  end
  if #rows > RESOLVED_SAMPLE_MAX_ROWS then
    table.insert(planDebug.resolvedSample, string.format("... +%d more", #rows - RESOLVED_SAMPLE_MAX_ROWS))
  end
end

-- hp/kg window above the player: (floorPw, bandHigh], with bandHigh capped by the sanctioned class ceiling.
-- floorPw sits slightly below the player so catalog rows in the same bin still qualify.
local function closeAboveWindow(playerPw, closeAbovePw, bracketMaxPw, defaultCloseAbovePw)
  local cap = tonumber(closeAbovePw)
  if not cap or cap <= 0 then cap = tonumber(defaultCloseAbovePw) or 0.0617 end
  local bracketMax = type(bracketMaxPw) == "number" and bracketMaxPw > 0 and bracketMaxPw or nil
  local bandHigh = playerPw + cap
  if bracketMax then bandHigh = math.min(bandHigh, bracketMax) end
  return {
    playerPw = playerPw,
    floorPw = playerPw - math.max(1e-9, playerPw * 1e-7 + 1e-12),
    cap = cap,
    bracketMax = bracketMax,
    bandHigh = bandHigh,
  }
end

-- Lineup selection -----------------------------------------------------------------------------------

-- Picks requestedCount rows from a shuffled pool: one per model first, then other configs, then repeats.
local function pickNearestRandomVarietyPlan(pool, requestedCount)
  if type(pool) ~= "table" or #pool == 0 or type(requestedCount) ~= "number" or requestedCount < 1 then return {} end
  local shuffled = {}
  for _, row in ipairs(pool) do
    table.insert(shuffled, row)
  end
  shuffleInPlace(shuffled)
  local picked = {}
  local pickedKeys = {}
  local modelUsed = {}
  for _, row in ipairs(shuffled) do
    if #picked >= requestedCount then break end
    local model = row.model or ""
    if not modelUsed[model] then
      modelUsed[model] = true
      local key = rowKey(row)
      if not pickedKeys[key] then
        pickedKeys[key] = true
        table.insert(picked, row)
      end
    end
  end
  for _, row in ipairs(shuffled) do
    if #picked >= requestedCount then break end
    local key = rowKey(row)
    if not pickedKeys[key] then
      pickedKeys[key] = true
      table.insert(picked, row)
    end
  end
  local repeatIndex = 1
  while #picked < requestedCount and #shuffled > 0 do
    local row = shuffled[((repeatIndex - 1) % #shuffled) + 1]
    repeatIndex = repeatIndex + 1
    table.insert(picked, { model = row.model, config = row.config, pw = row.pw })
  end
  local plan = {}
  for _, row in ipairs(picked) do
    table.insert(plan, { model = row.model, config = row.config, matchPw = row.pw })
  end
  return plan
end

local function sortedUniqueBand(rows, window, planDebug)
  local band = {}
  for _, row in ipairs(rows) do
    if row.pw > window.floorPw and row.pw <= window.bandHigh then table.insert(band, row) end
  end
  table.sort(band, comparePwThenModel)
  local seen = {}
  local unique = {}
  for _, row in ipairs(band) do
    local key = rowKey(row)
    if not seen[key] then
      seen[key] = true
      table.insert(unique, row)
      table.insert(planDebug.bandList, string.format("%s/%s %.4f hp/kg", row.model, row.config, row.pw))
    end
  end
  return unique
end

-- Round-robins rows into the plan, at most MAX_PLAN_ROWS_PER_IDENTITY per model+config, until it is full or nothing fits.
local function addRowsUpToIdentityLimit(plan, orderedRows, requestedCount, identityCounts)
  while #plan < requestedCount do
    local added = false
    for _, row in ipairs(orderedRows) do
      if #plan >= requestedCount then break end
      local key = rowKey(row)
      if (identityCounts[key] or 0) < MAX_PLAN_ROWS_PER_IDENTITY then
        table.insert(plan, { model = row.model, config = row.config, matchPw = row.pw })
        identityCounts[key] = (identityCounts[key] or 0) + 1
        added = true
      end
    end
    if not added then break end
  end
end

-- One row per model+config (its lowest hp/kg), lowest hp/kg first.
local function bandRepresentatives(band)
  local representative = {}
  for _, row in ipairs(band) do
    local key = rowKey(row)
    local existing = representative[key]
    if not existing or row.pw < existing.pw then representative[key] = row end
  end
  local ordered = {}
  for _, row in pairs(representative) do
    table.insert(ordered, row)
  end
  table.sort(ordered, function(left, right)
    if left.pw ~= right.pw then return left.pw < right.pw end
    return rowKey(left) < rowKey(right)
  end)
  return ordered
end

local function businessBranchName(planDebug)
  local cycled = planDebug.cyclesAdded > 0
  if planDebug.aboveAdded > 0 and planDebug.belowAdded > 0 then
    return cycled and "business_above_below_cycle" or "business_above_below_only"
  elseif planDebug.aboveAdded > 0 then
    return cycled and "business_above_cycle" or "business_above_only"
  elseif planDebug.belowAdded > 0 then
    return cycled and "business_below_cycle" or "business_below_only"
  end
  return cycled and "business_all_cycle" or "business_empty"
end

-- Per-load planner -------------------------------------------------------------------------------

-- Power and class lookups ---------------------------------------------------------------------------

local function installPowerLookups(ownerServices, services)
  local DEFAULT_CONFIG = ownerServices.DEFAULT_CONFIG
  -- cfg.vehiclePoolByHpClass[class] when set, else defaultVehiclePool.
  function services.getVehiclePoolForHpClass(cfg, class)
    local byClass = cfg.vehiclePoolByHpClass and cfg.vehiclePoolByHpClass[class]
    if type(byClass) == "table" and #byClass > 0 then return byClass end
    return cfg.defaultVehiclePool or DEFAULT_CONFIG.defaultVehiclePool
  end

  -- Match hp/kg for a pool row: the catalog config first (JSON peakPw is ignored), then a legacy peakHp band,
  -- then the filename tier divided by 1000.
  function services.getMatchPwForPoolEntry(entry, model, config)
    if type(model) == "string" and type(config) == "string" then
      local catalogConfig = core_vehicles.getConfig(model, config)
      local catalogPw =
        hpPerKgFromHpAndWeightKg(getPowerHpFromConfig(catalogConfig), getWeightKgFromConfig(catalogConfig))
      if type(catalogPw) == "number" and catalogPw > 0 then return catalogPw end
    end
    if type(entry) == "table" then
      local legacyPeakHp = tonumber(entry.peakHp) or tonumber(entry.hp) or tonumber(entry.powerHp)
      if legacyPeakHp and legacyPeakHp > 0 then
        local band = LEGACY_PEAKHP_BAND_TO_HP_PER_KG[math.floor(legacyPeakHp + 0.5)]
        if band then return band end
        if legacyPeakHp < 2 then return legacyPeakHp end
      end
    end
    if type(config) == "string" then
      local tier = parseFilenameTierInt(config)
      if tier then return tier / 1000 end
    end
    return nil
  end

  -- Power in HP of a model's config (its default config when configKey is empty), or nil.
  function services.getPowerForModelConfig(modelKey, configKey)
    if not modelKey or type(modelKey) ~= "string" then return nil end
    local data = core_vehicles.getModel(modelKey)
    if not data or not data.model or not data.configs then return nil end
    if not configKey or type(configKey) ~= "string" or configKey == "" then
      configKey = data.model.default_pc
      if not configKey then
        for key, _ in pairs(data.configs) do
          configKey = key
          break
        end
      end
    end
    if not configKey then return nil end
    return getPowerHpFromConfig(core_vehicles.getConfig(modelKey, configKey))
  end
end

-- Pool entry helpers --------------------------------------------------------------------------------

local function installPoolRows(ownerServices, services, helpers)
  -- Rows { model, config, pw } for every entry with a usable model, config and positive hp/kg.
  function helpers.resolvePoolRows(available)
    local rows = {}
    for _, entry in ipairs(available) do
      local model, config = entryModel(entry), entryConfig(entry)
      if type(model) == "string" and type(config) == "string" and config ~= "" then
        local pw = services.getMatchPwForPoolEntry(entry, model, config)
        if type(pw) == "number" and pw > 0 then table.insert(rows, { model = model, config = config, pw = pw }) end
      end
    end
    return rows
  end
end

-- Pool filters and merges ---------------------------------------------------------------------------

local function installPoolFilters(ownerServices, services, helpers)
  local DEFAULT_CONFIG = ownerServices.DEFAULT_CONFIG
  -- Keeps rows with hp/kg <= playerPw * (1 + aiPowerExceedCapPct).
  function services.filterPoolByPowerWeight(rawPool, playerPw, cfg)
    if type(rawPool) ~= "table" or #rawPool == 0 then return rawPool end
    local usePw = cfg.filterPoolByPowerWeightMeetOrExceed == true or cfg.filterPoolByPowerMeetOrExceed == true
    if usePw ~= true or type(playerPw) ~= "number" or playerPw < 0 then return rawPool end
    local capPct = tonumber(cfg.aiPowerExceedCapPct)
    if not capPct or capPct < 0 then capPct = tonumber(DEFAULT_CONFIG.aiPowerExceedCapPct) or 0.25 end
    local maxPw = playerPw * (1 + capPct)
    local kept = {}
    for _, entry in ipairs(rawPool) do
      local model = entryModel(entry) or entry
      if type(model) == "string" then
        local poolPw = nil
        if type(entry) == "table" then
          poolPw = services.getMatchPwForPoolEntry(entry, model, entryConfig(entry))
        else
          local data = core_vehicles.getModel(model)
          local configKey = nil
          if data and data.model then
            configKey = data.model.default_pc
            if not configKey and data.model.configs then
              for key, _ in pairs(data.model.configs) do
                configKey = key
                break
              end
            end
          end
          if configKey then poolPw = services.getMatchPwForPoolEntry({}, model, configKey) end
        end
        if poolPw and poolPw <= maxPw then table.insert(kept, entry) end
      end
    end
    return kept
  end

  -- Keeps entries whose hp/kg is unknown or passes keepEntry; falls back to rawPool when none remain unless strict.
  function helpers.filterPoolByBracket(rawPool, keepEntry, strict)
    local kept = {}
    for _, entry in ipairs(rawPool) do
      local model = entryModel(entry) or entry
      if type(model) == "string" then
        local poolPw = services.getMatchPwForPoolEntry(entry, model, entryConfig(entry))
        if not poolPw or keepEntry(poolPw) then table.insert(kept, entry) end
      end
    end
    if #kept == 0 and not strict then return rawPool end
    return kept
  end

  -- Sanctioned class floor: drops rows below minPw.
  function services.filterPoolByBracketMin(rawPool, minPw)
    if type(rawPool) ~= "table" or #rawPool == 0 then return rawPool end
    if type(minPw) ~= "number" or minPw <= 0 then return rawPool end
    return helpers.filterPoolByBracket(rawPool, function(poolPw)
      return poolPw >= minPw
    end, false)
  end

  -- Sanctioned class ceiling: drops rows above maxPw. strict keeps an empty result instead of relaxing to rawPool.
  function services.filterPoolByBracketMax(rawPool, maxPw, strict)
    if type(rawPool) ~= "table" or #rawPool == 0 then return rawPool end
    if type(maxPw) ~= "number" or maxPw <= 0 then return rawPool end
    return helpers.filterPoolByBracket(rawPool, function(poolPw)
      return poolPw <= maxPw
    end, strict)
  end

  function helpers.getAvailableModelLookup()
    local available = {}
    local list = core_vehicles.getVehicleList()
    for _, vehicle in ipairs(list and list.vehicles or {}) do
      local key = vehicle and vehicle.model and vehicle.model.key
      if type(key) == "string" and key ~= "" then available[key] = true end
    end
    return available
  end

  -- Model keys that exist in the game, unique; no fallback to all vehicles, so trailers and trucks stay out.
  function services.filterPoolToAvailableModels(rawPool)
    local available = helpers.getAvailableModelLookup()
    local models = {}
    local seen = {}
    if type(rawPool) == "table" then
      for _, entry in ipairs(rawPool) do
        local model = entryModel(entry) or entry
        if type(model) == "string" and available[model] and not seen[model] then
          seen[model] = true
          table.insert(models, model)
        end
      end
    end
    return models
  end

  -- vehiclePool rows { model, config } whose model exists, as new rows.
  function services.filterVehiclePoolToAvailable(rawPool)
    local available = helpers.getAvailableModelLookup()
    local rows = {}
    if type(rawPool) ~= "table" then return rows end
    for _, entry in ipairs(rawPool) do
      local model, config = entryModel(entry), entryConfig(entry)
      if type(model) == "string" and available[model] and type(config) == "string" and config ~= "" then
        local row = { model = model, config = config }
        if type(entry) == "table" then
          local peakHp = tonumber(entry.peakHp) or tonumber(entry.hp) or tonumber(entry.powerHp)
          if peakHp and peakHp > 0 then row.peakHp = peakHp end
        end
        table.insert(rows, row)
      end
    end
    return rows
  end

  function helpers.vehiclePoolClassOrderIndex(class)
    if type(class) ~= "string" then return 1 end
    for i, tierName in ipairs(VEHICLE_POOL_CLASS_ORDER) do
      if tierName == class then return i end
    end
    return 1
  end

  -- vehiclePool entries from startClass through open, de-duplicated by model and config.
  function services.mergeVehiclePoolFromClassUpward(vehiclePool, startClass)
    local merged = {}
    if type(vehiclePool) ~= "table" then return merged end
    local seen = {}
    for i = helpers.vehiclePoolClassOrderIndex(startClass), #VEHICLE_POOL_CLASS_ORDER do
      local tierPool = vehiclePool[VEHICLE_POOL_CLASS_ORDER[i]]
      if type(tierPool) == "table" then
        for _, entry in ipairs(tierPool) do
          local model, config = entryModel(entry), entryConfig(entry)
          if type(model) == "string" and type(config) == "string" and config ~= "" then
            local key = model .. "\0" .. config
            if not seen[key] then
              seen[key] = true
              table.insert(merged, entry)
            end
          end
        end
      end
    end
    return merged
  end

  -- Merges from the first non-empty tier, for races that omit e.g. stock but define modified and up.
  function services.mergeVehiclePoolFromFirstAvailableTier(vehiclePool)
    if type(vehiclePool) ~= "table" then return {} end
    for _, tierName in ipairs(VEHICLE_POOL_CLASS_ORDER) do
      local tierPool = vehiclePool[tierName]
      if type(tierPool) == "table" and #tierPool > 0 then
        return services.mergeVehiclePoolFromClassUpward(vehiclePool, tierName)
      end
    end
    return {}
  end
end

-- Staging debug lines -------------------------------------------------------------------------------

local function installDebugLines(ownerServices, services, helpers)
  local racerState = ownerServices.racerState
  function helpers.stagingDebugLivePlayerLine(powerDebug)
    if type(powerDebug.playerPwDbg) == "number" and powerDebug.playerPwDbg > 0 then
      return string.format("live player hp/kg = %.4f", powerDebug.playerPwDbg)
    end
    return "live player hp/kg = n/a"
  end

  function helpers.stagingDebugPwForPlanSlot(spec)
    if type(spec) ~= "table" then return 0 end
    local specPw = tonumber(spec.matchPw) or tonumber(spec.powerHp)
    if specPw and specPw > 0 then return specPw end
    if type(spec.model) == "string" and type(spec.config) == "string" then
      local catalogPw = services.getMatchPwForPoolEntry({}, spec.model, spec.config)
      if type(catalogPw) == "number" and catalogPw > 0 then return catalogPw end
    end
    return 0
  end

  function helpers.stagingDebugConfigLabelForPlanSlot(spec)
    if type(spec) == "table" and type(spec.model) == "string" and type(spec.config) == "string" then
      return spec.model .. "/" .. spec.config
    end
    return "—"
  end

  function services.buildStagingSpawnDebugLinesFromPlan(powerDebug, plan)
    local lines = { helpers.stagingDebugLivePlayerLine(powerDebug) }
    for i = 1, STAGING_DEBUG_AI_SLOTS do
      local spec = plan and plan[i]
      if spec then
        lines[#lines + 1] = string.format(
          "AI %d = %s, %.4f hp/kg",
          i,
          helpers.stagingDebugConfigLabelForPlanSlot(spec),
          helpers.stagingDebugPwForPlanSlot(spec)
        )
      else
        lines[#lines + 1] = string.format("AI %d = —", i)
      end
    end
    return lines
  end

  function services.buildStagingSpawnDebugLinesFromRecentSpawned(powerDebug, spawnedCount)
    local lines = { helpers.stagingDebugLivePlayerLine(powerDebug) }
    local total = #racerState.mSpawnedAiVehicleIds
    local recentCount = math.max(0, tonumber(spawnedCount) or 0)
    local firstIndex = (recentCount > 0) and (total - recentCount + 1) or (total + 1)
    for i = 1, STAGING_DEBUG_AI_SLOTS do
      local vehId = racerState.mSpawnedAiVehicleIds[firstIndex + i - 1]
      if vehId then
        local details = core_vehicles.getVehicleDetails(vehId)
        local model = details and details.current and details.current.key
        local configKey = details and details.current and details.current.config_key
        local pw = 0
        if type(model) == "string" and type(configKey) == "string" then
          pw = tonumber(services.getMatchPwForPoolEntry({}, model, configKey)) or 0
        end
        lines[#lines + 1] =
          string.format("AI %d = %s/%s, %.4f hp/kg", i, tostring(model or "?"), tostring(configKey or "?"), pw)
      else
        lines[#lines + 1] = string.format("AI %d = —", i)
      end
    end
    return lines
  end
end

-- Plan builders -------------------------------------------------------------------------------------

local function installPlanBuilders(ownerServices, services, helpers)
  -- Lineup by smallest |pw - playerPw|, random with model variety inside the nearest distance band.
  function services.buildNearestRandomVarietyPlan(available, playerPw, requestedCount, bracketMaxPw)
    if type(available) ~= "table" or type(requestedCount) ~= "number" or requestedCount < 1 then return {} end
    local playerPwClamped = nonNegativePlayerPw(playerPw)
    local rows = {}
    for _, row in ipairs(helpers.resolvePoolRows(available)) do
      local aboveCeiling = type(bracketMaxPw) == "number" and bracketMaxPw > 0 and row.pw > bracketMaxPw + 1e-9
      if not aboveCeiling then
        row.dist = math.abs(row.pw - playerPwClamped)
        table.insert(rows, row)
      end
    end
    if #rows == 0 then return {} end
    table.sort(rows, function(left, right)
      if left.dist ~= right.dist then return left.dist < right.dist end
      if (left.model or "") ~= (right.model or "") then return (left.model or "") < (right.model or "") end
      return (left.config or "") < (right.config or "")
    end)
    local lastIndex = math.min(#rows, math.max(requestedCount * 4, requestedCount + 4))
    local cutoff = rows[lastIndex].dist + 1e-8
    local pool = {}
    for _, row in ipairs(rows) do
      if row.dist <= cutoff then table.insert(pool, row) end
    end
    shuffleInPlace(pool)
    return pickNearestRandomVarietyPlan(pool, requestedCount)
  end

  -- Plan of { model, config, matchPw }: cycles rows with hp/kg in (playerPw, playerPw + closeAbovePw]; when none
  -- qualify it takes the closest row above the player and cycles the whole pool for the rest.
  function services.buildCloseAbovePlan(available, playerPw, requestedCount, closeAbovePw, bracketMaxPw)
    local plan = {}
    local planDebug = {
      branch = "none",
      availableCount = type(available) == "table" and #available or 0,
      playerPwUsed = 0,
      closeAboveCap = tonumber(closeAbovePw) or 0.0617,
      bandWindow = "",
      bandUniqueCount = 0,
      bandList = {},
      resolvedRowCount = 0,
      resolvedSample = {},
      nextCar = nil,
    }
    if type(available) ~= "table" or type(requestedCount) ~= "number" or requestedCount < 1 then
      planDebug.branch = "invalid_args"
      return plan, planDebug
    end
    local window = closeAboveWindow(nonNegativePlayerPw(playerPw), closeAbovePw, bracketMaxPw, ownerServices.DEFAULT_CONFIG.aiPoolCloseAbovePw)
    planDebug.playerPwUsed = window.playerPw
    planDebug.closeAboveCap = window.cap
    planDebug.bandWindow = string.format("(%.4f, %.4f]", window.playerPw, window.bandHigh)
    local rows = helpers.resolvePoolRows(available)
    describeResolvedRows(planDebug, rows)
    local unique = sortedUniqueBand(rows, window, planDebug)
    planDebug.bandUniqueCount = #unique
    if #unique >= 1 then
      planDebug.branch = "band_cycle"
      for i = 1, requestedCount do
        local row = unique[((i - 1) % #unique) + 1]
        table.insert(plan, { model = row.model, config = row.config, matchPw = row.pw })
      end
      return plan, planDebug
    end
    local above = {}
    for _, row in ipairs(rows) do
      if row.pw > window.floorPw and (not window.bracketMax or row.pw <= window.bracketMax) then
        table.insert(above, row)
      end
    end
    if #above == 0 then
      if #rows > 0 then
        planDebug.branch = "all_cycle_rows_no_band"
        ownerServices.parts.config.fillSpawnPlanCyclingRows(plan, rows, requestedCount)
      else
        planDebug.branch = "empty_no_rows"
      end
      return plan, planDebug
    end
    table.sort(above, comparePwThenModel)
    local closest = above[1]
    planDebug.branch = "fallback_one_pool_rest_cycle"
    planDebug.nextCar = string.format("%s/%s %.4f hp/kg", closest.model, closest.config, closest.pw)
    table.insert(plan, { model = closest.model, config = closest.config, matchPw = closest.pw })
    ownerServices.parts.config.fillSpawnPlanCyclingRows(plan, rows, requestedCount)
    return plan, planDebug
  end

  -- Racing-team business offers: the close-above windows plus a matching band below the player, at most 2 per identity.
  function services.buildBusinessSanctionedPlan(available, playerPw, requestedCount, closeAbovePw, bracketMaxPw)
    local plan = {}
    local planDebug = {
      branch = "business_sanctioned",
      availableCount = type(available) == "table" and #available or 0,
      playerPwUsed = 0,
      closeAboveCap = tonumber(closeAbovePw) or 0.0617,
      aboveWindow = "",
      belowWindow = "",
      aboveAdded = 0,
      belowAdded = 0,
      cyclesAdded = 0,
      resolvedRowCount = 0,
      resolvedSample = {},
    }
    if type(available) ~= "table" or type(requestedCount) ~= "number" or requestedCount < 1 then
      planDebug.branch = "invalid_args"
      return plan, planDebug
    end
    local window = closeAboveWindow(nonNegativePlayerPw(playerPw), closeAbovePw, bracketMaxPw, ownerServices.DEFAULT_CONFIG.aiPoolCloseAbovePw)
    local bandLow = window.playerPw - window.cap
    planDebug.playerPwUsed = window.playerPw
    planDebug.closeAboveCap = window.cap
    planDebug.aboveWindow = string.format("(%.4f, %.4f]", window.playerPw, window.bandHigh)
    planDebug.belowWindow = string.format("[%.4f, %.4f)", bandLow, window.playerPw)
    local rows = helpers.resolvePoolRows(available)
    describeResolvedRows(planDebug, rows)
    local above = {}
    local below = {}
    for _, row in ipairs(rows) do
      if row.pw > window.floorPw and row.pw <= window.bandHigh then
        table.insert(above, row)
      elseif row.pw >= bandLow and row.pw < window.playerPw then
        if not window.bracketMax or row.pw <= window.bracketMax then table.insert(below, row) end
      end
    end
    table.sort(above, comparePwThenModel)
    table.sort(below, comparePwThenModel)
    local identityCounts = {}
    addRowsUpToIdentityLimit(plan, bandRepresentatives(above), requestedCount, identityCounts)
    planDebug.aboveAdded = #plan
    addRowsUpToIdentityLimit(plan, bandRepresentatives(below), requestedCount, identityCounts)
    planDebug.belowAdded = #plan - planDebug.aboveAdded
    local beforeCycling = #plan
    ownerServices.parts.config.fillSpawnPlanCyclingRows(plan, rows, requestedCount)
    planDebug.cyclesAdded = #plan - beforeCycling
    planDebug.branch = businessBranchName(planDebug)
    return plan, planDebug
  end

  -- Racing-team proxy: rows with hp/kg in [minPw, maxPw], highest hp/kg first.
  function services.buildBracketMaxBiasedPlan(available, minPw, maxPw, requestedCount)
    local plan = {}
    if type(available) ~= "table" or type(requestedCount) ~= "number" or requestedCount < 1 then return plan end
    local lowPw = tonumber(minPw) or 0
    local highPw = tonumber(maxPw) or 0
    if highPw < lowPw then highPw = lowPw end
    local rows = {}
    for _, row in ipairs(helpers.resolvePoolRows(available)) do
      if row.pw >= lowPw and row.pw <= highPw then table.insert(rows, row) end
    end
    if #rows == 0 then return plan end
    table.sort(rows, function(left, right)
      if left.pw ~= right.pw then return left.pw > right.pw end
      if (left.model or "") ~= (right.model or "") then return (left.model or "") < (right.model or "") end
      return (left.config or "") < (right.config or "")
    end)
    addRowsUpToIdentityLimit(plan, rows, requestedCount, {})
    ownerServices.parts.config.fillSpawnPlanCyclingRows(plan, rows, requestedCount)
    return plan
  end

  -- Cycles the vehiclePool tier named classId, limited to the sanctioned hp/kg bracket.
  function services.buildStrictClassFallbackPlanFromVehiclePool(cfg, classId, requestedCount, minPw, maxPw)
    if type(cfg) ~= "table" or type(cfg.vehiclePool) ~= "table" then return {} end
    if type(requestedCount) ~= "number" or requestedCount < 1 then return {} end
    local tier = cfg.vehiclePool[classId]
    if type(tier) ~= "table" or #tier == 0 then return {} end
    local available = services.filterVehiclePoolToAvailable(tier)
    available = services.filterPoolByBracketMin(available, minPw)
    available = services.filterPoolByBracketMax(available, maxPw, true)
    if type(available) ~= "table" or #available == 0 then return {} end
    local rows = {}
    for _, entry in ipairs(available) do
      local model, config = entryModel(entry), entryConfig(entry)
      if type(model) == "string" and model ~= "" and type(config) == "string" and config ~= "" then
        table.insert(rows, { model = model, config = config, matchPw = services.getMatchPwForPoolEntry(entry, model, config) })
      end
    end
    if #rows == 0 then return {} end
    local plan = {}
    for i = 1, requestedCount do
      local row = rows[((i - 1) % #rows) + 1]
      plan[i] = { model = row.model, config = row.config, matchPw = row.matchPw }
    end
    return plan
  end
end

-- Per-load planner -------------------------------------------------------------------------------

function lib.create(ownerServices)
  local helpers = {}
  local services = {
    getDcbaClassFromPlayerPw = getDcbaClassFromPlayerPw,
    CLOSE_HP_TOLERANCE = CLOSE_HP_TOLERANCE,
    getClassFromPwForVehiclePool = getClassFromPwForVehiclePool,
    -- The existing part contract calls this Hp, but its argument is horsepower per kilogram.
    getClassFromHpForVehiclePool = getClassFromPwForVehiclePool,
    WATTS_PER_HP = WATTS_PER_HP,
    powerWattsToHp = powerWattsToHp,
    liveMaxPowerRawToWatts = liveMaxPowerRawToWatts,
    getPowerHpFromConfig = getPowerHpFromConfig,
    getWeightKgFromConfig = getWeightKgFromConfig,
    hpPerKgFromHpAndWeightKg = hpPerKgFromHpAndWeightKg,
  }
  installPowerLookups(ownerServices, services)
  installPoolRows(ownerServices, services, helpers)
  installPoolFilters(ownerServices, services, helpers)
  installDebugLines(ownerServices, services, helpers)
  installPlanBuilders(ownerServices, services, helpers)

  return services
end

return lib
