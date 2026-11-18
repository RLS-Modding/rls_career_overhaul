local M={}
M.message='Race lane blocked. Move the obstructing vehicle off the strip before racing.'
function M.new(v,venues)
  local segments={}
  local function add(a,b,first)
    a,b=vec3(a),vec3(b)
    local delta=b-a;local length=delta:length()
    local forward=delta/length
    local right=vec3(forward.y,-forward.x,0):normalized()
    local up=right:cross(forward)
    local behind=first and 8 or 0
    segments[#segments+1]={center=(a+b)*0.5-forward*(behind/2)+up,
      forward=forward*((length+behind)/2),right=right*v.laneWidth,up=up*1.5,
      radius=math.sqrt((length+behind)^2/4+v.laneWidth^2+2.25)}
  end
  if v.centerline then
    for i=1,#v.centerline-1 do add(v.centerline[i],v.centerline[i+1],i==1) end
  else add(v.start,venues.position(v,v.length,0),true) end
  local self={}
  function self.find(engine,playerId,opponentId)
    for i=0,engine:getObjectCount()-1 do
      local car=engine:getObject(i)
      local id=car:getID()
      if id~=playerId and id~=opponentId and car:getActive() and not car:isHidden() then
        local box=car:getSpawnWorldOOBB()
        local center,half=box:getCenter(),box:getHalfExtents()
        local x,y,z=box:getAxis(0)*half.x,box:getAxis(1)*half.y,box:getAxis(2)*half.z
        local radius=half:length()
        for _,segment in ipairs(segments)do
          if center:squaredDistance(segment.center)<=(radius+segment.radius)^2
            and overlapsOBB_OBB(center,x,y,z,segment.center,segment.forward,segment.right,segment.up) then return id end
        end
      end
    end
  end
  return self
end
return M
