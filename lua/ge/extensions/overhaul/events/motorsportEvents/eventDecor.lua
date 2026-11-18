-- Owns venue static visibility, collision, and deferred material setup.
-- motorsportEvents.lua calls sync/invalidate for scene state changes and shutdown to restore authored props.
local M = {}
local GROUPS = {'dragEvent_parked', 'dragEvent_barriers'}
local SHAPES = '/art/shapes/motorsport/parked_vehicles/'
local MATERIALS = SHAPES .. 'main.materials.json'
local phases = {registration = true, playerQualifying = true, qualifying = true, eliminations = true}
local cachedLevel, cachedGroup, appliedState
local synced, cachedEditing, cachedHidden = false
local objects = {}
local materialObjects, materialDefinitions, materialsPrepared
local materialsRetryAt
local collisionDirty = false

local function editorActive()
  return editor and (editor.active == true or editor.isEditorActive and editor.isEditorActive()) or false
end

local function objectById(id)
  local object = scenetree and scenetree.findObjectById and scenetree.findObjectById(id)
  return object and Sim and Sim.upcast and Sim.upcast(object) or object
end

local function retryMaterials(error)
  materialsRetryAt = os.clock() + 5
  log('E', 'motorsportEvents', 'Parked-car materials: ' .. tostring(error))
  return false
end

local function prepareMaterials()
  if not materialObjects then
    materialObjects = {}
    for _, row in pairs(objects) do
      local object = objectById(row.id)
      local ok, shape = pcall(function()
        local shape = object:getField('shapeName', 0)
        return shape:sub(1, #SHAPES) == SHAPES and shape or nil
      end)
      if ok and shape then materialObjects[shape] = row.id end
    end
    if next(materialObjects) then
      materialDefinitions = FS:fileExists(MATERIALS) and jsonReadFile(MATERIALS)
      if type(materialDefinitions) ~= 'table' then materialObjects = nil; return false end
    end
  end
  if materialsPrepared then return true end
  if not next(materialObjects) then materialsPrepared = true; return true end
  if materialsRetryAt and os.clock() < materialsRetryAt then return false end
  local player = be and be:getPlayerVehicle(0)
  if not player or player:getVelocity():length() > .5 then return false end
  for name in pairs(materialDefinitions) do
    if not scenetree.findObject(name) then
      if not loadJsonMaterialsFile then return false end
      local ok, error = pcall(loadJsonMaterialsFile, MATERIALS)
      if not ok then return retryMaterials(error) end
      break
    end
  end
  for shape, id in pairs(materialObjects) do
    local object = objectById(id)
    if object then
      local constructor
      local ok, error = pcall(function()
        for index = 0, object:getTargetCount() - 1 do
          local name = object:getTargetName(index)
          if materialDefinitions[name] then
            local material = scenetree.findObject(name)
            assert(material)
            object:changeMaterial(name, material, material)
          end
        end
        constructor = createObject('TSShapeConstructor')
        constructor:setField('baseShape', 0, shape)
        constructor.canSave = false
        constructor:registerObject('rlsMotorsportDecorShape' .. id)
        constructor:notifyShapeChanged()
      end)
      if constructor then pcall(function() constructor:delete() end) end
      if not ok then return retryMaterials(shape .. ': ' .. tostring(error)) end
    end
    materialObjects[shape] = nil
  end
  materialsPrepared = true
  return true
end

local function flushCollisionChanges()
  if not collisionDirty then return end
  be:reloadCollision()
  collisionDirty = false
end

local function originalCollision(row)
  return (row.originalHidden or not row.originalRenderEnabled) and 'None' or row.originalCollisionType
end

local function setState(row, hidden, renderEnabled, collisionType)
  local object = objectById(row.id)
  if not object then return end
  if row.collisionManaged then
    local target = collisionType or ((hidden or not renderEnabled) and 'None' or 'Collision Mesh')
    if object:getField('collisionType', 0) ~= target then
      object:preApply()
      object:setField('collisionType', 0, target)
      object:postApply()
      collisionDirty = true
    end
  end
  pcall(function()
    if object:getClassName() == 'TSStatic' and object:isHidden() ~= hidden then object:setHidden(hidden) end
  end)
  pcall(function()
    local value = object:getField('isRenderEnabled', 0)
    local enabled = value ~= '0' and value ~= 'false'
    if enabled ~= renderEnabled then object:setRenderEnabled(renderEnabled) end
  end)
end

local function restore(show)
  if cachedLevel ~= getCurrentLevelIdentifier() then return end
  for _, row in pairs(objects) do
    local hidden = row.originalHidden
    if show then hidden = false end
    setState(row, hidden, show or row.originalRenderEnabled, show and 'Collision Mesh' or originalCollision(row))
  end
end

local function resolve(ref)
  if type(ref) == 'number' then return objectById(ref) end
  if type(ref) == 'string' then return scenetree.findObject(ref) end
  return ref
end

local function collect(groups)
  local found, seen = {}, {}
  local function visit(object, barrier)
    if not object then return end
    local ok, id, class = pcall(function() return object:getID(), object:getClassName() end)
    if not ok or seen[id] then return end
    seen[id] = true
    if class == 'SimGroup' then
      local listed, count = pcall(function() return object:getCount() end)
      if listed and type(count) == 'number' then
        for i = 0, count - 1 do
          local childOk, child = pcall(function() return object:getObject(i) end)
          if childOk then visit(resolve(child), barrier) end
        end
      end
    elseif class == 'TSStatic' then
      local prior = objects[id]
      local readable, hidden, render = pcall(function() return object:isHidden(), object:getField('isRenderEnabled', 0) end)
      if readable then
        found[id] = prior or {id = id, originalHidden = hidden == true, originalRenderEnabled = render ~= '0' and render ~= 'false'}
        found[id].barrier = barrier
        if not prior then found[id].originalCollisionType = object:getField('collisionType', 0) end
        local shape = object:getField('shapeName', 0)
        found[id].collisionManaged = barrier or shape:sub(1, #SHAPES) == SHAPES
      end
    end
  end
  for _, group in ipairs(groups) do visit(group.object, group.barrier) end
  for id, row in pairs(objects) do if not found[id] then setState(row, row.originalHidden, row.originalRenderEnabled, originalCollision(row)) end end
  objects = found
end

function M.update()
  if not synced then return end
  if appliedState then
    if cachedHidden and not materialsPrepared then prepareMaterials() end
    return
  end
  if not prepareMaterials() then return end
  for _, row in pairs(objects) do setState(row, cachedHidden, not cachedHidden) end
  appliedState = true
  flushCollisionChanges()
end

function M.sync(eventState)
  local level = getCurrentLevelIdentifier()
  if cachedLevel ~= level then
    objects, cachedGroup, appliedState, cachedLevel, materialObjects, materialDefinitions, materialsPrepared, materialsRetryAt, collisionDirty = {}, nil, nil, level, nil, nil, nil, nil, false
    synced = false
  end
  local editing = editorActive()
  local active = eventState and eventState.level == level and (not eventState.discipline or eventState.discipline == 'drag') and phases[eventState.phase] == true
  local hidden = not (editing or active)
  if synced and cachedEditing == editing and cachedHidden == hidden then
    return M.update()
  end
  synced, cachedEditing, cachedHidden = true, editing, hidden
  local groups, groupIds = {}, {}
  for _, name in ipairs(GROUPS) do
    local group = scenetree and scenetree.findObject and scenetree.findObject(name)
    local ok, id = pcall(function() return group and group:getClassName() == 'SimGroup' and group:getID() or nil end)
    if ok and id then
      groups[#groups + 1] = {object = group, barrier = name == 'dragEvent_barriers'}
      groupIds[#groupIds + 1] = name .. ':' .. id
    end
  end
  if #groups == 0 then
    if cachedGroup then restore(editorActive()); objects, cachedGroup, appliedState, materialObjects, materialDefinitions, materialsPrepared, materialsRetryAt = {}, nil, nil, nil, nil, nil, nil end
    appliedState = true
    flushCollisionChanges()
    return
  end
  local groupId = table.concat(groupIds, '|')
  if cachedGroup and cachedGroup ~= groupId then restore(editing); objects, materialObjects, materialDefinitions, materialsPrepared, materialsRetryAt = {}, nil, nil, nil, nil end
  cachedGroup = groupId
  collect(groups)
  if hidden then prepareMaterials() end
  local ready = hidden or prepareMaterials()
  for _, row in pairs(objects) do
    local objectHidden = hidden or not ready and not row.barrier
    setState(row, objectHidden, not objectHidden)
  end
  appliedState = ready or nil
  flushCollisionChanges()
end

function M.invalidate() synced = false end

function M.shutdown()
  restore(editorActive())
  flushCollisionChanges()
  objects, cachedLevel, cachedGroup, appliedState, materialObjects, materialDefinitions, materialsPrepared, materialsRetryAt = {}, nil, nil, nil, nil, nil, nil, nil
  synced = false
end

return M
