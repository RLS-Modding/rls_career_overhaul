local M = {}

local function roundTo(value, places)
  local mult = math.pow(10, places or 0)
  return math.floor(value * mult + 0.5) / mult
end

local function randomFloat(minValue, maxValue)
  if minValue == nil then
    minValue = 0
  end
  if maxValue == nil then
    maxValue = minValue
  end
  if maxValue < minValue then
    minValue, maxValue = maxValue, minValue
  end
  return minValue + (maxValue - minValue) * math.random()
end

local function randomInt(minValue, maxValue)
  minValue = math.floor(minValue or 0)
  maxValue = math.floor(maxValue or minValue)
  if maxValue < minValue then
    minValue, maxValue = maxValue, minValue
  end
  return math.random(minValue, maxValue)
end

local function clamp(value, minValue, maxValue)
  if value < minValue then
    return minValue
  end
  if value > maxValue then
    return maxValue
  end
  return value
end

local function pickRandomFromList(list)
  if type(list) ~= "table" or #list == 0 then
    return nil
  end
  return list[randomInt(1, #list)]
end

local function pickEarlierTime(currentNext, candidate)
  local value = tonumber(candidate)
  if not value then
    return currentNext
  end
  if not currentNext or value < currentNext then
    return value
  end
  return currentNext
end

local function tableHasAnyEntries(value)
  if type(value) ~= "table" then
    return false
  end
  for _, _ in pairs(value) do
    return true
  end
  return false
end

local function formatTimeForRequirement(seconds)
  local total = math.max(0, tonumber(seconds) or 0)
  local minutes = math.floor(total / 60)
  local secs = math.min(math.max(total - (minutes * 60), 0), 59.999)
  if minutes >= 1 then
    return string.format("%d:%02d", minutes, math.floor(secs))
  elseif secs >= 10 then
    local display = math.floor(secs * 10) / 10
    return string.format("%.1f", display)
  else
    local display = math.floor(secs * 100) / 100
    return string.format("%.2f", display)
  end
end

local FREEROAM_CONTRACT_BLOCK_MSG =
  "You can't accept contracts during a freeroam race or while staged at an event. Finish or leave the event first."

local function isFreeroamEventBlockingContracts()
  local fs = gameplay_events_freeroam_session
  if type(fs) ~= "table" then
    return false
  end
  if fs.mActiveRace then
    return true
  end
  if fs.staged then
    return true
  end
  if fs.dragPracticeActive then
    return true
  end
  return false
end

local function getFreeroamEventContractBlockMessage()
  if isFreeroamEventBlockingContracts() then
    return FREEROAM_CONTRACT_BLOCK_MSG
  end
  return nil
end

local function pickWeightedBonusType(weightTable)
  local entries = {}
  local total = 0
  for key, value in pairs(weightTable or {}) do
    local weight = tonumber(value) or 0
    if weight > 0 then
      total = total + weight
      entries[#entries + 1] = {key = key, weight = weight}
    end
  end
  if total <= 0 then
    return "money"
  end
  local roll = randomFloat(0, total)
  local running = 0
  for _, entry in ipairs(entries) do
    running = running + entry.weight
    if roll < running then
      return entry.key
    end
  end
  return entries[#entries].key
end

M.roundTo = roundTo
M.randomFloat = randomFloat
M.randomInt = randomInt
M.clamp = clamp
M.pickRandomFromList = pickRandomFromList
M.pickEarlierTime = pickEarlierTime
M.tableHasAnyEntries = tableHasAnyEntries
M.formatTimeForRequirement = formatTimeForRequirement
M.pickWeightedBonusType = pickWeightedBonusType
M.isFreeroamEventBlockingContracts = isFreeroamEventBlockingContracts
M.getFreeroamEventContractBlockMessage = getFreeroamEventContractBlockMessage

return M
