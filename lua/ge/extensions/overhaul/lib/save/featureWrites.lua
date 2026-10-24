-- Optional save families: a failed family removes its partial files, so no stale slot copy is left.
-- Profile and user roots keep their only copy; queued operations keep their family after capture returns.

local M = {}

local function pack(...) return {n = select('#', ...), ...} end

local function normalized(path)
  return (path:gsub('\\', '/'):gsub('^/+', ''):gsub('/+$', ''))
end

local function matches(file, pattern)
  return file:match('^' .. pattern:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '[^/]*') .. '$') ~= nil
end

-- Adds the files a wildcard member matches under the family base.
local function addWildcardMatches(family, member, paths, fileSystem)
  local files = assert(fileSystem:findFiles(family.base .. '/', '*', -1, true, false), 'cannot enumerate optional family')
  local base = normalized(family.base)
  local prefix = base ~= '' and base .. '/' or ''
  for _, file in ipairs(files) do
    local path = normalized(file)
    if path:sub(1, #prefix) == prefix then
      local relative = path:sub(#prefix + 1)
      if matches(relative, member) or matches(relative:gsub('%.tmp$', ''), member) then paths[file] = true end
    end
  end
end

-- Every file the family owns: the paths it tracked plus each declared member on disk.
local function collectFamilyPaths(family, fileSystem)
  local paths = {}
  for file in pairs(family.paths) do paths[file] = true end
  for _, member in ipairs(family.files or {}) do
    if member:find('*', 1, true) then
      addWildcardMatches(family, member, paths, fileSystem)
    else
      paths[family.base .. '/' .. member] = true
    end
  end
  return paths
end

-- Removes each owned file, and its .tmp copy in the slot root, failing loudly if a removal fails.
local function removeFamilyFiles(family, paths, fileSystem)
  for file in pairs(paths) do
    local targets = family.root == 'slot' and {file, file .. '.tmp'}
      or {file:sub(-4) == '.tmp' and file or file .. '.tmp'}
    for _, target in ipairs(targets) do
      if fileSystem:fileExists(target) and fileSystem:removeFile(target) ~= 0 then error('cannot remove ' .. target) end
    end
  end
end

-- Marks an optional family as skipped: runs its cancellations, removes its files and logs once.
local function discard(state, family, reason)
  if family.failed then return end
  family.failed = true
  local ok, problem = pcall(function()
    for cancel in pairs(family.cancellations) do cancel() end
    removeFamilyFiles(family, collectFamilyPaths(family, state.fileSystem), state.fileSystem)
  end)
  if not ok then
    family.cleanupFailed = true
    state.failSave()
    error(problem, 0)
  end
  log('W', 'saveSystem', 'Optional save family skipped: ' .. tostring(family.key) .. ': ' .. tostring(reason))
end

local function track(state, path)
  if state.current and state.current.required == false and path then state.current.paths[path] = true end
end

-- The family this identity already has in the running save, or a new one.
local function familyFor(state, options, base, identity)
  local current = state.current
  local family = identity and current and current.identity == identity and current
    or identity and state.saving() and state.families[identity]
  if family then return family end
  family = {required = options.required ~= false, key = options.key, base = base, root = options.root or 'slot',
    identity = identity, files = {}, fileSet = {}, paths = {}, cancellations = {}}
  if identity and state.saving() then state.families[identity] = family end
  return family
end

-- Adds the files a scope declares; true when any were new.
local function addFamilyFiles(family, files)
  local expanded = false
  for _, file in ipairs(files or {}) do
    if not family.fileSet[file] then
      family.files[#family.files + 1], family.fileSet[file], expanded = file, true, true
    end
  end
  return expanded
end

-- Runs the callback as this family's current scope and settles the family from its result.
local function runScope(state, family, previous, callback, ...)
  state.current = family
  local result = pack(pcall(callback, ...))
  state.current = previous
  if family.cleanupFailed then error('optional family cleanup failed', 0) end
  if family.failed then return false, 'optional family already skipped' end
  if not family.required and (not result[1] or result[2] == false) then
    discard(state, family, result[2])
    return false, result[2]
  end
  if family.required and family.identity and (not result[1] or result[2] == false) then state.failSave() end
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2, result.n)
end

local function scope(state, options, callback, ...)
  local previous = state.current
  if type(options) ~= 'table' then options = {required = options ~= false} end
  local base = options.base and options.base:gsub('\\', '/'):gsub('/+$', '')
  local identity = options.key and (options.key .. '\0' .. normalized(base))
  local family = familyFor(state, options, base, identity)
  local expanded = addFamilyFiles(family, options.files)
  if options.required ~= false then family.required = true end
  if family.failed then
    if family.required then state.failSave(); error('required family already skipped', 0) end
    if expanded then
      family.failed = false
      discard(state, family, 'replacement family also skipped')
    end
    return false, 'optional family already skipped'
  end
  return runScope(state, family, previous, callback, ...)
end

-- Wraps a queued operation so it still belongs to the family after its capture returned.
local function wrap(state, operation, filename, cancel, description)
  local family = state.current
  if not family or family.required then return operation end
  track(state, filename)
  if cancel then family.cancellations[cancel] = true end
  return function(...)
    if family.cleanupFailed then return false end
    if family.failed then
      if family.required then state.failSave(); return false end
      return true
    end
    local previous = state.current
    state.current = family
    local ok, result, problem = pcall(operation, ...)
    state.current = previous
    if not ok or result == false then
      if family.required then
        state.failSave()
        if not ok then error(result, 0) end
        return false, problem
      end
      discard(state, family, (description or tostring(filename)) .. "; " .. tostring(problem or result))
      return true
    end
    return result
  end
end

-- fileSystem is FS; failSave() marks the running save failed; saving() says whether a save is running.
function M.new(fileSystem, failSave, saving)
  local state = {current = nil, families = {}, fileSystem = fileSystem, failSave = failSave, saving = saving}
  local writes = {}
  function writes.reset() state.current, state.families = nil, {} end
  function writes.track(path) track(state, path) end
  function writes.scope(options, callback, ...) return scope(state, options, callback, ...) end
  function writes.key() return state.current and state.current.key end
  function writes.required() return not state.current or state.current.required end
  function writes.wrap(operation, filename, cancel, description) return wrap(state, operation, filename, cancel, description) end
  return writes
end

return M
