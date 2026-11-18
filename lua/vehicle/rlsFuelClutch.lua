-- Publish a healthy fuel-aware base. Authored capacities and
-- native wear/damage/thermal multipliers remain independent of this adapter.
-- Torque converters get the same treatment for their automatic converterTorque.
local M={}
local model=require('common/rlsFuelModel')
local capacity=require('vehicle/overhaul/powertrainCapacity')
local engines=setmetatable({},{__mode='k'})
-- Native converterTorque per converter, captured once before any resize.
-- Nothing else derates it, so it needs no shared registry.
local converters=setmetatable({},{__mode='k'})

-- The JBeam field holding each device type's capacity. Native code infers it
-- from the engine's original torque curve when the field is absent.
local capacityField={frictionClutch='lockTorque',dctGearbox='lockTorque',torqueConverter='converterTorque'}

local function automatic(device)
  local field=capacityField[device.type]
  if not field then return false end
  local data=v and v.data
  if type(data)~='table' or type(data.powertrain)~='table' then return false end
  -- Native powertrain merges the processed row with the named device section.
  -- Either location may supply an explicit capacity; runtime lockTorque cannot
  -- distinguish one, because native validate has already filled its default.
  local section=data[device.name]
  if type(section)=='table' and section[field]~=nil then return false end
  for _,row in pairs(data.powertrain) do
    if type(row)=='table' and row.name==device.name then return row[field]==nil end
  end
  return false
end

local function releaseDevice(device)
  if device.type=='torqueConverter' then
    if converters[device] then device.converterTorque=converters[device] end
  else
    capacity.releaseLockTorqueBase(device,M)
  end
end

function M.release(engine)
  local record=engines[engine]
  if not record then return end
  for device,original in pairs(record.devices) do
    releaseDevice(device)
    if original.maxExpectedInputTorque then
      device.maxExpectedInputTorque=original.maxExpectedInputTorque
      device.invMaxExpectedInputTorque=original.invMaxExpectedInputTorque
      device.maxExpectedPower=original.maxExpectedPower
      device.invMaxExpectedPower=original.invMaxExpectedPower
    end
  end
  engines[engine]=nil
end

-- Parts callbacks cover in-place edits to a native children table or JBeam row.
function M.invalidate(engine)
  local record=engines[engine]
  if record then record.dirty=true end
end

local function torqueCoefs(device)
  if type(device)~='table' or not device.isExisting or type(device.getTorqueCoefs)~='function' then return nil end
  local ok,coefs=pcall(device.getTorqueCoefs)
  return ok and type(coefs)=='table' and coefs or nil
end

local function nativeBoostLimit(turbo)
  -- Native init copies JBeam first; copying can reorder sparse table keys.
  turbo=deepcopy(turbo)
  local starts,limits={},{}
  local startFallback,limitFallback,rangeFallback=0,1,1
  local pascalsPerPSI=model.constants.pascalsPerPSI
  -- Native fallbacks are the last iterated values, despite their max-prefixed
  -- names. Normalize the two tables separately so missing gears match native.
  if type(turbo.wastegateStart)=='table' then
    for gear,start in pairs(turbo.wastegateStart) do starts[gear]=start*pascalsPerPSI;startFallback=starts[gear] end
  else
    starts[1]=(turbo.wastegateStart or 0)*pascalsPerPSI;startFallback=starts[1]
  end
  if type(turbo.wastegateLimit)=='table' then
    for gear,limit in pairs(turbo.wastegateLimit) do limits[gear]=limit*pascalsPerPSI;limitFallback=limits[gear] end
  elseif type(turbo.wastegateLimit)=='number' then
    limits[1]=turbo.wastegateLimit*pascalsPerPSI;limitFallback=limits[1]
  else
    for gear,start in pairs(starts) do limits[gear]=start+.01*pascalsPerPSI;limitFallback=limits[gear] end
  end
  for gear,start in pairs(starts) do rangeFallback=(limits[gear] or limitFallback)-start end
  return (startFallback+rangeFallback*.5)/pascalsPerPSI
end

-- Native turbo torque previews ignore runtime wastegate offsets. Rebuild the
-- same full-load hardware estimate with the installed map's pressure ceiling.
local function turboPreview(engine,state)
  if not model.boostEnabled(state.tune) then return nil end
  local data=v and v.data
  local engineData=data and data[engine.name]
  local turbo=data and data[engineData and engineData.turbocharger or 'turbocharger']
  if type(turbo)~='table' or type(turbo.engineDef)~='table' or type(turbo.pressurePSI)~='table' or not createCurve then return nil end
  local efficiency,exhaust,maximumAV={},{},1
  for _,point in ipairs(turbo.engineDef) do
    efficiency[#efficiency+1]={point[1],point[2]}
    exhaust[#exhaust+1]={point[1],math.min(point[3],1)}
  end
  for _,point in ipairs(turbo.pressurePSI) do maximumAV=math.max(maximumAV,point[1]*.104719755) end
  local pressure=createCurve(turbo.pressurePSI,true)
  efficiency,exhaust=createCurve(efficiency),createCurve(exhaust)
  return function(rpm,target)
    local av=math.sqrt(math.max((.9*rpm/engine.maxRPM*(exhaust[rpm] or 1)*(turbo.maxExhaustPower or 1)-(turbo.frictionCoef or .01)),0)/(turbo.backPressureCoef or .0005))
    local turboRPM=math.floor(math.min(av,maximumAV)*9.549296596425384)
    local psi=math.min(pressure[turboRPM] or 0,target)
    return 1+.0000087*psi*model.constants.pascalsPerPSI*(efficiency[rpm] or 0),psi
  end,nativeBoostLimit(turbo)
end

local function peakTorque(engine,profile,state,blend)
  local native=engine.torqueData
  local curve=native and native.curves and native.curves[native.finalCurveName or 1]
  curve=curve and curve.torque
  if type(curve)~='table' or type(engine.torqueCurve)~='table' or not model.finite(native.maxTorque) then return nil end
  local turbo,supercharger=torqueCoefs(engine.turbocharger),torqueCoefs(engine.supercharger)
  local preview,nativeLimit
  if turbo then preview,nativeLimit=turboPreview(engine,state) end
  local efficiency=engine.invBurnEfficiencyTable and engine.invBurnEfficiencyTable[100] or 1/.30
  local pressure=profile.factoryBoostPsi and profile.factoryBoostPsi+(profile.wastegateHalfRangePsi or 0) or profile.factorySuperchargerPsi
  local boost=pressure and 1+pressure*model.constants.pascalsPerPSI/model.constants.referenceAtmospherePa or profile.referenceBoostRatio or 1
  local fuel=model.properties(blend)
  local samples={}
  local function sample(rpm)
    if model.finite(rpm) then rpm=math.floor(rpm);if rpm>=profile.idleRPM and rpm<profile.maxRPM then samples[rpm]=true end end
  end
  -- Scan map knots and native extrema, then refine each coarse local peak.
  -- Sizing is cached per calibration/blend, never changed with pedal position.
  for _,rpm in ipairs(state.tune.rpm) do sample(rpm) end
  sample((native.maxTorqueRPM or 1)-1);sample(profile.maxRPM-1)
  for rpm=profile.idleRPM,profile.maxRPM,25 do sample(rpm) end
  for index,torque in pairs(curve) do
    if type(index)=='number' and model.finite(torque) and torque>(curve[index-1] or torque) and torque>=(curve[index+1] or torque) then sample(index-1) end
  end
  local peak=native.maxTorque
  local function evaluate(rpm)
    local best=0
    local gross=engine.torqueCurve[rpm]
    local net=curve[rpm+1]
    if model.finite(gross) and model.finite(net) then
      local nativeGross=gross*(turbo and (turbo[rpm] or 0) or 1)*(supercharger and (supercharger[rpm] or 0) or 1)
      -- Live turbo coefficients include wear/damage, whereas torqueData is a
      -- rebuild snapshot. Subtract the same healthy estimate we add below.
      if preview then nativeGross=gross*preview(rpm-1,nativeLimit)*(supercharger and (supercharger[rpm] or 0) or 1) end
      local gears=preview and state.tune.boost.gears or {1}
      local seen={}
      for _,gear in ipairs(gears) do
        local target=preview and model.boostTarget(state.tune,rpm,gear)
        local coefficient,psi
        -- Native getTorqueCoefs writes at RPM+1, and getTorqueData reads at RPM.
        if target then coefficient,psi=preview(rpm-1,target) end
        local tunedGross=coefficient and gross*coefficient*(supercharger and (supercharger[rpm] or 0) or 1) or nativeGross
        local ratio=psi and 1+psi*model.constants.pascalsPerPSI/model.constants.referenceAtmospherePa or boost
        local pressureKey=psi or boost
        if not seen[pressureKey] then
          seen[pressureKey]=true
          local flow=math.max(0,tunedGross*rpm*.104719755*efficiency)/(profile.referenceEnergyPerL or model.constants.referenceEnergyPerL)
          local response=model.response(profile,state,blend,rpm,1,90,ratio,flow)
          local air=response.flowLps*fuel.density*fuel.stoich*response.lambda
          local cooling=air>0 and model.clamp(response.coolingW/(air*model.constants.airSpecificHeat),0,model.constants.maximumChargeCoolingC) or 0
          local gain=response.torque*(1+cooling/model.constants.referenceChargeKelvin)
          -- Friction and additive nitrous remain in the native net curve.
          best=math.max(best,net+tunedGross*gain-nativeGross)
        end
      end
    end
    peak=math.max(peak,best)
    return best
  end
  local ordered,values={},{}
  for rpm in pairs(samples) do ordered[#ordered+1]=rpm end
  table.sort(ordered)
  for index,rpm in ipairs(ordered) do values[index]=evaluate(rpm) end
  for index,rpm in ipairs(ordered) do
    local value=values[index]
    -- Rounding on a flat plateau must not turn every sample into a new peak.
    local tolerance=math.max(1,math.abs(value))*1e-7
    if value>(values[index-1] or -math.huge)+tolerance and value>=(values[index+1] or -math.huge)-tolerance then
      for fineRPM=math.max(profile.idleRPM,rpm-25),math.min(profile.maxRPM-1,rpm+25) do
        if not samples[fineRPM] then evaluate(fineRPM);samples[fineRPM]=true end
      end
    end
  end
  return peak
end

function M.sync(engine,profile,state,blend,active)
  if not active then M.release(engine);return end
  local native=engine.torqueData
  if type(native)~='table' or not model.finite(native.maxTorque) or native.maxTorque<=0 then M.release(engine);return end
  local record=engines[engine]
  local data=v and v.data
  local source=data and data.powertrain
  -- Compare scalar blend fields: equivalent freshly returned blend tables need
  -- no allocation, curve calculation or child scan on ordinary graphics frames.
  if record and not record.dirty and record.state==state and record.profile==profile and record.native==native
    and record.revision==state.revision and record.nativeMaxTorque==native.maxTorque and record.children==engine.children and record.data==data and record.source==source
    and record.diesel==blend.diesel and record.ethanol==blend.ethanol and record.methanol==blend.methanol
    and record.nitromethane==blend.nitromethane and record.aki==blend.aki then return end
  -- Restore before replacing the record; no scaled value becomes a new base.
  M.release(engine)
  -- Keep negative results too, until calibration/blend/devices change.
  record={state=state,revision=state.revision,profile=profile,native=native,nativeMaxTorque=native.maxTorque,children=engine.children,data=data,source=source,
    diesel=blend.diesel,ethanol=blend.ethanol,methanol=blend.methanol,nitromethane=blend.nitromethane,aki=blend.aki,devices={}}
  engines[engine]=record
  local peak
  for _,device in pairs(engine.children or {}) do
    local field=capacityField[device.type]
    local current=field and device[field]
    if automatic(device) and model.finite(current) and current>0 then
      peak=peak or peakTorque(engine,profile,state,blend)
      if not peak then return end
      -- Preserve the native inertia reserve; it is not a fuel torque gain.
      local gain=1.25*math.max(0,peak-native.maxTorque)
      if field=='converterTorque' then
        converters[device]=converters[device] or current
        device.converterTorque=converters[device]+gain
      else
        capacity.setLockTorqueBase(device,M,capacity.originalLockTorque(device)+gain)
      end
      record.devices[device]={maxExpectedInputTorque=device.maxExpectedInputTorque,invMaxExpectedInputTorque=device.invMaxExpectedInputTorque,
        maxExpectedPower=device.maxExpectedPower,invMaxExpectedPower=device.invMaxExpectedPower}
      if device.type=='dctGearbox' and model.finite(device.maxExpectedInputTorque) then
        device.maxExpectedInputTorque=math.max(device.maxExpectedInputTorque,peak)
        device.invMaxExpectedInputTorque=1/device.maxExpectedInputTorque
        if model.finite(engine.maxAV) then
          device.maxExpectedPower=engine.maxAV*device.maxExpectedInputTorque
          device.invMaxExpectedPower=1/device.maxExpectedPower
        end
      end
    end
  end
end

return M
