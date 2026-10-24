-- Company logistics employment: the named contract a discovered (add-on) job kind gets in its handler context.
-- An add-on reaches employment only through this contract, never through its internal state.
local part = {}

local function finite(value)
  return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

-- Per-instance state shared by the groups below: contract lifetime, pay policy, contexts, load progress.
local function newContractState()
  return {
    lifetime = {alive = true},
    payPolicyByShift = setmetatable({}, {__mode = 'k'}),
    tokenByContext = setmetatable({}, {__mode = 'k'}),
    restoredShift = nil,
    loadSettled = false,
    awaitingKindShift = nil,
    reconcileTarget = nil,
  }
end

-- A token belongs to one shift record; an unbound token refuses everything.
local function newWageTokens(inputs, contracts)
  local shared, state, lifecycle, M = inputs.shared, inputs.state, inputs.lifecycle, inputs.M

  -- Pay policy is read once per shift record, so a manifest change mid-shift cannot move held pay to the wallet.
  local function bindToken(token, shift)
    if token.shift or token.dead then return end
    if type(shift) ~= 'table' or shift.jobKind ~= token.kindId then token.dead = true return end
    if contracts.payPolicyByShift[shift] == nil then
      local kind = shared.kindDefinition(token.kindId)
      contracts.payPolicyByShift[shift] = kind and kind.payModel and kind.payModel.heldWages == true and 'held' or 'wallet'
    end
    token.shift = shift
  end

  local function newToken(kindId, shift)
    local token = {kindId = kindId, lifetime = contracts.lifetime}
    if shared.kindDefinition(kindId) == nil then token.dead = true end
    if shift then bindToken(token, shift) end
    return token
  end

  -- An unbound token's shift is nil, which never equals a running shift.
  local function current(token, fresh)
    return not token.dead and token.lifetime == contracts.lifetime and contracts.lifetime.alive
      and rawget(_G, 'overhaul_career_work_employment') == M
      and state.shift == token.shift and lifecycle.isOnShift() == true
      and not shared.kindUnavailable(token.shift, fresh)
  end

  return {bind = bindToken, create = newToken, current = current}
end

-- The wage handle a kind pays through; deposits check the token is still current before paying.
local function newWageHandles(inputs, contracts, tokens)
  local shared, settlement, persistence, projections = inputs.shared, inputs.settlement, inputs.persistence, inputs.projections

  local function newWages(token)
    local wages = {}
    function wages.isCurrent() return tokens.current(token) end
    function wages.held() return tokens.current(token) and settlement.escrowKeepSum() or 0 end
    function wages.deposit(label, gross, opts)
      opts = opts or {}
      if not tokens.current(token, true) then return nil, 'the shift this wage handle belongs to has ended' end
      if not finite(gross) or gross < 0 then return nil, 'gross must be a finite nonnegative number' end
      local share = opts.companyShare
      if share == nil then share = projections.getCompanyShare() end
      if not finite(share) or share < 0 or share > 1 then return nil, 'companyShare must be a number between 0 and 1' end
      if opts.tags ~= nil and type(opts.tags) ~= 'table' then return nil, 'tags must be a list' end
      label = type(label) == 'string' and label ~= '' and label or 'Shift pay'
      local amount = shared.roundMoney(gross * (1 - share))
      if amount == 0 then return 0 end
      if contracts.payPolicyByShift[token.shift] == 'held' then
        -- A contract leg always carries a tag list (maybe empty): End Day then posts the kind's tags instead of employment's delivery tag.
        if settlement.addEscrowKeep(label, gross, share, token.kindId, opts.tags or {}) ~= amount then return nil, 'held wages refused the deposit' end
        persistence.flushEmploymentCache()
        projections.notifyUi()
        return amount
      end
      local paid, problem = overhaul_career_economy_payment.payout(require("overhaul/lib/finance/metadata").tagPayout({amount = amount, label = label, tags = settlement.kindEarningTags(opts.tags)}, "activity:" .. token.kindId))
      if paid ~= true then return nil, problem or 'the payout was refused' end
      return amount
    end
    return wages
  end

  return newWages
end

local function addLifetimeApi(api, contracts)
  api.endKindContracts = function()
    contracts.lifetime.alive = false
    contracts.lifetime = {alive = true}
  end
end

-- Employment binds a context's token to the shift record it creates; a settled start binds or kills it.
local function addBindingApi(api, inputs, contracts, tokens)
  local state = inputs.state

  api.bindContextShift = function(kindContext, shift)
    local token = contracts.tokenByContext[kindContext]
    if token then tokens.bind(token, shift) end
  end
  -- Once the assignment start is over: to the shift that start created, or not at all (the start failed), which kills the token.
  api.settleContextStart = function(kindContext, started)
    local token = contracts.tokenByContext[kindContext]
    if not token or token.shift or token.dead then return end
    if started and state.shift and state.shift.jobKind == token.kindId then tokens.bind(token, state.shift)
    else token.dead = true end
  end
end

-- Adds the add-on part to handler context ctx for kind kindId. shift binds the wage token at once (a restored or running shift); without it the token waits for the start to bind or settle it.
local function addContextApi(api, inputs, contracts, tokens, newWages)
  local shared, state, projections = inputs.shared, inputs.state, inputs.projections

  api.addKindContract = function(kindContext, kindId, shift)
    local token = tokens.create(kindId, shift)
    local definition = shared.kindDefinition(kindId)
    contracts.tokenByContext[kindContext] = token
    kindContext.kind = definition and deepcopy(definition) or nil
    kindContext.wages = newWages(token)
    kindContext.shift = function() return tokens.current(token) and deepcopy(state.shift) or nil end
    kindContext.setGuidance = function(label, subtext)
      if not tokens.current(token) or type(label) ~= 'string' or label == '' then return false end
      state.shift.outboundLabel, state.shift.outboundSubtext = label, subtext
      projections.refreshTaskGuidance(true)
      return true
    end
    return kindContext
  end
end

-- Restoring: a kind's restoreShift(shift, ctx) runs once per shift and availability, after a load reconciles the shift and after its kind comes back. It gets a copy of the shift and a fresh contract. An error in the add-on is logged; employment's own restore (guidance, UI) still finishes.
local function addRestoreApi(api, inputs, contracts)
  local shared, state, assignment, LOG_TAG = inputs.shared, inputs.state, inputs.assignment, inputs.LOG_TAG

  api.restoreKindShift = function()
    local shift = state.shift
    if not shift or contracts.restoredShift == shift or shared.kindUnavailable(shift) then return end
    local kind = shared.kindDefinition(shift.jobKind)
    if not (kind.handlers and kind.handlers.restoreShift) then return end
    contracts.restoredShift = shift
    local generator = shared.generator()
    local fac = generator and generator.getFacilityById(shift.originFacId) or nil
    local kindContext = assignment.kindContext(shift.originFacId, fac, nil, shift.jobKind, shift)
    local ok, problem = pcall(shared.kindHandler, shift.jobKind, 'restoreShift', deepcopy(shift), kindContext)
    if not ok then log('E', LOG_TAG, 'restoreShift of kind ' .. tostring(shift.jobKind) .. ' failed: ' .. tostring(problem)) end
  end
end

-- The load's reconciliation job reports where it got to, so a retry knows whether the saved shift still needs reconciling (its kind was missing at load) or only its owner restored.
local function addLoadApi(api, inputs, contracts)
  local state = inputs.state

  api.kindLoadStarted = function() contracts.loadSettled = false end
  api.kindLoadAwaitingKind = function() contracts.loadSettled, contracts.awaitingKindShift = true, state.shift end
  api.kindLoadFinished = function() contracts.loadSettled, contracts.awaitingKindShift = true, nil end
  api.kindLoadTargetCurrent = function()
    local target = contracts.reconcileTarget
    contracts.reconcileTarget = nil
    return target == nil or target == state.shift
  end
end

-- A missing kind comes back: reconcile the saved shift it left waiting (once), or restore the owner of a shift that was running when the kind left. Both happen in queued work that checks it still has the same shift. A retry while the kind is not missing changes nothing, so repeated retries never rebind a restored shift or cancel its owner's work.
local function addRetryApi(api, inputs, contracts)
  local state, runtime, persistence, M = inputs.state, inputs.runtime, inputs.persistence, inputs.M

  api.retryMissingKind = function()
    local wasMissing = persistence.savedKindUnavailable()
    runtime.kindCatalog = nil
    local result = persistence.checkSavedKind()
    M.refreshKindActivities()
    if not wasMissing or not (result and result.status == 'available') or not contracts.loadSettled then return result end
    local shift = state.shift
    if shift == contracts.awaitingKindShift then
      contracts.awaitingKindShift = nil
      state.restoringFreight = (shift.freight or shift.plannerFreight) and true or nil
      contracts.reconcileTarget, runtime.loadedShiftReconciled = shift, nil
      M.onWorldReadyState(2)
    else
      -- The next frame: the kind's owner may still be loading from the same mod event.
      core_jobsystem.create(function(job)
        job.sleep(0)
        if rawget(_G, 'overhaul_career_work_employment') == M and state.shift == shift then api.restoreKindShift() end
      end)
    end
    return result
  end
end

-- Enabling or disabling a mod can add or remove kind manifests: read them again and republish the kind activities. A running shift whose kind is gone is suspended like a save loaded without its add-on (employment's update waits, held wages stay, End Day settles it), and every wage contract ends; when the kind comes back, the retry above resumes it. Outside a career only the cache is dropped (activation rebuilds both), so the mod manager's per-mod startup events do not rescan.
local function addKindsChangedApi(api, inputs, contracts)
  local shared, state, runtime, persistence, M = inputs.shared, inputs.state, inputs.runtime, inputs.persistence, inputs.M

  api.kindsChanged = function()
    runtime.kindCatalog = nil
    if not overhaul_career_career.isActive() then return end
    M.refreshKindActivities()
    local shift = state.shift
    if not shift then return end
    if shared.kindUnavailable(shift) then
      if not persistence.savedKindUnavailable() then
        persistence.checkSavedKind()
        api.endKindContracts()
        contracts.restoredShift = nil
      end
    elseif persistence.savedKindUnavailable() then
      api.retryMissingKind()
    end
  end
end

function part.new(inputs)
  local api = inputs.api or {}
  local contracts = newContractState()
  local tokens = newWageTokens(inputs, contracts)
  local newWages = newWageHandles(inputs, contracts, tokens)

  addLifetimeApi(api, contracts)
  addBindingApi(api, inputs, contracts, tokens)
  addContextApi(api, inputs, contracts, tokens, newWages)
  addRestoreApi(api, inputs, contracts)
  addLoadApi(api, inputs, contracts)
  addRetryApi(api, inputs, contracts)
  addKindsChangedApi(api, inputs, contracts)
  return api
end

return part
