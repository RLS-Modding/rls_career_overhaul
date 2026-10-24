-- Business vehicle leaderboard lookup and display labels.
-- Live capabilities keep owner reloads visible to callers.
local M = {}

local capabilities = require("overhaul/lib/platform/capabilities")

-- Proof consumers supply each authored leaderboard label explicitly.
local function getRaceLabelVariations(_raceType, raceLabel)
  return {raceLabel}
end

local function getLeaderboardInventoryIdsForBusinessVehicle(businessId, vehicleId)
  local ids = {}
  local seen = {}
  local function add(id)
    if not id or seen[id] then
      return
    end
    seen[id] = true
    table.insert(ids, id)
  end
  local vid = tonumber(vehicleId) or vehicleId
  add(capabilities.get("businessVehicles").getBusinessVehicleIdentifier(businessId, vid))
  return ids
end

local function getBestLeaderboardTime(businessId, vehicleId, raceType, raceLabel, levelIds)
  if not businessId or not vehicleId or not raceLabel then
    return nil
  end

  local leaderboardManager = capabilities.get("raceRecords")
  local variations = getRaceLabelVariations(raceType, raceLabel)
  local inventoryIds = getLeaderboardInventoryIdsForBusinessVehicle(businessId, vehicleId)
  local bestTime = nil
  local useLevels = type(levelIds) == "table" and #levelIds > 0
  local getEntryAtLevel = leaderboardManager.getLeaderboardEntryAtLevel

  for _, invId in ipairs(inventoryIds) do
    for _, variation in ipairs(variations) do
      if useLevels and type(getEntryAtLevel) == "function" then
        for _, lev in ipairs(levelIds) do
          if type(lev) == "string" and lev ~= "" then
            local entry = getEntryAtLevel(lev, invId, variation)
            if entry and entry.time then
              if not bestTime or entry.time < bestTime then
                bestTime = entry.time
              end
            end
          end
        end
      else
        local entry = leaderboardManager.getLeaderboardEntry(invId, variation)
        if entry and entry.time then
          if not bestTime or entry.time < bestTime then
            bestTime = entry.time
          end
        end
      end
    end
  end

  return bestTime
end

local function extractDisplayInfo(info)
  if not info then
    return nil, "Unknown", "Unknown", "/ui/images/appDefault.png"
  end

  local name = nil
  if info.Brand and info.Name then
    name = info.Brand .. " " .. info.Name
  elseif info.Name then
    name = info.Name
  end

  local year = "Unknown"
  local years = info.Years or (info.aggregates and info.aggregates.Years)
  if years then
    if type(years) == "table" and years.min then
      year = tostring(years.min)
    elseif type(years) == "number" then
      year = tostring(years)
    end
  elseif info.Year then
    year = tostring(info.Year)
  end

  local vtype = "Unknown"
  if info["Body Style"] then
    vtype = info["Body Style"]
  elseif info.Type then
    vtype = info.Type
  end

  local image = info.preview or "/ui/images/appDefault.png"

  return name, year, vtype, image
end

M.getRaceLabelVariations = getRaceLabelVariations
M.getBestLeaderboardTime = getBestLeaderboardTime
M.extractDisplayInfo = extractDisplayInfo

return M
