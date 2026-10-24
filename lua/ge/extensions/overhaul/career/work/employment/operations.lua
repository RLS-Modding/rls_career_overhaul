-- Binds stateless operations to the inputs supplied by one employment instance.
-- The provider is evaluated per call because dispatch snapshots depend on the current assignment.
local M = {}

function M.new(inputs)
  local api = inputs.api or {}
  for name, operation in pairs(inputs.operations) do
    if type(operation) == "function" and name ~= "new" then
      if inputs.withContext[name] then
        api[name] = function(...) return operation(inputs.context(), ...) end
      else
        api[name] = operation
      end
    end
  end
  return api
end

return M
