-- Racing team operating costs, entry fees, driver payouts and vehicle spending.
-- Read save helpers, cost timers, entry/refund operations, payout shares and finance queries.
local businessSaveState = require("overhaul/lib/business/saveState")
local M = {}

-- Config ------------------------------------------------------------------------------------------

local businessType = "racingTeam"
local PAYMENT_INTERVAL = 1800
local SHOP_OVERHEAD_COST_SCALE = 0.15
local SIM_STEP_INTERVAL = 1

-- State -------------------------------------------------------------------------------------------

local operatingCostTimers = {}
local simStepAccumulator = 0

-- Shared helpers ----------------------------------------------------------------------------------

local function normalizeBusinessId(businessId)
  return tonumber(businessId) or businessId
end

local function scaleShopOverhead(amount)
  return math.max(0, math.floor((tonumber(amount) or 0) * SHOP_OVERHEAD_COST_SCALE + 0.5))
end

local function debitBusinessAccount(businessId, amount, reason, description, allowNegativeBalance, category)
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then
    return true
  end
  local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
  if not account then
    return false
  end
  local accountId = account.id or account.accountId
  if not accountId then
    return false
  end
  return overhaul_career_economy_bank.removeFunds(accountId, amount, reason or "Racing team expense", description or "", allowNegativeBalance == true, require("overhaul/lib/finance/metadata").tag(nil, category or "business"))
end

-- Operating cost timers and their save file -------------------------------------------------------

local function getTimerFilePath(businessId)
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return nil
  end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not savePath or not businessId then
    return nil
  end
  return savePath .. "/career/rls_career/businesses/" .. tostring(businessId) .. "/racingTeamShopOperatingCost.json"
end

local function loadTimerFromDisk(businessId)
  businessId = normalizeBusinessId(businessId)
  local path = getTimerFilePath(businessId)
  if not path or not FS:fileExists(path) then
    return { elapsed = 0, lastChargeTime = nil }
  end
  local data = jsonReadFile(path) or {}
  return {
    elapsed = tonumber(data.elapsed) or 0,
    lastChargeTime = data.lastChargeTime,
  }
end

local function saveTimerToDisk(businessId, currentSavePath, writer)
  businessId = normalizeBusinessId(businessId)
  if not businessId or not currentSavePath then
    return
  end
  local state = operatingCostTimers[businessId]
  if not state then
    return
  end
  local path = businessSaveState.businessFilePath(businessId, "racingTeamShopOperatingCost.json", currentSavePath .. "")
  local dirPath = string.match(path, "^(.*)/[^/]+$")
  if dirPath and not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end
  overhaul_career_saveSystem.jsonWriteFileSafe(path, { elapsed = state.elapsed, lastChargeTime = state.lastChargeTime }, true)
end

local function loadOperatingCostTimer(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return { elapsed = 0, lastChargeTime = nil }
  end
  if operatingCostTimers[businessId] == nil then
    operatingCostTimers[businessId] = loadTimerFromDisk(businessId)
  end
  return operatingCostTimers[businessId] or { elapsed = 0, lastChargeTime = nil }
end

function M.saveOperatingCostTimers(currentSavePath, businessIds, writer)
  if not currentSavePath then
    return
  end
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  for _, bid in ipairs(businessIds or {}) do
    loadOperatingCostTimer(bid)
  end
  for bid, _ in pairs(operatingCostTimers) do
    saveTimerToDisk(bid, currentSavePath, writer)
  end
end

function M.clearOperatingCostTimer(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then return false end
  operatingCostTimers[businessId] = { elapsed = 0, lastChargeTime = nil }
  return true
end

function M.onCareerActivated()
  operatingCostTimers = {}
end

-- Shop operating costs ----------------------------------------------------------------------------

local function countActiveRacingDrivers(businessId)
  local businessManager = overhaul_career_business_manager
  local obj = businessManager.getBusinessObject("racingTeam")
  if not obj or not obj.getTechsForBusiness then
    return 0
  end
  local techs = obj.getTechsForBusiness(businessId) or {}
  local count = 0
  for _, tech in ipairs(techs) do
    if not tech.fired then
      count = count + 1
    end
  end
  return count
end

local function getShopOperatingCosts(businessId)
  if not businessId then
    local base = scaleShopOverhead(5000)
    return {
      baseLift = base,
      additionalLifts = 0,
      techs = 0,
      manager = 0,
      generalManager = 0,
      total = base,
    }
  end

  local baseLift = scaleShopOverhead(5000)
  local additionalLifts = 0
  local managerCost = 0
  local generalManagerCost = 0

  do
    local treeId = "team-operations"

    local managerLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, treeId, "manager") or 0
    if managerLevel > 0 then
      managerCost = scaleShopOverhead(5000)
    end
    local dynoLevel = overhaul_career_business_skillTree.getNodeProgress(businessId, "qol", "dyno") or 0
    if dynoLevel > 0 then
      generalManagerCost = scaleShopOverhead(25000)
    end
  end

  local techCount = countActiveRacingDrivers(businessId)
  local techsCost = techCount * scaleShopOverhead(2500)

  local additionalLiftsCost = additionalLifts * scaleShopOverhead(5000)
  local total = baseLift + additionalLiftsCost + techsCost + managerCost + generalManagerCost

  return {
    baseLift = baseLift,
    additionalLifts = additionalLifts,
    additionalLiftsCost = additionalLiftsCost,
    techs = techCount,
    techsCost = techsCost,
    manager = managerCost > 0 and 1 or 0,
    managerCost = managerCost,
    generalManager = generalManagerCost > 0 and 1 or 0,
    generalManagerCost = generalManagerCost,
    total = total,
    maxCost = scaleShopOverhead(55000),
  }
end

local function processOperatingCosts(businessId, dtSim)
  if not businessId or dtSim <= 0 then
    return false
  end
  local operatingCosts = getShopOperatingCosts(businessId)
  if operatingCosts.total <= 0 then
    return false
  end

  local timerState = loadOperatingCostTimer(businessId)
  timerState.elapsed = timerState.elapsed + dtSim

  local charged = false
  if timerState.elapsed >= PAYMENT_INTERVAL then
    local currentTime = os.time()
    local success = debitBusinessAccount(businessId, operatingCosts.total, "Operating Costs",
      string.format(
        "Shop overhead: Base $%d, Bays $%d, Team $%d, Manager $%d, Ops $%d",
        operatingCosts.baseLift,
        operatingCosts.additionalLiftsCost,
        operatingCosts.techsCost,
        operatingCosts.managerCost,
        operatingCosts.generalManagerCost
      ), true)

    if success then
      timerState.elapsed = math.max(0, timerState.elapsed - PAYMENT_INTERVAL)
      timerState.lastChargeTime = currentTime
      charged = true
    else
      timerState.elapsed = 0
    end
  end

  operatingCostTimers[businessId] = timerState
  return charged
end

-- Sim step ----------------------------------------------------------------------------------------

function M.onCareerSimStep(dtSim)
  if not overhaul_career_career or not overhaul_career_career.isActive() then
    return
  end
  if not dtSim or dtSim <= 0 then
    return
  end
  simStepAccumulator = simStepAccumulator + dtSim
  if simStepAccumulator < SIM_STEP_INTERVAL then
    return
  end
  local elapsed = simStepAccumulator
  simStepAccumulator = 0
  local businessManager = overhaul_career_business_manager
  local purchased = businessManager.getPurchasedBusinesses("racingTeam")
  if not purchased then
    return
  end
  for bid, _ in pairs(purchased) do
    processOperatingCosts(bid, elapsed)
  end
end

function M.onOverhaulCareerSimStep(dtSim)
  -- The team owns the ordering while loaded; its absence must not stop operating costs.
  local racingTeamModule = overhaul_career_business_racingTeam_racingTeam
  if racingTeamModule then return end
  if M.onCareerSimStep then M.onCareerSimStep(dtSim) end
end

-- Entry fees and driver cut -----------------------------------------------------------------------

local function leagueTierIndex(leagueIdStr)
  local tier = string.match(tostring(leagueIdStr or ""), "^league(%d+)$")
  if tier then
    return math.max(1, tonumber(tier) or 1)
  end
  return 1
end

function M.computeRaceEntranceFee(offer, leagueIdStr)
  local branch = "stock"
  if type(offer) == "table" and offer.hpBracketBranch then
    branch = string.lower(tostring(offer.hpBracketBranch))
  end
  local base = 350
  if branch == "modified" then
    base = 700
  elseif branch == "super" then
    base = 1200
  elseif branch == "open" then
    base = 700
  end
  local tier = leagueTierIndex(leagueIdStr)
  local mult = 1 + 0.2 * math.max(0, tier - 1)
  return math.floor(base * mult + 0.5)
end

function M.tryDebitRaceEntranceFee(businessId, offer, leagueIdStr)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  local fee = M.computeRaceEntranceFee(offer, leagueIdStr)
  if fee <= 0 then
    return true
  end
  local label = (type(offer) == "table" and (offer.raceLabel or offer.raceName)) or "Race"
  local cls = (type(offer) == "table" and offer.hpBracketBranch) and tostring(offer.hpBracketBranch) or "class"
  return debitBusinessAccount(
    businessId,
    fee,
    "Race entry fee",
    string.format("Entry — %s (%s)", label, cls)
  )
end

function M.refundRaceEntranceFee(businessId, offer, leagueIdStr)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return
  end
  local fee = M.computeRaceEntranceFee(offer, leagueIdStr)
  if fee <= 0 then
    return
  end
  local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
  local accountId = account and (account.id or account.accountId)
  if not accountId then
    return
  end
  overhaul_career_economy_bank.rewardToAccount({
    money = { amount = fee, canBeNegative = false },
  }, accountId, "Race entry fee (refund)", "Race start failed — entry fee returned", {category = "refund"})
end

local function driverCutBlendTFromXp(xp)
  local x = math.max(0, math.floor(tonumber(xp) or 0))
  if x >= 8000 then
    return 1
  end
  if x >= 4000 then
    return 0.75
  end
  if x >= 1500 then
    return 0.5
  end
  if x >= 400 then
    return 0.25
  end
  return 0
end

local function driverCutPercentFromRacingXp(xp)
  return 35 + 25 * driverCutBlendTFromXp(xp)
end

function M.applyDriverCutAfterPayout(businessId, grossAmount, opts)
  businessId = normalizeBusinessId(businessId)
  opts = opts or {}
  grossAmount = math.floor(tonumber(grossAmount) or 0)
  if not businessId or grossAmount <= 0 then
    return
  end
  local pct = driverCutPercentFromRacingXp(tonumber(opts.racingSkillXp) or 0)
  local cut = math.floor(grossAmount * pct / 100 + 0.5)
  if cut <= 0 then
    return
  end
  local driverName = type(opts.driverName) == "string" and opts.driverName ~= "" and opts.driverName or "Driver"
  debitBusinessAccount(
    businessId,
    cut,
    "Driver cut",
    string.format("Driver share (%d%%) — %s", pct, driverName),
    true
  )
end

-- Finance data for the business computer ----------------------------------------------------------


-- Reads the business bank account first, so the balance and transactions come before the loans.
local function readAccountSummary(businessId)
  local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
  local summary = {account = account, id = nil, balance = 0, transactions = {}}
  if account then
    summary.id = account.id or account.accountId
    if summary.id then
      summary.balance = overhaul_career_economy_bank.getAccountBalance(summary.id) or 0
      summary.transactions = overhaul_career_economy_bank.getAccountTransactions(summary.id, 100) or {}
    end
  end
  return summary
end

local function loansOfAccount(accountId)
  local loans = {}
  if not accountId then
    return loans
  end
  for _, loan in ipairs(overhaul_career_economy_loans.getActiveLoans() or {}) do
    if loan.businessAccountId == accountId then
      table.insert(loans, loan)
    end
  end
  return loans
end

local function operatingCostsView(shop)
  return {
    total = shop.total,
    baseLift = shop.baseLift,
    additionalLifts = shop.additionalLifts,
    additionalLiftsCost = shop.additionalLiftsCost,
    techs = shop.techs,
    techsCost = shop.techsCost,
    manager = shop.manager,
    managerCost = shop.managerCost,
    generalManager = shop.generalManager,
    generalManagerCost = shop.generalManagerCost,
    maxCost = shop.maxCost,
    driverCutPercentMin = 35,
    driverCutPercentMax = 60,
    driverCutNote = "35%–60% of gross payout by driver skill (debited on deposit; see ledger).",
    raceEntryNote = "Due when you schedule a race (class & league; see ledger).",
  }
end

-- Only a team with a running shop has a payment timer to show.
local function operatingCostTimerView(businessId, shop)
  if shop.total <= 0 then
    return nil
  end
  local timerState = loadOperatingCostTimer(businessId)
  return {
    elapsed = timerState.elapsed,
    lastChargeTime = timerState.lastChargeTime,
    paymentInterval = PAYMENT_INTERVAL,
    remainingTime = PAYMENT_INTERVAL - (timerState.elapsed % PAYMENT_INTERVAL),
  }
end

local function getRacingTeamFinancesData(businessId)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return nil
  end
  local summary = readAccountSummary(businessId)
  local loans = loansOfAccount(summary.id)
  local shop = getShopOperatingCosts(businessId)
  return {
    operatingCosts = operatingCostsView(shop),
    account = {
      id = summary.id,
      balance = summary.balance,
      name = summary.account and summary.account.name or nil,
    },
    transactions = summary.transactions,
    loans = loans,
    operatingCostTimer = operatingCostTimerView(businessId, shop),
  }
end

local function triggerFinancesData(payload)
  do
    guihooks.trigger("businessComputer:onFinancesData", payload)
  end
end

function M.requestFinancesData(businessId)
  if not businessId then
    triggerFinancesData({ success = false, error = "Missing businessId" })
    return
  end
  local financesData = getRacingTeamFinancesData(businessId)
  if not financesData then
    triggerFinancesData({ success = false, error = "Failed to get finances data", businessId = businessId })
    return
  end
  triggerFinancesData({
    success = true,
    businessId = businessId,
    finances = financesData,
    simulationTime = os.time(),
  })
end

-- Vehicle paint and fuel debits -------------------------------------------------------------------

local function tryDebitFleetVehicleCost(businessId, amount, reason, description, category)
  businessId = normalizeBusinessId(businessId)
  if not businessId then
    return false
  end
  amount = math.floor(tonumber(amount) or 0)
  if amount <= 0 then
    return true
  end
  return debitBusinessAccount(businessId, amount, reason, description, false, category)
end

function M.tryDebitVehiclePaintCost(businessId, amount, description)
  return tryDebitFleetVehicleCost(businessId, amount, "Vehicle painting", description or "Repainted a fleet vehicle", "purchase")
end

function M.tryDebitVehicleFuelCost(businessId, amount, description)
  return tryDebitFleetVehicleCost(businessId, amount, "Fuel", description or "Refueled a fleet vehicle", "fuel")
end

M.getRacingTeamFinancesData = getRacingTeamFinancesData
M.getShopOperatingCostsForDebug = getShopOperatingCosts

return M
