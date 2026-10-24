-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/unlockFlags.lua (BeamNG 0.40).
-- Unlock flags: named conditions that feature owners define and the career reads as unlocked or not.
-- Keeps the stock layout on purpose so it still diffs against stock.

local M = {}

local flagCache = {}
local flagDefinitions = {}

-- Load saved flags from file
local function loadSaveData()
  local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not saveSlot then return end

--  local data = savePath and jsonReadFile(savePath .. "/career/" .. saveFile) or {}
--  flags = data or {}
  flagDefinitions = {}
  extensions.hook("onOverhaulGetUnlockFlagDefinitions", flagDefinitions)
end

-- Save current flags to file
local function onOverhaulSaveCurrentProfile(currentSavePath)
  --local filePath = currentSavePath .. "/career/" .. saveFile
  --jsonWriteFile(filePath, flags, true)
end

-- Get flag value, returns false if flag doesn't exist
local function getFlag(flagName)
  if not flagCache[flagName] then
    local definition = M.getFlagDefinition(flagName)
    if not definition then return false end
    flagCache[flagName] = definition.unlockedFunction()
  end
  return flagCache[flagName] or false
end

local function getFlagDefinition(flagName)
  return flagDefinitions[flagName] or nil
end

local function getFlagLockedReason(flagName)
  local flagDefinition = getFlagDefinition(flagName)
  if not flagDefinition then return nil end
  return {type = "locked", icon = flagDefinition.icon, level = flagDefinition.level, label = flagDefinition.label}
end

-- Set flag value
local function setFlag(flagName, value)
  flagCache[flagName] = value
  extensions.hook("onOverhaulUnlockFlagChanged", flagName, value)
end

-- Reset all flags
local function resetFlags()
  flagCache = {}
end

M.onCareerActivated = function()
  resetFlags()
  loadSaveData()
end
M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile

M.getFlag = getFlag
M.getFlagDefinition = getFlagDefinition
M.setFlag = setFlag
M.resetFlags = resetFlags
return M
