-- Reduced-order overrun and exhaust combustion. SI units; no renderer/career
-- pacing here. Native afterfire counters are deliberately not a fuel input.
local M={}
local model=require('common/rlsFuelModel')
local exhaustModel=require('common/rlsExhaustCombustion')
local clamp=model.clamp
function M.referenceEnergy(e,av,air,eff,cut,dt)
  -- Reconstruct only the native algebra using the original air coefficient and
  -- the throttle already smoothed by native code. Never execute physics twice.
  for _,key in ipairs({'friction','wearFrictionCoef','damageFrictionCoef','dynamicFriction','wearDynamicFrictionCoef','damageDynamicFrictionCoef',
    'maxPowerThrottleMap','forcedInductionCoef','nitrousOxideTorque','outputTorqueState','slowIgnitionErrorCoef','fastIgnitionErrorCoef','halfInvEngInertia','throttle'}) do
    if type(e[key])~='number' then return nil end
  end
  -- Older native forks predate the torque limit; native defaults it to no limit.
  local torqueLimit=e.maxTorqueLimit==nil and math.huge or e.maxTorqueLimit
  if type(torqueLimit)~='number' then return nil end
  local outputState=e.outputTorqueState
  local maintenance=e.rlsMaintenanceOutput
  -- An outer maintenance wrapper still has its temporary factor installed;
  -- an inner one restored it before fuel accounting. Match either hook order.
  if maintenance and not maintenance.inCall then
    outputState=outputState*math.min(maintenance.engine or 1,maintenance.cooling or 1)
  end
  if not e.invBurnEfficiencyTable then return nil end
  local torque=(e.torqueCurve[math.floor(av*9.5492965855)] or 0)*air
  local friction=e.friction*e.wearFrictionCoef*e.damageFrictionCoef
  local dynamic=e.dynamicFriction*e.wearDynamicFrictionCoef*e.damageDynamicFrictionCoef
  local maxTorque=torque-friction-dynamic*av
  local t=e.throttle
  local a=math.max(t+t*e.maxPowerThrottleMap/(torque*e.forcedInductionCoef*av+1e-30)*(1-t),0)
  local k=(1-t)*.8
  local h=k>0 and clamp(.5+(1-a)/k,0,1) or (a<1 and 1 or 0)
  local throttleMap=h*a+(1-h)*(1-h*k*.5)
  torque=math.min(((torque*e.forcedInductionCoef*throttleMap)+e.nitrousOxideTorque)*outputState*(cut and 0 or 1)*e.slowIgnitionErrorCoef*e.fastIgnitionErrorCoef,torqueLimit)
  local load=clamp(torque/((maxTorque+1e-30)*outputState*e.forcedInductionCoef),0,1)
  local inverse=e.invBurnEfficiencyTable[math.floor(load*100)]
  if not inverse then return nil end
  local impulse=dt*torque
  return math.max(0,impulse*(impulse*e.halfInvEngInertia+av)*inverse*eff/(e.rlsFuelConsumptionMultiplier or 1))
end
function M.overrun(memory,profile,tune,fuel,input,dt)
  local d=model.decel(tune)
  local eligible=input.running and input.throttle<.02 and input.load<.08 and input.rpm>profile.idleRPM*1.4 and input.temperature>45
  memory.overrunTime=eligible and (memory.overrunTime or 0)+dt or 0
  local active=d.enabled and profile.fuelType~='diesel' and d.mode=='custom' and eligible and (d.continuous or memory.overrunTime<=d.cutDelay)
  local target=active and 1 or 0
  memory.decelWeight=(memory.decelWeight or 0)+(target-(memory.decelWeight or 0))*(1-math.exp(-dt/.08))
  -- A closed throttle still passes some air. This bounded fallback is only for
  -- extra overrun injection; it must never inflate the loaded-engine air estimate.
  local ref=model.properties(model.grades.regular)
  local air=profile.baseFlowLps*ref.density*ref.stoich*clamp(input.rpm/profile.maxRPM,0,1.5)*.035
  local grade=model.conversionKind(input.state)=='nitromethane' and model.grades.nitro90 or
    (model.conversionKind(input.state)=='methanol' and model.grades.m100 or model.grades.regular)
  local flow=air/model.properties(grade).stoich/fuel.density*d.fueling*memory.decelWeight
  if not eligible or d.mode=='original' or not d.enabled or profile.fuelType=='diesel' then flow=0;memory.decelWeight=0 end
  return flow,d.retard*memory.decelWeight,active,flow>0 and air or 0
end
function M.step(memory,fuel,baseLiters,extraLiters,response,running,dt)
  if dt<=0 then return memory end
  baseLiters=math.max(0,baseLiters);extraLiters=math.max(0,extraLiters)
  local supplied=(baseLiters+extraLiters)*fuel.density
  -- Later overrun ignition sends more of the extra charge into the exhaust.
  -- This is a bounded calibration response, not a crank-angle simulation.
  local extraExhaustShare=clamp(.15+(response.decelRetard or 0)*.035,.15,.85)
  local unburned=math.min(baseLiters,math.max(0,response.unburnedLiters or 0))
  local exhaust=(baseLiters-unburned)*fuel.density*(response.exhaustFraction or 0)+unburned*fuel.density+extraLiters*fuel.density*extraExhaustShare
  local inCylinder=supplied-exhaust-extraLiters*fuel.density*.15
  local loss=extraLiters*fuel.density*.15
  memory.deliveredKg=(memory.deliveredKg or 0)+supplied
  memory.inCylinderKg=(memory.inCylinderKg or 0)+inCylinder
  memory.exhaustSuppliedKg=(memory.exhaustSuppliedKg or 0)+exhaust
  memory.unburnedLossKg=(memory.unburnedLossKg or 0)+loss
  local reservoir=(memory.reservoirKg or 0)+exhaust
  local temperature=response.exhaustTemperature or 20
  local hot=clamp((temperature-220)/350,0,1)
  -- External entrainment and fuel-bound oxygen are approximate, bounded factors.
  local oxygen=clamp(.25+(response.lambda or 1)*.5+fuel.nitromethane*.25,0,1)
  if response.exhaustSimulation then
    response.cylinderKgPerSec=inCylinder/dt
    -- Fixed maximum integration step keeps physics/GFX batching equivalent.
    local count=math.max(1,math.ceil(dt/.005))
    local before=memory.exhaustBurnedJ or 0
    for _=1,count do exhaustModel.step(memory,fuel,exhaust/count,response,running,dt/count) end
    memory.burnW=((memory.exhaustBurnedJ or 0)-before)/dt
  else
    local released=reservoir*(1-math.exp(-dt/.18))
    local burned=running and released*hot*oxygen or 0
    memory.reservoirKg=math.max(0,reservoir-released)
    memory.exhaustBurnedKg=(memory.exhaustBurnedKg or 0)+burned
    memory.exhaustLostKg=(memory.exhaustLostKg or 0)+(released-burned)
    memory.burnW=burned/dt*fuel.energyPerL/fuel.density
  end
  -- Include ordinary paid delivery, not only custom overrun injection. Compare
  -- at the delivered charge's air/fuel ratio, so starvation and partial tank
  -- withdrawals cannot receive the requested (undelivered) cooling benefit.
  local baseMass=baseLiters*fuel.density
  local airMass=baseMass*fuel.stoich*math.max(.001,response.lambda or 1)
  local total,charge,wall=model.evaporativeCooling(fuel,baseMass,airMass,
    model.referenceLambda(response.load or 0),response.coldRunningSeverity)
  local extraCooling=extraLiters*fuel.density*fuel.latent*model.constants.coolingUtilization
  memory.evaporativeCoolingW=(total+extraCooling)/dt
  memory.chargeCoolingW=charge/dt
  memory.wallCoolingW=(wall+extraCooling)/dt
  memory.extraCylinderHeatW=extraLiters*fuel.energyPerL*math.max(0,1-extraExhaustShare-.15)*.10/dt
  memory.extraHeatW=extraLiters*fuel.energyPerL/dt*extraExhaustShare*hot*oxygen
  return memory
end
return M
