-- Checkout reservation, charge and compensation through owner callbacks.
-- Callback results and exceptions retain their original order and refusal semantics.
local M = {}

M.STATE = {
  QUOTED = "quoted",
  PENDING = "pending",
  RESERVED = "reserved",
  COMMITTED = "committed",
  REFUSED = "refused",
  COMPENSATING = "compensating",
  COMPENSATED = "compensated",
  FAILED = "failed",
}

local states = M.STATE

-- Allowed next states; COMMITTED, REFUSED, COMPENSATED and FAILED are terminal.
local allowedNext = {
  [states.QUOTED] = {[states.PENDING] = true, [states.RESERVED] = true, [states.COMMITTED] = true, [states.REFUSED] = true, [states.FAILED] = true},
  [states.PENDING] = {[states.RESERVED] = true, [states.COMMITTED] = true, [states.REFUSED] = true, [states.COMPENSATING] = true, [states.FAILED] = true},
  [states.RESERVED] = {[states.COMMITTED] = true, [states.COMPENSATING] = true, [states.REFUSED] = true, [states.FAILED] = true},
  [states.COMMITTED] = {[states.COMPENSATING] = true},
  [states.COMPENSATING] = {[states.COMPENSATED] = true, [states.FAILED] = true},
}

local idCounter = 0

-- Process-local and deterministic: never persisted or shown to the player.
function M.nextId(prefix)
  idCounter = idCounter + 1
  return string.format("%s-%d", prefix or "co", idCounter)
end

-- A settled operation has no work left; only a committed one may still be compensated.
function M.isSettled(state)
  return state == states.COMMITTED or state == states.REFUSED or state == states.COMPENSATED or state == states.FAILED
end

function M.wallet()
  return {kind = "wallet"}
end

function M.business(businessId, accountId)
  return {kind = "business", businessId = businessId, accountId = accountId}
end

-- spec: flow, amount (captured as given), payer, sponsor, target, label, tags, quoteId.
function M.newOperation(spec)
  spec = spec or {}
  return {
    id = M.nextId("op"),
    quoteId = spec.quoteId,
    flow = spec.flow,
    amount = spec.amount,
    payer = spec.payer or M.wallet(),
    sponsor = spec.sponsor,
    target = spec.target,
    label = spec.label,
    tags = spec.tags,
    state = states.QUOTED,
  }
end

function M.canTransition(from, to)
  local allowed = allowedNext[from]
  return allowed ~= nil and allowed[to] == true
end

-- Returns true when the state changed, false and a reason otherwise.
function M.transition(op, to)
  if type(op) ~= "table" then return false, "no operation" end
  if not M.canTransition(op.state, to) then
    return false, string.format("%s cannot move from %s to %s", tostring(op.id), tostring(op.state), tostring(to))
  end
  op.state = to
  return true
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

-- spec: flow, amount, lines (optional price lines), currency (default "money").
function M.captureQuote(spec)
  spec = spec or {}
  return {
    id = M.nextId("q"),
    flow = spec.flow,
    amount = spec.amount,
    currency = spec.currency or "money",
    lines = copy(spec.lines),
  }
end


local money = {}

-- Reuse the facade to avoid double posting or bypassing its authority.
function money.execute(call, ...)
  return call(...)
end

money.KINDS = {
  -- wallet reward or charge now
  immediate = {route = {"payment.reward", "payment.pay"}},
  -- earned into owner-held wages; the owner holds it and releases it later as one reward
  heldWages = {route = {"escrow", "payment.reward"}, needs = {"sourceInstanceId"}},
  -- business bank account
  businessAccount = {route = {"bank.rewardToAccount", "bank.payFromAccount"}, needs = {"accountId"}},
  -- contract total, paid once at completion
  accumulatedContract = {route = {"payment.reward"}, needs = {"sourceInstanceId"}},
  -- a non-money reward (vehicle), granted by the owner's own path (newEntitlement, below)
  entitlement = {route = {"grant"}, needs = {"sourceInstanceId"}},
  -- a charge a shift sponsor may cover; the registered service and payer owners define the coverage policy
  service = {route = {"payment.pay"}},
}

-- Descriptors remain plain data so callers can attach them to existing rows.
function money.describe(fields)
  if type(fields) ~= "table" then return nil, "fields required" end
  local spec = money.KINDS[fields.kind]
  if not spec then return nil, "unknown kind " .. tostring(fields.kind) end
  for _, name in ipairs(spec.needs or {}) do
    if fields[name] == nil or fields[name] == "" then return nil, fields.kind .. " needs " .. name end
  end
  local route = {}
  for i, step in ipairs(spec.route) do route[i] = step end
  return {kind = fields.kind, domain = fields.domain, sourceInstanceId = fields.sourceInstanceId,
    accountId = fields.accountId, payer = fields.payer, sponsor = fields.sponsor,
    category = fields.category, route = route}
end

-- Entitlements: pending -> granted | failed; a failed entitlement stays failed.
money.ENTITLEMENT_STATES = {pending = true, granted = true, failed = true}
local allowedEntitlementTransitions = {pending = {granted = true, failed = true}, granted = {}, failed = {}}

-- fields: kind ("vehicle"), domain, sourceInstanceId, resultId, detail (model, config, value...).
function money.newEntitlement(fields)
  if type(fields) ~= "table" or type(fields.kind) ~= "string" or fields.kind == "" then return nil, "kind required" end
  if fields.sourceInstanceId == nil then return nil, "sourceInstanceId required" end
  local detail = {}
  for key, value in pairs(fields.detail or {}) do detail[key] = value end
  return {kind = fields.kind, domain = fields.domain, sourceInstanceId = fields.sourceInstanceId,
    resultId = fields.resultId, detail = detail, state = "pending"}
end

-- Moves an entitlement to `state`; returns true, or false and a reason.
function money.transitionEntitlement(entitlement, state)
  if not money.ENTITLEMENT_STATES[state] then return false, "unknown state " .. tostring(state) end
  if not allowedEntitlementTransitions[entitlement.state][state] then return false, entitlement.state .. " -> " .. state .. " not allowed" end
  entitlement.state = state
  return true
end


local RECENT_LIMIT = 16

-- Paid flows select their existing route through Ledger settlement; the facades keep the single authority posting.
M.money = money

local recent = {}

local function remember(operation)
  recent[#recent + 1] = operation
  if #recent > RECENT_LIMIT then table.remove(recent, 1) end
end

-- Returns the call's results after recording the outcome: false refuses the operation, anything else commits it.
local function finish(operation, okState, failState, ...)
  M.transition(operation, (...) == false and failState or okState)
  return ...
end

-- spec: amount, payer, sponsor, target, label, tags, lines.
function M.begin(flow, spec)
  spec = spec or {}
  local priced = M.captureQuote({flow = flow, amount = spec.amount, lines = spec.lines})
  local operation = M.newOperation({
    flow = flow,
    quoteId = priced.id,
    amount = priced.amount,
    payer = spec.payer,
    sponsor = spec.sponsor,
    target = spec.target,
    label = spec.label,
    tags = spec.tags,
  })
  operation.quote = priced
  remember(operation)
  return operation
end

-- Runs the flow's payment call; a nil operation just makes the call.
function M.settle(operation, charge, ...)
  if not operation then return charge(...) end
  M.transition(operation, M.STATE.PENDING)
  return finish(operation, M.STATE.COMMITTED, M.STATE.REFUSED, charge(...))
end

-- A refused refund leaves compensation failed while callback errors propagate unchanged.
function M.compensate(operation, refund, ...)
  if not operation then return refund(...) end
  M.transition(operation, M.STATE.COMPENSATING)
  return finish(operation, M.STATE.COMPENSATED, M.STATE.FAILED, refund(...))
end

-- Operations created recently, oldest first, for diagnostics and tests.
function M.recent()
  return recent
end

return M
