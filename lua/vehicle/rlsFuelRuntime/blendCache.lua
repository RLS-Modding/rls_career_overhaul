-- Private chemistry cache. Tank volume matters only when it crosses empty;
-- native withdrawal ratios, rather than remaining litres, determine the mix.
local M={}
local emptyNames={}
local function nonempty(tank)
  return tank and tank.storedEnergy/math.max(1,tank.fuelLiquidDensity*tank.energyDensity)>0 or false
end
local function matches(record,key,name,engine,tanks)
  local tank=tanks[name]
  local blend=tank and tank.rlsFuelBlend
  if not record or record.key~=key or record.name~=name or record.tank~=tank or record.nonempty~=nonempty(tank)
    or record.ratio~=(engine.energyStorageRatios and engine.energyStorageRatios[name] or 1) then return false end
  return record.diesel==(blend and blend.diesel) and record.ethanol==(blend and blend.ethanol)
    and record.methanol==(blend and blend.methanol) and record.nitromethane==(blend and blend.nitromethane)
    and record.aki==(blend and blend.aki) and record.density==(blend and blend.density)
    and record.energyPerL==(blend and blend.energyPerL)
end
local function capture(record,key,name,engine,tanks)
  local tank=tanks[name]
  local blend=tank and tank.rlsFuelBlend
  record=record or {}
  record.key,record.name,record.tank,record.nonempty=key,name,tank,nonempty(tank)
  record.ratio=engine.energyStorageRatios and engine.energyStorageRatios[name] or 1
  record.diesel=blend and blend.diesel;record.ethanol=blend and blend.ethanol
  record.methanol=blend and blend.methanol;record.nitromethane=blend and blend.nitromethane
  record.aki=blend and blend.aki;record.density=blend and blend.density;record.energyPerL=blend and blend.energyPerL
  return record
end
function M.get(cache,engine,tanks,computeBlend,model)
  local names=engine.registeredEnergyStorages or engine.energyStorage
  local count=0
  local unchanged=cache.blend~=nil and cache.energyType==engine.requiredEnergyType
  if type(names)=='string' then
    count=1;unchanged=matches(cache.inputs[1],1,names,engine,tanks) and unchanged
  else
    for key,name in pairs(names or emptyNames) do
      count=count+1;unchanged=matches(cache.inputs[count],key,name,engine,tanks) and unchanged
    end
  end
  if unchanged and count==#cache.inputs then return cache.blend,cache.chemistry end
  cache.blend=computeBlend(engine)
  cache.chemistry=model.responseChemistry(cache.blend)
  cache.energyType=engine.requiredEnergyType
  local index=0
  if type(names)=='string' then cache.inputs[1]=capture(cache.inputs[1],1,names,engine,tanks);index=1
  else
    for key,name in pairs(names or emptyNames) do
      index=index+1;cache.inputs[index]=capture(cache.inputs[index],key,name,engine,tanks)
    end
  end
  for i=#cache.inputs,index+1,-1 do cache.inputs[i]=nil end
  return cache.blend,cache.chemistry
end
return M
