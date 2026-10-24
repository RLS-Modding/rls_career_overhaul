-- Guards registered service exports and defers the latest deserialize until activation.
-- getDirect exposes an implementation to callers that already enforce the active-service gate.
local function exportNames(module, exports)
  if exports then return exports end
  local names = {}
  for name, implementation in pairs(module) do
    if type(implementation) == "function" then names[#names + 1] = name end
  end
  return names
end

return function(module, start, stop, exports)
  local enabled = false
  local pending
  local deserialize = module.onDeserialized
  local direct = {}
  local function bindExport(name, fn)
    assert(type(fn) == "function", "Missing guarded service export: " .. name)
    direct[name] = fn
    -- Read-only parity inspection follows fn and enabled without calling a guarded export.
    module[name] = function(...)
      if not enabled then return end
      local gameMode = overhaul_shell_gameMode
      if not gameMode then return end
      local status = gameMode.status
      if status then
        if status.active then return fn(...) end
      elseif gameMode.isActive() then
        return fn(...)
      end
    end
  end
  for _, name in ipairs(exportNames(module, exports)) do bindExport(name, module[name]) end
  if deserialize then
    module.onDeserialized = function(...)
      if enabled and overhaul_shell_gameMode and overhaul_shell_gameMode.isActive() then return deserialize(...) end
      pending = {...}
    end
  end
  module.enable = function(data)
    if enabled then return end
    enabled = true
    if pending then
      deserialize(unpack(pending))
      pending = nil
    elseif start then
      start(data)
    end
  end
  module.disable = function()
    if not enabled then return end
    local data
    if stop then data = stop() end
    enabled = false
    return data
  end
  module.onExtensionUnloaded = module.disable
  module.getDirect = function(name) return direct[name] end
  return module
end
