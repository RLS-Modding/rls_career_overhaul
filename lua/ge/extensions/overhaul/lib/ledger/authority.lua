-- A shared ledger tracking wallet and bank postings through their existing mutation primitives.
-- Account handles retain owner lifetime so a stale facade cannot mutate its replacement.
local core = require("overhaul/lib/ledger/core")
local categories = require("overhaul/lib/ledger/categories")

local M = {}

local ledger = core.new({freshPrefix = "legacy"})
ledger:openCheckpoint()

function M.ledger()
  return ledger
end

-- A retained facade posts through its own handle so replacement cannot redirect stale writes.
local current = {}

-- Binds `name` to `adapter` for the live session, rebased at its loaded balance, and returns the handle to post through.
function M.bind(name, adapter)
  local handle = {name = name, adapter = adapter}
  ledger:addAccount(name, adapter)
  ledger:rebase(name)
  current[name] = handle
  return handle
end

function M.isCurrent(handle)
  return handle ~= nil and current[handle.name] == handle
end

-- Drops the handle's binding if it is still the live one.
function M.unbind(handle)
  if M.isCurrent(handle) then
    current[handle.name] = nil
    ledger:removeAccount(handle.name)
  end
end

-- Drops every live binding whose name starts with `prefix`, for an owner reloading its accounts.
function M.unbindPrefix(prefix)
  local names = {}
  for name in pairs(current) do
    if name:sub(1, #prefix) == prefix then names[#names + 1] = name end
  end
  for _, name in ipairs(names) do
    current[name] = nil
    ledger:removeAccount(name)
  end
end

-- Re-opens the checkpoint of a live binding at its current balance, after the owner's own initialisation writes.
function M.rebase(handle)
  if M.isCurrent(handle) then ledger:rebase(handle.name) end
end

-- Use a fresh operation id for each legacy mutation; existing effects must not be deduplicated.
function M.post(handle, amount, meta, strict)
  local leg = {account = handle.name, amount = amount, allowNegative = true, strict = strict}
  if not M.isCurrent(handle) then
    handle.adapter.apply(amount, {legs = {leg}, meta = meta}, 1)
    return {status = "applied", detached = true}
  end
  local result = ledger:post({id = ledger:freshId(handle.name), legs = {leg}, meta = meta, transient = true})
  if result.status ~= "applied" then error(result.reason or result.status, 0) end
  return result
end

-- ok, mismatches: every bound account equals its checkpoint plus the postings since.
function M.check(tolerance)
  return ledger:checkInvariant(tolerance)
end

local function newBucket()
  return {income = {}, expense = {}, incomeTotal = 0, expenseTotal = 0, transfersIn = 0, transfersOut = 0, rows = 0}
end

local function add(bucket, category, amount)
  if type(amount) ~= "number" or amount == 0 or amount ~= amount then return end
  bucket.rows = bucket.rows + 1
  if category == "transfer" then
    if amount > 0 then bucket.transfersIn = bucket.transfersIn + amount else bucket.transfersOut = bucket.transfersOut - amount end
  elseif amount > 0 then
    bucket.income[category] = (bucket.income[category] or 0) + amount
    bucket.incomeTotal = bucket.incomeTotal + amount
  else
    bucket.expense[category] = (bucket.expense[category] or 0) - amount
    bucket.expenseTotal = bucket.expenseTotal - amount
  end
end

-- Escrow release contributes one income row; unspent held wages are not posted income.
function M.summarize(input)
  local result = {wallet = newBucket(), personalBank = newBucket(), business = newBucket(), businessAccounts = {}}
  local since = input.since
  for _, row in ipairs(input.attributeLog or {}) do
    local change = type(row) == "table" and row.attributeChange
    if type(change) == "table" and change.money ~= nil and (not since or (row.time or 0) >= since) then
      add(result.wallet, categories.of(row), change.money)
    end
  end
  local transactions = input.transactions
  for _, account in ipairs(input.accounts or {}) do
    local rows = type(transactions) == "function" and transactions(account.id) or (transactions and transactions[account.id]) or {}
    local isBusiness = account.type == "business"
    local ownBucket = isBusiness and newBucket() or nil
    for _, row in ipairs(rows) do
      if not since or (row.timestamp or 0) >= since then
        local category = categories.of(row)
        add(isBusiness and result.business or result.personalBank, category, row.amount)
        if ownBucket then add(ownBucket, category, row.amount) end
      end
    end
    if ownBucket then result.businessAccounts[account.id] = ownBucket end
  end
  return result
end

-- Public account reads settle due transfers before the figures are projected.
function M.collect(since)
  local attributes = overhaul_career_economy_playerAttributes
  local bank = overhaul_career_economy_bank
  return M.summarize({
    attributeLog = attributes and attributes.getAttributeLog and attributes.getAttributeLog() or {},
    accounts = bank and bank.getAccounts and bank.getAccounts() or {},
    transactions = bank and bank.getAccountTransactions or nil,
    since = since,
  })
end


return M
