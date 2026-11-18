local schedule=require('overhaul/career/economy/streetKnights/schedule').config
local M={}
function M.new(env)
  local self={}
  local config=env.jsonReadFile('/gameplay/overhaul/streetKnights/raid.json') or {}
  local enabled=type(config.chance)=='number'
  local records,units={},{}
  local current,storage,target,pursuing,cleanup,group,activation
  local retry=0
  local function object(id) return env.be:getObjectByID(id) end
  local function police() return env.overhaul_integration_services_police end
  local function persist()
    if not storage then return false end
    env.overhaul_career_saveSystem.jsonWriteFileSafe(storage,{version=1,records=records},true)
    local saved=env.jsonReadFile(storage)
    return saved and saved.records and current and saved.records[current.key] and saved.records[current.key].state==current.record.state
  end
  local function visible(pos)
    local camera=env.core_camera.getPosition()
    if (env.vec3(pos)-camera):dot(env.core_camera.getForward())< -5 then return false end
    for _,offset in ipairs({env.vec3(0,0,0.5),env.vec3(0,0,2),env.vec3(2.5,1,1),env.vec3(-2.5,-1,1)})do
      local delta=env.vec3(pos)+offset-camera;local distance=delta:length()
      if distance<1 or env.castRayStatic(camera,delta/distance,distance)>=distance-0.5 then return true end
    end
    return false
  end
  local function clearSpace(pos,own)
    for i=0,env.be:getObjectCount()-1 do
      local car=env.be:getObject(i)
      if car:getID()~=own and car:getPosition():squaredDistance(pos)<225 then return false end
    end
    return true
  end
  local function approach(pos,target)
    local graph=env.map.getGraphpath()
    if not graph then return end
    local a,b=env.map.findClosestRoad(env.vec3(pos))
    local c,d=env.map.findClosestRoad(env.vec3(target))
    local best,direction=math.huge
    for _,start in ipairs({a,b})do for _,finish in ipairs({c,d})do
      local path=graph:getPath(start,finish)
      if path[#path]==finish then
        local distance=(env.vec3(pos)-graph.positions[start]):length()+(env.vec3(target)-graph.positions[finish]):length()
        for i=2,#path do distance=distance+(graph.positions[path[i]]-graph.positions[path[i-1]]):length()end
        if distance<best then
          local heading=graph.positions[path[1]]-env.vec3(pos)
          if heading:length()<5 then heading=(graph.positions[path[2]] or env.vec3(target))-env.vec3(pos)end
          heading.z=0
          best=distance;direction=heading:length()>0 and heading/heading:length() or nil
        end
      end
    end end
    return best,direction
  end
  local function placement(venue,own,target)
    target=target or venue.parking
    local angle=math.random()*math.pi*2
    local found,valid=env.gameplay_traffic_trafficUtils.findSpawnPoint(env.vec3(target),env.vec3(math.cos(angle),math.sin(angle),0),
      config.minSpawnDistance or 350,config.maxSpawnDistance or 800,config.minSpawnDistance or 350,{minDrivability=0.5,minRadius=2.5})
    if not valid or not found or visible(found.pos) or not clearSpace(found.pos,own) then return end
    local distance,direction=approach(found.pos,target)
    if not distance or distance>(config.maxSpawnDistance or 800) then return end
    found.dir=direction or found.dir
    return found
  end
  local function destroy()
    if activation then
      if activation.job and env.core_jobsystem.cancelJob then env.core_jobsystem.cancelJob(activation.job) end
      activation=nil
    end
    for _,unit in ipairs(units)do
      local car=object(unit.id)
      if car then
        env.gameplay_traffic.removeTraffic(unit.id,true)
        car:delete()
      end
    end
    units={};group=nil;cleanup=false
  end
  function self.clear()
    if pursuing and target and police() then police().setPursuitMode(0,target, self.ids()) end
    destroy();current=nil;target=nil;pursuing=false;retry=0
  end
  function self.configure(profile)
    self.clear()
    if not enabled then return end
    storage=env.overhaul_career_saveSystem.getSaveRootDirectory()..profile..'/streetKnightsRaids.json'
    local saved=env.jsonReadFile(storage)
    if not saved and env.FS:fileExists(storage) then storage=nil;env.log('E','streetKnightsRaid','Raid ledger unreadable; raids disabled.');return end
    records=saved and saved.records or {}
  end
  function self.ids()
    local ids={};for _,unit in ipairs(units)do if object(unit.id)then ids[#ids+1]=unit.id end end;return ids
  end
  function self.isPursuing() return pursuing==true end
  function self.getState() return {pursuing=pursuing==true,prepared=#units,record=current and env.deepcopy(current.record)} end
  function self.devInvite(venue,night,force)
    if pursuing then return false end
    if not storage then return not force end
    destroy();current=nil
    local key=venue.level..':'..venue.id..':'..night
    if force then
      local record={night=night,scheduled=true,state='pending',developerForced=true}
      records[key]=record;current={key=key,record=record,venue=venue}
      return persist()
    end
    local previous=records[key]
    if previous and previous.developerForced and previous.state=='pending' then
      local record={night=night,scheduled=math.random()<(config.chance or 0.25),state='pending'}
      records[key]=record;current={key=key,record=record,venue=venue}
      return persist()
    end
    return true
  end
  local function prepare(venue)
    if #units>=math.min(4,config.policeCount or 2) then return end
    if not group then
      group={}
      for _,level in ipairs({venue.level,'rls_west_coast'})do
        local file=env.jsonReadFile('/levels/'..level..'/police.vehGroup.json')
        for _,build in ipairs(file and file.data or {})do
          if type(build.model)=='string' and type(build.config)=='string' and env.FS:fileExists('/vehicles/'..build.model..'/'..build.config..'.pc') then
            group[#group+1]=env.deepcopy(build)
          end
        end
        if #group>0 then break end
      end
      for i=#group,2,-1 do local j=math.random(i);group[i],group[j]=group[j],group[i] end
    end
    if #group==0 then return end
    local build=group[#units%#group+1]
    if not build then return end
    local spawn=placement(venue)
    if not spawn then return end
    local car=env.core_vehicles.spawnNewVehicle(build.model,{config=build.config,pos=env.vec3(spawn.pos),
      rot=env.quatFromDir(spawn.dir,spawn.normal or env.vec3(0,0,1)),autoEnterVehicle=false,removeTraffic=false,canSpawnAnotherVehicleCheck=false})
    if not car then return end
    car.canSave=false;car.playerUsable=false
    local unit={id=car:getID(),pos=env.vec3(spawn.pos),dir=env.vec3(spawn.dir),ready=false,age=0}
    units[#units+1]=unit
    env.core_vehicleBridge.requestValue(car,function(response)
      if response and response.ping==true and object(unit.id)==car then
        -- SceneObject hiding can leave vehicle meshes hidden after reactivation.
        car:setMeshAlpha(0,'');car:setActive(0);unit.ready=true
      end
    end,'ping')
  end
  local function activate(venue,player)
    if not police() or #units==0 then return false end
    local existing=police().getPursuitData(player:getID())
    if existing and (existing.mode or 0)>0 then return false end
    for _,unit in ipairs(units)do
      local car=object(unit.id)
      if not car then return false end
      if not unit.ready then return false,'preparing' end
      unit.pos:set(car:getPosition())
      if not clearSpace(unit.pos,unit.id) then return false,'occupied' end
      local distance=approach(unit.pos,player:getPosition())
      if not distance or distance>(config.maxSpawnDistance or 800) or visible(unit.pos) then
        local spawn=placement(venue,unit.id,player:getPosition())
        if not spawn then return false end
        unit.pos=env.vec3(spawn.pos);unit.dir=env.vec3(spawn.dir)
        local rot=env.quatFromDir(unit.dir,env.vec3(0,0,1))
        car:setPositionRotation(unit.pos.x,unit.pos.y,unit.pos.z,rot.x,rot.y,rot.z,rot.w)
        car:setActive(0)
      end
    end
    current.record.state='triggered'
    if not persist() then return false end
    target=player:getID()
    for _,unit in ipairs(units)do
      local car=object(unit.id);car:setActive(1);car:setMeshAlpha(1,'')
      car:queueLuaCommand("controller.setFreeze(0);electrics.setIgnitionLevel(2)")
    end
    local ids=self.ids()
    if not police().setupPursuitGameplay(target,ids,{preventAutoStart=true,pursuitMode=config.pursuitMode or 2}) then return false end
    for _,id in ipairs(ids)do
      object(id).playerUsable=false
      local traffic=env.gameplay_traffic.getTrafficData()[id]
      if traffic then
        traffic.enableRespawn=false;traffic.enableAutoPooling=false;traffic:setAiMode('traffic')
        object(id):setMeshAlpha(1,'');traffic.alpha=1;traffic.state='active'
      end
    end
    pursuing=true
    police().setPursuitMode(config.pursuitMode or 2,target,ids)
    local pursuit=police().getPursuitData(target)
    if not pursuit or (pursuit.mode or 0)<=0 then pursuing=false;return false end
    return true
  end
  local function queueActivation(venue,near)
    local pending={}
    activation=pending
    pending.job=env.core_jobsystem.create(function(job)
      while activation==pending do
        local player=env.be:getPlayerVehicle(0)
        if not player or not near(venue,player,config.raidRadius or 1500) then break end
        local activated,waiting=activate(venue,player)
        if activated or (waiting~='preparing' and waiting~='occupied') then
          pending.activated=activated;break
        end
        job.sleep(1)
      end
      pending.job=nil;pending.done=true
    end)
  end
  function self.onPursuitAction(id,action)
    if not pursuing then return end
    -- Police can move the pursuit onto a newly entered vehicle without an end
    -- action on the previous id; accept the moved target before the end check.
    if id~=target then
      local player=env.be:getPlayerVehicle(0)
      local playerId=player and player:getID()
      if id==playerId then
        local pursuit=police() and police().getPursuitData(id)
        if pursuit and (pursuit.mode or 0)>0 then target=id end
      end
    end
    if id==target and (action=='evade' or action=='arrest' or action=='reset' or action=='release') then
      pursuing=false;cleanup=true
    end
  end
  function self.update(context)
    if not storage then return false end
    if activation and activation.done and activation.activated then activation=nil;return true end
    if cleanup then
      local hidden=true
      for _,unit in ipairs(units)do
        local car=object(unit.id)
        if car then
          local distance=(car:getPosition()-env.core_camera.getPosition()):length()
          if distance<150 or (distance<1500 and visible(car:getPosition())) then hidden=false end
        end
      end
      if hidden then destroy();current=nil end
      return false
    end
    if pursuing then
      local player=context.player
      local id=player and player:getID()
      local pursuit=id and id~=target and police().getPursuitData(id)
      if pursuit and (pursuit.mode or 0)>0 then target=id end
      return false
    end
    local dt=context.dtReal or 0
    retry=math.max(0,retry-dt)
    for i=#units,1,-1 do
      local unit=units[i]
      if not unit.ready then
        unit.age=unit.age+dt
        if unit.age>=15 then
          local car=object(unit.id)
          if car then car:delete() end
          table.remove(units,i)
        end
      end
    end
    if current and context.time>=(current.record.night+1)*24+schedule.meetCloseHour then
      if not activation then
        local canRaid=context.player and context.near(current.venue,context.player,config.raidRadius or 1500)
        if current.record.state=='pending' and canRaid then queueActivation(current.venue,context.near);return false end
      elseif not activation.done then
        return false
      end
      if current.record.state=='pending' then current.record.state='skipped';persist() end
      destroy();current=nil;return false
    end
    if not context.open or not context.venue or not context.player or not context.near(context.venue,context.player,config.attendanceRadius or 800) then
      return false
    end
    local key=context.venue.level..':'..context.venue.id..':'..context.night
    if current and current.key~=key then destroy();current=nil end
    if not current then
      local record=records[key]
      if not record then
        record={night=context.night,scheduled=math.random()<(config.chance or 0.25),state='pending'}
        records[key]=record
      end
      current={key=key,record=record,venue=context.venue}
      if not persist() then destroy();current=nil;return false end
    end
    if current.record.scheduled and current.record.state=='pending' and retry==0 then
      retry=2
      prepare(current.venue)
    end
    return false
  end
  return self
end
return M
