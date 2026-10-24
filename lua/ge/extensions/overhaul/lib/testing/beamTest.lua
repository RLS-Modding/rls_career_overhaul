-- Retain the opaque owner across hooks-only reloads; never use global fallbacks.
local M = {}
local registry, owner
local methods = {action='registerAction', check='registerCheck', career='registerCareer', setup='registerSetup'}
local function supported(handle)
  if type(handle) ~= 'table' or not handle.ok or type(handle.registerProvider) ~= 'function' then return false end
  for _, method in pairs(methods) do if type(handle[method]) ~= 'function' then return false end end
  return true
end
local function unavailable() return {ok=false, message='beamTest owner-bound registration unavailable'} end
function M.bind(bt, metadata)
  if registry ~= bt then registry, owner = bt, nil end
  if not bt or type(bt.registerProvider) ~= 'function' then return unavailable() end
  if not owner then
    -- Older draft API-1 receipts must never advertise usable compat=1 hooks.
    local claimed = bt.registerProvider('overhaul', {version=metadata.version, compat=0, capabilities={}})
    if not supported(claimed) then return unavailable() end
    owner = claimed
  end
  if not supported(owner) then return unavailable() end
  local result = owner:registerProvider(metadata)
  if result and result.ok then return owner end
  return result or unavailable()
end
function M.register(provider, kind, id, spec)
  local method = methods[kind]
  if not method or type(provider[method]) ~= 'function' then return unavailable() end
  return provider[method](provider, id, spec)
end
-- A detached registry must not keep provider closures alive through require's cache.
function M.releaseDetached(current)
  if current ~= registry then registry, owner = nil, nil end
end
return M
