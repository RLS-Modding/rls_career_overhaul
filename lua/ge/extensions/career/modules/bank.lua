local M = {}

M.dependencies = {'career_career', 'career_saveSystem', 'career_modules_playerAttributes', 'career_modules_payment'}

local saveDir = "/career/rls_career"
local saveFile = saveDir .. "/bank.json"

local PENDING_TRANSFER_DURATION = 5 * 60

local accounts = {}
local pendingTransfers = {}
local transactions = {}

local function ensureSaveDir(currentSavePath)
  local dirPath = currentSavePath .. saveDir
  if not FS:directoryExists(dirPath) then
    FS:directoryCreate(dirPath)
  end
end

local function loadBankData()
  if not career_career.isActive() then return end
  local _, currentSavePath = career_saveSystem.getCurrentSaveSlot()
  if not currentSavePath then return end
  
  local data = jsonReadFile(currentSavePath .. saveFile) or {}
  accounts = {}
  pendingTransfers = {}
  transactions = {}
  
  if data.accounts then
    for _, acc in ipairs(data.accounts) do
      accounts[acc.id] = acc
    end
  end
  
  if data.pendingTransfers then
    for _, transfer in ipairs(data.pendingTransfers) do
      pendingTransfers[transfer.id] = transfer
    end
  end
  
  if data.transactions then
    for _, trans in ipairs(data.transactions) do
      if not transactions[trans.accountId] then
        transactions[trans.accountId] = {}
      end
      table.insert(transactions[trans.accountId], trans)
    end
  end
end

local function saveBankData(currentSavePath)
  if not career_career.isActive() then return end
  if not currentSavePath then
    local _, path = career_saveSystem.getCurrentSaveSlot()
    currentSavePath = path
  end
  if not currentSavePath then return end
  
  ensureSaveDir(currentSavePath)
  
  local accountsArray = {}
  for _, acc in pairs(accounts) do
    table.insert(accountsArray, acc)
  end
  
  local transfersArray = {}
  for _, transfer in pairs(pendingTransfers) do
    table.insert(transfersArray, transfer)
  end
  
  local transactionsArray = {}
  for accountId, accountTransactions in pairs(transactions) do
    for _, trans in ipairs(accountTransactions) do
      table.insert(transactionsArray, trans)
    end
  end
  
  local data = {
    accounts = accountsArray or {},
    pendingTransfers = transfersArray or {},
    transactions = transactionsArray or {}
  }
  
  if not data or type(data) ~= "table" then
    log("E", "bank", "saveBankData: Invalid data structure")
    return
  end
  
  career_saveSystem.jsonWriteFileSafe(currentSavePath .. saveFile, data, true)
end

local function onSaveCurrentSaveSlot(currentSavePath)
  if not currentSavePath then return end
  local success, err = pcall(function()
    saveBankData(currentSavePath)
  end)
  if not success then
    log("E", "bank", "onSaveCurrentSaveSlot failed: " .. tostring(err))
  end
end

local function processPendingTransfers()
  local currentTime = os.time()
  local completed = {}
  
  for id, transfer in pairs(pendingTransfers) do
    if currentTime >= transfer.completesAt then
      local fromAccount = accounts[transfer.fromAccountId]
      local toAccount = accounts[transfer.toAccountId]
      
      if fromAccount and toAccount then
        toAccount.balance = toAccount.balance + transfer.amount
        
        if not transactions[transfer.toAccountId] then
          transactions[transfer.toAccountId] = {}
        end
        table.insert(transactions[transfer.toAccountId], {
          id = Engine.generateUUID(),
          accountId = transfer.toAccountId,
          type = "transfer_in",
          amount = transfer.amount,
          timestamp = transfer.completesAt,
          description = "Transfer from " .. (fromAccount.name or "Account"),
          relatedAccountId = transfer.fromAccountId
        })
        
        table.insert(completed, id)
      end
    end
  end
  
  for _, id in ipairs(completed) do
    pendingTransfers[id] = nil
  end
  
  if #completed > 0 then
    saveBankData()
  end
end

local function createAccount(name, accountType, initialDeposit)
  if not name or name == "" then return nil end
  if accountType ~= "savings" and accountType ~= "checking" then
    accountType = "checking"
  end
  
  local walletBalance = career_modules_playerAttributes.getAttributeValue("money") or 0
  initialDeposit = initialDeposit or 0
  initialDeposit = math.max(0, math.min(initialDeposit, walletBalance))
  
  if initialDeposit > 0 then
    if not career_modules_payment.canPay({ money = { amount = initialDeposit, canBeNegative = false } }) then
      return nil
    end
    career_modules_payment.pay({ money = { amount = initialDeposit, canBeNegative = false } }, { label = "Bank deposit" })
  end
  
  local accountId = Engine.generateUUID()
  local account = {
    id = accountId,
    name = name,
    type = "personal",
    accountType = accountType,
    balance = initialDeposit,
    createdAt = os.time()
  }
  
  accounts[accountId] = account
  
  if initialDeposit > 0 then
    if not transactions[accountId] then
      transactions[accountId] = {}
    end
    table.insert(transactions[accountId], {
      id = Engine.generateUUID(),
      accountId = accountId,
      type = "deposit",
      amount = initialDeposit,
      timestamp = os.time(),
      description = "Initial deposit"
    })
  end
  
  saveBankData()
  
  return accountId
end

local function createBusinessAccount(businessType, businessId, businessName)
  local accountId = "business_" .. businessType .. "_" .. businessId
  
  if accounts[accountId] then
    return accountId
  end
  
  local account = {
    id = accountId,
    name = businessName .. " Account",
    type = "business",
    businessType = businessType,
    businessId = businessId,
    balance = 0,
    createdAt = os.time()
  }
  
  accounts[accountId] = account
  saveBankData()
  
  return accountId
end

local function deleteAccount(accountId)
  if not accountId or not accounts[accountId] then return false end
  
  local account = accounts[accountId]
  if account.type == "business" then return false end
  
  local balance = account.balance
  if balance > 0 then
    career_modules_payment.reward({ money = { amount = balance } }, { label = "Account closure withdrawal" }, true)
  end
  
  accounts[accountId] = nil
  saveBankData()
  
  return true
end

local function renameAccount(accountId, newName)
  if not accountId or not accounts[accountId] then return false end
  if not newName or newName == "" then return false end
  
  local account = accounts[accountId]
  if account.type == "business" then return false end
  
  account.name = newName
  saveBankData()
  
  return true
end

local function deposit(accountId, amount)
  if not accountId or not accounts[accountId] then return false end
  if not amount or amount <= 0 then return false end
  
  local walletBalance = career_modules_playerAttributes.getAttributeValue("money") or 0
  amount = math.min(amount, walletBalance)
  
  if amount <= 0 then return false end
  
  if not career_modules_payment.canPay({ money = { amount = amount, canBeNegative = false } }) then
    return false
  end
  
  if not career_modules_payment.pay({ money = { amount = amount, canBeNegative = false } }, { label = "Bank deposit" }) then
    return false
  end
  
  accounts[accountId].balance = accounts[accountId].balance + amount
  
  if not transactions[accountId] then
    transactions[accountId] = {}
  end
  table.insert(transactions[accountId], {
    id = Engine.generateUUID(),
    accountId = accountId,
    type = "deposit",
    amount = amount,
    timestamp = os.time(),
    description = "Deposit"
  })
  
  saveBankData()
  
  return true
end

local function withdraw(accountId, amount)
  if not accountId or not accounts[accountId] then return false end
  if not amount or amount <= 0 then return false end
  
  local account = accounts[accountId]
  if account.balance < amount then return false end
  
  account.balance = account.balance - amount
  career_modules_payment.reward({ money = { amount = amount } }, { label = "Bank withdrawal" }, true)
  
  if not transactions[accountId] then
    transactions[accountId] = {}
  end
  table.insert(transactions[accountId], {
    id = Engine.generateUUID(),
    accountId = accountId,
    type = "withdraw",
    amount = amount,
    timestamp = os.time(),
    description = "Withdrawal"
  })
  
  saveBankData()
  
  return true
end

local function transfer(fromAccountId, toAccountId, amount)
  if not fromAccountId or not toAccountId or not accounts[fromAccountId] or not accounts[toAccountId] then
    return nil
  end
  
  if fromAccountId == toAccountId then return nil end
  if not amount or amount <= 0 then return nil end
  
  local fromAccount = accounts[fromAccountId]
  if fromAccount.balance < amount then return nil end
  
  local fromIsBusiness = fromAccount.type == "business"
  
  if fromIsBusiness then
    local transferId = Engine.generateUUID()
    local currentTime = os.time()
    local toAccount = accounts[toAccountId]
    local transfer = {
      id = transferId,
      fromAccountId = fromAccountId,
      toAccountId = toAccountId,
      amount = amount,
      initiatedAt = currentTime,
      completesAt = currentTime + PENDING_TRANSFER_DURATION
    }
    
    fromAccount.balance = fromAccount.balance - amount
    
    if not transactions[fromAccountId] then
      transactions[fromAccountId] = {}
    end
    table.insert(transactions[fromAccountId], {
      id = Engine.generateUUID(),
      accountId = fromAccountId,
      type = "transfer_out",
      amount = amount,
      timestamp = currentTime,
      description = "Transfer to " .. (toAccount and toAccount.name or "Account"),
      relatedAccountId = toAccountId,
      pending = true
    })
    
    pendingTransfers[transferId] = transfer
    saveBankData()
    
    return transferId
  else
    local toAccount = accounts[toAccountId]
    fromAccount.balance = fromAccount.balance - amount
    toAccount.balance = toAccount.balance + amount
    
    local currentTime = os.time()
    
    if not transactions[fromAccountId] then
      transactions[fromAccountId] = {}
    end
    table.insert(transactions[fromAccountId], {
      id = Engine.generateUUID(),
      accountId = fromAccountId,
      type = "transfer_out",
      amount = amount,
      timestamp = currentTime,
      description = "Transfer to " .. (toAccount.name or "Account"),
      relatedAccountId = toAccountId
    })
    
    if not transactions[toAccountId] then
      transactions[toAccountId] = {}
    end
    table.insert(transactions[toAccountId], {
      id = Engine.generateUUID(),
      accountId = toAccountId,
      type = "transfer_in",
      amount = amount,
      timestamp = currentTime,
      description = "Transfer from " .. (fromAccount.name or "Account"),
      relatedAccountId = fromAccountId
    })
    
    saveBankData()
    
    return "instant"
  end
end

local function getAccounts()
  processPendingTransfers()
  
  local accountsArray = {}
  for _, acc in pairs(accounts) do
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
  if not accountId or not accounts[accountId] then return 0 end
  processPendingTransfers()
  return accounts[accountId].balance or 0
end

local function getBusinessAccount(businessType, businessId)
  local accountId = "business_" .. businessType .. "_" .. businessId
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

local function cancelPendingTransfer(transferId)
  if not transferId or not pendingTransfers[transferId] then return false end
  
  local transfer = pendingTransfers[transferId]
  local fromAccount = accounts[transfer.fromAccountId]
  
  if fromAccount then
    fromAccount.balance = fromAccount.balance + transfer.amount
  end
  
  pendingTransfers[transferId] = nil
  saveBankData()
  
  return true
end

local function payFromAccount(price, accountId)
  if not accountId or not accounts[accountId] then return false end
  
  processPendingTransfers()
  
  local account = accounts[accountId]
  local totalAmount = 0
  
  for currency, info in pairs(price) do
    if currency == "money" then
      totalAmount = totalAmount + info.amount
    end
  end
  
  if account.balance < totalAmount then return false end
  
  account.balance = account.balance - totalAmount
  
  if not transactions[accountId] then
    transactions[accountId] = {}
  end
  table.insert(transactions[accountId], {
    id = Engine.generateUUID(),
    accountId = accountId,
    type = "payment",
    amount = totalAmount,
    timestamp = os.time(),
    description = "Payment"
  })
  
  saveBankData()
  
  return true
end

local function rewardToAccount(price, accountId)
  if not accountId or not accounts[accountId] then return false end
  
  local account = accounts[accountId]
  local totalAmount = 0
  
  for currency, info in pairs(price) do
    if currency == "money" then
      totalAmount = totalAmount + info.amount
    end
  end
  
  if totalAmount <= 0 then return false end
  
  account.balance = account.balance + totalAmount
  
  if not transactions[accountId] then
    transactions[accountId] = {}
  end
  table.insert(transactions[accountId], {
    id = Engine.generateUUID(),
    accountId = accountId,
    type = "reward",
    amount = totalAmount,
    timestamp = os.time(),
    description = "Deposit"
  })
  
  saveBankData()
  
  return true
end

local updateInterval = 5
local updateTimer = 0

local function onUpdate(dt)
  updateTimer = updateTimer + dt
  if updateTimer >= updateInterval then
    updateTimer = 0
    processPendingTransfers()
  end
end

function M.onCareerActivated()
  loadBankData()
end

function M.onCareerModulesActivated()
  -- Modules are ready
end

M.onUpdate = onUpdate
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot
M.createAccount = createAccount
M.createBusinessAccount = createBusinessAccount
M.deleteAccount = deleteAccount
M.renameAccount = renameAccount
M.deposit = deposit
M.withdraw = withdraw
M.transfer = transfer
M.getAccounts = getAccounts
M.getAccountBalance = getAccountBalance
M.getBusinessAccount = getBusinessAccount
M.getPendingTransfers = getPendingTransfers
M.cancelPendingTransfer = cancelPendingTransfer
M.payFromAccount = payFromAccount
M.rewardToAccount = rewardToAccount

local function getAccountTransactions(accountId, limit)
  if not accountId or not transactions[accountId] then return {} end
  
  local accountTransactions = transactions[accountId]
  local sorted = {}
  for _, trans in ipairs(accountTransactions) do
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

M.getAccountTransactions = getAccountTransactions

return M

