-- UI scope listeners belong to the extension instance, not the shared require cache.
-- Declarations select a state owner; the common scope loader reports acquire/release to it.
local M = {}
function M.set(scopes, id, active)
  if type(id) ~= 'string' then return false end
  scopes[id] = active == true and true or nil
  return true
end
function M.listening(scopes) return scopes and next(scopes) ~= nil or false end
return M
