-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function sortByStartable(m1, m2)
  if m1.unlocks.maxBranchlevel ~= m2.unlocks.maxBranchlevel then
    return m1.unlocks.maxBranchlevel < m2.unlocks.maxBranchlevel
  end
  return m1.unlocks.startable and not m2.unlocks.startable
end

local function sortByFacId(f1, f2)
  if f1.id ~= f2.id then
    return f1.id < f2.id
  end
  return f1.startable and not f2.startable
end

local function getRewardIcons(rewards)
  local ret = {}
  --Get the names of the rewards
  for _, tierData in pairs(rewards) do
    for _, reward in ipairs(tierData) do
      ret[reward.attributeKey] = reward.rewardAmount
    end
  end
  local keys = tableKeys(ret)
  career_branches.orderAttributeKeysByBranchOrder(keys)
  local newRet = {}
  for _, attKey in ipairs(keys) do
    table.insert(newRet, {attributeKey = attKey, rewardAmount = ret[attKey], icon=career_branches.getBranchIcon(attKey) })
  end
  return newRet
end

local comingSoonCard = {heading="(Not Implemented)", type="unlockCard", icon="roadblockL"}
local function calculateUnlockInfo(skill, value, level)
  local unlockInfo = {}
  local unlocks = skill.levels

  if unlocks then
    local prevTarget = 0
    for i = 1, #unlocks do
      local prevLvlInfo = skill.levels[i-1]
      local curLvlInfo = skill.levels[i]
      local nextLvlInfo = skill.levels[i+1]
      local requiredRelative = (curLvlInfo and curLvlInfo.requiredValue or -1) - prevTarget

      prevTarget = (curLvlInfo and curLvlInfo.requiredValue or -1)
      unlockInfo[i] = {
        list = unlocks[i].unlocks,
        index = i,
        currentValue = prevLvlInfo and value - prevLvlInfo.requiredValue or -1,
        requiredValue = curLvlInfo and requiredRelative or -1,
        isInDevelopment = unlocks[i].isInDevelopment,
        isMaxLevel = unlocks[i].isMaxLevel,
        isBase = i == 1,
        unlocked = i >= level,
        description = unlocks[i].description,
        rewardMultiplier = unlocks[i].rewardMultiplier,
      }

    end
  end

  local maxRequiredValue = 0
  for _, value in ipairs(unlockInfo) do
    maxRequiredValue = maxRequiredValue + value.requiredValue
  end

  return unlockInfo, maxRequiredValue
end

local function getSkillsProgressForUi(branchId)
  local ret = {}
  --dump("getting skills for " .. branchId)
  for _, skill in pairs(career_branches.getSortedBranches()) do
    --dump(branchId .. " is a skill of " .. skill.id.." / "..dumps( skill.parentId))
    if skill.parentId == branchId then
      local attKey = skill.attributeKey
      local value = career_modules_playerAttributes.getAttributeValue(attKey)
      local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, skill.id)
      local skData = {
        icon = skill.icon,
        isSkill = skill.isSkill,
        id = skill.attributeKey,
        name = skill.name,
        description = skill.description,
        level = level,
        levelLabel = {txt='ui.career.lvlLabel', context={lvl=level}},
        unlocked = skill.unlocked,
        min = min,
        value = value,
        max = max,
        unlockInfo = {},
        order = skill.order,
        isInDevelopment = skill.isInDevelopment,
        hasLevels = skill.hasLevels,
        color = skill.color,
        accentColor = skill.accentColor,
      }

      if skill.showProgressAsStars then
        local total, unlocked = career_modules_branches_leagues.getStarsForSkill(skill.id)
        skData.levelLabel = nil
        skData.min, skData.value, skData.max = 0, unlocked, total
        skData.showProgressAsStars = true
      end

      if skill.levels then
        skData.unlockInfo, skData.maxRequiredValue = calculateUnlockInfo(skill, value, level)
      end
      --dumpz(skData.unlockInfo,2)

      table.insert(ret, skData)
    end
  end
  return ret
end

local deliverySystemIcon = {
  parcelDelivery = "boxPickUp03",
  trailerDelivery = "smallTrailer",
  vehicleDelivery = "keys1",
  smallFluidDelivery = "tankerTrailer",
  largeFluidDelivery = "tankerTrailer",
  smallDryBulkDelivery = "terrain",
  smallCementDelivery = "terrain",
  largeDryBulkDelivery = "terrain",
  largeCementDelivery = "terrain",
}

local function getFacilityProgress(fac)
  local ret = {
    deliveredFromHere = {
      countByType = {},
      moneySum = {
        money = {
        attributeKey = 'money',
        rewardAmount = fac.progress.deliveredFromHere.moneySum
        }
      }
    },
    deliveredToHere = {
      countByType = {},
      moneySum = {
        money = {
        attributeKey = 'money',
        rewardAmount = fac.progress.deliveredToHere.moneySum
        }
      }
    }
  }
  for key, value in pairs(fac.providedSystemsLookup) do
    if value then
      table.insert(ret.deliveredFromHere.countByType, {
        attributeKey = key,
        rewardAmount = fac.progress.deliveredFromHere.countByType[key],
        icon = deliverySystemIcon[key]
      })
    end
  end

  for key, value in pairs(fac.receivedSystemsLookup) do
    if value then
      table.insert(ret.deliveredToHere.countByType, {
        attributeKey = key,
        rewardAmount = fac.progress.deliveredToHere.countByType[key],
        icon = deliverySystemIcon[key]
      })
    end
  end

  return ret
end

local deliverySystemToSkill = {
  vehicleDelivery = "logistics-vehicleDelivery",
  parcelDelivery = "logistics-delivery",
  trailerDelivery = "logistics-delivery",
  smallDryBulkDelivery = "logistics-delivery",
  largeDryBulkDelivery = "logistics-delivery",
  smallCementDelivery = "logistics-delivery",
  largeCementDelivery = "logistics-delivery",
  smallFluidDelivery = "logistics-delivery",
  largeFluidDelivery = "logistics-delivery",
}
local function getSkillsForFacility(facility)
  local ret = {}
  for key, value in pairs(facility.providedSystemsLookup) do
    if value then
      ret[deliverySystemToSkill[key]] = true
    end
  end
  for key, value in pairs(facility.receivedSystemsLookup) do
    if value then
      ret[deliverySystemToSkill[key]] = true
    end
  end
  return tableKeysSorted(ret)
end

local function changeDarknesssColor(color, addedValue)
  local number = tonumber(color:match("(%d+)"))
  if number then
      -- Adding 100 to the number
      local new_number = number + addedValue
      local oValue = color:gsub("(%d+)", tostring(new_number))
      return oValue
  end
    return color
end

local function getFacilityAvailableOrders(fac)
  local ret = {}
  -- parcels
  local amounts = {available = 0, locked = 0}
  for _, item in ipairs(career_modules_delivery_parcelManager.getAllCargoForFacilityUnexpiredUndelivered(fac.id)) do
    career_modules_delivery_generator.finalizeParcelItemDistanceAndRewards(item)
    local modifierKeys = {}
    for _, mod in ipairs(item.modifiers or {}) do
      modifierKeys[mod.type] = true
    end
    local lockedBecauseOfMods, minTier = career_modules_delivery_parcelMods.lockedBecauseOfMods(modifierKeys)
    if lockedBecauseOfMods then
      amounts.locked = amounts.locked + 1
    else
      amounts.available = amounts.available + 1
    end
  end

  table.insert(ret, {
    icon = "cardboardBox",
    label = "Available Parcels",
    amounts = amounts,
    level = career_branches.getBranchLevel("logistics-delivery"),
  })

  -- trailers + vehicles
  for _, t in ipairs({
    {key="trailer", icon="smallTrailer", label="Available Trailers", skill="logistics-delivery"},
    {key="vehicle", icon="keys1",        label="Available Vehicles", skill="logistics-vehicleDelivery"}
  }) do
    local amounts = {available = 0, locked = 0}
    for _, item in ipairs(career_modules_delivery_vehicleOfferManager.getAllOfferAtFacilityUnexpired(fac.id)) do
      if item.data.type == t.key then
        local enabled, reason = career_modules_delivery_vehicleOfferManager.isVehicleTagUnlocked(item.vehicle.unlockTag)
        if enabled then
          amounts.available = amounts.available + 1
        else
          amounts.locked = amounts.locked + 1
        end
      end
    end
    table.insert(ret, {
      icon = t.icon,
      label = t.label,
      amounts = amounts,
      level = career_branches.getBranchLevel(t.skill),
    })
  end


  return ret

end

local function getFacilitiesData(color)
  local ret = {}
  local facilities = career_modules_delivery_generator.getFacilities()

  for i, fac in ipairs(facilities) do
    local data = {
      order = i,
      skill = getSkillsForFacility(fac),
      rewards = getFacilityProgress(fac),
      availableOrders = getFacilityAvailableOrders(fac),
      id = fac.id,
      icon = "garage01",
      label = fac.name,
      description = fac.description,
      visible = fac.progress.interacted or fac.alwaysVisible,
      locked = false, --need to know if it's unlocked or not
      startable = true, --need to know if it's startable or not
      thumbnailFile = fac.preview,
      tier = 0, --is there any tier?
      color = color,
      blockedColor = changeDarknesssColor(color, 100)
    }
    data.hasOrders = false
    for _, orders in ipairs(data.availableOrders) do
      if orders.amounts.available > 0 or orders.amounts.locked > 0 then
        data.hasOrders = true
      end
    end
    if data.hasOrders then
      table.insert(ret,data)
    end
  end
  return ret
end

local function getFiltersForSkills(skills)
  local ret = {}
  for _, s in ipairs(skills) do
    ret[s.id] = {
      value = s.id,
      label = s.name,
      order = s.order,
    }
  end
  return ret
end

local function getBranchPageData(branchId)
  local branch = {}
  career_branches.checkUnlocks()
  local branchData = career_branches.getBranchById(branchId)
  --Setup branch
  local attKey = branchData.attributeKey
  local value = career_modules_playerAttributes.getAttributeValue(attKey)
  local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, branchData.id)
  local levelLabel = career_branches.getLevelLabel(branchData.id, level)
  branch.skillInfo = {
    name = branchData.longName or branchData.name,
    icon = branchData.icon,
    glyphIcon = branchData.icon,
    color = branchData.color,
    accentColor = branchData.accentColor,
    id = attKey,
    levelLabel = levelLabel,
    isMaxLevel = level >= #branchData.levels,
    min = min,
    value = value,
    max = max,
    level = level,
    unlocked = branchData.unlocked,
    hasLevels = branchData.hasLevels,
    lockedReason = branchData.lockedReason,
    showOrganizations = branchData.showOrganizations,
    isInDevelopment = branchData.isInDevelopment,
  }

  if branchData.levels then
    branch.skillInfo.unlockInfo, branch.skillInfo.maxRequiredValue = calculateUnlockInfo(branchData, value, level)
  end

  --branchData.milestones = career_modules_milestones_milestones.getMilestones({branchData.attributeKey})
  branchData.skills = getSkillsProgressForUi(branchId)
  branch.details = branchData

  branch.leagues = career_modules_branches_leagues.getLeaguesForProgressBranchPage(branchId)


  --Sort the misison tables and add them to the main table that will be send to the UI
  for _, league in ipairs(branch.leagues) do
    for i, mId in ipairs(league.missions) do
      local m = gameplay_missions_missions.getMissionById(mId)
      league.missions[i] = M.formatMission(m)
      if league.isCertification then
        league.missions[i].icon = "badgeRoundStar"
      end
    end
  end


  if branch.details.attributeKey == "logistics" then
    branch.facilities = getFacilitiesData(branchData.color)
    table.sort(branch.facilities, sortByFacId)
  end

  branch.filters = getFiltersForSkills(branch.details.skills)
  branch.isBranch = true
  return branch
end


local function getBranchSkillCardData(branchId)
  -- first get all branches. then get all skills
  career_branches.checkUnlocks()
  local br = career_branches.getBranchById(branchId)
  local attKey = br.attributeKey
  local value = career_modules_playerAttributes.getAttributeValue(attKey)
  local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, br.id)
  local branchInfo = {
    name = br.name,
    description = br.description,
    shortDescription = br.shortDescription,
    id = br.id,
    levelLabel = career_branches.getLevelLabel(br.id, level),
    isMaxLevel = level >= #br.levels,
    unlocked = br.unlocked,
    cover = br.progressCover,
    icon = br.icon,
    glyphIcon = br.icon,
    color = br.color,
    accentColor = br.accentColor,
    min = min,
    value = value,
    max = max,
    skills = {},
    isDomain = br.isDomain,
    isSkill = br.isSkill,
    showProgressAsStars = br.showProgressAsStars,
    level = level,
    certifications = {},
    lockedReason = br.lockedReason,
    unlockInfos = br.unlockInfos,
    isInDevelopment = br.isInDevelopment,
  }


  -- certifications
  for _, certification in ipairs(br.certifications or {}) do
    local unlocked = career_modules_unlockFlags.getFlag(certification.unlockFlag)
    local flagDefinition = career_modules_unlockFlags.getFlagDefinition(certification.unlockFlag)
    local status =  "locked"
    local certificationMission = gameplay_missions_missions.getMissionById(certification.requiredMissionsToPass)
    if certificationMission and certificationMission.unlocks and certificationMission.unlocks.startable then
      status = "available"
    end
    if unlocked then
      status = "completed"
    end
    if br.name == "Commercial" then
      status = "available"
    end
    table.insert(branchInfo.certifications, {
      status = status,
      name = "ui.career.certification.name",
      statusLabel = 'ui.career.certification.status.' .. status,
      icon = "badgeRoundStar",
    })
  end

  for _, subBranch in pairs(career_branches.getSortedBranches()) do
    if subBranch.parentId == branchId then
      local attKey = subBranch.attributeKey
      local value = career_modules_playerAttributes.getAttributeValue(attKey)
      local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, subBranch.id)
      local skillInfo = {
        name = subBranch.name,
        levelLabel = career_branches.getLevelLabel(subBranch.id, level),
        isMaxLevel = level >= #subBranch.levels,
        unlocked = subBranch.unlocked,
        min = min,
        value = value,
        max = max,
        isInDevelopment = subBranch.isInDevelopment,
        hasLevels = subBranch.hasLevels,
        icon = subBranch.icon,
        level = level,
        color = subBranch.color,
        accentColor = subBranch.accentColor,
        showProgressAsStars = subBranch.showProgressAsStars,
        isBranch = subBranch.isBranch,
        isSkill = subBranch.isSkill,
      }
      if subBranch.showProgressAsStars then
        local total, unlocked = career_modules_branches_leagues.getStarsForSkill(subBranch.id)
        skillInfo.levelLabel = nil
        skillInfo.min, skillInfo.value, skillInfo.max = 0, unlocked, total
        skillInfo.showProgressAsStars = true
      end
      table.insert(branchInfo.skills, skillInfo)
    end
  end
  return branchInfo
end

local function openBigMapWithMissionSelected(missionId)
  freeroam_bigMapMode.enterBigMap({instant = true, missionId = missionId})
end

M.getBranchPageData = getBranchPageData
M.getBranchSkillCardData = getBranchSkillCardData
M.openBigMapWithMissionSelected = openBigMapWithMissionSelected

local formatMission = function(m)
  return {
    skill = {m.careerSetup.skill},
    id = m.id,
    icon = m.iconFontIcon,
    label = m.name,
    devMission = m.devMission,
    formattedProgress =  gameplay_missions_progress.formatSaveDataForUi(m.id),
    startable = m.unlocks.startable,
    preview = m.previewFile,
    thumbnail = m.thumbnailFile,
    locked = not m.unlocks.visible,
    canStartFromProgressScreen = m.startTrigger.level ~= nil and m.startTrigger.type == "league",
  }
end
M.formatMission = formatMission


local formatDriftSpot = function(ds)
  local ret = {
    skill = {"drift"},
    id = ds.id,
    icon = "drift02",
    label = ds.info.name,
    startable = true,
    preview = ds.info.preview,
  }
  if ds.info.objectives then
    local defaults = {}
    local defaultCount = 0
    for _, obj in ipairs(ds.info.objectives) do
      table.insert(defaults, ds.saveData.objectivesCompleted[obj.id] or false)
      defaultCount = defaultCount + (ds.saveData.objectivesCompleted[obj.id] and 1 or 0)
    end
    local formattedProgress = {
      unlockedStars = {
        totalBonusStarCount = 0,
        defaults = defaults,
        defaultCount = defaultCount
      }
    }
    ret.formattedProgress = formattedProgress
  end
  return ret
end
M.formatDriftSpot = formatDriftSpot
local function getLandingPageData(pathId)
  local data = {
    heading = "ui.career.landingPage.name",
    description = "ui.career.landingPage.description",
    branches = {},
    showMilestones = true,
    showOrganizations = true
  }

  local branches = career_branches.getSortedBranches()

  if not pathId or pathId == "" or pathId == "undefined" then
    -- Find all domains and determine their target type
    for _, branch in ipairs(branches) do
      if branch.isDomain then
        local hasBranches = false
        -- Check children of this domain
        for _, childBranch in ipairs(branches) do
          if childBranch.parentId == branch.id and childBranch.isBranch then
            hasBranches = true
            break
          end
        end
        table.insert(data.branches, {
          id = branch.id,
          target = hasBranches and "landing" or "skillPage",
          isSkill = branch.isSkill,
          description = branch.description,
        })
      end
    end
  else
    -- Find branches for this domain
    for _, branch in ipairs(branches) do
      if branch.parentId == pathId then
        table.insert(data.branches, {
          id = branch.id,
          target = "skillPage",
          isSkill = branch.isSkill,
          description = branch.description,
        })
      end
    end

    -- Set heading/description based on domain
    local domainBranch = career_branches.getBranchById(pathId)
    if domainBranch then
      data.heading = domainBranch.name
      data.description = domainBranch.description
      data.branchHeading = domainBranch.branchHeading
      local attKey = domainBranch.attributeKey
      local value = career_modules_playerAttributes.getAttributeValue(attKey)
      local level, _, _, min, max = career_branches.calcBranchLevelFromValue(value, domainBranch.id)
      data.skillInfo = {
        name = domainBranch.name,
        icon = domainBranch.icon,
        glyphIcon = domainBranch.icon,
        color = domainBranch.color,
        accentColor = domainBranch.accentColor,
        unlocked = domainBranch.unlocked,
        levelLabel = career_branches.getLevelLabel(domainBranch.id, level),
        isMaxLevel = level >= #domainBranch.levels,
        isInDevelopment = domainBranch.isInDevelopment,
        min = min,
        value = value,
        max = max,
        level = level,
        hasLevels = domainBranch.hasLevels,
      }
    end

  end
  return data
end

M.getLandingPageData = getLandingPageData

return M