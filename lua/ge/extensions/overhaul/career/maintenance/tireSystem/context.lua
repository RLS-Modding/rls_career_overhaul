-- Tyre context: reads each vehicle's wheel state, pushes the weather, ground and wear context to the vehicle, and tracks the business, inspection, burnout and dyno owners that change what a vehicle is allowed to show.
-- Map: Vehicle state reports; Weather, ground and ambient; Trailers and towing; Part index; Signature trace; Personal contexts; Dyno sessions; Public API.

local partFactory = {}
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")
local capabilities = require("overhaul/lib/platform/capabilities")

-- Built by tireSystem.lua with the shared state, sibling helpers and dependencies.
function partFactory.new(inputs)
  local tireState = inputs.state
  local commandPayloads = inputs.commandPayloads

  -- Vehicle state reports ---------------------------------------------------------------------------

  -- Stores one reported wheel. Returns the stored wheel, and whether the state had to be created (a correction).
  local function storeReportedWheel(vehicleData, owner, inventoryId, reported)
    local partId, part
    if owner.kind == "personal" then
      partId, part = inputs.findPersonalPart(inventoryId, reported.partPath, reported.partOrigin, reported.containingSlot)
    end
    local storedWheel
    local created
    if part then
      storedWheel, _, created = inputs.ensurePartWheelState(part, reported.name, vehicleData)
    else
      local path = reported.partPath or reported.partOrigin or ("wheel:" .. tostring(reported.name))
      local conditionOdometer = vehicleData.partConditions and vehicleData.partConditions[path] and
                                  tonumber(vehicleData.partConditions[path].odometer) or nil
      local fallbackMiles = conditionOdometer ~= nil and conditionOdometer * inputs.metersToMiles or
                              (tonumber(vehicleData.mileage) or 0) * inputs.metersToMiles
      storedWheel, _, created = inputs.ensureVehicleFallbackState(vehicleData, path, reported.name,
        inputs.tireModel.remainingFromMiles(fallbackMiles))
    end
    if not created then
      storedWheel.remaining = inputs.tireModel.clamp(reported.remaining, 0, 1)
      storedWheel.flat = reported.flat == true
    end
    return storedWheel, partId, part, created
  end

  -- One layout row for a reported wheel, after its stored state has been updated.
  local function layoutRowFor(reported, storedWheel, partId, part)
    if type(reported.temperature) == "table" then
      storedWheel.temperature = inputs.deepCopy(reported.temperature)
    end
    if reported.pressure ~= nil then
      storedWheel.pressure = tonumber(reported.pressure)
    end
    return {
      name = tostring(reported.name),
      partId = partId,
      partPath = reported.partPath or (part and part.partPath),
      partOrigin = reported.partOrigin or (part and part.name),
      containingSlot = (part and part.containingSlot) or reported.containingSlot,
      width = tonumber(reported.width),
      remaining = storedWheel.remaining,
      flat = storedWheel.flat,
      temperature = inputs.deepCopy(storedWheel.temperature),
      pressure = tonumber(storedWheel.pressure),
    }
  end

  local function resolveStateOwner(vehId)
    local owner = inputs.runtimeOwnersByVehId[vehId]
    if not owner then
      local inventoryId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId) or nil
      if inventoryId then owner = {kind = "personal", inventoryId = tonumber(inventoryId)} end
    end
    return owner
  end

  -- Applies the provider and the reported wheels to the stored state, then sends a fresh context if the state was corrected.
  function inputs.M.receiveVehicleState(vehId, payload)
    if type(payload) ~= "table" then
      return false
    end
    vehId = tonumber(vehId)
    local owner = resolveStateOwner(vehId)
    local inventoryId = owner and owner.inventoryId or nil
    local vehicleData = owner and owner.kind == "business" and
                          inputs.businessVehicleData(owner.businessId, owner.vehicleId) or
                          (inventoryId and inputs.vehicleDataForInventory(inventoryId) or nil)
    if not vehicleData then
      return false
    end
    local providerChanged = false
    if type(payload.provider) == "table" then
      local previousProvider = serialize(vehicleData.overhaulTires)
      local nextProvider = serialize(payload.provider)
      providerChanged = previousProvider ~= nextProvider
      vehicleData.overhaulTires = inputs.deepCopy(payload.provider)
      inputs.showProviderNotice(payload.provider)
    end
    local persistenceEnabled = (inputs.isMaintenanceEnabled() or
      (owner.kind == "personal" and inputs.burnoutOverrides[tonumber(inventoryId)] == true)) and
      not (owner.kind == "personal" and inputs.dynoOverrides[tonumber(inventoryId)] == true)
    if not persistenceEnabled then
      if providerChanged then inputs.markOwnerDirty(owner) end
      return true
    end

    local previousSignature = inputs.currentTireSignature(vehicleData)
    local layout = {schemaVersion = 1, wheels = {}}
    local stateCorrectionNeeded = false
    for _, reported in ipairs(payload.wheels or {}) do
      if type(reported) == "table" and reported.name then
        local storedWheel, partId, part, created = storeReportedWheel(vehicleData, owner, inventoryId, reported)
        if created then stateCorrectionNeeded = true end
        table.insert(layout.wheels, layoutRowFor(reported, storedWheel, partId, part))
      end
    end
    if #layout.wheels > 0 then
      table.sort(layout.wheels, function(a, b) return a.name < b.name end)
      vehicleData.rlsTireLayout = layout
    end

    local changed = previousSignature ~= inputs.currentTireSignature(vehicleData)
    changed = inputs.maybeInvalidateInspection(vehicleData) or changed
    if changed or providerChanged then inputs.markOwnerDirty(owner) end
    if stateCorrectionNeeded then
      local revisionKey = owner.kind == "business" and
                            ("b:" .. tostring(owner.businessId) .. ":" .. tostring(owner.vehicleId)) or
                            tonumber(inventoryId)
      inputs.partRevisions[revisionKey] = (tonumber(inputs.partRevisions[revisionKey]) or 0) + 1
      if owner.kind == "business" then
        inputs.M.sendContextForBusinessVehicle(owner.businessId, owner.vehicleId, true)
      else
        inputs.M.sendContextForVehicle(vehId, true)
      end
    end
    return true
  end

  -- Weather, ground and ambient ---------------------------------------------------------------------

  -- core_environment is per-level; inspection and context cleanup can run outside a level.
  local function getAmbientTemperature()
    if core_environment then
      return (tonumber(core_environment.getTemperatureK()) or 294.15) - 273.15
    end
    return 21
  end

  local function getGroundModels()
    local source = core_environment and core_environment.groundModels or nil
    if tireState.groundModelsCache and tireState.groundModelsCacheSource == source then
      return tireState.groundModelsCache
    end
    local result = {}
    for name, model in pairs(source or {}) do
      local cdata = model and model.cdata or {}
      result[tostring(name)] = {
        staticFrictionCoefficient = tonumber(cdata.staticFrictionCoefficient) or 1,
        slidingFrictionCoefficient = tonumber(cdata.slidingFrictionCoefficient) or 1,
      }
    end
    tireState.groundModelsCache = result
    tireState.groundModelsCacheSource = source
    return tireState.groundModelsCache
  end

  -- Missing weather fields leave the road dry and keep the standard grip multipliers.
  local function getTireWeatherState()
    local result = {
      roadWetness = 0,
      wetGripMultipliers = {standard = 1.00, sport = 0.94, race = 0.80, drag = 0.72},
      wetGroundModels = {},
    }
    local reported = overhaul_world_weather.getTireWeatherState()
    if type(reported) ~= "table" then return result end
    result.roadWetness = inputs.round(inputs.tireModel.clamp(reported.roadWetness, 0, 1), 2)
    if type(reported.wetGripMultipliers) == "table" then
      for compound, fallback in pairs(result.wetGripMultipliers) do
        result.wetGripMultipliers[compound] = inputs.tireModel.clamp(
          tonumber(reported.wetGripMultipliers[compound]) or fallback, 0.10, 1)
      end
    end
    if type(reported.wetGroundModels) == "table" then
      for name, affected in pairs(reported.wetGroundModels) do
        if affected == true then result.wetGroundModels[tostring(name)] = true end
      end
    end
    return result
  end

  local function addTireWeatherContext(context)
    local weather = getTireWeatherState()
    context.roadWetness = weather.roadWetness
    context.wetGripMultipliers = weather.wetGripMultipliers
    context.wetGroundModels = weather.wetGroundModels
    return context
  end

  -- Trailers and towing ----------------------------------------------------------------------------

  local modelTrailerCache = {}
  local function containsTrailer(value)
    if type(value) == "table" then
      for key, nested in pairs(value) do
        if containsTrailer(key) or containsTrailer(nested) then return true end
      end
      return false
    end
    return string.find(string.lower(tostring(value or "")), "trailer", 1, true) ~= nil
  end

  local function vehicleTypeIsTrailer(vehicleData)
    local modelKey = vehicleData and (vehicleData.model or vehicleData.model_key or
                       (vehicleData.vehicleConfig and vehicleData.vehicleConfig.model_key)) or nil
    if containsTrailer(vehicleData and (vehicleData.Type or vehicleData.type)) then return true end
    if not modelKey then return false end
    local cached = modelTrailerCache[modelKey]
    if cached == nil then
      local modelData = core_vehicles.getModel(modelKey) or nil
      local model = modelData and (modelData.model or modelData) or {}
      cached = containsTrailer(model.Type)
      modelTrailerCache[modelKey] = cached
    end
    return cached
  end

  local function isTowedChild(vehId)
    for _, connection in pairs(core_trailerRespawn and core_trailerRespawn.getTrailerData and
                                 core_trailerRespawn.getTrailerData() or {}) do
      if type(connection) == "table" and tonumber(connection.trailerId) == tonumber(vehId) then
        return true
      end
    end
    return false
  end

  -- Why a vehicle shows no tyre runtime: a trailer, a towed child, or a dyno session. Nil when it has none.
  local function excludedReasonFor(vehicleData, vehId)
    if vehicleTypeIsTrailer(vehicleData) then return "trailer" end
    if isTowedChild(vehId) then return "towed" end
    return nil
  end

  -- Part index ---------------------------------------------------------------------------------------

  -- Parts at the spawned vehicles' locations in inventory iteration order, rebuilt in reused lists for each sendAllContexts pass (nothing changes the inventory during a pass).
  local partLists = {}
  local partIndexWanted = {}

  local function buildPartIndex()
    for location, list in pairs(partLists) do
      if partIndexWanted[location] then table.clear(list) else partLists[location] = nil end
    end
    for location in pairs(partIndexWanted) do
      partLists[location] = partLists[location] or {}
    end
    for _, part in pairs(inputs.personalInventory()) do
      local list = part and partLists[tonumber(part.location)]
      if list then list[#list + 1] = part end
    end
    return partLists
  end

  local function partsForInventory(inventoryId, index)
    return index and index[tonumber(inventoryId)] or inputs.personalPartsAt(inventoryId)
  end

  local function buildInitialWheelState(inventoryId, vehicleData, partIndex)
    local result = {}
    if inventoryId ~= nil then
      local parts = partsForInventory(inventoryId, partIndex)
      for index = 1, #parts do
        local state = inputs.partState(parts[index])
        for wheelName, wheelState in pairs(state and state.wheels or {}) do
          result[wheelName] = inputs.deepCopy(wheelState)
        end
      end
    end
    for _, state in pairs(vehicleData.rlsTireStateByPartPath or {}) do
      for wheelName, wheelState in pairs(state and state.wheels or {}) do
        if not result[wheelName] then
          result[wheelName] = inputs.deepCopy(wheelState)
        end
      end
    end
    return result
  end

  -- Signature trace ----------------------------------------------------------------------------------

  -- Every input of a personal vehicle's context signature, in the order the signature build reads it. When this sequence (values, keys, lengths and iteration order) repeats, the rebuilt signature equals the stored one.
  local contextTraces = {}
  local NIL_VALUE, TABLE_END = {}, {}
  -- Position of the ambient temperature in the trace (see traceContextInputs). The initial wheel state is traced last, from initialFrom on, so with everything before it equal both traces start it at that index.
  local AMBIENT_SLOT = 6
  local trace, traceLength, traceSame, traceOtherSame, initialFrom, initialSame

  local function tracePut(value)
    if value == nil then value = NIL_VALUE end
    traceLength = traceLength + 1
    if trace[traceLength] ~= value then
      traceSame = false
      if initialFrom then
        initialSame = false
      elseif traceLength ~= AMBIENT_SLOT then
        traceOtherSame = false
      end
    end
    trace[traceLength] = value
  end

  local function traceTable(value)
    if type(value) ~= "table" then
      tracePut(value)
      return
    end
    tracePut(#value)
    tracePut(getmetatable(value))
    for key, nested in pairs(value) do
      tracePut(key)
      traceTable(nested)
    end
    tracePut(TABLE_END)
  end

  local function traceInitialState(inventoryId, vehicleData, partIndex)
    local parts = partsForInventory(inventoryId, partIndex)
    for index = 1, #parts do
      local state = inputs.partState(parts[index])
      traceTable(state and state.wheels or nil)
    end
    tracePut(TABLE_END)
    for _, state in pairs(vehicleData.rlsTireStateByPartPath or {}) do
      traceTable(state and state.wheels or nil)
    end
  end

  -- Records the context inputs in the vehicle's trace and reports whether they match the last configured context. Returns same, the trace entry, whether only the ambient temperature (and initial state) differs, and whether the initial state differs.
  local function traceContextInputs(vehId, inventoryId, vehicleData, partIndex, enabled, burnout, dyno, excludedReason,
                                    ambientTemperature, weather)
    local entry = contextTraces[vehId]
    if not entry then
      entry = {values = {}, length = 0}
      contextTraces[vehId] = entry
    end
    trace, traceLength = entry.values, 0
    traceSame = entry.signature ~= nil and entry.signature == inputs.lastContextSignatures[vehId]
    traceOtherSame, initialFrom, initialSame = traceSame, nil, true
    tracePut(inventoryId)
    tracePut(enabled)
    tracePut(burnout)
    tracePut(dyno)
    tracePut(excludedReason)
    tracePut(ambientTemperature)
    tracePut(weather.roadWetness)
    traceTable(weather.wetGripMultipliers)
    traceTable(weather.wetGroundModels)
    if enabled then
      initialFrom = traceLength + 1
      traceInitialState(inventoryId, vehicleData, partIndex)
    end
    local same = traceSame and traceLength == entry.length
    -- Every input but the temperature and the initial wheel state equals the last configured one.
    local otherSignatureInputsUnchanged = traceOtherSame and (initialFrom ~= nil or traceLength == entry.length)
    local initialChanged = initialFrom ~= nil and not (initialSame and traceLength == entry.length)
    for index = traceLength + 1, entry.length do trace[index] = nil end
    entry.length = traceLength
    trace, initialFrom = nil, nil
    return same, entry, otherSignatureInputsUnchanged, initialChanged
  end

  -- The context fields outside the signature, as last configured on each vehicle.
  local configuredRest = {}

  local function restMatches(rest, context)
    return rest ~= nil and rest.inventoryId == context.inventoryId and rest.maintenanceEnabled == context.maintenanceEnabled and
      rest.defaultRemaining == context.defaultRemaining and rest.groundModels == context.groundModels and
      rest.stateRevision == context.stateRevision and rest.apiVersion == context.apiVersion
  end

  local function ambientCommand(vehId, ambientTemperature, initialState)
    return "if not (overhaulTires and overhaulTires.setAmbientTemperature and " ..
      commandPayloads.ambientTemperature(ambientTemperature, initialState) .. ") then obj:queueGameEngineLua(require('vehicle/overhaul/geCallback')" ..
      ".command('sendContextForVehicle', '" .. tostring(vehId) .. ",true')) end"
  end

  -- Personal contexts --------------------------------------------------------------------------------

  -- Builds the context a personal vehicle is configured with: whether tyres run, the wear, and the weather.
  local function buildPersonalContext(inventoryId, vehicleData, partIndex, tireRuntimeEnabled, maintenanceEnabled,
                                      burnout, dyno, excludedReason, ambientTemperature, weather)
    local context = {
      apiVersion = 1,
      inventoryId = tonumber(inventoryId),
      enabled = tireRuntimeEnabled,
      maintenanceEnabled = maintenanceEnabled,
      burnoutOverride = burnout,
      dynoOverride = dyno,
      excludedReason = excludedReason,
      ambientTemperature = ambientTemperature,
      initialState = tireRuntimeEnabled and buildInitialWheelState(inventoryId, vehicleData, partIndex) or {},
      defaultRemaining = tireRuntimeEnabled and
        inputs.tireModel.remainingFromMiles((tonumber(vehicleData.mileage) or 0) * inputs.metersToMiles) or 1,
      groundModels = getGroundModels(),
      stateRevision = tonumber(inputs.partRevisions[tonumber(inventoryId)]) or 0,
    }
    context.roadWetness = weather.roadWetness
    context.wetGripMultipliers = weather.wetGripMultipliers
    context.wetGroundModels = weather.wetGroundModels
    return context
  end

  -- Sends a personal vehicle its context; ambient/initial-state-only changes use the short command.
  local function sendPersonalContext(vehId, force, partIndex)
    vehId = tonumber(vehId)
    local vehObj = vehId and getObjectByID(vehId) or nil
    local inventoryId = vehObj and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(vehId) or nil
    local vehicleData = inventoryId and inputs.vehicleDataForInventory(inventoryId) or nil
    if not vehObj or not vehicleData then
      return false
    end
    inputs.runtimeOwnersByVehId[vehId] = {kind = "personal", inventoryId = tonumber(inventoryId)}

    local excludedReason = excludedReasonFor(vehicleData, vehId)
    local burnout = inputs.burnoutOverrides[tonumber(inventoryId)] == true
    local dyno = inputs.dynoOverrides[tonumber(inventoryId)] == true
    if dyno then
      excludedReason = "dyno"
    end
    local tireRuntimeEnabled = (inputs.isMaintenanceEnabled() or burnout) and excludedReason == nil
    local maintenanceEnabled = inputs.isMaintenanceEnabled()
    local ambientTemperature = getAmbientTemperature()
    local weather = getTireWeatherState()
    local unchanged, traceEntry, otherSignatureInputsUnchanged, initialChanged = traceContextInputs(vehId,
      tonumber(inventoryId), vehicleData, partIndex, tireRuntimeEnabled, burnout, dyno, excludedReason, ambientTemperature, weather)
    if unchanged and not force then
      return true
    end
    local context = buildPersonalContext(inventoryId, vehicleData, partIndex, tireRuntimeEnabled, maintenanceEnabled,
      burnout, dyno, excludedReason, ambientTemperature, weather)
    local signature = serialize({context.enabled, context.burnoutOverride, context.dynoOverride,
      context.excludedReason, context.ambientTemperature, context.initialState, context.roadWetness,
      context.wetGripMultipliers, context.wetGroundModels})
    traceEntry.signature = signature
    if not force and inputs.lastContextSignatures[vehId] == signature then
      return true
    end
    inputs.lastContextSignatures[vehId] = signature
    -- Every other input equals the last configured context, so the vehicle only needs the temperature and, when it changed, the initial wheel state.
    if not force and otherSignatureInputsUnchanged and restMatches(configuredRest[vehId], context) then
      vehObj:queueLuaCommand(ambientCommand(vehId, context.ambientTemperature, initialChanged and context.initialState or nil))
      return true
    end
    configuredRest[vehId] = {inventoryId = context.inventoryId, maintenanceEnabled = context.maintenanceEnabled,
      defaultRemaining = context.defaultRemaining, groundModels = context.groundModels,
      stateRevision = context.stateRevision, apiVersion = context.apiVersion}
    vehObj:queueLuaCommand(inputs.configureProviderCommand(context))
    return true
  end

  function inputs.M.sendContextForVehicle(vehId, force)
    return sendPersonalContext(vehId, force)
  end

  -- Business, inspection and fresh-tyre contexts -----------------------------------------------------

  function inputs.M.sendContextForBusinessVehicle(businessId, vehicleId, force)
    local businessInventory = capabilities.get("businessVehicles")
    local vehId = businessInventory and businessInventory.getSpawnedVehicleId(businessId, vehicleId) or nil
    local vehObj = vehId and getObjectByID(vehId) or nil
    local vehicleData = inputs.businessVehicleData(businessId, vehicleId)
    if not vehObj or not vehicleData then return false end

    vehId = tonumber(vehId)
    inputs.runtimeOwnersByVehId[vehId] = {
      kind = "business",
      businessId = businessId,
      vehicleId = tonumber(vehicleId) or vehicleId,
    }
    local excludedReason = vehicleTypeIsTrailer(vehicleData) and "trailer" or (isTowedChild(vehId) and "towed" or nil)
    local revisionKey = "b:" .. tostring(businessId) .. ":" .. tostring(vehicleId)
    local tireRuntimeEnabled = inputs.isMaintenanceEnabled() and excludedReason == nil
    local context = addTireWeatherContext({
      apiVersion = 1,
      ownerKind = "business",
      businessId = businessId,
      businessVehicleId = tonumber(vehicleId) or vehicleId,
      enabled = tireRuntimeEnabled,
      maintenanceEnabled = inputs.isMaintenanceEnabled(),
      burnoutOverride = false,
      excludedReason = excludedReason,
      ambientTemperature = getAmbientTemperature(),
      initialState = tireRuntimeEnabled and buildInitialWheelState(nil, vehicleData) or {},
      defaultRemaining = tireRuntimeEnabled and
        inputs.tireModel.remainingFromMiles((tonumber(vehicleData.mileage) or 0) * inputs.metersToMiles) or 1,
      groundModels = getGroundModels(),
      stateRevision = tonumber(inputs.partRevisions[revisionKey]) or 0,
    })
    local signature = serialize({context.enabled, context.excludedReason,
      context.ambientTemperature, context.initialState, context.roadWetness,
      context.wetGripMultipliers, context.wetGroundModels})
    if not force and inputs.lastContextSignatures[vehId] == signature then return true end
    inputs.lastContextSignatures[vehId] = signature
    vehObj:queueLuaCommand(inputs.configureProviderCommand(context))
    return true
  end

  local function applyFreshTiresOnVehId(vehId, initialState)
    vehId = tonumber(vehId)
    if not vehId then
      return
    end
    inputs.lastContextSignatures[vehId] = nil
    local vehObj = getObjectByID(vehId)
    if vehObj then
      vehObj:queueLuaCommand(
        "if overhaulTires and overhaulTires.applyFreshAndInflate then " ..
          commandPayloads.freshState(initialState) .. " end")
    end
  end

  local function initialStateWithFreshGroups(baseState, groups)
    local state = inputs.deepCopy(baseState or {})
    for _, group in ipairs(groups or {}) do
      for _, wheel in ipairs(group.wheels or {}) do
        state[tostring(wheel.name)] = inputs.freshWheelState()
      end
    end
    return state
  end

  function inputs.M.registerBusinessVehicle(businessId, vehicleId, vehId)
    if not vehId then return false end
    inputs.runtimeOwnersByVehId[tonumber(vehId)] = {
      kind = "business", businessId = businessId, vehicleId = tonumber(vehicleId) or vehicleId,
    }
    inputs.lastContextSignatures[tonumber(vehId)] = nil
    return inputs.M.sendContextForBusinessVehicle(businessId, vehicleId, true)
  end

  function inputs.M.sendContextForInspectionVehicle(vehId, force)
    vehId = tonumber(vehId)
    local owner = vehId and inputs.runtimeOwnersByVehId[vehId] or nil
    local vehObj = vehId and getObjectByID(vehId) or nil
    if not vehObj or not owner or owner.kind ~= "inspection" then return false end

    local excludedReason = vehicleTypeIsTrailer(owner.vehicleInfo) and "trailer" or nil
    local tireRuntimeEnabled = inputs.isMaintenanceEnabled() and excludedReason == nil
    local previewMileageMeters = tonumber(owner.vehicleInfo and
      (owner.vehicleInfo.wearMileage or owner.vehicleInfo.Mileage)) or 0
    local context = addTireWeatherContext({
      apiVersion = 1,
      ownerKind = "inspection",
      shopId = owner.shopId,
      readOnly = true,
      enabled = tireRuntimeEnabled,
      maintenanceEnabled = inputs.isMaintenanceEnabled(),
      burnoutOverride = false,
      excludedReason = excludedReason,
      ambientTemperature = getAmbientTemperature(),
      initialState = {},
      defaultRemaining = tireRuntimeEnabled and
        inputs.tireModel.remainingFromMiles(previewMileageMeters * inputs.metersToMiles) or 1,
      groundModels = getGroundModels(),
      stateRevision = 0,
    })
    local signature = serialize({context.enabled, context.excludedReason,
      context.ambientTemperature, context.defaultRemaining, context.shopId, context.roadWetness,
      context.wetGripMultipliers, context.wetGroundModels})
    if not force and inputs.lastContextSignatures[vehId] == signature then return true end
    inputs.lastContextSignatures[vehId] = signature
    vehObj:queueLuaCommand(inputs.configureProviderCommand(context))
    return true
  end

  function inputs.M.registerInspectionVehicle(vehId, vehicleInfo)
    vehId = tonumber(vehId)
    if not vehId or type(vehicleInfo) ~= "table" then return false end
    inputs.runtimeOwnersByVehId[vehId] = {
      kind = "inspection",
      shopId = vehicleInfo.shopId,
      vehicleInfo = {
        shopId = vehicleInfo.shopId,
        model = vehicleInfo.model,
        model_key = vehicleInfo.model_key,
        Type = vehicleInfo.Type,
        type = vehicleInfo.type,
        Mileage = tonumber(vehicleInfo.Mileage) or 0,
        wearMileage = tonumber(vehicleInfo.wearMileage),
      },
    }
    inputs.lastContextSignatures[vehId] = nil
    return inputs.M.sendContextForInspectionVehicle(vehId, true)
  end

  function inputs.M.unregisterInspectionVehicle(vehId)
    vehId = tonumber(vehId)
    local owner = vehId and inputs.runtimeOwnersByVehId[vehId] or nil
    if not owner or owner.kind ~= "inspection" then return false end
    inputs.runtimeOwnersByVehId[vehId] = nil
    inputs.lastContextSignatures[vehId] = nil

    -- A successful sale may have assigned inventory ownership before inspection cleanup runs. Hand the live vehicle directly to its persistent context.
    if inputs.M.sendContextForVehicle(vehId, true) then return true end
    local vehObj = vehId and getObjectByID(vehId) or nil
    if vehObj then
      vehObj:queueLuaCommand("if overhaulTires then " .. commandPayloads.disabledInspection() .. " end")
    end
    return true
  end

  function inputs.M.unregisterBusinessVehicle(businessId, vehicleId, vehId)
    vehId = tonumber(vehId)
    local vehObj = vehId and getObjectByID(vehId) or nil
    if vehObj then
      vehObj:queueLuaCommand("if overhaulTires then " .. vehicleCommands.call("overhaulTires", "flushState") .. "; "
    .. vehicleCommands.call("overhaulTires", "resetThermalsAndGrip") .. " end")
    end
    inputs.runtimeOwnersByVehId[vehId] = nil
    inputs.lastContextSignatures[vehId] = nil
    return true
  end

  -- Sends every spawned personal vehicle, then every business and inspection owner whose vehicle still exists.
  local spawnedVehIds = {}
  local function sendAllContexts(force)
    table.clear(spawnedVehIds)
    table.clear(partIndexWanted)
    for inventoryId in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
      local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
      if vehId then
        spawnedVehIds[#spawnedVehIds + 1] = vehId
        local location = tonumber(inventoryId)
        if location and location == location then partIndexWanted[location] = true end
      end
    end
    local index = spawnedVehIds[1] and buildPartIndex() or nil
    for spawnedIndex = 1, #spawnedVehIds do
      sendPersonalContext(spawnedVehIds[spawnedIndex], force, index)
    end
    for vehId, owner in pairs(inputs.runtimeOwnersByVehId) do
      if owner.kind == "business" then
        if getObjectByID(vehId) then
          inputs.M.sendContextForBusinessVehicle(owner.businessId, owner.vehicleId, force)
        else
          inputs.runtimeOwnersByVehId[vehId] = nil
          inputs.lastContextSignatures[vehId] = nil
        end
      elseif owner.kind == "inspection" then
        if getObjectByID(vehId) then
          inputs.M.sendContextForInspectionVehicle(vehId, force)
        else
          inputs.runtimeOwnersByVehId[vehId] = nil
          inputs.lastContextSignatures[vehId] = nil
        end
      end
    end
  end

  function inputs.M.setBurnoutOverride(inventoryId, enabled)
    inventoryId = tonumber(inventoryId)
    if not inventoryId then
      return false
    end
    inputs.burnoutOverrides[inventoryId] = enabled == true or nil
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
    if vehId then
      inputs.M.sendContextForVehicle(vehId, true)
    end
    return true
  end

  -- Dyno sessions -----------------------------------------------------------------------------------

  -- Copies the live wheel readings (wear, flat, temperature, pressure) onto a saved state.
  local function overlayWheelReading(savedWheel, liveWheel)
    if liveWheel.remaining ~= nil then savedWheel.remaining = inputs.tireModel.clamp(liveWheel.remaining, 0, 1) end
    if liveWheel.flat ~= nil then savedWheel.flat = liveWheel.flat == true end
    if type(liveWheel.temperature) == "table" then savedWheel.temperature = inputs.deepCopy(liveWheel.temperature) end
    if liveWheel.pressure ~= nil then savedWheel.pressure = tonumber(liveWheel.pressure) end
  end

  local function overlayLiveWheelState(snapshot, liveState)
    if type(snapshot) ~= "table" or type(liveState) ~= "table" then
      return
    end
    local liveByName = {}
    for _, wheel in ipairs(liveState.wheels or liveState.data or {}) do
      if type(wheel) == "table" and wheel.name then
        liveByName[tostring(wheel.name)] = wheel
      end
    end

    local function overlayState(state)
      for wheelName, savedWheel in pairs(state and state.wheels or {}) do
        local liveWheel = liveByName[tostring(wheelName)]
        if liveWheel and type(savedWheel) == "table" then
          overlayWheelReading(savedWheel, liveWheel)
        end
      end
    end

    for _, savedPart in pairs(snapshot.parts or {}) do
      overlayState(savedPart.directState)
      overlayState(savedPart.taggedState)
    end
    for _, state in pairs(snapshot.vehicleStateByPartPath or {}) do overlayState(state) end
    for _, savedWheel in ipairs(snapshot.vehicleLayout and snapshot.vehicleLayout.wheels or {}) do
      local liveWheel = liveByName[tostring(savedWheel.name)]
      if liveWheel then
        overlayWheelReading(savedWheel, liveWheel)
      end
    end
  end

  local function captureDynoSnapshot(inventoryId, liveState)
    local vehicleData = inputs.vehicleDataForInventory(inventoryId)
    if not vehicleData then
      return nil
    end

    local parts = {}
    for partId, part in pairs(inputs.personalInventory()) do
      if part and tonumber(part.location) == inventoryId then
        parts[partId] = {
          hadDirectState = part.rlsTireState ~= nil,
          directState = inputs.deepCopy(part.rlsTireState),
          hadTags = type(part.tags) == "table",
          hadTaggedState = type(part.tags) == "table" and part.tags.rlsTireState ~= nil,
          taggedState = type(part.tags) == "table" and inputs.deepCopy(part.tags.rlsTireState) or nil,
        }
      end
    end

    local snapshot = {
      vehicleStateByPartPath = inputs.deepCopy(vehicleData.rlsTireStateByPartPath),
      vehicleLayout = inputs.deepCopy(vehicleData.rlsTireLayout),
      provider = inputs.deepCopy(vehicleData.overhaulTires),
      parts = parts,
    }
    overlayLiveWheelState(snapshot, liveState)
    return snapshot
  end

  local function restoreDynoSnapshot(inventoryId)
    local snapshot = inputs.dynoSnapshots[inventoryId]
    local vehicleData = inputs.vehicleDataForInventory(inventoryId)
    if not snapshot or not vehicleData then
      return false
    end

    vehicleData.rlsTireStateByPartPath = inputs.deepCopy(snapshot.vehicleStateByPartPath)
    vehicleData.rlsTireLayout = inputs.deepCopy(snapshot.vehicleLayout)
    vehicleData.overhaulTires = inputs.deepCopy(snapshot.provider)

    local inventory = inputs.personalInventory()
    for partId, saved in pairs(snapshot.parts or {}) do
      local part = inventory[partId]
      if part then
        part.rlsTireState = saved.hadDirectState and inputs.deepCopy(saved.directState) or nil
        if saved.hadTags then
          part.tags = type(part.tags) == "table" and part.tags or {}
          part.tags.rlsTireState = saved.hadTaggedState and inputs.deepCopy(saved.taggedState) or nil
        elseif type(part.tags) == "table" then
          part.tags.rlsTireState = nil
        end
      end
    end

    inputs.partRevisions[inventoryId] = (tonumber(inputs.partRevisions[inventoryId]) or 0) + 1
    inputs.markDirty(inventoryId)
    return true
  end

  function inputs.M.beginDynoSession(inventoryId, liveState)
    inventoryId = tonumber(inventoryId)
    if not inventoryId then
      return false
    end

    -- The dyno removes the wheels immediately after this call. Persist the last live report onto the owned tire records first so wear follows those parts into storage and remains durable if the game is saved during the session. Dyno telemetry uses `data`; normal provider reports use `wheels`.
    if type(liveState) == "table" then
      local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
      if vehId then
        local payload = inputs.deepCopy(liveState)
        payload.wheels = payload.wheels or payload.data or {}
        inputs.M.receiveVehicleState(vehId, payload)
      end
    end
    if not inputs.dynoSnapshots[inventoryId] then
      inputs.dynoSnapshots[inventoryId] = captureDynoSnapshot(inventoryId, liveState)
      if not inputs.dynoSnapshots[inventoryId] then
        return false
      end
    end
    inputs.dynoOverrides[inventoryId] = true
    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
    if vehId then
      inputs.M.sendContextForVehicle(vehId, true)
    end
    return true
  end

  function inputs.M.endDynoSession(inventoryId)
    inventoryId = tonumber(inventoryId)
    if not inventoryId then
      return false
    end

    local restored = true
    if inputs.dynoSnapshots[inventoryId] then
      restored = restoreDynoSnapshot(inventoryId)
      inputs.dynoSnapshots[inventoryId] = nil
    end
    inputs.dynoOverrides[inventoryId] = nil

    local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId) or nil
    if vehId then
      inputs.M.sendContextForVehicle(vehId, true)
    end
    return restored
  end

  -- Compatibility for older callers while keeping snapshot ownership scoped to an entire dyno session rather than individual pulls or vehicle respawns.
  function inputs.M.setDynoOverride(inventoryId, enabled)
    if enabled == true then
      return inputs.M.beginDynoSession(inventoryId)
    end
    return inputs.M.endDynoSession(inventoryId)
  end

  -- Public API --------------------------------------------------------------------------------------

  return {
    applyFreshTiresOnVehId = applyFreshTiresOnVehId,
    buildInitialWheelState = buildInitialWheelState,
    configuredRest = configuredRest,
    contextTraces = contextTraces,
    initialStateWithFreshGroups = initialStateWithFreshGroups,
    restoreDynoSnapshot = restoreDynoSnapshot,
    sendAllContexts = sendAllContexts,
  }
end

return partFactory
