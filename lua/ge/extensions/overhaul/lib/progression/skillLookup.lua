-- Skill lookups: the one place callers read skill levels, level thresholds and skill XP, backed by the
-- branch catalog and overhaul_career_economy_playerAttributes. Stateless: callers keep their own fallbacks.
local M = {}

-- Experience values exist only in an active career; catalog reads remain available at boot.

-- True when the branch catalog can answer level questions. Always true; kept so callers keep their check.
function M.hasBranchLevels()
  return true
end

-- True when the catalog can compute a level from an XP value. Always true, like hasBranchLevels().
function M.hasLevelCalc()
  return true
end

-- True when levels can be computed from saved XP: the career is active, so the XP values exist.
function M.hasValueLevels()
  return overhaul_career_career.isActive()
end

-- Preserve the career gate at the experience fallback while the boot catalog remains available.
function M.hasValueLevelsUncheckedCatalog()
  return overhaul_career_career.isActive()
end

-- getBranchLevel(ref): level, curLvlProgress, neededForNext, prevThreshold, nextThreshold; nil for an unknown ref.
function M.branchLevel(ref)
  return overhaul_career_progression_skills.getBranchLevel(ref)
end

-- calcBranchLevelFromValue(value, ref): the same tuple for an XP value.
function M.levelFromValue(value, ref)
  return overhaul_career_progression_skills.calcBranchLevelFromValue(value, ref)
end

-- The XP value of a skill attribute (getAttributeValue).
function M.attributeValue(attributeKey)
  return overhaul_career_economy_playerAttributes.getAttributeValue(attributeKey)
end

-- level raised to the catalog level of one ref; refs that are not non-empty strings or have no level are skipped.
local function maxBranchLevel(level, ref)
  if type(ref) ~= "string" or ref == "" then return level end
  local raw = overhaul_career_progression_skills.getBranchLevel(ref)
  local catalogLevel = tonumber(raw)
  if catalogLevel then return math.max(level, catalogLevel) end
  return level
end

-- level raised to the level the XP value reaches for one ref, with the same skipping as maxBranchLevel.
local function maxBranchLevelFromValue(level, value, ref)
  if type(ref) ~= "string" or ref == "" then return level end
  local raw = overhaul_career_progression_skills.calcBranchLevelFromValue(value, ref)
  local calcLevel = tonumber(raw)
  if calcLevel then return math.max(level, calcLevel) end
  return level
end

-- Stop at the first known path before trying experience-derived levels.
function M.firstPathLevel(pathIds)
  for _, skillPathId in ipairs(pathIds or {}) do
    local branchLevel = overhaul_career_progression_skills.getBranchLevel(skillPathId)
    local level = tonumber(branchLevel)
    if level then
      return math.max(0, math.floor(level))
    end
  end

  return 0
end

-- Ask every path in the original order so backend callbacks observe the same sequence.
function M.maxPathLevel(level, refs)
  for _, ref in ipairs(refs or {}) do
    local branchLevel = overhaul_career_progression_skills.getBranchLevel(ref)
    local catalogLevel = tonumber(branchLevel)
    if catalogLevel then level = math.max(level, catalogLevel) end
  end
  return level
end

-- Ask every calculation path without filtering values the original caller accepted.
function M.maxValueLevel(level, value, refs)
  for _, ref in ipairs(refs or {}) do
    local branchLevel = overhaul_career_progression_skills.calcBranchLevelFromValue(value, ref)
    local calcLevel = tonumber(branchLevel)
    if calcLevel then level = math.max(level, calcLevel) end
  end
  return level
end

function M.maxInterleavedLevel(level, value, refs)
  if not overhaul_career_progression_skills then return level end
  local getBranchLevel = overhaul_career_progression_skills.getBranchLevel
  local calcFromValue = overhaul_career_progression_skills.calcBranchLevelFromValue
  for _, branchRef in ipairs(refs) do
    local raw = getBranchLevel(branchRef)
    local directLevel = tonumber(raw)
    if directLevel and directLevel > level then level = directLevel end
    raw = calcFromValue(value, branchRef)
    local calcLevel = tonumber(raw)
    if calcLevel and calcLevel > level then level = calcLevel end
  end
  return level
end

-- Callers that captured the calculation before a loop keep that function for the whole operation.
function M.captureLevelCalc()
  return overhaul_career_progression_skills and overhaul_career_progression_skills.calcBranchLevelFromValue
end

function M.levelFirstPathOrValue(attributeKey, pathIds)
  local level = M.firstPathLevel(pathIds)
  if level > 0 then
    return level
  end

  if M.hasValueLevels() then
    local value = tonumber(overhaul_career_economy_playerAttributes.getAttributeValue(attributeKey)) or 0
    level = M.maxValueLevel(level, value, pathIds)
  end

  return math.max(0, math.floor(level))
end

-- Repo and shopping used the same composition; the name stays for their callers.
M.levelFirstPathOrValueUncheckedCalc = M.levelFirstPathOrValue

-- Highest catalog level among refs; only when that is 0 or less, the highest level the attribute's XP reaches among the refs (non-number XP reads as 0).
function M.levelMaxPathOrValue(attributeKey, pathIds)
  local level = M.maxPathLevel(0, pathIds)
  if level <= 0 and M.hasValueLevels() then
    local value = tonumber((overhaul_career_economy_playerAttributes.getAttributeValue(attributeKey))) or 0
    level = M.maxValueLevel(level, value, pathIds)
  end
  return level
end

-- Recheck career state after catalog callbacks before reading experience.
function M.levelMaxOverRefs(attributeKey, pathIds, minimum)
  if not overhaul_career_career.isActive() then
    return minimum
  end

  -- Iterate paths after the attribute lookup because that callback may change them.
  local level = 0
  if type(attributeKey) == "string" and attributeKey ~= "" then
    level = maxBranchLevel(level, attributeKey)
  end
  for _, pathId in ipairs(pathIds or {}) do level = maxBranchLevel(level, pathId) end
  -- Catalog callbacks can end the career, so recheck it before reading experience.
  if M.hasValueLevels() then
    local skillValue = overhaul_career_economy_playerAttributes.getAttributeValue(attributeKey)
    skillValue = skillValue ~= nil and tonumber(skillValue) or nil
    if skillValue then
      level = maxBranchLevelFromValue(level, skillValue, attributeKey)
      for _, pathId in ipairs(pathIds or {}) do
        level = maxBranchLevelFromValue(level, skillValue, pathId)
      end
    end
  end

  return math.max(minimum, math.floor(level))
end

local function isValidBranch(candidate)
  return candidate and not candidate.missing and type(candidate.levels) == "table" and next(candidate.levels)
end

local function isCareerSkillsBranch(candidate)
  if type(candidate) ~= "table" then return false end
  if candidate.parentId == "careerSkills" then return true end
  if candidate.domainId == "careerSkills" then return true end
  if candidate.rootId == "careerSkills" then return true end
  if type(candidate.path) == "string" and candidate.path:find("careerSkills", 1, true) then return true end
  return false
end
M.isCareerSkillsBranch = isCareerSkillsBranch

-- Keep id, path and attribute lookup precedence while preserving each caller's guarded policy.
function M.findBranchForAttributeKey(attributeKey, opts)
  opts = opts or {}
  local guarded = opts.guarded
  if guarded and not overhaul_career_progression_skills then return nil end
  local candidates = {}

  -- Reread the live catalog at each callback boundary to observe owner replacement.
  local byId = overhaul_career_progression_skills.getBranchById(attributeKey)
  if isValidBranch(byId) then
    table.insert(candidates, byId)
  end

  local byPath = overhaul_career_progression_skills.getBranchByPath(attributeKey)
  if isValidBranch(byPath) then
    table.insert(candidates, byPath)
  end

  for _, candidate in ipairs(overhaul_career_progression_skills.getSortedBranches() or {}) do
    if (not guarded or type(candidate) == "table") and candidate.attributeKey == attributeKey and isValidBranch(candidate) then
      table.insert(candidates, candidate)
    end
  end

  local bestBranch, bestScore = nil, -math.huge
  for _, candidate in ipairs(candidates) do
    local score = #(candidate.levels or {})
    if isCareerSkillsBranch(candidate) then score = score + 10000 end
    if candidate.parentId == "careerSkills" then score = score + 1000 end
    if opts.logisticsDelivery and attributeKey == "logistics-delivery" and candidate.id == "logistics" then score = score + 100 end
    if score > bestScore then
      bestBranch, bestScore = candidate, score
    end
  end

  return bestBranch
end

-- Missing thresholds repeat the previous value and missing labels use the caller's fallback.
function M.sanitizeLevels(levels, labelFor)
  if type(levels) ~= "table" then return {} end
  local result = {}
  local lastRequiredValue = 0
  for i, levelInfo in ipairs(levels) do
    local entry = type(levelInfo) == "table" and deepcopy(levelInfo) or {}
    if type(entry.requiredValue) ~= "number" then
      entry.requiredValue = lastRequiredValue
    end
    lastRequiredValue = entry.requiredValue
    entry.levelLabel = entry.levelLabel or labelFor(i)
    result[#result + 1] = entry
  end
  return result
end

return M
