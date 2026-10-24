-- Stock listing generation and refresh for one shopping instance.
-- Read listing condition and price, seller generation, then refresh; stock/listings owns maintenance.
local M = {}
local listings = require("overhaul/career/market/vehicleShopping/stock/listings")

function M.new(inputs)
  local service = {}
  local dependencies = {}
  local state = inputs.state
  local shoppingConfig = inputs.config
  local listingMaintenance = listings.new {state = inputs.state, config = inputs.config}

  -- Listing fields --------------------------------------------------------------------------------
  local function populateListingCondition(randomVehicleInfo, seller, onlyStarterVehicles,
      starterVehicleMileages, starterVehicleYears)
    local filter = dependencies.catalog.choosePrecomputedFilter(randomVehicleInfo)
    if not filter and seller.associatedOrganization then
      local org = overhaul_world_organizations.getOrganization(seller.associatedOrganization)
      local level = dependencies.getOrgLevelData(org)
      if level and level.filter then
        filter = level.filter
      end
    end
    filter = filter or (seller.filter or {})
    randomVehicleInfo.filter = filter

    local years = dependencies.validation.safeYearsRange(randomVehicleInfo)

    if not onlyStarterVehicles then
      if years then
        local minYear = years.min
        local filterMinYear = filter.whiteList and filter.whiteList.Years and tonumber(filter.whiteList.Years.min)
        if filterMinYear then
          minYear = math.max(minYear, filterMinYear)
        end
        local maxYear = years.max
        local filterMaxYear = filter.whiteList and filter.whiteList.Years and tonumber(filter.whiteList.Years.max)
        if filterMaxYear then
          maxYear = math.min(maxYear, filterMaxYear)
        end
        if minYear > maxYear then
          error("invalid year bounds after filtering")
        end
        randomVehicleInfo.year = math.random(minYear, maxYear)
      else
        randomVehicleInfo.year = tonumber(randomVehicleInfo.year) or shoppingConfig.missingYearsFallbackModelYear
      end

      randomVehicleInfo.Mileage, randomVehicleInfo.wearMileage, randomVehicleInfo.mileageClass =
        dependencies.generateAgeDrivenMileage(seller, randomVehicleInfo, randomVehicleInfo.year)
      if not randomVehicleInfo.Mileage then return false end
    else
      randomVehicleInfo.year = starterVehicleYears[randomVehicleInfo.model_key]
      if not randomVehicleInfo.year then
        if years then
          randomVehicleInfo.year = math.random(years.min, years.max)
        else
          randomVehicleInfo.year = tonumber(randomVehicleInfo.year) or shoppingConfig.missingYearsFallbackModelYear
        end
      end
      randomVehicleInfo.Mileage = starterVehicleMileages[randomVehicleInfo.model_key] or 100000000
    end
    return true
  end

  local function calculateListingMarketPrice(randomVehicleInfo, seller, vehicleAge, catalogBaseValue, valuation)
    local baseValue = valuation and valuation.bookValue or
      overhaul_career_market_valueCalculator.getVehicleCatalogIntrinsicBookValue({
      catalogBaseValue = catalogBaseValue,
      mileageMeters = randomVehicleInfo.Mileage,
      age = vehicleAge,
      modelName = randomVehicleInfo.model_key,
      configKey = randomVehicleInfo.key,
      partsCatalogSum = randomVehicleInfo.cachedPartsValue,
      logContext = "updateVehicleList",
      applyVehicleBuyMarket = false
    }) or math.max(1500,
      math.floor(overhaul_career_market_valueCalculator.getAdjustedVehicleBaseValue(catalogBaseValue, {
        mileage = randomVehicleInfo.Mileage,
        age = vehicleAge
      }) / 1000) * 1000)
    randomVehicleInfo.valuation = valuation
    if valuation then
      randomVehicleInfo.haloScore = valuation.haloScore
      randomVehicleInfo.haloSignals = valuation.haloSignals
    end

    local range = seller.range
    if seller.associatedOrganization then
      local org = overhaul_world_organizations.getOrganization(seller.associatedOrganization)
      local level = dependencies.getOrgLevelData(org)
      if level and level.range then
        range = level.range
      end
    end

    if seller.id == "private" then
      randomVehicleInfo.negotiationPersonality = overhaul_career_market_marketplace.generatePersonality(false)
      randomVehicleInfo.sellerName = randomVehicleInfo.negotiationPersonality and randomVehicleInfo.negotiationPersonality.name or seller.name
    else
      local personalityKey = seller.negotiationArchetype or seller.id
      randomVehicleInfo.negotiationPersonality = overhaul_career_market_marketplace.generatePersonality(false,
        {personalityKey})
    end

    local randomizedValue, priceBand, dealerPriceMultiplier = dependencies.catalog.getRandomizedPrice(baseValue, range)
    randomVehicleInfo.marketValue = randomizedValue
    randomVehicleInfo.marketValueBase = randomVehicleInfo.marketValue
    randomVehicleInfo.priceRoundingType = seller.priceRoundingType
    randomVehicleInfo.priceBand = priceBand
    randomVehicleInfo.dealerPriceMultiplier = dealerPriceMultiplier

    local priceMultiplier = (randomVehicleInfo.negotiationPersonality and
                              randomVehicleInfo.negotiationPersonality.priceMultiplier) or 1
    return baseValue, priceBand, dealerPriceMultiplier, priceMultiplier
  end

  local function populateListingPrice(randomVehicleInfo, seller)
    local valuationYear = tonumber(os.date("%Y")) or 2026
    local vehicleAge = math.max(0, valuationYear - (tonumber(randomVehicleInfo.year) or valuationYear))
    local catalogBaseValue = randomVehicleInfo.effectiveCatalogValue or randomVehicleInfo.Value
    local valuation = overhaul_career_market_valueCalculator.getVehicleValuation and
      overhaul_career_market_valueCalculator.getVehicleValuation({
        catalogBaseValue = catalogBaseValue,
        mileageMeters = randomVehicleInfo.Mileage,
        age = vehicleAge,
        modelName = randomVehicleInfo.model_key,
        configKey = randomVehicleInfo.key,
        configInfo = randomVehicleInfo,
        partsCatalogSum = randomVehicleInfo.cachedPartsValue,
        logContext = "updateVehicleList",
        applyVehicleBuyMarket = false
      }) or nil
    local baseValue, priceBand, dealerPriceMultiplier, priceMultiplier = calculateListingMarketPrice(
      randomVehicleInfo, seller, vehicleAge, catalogBaseValue, valuation
    )
    priceMultiplier = math.max(0.95, math.min(1.05, tonumber(priceMultiplier) or 1))
    local combinedMultiplier = dealerPriceMultiplier * priceMultiplier
    if priceBand == "lowTail" then
      combinedMultiplier = math.max(0.70, math.min(0.88, combinedMultiplier))
    elseif priceBand == "highTail" then
      combinedMultiplier = math.max(1.12, math.min(1.30, combinedMultiplier))
    else
      combinedMultiplier = math.max(0.88, math.min(1.12, combinedMultiplier))
    end
    randomVehicleInfo.valueBase = baseValue * combinedMultiplier
    randomVehicleInfo.priceMultiplier = priceMultiplier
    randomVehicleInfo.combinedSellerMultiplier = combinedMultiplier

    local vehicleBuyMult = overhaul_career_market_valueCalculator.getVehicleBuyMarketMultiplier()
    randomVehicleInfo.Value = dependencies.getRoundedPrice(randomVehicleInfo.valueBase * vehicleBuyMult,
      seller.priceRoundingType)
  end

  local function applyListingTaxAndParking(randomVehicleInfo, seller, tax)
    if seller.associatedOrganization then
      local org = overhaul_world_organizations.getOrganization(seller.associatedOrganization)
      local level = dependencies.getOrgLevelData(org)
      if level and level.tax ~= nil then
        tax = level.tax
      end
    end
    tax = tonumber(tax)
    randomVehicleInfo.tax = tax or shoppingConfig.salesTax

    if seller.id == "private" then
      local parkingData = overhaul_integration_services_parking.getParkingSpots()
      local parkingSpots = parkingData and parkingData.byName or {}
      local sizeMatches, allowedSpots = {}, {}
      local boxX, boxY, boxZ = dependencies.validation.safeBoundingBoxDimensions(randomVehicleInfo)
      for name, spot in pairs(parkingSpots) do
        local tags = (spot.customFields and spot.customFields.tags) or {}
        if not tags.notprivatesale then
          table.insert(allowedSpots, {
            name = name,
            spot = spot
          })
          if boxX and spot.boxFits and spot:boxFits(boxX, boxY, boxZ) then
            table.insert(sizeMatches, {
              name = name,
              spot = spot
            })
          end
        end
      end

      local pool = (#sizeMatches > 0) and sizeMatches or allowedSpots
      local chosen = nil
      if #pool > 0 then
        chosen = pool[math.random(#pool)]
      end
      if chosen then
        randomVehicleInfo.parkingSpotName = chosen.name
        randomVehicleInfo.pos = chosen.spot.pos
      else
        log("W", "Career",
          string.format("No parking spot available for private sale vehicle %s",
            tostring(randomVehicleInfo.shopId)))
      end
    else
      local dealership = dependencies.getDealershipForSellerId(seller.id)
      randomVehicleInfo.pos = overhaul_world_facilities.getAverageDoorPositionForFacility(dealership)
    end
    return tax
  end

  local function populateListingSaleTerms(randomVehicleInfo, seller, onlyStarterVehicles, currentMap)
    randomVehicleInfo.negotiationPossible = not onlyStarterVehicles
    randomVehicleInfo.shopId = dependencies.generateShopId()
    randomVehicleInfo.associatedOrganization = seller.associatedOrganization
    local dealership = dependencies.getDealershipForSellerId(seller.id)
    local accessInfo = dependencies.getSellerAccessInfo(dealership or seller)
    randomVehicleInfo.remotePurchaseAllowed = accessInfo.remotePurchaseAllowed
    randomVehicleInfo.garageDeliveryAllowed = accessInfo.garageDeliveryAllowed
    randomVehicleInfo.deliveryDiscount = accessInfo.deliveryDiscount

    local fees = seller.fees or 0
    if seller.associatedOrganization then
      local org = overhaul_world_organizations.getOrganization(seller.associatedOrganization)
      local level = dependencies.getOrgLevelData(org)
      if level and level.fees ~= nil then
        fees = level.fees
      end
    end
    fees = tonumber(fees)
    randomVehicleInfo.fees = fees or 0

    local tax = seller.salesTax or shoppingConfig.salesTax
    tax = applyListingTaxAndParking(randomVehicleInfo, seller, tax)

    local vehicleInsuranceClass =
      overhaul_career_repair_insurance.getInsuranceClassFromVehicleShoppingData(randomVehicleInfo)
    if vehicleInsuranceClass then
      randomVehicleInfo.insuranceClass = vehicleInsuranceClass
    end

    randomVehicleInfo.taxExempt = seller.taxExempt
    randomVehicleInfo.stockSchemaVersion = seller.stockSchemaVersion
    randomVehicleInfo.stockPolicy = seller.stockPolicy
    randomVehicleInfo.mapId = currentMap
  end

  -- Stock generation ------------------------------------------------------------------------------
  -- Fills listing slots from the drawn configs; true when a listing or the generation time changed.
  local function insertDrawnStockBatch(
    generation, changed, starterVehicleMileages, starterVehicleYears, targetVehicleCount,
    successfulGenerationsForSeller, nextBatchStartIndex, batchEndIndex
  )
    local seller = generation.seller
    local onlyStarterVehicles = generation.onlyStarterVehicles
    local currentMap = generation.currentMap
    local updateSummary = generation.updateSummary
    for i = nextBatchStartIndex, batchEndIndex do
      if successfulGenerationsForSeller >= targetVehicleCount then
        break
      end

      local randomVehicleInfo = generation.randomVehicleInfos[i]
      updateSummary.attempted = updateSummary.attempted + 1
      if dependencies.validation.isQuarantined(randomVehicleInfo) then
        updateSummary.dropped = updateSummary.dropped + 1
        dependencies.validation.incrementValidationStat("generationDropped")
      else
        local shapeOk, shapeReason = dependencies.validation.isValidVehicleInfoShape(randomVehicleInfo)
        if not shapeOk then
          dependencies.validation.quarantineVehicleConfig(randomVehicleInfo, shapeReason, "updateVehicleList")
          updateSummary.dropped = updateSummary.dropped + 1
          dependencies.validation.incrementValidationStat("generationDropped")
        else
          local generatedVehicle, err = dependencies.validation.safeVehicleOp("updateVehicleList", randomVehicleInfo, function()
            randomVehicleInfo.generationTime = generation.currentTime - (successfulGenerationsForSeller * generation.adjustedOfferIntervalSeconds)
            randomVehicleInfo.offerTTL = onlyStarterVehicles and math.huge or shoppingConfig.vehicleOfferTimeToLive

            randomVehicleInfo.sellerId = seller.id
            randomVehicleInfo.sellerName = seller.name
            randomVehicleInfo.salesChannel = seller.salesChannel or (seller.id == "private" and "private" or "local")

            if not populateListingCondition(randomVehicleInfo, seller, onlyStarterVehicles, starterVehicleMileages, starterVehicleYears) then
              return nil
            end
            populateListingPrice(randomVehicleInfo, seller)
            populateListingSaleTerms(randomVehicleInfo, seller, onlyStarterVehicles, currentMap)
            return randomVehicleInfo
          end)

          if err or not generatedVehicle then
            updateSummary.dropped = updateSummary.dropped + 1
            dependencies.validation.incrementValidationStat("generationDropped")
          else
            table.insert(state.vehiclesInShop, generatedVehicle)
            if generatedVehicle.sellerId and not generatedVehicle.soldViewCounter then
              local unsoldCountBySellerId = generation.unsoldCountBySellerId
              unsoldCountBySellerId[generatedVehicle.sellerId] = (unsoldCountBySellerId[generatedVehicle.sellerId] or 0) + 1
              local model = generatedVehicle.model_key
              if model then generation.stockedModels[model] = (generation.stockedModels[model] or 0) + 1 end
            end
            changed = true
            updateSummary.inserted = updateSummary.inserted + 1
            successfulGenerationsForSeller = successfulGenerationsForSeller + 1
          end
        end
      end
    end
    return changed, successfulGenerationsForSeller
  end

  local function fillSellerStockListings(generation)
    local seller, onlyStarterVehicles = generation.seller, generation.onlyStarterVehicles
    local currentTime = generation.currentTime
    local randomVehicleInfos, numberOfVehiclesToGenerate = generation.randomVehicleInfos, generation.numberOfVehiclesToGenerate
    local changed = false
    local starterVehicleMileages = {bx = 165746239, etki = 285817342, covet = 80174611}
    local starterVehicleYears = {bx = 1990, etki = 1989, covet = 1989}
    local targetVehicleCount = onlyStarterVehicles and tableSize(randomVehicleInfos) or numberOfVehiclesToGenerate
    local successfulGenerationsForSeller = 0
    local replacementCycles = 0
    local maxReplacementCycles = onlyStarterVehicles and 0 or 2
    local nextBatchStartIndex = 1
    local attemptedGenerationForSeller = false

    if onlyStarterVehicles then
      attemptedGenerationForSeller = not tableIsEmpty(randomVehicleInfos)
    elseif numberOfVehiclesToGenerate > 0 then
      attemptedGenerationForSeller = true
    end

    while nextBatchStartIndex <= #randomVehicleInfos and successfulGenerationsForSeller < targetVehicleCount do
      local batchEndIndex = #randomVehicleInfos
      changed, successfulGenerationsForSeller = insertDrawnStockBatch(
        generation, changed, starterVehicleMileages, starterVehicleYears, targetVehicleCount,
        successfulGenerationsForSeller, nextBatchStartIndex, batchEndIndex
      )

      nextBatchStartIndex = batchEndIndex + 1
      if successfulGenerationsForSeller >= targetVehicleCount or replacementCycles >= maxReplacementCycles then
        break
      end

      local replacementCount = targetVehicleCount - successfulGenerationsForSeller
      if replacementCount <= 0 then
        break
      end

      replacementCycles = replacementCycles + 1
      local replacementVehicles = generation.drawUnstockedSellerVehicles(replacementCount)
      if tableIsEmpty(replacementVehicles) then
        break
      end

      attemptedGenerationForSeller = true
      arrayConcat(randomVehicleInfos, replacementVehicles)
    end
    if successfulGenerationsForSeller >= targetVehicleCount then
      state.sellersInfos[seller.id].lastGenerationTime = currentTime
      changed = true
    elseif attemptedGenerationForSeller and targetVehicleCount == 0 then
      state.sellersInfos[seller.id].lastGenerationTime = currentTime
      changed = true
    end
    return changed
  end

  local function resolveSellerStockPolicy(seller)
    local currentOrgLevel = nil
    if seller.associatedOrganization then
      local org = overhaul_world_organizations.getOrganization(seller.associatedOrganization)
      if org and org.reputation then
        local repLevel = org.reputation.level or 0
        if type(repLevel) ~= "number" then
          repLevel = 0
        end
        currentOrgLevel = repLevel
      end
    end

    local storedLevel = state.sellersInfos[seller.id].lastOrgLevel
    local levelChanged = (currentOrgLevel ~= nil) and (storedLevel ~= nil) and (storedLevel ~= currentOrgLevel)

    local maxStock = tonumber(seller.stock) or 10
    if seller.associatedOrganization then
      local org = overhaul_world_organizations.getOrganization(seller.associatedOrganization)
      local level = dependencies.getOrgLevelData(org)
      local levelStock = level and tonumber(level.stock) or nil
      if levelStock then
        maxStock = levelStock
      end
    end
    maxStock = math.max(math.floor(maxStock), 1)
    return currentOrgLevel, storedLevel, levelChanged, maxStock
  end

  local function selectSellerRestockBatch(
    seller, fromScratch, onlyStarterVehicles, currentTime, randomVehicleInfos,
    drawUnstockedSellerVehicles, currentOrgLevel, storedLevel, levelChanged, maxStock,
    availableSlots, numberOfVehiclesToGenerate
  )
    local adjustedOfferIntervalSeconds = shoppingConfig.vehicleOfferTimeToLive / maxStock
    local generationMultiplier = tonumber(seller.vehicleGenerationMultiplier)
    if generationMultiplier and generationMultiplier > 0 then
      adjustedOfferIntervalSeconds = adjustedOfferIntervalSeconds / generationMultiplier
    end

    if onlyStarterVehicles then
      local eligibleVehiclesStarterRaw = util_configListGenerator.getEligibleVehicles(onlyStarterVehicles) or {}
      local eligibleVehiclesStarter, starterSummary = dependencies.validation.sanitizeVehicleInfoList(eligibleVehiclesStarterRaw,
        "updateVehicleList:starterEligible", "generationDropped")
      if starterSummary.malformed > 0 or starterSummary.quarantined > 0 then
        dependencies.validation.logVehicleSanitizationSummary("updateVehicleList starter eligible vehicles", starterSummary)
      end
      randomVehicleInfos = util_configListGenerator.getRandomVehicleInfos(seller, 3, eligibleVehiclesStarter,
        "adjustedPopulation") or {}
    else
      -- vehicleGenerationMultiplier lowers the time between offers
      local maxVehicles = math.floor(shoppingConfig.vehicleOfferTimeToLive / adjustedOfferIntervalSeconds)
      numberOfVehiclesToGenerate = math.min(math.floor((currentTime - state.sellersInfos[seller.id].lastGenerationTime) / adjustedOfferIntervalSeconds), maxVehicles)

      if levelChanged then
        dependencies.catalog.rebuildDealershipCache(seller.id)
        numberOfVehiclesToGenerate = availableSlots
        state.sellersInfos[seller.id].lastGenerationTime = 0
        log("I", "Career", string.format("Level changed for %s (from %d to %d), restocking to %d vehicles",
          seller.id, storedLevel, currentOrgLevel, availableSlots))
      elseif fromScratch or state.sellersInfos[seller.id].lastGenerationTime == 0 then
        numberOfVehiclesToGenerate = availableSlots
        log("D", "Career",
          string.format("Initial stock fill for %s: generating %d vehicles", seller.id, numberOfVehiclesToGenerate))
      elseif availableSlots > 0 and numberOfVehiclesToGenerate < availableSlots then
        numberOfVehiclesToGenerate = availableSlots
        log("D", "Career",
          string.format("Stock below target for %s: generating %d vehicles to reach %d", seller.id, availableSlots, maxStock))
      end

      numberOfVehiclesToGenerate = math.max(0, math.min(numberOfVehiclesToGenerate, availableSlots))
      -- Generate unique configurations that are not already stocked by this seller.
      local newRandomVehicleInfos = drawUnstockedSellerVehicles(numberOfVehiclesToGenerate)
      arrayConcat(randomVehicleInfos, newRandomVehicleInfos)

      local numberOfMissingVehicles = numberOfVehiclesToGenerate - tableSize(newRandomVehicleInfos)
      if numberOfMissingVehicles > 0 then
        log("W", "Career", string.format(
          "Seller %s is short %d unique eligible configurations; leaving those stock slots empty",
          tostring(seller.id), numberOfMissingVehicles))
      end
    end
    return randomVehicleInfos, numberOfVehiclesToGenerate, adjustedOfferIntervalSeconds
  end

  local function generateSellerStock(seller, fromScratch, currentMap, onlyStarterVehicles, currentTime,
      updateSummary, sellerMeta, unsoldCountBySellerId)
    local changed = false
    local sellerAttemptedStart = updateSummary.attempted
    local sellerInsertedStart = updateSummary.inserted
    local sellerDroppedStart = updateSummary.dropped
    local dealershipData = state.vehicleCache.dealershipCache[seller.id]
    if dealershipData and dealershipData.notConfigured then
      return false
    end

    if not state.sellersInfos[seller.id] then
      state.sellersInfos[seller.id] = {
        lastGenerationTime = 0,
        mapId = currentMap,
        lastOrgLevel = nil
      }
      changed = true
    end
    if fromScratch then
      state.sellersInfos[seller.id].lastGenerationTime = 0
    end
    state.sellersInfos[seller.id].lastGenerationTime = math.min(tonumber(state.sellersInfos[seller.id].lastGenerationTime) or 0, currentTime) -- guard against OS clock adjusted back in time

    local randomVehicleInfos = {}
    local currentVehicleCount = unsoldCountBySellerId[seller.id] or 0
    local stockedConfigKeys = {}
    local stockedModels = {}
    local modelLimit = tonumber(seller.maxStockPerModel)
    if not modelLimit or modelLimit ~= modelLimit or modelLimit == math.huge then
      modelLimit = seller.salesChannel == "factory" and 0 or 3
    end
    modelLimit = math.max(0, math.floor(modelLimit))
    for _, stockedVehicle in ipairs(state.vehiclesInShop) do
      if stockedVehicle.sellerId == seller.id and not stockedVehicle.soldViewCounter then
        stockedConfigKeys[dependencies.validation.getVehicleConfigTrackingKey(stockedVehicle)] = true
        local model = stockedVehicle.model_key
        if model then stockedModels[model] = (stockedModels[model] or 0) + 1 end
      end
    end

    local function drawUnstockedSellerVehicles(drawCount)
      local selected = dependencies.catalog.getRandomVehicleFromCache(seller.id, drawCount, stockedConfigKeys, modelLimit, stockedModels)
      for _, selectedVehicle in ipairs(selected) do
        stockedConfigKeys[dependencies.validation.getVehicleConfigTrackingKey(selectedVehicle)] = true
      end
      return selected
    end

    local currentOrgLevel, storedLevel, levelChanged, maxStock = resolveSellerStockPolicy(seller)
    local availableSlots = math.max(0, maxStock - currentVehicleCount)

    local numberOfVehiclesToGenerate = 0
    local adjustedOfferIntervalSeconds
    randomVehicleInfos, numberOfVehiclesToGenerate, adjustedOfferIntervalSeconds = selectSellerRestockBatch(
      seller, fromScratch, onlyStarterVehicles, currentTime, randomVehicleInfos,
      drawUnstockedSellerVehicles, currentOrgLevel, storedLevel, levelChanged, maxStock,
      availableSlots, numberOfVehiclesToGenerate
    )

    local generation = {
      seller = seller,
      onlyStarterVehicles = onlyStarterVehicles,
      currentMap = currentMap,
      currentTime = currentTime,
      adjustedOfferIntervalSeconds = adjustedOfferIntervalSeconds,
      randomVehicleInfos = randomVehicleInfos,
      numberOfVehiclesToGenerate = numberOfVehiclesToGenerate,
      stockedModels = stockedModels,
      unsoldCountBySellerId = unsoldCountBySellerId,
      updateSummary = updateSummary,
      drawUnstockedSellerVehicles = drawUnstockedSellerVehicles,
    }
    if fillSellerStockListings(generation) then changed = true end
    if updateSummary.attempted > sellerAttemptedStart then
      log("I", "Career", string.format("updateVehicleList seller %s: attempted=%d inserted=%d dropped=%d",
        tostring(seller.id),
        updateSummary.attempted - sellerAttemptedStart,
        updateSummary.inserted - sellerInsertedStart,
        updateSummary.dropped - sellerDroppedStart))
    end

    if currentOrgLevel ~= nil then
      state.sellersInfos[seller.id].lastOrgLevel = currentOrgLevel
    end

    sellerMeta[seller.id] = {
      maxStock = maxStock,
      adjustedTimeBetweenOffers = adjustedOfferIntervalSeconds
    }
    return changed
  end

  local function refreshSellerListings(
    fromScratch, currentMap, onlyStarterVehicles, changed, updateSummary, facilitiesData
  )
    local sellers = listingMaintenance.collectSellers(facilitiesData, onlyStarterVehicles)

    if dependencies.validation.pruneBlacklistedSellerStock(sellers) > 0 then
      changed = true
    end

    local currentTime = os.time()

    local protectedShopId
    local spawnedVehicleInfo = overhaul_career_market_inspectVehicle.getSpawnedVehicleInfo()
    if spawnedVehicleInfo then
      protectedShopId = spawnedVehicleInfo.shopId
    end

    local expiredChanged, justExpiredShopIds = listingMaintenance.expireOffers(currentTime, protectedShopId)
    if expiredChanged then changed = true end

    local duplicatesChanged, unsoldCountBySellerId = listingMaintenance.removeDuplicateStock()
    if duplicatesChanged then changed = true end

    local sellerMeta = {}

    for _, seller in ipairs(sellers) do
      if generateSellerStock(seller, fromScratch, currentMap, onlyStarterVehicles, currentTime,
          updateSummary, sellerMeta, unsoldCountBySellerId) then
        changed = true
      end
    end

    listingMaintenance.scheduleNextUpdate(sellers, sellerMeta, unsoldCountBySellerId, currentTime)
    return changed, justExpiredShopIds
  end

  service.updateVehicleList = function(fromScratch)
    fromScratch = not not fromScratch
    local currentMap = getCurrentLevelIdentifier()
    local onlyStarterVehicles = not overhaul_career_career.hasBoughtStarterVehicle()
    local changed = false
    local updateSummary = {
      attempted = 0,
      inserted = 0,
      dropped = 0
    }

    if fromScratch then
      dependencies.catalog.invalidateVehicleCache()
      state.vehiclesInShop = {}
      state.sellersInfos = {}
      state.vehicleWatchlist = {}
      changed = true
    end

    -- Keep the initial starter selection stable until the player buys one.
    if onlyStarterVehicles and not tableIsEmpty(state.vehiclesInShop) then
      state.nextShopUpdateTime = os.time() + 3600
      return
    end

    if listingMaintenance.retainCurrentMapStock(currentMap) then changed = true end

    if not state.vehicleCache.cacheValid then
      dependencies.catalog.cacheDealers()
      changed = true
    end

    local facilitiesData = overhaul_world_facilities.getFacilities(getCurrentLevelIdentifier())
    if not facilitiesData then
      log("W", "Career", "No facilities data available for current map; skipping vehicle list update")
      state.nextShopUpdateTime = os.time() + 60
      return
    end
    local justExpiredShopIds
    changed, justExpiredShopIds = refreshSellerListings(
      fromScratch, currentMap, onlyStarterVehicles, changed, updateSummary, facilitiesData
    )

    if not changed then
      return
    end

    state.vehicleShopDirtyDate = os.date("!%Y-%m-%dT%H:%M:%SZ")
    log("I", "Career", "Vehicles in shop: " .. tableSize(state.vehiclesInShop))
    log("I", "Career", string.format("updateVehicleList summary: attempted=%d inserted=%d dropped=%d",
      updateSummary.attempted, updateSummary.inserted, updateSummary.dropped))

    local newSnap = dependencies.buildSnapshot()
    dependencies.commitDelta(newSnap, justExpiredShopIds)
    guihooks.trigger("vehicleShopDelta", state.lastDelta)
  end

  function service.bindServices(bindings)
    assert(type(bindings.buildSnapshot) == "function", "stock requires buildSnapshot")
    assert(type(bindings.commitDelta) == "function", "stock requires commitDelta")
    assert(type(bindings.generateAgeDrivenMileage) == "function", "stock requires generateAgeDrivenMileage")
    assert(type(bindings.generateShopId) == "function", "stock requires generateShopId")
    assert(type(bindings.getDealershipForSellerId) == "function", "stock requires getDealershipForSellerId")
    assert(type(bindings.getOrgLevelData) == "function", "stock requires getOrgLevelData")
    assert(type(bindings.getRoundedPrice) == "function", "stock requires getRoundedPrice")
    assert(type(bindings.getSellerAccessInfo) == "function", "stock requires getSellerAccessInfo")
    assert(type(bindings.catalog.cacheDealers) == "function", "stock requires catalog.cacheDealers")
    assert(type(bindings.catalog.choosePrecomputedFilter) == "function", "stock requires catalog.choosePrecomputedFilter")
    assert(type(bindings.catalog.getRandomVehicleFromCache) == "function", "stock requires catalog.getRandomVehicleFromCache")
    assert(type(bindings.catalog.getRandomizedPrice) == "function", "stock requires catalog.getRandomizedPrice")
    assert(type(bindings.catalog.invalidateVehicleCache) == "function", "stock requires catalog.invalidateVehicleCache")
    assert(type(bindings.catalog.rebuildDealershipCache) == "function", "stock requires catalog.rebuildDealershipCache")
    assert(type(bindings.validation.getVehicleConfigTrackingKey) == "function", "stock requires validation.getVehicleConfigTrackingKey")
    assert(type(bindings.validation.incrementValidationStat) == "function", "stock requires validation.incrementValidationStat")
    assert(type(bindings.validation.isQuarantined) == "function", "stock requires validation.isQuarantined")
    assert(type(bindings.validation.isValidVehicleInfoShape) == "function", "stock requires validation.isValidVehicleInfoShape")
    assert(type(bindings.validation.logVehicleSanitizationSummary) == "function", "stock requires validation.logVehicleSanitizationSummary")
    assert(type(bindings.validation.pruneBlacklistedSellerStock) == "function", "stock requires validation.pruneBlacklistedSellerStock")
    assert(type(bindings.validation.quarantineVehicleConfig) == "function", "stock requires validation.quarantineVehicleConfig")
    assert(type(bindings.validation.safeBoundingBoxDimensions) == "function", "stock requires validation.safeBoundingBoxDimensions")
    assert(type(bindings.validation.safeVehicleOp) == "function", "stock requires validation.safeVehicleOp")
    assert(type(bindings.validation.safeYearsRange) == "function", "stock requires validation.safeYearsRange")
    assert(type(bindings.validation.sanitizeVehicleInfoList) == "function", "stock requires validation.sanitizeVehicleInfoList")
    dependencies = bindings
    listingMaintenance.bindServices {
      isPoliceDealershipLocked = bindings.isPoliceDealershipLocked,
      isCarMeetShopVehicle = bindings.isCarMeetShopVehicle,
      normalizeVehicleShopTiming = bindings.normalizeVehicleShopTiming,
      generateSoldVehicleValue = bindings.generateSoldVehicleValue,
      getVehicleConfigTrackingKey = bindings.validation.getVehicleConfigTrackingKey,
    }
  end
  return service
end

return M
