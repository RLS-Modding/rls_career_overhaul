-- Checked temporary Career departures. Owners register their own checkpoint policy.
local M = {}
local owners = {}
function M.register(owner, handlers)
  assert(type(owner)=='string' and type(handlers.canSuspend)=='function' and type(handlers.isReturning)=='function')
  owners[owner]=handlers
  return function() if owners[owner]==handlers then owners[owner]=nil end end
end
function M.canSuspend(owner, ticket)
  local handlers=owners[owner]
  return handlers and handlers.canSuspend(ticket)==true or false
end
function M.isReturning()
  for _,handlers in pairs(owners) do if handlers.isReturning() then return true end end
  return false
end
return M
