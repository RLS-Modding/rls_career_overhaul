-- Player loans: offers, calendar installments, missed payments, prepayment and business settlement.
-- Config and state, calculations and payment helpers, update, lifecycle, public API and hooks.
local recordPayoff = require("overhaul/lib/progression/logbookFeed").register("overhaul.loanPaidOff", {
  title = "Loan paid off", label = "Loans", icon = "checkmark"
}, "career/economy/loans.lua")

local recordLoan = require("overhaul/lib/progression/logbookFeed").register("overhaul.loanOpened", {
  title = "Loan opened", label = "Loans", icon = "carCoins"
}, "career/economy/loans.lua")

local M = {}

local calendar = require("overhaul/lib/world/calendar")
local phoneLayout = require("overhaul/lib/phone/layoutOwner")

local saveStore = require("overhaul/lib/save/store")

-- Config ---------------------------------------------------------------------------------------------


local PAYMENT_INTERVAL_S = 10 * 60
local TERM_OPTIONS = {12, 24, 36, 48}
local MINUTES_PER_WORLD_DAY = 1440
local UPDATE_INTERVAL_S = 5
-- Residue below this many dollars is swept into the final installment instead of a tiny extra payment.
local LOAN_RESIDUE_SWEEP = 0.5

local PHONE_NOTIF_SOUND = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" }
local PHONE_KIND = { success = "success", error = "error", info = "invite" }

-- State ----------------------------------------------------------------------------------------------

local savePathFeature = nil

local updateTimer = 0
local activeLoans = {}
local notificationsEnabled = true
-- The computer the loans menu was opened from, so closing returns there.
local originComputerId = nil

-- Helpers --------------------------------------------------------------------------------------------

-- Round to cents before storing or displaying a loan amount.
local function r2(amount)
  return (amount and math.floor(amount * 100 + 0.5) / 100) or 0
end

-- Absolute world minutes from the calendar, or nil while the calendar is not ready.
local function currentWorldMinutes()
  local ui = calendar.get()
  if not ui or ui.ready == false or ui.dayIndex == nil then return nil end
  return math.max(0, math.floor(tonumber(ui.dayIndex) or 0)) * MINUTES_PER_WORLD_DAY
    + math.max(0, math.min(MINUTES_PER_WORLD_DAY - 1, math.floor(tonumber(ui.minuteOfDay) or 0)))
end

local function calendarSecondsUntilPayment(loan)
  local absolute = currentWorldMinutes()
  if not absolute or not loan.nextPaymentWorldMinute then return nil end
  local remainingWorldMinutes = math.max(0, loan.nextPaymentWorldMinute - absolute)
  local ui = calendar.get() or {}
  local dayLengthMinutes = tonumber(ui.dayLengthMinutes) or 60
  return remainingWorldMinutes / MINUTES_PER_WORLD_DAY * dayLengthMinutes * 60
end

local function fireLoanPhoneNotification(channelKey, toastType, title, message)
  local layout = phoneLayout.get()
  if not (layout and layout.fireNotification) then
    return false
  end
  return layout.fireNotification(channelKey, {
    title = title,
    message = message,
    kind = PHONE_KIND[toastType] or "invite",
    ttl = 8,
    source = "Loans",
    sound = PHONE_NOTIF_SOUND,
  })
end

local function normalizeBusinessAccountId(id)
  if not id or id == "" or id == "null" then return nil end
  return id
end

-- Storage --------------------------------------------------------------------------------------------

-- Resolve the declared relative file, preserving the supplied base's spelling and separators.
local function saveFilePath(currentSavePath)
  if not savePathFeature then
    savePathFeature = saveStore.bind(overhaul_career_saveSystem).feature("economy.loans", {
      owner = "overhaul_career_economy_loans",
      files = {"career/rls_career/loans.json"},
      phase = "profile",
      root = "slot",
      required = true,
    })
  end
  return currentSavePath .. "/" .. savePathFeature.path("")
end

local function loadLoans()
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  local data = jsonReadFile(saveFilePath(currentSavePath)) or {}
  activeLoans = data.activeLoans or {}
  for _, loan in ipairs(activeLoans) do
    loan.businessAccountId = normalizeBusinessAccountId(loan.businessAccountId)
    -- Migrates moneyGrab business loans saved without a calendar schedule to a daily one.
    if loan.businessAccountId and loan.orgId == "moneyGrabBusiness" and not loan.calendarIntervalMinutes then
      loan.calendarIntervalMinutes = MINUTES_PER_WORLD_DAY
      loan.nextPaymentWorldMinute = nil
    end
  end
  notificationsEnabled = data.notificationsEnabled
  if notificationsEnabled == nil then notificationsEnabled = true end
end

-- Persists active loans and notification settings; uses the current save slot when no path is given.
local function saveLoans(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not currentSavePath then
    local _, profilePath = overhaul_career_saveSystem.getCurrentProfile()
    currentSavePath = profilePath
    if not currentSavePath then return end
  end
  local dirPath = saveFilePath(currentSavePath):match("^(.*)/[^/]+$")
  if not writer.exists(dirPath) then writer.mkdir(dirPath) end
  local data = {
    activeLoans = activeLoans,
    notificationsEnabled = notificationsEnabled
  }
  overhaul_career_saveSystem.jsonWriteFileSafe(saveFilePath(currentSavePath), data, true)
end

-- Loan calculations ----------------------------------------------------------------------------------

local function getInstallmentPrincipal(loan)
  local base = loan.basePayment or 0
  local total = (loan.nextPrincipalPaid or 0) + (loan.principalOutstanding or 0)
  if total - base < LOAN_RESIDUE_SWEEP then
    return r2(math.max(0, total))
  end
  return r2(base)
end

local function getPrincipalDue(loan)
  return r2(math.max(0, getInstallmentPrincipal(loan) - (loan.nextPrincipalPaid or 0)))
end

local function getRemainingPayments(loan)
  local base = loan.basePayment or 0
  local outstanding = loan.principalOutstanding or 0
  if base <= 0 or outstanding <= 1e-6 then return 0 end
  return math.max(1, math.ceil((outstanding - LOAN_RESIDUE_SWEEP) / base))
end

local function getInterestDue(loan)
  local interest = r2(getInstallmentPrincipal(loan) * (loan.rate or 0))
  return r2(math.max(0, interest - (loan.nextInterestPaid or 0)))
end

local function nextPaymentDueFor(loan)
  return r2(getInterestDue(loan) + getPrincipalDue(loan))
end

local function buildUiLoan(loan)
  local perPayment = r2((loan.basePayment or 0) * (1 + (loan.rate or 0)))
  local remaining = getRemainingPayments(loan)
  local totalPayments = (loan.basePayment or 0) <= 0 and 0
    or math.max(1, math.ceil(((loan.principalOriginal or 0) - LOAN_RESIDUE_SWEEP) / loan.basePayment))
  local interestRemaining = r2(math.max(0, (perPayment - (loan.basePayment or 0)) * remaining))
  local secondsUntilNextPayment = loan.calendarIntervalMinutes and calendarSecondsUntilPayment(loan)
    or (loan.secondsUntilNextPayment or PAYMENT_INTERVAL_S)
  return {
    id = loan.id,
    orgId = loan.orgId,
    orgName = loan.orgName,
    principal = r2(loan.principalOriginal or 0),
    principalOutstanding = r2(loan.principalOutstanding or 0),
    basePayment = r2(loan.basePayment or 0),
    perPayment = perPayment,
    nextPaymentDue = nextPaymentDueFor(loan),
    nextPaymentInterest = getInterestDue(loan),
    prepaidCredit = r2((loan.nextInterestPaid or 0) + (loan.nextPrincipalPaid or 0)),
    rate = loan.rate or 0,
    currentRate = loan.rate or 0,
    paymentsSent = loan.paymentsSent or 0,
    paymentsRemaining = remaining,
    paymentsTotal = totalPayments,
    secondsUntilNextPayment = secondsUntilNextPayment,
    calendarIntervalMinutes = loan.calendarIntervalMinutes,
    nextPaymentWorldMinute = loan.nextPaymentWorldMinute,
    createdAt = loan.createdAt,
    interestRemaining = interestRemaining,
    businessAccountId = loan.businessAccountId,
  }
end

-- Per-payment amount and total for a loan. rate is decimal (e.g. 0.1 = 10%). @return number perPayment, number total
local function calculatePayment(amount, rate, payments)
  if not amount or not rate or not payments or payments <= 0 then return 0, 0 end
  local base = amount / payments
  local perPayment = r2(base * (1 + rate))
  local total = r2(perPayment * payments)
  return perPayment, total
end

-- Offers ---------------------------------------------------------------------------------------------

local function getCreditModifiers()
  local creditInfo = overhaul_career_economy_credit.getScore() or nil
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

-- Map of orgId to total outstanding principal across all loans with that org.
local function getOutstandingPrincipalByOrg()
  local totals = {}
  for _, loan in ipairs(activeLoans) do
    if loan.orgId then
      totals[loan.orgId] = (totals[loan.orgId] or 0) + (loan.principalOutstanding or 0)
    end
  end
  return totals
end

-- Orgs with loan config at the player's current reputation level.
local function getLoanOrganizations()
  local orgs = {}
  for orgId, org in pairs(overhaul_world_organizations.getOrganizations()) do
    local level = org.reputationLevels[org.reputation.level + 2]
    if level and level.loans then
      orgs[orgId] = level.loans
    end
  end
  return orgs
end

local function buildOfferForOrg(orgId, org, level, outstandingByOrg, creditInfo, creditTier, rateMultiplier, maxMultiplier, availableTerms)
  local loanTerms = level.loans
  local available = math.max(0, (loanTerms.max or 0) - (outstandingByOrg[orgId] or 0))
  local adjustedMax = math.floor(available * maxMultiplier)
  -- Same global economy index that takeLoan uses, so the offer card matches the rate the loan is created with.
  local loanGlobalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
  local adjustedRateVal = (loanTerms.rate or 0) * loanGlobalIndex * rateMultiplier
  return {
    id = orgId,
    name = org.name or orgId,
    max = adjustedMax,
    rate = adjustedRateVal,
    terms = availableTerms,
    creditScore = creditInfo and creditInfo.score or nil,
    creditTier = creditTier and creditTier.label or nil,
    baseRate = loanTerms.rate,
    adjustedRate = adjustedRateVal,
    baseMax = available,
    adjustedMax = adjustedMax,
  }
end

-- Available offers from every org the player qualifies for, adjusted by credit tier.
local function getLoanOffers()
  local offers = {}
  local outstandingByOrg = getOutstandingPrincipalByOrg()
  local creditInfo, creditTier, rateMultiplier, maxMultiplier, availableTerms = getCreditModifiers()

  for orgId, org in pairs(overhaul_world_organizations.getOrganizations()) do
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

-- Reputation -----------------------------------------------------------------------------------------

local function awardOrgReputation(orgId, delta, orgName)
  if not orgId or not delta or delta == 0 then return end
  local key = tostring(orgId) .. "Reputation"
  local label
  if delta > 0 then
    label = string.format("Loan payment (%s)", orgName or orgId)
  else
    label = string.format("Missed loan payment (%s)", orgName or orgId)
  end
  overhaul_career_economy_playerAttributes.addAttributes({[key] = delta}, { label = label })
end

-- Scheduled payments ---------------------------------------------------------------------------------

local function tryPayFromBank(loan, needed)
  if not loan.businessAccountId then return false end
  local price = { money = { amount = needed, canBeNegative = true } }
  local ok = overhaul_career_economy_bank.payFromAccount(price, loan.businessAccountId, "Loan Payment", "Payment to " .. (loan.orgName or loan.orgId), {category = "loan"})
  return ok
end

local function tryPayFromPlayer(loan, needed)
  local price = { money = { amount = needed } }
  if not overhaul_career_economy_payment.canPay(price) then return false end
  local ok = overhaul_career_economy_payment.pay(price, { category = "loan", label = "Loan Payment", description = "Payment to " .. (loan.orgName or loan.orgId) })
  return ok
end

local function advancePaymentSchedule(loan)
  if loan.calendarIntervalMinutes then
    local absolute = currentWorldMinutes()
    loan.nextPaymentWorldMinute = (loan.nextPaymentWorldMinute or absolute or 0) + loan.calendarIntervalMinutes
  else
    loan.secondsUntilNextPayment = (loan.secondsUntilNextPayment or PAYMENT_INTERVAL_S) + PAYMENT_INTERVAL_S
  end
end

local function applyInstallmentPrepaid(loan)
  loan.paymentsSent = (loan.paymentsSent or 0) + 1
  loan.nextInterestPaid = 0
  loan.nextPrincipalPaid = 0
  advancePaymentSchedule(loan)
  awardOrgReputation(loan.orgId, 1, loan.orgName)
  overhaul_career_economy_credit.recordOnTimePayment()
end

local function applyPaymentSuccess(loan, needed, principalDue)
  loan.principalOutstanding = r2(math.max(0, (loan.principalOutstanding or 0) - principalDue))
  loan.paymentsSent = (loan.paymentsSent or 0) + 1
  loan.amountPaid = r2((loan.amountPaid or 0) + needed)
  loan.nextInterestPaid = 0
  loan.nextPrincipalPaid = 0
  advancePaymentSchedule(loan)
  awardOrgReputation(loan.orgId, 1, loan.orgName)
  overhaul_career_economy_credit.recordOnTimePayment()
  fireLoanPhoneNotification("loans.paymentMade", "success", "Loan Payment Made",
    "Successfully paid $" .. string.format("%.2f", needed) .. " to " .. (loan.orgName or loan.orgId))
end

-- A missed payment adds its interest to principal, raises the rate and costs reputation.
local function applyPaymentMissed(loan, needed, interestDue)
  overhaul_career_economy_credit.recordMissedPayment()
  loan.principalOutstanding = r2((loan.principalOutstanding or 0) + interestDue)
  -- These credits paid the installment being closed. Principal prepayments
  -- already reduced outstanding debt; neither credit can pay next month again.
  loan.nextInterestPaid, loan.nextPrincipalPaid = 0, 0
  local rateIncrease = (loan.rate or 0.25) * 0.1
  loan.rate = (loan.rate or 0) + rateIncrease
  loan.missed = (loan.missed or 0) + 1
  advancePaymentSchedule(loan)
  awardOrgReputation(loan.orgId, -5, loan.orgName)
  local capitalizedMsg = ""
  if interestDue > 0 then
    capitalizedMsg = " $" .. string.format("%.2f", interestDue) .. " interest added to principal."
  end
  fireLoanPhoneNotification("loans.paymentMissed", "error", "Loan Payment Missed",
    "Failed to pay $" .. string.format("%.2f", needed) .. " to " .. (loan.orgName or loan.orgId) .. "." .. capitalizedMsg .. " Interest rate increased by " .. string.format("%.1f", rateIncrease * 100) .. "%.")
end

local function removeCompletedLoan(loan, index)
  loan.completedAt = os.time()
  local completedId = loan.id
  local completedOrg = loan.orgName or loan.orgId
  table.remove(activeLoans, index)
  overhaul_career_economy_credit.recordLoanCompleted()
  recordPayoff({name = completedOrg, receipt = completedId})
  guihooks.trigger("loans:completed", { id = completedId, orgName = completedOrg })
  fireLoanPhoneNotification("loans.paidOff", "success", "Loan Paid Off",
    "Congratulations! Your loan with " .. completedOrg .. " has been fully paid off.")
end

local function processSingleLoanPayment(loan)
  local interestDue = getInterestDue(loan)
  local principalDue = getPrincipalDue(loan)
  local needed = r2(interestDue + principalDue)

  if needed <= 1e-6 then
    applyInstallmentPrepaid(loan)
    return true
  end

  local paymentSuccess
  if loan.businessAccountId then
    paymentSuccess = tryPayFromBank(loan, needed)
  else
    paymentSuccess = tryPayFromPlayer(loan, needed)
  end
  if paymentSuccess then
    applyPaymentSuccess(loan, needed, principalDue)
    return true
  end

  applyPaymentMissed(loan, needed, interestDue)
  return true
end

local function paymentIsDue(loan, absoluteWorldMinutes)
  if loan.calendarIntervalMinutes then
    return absoluteWorldMinutes and loan.nextPaymentWorldMinute and absoluteWorldMinutes >= loan.nextPaymentWorldMinute
  end
  return (loan.secondsUntilNextPayment or PAYMENT_INTERVAL_S) <= 0
end

-- Processes scheduled payments for all active loans; onUpdate calls this every UPDATE_INTERVAL_S. @param elapsedSimSeconds number Simulated seconds since the last run
local function processDuePayments(elapsedSimSeconds)
  local loansModified = false
  local absoluteWorldMinutes = currentWorldMinutes()

  for i = #activeLoans, 1, -1 do
    local loan = activeLoans[i]
    if loan.calendarIntervalMinutes then
      if absoluteWorldMinutes and not loan.nextPaymentWorldMinute then
        loan.nextPaymentWorldMinute = absoluteWorldMinutes + loan.calendarIntervalMinutes
        loansModified = true
      end
    else
      loan.secondsUntilNextPayment = (loan.secondsUntilNextPayment or PAYMENT_INTERVAL_S) - elapsedSimSeconds
    end

    while getRemainingPayments(loan) > 0 and paymentIsDue(loan, absoluteWorldMinutes) do
      if processSingleLoanPayment(loan) then
        loansModified = true
      end
    end

    if (loan.principalOutstanding or 0) <= 1e-6 then
      removeCompletedLoan(loan, i)
      loansModified = true
    end
  end

  if loansModified then
    overhaul_career_saveSystem.saveCurrent()
  end
  local enriched = {}
  for _, loan in ipairs(activeLoans) do table.insert(enriched, buildUiLoan(loan)) end
  guihooks.trigger("loans:tick", enriched)
  guihooks.trigger("loans:funds", overhaul_career_economy_playerAttributes.getAttributeValue("money"))
end

-- Take loan ------------------------------------------------------------------------------------------

-- Base rate and org max for a regular (non-uncapped) loan; returns baseRate, orgMax, err.
local function getBaseRateForRegularLoan(org, rate, payments, creditTier)
  local level = org.reputationLevels[org.reputation.level + 2]
  if not level or not level.loans then return nil, nil, {error = "no_offer"} end
  local baseRate = rate or (level.loans.rate or 0)
  local loanGlobalIndex = overhaul_career_economy_globalEconomy.getGlobalIndex() or 1.0
  baseRate = baseRate * loanGlobalIndex
  if creditTier then
    baseRate = baseRate * (creditTier.rateMultiplier or 1.0)
    if creditTier.termsAvailable then
      local termAllowed = false
      for _, term in ipairs(creditTier.termsAvailable) do
        if term == payments then termAllowed = true; break end
      end
      if not termAllowed then return nil, nil, {error = "term_not_available"} end
    end
  end
  return baseRate, level.loans.max, nil
end

local function createLoanRecord(orgId, org, amount, baseRate, payments, businessAccountId, calendarIntervalMinutes)
  local basePayment = r2(amount / payments)
  calendarIntervalMinutes = math.max(0, math.floor(tonumber(calendarIntervalMinutes) or 0))
  local absoluteWorldMinutes = currentWorldMinutes()
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
    calendarIntervalMinutes = calendarIntervalMinutes > 0 and calendarIntervalMinutes or nil,
    nextPaymentWorldMinute = calendarIntervalMinutes > 0 and absoluteWorldMinutes
      and absoluteWorldMinutes + calendarIntervalMinutes or nil,
    prepaidCredit = 0,
    amountPaid = 0,
    businessAccountId = normalizeBusinessAccountId(businessAccountId),
  }
end

local function notifyLoanTaken(loan, amount, payments)
  fireLoanPhoneNotification("loans.approved", "info", "Loan Approved",
    "Received $" .. string.format("%.2f", amount) .. " loan from " .. (loan.orgName or loan.orgId) .. " at " .. string.format("%.1f", (loan.rate or 0) * 100) .. "% interest over " .. payments .. " payments.")
  guihooks.trigger("loans:activeUpdated")
  guihooks.trigger("loans:funds", overhaul_career_economy_playerAttributes.getAttributeValue("money"))
end

-- Takes a loan from an org.
local function takeLoan(orgId, amount, payments, rate, uncapped, businessAccountId, calendarIntervalMinutes)
  getLoanOrganizations()

  local org = overhaul_world_organizations.getOrganizations()[orgId]
  if not org then return {error = "invalid_org"} end

  local baseRate
  local available = math.huge

  if uncapped then
    baseRate = rate or 0
  else
    local creditInfo = overhaul_career_economy_credit.getScore() or nil
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

  local loan = createLoanRecord(orgId, org, amount, baseRate, payments, businessAccountId, calendarIntervalMinutes)

  table.insert(activeLoans, loan)
  overhaul_career_economy_credit.recordLoanTaken(orgId)

  if not loan.businessAccountId then
    overhaul_career_economy_playerAttributes.addAttributes({money = amount}, {category = "loan", label = string.format("Loan received (%s)", loan.orgName)}, true)
  end

  recordLoan({detail = loan.orgName .. (loan.businessAccountId and " / Business financing principal" or " / Loan principal"),
    money = amount, receipt = loan.id})
  overhaul_career_saveSystem.saveCurrent()
  notifyLoanTaken(loan, amount, payments)
  return buildUiLoan(loan)
end

local function createPersonalDebtLoan(orgId, amount, payments, rate)
  getLoanOrganizations()
  local org = overhaul_world_organizations.getOrganizations()[orgId]
  if not org then return {error = "invalid_org"} end
  amount = r2(tonumber(amount) or 0)
  payments = tonumber(payments) or 72
  if amount <= 0 then return {error = "invalid_amount"} end
  if payments <= 0 then payments = 72 end
  local loan = createLoanRecord(orgId, org, amount, rate or 0, payments, nil)
  table.insert(activeLoans, loan)
  overhaul_career_economy_credit.recordLoanTaken(orgId)
  recordLoan({detail = loan.orgName .. " / Converted business debt", receipt = loan.id})
  overhaul_career_saveSystem.saveCurrent()
  fireLoanPhoneNotification("loans.approved", "info", "Debt Converted",
    "Converted $" .. string.format("%.2f", amount) .. " of business debt into a personal loan with " .. (loan.orgName or loan.orgId) .. ".")
  guihooks.trigger("loans:activeUpdated")
  guihooks.trigger("loans:funds", overhaul_career_economy_playerAttributes.getAttributeValue("money"))
  return buildUiLoan(loan)
end

-- Prepay loan ----------------------------------------------------------------------------------------

-- Pays amount from the loan's source (bank account or player funds); returns ok, errorCode.
local function attemptPrepayFromSource(loan, amount)
  local price = { money = { amount = amount } }
  if loan.businessAccountId then
    if (overhaul_career_economy_bank.getAccountBalance(loan.businessAccountId) or 0) < amount then return false, "insufficient_funds" end
    local ok = overhaul_career_economy_bank.payFromAccount(price, loan.businessAccountId, "Loan Prepayment", "Prepayment to " .. (loan.orgName or loan.orgId), {category = "loan"})
    if ok then
      return ok, nil
    else
      return ok, "insufficient_funds"
    end
  end
  if not overhaul_career_economy_payment.canPay(price) then return false, "insufficient_funds" end
  local ok = overhaul_career_economy_payment.pay(price, { category = "loan", label = "Loan Prepayment", description = "Prepayment to " .. (loan.orgName or loan.orgId) })
  if ok then
    return ok, nil
  else
    return ok, "pay_failed"
  end
end

-- Covers interest due first, then principal due, then extra principal; returns the amount applied.
local function applyPrepaymentToLoan(loan, amount)
  local interestDue = getInterestDue(loan)
  local principalDue = getPrincipalDue(loan)
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

-- Applies a prepayment to a loan. Returns the loan UI object, {id, status = "paid_off"}, or {error = string}.
local function prepayLoan(loanId, amount)
  amount = tonumber(amount) or 0
  if amount <= 0 then return { error = "invalid_amount" } end

  local loan, index
  for idx, candidate in ipairs(activeLoans) do
    if candidate.id == loanId then loan, index = candidate, idx; break end
  end
  if not loan then return { error = "loan_not_found" } end

  local interestDue = getInterestDue(loan)
  local maxApplicable = r2((loan.principalOutstanding or 0) + interestDue)
  amount = math.min(amount, maxApplicable)
  if amount <= 0 then return { error = "nothing_owed" } end

  local payOk, payErr = attemptPrepayFromSource(loan, amount)
  if not payOk then
    return { error = payErr or "insufficient_funds" }
  end

  local amountApplied = applyPrepaymentToLoan(loan, amount)

  fireLoanPhoneNotification("loans.prepayment", "success", "Prepayment Applied",
    "Applied $" .. string.format("%.2f", amountApplied) .. " prepayment to loan with " .. (loan.orgName or loan.orgId))

  if (loan.principalOutstanding or 0) <= 1e-6 then
    loan.completedAt = os.time()
    local completedId = loan.id
    local completedOrg = loan.orgName or loan.orgId
    table.remove(activeLoans, index)
    overhaul_career_economy_credit.recordLoanCompleted()
    recordPayoff({name = completedOrg, receipt = completedId})
    overhaul_career_saveSystem.saveCurrent()
    guihooks.trigger("loans:completed", { id = completedId, orgName = completedOrg })
    fireLoanPhoneNotification("loans.paidOff", "success", "Loan Paid Off",
      "Congratulations! Your loan with " .. completedOrg .. " has been fully paid off.")
    guihooks.trigger("loans:activeUpdated")
    guihooks.trigger("loans:funds", overhaul_career_economy_playerAttributes.getAttributeValue("money"))
    return { id = completedId, status = "paid_off" }
  end

  overhaul_career_saveSystem.saveCurrent()
  guihooks.trigger("loans:activeUpdated")
  guihooks.trigger("loans:funds", overhaul_career_economy_playerAttributes.getAttributeValue("money"))
  return buildUiLoan(loan)
end

-- Settlement and menu helpers ------------------------------------------------------------------------

-- UI-ready list of all active loans.
local function getActiveLoans()
  local result = {}
  for _, loan in ipairs(activeLoans) do table.insert(result, buildUiLoan(loan)) end
  return result
end

-- Applies sale proceeds to loans tied to a business account, then converts any remainder to player-paid loans. Returns settlement details without moving money between accounts.
local function settleBusinessLoans(businessAccountId, availableAmount)
  businessAccountId = normalizeBusinessAccountId(businessAccountId)
  availableAmount = r2(math.max(0, tonumber(availableAmount) or 0))
  local result = {
    businessAccountId = businessAccountId,
    availableApplied = 0,
    paidOffPrincipal = 0,
    convertedPrincipal = 0,
    convertedLoans = 0,
    paidOffLoans = 0,
    remainingAvailable = availableAmount,
    loans = {}
  }
  if not businessAccountId then return result end

  for i = #activeLoans, 1, -1 do
    local loan = activeLoans[i]
    if normalizeBusinessAccountId(loan.businessAccountId) == businessAccountId then
      local before = r2(loan.principalOutstanding or 0)
      local applied = math.min(result.remainingAvailable, before)
      if applied > 0 then
        loan.principalOutstanding = r2(before - applied)
        loan.amountPaid = r2((loan.amountPaid or 0) + applied)
        result.remainingAvailable = r2(result.remainingAvailable - applied)
        result.availableApplied = r2(result.availableApplied + applied)
        result.paidOffPrincipal = r2(result.paidOffPrincipal + applied)
      end

      local remaining = r2(loan.principalOutstanding or 0)
      table.insert(result.loans, {
        id = loan.id,
        orgId = loan.orgId,
        orgName = loan.orgName,
        principalBefore = before,
        principalPaid = applied,
        principalRemaining = remaining,
      })

      if remaining <= 1e-6 then
        table.remove(activeLoans, i)
        result.paidOffLoans = result.paidOffLoans + 1
        overhaul_career_economy_credit.recordLoanCompleted()
        recordPayoff({name = loan.orgName or loan.orgId, receipt = loan.id})
        guihooks.trigger("loans:completed", { id = loan.id, orgName = loan.orgName or loan.orgId })
      else
        loan.businessAccountId = nil
        result.convertedLoans = result.convertedLoans + 1
        result.convertedPrincipal = r2(result.convertedPrincipal + remaining)
      end
    end
  end

  overhaul_career_saveSystem.saveCurrent()
  guihooks.trigger("loans:activeUpdated")
  guihooks.trigger("loans:funds", overhaul_career_economy_playerAttributes.getAttributeValue("money"))
  return result
end

local function openMenuFromComputer(computerId)
  originComputerId = computerId
  extensions.ui_router.navigate("loans-menu")
end

local function closeMenu()
  if originComputerId then
    local computer = overhaul_world_facilities.getFacility("computer", originComputerId)
    overhaul_career_garage_computer.openMenu(computer)
  else
    overhaul_career_career.closeAllMenus()
  end
end

local function setNotificationsEnabled(enabled)
  notificationsEnabled = enabled
  overhaul_career_saveSystem.saveCurrent()
  guihooks.trigger("loans:notificationsUpdated", enabled)
  return notificationsEnabled
end

-- Clears all loans and resets notifications; returns the number of loans cleared.
local function clearAllLoans()
  local loanCount = #activeLoans
  activeLoans = {}
  notificationsEnabled = true
  overhaul_career_saveSystem.saveCurrent()
  return loanCount
end

-- Per-frame update -----------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim, dtRaw)
  -- Skip while the career is inactive: the batch modules this tick calls (playerAttributes, credit, bank) only exist while it is active, including during a profile switch.
  if not overhaul_career_career.isActive() then
    return
  end
  if not overhaul_career_economy_playerAttributes then return end
  updateTimer = updateTimer + dtSim
  if updateTimer >= UPDATE_INTERVAL_S then
    local elapsed = updateTimer
    updateTimer = 0
    processDuePayments(elapsed)
  end
end

-- Lifecycle ------------------------------------------------------------------------------------------

local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
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

-- Organizations are read on activation, not here: reputation may not be loaded yet, and a fatal in this hook aborts the whole career module load.
local function onExtensionLoaded()
  loadLoans()
end

local function onCareerActivated()
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  -- All career modules, reputation included, are loaded by now.
  getLoanOrganizations()
  local loansFilePath = saveFilePath(currentSavePath)
  if FS:fileExists(loansFilePath) then
    loadLoans()
  else
    activeLoans = {}
    notificationsEnabled = true
  end
end

-- Public API -----------------------------------------------------------------------------------------

M.getLoanOrganizations = getLoanOrganizations
M.getOutstandingPrincipalByOrg = getOutstandingPrincipalByOrg
M.getLoanOffers = getLoanOffers
M.getActiveLoans = getActiveLoans
M.settleBusinessLoans = settleBusinessLoans
M.takeLoan = takeLoan
M.createPersonalDebtLoan = createPersonalDebtLoan
M.calculatePayment = calculatePayment
M.prepayLoan = prepayLoan
M.openMenuFromComputer = openMenuFromComputer
M.closeMenu = closeMenu
M.closeAllMenus = function() overhaul_career_career.closeAllMenus() end
M.getAvailableFunds = function()
  if not overhaul_career_career.isActive() then return 0 end
  return overhaul_career_economy_playerAttributes.getAttributeValue("money")
end
M.getNotificationsEnabled = function() return notificationsEnabled end
M.setNotificationsEnabled = setNotificationsEnabled
M.clearAllLoans = clearAllLoans

-- Game hooks -----------------------------------------------------------------------------------------

M.onOverhaulSaveCurrentProfile = saveLoans
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated
M.onUpdate = onUpdate
M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions

return M
