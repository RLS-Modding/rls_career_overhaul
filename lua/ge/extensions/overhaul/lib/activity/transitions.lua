-- Activity transition names: the lifecycle transitions an activity definition may name a handler for, and the hooks that announce them.
-- The names match the lifecycle owner descriptors in tests/fixtures/lifecycle. Data only: nothing here dispatches.
local M = {}

M.LIST = {"save", "reload", "exit", "quit", "stop", "switch", "travel", "unload"}
M.NAMES = {}
for _, name in ipairs(M.LIST) do M.NAMES[name] = true end

-- Forward the original active-state argument when dispatching a career stop.
M.HOOKS = {
  onOverhaulSaveCurrentProfile = "save",
  onOverhaulBeforeLuaReload = "reload",
  onPreExit = "exit",
  onOverhaulBeforeSetProfile = "switch",
  onClientEndMission = "unload",
}

-- Transition for a hook call, or nil when the hook does not announce one.
function M.forHook(hookName, ...)
  if hookName == "onOverhaulActive" then
    local active = ...
    if active == false then return "stop" end
    return nil
  end
  return M.HOOKS[hookName]
end

return M
