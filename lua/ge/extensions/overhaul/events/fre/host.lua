-- Loads the freeroam progression files as child extensions and runs their shared maintenance clock.
-- State, offers, skills, sanctioned racing and the UI feed are separate files; this one only sequences them.
local M = {}

-- Lua reload can reconstruct this host before the manager that supplies its accepted child roster.
M.dependencies = {"overhaul_shell_extensionManager"}

local loadedExtensions = {}

local function loadExtensions()
  local names, preserved = overhaul_shell_extensionManager.childrenOf("overhaul_events_fre_host")
  loadedExtensions = require("overhaul/lib/shell/childExtensions").load(names, preserved) or loadedExtensions
end

local function unloadExtensions()
  if require("overhaul/lib/shell/childExtensions").unload(loadedExtensions) == false then return false end
  loadedExtensions = {}
end

local function runMaintenancePass(now)
  local changed = false
  if overhaul_events_fre_skills.pruneAllSponsorSlotCooldowns(now) then
    changed = true
    overhaul_events_fre_state.saveNow()
  end
  if overhaul_events_fre_offers.purgeExpiredEntries(now) then changed = true end
  if overhaul_events_fre_offers.syncAllOffers(now) then changed = true end
  if overhaul_events_fre_sanctionedRacing.syncGeneration(now) then changed = true end
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
  overhaul_events_fre_state.preventImmediateRetrigger(now)
  if changed then overhaul_events_fre_ui.emitUiStateUpdate("maintenance") end
end

local function onUpdate(_, dtSim, _)
  if not overhaul_events_fre_state.isCareerActive() then return end
  overhaul_events_fre_state.updateSimTime(dtSim)
  local now = overhaul_events_fre_state.getSimTime()
  local nextMaintenanceAt = overhaul_events_fre_state.getNextMaintenanceAt()
  if not nextMaintenanceAt or now < nextMaintenanceAt then return end
  runMaintenancePass(now)
end

-- A leftover "committed" or "racing" sanctioned offer from an earlier session has no live race behind it
-- and would block every later accept with "already committed".
local function settleSanctionedRacingAndSchedule(now)
  overhaul_events_fre_sanctionedRacing.evictStaleOfferOnCareerLoad()
  overhaul_events_fre_sanctionedRacing.syncGeneration(now)
  overhaul_events_fre_state.refreshMaintenanceSchedule(now)
end

local function onExtensionLoaded()
  loadExtensions()
  overhaul_events_fre_state.loadState()
  overhaul_events_fre_raceCache.refreshRaceCache()
  local now = overhaul_events_fre_state.getSimTime()
  overhaul_events_fre_offers.purgeExpiredEntries(now)
  overhaul_events_fre_offers.syncAllOffers(now)
  settleSanctionedRacingAndSchedule(now)
end

local function onExtensionUnloaded()
  unloadExtensions()
end

local function onOverhaulModulesActivated()
  overhaul_events_fre_state.loadState()
  overhaul_events_fre_raceCache.refreshRaceCache()
  local now = overhaul_events_fre_state.getSimTime()
  overhaul_events_fre_sanctionedRacing.resetRuntimeForCareerChange()
  overhaul_events_fre_offers.syncAllOffers(now)
  settleSanctionedRacingAndSchedule(now)
end

local function onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  if not overhaul_events_fre_state.isStateLoaded() then overhaul_events_fre_state.loadState() end
  overhaul_events_fre_state.saveState(currentSavePath, writer)
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onOverhaulModulesActivated = onOverhaulModulesActivated
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

return M
