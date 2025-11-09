local M = {}

local isCollectingDataEnabled = false

local pendingDataEntries = {}

local utils = require('gameplay/events/freeroam/utils')

local races = nil

local function getModDataDirectory()
  return "/data/FREs"
end

local function ensureDirectoryExists(dirPath)
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function getRaces()
  if not races then
    races = utils.loadRaceData()
  end
  return races
end

local function getRaceNameFromLabel(raceLabel, isAltRoute, isHotlap)
  local races = getRaces()
  if not races then
    return nil
  end

  local baseLabel = raceLabel
  if isHotlap then
    baseLabel = baseLabel:gsub(" %(Hotlap%)$", "")
  end

  for raceName, race in pairs(races) do
    if isAltRoute and race.altRoute then
      if race.altRoute.label == baseLabel then
        return raceName
      end
    else
      if race.label == baseLabel then
        return raceName
      end
    end
  end

  return nil
end

local function getVehicleIdFromEntry(entry)
  local vehId = entry.inventoryId

  if career_career and career_career.isActive() and career_modules_inventory then
    local actualVehId = career_modules_inventory.getVehicleIdFromInventoryId(vehId)
    if actualVehId then
      vehId = actualVehId
    end
  end

  if not vehId then
    vehId = be:getPlayerVehicleID(0)
  end

  return vehId
end

local function onPowerToWeightCalculated(vehId, powerToWeight, raceName, time, isAltRoute)
  print(
    "onPowerToWeightCalculated: " .. tostring(vehId) .. " " .. tostring(powerToWeight) .. " " .. tostring(raceName) ..
      " " .. tostring(time))
  local key = tostring(vehId) .. "_" .. tostring(raceName) .. "_" .. tostring(time)
  local pendingEntry = pendingDataEntries[key]

  if not pendingEntry then
    return
  end

  if not powerToWeight or powerToWeight <= 0 then
    pendingDataEntries[key] = nil
    return
  end

  local dataDir = getModDataDirectory()
  ensureDirectoryExists(dataDir)

  local fileName = raceName
  if isAltRoute then
    fileName = raceName .. "_alt"
  end
  local filePath = dataDir .. "/" .. fileName .. ".json"
  local existingData = jsonReadFile(filePath)

  if not existingData or type(existingData) ~= "table" then
    existingData = {}
  end

  table.insert(existingData, {
    p2w = powerToWeight,
    time = time
  })

  jsonWriteFile(filePath, existingData, true)

  pendingDataEntries[key] = nil
end

local function collectPowerToWeight(entry)
  if not isCollectingDataEnabled then
    return
  end

  local vehId = getVehicleIdFromEntry(entry)
  if not vehId then
    return
  end

  local vehObj = getObjectByID(vehId)
  if not vehObj then
    vehObj = be:getPlayerVehicle(0)
  end

  if not vehObj then
    return
  end

  local raceLabel = entry.raceLabel
  local time = entry.time

  if not raceLabel or not time then
    return
  end

  local raceName = entry.raceName
  if not raceName then
    raceName = getRaceNameFromLabel(raceLabel, entry.isAltRoute, entry.isHotlap)
  end

  if not raceName then
    return
  end

  local key = vehId .. "_" .. raceName .. "_" .. tostring(time)
  pendingDataEntries[key] = {
    raceName = raceName,
    time = time,
    isAltRoute = entry.isAltRoute or false
  }

  print("collectPowerToWeight: " .. raceName .. " " .. time)

  vehObj:queueLuaCommand(string.format([[
            local engine = powertrain.getDevicesByCategory("engine")[1]
            if engine then
                local power = engine.maxPower
                local weight = obj:calcBeamStats().total_weight
                if power and weight and weight > 0 then
                    local powerToWeight = power / weight
                    obj:queueGameEngineLua("gameplay_events_freeroam_dataCollection.onPowerToWeightCalculated(%d, " .. powerToWeight .. ", ']] ..
                                         tostring(raceName) .. [[', ]] .. tostring(time) .. [[, ]] ..
                                         tostring(entry.isAltRoute or false) .. [[)")
                end
            end
        ]], vehId))
end

local function fitP2WModel(samples)
  -- require at least a few data points
  if not samples or #samples < 3 then
    return nil, "not_enough_samples"
  end

  local best = {
    err = math.huge,
    a = 0,
    b = 0,
    c = 0
  }

  -- search c in a reasonable range
  local cMin, cMax, cStep = 0.1, 1.5, 0.01

  for c = cMin, cMax, cStep do
    local n = 0
    local sumX, sumY, sumXX, sumXY = 0, 0, 0, 0

    for _, s in ipairs(samples) do
      local r = s.p2w
      local t = s.time
      if r and t and r > 0 then
        local x = 1 / (r ^ c)
        sumX = sumX + x
        sumY = sumY + t
        sumXX = sumXX + x * x
        sumXY = sumXY + x * t
        n = n + 1
      end
    end

    if n >= 3 then
      local denom = (n * sumXX - sumX * sumX)
      if denom ~= 0 then
        local b = (n * sumXY - sumX * sumY) / denom
        local a = (sumY - b * sumX) / n

        -- compute error
        local err = 0
        for _, s in ipairs(samples) do
          local r = s.p2w
          local t = s.time
          if r and t and r > 0 then
            local x = 1 / (r ^ c)
            local pred = a + b * x
            local diff = t - pred
            err = err + diff * diff
          end
        end

        if err < best.err and b > 0 then
          best.err = err
          best.a = a
          best.b = b
          best.c = c
        end
      end
    end
  end

  if best.err == math.huge then
    return nil, "fit_failed"
  end

  return {
    a = best.a,
    b = best.b,
    c = best.c,
    err = best.err
  }
end

local function analyzeData()
  local levelIdentifier = getCurrentLevelIdentifier()
  if not levelIdentifier then
    return false, "no_level"
  end

  local dataDir = getModDataDirectory()
  if not FS:directoryExists(dataDir) then
    return false, "no_data_directory"
  end

  local raceDataPath = "levels/" .. levelIdentifier .. "/race_data.json"
  local raceData = jsonReadFile(raceDataPath)
  if not raceData or not raceData.races then
    return false, "no_race_data"
  end

  local files = FS:findFiles(dataDir, "*.json", 0, false, false)
  if not files or #files == 0 then
    return false, "no_data_files"
  end

  local updated = false

  for _, filePath in ipairs(files) do
    local dir, filename, ext = path.split(filePath)
    local baseName = string.sub(filename, 1, -6)

    local raceName = baseName
    local isAltRoute = false

    if string.sub(baseName, -4) == "_alt" then
      raceName = string.sub(baseName, 1, -5)
      isAltRoute = true
    end

    if raceData.races[raceName] then
      local race = raceData.races[raceName]
      local samples = jsonReadFile(filePath)

      if samples and type(samples) == "table" and #samples > 0 then
        local coef, err = fitP2WModel(samples)
        if coef then
          if isAltRoute and race.altRoute then
            race.altRoute.predictCoef = {
              a = coef.a,
              b = coef.b,
              c = coef.c
            }
            updated = true
          elseif not isAltRoute then
            race.predictCoef = {
              a = coef.a,
              b = coef.b,
              c = coef.c
            }
            updated = true
          end
        end
      end
    end
  end

  if updated then
    jsonWriteFile(raceDataPath, raceData, true)
    return true
  end

  return false, "no_updates"
end

local function collectDataFromEntry(entry)
  if not entry then
    return
  end

  collectPowerToWeight(entry)
end

local function collectData(enabled)
  isCollectingDataEnabled = enabled or false
end

local function isCollectingData()
  return isCollectingDataEnabled
end

local function onWorldReadyState(state)
  if state == 2 then
    races = nil
  end
end

M.onPowerToWeightCalculated = onPowerToWeightCalculated
M.collectDataFromEntry = collectDataFromEntry
M.collectData = collectData
M.isCollectingData = isCollectingData
M.onWorldReadyState = onWorldReadyState
M.analyzeData = analyzeData

return M
