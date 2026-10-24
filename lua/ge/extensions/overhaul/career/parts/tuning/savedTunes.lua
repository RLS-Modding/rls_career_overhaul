-- Saved tuning values and slot-scoped tune files.
-- Names and paths preserve existing saves; missing values keep the owner fallback.
local M = {}

M.VERSION = 1

local MAX_NAME_LENGTH = 40

local function deepCopy(value, seen)
  if type(value) ~= "table" then return value end
  seen = seen or {}
  if seen[value] then return seen[value] end
  local result = {}
  seen[value] = result
  for key, child in pairs(value) do
    result[deepCopy(key, seen)] = deepCopy(child, seen)
  end
  return result
end

local function trim(value)
  if type(value) ~= "string" then return nil end
  return value:match("^%s*(.-)%s*$")
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function utf8Length(value)
  local _, count = value:gsub("[^\128-\193]", "")
  return count
end

local function isDenseArray(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
  end
  return count == #value
end

local function validateTune(tune)
  if type(tune) ~= "table" then return false, "invalid_tune" end
  if type(tune.id) ~= "string" or tune.id == "" then return false, "invalid_tune_id" end
  local name = trim(tune.name)
  if not name or name == "" or utf8Length(name) > MAX_NAME_LENGTH then return false, "invalid_tune_name" end
  if not isFiniteNumber(tune.createdAt) or not isFiniteNumber(tune.updatedAt) then
    return false, "invalid_tune_timestamp"
  end
  if type(tune.variables) ~= "table" then return false, "invalid_tune_variables" end
  return true
end

local function findTune(group, tuneId)
  if not group then return nil end
  for index, tune in ipairs(group.tunes or {}) do
    if tune.id == tuneId then return tune, index end
  end
end

-- The tune with this name, compared without case; nil when the model has none.
local function findTuneByName(group, normalizedName)
  for index, tune in ipairs(group.tunes) do
    if string.lower(trim(tune.name)) == string.lower(normalizedName) then return tune, index end
  end
end

-- A replacement keeps the id and creation time of the tune it replaces.
local function replacementTune(duplicate, normalizedName, now, variables)
  return {
    id = duplicate.id,
    name = normalizedName,
    createdAt = duplicate.createdAt,
    updatedAt = now,
    variables = deepCopy(variables),
  }
end

local function newTune(options, normalizedName, now, variables)
  local idFactory = options.idFactory or Engine.generateUUID
  return {
    id = tostring(idFactory()),
    name = normalizedName,
    createdAt = now,
    updatedAt = now,
    variables = deepCopy(variables),
  }
end

function M.newLibrary()
  return {version = M.VERSION, models = {}}
end

function M.validateLibrary(data)
  if type(data) ~= "table" then return false, "invalid_root" end
  if data.version ~= M.VERSION then return false, "unsupported_version" end
  if type(data.models) ~= "table" then return false, "invalid_models" end

  for modelKey, group in pairs(data.models) do
    if type(modelKey) ~= "string" or modelKey == "" then return false, "invalid_model_key" end
    if type(group) ~= "table" or not isDenseArray(group.tunes) then return false, "invalid_model_group" end
    local ids, names = {}, {}
    for _, tune in ipairs(group.tunes) do
      local valid, reason = validateTune(tune)
      if not valid then return false, reason end
      local normalizedName = string.lower(trim(tune.name))
      if ids[tune.id] then return false, "duplicate_tune_id" end
      if names[normalizedName] then return false, "duplicate_tune_name" end
      ids[tune.id] = true
      names[normalizedName] = true
    end
  end
  return true
end

function M.loadState(fileExists, decoded)
  if not fileExists then
    return {data = M.newLibrary(), readOnly = false}
  end
  if decoded == nil then
    return {data = nil, readOnly = true, error = "unreadable_file"}
  end
  local valid, reason = M.validateLibrary(decoded)
  if not valid then
    return {data = nil, readOnly = true, error = reason}
  end
  return {data = decoded, readOnly = false}
end

function M.normalizeModelKey(modelKey)
  local normalized = trim(modelKey)
  if not normalized or normalized == "" then return nil end
  return string.lower(normalized)
end

function M.validateName(name)
  local normalized = trim(name)
  if not normalized or normalized == "" then return false, "name_required" end
  if utf8Length(normalized) > MAX_NAME_LENGTH then return false, "name_too_long" end
  if normalized:find("[%z\1-\31\127]") then return false, "name_has_control_characters" end
  return true, normalized
end

function M.findTune(data, modelKey, tuneId)
  local key = M.normalizeModelKey(modelKey)
  local group = key and data and data.models and data.models[key] or nil
  return findTune(group, tuneId)
end

function M.listTunes(data, modelKey)
  local key = M.normalizeModelKey(modelKey)
  local group = key and data and data.models and data.models[key] or nil
  local result = {}
  for _, tune in ipairs(group and group.tunes or {}) do
    local variableCount = 0
    for _ in pairs(tune.variables or {}) do variableCount = variableCount + 1 end
    result[#result + 1] = {
      id = tune.id,
      name = tune.name,
      createdAt = tune.createdAt,
      updatedAt = tune.updatedAt,
      variableCount = variableCount,
    }
  end
  table.sort(result, function(a, b)
    local aName, bName = string.lower(a.name), string.lower(b.name)
    if aName == bName then return a.id < b.id end
    return aName < bName
  end)
  return result
end

-- Returns the candidate library and a result; a duplicate name is refused unless replaceExisting is set.
function M.upsertTune(data, modelKey, name, variables, replaceExisting, options)
  local key = M.normalizeModelKey(modelKey)
  if not key then return nil, {success = false, reason = "invalid_model_key"} end
  local validName, normalizedName = M.validateName(name)
  if not validName then return nil, {success = false, reason = normalizedName} end
  if type(variables) ~= "table" or next(variables) == nil then
    return nil, {success = false, reason = "empty_snapshot"}
  end

  options = options or {}
  local now = tonumber(options.now) or os.time()
  local candidate = deepCopy(data)
  candidate.models[key] = candidate.models[key] or {tunes = {}}
  local group = candidate.models[key]
  local duplicate, duplicateIndex = findTuneByName(group, normalizedName)

  if duplicate and not replaceExisting then
    return nil, {
      success = false,
      reason = "duplicate_name",
      duplicate = {id = duplicate.id, name = duplicate.name},
    }
  end

  local tune = nil
  if duplicate then
    tune = replacementTune(duplicate, normalizedName, now, variables)
    group.tunes[duplicateIndex] = tune
  else
    tune = newTune(options, normalizedName, now, variables)
    group.tunes[#group.tunes + 1] = tune
  end

  return candidate, {success = true, tune = deepCopy(tune), replaced = duplicate ~= nil}
end

function M.deleteTune(data, modelKey, tuneId)
  local key = M.normalizeModelKey(modelKey)
  local group = key and data and data.models and data.models[key] or nil
  local _, index = findTune(group, tuneId)
  if not index then return nil, {success = false, reason = "tune_not_found"} end
  local candidate = deepCopy(data)
  table.remove(candidate.models[key].tunes, index)
  if #candidate.models[key].tunes == 0 then candidate.models[key] = nil end
  return candidate, {success = true}
end

-- Commits the candidate only when the writer accepts it; otherwise the current library is returned unchanged.
function M.commit(currentData, candidate, writer)
  if type(writer) ~= "function" or not writer(candidate) then
    return currentData, false
  end
  return candidate, true
end

M.deepCopy = deepCopy
M.isFiniteNumber = isFiniteNumber

return M
