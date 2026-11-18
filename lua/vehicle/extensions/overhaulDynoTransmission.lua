-- Temporary native transmission restrictions for one dyno pull. No changes to
-- authored ratios, converter capacity, damage, or persisted vehicle tuning.
local M={}
local run
local function finite(x)return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function upvalue(fn,wanted)
  if type(fn)~='function' or not debug or not debug.getupvalue then return end
  for i=1,100 do local name,value=debug.getupvalue(fn,i);if not name then break end;if name==wanted then return value end end
end
local function inspect()
  local main=controller and controller.mainController
  local logic=main and upvalue(main.getState,'controlLogicModule')
  local handling=logic and upvalue(logic.setState,'automaticHandling')
  local devices=powertrain and powertrain.getDevices and powertrain.getDevices() or {}
  local box,converters,count=nil,{},0
  for _,d in pairs(devices)do
    if d.type=='automaticGearbox' or d.type=='dctGearbox' then box=d;count=count+1 end
    if d.type=='torqueConverter' then converters[#converters+1]=d end
  end
  if count~=1 or type(handling)~='table' or not finite(tonumber(handling.minGearIndex)) or not finite(tonumber(handling.maxGearIndex)) then return end
  -- Verify the native logic belongs to this gearbox; custom controllers opt out.
  if upvalue(logic.setState,'applyGearboxMode') then
    local apply=upvalue(logic.setState,'applyGearboxMode')
    if upvalue(apply,'gearbox')~=box then return end
  else return end
  local converter=box.parent
  if not converter or converter.type~='torqueConverter' then converter=#converters==1 and converters[1] or nil end
  local engine=upvalue(logic.init,'engine') or (converter and converter.parent)
  return {main=main,logic=logic,handling=handling,box=box,converter=converter,engine=engine,converterHandling=upvalue(logic.init,'torqueConverterHandling')}
end
function M.describe()
  local c=inspect();local out={supported=false,gears={},lockupSupported=false}
  if not c then return out end
  out.supported=true;out.type=c.box.type
  for gear=1,c.box.maxGearIndex or 0 do
    local ratio=c.box.gearRatios and c.box.gearRatios[gear]
    if finite(ratio) and ratio>0 then out.gears[#out.gears+1]={gear=gear,ratio=ratio} end
  end
  -- Respect equipment without a lockup clutch instead of adding one in Lua.
  local tc=c.converter
  out.lockupSupported=tc~=nil and c.converterHandling and c.converterHandling.hasLockup==true and finite(tc.lockupClutchTorque) and tc.lockupClutchTorque>0 and type(tc.torqueUpdate)=='function' or false
  return out
end
function M.release()
  local r=run;run=nil
  if not r then return end
  if r.restricted then
    r.c.handling.minGearIndex=r.minGear
    r.c.handling.maxGearIndex=r.maxGear
    r.c.handling.autoDownShiftInM=r.autoDown
    -- Preserve a player's selector change, with its native bounds recalculated.
    if r.c.handling.mode~=r.mode then r.c.logic.setState({grb_mde=r.c.handling.mode}) end
  end
  if r.wrapper and r.c.converter.torqueUpdate==r.wrapper then r.c.converter.torqueUpdate=r.original end
end
local function installLockup(r)
  local tc=r.c.converter
  if not r.lockup or not tc then return end
  r.original=tc.torqueUpdate
  r.wrapper=function(self,dt)
    local values=electrics.values
    local name=self.lockupClutchRatioName or 'lockupClutchRatio'
    local engine=r.c.engine
    local idle=engine and engine.idleAV or 800*.104719755
    local eligible=run==r and r.active and r.c.box.gearIndex==r.gear
      and not r.c.box.isShifting and not r.c.box.isShiftingUp and not r.c.box.isShiftingDown
      and (self.inputAV or 0)>idle*1.5 and (values.brake or 0)<.02
      and not self.isDisabled and (not engine or not engine.isDisabled)
    r.lockRatio=eligible and math.min(1,(r.lockRatio or 0)+math.max(0,dt or 0)*3) or 0
    local previous=values[name]
    if eligible then values[name]=math.max(previous or 0,r.lockRatio) end
    local ok,err=pcall(r.original,self,dt)
    values[name]=previous
    if not ok then error(err) end
  end
  tc.torqueUpdate=r.wrapper
end
local function engage(r)
  local c=r.c
  local mode=c.handling.mode
  if mode=='P' or mode=='R' or mode=='N' or c.box.gearIndex<0 then return end
  -- Request the gear through native shift logic. Waiting for it first lets
  -- manual-mode auto-downshift prevent the hold from ever engaging at low RPM.
  local engine=c.engine or c.box.parent
  local ratio=c.box.gearRatios[r.gear]
  local currentRatio=c.box.gearRatio or c.box.gearRatios[c.box.gearIndex]
  local shaftAV=c.box.outputAV1 or (currentRatio and currentRatio>0 and (c.box.inputAV or 0)/currentRatio) or 0
  if not r.restricted and c.box.gearIndex~=r.gear and engine and engine.maxAV
    and math.abs(shaftAV)*ratio>engine.maxAV*.95 then return end
  if not r.restricted then
    r.minGear=c.handling.minGearIndex;r.maxGear=c.handling.maxGearIndex
    r.autoDown=c.handling.autoDownShiftInM;r.mode=mode;r.restricted=true
  end
  c.handling.minGearIndex=r.gear;c.handling.maxGearIndex=r.gear;c.handling.autoDownShiftInM=false
  if r.active then return end
  if c.box.gearIndex~=r.gear or c.box.isShifting or c.box.isShiftingUp or c.box.isShiftingDown then return end
  r.active=true
  installLockup(r)
end
function M.arm(options)
  M.release();options=options or {}
  local gear=tonumber(options.holdGear)
  if not gear or gear==0 then return true end
  local c=inspect();local description=M.describe()
  if not c or not finite(gear) or gear%1~=0 or gear<1 or not c.box.gearRatios or not finite(c.box.gearRatios[gear]) or gear>(c.box.maxGearIndex or 0) then return false end
  if options.lockup==true and not description.lockupSupported then return false end
  run={c=c,gear=gear,active=false,lockup=options.lockup==true}
  -- Apply native restrictions before the next controller tick when in Drive.
  engage(run)
  return true
end
function M.updateGFX()
  local r=run;if not r then return end
  local c=r.c
  if powertrain.getDevices()[c.box.name]~=c.box then M.release();return end
  if r.restricted and (c.handling.mode=='P' or c.handling.mode=='R' or c.handling.mode=='N' or c.box.gearIndex<0) then M.release();return end
  engage(r)
end
function M.getState()
  local r=run
  return r and {selectedGear=r.gear,active=r.active,pending=not r.active,ratio=r.c.box.gearRatios[r.gear],lockup=r.lockup,lockupRatio=r.lockRatio or 0} or {active=false,pending=false}
end
function M.report()
  obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('dynoTransmissionInfo', obj:getID()..','..serialize(M.describe())))
end
M.onReset=M.release
M.onExtensionUnloaded=M.release
return M
