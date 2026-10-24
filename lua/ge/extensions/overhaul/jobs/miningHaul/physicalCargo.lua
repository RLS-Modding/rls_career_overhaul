-- Physical cargo geometry and truck bed containment.
-- Callers supply objects and bed settings; sampling and transforms retain their units.
local M = {}

local DEFAULT_BED = {
  offsetBack = 3.0,
  offsetSide = -0.45,
  length = 6.0,
  width = 2.4,
  floorHeight = 0.3,
  loadHeight = 3.5
}

local function toVec3(v)
  if not v then return nil end
  if type(v) == "table" then return vec3(v[1] or v.x or 0, v[2] or v.y or 0, v[3] or v.z or 0) end
  return vec3(v)
end

local function toQuat(v)
  if not v then return quat(0, 0, 0, 1) end
  if type(v) == "table" then return quat(v[1] or 0, v[2] or 0, v[3] or 0, v[4] or 1) end
  return v
end

local function getObjectAxes(obj)
  if not obj then return nil end
  local dir = obj:getDirectionVector():normalized()
  local up = obj:getDirectionVectorUp():normalized()
  local right = dir:cross(up):normalized()
  up = right:cross(dir):normalized()
  return dir, right, up
end

local function getObjectFrame(obj)
  local tf = obj:getTransform()
  return tf:getColumn(0), tf:getColumn(1), tf:getColumn(2), obj:getPosition()
end

local function nodeWorldPointInFrame(obj, nodeIdx, axisX, axisY, axisZ, objPos)
  local nodePos = obj:getNodePosition(nodeIdx)
  if not nodePos then return objPos end
  return objPos - (axisX * nodePos.x) - (axisY * nodePos.y) + (axisZ * nodePos.z)
end

local function localPointToWorld(obj, localPoint)
  if not obj or not localPoint then return nil end
  local tf = obj:getTransform()
  local axisX, axisY, axisZ = tf:getColumn(0), tf:getColumn(1), tf:getColumn(2)
  local p = toVec3(localPoint)
  return obj:getPosition() - (axisX * p.x) - (axisY * p.y) + (axisZ * p.z)
end

function M.makeBedData(vehicleObj, bedSettings)
  if not vehicleObj then return nil end
  local settings = bedSettings or DEFAULT_BED
  local pos = vehicleObj:getPosition()
  local dir, right, up = getObjectAxes(vehicleObj)
  if not dir then return nil end
  local offsetBack = settings.offsetBack or DEFAULT_BED.offsetBack
  local offsetSide = settings.offsetSide or DEFAULT_BED.offsetSide
  local floorHeight = settings.floorHeight or DEFAULT_BED.floorHeight
  local loadHeight = settings.loadHeight or DEFAULT_BED.loadHeight
  local bedCenter = pos - (dir * offsetBack) + (right * offsetSide) + (up * (floorHeight + loadHeight * 0.5))
  return {
    center = bedCenter,
    axisX = right,
    axisY = dir,
    axisZ = up,
    halfWidth = (settings.width or DEFAULT_BED.width) * 0.5,
    halfLength = (settings.length or DEFAULT_BED.length) * 0.5,
    halfHeight = loadHeight * 0.5,
    settings = settings
  }
end

function M.isPointInBox(point, box)
  if not point or not box then return false end
  local diff = point - box.center
  local localX = diff:dot(box.axisX)
  local localY = diff:dot(box.axisY)
  local localZ = diff:dot(box.axisZ)
  return math.abs(localX) <= box.halfWidth and math.abs(localY) <= box.halfLength and math.abs(localZ) <= box.halfHeight
end

function M.getLoadRatioInBox(objId, box, nodeStep)
  local obj = be:getObjectByID(objId)
  if not obj or not box then return 0 end
  local nodeCount = obj:getNodeCount()
  if not nodeCount or nodeCount <= 0 then
    return M.isPointInBox(obj:getPosition(), box) and 1 or 0
  end
  nodeStep = math.max(1, math.floor(nodeStep or 10))
  local axisX, axisY, axisZ, objPos = getObjectFrame(obj)
  local nodesChecked, nodesInside, lastChecked = 0, 0, -1
  for i = 0, nodeCount - 1, nodeStep do
    nodesChecked = nodesChecked + 1
    lastChecked = i
    if M.isPointInBox(nodeWorldPointInFrame(obj, i, axisX, axisY, axisZ, objPos), box) then nodesInside = nodesInside + 1 end
  end
  if lastChecked ~= nodeCount - 1 then
    nodesChecked = nodesChecked + 1
    if M.isPointInBox(nodeWorldPointInFrame(obj, nodeCount - 1, axisX, axisY, axisZ, objPos), box) then nodesInside = nodesInside + 1 end
  end
  local ratio = nodesChecked > 0 and (nodesInside / nodesChecked) or 0
  if ratio <= 0 and M.isPointInBox(obj:getPosition(), box) then ratio = 0.01 end
  return ratio
end

function M.getBedLoadRatio(objId, vehicleObj, bedSettings, nodeStep)
  return M.getLoadRatioInBox(objId, M.makeBedData(vehicleObj, bedSettings), nodeStep)
end

function M.spawnProp(model, config, pos, rot, options)
  if not model or not pos then return nil end
  options = options or {}
  local spawnOptions = {
    pos = toVec3(pos),
    rot = toQuat(rot),
    config = config or "default",
    autoEnterVehicle = false
  }
  if options.licenseText ~= nil then spawnOptions.licenseText = options.licenseText end
  if options.cling ~= nil then spawnOptions.cling = options.cling end
  if options.safeSpawn ~= nil then spawnOptions.safeSpawn = options.safeSpawn end
  local obj = core_vehicles.spawnNewVehicle(model, spawnOptions)
  return obj and obj:getID() or nil
end

function M.deleteProps(propIds)
  if not propIds then return end
  for _, id in ipairs(propIds) do
    local obj = id and be:getObjectByID(id)
    if obj then obj:delete() end
  end
end

function M.makeBoxFromGameplayArea(areaObj, fallback)
  if not areaObj and not fallback then return nil end
  local pos = areaObj and areaObj:getPosition() or toVec3(fallback.position or fallback.pos)
  if not pos then return nil end
  local axisX, axisY, axisZ = vec3(1, 0, 0), vec3(0, 1, 0), vec3(0, 0, 1)
  if areaObj and areaObj.getTransform then
    local tf = areaObj:getTransform()
    if tf then
      axisX, axisY, axisZ = tf:getColumn(0):normalized(), tf:getColumn(1):normalized(), tf:getColumn(2):normalized()
    end
  elseif fallback and fallback.rotationMatrix then
    local r = fallback.rotationMatrix
    axisX = vec3(r[1] or 1, r[2] or 0, r[3] or 0):normalized()
    axisY = vec3(r[4] or 0, r[5] or 1, r[6] or 0):normalized()
    axisZ = vec3(r[7] or 0, r[8] or 0, r[9] or 1):normalized()
  end
  local scl = nil
  if areaObj and areaObj.getScale then
    local s = areaObj:getScale()
    if s then scl = {s.x or s[1] or 1, s.y or s[2] or 1, s.z or s[3] or 1} end
  end
  scl = scl or (fallback and fallback.scale) or {2, 2, 2}
  return {
    center = pos,
    axisX = axisX,
    axisY = axisY,
    axisZ = axisZ,
    halfWidth = math.max(0.1, tonumber(scl[1]) or 1),
    halfLength = math.max(0.1, tonumber(scl[2]) or 1),
    halfHeight = math.max(0.1, tonumber(scl[3]) or 1)
  }
end

M.toVec3 = toVec3
M.toQuat = toQuat
M.localPointToWorld = localPointToWorld

return M
