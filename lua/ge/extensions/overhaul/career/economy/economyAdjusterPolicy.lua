-- Sandbox economy profile: writes per-type economy multipliers from the difficulty multiplier and the profile's umbrella and type sliders.
-- Saved to career/rls_career/sandboxEconomyProfile.json; rulesSnapshot records each rebuild and nothing reads it back here.
local M = {}

-- SaveStore keys over the files this module writes (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "options.sandboxEconomy", owner = "overhaul_career_economy_economyAdjusterPolicy", files = {"career/rls_career/sandboxEconomyProfile.json"}, phase = "profile", required = true},
})

local economyManifest = require("overhaul/lib/career/economyManifest")
local rulesSnapshot = require("overhaul/lib/career/rulesSnapshot")
local store = require("overhaul/lib/save/optionsStore").new("sandboxEconomyProfile.json")

-- Config ---------------------------------------------------------------------------------------------

local LOG_TAG = "economyAdjusterPolicy"
local DEFAULT_RELATIVE = 1.0
local MIN_RELATIVE = 0.25
local MAX_RELATIVE = 3.0

-- State ----------------------------------------------------------------------------------------------

-- Canonical umbrella manifest (Lua source of truth for switchboard wiring), scanned from gameplay/overhaul/economy/sections/ once per extension instance.
local discovered = nil

-- Activation hooks can fire repeatedly; loaded memory is newer than disk.
local profileLoaded = false
local profileData = {
  umbrellas = {},
  expanded = {},
}

local keyToUmbrellaId = {}
local manifestEconomyKeys = {}
local initialized = false
-- What the last rebuild wrote and the adjuster state right after it.
local lastApplied = nil

-- Manifest -------------------------------------------------------------------------------------------

local function economySections()
  if not discovered then
    local scanned = economyManifest.scan()
    discovered = {sections = economyManifest.sections(scanned), typeAliases = economyManifest.typeAliases(scanned)}
  end
  return discovered
end

local function normalizeTypeName(typeName)
  if type(typeName) ~= "string" or typeName == "" then
    return typeName
  end
  local alias = economySections().typeAliases[typeName:lower()]
  return alias or typeName
end

local function buildManifestIndexes()
  keyToUmbrellaId = {}
  manifestEconomyKeys = {}

  for _, section in ipairs(economySections().sections) do
    for _, child in ipairs(section.children or {}) do
      for _, economyKey in ipairs(child.economyKeys or {}) do
        keyToUmbrellaId[economyKey] = child.id
        manifestEconomyKeys[economyKey] = true
        local normalized = normalizeTypeName(economyKey)
        if normalized and normalized ~= economyKey then
          keyToUmbrellaId[normalized] = child.id
          manifestEconomyKeys[normalized] = true
        end
      end
    end
  end
  initialized = true
end

-- Clamping and lookup --------------------------------------------------------------------------------

local function sameValues(a, b)
  for key, value in pairs(a) do
    if b[key] ~= value then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

-- True when writing these values would leave the adjuster exactly as it is: nothing changed it since the last rebuild and every value is one that rebuild already stored.
local function isAlreadyApplied(finals)
  local adjuster = overhaul_career_economyAdjuster
  if not lastApplied then return false end
  if not sameValues(lastApplied.state, adjuster.getTypeMultipliers()) then return false end
  for typeName, value in pairs(finals) do
    if lastApplied.finals[typeName] == nil then return false end
    if adjuster.getTypeMultiplier(typeName) ~= math.max(0, math.min(10, value)) then return false end
  end
  return true
end

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

local function isChallengeActive()
  return overhaul_career_challengeModes.isChallengeActive() == true
end

local function getGlobalRewardMultiplier()
  local value = overhaul_career_economy_difficultyMode.getRewardMultiplier()
  if type(value) == "number" and value > 0 then
    return value
  end
  return 1.0
end

local function getRelativeForType(typeName)
  if not initialized then
    buildManifestIndexes()
  end

  local expandedValue = profileData.expanded and profileData.expanded[typeName]
  if type(expandedValue) == "number" then
    return clampRelative(expandedValue)
  end

  local umbrellaId = keyToUmbrellaId[typeName] or (typeName:find("^taxi_") and "taxi")
  if umbrellaId and profileData.umbrellas and type(profileData.umbrellas[umbrellaId]) == "number" then
    return clampRelative(profileData.umbrellas[umbrellaId])
  end

  return DEFAULT_RELATIVE
end

-- Persistence ----------------------------------------------------------------------------------------

local function sanitizeProfileTable(raw)
  local sanitized = { umbrellas = {}, expanded = {} }
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

  if type(raw.expanded) == "table" then
    for economyKey, value in pairs(raw.expanded) do
      if type(economyKey) == "string" and type(value) == "number" then
        local clamped = clampRelative(value)
        if math.abs(clamped - DEFAULT_RELATIVE) > 0.001 then
          sanitized.expanded[economyKey] = clamped
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
    expanded = deepcopy(profileData.expanded or {}),
    lastModified = os.time(),
  }
  store.write(savePath, payload)
end

local function consumePendingProfile()
  local pending = overhaul_career_career.pendingSandboxEconomyProfile
  overhaul_career_career.pendingSandboxEconomyProfile = nil
  M.pendingSandboxEconomyProfile = nil

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
    profileData = { umbrellas = {}, expanded = {} }
    return
  end

  local loaded = store.read(savePath)
  profileData = sanitizeProfileTable(loaded)
  profileLoaded = true
end

-- Rebuild steps --------------------------------------------------------------------------------------

-- Types to write: everything the adjuster already lists, plus manifest types whose value would change.
local function listTypesToWrite(globalMultiplier)
  local availableTypes = {}
  local listed = {}
  for _, typeName in ipairs(overhaul_career_economyAdjuster.getAvailableTypes() or {}) do
    if not listed[typeName] then
      listed[typeName] = true
      table.insert(availableTypes, typeName)
    end
  end
  -- Manifest types whose activity is not loaded yet still get the difficulty and slider value.
  local manifestTypes = tableKeys(manifestEconomyKeys)
  table.sort(manifestTypes)
  local getTypeMultiplier = overhaul_career_economyAdjuster.getTypeMultiplier
  for _, typeName in ipairs(manifestTypes) do
    if not listed[typeName] and normalizeTypeName(typeName) == typeName then
      listed[typeName] = true
      -- An unset type already pays 1.0x, so only write the ones that change.
      local final = globalMultiplier * getRelativeForType(typeName)
      if getTypeMultiplier(typeName) ~= final then
        table.insert(availableTypes, typeName)
      end
    end
  end
  return availableTypes
end

-- Final multiplier per type (difficulty times the profile's relative value), and the types no manifest maps.
local function computeFinals(availableTypes, globalMultiplier)
  local finals = {}
  local unmapped = {}
  for _, typeName in ipairs(availableTypes) do
    local relative = getRelativeForType(typeName)
    finals[typeName] = globalMultiplier * relative

    if not manifestEconomyKeys[typeName] and not keyToUmbrellaId[typeName] then
      table.insert(unmapped, typeName)
    end
  end
  return finals, unmapped
end

local function reportUnmapped(unmapped)
  if #unmapped == 0 then return end
  log("D", "economyAdjusterPolicy", string.format("Economy Adjuster Policy: %d unmapped type(s): %s", #unmapped, table.concat(unmapped, ", ")))
end

-- Profile application --------------------------------------------------------------------------------

local function rebuild()
  if isChallengeActive() then
    rulesSnapshot.policy("challengeActive")
    return false
  end
  if not initialized then
    buildManifestIndexes()
  end

  local globalMultiplier = getGlobalRewardMultiplier()
  local availableTypes = listTypesToWrite(globalMultiplier)
  if #availableTypes == 0 then
    rulesSnapshot.policy("noTypes", globalMultiplier, profileData)
    return false
  end

  local finals, unmapped = computeFinals(availableTypes, globalMultiplier)

  if isAlreadyApplied(finals) then
    rulesSnapshot.policy("alreadyApplied", globalMultiplier, profileData, finals)
    return true
  end

  reportUnmapped(unmapped)
  overhaul_career_economyAdjuster.setAllTypeMultipliers(finals)
  lastApplied = {finals = finals, state = overhaul_career_economyAdjuster.getTypeMultipliers()}
  rulesSnapshot.policy("applied", globalMultiplier, profileData, finals)
  return true
end

local function setProfileFromUI(rawProfile)
  profileData = sanitizeProfileTable(rawProfile)
  profileLoaded = true
  return rebuild()
end

local function getManifestForUI()
  if not initialized then
    buildManifestIndexes()
  end
  return deepcopy(economySections().sections)
end

local function getProfileForUI()
  return deepcopy(profileData)
end

-- Lifecycle ------------------------------------------------------------------------------------------

local function onCareerActivated()
  if not overhaul_career_career.isActive() then
    return
  end
  loadProfileData(true)
end

local function onOverhaulActive(active, newSave)
  if not active then
    profileData = { umbrellas = {}, expanded = {} }
    profileLoaded = false
    lastApplied = nil
    return false
  end
  loadProfileData(newSave == true)
  return rebuild()
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveProfileData(currentSavePath, writer)
end

-- Public API -----------------------------------------------------------------------------------------

M.rebuild = rebuild
M.getManifestForUI = getManifestForUI
M.getProfileForUI = getProfileForUI
M.setProfileFromUI = setProfileFromUI
M.sanitizeProfileTable = sanitizeProfileTable

-- Game hooks -----------------------------------------------------------------------------------------

M.onCareerActivated = onCareerActivated
M.onOverhaulActive = onOverhaulActive
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
