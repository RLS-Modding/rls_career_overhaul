local M = {}

M.dependencies = {'career_modules_business_businessInventory', 'gameplay_events_freeroam_leaderboardManager'}

local function getRaceLabelVariations(raceType, raceLabel)
  if not raceType or not raceLabel then
    return {raceLabel}
  end
  
  local variations = {raceLabel}
  
  if raceType == "track" then
    table.insert(variations, raceLabel .. " (Hotlap)")
  elseif raceType == "trackAlt" then
    table.insert(variations, raceLabel .. " (Hotlap)")
  elseif raceType == "drag" then
    table.insert(variations, raceLabel .. " (Hotlap)")
  end
  
  return variations
end

local function getBestLeaderboardTime(businessId, jobId, raceType, raceLabel)
  if not businessId or not jobId or not raceLabel then
    return nil
  end
  
  local businessJobId = career_modules_business_businessInventory.getBusinessJobIdentifier(businessId, jobId)
  local leaderboardManager = require('gameplay/events/freeroam/leaderboardManager')
  
  local variations = getRaceLabelVariations(raceType, raceLabel)
  local bestTime = nil
  
  for _, variation in ipairs(variations) do
    local entry = leaderboardManager.getLeaderboardEntry(businessJobId, variation)
    if entry and entry.time then
      if not bestTime or entry.time < bestTime then
        bestTime = entry.time
      end
    end
  end
  
  return bestTime
end

M.getRaceLabelVariations = getRaceLabelVariations
M.getBestLeaderboardTime = getBestLeaderboardTime

return M

