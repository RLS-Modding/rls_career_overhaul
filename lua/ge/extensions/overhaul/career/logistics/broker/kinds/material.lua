-- Material contracts: bulk cargo a facility's storage supplies, loaded into a container as a material parcel. Reserve accepts and cancel releases without a fine; abandoning charges one. Stateless: services come from ctx.
-- Read thousands, materialTrips, materialRequirement, collect, sync in order.

local cargoSemantics = require("overhaul/lib/logistics/cargoSemantics")
local rules = require("overhaul/career/logistics/broker/brokerRules")
local KIND = "material"
local M = { id = KIND }

local function thousands(n)
  return (tostring(math.floor(n + 0.5)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function materialTrips(contract)
  local total, load = tonumber(contract.totalAmount) or 0, tonumber(contract.standardLoad) or 0
  if total <= 0 or load <= 0 then return nil end
  local perTrip = math.min(load, total)
  local trips = math.ceil(total / perTrip - 1e-6)
  return string.format("%d trip%s of %s %s", trips, trips == 1 and "" or "s", thousands(perTrip), contract.units or "L")
end

local function materialRequirement(contract, materialType)
  local base = cargoSemantics.material(materialType).requirement
  local trips = materialTrips(contract)
  return trips and (base .. " · " .. trips) or base
end

function M.collect(brokerContext, fac)
  for _, contract in ipairs(brokerContext.readCurrentOffers(brokerContext.materials().getOffersForFacility, fac.id) or {}) do
    local material = brokerContext.gen().getMaterialsTemplatesById(contract.materialType)
    if material and not brokerContext.booked(KIND, contract.id) then
      local locked, definition = brokerContext.parcelMods().lockedBecauseOfMods({[material.type] = true})
      local reason = locked and (definition and definition.lockedReason
        and brokerContext.text(definition.lockedReason.label) or "Logistics level required") or nil
      local title = brokerContext.text(material.name)
      local inputs = {contract.id, title, material.type, contract.origin, contract.destination, contract.quotedRewards.money,
        contract.totalAmount, contract.units, contract.routeDistance, contract.standardLoad, not locked, reason, contract.materialType}
      brokerContext.cachedOffer(KIND .. ":" .. contract.id, KIND, contract, inputs, function() return {
        nativeId = contract.id,
        cargoIdentity = contract.materialType and tostring(contract.materialType) or nil,
        market = rules.materialMarket(material.type),
        subtype = material.type,
        standardLoad = contract.standardLoad,
        title = title,
        origin = brokerContext.destination(contract.origin),
        destination = brokerContext.destination(contract.destination),
        pay = contract.quotedRewards.money,
        quantity = contract.totalAmount,
        unit = contract.units or "L",
        haulDistance = contract.routeDistance,
        requirement = materialRequirement(contract, material.type),
        arrangement = "own",
        unlocked = not locked,
        lockedReason = reason,
      } end)
    end
  end
end

-- Only native delivery progress proves completion; disappearance can also mean abandonment.
function M.sync(brokerContext, job)
  local contract = brokerContext.materials().getContractById(job.nativeId)
  if contract then
    job.cargoIdentity = contract.materialType and tostring(contract.materialType) or nil
    job.delivered = contract.deliveredAmount or 0
    job.remaining = contract.remainingAmount
    job.inTransit = contract.inTransitAmount or 0
    local total = tonumber(contract.totalAmount or job.quantity) or 0
    if contract.status == "completed" or (total > 0 and job.delivered >= total) then
      job.status = "complete"
    elseif job.delivered > 0 or job.inTransit > 0 then
      job.status = "active"
    end
  elseif job.status == "active" or job.status == "reserved" then
    job.status = "cancelled"
  end
end

-- Progress calls this before removing a completed native contract.
M.cargoDelivered = M.sync

function M.reserve(brokerContext, job, row)
  if not brokerContext.materials().acceptBrokerContract(row.nativeId) then
    return false, "This contract is no longer available."
  end
  return true
end

function M.release(brokerContext, job)
  brokerContext.materials().abandonContract(job.nativeId, { noFine = true, silent = true })
  return true
end

function M.abandon(brokerContext, job)
  brokerContext.materials().abandonContract(job.nativeId)
  return true
end

function M.abandonQuote(brokerContext, job)
  local contract = brokerContext.materials().getContractById(job.nativeId)
  return contract and contract.abandonmentFine or 0
end

-- The native fine covers the undelivered order, including freight still at the
-- source. A discard only pays the share represented by this loaded quantity.
function M.cargoDiscardPenalty(brokerContext, job, cargo)
  local contract = brokerContext.materials().getContractById(job.nativeId)
  local remaining = contract and contract.remainingAmount or 0
  local fine = contract and contract.abandonmentFine or 0
  return {money = remaining > 0 and -fine * cargo.slots / remaining or 0}
end

-- The native loader owns its contract binding and does not stamp broker IDs.
function M.isCargoForJob(brokerContext, job, cargo)
  return cargo.data and cargo.data.materialContractId == job.nativeId
end

-- The phone opens the native loader; explicit API quantities still load directly.
function M.pickup(brokerContext, job, args, finish)
  if args.amount == nil then
    local contract = brokerContext.materials().getContractById(job.nativeId)
    local opened = contract and brokerContext.cargoScreen()
      .enterMaterialContractPickupScreen(contract.id, contract.origin.facId, contract.origin.psPath)
    finish(opened == true, opened and "Choose a quantity in the material loader." or "The material loader is unavailable.")
    return opened == true
  end
  return brokerContext.withContainer(job, args.containerKey, finish, function(target)
    local contract = brokerContext.materials().getContractById(job.nativeId)
    local material = contract and brokerContext.gen().getMaterialsTemplatesById(contract.materialType)
    local facility = contract and brokerContext.gen().getFacilityById(contract.sourceFacId)
    local storage = facility and facility.materialStorages[contract.materialType]
    local value = tonumber(args.amount)
    if not value and args.startHere and contract then
      value = math.min(target.freeCargoSlots or 0, contract.loadableAmount or 0,
        contract.standardLoad or job.standardLoad or math.huge)
    end
    if not value or value ~= value or value <= 0 or value == math.huge then
      finish(false, "Enter a positive quantity.")
      return
    end
    if not contract or not material or not storage or not target.cargoTypesLookup[material.type] then
      finish(false, "Choose compatible cargo capacity.")
      return
    end
    if target.rawCargo[1] and target.rawCargo[1].materialType ~= contract.materialType then
      finish(false, "Empty the other material first.")
      return
    end
    if value > math.min(contract.loadableAmount or 0, target.freeCargoSlots or 0) then
      finish(false, "Requested quantity exceeds free capacity or the remaining order.")
      return
    end
    local ok = brokerContext
      .gen()
      .addMaterialAsParcelToContainer(target, storage, value, contract.sourceFacId, contract.origin.psPath, contract.id)
    if ok then
      brokerContext.parcels().applyTransientMoves(contract.origin)
      for _, cargo in ipairs(brokerContext.parcels().getAllCargoInVehicles() or {}) do
        if cargo.data and cargo.data.materialContractId == job.nativeId then cargo.data.brokerId = job.id end
      end
      if not brokerContext.general().isDeliveryModeActive() then brokerContext.general().startDeliveryMode() end
      brokerContext.general().requestUpdateContainerWeights()
      brokerContext.tasklist().sendCargoToTasklist()
      brokerContext.materials().refreshTaskGuidance(true)
      job.status = "active"
    end
    -- The generator returns the loaded cargo table on success; the phone result expects a plain boolean.
    local loaded = ok ~= nil and ok ~= false
    finish(loaded, loaded and "Material loaded." or "Unable to load this quantity.")
  end, args.startHere)
end

function M.requirements(ctx, row)
  local locked, definition = ctx.parcelMods().lockedBecauseOfMods({[row.subtype] = true})
  return {{unlocked = not locked, definition = definition, flag = row.subtype}}
end
function M.containerFits(row, container)
  return container.cargoTypesLookup[row.subtype] and container.freeCargoSlots > 0
end
function M.fit(profile, row, capabilities)
  return capabilities.canHaulMaterial(profile, row.subtype, row.standardLoad)
end

return M
