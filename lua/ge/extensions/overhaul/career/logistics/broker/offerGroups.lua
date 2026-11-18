-- Broker display groups belong to the board, so stop summaries and the phone
-- count the same listings even when several native offers share a row.
local M = {}

local displayFields = {"market", "kind", "title", "from", "to", "pay", "quantity", "unit",
  "trailerType", "arrangement", "subtype", "requirement"}
local availabilityFields = {"access", "lockedReason", "atPickup", "offerExpiresAt", "modifiers", "timed", "fragile"}

-- Table iteration order must not split otherwise identical access/fit records.
local function key(value)
  if type(value) ~= "table" then
    local text = tostring(value)
    return type(value) .. #text .. ":" .. text
  end
  local entries = {}
  for field, item in pairs(value) do entries[#entries + 1] = key(field) .. key(item) end
  table.sort(entries)
  return "{" .. table.concat(entries) .. "}"
end

function M.assign(rows, yieldWork)
  local groups, rowKeys = {}, {}
  for _, row in ipairs(rows) do
    local identity = {}
    for _, field in ipairs(displayFields) do identity[field] = tostring(row[field] or "") end
    for _, field in ipairs(availabilityFields) do identity[field] = row[field] end
    local groupKey = key(identity)
    rowKeys[row] = groupKey
    local id = tostring(row.id)
    if not groups[groupKey] or id < groups[groupKey] then groups[groupKey] = id end
    if yieldWork then yieldWork() end
  end
  for _, row in ipairs(rows) do row.offerGroup = groups[rowKeys[row]] end
  return rows
end

function M.availableCounts(rows, markets)
  local counts, seen = {}, {}
  for _, row in ipairs(rows) do
    if row.access.state == "available" and not seen[row.offerGroup] then
      counts[row.market] = (counts[row.market] or 0) + 1
      seen[row.offerGroup] = true
    end
  end
  local result = {}
  for _, market in ipairs(markets) do
    if counts[market.id] then result[#result + 1] = {id = market.id, name = market.name, count = counts[market.id]} end
  end
  return result
end

return M
