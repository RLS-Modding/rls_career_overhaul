-- Private indexes over append-only histories. Replacement arrays (save/load) get
-- a fresh index; weak keys let closed accounts and unloaded careers be collected.
local M = {}
local historySort = require('overhaul/lib/finance/historySort')
local bankIndexes = setmetatable({}, {__mode = 'k'})

local function newest(left, right) return left.timestamp > right.timestamp end

function M.bankPage(history, limit)
  local count = #history
  local index = bankIndexes[history]
  if not index or index.count > count or index.first ~= history[1]
    or index.last ~= history[index.count] then
    index = {count = 0, ascending = true, descending = true}
    bankIndexes[history] = index
  end
  if index.count ~= count then
    for position = math.max(2, index.count + 1), count do
      local previous, current = history[position - 1].timestamp, history[position].timestamp
      index.ascending = index.ascending and previous < current
      index.descending = index.descending and previous > current
      if not index.ascending and not index.descending then break end
    end
    index.count, index.first, index.last = count, history[1], history[count]
    index.sorted = nil
    if not index.ascending and not index.descending then
      local sorted = {}
      for position, row in ipairs(history) do sorted[position] = row end
      -- Lua's legacy sort is unstable at equal timestamps. Rebuild from original
      -- insertion order so ties remain byte-for-byte identical, even after append.
      historySort(sorted, newest)
      index.sorted = sorted
    end
  end
  local result = {}
  local last = limit and limit > 0 and math.min(limit, count) or count
  for position = 1, last do
    result[position] = index.sorted and index.sorted[position]
      or history[index.ascending and count - position + 1 or position]
  end
  return result
end

-- A single active projection bounds retained memory independently of how many
-- combinations of filters/sorts the player tries. Page offsets are not keys.
function M.projectionCache()
  local entries = setmetatable({}, {__mode = 'k'})
  return function(rows, key, create)
    local entry = entries[rows]
    local matches = entry and #entry.key == #key and entry.count <= #rows
      and entry.first == rows[1] and entry.last == rows[entry.count]
    if matches then
      for position, field in ipairs(key) do
        if field ~= entry.key[position] then matches = false; break end
      end
    end
    if not matches or entry.count ~= #rows then
      entry = {key = key, value = create(matches and entry.value or nil), count = #rows, first = rows[1], last = rows[#rows]}
      entries = setmetatable({[rows] = entry}, {__mode = 'k'})
    end
    return entry.value
  end
end

function M.rowCache()
  local entries = setmetatable({}, {__mode = 'k'})
  return function(history, revision, project)
    local entry = entries[history]
    if not entry or entry.revision ~= revision or entry.count > #history
      or entry.first ~= history[1] or entry.last ~= history[entry.count] then
      entry = {rows = {}, shared = {}, count = 0, revision = revision, first = history[1]}
      entries = setmetatable({[history] = entry}, {__mode = 'k'})
    end
    for position = entry.count + 1, #history do
      local row = project(history[position], position, entry.shared)
      if row then entry.rows[#entry.rows + 1] = row end
      -- A failed legacy row must not make a retry duplicate earlier projections.
      entry.count, entry.last = position, history[position]
    end
    entry.count, entry.first, entry.last = #history, history[1], history[#history]
    return entry.rows
  end
end

return M
