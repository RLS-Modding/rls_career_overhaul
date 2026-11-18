-- Native damage adapter. Never overwrite an engine condition snapshot or
-- reapply a thermal failure that the device already owns.
local M = {}
local model = require('common/rlsFuelModel')
local thermalFailures={'pistonRingsDamaged','headGasketBlown'}

function M.normalize(state)
  local old=model.clamp(state.damage or 0,0,1)
  local exposure=type(state.exposure)=='table' and state.exposure or {}
  state.exposure={knock=model.clamp(exposure.knock or 0,0,1),lean=model.clamp(exposure.lean or 0,0,1),
    legacy=math.max(model.clamp(exposure.legacy or 0,0,1),old)}
  -- Migrate old lasting damage to native condition impairment. Keep this floor
  -- across config-only rebuilds; repair explicitly clears it with exposure.
  state.legacyCondition=math.max(model.clamp(state.legacyCondition or 0,0,1),old)
  local saved=type(state.fuelFailures)=='table' and state.fuelFailures or {}
  state.fuelFailures={}
  for _,name in ipairs({'pistonRingsDamaged','headGasketBlown','lockedUp'}) do
    if saved[name]==true then state.fuelFailures[name]=true end
  end
  state.damage=nil;state.version=state.hardware and 5 or 4
  model.accumulateExposure(state,{},0)
  return state
end

function M.clearExposure(state)
  state.exposure={knock=0,lean=0,legacy=0};state.legacyCondition=0;state.fuelFailures={}
end

function M.apply(engine,state)
  local legacy=state.legacyCondition or 0
  if legacy>0 then
    -- Same types of persistent impairment used by native numeric condition
    -- restoration, applied as floors so existing damage can never be repaired.
    for field,target in pairs({damageDynamicFrictionCoef=1+legacy*.5,
      damageIdleAVReadErrorRangeCoef=1+legacy*29,fastIgnitionErrorChance=legacy*.4,slowIgnitionErrorChance=legacy*.4}) do
      if model.finite(engine[field]) then engine[field]=math.max(engine[field],target) end
    end
  end
  local thermals=engine.thermals
  if thermals and type(thermals.setPartConditionThermals)=='function' then
    local pending={}
    for _,name in ipairs(thermalFailures) do
      if state.fuelFailures[name] and thermals[name]==false then pending[name]=true end
    end
    if next(pending) then thermals.setPartConditionThermals(0,pending,nil) end
  end
  if state.fuelFailures.lockedUp and engine.isBroken==false and type(engine.lockUp)=='function' then engine:lockUp() end
end

-- Native setPartConditionThermals replays multiplicative failure effects.
-- Omit only failures already applied on this device, leaving unrelated saved
-- condition fields untouched. A new device still restores every saved failure.
function M.pendingCondition(engine,condition)
  if type(condition)~='table' or type(condition.thermals)~='table' or not engine.thermals then return condition end
  local out=model.copy(condition)
  for _,name in ipairs({'pistonRingsDamaged','headGasketBlown','connectingRodBearingsDamaged','engineBlockMelted','cylinderWallsMelted'}) do
    if engine.thermals[name]==true then out.thermals[name]=nil end
  end
  return out
end

function M.inspect(engine,response)
  local thermals=engine.thermals or {}
  local diagnoses={}
  for _,entry in ipairs({{'pistonRingsDamaged','Damaged piston rings'}, {'headGasketBlown','Blown head gasket'},
    {'connectingRodBearingsDamaged','Damaged rod bearings'}, {'engineBlockMelted','Severe engine block damage'},
    {'cylinderWallsMelted','Severe cylinder wall damage'}}) do
    if thermals[entry[1]]==true then diagnoses[#diagnoses+1]=entry[2] end
  end
  if engine.isBroken then diagnoses[#diagnoses+1]='Engine broken / locked up' end
  if (engine.fastIgnitionErrorChance or 0)>0.001 or (engine.slowIgnitionErrorChance or 0)>0.001 then diagnoses[#diagnoses+1]='Ignition irregularity' end
  if (engine.damageFrictionCoef or 1)>1.001 or (engine.damageDynamicFrictionCoef or 1)>1.001 then diagnoses[#diagnoses+1]='Mechanical friction damage' end
  local warning
  response=response or {}
  if response.soot~=nil and ((response.soot or 0)>.05 or (response.dieselThermalStress or 0)>.05) then
    warning='Excess diesel fueling is producing soot and can increase thermal stress. Raise target AFR (leaner) or reduce positive live AFR trim to use less fuel. Watch smoke and temperature; larger injectors or pumps do not provide more air.'
  elseif (response.knock or 0)>0.05 then
    if (response.nitromethane or 0)>.001 then
      warning='Harmful nitro combustion remains under load. Lift off and reduce ignition advance (lower degree values). Check the Nitro 90 blend and fuel-delivery capacity; gasoline octane guidance does not apply.'
    else
      warning='Knock remains under load. Lift off, reduce ignition advance (lower degree values), and reduce boost if fitted. Check fuel suitability. If the mixture is lean, lower target AFR (richer), but check injector/pump headroom before adding fuel.'
    end
  elseif (response.leanSeverity or 0)>0.05 then
    if (response.deliveryDuty or 0)>1 then
      warning='Dangerously lean: the '..(response.deliveryLimit or 'fuel system')..' is at its delivery limit. Lift off; fit more capacity or reduce boost/load. A richer target cannot deliver fuel beyond that limit.'
    else
      warning='Dangerously lean under load. Lift off and check that calibration matches the tank fuel. Lower target AFR (richer), or add positive live AFR trim, in small steps; compare target and actual AFR before increasing load.'
    end
  elseif (response.richSeverity or 0)>0.05 then
    warning='Excessively rich: poor running and plug-fouling risk. Check that calibration matches the tank fuel. Raise target AFR (leaner), or reduce positive live AFR trim, in small steps at the affected RPM/load; watch actual AFR and knock.'
  elseif (response.knockRetard or 0)>0.25 then
    warning='Knock protection is pulling timing. Reduce ignition advance (lower degree values), use suitable fuel, or reduce boost if fitted. If the high-load mixture is lean, lower target AFR (richer) with available fuel-delivery headroom.'
  end
  local supported=type(thermals.setPartConditionThermals)=='function' and type(engine.lockUp)=='function'
    and type(engine.isBroken)=='boolean' and type(thermals.pistonRingsDamaged)=='boolean' and type(thermals.headGasketBlown)=='boolean'
  return {diagnoses=diagnoses,warning=warning,limited=not supported,
    limitation=not supported and 'Native damage interfaces are incomplete; some fuel-induced failures cannot be applied to this engine.' or nil}
end
return M
