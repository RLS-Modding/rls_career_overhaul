-- Override of freeroam_facilities_fuelPrice
-- Applies globalEconomy index as a multiplier to fuel prices displayed on gas station signs.

local M = {}

local cachedPrices = {}       -- [stationId][fuelType] = metricPrice (economy-adjusted)
local clonedObjects = {}      -- tracking created display clones
local simGroupName = "fuelPrice_localCopies"

-- DAE shape paths for 7-segment digits and dash
local digitShapes = {
  ["0"] = "art/shapes/props/gas_station_signs/gas_0.dae",
  ["1"] = "art/shapes/props/gas_station_signs/gas_1.dae",
  ["2"] = "art/shapes/props/gas_station_signs/gas_2.dae",
  ["3"] = "art/shapes/props/gas_station_signs/gas_3.dae",
  ["4"] = "art/shapes/props/gas_station_signs/gas_4.dae",
  ["5"] = "art/shapes/props/gas_station_signs/gas_5.dae",
  ["6"] = "art/shapes/props/gas_station_signs/gas_6.dae",
  ["7"] = "art/shapes/props/gas_station_signs/gas_7.dae",
  ["8"] = "art/shapes/props/gas_station_signs/gas_8.dae",
  ["9"] = "art/shapes/props/gas_station_signs/gas_9.dae",
  ["-"] = "art/shapes/props/gas_station_signs/gas_dash.dae",
}

-- Simple string hash for deterministic per-station randomness
local function stableHash(str)
  local h = 5381
  for i = 1, #str do
    h = (h * 33 + string.byte(str, i)) % 2147483647
  end
  return h
end

local function getEconomyMultiplier()
  if career_modules_globalEconomy and career_modules_globalEconomy.getFuelPriceMultiplier then
    return career_modules_globalEconomy.getFuelPriceMultiplier()
  end
  return career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex and career_modules_globalEconomy.getGlobalIndex() or 1.0
end

local function getOrCreateSimGroup()
  local group = scenetree.findObject(simGroupName)
  if not group then
    group = createObject("SimGroup")
    group:registerObject(simGroupName)
    group.canSave = false
  end
  return group
end

local function clearClones()
  local group = scenetree.findObject(simGroupName)
  if group then
    group:deleteAllObjects()
  end
  clonedObjects = {}
end

local function setDigitShape(objName, digit, group)
  local obj = scenetree.findObject(objName)
  if not obj then return end

  local shapePath = digitShapes[tostring(digit)] or digitShapes["-"]
  if not shapePath then return end

  -- Hide original
  obj:setHidden(true)

  -- Create clone with the correct shape
  local clone = createObject("TSStatic")
  clone.shapeName = shapePath
  clone:setPosition(obj:getPosition())
  clone:setScale(obj:getScale())
  local rot = obj:getRotation()
  clone:setField("rotation", 0, rot.x .. " " .. rot.y .. " " .. rot.z .. " " .. rot.w)
  clone.canSave = false
  clone:registerObject("")
  group:addObject(clone)
  table.insert(clonedObjects, {original = objName, clone = clone})
end

local function formatPrice(price)
  -- Format as 4-digit string: e.g. 1.459 -> "1459"
  local cents = math.floor(price * 1000 + 0.5)
  local str = tostring(cents)
  while #str < 4 do
    str = "0" .. str
  end
  return str:sub(1, 4)
end

local function setDisplayPrices()
  if not freeroam_facilities then return false end

  local facilities = freeroam_facilities.getCurrentLevelFacilities and freeroam_facilities.getCurrentLevelFacilities()
  if not facilities then
    facilities = freeroam_facilities.getFacilities and freeroam_facilities.getFacilities()
  end
  if not facilities then return false end

  local gasStations = facilities.gasStations
  if not gasStations or #gasStations == 0 then return false end

  -- Clear previous clones
  clearClones()
  local group = getOrCreateSimGroup()

  local economyMult = getEconomyMultiplier()
  local hasAnyPrices = false

  cachedPrices = {}

  for _, station in ipairs(gasStations) do
    local stationId = station.id
    if not stationId then goto continueStation end
    cachedPrices[stationId] = {}

    local prices = station.prices
    if not prices then goto continueStation end

    -- Check if this level uses gallons
    local useGallons = false
    if station.unitSystem == "gallonUS" or (facilities.unitSystem and facilities.unitSystem == "gallonUS") then
      useGallons = true
    end

    for fuelType, fuelData in pairs(prices) do
      if not fuelData or not fuelData.priceBaseline then goto continueFuel end

      local baseline = fuelData.priceBaseline or 0
      local randomGain = fuelData.priceRandomnessGain or 0
      local randomBias = fuelData.priceRandomnessBias or 0.5

      -- Seeded random per station+fuelType so prices don't jump every tick
      local seed = stableHash(tostring(stationId) .. "_" .. tostring(fuelType))
      local stableRandom = (seed % 10000) / 10000  -- 0..1 deterministic value
      local basePrice = baseline + randomGain * (stableRandom - randomBias)

      -- Apply economy multiplier AFTER base calculation
      local adjustedPrice = basePrice * economyMult

      -- Convert to gallons if needed (1 gallon = 3.78541 liters)
      if useGallons then
        adjustedPrice = adjustedPrice * 3.78541
      end

      -- Cache the metric price (before gallon conversion) for getFuelPrice
      cachedPrices[stationId][fuelType] = basePrice * economyMult

      -- Format and display
      local displayObjects = fuelData.displayObjects
      if displayObjects and #displayObjects > 0 then
        hasAnyPrices = true
        local priceStr = formatPrice(adjustedPrice)

        for digitIdx, objNames in ipairs(displayObjects) do
          local digit = priceStr:sub(digitIdx, digitIdx)

          -- US 9/10 tax convention: last digit forced to 9
          if fuelData.us_9_10_tax and digitIdx == 4 then
            digit = "9"
          end

          for _, objName in ipairs(objNames) do
            setDigitShape(objName, digit, group)
          end
        end
      end

      ::continueFuel::
    end

    -- Handle disabled fuel types (show dashes)
    if station.disabledFuelTypes then
      for _, fuelType in ipairs(station.disabledFuelTypes) do
        local fuelData = prices[fuelType]
        if fuelData and fuelData.displayObjects then
          for _, objNames in ipairs(fuelData.displayObjects) do
            for _, objName in ipairs(objNames) do
              setDigitShape(objName, "-", group)
            end
          end
        end
      end
    end

    ::continueStation::
  end

  return hasAnyPrices
end

local function getFuelPrice(stationId, fuelType)
  if not stationId or not fuelType then return nil end
  if cachedPrices[stationId] then
    return cachedPrices[stationId][fuelType]
  end
  return nil
end

local function restoreSign(hide)
  for _, entry in ipairs(clonedObjects) do
    local orig = scenetree.findObject(entry.original)
    if orig then
      orig:setHidden(hide or false)
    end
  end
  clearClones()
end

-- Called by globalEconomy when indices update
local function onEconomyUpdated()
  setDisplayPrices()
end

-- Hooks
local function onClientStartMission()
  setDisplayPrices()
end

local function onSerialize()
  return {cachedPrices = cachedPrices}
end

local function onDeserialized(data)
  if data and data.cachedPrices then
    cachedPrices = data.cachedPrices
    -- Refresh physical sign meshes so they reflect cached prices immediately
    setDisplayPrices()
  else
    setDisplayPrices()
  end
end

M.setDisplayPrices = setDisplayPrices
M.getFuelPrice = getFuelPrice
M.restoreSign = restoreSign
M.onEconomyUpdated = onEconomyUpdated

local function onClientEndMission()
  restoreSign(false)
  cachedPrices = {}
end

M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
