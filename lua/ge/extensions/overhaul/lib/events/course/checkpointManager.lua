-- Independent checkpoint triggers, marker colors and expected-checkpoint state.
-- Read scene ownership, marker primitives, route locking, lifecycle and injected live policy.
local factory = {}

function factory.create(inputs)
  inputs = inputs or {}
  local preview = inputs.preview == true
  local ownedObjects = {}
  local registeredObjects = {}
  local ownedGroup
  local instance = inputs.exports or {}


  -- State -------------------------------------------------------------------------------------------

  local checkpoints = {}
  local altCheckpoints = {}
  local aiAltCheckpoints = {}
  local raceName = nil
  local isLoop = false
  local mAltRoute = nil
  local mRouteLocked = false
  local mFixedAltUseMainColors = false
  local activeCheckpoints = {}

  local race

  -- Helpers -----------------------------------------------------------------------------------------

  local function sceneName(name)
    return preview and ("overhaul_editor_preview_" .. name) or name
  end

  local function deleteCourseObject(object)
    if not preview then object:delete(); return true end
    if not ownedObjects[object] then return false end
    local ok = pcall(function() object:delete() end)
    if ok then ownedObjects[object], registeredObjects[object] = nil, nil end
    return ok
  end

  local function replaceSceneObject(name)
    if not preview then
      if scenetree.findObject(name) then scenetree.findObject(name):delete() end
      return
    end
    local existing = scenetree.findObject(name)
    if not existing then return end
    -- Lua reload can lose tracking after native cleanup fails; this prefix belongs only to previews.
    if not ownedObjects[existing] then
      if name:sub(1, #"overhaul_editor_preview_") ~= "overhaul_editor_preview_" then
        error("Preview scene name is already owned: " .. name, 0)
      end
      ownedObjects[existing] = true
    end
    if not deleteCourseObject(existing) then error("Preview scene object could not be deleted: " .. name, 0) end
  end

  local function createCourseObject(className)
    local object = createObject(className)
    if preview then ownedObjects[object] = true end
    return object
  end

  local function registerCourseObject(object, name)
    object:registerObject(name)
    if preview then
      -- Registration reparents to MissionCleanup; transfer ownership afterwards.
      if not ownedGroup then
        ownedGroup = createObject("SimGroup")
        ownedGroup.canSave = false
        ownedGroup:registerObject("")
      end
      ownedGroup:addObject(object)
      registeredObjects[object] = true
    end
  end

  local function privateCheckpointRows(rows)
    local privateRows = {}
    for index, row in ipairs(rows or {}) do
      local privateRow = {}
      for key, value in pairs(row) do
        if key ~= "object" and key ~= "marker" and key ~= "markerShell" and key ~= "markerBase" then privateRow[key] = value end
      end
      if row.node then
        privateRow.node = {}
        for key, value in pairs(row.node) do privateRow.node[key] = value end
      end
      privateRows[index] = privateRow
    end
    return privateRows
  end

  local function setMarkerColor(marker, r, g, b)
    if not marker then return end
    marker.instanceColor = ColorF(r, g, b, 1):asLinear4F()
    if marker.updateInstanceRenderData then marker:updateInstanceRenderData() end
  end

  local function deleteMarkerObj(obj)
    if obj then pcall(function()
      deleteCourseObject(obj)
    end) end
  end

  -- Clears current marker plus any leftover shell/base from earlier experiments.
  local function clearCheckpointVisuals(checkpoint)
    if not checkpoint then return end
    deleteMarkerObj(checkpoint.marker)
    deleteMarkerObj(checkpoint.markerShell)
    deleteMarkerObj(checkpoint.markerBase)
    checkpoint.marker = nil
    checkpoint.markerShell = nil
    checkpoint.markerBase = nil
  end

  local function applyFallbackCheckpointWidth(checkpoint, index)
    if not checkpoint.node.width then
      log(
        "W",
        "checkpointManager",
        string.format(
          "Checkpoint width missing for race '%s' at index %d. Using fallback radius 30.",
          tostring(raceName),
          tonumber(index) or -1
        )
      )
      checkpoint.node.width = 30
    end
  end

  local function createCheckpoint(index, isAlt)
    local checkpoint
    if isAlt then
      checkpoint = altCheckpoints[index]
    else
      checkpoint = checkpoints[index]
    end
    if not checkpoint then
      log(
        "W",
        "checkpointManager",
        string.format(
          "Missing %s checkpoint data for race '%s' at index %d.",
          isAlt and "alt" or "main",
          tostring(raceName),
          tonumber(index) or -1
        )
      )
      return
    end
    if not checkpoint.node then
      log(
        "W",
        "checkpointManager",
        string.format("Checkpoint node missing for race '%s' at index %d.", tostring(raceName), tonumber(index) or -1)
      )
      return
    end

    applyFallbackCheckpointWidth(checkpoint, index)

    local position = vec3(checkpoint.node.x, checkpoint.node.y, checkpoint.node.z)
    local radius = checkpoint.node.width

    local triggerRadius = radius

    checkpoint.object = createCourseObject("BeamNGTrigger")
    checkpoint.object:setPosition(position)
    checkpoint.object:setScale(vec3(triggerRadius, triggerRadius, triggerRadius))
    checkpoint.object.triggerType = 0 -- Use 0 for Sphere type

    -- Naming the trigger according to the new scheme
    local triggerName
    if isAlt then
      triggerName = string.format("fre_checkpoint_%s_alt_%d", raceName, index)
    else
      triggerName = string.format("fre_checkpoint_%s_%d", raceName, index)
    end

    triggerName = sceneName(triggerName)
    replaceSceneObject(triggerName)
    registerCourseObject(checkpoint.object, triggerName)
    return checkpoint
  end

  local function createCheckpointMarker(index, alt)
    local checkpoint = alt and altCheckpoints[index] or checkpoints[index]
    if not checkpoint then
      log(
        "W",
        "checkpointManager",
        string.format(
          "Missing marker checkpoint data for race '%s' at index %d.",
          tostring(raceName),
          tonumber(index) or -1
        )
      )
      return
    end
    if not checkpoint.node then
      log(
        "W",
        "checkpointManager",
        string.format(
          "Checkpoint marker node missing for race '%s' at index %d.",
          tostring(raceName),
          tonumber(index) or -1
        )
      )
      return
    end

    clearCheckpointVisuals(checkpoint)

    local node = checkpoint.node
    local w = node.width or 30
    local markerName = (alt and "alt_" or "") .. "checkpoint_" .. index .. "_marker"
    markerName = sceneName(markerName)
    replaceSceneObject(markerName)

    local marker = createCourseObject("TSStatic")
    marker.shapeName = "art/shapes/interface/checkpoint_marker.dae"
    marker:setPosRot(node.x, node.y, node.z, 0, 0, 0, 0)
    marker.scale = vec3(w, w, w)
    marker.useInstanceRenderData = true
    marker:setField("instanceColor", 0, "1 1 1 1")
    marker.canSave = false
    registerCourseObject(marker, markerName)

    checkpoint.marker = marker
    setMarkerColor(marker, 1, 0.05, 0) -- default / next

    table.insert(activeCheckpoints, checkpoint)
    return checkpoint
  end

  local function removeCheckpointMarker(index, alt)
    local checkpoint = {}
    if alt then
      checkpoint = altCheckpoints[index]
    else
      checkpoint = checkpoints[index]
    end
    clearCheckpointVisuals(checkpoint)
    return checkpoint
  end

  local function removeCheckpoint(index, alt)
    local checkpoint = {}
    if alt then
      checkpoint = altCheckpoints[index]
    else
      checkpoint = checkpoints[index]
    end
    if checkpoint then
      if checkpoint.object then
        deleteCourseObject(checkpoint.object)
        checkpoint.object = nil
      end
      clearCheckpointVisuals(checkpoint)
    end
    return checkpoint
  end

  local function createAiAltTrigger(index, checkpointData)
    if not checkpointData or not checkpointData.node or not raceName then return end
    local w = (checkpointData.node.width and checkpointData.node.width > 0) and checkpointData.node.width or 30
    local pos = vec3(checkpointData.node.x, checkpointData.node.y, checkpointData.node.z)
    local triggerName = string.format("fre_checkpoint_%s_ai_alt_%d", raceName, index)
    triggerName = sceneName(triggerName)
    replaceSceneObject(triggerName)
    local obj = createCourseObject("BeamNGTrigger")
    obj:setPosition(pos)
    obj:setScale(vec3(w, w, w))
    obj.triggerType = 0
    registerCourseObject(obj, triggerName)
    return { object = obj, triggerName = triggerName }
  end

  local function removeAiAltCheckpoints()
    for i = 1, #aiAltCheckpoints do
      local entry = aiAltCheckpoints[i]
      if entry and entry.object then
        deleteCourseObject(entry.object)
        entry.object = nil
      end
    end
    aiAltCheckpoints = {}
  end

  local function adoptCheckpointRows(check, altCheck)
    if preview then
      if inputs.isCurrent and not inputs.isCurrent() then error("Preview instance is closed", 0) end
      for object in pairs(ownedObjects) do
        if not deleteCourseObject(object) then error("Preview cleanup failed before creation", 0) end
      end
      check, altCheck = privateCheckpointRows(check), privateCheckpointRows(altCheck)
    end
    return check, altCheck
  end

  local function notifyCheckpointsBuilt()
    local payload = {
      raceName = raceName,
      mainCount = #checkpoints,
      altCount = altCheckpoints and #altCheckpoints or 0,
    }
    if preview then
      if inputs.onCheckpointsBuilt then inputs.onCheckpointsBuilt(payload) end
    else
      extensions.hook("onFreeroamCheckpointsBuilt", payload)
    end
  end

  local function createCheckpoints(check, altCheck, aiAltCheck, routeOpts)
    check, altCheck = adoptCheckpointRows(check, altCheck)
    routeOpts = routeOpts or {}
    checkpoints = check
    altCheckpoints = altCheck or {}
    removeAiAltCheckpoints()
    if aiAltCheck and type(aiAltCheck) == "table" and #aiAltCheck > 0 then
      for i = 1, #aiAltCheck do
        local entry = createAiAltTrigger(i, aiAltCheck[i])
        if entry then table.insert(aiAltCheckpoints, entry) end
      end
    end

    for i = 1, #checkpoints do
      removeCheckpoint(i)
    end
    if altCheckpoints and #altCheckpoints > 0 then
      for i = 1, #altCheckpoints do
        removeCheckpoint(i, true)
      end
    end

    local omitAltTriggers = routeOpts.omitAltTriggers == true
    local mergeMainStart = tonumber(routeOpts.omitMainBeforeMerge)
    if mergeMainStart and mergeMainStart < 1 then mergeMainStart = nil end

    for i = 1, #checkpoints do
      if not mergeMainStart or i >= mergeMainStart then createCheckpoint(i) end
    end

    if not omitAltTriggers and altCheckpoints and #altCheckpoints > 0 then
      for i = 1, #altCheckpoints do
        createCheckpoint(i, true)
      end
    end
    notifyCheckpointsBuilt()

  end

  local function resetActiveCheckpoints()
    local checkpoint
    for i = 1, #activeCheckpoints do
      checkpoint = activeCheckpoints[i]
      clearCheckpointVisuals(checkpoint)
    end
    activeCheckpoints = {}
  end

  local function showAlternativeMergeMarker(index)
    if not mRouteLocked and race.altRoute and altCheckpoints and race.altRoute.mergeCheckpoints[1] == index[1] then
      if not altCheckpoints[1].marker then
        local altCheckpoint = createCheckpointMarker(1, true)
        if mFixedAltUseMainColors then
          setMarkerColor(altCheckpoint.marker, 0.15, 1, 0.2)
        else
          setMarkerColor(altCheckpoint.marker, 0.1, 0.35, 1)
        end
      end
    end
  end

  local function enableCheckpoint(checkpointIndex, alt)
    resetActiveCheckpoints()
    local ALT = { alt, alt }
    local index = { checkpointIndex, checkpointIndex + 1 }
    if isLoop then
      index = { index[1] % #checkpoints + 1, index[2] % #checkpoints + 1 }
    else
      index = { index[1] + 1, index[2] + 1 }
    end
    for i = 1, 2 do
      if ALT[i] then
        if #altCheckpoints < index[i] then
          index[i] = race.altRoute.mergeCheckpoints[2] + ((index[i] - 1) - #altCheckpoints)
          ALT[i] = false
        end
      end
    end
    local currentExpectedCheckpoint = index[1]
    local checkpoint = {}
    if ALT[1] then
      checkpoint = altCheckpoints[index[1]]
    else
      checkpoint = checkpoints[index[1]]
    end
    local nextCheckpoint = nil
    local checkpointCount = ALT[2] and #altCheckpoints or #checkpoints
    if checkpointCount > 1 then
      if ALT[2] then
        nextCheckpoint = altCheckpoints[index[2]]
      else
        nextCheckpoint = checkpoints[index[2]]
      end
    end

    if checkpoint then
      if not checkpoint.marker then checkpoint = createCheckpointMarker(index[1], ALT[1]) end
      local currentMainStyle = not ALT[1] or mFixedAltUseMainColors
      if currentMainStyle then
        setMarkerColor(checkpoint.marker, 0.15, 1, 0.2) -- neon green
      else
        setMarkerColor(checkpoint.marker, 0.1, 0.35, 1) -- blue
      end

      showAlternativeMergeMarker(index)

      if nextCheckpoint then
        if not nextCheckpoint.marker then nextCheckpoint = createCheckpointMarker(index[2], ALT[2]) end
        setMarkerColor(nextCheckpoint.marker, 1, 0.05, 0) -- red
      end
    end
    return currentExpectedCheckpoint
  end

  local function removeCheckpoints()
    local function removeCheckpointList(checkpointList)
      if not checkpointList or #checkpointList == 0 then return end

      for i = 1, #checkpointList do
        local checkpoint = checkpointList[i]
        if checkpoint then
          -- Remove the checkpoint object
          if checkpoint.object then
            pcall(function()
              deleteCourseObject(checkpoint.object)
            end)
            checkpoint.object = nil
          end

          -- Remove the checkpoint marker visuals (ring + shell + base)
          clearCheckpointVisuals(checkpoint)
        end
      end

      -- Clear the checkpoint list
      for i = 1, #checkpointList do
        checkpointList[i] = nil
      end
    end

    resetActiveCheckpoints()
    removeAiAltCheckpoints()

    -- Remove main checkpoints
    removeCheckpointList(checkpoints)

    -- Remove alternative checkpoints
    removeCheckpointList(altCheckpoints)

    checkpoints = {}
    altCheckpoints = {}
    race = nil
    mAltRoute = nil
    mRouteLocked = false
    mFixedAltUseMainColors = false
    if preview then
      for object in pairs(ownedObjects) do
        deleteCourseObject(object)
      end
      if ownedGroup then
        local removed = pcall(function() ownedGroup:delete() end)
        if removed then
          ownedGroup = nil
          for object in pairs(registeredObjects) do ownedObjects[object] = nil end
          registeredObjects = {}
        end
      end
      return ownedGroup == nil and next(ownedObjects) == nil
    end
  end

  local function calculateTotalCheckpoints()
    local mainCount = #checkpoints
    local altCount = altCheckpoints and #altCheckpoints or 0
    local mergePoints = (race and race.altRoute and race.altRoute.mergeCheckpoints) or { 0, 0 }

    -- If the player is on the alt route, adjust total checkpoints accordingly
    local total
    if mAltRoute then
      total = altCount + (mainCount - mergePoints[2] + mergePoints[1])
    else
      total = mainCount
    end

    return total
  end

  local function setRouteLocked(locked)
    mRouteLocked = locked
  end

  local function setAltRoute(altRoute)
    mAltRoute = altRoute
  end

  local function setRace(inputRace, inputRaceName)
    race = inputRace
    raceName = inputRaceName
  end

  local function getAltCheckpointCount()
    return altCheckpoints and #altCheckpoints or 0
  end

  local function getAiAltCheckpointCount()
    return aiAltCheckpoints and #aiAltCheckpoints or 0
  end

  local function notifyCheckpointEntered(payload)
    if not preview then extensions.hook("onFreeroamCheckpointEntered", payload) end
  end

  local function prepareSessionCheckpointRoutes(racePayload, sessionRaceName, competitiveCircuit)
    local sanctionedRacing = inputs.getSanctionedRacing and inputs.getSanctionedRacing()
    local sanctionedCircuit = sanctionedRacing
      and sanctionedRacing.isSanctionedCircuitRaceActive
      and sanctionedRacing.isSanctionedCircuitRaceActive()
      and (competitiveCircuit == true or (type(competitiveCircuit) == "string" and sessionRaceName == competitiveCircuit))
    mFixedAltUseMainColors = false
    local routeOpts = nil
    if sanctionedCircuit then
      routeOpts = {}
      setRouteLocked(true)
      local useAltOffer = sanctionedRacing.isSanctionedCircuitRaceUseAltRoute and sanctionedRacing.isSanctionedCircuitRaceUseAltRoute()
      if useAltOffer then
        mFixedAltUseMainColors = true
        local mergeCheckpoints = racePayload.altRoute and racePayload.altRoute.mergeCheckpoints
        local mainMergeCheckpointIndex = mergeCheckpoints and tonumber(mergeCheckpoints[2])
        if mainMergeCheckpointIndex and mainMergeCheckpointIndex > 0 then routeOpts.omitMainBeforeMerge = math.floor(mainMergeCheckpointIndex) end
      else
        routeOpts.omitAltTriggers = true
      end
    else
      setRouteLocked(false)
    end
    return sanctionedCircuit, routeOpts, sanctionedRacing
  end


  -- Public API --------------------------------------------------------------------------------------

  instance.notifyCheckpointEntered = notifyCheckpointEntered
  instance.createCheckpoints = createCheckpoints
  instance.enableCheckpoint = enableCheckpoint
  instance.removeCheckpoints = removeCheckpoints
  instance.setRouteLocked = setRouteLocked
  instance.setAltRoute = setAltRoute
  instance.setRace = setRace
  instance.calculateTotalCheckpoints = calculateTotalCheckpoints
  instance.getAltCheckpointCount = getAltCheckpointCount
  instance.getAiAltCheckpointCount = getAiAltCheckpointCount

  return {api = instance, prepareSessionCheckpointRoutes = prepareSessionCheckpointRoutes}
end

return factory
