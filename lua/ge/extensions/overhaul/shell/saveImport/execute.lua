-- One whole import of an old profile: validate, pick the target, read, prepare and write the new files.
-- Owns reading the old profile and the importer's only file output; runs inside the queued job's coroutine or straight through.
local optional = require('overhaul/lib/platform/optional')
local names = require('overhaul/shell/saveImport/names')
local cashOut = require('overhaul/shell/saveImport/cashOut')

local M = {}

-- The preflight report of the profile's newest supported slot (main's report, read-only).
function M.sourcePreflight(profile, slot)
  local service = optional('overhaul_career_saveMigration')
  assert(service and service.getSourceSavePreflight, 'Career migration service is unavailable.')
  local report = service.getSourceSavePreflight(profile, slot.path)
  assert(type(report) == 'table', 'Save data was not found')
  return report
end

-- Retain source paths for unchanged files so writing can copy their original bytes.
-- skipped: slot folder names left out of the copy (damaged or non-RLS slots).
local function readSourceFiles(services, profile, skipped)
  local checkpoint = services.checkpoint
  local base, files, signatures = names.SOURCE_ROOT .. profile .. '/', {}, {}
  local list = FS:findFiles(base, '*', -1, true, false) or {}
  checkpoint('reading', 0.05, 0, true)
  for index, file in ipairs(list) do
    local name = names.normalized(file)
    assert(name:sub(1, #base) == base, 'File escaped source profile: ' .. name)
    local relative = name:sub(#base + 1)
    assert(not relative:find('^%.%./') and not relative:find('/%.%./'), 'Unsafe source file path')
    if skipped[relative:match('^([^/]+)/')] then goto continue end
    local signature = {path = relative}
    -- Native signatures never had file size; keep their existing JSON text length/checksum without adding a new field.
    signatures[#signatures + 1] = signature
    if relative:sub(-5):lower() == '.json' and not relative:find('/vehicles/damage/', 1, true) then
      local bytes = readFile(file)
      assert(type(bytes) == 'string', 'Unreadable source file: ' .. relative)
      -- Hash in chunks so a large save reports progress while it is read.
      local hash = 0
      for start = 1, #bytes, 8192 do
        for i = start, math.min(start + 8191, #bytes) do hash = (hash * 33 + bytes:byte(i)) % 4294967291 end
        checkpoint('reading', 0.05 + 0.35 * (index - 1 + math.min(start + 8191, #bytes) / #bytes) / #list)
      end
      signature.textSize, signature.textChecksum = #bytes, string.format('%.0f', hash)
      local data = jsonReadFile(file)
      assert(type(data) == 'table', 'Unreadable source JSON: ' .. relative)
      files[relative] = {data = data}
    else
      files[relative] = {sourcePath = file}
    end
    checkpoint('reading', 0.05 + 0.35 * index / #list)
    ::continue::
  end
  table.sort(signatures, function(a, b) return a.path < b.path end)
  return files, signatures
end

-- Removes the files in `written` (newest first) and then the profile folder.
function M.rollback(root, written)
  for i = #written, 1, -1 do pcall(function() FS:removeFile(written[i]) end) end
  pcall(function() FS:directoryRemove(root) end)
end

-- info.json files go last, so a profile folder only looks like a save once its data is in place.
local function orderFileNames(prepared)
  local fileNames = names.sortedKeys(prepared)
  table.sort(fileNames, function(a, b)
    local aIsInfo, bIsInfo = a:match('/info%.json$') ~= nil, b:match('/info%.json$') ~= nil
    if aIsInfo ~= bIsInfo then return not aIsInfo end
    return a < b
  end)
  return fileNames
end

-- Records the path before writing it, so a failure part way can be rolled back.
local function writeEntry(root, written, name, entry)
  local filename = root .. '/' .. name
  written[#written + 1] = filename
  assert(FS:directoryCreate(filename:match('^(.*)/'), true) ~= false, 'Could not create save directory')
  local result
  if entry.data then
    result = jsonWriteFile(filename, entry.data, true)
    assert(result ~= false and FS:fileExists(filename), 'Could not write ' .. name)
  else
    result = FS:copyFile(entry.sourcePath, filename)
    assert((result == 0 or result == true) and FS:fileExists(filename), 'Could not copy ' .. name)
  end
end

-- Write the report before the completion record so failures remain eligible for rollback.
local function writeProfile(services, root, written, prepared, report, record)
  local checkpoint = services.checkpoint
  assert(FS:directoryCreate(root, true) ~= false, 'Could not create target profile')
  local fileNames = orderFileNames(prepared)
  for index, name in ipairs(fileNames) do
    writeEntry(root, written, name, prepared[name])
    checkpoint('writing', 0.7 + 0.29 * index / (#fileNames + 2))
  end
  writeEntry(root, written, names.REPORT, {data = report})
  checkpoint('writing', 0.7 + 0.29 * (#fileNames + 1) / (#fileNames + 2), 0, true)
  writeEntry(root, written, names.RECORD, {data = record})
end

-- An earlier import of this profile may have left a default target: reuse its name.
local function defaultTarget(services, profile)
  for _, record in ipairs(services.scan.importRecords()) do
    if record.sourceProfile == profile and record.defaultTarget == true then return record.targetProfile end
  end
end

local function isFinishedImportOf(existing, profile, target)
  return type(existing) == 'table' and existing.schemaVersion == names.VERSION and existing.complete == true
    and existing.sourceProfile == profile and existing.targetProfile == target
end

-- Checks the finished import in `target` is intact and answers a repeat request with it.
local function alreadyImportedResult(services, profile, target, existing)
  local report = jsonReadFile(names.TARGET_ROOT .. target .. '/' .. names.REPORT)
  assert(type(report) == 'table' and report.sourceProfile == profile and report.targetProfile == target,
    'Import record has no matching report')
  assert(type(existing.slots) == 'table' and #existing.slots > 0, 'Import record has no slots')
  for _, slot in ipairs(existing.slots or {}) do
    assert(names.validName(slot), 'Invalid imported slot name')
    local base = names.TARGET_ROOT .. target .. '/' .. slot
    local info = jsonReadFile(base .. '/info.json')
    assert(type(info) == 'table' and tonumber(info.version) == 64
      and FS:directoryExists(base .. '/career/rls_career')
      and type(jsonReadFile(base .. '/career/playerAttributes.json')) == 'table'
      and type(jsonReadFile(base .. '/career/inventory.json')) == 'table', 'Imported slot is missing or unreadable')
    services.checkpoint()
  end
  return {ok = true, targetProfile = target, alreadyImported = true, report = report}
end

-- Reuse a finished import; otherwise an unnamed target gets the next free profile suffix.
local function resolveTarget(services, profile, target, requestedTarget)
  local existing = jsonReadFile(names.TARGET_ROOT .. target .. '/' .. names.RECORD)
  if FS:directoryExists(names.TARGET_ROOT .. target) then
    if isFinishedImportOf(existing, profile, target) then
      return target, alreadyImportedResult(services, profile, target, existing)
    end
    assert(not requestedTarget, 'Target profile already exists')
    local suffix = 2
    while FS:directoryExists(names.TARGET_ROOT .. target) do
      target = profile .. ' ' .. suffix; suffix = suffix + 1
      services.checkpoint()
    end
  end
  return target
end

-- Choose a legacy migration policy against the newest slot, while plain imports retain their current behavior.
local function legacyPlan(services, profile, found, options)
  local legacy = options and services.scan.legacy(found[1].info,
    names.sourceJson(found[1].path .. '/career/rls_career/partRenames040.json'))
  if not legacy then return nil end
  local preflight = M.sourcePreflight(profile, found[1])
  local plan, err = cashOut.selectPlan(preflight, options)
  assert(plan, err)
  services.checkpoint()
  return plan
end

-- The record that marks an import complete; it is the last file written.
local function importRecord(profile, target, requestedTarget, found, report, signatures)
  local slotNames = {}
  for _, slot in ipairs(found) do slotNames[#slotNames + 1] = slot.name end
  return {schemaVersion = names.VERSION, complete = true, sourceProfile = profile,
    sourcePath = names.SOURCE_ROOT .. profile, sourceVersion = tonumber(found[1].info.version), targetProfile = target,
    defaultTarget = requestedTarget == nil, importedAt = report.importedAt, slots = slotNames, sourceFiles = signatures}
end

-- The queued job remembers each written file so cancellation can roll back a partial import.
local function writeImport(services, profile, target, requestedTarget, found, prepared, report, signatures)
  local root, written = names.TARGET_ROOT .. target, {}
  assert(not FS:directoryExists(root), 'Target profile already exists')
  services.checkpoint('writing', 0.7, 0, true)
  assert(not FS:directoryExists(root), 'Target profile already exists')
  local job = services.progress.currentJob()
  if job and coroutine.running() == job.thread then job.root, job.written = root, written else job = nil end
  local ok, err = pcall(writeProfile, services, root, written, prepared, report,
    importRecord(profile, target, requestedTarget, found, report, signatures))
  if job then job.root, job.written = nil, nil end
  if not ok then M.rollback(root, written); error(err) end
end

local function validateRequest(profile, requestedTarget, options)
  assert(names.validName(profile), 'Invalid source profile name')
  assert(requestedTarget == nil or names.validName(requestedTarget), 'Invalid target profile name')
  assert(options == nil or type(options) == 'table', 'Invalid migration options')
end

local function runImport(services, profile, requestedTarget, options)
  validateRequest(profile, requestedTarget, options)
  services.checkpoint('validating', 0, 0, true)
  local target = requestedTarget or profile
  if not requestedTarget then target = defaultTarget(services, profile) or target end
  local resolved, alreadyImported = resolveTarget(services, profile, target, requestedTarget)
  if alreadyImported then return alreadyImported end
  target = resolved
  -- Import the usable slots and leave damaged or non-RLS ones behind, as the source card says.
  local found, skipped = {}, {}
  for _, slot in ipairs(services.scan.slots(profile)) do
    if services.scan.supported(slot) then found[#found + 1] = slot else skipped[slot.name] = true end
    services.checkpoint()
  end
  assert(#found > 0, 'No importable RLS save slots')
  local plan = legacyPlan(services, profile, found, options)
  local files, signatures = readSourceFiles(services, profile, skipped)
  local prepared, report = services.prepare(profile, target, found, files, plan)
  writeImport(services, profile, target, requestedTarget, found, prepared, report, signatures)
  return {ok = true, targetProfile = target, alreadyImported = false, report = report}
end

-- The importer builds these services per load so their caches and queued work cannot cross reloads.
function M.create(deps)
  local services = {progress = deps.progress, scan = deps.scan, prepare = deps.prepare,
    checkpoint = deps.progress.checkpoint}
  return function(profile, requestedTarget, options)
    return runImport(services, profile, requestedTarget, options)
  end
end

return M
