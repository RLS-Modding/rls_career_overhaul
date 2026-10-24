-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/freeroam/facilities/fuelPrice.lua (BeamNG 0.40).

-- Gas station price signs for Overhaul, scaled by the global economy index.
local M = {}

M.dependencies = {"overhaul_shell_patches"}

local PATCH_ID = "fuelPrice"

local cachedPrices = {}       -- [stationId][fuelType] = metricPrice (economy-adjusted)
local clonedObjects = {}
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
  ["-"] = "art/shapes/quarter_mile_display/display_-.dae",
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
  if overhaul_career_economy_globalEconomy and overhaul_career_economy_globalEconomy.getFuelPriceMultiplier then
    return overhaul_career_economy_globalEconomy.getFuelPriceMultiplier()
  end
  return overhaul_career_economy_globalEconomy and overhaul_career_economy_globalEconomy.getGlobalIndex and overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
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

local function cloneIsCurrent(cloneName, shapePath, touched)
  touched[cloneName] = true
  local entry = clonedObjects[cloneName]
  if entry and entry.shape == (shapePath or false) and (not shapePath or scenetree.findObject(cloneName)) then
    return true
  end
  local old = scenetree.findObject(cloneName)
  if old then old:delete() end
  return false
end

local function setDigitShape(objName, digit, group, touched)
  local obj = scenetree.findObject(objName)
  if not obj then return end

  local cloneName = tostring(objName) .. "_localCopy"
  local shapePath = digitShapes[tostring(digit)]
  if cloneIsCurrent(cloneName, shapePath, touched) then return end

  obj:preApply()
  obj:setHidden(true)
  obj:postApply()

  clonedObjects[cloneName] = {original = objName, shape = shapePath or false}
  if not shapePath then return end

  local clone = createObject("TSStatic")
  clone:setField("shapeName", 0, shapePath)
  clone:setTransform(obj:getTransform())
  clone:setScale(obj:getScale())
  clone:setCanSave(false)
  clone:registerObject(cloneName)
  group:addObject(clone)
end

local function createPeriodAtPosition(objBeforeName, objAfterName, group, touched)
  local objBefore = scenetree.findObject(objBeforeName)
  local objAfter = scenetree.findObject(objAfterName)
  if not objBefore or not objAfter then return end

  local cloneName = tostring(objBeforeName) .. "_period_localCopy"
  if cloneIsCurrent(cloneName, periodShape, touched) then return end

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
  clone:registerObject(cloneName)
  group:addObject(clone)
  clonedObjects[cloneName] = {shape = periodShape}
end

local function formatPrice(price)
  -- Format as 4-digit string: e.g. 1.459 -> "1459"
  local priceThousandths = math.floor(price * 1000 + 0.5)
  local str = tostring(priceThousandths)
  while #str < 4 do
    str = "0" .. str
  end
  return str:sub(1, 4)
end

local function setDisplayPrices(restoredPrices)
  if not overhaul_world_facilities then return false end
  local levelUnits = nil
  local levelName = getCurrentLevelIdentifier()
  if levelName and levelName ~= "" then
    local levelInfoData = core_levels.getLevelByName(levelName)
    if levelInfoData then
      levelUnits = levelInfoData.localUnits
    end
  end

  local facilities = nil
  if overhaul_world_facilities.getFacilities and levelName and levelName ~= "" then
    facilities = overhaul_world_facilities.getFacilities(levelName)
  end
  if not facilities and overhaul_world_facilities.getCurrentLevelFacilities then
    facilities = overhaul_world_facilities.getCurrentLevelFacilities()
  end
  if not facilities then return false end

  local gasStations = facilities.gasStations
  if not gasStations or #gasStations == 0 then return false end

  local group = getOrCreateSimGroup()
  local touched = {}

  local economyMult = getEconomyMultiplier()
  local hasAnyPrices = false

  cachedPrices = {}

  for _, station in ipairs(gasStations) do
    local stationId = station.id
    if not stationId then goto continueStation end
    cachedPrices[stationId] = {}

    local prices = station.prices
    if not prices then goto continueStation end

    local disabledTypes = {}
    for _, fuelType in ipairs(station.disabledFuelTypes or {}) do
      disabledTypes[fuelType] = true
    end

    for fuelType, fuelData in pairs(prices) do
      if not fuelData then goto continueFuel end
      if fuelData.disabled or disabledTypes[fuelType] then
        if fuelData.disabled and fuelData.displayObjects and not disabledTypes[fuelType] then
          for _, objNames in ipairs(fuelData.displayObjects) do
            for _, objName in ipairs(objNames) do
              setDigitShape(objName, "-", group, touched)
            end
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

      local restored = restoredPrices and restoredPrices[stationId] and tonumber(restoredPrices[stationId][fuelType])
      local metricPrice = restored or basePrice * economyMult
      local adjustedPrice = metricPrice

      local useGallons = levelUnits and levelUnits[fuelType] == "gallonUS"
      -- Convert to gallons if needed (1 gallon = 3.78541 liters)
      if useGallons then
        adjustedPrice = adjustedPrice * 3.78541
      end

      -- Cache the metric price (before gallon conversion) for getFuelPrice
      cachedPrices[stationId][fuelType] = metricPrice

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
              createPeriodAtPosition(objBefore, objAfter, group, touched)
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
            setDigitShape(objName, digit, group, touched)
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
              setDigitShape(objName, "-", group, touched)
            end
          end
        end
      end
    end

    ::continueStation::
  end

  for cloneName, entry in pairs(clonedObjects) do
    if not touched[cloneName] and entry.shape then
      local old = scenetree.findObject(cloneName)
      if old then old:delete() end
      entry.shape = false
    end
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
  for _, entry in pairs(clonedObjects) do
    local orig = entry.original and scenetree.findObject(entry.original)
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

local function isOverhaulActive()
  return overhaul_shell_gameMode and overhaul_shell_gameMode.isActive and overhaul_shell_gameMode.isActive() or false
end

local function isLevelLoaded()
  local level = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
  return level ~= nil and level ~= ""
end

local function onClientStartMission()
  if not isOverhaulActive() then return end
  setDisplayPrices()
end

local function onSerialize()
  return {cachedPrices = cachedPrices, active = isOverhaulActive()}
end

local function onDeserialized(data)
  if not (data and data.active) and not isOverhaulActive() then return end
  if data and data.cachedPrices then
    setDisplayPrices(data.cachedPrices)
  else
    setDisplayPrices()
  end
end

M.setDisplayPrices = setDisplayPrices
M.getFuelPrice = getFuelPrice
M.restoreSign = restoreSign
M.onEconomyUpdated = onEconomyUpdated

local function onClientEndMission()
  if next(clonedObjects) then restoreSign(false) end
  cachedPrices = {}
end

-- The game's sign module renders the same signs; it pauses while Overhaul runs.
local silenced = function() return function() end end
-- Filled when the extension loads: the sign field swap and its install, uninstall and refresh.
local swap = {}

local function install()
  swap.install()
  if not isLevelLoaded() then return end
  local stock = freeroam_facilities_fuelPrice
  if stock and stock.restoreSign and scenetree.findObject(simGroupName) then pcall(stock.restoreSign, false) end
  setDisplayPrices()
end

local function uninstall()
  swap.uninstall()
  if not isLevelLoaded() then return end
  restoreSign(false)
  cachedPrices = {}
  local stock = freeroam_facilities_fuelPrice
  if stock and stock.setDisplayPrices then pcall(stock.setDisplayPrices) end
end

M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

M.onExtensionLoaded = function()
  swap.install, swap.uninstall, swap.refresh = overhaul_shell_patches.fieldSwap(function() return freeroam_facilities_fuelPrice end, {
    onClientStartMission = silenced,
    onDeserialized = silenced,
  })
  overhaul_shell_patches.register(PATCH_ID, install, uninstall, swap.refresh)
end

M.onExtensionUnloaded = function()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

return M
