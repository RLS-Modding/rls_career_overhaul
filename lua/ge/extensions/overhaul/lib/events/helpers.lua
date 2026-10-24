-- Pure event identity, authored scene bindings, time displays and lap scaling.
-- Catalog ids stay whole at every scene/strip boundary; no map state is retained.
local M = {}

local function formatTime(seconds)
  local sign = seconds < 0 and "-" or ""
  seconds = math.abs(seconds)

  local minutes = math.floor(seconds / 60)
  local remainingSeconds = seconds % 60
  local wholeSeconds = math.floor(remainingSeconds)
  local hundredths = math.floor((remainingSeconds - wholeSeconds) * 100)

  return string.format("%s%02d:%02d:%02d", sign, minutes, wholeSeconds, hundredths)
end

local function tableContains(tbl, val)
  if type(tbl) ~= "table" then return false end
  for _, v in ipairs(tbl) do
    if v == val then return true end
  end
  return false
end

local function hotlapMultiplier(lapCount)
  return (10 / (1 + math.exp(-0.07 * (lapCount - 17)))) - 1.35
end

local function raceHasType(race, discipline)
  return type(race) == "table" and tableContains(race.type, discipline)
end

-- Scene-name grammar is matched against whole catalog keys; underscores are part of the id.
-- Explicit bindings take precedence, including names outside the fre_ authoring grammar.
local TRIGGER_ROLES = { staging = true, start = true, checkpoint = true, finish = true, pits = true, hub = true }
local function sceneTriggerNames(raceId, race, role)
  local names = {}
  for name, binding in pairs(type(race) == "table" and race.triggerNames or {}) do
    if type(binding) == "table" and binding.eventType == role then names[#names + 1] = name end
  end
  if #names == 0 then names[1] = "fre_" .. role .. "_" .. raceId end
  table.sort(names)
  return names
end

local function resolveTrigger(races, name)
  if type(name) ~= "string" or type(races) ~= "table" then return nil end
  local explicit
  for raceId, race in pairs(races) do
    local binding = race.triggerNames and race.triggerNames[name]
    if binding then
      if explicit then return nil, "ambiguous trigger binding: " .. name end
      if type(binding) ~= "table" or not TRIGGER_ROLES[binding.eventType] then
        return nil, "invalid trigger binding: " .. name
      end
      local index = binding.checkpointIndex
      if binding.eventType == "checkpoint" and (type(index) ~= "number" or index < 1 or index % 1 ~= 0) then
        return nil, "invalid checkpoint binding: " .. name
      end
      explicit = { eventType = binding.eventType, raceId = raceId, checkpointIndex = index,
        altRoute = binding.altRoute == true, aiAlt = binding.aiAlt == true }
    end
  end
  if explicit then return explicit end

  local role, tail = name:match("^fre_([^_]+)_(.+)$")
  if not TRIGGER_ROLES[role] then return nil end
  if role ~= "checkpoint" then
    if races[tail] then return { eventType = role, raceId = tail } end
    return nil
  end
  local matched
  for raceId in pairs(races) do
    local prefix = raceId .. "_"
    if tail:sub(1, #prefix) == prefix then
      local suffix = tail:sub(#prefix + 1)
      local index = suffix:match("^(%d+)$")
      local altIndex = suffix:match("^alt_(%d+)$")
      local aiIndex = suffix:match("^ai_alt_(%d+)$")
      index = tonumber(index or altIndex or aiIndex)
      if index and index > 0 then
        if matched then return nil, "ambiguous checkpoint name: " .. name end
        matched = { eventType = role, raceId = raceId, checkpointIndex = index,
          altRoute = altIndex ~= nil, aiAlt = aiIndex ~= nil }
      end
    end
  end
  return matched
end

-- A stock drag settings id and a strip id are different. Only the authored strip binding selects an event.
-- Multiple events on one strip require an explicit event id (or the already staged/active matching event).
local function resolveDragRace(races, dragData, preferredId)
  local stripId = dragData and dragData.strip and dragData.strip.id
  if type(stripId) ~= "string" or stripId == "" then return nil, "drag strip id is missing" end
  local function matches(id)
    local race = races and races[id]
    return raceHasType(race, "drag") and race.dragStripId == stripId
  end
  local eventId = dragData.eventId
  if eventId ~= nil then
    if matches(eventId) then return eventId, races[eventId] end
    return nil, "drag event binding does not match this strip"
  end
  if preferredId and matches(preferredId) then return preferredId, races[preferredId] end
  local found
  for id in pairs(races or {}) do
    if matches(id) then
      if found then return nil, "multiple drag events bind this strip; supply eventId" end
      found = id
    end
  end
  if found then return found, races[found] end
  return nil, "no drag event binds this strip"
end

M.formatTime = formatTime
M.tableContains = tableContains
M.hotlapMultiplier = hotlapMultiplier
M.raceHasType = raceHasType
M.sceneTriggerNames = sceneTriggerNames
M.resolveTrigger = resolveTrigger
M.resolveDragRace = resolveDragRace
return M
