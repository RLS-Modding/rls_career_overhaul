-- Checkpoint-only coupling data. Never include it in a shared configuration.
local M = {}
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function nodeByName(name)
  local found
  for _,node in pairs(v.data.nodes or {}) do
    if node.name==name then if found then return nil end;found=node end
  end
  return found
end
local function endpoint(cid)
  local node=v.data.nodes[cid]
  if not node or type(node.name)~='string' or nodeByName(node.name)~=node then error('A connected coupling node has no stable name.') end
  local fifthwheel=false
  for _,entry in pairs(v.data.controller or {}) do
    if entry.fileName=='couplings/fifthwheel' then
      local data=v.data[entry.name or entry.fileName] or {}
      if (data.fifthwheelNode or entry.fifthwheelNode)==node.name then fifthwheel=true end
    end
  end
  local canAttach=fifthwheel or (node.couplerTag~=nil and not node.couplerWeld and not node.couplerLock)
  local result={cid=cid,name=node.name,canAttach=canAttach==true,kind=fifthwheel and 'fifthwheel' or canAttach and 'basic' or 'target'}
  if canAttach then
    result.strength=node.couplerStrength or (fifthwheel and 10000000 or 1000000)
    result.radius=node.couplerRadius or (fifthwheel and .5 or .2)
    result.lockRadius=node.couplerLockRadius or .025
    result.latchSpeed=node.couplerLatchSpeed or .3
    for _,key in ipairs({'strength','radius','lockRadius','latchSpeed'}) do
      if not finite(result[key]) or result[key]<=0 then error('A connected coupling has invalid settings.') end
    end
  end
  return result
end
function M.capture()
  local result={}
  for cid,attached in pairs(beamstate.attachedCouplers or {}) do
    if attached.obj2id~=obj:getID() then
      result[#result+1]={node=endpoint(cid),otherVehicleId=attached.obj2id,otherNodeCid=attached.obj2nodeId}
    end
  end
  return result
end
-- The GE owner resolves both endpoints by name after respawning. Only the saved
-- initiating side attaches, and native callbacks must confirm both endpoints.
function M.restore(expected,attach)
  local byCid,missing={},{}
  for _,edge in ipairs(expected or {}) do
    local node=nodeByName(edge.name)
    if not node or node.cid~=edge.cid or byCid[node.cid] then return false,'A saved coupling node is missing or changed.' end
    byCid[node.cid]=edge
  end
  for cid,current in pairs(beamstate.attachedCouplers or {}) do
    if current.obj2id~=obj:getID() then
      local edge=byCid[cid]
      if not edge or current.obj2id~=edge.otherVehicleId or current.obj2nodeId~=edge.otherNodeCid then
        return false,'A vehicle connected to a different coupling on the way back.'
      end
    end
  end
  for cid,edge in pairs(byCid) do
    local current=beamstate.attachedCouplers[cid]
    if not current then
      missing[#missing+1]=edge
    elseif current.obj2id~=edge.otherVehicleId or current.obj2nodeId~=edge.otherNodeCid then
      return false,'A saved coupling node is already occupied.'
    end
  end
  -- Validate every endpoint before issuing any native operation.
  for _,edge in ipairs(missing) do
    if edge.settings then
      local actual=endpoint(edge.cid)
      if not actual.canAttach then return false,'A saved coupling can no longer be attached.' end
      for _,key in ipairs({'strength','radius','lockRadius','latchSpeed'}) do
        if actual[key]~=edge.settings[key] then return false,'A saved coupling setting changed.' end
      end
    end
  end
  for _,edge in ipairs(missing) do
    if attach and edge.settings then
      local s=edge.settings
      obj:attachExternalCoupler(edge.cid,edge.otherVehicleId,edge.otherNodeCid,s.strength,s.radius,s.lockRadius,s.latchSpeed,0)
    end
  end
  return true,nil,#missing==0
end
return M
