-- One-time Civil Service migration: saved branch and milestone keys move from legacy paths to current ones.
-- Runs once per save; a marker file records the migration version so later loads skip it.
local M = {}

local branchMigration = {
  version = 1,
  markerFile = "career/civilServiceBranchMigration.json",
  branchUnlocksFile = "career/branchUnlocks.json",
  milestonesFile = "career/milestones/general.json",
}

-- Moves each old key to its new key. Table values merge into an existing table without overwriting fields.
local function migrateKeyedTable(jsonData, keyMap)
  if type(jsonData) ~= "table" then
    return false
  end
  local changed = false
  for oldKey, newKey in pairs(keyMap) do
    if jsonData[oldKey] ~= nil then
      if type(jsonData[oldKey]) == "table" and (jsonData[newKey] == nil or type(jsonData[newKey]) == "table") then
        jsonData[newKey] = jsonData[newKey] or {}
        for field, value in pairs(jsonData[oldKey]) do
          if jsonData[newKey][field] == nil then
            jsonData[newKey][field] = value
          end
        end
      elseif jsonData[newKey] == nil then
        jsonData[newKey] = jsonData[oldKey]
      end
      jsonData[oldKey] = nil
      changed = true
    end
  end
  return changed
end

-- Returns "changed", "unchanged" or "failed" for the branch unlock file.
local function migrateBranchUnlocks(savePath, branchKeyMap)
  local filePath = savePath .. "/" .. branchMigration.branchUnlocksFile
  local branchUnlocks = jsonReadFile(filePath)
  if not (branchUnlocks and migrateKeyedTable(branchUnlocks, branchKeyMap)) then
    return "unchanged"
  end
  if not overhaul_career_saveSystem.jsonWriteFileSafe(filePath, branchUnlocks, true) then
    return "failed"
  end
  return "changed"
end

-- Returns "changed", "unchanged" or "failed" for the general milestone file.
local function migrateMilestones(savePath, milestoneKeyMap)
  local filePath = savePath .. "/" .. branchMigration.milestonesFile
  local milestonesData = jsonReadFile(filePath)
  if not (milestonesData and milestonesData.general and migrateKeyedTable(milestonesData.general, milestoneKeyMap)) then
    return "unchanged"
  end
  if not overhaul_career_saveSystem.jsonWriteFileSafe(filePath, milestonesData, true) then
    return "failed"
  end
  return "changed"
end

-- Maps each legacy branch path, and its matching "branch_" milestone id, to the current path.
local function buildKeyMaps()
  local branchKeyMap = {}
  local milestoneKeyMap = {}
  for oldPath, newPath in pairs(overhaul_career_progression_skills.legacyBranchPathAliases) do
    branchKeyMap[oldPath] = newPath
    milestoneKeyMap["branch_" .. oldPath] = "branch_" .. newPath
  end
  return branchKeyMap, milestoneKeyMap
end

-- Migrates one save. The marker is written only when both files were written successfully.
local function runCivilServiceBranchMigration(savePath)
  if not savePath or savePath == "" then
    return
  end

  local markerPath = savePath .. "/" .. branchMigration.markerFile
  local markerData = jsonReadFile(markerPath) or {}
  if (markerData.version or 0) >= branchMigration.version then
    return
  end

  local branchKeyMap, milestoneKeyMap = buildKeyMaps()
  local unlocksOutcome = migrateBranchUnlocks(savePath, branchKeyMap)
  local milestonesOutcome = migrateMilestones(savePath, milestoneKeyMap)
  if unlocksOutcome == "failed" or milestonesOutcome == "failed" then
    return
  end

  overhaul_career_saveSystem.jsonWriteFileSafe(markerPath, {
    version = branchMigration.version,
    migratedAt = os.time(),
    changed = unlocksOutcome == "changed" or milestonesOutcome == "changed",
  }, true)
end

local function onOverhaulModulesActivated()
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  runCivilServiceBranchMigration(savePath)
end

M.onOverhaulModulesActivated = onOverhaulModulesActivated

return M
