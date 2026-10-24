-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Part shop catalog: available parts, translated slot names and route selection.
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/partShopping.lua.

local jbeamIO = require('jbeam/io')
local slotLabels = require('overhaul/lib/parts/slotLabels')
local cargoSemantics = require('overhaul/lib/logistics/cargoSemantics')

local M = {}

-- ctx supplies the live facade state:
--   getShoppingCart(), getInitialVehicle(), getCurrentVehicleVehId(), getCurrentVehicleObj()
function M.create(ctx)
  local partsInShop = {}
  local partShopId = 0
  local slotsNiceName = {}
  local partsNiceName = {}
  local previewVehicleSlotData = {}

  local function isCargoLogisticsMaterialsUnlocked()
    overhaul_career_progression_skills.checkUnlocks()
    return overhaul_career_progression_skills.getBranchByPath('logistics-materials').unlocked
  end

  local function generatePart(partName, currentVehicleData, availableParts, path, slot, vehicleObj)
    local jbeamData = jbeamIO.getPart(currentVehicleData.ioCtx, partName)
    if not jbeamData then return end
    local part = {}
    part.name = partName
    part.value = jbeamData.information.value or 100
    part.partCondition = {integrityValue = 1, odometer = 0, visualValue = 1}
    -- availableParts entries belong to the jbeamIO cache, so copy before writing the
    -- translated name into it, otherwise every shop visit re-translates the same table
    local partInfo = availableParts[partName]
    part.description = partInfo and shallowcopy(partInfo) or {description = _tr("ui.career.partShopping.noDescriptionFound")}
    part.tags = {}
    part.containingSlot = path
    part.partPath = path .. partName
    part.slot = slot
    part.vehicleModel = vehicleObj:getJBeamFilename()
    part.year = 2023
    part.partShopId = partShopId

    if part.description and part.description.description then
      part.description.description = core_vehicle_partmgmt.getTranslation(
        part.description.description,
        "ui.vehicleconfig.information.name."
      )
    end

    if jbeamData.cargoStorage and not isCargoLogisticsMaterialsUnlocked() and jbeamData.information.name ~= "Magic Cargo Testing Part" then
      for i=2, tableSize(jbeamData.cargoStorage) do
        for _, cargoType in ipairs(jbeamData.cargoStorage[i][3]) do
          if cargoSemantics.cargo(cargoType).requiresMaterialUnlock == true then
            part.disabled = true
            part.disabledReason = _tr("ui.career.partShopping.cargoLogisticsNotUnlocked")
            break
          end
        end
      end
    end
    partShopId = partShopId + 1

    part.finalValue = math.max(roundNear(overhaul_career_market_valueCalculator.getPartValue(part), 5) - 0.01, 0)
    return part
  end

  local function getPartSlotFromPartIdInShoppingCart(partId)
    for _, part in pairs(ctx.getShoppingCart().partsIn) do
      if part.partId == partId then
        return part.containingSlot
      end
    end
  end

  -- Spare parts (location 0, not part of an engine package) grouped by part name, each
  -- group in the inventory's pairs() order. Built once per shop generation: matching every
  -- shop part against the whole inventory cost shop parts x inventory size on every install.
  local function indexSparePartsByName(inventory)
    local sparesByName = {}
    for partId, inventoryPart in pairs(inventory) do
      if inventoryPart.name ~= nil and not inventoryPart.enginePackageId and inventoryPart.location == 0 then
        local spares = sparesByName[inventoryPart.name]
        if not spares then
          spares = {}
          sparesByName[inventoryPart.name] = spares
        end
        spares[#spares + 1] = {partId = partId, part = inventoryPart}
      end
    end
    return sparesByName
  end

  -- The cart slot of each inventory part already in the cart: the first cart entry with that
  -- partId wins, as in getPartSlotFromPartIdInShoppingCart.
  local function indexCartSlotsByPartId()
    local slotByPartId, seen = {}, {}
    for _, part in pairs(ctx.getShoppingCart().partsIn) do
      if part.partId ~= nil and not seen[part.partId] then
        seen[part.partId] = true
        slotByPartId[part.partId] = part.containingSlot
      end
    end
    return slotByPartId
  end

  local function addMatchingInventoryParts(part, suitablePartName, slotName, inventoryMatch)
    for _, spare in ipairs(inventoryMatch.sparesByName[suitablePartName] or {}) do
      local partId, inventoryPart = spare.partId, spare.part
      local partSlotOfThisPartInShoppingCart = inventoryMatch.cartSlotByPartId[partId]
      if inventoryPart.vehicleModel == part.vehicleModel and (not partSlotOfThisPartInShoppingCart or partSlotOfThisPartInShoppingCart == part.containingSlot) then
        local shopPart = deepcopy(inventoryPart)
        shopPart.containingSlot = part.containingSlot
        shopPart.partPath = part.partPath
        shopPart.slot = slotName
        shopPart.vehicleModel = part.vehicleModel
        shopPart.partId = partId
        shopPart.partShopId = partShopId
        partShopId = partShopId + 1
        shopPart.finalValue = 0
        table.insert(partsInShop, shopPart)
      end
    end
  end

  -- inventoryMatch: {sparesByName, cartSlotByPartId} for this generation.
  local function generatePartFromTree(treeNode, slotName, slotInfo, currentVehicleData, availableParts, vehicleObj, inventoryMatch)
    if not treeNode then return end

    local partInfo = availableParts[treeNode.chosenPartName]
    previewVehicleSlotData[treeNode.path] = slotInfo

    treeNode.chosenPartNiceName = partInfo and core_vehicle_partmgmt.getTranslation(partInfo.description, "ui.vehicleconfig.information.name.")
    treeNode.slotNiceName = slotLabels.getLabel(slotName, slotInfo, core_vehicle_partmgmt.getTranslation)
    slotsNiceName[treeNode.path] = treeNode.slotNiceName
    slotsNiceName[slotName] = treeNode.slotNiceName
    treeNode.slotName = slotName

    partsNiceName[treeNode.chosenPartName] = treeNode.chosenPartNiceName

    if treeNode.suitablePartNames then
      for _, suitablePartName in ipairs(treeNode.suitablePartNames) do
        local part = generatePart(suitablePartName, currentVehicleData, availableParts, treeNode.path, slotName, vehicleObj)
        if part and part.containingSlot ~= "main" and not part.description.isAuxiliary then
          table.insert(partsInShop, part)

          -- Add matching parts from inventory
          addMatchingInventoryParts(part, suitablePartName, slotName, inventoryMatch)
        end
      end
    end

    if slotInfo and not slotInfo.coreSlot and ctx.getInitialVehicle().partList[treeNode.path] and ctx.getInitialVehicle().partList[treeNode.path] ~= "" then
      local emptyPart = {}
      emptyPart.name = "empty"
      emptyPart.description = {}
      emptyPart.description.description = core_locales.contextTranslate("ui.career.partShopping.removePart", {partName = partsNiceName[ctx.getInitialVehicle().partList[treeNode.path]]})
      emptyPart.emptyPlaceholder = true
      emptyPart.containingSlot = treeNode.path
      emptyPart.partPath = treeNode.path .. "empty"
      emptyPart.slot = slotName
      emptyPart.slotNiceName = treeNode.slotNiceName
      emptyPart.partShopId = partShopId
      emptyPart.finalValue = 0
      partShopId = partShopId + 1
      table.insert(partsInShop, emptyPart)
    end

    -- Recursively process child slots
    if treeNode.children and next(treeNode.children) then
      local parentData = treeNode.chosenPartName and treeNode.chosenPartName ~= "" and
        jbeamIO.getPart(currentVehicleData.ioCtx, treeNode.chosenPartName)
      for childSlot, childNode in pairs(treeNode.children) do
        local childSlotInfo = slotLabels.getSlotInfo(parentData, childSlot) or slotLabels.getSlotInfo(partInfo, childSlot)
        generatePartFromTree(childNode, childSlot, childSlotInfo, currentVehicleData, availableParts, vehicleObj, inventoryMatch)
      end
    end
  end

  local function removeSlotsWithoutParts(treeNode, slotsWithParts)
    for slotName, childNode in pairs(treeNode.children or {}) do
      removeSlotsWithoutParts(childNode, slotsWithParts)
      if not slotsWithParts[childNode.path] and not next(childNode.children or {}) then
        treeNode.children[slotName] = nil
      end
    end
  end

  local function generatePartShop()
    local currentVehicleData = extensions.core_vehicle_manager.getVehicleData(ctx.getCurrentVehicleVehId())
    local ioCtx = currentVehicleData and currentVehicleData.ioCtx
    if not ioCtx then return end
    local availableParts = jbeamIO.getAvailableParts(ioCtx)
    local vehicleObj = ctx.getCurrentVehicleObj()
    if not vehicleObj then return end
    previewVehicleSlotData = {}

    slotsNiceName = {}

    partsInShop = {}
    local config = currentVehicleData.config
    local partsTree = config and config.partsTree
    if not partsTree then return end
    local chosenPartsTree = deepcopy(partsTree)
    local inventoryMatch = {
      sparesByName = indexSparePartsByName(overhaul_career_parts_partInventory.getInventory()),
      cartSlotByPartId = indexCartSlotsByPartId(),
    }
    generatePartFromTree(chosenPartsTree, "", nil, currentVehicleData, availableParts, vehicleObj, inventoryMatch)

    local slotsWithParts = {}
    for _, part in ipairs(partsInShop) do
      slotsWithParts[part.containingSlot] = true
    end
    removeSlotsWithoutParts(chosenPartsTree, slotsWithParts)

    return chosenPartsTree
  end

  local function buildSearchSlotList(partTree)
    local searchSlotsByPath = {}

    local function traverseTree(node, slotName, parentSegments)
      if not node then return end
      local pathSegments = deepcopy(parentSegments or {})
      if slotName then
        pathSegments[#pathSegments + 1] = node.slotNiceName or slotName
        searchSlotsByPath[node.path] = {
          slotName = slotName,
          slotNiceName = node.slotNiceName,
          path = node.path,
          nicePath = table.concat(pathSegments, " > "),
          partNiceName = node.chosenPartNiceName
        }
      end
      for childSlot, childNode in pairs(node.children or {}) do
        traverseTree(childNode, childSlot, pathSegments)
      end
    end

    traverseTree(partTree)

    -- Convert dict to sorted list
    local searchSlotList = {}
    for path, slotInfo in pairs(searchSlotsByPath) do
      table.insert(searchSlotList, slotInfo)
    end
    table.sort(searchSlotList, function(leftPart, rightPart)
      local aName = tostring(leftPart.slotNiceName or leftPart.slotName or "")
      local bName = tostring(rightPart.slotNiceName or rightPart.slotName or "")
      if aName == bName then
        return tostring(leftPart.path or "") < tostring(rightPart.path or "")
      end
      return aName < bName
    end)
    return searchSlotList
  end

  -- Normalize a router route into the part shopping selection (category, slot path,
  -- visible panel). Mirrors the panel decision the Vue route used to make from
  -- route.name/params: the slot route always shows the parts list, the category
  -- route shows the parts list for cargo and the slot list otherwise, and the root
  -- shows the categories.
  local function normalizeRouteSelection(toRoute)
    local name = type(toRoute) == "table" and toRoute.name or nil
    local params = type(toRoute) == "table" and toRoute.params or nil

    local category = ""
    local slotPath = ""
    if type(params) == "table" then
      if type(params.category) == "string" then
        category = params.category
      end
      -- slotPath is a node path string ("main/engine/"); the catch-all route may
      -- also deliver it as an array of segments.
      local routeSlotPath = params.slotPath
      if type(routeSlotPath) == "string" then
        slotPath = routeSlotPath
      elseif type(routeSlotPath) == "table" then
        slotPath = table.concat(routeSlotPath, "/")
      end
    end

    local panel = "categories"
    if name == "overhaul.computer.partShopping.category.slot" then
      panel = "parts"
    elseif name == "overhaul.computer.partShopping.category" then
      panel = (category == "cargo") and "parts" or "slots"
    end

    return category, slotPath, panel
  end

  -- Build the parts list for the active route selection. Replicates the Vue
  -- store's filterParts: cargo filters by the "cargo_load" name, every other
  -- category filters by the selected slot path (containingSlot match).
  local function buildFilteredParts(category, slotPath)
    local result = {}
    for _, part in ipairs(partsInShop) do
      if part.slot then
        if category == "cargo" then
          if part.name and string.find(part.name, "cargo_load", 1, true) then
            result[#result + 1] = part
          end
        elseif slotPath ~= "" and part.containingSlot == slotPath then
          result[#result + 1] = part
        end
      end
    end

    -- Same ordering as the Vue store: empty placeholders first, then inventory
    -- parts (partId), then alphabetical by description.
    table.sort(result, function(leftPart, rightPart)
      local isLeftEmpty = leftPart.emptyPlaceholder == true
      local isRightEmpty = rightPart.emptyPlaceholder == true
      if isLeftEmpty ~= isRightEmpty then return isLeftEmpty end
      local isLeftInventoryPart = leftPart.partId ~= nil
      local isRightInventoryPart = rightPart.partId ~= nil
      if isLeftInventoryPart ~= isRightInventoryPart then return isLeftInventoryPart end
      local leftDescription = (leftPart.description and leftPart.description.description) or ""
      local rightDescription = (rightPart.description and rightPart.description.description) or ""
      return leftDescription < rightDescription
    end)

    return result
  end

  local catalog = {}
  catalog.generatePart = generatePart
  catalog.generatePartShop = generatePartShop
  catalog.getPartSlotFromPartIdInShoppingCart = getPartSlotFromPartIdInShoppingCart
  catalog.buildSearchSlotList = buildSearchSlotList
  catalog.normalizeRouteSelection = normalizeRouteSelection
  catalog.buildFilteredParts = buildFilteredParts
  function catalog.getPartsInShop() return partsInShop end
  function catalog.getSlotsNiceName() return slotsNiceName end
  function catalog.getPartsNiceName() return partsNiceName end
  function catalog.resetPartsNiceName() partsNiceName = {} end
  function catalog.getPreviewVehicleSlotData() return previewVehicleSlotData end
  function catalog.resetPartShopId() partShopId = 0 end
  function catalog.clearFailedStart()
    partsInShop, slotsNiceName, partsNiceName, previewVehicleSlotData = {}, {}, {}, {}
    partShopId = 0
  end
  function catalog.captureInitializerState()
    -- Slot translations are updated in place; preserve their contents as well as the prior table identity.
    local slotNames = {}
    for key, value in pairs(slotsNiceName) do slotNames[key] = value end
    return {parts = partsInShop, id = partShopId, slots = slotsNiceName, slotNames = slotNames,
      names = partsNiceName, preview = previewVehicleSlotData}
  end
  function catalog.restoreInitializerState(state)
    partsInShop, partShopId, slotsNiceName = state.parts, state.id, state.slots
    partsNiceName, previewVehicleSlotData = state.names, state.preview
    for key in pairs(slotsNiceName) do slotsNiceName[key] = nil end
    for key, value in pairs(state.slotNames) do slotsNiceName[key] = value end
  end
  function catalog.takePartShopId()
    local id = partShopId
    partShopId = partShopId + 1
    return id
  end
  return catalog
end

return M
