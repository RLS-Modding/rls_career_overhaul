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

  -- Check if this is a business vehicle identifier
  if vehId and type(vehId) == "string" and vehId:match("^business_") then
    -- Extract businessId and vehicleId from the identifier (format: "business_businessId_vehicleId")
    -- Find the last underscore position
    local lastUnderscorePos = 0
    for i = #vehId, 1, -1 do
      if vehId:sub(i, i) == "_" then
        lastUnderscorePos = i
        break
      end
    end
    
    if lastUnderscorePos > 9 then -- Must be after "business_"
      local businessId = vehId:sub(9, lastUnderscorePos - 1) -- Skip "business_" prefix
      local vehicleIdStr = vehId:sub(lastUnderscorePos + 1)
      local vehicleId = tonumber(vehicleIdStr)
      
      if businessId and vehicleId and career_modules_business_businessInventory then
        -- Get the actual spawned vehicle ID
        local spawnedVehId = career_modules_business_businessInventory.getSpawnedVehicleId(businessId, vehicleId)
        if spawnedVehId then
          vehId = spawnedVehId
        else
          -- Fall back to current player vehicle if business vehicle not spawned
          vehId = be:getPlayerVehicleID(0)
        end
      else
        -- Fall back to current player vehicle if we can't parse the identifier
        vehId = be:getPlayerVehicleID(0)
      end
    else
      -- Fall back to current player vehicle if we can't parse the identifier
      vehId = be:getPlayerVehicleID(0)
    end
  elseif career_career and career_career.isActive() and career_modules_inventory then
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

local function onVehicleRaceDataCollected(vehId, power, weight, year, raceName, time, isAltRoute)
  print(
    "onVehicleRaceDataCollected: " .. tostring(vehId) .. " power:" .. tostring(power) .. " weight:" .. tostring(weight) .. 
    " year:" .. tostring(year) .. " " .. tostring(raceName) .. " time:" .. tostring(time))
  local key = tostring(vehId) .. "_" .. tostring(raceName) .. "_" .. tostring(time)
  local pendingEntry = pendingDataEntries[key]

  if not pendingEntry then
    return
  end

  if not power or not weight or not year or not time or power <= 0 or weight <= 0 then
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
    power = power,
    weight = weight,
    year = year,
    time = time
  })

  jsonWriteFile(filePath, existingData, true)

  pendingDataEntries[key] = nil
end

local function onVehicleModelReceived(vehId, power, weight, model, raceName, time, isAltRoute)
  local year = 2000
  
  if model and core_vehicles and core_vehicles.getModel then
    local modelData = core_vehicles.getModel(model)
    if modelData and modelData.model then
      local years = modelData.model.Years
      if years then
        if type(years) == "table" and years.min and years.max then
          year = math.floor((years.min + years.max) / 2)
        elseif type(years) == "number" then
          year = years
        end
      elseif modelData.model.Year then
        year = modelData.model.Year
      end
    end
  end
  
  onVehicleRaceDataCollected(vehId, power, weight, year, raceName, time, isAltRoute)
end

local function collectVehicleRaceData(entry)
  if not isCollectingDataEnabled then
    return
  end

  local inventoryId = entry.inventoryId
  if not inventoryId then
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

  local key = tostring(vehId) .. "_" .. tostring(raceName) .. "_" .. tostring(time)
  pendingDataEntries[key] = {
    raceName = raceName,
    time = time,
    isAltRoute = entry.isAltRoute or false
  }

  print("collectVehicleRaceData: Querying vehicle for power/weight/year - " .. raceName .. " time:" .. time)

  local luaCommand = [[
            local engine = powertrain.getDevicesByCategory("engine")[1]
            if engine then
                local power = engine.maxPower
                local weight = obj:calcBeamStats().total_weight
                if power and weight and weight > 0 then
                    local model = v.config.model or ""
                    
                    obj:queueGameEngineLua("gameplay_events_freeroam_dataCollection.onVehicleModelReceived(]] .. 
                                         tostring(vehId) .. [[, " .. power .. ", " .. weight .. ", '" .. model .. "', ']] ..
                                         raceName .. [[', ]] .. tostring(time) .. [[, ]] ..
                                         tostring(entry.isAltRoute or false) .. [[)")
                end
            end
        ]]

  vehObj:queueLuaCommand(luaCommand)
end

local function fitP2WModel(samples)
  if not samples or #samples < 3 then
    return nil, "not_enough_samples"
  end

  local best = {
    err = math.huge,
    a = 0,
    b = 0,
    c = 0
  }

  local cMin, cMax, cStep = 0.1, 1.5, 0.01

  for c = cMin, cMax, cStep do
    local n = 0
    local sumX, sumY, sumXX, sumXY = 0, 0, 0, 0

    for _, s in ipairs(samples) do
      local r, t
      if s.p2w and s.time then
        r = s.p2w
        t = s.time
      elseif s.power and s.weight and s.time then
        r = s.power / s.weight
        t = s.time
      else
        goto continue
      end
      
      if r and t and r > 0 then
        local x = 1 / (r ^ c)
        sumX = sumX + x
        sumY = sumY + t
        sumXX = sumXX + x * x
        sumXY = sumXY + x * t
        n = n + 1
      end
      ::continue::
    end

    if n >= 3 then
      local denom = (n * sumXX - sumX * sumX)
      if denom ~= 0 then
        local b = (n * sumXY - sumX * sumY) / denom
        local a = (sumY - b * sumX) / n

        local err = 0
        for _, s in ipairs(samples) do
          local r, t
          if s.p2w and s.time then
            r = s.p2w
            t = s.time
          elseif s.power and s.weight and s.time then
            r = s.power / s.weight
            t = s.time
          else
            goto continue_err
          end
          
          if r and t and r > 0 then
            local x = 1 / (r ^ c)
            local pred = a + b * x
            local diff = t - pred
            err = err + diff * diff
          end
          ::continue_err::
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

local function fitPowerWeightYearModel(samples)
  if not samples or #samples < 7 then
    return nil, "not_enough_samples"
  end

  local n = #samples
  local powerVals = {}
  local weightVals = {}
  local yearVals = {}
  local timeVals = {}

  for _, s in ipairs(samples) do
    if s.power and s.weight and s.year and s.time and s.power > 0 and s.weight > 0 then
      table.insert(powerVals, s.power)
      table.insert(weightVals, s.weight)
      table.insert(yearVals, s.year)
      table.insert(timeVals, s.time)
    end
  end

  n = #powerVals
  if n < 7 then
    return nil, "not_enough_valid_samples"
  end

  local powerMin, powerMax = math.huge, -math.huge
  local weightMin, weightMax = math.huge, -math.huge
  local yearMin, yearMax = math.huge, -math.huge

  for i = 1, n do
    if powerVals[i] < powerMin then powerMin = powerVals[i] end
    if powerVals[i] > powerMax then powerMax = powerVals[i] end
    if weightVals[i] < weightMin then weightMin = weightVals[i] end
    if weightVals[i] > weightMax then weightMax = weightVals[i] end
    if yearVals[i] < yearMin then yearMin = yearVals[i] end
    if yearVals[i] > yearMax then yearMax = yearVals[i] end
  end

  if powerMax == powerMin or weightMax == weightMin or yearMax == yearMin then
    return nil, "no_variation_in_data"
  end

  local normalizePower = function(p) return (p - powerMin) / (powerMax - powerMin) end
  local normalizeWeight = function(w) return (w - weightMin) / (weightMax - weightMin) end
  local normalizeYear = function(y) return (y - yearMin) / (yearMax - yearMin) end

  local X = {}
  local Y = {}

  for i = 1, n do
    local p = normalizePower(powerVals[i])
    local w = normalizeWeight(weightVals[i])
    local y = normalizeYear(yearVals[i])
    
    table.insert(X, {1, p, w, y, p*p, w*w, y*y})
    table.insert(Y, timeVals[i])
  end

  local XtX = {}
  for i = 1, 7 do
    XtX[i] = {}
    for j = 1, 7 do
      XtX[i][j] = 0
      for k = 1, n do
        XtX[i][j] = XtX[i][j] + X[k][i] * X[k][j]
      end
    end
  end

  local XtY = {}
  for i = 1, 7 do
    XtY[i] = 0
    for k = 1, n do
      XtY[i] = XtY[i] + X[k][i] * Y[k]
    end
  end

  local det = 0
  for i = 1, 7 do
    local pivot = XtX[i][i]
    if math.abs(pivot) < 1e-10 then
      return nil, "singular_matrix"
    end
    for j = i + 1, 7 do
      local factor = XtX[j][i] / pivot
      for k = i, 7 do
        XtX[j][k] = XtX[j][k] - factor * XtX[i][k]
      end
      XtY[j] = XtY[j] - factor * XtY[i]
    end
  end

  local coef = {}
  for i = 7, 1, -1 do
    coef[i] = XtY[i]
    for j = i + 1, 7 do
      coef[i] = coef[i] - XtX[i][j] * coef[j]
    end
    coef[i] = coef[i] / XtX[i][i]
  end

  local err = 0
  for i = 1, n do
    local pred = coef[1] + coef[2]*X[i][2] + coef[3]*X[i][3] + coef[4]*X[i][4] + 
                 coef[5]*X[i][5] + coef[6]*X[i][6] + coef[7]*X[i][7]
    local diff = Y[i] - pred
    err = err + diff * diff
  end

  return {
    a = coef[1],
    b = coef[2],
    c = coef[3],
    d = coef[4],
    e = coef[5],
    f = coef[6],
    g = coef[7],
    err = err,
    powerMin = powerMin,
    powerMax = powerMax,
    weightMin = weightMin,
    weightMax = weightMax,
    yearMin = yearMin,
    yearMax = yearMax
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
        local coefOld, errOld = fitP2WModel(samples)
        local coefNew, errNew = fitPowerWeightYearModel(samples)
        
        if coefOld then
          if isAltRoute and race.altRoute then
            race.altRoute.predictCoef = {
              a = coefOld.a,
              b = coefOld.b,
              c = coefOld.c
            }
            if coefNew then
              race.altRoute.predictCoefNew = {
                a = coefNew.a,
                b = coefNew.b,
                c = coefNew.c,
                d = coefNew.d,
                e = coefNew.e,
                f = coefNew.f,
                g = coefNew.g,
                powerMin = coefNew.powerMin,
                powerMax = coefNew.powerMax,
                weightMin = coefNew.weightMin,
                weightMax = coefNew.weightMax,
                yearMin = coefNew.yearMin,
                yearMax = coefNew.yearMax
              }
            end
            updated = true
          elseif not isAltRoute then
            race.predictCoef = {
              a = coefOld.a,
              b = coefOld.b,
              c = coefOld.c
            }
            if coefNew then
              race.predictCoefNew = {
                a = coefNew.a,
                b = coefNew.b,
                c = coefNew.c,
                d = coefNew.d,
                e = coefNew.e,
                f = coefNew.f,
                g = coefNew.g,
                powerMin = coefNew.powerMin,
                powerMax = coefNew.powerMax,
                weightMin = coefNew.weightMin,
                weightMax = coefNew.weightMax,
                yearMin = coefNew.yearMin,
                yearMax = coefNew.yearMax
              }
            end
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

  collectVehicleRaceData(entry)
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
    if overhaul_extensionManager and overhaul_extensionManager.isDevKeyValid then
      if overhaul_extensionManager.isDevKeyValid() then
        isCollectingDataEnabled = true
        print("Data collection enabled by default (dev mode active)")
      end
    end
  end
end

local function onExtensionLoaded()
  if overhaul_extensionManager and overhaul_extensionManager.isDevKeyValid then
    if overhaul_extensionManager.isDevKeyValid() then
      isCollectingDataEnabled = true
      print("Data collection enabled by default (dev mode active)")
    end
  end
end

M.onVehicleRaceDataCollected = onVehicleRaceDataCollected
M.onVehicleModelReceived = onVehicleModelReceived
M.collectDataFromEntry = collectDataFromEntry
M.collectData = collectData
M.isCollectingData = isCollectingData
M.onWorldReadyState = onWorldReadyState
M.onExtensionLoaded = onExtensionLoaded
M.analyzeData = analyzeData

return M
