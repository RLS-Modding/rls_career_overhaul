-- Explicit ownership of added combustion effects. Stored maps are not consent.
-- The pure fuel model also serves previews, so the boundary lives in the runtime.
local M={}
local model=require('common/rlsFuelModel')
local fields={'mixture','timing','boost','boostCut','decel','nitrous','hardware','conversion'}
function M.normalize(state)
  local previous=state.control
  local control={version=1}
  for _,field in ipairs(fields) do control[field]=type(previous)=='table' and previous.version==1 and previous[field]==true or false end
  if type(previous)=='table' and previous.version==1 and previous.boostCut==nil then
    control.boostCut=previous.boost==true and state.tune and state.tune.boostCut~=nil or false
  end
  control.liveMixtureTrim=type(previous)=='table' and previous.version==1 and previous.liveMixtureTrim==true or false
  if not previous then
    -- Preserve conversions already recorded in older fuel-system saves.
    -- Old maps, revision numbers and damage alone do not prove activation.
    control.conversion=state.conversion==true
    local h=state.hardware or {}
    control.hardware=(h.injector~='equipped' and h.injector~='legacy' and h.ownedInjectors and h.ownedInjectors[h.injector]==true)
      or (h.pump~='equipped' and h.pump~='legacy' and h.ownedPumps and h.ownedPumps[h.pump]==true) or false
  end
  local boost=state.tune and state.tune.boost
  if boost and boost.enabled==nil then boost.enabled=control.boost and boost.mode~='original' or false end
  state.control=control
  return control
end
local function defaultTune(profile,state)
  if state.control.conversion and state.conversion and model.conversionKind(state)=='nitromethane' then
    return model.convert(model.newEngineState(profile),profile,'nitromethane').tune
  end
  return model.newTune(profile)
end
function M.tuneChanges(profile,state,tune)
  local baseline=defaultTune(profile,state)
  local changed={nitrous=tune.nitrous~=nil and tune.nitrous.mode~='original',mixture=math.abs(tune.afrTrim or 0)>1e-8,timing=false,
    boost=model.boostEnabled(tune),boostCut=tune.boostCut~=nil,
    decel=model.decel(tune).mode=='custom' and model.decel(tune).enabled}
  for y,load in ipairs(tune.load) do for x,rpm in ipairs(tune.rpm) do
    if math.abs(tune.lambda[y][x]-model.sample(baseline,'lambda',rpm,load))>1e-8 then changed.mixture=true end
    if math.abs(tune.timing[y][x])>1e-8 then changed.timing=true end
  end end
  return changed
end
function M.appliedTune(state,profile)
  -- Submitted tunes must opt in; legacy migration is only for saved state.
  if state.tune.boost and state.tune.boost.enabled==nil then state.tune.boost.enabled=false end
  local control=M.normalize(state)
  control.liveMixtureTrim=false
  for field,changed in pairs(M.tuneChanges(profile,state,state.tune)) do control[field]=changed end
end
function M.effective(state,profile)
  M.normalize(state)
  local out=model.copy(state)
  local baseline=defaultTune(profile,state)
  local t,c=out.tune,state.control
  if not c.mixture then
    if not c.liveMixtureTrim then t.afrTrim=0 end
    for y,load in ipairs(t.load) do for x,rpm in ipairs(t.rpm) do t.lambda[y][x]=model.sample(baseline,'lambda',rpm,load) end end
  end
  if not c.timing then for _,row in ipairs(t.timing) do for x in ipairs(row) do row[x]=0 end end end
  if not c.boost or not model.boostEnabled(t) then t.boost=nil end
  if not c.boostCut then t.boostCut=nil end
  if not c.nitrous then t.nitrous=nil end
  if not c.decel then t.decel=nil end
  if not c.conversion then out.conversion=false;out.conversionKind='gasoline' end
  if not c.hardware then
    out.hardware.injector='equipped';out.hardware.pump='equipped'
  end
  local i,p=model.hardware.capacity(out,profile);out.deliveryLps=math.min(i,p)
  return out
end
function M.status(state,profile,blend)
  local control=state.control
  local changes=M.tuneChanges(profile,state,state.tune)
  local reasons={}
  for _,field in ipairs({'mixture','timing','boost','boostCut','decel','nitrous'}) do
    if (control[field] or (field=='mixture' and control.liveMixtureTrim and math.abs(state.tune.afrTrim or 0)>1e-8)) and changes[field] then reasons[#reasons+1]=field end
  end
  local h=state.hardware
  if control.hardware and (h.injector~='equipped' or h.pump~='equipped') then reasons[#reasons+1]='hardware' end
  if control.conversion and state.conversion then reasons[#reasons+1]='conversion' end
  if blend and not blend.diesel and ((blend.ethanol or 0)>.15000001 or (blend.methanol or 0)>.001 or (blend.nitromethane or 0)>.001) then reasons[#reasons+1]='fuel' end
  if profile.nativeBoostDeviation then reasons[#reasons+1]='boost adjustment' end
  local dormant=false
  for field,changed in pairs(changes) do
    if field=='mixture' and control.liveMixtureTrim then
      changed=false
      local baseline=defaultTune(profile,state)
      for y,load in ipairs(state.tune.load) do for x,rpm in ipairs(state.tune.rpm) do
        if math.abs(state.tune.lambda[y][x]-model.sample(baseline,'lambda',rpm,load))>1e-8 then changed=true end
      end end
    end
    if changed and not control[field] then dormant=true end
  end
  return {mode=#reasons==0 and 'native' or 'weepy',reasons=reasons,dormantCalibration=dormant}
end
return M
