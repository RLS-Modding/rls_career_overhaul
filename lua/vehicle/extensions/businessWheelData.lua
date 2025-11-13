local M = {}

local acos = math.acos
local deg = math.deg

local enabledVehicles = {}

local function updateGFX(dt)
  local vehId = obj:getID()
  if not vehId or not enabledVehicles[vehId] then
    return
  end
  
  if not v or not v.data or not v.data.wheels or not wheels then
    return
  end
  
  local vehForward = obj:getDirectionVector()
  local vehRight = obj:getDirectionVectorRight()
  if not vehRight then
    local vehUp = obj:getDirectionVectorUp()
    if not vehUp then
      vehUp = vec3(0, 0, 1)
    end
    vehRight = vehForward:cross(vehUp)
    vehRight:normalize()
  end
  
  local surfaceUp = vec3()
  local count = 0
  
  for i = 0, wheels.wheelRotatorCount - 1 do
    local wheel = wheels.wheelRotators[i]
    local nodeId = wheel.lastTreadContactNode
    if nodeId then
      local pos = obj:getNodePosition(nodeId) + obj:getPosition()
      local normal = mapmgr.surfaceNormalBelow(pos, 0.1)
      surfaceUp:setAdd(normal)
      count = count + 1
    end
  end
  
  if count == 0 then
    return
  end
  
  surfaceUp:setScaled(1 / count)
  local surfaceRight = vehForward:cross(surfaceUp)
  surfaceRight:normalize()
  local surfaceForward = surfaceUp:cross(surfaceRight)
  surfaceForward:normalize()
  
  local data = {}
  for _,wd in pairs(v.data.wheels) do
    local name = wd.name
    local wheelData = {name = name}
    
    if wd.steerAxisUp and wd.steerAxisDown then
      local casterSign = -obj:nodeVecCos(wd.steerAxisUp, wd.steerAxisDown, surfaceForward)
      wheelData.caster = deg(acos(obj:nodeVecPlanarCos(wd.steerAxisUp, wd.steerAxisDown, surfaceUp, surfaceForward))) * sign(casterSign)
      wheelData.sai = deg(acos(obj:nodeVecPlanarCos(wd.steerAxisUp, wd.steerAxisDown, surfaceUp, surfaceRight)))
    end
    
    wheelData.camber = (90 - deg(acos(obj:nodeVecPlanarCos(wd.node2, wd.node1, surfaceUp, surfaceRight))))
    local toeSign = obj:nodeVecCos(wd.node1, wd.node2, vehForward)
    wheelData.toe = deg(acos(obj:nodeVecPlanarCos(wd.node1, wd.node2, vehRight, vehForward)))
    if wheelData.toe > 90 then
      wheelData.toe = (180 - wheelData.toe) * sign(toeSign)
    else
      wheelData.toe = wheelData.toe * sign(toeSign)
    end
    
    if isnan(wheelData.toe) or isinf(wheelData.toe) then
      wheelData.toe = 0
    end
    if isnan(wheelData.camber) or isinf(wheelData.camber) then
      wheelData.camber = 0
    end
    if wheelData.caster and (isnan(wheelData.caster) or isinf(wheelData.caster)) then
      wheelData.caster = 0
    end
    if wheelData.sai and (isnan(wheelData.sai) or isinf(wheelData.sai)) then
      wheelData.sai = 0
    end
    
    table.insert(data, wheelData)
  end
  
  obj:queueGameEngineLua("career_modules_business_businessComputer.onVehicleWheelDataUpdate(" .. vehId .. ", '" .. jsonEncode(data):gsub("'", "\\'"):gsub("\\", "\\\\") .. "')")
end

local function enableWheelData()
  local vehId = obj:getID()
  if vehId then
    enabledVehicles[vehId] = true
  end
end

local function disableWheelData()
  local vehId = obj:getID()
  if vehId then
    enabledVehicles[vehId] = nil
  end
end

M.updateGFX = updateGFX
M.enableWheelData = enableWheelData
M.disableWheelData = disableWheelData

return M

