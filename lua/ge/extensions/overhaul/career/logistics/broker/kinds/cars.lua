-- Car-haul board loads stage owner-operator cars at pickup; stateless handlers use broker services.
-- Read collectBoard, sync, reserve, release, abandon in order.

local KIND = "cars"
local M = { id = KIND, nativeKind = "finkHaul" }

function M.collectBoard(brokerContext)
  for _, contract in ipairs(brokerContext.readCurrentOffers(brokerContext.ownerOp().listContracts) or {}) do
    if contract.kind == M.nativeKind and not brokerContext.booked(KIND, contract.id) then
      local native = brokerContext.ownerOp().getBrokerOffer(contract.id)
      if native then
        local fac = brokerContext.gen().getFacilityById(contract.originFacId)
        local ps = fac and (fac.pickUpSpots[1] or fac.inspectSpots[1])
        local first = native.vehicles and native.vehicles[1]
        local dest = first and { type = "facilityParkingspot", facId = first.destFacId, psPath = first.destPsPath }
        local unlocked = brokerContext.flagRequirement("logisticsCarHauling").unlocked
        brokerContext.cachedOffer(KIND .. ":" .. contract.id, KIND, native, {unlocked, contract, native.vehicles, ps and ps:getPath()}, function() return {
          nativeId = contract.id,
          market = "cars",
          title = contract.title,
          origin = { type = "facilityParkingspot", facId = contract.originFacId, psPath = ps and ps:getPath() },
          destination = dest,
          pay = contract.pay,
          quantity = #(native.vehicles or {}),
          unit = "vehicles",
          vehicles = deepcopy(contract.vehicles),
          requirement = "Car transport equipment",
          arrangement = "own",
          unlocked = unlocked,
          destinations = contract.destinations,
        } end)
      end
    end
  end
end

-- The contract's vehicles drive the job: staged or delivered cars make it active, and a contract that is gone completes it.
function M.sync(brokerContext, job)
  local active = brokerContext.ownerOp().getActiveContract()
  if active and active.id == job.nativeId then
    job.vehicles = deepcopy(active.vehicles or {})
    for _, v in ipairs(job.vehicles) do
      local offer = v.offerId and brokerContext.vehicles().getOfferById(v.offerId)
      if offer and offer.vehicle and not v.thumbnail then
        local m = core_vehicles.getModel(offer.vehicle.model)
        local cfg = m and m.configs and offer.vehicle.config and m.configs[offer.vehicle.config]
        v.thumbnail = cfg and cfg.preview or nil
      end
      if v.status == "delivered" or (offer and offer.spawned) then job.status = "active" end
    end
  elseif job.status == "active" then
    job.status = "complete"
  end
end

function M.reserve(brokerContext, job, row, native)
  job.native = deepcopy(native)
  return true
end

function M.release(brokerContext, job)
  if not brokerContext.ownerOp().cancelUnstartedBrokerContract(job.nativeId) then
    return false, "Vehicle collection has already begun."
  end
  return true
end

function M.abandon(brokerContext, job)
  if not brokerContext.ownerOp().abandonBrokerContract(job.nativeId) then return false, "This contract is unavailable." end
  return true
end

function M.abandonQuote(brokerContext, job) return brokerContext.vehicleTaskFine(job.id) end

-- One stop per distinct destination parking spot among the cars.
function M.destinations(row)
  local out, seen = {}, {}
  for _, car in ipairs(row.vehicles or {}) do
    local key = tostring(car.destFacId) .. ":" .. tostring(car.destPsPath)
    if not seen[key] then
      out[#out + 1] = { type = "facilityParkingspot", facId = car.destFacId, psPath = car.destPsPath }
      seen[key] = true
    end
  end
  return out
end

function M.pickup(brokerContext, job, args, finish)
  local active = brokerContext.ownerOp().getActiveContract()
  if not active or active.id ~= job.nativeId then
    local ok, msg = brokerContext.ownerOp().startBrokerContract(job.native)
    if not ok then return false, msg end
  end
  local ok, msg = brokerContext.ownerOp().stageCarHaulTrip(args.selectedCars or {})
  brokerContext.syncJobs()
  finish(ok, msg)
  return ok, msg
end

function M.requirements(ctx)
  return {ctx.flagRequirement("logisticsCarHauling")}
end
function M.pickupArea(ctx, row)
  local fac = row.origin and ctx.gen().getFacilityById(row.origin.facId)
  return require("overhaul/career/logistics/broker/presence").area(row, fac,
    {"pickUpSpots", "inspectSpots", "trailerSpots", "dropOffSpots", "accessPointsByName"})
end
function M.fit(profile, row, capabilities)
  local info = capabilities.getProfile(profile)
  return info and info.hasFlatbed == true or false
end

return M
