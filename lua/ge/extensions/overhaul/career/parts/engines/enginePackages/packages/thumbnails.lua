-- Engine thumbnails: isolate an engine, frame its camera and capture its image.
-- Map: State; Part visibility; Camera framing; Queue; Queue processing and idle callbacks; Public API.

local thumbnails = {}
-- require caches this library across career extension recreation. Native renders
-- outlive their career owner and share global CEF visibility.
local renderState = {pending = nil, waiters = {}}


function thumbnails.create(inputs)
  local parts = inputs.parts

  -- State ----------------------------------------------------------------------------------------------

  -- Vehicle ids temporarily isolated for capture; respawns reusing an id must regain full visibility.
  local isolatedVehicleIds = {}
  local visibilityRetry = {}
  local thumbnailState = {thumbnailQueue = {}, thumbnailBusy = false, capturingPackageId = nil, canceledThumbnailPackageIds = {}}
  local pendingAfterIdle = {}
  local captureGeneration = 0
  local activeCapture
  local stopped = false
  local failedCaptures = {}
  local pumpThumbnailQueue

  -- Part visibility ----------------------------------------------------------------------------------

  local function vehicleReadyForHighlightReset(vehId)
    if not vehId then return nil end
    local vehObj = getObjectByID(vehId)
    if not vehObj then return nil end
    local vehData = core_vehicle_manager.getVehicleData(vehId)
    if not vehData or not vehData.config then return nil end
    return vehObj
  end

  local function applyFullPartVisibility(vehId)
    local vehObj = vehicleReadyForHighlightReset(vehId)
    if not vehObj then return false end
    -- reset(false) drops the cache. It no-ops when the object or vehicle data is missing, which is what leaves wheels at alpha 0 after a same-model replace.
    if core_vehicle_partmgmt.clearVehicleHighlights then core_vehicle_partmgmt.clearVehicleHighlights(vehId) end
    core_vehicle_partmgmt.resetVehicleHighlights(false, vehId)
    core_vehicle_partmgmt.setNewParts(vehId)
    core_vehicle_partmgmt.showHighlightedParts(vehId)
    pcall(function() vehObj:setMeshAlpha(1, "", false) end)
    isolatedVehicleIds[vehId] = nil
    return true
  end

  local function scheduleVisibilityRetry(vehId)
    if not vehId or visibilityRetry[vehId] then return end
    visibilityRetry[vehId] = true
    core_jobsystem.create(function(job)
      local startClock = os.clock()
      while os.clock() - startClock < 3 do
        job.sleep(0.15)
        if applyFullPartVisibility(vehId) then
          visibilityRetry[vehId] = nil
          return
        end
      end
      visibilityRetry[vehId] = nil
      if isolatedVehicleIds[vehId] then
        log("W", inputs.constants.logTag, "Part visibility restore timed out for vehicle " .. tostring(vehId))
      end
    end, 1)
  end

  -- Reset menu highlights and mesh alpha, using the live object when a respawn reused this id.
  local function restoreVehiclePartVisibility(vehObj, vehId)
    if vehId then
      local live = getObjectByID(vehId)
      if live then vehObj = live end
    elseif vehObj and vehObj.getID then
      vehId = vehObj:getID()
    end
    if vehId and applyFullPartVisibility(vehId) then
      visibilityRetry[vehId] = nil
      return
    end
    if vehObj then
      pcall(function() vehObj:setMeshAlpha(1, "", false) end)
    end
    if vehId then
      scheduleVisibilityRetry(vehId)
    end
  end

  local function unhideInventoryVehicle(inventoryId)
    local vehObj, vehId = parts.capture.getSpawnedVehicleObject(inventoryId)
    restoreVehiclePartVisibility(vehObj, vehId)
  end

  -- Camera framing ------------------------------------------------------------------------------------

  -- Parts that extend far from the engine block and should not dominate framing.
  local PERIPHERAL_PART_TOKENS = {"exhaust", "transmission", "gearbox", "transfercase", "driveshaft", "radiator", "intercooler"}

  local function isPeripheralEnginePart(name)
    if not name then return false end
    local lower = string.lower(name)
    for _, token in ipairs(PERIPHERAL_PART_TOKENS) do
      if string.find(lower, token, 1, true) then return true end
    end
    return false
  end

  -- Splits the live part paths and names into core engine parts and peripheral parts.
  local function splitCoreParts(partPaths, partNames)
    local corePartPaths, corePartNames, peripheralPartPaths = {}, {}, {}
    for path in pairs(partPaths) do
      local name = path:match("([^/]+)$")
      if isPeripheralEnginePart(name) then
        peripheralPartPaths[path] = true
      else
        corePartPaths[path] = true
      end
    end
    for name in pairs(partNames) do
      if not isPeripheralEnginePart(name) then
        corePartNames[name] = true
      end
    end
    return corePartPaths, corePartNames
  end

  -- Grows the world-space box around every node in the list, and counts the nodes.
  local function makeBoxAccumulator(vehObj, vehPos)
    local box = vehObj:getSpawnWorldOOBB()
    local axes = {box:getAxis(0), box:getAxis(1), box:getAxis(2)}
    local accumulator = {nodeCount = 0, seen = {}, axes = axes, position = vehPos}
    function accumulator.addNode(cid)
      if cid == nil or accumulator.seen[cid] then return end
      accumulator.seen[cid] = true
      local nodePos = vehObj:getNodePosition(cid)
      if not nodePos then return end
      -- Measure in vehicle axes so rotating the car does not change portrait scale.
      local world = vec3(nodePos:dot(axes[1]), nodePos:dot(axes[2]), nodePos:dot(axes[3]))
      accumulator.nodeCount = accumulator.nodeCount + 1
      if not accumulator.minP then
        accumulator.minP = vec3(world.x, world.y, world.z)
        accumulator.maxP = vec3(world.x, world.y, world.z)
      else
        local minP, maxP = accumulator.minP, accumulator.maxP
        minP.x = math.min(minP.x, world.x)
        minP.y = math.min(minP.y, world.y)
        minP.z = math.min(minP.z, world.z)
        maxP.x = math.max(maxP.x, world.x)
        maxP.y = math.max(maxP.y, world.y)
        maxP.z = math.max(maxP.z, world.z)
      end
    end
    return accumulator
  end

  -- Core engine nodes first; if none resolve, every engine node is used.
  local function accumulateEngineNodes(vdata, accumulator, corePartPaths, corePartNames, partPaths, partNames)
    if vdata and vdata.nodes then
      for _, node in pairs(vdata.nodes) do
        if type(node) == "table" and node.cid ~= nil then
          local pathMatch = node.partPath and corePartPaths[node.partPath]
          local nameMatch = node.partOrigin and corePartNames[node.partOrigin]
          if pathMatch or nameMatch then accumulator.addNode(node.cid) end
        end
      end
    end

    if accumulator.nodeCount < 2 and vdata and vdata.nodes then
      for _, node in pairs(vdata.nodes) do
        if type(node) == "table" and node.cid ~= nil then
          local match = (node.partPath and partPaths[node.partPath]) or (node.partOrigin and partNames[node.partOrigin])
          if match then accumulator.addNode(node.cid) end
        end
      end
    end
  end

  -- No guessed vehicle corner: node-less/modded engines use the UI icon instead.
  local function frameEngineCamera(vehObj, vdata, partPaths, partNames)
    local corePartPaths, corePartNames = splitCoreParts(partPaths, partNames)
    local accumulator = makeBoxAccumulator(vehObj, vehObj:getPosition())
    accumulateEngineNodes(vdata, accumulator, corePartPaths, corePartNames, partPaths, partNames)
    if accumulator.nodeCount < 2 then return nil end
    local size = accumulator.maxP - accumulator.minP
    local radius = size:length() * 0.5
    if radius < 0.05 then return nil end
    local centre = (accumulator.minP + accumulator.maxP) * 0.5
    local axes = accumulator.axes
    local lookAt = accumulator.position + axes[1] * centre.x + axes[2] * centre.y + axes[3] * centre.z
    local boundingBox = vehObj:getSpawnWorldOOBB()
    local right, forward, up = boundingBox:getAxis(0), boundingBox:getAxis(1), boundingBox:getAxis(2)
    local fov = 28
    -- A bounding sphere fits at every vehicle heading, including tall mod engines.
    local distance = math.max(1.05, radius * 1.15 / math.sin(math.rad(fov) * 0.5))
    -- A very broad node cloud is not a useful engine portrait (often exhaust or shared chassis nodes).
    if distance > 6 then return nil end
    log("I", inputs.constants.logTag, string.format("Engine frame nodes=%d radius=%.2f dist=%.2f", accumulator.nodeCount, radius, distance))
    local offset = (right * -0.72 + forward * -0.88 + up * 0.42):normalized()
    local camPos = lookAt + offset * distance
    return camPos, quatFromDir(lookAt - camPos, up), fov
  end

  -- Read actual mesh ownership, independent of the parts menu's x-ray/focus state.
  local function collectEngineMeshes(vdata, partPaths, partNames)
    local meshes = {}
    for _, entries in ipairs({vdata and vdata.flexbodies or {}, vdata and vdata.props or {}}) do
      for _, entry in pairs(entries) do
        if type(entry) == "table" and type(entry.mesh) == "string" and entry.mesh ~= ""
          and entry.mesh ~= "SPOTLIGHT" and entry.mesh ~= "POINTLIGHT"
          and ((entry.partPath and partPaths[entry.partPath]) or (entry.partOrigin and partNames[entry.partOrigin])) then
          meshes[entry.mesh] = true
        end
      end
    end
    return meshes
  end

  -- Queue ----------------------------------------------------------------------------------------------

  local function packageInstalledOnInventory(package, inventoryId)
    if not package or inventoryId == nil then return false end
    local status, installedInventoryId = inputs.getPackageStatus(package)
    return status == "installed" and tonumber(installedInventoryId) == tonumber(inventoryId)
  end

  -- Drops queued captures for a package and tells their callbacks it was canceled.
  local function cancelThumbnailsForPackage(packageId)
    if packageId == nil then return end
    packageId = tostring(packageId)
    thumbnailState.canceledThumbnailPackageIds[packageId] = true
    local kept = {}
    for _, job in ipairs(thumbnailState.thumbnailQueue) do
      if tostring(job.packageId) ~= packageId then
        kept[#kept + 1] = job
      elseif job.callback then
        local cbOk, cbErr = pcall(job.callback, false)
        if not cbOk then
          log("E", inputs.constants.logTag, "Canceled thumbnail callback failed: " .. tostring(cbErr))
        end
      end
    end
    thumbnailState.thumbnailQueue = kept
  end

  local function clearThumbnailCancel(packageId)
    if packageId == nil then return end
    thumbnailState.canceledThumbnailPackageIds[tostring(packageId)] = nil
  end

  local function isThumbnailCanceled(packageId)
    return packageId ~= nil and thumbnailState.canceledThumbnailPackageIds[tostring(packageId)] == true
  end

  -- Checks in order: package exists, not canceled, installed on this vehicle, vehicle spawned. Returns the plan or nil and the reason.
  local function planEngineCapture(packageId, inventoryId, captureKey)
    local package = inputs.getPackageById(packageId)
    local runtimeData, vehObj, vehId = parts.capture.getRuntimeVehicleData(inventoryId)
    if not package then return nil, "package not found" end
    if isThumbnailCanceled(packageId) then return nil, "thumbnail canceled" end
    if not packageInstalledOnInventory(package, inventoryId) then return nil, "package not installed on capture vehicle" end
    if not runtimeData or not vehObj then return nil, "vehicle is not spawned" end

    local engine = runtimeData.config and parts.capture.resolveEngineCaptureAnchor(runtimeData.config.partsTree, runtimeData.ioCtx)
    if not engine or not engine.node then return nil, "no installed engine slot" end

    local partPaths = inputs.collectLivePartPaths(engine.node)
    local partNames = inputs.collectLivePartNames(engine.node)
    inputs.expandPartPathsFromVdata(runtimeData.vdata, partNames, partPaths)
    if not next(partPaths) then return nil, "engine part paths were empty" end
    log("I", inputs.constants.logTag, "Engine isolate parts=" .. tostring(inputs.countTableEntries(partPaths)))

    local filename = inputs.getPackageThumbnailDiskPath(package.id)
    if not filename then return nil, "no save path" end
    inputs.ensureSaveDirectory(filename)


    local meshes = collectEngineMeshes(runtimeData.vdata, partPaths, partNames)
    if not next(meshes) then return nil, "no engine meshes resolved" end
    local camPos, camRot, fov = frameEngineCamera(vehObj, runtimeData.vdata, partPaths, partNames)
    if not camPos or not camRot then return nil, "could not frame engine camera" end

    if not render_renderViews or not render_renderViews.takeScreenshot then
      extensions.load("render_renderViews")
    end
    if not render_renderViews or not render_renderViews.takeScreenshot then return nil, "render view screenshot missing" end

    return {
      package = package, vehObj = vehObj, vehId = vehId, meshes = meshes,
      filename = filename, captureFilename = filename .. "." .. captureKey .. ".jpg", renderViewName = captureKey,
      camPos = camPos, camRot = camRot, fov = fov
    }
  end

  -- Ends one capture exactly once: restores the vehicle, logs the outcome and calls back.
  local function finishCapture(session, ok, reason, unsupportedGeometry)
    if session.finished then return end
    session.finished = true
    if session.captureFilename then pcall(function() FS:removeFile(session.captureFilename) end) end
    if session.isolated then
      -- Restore the captured object even after inventory has already unloaded.
      local restored, restoreError = pcall(restoreVehiclePartVisibility, session.vehObj, session.vehId)
      if not restored then
        pcall(function() session.vehObj:setMeshAlpha(1, "", false) end)
        log("W", inputs.constants.logTag, "Engine visibility restore failed: " .. tostring(restoreError))
      end
      session.isolated = false
    end
    if activeCapture == session then activeCapture = nil end
    if not ok then
      local package = inputs.getPackageById(session.packageId)
      failedCaptures[tostring(session.packageId)] = {
        recipe = package and tostring(package.updatedAt or 0) or "missing",
        retryAfter = not unsupportedGeometry and os.clock() + 5 or nil,
      }
      log("W", inputs.constants.logTag, "Engine thumbnail failed for package " .. tostring(session.packageId) .. ": " .. tostring(reason or "unknown"))
    else
      log("I", inputs.constants.logTag, "Engine thumbnail saved for package " .. tostring(session.packageId))
    end
    if session.callback then
      local cbOk, cbErr = pcall(session.callback, ok == true)
      if not cbOk then
        log("E", inputs.constants.logTag, "Engine thumbnail callback failed: " .. tostring(cbErr))
      end
    end
  end

  -- Runs when the screenshot has returned: checks the package is still installed, then records the thumbnail.
  local function onScreenshotReturned(session, plan, success)
    if session.finished then pcall(function() FS:removeFile(plan.captureFilename) end) return end
    session.screenshotDone = true
    if isThumbnailCanceled(session.packageId) then
      finishCapture(session, false, "thumbnail canceled after capture")
      return
    end
    local livePackage = inputs.getPackageById(session.packageId)
    if not packageInstalledOnInventory(livePackage, session.inventoryId) then
      finishCapture(session, false, "package no longer installed on capture vehicle")
      return
    end
    -- A save may have copied the old bitmap before its profile path switches.
    -- Publishing during that window would stamp v6 onto a v5 image in the new slot.
    if (inputs.isSaveBusy and inputs.isSaveBusy())
      or inputs.getPackageThumbnailDiskPath(session.packageId) ~= plan.filename then
      finishCapture(session, false, "save moved or is copying thumbnail files")
      return
    end
    local published = false
    if success == true and FS:fileExists(plan.captureFilename) then
      local backup = plan.captureFilename .. ".previous"
      local hadTarget = FS:fileExists(plan.filename)
      local backedUp = not hadTarget or FS:renameFile(plan.filename, backup) == 0
      if backedUp then
        published = FS:renameFile(plan.captureFilename, plan.filename) == 0
        if published then
          if hadTarget then FS:removeFile(backup) end
        elseif hadTarget and FS:renameFile(backup, plan.filename) ~= 0 then
          log("E", inputs.constants.logTag, "Could not restore thumbnail backup: " .. backup)
        end
      end
    end
    if published then
      failedCaptures[tostring(session.packageId)] = nil
      livePackage.thumbnailAt = os.time()
      livePackage.thumbnailCaptureVersion = inputs.constants.thumbnailCaptureVersion
      inputs.sendUIData()
      finishCapture(session, true)
    else
      finishCapture(session, false, "screenshot callback reported failure")
    end
  end

  local function releaseRender(session)
    if renderState.pending ~= session then return end
    renderState.pending = nil
    local waiters = renderState.waiters
    renderState.waiters = {}
    for waiter in pairs(waiters) do
      local ok, err = pcall(waiter)
      if not ok then log("E", inputs.constants.logTag, "Thumbnail render waiter failed: " .. tostring(err)) end
    end
  end

  -- Isolates the engine parts, then takes the framed screenshot and waits for it (up to six seconds).
  local function isolateAndShoot(session, plan, job)
    if session.finished or stopped then return end
    session.isolated = true
    if plan.vehId then isolatedVehicleIds[plan.vehId] = true end
    local highlightOk, highlightErr = pcall(function()
      -- Newer menu highlighting owns render passes and animates alpha every frame.
      if core_vehicle_partmgmt.clearVehicleHighlights then core_vehicle_partmgmt.clearVehicleHighlights(plan.vehId) end
      core_vehicle_partmgmt.resetVehicleHighlights(false, plan.vehId)
      plan.vehObj:setMeshAlpha(0, "", false)
      for mesh in pairs(plan.meshes) do plan.vehObj:setMeshAlpha(1, mesh, false) end
    end)
    if not highlightOk then
      finishCapture(session, false, "engine isolation failed: " .. tostring(highlightErr))
      return
    end
    job.sleep(0.3)
    if session.finished then return end

    if isThumbnailCanceled(session.packageId) or not packageInstalledOnInventory(inputs.getPackageById(session.packageId), session.inventoryId) then
      finishCapture(session, false, "thumbnail canceled before screenshot")
      return
    end

    session.screenshotDone = false
    renderState.pending = session
    session.cefVisible = ui_visibility and ui_visibility.getCef()
    session.imguiVisible = ui_visibility and ui_visibility.getImgui()
    local screenshotOk, screenshotErr = pcall(function()
      render_renderViews.takeScreenshot({
        renderViewName = plan.renderViewName,
        screenshotDelay = 0.4,
        resolution = vec3(1000, 562, 0),
        downscaleFactor = 2,
        copyMainViewExposure = true,
        rot = plan.camRot,
        pos = plan.camPos,
        fov = plan.fov or 32,
        nearPlane = 0.04,
        filename = plan.captureFilename
      }, function(success)
        local callbackOk, callbackError = pcall(onScreenshotReturned, session, plan, success)
        if not callbackOk then finishCapture(session, false, "screenshot completion failed: " .. tostring(callbackError)) end
        releaseRender(session)
        pumpThumbnailQueue()
      end)
    end)

    if not screenshotOk then
      finishCapture(session, false, "takeScreenshot error: " .. tostring(screenshotErr))
      releaseRender(session)
      return
    end

    -- Native jobs can throw before calling back. Restore their global UI state
    -- before releasing the shared barrier, so later renders snapshot usable UI.
    if renderState.pending == session then
      core_jobsystem.create(function(watchdog)
        watchdog.sleep(30)
        if renderState.pending ~= session then return end
        log("W", inputs.constants.logTag, "Native thumbnail render did not complete within 30 seconds")
        pcall(function()
          if ui_visibility then
            if session.cefVisible ~= nil then ui_visibility.setCef(session.cefVisible) end
            if session.imguiVisible ~= nil then ui_visibility.setImgui(session.imguiVisible) end
          end
          if gameplay_markerInteraction then gameplay_markerInteraction.setMarkersVisibleTemporary(true) end
        end)
        finishCapture(session, false, "native render did not complete")
        releaseRender(session)
      end, 1)
    end

    local waitStart = os.clock()
    while not session.screenshotDone and (os.clock() - waitStart) < 6 do
      job.sleep(0.1)
    end
    if not session.finished then
      finishCapture(session, false, "screenshot timed out")
    end
  end

  -- Captures one thumbnail now; the callback receives true or false when it ends.
  local function captureEngineThumbnailNow(packageId, inventoryId, callback)
    local session = {packageId = packageId, inventoryId = inventoryId, callback = callback, finished = false, isolated = false}
    activeCapture = session
    local captureKey = "enginePkgThumb_" .. tostring(session):gsub("[^%w]", "")
    local planned, plan, reason = pcall(planEngineCapture, packageId, inventoryId, captureKey)
    if not planned then reason = plan; plan = nil end
    if not plan then
      local unsupported = reason == "no installed engine slot" or reason == "engine part paths were empty"
        or reason == "no engine meshes resolved"
      finishCapture(session, false, reason, unsupported)
      return
    end
    session.vehObj, session.vehId = plan.vehObj, plan.vehId
    session.captureFilename = plan.captureFilename

    local jobHandle = core_jobsystem.create(function(job)
      local ok, err = pcall(isolateAndShoot, session, plan, job)
      if not ok then finishCapture(session, false, tostring(err)) end
    end, 1)
    if jobHandle and jobHandle.setExitCallback then
      jobHandle.setExitCallback(function()
        if not session.finished then
          finishCapture(session, false, "thumbnail job ended")
        end
      end)
    end
  end

  -- Queue processing and idle callbacks --------------------------------------------------------------

  local function flushThumbnailWaiters()
    if thumbnailState.thumbnailBusy or thumbnailState.thumbnailQueue[1] then return end
    local waiters = pendingAfterIdle
    pendingAfterIdle = {}
    for _, waiter in ipairs(waiters) do
      local ok, err = pcall(waiter)
      if not ok then
        log("E", inputs.constants.logTag, "Thumbnail idle callback failed: " .. tostring(err))
      end
    end
  end

  pumpThumbnailQueue = function()
    -- A timed-out native render still owns global CEF visibility until its callback returns.
    if stopped or thumbnailState.thumbnailBusy then return end
    if renderState.pending then
      renderState.waiters[pumpThumbnailQueue] = true
      return
    end
    local job = table.remove(thumbnailState.thumbnailQueue, 1)
    if not job then
      thumbnailState.capturingPackageId = nil
      flushThumbnailWaiters()
      return
    end
    thumbnailState.thumbnailBusy = true
    thumbnailState.capturingPackageId = job.packageId
    captureEngineThumbnailNow(job.packageId, job.inventoryId, function(ok)
      thumbnailState.thumbnailBusy = false
      thumbnailState.capturingPackageId = nil
      if job.callback then
        local cbOk, cbErr = pcall(job.callback, ok)
        if not cbOk then
          log("E", inputs.constants.logTag, "Queued engine thumbnail callback failed: " .. tostring(cbErr))
        end
      end
      pumpThumbnailQueue()
    end)
  end

  local function whenThumbnailsIdle(callback)
    if not callback then return end
    if not thumbnailState.thumbnailBusy and not thumbnailState.thumbnailQueue[1] then
      local ok, err = pcall(callback)
      if not ok then
        log("E", inputs.constants.logTag, "Thumbnail idle callback failed: " .. tostring(err))
      end
      return
    end
    table.insert(pendingAfterIdle, callback)
  end

  -- Runs the callback once the queue is idle, or after the timeout, whichever comes first.
  local function whenThumbnailsIdleOrTimeout(callback, timeoutSec)
    if not callback then return end
    local finished = false
    local generation = captureGeneration
    local function run()
      if finished or generation ~= captureGeneration then return end
      finished = true
      local ok, err = pcall(callback)
      if not ok then
        log("E", inputs.constants.logTag, "Thumbnail idle/timeout callback failed: " .. tostring(err))
      end
    end
    whenThumbnailsIdle(run)
    core_jobsystem.create(function(job)
      job.sleep(math.max(1, tonumber(timeoutSec) or 8))
      run()
    end, 1)
  end

  local function isThumbnailPending(packageId)
    if thumbnailState.capturingPackageId and tostring(thumbnailState.capturingPackageId) == tostring(packageId) then
      return true
    end
    for _, job in ipairs(thumbnailState.thumbnailQueue) do
      if tostring(job.packageId) == tostring(packageId) then
        return true
      end
    end
    return false
  end

  local function enqueueEngineThumbnail(package, inventoryId, callback)
    if stopped or not package or not inventoryId then
      if callback then callback(false) end
      return
    end
    if not packageInstalledOnInventory(package, inventoryId) then
      if callback then callback(false) end
      return
    end
    clearThumbnailCancel(package.id)
    if isThumbnailPending(package.id) then
      if callback then whenThumbnailsIdle(function() callback(true) end) end
      return
    end
    table.insert(thumbnailState.thumbnailQueue, {
      packageId = package.id,
      inventoryId = inventoryId,
      callback = callback
    })
    pumpThumbnailQueue()
  end

  local function packageNeedsThumbnail(package)
    if not package then return false end
    local failure = failedCaptures[tostring(package.id)]
    if failure and failure.recipe == tostring(package.updatedAt or 0)
      and (not failure.retryAfter or os.clock() < failure.retryAfter) then return false end
    return not inputs.packageThumbnailExists(package.id) or tonumber(package.thumbnailCaptureVersion) ~= inputs.constants.thumbnailCaptureVersion
  end

  -- Queues a capture for every package that lacks a current thumbnail and is installed on a spawned vehicle.
  local function maybeCaptureMissingThumbnails()
    for _, package in ipairs(inputs.packageStore.packages) do
      if packageNeedsThumbnail(package) then
        local status, installedInventoryId = inputs.getPackageStatus(package)
        local inventoryId = installedInventoryId
        if status == "installed" and inventoryId then
          local spawnedId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
          if not spawnedId and tonumber(inventoryId) == tonumber(inputs.packageStore.currentInventoryId) then
            spawnedId = overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inputs.packageStore.currentInventoryId)
            inventoryId = inputs.packageStore.currentInventoryId
          end
          if spawnedId then
            log("I", inputs.constants.logTag, "Queueing engine thumbnail for package " .. tostring(package.id) .. " on vehicle " .. tostring(inventoryId))
            enqueueEngineThumbnail(package, inventoryId)
          end
        end
      end
    end
  end

  -- Unload must not depend on inventory still being registered or a render callback arriving.
  local function stopCaptures()
    stopped = true
    captureGeneration = captureGeneration + 1
    pendingAfterIdle = {}
    renderState.waiters[pumpThumbnailQueue] = nil
    local queued = thumbnailState.thumbnailQueue
    thumbnailState.thumbnailQueue = {}
    if activeCapture then finishCapture(activeCapture, false, "career unloaded") end
    for _, request in ipairs(queued) do
      if request.callback then pcall(request.callback, false) end
    end
  end

  -- Public API -----------------------------------------------------------------------------------------

  return {
    stopCaptures = stopCaptures,
    resumeCaptures = function() stopped = false; failedCaptures = {} end,
    cancelThumbnailsForPackage = cancelThumbnailsForPackage,
    enqueueEngineThumbnail = enqueueEngineThumbnail,
    isolatedVehicleIds = isolatedVehicleIds,
    maybeCaptureMissingThumbnails = maybeCaptureMissingThumbnails,
    packageNeedsThumbnail = packageNeedsThumbnail,
    restoreVehiclePartVisibility = restoreVehiclePartVisibility,
    unhideInventoryVehicle = unhideInventoryVehicle,
    whenThumbnailsIdleOrTimeout = whenThumbnailsIdleOrTimeout,
  }
end

return thumbnails
