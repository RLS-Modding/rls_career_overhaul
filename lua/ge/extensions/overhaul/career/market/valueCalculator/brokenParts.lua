-- Repair parts come from the live configuration tree or durable condition paths after the vehicle is unspawned.
-- Map: durable part lookup, missing metadata, then deterministic broken-part enumeration.
local M = {}

local function durablePart(service, inventoryId, partPath)
  local records = service.getInventory and service.getInventory() or {}
  local pathMap = service.getPartPathToPartIdMap and service.getPartPathToPartIdMap() or {}
  local partIds = pathMap[inventoryId]
  local record = partIds and partIds[partPath] and records[partIds[partPath]]
  if record and record.location == inventoryId and record.partPath == partPath then return record end
  -- The path index can lag a new vehicle or a replaced part while the durable records already exist.
  for _, candidate in pairs(records) do
    if candidate.location == inventoryId and candidate.partPath == partPath then return candidate end
  end
end

local function brokenPart(service, inventoryId, partPath, slotPath)
  local record = slotPath and service.getPart and service.getPart(inventoryId, slotPath)
    or durablePart(service, inventoryId, partPath)
  -- The pricing owner applies its ordinary unknown-part price to missing metadata.
  return record or {partPath=partPath}
end

function M.find(vehicle, service)
  service = service or {}
  local result = {partsToBeReplaced={}}
  local tree = vehicle.config and vehicle.config.partsTree
  if not tree then
    local paths = {}
    for path, condition in pairs(vehicle.partConditions or {}) do
      if condition and condition.integrityValue == 0 then paths[#paths+1] = path end
    end
    -- Stable ordering keeps rounded totals identical in the live-tree and saved-record paths.
    table.sort(paths)
    for _, path in ipairs(paths) do result.partsToBeReplaced[#result.partsToBeReplaced+1] = brokenPart(service,vehicle.id,path) end
    return result
  end
  local function visit(node)
    if not node.partPath or not vehicle.partConditions then return end
    local condition = vehicle.partConditions[node.partPath]
    if condition and condition.integrityValue == 0 then
      result.partsToBeReplaced[#result.partsToBeReplaced+1] = brokenPart(service,vehicle.id,node.partPath,node.path)
    end
    for _, child in pairs(node.children or {}) do visit(child) end
  end
  visit(tree)
  return result
end

return M
