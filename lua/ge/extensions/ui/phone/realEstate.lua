local M = {}
M.dependencies = { 'freeroam_facilities', 'career_modules_garageManager', 'career_modules_hardcore', 'career_modules_playerAttributes', 'career_modules_propertyOwners' }

local routePlanner = require('gameplay/route/route')()

local function getCurrentLevel()
  if getCurrentLevelIdentifier and getCurrentLevelIdentifier() then
    return getCurrentLevelIdentifier()
  end
  if core_levels and getMissionFilename and getMissionFilename() ~= '' then
    return core_levels.getLevelName(getMissionFilename())
  end
  return nil
end

local function getPlayerPos()
  local veh = getPlayerVehicle(0)
  if veh then return veh:getPosition() end
  return nil
end

local function getDistanceTo(pos)
  local playerPos = getPlayerPos()
  if not playerPos or not pos then return -1 end
  -- Try road distance first
  routePlanner:setupPath(playerPos, pos)
  if routePlanner.path and routePlanner.path[1] and routePlanner.path[1].distToTarget then
    return routePlanner.path[1].distToTarget
  end
  -- Fallback to straight-line
  return (pos - playerPos):length()
end

local function isCareerActive()
  local state = core_gamestate and core_gamestate.state and core_gamestate.state.state
  if state == 'freeroam' then return false end
  if state == 'career' then return true end
  return career_career and career_career.isActive()
end

local function requestGarageListings()
  if not isCareerActive() then
    guihooks.trigger('phoneRealEstateData', { garages = {}, careerActive = false, playerBalance = 0 })
    return
  end

  local levelName = getCurrentLevel()
  if not levelName or levelName == '' then
    guihooks.trigger('phoneRealEstateData', { garages = {}, careerActive = true, playerBalance = 0 })
    return
  end

  local garages = freeroam_facilities.getFacilitiesByType("garage", levelName)
  if not garages then
    guihooks.trigger('phoneRealEstateData', { garages = {}, careerActive = true, playerBalance = 0 })
    return
  end

  local computers = freeroam_facilities.getFacilitiesByType("computer", levelName) or {}
  local garagePreviewByComputer = {}
  for _, comp in ipairs(computers) do
    if comp.garageId and comp.preview and not garagePreviewByComputer[comp.garageId] then
      garagePreviewByComputer[comp.garageId] = comp.preview
    end
  end

  local storedLocations = career_modules_garageManager.getStoredLocations()
  local result = {}

  for _, garage in pairs(garages) do
    local owned = career_modules_garageManager.isPurchasedGarage(garage.id)
    local discovered = career_modules_garageManager.isDiscoveredGarage(garage.id)
    local capacity = math.ceil(garage.capacity / (career_modules_hardcore.isHardcoreMode() and 2 or 1))
    local vehicleCount = 0
    if storedLocations[garage.id] then
      vehicleCount = #storedLocations[garage.id]
    end

    -- Get position and distance
    local pos, _ = freeroam_facilities.getGaragePosRot(garage)
    local distance = -1
    if pos then
      distance = getDistanceTo(pos)
    end

    local price = career_modules_garageManager.getGaragePurchasePrice(garage.id)
    if not price then price = garage.defaultPrice end
    if price and price > 0 and career_modules_propertyOwners and career_modules_propertyOwners.getOwnerForListing then
      local ownerInfo = career_modules_propertyOwners.getOwnerForListing(garage.id, price)
      if ownerInfo and ownerInfo.currentAskingPrice then
        price = ownerInfo.currentAskingPrice
      end
    end
    local starterPurchasable = garage.starterGarage and not owned and career_modules_garageManager.isStarterGaragePurchasable and career_modules_garageManager.isStarterGaragePurchasable(garage.id)
    if garage.starterGarage and not starterPurchasable then price = 0 end

    local preview = garagePreviewByComputer[garage.id] or garage.preview or ""

    -- Translate name if needed
    local name = garage.name
    if translateLanguage then
      local translated = translateLanguage(garage.name, garage.name, true)
      if translated then name = translated end
    end

    local canNegotiate = (not garage.starterGarage or starterPurchasable) and price > 0 and not owned
    local rented = career_modules_propertyRentals and career_modules_propertyRentals.isRentedGarage(garage.id) or false
    
    table.insert(result, {
      id = garage.id,
      name = name,
      description = garage.description or "",
      price = price or 0,
      capacity = capacity,
      vehicleCount = vehicleCount,
      owned = owned or false,
      rented = rented,
      discovered = discovered or false,
      starterGarage = (garage.starterGarage and not starterPurchasable) or false,
      preview = preview,
      distance = math.floor(distance),
      posX = pos and pos.x or 0,
      posY = pos and pos.y or 0,
      posZ = pos and pos.z or 0,
      canNegotiate = canNegotiate,
    })
  end

  -- Sort: owned first, then by distance
  table.sort(result, function(a, b)
    if a.owned ~= b.owned then return a.owned end
    return a.distance < b.distance
  end)

  local playerBalance = 0
  if career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue then
    playerBalance = tonumber(career_modules_playerAttributes.getAttributeValue("money")) or 0
  end
  guihooks.trigger('phoneRealEstateData', { garages = result, careerActive = true, playerBalance = playerBalance })
end

local function setRouteToGarage(garageId)
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return end
  local pos, _ = freeroam_facilities.getGaragePosRot(garage)
  if pos then
    core_groundMarkers.setPath(pos, { clearPathOnReachingTarget = true })
  end
end

local function towToGarage(garageId)
  if not career_modules_garageManager.isAccessibleGarage(garageId) and
     not career_modules_garageManager.isDiscoveredGarage(garageId) then
    return
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return end
  career_modules_quickTravel.quickTravelToGarage({ id = garageId })
end

-- ── Mortgage Info API ──

local function getMortgageInfo(garageId)
  if not career_modules_propertyMortgage then return nil end
  local offer = career_modules_propertyMortgage.getMortgageOfferDetails()
  if not offer then return { available = false } end

  local price = career_modules_garageManager.getGaragePurchasePrice(garageId) or 0
  local result = {
    available = offer.available or false,
    tier = offer.tier or "Unknown",
    downPaymentPercent = offer.downPaymentPercent or 0,
    downPayment = math.floor(price * (offer.downPaymentPercent or 0) + 0.5),
    interestRate = offer.rate or 0,
    propertyPrice = price,
    terms = {},
  }

  -- Calculate payment for each available term
  local termsAvailable = offer.termsAvailable or {12}
  for _, term in ipairs(termsAvailable) do
    local principal = price - result.downPayment
    local periodRate = result.interestRate / term
    local monthlyPayment
    if term <= 0 then
      monthlyPayment = principal
    elseif result.interestRate <= 0 then
      monthlyPayment = math.floor(principal / term + 0.5)
    else
      local powVal = math.pow(1 + periodRate, term)
      monthlyPayment = math.floor(principal * ((periodRate * powVal) / (powVal - 1)) + 0.5)
    end
    table.insert(result.terms, {
      termLength = term,
      monthlyPayment = monthlyPayment,
      totalCost = monthlyPayment * term + result.downPayment,
    })
  end

  return result
end

-- ── Rental Info API ──

local function getRentalInfo(garageId)
  if not career_modules_propertyRentals then return nil end
  return career_modules_propertyRentals.getRentalBreakdown(garageId)
end

local function signLease(garageId, rentalType, leaseTerm)
  if not career_modules_propertyRentals then return { error = "rental_system_unavailable" } end
  return career_modules_propertyRentals.signLease(garageId, rentalType, leaseTerm)
end

local function getRentalStatus(garageId)
  if not career_modules_propertyRentals then return nil end
  return career_modules_propertyRentals.getRentalInfo(garageId)
end

local function endLeaseEarly(garageId)
  if not career_modules_propertyRentals then return { error = "rental_system_unavailable" } end
  return career_modules_propertyRentals.endLeaseEarly(garageId)
end

M.requestGarageListings = requestGarageListings
M.setRouteToGarage = setRouteToGarage
M.towToGarage = towToGarage
M.getMortgageInfo = getMortgageInfo
M.getRentalInfo = getRentalInfo
M.signLease = signLease
M.getRentalStatus = getRentalStatus
M.endLeaseEarly = endLeaseEarly

return M
