-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Owned-vehicle spawning, spawn-readiness tracking, entering vehicles and the walking fallback.
-- Each attempt keeps its engine-spawn and post-spawn failure boundaries separate; the tracker only observes them.
-- damageRestore.lua owns placement holds and restoration replies; callers finish movement through completeVehiclePlacement.
local walkTarget = require('overhaul/lib/avatar/walkTarget')
local vehicleCommands = require("overhaul/lib/vehicles/vehicleCommands")
local levelData = require('overhaul/lib/world/levelData')

local spawnPart = {}

-- Spawn readiness ---------------------------------------------------------------------------------

-- Readiness observes owner callbacks; it never changes spawn scheduling or sends game commands.
spawnPart.STATES = {"placed", "bound", "conditionsInitialized", "veAcknowledged", "damageRestored", "aiConfigured"}

local function snapshot(record)
  local states = {}
  for name, value in pairs(record.states) do states[name] = value end
  return {inventoryId = record.inventoryId, vehId = record.vehId, attempt = record.attempt,
    startedAt = record.startedAt, states = states, complete = record.complete, closed = record.closed,
    repeatedMarks = record.repeatedMarks}
end

local function isComplete(record)
  for _, name in ipairs(spawnPart.STATES) do
    if record.states[name] == nil then return false end
  end
  return true
end

-- Runs the observers once, with a copy of the record, and drops them.
local function notify(record)
  local observers = record.observers
  record.observers = {}
  for _, fn in ipairs(observers) do
    local ok, err = pcall(fn, snapshot(record))
    if not ok then log("E", "spawnReadiness", "readiness observer failed: " .. tostring(err)) end
  end
end

-- Marks one readiness state. False when it was already marked, or the attempt is closed or already complete.
local function markState(record, state, value)
  if record.states[state] ~= nil then
    record.repeatedMarks = record.repeatedMarks + 1
    return false
  end
  record.states[state] = value == nil and true or value
  if record.closed or record.complete then return false end
  if isComplete(record) then
    record.complete = true
    notify(record)
  end
  return true
end

-- Opens a new attempt for an inventory id; an open older attempt for that id is superseded.
local function beginAttempt(store, inventoryId, vehId)
  store.nextAttempt = store.nextAttempt + 1
  local previous = store.latest[inventoryId]
  if previous and not previous.complete and not previous.closed then
    previous.closed = "superseded"
    previous.observers = {}
  end
  local record = {inventoryId = inventoryId, vehId = vehId, attempt = store.nextAttempt, startedAt = store.clock(),
    states = {}, observers = {}, repeatedMarks = 0}
  store.latest[inventoryId] = record
  return function(state, value)
    return markState(record, state, value)
  end
end

-- Closes the latest attempt of a removed vehicle, complete or not (a complete one stays as history).
local function closeRemoved(store, inventoryId)
  local record = store.latest[inventoryId]
  if record and not record.closed then
    record.closed = "removed"
    record.observers = {}
  end
end

local function waitForReady(store, inventoryId, fn)
  local record = store.latest[inventoryId]
  if not record or record.closed then return false end
  if record.complete then
    fn(snapshot(record))
    return true
  end
  record.observers[#record.observers + 1] = fn
  return true
end

local function overdueAttempts(store, seconds, now)
  now = now or store.clock()
  local out = {}
  for _, record in pairs(store.latest) do
    if not record.complete and not record.closed and now - record.startedAt >= seconds then
      out[#out + 1] = snapshot(record)
    end
  end
  table.sort(out, function(a, b) return a.attempt < b.attempt end)
  return out
end

-- One tracker per owner; the inventory builds one per extension load. The tracker keeps no state of its own.
function spawnPart.create(opts)
  opts = opts or {}
  local store = {
    clock = opts.clock or function() return (os.clockhp or os.clock)() end,
    latest = {},        -- inventoryId -> latest attempt record
    nextAttempt = 0,
  }
  local tracker = {}

  -- Starts a spawn attempt; returns its mark(state, value) function. Each attempt is its own record.
  function tracker.begin(inventoryId, vehId)
    return beginAttempt(store, inventoryId, vehId)
  end

  function tracker.removed(inventoryId)
    closeRemoved(store, inventoryId)
  end

  -- The latest attempt for an inventory id, as a copy, or nil.
  function tracker.get(inventoryId)
    local record = store.latest[inventoryId]
    return record and snapshot(record) or nil
  end

  -- Runs fn(attempt) once the latest attempt is complete (now, if it already is). False when no open attempt exists.
  function tracker.onReady(inventoryId, fn)
    return waitForReady(store, inventoryId, fn)
  end

  -- Attempts still incomplete (and not closed) after `seconds`. Only a report: it decides nothing.
  function tracker.overdue(seconds, now)
    return overdueAttempts(store, seconds, now)
  end

  return tracker
end

function spawnPart.new(inputs)
  local helpers = {}
  -- Readiness of each spawn attempt, observed only.
  local readiness = spawnPart.create()
  local damageRestore = require('overhaul/career/garage/inventory/damageRestore').new({
    M=inputs.M, vehicles=inputs.vehicles, pendingDamageRestore=inputs.pendingDamageRestore,
    inventoryIdToVehId=inputs.inventoryIdToVehId, readiness=readiness,
  })

  -- Spawn placement ---------------------------------------------------------------------------------

  local function getVehicleSpawnLocation(inventoryId, replaceOption, location)
    local function isFinitePosition(pos)
      return pos and type(pos.x) == 'number' and type(pos.y) == 'number' and type(pos.z) == 'number'
        and pos.x == pos.x and pos.y == pos.y and pos.z == pos.z
        and math.abs(pos.x) < math.huge and math.abs(pos.y) < math.huge and math.abs(pos.z) < math.huge
    end
    if location and isFinitePosition(location.pos) then return location.pos, location.rot end
    local playerVehicle = getPlayerVehicle(0)
    local replacedVehicleId = replaceOption == 2 and inputs.inventoryIdToVehId[inventoryId]
    local replacedVehicle = replacedVehicleId and getObjectByID(replacedVehicleId) or (replaceOption == 1 and playerVehicle)
    if replacedVehicle and isFinitePosition(replacedVehicle:getPosition()) then return replacedVehicle:getPosition(), replacedVehicle:getRotation() end
    local garage = inputs.getInventoryMenuGarage()
    if garage then
      for _, spot in ipairs(overhaul_world_facilities.getParkingSpotsForFacility(garage) or {}) do
        if isFinitePosition(spot.pos) and not spot:hasAnyVehicles() then return spot.pos, spot.rot end
      end
    end
    local playerPos = playerVehicle and playerVehicle:getPosition()
    if not isFinitePosition(playerPos) then return end
    local roadStartNodeId, roadEndNodeId = map.findClosestRoad(playerPos)
    local nodes = (map.getMap() or {}).nodes or {}
    if nodes[roadStartNodeId] and nodes[roadEndNodeId] then
      local roadStartPosition, roadEndPosition = nodes[roadStartNodeId].pos, nodes[roadEndNodeId].pos
      if isFinitePosition(roadStartPosition) and isFinitePosition(roadEndPosition) then
        local roadSegment = roadEndPosition - roadStartPosition
        local roadLengthSquared = roadSegment:dot(roadSegment)
        local closestPointFraction = roadLengthSquared > 0 and clamp((playerPos - roadStartPosition):dot(roadSegment) / roadLengthSquared, 0, 1) or 0
        return roadStartPosition + roadSegment * closestPointFraction + vec3(0, 0, 1), playerVehicle:getRotation()
      end
    end
    return playerPos + vec3(0, 0, 1), playerVehicle:getRotation()
  end

  -- Vehicle spawning --------------------------------------------------------------------------------

  local function validateSpawnRecord(inventoryId)
    local vehicleRecord = inputs.vehicles[inventoryId]
    if vehicleRecord and vehicleRecord.listedForAuction then
      ui_message("This vehicle is listed at the auction and cannot be spawned.", nil, "vehicleInventory")
      return
    end

    if not vehicleRecord then
      log("E", "career.inventory", string.format("spawnVehicle: no inventory vehicle %s", tostring(inventoryId)))
      return
    end

    local inventoryConfig = vehicleRecord.config
    local vehicleModel = vehicleRecord.model
    if not inventoryConfig then
      log("E", "career.inventory", string.format("spawnVehicle: id %s has no config", tostring(inventoryId)))
      return
    end

    local modelMissing = tableIsEmpty(core_vehicles.getModel(vehicleModel))
    local partConfigPath = inventoryConfig.partConfigFilename
    local partConfigExists = false
    if type(partConfigPath) == "string" and partConfigPath ~= "" then
      partConfigExists = FS:fileExists(partConfigPath) or FS:fileExists("/" .. partConfigPath:gsub("^/", ""))
    end
    local hasParts = type(inventoryConfig.parts) == "table" and next(inventoryConfig.parts) ~= nil
    local hasPartsTree = type(inventoryConfig.partsTree) == "table" and next(inventoryConfig.partsTree) ~= nil

    log("I", "career.inventory", string.format(
      "spawnVehicle: id=%s model=%s pc=%s pcExists=%s hasParts=%s modelMissing=%s missingFile=%s",
      tostring(inventoryId), tostring(vehicleModel), tostring(partConfigPath),
      tostring(partConfigExists), tostring(hasParts or hasPartsTree), tostring(modelMissing),
      tostring(vehicleRecord.missingFile)))

    if modelMissing then
      log("E", "career.inventory", string.format("spawnVehicle: skip id %s - model missing: %s", tostring(inventoryId), tostring(vehicleModel)))
      return
    end
    if not partConfigExists and not hasParts and not hasPartsTree then
      log("E", "career.inventory", string.format(
        "spawnVehicle: skip id %s - no pc and no parts (pc=%s)", tostring(inventoryId), tostring(partConfigPath)))
      return
    end

    return vehicleRecord, inventoryConfig, vehicleModel, partConfigExists
  end

  local function prepareSpawnOptions(inventoryId, replaceOption, location, inventoryConfig, partConfigExists)
    local vehicleData = {}
    -- A copy, so stripping a missing .pc path and flattening partsTree never mutates the saved record.
    local spawnConfig = deepcopy(inventoryConfig)
    if spawnConfig.partsTree then
      spawnConfig.parts = core_vehicle_partmgmt.partsTreeToPartsMap(spawnConfig.partsTree)
      spawnConfig.partsTree = nil
    end
    if not partConfigExists then spawnConfig.partConfigFilename = nil end

    vehicleData.config = spawnConfig
    vehicleData.keepOtherVehRotation = true
    vehicleData.pos, vehicleData.rot = getVehicleSpawnLocation(inventoryId, replaceOption, location)
    if not vehicleData.pos then
      log('E', 'career.inventory', 'spawnVehicle: no safe location for id ' .. tostring(inventoryId))
      return
    end

    return vehicleData
  end

  local function createSpawnedVehicle(inventoryId, replaceOption, vehicleModel, vehicleData)
    core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = false})
    if replaceOption == 1 then
      return core_vehicles.replaceVehicle(vehicleModel, vehicleData)
    elseif replaceOption == 2 then
      local oldVehId = inputs.inventoryIdToVehId[inventoryId]
      local oldVehObj = oldVehId and getObjectByID(oldVehId) or nil
      if oldVehObj then return core_vehicles.replaceVehicle(vehicleModel, vehicleData, oldVehObj) end
    end
    vehicleData.autoEnterVehicle = false
    return core_vehicles.spawnNewVehicle(vehicleModel, vehicleData)
  end

  local function bindSpawnedVehicle(inventoryId, vehicleRecord, vehObj, callback, markReady)
    vehObj:queueLuaCommand("extensions.load('overhaulDamageState')")
    local boundVehId = vehObj:getID()
    helpers.assignInventoryIdToVehId(inventoryId, boundVehId)
    markReady("bound", boundVehId)

    if vehicleRecord.partConditions then
      core_vehicleBridge.executeAction(vehObj, 'initPartConditions', vehicleRecord.partConditions, 0, 1, 1)
      markReady("conditionsInitialized")
      core_vehicleBridge.requestValue(vehObj, function()
        if not (inputs.M.isTransientBuild and inputs.M.isTransientBuild(inventoryId)) then
          overhaul_career_parts_partInventory.updatePartsToMatchSpawnedVehicle(inventoryId)
        end
        if callback then callback() end
        markReady("veAcknowledged")
        damageRestore.setupReady(inventoryId, boundVehId)
      end, 'ping')
    else
      core_vehicleBridge.executeAction(vehObj, 'initPartConditions', {}, 0, 1, 1)
      markReady("conditionsInitialized")
      -- the legacy callback runs once the condition reply is processed; readiness is marked after it
      core_vehicleBridge.requestValue(vehObj, function(_response)
        overhaul_career_garage_inventory.updatePartConditions(nil, inventoryId, function()
          if callback then callback() end
          markReady("veAcknowledged")
          damageRestore.setupReady(inventoryId, boundVehId)
        end)
      end, 'ping')
    end

    gameplay_walk.removeVehicleFromBlacklist(vehObj:getId())
  end

  local function requestVehicleCertifications(inventoryId, vehObj)
    if inventoryId then
      vehObj:queueLuaCommand('electrics.setIgnitionLevel(0)')
      inputs.M.setMileage(inventoryId)
      vehObj:queueLuaCommand(string.format(
          [[
          local cert = {}
          local engines = powertrain.getDevicesByCategory("engine")
          local engine = engines and engines[1]
          cert.power = engine and engine.maxPower or 0
          cert.torque = engine and engine.maxTorque or 0
          cert.weight = obj:calcBeamStats().total_weight
          obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply(%d, 'inventoryCertifications', "%s, " .. serialize(cert)))
        ]],
        require('overhaul/lib/vehicles/callbacks').open('inventoryCertifications', {owner = 'inventory', vehId = vehObj:getID()}), vehObj:getID()))
    end
  end

  local function restoreSpawnDamage(inventoryId, vehicleRecord, vehObj, markReady, placementPending, waitForBinding)
    if inputs.M.isTransientBuild and inputs.M.isTransientBuild(inventoryId) then
      markReady("damageRestored", "transient")
      return true
    end
    local brokenPartCount = vehicleRecord.partConditions and overhaul_career_market_valueCalculator.getNumberOfBrokenParts(vehicleRecord.partConditions) or 0
    local manager = overhaul_career_repair_damageManager
    local hasSnapshot = manager.hasDamageState and manager.hasDamageState(inventoryId)
    local damaged = brokenPartCount > 0 or hasSnapshot == true
    local pose = not damaged and vehicleRecord.mechanismState or nil
    if waitForBinding and not damaged and not pose then return false end
    damageRestore.begin(inventoryId, vehObj, markReady, damaged, placementPending, waitForBinding, pose)
    if brokenPartCount == 0 and not hasSnapshot then
      vehObj:queueLuaCommand("extensions.load('overhaulDamageState'); if overhaulDamageState then "
        .. vehicleCommands.call("overhaulDamageState", "reset") .. "; end")
    end
    return true
  end

  local function configureSpawnTraffic(vehObj, markReady)
    if gameplay_traffic and gameplay_traffic.insertTraffic then
      gameplay_traffic.insertTraffic(vehObj:getID(), true, true)
      if overhaul_integration_services_police and overhaul_integration_services_police.suppressSpeedingOffense then
        -- Covers spawn-to-garage-teleport window during storage retrieval.
        overhaul_integration_services_police.suppressSpeedingOffense(vehObj:getID(), 3)
      end
      markReady("aiConfigured", "traffic")
    else
      markReady("aiConfigured", "none")
    end
  end

  -- The nonreplacement path still returns its engine object synchronously.
  local function spawnVehicleNow(inventoryId, replaceOption, callback, vehicleRecord, vehicleModel, vehicleData, placementPending)
    local delivery = overhaul_career_logistics_general
    delivery.capturePersistentCargo()
    local spawnOk, spawnResult = pcall(createSpawnedVehicle, inventoryId, replaceOption, vehicleModel, vehicleData)
    if not spawnOk then
      log("E", "career.inventory", string.format(
        "spawnVehicle: spawn threw for id %s (%s): %s",
        tostring(inventoryId), tostring(vehicleModel), tostring(spawnResult)))
      callback(false, "Vehicle spawn failed.")
      return
    end
    local vehObj = spawnResult
    if not vehObj then
      log("E", "career.inventory", string.format("Couldnt spawn vehicle id %s (%s)", tostring(inventoryId), tostring(vehicleModel)))
      callback(false, "Vehicle spawn failed.")
      return
    end
    local markReady = readiness.begin(inventoryId, vehObj:getID())
    if not placementPending then markReady('placed') end
    -- A failed setup must retain its saved wreck, even if the live object still looks pristine.
    local preparedDamage = restoreSpawnDamage(inventoryId, vehicleRecord, vehObj, markReady, placementPending, true)
    local didPostSpawnSetupSucceed, postSpawnError = pcall(function()
      bindSpawnedVehicle(inventoryId, vehicleRecord, vehObj, callback, markReady)
      requestVehicleCertifications(inventoryId, vehObj)
      if not preparedDamage then restoreSpawnDamage(inventoryId, vehicleRecord, vehObj, markReady, placementPending) end
      configureSpawnTraffic(vehObj, markReady)
    end)
    if not didPostSpawnSetupSucceed then
      log("E", "career.inventory", string.format(
        "spawnVehicle: post-spawn setup threw for id %s: %s (vehicle still returned)",
        tostring(inventoryId), tostring(postSpawnError)))
      callback(false, "Vehicle setup failed.")
    end
    if preparedDamage and not (inputs.M.isTransientBuild and inputs.M.isTransientBuild(inventoryId)) then
      damageRestore.start(inventoryId)
    end
    vehicleRecord.missingFile = nil
    log("I", "career.inventory", string.format("spawnVehicle: spawned id %s as vehId %s", tostring(inventoryId), tostring(vehObj:getID())))
    return vehObj
  end

  -- Capture belongs to the outgoing bound car, which can differ from the car being entered.
  local function replacementTarget(inventoryId, replaceOption)
    if replaceOption == 2 then
      local vehId = inputs.inventoryIdToVehId[inventoryId]
      if vehId and getObjectByID(vehId) then return inventoryId, vehId end
    elseif replaceOption == 1 then
      local playerVehicle = getPlayerVehicle(0)
      local vehId = playerVehicle and playerVehicle:getID()
      if vehId then
        for outgoingId, boundId in pairs(inputs.inventoryIdToVehId) do
          if boundId == vehId then return outgoingId, vehId end
        end
      end
    end
  end

  local function spawnVehicle(inventoryId, replaceOption, callback, location, placementPending, options)
    local completed = false
    local function complete(success, reason)
      if completed then return end
      completed = true
      if callback then
        if success == false then callback(false, reason) else callback() end
      end
    end
    local function fail(reason)
      log("W", "career.inventory", "spawnVehicle: replacement aborted for id " .. tostring(inventoryId) .. ": " .. tostring(reason))
      complete(false, reason)
    end

    local vehicleRecord, inventoryConfig, vehicleModel, partConfigExists = validateSpawnRecord(inventoryId)
    if not vehicleRecord then complete(false, "Vehicle unavailable."); return end
    local originalBinding = inputs.inventoryIdToVehId[inventoryId]
    local originalLevel = getCurrentLevelIdentifier()
    local outgoingId, outgoingVehId = replacementTarget(inventoryId, replaceOption)
    local outgoingRecord = outgoingId and inputs.vehicles[outgoingId]
    local handledCapture = false
    local result
    local function replaceCapturedVehicle()
      local currentOutgoingId, currentOutgoingVehId = replacementTarget(inventoryId, replaceOption)
      if inputs.vehicles[inventoryId] ~= vehicleRecord or inputs.inventoryIdToVehId[inventoryId] ~= originalBinding
        or getCurrentLevelIdentifier() ~= originalLevel or currentOutgoingId ~= outgoingId or currentOutgoingVehId ~= outgoingVehId
        or (outgoingId and inputs.vehicles[outgoingId] ~= outgoingRecord) then
        fail("Vehicle changed before replacement.")
        return
      end
      local vehicleData = prepareSpawnOptions(inventoryId, replaceOption, location, inventoryConfig, partConfigExists)
      if not vehicleData then fail("No safe spawn location."); return end
      if options and options.prepareReplacement then
        local ok, prepared = pcall(options.prepareReplacement)
        if not ok or prepared ~= true then
          fail(ok and "Replacement preparation refused." or tostring(prepared))
          return
        end
      end
      return spawnVehicleNow(inventoryId, replaceOption, complete, vehicleRecord, vehicleModel, vehicleData, placementPending)
    end
    local function afterCapture(success, reason)
      if handledCapture then return end
      handledCapture = true
      if success ~= true then fail(reason or "Damage capture failed."); return end
      local ok, spawned = pcall(replaceCapturedVehicle)
      if not ok then fail(tostring(spawned)) else result = spawned end
    end

    if outgoingId and not (inputs.M.isTransientBuild and inputs.M.isTransientBuild(outgoingId)) then
      local manager = overhaul_career_repair_damageManager
      if not manager or type(manager.captureDamageState) ~= "function" then
        fail("Damage capture unavailable.")
        return
      end
      local ok, err = pcall(manager.captureDamageState, outgoingId, afterCapture)
      if not ok and not handledCapture then afterCapture(false, tostring(err)) end
    else
      afterCapture(true)
    end
    if not handledCapture then return true end
    return result
  end

  -- Camera recovery ---------------------------------------------------------------------------------

  local function ensureGameCamera()
    if commands.isFreeCamera() then
      commands.setGameCamera()
    end
  end

  -- Career load starts freeroam with no player, so the free camera can win a race against entering or teleporting.
  local function ensureGameCameraWithRetry()
    commands.setGameCamera()
    core_jobsystem.create(function(job)
      for _ = 1, 6 do
        job.sleep(0.5)
        commands.isFreeCamera() -- traces pin this probe call; the camera is set either way
        commands.setGameCamera()
      end
    end)
  end

  -- Vehicle entry -----------------------------------------------------------------------------------

  -- loadOption 1 keeps the spawned vehicle as is; 2 forces a reload.
  local function enterVehicleActual(id, loadOption, callback)
    local function finishEntry(success, reason)
      if success == false then
        if callback then callback(false, reason) end
        return
      end
      if inputs.state.currentVehicle then inputs.dirtiedVehicles[inputs.state.currentVehicle] = true end
      extensions.hook("onOverhaulEnterVehicleFinished", inputs.state.currentVehicle)
      if callback then callback() end
    end
    if not id or loadOption == 1 then
      inputs.state.currentVehicle = id
    elseif inputs.inventoryIdToVehId[id] and loadOption ~= 2 then
      -- vehicle is already spawned. enter it
      walkTarget.leaveWalkingModeForced(gameplay_walk)
      be:enterVehicle(0, getObjectByID(inputs.inventoryIdToVehId[id]))
      inputs.state.currentVehicle = id
      ensureGameCamera()
    else
      spawnVehicle(id, 1, function(success, reason)
        if success == false then finishEntry(false, reason); return end
        inputs.state.currentVehicle = id
        ensureGameCamera()
        finishEntry()
      end)
      return
    end
    finishEntry()
  end

  local function enterVehicle(newInventoryId, loadOption, callback)
    local vehicleRecord = inputs.vehicles[newInventoryId]
    if vehicleRecord and vehicleRecord.timeToAccess then return end
    if vehicleRecord and vehicleRecord.listedForAuction then
      ui_message("This vehicle is listed at the auction.", nil, "vehicleInventory")
      return
    end
    overhaul_career_ui_log.addLog(string.format("Enter vehicle %s", newInventoryId or "no vehicle"), "inventory")

    if loadOption == 1 then
      enterVehicleActual(newInventoryId, loadOption, callback)
      return
    end
    if inputs.state.currentVehicle then
      helpers.updatePartConditionsOfCurrentVehicle(function() enterVehicleActual(newInventoryId, loadOption, callback) end)
    else
      enterVehicleActual(newInventoryId, loadOption, callback)
    end
  end

  -- Walking recovery --------------------------------------------------------------------------------

  inputs.state.pendingWalkRestore = false

  -- Career loads freeroam with preventPlayerSpawning, so the unicycle may not exist yet; the caller retries.
  local function teleportWalkFallback(levelName, preferredPos, preferredRot)
    if not preferredPos then
      local recovery = levelData.recoverySpawn(levelName)
      if recovery then preferredPos, preferredRot = recovery.pos, recovery.rot end
    end
    spawn.preventPlayerSpawning = nil
    gameplay_walk.setWalkingMode(true, preferredPos, preferredRot, true)
    local playerVeh = getPlayerVehicle(0)
    if not playerVeh then
      log("W", "career.inventory", "teleportWalkFallback: unicycle not ready yet")
      inputs.state.pendingWalkRestore = true
      return false
    end
    inputs.state.pendingWalkRestore = false

    if preferredPos then
      local ok, err = pcall(function()
        return spawn.safeTeleport(playerVeh, preferredPos, preferredRot)
      end)
      if ok and err ~= false then
        log("I", "career.inventory", "Walk restore teleported to saved position")
        ensureGameCameraWithRetry()
        return true
      end
      log("W", "career.inventory", "Walk restore saved-pos teleport failed: " .. tostring(err))
    end

    local ok, destination = pcall(inputs.teleportPlayerToStartingGarage, levelName)
    if not ok or not destination then
      log('W', 'career.inventory', 'Walk restore has no usable local destination')
      inputs.state.pendingWalkRestore = true
      return false
    end
    log("I", "career.inventory", "Walk restore teleported to starting garage")
    ensureGameCameraWithRetry()
    return true
  end

  -- Public API --------------------------------------------------------------------------------------

  return {
    ensureGameCameraWithRetry = ensureGameCameraWithRetry,
    enterVehicle = enterVehicle,
    spawnVehicle = spawnVehicle,
    spawnReadiness = readiness,
    completeVehiclePlacement = damageRestore.complete,
    deferVehiclePlacement = damageRestore.defer,
    isDamageRestorePending = damageRestore.isPending,
    teleportWalkFallback = teleportWalkFallback,
    bindInputs = function(inputs)
      helpers.assignInventoryIdToVehId = inputs.assignInventoryIdToVehId
      helpers.updatePartConditionsOfCurrentVehicle = inputs.updatePartConditionsOfCurrentVehicle
    end,
  }
end

return spawnPart
