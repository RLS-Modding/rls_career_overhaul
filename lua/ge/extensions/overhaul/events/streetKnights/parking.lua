local M={}
function M.isParked(venue,vehicle,axes)
  if not venue or not venue.parking or not vehicle or vehicle:getVelocity():length()>0.1 then return false end
  local forward,right=axes({heading=venue.parkingHeading or venue.heading})
  forward,right=vec3(forward),vec3(right)
  local anchor=vec3(venue.parking)
  local bounds=vehicle:getSpawnWorldOOBB()
  local bottom=math.huge
  for corner=0,7 do
    local delta=bounds:getPoint(corner)-anchor
    if math.abs(delta:dot(right))>(venue.parkingWidth or 4)/2 or math.abs(delta:dot(forward))>(venue.parkingLength or 8)/2 then return false end
    bottom=math.min(bottom,delta.z)
  end
  return math.abs(bottom)<=1.5
end
return M
