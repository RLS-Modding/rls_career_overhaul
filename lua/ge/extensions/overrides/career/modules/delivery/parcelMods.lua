-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Career-mode thin shell over shared parcel modifier logic.
-- Delegates to gameplay/delivery/parcelMods for all shared definitions and logic.
-- Keeps career-specific progress tracking and unlock flag resolution here.

local M = {}
local shared = require('gameplay/delivery/parcelMods')

local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dParcelMods, dTutorial
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dProgress = career_modules_delivery_progress
  dTutorial = career_modules_delivery_tutorial
end

local progressTemplate = {
  timed = {
    delivieries = 0,
    onTimeDeliveries = 0,
    delayedDeliveries = 0,
    lateDeliveries = 0
  },
  large = {
    delivieries = 0
  },
  precious = {
    delivieries = 0,
    lost = 0
  },
  heavy = {
    delivieries = 0
  },
  post = {
    delivieries = 0
  },
  airExpress = {
    delivieries = 0
  },
  remoteDelivery = {
    delivieries = 0
  },
  pepperReduction = {
    delivieries = 0
  }
}

local progress = deepcopy(progressTemplate)

-- Career-only: build unlock flags from career_modules_unlockFlags
local function getCareerUnlockFlags()
  if not career_modules_unlockFlags then return nil end
  local flags = {}
  local modifiers = shared.getModifiers()
  for _, mod in pairs(modifiers) do
    if mod.unlockFlag then
      flags[mod.unlockFlag] = career_modules_unlockFlags.getFlag(mod.unlockFlag) or false
    end
  end
  return flags
end

-- Career-only: build flag definitions from career_modules_unlockFlags
local function getCareerFlagDefinitions()
  if not career_modules_unlockFlags then return nil end
  local defs = {}
  local modifiers = shared.getModifiers()
  for _, mod in pairs(modifiers) do
    if mod.unlockFlag then
      defs[mod.unlockFlag] = career_modules_unlockFlags.getFlagDefinition(mod.unlockFlag)
    end
  end
  return defs
end

-- Career-only: track modifier stats into progress
local function trackModifierStats(cargo)
  for _, mod in ipairs(cargo.modifiers or {}) do
    progress[mod.type] = progress[mod.type] or {}
    progress[mod.type].delivered = (progress[mod.type].delivered or 0) + 1
    if mod.type == "timed" then
      local prog = progress.timed
      local expiredTime = dGeneral.time() - cargo.loadedAtTimeStamp

      if expiredTime <= mod.timeUntilDelayed then
        prog.onTimeDeliveries = (prog.onTimeDeliveries or 0) + 1
      elseif expiredTime <= mod.timeUntilLate then
        prog.delayedDeliveries = (prog.delayedDeliveries or 0) + 1
      else
        prog.lateDeliveries = (prog.lateDeliveries or 0) + 1
      end
    end
  end
end

M.setProgress = function(data)
  progress = data or deepcopy(progressTemplate)
end

M.getProgress = function()
  return progress
end

-- Delegate shared functions, passing career unlock flags where needed
M.getModData = shared.getModData
M.getModifierIcon = shared.getModifierIcon
M.getLabelAndShortDescription = shared.getLabelAndShortDescription
M.isImportant = shared.isImportant
M.getParcelModProgressLabel = shared.getParcelModProgressLabel
M.addModifier = shared.addModifier
M.calculateTimedModifierTime = shared.calculateTimedModifierTime
M.generateModifiers = shared.generateModifiers
M.trackModifierStats = trackModifierStats

-- These pass career unlock flags to the shared module
M.isParcelModUnlocked = function(modKey)
  return shared.isParcelModUnlocked(modKey, getCareerUnlockFlags())
end

M.lockedBecauseOfMods = function(modKeys)
  return shared.lockedBecauseOfMods(modKeys, getCareerUnlockFlags(), getCareerFlagDefinitions())
end

M.getParcelModUnlockStatusSimple = function()
  return shared.getParcelModUnlockStatusSimple(getCareerUnlockFlags())
end

return M
