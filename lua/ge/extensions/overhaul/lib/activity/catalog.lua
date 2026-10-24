-- Activity catalog: which owner extensions the activity host adopts, read from /gameplay/overhaul/activities/<id>.json.
-- A manifest is {id, order, extension, definition?}; the catalog never loads an extension or requires a definition module.
local manifests = require('overhaul/lib/platform/manifests')

local M = {}

M.dir = "/gameplay/overhaul/activities/"

local TAG = "overhaul_activity_catalog"
local EXTENSION_PATTERN = "^[%a_][%w_]*$"
local MODULE_PATTERN = "^[%w_][%w_/%.%-]*$"

-- Definition factories run only for live owners to keep extension hook order unchanged.
local function validate(data)
  if not manifests.isNonEmptyString(data.extension) or not string.match(data.extension, EXTENSION_PATTERN) then
    return nil, "extension must be a GE extension name"
  end
  if data.definition ~= nil and (not manifests.isNonEmptyString(data.definition)
      or not string.match(data.definition, MODULE_PATTERN) or string.sub(data.definition, -4) == ".lua") then
    return nil, "definition must be a module path (require name, no .lua)"
  end
  return {id = data.id, order = data.order, extension = data.extension, definition = data.definition}
end

-- The usable manifests sorted by order, then id, and the rejected files.
function M.scan()
  return manifests.scan({dir = M.dir, tag = TAG, validate = validate})
end

-- A lookup over a scan: {list = entries in order, byId = {[id] = entry}}.
function M.index(entries)
  local byId = {}
  for _, entry in ipairs(entries) do byId[entry.id] = entry end
  return {list = entries, byId = byId}
end

-- Reads the folder once: the index the access object keeps.
function M.load()
  return M.index((M.scan()))
end

return M
