-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/gameplay/crawl/saveSystem.lua (BeamNG 0.40).

local M = {}
M.dependencies = {"overhaul_shell_patches"}
-- SaveStore keys over the files this module writes today (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "events.crawlTrails", owner = "overhaul_integration_services_crawlScores", files = {"career/crawlTrails/*.json"}, phase = "profile", required = true},
})

local logTag = "crawl_save_system"
-- reserved for future use
-- local savePathFreeroam = '/gameplay/crawls/'
-- local savePathCareer = '/career/crawls/'

-- Cache for lazy loading
local cache = {
  trails = {},
  boundaries = {},
  paths = {},
  startingPositions = {}
}

local function getCurrentLevelCrawlPath()
  local levelName = getCurrentLevelIdentifier()
  if not levelName then
    log('E', logTag, 'Could not determine current level')
    return nil
  end
  return '/levels/' .. levelName .. '/crawls/'
end
M.getCurrentLevelCrawlPath = getCurrentLevelCrawlPath

local function extractLevelFromPath(filepath)
  local levelName = string.match(filepath, "/levels/([^/]+)/")
  if levelName then
    return levelName
  end
  return nil
end

local function deriveCrawlPathFromFile(filepath)
  local levelName = extractLevelFromPath(filepath)
  if levelName then
    return '/levels/' .. levelName .. '/crawls/'
  end
  return nil
end

-- Helper function to extract type from file path
local function getTypeFromPath(filePath)
  if string.match(filePath, "%.trail%.json$") then
    return "trail"
  elseif string.match(filePath, "%.boundary%.json$") then
    return "boundary"
  elseif string.match(filePath, "%.path%.json$") then
    return "path"
  elseif string.match(filePath, "%.startingPosition%.json$") then
    return "startingPosition"
  end
  return nil
end

-- Helper function to validate file path format
local function isValidPath(filePath)
  local type = getTypeFromPath(filePath)
  return type ~= nil
end

-- Clear cache for a specific type or all
local function clearCache(type)
  if type then
    cache[type] = {}
  else
    cache = {trails = {}, boundaries = {}, paths = {}, startingPositions = {}}
  end
end
M.clearCache = clearCache



-- Accept stock arrays, keyed JSON vectors and live engine geometry, without inventing coordinates.
local function geometryArray(value, size)
  local kind = type(value)
  if kind ~= "table" and kind ~= "cdata" and kind ~= "userdata" then return nil end
  if value.toTable then value = value:toTable() end
  local keys = {"x", "y", "z", "w"}
  local out = {}
  for i = 1, size do
    local component = value[i]
    if component == nil then component = value[keys[i]] end
    if type(component) ~= "number" or component ~= component or math.abs(component) == math.huge then return nil end
    out[i] = component
  end
  return out
end

local function pathGeometry(nodes)
  if type(nodes) ~= "table" or #nodes == 0 then
    log('E', logTag, 'Crawl path unavailable: no nodes')
    return nil
  end
  local out = {}
  for i, node in ipairs(nodes) do
    local position = type(node) == "table" and geometryArray(node.pos or node.position, 3)
    local rotation = type(node) == "table" and node.rotation ~= nil and geometryArray(node.rotation, 4) or nil
    if not position or (node.rotation ~= nil and not rotation) then
      log('E', logTag, 'Crawl path unavailable: missing or nonfinite geometry at node ' .. i)
      return nil
    end
    out[i] = {
      name = node.name or ("Node " .. i), position = position, rotation = rotation,
      radius = node.radius or 4.0, flags = node.flags or {},
    }
  end
  return out
end

local function startingGeometry(data)
  local tf = type(data.transform) == "table" and data.transform or {}
  local position = geometryArray(tf.position, 3)
  local rotation = geometryArray(tf.rotation, 4)
  local icon = position
  if data.iconPosition ~= nil then icon = geometryArray(data.iconPosition, 3) end
  if not position or not rotation or not icon then
    log('E', logTag, 'Crawl start unavailable: missing or nonfinite position, rotation or iconPosition')
    return nil
  end
  return position, rotation, icon
end

-- Serialization functions
local function serializeTrail(trail)
  if not trail then
    log('E', logTag, 'No trail to serialize')
    return nil
  end

  local serializedTrail = {
    name = trail.name or "Unnamed Trail",
    description = trail.description or "",
    pathId = trail.pathId or "",
    boundaryId = trail.boundaryId or "",
    startingPositionId = trail.startingPositionId or "",
    startingPositionIdReversed = trail.startingPositionIdReversed or "",
    pathReversed = trail.pathReversed or false,
    thumbnail = trail.thumbnail or "",
    preview = trail.preview or "",
    rules = trail.rules or {
      isPointsBased = false,
      isTimed = false
    },
    prefabs = trail.prefabs or {},
    metadata = trail.metadata or {
      created = os.date(),
      modified = os.date()
    },
    isFromMission = trail.isFromMission or false
  }


  return serializedTrail
end

local function serializeBoundary(boundary)
  if not boundary then
    log('E', logTag, 'No boundary to serialize')
    return nil
  end

  local serializedData = boundary:onSerialize()
  if not serializedData then
    log('E', logTag, 'Failed to serialize boundary')
    return nil
  end

  return serializedData
end

local function serializePath(path)
  if type(path) ~= "table" then
    log('E', logTag, 'No path to serialize')
    return nil
  end

  local nodes = pathGeometry(path.nodes)
  if not nodes then return nil end
  return {name = path.name or "Unnamed Path", description = path.description or "", nodes = nodes}
end

local function serializeStartingPosition(startingPosition)
  if type(startingPosition) ~= "table" then
    log('E', logTag, 'No starting position to serialize')
    return nil
  end

  local position, rotation, icon = startingGeometry(startingPosition)
  if not position then return nil end

  local serializedData = {
    name = startingPosition.name or "Unnamed Starting Position",
    description = startingPosition.description or "",
    transform = {
      position = position,
      rotation = rotation,
      radius = startingPosition.transform and startingPosition.transform.radius or 10.0
    },
    iconPosition = icon,
    metadata = startingPosition.metadata or {
      created = os.date(),
      modified = os.date()
    }
  }

  return serializedData
end

-- Deserialization functions
local function deserializeTrail(data)
  if not data then
    log('E', logTag, 'No trail data to deserialize')
    return nil
  end
  local trail = {}

  trail.name = data.name or "Unnamed Trail"
  trail.description = data.description or ""

  trail.rules = data.rules or {
    isPointsBased = false,
    isTimed = false
  }
  trail.prefabs = data.prefabs or {}

  trail.metadata = data.metadata or {
    created = os.date(),
    modified = os.date()
  }

  trail.pathId = data.pathId or ""
  trail.boundaryId = data.boundaryId or ""
  trail.startingPositionId = data.startingPositionId or ""
  trail.startingPositionIdReversed = data.startingPositionIdReversed or ""
  trail.pathReversed = data.pathReversed or false
  trail.thumbnail = data.thumbnail or ""
  trail.preview = data.preview or ""

  -- Mission-specific fields
  trail.isFromMission = data.isFromMission or false

  return trail
end

local function deserializeBoundary(data)
  if not data then
    log('E', logTag, 'No boundary data to deserialize')
    return nil
  end

  local boundary = require('/lua/ge/extensions/gameplay/sites/zone')(nil, data.name or "Boundary")
  boundary:onDeserialized(data)
  boundary.id = data.id
  return boundary
end

local function deserializePath(data)
  if type(data) ~= "table" then
    log('E', logTag, 'No path data to deserialize')
    return nil
  end

  local path = {
    name = data.name or "Path",
    description = data.description or "",
    nodes = {}
  }

  local nodes = pathGeometry(data.nodes)
  if not nodes then return nil end
  for _, node in ipairs(nodes) do
    node.pos = vec3(node.position)
    node.position = nil
    if node.rotation then node.rotation = quat(node.rotation) end
    table.insert(path.nodes, node)
  end

  path.id = data.id
  return path
end

local function deserializeStartingPosition(data)
  if type(data) ~= "table" then
    log('E', logTag, 'No starting position data to deserialize')
    return nil
  end

  local position, rotation, icon = startingGeometry(data)
  if not position then return nil end

  local startingPosition = {
    name = data.name or "Starting Position",
    description = data.description or "",
    transform = {
      position = vec3(position),
      rotation = quat(rotation),
      radius = data.transform and data.transform.radius or 10.0
    },
    iconPosition = vec3(icon),
    metadata = data.metadata or {
      created = os.date(),
      modified = os.date()
    }
  }

  startingPosition.id = data.id
  return startingPosition
end

-- Save functions for individual items
M.saveTrail = function(trail, filePath)
  if not trail then
    log('E', logTag, 'No trail to save')
    return false
  end

  if not filePath then
    log('E', logTag, 'No file path provided for trail')
    return false
  end

  local serializedData = serializeTrail(trail)
  if not serializedData then
    return false
  end

  local dir = string.match(filePath, "^(.*)/[^/]*$")
  if dir then
    FS:directoryCreate(dir)
  end

  local success = jsonWriteFile(filePath, serializedData, true)
  if success then
    -- Update cache
    if not cache.trails then
      cache.trails = {}
    end
    cache.trails[filePath] = trail
    return true
  else
    log('E', logTag, 'Failed to save trail to: ' .. filePath)
    return false
  end
end

M.saveBoundary = function(boundary, filePath)
  if not boundary then
    log('E', logTag, 'No boundary to save')
    return false
  end

  if not filePath then
    log('E', logTag, 'No file path provided for boundary')
    return false
  end

  local serializedData = serializeBoundary(boundary)
  if not serializedData then
    return false
  end

  local dir = string.match(filePath, "^(.*)/[^/]*$")
  if dir then
    FS:directoryCreate(dir)
  end

  local success = jsonWriteFile(filePath, serializedData, true)
  if success then
    -- Update cache
    if not cache.boundaries then
      cache.boundaries = {}
    end
    cache.boundaries[filePath] = boundary
    return true
  else
    log('E', logTag, 'Failed to save boundary to: ' .. filePath)
    return false
  end
end

M.savePath = function(path, filePath)
  if not path then
    log('E', logTag, 'No path to save')
    return false
  end

  if not filePath then
    log('E', logTag, 'No file path provided for path')
    return false
  end

  local serializedData = serializePath(path)
  if not serializedData then
    return false
  end

  local dir = string.match(filePath, "^(.*)/[^/]*$")
  if dir then
    FS:directoryCreate(dir)
  end

  local success = jsonWriteFile(filePath, serializedData, true)
  if success then
    -- Update cache
    if not cache.paths then
      cache.paths = {}
    end
    cache.paths[filePath] = path
    return true
  else
    log('E', logTag, 'Failed to save path to: ' .. filePath)
    return false
  end
end

M.saveStartingPosition = function(startingPosition, filePath)
  if not startingPosition then
    log('E', logTag, 'No starting position to save')
    return false
  end

  if not filePath then
    log('E', logTag, 'No file path provided for starting position')
    return false
  end

  local serializedData = serializeStartingPosition(startingPosition)
  if not serializedData then
    return false
  end

  local dir = string.match(filePath, "^(.*)/[^/]*$")
  if dir then
    FS:directoryCreate(dir)
  end

  local success = jsonWriteFile(filePath, serializedData, true)
  if success then
    -- Update cache
    if not cache.startingPositions then
      cache.startingPositions = {}
    end
    cache.startingPositions[filePath] = startingPosition
    return true
  else
    log('E', logTag, 'Failed to save starting position to: ' .. filePath)
    return false
  end
end

-- Load crawl data (main entry point)
M.loadCrawlData = function(filename)
  if not filename then
    log('E', logTag, 'No filename provided for loading')
    return nil
  end

  log('D', logTag, 'Attempting to load crawl data from: ' .. tostring(filename))

  local data = jsonReadFile(filename)
  if not data then
    log('E', logTag, 'Failed to read crawl data file: ' .. filename)
    return nil
  end

  local crawlData = {
    name = data.name,
    description = data.description or "",
    icon = data.icon or "rockCrawling01",
    metadata = data.metadata or {
      created = os.date(),
      modified = os.date(),
      description = "Crawl system data"
    },
    trails = {}
  }

  -- Load trails using the new getter system
  for i, trailId in ipairs(data.trails or {}) do
    local trail = M.getTrailById(trailId)
    if trail then
      table.insert(crawlData.trails, trail)
    else
      log('W', logTag, 'Failed to load trail: ' .. trailId)
    end
  end

  log('D', logTag, 'Loaded crawl data with ' .. #crawlData.trails .. ' trails')
  return crawlData
end

-- Save crawl data (main entry point)
M.saveCrawlData = function(saveData, filepath)
  if not saveData then
    log('E', logTag, 'No crawl data to save')
    return false
  end

  if not filepath then
    log('E', logTag, 'No filepath provided for saving')
    return false
  end

  -- Serialize crawl data (only metadata, not the actual items)
  local serializedData = {
    name = saveData.name,
    description = saveData.description,
    icon = saveData.icon,
    metadata = saveData.metadata,
    trails = {}
  }

  -- Add trail IDs (file paths)
  for _, trail in ipairs(saveData.trails or {}) do
    if trail.id then
      table.insert(serializedData.trails, trail.id)
    end
  end

  local success = jsonWriteFile(filepath, serializedData, true)
  if success then
    return true
  else
    log('E', logTag, 'Failed to save crawl data to: ' .. filepath)
    return false
  end
end


-- Generic loader with caching
local function loadFromFile(filePath, type)
  if not filePath or not isValidPath(filePath) then
    log('E', logTag, 'Invalid file path for ' .. (type or 'item') .. ': ' .. tostring(filePath))
    return nil
  end

  -- Check cache first
  if cache[type] and cache[type][filePath] then
    return cache[type][filePath]
  end

  -- Load from file
  local data = jsonReadFile(filePath)
  if not data then
    log('E', logTag, 'Failed to read ' .. type .. ' file: ' .. filePath)
    return nil
  end

  local item = nil
  if type == "trail" then
    item = deserializeTrail(data)
  elseif type == "boundary" then
    item = deserializeBoundary(data)
  elseif type == "path" then
    item = deserializePath(data)
  elseif type == "startingPosition" then
    item = deserializeStartingPosition(data)
  else
    log('E', logTag, 'Unknown type: ' .. tostring(type))
    return nil
  end

  if not item then
    log('E', logTag, 'Failed to deserialize ' .. type .. ' file: ' .. filePath)
    return nil
  end

  item._filePath = filePath
  local dir, fileName, ext = path.splitWithoutExt(filePath, true)
  item._fileName = fileName
  item._dir = dir
  item._ext = ext

  -- Cache the item
  if not cache[type] then
    cache[type] = {}
  end
  cache[type][filePath] = item

  return item
end

-- Getter functions with lazy loading
M.getTrailById = function(trailId)
  if not trailId then
    log('E', logTag, 'No trail ID provided')
    return nil
  end

  return loadFromFile(trailId, "trail")
end

M.getBoundaryById = function(boundaryId)
  if not boundaryId then
    log('E', logTag, 'No boundary ID provided')
    return nil
  end

  return loadFromFile(boundaryId, "boundary")
end

M.getPathById = function(pathId)
  if not pathId then
    log('E', logTag, 'No path ID provided')
    return nil
  end

  return loadFromFile(pathId, "path")
end

M.getStartingPositionById = function(startingPositionId, trail)
  -- Don't load starting positions for mission trails
  if trail and trail.isFromMission then
    return nil
  end

  if not startingPositionId or startingPositionId == "" then
    return nil
  end

  return loadFromFile(startingPositionId, "startingPosition")
end

-- Utility functions for listing files
local function listFiles(levelPath, type)
  local path = levelPath or getCurrentLevelCrawlPath()
  if not path then
    log('E', logTag, 'No path available for listing ' .. type .. ' files - no level loaded')
    return {}
  end

  local pattern = "*." .. type .. ".json"
  local files = FS:findFiles(path, pattern, 1, false, true)

  log('D', logTag, string.format('Found %d %s files in path: %s', #files, type, path))

  -- Convert to just the filenames if needed, or return full paths
  return files
end

M.getAllTrailFiles = function(levelPath)
  return listFiles(levelPath, "trail")
end

M.getAllBoundaryFiles = function(levelPath)
  return listFiles(levelPath, "boundary")
end

M.getAllPathFiles = function(levelPath)
  return listFiles(levelPath, "path")
end

M.getAllStartingPositionFiles = function(levelPath)
  return listFiles(levelPath, "startingPosition")
end

-- Getter functions for all objects
function M.getAllTrails(levelPath)
  local trailFiles = M.getAllTrailFiles(levelPath)
  local trails = {}
  for _, filePath in ipairs(trailFiles) do
    local trail = M.getTrailById(filePath)
    if trail then
      table.insert(trails, trail)
    end
  end
  return trails
end

function M.getAllBoundaries()
  local boundaryFiles = M.getAllBoundaryFiles()
  local boundaries = {}
  for _, filePath in ipairs(boundaryFiles) do
    local boundary = M.getBoundaryById(filePath)
    if boundary then
      table.insert(boundaries, boundary)
    end
  end
  return boundaries
end

function M.getAllPaths()
  local pathFiles = M.getAllPathFiles()
  local paths = {}
  for _, filePath in ipairs(pathFiles) do
    local path = M.getPathById(filePath)
    if path then
      table.insert(paths, path)
    end
  end
  return paths
end

function M.getAllStartingPositions()
  local startingPositionFiles = M.getAllStartingPositionFiles()
  local startingPositions = {}
  for _, filePath in ipairs(startingPositionFiles) do
    local startingPosition = M.getStartingPositionById(filePath)
    if startingPosition then
      table.insert(startingPositions, startingPosition)
    end
  end
  return startingPositions
end

-- Player save system for trail scores and times
local playerSavePathFreeroam = 'settings/cloud/overhaul/crawlTrails/'
local playerSavePathCareer = '/career/crawlTrails/'
local playerTrailsById = nil

local function ensurePlayerSaveDirectories()
  -- Ensure the crawl trails save directory exists
  if not FS:directoryExists(playerSavePathFreeroam) then
    FS:directoryCreate(playerSavePathFreeroam)
    log('D', logTag, 'Created crawl trails save directory: ' .. playerSavePathFreeroam)
  end
end

local function onOverhaulActive()
  M.clearCache()
  playerTrailsById = nil
end

local function savePlayerTrail(trail, dir)
  if not overhaul_career_saveSystem.jsonWriteFileSafe(dir .. trail.id ..".json", trail.saveData, true) then return false end
  log("I", logTag, "Saved Crawl Score for " .. trail.id .. " to " .. dir)
  trail._dirty = false
end

local function onOverhaulSaveCurrentProfile(currentSavePath)
  if not playerTrailsById then return end
  for id, trail in pairs(playerTrailsById) do
    if trail._dirty then
      savePlayerTrail(trail, currentSavePath .. playerSavePathCareer)
    end
  end
end

local function savePlayerCrawlTrailScoresForTrailById(trailId)
  local trail = M.getPlayerCrawlTrailById(trailId)
  if trail then
    trail._dirty = true
    if not overhaul_career_career.isActive() then
      savePlayerTrail(trail, playerSavePathFreeroam)
    end
  end
end

local function getPlayerCrawlTrailById(trailId)
  return M.getPlayerCrawlTrailsById()[trailId]
end

local function getPlayerCrawlTrailsById()
  if not playerTrailsById then
    local saveFolder = playerSavePathFreeroam
    if overhaul_career_career.isActive() then
      local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
      saveFolder = savePath .. playerSavePathCareer
    end

    local loaded = 0
    playerTrailsById = {}

    -- Get all trails from the save system
    local allTrails = M.getAllTrails()

    for _, trail in ipairs(allTrails or {}) do
      local trailId = trail._filePath or trail.id
      if trailId then
        -- Load save data for this trail
        local saveData = jsonReadFile(saveFolder .. trailId .. ".json") or {}

        -- Initialize default save data structure
        saveData.bestTime = saveData.bestTime or math.huge
        saveData.bestPenaltyPoints = saveData.bestPenaltyPoints or math.huge
        saveData.bestTimeDate = saveData.bestTimeDate or 0
        saveData.bestPenaltyPointsDate = saveData.bestPenaltyPointsDate or 0
        saveData.attempts = saveData.attempts or 0

        -- Create trail data structure
        local trailData = {
          id = trailId,
          trail = trail,
          saveData = saveData
        }

        playerTrailsById[trailId] = trailData

        if next(saveData) then
          loaded = loaded + 1
        end
      end
    end

    log("I", logTag, "Loaded " .. #tableKeys(playerTrailsById) .. " player crawl trails and " .. loaded .. " crawl score files.")
  end
  return playerTrailsById
end

local function addNewPlayerScore(trailId, time, penaltyPoints)
  local trail = M.getPlayerCrawlTrailById(trailId)
  if not trail then
    -- Mission trails may not be in player trail list, which is expected
    log("D", logTag, "Trail not found in player list (likely mission trail): " .. tostring(trailId))
    return
  end

  local saveData = trail.saveData
  local currentDate = os.time()
  local isNewBestTime = false
  local isNewBestPenaltyPoints = false

  -- Update best time if this is better (and time is valid)
  if time and time > 0 and time < saveData.bestTime then
    saveData.bestTime = time
    saveData.bestTimeDate = currentDate
    isNewBestTime = true
  end

  -- Update best penalty points if this is better (lower is better)
  if penaltyPoints and penaltyPoints >= 0 and penaltyPoints < saveData.bestPenaltyPoints then
    saveData.bestPenaltyPoints = penaltyPoints
    saveData.bestPenaltyPointsDate = currentDate
    isNewBestPenaltyPoints = true
  end

  -- Increment attempt counter
  saveData.attempts = saveData.attempts + 1

  -- Save the updated data
  savePlayerCrawlTrailScoresForTrailById(trailId)

  return {
    isNewBestTime = isNewBestTime,
    isNewBestPenaltyPoints = isNewBestPenaltyPoints,
    bestTime = saveData.bestTime,
    bestPenaltyPoints = saveData.bestPenaltyPoints
  }
end

local function resetPlayerTrailScores(trailId)
  local trail = M.getPlayerCrawlTrailById(trailId)
  if trail then
    trail.saveData.bestTime = math.huge
    trail.saveData.bestPenaltyPoints = math.huge
    trail.saveData.bestTimeDate = 0
    trail.saveData.bestPenaltyPointsDate = 0
    trail.saveData.attempts = 0
    savePlayerCrawlTrailScoresForTrailById(trailId)
  end
end

local function getPlayerTrailStats(trailId)
  local trail = M.getPlayerCrawlTrailById(trailId)
  if trail then
    return {
      bestTime = trail.saveData.bestTime,
      bestPenaltyPoints = trail.saveData.bestPenaltyPoints,
      attempts = trail.saveData.attempts
    }
  end
  return nil
end

-- Cleanup function
M.cleanup = function()
  clearCache()
  log('D', logTag, 'Save system cleanup completed')
end

-- Player save system exports
M.onOverhaulActive = onOverhaulActive
M.onOverhaulSetProfile = onOverhaulActive
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.savePlayerCrawlTrailScoresForTrailById = savePlayerCrawlTrailScoresForTrailById
M.getPlayerCrawlTrailById = getPlayerCrawlTrailById
M.getPlayerCrawlTrailsById = getPlayerCrawlTrailsById
M.addNewPlayerScore = addNewPlayerScore
M.resetPlayerTrailScores = resetPlayerTrailScores
M.getPlayerTrailStats = getPlayerTrailStats
M.ensurePlayerSaveDirectories = ensurePlayerSaveDirectories

-- Mission detection functions
M.isTrailFromMission = function(trail)
  return trail and trail.isFromMission == true
end

-- Keep geometry calls in the owned loader only during Overhaul; stock callers recover on stop.
local geometryPatchRegistered = false
function M.onExtensionLoaded()
  if geometryPatchRegistered then return end
  local wrappers = {}
  for _, name in ipairs({"getPathById", "getStartingPositionById", "savePath", "saveStartingPosition"}) do
    local method = name
    wrappers[method] = function()
      return function(...) return M[method](...) end
    end
  end
  local patches = overhaul_shell_patches
  patches.registerFields("stockCrawlGeometry", patches.onDemandExtension("gameplay_crawl_saveSystem"), wrappers)
  geometryPatchRegistered = true
end

function M.onExtensionUnloaded()
  if geometryPatchRegistered then
    overhaul_shell_patches.unregister("stockCrawlGeometry")
    geometryPatchRegistered = false
  end
  M.clearCache()
end

return M
