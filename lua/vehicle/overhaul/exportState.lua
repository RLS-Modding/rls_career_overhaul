-- Temporary export sessions preserve these runtime values in addition to Career's
-- detailed condition/deformation checkpoint. This data never enters a shared .pc.
local M = {}
local thermalKeys={'engineBlockTemperature','oilTemperature','coolantTemperature','cylinderHeadTemperature',
  'exhaustTemperature','cylinderWallTemperature','engineBlockTemperatureThermostat'}
local function finite(x) return type(x)=='number' and x==x and math.abs(x)<math.huge end
local function scalars(source,keys)
  local out={};for _,key in ipairs(keys) do if finite(source and source[key]) then out[key]=source[key] end end;return out
end
function M.capture()
  local state={version=1,tanks={},engines={},parts={},beams={},controls={},couplings=require('vehicle/overhaul/exportCouplings').capture()}
  state.controls.ignition=electrics.values.ignitionLevel
  state.controls.parkingbrake=electrics.values.parkingbrake
  for name,tank in pairs(energyStorage.getStorages() or {}) do
    if finite(tank.storedEnergy) then
      state.tanks[name]={energy=tank.storedEnergy,blend=scalars(tank.rlsFuelBlend,{'ethanol','methanol','nitromethane','aki'})}
    end
  end
  for name,engine in pairs(powertrain.getDevicesByCategory('engine') or {}) do
    if type(engine.name)=='string' then name=engine.name end
    state.engines[name]={outputAV1=engine.outputAV1,thermals=scalars(engine.thermals,thermalKeys)}
  end
  for path,condition in pairs(partCondition.getConditions() or {}) do
    state.parts[path]=scalars(condition,{'odometer','integrityValue','visualValue'})
  end
  for _,beam in pairs(v.data.beams or {}) do
    -- Wheel and hydraulic operating lengths legitimately differ during settling.
    if beam.wheelID==nil and beam.beamType~=3 and beam.beamType~=6 then
      state.beams[tostring(beam.cid)]={broken=obj:beamIsBroken(beam.cid),rest=obj:getBeamRestLength(beam.cid)}
    end
  end
  return state
end
function M.compare(expected,current)
  local differences={}
  local function difference(text) if #differences<12 then differences[#differences+1]=text end end
  for name,tank in pairs(expected.tanks or {}) do
    local actual=current.tanks[name]
    if not actual or math.abs(actual.energy-tank.energy)>math.max(1,math.abs(tank.energy)*1e-8) then difference('Tank energy: '..name) end
    for key,value in pairs(tank.blend or {}) do if not actual or not actual.blend or not finite(actual.blend[key]) or math.abs(value-actual.blend[key])>1e-7 then difference('Tank blend: '..name..'/'..key) end end
  end
  for path,part in pairs(expected.parts or {}) do
    local actual=current.parts[path]
    if not actual then difference('Missing part: '..path)
    else for key,value in pairs(part) do
      local tolerance=key=='odometer' and .002 or .000001
      if not finite(actual[key]) or math.abs(value-actual[key])>tolerance then difference('Part condition: '..path..'/'..key) end
    end end
  end
  for id,beam in pairs(expected.beams or {}) do
    local actual=current.beams[id]
    if not actual or actual.broken~=beam.broken or math.abs(actual.rest-beam.rest)>.0002 then difference('Beam damage: '..id) end
  end
  for name,engine in pairs(expected.engines or {}) do
    local actual=current.engines and current.engines[name]
    if not actual then difference('Missing engine: '..name)
    else
      if finite(engine.outputAV1) and (not finite(actual.outputAV1) or math.abs(engine.outputAV1-actual.outputAV1)>.01) then difference('Engine speed: '..name) end
      for key,value in pairs(engine.thermals or {}) do
        if not actual.thermals or not finite(actual.thermals[key]) or math.abs(value-actual.thermals[key])>.01 then difference('Engine temperature: '..name..'/'..key) end
      end
    end
  end
  -- Parking-brake input is consumed on the next graphics step, so the restored
  -- input event is authoritative here. Ignition updates synchronously.
  local ignition=expected.controls and expected.controls.ignition
  if finite(ignition) and (not current.controls or current.controls.ignition~=ignition) then difference('Ignition state') end
  return #differences==0,differences
end
function M.restore(state)
  if type(state)~='table' or state.version~=1 then return false,{'Missing return state'} end
  for name,saved in pairs(state.tanks or {}) do
    local tank=energyStorage.getStorage(name)
    if tank and finite(saved.energy) then
      tank.storedEnergy=saved.energy
      if finite(tank.energyCapacity) and tank.energyCapacity>0 then tank.remainingRatio=saved.energy/tank.energyCapacity end
      if finite(tank.energyDensity) and finite(tank.fuelLiquidDensity) and tank.energyDensity*tank.fuelLiquidDensity>0 then
        tank.remainingVolume=saved.energy/(tank.energyDensity*tank.fuelLiquidDensity)
      end
    end
  end
  for name,saved in pairs(state.engines or {}) do
    local engine=powertrain.getDevice(name)
    if engine then
      if finite(saved.outputAV1) then engine.outputAV1=saved.outputAV1 end
      for key,value in pairs(saved.thermals or {}) do if engine.thermals and finite(value) then engine.thermals[key]=value end end
    end
  end
  -- Career's normal damage loader restores the saved structure. Do not rewrite
  -- individual beam lengths again to chase tiny differences after it settles.
  local controls=state.controls or {}
  if finite(controls.ignition) then electrics.setIgnitionLevel(controls.ignition) end
  if finite(controls.parkingbrake) then input.event('parkingbrake',controls.parkingbrake,1) end
  -- Keep differences for diagnostics. They do not prevent a loaded Career from
  -- becoming playable, and we never repair parts to make the comparison pass.
  return M.compare(state,M.capture())
end
return M
