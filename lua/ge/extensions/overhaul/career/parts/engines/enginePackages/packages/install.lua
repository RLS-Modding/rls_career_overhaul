-- Engine installation: move stored builds into vehicles and return installed builds to storage.
-- Map: Dependencies; Fuel; Leftover engine mounts; Vehicle rebuild and rollback; Store saga; Install saga; Public API.

local install = {}

function install.create(inputs)
  local parts = inputs.parts

  -- Dependencies -------------------------------------------------------------------------------------

  local sendResult = inputs.sendResult

  -- Rollback ends its transaction before the respawn answers. Its callback must
  -- remain valid for that owner lifetime, without leaking into the next career.
  local function guardLifetime(callback)
    local generation = inputs.getLifetimeGeneration()
    return function(...)
      if generation ~= inputs.getLifetimeGeneration() then return end
      return callback(...)
    end
  end

  -- Fuel ---------------------------------------------------------------------------------------------

  -- Reads every non-nitrous tank. Times out after five seconds and continues with no fuel restored.
  local function storeFuelLevels(vehObj, callback)
    callback = guardLifetime(callback)
    if not vehObj then callback({}) return end
    local answered = false
    core_jobsystem.create(function(job)
      job.sleep(5)
      if not answered then
        answered = true
        log("W", inputs.constants.logTag, "Fuel level request timed out; continuing without restoring fuel")
        callback({})
      end
    end)
    core_vehicleBridge.requestValue(vehObj, function(data)
      if answered then return end
      answered = true
      local result = {}
      if data and data[1] then
        for _, tank in ipairs(data[1]) do
          if tank.energyType ~= "n2o" then
            result[tank.name] = {
              currentEnergy = tank.currentEnergy,
              maxEnergy = tank.maxEnergy,
              energyType = tank.energyType,
              relativeFuel = tank.maxEnergy > 0 and tank.currentEnergy / tank.maxEnergy or 0
            }
          end
        end
      end
      callback(result)
    end, "energyStorage")
  end

  -- Puts each stored tank back at its old level, scaled when the new tank is larger, never under 5 percent.
  local function restoreFuelLevels(vehObj, storedLevels)
    if not vehObj or not storedLevels or not next(storedLevels) then return end
    core_vehicleBridge.requestValue(vehObj, guardLifetime(function(data)
      if not data or not data[1] then return end
      for _, tank in ipairs(data[1]) do
        local stored = storedLevels[tank.name]
        if stored and stored.energyType == tank.energyType then
          local amount = math.min(stored.currentEnergy, tank.maxEnergy)
          if tank.maxEnergy > stored.maxEnergy then amount = tank.maxEnergy * stored.relativeFuel end
          core_vehicleBridge.executeAction(vehObj, "setEnergyStorageEnergy", tank.name, math.max(amount, tank.maxEnergy * 0.05))
        end
      end
    end), "energyStorage")
  end

  -- Leftover engine mounts ---------------------------------------------------------------------------

  local function pathIsUnder(childPath, parentPath)
    childPath = childPath or ""
    parentPath = parentPath or ""
    if parentPath == "" then return false end
    return childPath == parentPath or string.find(childPath, parentPath, 1, true) == 1
  end

  local function partIdSetFromTree(node)
    local ids = {}
    for _, partId in ipairs(inputs.getPartIdsFromPackageTree(node)) do
      ids[tostring(partId)] = true
    end
    return ids
  end

  -- The shallowest engine bay that contains the path (or any bay when no path is given).
  local function findOuterEngineBay(tree, ioCtx, path)
    local match
    for _, bay in ipairs(parts.capture.findEngineBaySlots(tree, ioCtx)) do
      if not path or pathIsUnder(path, bay.path) then
        if not match or parts.capture.pathDepth(bay.path) < parts.capture.pathDepth(match.path) then
          match = bay
        end
      end
    end
    return match
  end

  -- A mount that was left behind: a CEEP hub or an engine mount part, but never a combustion engine.
  local function isLeftoverEngineMount(bay, ioCtx)
    if not bay or not bay.node then return false end
    local name = parts.capture.nodePartName(bay.node)
    if not name or name == "" then return false end
    if parts.capture.partIsCombustionEngine(ioCtx, name) then return false end
    if parts.capture.isCeepHubNode(bay.node, ioCtx) then return true end
    return parts.capture.partProvidesEngineMount(inputs.jbeamIO.getPart(ioCtx, name))
  end

  -- The part sitting at a slot path: this vehicle's part when an inventory id is given, otherwise any part there.
  local function findInventoryPartAtSlot(inventory, slotPath, inventoryId)
    local fallbackId
    for partId, part in pairs(inventory) do
      if part.containingSlot == slotPath then
        if inventoryId and tonumber(part.location) == tonumber(inventoryId) then
          return partId, part
        end
        if not inventoryId then
          fallbackId = fallbackId or partId
        end
      end
    end
    if inventoryId then
      return nil
    end
    return fallbackId, fallbackId and inventory[fallbackId]
  end

  -- Copies the leftover mount subtree, skipping parts that belong to the package being moved.
  local function copyLeftoverPackageTree(source, skipIds, inventory, inventoryId, relativeSlot)
    if not source then return nil end
    local partId = findInventoryPartAtSlot(inventory, source.path, inventoryId)
    if partId and skipIds[tostring(partId)] then
      return nil
    end
    if not partId or not source.chosenPartName or source.chosenPartName == "" then
      return nil
    end
    local result = {
      name = source.chosenPartName,
      partId = partId,
      relativeSlot = relativeSlot,
      children = {}
    }
    for slotName, child in pairs(source.children or {}) do
      local copied = copyLeftoverPackageTree(child, skipIds, inventory, inventoryId, slotName)
      if copied then result.children[slotName] = copied end
    end
    return result
  end

  local function packageContainsPartId(package, partId)
    if not package or not partId then return false end
    for _, id in ipairs(inputs.getPartIdsFromPackageTree(package.tree)) do
      if tostring(id) == tostring(partId) then return true end
    end
    return false
  end

  -- Moves the leftover mount into storage under the outgoing package.
  local function parkLeftoverParts(leftoverTree, package, inventory, newConditions, basePath)
    if not leftoverTree or not package then return end
    for _, entry in ipairs(parts.capture.collectTreePartEntries(leftoverTree, basePath)) do
      local part = inventory[entry.partId]
      if part then
        if newConditions[part.partPath] then part.partCondition = deepcopy(newConditions[part.partPath]) end
        newConditions[part.partPath] = nil
        part.location = 0
        part.mainPart = true
        part.enginePackageId = tostring(package.id)
        part.containingSlot = entry.containingSlot
        part.partPath = entry.partPath
      end
    end
  end

  -- Returns the package that now holds the leftover mount, creating one when there was no outgoing package.
  local function createLeftoverPackage(leftoverTree, ioCtx)
    local package = {id = tostring(inputs.packageStore.nextPackageId)}
    inputs.packageStore.nextPackageId = inputs.packageStore.nextPackageId + 1
    table.insert(inputs.packageStore.packages, package)
    package.name = parts.capture.uniquePackageName((parts.capture.getPartNiceName(ioCtx, leftoverTree.name) or "Engine") .. " Package")
    package.createdAt = os.time()
    return package
  end

  local function mergeLeftoverIntoOutgoing(outgoingPackage, leftoverTree, innerSlotName, bay, ioCtx)
    if not leftoverTree then return outgoingPackage end
    if not outgoingPackage then
      outgoingPackage = createLeftoverPackage(leftoverTree, ioCtx)
    elseif packageContainsPartId(outgoingPackage, leftoverTree.partId) then
      outgoingPackage.rootSlotName = bay.slotName
      outgoingPackage.rootPath = bay.path
      outgoingPackage.updatedAt = os.time()
      return outgoingPackage
    else
      leftoverTree.children = leftoverTree.children or {}
      if innerSlotName and not leftoverTree.children[innerSlotName] and outgoingPackage.tree then
        leftoverTree.children[innerSlotName] = outgoingPackage.tree
        leftoverTree.children[innerSlotName].relativeSlot = innerSlotName
      end
    end
    outgoingPackage.tree = leftoverTree
    outgoingPackage.rootSlotName = bay.slotName
    outgoingPackage.rootPath = bay.path
    outgoingPackage.rootEngineName = leftoverTree.name
    outgoingPackage.rootEngineNiceName = parts.capture.getPartNiceName(ioCtx, leftoverTree.name)
    outgoingPackage.installedInventoryId = nil
    outgoingPackage.updatedAt = os.time()
    outgoingPackage.createdAt = outgoingPackage.createdAt or outgoingPackage.updatedAt
    return outgoingPackage
  end

  -- Puts the incoming package's engine into the bay, with its parts marked as installed in this vehicle.
  local function hoistPackageToBay(bay, package, inventory, newConditions, vehicle, inventoryId)
    local previousEntries = parts.capture.collectTreePartEntries(package.tree, package.rootPath or bay.path)
    for _, entry in ipairs(previousEntries) do
      newConditions[entry.partPath] = nil
    end
    local config = parts.capture.makeConfigTree(package.tree, bay.path, bay.slotName)
    bay.node.id = bay.slotName or bay.node.id
    bay.node.chosenPartName = package.tree.name
    bay.node.children = config.children
    bay.node.path = bay.path
    bay.node.partPath = bay.path .. tostring(package.tree.name)
    for _, entry in ipairs(parts.capture.collectTreePartEntries(package.tree, bay.path)) do
      local part = inventory[entry.partId]
      if part then
        part.location = inventoryId or vehicle.id
        part.containingSlot = entry.containingSlot
        part.partPath = entry.partPath
        part.mainPart = true
        part.enginePackageId = tostring(package.id)
        newConditions[entry.partPath] = deepcopy(part.partCondition or {integrityValue = 1, visualValue = 1, odometer = 0})
      end
    end
    package.rootSlotName = bay.slotName
    package.rootPath = bay.path
    vehicle.changedSlots = vehicle.changedSlots or {}
    vehicle.changedSlots[bay.path] = true
  end

  -- Empties the bay when no replacement is given; otherwise hoists the incoming engine into it.
  local function clearBayOrHoist(bay, opts)
    if opts.incomingPackage then
      hoistPackageToBay(bay, opts.incomingPackage, opts.inventory, opts.newConditions, opts.vehicle, opts.inventoryId)
      return
    end
    bay.node.id = bay.slotName or bay.node.id
    bay.node.chosenPartName = ""
    bay.node.children = {}
    bay.node.partPath = nil
    opts.vehicle.changedSlots = opts.vehicle.changedSlots or {}
    opts.vehicle.changedSlots[bay.path] = true
  end

  -- Rehomes an engine mount left in the bay after an engine is removed. Returns the outgoing package and whether a mount was moved.
  local function rehomeLeftoverEngineMount(opts)
    local bay = findOuterEngineBay(opts.tree, opts.ioCtx, opts.installPath)
    if not bay then return opts.outgoingPackage, false end
    if not isLeftoverEngineMount(bay, opts.ioCtx) then return opts.outgoingPackage, false end
    if opts.expectedRootName and parts.capture.nodePartName(bay.node) == opts.expectedRootName then
      return opts.outgoingPackage, false
    end

    local skipIds = opts.skipIds or {}
    local leftoverTree = copyLeftoverPackageTree(bay.node, skipIds, opts.inventory, opts.inventoryId)
    local outgoingPackage = mergeLeftoverIntoOutgoing(opts.outgoingPackage, leftoverTree, opts.innerSlotName, bay, opts.ioCtx)
    parkLeftoverParts(leftoverTree, outgoingPackage, opts.inventory, opts.newConditions, bay.path)
    clearBayOrHoist(bay, opts)
    return outgoingPackage, true
  end

  -- Post-swap checks ---------------------------------------------------------------------------------

  -- The bay holds the package's engine tree exactly, as rebuilt from the live vehicle.
  local function engineBayMatchesPackage(tree, ioCtx, package, inventoryId)
    if not tree or not ioCtx or not package or not package.tree then return false end
    local anchor = findOuterEngineBay(tree, ioCtx, package.rootPath) or parts.capture.resolveEngineCaptureAnchor(tree, ioCtx)
    if not anchor or not anchor.node then return false end
    local rebuiltTree = parts.capture.makePackageTree(anchor.node, inventoryId)
    if not rebuiltTree then return false end
    return parts.capture.packageTreesFullyMatch(package.tree, rebuiltTree)
  end

  local function nodeHasPart(node)
    local name = parts.capture.nodePartName(node)
    if name and name ~= "" then return true end
    for _, child in pairs(node.children or {}) do
      if nodeHasPart(child) then return true end
    end
    return false
  end

  -- After a store there is no engine and no mount left in the bay.
  local function engineBayIsEmptyOfMount(tree, ioCtx, package)
    if not tree then return true end
    if parts.capture.getPrimaryEngine(tree, ioCtx) then
      return false
    end
    local bay = findOuterEngineBay(tree, ioCtx, package and package.rootPath)
    if not bay or not bay.node then return true end
    return not nodeHasPart(bay.node)
  end

  -- Vehicle rebuild and rollback ----------------------------------------------------------------------

  -- Restores the snapshots, respawns the vehicle as it was, and reports the failure. Runs at most once per swap.
  local function rollbackSwap(opts, message)
    if opts.progress.finished or not inputs.isActiveTransaction(opts.transactionId) then return end
    opts.progress.finished = true
    inputs.restoreTable(opts.inventory, opts.inventorySnapshot)
    inputs.packageStore.packages = opts.packagesSnapshot
    opts.vehicles[opts.inventoryId] = opts.vehicleSnapshot
    overhaul_career_parts_partInventory.onOverhaulPartShoppingTransactionComplete()
    local respawnOk, spawnedVehicle = pcall(overhaul_career_garage_inventory.spawnVehicle, opts.inventoryId, 2, guardLifetime(inputs.repairPackageFlags))
    if not respawnOk then
      log("E", inputs.constants.logTag, "Engine package rollback respawn failed: " .. tostring(spawnedVehicle))
      inputs.repairPackageFlags()
    elseif not spawnedVehicle then
      log("E", inputs.constants.logTag, "Engine package rollback respawn returned nil")
      inputs.repairPackageFlags()
    end
    inputs.endTransaction(opts.transactionId)
    sendResult(false, message or opts.messages.rollback)
  end

  -- Runs once the rebuilt vehicle exists: restores fuel, checks the bay, and refreshes the package views.
  local function finalizeRebuiltVehicle(opts, fuelLevels)
    local newVehObj = parts.capture.getSpawnedVehicleObject(opts.inventoryId)
    restoreFuelLevels(newVehObj, fuelLevels)
    parts.thumbnails.unhideInventoryVehicle(opts.inventoryId)
    local liveData = parts.capture.getRuntimeVehicleData(opts.inventoryId)
    local liveTree = liveData and liveData.config and liveData.config.partsTree
    if not opts.verifyBay(liveTree, liveData and liveData.ioCtx or opts.runtimeData.ioCtx) then
      error("leftover engine mount")
    end
    overhaul_career_parts_partInventory.onOverhaulPartShoppingTransactionComplete()
    inputs.repairPackageFlags()
    overhaul_career_parts_vehiclePerformance.invalidateCertification(opts.inventoryId)
    overhaul_career_garage_inventory.setVehicleDirty(opts.inventoryId)
  end

  -- Called when the rebuild callback fires. A rebuild that finishes after the transaction has moved on is ignored.
  local function onRebuildReturned(opts, fuelLevels)
    if opts.progress.finished or not inputs.isActiveTransaction(opts.transactionId) then return end
    local callbackOk, callbackError = pcall(finalizeRebuiltVehicle, opts, fuelLevels)
    if not callbackOk then
      log("E", inputs.constants.logTag, opts.logs.completion .. tostring(callbackError))
      rollbackSwap(opts, opts.messages.completion)
      return
    end
    if not inputs.isActiveTransaction(opts.transactionId) then return end
    opts.progress.finished = true
    inputs.endTransaction(opts.transactionId)
    overhaul_career_saveSystem.saveCurrent()
    opts.onRebuilt()
  end

  -- Rebuilds the vehicle after the swap with its fuel restored, then either finishes the saga or rolls it back. `opts` carries the snapshots, the bay check, and the wording each saga uses.
  local function rebuildVehicleAfterSwap(opts)
    opts.progress = {finished = false}
    storeFuelLevels(opts.oldVehObj, function(fuelLevels)
      if not inputs.isActiveTransaction(opts.transactionId) then return end
      local ok, spawnedVehicle = pcall(overhaul_career_garage_inventory.spawnVehicle, opts.inventoryId, 2, function()
        onRebuildReturned(opts, fuelLevels)
      end)
      if not ok then
        log("E", inputs.constants.logTag, opts.logs.spawnFailed .. tostring(spawnedVehicle))
      end
      if not ok or not spawnedVehicle then rollbackSwap(opts, opts.messages.rebuildFailed) end
      if ok and spawnedVehicle then
        core_jobsystem.create(function(job)
          job.sleep(15)
          if not opts.progress.finished then rollbackSwap(opts, opts.messages.timeout) end
        end, 1)
      end
    end)
  end

  -- Store saga ---------------------------------------------------------------------------------------

  -- The installed engine is taken out of the vehicle: its parts go to storage and its bay is cleared. Returns false after reporting when a stored part is missing.
  local function applyStoreToInventory(context)
    local package, engine, vehicle, runtimeData = context.package, context.engine, context.vehicle, context.runtimeData
    local inventory, inventoryId = context.inventory, context.inventoryId
    local storePath = package.rootPath or engine.path
    local entries = parts.capture.collectTreePartEntries(package.tree, storePath)
    local newConditions = deepcopy(vehicle.partConditions or {})

    for _, entry in ipairs(entries) do
      local part = inventory[entry.partId]
      if not part then
        inputs.restoreTable(inventory, context.inventorySnapshot)
        inputs.packageStore.packages = context.packagesSnapshot
        inputs.endTransaction(context.transactionId)
        sendResult(false, "The engine package is missing one or more parts.")
        return false
      end
      if newConditions[part.partPath] then part.partCondition = deepcopy(newConditions[part.partPath]) end
      newConditions[part.partPath] = nil
      part.location = 0
      part.mainPart = true
      part.enginePackageId = tostring(package.id)
    end

    engine.node.id = engine.slotName or engine.node.id
    engine.node.chosenPartName = ""
    engine.node.children = {}
    engine.node.partPath = nil
    vehicle.config.partsTree = runtimeData.config.partsTree
    vehicle.config.vars = vehicle.config.vars or {}
    for variableName in pairs(package.tuning or {}) do vehicle.config.vars[variableName] = nil end
    vehicle.partConditions = newConditions
    vehicle.partList = nil
    vehicle.changedSlots = vehicle.changedSlots or {}
    vehicle.changedSlots[engine.path] = true
    package.installedInventoryId = nil
    package.updatedAt = os.time()

    rehomeLeftoverEngineMount({
      tree = runtimeData.config.partsTree,
      ioCtx = runtimeData.ioCtx,
      inventory = inventory,
      inventoryId = inventoryId,
      vehicle = vehicle,
      installPath = engine.path,
      skipIds = partIdSetFromTree(package.tree),
      innerSlotName = engine.slotName,
      outgoingPackage = package,
      newConditions = newConditions
    })
    return true
  end

  -- Reads the installed engine and checks it still matches the package. Returns the read context, or nil after reporting.
  local function readInstalledEngineForStore(package, inventoryId, transactionId)
    local inventory = inputs.getPartInventory()
    local vehicles = overhaul_career_garage_inventory.getVehicles()
    local vehicle = vehicles[inventoryId]
    local runtimeData, oldVehObj = parts.capture.getRuntimeVehicleData(inventoryId)
    local engine = runtimeData and runtimeData.config and parts.capture.resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx)
    if not vehicle or not runtimeData or not oldVehObj or not engine then
      inputs.endTransaction(transactionId)
      sendResult(false, "The installed engine could not be read.")
      return nil
    end

    local currentTree, treeError = parts.capture.makePackageTree(engine.node, inventoryId)
    if not currentTree or not parts.capture.installedPackageTreeMatches(package.tree, currentTree) then
      inputs.endTransaction(transactionId)
      sendResult(false, treeError or "The installed engine no longer matches this package.")
      return nil
    end
    return {inventory = inventory, vehicles = vehicles, vehicle = vehicle, runtimeData = runtimeData,
      oldVehObj = oldVehObj, engine = engine}
  end

  -- Runs after the thumbnail queue settles: stores the engine's parts and rebuilds the vehicle without it.
  local function continueStoreSwap(context)
    parts.thumbnails.cancelThumbnailsForPackage(context.package.id)
    if not inputs.isActiveTransaction(context.transactionId) then return end
    if not applyStoreToInventory(context) then return end
    rebuildVehicleAfterSwap({
      transactionId = context.transactionId, inventoryId = context.inventoryId, inventory = context.inventory,
      inventorySnapshot = context.inventorySnapshot, packagesSnapshot = context.packagesSnapshot,
      vehicles = context.vehicles, vehicleSnapshot = context.vehicleSnapshot, oldVehObj = context.oldVehObj,
      runtimeData = context.runtimeData,
      verifyBay = function(liveTree, liveIoCtx) return engineBayIsEmptyOfMount(liveTree, liveIoCtx, context.package) end,
      logs = {completion = "Engine package storage completion failed: ", spawnFailed = "Storing engine package failed while rebuilding the vehicle: "},
      messages = {
        rollback = "Storing the engine failed and was rolled back.",
        completion = "The stored engine transaction could not be finalized and was rolled back.",
        rebuildFailed = "The vehicle could not be rebuilt without the stored engine.",
        timeout = "The vehicle rebuild timed out and was rolled back."
      },
      onRebuilt = function()
        sendResult(true, "Stored " .. tostring(context.package.name) .. ". Use Part Customization to build another engine.")
      end
    })
  end

  local function storeInstalledPackage(packageId)
    if inputs.packageStore.transactionBusy then return end
    local valid, validationError = inputs.validateSelectedVehicle()
    if not valid then sendResult(false, validationError) return end
    local package = inputs.getPackageById(packageId)
    if not package then sendResult(false, "Engine package not found.") return end
    local inventoryId = inputs.packageStore.currentInventoryId
    local status, installedInventoryId = inputs.getPackageStatus(package)
    if status ~= "installed" or tonumber(installedInventoryId) ~= tonumber(inventoryId) then
      sendResult(false, "Only the selected vehicle's installed engine package can be stored.")
      return
    end

    local transactionId = inputs.beginTransaction()
    inputs.sendUIData()
    local conditionWait = inputs.guardConditionRequest(transactionId)
    overhaul_career_garage_inventory.updatePartConditions(nil, inventoryId, function()
      conditionWait.answered = true
      if not inputs.isActiveTransaction(transactionId) then return end
      local read = readInstalledEngineForStore(package, inventoryId, transactionId)
      if not read then return end
      local inventorySnapshot = deepcopy(read.inventory)
      local packagesSnapshot = deepcopy(inputs.packageStore.packages)
      local vehicleSnapshot = deepcopy(read.vehicle)
      package = parts.capture.captureCurrentEngineActual(inventoryId, package.name, package, read.engine)
      if not package then
        inputs.restoreTable(read.inventory, inventorySnapshot)
        inputs.packageStore.packages = packagesSnapshot
        inputs.endTransaction(transactionId)
        sendResult(false, "The installed engine package could not be refreshed.")
        return
      end

      local context = {package = package, engine = read.engine, vehicle = read.vehicle, runtimeData = read.runtimeData,
        oldVehObj = read.oldVehObj, inventory = read.inventory, vehicles = read.vehicles, inventoryId = inventoryId,
        transactionId = transactionId, inventorySnapshot = inventorySnapshot, packagesSnapshot = packagesSnapshot,
        vehicleSnapshot = vehicleSnapshot}
      if parts.thumbnails.packageNeedsThumbnail(package) then
        parts.thumbnails.enqueueEngineThumbnail(package, inventoryId)
      end
      parts.thumbnails.whenThumbnailsIdleOrTimeout(function() continueStoreSwap(context) end, 8)
    end)
  end

  -- Install saga -------------------------------------------------------------------------------------

  -- Writes the incoming engine into its bay, the vehicle config and the package records. Returns the outgoing package, which a leftover engine mount can replace with a new one.
  local function commitInstalledPackageTopology(swap)
    local targetCandidate = swap.targetCandidate
    local targetPackage = swap.targetPackage
    local vehicle = swap.vehicle
    local outgoingPackage = swap.outgoingPackage

    if targetCandidate.parentNode then
      targetCandidate.node = parts.capture.ensureChildSlotNode(targetCandidate.parentNode, targetCandidate.slotName, targetCandidate.path)
    end
    targetCandidate.node.id = targetCandidate.slotName or targetCandidate.node.id
    targetCandidate.node.chosenPartName = targetPackage.tree.name
    targetCandidate.node.children = parts.capture.makeConfigTree(targetPackage.tree, targetCandidate.path, targetCandidate.slotName).children
    targetCandidate.node.path = targetCandidate.path
    targetCandidate.node.partPath = targetCandidate.path .. targetPackage.tree.name
    vehicle.config.partsTree = swap.runtimeData.config.partsTree
    vehicle.config.vars = vehicle.config.vars or {}
    if outgoingPackage then
      for variableName in pairs(outgoingPackage.tuning or {}) do vehicle.config.vars[variableName] = nil end
    end
    for variableName, value in pairs(targetPackage.tuning or {}) do vehicle.config.vars[variableName] = value end
    vehicle.partConditions = swap.newConditions
    vehicle.partList = nil
    vehicle.changedSlots = vehicle.changedSlots or {}
    vehicle.changedSlots[targetCandidate.path] = true

    local rehomed
    outgoingPackage, rehomed = rehomeLeftoverEngineMount({
      tree = swap.runtimeData.config.partsTree,
      ioCtx = swap.runtimeData.ioCtx,
      inventory = swap.inventory,
      inventoryId = swap.inventoryId,
      vehicle = vehicle,
      installPath = targetCandidate.path,
      expectedRootName = targetPackage.tree.name,
      skipIds = partIdSetFromTree(targetPackage.tree),
      innerSlotName = targetCandidate.slotName,
      outgoingPackage = outgoingPackage,
      incomingPackage = targetPackage,
      newConditions = swap.newConditions
    })

    if outgoingPackage then
      outgoingPackage.installedInventoryId = nil
      outgoingPackage.updatedAt = os.time()
    end
    targetPackage.installedInventoryId = swap.inventoryId
    targetPackage.lastInstalledModel = swap.targetModel
    if not rehomed then
      targetPackage.rootSlotName = targetCandidate.slotName
      targetPackage.rootPath = targetCandidate.path
    end
    targetPackage.updatedAt = os.time()
    return outgoingPackage
  end

  -- Captures the engine currently in the vehicle as the outgoing package (or nil when the bay is empty). Returns the package, or nil plus the reason when the capture fails.
  local function captureOutgoingEngine(runtimeData, inventoryId, targetCandidate, currentEngine)
    local outgoingPackage = parts.capture.findPackageForInventory(inventoryId)
    local outgoingName = outgoingPackage and outgoingPackage.name or nil
    local outgoingCaptureAnchor = currentEngine
    local isInnerCeepTarget = parts.capture.parentIsCeepHub(targetCandidate.parentPartName, runtimeData.ioCtx)
    if not isInnerCeepTarget then
      outgoingCaptureAnchor = parts.capture.resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx) or currentEngine
    end
    return parts.capture.captureCurrentEngineActual(inventoryId, outgoingName, outgoingPackage, outgoingCaptureAnchor)
  end

  -- Moves the outgoing engine's parts to storage in the new config.
  local function parkOutgoingParts(outgoingPackage, outgoingEntries, inventory, newConditions)
    for _, entry in ipairs(outgoingEntries) do
      local part = inventory[entry.partId]
      if part then
        if newConditions[part.partPath] then part.partCondition = deepcopy(newConditions[part.partPath]) end
        newConditions[part.partPath] = nil
        part.location = 0
        part.mainPart = true
        part.enginePackageId = tostring(outgoingPackage.id)
      end
    end
  end

  -- Marks each incoming part as installed in this vehicle. Returns false when a part is no longer in storage.
  local function claimIncomingParts(incomingEntries, inventory, inventoryId, targetPackage, targetModel, availableParts, newConditions)
    for _, entry in ipairs(incomingEntries) do
      local part = inventory[entry.partId]
      if not part or tonumber(part.location) ~= 0 then return false end
      part.location = inventoryId
      part.containingSlot = entry.containingSlot
      part.partPath = entry.partPath
      part.vehicleModel = targetModel
      part.description = availableParts[entry.name] or part.description
      part.mainPart = true
      part.enginePackageId = tostring(targetPackage.id)
      newConditions[entry.partPath] = deepcopy(part.partCondition or {integrityValue = 1, visualValue = 1, odometer = 0})
    end
    return true
  end

  -- Reads the vehicle for an install. Returns the read context, or nil after reporting.
  local function readVehicleForInstall(inventoryId, transactionId)
    local inventory = inputs.getPartInventory()
    local vehicles = overhaul_career_garage_inventory.getVehicles()
    local vehicle = vehicles[inventoryId]
    local runtimeData, oldVehObj = parts.capture.getRuntimeVehicleData(inventoryId)
    if not vehicle or not runtimeData or not oldVehObj then
      inputs.endTransaction(transactionId)
      sendResult(false, "The selected vehicle is no longer available.")
      return nil
    end
    return {inventory = inventory, vehicles = vehicles, vehicle = vehicle, runtimeData = runtimeData, oldVehObj = oldVehObj}
  end

  -- Captures the outgoing engine and moves its parts to storage. Returns the outgoing package (nil when the bay is empty), or false after reporting when the capture fails.
  local function storeOutgoingEngine(read, inventoryId, targetCandidate, transactionId)
    local outgoingPackage
    local currentEngine = parts.capture.getPrimaryEngine(read.runtimeData.config.partsTree, read.runtimeData.ioCtx)
    if currentEngine then
      local captureError
      outgoingPackage, captureError = captureOutgoingEngine(read.runtimeData, inventoryId, targetCandidate, currentEngine)
      if not outgoingPackage then
        inputs.endTransaction(transactionId)
        sendResult(false, captureError)
        return false
      end
    end
    return outgoingPackage
  end

  -- Installs the target package into the bay: captures the outgoing engine, moves parts, and commits the config. Returns the outgoing package, or false after reporting when the swap cannot be applied.
  local function applyInstallToInventory(read, inventoryId, targetPackage, targetCandidate, transactionId, snapshots)
    local outgoingPackage = storeOutgoingEngine(read, inventoryId, targetCandidate, transactionId)
    if outgoingPackage == false then return false end

    local outgoingEntries = outgoingPackage and parts.capture.collectTreePartEntries(outgoingPackage.tree, outgoingPackage.rootPath) or {}
    local incomingEntries = parts.capture.collectTreePartEntries(targetPackage.tree, targetCandidate.path)
    local newConditions = deepcopy(read.vehicle.partConditions or {})
    parkOutgoingParts(outgoingPackage, outgoingEntries, read.inventory, newConditions)

    local targetModel = read.vehicle.model
    local availableParts = inputs.jbeamIO.getAvailableParts(read.runtimeData.ioCtx)
    if not claimIncomingParts(incomingEntries, read.inventory, inventoryId, targetPackage, targetModel, availableParts, newConditions) then
      inputs.restoreTable(read.inventory, snapshots.inventory)
      inputs.packageStore.packages = snapshots.packages
      inputs.endTransaction(transactionId)
      sendResult(false, "An engine package part became unavailable during the swap.")
      return false
    end

    return commitInstalledPackageTopology({
      targetCandidate = targetCandidate,
      targetPackage = targetPackage,
      vehicle = read.vehicle,
      runtimeData = read.runtimeData,
      outgoingPackage = outgoingPackage,
      newConditions = newConditions,
      inventory = read.inventory,
      inventoryId = inventoryId,
      targetModel = targetModel
    })
  end

  local function installPackage(packageId)
    if inputs.packageStore.transactionBusy then return end
    local valid, validationError = inputs.validateSelectedVehicle()
    if not valid then sendResult(false, validationError) return end
    local targetPackage = inputs.getPackageById(packageId)
    if not targetPackage then sendResult(false, "Engine package not found.") return end
    local status = inputs.getPackageStatus(targetPackage)
    if status ~= "stored" then sendResult(false, "Only stored engine packages can be installed.") return end

    local inventoryId = inputs.packageStore.currentInventoryId
    local targetCandidate, fitError = parts.capture.findCompatibleTarget(targetPackage, inventoryId)
    if not targetCandidate then sendResult(false, fitError) return end

    local transactionId = inputs.beginTransaction()
    inputs.sendUIData()
    local conditionWait = inputs.guardConditionRequest(transactionId)
    overhaul_career_garage_inventory.updatePartConditions(nil, inventoryId, function()
      conditionWait.answered = true
      if not inputs.isActiveTransaction(transactionId) then return end
      local read = readVehicleForInstall(inventoryId, transactionId)
      if not read then return end

      local snapshots = {inventory = deepcopy(read.inventory), packages = deepcopy(inputs.packageStore.packages)}
      local vehicleSnapshot = deepcopy(read.vehicle)
      local outgoingPackage = applyInstallToInventory(read, inventoryId, targetPackage, targetCandidate, transactionId, snapshots)
      if outgoingPackage == false then return end

      rebuildVehicleAfterSwap({
        transactionId = transactionId, inventoryId = inventoryId, inventory = read.inventory,
        inventorySnapshot = snapshots.inventory, packagesSnapshot = snapshots.packages,
        vehicles = read.vehicles, vehicleSnapshot = vehicleSnapshot, oldVehObj = read.oldVehObj, runtimeData = read.runtimeData,
        verifyBay = function(liveTree, liveIoCtx)
          return engineBayMatchesPackage(liveTree, liveIoCtx, targetPackage, inventoryId)
        end,
        logs = {completion = "Engine swap completion failed: ", spawnFailed = "Installing engine package failed while rebuilding the vehicle: "},
        messages = {
          rollback = "The engine swap failed and was rolled back.",
          completion = "The rebuilt vehicle could not be finalized; the engine swap was rolled back.",
          rebuildFailed = "The vehicle could not be rebuilt; the engine swap was rolled back.",
          timeout = "The vehicle rebuild timed out; the engine swap was rolled back."
        },
        onRebuilt = function()
          local successMessage = "Installed " .. tostring(targetPackage.name) .. "."
          if outgoingPackage then
            successMessage = successMessage .. " The outgoing engine was stored as " .. tostring(outgoingPackage.name) .. "."
          end
          sendResult(true, successMessage)
          if parts.thumbnails.packageNeedsThumbnail(targetPackage) then
            parts.thumbnails.enqueueEngineThumbnail(targetPackage, inventoryId)
          end
        end
      })
    end)
  end

  -- Public API ---------------------------------------------------------------------------------------

  return {
    installPackage = installPackage,
    storeInstalledPackage = storeInstalledPackage,
  }
end

return install
