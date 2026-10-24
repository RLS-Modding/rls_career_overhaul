-- Dyno hubs: mounted hardware, wheel slot matching and temporary hub configurations.
-- The session composes this per-load API so hardware rules stay separate from steering and cameras.
local M = {}

-- Wheel slot names look like wheel_F_5 or wheel_R_centerlug; anything else is not a wheel slot.
local function asWheelSlotType(value)
  if type(value) == "string" and value:match("^wheel_[FR]_.+$") then
    return value
  end
  return nil
end

-- The part tree node names the slot the wheel occupies. Prefer it over the wheel part's slotType, because modded wheels often declare several compatible slot types as an array.
local function getWheelSlotType(node, jbeamData)
  local slotType = asWheelSlotType(node and node.id)
  if slotType then
    return slotType
  end

  if node and type(node.path) == "string" then
    slotType = node.path:match("/(wheel_[FR]_[^/]+)/?$")
    if slotType then
      return slotType
    end
  end

  local declaredSlotType = jbeamData and jbeamData.slotType or nil
  slotType = asWheelSlotType(declaredSlotType)
  if slotType then
    return slotType
  end

  -- An array is only safe as a fallback when it names one wheel slot. If it advertises multiple lug patterns, the part-tree node/path must decide.
  if type(declaredSlotType) == "table" then
    local onlySlotType = nil
    for _, candidate in ipairs(declaredSlotType) do
      candidate = asWheelSlotType(candidate)
      if candidate then
        if onlySlotType and onlySlotType ~= candidate then
          return nil
        end
        onlySlotType = candidate
      end
    end
    return onlySlotType
  end

  return nil
end

function M.create(inputs)
  local parts = inputs.parts

  local function getDynoHubOption(hubId)
    return inputs.DYNO_HUB_OPTIONS[hubId] or inputs.DYNO_HUB_OPTIONS[inputs.DEFAULT_DYNO_HUB_ID]
  end

  -- RLS hardware ships with this mod. Optional hub providers are considered available only when one of their unique files is mounted in BeamNG's VFS, which also excludes installed-but-disabled mods.
  local function isDynoHubAvailable(hubId)
    local option = inputs.DYNO_HUB_OPTIONS[hubId]
    if not option then
      return false
    end

    if not option.requiredFile then
      return true
    end
    return FS:fileExists(option.requiredFile) == true
  end

  local function getDynoHubOptionsForUi()
    local options = {}
    for _, hubId in ipairs(inputs.DYNO_HUB_ORDER) do
      local option = inputs.DYNO_HUB_OPTIONS[hubId]
      if isDynoHubAvailable(hubId) then
        table.insert(options, {
          id = option.id,
          label = option.label,
          description = option.description
        })
      end
    end
    return options
  end

  -- A wheel replacement drops its children because the hub is the complete temporary assembly.
  local function replaceWheelNode(node, vehicleData, hubId)
    if not node.chosenPartName or node.chosenPartName == "" then return true, 0 end
    local jbeamData = inputs.jbeamIO.getPart(vehicleData.ioCtx, node.chosenPartName)
    local slotType = getWheelSlotType(node, jbeamData)
    if not slotType then return true, 0 end
    local axle
    if slotType:match("^wheel_F_") then
      axle = "front"
    elseif slotType:match("^wheel_R_") then
      axle = "rear"
    end
    if not axle then return true, 0 end
    local dynoPartName = inputs.dynoState.getDynoHubPartName(slotType, axle, hubId)
    if not dynoPartName then
      return false, string.format("Missing dyno hub for slot type '%s'.", tostring(slotType))
    end
    if not inputs.jbeamIO.getPart(vehicleData.ioCtx, dynoPartName) then
      local hubOption = getDynoHubOption(hubId)
      return false, string.format("%s does not provide a hub for slot type '%s' yet.", hubOption.label, tostring(slotType))
    end
    node.chosenPartName = dynoPartName
    node.children = nil
    node.decisionMethod = "user"
    return true, 1
  end

  local function replaceWheelTree(node, vehicleData, hubId)
    if not node then return true, 0 end
    local ok, countOrError = replaceWheelNode(node, vehicleData, hubId)
    if not ok then return false, countOrError end
    local replacedCount = countOrError
    for _, childNode in pairs(node.children or {}) do
      local childOk, childCountOrError = replaceWheelTree(childNode, vehicleData, hubId)
      if not childOk then return false, childCountOrError end
      replacedCount = replacedCount + childCountOrError
    end
    return true, replacedCount
  end

  local function replaceWheelEntriesWithDynoHubs(vehId, partsTree, hubId)
    if not vehId or not partsTree then return nil, "Vehicle wheel data is unavailable." end
    local vehicleData = extensions.core_vehicle_manager.getVehicleData(vehId)
    if not vehicleData or not vehicleData.ioCtx then return nil, "Vehicle part context is unavailable." end
    local ok, countOrError = replaceWheelTree(partsTree, vehicleData, hubId)
    if not ok then return nil, countOrError end
    return countOrError
  end

  inputs.dynoState.getDynoHubPartName = function(slotType, axle, hubId)
    local hubOption = getDynoHubOption(hubId)
    if hubOption.partsBySlot then
      return hubOption.partsBySlot[slotType]
    end
    if axle == "front" then
      local suffix = slotType and slotType:match("^wheel_F_(.+)$")
      if suffix and inputs.SUPPORTED_FRONT_SUFFIXES[suffix] then
        return hubOption.frontPartPrefix .. suffix
      end
    elseif axle == "rear" then
      local suffix = slotType and slotType:match("^wheel_R_(.+)$")
      if suffix and inputs.SUPPORTED_REAR_SUFFIXES[suffix] then
        return hubOption.rearPartPrefix .. suffix
      end
    end

    return nil
  end

  local function buildDynoConfig(config, vehId, hubId)
    if not config then
      return nil, "Vehicle configuration is missing."
    end

    local fullConfig = parts.history.safeDeepcopy(config)
    if not fullConfig.partsTree then
      return nil, "The dyno could not read the vehicle part tree."
    end

    local replacedCount, replaceError = replaceWheelEntriesWithDynoHubs(vehId, fullConfig.partsTree, hubId)
    if not replacedCount then
      return nil, replaceError
    end

    if replacedCount == 0 then
      return nil, "The dyno could not find any wheel slots to replace."
    end

    if getDynoHubOption(hubId).id == "rls" then
      fullConfig = overhaul_vehicles_hubDyno.prepareConfig(fullConfig)
    end
    return fullConfig
  end

  return {
    isDynoHubAvailable = isDynoHubAvailable,
    getDynoHubOptionsForUi = getDynoHubOptionsForUi,
    buildDynoConfig = buildDynoConfig,
  }
end

return M
