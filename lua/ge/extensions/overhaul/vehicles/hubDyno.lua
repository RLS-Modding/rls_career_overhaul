-- Temporarily removes the brakes on dyno-equipped axles, keeping saved choices with the config and restoring them later.
-- Map: Config, State, Helpers, Legacy part migration, Bearing offsets, Per-frame update, Public API, Game hooks.
local M = {}
M.dependencies = {'overhaul_shell_patches'}

-- Config ------------------------------------------------------------------------------------------

local PATCH_ID = 'hubDynoConfigMigration'
local FEET_TOP, FEET_BOTTOM = 0.1929932, -0.2753192
-- Retired fixed-dyno part names and the current parts they became.
local legacyParts = {
  wheel_dyno_rls_fixed_F5 = 'wheel_dyno_rls_F5',
  wheel_dyno_rls_fixed_R5 = 'wheel_dyno_rls_R5',
  rls_hubdyno_fixed_case_F = 'rls_hubdyno_case_F',
  rls_hubdyno_fixed_case_R = 'rls_hubdyno_case_R'
}

-- State -------------------------------------------------------------------------------------------

local pending = {}
local grounding = {}
local ignoreReset = {}

-- Helpers -----------------------------------------------------------------------------------------

local function migratePath(path)
  if type(path) ~= 'string' then return path end
  return (path:gsub('[^/]+', legacyParts))
end

local function dynoAxle(origin)
  if origin == 'wheel_dyno_rls_F5' or origin == 'rls_hubdyno_case_F' then return 'F' end
  if origin == 'wheel_dyno_rls_R5' or origin == 'rls_hubdyno_case_R' then return 'R' end
end

local function walk(node, fn)
  if type(node) ~= 'table' then return end
  fn(node)
  for _, child in pairs(node.children or {}) do walk(child, fn) end
end

local function dynoAxlesIn(partsTree)
  local axles = {}
  walk(partsTree, function(node)
    if node.chosenPartName == 'wheel_dyno_rls_F5' then axles.F = true end
    if node.chosenPartName == 'wheel_dyno_rls_R5' then axles.R = true end
  end)
  return axles
end

-- Legacy part migration ---------------------------------------------------------------------------

local function configNeedsMigration(sourceConfig)
  local needed = sourceConfig.rlsHubDynoSavedBrakes ~= nil
  for slot, part in pairs(sourceConfig.parts or {}) do
    if legacyParts[slot] or legacyParts[part] then needed = true end
  end
  walk(sourceConfig.partsTree, function(node)
    if legacyParts[node.chosenPartName] or legacyParts[node.id] or migratePath(node.path) ~= node.path then needed = true end
  end)
  return needed
end

-- A current slot already in the config wins over its legacy twin.
local function migrateSlotParts(parts)
  local migrated = {}
  for slot, part in pairs(parts) do
    if not legacyParts[slot] then migrated[slot] = legacyParts[part] or part end
  end
  for slot, part in pairs(parts) do
    if legacyParts[slot] and migrated[legacyParts[slot]] == nil then
      migrated[legacyParts[slot]] = legacyParts[part] or part
    end
  end
  return migrated
end

local function migrateNodeNames(node)
  node.chosenPartName = legacyParts[node.chosenPartName] or node.chosenPartName
  node.id = legacyParts[node.id] or node.id
  node.path = migratePath(node.path)
end

-- Clears brakes on dyno axles into the saved choices, and puts saved brakes back on the other axle.
local function parkBrakes(partsTree, axles, saved, changed)
  walk(partsTree, function(node)
    local slot = node.id or ''
    local axle = slot:match('_brakes?_([FR])$') or slot:match('_brakes?_([FR])_')
    if not axle then return end
    local key = node.path or slot
    if axles[axle] and (node.chosenPartName or '') ~= '' then
      saved[key] = {part = node.chosenPartName, children = node.children}
      node.chosenPartName, node.children, node.decisionMethod = '', nil, 'user-empty'
      changed = true
    elseif not axles[axle] and saved[key] then
      if (node.chosenPartName or '') == '' then
        node.chosenPartName = saved[key].part
        node.children = saved[key].children
        node.decisionMethod = 'user'
      end
      saved[key] = nil
      changed = true
    end
  end)
  return changed
end

-- Bearing offsets ---------------------------------------------------------------------------------

-- Hub tuning applies after inherited frame transforms; the lowest wheel-bearing node sets each axle's floor.
local function applyHubOffsets(nodes)
  local floors = {}
  for _, node in pairs(nodes) do
    local axle = dynoAxle(node.partOrigin)
    if axle and node.rlsDynoHubOffset then
      node.pos.x = node.pos.x + node.rlsDynoHubOffset
    end
    if axle and node.name and node.name:match('^[fr]wdb[23]') then
      floors[axle] = math.min(floors[axle] or math.huge, node.pos.z)
    end
  end
  return floors
end

local function lowerBearingNodes(nodes, floors, floor)
  for _, node in pairs(nodes) do
    local axle = dynoAxle(node.partOrigin)
    if axle and node.name and node.name:match('^[fr]wdb[23]') then
      node.pos.z = node.pos.z + floor - floors[axle]
    end
  end
end

-- Scales the feet about their upper mount so they stay attached to the housing while the sole reaches the floor.
local function extendFeet(flexbodies, floors, floor)
  for _, flexbody in pairs(flexbodies) do
    local axle = dynoAxle(flexbody.partOrigin)
    if axle and flexbody.pos and (flexbody.mesh or ''):match('^rls_hubdyno_feetD*$') then
      local extension = floors[axle] - floor
      flexbody.scale = flexbody.scale or {x=1, y=1, z=1}
      local scale = flexbody.scale.z or 1
      local newScale = scale + extension / (FEET_TOP - FEET_BOTTOM)
      flexbody.pos.z = (flexbody.pos.z or 0) + FEET_TOP * (scale - newScale)
      flexbody.scale.z = newScale
    end
  end
end

-- Per-frame update --------------------------------------------------------------------------------

-- Level pass: square the axle to the level wheel nodes before the vertical drop.
local function levelAxle(id, state, veh, data, pos)
  local firstPos, lastPos
  for _, node in pairs(data.vdata.nodes) do
    if node.name == 'fwdb1l' or (not firstPos and node.name == 'rwdb1l') then firstPos = veh:getNodePosition(node.cid) end
    if node.name == 'fwdb4l' or (not lastPos and node.name == 'rwdb4l') then lastPos = veh:getNodePosition(node.cid) end
  end
  local dir = firstPos and lastPos and (lastPos - firstPos) or veh:getDirectionVector()
  dir.z = 0
  if dir:squaredLength() > 0.01 then
    local rot = quat(0,0,1,0) * quatFromDir(dir:normalized(), vec3(0,0,1))
    ignoreReset[id] = 1
    veh:setPosRot(pos.x,pos.y,pos.z,rot.x,rot.y,rot.z,rot.w)
  end
  state.level = false
  state.delay = 0.15
end

-- Drop pass: lowers the dyno until its feet touch the floor, then reports whether the readings have settled.
local function dropToGround(id, state, veh, data, pos)
  local correction = -math.huge
  for _, node in pairs(data.vdata.nodes or {}) do
    if node.name and node.name:match('^[fr]wdb[23]') and
        (node.partOrigin == 'wheel_dyno_rls_F5' or node.partOrigin == 'wheel_dyno_rls_R5') then
      local foot = pos + veh:getNodePosition(node.cid)
      local rayStart = foot + vec3(0,0,2)
      local distance = castRayStatic(rayStart, vec3(0,0,-1), 10)
      -- Leave 2 mm of clearance rather than accepting up to 2 mm of penetration.
      if distance and distance < 10 then correction = math.max(correction, 2 - distance + 0.002) end
    end
  end
  if correction > -math.huge and math.abs(correction) > 0.0005 then
    ignoreReset[id] = 1
    local target = pos + vec3(0,0,correction)
    -- Translate all fixed clusters without resetting suspension deflection.
    veh:setClusterPosRelRot(veh:getRefNodeId(),target.x,target.y,target.z,0,0,0,1)
  end
  state.passes = (state.passes or 0) + 1
  state.stablePasses = math.abs(correction) <= 0.0005 and (state.stablePasses or 0) + 1 or 0
  -- The chassis reference keeps moving while suspension settles, so require several settled passes.
  if correction > -math.huge and state.passes < 20 and (state.passes < 8 or state.stablePasses < 3) then
    state.delay = 0.15
  else
    grounding[id] = nil
  end
end

local function settleGrounding(id, state)
  local veh = be:getObjectByID(id)
  local data = core_vehicle_manager.getVehicleData(id)
  if not (veh and data and data.vdata) then
    grounding[id] = nil
    return
  end
  local pos = veh:getPosition()
  -- Normal suspension may leave the old wheel configuration pitched; a bolted-down dyno needs a level base first.
  if state.level then
    levelAxle(id, state, veh, data, pos)
  else
    dropToGround(id, state, veh, data, pos)
  end
end

local function updateVehicle(id)
  local veh = be:getObjectByID(id)
  local data = core_vehicle_manager.getVehicleData(id)
  if not veh or not data or not data.config or not data.config.partsTree then return end
  local config, changed, axles = M.prepareConfig(data.config)
  if changed then
    veh:respawn(serialize(config))
  elseif next(axles) then
    grounding[id] = {delay=0.15, level=true}
  end
end

-- Public API --------------------------------------------------------------------------------------

-- Retired fixed-family configs resolve to the remaining parts before JBeam selection; waiting until onVehicleSpawned would already lose missing hubs.
M.migrateConfig = function(sourceConfig)
  if type(sourceConfig) ~= 'table' then return sourceConfig, false end
  if not configNeedsMigration(sourceConfig) then return sourceConfig, false end
  local config = deepcopy(sourceConfig)
  if config.parts then config.parts = migrateSlotParts(config.parts) end
  walk(config.partsTree, migrateNodeNames)
  local saved = config.rlsOverhaulDynoSavedBrakes or {}
  for key, choice in pairs(config.rlsHubDynoSavedBrakes or {}) do
    key = migratePath(key)
    if saved[key] == nil then
      saved[key] = choice
      walk(choice, migrateNodeNames)
    end
  end
  config.rlsOverhaulDynoSavedBrakes = next(saved) and saved or nil
  config.rlsHubDynoSavedBrakes = nil
  return config, true
end

-- Prepare before a career spawn so removing brakes does not trigger a second respawn after the session has positioned its vehicle.
M.prepareConfig = function(sourceConfig)
  local migrated, changed = M.migrateConfig(sourceConfig)
  if type(migrated) ~= 'table' or not migrated.partsTree then return deepcopy(migrated), changed, {} end
  local axles = dynoAxlesIn(migrated.partsTree)
  local savedSource = migrated.rlsOverhaulDynoSavedBrakes
  if not next(axles) and not (type(savedSource) == 'table' and next(savedSource)) then
    return migrated, changed, axles
  end
  local config = deepcopy(migrated)
  local saved = config.rlsOverhaulDynoSavedBrakes or {}
  changed = parkBrakes(config.partsTree, axles, saved, changed)
  if changed then
    config.rlsOverhaulDynoSavedBrakes = next(saved) and saved or nil
  end
  return config, changed, axles
end

-- Game hooks --------------------------------------------------------------------------------------

M.onJbeamLoadingPhase1 = function(_, _, vehicle)
  local floors = applyHubOffsets(vehicle.nodes or {})
  if not floors.F or not floors.R then return end
  local floor = math.min(floors.F, floors.R)
  lowerBearingNodes(vehicle.nodes or {}, floors, floor)
  extendFeet(vehicle.flexbodies or {}, floors, floor)
end

M.onVehicleSpawned = function(id) pending[id] = true end
M.onVehicleDestroyed = function(id) pending[id] = nil; grounding[id] = nil; ignoreReset[id] = nil end
M.onVehicleResetted = function(id)
  if not grounding[id] and not ignoreReset[id] then pending[id] = true end
end

M.onUpdate = function(dtReal)
  for id, t in pairs(ignoreReset) do
    ignoreReset[id] = t - (dtReal or 0)
    if ignoreReset[id] <= 0 then ignoreReset[id] = nil end
  end
  if next(pending) then
    local work = pending
    pending = {}
    for id in pairs(work) do updateVehicle(id) end
  end
  for id, state in pairs(grounding) do
    state.delay = state.delay - (dtReal or 0)
    if state.delay <= 0 then settleGrounding(id, state) end
  end
end

-- Overhaul's saved configs may still name the legacy fixed dyno parts; level loads replace core_vehicle_partmgmt.
M.onExtensionLoaded = function()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return rawget(_G, 'core_vehicle_partmgmt') end, {
    buildConfigFromString = function(original)
      if type(original) ~= 'function' then return end
      return function(...)
        local config, chosen = original(...)
        return M.migrateConfig(config), chosen
      end
    end,
  })
  for i = 0, be:getObjectCount() - 1 do pending[be:getObject(i):getID()] = true end
end
M.onExtensionUnloaded = function()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

return M
