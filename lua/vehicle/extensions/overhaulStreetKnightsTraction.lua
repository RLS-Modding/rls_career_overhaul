local M={}
local saved,prepared,savedClutch,savedBrake,cooling,brakeCommand,savedGearboxMode,holding
local names={'understeerThrottleControl','oversteerThrottleControl','throttleTcs'}
local finishHold,frozen
local stoppedSpeedMps,brakeRampPerSec -- the race's stop tuning, sent with every set-up (setStopTuning)
function M.configure()
  saved={};prepared=false;cooling=false;brakeCommand=0;holding=false;savedGearboxMode=nil
  savedClutch=electrics.values.clutchOverride;savedBrake=electrics.values.brakeOverride
  finishHold=false;frozen=false
  local parameters=ai.getParameters()
  for _,name in ipairs(names) do saved[name]=parameters[name] or 'on' end
  -- Arcade mode runs ABS on every wheel, including configs with no ABS part.
  wheels.setABSBehavior('arcade')
end
-- The race sends its stop tuning (gameplay/overhaul/streetKnights/finishStop.json) right after configure.
function M.setStopTuning(tuning) stoppedSpeedMps=tuning.stoppedSpeedMps;brakeRampPerSec=tuning.brakeRampPerSec end
function M.prepare()
  if prepared then return end
  ai.setParameters({understeerThrottleControl='on',oversteerThrottleControl='on',throttleTcs='on'})
  prepared=true
end
function M.apply(native)
  M.prepare()
  -- Use the native pitch request rather than the last traction-corrected output.
  native=tonumber(native) or electrics.values.throttleOverride or 1
  electrics.values.throttleOverride=math.min(native,clamp(input.throttle or 0,0,1))
end
function M.applyCooldown(hold)
  local main=controller.mainController
  if hold and main and main.setGearboxMode and main.gearboxBehavior then
    -- Arcade braking becomes reverse throttle once the opponent stops.
    if not savedGearboxMode then savedGearboxMode=main.gearboxBehavior end
    if main.gearboxBehavior~='realistic' then main.setGearboxMode('realistic') end
    holding=true
  end
  cooling=true;if hold then finishHold=true end
  local gearbox=powertrain.getDevice('gearbox')
  -- Drag manuals can lock the rear tires through engine braking during automatic downshifts.
  if gearbox and (gearbox.type=='manualGearbox' or gearbox.type=='sequentialGearbox') then electrics.values.clutchOverride=1 end
end
-- A won car keeps the cooldown until these controls unload; the unload then applies the player's mode.
function M.handOver(mode)
  savedGearboxMode=mode
  local main=controller.mainController
  if not (main and main.setGearboxMode) then return end
  if not holding then main.setGearboxMode(mode)
  elseif main.gearboxBehavior~='realistic' then main.setGearboxMode('realistic') end
end
function M.updateGFX(dt)
  if not cooling then return end
  -- The finish hold has no AI brake input, so it ramps to full braking under the forced ABS.
  local desired=finishHold and 1 or clamp(input.brake or 0,0,1)
  brakeCommand=math.min(desired,brakeCommand+dt*brakeRampPerSec)
  -- Below the stopped speed the freeze's gearbox lock can no longer skid the driven wheels.
  local slow=obj:getVelocity():length()<stoppedSpeedMps
  electrics.values.brakeOverride=slow and 1 or brakeCommand
  -- Freezing also locks the gearbox; at speed that would lock the driven wheels and spin the car.
  if finishHold and slow and not frozen then frozen=true;controller.setFreeze(1) end
end
function M.onExtensionUnloaded()
  if saved then ai.setParameters(saved);wheels.resetABSBehavior() end
  -- Letting go (the player gets in, or race cleanup) undoes the hold's freeze and its gearbox lock.
  if frozen then controller.setFreeze(0);frozen=false end
  local main=controller.mainController
  if savedGearboxMode and main and main.setGearboxMode then main.setGearboxMode(savedGearboxMode) end
  electrics.values.brakeOverride=savedBrake;electrics.values.clutchOverride=savedClutch;electrics.values.throttleOverride=nil
  saved=nil;prepared=false;cooling=false;savedGearboxMode=nil;holding=false
end
return M
