-- Credit score from five weighted factors: payment history, utilization, credit age, new credit and mix.
-- The score sets the loan rate, maximum loan multiplier and available terms. Saved to career/rls_career/credit.json.
local M = {}

local saveStore = require("overhaul/lib/save/store")
local ensureDir = require("overhaul/lib/save/ensureDir")


-- Config ---------------------------------------------------------------------------------------------

-- One game day is 1200 sim-seconds (20 real minutes at 1x speed).
local SIM_SECONDS_PER_GAME_DAY = require("overhaul/lib/career/gameTime").SIM_SECONDS_PER_GAME_DAY
local RECENT_INQUIRY_DAYS = 5
local MAX_SCORE_HISTORY = 50
local SCORE_FLOOR = 300
local SCORE_SPAN = 550
local MISSED_PAYMENT_PENALTY = 3
local CREDIT_AGE_FULL_DAYS = 30
local INQUIRY_PENALTY = 0.25
local MIX_FULL_ORG_COUNT = 3

-- Keep weighted terms in this order so floating-point rounding stays stable.
local FACTOR_WEIGHTS = {
  paymentHistory = 0.35,
  utilization = 0.30,
  creditAge = 0.15,
  newCredit = 0.10,
  creditMix = 0.10,
}

local TIERS = {
  {min = 750, label = "Excellent", rateMultiplier = 0.80, maxMultiplier = 1.25, termsAvailable = {12, 24, 36, 48}},
  {min = 650, label = "Good",      rateMultiplier = 1.00, maxMultiplier = 1.00, termsAvailable = {12, 24, 36, 48}},
  {min = 550, label = "Fair",     rateMultiplier = 1.30, maxMultiplier = 0.70, termsAvailable = {12, 24, 36}},
  {min = 450, label = "Poor",     rateMultiplier = 1.60, maxMultiplier = 0.40, termsAvailable = {12, 24}},
  {min = 300, label = "Bad",       rateMultiplier = 2.00, maxMultiplier = 0.20, termsAvailable = {12}},
}

-- State ----------------------------------------------------------------------------------------------

local savePathFeature = nil

local accumulatedSimTime = 0

local function newCreditData()
  return {
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
end

local creditData = newCreditData()

-- Time helpers ---------------------------------------------------------------------------------------

local function getSimTime()
  return creditData.simTime or 0
end

-- Persistence ----------------------------------------------------------------------------------------

-- Resolve the declared relative file, preserving the supplied base's spelling and separators.
local function saveFilePath(currentSavePath)
  if not savePathFeature then
    savePathFeature = saveStore.bind(overhaul_career_saveSystem).feature("economy.credit", {
      owner = "overhaul_career_economy_credit",
      files = {"career/rls_career/credit.json"},
      phase = "profile",
      root = "slot",
      required = true,
    })
  end
  return currentSavePath .. "/" .. savePathFeature.path("")
end

local function loadCredit()
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  local data = jsonReadFile(saveFilePath(currentSavePath)) or {}
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

local function saveCredit(currentSavePath, writer)
  if not currentSavePath then return end
  ensureDir.parentOf(writer, saveFilePath(currentSavePath))
  overhaul_career_saveSystem.jsonWriteFileSafe(saveFilePath(currentSavePath), creditData, true)
end

local function pushScoreHistory(score)
  local history = creditData.history.scoreHistory
  table.insert(history, {timestamp = getSimTime(), score = score})
  while #history > MAX_SCORE_HISTORY do
    table.remove(history, 1)
  end
end

-- Inquiries older than the window stop counting toward new credit.
local function pruneRecentInquiries()
  local cutoff = getSimTime() - (RECENT_INQUIRY_DAYS * SIM_SECONDS_PER_GAME_DAY)
  local inquiries = creditData.history.recentInquiries
  for i = #inquiries, 1, -1 do
    if inquiries[i] < cutoff then
      table.remove(inquiries, i)
    end
  end
end

-- Factors --------------------------------------------------------------------------------------------

local function factorPaymentHistory()
  local onTime = creditData.history.onTimePayments
  local missed = creditData.history.missedPayments
  local total = onTime + missed
  if total < 1 then return 1.0 end
  local raw = math.max(0, (onTime - missed * MISSED_PAYMENT_PENALTY) / total)
  return raw
end

-- Outstanding over available, across all organizations.
local function factorUtilization()
  local outstandingTotal = 0
  local availableTotal = 0
  local outstandingByOrg = overhaul_career_economy_loans.getOutstandingPrincipalByOrg()
  for _, amount in pairs(outstandingByOrg) do
    outstandingTotal = outstandingTotal + amount
  end
  for _, org in pairs(overhaul_world_organizations.getOrganizations()) do
    local level = org.reputation and org.reputationLevels and org.reputation.level and org.reputationLevels[org.reputation.level + 2]
    if level and level.loans and level.loans.max then
      availableTotal = availableTotal + (level.loans.max or 0)
    end
  end
  if availableTotal <= 0 then return 1.0 end
  local ratio = outstandingTotal / availableTotal
  return 1.0 - math.min(1.0, ratio)
end

local function factorCreditAge()
  local firstTs = creditData.history.firstLoanTimestamp
  if not firstTs then return 0.0 end
  local elapsed = getSimTime() - firstTs
  local days = elapsed / SIM_SECONDS_PER_GAME_DAY
  return math.min(1.0, days / CREDIT_AGE_FULL_DAYS)
end

local function factorNewCredit()
  pruneRecentInquiries()
  local count = #creditData.history.recentInquiries
  return math.max(0, 1.0 - (count * INQUIRY_PENALTY))
end

local function factorCreditMix()
  local uniqueOrgs = creditData.history.uniqueOrgs or {}
  local count = 0
  for _ in pairs(uniqueOrgs) do count = count + 1 end
  return math.min(1.0, count / MIX_FULL_ORG_COUNT)
end

-- Score ----------------------------------------------------------------------------------------------

local function calculateScore()
  local paymentHistory = factorPaymentHistory()
  local utilization = factorUtilization()
  local creditAge = factorCreditAge()
  local newCredit = factorNewCredit()
  local creditMix = factorCreditMix()
  local rawScore = (paymentHistory * FACTOR_WEIGHTS.paymentHistory) + (utilization * FACTOR_WEIGHTS.utilization)
    + (creditAge * FACTOR_WEIGHTS.creditAge) + (newCredit * FACTOR_WEIGHTS.newCredit) + (creditMix * FACTOR_WEIGHTS.creditMix)
  return math.floor(SCORE_FLOOR + rawScore * SCORE_SPAN)
end

local function getTierForScore(score)
  for i = 1, #TIERS do
    if score >= TIERS[i].min then
      return TIERS[i]
    end
  end
  return TIERS[#TIERS]
end

local function buildScoreReport()
  return {
    score = creditData.score,
    simTime = getSimTime(),
    tier = getTierForScore(creditData.score),
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

local function notifyScoreUpdated()
  guihooks.trigger("credit:updated", buildScoreReport())
end

local function recalcScore()
  local newScore = calculateScore()
  local oldScore = creditData.score
  creditData.score = newScore
  if newScore ~= oldScore then
    pushScoreHistory(newScore)
    notifyScoreUpdated()
  end
  return newScore
end

-- Per-frame update -----------------------------------------------------------------------------------

local function onUpdate(dtReal, dtSim, dtRaw)
  accumulatedSimTime = accumulatedSimTime + dtSim
  creditData.simTime = accumulatedSimTime
end

-- Lifecycle ------------------------------------------------------------------------------------------

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveCredit(currentSavePath, writer)
end

local function onExtensionLoaded()
  loadCredit()
end

local function onCareerActivated()
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then return end
  local creditFilePath = saveFilePath(currentSavePath)
  if FS:fileExists(creditFilePath) then
    loadCredit()
  else
    creditData = newCreditData()
    accumulatedSimTime = 0
  end
end

-- Public API -----------------------------------------------------------------------------------------

function M.getScore()
  recalcScore()
  return buildScoreReport()
end

function M.getTier()
  recalcScore()
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
  recalcScore()
end

function M.recordMissedPayment()
  creditData.history.missedPayments = creditData.history.missedPayments + 1
  recalcScore()
end

function M.recordLoanTaken(orgId)
  if orgId then
    creditData.history.uniqueOrgs[orgId] = true
    table.insert(creditData.history.recentInquiries, getSimTime())
    pruneRecentInquiries()
  end
  if not creditData.history.firstLoanTimestamp then
    creditData.history.firstLoanTimestamp = getSimTime()
  end
  recalcScore()
end

function M.recordLoanCompleted()
  creditData.history.loansCompleted = creditData.history.loansCompleted + 1
  recalcScore()
end

function M.getFactorBreakdown()
  recalcScore()
  return {
    {name = "Payment History", value = factorPaymentHistory(), weight = FACTOR_WEIGHTS.paymentHistory, description = "On-time vs missed payments"},
    {name = "Credit Utilization", value = factorUtilization(), weight = FACTOR_WEIGHTS.utilization, description = "Outstanding vs available credit"},
    {name = "Credit Age", value = factorCreditAge(), weight = FACTOR_WEIGHTS.creditAge, description = "Time since first loan"},
    {name = "New Credit", value = factorNewCredit(), weight = FACTOR_WEIGHTS.newCredit, description = "Recent loan activity"},
    {name = "Credit Mix", value = factorCreditMix(), weight = FACTOR_WEIGHTS.creditMix, description = "Loan diversity across orgs"}
  }
end

function M.getScoreHistory()
  return creditData.history.scoreHistory or {}
end

-- Game hooks -----------------------------------------------------------------------------------------

M.onUpdate = onUpdate
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onExtensionLoaded = onExtensionLoaded
M.onCareerActivated = onCareerActivated

return M
