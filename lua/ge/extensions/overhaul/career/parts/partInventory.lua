-- Part inventory: installed parts, stored parts and vehicle slot reconciliation.
-- The stock fork owns the persisted inventory and waits for vehicle condition capture before saving.
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/partInventory.lua (BeamNG 0.40).

local M = {}

local jbeamIO = require('jbeam/io')
local saveStore = require('overhaul/lib/save/store')

-- SaveStore key over the file this module writes today (metadata only). It completes after
-- the vehicle data arrives, through the async save extension of the same name.
saveStore.registerKeys({
  {key = "parts.inventory", owner = "overhaul_career_parts_partInventory", files = {"career/partInventory.json"}, phase = "vehicleSave", required = true, async = "partInventory"},
})

local imgui = ui_imgui

local minimumVersion = 42

local partInventory = {}
local serializedPartChunks = {}

local partsBefore = {}
local partsAfter
local slotToPartIdMap = {}
local partPathToPartIdMap = {}
local partInventoryOpen = false
local closeMenuAfterSaving

local currentVehicleInventoryIdForMenu

local function getNodeFromSlotPath(tree, path)
  if not tree or not path then return nil end

  if path == "/" then return tree end

  local segments = {}
  for segment in string.gmatch(path, "[^/]+") do
    table.insert(segments, segment)
  end

  local currentNode = tree
  for _, segment in ipairs(segments) do
    if currentNode.children and currentNode.children[segment] then
      currentNode = currentNode.children[segment]
    else
      return nil
    end
  end

  return currentNode
end

local function getDisconnectedParts(initialRemovedNode, vehicle)
  local disconnectedParts = {}

  local function traverseTree(node)
    if not node then return end

    if node.chosenPartName and node.chosenPartName ~= "" then
      for partId, inventoryPart in pairs(partInventory) do
        if inventoryPart.containingSlot == node.path and inventoryPart.location == vehicle.id then
          disconnectedParts[partId] = inventoryPart
          break
        end
      end
    end

    if node.children then
      for _, childNode in pairs(node.children) do
        traverseTree(childNode)
      end
    end
  end

  traverseTree(initialRemovedNode)

  return disconnectedParts
end

local function removeDisconnectedParts(vehicle, removedPartId)
  local initialRemovedPart = partInventory[removedPartId]
  local initialRemovedNode = getNodeFromSlotPath(vehicle.config.partsTree, initialRemovedPart.containingSlot)

  local disconnectedParts = getDisconnectedParts(initialRemovedNode, vehicle)
  initialRemovedNode.chosenPartName = ""
  initialRemovedNode.children = {}
  for partId, part in pairs(disconnectedParts) do
    vehicle.partConditions[part.partPath] = nil
    partsAfter[partId] = nil
  end
end

local function getPartsThatMoved(partsBefore, partsAfter)
  local movedOut = {}
  for partId, _ in pairs(partsBefore) do
    if not partsAfter[partId] then
      movedOut[partId] = true
    end
  end
  return {movedOut = movedOut}
end

local function initConditionsCallback(_, inventoryId)
  local vehicleId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local vehicleObject = getObjectByID(vehicleId)
  queueCallbackInVehicle(vehicleObject, "overhaul_career_parts_partInventory.changedPartsCallback", "partCondition.getConditions()", inventoryId)
end

local function getPartIdsFromVehicle(inventoryId)
  local result = {}
  for partId, part in pairs(partInventory) do
    if part.location == inventoryId then
      result[partId] = true
    end
  end
  return result
end

local function sellParts(partIds, useResaleValue)
  local getValue = useResaleValue == false and overhaul_career_market_valueCalculator.getPartValue
    or overhaul_career_market_valueCalculator.getPartResaleValue
  local totalSalePrice = 0
  for _, partId in ipairs(partIds) do
    local part = partInventory[partId]
    if not part or part.location ~= 0 then return end
    totalSalePrice = totalSalePrice + getValue(part)
  end

  overhaul_career_economy_playerAttributes.addAttributes({money=totalSalePrice}, require("overhaul/lib/finance/metadata").tag({tags={"partsSold","selling"}, label = {txt = "ui.career.partInventory.soldParts", context = {count = #partIds}}}, "sale", {vehicleRelated = false}))
  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  for _, partId in ipairs(partIds) do
    partInventory[partId] = nil
  end

  if partInventoryOpen then
    M.sendUIData()
  end
end

local function removePart(partId, inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  local vehicleModel = vehicle.model
  local vehicleData = {}
  vehicleData.config = vehicle.config
  vehicleData.keepOtherVehRotation = true
  partsAfter = getPartIdsFromVehicle(inventoryId)
  partsAfter[partId] = nil
  removeDisconnectedParts(vehicle, partId)

  local partConditions = vehicle.partConditions

  local brokenPartCount = overhaul_career_market_valueCalculator.getNumberOfBrokenParts(partConditions)
  if brokenPartCount > 0 and brokenPartCount < overhaul_career_market_valueCalculator.getBrokenPartsThreshold() then
    overhaul_career_repair_insurance.repairPartConditions({partConditions = partConditions})
  end

  local vehicleId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  if vehicleId then
    local vehicleObject = getObjectByID(vehicleId)
    core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = false}, vehicleId)
    core_vehicles.replaceVehicle(vehicleModel, vehicleData, vehicleObject)
    queueCallbackInVehicle(vehicleObject, "overhaul_career_parts_partInventory.initConditionsCallback", "partCondition.initConditions(" .. serialize(partConditions) .. ")", inventoryId)
  else
    M.changedPartsCallback(partConditions, inventoryId)
  end
  overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
end

local function addPartFromTree(result, tree, vehicleData, availableParts, vehicleObject, inventoryId, partConditions)
  if tree.chosenPartName and tree.chosenPartName ~= "" then
    local vehicleDefinition = vehicleData.vdata or {}
    local activeParts = vehicleDefinition.activeParts or {}
    local activePartsData = vehicleDefinition.activePartsData or {}
    local activePartKey = activeParts[tree.partPath]
    local activePartData = activePartKey and activePartsData[activePartKey]
    local availablePartData = availableParts[tree.chosenPartName]

    local part = {}
    part.name = tree.chosenPartName
    part.value = (activePartData and activePartData.information and activePartData.information.value)
      or (availablePartData and availablePartData.information and availablePartData.information.value)
      or 100
    part.description = availablePartData or {}
    part.partCondition = partConditions[tree.partPath]
    part.tags = {}
    part.vehicleModel = vehicleObject:getJBeamFilename()
    part.location = inventoryId
    part.containingSlot = tree.path
    part.partPath = part.containingSlot .. part.name
    part.mainPart = part.containingSlot == "/"

    table.insert(result, part)
  end

  if tree.children then
    for childSlot, childInfo in pairs(tree.children) do
      addPartFromTree(result, childInfo, vehicleData, availableParts, vehicleObject, inventoryId, partConditions)
    end
  end
end

local function generateAndGetPartsFromVehicle(inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  local vehicleId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local vehicleObject = getObjectByID(vehicleId)
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehicleId)
  local partConditions = vehicle.partConditions
  if not partConditions then return {} end
  local availableParts = jbeamIO.getAvailableParts(vehicleData.ioCtx)

  local result = {}

  -- Start with the root part (usually "main")
  addPartFromTree(result, vehicleData.config.partsTree, vehicleData, availableParts, vehicleObject, inventoryId, partConditions)
  return result
end

local function updateVehicleMaps()
  -- TODO does this need to be cached?
  -- Make a map from slot to its part
  table.clear(slotToPartIdMap)
  table.clear(partPathToPartIdMap)
  for partId, part in pairs(partInventory) do
    slotToPartIdMap[part.location] = slotToPartIdMap[part.location] or {}
    slotToPartIdMap[part.location][part.containingSlot] = partId

    if part.location > 0 then
      partPathToPartIdMap[part.location] = partPathToPartIdMap[part.location] or {}
      partPathToPartIdMap[part.location][part.partPath] = partId
    end
  end
end

-- TODO could even update once every time before removing a part
local function updatePartConditionsInInventory(inventoryId)
  local vehicles = overhaul_career_garage_inventory.getVehicles()
  local function updatePart(part)
    local vehicle = part and vehicles[part.location]
    local condition = vehicle and vehicle.partConditions and vehicle.partConditions[part.partPath]
    if condition then
      part.partCondition = condition
    end
  end

  local requestedInventoryId = inventoryId
  inventoryId = tonumber(inventoryId)
  if inventoryId then
    local partIdsBySlot = slotToPartIdMap[inventoryId]
    if partIdsBySlot then
      for _, partId in pairs(partIdsBySlot) do
        updatePart(partInventory[partId])
      end
      return
    end

    -- Maps can briefly be unavailable while a newly added vehicle is being
    -- reconciled. Limit that fallback scan to the affected vehicle.
    for _, part in pairs(partInventory) do
      if tonumber(part.location) == inventoryId then
        updatePart(part)
      end
    end
    return
  end

  if requestedInventoryId ~= nil then
    return
  end

  for _, part in pairs(partInventory) do
    if tonumber(part.location) and tonumber(part.location) > 0 then
      updatePart(part)
    end
  end
end

local function addPartToInventory(part)
  local nextAvailablePartId = 1
  while partInventory[nextAvailablePartId] do
    nextAvailablePartId = nextAvailablePartId + 1
  end
  partInventory[nextAvailablePartId] = part
end

-- Auxiliary JBeam plumbing has no inventory value or player-facing controls.
local function isHiddenInUI(part)
  return part.description and part.description.isAuxiliary and (part.value or 0) == 0
end

local function removeHiddenPartsInStorage()
  for partId, part in pairs(partInventory) do
    if part.location == 0 and not part.enginePackageId and isHiddenInUI(part) then
      partInventory[partId] = nil
    end
  end
end

local function syncEnginePackageInstallCache(packageId)
  if not packageId or not overhaul_career_parts_engines_enginePackages or not overhaul_career_parts_engines_enginePackages.getPackage then return end
  local package = overhaul_career_parts_engines_enginePackages.getPackage(packageId)
  if not package or not overhaul_career_parts_engines_enginePackages.getPackageStatus then return end
  local status, installedInventoryId = overhaul_career_parts_engines_enginePackages.getPackageStatus(package)
  if status == "installed" then
    package.installedInventoryId = installedInventoryId
  else
    package.installedInventoryId = nil
  end
end


local function changedPartsCallback(partConditions, inventoryId)
  overhaul_career_garage_inventory.getPartConditionsCallback(partConditions, inventoryId)
  local partsThatMoved = getPartsThatMoved(partsBefore, partsAfter)
  partsAfter = nil
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
  for partId, _ in pairs(partsThatMoved.movedOut) do
    local part = partInventory[partId]
    part.location = 0
    vehicle.changedSlots[part.containingSlot] = true
  end
  updateVehicleMaps()
  if partInventoryOpen then
    M.sendUIData()
  end
end

local function addNewPartsToInventory(inventoryId)
  local newParts = generateAndGetPartsFromVehicle(inventoryId)
  for _, part in ipairs(newParts) do
    addPartToInventory(part)
  end
  overhaul_career_ui_log.addLog(string.format("Added new vehicles' parts to inventory %d", inventoryId), "partInventory")
  return newParts
end

-- Re-reads the parts from the currently spawned vehicle and reconciles them with the part inventory.
local function updatePartsToMatchSpawnedVehicle(inventoryId)
  local newParts = generateAndGetPartsFromVehicle(inventoryId)
  local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]

  -- Update the saved vehicle config
  local vehicleId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local vehicleData = vehicleId and extensions.core_vehicle_manager.getVehicleData(vehicleId)
  if vehicle and vehicleData and vehicleData.config then
    local licenseName = vehicle.config and vehicle.config.licenseName
    local partConfigFilename = vehicle.config and vehicle.config.partConfigFilename
    vehicle.config = vehicleData.config
    vehicle.config.licenseName = licenseName
    -- Preserve the original (dealership) config reference used for base value / thumbnail lookups.
    if partConfigFilename then
      vehicle.config.partConfigFilename = partConfigFilename
    end
  end

  -- Index the existing inventory parts for this vehicle by their slot path.
  local oldPartsBySlot = {}
  for partId, part in pairs(partInventory) do
    if part.location == inventoryId then
      oldPartsBySlot[part.containingSlot] = {id = partId, part = part}
    end
  end

  local added, removed, changed = {}, {}, {}
  local matchedSlots = {}
  local vehicleYear = vehicle and vehicle.year
  local spawnedSlots = {}
  for _, part in ipairs(newParts) do spawnedSlots[part.containingSlot] = true end

  for _, newPart in ipairs(newParts) do
    local existing = oldPartsBySlot[newPart.containingSlot]
    if not existing then
      local candidate
      for slot, info in pairs(oldPartsBySlot) do
        if not spawnedSlots[slot] and not matchedSlots[slot] and info.part.name == newPart.name then
          if candidate then candidate = nil break end
          candidate = info
        end
      end
      existing = candidate
    end
    if existing then
      matchedSlots[existing.part.containingSlot] = true
      if existing.part.name ~= newPart.name then
        table.insert(changed, {old = existing.part, new = newPart})
        local condition = vehicle and vehicle.partConditions and vehicle.partConditions[existing.part.partPath]
        if condition then existing.part.partCondition = condition end
        existing.part.location = 0
        if existing.part.enginePackageId then syncEnginePackageInstallCache(existing.part.enginePackageId) end
        if vehicle and vehicle.partConditions then
          vehicle.partConditions[existing.part.partPath] = nil
        end
        newPart.year = vehicleYear
        newPart.partCondition = newPart.partCondition or {integrityValue = 1, odometer = 0, visualValue = 1}
        if vehicle and vehicle.partConditions then
          vehicle.partConditions[newPart.partPath] = newPart.partCondition
        end
        addPartToInventory(newPart)
      else
        newPart.partCondition = existing.part.partCondition or newPart.partCondition
        newPart.tags = existing.part.tags or newPart.tags
        newPart.year = existing.part.year or vehicleYear
        newPart.repairCount = existing.part.repairCount
        newPart.primered = existing.part.primered
        newPart.enginePackageId = existing.part.enginePackageId
        newPart.mainPart = existing.part.mainPart
        if existing.part.partPath ~= newPart.partPath and vehicle and vehicle.partConditions then
          vehicle.partConditions[existing.part.partPath] = nil
        end
        if vehicle and vehicle.partConditions and newPart.partCondition then
          vehicle.partConditions[newPart.partPath] = newPart.partCondition
        end
        partInventory[existing.id] = newPart
      end
    else
      newPart.year = vehicleYear
      newPart.partCondition = newPart.partCondition or {integrityValue = 1, odometer = 0, visualValue = 1}
      if vehicle and vehicle.partConditions then
        vehicle.partConditions[newPart.partPath] = newPart.partCondition
      end
      addPartToInventory(newPart)
      table.insert(added, newPart)
    end
  end

  -- Anything that was in the vehicle but no longer exists in the tree was removed.
  for slot, info in pairs(oldPartsBySlot) do
    if not matchedSlots[slot] then
      local condition = vehicle and vehicle.partConditions and vehicle.partConditions[info.part.partPath]
      if condition then info.part.partCondition = condition end
      info.part.location = 0
      if info.part.enginePackageId then syncEnginePackageInstallCache(info.part.enginePackageId) end
      if vehicle and vehicle.partConditions then
        vehicle.partConditions[info.part.partPath] = nil
      end
      table.insert(removed, info.part)
    end
  end

  updateVehicleMaps()
  overhaul_career_garage_inventory.setVehicleDirty(inventoryId)
  overhaul_career_ui_log.addLog(string.format("Reconciled parts for inventory %d: %d added, %d removed, %d changed", inventoryId, #added, #removed, #changed), "partInventory")
  return {added = added, removed = removed, changed = changed}
end

local function debugMenu()
  imgui.SetNextWindowSize(imgui.ImVec2(300, 300), imgui.Cond_FirstUseEver)
  local partInventoryOpenPtr = imgui.BoolPtr(true)
  imgui.Begin("Part Inventory", partInventoryOpenPtr)
  if not partInventoryOpenPtr[0] then
    partInventoryOpen = false
  end
  imgui.BeginChild1("vehiclePartsOuter", imgui.ImVec2(220, 0), imgui.WindowFlags_ChildWindow)
  imgui.Text("Parts in current vehicle")
  imgui.BeginChild1("partsInVehicle", imgui.ImVec2(200, 0), imgui.WindowFlags_ChildWindow)
  imgui.EndChild()
  imgui.EndChild()
  imgui.SameLine()
  imgui.BeginChild1("inventoryPartsOuter", imgui.ImVec2(0, 0), imgui.WindowFlags_ChildWindow)
  imgui.Text("Parts in inventory")

  if imgui.BeginTable('', 8) then
    imgui.TableSetupScrollFreeze(0,1)
    imgui.TableSetupColumn("Id",imgui.TableColumnFlags_WidthStretch,5)
    imgui.TableSetupColumn("Name",imgui.TableColumnFlags_WidthStretch,20)
    imgui.TableSetupColumn("Vehicle Model",imgui.TableColumnFlags_WidthStretch,10)
    imgui.TableSetupColumn("Description",imgui.TableColumnFlags_WidthStretch,20)
    imgui.TableSetupColumn("Distance Driven",imgui.TableColumnFlags_WidthStretch,10)
    imgui.TableSetupColumn("Value",imgui.TableColumnFlags_WidthStretch,5)
    imgui.TableSetupColumn("Location",imgui.TableColumnFlags_WidthStretch,5)
    imgui.TableSetupColumn("Put into current vehicle",imgui.TableColumnFlags_WidthStretch,20)
    imgui.TableHeadersRow()
    imgui.TableNextColumn()
    for partId, part in pairs(partInventory) do
      imgui.Text("" .. partId)
      imgui.TableNextColumn()
      imgui.Text(part.name)
      imgui.TableNextColumn()
      imgui.Text(part.vehicleModel)
      imgui.TableNextColumn()
      imgui.Text(part.description.description or "missing")
      imgui.TableNextColumn()
      imgui.Text("" .. part.partCondition["odometer"])
      imgui.TableNextColumn()
      imgui.Text("" .. part.value)
      imgui.TableNextColumn()
      imgui.Text("" .. part.location)
      imgui.TableNextColumn()
      imgui.TableNextColumn()
    end

    imgui.EndTable()
  end
  imgui.EndChild()
  imgui.End()
end

local updateVehicleParts
local addNewVehiclePartsInventoryId
local function onUpdate()
  -- Add a new vehicles' parts to the inventory
  if addNewVehiclePartsInventoryId and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(addNewVehiclePartsInventoryId) and overhaul_career_garage_inventory.getVehicles()[addNewVehiclePartsInventoryId].partConditions then
    local newParts = addNewPartsToInventory(addNewVehiclePartsInventoryId)
    extensions.hook("onOverhaulAddedVehiclePartsToInventory", addNewVehiclePartsInventoryId, newParts)
    updateVehicleMaps()
    addNewVehiclePartsInventoryId = nil
  end

  -- Update cached maps for the current vehicle
  -- TODO why does this need to be async?
  if updateVehicleParts and (overhaul_career_garage_inventory.getCurrentVehicle() and overhaul_career_garage_inventory.getVehicles()[overhaul_career_garage_inventory.getCurrentVehicle()].partConditions) then
    updateVehicleMaps()
    updateVehicleParts = nil
  end

end

local function getVehicleModelDisplayName(vehicleModel)
  if not vehicleModel then return "" end
  local modelEntry = core_vehicles.getModel(vehicleModel)
  if not modelEntry or tableIsEmpty(modelEntry) then
    return vehicleModel
  end
  local model = modelEntry.model or modelEntry
  if model.Brand and model.Name then
    return model.Brand .. " " .. model.Name
  end
  return model.Name or vehicleModel
end

local function sendUIData()
  local data = {}
  local partList = {}
  local vehicles = overhaul_career_garage_inventory.getVehicles()
  local vehiclesUiData = {}

  data.brokenVehicleInventoryIds = {}
  for inventoryId, vehicle in pairs(vehicles) do
    data.brokenVehicleInventoryIds[tostring(inventoryId)] = overhaul_career_repair_insurance.inventoryVehNeedsRepair(inventoryId)

    local vehicleUiData = deepcopy(vehicle)
    vehicleUiData.thumbnail = (overhaul_career_garage_inventory.getVehicleThumbnail(inventoryId) or "") .. "?" .. (vehicleUiData.dirtyDate or "")
    vehicleUiData.niceName = core_locales.translateWithOrWithoutContext(vehicleUiData.niceName)
    vehiclesUiData[tostring(inventoryId)] = vehicleUiData
  end

  for partId, part in pairs(partInventory) do
    if not part.mainPart and not isHiddenInUI(part) then
      local newPart = deepcopy(part)
      newPart.id = partId
      newPart.name = core_locales.translateWithOrWithoutContext(newPart.name)
      if newPart.description and newPart.description.description then
        newPart.description.description = core_vehicle_partmgmt.getTranslation(
          newPart.description.description,
          "ui.vehicleconfig.information.name."
        )
      else
        newPart.description = {description = _tr("ui.career.partShopping.noDescriptionFound")}
      end
      newPart.vehicleModelDisplayName = getVehicleModelDisplayName(newPart.vehicleModel)
      newPart.finalValue = overhaul_career_market_valueCalculator.getPartResaleValue(newPart)
      newPart.accessible = not (vehicles[newPart.location] and
          (vehicles[newPart.location].timeToAccess or
          data.brokenVehicleInventoryIds[tostring(newPart.location)] or
          not overhaul_career_permissions.getStatusForTag("partSwapping", {inventoryId = newPart.location}).allow)
        )
      table.insert(partList, newPart)
    end
  end
  data.partList = partList
  data.currentVehicle = currentVehicleInventoryIdForMenu
  data.vehicles = vehiclesUiData

  guihooks.trigger('partInventoryData', data)
end

-- Bound native decoding as well as Lua serialization; decoding one fleet-sized blob cannot yield.
local function onOverhaulVehicleSaveFinished(currentSavePath)
  local partsPerChunk = 64
  local saveJson = require('overhaul/lib/save/jsonWriter')
  local chunks, batch, batchCount = {}, {}, 0
  local function captureBatch()
    local blob = saveJson.encodeWithout(batch, "description")
    local snapshot
    if not blob then
      snapshot = {}
      for partId, part in pairs(batch) do
        local saved = {}
        for key, value in pairs(part) do
          if key ~= "description" then saved[key] = value end
        end
        snapshot[partId] = saved
      end
      snapshot = saveJson.snapshot(snapshot)
    end
    local previous = blob and serializedPartChunks[#chunks + 1]
    chunks[#chunks + 1] = {blob = blob, snapshot = snapshot,
      cached = previous and previous.blob == blob and previous or nil}
    batch, batchCount = {}, 0
  end
  for partId, part in pairs(partInventory) do
    batch[partId], batchCount = part, batchCount + 1
    if batchCount == partsPerChunk then captureBatch() end
  end
  if batchCount > 0 then captureBatch() end
  local function restoreChunk(chunk)
    return chunk.snapshot or require('string.buffer').decode(chunk.blob)
  end
  local fileName = currentSavePath .. "/career/partInventory.json"
  if not overhaul_career_saveSystem.deferSaveWork or not overhaul_career_saveSystem.captureSaveWrites then
    local parts = {}
    for _, chunk in ipairs(chunks) do
      for partId, part in pairs(restoreChunk(chunk)) do parts[partId] = part end
    end
    jsonWriteFile(fileName, {serialize(parts)}, true)
    return
  end
  local generation = overhaul_career_saveSystem.registerAsyncSaveExtension("partInventory")
  -- The file is one JSON string holding the serialized table; it is built already escaped.
  local escape = saveJson.escape
  local serializedPartsBuffer, lastSerializedPartId, serializedPartCount, serializationTimeMs = nil, nil, 0, 0
  local reusedPartCount = 0
  local chunkIndex, partsSnapshot, currentChunk, chunkBuffer, chunkStartCount = 1, nil, nil, nil, 0
  local nextSerializedChunks = {}
  local function appendEscapedValue(value)
    chunkBuffer:put(escape(serialize(value)))
  end
  local function step(budgetMs)
    if not overhaul_career_saveSystem.isAsyncSaveExtensionCurrent("partInventory", generation) then return end
    local clock = os.clockhp or os.clock
    local serializationStartedAtSeconds = clock()
    local serializationBudgetSeconds = (budgetMs or 2) / 1000
    if not serializedPartsBuffer then
      serializedPartsBuffer = require('string.buffer').new()
      serializedPartsBuffer:put('["{')
    end
    local hasSerializedAllParts = false
    while true do
      if not partsSnapshot then
        local chunk = chunks[chunkIndex]
        if not chunk then hasSerializedAllParts = true; break end
        if chunk.cached then
          serializedPartsBuffer:put(chunk.cached.text)
          serializedPartCount = serializedPartCount + chunk.cached.count
          reusedPartCount = reusedPartCount + chunk.cached.count
          nextSerializedChunks[chunkIndex] = chunk.cached
          chunks[chunkIndex] = false
          chunkIndex = chunkIndex + 1
        else
          partsSnapshot = restoreChunk(chunk)
          currentChunk, chunkBuffer, chunkStartCount = chunk, require('string.buffer').new(), serializedPartCount
        end
      end
      if partsSnapshot then
        local partId, part = next(partsSnapshot, lastSerializedPartId)
        lastSerializedPartId = partId
        if partId == nil then
          local text = chunkBuffer:tostring()
          serializedPartsBuffer:put(text)
          nextSerializedChunks[chunkIndex] = currentChunk.blob and {
            blob = currentChunk.blob, text = text, count = serializedPartCount - chunkStartCount} or false
          chunks[chunkIndex] = false
          chunkIndex = chunkIndex + 1
          partsSnapshot, currentChunk, chunkBuffer = nil, nil, nil
        else
          chunkBuffer:put("[")
          appendEscapedValue(partId)
          chunkBuffer:put("]=")
          appendEscapedValue(part)
          chunkBuffer:put(",")
          serializedPartCount = serializedPartCount + 1
        end
      end
      if clock() - serializationStartedAtSeconds >= serializationBudgetSeconds then break end
    end
    serializationTimeMs = serializationTimeMs + (clock() - serializationStartedAtSeconds) * 1000
    if not hasSerializedAllParts then
      overhaul_career_saveSystem.deferSaveWork(step)
      return
    end
    serializedPartsBuffer:put('}"]')
    local serializedPartsJson = serializedPartsBuffer:tostring()
    -- Reuse only equal frozen values; cached text is independent of rotated files and failed writes.
    serializedPartChunks = nextSerializedChunks
    serializedPartsBuffer, partsSnapshot, chunks = nil, nil, nil
    overhaul_career_saveSystem.captureSaveWrites(function(writer)
      writer.write(fileName .. ".tmp", serializedPartsJson)
      writer.rename(fileName .. ".tmp", fileName)
    end)
    log('D', 'partInventory', string.format('save timing parts=%d reused_parts=%d serialize_ms=%.3f', serializedPartCount, reusedPartCount, serializationTimeMs))
    overhaul_career_saveSystem.asyncSaveExtensionFinished("partInventory", generation)
  end
  overhaul_career_saveSystem.deferSaveWork(step)
end

local function updatePartDescriptionsWithJBeamInfo()
  local jBeamPartInfos = {}
  local vehicleModels = {}

  for partId, part in pairs(partInventory) do
    vehicleModels[part.vehicleModel] = true
  end

  -- TODO if we need this data more often, we can put it in a local table in this file
  for vehicleModel, _ in pairs(vehicleModels) do
    local vehicleDir = string.format("/vehicles/%s/", vehicleModel)
    if FS:directoryExists(vehicleDir) then
      local vehicleFolders = {vehicleDir, "/vehicles/common/"}
      local ioCtx = jbeamIO.startLoading(vehicleFolders)
      jBeamPartInfos[vehicleModel] = jbeamIO.getAvailableParts(ioCtx)
    end
  end

  for partId, part in pairs(partInventory) do
    local partInfosVehicleModel = jBeamPartInfos[part.vehicleModel]
    if not partInfosVehicleModel then
      part.description = {}
      part.missingFile = true
    elseif partInfosVehicleModel[part.name] then
      part.description = partInfosVehicleModel[part.name]
    else
      part.description = {}
      part.missingFile = true
    end
  end
end

local function onExtensionLoaded()
  if not overhaul_career_career.isActive() then return false end
  serializedPartChunks = {}
  local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not saveSlot then return end

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local outdated = not saveInfo or saveInfo.version < minimumVersion

  local jsonData = savePath and jsonReadFile(savePath .. "/career/partInventory.json")
  if jsonData and not outdated then
    partInventory = deserialize(jsonData[1])

    if saveInfo.version < overhaul_career_saveSystem.getSaveSystemVersion() then
      -- Sell all parts that are not in a vehicle
      local partsToSell = {}
      for partId, part in pairs(partInventory) do
        if part.location == 0 then
          table.insert(partsToSell, partId)
        end
      end
      -- Save upgrades compensate at full value, independently of loaded difficulty.
      sellParts(partsToSell, false)
    end
  else
    partInventory = {}
  end
  updatePartDescriptionsWithJBeamInfo()
  removeHiddenPartsInStorage()
  updateVehicleMaps()
end

local function onOverhaulEnterVehicleFinished(currentVehicle)
  if not currentVehicle then return end

  -- Update the cached vehicle maps when entering a new vehicle
  updateVehicleParts = true
end

local function onOverhaulPartShoppingTransactionComplete()
  removeHiddenPartsInStorage()
  updateVehicleMaps()
end

local function onOverhaulVehicleAdded(inventoryId)
  addNewVehiclePartsInventoryId = inventoryId
end

local function onOverhaulVehicleRemoved(inventoryId)
  local partsToRemove = {}
  for partId, part in pairs(partInventory) do
    if part.location == inventoryId then
      partsToRemove[partId] = true
    end
  end

  for partId, _ in pairs(partsToRemove) do
    partInventory[partId] = nil
  end
end

local function getPart(inventoryId, path)
  for partId, part in pairs(partInventory) do
    if part.location == inventoryId and part.containingSlot == path then
      return part
    end
  end
end

local originComputerId
local originReturnRoute
local menuRequestId = 0
local function openMenu(_originComputerId, returnRoute)
  menuRequestId = menuRequestId + 1
  partInventoryOpen = true
  originReturnRoute = type(returnRoute) == "table" and returnRoute.name and returnRoute or nil
  currentVehicleInventoryIdForMenu = overhaul_career_garage_inventory.getCurrentVehicle()
  if not currentVehicleInventoryIdForMenu then
    currentVehicleInventoryIdForMenu = overhaul_career_garage_inventory.getInventoryIdsInClosestGarage(true)
  end

  originComputerId = _originComputerId

  extensions.ui_router.navigate("overhaul.computer.partInventory")
end

-- The stock route names this lifecycle callback. Keep it available so the
-- router can finish its acknowledgement, but let the painted view request data.
local function onRouteMount()
end

-- The view requests data after the finalized shell has painted its loader.
-- Keep condition refresh out of navigation, and ignore a late vehicle callback
-- if the player left or opened a different inventory visit in the meantime.
local function requestUIData()
  if not partInventoryOpen then return end
  local requestId = menuRequestId
  local function publish()
    if partInventoryOpen and requestId == menuRequestId then sendUIData() end
  end
  if currentVehicleInventoryIdForMenu then
    overhaul_career_garage_inventory.updatePartConditions(nil, currentVehicleInventoryIdForMenu, publish)
  else
    publish()
  end
end

local function closeMenuActual()
  if originReturnRoute then
    local route = originReturnRoute
    originReturnRoute = nil
    extensions.ui_router.navigate(route.name, route.params)
  elseif originComputerId then
    local computer = overhaul_world_facilities.getFacility("computer", originComputerId)
    overhaul_career_garage_computer.openMenu(computer)
  else
    overhaul_career_career.closeAllMenus()
  end
end

local function closeMenu()
  closeMenuActual()
  if overhaul_career_career.isAutosaveEnabled() then
    local dirtyVehicles = overhaul_career_garage_inventory.getDirtiedVehicles()
    if dirtyVehicles and next(dirtyVehicles) then
      saveStore.request("partInventory:closeMenu", nil, {force = true})
    end
  end
end

-- Router back handler entry point: route-managed BACK and the wrapper back button
-- share the existing closeMenu path so autosave behavior stays intact.
local function requestExit()
  closeMenu()
end

local function onOverhaulSaveFinished()
  if closeMenuAfterSaving then
    closeMenuActual()
    closeMenuAfterSaving = nil
  end
end

local function partInventoryClosed()
  menuRequestId = menuRequestId + 1
  partInventoryOpen = false
end

local function getSlotToPartIdMap()
  return slotToPartIdMap
end

local function getPartPathToPartIdMap()
  return partPathToPartIdMap
end

local function getInventory()
  return partInventory
end

local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["partInventory"] then return end

  local computerFunctionData = {
    id = "partInventory",
    routeTarget = "overhaul.computer.partInventory",
    label = _tr("ui.career.partInventory.myParts"),
    callback = function() openMenu(menuData.computerFacility.id) end,
    order = 5
  }
  if not menuData.hasBoughtStarterVehicle then
    computerFunctionData.disabled = true
    computerFunctionData.reason = overhaul_career_garage_computer.reasons.hasBoughtStarterVehicle
  end
  computerFunctions.general[computerFunctionData.id] = computerFunctionData
end

M.generateAndGetPartsFromVehicle = generateAndGetPartsFromVehicle
M.updatePartsToMatchSpawnedVehicle = updatePartsToMatchSpawnedVehicle
M.changedPartsCallback = changedPartsCallback
M.initConditionsCallback = initConditionsCallback
M.sendUIData = sendUIData
M.openMenu = openMenu
M.closeMenu = closeMenu
M.requestExit = requestExit
M.onRouteMount = onRouteMount
M.requestUIData = requestUIData
M.partInventoryClosed = partInventoryClosed
M.getSlotToPartIdMap = getSlotToPartIdMap
M.getPartPathToPartIdMap = getPartPathToPartIdMap
M.getInventory = getInventory
M.addPartToInventory = addPartToInventory
M.getPart = getPart
M.updatePartConditionsInInventory = updatePartConditionsInInventory
M.sellParts = sellParts
M.isHiddenInUI = isHiddenInUI

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate
M.onOverhaulVehicleSaveFinished = onOverhaulVehicleSaveFinished
M.onOverhaulSaveFinished = onOverhaulSaveFinished
M.onOverhaulEnterVehicleFinished = onOverhaulEnterVehicleFinished
M.onOverhaulVehicleAdded = onOverhaulVehicleAdded
M.onOverhaulVehicleRemoved = onOverhaulVehicleRemoved
M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions
M.onOverhaulPartShoppingTransactionComplete = onOverhaulPartShoppingTransactionComplete

return M
