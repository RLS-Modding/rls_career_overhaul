-- Instance-local snapshots for broker rows and publication. Native owners mutate
-- tables in place, so identity alone cannot prove that a cached view is current.
local M = {}

local function copy(value, yieldWork)
  if type(value) ~= 'table' then return value end
  if yieldWork then yieldWork() end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item, yieldWork) end
  return result
end

local function equal(a, b, yieldWork)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  if yieldWork then yieldWork() end
  for key, value in pairs(a) do
    if not equal(value, b[key], yieldWork) then return false end
  end
  for key in pairs(b) do if a[key] == nil then return false end end
  return true
end

M.equal = equal

function M.new()
  local entries = {}
  local cache = {}
  function cache.get(key, source, dependencies, build, yieldWork)
    local entry = entries[key]
    if entry and equal(source, entry.source, yieldWork) and equal(dependencies, entry.dependencies, yieldWork) then return entry.value, false end
    local value = build(entry and entry.source)
    entries[key] = {source = copy(source, yieldWork), dependencies = copy(dependencies, yieldWork), value = value}
    return value, true
  end
  function cache.retain(keys)
    for key in pairs(entries) do if keys[key] == nil then entries[key] = nil end end
  end
  return cache
end
return M
