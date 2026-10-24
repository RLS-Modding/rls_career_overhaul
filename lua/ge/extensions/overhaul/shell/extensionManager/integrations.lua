-- Owns optional integration lifetimes for the shell's accepted owner roster.
-- Readiness hooks wake acquisition; only a live integration or draining owner keeps a job alive.
local M = {}

function M.new(context)
  local hooks, watching, retired = {}, false, false
  local extensions = context.extensions

  local function reconcile()
    if retired or not context.canLoad() then return false end
    local retained = false
    for name, owner in pairs(context.roster().byName) do
      if owner.integration then
        if context.lookup(owner.integration.global) ~= nil then
          retained = true
          if not extensions.isExtensionLoaded(name) then context.load(name) end
        elseif extensions.isExtensionLoaded(name) then
          -- Waiting for ordinary in-flight work is not a teardown error.
          if context.prepare({name}, true) then
            context.unloadMode(name, 'auto')
            extensions.unload(name)
          else
            retained = true
          end
        end
      end
    end
    return retained
  end

  local function wake()
    if not reconcile() or watching then return end
    watching = true
    context.jobs.create(function(job)
      repeat job.sleep(0.1) until not reconcile()
      watching = false
    end)
  end

  local function refresh()
    for hook in pairs(hooks) do
      context.exports[hook] = nil
      if extensions.hookUpdate then extensions.hookUpdate(hook) end
    end
    hooks = {}
    for _, owner in pairs(context.roster().byName) do
      local hook = owner.integration and owner.integration.readyHook
      if hook then
        -- Never replace an engine/shell lifecycle callback with a manifest callback.
        if context.exports[hook] == nil then
          hooks[hook], context.exports[hook] = true, wake
          if extensions.hookUpdate then extensions.hookUpdate(hook) end
        end
      end
    end
    wake()
  end

  return {refresh = refresh, stop = function() retired = true end}
end

return M
