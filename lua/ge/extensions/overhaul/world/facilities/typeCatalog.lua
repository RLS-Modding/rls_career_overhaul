-- Facility files already use a merged level VFS; this registry discovers their type/list vocabulary.
-- Validate the discovered declarations before deriving facility list names and UI labels.
local M = {}

local catalog = require('overhaul/lib/platform/jsonCatalog')

M.dir = '/gameplay/overhaul/facilities/types/'

local function validate(entry)
  if not catalog.validId(entry.listName) then return nil, 'invalid listName' end
  if type(entry.uiLabel) ~= 'string' or entry.uiLabel == '' then return nil, 'missing uiLabel' end
  return entry
end

function M.scan()
  local entries, rejected = catalog.scan(M.dir, validate, 'overhaul_facilityTypeCatalog')
  local valid, seen = {}, {}
  for _, entry in ipairs(entries) do
    if seen[entry.listName] then
      local reason = 'listName ' .. entry.listName .. ' already belongs to ' .. seen[entry.listName]
      rejected[#rejected + 1] = {id = entry.id, reason = reason}
      log('W', 'overhaul_facilityTypeCatalog', reason)
    else
      seen[entry.listName] = entry.id
      valid[#valid + 1] = entry
    end
  end
  return valid, rejected
end

function M.maps()
  local names, labels = {}, {}
  for _, entry in ipairs(M.scan()) do
    names[entry.id] = entry.listName
    labels[entry.id] = entry.uiLabel
  end
  return names, labels
end

return M
