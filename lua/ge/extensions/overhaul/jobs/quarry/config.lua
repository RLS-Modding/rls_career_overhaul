-- Quarry material, bed, facility and contract configuration.
-- Load global data before level facilities, then apply missing settings once.
local M = {}

local settings = require("overhaul/jobs/quarry/settings")
local levelData = require("overhaul/lib/world/levelData")
M.runtime = {}

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

local function mergeGlobalSettings(data)
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

local function mergeGlobalMaterials(data)
  if data.materials then
    for k, v in pairs(data.materials) do
      if validateMaterial(k, v) then
        M.materials[k] = v
      end
    end
  end
end

local function loadGlobalConfiguration()
  local globalPath = "/gameplay/overhaul/loading/"
  local globalFiles = FS:findFiles(globalPath, "*.loading.json", -1, true, false)
  if globalFiles then
    for _, filePath in ipairs(globalFiles) do
      local data = jsonReadFile(filePath)
      if data then
        mergeGlobalMaterials(data)
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
        mergeGlobalSettings(data)
      end
    end
  end
end

local function loadLevelFacilities()
  local levelName = getCurrentLevelIdentifier()
  if levelName then
    local facilityPath = "/levels/" .. levelName .. "/facilities/"
    local facilityFiles = FS:findFiles(facilityPath, "*.loading.json", -1, true, false)
    if facilityFiles then
      table.sort(facilityFiles)
      for _, filePath in ipairs(facilityFiles) do
        local data = jsonReadFile(filePath)
        if data and data.facilities then
          for facilityKey, facilityData in pairs(data.facilities) do
            local id = facilityData.id or facilityKey
            if type(facilityData.sitesFile) ~= "string" or type(facilityData.sites) ~= "table" then
              log("W", "quarry", "Facility disabled: missing sitesFile/sites in " .. filePath)
            elseif M.facilities[id] then
              log("W", "quarry", "Duplicate facility disabled: " .. id)
            else
              local sites = {}
              for tag, site in pairs(facilityData.sites) do
                local key = id .. "::" .. (site.id or tag)
                site.tag = tag
                sites[key] = site
              end
              facilityData.sites = sites
              facilityData.id = id
              M.facilities[id] = facilityData
            end
          end
        end
      end
    end
  end
end

local function loadConfiguration()
  M.materials = {}
  M.bedSettings = {}
  M.facilities = {}
  M.contracts = {}
  M.settings = {}
  loadGlobalConfiguration()
  loadLevelFacilities()
  local level = getCurrentLevelIdentifier()
  M.runtime = level and jsonReadFile(levelData.assetPath(level, "overhaul/quarry.json")) or {}
  M.runtime = M.runtime or {}
  settings.apply(M.settings)
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
