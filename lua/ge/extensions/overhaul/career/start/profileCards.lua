-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Owns profile cards, profile-screen builds and cached highlights for one career instance.
-- Read saved data, card fields, list builds, highlights and the per-career public API in order.
local M = {}

-- Requires ----------------------------------------------------------------------------------------

local difficultyModePersist = require('overhaul/lib/career/difficultyPersist')
local readModels = require('overhaul/lib/career/profileReadModels')
local saveSlots = require('overhaul/career/start/saveSlots')
local timing = require('overhaul/lib/ui/profileScreenTiming')
local contributorCatalog = require('overhaul/career/start/contributorCatalog')
local levelData = require('overhaul/lib/world/levelData')
local levelPreview = require('overhaul/lib/world/levelPreview')

-- Config ------------------------------------------------------------------------------------------

local SAVE_FILE = "general.json"
local MENU_BUDGET_SECONDS = 0.016
local LIVE_BUDGET_SECONDS = 0.008
local DETAIL_BATCH_SIZE = 6
-- Entry cards share the reader, but stock Career listens to allCareerProfiles too.
local ENTRY_CARD_EVENTS = {list = 'OverhaulEntryProfilesList', batch = 'OverhaulEntryProfilesBatch',
  complete = 'OverhaulEntryProfilesComplete', failed = 'OverhaulEntryProfilesFailed'}
local PROFILE_EVENTS = {list = 'allCareerProfilesList', batch = 'allCareerProfilesBatch',
  complete = 'allCareerProfiles', failed = 'allCareerProfilesFailed'}
-- Thrown inside a queued list build once its owner is retired, so the frame-budget job stops there.
local RETIRED_SIGNAL = {}

-- Save files --------------------------------------------------------------------------------------

-- Reads every JSON file a card may draw on, each once, in the order the card reads them.
local function readCardSaveFiles(autosavePath, seed)
  local files = {}
  if seed then
    files.info, files.career = seed.info, seed.career
  else
    files.info = jsonReadFile(autosavePath .. "/info.json")
    files.career = jsonReadFile(autosavePath .. "/career/" .. SAVE_FILE)
  end
  files.difficulty = jsonReadFile(difficultyModePersist.getSaveFilePath(autosavePath))
  files.hardcore = jsonReadFile(difficultyModePersist.getLegacyHardcorePath(autosavePath))
  files.cheats = jsonReadFile(autosavePath .. "/career/rls_career/cheats.json")
  files.challenge = jsonReadFile(autosavePath .. "/career/rls_career/challengeModes.json")
  files.maintenanceMode = jsonReadFile(autosavePath .. "/career/rls_career/maintenanceMode.json")
  files.ownerInputs = contributorCatalog.readProfileInputs(autosavePath)
  files.careerStartMode = jsonReadFile(autosavePath .. "/career/rls_career/careerStartMode.json")
  files.weather = jsonReadFile(autosavePath .. "/career/rls_career/weather.json")
  return files
end

-- Card fields -------------------------------------------------------------------------------------

-- An explicit start mode wins; otherwise the saved flags say which mode the save was started in.
local function setCareerStartMode(data, files)
  if files.careerStartMode and files.careerStartMode.careerStartMode then
    data.careerStartMode = files.careerStartMode.careerStartMode
  elseif files.cheats and files.cheats.cheatsMode then
    data.careerStartMode = "freeroam"
  elseif files.challenge and files.challenge.activeChallenge then
    data.careerStartMode = "story"
  elseif (files.difficulty and files.difficulty.mode == "hardcore") or (files.hardcore and files.hardcore.hardcoreMode) then
    data.careerStartMode = "hardcore"
  end
end

local function setDifficulty(data, files)
  if files.difficulty and files.difficulty.mode then
    data.difficultyMode = files.difficulty.mode
    data.hardcoreMode = files.difficulty.mode == "hardcore"
  elseif files.hardcore then
    data.hardcoreMode = files.hardcore.hardcoreMode
    data.difficultyMode = files.hardcore.hardcoreMode and "hardcore" or "normal"
  end
end

-- Each map owns its preview; missing art leaves the card's neutral placeholder visible.
local function previewForLevel(level, saveVersion)
  level = levelData.resolveAlias('map', level, {saveVersion = saveVersion})
  local map = levelData.getMap(level)
  local preview = map and levelData.assetPath(level, map.preview)
  if preview and FS:fileExists(preview) then return preview, map.label end
  return levelPreview.resolve(level), map and map.label
end

local function setLevel(data, careerData, saveVersion)
  if careerData and careerData.level then
    -- Keep the saved id for profile selection, and its versioned catalog label
    -- so the entry card can name the map without loading world services.
    data.level = careerData.level
    data.preview, data.levelLabel = previewForLevel(careerData.level, saveVersion)
  end
end

-- The live career's card: values come from the running attributes, inventory and garages.
local function setLiveCareerFields(state, data, files, autosavePath)
  contributorCatalog.contributeProfileCard(data, data.id, autosavePath,
    {stage = "attributes", live = true, saved = files.ownerInputs})

  data.money = overhaul_career_economy_playerAttributes.getAttribute("money")
  data.beamXP = overhaul_career_economy_playerAttributes.getAttribute("beamXP")
  data.vouchers = overhaul_career_economy_playerAttributes.getAttribute("vouchers")
  data.insuranceScore = {value = overhaul_career_repair_insurance.getDriverScore()}
  data.beamXP.level, data.beamXP.curLvlProgress, data.beamXP.neededForNext = readModels.getBeamXPLevel(data.beamXP.value)
  state.fillMenuProfileSkills(data, nil, true)
  data.branches = readModels.profileSkillRows(data.freSkills)
  local currentId = overhaul_career_garage_inventory.getCurrentVehicle()
  data.currentVehicle = currentId and deepcopy(overhaul_career_garage_inventory.getVehicles()[currentId])
  if data.currentVehicle then
    data.currentVehicle.niceName = overhaul_career_garage_inventory.getVehicleNiceNameTranslated(currentId)
  end

  -- Ships with the card rather than with the highlights: the card's artwork
  -- would otherwise rearrange itself a beat after appearing.
  if currentId and data.currentVehicle then
    data.lastVehicle = readModels.currentVehicleHighlight(autosavePath, data.currentVehicle, currentId)
  end

  data.vehicleCount = tableSize(overhaul_career_garage_inventory.getVehicles() or {})
  data.garageCount = #overhaul_career_garage_garageManager.getPurchasedGarages()
end

-- A card for a save that is not running: everything comes from the save's own files.
local function setSavedFileFields(state, data, files, autosavePath)
  contributorCatalog.contributeProfileCard(data, data.id, autosavePath,
    {stage = "attributes", live = false, saved = files.ownerInputs})
  local attData = jsonReadFile(autosavePath .. "/career/playerAttributes.json")
  local inventoryData = jsonReadFile(autosavePath .. "/career/inventory.json")
  local insuranceData = jsonReadFile(autosavePath .. "/career/insurance.json")

  if attData then
    data.money = deepcopy(attData.money) or {value=0}
    data.beamXP = deepcopy(attData.beamXP) or {value=0}
    data.vouchers = deepcopy(attData.vouchers) or {value=0}
    if insuranceData and insuranceData.plDriverScore then
      data.insuranceScore = {value = insuranceData.plDriverScore}
    else
      data.insuranceScore = {value = 0}
    end
    data.beamXP.level, data.beamXP.curLvlProgress, data.beamXP.neededForNext = readModels.getBeamXPLevel(data.beamXP.value)
    state.fillMenuProfileSkills(data, attData, false)
    data.branches = readModels.profileSkillRows(data.freSkills)
  else
    data.freSkills = {}
    -- Flag unwritten slots so zero values do not look like a valid save.
    data.saveDataMissing = true
  end

  if inventoryData and inventoryData.currentVehicle then
    local vehicleData = jsonReadFile(autosavePath .. "/career/vehicles/" .. inventoryData.currentVehicle .. ".json")
    if vehicleData then
      data.currentVehicle = vehicleData.niceName
      -- One extra record and a file check, next to reads this already does.
      data.lastVehicle = readModels.currentVehicleHighlight(autosavePath, vehicleData, inventoryData.currentVehicle)
    end
  end
  local vehicleFiles = FS:findFiles(autosavePath .. "/career/vehicles/", '*.json', 0, false, false)
  data.vehicleCount = #vehicleFiles
  data.garageCount = readModels.countPurchasedGarages(autosavePath)
end

local function setExperimentalMaintenance(data, files, isLiveCard)
  if isLiveCard then
    data.experimentalMaintenanceEnabled = overhaul_career_maintenance_maintenanceMode.isEnabled() == true
  else
    data.experimentalMaintenanceEnabled = files.maintenanceMode and files.maintenanceMode.enabled == true or false
  end
end

-- The save's info.json, with version flags, is merged in last.
local function mergeInfoFields(data, files, autosavePath)
  local infoData = files.info
  if infoData and infoData.version then
    infoData.incompatibleVersion = overhaul_career_saveSystem.getBackwardsCompVersion() > infoData.version
    infoData.outdatedVersion = overhaul_career_saveSystem.getSaveSystemVersion() > infoData.version
      or overhaul_career_saveMigration.requiresSaveMigration(autosavePath, infoData) or false
    infoData.requiresMigration = infoData.outdatedVersion
    tableMerge(data, infoData)
  end
end

-- sourcePath: an RLS save slot the importer offers (read-only); its card never shows
-- the running career's live state.
local function formatProfileForUi(state, profile, sourcePath, seed)
  local data = {id = profile}
  local autosavePath = seed and seed.path or sourcePath or saveSlots.getNewestSaveForProfile(profile)
  if not autosavePath then
    -- The folder exists but holds no readable save. The UI gets only an id, so
    -- say why rather than letting the card render "-" and $0 as real values.
    data.saveDataMissing = true
    return data
  end

  local files = readCardSaveFiles(autosavePath, seed)
  -- The saved weather clock owns the career day; reading it never starts the world simulation.
  data.day = files.weather and tonumber(files.weather.dayIndex)
  if data.day then data.day = math.max(0, math.floor(data.day)) + 1 end
  setCareerStartMode(data, files)
  setDifficulty(data, files)
  if files.cheats then
    data.cheatsMode = files.cheats.cheatsMode
  end
  if files.challenge and files.challenge.activeChallenge then
    data.activeChallenge = files.challenge.activeChallenge.name
  end
  if seed then
    data.level, data.preview, data.levelLabel = seed.level, seed.preview, seed.levelLabel
  else
    setLevel(data, files.career, files.info and files.info.version)
  end

  local currentProfile = overhaul_career_saveSystem.getCurrentProfile()
  local isLiveCard = not sourcePath and state.career.isActive() and overhaul_career_career.isActive() and currentProfile == profile
  if not sourcePath and overhaul_career_career.isActive() and currentProfile == profile then
    -- Prefer saved/deferred preference so profile UI can show next-load state.
    setLiveCareerFields(state, data, files, autosavePath)
  else
    setSavedFileFields(state, data, files, autosavePath)
  end
  setExperimentalMaintenance(data, files, isLiveCard)
  contributorCatalog.contributeProfileCard(data, profile, autosavePath,
    {stage = "choices", saved = files.ownerInputs})

  if files.career then
    data.boughtStarterVehicle = files.career.boughtStarterVehicle
    data.startingOptions = files.career.startingOptions or {}
  end
  contributorCatalog.contributeProfileCard(data, profile, autosavePath, {live = isLiveCard, imported = sourcePath ~= nil})
  mergeInfoFields(data, files, autosavePath)
  return data
end

-- List builds -------------------------------------------------------------------------------------

-- pace: optional, called after each profile so a frame-budgeted job can yield there.
local function collectAllProfilesData(state, pace)
  local res = {}
  local allProfiles = overhaul_career_saveSystem.getAllProfiles()
  if util_asyncBulkLoader and util_asyncBulkLoader.isLoading() then
    util_asyncBulkLoader.addTotal(#allProfiles)
  end
  for _, profile in ipairs(allProfiles) do
    local profileData = formatProfileForUi(state, profile)
    if util_asyncBulkLoader and util_asyncBulkLoader.isLoading() then
      util_asyncBulkLoader.addCount(1)
      util_asyncBulkLoader.yield("sendAllCareerProfilesData " .. profile)
    end
    if profileData then
      table.insert(res, profileData)
    end
    if pace then pace() end
  end

  table.sort(res, function(a,b) return (a.creationDate or "Z") < (b.creationDate or "Z") end)
  return res
end

local function sendAllCareerProfilesData(state)
  state.profileListGeneration = state.profileListGeneration + 1
  -- Slot choices and renames publish through this path without changing the
  -- save date. The next screen must not reuse their earlier disk cards.
  state.cardsCache = {}
  local span = timing.start('allCareerProfiles')
  local res = collectAllProfilesData(state)
  timing.finish(span, 'profiles=' .. #res)
  guihooks.trigger("allCareerProfiles", res)
  return res
end

-- Metadata fixes the strip's order and geometry before any skill, contributor
-- or vehicle reads. Disk cards survive screen visits within this career owner.
local function collectProfileList(state, checkCurrent)
  local profiles, saves, present = {}, {}, {}
  local currentProfile = overhaul_career_saveSystem.getCurrentProfile()
  local live = overhaul_career_career.isActive()
  for _, profile in ipairs(overhaul_career_saveSystem.getAllProfiles()) do
    checkCurrent()
    present[profile] = true
    local path = overhaul_career_saveSystem.getNewestSave(overhaul_career_saveSystem.getSaveRootDirectory() .. profile)
    if path == '' then path = nil end
    local info = path and jsonReadFile(path .. '/info.json')
    local date = info and info.date
    local cached = state.cardsCache[profile]
    local hit = cached and cached.path == path and cached.date == date and not (live and currentProfile == profile)
    local data
    if hit then
      data = cached.data
    else
      local career = path and jsonReadFile(path .. '/career/' .. SAVE_FILE)
      saves[profile] = {path = path, info = info, career = career}
      data = {id = profile, displayName = info and info.displayName or profile,
        date = date, creationDate = info and info.creationDate, pending = true}
      setLevel(data, career, info and info.version)
      saves[profile].level, saves[profile].preview, saves[profile].levelLabel = data.level, data.preview, data.levelLabel
    end
    profiles[#profiles + 1] = data
  end
  for profile in pairs(state.cardsCache) do if not present[profile] then state.cardsCache[profile] = nil end end
  table.sort(profiles, function(a, b) return (a.creationDate or 'Z') < (b.creationDate or 'Z') end)
  return profiles, saves, live and currentProfile or nil
end

-- Keep the full-list publication for existing callers; progressive consumers
-- replace only completed ids and never have to rebuild the strip's selection.
local function sendAllCareerProfilesDataAsync(state, events)
  events = events or PROFILE_EVENTS
  state.profileListGeneration = state.profileListGeneration + 1
  local generation = state.profileListGeneration
  local budget = state.career.isActive() and LIVE_BUDGET_SECONDS or MENU_BUDGET_SECONDS
  core_jobsystem.create(function(job)
    if state.retired or generation ~= state.profileListGeneration then return end
    local span = timing.start('allCareerProfilesAsync')
    -- Checked again after the pause: the owner may have unloaded while this job waited, and
    -- the next profile would read (and through live attributes, touch) its replacement.
    local function checkCurrent()
      if state.retired or generation ~= state.profileListGeneration then error(RETIRED_SIGNAL) end
    end
    local function build()
      local profiles, saves, activeProfileId = collectProfileList(state, checkCurrent)
      checkCurrent()
      guihooks.trigger(events.list, {generation = generation, profiles = profiles, activeProfileId = activeProfileId})
      timing.step(span, 'list')
      -- Match the screen's initial last-played order so its featured card is
      -- completed first, without changing the public creation-date ordering.
      local detailOrder = {}
      for index in ipairs(profiles) do detailOrder[#detailOrder + 1] = index end
      table.sort(detailOrder, function(a, b)
        local first, second = profiles[a], profiles[b]
        if first.id == activeProfileId then return second.id ~= activeProfileId end
        if second.id == activeProfileId then return false end
        return (first.date or '') > (second.date or '')
      end)
      local batch = {}
      local function publishBatch()
        if #batch == 0 then return end
        checkCurrent()
        guihooks.trigger(events.batch, {generation = generation, profiles = batch})
        batch = {}
      end
      -- Give the lightweight event a frame to paint before starting disk work.
      -- core_jobsystem's budgeted yield may skip, so use the coroutine directly.
      if next(saves) and coroutine.running() then coroutine.yield() end
      checkCurrent()
      for _, index in ipairs(detailOrder) do
        local data = profiles[index]
        local save = saves[data.id]
        if save then
          local card = save.path and formatProfileForUi(state, data.id, nil, save) or {id = data.id, saveDataMissing = true}
          profiles[index] = card
          if data.id ~= activeProfileId then
            state.cardsCache[data.id] = {path = save.path, date = save.info and save.info.date, data = card}
          end
          batch[#batch + 1] = card
          if #batch >= DETAIL_BATCH_SIZE then publishBatch() end
        end
        job.yield()
        checkCurrent()
      end
      publishBatch()
      return profiles
    end
    local ok, res = pcall(build)
    timing.finish(span, ok and ('profiles=' .. #res) or 'failed')
    if state.retired or generation ~= state.profileListGeneration then return end
    if ok then
      guihooks.trigger(events.complete, res)
    else
      log("E", "profileCards", "Profile list failed: " .. tostring(res))
      guihooks.trigger(events.failed, tostring(res))
    end
  end, budget)
  return true
end

-- Highlights --------------------------------------------------------------------------------------

-- Which save the highlights read, and its date. A slot the importer offers reads its own folder.
local function highlightSaveFor(profile, sourcePath)
  if sourcePath then
    local info = jsonReadFile(sourcePath .. "/info.json")
    return sourcePath, type(info) == "table" and tostring(info.date or "") or ""
  end
  return saveSlots.getNewestSaveForProfile(profile)
end

local function recentMoneyFor(isLoaded, autosavePath, limit)
  if isLoaded then
    -- The log on disk is only as fresh as the last autosave.
    return readModels.summariseRecentMoney(overhaul_career_economy_playerAttributes.getAttributeLog(), limit)
  end
  return readModels.summariseRecentMoney(jsonReadFile(autosavePath .. "/career/attributeLog.json"), limit)
end

-- The live inventory when loaded, otherwise the save's vehicle files.
local function assetValueFor(isLoaded, autosavePath)
  local total = 0
  if isLoaded then
    for _, vehicle in pairs(overhaul_career_garage_inventory.getVehicles() or {}) do
      total = total + readModels.vehicleAssetValue(vehicle)
    end
  else
    for _, file in ipairs(FS:findFiles(autosavePath .. "/career/vehicles/", "*.json", 0, false, false)) do
      total = total + readModels.vehicleAssetValue(jsonReadFile(file))
    end
  end
  return math.floor(total)
end

-- Cache unchanged disk saves; only the selected card reads expensive highlights, and imports remain read-only.
local function getProfileHighlights(state, profile, limit, sourcePath)
  local res = {recentMoney = {}, assetValue = 0}
  if not sourcePath and not saveSlots.isKnownCareerProfile(profile) then return res end
  limit = tonumber(limit) or 5

  local autosavePath, saveDate = highlightSaveFor(profile, sourcePath)
  saveDate = saveDate or ""
  if not autosavePath then return res end

  local currentProfile = overhaul_career_saveSystem.getCurrentProfile()
  local isLoaded = not sourcePath and overhaul_career_career.isActive() and currentProfile == profile

  -- The loaded save reads live state, which changes under us, so it is never cached.
  local cacheKey
  if not isLoaded then
    cacheKey = autosavePath .. "|" .. tostring(limit)
    local hit = state.highlightsCache[cacheKey]
    if hit and hit.date == saveDate then return hit.data end
  end

  res.recentMoney = recentMoneyFor(isLoaded, autosavePath, limit)
  res.assetValue = assetValueFor(isLoaded, autosavePath)
  if cacheKey then state.highlightsCache[cacheKey] = {date = saveDate, data = res} end
  return res
end

-- The current career's card, or nothing when no career is running.
local function sendCurrentProfileData(state)
  if not state.career.isActive() then return end
  local profile = overhaul_career_saveSystem.getCurrentProfile()
  if profile then
    return formatProfileForUi(state, profile)
  end
end

-- The owning career module is unloading: stop its queued list builds, so they never
-- overwrite the list of its replacement.
local function dispose(state)
  state.retired = true
end

-- Per-career API ----------------------------------------------------------------------------------

-- One set of profile functions per career instance (M.new(ctx)): its context and
-- card, skill and highlight caches. Replaced careers never share them.
-- ctx: isActive(), getPublic(key).
function M.new(ctx)
  local state = {
    career = ctx,
    fillMenuProfileSkills = readModels.new().fillMenuProfileSkills,
    -- Counts profile list sends, so an async build that a newer send overtook stays quiet
    -- instead of replacing the newer list with its older one.
    profileListGeneration = 0,
    retired = false,
    highlightsCache = {},
    cardsCache = {},
  }
  return {
    formatProfileForUi = function(profile, sourcePath) return formatProfileForUi(state, profile, sourcePath) end,
    collectAllProfilesData = function(pace) return collectAllProfilesData(state, pace) end,
    sendAllCareerProfilesData = function() return sendAllCareerProfilesData(state) end,
    sendAllCareerProfilesDataAsync = function() return sendAllCareerProfilesDataAsync(state) end,
    sendEntryCardProfilesDataAsync = function() return sendAllCareerProfilesDataAsync(state, ENTRY_CARD_EVENTS) end,
    dispose = function() dispose(state) end,
    getProfileHighlights = function(profile, limit, sourcePath) return getProfileHighlights(state, profile, limit, sourcePath) end,
    sendCurrentProfileData = function() return sendCurrentProfileData(state) end,
  }
end

return M
