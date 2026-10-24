-- One wallet history projection for the menu and phone. Pure reads: no settlement,
-- save mutation, provider callbacks or UI-specific grouping in this module.
local metadata = require("overhaul/lib/finance/metadata")
local M = {}
local function finite(value) return type(value) == "number" and value == value and math.abs(value) < math.huge end
local function totals() return {count = 0, incoming = 0, outgoing = 0, income = 0, expenses = 0, transfersIn = 0, transfersOut = 0, net = 0, operatingNet = 0} end
local function add(total, row)
  local amount = row.amount
  total.count = total.count + 1
  if amount >= 0 then total.incoming = total.incoming + amount else total.outgoing = total.outgoing - amount end
  if row.category.id == "transfer" then
    if amount >= 0 then total.transfersIn = total.transfersIn + amount else total.transfersOut = total.transfersOut - amount end
  elseif amount >= 0 then total.income = total.income + amount else total.expenses = total.expenses - amount end
  total.net = total.incoming - total.outgoing
  total.operatingNet = total.income - total.expenses
end

local function period(timestamp, unit)
  if not timestamp then return "unknown", "Unknown date" end
  if unit == "month" then local key = os.date("!%Y-%m", timestamp); return key, key end
  if unit == "year" then local key = os.date("!%Y", timestamp); return key, key end
  local day = math.floor(timestamp / 86400)
  if unit == "week" then day = day - ((day + 3) % 7) end
  local key = os.date("!%Y-%m-%d", day * 86400)
  return key, unit == "week" and ("Week of " .. key) or key
end

local function labelRow(row, stored, context)
  local name = context.label and context.label(stored.reason or {}) or type(stored.reason) == "table" and stored.reason.label
  row.name = type(name) == "string" and name or "Transaction"
end

local function build(logRows, options, context, deferLabels)
  options, context = type(options) == "table" and options or {}, context or {}
  local groupBy = ({vehicle=true, source=true, category=true, period=true})[options.groupBy] and options.groupBy or "none"
  local sortBy = ({amount=true, date=true, name=true})[options.sortBy] and options.sortBy or "date"
  local direction = options.direction == "asc" and "asc" or "desc"
  local periodUnit = ({day=true, week=true, month=true, year=true})[options.period] and options.period or "month"
  local result = {version = 1, balance = context.balance or 0, rows = {}, groups = {}, totals = totals(),
    options = {groupBy = groupBy, sortBy = sortBy, direction = direction, period = periodUnit, timezone = "UTC"}}
  local groups = {}
  for index, stored in ipairs(type(logRows) == "table" and logRows or {}) do
    local amount = type(stored) == "table" and type(stored.attributeChange) == "table" and stored.attributeChange.money
    if finite(amount) and amount ~= 0 then
      local meta, legacy = metadata.read(stored, amount)
      local timestamp = meta.timestamp
      if (not finite(options.since) or (timestamp and timestamp >= options.since))
        and (not finite(options.untilTime) or (timestamp and timestamp <= options.untilTime)) then
        local row = {id = tostring(index), amount = amount,
          timestamp = timestamp, legacy = legacy, isWork = meta.isWork,
          category = {id = meta.category, name = meta.categoryName, accent = meta.categoryAccent},
          source = {id = meta.isWork and (meta.source or "unknown") or "not_work",
            name = meta.isWork and (meta.sourceName or "Unspecified work type") or "Other money"},
          vehicle = {id = meta.vehicleId or "unknown", key = meta.vehicleKey or meta.vehicleId or "unknown",
            related = meta.vehicleRelated,
            name = meta.vehicleRelated == false and "Not vehicle-related"
              or meta.vehicleName or (meta.vehicleId and ("Vehicle " .. meta.vehicleId)) or "Unknown vehicle"},
          location = {id = meta.locationId, name = meta.locationName or (meta.locationId and ("Location " .. meta.locationId)) or "Location not recorded"}}
        if not deferLabels or sortBy == "name" then labelRow(row, stored, context) end
        result.rows[#result.rows + 1] = row
        add(result.totals, row)
        -- The vehicle view lists vehicles only: money with no vehicle recorded (or none
        -- involved) stays in the totals and the other views, not in a made-up vehicle group.
        local hasVehicle = meta.vehicleRelated ~= false and row.vehicle.key ~= "unknown"
        if groupBy ~= "none" and (groupBy ~= "vehicle" or hasVehicle) then
          local key, title
          if groupBy == "source" and not row.isWork then
            key, title = "other:" .. row.category.id, "Other money: " .. row.category.name
          elseif groupBy == "period" then key, title = period(timestamp, periodUnit)
          elseif groupBy == "vehicle" then key, title = row.vehicle.key, row.vehicle.name
          else key, title = row[groupBy].id, row[groupBy].name end
          local group = groups[key]
          if not group then
            group = {id = key, name = title, rows = {}, totals = totals()}
            groups[key] = group; result.groups[#result.groups + 1] = group
          end
          group.rows[#group.rows + 1] = row; add(group.totals, row)
          if timestamp then group.timestamp = math.max(group.timestamp or timestamp, timestamp) end
        end
      end
    end
  end
  local function sort(items, isGroup)
    table.sort(items, function(a, b)
      local left, right
      if sortBy == "name" then left, right = a.name:lower(), b.name:lower()
      elseif sortBy == "amount" then left, right = isGroup and a.totals.net or a.amount, isGroup and b.totals.net or b.amount
      else left, right = a.timestamp or -math.huge, b.timestamp or -math.huge end
      if left == right then
        if isGroup then return a.id < b.id end
        return tonumber(a.id) > tonumber(b.id)
      end
      if direction == "asc" then return left < right end
      return left > right
    end)
  end
  sort(result.rows, false); sort(result.groups, true)
  for _, group in ipairs(result.groups) do sort(group.rows, false) end
  return result
end

function M.build(logRows, options, context)
  return build(logRows, options, context, false)
end

-- Transport pages keep lifetime totals while sending each transaction only once.
-- Group decks contain summaries; opening a card requests that group's row page.
function M.page(logRows, options, context)
  options = type(options) == "table" and options or {}
  local view = build(logRows, options, context, true)
  local function materialize(row)
    if row.name == nil then labelRow(row, logRows[tonumber(row.id)], context or {}) end
    return row
  end
  local function integer(value, fallback, maximum)
    return finite(value) and math.max(0, math.min(maximum, math.floor(value))) or fallback
  end
  local limit = math.max(1, integer(options.limit, 60, 100))
  local offset = integer(options.offset, 0, 2147483647)
  local function paging(total, count)
    return {offset = offset, limit = limit, total = total, hasMore = offset + count < total,
      nextOffset = offset + count}
  end
  if view.options.groupBy == "none" then
    local rows = {}
    for i = offset + 1, math.min(#view.rows, offset + limit) do rows[#rows + 1] = materialize(view.rows[i]) end
    view.paging, view.rows = paging(#view.rows, #rows), rows
    return view
  end
  local groups, rows = {}, {}
  local groupId = type(options.groupId) == "string" and options.groupId
  local groupOffset = integer(options.groupOffset, 0, 2147483647)
  local groupLimit = math.max(1, integer(options.groupLimit, 20, 40))
  for index, group in ipairs(view.groups) do
    if (groupId and group.id == groupId) or (not groupId and index > groupOffset and index <= groupOffset + groupLimit) then
      local original = group.rows
      group.category, group.source = original[1].category, original[1].source
      local costs = {}
      for _, row in ipairs(original) do
        if row.amount < 0 and row.category.id ~= "transfer" then
          local cost = costs[row.category.id] or {id = row.category.id, name = row.category.name, amount = 0}
          cost.amount = cost.amount - row.amount; costs[row.category.id] = cost
        end
      end
      group.costs = {}
      for _, cost in pairs(costs) do group.costs[#group.costs + 1] = cost end
      table.sort(group.costs, function(a, b) return a.amount == b.amount and a.id < b.id or a.amount > b.amount end)
      -- Only the largest expense is needed by the card summary.
      group.costs = group.costs[1] and {group.costs[1]} or {}
      group.rows, group.rowIds = nil, {}
      if groupId then
        for i = offset + 1, math.min(#original, offset + limit) do
          local row = materialize(original[i])
          rows[#rows + 1] = row; group.rowIds[#group.rowIds + 1] = row.id
        end
        group.paging = paging(#original, #group.rowIds)
      else
        group.paging = {offset = 0, limit = limit, total = #original, hasMore = #original > 0, nextOffset = 0}
      end
      groups[#groups + 1] = group
    end
  end
  view.paging = {groupOffset = groupOffset, groupLimit = groupLimit, total = #view.groups,
    hasMore = not groupId and groupOffset + #groups < #view.groups,
    nextGroupOffset = groupOffset + #groups}
  view.groups, view.rows = groups, rows
  return view
end
return M
