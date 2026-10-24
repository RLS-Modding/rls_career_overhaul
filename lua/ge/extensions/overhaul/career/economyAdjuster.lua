-- Owns saved and transient reward multipliers and discovers activity types from owner data.
-- Read config, state, discovery, save handling, multiplier edits, rewards, lifecycle and public API in order.

-- Requires ----------------------------------------------------------------------------------------

local raceDataCatalog = require("overhaul/lib/events/raceDataCatalog")
local saveStore = require("overhaul/lib/save/store")
local economyManifest = require("overhaul/lib/career/economyManifest")
local activitySections = require("overhaul/lib/career/activitySections")
local optional = require("overhaul/lib/platform/optional")
-- Observational only: records the values used at each evaluation point; never read back here.
local rulesSnapshot = require("overhaul/lib/career/rulesSnapshot")
local M = {}

-- Save keys over the file this module writes (metadata only).
saveStore.registerKeys({
  {key = "rules.economyAdjuster", owner = "overhaul_career_economyAdjuster", files = {"career/rls_career/economyAdjuster.json"}, phase = "profile", required = true},
})

-- Config ------------------------------------------------------------------------------------------

local SAVE_DIR_SUFFIX = "/career/rls_career"
local SAVE_FILE_NAME = "economyAdjuster.json"
local MAX_TYPE_MULTIPLIER = 10
-- Surge and cool-down factors are clamped to these bounds; activityHeat applies tighter design clamps itself.
local TRANSIENT_FLOOR = 0.5
local TRANSIENT_CEIL = 5.0
-- A transient factor this close to 1.0 counts as cleared.
local TRANSIENT_CLEAR_EPSILON = 1e-6

-- State -------------------------------------------------------------------------------------------

local discoveredTypes = {}
local defaultTypeMultipliers = {}
local typeMultipliers = {}
-- Runtime surges never change saved multipliers or preset baselines.
local transientMultipliers = {}
local typeSources = {}
local isEnabled = true
local initialized = false
-- Economy sections (gameplay/overhaul/economy/), read once per extension instance.
local discovered = nil

-- Helpers -----------------------------------------------------------------------------------------

local function economySections()
  if not discovered then
    local scanned = economyManifest.scan()
    discovered = {
      typeAliases = economyManifest.typeAliases(scanned),
      manifestTypes = economyManifest.canonicalTypes(scanned),
      activitySections = activitySections.sections(),
    }
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

local function tableSize(tbl)
  if not tbl or type(tbl) ~= "table" then return 0 end
  local count = 0
  for _ in pairs(tbl) do
    count = count + 1
  end
  return count
end

-- Discovery ---------------------------------------------------------------------------------------

-- Race types from every compatible map's race data, plus the loaded level.
local function discoverRaceTypes()
  local compatibleMaps = {}
  if overhaul_world_maps then
    for id, label in pairs(overhaul_world_maps.getCompatibleMaps() or {}) do compatibleMaps[id] = label end
  end
  local currentLevel = getCurrentLevelIdentifier()
  if currentLevel then
    compatibleMaps[currentLevel] = currentLevel
  end

  local raceTypesFound = {}
  for mapName in pairs(compatibleMaps) do
    local raceData = raceDataCatalog.read(string.format("/levels/%s/race_data.json", mapName), true)
    for _, raceInfo in pairs((raceData and raceData.races) or {}) do
      if raceInfo.type and type(raceInfo.type) == "table" then
        for _, raceType in ipairs(raceInfo.type) do
          if type(raceType) == "string" then
            raceTypesFound[raceType] = true
            typeSources[raceType] = typeSources[raceType] or {}
            typeSources[raceType]["freeroam_module"] = true
            typeSources[raceType][string.format("race_%s", mapName)] = true
          end
        end
      end
    end
  end
  return raceTypesFound
end

local function addActivityType(activityTypesFound, typeName, sourceName)
  activityTypesFound[typeName] = true
  typeSources[typeName] = typeSources[typeName] or {}
  typeSources[typeName][sourceName] = true
end

-- Passenger types of the taxi section come from the owner's published list, one type per passenger key.
local function addPassengerTypes(activityTypesFound, section, owner)
  local passengerTypes = owner.getPassengerTypes()
  if not passengerTypes or type(passengerTypes) ~= "table" then return end
  for _, passengerType in ipairs(passengerTypes) do
    if passengerType.key then
      addActivityType(activityTypesFound, string.format("taxi_%s", passengerType.key:lower()), section.source)
    end
  end
end

-- Discover section keys from mounted data and each owner's published activity definition.
local function discoverActivityTypes()
  local activityTypesFound = {}
  for _, section in ipairs(economySections().activitySections) do
    local owner = section.extension and optional(section.extension) or nil
    if owner or not section.whenLoaded then
      for _, typeName in ipairs(activitySections.keys(section, owner)) do
        addActivityType(activityTypesFound, typeName, section.source)
      end
      if section.passengerTypes and owner.getPassengerTypes then
        addPassengerTypes(activityTypesFound, section, owner)
      end
    end
  end
  return activityTypesFound
end

-- A newly found type starts at 1.0; a type already saved keeps its value.
local function registerFoundTypes(foundTypes)
  for typeName in pairs(foundTypes) do
    if not discoveredTypes[typeName] then
      discoveredTypes[typeName] = true
      defaultTypeMultipliers[typeName] = 1.0
      if typeMultipliers[typeName] == nil then
        typeMultipliers[typeName] = 1.0
      end
    end
  end
end

local function initializeDiscoveredTypes()
  registerFoundTypes(discoverRaceTypes())
  registerFoundTypes(discoverActivityTypes())
end

-- Load and save ----------------------------------------------------------------------------------

-- The active profile's folder while a career is running, else nil (the defaults apply then).
local function activeSavePath()
  if not overhaul_career_career or not overhaul_career_career.isActive() then return nil end
  local _, path = overhaul_career_saveSystem.getCurrentProfile()
  return path
end

local function useDefaultMultipliers()
  typeMultipliers = deepcopy(defaultTypeMultipliers)
  rulesSnapshot.ruleChanged("load")
end

-- Types saved by an older version that discovery no longer finds keep their saved value.
local function keepLegacyTypes(savedMultipliers)
  for typeName, savedValue in pairs(savedMultipliers) do
    if typeMultipliers[typeName] == nil then
      typeMultipliers[typeName] = savedValue
      discoveredTypes[typeName] = true
      log("I", "economyAdjuster", string.format("Economy Adjuster: Preserving legacy type: %s", typeName))
    end
  end
end

local function loadMultipliers()
  local savePath = activeSavePath()
  if not savePath then
    useDefaultMultipliers()
    return
  end

  local data = jsonReadFile(savePath .. SAVE_DIR_SUFFIX .. "/" .. SAVE_FILE_NAME) or {}
  typeMultipliers = deepcopy(data.typeMultipliers or defaultTypeMultipliers)
  for typeName, defaultValue in pairs(defaultTypeMultipliers) do
    if typeMultipliers[typeName] == nil then
      typeMultipliers[typeName] = defaultValue
    end
  end
  if data.typeMultipliers then
    keepLegacyTypes(data.typeMultipliers)
  end

  isEnabled = data.enabled ~= false
  initialized = true
  rulesSnapshot.ruleChanged("load")
end

local function saveMultipliers(currentSavePath, writer)
  if not overhaul_career_career.isActive() then return end
  if not initialized then return end
  if not currentSavePath then return end

  local dirPath = currentSavePath .. SAVE_DIR_SUFFIX
  if not writer.exists(dirPath) then
    writer.mkdir(dirPath)
  end

  overhaul_career_saveSystem.jsonWriteFileSafe(dirPath .. "/" .. SAVE_FILE_NAME, {
    typeMultipliers = deepcopy(typeMultipliers),
    enabled = isEnabled,
    lastModified = os.time(),
  }, true)
end

-- Multiplier edits -------------------------------------------------------------------------------

local function setTypeMultiplier(typeName, multiplier, suppressSave)
  if not typeName then return false end
  typeName = normalizeTypeName(typeName)

  multiplier = math.max(0, math.min(MAX_TYPE_MULTIPLIER, tonumber(multiplier) or 1.0))
  typeMultipliers[typeName] = multiplier
  rulesSnapshot.ruleChanged("type")
  log("I", "economyAdjuster", string.format("Economy Adjuster: Set %s multiplier to %.2f", typeName, multiplier))
  return true
end

local function getTypeMultiplier(typeName)
  if not typeName then return 1.0 end
  typeName = normalizeTypeName(typeName)
  return typeMultipliers[typeName] or 1.0
end

local function setAllTypeMultipliers(multipliers)
  if not multipliers or type(multipliers) ~= "table" then return false end

  for typeName, multiplier in pairs(multipliers) do
    if type(multiplier) == "number" then
      setTypeMultiplier(typeName, multiplier, true)
    end
  end
  return true
end

local function resetToDefaults()
  typeMultipliers = deepcopy(defaultTypeMultipliers)
  rulesSnapshot.ruleChanged("reset")
  log("I", "economyAdjuster", "Economy Adjuster: Reset all multipliers to defaults")
  return true
end

local function setEnabled(enabled)
  isEnabled = enabled == true
  rulesSnapshot.ruleChanged("enabled")
  log("I", "economyAdjuster", string.format("Economy Adjuster: %s", isEnabled and "Enabled" or "Disabled"))
  return true
end

local function enableOnlyTypes(enabledTypes)
  if not enabledTypes or type(enabledTypes) ~= "table" then return false end

  for typeName in pairs(typeMultipliers) do
    typeMultipliers[typeName] = 0
  end
  for _, typeName in ipairs(enabledTypes) do
    if typeMultipliers[typeName] ~= nil then
      typeMultipliers[typeName] = 1.0
    end
  end
  rulesSnapshot.ruleChanged("enableOnly")

  log("I", "economyAdjuster", "Economy Adjuster: Enabled only types: " .. table.concat(enabledTypes, ", "))
  return true
end

local function disableTypes(disabledTypes)
  if not disabledTypes or type(disabledTypes) ~= "table" then return false end

  for _, typeName in ipairs(disabledTypes) do
    if typeMultipliers[typeName] ~= nil then
      typeMultipliers[typeName] = 0
    end
  end
  rulesSnapshot.ruleChanged("disable")

  log("I", "economyAdjuster", "Economy Adjuster: Disabled types: " .. table.concat(disabledTypes, ", "))
  return true
end

-- Type listings ----------------------------------------------------------------------------------

-- The shared manifest remains readable before career loads without requiring its policy owner.
local function getManifestTypes()
  local types = {}
  for i, typeName in ipairs(economySections().manifestTypes) do
    types[i] = typeName
  end
  return types
end

local function getAvailableTypes()
  initializeDiscoveredTypes()

  local types = {}
  local listed = {}
  for typeName in pairs(discoveredTypes) do
    table.insert(types, typeName)
    listed[typeName] = true
  end
  -- At the main menu the activity extensions are not loaded, so the challenge editor lists the manifest types too.
  if not overhaul_career_career.isActive() then
    for _, typeName in ipairs(getManifestTypes()) do
      if not listed[typeName] then
        listed[typeName] = true
        table.insert(types, typeName)
      end
    end
  end
  table.sort(types)
  return types
end

local function getTypesBySource()
  initializeDiscoveredTypes()

  local bySource = {}
  for typeName, sources in pairs(typeSources) do
    for sourceName in pairs(sources) do
      bySource[sourceName] = bySource[sourceName] or {}
      table.insert(bySource[sourceName], typeName)
    end
  end
  for _, types in pairs(bySource) do
    table.sort(types)
  end
  return bySource
end

local function getConfigurationSummary()
  return {
    enabled = isEnabled,
    multipliers = deepcopy(typeMultipliers),
    availableTypes = getAvailableTypes(),
    typesBySource = getTypesBySource(),
    discoveredTypes = tableSize(discoveredTypes),
  }
end

local function printConfiguration()
  log("I", "economyAdjuster", "\n=== Economy Adjuster Configuration ===")
  log("I", "economyAdjuster", string.format("System Enabled: %s", isEnabled and "Yes" or "No"))
  log("I", "economyAdjuster", string.format("Total Discovered Types: %d", tableSize(discoveredTypes)))

  for sourceName, types in pairs(getTypesBySource()) do
    log("I", "economyAdjuster", string.format("\n%s (%d types):", sourceName, #types))
    for _, typeName in ipairs(types) do
      log("I", "economyAdjuster", string.format("  %s: %.2f", typeName, typeMultipliers[typeName] or 1.0))
    end
  end

  log("I", "economyAdjuster", "\n=== Quick Reference ===")
  log("I", "economyAdjuster", "Available types: " .. table.concat(getAvailableTypes(), ", "))
  log("I", "economyAdjuster", "=====================================\n")
end

-- Section lookups --------------------------------------------------------------------------------

-- The parent module a section belongs to, read from its "<parent>_module" source.
local function getParentModuleName(sectionName)
  if not sectionName then return nil end

  local sources = typeSources[sectionName]
  if not sources then return nil end

  for sourceName in pairs(sources) do
    if sourceName:match("_module$") then
      local parentName = sourceName:gsub("_module$", "")
      if parentName ~= sectionName then
        return parentName
      end
    end
  end
  return nil
end

local function getTransientMultiplier(typeName)
  if not typeName then return 1.0 end
  return transientMultipliers[normalizeTypeName(typeName)] or 1.0
end

-- Set a transient (surge or cool-down) factor for a type. A value of 1.0 clears it.
local function setTransientMultiplier(typeName, value)
  if not typeName then return false end
  typeName = normalizeTypeName(typeName)
  value = tonumber(value)
  if not value then return false end

  value = math.max(TRANSIENT_FLOOR, math.min(TRANSIENT_CEIL, value))
  if math.abs(value - 1.0) < TRANSIENT_CLEAR_EPSILON then
    transientMultipliers[typeName] = nil
  else
    transientMultipliers[typeName] = value
  end
  rulesSnapshot.ruleChanged("transient")
  return true
end

local function clearTransientMultipliers()
  transientMultipliers = {}
  rulesSnapshot.ruleChanged("transient")
end

local function getTransientMultipliers()
  return deepcopy(transientMultipliers)
end

-- A disabled parent module disables its sections unless a section has its own non-default setting; the transient layer never revives a 0.
local function getSectionMultiplier(sectionName)
  if not sectionName then return 1.0 end

  local explicit = typeMultipliers[sectionName]
  local parentName = getParentModuleName(sectionName)
  local parentMultiplier = parentName and typeMultipliers[parentName]
  local hasOwnSetting = explicit ~= nil and explicit ~= 1.0
  if parentMultiplier == 0 and not hasOwnSetting then
    rulesSnapshot.section(sectionName, explicit, parentName, parentMultiplier, nil, 0)
    return 0
  end

  local base = explicit
  if base == nil then base = 1.0 end
  if base == 0 then
    rulesSnapshot.section(sectionName, explicit, parentName, parentMultiplier, nil, 0)
    return 0
  end

  local transient = getTransientMultiplier(sectionName)
  local result = base * transient
  rulesSnapshot.section(sectionName, explicit, parentName, parentMultiplier, transient, result)
  return result
end

local function getSectionMultipliers(sections)
  if not sections or type(sections) ~= "table" then return {} end

  local multipliers = {}
  for _, sectionName in ipairs(sections) do
    multipliers[sectionName] = getSectionMultiplier(sectionName)
  end
  return multipliers
end

-- The highest enabled multiplier among a reward's types; 0 when every type is disabled.
local function getEffectiveSectionMultiplier(sectionTypes)
  if not sectionTypes or type(sectionTypes) ~= "table" then
    return 1.0
  end

  if not isEnabled then
    rulesSnapshot.effective(sectionTypes, false, 1.0)
    return 1.0
  end

  local highestMultiplier = 0
  local hasEnabledType = false
  for _, sectionType in ipairs(sectionTypes) do
    local multiplier = getSectionMultiplier(sectionType)
    if multiplier > 0 then
      hasEnabledType = true
      if multiplier > highestMultiplier then
        highestMultiplier = multiplier
      end
    end
  end

  local result = hasEnabledType and highestMultiplier or 0
  rulesSnapshot.effective(sectionTypes, true, result)
  return result
end

local function isSectionEnabled(sectionTypes)
  if not sectionTypes or type(sectionTypes) ~= "table" then
    return true
  end
  if not isEnabled then
    return true
  end

  for _, sectionType in ipairs(sectionTypes) do
    if getSectionMultiplier(sectionType) > 0 then
      return true
    end
  end
  return false
end

-- Rewards ----------------------------------------------------------------------------------------

local function calculateAdjustedReward(raceData, baseReward)
  if not raceData then
    return baseReward or 0
  end

  local multiplier = getEffectiveSectionMultiplier(raceData.type or {})

  -- The job market index is layered on top of the per-activity multiplier.
  local jobIndex = 1.0
  if overhaul_career_career.isActive() then
    jobIndex = overhaul_career_economy_globalEconomy.getJobMarketIndex()
  end

  local adjustedReward = (baseReward or raceData.reward or 0) * multiplier * jobIndex
  local result = math.floor(adjustedReward + 0.5)
  rulesSnapshot.reward(raceData.type or {}, baseReward or raceData.reward or 0, multiplier, jobIndex, result)
  return result
end

local function adjustRaceData(raceData)
  if not raceData then return raceData end

  local adjusted = deepcopy(raceData)
  local multiplier = getEffectiveSectionMultiplier(raceData.type or {})
  if multiplier == 0 then
    adjusted.disabled = true
    adjusted.adjustedReward = 0
  else
    adjusted.disabled = false
    adjusted.originalReward = adjusted.reward
    adjusted.adjustedReward = calculateAdjustedReward(raceData, adjusted.reward)
    adjusted.multiplier = multiplier
  end
  return adjusted
end

local function filterEnabledRaces(races)
  if not races then return {} end

  local enabledRaces = {}
  for raceName, raceData in pairs(races) do
    if isSectionEnabled(raceData.type or {}) then
      enabledRaces[raceName] = adjustRaceData(raceData)
    end
  end
  return enabledRaces
end

-- Lifecycle --------------------------------------------------------------------------------------

local function initialize()
  if initialized then return end

  initializeDiscoveredTypes()
  loadMultipliers()
  log("I", "economyAdjuster", "Economy Adjuster module initialized with " .. tableSize(discoveredTypes) .. " discovered types")
end

local function refreshDiscoveredTypes()
  log("I", "economyAdjuster", "Economy Adjuster: Refreshing discovered types...")
  initializeDiscoveredTypes()

  for typeName in pairs(discoveredTypes) do
    if typeMultipliers[typeName] == nil then
      typeMultipliers[typeName] = 1.0
    end
  end
  log("I", "economyAdjuster", "Economy Adjuster: Refreshed types, now managing " .. tableSize(discoveredTypes) .. " total types")
end

local function onExtensionLoaded()
  initialize()
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  saveMultipliers(currentSavePath, writer)
end

-- Reload before onOverhaulActive reapplies policy and challenge settings.
local function onOverhaulModulesActivated()
  if not initialized then
    initializeDiscoveredTypes()
  end
  rulesSnapshot.reset()
  transientMultipliers = {}
  isEnabled = true
  loadMultipliers()
end

local function onOverhaulActive(active)
  if not active then
    transientMultipliers = {}
    rulesSnapshot.reset()
  end
end

-- Public API --------------------------------------------------------------------------------------

M.calculateAdjustedReward = calculateAdjustedReward
M.getSectionMultiplier = getSectionMultiplier
M.getSectionMultipliers = getSectionMultipliers
M.getEffectiveSectionMultiplier = getEffectiveSectionMultiplier
M.isSectionEnabled = isSectionEnabled
M.setTypeMultiplier = setTypeMultiplier
M.getTypeMultiplier = getTypeMultiplier
M.setAllTypeMultipliers = setAllTypeMultipliers
M.getTransientMultiplier = getTransientMultiplier
M.setTransientMultiplier = setTransientMultiplier
M.clearTransientMultipliers = clearTransientMultipliers
M.getTransientMultipliers = getTransientMultipliers
M.resetToDefaults = resetToDefaults
M.setEnabled = setEnabled
M.enableOnlyTypes = enableOnlyTypes
M.disableTypes = disableTypes
M.getAvailableTypes = getAvailableTypes
M.getTypesBySource = getTypesBySource
M.getConfigurationSummary = getConfigurationSummary
M.printConfiguration = printConfiguration
M.adjustRaceData = adjustRaceData
M.filterEnabledRaces = filterEnabledRaces
M.refreshDiscoveredTypes = refreshDiscoveredTypes
M.isEnabled = function() return isEnabled end
M.getTypeMultipliers = function() return deepcopy(typeMultipliers) end
M.getDiscoveredTypes = function() return deepcopy(discoveredTypes) end
M.getTypeSources = function() return deepcopy(typeSources) end
M.getRulesSnapshot = rulesSnapshot.get
M.getRulesSnapshots = rulesSnapshot.list
M.getRulesRevision = rulesSnapshot.revision
M.onExtensionLoaded = onExtensionLoaded
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onOverhaulActive = onOverhaulActive

return M
