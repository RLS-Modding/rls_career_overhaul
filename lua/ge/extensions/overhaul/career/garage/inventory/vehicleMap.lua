-- Vehicle map identity shared by inventory loading and garage capacity accounting.
-- Saved world evidence wins; legacy storage resolves through the facility catalog, never a map-name list.
local M = {}
local levelData = require('overhaul/lib/world/levelData')
local warned = {}

function M.homeGarage(vehicle)
  if tostring(vehicle.location or ''):find('freightPickup:', 1, true) == 1 then
    return vehicle.freightHomeGarageId
  end
  return vehicle.location
end

function M.resolve(vehicle)
  if vehicle.lastKnownLevel and vehicle.lastKnownLevel ~= '' then return vehicle.lastKnownLevel end
  if vehicle.worldPosition and vehicle.worldPosition.level then return vehicle.worldPosition.level end
  local garageId = M.homeGarage(vehicle)
  if not garageId then return nil end
  local current = getCurrentLevelIdentifier()
  local function contains(level)
    for _, garage in ipairs(overhaul_world_facilities.getFacilitiesByType('garage', level) or {}) do
      if tostring(garage.id) == tostring(garageId) then return true end
    end
  end
  local candidates = {}
  for level in pairs(levelData.loadMaps()) do candidates[level] = true end
  if current then candidates[current] = true end
  local found, count = nil, 0
  for level in pairs(candidates) do
    if contains(level) then
      found, count = level, count + 1
    else
      candidates[level] = nil
    end
  end
  if count > 1 then
    local manager = overhaul_career_garage_garageManager
    local live = manager and manager.getGarageAcquisition and manager.getGarageAcquisition(garageId)
    local ownerLevel = live and live.level
    if not ownerLevel then
      -- Ownership is evidence only when its acquisition actually recorded a map.
      local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
      local ownership = savePath and jsonReadFile(savePath .. '/career/rls_career/purchasedGarages.json')
      local acquisition = ownership and ownership.garages and ownership.garages[tostring(garageId)]
        and ownership.acquisitions and ownership.acquisitions[tostring(garageId)]
      ownerLevel = acquisition and acquisition.level
    end
    if ownerLevel and candidates[ownerLevel] then return ownerLevel end
    local key = tostring(garageId)
    if not warned[key] then
      warned[key] = true
      log('W', 'vehicleMap', 'Ambiguous garage id ' .. key .. '; leaving vehicle map unresolved')
    end
    return nil, 'ambiguous'
  end
  return found
end

function M.repair(vehicle)
  if not vehicle.lastKnownLevel or vehicle.lastKnownLevel == '' then
    vehicle.lastKnownLevel = M.resolve(vehicle)
  end
  return vehicle.lastKnownLevel
end

return M
