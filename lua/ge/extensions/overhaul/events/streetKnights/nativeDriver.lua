-- Repo port: keep native drag APIs behind this RLS adapter and register the owned traction integration.
-- See docs/street-knights.md: repo compatibility and traction control; do not replace shipped BeamNG files.
local M={}
local rules=require('overhaul/career/economy/streetKnights/rules')
local stopTuning=require('overhaul/events/streetKnights/finishStop').tuning
local dragReaction=require('overhaul/lib/events/dragReaction')
local settingsPath='/settings/streetKnights/native.dragSettings.json'
local function send(id,code)
  if not id then return end
  local veh=be:getObjectByID(id)
  if veh then veh:queueLuaCommand(code) end
end
local function releaseControls(id)
  send(id,[[
    electrics.values.throttleOverride=nil
    controller.setFreeze(0)
    local tb=controller.getController('transbrake')
    if tb and tb.setTransbrake then tb.setTransbrake(false) end
    local ts=controller.getController('twoStep') or controller.getController('twoStepLaunch')
    if ts and ts.setTwoStep then ts.setTwoStep(false) end
  ]])
end
function M.create()
  local driver={}
  local venue,id,data,laneIndex,paths,stopping
  local releaseReaction
  local stopNames={}
  local function ownsData() return data and gameplay_drag_core.getData()==data end
  local function clearData()
    overhaul_events_streetKnightsTraction.release()
    if releaseReaction then releaseReaction();releaseReaction=nil end
    if ownsData() then
      gameplay_drag_core.clear({hooks=false,data=true,context=true,extensions=true,ui=true,treeLightStaging=true})
    end
    data=nil
    overhaul_career_saveSystem.getSaveWriter().remove(settingsPath)
  end
  function driver.available()
    local current=gameplay_drag_core.getData()
    return not current or current==data or not current.isStarted or current.isCompleted
  end
  function driver.prepare(v,vehicleId)
    if not driver.available() then return false,'Another drag race is running.' end
    venue=v;id=vehicleId;laneIndex=v.aiSide=='right' and 2 or 1;stopping=false
    send(id,"ai.setMode('manual');ai.setSpeedMode('set');ai.setSpeed(0);controller.setFreeze(1)")
    return driver.initialize()
  end
  local function resetNavigation(nodes)
    map.reset(nodes)
    -- Native traffic retains the node table invalidated by a navgraph replacement.
    if gameplay_traffic.getState()=='on' then gameplay_traffic.onTrafficStarted() end
  end
  local function createPaths()
    local nodes=deepcopy(map.getMap().nodes)
    for lane,side in ipairs({-1,1}) do
      local distances={-6,0}
      for d=10,venue.length-1,10 do distances[#distances+1]=d end
      distances[#distances+1]=venue.length
      for d=10,40,10 do distances[#distances+1]=venue.length+d end
      local names={}
      for i,d in ipairs(distances) do
        local kind=d==-6 and 'spawn' or d==0 and 'stage' or d==venue.length and 'endLine' or d==venue.length+100 and 'end' or ('path'..i)
        local name=venue.id..'_wp_'..kind..'_'..lane
        nodes[name]={pos=vec3(overhaul_events_streetKnightsVenues.position(venue,d,side*venue.laneWidth/2)),radius=1.5,links={},noMerge=true}
        names[#names+1]=name
      end
      for i=1,#names-1 do
        local a,b=names[i],names[i+1]
        local edge={inNode=a,outNode=b,inPos=nodes[a].pos,outPos=nodes[b].pos,inRadius=1.5,outRadius=1.5,drivability=1,oneWay=true,speedLimit=300,lanes='+',type='private'}
        nodes[a].links[b]=edge;nodes[b].links[a]=edge
      end
      stopNames[lane]=names[#names]
    end
    paths=true;resetNavigation(nodes)
  end
  function driver.initialize()
    if data then return true end
    if not driver.available() then return false,'Another drag race is running.' end
    local start=vec3(overhaul_events_streetKnightsVenues.position(venue,0,0))
    local finish=vec3(overhaul_events_streetKnightsVenues.position(venue,venue.length,0))
    overhaul_career_saveSystem.getSaveWriter().mkdir('/settings/streetKnights')
    overhaul_career_saveSystem.getSaveWriter().json(settingsPath,{id='streetKnights',stripId=venue.stripPath,context='activity',dragType='headsUpRace',canBeReseted=false,canBeTeleported=false,
      phases={{name='stage',dependency=true,startedOffset=0},{name='countdown',dependency=true,startedOffset=0.5},{name='race',dependency=false,startedOffset=0},{name='stop',dependency=false,startedOffset=0}},
      prefabs={christmasTree={isUsed=false,treeType='.500'}},
      timers={{id='finish',label='Finish',type='distanceTimer',distance=start:distance(finish),important=true}}},true)
    data=gameplay_drag_core.loadDragDataForMission(settingsPath)
    if not data then return false,'Could not initialize native drag control.' end
    releaseReaction=dragReaction.attach(data)
    if not paths or not map.getMap().nodes[venue.id..'_wp_stage_1'] then createPaths() end
    -- No Prep rules own lane penalties; retain the native corridor for outside-edge mode.
    for index,lane in ipairs(data.strip.lanes) do
      for kind,waypoint in pairs(lane.waypoints) do waypoint.name=venue.id..'_wp_'..kind..'_'..index end
      lane.autoStopName=stopNames[index]
      lane.zone={containsPoint2D=function(_,point)
        if not rules.outsideLaneFouls then return true end
        local d,side=overhaul_events_streetKnightsVenues.project(venue,point)
        return d>=-50 and d<=venue.length+80 and math.abs(side)<=venue.laneWidth*4
      end}
      lane.waypoints.stage.waypoint={speed=0.5,mode='set'}
      lane.waypoints.endLine.waypoint={speed=300,mode='set'}
    end
    return true
  end
  function driver.begin()
    local ok,err=driver.initialize()
    if not ok then return false,err end
    if data.isStarted then return true end
    gameplay_drag_core.setupRacer(id,laneIndex)
    local racer=data.racers[id]
    if not racer then return false,'Could not register the opponent.' end
    racer.isPlayable=false
    if not gameplay_drag_core.startDragRaceActivity(nil) then return false,'Could not start native drag control.' end
    if ui_appContainers then ui_appContainers.hideApp('topCenter','drag') end
    guihooks.trigger('updateTreeLightStaging',false)
    return true
  end
  function driver.state()
    if not data then return {} end
    if not ownsData() then return {fault='Native drag activity was interrupted.'} end
    local lights=data.strip.treeLights and data.strip.treeLights[laneIndex]
    local bulbs=lights and lights.countDownLights or {}
    local result={}
    for _,name in ipairs({'amber1','amber2','amber3','green','red'}) do
      local light=bulbs[name=='green' and 'greenLight' or name=='red' and 'redLight' or 'amberLight'..name:sub(-1)]
      result[name]=light and light.isOn or false
    end
    local racer=data.racers[id]
    if racer and (racer.isDisqualified or racer.isDesqualified) then
      local reason=racer.disqualifiedReason or racer.desqualifiedReason or ''
      local reasons={jumping='Opponent red light',outOfLane='Opponent left its lane',crashed='Opponent crashed',stationaryTooLong='Opponent stopped too long'}
      result.disqualified=reasons[reason:match('([^%.]+)$')] or 'Opponent disqualified'
    end
    return result
  end
  function driver.cancel()
    if ownsData() then
      gameplay_drag_core.reset({raceState=true,clearRacers=true,transitionLock=true,hooks=false,treeLightStaging=false})
      if gameplay_drag_dragTypes_headsUpRace then gameplay_drag_dragTypes_headsUpRace.resetDragRace() end
      local lights=data.strip.treeLights and data.strip.treeLights[laneIndex]
      for _,light in pairs(lights and lights.countDownLights or {})do light.isOn=false end
      overhaul_events_streetKnightsTraction.clear()
    end
    releaseControls(id)
    if id then send(id,"ai.setMode('manual');ai.setSpeedMode('set');ai.setSpeed(0);controller.setFreeze(1)") end
  end
  function driver.stop()
    if stopping then return end
    stopping=true;releaseControls(id)
    local racer=ownsData() and data.racers[id]
    -- Finish must not send the AI down a long stop corridor into street furniture.
    -- Mark the native stop phase complete and brake to a stop in the lane.
    if racer then
      racer.currentPhase=4;racer.phases[4].started=true;racer.phases[4].completed=true
    end
    if id then
      send(id,"ai.setMode('disabled');electrics.values.throttleOverride=0")
      -- The race controls brake the car and freeze it once nearly stopped. Without them
      -- (a forfeit before the countdown) the car is barely moving, so it is held at once.
      send(id,"if overhaulStreetKnightsTraction then overhaulStreetKnightsTraction.applyCooldown(true) else electrics.values.brakeOverride=1;controller.setFreeze(1) end")
    end
  end
  function driver.clear(released)
    if id then
      releaseControls(id)
      -- releaseControls unfreezes the car; a stopped opponent left in the world (a won car) is parked so it cannot roll away.
      if not released then send(id,be:getPlayerVehicleID(0)==id and "ai.setMode('disabled')"
        or "ai.setMode('stop');if obj:getVelocity():length()<"..stopTuning.stoppedSpeedMps.." then input.event('parkingbrake',1,1) end") end
    end
    clearData()
    if paths then paths=false;resetNavigation() end
    id=nil;venue=nil;stopping=false
  end
  return driver
end
return M
