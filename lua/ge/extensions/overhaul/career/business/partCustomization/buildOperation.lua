-- Business part build operation: one transaction per preview session. Acceptance only queues work; the final event owns completion.
-- Legacy preview/cart/tuning calls do not use this transaction or its vehicle command acknowledgements.
local installer = {}

function installer.new(inputs)
  local runtime = inputs.runtime
  local sharedParts = inputs.parts
  local owner = inputs.owner
  -- Real state: required on first use by useOwnedProtocol below.
  local callbacks, commands, lifecycle
  local TIMEOUT_SECONDS = 30
  local NONCE_HEX_LENGTH = 32
  local CHANNEL = 'businessBuildVehicleCommand'
  -- Do not advance the existing callback registry's initialization time on a legacy-only load.
  local function useOwnedProtocol()
    if callbacks then return end
    callbacks = require('overhaul/lib/vehicles/callbacks')
    commands = require('overhaul/lib/vehicles/vehicleCommands')
    lifecycle = require('overhaul/lib/lifecycle/host')
  end
  local function now() return os.clockhp and os.clockhp() or os.clock() end
  local function captureState(operation)
    operation.initialConfig = commands.luaLiteral(operation.session.initial.config)
    operation.previewConfig = commands.luaLiteral(operation.session.preview and operation.session.preview.config)
  end

  local function result(businessId, vehicleId, operationId, success, reason, requestId)
    guihooks.trigger('businessComputer:onBuildOperationCompleted', {
      businessId = businessId, vehicleId = vehicleId, operationId = operationId,
      success = success, reason = reason, requestId = requestId, nonce = operationId,
    })
  end

  local function settle(operation, success, reason)
    if operation.settled then return end
    operation.settled, operation.cancelled, operation.success = true, true, success
    if operation.command then callbacks.close(operation.command.requestId) end
    if operation.requestId then callbacks.close(operation.requestId) end
    operation.command = nil
    lifecycle.done(operation.host)
    local session = operation.session
    if session.buildOperation == operation then
      session.buildOperation = nil
      session.operationInProgress = false
      session.resetInProgress = false
    end
    result(operation.businessId, operation.vehicleId, operation.operationId, success, reason, operation.requestId)
  end

  local function ownerMatches(operation)
    local session = operation.session
    local vehObj = sharedParts.baseline.getBusinessVehicleObject(operation.businessId, operation.vehicleId)
    local current = inputs.isOwnerCurrent() and runtime.currentSession == session
      and session.buildOperation == operation and session.initial == operation.initial
      and commands.luaLiteral(session.initial.config) == operation.initialConfig
      and commands.luaLiteral(session.preview and session.preview.config) == operation.previewConfig
      and tostring(session.businessId) == tostring(operation.businessId)
      and tostring(session.vehicleId) == tostring(operation.vehicleId)
      and vehObj == operation.vehicleObject and vehObj:getID() == operation.vehId
      and callbacks.getVehicleGeneration(operation.vehId) == operation.vehicleGeneration
      and lifecycle.isCurrent(operation.host) and now() < operation.deadline
    return current == true
  end

  local function isCurrent(operation)
    if operation.settled then return false end
    local ok, current = pcall(ownerMatches, operation)
    if not ok then
      log('E', 'businessBuild', tostring(current))
      settle(operation, false, tostring(current))
    elseif not current then
      settle(operation, false, 'Build owner changed or timed out')
    end
    return ok and current == true
  end

  local function protect(operation, fn)
    return function(...)
      if not isCurrent(operation) then return end
      local ok, err = pcall(fn, ...)
      if not ok then
        log('E', 'businessBuild', tostring(err))
        settle(operation, false, tostring(err))
      end
    end
  end

  -- The reply is in the mutation body itself. A later independent ping cannot prove that body succeeded.
  local function vehicleCommand(operation, vehObj, body, onDone)
    if not isCurrent(operation) then return end
    assert(not operation.command, 'A build vehicle command is already pending')
    local requestId = callbacks.open(CHANNEL, {
      owner = owner, vehId = vehObj:getID(), timeout = TIMEOUT_SECONDS,
      endsWith = {'career', 'map', 'profile'},
      onFail = function(_, reason) settle(operation, false, reason) end,
    })
    assert(requestId, 'Build callback declaration is unavailable')
    operation.command = {requestId = requestId, onDone = protect(operation, onDone)}
    -- command dispatches the declared receiver without consuming the request; that receiver authenticates before reply.
    local replyArgs = requestId .. ',' .. operation.requestId .. ','
      .. commands.luaLiteral(operation.operationId) .. ',' .. commands.luaLiteral(operation.nonce)
    vehObj:queueLuaCommand('local ok,value=pcall(function() ' .. body .. ' end)\nif not ok then value=tostring(value) end\n'
      .. "obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('businessBuildVehicleCommand',"
      .. commands.luaLiteral(replyArgs) .. "..','..tostring(ok)..','..serialize(value)))")
  end

  local function onBuildVehicleCommandResult(requestId, buildRequestId, operationId, nonce, success, value)
    local operation = runtime.currentSession and runtime.currentSession.buildOperation
    local command = operation and operation.command
    if not command or command.requestId ~= requestId or operation.requestId ~= buildRequestId or operation.operationId ~= operationId
      or operation.nonce ~= nonce then return false end
    if not isCurrent(operation) then return false end
    if not command.dispatching then
      if not callbacks.getPending(requestId) then return false end
      -- Authenticate before the generic registry consumes the token. Its token can repeat in a fresh Lua VM.
      command.dispatching = true
      local ok, err = pcall(callbacks.reply, requestId, CHANNEL, requestId, buildRequestId, operationId, nonce, success, value)
      command.dispatching = false
      if not ok then
        log('E', 'businessBuild', tostring(err))
        settle(operation, false, tostring(err))
      end
      return ok
    end
    operation.command = nil
    if not isCurrent(operation) then return end
    if success ~= true then settle(operation, false, tostring(value)); return end
    command.onDone(value)
  end

  local function readFuel(operation, vehObj, onDone)
    vehicleCommand(operation, vehObj, [[
      local storages=energyStorage.getStorages()
      assert(type(storages)=="table","Fuel read failed")
      local tanks={}
      for name,storage in pairs(storages) do
        tanks[#tanks+1]={name=name,energyType=storage.energyType,currentEnergy=storage.storedEnergy,maxEnergy=storage.energyCapacity}
      end
      return tanks
    ]], function(tanks)
      assert(type(tanks) == 'table', 'Fuel read failed')
      onDone(tanks)
    end)
  end

  local function fuelSnapshot(tanks)
    local stored = {}
    for _, tank in ipairs(tanks) do
      if tank.energyType ~= 'n2o' then stored[tank.name] = deepcopy(tank) end
    end
    return stored
  end

  local function fuelRestoreBody(stored, tanks, relative)
    local actions = {}
    for _, tank in ipairs(tanks) do
      local old = stored[tank.name]
      if old and old.energyType == tank.energyType and tank.energyType ~= 'n2o' then
        local fraction = old.maxEnergy > 0 and old.currentEnergy / old.maxEnergy or 0
        local amount = math.min(old.currentEnergy, tank.maxEnergy)
        if relative or tank.maxEnergy > old.maxEnergy then amount = fraction * tank.maxEnergy end
        if not relative then amount = math.max(amount, tank.maxEnergy * 0.05) end
        actions[#actions + 1] = 'local tank=assert(energyStorage.getStorage(' .. commands.luaLiteral(tank.name)
          .. '),"Fuel storage disappeared"); tank.storedEnergy=' .. commands.luaLiteral(amount)
      end
    end
    return table.concat(actions, '\n')
  end

  local function chosenPart(node)
    local name = node and node.chosenPartName or ''
    return name == 'none' and '' or name
  end

  local function declaredDefault(ioCtx, parentPart, slotId)
    if not ioCtx or parentPart == '' then return nil end
    local part = inputs.jbeamIO.getPart(ioCtx, parentPart)
    for _, slot in ipairs(part and (part.slots2 or part.slots) or {}) do
      if (slot.name or slot.type) == slotId then return slot.default end
    end
    return nil
  end

  -- Stock adds empty slot records and resolves omitted slots from JBeam defaults. Metadata alone is not a chosen part.
  local function partsMatch(expected, actual, ioCtx)
    if chosenPart(expected) ~= chosenPart(actual) then return false end
    for slot, child in pairs(expected and expected.children or {}) do
      if not partsMatch(child, actual and actual.children and actual.children[slot], ioCtx) then return false end
    end
    for slot, child in pairs(actual and actual.children or {}) do
      if not (expected and expected.children and expected.children[slot]) then
        local wanted
        if chosenPart(child) ~= '' then
          local default = declaredDefault(ioCtx, chosenPart(expected), slot)
          if child.decisionMethod ~= 'default' or chosenPart(child) ~= default then return false end
          wanted = {chosenPartName = default}
        end
        if not partsMatch(wanted, child, ioCtx) then return false end
      end
    end
    return true
  end

  local function configurationMatches(vehObj, config)
    local data = extensions.core_vehicle_manager.getVehicleData(vehObj:getID())
    local actual = data and data.config
    return actual and actual.partsTree and actual.partsTree.chosenPartName ~= ''
      and partsMatch(config.partsTree, actual.partsTree, data.ioCtx)
      and commands.luaLiteral(config.vars or {}) == commands.luaLiteral(actual.vars or {})
  end

  local function replace(operation, vehObj, model, config, conditions, relative, onDone)
    assert(vehObj and model and config, 'Invalid build replacement')
    sharedParts.conditions.capture(operation.session, protect(operation, function(ready)
    assert(ready, 'Condition capture failed')
    if relative then conditions = sharedParts.conditions.forConfig(operation.session, config) end
    readFuel(operation, vehObj, function(tanks)
      local stored = fuelSnapshot(tanks)
      core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = false}, vehObj:getID())
      assert(core_vehicles.replaceVehicle(model, {config = config, keepOtherVehRotation = true}, vehObj) ~= false,
        'Build replacement refused')
      local live = assert(sharedParts.baseline.getBusinessVehicleObject(operation.businessId, operation.vehicleId), 'Build vehicle disappeared')
      operation.vehicleObject, operation.vehId = live, live:getID()
      operation.vehicleGeneration = callbacks.getVehicleGeneration(operation.vehId)
      local claim = operation.session.ownedBuildClaim
      if claim and claim.nonce == operation.nonce then claim.vehicleId = operation.vehId end
      vehObj = live
      readFuel(operation, vehObj, function(newTanks)
        assert(configurationMatches(vehObj, config), 'Build parts or variables did not load as requested')
        local body = fuelRestoreBody(stored, newTanks, relative)
        if conditions then
          local policy = require('overhaul/lib/business/partConditions')
          local sanitized = policy.sanitizePartConditions(conditions, sharedParts.preview.getPartConditionApplyOpts(config))
          body = 'assert(partCondition.initConditions(' .. commands.luaLiteral(sanitized)
            .. ',0,1,1) ~= false,"Condition restoration refused")\n' .. body
        end
        vehicleCommand(operation, vehObj, body, onDone)
      end)
    end)
    end))
  end

  local function transactionFor(operation)
    operation.ownedBuild = true
    operation.guard = function(fn) return protect(operation, fn) end
    operation.fail = function(reason) settle(operation, false, reason) end
    operation.isCurrent = function() return isCurrent(operation) end
    operation.captureState = function() captureState(operation) end
    operation.baselineMatches = configurationMatches
    operation.vehicleCommand = function(vehObj, body, onDone) vehicleCommand(operation, vehObj, body, onDone) end
    operation.replace = function(vehObj, model, config, beforeRestore, afterRestore)
      assert(beforeRestore == nil, 'Owned replacement requires acknowledged conditions')
      replace(operation, vehObj, model, config, nil, false, afterRestore)
    end
    operation.replaceBaseline = function(vehObj, model, config, conditions, afterRestore)
      replace(operation, vehObj, model, config, conditions, false, afterRestore)
    end
    operation.replaceTuning = function(vehObj, model, config, afterRestore)
      operation.session.operationInProgress = true
      replace(operation, vehObj, model, config, nil, true, afterRestore)
    end
    operation.reinitializeConditions = function(vehObj, conditions, config, onDone)
      local policy = require('overhaul/lib/business/partConditions')
      local sanitized = policy.sanitizePartConditions(conditions, sharedParts.preview.getPartConditionApplyOpts(config))
      vehicleCommand(operation, vehObj, 'assert(partCondition.initConditions(' .. commands.luaLiteral(sanitized) .. ',0,1,1) ~= false,'
        .. '"Condition initialization refused"); return partCondition.getConditions()', function(fresh)
        assert(type(fresh) == 'table', 'Condition read failed')
        onDone(fresh)
      end)
    end
    return operation
  end

  local function beginOperation(businessId, vehicleId, session, vehObj, operationId)
    local operation = {session = session, initial = session.initial, businessId = businessId,
      vehicleId = vehicleId, vehId = vehObj:getID(), vehicleObject = vehObj,
      vehicleGeneration = callbacks.getVehicleGeneration(vehObj:getID()),
      operationId = operationId, nonce = operationId, deadline = now() + TIMEOUT_SECONDS}
    captureState(operation)
    session.buildOperation = operation
    local opened, openError = pcall(function()
      operation.host = lifecycle.track(owner, {'career', 'map', 'profile'}, {
        onEnded = function(_, scope) settle(operation, false, scope .. ' changed') end,
      })
      operation.requestId = callbacks.open(CHANNEL, {
        -- The operation intentionally replaces vehicles. Individual query/command tokens bind the current generation.
        owner = owner, timeout = TIMEOUT_SECONDS,
        endsWith = {'career', 'map', 'profile'},
        onFail = function(_, reason) settle(operation, false, reason) end,
      })
      assert(operation.requestId, 'Build callback declaration unavailable')
    end)
    if not opened then
      log('E', 'businessBuild', tostring(openError))
      settle(operation, false, tostring(openError))
      return nil
    end
    return operation
  end

  local function applyBuildToVehicle(businessId, vehicleId, build, operationId)
    if type(operationId) ~= 'string' or #operationId ~= NONCE_HEX_LENGTH or not operationId:match('^%x+$')
      or type(build) ~= 'table' then return false end
    useOwnedProtocol()
    local session = sharedParts.preview.ensureActiveSession(businessId, vehicleId)
    if not session or session.operationInProgress or session.buildOperation then
      result(businessId, vehicleId, operationId, false, 'Preview session is unavailable or busy')
      return false
    end
    local vehObj = sharedParts.baseline.getBusinessVehicleObject(businessId, vehicleId)
    if not vehObj then result(businessId, vehicleId, operationId, false, 'Vehicle unavailable'); return false end
    local operation = beginOperation(businessId, vehicleId, session, vehObj, operationId)
    if not operation then return false end
    local transaction = transactionFor(operation)
    local function complete(ok)
      if ok ~= true then settle(operation, false, 'Build action refused'); return end
      settle(operation, true)
    end
    local tune = protect(operation, function(ok)
      if ok ~= true then complete(false); return end
      if build.tuning == nil then complete(true); return end
      if overhaul_career_business_vehicleTuning.applyTuningToVehicle(businessId, vehicleId, build.tuning, transaction.guard(complete), transaction) ~= true then
        complete(false)
      end
    end)
    local parts = protect(operation, function(ok)
      if ok ~= true then complete(false); return end
      if build.parts == nil then tune(true); return end
      if sharedParts.cart.applyCartPartsToVehicle(businessId, vehicleId, build.parts, tune, transaction) ~= true then complete(false) end
    end)
    protect(operation, function()
      if not build.reset then parts(true); return end
      if sharedParts.preview.resetVehicleToOriginal(businessId, vehicleId, parts, transaction) ~= true then complete(false) end
    end)()
    local accepted = not operation.settled or operation.success == true
    if accepted then
      -- A session lifetime fact, including after cancellation; it is never reused as a completion result.
      session.ownedBuildClaim = {vehicleId = operation.vehId, nonce = operation.nonce, epochs = lifecycle.epochs()}
    end
    return {accepted = accepted, requestId = operation.requestId, nonce = operation.nonce}
  end

  local function cancelBuildOperation(businessId, vehicleId, operationId, requestId, nonce)
    local operation = runtime.currentSession and runtime.currentSession.buildOperation
    if not operation or operation.businessId ~= businessId or tostring(operation.vehicleId) ~= tostring(vehicleId)
      or operation.operationId ~= operationId or operation.requestId ~= requestId or operation.nonce ~= nonce then return false end
    settle(operation, false, 'Build cancelled')
    return true
  end

  local function cancelCurrent(reason)
    local operation = runtime.currentSession and runtime.currentSession.buildOperation
    if operation then settle(operation, false, reason or 'Build owner closed') end
  end

  -- Old continuations ask the currently loaded public owner, including after a module replacement.
  local function hasNewerOwnedPreviewForVehicle(oldSession, vehObj, oldClaim)
    local current = runtime.currentSession
    local claim = current and current.ownedBuildClaim
    if not inputs.isOwnerCurrent() or not claim or not vehObj then return false end
    local epochs = lifecycle.epochs()
    for scope, epoch in pairs(claim.epochs) do if epochs[scope] ~= epoch then return false end end
    if current == oldSession and claim == oldClaim then return false end
    return claim.vehicleId == vehObj:getID()
  end

  return {
    applyBuildToVehicle = applyBuildToVehicle, cancelBuildOperation = cancelBuildOperation,
    onBuildVehicleCommandResult = onBuildVehicleCommandResult, cancelCurrent = cancelCurrent,
    hasNewerOwnedPreviewForVehicle = hasNewerOwnedPreviewForVehicle,
    onUpdate = function()
      local operation = runtime.currentSession and runtime.currentSession.buildOperation
      if operation then isCurrent(operation) end
    end,
  }
end

return installer
