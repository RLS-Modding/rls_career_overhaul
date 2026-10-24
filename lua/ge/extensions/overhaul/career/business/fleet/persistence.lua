-- Fleet save adapter: capture live conditions before writing detached business records.
-- The save join owns its replies until completion, cancellation or a bounded timeout.
local part = {}

function part.new(inputs)
  local saveState = require('overhaul/lib/business/saveState')
  local SAVE_EXTENSION = 'businessFleet'
  local CONDITIONS_TIMEOUT_SECONDS = 3
  local fleetState = inputs.fleetState
  local pendingSave

  local function isCurrent(task)
    return pendingSave == task and fleetState.businessVehicles == task.records
      and task.profile == overhaul_career_saveSystem.getCurrentProfile()
      and overhaul_career_career.isActive()
      and (not task.generation or overhaul_career_saveSystem.isAsyncSaveExtensionCurrent(SAVE_EXTENSION, task.generation))
  end

  local function release(task)
    if pendingSave == task then pendingSave = nil end
    if task.generation then
      overhaul_career_saveSystem.asyncSaveExtensionFinished(SAVE_EXTENSION, task.generation)
    end
  end

  local function writeSnapshot(task, writer)
    if not isCurrent(task) then return end
    for businessId, vehicles in pairs(task.snapshot) do
      local path = saveState.businessFilePath(businessId, 'vehicles.json', task.path)
      local directory = path:match('^(.*)/[^/]+$')
      if not writer.exists(directory) then writer.mkdir(directory) end
      overhaul_career_saveSystem.jsonWriteFileSafe(path, {vehicles = vehicles}, true)
    end
    saveState.clearUnownedFiles(task.path, {'vehicles.json'}, nil, writer)
  end

  local function finish(task)
    if not isCurrent(task) then return release(task) end
    if task.generation then
      overhaul_career_saveSystem.captureSaveWrites(function(writer) writeSnapshot(task, writer) end)
    else
      writeSnapshot(task, task.writer)
    end
    release(task)
  end

  local function cancel()
    if pendingSave then release(pendingSave) end
  end

  local function loadOwnedFleets()
    for _, ids in pairs(overhaul_career_business_manager.getAllPurchasedBusinesses() or {}) do
      if type(ids) == 'table' then
        for businessId, owned in pairs(ids) do
          local id = owned and inputs.normalizeBusinessId(businessId)
          if id and not fleetState.businessVehicles[id] then
            local path = saveState.businessFilePath(id, 'vehicles.json')
            if path and FS:fileExists(path) then inputs.loadBusinessVehicles(id) end
          end
        end
      end
    end
  end

  local function requestsFor(task)
    local requests = {}
    for businessId, vehicles in pairs(task.records) do
      for index, stored in ipairs(vehicles) do
        local spawnedId = inputs.getSpawnedVehicleId(businessId, stored.vehicleId)
        local object = spawnedId and getObjectByID(spawnedId)
        if object then
          requests[#requests + 1] = {businessId = businessId, stored = stored, spawnedId = spawnedId,
            object = object, snapshot = task.snapshot[businessId][index]}
        end
      end
    end
    return requests
  end

  local function captureReply(task, request, response)
    if request.finished or not isCurrent(task) then return end
    request.finished = true
    local stored = request.stored
    if inputs.getVehicleById(request.businessId, stored.vehicleId) == stored
      and inputs.getSpawnedVehicleId(request.businessId, stored.vehicleId) == request.spawnedId
      and getObjectByID(request.spawnedId) == request.object
      and response and type(response.result) == 'table' then
      request.snapshot.partConditions = deepcopy(response.result)
      stored.partConditions = deepcopy(response.result)
    end
    task.remaining = task.remaining - 1
    if task.remaining == 0 then finish(task) end
  end

  local function save(currentSavePath, _, writer)
    cancel()
    if not currentSavePath then return end
    loadOwnedFleets()
    local task = {path = currentSavePath, writer = writer or overhaul_career_saveSystem.getSaveWriter(),
      profile = overhaul_career_saveSystem.getCurrentProfile(), records = fleetState.businessVehicles,
      snapshot = deepcopy(fleetState.businessVehicles), elapsed = 0}
    pendingSave = task
    local requests = requestsFor(task)
    task.remaining = #requests
    if #requests == 0 then return finish(task) end
    task.generation = overhaul_career_saveSystem.registerAsyncSaveExtension(SAVE_EXTENSION)
    for _, request in ipairs(requests) do
      core_vehicleBridge.requestValue(request.object, function(response)
        captureReply(task, request, response)
      end, 'getPartConditions')
    end
  end

  local function onUpdate(dtReal)
    local task = pendingSave
    if not task then return end
    if not isCurrent(task) then return release(task) end
    task.elapsed = task.elapsed + math.max(0, dtReal or 0)
    if task.elapsed >= CONDITIONS_TIMEOUT_SECONDS then
      log('W', 'businessFleet', 'Fleet conditions timed out; saving last known conditions for missing replies')
      finish(task)
    end
  end

  return {save = save, onUpdate = onUpdate, cancel = cancel}
end

return part
