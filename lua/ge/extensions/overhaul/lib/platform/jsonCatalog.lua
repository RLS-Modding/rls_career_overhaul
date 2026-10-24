-- Stateless VFS discovery shared by data registries: nested folders, optional order, first declared id
-- wins. Callers own any state they derive from the entries.
local M = {}

local function reject(rejected, file, reason, tag)
  rejected[#rejected + 1] = {file = file, reason = reason}
  log("W", tag, "Ignoring manifest " .. file .. ": " .. reason)
end

function M.validId(id)
  return type(id) == "string" and id:match("^[%w][%w%._%-]*$") ~= nil
end

function M.finite(value)
  return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

-- Returns the data when it is a valid manifest for its file, else nil and the reason.
function M.validate(data, file)
  if type(data) ~= "table" then return nil, "not a JSON object" end
  if not M.validId(data.id) then return nil, "invalid id" end
  if data.id ~= file:match("([^/\\]+)%.[jJ][sS][oO][nN]$") then return nil, "id must match file name" end
  if data.order ~= nil and not M.finite(data.order) then return nil, "order must be finite" end
  if data.namespace ~= nil then
    if not M.validId(data.namespace) or data.id:sub(1, #data.namespace + 1) ~= data.namespace .. "." then
      return nil, "namespaced id must start with namespace."
    end
  end
  return data
end

-- Reads and validates every file; the valid ones are candidates, the rest are rejected in file order.
local function collectCandidates(files, validate, tag, rejected)
  local candidates = {}
  for _, file in ipairs(files) do
    local data = jsonReadFile(file)
    local entry, reason = M.validate(data, file)
    if entry then entry, reason = validate(entry, file) end
    if entry then
      candidates[#candidates + 1] = {data = entry, file = file}
    else
      reject(rejected, file, tostring(reason), tag)
    end
  end
  return candidates
end

local function byOrderThenIdThenFile(left, right)
  local leftOrder, rightOrder = left.data.order or math.huge, right.data.order or math.huge
  if leftOrder ~= rightOrder then return leftOrder < rightOrder end
  if left.data.id ~= right.data.id then return left.data.id < right.data.id end
  return left.file < right.file
end

-- The first candidate for an id is kept; a later one with the same id is rejected.
local function keepFirstIds(candidates, rejected, tag)
  local entries, seen = {}, {}
  for _, candidate in ipairs(candidates) do
    local entry, file = candidate.data, candidate.file
    if seen[entry.id] then
      reject(rejected, file, "duplicate id; first declared entry wins: " .. seen[entry.id], tag)
    else
      seen[entry.id] = file
      entries[#entries + 1] = entry
    end
  end
  return entries
end

-- Entries sorted by order then id, and {file, reason} for each rejected file.
function M.scan(dir, validate, tag)
  local files = FS:findFiles(dir, "*.json", -1, false, false) or {}
  table.sort(files)
  local rejected = {}
  local candidates = collectCandidates(files, validate, tag, rejected)
  table.sort(candidates, byOrderThenIdThenFile)
  return keepFirstIds(candidates, rejected, tag), rejected
end

return M
