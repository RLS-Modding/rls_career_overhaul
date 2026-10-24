-- Engine retail: shop catalogs, seeded listings and install work orders.
-- Read the named sections below in order; the final API binds the owner's game hooks.

-- The career owns stock and job state; this extension handles the shop screen and purchase lifecycle.

local M = {}

local jbeamIO = require("jbeam/io")
local jbeamSlotSystem = require("jbeam/slotSystem")
local devScope = require("overhaul/lib/lifecycle/scopes/dev")
local levelData = require("overhaul/lib/world/levelData")
-- Config -------------------------------------------------------------------------------------------

local logTag = "engineRetail"
local SAVE_PATH = "/career/rls_career/engineRetail.json"
local STOCK_LIFETIME_SIM_S = 1800
local RESTOCK_INTERVAL_SIM_S = 300
local CATALOG_VERSION = 11
local RETAIL_MARKUP_FRACTION = 0.15
local CACHE_LIMIT = 256
local RECIPE_CACHE_LIMIT = 32
local METERS_PER_MILE = 1609.344

-- Used-listing rolls: age, mileage and wear. Factory engines are kept younger and in better shape.
local listingTuning = {
  factoryMaxAgeYears = 6,
  aftermarketMaxAgeYears = 10,
  ageCurveExponent = 0.85,
  annualMileageBaseMiles = 4000,
  annualMileageRangeMiles = 6000,
  minimumMileageMiles = 1500,
  mileageJitterBaseFactor = 0.82,
  mileageJitterRangeFactor = 0.36,
  startingIntegrityFraction = 0.98,
  maximumUsedIntegrityFraction = 0.97,
  integrityNoiseFraction = 0.06,
  ageWearFractionAtMaximumAge = 0.06,
  mileageWearFractionPer100kMiles = 0.12,
  modificationWearFraction = 0.04,
  factoryMinimumIntegrityFraction = 0.84,
  aftermarketMinimumIntegrityFraction = 0.80,
}

-- Listing payment and install pricing.
local installPricing = {
  minimumInstallFee = 350,
  installFeeFraction = 0.06,
  minimumDurationSeconds = 300,
  maximumDurationSeconds = 600,
  secondsPerPartNode = 12,
  tradeInFraction = 0.7,
  certificationFeeFraction = 0.10,
}

local reliabilityOrder = {Reliable = 1, Fair = 2, Risky = 3, Questionable = 4}
local categoryOrder = {factory = 1, aftermarket = 2}
local definingEngineTokens = {"engine", "internal", "intake", "turbo", "supercharger", "ecu", "exhaust",
  "head", "block", "piston", "camshaft", "carb", "injection", "nitro", "n2o"}
local excludedEngineTokens = {"mount", "oilpan", "radiator", "cooler", "flywheel"}
local blockedWhileWorkOrderRuns = {vehicleSelling = true, vehicleRepair = true, vehicleStoring = true,
  partSwapping = true, partBuying = true, tuning = true, painting = true, vehicleModification = true,
  vehicleLicensePlate = true, junkVehicle = true, recoveryTowToGarage = true, interactMission = true}

-- State -------------------------------------------------------------------------------------------

local function emptyState()
  return {activeSeconds = 0, nextListingId = 1, shops = {}, jobs = {}}
end

-- Saved with the career: stock per shop and model, install and cancel jobs, and the active-time clock.
local state = emptyState()
local shopsByMap = {}
local recipeCache = {}
local analysisCache = {}
local valueCache = {}
local menuContext
local initialized = false
local updateAccumulator = 0

-- Shared helpers ----------------------------------------------------------------------------------

local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local function round25(value) return math.floor((tonumber(value) or 0) / 25 + 0.5) * 25 end

local function shuffle(values)
  for index = #values, 2, -1 do
    local swap = math.random(index)
    values[index], values[swap] = values[swap], values[index]
  end
end

local function isPaused()
  return simTimeAuthority.getPause() == true
end

local function displayName(description)
  if type(description) == "table" then return description.description or description.name end
  return description
end

local function refreshPoiMarkers()
  if gameplay_rawPois then gameplay_rawPois.clear() end
end

local function failure(message)
  return {success = false, message = message}
end

-- Shops and save data -----------------------------------------------------------------------------

local function loadShopDefinitions(mapId)
  mapId = mapId or getCurrentLevelIdentifier()
  if mapId then mapId = levelData.resolveAlias("map", mapId) end
  if not mapId or mapId == "" then return {} end
  if shopsByMap[mapId] then return shopsByMap[mapId] end
  local shops = {}
  for _, definition in ipairs(overhaul_world_facilities.getFacilitiesByType("engineRetail", mapId) or {}) do
    local shop = deepcopy(definition)
    shop.mapId = mapId
    if type(shop.id) == "string" and type(shop.name) == "string" and type(shop.sitesFile) == "string"
      and type(shop.serviceSpotName) == "string" and type(shop.pickupSpotName) == "string" then
      shops[tostring(shop.id)] = shop
    else
      log("W", logTag, "Ignoring retailer without sites/service/pickup: " .. tostring(shop.id))
    end
  end
  shopsByMap[mapId] = shops
  return shops
end

local function shopById(shopId, mapId)
  mapId = levelData.resolveAlias("map", mapId or getCurrentLevelIdentifier())
  shopId = levelData.resolveAlias("engineRetail", tostring(shopId), {levelId = mapId})
  return loadShopDefinitions(mapId)[shopId]
end

local function currentMenuShop()
  if menuContext and menuContext.mapId == getCurrentLevelIdentifier() then
    return shopById(menuContext.shopId, menuContext.mapId)
  end
end

local function shopForJob(job)
  return job and job.mapId and shopById(job.shopId, job.mapId)
end

local function saveData(savePath)
  if not savePath then return end
  overhaul_career_saveSystem.jsonWriteFileSafe(savePath .. SAVE_PATH, {version = 1, state = state}, true)
end

-- Listings that expired while the career was closed are dropped, and so are their empty model slots.
local function pruneExpiredStock()
  for _, shopState in pairs(state.shops) do
    if type(shopState) == "table" and type(shopState.models) == "table" then
      for stockKey, stock in pairs(shopState.models) do
        local live = false
        for _, listing in ipairs(type(stock) == "table" and stock.listings or {}) do
          if state.activeSeconds < (tonumber(listing.expiresAtActive) or 0) then live = true break end
        end
        if not live then shopState.models[stockKey] = nil end
      end
    end
  end
end

local function normalizeLoadedState(data)
  state = type(data and data.state) == "table" and data.state or emptyState()
  state.activeSeconds = math.max(0, tonumber(state.activeSeconds) or 0)
  state.nextListingId = math.max(1, math.floor(tonumber(state.nextListingId) or 1))
  state.shops = type(state.shops) == "table" and state.shops or {}
  state.jobs = type(state.jobs) == "table" and state.jobs or {}
end

-- Historical ownership survives travel; ambiguous or missing retailers leave paid orders unbound.
local function legacyShopMap(shopId, saveVersion)
  local mapId, alias = levelData.resolveAlias("engineRetailOwnerMap", shopId,
    {facilityId = shopId, saveVersion = saveVersion})
  if alias then return levelData.resolveAlias("map", mapId) end
  local owner
  for id in pairs(levelData.loadMaps()) do
    if shopById(shopId, id) then
      if owner and owner ~= id then return nil end
      owner = id
    end
  end
  return owner
end

local function resolveJobOwnership(job, saveVersion)
  local shopId = tostring(job.shopId)
  local mapId = job.mapId or legacyShopMap(shopId, tonumber(job.legacyOwnershipVersion) or saveVersion)
  if not mapId then
    job.legacyOwnershipVersion = tonumber(job.legacyOwnershipVersion) or saveVersion
    log("W", logTag, "Paid work order retained without a resolved retailer map: " .. shopId)
    return
  end
  job.mapId = levelData.resolveAlias("map", mapId)
  job.shopId = levelData.resolveAlias("engineRetail", shopId, {levelId = job.mapId, saveVersion = saveVersion})
  job.legacyOwnershipVersion = nil
end

local function loadData()
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  local data = savePath and jsonReadFile(savePath .. SAVE_PATH) or nil
  normalizeLoadedState(data)
  local movedStock = {}
  for key, stock in pairs(state.shops) do
    local mapId, shopId = key:match("^([^|]+)|(.+)$")
    if mapId then
      mapId = levelData.resolveAlias("map", mapId)
      shopId = levelData.resolveAlias("engineRetail", shopId,
        {levelId = mapId, saveVersion = tonumber(data and data.version) or 0})
      local target = mapId .. "|" .. shopId
      movedStock[target] = movedStock[target] or state.shops[target] or stock
    else
      movedStock[key] = stock
    end
  end
  local saveVersion = tonumber(data and data.version) or 0
  local normalizedStock = {}
  for key, stock in pairs(movedStock) do
    if key:find("|", 1, true) then normalizedStock[key] = stock end
  end
  for shopId, stock in pairs(movedStock) do
    if not shopId:find("|", 1, true) then
      local ownerMap = legacyShopMap(shopId, saveVersion)
      if ownerMap then
        local id = levelData.resolveAlias("engineRetail", shopId, {levelId = ownerMap, saveVersion = saveVersion})
        local key = ownerMap .. "|" .. id
        normalizedStock[key] = normalizedStock[key] or stock
      else
        normalizedStock[shopId] = stock
      end
    end
  end
  state.shops = normalizedStock
  for _, job in pairs(state.jobs) do resolveJobOwnership(job, saveVersion) end
  pruneExpiredStock()
end

local function sitesForShop(shop)
  if not shop then return nil end
  return gameplay_sites_sitesManager.loadSites(levelData.assetPath(shop.mapId, shop.sitesFile))
end

local function spotFor(shop, key)
  local sites = sitesForShop(shop)
  local name = shop and shop[key]
  local spot = sites and name and sites.parkingSpots and sites.parkingSpots.byName
    and sites.parkingSpots.byName[name]
  if spot and not spot.missing then return spot end
  if shop then log("W", logTag, "Retailer spot unavailable: " .. tostring(shop.id) .. "/" .. tostring(name)) end
end

-- Vehicle configuration helpers -------------------------------------------------------------------

local function getConfigType(info)
  local value = info and (info["Config Type"] or (info.aggregates and info.aggregates["Config Type"]))
  if type(value) == "string" then return value end
  if type(value) == "table" then for key, enabled in pairs(value) do if enabled then return tostring(key) end end end
end

local function configCategory(info)
  return string.lower(tostring(getConfigType(info) or "")) == "factory" and "factory" or "aftermarket"
end

local function configPopulation(info)
  local value = info and (info.Population or info.population or (info.aggregates and info.aggregates.Population))
  if type(value) == "table" then value = value.max or value.value or value.min end
  -- A square-root curve lets common configurations appear more often without making rare and mod-authored configurations effectively impossible to see.
  return math.sqrt(math.max(1, tonumber(value) or 100))
end

-- Exponential-race keys produce a population-weighted shuffle without replacement.
local function populationWeightedOrder(values)
  local ranked = {}
  for _, info in ipairs(values or {}) do
    local roll = math.max(0.000000001, math.random())
    ranked[#ranked + 1] = {info = info, score = -math.log(roll) / configPopulation(info)}
  end
  table.sort(ranked, function(a, b) return a.score < b.score end)
  local result = {}
  for _, entry in ipairs(ranked) do result[#result + 1] = entry.info end
  return result
end

local function configPath(info)
  local key, model = tostring(info.key or ""), tostring(info.model_key or "")
  key = key:gsub("\\", "/")
  if key:sub(-3) == ".pc" then return key:sub(1, 1) == "/" and key or "/" .. key end
  local direct = string.format("/vehicles/%s/%s.pc", model, key)
  if FS:fileExists(direct) then return direct end
  return string.format("/vehicles/%s/configurations/%s.pc", model, key)
end

-- Recipes from vehicle trees -----------------------------------------------------------------------

local function findEngineNode(tree, ioCtx)
  return overhaul_career_parts_engines_enginePackages.findEngineAssemblyCandidates(tree, false, ioCtx)[1]
end

local function recipeNode(node, slotName)
  local result = {name = node.chosenPartName, slotName = slotName or node.id, children = {}}
  for childSlot, child in pairs(node.children or {}) do
    if child.chosenPartName and child.chosenPartName ~= "" then result.children[childSlot] = recipeNode(child, childSlot) end
  end
  return result
end

local function nicePartName(ioCtx, name)
  local info = (jbeamIO.getAvailableParts(ioCtx) or {})[name] or {}
  local description = displayName(info.description)
  return type(description) == "string" and description or name
end

local function findTransmissionNode(tree)
  for slotName, child in pairs(tree and tree.children or {}) do
    if string.find(string.lower(tostring(slotName)), "transmission", 1, true) then return tree, slotName, child end
    local parent, key, found = findTransmissionNode(child)
    if found then return parent, key, found end
  end
end

-- Parts that define the engine build, sorted by slot. The root always counts; excluded accessories do not.
local function collectDefiningParts(recipe)
  local parts = {}
  local function visit(node, slotName, isRoot)
    if not node then return end
    local normalizedSlot = string.lower(tostring(slotName or node.slotName or ""))
    if string.find(normalizedSlot, "transmission", 1, true) then return end
    local text = normalizedSlot .. " " .. string.lower(tostring(node.name or ""))
    local excluded, defining = false, isRoot == true
    for _, token in ipairs(excludedEngineTokens) do
      if string.find(text, token, 1, true) then excluded = true; break end
    end
    if not excluded and not defining then
      for _, token in ipairs(definingEngineTokens) do
        if string.find(text, token, 1, true) then defining = true; break end
      end
    end
    if defining and not excluded then
      parts[#parts + 1] = {slotName = tostring(slotName or node.slotName or ""), name = tostring(node.name or "")}
    end
    for childSlot, child in pairs(node.children or {}) do visit(child, childSlot, false) end
  end
  visit(recipe and recipe.tree, recipe and recipe.rootSlotName, true)
  table.sort(parts, function(a, b)
    local left, right = a.slotName .. "=" .. a.name, b.slotName .. "=" .. b.name
    return left < right
  end)
  return parts
end

-- Category identity follows the engine build, not the source vehicle. A transmission may vary while the engine stays factory-equivalent, so the transmission branch is left out of the signature.
local function engineBuildSignature(recipe)
  return overhaul_career_parts_engines_enginePackages.computeRecipeSignature({
    vehicleModel = recipe and recipe.vehicleModel,
    rootEngineName = recipe and recipe.rootEngineName,
    parts = collectDefiningParts(recipe),
    tuning = deepcopy(recipe and recipe.tuning or {})
  })
end

-- Whether the shop's catalog tokens match the recipe's engine, parts or descriptions.
local function shopAllowsRecipe(shop, info, recipe, ioCtx)
  if shop.catalogMode ~= "filtered" then return true end
  local pieces = {tostring(configPath(info)), tostring(info.Name or ""), tostring(recipe.rootEngineName or ""),
    tostring(recipe.rootEngineNiceName or "")}
  local available = ioCtx and jbeamIO.getAvailableParts(ioCtx) or {}
  local function visit(node)
    if not node then return end
    pieces[#pieces + 1] = tostring(node.name or "")
    pieces[#pieces + 1] = tostring(displayName(available[node.name] and available[node.name].description) or "")
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(recipe.tree)
  local haystack = string.lower(table.concat(pieces, " "))
  for _, token in ipairs(shop.catalogTokens or {}) do
    if string.find(haystack, string.lower(tostring(token)), 1, true) then return true end
  end
  return false
end

local function configInfoMatchesCatalog(shop, info)
  if shop.catalogMode ~= "filtered" then return true end
  local haystack = string.lower(table.concat({tostring(configPath(info)), tostring(info.Name or ""),
    tostring(info.Source or ""), tostring(info.SourceId or ""), tostring(info.modID or "")}, " "))
  for _, token in ipairs(shop.catalogTokens or {}) do
    if string.find(haystack, string.lower(tostring(token)), 1, true) then return true end
  end
  return false
end

-- JBeam inspection is shop-time work, never per-frame work. The result is pure for a recipe signature, so it is reused across listings and UI refreshes.
local function analyzeRecipe(recipe, ioCtx)
  local signature = recipe and (recipe.signature or overhaul_career_parts_engines_enginePackages.computeRecipeSignature(recipe))
  if signature and analysisCache[signature] then return deepcopy(analysisCache[signature]) end
  local analysis, err = overhaul_career_parts_engines_engineCertification.analyzeRecipe(recipe, ioCtx)
  if analysis and analysis.result == "unknown" then return nil, analysis.reason end
  if analysis and signature then
    if tableSize(analysisCache) >= CACHE_LIMIT then table.clear(analysisCache) end
    analysisCache[signature] = deepcopy(analysis)
  end
  return analysis, err
end

local function recipeValue(recipe, ioCtx)
  local signature = recipe and (recipe.signature or overhaul_career_parts_engines_enginePackages.computeRecipeSignature(recipe))
  if signature and valueCache[signature] then return valueCache[signature] end
  local value, err = overhaul_career_parts_engines_enginePackages.getFreshRecipeValue(recipe, ioCtx)
  if value and signature then
    if tableSize(valueCache) >= CACHE_LIMIT then table.clear(valueCache) end
    valueCache[signature] = value
  end
  return value, err
end

-- Config candidates for a vehicle model. Filtered shops try their own catalog first; within each group configurations are population-weighted.
local function orderCandidates(shop, values)
  if shop.catalogMode ~= "filtered" then return populationWeightedOrder(values) end
  local preferred, fallback = {}, {}
  for _, info in ipairs(values) do
    local bucket = configInfoMatchesCatalog(shop, info) and preferred or fallback
    bucket[#bucket + 1] = info
  end
  local ordered = populationWeightedOrder(preferred)
  for _, info in ipairs(populationWeightedOrder(fallback)) do ordered[#ordered + 1] = info end
  return ordered
end

local function candidateConfigsForModel(shop, modelKey)
  local candidates = {}
  local configList = core_vehicles.getConfigList() or {}
  for _, info in pairs(configList.configs or configList) do
    if type(info) == "table" and tostring(info.model_key) == tostring(modelKey) and info.key then
      candidates[#candidates + 1] = info
    end
  end
  return orderCandidates(shop, candidates)
end

-- Turns one config file into a recipe entry, or false when it does not resolve to a fitting engine. `cache` holds the parse results and per-model JBeam contexts for the current discovery pass.
local function parseConfigCandidate(info, inventoryId, runtimeData, cache)
  local pcPath = configPath(info)
  if cache.parsed[pcPath] ~= nil then return cache.parsed[pcPath] or nil end
  local pc = FS:fileExists(pcPath) and jsonReadFile(pcPath) or nil
  local vehicleDir = string.format("/vehicles/%s/", tostring(info.model_key))
  if type(pc) ~= "table" or not FS:directoryExists(vehicleDir) then cache.parsed[pcPath] = false; return nil end
  local modelKey = tostring(info.model_key)
  local ioCtx = cache.ioByModel[modelKey]
  if ioCtx == nil then
    ioCtx = runtimeData and runtimeData.ioCtx or jbeamIO.startLoading({vehicleDir, "/vehicles/common/"})
    cache.ioByModel[modelKey] = ioCtx or false
  end
  if not ioCtx then cache.parsed[pcPath] = false; return nil end
  pc.mainPartName = pc.mainPartName or jbeamIO.getMainPartName(ioCtx)
  pc.mainPartPath = pc.mainPartPath or (pc.mainPartName and "/" .. pc.mainPartName)
  local _, _, _, tree = jbeamSlotSystem.findParts(ioCtx, pc)
  local engine = tree and findEngineNode(tree, ioCtx)
  if not engine then cache.parsed[pcPath] = false; return nil end
  local recipe = {
    vehicleModel = modelKey, rootSlotName = engine.slotName, rootPath = engine.path,
    rootEngineName = engine.combustionPartName or engine.node.chosenPartName,
    rootEngineNiceName = nicePartName(ioCtx, engine.combustionPartName or engine.node.chosenPartName),
    tree = recipeNode(engine.node, engine.slotName), tuning = {}
  }
  recipe.tuning = overhaul_career_parts_engines_enginePackages.filterRecipeTuning(
    recipe.tree, recipe.vehicleModel, pc.vars or {}, ioCtx)
  recipe.signature = overhaul_career_parts_engines_enginePackages.computeRecipeSignature(recipe)
  local _, _, transmission = findTransmissionNode(recipe.tree)
  if not transmission or not overhaul_career_parts_engines_enginePackages.findCompatibleRecipeTarget(recipe, inventoryId) then
    cache.parsed[pcPath] = false
    return nil
  end
  local entry = {recipe = recipe, info = deepcopy(info), sourceTree = engine.node, ioCtx = ioCtx,
    category = configCategory(info), engineBuildSignature = engineBuildSignature(recipe)}
  cache.parsed[pcPath] = entry
  return entry
end

-- Adds a candidate to the discovery results unless the shop is full, the build is already listed, or the catalog or value check refuses it.
local function addDiscoveredRecipe(found, shop, entry, recipeTarget)
  if not entry or #found.results >= recipeTarget then return false end
  local signature = tostring(entry.recipe.signature)
  if found.signatures[signature] or not shopAllowsRecipe(shop, entry.info, entry.recipe, entry.ioCtx) then return false end
  local analysis = analyzeRecipe(entry.recipe, entry.ioCtx)
  local freshValue = recipeValue(entry.recipe, entry.ioCtx)
  if not analysis or not freshValue then return false end
  found.signatures[signature] = true
  entry.analysis, entry.freshValue = analysis, freshValue
  found.results[#found.results + 1] = entry
  return true
end

-- One bounded search supplies the whole shop. Never resolve more complete vehicle trees than the store can display; new/used variants can fill the remaining cards when several configs resolve to one package.
local function discoverRecipes(shop, inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[tonumber(inventoryId)]
  if not vehicle then return {} end
  local attachmentKey = overhaul_career_parts_engines_enginePackages.getEngineCompatibilityKey(inventoryId)
  if not attachmentKey then return {} end
  local cacheKey = tostring(shop.id) .. "|" .. tostring(vehicle.model) .. "|" .. tostring(attachmentKey)
  local cached = recipeCache[cacheKey]
  if cached and state.activeSeconds - (tonumber(cached.createdAtActive) or 0) < STOCK_LIFETIME_SIM_S then
    return cached.results
  end
  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(tonumber(inventoryId))
  local runtimeData = vehId and core_vehicle_manager.getVehicleData(vehId) or nil
  local candidates = candidateConfigsForModel(shop, vehicle.model)
  local recipeTarget = math.max(1, tonumber(shop.stockSize) or 8)
  local scanLimit = math.max(1, recipeTarget)
  local cache = {parsed = {}, ioByModel = {}}
  local found = {results = {}, signatures = {}}
  local checks = 0
  for _, info in ipairs(candidates) do
    if #found.results >= recipeTarget or checks >= scanLimit then break end
    checks = checks + 1
    addDiscoveredRecipe(found, shop, parseConfigCandidate(info, inventoryId, runtimeData, cache), recipeTarget)
  end
  local results = found.results
  table.sort(results, function(a, b) return tostring(a.recipe.rootEngineNiceName) < tostring(b.recipe.rootEngineNiceName) end)
  if tableSize(recipeCache) >= RECIPE_CACHE_LIMIT then table.clear(recipeCache) end
  recipeCache[cacheKey] = {createdAtActive = state.activeSeconds, results = results}
  return results
end

-- Visible cards: the engine, the transmission, then up to three intake, turbo, supercharger or ECU parts.
local function collectVisibleParts(entry, modifiedClues, ioCtx)
  local visible = {{label = "Block / engine", value = entry.recipe.rootEngineNiceName}}
  local _, _, transmission = findTransmissionNode(entry.recipe.tree)
  if transmission and transmission.name then
    visible[#visible + 1] = {label = "Transmission", value = nicePartName(ioCtx, transmission.name)}
  end
  local found = {}
  local function visit(node)
    for slotName, child in pairs(node.children or {}) do
      local lower = string.lower(tostring(slotName))
      if #visible < 3 and not found[lower] and (lower:find("intake", 1, true) or lower:find("turbo", 1, true)
          or lower:find("supercharger", 1, true) or lower:find("ecu", 1, true)) then
        found[lower] = true
        visible[#visible + 1] = {label = modifiedClues and "Visible upgrade" or "Visible part",
          value = nicePartName(ioCtx, child.name)}
      end
      visit(child)
    end
  end
  visit(entry.recipe.tree)
  return visible
end

-- Used-modified listings swap one intake, turbo, supercharger or ECU for another suitable part.
local function isInterestingSlot(slotName)
  local lower = string.lower(tostring(slotName))
  return lower:find("intake", 1, true) or lower:find("turbo", 1, true)
    or lower:find("supercharger", 1, true) or lower:find("ecu", 1, true)
end

local function gatherSwapCandidates(recipePart, sourcePart, candidates)
  for slotName, child in pairs(recipePart.children or {}) do
    local sourceChild = sourcePart.children and sourcePart.children[slotName]
    if isInterestingSlot(slotName) and sourceChild and #(sourceChild.suitablePartNames or {}) > 1 and not next(child.children or {}) then
      candidates[#candidates + 1] = {recipePart = child, sourcePart = sourceChild, slotName = slotName}
    end
    if sourceChild then gatherSwapCandidates(child, sourceChild, candidates) end
  end
  return candidates
end

local function randomizeRecipe(base)
  local recipe = deepcopy(base.recipe)
  local candidates = gatherSwapCandidates(recipe.tree, base.sourceTree, {})
  local clues = {}
  if #candidates > 0 then
    local candidate = candidates[math.random(#candidates)]
    local alternatives = {}
    for _, name in ipairs(candidate.sourcePart.suitablePartNames or {}) do
      if name ~= "" and name ~= candidate.recipePart.name then alternatives[#alternatives + 1] = name end
    end
    if #alternatives > 0 then
      candidate.recipePart.name = alternatives[math.random(#alternatives)]
      clues[#clues + 1] = "Aftermarket-looking " .. candidate.slotName:gsub("_", " ")
    end
  end
  recipe.signature = overhaul_career_parts_engines_enginePackages.computeRecipeSignature(recipe)
  return recipe, clues, #clues > 0
end

local function reliabilityFor(integrity, analysis, unknown)
  local condition = integrity >= 0.85 and "Reliable" or integrity >= 0.65 and "Fair" or integrity >= 0.45 and "Risky" or "Questionable"
  local utilization = analysis and tonumber(analysis.torqueUtilization)
  local stress = not utilization and "Questionable" or utilization <= 0.75 and "Reliable"
    or utilization <= 0.9 and "Fair" or utilization <= 1 and "Risky" or "Questionable"
  local result = reliabilityOrder[condition] >= reliabilityOrder[stress] and condition or stress
  if unknown and reliabilityOrder[result] < reliabilityOrder.Risky then result = "Risky" end
  return result
end

-- Listing construction ----------------------------------------------------------------------------

-- Age, mileage and integrity for a listing. New engines have no age, mileage or wear.
local function rollCondition(category, used, modified, currentYear)
  local maximumAge = category == "factory" and listingTuning.factoryMaxAgeYears or listingTuning.aftermarketMaxAgeYears
  local age = used and math.floor(1 + math.pow(math.random(), listingTuning.ageCurveExponent) * (maximumAge - 1)) or 0
  local annualMiles = used and (listingTuning.annualMileageBaseMiles + math.random() * listingTuning.annualMileageRangeMiles) or 0
  local mileageMiles = used and math.max(listingTuning.minimumMileageMiles,
    age * annualMiles * (listingTuning.mileageJitterBaseFactor + math.random() * listingTuning.mileageJitterRangeFactor)) or 0
  local mileage = math.floor(mileageMiles * METERS_PER_MILE)
  local ageWear = age / maximumAge * listingTuning.ageWearFractionAtMaximumAge
  local mileageWear = mileageMiles / 100000 * listingTuning.mileageWearFractionPer100kMiles
  local modificationWearFraction = modified and listingTuning.modificationWearFraction or 0
  local minimumIntegrity = category == "factory" and listingTuning.factoryMinimumIntegrityFraction or listingTuning.aftermarketMinimumIntegrityFraction
  local integrity = used and clamp(listingTuning.startingIntegrityFraction - ageWear - mileageWear - modificationWearFraction
    + (math.random() - 0.5) * listingTuning.integrityNoiseFraction, minimumIntegrity, listingTuning.maximumUsedIntegrityFraction) or 1
  return {
    age = age, year = currentYear - age, mileage = mileage, integrity = integrity
  }
end

local function certificationFor(analysis, recipe, category, kind)
  local certification = deepcopy(analysis)
  certification.status = analysis.result == "passed" and "passed" or "failed"
  certification.recipeSignature = recipe.signature
  certification.source = category == "factory"
    and (kind == "new" and "factory recipe" or "factory donor inspection")
    or (kind == "new" and "aftermarket build sheet" or "aftermarket inspection")
  return certification
end

local function createListing(shop, base, kind, inventoryId)
  local category = base.category == "factory" and "factory" or "aftermarket"
  local modified = kind == "usedModified"
  local recipe, clues, changed
  if modified then recipe, clues, changed = randomizeRecipe(base) else recipe, clues, changed = deepcopy(base.recipe), {}, true end
  if not changed then return nil end
  local fit = overhaul_career_parts_engines_enginePackages.findCompatibleRecipeTarget(recipe, inventoryId)
  if not fit then return nil end
  local analysis = modified and analyzeRecipe(recipe, base.ioCtx) or deepcopy(base.analysis)
  if not analysis then return nil end
  local used = kind ~= "new"
  local currentYear = overhaul_career_parts_engines_enginePackages.getCurrentManufacturingYear()
  local condition = rollCondition(category, used, modified, currentYear)
  local value = modified and recipeValue(recipe, base.ioCtx) or base.freshValue
  local price = overhaul_career_parts_engines_enginePackages.getConditionedRecipeValue(recipe, {
    manufacturedYear = condition.year, odometer = condition.mileage, integrity = condition.integrity
  }, base.ioCtx)
  if not price then return nil end
  -- Retail margin is separate from the parts' condition-adjusted inventory value.
  price = math.max(1, math.floor(price * (1 + RETAIL_MARKUP_FRACTION) + 0.5))
  local id = tostring(state.nextListingId); state.nextListingId = state.nextListingId + 1
  local certification = not modified and certificationFor(analysis, recipe, category, kind) or nil
  -- Config-list Power is already stored in watts; the analyzer is canonical mechanical horsepower, which is what this retail payload explicitly names.
  local displayPower = analysis and analysis.peakHorsepower
  return {
    id = id, shopId = tostring(shop.id), kind = kind, category = category, name = recipe.rootEngineNiceName,
    engineBuildSignature = base.engineBuildSignature or engineBuildSignature(recipe),
    sourceConfigName = base.info.Name or base.info.key, recipe = recipe, createdAtActive = state.activeSeconds,
    expiresAtActive = state.activeSeconds + STOCK_LIFETIME_SIM_S, mileage = condition.mileage, manufacturedYear = condition.year,
    integrity = condition.integrity, freshValue = value, price = price,
    powerHp = displayPower, peakTorqueNm = analysis and analysis.peakTorque,
    maxTorqueRatingNm = analysis and analysis.torqueLimit, estimatedSafePowerHp = analysis and round25(analysis.estimatedSafePower),
    reliability = reliabilityFor(condition.integrity, analysis, modified), certification = certification,
    inspection = modified and deepcopy(analysis) or nil, aftermarketUnknown = modified,
    exceedsStressLimit = analysis.result == "failed",
    sellerClues = clues, visibleParts = collectVisibleParts({recipe = recipe}, modified, base.ioCtx)
  }
end

-- Stock per shop and model ------------------------------------------------------------------------

local function modelStock(shop, inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[tonumber(inventoryId)]
  if not vehicle then return nil end
  local attachmentKey = overhaul_career_parts_engines_enginePackages.getEngineCompatibilityKey(inventoryId)
  if not attachmentKey then return nil end
  local key = tostring(shop.mapId) .. "|" .. tostring(shop.id)
  local shopState = state.shops[key] or {models = {}}
  state.shops[key] = shopState
  shopState.models = shopState.models or {}
  local stockKey = tostring(vehicle.model) .. "|" .. tostring(attachmentKey)
  local stock = shopState.models[stockKey] or {listings = {}, lastRestock = -RESTOCK_INTERVAL_SIM_S}
  shopState.models[stockKey] = stock
  return stock
end

-- Stock saved under an older catalog version is discarded so it is rebuilt from the current rules.
local function migrateStockCatalog(stock)
  if stock.catalogVersion ~= CATALOG_VERSION then
    stock.listings = {}
    stock.lastRestock = -RESTOCK_INTERVAL_SIM_S
    stock.catalogVersion = CATALOG_VERSION
  end
end

local function dropExpiredListings(stock)
  local kept = {}
  for _, listing in ipairs(stock.listings or {}) do
    if state.activeSeconds < (tonumber(listing.expiresAtActive) or 0) then kept[#kept + 1] = listing end
  end
  stock.listings = kept
  return kept
end

local function shuffledRecipeCombinations(recipes)
  local combinations = {}
  for _, base in ipairs(recipes) do
    for _, kind in ipairs({"new", "used"}) do
      combinations[#combinations + 1] = {kind = kind, base = base}
    end
  end
  shuffle(combinations)
  return combinations
end

-- Fills the stock with listings for combinations not already listed, up to the shop's stock size.
local function fillStock(shop, inventoryId, stock, recipes)
  local desired = math.max(1, tonumber(shop.stockSize) or 8)
  local consumed = {}
  for _, listing in ipairs(stock.listings) do
    consumed[tostring(listing.kind) .. "|" .. tostring(listing.recipe and listing.recipe.signature)] = true
  end
  local function addCombo(combo)
    local key = combo.kind .. "|" .. tostring(combo.base.recipe.signature)
    if consumed[key] or #stock.listings >= desired then return false end
    local listing = createListing(shop, combo.base, combo.kind, inventoryId)
    if not listing then return false end
    stock.listings[#stock.listings + 1] = listing
    consumed[key] = true
    return true
  end
  for _, combo in ipairs(shuffledRecipeCombinations(recipes)) do
    if #stock.listings >= desired then break end
    addCombo(combo)
  end
end

local function refreshStock(shop, inventoryId, force)
  local stock = modelStock(shop, inventoryId)
  if not stock then return nil, "No compatible vehicle is selected." end
  migrateStockCatalog(stock)
  local kept = dropExpiredListings(stock)
  if not force and state.activeSeconds - (tonumber(stock.lastRestock) or 0) < RESTOCK_INTERVAL_SIM_S and #kept > 0 then return stock end
  local recipes = discoverRecipes(shop, inventoryId)
  if #recipes == 0 then return stock, "No authored engine configurations fit this vehicle." end
  fillStock(shop, inventoryId, stock, recipes)
  stock.lastRestock = state.activeSeconds
  stock.catalogVersion = CATALOG_VERSION
  return stock
end

local function findListing(shopId, listingId, inventoryId)
  local shop = shopById(shopId)
  local stock = shop and modelStock(shop, inventoryId)
  for index, listing in ipairs(stock and stock.listings or {}) do
    if tostring(listing.id) == tostring(listingId) then return listing, stock, index end
  end
end

local function removeListing(stock, index) table.remove(stock.listings, index) end

local function preparedRecipe(listing, inventoryId)
  local recipe = deepcopy(listing.recipe)
  local _, _, transmission = findTransmissionNode(recipe.tree)
  if not transmission then return nil, "This listing does not contain a matched transmission." end
  recipe.signature = overhaul_career_parts_engines_enginePackages.computeRecipeSignature(recipe)
  local fit, err = overhaul_career_parts_engines_enginePackages.findCompatibleRecipeTarget(recipe, inventoryId)
  if not fit then return nil, err end
  return recipe
end

local function vehicleReadyForEngineSwap(inventoryId)
  if overhaul_career_repair_insurance.inventoryVehNeedsRepair(tonumber(inventoryId)) then
    return false, "Repair this vehicle before purchasing an engine swap."
  end
  return true
end

local function countTreeNodes(node)
  local count = 1
  for _, child in pairs(node.children or {}) do count = count + countTreeNodes(child) end
  return count
end

-- The owned vehicle closest to the service bay, if it is within five metres and can be worked on.
local function parkedOwnedVehicle(shop)
  local spot = spotFor(shop, "serviceSpotName")
  if not spot or not spot.pos then return nil end
  local bestId, bestDistance
  for inventoryId, vehicle in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(tonumber(inventoryId))
    local object = vehId and getObjectByID(vehId)
    local distance = object and (object:getPosition() - vec3(spot.pos)):length() or math.huge
    if vehicle.owned == true and not vehicle.timeToAccess and distance <= 5
        and (not bestDistance or distance < bestDistance) then
      bestId, bestDistance = tonumber(inventoryId), distance
    end
  end
  return bestId
end

-- Quotes, purchases and installs ------------------------------------------------------------------

local function getQuote(listingId, options)
  options = options or {}
  if not menuContext then return failure("The engine shop is not open.") end
  if not menuContext.inventoryId then return failure("Park an accessible owned vehicle in the service bay first.") end
  local shop = currentMenuShop()
  if tonumber(parkedOwnedVehicle(shop)) ~= tonumber(menuContext.inventoryId) then
    return failure("The selected vehicle is no longer parked in the service bay.")
  end
  local install = options.mode == "install"
  if install then
    local ready, repairError = vehicleReadyForEngineSwap(menuContext.inventoryId)
    if not ready then return {success = false, message = repairError, requiresRepair = true} end
  end
  local listing = findListing(menuContext.shopId, listingId, menuContext.inventoryId)
  if not listing then return failure("That engine is no longer available.") end
  local recipe, err = preparedRecipe(listing, menuContext.inventoryId)
  if not recipe then return failure(err) end
  -- The package is immutable after listing creation; there is no optional transmission/removal path that would require repricing it here.
  local preparedValue = listing.freshValue
  local packagePrice = math.max(1, math.floor(listing.price * preparedValue / math.max(1, listing.freshValue) + 0.5))
  local nodes = countTreeNodes(recipe.tree)
  local installFee = install and math.max(installPricing.minimumInstallFee, math.floor(packagePrice * installPricing.installFeeFraction + 0.5)) or 0
  local duration = install and clamp(installPricing.minimumDurationSeconds + nodes * installPricing.secondsPerPartNode,
    installPricing.minimumDurationSeconds, installPricing.maximumDurationSeconds) or 0
  local _, currentValue = overhaul_career_parts_engines_enginePackages.getInstalledRecipeAndValue(menuContext.inventoryId)
  local tradeInCredit = install and options.tradeIn == true and math.floor((tonumber(currentValue) or 0) * installPricing.tradeInFraction + 0.5) or 0
  return {success = true, listingId = tostring(listing.id), recipe = recipe, packagePrice = packagePrice,
    installFee = installFee, tradeInCredit = tradeInCredit, total = math.max(0, packagePrice + installFee - tradeInCredit),
    durationSeconds = duration, includesTransmission = true, mode = options.mode or "loose"}
end

local function payment(amount, label, inventoryId, shopId)
  return overhaul_career_economy_payment.pay({money = {amount = math.max(0, math.floor(amount)), canBeNegative = false}}, require("overhaul/lib/finance/metadata").tag({label = label, tags = {"engineRetail", "vehicleModification"}}, "purchase", {vehicleId = inventoryId, vehicleRelated = inventoryId ~= nil, locationId = shopId}))
end

local function refundPayment(amount, label, inventoryId, shopId)
  overhaul_career_economy_payment.reward({money = {amount = amount}}, require("overhaul/lib/finance/metadata").tag({label = label, tags = {"engineRetail", "refund"}}, "refund", {vehicleId = inventoryId, vehicleRelated = inventoryId ~= nil, locationId = shopId}))
end

local function packageMetadata(listing, recipe)
  -- Validate the stable record once; metadata copies must share its cached check.
  if listing.certification then
    overhaul_career_parts_engines_engineCertification.refreshAnalysis(listing.certification, recipe)
  end
  local certification = listing.certification and deepcopy(listing.certification) or nil
  if certification then
    certification.recipeSignature = recipe.signature
  end
  return {listingId = listing.id, shopId = listing.shopId, type = listing.kind, integrity = listing.integrity,
    visual = clamp(listing.integrity - 0.04, 0.2, 1), odometer = listing.mileage,
    manufacturedYear = listing.manufacturedYear, reliability = listing.reliability,
    aftermarketUnknown = listing.aftermarketUnknown, certification = certification}
end

local function riskAccepted(listing, options)
  return not listing.exceedsStressLimit or options and options.acceptRisk == true
end

local function riskConfirmationRequired()
  return {success = false, requiresRiskConfirmation = true,
    message = "Confirm that you accept the risk of an engine package that exceeds its declared stress limit."}
end

local function purchaseLoose(listingId, options)
  if not menuContext then return failure("The engine shop is not open.") end
  local shop = currentMenuShop()
  if not menuContext.inventoryId or tonumber(parkedOwnedVehicle(shop)) ~= tonumber(menuContext.inventoryId) then
    return failure("Park the selected owned vehicle in the service bay first.")
  end
  local listing, stock, index = findListing(menuContext.shopId, listingId, menuContext.inventoryId)
  if not listing then return failure("That engine is no longer available.") end
  if not riskAccepted(listing, options) then return riskConfirmationRequired() end
  if not payment(listing.price, "Loose Engine Package", nil, menuContext.shopId) then return failure("You cannot afford this Engine Package.") end
  local package, err = overhaul_career_parts_engines_enginePackages.clonePersonalPackageFromRecipe(listing.recipe,
    listing.name .. " Package", packageMetadata(listing, listing.recipe))
  if not package then
    refundPayment(listing.price, "Engine Package refund", nil, menuContext.shopId)
    return failure(err)
  end
  removeListing(stock, index)
  overhaul_career_saveSystem.saveCurrent()
  return {success = true, message = "The Engine Package was added to My Engine Packages.", packageId = package.id}
end

-- Personal packages that were installed in the vehicle before the swap, so the trade-in can be found.
local function snapshotPersonalPackages(inventoryId)
  local before, oldInstalledId = {}, nil
  for _, package in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "personal"})) do
    before[tostring(package.id)] = true
    if tonumber(package.installedInventoryId) == tonumber(inventoryId) then oldInstalledId = tostring(package.id) end
  end
  return before, oldInstalledId
end

-- The engine that comes out of the vehicle: the one installed before, or a newly stored package.
local function findOutgoingPackageId(before, oldInstalledId, targetPackageId)
  if oldInstalledId then return oldInstalledId end
  for _, candidate in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "personal"})) do
    if tostring(candidate.id) ~= targetPackageId and not before[tostring(candidate.id)]
        and overhaul_career_parts_engines_enginePackages.getPackageStatus(candidate) == "stored" then
      return tostring(candidate.id)
    end
  end
end

local function restockListing(stock, listing)
  for _, stocked in ipairs(stock.listings or {}) do
    if tostring(stocked.id) == tostring(listing.id) then return end
  end
  stock.listings[#stock.listings + 1] = listing
end

-- Runs when the package is installed: the vehicle is taken into the shop and the work order starts.
local function startWorkOrder(context)
  local inventoryId = context.inventoryId
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  state.jobs[tostring(inventoryId)] = {inventoryId = inventoryId, shopId = context.shopId, mapId = context.mapId, packageId = context.targetPackageId,
    outgoingPackageId = context.outgoingPackageId, tradeIn = context.tradeIn, paidTotal = context.paidTotal,
    listing = deepcopy(context.listing), status = "installing", remainingSeconds = context.durationSeconds,
    totalSeconds = context.durationSeconds, startedAtActive = state.activeSeconds}
  if vehicle then
    vehicle.timeToAccess = context.durationSeconds
    vehicle.delayReason = "engineRetailInstall"
    vehicle.engineRetailJobId = tostring(inventoryId)
    overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
  end
  overhaul_career_garage_inventory.removeVehicleObject(inventoryId, true)
  overhaul_career_saveSystem.saveCurrent()
  guihooks.trigger("toastrMsg", {type = "info", title = "Engine swap underway",
    msg = "Return to " .. tostring(shopById(context.shopId, context.mapId) and shopById(context.shopId, context.mapId).name or "the engine shop") .. " when the vehicle is ready."})
end

-- Install callback: a failed install refunds, releases the new package and restocks the listing.
local function onInstallFinished(context, success)
  if not success then
    refundPayment(context.paidTotal, "Engine swap refund", context.inventoryId, context.shopId)
    overhaul_career_parts_engines_enginePackages.consumeStoredPersonalPackage(context.targetPackageId)
    restockListing(context.stock, context.listing)
    return
  end
  context.outgoingPackageId = findOutgoingPackageId(context.before, context.oldInstalledId, context.targetPackageId)
  startWorkOrder(context)
end

local function startInstall(listingId, options)
  options = options or {}; options.mode = "install"
  if not menuContext then return failure("The engine shop is not open.") end
  local quote = getQuote(listingId, options)
  if not quote.success then return quote end
  local listing, stock, index = findListing(menuContext.shopId, listingId, menuContext.inventoryId)
  if not listing then return failure("That engine is no longer available.") end
  if not riskAccepted(listing, options) then return riskConfirmationRequired() end
  if not payment(quote.total, "Engine Package and installation", menuContext.inventoryId, menuContext.shopId) then return failure("You cannot afford this engine swap.") end

  local before, oldInstalledId = snapshotPersonalPackages(menuContext.inventoryId)
  local package, err = overhaul_career_parts_engines_enginePackages.clonePersonalPackageFromRecipe(quote.recipe,
    listing.name .. " Package", packageMetadata(listing, quote.recipe))
  if not package then
    refundPayment(quote.total, "Engine swap refund", menuContext.inventoryId, menuContext.shopId)
    return failure(err)
  end

  local context = {inventoryId = menuContext.inventoryId, shopId = menuContext.shopId, mapId = menuContext.mapId, targetPackageId = tostring(package.id),
    before = before, oldInstalledId = oldInstalledId, tradeIn = options.tradeIn == true, paidTotal = quote.total,
    durationSeconds = quote.durationSeconds, listing = listing, stock = stock}
  local accepted, installError = overhaul_career_parts_engines_enginePackages.installPackageIntoVehicle(package.id, context.inventoryId,
    function(success) onInstallFinished(context, success) end)
  if not accepted then
    -- A synchronous package failure already invokes the callback above. Only perform fallback cleanup when the target package still exists.
    if overhaul_career_parts_engines_enginePackages.getPackage(package.id) then
      refundPayment(quote.total, "Engine swap refund", menuContext.inventoryId, menuContext.shopId)
      overhaul_career_parts_engines_enginePackages.consumeStoredPersonalPackage(package.id)
    end
    return failure(installError)
  end
  removeListing(stock, index)
  overhaul_career_career.closeAllMenus()
  return {success = true, message = "The shop is starting the engine swap."}
end

-- Work orders: cancel, retrieve and the install timer ---------------------------------------------

local function vehicleBlocksSpot(spot)
  if not spot or not spot.pos then return true end
  local walkingVehicleId = gameplay_walk.isWalking()
    and be:getPlayerVehicleID(0) or nil
  for _, vehicle in pairs(getAllVehicles() or {}) do
    if vehicle and vehicle:getID() ~= walkingVehicleId
        and (vehicle:getPosition() - vec3(spot.pos)):length() < 4 then return true end
  end
  return false
end

local function moveVehicleToSpot(inventoryId, spot, vehObj)
  local object = vehObj or getObjectByID(overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId))
  if object and spot and spot.moveResetVehicleTo then spot:moveResetVehicleTo(object:getID(), nil, nil, nil, nil, true, nil, false) end
end

-- A cancelled work order returns its listing to stock while the listing is still live.
local function restoreListingForCancelledJob(job)
  local listing = job and job.listing
  local shop = job and shopForJob(job)
  if not listing or not shop or state.activeSeconds >= (tonumber(listing.expiresAtActive) or 0) then return end
  local stock = modelStock(shop, job.inventoryId)
  if not stock then return end
  restockListing(stock, listing)
end

local function jobPackageGuard(package)
  if not package then return true end
  for _, job in pairs(state.jobs) do
    if not job.internalMutation and (tostring(job.packageId) == tostring(package.id)
        or tostring(job.outgoingPackageId or "") == tostring(package.id)) then
      return false, "This Engine Package is locked by an engine-shop work order."
    end
  end
  return true
end

-- Puts the vehicle back as it was before a cancellation started, so the work order can still finish.
local function restoreJobAfterFailedCancel(job, inventoryId, vehicle, message)
  if job.status ~= "cancelling" then return end
  job.internalMutation = nil
  job.status = job.previousStatus or "installing"
  job.previousStatus = nil
  vehicle.timeToAccess = job.status == "ready" and 1 or math.max(1, tonumber(job.remainingSeconds) or 1)
  vehicle.delayReason = job.status == "ready" and "engineRetailPickup" or "engineRetailInstall"
  overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
  overhaul_career_garage_inventory.removeVehicleObject(inventoryId, true)
  refreshPoiMarkers()
  overhaul_career_saveSystem.saveCurrent()
  guihooks.trigger("toastrMsg", {type = "error", title = "Cancellation failed", msg = message or "The original engine could not be restored."})
end

-- Runs when the original engine is back in the vehicle: removes the new package and refunds the purchase.
local function completeCancellation(job, inventoryId, vehicle, pickup, success, message)
  if job.status ~= "cancelling" then return end
  if not success then restoreJobAfterFailedCancel(job, inventoryId, vehicle, message) return end
  -- Keep the internal mutation exemption active from reversion through cleanup; public package and vehicle operations remain forbidden.
  job.internalMutation = true
  local removed, removeError = overhaul_career_parts_engines_enginePackages.consumeStoredPersonalPackage(job.packageId)
  job.internalMutation = nil
  if not removed then restoreJobAfterFailedCancel(job, inventoryId, vehicle, removeError) return end
  refundPayment(math.max(0, tonumber(job.paidTotal) or 0), "Cancelled engine-shop work order", inventoryId, job.shopId)
  restoreListingForCancelledJob(job)
  vehicle.timeToAccess = nil; vehicle.delayReason = nil; vehicle.engineRetailJobId = nil
  state.jobs[tostring(inventoryId)] = nil
  overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
  moveVehicleToSpot(inventoryId, pickup)
  refreshPoiMarkers()
  overhaul_career_saveSystem.saveCurrent()
  guihooks.trigger("toastrMsg", {type = "success", title = "Work order cancelled",
    msg = "The original engine was restored and the purchase was refunded."})
end

-- Swaps the installed package back: the outgoing engine if there is one, otherwise the new package is stored.
local function beginCancelReversion(job, inventoryId, vehicle, pickup)
  job.internalMutation = true
  local onDone = function(success, message) completeCancellation(job, inventoryId, vehicle, pickup, success, message) end
  local accepted, err
  if job.outgoingPackageId then
    accepted, err = overhaul_career_parts_engines_enginePackages.installPackageIntoVehicle(job.outgoingPackageId, inventoryId, onDone)
  else
    accepted, err = overhaul_career_parts_engines_enginePackages.storePackageFromVehicle(job.packageId, inventoryId, onDone)
  end
  if not accepted then restoreJobAfterFailedCancel(job, inventoryId, vehicle, err) end
end

local function cancelJob(inventoryId)
  inventoryId = tonumber(inventoryId)
  local job = state.jobs[tostring(inventoryId)]
  if not job then return failure("That engine-shop work order no longer exists.") end
  if job.status == "cancelling" or job.status == "retrieving" then
    return failure("That work order is already being finalized.")
  end
  if not job.mapId then resolveJobOwnership(job, tonumber(job.legacyOwnershipVersion) or 0) end
  if not job.mapId then return failure("The retailer for this paid work order is unavailable. The order has been kept for recovery.") end
  if job.mapId ~= getCurrentLevelIdentifier() then return failure("Return to the work order map first.") end
  local shop = shopForJob(job)
  local pickup = spotFor(shop, "pickupSpotName")
  if not pickup then return failure("The pickup bay is not configured.") end
  if vehicleBlocksSpot(pickup) then return failure("Move the vehicle blocking the pickup bay first.") end
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  if not vehicle then return failure("The vehicle in this work order no longer exists.") end

  job.previousStatus = job.status
  job.status = "cancelling"
  refreshPoiMarkers()
  vehicle.timeToAccess = nil
  vehicle.delayReason = nil
  overhaul_career_garage_inventory.setVehicleDirty(inventoryId)

  local spawned = overhaul_career_garage_inventory.spawnVehicle(inventoryId, nil, function(success, reason)
    if job.status ~= 'cancelling' then return end
    if success == false then
      restoreJobAfterFailedCancel(job, inventoryId, vehicle, reason or 'The vehicle could not be prepared for cancellation.')
      return
    end
    beginCancelReversion(job, inventoryId, vehicle, pickup)
  end)
  if not spawned then
    restoreJobAfterFailedCancel(job, inventoryId, vehicle, "The vehicle could not be prepared for cancellation.")
    return {success = false, message = "The vehicle could not be prepared for cancellation."}
  end
  return {success = true, message = "Cancellation started. The original configuration is being restored."}
end

local function retrieveVehicle(inventoryId)
  inventoryId = tonumber(inventoryId)
  local job = state.jobs[tostring(inventoryId)]
  if not job or job.status ~= "ready" then return failure("That vehicle is not ready for pickup.") end
  if not job.mapId then resolveJobOwnership(job, tonumber(job.legacyOwnershipVersion) or 0) end
  if not job.mapId then return failure("The retailer for this paid work order is unavailable. The order has been kept for recovery.") end
  if job.mapId ~= getCurrentLevelIdentifier() then return failure("Return to the work order map first.") end
  local shop, vehicle = shopForJob(job), overhaul_career_garage_inventory.getVehicles()[inventoryId]
  local spot = spotFor(shop, "pickupSpotName")
  if not spot then return failure("The pickup bay is not configured.") end
  if vehicleBlocksSpot(spot) then return failure("Move the vehicle blocking the pickup bay first.") end
  job.status = "retrieving"
  refreshPoiMarkers()
  if vehicle then vehicle.timeToAccess = nil; vehicle.delayReason = nil end
  local spawned = overhaul_career_garage_inventory.spawnVehicle(inventoryId, nil, function(vehObj)
    moveVehicleToSpot(inventoryId, spot, vehObj)
  end)
  if not spawned then
    job.status = "ready"
    if vehicle then vehicle.timeToAccess = 1; vehicle.delayReason = "engineRetailPickup" end
    refreshPoiMarkers()
    return failure("The vehicle could not be spawned in the pickup bay.")
  end
  if job.tradeIn and job.outgoingPackageId then
    job.internalMutation = true
    local consumed, consumeError = overhaul_career_parts_engines_enginePackages.consumeStoredPersonalPackage(job.outgoingPackageId)
    job.internalMutation = nil
    if not consumed then
      job.status = "ready"
      if vehicle then vehicle.timeToAccess = 1; vehicle.delayReason = "engineRetailPickup" end
      overhaul_career_garage_inventory.removeVehicleObject(inventoryId, true)
      refreshPoiMarkers()
      return failure(consumeError or "The outgoing engine trade-in could not be finalized.")
    end
  end
  if vehicle then vehicle.engineRetailJobId = nil end
  state.jobs[tostring(inventoryId)] = nil
  overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
  refreshPoiMarkers()
  overhaul_career_saveSystem.saveCurrent()
  guihooks.trigger("toastrMsg", {type = "success", title = "Vehicle retrieved", msg = "Your vehicle is waiting in the pickup bay."})
  return {success = true, message = "Your vehicle is waiting in the pickup bay."}
end

-- UI data -----------------------------------------------------------------------------------------

local function jobsForShop(shop)
  local jobs = {}
  for _, job in pairs(state.jobs) do
    if job.mapId == shop.mapId and tostring(job.shopId) == tostring(shop.id) then
      local copy = deepcopy(job); copy.listing = nil
      local vehicle = overhaul_career_garage_inventory.getVehicles()[tonumber(job.inventoryId)]
      copy.vehicleName = vehicle and (vehicle.niceName or vehicle.name) or ("Vehicle #" .. tostring(job.inventoryId))
      jobs[#jobs + 1] = copy
    end
  end
  table.sort(jobs, function(a, b) return tonumber(a.inventoryId) < tonumber(b.inventoryId) end)
  return jobs
end

local function certificationSummary(certification)
  if not certification then return nil end
  return {
    status = certification.status,
    submittedAtActive = certification.submittedAtActive,
    readyAtActive = certification.readyAtActive,
    completedAtActive = certification.completedAtActive
  }
end

local function certifiablePackages()
  local result = {}
  for _, package in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "personal"})) do
    if overhaul_career_parts_engines_enginePackages.getPackageStatus(package) == "stored" then
      local cert = package.engineShopCertification
      if not cert or cert.status ~= "passed" then
        local value = overhaul_career_parts_engines_enginePackages.getFreshPackageValue(package)
        if value or (cert and cert.status == "pending") then
          result[#result + 1] = {id = tostring(package.id), name = package.name,
            certification = certificationSummary(cert),
            estimatedFee = value and math.max(1, math.floor(value * installPricing.certificationFeeFraction + 0.5)) or nil,
            canStart = not cert or cert.status ~= "pending" and cert.status ~= "failed"}
        end
      end
    end
  end
  table.sort(result, function(a, b) return string.lower(a.name or "") < string.lower(b.name or "") end)
  return result
end

-- Shop listing order: factory before aftermarket, then reliability, price, name, mileage and id.
local function compareListings(leftListing, rightListing)
  local categoryA = categoryOrder[leftListing.category] or math.huge
  local categoryB = categoryOrder[rightListing.category] or math.huge
  if categoryA ~= categoryB then return categoryA < categoryB end
  local reliabilityA = reliabilityOrder[leftListing.reliability] or math.huge
  local reliabilityB = reliabilityOrder[rightListing.reliability] or math.huge
  if reliabilityA ~= reliabilityB then return reliabilityA < reliabilityB end
  local priceA, priceB = tonumber(leftListing.price) or math.huge, tonumber(rightListing.price) or math.huge
  if priceA ~= priceB then return priceA < priceB end
  local nameA, nameB = string.lower(tostring(leftListing.name or "")), string.lower(tostring(rightListing.name or ""))
  if nameA ~= nameB then return nameA < nameB end
  local mileageA, mileageB = tonumber(leftListing.mileage) or math.huge, tonumber(rightListing.mileage) or math.huge
  if mileageA ~= mileageB then return mileageA < mileageB end
  return tostring(leftListing.id or "") < tostring(rightListing.id or "")
end

-- Listings as the UI sees them: no recipe or certification internals, plus the time left on each.
local function listingCards(stock)
  local listings = {}
  for _, listing in ipairs(stock and stock.listings or {}) do
    local copy = deepcopy(listing); copy.recipe = nil; copy.certification = nil; copy.inspection = nil
    copy.remainingSeconds = math.max(0, (listing.expiresAtActive or state.activeSeconds) - state.activeSeconds)
    listings[#listings + 1] = copy
  end
  table.sort(listings, compareListings)
  return listings
end

local function requestData()
  if not menuContext then return failure("The engine shop is not open.") end
  local shop = currentMenuShop()
  menuContext.inventoryId = parkedOwnedVehicle(shop)
  local listings = {}
  local err
  if menuContext.inventoryId then
    local stock
    stock, err = refreshStock(shop, menuContext.inventoryId)
    listings = listingCards(stock)
  end
  local vehicle = menuContext.inventoryId and overhaul_career_garage_inventory.getVehicles()[menuContext.inventoryId] or nil
  local swapReady, swapBlockedReason = true, nil
  if vehicle then swapReady, swapBlockedReason = vehicleReadyForEngineSwap(menuContext.inventoryId) end
  return {success = true, shop = deepcopy(shop), inventoryId = menuContext.inventoryId,
    vehicle = vehicle and {id = menuContext.inventoryId, model = vehicle.model, niceName = vehicle.niceName or vehicle.name,
      engineSwapBlockedReason = not swapReady and swapBlockedReason or nil} or nil,
    listings = listings, jobs = jobsForShop(shop), certifiablePackages = certifiablePackages(),
    message = err}
end

local function requestStatus()
  if not menuContext then return failure("The engine shop is not open.") end
  local shop = currentMenuShop()
  local stressTests = {}
  for _, package in ipairs(overhaul_career_parts_engines_enginePackages.listPackages({ownerType = "personal"})) do
    local cert = package.engineShopCertification
    if cert then stressTests[#stressTests + 1] = {id = tostring(package.id), certification = certificationSummary(cert)} end
  end
  return {success = true, jobs = jobsForShop(shop), stressTests = stressTests}
end

local function openShop(shopId)
  local shop = shopById(shopId)
  if not shop then return false end
  local inventoryId = parkedOwnedVehicle(shop)
  local vehicle = inventoryId and overhaul_career_garage_inventory.getVehicles()[inventoryId]
  menuContext = {shopId = tostring(shop.id), mapId = shop.mapId, inventoryId = tonumber(inventoryId)}
  if vehicle then refreshStock(shop, inventoryId, false) end
  guihooks.trigger("ChangeState", {state = "overhaul.engineRetail"})
  return true
end

local function startCertification(packageId)
  if not menuContext then return failure("Open an engine shop first.") end
  return overhaul_career_parts_engines_engineCertification.startPersonalCertification(packageId, menuContext.shopId)
end

-- Map and activity helpers --------------------------------------------------------------------------

local function addShopMarkers(shop, elements)
  local spot = spotFor(shop, "serviceSpotName")
  if spot and spot.pos then
    table.insert(elements, {id = "engineRetail-" .. tostring(shop.id),
      data = {type = "engineRetail", shopId = tostring(shop.id), name = shop.name},
      markerInfo = {inspectVehicleMarker = {pos = vec3(spot.pos), radius = 6, vehicleHeight = 4},
        bigmapMarker = {pos = vec3(spot.pos), icon = "poi_engine_round", name = shop.name,
          description = shop.description, cardIcon = "engine"}, clusterType = "activity"},
      pos = vec3(spot.pos), radius = 6})
  end
end

local function addPickupMarkers(shop, elements)
  for inventoryId, job in pairs(state.jobs) do
    if job.mapId == shop.mapId and tostring(job.shopId) == tostring(shop.id) and job.status == "ready" then
      local pickup = spotFor(shop, "pickupSpotName")
      if pickup and pickup.pos then
        table.insert(elements, {id = "engineRetailPickup-" .. tostring(inventoryId),
          data = {type = "engineRetailPickup", shopId = tostring(shop.id), inventoryId = tonumber(inventoryId), name = shop.name},
          markerInfo = {inspectVehicleMarker = {pos = vec3(pickup.pos), radius = 6, vehicleHeight = 4}},
          pos = vec3(pickup.pos), radius = 6})
      end
    end
  end
end

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  if not overhaul_career_career.isActive() then return end
  for _, shop in pairs(loadShopDefinitions(levelIdentifier)) do
    if tostring(shop.mapId) == tostring(levelIdentifier) then
      addShopMarkers(shop, elements)
      addPickupMarkers(shop, elements)
    end
  end
end

local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData or {}) do
    if elem.type == "engineRetail" then
      table.insert(activityData, {icon = "engine", heading = elem.name, preheadings = {"Engine Retailer"},
        sorting = {type = elem.type, id = elem.shopId}, startable = true, buttonLabel = "View Engine Inventory",
        buttonFun = function() openShop(elem.shopId) end})
    elseif elem.type == "engineRetailPickup" then
      table.insert(activityData, {icon = "keys1", heading = elem.name .. " Pickup", preheadings = {"Vehicle Ready"},
        sorting = {type = elem.type, id = elem.inventoryId}, startable = true, buttonLabel = "Retrieve Vehicle",
        buttonFun = function()
          local result = retrieveVehicle(elem.inventoryId)
          if not result.success then guihooks.trigger("toastrMsg", {type = "error", title = "Vehicle pickup", msg = result.message}) end
        end})
    end
  end
end

-- A vehicle with a work order in progress cannot be sold, repaired, stored, tuned or driven.
local function onOverhaulCheckPermission(tags, permissions, additionalData)
  local inventoryId = additionalData and tonumber(additionalData.inventoryId)
  local job = inventoryId and state.jobs[tostring(inventoryId)]
  if not job or job.internalMutation then return end
  for _, tag in ipairs(tags or {}) do
    if blockedWhileWorkOrderRuns[tag] then
      table.insert(permissions, {permission = "forbidden", label = "This vehicle is locked by an engine-shop work order."})
    end
  end
end

-- Game-time and per-frame updates -----------------------------------------------------------------

-- Installs count down in whole seconds; a finished install moves the vehicle to the pickup bay.
local function advanceInstallJob(inventoryId, job, tick)
  job.remainingSeconds = math.max(0, (tonumber(job.remainingSeconds) or 0) - tick)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[tonumber(inventoryId)]
  if vehicle then vehicle.timeToAccess = math.max(1, job.remainingSeconds); overhaul_career_garage_inventory.setVehicleDirty(tonumber(inventoryId)) end
  if job.remainingSeconds > 0 then return end
  job.status = "ready"
  if vehicle then vehicle.timeToAccess = 1; vehicle.delayReason = "engineRetailPickup" end
  refreshPoiMarkers()
  guihooks.trigger("toastrMsg", {type = "success", title = "Engine swap complete",
    msg = "Return to " .. tostring(shopForJob(job) and shopForJob(job).name or "the engine shop") .. " to retrieve your vehicle."})
  overhaul_career_saveSystem.saveCurrent()
end

local function onUpdate(dtReal)
  if not (overhaul_career_career and overhaul_career_career.isActive()) then return end
  if isPaused() then return end
  local elapsed = math.max(0, tonumber(dtReal) or 0)
  state.activeSeconds = state.activeSeconds + elapsed
  updateAccumulator = updateAccumulator + elapsed
  if updateAccumulator < 1 then return end
  local tick = updateAccumulator; updateAccumulator = 0
  for inventoryId, job in pairs(state.jobs) do
    if job.status == "installing" then advanceInstallJob(inventoryId, job, tick) end
  end
end

-- Lifecycle ------------------------------------------------------------------------

local function initialize()
  if initialized then return end
  initialized = true
  loadShopDefinitions(); loadData()
  overhaul_career_parts_engines_enginePackages.registerPackageReferenceGuard(jobPackageGuard)
end

local function onExtensionLoaded()
  shopsByMap = {}
  loadShopDefinitions()
  if overhaul_career_career.isActive() then initialize() end
end

-- Rebuild cached recipes when developer tools clear a shop's stock.
local function debugClearStock(shopId)
  if not devScope.devToolsEnabled() then return false end
  state.shops[tostring(getCurrentLevelIdentifier()) .. "|" .. tostring(shopId or "")] = nil
  recipeCache = {}
  analysisCache = {}
  valueCache = {}
  return true
end

-- Public API ---------------------------------------------------------------------------------------

M.openShop = openShop
M.requestData = requestData
M.requestStatus = requestStatus
M.getQuote = getQuote
M.purchaseLoose = purchaseLoose
M.startInstall = startInstall
M.retrieveVehicle = retrieveVehicle
M.cancelJob = cancelJob
M.startCertification = startCertification
M.debugClearStock = debugClearStock
-- Hooks --------------------------------------------------------------------------------------------

M.onGetRawPoiListForLevel = onGetRawPoiListForLevel
M.onActivityAcceptGatherData = onActivityAcceptGatherData
M.onOverhaulCheckPermission = onOverhaulCheckPermission
M.onCareerActivated = initialize
M.onOverhaulModulesActivated = initialize
M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulSaveCurrentProfile = function(path)
  initialize()
  saveData(path)
end
M.onUpdate = onUpdate

return M
