local M = {}

M.dependencies = {
  'career_career',
  'career_saveSystem',
  'career_modules_playerAttributes',
  'career_modules_garageManager'
}

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/mortgages.json"

local SIM_SECONDS_PER_GAME_DAY = 300
local BASE_INTEREST_RATE = 0.05
local FORECLOSURE_VEHICLE_MULTIPLIER = 0.75
local accumulatedSimTime = 0

local DOWN_PAYMENT_BY_TIER = {
  Excellent = 0.10,
  Good = 0.15,
  Fair = 0.25,
  Poor = 0.40,
}

local mortgages = {}

local function ensureSaveDir(currentSavePath)
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function saveMortgages(currentSavePath)
  if not currentSavePath then
    local _, p = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = p
    if not currentSavePath then return end
  end

  ensureSaveDir(currentSavePath)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, {
    mortgages = mortgages,
    simTime = accumulatedSimTime
  }, true)
end

local function loadMortgages()
  if not career_career.isActive() then return end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end

  local data = jsonReadFile(currentSavePath .. saveFile) or {}
  mortgages = data.mortgages or {}
  accumulatedSimTime = data.simTime or 0
end

local function notify(type, title, msg)
  if guihooks and guihooks.trigger then
    guihooks.trigger('toastrMsg', { type = type, title = title, msg = msg })
  end
end

local function calculatePayment(principal, annualRate, term)
  if term <= 0 then return principal end
  if annualRate <= 0 then
    return math.floor((principal / term) + 0.5)
  end

  -- term is in game-days; rate is annual but payments are daily
  -- Use per-period rate = annualRate / term (spread over loan life)
  local periodRate = annualRate / term
  local powVal = math.pow(1 + periodRate, term)
  local payment = principal * ((periodRate * powVal) / (powVal - 1))
  return math.floor(payment + 0.5)
end

local function getRemainingBalance(mortgage)
  if not mortgage then return 0 end
  return math.max(0, mortgage.remainingBalance or mortgage.principal or 0)
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
      return career_modules_payment.pay({money = {amount = math.abs(amount), canBeNegative = false}}, {label = "Mortgage", description = "Mortgage payment"})
    end
  elseif amount > 0 then
    if career_modules_payment and career_modules_payment.reward then
      return career_modules_payment.reward({money = {amount = amount, canBeNegative = false}}, {label = "Mortgage", description = "Mortgage payout"})
    end
  end
  if career_modules_playerAttributes and career_modules_playerAttributes.addAttributes then
    career_modules_playerAttributes.addAttributes({money = amount}, {label = "Mortgage"})
    return true
  end
  return false
end

local function clearMortgage(garageId)
  mortgages[tostring(garageId)] = nil
end

local function recalcPaymentForMortgage(mortgage)
  local remainingBalance = getRemainingBalance(mortgage)
  mortgage.monthlyPayment = calculatePayment(remainingBalance, (mortgage.interestRate or 0), mortgage.remainingPayments or 1)
end

local function liquidateGarageVehicles(garageId)
  local totalPayout = 0
  if not career_modules_garageManager or not career_modules_garageManager.getVehiclesInGarage then
    return totalPayout
  end

  local vehicleIds = career_modules_garageManager.getVehiclesInGarage(garageId) or {}
  for _, inventoryId in ipairs(vehicleIds) do
    local value = 0
    if career_modules_valueCalculator and career_modules_valueCalculator.getInventoryVehicleValue then
      value = career_modules_valueCalculator.getInventoryVehicleValue(inventoryId) or 0
    end
    value = math.floor((value * FORECLOSURE_VEHICLE_MULTIPLIER) + 0.5)
    if value > 0 then
      totalPayout = totalPayout + value
    end

    if career_modules_inventory and career_modules_inventory.removeVehicleObject then
      career_modules_inventory.removeVehicleObject(inventoryId)
    end
  end

  if totalPayout > 0 then
    applyMoneyDelta(totalPayout)
  end

  return totalPayout
end

local function forecloseMortgage(garageId)
  local mortgage = mortgages[tostring(garageId)]
  if not mortgage then return false end

  local payout = liquidateGarageVehicles(garageId)

  if career_modules_credit and career_modules_credit.recordMissedPayment then
    career_modules_credit.recordMissedPayment()
    career_modules_credit.recordMissedPayment()
    career_modules_credit.recordMissedPayment()
  end

  if career_modules_garageManager and career_modules_garageManager.removePurchasedGarage then
    career_modules_garageManager.removePurchasedGarage(garageId)
  end

  clearMortgage(garageId)
  saveMortgages()

  local msg = "Property repossessed due to missed payments."
  if payout > 0 then
    msg = msg .. " Vehicles liquidated for $" .. tostring(payout) .. "."
  end
  notify("error", "Foreclosure", msg)

  return true
end

local function processMissedPayment(garageId, mortgage)
  mortgage.missedPayments = (mortgage.missedPayments or 0) + 1

  if mortgage.missedPayments >= 3 then
    return forecloseMortgage(garageId)
  end

  mortgage.interestRate = (mortgage.interestRate or 0) * 1.15
  recalcPaymentForMortgage(mortgage)

  if career_modules_credit and career_modules_credit.recordMissedPayment then
    career_modules_credit.recordMissedPayment()
  end

  if mortgage.missedPayments == 1 then
    notify("warning", "Mortgage Payment Missed", "Payment missed. Interest rate increased by 15%.")
  else
    notify("warning", "Second Mortgage Strike", "Second missed payment. Interest increased again.")
  end

  saveMortgages()
  return true
end

local function processDailyPayment(garageId, mortgage)
  if not mortgage or (mortgage.remainingPayments or 0) <= 0 then
    return
  end

  local payment = mortgage.monthlyPayment or 0
  if payment <= 0 then
    return
  end

  if canAfford(payment) then
    applyMoneyDelta(-payment)

    local periodRate = (mortgage.interestRate or 0) / (mortgage.term or 1)
    local interestPortion = math.floor((getRemainingBalance(mortgage) * periodRate) + 0.5)
    local principalPortion = math.max(0, payment - interestPortion)

    mortgage.remainingBalance = math.max(0, getRemainingBalance(mortgage) - principalPortion)
    mortgage.remainingPayments = math.max(0, (mortgage.remainingPayments or 0) - 1)
    mortgage.totalPaid = (mortgage.totalPaid or 0) + payment

    if career_modules_credit and career_modules_credit.recordOnTimePayment then
      career_modules_credit.recordOnTimePayment()
    end

    if mortgage.remainingPayments <= 0 or mortgage.remainingBalance <= 0 then
      if career_modules_credit and career_modules_credit.recordLoanCompleted then
        career_modules_credit.recordLoanCompleted()
      end
      clearMortgage(garageId)
      notify("success", "Mortgage Paid Off", "You have fully paid this mortgage.")
    end

    saveMortgages()
    return
  end

  processMissedPayment(garageId, mortgage)
end

function M.isMortgageAvailable()
  if not career_modules_credit then return false end
  local scoreData = career_modules_credit.getScore and career_modules_credit.getScore() or nil
  if not scoreData or not scoreData.score then return false end
  return scoreData.score >= 450
end

function M.getMortgageOfferDetails()
  if not career_modules_credit or not career_modules_credit.getTier then return nil end
  local tier = career_modules_credit.getTier()
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

function M.createMortgage(garageId, purchasePrice, selectedTerm)
  if not career_modules_credit then return nil end
  if not garageId or not purchasePrice or purchasePrice <= 0 then return nil end

  local tier = career_modules_credit.getTier and career_modules_credit.getTier() or nil
  if not tier then return nil end

  local downPaymentPercent = DOWN_PAYMENT_BY_TIER[tier.label]
  if not downPaymentPercent then
    return nil
  end

  local termsAvailable = tier.termsAvailable or {12}
  local term = tonumber(selectedTerm) or termsAvailable[#termsAvailable] or 12
  local termAllowed = false
  for _, t in ipairs(termsAvailable) do
    if t == term then
      termAllowed = true
      break
    end
  end
  if not termAllowed then
    term = termsAvailable[#termsAvailable] or 12
  end

  local downPayment = math.floor((purchasePrice * downPaymentPercent) + 0.5)
  local principal = math.max(0, math.floor(purchasePrice - downPayment + 0.5))
  local interestRate = BASE_INTEREST_RATE * (tier.rateMultiplier or 1)
  local monthlyPayment = calculatePayment(principal, interestRate, term)

  if not canAfford(downPayment) then
    return nil
  end

  applyMoneyDelta(-downPayment)

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

  if career_modules_credit and career_modules_credit.recordLoanTaken then
    career_modules_credit.recordLoanTaken("propertyMortgage")
  end

  saveMortgages()
  notify("success", "Mortgage Created", "Financing approved for property purchase.")

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
    local facility = freeroam_facilities.getFacility("garage", garageId)
    entry.garageName = facility and facility.name or ("Garage " .. tostring(garageId))
    entry.secondsUntilNextPayment = math.max(0, SIM_SECONDS_PER_GAME_DAY - accumulatedSimTime)
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

  local facility = freeroam_facilities.getFacility("garage", garageId)
  return {
    monthlyPayment = mortgage.monthlyPayment,
    remainingPayments = mortgage.remainingPayments,
    remainingBalance = getRemainingBalance(mortgage),
    interestRate = mortgage.interestRate,
    missedPayments = mortgage.missedPayments,
    garageName = facility and facility.name or ("Garage " .. tostring(garageId)),
    secondsUntilNextPayment = math.max(0, SIM_SECONDS_PER_GAME_DAY - accumulatedSimTime)
  }
end

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

  if career_modules_credit and career_modules_credit.recordLoanCompleted then
    career_modules_credit.recordLoanCompleted()
  end

  saveMortgages()
  return true, netProceeds
end

function M.payoffMortgage(garageId)
  local mortgage = M.getMortgage(garageId)
  if not mortgage then return false end

  local remaining = getRemainingBalance(mortgage)
  if remaining <= 0 then
    clearMortgage(garageId)
    saveMortgages()
    return true
  end

  if not canAfford(remaining) then
    return false
  end

  applyMoneyDelta(-remaining)
  clearMortgage(garageId)

  if career_modules_credit and career_modules_credit.recordLoanCompleted then
    career_modules_credit.recordLoanCompleted()
  end

  saveMortgages()
  notify("success", "Mortgage Paid Off", "You paid off the remaining mortgage balance.")
  return true
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
    saveMortgages()
    return { id = garageId, status = "paid_off" }
  end

  amount = math.min(amount, remaining)
  if not canAfford(amount) then return { error = "insufficient_funds" } end

  applyMoneyDelta(-amount)
  mortgage.remainingBalance = math.max(0, remaining - amount)

  if mortgage.remainingBalance <= 0 then
    clearMortgage(garageId)
    if career_modules_credit and career_modules_credit.recordLoanCompleted then
      career_modules_credit.recordLoanCompleted()
    end
    saveMortgages()
    notify("success", "Mortgage Paid Off", "You paid off the remaining mortgage balance.")
    return { id = garageId, status = "paid_off" }
  end

  mortgage.remainingPayments = math.ceil(mortgage.remainingBalance / mortgage.monthlyPayment)
  if career_modules_credit and career_modules_credit.recordOnTimePayment then
    career_modules_credit.recordOnTimePayment()
  end
  saveMortgages()
  notify("success", "Mortgage Prepayment", "Applied $" .. tostring(amount) .. " to your mortgage.")
  return { id = garageId, status = "prepaid" }
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveMortgages(currentSavePath)
end

local function onCareerActivated()
  loadMortgages()
  if not next(mortgages) then
    saveMortgages()
  end
end

local function onExtensionLoaded()
  loadMortgages()
end

local function onUpdate(dtReal, dtSim)
  if not career_modules_credit then return end

  accumulatedSimTime = accumulatedSimTime + (dtSim or 0)
  while accumulatedSimTime >= SIM_SECONDS_PER_GAME_DAY do
    accumulatedSimTime = accumulatedSimTime - SIM_SECONDS_PER_GAME_DAY

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

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onCareerActivated = onCareerActivated
M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate

return M
