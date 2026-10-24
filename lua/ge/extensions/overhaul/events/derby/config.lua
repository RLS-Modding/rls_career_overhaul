-- Derby tuning projections preserve the raw event table used by staging snapshots.
-- A live editor may change that table, so a changed leaf refreshes its cached effective value.
local M = {}

local NUMERIC_DEFAULTS = { maxOpponents = 10, timeLimitSeconds = 300, reward = 0 }
local VALUE_DEFAULTS = { aiActivationDelay = 2.0, aiPlayerTargetWeight = 0.4, aiAggression = 1.2, aiAvoidCars = "off" }
local emptyConfig = {}
local cached = setmetatable({}, { __mode = "k" })

local function refreshLeaf(entry, raw, key, default, numeric)
  local value = raw[key]
  entry.rawValues[key] = value
  entry.values[key] = numeric and (tonumber(value) or default) or (value or default)
end

function M.normalize(raw)
  raw = raw or emptyConfig
  local entry = { rawValues = {}, values = {} }
  for key, default in pairs(NUMERIC_DEFAULTS) do
    refreshLeaf(entry, raw, key, default, true)
  end
  for key, default in pairs(VALUE_DEFAULTS) do
    refreshLeaf(entry, raw, key, default, false)
  end
  cached[raw] = entry
  return entry.values
end

function M.value(raw, key)
  raw = raw or emptyConfig
  local entry = cached[raw]
  if not entry then
    M.normalize(raw)
    entry = cached[raw]
  end
  if entry.rawValues[key] ~= raw[key] then
    local numeric = NUMERIC_DEFAULTS[key] ~= nil
    local default = numeric and NUMERIC_DEFAULTS[key] or VALUE_DEFAULTS[key]
    refreshLeaf(entry, raw, key, default, numeric)
  end
  return entry.values[key]
end

return M
