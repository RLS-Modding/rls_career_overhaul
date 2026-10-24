-- Copies an old RLS save profile into an Overhaul profile and writes an import record and report.
-- Owns the import job (progress, queue, public API); the work is in shell/saveImport/ (start at execute.lua).
local M = {}

local names = require('overhaul/shell/saveImport/names')
local importSources = require('overhaul/shell/saveImport/importSources')
local preparePart = require('overhaul/shell/saveImport/prepare')
local executePart = require('overhaul/shell/saveImport/execute')

-- A queued import yields when its frame budget runs out, so scanning and writing cannot hold a frame.
local CHECKPOINT_FRAME_BUDGET_SECONDS = 0.008

-- Progress and job state: the last status, the one queued job (a coroutine that yields from
-- checkpoint() so a large import spreads over frames) and the "import running" flag.
local active = false
local queuedJob, lastStatus
local nextJobId = 0
local progress = {}

function progress.publish(status)
  lastStatus = status
  guihooks.trigger('OverhaulSaveImportProgress', status)
end

function progress.checkpoint(phase, fraction, units, force)
  local job = queuedJob
  if not job or coroutine.running() ~= job.thread then return end
  job.phase = phase or job.phase
  job.progress = math.max(job.progress, fraction or 0)
  job.units = job.units + (units or 1)
  if force or os.clock() - job.started >= CHECKPOINT_FRAME_BUDGET_SECONDS then
    progress.publish({jobId = job.id, profileName = job.profile, status = 'running', phase = job.phase, progress = job.progress})
    coroutine.yield()
  end
end

function progress.currentJob() return queuedJob end

-- Queues `run` (a function returning the import result) as the job and publishes 'queued'.
local function enqueue(profile, run)
  nextJobId = nextJobId + 1
  local job = {id = nextJobId, profile = profile, phase = 'queued', progress = 0}
  job.thread = coroutine.create(run)
  queuedJob, active = job, true
  progress.publish({jobId = job.id, profileName = profile, status = 'queued', phase = 'queued', progress = 0})
  return job
end

-- Runs the job until its next yield. Returns the coroutine's ok flag, its result and whether it finished.
local function resume(job)
  job.units = 0
  job.started = os.clock()
  local ok, result = coroutine.resume(job.thread)
  return ok, result, coroutine.status(job.thread) == 'dead'
end

-- Whether a slot was written before the 0.40 part migration (it still needs migrating on import).
local function legacy(info, marker)
  return (tonumber(info.version) or 0) < 64 or type(marker) ~= 'table' or (tonumber(marker.version) or 0) < 3
end

local function unsupportedReason(slot)
  if not slot.rls then return 'Not an RLS save slot' end
  if slot.infoUnreadable then return 'Missing or unreadable info.json' end
  local version = tonumber(slot.info.version)
  if not version or version % 1 ~= 0 then return 'Unrecognized save version: ' .. tostring(slot.info.version) end
  if version < 36 then return 'Made with an older RLS version (save version ' .. version .. ')' end
  if version > 64 then return 'Made with a newer save version (' .. version .. ')' end
  if slot.info.corrupted then return 'Save slot is marked corrupted' end
  for _, file in ipairs({'playerAttributes.json', 'inventory.json', 'general.json'}) do
    if type(jsonReadFile(slot.path .. '/career/' .. file)) ~= 'table' then
      return 'Missing or unreadable career/' .. file
    end
  end
end

local function supported(slot)
  return unsupportedReason(slot) == nil
end

-- Sorted names of the child folders of `root` that are safe to use as profile or slot names.
local function children(root)
  local result = {}
  for _, dir in ipairs(FS:directoryList(root, false, true) or {}) do
    local name = names.normalized(dir):match('([^/]+)$')
    if names.validName(name) then result[#result + 1] = name end
  end
  table.sort(result)
  return result
end

-- The slots of one source profile, newest first.
local function slotsOf(checkpoint, profile)
  local result = {}
  local base = names.SOURCE_ROOT .. profile .. '/'
  for _, name in ipairs(children(base)) do
    local info = jsonReadFile(base .. name .. '/info.json')
    local rls = FS:directoryExists(base .. name .. '/career/rls_career')
    if type(info) == 'table' or rls then
      result[#result + 1] = {name = name, path = base .. name, info = type(info) == 'table' and info or {},
        infoUnreadable = type(info) ~= 'table', rls = rls}
    end
    checkpoint()
  end
  table.sort(result, function(a, b)
    local aDate, bDate = tostring(a.info.date or ''), tostring(b.info.date or '')
    return aDate == bDate and a.name < b.name or aDate > bDate
  end)
  return result
end

local function importRecordsOf(checkpoint)
  local result = {}
  for _, name in ipairs(children(names.TARGET_ROOT)) do
    local record = jsonReadFile(names.TARGET_ROOT .. name .. '/' .. names.RECORD)
    if type(record) == 'table' and record.schemaVersion == names.VERSION and record.complete == true
      and record.targetProfile == name then result[#result + 1] = record end
    checkpoint()
  end
  return result
end

local function countVehicles(slot)
  local count = 0
  for _, file in ipairs(FS:findFiles(slot.path .. '/career/vehicles/', '*.json', 0, false, false) or {}) do
    if not names.normalized(file):sub(#slot.path + 2):find('/damage/', 1, true) then count = count + 1 end
  end
  return count
end

local function importedTargets(records, profile)
  local imported = {}
  for _, record in ipairs(records) do
    if record.sourceProfile == profile then imported[#imported + 1] = record.targetProfile end
  end
  return imported
end

local function blockedSlotNames(found, isSupported)
  local blocked = {}
  for _, candidate in ipairs(found) do
    if not isSupported(candidate) then blocked[#blocked + 1] = candidate.name end
  end
  return blocked
end

local function listingRow(profile, slot, found, records, isSupported)
  local attrs = jsonReadFile(slot.path .. '/career/playerAttributes.json')
  if type(attrs) ~= 'table' then attrs = {} end
  local marker = jsonReadFile(slot.path .. '/' .. names.PART_RENAME_MARKER)
  local imported = importedTargets(records, profile)
  local blockedSlots = blockedSlotNames(found, isSupported)
  local reasons = {}
  for _, candidate in ipairs(found) do
    local reason = unsupportedReason(candidate)
    if reason then reasons[#reasons + 1] = candidate.name .. ': ' .. reason end
  end
  -- One good slot is enough: damaged or non-RLS slots are skipped and named, not a reason to refuse the profile.
  local importable = isSupported(slot)
  return {profileName = profile, displayName = slot.info.displayName or profile,
    version = tonumber(slot.info.version), gameVersion = legacy(slot.info, marker) and '0.39' or '0.40',
    money = type(attrs.money) == 'table' and tonumber(attrs.money.value) or 0, vehicleCount = countVehicles(slot),
    lastPlayed = slot.info.date, slot = slot.name, alreadyImported = #imported > 0, importedTargets = imported,
    canImport = importable, blockedSlots = blockedSlots,
    importBlockReason = not importable and #reasons > 0 and table.concat(reasons, '; ') or nil,
    skippedSlotReason = importable and #reasons > 0 and table.concat(reasons, '; ') or nil}
end

-- Keep unsupported RLS profiles visible too, so the player can see why the copy is unavailable.
local function firstListingRow(profile, found, records, includeUnsupported)
  local supportedBySlot = {}
  local function isSupported(slot)
    if supportedBySlot[slot] == nil then supportedBySlot[slot] = supported(slot) end
    return supportedBySlot[slot]
  end
  local selected, rls
  for _, slot in ipairs(found) do
    if slot.rls then rls = rls or slot end
    if isSupported(slot) then selected = selected or slot end
  end
  if selected or (includeUnsupported and rls) then return listingRow(profile, selected or rls, found, records, isSupported) end
end

local scan = {legacy = legacy, supported = supported}

function scan.slots(profile)
  return slotsOf(progress.checkpoint, profile)
end

function scan.importRecords()
  return importRecordsOf(progress.checkpoint)
end

-- Include both save roots in the cache stamp so creating, deleting or importing a profile forces a rescan.
function scan.saveRootsStamp()
  return table.concat(children(names.SOURCE_ROOT), '/') .. '|' .. table.concat(children(names.TARGET_ROOT), '/')
end

-- pace(profile, slots) is optional; onlyProfile limits the listing to one profile.
function scan.listImportableSaves(pace, onlyProfile, includeUnsupported)
  local result, records = {}, scan.importRecords()
  for _, profile in ipairs(onlyProfile and {onlyProfile} or children(names.SOURCE_ROOT)) do
    local found = scan.slots(profile)
    local row = firstListingRow(profile, found, records, includeUnsupported)
    if row then result[#result + 1] = row end
    if pace then pace(profile, found) end
  end
  return result
end

local prepare = preparePart.create({progress = progress, scan = scan})
local execute = executePart.create({progress = progress, scan = scan, prepare = prepare})

-- Profile-screen cards and the migration step's report (lib/save/importSources.lua).
local sources = importSources.create({list = function(pace, profile) return scan.listImportableSaves(pace, profile, true) end,
  stamp = scan.saveRootsStamp, slots = scan.slots,
  records = scan.importRecords, validName = names.validName, preflight = executePart.sourcePreflight,
  sourceRoot = names.SOURCE_ROOT, targetRoot = names.TARGET_ROOT})

-- Clears the job, drops the cached source cards so the profile screen matches the disk, then publishes
-- 'complete' so a UI never sees stale running state.
local function finishJob(job, result)
  queuedJob, active = nil, false
  sources.invalidate()
  progress.publish({jobId = job.id, profileName = job.profile, status = 'complete', phase = 'complete', progress = 1, result = result})
end

-- A job that stops mid-write leaves files behind: remove them.
local function rollbackJob(job)
  if job.root then executePart.rollback(job.root, job.written) end
end

function M.onUpdate()
  local job = queuedJob
  if not job then return end
  local ok, result, finished = resume(job)
  if not ok then
    rollbackJob(job)
    finishJob(job, {ok = false, error = tostring(result)})
  elseif finished then
    finishJob(job, result)
  end
end

M.listImportableSaves = scan.listImportableSaves
M.getImportSourceCards = sources.cards
M.getImportSourceCardsAsync = sources.cardsAsync
M.getImportPreflight = sources.preflight
M.getImportSourceHighlights = sources.highlights

function M.logImportDiagnostics()
  for _, profile in ipairs(children(names.SOURCE_ROOT)) do
    for _, slot in ipairs(scan.slots(profile)) do
      log('I', 'overhaul.saveImport', profile .. '/' .. slot.name .. ' (version ' .. tostring(slot.info.version)
        .. '): ' .. (unsupportedReason(slot) or 'ready to import'))
    end
  end
end

function M.getImportStatus() return lastStatus end

function M.queueImportSave(profile, target, options)
  if active then return {ok = false, error = 'An import is already running'} end
  if not names.validName(profile) then return {ok = false, error = 'Invalid source profile name'} end
  if target ~= nil and not names.validName(target) then return {ok = false, error = 'Invalid target profile name'} end
  if options ~= nil and type(options) ~= 'table' then return {ok = false, error = 'Invalid migration options'} end
  local job = enqueue(profile, function()
    local ok, result = pcall(execute, profile, target, options)
    return ok and result or {ok = false, error = tostring(result)}
  end)
  return {ok = true, jobId = job.id}
end

function M.importSave(profile, target, options)
  if active then return {ok = false, error = 'An import is already running'} end
  active = true
  local ok, result = pcall(execute, profile, target, options)
  active = false
  sources.invalidate()
  return ok and result or {ok = false, error = tostring(result)}
end

function M.onExtensionUnloaded()
  sources.dispose()
  local job = queuedJob
  if not job then return end
  rollbackJob(job)
  finishJob(job, {ok = false, error = 'Import cancelled because the save import extension was unloaded'})
end

return M
