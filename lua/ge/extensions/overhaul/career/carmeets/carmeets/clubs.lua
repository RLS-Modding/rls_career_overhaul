-- Car meet clubs: club definitions and matching, vehicle pool rules, membership and standing, and traffic cut and restore.
-- Map: per-load state, club matching, vehicle pools, membership, traffic and returned API.

local lib = {}

function lib.create(inputs)
  local parts = inputs.parts
  -- State -----------------------------------------------------------------------------------------

  local carMeetState = inputs.carMeetState
  local callbacks = inputs.callbacks

  -- Helpers ---------------------------------------------------------------------------------------
  local function loadClubDefinitions()
    if carMeetState.clubDefinitions then return carMeetState.clubDefinitions end
    local data = jsonReadFile(inputs.CLUB_DEFINITIONS_PATH) or {}
    carMeetState.clubDefinitions = data.clubs or {}
    return carMeetState.clubDefinitions
  end

  local function getClubDefinition(clubId)
    clubId = tostring(clubId or "")
    for _, club in ipairs(loadClubDefinitions()) do
      if tostring(club.id) == clubId then
        return club
      end
    end
    return nil
  end

  local function getPlayerMoney()
    return tonumber(overhaul_career_economy_playerAttributes.getAttributeValue("money")) or 0
  end

  local function clubRequirementText(requirements)
    requirements = requirements or {}
    if requirements.minVehicleValue then
      return "Vehicle value: $" .. tostring(requirements.minVehicleValue) .. "+"
    end
    if requirements.configPrefix then
      return "Model: " .. tostring(requirements.displayName or requirements.configPrefix)
    end
    if requirements.models and #requirements.models > 0 then
      return "Models: " .. table.concat(requirements.models, ", ")
    end
    if requirements.brands and #requirements.brands > 0 then
      return "Brands: " .. table.concat(requirements.brands, ", ")
    end
    if requirements.tags and #requirements.tags > 0 then
      return "Tags: " .. table.concat(requirements.tags, ", ")
    end
    return "Any owned vehicle"
  end

  local function meetsMinimumValue(vehicle, requirements, inventoryId)
    if not requirements.minVehicleValue then return true end
    local vehicleValue = parts.sales.getInventoryVehicleValue(inventoryId)
    if vehicleValue <= 0 and vehicle.id then vehicleValue = parts.sales.getInventoryVehicleValue(vehicle.id) end
    if vehicleValue <= 0 then
      vehicleValue = tonumber(vehicle.value) or tonumber(vehicle.Value) or tonumber(vehicle.configBaseValue) or 0
    end
    return not (vehicleValue < tonumber(requirements.minVehicleValue))
  end

  local function matchesFactoryVariant(vehicle, requirements)
    -- Shared platform models need their installed body or original configuration to identify the variant.
    if parts.sales.normalizeString(vehicle.model) ~= parts.sales.normalizeString(requirements.model) then return false end
    local config = vehicle.config or {}
    local bodyPart = config.parts and config.parts[requirements.bodySlot]
    if not bodyPart and config.partsTree then
      local partsMap = core_vehicle_partmgmt.partsTreeToPartsMap(config.partsTree)
      bodyPart = partsMap and partsMap[requirements.bodySlot]
    end
    if bodyPart then return parts.sales.normalizeString(bodyPart) == parts.sales.normalizeString(requirements.bodyPart) end
    local filename = parts.sales.normalizeString(config.partConfigFilename):gsub("\\", "/"):match("([^/]+)%.pc$") or ""
    local prefix = parts.sales.normalizeString(requirements.configPrefix)
    return filename:sub(1, #prefix) == prefix
  end

  local function anyValueMatches(values, requirements)
    for _, value in pairs(values) do
      if parts.sales.valueMatches(value, requirements) then return true end
    end
    return false
  end

  local function matchesClubTags(vehicle, tags)
    local haystackParts = {}
    local function add(value)
      if value then table.insert(haystackParts, tostring(value)) end
    end
    add(vehicle.model)
    add(vehicle.niceName)
    if vehicle.config then
      add(vehicle.config.partConfigFilename)
      add(vehicle.config.configType)
      add(vehicle.config["Config Type"])
      add(vehicle.config["Body Style"])
      if vehicle.config.tags then add(parts.sales.sortedStableSerialize(vehicle.config.tags)) end
    end
    local haystack = parts.sales.normalizeString(table.concat(haystackParts, " "))
    for _, tag in ipairs(tags) do
      if not string.find(haystack, parts.sales.normalizeString(tag), 1, true) then return false end
    end
    return true
  end

  local function vehicleMatchesClub(vehicle, club, inventoryId)
    if not vehicle or not club then return false end
    local requirements = club.requirements or {}
    if not meetsMinimumValue(vehicle, requirements, inventoryId) then return false end
    local modelValues = {
      vehicle.model, vehicle.modelName, vehicle.config and vehicle.config.model,
      vehicle.config and vehicle.config.model_key, vehicle.config and vehicle.config.mainPartName
    }
    if requirements.configPrefix then return matchesFactoryVariant(vehicle, requirements) end
    if requirements.models and #requirements.models > 0 then return anyValueMatches(modelValues, requirements.models) end
    local brandValues = {
      vehicle.Brand, vehicle.brand, vehicle.config and vehicle.config.Brand,
      vehicle.config and vehicle.config.brand, vehicle.niceName
    }
    if requirements.brands and #requirements.brands > 0 then return anyValueMatches(brandValues, requirements.brands) end
    if requirements.tags and #requirements.tags > 0 then return matchesClubTags(vehicle, requirements.tags) end
    return true
  end

  -- Vehicle pools -----------------------------------------------------------------------------------

  local function getVehicleInfoFieldText(vehicleInfo)
    if not vehicleInfo then return "" end
    local textParts = {}
    local function add(value)
      if value ~= nil then
        table.insert(textParts, tostring(value))
      end
    end
    local keys = {
      "model_key", "key", "Brand", "brand", "Make", "make", "Name", "name",
      "Configuration", "Description", "Config Type", "ConfigType", "Body Style",
      "BodyStyle", "Body", "Type", "Source", "defaultPaintName1"
    }
    for _, key in ipairs(keys) do
      add(vehicleInfo[key])
    end
    if type(vehicleInfo.Years) == "table" then
      add(vehicleInfo.Years.min)
      add(vehicleInfo.Years.max)
      add(vehicleInfo.Years[1])
      add(vehicleInfo.Years[2])
    else
      add(vehicleInfo.Years)
    end
    if type(vehicleInfo.tags) == "table" then add(parts.sales.sortedStableSerialize(vehicleInfo.tags)) end
    if type(vehicleInfo.Tags) == "table" then add(parts.sales.sortedStableSerialize(vehicleInfo.Tags)) end
    return parts.sales.normalizeString(table.concat(textParts, " "))
  end

  local function getVehicleInfoYearBounds(vehicleInfo)
    if not vehicleInfo then return nil, nil end
    local years = vehicleInfo.Years or vehicleInfo.Year or vehicleInfo.year
    if type(years) == "table" then
      local minYear = tonumber(years.min) or tonumber(years[1])
      local maxYear = tonumber(years.max) or tonumber(years[2]) or minYear
      if minYear and maxYear and minYear > maxYear then
        minYear, maxYear = maxYear, minYear
      end
      return minYear, maxYear
    end
    local year = tonumber(years)
    return year, year
  end

  local MODEL_INFO_FIELDS = {"model_key", "model", "Model", "key", "Name", "name"}
  local BRAND_INFO_FIELDS = {"Brand", "brand", "Make", "make", "Name", "name"}

  local function vehicleInfoTextMatches(vehicleInfo, requirements)
    local text = requirements.bodyContainsAny and parts.sales.normalizeString(vehicleInfo["Body Style"] or vehicleInfo.BodyStyle or vehicleInfo.Body or "")
      or getVehicleInfoFieldText(vehicleInfo)
    for _, token in ipairs(requirements.textContainsAny or requirements.bodyContainsAny) do
      if text:find(parts.sales.normalizeString(token), 1, true) then return true end
    end
    return false
  end

  local function vehicleInfoWithinYearMax(vehicleInfo, yearLimit)
    local _, yearMax = getVehicleInfoYearBounds(vehicleInfo)
    return yearMax ~= nil and not (yearMax > yearLimit)
  end

  local function vehicleInfoMeetsMinValue(vehicleInfo, minValue)
    local value = tonumber(vehicleInfo.Value) or tonumber(vehicleInfo.value) or tonumber(vehicleInfo.configBaseValue) or 0
    return not (value < tonumber(minValue))
  end

  local function vehicleInfoMatchesConfigPrefix(vehicleInfo, requirements)
    if parts.sales.normalizeString(vehicleInfo.model_key) ~= parts.sales.normalizeString(requirements.model) then return false end
    local prefix = parts.sales.normalizeString(requirements.configPrefix)
    return parts.sales.normalizeString(vehicleInfo.key):sub(1, #prefix) == prefix
  end

  local function vehicleInfoFieldMatches(vehicleInfo, fieldNames, wanted)
    for _, fieldName in ipairs(fieldNames) do
      local value = vehicleInfo[fieldName]
      if value ~= nil and parts.sales.valueMatches(value, wanted) then return true end
    end
    return false
  end

  local function vehicleInfoHasAllTags(vehicleInfo, tags)
    local haystack = getVehicleInfoFieldText(vehicleInfo)
    for _, tag in ipairs(tags) do
      if not string.find(haystack, parts.sales.normalizeString(tag), 1, true) then return false end
    end
    return true
  end

  local function vehicleInfoMatchesClub(vehicleInfo, club)
    if not vehicleInfo or not club then return false end
    local requirements = club.vehiclePoolRequirements or club.requirements or {}
    if requirements.anyOf then
      for _, branch in ipairs(requirements.anyOf) do
        if vehicleInfoMatchesClub(vehicleInfo, {requirements = branch}) then return true end
      end
      return false
    end
    if requirements.allOf then
      for _, branch in ipairs(requirements.allOf) do
        if not vehicleInfoMatchesClub(vehicleInfo, {requirements = branch}) then return false end
      end
      return true
    end
    if (requirements.textContainsAny or requirements.bodyContainsAny) and not vehicleInfoTextMatches(vehicleInfo, requirements) then return false end
    if requirements.yearMax and not vehicleInfoWithinYearMax(vehicleInfo, requirements.yearMax) then return false end
    if requirements.minVehicleValue and not vehicleInfoMeetsMinValue(vehicleInfo, requirements.minVehicleValue) then return false end
    if requirements.configPrefix then return vehicleInfoMatchesConfigPrefix(vehicleInfo, requirements) end
    if requirements.models and #requirements.models > 0 then
      return vehicleInfoFieldMatches(vehicleInfo, MODEL_INFO_FIELDS, requirements.models)
    end
    if requirements.brands and #requirements.brands > 0 then
      return vehicleInfoFieldMatches(vehicleInfo, BRAND_INFO_FIELDS, requirements.brands)
    end
    if requirements.tags and #requirements.tags > 0 then return vehicleInfoHasAllTags(vehicleInfo, requirements.tags) end
    return true
  end

  local function getVehicleInfoPopulation(vehicleInfo)
    if not vehicleInfo then return math.huge end
    local population = tonumber(vehicleInfo.Population) or tonumber(vehicleInfo.population) or tonumber(vehicleInfo.adjustedPopulation)
    if not population or population <= 0 then return math.huge end
    return population
  end

  local function getVehicleInfoCatalogValue(vehicleInfo)
    if not vehicleInfo then return 0 end
    return tonumber(vehicleInfo.Value) or tonumber(vehicleInfo.value) or tonumber(vehicleInfo.configBaseValue) or 0
  end

  local function vehicleInfoMatchesPoolRules(vehicleInfo, rules)
    if not rules then return true end
    local population = getVehicleInfoPopulation(vehicleInfo)
    local value = getVehicleInfoCatalogValue(vehicleInfo)
    if rules.populationMax and population > rules.populationMax then return false end
    if rules.valueMin and value < rules.valueMin then return false end
    return true
  end

  local function filterVehicleInfosForPoolRules(vehicleInfos, rules)
    if not rules then return vehicleInfos end
    local filtered = {}
    for _, vehicleInfo in ipairs(vehicleInfos or {}) do
      if vehicleInfoMatchesPoolRules(vehicleInfo, rules) then
        table.insert(filtered, vehicleInfo)
      end
    end
    return filtered
  end

  local function getMeetVehiclePoolRules(meetType)
    local rules = meetType and meetType.vehiclePoolRules
    if not rules then return nil end
    local tiers = rules.tiers or {rules}
    return tiers
  end

  local function playerOwnsClubVehicle(club)
    -- Some mod clubs sell membership as soon as their model is installed.
    if club and club.joinRequiresInstalledModel then
      -- check the vehicle folder first: getModel logs an error for every missing model, and this runs on each refresh
      local model = tostring(club.joinRequiresInstalledModel)
      if not FS:directoryExists("/vehicles/" .. model) then return false end
      local modelData = core_vehicles.getModel(model)
      return modelData and modelData.model ~= nil or false
    end
    for inventoryId, vehicle in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
      if vehicleMatchesClub(vehicle, club, inventoryId) then
        return true
      end
    end
    return false
  end

  -- Membership and standing -------------------------------------------------------------------------

  local function isClubJoined(clubId)
    return carMeetState.joinedClubs[tostring(clubId)] ~= nil
  end

  local function isClubActive(club)
    return club and isClubJoined(club.id) and playerOwnsClubVehicle(club)
  end

  local function ensureClubMembership(clubId)
    clubId = tostring(clubId or "")
    local membership = carMeetState.joinedClubs[clubId]
    if not membership then return nil end
    if type(membership) ~= "table" then
      membership = {joinedAt = os.time()}
      carMeetState.joinedClubs[clubId] = membership
    end
    membership.joinedAt = membership.joinedAt or os.time()
    membership.standing = tonumber(membership.standing) or inputs.CLUB_STANDING_MAX
    membership.obligationEvents = tonumber(membership.obligationEvents) or 0
    membership.obligationAttended = tonumber(membership.obligationAttended) or 0
    membership.obligationWindowSize = tonumber(membership.obligationWindowSize) or inputs.CLUB_OBLIGATION_WINDOW_SIZE
    membership.requiredAttendance = tonumber(membership.requiredAttendance) or inputs.CLUB_OBLIGATION_REQUIRED_ATTENDANCE
    return membership
  end

  local function recordClubMeetResult(clubId, attended, reason)
    local membership = ensureClubMembership(clubId)
    if not membership then return end

    membership.obligationEvents = (tonumber(membership.obligationEvents) or 0) + 1
    if attended then
      membership.obligationAttended = (tonumber(membership.obligationAttended) or 0) + 1
      membership.lastAttendedAt = os.time()
    else
      membership.lastMissedAt = os.time()
    end

    if membership.obligationEvents < (membership.obligationWindowSize or inputs.CLUB_OBLIGATION_WINDOW_SIZE) then
      return
    end

    local club = getClubDefinition(clubId)
    local clubName = club and club.name or "your club"
    local missedRequirement = (tonumber(membership.obligationAttended) or 0) < (membership.requiredAttendance or inputs.CLUB_OBLIGATION_REQUIRED_ATTENDANCE)
    membership.obligationEvents = 0
    membership.obligationAttended = 0

    if not missedRequirement then
      inputs.persist.markDirty()
      return
    end

    membership.standing = math.max(0, (tonumber(membership.standing) or inputs.CLUB_STANDING_MAX) - inputs.CLUB_STANDING_MISS_PENALTY)
    -- Club standing can drop, but scene reputation only drops on Car Bazaar RSVP miss.

    if membership.standing <= 0 then
      carMeetState.joinedClubs[tostring(clubId)] = nil
      ui_message("You lost standing with " .. clubName .. " and need to re-pay dues to rejoin.", 9, "warning", "warning")
    elseif membership.standing <= inputs.CLUB_STANDING_WARNING_THRESHOLD then
      ui_message(clubName .. " standing is low. Attend an upcoming club meet to avoid being dropped.", 9, "warning", "warning")
    else
      ui_message("You missed your " .. clubName .. " attendance requirement.", 7, "warning", "warning")
    end
    inputs.persist.markDirty()
  end

  local function getActiveClubs(includeSpecial)
    local activeClubs = {}
    for _, club in ipairs(loadClubDefinitions()) do
      if isClubActive(club) and (includeSpecial or club.type ~= "special") then
        table.insert(activeClubs, club)
      end
    end
    return activeClubs
  end

  local function getActiveClubById(clubId)
    if not clubId then return nil end
    clubId = tostring(clubId)
    for _, club in ipairs(loadClubDefinitions()) do
      if tostring(club.id) == clubId then
        return isClubActive(club) and club or nil
      end
    end
    return nil
  end

  local function selectActiveClub(clubId, allowFallback)
    local club = getActiveClubById(clubId)
    if club then return club end
    if clubId and allowFallback == false then return nil end
    local activeClubs = getActiveClubs()
    if #activeClubs == 0 then return nil end
    return activeClubs[math.random(#activeClubs)]
  end

  -- Traffic and sale markers ------------------------------------------------------------------------

  local function saveAndReduceTraffic(reductionPercent)
    if gameplay_traffic then
      local vars = gameplay_traffic.getTrafficVars()
      local activeAmount = vars and tonumber(vars.activeAmount)
      local totalAmount = gameplay_traffic.getNumOfTraffic() or 0
      if carMeetState.previousTrafficAmount == nil then
        carMeetState.previousTrafficAmount = activeAmount or totalAmount
      end
      local baseAmount = math.min(activeAmount or totalAmount, totalAmount)
      local newAmount = math.floor(baseAmount * (1 - reductionPercent))
      gameplay_traffic.setActiveAmount(newAmount)
    end
  end

  local function restoreTrafficAmount()
    if gameplay_traffic and carMeetState.previousTrafficAmount then
      gameplay_traffic.setActiveAmount(carMeetState.previousTrafficAmount)
      carMeetState.previousTrafficAmount = nil
    end
  end

  callbacks.canPlayerSellAtMeet = function(state)
    state = state or carMeetState.meetState
    return state
    and state.flags
    and state.flags.playerBroughtVehicle == true
    and state.flags.saleInventoryId
    and state.flags.playerSoldSaleVehicle ~= true
  end

  -- Drop sale interaction markers as soon as showcase ends so they cannot linger/follow the player.
  local function clearMeetShowcasePois(state)
    if state and state.flags then
      state.flags.saleVehicleId = nil
    end
    if gameplay_rawPois and gameplay_rawPois.clear then
      gameplay_rawPois.clear()
    end
  end

  -- Public API ------------------------------------------------------------------------------------
  return {
    loadClubDefinitions = loadClubDefinitions,
    getPlayerMoney = getPlayerMoney,
    clubRequirementText = clubRequirementText,
    vehicleInfoMatchesClub = vehicleInfoMatchesClub,
    filterVehicleInfosForPoolRules = filterVehicleInfosForPoolRules,
    getMeetVehiclePoolRules = getMeetVehiclePoolRules,
    playerOwnsClubVehicle = playerOwnsClubVehicle,
    isClubJoined = isClubJoined,
    isClubActive = isClubActive,
    ensureClubMembership = ensureClubMembership,
    recordClubMeetResult = recordClubMeetResult,
    getActiveClubs = getActiveClubs,
    getActiveClubById = getActiveClubById,
    selectActiveClub = selectActiveClub,
    saveAndReduceTraffic = saveAndReduceTraffic,
    restoreTrafficAmount = restoreTrafficAmount,
    clearMeetShowcasePois = clearMeetShowcasePois,
  }
end

return lib
