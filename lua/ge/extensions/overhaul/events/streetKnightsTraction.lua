local M={}
M.dependencies={'gameplay_drag_core','overhaul_shell_patches'}
local prizeRecovery=require('overhaul/career/economy/streetKnights/prizeRecovery')
local stopTuning=require('overhaul/events/streetKnights/finishStop').tuning
local data,id
local PATCH='streetKnightsTraction'
local function send(code)
  local car=id and be:getObjectByID(id)
  if car then car:queueLuaCommand(code) end
end
local function finished(current)
  local racer=current and id and current.racers and current.racers[id]
  local stopPhase=racer and racer.phases and racer.phases[4]
  return stopPhase and stopPhase.completed
end
local function unload(park)
  -- Unloading drops the finish hold; park a stopped opponent the player is not in so it cannot roll away.
  -- The 'stop' AI mode, as at race cleanup, lets getting in release the parking brake (releaseLeftoverAi).
  if park and finished(data) and be:getPlayerVehicleID(0)~=id then send("if obj:getVelocity():length()<"..stopTuning.stoppedSpeedMps.." then ai.setMode('stop');input.event('parkingbrake',1,1) end") end
  send("extensions.unload('overhaulStreetKnightsTraction')")
  overhaul_shell_patches.unregister(PATCH)
  data=nil;id=nil
end
-- An early clear (drag activity cleared or replaced) parks a stopped opponent.
function M.clear() unload(true) end
-- The native driver's own cleanup parks the opponents it keeps and leaves cars it hands back (to a meet) alone.
function M.release() unload(false) end
function M.onDragRacersSetup(current)
  M.clear()
  if not current or current.id~='streetKnights' or current.context~='activity' then return end
  for vehicleId,racer in pairs(current.racers or {})do
    if not racer.isPlayable then
      if id then id=nil;return end
      id=vehicleId
    end
  end
  if not id then return end
  data=current
  send("extensions.load('overhaulStreetKnightsTraction');overhaulStreetKnightsTraction.configure();overhaulStreetKnightsTraction.setStopTuning("..serialize(stopTuning)..")")
  -- Reloaded after the finish: resume the finish hold so a car still braking is not left rolling.
  if finished(current) then send("overhaulStreetKnightsTraction.applyCooldown(true)") end
  local function wrap(command,racing)
    return function(original)
      return function(phase,racer,dt)
        local result=original(phase,racer,dt)
        if data==current and gameplay_drag_core.getData()==data and racer.vehId==id and not racer.isPlayable
          and phase.started and (not racing or (not racer.isFinished and not racer.isDisqualified)) then send(racing and ('overhaulStreetKnightsTraction.apply('..tostring(racer._aiThrottle or 1)..')') or command) end
        return result
      end
    end
  end
  overhaul_shell_patches.registerFields(PATCH,function()return rawget(_G,'gameplay_drag_phaseHandlers')end,{
    countdown=wrap('overhaulStreetKnightsTraction.prepare()'),
    race=wrap(nil,true),
    stop=wrap('overhaulStreetKnightsTraction.applyCooldown()'),
  })
end
function M.onUpdate() if data and gameplay_drag_core.getData()~=data then M.clear() end end
function M.onExtensionLoaded()
  local current=gameplay_drag_core.getData()
  if current and current.isStarted then M.onDragRacersSetup(current) end
end
local function releaseWonCar(vehicleId)
  local inventory=rawget(_G,'overhaul_career_garage_inventory')
  local inventoryId=inventory and inventory.getInventoryIdFromVehicleId(vehicleId)
  local record=inventoryId and inventory.getVehicles()[inventoryId]
  local car=record and (record.streetKnightsTransaction or record.streetChallengesTransaction) and be:getObjectByID(vehicleId)
  if car then prizeRecovery.releaseLeftoverAi(car,settings.getValue('defaultGearboxBehavior')) end
end
function M.onVehicleSwitched(_,newId)
  if newId~=id then releaseWonCar(newId);return end
  local owned=data and gameplay_drag_core.getData()==data
  send("ai.setMode('disabled')");M.clear()
  if owned then gameplay_drag_core.clear({hooks=false,data=true,context=true,extensions=true,ui=true,treeLightStaging=true}) end
end
M.onDragClear=M.clear
M.onClientEndMission=M.clear
M.onExtensionUnloaded=M.clear
return M
