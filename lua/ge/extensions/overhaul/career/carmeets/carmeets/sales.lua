-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Car meet sales helpers: meet vehicle inventory lookup, player position, invite cap and meet sale offers.
-- Map: per-load state, vehicle lookups, paint and shop data, sale offers and returned API.

local lib = {}

function lib.create(inputs)
  -- State -----------------------------------------------------------------------------------------

  local carMeetState = inputs.carMeetState
  local callbacks = inputs.callbacks

  -- Helpers ---------------------------------------------------------------------------------------

  local function getMeetVehicleInventoryId(meetState)
    meetState = meetState or carMeetState.meetState
    if not meetState or not meetState.flags then return nil end
    if meetState.flags.saleInventoryId then return meetState.flags.saleInventoryId end
    if meetState.flags.playerBroughtVehicle then
      return callbacks.getCurrentInventoryId()
    end
    return nil
  end

  local function getPlayerReferencePosition()
    local playerVeh = be:getPlayerVehicle(0)
    if playerVeh then return playerVeh:getPosition() end
    return vec3(core_camera.getPosition())
  end

  local function getPendingInviteCap()
    return overhaul_career_carmeets_reputation.getReputation() >= inputs.LATE_PENDING_INVITE_REP and inputs.LATE_PENDING_INVITE_CAP or inputs.EARLY_PENDING_INVITE_CAP
  end

  local function normalizeString(value)
    return string.lower(tostring(value or ""))
  end

  local function valueMatches(value, expectedValues)
    local normalized = normalizeString(value)
    if normalized == "" then return false end
    for _, expected in ipairs(expectedValues or {}) do
      local expectedNormalized = normalizeString(expected)
      if normalized == expectedNormalized then
        return true
      end
    end
    return false
  end

  -- Serializes with sorted keys so equal tables give equal strings.
  local function sortedStableSerialize(value)
    local valueType = type(value)
    if valueType ~= "table" then
      return tostring(value)
    end

    local keys = {}
    for key in pairs(value) do
      table.insert(keys, key)
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    local parts = {}
    for _, key in ipairs(keys) do
      table.insert(parts, tostring(key) .. "=" .. sortedStableSerialize(value[key]))
    end
    return "{" .. table.concat(parts, "|") .. "}"
  end

  callbacks.getCurrentInventoryId = function()
    return overhaul_career_garage_inventory.getCurrentVehicle()
  end

  -- The brought vehicle: the sale car if set, else the vehicle the player is in, else the last one used.
  local function resolveMeetSaleInventoryId()
    local inventoryId = callbacks.getCurrentInventoryId()
    if inventoryId then return inventoryId end

    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId and playerVehId >= 0 then
      inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(playerVehId)
      if inventoryId then return inventoryId end
    end

    return overhaul_career_garage_inventory.getLastVehicle()
  end

  local function getInventoryVehicle(inventoryId)
    if not inventoryId then return nil end
    return overhaul_career_garage_inventory.getVehicle(inventoryId)
  end

  local function getInventoryVehicleValue(inventoryId)
    if not inventoryId then return 0 end
    local value = overhaul_career_garage_inventory.getVehicleValuationService().getInventoryVehicleValue(inventoryId)
    if not value then
      value = overhaul_career_garage_inventory.getVehicleValuationService().getInventoryVehicleSellValue(inventoryId)
    end
    return tonumber(value) or 0
  end

  local function getInventoryVehicleDisplayName(vehicle, fallback)
    local raw = vehicle and (vehicle.niceName or vehicle.name) or nil
    if raw ~= nil then
      local translated = core_locales.translateWithOrWithoutContext(raw)
      if type(translated) == "string" and translated ~= "" then
        return translated
      end
    end
    if type(raw) == "string" and raw ~= "" then
      return raw
    end
    return fallback or "Your vehicle"
  end

  -- Meet sale -------------------------------------------------------------------------------------

  -- Creates or refreshes the listing for the brought vehicle; the asking price keeps the player's value.
  local function ensureMeetSaleState(meetState)
    if not meetState or not meetState.flags or not meetState.flags.saleInventoryId then return nil end
    local inventoryId = meetState.flags.saleInventoryId
    local vehicle = getInventoryVehicle(inventoryId) or {}
    local marketValue = getInventoryVehicleValue(inventoryId)

    meetState.flags.saleOffers = meetState.flags.saleOffers or {}
    meetState.flags.saleListing = meetState.flags.saleListing or {
      id = inventoryId,
      inventoryId = inventoryId,
      niceName = getInventoryVehicleDisplayName(vehicle, "Brought vehicle"),
      value = marketValue,
      marketValue = marketValue,
      thumbnail = overhaul_career_garage_inventory.getVehicleThumbnail(inventoryId) or nil
    }

    meetState.flags.saleListing.niceName = getInventoryVehicleDisplayName(vehicle, meetState.flags.saleListing.niceName or "Brought vehicle")
    meetState.flags.saleListing.value = tonumber(meetState.flags.saleListing.value) or marketValue
    meetState.flags.saleListing.marketValue = marketValue
    return meetState.flags.saleListing
  end

  local function getAskingPriceOfferChanceMultiplier(listing)
    if not listing then return 1 end
    local marketValue = math.max(tonumber(listing.marketValue) or 0, 1)
    local askingRatio = (tonumber(listing.value) or marketValue) / marketValue
    if askingRatio <= 0.85 then return 1.5 end
    if askingRatio <= 1.10 then return 1.0 end
    if askingRatio <= 1.35 then return 0.7 end
    if askingRatio <= 1.60 then return 0.45 end
    return 0.25
  end

  -- Draws one buyer offer; the random draws keep their order (noise is drawn before the cap).
  local function generateMeetSaleOffer(meetState, ttl)
    local listing = ensureMeetSaleState(meetState)
    if not listing then return nil end
    local buyerPersonality = overhaul_career_garage_inventory.getVehicleNegotiationService().generatePersonality(true)
    if not buyerPersonality then return nil end

    local marketValue = math.max(tonumber(listing.marketValue) or tonumber(listing.value) or 0, 50)
    local askingPrice = math.max(tonumber(listing.value) or marketValue, 50)
    local askingRatio = askingPrice / marketValue
    local personalityMult = buyerPersonality.priceMultiplier or 1
    local noise = 0.86 + (math.random() * 0.22)
    local askInfluence = math.max(0.85, math.min(1.12, 1 + ((askingRatio - 1) * 0.22)))
    local cap = askingRatio > 1.1 and (marketValue * math.min(1.25, 0.95 + ((askingRatio - 1) * 0.35))) or askingPrice * 1.03
    local value = math.max(50, math.floor((math.min(marketValue * personalityMult * noise * askInfluence, cap) + 25) / 50) * 50)
    local offer = {
      timestamp = os.time(),
      value = value,
      ttl = ttl or inputs.BAZAAR_OFFER_TTL,
      negotiationPossible = true,
      buyerPersonality = buyerPersonality,
      source = "carMeet"
    }
    table.insert(meetState.flags.saleOffers, offer)
    return offer
  end

  local function getSellOfferChance(meetTypeKey)
    if meetTypeKey == "SHOWCASE" then return 0.20 end
    if meetTypeKey == "CLUB" then return 0.20 end
    if meetTypeKey == "STREET_CRUISE" then return 0.20 end
    if meetTypeKey == "ELITE" then return 0.15 end
    return 0.10
  end

  -- Paint for meet cars ---------------------------------------------------------------------------

  local function getConfigKeyFromPath(configPath)
    if type(configPath) ~= "string" then return nil end
    local normalized = configPath:gsub("\\", "/")
    local key = normalized:match("/configurations/([^/]+)%.pc$")
    if key then return key end
    return normalized:match("/([^/]+)%.pc$")
  end

  -- Picks up to three random paints for a listing and writes them into the spawn options.
  local function applyRandomPaintToSpawnOptions(options, modelKey, configPath)
    if not options or not modelKey then return end
    local paintResult = core_vehiclePaints.getRandomPaints(modelKey, getConfigKeyFromPath(configPath))
    if type(paintResult) ~= "table" then return end

    local modelData = core_vehicles.getModel(modelKey)
    local modelPaints = modelData and modelData.model and modelData.model.paints
    if type(modelPaints) ~= "table" then return end

    local paintNames = {
      paintResult.paintName1,
      paintResult.paintName2 or paintResult.paintName1,
      paintResult.paintName3 or paintResult.paintName2 or paintResult.paintName1
    }
    if not paintNames[1] or not modelPaints[paintNames[1]] then return end

    -- Use the same random-paint source as the auction house, but apply all paint slots so two-tone and three-paint configs vary properly at meets.
    options.paintName = paintNames[1]
    options.paintName2 = paintNames[2]
    options.paintName3 = paintNames[3]
    options.paint = deepcopy(modelPaints[paintNames[1]])
    options.paint2 = paintNames[2] and modelPaints[paintNames[2]] and deepcopy(modelPaints[paintNames[2]]) or nil
    options.paint3 = paintNames[3] and modelPaints[paintNames[3]] and deepcopy(modelPaints[paintNames[3]]) or nil
    options.carMeetRandomPaintNames = paintNames

    if type(configPath) == "string" then
      local cfg = jsonReadFile(configPath)
      if type(cfg) == "table" and cfg.format ~= 4 then
        cfg = deepcopy(cfg)
        cfg.partConfigFilename = configPath
        cfg.colors = nil
        local paints = type(cfg.paints) == "table" and deepcopy(cfg.paints) or {}
        paints[1] = deepcopy(options.paint)
        if options.paint2 then paints[2] = deepcopy(options.paint2) end
        if options.paint3 then paints[3] = deepcopy(options.paint3) end
        cfg.paints = paints
        options.config = cfg
      end
    end
  end

  local function embedPaintNamesInVehicleConfig(vehId, modelKey, paintNames)
    if not vehId or type(paintNames) ~= "table" or not paintNames[1] then return end

    core_vehicle_manager.setVehiclePaintsNames(vehId, paintNames)

    local vehicleData = core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData or type(vehicleData.config) ~= "table" then return end

    local modelData = modelKey and core_vehicles.getModel(modelKey) or nil
    if not modelData and vehicleData.ioCtx and vehicleData.ioCtx.modelKey then
      modelData = core_vehicles.getModel(vehicleData.ioCtx.modelKey)
    end
    local modelPaints = modelData and modelData.model and modelData.model.paints
    if type(modelPaints) ~= "table" then return end

    local config = vehicleData.config
    config.colors = nil
    local paints = type(config.paints) == "table" and deepcopy(config.paints) or {}
    for i, paintName in ipairs(paintNames) do
      if paintName and modelPaints[paintName] then
        paints[i] = deepcopy(modelPaints[paintName])
      end
    end
    config.paints = paints
    config.paintName = paintNames[1]
    config.paintName2 = paintNames[2]
    config.paintName3 = paintNames[3]
  end

  local function applyRandomPaintToSpawnedVehicle(vehId, paintNames, modelKey)
    embedPaintNamesInVehicleConfig(vehId, modelKey, paintNames)
  end

  -- Shop info -------------------------------------------------------------------------------------

  -- Model year: a random year inside the catalog range, capped at the current year.
  local function rollMeetVehicleYear(info, currentYear)
    local year = currentYear
    if type(info.Years) == "table" then
      local minYear = tonumber(info.Years.min) or tonumber(info.Years[1])
      local maxYear = tonumber(info.Years.max) or minYear
      if minYear and maxYear then
        if minYear > maxYear then minYear, maxYear = maxYear, minYear end
        maxYear = math.min(maxYear, currentYear)
        if minYear > maxYear then minYear = maxYear end
        year = math.random(math.floor(minYear), math.floor(maxYear))
      end
    elseif tonumber(info.Years) then
      year = tonumber(info.Years)
    end
    return year
  end

  -- Mileage in meters: a random car unless the catalog gives one, in miles or meters.
  local function rollMeetVehicleMileage(info)
    local mileageMeters = math.random(10000, 300000) * 1609.344
    local rawMileage = tonumber(info.Mileage) or tonumber(info.mileage) or tonumber(info["Mileage"])
    if rawMileage and rawMileage > 0 then
      mileageMeters = rawMileage > 2000000 and rawMileage or rawMileage * 1609.344
    end
    return mileageMeters
  end

  local function meetVehicleMarketValue(info, vehicleData, year, mileageMeters, currentYear)
    local catalogValue = tonumber(info.Value) or tonumber(info.value) or tonumber(info.configBaseValue) or 10000
    local configKey = tostring(info.key or vehicleData.config or ""):match("/configurations/([^/]+)%.pc$") or tostring(info.key or ""):gsub("%.pc$", "")
    local partsCatalogSum = info.cachedPartsValue
    if not partsCatalogSum then
      partsCatalogSum = overhaul_career_garage_inventory.getVehicleValuationService().getVehiclePcPartsCatalogSum(info.model_key or vehicleData.model, configKey, "carMeetPurchase")
    end
    local marketValue = overhaul_career_garage_inventory.getVehicleValuationService().getVehicleCatalogIntrinsicBookValue({
      catalogBaseValue = catalogValue,
      mileageMeters = mileageMeters,
      age = math.max(0, currentYear - (tonumber(year) or currentYear)),
      modelName = info.model_key or vehicleData.model,
      configKey = configKey,
      partsCatalogSum = partsCatalogSum,
      logContext = "carMeetPurchase",
      applyVehicleBuyMarket = false
    })
    if not marketValue then
      marketValue = overhaul_career_garage_inventory.getVehicleValuationService().getAdjustedVehicleBaseValue(catalogValue, {mileage = mileageMeters, age = math.max(0, currentYear - year)})
    end
    return math.max(1500, math.floor(tonumber(marketValue) or catalogValue))
  end

  local function buildCarMeetVehicleShopInfo(vehicleData, spot, meetTypeKey)
    if not vehicleData then return nil end
    local info = deepcopy(vehicleData.info or {})
    local currentYear = tonumber(os.date("%Y")) or 2026
    local mileageMeters = rollMeetVehicleMileage(info)
    local year = rollMeetVehicleYear(info, currentYear)
    local marketValue = meetVehicleMarketValue(info, vehicleData, year, mileageMeters, currentYear)

    info.model_key = info.model_key or vehicleData.model
    info.key = vehicleData.config
    info.Name = info.Name or info.name or info.key or "Meet Vehicle"
    info.Brand = info.Brand or info.brand or info.model_key or "Car Meet"
    info.niceName = (info.Brand and info.Name) and (tostring(info.Brand) .. " " .. tostring(info.Name)) or "Car Meet Vehicle"
    info.Value = marketValue
    info.marketValue = marketValue
    info.marketValueBase = info.marketValue
    info.valueBase = nil
    info.Mileage = mileageMeters
    info.year = year
    info.fees = 0
    info.tax = 0
    info.sellerId = "carMeet"
    info.negotiationPersonality = overhaul_career_garage_inventory.getVehicleNegotiationService().generatePersonality(false)
    info.sellerName = info.negotiationPersonality and info.negotiationPersonality.name or "Private Seller"
    info.negotiationPossible = true
    info.playerStartsNegotiation = true
    info.hideMarketValue = true
    info.source = "carMeet"
    info.meetType = meetTypeKey
    info.pos = spot and vec3(spot.pos) or nil
    return info
  end

  -- Public API ------------------------------------------------------------------------------------

  return {
    getMeetVehicleInventoryId = getMeetVehicleInventoryId,
    getPlayerReferencePosition = getPlayerReferencePosition,
    getPendingInviteCap = getPendingInviteCap,
    normalizeString = normalizeString,
    valueMatches = valueMatches,
    sortedStableSerialize = sortedStableSerialize,
    resolveMeetSaleInventoryId = resolveMeetSaleInventoryId,
    getInventoryVehicle = getInventoryVehicle,
    getInventoryVehicleValue = getInventoryVehicleValue,
    getInventoryVehicleDisplayName = getInventoryVehicleDisplayName,
    ensureMeetSaleState = ensureMeetSaleState,
    getAskingPriceOfferChanceMultiplier = getAskingPriceOfferChanceMultiplier,
    generateMeetSaleOffer = generateMeetSaleOffer,
    getSellOfferChance = getSellOfferChance,
    applyRandomPaintToSpawnOptions = applyRandomPaintToSpawnOptions,
    applyRandomPaintToSpawnedVehicle = applyRandomPaintToSpawnedVehicle,
    buildCarMeetVehicleShopInfo = buildCarMeetVehicleShopInfo,
  }
end

return lib
