-- Compatibility facade for the existing GE lifecycle. The fuel runtime is
-- the sole adapter owner; this extension never renders or changes an engine.
local M={}
local epoch=0
function M.configure(value)epoch=value or 0 end
function M.onReset()end
M.onExtensionUnloaded=M.onReset
function M.debugState()
  local out={renderer='native',epoch=epoch,engines={}}
  for name,e in pairs(powertrain.getDevices()) do
    local context=e.rlsFuelContext
    if context and context.afterfire then
      out.engines[name]=require('vehicle/rlsAfterfireAdapter').status(context.afterfire)
    end
  end
  return out
end
return M
