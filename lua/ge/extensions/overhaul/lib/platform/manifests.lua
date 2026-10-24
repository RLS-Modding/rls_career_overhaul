-- Platform manifest discovery for registries with an explicit `order`: one folder (depth 0), one manifest per
-- file, entries sorted by order then id. Broken files are skipped with a warning.
-- Raw directory data is lazy and lasts until a mod mount changes.
local M = {}

local ID_PATTERN = "^[%w][%w%._%-]*$"
local DEFAULT_TAG = "overhaul_platform_manifests"
local directories = {}
local mountedMods

-- The mount hooks discard raw snapshots before rebuilding owner registries.
function M.invalidate()
  directories = {}
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

-- Readers can precede the manager in a retained/reloaded hook list. Detect the
-- stock active-mod change on their first scan, before their mount callback runs.
local function syncMountState()
  local manager = rawget(_G, "core_modmanager")
  if not manager then return end
  local mods = manager.getMods()
  local current, changed = {}, mountedMods == nil
  for name, mod in pairs(mods) do
    if mod.active then
      current[name] = mod.fullpath or true
      if not mountedMods or mountedMods[name] ~= current[name] then changed = true end
    end
  end
  for name in pairs(mountedMods or {}) do
    if current[name] == nil then changed = true end
  end
  if changed then M.invalidate() end
  mountedMods = current
end

local function directory(dir)
  if directories[dir] then return directories[dir] end
  local files = FS:findFiles(dir, "*.json", 0, false, false) or {}
  table.sort(files)
  local rows = {}
  for _, file in ipairs(files) do rows[#rows + 1] = {file = file} end
  directories[dir] = rows
  return rows
end

local function warn(tag, message)
  log("W", tag, message)
end

function M.isNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

-- True for a list of non-empty strings; an empty list only when allowEmpty.
function M.isStringList(value, allowEmpty)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" then return false end
    count = count + 1
  end
  if count ~= #value or (count == 0 and not allowEmpty) then return false end
  for _, item in ipairs(value) do
    if not M.isNonEmptyString(item) then return false end
  end
  return true
end

function M.fileId(file)
  return string.match(file, "([^/\\]+)%.[jJ][sS][oO][nN]$")
end

-- Order is the first sort key and id the tie-break, so the result never depends on filesystem order.
local function byOrderThenId(left, right)
  if left.order ~= right.order then return left.order < right.order end
  return left.id < right.id
end
M.byOrderThenId = byOrderThenId

-- Why a file is not a usable manifest, or the entry to keep (the validator's entry when it gives one).
local function checkManifest(row, options)
  local file = row.file
  if not row.loaded then
    row.data = jsonReadFile(file)
    row.loaded = true
  end
  -- Validators can transform/mutate their input; neither they nor callers own the snapshot.
  local data = copy(row.data)
  if type(data) ~= "table" then return nil, "not a JSON object" end
  if not M.isNonEmptyString(data.id) or not string.match(data.id, ID_PATTERN) then return nil, "invalid id" end
  if data.id ~= M.fileId(file) then return nil, string.format("id '%s' must match the file name", data.id) end
  if type(data.order) ~= "number" or data.order ~= data.order then return nil, "order must be a number" end
  if options.validate then return options.validate(data, file) end
  return data
end

-- Choose the current validator after reading and validating each manifest.
function M.scan(opts)
  syncMountState()
  local tag = opts.tag or DEFAULT_TAG
  local entries, rejected, seen = {}, {}, {}
  for _, row in ipairs(directory(opts.dir)) do
    local file = row.file
    local entry, reason = checkManifest(row, opts)
    if entry and seen[entry.id] then entry, reason = nil, "duplicate id" end
    if entry then
      seen[entry.id] = true
      entries[#entries + 1] = entry
    else
      rejected[#rejected + 1] = {file = file, reason = reason}
      warn(tag, string.format("Ignoring manifest %s: %s", file, tostring(reason)))
    end
  end
  table.sort(entries, byOrderThenId)
  return entries, rejected
end

return M
