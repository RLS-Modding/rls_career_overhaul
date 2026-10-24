-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Fork of stock lua/ge/extensions/career/modules/loanerVehicles.lua (BeamNG 0.40).

-- Loaner vehicles: extension state, hourly rental billing, and the public API over the parts in loanerVehicles/.
-- Parts take explicit inputs: offers (unlock rules, marks, rates), spawn, returns (and the walk-away timer) and ui (menu rows).
local M = {}

local dateUtils = require("utils/dateUtils")
local facilityRole = require("overhaul/lib/logistics/facilityRole")
local issued = require("overhaul/lib/vehicles/issued")

M.dependencies = {"overhaul_shell_stepHandler"}

-- Scalar tuning for loaners: billing reads it here, the walk-away limits go to the returns part.
local config = {
  simSecondsPerHour = 3600,
  defaultHourlyRate = 30,
  walkAway = {
    radiusMeters = 100,
    comeBackRadiusMeters = 95,
    timeLimitSeconds = 300,
    warningTimeSeconds = 60,
  },
}

-- Runtime state of this extension instance. A fresh load starts over; the parts read and write these fields.
local loanerState = {
  markedForSpawningLoaners = {}, -- offer id -> offer queued for the next spawn
  vehicleAdded = false,          -- true once the car being spawned has been announced to the spawn sequence
  spawnBlocked = nil,            -- the occupied-stall prompt while it is open
  walkAwayTimers = {},           -- inventory id -> seconds left before an abandoned loaner is returned
}

-- Sim time accrues while a rental is out, whole hours are charged as they pass, and the part hour is settled when the car comes back.
-- Broker rentals bill to the cent; every other rental bills to the whole unit.
local BROKER_RENTAL_PRECISION = 100
local WHOLE_UNIT_PRECISION = 1

local function deliveryGameTime()
  return overhaul_career_logistics_general and overhaul_career_logistics_general.time() or nil
end

local function deliverySimPaused()
  return overhaul_career_logistics_general and overhaul_career_logistics_general.isDeliveryTimePaused() or false
end

-- Billed time is kept in seconds; older saves only recorded whole billed hours.
local function rentalBilledSimSeconds(vehInfo)
  if vehInfo.rentalBilledSimSeconds ~= nil then
    return math.max(0, tonumber(vehInfo.rentalBilledSimSeconds) or 0)
  end
  return math.max(0, tonumber(vehInfo.rentalBilledHours) or 0) * config.simSecondsPerHour
end

local function initRentalBilling(vehInfo)
  if not vehInfo then return end
  vehInfo.rentalSimAccrued = tonumber(vehInfo.rentalSimAccrued) or 0
  vehInfo.rentalBilledSimSeconds = rentalBilledSimSeconds(vehInfo)
  vehInfo.rentalLastGameTime = deliveryGameTime()
end

local function accrueRentalSimTime(vehInfo)
  local record = issued.forVehicle(vehInfo)
  if not record or not record.isRental then return 0 end
  if deliverySimPaused() then return 0 end
  local gameTime = deliveryGameTime()
  if not gameTime then return 0 end
  local lastGameTime = vehInfo.rentalLastGameTime
  if lastGameTime == nil then
    vehInfo.rentalLastGameTime = gameTime
    return 0
  end
  local elapsedSimSeconds = gameTime - lastGameTime
  if elapsedSimSeconds <= 0 then return 0 end
  vehInfo.rentalLastGameTime = gameTime
  vehInfo.rentalSimAccrued = (tonumber(vehInfo.rentalSimAccrued) or 0) + elapsedSimSeconds
  return elapsedSimSeconds
end

local function roundedCharge(vehInfo, amount)
  local precision = vehInfo.brokerRentalId and BROKER_RENTAL_PRECISION or WHOLE_UNIT_PRECISION
  return math.floor(amount * precision + 0.5) / precision
end

-- Takes the money and posts the toast only for a charge that is due.
local function postRentalCharge(charge, message, vehInfo)
  if charge > 0 and overhaul_career_economy_playerAttributes then
    overhaul_career_economy_playerAttributes.addAttributes({ money = -charge }, require("overhaul/lib/finance/metadata").tag({
      tags = { "fine", "rental" },
      label = "Hourly vehicle rental",
    }, "service", {vehicleId = vehInfo.id}))
    ui_message(message, 5, "info")
  end
  return charge
end

local function billRentalHours(vehInfo, hours)
  hours = math.max(0, tonumber(hours) or 0)
  if hours <= 0 then return 0 end
  local rate = tonumber(vehInfo.rentalHourlyRate) or config.defaultHourlyRate
  local charge = roundedCharge(vehInfo, rate * hours)
  return postRentalCharge(charge, string.format("Rental charge: $%.2f for %d sim hour%s.", charge, hours, hours == 1 and "" or "s"), vehInfo)
end

local function billRentalSimSeconds(vehInfo, simSeconds)
  simSeconds = math.max(0, tonumber(simSeconds) or 0)
  if simSeconds <= 0 then return 0 end
  local rate = tonumber(vehInfo.rentalHourlyRate) or config.defaultHourlyRate
  local charge = roundedCharge(vehInfo, rate * (simSeconds / config.simSecondsPerHour))
  local minutes = math.max(1, math.floor(simSeconds / 60 + 0.5))
  postRentalCharge(charge, string.format("Rental charge: $%.2f (%d sim min).", charge, minutes), vehInfo)
  vehInfo.rentalBilledSimSeconds = rentalBilledSimSeconds(vehInfo) + simSeconds
  return charge
end

-- Called once per frame for every vehicle: charges each whole hour that has passed since the last charge.
local function billWholeRentalHours(vehInfo)
  local record = issued.forVehicle(vehInfo)
  if not (record and record.isRental) then return end
  accrueRentalSimTime(vehInfo)
  local billed = rentalBilledSimSeconds(vehInfo)
  local unbilled = (tonumber(vehInfo.rentalSimAccrued) or 0) - billed
  local wholeHours = math.floor(unbilled / config.simSecondsPerHour)
  if wholeHours > 0 then
    billRentalHours(vehInfo, wholeHours)
    vehInfo.rentalBilledSimSeconds = billed + wholeHours * config.simSecondsPerHour
  end
end

-- Settles the part hour that accrued since the last whole-hour charge.
local function settleRentalOnReturn(vehInfo)
  local record = issued.forVehicle(vehInfo)
  if not record or not record.isRental then return end
  accrueRentalSimTime(vehInfo)
  local unbilled = (tonumber(vehInfo.rentalSimAccrued) or 0) - rentalBilledSimSeconds(vehInfo)
  if unbilled > 0 then
    billRentalSimSeconds(vehInfo, unbilled)
  end
end

local billing = {
  initRentalBilling = initRentalBilling,
  billWholeRentalHours = billWholeRentalHours,
  settleRentalOnReturn = settleRentalOnReturn,
}

-- Created in this order: each later part reads the earlier ones.
local parts = {}
parts.offers = require("overhaul/career/logistics/loanerVehicles/offers").new({
  state = loanerState,
})
parts.spawning = require("overhaul/career/logistics/loanerVehicles/spawn").new({
  state = loanerState,
  offers = parts.offers,
  initRentalBilling = initRentalBilling,
})
parts.returns = require("overhaul/career/logistics/loanerVehicles/returns").new({
  state = loanerState,
  offers = parts.offers,
  billing = billing,
  spawning = parts.spawning,
  facilityRole = facilityRole,
  walkAway = config.walkAway,
})
parts.ui = require("overhaul/career/logistics/loanerVehicles/ui").new({
  state = loanerState,
  offers = parts.offers,
  returns = parts.returns,
  dateUtils = dateUtils,
})

M.markForSpawning = parts.offers.markForSpawning
M.setMarkedForSpawning = parts.offers.setMarkedForSpawning
M.hasMarkedOffers = parts.offers.hasMarkedOffers
M.markCompanyOfferForSpawning = parts.offers.markCompanyOffer
M.unmarkAllForSpawning = parts.offers.unmarkAllForSpawning
M.isMaterialsEquipment = parts.offers.isMaterialsEquipment
M.usesIndependentHourlyRental = parts.offers.usesIndependentHourlyRental
M.getHourlyRateForOffer = parts.offers.getHourlyRateForOffer
M.initRentalBilling = initRentalBilling

M.spawnAllOffers = parts.spawning.spawnAllOffers
M.getBlockedSpawnStatus = parts.spawning.getBlockedSpawnStatus
M.spawnBlockedOffers = parts.spawning.spawnBlockedOffers
M.cancelBlockedSpawn = parts.spawning.cancelBlockedSpawn
M.consumeLastSpawnBatchResult = parts.spawning.consumeLastSpawnBatchResult

M.returnVehicle = parts.returns.returnVehicle
M.returnVehicles = parts.returns.returnVehicles
M.returnAllCompanyVehicles = parts.returns.returnAllCompanyVehicles
M.stepOutIfInCompanyVehicle = parts.returns.stepOutIfInCompanyVehicle
M.getLoanedVehiclesByOrg = parts.returns.getLoanedVehiclesByOrg

M.appliesRevenueShare = parts.ui.appliesRevenueShare
M.getLoaningOrgsOfVehicle = parts.ui.getLoaningOrgsOfVehicle
M.formatLoanerOfferForUi = parts.ui.formatLoanerOfferForUi
M.formatSpawnedLoanersForUi = parts.ui.formatSpawnedLoanersForUi

M.onUpdate = parts.returns.onUpdate
M.onOverhaulActive = function(active)
  if not active then parts.spawning.cancelBlockedSpawn() end
  parts.returns.onOverhaulActive(active)
end
M.onExtensionUnloaded = parts.spawning.cancelBlockedSpawn
M.onOverhaulVehicleAdded = parts.spawning.onOverhaulVehicleAdded

return M
