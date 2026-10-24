-- Import vehicle part topology and loose inventory into the 0.40 layout.
-- Map: tree preparation, metadata rewrites, installed migration phases, loose parts, public API.
local M = {}
local rules = require("overhaul/lib/save/partMigration040/rules")
local unpack = unpack or table.unpack

-- State ---------------------------------------------------------------------------------------------

local warn = nil

-- Shared helpers ------------------------------------------------------------------------------------

local function partMigrationWarning(message)
  if warn then warn(message) end
end

local function sortedKeys(tbl)
  local keys = {}
  for key in pairs(tbl or {}) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  return keys
end

local function matchesModel(rule, model)
  return rule == "*" or ("|" .. rule .. "|"):find("|" .. tostring(model) .. "|", 1, true) ~= nil
end

local function contains(values, value)
  for _, candidate in ipairs(values or {}) do
    if candidate == value then return true end
  end
  return false
end

local function startsWith(value, prefix)
  return type(value) == "string" and value:sub(1, #prefix) == prefix
end

local function partReplacement040(name, model)
  local replacement = rules.partRenames[name]
  if not replacement then return nil end
  local prefix = name:match("^([^_]+)_")
  if prefix == "vintage" or prefix == model or (prefix == "schoolbus" and model == "md_series")
    or (prefix == "us" and model == "us_semi") then return replacement end
end

local function walkParts(node, fn, parent, slot, nodePath)
  if type(node) ~= "table" then return end
  node.path = nodePath or "/"
  node.partPath = node.path .. (node.chosenPartName or "")
  fn(node, parent, slot)
  for _, childSlot in ipairs(sortedKeys(node.children)) do
    walkParts(node.children[childSlot], fn, node, childSlot, node.path .. childSlot .. "/")
  end
end

-- Tree preparation ----------------------------------------------------------------------------------

local function insertFlatPart(root, metadataOnly, parts, slotPath, name, historical)
  if type(slotPath) ~= "string" or slotPath:sub(-1) ~= "/" then return end
  local node = root
  for slot in slotPath:gmatch("([^/]+)/") do
    node.children = node.children or {}
    if not node.children[slot] then
      node.children[slot] = {chosenPartName = parts[slot] or "", children = {}}
      metadataOnly[node.children[slot]] = true
    end
    node = node.children[slot]
    if not historical then metadataOnly[node] = false end
  end
  if name then node.chosenPartName = name end
end

local function prepareMigrationPartsTree(vehicle, inventory, conditions, parts, id, root, hasTree)
  local metadataOnly = {}
  if not hasTree then
    -- Flat saves still carry their old topology in the condition and inventory paths.
    root = {chosenPartName = vehicle.model, children = {}}
    for _, key in ipairs(sortedKeys(vehicle.originalParts)) do
      local part = vehicle.originalParts[key]
      insertFlatPart(root, metadataOnly, parts, key, type(part) == "table" and part.name or nil, true)
    end
    local conditionSlots = {}
    for key in pairs(conditions) do
      local slotPath, name = key:match("^(.*)/([^/]+)$")
      if slotPath then
        insertFlatPart(root, metadataOnly, parts, slotPath .. "/", name)
        conditionSlots[slotPath:match("([^/]+)$") or ""] = true
      end
    end
    for _, part in pairs(inventory) do
      if type(part) == "table" and tonumber(part.location) == id then
        local slot = type(part.containingSlot) == "string" and part.containingSlot:match("([^/]+)/$")
        if not conditionSlots[slot] then insertFlatPart(root, metadataOnly, parts, part.containingSlot, part.name) end
      end
    end
    local installedSlots = {}
    walkParts(root, function(node, _, slot)
      if slot and not metadataOnly[node] then installedSlots[slot] = true end
    end)
    walkParts(root, function(node, _, slot)
      if slot and parts[slot] ~= nil then
        node.chosenPartName = parts[slot]
        if not installedSlots[slot] then metadataOnly[node] = false end
      end
    end)
    local seen = {}
    walkParts(root, function(_, _, slot) if slot then seen[slot] = true end end)
    for slot, name in pairs(parts) do
      if not seen[slot] then root.children[slot] = {chosenPartName = name, children = {}} end
    end
  end
  return root, metadataOnly
end

-- Metadata rewrites ---------------------------------------------------------------------------------

local function rewriteMigrationPartPaths(migration, oldPath, newPath, exact)
  local vehicle, inventory, conditions, id = migration.vehicle, migration.inventory, migration.conditions, migration.id
  local function rewrite(value)
    if (exact and value == oldPath) or (not exact and startsWith(value, oldPath)) then
      return newPath .. value:sub(#oldPath + 1)
    end
    return value
  end
  for _, tbl in ipairs({conditions, vehicle.originalParts or {}, vehicle.changedSlots or {}}) do
    for _, key in ipairs(sortedKeys(tbl)) do
      local newKey = rewrite(key)
      if newKey ~= key then
        if tbl[newKey] ~= nil then
          partMigrationWarning("Keeping conflicting migration metadata at " .. key)
        else
          tbl[newKey], tbl[key] = tbl[key], nil
        end
      end
    end
  end
  for _, part in pairs(inventory) do
    if type(part) == "table" and tonumber(part.location) == id then
      part.partPath = rewrite(part.partPath)
      part.containingSlot = rewrite(part.containingSlot)
    end
  end
end

local function detachMigratedPartToInventory(migration, walkInstalled, node, parent, slot, reason)
  local vehicle, inventory, conditions, parts = migration.vehicle, migration.inventory, migration.conditions, migration.parts
  local id, metadataOnly = migration.id, migration.metadataOnly
  if metadataOnly[node] then return end
  walkInstalled(node, function(child, _, childSlot)
    if child.chosenPartName and child.chosenPartName ~= "" then
      local found = false
      for _, key in ipairs(sortedKeys(inventory)) do
        local part = inventory[key]
        if type(part) == "table" and ((tonumber(part.location) == id and part.partPath == child.partPath)
          or (part.migrationSourceVehicle == id and part.migrationSourcePath == child.partPath)) then
          if tonumber(part.location) == id then part.partCondition = conditions[child.partPath] or part.partCondition end
          part.location = 0
          part.migrationSourceVehicle, part.migrationSourcePath = id, child.partPath
          found = true
          break
        end
      end
      if not found then
        for _, key in ipairs(sortedKeys(inventory)) do
          local part = inventory[key]
          if type(part) == "table" and tonumber(part.location) == 0 and part.vehicleModel == vehicle.model
            and part.name == child.chosenPartName and part.partPath == child.partPath then
            part.migrationSourceVehicle, part.migrationSourcePath = id, child.partPath
            found = true
            break
          end
        end
      end
      if not found then
        local original = vehicle.originalParts and vehicle.originalParts[child.path]
        local nextId = 1
        for key in pairs(inventory) do nextId = math.max(nextId, (tonumber(key) or 0) + 1) end
        inventory[nextId] = {name = child.chosenPartName, location = 0, vehicleModel = vehicle.model,
          containingSlot = child.path, partPath = child.partPath, mainPart = false, tags = {},
          migrationSourceVehicle = id, migrationSourcePath = child.partPath,
          value = type(original) == "table" and original.value or 0, year = vehicle.year,
          partCondition = conditions[child.partPath] or {integrityValue = 1, visualValue = 1, odometer = 0}}
      end
      partMigrationWarning("Kept " .. child.partPath .. " in loose part inventory: " .. reason)
    end
    conditions[child.partPath] = nil
    if vehicle.originalParts then vehicle.originalParts[child.path] = nil end
    if vehicle.changedSlots then vehicle.changedSlots[child.path] = nil end
    local currentSlot = childSlot or slot
    if parts[currentSlot] == child.chosenPartName then parts[currentSlot] = nil end
  end, parent, slot, node.path)
  parent.children[slot] = nil
end

local function moveMigratedSeats(vehicle, snapshot, metadataOnly, move)
  for _, row in ipairs(snapshot()) do
    local node = row[1]
    for _, seatSlot in ipairs(sortedKeys(rules.seatMoves[vehicle.model])) do
      local seat = node.children and node.children[seatSlot]
      if seat then
        for _, parentSlot in ipairs(rules.seatMoves[vehicle.model][seatSlot]) do
          local target = node.children[parentSlot]
          if target and not metadataOnly[target] and target.chosenPartName ~= "" then
            move(seat, node, seatSlot, target, seatSlot)
            break
          end
        end
      end
    end
  end
end

local function moveMigratedRollCages(vehicle, snapshot, metadataOnly, move, detach)
  for _, row in ipairs(snapshot()) do
    local cage, parent, slot = unpack(row)
    local rule = rules.cageMoves[vehicle.model] and rules.cageMoves[vehicle.model][slot]
    if rule and parent and parent.children[slot] == cage then
      local target = nil
      for _, host in ipairs(rule.hosts) do
        if parent.children[host] then target = parent.children[host] break end
      end
      if target and not metadataOnly[target] and target.chosenPartName ~= "" then
        move(cage, parent, slot, target, rule.slot)
      else
        detach(cage, parent, slot, "roll cage dashboard host is unavailable")
      end
    end
  end
end

-- Installed migration phases ------------------------------------------------------------------------

local function prepareVehicleMigration(vehicle, inventory)
  local config = vehicle.config
  if type(config) ~= "table" then return nil end
  local id = tonumber(vehicle.id)
  local conditions = vehicle.partConditions
  local serializedConditions = type(conditions) == "string"
  if serializedConditions then
    conditions = deserialize(conditions)
    if type(conditions) ~= "table" then error("Unreadable conditions for vehicle " .. tostring(id)) end
  end
  conditions = type(conditions) == "table" and conditions or {}
  local parts = type(config.parts) == "table" and config.parts or {}
  local root = config.partsTree
  local hasTree = type(root) == "table"
  local metadataOnly = nil
  root, metadataOnly = prepareMigrationPartsTree(vehicle, inventory, conditions, parts, id, root, hasTree)

  return {vehicle = vehicle, inventory = inventory, conditions = conditions, parts = parts,
    id = id, metadataOnly = metadataOnly, root = root, config = config,
    hasTree = hasTree, serializedConditions = serializedConditions, changed = false}
end

local function walkInstalled(migration, node, fn, parent, slot, nodePath)
  local metadataOnly = migration.metadataOnly
  if metadataOnly[node] then return end
  node.path = nodePath or "/"
  node.partPath = node.path .. (node.chosenPartName or "")
  fn(node, parent, slot)
  -- Empty parents block descendants even when stale metadata claims installation.
  if node.chosenPartName == "" then return end
  for _, childSlot in ipairs(sortedKeys(node.children)) do
    walkInstalled(migration, node.children[childSlot], fn, node, childSlot, node.path .. childSlot .. "/")
  end
end

local function rewritePaths(migration, oldPath, newPath, exact)
  rewriteMigrationPartPaths(migration, oldPath, newPath, exact)
  migration.changed = true
end

local function renamePart(migration, node, name)
  local metadataOnly, inventory, id, vehicle = migration.metadataOnly, migration.inventory, migration.id, migration.vehicle
  if metadataOnly[node] then return end
  local oldPath, oldName = node.partPath, node.chosenPartName
  if oldName == name then return end
  rewritePaths(migration, oldPath, node.path .. name, true)
  for _, part in pairs(inventory) do
    if type(part) == "table" and tonumber(part.location) == id and part.containingSlot == node.path and part.name == oldName then
      part.name = name
    end
  end
  local original = vehicle.originalParts and vehicle.originalParts[node.path]
  if type(original) == "table" and original.name == oldName then original.name = name end
  node.chosenPartName, node.partPath = name, node.path .. name
end

local function detach(migration, node, parent, slot, reason)
  local metadataOnly = migration.metadataOnly
  if metadataOnly[node] then return end
  detachMigratedPartToInventory(migration, function(...) return walkInstalled(migration, ...) end, node, parent, slot, reason)
  migration.changed = true
end

local function move(migration, node, parent, slot, target, newSlot)
  local metadataOnly, config, parts, root = migration.metadataOnly, migration.config, migration.parts, migration.root
  if metadataOnly[node] then return false end
  if parent == target and slot == newSlot then return false end
  target.children = target.children or {}
  local existing = target.children[newSlot]
  if existing and not metadataOnly[existing] and existing ~= node and existing.chosenPartName ~= "" then
    detach(migration, node, parent, slot, "destination slot is occupied")
    if config.parts then parts[newSlot] = existing.chosenPartName end
    return false
  end
  local oldPath = node.path
  parent.children[slot] = nil
  target.children[newSlot] = node
  rewritePaths(migration, oldPath, target.path .. newSlot .. "/")
  walkParts(root, function() end)
  if newSlot ~= slot and parts[slot] ~= nil then
    parts[newSlot], parts[slot] = node.chosenPartName, nil
  end
  return true
end

local function snapshot(migration)
  local root = migration.root
  local nodes = {}
  walkInstalled(migration, root, function(node, parent, slot) nodes[#nodes + 1] = {node, parent, slot} end)
  return nodes
end

local function newSlotParent(rule, nodes, parent)
  if not rule.newParentSlot then return parent end
  local target = nil
  for _, candidate in ipairs(nodes) do
    if candidate[3] == rule.newParentSlot and candidate[1].chosenPartName ~= "" then
      if target then return nil end
      target = candidate[1]
    end
  end
  return target
end

local function renamedSlotValue(migration, rule, node, parent)
  local name = rule.valueMap and rule.valueMap[node.chosenPartName]
  if rule.valueMapWhenParentIsUte and (contains(rule.uteBodies, parent.chosenPartName)
    or (not migration.hasTree and contains(rule.uteBodies, migration.parts.miramar_body))) then
    name = rule.valueMapWhenParentIsUte[node.chosenPartName]
  end
  if rule.valuePattern then
    local suffix = node.chosenPartName:match(rule.valuePattern[1])
    if suffix then name = string.format(rule.valuePattern[2], suffix) end
  end
  return name
end

local function migrateInstalledSlot(migration, rule, nodes, row)
  local node, parent, slot = unpack(row)
  if not parent or parent.children[slot] ~= node then return end
  if slot ~= rule.oldSlot and not (rule.oldSlotPattern and slot:match(rule.oldSlotPattern)) then return end
  if rule.onlyWhenParentPart and not contains(rule.onlyWhenParentPart, parent.chosenPartName) then return end
  local target = newSlotParent(rule, nodes, parent)
  if not target then
    detach(migration, node, parent, slot, "new parent is unavailable or ambiguous")
    return
  end
  if not move(migration, node, parent, slot, target, rule.newSlot) then return end
  local name = renamedSlotValue(migration, rule, node, parent)
  if name then renamePart(migration, node, name) end
  if migration.parts[rule.newSlot] ~= nil then migration.parts[rule.newSlot] = node.chosenPartName end
end

local function migrateInstalledSlots(migration)
  for _, rule in ipairs(rules.slotRenames) do
    if matchesModel(rule.model, migration.vehicle.model) then
      local nodes = snapshot(migration)
      for _, row in ipairs(nodes) do migrateInstalledSlot(migration, rule, nodes, row) end
    end
  end
end

local function migrateInstalledNames(migration)
  local vehicle, parts, hasTree, root, metadataOnly = migration.vehicle, migration.parts, migration.hasTree, migration.root, migration.metadataOnly
  for _, row in ipairs(snapshot(migration)) do
    local node, parent, slot = unpack(row)
    if parent and parent.children[slot] == node then
      for _, rule in ipairs(rules.colorSeats) do
        if slot == rule.slot and node.chosenPartName == rule.oldPart then
          local skin = node.children and node.children[rule.skinSlot]
          local skinParent = node
          if not skin and not hasTree and root.children[rule.skinSlot] then
            skin, skinParent = root.children[rule.skinSlot], root
          end
          if skin and (metadataOnly[skin] or skin.chosenPartName == "") then skin = nil end
          local skinName = skin and skin.chosenPartName
          local pattern = rule.skinPattern or ("^" .. rule.skinSlot .. "_(%w+)$")
          local color = type(skinName) == "string" and skinName:match(pattern)
          local name = contains(rule.colors, color) and string.format(rule.newPattern, color) or rule.fallback
          if color and not contains(rule.colors, color) then partMigrationWarning("Unknown seat colour " .. color .. "; using " .. name) end
          renamePart(migration, node, name)
          if parts[slot] ~= nil then parts[slot] = name end
          if skin then detach(migration, skin, skinParent, rule.skinSlot, "colour is now included in the seat") end
          parts[rule.skinSlot] = nil
        end
      end
      local name = partReplacement040(node.chosenPartName, vehicle.model)
      if name == "" then
        detach(migration, node, parent, slot, "part was removed in 0.40")
      elseif name then
        renamePart(migration, node, name)
        if parts[slot] ~= nil then parts[slot] = name end
      end
    end
  end
end

local function migrateInstalledCargoLoad(migration, node, spaceSlot, rule, loadSlot)
  local config, parts, metadataOnly = migration.config, migration.parts, migration.metadataOnly
  local load = node.children and node.children[loadSlot]
  if not load or metadataOnly[load] then return end
  if load.chosenPartName == "" then
    detach(migration, load, node, loadSlot, "empty cargo slot")
    return
  end
  local target = node.children[spaceSlot]
  if target and metadataOnly[target] then target = nil end
  if target and target.chosenPartName ~= rule.cargoPart then
    detach(migration, load, node, loadSlot, "rear space slot is occupied")
    return
  end
  target = target or {chosenPartName = rule.cargoPart, children = {}, path = node.path .. spaceSlot .. "/"}
  node.children[spaceSlot] = target
  move(migration, load, node, loadSlot, target, loadSlot)
  if config.parts then parts[spaceSlot] = rule.cargoPart end
end

local function migrateInstalledCargo(migration)
  for _, row in ipairs(snapshot(migration)) do
    local node, _, slot = unpack(row)
    for _, spaceSlot in ipairs(sortedKeys(rules.cargoMoves)) do
      local rule = rules.cargoMoves[spaceSlot]
      if contains(rule.hostSlotType, slot) and node.chosenPartName ~= "" and node.chosenPartName ~= "covet_junk_seats_R" and node.chosenPartName ~= "pessima_junk_seats_R" then
        for _, loadSlot in ipairs({"load_seat_R", "load_seat_R_2", "load_seat_R_3", "load_seat_RR"}) do
          migrateInstalledCargoLoad(migration, node, spaceSlot, rule, loadSlot)
        end
      end
    end
  end
end

local function migrateConditionalNames(migration)
  local vehicle, parts = migration.vehicle, migration.parts
  for _, row in ipairs(snapshot(migration)) do
    local node, parent, slot = unpack(row)
    for _, rule in ipairs(rules.conditionalRenames) do
      if vehicle.model == rule.model and slot == rule.slot and parent.chosenPartName == rule.parentPart and node.chosenPartName == rule.old then
        renamePart(migration, node, rule.new)
        if parts[slot] ~= nil then parts[slot] = rule.new end
      end
    end
  end
end

local function migrateVehicleParts040(vehicle, inventory)
  local migration = prepareVehicleMigration(vehicle, inventory)
  if not migration then return false end
  migrateInstalledSlots(migration)
  migrateInstalledNames(migration)
  moveMigratedSeats(vehicle, function() return snapshot(migration) end, migration.metadataOnly,
    function(...) return move(migration, ...) end)
  moveMigratedRollCages(vehicle, function() return snapshot(migration) end, migration.metadataOnly,
    function(...) return move(migration, ...) end, function(...) return detach(migration, ...) end)
  migrateInstalledCargo(migration)
  migrateConditionalNames(migration)
  if migration.changed then
    if migration.serializedConditions then vehicle.partConditions = serialize(migration.conditions) end
    if migration.hasTree then walkParts(migration.root, function() end) end
  end
  return migration.changed
end

-- Loose parts ---------------------------------------------------------------------------------------

local function migrateLooseParts040(inventory)
  local looseBySlot = {}
  for _, part in pairs(inventory) do
    if type(part) == "table" and tonumber(part.location) == 0 and part.containingSlot then
      looseBySlot[tostring(part.vehicleModel) .. part.containingSlot] = part.name
    end
  end
  for _, part in pairs(inventory) do
    if type(part) == "table" and tonumber(part.location) == 0 then
      for _, rule in ipairs(rules.slotRenames) do
        if matchesModel(rule.model, part.vehicleModel) and type(part.containingSlot) == "string" then
          local parentPath, slot = part.containingSlot:match("^(.*)/([^/]+)/$")
          local parentName = parentPath and looseBySlot[tostring(part.vehicleModel) .. parentPath .. "/"]
          if parentPath and (slot == rule.oldSlot or (rule.oldSlotPattern and slot:match(rule.oldSlotPattern)))
            and (not rule.onlyWhenParentPart or contains(rule.onlyWhenParentPart, parentName)) then
            local name = rule.valueMap and rule.valueMap[part.name]
            if rule.valuePattern then
              local suffix = part.name:match(rule.valuePattern[1])
              if suffix then name = string.format(rule.valuePattern[2], suffix) end
            end
            part.name = name or part.name
            part.containingSlot = parentPath .. "/" .. rule.newSlot .. "/"
            part.partPath = part.containingSlot .. part.name
          end
        end
      end
      local name = partReplacement040(part.name, part.vehicleModel)
      for _, rule in ipairs(rules.colorSeats) do
        if part.name == rule.oldPart then
          local skin = looseBySlot[tostring(part.vehicleModel) .. tostring(part.containingSlot) .. rule.skinSlot .. "/"]
          local color = skin and skin:match(rule.skinPattern or ("^" .. rule.skinSlot .. "_(%w+)$"))
          name = contains(rule.colors, color) and string.format(rule.newPattern, color) or rule.fallback
          if not contains(rule.colors, color) then partMigrationWarning("Loose seat " .. part.name .. " has no supported colour skin; using " .. name) end
        end
      end
      if name and name ~= "" then
        if type(part.partPath) == "string" and type(part.containingSlot) == "string" then
          part.partPath = part.containingSlot .. name
        end
        part.name = name
      end
    end
    if type(part) == "table" and type(part.name) == "string" then
      if part.name:match("^seat_race_") then part.slotType = "racing_seat" end
      if part.name:match("^seat_vintage_") and part.name ~= "seat_vintage_headrest" then part.slotType = "vintage_seat" end
    end
  end
end

-- Public API ----------------------------------------------------------------------------------------

function M.migrateVehicleParts040(vehicle, inventory, onWarning)
  warn = onWarning
  return migrateVehicleParts040(vehicle, inventory)
end

function M.migrateLooseParts040(inventory, onWarning)
  warn = onWarning
  return migrateLooseParts040(inventory)
end

return M
