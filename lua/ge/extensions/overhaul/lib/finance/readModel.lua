-- One wallet history projection for the menu and phone. Pure reads: no settlement,
-- save mutation, provider callbacks or UI-specific grouping in this module.
local metadata = require("overhaul/lib/finance/metadata")
local pageIndex = require("overhaul/lib/finance/pageIndex")
local cachedProjection, cachedRows = pageIndex.projectionCache(), pageIndex.rowCache()
local M = {}
local emptyLog = {}
local labelRevision = 0

function M.invalidateLabels() labelRevision = labelRevision + 1 end
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

local function rowName(stored, context)
  local name = context.label and context.label(stored.reason or {}) or type(stored.reason) == "table" and stored.reason.label
  return type(name) == "string" and name or "Transaction"
end

local function labelRow(row, stored, context)
  row.name = rowName(stored, context)
end

local function normalizedOptions(options)
  return {
    groupBy = ({vehicle=true, source=true, category=true, period=true})[options.groupBy] and options.groupBy or "none",
    sortBy = ({amount=true, date=true, name=true})[options.sortBy] and options.sortBy or "date",
    direction = options.direction == "asc" and "asc" or "desc",
    period = ({day=true, week=true, month=true, year=true})[options.period] and options.period or "month",
    timezone = "UTC",
  }
end

local descriptorFields = {category = {'id', 'name', 'accent'}, source = {'id', 'name'},
  vehicle = {'id', 'key', 'related', 'name'}, location = {'id', 'name'}}
local missingField = {}
local compactPositions = {id=1, amount=2, timestamp=3, legacy=4, isWork=5, category=6, source=7, vehicle=8, location=9}
local compactRow = {__index=function(row, key) return rawget(row, compactPositions[key]) end}

local function shareDescriptor(pools, kind, descriptor)
  local branch = pools[kind]
  if not branch then branch = {}; pools[kind] = branch end
  for _, field in ipairs(descriptorFields[kind]) do
    local key = descriptor[field]
    if key == nil then key = missingField end
    local child = branch[key]
    if not child then child = {}; branch[key] = child end
    branch = child
  end
  if not branch.value then branch.value = descriptor end
  return branch.value
end

local function projectRow(stored, index, shared)
  local amount = type(stored) == "table" and type(stored.attributeChange) == "table" and stored.attributeChange.money
  if not finite(amount) or amount == 0 then return end
  local meta, legacy = metadata.read(stored, amount)
  local timestamp = meta.timestamp
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
  if not shared then return row end
  -- Durable metadata already owns the detailed snapshots. Compact cache records
  -- share repeated descriptors instead of retaining four more tables per posting.
  return setmetatable({row.id, amount, timestamp, legacy, meta.isWork,
    shareDescriptor(shared, 'category', row.category), shareDescriptor(shared, 'source', row.source),
    shareDescriptor(shared, 'vehicle', row.vehicle), shareDescriptor(shared, 'location', row.location)}, compactRow)
end

local function build(logRows, options, context, deferLabels, projectedRows)
  options, context = type(options) == "table" and options or {}, context or {}
  local normalized = normalizedOptions(options)
  local groupBy, sortBy, direction, periodUnit = normalized.groupBy, normalized.sortBy, normalized.direction, normalized.period
  local result = {version = 1, balance = context.balance or 0, rows = {}, groups = {}, totals = totals(),
    options = normalized}
  local groups = {}
  local labels = projectedRows and sortBy == "name" and {} or nil
  for index, stored in ipairs(projectedRows or (type(logRows) == "table" and logRows or {})) do
    local row = projectedRows and stored or projectRow(stored, index)
    if row then
      local timestamp = row.timestamp
      if (not finite(options.since) or (timestamp and timestamp >= options.since))
        and (not finite(options.untilTime) or (timestamp and timestamp <= options.untilTime)) then
        if labels then
          labels[tonumber(row.id)] = rowName(logRows[tonumber(row.id)], context)
        elseif not deferLabels or sortBy == "name" then
          labelRow(row, stored, context)
        end
        result.rows[#result.rows + 1] = row
        add(result.totals, row)
        -- The vehicle view lists vehicles only: money with no vehicle recorded (or none
        -- involved) stays in the totals and the other views, not in a made-up vehicle group.
        local hasVehicle = row.vehicle.related ~= false and row.vehicle.key ~= "unknown"
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
  local function comparator(isGroup)
    return function(a, b)
      local left, right
      if sortBy == "name" then
        left = (not isGroup and labels and labels[tonumber(a.id)] or a.name):lower()
        right = (not isGroup and labels and labels[tonumber(b.id)] or b.name):lower()
      elseif sortBy == "amount" then left, right = isGroup and a.totals.net or a.amount, isGroup and b.totals.net or b.amount
      else left, right = a.timestamp or -math.huge, b.timestamp or -math.huge end
      if left == right then
        if isGroup then return a.id < b.id end
        return tonumber(a.id) > tonumber(b.id)
      end
      if direction == "asc" then return left < right end
      return left > right
    end
  end
  local rowLess = comparator(false)
  table.sort(result.rows, rowLess); table.sort(result.groups, comparator(true))
  for _, group in ipairs(result.groups) do table.sort(group.rows, rowLess) end
  if labels then result.labels = labels end
  if projectedRows then result.rowLess = rowLess end
  return result
end

function M.build(logRows, options, context)
  return build(logRows, options, context, false)
end

-- Cache group summaries with the ordering, so opening a card never scans its
-- entire transaction history just to rediscover its largest expense.
local function insertOrdered(rows, row, less)
  local lower, upper = 1, #rows + 1
  while lower < upper do
    local middle = math.floor((lower + upper) / 2)
    if less(rows[middle], row) then lower = middle + 1 else upper = middle end
  end
  table.insert(rows, lower, row)
end

local function appendRows(view, rows, logRows, options, context)
  local appended, labels = {}, {}
  for index = view.projectedCount + 1, #rows do
    local row, timestamp = rows[index], rows[index].timestamp
    if (not finite(options.since) or (timestamp and timestamp >= options.since))
      and (not finite(options.untilTime) or (timestamp and timestamp <= options.untilTime)) then
      appended[#appended + 1] = row
      -- Resolve callbacks before changing an existing view, so failures can retry.
      if view.labels then labels[tonumber(row.id)] = rowName(logRows[tonumber(row.id)], context) end
    end
  end
  for _, row in ipairs(appended) do
    if view.labels then view.labels[tonumber(row.id)] = labels[tonumber(row.id)] end
    insertOrdered(view.rows, row, view.rowLess)
    add(view.totals, row)
  end
  view.projectedCount = #rows
  return view
end

local function indexProjection(logRows, options, context, previous)
  local rows = cachedRows(logRows, metadata.getReadRevision(), projectRow)
  if previous and previous.options.groupBy == "none" then return appendRows(previous, rows, logRows, options, context) end
  local view = build(logRows, options, context, true, rows)
  view.projectedCount = #rows
  view.groupsById = {}
  for _, group in ipairs(view.groups) do
    local original, costs = group.rows, {}
    for _, row in ipairs(original) do
      if row.amount < 0 and row.category.id ~= "transfer" then
        local cost = costs[row.category.id] or {id = row.category.id, name = row.category.name, amount = 0}
        cost.amount = cost.amount - row.amount; costs[row.category.id] = cost
      end
    end
    local orderedCosts = {}
    for _, cost in pairs(costs) do orderedCosts[#orderedCosts + 1] = cost end
    table.sort(orderedCosts, function(a, b) return a.amount == b.amount and a.id < b.id or a.amount > b.amount end)
    group.summary = {id = group.id, name = group.name, totals = group.totals, timestamp = group.timestamp,
      category = original[1].category, source = original[1].source,
      costs = orderedCosts[1] and {orderedCosts[1]} or {}}
    view.groupsById[group.id] = group
  end
  return view
end

-- Balance is live; only immutable historical projections and ordering are cached.
-- Labels on returned rows are resolved per request; name ordering also keys locale.
function M.page(logRows, options, context)
  logRows = type(logRows) == "table" and logRows or emptyLog
  options, context = type(options) == "table" and options or {}, context or {}
  local normalized = normalizedOptions(options)
  local language = core_locales and core_locales.getLanguage and core_locales.getLanguage() or false
  local key = {normalized.groupBy, normalized.sortBy, normalized.direction, normalized.period,
    finite(options.since) and options.since or false, finite(options.untilTime) and options.untilTime or false,
    context.label or false, context.labelRevision or false, language, labelRevision, metadata.getReadRevision()}
  local view = cachedProjection(logRows, key, function(previous) return indexProjection(logRows, options, context, previous) end)
  local result = {version = view.version, balance = context.balance or 0, rows = {}, groups = {},
    totals = metadata.copy(view.totals), options = metadata.copy(view.options)}
  local function materialize(row)
    local copy = metadata.copy({id=row.id, amount=row.amount, timestamp=row.timestamp, legacy=row.legacy,
      isWork=row.isWork, category=row.category, source=row.source, vehicle=row.vehicle, location=row.location})
    if view.labels then copy.name = view.labels[tonumber(row.id)]
    else labelRow(copy, logRows[tonumber(row.id)], context) end
    return copy
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
    for index = offset + 1, math.min(#view.rows, offset + limit) do
      result.rows[#result.rows + 1] = materialize(view.rows[index])
    end
    result.paging = paging(#view.rows, #result.rows)
    return result
  end
  local groupId = type(options.groupId) == "string" and options.groupId
  local groupOffset = integer(options.groupOffset, 0, 2147483647)
  local groupLimit = math.max(1, integer(options.groupLimit, 20, 40))
  local function appendGroup(group)
    if not group then return end
    local summary = metadata.copy(group.summary)
    summary.rowIds = {}
    if groupId then
      for index = offset + 1, math.min(#group.rows, offset + limit) do
        local row = materialize(group.rows[index])
        result.rows[#result.rows + 1] = row; summary.rowIds[#summary.rowIds + 1] = row.id
      end
      summary.paging = paging(#group.rows, #summary.rowIds)
    else
      summary.paging = {offset = 0, limit = limit, total = #group.rows, hasMore = #group.rows > 0, nextOffset = 0}
    end
    result.groups[#result.groups + 1] = summary
  end
  if groupId then appendGroup(view.groupsById[groupId])
  else
    for index = groupOffset + 1, math.min(#view.groups, groupOffset + groupLimit) do appendGroup(view.groups[index]) end
  end
  result.paging = {groupOffset = groupOffset, groupLimit = groupLimit, total = #view.groups,
    hasMore = not groupId and groupOffset + #result.groups < #view.groups,
    nextGroupOffset = groupOffset + #result.groups}
  return result
end
return M
