-- Business skill-tree definitions, saved progress, upgrade purchases and computer payloads.
-- Read saved progress, costs, prerequisites, layout, purchases, liquidation, UI payloads, tabs, then game hooks and API.
local recordUpgrade = require("overhaul/lib/progression/logbookFeed").register("overhaul.businessUpgraded", {
  title = "Business upgraded", label = "Business", icon = "wrench"
}, "career/business/skillTree.lua")

local capabilities = require("overhaul/lib/platform/capabilities")
local M = {}
M.dependencies = {"overhaul_career_career"}

-- Config ------------------------------------------------------------------------------------------

local TREE_DIR = "/gameplay/overhaul/business/skillTrees/"
local PROGRESS_FILE = "/career/businessSkillTrees.json"
local LIQUIDATION_RATE = 0.70
-- Older saves kept these levels under team-operations; they now live under qol.
local LEGACY_QOL_KEYS = {"towing", "dyno"}

-- Node grid in pixels: rows follow dependency depth, columns centre each node under its parents.
local LAYOUT = {
  nodeWidth = 200,
  nodeHeight = 200,
  columnSpacing = 280,
  rowSpacing = 300,
  originX = 100,
  originY = 100,
}

-- State -------------------------------------------------------------------------------------------

local registeredBusinessTypes = {}
local skillTreeCache = {}
local skillTreeFileCache = {}
local skillTreeProgress = {}
-- The active profile's saved progress file, read once per career.
local allProgressData = nil

-- Saved progress ----------------------------------------------------------------------------------

local function removeBusinessKeys(progressByBusiness, businessId)
  progressByBusiness[businessId] = nil
  progressByBusiness[tostring(businessId)] = nil
  local numericId = tonumber(businessId)
  if numericId ~= nil then
    progressByBusiness[numericId] = nil
  end
end

local function getAllProgressData()
  if allProgressData then
    return allProgressData
  end
  if not overhaul_career_career.isActive() then
    return {}
  end
  local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
  if not savePath then
    return {}
  end
  local data = jsonReadFile(savePath .. PROGRESS_FILE)
  allProgressData = type(data) == "table" and data or {}
  return allProgressData
end

local function migrateLegacyTeamProgress(businessProgress)
  local team = businessProgress["team-operations"]
  if type(team) ~= "table" then
    return
  end
  businessProgress["qol"] = businessProgress["qol"] or {}
  local qol = businessProgress["qol"]
  for _, key in ipairs(LEGACY_QOL_KEYS) do
    local legacyLevel = tonumber(team[key]) or 0
    if legacyLevel > 0 then
      qol[key] = math.max(tonumber(qol[key]) or 0, legacyLevel)
      team[key] = nil
    end
  end
  -- The shop app needs the laptop it was sold with.
  if (tonumber(team["shop-app"]) or 0) > 0 and (tonumber(team["laptop"]) or 0) < 1 then
    team["laptop"] = 1
  end
end

local function loadSkillTreeProgress(businessId)
  if skillTreeProgress[businessId] then
    return skillTreeProgress[businessId]
  end
  if not overhaul_career_career.isActive() then
    return {}
  end
  local businessProgress = getAllProgressData()[businessId] or {}
  migrateLegacyTeamProgress(businessProgress)
  skillTreeProgress[businessId] = businessProgress
  return businessProgress
end

local function saveAllSkillTreeProgress(currentSavePath, removeBusinessId)
  if not currentSavePath then
    return
  end
  if not overhaul_career_career.isActive() then
    return
  end

  local existing = {}
  for businessId, progress in pairs(getAllProgressData()) do
    existing[businessId] = progress
  end
  if removeBusinessId then
    removeBusinessKeys(existing, removeBusinessId)
  end
  for businessId, progress in pairs(skillTreeProgress) do
    existing[businessId] = progress
  end

  overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. PROGRESS_FILE, existing, true)
end

-- Node progress -----------------------------------------------------------------------------------

local function notifyTreesUpdated(businessId)
  guihooks.trigger("businessSkillTree:onTreesUpdated", { businessId = businessId })
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

local function getDependencyNodeLevel(businessId, depId, trees)
  local progress = loadSkillTreeProgress(businessId)
  if trees then
    for _, tree in ipairs(trees) do
      for _, node in ipairs(tree.nodes or {}) do
        if node.id == depId then
          return (progress[tree.treeId] or {})[depId] or 0
        end
      end
    end
  end
  for _, treeProgress in pairs(progress) do
    if type(treeProgress) == "table" then
      local level = treeProgress[depId]
      if level and level > 0 then
        return level
      end
    end
  end
  return 0
end

-- Costs -------------------------------------------------------------------------------------------

-- A cost is a plain number, or {base, increment} where the increment is paid for every level already owned.
local function costAtLevel(cost, currentLevel)
  if not cost then
    return 0
  end
  if type(cost) == "number" then
    return cost
  end
  if type(cost) == "table" then
    local base = cost.base or cost[1] or 0
    local increment = cost.increment or cost[2] or 0
    return base + (increment * currentLevel)
  end
  return 0
end

local function calculateUpgradeCost(node, currentLevel)
  return costAtLevel(node.cost, currentLevel)
end

local function calculateUpgradeXPCost(node, currentLevel)
  return costAtLevel(node.xpCost, currentLevel)
end

-- Prerequisites -----------------------------------------------------------------------------------

local function checkPrerequisites(businessId, treeId, node, trees)
  -- Loading also caches the business entry, which the save writes even when it is empty.
  loadSkillTreeProgress(businessId)

  if node.dependencies and type(node.dependencies) == "table" and #node.dependencies > 0 then
    local hasAnyDependency = false
    for _, depId in ipairs(node.dependencies) do
      if getDependencyNodeLevel(businessId, depId, trees) > 0 then
        hasAnyDependency = true
        break
      end
    end
    if not hasAnyDependency then
      return false
    end
  end

  if not node.prerequisites then
    return true
  end
  for _, prereq in ipairs(node.prerequisites) do
    if prereq.type == "totalUpgrades" then
      if getTotalUpgradesInTree(businessId, treeId) < (prereq.min or 0) then
        return false
      end
    elseif prereq.nodeId then
      local requiredLevel = prereq.minLevel or 1
      if getDependencyNodeLevel(businessId, prereq.nodeId, trees) < requiredLevel then
        return false
      end
    end
  end
  return true
end

-- Layout ------------------------------------------------------------------------------------------

-- Depth is one more than the deepest dependency; a dependency missing from the tree counts as depth 0.
local function nodeDepth(layout, nodeId, visited)
  if visited[nodeId] then
    return layout.depths[nodeId] or 0
  end
  visited[nodeId] = true

  local node = layout.nodesById[nodeId]
  if not node then
    return 0
  end
  if layout.depths[nodeId] then
    return layout.depths[nodeId]
  end
  if not node.dependencies or #node.dependencies == 0 then
    layout.depths[nodeId] = 0
    return 0
  end

  local deepestDependency = -1
  for _, depId in ipairs(node.dependencies) do
    deepestDependency = math.max(deepestDependency, nodeDepth(layout, depId, visited))
  end
  layout.depths[nodeId] = deepestDependency + 1
  return layout.depths[nodeId]
end

-- Rows keyed by depth, each keeping the tree's own order.
local function groupNodesByDepth(nodes, layout)
  local rows = {}
  for _, node in ipairs(nodes) do
    local depth = nodeDepth(layout, node.id, {})
    rows[depth] = rows[depth] or {}
    table.insert(rows[depth], node)
  end
  return rows
end

local function deepestRow(rows)
  local deepest = 0
  for depth in pairs(rows) do
    if depth > deepest then
      deepest = depth
    end
  end
  return deepest
end

-- Nodes with identical dependencies share a signature; "none" marks a node without dependencies.
local function dependencySignature(node)
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

local function groupRowByDependencies(rowNodes)
  local groups = {}
  for idx, node in ipairs(rowNodes) do
    local signature = dependencySignature(node)
    if not groups[signature] then
      groups[signature] = {}
    end
    table.insert(groups[signature], { node = node, idx = idx })
  end
  return groups
end

-- A group centres under the average x of its placed parents, or on the origin column without any.
local function groupCenterX(signature, group, nodesById)
  if signature == "none" then
    return LAYOUT.originX
  end
  local parentXSum, parentCount = 0, 0
  for _, depId in ipairs(group[1].node.dependencies or {}) do
    local depNode = nodesById[depId]
    if depNode and depNode.position and depNode.position.x then
      parentXSum = parentXSum + depNode.position.x
      parentCount = parentCount + 1
    end
  end
  if parentCount == 0 then
    return LAYOUT.originX
  end
  return parentXSum / parentCount
end

-- Groups sit side by side around their centre; then each node is pushed right until it clears the one before.
local function layoutRow(rowNodes, rowY, nodesById)
  local groups = groupRowByDependencies(rowNodes)
  local centers = {}
  for signature, group in pairs(groups) do
    centers[signature] = groupCenterX(signature, group, nodesById)
  end

  local placements = {}
  for signature, group in pairs(groups) do
    local groupWidth = (#group - 1) * LAYOUT.columnSpacing
    local groupStartX = centers[signature] - (groupWidth / 2)
    for i, entry in ipairs(group) do
      table.insert(placements, {
        node = entry.node,
        desiredX = groupStartX + ((i - 1) * LAYOUT.columnSpacing),
        idx = entry.idx,
      })
    end
  end
  table.sort(placements, function(a, b)
    if math.abs(a.desiredX - b.desiredX) < 0.01 then
      return a.idx < b.idx
    end
    return a.desiredX < b.desiredX
  end)

  for i, placement in ipairs(placements) do
    local finalX = placement.desiredX
    if i > 1 then
      local previous = placements[i - 1].node
      if previous.position and previous.position.x then
        finalX = math.max(finalX, previous.position.x + LAYOUT.columnSpacing)
      end
    end
    placement.node.position = placement.node.position or {}
    placement.node.position.x = finalX
    placement.node.position.y = rowY
  end
end

-- The deepest row is drawn at the top of the view.
local function layoutRows(rows, deepest, nodesById)
  for depth = 0, deepest do
    if rows[depth] then
      layoutRow(rows[depth], LAYOUT.originY + ((deepest - depth) * LAYOUT.rowSpacing), nodesById)
    end
  end
end

-- Bounding box of the placed nodes, kept on the tree for the view.
local function storeTreeBounds(tree)
  local minX, maxX, minY, maxY
  for _, node in ipairs(tree.nodes) do
    if node.position then
      local x = node.position.x or 0
      local y = node.position.y or 0
      local right = x + LAYOUT.nodeWidth
      local bottom = y + LAYOUT.nodeHeight
      if minX == nil or x < minX then minX = x end
      if maxX == nil or right > maxX then maxX = right end
      if minY == nil or y < minY then minY = y end
      if maxY == nil or bottom > maxY then maxY = bottom end
    end
  end
  if minX == nil then
    return
  end

  tree.bounds = tree.bounds or {}
  tree.bounds.minX = minX
  tree.bounds.maxX = maxX
  tree.bounds.minY = minY
  tree.bounds.maxY = maxY
  tree.bounds.width = maxX - minX
  tree.bounds.height = maxY - minY
end

local function autoLayoutTree(tree)
  if not tree.nodes or #tree.nodes == 0 then
    return
  end
  local layout = { nodesById = {}, depths = {} }
  for _, node in ipairs(tree.nodes) do
    layout.nodesById[node.id] = node
  end
  local rows = groupNodesByDepth(tree.nodes, layout)
  layoutRows(rows, deepestRow(rows), layout.nodesById)
  storeTreeBounds(tree)
end

-- Tree definitions --------------------------------------------------------------------------------

local function loadSkillTreeFile(filePath)
  if not skillTreeFileCache[filePath] then
    skillTreeFileCache[filePath] = jsonReadFile(filePath)
  end
  return skillTreeFileCache[filePath]
end

-- A file without a businessType is shared by every business; a file for another type is skipped.
local function collectTreesFromFile(data, businessType, trees)
  if not data then
    return
  end
  local fileBusinessType = data.businessType
  if fileBusinessType and fileBusinessType ~= businessType then
    return
  end
  if not data.trees or type(data.trees) ~= "table" then
    return
  end
  for _, tree in ipairs(data.trees) do
    if tree.treeId and tree.nodes then
      table.insert(trees, tree)
    end
  end
end

local function loadSkillTreesForBusiness(businessType)
  if skillTreeCache[businessType] then
    return skillTreeCache[businessType]
  end

  local trees = {}
  if FS:directoryExists(TREE_DIR) then
    for _, filePath in ipairs(FS:findFiles(TREE_DIR, "*.json", 0, false, false)) do
      collectTreesFromFile(loadSkillTreeFile(filePath), businessType, trees)
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

-- Purchases ---------------------------------------------------------------------------------------

local function reachedMaxLevel(node, currentLevel)
  return node.maxLevel and currentLevel >= node.maxLevel
end

local function findNode(tree, nodeId)
  for _, node in ipairs(tree.nodes) do
    if node.id == nodeId then
      return node
    end
  end
  return nil
end

local function findUpgradeNode(trees, treeId, nodeId)
  for _, tree in ipairs(trees) do
    if tree.treeId == treeId then
      return findNode(tree, nodeId)
    end
  end
  return nil
end

local function businessHasMoney(businessType, businessId, cost)
  if not businessType then
    return false
  end
  return not (capabilities.get("businessComputer").getBusinessAccountBalance(businessType, businessId) < cost)
end

local function businessHasXP(businessType, businessId, xpCost)
  if not businessType then
    return false
  end
  return not (capabilities.get("businessComputer").getBusinessXP(businessType, businessId) < xpCost)
end

local function canAffordUpgrade(businessType, businessId, treeId, nodeId, trees)
  local node = findUpgradeNode(trees, treeId, nodeId)
  if not node then
    return false
  end

  local currentLevel = getNodeProgress(businessId, treeId, nodeId)
  if reachedMaxLevel(node, currentLevel) then
    return false
  end
  if not checkPrerequisites(businessId, treeId, node, trees) then
    return false
  end

  local cost = calculateUpgradeCost(node, currentLevel)
  if cost > 0 and not businessHasMoney(businessType, businessId, cost) then
    return false
  end
  local xpCost = calculateUpgradeXPCost(node, currentLevel)
  if xpCost > 0 and not businessHasXP(businessType, businessId, xpCost) then
    return false
  end
  return true
end

local function businessXPModule(businessType)
  local manager = overhaul_career_business_manager
  return manager and manager.getBusinessModule and manager.getBusinessModule(businessType) or nil
end

-- Returns true with the paying account id, or nil when the account cannot pay.
local function chargeUpgradeMoney(businessType, businessId, node, cost)
  local account = overhaul_career_economy_bank.getBusinessAccount(businessType, businessId)
  if not account then
    return nil
  end
  local paid = overhaul_career_economy_bank.payFromAccount({
    money = { amount = cost, canBeNegative = false },
  }, account.id, "Skill Upgrade", "Purchased " .. (node.title or "upgrade"), { category = "purchase" })
  if not paid then
    return nil
  end
  return true, account.id
end

local function refundUpgradeMoney(accountId, node, cost)
  overhaul_career_economy_bank.rewardToAccount({ money = { amount = cost } }, accountId, "Skill Upgrade Refund",
    "Refund: " .. (node.title or "upgrade"), { category = "refund" })
end

local function purchaseUpgrade(businessType, businessId, treeId, nodeId)
  if not businessType or not businessId or not treeId or not nodeId then
    return false
  end

  local trees = loadSkillTreesForBusiness(businessType)
  if not canAffordUpgrade(businessType, businessId, treeId, nodeId, trees) then
    return false
  end
  local node = findUpgradeNode(trees, treeId, nodeId)
  if not node then
    return false
  end
  local currentLevel = getNodeProgress(businessId, treeId, nodeId)
  if reachedMaxLevel(node, currentLevel) then
    return false
  end

  local xpCost = calculateUpgradeXPCost(node, currentLevel)
  local xpModule = businessXPModule(businessType)
  if xpCost > 0 and not (xpModule and xpModule.spendBusinessXP) then
    return false
  end

  local cost = calculateUpgradeCost(node, currentLevel)
  local paidAccountId
  if cost > 0 then
    local paid
    paid, paidAccountId = chargeUpgradeMoney(businessType, businessId, node, cost)
    if not paid then
      return false
    end
  end

  if xpCost > 0 and not xpModule.spendBusinessXP(businessId, xpCost) then
    if paidAccountId then
      refundUpgradeMoney(paidAccountId, node, cost)
    end
    return false
  end

  setNodeProgress(businessId, treeId, nodeId, currentLevel + 1)
  recordUpgrade({name = node.title or node.name or node.label or nodeId,
    facts = {{label = "Upgrade", value = node.title or node.name or node.label or nodeId},
      {label = "Level", value = currentLevel + 1}}, money = -cost})
  Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Buy_01')
  gameplay_rawPois.clear()
  overhaul_ui_recoveryPrompt.addTowingButtons()
  overhaul_ui_recoveryPrompt.addTaxiButtons()
  return true
end

-- Liquidation -------------------------------------------------------------------------------------

-- What the business gets back when sold: a fixed share of everything spent on upgrades.
local function getLiquidationValue(businessType, businessId)
  if not businessType or not businessId then
    return 0
  end

  local trees = loadSkillTreesForBusiness(businessType)
  local progress = loadSkillTreeProgress(businessId)
  local total = 0
  for _, tree in ipairs(trees) do
    local treeProgress = progress[tree.treeId] or {}
    for _, node in ipairs(tree.nodes or {}) do
      local purchasedLevels = math.floor(tonumber(treeProgress[node.id]) or 0)
      for level = 0, purchasedLevels - 1 do
        total = total + calculateUpgradeCost(node, level)
      end
    end
  end
  return math.floor((total * LIQUIDATION_RATE) + 0.5)
end

-- UI payloads -------------------------------------------------------------------------------------

local function businessBalances(businessType, businessId)
  if not businessType then
    return 0, 0
  end
  local balance = tonumber(capabilities.get("businessComputer").getBusinessAccountBalance(businessType, businessId)) or 0
  local xp = tonumber(capabilities.get("businessComputer").getBusinessXP(businessType, businessId)) or 0
  return balance, xp
end

local function boundsView(bounds)
  return {
    minX = bounds.minX,
    maxX = bounds.maxX,
    minY = bounds.minY,
    maxY = bounds.maxY,
    width = bounds.width,
    height = bounds.height,
  }
end

local function nodeView(node, nodeLevel, unlocked, balance, xp)
  local maxed = reachedMaxLevel(node, nodeLevel)
  local nextMoneyCost = calculateUpgradeCost(node, nodeLevel)
  local nextXPCost = calculateUpgradeXPCost(node, nodeLevel)
  local affordableMoney = (nextMoneyCost <= 0) or (balance >= nextMoneyCost)
  local affordableXP = (nextXPCost <= 0) or (xp >= nextXPCost)
  return {
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
    unlocked = unlocked,
    affordable = unlocked and (not maxed) and affordableMoney and affordableXP,
    affordableMoney = affordableMoney,
    affordableXP = affordableXP,
    nextMoneyCost = nextMoneyCost,
    nextXPCost = nextXPCost,
    maxed = maxed,
    xpCost = node.xpCost,
    commingSoon = node.commingSoon,
  }
end

local function treeView(businessId, tree, trees, progress, balance, xp)
  local view = {
    treeId = tree.treeId,
    treeName = tree.treeName,
    description = tree.description,
    icon = tree.icon,
    nodes = {},
  }
  if tree.bounds then
    view.bounds = boundsView(tree.bounds)
  end

  local treeProgress = progress[tree.treeId] or {}
  for _, node in ipairs(tree.nodes) do
    local nodeLevel = treeProgress[node.id] or 0
    local unlocked = checkPrerequisites(businessId, tree.treeId, node, trees)
    table.insert(view.nodes, nodeView(node, nodeLevel, unlocked, balance, xp))
  end
  return view
end

local function getTreesForBusiness(businessType, businessId)
  local trees = loadSkillTreesForBusiness(businessType)
  local progress = loadSkillTreeProgress(businessId)
  local balance, xp = businessBalances(businessType, businessId)
  local result = {}
  for _, tree in ipairs(trees) do
    table.insert(result, treeView(businessId, tree, trees, progress, balance, xp))
  end
  return result
end

-- Debug and cleanup -------------------------------------------------------------------------------

local function clearBusinessProgress(businessId)
  if not businessId then
    return false
  end
  removeBusinessKeys(skillTreeProgress, businessId)
  removeBusinessKeys(getAllProgressData(), businessId)
  notifyTreesUpdated(businessId)
  return true
end

local function debugMaxAllNodes(businessType, businessId)
  if not businessType or not businessId then
    return false
  end
  local trees = loadSkillTreesForBusiness(businessType)
  if not trees or #trees == 0 then
    log("W", "businessSkillTree", "debugMaxAllNodes: no skill trees for businessType=" .. tostring(businessType))
    return false
  end
  for _, tree in ipairs(trees) do
    for _, node in ipairs(tree.nodes or {}) do
      if node.id then
        setNodeProgress(businessId, tree.treeId, node.id, node.maxLevel or 1)
      end
    end
  end
  notifyTreesUpdated(businessId)
  return true
end

-- Tabs and requests -------------------------------------------------------------------------------

local function registerSkillTreeTabs(businessType)
  if not overhaul_career_business_tabRegistry then
    return
  end
  if registeredBusinessTypes[businessType] then
    return
  end

  local trees = loadSkillTreesForBusiness(businessType)
  if #trees > 0 then
    overhaul_career_business_tabRegistry.registerTab(businessType, {
      id = "skill-tree",
      label = "Skill Trees",
      icon = '<path d="M12 2L2 7l10 5 10-5-10-5zM2 17l10 5 10-5M2 12l10 5 10-5"/>',
      component = "BusinessSkillTreeTab",
      section = "BASIC",
      order = 100,
      data = {
        businessType = businessType,
      },
    })
  end
  registeredBusinessTypes[businessType] = true
end

local function requestSkillTrees(requestId, businessType, businessId)
  guihooks.trigger('businessSkillTree:onTreesResponse', {
    requestId = requestId,
    success = true,
    businessType = businessType,
    businessId = businessId,
    trees = getTreesForBusiness(businessType, businessId),
  })
end

local function requestPurchaseUpgrade(requestId, businessType, businessId, treeId, nodeId)
  local success = purchaseUpgrade(businessType, businessId, treeId, nodeId)
  guihooks.trigger('businessSkillTree:onPurchaseResponse', {
    requestId = requestId,
    success = success,
    businessId = businessId,
    treeId = treeId,
    nodeId = nodeId,
  })
  if success then
    overhaul_career_saveSystem.saveCurrent()
    guihooks.trigger('businessSkillTree:onTreesUpdated', {
      businessType = businessType,
      businessId = businessId,
      trees = getTreesForBusiness(businessType, businessId),
    })
  end
end

-- Public API --------------------------------------------------------------------------------------

M.getTreesForBusiness = getTreesForBusiness
M.purchaseUpgrade = purchaseUpgrade
M.canAffordUpgrade = canAffordUpgrade
M.getTotalUpgradesInTree = getTotalUpgradesInTree
M.getNodeProgress = getNodeProgress
M.getLiquidationValue = getLiquidationValue
M.clearBusinessProgress = clearBusinessProgress
M.debugMaxAllNodes = debugMaxAllNodes
M.ensureTabsRegistered = registerSkillTreeTabs
M.requestSkillTrees = requestSkillTrees
M.requestPurchaseUpgrade = requestPurchaseUpgrade

-- Game hooks --------------------------------------------------------------------------------------

function M.onWorldReadyState(worldReadyState)
  if worldReadyState == 2 and overhaul_career_career.isActive() then
    local facilities = overhaul_world_facilities.getFacilities(getCurrentLevelIdentifier())
    for businessType in pairs(facilities or {}) do
      registerSkillTreeTabs(businessType)
    end
  end
end

function M.onCareerActivated()
  skillTreeProgress = {}
  allProgressData = nil
end

function M.onOverhaulSaveCurrentProfile(currentSavePath)
  if not currentSavePath then
    return
  end
  local success, err = pcall(saveAllSkillTreeProgress, currentSavePath)
  if not success then
    log("E", "businessSkillTree", "onOverhaulSaveCurrentProfile failed: " .. tostring(err))
  end
end

return M
