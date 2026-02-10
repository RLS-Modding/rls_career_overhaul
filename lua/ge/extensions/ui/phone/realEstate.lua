local M = {}

local routePlanner = require('gameplay/route/route')()

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

local function requestGarageListings()
  if not career_career or not career_career.isActive() then
    guihooks.trigger('phoneRealEstateData', { garages = {}, careerActive = false })
    return
  end

  local garages = freeroam_facilities.getFacilitiesByType("garage")
  if not garages then
    guihooks.trigger('phoneRealEstateData', { garages = {}, careerActive = true })
    return
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

    -- Get price (accounts for hardcore, starter, etc)
    local price = career_modules_garageManager.getGaragePrice(garage.id)
    if not price then price = garage.defaultPrice end

    -- Resolve preview image path
    local preview = garage.preview or ""
    if preview ~= "" then
      -- Build full path relative to current level
      local levelDir = core_levels.getLevelName()
      if levelDir then
        preview = "/levels/" .. levelDir .. "/facilities/" .. preview
      end
    end

    -- Translate name if needed
    local name = garage.name
    if translateLanguage then
      local translated = translateLanguage(garage.name, garage.name, true)
      if translated then name = translated end
    end

    table.insert(result, {
      id = garage.id,
      name = name,
      description = garage.description or "",
      price = price or 0,
      capacity = capacity,
      vehicleCount = vehicleCount,
      owned = owned or false,
      discovered = discovered or false,
      starterGarage = garage.starterGarage or false,
      preview = preview,
      distance = math.floor(distance),
      posX = pos and pos.x or 0,
      posY = pos and pos.y or 0,
      posZ = pos and pos.z or 0,
    })
  end

  -- Sort: owned first, then by distance
  table.sort(result, function(a, b)
    if a.owned ~= b.owned then return a.owned end
    return a.distance < b.distance
  end)

  guihooks.trigger('phoneRealEstateData', { garages = result, careerActive = true })
end

local function setRouteToGarage(garageId)
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return end
  local pos, _ = freeroam_facilities.getGaragePosRot(garage)
  if pos then
    core_groundMarkers.setPath(pos)
  end
end

local function towToGarage(garageId)
  if not career_modules_garageManager.isPurchasedGarage(garageId) and
     not career_modules_garageManager.isDiscoveredGarage(garageId) then
    return
  end
  local garage = freeroam_facilities.getFacility("garage", garageId)
  if not garage then return end
  career_modules_quickTravel.quickTravelToGarage({ id = garageId })
end

M.requestGarageListings = requestGarageListings
M.setRouteToGarage = setRouteToGarage
M.towToGarage = towToGarage

return M
