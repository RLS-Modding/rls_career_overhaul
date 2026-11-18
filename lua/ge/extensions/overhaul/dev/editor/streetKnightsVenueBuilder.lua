local M={}
M.dependencies={'overhaul_events_streetKnightsVenues'}
local im=ui_imgui
local window='StreetKnightsVenueBuilder'
local venue,mode,message,dragging,oldCamera
local pendingOpen=false
local startPlaced=false
local name=im.ArrayChar(80,'island_meet')
local locationName=im.ArrayChar(80,'')
local length=im.FloatPtr(201.168)
local heading=im.FloatPtr(0)
local width=im.FloatPtr(4)
local parkingHeading,parkingWidth,parkingLength=im.FloatPtr(0),im.FloatPtr(4),im.FloatPtr(8)
local transformTarget='strip'
local gizmoDragging,dragBefore,dragRotation
local draftEpoch=0
local focusRequested=false
local deleteTarget
local showDecor,showBoss=im.BoolPtr(true),im.BoolPtr(true)
local propScale={im.FloatPtr(1),im.FloatPtr(1),im.FloatPtr(1)}
local propHeading=im.FloatPtr(0)
local customShape=im.ArrayChar(256,'')
local selectedProp,pickedShape,selectedNode
local pathKey,pathInfo
local saveResult,savedKey,markSaved
local shapeCache={}
local previewIds,previewKey={},nil
local function allowed() return overhaul_shell_extensionManager and overhaul_shell_extensionManager.isDevKeyValid() end
local function currentProp() return venue and venue.props and selectedProp and venue.props[selectedProp] end
local function lostParking() return venue and type(venue.lostVehicleParking)=='table' and venue.lostVehicleParking or nil end
local function loadLostParking()
  local spot=overhaul_events_streetKnightsVenues.getLostVehicleParking(venue)
  if not spot then venue.lostVehicleParking=false;return end
  local p,q,size=vec3(spot.pos),quat(spot.rot),vec3(spot.scl)
  venue.lostVehicleParking={pos={x=p.x,y=p.y,z=p.z},heading=overhaul_events_streetKnightsVenues.headingFromRotation(q),width=size.x,length=size.y,height=size.z,
    rotation={x=q.x,y=q.y,z=q.z,w=q.w}}
end
local hidden={}
local hiddenProps=setmetatable({},{__mode='k'})
local function isVisible(target,prop)
  if target=='prop' then prop=prop or currentProp();return not (prop and hiddenProps[prop]) end
  if target=='node' or target=='start' or target=='finish' then return not hidden.strip end
  return not hidden[target]
end
local presetLengths={201.168,402.336,804.672}
local function snapLength(d)
  for _,preset in ipairs(presetLengths) do if math.abs(d-preset)<5 then return preset end end
  return math.max(10,math.min(2000,d))
end
local function syncFields()
  name=im.ArrayChar(80,venue.id);length[0]=venue.length;heading[0]=venue.heading;width[0]=venue.laneWidth
  locationName=im.ArrayChar(80,(venue.name~='Street Knights' and venue.name) or '')
  parkingHeading[0]=venue.parkingHeading or venue.heading;parkingWidth[0]=venue.parkingWidth or 4;parkingLength[0]=venue.parkingLength or 8
  showDecor[0]=venue.decorations~=false;showBoss[0]=venue.bossDisplay~=false
  if selectedProp and not currentProp() then selectedProp=nil end
  if selectedNode and not (venue.pathNodes and venue.pathNodes[selectedNode]) then selectedNode=nil end
  if transformTarget=='node' and not selectedNode then transformTarget='strip' end
  if transformTarget=='lostParking' and not lostParking() then transformTarget='strip' end
  if (transformTarget=='start' or transformTarget=='finish') and not venue.pathNodes then transformTarget='strip' end
  local p=currentProp()
  if p then propScale[1][0]=p.scale.x;propScale[2][0]=p.scale.y;propScale[3][0]=p.scale.z;propHeading[0]=p.heading or 0 end
end
local function targetPosition(target)
  if target=='flareLeft' or target=='flareRight' then return overhaul_events_streetKnightsVenues.finishFlarePosition(venue,target=='flareLeft' and -1 or 1) end
  if target=='parking' then return venue.parking end
  if target=='prop' then local p=currentProp();return p and p.pos end
  if target=='boss' then return venue.bossSpot end
  if target=='lostParking' then local p=lostParking();return p and p.pos end
  if target=='node' then return venue.pathNodes and selectedNode and venue.pathNodes[selectedNode] end
  if target=='finish' then return overhaul_events_streetKnightsVenues.position(venue,venue.length,0) end
  return venue.start
end
local function targetHeading(target)
  if target=='prop' then local p=currentProp();if p then return p.heading or 0 end end
  if target=='boss' then return venue.bossHeading or venue.parkingHeading or venue.heading end
  if target=='lostParking' then local p=lostParking();if p then return p.heading end end
  return venue.parkingHeading or venue.heading
end
local moveFinish
local function setTarget(target,p,degrees,finishBase)
  if target=='flareLeft' or target=='flareRight' then
    if p then venue.finishFlares=venue.finishFlares or {};venue.finishFlares[target=='flareLeft' and 'left' or 'right']=p end
  elseif target=='parking' then if p then venue.parking=p end;if degrees then venue.parkingHeading=degrees end
  elseif target=='prop' then local prop=currentProp();if prop then if p then prop.pos=p end;if degrees then prop.heading=degrees end end
  elseif target=='boss' then if p then venue.bossSpot=p end;if degrees then venue.bossHeading=degrees end
  elseif target=='lostParking' then
    local spot=lostParking()
    if spot then
      if p then spot.pos=p end
      if degrees then
        if math.abs((degrees-spot.heading+180)%360-180)>0.0001 then spot.rotation=nil end
        spot.heading=degrees
      end
    end
  elseif target=='node' then if p and venue.pathNodes and venue.pathNodes[selectedNode] then venue.pathNodes[selectedNode]=p end
  elseif target=='start' then if p then venue.start=p;venue.startNormal=nil end
  elseif target=='finish' then if p then moveFinish(p,finishBase) end end
end
local function snapshot() return {venue=deepcopy(venue),startPlaced=startPlaced,target=transformTarget,prop=selectedProp,node=selectedNode} end
local function applySnapshot(data)
  venue=deepcopy(data.venue);startPlaced=data.startPlaced;transformTarget=data.target or 'strip';selectedProp=data.prop;selectedNode=data.node;syncFields()
end
local function remember(label,before)
  local data={before=before,after=snapshot(),epoch=draftEpoch}
  editor.history:commitAction(label,data,
    function(d)if d.epoch==draftEpoch then applySnapshot(d.before)end end,
    function(d)if d.epoch==draftEpoch then applySnapshot(d.after)end end)
end
local function targetRotation()
  local prop=transformTarget=='prop' and currentProp()
  if prop then
    local rot=overhaul_events_streetKnightsVenues.propRotation(prop)
    return quat(rot.x,rot.y,rot.z,rot.w)
  end
  local onStrip=transformTarget=='strip' or transformTarget=='start' or transformTarget=='finish'
  local v=onStrip and venue or {heading=targetHeading(transformTarget)}
  local f=overhaul_events_streetKnightsVenues.axes(v,transformTarget=='finish' and venue.length or 0)
  return quatFromDir(vec3(f),vec3(0,0,1))
end
local function updateGizmoTransform()
  local rotation=targetRotation()
  if editor.getAxisGizmoAlignment()~=editor.AxisGizmoAlignment_Local then rotation=quat(0,0,0,1) end
  local transform=QuatF(rotation.x,rotation.y,rotation.z,rotation.w):getMatrix()
  transform:setPosition(vec3(targetPosition(transformTarget)))
  editor.setAxisGizmoTransform(transform)
end
local dragScaleBase
local function clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end
local function beginGizmoDrag()
  gizmoDragging=true;dragBefore=snapshot();dragRotation=targetRotation()
  local prop=currentProp()
  dragScaleBase={laneWidth=venue.laneWidth,parkingWidth=venue.parkingWidth or 4,parkingLength=venue.parkingLength or 8,
    prop=prop and {x=prop.scale.x,y=prop.scale.y,z=prop.scale.z},
    start=deepcopy(venue.start),heading=venue.heading,nodes=venue.pathNodes and deepcopy(venue.pathNodes),
    position=vec3(editor.getAxisGizmoTransform():getColumn(3)),translation=vec3(0,0,0),
    finish=transformTarget=='finish' and deepcopy(venue) or nil}
end
local function gizmoScale()
  local s=vec3(worldEditorCppApi.getAxisGizmoScale())
  local b=dragScaleBase;if not b then return end
  if transformTarget=='strip' then venue.laneWidth=clamp(b.laneWidth*s.x,2,12)
  elseif transformTarget=='parking' then venue.parkingWidth=clamp(b.parkingWidth*s.x,2,20);venue.parkingLength=clamp(b.parkingLength*s.y,3,30)
  elseif transformTarget=='prop' and b.prop then
    local prop=currentProp()
    if prop then prop.scale={x=clamp(b.prop.x*s.x,0.05,20),y=clamp(b.prop.y*s.y,0.05,20),z=clamp(b.prop.z*s.z,0.05,20)} end
  end
end
local function gizmoDrag()
  local transform=editor.getAxisGizmoTransform()
  if editor.getAxisGizmoMode()==editor.AxisGizmoMode_Translate then
    local b=dragScaleBase;if not b then return end
    b.translation=b.translation+vec3(worldEditorCppApi.getAxisGizmoTranslateOffset())
    local p=b.position+b.translation
    if transformTarget=='strip' then
      venue.start={x=p.x,y=p.y,z=p.z}
      if b and b.nodes and venue.pathNodes then
        local dx,dy,dz=p.x-b.start.x,p.y-b.start.y,p.z-b.start.z
        for i,n in ipairs(b.nodes) do venue.pathNodes[i]={x=n.x+dx,y=n.y+dy,z=n.z+dz} end
      end
    else setTarget(transformTarget,{x=p.x,y=p.y,z=p.z},nil,b.finish) end
  elseif editor.getAxisGizmoMode()==editor.AxisGizmoMode_Rotate then
    local rotation=QuatF(0,0,0,1);rotation:setFromMatrix(transform)
    local q=quat(rotation)
    if editor.getAxisGizmoAlignment()~=editor.AxisGizmoAlignment_Local then q=dragRotation*q end
    local prop=transformTarget=='prop' and currentProp()
    if prop then prop.rot={x=q.x,y=q.y,z=q.z,w=q.w} end
    local forward=q*vec3(0,1,0);local horizontal=math.sqrt(forward.x^2+forward.y^2)
    if horizontal>0.001 then
      local degrees=math.deg(math.atan2(forward.y,forward.x))
      if transformTarget~='strip' then setTarget(transformTarget,nil,degrees)
      else
        venue.heading=degrees;venue.grade=forward.z/horizontal;venue.startNormal=nil
        local b=dragScaleBase
        if b and b.nodes and venue.pathNodes then
          local a=math.rad(degrees-b.heading);local c,s=math.cos(a),math.sin(a)
          for i,n in ipairs(b.nodes) do
            local x,y=n.x-b.start.x,n.y-b.start.y
            venue.pathNodes[i]={x=venue.start.x+x*c-y*s,y=venue.start.y+x*s+y*c,z=n.z}
          end
        end
      end
    end
  elseif editor.getAxisGizmoMode()==editor.AxisGizmoMode_Scale then gizmoScale()
  end
  syncFields()
end
local function endGizmoDrag()
  gizmoDragging=false;dragScaleBase=nil
  if dragBefore then remember('Transform drag '..transformTarget,dragBefore);dragBefore=nil end
end
local function surfaceNormal(hit)
  local n=hit and hit.normal and vec3(hit.normal) or vec3(0,0,1)
  if n:length()<0.01 then n=vec3(0,0,1) else n:normalize() end
  if n.z<0 then n=-n end
  return n
end
local function drawStartBand(v,normal,alpha)
  local f,r=overhaul_events_streetKnightsVenues.axes(v)
  local forward=vec3(f)
  local n=normal or (v.startNormal and vec3(v.startNormal)) or vec3(r):cross(forward):normalized()
  forward=forward-n*forward:dot(n)
  if forward:length()<0.01 then return end
  forward:normalize();local right=forward:cross(n):normalized()
  local p=vec3(v.start)+n*0.08;local side=right*v.laneWidth;local depth=forward*0.3
  local a,b,c,d=p-side-depth,p+side-depth,p+side+depth,p-side+depth
  local packedColor=color(255,255,255,math.floor((alpha or 0.95)*255))
  for _,t in ipairs({{a,b,c},{a,c,d},{c,b,a},{d,c,a}})do debugDrawer:drawTriSolid(t[1],t[2],t[3],packedColor)end
end
local function drawStrip(v,preview,upto)
  drawStartBand(v,nil,preview and 0.65 or 0.95)
  local c=ColorF(1,0.5,0.2,preview and 0.6 or 1);local lift=vec3(0,0,0.1)
  local stop=math.min(v.length,upto or v.length)
  if stop<=0 then return end
  local step=v.centerline and 4 or stop
  for _,side in ipairs({-1,0,1})do
    local offset=side*v.laneWidth
    local a=vec3(overhaul_events_streetKnightsVenues.position(v,0,offset))+lift;local d=0
    while d<stop do
      d=math.min(stop,d+step)
      local b=vec3(overhaul_events_streetKnightsVenues.position(v,d,offset))+lift
      debugDrawer:drawLineInstance(a,b,3,c);a=b
    end
  end
end
local function drawFinish(v,label)
  local V=overhaul_events_streetKnightsVenues;local w=v.laneWidth
  local f=vec3(V.position(v,v.length+0.5,0))-vec3(V.position(v,v.length-0.5,0));f.z=0
  if f:length()<0.01 then return end
  f:normalize();local r=vec3(f.y,-f.x,0)
  local mid=vec3(V.position(v,v.length,0))+vec3(0,0,0.09)
  local cells=8;local size=2*w/cells;local depth=0.6
  for i=0,cells-1 do
    for j=0,1 do
      local a=mid+r*(-w+i*size)+f*(j*depth-depth);local b=a+r*size;local c=b+f*depth;local d=a+f*depth
      local shade=(i+j)%2==0 and color(255,255,255,240) or color(20,20,20,240)
      for _,t in ipairs({{a,b,c},{a,c,d},{c,b,a},{d,c,a}})do debugDrawer:drawTriSolid(t[1],t[2],t[3],shade)end
    end
  end
  local up=vec3(0,0,4);local left=mid-r*(w+0.5);local right=mid+r*(w+0.5)
  debugDrawer:drawLineInstance(left,left+up,6,ColorF(1,1,1,1))
  debugDrawer:drawLineInstance(right,right+up,6,ColorF(1,1,1,1))
  debugDrawer:drawLineInstance(left+up,right+up,10,ColorF(0.4,1,0.6,1))
  debugDrawer:drawTextAdvanced(mid+up+vec3(0,0,0.8),label or 'FINISH',ColorF(1,1,1,1),true,false,ColorI(20,120,50,220))
end
local function ground(p)
  local origin=vec3(p.x,p.y,p.z+4);local d=castRayStatic(origin,vec3(0,0,-1),12)
  if d and d>0 and d<12 then return {x=p.x,y=p.y,z=origin.z-d} end
  return {x=p.x,y=p.y,z=p.z}
end
moveFinish=function(p,base)
  local V=overhaul_events_streetKnightsVenues;base=base or venue
  local distance,side=V.project(base,p)
  if not base.pathNodes or math.abs(side)<0.05 then
    if base.pathNodes then venue.pathNodes=deepcopy(base.pathNodes) end
    venue.length=snapLength(distance);return
  end
  local nodes={}
  for _,n in ipairs(base.pathNodes) do
    local along=V.project(base,n)
    if along<distance-0.5 then nodes[#nodes+1]=deepcopy(n) end
  end
  if #nodes>=V.maxPathNodes then message='Node limit reached. Remove a node before moving the finish sideways.';return end
  nodes[#nodes+1]=ground(p)
  venue.pathNodes=nodes
  local info=V.buildCenterline(venue,ground)
  venue.length=clamp(info.curve,10,2000)
end
local function refreshPath()
  if not venue then return end
  if venue.centerline and not venue.pathNodes then venue.pathNodes=overhaul_events_streetKnightsVenues.nodesFromCenterline(venue.centerline) end
  if not venue.pathNodes then venue.centerline=nil;pathKey=nil;pathInfo=nil;return end
  if #venue.pathNodes>0 and not gizmoDragging then
    local snapped=ground(venue.start)
    if math.abs(snapped.z-venue.start.z)>0.05 then venue.start.z=snapped.z;venue.startNormal=nil end
  end
  local s=venue.start;local parts={s.x,s.y,s.z,venue.length,venue.heading,venue.grade or 0}
  for _,n in ipairs(venue.pathNodes) do parts[#parts+1]=n.x;parts[#parts+1]=n.y;parts[#parts+1]=n.z end
  local key=table.concat(parts,',')
  if key==pathKey and venue.centerline then return end
  pathInfo=overhaul_events_streetKnightsVenues.buildCenterline(venue,ground)
  parts[5]=venue.heading;parts[6]=venue.grade or 0;pathKey=table.concat(parts,',')
end
local function roadNeighbours(nodes)
  local links={}
  for a,n in pairs(nodes) do
    for b in pairs(n.links or {}) do
      if nodes[b] then links[a]=links[a] or {};links[b]=links[b] or {};links[a][b]=true;links[b][a]=true end
    end
  end
  return links
end
local function followRoad()
  if not (map and map.getMap and map.findClosestRoad) then message='Road network unavailable on this map.';return end
  local graph=map.getMap();local nodes=graph and graph.nodes
  local start=vec3(venue.start)
  local a,b=map.findClosestRoad(start)
  if not (nodes and a and b and nodes[a] and nodes[b]) then message='No road found under the start line.';return end
  local forward=overhaul_events_streetKnightsVenues.axes({heading=venue.heading})
  local f=vec3(forward);f.z=0;f:normalize()
  local from,to=a,b
  if (nodes[b].pos-nodes[a].pos):dot(f)<0 then from,to=b,a end
  local roadDir=nodes[to].pos-nodes[from].pos;roadDir.z=0;roadDir:normalize()
  local offset=(start-nodes[from].pos):dot(vec3(roadDir.y,-roadDir.x,0))
  local links=roadNeighbours(nodes)
  local points,travelled,last={},0,start
  local prev,cur=from,to
  for _=1,2000 do
    local here=nodes[cur].pos;local incoming=here-nodes[prev].pos;incoming.z=0
    if incoming:length()<0.01 then incoming=vec3(f) else incoming:normalize() end
    local nextNode,best=nil,0.5
    for n in pairs(links[cur] or {}) do
      if n~=prev then
        local d=nodes[n].pos-here;d.z=0
        if d:length()>0.01 then d:normalize();local score=d:dot(incoming);if score>best then best,nextNode=score,n end end
      end
    end
    local tangent=incoming
    if nextNode then
      local out=nodes[nextNode].pos-here;out.z=0;out:normalize()
      local mid=incoming+out;if mid:length()>0.01 then tangent=mid:normalized() end
    end
    local p=here+vec3(tangent.y,-tangent.x,0)*offset
    if (p-start):dot(f)>2 and (p-last):length()>=15 then
      travelled=travelled+(p-last):length();last=p
      points[#points+1]={x=p.x,y=p.y,z=p.z}
      if travelled>=venue.length+10 then break end
    end
    if not nextNode then break end
    prev,cur=cur,nextNode
  end
  if #points==0 then message='Could not follow a road from the start line in this direction.';return end
  local nodesOut=points
  if #points>overhaul_events_streetKnightsVenues.maxPathNodes then
    local c={{x=start.x,y=start.y,z=start.z}};for _,p in ipairs(points) do c[#c+1]=p end
    nodesOut=overhaul_events_streetKnightsVenues.nodesFromCenterline(c,math.max(8,travelled/(overhaul_events_streetKnightsVenues.maxPathNodes-2)))
  end
  local before=snapshot();venue.pathNodes=nodesOut;selectedNode=nil;transformTarget='strip';refreshPath();remember('Follow road',before)
  message=travelled>=venue.length and ('Strip now follows the road with '..#nodesOut..' nodes.')
    or string.format('Road ends after %d m; the rest of the strip continues straight.',math.floor(travelled))
end
local function drawBox(p,boxHeading,w,l,c)
  local v={start=p,heading=boxHeading}
  local corners={{-l/2,-w/2},{l/2,-w/2},{l/2,w/2},{-l/2,w/2}}
  for i,k in ipairs(corners)do local n=corners[i%4+1]
    debugDrawer:drawLineInstance(vec3(overhaul_events_streetKnightsVenues.position(v,k[1],k[2]))+vec3(0,0,0.1),vec3(overhaul_events_streetKnightsVenues.position(v,n[1],n[2]))+vec3(0,0,0.1),4,c)
  end
end
local function drawParking(p,ghost)
  drawBox(p,venue.parkingHeading or venue.heading,venue.parkingWidth or 4,venue.parkingLength or 8,ColorF(0.2,0.5,1,ghost and 0.6 or 1))
end
local function drawLostParking(p,ghost)
  local spot=lostParking()
  drawBox(p,spot and spot.heading or targetHeading('lostParking'),spot and spot.width or 4,spot and spot.length or 8,ColorF(0.7,0.4,1,ghost and 0.6 or 1))
  debugDrawer:drawTextAdvanced(vec3(p)+vec3(0,0,1.5),'Lost vehicle parking',ColorF(1,1,1,1),true,false,ColorI(0,0,0,160))
end
local function drawBoss(p,bossHeading,ghost)
  local c=ColorF(1,0.25,0.3,ghost and 0.6 or 1)
  drawBox(p,bossHeading,2,4.8,c)
  local v={start=p,heading=bossHeading}
  debugDrawer:drawLineInstance(vec3(p)+vec3(0,0,0.1),vec3(overhaul_events_streetKnightsVenues.position(v,3.4,0))+vec3(0,0,0.1),4,c)
  debugDrawer:drawTextAdvanced(vec3(p)+vec3(0,0,1.5),'Rival car',ColorF(1,1,1,1),true,false,ColorI(0,0,0,160))
end
local function clearPreview()
  for _,id in ipairs(previewIds) do local o=scenetree.findObjectById(id);if o then o:delete() end end
  previewIds={};previewKey=nil
end
local function syncPreview()
  local props=venue and venue.decorations~=false and venue.props or {}
  if #props==0 then if previewKey then clearPreview() end;return end
  local shapes={};for i,p in ipairs(props) do shapes[i]=p.shape end
  local key=table.concat(shapes,'|')
  if key~=previewKey then
    clearPreview();previewKey=key
    for _,p in ipairs(props) do
      local o=createObject('TSStatic');o:setField('shapeName',0,p.shape);o:setField('collisionType',0,'None');o.canSave=false
      o:registerObject('');previewIds[#previewIds+1]=o:getID()
    end
  end
  for i,p in ipairs(props) do
    local o=scenetree.findObjectById(previewIds[i])
    if o then
      local hide=hiddenProps[p] and true or false
      if o:isHidden()~=hide then o:setHidden(hide) end
      local r=overhaul_events_streetKnightsVenues.propRotation(p)
      o:setScale(vec3(p.scale));o:setPosRot(p.pos.x,p.pos.y,p.pos.z,r.x,r.y,r.z,r.w)
    end
  end
  local selected=currentProp()
  if selected and not hiddenProps[selected] then
    debugDrawer:drawSphere(vec3(selected.pos),0.35,ColorF(1,0.85,0.3,0.9))
    debugDrawer:drawTextAdvanced(vec3(selected.pos)+vec3(0,0,0.8),'Selected: '..overhaul_events_streetKnightsVenues.meshLabel(selected.shape),ColorF(1,1,1,1),true,false,ColorI(0,0,0,170))
  end
end
local function propShapes()
  local level=getCurrentLevelIdentifier() or ''
  if not shapeCache[level] then shapeCache[level]=overhaul_events_streetKnightsVenues.propShapes(level) end
  return shapeCache[level]
end
local function reset()
  local p=getCameraPosition()
  venue={version=1,id='island_meet',level=getCurrentLevelIdentifier(),start={x=p.x,y=p.y,z=p.z-5},
    length=201.168,heading=0,laneWidth=4,aiSide='right',enabled=true}
  mode='start';message='Place the start on the road.'
  startPlaced=false
  draftEpoch=draftEpoch+1;transformTarget='strip';dragging=false;gizmoDragging=false
  length[0]=201.168;heading[0]=0;width[0]=4;parkingHeading[0]=0;parkingWidth[0]=4;parkingLength[0]=8
  name=im.ArrayChar(80,'island_meet');locationName=im.ArrayChar(80,'');selectedProp=nil;selectedNode=nil;saveResult=nil;savedKey=nil
end
local function open()
  if not allowed() then return end
  if not editor.editModes then pendingOpen=true;editor.setEditorActive(true);return end
  if not venue then reset() end
  if editor.editModes.streetKnightsVenue then editor.selectEditMode(editor.editModes.streetKnightsVenue) end
  editor.showWindow(window)
  focusRequested=true
end
local function selectBuilder()
  if editor.editMode~=editor.editModes.streetKnightsVenue then editor.selectEditMode(editor.editModes.streetKnightsVenue) end
end
local function beginPlacement(kind)
  selectBuilder();mode=kind;dragging=false
  message=kind=='node' and 'Click along the road to add strip nodes. Stop once you pass the FINISH marker. Escape when done.'
    or 'Click a road or mesh surface to place '..(kind=='boss' and 'rival car' or kind=='lostParking' and 'lost vehicle parking' or kind=='prop' and 'part' or kind)..'. Escape cancels.'
end
local function transform(target,gizmoMode)
  selectBuilder();mode=nil;dragging=false;transformTarget=target
  editor.setAxisGizmoMode(gizmoMode or editor.AxisGizmoMode_Translate)
end
local function restoreCamera()
  if oldCamera then
    core_camera.setPosRot(0,oldCamera.pos.x,oldCamera.pos.y,oldCamera.pos.z,oldCamera.rot.x,oldCamera.rot.y,oldCamera.rot.z,oldCamera.rot.w)
    if not oldCamera.free then commands.setGameCamera() end
    oldCamera=nil
  end
end
local function registerEditMode()
  editor.editModes.streetKnightsVenue={displayName='Drag Venue Builder',onActivate=function() editor.showWindow(window);editor.clearObjectSelection() end,
    onUpdate=function() local live=extensions.overhaul_dev_editor_streetKnightsVenueBuilder if live then live.onEditorUpdate() end end,
    onDeactivate=function() local live=extensions.overhaul_dev_editor_streetKnightsVenueBuilder if live then live.clearPreview() end end,
    auxShortcuts={[editor.AuxControl_LMB]='Place / select drag venue'}}
end
function M.onExtensionLoaded()
  if editor and editor._dragVenueDraft then local kept=editor._dragVenueDraft;editor._dragVenueDraft=nil;M.onDeserialized(kept) end
  if editor and editor.editModes and editor.editModes.streetKnightsVenue then
    local active=editor.editMode==editor.editModes.streetKnightsVenue
    registerEditMode()
    if active then editor.selectEditMode(editor.editModes.streetKnightsVenue) end
  end
end
function M.onEditorInitialized()
  editor.registerWindow(window,im.ImVec2(600,720))
  registerEditMode()
  -- Resolve the live extension when opening; targeted reloads must not retain an old draft closure.
  if editor._dragVenueMenuRegistration~=editor.addWindowMenuItem then
    editor.addWindowMenuItem('Drag Venue Builder',function() extensions.overhaul_dev_editor_streetKnightsVenueBuilder.open() end)
    editor._dragVenueMenuRegistration=editor.addWindowMenuItem
  end
  if pendingOpen then pendingOpen=false;open() end
end
local house={
  page=im.ImVec4(0.082,0.082,0.09,1),popup=im.ImVec4(0.102,0.102,0.11,1),
  panel=im.ImVec4(1,1,1,0.06),panel2=im.ImVec4(1,1,1,0.1),panelHover=im.ImVec4(1,1,1,0.18),
  fold=im.ImVec4(1,1,1,0.03),line=im.ImVec4(1,1,1,0.1),field=im.ImVec4(0,0,0,0.3),clear=im.ImVec4(0,0,0,0),
  text=im.ImVec4(1,1,1,1),muted=im.ImVec4(1,1,1,0.72),faint=im.ImVec4(1,1,1,0.55),
  accent=im.ImVec4(1,0.4,0,1),accentHover=im.ImVec4(1,0.478,0.122,1),accentSoft=im.ImVec4(1,0.698,0.478,1),accentInk=im.ImVec4(1,0.4,0,0.25),
  danger=im.ImVec4(0.725,0.11,0.11,1),dangerHover=im.ImVec4(0.863,0.149,0.149,1),bad=im.ImVec4(0.988,0.647,0.647,1),good=im.ImVec4(0.525,0.937,0.675,1),
  quietDanger=im.ImVec4(0.725,0.11,0.11,0.2),quietDangerHover=im.ImVec4(0.725,0.11,0.11,0.35),quietDangerText=im.ImVec4(0.996,0.792,0.792,1),
}
local buttonKinds={
  primary={house.accent,house.accentHover,house.accentHover,house.text},
  danger={house.danger,house.dangerHover,house.dangerHover,house.text},
  quietDanger={house.quietDanger,house.quietDangerHover,house.quietDangerHover,house.quietDangerText},
  quiet={house.clear,house.panel,house.panel2,house.faint},
}
local function houseButton(label,kind)
  local c=buttonKinds[kind]
  if c then
    im.PushStyleColor2(im.Col_Button,c[1]);im.PushStyleColor2(im.Col_ButtonHovered,c[2])
    im.PushStyleColor2(im.Col_ButtonActive,c[3]);im.PushStyleColor2(im.Col_Text,c[4])
  end
  local pressed=im.Button(label)
  if c then im.PopStyleColor(4) end
  return pressed
end
local function toolButton(label,active) return houseButton(label,active and 'primary') end
local function viewButton(id,shown)
  local pressed=houseButton((shown and 'View' or 'Hidden')..'##view_'..id,not shown and 'quiet')
  if im.IsItemHovered() then im.SetTooltip(shown and 'Hide in the editor while you work (not saved)' or 'Show in the editor again') end
  return pressed
end
local function viewToggle(key)
  if viewButton(key,not hidden[key]) then hidden[key]=not hidden[key] end
end
local function removeButton(label) return houseButton(label,'quietDanger') end
local themeColors={
  {im.Col_WindowBg,house.page},{im.Col_ChildBg,house.clear},{im.Col_PopupBg,house.popup},{im.Col_Border,house.line},
  {im.Col_Text,house.text},{im.Col_TextDisabled,house.faint},
  {im.Col_FrameBg,house.field},{im.Col_FrameBgHovered,im.ImVec4(0,0,0,0.42)},{im.Col_FrameBgActive,im.ImVec4(0,0,0,0.5)},
  {im.Col_Button,house.panel2},{im.Col_ButtonHovered,house.panelHover},{im.Col_ButtonActive,house.accentInk},
  {im.Col_Header,house.panel},{im.Col_HeaderHovered,house.panel2},{im.Col_HeaderActive,house.panelHover},
  {im.Col_Separator,house.line},{im.Col_CheckMark,house.accent},
  {im.Col_ScrollbarBg,house.clear},{im.Col_ScrollbarGrab,im.ImVec4(1,1,1,0.22)},{im.Col_ScrollbarGrabHovered,im.ImVec4(1,1,1,0.38)},{im.Col_ScrollbarGrabActive,house.accent},
  {im.Col_TitleBg,house.page},{im.Col_TitleBgActive,im.ImVec4(0.11,0.11,0.12,1)},
}
local themeVars={
  {im.StyleVar_WindowPadding,im.ImVec2(14,12)},{im.StyleVar_FramePadding,im.ImVec2(12,7)},{im.StyleVar_ItemSpacing,im.ImVec2(8,8)},
  {im.StyleVar_IndentSpacing,14},{im.StyleVar_FrameRounding,7},{im.StyleVar_PopupRounding,7},{im.StyleVar_GrabRounding,7},
  {im.StyleVar_ScrollbarRounding,12},{im.StyleVar_FrameBorderSize,0},{im.StyleVar_PopupBorderSize,1},
  {im.StyleVar_SeparatorTextBorderSize,1},{im.StyleVar_SeparatorTextPadding,im.ImVec2(0,4)},
}
local function pushTheme()
  for _,c in ipairs(themeColors) do im.PushStyleColor2(c[1],c[2]) end
  for _,v in ipairs(themeVars) do if type(v[2])=='number' then im.PushStyleVar1(v[1],v[2]) else im.PushStyleVar2(v[1],v[2]) end end
end
local function popTheme() im.PopStyleVar(#themeVars);im.PopStyleColor(#themeColors) end
local function removePlaced(kind)
  local before=snapshot()
  if kind=='strip' then startPlaced=false;venue.centerline=nil;venue.pathNodes=nil;venue.startNormal=nil;selectedNode=nil
  elseif kind=='parking' then venue.parking=nil
  elseif kind=='boss' then venue.bossSpot=nil;venue.bossHeading=nil
  elseif kind=='lostParking' then venue.lostVehicleParking=false
  elseif kind=='props' then venue.props={};selectedProp=nil end
  if transformTarget==kind or (kind=='props' and transformTarget=='prop') or (kind=='strip' and transformTarget=='node') then transformTarget='strip' end
  mode=nil;dragging=false
  syncFields();remember('Remove '..kind,before)
  message=({strip='Strip removed. Place the start again.',parking='Signup parking removed.',lostParking='Lost vehicle parking removed. Lost cars use the rival display.',boss='Rival car spot reset to beside the signup parking.',props='All decoration parts removed.'})[kind]
end
local function transformActive(target,gizmoMode)
  return not mode and transformTarget==target and editor.getAxisGizmoMode()==gizmoMode
end
local function ensureBoss()
  if venue.bossSpot then return end
  local p,h=overhaul_events_streetKnightsVenues.bossSpot(venue)
  if p then venue.bossSpot={x=p.x,y=p.y,z=p.z};venue.bossHeading=h end
end
local function selectProp(i)
  selectedProp=i;transformTarget='prop';mode=nil;dragging=false;syncFields()
end
local function defaultPropPosition()
  local anchor=currentProp()
  if anchor then
    local _,r=overhaul_events_streetKnightsVenues.axes({heading=anchor.heading or 0})
    return {x=anchor.pos.x+r.x*2,y=anchor.pos.y+r.y*2,z=anchor.pos.z}
  end
  if venue.parking then return overhaul_events_streetKnightsVenues.position({start=venue.parking,heading=venue.parkingHeading or venue.heading},0,8) end
  local c=vec3(getCameraPosition());local d=castRayStatic(c,vec3(0,0,-1),1000)
  return {x=c.x,y=c.y,z=(d and d>0 and d<1000) and c.z-d or c.z-5}
end
local function addProp(shape,copy)
  if type(shape)~='string' or not shape:lower():match('%.dae$') or not FS:fileExists(shape) then message='Mesh not found: '..tostring(shape);return end
  local before=snapshot()
  local prop={shape=shape,pos=defaultPropPosition(),heading=copy and copy.heading or targetHeading('parking'),
    scale=copy and {x=copy.scale.x,y=copy.scale.y,z=copy.scale.z} or {x=1,y=1,z=1}}
  if copy and copy.rot then prop.rot=deepcopy(copy.rot) end
  venue.props=venue.props or {}
  venue.props[#venue.props+1]=prop
  selectProp(#venue.props);remember(copy and 'Duplicate decoration part' or 'Add decoration part',before)
  if not copy then beginPlacement('prop') end
end
local function deleteProp(index)
  index=index or selectedProp
  if not (venue.props and index and venue.props[index]) then return end
  local before=snapshot()
  table.remove(venue.props,index)
  if selectedProp and selectedProp>index then selectedProp=selectedProp-1 end
  selectedProp=#venue.props>0 and selectedProp and math.min(selectedProp,#venue.props) or nil
  if not selectedProp and transformTarget=='prop' then transformTarget='strip' end
  syncFields();remember('Delete decoration part',before)
end
local function moveRotateButtons(target,label,prepare,resizable)
  local move,rotate,scale=editor.AxisGizmoMode_Translate,editor.AxisGizmoMode_Rotate,editor.AxisGizmoMode_Scale
  if toolButton('Move '..label,transformActive(target,move)) then if prepare then prepare() end;transform(target,move) end
  im.SameLine();if toolButton('Rotate '..label,transformActive(target,rotate)) then if prepare then prepare() end;transform(target,rotate) end
  if resizable then im.SameLine();if toolButton('Resize '..label,transformActive(target,scale)) then transform(target,scale) end end
end
local boxList
local function beginBox()
  boxList=im.GetWindowDrawList()
  im.ImDrawList_ChannelsSplit(boxList,2);im.ImDrawList_ChannelsSetCurrent(boxList,1)
  im.BeginGroup()
end
local function endBox(fill,border)
  im.EndGroup()
  local a,b=im.GetItemRectMin(),im.GetItemRectMax()
  im.ImDrawList_ChannelsSetCurrent(boxList,0)
  im.ImDrawList_AddRectFilled(boxList,a,b,im.GetColorU322(fill),8)
  if border then im.ImDrawList_AddRect(boxList,a,b,im.GetColorU322(border),8,nil,1) end
  im.ImDrawList_ChannelsMerge(boxList)
  im.Dummy(im.ImVec2(0,4))
end
local function endSection(closed)
  if not closed then im.Unindent(12);im.Dummy(im.ImVec2(0,4)) end
  endBox(house.fold,house.line)
end
local function beginSection(title,id)
  beginBox()
  im.PushStyleColor2(im.Col_Header,house.clear);im.PushStyleColor2(im.Col_HeaderHovered,im.ImVec4(1,1,1,0.04))
  im.PushStyleColor2(im.Col_HeaderActive,house.panel);im.PushStyleColor2(im.Col_Text,house.accent)
  local open=im.CollapsingHeader1(title:upper()..'##section_'..id,im.TreeNodeFlags_DefaultOpen)
  im.PopStyleColor(4)
  if not open then endSection(true);return false end
  im.Indent(12)
  return true
end
local function caption(text)
  im.PushStyleColor2(im.Col_Text,house.faint);im.SeparatorText(text:upper());im.PopStyleColor(1)
end
local function hint(text,color)
  im.PushStyleColor2(im.Col_Text,color or house.faint);im.TextWrapped(text);im.PopStyleColor(1)
end
local function statusBar()
  beginBox()
  im.Dummy(im.ImVec2(im.GetContentRegionAvailWidth(),2));im.Indent(12)
  if mode then
    hint(mode=='node' and 'ADDING STRIP NODES: click along the road. Escape when done.'
      or 'PLACING '..(mode=='boss' and 'RIVAL CAR' or mode=='lostParking' and 'LOST VEHICLE PARKING' or mode=='prop' and 'PART' or mode:upper())..': click a surface in the world. Escape cancels.',house.accentSoft)
    if im.Button('Cancel placement') then mode=nil;dragging=false end
  end
  hint('EDITING  '..tostring(venue.id)..'     GIZMO  '..(transformTarget=='boss' and 'rival car' or transformTarget=='lostParking' and 'lost vehicle parking' or transformTarget=='prop' and 'part' or transformTarget=='node' and ('node '..tostring(selectedNode)) or transformTarget):upper())
  if message and message~='' then hint(message,house.muted) end
  im.Unindent(12);im.Dummy(im.ImVec2(0,2))
  endBox(mode and house.accentInk or house.panel)
end
local function venueSection()
  if not beginSection('Venue','venue') then return end
  if im.InputText('Venue ID',name) then venue.id=ffi.string(name) end
  if im.InputText('Location name',locationName) then
    local text=ffi.string(locationName):match('^%s*(.-)%s*$')
    venue.name=text~='' and text or nil
  end
  hint('Shown in the Car Meet invite. Blank uses the venue ID.')
  if im.Button('New venue') then reset() end
  caption('Saved venues on this map')
  local saved=overhaul_events_streetKnightsVenues.list(getCurrentLevelIdentifier())
  if #saved==0 then hint('None yet.') end
  for _,v in ipairs(saved) do
    if im.Button('Edit##'..v.id) then venue=deepcopy(v);loadLostParking();venue.tent=nil;selectedProp=nil;selectedNode=nil;startPlaced=true;draftEpoch=draftEpoch+1;transformTarget='strip';syncFields();mode=nil;message='Venue loaded: '..v.id;saveResult=nil;markSaved=true end
    im.SameLine();if removeButton('Delete##'..v.id) then deleteTarget={id=v.id,level=v.level} end
    im.SameLine();if v.id==venue.id then im.TextColored(house.accentSoft,v.id..'  (editing)') else im.Text(v.id) end
  end
  if deleteTarget then
    hint('Delete '..deleteTarget.id..'? Its race and signup parking will be removed from this map.',house.bad)
    if houseButton('Confirm delete','danger') then
      local target=deleteTarget;local ok,result=overhaul_events_streetKnightsVenues.delete(target.level,target.id)
      if ok then if venue.id==target.id then reset()end;deleteTarget=nil end
      message=result
    end
    im.SameLine();if im.Button('Cancel delete') then deleteTarget=nil end
  end
  endSection()
end
local function cameraSection()
  if not beginSection('Camera & view','camera') then return end
  if im.Button('Top-down view') then
    local p=vec3(getCameraPosition())
    oldCamera=oldCamera or {pos=vec3(p),rot=getCameraQuat(),free=commands.isFreeCamera()}
    local q=quatFromDir(vec3(0,0,-1),vec3(0,1,0))
    -- Stay above the current camera location, regardless of the draft's start/finish.
    -- Ground-relative clearance also prevents repeated clicks from climbing forever.
    local groundDistance=castRayStatic(p,vec3(0,0,-1),10000)
    if groundDistance and groundDistance>=0 and groundDistance<10000 then
      p.z=math.max(p.z,p.z-groundDistance+math.max(450,venue.length*2.5))
    end
    commands.setFreeCamera()
    core_camera.setPosRot(0,p.x,p.y,p.z,q.x,q.y,q.z,q.w)
  end
  im.SameLine();if im.Button('Restore view') then restoreCamera() end
  im.SameLine();if im.Button('Show all') then hidden={};for k in pairs(hiddenProps) do hiddenProps[k]=nil end end
  hint('Gizmo: drag the arrows to move, the rings to rotate, or the boxes to resize. Editor shortcuts and snapping also work. View buttons hide items in the editor only.')
  endSection()
end
local function selectNode(i)
  selectedNode=i;transformTarget='node';mode=nil;dragging=false
  editor.setAxisGizmoMode(editor.AxisGizmoMode_Translate)
end
local function selectEnd(target)
  selectedNode=nil;transformTarget=target;mode=nil;dragging=false
  editor.setAxisGizmoMode(editor.AxisGizmoMode_Translate)
end
local function nearestNode(p,radius)
  local best,index=radius
  for i,n in ipairs(venue.pathNodes or {}) do
    local d=(vec3(p)-vec3(n)):length();if d<best then best,index=d,i end
  end
  return index
end
local function setPath(curved)
  local before=snapshot()
  if curved then venue.pathNodes=venue.pathNodes or {}
  else
    venue.pathNodes=nil;venue.centerline=nil;selectedNode=nil
    if transformTarget=='node' then transformTarget='strip' end
    if mode=='node' then mode=nil end
  end
  refreshPath();remember(curved and 'Curved strip' or 'Straight strip',before)
end
local function deleteNode(i)
  local before=snapshot();table.remove(venue.pathNodes,i)
  if selectedNode then if selectedNode==i then selectedNode=nil elseif selectedNode>i then selectedNode=selectedNode-1 end end
  syncFields();remember('Delete strip node',before)
end
local function insertNodeAfter(i)
  local nodes=venue.pathNodes;local a=i==0 and venue.start or nodes[i];local b=nodes[i+1]
  local p
  if b then p={x=(a.x+b.x)/2,y=(a.y+b.y)/2,z=(a.z+b.z)/2}
  else p=overhaul_events_streetKnightsVenues.position(venue,overhaul_events_streetKnightsVenues.project(venue,a)+20,0) end
  local before=snapshot();table.insert(nodes,i+1,ground(p));selectNode(i+1);remember('Insert strip node',before)
end
local function pathControls()
  caption('Path')
  if toolButton('Straight',not venue.pathNodes) and venue.pathNodes then setPath(false) end
  im.SameLine();if toolButton('Curved',venue.pathNodes~=nil) and not venue.pathNodes then setPath(true) end
  if not venue.pathNodes then hint('Straight runs from the start to the finish. Pick Curved to bend the strip along the road with nodes.');return end
  if not startPlaced then hint('Place the start first.');return end
  local nodes=venue.pathNodes;local full=#nodes>=overhaul_events_streetKnightsVenues.maxPathNodes
  if toolButton('Add nodes',mode=='node') and not full then beginPlacement('node') end
  im.SameLine();if im.Button('Follow road') then followRoad() end
  if #nodes>0 then
    im.SameLine()
    if removeButton('Clear nodes') then local before=snapshot();venue.pathNodes={};selectedNode=nil;syncFields();remember('Clear strip nodes',before) end
  end
  if toolButton('Move start',transformActive('start',editor.AxisGizmoMode_Translate)) then selectEnd('start') end
  im.SameLine();if toolButton('Move finish',transformActive('finish',editor.AxisGizmoMode_Translate)) then selectEnd('finish') end
  if transformTarget=='start' and not mode then hint('Drag the start on its own; the nodes stay put.',house.accentSoft)
  elseif transformTarget=='finish' and not mode then hint(string.format('Drag along the strip to change distance (%d m); drag sideways to reshape its end. Along-strip moves snap to 1/8, 1/4 and 1/2 mile.',math.floor(venue.length+0.5)),house.accentSoft) end
  if pathInfo then
    if #nodes==0 then hint('No nodes yet, so the strip runs straight from the start. Click Add nodes and click along the road, or use Follow road.')
    elseif pathInfo.curve<venue.length then hint(string.format('Nodes cover %d of %d m; the rest continues straight.',math.floor(pathInfo.curve),math.floor(venue.length)))
    else hint(string.format('Nodes cover the full %d m.',math.floor(venue.length))) end
    if pathInfo.radius<150 then
      hint(string.format('Tight bend near %d m (radius about %d m). The AI stays flat out, so keep bends gentle.',math.floor(pathInfo.radiusAt),math.floor(pathInfo.radius)),house.bad)
    end
  end
  if full then hint('Node limit reached ('..overhaul_events_streetKnightsVenues.maxPathNodes..').') end
  for i,n in ipairs(nodes) do
    if removeButton('X##delnode'..i) then deleteNode(i);break end
    im.SameLine()
    if i==selectedNode then im.PushStyleColor2(im.Col_Text,house.accentSoft) end
    if im.Selectable1(string.format('Node %d  -  %d m##node%d',i,math.floor(overhaul_events_streetKnightsVenues.project(venue,n)),i),i==selectedNode) then selectNode(i) end
    if i==selectedNode then im.PopStyleColor(1) end
  end
  if selectedNode and nodes[selectedNode] then
    if toolButton('Move node',transformActive('node',editor.AxisGizmoMode_Translate)) then selectNode(selectedNode) end
    im.SameLine();if im.Button('Insert node after') and not full then insertNodeAfter(selectedNode) end
    im.SameLine();if removeButton('Delete node') then deleteNode(selectedNode) end
  end
end
local function stripSection()
  if not beginSection('Race strip','strip') then return end
  hint(venue.pathNodes and 'The white start line sits between both lanes. The strip bends through your nodes; the checkered FINISH line sits at the chosen distance along the curve.'
    or 'The white start line sits between both lanes. The green finish handle rotates the strip at a fixed distance.')
  if toolButton('Place start',mode=='start') then beginPlacement('start') end
  if not venue.pathNodes then im.SameLine();if toolButton('Place finish (custom)',mode=='finish') then beginPlacement('finish') end end
  if startPlaced then im.SameLine();viewToggle('strip');im.SameLine();if removeButton('Remove strip') then removePlaced('strip') end end
  pathControls()
  if startPlaced then
    caption('Finish flares')
    hint('Place each flare on a safe surface beside the finish. Move adjusts it with the gizmo.')
    for _,side in ipairs({'left','right'}) do
      local target=side=='left' and 'flareLeft' or 'flareRight'
      if toolButton('Place '..side..' flare',mode==target) then beginPlacement(target) end
      im.SameLine();if toolButton('Move##'..target,transformActive(target,editor.AxisGizmoMode_Translate)) then transform(target) end
      if venue.finishFlares and venue.finishFlares[side] then
        im.SameLine();if im.Button('Reset##'..target) then local before=snapshot();venue.finishFlares[side]=nil;if not next(venue.finishFlares) then venue.finishFlares=nil end;remember('Reset '..side..' flare',before) end
      end
    end
  end
  caption('Distance')
  if toolButton('Eighth mile',math.abs(venue.length-201.168)<0.01) then venue.length=201.168;length[0]=venue.length end
  im.SameLine();if toolButton('Quarter mile',math.abs(venue.length-402.336)<0.01) then venue.length=402.336;length[0]=venue.length end
  im.SameLine();if toolButton('Half mile',math.abs(venue.length-804.672)<0.01) then venue.length=804.672;length[0]=venue.length end
  caption('Lanes')
  if im.Button('AI lane: '..venue.aiSide) then venue.aiSide=venue.aiSide=='right' and 'left' or 'right' end
  caption('Transform')
  if startPlaced then moveRotateButtons('strip','strip',nil,true);hint('Resize changes lane width only.')
  else hint('Place the start in the world to unlock Move / Rotate / Resize.') end
  endSection()
end
local function parkingSection()
  if not beginSection('Signup parking','parking') then return end
  hint(venue.parking and 'Signup parking placed. Drivers stop here to open the meet.' or 'Signup parking required before saving.')
  if toolButton('Place signup parking',mode=='parking') then beginPlacement('parking') end
  if venue.parking then
    im.SameLine();viewToggle('parking');im.SameLine();if removeButton('Remove parking') then removePlaced('parking') end
    caption('Transform')
    moveRotateButtons('parking','parking',nil,true)
  end
  endSection()
end
local function lostParkingSection()
  if not beginSection('Lost vehicle parking','lostParking') then return end
  hint('Optional. Displays the latest lost car for that night. Without this spot, it replaces the rival display.')
  if toolButton('Place lost vehicle parking',mode=='lostParking') then beginPlacement('lostParking') end
  if lostParking() then
    im.SameLine();viewToggle('lostParking');im.SameLine();if removeButton('Remove lost vehicle parking') then removePlaced('lostParking') end
    caption('Transform');moveRotateButtons('lostParking','lost vehicle parking')
  end
  endSection()
end
local function bossSection()
  if not beginSection('Rival car','boss') then return end
  if im.Checkbox('Show rival car at the meet',showBoss) then local before=snapshot();venue.bossDisplay=showBoss[0];remember('Toggle rival car',before) end
  if venue.bossDisplay~=false then
    if toolButton('Place rival car',mode=='boss') then beginPlacement('boss') end
    im.SameLine();viewToggle('boss')
    if venue.bossSpot then im.SameLine();if removeButton('Reset rival car spot') then removePlaced('boss') end end
    if overhaul_events_streetKnightsVenues.bossSpot(venue) then caption('Transform');moveRotateButtons('boss','rival car',ensureBoss) end
    if not venue.bossSpot then hint('Defaults to beside the signup parking until placed.') end
  end
  endSection()
end
local function saveSection()
  if markSaved then savedKey=serialize(venue);markSaved=false end
  if not beginSection('Save','save') then return end
  if toolButton('Save venue',true) then
    local ok,result=false,'Place the starting line on the road first.'
    if startPlaced then ok,result=overhaul_events_streetKnightsVenues.save(venue) end
    message=ok and 'Venue saved and available to the career controller.' or tostring(result)
    saveResult={ok=ok,text=ok and ('Saved '..venue.id..' at '..os.date('%H:%M:%S')) or ('Not saved: '..tostring(result))}
    if ok then savedKey=serialize(venue) end
  end
  local dirty=savedKey~=serialize(venue)
  im.SameLine()
  if dirty then im.TextColored(house.accentSoft,'Unsaved changes') else im.TextColored(house.good,'All changes saved') end
  if saveResult then hint(saveResult.text,saveResult.ok and house.good or house.bad) end
  hint('Saving publishes the layout, race settings, signup parking and decoration. The level itself does not need saving.')
  endSection()
end
local function decorationSection()
  if not beginSection('Site decoration','decor') then return end
  if im.Checkbox('Show decorations at the meet',showDecor) then local before=snapshot();venue.decorations=showDecor[0];remember('Toggle decorations',before) end
  caption('Add a part')
  local shapes=propShapes()
  pickedShape=pickedShape or (shapes[1] and shapes[1].id)
  if im.BeginCombo('Mesh',pickedShape and overhaul_events_streetKnightsVenues.meshLabel(pickedShape) or 'Choose a mesh') then
    for _,s in ipairs(shapes) do
      if im.Selectable1(s.label..'##'..s.id,pickedShape==s.id) then pickedShape=s.id end
    end
    im.EndCombo()
  end
  im.SameLine();if im.Button('Add part') then addProp(pickedShape) end
  im.InputText('Custom .dae path',customShape)
  im.SameLine();if im.Button('Add custom') then addProp(ffi.string(customShape)) end
  if not venue.props and venue.signupTent then
    hint('This venue uses its original hand-placed tent.',house.muted)
    if im.Button('Edit hand-placed tent as parts') then
      local before=snapshot();venue.props=overhaul_events_streetKnightsVenues.propsFromSignupTent(venue.signupTent)
      selectProp(#venue.props>0 and 1 or nil);remember('Convert tent to parts',before)
    end
    im.SameLine();if removeButton('Remove hand-placed tent') then removePlaced('props') end
  end
  local props=venue.props or {}
  caption('Parts ('..#props..')')
  if #props==0 and not venue.signupTent then hint('No parts yet. Pick a mesh above and click Add part.') end
  if #props>0 then if removeButton('Remove all parts') then removePlaced('props') end end
  for i,p in ipairs(props) do
    if removeButton('X##delprop'..i) then deleteProp(i);break end
    im.SameLine()
    if viewButton('prop'..i,not hiddenProps[p]) then hiddenProps[p]=not hiddenProps[p] or nil end
    im.SameLine()
    if i==selectedProp then im.PushStyleColor2(im.Col_Text,house.accentSoft) end
    if im.Selectable1(i..'. '..overhaul_events_streetKnightsVenues.meshLabel(p.shape)..'##prop'..i,i==selectedProp) then selectProp(i) end
    if i==selectedProp then im.PopStyleColor(1) end
  end
  local prop=currentProp()
  if prop then
    caption('Selected part: '..selectedProp..'. '..overhaul_events_streetKnightsVenues.meshLabel(prop.shape))
    if toolButton('Place part',mode=='prop') then beginPlacement('prop') end
    moveRotateButtons('prop','part',nil,true)
    if im.Button('Duplicate part') then addProp(prop.shape,prop) end
    im.SameLine();if removeButton('Delete part') then deleteProp() end
  elseif #props>0 then
    hint('Select a part from the list, or click near one in the world.')
  end
  endSection()
end
function M.nearestProp(p,radius)
  local best,index=radius
  for i,prop in ipairs(venue and venue.props or {}) do
    local d=(vec3(p)-vec3(prop.pos)):length()
    if d<best and not hiddenProps[prop] then best,index=d,i end
  end
  return index
end
function M.clearPreview() clearPreview() end
function M.onExtensionUnloaded()
  clearPreview()
  if venue and editor then editor._dragVenueDraft=M.onSerialize() end
end
function M.onEditorToolWindowGotFocus(id)
  if id==window and allowed() then selectBuilder() end
end
function M.onEditorGui()
  if not allowed() then editor.hideWindow(window);return end
  if focusRequested then im.SetNextWindowFocus();focusRequested=false end
  pushTheme()
  if editor.beginWindow(window,'Drag Venue Builder') then
    im.SetWindowFontScale(1.35)
    if not venue then reset() end
    refreshPath()
    statusBar()
    venueSection()
    cameraSection()
    stripSection()
    parkingSection()
    lostParkingSection()
    decorationSection()
    bossSection()
    saveSection()
  end
  editor.endWindow()
  popTheme()
end
function M.onEditorUpdate()
  if not venue or not allowed() or not editor.isWindowVisible(window) or editor.editMode~=editor.editModes.streetKnightsVenue then
    if previewKey then clearPreview() end
    return
  end
  local v=overhaul_events_streetKnightsVenues
  refreshPath()
  syncPreview()
  if venue.bossDisplay~=false and not hidden.boss then local bp,bh=v.bossSpot(venue);if bp then drawBoss(bp,bh) end end
  if lostParking() and not hidden.lostParking then drawLostParking(lostParking().pos) end
  local finish=vec3(v.position(venue,venue.length,0))
  local green=ColorF(0.4,1,0.6,1)
  if startPlaced and not hidden.strip then
    if mode~='node' then drawStrip(venue);drawFinish(venue) end
    if not venue.pathNodes then
      debugDrawer:drawSphere(finish,3,green)
      debugDrawer:drawTextAdvanced(finish+vec3(0,0,6),'Drag finish: distance locked',ColorF(1,1,1,1),true,false,ColorI(0,0,0,160))
    end
    for i,n in ipairs(venue.pathNodes or {}) do
      local p=vec3(n)+vec3(0,0,0.3);local picked=i==selectedNode
      debugDrawer:drawSphere(p,picked and 0.8 or 0.55,picked and ColorF(1,0.85,0.3,0.95) or ColorF(1,0.5,0.2,0.85))
      debugDrawer:drawTextAdvanced(p+vec3(0,0,0.9),tostring(i),ColorF(1,1,1,1),true,false,ColorI(0,0,0,170))
    end
    if venue.pathNodes and mode~='node' then
      for _,e in ipairs({{'start',vec3(venue.start),'Start'},{'finish',finish,'Finish'}}) do
        local picked=transformTarget==e[1];local p=e[2]+vec3(0,0,0.3)
        debugDrawer:drawSphere(p,picked and 0.9 or 0.65,picked and ColorF(1,0.85,0.3,0.95) or ColorF(0.4,1,0.6,0.9))
        debugDrawer:drawTextAdvanced(p+vec3(0,0,1),e[3],ColorF(1,1,1,1),true,false,ColorI(0,0,0,170))
      end
    end
  end
  if startPlaced and not hidden.strip then
    for _,side in ipairs({-1,1}) do
      local target=side<0 and 'flareLeft' or 'flareRight'
      local p=vec3(overhaul_events_streetKnightsVenues.finishFlarePosition(venue,side))+vec3(0,0,0.15)
      debugDrawer:drawSphere(p,0.25,ColorF(1,0.2,0.1,0.9))
      debugDrawer:drawTextAdvanced(p+vec3(0,0,0.6),side<0 and 'Left flare' or 'Right flare',ColorF(1,1,1,1),true,false,ColorI(0,0,0,170))
    end
  end
  if venue.parking and not hidden.parking then drawParking(venue.parking) end
  if not mode and not dragging and isVisible(transformTarget) and ((transformTarget=='strip' and startPlaced) or (transformTarget~='strip' and targetPosition(transformTarget))) then
    if ((transformTarget=='boss' or transformTarget=='lostParking') and editor.getAxisGizmoMode()==editor.AxisGizmoMode_Scale)
      or ((transformTarget=='node' or transformTarget=='start' or transformTarget=='finish' or transformTarget=='flareLeft' or transformTarget=='flareRight') and editor.getAxisGizmoMode()~=editor.AxisGizmoMode_Translate) then editor.setAxisGizmoMode(editor.AxisGizmoMode_Translate) end
    if not gizmoDragging then updateGizmoTransform()end
    editor.updateAxisGizmo(beginGizmoDrag,endGizmoDrag,gizmoDrag);editor.drawAxisGizmo()
    -- Native gizmos omit their end callback for a click with no movement.
    if gizmoDragging and not im.IsMouseDown(0) then gizmoDragging=false;dragBefore=nil end
    if gizmoDragging or editor.isAxisGizmoHovered()then return end
  end
  if mode and im.IsKeyPressed(im.GetKeyIndex(im.Key_Escape))then mode=nil;return end
  if not editor.isViewportHovered() and not dragging then return end
  -- Pick solid terrain/DAE surfaces, not water or vehicle roofs. Mesh roads also
  -- need the native flags-less fallback used by the standard object editor.
  local hit=cameraMouseRayCast(false,im.flags(SOTTerrain,SOTStaticShape),10000)
  local meshHit=cameraMouseRayCast(false,nil,10000)
  if meshHit and meshHit.object and meshHit.object:getClassName()=='MeshRoad'
    and (not hit or meshHit.distance<hit.distance)then hit=meshHit end
  if mode then im.SetMouseCursor(im.MouseCursor_ResizeAll or 2)end
  if not hit or not hit.pos then
    if mode and im.IsMouseClicked(0) then message='No road or mesh surface under the cursor. Aim at a solid surface and click again.' end
    return
  end
  local p=hit.pos
  if mode then
    local preview=deepcopy(venue);local nodeLabel
    if mode=='start' then
      preview.start={x=p.x,y=p.y,z=p.z};preview.startNormal=surfaceNormal(hit):toTable();drawStrip(preview,true)
    elseif mode=='flareLeft' or mode=='flareRight' then debugDrawer:drawSphere(p+vec3(0,0,0.08),0.25,ColorF(1,0.2,0.1,0.9))
    elseif mode=='parking' then drawParking(p,true)
    elseif mode=='lostParking' then drawLostParking(p,true)
    elseif mode=='boss' then drawBoss(p,targetHeading('boss'),true)
    elseif mode=='prop' then local prop=currentProp();if prop then drawBox(p,prop.heading or 0,2*prop.scale.x,2*prop.scale.y,ColorF(1,0.85,0.3,0.6)) end
    elseif mode=='node' then
      if preview.pathNodes then
        preview.pathNodes[#preview.pathNodes+1]={x=p.x,y=p.y,z=p.z}
        local info=v.buildCenterline(preview);local covered=info and info.curve or 0
        drawStrip(preview,true)
        drawFinish(preview,covered>=preview.length and 'FINISH - stop here' or 'FINISH')
        nodeLabel=covered>=preview.length and 'Past the finish · this can be your last node'
          or string.format('Click to add a strip node · %d m to the finish',math.ceil(preview.length-covered))
      end
    elseif startPlaced then v.aim(preview,p,false);drawStrip(preview,true) end
    debugDrawer:drawSphere(p,0.5,ColorF(1,0.65,0.2,0.8))
    debugDrawer:drawTextAdvanced(p,mode=='node' and (nodeLabel or 'Click to add a strip node · Escape when done')
      or 'Click to place '..(mode=='boss' and 'rival car' or mode=='lostParking' and 'lost vehicle parking' or mode=='prop' and 'part' or mode)..' · Escape cancels',ColorF(1,1,1,1),true,false,ColorI(0,0,0,180))
  end
  if im.IsMouseClicked(0) then
    if mode then
      local before=snapshot()
      if mode=='start' then venue.start={x=p.x,y=p.y,z=p.z};venue.startNormal=surfaceNormal(hit):toTable();startPlaced=true;transformTarget='strip'
      elseif mode=='flareLeft' or mode=='flareRight' then setTarget(mode,{x=p.x,y=p.y,z=p.z});transformTarget=mode
      elseif mode=='parking' then venue.parking={x=p.x,y=p.y,z=p.z};transformTarget='parking'
      elseif mode=='lostParking' then
        local spot=lostParking() or {heading=targetHeading('lostParking'),width=4,length=8}
        spot.pos={x=p.x,y=p.y,z=p.z};venue.lostVehicleParking=spot;transformTarget='lostParking'
      elseif mode=='prop' then local prop=currentProp();if not prop then mode=nil;return end;prop.pos={x=p.x,y=p.y,z=p.z};transformTarget='prop'
      elseif mode=='boss' then venue.bossHeading=targetHeading('boss');venue.bossSpot={x=p.x,y=p.y,z=p.z};transformTarget='boss'
      elseif mode=='node' then
        if not (startPlaced and venue.pathNodes) or #venue.pathNodes>=v.maxPathNodes then mode=nil;message='Cannot add more strip nodes.';return end
        venue.pathNodes[#venue.pathNodes+1]={x=p.x,y=p.y,z=p.z};selectedNode=#venue.pathNodes;transformTarget='node'
      elseif startPlaced then v.aim(venue,p,false);transformTarget='strip'
      else message='Place the start before choosing the finish.';return end
      syncFields();remember('Place drag '..mode,before)
      if mode=='node' then message='Node '..#venue.pathNodes..' added. Keep clicking along the road; Escape when done.'
      else mode=nil;message='Placement updated. Preview the lanes and signup parking before saving.' end
    elseif startPlaced and not hidden.strip and venue.pathNodes and (p-vec3(venue.start)):length()<2.5 then selectEnd('start')
    elseif startPlaced and not hidden.strip and venue.pathNodes and (p-finish):length()<3 then selectEnd('finish')
    elseif startPlaced and not hidden.strip and nearestNode(p,3) then selectNode(nearestNode(p,3))
    elseif startPlaced and not hidden.strip and not venue.pathNodes and (p-finish):length()<4 then dragging=true;dragBefore=snapshot()
    elseif M.nearestProp(p,2.5) then selectProp(M.nearestProp(p,2.5))
    elseif lostParking() and not hidden.lostParking and (p-vec3(lostParking().pos)):length()<3 then transformTarget='lostParking'
    elseif venue.parking and not hidden.parking and (p-vec3(venue.parking)):length()<5 then transformTarget='parking'
    elseif venue.bossSpot and venue.bossDisplay~=false and not hidden.boss and (p-vec3(venue.bossSpot)):length()<3 then transformTarget='boss'
    elseif startPlaced then local along,side=v.project(venue,p);if along>=-1 and along<=venue.length and math.abs(side)<=venue.laneWidth then transformTarget='strip'end
    end
  end
  if dragging then v.aim(venue,p,true);heading[0]=venue.heading end
  if im.IsMouseReleased(0) and dragging then dragging=false;if dragBefore then remember('Rotate drag finish',dragBefore);dragBefore=nil end end
end
function M.allowGizmo()return not mode and venue~=nil and editor.editModes and editor.editMode==editor.editModes.streetKnightsVenue end
function M.onEditorDeactivated() restoreCamera();clearPreview();dragging=false;gizmoDragging=false end
function M.getDraft() if allowed() and venue then return deepcopy(venue) end end
function M.onSerialize()return {venue=venue and deepcopy(venue),mode=mode,message=message,startPlaced=startPlaced,target=transformTarget,oldCamera=oldCamera}end
function M.onDeserialized(data)
  if not data or not data.venue then return end
  applySnapshot(data);venue.tent=nil;mode=data.mode~='tent' and data.mode or nil;message=data.message;oldCamera=data.oldCamera;draftEpoch=draftEpoch+1
end
M.open=open
M.followRoad=function() if allowed() and venue and startPlaced then followRoad() end end
return M
