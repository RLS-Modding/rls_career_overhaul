-- Persists the generator's start-node lengths between sessions, so setup does not search the road graph again.
-- Numbers are written as %.17g text because the game's JSON encoder rounds doubles.
local M = {}

local CACHE_DIRECTORY = '/temp/rls_career/deliveryRoutes/'
local CACHE_FORMAT = 'facility-routes-3'

local function checksum(text)
  local hash31, hash131 = #text, #text
  for i = 1, #text do
    local byteValue = text:byte(i)
    hash31 = (hash31 * 31 + byteValue) % 4294967291
    hash131 = (hash131 * 131 + byteValue) % 2147483629
  end
  return string.format('%d:%d:%d', #text, hash31, hash131)
end

local function encodeAtom(value)
  local kind = type(value)
  if kind == 'number' then return 'n' .. string.format('%.17g', value) end
  if kind == 'string' then
    if not value:find('[%%\t\r\n]') then return 's' .. value end
    local escaped = value:gsub('%%', '%%25'):gsub('\t', '%%09'):gsub('\r', '%%0d'):gsub('\n', '%%0a')
    return 's' .. escaped
  end
  return kind .. ':' .. tostring(value)
end

local function decodeAtom(value)
  if value:sub(1, 1) == 'n' then return tonumber(value:sub(2)) end
  if value:sub(1, 1) == 's' then
    return (value:sub(2):gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
  end
end

-- The game build, as valueCalculator's vehicle stamp reads it; the whole integrity.json is ~3 MB.
local function gameBuild()
  local integrity = readFile('integrity.json') or ''
  return tostring(integrity:match('"version"%s*:%s*"([^"]*)"')) .. '|' ..
    tostring(integrity:match('"buildinfo"%s*:%s*"([^"]*)"'))
end

local function byKey(a, b) return a.key < b.key end

-- Sorted edges keep routing stamps stable across Lua hash seeds; road lookups are refreshed at setup.
local function signature(state)
  local nodes = map.getMap().nodes
  local version = jsonReadFile('/gameplay/overhaul/version.json')
  local signatureLines = {CACHE_FORMAT, encodeAtom(getCurrentLevelIdentifier()), encodeAtom(version and version.version_string), encodeAtom(gameBuild())}
  local nodeIds = {}
  for id in pairs(state.graph.graph) do nodeIds[#nodeIds + 1] = {id = id, key = encodeAtom(id)} end
  table.sort(nodeIds, byKey)
  for _, item in ipairs(nodeIds) do
    local id = item.id
    local position = nodes[id] and nodes[id].pos
    signatureLines[#signatureLines + 1] = table.concat({item.key, encodeAtom(position and position.x), encodeAtom(position and position.y), encodeAtom(position and position.z)}, '\t')
    local edges = {}
    for child, data in pairs(state.graph.graph[id]) do
      edges[#edges + 1] = {key = encodeAtom(child), line = table.concat({encodeAtom(child), encodeAtom(data.len), encodeAtom(data.drivability > 0),
        encodeAtom(data.oneWay and data.inNode == child)}, '\t')}
    end
    table.sort(edges, byKey)
    for _, edge in ipairs(edges) do signatureLines[#signatureLines + 1] = edge.line end
    signatureLines[#signatureLines + 1] = '.'
  end
  return table.concat(signatureLines, '\n') .. '\n'
end

-- The serialized rows when the file holds this graph's signature and a valid checksum, else nil.
local function cacheParts(contents)
  if contents then return contents:match('^(%d+)\n(.*)$') end
end

local function readMatchingRows(state, graphSignature)
  local cacheFileContents = FS:fileExists(state.persistenceFile) and readFile(state.persistenceFile)
  local signatureLengthBytes, cacheBody = cacheParts(cacheFileContents)
  signatureLengthBytes = tonumber(signatureLengthBytes)
  if not signatureLengthBytes or not cacheBody or signatureLengthBytes ~= #graphSignature or cacheBody:sub(1, signatureLengthBytes) ~= graphSignature then
    return nil
  end
  local serializedPayload = cacheBody:sub(signatureLengthBytes + 1)
  local serializedRows, expectedChecksum = serializedPayload:match('^(.*)END\t([^\n]+)\n$')
  if not serializedRows or checksum(serializedRows) ~= expectedChecksum then return nil end
  return serializedRows
end

-- Every row is parsed before any is used: a truncated or malformed file is a miss, so nil comes back.
local function parseRows(state, serializedRows)
  local loadedRecords = {}
  local consumedRowBytes = 0
  for row in serializedRows:gmatch('([^\n]+)\n') do
    consumedRowBytes = consumedRowBytes + #row + 1
    local encodedStartNode, encodedGoalNode, value = row:match('^([^\t]+)\t([^\t]+)\t([^\t]+)$')
    local startNode, goalNode, distance = encodedStartNode and decodeAtom(encodedStartNode), encodedGoalNode and decodeAtom(encodedGoalNode), tonumber(value)
    if not startNode or not goalNode or not distance or distance ~= distance or distance < 0 or distance == math.huge then return nil end
    local targetIndex = state.targetIndex[goalNode]
    if state.graph.graph[startNode] and targetIndex then
      local startRecord = loadedRecords[startNode] or {lengths = {}, recorded = 0}
      loadedRecords[startNode] = startRecord
      if startRecord.lengths[targetIndex] == nil then startRecord.recorded = startRecord.recorded + 1 end
      startRecord.lengths[targetIndex] = distance
    end
  end
  if consumedRowBytes ~= #serializedRows then return nil end
  return loadedRecords
end

local function load(state)
  if state.persistenceChecked then return end
  state.persistenceChecked = true
  local level = getCurrentLevelIdentifier()
  if type(level) ~= 'string' or not level:match('^[%w_-]+$') then return end
  state.persistenceFile = CACHE_DIRECTORY .. level .. '.txt'
  local ok, graphSignature = pcall(signature, state)
  if not ok then return end
  state.persistenceStamp = graphSignature
  local serializedRows = readMatchingRows(state, graphSignature)
  if not serializedRows then return end
  local loadedRecords = parseRows(state, serializedRows)
  if loadedRecords then state.starts = loadedRecords end
end

-- Rows are sorted, so the same lengths always serialize to the same bytes.
local function serializeRows(state)
  local goalsByIndex, cacheRows = {}, {}
  for goalNode, targetIndex in pairs(state.targetIndex) do goalsByIndex[targetIndex] = goalNode end
  for startNode, startRecord in pairs(state.starts) do
    for targetIndex, distanceMeters in pairs(startRecord.lengths) do
      if type(distanceMeters) == 'number' and distanceMeters >= 0 and distanceMeters < math.huge then
        cacheRows[#cacheRows + 1] = encodeAtom(startNode) .. '\t' .. encodeAtom(goalsByIndex[targetIndex]) .. '\t' .. string.format('%.17g', distanceMeters)
      end
    end
  end
  table.sort(cacheRows)
  return #cacheRows > 0 and (table.concat(cacheRows, '\n') .. '\n') or ''
end

local function save(state)
  if not state.persistenceStamp or not state.persistenceFile or not state.persistenceDirty then return false end
  -- Never write mixed or stale lengths after a graph reload or an in-place edit.
  if state.graph ~= map.getGraphpath() or signature(state) ~= state.persistenceStamp then return false end
  local serializedRows = serializeRows(state)
  if not FS:directoryExists(CACHE_DIRECTORY) then FS:directoryCreate(CACHE_DIRECTORY, true) end
  local cacheFileContents = #state.persistenceStamp .. '\n' .. state.persistenceStamp .. serializedRows .. 'END\t' .. checksum(serializedRows) .. '\n'
  if not writeFile(state.persistenceFile, cacheFileContents) then return false end
  state.persistenceDirty = false
  return true
end

-- Cache I/O is optional; a failure must leave normal route calculation usable.
function M.load(state) pcall(load, state) end

function M.save(state)
  local ok, saved = pcall(save, state)
  return ok and saved or false
end

return M
