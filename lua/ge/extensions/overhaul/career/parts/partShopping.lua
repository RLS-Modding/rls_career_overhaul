-- Part shopping: vehicle previews, cart drafts and checkout.
-- The stock fork restores the initial vehicle on cancellation and delegates drafts and catalog lookup.
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/partShopping.lua (BeamNG 0.40).

local capabilities = require("overhaul/lib/platform/capabilities")
local M = {}

local jbeamIO = require('jbeam/io')
local jbeamSlotSystem = require('jbeam/slotSystem')
local draftsLib = require('overhaul/career/parts/partShopping/drafts')
local catalogLib = require('overhaul/career/parts/partShopping/catalog')
local checkout = require('overhaul/lib/checkout/operations')
local saveStore = require('overhaul/lib/save/store')

-- SaveStore registers today's draft paths; legacy paths are only read, migrated and removed.
saveStore.registerKeys({
  {key = "parts.shoppingDrafts", owner = "overhaul_career_parts_partShopping", files = {"career/partShoppingCartDrafts.json", "career/rls_career/partShoppingCartDrafts.json"}, phase = "immediate", required = false},
})

local salesTaxRate = 0.07

local shoppingSessionActive = false
local shoppingSaveHold, shoppingInitializer
-- This module retains a detached GUI projection; only a publication changes the displayed contract.
local publishedShoppingDisplay
local shoppingDisplayOwnerUnloaded = false
local initialVehicle
local previewVehicle
local shoppingCart

local currentVehicleInventoryId
local slotToPartIdMap

local currentRouteCategory = ""
local currentRouteSlotPath = ""
local currentRoutePanel = "categories"

local tether -- tether object for aborting shopping when walking too far away

local RESTORE_SETTLE_TIME_SECONDS = 0.4
local MAX_ADDITIONAL_PART_PASSES = 32
local warnedDeclaredDefaultMismatches = {}
local warnedMissingInventoryParts = {}

local sendShoppingDataToUI
local installPart
local removePart
local republishPreviousShoppingSession

local function isShoppingUnavailable()
  return shoppingInitializer and (shoppingInitializer.unavailableData ~= nil or shoppingInitializer.pendingRecovery ~= nil)
end

-- The bodyless refresh prompts a UI read, so the catalog is copied once and encoded once.
local function publishShoppingData(data)
  -- Capture before the hook: a synchronous frontend read sees this publication, and
  -- a newer publication during hook reentry remains current when the older call returns.
  if not shoppingDisplayOwnerUnloaded then publishedShoppingDisplay = deepcopy(data) end
  guihooks.trigger("partShoppingData")
end

-- Returns a copy of the last publication, or nil before publication/after unload; never regenerates it.
local function readShoppingDisplay()
  if not publishedShoppingDisplay then return nil end
  return deepcopy(publishedShoppingDisplay)
end

-- The UI bridge immediately serializes the immutable snapshot; Lua callers use readShoppingDisplay's copy.
local function readShoppingDisplayForUI()
  return publishedShoppingDisplay
end

local function previousDisplayData(previous, reason)
  local retained = previous.initializer.publishedData
  local data = {}
  if retained and retained.shoppingCart == previous.cart and retained.partsInShop == previous.catalog.parts then
    for key, value in pairs(retained) do data[key] = value end
  end
  data.unavailableReason = reason
  return data
end

local function publishPendingShoppingRecovery(initializer)
  local attempt = initializer.pendingRecovery
  if not attempt then return false end
  republishPreviousShoppingSession(attempt)
  if shoppingInitializer ~= initializer then return true end
  if initializer.pendingRecovery ~= attempt then return true end
  local current = extensions.ui_router.getCurrent()
  if shoppingInitializer ~= initializer or initializer.pendingRecovery ~= attempt
      or current ~= attempt.recoveryWaitingEntry or initializer.routeRevision ~= attempt.recoveryRouteRevision
      or shoppingSaveHold ~= attempt.reusedHold or shoppingCart ~= attempt.previous.cart then return true end
  publishShoppingData(previousDisplayData(attempt.previous, "previous-context-pending"))
  return true
end

local function openUIState()
  return extensions.ui_router.navigate("overhaul.computer.partShopping")
end

local function flattenPartsTree(tree)
  local result = {}

  if tree.chosenPartName then
    result[tree.path] = tree.chosenPartName
  end

  if tree.children then
    for slotName, childNode in pairs(tree.children) do
      tableMerge(result, flattenPartsTree(childNode))
    end
  end

  return result
end

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

local function getCurrentVehicleVehId()
  if not currentVehicleInventoryId then return end
  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(currentVehicleInventoryId)
  return vehId
end

local function getCurrentVehicleObj()
  if not currentVehicleInventoryId then return end
  return getObjectByID(getCurrentVehicleVehId())
end

-- Set when leaving shopping via a respawn, so the spawn hook can still heal
-- after the session flag is cleared.
local healSpawnedVehicle = false
local visibilityHealToken = 0

local function forceCurrentVehicleVisible()
  local vehId = getCurrentVehicleVehId()
  local vehicleObject = vehId and getObjectByID(vehId) or nil
  if not vehicleObject or not core_vehicle_partmgmt then return false end
  local vehicleData = core_vehicle_manager.getVehicleData(vehId)
  if not vehicleData or not vehicleData.config then return false end
  pcall(core_vehicle_partmgmt.resetVehicleHighlights, false, vehId)
  pcall(core_vehicle_partmgmt.setNewParts, vehId)
  pcall(core_vehicle_partmgmt.showHighlightedParts, vehId)
  pcall(function() vehicleObject:setMeshAlpha(1, "", false) end)
  if overhaul_vehicles_passengerOccupants then overhaul_vehicles_passengerOccupants.onVehicleVisible(vehId) end
  return true
end

local function healCurrentVehicleVisible()
  visibilityHealToken = visibilityHealToken + 1
  local token = visibilityHealToken
  if forceCurrentVehicleVisible() then return end
  core_jobsystem.create(function(job)
    local startClock = os.clock()
    while os.clock() - startClock < 2.5 do
      job.sleep(0.1)
      if token ~= visibilityHealToken then return end
      if forceCurrentVehicleVisible() then return end
    end
  end, 1)
end

local catalog = catalogLib.create({
  getShoppingCart = function() return shoppingCart end,
  getInitialVehicle = function() return initialVehicle end,
  getCurrentVehicleVehId = getCurrentVehicleVehId,
  getCurrentVehicleObj = getCurrentVehicleObj,
})

local drafts = draftsLib.create({
  getShoppingCart = function() return shoppingCart end,
  getCurrentVehicle = function() return currentVehicleInventoryId end,
  getPartsInShop = function() return catalog.getPartsInShop() end,
  isSessionActive = function() return shoppingSessionActive end,
  canRestoreParts = function() return not isShoppingUnavailable() end,
  installPart = function(part) return installPart(part) end,
  removePart = function(part) return removePart(part) end,
  sendShoppingDataToUI = function() return sendShoppingDataToUI() end,
})

local function updateShoppingCart()
  shoppingCart.total = 0
  shoppingCart.partsInList = {}
  shoppingCart.partsOutList = {}
  shoppingCart.partsOut = {}
  shoppingCart.slotList = {}

  for path, part in pairs(shoppingCart.partsIn) do
    shoppingCart.partsOut[path] = overhaul_career_parts_partInventory.getInventory()[slotToPartIdMap[currentVehicleInventoryId][path]]
  end
  for path, partName in pairs(initialVehicle.partList) do
    if partName ~= "" and (not previewVehicle.partList[path] or previewVehicle.partList[path] == "") then
      shoppingCart.partsOut[path] = overhaul_career_parts_partInventory.getInventory()[slotToPartIdMap[currentVehicleInventoryId][path]]
    end
  end

  -- Convert the partsIn/partsOut tables to lists
  local slotsAdded = {}
  local counter = 1
  for slot, part in pairs(shoppingCart.partsIn) do
    local partOut = shoppingCart.partsOut[part.containingSlot]
    if not overhaul_career_parts_partInventory.isHiddenInUI(part) or
        (partOut and not overhaul_career_parts_partInventory.isHiddenInUI(partOut)) then
      shoppingCart.slotList[counter] = slot
      shoppingCart.partsInList[counter] = part
      shoppingCart.partsOutList[counter] = partOut
      counter = counter + 1
    end
    slotsAdded[part.containingSlot] = true
  end

  for slot, part in pairs(shoppingCart.partsOut) do
    if not slotsAdded[part.containingSlot] and not overhaul_career_parts_partInventory.isHiddenInUI(part) then
      shoppingCart.slotList[counter] = slot
      shoppingCart.partsOutList[counter] = part
      slotsAdded[part.containingSlot] = true
      counter = counter + 1
    end
  end

  -- Calculate the total price of the whole shopping cart
  local total = 0
  for slot, part in pairs(shoppingCart.partsIn) do
    total = total + part.finalValue
  end

  shoppingCart.taxes = total * salesTaxRate
  shoppingCart.total = total + shoppingCart.taxes
end

-- TODO we send all data every time a part changes. we should send only smaller updates
sendShoppingDataToUI = function()
  local initializer = shoppingInitializer
  if initializer and initializer.pendingRecovery and publishPendingShoppingRecovery(initializer) then
    return
  end
  if initializer and initializer.unavailableData then
    publishShoppingData(initializer.unavailableData)
    return
  end
  if not shoppingSessionActive or not currentVehicleInventoryId or not shoppingCart or not initialVehicle then
    publishShoppingData({unavailableReason = "shopping-display-unavailable"})
    return
  end
  if initializer and initializer.origin then
    local computer = overhaul_world_facilities.getFacility("computer", initializer.origin)
    if shoppingInitializer ~= initializer then return end
    if not computer then
      local unavailable = {unavailableReason = "previous-context-unavailable"}
      initializer.unavailableData = unavailable
      publishShoppingData(unavailable)
      return
    end
  end
  local partTree = catalog.generatePartShop()
  if not partTree then return end
  local shoppingData = {}
  shoppingData.partsInShop = catalog.getPartsInShop()
  shoppingData.partTree = partTree
  shoppingData.shoppingCart = shoppingCart
  shoppingData.slotsNiceName = catalog.getSlotsNiceName()
  shoppingData.searchSlotList = catalog.buildSearchSlotList(partTree)
  shoppingData.vehicleSlotToPartMap = {}
  for partId, part in pairs(overhaul_career_parts_partInventory.getInventory()) do
    if part.location == currentVehicleInventoryId then
      shoppingData.vehicleSlotToPartMap[part.containingSlot] = part
    end
  end

  -- Route-selected fields so Vue renders the active route view directly instead
  -- of recomputing category/slot from route params.
  shoppingData.category = currentRouteCategory
  shoppingData.slot = currentRouteSlotPath
  shoppingData.activePanel = currentRoutePanel
  shoppingData.filteredParts = catalog.buildFilteredParts(currentRouteCategory, currentRouteSlotPath)
  -- filteredSlots is search-driven and stays UI-local; emit empty so the route
  -- payload shape is complete. ponytail: search filtering remains in Vue.
  shoppingData.filteredSlots = {}

  shoppingData.playerMoney = overhaul_career_economy_playerAttributes.getAttributeValue("money")
  shoppingData.saveForLater = drafts.getSaveForLater()
  shoppingData.restoreInProgress = drafts.isRestoreInProgress()
  if drafts.isRestoreInProgress() then
    local restoreCurrent, restoreTotal = drafts.getRestoreProgress()
    shoppingData.restoreProgress = {
      current = restoreCurrent,
      total = restoreTotal,
    }
  end
  publishShoppingData(shoppingData)
  if initializer and shoppingInitializer == initializer and shoppingCart == shoppingData.shoppingCart then
    initializer.publishedData = shoppingData
  end
end

-- Router lifecycle: store the normalized selection on enter so any emission
-- between enter and mount uses the correct route state.
local function onRouteEnter(context, toRoute, fromRoute, data)
  local initializer = shoppingInitializer
  if initializer then initializer.pendingRecovery = nil end
  if initializer and initializer.openedUI then
    -- Stock passes the distinct entry.resolved object to enter and mount. Only the first
    -- parameterless root entry during our navigate belongs to this opening attempt.
    if initializer.openingUI and not initializer.openingRoute and toRoute
        and toRoute.name == "overhaul.computer.partShopping" and not (toRoute.params and next(toRoute.params)) then
      initializer.openingRoute = toRoute
    else
      initializer.routeRevision = (initializer.routeRevision or 0) + 1
    end
  end
  currentRouteCategory, currentRouteSlotPath, currentRoutePanel = catalog.normalizeRouteSelection(toRoute)
end

-- Router lifecycle: re-normalize and emit the route-aware shopping data once the
-- destination view has mounted.
local function onRouteMount(context, toRoute, fromRoute, data)
  if not shoppingSessionActive then
    publishShoppingData({unavailableReason = "shopping-display-unavailable"})
    return
  end
  local pending = shoppingInitializer and shoppingInitializer.pendingRecovery
  if pending and toRoute == pending.openingRoute then
    republishPreviousShoppingSession(pending)
    return
  end
  currentRouteCategory, currentRouteSlotPath, currentRoutePanel = catalog.normalizeRouteSelection(toRoute)
  sendShoppingDataToUI()
end

-- A preview report that lands while a replacement begin is still open belongs to the session it replaces.
local function restoreOwner()
  local current = shoppingInitializer
  if current and not current.completed and current.previous then return current.previous.initializer end
  return current
end

local function isReplacementBeginning(owner)
  local current = shoppingInitializer
  return current ~= owner and current ~= nil and not current.completed
    and current.previous ~= nil and current.previous.initializer == owner
end

-- The next restore step waits out a replacement begin or a pending recovery that spans the settle delay,
-- so the restore resumes when the owner is current again. An unavailable owner ends the restore. A
-- replaced owner leaves the restore state to the session that replaced it.
local function scheduleNextRestorePart()
  local owner = restoreOwner()
  core_jobsystem.create(function(job)
    job.sleep(RESTORE_SETTLE_TIME_SECONDS)
    while isReplacementBeginning(owner) or (shoppingInitializer == owner and owner.pendingRecovery) do
      job.sleep(RESTORE_SETTLE_TIME_SECONDS)
    end
    if shoppingInitializer ~= owner then return end
    if isShoppingUnavailable() then drafts.abortCartRestore(); return end
    drafts.processNextRestorePart()
  end)
end

local function updatePreviewVehicle(currentPartConditions)
  if isShoppingUnavailable() then
    -- Nothing can resume this restore once the display is unavailable.
    drafts.abortCartRestore()
    return false
  end
  if not shoppingSessionActive then
    return false
  end
  -- get the data
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  if not currentVehicleData then
    log('E', 'inventory', 'unable to get vehicle data')
    -- Without the vehicle's parts no further restore step can be scheduled, so end the restore.
    drafts.abortCartRestore()
    return false
  end
  if not currentVehicleInventoryId then return end

  previewVehicle.config.partsTree = deepcopy(currentVehicleData.config.partsTree)
  previewVehicle.partList = flattenPartsTree(previewVehicle.config.partsTree)
  if currentPartConditions then
    previewVehicle.partConditions = currentPartConditions
  end
  updateShoppingCart()
  sendShoppingDataToUI()
  core_vehicleBridge.executeAction(getObjectByID(overhaul_career_garage_inventory.getVehicleIdFromInventoryId(previewVehicle.id)),'setFreeze', true)

  if drafts.isRestoreInProgress() then
    drafts.incrementRestoreCurrent()
    scheduleNextRestorePart()
  elseif drafts.getSaveForLater() and shoppingSessionActive then
    drafts.persistCartDraftToFile()
  end
end

local originComputerId
local returnRoute
local function navigateReturnRoute(route, stillOwnsRoute)
  if not route or not (extensions.ui_router and extensions.ui_router.navigate) then
    return false
  end
  if type(route) == "table" then
    local routeName = route.name or route.route
    local params = route.params
    if not routeName and route.businessType then
      routeName = "business-computer"
      params = {businessType = route.businessType, businessId = route.businessId}
    end
    if routeName then
      if params and params.businessType then
        capabilities.get("businessComputer").setBusinessContext(params.businessType, params.businessId)
      end
      if stillOwnsRoute and not stillOwnsRoute() then return false end
      return true, extensions.ui_router.navigate(routeName, params)
    end
  end
  if stillOwnsRoute and not stillOwnsRoute() then return false end
  return true, extensions.ui_router.navigate(route)
end

-- A completed session owns its reused hold; a refused replacement must keep that session intact.
local function capturePreviousShoppingSession()
  if not shoppingSessionActive or not shoppingSaveHold or not shoppingInitializer or not shoppingInitializer.completed then return end
  return {initializer = shoppingInitializer, cart = shoppingCart, initial = initialVehicle, preview = previewVehicle,
    slotMap = slotToPartIdMap, vehicleId = currentVehicleInventoryId, origin = originComputerId, route = returnRoute,
    category = currentRouteCategory, slot = currentRouteSlotPath, panel = currentRoutePanel, tether = tether,
    catalog = catalog.captureInitializerState()}
end

local function isFailedInitializerRouteCurrent(attempt)
  if shoppingInitializer ~= attempt or not attempt.openingEntry then return false end
  local route = extensions.ui_router.getCurrent()
  if shoppingInitializer ~= attempt or route ~= attempt.openingEntry then return false end
  local name = route and route.request and route.request.name
  return name == "overhaul.computer.partShopping" or name == "overhaul.computer.partShopping.category"
    or name == "overhaul.computer.partShopping.category.slot"
end

-- Accepted pending navigation owns its destination; only a refused or unanswered request may fall back to play.
local function leftShoppingView(attempt, reply)
  if type(reply) == "table" then return reply.success == true end
  return not isFailedInitializerRouteCurrent(attempt)
end

local function closeFailedInitializerUI(attempt)
  if not attempt.openedUI or not isFailedInitializerRouteCurrent(attempt) then return end
  local navigationState = require('ge/extensions/ui/router/navigationState')
  local current, pending = navigationState.getCurrentEntry(), navigationState.getPendingEntry()
  -- Only the opening entry belongs to this attempt; an already queued request owns its destination.
  if current ~= attempt.openingEntry or pending and pending ~= attempt.openingEntry then return end
  local stillOwnsRoute = function()
    local now, queued = navigationState.getCurrentEntry(), navigationState.getPendingEntry()
    return shoppingInitializer == attempt and now == current and queued == pending
      and isFailedInitializerRouteCurrent(attempt)
  end
  if not stillOwnsRoute() then return end
  if attempt.origin then
    local computer = overhaul_world_facilities.getFacility("computer", attempt.origin)
    if not stillOwnsRoute() then return end
    if computer then
      -- openMenu returns false when it refused to open; otherwise nothing, then the router's reply.
      local opened, reply = overhaul_career_garage_computer.openMenu(computer, nil, nil, stillOwnsRoute)
      if opened ~= false and leftShoppingView(attempt, reply) then return end
    end
  elseif attempt.route then
    local navigated, reply = navigateReturnRoute(attempt.route, stillOwnsRoute)
    if navigated and leftShoppingView(attempt, reply) then return end
  end
  if stillOwnsRoute() then extensions.ui_router.navigate("play") end
end

local function restorePreviousShoppingSession(previous)
  shoppingInitializer, shoppingSessionActive = previous.initializer, true
  shoppingCart, initialVehicle, previewVehicle = previous.cart, previous.initial, previous.preview
  slotToPartIdMap, currentVehicleInventoryId = previous.slotMap, previous.vehicleId
  originComputerId, returnRoute = previous.origin, previous.route
  currentRouteCategory, currentRouteSlotPath, currentRoutePanel = previous.category, previous.slot, previous.panel
  tether = previous.tether
  catalog.restoreInitializerState(previous.catalog)
end

-- Keep the prior backend/hold on the same owned view. Recovery must not prepare another
-- computer, run its providers, navigate over a newer entry, or trigger ordinary Vue teardown.
local function publishUnavailablePreviousShoppingUI(previous, stillOwnsRoute)
  if not stillOwnsRoute() then return end
  local data = previousDisplayData(previous, "previous-context-unavailable")
  previous.initializer.pendingRecovery = nil
  previous.initializer.unavailableData = data
  publishShoppingData(data)
end

-- Replay the public producer's matching catalog, not a regeneration with fresh item IDs/quotes.
republishPreviousShoppingSession = function(attempt)
  if not attempt.openedUI or attempt.routeRevision or not attempt.openingRoute then return end
  local previous = attempt.previous
  local routeRevision = previous.initializer.routeRevision
  local function stillOwnsSession()
    return shoppingInitializer == previous.initializer and shoppingSaveHold == attempt.reusedHold
      and shoppingSessionActive and shoppingCart == previous.cart and currentVehicleInventoryId == previous.vehicleId
      and previous.initializer.routeRevision == routeRevision
  end
  if not stillOwnsSession() then return end
  local route = extensions.ui_router.getCurrent()
  if not stillOwnsSession() then return end
  local request = route and route.request
  if route ~= attempt.openingEntry and request and request.name:find("overhaul.computer.partShopping", 1, true) == 1 then
    previous.initializer.pendingRecovery = attempt
    attempt.recoveryWaitingEntry, attempt.recoveryRouteRevision = route, routeRevision
  end
  -- A distinct entry, including the same root/params, owns its own display.
  if not request or route ~= attempt.openingEntry or route.resolved ~= attempt.openingRoute
      or request.name ~= "overhaul.computer.partShopping"
      or request.params and next(request.params) then return end
  local function stillOwnsRoute()
    if not stillOwnsSession() then return false end
    local currentRoute = extensions.ui_router.getCurrent()
    return stillOwnsSession() and currentRoute == route and currentRoute.request == request
      and currentRoute.resolved == attempt.openingRoute and request.name == "overhaul.computer.partShopping"
      and not (request.params and next(request.params))
  end
  local function unavailable()
    publishUnavailablePreviousShoppingUI(previous, stillOwnsRoute)
  end
  local data = previous.initializer.publishedData
  if previous.initializer.unavailableData then unavailable(); return end
  if not data or data.shoppingCart ~= previous.cart or data.partsInShop ~= previous.catalog.parts then
    unavailable(); return
  end
  local vehicles = overhaul_career_garage_inventory.getVehicles()
  if not stillOwnsSession() then return end
  if not vehicles or not vehicles[previous.vehicleId] then unavailable(); return end
  local vehicleId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(previous.vehicleId)
  if not stillOwnsSession() then return end
  if not vehicleId then unavailable(); return end
  local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehicleId)
  if not stillOwnsSession() then return end
  if not vehicleData or not vehicleData.ioCtx or not vehicleData.config or not vehicleData.config.partsTree then
    unavailable(); return
  end
  local vehicle = getObjectByID(vehicleId)
  if not stillOwnsSession() then return end
  if not vehicle then unavailable(); return end
  if not stillOwnsRoute() then return end
  if previous.origin then
    local computer = overhaul_world_facilities.getFacility("computer", previous.origin)
    if not stillOwnsRoute() then return end
    if not computer then unavailable(); return end
  end
  previous.initializer.pendingRecovery = nil
  publishShoppingData(data)
end

-- Cancellation restores/spawns the old vehicle; a refused begin must only discard its own state.
local function abortShoppingInitializer(attempt)
  if shoppingInitializer ~= attempt then return end
  if attempt.tether and tether == attempt.tether then
    tether.remove = true
    tether = nil
  end
  if attempt.previous and shoppingSaveHold == attempt.reusedHold then
    restorePreviousShoppingSession(attempt.previous)
    republishPreviousShoppingSession(attempt)
    return
  end
  shoppingSessionActive = false
  shoppingCart, initialVehicle, previewVehicle, slotToPartIdMap = nil, nil, nil, nil
  currentVehicleInventoryId, originComputerId, returnRoute = nil, nil, nil
  currentRouteCategory, currentRouteSlotPath, currentRoutePanel = "", "", "categories"
  catalog.clearFailedStart()
  -- An unfinished begin has no usable prior session to keep alive with a reused module-owned hold.
  local ownedHold = attempt.acquiredHold or attempt.reusedHold
  if ownedHold and shoppingSaveHold == ownedHold then
    shoppingSaveHold = nil
    ownedHold.release()
  end
  closeFailedInitializerUI(attempt)
  if shoppingInitializer == attempt then shoppingInitializer = nil end
end

local function fillInitialPartNames(attempt)
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  if shoppingInitializer ~= attempt then return false end
  local ioCtx = currentVehicleData and currentVehicleData.ioCtx
  if not ioCtx then
    abortShoppingInitializer(attempt)
    return false
  end
  local availableParts = jbeamIO.getAvailableParts(ioCtx)
  if shoppingInitializer ~= attempt then return false end
  for _, partName in pairs(initialVehicle.partList) do
    if partName and partName ~= "" then
      local partInfo = availableParts[partName]
      if partInfo then
        catalog.getPartsNiceName()[partName] = core_vehicle_partmgmt.getTranslation(partInfo.description, "ui.vehicleconfig.information.name.")
        if shoppingInitializer ~= attempt then return false end
      end
    end
  end
  return true
end

local function prepareShoppingInitializer(attempt)
  local vehicles = overhaul_career_garage_inventory.getVehicles()
  if shoppingInitializer ~= attempt then return false end
  if not vehicles or not vehicles[currentVehicleInventoryId] then
    abortShoppingInitializer(attempt)
    return false
  end
  shoppingCart = {partsIn = {}, partsOut = {}, total = 0, partsInList = {}, partsOutList = {}, slotList = {}}
  catalog.resetPartsNiceName()
  shoppingSessionActive = true
  if not shoppingSaveHold then
    local hold = saveStore.hold(M, "shopping session", {stage = 'beforeRoute'})
    if shoppingInitializer ~= attempt then
      if shoppingSaveHold ~= hold then hold.release() end
      return false
    end
    shoppingSaveHold, attempt.acquiredHold = hold, hold
  end
  local slotMap = deepcopy(overhaul_career_parts_partInventory.getSlotToPartIdMap())
  if shoppingInitializer ~= attempt then return false end
  if not slotMap then abortShoppingInitializer(attempt); return false end
  slotToPartIdMap = slotMap
  -- Older car-meet purchases could be saved without a partInventory entry.
  -- Keep those vehicles modifiable instead of indexing a nil slot map.
  slotToPartIdMap[currentVehicleInventoryId] = slotToPartIdMap[currentVehicleInventoryId] or {}

  local vehicle = deepcopy(vehicles[currentVehicleInventoryId])
  if shoppingInitializer ~= attempt then return false end
  local config = vehicle and vehicle.config
  local partsTree = config and config.partsTree
  if not partsTree then
    abortShoppingInitializer(attempt)
    return false
  end
  initialVehicle = vehicle
  initialVehicle.partList = flattenPartsTree(partsTree)

  -- Fill partsNiceName with initial vehicle parts
  if not fillInitialPartNames(attempt) then return false end

  local preview = deepcopy(initialVehicle)
  if shoppingInitializer ~= attempt then return false end
  if not preview then abortShoppingInitializer(attempt); return false end
  previewVehicle = preview
  return true
end

local function startShoppingActual(_originComputerId, _returnRoute, attempt)
  if shoppingInitializer ~= attempt or currentVehicleInventoryId ~= attempt.vehicleId then return end
  if shoppingInitializer ~= attempt or not prepareShoppingInitializer(attempt) then return end
  catalog.resetPartShopId()
  local partTree = catalog.generatePartShop()
  if shoppingInitializer ~= attempt then return end
  if not partTree then abortShoppingInitializer(attempt); return end
  originComputerId = _originComputerId
  returnRoute = _returnRoute
  attempt.origin, attempt.route = _originComputerId, _returnRoute

  if originComputerId then
    M.setupTether()
    if shoppingInitializer ~= attempt then return end
    if attempt.missingTetherVehicle then abortShoppingInitializer(attempt); return end
  end

  attempt.openedUI = true
  attempt.openingUI = true
  local opened = openUIState()
  if shoppingInitializer ~= attempt then return end
  attempt.openingUI = false
  -- Stock returns this navigate's entry even when a later nested request becomes current.
  -- A preempted navigate has no entry; its nested enter cannot acquire this attempt's UI.
  local openingEntry = type(opened) == "table" and opened.success and opened.data or nil
  if openingEntry and openingEntry.resolved == attempt.openingRoute then
    attempt.openingEntry = openingEntry
  else
    attempt.openingRoute = nil
  end

  local walking = gameplay_walk.isWalking()
  if shoppingInitializer ~= attempt then return end
  if walking then
    local vehicle = getCurrentVehicleObj()
    if shoppingInitializer ~= attempt then return end
    if not vehicle then abortShoppingInitializer(attempt); return end
    local vehiclePosition = vehicle:getPosition()
    if shoppingInitializer ~= attempt then return end
    local playerVehicle = getPlayerVehicle(0)
    if shoppingInitializer ~= attempt then return end
    if not playerVehicle then abortShoppingInitializer(attempt); return end
    gameplay_walk.setRot(vehiclePosition - playerVehicle:getPosition())
    if shoppingInitializer ~= attempt then return end
  end

  local vehicle = getObjectByID(overhaul_career_garage_inventory.getVehicleIdFromInventoryId(previewVehicle.id))
  if shoppingInitializer ~= attempt then return end
  if not vehicle then abortShoppingInitializer(attempt); return end
  core_vehicleBridge.executeAction(vehicle,'setFreeze', true)
  if shoppingInitializer ~= attempt then return end
  extensions.hook("onOverhaulPartShoppingStarted")
  if shoppingInitializer ~= attempt then return end
  drafts.maybeStartCartRestore()
  if shoppingInitializer == attempt then attempt.completed = true end
end

local function setupTether()
    -- calculate the size of the vehicle to use for tethering
  local attempt = shoppingInitializer
  local vehicle = getCurrentVehicleObj()
  if shoppingInitializer ~= attempt then return end
  if not vehicle then
    if attempt then attempt.missingTetherVehicle = true end
    return
  end
  local oobb = vehicle:getSpawnWorldOOBB()
  if shoppingInitializer ~= attempt then return end
  local vehCenter = oobb:getCenter()
  local vehRadius = (oobb:getPoint(0) - oobb:getPoint(6)):length()
  -- calculate computer position
  local computerPos = overhaul_world_facilities.getAverageDoorPositionForFacility(overhaul_world_facilities.getFacility("computer",originComputerId))
  if shoppingInitializer ~= attempt then return end
  if not computerPos then return end

  local distBetweenVehicleAndComputer = (computerPos-vehCenter):length()
  -- this smoothly scales the radius from 100% for 4m or less distance to 150% for 12m or more radius
  local radiusMultipler = ((clamp(distBetweenVehicleAndComputer,4,12)-4)/16 + 1)
  -- These camera radii keep the workshop vehicle in view.
  local newTether = overhaul_career_maintenance_tether.startCapsuleTetherBetweenStatics(computerPos, 10*radiusMultipler, vehCenter, vehRadius + (9*radiusMultipler), M.cancelShopping)
  if shoppingInitializer ~= attempt then
    if newTether and newTether ~= tether then newTether.remove = true end
    return
  end
  tether = newTether
  if attempt then attempt.tether = newTether end
end

local function startShopping(inventoryId, _originComputerId, _returnRoute)
  local attempt = {previous = capturePreviousShoppingSession(), reusedHold = shoppingSaveHold}
  shoppingInitializer = attempt
  local selectedId = inventoryId or overhaul_career_garage_inventory.getCurrentVehicle()
  if shoppingInitializer ~= attempt then return end
  currentVehicleInventoryId = selectedId
  if not selectedId then
    selectedId = overhaul_career_garage_inventory.getInventoryIdsInClosestGarage(true)
    if shoppingInitializer ~= attempt then return end
    currentVehicleInventoryId = selectedId
  end
  if not currentVehicleInventoryId then abortShoppingInitializer(attempt); return end
  attempt.vehicleId = currentVehicleInventoryId

  local vehicles = overhaul_career_garage_inventory.getVehicles()
  if shoppingInitializer ~= attempt then return end
  local vehicle = vehicles and vehicles[currentVehicleInventoryId]
  if not vehicle then abortShoppingInitializer(attempt); return end
  local brokenParts = overhaul_career_market_valueCalculator.getNumberOfBrokenParts(vehicle.partConditions)
  if brokenParts > 0 then
    ui_message('Repair the vehicle before changing parts.', 5, 'Parts shop', 'warning')
    abortShoppingInitializer(attempt)
    return
  end
  overhaul_career_repair_damageManager.saveDamageState(currentVehicleInventoryId)
  if shoppingInitializer ~= attempt then return end
  startShoppingActual(_originComputerId, _returnRoute, attempt)
end

local function getDefaultPartName(jbeamData, slotName)
  if not jbeamData or not jbeamData.slots2 then return end
  for _, slot in ipairs(jbeamData.slots2) do
    if slot.name == slotName and slot.default and slot.default ~= "" then return slot.default end
  end
end

-- Some older vehicle mods have a default part whose slotType does not exactly
-- match the slot that declares it. Free roam still installs that explicit
-- default by name, while career's stricter fit check used to reject and add it
-- forever. Treat a parent's named default as authoritative, but warn once so
-- the broken JBeam remains visible to mod authors.
local function partFitsSlotOrIsDeclaredDefault(parentJbeamData, slotName, partData, partName, slotInfo)
  if not partData or not slotInfo then return false end
  if jbeamSlotSystem.partFitsSlot(partData, slotInfo) then return true end

  local defaultPartName = getDefaultPartName(parentJbeamData, slotName)
  if defaultPartName and partName == defaultPartName then
    local warningKey = tostring(parentJbeamData.partName) .. "|" .. tostring(slotName) .. "|" .. tostring(partName)
    if not warnedDeclaredDefaultMismatches[warningKey] then
      warnedDeclaredDefaultMismatches[warningKey] = true
      log("W", "partShopping",
        string.format(
          "Accepting declared default '%s' for slot '%s' despite a slotType mismatch (parent '%s')",
          tostring(partName), tostring(slotName), tostring(parentJbeamData.partName)
        )
      )
    end
    return true
  end

  return false
end

local function getFittingPartFromInventory(parentPart, slotName, currentVehicleData)
  for partId, inventoryPart in pairs(overhaul_career_parts_partInventory.getInventory()) do
    -- The cart lookup is a read-only scan of the cart; it runs last so installed parts and other
    -- models' spares (most of a large inventory) skip it.
    if not inventoryPart.enginePackageId and inventoryPart.location == 0 and inventoryPart.vehicleModel == parentPart.vehicleModel
        and not catalog.getPartSlotFromPartIdInShoppingCart(partId) then
      local partDescription = jbeamIO.getPart(currentVehicleData.ioCtx, inventoryPart.name)
      if not partDescription then
        -- Mod updates can leave stored parts whose JBeam definition no longer exists.
        -- Keep the inventory entry, but do not pass nil to the slot compatibility check.
        local warningKey = tostring(inventoryPart.vehicleModel) .. "|" .. tostring(inventoryPart.name)
        if not warnedMissingInventoryParts[warningKey] then
          warnedMissingInventoryParts[warningKey] = true
          log("W", "partShopping", string.format(
            "Skipping unavailable inventory part '%s' (model '%s', inventory ID '%s') while filling slot '%s'",
            tostring(inventoryPart.name), tostring(inventoryPart.vehicleModel), tostring(partId), tostring(slotName)))
        end
      elseif jbeamSlotSystem.partFitsSlot(partDescription, parentPart.description.slotInfoUi[slotName]) then
        local shopPart = deepcopy(inventoryPart)
        shopPart.containingSlot = parentPart.containingSlot .. slotName .. "/"
        shopPart.partPath = shopPart.containingSlot .. inventoryPart.name
        shopPart.slot = slotName
        shopPart.vehicleModel = parentPart.vehicleModel
        shopPart.partId = partId
        shopPart.partShopId = catalog.takePartShopId()
        shopPart.finalValue = 0
        return shopPart
      end
    end
  end
end

-- New parts bring default subparts unless a compatible installed part can be reused.
local function getNeededAdditionalParts(parts, inventoryId)
  local vehId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  local vehicleObj = getObjectByID(vehId)
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  local availableParts = jbeamIO.getAvailableParts(currentVehicleData.ioCtx)

  -- Make a map from slot to its part for the parts which were already in the vehicle and the parts which we want to add
  local combinedSlotToPartMap = {}
  for containingSlot, partId in pairs(slotToPartIdMap[inventoryId]) do
    combinedSlotToPartMap[containingSlot] = deepcopy(overhaul_career_parts_partInventory.getInventory()[partId])
  end
  for _, part in pairs(parts) do
    combinedSlotToPartMap[part.containingSlot] = deepcopy(part)
  end

  for path, part in pairs(combinedSlotToPartMap) do
    if not part.slotType then
      local jbeamData = jbeamIO.getPart(currentVehicleData.ioCtx, part.name)
      if jbeamData then
        part.slotType = jbeamData.slotType
      end
    end
  end

  -- add the default part if the slot is empty and they have a default part
  local addedParts = false
  local resultParts = deepcopy(parts)
  for _, part in pairs(parts) do
    if part.description.slotInfoUi then
      local parentJbeamData = jbeamIO.getPart(currentVehicleData.ioCtx, part.name)
      for slotName, slotInfo in pairs(part.description.slotInfoUi) do
        local path = part.containingSlot .. slotName .. "/"
        local installedPart = combinedSlotToPartMap[path]
        if not installedPart or not partFitsSlotOrIsDeclaredDefault(parentJbeamData, slotName, installedPart, installedPart.name, slotInfo) then -- found an empty slot
          -- look for a fitting part from the inventory
          local fittingPart = getFittingPartFromInventory(part, slotName, currentVehicleData)

          if not fittingPart then
            local partNameToGenerate = getDefaultPartName(parentJbeamData, slotName)
            if partNameToGenerate then -- found a default part name
              fittingPart = catalog.generatePart(partNameToGenerate, currentVehicleData, availableParts, path, slotName, vehicleObj)
              if fittingPart then
                local generatedJbeam = jbeamIO.getPart(currentVehicleData.ioCtx, fittingPart.name)
                -- this check should normally not be necessary, but it's possible that the jbeam has a non-fitting part as the default part and then this would lead to an infinite loop
                if generatedJbeam and not jbeamSlotSystem.partFitsSlot(generatedJbeam, slotInfo) then
                  fittingPart.slotType = slotInfo.allowTypes[1]
                end
              end
            end
          end

          if fittingPart then
            resultParts[fittingPart.containingSlot] = fittingPart
            addedParts = true
            if not slotInfo.coreSlot then
              fittingPart.sourcePart = true
            end
          end
        end
      end
    end
  end
  return resultParts, addedParts
end

-- TODO refactor for new parts system
local function findIncompatiblePartsInShoppingCartRec(partName, availableParts, node, vehicleParts, ioCtx)
  if not node or not node.children then return end

  local parentJbeamData = jbeamIO.getPart(ioCtx, partName)

  -- Traverse through the vehicle parts tree
  for slotName, childNode in pairs(node.children) do
    local subPartName = childNode.chosenPartName

    if vehicleParts[childNode.path] then
      local description = availableParts[partName]
      local slotInfo = description and description.slotInfoUi and description.slotInfoUi[slotName]
      if not slotInfo and parentJbeamData and parentJbeamData.slotInfoUi then
        slotInfo = parentJbeamData.slotInfoUi[slotName]
      end
      local subPart = jbeamIO.getPart(ioCtx, subPartName)

      if (shoppingCart.partsIn[childNode.path] and shoppingCart.partsIn[childNode.path].emptyPlaceholder) then
        -- This is an intentionally empty slot, so all child parts are incompatible
        vehicleParts[childNode.path] = nil
      elseif subPartName and subPartName ~= "" and
             partFitsSlotOrIsDeclaredDefault(parentJbeamData, slotName, subPart, subPartName, slotInfo) then
        vehicleParts[childNode.path] = nil
        findIncompatiblePartsInShoppingCartRec(subPartName, availableParts, childNode, vehicleParts, ioCtx)
      end
    end
  end
end

-- TODO this returns "main"
local function findIncompatiblePartsInShoppingCart()
  local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())
  local availableParts = jbeamIO.getAvailableParts(currentVehicleData.ioCtx)

  local mainPartName = jbeamIO.getMainPartName(currentVehicleData.ioCtx)
  local vehiclePartsTree = deepcopy(previewVehicle.config.partsTree)
  local vehicleParts = flattenPartsTree(vehiclePartsTree)

  for path, part in pairs(vehicleParts) do
    -- Remove the root part
    if (path == "/") then
      vehicleParts[path] = nil
    end
  end

  -- Remove all parts of the "vehicleParts" list that are in the vehicle correctly. Then only the incorrect ones will remain
  findIncompatiblePartsInShoppingCartRec(mainPartName, availableParts, vehiclePartsTree, vehicleParts, currentVehicleData.ioCtx)
  return vehicleParts
end

-- fill the preview vehicle with the initial parts
local function fillWithInitialParts(containingSlot)
  local node = getNodeFromSlotPath(previewVehicle.config.partsTree, containingSlot)
  if not node then return end
  local initialVehicleNode = getNodeFromSlotPath(initialVehicle.config.partsTree, containingSlot)
  if initialVehicleNode and initialVehicleNode.chosenPartName and initialVehicleNode.chosenPartName ~= "" then
    node.chosenPartName = initialVehicleNode.chosenPartName
    previewVehicle.partConditions[initialVehicleNode.partPath] = initialVehicle.partConditions[initialVehicleNode.partPath]
  else
    node.chosenPartName = ""
  end
end

local function fillEmptySlotsWithInitialParts(initialNode, previewNode)
  if not initialNode or not previewNode then return end

  -- Fill current node if empty
  if previewNode.chosenPartName == "" and initialNode.chosenPartName and initialNode.chosenPartName ~= "" and not previewNode.emptyPlaceholder then
    previewNode.chosenPartName = initialNode.chosenPartName
    previewVehicle.partConditions[initialNode.partPath] = initialVehicle.partConditions[initialNode.partPath]
  end

  -- Recursively process children
  if initialNode.children then
    for slotName, initialChildNode in pairs(initialNode.children) do
      -- Create preview child node if it doesn't exist
      if not previewNode.children then previewNode.children = {} end
      if not previewNode.children[slotName] then
        previewNode.children[slotName] = {
          chosenPartName = "",
          children = {},
          suitablePartNames = {initialChildNode.chosenPartName},
          unsuitablePartNames = {},
          decisionMethod = "user"
        }
      end

      -- Recurse into child nodes
      fillEmptySlotsWithInitialParts(
        initialChildNode,
        previewNode.children[slotName]
      )
    end
  end
end

local function updateInstalledParts(addedParts, removedParts)
  -- Restore jobs reach this through a closure that can outlive the career batch, so the module may be gone.
  local delivery = overhaul_career_logistics_general
  if delivery and delivery.capturePersistentCargo then delivery.capturePersistentCargo() end
  if not shoppingSessionActive then return end

  if addedParts then
    local firstPart = next(addedParts)
    if firstPart and not addedParts[firstPart].emptyPlaceholder then
      local werePartsAdded
      local previousSignature
      local passCount = 0
      repeat
        passCount = passCount + 1
        addedParts, werePartsAdded = getNeededAdditionalParts(addedParts, currentVehicleInventoryId)
        for path, part in pairs(addedParts) do
          local node = getNodeFromSlotPath(previewVehicle.config.partsTree, part.containingSlot)
          if node then
            node.chosenPartName = part.name
          else
            -- Get the parent path by removing everything after the second-to-last "/"
            local parentPath = part.containingSlot:match("(.+)/[^/]+/$") or "/"
            local parentNode = getNodeFromSlotPath(previewVehicle.config.partsTree, parentPath)
            if parentNode then
              parentNode.children = parentNode.children or {}
              parentNode.children[part.slot] = {chosenPartName = part.name, path = parentNode.path .. part.slot .. "/", children = {}, suitablePartNames = {part.name}, unsuitablePartNames = {}, decisionMethod = "user"}
            end
          end
        end

        if werePartsAdded then
          local signatureParts = {}
          for path, part in pairs(addedParts) do
            signatureParts[#signatureParts + 1] =
              tostring(path) .. "\0" .. tostring(part and part.name) .. "\0" .. tostring(part and part.partId)
          end
          table.sort(signatureParts)
          local signature = table.concat(signatureParts, "\1")

          if signature == previousSignature then
            log("E", "partShopping",
              "Stopped additional-part resolution because the part set made no forward progress")
            werePartsAdded = false
          elseif passCount >= MAX_ADDITIONAL_PART_PASSES then
            log("E", "partShopping",
              string.format("Stopped additional-part resolution after %d passes", MAX_ADDITIONAL_PART_PASSES))
            werePartsAdded = false
          end
          previousSignature = signature
        end
      until not werePartsAdded
    end
    tableMerge(shoppingCart.partsIn, addedParts)
  end

  if removedParts then
    local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(getCurrentVehicleVehId())

    for containingSlot, part in pairs(removedParts) do
      -- If there was another part in the slot before, put the initial part back in, otherwise leave the slot empty
      local initialPartName = initialVehicle.partList[containingSlot]
      local initialPart = jbeamIO.getPart(currentVehicleData.ioCtx, initialPartName)

      if initialPartName and initialPartName ~= "" and jbeamSlotSystem.partFitsSlot(initialPart, catalog.getPreviewVehicleSlotData()[containingSlot]) then
        fillWithInitialParts(containingSlot)
      else
        local node = getNodeFromSlotPath(previewVehicle.config.partsTree, containingSlot)
        if node then node.chosenPartName = "" end
      end
      shoppingCart.partsIn[containingSlot] = nil
    end
  end

  -- Add new parts to preview vehicle data
  for _, part in pairs(shoppingCart.partsIn) do
    local node = getNodeFromSlotPath(previewVehicle.config.partsTree, part.containingSlot)
    if node then
      if part.emptyPlaceholder then
        -- this means the slot is intentionally empty
        node.chosenPartName = ""
        node.emptyPlaceholder = true
      else
        node.chosenPartName = part.name
      end
    end
  end

  -- Find and remove parts from the shopping cart that are not compatible anymore after the installed parts have changed
  local incompatibleParts = findIncompatiblePartsInShoppingCart()
  for slot, partName in pairs(incompatibleParts) do
    shoppingCart.partsIn[slot] = nil
    local node = getNodeFromSlotPath(previewVehicle.config.partsTree, slot)
    if node then node.chosenPartName = "" end
  end

  -- Fill the empty slots with initial vehicle parts using both methods
  fillEmptySlotsWithInitialParts(initialVehicle.config.partsTree, previewVehicle.config.partsTree)

  -- Add the partCondition of the new parts to the previewVehicle
  for _, part in pairs(shoppingCart.partsIn) do
    previewVehicle.partConditions[part.partPath] = part.partCondition
  end

  local additionalVehicleData = {spawnWithEngineRunning = false}
  core_vehicle_manager.queueAdditionalVehicleData(additionalVehicleData, getCurrentVehicleObj():getID())

  local spawnOptions = {}
  spawnOptions.config = previewVehicle.config
  spawnOptions.keepOtherVehRotation = true

  -- Drop a poisoned highlight map before the same-model replace. Freeroam
  -- keeps that map when the JBeam name does not change, which hides wheels.
  local previewVehicleObject = getCurrentVehicleObj()
  if previewVehicleObject and core_vehicle_partmgmt then
    pcall(core_vehicle_partmgmt.resetVehicleHighlights, false, previewVehicleObject:getID())
  end

  core_vehicles.replaceVehicle(previewVehicle.model, spawnOptions, getCurrentVehicleObj())
  core_vehicleBridge.executeAction(getCurrentVehicleObj(), 'initPartConditions', previewVehicle.partConditions, nil, nil, nil, overhaul_career_parts_painting.getPrimerColor())
  healCurrentVehicleVisible()

  -- Doing the callback immediately will result in wrong values for some parts, so we do it one frame later
  core_vehicleBridge.requestValue(getCurrentVehicleObj(),
  function()
    queueCallbackInVehicle(getCurrentVehicleObj(), "overhaul_career_parts_partShopping.updatePreviewVehicle", "partCondition.getConditions()")
  end
  , 'ping')
end

removePart = function(part)
  if isShoppingUnavailable() then return end
  if not shoppingSessionActive then return end
  local removedParts = {}
  removedParts[part.containingSlot] = part
  updateInstalledParts(nil, removedParts)
end

installPart = function(part)
  if isShoppingUnavailable() then return end
  if not shoppingSessionActive then return end

  -- only make this a sourcePart if it is not in a core slot or if the initial vehicle has a part in that slot
  -- this way we make sure that a core slot can never be empty
  if not catalog.getPreviewVehicleSlotData()[part.containingSlot].coreSlot or initialVehicle.partList[part.containingSlot] and initialVehicle.partList[part.containingSlot] ~= "" then
    part.sourcePart = true
  end
  local newParts = {}
  newParts[part.containingSlot] = part
  updateInstalledParts(newParts)

  extensions.hook("onOverhaulPartShoppingPartInstalled", {part = part})
end

local function installPartByPartShopId(partShopId)
  if isShoppingUnavailable() then return end
  if drafts.isRestoreInProgress() then
    return
  end
  for _, part in ipairs(catalog.getPartsInShop()) do
    if part.partShopId == partShopId then
      installPart(part)
      return
    end
  end
end

local function removePartBySlot(slot)
  if isShoppingUnavailable() then return end
  if drafts.isRestoreInProgress() then
    return
  end
  for _, part in pairs(shoppingCart.partsIn) do
    if part.containingSlot == slot then
      removePart(part)
      return
    end
  end
end

local closeMenuAfterSaving

local function closeMenu()
  if originComputerId then
    local computer = overhaul_world_facilities.getFacility("computer", originComputerId)
    if computer then overhaul_career_garage_computer.openMenu(computer)
    else overhaul_career_career.closeAllMenus() end
  elseif returnRoute then
    local route = returnRoute
    returnRoute = nil
    if not navigateReturnRoute(route) then
      overhaul_career_career.closeAllMenus()
    end
  else
    overhaul_career_career.closeAllMenus()
  end
  if tether then
    tether.remove = true
    tether = nil
  end
end

local function endShopping(_closeMenuAfterSaving)
  shoppingInitializer = nil
  closeMenuAfterSaving = overhaul_career_career.isAutosaveEnabled() and _closeMenuAfterSaving
  shoppingSessionActive = false
  if shoppingSaveHold then shoppingSaveHold.release(); shoppingSaveHold = nil end
  if not closeMenuAfterSaving then
    closeMenu()
  end
end

local function restoreVehicleAndEndShopping()
  local vehicles = currentVehicleInventoryId and overhaul_career_garage_inventory.getVehicles()
  -- A vehicle sold, repossessed or deleted during the session must not come back when the player leaves.
  local vehicleRemoved = vehicles and not vehicles[currentVehicleInventoryId]
  if initialVehicle and vehicles and not vehicleRemoved then
    local restored = deepcopy(initialVehicle)
    restored.partList = nil
    vehicles[currentVehicleInventoryId] = restored
  end

  extensions.hook("onOverhaulPartShoppingCancelled")
  if not vehicleRemoved then
    healSpawnedVehicle = true
    local inventoryId, damage = currentVehicleInventoryId, overhaul_career_repair_damageManager
    local changedBuild = shoppingCart and (next(shoppingCart.partsIn or {}) or next(shoppingCart.partsOut or {}))
    -- A preview snapshot belongs to its build, never to the restored parts.
    overhaul_career_garage_inventory.spawnVehicle(inventoryId, 2, function(ok)
      if ok ~= false then damage.saveDamageState(inventoryId) end
    end, nil, nil, changedBuild and {prepareReplacement = function() damage.clearDamageState(inventoryId); return true end} or nil)
  end
  endShopping()
end

-- Explicit Cancel: revert the vehicle and drop any saved cart draft.
local function discardShopping()
  if not shoppingSessionActive then
    return
  end

  drafts.abortCartRestore()
  drafts.clearCartDraftForVehicle(currentVehicleInventoryId)
  drafts.setSaveForLaterEnabled(false)
  restoreVehicleAndEndShopping()
end

-- Persist the current cart, revert the vehicle, and leave.
local function saveCartForLater()
  if not shoppingSessionActive then
    return
  end
  if not shoppingCart or not shoppingCart.partsInList or tableSize(shoppingCart.partsInList) == 0 then
    return
  end

  drafts.abortCartRestore()
  drafts.setSaveForLaterEnabled(true)
  drafts.persistCartDraftToFile()
  drafts.setSaveForLaterEnabled(false)
  restoreVehicleAndEndShopping()
end

-- Used by tether / UI unmount. Keep an in-progress cart rather than wiping it.
local function cancelShopping()
  if not shoppingSessionActive then return end
  if shoppingCart and shoppingCart.partsInList and tableSize(shoppingCart.partsInList) > 0 then
    saveCartForLater()
    return
  end

  drafts.abortCartRestore()
  drafts.setSaveForLaterEnabled(false)
  restoreVehicleAndEndShopping()
end

local function requestExit()
  if not shoppingSessionActive then closeMenu(); return end
  guihooks.trigger("partShoppingRequestExit")
end

local function onOverhaulSaveFinished()
  if closeMenuAfterSaving then
    closeMenu()
    closeMenuAfterSaving = nil
  end
end

local function updateInventory()
  local vehicle = overhaul_career_garage_inventory.getVehicles()[currentVehicleInventoryId]
  for slot, part in pairs(shoppingCart.partsOut) do
    part.location = 0
    vehicle.changedSlots[slot] = true
  end

  vehicle.partList = nil

  for slot, part in pairs(shoppingCart.partsIn) do
    if part.emptyPlaceholder then
      goto continue
    end
    local partId = part.partId
    local partComesFromInventory = part.partId ~= nil
    part.location = currentVehicleInventoryId
    part.partShopId = nil
    part.sourcePart = nil
    part.finalValue = nil
    part.partId = nil
    part.disabled = nil
    part.disabledReason = nil
    vehicle.changedSlots[slot] = true
    if partComesFromInventory then
      overhaul_career_parts_partInventory.getInventory()[partId] = part
    else
      overhaul_career_parts_partInventory.addPartToInventory(part)
    end
    ::continue::
  end
end

local function getInstalledPartsHookData()
  local installedParts = {}
  for _, part in pairs(shoppingCart.partsIn or {}) do
    if not part.emptyPlaceholder then
      table.insert(installedParts, {
        name = part.name,
        partPath = part.partPath,
        containingSlot = part.containingSlot,
        fromInventory = part.partId ~= nil,
      })
    end
  end
  return installedParts
end

local function getBuyingLabel()
  local parts = {}
  for _, part in ipairs(shoppingCart.partsInList) do
    if not overhaul_career_parts_partInventory.isHiddenInUI(part) then
      table.insert(parts, part.description.description)
    end
  end
  return {
    txt = "ui.career.partShopping.boughtNewParts",
    context = {parts = table.concat(parts, ", ")},
  }
end

local function applyShopping()
  if isShoppingUnavailable() then return false end
  if not shoppingSessionActive or not shoppingCart then return false end
  if not overhaul_career_logistics_general.validateLogisticsContainers(currentVehicleInventoryId) then return false end
  if not overhaul_career_economy_payment.canPay({money = {amount = shoppingCart.total}}) then return end
  local operation = checkout.begin("partShop", {amount = shoppingCart.total, target = {inventoryId = currentVehicleInventoryId}})

  drafts.abortCartRestore()
  drafts.clearCartDraftForVehicle(currentVehicleInventoryId)
  drafts.setSaveForLaterEnabled(false)

  local vehicles = overhaul_career_garage_inventory.getVehicles()
  local installedParts = getInstalledPartsHookData()
  vehicles[currentVehicleInventoryId] = previewVehicle
  overhaul_career_parts_vehiclePerformance.invalidateCertification(currentVehicleInventoryId)
  updateInventory()
  -- Tire wear state must be attached to newly installed parts before the
  -- transaction autosave and vehicle respawn. Inventory-sourced parts retain
  -- their own state; newly purchased parts are initialized as fresh.
  extensions.hook("onOverhaulPartShoppingPartsInstalled", currentVehicleInventoryId, installedParts)
  endShopping()
  local buyingLabel = getBuyingLabel()
  checkout.settle(operation, function()
    checkout.money.execute(overhaul_career_economy_playerAttributes.addAttributes, {money=-shoppingCart.total}, {category = "purchase", finance = {vehicleId = currentVehicleInventoryId}, tags={"partsBought", "buying"},label=buyingLabel})
  end)
  -- Publish the purchased build before a later same-build restore can read it.
  overhaul_career_repair_damageManager.saveDamageState(currentVehicleInventoryId)
  if overhaul_career_career.isAutosaveEnabled() then
    saveStore.request("partShop:apply", {currentVehicleInventoryId}, {force = true})
  else
    overhaul_career_garage_inventory.updatePartConditions(nil, currentVehicleInventoryId)
  end

  Engine.Audio.playOnce('AudioGui','event:>UI>Career>Buy_01')
  healCurrentVehicleVisible()
  core_vehicleBridge.executeAction(getObjectByID(overhaul_career_garage_inventory.getVehicleIdFromInventoryId(previewVehicle.id)),'setFreeze', false)
  extensions.hook("onOverhaulPartShoppingTransactionComplete")
  gameplay_achievement.unlockAchievement("VEHICLE_MODIFIED")
end

local function isShoppingSessionActive() return shoppingSessionActive end

-- Localized title for the route's category.
local function getCategoryBreadcrumbTitle(category)
  return _tr(category == "cargo" and "ui.career.partShopping.cargoParts" or "ui.career.partShopping.allParts")
end

-- The last nonempty path segment names the slot; use its nice name when known.
local function getSlotBreadcrumbTitle(slotPath)
  if type(slotPath) ~= "string" or slotPath == "" then return nil end
  local slotName
  for segment in string.gmatch(slotPath, "[^/]+") do slotName = segment end
  return catalog.getSlotsNiceName()[slotPath] or (slotName and catalog.getSlotsNiceName()[slotName]) or nil
end

local function getPartsInShop() return catalog.getPartsInShop() end
local function getShoppingCart() return shoppingCart end

local function onOverhaulComputerAddFunctions(menuData, computerFunctions)
  if not menuData.computerFacility.functions["partShop"] then return end

  for _, vehicleData in ipairs(menuData.vehiclesInGarage) do
    local inventoryId = vehicleData.inventoryId
    local computerFunctionData = {
      id = "partShop",
      routeTarget = "overhaul.computer.partShopping",
      label = _tr("ui.career.shared.pathPartCustomization"),
      callback = function() startShopping(inventoryId, menuData.computerFacility.id) end,
      order = 1
    }
    -- vehicle broken
    local vehicle = overhaul_career_garage_inventory.getVehicles()[inventoryId]
    if vehicle and overhaul_career_market_valueCalculator.getNumberOfBrokenParts(vehicle.partConditions) > 0 then
      computerFunctionData.disabled = true
      computerFunctionData.reason = overhaul_career_garage_computer.reasons.needsRepair
    end
    -- tutorial active
    if not menuData.hasBoughtStarterVehicle then
      computerFunctionData.disabled = true
      computerFunctionData.reason = overhaul_career_garage_computer.reasons.hasBoughtStarterVehicle
    end

    -- generic gameplay reason
    local reason = overhaul_career_permissions.getStatusForTag({"partBuying", "vehicleModification"}, {inventoryId = inventoryId})
    if not reason.allow then
      computerFunctionData.disabled = true
    end
    if reason.permission ~= "allowed" then
      computerFunctionData.reason = reason
    end

    computerFunctions.vehicleSpecific[inventoryId][computerFunctionData.id] = computerFunctionData
  end
end

M.startShopping = startShopping
M.installPart = installPart
M.installPartByPartShopId = installPartByPartShopId
M.removePartBySlot = removePartBySlot
M.updatePreviewVehicle = updatePreviewVehicle
M.cancelShopping = cancelShopping
M.discardShopping = discardShopping
M.saveCartForLater = saveCartForLater
M.requestExit = requestExit
M.applyShopping = applyShopping
M.sendShoppingDataToUI = sendShoppingDataToUI
M.readShoppingDisplay = readShoppingDisplay
M.readShoppingDisplayForUI = readShoppingDisplayForUI
M.onRouteEnter = onRouteEnter
M.onRouteMount = onRouteMount
M.getPartsInShop = getPartsInShop
M.getShoppingCart = getShoppingCart
M.isShoppingSessionActive = isShoppingSessionActive
M.getCategoryBreadcrumbTitle = getCategoryBreadcrumbTitle
M.getSlotBreadcrumbTitle = getSlotBreadcrumbTitle
M.setupTether = setupTether
M.onOverhaulComputerAddFunctions = onOverhaulComputerAddFunctions
M.onOverhaulSaveFinished = onOverhaulSaveFinished
M.setSaveForLater = drafts.setSaveForLater
M.getSaveForLater = drafts.getSaveForLater
local function onOverhaulVehicleRemoved(inventoryId)
  drafts.clearCartDraftForVehicle(inventoryId)
end

local function onVehicleSpawned(vehId)
  if vehId ~= getCurrentVehicleVehId() then return end
  if not shoppingSessionActive and not healSpawnedVehicle then return end
  healSpawnedVehicle = false
  healCurrentVehicleVisible()
end

M.onOverhaulVehicleRemoved = onOverhaulVehicleRemoved
M.onVehicleSpawned = onVehicleSpawned

local function releaseShoppingHolds()
  shoppingDisplayOwnerUnloaded = true
  publishedShoppingDisplay = nil
  shoppingInitializer = nil
  saveStore.releaseHolds(M)
  shoppingSaveHold = nil
end
M.onExtensionUnloaded = releaseShoppingHolds

return M
