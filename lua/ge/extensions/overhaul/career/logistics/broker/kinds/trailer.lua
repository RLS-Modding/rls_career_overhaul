-- Trailer loads: a trailer offer the player tows from its bay; the offer's brokerId and expiry hold it while reserved. Stateless: every service comes from the broker's ctx.
-- Read collect, sync, reserve, release, abandon in order.

local KIND = "trailer"
local M = { id = KIND }

-- The trailer's own config preview, so the offer shows what you will tow rather than where it waits.
local function trailerPreview(vehicle)
  local model = vehicle and vehicle.model and core_vehicles.getModel(vehicle.model)
  local config = model and model.configs and vehicle.config and model.configs[vehicle.config]
  return config and config.preview or nil
end

function M.collect(brokerContext, fac)
  for _, offer in ipairs(brokerContext.readCurrentOffers(brokerContext.vehicles().getAllOfferAtFacilityUnexpired, fac.id) or {}) do
    if offer.data and offer.data.type == "trailer" and not brokerContext.booked(KIND, offer.id) then
      brokerContext.gen().finalizeVehicleOffer(offer)
      local tag = offer.vehicle and (offer.vehicle.unlockTag or offer.vehicle.filterId) or ""
      local unlocked = brokerContext.vehicles().isVehicleTagUnlocked(tag)
      local title = brokerContext.text(offer.vehicle and (offer.vehicle.filterName or offer.vehicle.name) or "Trailer load")
      local trailerType = brokerContext.vehicles().getVehicleTagLabelSingular(tag)
      local inputs = {offer.id, title, offer.origin, offer.task.destination, offer.rewards and offer.rewards.money, trailerType, unlocked}
      brokerContext.cachedOffer(KIND .. ":" .. offer.id, KIND, offer, inputs, function() return {
        nativeId = offer.id,
        market = "trailers",
        title = title,
        origin = brokerContext.destination(offer.origin),
        destination = brokerContext.destination(offer.task.destination),
        pay = offer.rewards and offer.rewards.money,
        trailerType = trailerType,
        couplerClass = require("overhaul/career/logistics/loanerCapabilities").getOfferCouplerClass(offer),
        vehiclePreview = trailerPreview(offer.vehicle),
        quantity = 1,
        unit = "trailer",
        requirement = "Compatible tow vehicle",
        arrangement = "supplied",
        unlocked = unlocked ~= false,
      } end)
    end
  end
end

function M.sync(brokerContext, job)
  local offer = brokerContext.vehicles().getOfferById(job.nativeId)
  if offer and offer.spawned then job.status = "active" end
end

function M.reserve(brokerContext, job, row, native)
  job.originalExpiry = native.offerExpiresAt
  native.offerExpiresAt = 1e30
  native.brokerId = job.id
  return true
end

function M.release(brokerContext, job)
  local offer = brokerContext.vehicles().getOfferById(job.nativeId)
  if offer then
    offer.brokerId = nil
    offer.offerExpiresAt = math.max(brokerContext.now() + 60, job.originalExpiry or 0)
  end
  return true
end

function M.abandon(brokerContext, job)
  local offer = brokerContext.vehicles().getOfferById(job.nativeId)
  if not (offer and offer.vehicle and offer.vehicle.vehId) then return false, "The trailer is unavailable." end
  brokerContext.vehicleTasks().giveBackDeliveryVehicle(offer.vehicle.vehId)
  return true
end

function M.abandonQuote(brokerContext, job) return brokerContext.vehicleTaskFine(job.id) end

-- Collecting spawns the trailer on its bay. Pickup needs the job still reserved; finish runs when it lands.
function M.pickup(brokerContext, job, args, finish)
  if job.status ~= "reserved" then return false, "This trailer has already been collected." end
  brokerContext.vehicles().spawnOffer(job.nativeId, true, brokerContext.collectionCallback(function()
    local offer = brokerContext.vehicles().getOfferById(job.nativeId)
    if offer and offer.spawned then
      job.status = "active"
      finish(true, "Trailer ready for collection.")
    else
      finish(false, "The trailer could not be placed. Clear the pickup bay and retry.")
    end
  end))
  return true, "Collecting trailer…"
end

-- Saved trailer jobs re-bind to the offer that still carries their broker id after a load.
function M.restoreOffer(brokerContext, job, offer) job.nativeId = offer.id end

function M.vehicleDelivered(brokerContext, job) job.status = "complete" end

function M.vehicleAbandoned(brokerContext, job) job.status = "cancelled" end

function M.requirements(ctx, row, native)
  local vehicle = native.vehicle or {}
  local unlocked, definition = ctx.vehicles().isVehicleTagUnlocked(vehicle.unlockTag or vehicle.filterId or "")
  return {{unlocked = unlocked ~= false, definition = definition, flag = vehicle.unlockTag or vehicle.filterId}}
end
function M.fit(profile, row, capabilities)
  return capabilities.canTowTrailer(profile, {couplerClass = row.couplerClass})
end

return M
