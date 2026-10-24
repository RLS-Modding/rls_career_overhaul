-- Gives every operation its own instance's deps as the first argument, so two loaded instances never share inputs.
-- Shared by dispatch, jobs and results (3 callers), which each pass their deps and operation table.
return function(deps, operations)
  local api = {}
  for name, operation in pairs(operations) do
    api[name] = function(...) return operation(deps, ...) end
  end
  return api
end
