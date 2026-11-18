-- Exact retired-blower content migration, separate from the 0.40 topology pass.
-- Plans on copies. Splits the formerly integral pulley from the owned assembly,
-- conserving its value and condition. Conflicting/malformed data refuses writes.
-- Map: pulley selection, asset splitting, vehicle migration, copy planning, saved-data readers and preservation.
local M = {version = 2, packagePath = '/career/rls_career/enginePackages.json'}
local serializedTable = require('overhaul/lib/save/serializedTable')
local data = require('overhaul/lib/save/superchargerMigrationData')

local function finite(n)
  return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

local function keys(t)
  local result = {}
  if type(t) ~= 'table' then return result end
  for k in pairs(t or {}) do result[#result + 1] = k end
  table.sort(result, function(a, b) return tostring(a) < tostring(b) end)
  return result
end

local function number(expression, entry, vars)
  if finite(expression) then return expression end
  local spec = entry.variables[expression]
  if not spec then return nil, 'unsupported-control' end
  local v = vars and vars[expression]
  if v == nil then v = spec.default end
  if not finite(v) then return nil, 'invalid-control:' .. expression end
  return math.min(spec.max, math.max(spec.min, v))
end

local function isPulley(family, name)
  for _, p in ipairs(family.ratios) do if p.id == name then return true end end
  return false
end

-- The reviewed Wendover method: minimize relative unpulsed coefficient error
-- across 2500..reference limiter, including rotor loss and native efficiency.
-- Pressure slope is never used as gearRatio. This is not an ET prediction.
local function coefficient(family, ratio, slope, rpm)
  local rotor = rpm * ratio
  local endpoint = math.ceil(family.referenceRPM * ratio)
  local lookup = math.min(math.floor(rotor), endpoint)
  local efficiency = 1 + (family.twisted and -0.35 or -0.55) * (lookup / endpoint)^2
  local pressure = math.max(efficiency * slope * 0.001 * lookup, 0)
  return math.max(1 + 0.0000087 * 6894.757293178 * pressure - family.loss * 0.001 * rotor, 0)
end

function M.choosePulley(oldID, vars, existing)
  local entry = data.entries[oldID]
  if not entry then return nil, 'not-retired' end
  local family = data.families[entry.slot]
  if vars ~= nil and type(vars) ~= 'table' then return nil, 'unreadable-controls' end
  if existing and existing ~= '' then
    if isPulley(family, existing) then return existing end
    return nil, 'incompatible-existing-pulley'
  end
  if entry.policy == 'blocked' then return nil, 'unreviewed-transfer:' .. oldID end
  if entry.policy == 'reviewed-fixed' then return entry.pulley end
  if vars ~= nil and type(vars) ~= 'table' then return nil, 'unreadable-controls' end
  local ratio, err = number(entry.ratio, entry, vars)
  if not ratio then return nil, err end
  local slope
  slope, err = number(entry.slope, entry, vars)
  if not slope then return nil, err end
  local best, bestError
  for _, candidate in ipairs(family.ratios) do
    local score = math.abs(candidate.ratio - ratio)
    if entry.policy == 'relative-coefficient-rms' then
      score = 0
      for rpm = 2500, family.referenceRPM do
        local old = coefficient(family, ratio, slope, rpm)
        local new = coefficient(family, candidate.ratio, family.slope, rpm)
        score = score + ((new - old) / math.max(old, 1e-12))^2
      end
    end
    -- Family ratios are ascending; ties retain the lower drive ratio.
    if not bestError or score < bestError - 1e-12 then best, bestError = candidate.id, score end
  end
  return best
end

local function treeNodes(node, path, result, disabled)
  if type(node) ~= 'table' then return end
  local name = node.chosenPartName
  local retired = data.entries[name]
  if retired then result[#result + 1] = {node = node, path = path, oldID = name, disabled = disabled} end
  disabled = disabled or name == ''
  for _, slot in ipairs(keys(node.children)) do treeNodes(node.children[slot], path .. slot .. '/', result, disabled) end
end

local function fail(issues, code, subject)
  issues[#issues + 1] = {code = code, subject = subject}
end

local function renameKey(tbl, from, to, issues, subject)
  if type(tbl) ~= 'table' or tbl[from] == nil or from == to then return end
  if tbl[to] ~= nil then fail(issues, 'metadata-key-conflict', subject .. ':' .. to); return end
  tbl[to], tbl[from] = tbl[from], nil
end

local function pulleyRatio(family, choice)
  for _, p in ipairs(family.ratios) do if p.id == choice then return p.ratio end end
end

local function validAsset(base, issues, subject)
  if not finite(base.value) or base.value < 0 then fail(issues, 'invalid-asset-value', subject); return false end
  if not finite(base.location) or base.location < 0 or base.location ~= math.floor(base.location) then fail(issues, 'invalid-asset-location', subject); return false end
  if type(base.partCondition) ~= 'table' then fail(issues, 'missing-asset-condition', subject); return false end
  if base.rlsSuperchargerMigration ~= nil then fail(issues, 'existing-migration-receipt', subject); return false end
  return true
end

-- Native inventory allocates the first free positive integer. Stable iteration
-- and renaming the base make repeated planning/reloading idempotent; receipts
-- preserve both row identities without imposing a new installation protocol.
local function splitAsset(inventory, baseKey, base, oldID, choice, vars, childPath, issues, reservedIDs)
  local entry = data.entries[oldID]
  local family = data.families[entry.slot]
  local childKey = 1
  -- Incomplete personal packages can retain missing row IDs. Native package
  -- loading claims rows by ID, so these references must not acquire a new pulley.
  while inventory[childKey] ~= nil or inventory[tostring(childKey)] ~= nil
    or (reservedIDs and reservedIDs[childKey]) do childKey = childKey + 1 end
  local child = deepcopy(base)
  local originalValue = base.value
  child.value = math.min(500, originalValue)
  base.value = originalValue - child.value
  child.name, child.containingSlot, child.partPath = choice, childPath, childPath and childPath .. choice
  child.mainPart = base.enginePackageId ~= nil
  child.description = nil
  if child.id ~= nil then child.id = childKey end
  if child.partId ~= nil then child.partId = childKey end
  local requestedRatio = number(entry.ratio, entry, vars)
  local requestedSlope = number(entry.slope, entry, vars)
  local receipt = {version = M.version, oldID = oldID, basePartId = baseKey, childPartId = childKey,
    oldValue = originalValue, childValue = child.value, requestedRatio = requestedRatio,
    requestedPressureSlope = requestedSlope, requestedVars = deepcopy(vars or {}),
    controlSource = vars and 'saved-controls-with-defaults' or 'legacy-defaults',
    selectedPulley = choice, ratio = pulleyRatio(family, choice), policy = entry.policy,
    splitApplied = true, role = 'core'}
  base.rlsSuperchargerMigration = receipt
  child.rlsSuperchargerMigration = deepcopy(receipt)
  child.rlsSuperchargerMigration.role = 'pulley'
  inventory[childKey] = child
  return child, childKey
end

local function splitOriginal(vehicle, path, newPath, oldID, family, choice, issues, subject)
  local originals = vehicle.originalParts
  if type(originals) ~= 'table' then return end
  local original = originals[path] or originals[newPath]
  if type(original) ~= 'table' or original.name ~= oldID then return end
  local childPath = path .. family.childSlot .. '/'
  if originals[childPath] ~= nil then fail(issues, 'original-pulley-conflict', subject); return end
  if not finite(original.value) or original.value < 0 then fail(issues, 'invalid-original-value', subject); return end
  local child = deepcopy(original)
  child.name, child.value = choice, math.min(500, original.value)
  original.value = original.value - child.value
  originals[childPath] = child
end

local function migrateVehicle(vehicle, inventory, issues, result, reservedIDs)
  if type(vehicle) ~= 'table' then fail(issues, 'unreadable-vehicle', 'vehicle list'); return end
  local config = vehicle.config
  if type(config) ~= 'table' then return end
  local parts = config.parts
  local function validTree(node)
    if type(node) ~= 'table' or (node.children ~= nil and type(node.children) ~= 'table') then return false end
    for slot, child in pairs(node.children or {}) do
      if type(slot) ~= 'string' or not validTree(child) then return false end
    end
    return true
  end
  if config.partsTree ~= nil and not validTree(config.partsTree) then fail(issues, 'malformed-parts-tree', tostring(vehicle.id)); return end
  local nodes, bySlot = {}, {}
  treeNodes(config.partsTree, '/', nodes)
  for _, row in ipairs(nodes) do
    local slot = row.path:match('([^/]+)/$')
    local entry = data.entries[row.oldID]
    if row.disabled or slot ~= entry.slot or bySlot[slot] then
      fail(issues, 'ambiguous-or-inactive-tree', tostring(vehicle.id) .. ':' .. row.oldID)
    else bySlot[slot] = row end
  end
  for slot, name in pairs(type(parts) == 'table' and parts or {}) do
    local entry = data.entries[name]
    if entry then
      if entry.slot ~= slot then fail(issues, 'wrong-native-slot', tostring(vehicle.id) .. ':' .. slot)
      elseif bySlot[slot] then
        if bySlot[slot].oldID ~= name then fail(issues, 'flat-tree-conflict', tostring(vehicle.id) .. ':' .. slot) end
      elseif config.partsTree then fail(issues, 'flat-tree-conflict', tostring(vehicle.id) .. ':' .. slot)
      else local row = {oldID = name}; nodes[#nodes + 1] = row; bySlot[slot] = row end
    end
  end
  if #nodes == 0 then return end
  if not tonumber(vehicle.id) or tonumber(vehicle.id) <= 0 then fail(issues, 'invalid-vehicle-id', tostring(vehicle.id)); return end
  for _, name in ipairs({'originalParts', 'changedSlots'}) do
    if vehicle[name] ~= nil and type(vehicle[name]) ~= 'table' then fail(issues, 'unreadable-metadata', tostring(vehicle.id) .. ':' .. name); return end
  end
  if parts ~= nil and type(parts) ~= 'table' then fail(issues, 'unreadable-flat-parts', tostring(vehicle.id)); return end
  local conditions = vehicle.partConditions
  local encoded = type(conditions) == 'string'
  if encoded then
    local ok, value = pcall(serializedTable.decode, conditions)
    if not ok or type(value) ~= 'table' then fail(issues, 'unreadable-conditions', tostring(vehicle.id)); return end
    conditions = value
  elseif conditions ~= nil and type(conditions) ~= 'table' then fail(issues, 'unreadable-conditions', tostring(vehicle.id)); return end
  conditions = conditions or {}
  for _, row in ipairs(nodes) do
    local entry, oldID = data.entries[row.oldID], row.oldID
    local family = data.families[entry.slot]
    local subject = tostring(vehicle.id) .. ':' .. oldID
    local countBefore = #issues
    if vehicle.model ~= entry.model then fail(issues, 'wrong-model', subject) end
    if parts and parts[entry.slot] ~= nil and parts[entry.slot] ~= oldID then fail(issues, 'flat-tree-conflict', subject) end
    local baseItems, baseKeys = {}, {}
    for _, key in ipairs(keys(inventory)) do
      local part = inventory[key]
      if type(part) == 'table' and tonumber(part.location) == tonumber(vehicle.id) and part.name == oldID then
        baseItems[#baseItems + 1] = part
        baseKeys[#baseKeys + 1] = key
      end
    end
    if #baseItems ~= 1 then fail(issues, 'ambiguous-or-missing-owned-base', subject) end
    local base = baseItems[1]
    local path = row.path or (base and base.containingSlot)
    if type(path) ~= 'string' or path:sub(-#entry.slot - 2) ~= '/' .. entry.slot .. '/' then
      fail(issues, 'missing-native-path', subject)
    elseif base and (base.containingSlot ~= path or base.partPath ~= path .. oldID or base.vehicleModel ~= entry.model) then
      fail(issues, 'inventory-path-conflict', subject)
    end
    if row.node and ((row.node.path ~= nil and row.node.path ~= path) or (row.node.partPath ~= nil and row.node.partPath ~= path .. oldID)) then
      fail(issues, 'tree-path-conflict', subject)
    end
    if base then validAsset(base, issues, subject) end
    local child = row.node and row.node.children and row.node.children[family.childSlot]
    local treeChoice = child and child.chosenPartName
    local flatChoice = parts and parts[family.childSlot]
    if treeChoice ~= nil and flatChoice ~= nil and treeChoice ~= flatChoice then fail(issues, 'pulley-flat-tree-conflict', subject) end
    local choice, err = M.choosePulley(oldID, config.vars, treeChoice or flatChoice)
    if not choice then fail(issues, err, subject) end
    local pulleyItems, pulleyKeys = {}, {}
    if type(path) == 'string' then
      for key, part in pairs(inventory) do
        if type(part) == 'table' and tonumber(part.location) == tonumber(vehicle.id)
          and part.containingSlot == path .. family.childSlot .. '/' then
          pulleyItems[#pulleyItems + 1], pulleyKeys[#pulleyKeys + 1] = part, key
        end
      end
    end
    if #pulleyItems > 1 then
      fail(issues, 'ambiguous-owned-pulley', subject)
    elseif #pulleyItems == 1 then
      local owned = pulleyItems[1]
      if not finite(owned.value) or owned.value < 0 or type(owned.partCondition) ~= 'table' then fail(issues, 'malformed-owned-pulley', subject) end
      if not choice or owned.name ~= choice or owned.vehicleModel ~= entry.model or owned.partPath ~= path .. family.childSlot .. '/' .. choice then
        fail(issues, 'owned-pulley-conflict', subject)
      end
    end
    if #issues == countBefore then
      local from, to = path .. oldID, path .. family.newID
      if conditions[from] ~= nil and type(conditions[from]) ~= 'table' then fail(issues, 'malformed-part-condition', subject) end
      renameKey(conditions, from, to, issues, subject)
      renameKey(vehicle.originalParts, from, to, issues, subject)
      renameKey(vehicle.changedSlots, from, to, issues, subject)
      if #pulleyItems == 0 then
        local childKey = path .. family.childSlot .. '/' .. choice
        if conditions[childKey] ~= nil then fail(issues, 'condition-without-owned-pulley', subject) end
        splitOriginal(vehicle, path, to, oldID, family, choice, issues, subject)
      end
      if #issues == countBefore then
        if conditions[to] == nil then conditions[to] = deepcopy(base.partCondition) end
        local owned, ownedKey = pulleyItems[1], pulleyKeys[1]
        if not owned then
          owned, ownedKey = splitAsset(inventory, baseKeys[1], base, oldID, choice, config.vars, path .. family.childSlot .. '/', issues, reservedIDs)
          conditions[owned.partPath] = deepcopy(conditions[to] or base.partCondition)
          if type(vehicle.changedSlots) == 'table' and vehicle.changedSlots[path] ~= nil then
            vehicle.changedSlots[owned.containingSlot] = type(vehicle.changedSlots[path]) == 'string' and choice or deepcopy(vehicle.changedSlots[path])
          end
        else
          -- An already-owned compatible pulley is reused without a second split.
          -- Both existing paid values still need protection from catalog refresh.
          local receipt = {version = M.version, oldID = oldID, basePartId = baseKeys[1], childPartId = ownedKey,
            oldValue = base.value, childValue = owned.value, requestedRatio = number(entry.ratio, entry, config.vars),
            requestedPressureSlope = number(entry.slope, entry, config.vars), requestedVars = deepcopy(config.vars or {}),
            selectedPulley = choice, ratio = pulleyRatio(family, choice), policy = 'existing-owned-pulley', splitApplied = false, role = 'core'}
          base.rlsSuperchargerMigration = receipt
          if owned.rlsSuperchargerMigration == nil then
            owned.rlsSuperchargerMigration = deepcopy(receipt)
            owned.rlsSuperchargerMigration.role = 'pulley'
          end
        end
        if row.node then
          row.node.chosenPartName = family.newID
          if row.node.partPath then row.node.partPath = to end
          row.node.children = row.node.children or {}
          child = child or {children = {}}
          child.chosenPartName, child.path, child.partPath = choice, path .. family.childSlot .. '/', path .. family.childSlot .. '/' .. choice
          row.node.children[family.childSlot] = child
        end
        if parts then parts[entry.slot], parts[family.childSlot] = family.newID, choice end
        base.name, base.partPath = family.newID, to
        for _, tbl in ipairs({vehicle.originalParts or {}, vehicle.changedSlots or {}}) do
          local original = tbl[path] or tbl[to]
          if type(original) == 'table' and original.name == oldID then original.name = family.newID end
          if original == oldID then if tbl[path] then tbl[path] = family.newID else tbl[to] = family.newID end end
        end
        -- Do not erase custom vars without proving all selected third-party consumers.
        -- New hardware never reads these vars; retention preserves player data.
        result.changes[#result.changes + 1] = {vehicleID = vehicle.id, oldID = oldID, newID = family.newID,
          basePartId = baseKeys[1], childPartId = ownedKey, pulley = choice,
          ratio = pulleyRatio(family, choice), retainedVars = deepcopy(config.vars or {}),
          receipt = deepcopy(base.rlsSuperchargerMigration)}
        result.changedVehicles[tostring(vehicle.id)] = true
      end
    end
  end
  vehicle.partConditions = encoded and serialize(conditions) or conditions
end

-- Package trees already provide the native parent/child ownership association.
-- Only personal rows in this inventory are eligible; business stores are separate.
local function packageIndex(packages, inventory, issues)
  local index, reservedIDs = {}, {}
  packages = packages or {packages = {}}
  if type(packages) ~= 'table' or type(packages.packages) ~= 'table' then
    fail(issues, 'unreadable-engine-packages', M.packagePath); return index
  end
  local function visit(node, package)
    if type(node) ~= 'table' then fail(issues, 'malformed-package-tree', tostring(package.id)); return end
    local key = tonumber(node.partId) or node.partId
    if key ~= nil then reservedIDs[key] = true end
    local part = key and inventory[key]
    if data.entries[node.name] or (type(part) == 'table' and data.entries[part.name]) then
      if not part or node.name ~= part.name or tostring(part.enginePackageId) ~= tostring(package.id) or index[key] then
        fail(issues, 'package-ownership-conflict', tostring(package.id) .. ':' .. tostring(key))
      else index[key] = {node = node, package = package} end
    end
    if node.children ~= nil and type(node.children) ~= 'table' then fail(issues, 'malformed-package-tree', tostring(package.id)); return end
    for _, child in pairs(node.children or {}) do visit(child, package) end
  end
  for _, package in ipairs(packages.packages) do
    if type(package) ~= 'table' then fail(issues, 'malformed-package', M.packagePath)
    elseif package.ownerType == nil or package.ownerType == 'personal' then visit(package.tree, package) end
  end
  for key, part in pairs(inventory) do
    if type(part) == 'table' and data.entries[part.name] and part.enginePackageId ~= nil and not index[key] then
      fail(issues, 'missing-package-owned-row', tostring(key))
    end
  end
  return index, reservedIDs
end

function M.plan(vehicles, inventory, packages)
  local result = {vehicles = deepcopy(vehicles), inventory = deepcopy(inventory), packages = deepcopy(packages), changes = {}, changedVehicles = {}}
  local issues = {}
  local packageRefs, reservedIDs = packageIndex(result.packages, result.inventory, issues)
  if #issues > 0 then return nil, issues end
  for _, vehicle in ipairs(result.vehicles) do migrateVehicle(vehicle, result.inventory, issues, result, reservedIDs) end
  for _, key in ipairs(keys(result.inventory)) do
    local part = result.inventory[key]
    if type(part) == 'table' and data.entries[part.name] then
      local oldID, entry, countBefore = part.name, data.entries[part.name], #issues
      local family = data.families[entry.slot]
      local subject = tostring(key) .. ':' .. oldID
      if tonumber(part.location) ~= 0 then fail(issues, 'unconverted-owned-part', subject)
      else
        if part.vehicleModel ~= entry.model then fail(issues, 'wrong-model', subject) end
        validAsset(part, issues, subject)
        local packageRef = packageRefs[key]
        local vars = packageRef and packageRef.package.tuning or part.vars
        local existing = packageRef and packageRef.node.children and packageRef.node.children[family.childSlot]
        local choice, err = M.choosePulley(oldID, vars, existing and existing.name)
        if not choice then fail(issues, err, subject) end
        if #issues == countBefore then
          -- Loose rows retain their last path in native storage; it is rewritten
          -- by the standard catalog when installed, never used to force pairing.
          local path = part.containingSlot
          if type(path) ~= 'string' or path:sub(-1) ~= '/' or part.partPath ~= path .. oldID then fail(issues, 'invalid-stored-path', subject)
          else
            if existing then fail(issues, 'conflicting-stored-package-pulley', subject) end
            local child, childKey = splitAsset(result.inventory, key, part, oldID, choice, vars, path and path .. family.childSlot .. '/', issues, reservedIDs)
            part.name, part.partPath = family.newID, path and path .. family.newID
            result.changes[#result.changes + 1] = {oldID = oldID, newID = family.newID, basePartId = key,
              childPartId = childKey, pulley = choice, ratio = pulleyRatio(family, choice), receipt = deepcopy(part.rlsSuperchargerMigration)}
          end
        end
      end
    end
  end
  for _, change in ipairs(result.changes) do
    local ref = packageRefs[change.basePartId]
    if ref then
      local family = data.families[data.entries[change.oldID].slot]
      ref.node.children = ref.node.children or {}
      local child = ref.node.children[family.childSlot]
      if child and (child.name ~= change.pulley or tonumber(child.partId) ~= tonumber(change.childPartId)) then
        fail(issues, 'package-pulley-conflict', tostring(ref.package.id))
      else
        ref.node.name = change.newID
        ref.node.children[family.childSlot] = child or {name = change.pulley, partId = change.childPartId, relativeSlot = family.childSlot, children = {}}
        result.changedPackages = true
      end
    end
  end
  if #issues > 0 then return nil, issues end
  return result, issues
end

-- Read-only planning for both preflight and copied-save execution. No FS writes.
function M.readPlan(savePath)
  local inventoryPath = savePath .. '/career/partInventory.json'
  local inventory = {}
  if FS:fileExists(inventoryPath) then
    local encoded = jsonReadFile(inventoryPath)
    if type(encoded) ~= 'table' or type(encoded[1]) ~= 'string' then return nil, {{code = 'unreadable-part-inventory', subject = inventoryPath}} end
    local ok
    ok, inventory = pcall(serializedTable.decode, encoded[1])
    if not ok or type(inventory) ~= 'table' then return nil, {{code = 'unreadable-part-inventory', subject = inventoryPath}} end
  end
  local files = FS:findFiles(savePath .. '/career/vehicles/', '*.json', 0, false, false)
  table.sort(files)
  local vehicles = {}
  for _, file in ipairs(files) do
    local vehicle = jsonReadFile(file)
    if type(vehicle) ~= 'table' then return nil, {{code = 'unreadable-vehicle', subject = file}} end
    vehicle.id = vehicle.id or tonumber(file:match('(%d+)%.json$'))
    vehicles[#vehicles + 1] = vehicle
  end
  local packages, packageError = M.readPackages(savePath)
  if packageError then return nil, packageError end
  local result, issues = M.plan(vehicles, inventory, packages)
  if result then result.files = files end
  return result, issues
end

function M.readPackages(savePath)
  local file = savePath .. M.packagePath
  if not FS:fileExists(file) then return nil end
  local value = jsonReadFile(file)
  if type(value) ~= 'table' or type(value.packages) ~= 'table' then return nil, {{code = 'unreadable-engine-packages', subject = file}} end
  return value
end

-- Same-name spawn reconciliation normally regenerates catalog value. Owned
-- split rows instead retain their conserved value, receipt and depreciation
-- inputs. Native runtime paths/descriptions still come from the spawned part.
function M.preserveOwnedSplit(existing, spawned)
  local receipt = existing and existing.rlsSuperchargerMigration
  if type(receipt) ~= 'table' or receipt.version ~= M.version or existing.name ~= spawned.name then return false end
  local entry = data.entries[receipt.oldID]
  if not entry then return false end
  local family = data.families[entry.slot]
  if existing.name ~= family.newID and not isPulley(family, existing.name) then return false end
  local runtimeFields = {name = true, description = true, containingSlot = true, partPath = true, location = true, missingFile = true}
  for key, value in pairs(existing) do if not runtimeFields[key] then spawned[key] = deepcopy(value) end end
  return true
end

return M
