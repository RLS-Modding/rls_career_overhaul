local M={}
local venueName=require('overhaul/career/economy/streetKnights/venueName').resolve
M.dependencies={'overhaul_career_saveSystem'}
local function finite(n) return type(n)=='number' and n==n and math.abs(n)<1e8 end
local function point(p) return type(p)=='table' and finite(p.x) and finite(p.y) and finite(p.z) end
local paths=setmetatable({},{__mode='k'})
local function route(v)
  if not v.centerline then return end
  if paths[v] and paths[v].source==v.centerline then return paths[v] end
  local segments,total={},0
  for i=1,#v.centerline-1 do
    local a,b=v.centerline[i],v.centerline[i+1]
    local x,y,z=b.x-a.x,b.y-a.y,b.z-a.z
    local length=math.sqrt(x*x+y*y+z*z);local horizontal=math.sqrt(x*x+y*y)
    segments[i]={start=a,distance=total,length=length,forward={x=x/length,y=y/length,z=z/length},right={x=y/horizontal,y=-x/horizontal,z=0}}
    total=total+length
  end
  paths[v]={segments=segments,length=total,source=v.centerline};return paths[v]
end
M.maxPathNodes=64
local function sub(a,b) return {x=a.x-b.x,y=a.y-b.y,z=a.z-b.z} end
local function len(a) return math.sqrt(a.x*a.x+a.y*a.y+a.z*a.z) end
local function lerp(a,b,t) return {x=a.x+(b.x-a.x)*t,y=a.y+(b.y-a.y)*t,z=a.z+(b.z-a.z)*t} end
local function knot(a,b) return math.max(1e-3,math.sqrt(len(sub(b,a)))) end
local function blend(a,b,ta,tb,t) local w=(t-ta)/(tb-ta);return lerp(a,b,w) end
local function catmull(p0,p1,p2,p3,u)
  local t0=0;local t1=t0+knot(p0,p1);local t2=t1+knot(p1,p2);local t3=t2+knot(p2,p3)
  local t=t1+(t2-t1)*u
  local a1,a2,a3=blend(p0,p1,t0,t1,t),blend(p1,p2,t1,t2,t),blend(p2,p3,t2,t3,t)
  return blend(blend(a1,a2,t0,t2,t),blend(a2,a3,t1,t3,t),t1,t2,t)
end
local function mirror(a,b) return {x=2*a.x-b.x,y=2*a.y-b.y,z=2*a.z-b.z} end
local function bend(c)
  local radius,at=math.huge,0
  for i=1,#c-10 do
    local a1=math.atan2(c[i+1].y-c[i].y,c[i+1].x-c[i].x);local a2=math.atan2(c[i+10].y-c[i+9].y,c[i+10].x-c[i+9].x)
    local d=math.abs((a2-a1+math.pi)%(2*math.pi)-math.pi)
    if d>1e-4 then
      local span=0;for j=i,i+9 do span=span+len(sub(c[j+1],c[j])) end
      if span/d<radius then radius,at=span/d,span*0.5+(i-1)*2 end
    end
  end
  return radius,at
end
function M.buildCenterline(v,ground,spacing)
  spacing=spacing or 2
  local start={x=v.start.x,y=v.start.y,z=v.start.z}
  local ctrl={start};for _,n in ipairs(v.pathNodes or {}) do ctrl[#ctrl+1]={x=n.x,y=n.y,z=n.z} end
  local dense={start}
  local function push(p)
    local last=dense[#dense];local d=sub(p,last)
    if d.x*d.x+d.y*d.y>0.0001 then dense[#dense+1]=(ground and #dense>0) and ground(p) or p end
  end
  for i=1,#ctrl-1 do
    local p1,p2=ctrl[i],ctrl[i+1]
    local p0=ctrl[i-1] or mirror(p1,p2);local p3=ctrl[i+2] or mirror(p2,p1)
    local steps=math.max(2,math.ceil(len(sub(p2,p1))))
    for s=1,steps do push(catmull(p0,p1,p2,p3,s/steps)) end
  end
  local curve=0;for i=2,#dense do curve=curve+len(sub(dense[i],dense[i-1])) end
  local dir
  if #dense>1 then dir=sub(dense[#dense],dense[#dense-1]);local l=len(dir);dir={x=dir.x/l,y=dir.y/l,z=dir.z/l}
  else dir=M.axes({heading=v.heading,grade=v.grade}) end
  local total=curve
  while total<v.length+spacing*2 do
    local last=dense[#dense];local before=#dense
    push({x=last.x+dir.x,y=last.y+dir.y,z=last.z+dir.z})
    if #dense==before then break end
    total=total+len(sub(dense[#dense],last))
  end
  local cursor,arc=2,0
  local function pointAt(target)
    while cursor<#dense do
      local seg=len(sub(dense[cursor],dense[cursor-1]))
      if arc+seg>=target then return lerp(dense[cursor-1],dense[cursor],(target-arc)/seg) end
      arc=arc+seg;cursor=cursor+1
    end
    return dense[#dense]
  end
  local out,chord,along={start},0,0
  while chord+spacing<v.length-spacing*0.25 do
    along=along+spacing
    local q=pointAt(along);local d=len(sub(q,out[#out]))
    if d<0.01 then break end
    out[#out+1]=q;chord=chord+d
  end
  local prev=out[#out];local rest=v.length-chord
  local aim=sub(pointAt(along+rest),prev);local l=len(aim)
  if l<0.01 then aim=dir;l=1 end
  out[#out+1]={x=prev.x+aim.x/l*rest,y=prev.y+aim.y/l*rest,z=prev.z+aim.z/l*rest}
  v.centerline=out
  local f=sub(out[2],out[1]);local h=math.sqrt(f.x*f.x+f.y*f.y)
  if h>0.001 then v.heading=math.deg(math.atan2(f.y,f.x));v.grade=math.max(-1,math.min(1,f.z/h)) end
  local radius,at=bend(out)
  return {curve=curve,radius=radius,radiusAt=at}
end
function M.nodesFromCenterline(c,step)
  step=step or 25
  local nodes,since={},0
  for i=2,#c do
    since=since+len(sub(c[i],c[i-1]))
    if since>=step or i==#c then nodes[#nodes+1]={x=c[i].x,y=c[i].y,z=c[i].z};since=0 end
  end
  while #nodes>M.maxPathNodes do
    local thin={};for i=1,#nodes,2 do thin[#thin+1]=nodes[i] end
    if thin[#thin]~=nodes[#nodes] then thin[#thin+1]=nodes[#nodes] end
    nodes=thin
  end
  return nodes
end
local function segmentAt(path,distance)
  for _,s in ipairs(path.segments) do if distance<=s.distance+s.length then return s end end
  return path.segments[#path.segments]
end
function M.validate(v)
  if type(v)~='table' or v.version~=1 then return false,'Unsupported venue version.' end
  if type(v.id)~='string' or not v.id:match('^[%w_%-]+$') then return false,'Use letters, digits, underscores or hyphens for the venue ID.' end
  if type(v.level)~='string' or not v.level:match('^[%w_%-]+$') then return false,'Invalid level.' end
  if not point(v.start) or not point(v.parking) then return false,'Place the start and signup parking.' end
  if not finite(v.heading) or not finite(v.length) or v.length<10 or v.length>2000 then return false,'Distance must be between 10 and 2000 meters.' end
  if v.finishFlares~=nil then
    if type(v.finishFlares)~='table' then return false,'Invalid finish flare positions.' end
    for _,side in ipairs({'left','right'}) do
      if v.finishFlares[side]~=nil and not point(v.finishFlares[side]) then return false,'Invalid '..side..' finish flare position.' end
    end
  end
  if v.grade~=nil and (not finite(v.grade) or math.abs(v.grade)>1) then return false,'Invalid road grade.' end
  if v.raceTimeout~=nil and (not finite(v.raceTimeout) or v.raceTimeout<10 or v.raceTimeout>600) then return false,'Race timeout must be 10–600 seconds.' end
  if not finite(v.laneWidth) or v.laneWidth<2 or v.laneWidth>12 then return false,'Lane width must be between 2 and 12 meters.' end
  if v.aiSide~='left' and v.aiSide~='right' then return false,'Choose the AI lane.' end
  if v.parkingHeading~=nil and not finite(v.parkingHeading) then return false,'Invalid parking direction.' end
  if v.parkingWidth and (not finite(v.parkingWidth) or v.parkingWidth<2 or v.parkingWidth>20) then return false,'Parking width must be 2–20 meters.' end
  if v.parkingLength and (not finite(v.parkingLength) or v.parkingLength<3 or v.parkingLength>30) then return false,'Parking length must be 3–30 meters.' end
  if v.lostVehicleParking~=nil and v.lostVehicleParking~=false then
    local p=v.lostVehicleParking
    if type(p)~='table' or not point(p.pos) or not finite(p.heading) or not finite(p.width) or p.width<2 or p.width>20
      or not finite(p.length) or p.length<3 or p.length>30 then return false,'Invalid lost vehicle parking.' end
    if p.height~=nil and (not finite(p.height) or p.height<=0) then return false,'Invalid lost vehicle parking height.' end
    if p.rotation~=nil then
      local q=p.rotation
      if type(q)~='table' or not finite(q.x) or not finite(q.y) or not finite(q.z) or not finite(q.w)
        or q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w<0.0001 then return false,'Invalid lost vehicle parking rotation.' end
    end
  end
  if v.centerline~=nil then
    if type(v.centerline)~='table' or #v.centerline<2 or #v.centerline>1024 then return false,'Invalid road centerline.' end
    local total=0
    for i,p in ipairs(v.centerline) do
      if not point(p) then return false,'Invalid road centerline point.' end
      if i>1 then
        local a=v.centerline[i-1];local x,y,z=p.x-a.x,p.y-a.y,p.z-a.z
        if x*x+y*y<0.0001 then return false,'Road centerline points overlap.' end
        total=total+math.sqrt(x*x+y*y+z*z)
      end
    end
    local first=v.centerline[1]
    if math.abs(first.x-v.start.x)+math.abs(first.y-v.start.y)+math.abs(first.z-v.start.z)>0.1 then return false,'Road centerline must begin at the start.' end
    if math.abs(total-v.length)>0.1 then return false,'Road centerline must match the race distance.' end
  end
  if v.pathNodes~=nil then
    if type(v.pathNodes)~='table' or #v.pathNodes>M.maxPathNodes then return false,'Use at most '..M.maxPathNodes..' strip nodes.' end
    for _,p in ipairs(v.pathNodes) do if not point(p) then return false,'Invalid strip node.' end end
  end
  if v.bossParkingSide~=nil and not finite(v.bossParkingSide) then return false,'Invalid display car placement.' end
  if v.signupTent then
    local t=v.signupTent;if type(t)~='table' then return false,'Invalid signup tent placement.' end
    if t.components~=nil and (type(t.components)~='table' or #t.components>16) then return false,'Invalid signup tent components.' end
    local parts={t};for _,part in ipairs(t.components or {}) do parts[#parts+1]=part end
    for _,part in ipairs(parts) do
      if type(part)~='table' then return false,'Invalid signup tent placement.' end
      local q=part.rot
      if type(part.shape)~='string' or not point(part.pos) or not point(part.scale) or part.scale.x<=0 or part.scale.y<=0 or part.scale.z<=0
        or (part.name~=nil and type(part.name)~='string')
        or type(q)~='table' or not finite(q.x) or not finite(q.y) or not finite(q.z) or not finite(q.w)
        or q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w<0.0001 then return false,'Invalid signup tent placement.' end
    end
  end
  if v.props~=nil then
    if type(v.props)~='table' or #v.props>48 then return false,'Invalid decoration list.' end
    for i,p in ipairs(v.props) do
      local s=type(p)=='table' and p.scale
      if type(p)~='table' or type(p.shape)~='string' or not p.shape:lower():match('%.dae$') or not point(p.pos) or not finite(p.heading or 0)
        or not point(s) or s.x<=0 or s.y<=0 or s.z<=0 or s.x>20 or s.y>20 or s.z>20 then return false,'Decoration part '..i..' needs a mesh, position and scale.' end
    end
  end
  if v.bossDisplay~=nil and type(v.bossDisplay)~='boolean' then return false,'Invalid rival car setting.' end
  if v.bossSpot~=nil and not point(v.bossSpot) then return false,'Invalid rival car placement.' end
  if v.bossHeading~=nil and not finite(v.bossHeading) then return false,'Invalid rival car direction.' end
  return true
end
local rally='/art/shapes/race/rally/rally_assets/s_rally_gazebo_mod_'
local gazeboColors={{'rotopad','Rotopad'},{'blastr','Blastr'},{'dkblue','Dark blue'},{'ngrc','NGRC'}}
local levelTents={}
local function meshLabel(path)
  local file=path:match('([^/]+)%.[Dd][Aa][Ee]$') or path
  return (file:gsub('^s_',''):gsub('_',' '):gsub('^%l',string.upper))
end
M.meshLabel=meshLabel
function M.propShapes(level)
  local shapes={{id=rally..'frame_3x3.dae',label='Rally gazebo frame 3x3'},{id=rally..'frame_addon_3x3.dae',label='Rally gazebo frame add-on 3x3'}}
  for _,c in ipairs(gazeboColors) do
    shapes[#shapes+1]={id=rally..'cover_'..c[1]..'_3x3.dae',label='Rally gazebo cover 3x3 - '..c[2]}
    shapes[#shapes+1]={id=rally..'cover_'..c[1]..'_3x6.dae',label='Rally gazebo cover 3x6 - '..c[2]}
  end
  if level and level~='' then
    if not levelTents[level] then
      local found,seen={},{}
      for _,pattern in ipairs({'*tent*.dae','*gazebo*.dae'}) do
        for _,f in ipairs(FS:findFiles('/levels/'..level..'/art',pattern,-1,true,false) or {}) do
          local key=f:lower()
          if not seen[key] and not key:find('trailer',1,true) then seen[key]=true;found[#found+1]=f end
        end
      end
      table.sort(found,function(a,b) return a:lower()<b:lower() end)
      levelTents[level]=found
    end
    for _,f in ipairs(levelTents[level]) do shapes[#shapes+1]={id=f,label='Map: '..meshLabel(f)} end
  end
  return shapes
end
function M.propRotation(p)
  local rot=p.rot
  if point(rot) and finite(rot.w) then
    local length=math.sqrt(rot.x*rot.x+rot.y*rot.y+rot.z*rot.z+rot.w*rot.w)
    if length>=0.01 then return {x=rot.x/length,y=rot.y/length,z=rot.z/length,w=rot.w/length} end
  end
  local f=M.axes({heading=p.heading or 0})
  local q=quatFromDir(vec3(f),vec3(0,0,1))
  return {x=q.x,y=q.y,z=q.z,w=q.w}
end
function M.headingFromRotation(r)
  local f=quat(r.x,r.y,r.z,r.w)*vec3(0,1,0)
  return math.deg(math.atan2(f.y,f.x))
end
function M.propsFromSignupTent(t)
  if type(t)~='table' then return nil end
  local props={}
  local parts={t};for _,part in ipairs(t.components or {}) do parts[#parts+1]=part end
  for _,part in ipairs(parts) do
    if type(part.shape)=='string' and point(part.pos) then
      props[#props+1]={shape=part.shape,pos={x=part.pos.x,y=part.pos.y,z=part.pos.z},
        heading=part.rot and M.headingFromRotation(part.rot) or 0,
        scale=point(part.scale) and {x=part.scale.x,y=part.scale.y,z=part.scale.z} or {x=1,y=1,z=1}}
    end
  end
  return props
end
function M.bossSpot(v)
  if v.bossSpot then return v.bossSpot,v.bossHeading or v.parkingHeading or v.heading end
  if not v.parking then return nil end
  local heading=v.parkingHeading or v.heading
  return M.position({start=v.parking,heading=heading},5,v.bossParkingSide or 5),heading
end
function M.axes(v,distance)
  local path=route(v)
  if path then local s=segmentAt(path,distance or 0);return s.forward,s.right end
  local a=math.rad(v.heading)
  local grade=v.grade or 0;local norm=math.sqrt(1+grade*grade)
  return {x=math.cos(a)/norm,y=math.sin(a)/norm,z=grade/norm},{x=math.sin(a),y=-math.cos(a),z=0}
end
function M.position(v,distance,side)
  local path=route(v)
  if path then
    local s=segmentAt(path,distance);local d=distance-s.distance;local f,r=s.forward,s.right
    return {x=s.start.x+f.x*d+r.x*(side or 0),y=s.start.y+f.y*d+r.y*(side or 0),z=s.start.z+f.z*d}
  end
  local f,r=M.axes(v)
  return {x=v.start.x+f.x*distance+r.x*(side or 0),y=v.start.y+f.y*distance+r.y*(side or 0),z=v.start.z+f.z*distance}
end
function M.finishFlarePosition(v,side)
  local custom=v.finishFlares and v.finishFlares[side<0 and 'left' or 'right']
  return custom or M.position(v,v.length,side*(v.laneWidth+2))
end
function M.project(v,p)
  local path=route(v)
  if path then
    local best,along,side=math.huge,0,0
    for i,s in ipairs(path.segments) do
      local x,y,z=p.x-s.start.x,p.y-s.start.y,p.z-s.start.z;local f=s.forward
      local d=x*f.x+y*f.y+z*f.z;local bounded=math.max(0,math.min(s.length,d))
      local dx,dy,dz=x-f.x*bounded,y-f.y*bounded,z-f.z*bounded
      local distance=dx*dx+dy*dy+dz*dz
      if distance<best then
        best=distance
        if not ((i==1 and d<0) or (i==#path.segments and d>s.length)) then d=bounded end
        along=s.distance+d;side=x*s.right.x+y*s.right.y
      end
    end
    return along,side
  end
  local f,r=M.axes(v);local x,y=p.x-v.start.x,p.y-v.start.y
  return x*f.x+y*f.y+(p.z-v.start.z)*f.z,x*r.x+y*r.y
end
function M.lanePath(v,side)
  local path=route(v);if not path then return end
  local points={}
  for _,s in ipairs(path.segments) do local p=M.position(v,s.distance,side);p.distance=s.distance;points[#points+1]=p end
  for _,d in ipairs({v.length,v.length+100}) do local p=M.position(v,d,side);p.distance=d;points[#points+1]=p end
  return points
end
function M.aim(v,p,locked)
  local dx,dy=p.x-v.start.x,p.y-v.start.y
  if dx*dx+dy*dy<1 then return end
  v.heading=math.deg(math.atan2(dy,dx))
  local dz=(p.z or v.start.z)-v.start.z
  v.grade=dz/math.sqrt(dx*dx+dy*dy)
  if not locked then v.length=math.sqrt(dx*dx+dy*dy+dz*dz) end
end
function M.basePath(level) return '/levels/'..level..'/streetKnights/' end
function M.path(v) return M.basePath(v.level)..v.id..'.venue.json' end
function M.getLostVehicleParking(v)
  local published=jsonReadFile(M.path(v))
  local path=published and published.sitesPath or v.sitesPath
  local sites=path and jsonReadFile(path)
  for _,spot in ipairs(sites and sites.parkingSpots or {}) do
    if spot.name==v.id..'_lostVehicle' then return deepcopy(spot) end
  end
end
local function deletionPath(v) return M.basePath(v.level)..v.id..'.deleted.json' end
local function isDeleted(v)
  local marker=jsonReadFile(deletionPath(v));return marker and marker.deleted==true
end
local function rotation(v,distance)
  local f=M.axes(v,distance);local q=quatFromDir(vec3(f),vec3(0,0,1))
  return {x=q.x,y=q.y,z=q.z,w=q.w}
end
function M.strip(v)
  local lanes={};local rot=rotation(v,v.length/2)
  for i,side in ipairs({-1,1}) do
    local offset=side*v.laneWidth/2;local points={}
    for _,w in ipairs({{'spawn',-4},{'stage',0},{'endLine',v.length},{'end',v.length+100}}) do
      points[#points+1]={id=v.id..'_'..i..'_'..w[1],name=w[1],type=w[1],
        transform={position=M.position(v,w[2],offset),rotation=rotation(v,w[2]),scale={x=v.laneWidth,y=0.2,z=3}}}
    end
    lanes[i]={id=v.id..'_'..i,shortName=i==1 and 'Left' or 'Right',longName='Street Knights lane '..i,laneOrder=i,
      color={1,0.5,0.2,1},waypoints=points,boundary={transform={position=M.position(v,v.length/2,offset),rotation=rot,scale={x=v.laneWidth,y=v.length+10,z=10}}}}
  end
  return {id=v.id,name=v.name or v.id,description='Street Knights',lanes=lanes}
end
function M.save(v)
  if not (overhaul_shell_extensionManager and overhaul_shell_extensionManager.isDevKeyValid(true)) then return false,'Developer access required.' end
  local ok,err=M.validate(v);if not ok then return false,err end
  if v.level~=getCurrentLevelIdentifier() then return false,'Load the venue level before saving.' end
  -- A revision directory plus a final manifest makes a partially written export invisible.
  local root=M.basePath(v.level)..v.id..'_'..tostring(os.time())..'_'..tostring(math.random(10000,99999))..'/'
  if not overhaul_career_saveSystem then return false,'Career save service is required for safe venue publication.' end
  local writer=overhaul_career_saveSystem.getSaveWriter()
  writer.mkdir(root)
  local record=deepcopy(v);record.stripPath=root..'strip.json';record.settingsPath=root..'settings.json';record.sitesPath=root..'signup.sites.json'
  local parkingRotation=rotation({heading=v.parkingHeading or v.heading})
  local sites={name=v.id,parkingSpots={{oldId=1,color={0.2,0.5,1},isMultiSpot=false,name=v.id..'_signup',pos={v.parking.x,v.parking.y,v.parking.z},rot={parkingRotation.x,parkingRotation.y,parkingRotation.z,parkingRotation.w},scl={v.parkingWidth or 4,v.parkingLength or 8,3},customFields={values={streetKnightsVenue=v.id},types={streetKnightsVenue='string'},tags={'streetKnightsSignup'}}}},zones={},locations={}}
  local previous=M.getLostVehicleParking(v)
  local parking=v.lostVehicleParking
  if parking~=false and (parking or previous) then
    local saved=previous or {color={0.7,0.4,1},isMultiSpot=false,customFields={values={},types={},tags={}}}
    saved.name=v.id..'_lostVehicle';saved.oldId=2
    if parking then
      local q=parking.rotation or rotation({heading=parking.heading})
      saved.pos={parking.pos.x,parking.pos.y,parking.pos.z};saved.rot={q.x,q.y,q.z,q.w};saved.scl={parking.width,parking.length,parking.height or 3}
    end
    sites.parkingSpots[2]=saved
  end
  record.lostVehicleParking=nil
  local settings={stripId=record.stripPath,dragType='headsUpRace',context='streetKnights',canBeReseted=false,canBeTeleported=false,
    streetKnights={distance=v.length,importantTimer=v.length},phases={{name='stage',dependency=true},{name='countdown',dependency=true},{name='race',dependency=false}}}
  for file,data in pairs({[record.stripPath]=M.strip(v),[record.settingsPath]=settings,[record.sitesPath]=sites}) do
    writer.json(file,data,true)
    if not jsonReadFile(file) then return false,'Could not verify venue export.' end
  end
  local loaded,site=pcall(function()
    local s=require('/lua/ge/extensions/gameplay/sites/sites')()
    s:onDeserialized(jsonReadFile(record.sitesPath));s:finalizeSites();return s
  end)
  if not loaded or #site.parkingSpots.sorted~=#sites.parkingSpots then return false,'Native parking export validation failed: '..tostring(site) end
  if not overhaul_career_saveSystem then return false,'Career save service is required for safe venue publication.' end
  overhaul_career_saveSystem.jsonWriteFileSafe(M.path(v),record,true)
  local written=jsonReadFile(M.path(v))
  if not written or written.stripPath~=record.stripPath then return false,'Could not publish venue.' end
  if isDeleted(v) then
    overhaul_career_saveSystem.jsonWriteFileSafe(deletionPath(v),{deleted=false},true)
    if isDeleted(v) then return false,'Could not restore the deleted venue.' end
  end
  -- Sites discovery scans every revision directory. Retain old exports for recovery,
  -- but remove their Sites suffix after publication so parking is not duplicated.
  local escaped=(M.basePath(v.level)..v.id):gsub('([^%w])','%%%1')
  for _,file in ipairs(FS:findFiles(M.basePath(v.level),'signup.sites.json',-1,true,false) or {}) do
    if file~=record.sitesPath and file:match('^'..escaped..'_%d+_%d+/signup%.sites%.json$') then
      if writer.rename(file,file:gsub('%.sites%.json$','.retired.json'))~=0 then
        log('W','streetKnightsVenues','Could not retire obsolete parking export: '..file)
      end
    end
  end
  if gameplay_sites_sitesManager then gameplay_sites_sitesManager.getAllLevelSites() end
  extensions.hook('onStreetKnightsVenuesChanged')
  return true,record
end
function M.delete(level,id)
  if not (overhaul_shell_extensionManager and overhaul_shell_extensionManager.isDevKeyValid(true)) then return false,'Developer access required.' end
  if type(level)~='string' or not level:match('^[%w_%-]+$') or type(id)~='string' or not id:match('^[%w_%-]+$') then return false,'Invalid venue ID or level.' end
  if level~=getCurrentLevelIdentifier() then return false,'Load the venue level before deleting.' end
  if overhaul_career_career and overhaul_career_career.isActive() and overhaul_career_economy_streetKnights and overhaul_career_economy_streetKnights.getState().race then return false,'Finish or abandon the race before deleting a venue.' end
  local v=jsonReadFile(M.path({level=level,id=id}))
  if not M.validate(v) or v.id~=id or v.level~=level then return false,'Saved venue not found.' end
  if not overhaul_career_saveSystem then return false,'Career save service is required for safe deletion.' end
  -- A local tombstone also hides packaged venues without modifying their source mod.
  overhaul_career_saveSystem.jsonWriteFileSafe(deletionPath(v),{deleted=true,id=id,level=level},true)
  if not isDeleted(v) then return false,'Could not save venue deletion.' end
  local escaped=(M.basePath(level)..id):gsub('([^%w])','%%%1')
  local warning
  for _,file in ipairs(FS:findFiles(M.basePath(level),'signup.sites.json',-1,true,false) or {})do
    if file:match('^'..escaped..'/signup%.sites%.json$') or file:match('^'..escaped..'_%d+_%d+/signup%.sites%.json$') then
      -- Override with an empty Sites file so packaged parking cannot reappear on reload.
      local data=jsonReadFile(file)
      if data and data.parkingSpots and #data.parkingSpots>0 then
        local backup=file:gsub('%.sites%.json$','.deleted.json')
        overhaul_career_saveSystem.jsonWriteFileSafe(backup,data,true)
        if jsonReadFile(backup) then
          overhaul_career_saveSystem.jsonWriteFileSafe(file,{name=id,parkingSpots={},zones={},locations={}},true)
          local empty=jsonReadFile(file)
          if not empty or not empty.parkingSpots or #empty.parkingSpots~=0 then warning=' Parking cleanup failed; the race is disabled.' end
        else warning=' Parking backup failed; the race is disabled.' end
      end
    end
  end
  if gameplay_sites_sitesManager then gameplay_sites_sitesManager.getAllLevelSites() end
  extensions.hook('onStreetKnightsVenuesChanged')
  return true,'Deleted '..id..'.'..(warning or '')
end
function M.list(level)
  local result={}
  for _,file in ipairs(FS:findFiles(M.basePath(level),'*.venue.json',0,false,false) or {}) do
    local v=jsonReadFile(file)
    if M.validate(v) and v.level==level and not isDeleted(v) and (not v.developerOnly or (overhaul_shell_extensionManager and overhaul_shell_extensionManager.isDevKeyValid())) then v.name=venueName(v);result[#result+1]=v end
  end
  table.sort(result,function(a,b) return a.id<b.id end)
  return result
end
return M
