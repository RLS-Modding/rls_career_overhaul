-- VE bridge: damage snapshots, structural detection and actuator pose.
-- Map: rest state and latches, part/ID maps, damage and pose capture, restoration, lifecycle hooks.
-- overhaulVehicleState.lua returns pose with inventory conditions during career activity.
local M = {}

local damageData = {}

local nodeIDconvert = {}
local beamIDconvert = {}
local hydrosIDconvert = {}
local SNAPSHOT_PRECISION = 100000
-- Healthy settling yielded up to 2.4 mm in the measured cars; unflagged dents began at 5 mm.
local PLASTIC_CHANGE_METERS = 0.003
local mechanismBeamIds = {}
local actuatorBeamIds = {}
local drivenBeamIds = {}
local controllerBeamIds = {}
local initialHydroStates = {}
local originalBeamLengths = {}

local function rounded(value)
  return math.floor(value * SNAPSHOT_PRECISION + 0.5) / SNAPSHOT_PRECISION
end

local function beamHydroCid(hydro)
  -- Torsion hydros use another id namespace; older beam-hydro snapshots used cid.
  if hydro.center == 0 then return nil end
  return hydro.beamCID or hydro.cid
end

local function registerDrivenBeams(cids)
  for _, cid in pairs(cids or {}) do
    if v.data.beams[cid] then
      mechanismBeamIds[cid], actuatorBeamIds[cid], drivenBeamIds[cid] = true, true, true
    end
  end
end

local function discoverDrivenBeams(device, visited)
  if type(device) ~= 'table' or visited[device] then return end
  visited[device] = true
  registerDrivenBeams(device.beamCids)
  registerDrivenBeams(device.actuatorBeams)
  -- Pump consumers own their cylinders but are not separate powertrain devices.
  for _, consumer in pairs(device.connectedConsumers or {}) do discoverDrivenBeams(consumer, visited) end
  if device.type == 'electricWinch' then
    -- Stock's prototype winch actuates the first ropeTest beam directly rather than exposing a beam list.
    local rope = beamstate and beamstate.tagBeamMap and beamstate.tagBeamMap.ropeTest
    if rope and rope[1] then registerDrivenBeams({rope[1]}) end
  end
end

local function discoverHydraulicControllers()
  for _, definition in pairs(v.data.controller or {}) do
    if definition.fileName == 'hydraulicSuspension' then
      local names = {}
      for _, entry in pairs(v.data[definition.hydraulicBeams or 'hydraulicsData'] or {}) do
        if entry.beamName then names[entry.beamName] = true end
      end
      for _, beam in pairs(v.data.beams) do
        if beam.name and names[beam.name] then
          registerDrivenBeams({beam.cid})
          controllerBeamIds[beam.cid] = true
        end
      end
    end
  end
end

local function captureUndeformedRestState()
  -- Load before applying saved conditions: suspension precompression is already part of a healthy spawn.
  for _, beam in pairs(v.data.beams) do
    originalBeamLengths[beam.cid] = obj:getBeamRestLength(beam.cid)
    if beam.wheelID ~= nil or beam.beamType == 3 or beam.beamType == 6 then mechanismBeamIds[beam.cid] = true end
  end
  for _, hydro in pairs(hydros.hydros or {}) do
    local cid = beamHydroCid(hydro)
    if cid then
      mechanismBeamIds[cid], actuatorBeamIds[cid] = true, true
      initialHydroStates[cid] = hydro.state
    end
  end
  local visited = {}
  for _, device in pairs(powertrain and powertrain.getDevices and powertrain.getDevices() or {}) do
    discoverDrivenBeams(device, visited)
  end
  discoverHydraulicControllers()
end

local function hasPlasticChange(beam, length)
  local original = originalBeamLengths[beam.cid]
  local structural = beam.beamType == nil or beam.beamType == 0 or beam.beamType == 1
  return structural and not mechanismBeamIds[beam.cid] and original and original > 0
    and math.abs(length - original) > PLASTIC_CHANGE_METERS
end

local function nativeDeformation(beam)
  if mechanismBeamIds[beam.cid] or obj:beamIsBroken(beam.cid) then return nil end
  -- Only callbacks recorded in the live condition tracker may alter part condition on restore.
  local tracker = beamstate and beamstate.deformedBeams
  local value = tracker and tracker[beam.cid] or (not tracker and obj:getBeamDeformation(beam.cid))
  return value and value ~= 0 and value or nil
end

local function latchControllers()
  return controller and controller.getControllersByType and controller.getControllersByType('advancedCouplerControl') or {}
end

local function captureLatches()
  local states, pairsByName = {}, {}
  for _, latch in ipairs(latchControllers()) do
    for key, value in pairs(latch.getState() or {}) do states[key] = value end
  end
  local vehicleId = objectId or (obj.getId and obj:getId())
  for cid, attached in pairs(beamstate and beamstate.attachedCouplers or {}) do
    local first, second = v.data.nodes[cid], v.data.nodes[attached.obj2nodeId]
    if attached.obj2id == vehicleId and first and second and first.name and second.name then
      pairsByName[first.name] = second.name
    end
  end
  return {states = states, attached = pairsByName}
end

local function restoreLatches(saved)
  if not saved then return end
  local restored = {}
  for _, latch in ipairs(latchControllers()) do latch.setState(saved.states or {}) end
  -- Commit can discard the native constraints without updating the controller's attached state.
  -- Recreate only saved local pairs, using the latch's own force limits; external hitches stay caller-owned.
  local byName = {}
  for _, node in pairs(v.data.nodes) do if node.name then byName[node.name] = node.cid end end
  for _, definition in ipairs(v.data.controller or {}) do
    if definition.fileName == 'advancedCouplerControl' then
      for _, pair in ipairs(tableFromHeaderTable(definition.couplerNodes or {})) do
        local targetName = saved.attached and saved.attached[pair.cid1]
        local cid1, cid2 = byName[pair.cid1], byName[targetName]
        if cid1 and cid2 then
          local radius = math.max(pair.autoCouplingRadius or 0.01, obj:nodeLength(cid1, cid2) + 0.001)
          obj:attachLocalCoupler(cid1, cid2, pair.autoCouplingStrength or 40000, radius,
            pair.autoCouplingLockRadius or 0.005, pair.autoCouplingSpeed or 0.2, true)
          restored[math.min(cid1, cid2) .. ':' .. math.max(cid1, cid2)] = true
        end
      end
    end
  end
  -- Locked internal mounts are constraints too; commitLoad discards their native attachment.
  for first, second in pairs(saved.attached or {}) do
    local a, b = byName[first], byName[second]
    if a ~= nil and b ~= nil then
      local key = math.min(a, b) .. ':' .. math.max(a, b)
      local na, nb = v.data.nodes[a], v.data.nodes[b]
      -- Beamstate also marks the receiving node as locked; prefer the authored coupling source.
      local source = na.couplerTag and na or (nb.couplerTag and nb)
      if not source then
        source = (na.couplerLock or na.couplerWeld) and na
          or ((nb.couplerLock or nb.couplerWeld) and nb)
      end
      if source and (source.couplerLock or source.couplerWeld) and not restored[key] then
        restored[key] = true
        local radius = math.max(source.couplerRadius or 0.2, obj:nodeLength(a, b) + 0.001)
        if source.couplerTag then
          -- Tagged mounts use the same attachment path as beamstate initialization.
          obj:attachCoupler(source.cid, source.couplerTag, source.couplerStrength or 1000000, radius,
            source.couplerLockRadius or 0.025, source.couplerLatchSpeed or 0.3, source.couplerTargets or 0)
        else
          local target = source == na and b or a
          obj:attachLocalCoupler(source.cid, target, source.couplerStrength or 1000000, radius,
            source.couplerLockRadius or 0.025, source.couplerLatchSpeed or 0.3, true)
        end
      end
    end
  end
end
local function getParentPath(path)
  local lastSlash = path:find("/[^/]*$")
  if lastSlash then
    return path:sub(1, lastSlash)
  end
  return "/"
end

local mechanisms = require('vehicle/overhaul/mechanismState').new({
  vehicle=function() return v end, object=function() return obj end,
  warn=function(message) log('W','overhaulDamageState.mechanism',message) end,
  devices=function() return powertrain and powertrain.getDevices and powertrain.getDevices() or {} end,
  hydros=function() return hydros.hydros or {} end,
  electrics=function() return electrics and electrics.values or {} end,
  controllers=function()
    local controls = {}
    if controller and controller.getControllersByType then
      local kinds = {}
      for _, definition in pairs(v.data.controller or {}) do
        local kind = definition.fileName
        if kind == 'hydraulicSuspension' or kind == 'hydraulics/hydraulicTrailerFeet' then kinds[kind] = true end
      end
      for kind in pairs(kinds) do
        for _, control in pairs(controller.getControllersByType(kind) or {}) do controls[#controls+1] = control end
      end
    end
    return controls
  end,
  actuatorIds=actuatorBeamIds, drivenIds=drivenBeamIds, controllerIds=controllerBeamIds,
  initialHydros=initialHydroStates, captureLatches=captureLatches, restoreLatches=restoreLatches,
})

local function shouldProcessPart(partPath, pathsTable)
  if not partPath or not pathsTable then
    return false
  end

  for checkPath, _ in pairs(pathsTable) do
    if partPath == checkPath then
      return true
    end
  end
  return false
end

local function omitRepairedLatches(saved, partsToRepair, partsToRemove)
  if not partsToRepair and not partsToRemove then return end
  local changed = {}
  for _, node in pairs(v.data.nodes) do
    local path = getParentPath(node.partPath or '/')
    if shouldProcessPart(path, partsToRepair) or shouldProcessPart(path, partsToRemove) then
      if node.name then changed[node.name] = true end
    end
  end
  for first, second in pairs(saved.attached or {}) do
    if changed[first] or changed[second] then saved.attached[first] = nil end
  end
  -- A replaced panel keeps its fresh latch state, including when the saved latch was broken.
  for _, definition in ipairs(v.data.controller or {}) do
    if definition.fileName == 'advancedCouplerControl' then
      for _, pair in ipairs(tableFromHeaderTable(definition.couplerNodes or {})) do
        local replaced = changed[pair.cid1]
        for _, name in pairs(type(pair.cid2) == 'table' and pair.cid2 or {pair.cid2}) do
          replaced = replaced or changed[name]
        end
        if replaced then saved.states[(definition.name or definition.fileName)..'_groupState'] = nil end
      end
    end
  end
end

local function separateByPart(inputTable)
  local outputTable = {}
  for _, state in pairs(inputTable or {}) do
    if not state.partPath then
      log("W", "overhaulDamageState", "No part path found for: " .. tostring(state.cid))
      goto continue
    end
    local parentPath = getParentPath(state.partPath)
    if not outputTable[parentPath] then
      outputTable[parentPath] = {}
    end
    table.insert(outputTable[parentPath], state)
    ::continue::
  end
  return outputTable
end

local function getWheelNodes()
  local wheelNodes = {}
  for i, wheel in pairs(v.data.wheels) do
    if wheel.nodes then
      for index, node in ipairs(wheel.nodes) do
        wheelNodes[node] = "wheel" .. i .. "_node" .. index
      end
    end
    if wheel.treadNodes then
      for index, node in ipairs(wheel.treadNodes) do
        wheelNodes[node] = "wheel" .. i .. "_treadNode" .. index
      end
    end
  end
  return wheelNodes
end

local function defaultSaveFile()
  local model = tostring(v.data.vehicleDirectory or ""):match("([^/]+)/*$") or "vehicle"
  return "/temp/rls_career/individualRepair/" .. model .. ".rls_save.json"
end

-- JBeam node and beam membership stays fixed for the lifetime of this vehicle.
local partIndex

local function getPartIndex()
  if partIndex then return partIndex end
  local rootPartPath = v.config and v.config.partsTree and v.config.partsTree.partPath or "/"
  local index = {}
  local function entry(partPath)
    local key = getParentPath(partPath or rootPartPath)
    index[key] = index[key] or {nodes = {}, beams = {}}
    return index[key]
  end
  for _, node in pairs(v.data.nodes) do table.insert(entry(node.partPath).nodes, node) end
  for _, beam in pairs(v.data.beams) do table.insert(entry(beam.partPath).beams, beam) end
  partIndex = index
  return index
end

local function hasStructuralDamage()
  for _, part in pairs(getPartIndex()) do
    for _, beam in ipairs(part.beams) do
      if obj:beamIsBroken(beam.cid) or nativeDeformation(beam)
          or hasPlasticChange(beam, obj:getBeamRestLength(beam.cid)) then return true end
    end
  end
  -- Fuel consumption and payload mass change healthy nodes; they are saved with damage but do not diagnose it.
  return false
end

-- Reuse the previous capture when no damage event or Lua-state change invalidated it.
local changeCount = 0
-- A caller may reuse its snapshot, but this cache must not keep saved geometry alive.
-- The metadata never references its weak key, so both payload and signatures can be collected.
local lastCapture = setmetatable({}, {__mode = 'k'})

-- Plastic yielding need not emit a deform callback; cached geometry must still match the live nodes and lengths.
local function geometrySignature()
  local values = {}
  for _, node in pairs(v.data.nodes) do
    local position = obj:getNodePosition(node.cid):toTable()
    for _, value in ipairs(position) do values[#values + 1] = rounded(value) end
    values[#values + 1] = obj:getNodeMass(node.cid)
  end
  for _, beam in pairs(v.data.beams) do
    values[#values + 1] = rounded(obj:getBeamRestLength(beam.cid))
    values[#values + 1] = obj:beamIsBroken(beam.cid) and 'broken' or 'intact'
    values[#values + 1] = obj:getBeamDeformation(beam.cid)
  end
  for _, hydro in pairs(hydros.hydros) do values[#values + 1] = hydro.state end
  return table.concat(values, ',')
end

local function markChanged()
  changeCount = changeCount + 1
end

local function captureDamageSnapshot(luaState, mechanismState)
  local wheelNodes = getWheelNodes()
  local rootPartPath = v.config and v.config.partsTree and v.config.partsTree.partPath or "/"
  local index = getPartIndex()

  local save = {}
  save.format = "rls_v1"
  save.deformationSource = 'beamstate'
  save.model = v.data.model
  save.luaState = luaState
  save.rotation = quat(obj:getRotation()):toTable()
  save.latches = captureLatches()
  save.mechanismState = mechanismState

  save.partStates = {}

  -- Neighbouring parts must return to the same shape or their connecting beams tear on restore.
  for key, part in pairs(index) do
    local partState = {}
    if part.nodes[1] then
      partState.nodes = {}
      for _, node in ipairs(part.nodes) do
        if not node.name then
          if wheelNodes[node.cid] then
            node.name = wheelNodes[node.cid]
          else
            log("W", "overhaulDamageState", "No name found for: " .. tostring(node.cid) .. " " .. tostring(node.partPath))
          end
        end
        local position = obj:getNodePosition(node.cid):toTable()
        for axis, value in pairs(position) do position[axis] = rounded(value) end
        partState.nodes[node.cid] = {
          pos = position,
          name = node.name,
          mass = math.abs(obj:getOriginalNodeMass(node.cid) - obj:getNodeMass(node.cid)) > 0.1 and obj:getNodeMass(node.cid) or
            nil
        }
      end
    end
    if part.beams[1] then
      partState.beams = {}
      for _, beam in ipairs(part.beams) do
        local length = obj:getBeamRestLength(beam.cid)
        partState.beams[beam.cid] = {
          length = rounded(length),
          broken = obj:beamIsBroken(beam.cid) and true or nil,
          deformed = nativeDeformation(beam),
          idents = {beam.id1, beam.id2, beam.beamType}
        }
      end
    end
    save.partStates[key] = partState
    ::nextPart::
  end
  return rootPartPath, save
end

local function captureMechanismState()
  local pose = mechanisms.capture()
  -- Observe control pulses between saves; returning the input to neutral must not hide a deliberate change.
  if pose and enablePhysicsStepHook then enablePhysicsStepHook() end
  return pose
end

local function saveDamageData(filename)
  if filename == nil then
    filename = defaultSaveFile()
    FS:directoryCreate("/temp/rls_career/individualRepair/", true)
  end

  local luaState = serialize(serializePackages("save"))
  local latchState = serialize(captureLatches())
  local geometry = geometrySignature()
  local mechanismState = mechanisms.capture()
  local controls = mechanismState and serialize(mechanismState) or ''
  local previousSave, previous = next(lastCapture)
  if previous and previous.changeCount == changeCount and previous.luaState == luaState
      and previous.geometry == geometry and previous.latchState == latchState and previous.controls == controls then
    jsonWriteFile(filename, previousSave, false)
    return previousSave
  end

  local rootPartPath, save = captureDamageSnapshot(luaState, mechanismState)

  -- Hydro positions (tipper beds, roofs) are restored for every part, damaged or not.
  for _, hydro in pairs(hydros.hydros) do
    local cid = beamHydroCid(hydro)
    if not cid then goto nextHydro end
    local parentPath = getParentPath(hydro.partPath or rootPartPath)
    save.partStates[parentPath] = save.partStates[parentPath] or {}
    save.partStates[parentPath].hydros = save.partStates[parentPath].hydros or {}
    save.partStates[parentPath].hydros[cid] = {
      idents = {hydro.id1, hydro.id2, hydro.beamType},
      state = hydro.state
    }
    ::nextHydro::
  end

  local savedParts = 0
  for _ in pairs(save.partStates) do
    savedParts = savedParts + 1
  end
  log("I", "overhaulDamageState", "Saved " .. savedParts .. " parts")

  jsonWriteFile(filename, save, false)
  if previousSave then lastCapture[previousSave] = nil end
  lastCapture[save] = {changeCount = changeCount, luaState = luaState, geometry = geometry, latchState = latchState, controls = controls}
  return save
end

local function loadNodeIDconvert(separateOldNodes)
  local nodeConvert = {}

  local wheelNodes = getWheelNodes()

  local cidByName, savedNodeIds = {}, {}
  for _, state in pairs(separateOldNodes) do
    for cid in pairs(state.nodes or {}) do savedNodeIds[tostring(cid)] = true end
  end
  for newCid = 0, tableSizeC(v.data.nodes) - 1 do
    local newNode = v.data.nodes[newCid]
    if newNode then
      -- Older partial snapshots may reference endpoints whose node records were not saved.
      if not savedNodeIds[tostring(newCid)] then nodeConvert[tostring(newCid)] = newCid end
      if not newNode.name and wheelNodes[newNode.cid] then
        newNode.name = wheelNodes[newNode.cid]
      end
      if newNode.name and cidByName[newNode.name] == nil then
        cidByName[newNode.name] = newNode.cid
      end
    end
  end

  local partCount = 0
  for partPath, state in pairs(separateOldNodes) do
    partCount = partCount + 1
    local nodes = state.nodes
    if nodes then
      for cid, oldNode in pairs(nodes) do
        local newCid = oldNode.name and cidByName[oldNode.name]
        if not oldNode.name then
          local current = v.data.nodes[tonumber(cid)]
          if current and not current.name and getParentPath(current.partPath or '/') == partPath then
            newCid = current.cid
          end
        end
        if newCid ~= nil then
          nodeConvert[tostring(cid)] = newCid
        end
      end
    end
  end
  log("I", "overhaulDamageState", "Checked " .. partCount .. " parts")
  return nodeConvert
end

local function mapSavedPartBeamIds(separateOldBeams, isHydro, separateNewBeams)
  local conversion = isHydro and hydrosIDconvert or beamIDconvert
  local function currentCid(beam)
    if isHydro then return beamHydroCid(beam) end
    return beam.cid
  end
  for partPath, states in pairs(separateOldBeams) do
    local current = {}
    for _, beam in ipairs(separateNewBeams[partPath] or {}) do
      if currentCid(beam) ~= nil then current[#current + 1] = beam end
    end
    local saved
    if isHydro then saved = states.hydros else saved = states.beams end
    if #current > 0 and saved then
      local used, ordered = {}, {}
      for cid, beam in pairs(saved) do
        ordered[#ordered + 1] = {cid = cid, beam = beam}
      end
      table.sort(ordered, function(a, b) return tonumber(a.cid) < tonumber(b.cid) end)
      table.sort(current, function(a, b)
        return currentCid(a) < currentCid(b)
      end)
      local function matches(old, candidate)
        local first = nodeIDconvert[tostring(old.idents[1])]
        local second = nodeIDconvert[tostring(old.idents[2])]
        return first ~= nil and second ~= nil and candidate.beamType == old.idents[3]
          and ((candidate.id1 == first and candidate.id2 == second)
            or (candidate.id1 == second and candidate.id2 == first))
      end
      local function assign(entry, candidate)
        local cid = currentCid(candidate)
        if cid == nil or used[cid] or not matches(entry.beam, candidate) then return false end
        conversion[entry.cid], used[cid] = cid, true
        return true
      end
      -- Keep verified IDs before remapping: parallel beams can have different lengths and limits.
      for _, entry in ipairs(ordered) do
        for _, candidate in ipairs(current) do
          local cid = currentCid(candidate)
          if cid == tonumber(entry.cid) and assign(entry, candidate) then break end
        end
      end
      -- If compilation shifted IDs, preserve occurrence order and consume each destination once.
      for _, entry in ipairs(ordered) do
        if conversion[entry.cid] == nil then
          for _, candidate in ipairs(current) do
            if assign(entry, candidate) then break end
          end
        end
      end
    end
  end
end

local function loadBeamIDconvert(separateOldBeams, hydros)
  if not separateOldBeams or separateOldBeams == {} then
    return
  end

  local separateNewBeams
  if hydros then
    separateNewBeams = separateByPart(v.data.hydros)
  else
    separateNewBeams = separateByPart(v.data.beams)
  end

  -- Process each part's beams
  mapSavedPartBeamIds(separateOldBeams, hydros, separateNewBeams)

  return hydros and hydrosIDconvert or beamIDconvert
end

local function getBeamsToChange(partStates, partsToChange)
  if not partsToChange then
    return {}
  end
  local changedNodes = {}
  for partPath, state in pairs(partStates) do
    if partsToChange and shouldProcessPart(partPath, partsToChange) then
      if state.nodes then
        for cid, node in pairs(state.nodes) do
          if node.name then
            changedNodes[tonumber(cid)] = partPath
          end
        end
      end
    end
  end
  local beamsToChange = {}
  for partPath, state in pairs(partStates) do
    if state.beams then
      for cid, beam in pairs(state.beams) do
        if beam.idents[1] and beam.idents[2] then
          if changedNodes[beam.idents[1]] and changedNodes[beam.idents[2]] then
            goto nextBeam
          elseif changedNodes[beam.idents[1]] then
            local node = partStates[changedNodes[beam.idents[1]]].nodes[tostring(beam.idents[1])]
            if node then
              beamsToChange[tonumber(cid)] = {
                node = beam.idents[1],
                pos = vec3(node.pos)
              }
            end
          elseif changedNodes[beam.idents[2]] then
            local node = partStates[changedNodes[beam.idents[2]]].nodes[tostring(beam.idents[2])]
            if node then
              beamsToChange[tonumber(cid)] = {
                node = beam.idents[2],
                pos = vec3(node.pos)
              }
            end
          end
        end
        ::nextBeam::
      end
    end
  end
  return beamsToChange
end

local function planDamageRestoration(partsToRepair, partsToRemove, save)
  local currentRotation = quat(obj:getRotation())
  local saveRotation = quat(save.rotation)

  -- Calculate the rotation needed to go from saved rotation to current rotation
  -- BeamNG composes quaternions left to right: remove the saved rotation, then apply the current pose.
  local rotationDifference = saveRotation:inversed() * currentRotation

  -- Adjust beam lengths
  local beamsToAdjust = getBeamsToChange(save.partStates, partsToRepair)
  local beamsToRemove = getBeamsToChange(save.partStates, partsToRemove)
  
  for partPath, state in pairs(save.partStates) do
    if partsToRemove and shouldProcessPart(partPath, partsToRemove) then
      log("D", "overhaulDamageState", "Skipping part: " .. partPath .. " because it is in the partsToRemove list")
      save.partStates[partPath] = nil
    end
    if partsToRepair and shouldProcessPart(partPath, partsToRepair) then
      log("D", "overhaulDamageState", "Skipping part: " .. partPath .. " because it is in the partsToRepair list")
      save.partStates[partPath] = nil
    end
  end

  if save.format ~= 'rls_pose_v1' then importPersistentData(save.luaState) end
  beamIDconvert = {}
  hydrosIDconvert = {}
  nodeIDconvert = loadNodeIDconvert(save.partStates)
  beamIDconvert = loadBeamIDconvert(save.partStates) or beamIDconvert
  hydrosIDconvert = loadBeamIDconvert(save.partStates, true) or hydrosIDconvert
  return rotationDifference, beamsToAdjust, beamsToRemove
end

local function restoreNativeDeformation(save, beam, cid)
  if not beam.deformed or beam.broken or mechanismBeamIds[cid] then return end
  local definition = v.data.beams[cid]
  if not definition then return end
  if not save.deformationSource then
    -- Older full snapshots synthesized ratios from authored dimensions, including healthy precompression.
    local authored = definition.beamLength or definition.restLength
    if not authored then
      local first, second = v.data.nodes[definition.id1], v.data.nodes[definition.id2]
      if first and second and first.pos and second.pos then authored = (vec3(first.pos) - vec3(second.pos)):length() end
    end
    if authored and authored > 0
        and math.abs(beam.deformed - math.abs(beam.length - authored) / authored) < 0.00002 / authored then return end
  end
  if not beamstate.deformedBeams or beamstate.deformedBeams[cid] ~= beam.deformed then
    beamstate.onBeamDeformed(cid, beam.deformed)
  end
end

local function restoreSavedPartDamage(save, rotationDifference, beamsToAdjust, beamsToRemove)
  for partPath, state in pairs(save.partStates) do
    if save.partStates[partPath].nodes then
      for cid, node in pairs(state.nodes) do
        local newCID = nodeIDconvert[tostring(cid)]
        if newCID then
          -- Apply rotation difference to the node position
          local nodePos = vec3(node.pos)
          local rotatedPos = rotationDifference * nodePos

          -- Set the rotated position
          obj:setNodePosition(newCID, rotatedPos)

          if node.mass then
            obj:setNodeMass(newCID, node.mass)
          end
        end
      end
    end
    if save.partStates[partPath].beams then
      for cid, beam in pairs(state.beams) do
        if beamsToAdjust[tonumber(cid)] or beamsToRemove[tonumber(cid)] then
          log("D", "overhaulDamageState", "Skipping beam: " .. tostring(cid) .. " because it is in the beamsToAdjust or beamsToRemove list")
          goto nextBeam
        end
        local targetCid = beamIDconvert[cid]
        if targetCid == nil then goto nextBeam end
        if beam.length > 0 then
          obj:setBeamLength(targetCid, beam.length)
        end
        if beam.broken then
          obj:breakBeam(targetCid)
        end
        restoreNativeDeformation(save, beam, targetCid)
        ::nextBeam::
      end
    end
    if save.partStates[partPath].hydros then
      if state.hydros then
        for cid, hydro in pairs(state.hydros) do
          -- JSON keys are strings; hydro cids are numbers
          local targetCid = hydrosIDconvert[cid]
          for k, h in pairs(hydros.hydros or {}) do
            if targetCid ~= nil and beamHydroCid(h) == targetCid then
              h.state = hydro.state
              break
            end
          end
        end
      end
    end
  end
end

local function loadDamageData(filename, partsToRepair, partsToRemove)
  if filename == nil then
    filename = defaultSaveFile()
  end

  local save = jsonReadFile(filename)
  if not save then
    log("E", "overhaulDamageState.load", "Invalid save file: " .. filename)
    return
  end

  if save.format ~= "rls_v1" then
    log("E", "overhaulDamageState.load", "Invalid save format: " .. tostring(save.format))
    return
  end

  if save.model ~= v.data.model then
    log("E", "overhaulDamageState.load", "Invalid model: " .. tostring(save.model))
    return
  end

  local latches = save.latches or captureLatches()
  mechanisms.cancel()
  omitRepairedLatches(latches, partsToRepair, partsToRemove)
  -- Calculate rotation difference between saved and current orientation
  local rotationDifference, beamsToAdjust, beamsToRemove = planDamageRestoration(partsToRepair, partsToRemove, save)

  restoreSavedPartDamage(save, rotationDifference, beamsToAdjust, beamsToRemove)

  obj:commitLoad()
  restoreLatches(latches)
  -- The complete snapshot already restores every connected part coherently; control motion is pose-only.
  markChanged()
end

local function restoreMechanismState(pose)
  -- Stock leaves extension physics callbacks disabled until an extension explicitly requests them.
  if enablePhysicsStepHook then enablePhysicsStepHook() end
  mechanisms.restore(pose)
  markChanged()
end

M.getNodeIDconvert = function()
  return nodeIDconvert
end

M.getBeamIDconvert = function()
  return beamIDconvert
end

M.getHydrosIDconvert = function()
  return hydrosIDconvert
end

M.saveDamageData = saveDamageData
M.hasStructuralDamage = hasStructuralDamage
M.loadDamageData = loadDamageData
M.captureMechanismState = captureMechanismState
M.restoreMechanismState = restoreMechanismState
M.getMechanismRestoreState = mechanisms.state
M.cancelMechanismRestore = mechanisms.cancel
M.onPhysicsStep = mechanisms.update
M.onBeamBroke = markChanged
M.onBeamDeformed = markChanged
M.onTorsionbarBroken = markChanged
M.onReset = function() mechanisms.cancel(); markChanged() end
M.onExtensionLoaded = captureUndeformedRestState


M.saveData = damageData

-- Test reset function
M.reset = function()
  mechanisms.cancel()
  markChanged()
  for save in pairs(lastCapture) do lastCapture[save] = nil end
  -- Cleared in place: M.saveData is this same table, so it must never be replaced.
  for key in pairs(damageData) do damageData[key] = nil end
  nodeIDconvert = {}
  beamIDconvert = {}
end

M.beamIdentityMappingVersion = 4
return M
