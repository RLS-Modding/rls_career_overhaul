-- Quarry runtime setting defaults and load-boundary normalization.
-- Missing provider data retains the same settings during initialization and reload.
local M = {}

local defaults = {
  ui = {
    updateInterval = 0.5,
    animationSpeed = 8.0,
    pulseSpeed = 5.0,
    markerPulseSpeed = 2.5,
    markerRotationSpeed = 0.4,
    markerBeamSpeed = 30.0,
    markerMaxBeamHeight = 12.0,
    markerRingExpandSpeed = 1.5,
    zoneMarkerMaxBeamHeight = 15.0,
    zoneMarkerPulseSpeed = 2.5,
  },
  truck = {
    arrivalSpeedThreshold = 2.0,
    arrivalDistanceThreshold = 1.0,
  },
  payload = {
    updateInterval = 0.25,
    nodeSamplingStep = 10,
    minLoadRatio = 0.25,
  },
  zones = {
    checkInterval = 0.1,
    detectionRadius = 10.0,
    sitesLoadRetryInterval = 1.0,
  },
}

function M.value(values, section, key)
  return values and values[key] or defaults[section][key]
end

local propLimits = {beforeConfiguration = 6, afterConfiguration = 2}
local bedDefaults = {offsetBack = 0, offsetSide = 0, floorHeight = 0, centerLoadHeight = 0, loadHeight = 1, width = 1, length = 1}
local respawnMaterialConfig = "default"

-- Cached bed transforms still observe edits to the public settings table.
function M.bedGeometry(values)
  return {
    offsetBack = values.offsetBack or bedDefaults.offsetBack,
    offsetSide = values.offsetSide or bedDefaults.offsetSide,
    floorHeight = values.floorHeight or bedDefaults.floorHeight,
    centerLoadHeight = values.loadHeight or bedDefaults.centerLoadHeight,
    loadHeight = values.loadHeight or bedDefaults.loadHeight,
    width = values.width or bedDefaults.width,
    length = values.length or bedDefaults.length,
  }
end

function M.propLimit(settings)
  return settings.maxProps or propLimits.beforeConfiguration
end

function M.respawnConfig(material)
  return material.config or respawnMaterialConfig
end

local sections = {
  {name = "ui", keys = {"updateInterval", "animationSpeed", "pulseSpeed", "markerPulseSpeed", "markerRotationSpeed", "markerBeamSpeed", "markerMaxBeamHeight", "markerRingExpandSpeed", "zoneMarkerMaxBeamHeight", "zoneMarkerPulseSpeed"}},
  {name = "truck", keys = {"arrivalSpeedThreshold", "arrivalDistanceThreshold"}},
  {name = "payload", keys = {"updateInterval", "nodeSamplingStep", "minLoadRatio"}},
  {name = "zones", keys = {"checkInterval", "detectionRadius", "sitesLoadRetryInterval"}},
}

function M.apply(settings)
  -- A malformed later section must leave the same earlier defaults installed.
  for _, section in ipairs(sections) do
    settings[section.name] = settings[section.name] or {}
    for _, key in ipairs(section.keys) do
      settings[section.name][key] = settings[section.name][key] or defaults[section.name][key]
    end
  end
  settings.maxProps = settings.maxProps or propLimits.afterConfiguration
end

return M
