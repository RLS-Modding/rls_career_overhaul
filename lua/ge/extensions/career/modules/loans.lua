local M = {}

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/loans.json"

local PAYMENT_INTERVAL_S = 5 * 60
local TERM_OPTIONS = {12, 24, 36, 48} -- payments, each payment due every 5 minutes

local updateInterval = 5
local updateTimer = 0

local activeLoans = {}
local notificationsEnabled = true -- Default to enabled

local function r2(n)
  if not n then return 0 end
  return math.floor(n * 100 + 0.5) / 100
end

local function adjustedRate(baseRate, payments)
  if not baseRate or not payments then return baseRate or 0 end
  local step = (payments / 12) - 1
  if step < 0 then step = 0 end
  return baseRate * (1 + 0.1 * step)
end

local function ensureSaveDir(currentSavePath)
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function loadLoans()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  local data = jsonReadFile(currentSavePath .. saveFile) or {}
  activeLoans = data.activeLoans or {}
  notificationsEnabled = data.notificationsEnabled
  if notificationsEnabled == nil then notificationsEnabled = true end -- Default to enabled if not set
end

local function saveLoans(currentSavePath)
  if not currentSavePath then
    local _, p = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = p
    if not currentSavePath then return end
  end
  ensureSaveDir(currentSavePath)
  local data = {
    activeLoans = activeLoans,
    notificationsEnabled = notificationsEnabled
  }
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, data, true)
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveLoans(currentSavePath)
end

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

local function getOutstandingPrincipalByOrg()
    local totals = {}
    for _, loan in ipairs(activeLoans) do
      if loan.orgId then
        totals[loan.orgId] = (totals[loan.orgId] or 0) + (loan.principalOutstanding or 0)
      end
    end
    return totals
  end

local function getLoanOffers()
  local offers = {}
  local outstandingByOrg = getOutstandingPrincipalByOrg()

  for orgId, org in pairs(freeroam_organizations.getOrganizations()) do
    local level = org.reputationLevels[org.reputation.level + 2]
    if level and level.loans then
      local minLoanLevel = nil
      for levelIdx, levelData in ipairs(org.reputationLevels) do
        if levelData.loans then
          minLoanLevel = levelIdx - 2
          break
        end
      end
      if minLoanLevel and org.reputation.level >= minLoanLevel then
        local l = level.loans
        local available = math.max(0, (l.max or 0) - (outstandingByOrg[orgId] or 0))
        table.insert(offers, {
          id = orgId,
          name = org.name or orgId,
          max = available,
          rate = l.rate,
          terms = TERM_OPTIONS
        })
      end
    else
    end
  end
  table.sort(offers, function(a,b) return a.name < b.name end)
  return offers
end

local function calculatePayment(amount, rate, payments)
  if not amount or not rate or not payments or payments <= 0 then return 0, 0 end
  local base = amount / payments
  local perPayment = r2(base * (1 + rate))
  local total = r2(perPayment * payments)
  return perPayment, total
end

local function makeId()
  return tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999))
end

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

local function perPaymentFor(loan)
  return r2((loan.basePayment or 0) * (1 + (loan.rate or 0)))
end

local function paymentsRemainingFor(loan)
  if (loan.basePayment or 0) <= 0 then return 0 end
  return math.max(0, math.ceil((loan.principalOutstanding or 0) / (loan.basePayment or 1)))
end

local function nextPaymentDueFor(loan)
  local base = loan.basePayment or 0
  local interest = r2(base * (loan.rate or 0))
  local ip = r2(math.max(0, interest - (loan.nextInterestPaid or 0)))
  local pp = r2(math.max(0, base - (loan.nextPrincipalPaid or 0)))
  return r2(ip + pp)
end

local function buildUiLoan(loan)
  local per = perPaymentFor(loan)
  local remaining = paymentsRemainingFor(loan)
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
  }
end

local function processDuePayments(elapsedSimSeconds)
  local now = os.time()
  local loansModified = false
  for i = #activeLoans, 1, -1 do
    local loan = activeLoans[i]
    loan.secondsUntilNextPayment = (loan.secondsUntilNextPayment or PAYMENT_INTERVAL_S) - elapsedSimSeconds

    while paymentsRemainingFor(loan) > 0 and loan.secondsUntilNextPayment <= 0 do
      local base = loan.basePayment or 0
      local interest = r2(base * (loan.rate or 0))
      local interestDue = r2(math.max(0, interest - (loan.nextInterestPaid or 0)))
      local principalDue = r2(math.max(0, base - (loan.nextPrincipalPaid or 0)))
      local needed = r2(interestDue + principalDue)
      if needed <= 1e-6 then
        -- installment already fully covered earlier by prepay; do not change outstanding again
        loan.paymentsSent = (loan.paymentsSent or 0) + 1
        loan.nextInterestPaid = 0
        loan.nextPrincipalPaid = 0
        loan.secondsUntilNextPayment = loan.secondsUntilNextPayment + PAYMENT_INTERVAL_S
        awardOrgReputation(loan.orgId, 1, loan.orgName)
        loansModified = true
      else
        local price = { money = { amount = needed } }
        if career_modules_payment and career_modules_payment.canPay(price) and career_modules_payment.pay(price, { label = string.format("Loan payment (%s)", loan.orgName or loan.orgId) }) then

          loan.principalOutstanding = r2(math.max(0, (loan.principalOutstanding or 0) - principalDue))
          loan.paymentsSent = (loan.paymentsSent or 0) + 1
          loan.amountPaid = r2((loan.amountPaid or 0) + needed)

          loan.nextInterestPaid = 0
          loan.nextPrincipalPaid = 0

          loan.secondsUntilNextPayment = loan.secondsUntilNextPayment + PAYMENT_INTERVAL_S
          awardOrgReputation(loan.orgId, 1, loan.orgName)
          loansModified = true
          -- Show payment success message
          if notificationsEnabled then
            guihooks.trigger("toastrMsg", {type="success", title="Loan Payment Made", msg="Successfully paid $" .. string.format("%.2f", needed) .. " to " .. (loan.orgName or loan.orgId)})
          end
        else
          -- Capitalize the missed interest by adding it to principal outstanding
          local currentPrincipal = loan.principalOutstanding or 0
          loan.principalOutstanding = r2(currentPrincipal + interestDue)

          local rateIncrease = (loan.rate or 0.25) * 0.1
          loan.rate = (loan.rate or 0) + rateIncrease
          loan.missed = (loan.missed or 0) + 1
          loan.secondsUntilNextPayment = loan.secondsUntilNextPayment + PAYMENT_INTERVAL_S
          awardOrgReputation(loan.orgId, -5, loan.orgName)
          loansModified = true
          -- Show payment missed message
          if notificationsEnabled then
            local capitalizedMsg = ""
            if interestDue > 0 then
              capitalizedMsg = " $" .. string.format("%.2f", interestDue) .. " interest added to principal."
            end
            guihooks.trigger("toastrMsg", {type="error", title="Loan Payment Missed", msg="Failed to pay $" .. string.format("%.2f", needed) .. " to " .. (loan.orgName or loan.orgId) .. "." .. capitalizedMsg .. " Interest rate increased by " .. string.format("%.1f", rateIncrease * 100) .. "%."})
          end
        end
      end
    end

    if (loan.principalOutstanding or 0) <= 1e-6 then
      loan.completedAt = now
      local completedId = loan.id
      local completedOrg = loan.orgName or loan.orgId
      table.remove(activeLoans, i)
      loansModified = true
      guihooks.trigger('loans:completed', { id = completedId, orgName = completedOrg })
      if notificationsEnabled then
        guihooks.trigger("toastrMsg", {type="success", title="Loan Paid Off", msg="Congratulations! Your loan with " .. completedOrg .. " has been fully paid off."})
      end
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

local function takeLoan(orgId, amount, payments, rate, uncapped)
  getLoanOrganizations()
  local org = freeroam_organizations.getOrganizations()[orgId]
  if not org then return {error = "invalid_org"} end

  local baseRate
  if uncapped then
    -- For uncapped loans, use provided rate or default to 0
    baseRate = rate or 0
  else
    -- For regular loans, check organization level and loan limits
    local level = org.reputationLevels[org.reputation.level + 2]
    if not level or not level.loans then return {error = "no_offer"} end
    local max = level.loans.max or 0
    baseRate = rate or (level.loans.rate or 0)
    local outstandingByOrg = getOutstandingPrincipalByOrg()
    local available = math.max(0, max - (outstandingByOrg[orgId] or 0))
    if amount <= 0 or amount > available then return {error = "invalid_amount", max = available} end
  end

  -- Basic amount validation for uncapped loans
  if amount <= 0 then return {error = "invalid_amount", max = 0} end

  local perPayment, total = calculatePayment(amount, baseRate, payments)
  local basePayment = r2(amount / payments)
  local loan = {
    id = makeId(),
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
  }
  table.insert(activeLoans, loan)

  if career_modules_payment then
    career_modules_payment.reward({ money = { amount = amount } }, { label = string.format("Loan received (%s)", loan.orgName) }, true)
  else
    career_modules_playerAttributes.addAttributes({money = amount}, {label = string.format("Loan received (%s)", loan.orgName)})
  end
  career_saveSystem.saveCurrent()

  if guihooks and guihooks.trigger then
    if notificationsEnabled then
      guihooks.trigger("toastrMsg", {type="info", title="Loan Approved", msg="Received $" .. string.format("%.2f", amount) .. " loan from " .. (loan.orgName or loan.orgId) .. " at " .. string.format("%.1f", (loan.rate or 0) * 100) .. "% interest over " .. payments .. " payments."})
    end
    guihooks.trigger('loans:activeUpdated')
    if career_modules_playerAttributes then
      guihooks.trigger('loans:funds', career_modules_playerAttributes.getAttributeValue('money'))
    end
  end
  return buildUiLoan(loan)
end

local function prepayLoan(loanId, amount)
  if not amount or amount <= 0 then return { error = "invalid_amount" } end
  for index, loan in ipairs(activeLoans) do
    if loan.id == loanId then
      local price = { money = { amount = amount } }
      if not (career_modules_payment and career_modules_payment.canPay(price)) then return { error = "insufficient_funds" } end
      if not career_modules_payment.pay(price, { label = string.format("Loan prepayment (%s)", loan.orgName or loan.orgId) }) then return { error = "pay_failed" } end

      local base = loan.basePayment or 0
      local interest = r2(base * (loan.rate or 0))
      local interestDue = r2(math.max(0, interest - (loan.nextInterestPaid or 0)))
      local principalDue = r2(math.max(0, base - (loan.nextPrincipalPaid or 0)))
      -- Cap prepay so it never exceeds principal + remaining interest for next installment
      local maxApplicable = r2((loan.principalOutstanding or 0) + interestDue)
      amount = math.min(amount, maxApplicable)

      local coverInterest = math.min(amount, interestDue)
      loan.nextInterestPaid = r2((loan.nextInterestPaid or 0) + coverInterest)
      local remain = r2(amount - coverInterest)

      if remain > 0 then
        local coverPrincipal = math.min(remain, principalDue)
        loan.nextPrincipalPaid = r2((loan.nextPrincipalPaid or 0) + coverPrincipal)
        
        local beforePO = loan.principalOutstanding or 0
        loan.principalOutstanding = r2(math.max(0, beforePO - coverPrincipal))
        remain = r2(remain - coverPrincipal)
      end

      if remain > 0 then
        local before = loan.principalOutstanding or 0
        loan.principalOutstanding = r2(math.max(0, before - remain))
      end

      -- track money spent now
      loan.amountPaid = r2((loan.amountPaid or 0) + amount)

      -- Show prepayment success message (if not fully paid off)
      if notificationsEnabled and guihooks and guihooks.trigger then
        guihooks.trigger("toastrMsg", {type="success", title="Prepayment Applied", msg="Applied $" .. string.format("%.2f", amount) .. " prepayment to loan with " .. (loan.orgName or loan.orgId)})
      end

      -- if fully paid off, close out immediately
      if (loan.principalOutstanding or 0) <= 1e-6 then
        loan.completedAt = os.time()
        local completedId = loan.id
        local completedOrg = loan.orgName or loan.orgId
        table.remove(activeLoans, index)
        career_saveSystem.saveCurrent()
        if guihooks and guihooks.trigger then
          guihooks.trigger('loans:completed', { id = completedId, orgName = completedOrg })
          if notificationsEnabled then
            guihooks.trigger("toastrMsg", {type="success", title="Loan Paid Off", msg="Congratulations! Your loan with " .. completedOrg .. " has been fully paid off."})
          end
          guihooks.trigger('loans:activeUpdated')
          if career_modules_playerAttributes then
            guihooks.trigger('loans:funds', career_modules_playerAttributes.getAttributeValue('money'))
          end
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
  end
  return { error = "loan_not_found" }
end

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

local function closeAllMenus()
  career_career.closeAllMenus()
end

-- expose available funds to UI
local function getAvailableFunds()
  if career_modules_playerAttributes then
    return career_modules_playerAttributes.getAttributeValue('money')
  end
  return 0
end

local function getNotificationsEnabled()
  return notificationsEnabled
end

local function setNotificationsEnabled(enabled)
  notificationsEnabled = enabled
  career_saveSystem.saveCurrent()
  if guihooks and guihooks.trigger then
    guihooks.trigger('loans:notificationsUpdated', enabled)
  end
  return notificationsEnabled
end

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
  
  -- Check if loans file exists - if it does, load it; if not, initialize for new save
  local loansFilePath = currentSavePath .. saveFile
  if FS:fileExists(loansFilePath) then
    -- Existing save - load loans
    loadLoans()
  else
    -- New save - clear and initialize
    activeLoans = {}
    notificationsEnabled = true
    log("I", "", "Loans: Initialized for new career")
  end
end

local function clearAllLoans()
  -- Clear all existing loans (useful for challenges or resets)
  local loanCount = #activeLoans
  activeLoans = {}
  notificationsEnabled = true -- Reset to default
  log("I", "", "Loans: Cleared " .. loanCount .. " loans")
  career_saveSystem.saveCurrent()
  return loanCount -- Return number of loans cleared
end

M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated
M.onUpdate = onUpdate
M.onComputerAddFunctions = onComputerAddFunctions

M.getLoanOrganizations = getLoanOrganizations
M.getLoanOffers = getLoanOffers
M.getActiveLoans = getActiveLoans
M.takeLoan = takeLoan
M.calculatePayment = calculatePayment
M.prepayLoan = prepayLoan
M.openMenuFromComputer = openMenuFromComputer
M.closeMenu = closeMenu
M.closeAllMenus = closeAllMenus
M.getAvailableFunds = getAvailableFunds
M.getNotificationsEnabled = getNotificationsEnabled
M.setNotificationsEnabled = setNotificationsEnabled
M.clearAllLoans = clearAllLoans

return M