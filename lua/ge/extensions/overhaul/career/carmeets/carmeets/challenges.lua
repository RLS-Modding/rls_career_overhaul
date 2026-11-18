local M={}
function M.create(inputs)
  local state,route=inputs.carMeetState,inputs.meetRoute
  local api={}
  local function locationKey()
    local location=state.meetState.location
    if type(location)=='table' then return location.zone and location.zone.name end
    return location
  end
  local function current(data)
    local meet=state.meetState
    return data and meet.active and meet.phase=='showcase' and meet.startTime==data.startTime and locationKey()==data.location
  end
  function api.getChallengeVehicleInventoryId()
    local meet=state.meetState
    if meet.active and meet.phase=='showcase' then return meet.flags and meet.flags.saleInventoryId end
  end
  function api.getChallengeCandidates()
    local meet=state.meetState
    return meet.active and meet.phase=='showcase' and deepcopy(state.carMeetPurchaseVehicles) or {}
  end
  function api.getChallengeReturnData(entry)
    local veh=entry and getObjectByID(entry.vehicleId)
    if not veh or not state.meetState.active or state.meetState.phase~='showcase' then return end
    local pos,rot=veh:getPosition(),veh:getRotation()
    return {entry=deepcopy(entry),position={x=pos.x,y=pos.y,z=pos.z},rotation={x=rot.x,y=rot.y,z=rot.z,w=rot.w},
      startTime=state.meetState.startTime,location=locationKey()}
  end
  function api.routeBackFromChallenge(data)
    if not current(data) then return false end
    local spot=state.meetState.playerSpot
    return spot and route.set(spot.pos,{color={1,0.4,0},step=4,renderDecals=true}) or false
  end
  function api.parkPlayerAtMeet(data,vehicleId)
    local spot=current(data) and state.meetState.playerSpot
    if not spot or not spot.moveResetVehicleTo then return false,'The original meet parking spot is no longer available.' end
    if spot:hasAnyVehicles(vehicleId) then return false,'Your parking spot is occupied.' end
    if not spot:moveResetVehicleTo(vehicleId,false,false,nil,nil,true,false,false) then return false,'Could not park your car at the meet.' end
    route.clear()
    return true
  end
  function api.returnChallengeVehicle(data,veh)
    if not current(data) or not veh then return false end
    for _,entry in ipairs(state.carMeetPurchaseVehicles)do if entry.shopId==data.entry.shopId then return false end end
    veh:setPosRot(data.position.x,data.position.y,data.position.z,data.rotation.x,data.rotation.y,data.rotation.z,data.rotation.w)
    veh:queueLuaCommand('extensions.unload("overhaulStreetKnightsRaceGuard");ai.setMode("disabled");input.event("throttle",0,1);input.event("parkingbrake",1,1);electrics.setIgnitionLevel(0)')
    veh.playerUsable=false
    local entry=deepcopy(data.entry);entry.vehicleId=veh:getID()
    state.spawnedMeetVehicles[#state.spawnedMeetVehicles+1]=entry.vehicleId
    state.carMeetPurchaseVehicles[#state.carMeetPurchaseVehicles+1]=entry
    if gameplay_rawPois then gameplay_rawPois.clear() end
    return true
  end
  return api
end
return M
