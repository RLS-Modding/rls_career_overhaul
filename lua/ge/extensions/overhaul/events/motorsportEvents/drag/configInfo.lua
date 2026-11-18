-- Owns approved build metadata ingestion.
-- Reads settings/motorsportEvents/configInfo.json and indexed files; drag/catalog.lua consumes validated driver rows.
local M = {}

local function isHash(value)
  return type(value) == 'string' and #value == 64 and value:match('^[0-9a-f]+$') ~= nil
end

local function isHistoricalEstimate(row, performance)
  return performance.status == 'historical-estimate'
    and performance.configHashMatches == false
    and performance.rosterApprovalRetained == true
    and performance.requiresRetiming == true
    and isHash(row.sourceConfigSHA256) and isHash(performance.evidenceConfigSHA256)
    and row.sourceConfigSHA256 ~= performance.evidenceConfigSHA256
end

-- Explicit index avoids discovering unrelated selector configurations or draft packs.
-- Assigned classIds are authoring intent; only approvedClassIds enter NPC pools.
function M.read(classes, readJson, exists)
  readJson = readJson or jsonReadFile
  exists = exists or function(path) return FS and FS:fileExists(path) end
  local index = readJson('/settings/motorsportEvents/configInfo.json')
  if not index or index.enabled ~= true then return {} end
  assert(index.version == 1 and type(index.files) == 'table', 'Invalid motorsport config info index')
  local known, seen, result = {}, {}, {}
  for _, class in ipairs(classes or {}) do known[class.id] = true end
  for _, file in ipairs(index.files) do
    local info = assert(readJson(file), 'Missing motorsport info file: ' .. tostring(file))
    local row = assert(info.Motorsport, 'Missing Motorsport metadata: ' .. file)
    assert(row.version == 1 and type(row.model) == 'string' and type(row.configId) == 'string', 'Invalid motorsport config identity')
    local id = row.model .. '/' .. row.configId
    assert(row.id == id and not seen[id], 'Duplicate/mismatched motorsport config ID: ' .. id)
    seen[id] = true
    assert(row.config == '/vehicles/' .. id .. '.pc', 'Mismatched motorsport config path: ' .. id)
    local assigned, approved, used = {}, {}, {}
    for _, classId in ipairs(row.classIds or {}) do assigned[classId] = true end
    for _, classId in ipairs(row.approvedClassIds or {}) do
      assert(assigned[classId] and known[classId], 'Unknown/unassigned approved class: ' .. tostring(classId))
      if not used[classId] then approved[#approved + 1], used[classId] = classId, true end
    end
    if #approved > 0 then
      assert(type(row.driverId) == 'string' and row.driverId ~= '', 'Missing stable driver ID: ' .. id)
      local performance = row.performance or {}
      local historicalEstimate = isHistoricalEstimate(row, performance)
      local matchingEvidence = performance.configHashMatches == true and performance.status ~= 'historical-estimate'
      assert((matchingEvidence or historicalEstimate)
        and type(performance.quarterMileSeconds) == 'number'
        and performance.quarterMileSeconds > 0 and performance.quarterMileSeconds < math.huge,
        'Approved config needs matching evidence or explicitly retained historical estimates: ' .. id)
      if exists(row.config) then result[#result + 1] = {id = id, driverId = row.driverId, driverName = row.driverName,
        model = row.model, config = row.configId, classIds = approved,
        estimatedET = performance.quarterMileSeconds, historicalETEstimate = historicalEstimate, infoFile = file}
      end
    end
  end
  return result
end

return M
