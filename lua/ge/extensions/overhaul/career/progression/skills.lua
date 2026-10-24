-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/branches.lua (BeamNG 0.40).

-- Loads the domain/branch/skill hierarchy, resolves XP levels and exposes unlock flags.
-- Catalog caches belong to this extension instance and preserve the original traversal order.
local M = {}
-- SaveStore keys over the files this module writes today (metadata only).
require("overhaul/lib/save/store").registerKeys({
  {key = "progression.branchUnlocks", owner = "overhaul_career_progression_skills", files = {"career/branchUnlocks.json"}, phase = "profile", required = true},
})
local dataFiles = require("overhaul/lib/data/dataFiles")

local moduleVersion = 42

local branchesDir = "/gameplay/domains/"
local missingBranch = {id = "missing", name = "ui.career.branches.missing.name", description = "ui.career.branches.missing.description", levels = {}, missing = true}

local branchesById
local branchesByAttributeKey
local branchesByPath
local sortedBranches

local defaultRewardMultipliers = {1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3, 3.25, 3.5, 3.75, 4, 4.25, 4.5, 4.75, 5}

local order = {money = 0,beamXP = 1, vouchers = 9999}
local function sortAttributes(a,b) return (order[a] or math.huge) < (order[b] or math.huge) end
M.getOrder = function(key) return order[key] or -math.huge end
local branchNameOrder = {}
local function sortBranchNames(a,b) return (order[a] or math.huge) < (order[b] or math.huge) end

local function sanitizeBranch(branch, filePath)
  local infoDir, _, _ = path.split(filePath)
  branch.dir = dataFiles.assetDir(infoDir)
  branch.id = ""

  -- Extracting folders
  local folders = {'domains'}
  for folder in string.gmatch(string.sub(dataFiles.toVanilla(infoDir), #branchesDir, -2), "[^/]+") do
      table.insert(folders, folder)
  end

  if #folders > 0 then
    -- Build path ID from folders, excluding type names
    branch.pathId = ""

    local skipFolders = {domains = true, branches = true, skills = true}
    for _, folder in ipairs(folders) do
      if not skipFolders[folder] then
        if branch.pathId ~= "" then
          branch.pathId = branch.pathId .. "-"
        end
        branch.pathId = branch.pathId .. folder
      end
    end
    branch.id = branch.pathId
    -- Determine type and parents based on path structure
    branch.isDomain = false
    branch.isBranch = false
    branch.isSkill = false
    branch.parentDomain = nil
    branch.parentBranch = nil
    branch.parentId = nil

    -- Check each pair of folders to determine type and parents
    for i = 1, #folders-1 do
      local folderType = folders[i]
      local followingFolder = folders[i+1]

      if folderType == "domains" then
        -- Found domain
        branch.parentDomain = followingFolder
        branch.isDomain = true
      elseif folderType == "branches" then
        -- Found branch
        branch.isBranch = true
        if not branch.parentDomain then
          -- If no domain found yet, use previous folder
          branch.parentDomain = folders[i-1]
        end
        branch.parentBranch = followingFolder
        branch.parentId = branch.parentDomain -- Domain is direct parent
      elseif folderType == "skills" then
        -- Found skill
        branch.isSkill = true
        if branch.parentBranch then
          -- Build full path for parent branch
          branch.parentBranch = branch.parentDomain .. "-" .. branch.parentBranch
          branch.parentId = branch.parentBranch -- Branch is direct parent
        else
          -- If no branch in between, parent is domain
          branch.parentId = branch.parentDomain
        end
      end
    end

    -- Set type based on deepest found type
    if branch.isSkill then
      branch.isDomain = false
      branch.isBranch = false
    elseif branch.isBranch then
      branch.isDomain = false
      branch.parentId = branch.parentDomain -- Domain is direct parent
    end

    -- If no specific type was found, log error and default to branch
    if not (branch.isDomain or branch.isBranch or branch.isSkill) then
      log('E', 'branches', 'Branch type not specified for ' .. branch.id .. ', defaulting to branch')
      branch.isBranch = true
    end
  end

  -- go through levels and add some helper fields
  local maxReachableLevel = 0
  for i, level in ipairs(branch.levels) do
    if not level.isInDevelopment then
      maxReachableLevel = i
    end
  end
  if maxReachableLevel > 0 then
    branch.levels[maxReachableLevel].isMaxLevel = true
  end
  branch.maxReachableLevel = maxReachableLevel

  --expand automatic unlocks for skills
  for i, level in ipairs(branch.levels) do
    if level.unlocks then
      level.unlocks = M.expandUnlocks(branch, i, level.unlocks)
    end
    if branch.defaultRewardMultipliers then
      level.rewardMultiplier = defaultRewardMultipliers[i] or 1
    end
  end

  branch.hasLevels = #branch.levels > 1

  --branch/skill itself unlock
  branch.unlocked = true
  if branch.startLocked then
    branch.unlocked = false
  end
  branch.file = filePath

  branch.name = branch.name or {txt = "ui.career.branches.unnamed", context = {id = branch.id}}
  branch.description = branch.description or "ui.career.branches.noDescription"
  branch.attributeKey = branch.attributeKey or branch.pathId
  branch.order = branch.order or (10000 + #(sortedBranches or {}))
  -- Only a cover that ships with the branch: a missing file left a blank image box on the Skills pages.
  local coverFile = branch.dir .. "progressCover.jpg"
  branch.progressCover = FS:fileExists(coverFile) and coverFile or nil
  branch.thumbnail = branch.dir .. "thumbnail.jpg"
  branch.isInDevelopment = branch.isInDevelopment or false
  branch.accentColor = branch.accentColor or branch.color
  if branch.isInDevelopment then
    branch.unlocked = false
    branch.unlockInfo = {type = "locked", label = "ui.career.inDevelopment"}
    branch.unlockCondition = {type = "never"}
  end
end
-- gets all branches in a dict by ID
local function getBranches()
  if not branchesById then
    branchesById = {}
    branchesByAttributeKey = {}
    branchesByPath = {}

    -- First collect all branches
    local allBranches = {}
    -- Only Overhaul's own domains: the stock apm/bmra/freestyle domains are not read. Every node
    -- kept here was already read from this Overhaul file (dataFiles let it replace the stock twin), in the
    -- same sorted order. sanitizeBranch still derives ids through dataFiles.toVanilla and branchesDir.
    local domainFiles = FS:findFiles('/gameplay/overhaul/domains/', 'info.json', -1, false, true)
    table.sort(domainFiles)
    for _, filePath in ipairs(domainFiles) do
      local fileInfo = jsonReadFile(filePath)
      if type(fileInfo) ~= "table" then
        log('E', 'branches', 'Could not read branch file: ' .. tostring(filePath))
      elseif not fileInfo.ignore then
        -- A malformed file is skipped; aborting here would leave an empty cache for the session.
        local ok, err = pcall(sanitizeBranch, fileInfo, filePath)
        if ok then
          table.insert(allBranches, fileInfo)
        else
          log('E', 'branches', 'Skipped invalid branch file ' .. tostring(filePath) .. ': ' .. tostring(err))
        end
      end
    end

    -- First get all domains and sort them by order
    local domains = {}
    for _, branch in ipairs(allBranches) do
      if branch.isDomain then
        table.insert(domains, branch)
      end
    end
    table.sort(domains, function(a,b) return (a.order or 0) < (b.order or 0) end)

    -- Build sorted list by traversing hierarchy
    local sortedList = {}
    local remaining = {}
    for _, branch in ipairs(allBranches) do
      if not branch.isDomain then
        remaining[branch.id] = branch
      end
    end

    -- Helper to find children of a parent
    local function getChildren(parentId)
      local children = {}
      for id, branch in pairs(remaining) do
        if branch.parentId == parentId then
          table.insert(children, branch)
          remaining[id] = nil
        end
      end
      table.sort(children, function(a,b) return (a.order or 0) < (b.order or 0) end)
      return children
    end

    -- Process domains and their children recursively
    local function processChildren(parent)
      local children = getChildren(parent.id)
      for _, child in ipairs(children) do
        table.insert(sortedList, child)
        processChildren(child) -- Recursively process any children of this child
      end
    end

    -- Process domains
    for _, domain in ipairs(domains) do
      table.insert(sortedList, domain)
      processChildren(domain)
    end

    -- Add to lookup tables preserving hierarchical order
    for i, fileInfo in ipairs(sortedList) do
      branchesById[fileInfo.id] = fileInfo
      branchesByAttributeKey[fileInfo.attributeKey] = fileInfo
      branchesByPath[fileInfo.pathId] = fileInfo
      order[fileInfo.attributeKey] = i
      branchNameOrder[fileInfo.id] = fileInfo.order
    end

    -- Recursively get color from parent chain
    local function getInheritedColor(branch, colorType)
      if not branch then return nil end
      if branch[colorType] then return branch[colorType] end

      local parent = branch.parentId and branchesById[branch.parentId]
      return parent and getInheritedColor(parent, colorType)
    end

    -- Now that all branches are loaded, handle color inheritance
    for _, branch in pairs(branchesById) do
      branch.color = branch.color or getInheritedColor(branch, 'color')
      branch.accentColor = branch.accentColor or getInheritedColor(branch, 'accentColor') or branch.color
    end
  end
  return branchesById
end

local function getBranchById(id)
  return M.getBranchByPath(id)
end

local function getBranchByPath(pathId)
  getBranches()
  local branch = branchesByPath[pathId]
  if not branch and M.oldAttributeNamesToNewNames[pathId] then
    branch = branchesByPath[M.oldAttributeNamesToNewNames[pathId]]
    if branch then
      log('W', '', 'Using legacy branch path: ' .. pathId .. ' -> ' .. M.oldAttributeNamesToNewNames[pathId])
      log('D', '', 'Called from:\n' .. debug.tracesimple())
    end
  end
  return branch or missingBranch
end

local function getBranchByDomainBranchSkill(domainId, branchId, skillId)
  getBranches()
  local pathId = domainId
  if branchId then
    pathId = pathId .. "-" .. branchId
    if skillId then
      pathId = pathId .. "-" .. skillId
    end
  end
  return getBranchByPath(pathId) or missingBranch
end

M.getBranchByPath = getBranchByPath
M.getBranchByDomainBranchSkill = getBranchByDomainBranchSkill

local function getSortedBranches()
  if not sortedBranches then
    getBranches()
    sortedBranches = {}
    local keysSorted = tableKeys(branchesByPath)
    table.sort(keysSorted, sortBranchNames)
    for _, key in ipairs(keysSorted) do
      table.insert(sortedBranches, branchesByPath[key])
    end
  end
  return sortedBranches
end

local function calcBranchLevelFromValue(attributeValue, id)
  local branch = getBranchByPath(id)
  local level = -1
  local currentLevelProgress, neededForNext, previousThreshold, nextThreshold = -1, -1, -1, -1

  local levels = branch.levels or {}
  for i, lvl in ipairs(levels) do
    if lvl.requiredValue and  attributeValue >= lvl.requiredValue then
      level = i
    end
  end
  if levels[level+1] and levels[level+1].requiredValue then
    previousThreshold = levels[level].requiredValue
    neededForNext = levels[level+1].requiredValue - levels[level].requiredValue
    currentLevelProgress = attributeValue - levels[level].requiredValue
    nextThreshold = levels[level+1].requiredValue
  end
  return level, currentLevelProgress, neededForNext, previousThreshold, nextThreshold

end

local function getBranchSimpleInfo(id)
  local branch = getBranchByPath(id)
  local xp = M.getBranchXP(id)
  local level, currentLevelProgress, neededForNext, previousThreshold, nextThreshold = calcBranchLevelFromValue(xp, id)
  return {
    label = branch.name,
    level = level,
    icon = branch.icon,
    curLvlProgress = currentLevelProgress,
    neededForNext = neededForNext,
    processPercent = currentLevelProgress / neededForNext,
    max = #branch.levels,
  }
end
M.getBranchSimpleInfo = getBranchSimpleInfo

local function getBranchLevel(id)
  local branch = getBranchByPath(id)
  if branch.id == 'missing' then return nil end
  local attributeValue = 0
  -- Load handlers query the catalog before career core or its XP owner is published.
  if overhaul_career_career and overhaul_career_career.isActive() and overhaul_career_economy_playerAttributes then
    attributeValue = overhaul_career_economy_playerAttributes.getAttributeValue(branch.attributeKey) or 0
  end
  return calcBranchLevelFromValue(attributeValue, id)
end

local function getBranchLevelByPath(pathId)
  local branch = getBranchByPath(pathId)
  if branch.id == 'missing' then return nil end
  local attributeValue = 0
  if overhaul_career_career and overhaul_career_career.isActive() and overhaul_career_economy_playerAttributes then
    attributeValue = overhaul_career_economy_playerAttributes.getAttributeValue(branch.attributeKey) or 0
  end
  return calcBranchLevelFromValue(attributeValue, pathId)
end

local function getBranchXP(id)
  local branch = getBranchByPath(id)
  if branch.id == 'missing' then return nil end
  local attributeValue = nil
  if overhaul_career_career and overhaul_career_career.isActive() and overhaul_career_economy_playerAttributes then
    attributeValue = overhaul_career_economy_playerAttributes.getAttributeValue(branch.attributeKey)
  end
  return attributeValue or -1
end

local function getXPNeededForLevel(id, level)
  local branch = getBranchByPath(id)
  if branch.id == 'missing' then return nil end
  local levels = branch.levels or {}
  if not levels[level] then return -1 end
  return levels[level].requiredValue
end

local function getBranchIcon(id)
  local branch = getBranchByPath(id)
  if branch.id == 'missing' then return nil end
  return branch.icon
end

local function getLevelLabel(id, level)
  local branch = getBranchByPath(id)
  if branch.id == 'missing' then return nil end
  if not level or level < 1 then return "ui.career.branches.missingLevel" end
  if level >= #branch.levels then return "ui.career.lvlLabelMax" end
  return branch.levels[level].levelName or {txt='ui.career.lvlLabel', context={lvl=level}}
end

local function getLevelRewardMultiplier(id)
  local branch = getBranchByPath(id)
  if branch.id == 'missing' then return nil end
  local attributeValue = 0
  if overhaul_career_career and overhaul_career_career.isActive() and overhaul_career_economy_playerAttributes then
    attributeValue = overhaul_career_economy_playerAttributes.getAttributeValue(branch.attributeKey) or 0
  end
  local level = calcBranchLevelFromValue(attributeValue, id)
  local levelInfo = branch.levels[level]
  return levelInfo and levelInfo.rewardMultiplier or nil
end

local function orderAttributeKeysByBranchOrder(list)
  table.sort(list, sortAttributes)
  return list
end

local function orderBranchNamesKeysByBranchOrder(list)
  list = list or tableKeys(branchesById)
  table.sort(list, sortBranchNames)
  return list
end

local function expandUnlocks(skill, level, unlocks)
  local newUnlocks = {}
  for _, unlock in ipairs(unlocks) do
    -- "automaticMission" unlock cards listed the missions a level opened; missions no longer exist.
    if unlock.type ~= "automaticMission" then
      table.insert(newUnlocks, unlock)
    end
  end
  return newUnlocks

end
M.expandUnlocks = expandUnlocks

-- Career Saving stuff
local saveFile = "branchUnlocks.json"
local savedFields = {"unlocked"}

local function onOverhaulSaveCurrentProfile(currentSavePath)
  local filePath = currentSavePath .. "/career/" .. saveFile
  local saveData = { }
  for id, branch in pairs(getBranches()) do
    saveData[id] = {}
    for _, field in ipairs(savedFields) do
      saveData[id][field] = branch[field]
    end
  end
  -- save the data to file
  overhaul_career_saveSystem.jsonWriteFileSafe(filePath, saveData, true)
end

local function onOverhaulActive(active)
  if not active then return end
  local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not saveSlot then return end

  local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
  local outdated = not saveInfo or saveInfo.version < moduleVersion

  local data = (savePath and not outdated and jsonReadFile(savePath .. "/career/"..saveFile)) or {}
  -- Preserve the legacy reads and iteration; checkUnlocks recomputes the live flags.
  for id, branch in pairs(getBranches()) do
    for k, v in pairs(data[id] or {}) do
    end
  end
end

local function checkUnlocks()
  for id, branch in pairs(getBranches()) do
    branch.unlocked = true
    branch.unlockInfo = nil
    branch.lockedReason = nil
    branch.unlockInfos = nil
    if branch.unlockCondition then
      if branch.unlockCondition.type == "unlockFlag" then
        branch.unlocked = overhaul_career_progression_unlockFlags.getFlag(branch.unlockCondition.unlockFlag)
        if not branch.unlocked then
          local flagDefinition = overhaul_career_progression_unlockFlags.getFlagDefinition(branch.unlockCondition.unlockFlag)
          if flagDefinition then
            branch.unlockInfo = flagDefinition.unlockInfo
            branch.lockedReason = flagDefinition.lockedReason
          end
        end
      elseif branch.unlockCondition.type == "anyNunlockFlags" then
        local flags = branch.unlockCondition.unlockFlags
        local requiredFlagCount = branch.unlockCondition.n
        branch.unlockInfos = {}
        local completedFlagCount = 0
        for _, flag in ipairs(flags) do
          if overhaul_career_progression_unlockFlags.getFlag(flag) then
            completedFlagCount = completedFlagCount + 1
            local flagDefinition = overhaul_career_progression_unlockFlags.getFlagDefinition(flag)
            if flagDefinition then
              table.insert(branch.unlockInfos, {label = flagDefinition.label, icon = "badgeRoundStar", status = "completed", color = flagDefinition.color})
            end
          end
        end
        if completedFlagCount < requiredFlagCount then
          branch.unlocked = false
        end
        while completedFlagCount < requiredFlagCount do
          table.insert(branch.unlockInfos, {label = "ui.career.certification.anyCertification", icon = "badgeRoundStar", status = "open"})
          completedFlagCount = completedFlagCount + 1
        end
      elseif branch.unlockCondition.type == "never" then
        branch.unlocked = false
        branch.unlockInfo = {type = "locked", label = "ui.career.inDevelopment"}
        branch.lockedReason = {type = "locked", label = "ui.career.inDevelopment", icon = "lockClosed"}
      end
    end
  end
end
M.checkUnlocks = checkUnlocks

local function onOverhaulGetUnlockFlagDefinitions(flagDefinitions)

  for id, branch in pairs(getBranches()) do
    -- for levels
    for lvl, lvlData in pairs(branch.levels or {}) do
      local unlockFlags = lvlData.unlockFlags or {}
      table.insert(unlockFlags, branch.id.."-level-"..lvl)
      for _, flag in ipairs(unlockFlags) do
        flagDefinitions[flag] = {
          label = { txt = "ui.career.branchLevel", context = {branch = branch.name, lvl = lvl}},
          level = lvl,
          unlockedFunction = function()
            local hasLevel =  getBranchLevel(id) >= lvl
            local isUnlocked = getBranchById(id).unlocked
            return hasLevel and isUnlocked
          end,
          unlockInfo = {
            type = "minLevel", icon = branch.icon,
            longLabel = { txt = "ui.career.requiresBranchLevel", context = {branch = branch.name, lvl = lvl}},
            shortLabel = { txt = "ui.career.lvlShort", context = {lvl = lvl}},
          },
          lockedReason = {
            type = "locked", icon = branch.icon, level = lvl, label = { txt = "ui.career.requiresBranchLevel", context = {branch = branch.name, lvl = lvl}}
          }
        }
      end
    end

  end
end
M.onOverhaulGetUnlockFlagDefinitions = onOverhaulGetUnlockFlagDefinitions

M.onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile
M.onOverhaulActive = onOverhaulActive

M.getBranches = getBranches
M.getBranchById = getBranchById
M.getSortedBranches = getSortedBranches
M.getBranchLevel = getBranchLevel
M.getBranchLevelByPath = getBranchLevelByPath
M.getBranchXP = getBranchXP
M.getXPNeededForLevel = getXPNeededForLevel
M.getBranchIcon = getBranchIcon
M.getLevelLabel = getLevelLabel
M.getLevelRewardMultiplier = getLevelRewardMultiplier
M.calcBranchLevelFromValue = calcBranchLevelFromValue

M.orderAttributeKeysByBranchOrder = orderAttributeKeysByBranchOrder
M.orderBranchNamesKeysByBranchOrder = orderBranchNamesKeysByBranchOrder

M.onOverhaulPlayerAttributesChanged = onOverhaulPlayerAttributesChanged

-- Legacy branch path -> Overhaul skill path, for page/branch lookups (getBranchByPath). Only Overhaul's
-- own domains exist: names that pointed at the stock apm/bmra/freestyle domains are gone, and the
-- legacy names of skills that live on point at their careerSkills path. Paths only: saved values are never
-- converted through this table (a persisted apm-motorsport balance stays inert imported data).
local oldAttributeNamesToNewNames = {
  labourer = "logistics",
  delivery = "logistics-delivery",
  vehicleDelivery = "logistics-delivery",

  drift = "careerSkills-mayhem",
  crawl = "careerSkills-offroad",
  crawling = "careerSkills-offroad",
  apexRacing = "careerSkills-circuitRacing",
  motorsport = "careerSkills-circuitRacing",
  police = "careerSkills-emergency",
}

-- Saved keys that moved under a branch in Civil Service: legacy path -> current branch path. Saves hold
-- these names too (branch_* milestones, branchUnlocks), so civilServiceSkills migrates through this table.
-- Paths only; playerAttributes routes the saved police XP attribute without renaming this path.
-- (tests/career/police_skill_key_namespaces_test.lua pins both answers).
local legacyBranchPathAliases = {
  ["careerSkills-police"] = "careerSkills-civilService-police",
}
for oldName, newPath in pairs(legacyBranchPathAliases) do
  oldAttributeNamesToNewNames[oldName] = newPath
end

-- Saved attribute name -> the one legacy name a save may still use for it. A fixed one-to-one table:
-- inverting the many-to-one table above picked one of several old names at random per process
-- Readers try the canonical key first and this name only as a fallback.
local newAttributeNamesToOldNames = {
  ["logistics-delivery"] = "delivery",
  logistics = "labourer",
}

M.oldAttributeNamesToNewNames = oldAttributeNamesToNewNames
M.legacyBranchPathAliases = legacyBranchPathAliases
M.newAttributeNamesToOldNames = newAttributeNamesToOldNames

local function extractBranchPathIdFromFilePath(filePath)
  -- Get the directory path without the file name
  local infoDir, _, _ = path.split(filePath)

  -- Extracting folders
  local folders = {'domains'}
  for folder in string.gmatch(string.sub(dataFiles.toVanilla(infoDir), #branchesDir, -2), "[^/]+") do
      table.insert(folders, folder)
  end

  -- Build path ID from folders, excluding type names
  local pathId = ""
  local skipFolders = {domains = true, branches = true, skills = true}
  for _, folder in ipairs(folders) do
    if not skipFolders[folder] then
      if pathId ~= "" then
        pathId = pathId .. "-"
      end
      pathId = pathId .. folder
    end
  end

  return pathId
end

M.extractBranchPathIdFromFilePath = extractBranchPathIdFromFilePath

-- Reuse the profile skill catalog: explicit attribute keys, zero XP and hidden-until-progress rules.
local pauseCardSkills = require('overhaul/lib/career/profileReadModels').new({includeMaxLevel = true})
M.getPauseCardSummary = function()
  local data = {}
  pauseCardSkills.fillMenuProfileSkills(data, nil, true)
  return {kind = 'skills', label = 'Skills', rows = data.freSkills}
end

return M
