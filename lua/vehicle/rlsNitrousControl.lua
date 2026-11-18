-- Gate the native controller, never synthesize torque or bottle consumption.
local M={}
local tuneModel=require('common/rlsNitrousTune')
local boost=require('vehicle/rlsBoostControl')
local records=setmetatable({},{__mode='k'})
function M.installed(e) return e.nitrousOxideInjection and e.nitrousOxideInjection.isExisting==true or false end
function M.supported(e,box,tune)
  if not M.installed(e) then return false,'Install nitrous hardware before tuning it.' end
  local d=v and v.data and v.data[e.name]
  if not d or (d.nitrousOxideLuaFileName and d.nitrousOxideLuaFileName~='powertrain/nitrousOxideInjection') or type(e.nitrousOxideInjection.updateGFX)~='function' then return false,'This custom nitrous controller is not supported.' end
  if tune and tune.mode=='rpmGear' then
    local gears=boost.gears(box)
    if #gears==0 or tune.maxGear>gears[#gears] then return false,'Nitrous gear limits must match the installed transmission.' end
  end
  return true
end
function M.release(e)
  local r=records[e]
  if not r then return end
  r.active=false
  if r.controller.updateGFX==r.wrapper then r.controller.updateGFX=r.original end
  records[e]=nil
end
function M.set(e,box,tune)
  if not tune or tune.mode=='original' or not tuneModel.validate(tune) or not M.supported(e,box) then M.release(e);return end
  local r=records[e]
  if r and (r.controller~=e.nitrousOxideInjection or r.controller.updateGFX~=r.wrapper) then M.release(e);r=nil end
  if not r then
    local d=v.data[e.name]
    local data=v.data[d.nitrousOxideInjection] or {}
    r={controller=e.nitrousOxideInjection,active=true}
    r.original=r.controller.updateGFX
    local arm,override=data.electricsArmName or 'nitrousOxideArm',data.electricsOverrideName or 'nitrousOxideOverride'
    r.wrapper=function(dt)
      if not r.active then return r.original(dt) end
      local ev=electrics.values
      local gear=boost.currentGear(r.box)
      if not r.box then gear=ev.gearIndex end
      local allowed=M.supported(e,r.box,r.tune) and tuneModel.allows(r.tune,(e.outputAV1 or 0)*9.5492966,(ev.airspeed or 0)*3.6,gear)
        and (e.throttle or 0)>=1 and (ev.clutch or 0)==0 and not e.isDisabled and not e.isStalled
      if allowed then return r.original(dt) end
      local a,o=ev[arm],ev[override]
      ev[arm],ev[override]=0,0
      local ok,err=pcall(r.original,dt)
      ev[arm],ev[override]=a,o
      if not ok then error(err) end
    end
    records[e]=r;r.controller.updateGFX=r.wrapper
  end
  r.box=box;r.tune=tune
end
return M
