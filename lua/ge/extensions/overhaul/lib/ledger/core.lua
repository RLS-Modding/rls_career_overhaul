-- Ledger operations, account balances, compensation and checkpoints.
-- Duplicate operations never apply twice; atomic failures restore every touched account in reverse order.
local M = {}

-- Ids -----------------------------------------------------------------------------------------------

local function escape(part)
  return (tostring(part == nil and "" or part):gsub("[\\|]", "\\%0"))
end

-- Stable operation id from the identity tuple (domain, sourceInstanceId, resultId, legKind, recipient).
function M.opId(domain, sourceInstanceId, resultId, legKind, recipient)
  return escape(domain) .. "|" .. escape(sourceInstanceId) .. "|" .. escape(resultId) .. "|"
    .. escape(legKind) .. "|" .. escape(recipient)
end

-- The unescaped fields of an id made by M.opId; separators split only where they are unescaped.
function M.parseOpId(id)
  if type(id) ~= "string" then return nil end
  local fields, current, i = {}, {}, 1
  while i <= #id do
    local c = id:sub(i, i)
    if c == "\\" and i < #id then
      current[#current + 1] = id:sub(i + 1, i + 1)
      i = i + 2
    else
      if c == "|" then
        fields[#fields + 1] = table.concat(current)
        current = {}
      else
        current[#current + 1] = c
      end
      i = i + 1
    end
  end
  fields[#fields + 1] = table.concat(current)
  return fields
end

-- Helpers -------------------------------------------------------------------------------------------

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local function captureLegs(legs)
  local captured = {}
  for i, leg in ipairs(legs) do
    captured[i] = {account = leg.account, amount = leg.amount, allowNegative = leg.allowNegative == true}
  end
  return captured
end

local unpack = unpack or table.unpack

local function resultOf(record, status)
  return {status = status, id = record.id, legs = copy(record.legs), seq = record.seq}
end

local function refuse(id, reason)
  return {status = "refused", id = id, reason = reason}
end

local function canAfford(adapter, total)
  if adapter.canDebit then return adapter.canDebit(total) end
  return adapter.get() >= total
end

-- Class ---------------------------------------------------------------------------------------------

local Ledger = {}
Ledger.__index = Ledger

-- opts.onPosted(result, operation) is called after an operation applies, never for duplicates.
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    accounts = {},
    applied = {},       -- id -> record {id, legs, refs, compensates, meta, seq}
    compensatedBy = {}, -- opId -> compensating opId
    seq = 0,
    freshCounter = 0,
    freshPrefix = opts.freshPrefix or "op",
    onPosted = opts.onPosted,
    checkpoint = nil,
    sinceCheckpoint = {},
  }, Ledger)
end

-- A unique id for a legacy call; it stays independent of every other call, so adopting the Ledger never deduplicates it.
function Ledger:freshId(domain)
  self.freshCounter = self.freshCounter + 1
  return M.opId(domain or "legacy", self.freshPrefix, self.freshCounter, "", "")
end

-- Accounts ------------------------------------------------------------------------------------------

function Ledger:addAccount(name, adapter)
  assert(type(name) == "string" and name ~= "", "account name required")
  assert(type(adapter) == "table" and type(adapter.get) == "function" and type(adapter.apply) == "function",
    "account adapter needs get and apply")
  self.accounts[name] = adapter
  return adapter
end

function Ledger:removeAccount(name)
  self.accounts[name] = nil
  if self.checkpoint then self.checkpoint[name] = nil end
  self.sinceCheckpoint[name] = nil
end

function Ledger:hasAccount(name)
  return self.accounts[name] ~= nil
end

function Ledger:balance(name)
  local adapter = self.accounts[name]
  if not adapter then return nil end
  return adapter.get()
end

function Ledger:isApplied(id)
  return self.applied[id] ~= nil
end

function Ledger:getApplied(id)
  return copy(self.applied[id])
end

-- Posting -------------------------------------------------------------------------------------------

-- Returns the result that ends the post early (a refusal or a duplicate), or nil when the operation may proceed.
local function screenOperation(self, operation)
  if type(operation) ~= "table" or type(operation.id) ~= "string" or operation.id == "" then return refuse(nil, "missing_id") end
  if operation.transient and operation.compensates ~= nil then return refuse(operation.id, "transient_compensation") end
  local existing = self.applied[operation.id]
  if existing then return resultOf(existing, "duplicate") end
  if type(operation.legs) ~= "table" or #operation.legs == 0 then return refuse(operation.id, "no_legs") end
  if operation.compensates ~= nil then
    if not self.applied[operation.compensates] then return refuse(operation.id, "unknown_compensated_operation") end
    if self.compensatedBy[operation.compensates] then return refuse(operation.id, "already_compensated") end
  end
  return nil
end

-- Validate every leg before touching accounts; transient postings retain owner-computed amounts.
local function checkLegs(self, operation)
  local debits = {}
  for _, leg in ipairs(operation.legs) do
    local adapter = self.accounts[leg.account]
    if not operation.transient then
      if type(leg.amount) ~= "number" or leg.amount ~= leg.amount or math.abs(leg.amount) == math.huge then
        return refuse(operation.id, "invalid_amount")
      end
    end
    if not adapter then return refuse(operation.id, "unknown_account") end
    if not operation.transient and leg.amount < 0 and not leg.allowNegative then
      debits[leg.account] = (debits[leg.account] or 0) - leg.amount
    end
  end
  for name, total in pairs(debits) do
    if not canAfford(self.accounts[name], total) then return refuse(operation.id, "insufficient_funds") end
  end
  return nil
end

-- Legacy path: each leg runs its primitive in order, as the wrapped code did. An error propagates and nothing is rolled back.
local function applyTransientLegs(self, operation, legs)
  for i, leg in ipairs(legs) do
    local adapter = self.accounts[leg.account]
    local before = adapter.get()
    adapter.apply(leg.amount, operation, i)
    leg.effective = adapter.get() - before
  end
end

-- Snapshot every touched account before its first leg and roll back in reverse order after failure.
local function applyAtomicLegs(self, operation, legs)
  for _, leg in ipairs(legs) do
    local adapter = self.accounts[leg.account]
    if type(adapter.snapshot) ~= "function" or type(adapter.restore) ~= "function" then
      return refuse(operation.id, "account_not_atomic")
    end
  end
  local snapshots, touched = {}, {}
  local ok, err = pcall(function()
    for i, leg in ipairs(legs) do
      local adapter = self.accounts[leg.account]
      if not snapshots[leg.account] then
        snapshots[leg.account] = {adapter.snapshot()}
        touched[#touched + 1] = leg.account
      end
      local before = adapter.get()
      adapter.apply(leg.amount, operation, i)
      leg.effective = adapter.get() - before
    end
  end)
  if ok then return nil end
  for i = #touched, 1, -1 do
    local name = touched[i]
    self.accounts[name].restore(unpack(snapshots[name]))
  end
  return {status = "failed", id = operation.id, reason = tostring(err)}
end

-- Advances the sequence and the checkpoint sums, keeps the record unless transient, and notifies.
local function commitApplied(self, operation, legs)
  self.seq = self.seq + 1
  if self.checkpoint then
    for _, leg in ipairs(legs) do
      if type(leg.effective) == "number" then
        self.sinceCheckpoint[leg.account] = (self.sinceCheckpoint[leg.account] or 0) + leg.effective
      end
    end
  end
  local result = nil
  if operation.transient then
    result = {status = "applied", id = operation.id, legs = legs, seq = self.seq}
  else
    local record = {id = operation.id, legs = legs, refs = copy(operation.refs), compensates = operation.compensates, meta = copy(operation.meta), seq = self.seq}
    self.applied[operation.id] = record
    if operation.compensates ~= nil then self.compensatedBy[operation.compensates] = operation.id end
    result = resultOf(record, "applied")
  end
  if self.onPosted then self.onPosted(result, operation) end
  return result
end

-- Duplicate ids return the first result; refused or failed operations remain retryable.
function Ledger:post(operation)
  local ended = screenOperation(self, operation)
  if ended then return ended end
  local refusal = checkLegs(self, operation)
  if refusal then return refusal end
  local legs = captureLegs(operation.legs)
  if operation.transient then
    applyTransientLegs(self, operation, legs)
  else
    local failure = applyAtomicLegs(self, operation, legs)
    if failure then return failure end
  end
  return commitApplied(self, operation, legs)
end

-- Reverse effective changes in reverse leg order so compensation mirrors the applied operation.
function Ledger:compensate(id, newId, meta)
  local record = self.applied[id]
  if not record then return refuse(newId, "unknown_compensated_operation") end
  local legs = {}
  for i = #record.legs, 1, -1 do
    local leg = record.legs[i]
    local moved = leg.effective
    if moved == nil then moved = leg.amount end
    legs[#legs + 1] = {account = leg.account, amount = -moved, allowNegative = true}
  end
  return self:post({id = newId or (id .. "#compensation"), legs = legs, compensates = id, meta = meta})
end

-- Checkpoints ---------------------------------------------------------------------------------------

-- Opening checkpoint: the balances the loaders produced, taken as they are.
function Ledger:openCheckpoint()
  local balances = {}
  for name, adapter in pairs(self.accounts) do balances[name] = adapter.get() end
  self.checkpoint = balances
  self.sinceCheckpoint = {}
  return copy(balances)
end

-- Reopen checkpoints after load or account creation to exclude loader-owned balance changes.
function Ledger:rebase(name)
  self.checkpoint = self.checkpoint or {}
  local adapter = self.accounts[name]
  self.checkpoint[name] = adapter and adapter.get() or nil
  self.sinceCheckpoint[name] = nil
end

function Ledger:getCheckpoint()
  return copy(self.checkpoint)
end

-- Every account equals its checkpoint plus the legs posted since. Returns ok, mismatches; accounts added after the checkpoint are not judged.
function Ledger:checkInvariant(tolerance)
  tolerance = tolerance or 1e-6
  if not self.checkpoint then return false, {{reason = "no_checkpoint"}} end
  local mismatches = {}
  for name, opening in pairs(self.checkpoint) do
    local adapter = self.accounts[name]
    if adapter then
      local expected = opening + (self.sinceCheckpoint[name] or 0)
      local actual = adapter.get()
      if math.abs(actual - expected) > tolerance then
        mismatches[#mismatches + 1] = {account = name, expected = expected, actual = actual}
      end
    end
  end
  table.sort(mismatches, function(a, b) return a.account < b.account end)
  return #mismatches == 0, mismatches
end

-- Applied records -----------------------------------------------------------------------------------

-- Applied records in posting order (copies).
function Ledger:appliedList()
  local list = {}
  for _, record in pairs(self.applied) do list[#list + 1] = copy(record) end
  table.sort(list, function(a, b) return a.seq < b.seq end)
  return list
end

-- Drops applied records for which keep(record) is false; returns how many were dropped.
function Ledger:prune(keep)
  local dropped = 0
  for id, record in pairs(self.applied) do
    if not keep(record) then
      self.applied[id] = nil
      dropped = dropped + 1
    end
  end
  for compensated, by in pairs(self.compensatedBy) do
    if not self.applied[by] and not self.applied[compensated] then self.compensatedBy[compensated] = nil end
  end
  return dropped
end

-- Restores applied records (from captured save generations) without re-applying their legs.
function Ledger:restoreApplied(records)
  self.applied, self.compensatedBy, self.seq = {}, {}, 0
  for _, record in ipairs(records or {}) do
    local restored = copy(record)
    self.applied[restored.id] = restored
    if restored.compensates ~= nil then self.compensatedBy[restored.compensates] = restored.id end
    if (restored.seq or 0) > self.seq then self.seq = restored.seq end
  end
end

M.Ledger = Ledger
-- Account adapters --------------------------------------------------------------------------------

local accounts = {}

-- Adapter shape: get() -> number, apply(delta), canDebit(amount) -> bool (optional), snapshot() and restore(...) (optional).

-- Capture the owned field so rollback restores its exact previous value.
function accounts.field(getTable, field, opts)
  opts = opts or {}
  local adapter = {}
  function adapter.get()
    local stateTable = getTable()
    return (stateTable and stateTable[field]) or 0
  end
  function adapter.apply(delta)
    local stateTable = assert(getTable(), "ledger account state is missing")
    local value = (stateTable[field] or 0) + delta
    if opts.min and value < opts.min then value = opts.min end
    if opts.max and value > opts.max then value = opts.max end
    stateTable[field] = value
  end
  function adapter.canDebit(amount)
    return opts.allowOverdraft == true or adapter.get() >= amount
  end
  function adapter.snapshot()
    local stateTable = getTable()
    return stateTable, stateTable and stateTable[field]
  end
  function adapter.restore(stateTable, value)
    if stateTable then stateTable[field] = value end
  end
  return adapter
end

-- Delegate mutation to the owner to preserve history, hooks and rounding.
function accounts.custom(get, apply, canDebit, snapshot, restore)
  assert(type(get) == "function" and type(apply) == "function", "custom account needs get and apply")
  return {get = get, apply = apply, canDebit = canDebit, snapshot = snapshot, restore = restore}
end

-- A ledger-owned balance (escrow, held earnings) with no legacy store of its own.
function accounts.memory(initial, opts)
  local state = {balance = initial or 0}
  local adapter = accounts.field(function() return state end, "balance", opts)
  adapter.state = state
  return adapter
end


-- Save generations --------------------------------------------------------------------------------

local saveState = {}

saveState.SCHEMA = 1

-- Operation states: APPLIED (in memory), CAPTURED(g) (in generation g's capture), ACCEPTED (g's info.json commit succeeded).

local State = {}
State.__index = State

-- Retention follows accepted save generations rather than the number of attempted saves.
function saveState.new(ledger, opts)
  assert(ledger, "ledger required")
  opts = opts or {}
  assert(type(opts.profile) == "string" and opts.profile ~= "", "profile required")
  local self = setmetatable({
    ledger = ledger,
    profile = opts.profile,
    keep = opts.keepAcceptedGenerations or 2,
    capturing = nil,
    lastAccepted = nil,
  }, State)
  local previous = ledger.onPosted
  -- A posting made while a generation is captured is buffered for the next one, so an operation and its terminal state land together.
  ledger.onPosted = function(result, op)
    local record = ledger.applied[result.id]
    if record then
      record.state = "APPLIED"
      record.generation = self.capturing and (self.capturing + 1) or nil
    end
    if previous then previous(result, op) end
  end
  return self
end

function State:isCapturing()
  return self.capturing ~= nil
end

-- Marks every APPLIED operation not buffered for a later generation as CAPTURED(g), and returns the record to store.
function State:beginCapture(generation)
  assert(type(generation) == "number", "generation required")
  assert(self.capturing == nil, "capture already running")
  self.capturing = generation
  for _, record in pairs(self.ledger.applied) do
    if record.state == nil or (record.state == "APPLIED" and (record.generation == nil or record.generation <= generation)) then
      record.state = "CAPTURED"
      record.generation = generation
    end
  end
  return self:captureRecord(generation)
end

function State:endCapture()
  self.capturing = nil
end

-- Keep operations captured or accepted within the retained generation window.
function State:captureRecord(generation)
  local ops = {}
  for _, record in ipairs(self.ledger:appliedList()) do
    if record.state == "ACCEPTED" or (record.state == "CAPTURED" and record.generation == generation) then
      ops[#ops + 1] = {id = record.id, legs = record.legs, refs = record.refs, compensates = record.compensates,
        meta = record.meta, seq = record.seq, generation = record.generation,
        state = record.state == "ACCEPTED" and "ACCEPTED" or "CAPTURED"}
    end
  end
  -- The fresh-id generator continues after a reload, so a new operation never reuses an id.
  return {schema = saveState.SCHEMA, profile = self.profile, generation = generation,
    checkpoint = self.ledger:getCheckpoint(), ops = ops,
    ids = {prefix = self.ledger.freshPrefix, counter = self.ledger.freshCounter}}
end

-- info.json for generation g committed. Returns how many operations the prune dropped.
function State:accept(generation)
  for _, record in pairs(self.ledger.applied) do
    if record.state == "CAPTURED" and record.generation == generation then record.state = "ACCEPTED" end
  end
  self.lastAccepted = generation
  local oldest = generation - self.keep + 1
  return self.ledger:prune(function(record)
    return record.state ~= "ACCEPTED" or (record.generation or generation) >= oldest
  end)
end

-- Generation g's save failed: its operations wait for the next capture.
function State:fail(generation)
  for _, record in pairs(self.ledger.applied) do
    if record.state == "CAPTURED" and record.generation == generation then
      record.state = "APPLIED"
      record.generation = nil
    end
  end
  if self.capturing == generation then self.capturing = nil end
end

-- Scan restored ids because older records omit generator state.
local function restoreFreshIds(ledger, record, restored)
  local ids = record.ids
  if type(ids) == "table" then
    if type(ids.prefix) == "string" and ids.prefix ~= "" then ledger.freshPrefix = ids.prefix end
    if type(ids.counter) == "number" and ids.counter > ledger.freshCounter then ledger.freshCounter = ids.counter end
  end
  for _, op in ipairs(restored) do
    local fields = M.parseOpId(op.id)
    if fields and #fields == 5 and fields[2] == ledger.freshPrefix and fields[4] == "" and fields[5] == "" and fields[3]:match("^%d+$") then
      local counter = tonumber(fields[3])
      if counter > ledger.freshCounter then ledger.freshCounter = counter end
    end
  end
end

-- Owner loaders restore balances; protocol restore installs only their checkpoint and applied ids.
function State:load(record)
  if type(record) ~= "table" then return false, "missing" end
  if record.schema ~= saveState.SCHEMA then return false, "schema" end
  if record.profile ~= self.profile then return false, "profile" end
  local restored = {}
  for _, op in ipairs(record.ops or {}) do
    restored[#restored + 1] = {id = op.id, legs = op.legs, refs = op.refs, compensates = op.compensates,
      meta = op.meta, seq = op.seq, generation = op.generation, state = "ACCEPTED"}
  end
  self.ledger:restoreApplied(restored)
  restoreFreshIds(self.ledger, record, restored)
  self.lastAccepted = record.generation
  return true
end

function State:states()
  local out = {}
  for id, record in pairs(self.ledger.applied) do out[id] = {state = record.state, generation = record.generation} end
  return out
end

saveState.State = State

M.accounts = accounts
M.saveState = saveState

return M
