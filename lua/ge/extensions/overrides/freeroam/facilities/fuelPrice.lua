-- Override of freeroam_facilities_fuelPrice
-- Applies globalEconomy index as a multiplier to fuel prices displayed on gas station signs.

local M = {}

local cachedPrices = {}       -- [stationId][fuelType] = metricPrice (economy-adjusted)
local clonedObjects = {}      -- tracking created display clones
local simGroupName = "fuelPrice_localCopies"

local periodShape = "art/shapes/quarter_mile_display/display_period.dae"

local digitShapes = {
  ["0"] = "art/shapes/quarter_mile_display/display_0.dae",
  ["1"] = "art/shapes/quarter_mile_display/display_1.dae",
  ["2"] = "art/shapes/quarter_mile_display/display_2.dae",
  ["3"] = "art/shapes/quarter_mile_display/display_3.dae",
  ["4"] = "art/shapes/quarter_mile_display/display_4.dae",
  ["5"] = "art/shapes/quarter_mile_display/display_5.dae",
  ["6"] = "art/shapes/quarter_mile_display/display_6.dae",
  ["7"] = "art/shapes/quarter_mile_display/display_7.dae",
  ["8"] = "art/shapes/quarter_mile_display/display_8.dae",
  ["9"] = "art/shapes/quarter_mile_display/display_9.dae",
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

  obj:preApply()
  obj:setHidden(true)
  obj:postApply()

  local shapePath = digitShapes[tostring(digit)]
  if not shapePath then
    table.insert(clonedObjects, {original = objName})
    return
  end

  local clone = createObject("TSStatic")
  clone:setField("shapeName", 0, shapePath)
  clone:setTransform(obj:getTransform())
  clone:setScale(obj:getScale())
  clone:setCanSave(false)
  clone:registerObject(tostring(objName) .. "_localCopy")
  group:addObject(clone)
  table.insert(clonedObjects, {original = objName})
end

local function createPeriodAtPosition(objBeforeName, objAfterName, group)
  local objBefore = scenetree.findObject(objBeforeName)
  local objAfter = scenetree.findObject(objAfterName)
  if not objBefore or not objAfter then return end

  local p1 = objBefore:getPosition()
  local p2 = objAfter:getPosition()
  local t = 1.05
  local pos = vec3(lerp(p1.x, p2.x, t), lerp(p1.y, p2.y, t), lerp(p1.z, p2.z, t))

  local clone = createObject("TSStatic")
  clone:setField("shapeName", 0, periodShape)
  clone:setTransform(objBefore:getTransform())
  clone:setScale(objBefore:getScale())
  clone:setPosition(pos)
  clone:setCanSave(false)
  clone:registerObject(tostring(objBeforeName) .. "_period_localCopy")
  group:addObject(clone)
  table.insert(clonedObjects, {original = objBeforeName .. "_period_synthetic"})
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
  local levelUnits = nil
  local levelName = getCurrentLevelIdentifier()
  if levelName and levelName ~= "" then
    local levelInfoData = core_levels.getLevelByName(levelName)
    if levelInfoData then
      levelUnits = levelInfoData.localUnits
    end
  end

  local facilities = nil
  if freeroam_facilities.getFacilities and levelName and levelName ~= "" then
    facilities = freeroam_facilities.getFacilities(levelName)
  end
  if not facilities and freeroam_facilities.getCurrentLevelFacilities then
    facilities = freeroam_facilities.getCurrentLevelFacilities()
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

    for fuelType, fuelData in pairs(prices) do
      if not fuelData then goto continueFuel end
      if fuelData.disabled and fuelData.displayObjects then
        for _, objNames in ipairs(fuelData.displayObjects) do
          for _, objName in ipairs(objNames) do
            setDigitShape(objName, "-", group)
          end
        end
        goto continueFuel
      end
      if not fuelData.priceBaseline then goto continueFuel end

      local baseline = fuelData.priceBaseline or 0
      local randomGain = fuelData.priceRandomnessGain or 0
      local randomBias = fuelData.priceRandomnessBias or 0.5

      -- Seeded random per station+fuelType so prices don't jump every tick
      local seed = stableHash(tostring(stationId) .. "_" .. tostring(fuelType))
      local stableRandom = (seed % 10000) / 10000  -- 0..1 deterministic value
      local basePrice = baseline + randomGain * (stableRandom - randomBias)

      -- Apply economy multiplier AFTER base calculation
      local adjustedPrice = basePrice * economyMult

      local useGallons = levelUnits and levelUnits[fuelType] == "gallonUS"
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

        -- Determine decimal position from integer digit count (e.g. 6.48->1, 64.9->2, 123.4->3)
        local intPart = math.floor(adjustedPrice + 0.001)
        local decimalIdx = (intPart == 0) and 1 or math.min(#tostring(intPart), 3)
        if decimalIdx + 1 <= #displayObjects then
          local beforeObjs = displayObjects[decimalIdx]
          local afterObjs = displayObjects[decimalIdx + 1]
          for i, objBefore in ipairs(beforeObjs) do
            local objAfter = afterObjs[i]
            if objAfter then
              createPeriodAtPosition(objBefore, objAfter, group)
            end
          end
        end

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
