local M={}
M.dependencies={'overhaul_events_streetKnightsVenues','gameplay_drag_core','overhaul_events_streetKnightsTraction','overhaul_events_utils'}
local rules=require('overhaul/career/economy/streetKnights/rules')
local prizeRecovery=require('overhaul/career/economy/streetKnights/prizeRecovery')
local native=require('overhaul/events/streetKnights/nativeDriver').create()
local obstructions=require('overhaul/events/streetKnights/obstructions')
local race,aiId,spawnAge,countdown,elapsed,lastPlayer,lastAI,finished,cleanupAt
local staged=false
local redArmed=false
local ready=false
local laneCheck,blocker,blockCheckAt,blockPromptAt
local lastPlayerSide,lastAISide
local pendingPrize,captureAge,captureAttempts,pendingOutcome,outcomeAge,prizeWait
-- A won car is handed over once the race has braked it to a stop (or after the wait, if it never settles).
local stopTuning=require('overhaul/events/streetKnights/finishStop').tuning
local trafficSuppressed=false
local trafficRestoreAt,trafficRamp
local trafficStep=1
local function restoreTraffic()
  if not trafficSuppressed then return end
  overhaul_events_utils.restoreTrafficAmount()
  trafficSuppressed=false;trafficRestoreAt=nil;trafficRamp=nil
end
local function suppressTraffic()
  trafficRestoreAt=nil -- A new commitment cancels the previous race's delayed return.
  if trafficSuppressed then
    if trafficRamp then trafficRamp=nil;gameplay_traffic.setActiveAmount(0) end
    return
  end
  trafficSuppressed=true
  overhaul_events_utils.saveAndSetTrafficAmount(0)
end
local meetHold=false
function M.holdTraffic(on)
  if on then
    meetHold=true;suppressTraffic()
    local vars=gameplay_traffic and gameplay_traffic.getTrafficVars and gameplay_traffic.getTrafficVars()
    if vars and vars.activeAmount~=0 then gameplay_traffic.setActiveAmount(0) end
  elseif meetHold then
    meetHold=false
    if (not race or finished) and trafficSuppressed and not trafficRestoreAt and not trafficRamp then trafficRestoreAt=10 end
  end
end
local function updateTraffic(dtSim)
  if trafficRestoreAt then
    trafficRestoreAt=trafficRestoreAt-dtSim
    if trafficRestoreAt<=0 then trafficRestoreAt=nil;trafficRamp={amount=0,wait=0} end
  end
  if not trafficRamp then return end
  trafficRamp.wait=trafficRamp.wait-dtSim
  if trafficRamp.wait>0 then return end
  trafficRamp.wait=trafficStep;trafficRamp.amount=trafficRamp.amount+1
  if not gameplay_traffic or trafficRamp.amount>=gameplay_traffic.getNumOfTraffic() then restoreTraffic()
  else gameplay_traffic.setActiveAmount(trafficRamp.amount) end
end
local function controller()
  return race and race.controller=='overhaul_career_economy_streetChallenges' and overhaul_career_economy_streetChallenges or overhaul_career_economy_streetKnights
end
function M.systemFault(code,detail) return controller().systemFault(code,detail) end
local function send(id,code) local veh=be:getObjectByID(id) if veh then veh:queueLuaCommand(code) end end
local function tree(lights)
  if overhaul_events_streetKnightsMeet and overhaul_events_streetKnightsMeet.tree then overhaul_events_streetKnightsMeet.tree(lights) end
end
local function stageBulbs(front,inLane)
  return {prestage=inLane and front>=-0.8 and front<=0.2,stage=inLane and front>=-0.15 and front<=0.2}
end
local function phase(p)
  race.phase=p;controller().setPhase(p)
  guihooks.trigger('StreetKnightsHud',{challenge=race.controller=='overhaul_career_economy_streetChallenges',phase=p,stake=(race.kind=='boss' or race.kind=='pink') and 'Your car' or '$'..race.amount})
end
local stageGuide
local function hideStageGuide()
  if stageGuide then stageGuide:clearMarkers();stageGuide=nil end
end
local function drawStageGuide(v,front,valid,dtReal,dtSim)
  if math.abs(front)>25 or not settings.getValue('dragAssistStageGuideVisualizer') then hideStageGuide();return end
  if not stageGuide then
    stageGuide=require('scenario/race_marker').createRaceMarker(true,'dragStagePlane')
    stageGuide:setMode('default')
  end
  local f,r=overhaul_events_streetKnightsVenues.axes(v)
  local side=(v.aiSide=='right' and -1 or 1)*v.laneWidth/2
  stageGuide:setPlane(vec3(overhaul_events_streetKnightsVenues.position(v,0,side)),vec3(r),vec3(0,0,1),v.laneWidth/2-0.2,0.15)
  stageGuide.normal=vec3(f):normalized()
  stageGuide.distanceToCar=front;stageGuide.isValidStage=valid
  stageGuide:update(dtReal,dtSim)
end
function M.frontWheels(veh,v)
  local best=-math.huge;local pos=veh:getPosition()
  for i=0,veh:getWheelCount()-1 do
    local nodes=veh:getWheelAxisNodes(i)
    if nodes and nodes[1] then
      local p=pos+vec3(veh:getNodePosition(nodes[1]))
      local d=overhaul_events_streetKnightsVenues.project(v,p);best=math.max(best,d)
    end
  end
  return best
end
local function nose(veh,v)
  local obb=veh:getSpawnWorldOOBB();local best=-math.huge
  for i=0,7 do local d=overhaul_events_streetKnightsVenues.project(v,obb:getPoint(i));best=math.max(best,d) end
  return best
end
local function outside(veh,v,ai)
  local _,side=overhaul_events_streetKnightsVenues.project(v,veh:getSpawnWorldOOBB():getCenter())
  local aiSign=v.aiSide=='right' and 1 or -1
  local expected=ai and aiSign or -aiSign
  return side*expected<0 or math.abs(side)>v.laneWidth
end
function M.validate(v,playerId,opponentId)
  local ok,err=overhaul_events_streetKnightsVenues.validate(v)
  if not ok then return false,err end
  if v.level~=getCurrentLevelIdentifier() then return false,'Venue belongs to another map.' end
  if not v.stripPath or not FS:fileExists(v.stripPath) then return false,'Save this venue with the builder first.' end
  local strip=gameplay_drag_saveSystem.loadCompleteDragRaceData(v.stripPath)
  if not strip or #strip.strip.lanes~=2 then return false,'Invalid generated drag strip.' end
  if playerId and obstructions.new(v,overhaul_events_streetKnightsVenues).find(be,playerId,opponentId) then return false,obstructions.message end
  return true
end
function M.start(data)
  if race and not finished then return false,'Another Street Knights race is running.' end
  if not native.available() then return false,'Another drag race is running.' end
  native.clear()
  if aiId then
    local previous=be:getObjectByID(aiId)
    local owned=previous and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(aiId)
    if previous and not owned then previous:delete()
    elseif owned and be:getPlayerVehicleID(0)~=aiId then
      local record=overhaul_career_garage_inventory.getVehicles()[owned]
      if not (record and (record.streetChallengesInWorld or record.streetChallengesStorePending or record.streetKnightsInWorld or record.streetKnightsStorePending)) then overhaul_career_garage_inventory.removeVehicleObject(owned) end
    end
    aiId=nil
  end
  race=deepcopy(data);finished=false;cleanupAt=nil;staged=false;ready=false;elapsed=0;spawnAge=0;countdown=nil;lastPlayer=nil;lastAI=nil
  redArmed=false
  pendingPrize=nil;captureAge=0;captureAttempts=0;pendingOutcome=nil;outcomeAge=0;prizeWait=0
  tree(nil);suppressTraffic()
  local v=race.venue;local offset=(v.aiSide=='right' and 1 or -1)*v.laneWidth/2
  laneCheck=obstructions.new(v,overhaul_events_streetKnightsVenues);blocker=nil;blockCheckAt=0;blockPromptAt=0
  local pos=vec3(overhaul_events_streetKnightsVenues.position(v,-2,offset))
  local f=overhaul_events_streetKnightsVenues.axes(v)
  local spawned=race.waitingOpponentId and be:getObjectByID(race.waitingOpponentId)
  if not spawned and not race.waitingOpponentId then spawned=core_vehicles.spawnNewVehicle(race.opponent.model,{config=race.opponentConfigSnapshot or race.opponent.config,pos=pos,rot=quatFromDir(vec3(f),vec3(0,0,1)),autoEnterVehicle=false}) end
  if not spawned then race=nil;restoreTraffic();return false,'Could not spawn the opponent.' end
  -- Cling via safeTeleport so a bad spawn height cannot shear the wheels on contact (setPosition buries cars).
  if spawn and spawn.safeTeleport then
    spawn.safeTeleport(spawned,pos,quatFromDir(vec3(f),vec3(0,0,1)),true,nil,false,true,true)
  elseif race.waitingOpponentId then
    spawned:setPosition(pos)
  end
  aiId=spawned:getID();spawned.playerUsable=false;phase('approach')
  if race.opponent.originalVehicle then prizeRecovery.applyMileage(spawned,race.opponent.originalVehicle.mileage) end
  local ok,err=native.prepare(v,aiId)
  if not ok then native.clear();race=nil;restoreTraffic();return false,err end
  send(aiId,"extensions.load('overhaulStreetKnightsRaceGuard'); overhaulStreetKnightsRaceGuard.configure("..race.playerVehicleId..",true)")
  send(race.playerVehicleId,"extensions.load('overhaulStreetKnightsRaceGuard'); overhaulStreetKnightsRaceGuard.configure("..aiId..",false)")
  return true
end
function M.getOpponentId() return aiId end
function M.getPendingOutcome() return pendingOutcome and {outcome=pendingOutcome.outcome,reason=pendingOutcome.reason} end
function M.opponentReady(id) if id==aiId then ready=true end end
local function capturePrize()
  local ai=aiId and be:getObjectByID(aiId)
  if not pendingPrize then return end
  -- A vanished car counts as a failed try, so the locked win still reaches prize recovery.
  if not ai then captureAge=0;captureAttempts=captureAttempts+1;return end
  local prize=deepcopy(pendingPrize);local transaction=race.id
  captureAge=0;captureAttempts=captureAttempts+1
  ai:queueLuaCommand("extensions.load('overhaulDamageState'); overhaulDamageState.saveDamageData("..serialize(prize.damagePath)..")")
  core_vehicleBridge.requestValue(ai,function(response)
    if not race or race.id~=transaction or not pendingPrize then return end
    local captured=response and response.result
    if type(captured)~='table' or not next(captured) then controller().prizeCaptureFailed();return end
    if not overhaul_career_saveSystem.jsonWriteFileSafe(prize.conditionsPath,captured,true) then controller().prizeCaptureFailed();return end
    local conditions=jsonReadFile(prize.conditionsPath)
    local damage=jsonReadFile(prize.damagePath)
    if type(conditions)~='table' or not next(conditions) or not damage or damage.format~='rls_v1' then
      controller().prizeCaptureFailed();return
    end
    prize.partConditions=conditions
    if controller().completePrize(prize) then pendingPrize=nil end
  end,'getPartConditions')
end
local function opponentMoving()
  local ai=aiId and be:getObjectByID(aiId)
  return ai~=nil and ai:getVelocity():length()>=stopTuning.stoppedSpeedMps
end
local function settleOutcome()
  if not pendingOutcome then return end
  local decision=pendingOutcome
  if decision.prize then
    if controller().lockPendingPrize(decision.outcome,decision.reason,decision.prize) then
      pendingOutcome=nil;pendingPrize=decision.prize;prizeWait=0
      if not opponentMoving() then capturePrize() end
    end
  elseif controller().raceFinished(decision.outcome,decision.reason) then
    pendingOutcome=nil
  end
end
local function finish(outcome,reason)
  if finished then return end
  finished=true;hideStageGuide()
  native.stop()
  if aiId then send(aiId,"if overhaulStreetKnightsRaceGuard then overhaulStreetKnightsRaceGuard.stop() end") end
  guihooks.trigger('StreetKnightsHud',{challenge=race and race.controller=='overhaul_career_economy_streetChallenges',phase='finished',outcome=outcome,reason=reason})
  local ai=aiId and be:getObjectByID(aiId)
  if outcome=='loss' and reason=='Red light' and race.controller~='overhaul_career_economy_streetChallenges' and ai then
    local owned=overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(aiId)
    if not owned then native.clear();ai:delete();aiId=nil;ai=nil end
  end
  if outcome=='win' and (race.kind=='boss' or race.kind=='pink') and ai then
    local data=core_vehicle_manager.getVehicleData(aiId)
    local info=core_vehicles.getConfig(race.opponent.model,race.opponent.configKey or race.opponent.id) or {}
    local original=race.opponent.originalVehicle
    local prize={model=race.opponent.model,config=deepcopy(data.config),configBaseValue=info.Value or 0,niceName=race.opponent.name,
      year=original and original.year or 2026,mileage=original and original.mileage or prizeRecovery.rollMileageMeters(math.random),owned=true,partConditions={},defaultThumbnail=true}
    if original then prize.niceName=original.niceName;prize.configBaseValue=original.configBaseValue or prize.configBaseValue end
    prize.conditionsPath,prize.damagePath=controller().prizePaths()
    pendingOutcome={outcome=outcome,reason=reason,prize=prize}
  else pendingOutcome={outcome=outcome,reason=reason} end
  -- Persist the decided result before settle retries so a reload cannot invent a loss.
  if controller().rememberDecision then
    local prize=pendingOutcome.prize
    if prize then prize.pending=true end
    controller().rememberDecision(outcome,reason,prize)
  end
  outcomeAge=0;settleOutcome()
end
function M.contact(a,b)
  if not race or finished then return end
  if (a==aiId and b==race.playerVehicleId) or (b==aiId and a==race.playerVehicleId) then finish('loss','Contact with opponent') end
end
function M.stop(keepOpponent,outcome,reason,canReturnToMeet)
  finished=true;hideStageGuide()
  -- Match FRE's post-event delay, then hand population back to its traffic pool.
  if trafficSuppressed and not meetHold and not trafficRestoreAt and not trafficRamp then trafficRestoreAt=10 end
  if race then send(race.playerVehicleId,"extensions.unload('overhaulStreetKnightsRaceGuard')") end
  native.stop()
  if aiId then send(aiId,"if overhaulStreetKnightsRaceGuard then overhaulStreetKnightsRaceGuard.stop() end") end
  cleanupAt=30
  guihooks.trigger('StreetKnightsHud',{challenge=race and race.controller=='overhaul_career_economy_streetChallenges',phase='finished',outcome=outcome,reason=reason,canReturnToMeet=canReturnToMeet})
end
function M.clear()
  meetHold=false;restoreTraffic();hideStageGuide();tree(nil)
  native.clear()
  if race then send(race.playerVehicleId,"extensions.unload('overhaulStreetKnightsRaceGuard')") end
  local ai=aiId and be:getObjectByID(aiId)
  if ai then
    local owned=overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(aiId)
    if owned then send(aiId,"extensions.unload('overhaulStreetKnightsRaceGuard')") else ai:delete() end
  end
  race=nil;aiId=nil;cleanupAt=nil;finished=true
  laneCheck=nil;blocker=nil
  pendingPrize=nil;pendingOutcome=nil
  guihooks.trigger('StreetKnightsHud',{})
end
function M.releaseOpponent()
  local opponent=aiId and be:getObjectByID(aiId)
  native.clear(true)
  if aiId then send(aiId,"extensions.unload('overhaulStreetKnightsRaceGuard')") end
  aiId=nil
  return opponent
end
function M.onClientEndMission() M.clear() end
function M.onExtensionUnloaded() M.clear() end
local function update(dtReal,dtSim)
  updateTraffic(dtSim)
  if not race then return end
  if finished then
    if pendingOutcome then
      outcomeAge=outcomeAge+dtReal
      if outcomeAge>=2 then outcomeAge=0;settleOutcome() end
      return
    end
    if pendingPrize then
      if captureAttempts==0 and prizeWait<stopTuning.handoverTimeoutSec then
        prizeWait=prizeWait+dtSim -- game time, so a pause cannot hand over a car still moving
        if opponentMoving() and prizeWait<stopTuning.handoverTimeoutSec then return end
        capturePrize();return
      end
      captureAge=captureAge+dtReal
      if captureAge>=2 then
        captureAge=0
        -- Damage-capture budget is separate from settlement: after a few capture tries,
        -- keep retrying prize settlement from the locked win so recovery cannot stick.
        if captureAttempts<3 then capturePrize()
        elseif controller().recoverPrizeCapture(pendingPrize) then pendingPrize=nil
        end
      end
      return
    end
    if cleanupAt then cleanupAt=cleanupAt-dtSim;if cleanupAt<=0 then
      native.clear()
      local ai=aiId and be:getObjectByID(aiId)
      if ai then
        local invId=overhaul_career_garage_inventory.getInventoryIdFromVehicleId(aiId)
        if not invId then ai:delete()
        elseif be:getPlayerVehicleID(0)~=aiId then
          local record=overhaul_career_garage_inventory.getVehicles()[invId]
          if record and (record.streetChallengesInWorld or record.streetChallengesStorePending or record.streetKnightsInWorld or record.streetKnightsStorePending) then send(aiId,"extensions.unload('overhaulStreetKnightsRaceGuard')")
          else overhaul_career_garage_inventory.updatePartConditions(aiId,invId,function() overhaul_career_garage_inventory.removeVehicleObject(invId) end) end
        end
      end
      aiId=nil;race=nil;cleanupAt=nil
    end end
    return
  end
  local player=be:getObjectByID(race.playerVehicleId);local ai=aiId and be:getObjectByID(aiId)
  spawnAge=spawnAge+dtReal
  if not ai then controller().systemFault('opponentInitialization','Opponent disappeared');return end
  if not player then finish('loss','Entered car unavailable');return end
  if not ready and spawnAge>15 then controller().systemFault('opponentInitialization','Opponent engine did not initialize');return end
  local v=race.venue
  local aiFront=M.frontWheels(ai,v)
  if not staged then
    if aiFront>-math.huge and spawnAge>0.25 then
      local f=vec3((overhaul_events_streetKnightsVenues.axes(v)));local p=ai:getPosition()+f*(-0.05-aiFront)
      -- Keep the reference-point target and move all clusters so separate axles stay attached.
      if spawn and spawn.safeTeleport then
        spawn.safeTeleport(ai,p,quatFromDir(f,vec3(0,0,1)),false,nil,false,false,true)
      else ai:setPosition(p) end
      staged=true;ready=false;spawnAge=0
      -- Positioning resets the vehicle's ignition; start and re-arm readiness after that reset.
      send(aiId,"controller.setFreeze(1); extensions.load('overhaulStreetKnightsRaceGuard'); overhaulStreetKnightsRaceGuard.configure("..race.playerVehicleId..",true)")
    elseif spawnAge>10 then controller().systemFault('opponentInitialization','Could not locate front wheels') end
    return
  end
  local front=M.frontWheels(player,v)
  local lights=native.state(dtSim)
  if lights.fault then controller().systemFault('controllerError',lights.fault);return end
  if race.phase~='green' then
    blockCheckAt=blockCheckAt-dtReal;blockPromptAt=blockPromptAt-dtReal
    if blockCheckAt<=0 or (countdown and (lights.green or lights.red or lights.disqualified)) then
      blocker=laneCheck.find(be,race.playerVehicleId,aiId);blockCheckAt=0.25
    end
    if blocker then
      if countdown then native.cancel();countdown=nil;redArmed=false;phase('prestage') end
      hideStageGuide();tree(nil)
      if blockPromptAt<=0 then
        guihooks.trigger('Message',{ttl=6,msg=obstructions.message,category='warning',icon='warning'})
        blockPromptAt=5
      end
      return
    end
    blockPromptAt=0
  end
  if countdown and (lights.amber1 or lights.amber2 or lights.amber3) then redArmed=true end
  local red=lights.red or lights.disqualified=='Opponent red light'
  if countdown and ((red and redArmed) or (lights.disqualified and not red)) then
    tree({ai={red=true}});finish('win',lights.disqualified or 'Opponent red light');return
  end
  if race.phase~='green' then
    local inLane=not outside(player,v,false)
    local aiInLane=not outside(ai,v,true)
    local bothInStage=inLane and front>=-0.15 and front<=0.2 and aiInLane and aiFront>=-0.15 and aiFront<=0.2 and ready
    local bothStaged=bothInStage and player:getVelocity():length()<0.05 and ai:getVelocity():length()<0.05
    if countdown and not redArmed and (not bothInStage or red) then
      native.cancel();countdown=nil;redArmed=false;phase('prestage')
      if aiFront< -0.15 or aiFront>0.2 then staged=false end
      tree({player=stageBulbs(front,inLane),ai=stageBulbs(aiFront,aiInLane)})
      return
    end
    if not countdown and not redArmed and aiInLane and ai:getVelocity():length()<0.5
      and aiFront>-math.huge and aiFront<math.huge and (aiFront< -0.15 or aiFront>0.2) then
      native.cancel();staged=false;phase('prestage');return
    end
    if countdown and not lights.green then
      local _,ps=overhaul_events_streetKnightsVenues.project(v,player:getSpawnWorldOOBB():getCenter())
      local _,as=overhaul_events_streetKnightsVenues.project(v,ai:getSpawnWorldOOBB():getCenter())
      local sign=v.aiSide=='right' and 1 or -1
      if ps*sign>0 then finish('loss','Left your lane');return end
      if as*sign<0 then finish('win','Opponent left its lane');return end
    end
    if countdown and lights.green then
      hideStageGuide();phase('green');elapsed=0
      lastPlayer=nose(player,v);lastAI=nose(ai,v)
      local _,ps=overhaul_events_streetKnightsVenues.project(v,player:getSpawnWorldOOBB():getCenter())
      local _,as=overhaul_events_streetKnightsVenues.project(v,ai:getSpawnWorldOOBB():getCenter())
      local sign=v.aiSide=='right' and 1 or -1
      lastPlayerSide=-ps*sign;lastAISide=as*sign
      tree({player={green=true},ai={green=true}})
      return
    end
    if redArmed and (aiFront>0.2 or aiFront< -0.15) then tree({ai={red=true}});finish('win','Opponent red light');return end
    if redArmed and (front>0.2 or front< -0.15) then tree({player={red=true}});finish('loss','Red light');return end
    drawStageGuide(v,front,front>=-0.15 and front<=0.2 and inLane,dtReal,dtSim)
    if front>=-0.8 and front<=0.2 and inLane then
      if race.phase=='approach' then phase('prestage') end
      if front>=-0.15 and (countdown or bothStaged) then
        if not countdown then
          blocker=laneCheck.find(be,race.playerVehicleId,aiId)
          if blocker then blockCheckAt=0;return end
          local ok,err=native.begin()
          if not ok then controller().systemFault('opponentInitialization',err);return end
          countdown=true;phase('staged')
        end
      else
        if countdown then native.cancel();redArmed=false end
        countdown=nil;if race.phase=='staged' then phase('prestage') end
      end
    elseif race.phase~='approach' then
      if countdown then native.cancel() end
      countdown=nil;redArmed=false;phase('approach')
    end
    local p,a=stageBulbs(front,inLane),stageBulbs(aiFront,aiInLane)
    for n=1,3 do
      local on=countdown~=nil and lights['amber'..n]
      p['amber'..n]=on;a['amber'..n]=on
    end
    tree({player=p,ai=a})
    return
  end
  elapsed=elapsed+dtSim
  local pd,ad=nose(player,v),nose(ai,v)
  local pt=rules.crossing(lastPlayer,pd,v.length,elapsed,dtSim)
  local at=rules.crossing(lastAI,ad,v.length,elapsed,dtSim)
  local playerCenter=player:getSpawnWorldOOBB():getCenter()
  local _,ps=overhaul_events_streetKnightsVenues.project(v,playerCenter)
  local _,as=overhaul_events_streetKnightsVenues.project(v,ai:getSpawnWorldOOBB():getCenter())
  local sign=v.aiSide=='right' and 1 or -1;ps=-ps*sign;as=as*sign
  local pe=rules.laneExit(lastPlayerSide,ps,elapsed,dtSim,v.laneWidth)
  local ae=rules.laneExit(lastAISide,as,elapsed,dtSim,v.laneWidth)
  local winner,why=rules.firstEvent(pt,at,pe,ae)
  if winner then
    if why=='Left your lane' then
      log('I','streetKnightsDrag',string.format('Lane foul venue=%s vehicle=%s lane=%s distance=%.3fm previousSide=%.6f side=%.6f width=%.6f center=(%.6f,%.6f,%.6f)',
        tostring(v.id),tostring(race.playerVehicleId),v.aiSide=='right' and 'left' or 'right',pd,lastPlayerSide,ps,v.laneWidth,playerCenter.x,playerCenter.y,playerCenter.z))
    end
    finish(winner,why);return
  end
  if elapsed>=(v.raceTimeout or rules.raceTimeout) then finish('loss','Race timed out');return end
  lastPlayer=pd;lastAI=ad
  lastPlayerSide=ps;lastAISide=as
end
function M.onUpdate(dtReal,dtSim)
  local ok,err=xpcall(function() update(dtReal,dtSim) end,debug.traceback)
  if not ok and race and not finished then
    controller().systemFault('controllerError',err)
  elseif not ok then log('E','streetKnightsDrag',err) end
end
return M
