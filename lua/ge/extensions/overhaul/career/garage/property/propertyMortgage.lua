-- Property mortgages: loan terms, payment schedules, prepayments and foreclosure.
-- Read credit/payment helpers, foreclosure and payments, update, save/load, then lifecycle, API and hooks.
local M = {}

local ensureDir = require("overhaul/lib/save/ensureDir")

-- Config ------------------------------------------------------------------------------------------

local SAVE_DIR = "/career/rls_career"
local SAVE_FILE = SAVE_DIR .. "/mortgages.json"

local PAYMENT_INTERVAL_S = 10 * 60
local BASE_INTEREST_RATE = 0.05
local FORECLOSURE_VEHICLE_MULTIPLIER = 0.75
local MIN_CREDIT_SCORE = 450
local MISSED_PAYMENTS_BEFORE_FORECLOSURE = 3
local MISSED_PAYMENT_RATE_MULTIPLIER = 1.15
local FORECLOSURE_CREDIT_STRIKES = 3
local DEFAULT_TERM = 12

local DOWN_PAYMENT_BY_TIER = {
  Excellent = 0.10,
  Good = 0.15,
  Fair = 0.25,
  Poor = 0.40,
}

-- State -------------------------------------------------------------------------------------------

local mortgages = {}
local accumulatedSimTime = 0

-- Money and credit helpers ------------------------------------------------------------------------

local propertyMoney = require("overhaul/career/garage/property/money").new({
  category = "property",
  label = "Mortgage",
  payDescription = "Mortgage payment",
  rewardDescription = "Mortgage payout",
  source = "Real Estate",
  deps = function()
    return overhaul_career_economy_payment, overhaul_career_economy_playerAttributes, overhaul_world_facilities,
      overhaul_phone_apps_layout
  end,
})

local function recordCreditEvent(eventName)
  if overhaul_career_economy_credit[eventName] then
    overhaul_career_economy_credit[eventName]()
  end
end

local function notifyPaidOff(garageId, message)
  propertyMoney.notify("success", "Mortgage Paid Off", message, "realEstate.mortgagePaidOff", garageId)
end

-- Payment math ------------------------------------------------------------------------------------

-- Payments use game-days, so re-amortization retains the original daily rate.
local function calculatePayment(principal, annualRate, term, periodRate)
  if term <= 0 then return principal end
  if annualRate <= 0 then
    return math.floor((principal / term) + 0.5)
  end

  periodRate = periodRate or (annualRate / term)
  local powVal = math.pow(1 + periodRate, term)
  local payment = principal * ((periodRate * powVal) / (powVal - 1))
  return math.floor(payment + 0.5)
end

local function getRemainingBalance(mortgage)
  if not mortgage then return 0 end
  return math.max(0, mortgage.remainingBalance or mortgage.principal or 0)
end

local function clearMortgage(garageId)
  mortgages[tostring(garageId)] = nil
end

local function getPeriodRate(mortgage)
  return (mortgage.interestRate or 0) / (mortgage.term or mortgage.remainingPayments or 1)
end

local function recalcPaymentForMortgage(mortgage)
  local remainingBalance = getRemainingBalance(mortgage)
  mortgage.monthlyPayment = calculatePayment(remainingBalance, (mortgage.interestRate or 0), mortgage.remainingPayments or 1, getPeriodRate(mortgage))
end

local function resolveTerm(termsAvailable, selectedTerm)
  local longestTerm = termsAvailable[#termsAvailable] or DEFAULT_TERM
  local term = tonumber(selectedTerm) or longestTerm
  for _, allowedTerm in ipairs(termsAvailable) do
    if allowedTerm == term then return term end
  end
  return longestTerm
end

-- Foreclosure -------------------------------------------------------------------------------------

local function liquidateGarageVehicles(garageId)
  local totalPayout = 0
  local ids, snapshots = {}, {}
  local vehicleIds = overhaul_career_garage_garageManager.getVehiclesInGarage(garageId) or {}
  for _, inventoryId in ipairs(vehicleIds) do
    local value = overhaul_career_market_valueCalculator.getInventoryVehicleValue(inventoryId) or 0
    value = math.floor((value * FORECLOSURE_VEHICLE_MULTIPLIER) + 0.5)
    if value > 0 then
      totalPayout = totalPayout + value
      ids[inventoryId] = true
      snapshots[inventoryId] = require("overhaul/lib/finance/metadata").capture(
        {category = "sale", finance = {vehicleId = inventoryId}}, os.time(), value)
    end

    overhaul_career_garage_inventory.removeVehicle(inventoryId)
  end

  if totalPayout > 0 then
    propertyMoney.applyMoneyDelta(totalPayout, garageId, {category = "sale", finance =
      require("overhaul/lib/finance/vehicleContext").single(ids, snapshots, false, 0)})
  end
  return totalPayout
end

local function forecloseMortgage(garageId)
  local mortgage = mortgages[tostring(garageId)]
  if not mortgage then return false end

  local payout = liquidateGarageVehicles(garageId)

  for _ = 1, FORECLOSURE_CREDIT_STRIKES do
    recordCreditEvent("recordMissedPayment")
  end

  overhaul_career_garage_garageManager.removePurchasedGarage(garageId)

  clearMortgage(garageId)
  overhaul_career_saveSystem.saveCurrent()

  local message = propertyMoney.getGarageLabel(garageId) .. " repossessed due to missed payments."
  if payout > 0 then
    message = message .. " Vehicles liquidated for $" .. tostring(payout) .. "."
  end
  propertyMoney.notify("error", "Foreclosure", message, "realEstate.mortgageForeclosure", garageId)
  return true
end

-- Scheduled payments ------------------------------------------------------------------------------

local function processMissedPayment(garageId, mortgage)
  mortgage.missedPayments = (mortgage.missedPayments or 0) + 1

  if mortgage.missedPayments >= MISSED_PAYMENTS_BEFORE_FORECLOSURE then
    return forecloseMortgage(garageId)
  end

  mortgage.interestRate = (mortgage.interestRate or 0) * MISSED_PAYMENT_RATE_MULTIPLIER
  recalcPaymentForMortgage(mortgage)
  recordCreditEvent("recordMissedPayment")

  if mortgage.missedPayments == 1 then
    propertyMoney.notify("warning", "Mortgage Payment Missed", "Payment missed for " .. propertyMoney.getGarageLabel(garageId) .. ". Interest rate increased by 15%.", "realEstate.mortgageMissed")
  else
    propertyMoney.notify("warning", "Second Mortgage Strike", "Second missed payment for " .. propertyMoney.getGarageLabel(garageId) .. ". Interest increased again.", "realEstate.mortgageMissed")
  end
  return true
end

local function recordPaidInstallment(garageId, mortgage, payment, interestPortion)
  local principalPortion = math.max(0, payment - interestPortion)

  mortgage.remainingBalance = math.max(0, getRemainingBalance(mortgage) - principalPortion)
  mortgage.remainingPayments = math.max(0, (mortgage.remainingPayments or 0) - 1)
  mortgage.totalPaid = (mortgage.totalPaid or 0) + payment
  recordCreditEvent("recordOnTimePayment")

  if mortgage.remainingPayments <= 0 or mortgage.remainingBalance <= 0 then
    recordCreditEvent("recordLoanCompleted")
    clearMortgage(garageId)
    notifyPaidOff(garageId, "You have fully paid the mortgage on " .. propertyMoney.getGarageLabel(garageId) .. ".")
  end
end

local function processDailyPayment(garageId, mortgage)
  if not mortgage or (mortgage.remainingPayments or 0) <= 0 then return end

  local payment = mortgage.monthlyPayment or 0
  if payment <= 0 then return end

  local periodRate = getPeriodRate(mortgage)
  local interestPortion = math.floor((getRemainingBalance(mortgage) * periodRate) + 0.5)
  payment = math.min(payment, getRemainingBalance(mortgage) + interestPortion)

  if propertyMoney.canAfford(payment) and propertyMoney.applyMoneyDelta(-payment, garageId) then
    recordPaidInstallment(garageId, mortgage, payment, interestPortion)
    return
  end
  processMissedPayment(garageId, mortgage)
end

-- Per-frame update --------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim)
  accumulatedSimTime = accumulatedSimTime + (dtSim or 0)
  while accumulatedSimTime >= PAYMENT_INTERVAL_S do
    accumulatedSimTime = accumulatedSimTime - PAYMENT_INTERVAL_S

    -- Snapshot the ids because a missed payment can foreclose and remove entries.
    local garageIds = {}
    for garageId, _ in pairs(mortgages) do
      table.insert(garageIds, garageId)
    end

    for _, garageId in ipairs(garageIds) do
      local mortgage = mortgages[garageId]
      if mortgage then
        processDailyPayment(garageId, mortgage)
      end
    end
  end
end

-- Save and load -----------------------------------------------------------------------------------

local function saveMortgages(currentSavePath, writer)
  if not currentSavePath then return end
  ensureDir.directory(writer, currentSavePath .. SAVE_DIR)
  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. SAVE_FILE, {
    mortgages = mortgages,
    simTime = accumulatedSimTime
  }, true)
end

local function loadMortgages()
  if not overhaul_career_career.isActive() then return end
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end

  local data = jsonReadFile(currentSavePath .. SAVE_FILE) or {}
  mortgages = data.mortgages or {}
  accumulatedSimTime = data.simTime or 0
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveMortgages(currentSavePath, writer)
end

local function onCareerActivated()
  loadMortgages()
end

local function onExtensionLoaded()
  loadMortgages()
end

-- Public API: offers ------------------------------------------------------------------------------

function M.isMortgageAvailable()
  local scoreData = overhaul_career_economy_credit.getScore()
  if not scoreData or not scoreData.score then return false end
  return scoreData.score >= MIN_CREDIT_SCORE
end

function M.getMortgageOfferDetails()
  local tier = overhaul_career_economy_credit.getTier()
  if not tier then return nil end

  local downPaymentPercent = DOWN_PAYMENT_BY_TIER[tier.label]
  return {
    tier = tier.label,
    available = downPaymentPercent ~= nil,
    downPaymentPercent = downPaymentPercent,
    rate = BASE_INTEREST_RATE * (tier.rateMultiplier or 1),
    termsAvailable = tier.termsAvailable or {}
  }
end

function M.computeDownPayment(purchasePrice)
  if not purchasePrice or purchasePrice <= 0 then return nil end

  local tier = overhaul_career_economy_credit.getTier()
  if not tier then return nil end

  local downPaymentPercent = DOWN_PAYMENT_BY_TIER[tier.label]
  if not downPaymentPercent then return nil end

  return math.floor((purchasePrice * downPaymentPercent) + 0.5)
end

-- Public API: mortgages ---------------------------------------------------------------------------

function M.createMortgage(garageId, purchasePrice, selectedTerm, downPaymentAlreadyPaid)
  if require("overhaul/lib/business/bundles").forGarage(garageId) then return false end
  if not garageId or not purchasePrice or purchasePrice <= 0 then return nil end

  local tier = overhaul_career_economy_credit.getTier()
  if not tier then return nil end

  local downPaymentPercent = DOWN_PAYMENT_BY_TIER[tier.label]
  if not downPaymentPercent then return nil end

  local term = resolveTerm(tier.termsAvailable or {DEFAULT_TERM}, selectedTerm)

  local downPayment = math.floor((purchasePrice * downPaymentPercent) + 0.5)
  local principal = math.max(0, math.floor(purchasePrice - downPayment + 0.5))
  local interestRate = BASE_INTEREST_RATE * (tier.rateMultiplier or 1)
  local monthlyPayment = calculatePayment(principal, interestRate, term)

  if not downPaymentAlreadyPaid then
    if not propertyMoney.canAfford(downPayment) or not propertyMoney.applyMoneyDelta(-downPayment, garageId) then
      return nil
    end
  end

  local mortgage = {
    garageId = tostring(garageId),
    principal = principal,
    downPayment = downPayment,
    interestRate = interestRate,
    term = term,
    remainingPayments = term,
    missedPayments = 0,
    monthlyPayment = monthlyPayment,
    totalPaid = downPayment,
    remainingBalance = principal
  }

  mortgages[tostring(garageId)] = mortgage

  overhaul_career_economy_credit.recordLoanTaken("propertyMortgage")

  propertyMoney.notify("success", "Mortgage Created", "Financing approved for " .. propertyMoney.getGarageLabel(garageId) .. ".", "realEstate.mortgageCreated")
  return mortgage
end

function M.getMortgage(garageId)
  if not garageId then return nil end
  return mortgages[tostring(garageId)]
end

function M.getAllMortgages()
  local result = {}
  for garageId, mortgage in pairs(mortgages) do
    local entry = deepcopy(mortgage)
    local facility = overhaul_world_facilities.getFacility("garage", garageId)
    entry.garageName = facility and facility.name or ("Garage " .. tostring(garageId))
    entry.secondsUntilNextPayment = math.max(0, PAYMENT_INTERVAL_S - accumulatedSimTime)
    result[garageId] = entry
  end
  return result
end

function M.hasMortgage(garageId)
  return M.getMortgage(garageId) ~= nil
end

function M.getMortgagePaymentInfo(garageId)
  local mortgage = M.getMortgage(garageId)
  if not mortgage then return nil end

  local facility = overhaul_world_facilities.getFacility("garage", garageId)
  return {
    monthlyPayment = mortgage.monthlyPayment,
    remainingPayments = mortgage.remainingPayments,
    remainingBalance = getRemainingBalance(mortgage),
    interestRate = mortgage.interestRate,
    missedPayments = mortgage.missedPayments,
    garageName = facility and facility.name or ("Garage " .. tostring(garageId)),
    secondsUntilNextPayment = math.max(0, PAYMENT_INTERVAL_S - accumulatedSimTime)
  }
end

-- Public API: sale, payoff and prepayment ---------------------------------------------------------

function M.canSellMortgagedProperty(garageId, salePrice)
  local mortgage = M.getMortgage(garageId)
  if not mortgage then return true end
  salePrice = tonumber(salePrice) or 0
  return salePrice > getRemainingBalance(mortgage)
end

function M.processMortgageSale(garageId, salePrice)
  local mortgage = M.getMortgage(garageId)
  if not mortgage then
    return true, tonumber(salePrice) or 0
  end

  local sale = tonumber(salePrice) or 0
  local remaining = getRemainingBalance(mortgage)
  if sale <= remaining then
    return false, 0
  end

  local netProceeds = math.floor(sale - remaining + 0.5)
  clearMortgage(garageId)
  overhaul_career_economy_credit.recordLoanCompleted()
  return true, netProceeds
end

function M.payoffMortgage(garageId)
  local mortgage = M.getMortgage(garageId)
  if not mortgage then return false end

  local remaining = getRemainingBalance(mortgage)
  if remaining <= 0 then
    clearMortgage(garageId)
    return true
  end

  if not propertyMoney.canAfford(remaining) or not propertyMoney.applyMoneyDelta(-remaining, garageId) then
    return false
  end

  clearMortgage(garageId)
  overhaul_career_economy_credit.recordLoanCompleted()
  notifyPaidOff(garageId, "You paid off the remaining mortgage on " .. propertyMoney.getGarageLabel(garageId) .. ".")
  return true
end

-- A smaller balance shortens the schedule; if the recalculated payment still rose, one more period is added.
local function reschedulePrepaidMortgage(mortgage)
  local oldPayment = tonumber(mortgage.monthlyPayment) or 0
  if oldPayment <= 0 then return end
  mortgage.remainingPayments = math.max(1, math.ceil(mortgage.remainingBalance / oldPayment))
  recalcPaymentForMortgage(mortgage)
  if mortgage.monthlyPayment > oldPayment then
    mortgage.remainingPayments = mortgage.remainingPayments + 1
    recalcPaymentForMortgage(mortgage)
  end
end

function M.prepayMortgage(garageId, amount)
  garageId = tostring(garageId or "")
  local mortgage = M.getMortgage(garageId)
  if not mortgage then return { error = "loan_not_found" } end

  amount = tonumber(amount) or 0
  if amount <= 0 then return { error = "invalid_amount" } end

  local remaining = getRemainingBalance(mortgage)
  if remaining <= 0 then
    clearMortgage(garageId)
    return { id = garageId, status = "paid_off" }
  end

  amount = math.min(amount, remaining)
  if not propertyMoney.canAfford(amount) or not propertyMoney.applyMoneyDelta(-amount, garageId) then return { error = "insufficient_funds" } end

  mortgage.remainingBalance = math.max(0, remaining - amount)

  if mortgage.remainingBalance <= 0 then
    clearMortgage(garageId)
    overhaul_career_economy_credit.recordLoanCompleted()
    notifyPaidOff(garageId, "You paid off the remaining mortgage on " .. propertyMoney.getGarageLabel(garageId) .. ".")
    return { id = garageId, status = "paid_off" }
  end

  reschedulePrepaidMortgage(mortgage)
  propertyMoney.notify("success", "Mortgage Prepayment", "Applied $" .. tostring(amount) .. " to your mortgage.", "realEstate.mortgagePrepayment")
  return { id = garageId, status = "prepaid" }
end

-- Game hooks --------------------------------------------------------------------------------------

M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onCareerActivated = onCareerActivated
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate

return M
