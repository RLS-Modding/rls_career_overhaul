-- Smoke transport for a temporary diesel governor. Never requests fuel/torque.
local M={}
local model=require('common/rlsFuelModel')
local tau=.12
function M.record(c,e,response,spent,dt)
  if c.profile.fuelType~='diesel' or not e.isTempRevLimiterActive or spent<=0 or dt<=0 then return end
  if e.hasFuel==false or e.isDisabled or e.isStalled or (e.ignitionCoef or 1)<=0 or response.boostFuelCut then return end
  -- Sample firing pulses in physics, not the GFX load at an arbitrary cut edge.
  -- This also respects a soft governor's reduced fueling/load.
  local load=model.clamp(e.instantEngineLoad or e.engineLoad or 0,0,1)
  local afr=response.afr or 200
  local soot=model.clamp((18-afr)/6,0,1)*load
  local enrichment=model.clamp((model.dieselAFR(load)-afr)/6,0,1)
  local mixing=.75*(response.smokeBoostDeficit or 0)*load*model.clamp((24-afr)/6,0,1)*enrichment
  local rich=math.sqrt(soot)
  local amount=model.clamp(rich+(1-rich)*mixing,0,1)*dt
  c.limiterSmokePending=math.min(.25,(c.limiterSmokePending or 0)+amount)
end
function M.confirm(c,deliveredJ,requestedJ)
  local paid=model.clamp(deliveredJ/math.max(1e-12,requestedJ),0,1)
  c.limiterSmoke=math.min(.25,(c.limiterSmoke or 0)+(c.limiterSmokePending or 0)*paid)
  c.limiterSmokePending=0
end
function M.clear(c)
  c.limiterSmoke=0;c.limiterSmokePending=0
end
function M.consume(c,dt)
  if dt<=0 then return 0 end
  local stored=c.limiterSmoke or 0
  local emitted=stored*(1-math.exp(-dt/tau))
  c.limiterSmoke=stored-emitted
  if c.limiterSmoke<1e-8 then c.limiterSmoke=0 end
  -- Return an average intensity. A hitch discards excess rather than bursting.
  return math.min(1,emitted/dt)
end
return M
