-- Tyre quotes: the axle groups a vehicle can have replaced, their prices, the quote revision and the tyre inspection.
-- Part of the tire system; the functions attach to the tire system's M, so callers reach them as before.
local partFactory = {}

function partFactory.new(inputs)

  -- Name and price of one fitted part, from the jbeam catalog, the owned part, or the translated catalog name.
  local function catalogInfo(vehicleModel, partName, fallbackPart)
    local info = {
      name = fallbackPart and ((fallbackPart.description and fallbackPart.description.description) or fallbackPart.name) or partName,
      value = tonumber(fallbackPart and fallbackPart.value) or 100,
    }
    if not vehicleModel or not partName then
      return info
    end
    local ioCtx = inputs.ioCtxCache[vehicleModel]
    if ioCtx == nil then
      if tableSize(inputs.ioCtxCache) >= 8 then table.clear(inputs.ioCtxCache) end
      ioCtx = inputs.jbeamIO.startLoading({"/vehicles/" .. tostring(vehicleModel) .. "/", "/vehicles/common/"})
      inputs.ioCtxCache[vehicleModel] = ioCtx or false
    end
    if ioCtx then
      local partData = inputs.jbeamIO.getPart(ioCtx, partName)
      if partData and partData.information then
        info.value = tonumber(partData.information.value) or info.value
        info.name = partData.information.name or info.name
      end
    end
    -- The stock part manager loads on demand; tire quotes also run before tuning opens.
    if core_vehicle_partmgmt then
      local translated = core_vehicle_partmgmt.getTranslation(info.name, "ui.vehicleconfig.information.name.")
      if translated then
        info.name = translated
      end
    end
    if type(info.name) ~= "string" then
      info.name = tostring(partName)
    end
    return info
  end

  -- "Front Axle" or "Rear Axle", numbered from the second axle of each end.
  local function groupLabel(index, wheels)
    local hasFront = false
    for _, wheel in ipairs(wheels) do
      if string.sub(string.upper(wheel.name or ""), 1, 1) == "F" then
        hasFront = true
        break
      end
    end
    if hasFront then
      return index == 1 and "Front Axle" or ("Front Axle " .. tostring(index))
    end
    return index == 1 and "Rear Axle" or ("Rear Axle " .. tostring(index))
  end

  -- Groups the layout's wheels by the fitted tyre path, so a pair of wheels on one axle becomes one replaceable group.
  local function groupWheelsByPart(vehicleData)
    local grouped = {}
    for _, wheel in ipairs(vehicleData.rlsTireLayout and vehicleData.rlsTireLayout.wheels or {}) do
      -- A pressure-wheel row may report the generic `main` containing slot even though its active tire part path is axle-specific. The fitted tire path is therefore the stable grouping key for replacement and pricing.
      local key = wheel.partPath or wheel.containingSlot or wheel.partOrigin or wheel.name
      grouped[key] = grouped[key] or {key = key, wheels = {}, parts = {}}
      table.insert(grouped[key].wheels, wheel)
      local partKey = wheel.partId and ("id:" .. tostring(wheel.partId)) or ("path:" .. tostring(wheel.partPath or key))
      grouped[key].parts[partKey] = grouped[key].parts[partKey] or {
        partId = wheel.partId,
        partPath = wheel.partPath,
        partOrigin = wheel.partOrigin,
        containingSlot = wheel.containingSlot,
      }
    end
    return grouped
  end

  -- Splits the groups into front and rear axles, each sorted by key so the list order is stable.
  local function sortedFrontAndRear(grouped)
    local front, rear = {}, {}
    for _, group in pairs(grouped) do
      table.sort(group.wheels, function(a, b) return a.name < b.name end)
      local isFront = string.sub(string.upper(group.wheels[1].name or ""), 1, 1) == "F"
      table.insert(isFront and front or rear, group)
    end
    table.sort(front, function(a, b) return a.key < b.key end)
    table.sort(rear, function(a, b) return a.key < b.key end)
    return front, rear
  end

  -- Prices the group's parts and returns the part rows, the subtotal and the sorted part names.
  local function priceGroupParts(inventoryId, vehicleData, group, isBusiness)
    local subtotal = 0
    local partNames = {}
    local partsArray = {}
    for _, descriptor in pairs(group.parts) do
      local partId, part
      if not isBusiness then
        partId, part = inputs.findPersonalPart(inventoryId, descriptor.partPath, descriptor.partOrigin,
          descriptor.containingSlot)
      end
      descriptor.partId = descriptor.partId or partId
      local vehicleModel = vehicleData.model or vehicleData.model_key or
                             (vehicleData.vehicleConfig and vehicleData.vehicleConfig.model_key)
      local info = catalogInfo(vehicleModel, descriptor.partOrigin or (part and part.name), part)
      descriptor.name = info.name
      descriptor.price = info.value
      subtotal = subtotal + info.value
      partNames[info.name] = true
      table.insert(partsArray, descriptor)
    end
    table.sort(partsArray, function(a, b) return tostring(a.partPath) < tostring(b.partPath) end)
    local names = {}
    for name in pairs(partNames) do table.insert(names, name) end
    table.sort(names)
    return partsArray, subtotal, names
  end

  -- Per-wheel rows for the screen, and the group's combined wear and flat state.
  local function wheelRowsFor(group)
    local remainingTotal, flat = 0, false
    local wheelStates = {}
    for _, wheel in ipairs(group.wheels) do
      remainingTotal = remainingTotal + inputs.tireModel.clamp(wheel.remaining, 0, 1)
      flat = flat or wheel.flat == true
      table.insert(wheelStates, {
        name = wheel.name,
        remainingPercent = inputs.round(inputs.tireModel.clamp(wheel.remaining, 0, 1) * 100, 1),
        flat = wheel.flat == true,
      })
    end
    return wheelStates, remainingTotal, flat
  end

  local function buildAxleGroups(inventoryId, vehicleData, isBusiness)
    local front, rear = sortedFrontAndRear(groupWheelsByPart(vehicleData))
    local result = {}
    local function appendGroups(groups, prefix)
      for index, group in ipairs(groups) do
        local partsArray, subtotal, names = priceGroupParts(inventoryId, vehicleData, group, isBusiness)
        local wheelStates, remainingTotal, flat = wheelRowsFor(group)
        local wheelCount = math.max(#group.wheels, 1)
        table.insert(result, {
          id = prefix .. tostring(index),
          label = groupLabel(index, group.wheels),
          tireName = table.concat(names, ", "),
          tireCount = #group.wheels,
          remainingPercent = inputs.round(remainingTotal / wheelCount * 100, 1),
          flat = flat,
          subtotal = inputs.round(subtotal, 2),
          perTirePrice = inputs.round(subtotal / wheelCount, 2),
          parts = partsArray,
          wheels = inputs.deepCopy(group.wheels),
          wheelStates = wheelStates,
        })
      end
    end
    appendGroups(front, "front-")
    appendGroups(rear, "rear-")
    return result
  end

  local function quoteRevision(vehicleData, groups)
    local rows = {inputs.currentTireSignature(vehicleData)}
    for _, group in ipairs(groups or {}) do
      table.insert(rows, string.format("%s:%0.2f:%s", group.id, group.subtotal, group.tireName))
    end
    return table.concat(rows, "|")
  end

  local function bundledProvider()
    return {
      id = "rls-bundled",
      name = "RLS Tyre Wear and Thermals",
      version = "1.3.0",
      source = "bundled",
      apiVersion = 1,
      integrated = true,
    }
  end

  -- The shop payload shared by the personal and fleet screens. `layoutMessage` says how to get the layout back.
  local function buildTireShopPayload(vehicleData, groups, layoutMessage)
    local provider = inputs.deepCopy(vehicleData.overhaulTires or bundledProvider())
    local integrated = provider.integrated == true
    local signature = inputs.currentTireSignature(vehicleData)
    local inspection = vehicleData.maintenanceComputerState and vehicleData.maintenanceComputerState.tireInspection
    local inspected = inspection and inspection.signature == signature
    local total = 0
    for _, group in ipairs(groups) do total = total + group.subtotal end
    local available = inputs.isMaintenanceEnabled() and integrated and #groups > 0
    local message
    if not inputs.isMaintenanceEnabled() then
      message = "Maintenance Mode is not enabled."
    elseif not integrated then
      message = "The selected external tire provider does not expose the RLS integration API."
    elseif #groups == 0 then
      message = layoutMessage
    end
    return {
      available = available,
      message = message,
      provider = provider,
      inspected = inspected == true,
      inspectedAt = inspected and inspection.inspectedAt or nil,
      signature = signature,
      quoteRevision = quoteRevision(vehicleData, groups),
      axles = groups,
      replaceAllSubtotal = inputs.round(total, 2),
    }
  end

  function inputs.M.buildUiData(inventoryId)
    local vehicleData = inputs.vehicleDataForInventory(inventoryId)
    if not vehicleData then
      return {available = false, message = "Vehicle not found."}
    end
    local groups = buildAxleGroups(inventoryId, vehicleData, false)
    return buildTireShopPayload(vehicleData, groups, "Tire layout is not available yet. Retrieve or respawn this vehicle once.")
  end

  function inputs.M.buildBusinessUiData(businessId, vehicleId)
    local vehicleData = inputs.businessVehicleData(businessId, vehicleId)
    if not vehicleData then return {available = false, message = "Fleet vehicle not found."} end
    inputs.M.sendContextForBusinessVehicle(businessId, vehicleId, false)
    local groups = buildAxleGroups(vehicleId, vehicleData, true)
    return buildTireShopPayload(vehicleData, groups, "Tire layout is not available yet. Pull out or respawn this fleet vehicle once.")
  end

  -- Records the current tyre condition as inspected, so a quote for it can be bought.
  local function recordInspection(vehicleData, uiData)
    vehicleData.maintenanceComputerState = type(vehicleData.maintenanceComputerState) == "table" and
                                             vehicleData.maintenanceComputerState or {revealed = {}, jobs = {}}
    vehicleData.maintenanceComputerState.tireInspection = {
      signature = uiData.signature,
      inspectedAt = os.time(),
    }
  end

  function inputs.M.inspectAll(inventoryId)
    inventoryId = tonumber(inventoryId)
    local uiData = inputs.M.buildUiData(inventoryId)
    if not uiData.available then
      return {ok = false, message = uiData.message or "Tire inspection is unavailable."}
    end
    recordInspection(inputs.vehicleDataForInventory(inventoryId), uiData)
    inputs.markDirty(inventoryId)
    return {ok = true, completed = true, tireShop = inputs.M.buildUiData(inventoryId)}
  end

  function inputs.M.inspectBusiness(businessId, vehicleId)
    local uiData = inputs.M.buildBusinessUiData(businessId, vehicleId)
    if not uiData.available then
      return {ok = false, message = uiData.message or "Tire inspection is unavailable."}
    end
    recordInspection(inputs.businessVehicleData(businessId, vehicleId), uiData)
    overhaul_career_saveSystem.saveCurrent()
    return {ok = true, completed = true, tireShop = inputs.M.buildBusinessUiData(businessId, vehicleId)}
  end

  return {
    bindInputs = function() end,
  }
end

return partFactory
