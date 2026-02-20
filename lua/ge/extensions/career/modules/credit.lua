local M = {}

M.dependencies = {}

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/credit.json"

-- 1 game day = 1200 sim-seconds (20 real minutes at 1x speed)
local SIM_SECONDS_PER_GAME_DAY = 1200
local RECENT_INQUIRY_DAYS = 5
local MAX_SCORE_HISTORY = 50
local accumulatedSimTime = 0

local TIERS = {
  {min = 750, label = "Excellent", rateMultiplier = 0.80, maxMultiplier = 1.25, termsAvailable = {12, 24, 36, 48}},
  {min = 650, label = "Good",      rateMultiplier = 1.00, maxMultiplier = 1.00, termsAvailable = {12, 24, 36, 48}},
  {min = 550, label = "Fair",     rateMultiplier = 1.30, maxMultiplier = 0.70, termsAvailable = {12, 24, 36}},
  {min = 450, label = "Poor",     rateMultiplier = 1.60, maxMultiplier = 0.40, termsAvailable = {12, 24}},
  {min = 300, label = "Bad",       rateMultiplier = 2.00, maxMultiplier = 0.20, termsAvailable = {12}},
}

local creditData = {
  score = 500,
  simTime = 0,
  history = {
    onTimePayments = 0,
    missedPayments = 0,
    loansCompleted = 0,
    firstLoanTimestamp = nil,
    recentInquiries = {},
    scoreHistory = {},
    uniqueOrgs = {}
  }
}

local function getSimTime()
  return creditData.simTime or 0
end

local function ensureSaveDir(currentSavePath)
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function loadCredit()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  local data = jsonReadFile(currentSavePath .. saveFile) or {}
  if data.score then
    creditData.score = data.score
  end
  creditData.simTime = data.simTime or 0
  accumulatedSimTime = creditData.simTime
  if data.history then
    creditData.history.onTimePayments = data.history.onTimePayments or 0
    creditData.history.missedPayments = data.history.missedPayments or 0
    creditData.history.loansCompleted = data.history.loansCompleted or 0
    creditData.history.firstLoanTimestamp = data.history.firstLoanTimestamp
    creditData.history.recentInquiries = data.history.recentInquiries or {}
    creditData.history.scoreHistory = data.history.scoreHistory or {}
    creditData.history.uniqueOrgs = data.history.uniqueOrgs or {}
  end
end

local function saveCredit(currentSavePath)
  if not currentSavePath then
    local _, p = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = p
    if not currentSavePath then return end
  end
  ensureSaveDir(currentSavePath)
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, creditData, true)
end

local function pushScoreHistory(score)
  local history = creditData.history.scoreHistory
  table.insert(history, {timestamp = getSimTime(), score = score})
  while #history > MAX_SCORE_HISTORY do
    table.remove(history, 1)
  end
end

-- Factor 1: Payment History (35%)
local function factorPaymentHistory()
  local onTime = creditData.history.onTimePayments
  local missed = creditData.history.missedPayments
  local total = onTime + missed
  if total < 1 then return 1.0 end
  local raw = math.max(0, (onTime - missed * 3) / total)
  return raw
end

-- Factor 2: Utilization (30%) — outstanding / available across all orgs
local function factorUtilization()
  local outstandingTotal = 0
  local availableTotal = 0
  if career_modules_loans and career_modules_loans.getOutstandingPrincipalByOrg then
    local outstandingByOrg = career_modules_loans.getOutstandingPrincipalByOrg()
    for orgId, amt in pairs(outstandingByOrg) do
      outstandingTotal = outstandingTotal + amt
    end
  end
  for orgId, org in pairs(freeroam_organizations.getOrganizations()) do
    local level = org.reputation and org.reputationLevels and org.reputation.level and org.reputationLevels[org.reputation.level + 2]
    if level and level.loans and level.loans.max then
      availableTotal = availableTotal + (level.loans.max or 0)
    end
  end
  if availableTotal <= 0 then return 1.0 end
  local ratio = outstandingTotal / availableTotal
  return 1.0 - math.min(1.0, ratio)
end

-- Factor 3: Credit Age (15%)
local function factorCreditAge()
  local firstTs = creditData.history.firstLoanTimestamp
  if not firstTs then return 0.0 end
  local elapsed = getSimTime() - firstTs
  local days = elapsed / SIM_SECONDS_PER_GAME_DAY
  return math.min(1.0, days / 30)
end

-- Factor 4: New Credit (10%)
local function factorNewCredit()
  local cutoff = getSimTime() - (RECENT_INQUIRY_DAYS * SIM_SECONDS_PER_GAME_DAY)
  -- Prune expired inquiries
  for i = #creditData.history.recentInquiries, 1, -1 do
    if creditData.history.recentInquiries[i] < cutoff then
      table.remove(creditData.history.recentInquiries, i)
    end
  end
  local count = #creditData.history.recentInquiries
  return math.max(0, 1.0 - (count * 0.25))
end

-- Factor 5: Credit Mix (10%)
local function factorCreditMix()
  local uniqueOrgs = creditData.history.uniqueOrgs or {}
  local count = 0
  for _ in pairs(uniqueOrgs) do count = count + 1 end
  return math.min(1.0, count / 3)
end

local function calculateScore()
  local f1 = factorPaymentHistory()
  local f2 = factorUtilization()
  local f3 = factorCreditAge()
  local f4 = factorNewCredit()
  local f5 = factorCreditMix()
  local rawScore = (f1 * 0.35) + (f2 * 0.30) + (f3 * 0.15) + (f4 * 0.10) + (f5 * 0.10)
  return math.floor(300 + rawScore * 550)
end

local function getTierForScore(score)
  for i = 1, #TIERS do
    if score >= TIERS[i].min then
      return TIERS[i]
    end
  end
  return TIERS[#TIERS]
end

local function notifyScoreUpdated()
  if not (guihooks and guihooks.trigger) then return end
  local tier = getTierForScore(creditData.score)
  guihooks.trigger("credit:updated", {
    score = creditData.score,
    simTime = getSimTime(),
    tier = tier,
    factors = {
      paymentHistory = factorPaymentHistory(),
      utilization = factorUtilization(),
      creditAge = factorCreditAge(),
      newCredit = factorNewCredit(),
      creditMix = factorCreditMix()
    },
    history = creditData.history
  })
end

local function recalcAndSave()
  local newScore = calculateScore()
  local oldScore = creditData.score
  creditData.score = newScore
  if newScore ~= oldScore then
    pushScoreHistory(newScore)
    notifyScoreUpdated()
  end
  saveCredit()
  return newScore
end

function M.getScore()
  recalcAndSave()
  local tier = getTierForScore(creditData.score)
  return {
    score = creditData.score,
    simTime = getSimTime(),
    tier = tier,
    factors = {
      paymentHistory = factorPaymentHistory(),
      utilization = factorUtilization(),
      creditAge = factorCreditAge(),
      newCredit = factorNewCredit(),
      creditMix = factorCreditMix()
    },
    history = creditData.history
  }
end

function M.getTier()
  recalcAndSave()
  return getTierForScore(creditData.score)
end

function M.getRateMultiplier()
  local tier = M.getTier()
  return tier.rateMultiplier
end

function M.getMaxMultiplier()
  local tier = M.getTier()
  return tier.maxMultiplier
end

function M.getAvailableTerms()
  local tier = M.getTier()
  return tier.termsAvailable
end

function M.recordOnTimePayment()
  creditData.history.onTimePayments = creditData.history.onTimePayments + 1
  recalcAndSave()
end

function M.recordMissedPayment()
  creditData.history.missedPayments = creditData.history.missedPayments + 1
  recalcAndSave()
end

function M.recordLoanTaken(orgId)
  if orgId then
    creditData.history.uniqueOrgs[orgId] = true
    table.insert(creditData.history.recentInquiries, getSimTime())
    local cutoff = getSimTime() - (RECENT_INQUIRY_DAYS * SIM_SECONDS_PER_GAME_DAY)
    for i = #creditData.history.recentInquiries, 1, -1 do
      if creditData.history.recentInquiries[i] < cutoff then
        table.remove(creditData.history.recentInquiries, i)
      end
    end
  end
  if not creditData.history.firstLoanTimestamp then
    creditData.history.firstLoanTimestamp = getSimTime()
  end
  recalcAndSave()
end

function M.recordLoanCompleted()
  creditData.history.loansCompleted = creditData.history.loansCompleted + 1
  recalcAndSave()
end

function M.getFactorBreakdown()
  recalcAndSave()
  return {
    {name = "Payment History", value = factorPaymentHistory(), weight = 0.35, description = "On-time vs missed payments"},
    {name = "Credit Utilization", value = factorUtilization(), weight = 0.30, description = "Outstanding vs available credit"},
    {name = "Credit Age", value = factorCreditAge(), weight = 0.15, description = "Time since first loan"},
    {name = "New Credit", value = factorNewCredit(), weight = 0.10, description = "Recent loan activity"},
    {name = "Credit Mix", value = factorCreditMix(), weight = 0.10, description = "Loan diversity across orgs"}
  }
end

function M.getScoreHistory()
  return creditData.history.scoreHistory or {}
end

local function onSaveCurrentSaveSlot(currentSavePath)
  saveCredit(currentSavePath)
end

local function onExtensionLoaded()
  loadCredit()
end

local function onCareerActivated()
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  local creditFilePath = currentSavePath .. saveFile
  if FS:fileExists(creditFilePath) then
    loadCredit()
  else
    creditData = {
      score = 500,
      simTime = 0,
      history = {
        onTimePayments = 0,
        missedPayments = 0,
        loansCompleted = 0,
        firstLoanTimestamp = nil,
        recentInquiries = {},
        scoreHistory = {},
        uniqueOrgs = {}
      }
    }
    saveCredit(currentSavePath)
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  accumulatedSimTime = accumulatedSimTime + dtSim
  creditData.simTime = accumulatedSimTime
end

M.onUpdate = onUpdate
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated

return M
