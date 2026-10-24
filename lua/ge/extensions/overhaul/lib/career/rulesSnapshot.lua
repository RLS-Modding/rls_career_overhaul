-- Observational rules snapshots: the economy adjuster, its sandbox policy and the XP policy record the rule
-- values they used. Nothing reads a snapshot back into a computation; readers get copies.
local M = {}

local revision = 0    -- bumped on every rule change the adjuster or a policy makes
local lastChange = nil
local sequence = 0
local latest = {}     -- latest[point][key] = snapshot

-- Field names of each evaluation point, in the order the public functions take their values.
local SECTION_FIELDS = {"explicit", "parent", "parentMultiplier", "transient", "result"}
local EFFECTIVE_FIELDS = {"enabled", "result"}
local REWARD_FIELDS = {"baseReward", "multiplier", "jobIndex", "result"}
local EXPERIENCE_FIELDS = {"challengeActive", "difficultyActive", "global", "relative", "result"}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, inner in pairs(value) do out[key] = copy(inner) end
  return out
end

local function store(point, key, values)
  sequence = sequence + 1
  local byKey = latest[point]
  if not byKey then
    byKey = {}
    latest[point] = byKey
  end
  byKey[key] = {point = point, key = key, revision = revision, sequence = sequence, values = values}
end

-- An identical evaluation retains the snapshot so steady frames do not allocate replacements.
local function storeScalars(point, key, names, ...)
  local byKey = latest[point]
  local current = byKey and byKey[key]
  if current and current.revision == revision then
    local same, values = true, current.values
    for i = 1, #names do
      if values[names[i]] ~= select(i, ...) then
        same = false
        break
      end
    end
    if same then return end
  end
  local values = {}
  for i = 1, #names do values[names[i]] = select(i, ...) end
  store(point, key, values)
end

local function keyOf(value)
  if value == nil then return "" end
  return tostring(value)
end

-- A list of section types as one key, element by element (entries need not be strings).
local function listKey(list)
  if type(list) ~= "table" then return keyOf(list) end
  local parts = {}
  for i, value in ipairs(list) do parts[i] = tostring(value) end
  return table.concat(parts, ",")
end

function M.ruleChanged(reason)
  revision = revision + 1
  lastChange = reason
end

function M.section(sectionName, explicit, parent, parentMultiplier, transient, result)
  storeScalars("economy.section", keyOf(sectionName), SECTION_FIELDS, explicit, parent, parentMultiplier, transient, result)
end

function M.effective(sectionTypes, enabled, result)
  storeScalars("economy.effective", listKey(sectionTypes), EFFECTIVE_FIELDS, enabled, result)
end

function M.reward(sectionTypes, baseReward, multiplier, jobIndex, result)
  storeScalars("economy.reward", listKey(sectionTypes), REWARD_FIELDS, baseReward, multiplier, jobIndex, result)
end

function M.xp(progressionKey, challengeActive, difficultyActive, global, relative, result)
  storeScalars("xp.multiplier", keyOf(progressionKey), EXPERIENCE_FIELDS, challengeActive, difficultyActive, global, relative, result)
end

-- Capture only values the policy computed; snapshots never feed changes back into the policy.
function M.policy(outcome, globalMultiplier, profile, finals)
  store("economy.policy", "rebuild", {
    outcome = outcome,
    global = globalMultiplier,
    profile = copy(profile),
    finals = copy(finals),
  })
end

function M.get(point, key)
  local byKey = latest[point]
  return copy(byKey and byKey[key == nil and "" or key])
end

function M.list(point)
  return copy(latest[point] or {})
end

function M.revision()
  return revision, lastChange
end

-- Career start and stop: snapshots never cross into another career or profile.
function M.reset()
  revision = 0
  lastChange = nil
  sequence = 0
  latest = {}
end

return M
