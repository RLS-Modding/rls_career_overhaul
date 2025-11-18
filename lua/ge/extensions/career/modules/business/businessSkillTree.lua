local M = {}

M.dependencies = {'career_career', 'career_saveSystem'}

local skillTreeCache = {}
local skillTreeProgress = {}

local function loadSkillTreeFile(filePath)
  if not filePath then
    return nil
  end
  local data = jsonReadFile(filePath)
  return data
end

local function getSkillTreeFilePath(businessType, treeFileName)
  local basePath = "lua/ge/extensions/career/modules/business/skillTrees/"
  local filePath = basePath .. treeFileName
  if FS:fileExists(filePath) then
    return filePath
  end
  return nil
end

local registeredBusinessTypes = {}

local function autoLayoutTree(tree)
  if not tree or not tree.nodes or #tree.nodes == 0 then
    return
  end

  local NODE_WIDTH = 200
  local NODE_HEIGHT = 200
  local NODE_SPACING_X = 280
  local NODE_SPACING_Y = 300
  local START_X = 100
  local START_Y = 100

  local nodeMap = {}
  local levels = {}
  local nodeLevels = {}

  for _, node in ipairs(tree.nodes) do
    nodeMap[node.id] = node
  end

  local function getNodeLevel(nodeId, visited)
    if visited[nodeId] then
      return nodeLevels[nodeId] or 0
    end
    visited[nodeId] = true

    local node = nodeMap[nodeId]
    if not node then
      return 0
    end

    if nodeLevels[nodeId] then
      return nodeLevels[nodeId]
    end

    if not node.dependencies or #node.dependencies == 0 then
      nodeLevels[nodeId] = 0
      return 0
    end

    local maxDepLevel = -1
    for _, depId in ipairs(node.dependencies) do
      local depLevel = getNodeLevel(depId, visited)
      if depLevel > maxDepLevel then
        maxDepLevel = depLevel
      end
    end

    local level = maxDepLevel + 1
    nodeLevels[nodeId] = level
    return level
  end

  for _, node in ipairs(tree.nodes) do
    local visited = {}
    local level = getNodeLevel(node.id, visited)

    if not levels[level] then
      levels[level] = {}
    end
    table.insert(levels[level], node)
  end

  local maxLevel = 0
  for level, _ in pairs(levels) do
    if level > maxLevel then
      maxLevel = level
    end
  end

  for level = 0, maxLevel do
    local nodes = levels[level]
    if not nodes then
      break
    end

    local y = START_Y + ((maxLevel - level) * NODE_SPACING_Y)
    
    local function getDependencyKey(node)
      if not node.dependencies or #node.dependencies == 0 then
        return "none"
      end
      local sorted = {}
      for _, depId in ipairs(node.dependencies) do
        table.insert(sorted, depId)
      end
      table.sort(sorted)
      return table.concat(sorted, ",")
    end
    
    local groups = {}
    for idx, node in ipairs(nodes) do
      local key = getDependencyKey(node)
      if not groups[key] then
        groups[key] = {}
      end
      table.insert(groups[key], { node = node, idx = idx })
    end
    
    local groupCenters = {}
    for key, groupNodes in pairs(groups) do
      local centerX = START_X
      
      if key ~= "none" then
        local firstNode = groupNodes[1].node
        if firstNode.dependencies and #firstNode.dependencies > 0 then
          local parentXSum = 0
          local parentCount = 0
          for _, depId in ipairs(firstNode.dependencies) do
            local depNode = nodeMap[depId]
            if depNode and depNode.position and depNode.position.x then
              parentXSum = parentXSum + depNode.position.x
              parentCount = parentCount + 1
            end
          end
          if parentCount > 0 then
            centerX = parentXSum / parentCount
          end
        end
      end
      
      groupCenters[key] = centerX
    end
    
    local allNodePositions = {}
    for key, groupNodes in pairs(groups) do
      local centerX = groupCenters[key]
      local groupSize = #groupNodes
      local groupTotalWidth = (groupSize - 1) * NODE_SPACING_X
      local groupStartX = centerX - (groupTotalWidth / 2)
      
      for i, groupNode in ipairs(groupNodes) do
        local x = groupStartX + ((i - 1) * NODE_SPACING_X)
        table.insert(allNodePositions, { node = groupNode.node, desiredX = x, idx = groupNode.idx })
      end
    end
    
    table.sort(allNodePositions, function(a, b)
      if math.abs(a.desiredX - b.desiredX) < 0.01 then
        return a.idx < b.idx
      end
      return a.desiredX < b.desiredX
    end)
    
    for i, posData in ipairs(allNodePositions) do
      local node = posData.node
      local desiredX = posData.desiredX
      
      local finalX = desiredX
      if i > 1 then
        local prevNode = allNodePositions[i - 1].node
        local minX = prevNode.position.x + NODE_SPACING_X
        finalX = math.max(finalX, minX)
      end
      
      if not node.position then
        node.position = {}
      end
      node.position.x = finalX
      node.position.y = y
    end
  end

  local minX, maxX, minY, maxY = nil, nil, nil, nil
  for _, node in ipairs(tree.nodes) do
    if node.position then
      local x = node.position.x or 0
      local y = node.position.y or 0
      local nodeRight = x + NODE_WIDTH
      local nodeBottom = y + NODE_HEIGHT

      if minX == nil or x < minX then
        minX = x
      end
      if maxX == nil or nodeRight > maxX then
        maxX = nodeRight
      end
      if minY == nil or y < minY then
        minY = y
      end
      if maxY == nil or nodeBottom > maxY then
        maxY = nodeBottom
      end
    end
  end

  if minX and maxX and minY and maxY then
    if not tree.bounds then
      tree.bounds = {}
    end
    tree.bounds.minX = minX
    tree.bounds.maxX = maxX
    tree.bounds.minY = minY
    tree.bounds.maxY = maxY
    tree.bounds.width = maxX - minX
    tree.bounds.height = maxY - minY
  end
end

local function loadSkillTreesForBusiness(businessType)
  if skillTreeCache[businessType] then
    return skillTreeCache[businessType]
  end

  local trees = {}
  local skillTreesDir = "/lua/ge/extensions/career/modules/business/skillTrees/"

  if not FS:directoryExists(skillTreesDir) then
    skillTreeCache[businessType] = trees
    return trees
  end

  local files = FS:findFiles(skillTreesDir, "*.json", 0, false, false)

  for _, filePath in ipairs(files) do
    local data = loadSkillTreeFile(filePath)
    if data then
      local fileBusinessType = data.businessType
      if not fileBusinessType or fileBusinessType == businessType then
        if data.trees and type(data.trees) == "table" then
          for _, tree in ipairs(data.trees) do
            if tree.treeId and tree.nodes then
              table.insert(trees, tree)
            end
          end
        end
      end
    end
  end

  for _, tree in ipairs(trees) do
    if tree.nodes then
      autoLayoutTree(tree)
    end
  end

  skillTreeCache[businessType] = trees
  return trees
end

local function loadSkillTreeProgress(businessId)
  if skillTreeProgress[businessId] then
    return skillTreeProgress[businessId]
  end

  if not career_career.isActive() then
    return {}
  end

  local _, savePath = career_saveSystem.getCurrentSaveSlot()
  if not savePath then
    return {}
  end

  local filePath = savePath .. "/career/businessSkillTrees.json"
  local data = jsonReadFile(filePath) or {}
  local businessProgress = data[businessId] or {}

  skillTreeProgress[businessId] = businessProgress
  return businessProgress
end

local function saveAllSkillTreeProgress(currentSavePath)
  if not currentSavePath then
    return
  end

  if not career_career.isActive() then
    return
  end

  local filePath = currentSavePath .. "/career/businessSkillTrees.json"
  local data = jsonReadFile(filePath) or {}
  
  for businessId, progress in pairs(skillTreeProgress) do
    data[businessId] = progress
  end
  
  career_saveSystem.jsonWriteFileSafe(filePath, data, true)
end

local function getNodeProgress(businessId, treeId, nodeId)
  local progress = loadSkillTreeProgress(businessId)
  local treeProgress = progress[treeId] or {}
  return treeProgress[nodeId] or 0
end

local function setNodeProgress(businessId, treeId, nodeId, level)
  if not skillTreeProgress[businessId] then
    skillTreeProgress[businessId] = {}
  end
  if not skillTreeProgress[businessId][treeId] then
    skillTreeProgress[businessId][treeId] = {}
  end
  skillTreeProgress[businessId][treeId][nodeId] = level
end

local function getTotalUpgradesInTree(businessId, treeId)
  local progress = loadSkillTreeProgress(businessId)
  local treeProgress = progress[treeId] or {}
  local total = 0
  for _, level in pairs(treeProgress) do
    total = total + (level or 0)
  end
  return total
end

local function checkPrerequisites(businessId, treeId, node, trees)
  local progress = loadSkillTreeProgress(businessId)
  local treeProgress = progress[treeId] or {}

  -- Check dependencies first (OR logic - need at least ONE)
  if node.dependencies and type(node.dependencies) == "table" and #node.dependencies > 0 then
    local hasAnyDependency = false

    for _, depId in ipairs(node.dependencies) do
      local depLevel = treeProgress[depId] or 0
      if depLevel > 0 then
        hasAnyDependency = true
        break
      end
    end

    if not hasAnyDependency then
      return false
    end
  end

  -- Check prerequisites (AND logic - need ALL)
  if not node.prerequisites then
    return true
  end

  for _, prereq in ipairs(node.prerequisites) do
    if prereq.type == "totalUpgrades" then
      local total = getTotalUpgradesInTree(businessId, treeId)
      if total < (prereq.min or 0) then
        return false
      end
    elseif prereq.nodeId then
      local nodeLevel = treeProgress[prereq.nodeId] or 0
      local requiredLevel = prereq.minLevel or 1
      if nodeLevel < requiredLevel then
        return false
      end
    end
  end

  return true
end

local function calculateUpgradeCost(node, currentLevel)
  if not node.cost then
    return 0
  end

  if type(node.cost) == "number" then
    return node.cost
  end

  if type(node.cost) == "table" then
    local base = node.cost.base or node.cost[1] or 0
    local increment = node.cost.increment or node.cost[2] or 0
    return base + (increment * currentLevel)
  end

  return 0
end

local function canAffordUpgrade(businessType, businessId, treeId, nodeId, trees)
  local tree = nil
  for _, t in ipairs(trees) do
    if t.treeId == treeId then
      tree = t
      break
    end
  end

  if not tree then
    return false
  end

  local node = nil
  for _, n in ipairs(tree.nodes) do
    if n.id == nodeId then
      node = n
      break
    end
  end

  if not node then
    return false
  end

  local currentLevel = getNodeProgress(businessId, treeId, nodeId)
  if node.maxLevel and currentLevel >= node.maxLevel then
    return false
  end

  if not checkPrerequisites(businessId, treeId, node, trees) then
    return false
  end

  local cost = calculateUpgradeCost(node, currentLevel)
  if cost <= 0 then
    return true
  end

  if businessType and career_modules_business_businessComputer then
    local balance = career_modules_business_businessComputer.getBusinessAccountBalance(businessType, businessId)
    return balance >= cost
  end

  return false
end

local function purchaseUpgrade(businessType, businessId, treeId, nodeId)
  if not businessType or not businessId or not treeId or not nodeId then
    return false
  end

  local trees = loadSkillTreesForBusiness(businessType)
  if not canAffordUpgrade(businessType, businessId, treeId, nodeId, trees) then
    return false
  end

  local tree = nil
  for _, t in ipairs(trees) do
    if t.treeId == treeId then
      tree = t
      break
    end
  end

  if not tree then
    return false
  end

  local node = nil
  for _, n in ipairs(tree.nodes) do
    if n.id == nodeId then
      node = n
      break
    end
  end

  if not node then
    return false
  end

  local currentLevel = getNodeProgress(businessId, treeId, nodeId)
  if node.maxLevel and currentLevel >= node.maxLevel then
    return false
  end

  local cost = calculateUpgradeCost(node, currentLevel)
  if cost > 0 then
    if businessType and career_modules_bank then
      local account = career_modules_bank.getBusinessAccount(businessType, businessId)
      if account then
        local success = career_modules_bank.payFromAccount({
          money = {
            amount = cost,
            canBeNegative = false
          }
        }, account.id)
        if not success then
          return false
        end
      else
        return false
      end
    else
      return false
    end
  end

  setNodeProgress(businessId, treeId, nodeId, currentLevel + 1)
  return true
end

local function getTreesForBusiness(businessType, businessId)
  local trees = loadSkillTreesForBusiness(businessType)
  local progress = loadSkillTreeProgress(businessId)

  local result = {}
  for _, tree in ipairs(trees) do
    local treeData = {
      treeId = tree.treeId,
      treeName = tree.treeName,
      description = tree.description,
      icon = tree.icon,
      nodes = {}
    }

    if tree.bounds then
      treeData.bounds = {
        minX = tree.bounds.minX,
        maxX = tree.bounds.maxX,
        minY = tree.bounds.minY,
        maxY = tree.bounds.maxY,
        width = tree.bounds.width,
        height = tree.bounds.height
      }
    end

    local treeProgress = progress[tree.treeId] or {}
    for _, node in ipairs(tree.nodes) do
      local nodeLevel = treeProgress[node.id] or 0
      local nodeData = {
        id = node.id,
        title = node.title,
        description = node.description,
        detailedDescription = node.detailedDescription,
        cost = node.cost,
        maxLevel = node.maxLevel,
        currentLevel = nodeLevel,
        dependencies = node.dependencies,
        prerequisites = node.prerequisites,
        position = node.position,
        unlocked = checkPrerequisites(businessId, tree.treeId, node, trees),
        affordable = canAffordUpgrade(businessType, businessId, tree.treeId, node.id, trees),
        maxed = node.maxLevel and nodeLevel >= node.maxLevel
      }
      table.insert(treeData.nodes, nodeData)
    end

    table.insert(result, treeData)
  end

  return result
end

local function registerSkillTreeTabs(businessType)
  if not career_modules_business_businessTabRegistry then
    return
  end

  if registeredBusinessTypes[businessType] then
    return
  end

  local trees = loadSkillTreesForBusiness(businessType)

  if #trees > 0 then
    career_modules_business_businessTabRegistry.registerTab(businessType, {
      id = "skill-tree",
      label = "Skill Trees",
      icon = '<path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/>',
      component = "BusinessSkillTreeTab",
      section = "BASIC",
      order = 100,
      data = {
        businessType = businessType
      }
    })
  end

  registeredBusinessTypes[businessType] = true
end

local function ensureTabsRegistered(businessType)
  registerSkillTreeTabs(businessType)
end

local function requestSkillTrees(requestId, businessType, businessId)
  local trees = getTreesForBusiness(businessType, businessId)
  guihooks.trigger('businessSkillTree:onTreesResponse', {
    requestId = requestId,
    success = true,
    businessType = businessType,
    businessId = businessId,
    trees = trees
  })
end

local function requestPurchaseUpgrade(requestId, businessType, businessId, treeId, nodeId)
  local success = purchaseUpgrade(businessType, businessId, treeId, nodeId)
  guihooks.trigger('businessSkillTree:onPurchaseResponse', {
    requestId = requestId,
    success = success,
    businessId = businessId,
    treeId = treeId,
    nodeId = nodeId
  })
  if success then
    career_saveSystem.saveCurrent()
    local updatedTrees = getTreesForBusiness(businessType, businessId)
    guihooks.trigger('businessSkillTree:onTreesUpdated', {
      businessType = businessType,
      businessId = businessId,
      trees = updatedTrees
    })
  end
end


local function onWorldReadyState(state)
  if state == 2 and career_career.isActive() then
    if freeroam_facilities then
      local facilities = freeroam_facilities.getFacilities()
      if facilities then
        for businessType, _ in pairs(facilities) do
          registerSkillTreeTabs(businessType)
        end
      end
    end
  end
end

local function onSaveCurrentSaveSlot(currentSavePath)
  if not currentSavePath then
    return
  end
  local success, err = pcall(function()
    saveAllSkillTreeProgress(currentSavePath)
  end)
  if not success then
    log("E", "businessSkillTree", "onSaveCurrentSaveSlot failed: " .. tostring(err))
  end
end

M.getTreesForBusiness = getTreesForBusiness
M.purchaseUpgrade = purchaseUpgrade
M.canAffordUpgrade = canAffordUpgrade
M.getTotalUpgradesInTree = getTotalUpgradesInTree
M.getNodeProgress = getNodeProgress
M.ensureTabsRegistered = ensureTabsRegistered
M.requestSkillTrees = requestSkillTrees
M.requestPurchaseUpgrade = requestPurchaseUpgrade
M.onWorldReadyState = onWorldReadyState
M.onSaveCurrentSaveSlot = onSaveCurrentSaveSlot

return M

