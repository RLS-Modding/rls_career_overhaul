-- Parcel cargo at a facility spot; a reserved job holds its parcel (data.brokerId) until cancelled, abandoned or delivered. Stateless: every service comes from the broker's ctx (ctx.parcels(), ctx.general(), ...).
-- Read findParcel, inVehicle, collect, sync, reserve in order.

local KIND = "parcel"
local M = { id = KIND, pickupProximity = true }

local function cargoIdentity(cargo)
  if cargo.templateId == nil then return nil end
  local modifiers = {}
  for _, modifier in ipairs(cargo.modifiers or {}) do modifiers[#modifiers + 1] = jsonEncode(modifier) end
  table.sort(modifiers)
  return jsonEncode({cargo.templateId, cargo.type, modifiers, cargo.loadedAtTimeStamp})
end

local function findParcel(brokerContext, job)
  for _, cargo in
    ipairs(
      brokerContext.parcels().getAllCargoCustomFilter(function(item) return item.data and item.data.brokerId == job.id end) or {}
    )
  do
    return cargo
  end
end

local function inVehicle(brokerContext, job)
  local moved = findParcel(brokerContext, job)
  return moved and moved.location.type == "vehicle"
end

function M.collect(brokerContext, fac)
  for _, cargo in ipairs(brokerContext.readCurrentOffers(brokerContext.parcels().getAllCargoForFacilityUnexpiredUndelivered, fac.id) or {}) do
    if cargo.type == KIND and not (cargo.data and cargo.data.brokerId) then
      brokerContext.gen().finalizeParcelItemDistanceAndRewards(cargo)
      local keys = {}
      for _, modifier in ipairs(cargo.modifiers or {}) do
        keys[modifier.type] = true
      end
      local locked = brokerContext.parcelMods().lockedBecauseOfMods(keys)
      local unlocked = not locked
      local reason = locked and "Logistics level required" or nil
      local title = brokerContext.text(cargo.name)
      local identity = cargoIdentity(cargo)
      local inputs = {cargo.id, title, cargo.origin, cargo.destination, cargo.rewards.money, cargo.slots, cargo.weight, unlocked, identity}
      brokerContext.cachedOffer(KIND .. ":" .. cargo.id, KIND, cargo, inputs, function() return {
        nativeId = cargo.id,
        cargoIdentity = identity,
        market = "parcels",
        title = title,
        origin = brokerContext.destination(cargo.origin),
        destination = brokerContext.destination(cargo.destination),
        pay = cargo.rewards.money,
        quantity = cargo.slots,
        unit = "slots",
        weight = cargo.weight,
        requirement = "Cargo space",
        arrangement = "own",
        unlocked = unlocked,
        lockedReason = reason,
      } end)
    end
  end
end

-- Cargo in a vehicle is active. Cargo that is deleted, or gone while no restore is pending, cancels the job.
function M.sync(brokerContext, job)
  local cargoItems = brokerContext.parcels().getAllCargoCustomFilter(function(item)
    return item.data and item.data.brokerId == job.id
  end) or {}
  local deleted = false
  for _, cargo in ipairs(cargoItems) do
    -- Refresh native identity as cargo changes; older saves recover it here too.
    job.cargoIdentity = cargoIdentity(cargo)
    if cargo.location and cargo.location.type == "vehicle" then
      job.status = "active"
      return
    end
    deleted = deleted or cargo.location and (cargo.location.type == "deleted" or cargo.location.type == "delete")
  end
  if deleted or (#cargoItems == 0 and job.status == "active" and not brokerContext.awaitingCargoRestore(job.id)) then
    job.status = "cancelled"
  end
end

function M.reserve(brokerContext, job, row, native)
  job.cargoIdentity = row.cargoIdentity
  native.data = native.data or {}
  native.data.brokerId = job.id
  job.originalExpiry = native.offerExpiresAt
  native.offerExpiresAt = 1e30
  return true
end

function M.release(brokerContext, job)
  local cargo = findParcel(brokerContext, job)
  if cargo then
    cargo.data.brokerId = nil
    cargo.offerExpiresAt = math.max(brokerContext.now() + 60, job.originalExpiry or 0)
  end
  return true
end

function M.abandon(brokerContext, job)
  local fine = brokerContext
    .general()
    .getDeliveryModePenalty(nil, false, function(item) return item.data and item.data.brokerId == job.id end)
  for _, cargo in
    ipairs(brokerContext.parcels().getAllCargoCustomFilter(function(item) return item.data and item.data.brokerId == job.id end))
  do
    brokerContext.parcels().changeCargoLocation(cargo.id, { type = "deleted" })
  end
  brokerContext.playerAttributes().addAttributes(fine, { category = "fine", tags = { "gameplay", "delivery", "fine" }, label = "Cargo abandonment" })
  brokerContext.general().requestUpdateContainerWeights()
  return true
end

function M.abandonQuote(brokerContext, job)
  local fine = brokerContext
    .general()
    .getDeliveryModePenalty(nil, false, function(item) return item.data and item.data.brokerId == job.id end)
  return -(fine.money or 0)
end

-- Single load: one parcel into the chosen container.
function M.pickup(brokerContext, job, args, finish)
  return brokerContext.withContainer(job, args.containerKey, finish, function(target)
    local cargo = findParcel(brokerContext, job)
    if not cargo or cargo.location.type ~= "facilityParkingspot" or cargo.location.facId ~= job.origin.facId then
      finish(false, "This cargo has already moved.")
      return
    end
    if not target.cargoTypesLookup.parcel or target.freeCargoSlots < cargo.slots then
      finish(false, "This container needs more compatible cargo space.")
      return
    end
    local emp = brokerContext.employment()
    if emp and emp.canMoveCargoOntoLocation and not emp.canMoveCargoOntoLocation(cargo.id, target.location) then
      finish(false, "This vehicle cannot accept independent cargo.")
      return
    end
    if #(brokerContext.parcels().getTransientMoveCargo() or {}) > 0 then
      finish(false, "Finish the existing loading operation first.")
      return
    end
    brokerContext.cargoScreen().moveCargoFromUi(cargo.id, target.location)
    brokerContext.cargoScreen().commitDeliveryConfiguration(brokerContext.collectionCallback(function()
      local moved = findParcel(brokerContext, job)
      finish(
        moved and moved.location.type == "vehicle",
        moved and moved.location.type == "vehicle" and "Cargo loaded."
          or "Cargo could not be loaded. Retry at the pickup."
      )
    end))
  end, args.startHere)
end

-- Each parcel is checked against the space left in its box, for "Load now" and multi-parcel pickup.
M.batch = {}

function M.batch.precheck(brokerContext)
  if #(brokerContext.parcels().getTransientMoveCargo() or {}) > 0 then
    return false, "Finish the existing loading operation first."
  end
  return true
end

function M.batch.stage(brokerContext, prepared)
  local job, box = prepared.job, prepared.box
  local cargo = findParcel(brokerContext, job)
  local title = job.title or "A parcel"
  if not cargo or cargo.location.type ~= "facilityParkingspot" or cargo.location.facId ~= job.origin.facId then
    return false, title .. " has already moved."
  end
  if not box.con.cargoTypesLookup.parcel then return false, box.con.moveToLabel .. " cannot carry parcels." end
  if box.left < (cargo.slots or 0) then
    return false, "Not enough room in " .. box.con.moveToLabel .. " for " .. title .. "."
  end
  local emp = brokerContext.employment()
  if emp and emp.canMoveCargoOntoLocation and not emp.canMoveCargoOntoLocation(cargo.id, box.con.location) then
    return false, "This vehicle cannot accept independent cargo."
  end
  box.left = box.left - (cargo.slots or 0)
  prepared.cargo = cargo
  prepared.target = box.con.location
  return true
end

function M.batch.move(brokerContext, prepared) brokerContext.cargoScreen().moveCargoFromUi(prepared.cargo.id, prepared.target) end

function M.batch.loaded(brokerContext, job) return inVehicle(brokerContext, job) and true or false end

-- Reserved parcels still waiting at their pickup spot (the vanilla "Pick Up" prompt).
function M.reservedPickup(brokerContext, job)
  local origin = job.origin
  if job.status == "reserved" and job.map == brokerContext.mapId() and origin and origin.psPath then
    return {
      facId = origin.facId,
      psPath = origin.psPath,
      jobId = job.id,
      title = job.title,
      slots = tonumber(job.quantity) or 0,
    }
  end
end

function M.cargoDelivered(brokerContext, job) job.status = "complete" end

function M.requirements(ctx, row, native)
  local out = {}
  for _, modifier in ipairs(native.modifiers or {}) do
    local locked, definition = ctx.parcelMods().lockedBecauseOfMods({[modifier.type] = true})
    out[#out + 1] = {unlocked = not locked, definition = definition, flag = modifier.type}
  end
  if #out == 0 then
    local locked, definition = ctx.parcelMods().lockedBecauseOfMods({})
    out[1] = {unlocked = not locked, definition = definition}
  end
  return out
end
function M.containerFits(row, container)
  return container.cargoTypesLookup.parcel and container.freeCargoSlots >= (row.quantity or 0)
end
function M.fit(profile, row, capabilities)
  if profile.isTrailer then
    local slots = profile.capacityByType.parcel or 0
    return slots >= (tonumber(row.quantity) or 0)
  end
  return capabilities.canDoParcelJob(profile, row.quantity)
end

return M
