-- Numeric, timing, random-pick and contract-blocking helpers shared by the freeroam progression files.
-- Pure functions except the contract block, which reads the live event session.
local M = {}

local FREEROAM_CONTRACT_BLOCK_MSG =
  "You can't accept contracts during a freeroam race or while staged at an event. Finish or leave the event first."

function M.roundTo(value, places)
  local decimalScale = math.pow(10, places or 0)
  return math.floor(value * decimalScale + 0.5) / decimalScale
end

function M.clamp(value, minValue, maxValue)
  if value < minValue then return minValue end
  if value > maxValue then return maxValue end
  return value
end

function M.randomFloat(minValue, maxValue)
  if minValue == nil then minValue = 0 end
  if maxValue == nil then maxValue = minValue end
  if maxValue < minValue then
    minValue, maxValue = maxValue, minValue
  end
  return minValue + (maxValue - minValue) * math.random()
end

function M.randomInt(minValue, maxValue)
  minValue = math.floor(minValue or 0)
  maxValue = math.floor(maxValue or minValue)
  if maxValue < minValue then
    minValue, maxValue = maxValue, minValue
  end
  return math.random(minValue, maxValue)
end

function M.pickRandomFromList(list)
  if type(list) ~= "table" or #list == 0 then return nil end
  return list[M.randomInt(1, #list)]
end

function M.pickEarlierTime(currentNext, candidate)
  local candidateTime = tonumber(candidate)
  if not candidateTime then return currentNext end
  if not currentNext or candidateTime < currentNext then return candidateTime end
  return currentNext
end

function M.pickWeightedBonusType(weightTable)
  local entries = {}
  local totalWeight = 0
  for key, value in pairs(weightTable or {}) do
    local weight = tonumber(value) or 0
    if weight > 0 then
      totalWeight = totalWeight + weight
      entries[#entries + 1] = { key = key, weight = weight }
    end
  end
  if totalWeight <= 0 then return "money" end
  local roll = M.randomFloat(0, totalWeight)
  local cumulativeWeight = 0
  for _, entry in ipairs(entries) do
    cumulativeWeight = cumulativeWeight + entry.weight
    if roll < cumulativeWeight then return entry.key end
  end
  return entries[#entries].key
end

function M.tableHasAnyEntries(value)
  if type(value) ~= "table" then return false end
  for _ in pairs(value) do
    return true
  end
  return false
end

function M.formatTimeForRequirement(seconds)
  local totalSeconds = math.max(0, tonumber(seconds) or 0)
  local minutes = math.floor(totalSeconds / 60)
  local remainingSeconds = math.min(math.max(totalSeconds - (minutes * 60), 0), 59.999)
  if minutes >= 1 then
    return string.format("%d:%02d", minutes, math.floor(remainingSeconds))
  elseif remainingSeconds >= 10 then
    return string.format("%.1f", math.floor(remainingSeconds * 10) / 10)
  end
  return string.format("%.2f", math.floor(remainingSeconds * 100) / 100)
end

function M.isFreeroamEventBlockingContracts()
  local eventSession = overhaul_events_session
  if type(eventSession) ~= "table" then return false end
  return (eventSession.mActiveRace or eventSession.staged or eventSession.dragPracticeActive) and true or false
end

function M.getFreeroamEventContractBlockMessage()
  if M.isFreeroamEventBlockingContracts() then return FREEROAM_CONTRACT_BLOCK_MSG end
  return nil
end

return M
