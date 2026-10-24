-- Derives events from level drag settings without loading gameplay or scene geometry.
-- Read manifest defaults, strip identity and facility labels, then add only unbound strips.
local M = {}
local catalog = require("overhaul/lib/platform/jsonCatalog")
local levelData = require("overhaul/lib/world/levelData")
local DEFAULTS_FILE = "gameplay/overhaul/events/drag.json"

local function name(value)
  return type(value) == "string" and value ~= "" and value or nil
end

local function defaults()
  local manifest = jsonReadFile(DEFAULTS_FILE)
  local data = type(manifest) == "table" and manifest.derivedEventDefaults
  if type(data) ~= "table" or not name(data.label) or type(data.type) ~= "table"
    or #data.type ~= 1 or data.type[1] ~= "drag" or type(data.displaySpeed) ~= "boolean"
    or (data.dragTreeType ~= ".400" and data.dragTreeType ~= ".500")
    or not catalog.finite(data.bestTimeS) or data.bestTimeS <= 0
    or not catalog.finite(data.rewardMoney) or data.rewardMoney < 0 then
    log("W", "dragStripEvents", "Derived drag events unavailable: invalid defaults at " .. DEFAULTS_FILE)
    return nil
  end
  return data
end

local function facilityName(level, settingsId, stripId)
  local facilities = overhaul_world_facilities
  if not facilities or not facilities.getFacilitiesByType then return nil end
  for _, facility in ipairs(facilities.getFacilitiesByType("dragstrip", level) or {}) do
    if facility.id == settingsId or facility.id == stripId then return name(facility.name) end
  end
end

function M.addUnbound(level, races)
  local files = FS:findFiles("levels/" .. level .. "/dragstrips/", "*.dragSettings.json", -1, true, false) or {}
  table.sort(files)
  if #files == 0 then return end
  local tuning = defaults()
  if not tuning then return end
  local bound = {}
  for _, race in pairs(races) do
    if type(race) == "table" and race.dragStripId then bound[race.dragStripId] = true end
  end
  for _, file in ipairs(files) do
    local settings = jsonReadFile(file)
    local stripFile = type(settings) == "table" and levelData.assetPath(level, settings.stripId)
    local strip = stripFile and jsonReadFile(stripFile)
    local stripId = type(strip) == "table" and strip.id
    if catalog.validId(stripId) and not bound[stripId] and races["drag." .. stripId] == nil then
      local settingsId = name(settings.id) or file:match("([^/\\]+)%.dragSettings%.json$")
      races["drag." .. stripId] = {
        label = facilityName(level, settingsId, stripId) or name(strip.name) or tuning.label,
        type = {tuning.type[1]}, dragStripId = stripId,
        bestTime = tuning.bestTimeS, reward = tuning.rewardMoney, displaySpeed = tuning.displaySpeed,
        dragTreeType = tuning.dragTreeType,
      }
      bound[stripId] = true
    end
  end
end

return M
