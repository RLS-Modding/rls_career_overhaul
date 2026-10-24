-- UI state events: a periodic refresh is sent only when its payload differs from the last one sent on that event.
-- Every push of an event must go through send or refresh so the remembered payload is the one the UI has.
local ffi = require('ffi')

local M = {}

-- Copies of the last payloads, so later edits to the caller's table still count as a change.
local lastSent = {}

local function snapshot(value)
  local valueType = type(value)
  if valueType == 'table' then
    local out = {}
    for key, nested in pairs(value) do out[key] = snapshot(nested) end
    return out
  elseif valueType == 'cdata' then
    return ffi.new(ffi.typeof(value), value)
  end
  return value
end

-- Deep comparison; a key present only in b also counts as a difference.
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for key, nested in pairs(a) do
    if not same(nested, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

function M.send(eventName, payload)
  lastSent[eventName] = snapshot(payload)
  guihooks.trigger(eventName, payload)
end

function M.refresh(eventName, payload)
  local last = lastSent[eventName]
  if last ~= nil and same(payload, last) then return false end
  M.send(eventName, payload)
  return true
end

return M
