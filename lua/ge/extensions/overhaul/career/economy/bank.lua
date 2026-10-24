-- Personal and business bank accounts, delayed transfers, savings interest and account history.
-- Map: ledger bindings, persistence, account and transfer workflows, queries, interest and public API.
local M = {}

local saveStore = require("overhaul/lib/save/store")
local ensureDir = require("overhaul/lib/save/ensureDir")

local ledgerAuthority = require("overhaul/lib/ledger/authority")
local moneyCategories = require("overhaul/lib/ledger/categories")

-- Config ------------------------------------------------------------------------------------------


local PENDING_TRANSFER_DURATION = 5 * 60
local SAVINGS_PAYOUT_INTERVAL_SEC = 30 * 60
local SAVINGS_RATE_PER_SEC = 0.05 / (6 * 3600)
local UPDATE_INTERVAL_S = 5
local SAVINGS_UPDATE_INTERVAL_S = 1
local TRANSFER = {category = "transfer"}

-- State -------------------------------------------------------------------------------------------

local savePathFeature = nil

local accounts = {}
local pendingTransfers = {}
local transactions = {}
local isLoadingData = false
-- Ledger handles prevent a bank operation from posting through another owner's account.
local ledgerHandles = {}
local updateTimer = 0
local savingsUpdateTimer = 0

-- Ledger ------------------------------------------------------------------------------------------

local function ledgerName(accountId)
  return "bank:" .. tostring(accountId)
end

-- The balance change primitive: strict reproduces sites that had no nil-balance fallback.
local function bindLedgerAccount(accountId)
  ledgerHandles[accountId] = ledgerAuthority.bind(ledgerName(accountId), {
    get = function()
      local account = accounts[accountId]
      return (account and account.balance) or 0
    end,
    apply = function(delta, op, legIndex)
      local account = accounts[accountId]
      if op.legs[legIndex].strict then
        account.balance = account.balance + delta
      else
        account.balance = (account.balance or 0) + delta
      end
    end,
  })
end

local function unbindLedgerAccount(accountId)
  ledgerAuthority.unbind(ledgerHandles[accountId])
  ledgerHandles[accountId] = nil
end

local function changeBalance(account, delta, strict)
  if not ledgerHandles[account.id] then bindLedgerAccount(account.id) end
  ledgerAuthority.post(ledgerHandles[account.id], delta, nil, strict)
end

-- Transaction history -----------------------------------------------------------------------------

-- Appends one entry to an account's history, creating the list on first use.
local function appendTransaction(accountId, entry)
  if not isLoadingData and not entry.finance then
    entry.finance = require("overhaul/lib/finance/metadata").capture({category = entry.category}, entry.timestamp, entry.amount)
  end
  if not transactions[accountId] then
    transactions[accountId] = {}
  end
  table.insert(transactions[accountId], entry)
end

-- Savings interest -------------------------------------------------------------------------------

local function triggerAccountUpdate(accountId)
  if not accountId or not accounts[accountId] then
    return
  end
  if not overhaul_career_career.isActive() then
    return
  end
  if isLoadingData then
    return
  end

  local account = accounts[accountId]

  local success, err = pcall(function()
    local accountData = {
      accountId = accountId,
      balance = account.balance or 0,
      accountType = account.type or "unknown",
      businessType = account.businessType,
      businessId = account.businessId,
      name = account.name or "Account"
    }

    extensions.hook("onOverhaulAccountUpdate", accountId, accountData)
    guihooks.trigger("bank:onOverhaulAccountUpdate", accountData)
  end)

  if not success then
    log("E", "bank", "triggerAccountUpdate failed: " .. tostring(err))
  end
end

local function isSavingsPersonal(account)
  return account and (account.type or "") == "personal" and account.accountType == "savings"
end

local function migrateSavingsInterestOnLoad(acc)
  if not isSavingsPersonal(acc) then
    return
  end
  acc.accruedInterest = acc.accruedInterest or 0
  acc.sinceLastPayout = acc.sinceLastPayout or 0
  acc.sinceSegmentStart = acc.sinceSegmentStart or 0
  acc.segmentBalance = acc.segmentBalance or acc.balance or 0
end

-- Accrues interest for the open segment (time since the balance last changed), then starts a new one.
local function closeOpenSegment(account)
  if not isSavingsPersonal(account) then
    return
  end
  local dt = math.max(0, account.sinceSegmentStart or 0)
  local segBal = account.segmentBalance or account.balance or 0
  if dt > 0 then
    account.accruedInterest = (account.accruedInterest or 0) + segBal * SAVINGS_RATE_PER_SEC * dt
  end
  account.sinceSegmentStart = 0
  account.segmentBalance = account.balance or 0
end

local function syncSavingsSegmentAfterMutation(account)
  if isSavingsPersonal(account) then
    account.segmentBalance = account.balance or 0
  end
end

-- Pays out whole cents of accrued interest and keeps the fraction for the next payout.
local function runSavingsPayoutCycle(account)
  if not isSavingsPersonal(account) then
    return
  end
  closeOpenSegment(account)
  local raw = account.accruedInterest or 0
  local paid = math.floor(raw * 100 + 0.5) / 100
  changeBalance(account, paid)
  account.accruedInterest = raw - paid
  if paid > 0 then
    appendTransaction(account.id, {
      id = Engine.generateUUID(),
      accountId = account.id,
      label = "Interest",
      amount = paid,
      timestamp = os.time(),
      description = "Savings interest payout",
      category = "interest"
    })
  end
  account.segmentBalance = account.balance or 0
  account.sinceSegmentStart = 0
  account.sinceLastPayout = (account.sinceLastPayout or 0) - SAVINGS_PAYOUT_INTERVAL_SEC
  if not isLoadingData then
    triggerAccountUpdate(account.id)
  end
end

local function applySavingsDtSim(dtSim)
  if not overhaul_career_career.isActive() or isLoadingData or not dtSim or dtSim <= 0 then
    return
  end
  for _, account in pairs(accounts) do
    if isSavingsPersonal(account) then
      account.sinceLastPayout = (account.sinceLastPayout or 0) + dtSim
      account.sinceSegmentStart = (account.sinceSegmentStart or 0) + dtSim
      while (account.sinceLastPayout or 0) >= SAVINGS_PAYOUT_INTERVAL_SEC do
        runSavingsPayoutCycle(account)
      end
    end
  end
end

local function foldAllSavingsForSave()
  for _, account in pairs(accounts) do
    if isSavingsPersonal(account) then
      closeOpenSegment(account)
    end
  end
end

-- Pending transfers -------------------------------------------------------------------------------

-- Completes transfers whose delay has passed, and drops transfers that no longer have both accounts.
local function processPendingTransfers()
  if not overhaul_career_career.isActive() then
    return
  end

  local currentTime = os.time()

  for id, transfer in pairs(pendingTransfers) do
    if not transfer or not transfer.completesAt or not transfer.fromAccountId or not transfer.toAccountId then
      pendingTransfers[id] = nil
    elseif currentTime >= transfer.completesAt then
      local fromAccount = accounts[transfer.fromAccountId]
      local toAccount = accounts[transfer.toAccountId]

      if fromAccount and toAccount then
        local transferAmount = transfer.amount or 0
        closeOpenSegment(toAccount)
        changeBalance(toAccount, transferAmount)
        syncSavingsSegmentAfterMutation(toAccount)

        appendTransaction(transfer.toAccountId, {
          id = Engine.generateUUID(),
          accountId = transfer.toAccountId,
          label = "Transfer In",
          amount = transferAmount,
          timestamp = transfer.completesAt,
          description = "Transfer from " .. (fromAccount.name or "Account"),
          relatedAccountId = transfer.fromAccountId,
          category = "transfer"
        })

        pendingTransfers[id] = nil
        triggerAccountUpdate(transfer.toAccountId)
      else
        pendingTransfers[id] = nil
      end
    end
  end
end

-- Persistence -------------------------------------------------------------------------------------

-- Resolve the declared relative file, preserving the supplied base's spelling and separators.
local function saveFilePath(currentSavePath)
  if not savePathFeature then
    savePathFeature = saveStore.bind(overhaul_career_saveSystem).feature("economy.bank", {
      owner = "overhaul_career_economy_bank",
      files = {"career/rls_career/bank.json"},
      phase = "profile",
      root = "slot",
      required = true,
    })
  end
  return currentSavePath .. "/" .. savePathFeature.path("")
end

local function loadBankData()
  if not overhaul_career_career.isActive() then
    return
  end
  isLoadingData = true
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  if not currentSavePath then
    isLoadingData = false
    return
  end

  local data = jsonReadFile(saveFilePath(currentSavePath)) or {}
  accounts = {}
  pendingTransfers = {}
  transactions = {}

  if data.accounts then
    for _, acc in ipairs(data.accounts) do
      accounts[acc.id] = acc
      migrateSavingsInterestOnLoad(acc)
    end
  end
  for accountId in pairs(ledgerHandles) do ledgerAuthority.unbind(ledgerHandles[accountId]) end
  ledgerHandles = {}
  ledgerAuthority.unbindPrefix("bank:")
  for accountId in pairs(accounts) do
    bindLedgerAccount(accountId)
  end

  if data.pendingTransfers then
    for _, transfer in ipairs(data.pendingTransfers) do
      pendingTransfers[transfer.id] = transfer
    end
  end

  if data.transactions then
    for _, trans in ipairs(data.transactions) do
      -- Older saves stored a type; the sign now lives in the amount itself.
      if trans.type then
        local transType = trans.type
        local amount = trans.amount or 0

        if transType == "deposit" or transType == "transfer_in" or transType == "reward" then
          trans.amount = math.abs(amount)
        elseif transType == "withdraw" or transType == "transfer_out" or transType == "payment" or transType == "penalty" or transType == "transfer_cancelled" then
          trans.amount = -math.abs(amount)
        end

        trans.type = nil
      end

      appendTransaction(trans.accountId, trans)
    end
  end

  isLoadingData = false
end

local function saveBankData(currentSavePath, forceSave, writer)
  if not overhaul_career_career.isActive() then
    return
  end
  if isLoadingData and not forceSave then
    return
  end

  if not currentSavePath then
    local _, path = overhaul_career_saveSystem.getCurrentProfile()
    currentSavePath = path
  end
  if not currentSavePath then
    return
  end

  ensureDir.parentOf(writer, saveFilePath(currentSavePath))

  local accountsArray = {}
  for _, acc in pairs(accounts) do
    table.insert(accountsArray, acc)
  end
  -- Hash iteration must not choose the order of saved JSON arrays.
  table.sort(accountsArray, function(a, b) return a.id < b.id end)

  local transfersArray = {}
  for _, transfer in pairs(pendingTransfers) do
    table.insert(transfersArray, transfer)
  end
  table.sort(transfersArray, function(a, b) return a.id < b.id end)

  local transactionsArray = {}
  local transactionAccountIds = {}
  for accountId in pairs(transactions) do transactionAccountIds[#transactionAccountIds + 1] = accountId end
  table.sort(transactionAccountIds)
  for _, accountId in ipairs(transactionAccountIds) do
    -- Keep each account's history in insertion order, including timestamp ties.
    for _, trans in ipairs(transactions[accountId]) do
      table.insert(transactionsArray, trans)
    end
  end

  local data = {
    accounts = accountsArray,
    pendingTransfers = transfersArray,
    transactions = transactionsArray
  }

  overhaul_career_saveSystem.jsonWriteFileSafe(saveFilePath(currentSavePath), data, true)
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not currentSavePath then
    return
  end
  local success, err = pcall(function()
    foldAllSavingsForSave()
    saveBankData(currentSavePath, true, writer)
  end)
  if not success then
    log("E", "bank", "onOverhaulSaveCurrentProfile failed: " .. tostring(err))
  end
end

-- Accounts ----------------------------------------------------------------------------------------

local function initialDepositPrice(amount)
  return {money = {amount = amount, canBeNegative = false}}
end

local function payInitialDeposit(amount)
  if amount <= 0 then return true end
  if not overhaul_career_economy_payment.canPay(initialDepositPrice(amount)) then return false end
  overhaul_career_economy_payment.pay(initialDepositPrice(amount), {label = "Bank deposit", category = "transfer"})
  return true
end

local function createAccount(name, accountType, initialDeposit)
  if not name or name == "" then
    return nil
  end
  if accountType ~= "savings" and accountType ~= "checking" then
    accountType = "checking"
  end

  local walletBalance = overhaul_career_economy_playerAttributes.getAttributeValue("money") or 0
  initialDeposit = initialDeposit or 0
  initialDeposit = math.max(0, math.min(initialDeposit, walletBalance))

  if not payInitialDeposit(initialDeposit) then return nil end

  local accountId = Engine.generateUUID()
  local account = {
    id = accountId,
    name = name,
    type = "personal",
    accountType = accountType,
    balance = initialDeposit,
    createdAt = os.time()
  }

  if accountType == "savings" then
    account.accruedInterest = 0
    account.sinceLastPayout = 0
    account.sinceSegmentStart = 0
    account.segmentBalance = initialDeposit
  end

  accounts[accountId] = account
  bindLedgerAccount(accountId)

  if initialDeposit > 0 then
    appendTransaction(accountId, {
      id = Engine.generateUUID(),
      accountId = accountId,
      label = "Deposit",
      amount = initialDeposit,
      timestamp = os.time(),
      description = "Initial deposit",
      category = "transfer"
    })
  end

  if not isLoadingData then
    triggerAccountUpdate(accountId)
  end

  return accountId
end

local function createBusinessAccount(businessType, businessId, businessName)
  if not businessType or not businessId then
    return nil
  end

  local accountId = "business_" .. tostring(businessType) .. "_" .. tostring(businessId)

  if accounts[accountId] then
    return accountId
  end

  local account = {
    id = accountId,
    name = (businessName and tostring(businessName) or (tostring(businessType) .. " " .. tostring(businessId))) ..
      " Account",
    type = "business",
    businessType = businessType,
    businessId = businessId,
    balance = 0,
    createdAt = os.time()
  }

  accounts[accountId] = account
  bindLedgerAccount(accountId)

  if not isLoadingData then
    triggerAccountUpdate(accountId)
  end

  return accountId
end

-- Closing a personal account pays its balance and accrued interest out to the wallet.
local function deleteAccount(accountId)
  if not accountId or not accounts[accountId] then
    return false
  end

  local account = accounts[accountId]
  if (account.type or "") == "business" then
    return false
  end

  if isSavingsPersonal(account) then
    closeOpenSegment(account)
  end

  processPendingTransfers()
  for transferId, transfer in pairs(pendingTransfers) do
    if transfer and transfer.toAccountId == accountId then
      local senderAccount = accounts[transfer.fromAccountId]
      if senderAccount then
        changeBalance(senderAccount, transfer.amount or 0)
        triggerAccountUpdate(transfer.fromAccountId)
      end
      pendingTransfers[transferId] = nil
    elseif transfer and transfer.fromAccountId == accountId then
      changeBalance(account, transfer.amount or 0)
      pendingTransfers[transferId] = nil
    end
  end

  local payTotal = (account.balance or 0) + (isSavingsPersonal(account) and (account.accruedInterest or 0) or 0)
  if isSavingsPersonal(account) then
    account.accruedInterest = 0
  end
  if payTotal > 0 then
    overhaul_career_economy_payment.reward({
      money = {
        amount = payTotal
      }
    }, {
      label = "Account closure withdrawal",
      category = "transfer"
    }, true)
  end

  accounts[accountId] = nil
  unbindLedgerAccount(accountId)
  transactions[accountId] = nil

  return true
end

-- Closes a business account and returns its final balance; pending transfers in either direction settle first.
local function liquidateBusinessAccount(accountId)
  if not accountId or not accounts[accountId] then
    return false, 0
  end

  local account = accounts[accountId]
  if (account.type or "") ~= "business" then
    return false, 0
  end

  processPendingTransfers()
  for transferId, transfer in pairs(pendingTransfers) do
    if transfer and transfer.fromAccountId == accountId then
      changeBalance(account, transfer.amount or 0)
      pendingTransfers[transferId] = nil
    elseif transfer and transfer.toAccountId == accountId then
      local senderAccount = accounts[transfer.fromAccountId]
      if senderAccount then
        changeBalance(senderAccount, transfer.amount or 0)
        triggerAccountUpdate(transfer.fromAccountId)
      end
      pendingTransfers[transferId] = nil
    end
  end
  local finalBalance = account.balance or 0
  accounts[accountId] = nil
  unbindLedgerAccount(accountId)
  transactions[accountId] = nil

  guihooks.trigger("bank:onAccountClosed", { accountId = accountId, businessType = account.businessType, businessId = account.businessId })

  return true, finalBalance
end

local function renameAccount(accountId, newName)
  if not accountId or not accounts[accountId] then
    return false
  end
  if not newName or newName == "" then
    return false
  end

  local account = accounts[accountId]
  if (account.type or "") == "business" then
    return false
  end

  account.name = newName

  return true
end

-- Funds -------------------------------------------------------------------------------------------

-- meta retains the producer category and finance context for the bank snapshot.
local function addFunds(accountId, amount, label, description, meta)
  if not accountId or not accounts[accountId] then
    return false
  end
  if not amount or amount <= 0 then
    return false
  end

  local account = accounts[accountId]
  closeOpenSegment(account)
  changeBalance(account, amount)
  syncSavingsSegmentAfterMutation(account)

  appendTransaction(accountId, {
    id = Engine.generateUUID(),
    accountId = accountId,
    label = label or "Deposit",
    amount = amount,
    timestamp = os.time(),
    description = description or "Funds added",
    category = meta and moneyCategories.normalize(meta.category) or nil,
    finance = require("overhaul/lib/finance/metadata").capture(meta, os.time(), amount)
  })

  triggerAccountUpdate(accountId)

  return true
end

local function removeFunds(accountId, amount, label, description, allowNegativeBalance, meta)
  if not accountId or not accounts[accountId] then
    return false
  end
  if not amount or amount <= 0 then
    return false
  end

  local account = accounts[accountId]
  if not allowNegativeBalance and (account.balance or 0) < amount then
    return false
  end

  closeOpenSegment(account)
  changeBalance(account, -amount)
  syncSavingsSegmentAfterMutation(account)

  appendTransaction(accountId, {
    id = Engine.generateUUID(),
    accountId = accountId,
    label = label or "Withdrawal",
    amount = -amount,
    timestamp = os.time(),
    description = description or "Funds removed",
    category = meta and moneyCategories.normalize(meta.category) or nil,
    finance = require("overhaul/lib/finance/metadata").capture(meta, os.time(), -amount)
  })

  triggerAccountUpdate(accountId)

  return true
end

-- Moves wallet money into an account, capped at the wallet balance.
local function deposit(accountId, amount)
  if not accountId or not accounts[accountId] then
    return false
  end
  if not amount or amount <= 0 then
    return false
  end

  local walletBalance = overhaul_career_economy_playerAttributes.getAttributeValue("money") or 0
  amount = math.min(amount, walletBalance)

  if amount <= 0 then
    return false
  end

  if not overhaul_career_economy_payment.canPay({
    money = {
      amount = amount,
      canBeNegative = false
    }
  }) then
    return false
  end

  if not overhaul_career_economy_payment.pay({
    money = {
      amount = amount,
      canBeNegative = false
    }
  }, {
    label = "Bank deposit",
    category = "transfer"
  }) then
    return false
  end

  return addFunds(accountId, amount, "Deposit", "Initial deposit", TRANSFER)
end

-- Moves money from an account to the wallet.
local function withdraw(accountId, amount)
  if not accountId or not accounts[accountId] then
    return false
  end
  if not amount or amount <= 0 then
    return false
  end

  local account = accounts[accountId]
  if (account.balance or 0) < amount then
    return false
  end

  overhaul_career_economy_payment.reward({
    money = {
      amount = amount
    }
  }, {
    label = "Bank withdrawal",
    category = "transfer"
  }, true)

  return removeFunds(accountId, amount, "Withdrawal", "Funds withdrawn", nil, TRANSFER)
end

-- Business source: money leaves now, lands after PENDING_TRANSFER_DURATION, and the transfer id is returned.
local function startBusinessTransfer(fromAccountId, toAccountId, amount)
  local fromAccount = accounts[fromAccountId]
  local transferId = Engine.generateUUID()
  local currentTime = os.time()
  local toAccount = accounts[toAccountId]
  local pendingEntry = {
    id = transferId,
    fromAccountId = fromAccountId,
    toAccountId = toAccountId,
    amount = amount,
    initiatedAt = currentTime,
    completesAt = currentTime + PENDING_TRANSFER_DURATION
  }

  closeOpenSegment(fromAccount)
  changeBalance(fromAccount, -amount, true)
  syncSavingsSegmentAfterMutation(fromAccount)

  appendTransaction(fromAccountId, {
    id = Engine.generateUUID(),
    accountId = fromAccountId,
    label = "Transfer Out",
    amount = -amount,
    timestamp = currentTime,
    description = "Transfer to " .. (toAccount and toAccount.name or "Account"),
    relatedAccountId = toAccountId,
    transferId = transferId,
    pending = true,
    category = "transfer"
  })

  pendingTransfers[transferId] = pendingEntry
  triggerAccountUpdate(fromAccountId)

  return transferId
end

-- Personal source: both balances move now and both histories get an entry.
local function postInstantTransfer(fromAccountId, toAccountId, amount)
  local fromAccount = accounts[fromAccountId]
  local toAccount = accounts[toAccountId]
  closeOpenSegment(fromAccount)
  closeOpenSegment(toAccount)
  changeBalance(fromAccount, -amount, true)
  changeBalance(toAccount, amount, true)
  syncSavingsSegmentAfterMutation(fromAccount)
  syncSavingsSegmentAfterMutation(toAccount)

  local currentTime = os.time()

  appendTransaction(fromAccountId, {
    id = Engine.generateUUID(),
    accountId = fromAccountId,
    label = "Transfer Out",
    amount = -amount,
    timestamp = currentTime,
    description = "Transfer to " .. (toAccount.name or "Account"),
    relatedAccountId = toAccountId,
    category = "transfer"
  })

  appendTransaction(toAccountId, {
    id = Engine.generateUUID(),
    accountId = toAccountId,
    label = "Transfer In",
    amount = amount,
    timestamp = currentTime,
    description = "Transfer from " .. (fromAccount.name or "Account"),
    relatedAccountId = fromAccountId,
    category = "transfer"
  })

  triggerAccountUpdate(fromAccountId)
  triggerAccountUpdate(toAccountId)

  return "instant"
end

-- Business sources are delayed and return a transfer id; personal sources post instantly and return "instant".
local function transfer(fromAccountId, toAccountId, amount)
  if not fromAccountId or not toAccountId or not accounts[fromAccountId] or not accounts[toAccountId] then
    return nil
  end

  if fromAccountId == toAccountId then
    return nil
  end
  if not amount or amount <= 0 then
    return nil
  end

  local fromAccount = accounts[fromAccountId]
  if fromAccount.balance < amount then
    return nil
  end

  if fromAccount.type == "business" then
    return startBusinessTransfer(fromAccountId, toAccountId, amount)
  end
  return postInstantTransfer(fromAccountId, toAccountId, amount)
end

-- Queries -----------------------------------------------------------------------------------------

local function getAccounts()
  processPendingTransfers()

  local accountsArray = {}
  for _, acc in pairs(accounts) do
    if isSavingsPersonal(acc) then
      acc.nextPayoutIn = math.max(0, SAVINGS_PAYOUT_INTERVAL_SEC - (acc.sinceLastPayout or 0))
    end
    table.insert(accountsArray, acc)
  end

  table.sort(accountsArray, function(a, b)
    if a.type ~= b.type then
      return a.type == "personal"
    end
    return a.createdAt < b.createdAt
  end)

  return accountsArray
end

local function getAccountBalance(accountId)
  if not accountId or not accounts[accountId] then
    return 0
  end
  processPendingTransfers()
  return accounts[accountId].balance or 0
end

-- Business balance including money still in transit out of it.
local function getBusinessAccountLiquidationBalance(accountId)
  if not accountId or not accounts[accountId] then
    return 0
  end
  processPendingTransfers()
  local account = accounts[accountId]
  local balance = account.balance or 0
  if (account.type or "") == "business" then
    for _, transfer in pairs(pendingTransfers) do
      if transfer and transfer.fromAccountId == accountId then
        balance = balance + (transfer.amount or 0)
      end
    end
  end
  return balance
end

local function getBusinessAccount(businessType, businessId)
  if not businessType or not businessId then
    return nil
  end
  local accountId = "business_" .. tostring(businessType) .. "_" .. tostring(businessId)
  return accounts[accountId]
end

local function getPendingTransfers()
  processPendingTransfers()

  local transfersArray = {}
  for _, transfer in pairs(pendingTransfers) do
    table.insert(transfersArray, transfer)
  end

  table.sort(transfersArray, function(a, b)
    return a.completesAt < b.completesAt
  end)

  return transfersArray
end

-- Newest first; limit <= 0 or nil returns the whole history.
local function getAccountTransactions(accountId, limit)
  if not accountId or not transactions[accountId] then
    return {}
  end

  local sorted = {}
  for _, trans in ipairs(transactions[accountId]) do
    table.insert(sorted, trans)
  end

  table.sort(sorted, function(a, b)
    return a.timestamp > b.timestamp
  end)

  if limit and limit > 0 then
    local limited = {}
    for i = 1, math.min(limit, #sorted) do
      table.insert(limited, sorted[i])
    end
    return limited
  end

  return sorted
end

-- Refunds a pending transfer to its sender and drops the pending record.
local function cancelPendingTransfer(transferId)
  if not transferId or not pendingTransfers[transferId] then
    return false
  end

  local transfer = pendingTransfers[transferId]
  if not transfer or not transfer.fromAccountId then
    return false
  end

  local fromAccount = accounts[transfer.fromAccountId]

  if fromAccount then
    local transferAmount = transfer.amount or 0
    closeOpenSegment(fromAccount)
    changeBalance(fromAccount, transferAmount)
    syncSavingsSegmentAfterMutation(fromAccount)

    -- Keep the debit beside its refund so history still reconciles to cash.
    -- Older saves predate the explicit link; match their original metadata.
    if transactions[transfer.fromAccountId] then
      local linkedDebit, legacyDebit, legacyMatches = nil, nil, 0
      for i = #transactions[transfer.fromAccountId], 1, -1 do
        local trans = transactions[transfer.fromAccountId][i]
        if trans.pending and trans.amount < 0 then
          if trans.transferId == transferId then
            linkedDebit = trans
            break
          elseif not trans.transferId and trans.timestamp == transfer.initiatedAt
            and trans.relatedAccountId == transfer.toAccountId
            and math.abs(math.abs(trans.amount) - transferAmount) < 0.01 then
            legacyDebit = trans
            legacyMatches = legacyMatches + 1
          end
        end
      end
      -- Identical legacy transfers cannot be distinguished; leave them unlinked.
      local debit = linkedDebit or (legacyMatches == 1 and legacyDebit)
      if debit then
        debit.pending, debit.cancelled, debit.transferId = false, true, transferId
      end
    end

    appendTransaction(transfer.fromAccountId, {
      id = Engine.generateUUID(),
      accountId = transfer.fromAccountId,
      label = "Transfer Refund",
      amount = transferAmount,
      timestamp = os.time(),
      description = "Transfer cancelled - refund",
      transferId = transferId,
      relatedAccountId = transfer.toAccountId,
      category = "transfer"
    })

    triggerAccountUpdate(transfer.fromAccountId)
  end

  pendingTransfers[transferId] = nil

  return true
end

-- Payments ----------------------------------------------------------------------------------------

-- Charges the money part of a price to an account; canBeNegative lets the balance go below zero.
local function payFromAccount(price, accountId, label, description, meta)
  if not accountId or not accounts[accountId] then
    return false
  end

  processPendingTransfers()

  local totalAmount = 0
  local allowNegativeBalance = false

  for currency, info in pairs(price) do
    if currency == "money" then
      totalAmount = totalAmount + info.amount
      if info.canBeNegative then
        allowNegativeBalance = true
      end
    end
  end

  if not allowNegativeBalance then
    local account = accounts[accountId]
    if (account.balance or 0) < totalAmount then
      return false
    end
  end

  return removeFunds(accountId, totalAmount, label or "Payment", description or "Payment", allowNegativeBalance, meta)
end

local function rewardToAccount(price, accountId, label, description, meta)
  if not accountId or not accounts[accountId] then
    return false
  end

  local totalAmount = 0

  for currency, info in pairs(price) do
    if currency == "money" then
      totalAmount = totalAmount + info.amount
    end
  end

  if totalAmount <= 0 then
    return false
  end

  return addFunds(accountId, totalAmount, label or "Reward", description or "Deposit", meta)
end

-- Per-frame update --------------------------------------------------------------------------------

-- Savings accrue on game time; pending transfers settle on real time.
local function onUpdate(dtReal, dtSim)
  dtSim = dtSim or 0
  dtReal = dtReal or 0
  savingsUpdateTimer = savingsUpdateTimer + dtSim
  if savingsUpdateTimer >= SAVINGS_UPDATE_INTERVAL_S then
    local elapsed = savingsUpdateTimer
    savingsUpdateTimer = 0
    applySavingsDtSim(elapsed)
  end
  updateTimer = updateTimer + dtReal
  if updateTimer >= UPDATE_INTERVAL_S then
    updateTimer = 0
    processPendingTransfers()
  end
end

-- Lifecycle ---------------------------------------------------------------------------------------

local function onCareerActivated()
  loadBankData()
end

-- Public API exports ------------------------------------------------------------------------------

M.createAccount = createAccount
M.createBusinessAccount = createBusinessAccount
M.deleteAccount = deleteAccount
M.liquidateBusinessAccount = liquidateBusinessAccount
M.renameAccount = renameAccount
M.deposit = deposit
M.withdraw = withdraw
M.addFunds = addFunds
M.removeFunds = removeFunds
M.transfer = transfer
M.getAccounts = getAccounts
M.getAccountBalance = getAccountBalance
M.getBusinessAccountLiquidationBalance = getBusinessAccountLiquidationBalance
M.getBusinessAccount = getBusinessAccount
M.getPendingTransfers = getPendingTransfers
M.getBusinessTransferDuration = function() return PENDING_TRANSFER_DURATION end
M.cancelPendingTransfer = cancelPendingTransfer
M.payFromAccount = payFromAccount
M.rewardToAccount = rewardToAccount
M.getAccountTransactions = getAccountTransactions

-- Game hooks exports ------------------------------------------------------------------------------

M.onCareerActivated = onCareerActivated
M.onUpdate = onUpdate
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
