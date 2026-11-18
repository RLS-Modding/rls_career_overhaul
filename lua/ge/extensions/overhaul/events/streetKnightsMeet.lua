-- Temporary meet dressing. Only objects created here are ever removed.
local M={}
M.dependencies={'overhaul_events_streetKnightsVenues'}
local parking=require('overhaul/events/streetKnights/parking')
local objects,bossId,current={}
local displayIsLost=false
local lostCarId
local authored={}
local bulbs={}
local treeAssets='/levels/rls_west_coast/art/shapes/race/no_prep_knights/'
local bulbLayout={
  prestage={shape='npk_light_stage',y={-0.2125,0.2125},z=2.415},
  stage={shape='npk_light_stage',y={-0.2125,0.2125},z=2.14},
  amber1={shape='npk_light_amber',y={-0.215,0.215},z=1.92},
  amber2={shape='npk_light_amber',y={-0.215,0.215},z=1.665},
  amber3={shape='npk_light_amber',y={-0.215,0.215},z=1.41},
  green={shape='npk_light_green',y={-0.215,0.215},z=1.155},
  red={shape='npk_light_red',y={-0.215,0.215},z=0.9},
}
local lineMaterial
local function startLineMaterial()
  local o=scenetree.findObject('streetKnights_startLineWhite')
  if not o then
    o=createObject('Material');o.canSave=false
    o:setField('version',0,'1.5');o:setField('mapTo',0,'streetKnights_startLineWhite');o:setField('castShadows',0,'false')
    o:setField('diffuseMap',0,'/core/art/white.color.png');o:setField('baseColorMap',0,'/core/art/white.color.png')
    o:setField('baseColorFactor',0,'1 1 1 1');o:setField('roughnessFactor',0,'1');o:setField('metallicFactor',0,'0')
    o:setField('translucent',0,'true');o:setField('translucentBlendOp',0,'LerpAlpha');o:setField('translucentZWrite',0,'true')
    o:registerObject('streetKnights_startLineWhite');lineMaterial=o:getID()
  end
  return 'streetKnights_startLineWhite'
end
local registrationMarkers=setmetatable({},{__mode='k'})
local function dimRegistration(venue)
  if not venue or not gameplay_playmodeMarkers then return end
  local id='parkingMarker#streetKnights_signup_'..venue.id
  for _,cluster in ipairs(gameplay_playmodeMarkers.getPlaymodeClusters()) do if cluster.id==id then
    local marker=gameplay_playmodeMarkers.getMarkerForCluster(cluster)
    local state=registrationMarkers[marker]
    if not state then
      local update=marker.update
      state={update=update,checkParking=marker.checkParking,color=marker.groundDecalData.color}
      registrationMarkers[marker]=state
      marker.checkParking=function(self,data)
        state.checkParking(self,data)
        self.parked=parking.isParked(state.venue,be:getPlayerVehicle(0),overhaul_events_streetKnightsVenues.axes)
        self.overlap=self.parked
      end
      marker.groundDecalData.color=ColorF(1,1,1,0.1)
      marker.update=function(self,data)
        update(self,data)
        if not self.visible then return end
        local outline=scenetree.findObjectById(self.outlineId)
        if outline then
          local color=ColorF(0.35,0.35,0.35,1):asLinear4F();color.w=math.max(self.lastAlpha,0)*0.15
          outline.instanceColor=color;outline:updateInstanceRenderData()
        end
      end
    end
    state.venue=venue
    return
  end end
end
local function tentParts(t)
  local parts={t};for _,part in ipairs(t.components or {}) do parts[#parts+1]=part end;return parts
end
local function existingPart(t)
  local o=t.name and scenetree.findObject(t.name)
  if o and o:getField('shapeName',0)==t.shape and (o:getPosition()-vec3(t.pos)):length()<0.1 then return o end
end
local function showAuthored(venue)
  local level=getCurrentLevelIdentifier();if not level then return end
  for _,v in ipairs(overhaul_events_streetKnightsVenues.list(level)) do
    if v.signupTent then for _,t in ipairs(tentParts(v.signupTent)) do
      local o=existingPart(t)
      if o then
        local id=o:getID();if not authored[id] then authored[id]={hidden=o:isHidden()} end
        o:setHidden(not (venue and venue.id==v.id and venue.decorations~=false and not v.props))
      end
    end
    end
  end
end
local function add(shape,p,heading,label,rotation,scale)
  if not FS:fileExists(shape) then return end
  local o=createObject('TSStatic');o:setField('shapeName',0,shape);o:setField('collisionType',0,'None');o.canSave=false
  local f=overhaul_events_streetKnightsVenues.axes({heading=heading});local q=rotation or quatFromDir(vec3(f),vec3(0,0,1))
  if scale then o:setScale(vec3(scale)) end
  o:setPosRot(p.x,p.y,p.z,q.x,q.y,q.z,q.w);o:registerObject('sk_'..label..'_'..tostring(os.time())..'_'..math.random(10000,99999))
  if scenetree.MissionGroup then scenetree.MissionGroup:addObject(o) end
  objects[#objects+1]=o:getID();return o
end
local function paintLine(venue,side,distance)
  local o=createObject('DecalRoad');o.canSave=false
  o:setField('material',0,startLineMaterial());o:setField('overObjects',0,'true')
  o:setField('canFloatAboveGround',0,'true');o:setField('startEndFade',0,'0 0')
  o:setField('zBias',0,'0.1');o:setField('decalBias',0,'0.01')
  o:setField('drivability',0,'-1');o:setField('renderPriority',0,'20')
  o:registerObject('sk_line_'..tostring(side)..'_'..math.floor(distance)..'_'..os.time()..'_'..math.random(10000,99999))
  if scenetree.MissionGroup then scenetree.MissionGroup:addObject(o) end
  for i,offset in ipairs({side*0.2,side*(venue.laneWidth-0.2)}) do
    o:insertNode(vec3(overhaul_events_streetKnightsVenues.position(venue,distance,offset)),0.2,i-1)
  end
  objects[#objects+1]=o:getID()
end
local function finishFlare(venue,side)
  if not scenetree.findObject('npk_finish_flare_core_emitter') then loadJsonMaterialsFile(treeAssets..'finish_flare.particles.json') end
  local p=vec3(overhaul_events_streetKnightsVenues.finishFlarePosition(venue,side))+vec3(0,0,0.08)
  for _,kind in ipairs({'core','smoke'}) do
    local o=createObject('ParticleEmitterNode');o.canSave=false
    o:setField('dataBlock',0,'lightExampleEmitterNodeData1');o:setField('emitter',0,'npk_finish_flare_'..kind..'_emitter')
    o:setPosition(p);o:registerObject('sk_finish_flare_'..kind..'_'..side..'_'..os.time()..'_'..math.random(10000,99999))
    if scenetree.MissionGroup then scenetree.MissionGroup:addObject(o) end
    objects[#objects+1]=o:getID()
  end
  local o=createObject('PointLight');o.canSave=false
  o:setField('color',0,'1 0.025 0.01 1');o:setField('brightness',0,'0.8');o:setField('radius',0,'3');o:setField('castShadows',0,'false')
  o:setPosition(p);o:registerObject('sk_finish_flare_light_'..side..'_'..os.time()..'_'..math.random(10000,99999))
  if scenetree.MissionGroup then scenetree.MissionGroup:addObject(o) end
  objects[#objects+1]=o:getID()
end
function M.getBossVehicleId() if not displayIsLost then return bossId end end
local function lostVehicleSpot(venue)
  local manager=gameplay_sites_sitesManager
  if not (venue and venue.sitesPath and manager and manager.loadSites) then return nil end
  local ok,sites=pcall(manager.loadSites,venue.sitesPath)
  return ok and sites and sites.parkingSpots and sites.parkingSpots.byName and sites.parkingSpots.byName[venue.id..'_lostVehicle'] or nil
end
local function spawnDisplay(car,position,rotation,copyConfig)
  local vehicle=core_vehicles.spawnNewVehicle(car.model,{config=copyConfig and deepcopy(car.config) or car.config,pos=vec3(position),rot=rotation,autoEnterVehicle=false})
  if not vehicle then return nil end
  vehicle.playerUsable=false;vehicle.canSave=false
  vehicle:queueLuaCommand("ai.setMode('disabled');input.event('parkingbrake',1,1);electrics.setIgnitionLevel(0)")
  return vehicle:getID()
end
function M.clear()
  for _,id in ipairs(objects) do local o=be:getObjectByID(id) or scenetree.findObjectById(id);if o then o:delete() end end
  local material=lineMaterial and scenetree.findObjectById(lineMaterial);if material then material:delete() end
  lineMaterial=nil
  if bossId then local v=be:getObjectByID(bossId);if v then v:delete() end end
  if lostCarId then local v=be:getObjectByID(lostCarId);if v then v:delete() end end
  objects={};bossId=nil;lostCarId=nil;displayIsLost=false;current=nil;bulbs={}
  for id in pairs(authored) do local o=scenetree.findObjectById(id);if o then o:setHidden(true) end end
end
function M.update(venue,boss,showBoss,lost,night)
  lost=lost and lost.night==night and lost or nil
  local spot=lost and lostVehicleSpot(venue)
  local replacement=lost and not spot and lost or nil
  local display=replacement and replacement.vehicle or boss
  local showDisplay=showBoss or replacement~=nil
  dimRegistration(venue)
  local key=venue and (venue.id..':'..(venue.stripPath or '')..':'..(showDisplay and display and (replacement and 'lost:'..replacement.id or boss.id) or 'none'))
  if key and lost and spot then key=key..':spot:'..lost.id end
  if key==current then showAuthored(venue);return end
  M.clear();showAuthored(venue);if not venue then return end
  current=key
  local parking={start=venue.parking,heading=venue.parkingHeading or venue.heading}
  local venues=overhaul_events_streetKnightsVenues
  if venue.decorations~=false then
    if venue.props then
      for _,p in ipairs(venue.props) do add(p.shape,p.pos,parking.heading,'prop',venues.propRotation(p),p.scale) end
    elseif venue.signupTent then
      for _,t in ipairs(tentParts(venue.signupTent)) do
        if not existingPart(t) then add(t.shape,t.pos,parking.heading,'tent',t.rot,t.scale) end
      end
    elseif venue.level=='west_coast_usa' then
      add('/levels/west_coast_usa/art/shapes/buildings/tent1.dae',venues.position(parking,0,9),parking.heading,'tent')
    end
  end
  local p=vec3(overhaul_events_streetKnightsVenues.position(venue,4,0))
  local f=overhaul_events_streetKnightsVenues.axes(venue,4)
  local x=vec3(f.x,f.y,0):normalized();local y=vec3(-x.y,x.x,0);local up=vec3(0,0,1)
  local rotation=quatFromDir(x,up)
  if not scenetree.findObject('lod_vertcol') then loadJsonMaterialsFile('/art/shapes/common/common.materials.json') end
  if not scenetree.findObject('vertexColor_glow') then loadJsonMaterialsFile('/art/shapes/race/dragstrip/main.materials.json') end
  if not scenetree.findObject('npk_beam_metal_trim') then loadJsonMaterialsFile(treeAssets..'main.materials.json') end
  add(treeAssets..'npk_portable_tree.dae',p,venue.heading,'tree',rotation)
  local lanes={player=venue.aiSide=='right' and 2 or 1,ai=venue.aiSide=='right' and 1 or 2}
  for lane,column in pairs(lanes) do
    bulbs[lane]={}
    for name,b in pairs(bulbLayout) do
      local o=add(treeAssets..b.shape..'.dae',p+y*b.y[column]+up*b.z,venue.heading,name,rotation)
      if o then
        local aiLane=venue.aiSide=='right' and 2 or 1
        o:setName(venue.id..'_'..name..'_'..(lane=='ai' and aiLane or 3-aiLane))
        o:setHidden(true);bulbs[lane][name]=o:getID()
      end
    end
  end
  for _,distance in ipairs({0,venue.length}) do paintLine(venue,-1,distance);paintLine(venue,1,distance) end
  finishFlare(venue,-1);finishFlare(venue,1)
  local bossPos,bossHeading=venues.bossSpot(venue)
  if showDisplay and display and venue.bossDisplay~=false and bossPos then
    local f=venues.axes({heading=bossHeading})
    bossId=spawnDisplay(display,bossPos,quatFromDir(vec3(f),vec3(0,0,1)),replacement~=nil)
    displayIsLost=replacement~=nil
  end
  if lost and spot and spot.pos and spot.rot and spot.hasAnyVehicles then
    local ok,occupied=pcall(spot.hasAnyVehicles,spot)
    if ok and occupied==false then lostCarId=spawnDisplay(lost.vehicle,spot.pos,quat(spot.rot),true) end
  end
end
function M.tree(lights)
  for lane,set in pairs(bulbs) do
    for name,id in pairs(set) do
      local on=lights and lights[lane] and lights[lane][name] and true or false
      local o=scenetree.findObjectById(id)
      if o and o:isHidden()==on then o:setHidden(not on) end
    end
  end
end
function M.onClientEndMission() M.clear();authored={} end
function M.onExtensionLoaded() showAuthored(nil) end
function M.onClientStartMission() showAuthored(nil) end
function M.onExtensionUnloaded()
  M.clear()
  for marker,state in pairs(registrationMarkers) do
    marker.update=state.update;marker.checkParking=state.checkParking;marker.groundDecalData.color=state.color;marker.lastAlpha=-1
  end
  registrationMarkers=setmetatable({},{__mode='k'})
  for id,state in pairs(authored) do local o=scenetree.findObjectById(id);if o then o:setHidden(state.hidden) end end
  authored={}
end
return M
