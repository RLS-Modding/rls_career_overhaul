-- Filters traffic configurations and builds replacement groups without changing stock fallback order.
-- Reading order: config, state, parts, spawn intent, weights, rejection checks, group creation and game hooks.
local M = {}

-- core_multiSpawn is a level preset; the registry wraps each copy a level loads.
M.dependencies = {'overhaul_shell_patches'}

-- Config ------------------------------------------------------------------------------------------

local PATCH_ID = 'trafficConfigFilter'
local logTag = 'trafficConfigFilter'
local RULES_PATH = '/gameplay/overhaul/traffic/trafficConfigPartRules.json'

-- State -------------------------------------------------------------------------------------------

local rules = nil
local cache = {} -- cacheKey -> { ok = bool, reason = string|nil }

-- Helpers -----------------------------------------------------------------------------------------

-- Built-in rules, used when the rules file is missing or invalid. A fresh table each call.
local function defaultRules()
  return {
    rejectConfigTypes = { 'Frame', 'joesJunkshell' },
    rejectTrafficConfigTypes = { 'Police' },
    trafficConfigTypeWeights = { joesjunkcar = 0.05, joesjunk = 0.05 },
    rejectConfigNamePatterns = { 'police' },
    rejectIfPowerAtMost = 0,
    rejectIfPowerBelow = 60,
    rejectPartValuePatterns = { 'wheel_square' },
    engineSlotNameMustInclude = 'engine',
    engineSlotNameMustNotInclude = { 'ecu', 'internal', 'mount', 'cover', 'lid', 'bay', 'sound' },
    rejectEmptyMainEngineSlot = true,
    requireFrontAndRearWheels = true,
    wheelSlotNamePattern = '^wheel_[FR]',
  }
end

local function loadRules()
  local data = jsonReadFile(RULES_PATH)
  if type(data) ~= 'table' then
    log('W', logTag, 'Missing or invalid rules at ' .. RULES_PATH .. '; using built-in defaults')
    data = defaultRules()
  end
  rules = data
  table.clear(cache)
  return rules
end

local function getRules()
  if not rules then loadRules() end
  return rules
end

local function cacheKey(model, config)
  return tostring(model or '') .. '/' .. tostring(config or '')
end

local function lower(text)
  return string.lower(tostring(text or ''))
end

local function shallowCopy(source)
  local copy = {}
  for key, value in pairs(source) do copy[key] = value end
  return copy
end

-- Vehicle definitions and parts --------------------------------------------------------------------

-- "lid" must be a standalone token so slots like "bolide_engine" are not rejected.
local function slotNameHasBannedFragment(slotName, banned)
  local bannedText = lower(banned)
  if bannedText == 'lid' then
    return string.find(slotName, '%f[%w]lid%f[%W]') ~= nil or string.find(slotName, '%f[%w]lid$') ~= nil
  end
  return string.find(slotName, bannedText, 1, true) ~= nil
end

local function isMainEngineSlot(slotName, ruleSet)
  local lowerName = lower(slotName)
  local mustInclude = lower(ruleSet.engineSlotNameMustInclude or 'engine')
  if not string.find(lowerName, mustInclude, 1, true) then
    return false
  end
  for _, banned in ipairs(ruleSet.engineSlotNameMustNotInclude or {}) do
    if slotNameHasBannedFragment(lowerName, banned) then
      return false
    end
  end
  return true
end

-- Returns true and the matched pattern when the part value holds a rejected pattern.
local function partValueRejected(value, ruleSet)
  local text = lower(value)
  if text == '' then
    return false
  end
  for _, pattern in ipairs(ruleSet.rejectPartValuePatterns or {}) do
    if string.find(text, lower(pattern), 1, true) then
      return true, pattern
    end
  end
  return false
end

local function readParts(model, config)
  if not model or not config or config == '' then
    return nil
  end
  local path = '/vehicles/' .. model .. '/' .. config .. '.pc'
  local data = jsonReadFile(path)
  if type(data) ~= 'table' then
    return nil
  end
  return data.parts or data.slotMap or nil
end

local function getConfigInfo(model, config)
  local modelData = core_vehicles.getModel(model)
  if not modelData or type(modelData.configs) ~= 'table' then
    return nil
  end
  return modelData.configs[config]
end

-- Spawn intent ------------------------------------------------------------------------------------

local function isPoliceSpawnIntent(params)
  if type(params) ~= 'table' then return false end
  local configTypeFilter = params.filters and params.filters['Config Type']
  if type(configTypeFilter) ~= 'table' then return false end
  local policeWeight = tonumber(configTypeFilter.police) or tonumber(configTypeFilter.Police) or 0
  if policeWeight <= 0 then return false end
  local otherWeight = configTypeFilter.other
  if otherWeight == nil then return true end
  return tonumber(otherWeight) == 0
end

local function isParkedSpawnIntent(params)
  local filter = type(params) == 'table' and params.filters and params.filters.Type
  if type(filter) ~= 'table' then return false end
  local parkedWeight = 0
  for configType, weight in pairs(filter) do
    if lower(configType) == 'propparked' then
      parkedWeight = tonumber(weight) or 0
    elseif (tonumber(weight) or 0) > 0 then
      return false
    end
  end
  return parkedWeight > 0
end

-- Traffic group weighting --------------------------------------------------------------------------

local function hasNumericWeight(weights)
  for _, weight in pairs(weights) do
    if tonumber(weight) ~= nil then return true end
  end
  return false
end

-- Copies the wanted config types, so the rules and the caller's filters stay untouched.
local function weightedConfigTypes(filters, weights)
  local configTypes = type(filters['Config Type']) == 'table' and shallowCopy(filters['Config Type']) or {other = 1}
  for configType, weight in pairs(weights) do
    local numeric = tonumber(weight)
    if numeric ~= nil then configTypes[lower(configType)] = numeric end
  end
  return configTypes
end

local function withConfigTypeWeights(params, weights)
  local out = shallowCopy(params)
  out.filters = shallowCopy(params.filters or {})
  out.filters['Config Type'] = weightedConfigTypes(out.filters, weights)
  return out
end

local function applyTrafficConfigTypeWeights(params)
  if type(params) ~= 'table' or isPoliceSpawnIntent(params) or isParkedSpawnIntent(params) then
    return params
  end
  local weights = getRules().trafficConfigTypeWeights
  if type(weights) ~= 'table' or not hasNumericWeight(weights) then
    return params
  end
  return withConfigTypeWeights(params, weights)
end

-- Rejection checks --------------------------------------------------------------------------------

local function isReservedTrafficConfig(model, config, ruleSet)
  local info = getConfigInfo(model, config)
  local configType = info and (info['Config Type'] or info.configType) or nil
  if configType then
    local lowerType = lower(configType)
    for _, reserved in ipairs(ruleSet.rejectTrafficConfigTypes or { 'Police' }) do
      if lowerType == lower(reserved) then
        return true, 'trafficConfigType:' .. tostring(configType)
      end
    end
  end
  local cfgName = lower(config)
  if cfgName ~= '' then
    for _, pattern in ipairs(ruleSet.rejectConfigNamePatterns or { 'police' }) do
      if string.find(cfgName, lower(pattern), 1, true) then
        return true, 'configName:' .. tostring(pattern)
      end
    end
  end
  return false
end

local function configTypeRejection(configType, ruleSet)
  if not configType then return nil end
  local lowerType = lower(configType)
  for _, bad in ipairs(ruleSet.rejectConfigTypes or {}) do
    if lowerType == lower(bad) then return 'configType:' .. tostring(configType) end
  end
  return nil
end

local function powerRejection(power, ruleSet, parkedPool)
  if parkedPool or power == nil then return nil end
  local atMost = tonumber(ruleSet.rejectIfPowerAtMost)
  if atMost ~= nil and power <= atMost then return 'powerAtMost:' .. tostring(power) end
  local below = tonumber(ruleSet.rejectIfPowerBelow)
  if below ~= nil and power > 0 and power < below then return 'powerBelow:' .. tostring(power) end
  return nil
end

-- Walks every part slot once; returns the first rejection reason, or nil with the slot tallies in `scan`.
local function checkPartSlot(slotName, value, ruleSet, scan, parkedPool)
  local text = value == nil and '' or tostring(value)
  local badValue, pattern = partValueRejected(text, ruleSet)
  if badValue then return 'partValue:' .. pattern .. ':' .. slotName end

  if isMainEngineSlot(slotName, ruleSet) then
    scan.sawMainEngine = true
    if text == '' then scan.mainEngineEmpty = true end
  end

  if not parkedPool and ruleSet.requireFrontAndRearWheels ~= false then
    local wheelPattern = ruleSet.wheelSlotNamePattern or '^wheel_[FR]'
    if string.match(slotName, wheelPattern) then
      if text == '' then return 'emptyWheel:' .. slotName end
      if string.match(slotName, '^wheel_F') then
        scan.hasFrontWheel = true
      elseif string.match(slotName, '^wheel_R') then
        scan.hasRearWheel = true
      end
    end
  end
  return nil
end

local function scanParts(parts, ruleSet, parkedPool)
  local scan = {}
  for slot, value in pairs(parts) do
    local reason = checkPartSlot(tostring(slot), value, ruleSet, scan, parkedPool)
    if reason then return reason end
  end
  return nil, scan
end

-- Once every slot is read: an empty main engine, a missing engine on a zero-power config, or half a wheel pair.
local function engineAndWheelRejection(scan, ruleSet, parkedPool, power)
  local rejectsEmptyEngine = not parkedPool and ruleSet.rejectEmptyMainEngineSlot ~= false
  if rejectsEmptyEngine and scan.sawMainEngine and scan.mainEngineEmpty then return 'emptyEngine' end
  -- No main engine slot at all + zero/missing power → treat as roller/shell.
  if rejectsEmptyEngine and not scan.sawMainEngine and (power == nil or power <= 0) then return 'noEngine' end
  if not parkedPool and ruleSet.requireFrontAndRearWheels ~= false and (scan.hasFrontWheel or scan.hasRearWheel) then
    if not scan.hasFrontWheel or not scan.hasRearWheel then return 'incompleteWheels' end
  end
  return nil
end

local function partsRejection(model, config, ruleSet, parkedPool, power)
  local parts = readParts(model, config)
  if type(parts) ~= 'table' then return nil end
  local reason, scan = scanParts(parts, ruleSet, parkedPool)
  if reason then return reason end
  return engineAndWheelRejection(scan, ruleSet, parkedPool, power)
end

-- The first rejection reason for a config, or nil when it is eligible.
local function rejectionReason(model, config, pools)
  local ruleSet = getRules()
  local info = getConfigInfo(model, config)
  local configType = info and (info['Config Type'] or info.configType) or nil
  local power = info and tonumber(info.Power or info.power) or nil
  if not pools.police then
    local reserved, reservedReason = isReservedTrafficConfig(model, config, ruleSet)
    if reserved then return reservedReason end
  end
  local typeReason = configTypeRejection(configType, ruleSet)
  if typeReason then return typeReason end
  local powerReason = powerRejection(power, ruleSet, pools.parked)
  if powerReason then return powerReason end
  return partsRejection(model, config, ruleSet, pools.parked, power)
end

local function poolSuffix(pools)
  if pools.parked then return '|parked' end
  if pools.police then return '|police' end
  return '|traffic'
end

-- Returns ok, reason. Cached per model, config and pool.
local function isConfigEligible(model, config, params)
  local pools = {police = isPoliceSpawnIntent(params), parked = isParkedSpawnIntent(params)}
  local key = cacheKey(model, config) .. poolSuffix(pools)
  local hit = cache[key]
  if hit ~= nil then return hit.ok, hit.reason end
  local reason = rejectionReason(model, config, pools)
  cache[key] = {ok = reason == nil, reason = reason}
  return reason == nil, reason
end

-- createGroup -------------------------------------------------------------------------------------

-- Stock createGroup closes over its data reader, so filter an oversampled group rather than wrapping that export.
local function entryIdentity(entry)
  local model = entry and entry.model
  local config = entry and entry.config
  return model, config, tostring(model) .. '/' .. tostring(config)
end

-- Appends eligible entries from one batch, stopping once the group holds `want` entries.
local function appendEligible(out, seen, batch, params, want)
  for _, entry in ipairs(batch) do
    local model, config, key = entryIdentity(entry)
    if not seen[key] and isConfigEligible(model, config, params) then
      seen[key] = true
      out[#out + 1] = entry
      if #out >= want then return end
    end
  end
end

-- When every candidate was filtered out, keep non-reserved entries from the last batch (police pools keep all).
local function appendFallback(out, seen, batch, params, want, policePool)
  local ruleSet = getRules()
  for _, entry in ipairs(batch) do
    local model, config, key = entryIdentity(entry)
    if not seen[key] then
      local allow = policePool
      if not allow then allow = not isReservedTrafficConfig(model, config, ruleSet) end
      if allow and isConfigEligible(model, config, params) then
        seen[key] = true
        out[#out + 1] = entry
        if #out >= want then return end
      end
    end
  end
end

local CREATE_GROUP_ATTEMPTS = 4

local function filteredCreateGroup(originalCreateGroup)
  return function(amount, params)
    amount = amount or 10
    local want = math.max(1, amount)
    params = applyTrafficConfigTypeWeights(params)
    local policePool = isPoliceSpawnIntent(params)
    local out, seen = {}, {}
    local lastBatch = nil
    for _ = 1, CREATE_GROUP_ATTEMPTS do
      if #out >= want then break end
      local batch = originalCreateGroup(math.max(want * 3, want), params) or {}
      if #batch > 0 then lastBatch = batch end
      appendEligible(out, seen, batch, params, want)
    end
    if #out == 0 and lastBatch and #lastBatch > 0 then
      appendFallback(out, seen, lastBatch, params, want, policePool)
      if #out == 0 then
        log('W', logTag, 'Traffic filter removed all candidates; returning empty group')
      end
    end
    if #out < want then
      log('W', logTag, string.format('Traffic group short after filter: want %d, got %d', want, #out))
    end
    return out
  end
end

local function wrapCreateGroup(original)
  if type(original) == 'function' then return filteredCreateGroup(original) end
end

-- Game hooks --------------------------------------------------------------------------------------

local function onExtensionUnloaded()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

local function onExtensionLoaded()
  loadRules()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return rawget(_G, 'core_multiSpawn') end, {
    createGroup = wrapCreateGroup,
  })
end

local function onModActivated()
  table.clear(cache)
  loadRules()
end

local function onFileChanged(filename)
  if type(filename) == 'string' and filename:find('trafficConfigPartRules', 1, true) then
    loadRules()
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onModActivated = onModActivated
M.onFileChanged = onFileChanged

M.isConfigEligible = isConfigEligible
M.reloadRules = loadRules
M.getRules = getRules

return M
