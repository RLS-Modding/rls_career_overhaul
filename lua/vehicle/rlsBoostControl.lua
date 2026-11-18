-- One setter wrapper shared by the scanner and fuel runtime.
local M={}
local records=setmetatable({},{__mode='k'})
local function baselineControl(turbo)
  local capability=turbo.wastegateBaselineControl
  if type(capability)=='table' and capability.version==1 and capability.active
    and type(capability.resolveOffset)=='function' and type(capability.getMidpoint)=='function'
    and type(capability.getNativeOffset)=='function' then return capability end
end
local function apply(r)
  local bridge=baselineControl(r.turbo)
  local baseline=bridge and bridge.active and bridge.resolveOffset(r.native) or r.native
  local midpoint=bridge and bridge.active and bridge.getMidpoint() or r.midpoint
  local offset=r.target~=nil and (r.target-midpoint) or (baseline+r.pro)
  r.interface.nativeOffset=r.native
  r.interface.targetPsi=r.target
  r.interface.proOffset=r.pro
  r.interface.commandedOffset=offset
  -- Bypass the lower-priority baseline wrapper, if it was installed before ours.
  r.original(offset,'wastegate-target')
end
local function turboData(engine)
  local engineData=v and v.data and v.data[engine.name]
  local name=engineData and engineData.turbocharger
  local data=v and v.data and v.data[type(name)=='string' and name or 'turbocharger']
  return type(data)=='table' and data or nil
end
local function interface(engine)
  local turbo=engine and engine.turbocharger
  if not turbo or turbo.isExisting==false then
    return nil,nil,'Boost targets require a turbocharger; a belt-driven supercharger cannot use wastegate control.'
  end
  if type(turbo.setWastegateOffset)~='function' then
    return nil,nil,'This turbo uses a custom controller without a wastegate target interface.'
  end
  local data=turboData(engine)
  if not data then return nil,nil,'Turbo calibration data is unavailable; boost targets cannot be applied.' end
  return turbo,data
end
function M.supported(engine,box)
  local turbo,_,reason=interface(engine)
  if not turbo then return false,reason end
  if not box or #M.gears(box)==0 then return false,'Boost by gear requires one discrete gearbox; this drivetrain has no unambiguous forward gears.' end
  return true
end
function M.bind(engine)
  local turbo,data=interface(engine)
  if not turbo then return nil end
  local r=records[turbo]
  if r then return r end
  r={original=turbo.setWastegateOffset,native=0,pro=0,midpoint=0,data=data,users={},turbo=turbo}
  r.interface={version=1,refresh=function() apply(r) end,detachBaseline=function(wrapper,original)
    if wrapper and r.original==wrapper then r.original=original end
  end}
  turbo.wastegateTargetControl=r.interface
  r.wrapper=function(psi) r.native=tonumber(psi) or 0;apply(r) end
  records[turbo]=r;turbo.setWastegateOffset=r.wrapper
  local dm=controller and controller.getController and controller.getController('driveModes')
  if dm and dm.getCurrentDriveModeKey and dm.getDriveModeData then
    local mode=dm.getDriveModeData(dm.getCurrentDriveModeKey())
    for _,s in pairs(mode and mode.settings or {}) do
      if s.type=='turbocharger' and s.name==engine.name then r.native=tonumber(s.wastegateOffset) or 0 end
    end
  end
  local bridge=baselineControl(turbo)
  if bridge and bridge.active then r.native=bridge.getNativeOffset() end
  r.interface.nativeOffset=r.native
  return r
end
local function pressure(value,gear)
  if type(value)~='table' then return tonumber(value) end
  if tonumber(value[gear]) then return tonumber(value[gear]) end
  local last;for _,n in pairs(value) do last=tonumber(n) end;return last
end
function M.setTarget(engine,target)
  local r=M.bind(engine);if not r then return false end
  r.users.fuel=true
  local gear=electrics and electrics.values and electrics.values.gearIndex or 0
  local start=pressure(r.data.wastegateStart,gear) or 0
  local limit=pressure(r.data.wastegateLimit,gear) or start+.01
  r.midpoint=(start+limit)*.5;r.target=target;apply(r);return true
end
function M.setProOffset(engine,offset)
  local r=M.bind(engine);if not r then return false end
  r.users.scanner=true;r.pro=offset or 0;apply(r);return true
end
function M.proOffset(engine)
  local r=engine and records[engine.turbocharger]
  return r and r.pro or 0
end
function M.release(engine,user)
  local turbo=engine and engine.turbocharger;local r=turbo and records[turbo]
  if not r then return end
  r.users[user]=nil
  if user=='fuel' then r.target=nil else r.pro=0 end
  apply(r)
  if not next(r.users) then
    if turbo.setWastegateOffset==r.wrapper then turbo.setWastegateOffset=r.original end
    if turbo.wastegateTargetControl==r.interface then turbo.wastegateTargetControl=nil end
    records[turbo]=nil
  end
end
function M.gearbox(engine)
  local seen,found={},{}
  local function visit(d)
    if type(d)~='table' or seen[d] then return end;seen[d]=true
    if d.type~='rangeBox' and type(d.gearRatios)=='table' and d.maxGearIndex then found[#found+1]=d;return end
    for _,child in pairs(d.children or {}) do visit(child) end
  end
  visit(engine)
  if #found~=1 or found[1].type=='cvtGearbox' then return nil,'No unambiguous discrete gearbox' end
  return found[1]
end
function M.gears(box)
  local out={}
  for gear,ratio in pairs(box and box.gearRatios or {}) do
    if type(gear)=='number' and gear%1==0 and gear>0 and gear<math.huge
      and type(ratio)=='number' and ratio~=0 and math.abs(ratio)<math.huge then out[#out+1]=gear end
  end
  table.sort(out);return out
end
function M.currentGear(box)
  if not box then return 0 end
  if box.type=='dctGearbox' then
    -- A DCT keeps a forward gear preselected in Neutral/Park. It is not engaged.
    if box.mode=='neutral' or box.mode=='park' or math.max(box.clutchRatio1 or 0,box.clutchRatio2 or 0)<=0 then return 0 end
    return (box.clutchRatio1 or 0)>=(box.clutchRatio2 or 0) and (box.gearIndex1 or 0) or (box.gearIndex2 or 0)
  end
  return box.gearIndex or 0
end
return M
