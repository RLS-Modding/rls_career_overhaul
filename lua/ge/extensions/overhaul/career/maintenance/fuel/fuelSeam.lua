-- RLS seam of the stock refuelling flow in overhaul/career/maintenance/fuel.lua: which vehicle the pump serves,
-- and the business or shop-stockpile transaction, its billing and the employer-paid company car.
local M = {}
local capabilities = require("overhaul/lib/platform/capabilities")

-- Synthetic station for in-shop refuelling: pricing bills the level's average pump price, and the ledger labels it.
local SHOP_STATION_ID = "shopStockpile"
M.SHOP_STATION_ID = SHOP_STATION_ID

-- The shop stockpile has no real station, so it bills the average price of every station that sells this fuel. Returns nil when no station has a price yet (for example before the pump signs refresh).
local function getShopAveragePrice(energyType)
  local facilities = overhaul_world_facilities.getCurrentLevelFacilities()
  if not facilities or not facilities.gasStations then return nil end
  local sum, count = 0, 0
  for _, station in ipairs(facilities.gasStations) do
    if station and station.id then
      local price = overhaul_world_fuel_fuelPrice.getFuelPrice(station.id, energyType)
      if price and price > 0 then
        sum = sum + price
        count = count + 1
      end
    end
  end
  if count == 0 then return nil end
  return sum / count
end

local function isShopStation(gasStation)
  return gasStation and gasStation.facility and gasStation.facility.id == SHOP_STATION_ID
end

-- The shop stockpile bills the level's average pump price (1 when there is none) and never gets the insurance discount. Returns nil for a real station, which keeps its own price.
function M.getShopPricePerUnit(gasStation, energyType)
  if isShopStation(gasStation) then
    return getShopAveragePrice(energyType) or 1
  end
  return nil
end

-- A transaction without a station id, and the shop stockpile, sell every fuel type. The shop has no fuel-price entry of its own, and its average can be nil before the pump signs refresh.
function M.sellsEveryFuelType(gasStation)
  if not (gasStation and gasStation.facility and gasStation.facility.id) then return true end
  return gasStation.facility.id == SHOP_STATION_ID
end

-- The tank's identity for the refuelling UI.
function M.tagTank(tankData, tank, index)
  tankData.energyType = tank.energyType
  tankData.tankIndex = index
  tankData.tankName = tank.name
end

function M.create()
  local fuelSeam = {}

  -- Set while refuelling a business fleet vehicle: { businessId, vehicleId, vehObjId }. Pay and end logic use it to bill the business and skip player inventory lookups.
  local businessCtx

  -- Set when a Business Computer screen started the refuel (for example Racing Team "Pit Fuel"). finishTransaction uses it to return the player to that screen.
  local pendingBizReturn

  -- The vehicle the pump prompt picked when the player walked up on foot; every fuel read and the bill go to it.
  local targetVehObjId

  -- The vehicle to pump against. In business mode the player's own vehicle is ignored, because the Business Computer drives the flow and every read and write must hit the chosen fleet vehicle.
  function fuelSeam.getFuelingVehicle()
    if businessCtx and businessCtx.vehObjId then
      local obj = getObjectByID(businessCtx.vehObjId)
      if obj then return obj end
    end
    if targetVehObjId then
      local obj = getObjectByID(targetVehObjId)
      if obj then return obj end
    end
    return getPlayerVehicle(0)
  end

  -- The owned vehicle to refuel: the walked-up target, the current inventory vehicle, or the seated owned vehicle. Inventory "current" can be unset after a walk-enter, so the seated vehicle is the fallback.
  function fuelSeam.resolvePlayerInventoryId()
    if targetVehObjId then
      return overhaul_career_garage_inventory.getInventoryIdFromVehicleId(targetVehObjId)
    end
    local invId = overhaul_career_garage_inventory.getCurrentVehicle()
    if invId then return invId end
    local playerVehId = be:getPlayerVehicleID(0)
    if playerVehId and playerVehId > 0 then
      return overhaul_career_garage_inventory.getInventoryIdFromVehicleId(playerVehId)
    end
    return nil
  end

  local function detectBusinessCtxForPlayerVehicle()
    local objId = targetVehObjId or be:getPlayerVehicleID(0)
    if not objId or objId < 0 then return nil end
    local businessId, vehicleId = capabilities.get("businessVehicles").getBusinessVehicleFromSpawnedId(objId)
    if not businessId or not vehicleId then return nil end
    return { businessId = businessId, vehicleId = vehicleId, vehObjId = objId }
  end

  function fuelSeam.isBusinessTransaction()
    return businessCtx ~= nil
  end

  -- startFuelingTank's guard: a business transaction or an owned vehicle to fuel.
  function fuelSeam.hasFuelingTarget()
    return businessCtx or fuelSeam.resolvePlayerInventoryId()
  end

  -- startTransaction's guard. vehObjId is the spawned vehicle to fill instead of the player's vehicle. Returns false, and forgets the target, when there is nothing to fuel.
  function fuelSeam.beginTransaction(vehObjId)
    if vehObjId and vehObjId ~= be:getPlayerVehicleID(0) then
      targetVehObjId = vehObjId
    end
    -- startForBusinessVehicle may have already set businessCtx; only detect when nothing supplied one.
    if not businessCtx then
      businessCtx = detectBusinessCtxForPlayerVehicle()
    end
    if not businessCtx and not fuelSeam.resolvePlayerInventoryId() then
      targetVehObjId = nil
      return false
    end
    return true
  end

  function fuelSeam.showStationPrices()
    overhaul_world_fuel_fuelPrice.setDisplayPrices()
  end

  -- Forgets the transaction's vehicle. Returns true when it routed back to a Business Computer screen, and false when the caller should continue to gameplay.
  function fuelSeam.finishTransaction()
    businessCtx = nil
    targetVehObjId = nil

    if pendingBizReturn then
      local info = pendingBizReturn
      pendingBizReturn = nil
      extensions.ui_router.navigate('business-computer', {
        businessType = info.businessType,
        businessId = info.businessId,
      })
      return true
    end
    return false
  end

  -- Bills a business fleet refuel, returns true, and returns false for a player refuel. The team account pays when it can; otherwise the player pays personally, so the pump transaction still completes. getPrice is read at each use, because a callback during the debit can end the transaction and reset it.
  function fuelSeam.payForBusinessVehicle(getPrice, gasStation)
    local stationName = (gasStation and gasStation.facility and gasStation.facility.name) or "fuel station"
    local stationLabel = "Refuelled at " .. (translateLanguage(stationName, stationName, true))

    if not businessCtx then return false end
    -- Only the Racing Team has a fuel debit helper, and the finances module is optional because the fuel extension's onUpdate debug window also reaches this code.
    local paid = false
    if overhaul_career_business_racingTeam_finances then
      paid = overhaul_career_business_racingTeam_finances.tryDebitVehicleFuelCost(
        businessCtx.businessId, getPrice(), stationLabel)
    end
    if paid then
      if getPrice() > 0 then
        ui_message("Fuel billed to the team account", 6, "refueling")
      end
      gameplay_statistic.metricAdd("career/fuel/paidPrice.money", getPrice())
    else
      overhaul_career_economy_playerAttributes.addAttributes({money = -getPrice()}, require("overhaul/lib/finance/metadata").tag({tags = {"fuel","buying"}, label = stationLabel}, "fuel", {vehicleId = fuelSeam.resolvePlayerInventoryId(), locationId = gasStation and gasStation.facility and gasStation.facility.id, locationName = gasStation and gasStation.facility and gasStation.facility.name}))
      gameplay_statistic.metricAdd("career/fuel/paidPrice.money", getPrice())
      if getPrice() > 0 then
        ui_message("Team account couldn't cover fuel; paid personally", 6, "refueling")
      end
    end
    return true
  end

  -- A company vehicle of the player's employer is fuelled on the company while the player is on shift.
  function fuelSeam.isEmployerVehicleOnShift(vehData)
    return vehData.loanType == "company"
      and overhaul_career_work_employment
      and overhaul_career_work_employment.isOnShift()
      and vehData.owningOrganization == overhaul_career_work_employment.getEmployerOrgId()
  end

  -- The seated owned vehicle's id, for the minimum-refuel check.
  function fuelSeam.currentVehicleId()
    local invId = fuelSeam.resolvePlayerInventoryId()
    return invId and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(invId)
  end

  -- Recovery-contract targets keep their fuel, so they get no emergency refuel.
  function fuelSeam.skipMinimumRefuel(vehId)
    return vehId and overhaul_jobs_recovery and overhaul_jobs_recovery.isContractTarget
      and overhaul_jobs_recovery.isContractTarget(vehId)
  end

  -- Starts a shop-stockpile refuel of a business vehicle against the synthetic station, billed to the team at the average price. Returns true on success, or false with a reason code when the vehicle cannot be refuelled right now.
  function fuelSeam.startForBusinessVehicle(businessId, vehicleId, startTransaction)
    if not businessId or not vehicleId then
      return false, "invalidArgs"
    end
    local spawnedId = capabilities.get("businessVehicles").getSpawnedVehicleId(businessId, vehicleId)
    if not spawnedId then
      return false, "notPulledOut"
    end
    local vehObj = getObjectByID(spawnedId)
    if not vehObj then
      return false, "notPulledOut"
    end

    -- Enter the fleet vehicle so getPlayerVehicle(0) returns it while the refuel dialog is open.
    be:enterVehicle(0, vehObj)

    businessCtx = {
      businessId = businessId,
      vehicleId = vehicleId,
      vehObjId = spawnedId,
    }
    pendingBizReturn = {
      businessId = businessId,
      businessType = "racingTeam",
    }

    local syntheticStation = {
      facility = {
        id = SHOP_STATION_ID,
        name = "Shop Stockpile",
      },
    }
    startTransaction(syntheticStation)
    return true
  end

  return fuelSeam
end

return M
