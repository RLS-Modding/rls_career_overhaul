-- Shared per-level metadata, placement and versioned location migration rules.
-- Catalogs follow VFS refreshes; per-level metadata and city parking scopes remain independent.
local M = {}

local context = require('overhaul/lib/career/context')
local catalog = require('overhaul/lib/platform/jsonCatalog')

-- Config ------------------------------------------------------------------------------------------

local MAP_ROOT = '/gameplay/overhaul/maps/'
local ALIAS_ROOT = '/gameplay/overhaul/save/locationAliases/'
local mapCatalog
local aliasCatalog

-- Catalog discovery -------------------------------------------------------------------------------

function M.invalidateCatalogs()
  mapCatalog, aliasCatalog = nil, nil
end

function M.assetPath(levelId, value)
  if type(value) ~= 'string' or value == '' then return nil end
  if value:sub(1, 1) == '/' then return value end
  return '/levels/' .. levelId .. '/' .. value
end

local function validateMap(data)
  if data.version ~= 1 then return nil, 'unsupported map version' end
  if type(data.label) ~= 'string' or data.label == '' then return nil, 'missing label' end
  for _, key in ipairs({'careerCompatible', 'defaultStart', 'builtIn'}) do
    if data[key] ~= nil and type(data[key]) ~= 'boolean' then return nil, key .. ' must be boolean' end
  end
  for _, key in ipairs({'preview', 'travelPreview', 'negotiationPersonalities'}) do
    if data[key] ~= nil and type(data[key]) ~= 'string' then return nil, key .. ' must be a path' end
  end
  if data.startPreviews ~= nil then
    if type(data.startPreviews) ~= 'table' then return nil, 'startPreviews must be an object' end
    for _, preview in pairs(data.startPreviews) do
      if type(preview) ~= 'string' then return nil, 'start preview must be a path' end
    end
  end
  if data.optionalFeatures ~= nil then
    if type(data.optionalFeatures) ~= 'table' then return nil, 'optionalFeatures must be an object' end
    for _, feature in pairs(data.optionalFeatures) do
      if type(feature) ~= 'table' or not catalog.validId(feature.provider)
        or (feature.config ~= nil and type(feature.config) ~= 'string') then
        return nil, 'optional feature requires provider'
      end
    end
  end
  return data
end

function M.loadMaps()
  if mapCatalog then return unpack(mapCatalog) end
  local entries, rejected = catalog.scan(MAP_ROOT, validateMap, 'levelData')
  local byId = {}
  for _, entry in ipairs(entries) do byId[entry.id] = entry end
  mapCatalog = {byId, entries, rejected}
  return byId, entries, rejected
end

function M.getMap(levelId)
  return M.loadMaps()[levelId or M.currentMapKey()]
end

function M.defaultMap()
  local _, entries = M.loadMaps()
  local selected
  for _, entry in ipairs(entries) do
    if entry.defaultStart and entry.careerCompatible and core_levels.getLevelByName(entry.id) then
      if selected then
        log('E', 'levelData', 'Multiple default career maps; choose one in map metadata')
        return nil
      end
      selected = entry.id
    end
  end
  return selected
end

-- Start data and scene placement --------------------------------------------------------------------

local function validSpawn(definition)
  if type(definition) ~= 'table' then return false end
  if type(definition.sitesFile) == 'string' and type(definition.parkingSpotName) == 'string' then return true end
  if type(definition.sceneObject) == 'string' and definition.sceneObject ~= '' then return true end
  if type(definition.pos) ~= 'table' or type(definition.rot) ~= 'table' then return false end
  if #definition.pos ~= 3 or #definition.rot ~= 4 then return false end
  for _, value in ipairs(definition.pos) do if not catalog.finite(value) then return false end end
  for _, value in ipairs(definition.rot) do if not catalog.finite(value) then return false end end
  return true
end

local function validStart(data)
  if type(data) ~= 'table' or data.version ~= 1 then return false end
  for _, role in ipairs({'recoverySpawn', 'initialSpawn'}) do
    if data[role] ~= nil and not validSpawn(data[role]) then return false end
  end
  if data.modes ~= nil then
    if type(data.modes) ~= 'table' then return false end
    for _, mode in pairs(data.modes) do
      if type(mode) ~= 'table' then return false end
      for _, flag in ipairs({'enabled', 'locked'}) do
        if mode[flag] ~= nil and type(mode[flag]) ~= 'boolean' then return false end
      end
      for _, role in ipairs({'playerSpawn', 'vehicleSpawn'}) do
        if mode[role] ~= nil and not validSpawn(mode[role]) then return false end
      end
    end
  end
  return true
end

function M.loadStart(levelId)
  levelId = levelId or M.currentMapKey()
  if not levelId then return nil end
  local file = '/levels/' .. levelId .. '/overhaul/start.json'
  local data = jsonReadFile(file)
  if not data then return nil end
  if not validStart(data) then
    log('W', 'levelData', 'Ignoring invalid start metadata: ' .. file)
    return nil
  end
  return data
end

-- A spawn can name a local sites parking spot, a declared scene object, or an authored transform.
function M.resolveSpawn(definition, levelId)
  levelId = levelId or M.currentMapKey()
  if not levelId then return nil end
  if not validSpawn(definition) then
    log('W', 'levelData', 'No valid configured spawn on ' .. levelId)
    return nil
  end
  if definition.sitesFile and definition.parkingSpotName then
    local sites = context.sitesManager().loadSites(M.assetPath(levelId, definition.sitesFile), true, true)
    local spots = sites and sites.parkingSpots and sites.parkingSpots.byName
    local spot = spots and spots[definition.parkingSpotName]
    if spot and spot.pos and spot.rot and not spot.missing then return {pos = spot.pos, rot = spot.rot, spot = spot} end
  elseif definition.sceneObject then
    local object = scenetree.findObject(definition.sceneObject)
    if object then return {pos = object:getPosition(), rot = quat(object:getRotation())} end
  elseif definition.pos and definition.rot then
    return {pos = vec3(definition.pos), rot = quat(definition.rot)}
  end
  log('W', 'levelData', 'Configured spawn unavailable on ' .. levelId)
  return nil
end

function M.startSpawn(role, levelId)
  local data = M.loadStart(levelId)
  return data and data[role] and M.resolveSpawn(data[role], levelId) or nil
end

function M.startPolicy(levelId, modeId)
  local data = M.loadStart(levelId)
  local mode = data and data.modes and data.modes[modeId]
  local available = modeId ~= 'hardcore' or (mode and mode.enabled ~= false
    and mode.playerSpawn ~= nil and mode.vehicleSpawn ~= nil) or false
  return {available = available, locked = mode and mode.locked == true or false}
end

-- The loaded scene owns map travel; destination objects cannot be resolved before the level loads.
function M.findSceneObject(name, className)
  if not scenetree then return nil end
  local object = scenetree.findObject(name)
  if object and (not className or not object.getClassName or object:getClassName() == className) then return object end
  if not scenetree.findClassObjects then return nil end
  for _, candidateName in ipairs(scenetree.findClassObjects(className or 'SpawnSphere') or {}) do
    local candidate = scenetree.findObject(candidateName)
    local actualName = candidate and candidate.getName and candidate:getName() or candidateName
    if tostring(actualName):lower() == name:lower() then return candidate end
  end
end

local function sceneSpawn(object)
  if not object then return nil end
  return {pos = object:getPosition(), rot = quat(object:getRotation())}
end

function M.travelTrigger(levelName)
  if levelName and levelName ~= M.currentMapKey() then return nil end
  return M.findSceneObject('switchMaps', 'BeamNGTrigger')
end

function M.arrivalSpawn(levelName)
  if levelName and levelName ~= M.currentMapKey() then return nil end
  return sceneSpawn(M.findSceneObject('Level Gate')) or sceneSpawn(M.travelTrigger(levelName))
end

function M.recoverySpawn(levelName)
  if levelName and levelName ~= M.currentMapKey() then return nil end
  local arrival = M.arrivalSpawn(levelName) or M.startSpawn('recoverySpawn', levelName)
  if arrival then return arrival end
  if not spawn or not spawn.pickSpawnPoint then return nil end
  local ok, object = pcall(spawn.pickSpawnPoint, 'player')
  return ok and sceneSpawn(object) or nil
end

-- Versioned alias policies -------------------------------------------------------------------------

local function validateAliases(data)
  if data.version ~= 1 or type(data.aliases) ~= 'table' then return nil, 'requires version 1 and aliases array' end
  for _, alias in ipairs(data.aliases) do
    if type(alias) ~= 'table' or not catalog.validId(alias.kind)
      or type(alias.from) ~= 'string' or type(alias.to) ~= 'string' then
      return nil, 'alias requires kind/from/to'
    end
    if alias.kind == 'map' and (not catalog.validId(alias.from) or not catalog.validId(alias.to)) then
      return nil, 'map aliases require safe level ids'
    end
    if alias.maxSaveVersion ~= nil and (not catalog.finite(alias.maxSaveVersion)
      or alias.maxSaveVersion < 0 or alias.maxSaveVersion % 1 ~= 0) then
      return nil, 'maxSaveVersion must be a nonnegative integer'
    end
    for _, key in ipairs({'rewriteLevelPaths', 'rewriteMapSaveFiles', 'onlyIfTargetFileExists'}) do
      if alias[key] ~= nil and type(alias[key]) ~= 'boolean' then return nil, key .. ' must be boolean' end
    end
    for _, key in ipairs({'levelId', 'facilityId'}) do
      if alias[key] ~= nil and type(alias[key]) ~= 'string' then return nil, key .. ' must be a string' end
    end
  end
  return data
end

local function rejectChainedMapAliases(aliases)
  local sources, targets = {}, {}
  for _, alias in ipairs(aliases) do
    if alias.kind == 'map' then sources[alias.from], targets[alias.to] = true, true end
  end
  local accepted = {}
  for _, alias in ipairs(aliases) do
    if alias.kind == 'map' and (sources[alias.to] or targets[alias.from]) then
      log('W', 'levelData', 'Ignoring chained map alias: ' .. alias.from .. ' -> ' .. alias.to
        .. '; author each alias directly to its final map')
    else
      accepted[#accepted + 1] = alias
    end
  end
  return accepted
end

function M.loadAliases(kind)
  if not aliasCatalog then
    local fragments = catalog.scan(ALIAS_ROOT, validateAliases, 'levelData')
    aliasCatalog = {}
    for _, fragment in ipairs(fragments) do
      for _, alias in ipairs(fragment.aliases) do aliasCatalog[#aliasCatalog + 1] = alias end
    end
    aliasCatalog = rejectChainedMapAliases(aliasCatalog)
  end
  local aliases = {}
  for _, alias in ipairs(aliasCatalog) do
    if not kind or alias.kind == kind then aliases[#aliases + 1] = alias end
  end
  return aliases
end

local function matchesAliasScope(alias, scope)
  return (not alias.levelId or alias.levelId == scope.levelId)
    and (not alias.facilityId or alias.facilityId == scope.facilityId)
    and (not alias.maxSaveVersion or (catalog.finite(scope.saveVersion) and scope.saveVersion >= 0
      and scope.saveVersion % 1 == 0 and scope.saveVersion <= alias.maxSaveVersion))
end

-- Scoped aliases never apply without matching map/facility/save-version evidence.
function M.resolveAlias(kind, value, scope)
  scope = type(scope) == 'table' and scope or {}
  for _, alias in ipairs(M.loadAliases(kind)) do
    if alias.from == value and matchesAliasScope(alias, scope) then
      return alias.to, alias
    end
  end
  return value
end

-- Save payload transforms -------------------------------------------------------------------------

local function sortedKeys(value)
  local keys = {}
  for key in pairs(value) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

-- Keep this snapshot for a whole slot, including its original version before layout migration.
function M.mapAliases(scope)
  scope = type(scope) == 'table' and scope or {}
  local result = {}
  for _, alias in ipairs(M.loadAliases('map')) do
    if matchesAliasScope(alias, scope) then
      result[#result + 1] = alias
    end
  end
  return result
end

function M.mapAliasKey(alias)
  local result = {}
  for _, field in ipairs({'kind', 'from', 'to', 'levelId', 'facilityId', 'maxSaveVersion',
    'rewriteLevelPaths', 'rewriteMapSaveFiles', 'onlyIfTargetFileExists'}) do
    result[#result + 1] = field .. '=' .. serialize(alias[field])
  end
  return table.concat(result, ';')
end

function M.renameMapString(value, scope, aliases)
  for _, alias in ipairs(aliases or M.mapAliases(scope)) do
    if value == alias.from then return alias.to end
    if alias.rewriteLevelPaths then
      local forward = value:gsub('\\', '/')
      local slash = forward:sub(1, 1) == '/' and '/' or ''
      local prefix = slash .. 'levels/' .. alias.from .. '/'
      if forward:sub(1, #prefix) == prefix then
        local rel = forward:sub(#prefix + 1)
        local target = '/levels/' .. alias.to .. '/' .. rel
        if not alias.onlyIfTargetFileExists or FS:fileExists(target) then
          return slash .. target:sub(2)
        end
      end
    end
  end
  return value
end

function M.renameMapFile(value, scope, aliases)
  local dir, basename = value:match('^(.-)([^/]+)%.json$')
  if not basename then return value end
  for _, alias in ipairs(aliases or M.mapAliases(scope)) do
    if alias.rewriteMapSaveFiles and basename == alias.from then return dir .. alias.to .. '.json' end
  end
  return value
end

local function equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= 'table' then return left == right end
  for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

-- Renaming two keys may combine disjoint history, but never discard a conflicting value.
local function merge(left, right, location)
  if equal(left, right) then return left end
  assert(type(left) == 'table' and type(right) == 'table', 'Map alias collision at ' .. location)
  for key, value in pairs(right) do
    if left[key] == nil then left[key] = value else left[key] = merge(left[key], value, location .. '/' .. tostring(key)) end
  end
  return left
end

-- Produces a separate table so a collision leaves the source save untouched.
function M.renameMapData(data, scope, aliases, location)
  aliases = aliases or M.mapAliases(scope)
  location = location or 'save'
  local result, changed = {}, false
  for _, key in ipairs(sortedKeys(data)) do
    local newKey = type(key) == 'string' and M.renameMapString(key, scope, aliases) or key
    local value = data[key]
    if type(value) == 'table' then
      local hit
      value, hit = M.renameMapData(value, scope, aliases, location .. '/' .. tostring(key))
      changed = changed or hit
    elseif type(value) == 'string' then
      local renamed = M.renameMapString(value, scope, aliases)
      changed = changed or renamed ~= value
      value = renamed
    end
    changed = changed or newKey ~= key
    if result[newKey] ~= nil then result[newKey] = merge(result[newKey], value, location)
    else result[newKey] = value end
  end
  return result, changed
end


-- Independent city parking caches -----------------------------------------------------------------

function M.currentMapKey()
  return getCurrentLevelIdentifier()
end

-- Force a read so edits to the sites file are visible immediately.
function M.loadCityParkingSpots()
  local sitePath = context.sitesManager().getCurrentLevelSitesFileByName('city')
  if sitePath then
    local siteData = context.sitesManager().loadSites(sitePath, true, true)
    return true, siteData and siteData.parkingSpots
  end
  return false
end

-- Keep each caller's cache independent while retaining one map-key read per request.
function M.newMapScope()
  local scope = {}
  local cache = { parkingSpots = nil, mapKey = nil }
  function scope.get()
    local map = M.currentMapKey()
    if cache.parkingSpots and cache.mapKey ~= map then
      cache.parkingSpots = nil
    end
    if not cache.parkingSpots then
      cache.mapKey = map
      local found, loaded = M.loadCityParkingSpots()
      if found then
        cache.parkingSpots = loaded
      end
    end
    return cache.parkingSpots
  end
  function scope.reset()
    cache.parkingSpots = nil
    cache.mapKey = nil
  end
  return scope
end

return M
