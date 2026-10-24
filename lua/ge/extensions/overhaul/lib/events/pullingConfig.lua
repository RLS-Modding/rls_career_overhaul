-- Tractor-pull numeric tuning projection without changing loaded metadata.
-- Read numeric defaults, coercion rules and the public normalizer.
local M = {}
local catalog = require("overhaul/lib/platform/jsonCatalog")

local NUMERIC_DEFAULTS = {
  fullPullDistanceMeters = 91.44,
  finishToleranceMeters = 0.35,
  sledSpawnHeightMeters = 1.25,
  stagingRadiusMeters = 6,
  stagingExitRadiusMeters = 9,
  stagingStopSpeedMps = 0.5,
  stagingStopSeconds = 1,
  sledLoadDelaySeconds = 2,
  maxSledTeleportJumpMeters = 12,
  maxSledTeleportSpeedMps = 40,
  startMovementFeet = 1,
  progressIncrementFeet = 0.1,
  noProgressFinishSeconds = 5,
  maximumPullSeconds = 120,
}

-- Location bindings are authored in overhaul/pulling.json; absent bindings remain absent.
local LOCATION_FIELDS = {"sitesFile", "stagingSpot", "spawnSpot", "finishSpot", "eventId"}

function M.normalize(raw)
  raw = type(raw) == "table" and raw or {}
  local values = {}
  for key, default in pairs(NUMERIC_DEFAULTS) do
    values[key] = tonumber(raw[key]) or default
  end
  for _, key in ipairs(LOCATION_FIELDS) do
    if type(raw[key]) == "string" and raw[key] ~= "" then values[key] = raw[key] end
  end
  values.label = raw.label or "Tractor Pull"
  return values
end

-- Common metadata remains raw so runtime owners retain sled, hitch and authoring fields.
-- Event keys are the exact race identities; per-event data overlays common metadata.
function M.events(raw)
  if type(raw) ~= "table" then return {} end
  if raw.events == nil then
    return catalog.validId(raw.eventId) and {[raw.eventId] = raw} or {}
  end
  local events = {}
  if type(raw.events) ~= "table" then
    log("W", "tractorPullConfig", "Pulling unavailable: events must be an object keyed by event id")
    return events
  end
  for id, event in pairs(raw.events) do
    if catalog.validId(id) and type(event) == "table" then
      local merged = {}
      for key, value in pairs(raw) do
        if key ~= "events" then merged[key] = value end
      end
      for key, value in pairs(event) do merged[key] = value end
      merged.eventId = id
      events[id] = merged
    else
      log("W", "tractorPullConfig", "Ignoring pulling event: requires an exact string id and metadata object")
    end
  end
  return events
end

function M.getEvent(raw, eventId)
  if type(eventId) ~= "string" then return nil end
  return M.events(raw)[eventId]
end

return M
