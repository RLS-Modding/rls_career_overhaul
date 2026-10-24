-- Pit speed limiting and the initial stop/repair controller.
-- Read input callbacks, named stop/speed phases, limit controls and the frame hook.
local M = {}

local activeSpeedLimit = nil
local limitActive = false
local applyingLimit = false
local lastThrottleState = 0 -- Store the last known throttle state
local forcingStop = false -- Flag to indicate if we're in "stop first" mode

-- Function to get throttle input from vehicle

local function requestThrottleInput()
  local veh = be:getPlayerVehicle(0)
  if not veh then return end

  veh:queueLuaCommand([[
    local throttleInput = input.lastInputs["local"].throttle or 0
    obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('pitsThrottleInput', throttleInput))
  ]])
end

-- Function to receive throttle input from vehicle
local function receiveThrottleInput(value)
  lastThrottleState = value
end

-- Function to apply speed limit to the vehicle
local function stopAndRepairInPit(veh, vel)
  veh:queueLuaCommand("input.event('throttle', 0, 1, nil, nil, nil, 'code')")
  veh:queueLuaCommand("input.event('brake', 0.85, 1, nil, nil, nil, 'code')")

  if vel < 1.0 then
    forcingStop = false
    applyingLimit = false
    log(
      "I",
      "pits",
      "Vehicle stopped and repaired, now applying regular speed limit of "
        .. math.floor(activeSpeedLimit * 3.6)
        .. " km/h"
    )
    if not overhaul_career_career then
      veh:queueLuaCommand([[
          recovery.startRecovering()
          recovery.stopRecovering()
        ]])
    end
    veh:queueLuaCommand([[
        input.event('brake', 0.5, 1, nil, nil, nil, 'code')
        input.event('throttle', 0.5, 1, nil, nil, nil, 'code')
        input.event('brake', 0, 1, nil, nil, nil, 'code')
        input.event('throttle', 0, 1, nil, nil, nil, 'code')
      ]])
  end
end

local function maintainPitSpeedLimit(veh, vel)
  requestThrottleInput()
  local wasLimiting = applyingLimit
  local speedRatio = 1.0 - (vel / activeSpeedLimit)
  if vel >= activeSpeedLimit then
    local overSpeed = vel - activeSpeedLimit
    local brakeAmount = math.min(1.0, overSpeed * 0.5)
    veh:queueLuaCommand("input.event('throttle', 0, 1, nil, nil, nil, 'code')")
    veh:queueLuaCommand("input.event('brake', " .. brakeAmount .. ", 1, nil, nil, nil, 'code')")
    applyingLimit = true
  else
    if lastThrottleState > 0.01 then
      local underSpeed = activeSpeedLimit - vel
      local proximityFactor = math.min(1.0, speedRatio * 2.0)
      local throttleAmount
      if speedRatio < 0.05 then
        throttleAmount = math.min(lastThrottleState, 0.20)
      elseif speedRatio < 0.15 then
        throttleAmount = math.min(lastThrottleState, lastThrottleState * proximityFactor + 0.1 * underSpeed)
      else
        throttleAmount = math.min(1.0, lastThrottleState + (underSpeed * 0.1 * proximityFactor))
      end
      veh:queueLuaCommand("input.event('throttle', " .. throttleAmount .. ", 1, nil, nil, nil, 'code')")
      veh:queueLuaCommand("input.event('brake', 0, 1)")
      applyingLimit = true
    else
      if wasLimiting then applyingLimit = false end
    end
  end
end

local function applySpeedLimit(dt)
  if not activeSpeedLimit or not limitActive then return end
  local veh = be:getPlayerVehicle(0)
  if not veh then return end
  local vel = veh:getVelocity():length()
  if forcingStop then
    stopAndRepairInPit(veh, vel)
    return
  end
  maintainPitSpeedLimit(veh, vel)
end

-- Function to set a speed limit with unit conversion
local function setSpeedLimit(limit, unit)
  if not limit or limit <= 0 then
    activeSpeedLimit = nil
    limitActive = false
    applyingLimit = false
    forcingStop = false
    log("I", "pits", "Speed limit disabled")
    return limitActive
  end

  -- Default unit is m/s if not specified
  local limitInMPS = limit
  local displayUnit = "m/s"
  local displayValue = limit

  if unit then
    unit = string.upper(unit)
    if unit == "MPH" then
      limitInMPS = limit * 0.44704 -- Convert mph to m/s
      displayUnit = "mph"
      displayValue = limit
    elseif unit == "KPH" then
      limitInMPS = limit * 0.27778 -- Convert kph to m/s
      displayUnit = "km/h"
      displayValue = limit
    end
  else
    -- When using m/s as input, we'll show km/h in the log for better readability
    displayUnit = "km/h"
    displayValue = math.floor(limit * 3.6)
  end

  activeSpeedLimit = limitInMPS
  limitActive = true

  -- Log the limit in both the input unit and m/s for clarity
  log(
    "I",
    "pits",
    "Speed limit set to " .. displayValue .. " " .. displayUnit .. " (" .. string.format("%.2f", limitInMPS) .. " m/s)"
  )

  return limitActive
end

-- Function to first stop the vehicle completely, then apply speed limit
local function stopThenLimit(limit, unit)
  -- First set the target speed limit
  setSpeedLimit(limit, unit)

  forcingStop = true
  limitActive = true

  log("I", "pits", "Stopping vehicle before applying speed limit...")

  return true
end

-- Hands throttle and brake back to the player's own last inputs after code-driven pit control.
local function releaseCodeInputs()
  local veh = be:getPlayerVehicle(0)
  if not veh then return end
  veh:queueLuaCommand([[
    local userInputs = input.lastInputs["local"] or {}
    input.event('throttle', userInputs.throttle or 0, 1)
    input.event('brake', userInputs.brake or 0, 1)
  ]])
end

-- Function to toggle the speed limit on/off without changing the value
local function toggleSpeedLimit()
  limitActive = not limitActive
  if limitActive and activeSpeedLimit then
    local speedKmh = math.floor(activeSpeedLimit * 3.6)
    log(
      "I",
      "pits",
      "Speed limit enabled: " .. speedKmh .. " km/h (" .. string.format("%.2f", activeSpeedLimit) .. " m/s)"
    )
  else
    releaseCodeInputs()
    log("I", "pits", "Speed limit disabled")
    forcingStop = false
  end
  return limitActive
end

local function clearSpeedLimit()
  if limitActive or forcingStop or applyingLimit then releaseCodeInputs() end
  activeSpeedLimit = nil
  limitActive = false
  applyingLimit = false
  forcingStop = false
  log("I", "pits", "Speed limit disabled")
end

-- Update function to be called in the vehicle update loop
local function onUpdate(dt)
  if activeSpeedLimit and limitActive then applySpeedLimit(dt) end
end

-- Register this module to receive updates

M.onUpdate = onUpdate
M.setSpeedLimit = setSpeedLimit
M.toggleSpeedLimit = toggleSpeedLimit
M.isSpeedLimitActive = function()
  return limitActive
end
M.stopThenLimit = stopThenLimit
M.receiveThrottleInput = receiveThrottleInput
M.clearSpeedLimit = clearSpeedLimit
return M
