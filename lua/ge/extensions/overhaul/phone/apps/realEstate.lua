-- Real estate app: lists the level's garages with price, distance and ownership for the phone.
-- Career calls check careerActive() first and answer as they do without a career.
local M = {}
local context = require('overhaul/lib/career/context')

local routePlanner = require('gameplay/route/route')()

local getCurrentLevel = context.currentLevel

local function getPlayerPos()
  local veh = getPlayerVehicle(0)
  if veh then return veh:getPosition() end
  return nil
end

-- Road distance when the route planner finds one, straight-line otherwise.
local function getDistanceTo(pos)
  local playerPos = getPlayerPos()
  if not playerPos or not pos then return -1 end
  routePlanner:setupPath(playerPos, pos)
  if routePlanner.path and routePlanner.path[1] and routePlanner.path[1].distToTarget then
    return routePlanner.path[1].distToTarget
  end
  return (pos - playerPos):length()
end

-- The career batch is loaded only while the career is active, and this app declares none of it.
local function careerActive()
  return overhaul_career_career.isActive()
end

local function playerMoney()
  local attributes = overhaul_career_economy_playerAttributes
  if attributes and attributes.getAttributeValue then
    return tonumber(attributes.getAttributeValue("money")) or 0
  end
  return 0
end

-- The price a property owner is asking, when they have a listing for this garage.
local function askingPriceFor(garage, price)
  local owners = overhaul_career_garage_property_propertyOwners
  if not (price and price > 0 and owners and owners.getOwnerForListing) then return price end
  local ownerInfo = owners.getOwnerForListing(garage.id, price)
  if ownerInfo and ownerInfo.currentAskingPrice then return ownerInfo.currentAskingPrice end
  return price
end

local function translatedName(garage)
  if translateLanguage then
    local translated = translateLanguage(garage.name, garage.name, true)
    if translated then return translated end
  end
  return garage.name
end

-- One listing row, or nil for a garage that is not sold at all.
local function garageRow(garage, listingContext)
  if garage.notPurchasable then return nil end
  local garageManager = overhaul_career_garage_garageManager
  local owned = garageManager.isPurchasedGarage(garage.id)
  local discovered = garageManager.isDiscoveredGarage(garage.id)
  local canReclaim = garageManager.canReclaimGrantedGarage(garage.id) or false
  local isHardcore = overhaul_career_economy_difficultyMode.isHardcoreMode()
  local capacity = math.ceil(garage.capacity / (isHardcore and 2 or 1))
  local storedLocations = listingContext.storedLocations
  local vehicleCount = storedLocations[garage.id] and #storedLocations[garage.id] or 0

  local pos = overhaul_world_facilities.getGaragePosRot(garage)
  local distance = -1
  if pos then distance = getDistanceTo(pos) end

  local price = garageManager.getGaragePurchasePrice(garage.id)
  if not price then price = garage.defaultPrice or 0 end
  price = askingPriceFor(garage, price)
  local starterPurchasable = garage.starterGarage and not owned and garageManager.isStarterGaragePurchasable(garage.id)
  if garage.starterGarage and not starterPurchasable then price = 0 end
  if canReclaim then price = 0 end

  local preview = listingContext.previewByComputer[garage.id] or garage.preview or ""
  local canNegotiate = (not garage.starterGarage or starterPurchasable) and price > 0 and not owned and not canReclaim
  local rented = overhaul_career_garage_property_propertyRentals.isRentedGarage(garage.id) or false

  return {
    id = garage.id,
    name = translatedName(garage),
    description = garage.description or "",
    price = price or 0,
    capacity = capacity,
    vehicleCount = vehicleCount,
    owned = owned or false,
    rented = rented,
    discovered = discovered or false,
    starterGarage = (garage.starterGarage and not starterPurchasable) or false,
    canReclaim = canReclaim,
    preview = preview,
    distance = math.floor(distance),
    posX = pos and pos.x or 0,
    posY = pos and pos.y or 0,
    posZ = pos and pos.z or 0,
    canNegotiate = canNegotiate,
  }
end

-- Preview picture per garage: the computer's picture wins over the garage's own.
local function previewsByGarage(levelName)
  local computers = overhaul_world_facilities.getFacilitiesByType("computer", levelName) or {}
  local previewByComputer = {}
  for _, computer in ipairs(computers) do
    if computer.garageId and computer.preview and not previewByComputer[computer.garageId] then
      previewByComputer[computer.garageId] = computer.preview
    end
  end
  return previewByComputer
end

local function buildGarageRows(garages, levelName)
  local listingContext = {
    previewByComputer = previewsByGarage(levelName),
    storedLocations = overhaul_career_garage_garageManager.getStoredLocations(),
  }
  local rows = {}
  for _, garage in pairs(garages) do
    local row = garageRow(garage, listingContext)
    if row then table.insert(rows, row) end
  end
  return rows
end

-- Owned first, then reclaimable, then nearest.
local function sortGarageRows(rows)
  table.sort(rows, function(a, b)
    if a.owned ~= b.owned then return a.owned end
    if a.canReclaim ~= b.canReclaim then return a.canReclaim end
    return a.distance < b.distance
  end)
end

local function sendEmptyListings(isCareerActive)
  guihooks.trigger("phoneRealEstateData", { garages = {}, careerActive = isCareerActive, playerBalance = 0 })
end

local function requestGarageListings()
  if not careerActive() then return sendEmptyListings(false) end

  local levelName = getCurrentLevel()
  if not levelName or levelName == "" then return sendEmptyListings(true) end

  local garages = overhaul_world_facilities.getFacilitiesByType("garage", levelName)
  if not garages then return sendEmptyListings(true) end

  local rows = buildGarageRows(garages, levelName)
  sortGarageRows(rows)
  guihooks.trigger("phoneRealEstateData", { garages = rows, careerActive = true, playerBalance = playerMoney() })
end

local function setRouteToGarage(garageId)
  local garage = overhaul_world_facilities.getFacility("garage", garageId)
  if not garage then return end
  local pos = overhaul_world_facilities.getGaragePosRot(garage)
  if pos then
    core_groundMarkers.setPath(pos, { clearPathOnReachingTarget = true })
  end
end

local function endLeaseEarly(garageId)
  if not careerActive() then
    return { error = "rental_system_unavailable" }
  end
  return overhaul_career_garage_property_propertyRentals.endLeaseEarly(garageId)
end

M.requestGarageListings = requestGarageListings
M.setRouteToGarage = setRouteToGarage
M.endLeaseEarly = endLeaseEarly

-- Loaded on demand by the phone. Restoring it on Lua reload would load career modules before career is active.
M.onInit = function() extensions.disableSerialization("overhaul_phone_apps_realEstate") end

return M
