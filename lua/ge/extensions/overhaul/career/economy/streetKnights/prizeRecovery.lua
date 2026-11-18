-- The result lock owns the prize. Missing capture files cannot revoke that win.
local M={}
local partConditionCompatibility=require('overhaul/lib/parts/conditionCompatibility')
local mileageDefaults={minimumMileageMiles=50000,maximumMileageMiles=200000}
local function mileageBound(value) return type(value)=='number' and value>=0 and value<math.huge and value%1==0 end
local ok,mileageTuning=false,nil
if type(jsonReadFile)=='function' then ok,mileageTuning=pcall(jsonReadFile,'/gameplay/overhaul/streetKnights/prizeMileage.json') end
if not ok or type(mileageTuning)~='table' or not mileageBound(mileageTuning.minimumMileageMiles)
  or not mileageBound(mileageTuning.maximumMileageMiles) or mileageTuning.minimumMileageMiles>mileageTuning.maximumMileageMiles then
  mileageTuning=mileageDefaults
end
function M.rollMileageMeters(random)
  return random(mileageTuning.minimumMileageMiles,mileageTuning.maximumMileageMiles)*1609.344
end
local function copy(t) local r={} for k,v in pairs(t) do r[k]=type(v)=='table' and copy(v) or v end return r end
local function read(path,reader)
  if type(path)~='string' then return end
  local ok,value=pcall(reader,path)
  if ok and type(value)=='table' then return value end
end
function M.conditions(prize)
  -- Captures and the ledger are JSON, which stores gearbox wear gear numbers as text; stock gearboxes index by number.
  local conditions=partConditionCompatibility.sanitizeSynchroWearInConditions(copy(prize.partConditions or {}))
  if (prize.mileage or 0)>0 then
    for _,condition in pairs(conditions) do condition.odometer=prize.mileage end
  end
  return conditions
end
M.applyMileage=require('overhaul/lib/vehicles/mileage').apply
-- Race AI leaves the car in arcade and can hold a stale mode for its next disable, so consume that first.
-- Race controls restore their saved mode on unload, so hand them the player's mode.
function M.applyPlayerGearbox(vehicle,mode)
  if mode~='realistic' and mode~='arcade' then return end
  vehicle:queueLuaCommand(string.format([[
    if ai and ai.restoreSavedGearboxMode then ai.restoreSavedGearboxMode() end
    if overhaulStreetKnightsTraction and overhaulStreetKnightsTraction.handOver then overhaulStreetKnightsTraction.handOver(%q)
    elseif controller and controller.mainController then controller.mainController.setGearboxMode(%q) end
  ]],mode,mode))
end
-- Live AI re-selects arcade on every reset and reload, so a won car must not keep the race driver.
function M.releaseLeftoverAi(vehicle,mode)
  if mode~='realistic' and mode~='arcade' then mode='nil' else mode=string.format('%q',mode) end
  vehicle:queueLuaCommand(string.format([[
    if ai and ai.mode~='disabled' then
      extensions.unload('overhaulStreetKnightsRaceGuard');extensions.unload('overhaulStreetKnightsTraction')
      ai.setMode('disabled')
      local mode=%s
      if mode and controller and controller.mainController then controller.mainController.setGearboxMode(mode) end
    end
  ]],mode))
end
function M.resolve(pending,reader)
  local prize=copy(pending)
  local conditions=read(prize.conditionsPath,reader)
  local damage=read(prize.damagePath,reader)
  local hasConditions=conditions and next(conditions)~=nil
  local hasDamage=damage and damage.format=='rls_v1'
  prize.partConditions=hasConditions and conditions or (type(prize.partConditions)=='table' and prize.partConditions or {})
  if not hasDamage then prize.damagePath=nil end
  prize.recoveredFromIncompleteCapture=not (hasConditions and hasDamage) or nil
  prize.pending=nil
  return prize
end
return M
