local M = {}
local active, waiting, elapsed, attempts = false, 0, nil, 0
local savedMode, savedClutch, savedThrottle
local cranking
local stable = 0

local function release()
  if not elapsed then return end
  if electrics.values.ignitionLevel == 3 then electrics.setIgnitionLevel(2) end
  electrics.values.clutchOverride, electrics.values.throttleOverride = savedClutch, savedThrottle
  if savedMode then controller.mainController.setGearboxMode(savedMode) end
  savedMode, savedClutch, savedThrottle, elapsed = nil, nil, nil, nil
  cranking = nil
end

function M.start()
  if active or playerInfo and playerInfo.anyPlayerSeated then return false end
  active, waiting, attempts, stable = true, 0, 0, 0
  return true
end

function M.clear()
  release()
  active, waiting, attempts, stable = false, 0, 0, 0
end

function M.updateGFX(dt)
  if not active then return end
  if playerInfo and playerInfo.anyPlayerSeated then M.clear(); extensions.unload('overhaulMotorsportStartup'); return end
  if type(dt) ~= 'number' or dt <= 0 or dt ~= dt then return end
  dt = math.min(dt, .1)
  local engine = powertrain.getDevice('mainEngine')
  if not engine or engine.isDisabled or not controller.mainController then return end
  local e = electrics.values
  local running = e.engineRunning == 1 and (not engine.idleAV or not engine.outputAV1 or engine.outputAV1 >= engine.idleAV * .85)
  stable = running and stable + dt or 0
  if elapsed then
    elapsed = elapsed + dt
    if not cranking and elapsed >= .2 then electrics.setIgnitionLevel(3); cranking = true end
    if cranking and (engine.starterEngagedCoef == 0 or elapsed >= 1.4) and e.ignitionLevel == 3 then electrics.setIgnitionLevel(2) end
    if cranking and stable >= .2 and e.ignitionLevel == 2 or elapsed >= 3 then release(); waiting, stable = 0, 0 end
    return
  end
  if (e.ignitionLevel or 0) < 2 or obj:getVelocity():length() >= 1 or stable >= .5 then waiting = 0
  elseif not running then waiting = waiting + dt end
  if waiting < 1 or attempts >= 2 then return end
  savedMode = controller.mainController.gearboxBehavior
  savedClutch, savedThrottle = e.clutchOverride, e.throttleOverride
  controller.mainController.setGearboxMode('realistic')
  local gearbox = powertrain.getDevice('gearbox')
  if gearbox and (gearbox.type == 'manualGearbox' or gearbox.type == 'sequentialGearbox') then e.clutchOverride = 1 end
  e.throttleOverride = .05
  electrics.setIgnitionLevel(2)
  elapsed, attempts, stable = 0, attempts + 1, 0
end

function M.onPlayersChanged(seated) if seated then M.clear(); extensions.unload('overhaulMotorsportStartup') end end
function M.onReset() local running = active; M.clear(); if running then M.start() end end
M.onExtensionUnloaded = M.clear
return M
