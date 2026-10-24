-- Owner-driven feature persistence over the existing capture writer.
-- Capture and restore stay at owner hooks; stale adapters cannot write for their replacements.
local registry = require('overhaul/lib/save/keyRegistry')
local M = {}

-- Async joins per save system; weak keys let a discarded save system be collected.
local asyncJoins = setmetatable({}, {__mode = 'k'})

-- Writer operations that only read; they report a stale context as a value, not a skipped write.
local READ_OPERATIONS = {read = true, exists = true, findFiles = true}

-- Helpers -------------------------------------------------------------------------------------------

local function pack(...) return {n = select('#', ...), ...} end

local function report(key, err)
  log('E', 'saveFeature', key .. ': ' .. tostring(err))
end

local function matches(file, pattern)
  pattern = '^' .. pattern:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '[^/]*') .. '$'
  return file:match(pattern) ~= nil
end

-- Registration --------------------------------------------------------------------------------------

-- Add-on keys keep the owner and required flag they were discovered with; core keys stay explicit.
local function registerFeature(key, descriptor, instance)
  local supplied = {}
  for field, value in pairs(descriptor) do supplied[field] = value end
  supplied.key = key
  if supplied.required == nil then
    registry.discoverAddonKeys()
    local existing = registry.get(key)
    if existing and existing.owner == supplied.owner then supplied.required = existing.required end
    if supplied.required == nil and registry.isAddon(key, supplied.owner) then supplied.required = false end
  end
  return registry.register(supplied, instance)
end

-- Current state -------------------------------------------------------------------------------------

local function isCurrent(feature)
  return not feature.disposed and registry.isCurrent(feature.key, feature.instance)
end

local function currentProblem(feature)
  if isCurrent(feature) then return end
  if feature.descriptor.required then error(feature.key .. ': disposed or replaced feature', 0) end
  return 'disposed or replaced feature'
end

-- Paths ---------------------------------------------------------------------------------------------

local function pathOf(feature, base, file)
  local key, descriptor = feature.key, feature.descriptor
  if type(base) == 'table' then base = base[descriptor.root] end
  assert(type(base) == 'string', key .. ': root directory required')
  if file == nil and #descriptor.files == 1 and not descriptor.files[1]:find('*', 1, true) then
    file = descriptor.files[1]
  end
  assert(type(file) == 'string' and file ~= '' and not file:find('\\', 1, true)
    and not file:find(':', 1, true) and not ('/' .. file .. '/'):find('/../', 1, true), key .. ': file member required')
  local accepted = false
  for _, family in ipairs(descriptor.files) do
    if matches(file, family) then accepted = true; break end
  end
  assert(accepted, key .. ': undeclared file ' .. file)
  if base == '' then return file end
  return base:gsub('/+$', '') .. '/' .. file
end

-- Require family-root membership before recording a writer-reported path.
local function memberPath(feature, base, filename, allowTemp)
  local key, descriptor = feature.key, feature.descriptor
  local directory = type(base) == 'table' and base[descriptor.root] or base
  assert(type(directory) == 'string' and type(filename) == 'string', key .. ': file path required')
  local normalized = filename:gsub('^/+', '')
  local prefix = directory:gsub('^/+', ''):gsub('/+$', '')
  if prefix ~= '' then
    prefix = prefix .. '/'
    assert(normalized:sub(1, #prefix) == prefix, key .. ': file outside root')
    normalized = normalized:sub(#prefix + 1)
  end
  if allowTemp and normalized:sub(-4) == '.tmp' then
    local declared = false
    for _, file in ipairs(descriptor.files) do
      if matches(normalized, file) then declared = true; break end
    end
    if not declared then normalized = normalized:sub(1, -5) end
  end
  pathOf(feature, base, normalized)
end

-- Running work --------------------------------------------------------------------------------------

-- Optional callback failures are logged; required failures propagate to the save owner.
local function invoke(feature, base, callback, ...)
  local problem = currentProblem(feature)
  if problem then return false, problem end
  local saveSystem, descriptor = feature.saveSystem, feature.descriptor
  local result = nil
  if saveSystem.withFeatureWrites then
    local scope = descriptor.required
    if base ~= nil then
      local directory = type(base) == 'table' and base[descriptor.root] or base
      scope = {required = descriptor.required, key = feature.key, base = directory, files = descriptor.files, root = descriptor.root}
    end
    result = pack(pcall(saveSystem.withFeatureWrites, scope, callback, ...))
  else
    result = pack(pcall(callback, ...))
  end
  if result[1] then return unpack(result, 2, result.n) end
  if descriptor.required then error(result[2], 0) end
  report(feature.key, result[2])
  return false, result[2]
end

-- Optional malformed families are discarded without changing required-write refusal.
local function writeFile(feature, base, value, file, pretty, precision, tempFile)
  local descriptor = feature.descriptor
  if not descriptor.required and type(value) ~= 'table' then
    return false, feature.key .. ': JSON payload must be a table'
  end
  local options = descriptor.writer or {}
  if pretty == nil then pretty = options.pretty end
  if precision == nil then precision = options.numberPrecision end
  if tempFile ~= nil then memberPath(feature, base, tempFile, true) end
  return feature.saveSystem.jsonWriteFileSafe(pathOf(feature, base, file), value, pretty, precision, tempFile)
end

local function writeThrough(feature, base, ...)
  return invoke(feature, base, writeFile, feature, base, ...)
end

-- Capture context -----------------------------------------------------------------------------------

-- Checks a mkdir target against the family root and the directories its files declare.
local function checkMkdir(feature, base, dirPath)
  local key, descriptor = feature.key, feature.descriptor
  local directory = type(base) == 'table' and base[descriptor.root] or base
  local root = directory:gsub('^/+', ''):gsub('/+$', '')
  local target = tostring(dirPath):gsub('^/+', ''):gsub('/+$', '')
  assert(target == root or target:sub(1, #root + 1) == root .. '/', key .. ': directory outside root')
  if target == root then return end
  local relative, declared = target:sub(#root + 2), false
  for _, file in ipairs(descriptor.files) do
    local parent = file:match('^(.*)/[^/]+$')
    while parent do
      if matches(relative, parent) then declared = true; break end
      parent = parent:match('^(.*)/[^/]+$')
    end
    if declared then break end
  end
  assert(declared, key .. ': undeclared directory')
end

local function checkWriterOperation(feature, base, name, args)
  if name == 'json' or name == 'write' or name == 'remove' then
    memberPath(feature, base, args[1], name == 'remove')
    if name == 'json' and type(args[5]) == 'string' then memberPath(feature, base, args[5], true) end
  elseif name == 'copy' or name == 'rename' then
    memberPath(feature, base, args[2])
    if name == 'rename' then memberPath(feature, base, args[1], true) end
  elseif name == 'mkdir' then
    checkMkdir(feature, base, args[1])
  elseif name == 'removeDir' then
    error(feature.key .. ': file-family adapter cannot remove a directory', 0)
  end
end

-- Check staleness for every operation because a callback can replace its own owner.
local function buildContext(feature, base, guard)
  local saveSystem, descriptor = feature.saveSystem, feature.descriptor
  local context = {root = descriptor.root, base = base, key = feature.key, writer = {}}
  local function current() return isCurrent(feature) and (not guard or guard()) end
  function context.path(file) return pathOf(feature, base, file) end
  function context.write(...)
    currentProblem(feature)
    if not current() then
      return invoke(feature, base, function() return false, 'stale capture context' end)
    end
    return writeThrough(feature, base, ...)
  end
  function context.read(file, ...)
    if not current() then return nil, 'stale capture context' end
    return saveSystem.getSaveWriter().read(context.path(file), ...)
  end
  -- Resolve the writer for every operation: saveSystem owns its capture lifetime and snapshots.
  for name in pairs(saveSystem.getSaveWriter()) do
    context.writer[name] = function(...)
      if not READ_OPERATIONS[name] then currentProblem(feature) end
      if not current() then
        if READ_OPERATIONS[name] then return false, 'stale capture context' end
        return invoke(feature, base, function() return false, 'stale capture context' end)
      end
      local args = pack(...)
      local function operation()
        checkWriterOperation(feature, base, name, args)
        return saveSystem.getSaveWriter()[name](unpack(args, 1, args.n))
      end
      if READ_OPERATIONS[name] then return operation() end
      return invoke(feature, base, operation)
    end
  end
  return context
end

-- Capture and restore -------------------------------------------------------------------------------

-- Preserve owner refusals while preventing a replaced owner from committing its capture.
local function runCapture(feature, completionGuard, context, ...)
  local key, descriptor = feature.key, feature.descriptor
  local result = pack(descriptor.capture(context, ...))
  local problem = currentProblem(feature)
  if problem then return false, problem end
  if not descriptor.required and completionGuard and not completionGuard() then
    return false, 'stale capture context'
  end
  if result[1] == false then error(result[2] or (key .. ': capture callback refused'), 0) end
  return unpack(result, 1, result.n)
end

local function capture(feature, base, guard, completionGuard, ...)
  local problem = currentProblem(feature)
  if problem then return false, problem end
  if not feature.descriptor.capture then return false, 'capture callback not declared' end
  local context = buildContext(feature, base, guard)
  return invoke(feature, base, function(...)
    return runCapture(feature, completionGuard, context, ...)
  end, ...)
end

local function restore(feature, base, ...)
  local problem = currentProblem(feature)
  if problem then return false, problem end
  if not feature.descriptor.restore then return false, 'restore callback not declared' end
  return invoke(feature, nil, feature.descriptor.restore, buildContext(feature, base), ...)
end

-- Async tokens --------------------------------------------------------------------------------------

local function asyncJoinsOf(saveSystem)
  local joins = asyncJoins[saveSystem]
  if not joins then
    joins = setmetatable({}, {__mode = 'v'})
    asyncJoins[saveSystem] = joins
  end
  return joins
end

-- Bind asynchronous work to profile, generation and owner lifetime so stale completion cannot write.
local function newAsyncToken(feature, base, joins, generation, profile)
  local saveSystem, descriptor = feature.saveSystem, feature.descriptor
  local async = descriptor.async
  local finished = false
  local token = {generation = generation}
  function token.isCurrent()
    return not finished and joins[async] == token and isCurrent(feature)
      and profile == saveSystem.getCurrentProfile()
      and saveSystem.isAsyncSaveExtensionCurrent(async, generation)
  end
  local function completionCurrent()
    return joins[async] == token and profile == saveSystem.getCurrentProfile()
      and (finished or saveSystem.isAsyncSaveExtensionCurrent(async, generation))
  end
  function token.capture(...)
    if not token.isCurrent() then return false, 'stale async capture' end
    local args = pack(...)
    return saveSystem.captureSaveWrites(function()
      return capture(feature, base, token.isCurrent, completionCurrent, unpack(args, 1, args.n))
    end)
  end
  function token.write(...)
    if not token.isCurrent() then return false, 'stale async capture' end
    local args = pack(...)
    return saveSystem.captureSaveWrites(function() return writeThrough(feature, base, unpack(args, 1, args.n)) end)
  end
  function token.finish()
    -- Profile or reload changes reject capture, but a join still owned by this token must be released.
    if finished or joins[async] ~= token or not saveSystem.isAsyncSaveExtensionCurrent(async, generation) then
      return false
    end
    finished = true
    -- Keep the weak identity until capture returns; finishing is distinct from replacement.
    feature.tokens[token] = nil
    saveSystem.asyncSaveExtensionFinished(async, generation)
    return true
  end
  joins[async] = token
  feature.tokens[token] = true
  return token
end

local function beginAsync(feature, base)
  local problem = currentProblem(feature)
  if problem then return nil, problem end
  local saveSystem, descriptor = feature.saveSystem, feature.descriptor
  assert(descriptor.async, feature.key .. ': async identity required')
  local profile = saveSystem.getCurrentProfile()
  local generation = saveSystem.registerAsyncSaveExtension(descriptor.async)
  if not saveSystem.isAsyncSaveExtensionCurrent(descriptor.async, generation) then
    return nil, 'no current async save'
  end
  return newAsyncToken(feature, base, asyncJoinsOf(saveSystem), generation, profile)
end

-- Public API ----------------------------------------------------------------------------------------

function M.create(saveSystem, key, descriptor)
  assert(type(saveSystem) == 'table', 'saveSystem required')
  assert(type(descriptor) == 'table', 'feature descriptor required')
  local instance = {}
  local registered, problem = registerFeature(key, descriptor, instance)
  if not registered then return nil, problem end
  local feature = {saveSystem = saveSystem, key = key, descriptor = registered, instance = instance,
    disposed = false, tokens = {}}
  local adapter = {}
  function adapter.isCurrent() return isCurrent(feature) end
  function adapter.path(base, file) return pathOf(feature, base, file) end
  function adapter.write(base, ...) return writeThrough(feature, base, ...) end
  function adapter.capture(base, ...) return capture(feature, base, nil, nil, ...) end
  function adapter.restore(base, ...) return restore(feature, base, ...) end
  function adapter.beginAsync(base) return beginAsync(feature, base) end
  function adapter.dispose()
    if feature.disposed then return false end
    -- Finish only this instance's still-current joins; never complete a replacement's work.
    for token in pairs(feature.tokens) do token.finish() end
    feature.tokens = {}
    feature.disposed = true
    return registry.unregister(key, instance)
  end
  return adapter
end

return M
