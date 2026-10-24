-- Clock app: sends the in-game time to the phone as a 12-hour string, once per in-game minute.
-- Read time formatting and emission, then update, lifecycle and the public request API.
local M = {}
local clock = require('overhaul/lib/phone/clock')

local TIME_EVENT = "phone_time_update"
local MINUTES_PER_DAY = 1440

local lastSentTime = nil
local lastSentMinute = nil

-- BeamNG TimeOfDay uses 0=noon and 0.5=midnight, so shift it to a midnight-based clock first.
local formatTime = clock.format

local function currentTimeOfDay()
  return scenetree.tod and scenetree.tod.time
end

local function sendTime(timeOfDay)
  lastSentMinute = math.floor(timeOfDay * MINUTES_PER_DAY)
  lastSentTime = formatTime(timeOfDay)
  guihooks.trigger(TIME_EVENT, lastSentTime)
end

local function sendCurrentTime()
  local timeOfDay = currentTimeOfDay()
  if timeOfDay ~= nil then sendTime(timeOfDay) end
end

function M.onUpdate()
  local timeOfDay = currentTimeOfDay()
  if timeOfDay == nil then return end
  local minute = math.floor(timeOfDay * MINUTES_PER_DAY)
  if minute == lastSentMinute then return end

  local formatted = formatTime(timeOfDay)
  lastSentMinute = minute
  if formatted ~= lastSentTime then
    lastSentTime = formatted
    guihooks.trigger(TIME_EVENT, formatted)
  end
end

function M.onExtensionLoaded()
  sendCurrentTime()
end

function M.clearTime()
  lastSentTime = nil
  lastSentMinute = nil
end

M.requestTime = sendCurrentTime

return M
