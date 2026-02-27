local M = {}
M.dependencies = { 'career_career', 'career_saveSystem', 'career_modules_garageManager',
                   'career_modules_playerAttributes' }
-- NOTE: career_modules_credit is NOT a dependency. It's optional.

local SIM_SECONDS_PER_GAME_DAY = 1200
local PAYMENT_INTERVAL_S = 300     -- 5 real minutes (matches mortgage)
local EVICTION_COOLDOWN_DAYS = 5

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/rentals.json"

-- Rental history tiers (credit-free — based on past rental behavior)
local RENTAL_HISTORY_TIERS = {
  { id = "veteran",     label = "Veteran Renter",  minCompleted = 3, maxEvictions = 0, maxProperties = 4, depositMult = 1.0, types = {"fixed","dynamic","upfront"} },
  { id = "experienced", label = "Experienced",      minCompleted = 1, maxEvictions = 0, maxProperties = 3, depositMult = 1.5, types = {"fixed","dynamic","upfront"} },
  { id = "new",         label = "New Renter",        minCompleted = 0, maxEvictions = 0, maxProperties = 2, depositMult = 2.0, types = {"fixed","upfront"} },
  { id = "risky",       label = "Risky",             minCompleted = 0, maxEvictions = 999, maxProperties = 1, depositMult = 3.0, types = {"fixed"} },
}

-- Runtime state
local rentalData = {
  activeRentals = {},
  rentalHistory = {},
  evictionCooldowns = {},
}
local accumulatedSimTime = 0
local updateTimer = 0

-- Forward declarations
local evictFromGarage
local relocateVehicles

-- ── Helpers ──

local function notify(type, title, msg)
  if guihooks and guihooks.trigger then
    guihooks.trigger('toastrMsg', { type = type, title = title, msg = msg })
  end
end

local function canAfford(amount)
  if amount <= 0 then return true end
  if career_modules_payment and career_modules_payment.canPay then
    return career_modules_payment.canPay({money = {amount = amount, canBeNegative = false}})
  end
  local money = (career_modules_playerAttributes and career_modules_playerAttributes.getAttributeValue and career_modules_playerAttributes.getAttributeValue("money")) or 0
  return money >= amount
end

local function applyMoneyDelta(amount)
  if amount < 0 then
    if career_modules_payment and career_modules_payment.pay then
      return career_modules_payment.pay({money = {amount = math.abs(amount), canBeNegative = false}}, {label = "Rent", description = "Rental payment"})
    end
  elseif amount > 0 then
    if career_modules_payment and career_modules_payment.reward then
      return career_modules_payment.reward({money = {amount = amount, canBeNegative = false}}, {label = "Rent", description = "Rental deposit return"})
    end
  end
  if career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({money = amount}, {label = "Rent"})
    return true
  end
  return false
end

-- ── Rental History Evaluation ──

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
    return RENTAL_HISTORY_TIERS[4] -- risky
  end
  for _, tier in ipairs(RENTAL_HISTORY_TIERS) do
    if completed >= tier.minCompleted and evictions <= tier.maxEvictions then
      return tier
    end
  end
  return RENTAL_HISTORY_TIERS[3] -- new renter default
end

local function getCreditDepositAdjustment()
  if not career_modules_credit then return 0 end
  local scoreInfo = career_modules_credit.getScore and career_modules_credit.getScore() or nil
  if not scoreInfo then return 0 end
  local score = scoreInfo.score or 500
  if score >= 650 then return -0.5 end
  if score >= 550 then return 0 end
  return 0.5
end

local function canRentMore()
  local tier = getRentalTier()
  local count = 0
  for _ in pairs(rentalData.activeRentals) do count = count + 1 end
  return count < tier.maxProperties
end

local function isRentalTypeAvailable(rentalType)
  local tier = getRentalTier()
  for _, t in ipairs(tier.types) do
    if t == rentalType then return true end
  end
  return false
end

-- ── Rent Calculation ──

local function getBaseValue(garageId)
  if career_modules_garageManager and career_modules_garageManager.getGaragePurchasePrice then
    local price = career_modules_garageManager.getGaragePurchasePrice(garageId)
    if price and price > 0 then return price end
  end
  -- fallback
  local facility = freeroam_facilities and freeroam_facilities.getFacility("garage", garageId)
  if facility and facility.defaultPrice then return facility.defaultPrice end
  return 50000
end

local function calculateRent(garageId, rentalType)
  local baseValue = getBaseValue(garageId)
  if rentalType == "dynamic" then
    return math.floor(baseValue * 0.012 + 0.5)
  end
  return math.floor(baseValue * 0.015 + 0.5)
end

local function calculateDeposit(garageId)
  local rent = calculateRent(garageId, "fixed")
  local tier = getRentalTier()
  local depositMult = math.max(1.0, tier.depositMult + getCreditDepositAdjustment())
  return math.floor(rent * 2 * depositMult + 0.5)
end

-- ── Lease Signing ──

local function signLease(garageId, rentalType, leaseTerm)
  if not canRentMore() then return { error = "max_rentals_reached" } end
  if not isRentalTypeAvailable(rentalType) then return { error = "type_not_available" } end
  if rentalData.activeRentals[garageId] then return { error = "already_rented" } end
  if career_modules_garageManager.isPurchasedGarage(garageId) then return { error = "already_owned" } end

  local cooldown = rentalData.evictionCooldowns[garageId]
  if cooldown and accumulatedSimTime < cooldown then
    return { error = "cooldown_active" }
  end

  leaseTerm = leaseTerm or 12
  local monthlyRent = calculateRent(garageId, rentalType)
  local deposit = calculateDeposit(garageId)

  local upfrontTotal = 0
  if rentalType == "upfront" then
    upfrontTotal = math.floor(monthlyRent * leaseTerm * 0.87 + 0.5)
    local totalCost = upfrontTotal + deposit
    if not canAfford(totalCost) then return { error = "insufficient_funds" } end
    applyMoneyDelta(-totalCost)
  else
    local totalCost = deposit + monthlyRent -- deposit + first month
    if not canAfford(totalCost) then return { error = "insufficient_funds" } end
    applyMoneyDelta(-totalCost)
  end

  rentalData.activeRentals[garageId] = {
    type = rentalType,
    monthlyRent = monthlyRent,
    leaseStart = accumulatedSimTime,
    leaseTerm = leaseTerm,
    paymentsRemaining = rentalType == "upfront" and 0 or (leaseTerm - 1), -- first month already paid
    paymentsMade = rentalType == "upfront" and leaseTerm or 1,
    missedPayments = 0,
    consecutiveMissed = 0,
    nextPaymentDue = rentalType == "upfront" and 0 or (accumulatedSimTime + PAYMENT_INTERVAL_S),
    securityDeposit = deposit,
    upfrontPaid = upfrontTotal,
    warningLevel = 0,
    secondsUntilNextPayment = rentalType == "upfront" and 0 or PAYMENT_INTERVAL_S,
  }

  if career_modules_credit and career_modules_credit.recordOnTimePayment then
    career_modules_credit.recordOnTimePayment()
  end

  career_modules_garageManager.addDiscoveredGarage(garageId)
  career_modules_garageManager.buildGarageSizes()
  if core_recoveryPrompt then
    core_recoveryPrompt.addTowingButtons()
    core_recoveryPrompt.addTaxiButtons()
  end

  career_saveSystem.saveCurrent()
  notify("success", "Lease Signed", "You are now renting " .. tostring(garageId) .. ".")
  return { success = true, garageId = garageId }
end

-- ── Payment Processing ──

local function processRentPayment(garageId, rental)
  if rental.type == "upfront" then return end
  if rental.paymentsRemaining <= 0 then
    -- Lease complete
    table.insert(rentalData.rentalHistory, {
      garageId = garageId,
      type = rental.type,
      leaseStart = rental.leaseStart,
      leaseEnd = accumulatedSimTime,
      paymentsMade = rental.paymentsMade,
      missedPayments = rental.missedPayments,
      evicted = false,
    })
    -- Return deposit
    applyMoneyDelta(rental.securityDeposit)
    notify("success", "Lease Complete", "Lease for " .. garageId .. " complete. Deposit returned.")
    rentalData.activeRentals[garageId] = nil
    career_saveSystem.saveCurrent()
    return
  end

  -- Dynamic rent: recalculate each period
  if rental.type == "dynamic" then
    rental.monthlyRent = calculateRent(garageId, "dynamic")
  end

  if canAfford(rental.monthlyRent) then
    applyMoneyDelta(-rental.monthlyRent)
    rental.paymentsMade = rental.paymentsMade + 1
    rental.paymentsRemaining = rental.paymentsRemaining - 1
    rental.consecutiveMissed = 0
    rental.nextPaymentDue = accumulatedSimTime + PAYMENT_INTERVAL_S
    rental.secondsUntilNextPayment = PAYMENT_INTERVAL_S
    if career_modules_credit and career_modules_credit.recordOnTimePayment then
      career_modules_credit.recordOnTimePayment()
    end
    return
  end

  -- Missed payment
  rental.missedPayments = rental.missedPayments + 1
  rental.consecutiveMissed = rental.consecutiveMissed + 1
  rental.nextPaymentDue = accumulatedSimTime + PAYMENT_INTERVAL_S
  rental.secondsUntilNextPayment = PAYMENT_INTERVAL_S

  if rental.consecutiveMissed == 1 then
    notify("warning", "Rent Due", "Rent payment for " .. garageId .. " was missed. Grace period active.")
  elseif rental.consecutiveMissed == 2 then
    rental.warningLevel = 1
    if career_modules_credit and career_modules_credit.recordMissedPayment then
      career_modules_credit.recordMissedPayment()
    end
    notify("warning", "Late Payment Notice", "Second missed rent payment for " .. garageId)
  elseif rental.consecutiveMissed == 3 then
    rental.warningLevel = 2
    rental.monthlyRent = math.floor(rental.monthlyRent * 1.10 + 0.5)
    if career_modules_credit and career_modules_credit.recordMissedPayment then
      career_modules_credit.recordMissedPayment()
    end
    notify("error", "Final Notice", "Final warning! Rent increased 10% for " .. garageId)
  else
    evictFromGarage(garageId)
  end
end

-- ── Vehicle Relocation ──

relocateVehicles = function(garageId)
  local vehicles = career_modules_garageManager.getVehiclesInGarage(garageId)
  if not vehicles or #vehicles == 0 then return end

  local purchasedGarages = career_modules_garageManager.getPurchasedGarages()

  for _, vehicleId in ipairs(vehicles) do
    local moved = false
    -- Try owned garages
    if purchasedGarages then
      for _, targetGarageId in ipairs(purchasedGarages) do
        if targetGarageId ~= garageId then
          local space = career_modules_garageManager.isGarageSpace(targetGarageId)
          if space and space[1] then
            if career_modules_inventory and career_modules_inventory.moveVehicleToGarage then
              career_modules_inventory.moveVehicleToGarage(vehicleId, targetGarageId)
            end
            moved = true
            break
          end
        end
      end
    end
    -- Try other rented garages
    if not moved then
      for rentedId, _ in pairs(rentalData.activeRentals) do
        if rentedId ~= garageId then
          local space = career_modules_garageManager.isGarageSpace(rentedId)
          if space and space[1] then
            if career_modules_inventory and career_modules_inventory.moveVehicleToGarage then
              career_modules_inventory.moveVehicleToGarage(vehicleId, rentedId)
            end
            moved = true
            break
          end
        end
      end
    end
    if not moved then
      log("W", "propertyRentals", "Vehicle " .. tostring(vehicleId) .. " could not be relocated from " .. garageId)
    end
  end
end

-- ── Eviction ──

evictFromGarage = function(garageId)
  local rental = rentalData.activeRentals[garageId]
  if not rental then return end

  relocateVehicles(garageId)

  if career_modules_credit and career_modules_credit.recordMissedPayment then
    career_modules_credit.recordMissedPayment()
    career_modules_credit.recordMissedPayment()
    career_modules_credit.recordMissedPayment()
  end

  table.insert(rentalData.rentalHistory, {
    garageId = garageId,
    type = rental.type,
    leaseStart = rental.leaseStart,
    leaseEnd = accumulatedSimTime,
    paymentsMade = rental.paymentsMade,
    missedPayments = rental.missedPayments,
    evicted = true,
  })

  rentalData.evictionCooldowns[garageId] = accumulatedSimTime + (EVICTION_COOLDOWN_DAYS * SIM_SECONDS_PER_GAME_DAY)
  rentalData.activeRentals[garageId] = nil

  notify("error", "Eviction", "You have been evicted from " .. garageId .. ". Security deposit forfeited.")
  career_saveSystem.saveCurrent()
end

-- ── End Lease Early ──

local function endLeaseEarly(garageId)
  local rental = rentalData.activeRentals[garageId]
  if not rental then return { error = "no_rental" } end

  -- Penalty: forfeit deposit + 1 month rent
  local penalty = rental.monthlyRent
  if canAfford(penalty) then
    applyMoneyDelta(-penalty)
  end

  relocateVehicles(garageId)

  table.insert(rentalData.rentalHistory, {
    garageId = garageId,
    type = rental.type,
    leaseStart = rental.leaseStart,
    leaseEnd = accumulatedSimTime,
    paymentsMade = rental.paymentsMade,
    missedPayments = rental.missedPayments,
    evicted = false,
    earlyTermination = true,
  })

  rentalData.activeRentals[garageId] = nil
  career_saveSystem.saveCurrent()
  notify("warning", "Lease Terminated", "Early termination for " .. garageId .. ". Deposit forfeited + penalty applied.")
  return { success = true }
end

-- ── Public API ──

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
  local count = 0
  for _ in pairs(rentalData.activeRentals) do count = count + 1 end
  local depositMult = math.max(1.0, tier.depositMult + getCreditDepositAdjustment())
  return {
    canRent = true,
    maxProperties = tier.maxProperties,
    currentRentals = count,
    availableTypes = tier.types,
    depositMultiplier = depositMult,
    tierLabel = tier.label,
    tierId = tier.id,
    creditEnhanced = career_modules_credit ~= nil,
  }
end

local function getAllRentals()
  local result = {}
  for garageId, rental in pairs(rentalData.activeRentals) do
    local entry = deepcopy(rental)
    local facility = freeroam_facilities and freeroam_facilities.getFacility("garage", garageId)
    entry.garageName = facility and facility.name or ("Garage " .. tostring(garageId))
    entry.garageId = garageId
    if rental.type == "upfront" then
      local totalDuration = rental.leaseTerm * PAYMENT_INTERVAL_S
      local elapsed = accumulatedSimTime - (rental.leaseStart or 0)
      entry.leaseTimeRemaining = math.max(0, totalDuration - elapsed)
    else
      local nextPay = rental.secondsUntilNextPayment or 0
      local remaining = math.max(0, (rental.paymentsRemaining or 1) - 1)
      entry.leaseTimeRemaining = nextPay + remaining * PAYMENT_INTERVAL_S
    end
    result[garageId] = entry
  end
  return result
end

local function getRentalBreakdown(garageId)
  local baseValue = getBaseValue(garageId)
  local tier = getRentalTier()
  local depositMult = math.max(1.0, tier.depositMult + getCreditDepositAdjustment())
  local fixedRent = math.floor(baseValue * 0.015 + 0.5)
  local dynamicRent = math.floor(baseValue * 0.012 + 0.5)
  local deposit = math.floor(fixedRent * 2 * depositMult + 0.5)

  local facility = freeroam_facilities and freeroam_facilities.getFacility("garage", garageId)

  return {
    garageId = garageId,
    garageName = facility and facility.name or garageId,
    baseValue = baseValue,
    fixedRent = fixedRent,
    dynamicRent = dynamicRent,
    upfrontTotal12 = math.floor(fixedRent * 12 * 0.87 + 0.5),
    upfrontTotal6 = math.floor(fixedRent * 6 * 0.87 + 0.5),
    deposit = deposit,
    depositMultiplier = depositMult,
    tier = tier.label,
    tierId = tier.id,
    availableTypes = tier.types,
    canRent = canRentMore(),
    creditEnhanced = career_modules_credit ~= nil,
    isOwned = career_modules_garageManager.isPurchasedGarage(garageId),
    isRented = rentalData.activeRentals[garageId] ~= nil,
    cooldownActive = rentalData.evictionCooldowns[garageId] and accumulatedSimTime < rentalData.evictionCooldowns[garageId] or false,
  }
end

-- ── Save / Load ──

local function ensureSaveDir(currentSavePath)
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function loadRentals()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  local data = jsonReadFile(currentSavePath .. saveFile)
  if data then
    rentalData.activeRentals = data.activeRentals or {}
    rentalData.rentalHistory = data.rentalHistory or {}
    rentalData.evictionCooldowns = data.evictionCooldowns or {}
    accumulatedSimTime = data.simTime or 0
  end
end

local function saveRentals(currentSavePath)
  if not currentSavePath then
    local _, p = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = p
    if not currentSavePath then return end
  end
  ensureSaveDir(currentSavePath)
  local data = deepcopy(rentalData)
  data.simTime = accumulatedSimTime
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, data, true)
end

-- ── Hooks ──

local function onUpdate(dtReal, dtSim, dtRaw)
  if not career_career or not career_career.isActive() then return end
  accumulatedSimTime = accumulatedSimTime + dtSim
  updateTimer = updateTimer + dtSim

  if updateTimer >= 5 then
    updateTimer = 0
    local garageIds = {}
    for garageId, _ in pairs(rentalData.activeRentals) do
      table.insert(garageIds, garageId)
    end
    for _, garageId in ipairs(garageIds) do
      local rental = rentalData.activeRentals[garageId]
      if rental and rental.type == "upfront" then
        local totalDuration = rental.leaseTerm * PAYMENT_INTERVAL_S
        local elapsed = accumulatedSimTime - (rental.leaseStart or 0)
        if elapsed >= totalDuration then
          relocateVehicles(garageId)
          table.insert(rentalData.rentalHistory, {
            garageId = garageId,
            type = rental.type,
            leaseStart = rental.leaseStart,
            leaseEnd = accumulatedSimTime,
            paymentsMade = rental.paymentsMade,
            missedPayments = 0,
            evicted = false,
          })
          applyMoneyDelta(rental.securityDeposit)
          notify("success", "Lease Complete", "Prepaid lease for " .. garageId .. " has expired. Deposit returned.")
          rentalData.activeRentals[garageId] = nil
          career_saveSystem.saveCurrent()
        end
      elseif rental and rental.paymentsRemaining > 0 then
        rental.secondsUntilNextPayment = (rental.secondsUntilNextPayment or PAYMENT_INTERVAL_S) - 5
        if rental.secondsUntilNextPayment <= 0 then
          rental.secondsUntilNextPayment = PAYMENT_INTERVAL_S
          processRentPayment(garageId, rental)
        end
      elseif rental and rental.type ~= "upfront" and rental.paymentsRemaining <= 0 then
        -- Lease term complete for fixed/dynamic rentals
        relocateVehicles(garageId)
        table.insert(rentalData.rentalHistory, {
          garageId = garageId,
          type = rental.type,
          leaseStart = rental.leaseStart,
          leaseEnd = accumulatedSimTime,
          paymentsMade = rental.paymentsMade,
          missedPayments = rental.missedPayments,
          evicted = false,
        })
        applyMoneyDelta(rental.securityDeposit)
        notify("success", "Lease Complete", "Lease for " .. garageId .. " complete. Deposit returned.")
        rentalData.activeRentals[garageId] = nil
        career_saveSystem.saveCurrent()
      end
    end
  end
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveRentals(currentSavePath)
end

local function onExtensionLoaded()
  loadRentals()
end

local function onCareerActivated()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  if FS:fileExists(currentSavePath .. saveFile) then
    loadRentals()
  else
    rentalData = { activeRentals = {}, rentalHistory = {}, evictionCooldowns = {} }
    accumulatedSimTime = 0
  end
end

-- ── Exports ──

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
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated

return M
