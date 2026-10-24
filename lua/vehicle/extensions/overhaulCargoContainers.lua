-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- GE-callable API: none directly queued.
-- The gameplayInterface registry dispatches moduleActions/moduleLookups; requestRegistration(gi),
-- setActive(active) and setUpdateEnabled(enabled) are VE registry/controller entry points.

-- Owns container registration, loading state and suspension-aware cargo mass updates.
-- Read state/helpers, container lookup/actions, registration, updateGFX, then lifecycle hooks.
-- geCallback.lua transports registration replies to the GE cargo owner.
-- Fork of stock lua/vehicle/extensions/gameplayInterfaceModules/interactCargoContainers.lua (BeamNG 0.40).
local M = {}
M.moduleActions = {}
M.moduleLookups = {}

local max = math.max
local abs = math.abs
local moduleName = "overhaulCargoContainers"

local expressionParser

local cargoContainerCache = nil
local cargoContainerById = nil
local warnedCompatibilityIssues = {}
local isOverhaulActive = false
local isRegistered = false
local cargoData

local functionFields = {
  "beamSpringFunction", "beamLimitSpringFunction", "beamDampFunction",
  "nodeWeightFunction", "beamStrengthFunction", "beamDeformFunction", "beamShortBoundFunction",
  "beamLongBoundFunction", "beamPrecompressionFunction"
}

local function cargoElement(source)
  local element = {
    cid = source.cid, name = source.name, cargoGroup = source.cargoGroup, partPath = source.partPath,
    nodeWeight = source.nodeWeight, beamSpring = source.beamSpring, beamDamp = source.beamDamp,
    beamLimitDampFunction = source.beamLimitDampFunction
  }
  for _, field in ipairs(functionFields) do element[field] = source[field] end
  return element
end

local function warnCompatibilityOnce(key, message)
  if warnedCompatibilityIssues[key] then return end
  warnedCompatibilityIssues[key] = true
  log("W", moduleName, message)
end

local function resolveLegacyNode(nodeRef)
  local source
  if type(nodeRef) == "number" then
    source = v.data.nodes[nodeRef]
  end

  if type(nodeRef) == "string" then
    for _, node in pairs(v.data.nodes or {}) do
      if node.name == nodeRef then
        source = node
        break
      end
    end
  end
  if source then
    cargoData.nodes[source.cid] = cargoData.nodes[source.cid] or cargoElement(source)
    return cargoData.nodes[source.cid]
  end
end

local function makeLegacyGroupId(container, fallbackId)
  local partIdentity = tostring(container.partOrigin or container.partPath or "container")
  partIdentity = partIdentity:gsub("[^%w_]", "_")
  return string.format("__rlsLegacyCargo_%s_%s", partIdentity, tostring(fallbackId))
end

local function normalizeLegacyCargoStorage()
  local fallbackId = 0
  local usedContainerIds = {}
  for _, container in pairs(cargoData.cargoStorage or {}) do
    local containerId = tonumber(container.cid)
    if containerId == nil or usedContainerIds[containerId] then
      while usedContainerIds[fallbackId] do
        fallbackId = fallbackId + 1
      end
      containerId = fallbackId
      container.cid = containerId
      warnCompatibilityOnce(
        "missingCid:" .. tostring(container.partPath) .. ":" .. tostring(containerId),
        string.format("Cargo container '%s' had no unique numeric id; assigned fallback id %s.", tostring(container.name), tostring(containerId))
      )
    elseif container.cid ~= containerId then
      container.cid = containerId
    end
    usedContainerIds[containerId] = true
    fallbackId = max(fallbackId + 1, containerId + 1)

    local legacyWeightNodes = container["weightNodes:"] or container.weightNodes
    if container.groupId == nil or container.groupId == "" then
      container.groupId = makeLegacyGroupId(container, containerId)
      warnCompatibilityOnce(
        "missingGroup:" .. tostring(container.partPath) .. ":" .. tostring(containerId),
        string.format(
          "Using legacy cargo compatibility for '%s' (%s): generated missing groupId '%s'.",
          tostring(container.name or "Unnamed Container"),
          tostring(container.partOrigin or container.partPath or "unknown part"),
          container.groupId
        )
      )
    end

    if type(legacyWeightNodes) == "table" then
      local resolvedNodeCount = 0
      for _, nodeRef in pairs(legacyWeightNodes) do
        local node = resolveLegacyNode(nodeRef)
        if node then
          resolvedNodeCount = resolvedNodeCount + 1
          node.cargoGroup = container.groupId
          node.partPath = node.partPath or container.partPath or ""
          if not node.nodeWeightFunction then
            local baseWeight = tonumber(node.nodeWeight) or 0
            node.nodeWeightFunction = string.format("=%.17g+($volume*$density)", baseWeight)
          end
        end
      end

      if resolvedNodeCount == 0 and next(legacyWeightNodes) then
        warnCompatibilityOnce(
          "missingNodes:" .. tostring(container.partPath) .. ":" .. tostring(containerId),
          string.format(
            "Legacy cargo container '%s' referenced weight nodes that could not be resolved; cargo remains usable but will not add physical mass.",
            tostring(container.name or "Unnamed Container")
          )
        )
      end
    end
  end
end

local function isPassengerOnly(cargoTypes)
  if not cargoTypes then return false end
  local hasPassenger = false
  for _, cargoType in ipairs(cargoTypes) do
    if cargoType ~= "passenger" then return false end
    hasPassenger = true
  end
  return hasPassenger
end

local function buildContainerCache()
  cargoContainerCache = {}
  cargoContainerById = {}
  -- Legacy containers need private annotations; unrelated JBeam geometry stays with v.data.
  cargoData = {cargoStorage = deepcopy(v.data.cargoStorage or {}), nodes = {}, beams = {}}
  normalizeLegacyCargoStorage()

  local cargoContainerGroupIdToCacheIndex = {}
  local cargoContainerGroupIdToCid = {}
  local idx = 1
  for _, container in pairs(cargoData.cargoStorage or {}) do
    local containerId = container.cid
    local groupId = tostring(container.groupId)
    local partPath = tostring(container.partPath or "")
    local containerKey = groupId .. partPath

    -- generate an entry for the list that will be sent back to geLua.
    local entry = {
      id = containerId,
      cargoTypes = type(container.cargoTypes) == "table" and container.cargoTypes or {},
      capacity = tonumber(container.capacity) or 0,
      name = container.name or "Unnamed Container",
      groupId = groupId,
      partPath = partPath
    }
    table.insert(cargoContainerCache, entry)

    cargoContainerById[containerId] = {
      nodes = {},
      beams = {},
      passengerOnly = isPassengerOnly(entry.cargoTypes),
      smoothers = {
        volume = newTemporalSmoothing(container.maxVolumeRate or 1000, container.maxVolumeRate or 1000),
        density = newTemporalSmoothing(2, 2, nil, 1) -- need to smooth density? probably...
      },
      target = {
        volume = 0,
        density = 1
      },
      reachedTarget = true
    }
    cargoContainerGroupIdToCacheIndex[containerKey] = idx
    cargoContainerGroupIdToCid[containerKey] = containerId
    idx = idx + 1
  end

  for id, node in pairs(v.data.nodes or {}) do
    local key = node.cargoGroup and (tostring(node.cargoGroup) .. tostring(node.partPath or ""))
    if key and cargoContainerGroupIdToCid[key] then
      cargoData.nodes[id] = cargoData.nodes[id] or cargoElement(node)
    end
  end
  for id, beam in pairs(v.data.beams or {}) do
    local key = beam.cargoGroup and (tostring(beam.cargoGroup) .. tostring(beam.partPath or ""))
    if key and cargoContainerGroupIdToCid[key] then cargoData.beams[id] = cargoElement(beam) end
  end

  -- store all nodes for groups
  for _, node in pairs(cargoData.nodes) do
    local nodeKey = node.cargoGroup and (tostring(node.cargoGroup) .. tostring(node.partPath or ""))
    if nodeKey and cargoContainerGroupIdToCacheIndex[nodeKey] then
      local hasValidFunction = false
      for _, functionName in ipairs(functionFields) do
        if node[functionName] then
          hasValidFunction = true
          break
        end
      end
      if hasValidFunction then
        table.insert(cargoContainerById[cargoContainerGroupIdToCid[nodeKey]].nodes, node.cid)
      end

      -- give one of the node id's to the entry, so that geLua can use it for detachment test
      cargoContainerCache[cargoContainerGroupIdToCacheIndex[nodeKey]].nodeId = node.cid
    end
  end

  -- store all beams for groups
  for _, beam in pairs(cargoData.beams) do
    local beamKey = beam.cargoGroup and (tostring(beam.cargoGroup) .. tostring(beam.partPath or ""))
    if beamKey and cargoContainerGroupIdToCacheIndex[beamKey] then
      local hasValidFunction = false
      for _, functionName in ipairs(functionFields) do
        if beam[functionName] then
          hasValidFunction = true
          break
        end
      end
      if hasValidFunction then
        table.insert(cargoContainerById[cargoContainerGroupIdToCid[beamKey]].beams, beam.cid)
      end
    end
  end

  -- wrap cargoContainerCache another time to conform to return value format for gameplay interface functions.
  cargoContainerCache = {cargoContainerCache}
  cargoData.cargoStorage = nil
end

local functionCache = {}
local function clearFunctionResults()
  for _, data in pairs(functionCache) do
    data.result = nil
  end
end

local function getFunctionResult(expr, container)
  if not functionCache[expr] then
    expressionParser = expressionParser or require("jbeam/expressionParser")
    local fun, vars = expressionParser.compileSafe("$" .. expr)
    functionCache[expr] = {fun = fun, vars = vars, result = nil}
  end
  if not functionCache[expr].result then
    local volume = container.smoothers.volume.state
    local density = container.smoothers.density.state
    functionCache[expr].vars["$volume"] = volume
    functionCache[expr].vars["$density"] = density
    -- Older cargo JBeams used $load for the physical cargo mass.
    functionCache[expr].vars["$load"] = volume * density
    functionCache[expr].result = functionCache[expr].fun()
  --dump(expr, functionCache[expr].result)
  end
  return functionCache[expr].result
end

local function applyNodeAndBeamValues(container, dtSim)
  clearFunctionResults()

  --update smoothers
  container.reachedTarget = false
  container.smoothers.volume:get(container.target.volume, dtSim)
  container.smoothers.density:get(container.target.density, dtSim)

  container.reachedTarget = abs(container.smoothers.volume.state - container.target.volume) < 1e-30 and abs(container.smoothers.density.state - container.target.density) < 1e-30

  for _, nodeId in ipairs(container.nodes) do
    local node = cargoData.nodes[nodeId]
    if node.nodeWeightFunction then
      local nodeWeight = getFunctionResult(node.nodeWeightFunction, container)
      obj:setNodeMass(node.cid, nodeWeight)
    --dump("setNodeMass To  ", node.cid, nodeWeight)
    end
  end

  for _, beamId in ipairs(container.beams) do
    local beam = cargoData.beams[beamId]

    if beam.beamSpringFunction or beam.beamDampFunction then
      local beamSpring = beam.beamSpring
      local beamDamp = beam.beamDamp
      --dump("setBeamSpringDamp From", beam.cid, beamSpring, beamDamp)

      if beam.beamSpringFunction then
        beamSpring = getFunctionResult(beam.beamSpringFunction, container)
      end
      if beam.beamDampFunction then
        beamDamp = getFunctionResult(beam.beamDampFunction, container)
      end
      obj:setBeamSpringDamp(beam.cid, beamSpring, beamDamp, -1, -1)
    --dump("setBeamSpringDamp To  ", beam.cid, beamSpring, beamDamp)
    end

    if beam.beamLimitSpringFunction or beam.beamLimitDampFunction then
      local beamLimitSpring = -1
      local beamLimitDamp = -1
      --dump("setBeamSpringDamp From", beam.cid, beamSpring, beamDamp)
      if beam.beamLimitSpringFunction then
        beamLimitSpring = getFunctionResult(beam.beamLimitSpringFunction, container)
      end
      if beam.beamLimitDampFunction then
        beamLimitDamp = getFunctionResult(beam.beamLimitDampFunction, container)
      end
      obj:setBoundedBeamSpringDampLimits(beamId, beamLimitSpring, beamLimitDamp, -1)
    --dump("setBoundedBeamSpringDampLimits To  ", beam.cid, beamLimitSpring, beamLimitDamp)
    end

    if beam.beamStrengthFunction then
      local beamStrength = getFunctionResult(beam.beamStrengthFunction, container)
      obj:setBeamStrength(beam.cid, beamStrength)
    --dump("setBeamStrength To  ", beam.cid, beamStrength)
    end
    if beam.beamDeformFunction then
      local beamDeform = getFunctionResult(beam.beamDeformFunction, container)
      obj:setBeamDeform(beam.cid, beamDeform)
    --dump("beamDeform To  ", beam.cid, beamDeform)
    end

    if beam.beamShortBoundFunction then
      local beamShortBound = getFunctionResult(beam.beamShortBoundFunction, container)
      obj:setBoundedBeamShortBound(beam.cid, beamShortBound)
    --dump("setBoundedBeamShortBound To  ", beam.cid, beamShortBound)
    end

    if beam.beamLongBoundFunction then
      local beamLongBound = getFunctionResult(beam.beamLongBoundFunction, container)
      obj:setBoundedBeamLongBound(beam.cid, beamLongBound)
    --dump("setBoundedBeamLongBound To  ", beam.cid, beamLongBound)
    end

    if beam.beamPrecompressionFunction then
      local beamPrecompression = getFunctionResult(beam.beamPrecompressionFunction, container)
      obj:setPrecompressionRatio(beam.cid, beamPrecompression)
    --dump("setPrecompressionRatio To  ", beam.cid, beamPrecompression)
    end
  end

  return container.reachedTarget
end

local anyContainerNeedsUpdate = false
local function restorePhysicalValues()
  for _, container in pairs(cargoContainerById or {}) do
    for _, nodeId in ipairs(container.nodes) do
      local node = v.data.nodes[nodeId]
      if cargoData.nodes[nodeId].nodeWeightFunction then obj:setNodeMass(nodeId, node.nodeWeight) end
    end
    for _, beamId in ipairs(container.beams) do
      local beam = v.data.beams[beamId]
      if beam.beamSpringFunction or beam.beamDampFunction then
        obj:setBeamSpringDamp(beamId, beam.beamSpring, beam.beamDamp, -1, -1)
      end
      if beam.beamLimitSpringFunction or beam.beamLimitDampFunction then
        obj:setBoundedBeamSpringDampLimits(beamId, beam.beamLimitSpring or -1, beam.beamLimitDamp or -1, -1)
      end
      if beam.beamStrengthFunction then obj:setBeamStrength(beamId, beam.beamStrength) end
      if beam.beamDeformFunction then obj:setBeamDeform(beamId, beam.beamDeform) end
      if beam.beamPrecompressionFunction then obj:setPrecompressionRatio(beamId, beam.beamPrecompression or 1) end
    end
  end
end

local function clearCache()
  cargoContainerCache = nil
  cargoContainerById = nil
  cargoData = nil
end

local function updateGFX(dtSim)
  anyContainerNeedsUpdate = false
  if not cargoContainerById then
    M.setUpdateEnabled(false)
    return
  end
  for _, container in pairs(cargoContainerById) do
    if not container.reachedTarget then
      applyNodeAndBeamValues(container, dtSim)
      anyContainerNeedsUpdate = anyContainerNeedsUpdate or not container.reachedTarget
    end
  end
  if not anyContainerNeedsUpdate then
    M.setUpdateEnabled(false)
  end
end

local isUpdating = false
local function setUpdateEnabled(enabled)
  if enabled and not isUpdating then
    --log("I","","Start updating cargo containers...")
    isUpdating = true
    M.updateGFX = updateGFX
    extensions.hookUpdate("updateGFX")
  elseif not enabled and isUpdating then
    isUpdating = false
    M.updateGFX = nil
    extensions.hookUpdate("updateGFX")
  --log("I","","Cargo containers updated.")
  end
end

local function setCargoContainers(params)
  local dataTypeCheck, dataTypeError = checkTableDataTypes(params, {"table", "string"})
  if not dataTypeCheck then
    return {failReason = dataTypeError}
  end

  if not cargoContainerCache then
    buildContainerCache()
  end

  local mode = params[2] or "updateExplicit"

  -- set all container weights according to the params data.
  for _, setContainerData in pairs(params[1] or {}) do
    -- first check if all containers have proper data
    if setContainerData.containerId == nil or setContainerData.volume == nil then
      return {failReason = "Container Data missing either containerId or volume values."}
    end
  end
  -- only then actually update
  anyContainerNeedsUpdate = false
  for id, _ in pairs(cargoContainerById) do
    local setContainerData = (params[1] or {})[id]
    local target = cargoContainerById[id].target
    local container = cargoContainerById[id]
    if mode == "updateDelivery" and container.passengerOnly then
      setContainerData = nil
    end
    -- default non-set containers to 0 weight by default
    local keepCurrentTarget = mode == "updateExplicit" or (mode == "updateDelivery" and container.passengerOnly)
    target.volume = (setContainerData and setContainerData.volume) or (keepCurrentTarget and target.volume or 0) or 0
    target.density = (setContainerData and setContainerData.density) or (keepCurrentTarget and target.density or 1) or 1

    container.reachedTarget = abs(container.smoothers.volume.state - container.target.volume) < 1e-30 and abs(container.smoothers.density.state - container.target.density) < 1e-30

    if not container.reachedTarget then
      container.reachTargetDuration = max(abs(container.smoothers.volume.state - container.target.volume) / container.smoothers.volume[false], abs(container.smoothers.density.state - container.target.density) / container.smoothers.density[false])
    end

    anyContainerNeedsUpdate = anyContainerNeedsUpdate or not container.reachedTarget
  end
  if anyContainerNeedsUpdate then
    M.setUpdateEnabled(true)
  end

  --dump(cargoContainerById)
end

local function rejectInactive()
  return {failReason = "Overhaul cargo API is inactive."}
end

local function setCargoContainersForOverhaul(params)
  if not isOverhaulActive then return rejectInactive() end
  return setCargoContainers(params)
end

local function getCargoContainers(params)
  if not isOverhaulActive then return rejectInactive() end
  local dataTypeCheck, dataTypeError = checkTableDataTypes(params, {})
  if not dataTypeCheck then
    return {failReason = dataTypeError}
  end
  -- create the cache if it doesnt exist yet.
  if not cargoContainerCache then
    buildContainerCache()
  end

  for _, entry in ipairs(cargoContainerCache[1]) do
    local container = cargoContainerById[entry.id]
    entry.reachTargetDuration = container.reachTargetDuration
    if container.reachedTarget then
      entry.reachTargetTimeRemaining = 0
    else
      entry.reachTargetTimeRemaining = math.max(math.abs(container.smoothers.volume.state - container.target.volume) / container.smoothers.volume[false], math.abs(container.smoothers.density.state - container.target.density) / container.smoothers.density[false])
    end
    entry.targetVolume = container.target.volume
    entry.currentVolume = container.smoothers.volume.state
    entry.rateVolume = container.smoothers.volume[false]
    entry.targetDensity = container.target.density
    entry.currentDensity = container.smoothers.density.state
  end

  return cargoContainerCache
end

local function requestRegistration(gi)
  if isOverhaulActive and not isRegistered then
    gi.registerModule(moduleName, M.moduleActions, M.moduleLookups)
    isRegistered = true
  end
end

local function setActive(active)
  if active == true then
    local gi = extensions.gameplayInterface
    if not gi or not gi.registerModule then return false end
    isOverhaulActive = true
    if not isRegistered then
      requestRegistration(gi)
      if not isRegistered then
        isOverhaulActive = false
        return false
      end
    end
    return true
  end

  isOverhaulActive = false
  restorePhysicalValues()
  M.setUpdateEnabled(false)
  clearCache()
  return true
end

local function onExtensionLoaded()
  M.setUpdateEnabled(false)
  M.moduleActions.overhaulSetCargoContainers = setCargoContainersForOverhaul
  M.moduleLookups.overhaulGetCargoContainers = getCargoContainers
  clearCache()
end

local function onReset()
  M.setUpdateEnabled(false)
  clearCache()
end

M.onExtensionLoaded = onExtensionLoaded
M.requestRegistration = requestRegistration
M.setActive = setActive
M.setUpdateEnabled = setUpdateEnabled
M.updateGFX = nop
M.onReset = onReset
M.onExtensionUnloaded = function()
  isOverhaulActive = false
  restorePhysicalValues()
  M.setUpdateEnabled(false)
  clearCache()
end
return M
