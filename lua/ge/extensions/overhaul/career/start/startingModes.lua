-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Normalizes career start choices and writes start-time save files before activation.
-- Read option helpers, mode catalog, start steps, create-or-load and the per-career public API in order.
local M = {}

-- Requires ----------------------------------------------------------------------------------------

local difficultyModePersist = require('overhaul/lib/career/difficultyPersist')
local saveSlots = require('overhaul/career/start/saveSlots')
local contributorCatalog = require('overhaul/career/start/contributorCatalog')
local jsonCatalog = require("overhaul/lib/platform/jsonCatalog")
local levelData = require('overhaul/lib/world/levelData')

local STARTING_MODES_DIR = "/gameplay/overhaul/startingModes/"

-- Option normalizers ------------------------------------------------------------------------------

local function resolveDifficultyMode(candidate, hardcoreFallback)
  return difficultyModePersist.resolveMode(candidate, hardcoreFallback)
end

local function normalizeDifficultyOverrides(xpMultiplier, economyMultiplier, startingCash)
  local overrides = {}

  if type(xpMultiplier) == "number" and xpMultiplier > 0 then
    overrides.xpMultiplier = xpMultiplier
  end
  if type(economyMultiplier) == "number" and economyMultiplier > 0 then
    overrides.rewardMultiplier = economyMultiplier
  end
  if type(startingCash) == "number" and startingCash >= 0 then
    overrides.startingCapital = math.floor(startingCash + 0.5)
  end

  if next(overrides) then
    return overrides
  end
  return nil
end

local function normalizeSandboxEconomyProfile(rawProfile)
  if type(rawProfile) ~= "table" then
    return nil
  end

  local umbrellas = type(rawProfile.umbrellas) == "table" and rawProfile.umbrellas or nil
  local expanded = type(rawProfile.expanded) == "table" and rawProfile.expanded or nil
  if (not umbrellas or not next(umbrellas)) and (not expanded or not next(expanded)) then
    return nil
  end

  return {
    umbrellas = umbrellas and deepcopy(umbrellas) or {},
    expanded = expanded and deepcopy(expanded) or {},
  }
end

local function normalizeSandboxXpProfile(rawProfile)
  if type(rawProfile) ~= "table" then
    return nil
  end

  local umbrellas = type(rawProfile.umbrellas) == "table" and rawProfile.umbrellas or nil
  if not umbrellas or not next(umbrellas) then
    return nil
  end

  return {
    umbrellas = deepcopy(umbrellas),
  }
end

local function normalizeStartingGaragePreference(mode, garageId)
  local normalizedMode = type(mode) == "string" and string.lower(mode) or "default"
  if normalizedMode ~= "default" and normalizedMode ~= "none" then
    normalizedMode = "default"
  end

  local normalizedGarageId = nil
  if normalizedMode == "default" and type(garageId) == "string" and garageId ~= "" then
    normalizedGarageId = garageId
  end

  return {
    mode = normalizedMode,
    garageId = normalizedGarageId
  }
end

local function resolveCareerStartMode(candidate)
  if type(candidate) ~= "string" then
    return nil
  end
  local normalized = string.lower(candidate)
  if normalized == "freeroam" or normalized == "story" or normalized == "sandbox"
      or normalized == "hardcore" or normalized == "career" or normalized == "custom" then
    return normalized
  end
  return nil
end

-- Starting-mode catalog ---------------------------------------------------------------------------

local function validateStartingModeManifest(data)
  if type(data.module) ~= "string" or not data.module:match("^/lua/[%w_/%.-]+%.lua$")
      or data.module:find("..", 1, true) then
    return nil, "module must be an absolute Lua VFS path"
  end
  return data
end

-- The valid manifests in order, and the rejected files.
local function scanStartingModes()
  return jsonCatalog.scan(STARTING_MODES_DIR, validateStartingModeManifest, "overhaul_startingModeCatalog")
end

-- The Lua VFS path of every valid mode, in order.
local function getStartingModeFiles()
  local files = {}
  for _, entry in ipairs(scanStartingModes()) do files[#files + 1] = entry.module end
  return files
end

-- Each mode is loaded with dofile rather than require, so its callbacks belong to that mode and are not held in a require cache.
-- Loads one catalog entry's mode file. Returns its data, or nil when it fails, has another id, or is ignored.
local function loadStartingMode(entry)
  local loadedOk, modeData = pcall(dofile, entry.module)
  if loadedOk and type(modeData) == "table" and modeData.id == entry.id and not modeData.ignore then
    return modeData
  end
  return nil
end

local function sanitizeStartingModeForUi(modeData, entry)
  return {
    id = modeData.id,
    order = entry.order or modeData.order,
    tier = modeData.tier,
    title = modeData.title,
    description = modeData.description,
    image = modeData.image,
    tag = modeData.tag,
  }
end

-- Lower order first, then by id, so a missing order sorts last.
local function startingModeComesFirst(a, b)
  local ao = tonumber(a.order) or math.huge
  local bo = tonumber(b.order) or math.huge
  if ao ~= bo then
    return ao < bo
  end
  return tostring(a.id) < tostring(b.id)
end

local function getStartingModeOptions()
  local options = {}
  for _, entry in ipairs(scanStartingModes()) do
    local modeData = loadStartingMode(entry)
    if modeData then
      table.insert(options, sanitizeStartingModeForUi(modeData, entry))
    else
      log("W", "career.startingModes", string.format("Unable to load starting mode from '%s'", tostring(entry.module)))
    end
  end

  table.sort(options, startingModeComesFirst)
  return deepcopy(options)
end

-- Start steps -------------------------------------------------------------------------------------

-- Removes what is inside a folder, one level deep, and leaves the folder itself.
local function clearDirectoryContents(directory)
  if not FS:directoryExists(directory) then return end
  for _, file in ipairs(FS:findFiles(directory, "*", -1, false, false)) do
    if FS:fileExists(file) then
      FS:removeFile(file)
    elseif FS:directoryExists(file) then
      FS:directoryRemove(file)
    end
  end
end

-- Clears the pending choices left by an earlier start, and the publishes that mirror them.
local function resetPendingCareerChoices(career, start)
  career.publish("pendingChallengeId", nil)
  start.pendingStartingOptions = nil
  start.pendingDifficultyMode = nil
  start.pendingDifficultyOverrides = nil
  start.pendingExperimentalMaintenanceEnabled = nil
  start.pendingPoliceEnabled = nil
  start.pendingEmploymentApprenticeship = nil
  start.pendingStartingGaragePreference = nil
  start.pendingCareerStartMode = nil
  start.pendingCheatsMode = nil
  start.pendingSandboxEconomyProfile = nil
  start.pendingSandboxXpProfile = nil
  career.publish("pendingCareerStartMode", nil)
  career.publish("pendingSandboxEconomyProfile", nil)
  career.publish("pendingSandboxXpProfile", nil)
  career.publish("cheatsMode", false)
  start.startingGaragePreference = nil
  career.publish("startingGaragePreference", nil)
  career.publish("pendingExperimentalMaintenanceEnabled", nil)
  career.publish("pendingPoliceEnabled", nil)
  career.publish("pendingEmploymentApprenticeship", nil)
  career.publish("experimentalMaintenanceEnabled", nil)
  career.publish("policeEnabled", nil)
end

-- A new profile starts from an empty career folder; a challenge keeps its own rls_career files.
local function clearFreshCareerProfile(savePath, challengeId)
  clearDirectoryContents(savePath .. "/career")
  if not challengeId then
    clearDirectoryContents(savePath .. "/career/rls_career")
  end
  overhaul_career_saveMigration.stampCurrentLayout(savePath)
end

-- Choices for a save that has never been written: pending state, then the files modules read at activation.
local function applyNewSaveChoices(career, start, request, savePath)
  local selectedDifficultyMode = resolveDifficultyMode(request.difficultyMode, request.hardcore == true)
  if selectedDifficultyMode == "hardcore" then
    log("I","","Hardcore mode enabled.")
  end
  career.publish("hardcoreMode", selectedDifficultyMode == "hardcore")
  start.pendingDifficultyMode = selectedDifficultyMode
  start.pendingDifficultyOverrides = normalizeDifficultyOverrides(request.xpMultiplier, request.economyMultiplier, request.startingCash)
  -- Persist before modules activate so a crash/reload cannot lose hardcore.
  difficultyModePersist.writeModeToSave(savePath, selectedDifficultyMode, start.pendingDifficultyOverrides)
  start.pendingExperimentalMaintenanceEnabled = request.experimentalMaintenanceEnabled == true
  -- Hardcore always starts with no garage, regardless of UI payload.
  if selectedDifficultyMode == "hardcore" then
    start.pendingStartingGaragePreference = normalizeStartingGaragePreference("none", nil)
  else
    start.pendingStartingGaragePreference = normalizeStartingGaragePreference(request.startingGarageMode, request.startingGarageId)
  end
  career.publish("startingGaragePreference", deepcopy(start.pendingStartingGaragePreference))
  career.publish("pendingExperimentalMaintenanceEnabled", start.pendingExperimentalMaintenanceEnabled)
  career.publish("experimentalMaintenanceEnabled", start.pendingExperimentalMaintenanceEnabled)
  start.pendingPoliceEnabled = request.policeEnabled ~= false
  career.publish("pendingPoliceEnabled", start.pendingPoliceEnabled)
  career.publish("policeEnabled", start.pendingPoliceEnabled)
  -- Write before activation so the first autosave cannot replace the pending preference with its default.
  contributorCatalog.writePendingDefault("pendingPoliceEnabled", start, savePath)
  start.pendingEmploymentApprenticeship = request.employmentApprenticeship ~= false
  career.publish("pendingEmploymentApprenticeship", start.pendingEmploymentApprenticeship)
  contributorCatalog.writePendingDefault("pendingEmploymentApprenticeship", start, savePath, "profile")
  start.pendingCareerStartMode = resolveCareerStartMode(request.careerStartMode)
  career.publish("pendingCareerStartMode", start.pendingCareerStartMode)
  start.pendingSandboxEconomyProfile = normalizeSandboxEconomyProfile(request.sandboxEconomyProfile)
  career.publish("pendingSandboxEconomyProfile", start.pendingSandboxEconomyProfile and deepcopy(start.pendingSandboxEconomyProfile) or nil)
  start.pendingSandboxXpProfile = normalizeSandboxXpProfile(request.sandboxXpProfile)
  career.publish("pendingSandboxXpProfile", start.pendingSandboxXpProfile and deepcopy(start.pendingSandboxXpProfile) or nil)
end

-- An existing save only syncs the hardcore flag from disk, and records a legacy employment answer if one came in.
local function applyExistingSaveChoices(career, start, request, savePath)
  local savedDifficulty = difficultyModePersist.readModeFromSave(savePath)
  if savedDifficulty then
    career.publish("hardcoreMode", savedDifficulty == "hardcore")
  else
    career.publish("hardcoreMode", false)
  end
  if request.employmentApprenticeship ~= nil then
    start.pendingEmploymentApprenticeship = request.employmentApprenticeship == true
    career.publish("pendingEmploymentApprenticeship", start.pendingEmploymentApprenticeship)
    contributorCatalog.writePendingDefault("pendingEmploymentApprenticeship", start, savePath, "legacyModal")
  end
end

-- A challenge can select its map; difficulty never substitutes another map's placement.
local function chooseStartingMap(request)
  local mapToUse = request.startingMap
  local challengeMap = false
  if request.challengeId then
    local challengeOptions = overhaul_career_challengeModes.getChallengeOptionsForCareerCreation()
    if challengeOptions then
      for _, challenge in ipairs(challengeOptions) do
        if challenge.id == request.challengeId and challenge.map then
          mapToUse = challenge.map
          challengeMap = true
          break
        end
      end
    end
  end
  if mapToUse then return mapToUse, challengeMap end
  return levelData.defaultMap()
end

-- Modules usually unload synchronously; bound the wait so a stuck reference cannot
-- freeze profile loads behind the loading screen forever.
local function waitForPlayerAttributesUnload(job)
  local waited = 0
  if overhaul_career_economy_playerAttributes then
    log("D", "", "Waiting for player attributes to be unloaded...")
  end
  while overhaul_career_economy_playerAttributes and waited < 5 do
    job.sleep(0.05)
    waited = waited + 0.05
  end
  if overhaul_career_economy_playerAttributes then
    log("W", "", "playerAttributes still loaded after wait; continuing career load anyway")
  end
end

-- Autosaves left by an unfinished new career would otherwise be read as its history.
local function removeUnfinishedAutosaves(slotPath)
  for i = 1, 3 do
    local autosaveDir = slotPath .. "/autosave" .. i
    if FS:directoryExists(autosaveDir) then
      FS:directoryRemove(autosaveDir)
    end
  end
end

local function abortCareerStart(career)
  career.setStartInProgress(false)
  core_gamestate.requestExitLoadingScreen('careerLoading')
end

local function writeContributedStartDefaults(career, start, savePath)
  if contributorCatalog.writeStartDefaults(start, savePath) then return true end
  abortCareerStart(career)
  guihooks.trigger('toastrMsg', {type = 'error', title = 'Career could not start',
    msg = 'Start options could not be saved. Please try again.'})
  return false
end

local function preparedStartingMap(career, request)
  local startingMap, challengeMap = chooseStartingMap(request)
  local difficulty = resolveDifficultyMode(request.difficultyMode, request.hardcore == true)
  if startingMap and levelData.startPolicy(startingMap, difficulty).available then return startingMap, challengeMap end
  log('E', 'career', 'Career start unavailable: configure the selected map start metadata')
  abortCareerStart(career)
  guihooks.trigger('toastrMsg', {type = 'error', title = 'Career could not start',
    msg = 'The selected map does not provide this career start.'})
end

local function selectPreparedProfile(request)
  if overhaul_career_saveSystem.isSavePending() then
    log("W", "", "Career start blocked; a save began while waiting to switch profiles")
    guihooks.trigger('toastrMsg', {type='info', title='Waiting for career save', msg='Please try opening the profile again when saving finishes.'})
    return false
  end
  return overhaul_career_saveSystem.setProfile(request.name, request.specificAutosave)
end

local function publishPreparedChoices(career, start, request, savePath, isNewSave)
  start.pendingStartingOptions = request.startingOptions or {}
  career.publish("startingOptions", deepcopy(start.pendingStartingOptions))

  if isNewSave then
    applyNewSaveChoices(career, start, request, savePath)
  else
    applyExistingSaveChoices(career, start, request, savePath)
  end
  if request.cheats then
    log("I","","Cheats mode enabled.")
  end
  start.pendingCheatsMode = request.cheats and true or false
  career.publish("cheatsMode", start.pendingCheatsMode)
  if request.challengeId then
    log("I","","Challenge enabled for later start: " .. request.challengeId)
  end
  career.publish("pendingChallengeId", request.challengeId)
end

-- Runs in the start job: selects the profile, writes its start choices, and activates the career.
local function startPreparedCareerProfile(career, start, job, request)
  waitForPlayerAttributesUnload(job)
  local name, specificAutosave = request.name, request.specificAutosave
  local slotPath = overhaul_career_saveSystem.getSaveRootDirectory() .. name
  local folderName = require('overhaul/lib/save/pathComponent').valid(name)
  local saveState = folderName and saveSlots.getProfileSaveState(name, specificAutosave) or 'new'
  local isNewSave = saveState == 'new'
  if saveState == 'unreadable' then
    saveSlots.refuseUnreadableSave(name, specificAutosave)
    abortCareerStart(career)
    return
  end
  local startingMap, challengeMap
  if isNewSave then
    startingMap, challengeMap = preparedStartingMap(career, request)
    if not startingMap then return end
    if folderName then removeUnfinishedAutosaves(slotPath) end
  end
  if not selectPreparedProfile(request) then
    abortCareerStart(career)
    return
  end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if savePath and isNewSave then clearFreshCareerProfile(savePath, request.challengeId) end
  publishPreparedChoices(career, start, request, savePath, isNewSave)

  if isNewSave and not writeContributedStartDefaults(career, start, savePath) then return end
  if challengeMap then log('I', '', 'Using challenge map: ' .. startingMap) end
  career.activateCareer(true, isNewSave and startingMap or request.startingMap)
end

-- Create-or-load ----------------------------------------------------------------------------------

-- The options table (the third argument) overrides the positional values it names. Prefer it:
-- .39's Lua bridge types the 3rd arg as Object.
local function applyStartingOptions(request, startingOptions)
  request.startingOptions = startingOptions
  request.legacyMigrationApproved = startingOptions.legacyMigrationApproved == true
  if startingOptions.hardcoreMode ~= nil then
    request.hardcore = startingOptions.hardcoreMode
  else
    request.hardcore = startingOptions.hardcore
  end
  request.challengeId = startingOptions.challengeId or startingOptions.challengeSelection
  if startingOptions.cheatsMode ~= nil then
    request.cheats = startingOptions.cheatsMode
  else
    request.cheats = startingOptions.cheats
  end
  request.startingMap = startingOptions.startingMap
  request.difficultyMode = startingOptions.difficultyMode
  request.experimentalMaintenanceEnabled = startingOptions.experimentalMaintenanceEnabled
  request.startingGarageMode = startingOptions.startingGarageMode
  request.startingGarageId = startingOptions.startingGarageId
  if startingOptions.policeEnabled ~= nil then
    request.policeEnabled = startingOptions.policeEnabled
  end
  request.xpMultiplier = startingOptions.xpMultiplier
  request.economyMultiplier = startingOptions.economyMultiplier
  request.startingCash = startingOptions.startingCash
  -- Overhaul UI sends careerStartMode; vanilla .39 sends startMode.
  request.careerStartMode = startingOptions.careerStartMode or startingOptions.startMode
  request.sandboxEconomyProfile = startingOptions.sandboxEconomyProfile
  request.sandboxXpProfile = startingOptions.sandboxXpProfile
  if startingOptions.employmentApprenticeship ~= nil then
    request.employmentApprenticeship = startingOptions.employmentApprenticeship
  end
end

-- A legacy save loads only once its migrated copy is prepared; until then the migration screen opens instead.
local function legacyMigrationBlocks(career, request)
  -- Display-only names describe new careers; never probe their raw paths.
  if not require('overhaul/lib/save/pathComponent').valid(request.name) then return false end
  local migrationReport = overhaul_career_saveMigration.getLegacySavePreflight(request.name, request.specificAutosave)
  if not (migrationReport and migrationReport.requiresMigration) then
    return false
  end
  local prepared = overhaul_career_saveMigration.isPreparedMigration(request.name, request.specificAutosave)
  if request.legacyMigrationApproved and prepared then
    return false
  end
  -- Nothing is going to load, so drop the migration screen the UI raised for us.
  career.endLegacySaveMigrationLoading()
  overhaul_career_saveMigration.requestLegacySaveMigration(migrationReport)
  log(
    "I",
    "career.migration",
    string.format(
      "Blocked direct legacy load for %s/%s until a migrated copy is prepared",
      tostring(request.name),
      tostring(request.specificAutosave)
    )
  )
  return true
end

-- Puts the loading screen up and clears the previous start's choices before the start job runs.
local function beginStartLoading(career, start, request)
  core_gamestate.requestEnterLoadingScreen("careerLoading")
  -- careerLoading now holds the screen up, so hand it over without letting it close.
  career.endLegacySaveMigrationLoading()
  career.resetLoadingIntro()
  career.setStartInProgress(true)
  if career.isActive() then
    career.deactivateCareer()
  end

  resetPendingCareerChoices(career, start)

  log("I","",string.format("Create or Load Career: %s - %s", request.name, request.specificAutosave))
end

-- Accepts either v39 style (name, specificAutosave, startingOptionsTable)
-- or overhaul positional args (name, specificAutosave, tutorial, hardcore, ...).
local function createOrLoadCareerAndStart(career, start, name, specificAutosave, tutorial, hardcore, challengeId, cheats, startingMap, difficultyMode,
                                          experimentalMaintenanceEnabled, startingGarageMode, startingGarageId, policeEnabled,
                                          xpMultiplier, economyMultiplier, startingCash, careerStartMode, sandboxEconomyProfile,
                                          sandboxXpProfile)
  if overhaul_shell_extensionManager.refuseCareerStart() then
    return false
  end
  local paths = require('overhaul/lib/save/pathComponent')
  if not paths.displayName(name) or (specificAutosave ~= nil
    and (not paths.valid(name) or not paths.valid(specificAutosave))) then return false end
  local requestedArgs = {name, specificAutosave, tutorial, hardcore, challengeId, cheats, startingMap, difficultyMode,
    experimentalMaintenanceEnabled, startingGarageMode, startingGarageId, policeEnabled, xpMultiplier,
    economyMultiplier, startingCash, careerStartMode, sandboxEconomyProfile, sandboxXpProfile}

  local request = {
    name = name, specificAutosave = specificAutosave, challengeId = challengeId, hardcore = hardcore, cheats = cheats,
    startingMap = startingMap, difficultyMode = difficultyMode, experimentalMaintenanceEnabled = experimentalMaintenanceEnabled,
    policeEnabled = policeEnabled, startingGarageMode = startingGarageMode, startingGarageId = startingGarageId,
    xpMultiplier = xpMultiplier, economyMultiplier = economyMultiplier, startingCash = startingCash,
    careerStartMode = careerStartMode, sandboxEconomyProfile = sandboxEconomyProfile, sandboxXpProfile = sandboxXpProfile,
    legacyMigrationApproved = false,
  }
  if type(tutorial) == "table" then
    applyStartingOptions(request, deepcopy(tutorial))
  end

  -- Freeroam+ is defined as cheats-enabled career; honor start mode even if cheatsMode was omitted.
  if resolveCareerStartMode(request.careerStartMode) == "freeroam" then
    request.cheats = true
  end

  if legacyMigrationBlocks(career, request) then
    return false
  end

  if career.isStartInProgress() then
    log("W", "", "Ignoring duplicate career start; a load is already in progress")
    return false
  end

  if overhaul_career_saveSystem.isSavePending() then
    overhaul_career_saveSystem.flushSaveForExit(function() career.restart(unpack(requestedArgs, 1, 18)) end)
    return true
  end

  if paths.valid(name) and saveSlots.getProfileSaveState(name, specificAutosave) == "unreadable" then
    career.endLegacySaveMigrationLoading()
    saveSlots.refuseUnreadableSave(name, specificAutosave)
    return false
  end

  beginStartLoading(career, start, request)
  core_jobsystem.create(function(job)
    startPreparedCareerProfile(career, start, job, request)
  end)

  return true
end

local function getCurrentStartingModeData(career)
  local startingOptions = career.getPublic("startingOptions")
  local startModeId = startingOptions and (startingOptions.startMode or startingOptions.careerStartMode)
  if type(startModeId) ~= "string" then
    return nil
  end

  for _, entry in ipairs(scanStartingModes()) do
    local modeData = loadStartingMode(entry)
    if modeData and modeData.id == startModeId then
      return modeData
    end
  end

  return nil
end

-- Pending load jobs must keep the career instance that created them.
function M.new(ctx)
  local career, start = ctx, ctx.start
  return {
    createOrLoadCareerAndStart = function(...)
      return createOrLoadCareerAndStart(career, start, ...)
    end,
    getCurrentStartingModeData = function()
      return getCurrentStartingModeData(career)
    end,
    getStartingMapPolicy = levelData.startPolicy,
  }
end

-- Public API --------------------------------------------------------------------------------------

M.scanStartingModes = scanStartingModes
M.getStartingModeFiles = getStartingModeFiles
M.resolveDifficultyMode = resolveDifficultyMode
M.normalizeDifficultyOverrides = normalizeDifficultyOverrides
M.normalizeSandboxEconomyProfile = normalizeSandboxEconomyProfile
M.normalizeSandboxXpProfile = normalizeSandboxXpProfile
M.normalizeStartingGaragePreference = normalizeStartingGaragePreference
M.resolveCareerStartMode = resolveCareerStartMode
M.getStartingModeOptions = getStartingModeOptions
M.getStartingMapPolicy = levelData.startPolicy

return M
