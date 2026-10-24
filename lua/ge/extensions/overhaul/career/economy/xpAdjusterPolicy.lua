-- Sandbox XP profile: per-progression-key XP multipliers, scaled on top of the global difficulty XP multiplier.
-- Saved to career/rls_career/sandboxXpProfile.json; rulesSnapshot records what was used and nothing reads it back here.
local M = {}

-- SaveStore keys over the files this module writes (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "options.sandboxXp", owner = "overhaul_career_economy_xpAdjusterPolicy", files = {"career/rls_career/sandboxXpProfile.json"}, phase = "profile", required = true},
})

local rulesSnapshot = require("overhaul/lib/career/rulesSnapshot")
local store = require("overhaul/lib/save/optionsStore").new("sandboxXpProfile.json")

local DEFAULT_RELATIVE = 1.0
local MIN_RELATIVE = 0.25
local MAX_RELATIVE = 3.0

-- Mirrors the economyAdjusterPolicy umbrella tree; each child names the skill key it scales.
local XP_SECTIONS = {
  {id = "offroad", label = "Off-Road", children = {{id = "offroad", label = "Off-Road", skillKey = "careerSkills-offroad"}}},
  {id = "speed", label = "Speed", children = {{id = "speed", label = "Speed", skillKey = "careerSkills-speed"}}},
  {id = "mayhem", label = "Mayhem", children = {{id = "mayhem", label = "Mayhem", skillKey = "careerSkills-mayhem"}}},
  {id = "circuitRacing", label = "Circuit Racing", children = {{id = "circuitRacing", label = "Circuit Racing", skillKey = "careerSkills-circuitRacing"}}},
  {id = "emergency", label = "Emergency", children = {{id = "emergency", label = "Emergency", skillKey = "careerSkills-emergency"}}},
  {id = "passenger", label = "Passenger", children = {{id = "passenger", label = "Passenger", skillKey = "careerSkills-passenger"}}},
  {id = "operator", label = "Operator", children = {{id = "operator", label = "Operator", skillKey = "careerSkills-operator"}}},
  {id = "recovery", label = "Recovery", children = {{id = "recovery", label = "Recovery", skillKey = "careerSkills-recovery"}}},
  {id = "logistics", label = "Logistics", children = {{id = "logistics", label = "Logistics", skillKey = "logistics-delivery"}}},
  {id = "gambling", label = "Gambling", children = {{id = "gambling", label = "Gambling", skillKey = "careerSkills-gambling"}}},
  {id = "stamina", label = "Stamina", children = {{id = "stamina", label = "Stamina", skillKey = "stamina"}}},
}

-- Skill keys that cover several activities average those activities' umbrella multipliers.
local SKILL_KEY_ACTIVITIES = {
  ["careerSkills-police"] = {"police"},
  ["careerSkills-paramedic"] = {"paramedic"},
  ["careerSkills-bus"] = {"bus"},
  ["careerSkills-civilService"] = {"police", "paramedic", "bus"},
  ["careerSkills-emergency"] = {"police", "paramedic"},
  ["careerSkills-taxi"] = {"taxi"},
  ["careerSkills-passenger"] = {"taxi", "bus"},
  ["careerSkills-repo"] = {"repo"},
  ["careerSkills-offroadRecovery"] = {"offroadRecovery"},
  ["careerSkills-recovery"] = {"repo", "offroadRecovery"},
  ["careerSkills-offroad"] = {"rally", "offroad", "crawling", "mudding", "trail"},
  ["careerSkills-drift"] = {"drift"},
  ["careerSkills-mayhem"] = {"drift", "demo", "burnout"},
  ["careerSkills-drag"] = {"drag"},
  ["careerSkills-speed"] = {"drag", "landspeed"},
  ["careerSkills-roadracing"] = {"roadracing"},
  ["careerSkills-circuitRacing"] = {"oval", "roadracing"},
  ["logistics-delivery"] = {"logistics"},
}

-- Activation hooks can fire repeatedly; loaded memory is newer than disk.
local profileLoaded = false
local profileData = {
  umbrellas = {},
}

local skillKeyToUmbrellaId = {}
local manifestSkillKeys = {}
local initialized = false

local function clampRelative(value)
  local num = tonumber(value)
  if not num then
    return DEFAULT_RELATIVE
  end
  if num < MIN_RELATIVE then
    return MIN_RELATIVE
  end
  if num > MAX_RELATIVE then
    return MAX_RELATIVE
  end
  return num
end

local function buildManifestIndexes()
  skillKeyToUmbrellaId = {}
  manifestSkillKeys = {}

  for _, section in ipairs(XP_SECTIONS) do
    for _, child in ipairs(section.children or {}) do
      if type(child.skillKey) == "string" and child.skillKey ~= "" then
        skillKeyToUmbrellaId[child.skillKey] = child.id
        manifestSkillKeys[child.skillKey] = true
      end
    end
  end
  initialized = true
end

local function getRelativeForSkillKey(skillKey)
  if not initialized then
    buildManifestIndexes()
  end

  if type(skillKey) ~= "string" or skillKey == "" then
    return DEFAULT_RELATIVE
  end

  local umbrellas = profileData.umbrellas or {}

  local activityIds = SKILL_KEY_ACTIVITIES[skillKey]
  if activityIds then
    local sum, count = 0, 0
    for _, activityId in ipairs(activityIds) do
      if type(umbrellas[activityId]) == "number" then
        sum = sum + clampRelative(umbrellas[activityId])
        count = count + 1
      end
    end
    if count > 0 then
      return clampRelative(sum / count)
    end
  end

  local umbrellaId = skillKeyToUmbrellaId[skillKey]
  if umbrellaId and type(umbrellas[umbrellaId]) == "number" then
    return clampRelative(umbrellas[umbrellaId])
  end

  return DEFAULT_RELATIVE
end

local function sanitizeProfileTable(raw)
  local sanitized = { umbrellas = {} }
  if type(raw) ~= "table" then
    return sanitized
  end

  if type(raw.umbrellas) == "table" then
    for umbrellaId, value in pairs(raw.umbrellas) do
      if type(umbrellaId) == "string" and type(value) == "number" then
        local clamped = clampRelative(value)
        if math.abs(clamped - DEFAULT_RELATIVE) > 0.001 then
          sanitized.umbrellas[umbrellaId] = clamped
        end
      end
    end
  end

  return sanitized
end

local function saveProfileData(currentSavePath, writer)
  if not overhaul_career_career.isActive() then
    return
  end

  local savePath = currentSavePath
  if not savePath then
    return
  end

  store.ensureDir(savePath, writer)
  local payload = {
    umbrellas = deepcopy(profileData.umbrellas or {}),
    lastModified = os.time(),
  }
  store.write(savePath, payload)
end

local function consumePendingProfile()
  local pending = overhaul_career_career.pendingSandboxXpProfile
  overhaul_career_career.pendingSandboxXpProfile = nil
  M.pendingSandboxXpProfile = nil

  if type(pending) ~= "table" then
    return nil
  end
  return sanitizeProfileTable(pending)
end

local function loadProfileData(allowPending)
  local pending = allowPending and consumePendingProfile() or nil
  if pending then
    profileData = pending
    profileLoaded = true
    return
  end
  if profileLoaded then
    return
  end

  local savePath = store.currentSavePath()
  if not savePath then
    profileData = { umbrellas = {} }
    return
  end

  local loaded = store.read(savePath)
  profileData = sanitizeProfileTable(loaded)
  profileLoaded = true
end

local function isChallengeActive()
  return overhaul_career_challengeModes.isChallengeActive() == true
end

local function getGlobalXpMultiplier()
  local value = overhaul_career_economy_difficultyMode.getXPMultiplier()
  if type(value) == "number" and value > 0 then
    return value
  end
  return 1.0
end

local function getEffectiveMultiplierForKey(progressionKey)
  if isChallengeActive() then
    local globalMultiplier = getGlobalXpMultiplier()
    rulesSnapshot.xp(progressionKey, true, nil, globalMultiplier, nil, globalMultiplier)
    return globalMultiplier
  end
  if not overhaul_career_economy_difficultyMode.isDifficultyActive() then
    rulesSnapshot.xp(progressionKey, false, false, nil, nil, 1.0)
    return 1.0
  end

  local globalMultiplier = getGlobalXpMultiplier()
  local relative = getRelativeForSkillKey(progressionKey)
  local result = globalMultiplier * relative
  rulesSnapshot.xp(progressionKey, false, true, globalMultiplier, relative, result)
  return result
end

local function onCareerActivated()
  if not overhaul_career_career.isActive() then
    return
  end
  loadProfileData(true)
end

local function onOverhaulActive(active, newSave)
  if not active then
    profileData = { umbrellas = {} }
    profileLoaded = false
    return false
  end
  loadProfileData(newSave == true)
  return true
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveProfileData(currentSavePath, writer)
end

M.getEffectiveMultiplierForKey = getEffectiveMultiplierForKey

M.onCareerActivated = onCareerActivated
M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
