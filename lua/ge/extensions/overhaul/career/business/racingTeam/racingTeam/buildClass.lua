-- Compare team builds with factory baselines to choose sanctioned power classes.
-- Read configuration and caches, branch helpers, baseline comparisons and public queries.
local M = {}

-- Config ------------------------------------------------------------------------------------------

M.ENABLED = true
local MAX_PART_TREE_NODES = 12000

local rankByBranch = { stock = 1, modified = 2, super = 3, open = 4 }

-- State -------------------------------------------------------------------------------------------

local baselineConfigKeyByModel = {}
local baselinePartsMapByModel = {}
local eligibleFactoryBaselineScanDone = false

-- Branch helpers ----------------------------------------------------------------------------------

local function branchRank(branch)
  return rankByBranch[tostring(branch or "")] or 0
end

local function branchFromRank(r)
  r = math.floor(tonumber(r) or 0)
  if r >= 4 then
    return "open"
  end
  if r >= 3 then
    return "super"
  end
  if r >= 2 then
    return "modified"
  end
  return "stock"
end

-- Factory baselines -------------------------------------------------------------------------------

local function catalogPowerHp(vi)
  if not vi or type(vi) ~= "table" then
    return nil
  end
  local power = tonumber(vi.Power)
  if not power and vi.aggregates and vi.aggregates.Power then
    local agg = vi.aggregates.Power
    power = tonumber(agg.min) or tonumber(agg.max)
  end
  if power and power > 0 then
    return power
  end
  return nil
end

local function ensureEligibleFactoryBaselinesCached()
  if eligibleFactoryBaselineScanDone then
    return
  end
  eligibleFactoryBaselineScanDone = true
  local gen = util_configListGenerator
  local eligible = gen.getEligibleVehicles(false, false) or {}
  local bestByModel = {}
  for _, vi in ipairs(eligible) do
    if type(vi) == "table" and type(vi.model_key) == "string" and vi.model_key ~= "" then
      local configType = vi["Config Type"]
      if not configType and vi.aggregates and vi.aggregates["Config Type"] then
        configType = next(vi.aggregates["Config Type"])
      end
      if configType == "Factory" and type(vi.key) == "string" and vi.key ~= "" then
        local p = catalogPowerHp(vi) or 1e9
        local row = bestByModel[vi.model_key]
        if not row or p < row.power then
          bestByModel[vi.model_key] = { key = vi.key, power = p }
        end
      end
    end
  end
  for mk, row in pairs(bestByModel) do
    baselineConfigKeyByModel[mk] = row.key
  end
end
local function pickFactoryBaselineConfigKey(modelKey)
  if not modelKey or modelKey == "" then
    return nil
  end
  local memo = baselineConfigKeyByModel[modelKey]
  if memo ~= nil then
    if memo == false then
      return nil
    end
    return memo
  end
  ensureEligibleFactoryBaselinesCached()
  memo = baselineConfigKeyByModel[modelKey]
  if memo ~= nil then
    if memo == false then
      return nil
    end
    return memo
  end
  local bestKey = nil
  local info = jsonReadFile("/vehicles/" .. modelKey .. "/info.json")
  if type(info) == "table" and type(info.default_pc) == "string" and info.default_pc ~= "" then
    bestKey = info.default_pc:gsub("%.pc$", "")
  end
  baselineConfigKeyByModel[modelKey] = bestKey or false
  return bestKey
end

local function stripPcExtension(key)
  if type(key) ~= "string" then
    return nil
  end
  return (key:gsub("%.pc$", ""))
end

local function normalizeConfigKeyForCompare(key)
  if type(key) ~= "string" or key == "" then
    return nil
  end
  return string.lower(stripPcExtension(key) or "")
end

local function loadBaselinePartsMap(modelKey)
  local memo = baselinePartsMapByModel[modelKey]
  if memo ~= nil then
    if memo == false then
      return nil
    end
    return memo
  end
  local cfgKey = pickFactoryBaselineConfigKey(modelKey)
  if not cfgKey then
    baselinePartsMapByModel[modelKey] = false
    return nil
  end
  local rel = "/vehicles/" .. modelKey .. "/" .. stripPcExtension(cfgKey) .. ".pc"
  local pc = jsonReadFile(rel)
  if type(pc) ~= "table" or type(pc.parts) ~= "table" then
    baselinePartsMapByModel[modelKey] = false
    return nil
  end
  baselinePartsMapByModel[modelKey] = pc.parts
  return pc.parts
end

-- Build comparisons -------------------------------------------------------------------------------

local function flattenPartsTreeToSlotParts(tree, out, acc)
  if type(tree) ~= "table" then
    return out
  end
  out = out or {}
  acc = acc or { n = 0 }
  acc.n = acc.n + 1
  if acc.n > MAX_PART_TREE_NODES then
    return out
  end
  if type(tree.chosenPartName) == "string" and tree.chosenPartName ~= "" and type(tree.path) == "string" then
    local leaf = tree.path:match("[^/]+$") or tree.path
    if leaf and leaf ~= "" then
      out[leaf] = tree.chosenPartName
    end
  end
  local ch = tree.children
  if type(ch) == "table" then
    for _, child in pairs(ch) do
      flattenPartsTreeToSlotParts(child, out, acc)
      if acc.n > MAX_PART_TREE_NODES then
        return out
      end
    end
  end
  return out
end

local function isLikelyCosmeticSlotKey(slotKey)
  local s = string.lower(tostring(slotKey or ""))
  return s:find("paint", 1, true) or s:find("skin", 1, true) or s:find("color", 1, true) or s:find("livery", 1, true)
end
local function isTireOrBrakeSlotKey(slotKey)
  local s = string.lower(tostring(slotKey or ""))
  if s:find("tire", 1, true) then
    return true
  end
  if s:find("brake", 1, true) then
    return true
  end
  if s:find("caliper", 1, true) then
    return true
  end
  if s:find("rotor", 1, true) then
    return true
  end
  if s:find("handbrake", 1, true) then
    return true
  end
  return false
end

local function shouldIgnoreSlotForStockBuildCompare(slotKey)
  return isLikelyCosmeticSlotKey(slotKey) or isTireOrBrakeSlotKey(slotKey)
end
local function countMeaningfulDiffsAgainstBaseline(modelKey, partsTree)
  local base = loadBaselinePartsMap(modelKey)
  if not base then
    return nil
  end
  if type(partsTree) ~= "table" then
    return nil
  end
  local cur = flattenPartsTreeToSlotParts(partsTree, {}, { n = 0 })
  local keys = {}
  for k, _ in pairs(base) do
    keys[k] = true
  end
  for k, _ in pairs(cur) do
    keys[k] = true
  end
  local n = 0
  for slotKey, _ in pairs(keys) do
    if not shouldIgnoreSlotForStockBuildCompare(slotKey) then
      local b = base[slotKey]
      local c = cur[slotKey]
      if type(b) ~= "string" then
        b = ""
      end
      if type(c) ~= "string" then
        c = ""
      end
      if b ~= c then
        n = n + 1
      end
    end
  end
  return n
end
local function isStockBuild(modelKey, configKey, partsTree)
  if not modelKey or modelKey == "" then
    return false
  end
  local baselineCfg = pickFactoryBaselineConfigKey(modelKey)
  local curNorm = normalizeConfigKeyForCompare(configKey)
  local baseNorm = normalizeConfigKeyForCompare(baselineCfg)
  if baseNorm and curNorm and curNorm ~= baseNorm then
    return false
  end
  if type(partsTree) ~= "table" then
    if baseNorm and curNorm and curNorm == baseNorm then
      return true
    end
    if not curNorm and baseNorm then
      return true
    end
    return false
  end
  local diff = countMeaningfulDiffsAgainstBaseline(modelKey, partsTree)
  if diff == nil then
    return false
  end
  return diff == 0
end
-- Public queries ----------------------------------------------------------------------------------

M.branchRank = branchRank
M.branchFromRank = branchFromRank

function M.resolveSanctionedBranchForFleetVehicle(modelKey, partsTree, pwBranch, configKey)
  if not M.ENABLED then
    return pwBranch or "stock"
  end
  if not modelKey or modelKey == "" then
    return pwBranch or "stock"
  end
  if isStockBuild(modelKey, configKey, partsTree) then
    return "stock"
  end
  return pwBranch or "stock"
end

function M.debugMeaningfulDiffCount(modelKey, partsTree)
  return countMeaningfulDiffsAgainstBaseline(modelKey, partsTree)
end
function M.debugSlotDiffCount(modelKey, partsTree)
  return countMeaningfulDiffsAgainstBaseline(modelKey, partsTree)
end

function M.debugIsStockBuild(modelKey, configKey, partsTree)
  return isStockBuild(modelKey, configKey, partsTree)
end

function M.debugBaselineConfigKey(modelKey)
  return pickFactoryBaselineConfigKey(modelKey)
end
function M.warmupCatalogBaselines()
  if not M.ENABLED then
    return
  end
  ensureEligibleFactoryBaselinesCached()
end

return M
