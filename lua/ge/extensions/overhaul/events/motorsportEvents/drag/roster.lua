-- Owns entrant creation and registered-configuration identity checks.
-- drag/catalog.lua supplies authored builds; registration.lua supplies player snapshots; the runner checks identity.
local M = {}

local function equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for key, value in pairs(a) do if not equal(value, b[key]) then return false end end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

local function matchesIdentity(entrant, vehicle)
  if not vehicle or vehicle.JBeam ~= entrant.model then return false end
  local inventory = overhaul_career_garage_inventory
  if entrant.inventoryId and inventory and type(inventory.getInventoryIdFromVehicleId) == 'function' then
    local ok, id = pcall(function() return inventory.getInventoryIdFromVehicleId(vehicle:getID()) end)
    if not ok or id ~= entrant.inventoryId then return false end
  end
  return true
end

local function resolvedTree(node)
  local copy = {id = node.id, path = node.path, chosenPartName = node.chosenPartName, children = {}}
  local count = 0
  for slot, child in pairs(node.children or {}) do
    if type(child) == 'table' and type(child.id) == 'string' and type(child.path) == 'string'
      and type(child.chosenPartName) == 'string' and child.chosenPartName ~= '' then
      local resolved, children = resolvedTree(child)
      copy.children[slot], count = resolved, count + children + 1
    end
  end
  return copy, count
end

local function parts(config)
  if type(config) == 'string' then
    local ok, decoded = pcall(deserialize, config)
    config = ok and decoded or nil
  end
  if type(config) ~= 'table' then return nil end
  if config.partsTree ~= nil then
    if type(config.partsTree) ~= 'table' then return nil, true end
    local partmgmt = core_vehicle_partmgmt
    if not partmgmt or type(partmgmt.partsTreeToPartsMap) ~= 'function' then return nil, true end
    local ok, converted = pcall(function()
      local resolved, count = resolvedTree(config.partsTree)
      if count == 0 then return nil end
      return partmgmt.partsTreeToPartsMap(resolved)
    end)
    return ok and type(converted) == 'table' and converted or nil, true
  end
  if type(config.parts) ~= 'table' then return nil end
  local installed = {}
  for slot, name in pairs(config.parts) do
    if name ~= '' then installed[slot] = name end
  end
  return installed
end

local function humanize(value)
  local text = tostring(value):gsub('[_%-]+', ' ')
  return text:gsub('^%l', string.upper)
end

local function descriptionText(value, fallback)
  if type(value) == 'string' then return value end
  if type(value) == 'table' then
    if value.description then return descriptionText(value.description, fallback) end
    if type(value.name) == 'string' then return value.name end
  end
  return fallback
end

function M.diffParts(registered, current)
  local changes, slots = {}, {}
  for slot in pairs(registered or {}) do slots[slot] = true end
  for slot in pairs(current or {}) do slots[slot] = true end
  for slot in pairs(slots) do
    local before, after = registered and registered[slot], current and current[slot]
    if before ~= after then
      changes[#changes + 1] = {slot = slot, slotLabel = humanize(slot), kind = not before and 'added' or not after and 'removed' or 'swapped',
        registered = before and {name = before, label = humanize(before)} or nil,
        current = after and {name = after, label = humanize(after)} or nil}
    end
  end
  table.sort(changes, function(a, b) return a.slot < b.slot end)
  return changes
end

function M.partChanges(entrant, vehicle)
  local registered = parts(entrant.config)
  local data
  if vehicle and core_vehicle_manager and type(core_vehicle_manager.getVehicleData) == 'function' then
    local ok, result = pcall(core_vehicle_manager.getVehicleData, vehicle:getID())
    if ok then data = result end
  end
  local current, currentTree
  if data then current, currentTree = parts(data.config) end
  if currentTree and not current then return {} end
  current = current or vehicle and parts(vehicle.partConfig)
  if not registered or not current then return {} end
  local changes = M.diffParts(registered, current)
  local available = {}
  local jbeamIO
  if data and data.ioCtx then
    local ok, module = pcall(require, 'jbeam/io')
    if ok then jbeamIO = module end
  end
  if data and data.ioCtx and jbeamIO and type(jbeamIO.getAvailableParts) == 'function' then
    local ok, result = pcall(jbeamIO.getAvailableParts, data.ioCtx)
    if ok and type(result) == 'table' then available = result end
  end
  local parentNames, seen, slotInfo, declarations = {}, {}, {}, {}
  for _, map in ipairs({current, registered}) do
    for _, name in pairs(map) do
      if not seen[name] then parentNames[#parentNames + 1], seen[name] = name, true end
    end
  end
  table.sort(parentNames)
  for _, name in ipairs(parentNames) do
    local info = available[name]
    local definition = info
    if data and data.ioCtx and jbeamIO and type(jbeamIO.getPart) == 'function' then
      local ok, parent = pcall(jbeamIO.getPart, data.ioCtx, name)
      if ok and type(parent) == 'table' then definition = parent end
    end
    local slots = type(definition) == 'table' and definition.slotInfoUi or type(info) == 'table' and info.slotInfoUi
    if slots then for slot, info in pairs(slots) do if not slotInfo[slot] then slotInfo[slot] = info end end end
    declarations[name] = {}
    if slots then for slot in pairs(slots) do declarations[name][slot] = true end end
    for _, slot in pairs(type(definition) == 'table' and definition.slots or {}) do
      if type(slot) == 'table' then
        local id = slot.type or slot.slotType or slot[1]
        if type(id) == 'string' and id ~= 'type' then declarations[name][id] = true end
      end
    end
  end
  local parents, roots, slotIds = {}, {}, {}
  local function treeParents(config)
    if type(config) == 'string' then
      local ok, decoded = pcall(deserialize, config)
      config = ok and decoded or nil
    end
    local root = type(config) == 'table' and config.partsTree
    if type(root) ~= 'table' then return end
    local function walk(node, parent, isRoot)
      if type(node) ~= 'table' or type(node.id) ~= 'string' or type(node.path) ~= 'string' then return end
      local key = node.path
      slotIds[key] = node.id
      if isRoot then roots[key] = true elseif parent and not parents[key] then parents[key] = parent end
      for _, child in pairs(node.children or {}) do walk(child, key, false) end
    end
    walk(root, nil, true)
  end
  treeParents(data and data.config or vehicle and vehicle.partConfig)
  treeParents(entrant.config)
  for _, map in ipairs({current, registered}) do
    local installedSlots = {}
    for slot in pairs(map) do installedSlots[#installedSlots + 1] = slot end
    table.sort(installedSlots)
    for _, parent in ipairs(installedSlots) do
      for child in pairs(declarations[map[parent]] or {}) do
        if child ~= parent and not parents[child] then parents[child] = parent end
      end
    end
  end
  for index = #changes, 1, -1 do
    if roots[changes[index].slot] then table.remove(changes, index) end
  end
  local changed = {}
  for _, change in ipairs(changes) do changed[change.slot] = true end
  for _, change in ipairs(changes) do
    for _, part in ipairs({change.registered or false, change.current or false}) do
      if part then
        part.label = descriptionText(available[part.name], part.label)
      end
    end
    change.slotLabel = descriptionText(slotInfo[slotIds[change.slot] or change.slot], change.slotLabel)
    change.ancestors = {}
    local parent, visited = parents[change.slot], {[change.slot] = true}
    while parent and not visited[parent] do
      visited[parent] = true
      if not roots[parent] and parents[parent] then
        table.insert(change.ancestors, 1, {slot = parent, label = descriptionText(slotInfo[slotIds[parent] or parent], humanize(slotIds[parent] or parent)), changed = changed[parent] or false})
      end
      parent = parents[parent]
    end
  end
  table.sort(changes, function(left, right)
    local function key(change)
      local segments = {}
      for _, ancestor in ipairs(change.ancestors) do segments[#segments + 1] = ancestor.label:lower() .. '\0' .. ancestor.slot end
      segments[#segments + 1] = change.slotLabel:lower() .. '\0' .. change.slot
      return table.concat(segments, '\1')
    end
    return key(left) < key(right)
  end)
  return changes
end

function M.matchesVehicle(entrant, vehicle)
  if not matchesIdentity(entrant, vehicle) then return false end
  local entered, enteredTree = parts(entrant.config)
  if not entered then
    if enteredTree then return false end
    return type(entrant.config) == 'string' and vehicle.partConfig == entrant.config
  end
  local manager = core_vehicle_manager
  local current
  if manager and type(manager.getVehicleData) == 'function' then
    local ok, data = pcall(manager.getVehicleData, vehicle:getID())
    if ok and type(data) == 'table' then
      local currentTree
      current, currentTree = parts(data.config)
      if currentTree and not current then return false end
    end
  end
  current = current or parts(vehicle.partConfig)
  return current ~= nil and equal(entered, current)
end

function M.mismatchReason(entrant, vehicle)
  if M.matchesVehicle(entrant, vehicle) then return nil, nil end
  if not vehicle then return 'Enter your registered car to start your pass.', 'registered_vehicle_missing' end
  if not matchesIdentity(entrant, vehicle) then
    return 'Enter the car you registered for this event to start your pass.', 'wrong_registered_vehicle'
  end
  return "This car's installed parts changed after registration. Restore the registered parts to start your pass. Tuning and paint changes are allowed.", 'configuration_changed'
end

function M.playerDial(vehicleId)
  local hash = gameplay_drag_saveSystem.generateHashFromFile(vehicleId)
  local saved = (gameplay_drag_saveSystem.getDialTimes() or {})[hash]
  local details = core_vehicles.getVehicleDetails(vehicleId)
  local times = details and details.configs and details.configs['Drag Times']
  local dial = tonumber(saved and saved.time_1_4)
  if not dial or dial <= 0 then dial = tonumber(times and times.time_1_4) end
  return dial and dial > 0 and dial or 10
end

function M.create(count)
  local vehicleId = be:getPlayerVehicleID(0)
  local vehicle = be:getObjectByID(vehicleId)
  if not vehicle then return nil, 'Enter your race car first.' end
  local dial = M.playerDial(vehicleId)
  local ok, pool = pcall(gameplay_drag_dragBridge.generateOpponentsGroup, vehicleId, dial, {}, count - 1, 0.35)
  if not ok then
    local details = core_vehicles.getVehicleDetails(vehicleId)
    local config = details and details.configs
    if not config or not config.key then return nil, 'This car needs a saved configuration to generate the AI field.' end
    pool = {}
    for i = 1, count - 1 do pool[i] = {model = vehicle.JBeam, config = config.key} end
  end
  if type(pool) ~= 'table' or #pool ~= count - 1 then return nil, 'Could not generate the AI field for this car.' end
  local entrants = {{id = 'entrant-1', number = 1, name = 'You', player = true,
    model = vehicle.JBeam, config = vehicle.partConfig, configLabel = 'Entered configuration', dial = dial}}
  for i, spec in ipairs(pool) do
    if not spec.model or not spec.config then return nil, 'Opponent config is missing.' end
    entrants[#entrants + 1] = {id = 'entrant-' .. (i + 1), number = i + 1,
      name = 'Driver ' .. (i + 1), model = spec.model, config = spec.config, dial = dial}
  end
  return entrants
end

function M.find(entrants, id)
  for _, entrant in ipairs(entrants) do if entrant.id == id then return entrant end end
end

return M
