local M = {}

-- =============================================================================
-- Constants & State
-- =============================================================================

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/loans.json"

local PAYMENT_INTERVAL_S = 5 * 60
local TERM_OPTIONS = {12, 24, 36, 48}

local updateInterval = 5
local updateTimer = 0

local activeLoans = {}
local notificationsEnabled = true

local r2 = function(n) return (n and math.floor(n * 100 + 0.5) / 100) or 0 end

-- =============================================================================
-- Storage
-- =============================================================================

local function normalizeBusinessAccountId(id)
  if not id or id == "" or id == "null" then return nil end
  return id
end

local function loadLoans()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  local data = jsonReadFile(currentSavePath .. saveFile) or {}
  activeLoans = data.activeLoans or {}
  for _, loan in ipairs(activeLoans) do
    loan.businessAccountId = normalizeBusinessAccountId(loan.businessAccountId)
  end
  notificationsEnabled = data.notificationsEnabled
  if notificationsEnabled == nil then notificationsEnabled = true end
end

--- Persists active loans and notification settings. currentSavePath optional; uses current slot if omitted.
local function saveLoans(currentSavePath)
  if not currentSavePath then
    local _, p = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = p
    if not currentSavePath then return end
  end
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then FS:directoryCreate(dirPath) end
  local data = {
    activeLoans = activeLoans,
    notificationsEnabled = notificationsEnabled
  }
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, data, true)
end

-- =============================================================================
-- Loan Calculations
-- =============================================================================

local function nextPaymentDueFor(loan)
  local base = loan.basePayment or 0
  local interest = r2(base * (loan.rate or 0))
  local ip = r2(math.max(0, interest - (loan.nextInterestPaid or 0)))
  local pp = r2(math.max(0, base - (loan.nextPrincipalPaid or 0)))
  return r2(ip + pp)
end

local function getInterestDue(loan)
  local base = loan.basePayment or 0
  local interest = r2(base * (loan.rate or 0))
  return r2(math.max(0, interest - (loan.nextInterestPaid or 0)))
end

local function buildUiLoan(loan)
  local per = r2((loan.basePayment or 0) * (1 + (loan.rate or 0)))
  local remaining = (loan.basePayment or 0) <= 0 and 0 or math.max(0, math.ceil((loan.principalOutstanding or 0) / (loan.basePayment or 1)))
  local totalPayments = math.ceil((loan.principalOriginal or 0) / (loan.basePayment or 1))
  local interestRemaining = r2(math.max(0, (per - (loan.basePayment or 0)) * remaining))
  return {
    id = loan.id,
    orgId = loan.orgId,
    orgName = loan.orgName,
    principal = r2(loan.principalOriginal or 0),
    principalOutstanding = r2(loan.principalOutstanding or 0),
    basePayment = r2(loan.basePayment or 0),
    perPayment = per,
    nextPaymentDue = nextPaymentDueFor(loan),
    nextPaymentInterest = r2(math.max(0, (loan.basePayment or 0) * (loan.rate or 0) - (loan.nextInterestPaid or 0))),
    prepaidCredit = r2((loan.nextInterestPaid or 0) + (loan.nextPrincipalPaid or 0)),
    rate = loan.rate or 0,
    currentRate = loan.rate or 0,
    paymentsSent = loan.paymentsSent or 0,
    paymentsRemaining = remaining,
    paymentsTotal = totalPayments,
    secondsUntilNextPayment = loan.secondsUntilNextPayment or PAYMENT_INTERVAL_S,
    createdAt = loan.createdAt,
    interestRemaining = interestRemaining,
    businessAccountId = loan.businessAccountId,
  }
end

--- Returns per-payment amount and total for a loan. rate is decimal (e.g. 0.1 = 10%).
--- @return number perPayment, number total
local function calculatePayment(amount, rate, payments)
  if not amount or not rate or not payments or payments <= 0 then return 0, 0 end
  local base = amount / payments
  local perPayment = r2(base * (1 + rate))
  local total = r2(perPayment * payments)
  return perPayment, total
end

-- =============================================================================
-- Loan Offers
-- =============================================================================

local function getCreditModifiers()
  local creditMod = career_modules_credit
  local creditInfo = creditMod and creditMod.getScore() or nil
  local creditTier = creditInfo and creditInfo.tier or nil
  local rateMultiplier = creditTier and creditTier.rateMultiplier or 1.0
  local maxMultiplier = creditTier and creditTier.maxMultiplier or 1.0
  local availableTerms = creditTier and creditTier.termsAvailable or TERM_OPTIONS
  return creditInfo, creditTier, rateMultiplier, maxMultiplier, availableTerms
end

local function getMinLoanLevelForOrg(org)
  for levelIdx, levelData in ipairs(org.reputationLevels) do
    if levelData.loans then
      return levelIdx - 2
    end
  end
  return nil
end

--- Returns map of orgId -> total outstanding principal across all loans with that org.
local function getOutstandingPrincipalByOrg()
  local totals = {}
  for _, loan in ipairs(activeLoans) do
    if loan.orgId then
      totals[loan.orgId] = (totals[loan.orgId] or 0) + (loan.principalOutstanding or 0)
    end
  end
  return totals
end

--- Returns orgs that have loan config at the player's current reputation level.
local function getLoanOrganizations()
  local orgs = {}
  for orgId, org in pairs(freeroam_organizations.getOrganizations()) do
    local level = org.reputationLevels[org.reputation.level + 2]
    if level and level.loans then
      orgs[orgId] = level.loans
    end
  end
  return orgs
end

local function buildOfferForOrg(orgId, org, level, outstandingByOrg, creditInfo, creditTier, rateMultiplier, maxMultiplier, availableTerms)
  local l = level.loans
  local available = math.max(0, (l.max or 0) - (outstandingByOrg[orgId] or 0))
  local adjustedMax = math.floor(available * maxMultiplier)
  local adjustedRateVal = (l.rate or 0) * rateMultiplier
  return {
    id = orgId,
    name = org.name or orgId,
    max = adjustedMax,
    rate = adjustedRateVal,
    terms = availableTerms,
    creditScore = creditInfo and creditInfo.score or nil,
    creditTier = creditTier and creditTier.label or nil,
    baseRate = l.rate,
    adjustedRate = adjustedRateVal,
    baseMax = available,
    adjustedMax = adjustedMax,
  }
end

--- Returns available loan offers from all orgs the player qualifies for, adjusted by credit tier.
local function getLoanOffers()
  local offers = {}
  local outstandingByOrg = getOutstandingPrincipalByOrg()
  local creditInfo, creditTier, rateMultiplier, maxMultiplier, availableTerms = getCreditModifiers()

  for orgId, org in pairs(freeroam_organizations.getOrganizations()) do
    local level = org.reputationLevels[org.reputation.level + 2]
    if level and level.loans then
      local minLoanLevel = getMinLoanLevelForOrg(org)
      if minLoanLevel and org.reputation.level >= minLoanLevel then
        table.insert(offers, buildOfferForOrg(orgId, org, level, outstandingByOrg, creditInfo, creditTier, rateMultiplier, maxMultiplier, availableTerms))
      end
    end
  end
  table.sort(offers, function(a, b) return a.name < b.name end)
  return offers
end

-- =============================================================================
-- Reputation
-- =============================================================================

local function awardOrgReputation(orgId, delta, orgName)
  if not orgId or not delta or delta == 0 then return end
  local key = tostring(orgId) .. "Reputation"
  local label
  if delta > 0 then
    label = string.format("Loan payment (%s)", orgName or orgId)
  else
    label = string.format("Missed loan payment (%s)", orgName or orgId)
  end
  career_modules_playerAttributes.addAttributes({[key] = delta}, { label = label })
end

-- =============================================================================
-- Scheduled Payment Processing
-- =============================================================================

local function tryPayFromBank(loan, needed)
  if not loan.businessAccountId or not career_modules_bank then return false end
  local price = { money = { amount = needed } }
  local ok = career_modules_bank.payFromAccount(price, loan.businessAccountId, "Loan Payment", "Payment to " .. (loan.orgName or loan.orgId))
  return ok
end

local function tryPayFromPlayer(loan, needed)
  if not career_modules_payment then return false end
  local price = { money = { amount = needed } }
  if not career_modules_payment.canPay(price) then return false end
  local ok = career_modules_payment.pay(price, { label = "Loan Payment", description = "Payment to " .. (loan.orgName or loan.orgId) })
  return ok
end

local function applyInstallmentPrepaid(loan)
  loan.paymentsSent = (loan.paymentsSent or 0) + 1
  loan.nextInterestPaid = 0
  loan.nextPrincipalPaid = 0
  loan.secondsUntilNextPayment = loan.secondsUntilNextPayment + PAYMENT_INTERVAL_S
  awardOrgReputation(loan.orgId, 1, loan.orgName)
  if career_modules_credit then career_modules_credit.recordOnTimePayment() end
end

local function applyPaymentSuccess(loan, needed, principalDue)
  loan.principalOutstanding = r2(math.max(0, (loan.principalOutstanding or 0) - principalDue))
  loan.paymentsSent = (loan.paymentsSent or 0) + 1
  loan.amountPaid = r2((loan.amountPaid or 0) + needed)
  loan.nextInterestPaid = 0
  loan.nextPrincipalPaid = 0
  loan.secondsUntilNextPayment = loan.secondsUntilNextPayment + PAYMENT_INTERVAL_S
  awardOrgReputation(loan.orgId, 1, loan.orgName)
  if career_modules_credit then career_modules_credit.recordOnTimePayment() end
  if notificationsEnabled then
    guihooks.trigger("toastrMsg", {type="success", title="Loan Payment Made", msg="Successfully paid $" .. string.format("%.2f", needed) .. " to " .. (loan.orgName or loan.orgId)})
  end
end

local function applyPaymentMissed(loan, needed, interestDue)
  if career_modules_credit then career_modules_credit.recordMissedPayment() end
  loan.principalOutstanding = r2((loan.principalOutstanding or 0) + interestDue)
  local rateIncrease = (loan.rate or 0.25) * 0.1
  loan.rate = (loan.rate or 0) + rateIncrease
  loan.missed = (loan.missed or 0) + 1
  loan.secondsUntilNextPayment = loan.secondsUntilNextPayment + PAYMENT_INTERVAL_S
  awardOrgReputation(loan.orgId, -5, loan.orgName)
  if notificationsEnabled then
    local capitalizedMsg = ""
    if interestDue > 0 then
      capitalizedMsg = " $" .. string.format("%.2f", interestDue) .. " interest added to principal."
    end
    guihooks.trigger("toastrMsg", {type="error", title="Loan Payment Missed", msg="Failed to pay $" .. string.format("%.2f", needed) .. " to " .. (loan.orgName or loan.orgId) .. "." .. capitalizedMsg .. " Interest rate increased by " .. string.format("%.1f", rateIncrease * 100) .. "%."})
  end
end

local function removeCompletedLoan(loan, index)
  loan.completedAt = os.time()
  local completedId = loan.id
  local completedOrg = loan.orgName or loan.orgId
  table.remove(activeLoans, index)
  if career_modules_credit then career_modules_credit.recordLoanCompleted() end
  guihooks.trigger('loans:completed', { id = completedId, orgName = completedOrg })
  if notificationsEnabled then
    guihooks.trigger("toastrMsg", {type="success", title="Loan Paid Off", msg="Congratulations! Your loan with " .. completedOrg .. " has been fully paid off."})
  end
end

local function processSingleLoanPayment(loan, i)
  local interestDue = getInterestDue(loan)
  local principalDue = r2(math.max(0, (loan.basePayment or 0) - (loan.nextPrincipalPaid or 0)))
  local needed = r2(interestDue + principalDue)

  if needed <= 1e-6 then
    applyInstallmentPrepaid(loan)
    return true
  end

  local paymentSuccess = (loan.businessAccountId and career_modules_bank)
    and tryPayFromBank(loan, needed) or tryPayFromPlayer(loan, needed)
  if paymentSuccess then
    applyPaymentSuccess(loan, needed, principalDue)
    return true
  end

  applyPaymentMissed(loan, needed, interestDue)
  return true
end

--- Processes scheduled payments for all active loans. Called from onUpdate every updateInterval seconds.
--- @param elapsedSimSeconds number Simulated seconds since last run
local function processDuePayments(elapsedSimSeconds)
  local loansModified = false

  for i = #activeLoans, 1, -1 do
    local loan = activeLoans[i]
    loan.secondsUntilNextPayment = (loan.secondsUntilNextPayment or PAYMENT_INTERVAL_S) - elapsedSimSeconds

    while ((loan.basePayment or 0) <= 0 and 0 or math.max(0, math.ceil((loan.principalOutstanding or 0) / (loan.basePayment or 1)))) > 0 and loan.secondsUntilNextPayment <= 0 do
      local interestDue = getInterestDue(loan)
      local principalDue = r2(math.max(0, (loan.basePayment or 0) - (loan.nextPrincipalPaid or 0)))
      local needed = r2(interestDue + principalDue)

      if processSingleLoanPayment(loan, i) then
        loansModified = true
      end
    end

    if (loan.principalOutstanding or 0) <= 1e-6 then
      removeCompletedLoan(loan, i)
      loansModified = true
    end
  end

  if loansModified then
    career_saveSystem.saveCurrent()
  end
  local enriched = {}
  for _, loan in ipairs(activeLoans) do table.insert(enriched, buildUiLoan(loan)) end
  guihooks.trigger('loans:tick', enriched)
  guihooks.trigger('loans:funds', career_modules_playerAttributes.getAttributeValue('money'))
end

local function onUpdate(dtReal, dtSim, dtRaw)
  updateTimer = updateTimer + dtSim
  if updateTimer >= updateInterval then
    local elapsed = updateTimer
    updateTimer = 0
    processDuePayments(elapsed)
  end
end

-- =============================================================================
-- Take Loan
-- =============================================================================

--- Resolves base rate and org max for a regular (non-uncapped) loan. Returns baseRate, orgMax, err.
local function getBaseRateForRegularLoan(org, rate, payments, creditTier)
  local level = org.reputationLevels[org.reputation.level + 2]
  if not level or not level.loans then return nil, nil, {error = "no_offer"} end
  local baseRate = rate or (level.loans.rate or 0)
  local loanGlobalIndex = career_modules_globalEconomy and career_modules_globalEconomy.getGlobalIndex() or 1.0
  baseRate = baseRate * loanGlobalIndex
  if creditTier then
    baseRate = baseRate * (creditTier.rateMultiplier or 1.0)
    if creditTier.termsAvailable then
      local termAllowed = false
      for _, t in ipairs(creditTier.termsAvailable) do
        if t == payments then termAllowed = true; break end
      end
      if not termAllowed then return nil, nil, {error = "term_not_available"} end
    end
  end
  return baseRate, level.loans.max, nil
end

local function createLoanRecord(orgId, org, amount, baseRate, payments, businessAccountId)
  local basePayment = r2(amount / payments)
  return {
    id = tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)),
    orgId = orgId,
    orgName = org.name or orgId,
    principalOriginal = r2(amount),
    principalOutstanding = r2(amount),
    basePayment = basePayment,
    rate = baseRate,
    paymentsSent = 0,
    createdAt = os.time(),
    secondsUntilNextPayment = PAYMENT_INTERVAL_S,
    prepaidCredit = 0,
    amountPaid = 0,
    businessAccountId = normalizeBusinessAccountId(businessAccountId),
  }
end

local function notifyLoanTaken(loan, amount, payments)
  if guihooks and guihooks.trigger then
    if notificationsEnabled then
      guihooks.trigger("toastrMsg", {type="info", title="Loan Approved", msg="Received $" .. string.format("%.2f", amount) .. " loan from " .. (loan.orgName or loan.orgId) .. " at " .. string.format("%.1f", (loan.rate or 0) * 100) .. "% interest over " .. payments .. " payments."})
    end
    guihooks.trigger('loans:activeUpdated')
    if career_modules_playerAttributes then
      guihooks.trigger('loans:funds', career_modules_playerAttributes.getAttributeValue('money'))
    end
  end
end

--- Takes a loan from an org. uncapped=true bypasses org limits (e.g. business loans).
--- businessAccountId: when set, funds go to that account and no cash is disbursed.
--- @return table|table loan UI object on success, or {error=string, max=number} on failure
local function takeLoan(orgId, amount, payments, rate, uncapped, businessAccountId)
  getLoanOrganizations()

  local org = freeroam_organizations.getOrganizations()[orgId]
  if not org then return {error = "invalid_org"} end

  local baseRate
  local available = math.huge

  if uncapped then
    baseRate = rate or 0
  else
    local creditMod = career_modules_credit
    local creditInfo = creditMod and creditMod.getScore() or nil
    local creditTier = creditInfo and creditInfo.tier or nil
    local orgMax, err
    baseRate, orgMax, err = getBaseRateForRegularLoan(org, rate, payments, creditTier)
    if err then return err end
    local outstandingByOrg = getOutstandingPrincipalByOrg()
    available = math.max(0, orgMax - (outstandingByOrg[orgId] or 0))
    local maxMultiplier = creditTier and (creditTier.maxMultiplier or 1.0) or 1.0
    available = math.floor(available * maxMultiplier)
  end

  if amount <= 0 then return {error = "invalid_amount", max = uncapped and 0 or available} end
  if not uncapped and amount > available then return {error = "invalid_amount", max = available} end

  local loan = createLoanRecord(orgId, org, amount, baseRate, payments, businessAccountId)

  table.insert(activeLoans, loan)
  if career_modules_credit then career_modules_credit.recordLoanTaken(orgId) end

  if not loan.businessAccountId and career_modules_playerAttributes then
    career_modules_playerAttributes.addAttributes({money = amount}, {label = string.format("Loan received (%s)", loan.orgName)}, true)
  end

  career_saveSystem.saveCurrent()

  notifyLoanTaken(loan, amount, payments)
  return buildUiLoan(loan)
end

-- =============================================================================
-- Prepay Loan
-- =============================================================================

--- Attempts to pay amount from loan's source (bank account or player funds). Returns ok, errorCode.
local function attemptPrepayFromSource(loan, amount)
  local price = { money = { amount = amount } }
  if loan.businessAccountId and career_modules_bank then
    if (career_modules_bank.getAccountBalance(loan.businessAccountId) or 0) < amount then return false, "insufficient_funds" end
    local ok = career_modules_bank.payFromAccount(price, loan.businessAccountId, "Loan Prepayment", "Prepayment to " .. (loan.orgName or loan.orgId))
    return ok, ok and nil or "insufficient_funds"
  end
  if not career_modules_payment then return false, "insufficient_funds" end
  if not career_modules_payment.canPay(price) then return false, "insufficient_funds" end
  local ok = career_modules_payment.pay(price, { label = "Loan Prepayment", description = "Prepayment to " .. (loan.orgName or loan.orgId) })
  return ok, ok and nil or "pay_failed"
end

--- Applies prepayment to loan: covers interest due, then principal due, then extra principal. Returns amount applied.
local function applyPrepaymentToLoan(loan, amount)
  local interestDue = getInterestDue(loan)
  local principalDue = r2(math.max(0, (loan.basePayment or 0) - (loan.nextPrincipalPaid or 0)))
  local maxApplicable = r2((loan.principalOutstanding or 0) + interestDue)
  amount = math.min(amount, maxApplicable)

  local coverInterest = math.min(amount, interestDue)
  loan.nextInterestPaid = r2((loan.nextInterestPaid or 0) + coverInterest)
  local remain = r2(amount - coverInterest)

  if remain > 0 then
    local coverPrincipal = math.min(remain, principalDue)
    loan.nextPrincipalPaid = r2((loan.nextPrincipalPaid or 0) + coverPrincipal)
    loan.principalOutstanding = r2(math.max(0, (loan.principalOutstanding or 0) - coverPrincipal))
    remain = r2(remain - coverPrincipal)
  end

  if remain > 0 then
    loan.principalOutstanding = r2(math.max(0, (loan.principalOutstanding or 0) - remain))
  end

  loan.amountPaid = r2((loan.amountPaid or 0) + amount)
  return amount
end

--- Applies prepayment to a loan. Returns loan UI object, {id, status='paid_off'}, or {error=string}.
local function prepayLoan(loanId, amount)
  if not amount or amount <= 0 then return { error = "invalid_amount" } end

  local loan, index
  for idx, l in ipairs(activeLoans) do
    if l.id == loanId then loan, index = l, idx; break end
  end
  if not loan then return { error = "loan_not_found" } end

  local payOk, payErr = attemptPrepayFromSource(loan, amount)
  if not payOk then
    return { error = payErr or "insufficient_funds" }
  end

  local amountApplied = applyPrepaymentToLoan(loan, amount)

  if notificationsEnabled and guihooks and guihooks.trigger then
    guihooks.trigger("toastrMsg", {type="success", title="Prepayment Applied", msg="Applied $" .. string.format("%.2f", amountApplied) .. " prepayment to loan with " .. (loan.orgName or loan.orgId)})
  end

  if (loan.principalOutstanding or 0) <= 1e-6 then
    loan.completedAt = os.time()
    local completedId = loan.id
    local completedOrg = loan.orgName or loan.orgId
    table.remove(activeLoans, index)
    if career_modules_credit then career_modules_credit.recordLoanCompleted() end
    career_saveSystem.saveCurrent()
    guihooks.trigger('loans:completed', { id = completedId, orgName = completedOrg })
    if guihooks and guihooks.trigger then
      if notificationsEnabled then
        guihooks.trigger("toastrMsg", {type="success", title="Loan Paid Off", msg="Congratulations! Your loan with " .. completedOrg .. " has been fully paid off."})
      end
      guihooks.trigger('loans:activeUpdated')
      if career_modules_playerAttributes then guihooks.trigger('loans:funds', career_modules_playerAttributes.getAttributeValue('money')) end
    end
    return { id = completedId, status = 'paid_off' }
  end

  career_saveSystem.saveCurrent()
  if guihooks and guihooks.trigger then
    guihooks.trigger('loans:activeUpdated')
    if career_modules_playerAttributes then
      guihooks.trigger('loans:funds', career_modules_playerAttributes.getAttributeValue('money'))
    end
  end
  return buildUiLoan(loan)
end

-- =============================================================================
-- Public API
-- =============================================================================

--- Returns UI-ready list of all active loans.
local function getActiveLoans()
  local result = {}
  for _, loan in ipairs(activeLoans) do table.insert(result, buildUiLoan(loan)) end
  return result
end

local originComputerId
local function openMenuFromComputer(computerId)
  originComputerId = computerId
  guihooks.trigger('ChangeState', {state = 'loans-menu'})
end

local function closeMenu()
  if originComputerId then
    local computer = freeroam_facilities.getFacility("computer", originComputerId)
    career_modules_computer.openMenu(computer)
  else
    career_career.closeAllMenus()
  end
end

local function setNotificationsEnabled(enabled)
  notificationsEnabled = enabled
  career_saveSystem.saveCurrent()
  if guihooks and guihooks.trigger then
    guihooks.trigger('loans:notificationsUpdated', enabled)
  end
  return notificationsEnabled
end

-- =============================================================================
-- Lifecycle Hooks
-- =============================================================================

local function onComputerAddFunctions(menuData, computerFunctions)
  local data = {
    id = "loans",
    label = "Loans",
    callback = function()
      openMenuFromComputer(menuData.computerFacility.id)
    end,
    order = 25
  }
  computerFunctions.general[data.id] = data
end

local function onExtensionLoaded()
  getLoanOrganizations()
  loadLoans()
end

local function onCareerActivated()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  local loansFilePath = currentSavePath .. saveFile
  if FS:fileExists(loansFilePath) then
    loadLoans()
  else
    activeLoans = {}
    notificationsEnabled = true
  end
end

--- Clears all loans and resets notifications. Returns number of loans cleared.
local function clearAllLoans()
  local loanCount = #activeLoans
  activeLoans = {}
  notificationsEnabled = true
  career_saveSystem.saveCurrent()
  return loanCount
end

-- =============================================================================
-- Exports
-- =============================================================================

M.onSaveCurrentSaveSlot = saveLoans
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated
M.onUpdate = onUpdate
M.onComputerAddFunctions = onComputerAddFunctions
M.getLoanOrganizations = getLoanOrganizations
M.getOutstandingPrincipalByOrg = getOutstandingPrincipalByOrg
M.getLoanOffers = getLoanOffers
M.getActiveLoans = getActiveLoans
M.takeLoan = takeLoan
M.calculatePayment = calculatePayment
M.prepayLoan = prepayLoan
M.openMenuFromComputer = openMenuFromComputer
M.closeMenu = closeMenu
M.closeAllMenus = function() career_career.closeAllMenus() end
M.getAvailableFunds = function()
  if career_modules_playerAttributes then return career_modules_playerAttributes.getAttributeValue('money') end
  return 0
end
M.getNotificationsEnabled = function() return notificationsEnabled end
M.setNotificationsEnabled = setNotificationsEnabled
M.clearAllLoans = clearAllLoans

return M
