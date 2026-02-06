local M = {}

M.materials = {}
M.bedSettings = {}
M.facilities = {}
M.economy = {}
M.contracts = {}
M.settings = {}

M.STATE_IDLE             = 0
M.STATE_CONTRACT_SELECT  = 1
M.STATE_CHOOSING_ZONE    = 2
M.STATE_DRIVING_TO_SITE  = 3
M.STATE_TRUCK_ARRIVING   = 4
M.STATE_LOADING          = 5
M.STATE_DELIVERING       = 6
M.STATE_RETURN_TO_QUARRY = 7
M.STATE_AT_QUARRY_DECIDE = 8

local function validateMaterial(materialKey, materialData)
  local required = {"name", "model", "config", "unitType", "deliveryVehicle"}
  local missing = {}
  for _, field in ipairs(required) do
    if not materialData[field] then
      table.insert(missing, field)
    end
  end
  if #missing > 0 then
    return false
  end
  return true
end

local function applyDefaults()
  if not M.settings.ui then M.settings.ui = {} end
  M.settings.ui.updateInterval = M.settings.ui.updateInterval or 0.5
  M.settings.ui.animationSpeed = M.settings.ui.animationSpeed or 8.0
  M.settings.ui.pulseSpeed = M.settings.ui.pulseSpeed or 5.0
  M.settings.ui.markerPulseSpeed = M.settings.ui.markerPulseSpeed or 2.5
  M.settings.ui.markerRotationSpeed = M.settings.ui.markerRotationSpeed or 0.4
  M.settings.ui.markerBeamSpeed = M.settings.ui.markerBeamSpeed or 30.0
  M.settings.ui.markerMaxBeamHeight = M.settings.ui.markerMaxBeamHeight or 12.0
  M.settings.ui.markerRingExpandSpeed = M.settings.ui.markerRingExpandSpeed or 1.5
  M.settings.ui.zoneMarkerMaxBeamHeight = M.settings.ui.zoneMarkerMaxBeamHeight or 15.0
  M.settings.ui.zoneMarkerPulseSpeed = M.settings.ui.zoneMarkerPulseSpeed or 2.5

  if not M.settings.truck then M.settings.truck = {} end
  M.settings.truck.arrivalSpeedThreshold = M.settings.truck.arrivalSpeedThreshold or 2.0
  M.settings.truck.arrivalDistanceThreshold = M.settings.truck.arrivalDistanceThreshold or 10.0

  if not M.settings.payload then M.settings.payload = {} end
  M.settings.payload.updateInterval = M.settings.payload.updateInterval or 0.25
  M.settings.payload.nodeSamplingStep = M.settings.payload.nodeSamplingStep or 10
  M.settings.payload.minLoadRatio = M.settings.payload.minLoadRatio or 0.25

  if not M.settings.zones then M.settings.zones = {} end
  M.settings.zones.checkInterval = M.settings.zones.checkInterval or 0.1
  M.settings.zones.detectionRadius = M.settings.zones.detectionRadius or 10.0
  M.settings.zones.sitesLoadRetryInterval = M.settings.zones.sitesLoadRetryInterval or 1.0

  M.settings.maxProps = M.settings.maxProps or 2
end

local function loadConfiguration()
  M.materials = {}
  M.bedSettings = {}
  M.facilities = {}
  M.contracts = {}
  M.settings = {}

  local globalPath = "/gameplay/loading/"
  local globalFiles = FS:findFiles(globalPath, "*.loading.json", -1, true, false)
  if globalFiles then
    for _, filePath in ipairs(globalFiles) do
      local data = jsonReadFile(filePath)
      if data then
        if data.materials then
          for k, v in pairs(data.materials) do
            if validateMaterial(k, v) then
              M.materials[k] = v
            end
          end
        end
        if data.bedSettings then
          for k, v in pairs(data.bedSettings) do
            M.bedSettings[k] = v
          end
        end
        if data.contracts then
          for k, v in pairs(data.contracts) do
            M.contracts[k] = v
          end
        end
        if data.settings then
          for k, v in pairs(data.settings) do
            if type(v) == "table" then
              if not M.settings[k] then M.settings[k] = {} end
              for sk, sv in pairs(v) do
                M.settings[k][sk] = sv
              end
            else
              M.settings[k] = v
            end
          end
        end
      end
    end
  end

  local levelName = getCurrentLevelIdentifier()
  if levelName then
    local facilityPath = "/levels/" .. levelName .. "/facilities/"
    local facilityFiles = FS:findFiles(facilityPath, "*.loading.json", -1, true, false)
    if facilityFiles then
      for _, filePath in ipairs(facilityFiles) do
        local data = jsonReadFile(filePath)
        if data and data.facilities then
          for facilityKey, facilityData in pairs(data.facilities) do
            local id = facilityData.id or facilityKey
            M.facilities[id] = facilityData
          end
        end
      end
    end
  end

  applyDefaults()
  extensions.hook("loadingConfigLoaded")
end

local function onExtensionLoaded()
  loadConfiguration()
end

local function onWorldReadyState(state)
  if state == 2 then
    loadConfiguration()
  end
end

M.onWorldReadyState = onWorldReadyState
M.onExtensionLoaded = onExtensionLoaded
M.loadConfiguration = loadConfiguration
M.validateMaterial = validateMaterial

return M
