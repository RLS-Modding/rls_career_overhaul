-- Personal inventory transport. The view's row schema is decoded in partsInventoryTransport.js.
local M = {}
local maxRowsPerMessage = 128

local function packPart(part)
  -- False fills absent cells so the bridge always encodes a dense array.
  return {part.id, part.name or "", part.description.description, part.vehicleModel or false,
    part.vehicleModelDisplayName, part.partCondition.odometer or false, part.finalValue,
    part.location, part.accessible, part.missingFile or false, part.repairCount or false,
    part.primered or false}
end

local function equalArray(left, right)
  if not left or #left ~= #right then return false end
  for index, value in ipairs(left) do
    if right[index] ~= value then return false end
  end
  return true
end

local function slice(values, offset)
  local result = {}
  for index = offset, math.min(offset + maxRowsPerMessage - 1, #values) do
    result[#result + 1] = values[index]
  end
  return result
end

function M.newPublisher()
  local previousRows, previousOrder, revision = nil, nil, 0
  -- The process clock survives an extension reload; old publications cannot replace its new snapshot.
  local generation = (os.clockhp or os.clock)()
  return {
    reset = function() previousRows, previousOrder = nil, nil end,
    publish = function(data)
      local rows, order, changed, removed = {}, {}, {}, {}
      for _, part in ipairs(data.partList) do
        local row = packPart(part)
        rows[part.id], order[#order + 1] = row, part.id
        if not previousRows or not equalArray(previousRows[part.id], row) then
          changed[#changed + 1] = row
        end
      end
      for id in pairs(previousRows or {}) do
        if not rows[id] then removed[#removed + 1] = id end
      end
      local replaceOrder = not equalArray(previousOrder, order)
      local changedOrder = replaceOrder and order or {}
      local batches = math.max(1, math.ceil(math.max(#changed, #removed, #changedOrder) / maxRowsPerMessage))
      revision = revision + 1
      for batch = 1, batches do
        local offset = (batch - 1) * maxRowsPerMessage + 1
        local message = {generation = generation, revision = revision, batch = batch, reset = not previousRows,
          replaceOrder = replaceOrder, rows = slice(changed, offset),
          removedIds = slice(removed, offset), order = slice(changedOrder, offset), complete = batch == batches}
        if message.complete then
          message.data = {vehicles = data.vehicles, currentVehicle = data.currentVehicle,
            brokenVehicleInventoryIds = data.brokenVehicleInventoryIds}
        end
        guihooks.trigger('partInventoryData', message)
      end
      previousRows, previousOrder = rows, order
    end,
  }
end

return M
