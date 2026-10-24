-- Market Watch and challenge displays share the discovered economy activity sections. No cached runtime
-- state: each consumer owns its snapshot for its own load lifetime.
local activitySections = require("overhaul/lib/career/activitySections")
local manifests = require("overhaul/lib/platform/manifests")
local optional = require("overhaul/lib/platform/optional")

local M = {}

local TAG = "overhaul_activityTaxonomy"

local function number(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

-- A leaf needs an id, a label, a positive job count and orders; tags and availability must be lists.
local function validLeaf(leaf)
  if not manifests.isNonEmptyString(leaf.id) or not manifests.isNonEmptyString(leaf.label) then return false end
  if not number(leaf.npcJobsPerDay) or leaf.npcJobsPerDay <= 0 then return false end
  if not number(leaf.marketOrder) or not number(leaf.earningOrder) then return false end
  if not manifests.isStringList(leaf.earningTags) then return false end
  if leaf.availability ~= nil and not manifests.isStringList(leaf.availability, true) then return false end
  if leaf.refreshOffers ~= nil and type(leaf.refreshOffers) ~= "boolean" then return false end
  return leaf.typeFamilyPrefix == nil or manifests.isNonEmptyString(leaf.typeFamilyPrefix)
end

local function warn(section, reason)
  log("W", TAG, "Ignoring taxonomy in " .. section.id .. ": " .. reason)
end

-- A leaf built from its declaration, with the section's orders, tags, availability and refresh as defaults.
local function leafFromData(data, section)
  local leaf = {
    id = data.id,
    label = data.label,
    npcJobsPerDay = data.npcJobsPerDay,
    marketOrder = data.marketOrder or section.order,
    earningOrder = data.earningOrder or data.marketOrder or section.order,
    earningTags = data.earningTags or {data.id},
    availability = data.availability or section.availability,
    typeFamilyPrefix = data.typeFamilyPrefix or section.typeFamilyPrefix,
    refreshOffers = data.refreshOffers,
  }
  if leaf.refreshOffers == nil then leaf.refreshOffers = section.refreshOffers end
  return leaf
end

-- The section's leaves, all valid and unique; nil after a warning when any one is not.
local function acceptedLeaves(taxonomy, section)
  local leaves = section.marketLeaves or {section}
  if type(leaves) ~= "table" or #leaves == 0 then
    warn(section, "invalid marketLeaves")
    return nil
  end
  local accepted, seen = {}, {}
  for _, data in ipairs(leaves) do
    if type(data) ~= "table" then
      warn(section, "invalid leaf")
      return nil
    end
    local leaf = leafFromData(data, section)
    if not validLeaf(leaf) or taxonomy.byId[leaf.id] or seen[leaf.id] then
      warn(section, "invalid or duplicate leaf")
      return nil
    end
    accepted[#accepted + 1] = leaf
    seen[leaf.id] = true
  end
  return accepted
end

-- The branch a section adds leaves to; nil after a warning when its label or order conflicts with the branch.
local function branchFor(taxonomy, section)
  local branch = taxonomy.branchById[section.branch]
  if branch and (branch.label ~= section.branchLabel or branch.order ~= section.branchOrder) then
    warn(section, "conflicting branch label/order")
    return nil
  end
  if not branch then
    branch = {id = section.branch, label = section.branchLabel, order = section.branchOrder, leaves = {}}
    taxonomy.branchById[branch.id] = branch
    taxonomy.branches[#taxonomy.branches + 1] = branch
  end
  return branch
end

local function addMarket(taxonomy, section)
  if section.branch == nil then
    if section.label ~= nil or section.npcJobsPerDay ~= nil or section.marketLeaves ~= nil then
      warn(section, "market fields need a branch")
    end
    return
  end
  if not manifests.isNonEmptyString(section.branch) or not manifests.isNonEmptyString(section.branchLabel)
      or not number(section.branchOrder) then
    warn(section, "invalid branch")
    return
  end
  local accepted = acceptedLeaves(taxonomy, section)
  if not accepted then return end
  local branch = branchFor(taxonomy, section)
  if not branch then return end
  for _, leaf in ipairs(accepted) do
    taxonomy.byId[leaf.id] = leaf
    taxonomy.earningLeaves[#taxonomy.earningLeaves + 1] = leaf
    branch.leaves[#branch.leaves + 1] = leaf
  end
end

-- A display rule names its type by exact key or by prefix, never both, and may number a suffix from suffixStart.
local function validDisplayRule(rule)
  if type(rule) ~= "table" or not number(rule.order) then return false end
  if not manifests.isNonEmptyString(rule.name) or not manifests.isNonEmptyString(rule.category) then return false end
  local hasKey = manifests.isNonEmptyString(rule.key) and rule.prefix == nil
  local hasPrefix = manifests.isNonEmptyString(rule.prefix) and rule.key == nil
  if not (hasKey or hasPrefix) then return false end
  return rule.suffixStart == nil or (number(rule.suffixStart) and rule.suffixStart >= 1 and rule.suffixStart % 1 == 0)
end

local function addDisplay(taxonomy, section)
  if section.challengeDisplay == nil then return end
  if type(section.challengeDisplay) ~= "table" then
    warn(section, "invalid challengeDisplay")
    return
  end
  for index, rule in ipairs(section.challengeDisplay) do
    if validDisplayRule(rule) then
      taxonomy.displayRules[#taxonomy.displayRules + 1] = {rule = rule, id = section.id, index = index}
    else
      warn(section, "invalid display rule")
    end
  end
end

local function addExcludedTags(taxonomy, section)
  if section.excludedEarningTags == nil then return end
  if not manifests.isStringList(section.excludedEarningTags, true) then
    warn(section, "invalid excludedEarningTags")
    return
  end
  for _, tag in ipairs(section.excludedEarningTags) do taxonomy.excludedEarningTags[tag] = true end
end

local function sortTaxonomy(taxonomy)
  table.sort(taxonomy.branches, manifests.byOrderThenId)
  for _, branch in ipairs(taxonomy.branches) do
    table.sort(branch.leaves, function(left, right)
      if left.marketOrder ~= right.marketOrder then return left.marketOrder < right.marketOrder end
      return left.id < right.id
    end)
  end
  table.sort(taxonomy.earningLeaves, function(left, right)
    if left.earningOrder ~= right.earningOrder then return left.earningOrder < right.earningOrder end
    return left.id < right.id
  end)
  table.sort(taxonomy.displayRules, function(left, right)
    if left.rule.order ~= right.rule.order then return left.rule.order < right.rule.order end
    if left.id ~= right.id then return left.id < right.id end
    return left.index < right.index
  end)
end

function M.load()
  local taxonomy = {branches = {}, branchById = {}, byId = {}, earningLeaves = {}, displayRules = {}, excludedEarningTags = {}}
  for _, section in ipairs(activitySections.sections()) do
    addMarket(taxonomy, section)
    addDisplay(taxonomy, section)
    addExcludedTags(taxonomy, section)
  end
  sortTaxonomy(taxonomy)
  return taxonomy
end

-- Missing availability means always available; [] deliberately has no owner gate.
function M.available(leaf)
  if not leaf then return false end
  if not leaf.availability or #leaf.availability == 0 then return true end
  for _, extension in ipairs(leaf.availability) do
    if optional(extension) ~= nil then return true end
  end
  return false
end

-- "burnoutComp" or "road_racing" as player text ("Burnout Comp", "Road Racing"), for types no manifest names.
local function readableKey(key)
  local words = key:gsub("[_%-]+", " "):gsub("(%l)(%u)", "%1 %2")
  return (words:gsub("^%s+", ""):gsub("%s+$", ""):gsub("(%a)(%w*)", function(first, rest) return first:upper() .. rest end))
end

-- Display name order: the manifest's challengeDisplay rule, then its Market Watch leaf label, then the key made readable.
function M.typeInfo(taxonomy, key)
  for _, entry in ipairs(taxonomy.displayRules) do
    local rule = entry.rule
    if rule.key == key or (rule.prefix and key:sub(1, #rule.prefix) == rule.prefix) then
      local name = rule.name
      if rule.suffixStart then name = name .. readableKey(key:sub(rule.suffixStart)) end
      return {id = key, name = name, category = rule.category}
    end
  end
  local leaf = taxonomy.byId[key]
  if leaf then return {id = key, name = leaf.label, category = "Other"} end
  return {id = key, name = readableKey(key), category = "Other"}
end

return M
