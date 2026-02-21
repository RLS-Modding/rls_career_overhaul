local M = {}
local logTag = "dynamicRoutes"

local CONFIG_VERSION = 1
local ROOT_GROUP_NAME = "dynamicRoutes"
local EPSILON = 0.0001
local PROXIMITY_BLOCK_DISTANCE = 50

local state = {
  enabled = true,
  timerSeconds = 1800,
  elapsed = 0,
  rootFound = false,
  missingRootWarned = false,
  configFileExists = false,
  groups = {},
  groupOrder = {},
  config = nil,
  configPath = nil,
  warnings = {},
  lastTriggerTime = nil,
  lastMapResetTime = nil,
  pendingQueue = false
}

local function addWarning(message)
  table.insert(state.warnings, message)
  log("W", logTag, message)
end

local function isTruthyDynamicValue(value)
  local t = type(value)
  if t == "boolean" then
    return value
  end
  if t == "number" then
    return value ~= 0
  end
  if t == "string" then
    local normalized = string.lower(trim(value))
    return normalized == "true" or normalized == "1" or normalized == "yes" or normalized == "on"
  end
  return false
end

local function safeGetObjectById(objectId)
  if not objectId then
    return nil
  end
  return scenetree.findObjectById(objectId)
end

local function resolveSceneRefToObject(ref)
  if not ref then
    return nil
  end

  local refType = type(ref)
  if refType == "userdata" then
    return ref
  end
  if refType == "number" then
    return scenetree.findObjectById(ref)
  end
  if refType == "string" then
    return scenetree.findObject(ref)
  end
  return nil
end

local function isSimGroupLike(obj)
  if not obj then
    return false
  end
  if obj.isSubClassOf then
    local ok, result = pcall(function()
      return obj:isSubClassOf("SimGroup")
    end)
    if ok and result == true then
      return true
    end
  end
  local className = obj.getClassName and obj:getClassName() or nil
  return className == "SimGroup"
end

local function isDirectChildOf(childObj, parentObj)
  if not childObj or not parentObj or not childObj.getGroup then
    return false
  end
  local ok, actualParent = pcall(function()
    return childObj:getGroup()
  end)
  if not ok or not actualParent then
    return false
  end
  if actualParent == parentObj then
    return true
  end
  if actualParent.getID and parentObj.getID then
    return actualParent:getID() == parentObj:getID()
  end
  return false
end

local function listChildrenSafe(obj)
  if not obj then
    return {}
  end

  local children = {}
  if not isSimGroupLike(obj) then
    return children
  end

  if obj.getObjects then
    local ok, refs = pcall(function()
      return obj:getObjects()
    end)
    if ok and type(refs) == "table" then
      for _, ref in ipairs(refs) do
        local child = resolveSceneRefToObject(ref)
        if child then
          table.insert(children, child)
        end
      end
    end
  end

  return children
end

local function listDirectChildrenAny(obj)
  local children = {}
  if not obj or not obj.getObjects then
    return children
  end

  local ok, refs = pcall(function()
    return obj:getObjects()
  end)
  if not ok or type(refs) ~= "table" then
    return children
  end

  for _, ref in ipairs(refs) do
    local child = resolveSceneRefToObject(ref)
    if child and isDirectChildOf(child, obj) then
      table.insert(children, child)
    end
  end
  return children
end

local function setHiddenRecursive(obj, hidden, visited)
  if not obj then
    return false
  end

  visited = visited or {}
  local objectId = obj.getID and obj:getID() or tostring(obj)
  if visited[objectId] then
    return false
  end
  visited[objectId] = true

  local changed = false
  if obj.setHidden and obj.isHidden then
    local currentlyHidden = obj:isHidden()
    if currentlyHidden ~= hidden then
      obj:setHidden(hidden)
      changed = true
    end
  end

  if isSimGroupLike(obj) then
    local children = listDirectChildrenAny(obj)
    for _, child in ipairs(children) do
      if setHiddenRecursive(child, hidden, visited) then
        changed = true
      end
    end
  end

  return changed
end

local function findDynamicRoutesRoot()
  local direct = scenetree.findObject(ROOT_GROUP_NAME)
  if direct and isSimGroupLike(direct) then
    return direct
  end

  local missionGroup = scenetree.MissionGroup or scenetree.findObject("MissionGroup")
  if missionGroup then
    local missionChildren = listChildrenSafe(missionGroup)
    for _, child in ipairs(missionChildren) do
      if child and child.getName and child:getName() == ROOT_GROUP_NAME and isSimGroupLike(child) then
        return child
      end
    end
  end

  return nil
end

local function getObjectName(obj)
  if not obj then
    return "<missing>"
  end
  local name = obj:getName()
  if not name or name == "" then
    return string.format("%s_%s", obj:getClassName() or "Object", tostring(obj:getID()))
  end
  return name
end

local function getCurrentRoadDrivability(roadObj)
  if not roadObj then
    return nil
  end
  local value = tonumber(roadObj.drivability)
  if value == nil and roadObj.getField then
    local ok, fieldVal = pcall(function()
      return roadObj:getField("drivability", 0)
    end)
    if ok then
      value = tonumber(fieldVal)
    end
  end
  return value
end

local function setRoadDrivability(roadObj, value)
  if not roadObj then
    return false
  end

  local current = getCurrentRoadDrivability(roadObj)
  if current ~= nil and math.abs(current - value) < EPSILON then
    return false
  end

  roadObj.drivability = value
  if roadObj.setField then
    pcall(function()
      roadObj:setField("drivability", 0, tostring(value))
    end)
  end
  if roadObj.updateInstanceRenderData then
    pcall(function()
      roadObj:updateInstanceRenderData()
    end)
  end
  return true
end

local function getDynamicRouteFieldValue(obj)
  if not obj then
    return nil
  end

  if obj.getDynDataFieldbyName then
    local ok, result = pcall(function()
      return obj:getDynDataFieldbyName("dynamicRoute", 0)
    end)
    if ok and result ~= nil and result ~= "" then
      return result
    end
  end

  if obj.getDynDataFieldByName then
    local ok, result = pcall(function()
      return obj:getDynDataFieldByName("dynamicRoute", 0)
    end)
    if ok and result ~= nil and result ~= "" then
      return result
    end
  end

  if obj.getField then
    local ok, result = pcall(function()
      return obj:getField("dynamicRoute", 0)
    end)
    if ok and result ~= nil and result ~= "" then
      return result
    end
  end

  return obj.dynamicRoute
end

local function isManagedRoad(obj)
  if not obj or obj:getClassName() ~= "DecalRoad" then
    return false
  end
  return isTruthyDynamicValue(getDynamicRouteFieldValue(obj))
end

local function isTSStaticObject(obj)
  return obj and obj.getClassName and obj:getClassName() == "TSStatic"
end

local function getCurrentLevelIdentifierSafe()
  if getCurrentLevelIdentifier then
    local ok, result = pcall(getCurrentLevelIdentifier)
    if ok and result and result ~= "" then
      return result
    end
  end

  if map and map.getMapName then
    local ok, result = pcall(map.getMapName)
    if ok and result and result ~= "" then
      return result
    end
  end

  return nil
end

local function getConfigPath()
  local levelId = getCurrentLevelIdentifierSafe()
  if not levelId then
    return nil
  end
  return "levels/" .. levelId .. "/dynamicRoute.json"
end

local function defaultConfigFromScene()
  local groups = {}
  for _, groupName in ipairs(state.groupOrder) do
    local group = state.groups[groupName]
    local options = {}
    for _, optionName in ipairs(group.optionOrder) do
      options[optionName] = {
        weight = 1,
        defaultDrivability = nil
      }
    end

    groups[groupName] = {
      enabled = true,
      selectionMode = "weighted",
      options = options
    }
  end

  return {
    version = CONFIG_VERSION,
    enabled = true,
    timerSeconds = 1800,
    groups = groups
  }
end

local function mergeConfig(generated, existing)
  local merged = deepcopy(generated)
  if type(existing) ~= "table" then
    return merged
  end

  if type(existing.enabled) == "boolean" then
    merged.enabled = existing.enabled
  end
  if tonumber(existing.timerSeconds) then
    merged.timerSeconds = math.max(0.1, tonumber(existing.timerSeconds))
  end

  local existingGroups = type(existing.groups) == "table" and existing.groups or {}
  for groupName, groupCfg in pairs(merged.groups) do
    local existingGroup = existingGroups[groupName]
    if type(existingGroup) == "table" then
      if type(existingGroup.enabled) == "boolean" then
        groupCfg.enabled = existingGroup.enabled
      end
      if type(existingGroup.selectionMode) == "string" and existingGroup.selectionMode ~= "" then
        groupCfg.selectionMode = existingGroup.selectionMode
      end

      local existingOptions = type(existingGroup.options) == "table" and existingGroup.options or {}
      for optionName, optionCfg in pairs(groupCfg.options) do
        local existingOption = existingOptions[optionName]
        if type(existingOption) == "table" then
          if tonumber(existingOption.weight) then
            optionCfg.weight = tonumber(existingOption.weight)
          end
          if existingOption.defaultDrivability == nil then
            optionCfg.defaultDrivability = nil
          elseif tonumber(existingOption.defaultDrivability) then
            optionCfg.defaultDrivability = tonumber(existingOption.defaultDrivability)
          end
        end
      end
    end
  end

  return merged
end

local function deepEqual(a, b, visited)
  if a == b then
    return true
  end
  if type(a) ~= type(b) then
    return false
  end
  if type(a) ~= "table" then
    return false
  end

  visited = visited or {}
  if visited[a] and visited[a] == b then
    return true
  end
  visited[a] = b

  for k, v in pairs(a) do
    if not deepEqual(v, b[k], visited) then
      return false
    end
  end
  for k, _ in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function saveConfig()
  if not state.configPath or type(state.config) ~= "table" then
    return false, "No config path or config data"
  end
  state.config.version = CONFIG_VERSION
  local ok = jsonWriteFile(state.configPath, state.config, true)
  if not ok then
    return false, "jsonWriteFile failed"
  end
  return true
end

local function getOptionConfig(groupName, optionName)
  local cfg = state.config and state.config.groups and state.config.groups[groupName]
  if not cfg or not cfg.options then
    return nil
  end
  return cfg.options[optionName]
end

local function chooseWeightedOption(groupName)
  local group = state.groups[groupName]
  if not group or #group.optionOrder == 0 then
    return nil
  end

  local groupCfg = state.config and state.config.groups and state.config.groups[groupName]
  local weighted = {}
  local totalWeight = 0

  for _, optionName in ipairs(group.optionOrder) do
    local weight = 1
    if groupCfg and groupCfg.options and groupCfg.options[optionName] and tonumber(groupCfg.options[optionName].weight) then
      weight = tonumber(groupCfg.options[optionName].weight)
    end
    weight = math.max(0, weight)
    totalWeight = totalWeight + weight
    table.insert(weighted, {name = optionName, weight = weight})
  end

  if totalWeight <= 0 then
    addWarning(string.format("Group '%s' has zero/negative total weight. Falling back to uniform.", groupName))
    local idx = math.random(1, #group.optionOrder)
    return group.optionOrder[idx]
  end

  local pick = math.random() * totalWeight
  local running = 0
  for _, entry in ipairs(weighted) do
    running = running + entry.weight
    if pick <= running then
      return entry.name
    end
  end

  return weighted[#weighted].name
end

local function collectManagedRoadsRecursive(obj, groupName, optionName, roads, visited)
  if not obj then
    return
  end
  local objectId = obj:getID()
  if visited[objectId] then
    return
  end
  visited[objectId] = true

  if isManagedRoad(obj) then
    table.insert(roads, {
      objectId = objectId,
      name = getObjectName(obj),
      groupName = groupName,
      optionName = optionName,
      originalDrivability = getCurrentRoadDrivability(obj)
    })
  end

  local children = listChildrenSafe(obj)
  for _, child in ipairs(children) do
    if child then
      collectManagedRoadsRecursive(child, groupName, optionName, roads, visited)
    end
  end
end

local function collectTSStaticsRecursive(obj, groupName, optionName, statics, visited)
  if not obj then
    return
  end
  local objectId = obj:getID()
  if visited[objectId] then
    return
  end
  visited[objectId] = true

  if isTSStaticObject(obj) then
    table.insert(statics, {
      objectId = objectId,
      name = getObjectName(obj),
      groupName = groupName,
      optionName = optionName
    })
  end

  local children = listChildrenSafe(obj)
  for _, child in ipairs(children) do
    if child then
      collectTSStaticsRecursive(child, groupName, optionName, statics, visited)
    end
  end
end

local function getPlayerReferencePosition()
  local veh = getPlayerVehicle and getPlayerVehicle(0) or nil
  if veh and veh.getPosition then
    return vec3(veh:getPosition())
  end
  if core_camera and core_camera.getPosition then
    return vec3(core_camera.getPosition())
  end
  return nil
end

local function isOptionSwitchBlockedByProximity(groupName, candidateOptionName)
  local group = state.groups[groupName]
  if not group then
    return false
  end
  if not candidateOptionName or not group.options[candidateOptionName] then
    return false
  end
  if group.activeOptionName == candidateOptionName then
    return false
  end

  local playerPos = getPlayerReferencePosition()
  if not playerPos then
    return false
  end

  local option = group.options[candidateOptionName]
  for _, staticData in ipairs(option.tstatics or {}) do
    local staticObj = safeGetObjectById(staticData.objectId)
    if staticObj and staticObj.isHidden and staticObj.getPosition and staticObj:isHidden() then
      local dist = playerPos:distance(vec3(staticObj:getPosition()))
      if dist <= PROXIMITY_BLOCK_DISTANCE then
        return true, staticData.name, dist
      end
    end
  end

  return false
end

local function scanSceneTree()
  state.groups = {}
  state.groupOrder = {}
  state.warnings = {}

  local root = findDynamicRoutesRoot()
  if not root then
    state.rootFound = false
    if not state.missingRootWarned then
      addWarning("Scene group 'dynamicRoutes' not found (including MissionGroup search). Dynamic route switching is disabled until reload/rescan finds it.")
      state.missingRootWarned = true
    end
    return false
  end

  state.rootFound = true
  state.missingRootWarned = false

  local seenGroups = {}
  local rootChildren = listChildrenSafe(root)
  if #rootChildren == 0 then
    addWarning("dynamicRoutes root exists but has no SimGroup children via getObjects().")
    return false
  end

  for _, groupObj in ipairs(rootChildren) do
    if groupObj then
      if isDirectChildOf(groupObj, root) then
        if isSimGroupLike(groupObj) then
          local groupName = getObjectName(groupObj)
          if seenGroups[groupName] then
            addWarning(string.format("Duplicate group name '%s' detected under dynamicRoutes. Keeping first occurrence.", groupName))
          else
            seenGroups[groupName] = true
            local group = {
              name = groupName,
              objectId = groupObj:getID(),
              optionOrder = {},
              options = {},
              activeOptionName = nil
            }

            local seenOptions = {}
            local optionChildren = listChildrenSafe(groupObj)
            if #optionChildren == 0 then
              local className = groupObj.getClassName and groupObj:getClassName() or "unknown"
              addWarning(string.format("Group '%s' (class '%s') has no SimGroup option children via getObjects().", groupName, className))
            else
              for _, optionObj in ipairs(optionChildren) do
                if optionObj and isDirectChildOf(optionObj, groupObj) and isSimGroupLike(optionObj) then
                  local optionName = getObjectName(optionObj)
                  if seenOptions[optionName] then
                    addWarning(string.format("Duplicate option name '%s' in group '%s'. Keeping first occurrence.", optionName, groupName))
                  else
                    seenOptions[optionName] = true
                    local roads = {}
                    local visited = {}
                    collectManagedRoadsRecursive(optionObj, groupName, optionName, roads, visited)
                    local tstatics = {}
                    local staticVisited = {}
                    collectTSStaticsRecursive(optionObj, groupName, optionName, tstatics, staticVisited)
                    group.options[optionName] = {
                      name = optionName,
                      objectId = optionObj:getID(),
                      roads = roads,
                      tstatics = tstatics
                    }
                    table.insert(group.optionOrder, optionName)
                  end
                end
              end
            end

            if #group.optionOrder == 0 then
              addWarning(string.format("Group '%s' has no options.", groupName))
            end

            state.groups[groupName] = group
            table.insert(state.groupOrder, groupName)
          end
        else
          -- Ignore non-SimGroup direct children under root silently.
        end
      end
    end
  end

  return true
end

local function resolveInitialActiveOptions()
  for _, groupName in ipairs(state.groupOrder) do
    local group = state.groups[groupName]
    local visibleNames = {}

    for _, optionName in ipairs(group.optionOrder) do
      local optionObj = safeGetObjectById(group.options[optionName].objectId)
      if optionObj and not optionObj:isHidden() then
        table.insert(visibleNames, optionName)
      end
    end

    if #visibleNames == 1 then
      group.activeOptionName = visibleNames[1]
    else
      group.activeOptionName = chooseWeightedOption(groupName) or group.optionOrder[1]
    end
  end
end

local function applyGroup(groupName)
  local group = state.groups[groupName]
  if not group or #group.optionOrder == 0 then
    return false
  end

  if not group.activeOptionName or not group.options[group.activeOptionName] then
    group.activeOptionName = chooseWeightedOption(groupName) or group.optionOrder[1]
  end

  local changed = false
  local activeName = group.activeOptionName

  for _, optionName in ipairs(group.optionOrder) do
    local option = group.options[optionName]
    local optionObj = safeGetObjectById(option.objectId)
    if optionObj then
      local shouldHide = optionName ~= activeName
      if setHiddenRecursive(optionObj, shouldHide) then
        changed = true
      end
    end

    local optionCfg = getOptionConfig(groupName, optionName) or {}
    for _, roadData in ipairs(option.roads) do
      local roadObj = safeGetObjectById(roadData.objectId)
      if roadObj then
        local targetDrivability
        if optionName == activeName then
          if optionCfg.defaultDrivability ~= nil and tonumber(optionCfg.defaultDrivability) ~= nil then
            targetDrivability = tonumber(optionCfg.defaultDrivability)
          else
            targetDrivability = roadData.originalDrivability
          end
        else
          targetDrivability = -1
        end

        if targetDrivability ~= nil and setRoadDrivability(roadObj, targetDrivability) then
          changed = true
        end
      end
    end
  end

  return changed
end

local function reapplyGroundMarkersWithExistingOptions()
  if not core_groundMarkers or not core_groundMarkers.setPath then
    return
  end

  local target = nil
  if type(core_groundMarkers.endWP) == "table" and next(core_groundMarkers.endWP) ~= nil then
    target = deepcopy(core_groundMarkers.endWP)
  elseif core_groundMarkers.getTargetPos then
    target = core_groundMarkers.getTargetPos()
  end

  if not target then
    return
  end

  local options = {}
  options.clearPathOnReachingTarget = core_groundMarkers.clearPathOnReachingTarget
  options.step = tonumber(core_groundMarkers.stepDistance)
  options.color = deepcopy(core_groundMarkers.color)
  options.cutOffDrivability = core_groundMarkers.cutOffDrivability
  options.penaltyAboveCutoff = core_groundMarkers.penaltyAboveCutoff
  options.penaltyBelowCutoff = core_groundMarkers.penaltyBelowCutoff
  options.renderDecals = core_groundMarkers.renderDecals

  core_groundMarkers.setPath(target, options)
end

local function resetMapIfNeeded(changed, force)
  if not changed and not force then
    return
  end
  if map and map.reset then
    map.reset()
    be:reloadCollision()
    if ui_apps_minimap_roads and ui_apps_minimap_roads.reset then
      ui_apps_minimap_roads.reset()
    end
    reapplyGroundMarkersWithExistingOptions()
    state.lastMapResetTime = os.time()
  end
end 

local function applyAllGroups()
  local changed = false
  for _, groupName in ipairs(state.groupOrder) do
    if applyGroup(groupName) then
      changed = true
    end
  end
  resetMapIfNeeded(changed)
  return changed
end

local function reloadConfigAndRescan()
  state.elapsed = 0
  state.configPath = getConfigPath()

  local foundRoot = scanSceneTree()
  local generated = defaultConfigFromScene()

  local existingConfig = nil
  local hasValidConfig = false
  if state.configPath then
    if FS and FS.fileExists and FS:fileExists(state.configPath) then
      existingConfig = jsonReadFile(state.configPath)
      if existingConfig == nil then
        addWarning("Failed to parse existing dynamicRoute.json.")
      else
        hasValidConfig = true
      end
    end
  else
    addWarning("Cannot resolve current level identifier. Config path unavailable.")
  end

  state.configFileExists = hasValidConfig
  state.config = mergeConfig(generated, existingConfig)
  state.enabled = state.config.enabled ~= false
  state.timerSeconds = math.max(0.1, tonumber(state.config.timerSeconds) or 1800)

  local careerActive = false
  if core_gamestate and core_gamestate.state and core_gamestate.state.state == "career" then
    careerActive = true
  end
  if not careerActive and career_career and career_career.isActive then
    local ok, active = pcall(function() return career_career.isActive() end)
    careerActive = ok and active
  end
  if careerActive then
    state.enabled = true
    state.config.enabled = true
  end

  if foundRoot and hasValidConfig then
    resolveInitialActiveOptions()
    applyAllGroups()
  end

  return foundRoot
end

local function generateRoutesFile()
  state.configPath = getConfigPath()
  if not state.configPath then
    return false, "No config path (level not resolved)"
  end
  local foundRoot = scanSceneTree()
  if not foundRoot then
    return false, "Scene group 'dynamicRoutes' not found"
  end
  local generated = defaultConfigFromScene()
  state.config = mergeConfig(generated, nil)
  state.configFileExists = true
  resolveInitialActiveOptions()
  applyAllGroups()
  local ok, err = saveConfig()
  if not ok then
    return false, tostring(err)
  end
  return true
end

local function triggerGroupWeighted(groupName)
  local group = state.groups[groupName]
  if not group then
    return false, "Group not found: " .. tostring(groupName)
  end
  local picked = chooseWeightedOption(groupName)
  if not picked then
    return false, "No option to choose for group: " .. tostring(groupName)
  end
  local blocked, staticName, dist = isOptionSwitchBlockedByProximity(groupName, picked)
  if blocked then
    return false, string.format("Blocked by nearby TSStatic '%s' (%.1fm <= %dm).", tostring(staticName), dist or -1, PROXIMITY_BLOCK_DISTANCE)
  end
  group.activeOptionName = picked
  local changed = applyGroup(groupName)
  resetMapIfNeeded(changed)
  state.lastTriggerTime = os.time()
  return true
end

local function triggerAllWeighted()
  local anyPicked = false
  local changed = false

  for _, groupName in ipairs(state.groupOrder) do
    local groupCfg = state.config and state.config.groups and state.config.groups[groupName]
    if not groupCfg or groupCfg.enabled ~= false then
      local picked = chooseWeightedOption(groupName)
      local blocked = false
      if picked then
        blocked = isOptionSwitchBlockedByProximity(groupName, picked)
      end
      if picked and not blocked then
        state.groups[groupName].activeOptionName = picked
        anyPicked = true
      end
    end
  end

  if anyPicked then
    for _, groupName in ipairs(state.groupOrder) do
      if applyGroup(groupName) then
        changed = true
      end
    end
    resetMapIfNeeded(changed)
    state.lastTriggerTime = os.time()
  end

  return anyPicked
end

local function setGroupOption(groupName, optionName)
  local group = state.groups[groupName]
  if not group then
    return false, "Group not found: " .. tostring(groupName)
  end
  if not group.options[optionName] then
    return false, string.format("Option '%s' not found in group '%s'", tostring(optionName), tostring(groupName))
  end
  local blocked, staticName, dist = isOptionSwitchBlockedByProximity(groupName, optionName)
  if blocked then
    return false, string.format("Blocked by nearby TSStatic '%s' (%.1fm <= %dm).", tostring(staticName), dist or -1, PROXIMITY_BLOCK_DISTANCE)
  end
  group.activeOptionName = optionName
  local changed = applyGroup(groupName)
  resetMapIfNeeded(changed)
  state.lastTriggerTime = os.time()
  return true
end

local function setEnabled(enabled)
  state.enabled = enabled == true
  if state.config then
    state.config.enabled = state.enabled
  end
end

local function setTimerSeconds(seconds)
  local value = tonumber(seconds)
  if not value then
    return false
  end
  state.timerSeconds = math.max(0.1, value)
  if state.config then
    state.config.timerSeconds = state.timerSeconds
  end
  return true
end

local function setGroupEnabled(groupName, enabled)
  if not (state.config and state.config.groups and state.config.groups[groupName]) then
    return false
  end
  state.config.groups[groupName].enabled = enabled == true
  return true
end

local function setOptionWeight(groupName, optionName, weight)
  local optionCfg = getOptionConfig(groupName, optionName)
  local value = tonumber(weight)
  if not optionCfg or not value then
    return false
  end
  optionCfg.weight = value
  return true
end

local function setOptionDefaultDrivability(groupName, optionName, defaultDrivability)
  local optionCfg = getOptionConfig(groupName, optionName)
  if not optionCfg then
    return false
  end
  if defaultDrivability == nil then
    optionCfg.defaultDrivability = nil
    return true
  end
  local value = tonumber(defaultDrivability)
  if value == nil then
    return false
  end
  optionCfg.defaultDrivability = value
  return true
end

local function getDebugState()
  local groups = {}
  local managedRoadCount = 0

  for _, groupName in ipairs(state.groupOrder) do
    local group = state.groups[groupName]
    local cfgGroup = state.config and state.config.groups and state.config.groups[groupName] or {}
    local options = {}
    local totalWeight = 0

    for _, optionName in ipairs(group.optionOrder) do
      local option = group.options[optionName]
      local cfgOption = cfgGroup.options and cfgGroup.options[optionName] or {}
      local weight = tonumber(cfgOption.weight) or 1
      totalWeight = totalWeight + math.max(0, weight)
      managedRoadCount = managedRoadCount + #option.roads
      table.insert(options, {
        name = optionName,
        roadCount = #option.roads,
        weight = weight,
        defaultDrivability = cfgOption.defaultDrivability
      })
    end

    table.insert(groups, {
      name = groupName,
      enabled = cfgGroup.enabled ~= false,
      activeOptionName = group.activeOptionName,
      totalWeight = totalWeight,
      optionCount = #group.optionOrder,
      options = options
    })
  end

  return {
    rootFound = state.rootFound,
    configFileExists = state.configFileExists,
    enabled = state.enabled,
    timerSeconds = state.timerSeconds,
    elapsed = state.elapsed,
    configPath = state.configPath,
    lastTriggerTime = state.lastTriggerTime,
    lastMapResetTime = state.lastMapResetTime,
    warningCount = #state.warnings,
    warnings = deepcopy(state.warnings),
    groupCount = #state.groupOrder,
    managedRoadCount = managedRoadCount,
    groups = groups
  }
end

local function onLevelLoaded()
  reloadConfigAndRescan()
end

local function onWorldReadyState(state)
  if state == 2 then
    reloadConfigAndRescan()
  end
end

local function onReset()
  reloadConfigAndRescan()
end

local function onInit()
  math.randomseed(os.time())
  reloadConfigAndRescan()
end

local function onExtensionLoaded()
  reloadConfigAndRescan()
end

local function applyPendingQueue()
  if not state.pendingQueue then
    return
  end
  state.pendingQueue = false

  core_gamestate.requestEnterLoadingScreen("dynamicRoutes")
  triggerAllWeighted()
  core_gamestate.requestExitLoadingScreen("dynamicRoutes")
  guihooks.trigger("toastrMsg", {type = "info", msg = "Dynamic routes reloaded"})
end

local function onScreenFadeState(fadeState)
  if fadeState == 2 and state.pendingQueue then
    applyPendingQueue()
  end
end

local function onUpdate(dt)
  if not state.enabled or not state.rootFound or #state.groupOrder == 0 then
    return
  end

  state.elapsed = state.elapsed + dt
  if state.elapsed < state.timerSeconds then
    return
  end
  state.elapsed = 0
  state.pendingQueue = true
end

M.reloadConfigAndRescan = reloadConfigAndRescan
M.generateRoutesFile = generateRoutesFile
M.applyAllGroups = applyAllGroups
M.triggerAllWeighted = triggerAllWeighted
M.triggerGroupWeighted = triggerGroupWeighted
M.setGroupOption = setGroupOption
M.getDebugState = getDebugState
M.setEnabled = setEnabled
M.setTimerSeconds = setTimerSeconds
M.setGroupEnabled = setGroupEnabled
M.setOptionWeight = setOptionWeight
M.setOptionDefaultDrivability = setOptionDefaultDrivability
M.saveConfig = saveConfig
M.getConfigPath = function() return state.configPath end
M.onLevelLoaded = onLevelLoaded
M.onReset = onReset
M.onInit = onInit
M.onExtensionLoaded = onExtensionLoaded
M.onScreenFadeState = onScreenFadeState
M.onWorldReadyState = onWorldReadyState
M.onUpdate = onUpdate
M.updateGFX = onUpdate

return M
