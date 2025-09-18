-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local logTag = "drift"
local freeroamScoresFileName = "driftSpotsScores.json"

local spotsById = nil

local savePathFreeroam = 'settings/cloud/driftSpots/'

local function saveSpot(spot, dir)
  jsonWriteFile(dir .. spot.id ..".json", spot.saveData, true)
  log("I","","Saved Drift Score for " .. spot.id .. " to " .. dir)
  spot._dirty = false
end

local function saveDriftSpotsScoresForSpotById(spotId)
  local spot = M.getDriftSpotById(spotId)
  spot._dirty = true
end


local function getDriftSpotById(spotId)
  return M.getDriftSpotsById()[spotId]
end


local function getDriftSpotsById()
  if not spotsById then
    local saveFolder = savePathFreeroam
    if career_career.isActive() then
      return
    end
    local loaded = 0
    spotsById = {}
    local level = getCurrentLevelIdentifier()
    local levelSpotsDir = "/levels/"..level .. "/driftSpots/"
    --dump(levelSpotsDir)
    for _, file in ipairs(FS:findFiles(levelSpotsDir, "spot.driftSpot.json", -1, false, true)) do
      local dir, _, _ = path.split(file)
      local spotId = level .."/".. string.sub(dir, #levelSpotsDir+1, -2)
      -- main data

      local spotData = {
        id = spotId,
        spatialInfo = jsonReadFile(file).spatialInfo,
        racePath = dir.."race.race.json",
        bounds = dir.."bounds.sites.json",
        level = level,
      }

      -- infos for ui etc
      local info = jsonReadFile(dir .. "info.json") or {}
      info.preview = M.getPreviewWithFallback(dir)
      info.name = info.name or "Unnamed Drift Spot"
      spotData.info = info

      -- immediately hide the objects found
      for id, line in pairs(spotData.spatialInfo.lines) do
        for _, name in ipairs(line.markerObjects or {}) do
          local obj = scenetree.findObject(name)
          if obj then
            obj:setHidden(true)
            --log("I","","Hidden: " .. name)
          else
            log("W","","Couldnt find: " .. name .. " for drift zone: " ..spotId)
          end
        end
      end

      -- save data
      local saveData = jsonReadFile(saveFolder .. spotId .. ".json") or {}
      if next(saveData) then loaded = loaded + 1 end
      saveData.scores = saveData.scores or {}
      saveData.objectivesCompleted = saveData.objectivesCompleted or {}
      spotData.saveData = saveData

      table.sort(saveData.scores, function(a, b) return a.score > b.score end)

      spotData.unlocked = true

      spotsById[spotId] = spotData
      --dumpz(spotData)
    end
      --dump(tableKeysSorted(spotsById))
    --log("I","","Loaded " .. #tableKeys(spotsById) .. " drift spots and " .. loaded .. " drift score files.")
  end
  return spotsById
end

local noPreviewFilepath = "/ui/modules/gameContext/noPreview.jpg"
local previewFilenames = {"/preview.jpg","/preview.png","/preview.jpeg"}
local function getPreviewWithFallback(dir)
  -- check in mission Dir
  local found = false
  for _, fn in ipairs(previewFilenames) do
    local f = dir..fn
    if FS:fileExists(f) then
      return f
    end
  end
  return noPreviewFilepath
end


local function loadAndSanitizeDriftFreeroamSpotsCurrMap()
  if career_career.isActive() then
    return
  end
  local spotsForLevel = {}
  for _, spot in pairs(getDriftSpotsById()) do
    if spot.level == getCurrentLevelIdentifier() then
      table.insert(spotsForLevel, spot)
    end
  end
  return spotsForLevel
end

local function loadDriftData(fileName)
  if not fileName then
    return
  end
  local json = jsonReadFile(fileName)
  if not json then
    log('E', logTag, 'unable to find driftData file: ' .. tostring(fileName))
    return
  end

  -- "cast" scl, pos and rot to vec/quat
  for _, elem in ipairs(json.stuntZones or {}) do
    if elem.pos and type(elem.pos) == "table" and elem.pos.x and elem.pos.y and elem.pos.z then elem.pos = vec3(elem.pos) end
    if elem.rot and type(elem.rot) == "table" and elem.rot.x and elem.rot.y and elem.rot.z and elem.rot.w then elem.rot = quat(elem.rot) end
    if elem.scl and type(elem.scl) == "table" and elem.scl.x and elem.scl.y and elem.scl.z then elem.scl = vec3(elem.scl) end
    if elem.scl and type(elem.scl) == "number" then end
  end

  gameplay_drift_stuntZones.setStuntZones(json.stuntZones)
end

M.loadDriftData = loadDriftData
M.loadAndSanitizeDriftFreeroamSpotsCurrMap = loadAndSanitizeDriftFreeroamSpotsCurrMap

M.saveDriftSpotsScoresForSpotById = saveDriftSpotsScoresForSpotById

M.getDriftSpotById = getDriftSpotById
M.getDriftSpotsById = getDriftSpotsById
M.getPreviewWithFallback = getPreviewWithFallback

return M