-- Material contract quantities preserve exact amounts and load-count ranges.
-- Read weighted load selection, then validation and amount resolution.
local M = {}

local function weightedLoads(minLoads, maxLoads, weights, random)
  local total = 0
  for loads = minLoads, maxLoads do
    total = total + math.max(0, tonumber(weights[tostring(loads)]) or 0)
  end
  if total <= 0 then return nil end
  local pick = random() * total
  for loads = minLoads, maxLoads do
    pick = pick - math.max(0, tonumber(weights[tostring(loads)]) or 0)
    if pick < 0 then return loads end
  end
  return maxLoads
end

function M.validate(values)
  if values == nil then return nil end
  if type(values) ~= "table" or #values == 0 then return nil, "contractAmounts must be a nonempty list" end
  local result, seen = {}, {}
  for _, value in ipairs(values) do
    if type(value) ~= "number" or value ~= value or value <= 0 or value == math.huge then
      return nil, "contractAmounts must contain finite positive quantities"
    end
    if not seen[value] then
      result[#result + 1] = value
      seen[value] = true
    end
  end
  table.sort(result)
  return result
end

function M.resolve(generator, standardLoad, minLoads, maxLoads)
  local amounts, err = M.validate(generator and generator.contractAmounts)
  if err then return nil, err end
  local range = generator and generator.contractLoadCount
  if range then
    if type(range) ~= "table" or type(range.min) ~= "number" or type(range.max) ~= "number"
        or range.min < 1 or range.max < range.min or range.min % 1 ~= 0 or range.max % 1 ~= 0 then
      return nil, "contractLoadCount must contain positive integer min/max values"
    end
    minLoads, maxLoads = range.min, range.max
  end
  return { amounts = amounts, standardLoad = standardLoad, minLoads = minLoads, maxLoads = maxLoads,
    maxAmount = amounts and amounts[#amounts] or standardLoad * maxLoads }
end

function M.choose(quantity, random)
  random = random or math.random
  if quantity.amounts then
    local amount = quantity.amounts[random(1, #quantity.amounts)]
    return amount, math.ceil(amount / quantity.standardLoad), "exact"
  end
  local loads = type(quantity.loadWeights) == "table"
    and weightedLoads(quantity.minLoads, quantity.maxLoads, quantity.loadWeights, random)
    or random(quantity.minLoads, quantity.maxLoads)
  return quantity.standardLoad * loads, loads, "loads"
end

function M.destinationAllowed(generator, line, destinationId)
  for _, ids in ipairs({ generator and generator.contractDestinationFacilityIds or false,
    line and line.destinationFacilityIds or false }) do
    if type(ids) == "table" then
      local found = false
      for _, id in ipairs(ids) do
        if id == destinationId then
          found = true
          break
        end
      end
      if not found then return false end
    end
  end
  return true
end

return M
