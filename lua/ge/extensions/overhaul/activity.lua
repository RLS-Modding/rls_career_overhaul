-- On-demand developer access to the activity host owned by the current career.
-- Kept demand-only because loading another GE extension changes the engine's hook order.

local M = {}

local accessLib = require('overhaul/lib/activity/access')

local own = nil

local function access()
  local career = rawget(_G, 'overhaul_career_career')
  local a = type(career) == 'table' and career.activity or nil
  if type(a) == 'table' and a.action then return a end
  if not own then own = accessLib.new() end
  return own
end

for _, name in ipairs({'register', 'unregister', 'get', 'list', 'children', 'action', 'project', 'isActive',
    'canStart', 'resources', 'getHost'}) do
  M[name] = function(...) return access()[name](...) end
end

return M
