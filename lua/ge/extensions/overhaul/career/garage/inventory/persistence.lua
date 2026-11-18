-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Inventory persistence owns condition snapshots, thumbnail work and save writes.
-- Read in order: thumbnails, listings, condition batches, save tasks, vehicle files and inventory capture.
local persistence = {}
local capabilities = require("overhaul/lib/platform/capabilities")
local consignment = require('overhaul/career/market/auction/consignment')
local auctionConstants = require('overhaul/career/market/auction/constants')

local VEHICLE_THUMBNAIL_WIDTH = 500
local VEHICLE_THUMBNAIL_HEIGHT = 281
local VEHICLE_THUMBNAIL_FOV_DEGREES = 50
local VEHICLE_THUMBNAIL_NEAR_PLANE_METERS = 0.1

-- A dedicated render view leaves the player's UI, camera and graphics settings alone.
function persistence.captureThumbnail(filename, camera, callback)
  require('overhaul/career/garage/inventory/thumbnail').capture(filename, camera, callback)
end

function persistence.new(inputs)
  -- Requests reserve capacity before the engine returns the spawned car's conditions.
  -- Tokens live only in this inventory instance, never in a vehicle's save record.
  local pendingListings = {}

  -- Dirty marks and auction listings --------------------------------------------------------------

  local function updateVehicleThumbnail(inventoryId, filename, callback)
    local vehId = inputs.M.getVehicleIdFromInventoryId(inventoryId)
    local vehObj = vehId and getObjectByID(vehId)
    if not vehObj then
      if callback then callback(false) end
      return
    end

    local data = core_vehicle_manager.getVehicleData(vehId)
    local record = inputs.vehicles[inventoryId]
    local configKey = require('overhaul/career/garage/inventory/thumbnail').configKey(data and data.config or record and record.config)
    local resolution = vec3(VEHICLE_THUMBNAIL_WIDTH, VEHICLE_THUMBNAIL_HEIGHT, 0)
    local cameraPosition, cameraRotation = extensions.util_screenshotCreator.frameVehicle(
      vehObj, VEHICLE_THUMBNAIL_FOV_DEGREES, VEHICLE_THUMBNAIL_NEAR_PLANE_METERS,
      resolution.x / resolution.y, {resolution.x, resolution.y})
    persistence.captureThumbnail(filename, {
      pos = cameraPosition,
      rot = cameraRotation,
      fov = VEHICLE_THUMBNAIL_FOV_DEGREES,
      nearPlane = VEHICLE_THUMBNAIL_NEAR_PLANE_METERS,
      width = VEHICLE_THUMBNAIL_WIDTH,
      height = VEHICLE_THUMBNAIL_HEIGHT,
      screenshotDelay = 0.5
    }, function(success) if callback then callback(success and getObjectByID(vehId) ~= nil, configKey) end end)
  end

  local function setVehicleDirty(inventoryId)
    inputs.dirtiedVehicles[inventoryId] = true
  end

  local function isVehicleListedForAuction(inventoryId)
    local vehicle = inputs.vehicles[inventoryId]
    return vehicle and vehicle.listedForAuction == true
  end

  local function getListedVehicleIds()
    local ids = {}
    for inventoryId, vehicle in pairs(inputs.vehicles) do
      if vehicle.listedForAuction == true then ids[#ids + 1] = inventoryId end
    end
    table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
    return ids
  end

  local function getListedVehicleId()
    return getListedVehicleIds()[1]
  end

  local function isAuctionListingPending(inventoryId)
    return pendingListings[inventoryId] ~= nil
  end

  local function cancelPendingAuctionListings()
    pendingListings = {}
  end

  -- Why a car can't be listed at auction, or nil when it can. The auction counter shows the reason on
  -- the disabled button; listing itself goes through canListAtAuction, so both read this one rule.
  local function auctionListingBlockReason(inventoryId)
    local vehicle = inputs.vehicles[inventoryId]
    local reason = consignment.saleBlockReason(inventoryId, vehicle)
    if reason then return reason end
    if inputs.M.isDamageRestorePending and inputs.M.isDamageRestorePending(inventoryId) then return 'Vehicle is still loading' end
    if overhaul_career_repair_insurance.inventoryVehNeedsRepair(inventoryId) then return "Needs repair" end
    if not vehicle.listedForAuction and not pendingListings[inventoryId] then
      local count = #getListedVehicleIds()
      for id in pairs(pendingListings) do
        if not inputs.vehicles[id] or not inputs.vehicles[id].listedForAuction then count = count + 1 end
      end
      local limit = auctionConstants.MAX_CONSIGNMENT_LISTINGS
      if limit > 0 and count >= limit then return 'Listing limit reached' end
    end
    return nil
  end

  local LISTING_REFUSAL_MESSAGES = {
    ["Needs repair"] = "Repair this vehicle before listing it at auction.",
    ["Not in storage"] = "This vehicle can't be listed at auction until it is back in your storage.",
    ["Loaned car"] = "This vehicle can't be listed at auction until it is back in your storage.",
    ["In use for a delivery"] = "Unload or transfer this vehicle's cargo before listing it at auction.",
    ["Listing limit reached"] = "Unlist a vehicle or finish its auction before listing another.",
  }

  local function canListAtAuction(inventoryId)
    local reason = auctionListingBlockReason(inventoryId)
    if reason and LISTING_REFUSAL_MESSAGES[reason] then
      ui_message(LISTING_REFUSAL_MESSAGES[reason], nil, "vehicleInventory")
    end
    return reason == nil
  end

  local function setVehicleListedForAuction(inventoryId, listed, onComplete)
    local vehicle = inputs.vehicles[inventoryId]
    if not vehicle or not vehicle.owned then return false end
    if not listed then
      pendingListings[inventoryId] = nil
      vehicle.listedForAuction = nil
    else
      if vehicle.listedForAuction then return true end
      if pendingListings[inventoryId] then return false end
      if not canListAtAuction(inventoryId) then return false end
      -- A spawned car is listed once its latest conditions are in and it has left the world.
      if inputs.inventoryIdToVehId[inventoryId] then
        local request = {}
        local spawnedId = inputs.inventoryIdToVehId[inventoryId]
        pendingListings[inventoryId] = request
        local function fail()
          if pendingListings[inventoryId] ~= request then return end
          pendingListings[inventoryId] = nil
          ui_message('The vehicle could not be prepared for auction. Please try again.', nil, 'vehicleInventory')
        end
        local function isCurrent()
          return pendingListings[inventoryId] == request and inputs.vehicles[inventoryId] == vehicle
            and inputs.inventoryIdToVehId[inventoryId] == spawnedId
        end
        local function finish(ok)
          if not isCurrent() then return end
          if not ok or not canListAtAuction(inventoryId) then fail(); return end
          -- The damage snapshot is complete. Delete directly so storage cannot start a second,
          -- unobserved capture and report success before the original car has actually left.
          local removed = pcall(inputs.M.removeVehicleObject, inventoryId, true)
          if not removed then fail(); return end
          pendingListings[inventoryId] = nil
          vehicle.listedForAuction = true
          setVehicleDirty(inventoryId)
          if onComplete then onComplete() end
        end
        local function conditionsReady()
          if not isCurrent() then return end
          if not canListAtAuction(inventoryId) then fail(); return end
          local ok, started = pcall(overhaul_career_repair_damageManager.captureDamageState, inventoryId, finish)
          if not ok or started == false then fail() end
        end
        local ok = pcall(inputs.M.updatePartConditions, nil, inventoryId, conditionsReady)
        if not ok then
          fail()
          return false
        end
        -- A lost vehicle callback must release its reserved listing slot.
        core_jobsystem.create(function(job)
          job.sleep(5)
          if pendingListings[inventoryId] == request then
            pendingListings[inventoryId] = nil
            ui_message('Auction listing timed out. Please try again.', nil, 'vehicleInventory')
          end
        end)
        return vehicle.listedForAuction == true
      end
      vehicle.listedForAuction = true
    end
    setVehicleDirty(inventoryId)
    return true
  end

  local function clearVehicleAuctionListing(inventoryId)
    pendingListings[inventoryId] = nil
    local vehicle = inputs.vehicles[inventoryId]
    if vehicle then
      vehicle.listedForAuction = nil
      setVehicleDirty(inventoryId)
    end
  end

  -- Part condition batches ------------------------------------------------------------------------

  local partConditionBatches = {
    nextToken = 0,
    cancelled = {},
    deferred = {},
    begin = function(self, deferResponses)
      self.nextToken = self.nextToken + 1
      self.deferred[self.nextToken] = deferResponses or nil
      return self.nextToken
    end,
    cancel = function(self, batchToken)
      if batchToken then
        self.cancelled[batchToken] = true
        self.deferred[batchToken] = nil
      end
    end,
    isLive = function(self, batchToken)
      if batchToken == nil then return true end
      return self.cancelled[batchToken] ~= true
    end,
  }

  local SAVE_PART_CONDITIONS_TIMEOUT_S = 3

  -- A save timeout keeps the last conditions and consumes the same once-only completion.
  local function schedulePartConditionTimeout(batchToken, inventoryId, isFinished, finished)
    core_jobsystem.create(function(job)
      job.sleep(SAVE_PART_CONDITIONS_TIMEOUT_S)
      if not isFinished() and partConditionBatches:isLive(batchToken) then
        log("W", "inventory", "part conditions of inventory vehicle " .. tostring(inventoryId) .. " did not arrive in time; saving its last known conditions")
        finished()
      end
    end)
  end

  -- onlyInventoryIds (keys tostring(inventoryId)) limits the requests to those cars.
  local function updatePartConditionsOfSpawnedVehicles(callback, onVehicleFinished, deferRequests, onlyInventoryIds)
    local batchToken
    if callback then
      batchToken = partConditionBatches:begin(deferRequests)
    end
    local requests = {}
    for vehId, inventoryId in pairs(inputs.vehIdToInventoryId) do
      if not onlyInventoryIds or onlyInventoryIds[tostring(inventoryId)] then
        requests[#requests + 1] = {vehId = vehId, inventoryId = inventoryId}
      end
    end
    local expectedResponseCount = #requests
    local completedResponseCount = 0
    local function finishIfAllResponsesCompleted()
      if callback and completedResponseCount >= expectedResponseCount then
        callback()
      end
    end
    local function requestVehicle(request)
      if not partConditionBatches:isLive(batchToken) then return end
      local vehId, inventoryId = request.vehId, request.inventoryId
      setVehicleDirty(inventoryId)
      local hasFinished = false
      local function finished()
        if hasFinished or not partConditionBatches:isLive(batchToken) then return end
        hasFinished = true
        if onVehicleFinished then onVehicleFinished(inventoryId) end
        completedResponseCount = completedResponseCount + 1
        finishIfAllResponsesCompleted()
      end
      if deferRequests then
        schedulePartConditionTimeout(batchToken, inventoryId, function() return hasFinished end, finished)
      end
      if inputs.M.isTransientBuild(inventoryId) then
        finished()
      else
        inputs.M.updatePartConditions(vehId, inventoryId, (callback or deferRequests) and finished, batchToken)
      end
    end
    if deferRequests then
      -- Every car is asked at once, after the capture frame and ahead of queued encoding.
      for _, request in ipairs(requests) do
        overhaul_career_saveSystem.deferSaveWork(function() requestVehicle(request) end, nil, true)
      end
    else
      deferRequests = false
      for _, request in ipairs(requests) do requestVehicle(request) end
    end
    if callback and expectedResponseCount == 0 then
      callback()
    end
    return batchToken
  end

  -- Entry waits only for the car being left; full saves still capture every spawned car.
  local function updatePartConditionsOfCurrentVehicle(callback)
    local inventoryId = inputs.state.currentVehicle
    if not inventoryId then
      if callback then callback() end
      return
    end
    setVehicleDirty(inventoryId)
    inputs.M.updatePartConditions(inputs.inventoryIdToVehId[inventoryId], inventoryId, callback)
  end

  -- Save tasks ------------------------------------------------------------------------------------

  local extensionName = "inventory"
  local finishedSaveTasks = {}

  local function inventorySaveFinished(currentSavePath, generation)
    if not overhaul_career_saveSystem.isAsyncSaveExtensionCurrent(extensionName, generation) then return end
    -- Async steps that wait for the vehicle save must call registerAsyncSaveExtension inside their onOverhaulVehicleSaveFinished first.
    extensions.hook("onOverhaulVehicleSaveFinished", currentSavePath)
    overhaul_career_saveSystem.asyncSaveExtensionFinished(extensionName, generation)
    guihooks.trigger("saveFinished")
  end

  local function onOverhaulSaveCurrentProfileAsyncStart()
    partConditionBatches:cancel(finishedSaveTasks.partConditionsBatch)
    finishedSaveTasks = {
      generation = overhaul_career_saveSystem.registerAsyncSaveExtension(extensionName)
    }
  end

  local function checkSaveFinished(currentSavePath, task)
    task = task or finishedSaveTasks
    for key, isFinished in pairs(task) do
      if key ~= "generation" and key ~= "partConditionsBatch" and key ~= "liveCapture" and not isFinished then return end
    end
    if task.diff and not task.diff.complete then
      task.diff.complete = true
      log('D', 'inventory', string.format('save timing vehicle_records=%d copied_unchanged=%d', tableSize(task.diff.keys), task.diff.copied))
    end
    inventorySaveFinished(currentSavePath, task.generation)
  end

  -- Thumbnail captures ----------------------------------------------------------------------------

  -- A shared worker prevents overlapping autosaves from reusing the same thumbnail render view.
  local thumbnailCaptureQueue = {}
  local thumbnailCaptureBusy = false
  local thumbnailCaptureJobs = {}

  local function forgetThumbnailJob(job)
    if thumbnailCaptureJobs[job.filename] == job then thumbnailCaptureJobs[job.filename] = nil end
  end

  local function pumpThumbnailCaptures()
    if thumbnailCaptureBusy then return end
    local job = table.remove(thumbnailCaptureQueue, 1)
    if not job then return end
    if job.isCurrent and not job.isCurrent() then
      forgetThumbnailJob(job)
      pumpThumbnailCaptures()
      return
    end
    thumbnailCaptureBusy = true
    updateVehicleThumbnail(job.id, job.filename, function(success, configKey)
      thumbnailCaptureBusy = false
      forgetThumbnailJob(job)
      for _, callback in ipairs(job.callbacks) do callback(success, configKey) end
    end)
  end

  local function enqueueThumbnailCapture(inventoryId, filename, onComplete, isCurrent)
    local job = thumbnailCaptureJobs[filename]
    if job and job.id == inventoryId and (not job.isCurrent or job.isCurrent()) then
      if onComplete then job.callbacks[#job.callbacks + 1] = onComplete end
      return
    end
    job = {id = inventoryId, filename = filename, callbacks = {}, isCurrent = isCurrent}
    if onComplete then job.callbacks[1] = onComplete end
    thumbnailCaptureJobs[filename] = job
    table.insert(thumbnailCaptureQueue, job)
  end

  -- UI screens that show live vehicles get one real thumbnail attempt per session, so a failure cannot loop.
  -- A refresh (after a purchase changed the car) always renders; a transaction save keeps the old file meanwhile.
  local onDemandThumbnailRequested = {}
  local function renderSlotThumbnail(inventoryId, onComplete, refresh)
    local vehicle = inputs.vehicles[inventoryId]
    local vehId = inputs.inventoryIdToVehId[inventoryId]
    if not vehicle or not vehId then return false end
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if not savePath then return false end
    local dir = savePath .. "/career/vehicles"
    local filename = dir .. "/" .. inventoryId .. ".jpg"
    if not refresh then
      if onDemandThumbnailRequested[inventoryId] then return false end
      if not vehicle.defaultThumbnail and vehicle.thumbnailConfig ~= nil and FS:fileExists(filename) then
        local data = core_vehicle_manager.getVehicleData(vehId)
        local key = require('overhaul/career/garage/inventory/thumbnail').configKey(data and data.config or vehicle.config)
        if vehicle.thumbnailConfig == key then return false end
      end
      onDemandThumbnailRequested[inventoryId] = true
    end
    if not FS:directoryExists(dir) then FS:directoryCreate(dir) end
    local function isCurrent()
      local _, currentPath = overhaul_career_saveSystem.getCurrentProfile()
      return currentPath == savePath and inputs.vehicles[inventoryId] == vehicle and inputs.inventoryIdToVehId[inventoryId] == vehId
    end
    enqueueThumbnailCapture(inventoryId, filename, function(success, configKey)
      if success and isCurrent() and FS:fileExists(filename) then
        vehicle.defaultThumbnail = nil
        vehicle.thumbnailConfig = configKey
        vehicle.dirtyDate = require('overhaul/career/garage/inventory/thumbnail').nextDirtyDate(vehicle.dirtyDate, os.date("!%Y-%m-%dT%H:%M:%SZ"))
        setVehicleDirty(inventoryId)
      end
      if onComplete then pcall(onComplete) end
    end, isCurrent)
    return true
  end

  local function ensureVehicleThumbnail(inventoryId, onComplete)
    return renderSlotThumbnail(inventoryId, onComplete, false)
  end

  local function refreshVehicleThumbnail(inventoryId)
    return renderSlotThumbnail(inventoryId, nil, true)
  end

  -- Vehicle files ---------------------------------------------------------------------------------

  local function isPersonalInventoryId(inventoryId)
    if type(inventoryId) == "number" then return true end
    return type(inventoryId) == "string" and tonumber(inventoryId) ~= nil
  end

  local function prepareVehicleSave(inventoryId, vehicle, task, currentDate)
    local session = capabilities.peek("businessSession")
    local dynoSaveOverride = task.dynoOverrides and task.dynoOverrides[inventoryId] or (not task.vehiclesSnapshot and session and
      session.getInventorySaveOverride and
      session.getInventorySaveOverride(inventoryId)) or nil
    if dynoSaveOverride then
      vehicle.config = dynoSaveOverride.config
      vehicle.partConditions = dynoSaveOverride.partConditions
    end

    if (task.dirtiedSnapshot or inputs.dirtiedVehicles)[inventoryId] or not vehicle.dirtyDate then
      local dirtyDate = require('overhaul/career/garage/inventory/thumbnail').nextDirtyDate(vehicle.dirtyDate, currentDate)
      if inputs.vehicles[inventoryId] then inputs.vehicles[inventoryId].dirtyDate = dirtyDate end
      vehicle.dirtyDate = dirtyDate
      if not task.dirtiedSnapshot then inputs.dirtiedVehicles[inventoryId] = nil end
    end

    if not inputs.isExperimentalMaintenanceEnabled() then
      if type(vehicle.partConditions) == "table" then
        vehicle.partConditions = inputs.sanitizeMaintenancePartConditionsForVehicle(vehicle, vehicle.partConditions)
      end
      vehicle.maintenanceState = nil
      if inputs.vehicles[inventoryId] then inputs.vehicles[inventoryId].maintenanceState = nil end
    end

    vehicle.partConditions = serialize(vehicle.partConditions)

    -- Save parts as a flat pc-style map
    if vehicle.config then
      if vehicle.config.partsTree then
        vehicle.config.parts = core_vehicle_partmgmt.partsTreeToPartsMap(vehicle.config.partsTree)
      end
      vehicle.config.partsTree = nil
    end
  end

  local function prepareVehicleThumbnail(inventoryId, vehicle, vehicleWriter, currentSavePath, vehiclesThumbnailUpdate, task)
    local thumbnailFilename = currentSavePath .. "/career/vehicles/" .. inventoryId .. ".jpg"
    if vehiclesThumbnailUpdate and tableContains(vehiclesThumbnailUpdate, inventoryId) and inputs.inventoryIdToVehId[inventoryId] then
      local configKey = require('overhaul/career/garage/inventory/thumbnail').configKey(vehicle.config)
      local liveVehicle, vehId = inputs.vehicles[inventoryId], inputs.inventoryIdToVehId[inventoryId]
      vehicle.thumbnailConfig = configKey
      task["thumbnail" .. inventoryId] = false
      local function captureThumbnail()
        enqueueThumbnailCapture(inventoryId, thumbnailFilename, function(success, capturedConfig)
          if overhaul_career_saveSystem.isAsyncSaveExtensionCurrent(extensionName, task.generation) then
            if not success or capturedConfig ~= configKey or inputs.vehicles[inventoryId] ~= liveVehicle
              or inputs.inventoryIdToVehId[inventoryId] ~= vehId then
              -- A reused autosave slot can still contain an older car photo.
              overhaul_career_saveSystem.captureSaveWrites(function(writer) writer.remove(thumbnailFilename) end)
            else
              local record = inputs.vehicles[inventoryId]
              if record and require('overhaul/career/garage/inventory/thumbnail').configKey(record.config) == configKey then
                record.thumbnailConfig = configKey
              end
            end
          end
          task["thumbnail" .. inventoryId] = true
          checkSaveFinished(currentSavePath, task)
        end, function() return overhaul_career_saveSystem.isAsyncSaveExtensionCurrent(extensionName, task.generation) end)
      end
      overhaul_career_saveSystem.deferSaveWork(captureThumbnail, thumbnailFilename)
      vehicle.defaultThumbnail = nil
      if inputs.vehicles[inventoryId] then inputs.vehicles[inventoryId].defaultThumbnail = nil end
    elseif not vehicle.defaultThumbnail then
      local _, oldSavePath = overhaul_career_saveSystem.getCurrentProfile()
      vehicleWriter.copy(oldSavePath .. "/career/vehicles/" .. inventoryId .. ".jpg", thumbnailFilename)
    end
  end

  -- Record diff ---------------------------------------------------------------------------------------

  -- What the last committed save wrote for each record: its serialized form without dirtyDate (a UI thumbnail
  -- cache key, restamped whenever a car is marked dirty) and the dirtyDate the file holds. A record that serializes
  -- the same again, with the same dirtyDate, is copied from that slot instead of being prepared, encoded and
  -- written. Any doubt writes it in full.
  local committedRecords

  local function normalizedSlot(savePath) return (tostring(savePath or ""):gsub("^/+", "")) end

  -- Nothing but the captured record decides this save's file, apart from the dirtyDate stamp.
  local function recordOnly(inventoryId, task, vehiclesThumbnailUpdate)
    return not (task.dynoOverrides and task.dynoOverrides[inventoryId])
      and not (task.freshPartConditions and task.freshPartConditions[inventoryId])
      and not (vehiclesThumbnailUpdate and tableContains(vehiclesThumbnailUpdate, inventoryId))
  end

  -- An unchanged record keeps its file and its dirtyDate: nothing about the car changed, so neither does its picture.
  local function copyUnchangedRecord(inventoryId, task, vehiclesThumbnailUpdate, vehicleWriter, currentSavePath)
    local diff = task.diff
    local key = diff and diff.keys[inventoryId]
    local saved = key and diff.baseline and diff.baseline.records[inventoryId]
    if not (saved and saved.key == key and saved.dirtyDate == diff.dirtyDates[inventoryId]
      and diff.baseline.maintenance == diff.maintenance and recordOnly(inventoryId, task, vehiclesThumbnailUpdate)) then
      return false
    end
    local relative = "/career/vehicles/" .. inventoryId .. ".json"
    -- A save into the baseline's own folder already holds this file.
    if normalizedSlot(diff.baseline.slot) ~= normalizedSlot(currentSavePath) then
      if not FS:fileExists(diff.baseline.slot .. relative) then return false end
      vehicleWriter.copy(diff.baseline.slot .. relative, currentSavePath .. relative)
    end
    diff.written[inventoryId] = saved
    diff.copied = diff.copied + 1
    return true
  end

  -- After a full write: the file came from the record alone, stamped with the copy's final dirtyDate.
  local function recordWritten(inventoryId, written, task, vehiclesThumbnailUpdate)
    local diff = task.diff
    if diff and diff.keys[inventoryId] and recordOnly(inventoryId, task, vehiclesThumbnailUpdate) then
      diff.written[inventoryId] = {key = diff.keys[inventoryId], dirtyDate = written.dirtyDate}
    end
  end

  local function onOverhaulSaveFinished()
    local diff = finishedSaveTasks.diff
    local _, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if diff and diff.complete and normalizedSlot(savePath) == normalizedSlot(diff.slot) then
      committedRecords = {slot = diff.slot, records = diff.written, maintenance = diff.maintenance}
    else
      committedRecords = nil
    end
  end

  local function forgetCommittedRecords() committedRecords = nil end

  -- A parked car settles by micrometres between saves. Comparing its spot to the centimetre (and its facing to
  -- 1e-4) keeps an unchanged car copyable; the copied file then holds a spot within that rounding.
  local PLACEMENT_POSITION_STEP, PLACEMENT_ROTATION_STEP = 0.01, 1e-4
  local function rounded(value, step)
    return type(value) == "number" and math.floor(value / step + 0.5) * step or value
  end
  local function roundedPlacement(placed)
    local pos, rot = placed.pos or {}, placed.rot or {}
    return {
      pos = {x = rounded(pos.x, PLACEMENT_POSITION_STEP), y = rounded(pos.y, PLACEMENT_POSITION_STEP), z = rounded(pos.z, PLACEMENT_POSITION_STEP)},
      rot = {x = rounded(rot.x, PLACEMENT_ROTATION_STEP), y = rounded(rot.y, PLACEMENT_ROTATION_STEP),
        z = rounded(rot.z, PLACEMENT_ROTATION_STEP), w = rounded(rot.w, PLACEMENT_ROTATION_STEP)},
      level = placed.level,
    }
  end

  local function removeDeletedVehicleFiles(writer, currentSavePath, vehiclesCopy)
    local files = writer.findFiles(currentSavePath .. "/career/vehicles/", '*.json', 0, false, false)
    for i = 1, tableSize(files) do
      local dir, filename = path.split(files[i])
      local fileNameNoExt = string.sub(filename, 1, -6)
      local inventoryId = tonumber(fileNameNoExt)
      if inventoryId and not vehiclesCopy[inventoryId] then
        writer.remove(dir .. filename)
        writer.remove(dir .. inventoryId .. ".jpg")
      end
    end
  end

  local function saveVehiclesData(writer, currentSavePath, vehiclesThumbnailUpdate, task)
    task = task or finishedSaveTasks
    local vehiclesCopy = task.vehiclesSnapshot or deepcopy(inputs.vehicles)
    local currentDate = os.date("!%Y-%m-%dT%H:%M:%SZ")

    for inventoryId, vehicle in pairs(vehiclesCopy) do
      if isPersonalInventoryId(inventoryId) then
        local function saveVehicle(vehicleWriter)
          prepareVehicleSave(inventoryId, vehicle, task, currentDate)
          prepareVehicleThumbnail(inventoryId, vehicle, vehicleWriter, currentSavePath, vehiclesThumbnailUpdate, task)
          overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/vehicles/" .. inventoryId .. ".json", vehicle, true)
        end
        local key = "vehicleWrite" .. tostring(inventoryId)
        task[key] = false
        overhaul_career_saveSystem.deferSaveWork(function()
          if not overhaul_career_saveSystem.isAsyncSaveExtensionCurrent(extensionName, task.generation) then return end
          local blob = task.vehicleBlobs and task.vehicleBlobs[inventoryId]
          if blob then
            vehicle = require('string.buffer').decode(blob)
            task.vehicleBlobs[inventoryId] = nil
            vehiclesCopy[inventoryId] = vehicle
          end
          if task.freshPartConditions and task.freshPartConditions[inventoryId] then
            vehicle.partConditions = task.freshPartConditions[inventoryId]
            vehicle.mechanismState = task.freshMechanismStates[inventoryId]
          end
          overhaul_career_saveSystem.captureSaveWrites(function(vehicleWriter)
            -- Without live capture the damage manager's profile pass keeps each unchanged car's damage file.
            if task.liveCapture ~= false or (task.liveCars and task.liveCars[tostring(inventoryId)]) then
              overhaul_career_repair_damageManager.saveDamageState(inventoryId, currentSavePath .. "/career/vehicles/damage/" .. inventoryId .. "_damageState.json", nil, vehicle.partConditions, vehicleWriter)
            end
            if copyUnchangedRecord(inventoryId, task, vehiclesThumbnailUpdate, vehicleWriter, currentSavePath) then
              prepareVehicleThumbnail(inventoryId, vehicle, vehicleWriter, currentSavePath, vehiclesThumbnailUpdate, task)
            else
              saveVehicle(vehicleWriter)
              recordWritten(inventoryId, vehicle, task, vehiclesThumbnailUpdate)
            end
          end)
          task[key] = true
          checkSaveFinished(currentSavePath, task)
        end)
      end
    end

    if inputs.state.currentVehicle then
      inputs.dirtiedVehicles[inputs.state.currentVehicle] = true
    end

    removeDeletedVehicleFiles(writer, currentSavePath, vehiclesCopy)
  end

  -- Inventory capture -----------------------------------------------------------------------------

  local SNAPSHOT_LOG_THRESHOLD_MS = 5
  local PART_CONDITIONS_BATCH_TIMEOUT_S = 30

  -- Walking entry can skip the current id; recover it before saving so the next load restores the car.
  local function adoptSeatedVehicleAsCurrent()
    if inputs.state.currentVehicle then return end
    local playerVehId = be:getPlayerVehicleID(0)
    if not (playerVehId and playerVehId > 0) then return end
    local seatedInvId = inputs.vehIdToInventoryId[playerVehId]
    if seatedInvId then
      inputs.state.currentVehicle = seatedInvId
      inputs.state.lastVehicle = seatedInvId
    end
  end

  -- Each spawned personal car's position and facing. String keys so JSON keeps an object ({"1":...}), not an array.
  local function spawnedPlacements(visit)
    local placements = {}
    for inventoryId, vehId in pairs(inputs.inventoryIdToVehId) do
      if isPersonalInventoryId(inventoryId) then
        local vehicleObject = getObjectByID(vehId)
        if vehicleObject then
          local placed = {
            pos = vehicleObject:getPosition(),
            rot = quat(0,0,1,0) * quat(vehicleObject:getRefNodeRotation())
          }
          placements[tostring(inventoryId)] = placed
          if visit then visit(inventoryId, placed) end
        end
      end
    end
    return placements
  end

  local function buildInventoryData()
    local data = {}
    data.currentVehicle = inputs.state.currentVehicle
    data.lastVehicle = inputs.state.lastVehicle
    data.favoriteVehicle = inputs.state.favoriteVehicle
    if inputs.travel.pending then
      data.mapTravel = deepcopy(inputs.travel.pending)
    end

    data.spawnedPlayerVehicles = spawnedPlacements(function(inventoryId, placed)
      -- The next map's save has no live object for a car left here. Plain numbers, not vec3/quat cdata:
      -- the record must stay serializable, or every later save deep-copies it and cannot reuse its file.
      local record = inputs.vehicles[inventoryId]
      if record then
        record.worldPosition = {
          pos = {x = placed.pos.x, y = placed.pos.y, z = placed.pos.z},
          rot = {x = placed.rot.x, y = placed.rot.y, z = placed.rot.z, w = placed.rot.w},
          level = getCurrentLevelIdentifier(),
        }
      end
    end)

    if gameplay_walk.isWalking() then
      local playerVeh = getPlayerVehicle(0)
      if playerVeh then
        data.unicyclePos = playerVeh:getPosition()
      end
    end

    if overhaul_career_market_auction_auction and overhaul_career_market_auction_auction.applyInventorySpawnOverrides then
      overhaul_career_market_auction_auction.applyInventorySpawnOverrides(data)
    end
    local session = capabilities.peek("businessSession")
    if session then
      session.applyInventorySpawnOverrides(data)
    end
    return data
  end

  -- A vehicle record without its parts tree, with the tree flattened to a parts map.
  local function projectVehicleForSave(vehicle)
    local projected = {}
    for key, value in pairs(vehicle) do
      if key ~= "config" then projected[key] = value end
    end
    if vehicle.config then
      projected.config = {}
      for key, value in pairs(vehicle.config) do
        if key ~= "partsTree" then projected.config[key] = value end
      end
      if vehicle.config.partsTree then
        projected.config.parts = core_vehicle_partmgmt.partsTreeToPartsMap(vehicle.config.partsTree)
      end
    end
    return projected
  end

  -- Freezes the vehicle records for the async save; returns the snapshot function the save also needs later.
  local function captureVehicleSnapshot(task)
    local clock = os.clockhp or os.clock
    local snapshotStarted = clock()
    -- Vehicles are captured serialized and decoded when their files are written.
    task.vehiclesSnapshot, task.vehicleBlobs, task.freshPartConditions, task.freshMechanismStates = {}, {}, {}, {}
    local saveJson = require('overhaul/lib/save/jsonWriter')
    local snapshot = saveJson.snapshot
    for inventoryId, vehicle in pairs(inputs.vehicles) do
      local projected = projectVehicleForSave(vehicle)
      if task.diff then
        -- The diff key leaves out dirtyDate and rounds the parking spot; restoring both fields keeps the table's
        -- layout and the blob's bytes.
        local dirtyDate, placed = projected.dirtyDate, projected.worldPosition
        projected.dirtyDate = nil
        if type(placed) == "table" then projected.worldPosition = roundedPlacement(placed) end
        task.diff.keys[inventoryId], task.diff.dirtyDates[inventoryId] = saveJson.encode(projected), dirtyDate
        projected.dirtyDate, projected.worldPosition = dirtyDate, placed
      end
      local blob = saveJson.encode(projected)
      if blob then
        task.vehicleBlobs[inventoryId] = blob
        -- Keep membership for deletion checks without allocating the entire decoded fleet.
        task.vehiclesSnapshot[inventoryId] = true
      else
        task.vehiclesSnapshot[inventoryId] = snapshot(projected)
      end
    end
    task.dynoOverrides = {}
    local session = capabilities.peek("businessSession")
    if session then
      for inventoryId in pairs(inputs.vehicles) do task.dynoOverrides[inventoryId] = session.getInventorySaveOverride(inventoryId) end
    end
    task.dirtiedSnapshot = deepcopy(inputs.dirtiedVehicles)
    table.clear(inputs.dirtiedVehicles)
    local snapshotMs = (clock() - snapshotStarted) * 1000
    if snapshotMs >= SNAPSHOT_LOG_THRESHOLD_MS then
      log('D', 'inventory', string.format('save timing inventory_snapshot_ms=%.3f vehicles=%d', snapshotMs, tableSize(inputs.vehicles)))
    end
    return snapshot
  end

  -- Writes the vehicle files once the spawned cars' conditions are in, or after a timeout without them.
  local function startPartConditionsCapture(task, currentSavePath, vehiclesThumbnailUpdate, snapshot)
    local function finishPartConditionsStep()
      if not overhaul_career_saveSystem.isAsyncSaveExtensionCurrent(extensionName, task.generation) then return end
      if task.updatePartConditions then return end
      task.updatePartConditions = true
      overhaul_career_saveSystem.captureSaveWrites(saveVehiclesData, currentSavePath, vehiclesThumbnailUpdate, task)
      checkSaveFinished(currentSavePath, task)
    end
    -- A transaction save asks only the cars that changed since a save last captured them; the others keep
    -- the conditions they last reported.
    local only = task.liveCapture == false and (task.liveCars or {}) or nil
    if only and not next(only) then
      finishPartConditionsStep()
      return
    end
    task.partConditionsBatch = updatePartConditionsOfSpawnedVehicles(finishPartConditionsStep, function(inventoryId)
      if (task.vehicleBlobs[inventoryId] or task.vehiclesSnapshot[inventoryId]) and inputs.vehicles[inventoryId] then
        task.freshPartConditions[inventoryId] = snapshot(inputs.vehicles[inventoryId].partConditions)
        task.freshMechanismStates[inventoryId] = snapshot(inputs.vehicles[inventoryId].mechanismState)
      end
    end, true, only)
    core_jobsystem.create(function(job)
      job.sleep(PART_CONDITIONS_BATCH_TIMEOUT_S)
      if not task.updatePartConditions and overhaul_career_saveSystem.isAsyncSaveExtensionCurrent(extensionName, task.generation) then
        log("W", "inventory", "updatePartConditions timed out during save; continuing without fresh part data")
        partConditionBatches:cancel(task.partConditionsBatch)
        finishPartConditionsStep()
      end
    end)
  end

  -- Records how carried and hitched vehicles relate, unless a map travel is mid-flight.
  local function relationshipCaptureBlocked()
    local pending = inputs.travel.pending
    local departing = pending and not pending.arrivalPending and not pending.sessionRestore
    return departing or inputs.travel.activeRestore
  end

  -- Relationship staging ------------------------------------------------------------------------------

  -- The part shop scans hitched and carried cars, brakes included, while the player browses. Its purchase save
  -- reuses that scan when every other spawned car is still where it was; otherwise it scans live as usual.
  local STAGED_MOVE_TOLERANCE_M = 0.05
  local STAGED_TURN_TOLERANCE = 1e-4 -- 1 - |q1.q2|
  local stagedRelationships

  local function treeHas(node, key)
    if tostring(node.inventoryId) == key then return true end
    for _, child in ipairs(node.children or {}) do if treeHas(child, key) then return true end end
    return false
  end

  -- True when the car is coupled to, carries or rides on another car.
  local function relationshipsInvolve(manifest, inventoryId)
    local key = tostring(inventoryId)
    for _, relation in ipairs(manifest.carriedVehicles or {}) do
      if tostring(relation.inventoryId) == key or tostring(relation.parentInventoryId) == key then return true end
    end
    for _, group in ipairs(manifest.groups or {}) do
      if group.tree and next(group.tree.children or {}) and treeHas(group.tree, key) then return true end
    end
    return false
  end

  local function samePlacements(staged, now, ignoredKey)
    for key, placed in pairs(now) do
      local before = staged[key]
      if key ~= ignoredKey then
        if not before then return false end
        local dx, dy, dz = placed.pos.x - before.pos.x, placed.pos.y - before.pos.y, placed.pos.z - before.pos.z
        if dx * dx + dy * dy + dz * dz > STAGED_MOVE_TOLERANCE_M * STAGED_MOVE_TOLERANCE_M then return false end
        local dot = placed.rot.x * before.rot.x + placed.rot.y * before.rot.y + placed.rot.z * before.rot.z + placed.rot.w * before.rot.w
        if 1 - math.abs(dot) > STAGED_TURN_TOLERANCE then return false end
      end
    end
    for key in pairs(staged) do if now[key] == nil and key ~= ignoredKey then return false end end
    return true
  end

  -- The edited car must not take part in a relationship: its preview respawns would make the scan stale.
  local function stageRelationships(editedInventoryId)
    stagedRelationships = nil
    local switchMap = overhaul_career_garage_switchMap
    if not (switchMap and switchMap.captureInventoryRelationships) or relationshipCaptureBlocked() then return false end
    local placements = spawnedPlacements()
    local ok, manifest = pcall(switchMap.captureInventoryRelationships, placements)
    if not ok or not manifest or relationshipsInvolve(manifest, editedInventoryId) then return false end
    local stage = {placements = placements, manifest = manifest, ignoredKey = tostring(editedInventoryId)}
    stagedRelationships = stage
    if switchMap.captureRelationshipBrakes then
      switchMap.captureRelationshipBrakes(manifest.brakeStates, function() stage.ready = true end)
    else
      stage.ready = true
    end
    return true
  end

  local function clearStagedRelationships() stagedRelationships = nil end

  -- A purchase save takes the staged scan, once, when it is complete and still matches the cars.
  local function takeStagedRelationships(task, data)
    local stage = stagedRelationships
    if not (stage and stage.ready and task.liveCapture == false) then return nil end
    stagedRelationships = nil
    if not samePlacements(stage.placements, data.spawnedPlayerVehicles, stage.ignoredKey) then return nil end
    return stage.manifest
  end

  local function captureVehicleRelationships(data, task)
    local capture = overhaul_career_garage_switchMap and overhaul_career_garage_switchMap.captureInventoryRelationships
    if not capture or relationshipCaptureBlocked() then return end
    -- Map travel captures without a save task and always scans live.
    local manifest = task and takeStagedRelationships(task, data)
    if task then task.relationshipsStaged = manifest ~= nil or nil end
    if not manifest then
      local ok, captured = pcall(capture, data.spawnedPlayerVehicles)
      manifest = ok and captured or nil
    end
    if manifest then
      manifest.savedLocations = deepcopy(data.spawnedPlayerVehicles)
      manifest.currentInventoryId = data.currentVehicle
      manifest.sessionRestore = true
      data.vehicleRelationships = manifest
    end
  end

  local function writeInventoryFile(task, currentSavePath, data)
    local function writeInventory()
      if finishedSaveTasks ~= task then return end
      overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/inventory.json", data, true)
      task.relationships = true
      checkSaveFinished(currentSavePath, task)
    end
    -- A staged scan already holds its brake states.
    if data.vehicleRelationships and not task.relationshipsStaged and overhaul_career_garage_switchMap.captureRelationshipBrakes then
      overhaul_career_garage_switchMap.captureRelationshipBrakes(data.vehicleRelationships.brakeStates, writeInventory)
    else
      writeInventory()
    end
  end

  -- TODO update a vehicles part conditions in the table when you exit a vehicle
  local function onOverhaulSaveCurrentProfile(currentSavePath, vehiclesThumbnailUpdate)
    adoptSeatedVehicleAsCurrent()
    local data = buildInventoryData()
    local task = finishedSaveTasks
    local saveSystem = overhaul_career_saveSystem
    task.liveCapture = not saveSystem.capturesLiveVehicles or saveSystem.capturesLiveVehicles()
    local damage = overhaul_career_repair_damageManager
    task.liveCars = not task.liveCapture and damage and damage.getLiveCaptureCars and damage.getLiveCaptureCars() or nil
    task.diff = {slot = currentSavePath, baseline = committedRecords, keys = {}, dirtyDates = {}, written = {}, copied = 0,
      maintenance = inputs.isExperimentalMaintenanceEnabled() == true}
    captureVehicleRelationships(data, task)
    local snapshot = captureVehicleSnapshot(task)
    task.relationships = false
    task.updatePartConditions = false
    startPartConditionsCapture(task, currentSavePath, vehiclesThumbnailUpdate, snapshot)
    writeInventoryFile(task, currentSavePath, data)
  end

  -- Public API ------------------------------------------------------------------------------------

  return {
    auctionListingBlockReason = auctionListingBlockReason,
    cancelPendingAuctionListings = cancelPendingAuctionListings,
    clearVehicleAuctionListing = clearVehicleAuctionListing,
    ensureVehicleThumbnail = ensureVehicleThumbnail,
    getListedVehicleId = getListedVehicleId,
    getListedVehicleIds = getListedVehicleIds,
    isAuctionListingPending = isAuctionListingPending,
    isPersonalInventoryId = isPersonalInventoryId,
    isVehicleListedForAuction = isVehicleListedForAuction,
    onOverhaulSaveCurrentProfile = onOverhaulSaveCurrentProfile,
    onOverhaulSaveCurrentProfileAsyncStart = onOverhaulSaveCurrentProfileAsyncStart,
    partConditionBatches = partConditionBatches,
    pumpThumbnailCaptures = pumpThumbnailCaptures,
    refreshVehicleThumbnail = refreshVehicleThumbnail,
    onOverhaulSaveFinished = onOverhaulSaveFinished,
    stageRelationships = stageRelationships,
    clearStagedRelationships = clearStagedRelationships,
    forgetCommittedRecords = forgetCommittedRecords,
    setVehicleDirty = setVehicleDirty,
    setVehicleListedForAuction = setVehicleListedForAuction,
    updatePartConditionsOfCurrentVehicle = updatePartConditionsOfCurrentVehicle,
    updatePartConditionsOfSpawnedVehicles = updatePartConditionsOfSpawnedVehicles,
  }
end

return persistence
