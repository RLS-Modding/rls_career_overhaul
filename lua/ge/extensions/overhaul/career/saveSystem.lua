-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/saveSystem.lua (BeamNG 0.40).
-- Career save slots: profiles, autosave rotation and the queued pipeline that commits one save.
-- Reading order: requires, config, state, write queue, capture, gates, profile folders, save lifecycle, write pump, update, exit, public API.

local M = {}

-- Requires ----------------------------------------------------------------------------------------

local careerContext = require("overhaul/lib/career/context")
M.dependencies = {"overhaul_shell_patches"}
local saveSchema = require('overhaul/lib/save/schema')
local saveStore = require('overhaul/lib/save/store')
local lifecycle = require('overhaul/lib/lifecycle/host')
local transitions = require('overhaul/lib/lifecycle/transitions')
local saveJson = require('overhaul/lib/save/jsonWriter')

-- SaveStore key over the file this module commits; module keys live with their owners.
saveStore.registerKeys({
  {key = "save.info", owner = "overhaul_career_saveSystem", files = {"info.json"}, phase = "profile", required = true},
})

-- Config ---------------------------------------------------------------------------------------------

local saveRoot = 'settings/cloud/overhaul/saves/'
local saveSystemVersion = 64
local backwardsCompVersion = 36
local numberOfAutosaves = 4
local DEFAULT_AUTOSAVE_INTERVAL_MINUTES = 5
local AUTOSAVE_STOP_TOLERANCE = 0.15
local AUTOSAVE_STOP_TOLERANCE_SQ = AUTOSAVE_STOP_TOLERANCE * AUTOSAVE_STOP_TOLERANCE
local SAVE_IN_FLIGHT_TIMEOUT_S = 45
local STOP_SAMPLE_INTERVAL = 0.25 -- without a queued save the stop time is only sampled this often
local WRITE_BUDGET_MS = 2.5
local EXIT_WRITE_BUDGET_MS = 1000 -- leaving the level or game waits for the save, so it drains what is ready
local WRITE_OPS_CAP = 1024
local REUSE_MIN_BYTES = 16384 -- smaller captures are always encoded again
local REQUEST_TRACE_LIMIT = 64
local CAPTURED_FILE_OPS = {copy = "copyFile", rename = "renameFile", remove = "removeFile"}

-- State ----------------------------------------------------------------------------------------------

local currentProfile
local currentSavePath
local currentDisplayName
local creationDateOfCurrentProfile
local lastAutosaveAt = 0
local saveStartedAt = 0
local stoppedFor = 0
local stopSampleElapsed = 0
-- Captured when a save begins so a late async completion cannot overwrite the active profile's currentSavePath after a profile switch.
local saveInFlightProfile = nil
local lastSaveStats
local lastWriteFiles
local lastWriteSlot
-- The save in flight as the lifecycle host sees it.
local saveTransition

local queueSave = false
local saveInProgress = false
local pendingForceSave = false
local pendingSaveName = nil
local pendingVehiclesThumbnailUpdate
local pendingManualSave = false
local inFlightManualSave = false
local exitFlush = false
local pendingExit
local exitSaveFailed = false

local syncSaveExtensionsDone
local asyncSaveExtensions = {}
local saveGeneration = 0
local activeSaveGeneration = 0
local inFlightSaveName = nil
local inFlightForceSave = false
local inFlightVehiclesThumbnailUpdate
local infoData
local saveDate
local oldestSave
local pendingSaveSuccessSound = false

local writeQueue = {}
local writeIndex = 1
local writeDetails = setmetatable({}, {__mode = "k"})
-- Cheap steps that start or finish async work (vehicle requests) run before queued encoding.
local priorityQueue = {}
local priorityIndex = 1
local captureDepth = 0
local writing = false
local snapshotStarted, captureMs, writeFrames, fileCount = 0, 0, 0, 0
local backupPath
local backupFiles = {}
local saveStampCommitted = false
local saveFailureReason
local backupReady = false
local backupWasCurrent = false
local writeFiles = {}
local activeWriter
local timingLog = false
local activeWriters = {}
local snapshotCopyMs = 0
local frameEncodeMs, frameIoMs = 0, 0
local lastBlobs, lastBlobSlot, newBlobs = {}, nil, {}
local reusedFiles = 0

local requestTrace, requestSeq, requestReason = {}, 0, nil
-- Breaks the start/finish cycle: a finished save may start a queued exit save.
local flow = {}

local featureWrites = require('overhaul/lib/save/featureWrites').new(FS, function() infoData = nil end,
  function() return saveInProgress end)

-- Write queue ----------------------------------------------------------------------------------------

local function clockMs()
  if os.clockhp then return os.clockhp() * 1000 end
  return (os.clock and os.clock() or os.time()) * 1000
end

local function resetQueues()
  writeQueue, writeIndex, priorityQueue, priorityIndex = {}, 1, {}, 1
  featureWrites.reset()
end

local function queuesDone()
  return writeIndex > #writeQueue and priorityIndex > #priorityQueue
end

local function saveFailed(reason)
  if featureWrites.required() then
    infoData = nil
    saveFailureReason = saveFailureReason or reason
  end
end

local function describeWrite(filename, operation, source)
  local relative
  if filename and oldestSave then
    local file, slot = filename:gsub("^/+", ""), oldestSave:gsub("^/+", "")
    for _, base in ipairs({slot, slot .. "_recovery"}) do
      if file:sub(1, #base + 1) == base .. "/" then relative = file:sub(#base + 2); break end
    end
  end
  local key = relative and saveStore.keyForFile(relative)
  local feature, caller = featureWrites.key() or (key and key.key), ""
  if not feature then
    for level = 3, 12 do
      local frame = debug.getinfo(level, "Sl")
      if not frame then break end
      local file = frame.source or ""
      if file:find("overhaul/", 1, true) and not file:find("/lib/", 1, true)
          and not file:find("/saveSystem.lua", 1, true) then
        caller = " caller=" .. file:gsub("^@", "") .. ":" .. frame.currentline
        break
      end
    end
  end
  return string.format("operation=%s feature=%s path=%s%s", operation or "callback",
    feature or "unregistered", tostring(filename or oldestSave),
    (source and (" source=" .. tostring(source)) or "") .. caller)
end

local function enqueueWrite(operation, filename, onFailure, kind, source)
  local description = describeWrite(filename, kind, source)
  local wrapped = featureWrites.wrap(operation, filename, onFailure, description)
  writeDetails[wrapped] = description
  writeQueue[#writeQueue + 1] = wrapped
  if filename and kind ~= "directoryCreate" and kind ~= "removeFile" and not writeFiles[filename] then
    writeFiles[filename] = true
    fileCount = fileCount + 1
  end
  return true
end

local function normPath(rawPath) return (tostring(rawPath):gsub("\\", "/"):gsub("^/+", "")) end

local function forgetSavedBlobs()
  lastBlobs, lastBlobSlot, newBlobs = {}, nil, {}
end

local function slotRelative(filename)
  if not oldestSave then return nil end
  local file, slot = normPath(filename), normPath(oldestSave)
  if file:sub(1, #slot + 1) == slot .. "/" then return file:sub(#slot + 1) end
end

local function sameStat(entry, stat)
  return stat and entry.size == stat.filesize and entry.modtime == stat.modtime
end

local function newJsonJob(temp, captured, precision)
  return saveJson.writer(temp, captured, {
    clock = clockMs, open = io.open, precision = precision,
    encode = function(value, digits)
      if digits and type(value) == 'number' then return jsonEncodePretty(value, 1, digits) end
      return jsonEncode(value)
    end,
    timing = function(file, encoded, written, bytes, done, totalEncode, totalWrite, slices)
      frameEncodeMs, frameIoMs = frameEncodeMs + encoded, frameIoMs + written
      if timingLog then
        log('D', 'saveSystem', string.format('save file phase path=%s encode_ms=%.3f write_ms=%.3f bytes=%d done=%s encode_total_ms=%.3f write_total_ms=%.3f slices=%d',
          file, encoded, written, bytes, tostring(done), totalEncode, totalWrite, slices))
      end
    end,
  })
end

-- Queues a JSON write; an unchanged capture is copied from the last completed save when its source is trusted.
local function enqueueJson(filename, obj, pretty, precision, tempFileName, fallback)
  local started = clockMs()
  local captured = saveJson.capture(obj)
  local elapsed = clockMs() - started
  snapshotCopyMs = snapshotCopyMs + elapsed
  if elapsed >= 5 then log('D', 'saveSystem', string.format('save timing snapshot_ms=%.3f path=%s', elapsed, filename)) end
  if type(obj) ~= 'table' or type(jsonEncode) ~= 'function' then
    return enqueueWrite(function() return fallback(saveJson.restore(captured)) end, filename, nil, "json"), captured
  end
  local temp = tempFileName or filename .. '.tmp'
  featureWrites.track(temp)
  local rel = FS.stat and saveJson.isCaptured(captured) and not captured.copies and #captured.blob >= REUSE_MIN_BYTES
    and not writeFiles[filename] and slotRelative(filename)
  local entry = rel and {blob = captured.blob, precision = precision}
  if entry then newBlobs[rel] = entry end
  local previous = entry and lastBlobSlot and lastBlobs[rel]
  local reuse = previous and previous.blob == entry.blob and previous.precision == precision and previous
  local source = reuse and (lastBlobSlot .. rel)
  local job
  local function finished()
    local code, problem = FS:renameFile(temp, filename)
    if code ~= 0 then return false, "renameFile(" .. temp .. ") returned " .. tostring(code) .. ": " .. tostring(problem) end
    if entry then
      local stat = FS:stat(filename)
      entry.size, entry.modtime = stat and stat.filesize, stat and stat.modtime
    end
    return true
  end
  return enqueueWrite(function(budgetMs)
    if not job then
      if reuse and sameStat(reuse, FS:stat(source)) and FS:copyFile(source, temp) == 0 then
        reusedFiles = reusedFiles + 1
        captured = nil
        return finished()
      end
      job = newJsonJob(temp, captured, precision)
      activeWriters[job] = true
    end
    if not job.step(budgetMs) then return 'pending' end
    activeWriters[job] = nil
    return finished()
  end, filename, function()
    if job then job.cancel(); activeWriters[job] = nil end
  end, "json"), captured
end

local function jsonWriteFileSafe(filename, obj, pretty, numberPrecision, tempFileName)
  if saveInProgress and (not writing or captureDepth > 0) and type(obj) == 'table' then
    return enqueueJson(filename, obj, pretty, numberPrecision, tempFileName,
      function(captured) return M.jsonWriteFileSafe(filename, captured, pretty, numberPrecision, tempFileName) end)
  end
  -- A nil or non-table payload soft-skips: the prior file stays, the symptom is logged, and the save goes on.
  if type(obj) ~= "table" then
    log("E", "save", string.format(
      "jsonWriteFileSafe: refusing non-table (%s) for %s — leaving prior file intact",
      type(obj), tostring(filename)))
    log("E", "save", debug.traceback())
    return true
  end
  tempFileName = tempFileName or filename..".tmp"
  local result, problem = jsonWriteFile(tempFileName, obj, pretty, numberPrecision)
  local operation = "jsonWriteFile"
  if result then
    result, problem = FS:renameFile(tempFileName, filename)
    if result == 0 then return true end
    operation = "renameFile"
  end
  local reason = describeWrite(filename, operation, tempFileName)
    .. "; returned " .. tostring(result) .. ": " .. tostring(problem)
  log("E", "save", reason)
  saveFailed(reason)
  return false, reason
end

local directWriter = {
  json = function(filename, obj, ...) return jsonWriteFile(filename, obj, ...) end,
  write = function(filename, data, ...) return writeFile(filename, data, ...) end,
  read = function(filename, ...) return jsonReadFile(filename, ...) end,
  copy = function(...) return FS:copyFile(...) end,
  rename = function(...) return FS:renameFile(...) end,
  remove = function(...) return FS:removeFile(...) end,
  mkdir = function(...) return FS:directoryCreate(...) end,
  removeDir = function(...) return FS:directoryRemove(...) end,
  exists = function(dir) return FS:directoryExists(dir) end,
  findFiles = function(...) return FS:findFiles(...) end,
}

-- The writer of the running capture, or one that writes straight to disk.
local function getSaveWriter()
  return activeWriter or directWriter
end

-- Capture writer ---------------------------------------------------------------------------------------

local function captureKey(file)
  return type(file) == "string" and file:gsub("^/+", "") or file
end

local function newCaptureState()
  return {
    json = jsonWriteFile, read = jsonReadFile, write = writeFile, fileSystem = FS,
    capturedJson = {}, created = {}, scans = {},
    stats = {scanMs = 0, scanCount = 0, scanHits = 0},
  }
end

local function captureJson(capture, filename, obj, ...)
  local args = {...}
  local queued, data = enqueueJson(filename, obj, args[1], args[2], type(args[3]) == 'string' and args[3] or nil,
    function(captured) return capture.json(filename, captured, unpack(args)) end)
  capture.capturedJson[captureKey(filename)] = data
  return queued
end

local function captureRead(capture, filename, ...)
  if capture.capturedJson[captureKey(filename)] ~= nil then return saveJson.restore(capture.capturedJson[captureKey(filename)]) end
  return capture.read(filename, ...)
end

local function captureWrite(capture, filename, data, ...)
  local args = {...}
  return enqueueWrite(function()
    local result, problem = capture.write(filename, data, unpack(args))
    return result ~= false and result ~= nil, "writeFile returned " .. tostring(result) .. ": " .. tostring(problem)
  end, filename, nil, "writeFile")
end

local function captureFindFiles(capture, ...)
  local args, parts, count = {...}, {}, select('#', ...)
  for i = 1, count do parts[i] = type(args[i]) .. ':' .. tostring(args[i]) end
  local query = table.concat(parts, '\0')
  local files = capture.scans[query]
  if files == nil then
    local started = clockMs()
    files = capture.fileSystem:findFiles(unpack(args, 1, count))
    capture.stats.scanMs, capture.stats.scanCount = capture.stats.scanMs + clockMs() - started, capture.stats.scanCount + 1
    if files then capture.scans[query] = files end
  else
    capture.stats.scanHits = capture.stats.scanHits + 1
  end
  if not files then return files end
  local result = {}
  for i, file in ipairs(files) do result[i] = file end
  return result
end

local function captureMkdir(capture, dir, ...)
  if not oldestSave or captureKey(dir):sub(1, #captureKey(oldestSave)) ~= captureKey(oldestSave) then
    capture.scans = {}
    return capture.fileSystem:directoryCreate(dir, ...)
  end
  capture.created[captureKey(dir)] = true
  enqueueWrite(function()
    -- Another capture (or an earlier child-directory create) may have made it
    -- since this operation was queued. Existence is the successful postcondition.
    if capture.fileSystem:directoryExists(dir) then return true end
    -- Captures run before queued JSON writers create their parent folders.
    -- A nested save directory must not depend on another hook's write order.
    local result, problem = capture.fileSystem:directoryCreate(dir, true)
    return capture.fileSystem:directoryExists(dir), "directoryCreate returned " .. tostring(result) .. ": " .. tostring(problem)
  end, dir, nil, "directoryCreate")
  return true
end

local function captureRemoveDir(capture, ...)
  capture.scans = {}
  return capture.fileSystem:directoryRemove(...)
end

local function captureExists(capture, dir)
  return capture.created[captureKey(dir)] or capture.fileSystem:directoryExists(dir)
end

-- Copy, rename and remove are queued; the caller sees 0 at once and the result comes from the queue.
local function captureFileOp(capture, method)
  return function(...)
    local args = {...}
    enqueueWrite(function()
      local result, problem = capture.fileSystem[method](capture.fileSystem, unpack(args))
      if method == "removeFile" then
        -- Missing cleanup targets are harmless; stale vehicle records are not.
        return result == 0 or not capture.fileSystem:fileExists(args[1]),
          "removeFile returned " .. tostring(result)
      end
      -- Stock thumbnails are optional; missing damage/JSON files are failures.
      if method == "copyFile" and tostring(args[1]):match("%.jpg$") and not capture.fileSystem:fileExists(args[1]) then return true end
      return result == 0, method .. " returned " .. tostring(result) .. ": " .. tostring(problem)
    end, method ~= "removeFile" and args[2] or args[1], nil, method, args[1])
    return 0
  end
end

local function newCaptureWriter()
  local capture = newCaptureState()
  local ops = {
    json = function(filename, obj, ...) return captureJson(capture, filename, obj, ...) end,
    read = function(filename, ...) return captureRead(capture, filename, ...) end,
    write = function(filename, data, ...) return captureWrite(capture, filename, data, ...) end,
    findFiles = function(...) return captureFindFiles(capture, ...) end,
    mkdir = function(dir, ...) return captureMkdir(capture, dir, ...) end,
    removeDir = function(...) return captureRemoveDir(capture, ...) end,
    exists = function(dir) return captureExists(capture, dir) end,
  }
  for name, method in pairs(CAPTURED_FILE_OPS) do ops[name] = captureFileOp(capture, method) end
  local writer = {}
  for name, op in pairs(ops) do
    -- A writer kept past its capture acts like whichever writer is current.
    writer[name] = function(...)
      if activeWriter ~= writer then return getSaveWriter()[name](...) end
      return op(...)
    end
  end
  return writer, capture.stats
end

local function captureSaveWrites(callback, ...)
  if captureDepth > 0 or not saveInProgress then return callback(getSaveWriter(), ...) end
  local captureStarted = clockMs()
  local writer, stats = newCaptureWriter()
  activeWriter = writer
  captureDepth = captureDepth + 1
  local result = {pcall(callback, writer, ...)}
  captureDepth = captureDepth - 1
  activeWriter = nil
  local elapsed = clockMs() - captureStarted
  captureMs = captureMs + elapsed
  if timingLog then log('D', 'saveSystem', string.format('save capture slice_ms=%.3f snapshot_copy_ms=%.3f fs_scan_ms=%.3f fs_scans=%d fs_scan_hits=%d', elapsed, snapshotCopyMs, stats.scanMs, stats.scanCount, stats.scanHits)) end
  if not result[1] then
    log("E", "saveSystem", "Snapshot capture failed: " .. tostring(result[2]))
    saveFailed(tostring(result[2]))
    return nil
  end
  return unpack(result, 2)
end

-- Gates and queries -------------------------------------------------------------------------------------

local isCareerActive = careerContext.isCareerActiveStrict

local function autosaveEnabled()
  return not overhaul_career_career or overhaul_career_career.isAutosaveEnabled()
end

local function isSaveBusy()
  return saveInProgress
end

local function isSavePending()
  return saveInProgress or (queueSave and isCareerActive())
end

local function clearQueuedSave()
  queueSave = false
  pendingForceSave, pendingManualSave = false, false
  pendingSaveName, pendingVehiclesThumbnailUpdate = nil, nil
  pendingSaveSuccessSound = false
end

local function autosaveIntervalReady()
  if lastAutosaveAt <= 0 then
    return true
  end
  local interval = overhaul_shell_settings and overhaul_shell_settings.getSetting("autosaveIntervalMinutes")
  if interval ~= 5 and interval ~= 10 and interval ~= 15 and interval ~= 30 and interval ~= 60 then
    interval = DEFAULT_AUTOSAVE_INTERVAL_MINUTES
  end
  return (os.time() - lastAutosaveAt) >= interval * 60
end

local function markAutosaveDone()
  lastAutosaveAt = os.time()
end

-- The seated vehicle counts as stopped only when it is slow, and so does the inventory car when it is not the one seated.
local function playerIsStopped()
  local playerVeh = be and be:getPlayerVehicle(0)
  local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()
  if walking then return true end
  if playerVeh and playerVeh:getVelocity():squaredLength() >= AUTOSAVE_STOP_TOLERANCE_SQ then return false end
  local inventory = overhaul_career_garage_inventory
  local inventoryId = inventory and inventory.getCurrentVehicle()
  local vehId = inventoryId and inventory.getVehicleIdFromInventoryId(inventoryId)
  local owned = vehId and be:getObjectByID(vehId)
  if owned and owned ~= playerVeh and owned:getVelocity():squaredLength() >= AUTOSAVE_STOP_TOLERANCE_SQ then return false end
  return true
end

-- A UI route can ask for no autosave with meta.deferAutosave, on its node or on the registered route.
local function routeDefersAutosave()
  if not (ui_router and ui_router.getState) then return false end
  local readOk, state = pcall(ui_router.getState)
  local entry = readOk and type(state) == 'table' and state.currentRoute
  local node = type(entry) == 'table' and entry.routeNode
  local resolved = type(entry) == 'table' and entry.resolved
  local meta = type(node) == 'table' and node.meta or type(resolved) == 'table' and resolved.meta
  if type(meta) ~= 'table' or meta.deferAutosave == nil then
    local name = careerContext.currentUiRouteName()
    local manager = ui_router_routeManager
    local route = name and manager and manager.getRoute and manager.getRoute(name)
    meta = type(route) == 'table' and route.meta or meta
  end
  return type(meta) == 'table' and meta.deferAutosave == true
end

local function shouldDeferAutosave()
  if saveStore.isHeld('beforeRoute') then return true end
  if routeDefersAutosave() then return true end
  if core_gamestate.loading() then return true end
  if core_gamestate.getLoadingStatus("careerLoading") or core_gamestate.getLoadingStatus("careerActivate") then
    return true
  end
  if saveStore.isHeld('beforeRecovery') then return true end
  saveStore.recoverHolds()
  if saveStore.isHeld() then return true end
  return false
end

-- Profile folders -------------------------------------------------------------------------------------

-- Old saves have only a display date. Once written by this version, a persisted
-- sequence orders commits even within one second or after a clock adjustment.
local function validSaveSequence(data)
  local sequence = data.saveSequence
  if type(sequence) == 'number' and sequence >= 0 and sequence < math.huge and sequence % 1 == 0 then
    return sequence
  end
end

local function saveIsOlder(a, b)
  local left, right = validSaveSequence(a), validSaveSequence(b)
  -- Legacy slots predate sequenced commits, regardless of clock changes.
  if (left ~= nil) ~= (right ~= nil) then return left == nil end
  if left and right and left ~= right then return left < right end
  return (a.date or "0") < (b.date or "0")
end

local function nextSaveSequence(profileFolder)
  local sequence = 0
  for _, folder in ipairs(FS:directoryList(profileFolder, false, true)) do
    local data = jsonReadFile(folder .. "/info.json")
    if data and not data.corrupted then sequence = math.max(sequence, validSaveSequence(data) or 0) end
  end
  return sequence + 1
end

local function isLegalDirectoryName(name)
  return require('overhaul/lib/save/pathComponent').valid(name)
end

local function getAllSaveFolders(profile)
  if not isLegalDirectoryName(profile) then return {} end
  local res = {}
  local folders = FS:directoryList(saveRoot .. profile, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    local data = jsonReadFile(dir .. filename .. "/info.json")
    if data then
      data.name = filename
      table.insert(res, data)
    end
  end

  table.sort(res, saveIsOlder)
  return res
end

local function pickSaveByDate(folders, oldest)
  local resultData
  local resultSave = ""
  for i = 1, tableSize(folders) do
    local folder = folders[i]
    local data = jsonReadFile(folder .. "/info.json")
    if oldest then
      if not data or not data.date or data.corrupted then return folder end
      if not resultData or saveIsOlder(data, resultData) then
        resultSave = folder
        resultData = data
      end
    else
      if data and data.date and not data.corrupted and (not resultData or saveIsOlder(resultData, data)) then
        resultSave = folder
        resultData = data
      end
    end
  end
  return resultSave
end

-- The first free autosave slot, or else the oldest one that is readable.
local function getOldestAutosave(profileFolder)
  local folders = FS:directoryList(profileFolder, false, true)

  local existingAutosaves = {}
  for i = 1, tableSize(folders) do
    local name = string.match(folders[i], "([^/\\]+)$")
    if name and string.match(name, "^autosave%d+$") then
      existingAutosaves[name] = folders[i]
    end
  end

  for i = 1, numberOfAutosaves do
    if not existingAutosaves["autosave" .. i] then
      return "/" .. profileFolder .. "/autosave" .. i
    end
  end

  local autosaveFolders = {}
  for i = 1, numberOfAutosaves do
    if existingAutosaves["autosave" .. i] then
      table.insert(autosaveFolders, existingAutosaves["autosave" .. i])
    end
  end
  return pickSaveByDate(autosaveFolders, true)
end

local function getNewestSave(profileFolder)
  local folders = FS:directoryList(profileFolder, false, true)
  return pickSaveByDate(folders, false)
end



local function getUsedProfileNames()
  local usedNames = {}
  local folders = FS:directoryList(saveRoot, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    usedNames[string.lower(filename)] = true
  end
  return usedNames
end

-- Folder-safe lowercase letters and digits, with a numbered suffix when the name is taken.
local function getSanitizedProfileName(profileName)
  local usedNames = getUsedProfileNames()
  local sanitizedName = string.lower(profileName or '')
  sanitizedName = string.gsub(sanitizedName, '[^a-z0-9]', '')
  if sanitizedName == '' then
    sanitizedName = 'profile'
  end

  local candidate = sanitizedName
  local counter = 1
  while not isLegalDirectoryName(candidate) or usedNames[string.lower(candidate)] do
    candidate = sanitizedName .. counter
    counter = counter + 1
  end
  return candidate
end

-- A slot written by a newer Overhaul is refused before any migration, hook or state change, so this build never loads and then drops newer state.
local function newerSchemaRefusal(profile, specificSaveFolder)
  if type(profile) ~= "string" or profile == "" then return nil end
  local slotPath = specificSaveFolder and (saveRoot .. profile .. "/" .. specificSaveFolder) or getNewestSave(saveRoot .. profile)
  if not slotPath or slotPath == "" then return nil end
  return saveSchema.refusal(jsonReadFile(slotPath .. "/info.json"))
end

-- Clears the saved-blob reuse state and the profile's hooks before its fields change.
local function beginProfileSwitch()
  extensions.hook("onOverhaulBeforeSetProfile")
  forgetSavedBlobs()
end

local function clearProfile()
  beginProfileSwitch()
  currentSavePath = nil
  currentProfile = nil
  currentDisplayName = nil
  creationDateOfCurrentProfile = nil
  extensions.hook("onOverhaulSetProfile", nil, nil)
  return false
end

-- A profile without a requested slot opens its newest save, or autosave1 when it has none yet.
local function resolveSavePath(profile, specificSaveFolder)
  local savePath = specificSaveFolder and (saveRoot .. profile .. "/" .. specificSaveFolder) or getNewestSave(saveRoot .. profile)
  if not savePath or savePath == "" then savePath = saveRoot .. profile .. "/autosave1" end
  return savePath
end

local function activateProfile(profile, savePath)
  currentSavePath = savePath
  currentProfile = profile
  lastAutosaveAt = os.time()
  queueSave = false
  lifecycle.advance("profile", "setProfile")
  extensions.hook("onOverhaulSetProfile", currentSavePath, profile)
  return true
end

local function setProfile(profile, specificSaveFolder)
  -- Validate before any filesystem lookup, migration or outgoing save. An
  -- existing directory/info.json grants no exception to component validation.
  local displayName, displayOnly = profile, false
  if profile ~= nil and not isLegalDirectoryName(profile) then
    -- A new profile's display name can end in punctuation or spell a device
    -- alias. Allocate a legal unused ID before any lookup of that profile.
    -- Explicit slots always identify existing folders, never display names.
    if specificSaveFolder ~= nil or not require('overhaul/lib/save/pathComponent').displayName(profile) then return false end
    displayOnly = true
  end
  if specificSaveFolder ~= nil and not isLegalDirectoryName(specificSaveFolder) then return false end
  if M.isSavePending and M.isSavePending() then
    M.flushSaveForExit(function() setProfile(profile, specificSaveFolder) end)
    return false
  end
  if displayOnly then profile = getSanitizedProfileName(displayName) end
  local refusal = newerSchemaRefusal(profile, specificSaveFolder)
  if refusal then
    log("E", "saveSystem", "Save refused: " .. refusal .. " (" .. tostring(profile) .. ")")
    guihooks.trigger("toastrMsg", {type="error", label="career-save", title="Save not loaded", msg=refusal, config={timeOut=10000}})
    return false
  end
  if not profile then return clearProfile() end
  local report = overhaul_career_saveMigration.getLegacySavePreflight(profile, specificSaveFolder)
  if report.requiresMigration then
    overhaul_career_saveMigration.requestLegacySaveMigration(report)
    return false
  end

  local savePath = resolveSavePath(profile, specificSaveFolder)
  local data = jsonReadFile(savePath .. "/info.json")
  if data then
    if not data.version or M.getBackwardsCompVersion() > data.version then
      return false
    end
    beginProfileSwitch()
    creationDateOfCurrentProfile = data.creationDate
    currentDisplayName = data.displayName or profile
    return activateProfile(profile, savePath)
  end

  beginProfileSwitch()
  currentDisplayName = displayName
  -- An unfinished slot already owns its folder ID. Reusing it must not silently
  -- create a numbered sibling; unreadable saves are refused by career start.
  local exactFolder = false
  if type(profile) == 'string' and profile:match('^[A-Za-z0-9][A-Za-z0-9_-]*$') then
    for _, existing in ipairs(FS:directoryList(saveRoot, false, true)) do
      local _, name = path.split(existing)
      if name == profile then exactFolder=true; break end
    end
  end
  local sanitizedProfile = exactFolder and profile or getSanitizedProfileName(profile)
  creationDateOfCurrentProfile = nil
  return activateProfile(sanitizedProfile, resolveSavePath(sanitizedProfile, specificSaveFolder))
end

local function removeProfile(profile)
  if type(profile) ~= "string" or profile == "" or profile == "." or profile == ".." or not isLegalDirectoryName(profile) then return end
  if currentProfile == profile then
    if not overhaul_career_career.isActive() then
      setProfile(nil)
      FS:directoryRemove(saveRoot .. profile)
    end
  else
    FS:directoryRemove(saveRoot .. profile)
  end
end

local function removeSaveFolder(profile, saveFolderName)
  if not profile or not saveFolderName or saveFolderName == "" then return false end
  if not isLegalDirectoryName(profile) or not isLegalDirectoryName(saveFolderName) then return false end

  local folderPath = saveRoot .. profile .. "/" .. saveFolderName
  if not FS:directoryExists(folderPath) then return false end

  if currentProfile == profile and currentSavePath then
    local currentFolderName = string.match(currentSavePath, "([^/\\]+)$")
    if currentFolderName == saveFolderName then return false end
  end

  FS:directoryRemove(folderPath)
  return true
end

local function renameFolderRec(oldName, newName, oldNameLength)
  local success = true
  local folders = FS:directoryList(oldName, true, true)
  for i = 1, tableSize(folders) do
    if FS:directoryExists(folders[i]) then
      if not renameFolderRec(folders[i], newName, oldNameLength) then
        success = false
      end
    else
      local newPath = string.sub(folders[i], oldNameLength + 2)
      newPath = newName .. newPath
      if FS:renameFile(folders[i], newPath) == -1 then
        success = false
      end
    end
  end
  return success
end

local function renameFolder(oldName, newName)
  local oldNameLength = string.len(oldName)
  if renameFolderRec(oldName, newName, oldNameLength) then
    FS:directoryRemove(oldName)
    return true
  end
end

-- A profile's visible name lives in every save folder's info.json. Folder-only copies and renames otherwise keep showing the source profile's old name.
local function updateProfileDisplayName(profile, displayName)
  local folders = FS:directoryList(saveRoot .. profile, false, true)
  for i = 1, tableSize(folders) do
    local infoPath = folders[i] .. "/info.json"
    local data = jsonReadFile(infoPath)
    if data then
      data.displayName = displayName
      if not jsonWriteFileSafe(infoPath, data, true) then
        log("E", "save", "failed to update profile display name in " .. infoPath)
        return false
      end
    end
  end
  return true
end

local function renameProfile(profile, newName)
  if type(profile) ~= "string" or type(newName) ~= "string" or newName == ""
  or not isLegalDirectoryName(profile) or not isLegalDirectoryName(newName)
  or not FS:directoryExists(saveRoot .. profile)
  or FS:directoryExists(saveRoot .. newName) then
    return false
  end

  local renamed = false
  if currentProfile == profile then
    if not overhaul_career_career.isActive() then
      setProfile(nil)
      renamed = renameFolder(saveRoot .. profile, saveRoot .. newName)
    end
  else
    renamed = renameFolder(saveRoot .. profile, saveRoot .. newName)
  end

  if not renamed then return false end
  return updateProfileDisplayName(newName, newName)
end

local function getCurrentProfile()
  return currentProfile, currentSavePath
end

local function getCurrentDisplayName()
  return currentDisplayName
end

-- Copies every file under src into dst; false at the first file that cannot be copied.
local function copySlotFiles(src, dst, files)
  local sourcePrefix = src:gsub("^/+", ""):gsub("/+$", "") .. "/"
  for i = 1, tableSize(files) do
    local srcPath = files[i]
    if not FS:directoryExists(srcPath) then
      local sourceFile = srcPath:gsub("^/+", "")
      if sourceFile:sub(1, #sourcePrefix) ~= sourcePrefix then return false end
      local dstPath = dst .. "/" .. sourceFile:sub(#sourcePrefix + 1)
      local parentDir = path.split(dstPath)
      if parentDir and parentDir ~= "" and not FS:directoryExists(parentDir) then
        FS:directoryCreate(parentDir, true)
      end
      if FS:copyFile(srcPath, dstPath) ~= 0 then return false end
    end
  end
  return true
end

-- options.sourceSaveReady lets the UI copy after it saw the save finish; the two-argument form saves first.
local function duplicateSaveSlot(slotName, newName, options)
  if not isLegalDirectoryName(slotName) or not isLegalDirectoryName(newName) then
    return false
  end
  if slotName == newName then
    return false
  end
  local src = saveRoot .. slotName
  local dst = saveRoot .. newName
  if not FS:directoryExists(src) or FS:directoryExists(dst) then
    return false
  end

  if currentProfile == slotName and overhaul_career_career.isActive() then
    local sourceSaveReady = type(options) == "table" and options.sourceSaveReady == true
    if not sourceSaveReady then
      M.saveCurrent(nil, {manual = true, force = true})
    end
    -- Saving marks info.json as corrupted until every synchronous/asynchronous save hook finishes. Never copy while that snapshot is still in flight.
    if isSavePending() then
      guihooks.trigger("toastrMsg", {type="info", title="Waiting for career save", msg="Stop the vehicle to finish saving before copying this profile."})
      return false
    end
  end

  local files = FS:findFiles(src .. "/", "*.*", -1, true, true)
  if not files or tableSize(files) == 0 then
    return false
  end

  if not copySlotFiles(src, dst, files) then
    FS:directoryRemove(dst)
    return false
  end

  if not updateProfileDisplayName(newName, newName) then
    FS:directoryRemove(dst)
    return false
  end
  return true
end

local function getAllProfiles()
  local res = {}
  local folders = FS:directoryList(saveRoot, false, true)
  for i = 1, tableSize(folders) do
    local dir, filename, ext = path.split(folders[i])
    table.insert(res, filename)
  end
  return res
end

-- Save lifecycle ---------------------------------------------------------------------------------------

-- Request and queue trace for observation only; nothing reads it back.
local function trace(entry)
  requestSeq = requestSeq + 1
  entry.seq = requestSeq
  requestTrace[#requestTrace + 1] = entry
  if #requestTrace > REQUEST_TRACE_LIMIT then table.remove(requestTrace, 1) end
  return entry
end

local function mergeVehiclesThumbnailUpdate(incoming)
  if type(incoming) ~= "table" then return end
  pendingVehiclesThumbnailUpdate = pendingVehiclesThumbnailUpdate or {}
  for _, inventoryId in ipairs(incoming) do
    if inventoryId and not tableContains(pendingVehiclesThumbnailUpdate, inventoryId) then
      table.insert(pendingVehiclesThumbnailUpdate, inventoryId)
    end
  end
end

local function abortSaveInFlight(reason)
  forgetSavedBlobs()
  reason = saveFailureReason or reason
  log("E", "saveSystem", "Save failed: " .. tostring(reason))
  exitSaveFailed = true
  -- Timed autosaves retry one interval after a failure.
  markAutosaveDone()
  infoData = nil
  saveInProgress = false
  writing = false
  for job in pairs(activeWriters) do job.cancel() end
  activeWriters = {}
  resetQueues()
  table.clear(asyncSaveExtensions)
  queueSave = isCareerActive()
  pendingManualSave = pendingManualSave or inFlightManualSave
  pendingForceSave = pendingForceSave or inFlightForceSave
  pendingSaveName = pendingSaveName or inFlightSaveName
  mergeVehiclesThumbnailUpdate(inFlightVehiclesThumbnailUpdate)
  -- Never restore a complete stamp over partially replaced files.
  if backupReady and backupWasCurrent and saveInFlightProfile == currentProfile then currentSavePath = backupPath end
  guihooks.trigger("toastrMsg", {type="error", label="career-save", title=_tr("ui.career.save.toast.failed.title"), msg=_tr("ui.career.save.toast.failed.msg") .. " " .. tostring(reason), config={timeOut=15000}})
  guihooks.trigger("OverhaulSaveStatus", {state = "idle"})
  lifecycle.finish(saveTransition, "failed", {reason = reason})
  trace({kind = "finish", result = "failed", generation = activeSaveGeneration, reason = tostring(reason)})
  extensions.hook("onOverhaulSaveFailed", oldestSave)
end

-- Commits the info.json stamp and reports the save done; false when the save aborted instead.
local function saveCompleted()
  if not infoData then abortSaveInFlight("capture/write error"); return false end
  local finalizeStarted = clockMs()
  if not saveStampCommitted then
    infoData.corrupted = nil
    infoData.date = saveDate
    writing = true
    local didRun, committed, problem = pcall(jsonWriteFileSafe, oldestSave .. "/info.json", infoData, true)
    writing = false
    if not didRun or not committed then abortSaveInFlight(describeWrite(oldestSave .. "/info.json", "commit") .. "; " .. tostring(didRun and problem or committed)); return false end
    saveStampCommitted = true
    lifecycle.phase(saveTransition, "commit")
    -- The replacement is durable before its recovery copy is retired. Remove
    -- copied files through the same budgeted queue instead of one recursive call.
    if backupPath and FS.directoryRemove and FS:removeFile(backupPath .. "/info.json") == 0 then
      local retired = backupPath
      for _, file in ipairs(backupFiles) do
        enqueueWrite(function() pcall(FS.removeFile, FS, file); return true end)
      end
      enqueueWrite(function() pcall(FS.directoryRemove, FS, retired); return true end)
      backupPath, backupFiles = nil, {}
      return false
    end
  end
  if saveInFlightProfile == currentProfile then currentSavePath = oldestSave end
  exitSaveFailed = false
  markAutosaveDone()
  resetQueues()
  backupPath = nil
  saveInProgress = false
  if saveInFlightProfile == currentProfile then
    lastBlobs, lastBlobSlot = {}, oldestSave
    for rel, entry in pairs(newBlobs) do if entry.size then lastBlobs[rel] = entry end end
  end
  newBlobs = {}
  lastWriteFiles, lastWriteSlot = writeFiles, oldestSave
  lastSaveStats = {captureMs = captureMs, files = fileCount, reused = reusedFiles, writeFrames = writeFrames,
    totalMs = clockMs() - snapshotStarted, snapshotMs = snapshotCopyMs, path = oldestSave}
  log("D", "saveSystem", string.format("save timing capture_ms=%.3f files=%d reused=%d write_frames=%d total_ms=%.3f snapshot_copy_ms=%.3f finalize_ms=%.3f path=%s", captureMs, fileCount, reusedFiles, writeFrames, clockMs() - snapshotStarted, snapshotCopyMs, clockMs() - finalizeStarted, oldestSave))
  guihooks.trigger("OverhaulSaveStatus", {state = queueSave and pendingManualSave and "deferred" or "saved"})
  if pendingSaveSuccessSound and not queueSave then
    pendingSaveSuccessSound = false
    if Engine and Engine.Audio then Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Drift_Combo_5x') end
  end
  lifecycle.finish(saveTransition, "done")
  trace({kind = "finish", result = "done", generation = activeSaveGeneration})
  extensions.hook("onOverhaulSaveFinished")
  return true
end

local function tryFinishSave()
  if not (saveInProgress and captureDepth == 0 and syncSaveExtensionsDone and queuesDone() and tableIsEmpty(asyncSaveExtensions)) then return end
  if saveCompleted() and queueSave and exitFlush then flow.startPending() end
end

local function registerAsyncSaveExtension(extName)
  asyncSaveExtensions[extName] = activeSaveGeneration
  if saveInProgress then lifecycle.phase(saveTransition, "join", {owner = extName}) end
  return activeSaveGeneration
end

local function isAsyncSaveExtensionCurrent(extName, generation)
  return saveInProgress and generation ~= nil and generation == activeSaveGeneration and asyncSaveExtensions[extName] == generation
end

local function asyncSaveExtensionFinished(extName, generation)
  if not isAsyncSaveExtensionCurrent(extName, generation) then return end
  asyncSaveExtensions[extName] = nil
  lifecycle.phase(saveTransition, "joined", {owner = extName})
  tryFinishSave()
end

-- Moves the previous slot's files aside as a recovery copy, so a crash mid-write still leaves a complete save.
local function protectPreviousSave()
  backupPath, backupReady, backupWasCurrent = nil, false, false
  backupFiles = {}
  if not FS:fileExists(oldestSave .. "/info.json") then return end
  local previous = jsonReadFile(oldestSave .. "/info.json")
  if not previous or previous.corrupted then return end
  local function trimSlashes(rawPath) return (tostring(rawPath or ""):gsub("^/+", "")) end
  local isCurrent = currentSavePath ~= nil and trimSlashes(currentSavePath) == trimSlashes(oldestSave)
  -- The target is marked corrupted before it changes, so a newer valid slot already covers a crash.
  if not isCurrent and trimSlashes(getNewestSave(saveRoot .. currentProfile)) ~= trimSlashes(oldestSave) then return end
  -- A suffix is also a legal player save name. Only retire the fresh directory
  -- allocated by this capture; existing recoveries may belong to the player.
  local candidate, suffix = oldestSave .. "_recovery", 1
  while FS:directoryExists(candidate) do
    suffix = suffix + 1
    candidate = oldestSave .. "_recovery_" .. suffix
  end
  backupPath = candidate
  backupWasCurrent = isCurrent
  local target = backupPath
  for _, file in ipairs(FS:findFiles(oldestSave .. "/", "*", -1, false, false)) do
    local relative = file:gsub("^/+", ""):sub(#oldestSave:gsub("^/+", "") + 1)
    if relative ~= "/info.json" then
      backupFiles[#backupFiles + 1] = target .. relative
      enqueueWrite(function()
        local destination = target .. relative
        FS:directoryCreate(destination:match("^(.*)/"), true)
        local code, problem = FS:copyFile(file, destination)
        return code == 0, "copyFile returned " .. tostring(code) .. ": " .. tostring(problem)
      end, target .. relative, nil, "recovery copyFile", file)
    end
  end
  enqueueWrite(function()
    if not jsonWriteFileSafe(target .. "/info.json", previous, true) then return false end
    backupReady = true
    if backupWasCurrent then currentSavePath = target end
    return true
  end, target .. "/info.json", nil, "recovery stamp")
end

-- Starts a save into the next slot, runs the capture hooks, and returns true when the capture finished.
local function saveCurrentActual(vehiclesThumbnailUpdate, saveName, forceSave)
  if not currentProfile then return end
  saveInProgress = true
  saveStampCommitted = false
  saveFailureReason = nil
  saveStartedAt = os.time()
  snapshotStarted, captureMs, writeFrames, fileCount = clockMs(), 0, 0, 0
  snapshotCopyMs, reusedFiles = 0, 0
  newBlobs = {}
  resetQueues()
  writeFiles = {}
  syncSaveExtensionsDone = false
  saveGeneration = saveGeneration + 1
  activeSaveGeneration = saveGeneration
  table.clear(asyncSaveExtensions)
  inFlightSaveName, inFlightForceSave = saveName, forceSave
  inFlightVehiclesThumbnailUpdate = vehiclesThumbnailUpdate
  oldestSave = saveName and (saveRoot .. currentProfile .. "/" .. saveName) or getOldestAutosave(saveRoot .. currentProfile)
  saveInFlightProfile = currentProfile
  saveTransition = lifecycle.begin("save", {profile = currentProfile, path = oldestSave, name = saveName,
    force = forceSave == true, manual = inFlightManualSave == true, exit = exitFlush})
  writeFiles[oldestSave .. "/info.json"], fileCount = true, 1
  saveDate = os.date("!%Y-%m-%dT%H:%M:%SZ")
  creationDateOfCurrentProfile = creationDateOfCurrentProfile or saveDate
  infoData = {version=saveSystemVersion, overhaulSchema=saveSchema.OVERHAUL_SCHEMA, date="0", creationDate=creationDateOfCurrentProfile, displayName=currentDisplayName, corrupted=true}
  infoData.saveSequence = nextSaveSequence(saveRoot .. currentProfile)
  local protected, problem = pcall(protectPreviousSave)
  if not protected then abortSaveInFlight(problem); return end
  local marker = saveJson.snapshot(infoData)
  local function invalidateTarget() return jsonWriteFileSafe(oldestSave .. "/info.json", marker, true) end
  if #writeQueue == 0 then
    writing = true
    local didRun, succeeded = pcall(invalidateTarget)
    writing = false
    if not didRun or not succeeded then abortSaveInFlight("initial info.json failed"); return end
  else
    enqueueWrite(invalidateTarget, oldestSave .. "/info.json", nil, "invalidate slot")
  end
  guihooks.trigger("OverhaulSaveStatus", {state = "saving"})
  local started = clockMs()
  log('D', 'saveSystem', string.format('save prepare_ms=%.3f', started - snapshotStarted))
  log("D", "saveSystem", string.format("save capture at %s stationary_s=%.2f exit=%s", tostring(os.time()), stoppedFor, tostring(exitFlush)))
  lifecycle.phase(saveTransition, "capture")
  captureSaveWrites(function(writer)
    if overhaul_integration_services_statistic then overhaul_integration_services_statistic.ensureCareerReady("saveCurrentActual") end
    extensions.hook("onOverhaulSaveCurrentProfileAsyncStart")
    extensions.hook("onOverhaulSaveCurrentProfile", oldestSave, vehiclesThumbnailUpdate, writer)
  end)
  captureMs = clockMs() - started
  syncSaveExtensionsDone = true
  lifecycle.phase(saveTransition, "captured")
  tryFinishSave()
end

local function tryStartPendingSave()
  if not queueSave or saveInProgress or not currentProfile or not isCareerActive() or exitSaveFailed then return end
  if not pendingManualSave and not autosaveEnabled() then clearQueuedSave(); return end
  if not exitFlush then
    local walking = gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking()
    if be and be:getPlayerVehicle(0) and not walking and stoppedFor < 1 then return end
    if not playerIsStopped() then return end
    if not pendingForceSave and not pendingManualSave and not pendingSaveName and not autosaveIntervalReady() then return end
  end
  if shouldDeferAutosave() then return end
  local name, force, vehicles = pendingSaveName, pendingForceSave, pendingVehiclesThumbnailUpdate
  inFlightManualSave = pendingManualSave
  pendingManualSave, pendingForceSave, queueSave = false, false, false
  pendingSaveName, pendingVehiclesThumbnailUpdate = nil, nil
  trace({kind = "start", saveName = name, force = force == true, manual = inFlightManualSave == true,
    thumbnails = type(vehicles) == "table" and #vehicles or 0, generation = saveGeneration + 1, exit = exitFlush == true})
  saveCurrentActual(vehicles, name, force)
end
flow.startPending = tryStartPendingSave

-- Requests ---------------------------------------------------------------------------------------------

-- (vehiclesThumbnailUpdate, playSuccessSound|{opts}, saveName)
local function queueSaveRequest(vehiclesThumbnailUpdate, arg2, arg3)
  local options = type(arg2) == "table" and arg2 or {}
  local name = options.saveName or arg3
  local manual = options.manual == true or options.playSuccessSound == true or arg2 == true
  if not currentProfile or (not manual and not autosaveEnabled()) then return false end
  if name and (type(name) ~= "string" or name == "" or name == "." or name == ".." or not isLegalDirectoryName(name)) then return false end
  mergeVehiclesThumbnailUpdate(options.vehiclesThumbnailUpdate or vehiclesThumbnailUpdate)
  pendingManualSave = pendingManualSave or manual
  pendingForceSave = pendingForceSave or options.force == true
  pendingSaveName = name or pendingSaveName
  pendingSaveSuccessSound = pendingSaveSuccessSound or options.playSuccessSound == true or arg2 == true
  queueSave = true
  exitSaveFailed = false
  if manual and not playerIsStopped() then
    stoppedFor = 0
    if not saveInProgress then guihooks.trigger("OverhaulSaveStatus", {state = "deferred"}) end
    log("D", "saveSystem", "save deferred while moving at " .. tostring(os.time()))
  end
  -- A request always joins the same queue; a safe explicit request may start now.
  if manual or options.force or name then tryStartPendingSave() end
  return true
end

local function saveCurrent(vehiclesThumbnailUpdate, arg2, arg3)
  local options = type(arg2) == "table" and arg2 or {}
  local reason = requestReason
  requestReason = nil
  local entry = trace({kind = "request", reason = reason,
    manual = options.manual == true or options.playSuccessSound == true or arg2 == true, force = options.force == true,
    saveName = options.saveName or arg3,
    state = captureDepth > 0 and "capture" or saveInProgress and "inFlight" or queueSave and "queued" or "idle"})
  local accepted = queueSaveRequest(vehiclesThumbnailUpdate, arg2, arg3)
  entry.accepted = accepted
  return accepted
end

-- The SaveStore request facade's entry: the same request, with its reason.
local function requestSave(reason, ...)
  requestReason = type(reason) == "string" and reason or nil
  return saveCurrent(...)
end

-- Write pump -------------------------------------------------------------------------------------------

-- Runs queued work until the frame budget is spent; returns false after aborting a failed save.
local function runWrites(maxMs, maxOps)
  local started, count = clockMs(), 0
  writing = true
  while count < (maxOps or WRITE_OPS_CAP) do
    local priority = priorityIndex <= #priorityQueue
    local operation = priority and priorityQueue[priorityIndex] or writeQueue[writeIndex]
    if not operation then break end
    local ran, result, problem = pcall(operation, math.max(0.1, maxMs - (clockMs() - started)))
    if priority then priorityQueue[priorityIndex] = false; priorityIndex = priorityIndex + 1
    elseif result ~= 'pending' then writeQueue[writeIndex] = false; writeIndex = writeIndex + 1 end
    count = count + 1
    if not ran or result == false or not infoData then
      writing = false
      abortSaveInFlight("file write failed: " .. (writeDetails[operation] or describeWrite(nil, priority and "priority callback" or "callback"))
        .. "; " .. (ran and ("returned " .. tostring(result) .. ": " .. tostring(problem)) or tostring(result)))
      return false
    end
    if clockMs() - started >= maxMs then break end
  end
  writing = false
  return true, count, started
end

local function pumpSaveWrites()
  writeFrames = writeFrames + 1
  frameEncodeMs, frameIoMs = 0, 0
  local drained, count, started = runWrites((exitFlush or pendingExit) and EXIT_WRITE_BUDGET_MS or WRITE_BUDGET_MS)
  if not drained then return false end
  if timingLog then
    log('D', 'saveSystem', string.format('save frame work_ms=%.3f encode_ms=%.3f write_ms=%.3f operations=%d remaining=%d', clockMs() - started, frameEncodeMs, frameIoMs, count, #writeQueue - writeIndex + 1))
  end
  return true
end

-- Finishes a captured save in this frame; used when Lua is torn down before onUpdate can.
local function finishSaveNow(maxSaves)
  if not saveInProgress then return false end
  if not infoData or captureDepth > 0 or not syncSaveExtensionsDone or not tableIsEmpty(asyncSaveExtensions) then
    local waiting = {}
    for name in pairs(asyncSaveExtensions) do waiting[#waiting + 1] = name end
    log("W", "saveSystem", "save left unfinished by Lua reload; waiting on: " .. table.concat(waiting, ", "))
    return false
  end
  -- Each overwrite may need a second drain for recovery retirement. Pre-exit
  -- also has one coalesced fresh snapshot to finish, with no later frame.
  for _ = 1, 2 * (maxSaves or 1) do
    if not infoData or captureDepth > 0 or not syncSaveExtensionsDone or not tableIsEmpty(asyncSaveExtensions) then return false end
    if not runWrites(10000, math.huge) then return false end
    if not queuesDone() then abortSaveInFlight("write did not finish before Lua reload"); return false end
    tryFinishSave()
    if not saveInProgress then break end
  end
  return not saveInProgress
end

-- Update -----------------------------------------------------------------------------------------------

local function onUpdate(dt, dtSim)
  stopSampleElapsed = stopSampleElapsed + math.max(0, dt or 0)
  if queueSave or stopSampleElapsed >= STOP_SAMPLE_INTERVAL then
    if playerIsStopped() then stoppedFor = stoppedFor + stopSampleElapsed else stoppedFor = 0 end
    stopSampleElapsed = 0
  end
  if saveInProgress and (os.time() - saveStartedAt) >= SAVE_IN_FLIGHT_TIMEOUT_S then
    abortSaveInFlight("timed out after " .. tostring(SAVE_IN_FLIGHT_TIMEOUT_S) .. "s")
    return
  end
  if saveInProgress then
    if not infoData then abortSaveInFlight("asynchronous capture failed"); return end
    if not queuesDone() and not pumpSaveWrites() then return end
    tryFinishSave()
  end
  if pendingExit and not isSavePending() and not exitSaveFailed then
    local finish = pendingExit
    pendingExit, exitFlush = nil, false
    finish()
    return
  end
  if exitSaveFailed and not exitFlush and not pendingExit and not saveInProgress and autosaveIntervalReady() then exitSaveFailed = false end
  if not queueSave and not saveInProgress and currentProfile and isCareerActive() and autosaveEnabled() and autosaveIntervalReady() and not exitFlush then queueSave = true end
  tryStartPendingSave()
end

-- Exit and reload -------------------------------------------------------------------------------------

-- Exits and repeated Ctrl+L requests join the save; stalled reloads have a timed escape (lib/lifecycle/transitions.lua).
local function flushSaveForExit(callback, captureFresh)
  -- Work owners settle completed earnings while their payment providers and
  -- the career are still active, then the exit drains any permitted save.
  -- Autosave off still requires a manual save; settlement alone does not checkpoint progress.
  if isCareerActive() and currentProfile then extensions.hook("onOverhaulBeforeSaveExit") end
  if not isCareerActive() or not currentProfile then
    clearQueuedSave()
    if callback then callback() end
    return true
  end
  if callback then pendingExit = callback end
  local firstFlush = not exitFlush
  exitFlush = true
  exitSaveFailed = false
  if not autosaveEnabled() and queueSave and not pendingManualSave then clearQueuedSave() end
  -- Capture unqueued mutations too. If a snapshot is already in flight, the
  -- follow-up captures changes since it began. Repeated exit hooks only join.
  if firstFlush and captureFresh ~= false and autosaveEnabled() then
    queueSave = true
    pendingForceSave = true
  end
  tryStartPendingSave()
  if not callback and isSavePending() and not finishSaveNow(2) then return false end
  if not isSavePending() then
    local finish = pendingExit
    pendingExit, exitFlush = nil, false
    if finish then finish() end
    return true
  end
  if callback then
    guihooks.trigger('toastrMsg', {type='info', title='Waiting for career save', msg='Finishing the current transaction and save before continuing.'})
  end
  return false
end

local exitContinuations = {flushSaveForExit = flushSaveForExit}
local reload = transitions.newReload({
  cancelPendingExit = function() pendingExit, exitFlush = nil, false end,
  shouldSaveBeforeReload = function() return isCareerActive() and currentProfile and autosaveEnabled() and not saveInProgress end,
  saveCurrent = saveCurrent,
  -- Reload requests its fresh snapshot before flushing; do not queue another.
  flushSaveForExit = function(callback) return flushSaveForExit(callback, false) end,
}, _G)

local function onExtensionLoaded()
  transitions.registerExitPatches(exitContinuations, _G)
end

local function onExtensionUnloaded()
  transitions.unregisterExitPatches(_G)
end

local function onPreExit()
  transitions.preExit(exitContinuations)
end

local function requestLuaReload()
  return reload.request()
end

local function onOverhaulActive(active)
  if not active then guihooks.trigger("OverhaulSaveStatus", {state = "idle"}) end
  if not active then forgetSavedBlobs(); saveStore.releaseHolds() end
  if active then onExtensionLoaded(); return end
  pendingExit = nil
  reload.reset()
  exitFlush = false
  stoppedFor = 0
  -- Deactivation unloads career modules before queued saves can run.
  if not saveInProgress then
    clearQueuedSave()
  end
end

local function onSerialize()
  finishSaveNow()
  local data = {}
  data.currentProfile = currentProfile
  data.currentSavePath = currentSavePath
  data.currentDisplayName = currentDisplayName
  data.creationDateOfCurrentProfile = creationDateOfCurrentProfile
  return data
end

local function onDeserialized(v)
  forgetSavedBlobs()
  currentProfile = v.currentProfile or v.currentSaveSlot
  currentSavePath = v.currentSavePath
  currentDisplayName = v.currentDisplayName or currentProfile
  creationDateOfCurrentProfile = v.creationDateOfCurrentProfile or v.creationDateOfCurrentSaveSlot
  lastAutosaveAt = os.time()
end

-- Which files the last completed save wrote, by SaveStore key (slot-relative paths), computed on demand.
local function getSaveKeyCoverage()
  local keyed, unkeyed = {}, {}
  if not lastWriteFiles or not lastWriteSlot then return {keyed = keyed, unkeyed = unkeyed} end
  local slot = tostring(lastWriteSlot):gsub("\\", "/"):gsub("^/+", "") .. "/"
  for file in pairs(lastWriteFiles) do
    local normalized = tostring(file):gsub("\\", "/"):gsub("^/+", "")
    if normalized:sub(1, #slot) == slot then
      local rel = normalized:sub(#slot + 1)
      local key = saveStore.keyForFile(rel)
      if key then keyed[rel] = key.key else unkeyed[#unkeyed + 1] = rel end
    end
  end
  table.sort(unkeyed)
  return {keyed = keyed, unkeyed = unkeyed}
end

local function copyRequestTrace()
  local out = {}
  for i, entry in ipairs(requestTrace) do
    local copy = {}
    for k, v in pairs(entry) do copy[k] = v end
    out[i] = copy
  end
  return out
end

-- Public API -------------------------------------------------------------------------------------------

M.setProfile = setProfile
M.removeProfile = removeProfile
M.removeSaveFolder = removeSaveFolder
M.renameProfile = renameProfile
M.duplicateSaveSlot = duplicateSaveSlot
M.getCurrentProfile = getCurrentProfile
M.getCurrentDisplayName = getCurrentDisplayName
M.getPauseCardSummary = function()
  return {kind = 'profile', label = 'Career', value = getCurrentDisplayName() or getCurrentProfile()}
end
M.saveCurrent = saveCurrent
M.requestSave = requestSave
M.getRequestTrace = copyRequestTrace
M.clearRequestTrace = function() requestTrace = {} end
M.getSaveKeyCoverage = getSaveKeyCoverage
M.isSaveBusy = isSaveBusy
M.isSavePending = isSavePending
M.flushSaveForExit = flushSaveForExit
M.requestLuaReload = requestLuaReload
M.onOverhaulActive = onOverhaulActive
M.getAllProfiles = getAllProfiles
M.getSaveRootDirectory = function() return saveRoot end
M.getNewestSave = getNewestSave
M.getAllSaveFolders = getAllSaveFolders
M.getSaveSystemVersion = function() return saveSystemVersion end
M.getBackwardsCompVersion = function() return backwardsCompVersion end
M.saveFailed = saveFailed
M.registerAsyncSaveExtension = registerAsyncSaveExtension
M.isAsyncSaveExtensionCurrent = isAsyncSaveExtensionCurrent
M.asyncSaveExtensionFinished = asyncSaveExtensionFinished
M.jsonWriteFileSafe = jsonWriteFileSafe
M.captureSaveWrites = captureSaveWrites
M.withFeatureWrites = function(required, callback, ...) return featureWrites.scope(required, callback, ...) end
M.getSaveWriter = getSaveWriter
-- `priority` work only starts or finishes async steps; it runs ahead of queued encoding.
M.deferSaveWork = function(callback, filename, priority)
  if saveInProgress then
    if priority then
      local description = describeWrite(filename, "priority callback")
      local operation = featureWrites.wrap(function() callback(); return true end, filename, nil, description)
      writeDetails[operation] = description
      priorityQueue[#priorityQueue + 1] = operation
      return true
    end
    return enqueueWrite(function(budgetMs) callback(budgetMs); return true end, filename, nil, "deferred callback")
  end
  callback()
  return true
end
M.setTimingLog = function(enabled) timingLog = enabled == true end
M.getLastSaveStats = function() return lastSaveStats end
M.onUpdate = onUpdate

-- Older callers retain their save-slot entry points across the profile API naming change.
M.setSaveSlot = setProfile
M.removeSaveSlot = removeProfile
M.renameSaveSlot = renameProfile
M.getCurrentSaveSlot = getCurrentProfile
M.getAllSaveSlots = getAllProfiles
M.getAllAutosaves = getAllSaveFolders

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onPreExit = onPreExit
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
