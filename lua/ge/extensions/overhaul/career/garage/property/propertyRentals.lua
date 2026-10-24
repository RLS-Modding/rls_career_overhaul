-- Property leases, deposits, renter history, timed payments and evictions.
-- Read tuning/state, save/load and pricing, lease actions, payment/eviction steps, then hooks and exports.
local M = {}

local propertyMoneyFactory = require("overhaul/career/garage/property/money")
local ensureDir = require("overhaul/lib/save/ensureDir")

-- Config ------------------------------------------------------------------------------------------

local SIM_SECONDS_PER_GAME_DAY = require("overhaul/lib/career/gameTime").SIM_SECONDS_PER_GAME_DAY
-- Rent keeps its existing half-day payment interval; eviction cooldowns use full simulation days.
local RENT_PAYMENT_GAME_DAYS = 0.5
local PAYMENT_INTERVAL_S = RENT_PAYMENT_GAME_DAYS * SIM_SECONDS_PER_GAME_DAY
local EVICTION_COOLDOWN_DAYS = 5
local UPDATE_STEP_S = 5
local FIXED_RENT_RATE = 0.015
local DYNAMIC_RENT_RATE = 0.012
local UPFRONT_DISCOUNT = 0.87
local FALLBACK_BASE_VALUE = 50000
local SAVE_DIR = "/career/rls_career"
local SAVE_FILE = SAVE_DIR .. "/rentals.json"

-- Based on past rental behaviour only, so the tiers need no credit score.
local RENTAL_HISTORY_TIERS = {
  { id = "veteran",     label = "Veteran Renter",  minCompleted = 3, maxEvictions = 0, maxProperties = 4, depositMult = 1.0, types = {"fixed","dynamic","upfront"} },
  { id = "experienced", label = "Experienced",      minCompleted = 1, maxEvictions = 0, maxProperties = 3, depositMult = 1.5, types = {"fixed","dynamic","upfront"} },
  { id = "new",         label = "New Renter",        minCompleted = 0, maxEvictions = 0, maxProperties = 2, depositMult = 2.0, types = {"fixed","upfront"} },
  { id = "risky",       label = "Risky",             minCompleted = 0, maxEvictions = 999, maxProperties = 1, depositMult = 3.0, types = {"fixed"} },
}

-- State -------------------------------------------------------------------------------------------

local rentalData = {
  activeRentals = {},
  rentalHistory = {},
  evictionCooldowns = {},
}
local accumulatedSimTime = 0
local updateTimer = 0

-- Helpers -----------------------------------------------------------------------------------------

local propertyMoney = propertyMoneyFactory.new({
  category = "property",
  label = "Rent",
  payDescription = "Rental payment",
  rewardDescription = "Rental deposit return",
  source = "Rentals",
  deps = function()
    return overhaul_career_economy_payment, overhaul_career_economy_playerAttributes, overhaul_world_facilities,
      overhaul_phone_apps_layout
  end,
})

-- The phone's rentals screen re-reads its list on this event.
local function notifyRentalsChanged()
  guihooks.trigger("rentals:updated")
end

local function countActiveRentals()
  local count = 0
  for _ in pairs(rentalData.activeRentals) do count = count + 1 end
  return count
end

local function addHistoryEntry(garageId, rental, outcome)
  local entry = {
    garageId = garageId,
    type = rental.type,
    leaseStart = rental.leaseStart,
    leaseEnd = accumulatedSimTime,
    paymentsMade = rental.paymentsMade,
    missedPayments = outcome.missedPayments,
    evicted = outcome.evicted,
  }
  if outcome.earlyTermination then entry.earlyTermination = true end
  table.insert(rentalData.rentalHistory, entry)
end

local function upfrontLeaseDuration(rental)
  return rental.leaseTerm * PAYMENT_INTERVAL_S
end

local function upfrontLeaseElapsed(rental)
  return accumulatedSimTime - (rental.leaseStart or 0)
end

-- Renter tier -------------------------------------------------------------------------------------

local function countCompletedLeases()
  local count = 0
  for _, entry in ipairs(rentalData.rentalHistory) do
    if not entry.evicted and not entry.earlyTermination then count = count + 1 end
  end
  return count
end

local function countEvictions()
  local count = 0
  for _, entry in ipairs(rentalData.rentalHistory) do
    if entry.evicted then count = count + 1 end
  end
  return count
end

local function getRentalTier()
  local completed = countCompletedLeases()
  local evictions = countEvictions()
  if evictions > 0 then
    return RENTAL_HISTORY_TIERS[4]
  end
  for _, tier in ipairs(RENTAL_HISTORY_TIERS) do
    if completed >= tier.minCompleted and evictions <= tier.maxEvictions then
      return tier
    end
  end
  return RENTAL_HISTORY_TIERS[3]
end

local function getCreditDepositAdjustment()
  local scoreInfo = overhaul_career_economy_credit.getScore() or nil
  if not scoreInfo then return 0 end
  local score = scoreInfo.score or 500
  if score >= 650 then return -0.5 end
  if score >= 550 then return 0 end
  return 0.5
end

local function tierDepositMultiplier(tier)
  return math.max(1.0, tier.depositMult + getCreditDepositAdjustment())
end

local function canRentMore()
  local tier = getRentalTier()
  return countActiveRentals() < tier.maxProperties
end

local function isRentalTypeAvailable(rentalType)
  local tier = getRentalTier()
  for _, availableType in ipairs(tier.types) do
    if availableType == rentalType then return true end
  end
  return false
end

-- Pricing -----------------------------------------------------------------------------------------

local function getBaseValue(garageId)
  if overhaul_career_garage_garageManager and overhaul_career_garage_garageManager.getGaragePurchasePrice then
    local price = overhaul_career_garage_garageManager.getGaragePurchasePrice(garageId)
    if price and price > 0 then return price end
  end
  local facility = overhaul_world_facilities.getFacility("garage", garageId)
  if facility and facility.defaultPrice then return facility.defaultPrice end
  return FALLBACK_BASE_VALUE
end

local function rentFromBaseValue(baseValue, rentalType)
  if rentalType == "dynamic" then
    return math.floor(baseValue * DYNAMIC_RENT_RATE + 0.5)
  end
  return math.floor(baseValue * FIXED_RENT_RATE + 0.5)
end

local function depositFromRent(fixedRent, depositMult)
  return math.floor(fixedRent * 2 * depositMult + 0.5)
end

local function calculateRent(garageId, rentalType)
  return rentFromBaseValue(getBaseValue(garageId), rentalType)
end

local function calculateDeposit(garageId)
  local rent = calculateRent(garageId, "fixed")
  local tier = getRentalTier()
  return depositFromRent(rent, tierDepositMultiplier(tier))
end

-- Credit ------------------------------------------------------------------------------------------

local function recordMissedPayments(count)
  if overhaul_career_economy_credit and overhaul_career_economy_credit.recordMissedPayment then
    for _ = 1, count do overhaul_career_economy_credit.recordMissedPayment() end
  end
end

-- Relocation --------------------------------------------------------------------------------------

local function refreshGaragesAfterRentalEnded()
  if overhaul_career_garage_garageManager and overhaul_career_garage_garageManager.buildGarageSizes then
    overhaul_career_garage_garageManager.buildGarageSizes()
  end
  overhaul_ui_recoveryPrompt.addTowingButtons()
  overhaul_ui_recoveryPrompt.addTaxiButtons()
end

local function tryMoveVehicleToGarage(vehicleId, targetGarageId)
  if not (overhaul_career_garage_inventory and overhaul_career_garage_inventory.moveVehicleToGarage) then return false end
  return overhaul_career_garage_inventory.moveVehicleToGarage(vehicleId, targetGarageId) == true
end

local function moveIfGarageHasSpace(vehicleId, targetGarageId)
  local space = overhaul_career_garage_garageManager.isGarageSpace(targetGarageId)
  return space and space[1] and tryMoveVehicleToGarage(vehicleId, targetGarageId)
end

local function moveToOwnedGarage(vehicleId, leavingGarageId, purchasedGarages)
  if not purchasedGarages then return false end
  for _, targetGarageId in ipairs(purchasedGarages) do
    if targetGarageId ~= leavingGarageId and moveIfGarageHasSpace(vehicleId, targetGarageId) then
      return true
    end
  end
  return false
end

local function moveToOtherRentedGarage(vehicleId, leavingGarageId)
  for rentedId, _ in pairs(rentalData.activeRentals) do
    if rentedId ~= leavingGarageId and moveIfGarageHasSpace(vehicleId, rentedId) then
      return true
    end
  end
  return false
end

local function unlocateVehicle(vehicleId, garageId)
  local inventory = overhaul_career_garage_inventory
  local vehicle = inventory and inventory.getVehicles and inventory.getVehicles()[vehicleId]
  if vehicle and vehicle.location == garageId then
    vehicle.location = nil
    vehicle.niceLocation = nil
    if inventory.setVehicleDirty then inventory.setVehicleDirty(vehicleId) end
  end
  log("W", "propertyRentals", "Vehicle " .. tostring(vehicleId) .. " could not be relocated from " .. garageId)
end

local relocateVehicles = function(garageId)
  local vehicles = overhaul_career_garage_garageManager.getVehiclesInGarage(garageId)
  if not vehicles or #vehicles == 0 then return end
  local purchasedGarages = overhaul_career_garage_garageManager.getPurchasedGarages()
  for _, vehicleId in ipairs(vehicles) do
    local moved = moveToOwnedGarage(vehicleId, garageId, purchasedGarages)
      or moveToOtherRentedGarage(vehicleId, garageId)
    if not moved then unlocateVehicle(vehicleId, garageId) end
  end
end

-- Lease endings -----------------------------------------------------------------------------------

local function evictFromGarage(garageId)
  local rental = rentalData.activeRentals[garageId]
  if not rental then return end
  relocateVehicles(garageId)
  recordMissedPayments(3)
  addHistoryEntry(garageId, rental, { missedPayments = rental.missedPayments, evicted = true })
  rentalData.evictionCooldowns[garageId] = accumulatedSimTime + (EVICTION_COOLDOWN_DAYS * SIM_SECONDS_PER_GAME_DAY)
  rentalData.activeRentals[garageId] = nil
  refreshGaragesAfterRentalEnded()
  propertyMoney.notify("error", "Eviction", "You have been evicted from " .. propertyMoney.getGarageLabel(garageId) .. ". Security deposit forfeited.", "rentals.eviction", garageId)
  overhaul_career_saveSystem.saveCurrent()
end

local function endLeaseEarly(garageId)
  local rental = rentalData.activeRentals[garageId]
  if not rental then return { error = "no_rental" } end
  -- The deposit is forfeited and one month of rent is charged on top.
  local penalty = rental.monthlyRent
  if propertyMoney.canAfford(penalty) then
    propertyMoney.applyMoneyDelta(-penalty, garageId)
  end
  relocateVehicles(garageId)
  addHistoryEntry(garageId, rental, { missedPayments = rental.missedPayments, evicted = false, earlyTermination = true })
  rentalData.activeRentals[garageId] = nil
  refreshGaragesAfterRentalEnded()
  overhaul_career_saveSystem.saveCurrent()
  propertyMoney.notify("warning", "Lease Terminated", "Early termination for " .. propertyMoney.getGarageLabel(garageId) .. ". Deposit forfeited + penalty applied.", "rentals.leaseTerminated", garageId)
  notifyRentalsChanged()
  return { success = true }
end

-- Ends a lease that ran its full term: vehicles leave, the deposit comes back.
local function finishLeaseAndRelocate(garageId, rental, missedPayments, messageBeforeGarage, messageAfterGarage)
  relocateVehicles(garageId)
  addHistoryEntry(garageId, rental, { missedPayments = missedPayments, evicted = false })
  propertyMoney.applyMoneyDelta(rental.securityDeposit, garageId)
  propertyMoney.notify("success", "Lease Complete", messageBeforeGarage .. propertyMoney.getGarageLabel(garageId) .. messageAfterGarage, "rentals.leaseComplete", garageId)
  rentalData.activeRentals[garageId] = nil
  refreshGaragesAfterRentalEnded()
  overhaul_career_saveSystem.saveCurrent()
  notifyRentalsChanged()
end

-- Lease signing -----------------------------------------------------------------------------------

local function newLease(rentalType, monthlyRent, leaseTerm, deposit, upfrontTotal)
  local isUpfront = rentalType == "upfront"
  return {
    type = rentalType,
    monthlyRent = monthlyRent,
    leaseStart = accumulatedSimTime,
    leaseTerm = leaseTerm,
    paymentsRemaining = isUpfront and 0 or (leaseTerm - 1), -- first month already paid
    paymentsMade = isUpfront and leaseTerm or 1,
    missedPayments = 0,
    consecutiveMissed = 0,
    nextPaymentDue = isUpfront and 0 or (accumulatedSimTime + PAYMENT_INTERVAL_S),
    securityDeposit = deposit,
    upfrontPaid = upfrontTotal,
    warningLevel = 0,
    secondsUntilNextPayment = isUpfront and 0 or PAYMENT_INTERVAL_S,
  }
end

local function signLease(garageId, rentalType, leaseTerm)
  if require("overhaul/lib/business/bundles").forGarage(garageId) then return {error = "business_bundle_only"} end
  if not canRentMore() then return { error = "max_rentals_reached" } end
  if not isRentalTypeAvailable(rentalType) then return { error = "type_not_available" } end
  if rentalData.activeRentals[garageId] then return { error = "already_rented" } end
  if overhaul_career_garage_garageManager.isPurchasedGarage(garageId) then return { error = "already_owned" } end
  local cooldown = rentalData.evictionCooldowns[garageId]
  if cooldown and accumulatedSimTime < cooldown then
    return { error = "cooldown_active" }
  end

  leaseTerm = math.max(1, math.floor(tonumber(leaseTerm) or 12))
  local monthlyRent = calculateRent(garageId, rentalType)
  local deposit = calculateDeposit(garageId)

  local upfrontTotal = 0
  local totalCost
  if rentalType == "upfront" then
    upfrontTotal = math.floor(monthlyRent * leaseTerm * UPFRONT_DISCOUNT + 0.5)
    totalCost = upfrontTotal + deposit
  else
    totalCost = deposit + monthlyRent -- deposit + first month
  end
  if not propertyMoney.canAfford(totalCost) or not propertyMoney.applyMoneyDelta(-totalCost, garageId) then return { error = "insufficient_funds" } end

  rentalData.activeRentals[garageId] = newLease(rentalType, monthlyRent, leaseTerm, deposit, upfrontTotal)
  overhaul_career_economy_credit.recordOnTimePayment()
  overhaul_career_garage_garageManager.addDiscoveredGarage(garageId)
  overhaul_career_garage_garageManager.buildGarageSizes()
  overhaul_ui_recoveryPrompt.addTowingButtons()
  overhaul_ui_recoveryPrompt.addTaxiButtons()
  overhaul_career_saveSystem.saveCurrent()
  propertyMoney.notify("success", "Lease Signed", "You are now renting " .. propertyMoney.getGarageLabel(garageId) .. ".", "rentals.leaseSigned")
  notifyRentalsChanged()
  return { success = true, garageId = garageId }
end

-- Payments ----------------------------------------------------------------------------------------

local function scheduleNextPayment(rental)
  rental.nextPaymentDue = accumulatedSimTime + PAYMENT_INTERVAL_S
  rental.secondsUntilNextPayment = PAYMENT_INTERVAL_S
end

local function completeLeaseWithoutRelocation(garageId, rental)
  addHistoryEntry(garageId, rental, { missedPayments = rental.missedPayments, evicted = false })
  propertyMoney.applyMoneyDelta(rental.securityDeposit, garageId)
  propertyMoney.notify("success", "Lease Complete", "Lease for " .. propertyMoney.getGarageLabel(garageId) .. " complete. Deposit returned.", "rentals.leaseComplete", garageId)
  rentalData.activeRentals[garageId] = nil
  overhaul_career_saveSystem.saveCurrent()
end

local function handleMissedPayment(garageId, rental)
  rental.missedPayments = rental.missedPayments + 1
  rental.consecutiveMissed = rental.consecutiveMissed + 1
  scheduleNextPayment(rental)
  if rental.consecutiveMissed == 1 then
    propertyMoney.notify("warning", "Rent Due", "Rent payment for " .. propertyMoney.getGarageLabel(garageId) .. " was missed. Grace period active.", "rentals.rentDue")
  elseif rental.consecutiveMissed == 2 then
    rental.warningLevel = 1
    recordMissedPayments(1)
    propertyMoney.notify("warning", "Late Payment Notice", "Second missed rent payment for " .. propertyMoney.getGarageLabel(garageId), "rentals.rentDue")
  elseif rental.consecutiveMissed == 3 then
    rental.warningLevel = 2
    rental.monthlyRent = math.floor(rental.monthlyRent * 1.10 + 0.5)
    recordMissedPayments(1)
    propertyMoney.notify("error", "Final Notice", "Final warning! Rent increased 10% for " .. propertyMoney.getGarageLabel(garageId), "rentals.rentDue")
  else
    evictFromGarage(garageId)
  end
end

local function processRentPayment(garageId, rental)
  if rental.type == "upfront" then return end
  if rental.paymentsRemaining <= 0 then
    completeLeaseWithoutRelocation(garageId, rental)
    return
  end
  if rental.type == "dynamic" then
    rental.monthlyRent = calculateRent(garageId, "dynamic")
  end
  if propertyMoney.canAfford(rental.monthlyRent) and propertyMoney.applyMoneyDelta(-rental.monthlyRent, garageId) then
    rental.paymentsMade = rental.paymentsMade + 1
    rental.paymentsRemaining = rental.paymentsRemaining - 1
    rental.consecutiveMissed = 0
    scheduleNextPayment(rental)
    if overhaul_career_economy_credit and overhaul_career_economy_credit.recordOnTimePayment then
      overhaul_career_economy_credit.recordOnTimePayment()
    end
    return
  end
  handleMissedPayment(garageId, rental)
end

-- Per-frame update --------------------------------------------------------------------------------

local function expireUpfrontLease(garageId, rental)
  if upfrontLeaseElapsed(rental) < upfrontLeaseDuration(rental) then return end
  finishLeaseAndRelocate(garageId, rental, 0, "Prepaid lease for ", " has expired. Deposit returned.")
end

local function tickMonthlyPayment(garageId, rental)
  rental.secondsUntilNextPayment = (rental.secondsUntilNextPayment or PAYMENT_INTERVAL_S) - UPDATE_STEP_S
  if rental.secondsUntilNextPayment <= 0 then
    rental.secondsUntilNextPayment = PAYMENT_INTERVAL_S
    processRentPayment(garageId, rental)
    notifyRentalsChanged()
  end
end

local function tickRental(garageId, rental)
  if not rental then return end
  if rental.type == "upfront" then
    expireUpfrontLease(garageId, rental)
  elseif rental.paymentsRemaining > 0 then
    tickMonthlyPayment(garageId, rental)
  elseif ((rental.secondsUntilNextPayment or 0) - UPDATE_STEP_S) > 0 then
    rental.secondsUntilNextPayment = rental.secondsUntilNextPayment - UPDATE_STEP_S
  else
    rental.secondsUntilNextPayment = 0
    finishLeaseAndRelocate(garageId, rental, rental.missedPayments, "Lease for ", " complete. Deposit returned.")
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not overhaul_career_career or not overhaul_career_career.isActive() then return end
  accumulatedSimTime = accumulatedSimTime + dtSim
  updateTimer = updateTimer + dtSim
  if updateTimer < UPDATE_STEP_S then return end
  updateTimer = 0
  -- Ticking can end a lease, so walk a snapshot of the ids.
  local garageIds = {}
  for garageId, _ in pairs(rentalData.activeRentals) do
    table.insert(garageIds, garageId)
  end
  for _, garageId in ipairs(garageIds) do
    tickRental(garageId, rentalData.activeRentals[garageId])
  end
end

-- Save / load -------------------------------------------------------------------------------------

local function loadRentals()
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  local data = jsonReadFile(currentSavePath .. SAVE_FILE)
  if data then
    rentalData.activeRentals = data.activeRentals or {}
    rentalData.rentalHistory = data.rentalHistory or {}
    rentalData.evictionCooldowns = data.evictionCooldowns or {}
    accumulatedSimTime = data.simTime or 0
  end
end

local function saveRentals(currentSavePath, writer)
  if not currentSavePath then
    local _, profilePath = overhaul_career_saveSystem.getCurrentProfile()
    currentSavePath = profilePath
    if not currentSavePath then return end
  end
  ensureDir.directory(writer, currentSavePath .. SAVE_DIR)
  local data = deepcopy(rentalData)
  data.simTime = accumulatedSimTime
  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. SAVE_FILE, data, true)
end

-- Public API: queries -----------------------------------------------------------------------------

local function isRentedGarage(garageId)
  return rentalData.activeRentals[garageId] ~= nil
end

local function getActiveRentals()
  return rentalData.activeRentals
end

local function getRentalInfo(garageId)
  return rentalData.activeRentals[garageId]
end

local function getRentalEligibility()
  local tier = getRentalTier()
  local count = countActiveRentals()
  local depositMult = tierDepositMultiplier(tier)
  return {
    canRent = true,
    maxProperties = tier.maxProperties,
    currentRentals = count,
    availableTypes = tier.types,
    depositMultiplier = depositMult,
    tierLabel = tier.label,
    tierId = tier.id,
    creditEnhanced = overhaul_career_economy_credit ~= nil,
  }
end

local function leaseSecondsRemaining(rental)
  if rental.type == "upfront" then
    return math.max(0, upfrontLeaseDuration(rental) - upfrontLeaseElapsed(rental))
  end
  local nextPay = rental.secondsUntilNextPayment or 0
  local remaining = math.max(0, rental.paymentsRemaining or 0)
  return nextPay + remaining * PAYMENT_INTERVAL_S
end

local function getAllRentals()
  local result = {}
  for garageId, rental in pairs(rentalData.activeRentals) do
    local entry = deepcopy(rental)
    local facility = overhaul_world_facilities.getFacility("garage", garageId)
    entry.garageName = facility and facility.name or ("Garage " .. tostring(garageId))
    entry.garageId = garageId
    entry.leaseTimeRemaining = leaseSecondsRemaining(rental)
    result[garageId] = entry
  end
  return result
end

local function getRentalBreakdown(garageId)
  local baseValue = getBaseValue(garageId)
  local tier = getRentalTier()
  local depositMult = tierDepositMultiplier(tier)
  local fixedRent = rentFromBaseValue(baseValue, "fixed")
  local dynamicRent = rentFromBaseValue(baseValue, "dynamic")
  local deposit = depositFromRent(fixedRent, depositMult)
  local facility = overhaul_world_facilities.getFacility("garage", garageId)
  return {
    garageId = garageId,
    garageName = facility and facility.name or garageId,
    baseValue = baseValue,
    fixedRent = fixedRent,
    dynamicRent = dynamicRent,
    upfrontTotal12 = math.floor(fixedRent * 12 * UPFRONT_DISCOUNT + 0.5),
    upfrontTotal6 = math.floor(fixedRent * 6 * UPFRONT_DISCOUNT + 0.5),
    deposit = deposit,
    depositMultiplier = depositMult,
    tier = tier.label,
    tierId = tier.id,
    availableTypes = tier.types,
    canRent = canRentMore(),
    creditEnhanced = overhaul_career_economy_credit ~= nil,
    isOwned = overhaul_career_garage_garageManager.isPurchasedGarage(garageId),
    isRented = rentalData.activeRentals[garageId] ~= nil,
    cooldownActive = rentalData.evictionCooldowns[garageId] and accumulatedSimTime < rentalData.evictionCooldowns[garageId] or false,
  }
end

-- Game hooks --------------------------------------------------------------------------------------

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveRentals(currentSavePath, writer)
end

local function onExtensionLoaded()
  loadRentals()
end

local function onCareerActivated()
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  if FS:fileExists(currentSavePath .. SAVE_FILE) then
    loadRentals()
  else
    rentalData = { activeRentals = {}, rentalHistory = {}, evictionCooldowns = {} }
    accumulatedSimTime = 0
  end
end

M.signLease = signLease
M.endLeaseEarly = endLeaseEarly
M.isRentedGarage = isRentedGarage
M.getActiveRentals = getActiveRentals
M.getRentalInfo = getRentalInfo
M.getRentalEligibility = getRentalEligibility
M.getRentalBreakdown = getRentalBreakdown
M.getAllRentals = getAllRentals
M.calculateRent = calculateRent
M.calculateDeposit = calculateDeposit

M.onUpdate = onUpdate
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated

return M
