-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/debug/precisionParkingDebug.lua (BeamNG 0.40).

local M = {}
local im = ui_imgui
M.debugOrder = 10
M.debugName = "Precision Parking"

-- Debug state
local debugEnabled = false
local debugData = {}
local lastUpdateTime = 0
local updateInterval = 0.1 -- Update every 100ms

-- Get closest facility parking spot
local function getClosestFacilityParkingSpot()
  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId then return nil end

  local playerVeh = scenetree.findObjectById(playerVehId)
  if not playerVeh then return nil end

  local playerPos = playerVeh:getPosition()
  local facilities = overhaul_world_facilities.getFacilities(getCurrentLevelIdentifier())

  local closestFacility = nil
  local closestParkingSpot = nil
  local minDist = math.huge

  -- Check all facilities for parking spots
  for _, facility in ipairs(facilities.deliveryProviders or {}) do
    if facility.accessPointsByName then
      for _, accessPoint in pairs(facility.accessPointsByName) do
        local dist = accessPoint.ps.pos:distance(playerPos)
        if dist < minDist then
          minDist = dist
          closestFacility = accessPoint
          closestParkingSpot = accessPoint.ps
        end
      end
    end
  end

  return closestParkingSpot, closestFacility
end

-- Update debug data
local function updateDebugData()
  if not debugEnabled then return end

  local currentTime = os.clock()
  if currentTime - lastUpdateTime < updateInterval then return end
  lastUpdateTime = currentTime

  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId then
    debugData = { error = "No player vehicle" }
    return
  end

  local closestParkingSpot, closestFacility = getClosestFacilityParkingSpot()
  if not closestParkingSpot then
    debugData = { error = "No parking spots found" }
    return
  end

  -- Calculate precision parking data
  local precisionData = overhaul_career_logistics_precisionParking.debugPrecisionParking(playerVehId, closestParkingSpot)
  if not precisionData then
    debugData = { error = "Failed to calculate precision data" }
    return
  end

  -- Get bonus information
  local precisionBonus = overhaul_career_logistics_precisionParking.getPrecisionParkingBonus and
                        overhaul_career_logistics_precisionParking.getPrecisionParkingBonus(precisionData) or {}

  debugData = {
    playerVehId = playerVehId,
    facilityName = closestFacility and closestFacility.name or "Unknown",
    precisionLevel = precisionData.precisionLevel,
    totalScore = precisionData.totalScore,
    angle = precisionData.angle,
    adjustedAngle = precisionData.adjustedAngle,
    sideDist = precisionData.sideDist,
    forwardDist = precisionData.forwardDist,
    angleScore = precisionData.angleScore,
    sideScore = precisionData.sideScore,
    forwardScore = precisionData.forwardScore,
    multiplier = precisionBonus.multiplier or 1.0,
    bonusXP = precisionBonus.bonusXP or 0,
    bonusMoney = precisionBonus.bonusMoney or 0,
    targetPos = closestParkingSpot.pos,
    targetRot = closestParkingSpot.rot,
    -- Adaptive tolerance data
    vehicleWidth = precisionData.vehicleWidth,
    vehicleLength = precisionData.vehicleLength,
    parkingSpotWidth = precisionData.parkingSpotWidth,
    parkingSpotLength = precisionData.parkingSpotLength,
    maxSideTolerance = precisionData.maxSideTolerance,
    maxForwardTolerance = precisionData.maxForwardTolerance,
    minSideTolerance = precisionData.minSideTolerance,
    minForwardTolerance = precisionData.minForwardTolerance
  }
end

-- Draw debug visualization
local function drawDebugVisualization()
  if not debugEnabled or not debugData.targetPos then return end

  local targetPos = debugData.targetPos
  local targetRot = debugData.targetRot

  -- Draw target parking spot
  debugDrawer:drawSphere(targetPos, 1.0, ColorF(1, 0, 0, 0.5))

  -- Draw target direction
  local targetDir = targetRot * vec3(0, 1, 0)
  debugDrawer:drawArrow(targetPos, targetPos + targetDir * 3, ColorF(1, 0, 0, 1))

  -- Draw target orientation box
  local xVec = targetRot * vec3(1, 0, 0)
  local yVec = targetRot * vec3(0, 1, 0)

  local size = 2.0
  local corners = {
    targetPos + xVec * size + yVec * size,
    targetPos - xVec * size + yVec * size,
    targetPos - xVec * size - yVec * size,
    targetPos + xVec * size - yVec * size
  }

  for i = 1, 4 do
    local next = (i % 4) + 1
    debugDrawer:drawLine(corners[i], corners[next], ColorF(1, 0, 0, 0.8))
  end

  -- Draw precision level color coding
  local color = ColorF(1, 0, 0, 0.3) -- Default red
  if debugData.precisionLevel == "perfect" then
    color = ColorF(0, 1, 0, 0.3) -- Green
  elseif debugData.precisionLevel == "great" then
    color = ColorF(0, 1, 1, 0.3) -- Cyan
  elseif debugData.precisionLevel == "good" then
    color = ColorF(1, 1, 0, 0.3) -- Yellow
  elseif debugData.precisionLevel == "ok" then
    color = ColorF(1, 0.5, 0, 0.3) -- Orange
  end

  debugDrawer:drawSphere(targetPos, 0.5, color)
end

M.drawDebugMenu = function()
  -- Toggle debug mode
  if im.Button(debugEnabled and "Disable Precision Parking Debug" or "Enable Precision Parking Debug") then
    debugEnabled = not debugEnabled
    if not debugEnabled then
      debugData = {}
    end
  end

  if not debugEnabled then return end

  im.Separator()

  -- Update debug data
  updateDebugData()

  -- Display debug information
  if debugData.error then
    im.TextColored(im.ImVec4(1, 0, 0, 1), "Error: " .. debugData.error)
    return
  end


  -- Basic info
  im.Text("Player Vehicle ID: " .. tostring(debugData.playerVehId or "None"))
  im.Text("Closest Facility: " .. tostring(debugData.facilityName or "Unknown"))

  im.Separator()

  -- Precision scoring
  im.Text("=== Precision Parking Score ===")
  im.Text("Level: " .. tostring(debugData.precisionLevel or "Unknown"))

  -- Total score with progress bar
  local totalScore = math.floor((debugData.totalScore or 0) * 10 + 0.5) / 10
  local totalProgress = math.min(totalScore / 20, 1.0)
  im.Text("Total Score: " .. string.format("%.1f", totalScore) .. "/20")

  -- Set progress bar color based on score
  local totalColor = im.ImVec4(
    math.max(0, 1 - totalProgress),  -- Red component decreases
    math.min(1, totalProgress),       -- Green component increases
    0, 1
  )
  im.PushStyleColor1(im.Col_PlotHistogram, im.GetColorU322(totalColor))
  im.ProgressBar(totalProgress, im.ImVec2(-1, 0), "")
  im.PopStyleColor()

  -- Individual scores with progress bars
  local angleScore = math.floor((debugData.angleScore or 0) * 10 + 0.5) / 10
  local sideScore = math.floor((debugData.sideScore or 0) * 10 + 0.5) / 10
  local forwardScore = math.floor((debugData.forwardScore or 0) * 10 + 0.5) / 10

  -- Angle score with progress bar
  local angleProgress = math.min(angleScore / 6, 1.0)
  im.Text("Angle Score: " .. string.format("%.1f", angleScore) .. "/6")
  local angleColor = im.ImVec4(
    math.max(0, 1 - angleProgress),
    math.min(1, angleProgress),
    0, 1
  )
  im.PushStyleColor1(im.Col_PlotHistogram, im.GetColorU322(angleColor))
  im.ProgressBar(angleProgress, im.ImVec2(-1, 0), "")
  im.PopStyleColor()

  -- Side score with progress bar
  local sideProgress = math.min(sideScore / 6, 1.0)
  im.Text("Side Score: " .. string.format("%.1f", sideScore) .. "/6")
  local sideColor = im.ImVec4(
    math.max(0, 1 - sideProgress),
    math.min(1, sideProgress),
    0, 1
  )
  im.PushStyleColor1(im.Col_PlotHistogram, im.GetColorU322(sideColor))
  im.ProgressBar(sideProgress, im.ImVec2(-1, 0), "")
  im.PopStyleColor()

  -- Forward score with progress bar
  local forwardProgress = math.min(forwardScore / 6, 1.0)
  im.Text("Forward Score: " .. string.format("%.1f", forwardScore) .. "/6")
  local forwardColor = im.ImVec4(
    math.max(0, 1 - forwardProgress),
    math.min(1, forwardProgress),
    0, 1
  )
  im.PushStyleColor1(im.Col_PlotHistogram, im.GetColorU322(forwardColor))
  im.ProgressBar(forwardProgress, im.ImVec2(-1, 0), "")
  im.PopStyleColor()

  im.Separator()




  -- Precision parking results table
  im.Text("=== All Possible Results ===")

  -- Get precision parking config
  local config = overhaul_career_logistics_precisionParking.getPrecisionParkingConfig()
  if config then
    -- Table headers
    if im.BeginTable("PrecisionParkingResults", 6, im.TableFlags_Borders) then
      im.TableSetupColumn("Rating", im.TableColumnFlags_WidthFixed, 80)
      im.TableSetupColumn("Score", im.TableColumnFlags_WidthFixed, 60)
      im.TableSetupColumn("Money", im.TableColumnFlags_WidthFixed, 100)
      im.TableSetupColumn("Logistics XP", im.TableColumnFlags_WidthFixed, 100)
      im.TableSetupColumn("Skill XP", im.TableColumnFlags_WidthFixed, 100)
      im.TableSetupColumn("Reputation", im.TableColumnFlags_WidthFixed, 100)
      im.TableHeadersRow()

      -- Define all possible results
      local results = {
        {name = "Perfect", score = config.PERFECT_SCORE,
         moneyFlat = config.PERFECT_MONEY_FLAT, moneyPercent = config.PERFECT_MONEY_PERCENT,
         logisticsFlat = config.PERFECT_LOGISTICS_FLAT, logisticsPercent = config.PERFECT_LOGISTICS_PERCENT,
         skillFlat = config.PERFECT_SKILL_FLAT, skillPercent = config.PERFECT_SKILL_PERCENT,
         reputationFlat = config.PERFECT_REPUTATION_FLAT, reputationPercent = config.PERFECT_REPUTATION_PERCENT},
        {name = "Great", score = config.GREAT_SCORE,
         moneyFlat = config.GREAT_MONEY_FLAT, moneyPercent = config.GREAT_MONEY_PERCENT,
         logisticsFlat = config.GREAT_LOGISTICS_FLAT, logisticsPercent = config.GREAT_LOGISTICS_PERCENT,
         skillFlat = config.GREAT_SKILL_FLAT, skillPercent = config.GREAT_SKILL_PERCENT,
         reputationFlat = config.GREAT_REPUTATION_FLAT, reputationPercent = config.GREAT_REPUTATION_PERCENT},
        {name = "Good", score = config.GOOD_SCORE,
         moneyFlat = config.GOOD_MONEY_FLAT, moneyPercent = config.GOOD_MONEY_PERCENT,
         logisticsFlat = config.GOOD_LOGISTICS_FLAT, logisticsPercent = config.GOOD_LOGISTICS_PERCENT,
         skillFlat = config.GOOD_SKILL_FLAT, skillPercent = config.GOOD_SKILL_PERCENT,
         reputationFlat = 0, reputationPercent = 0},
        {name = "Bad", score = config.BAD_SCORE,
         moneyFlat = config.BAD_MONEY_FLAT, moneyPercent = config.BAD_MONEY_PERCENT,
         logisticsFlat = 0, logisticsPercent = 0,
         skillFlat = 0, skillPercent = 0,
         reputationFlat = 0, reputationPercent = 0},
                 {name = "Horrible", score = 0,
                  moneyFlat = config.HORRIBLE_MONEY_FLAT, moneyPercent = config.HORRIBLE_MONEY_PERCENT,
                  logisticsFlat = 0, logisticsPercent = 0,
                  skillFlat = 0, skillPercent = 0,
                  reputationFlat = config.HORRIBLE_REPUTATION_FLAT, reputationPercent = config.HORRIBLE_REPUTATION_PERCENT}
      }

      -- Display each result
      for _, result in ipairs(results) do
        im.TableNextRow()

        -- Highlight current result
        local isCurrentResult = (debugData.precisionLevel == string.lower(result.name))
        if isCurrentResult then
          -- Convert ImVec4 to color value using the correct function
          local color = im.GetColorU322(im.ImVec4(0.2, 0.6, 0.2, 0.3))
          im.TableSetBgColor(im.TableBgTarget_RowBg0, color)
        end

        -- Rating column
        im.TableSetColumnIndex(0)
        if isCurrentResult then
          im.TextColored(im.ImVec4(0, 1, 0, 1), "► " .. result.name)
        else
          im.Text(result.name)
        end

        -- Score column
        im.TableSetColumnIndex(1)
        if isCurrentResult then
          local currentScore = math.floor((debugData.totalScore or 0) * 10 + 0.5) / 10
          im.TextColored(im.ImVec4(0, 1, 0, 1), string.format("%.1f", currentScore))
        else
          im.Text(tostring(result.score))
        end

        -- Money column
        im.TableSetColumnIndex(2)
        local moneyText = string.format("%+.0f", result.moneyFlat)
        if result.moneyPercent ~= 0 then
          moneyText = moneyText .. string.format(" (%+.0f%%)", result.moneyPercent * 100)
        end
        if result.moneyFlat >= 0 then
          im.TextColored(im.ImVec4(0, 1, 0, 1), moneyText)
        else
          im.TextColored(im.ImVec4(1, 0, 0, 1), moneyText)
        end

        -- Logistics XP column
        im.TableSetColumnIndex(3)
        if result.logisticsFlat ~= 0 or result.logisticsPercent ~= 0 then
          local logisticsText = string.format("%+.0f", result.logisticsFlat)
          if result.logisticsPercent ~= 0 then
            logisticsText = logisticsText .. string.format(" (%+.0f%%)", result.logisticsPercent * 100)
          end
          im.TextColored(im.ImVec4(0, 1, 0, 1), logisticsText)
        else
          im.Text("-")
        end

        -- Skill XP column
        im.TableSetColumnIndex(4)
        if result.skillFlat ~= 0 or result.skillPercent ~= 0 then
          local skillText = string.format("%+.0f", result.skillFlat)
          if result.skillPercent ~= 0 then
            skillText = skillText .. string.format(" (%+.0f%%)", result.skillPercent * 100)
          end
          im.TextColored(im.ImVec4(0, 1, 0, 1), skillText)
        else
          im.Text("-")
        end

        -- Reputation column
        im.TableSetColumnIndex(5)
        if result.reputationFlat ~= 0 or result.reputationPercent ~= 0 then
          local reputationText = string.format("%+.0f", result.reputationFlat)
          if result.reputationPercent ~= 0 then
            reputationText = reputationText .. string.format(" (%+.0f%%)", result.reputationPercent * 100)
          end
          im.TextColored(im.ImVec4(0, 1, 0, 1), reputationText)
        else
          im.Text("-")
        end
      end

      im.EndTable()
    end
  end

  im.Separator()

  -- Adaptive tolerance information
  im.Text("=== Size Adaptive Scoring ===")
  im.Text("Vehicle: " .. string.format("%.1fx%.1fm", debugData.vehicleWidth or 0, debugData.vehicleLength or 0))
  im.Text("Parking Spot: " .. string.format("%.1fx%.1fm", debugData.parkingSpotWidth or 0, debugData.parkingSpotLength or 0))
  im.Text("Side Tolerance: " .. string.format("%.2f-%.2fm", debugData.minSideTolerance or 0, debugData.maxSideTolerance or 0))
  im.Text("Forward Tolerance: " .. string.format("%.2f-%.2fm", debugData.minForwardTolerance or 0, debugData.maxForwardTolerance or 0))

  -- Measurements
  im.Text("=== Measurements ===")
  im.Text("Raw Angle: " .. string.format("%.1f°", debugData.angle or 0))
  im.Text("Adjusted Angle: " .. string.format("%.1f°", debugData.adjustedAngle or 0))
  im.Text("Side Distance: " .. string.format("%.2fm", debugData.sideDist or 0))
  im.Text("Forward Distance: " .. string.format("%.2fm", debugData.forwardDist or 0))

  im.Separator()

end

-- Draw debug visualization in 3D world
M.drawDebugVisualization = function()
  if debugEnabled then
    drawDebugVisualization()
  end
end

-- Cleanup when debug is disabled
M.onDebugDisabled = function()
  debugEnabled = false
  debugData = {}
end

return M
