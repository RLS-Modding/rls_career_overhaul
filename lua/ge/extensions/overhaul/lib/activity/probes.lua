-- Probe helpers for activity owners: wraps a getter so a missing or failing getter reads as inactive.
-- Some existing consumers treat failed or missing owner getters as inactive and require literal true.
local M = {}

function M.protectedBoolean(owner, name)
  return function()
    local getter = owner[name]
    if type(getter) ~= 'function' then return false end
    local ok, value = pcall(getter)
    return ok and value == true
  end
end

return M
