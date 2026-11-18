local M={}
M.dependencies={'overhaul_career_career','overhaul_career_saveSystem','overhaul_career_garage_inventory','overhaul_career_economy_payment','overhaul_career_carmeets_carmeets','overhaul_career_economy_streetKnights'}
local rules=require('overhaul/career/economy/streetChallenges/rules')
local journalFactory=require('overhaul/lib/finance/wagerJournal')
local prizeRecovery=require('overhaul/career/economy/streetKnights/prizeRecovery')
local winBack=require('overhaul/lib/vehicles/pinkSlipWinBack')
local live=require('overhaul/career/economy/streetChallenges/session')
local journal,profile,loaded,offer,talk,pending,active,result,warning,errorMessage
local receipts={}
local winBacks={}
local handover,handoverCallback
local revision,age,tick,incomingAge,cooldown=0,0,0,0,0
local uiOpen,recovering,ledgerReady=false,false,false
local offered={}
local challengeRoute,returnMeet,resultCarId
local function clearRoute()
  if not challengeRoute then return end
  local ownership=require("overhaul/lib/platform/capabilities").get("groundMarkerOwnership")
  if ownership then ownership.release("streetChallenges") end
  local target=core_groundMarkers.getTargetPos()
  if target and (target-vec3(challengeRoute)):length()<1 then core_groundMarkers.setPath(nil) end
  challengeRoute=nil
end
local snapshotFile='/career/streetChallenges.json'
local function notify(message)
  ui_message(message,10,'streetChallenges','flag')
end
local function fail(message)
  errorMessage=message;guihooks.trigger('StreetChallengesError',message)
  if not uiOpen then notify(message) end
  return false,message
end
local function car()
  local agreed=active or pending or offer
  local id=agreed and agreed.carId or overhaul_career_carmeets_carmeets.getChallengeVehicleInventoryId()
  local record=id and overhaul_career_garage_inventory.getVehicles()[id]
  local sceneId=id and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(id)
  local veh=sceneId and be:getObjectByID(sceneId)
  if not record or record.owned==false or not veh then return end
  return id,record,veh
end
local function configuration(veh)
  local data=core_vehicle_manager.getVehicleData(veh:getID())
  local config=data and data.config
  return config and {parts=deepcopy(config.parts or {}),partsTree=deepcopy(config.partsTree or {}),vars=deepcopy(config.vars or {})}
end
local function sameConfiguration(veh,expected)
  local function same(a,b)
    if type(a)~='table' or type(b)~='table' then return a==b end
    for k,v in pairs(a) do if not same(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
  end
  return expected and same(configuration(veh),expected)
end
local function clearPois() if gameplay_rawPois then gameplay_rawPois.clear() end end
local function candidates() return overhaul_career_carmeets_carmeets.getChallengeCandidates() end
local function candidate(id)
  for _,entry in ipairs(candidates()) do if entry.shopId==tonumber(id) then return entry end end
end
local function venues(player)
  local list={}
  local origin=player:getPosition()
  local planner=require('gameplay/route/route')()
  for _,v in ipairs(overhaul_events_streetKnightsVenues.list(getCurrentLevelIdentifier())) do
    if overhaul_events_streetKnightsDrag.validate(v) then
      local destination=vec3(v.parking)
      planner:setupPath(origin,destination)
      local first=planner.path and planner.path[1]
      local distance=first and first.distToTarget
      v.distance=distance and distance>0 and distance or (destination-origin):length()
      list[#list+1]=v
    end
  end
  table.sort(list,function(a,b) return a.distance==b.distance and a.id<b.id or a.distance<b.distance end)
  return list
end
local function clearTask() guihooks.trigger('DiscardTasklistItem','streetChallengeRace') end
function M.isCommitted() return active and journal and journal.records[active.id] and journal.records[active.id].state=='committed' or false end
function M.blocksSave() return M.isCommitted() or recovering end
function M.isBusy() return pending~=nil or active~=nil end
function M.ownsVenue() return M.isBusy() end
function M.getWinBackVehicles()
  if not journal or recovering or errorMessage then return {} end
  return deepcopy(winBacks)
end
local function available()
  if not journal or recovering then return false,'Career wager records are not ready.' end
  if M.isBusy() then return false,'Finish or cancel your current challenge first.' end
  if overhaul_career_economy_streetKnights.blocksOtherRaces() then return false,'Finish your current event first.' end
  if overhaul_events_session and overhaul_events_session.mActiveRace then return false,'Finish your current event first.' end
  if gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId() then return false,'Finish your current mission first.' end
  if #candidates()==0 then return false,'The meet has ended or its racers have left.' end
  if not car() then return false,'Bring a car you own to the meet.' end
  return true
end
function M.getState()
  local id,record=car()
  return {talk=talk and {shopId=talk.shopId,name=talk.name,owner=talk.sellerName,winBackId=talk.winBackId},offer=offer and {
    revision=offer.revision,kind=offer.kind,amount=offer.amount,direction=offer.direction,venue=offer.venue,
    ready=offer.ready,negotiation=offer.negotiation and deepcopy(rules.publicNegotiation(offer.negotiation)),playerStats=offer.playerStats,opponentStats=offer.opponentStats},
    venues=offer and offer.venues or {},pending=pending and {venue=pending.venue,owner=pending.opponent.owner,remaining=math.max(0,1800-pending.age)},
    race=active and {phase=active.phase,kind=active.kind,amount=active.amount},result=result,canReturnToMeet=result~=nil and resultCarId~=nil,
    warning=warning and {label=warning.label,stake=active and active.kind=='boss' and 'your car' or '$'..tostring(active and active.amount or 0)},
    handover=handover and {name=active and active.opponent.owner},
    car=id and {id=id,name=record.niceName or record.model},error=errorMessage}
end
local function push() if uiOpen then guihooks.trigger('StreetChallengesState',M.getState()) end end
local function discardOffer()
  if not offer then return end
  -- Clear ownership before cancelling callbacks so a late measurement cannot revive the draft.
  offer=nil;age=0;revision=revision+1
  require('overhaul/lib/vehicles/callbacks').cancelOwner('streetChallenges','conversation ended')
end
function M.requestState()
  if offer and not offer.ready then
    discardOffer()
    errorMessage='The previous challenge was interrupted. Challenge the owner again.'
  end
  uiOpen=true;push()
end
function M.close()
  if handover then push();return false end
  discardOffer()
  errorMessage=nil;warning=nil
  if result then overhaul_career_carmeets_carmeets.routeBackFromChallenge(returnMeet) end
  uiOpen=false;guihooks.trigger('ChangeState',{state='play'});return true
end
function M.openResult()
  if not result then return false end
  uiOpen=true;guihooks.trigger('StreetKnightsHud',{});extensions.ui_router.navigate('overhaul.streetChallenges');push();return true
end
function M.returnToMeet()
  if not result or not resultCarId or handover or recovering or offer or pending or (active and active.phase~='cooldown') then return false end
  if not overhaul_career_career.isActive() or (not active and overhaul_career_economy_streetKnights.blocksOtherRaces())
    or (overhaul_events_session and overhaul_events_session.mActiveRace)
    or (gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId()) then
    return fail('Finish your current event first.')
  end
  local inventory=overhaul_career_garage_inventory
  local record=inventory.getVehicles()[resultCarId]
  local vehicleId=inventory.getVehicleIdFromInventoryId(resultCarId)
  if not record or record.owned==false or not vehicleId or vehicleId~=be:getPlayerVehicleID(0) then
    return fail('Get into the car you raced before returning to the meet.')
  end
  local parked,why=overhaul_career_carmeets_carmeets.parkPlayerAtMeet(returnMeet,vehicleId)
  if not parked then return fail(why) end
  returnMeet=nil;resultCarId=nil
  guihooks.trigger('StreetKnightsHud',{})
  return M.close()
end
function M.openTalk(id)
  local entry=candidate(id)
  if not entry then return fail('That owner has left the meet.') end
  talk=entry;result=nil;errorMessage=nil
  if offer and offer.shopId~=entry.shopId then discardOffer() end
  uiOpen=true;extensions.ui_router.navigate('overhaul.streetChallenges');push();return true
end
function M.makeOffer()
  if not talk or not candidate(talk.shopId) then return fail('That owner has left the meet.') end
  if talk.winBackId then return fail('This owner will race for your former car, but is not selling it.') end
  local started=overhaul_career_carmeets_carmeets.startPurchaseOffer(talk.shopId)
  if started then uiOpen=false end
  return started
end
local function probe(veh,token)
  local request=require('overhaul/lib/vehicles/callbacks').open('streetChallengePerformance',{owner='streetChallenges',vehId=veh:getID(),timeout=15,endsWith={'map','profile'}})
  if not request then return end
  veh:queueLuaCommand("local p=0; for _,e in ipairs(powertrain.getDevicesByCategory('engine') or {}) do p=p+(e.maxPower or 0) end; obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply("..request..",'streetChallengePerformance',"..serialize(token..',').."..obj:getID()..','..serialize({power=p,weight=obj:calcBeamStats().total_weight})))")
end
function M.challenge(id,direction)
  local ok,why=available();if not ok then return fail(why) end
  local entry=candidate(id or (talk and talk.shopId));if not entry then return fail('That owner has left the meet.') end
  local opponent=be:getObjectByID(entry.vehicleId)
  local data=opponent and core_vehicle_manager.getVehicleData(entry.vehicleId)
  local carId,_,player=car()
  local list=venues(player);if #list==0 then return fail('No race venues are available on this map.') end
  if not data or type(data.config)~='table' then return fail('The opponent configuration is not ready.') end
  talk=entry;errorMessage=nil;result=nil;revision=revision+1;age=0
  live.probe=(live.probe or 0)+1
  offer={shopId=entry.shopId,revision=revision,token=live.probe,carId=carId,playerId=player:getID(),opponentId=entry.vehicleId,playerConfig=configuration(player),
    opponent={model=entry.modelKey,config=deepcopy(data.config),id=tostring(entry.shopId),name=entry.name,owner=entry.sellerName,
      winBackId=entry.winBackId,winBackOwnerId=entry.winBackOwnerId,originalVehicle=deepcopy(entry.originalVehicle)},
    paintName=data.config.paintName or (entry.paintNames and entry.paintNames[1]),
    direction=direction=='incoming' and 'incoming' or 'outgoing',venues=list,venue=deepcopy(list[1])}
  probe(player,offer.token);probe(opponent,offer.token);push();return true
end
function M.receivePerformance(token,id,stats)
  if not offer or offer.token~=token or offer.ready or not rules.ratio(stats) then return end
  if id==offer.playerId then offer.playerStats=stats elseif id==offer.opponentId then offer.opponentStats=stats else return end
  if offer.playerStats and offer.opponentStats then
    local wager=rules.wager(offer.playerStats,offer.opponentStats,math.random)
    offer.kind=wager.kind;offer.amount=wager.amount;offer.ready=true
    offer.preference={kind=wager.kind,amount=wager.amount,confidence=wager.confidence,venueId=offer.venue.id}
    if offer.opponent.winBackId then offer.preference.kind='boss' end
    offer.negotiation=rules.openNegotiation(offer.preference)
    offer.kind=offer.negotiation.kind
    if offer.direction=='incoming' then
      local carName=offer.opponent.name and ('the '..offer.opponent.name) or 'their car'
      if offer.paintName and offer.paintName~='' then carName=carName..' ('..offer.paintName..')' end
      notify(offer.opponent.owner..' challenges you to a race. Look for '..carName..' to review the wager.')
    end
  end
  push()
end
function M.negotiate(kind,amount,venueId,version)
  if not offer or offer.revision~=version or not offer.ready then return fail('The challenge has changed.') end
  if not candidate(offer.shopId) then return fail('That owner has left the meet.') end
  if venueId~=offer.venue.id then return fail('Challenges use the nearest race venue.') end
  local id,_,player=car()
  if id~=offer.carId or not sameConfiguration(player,offer.playerConfig) then return fail('Use the unchanged car named in the challenge.') end
  local terms,why=rules.counterOffer(offer.negotiation,offer.preference,kind,amount,venueId,math.random)
  if not terms then return fail(why) end
  for _,v in ipairs(offer.venues) do if v.id==terms.venueId then offer.venue=deepcopy(v);break end end
  offer.kind=terms.kind;offer.amount=terms.amount
  revision=revision+1;offer.revision=revision;errorMessage=nil;push();return true
end
function M.selectVenue(id,version)
  if not offer then return fail('The challenge has changed.') end
  return M.negotiate(offer.kind,offer.amount,id,version)
end
function M.requestCash(version)
  if not offer then return fail('The challenge has changed.') end
  return M.negotiate('cash',offer.amount,offer.venue.id,version)
end
local function removeWaiting()
  local id=pending and pending.waitingOpponentId
  local v=id and be:getObjectByID(id)
  if v then v:delete() end
end
function M.route()
  local target=pending or active
  if not target then return false end
  challengeRoute=deepcopy(target.venue.parking)
  core_groundMarkers.setPath(vec3(target.venue.parking),{color={1,.4,0},step=4,renderDecals=true})
  local ownership=require("overhaul/lib/platform/capabilities").get("groundMarkerOwnership")
  if ownership then ownership.claim("streetChallenges") end
  return true
end
function M.accept(version)
  local ok,why=available();if not ok then return fail(why) end
  if not offer or offer.revision~=version or not offer.ready then return fail('Wait for the current wager.') end
  if offer.negotiation.status=='failed' then return fail('The owner has ended this discussion.') end
  if not candidate(offer.shopId) then return fail('That owner has left the meet.') end
  local id,_,player=car()
  if id~=offer.carId or not sameConfiguration(player,offer.playerConfig) then return fail('Use the unchanged car named in the challenge.') end
  if offer.kind=='cash' and overhaul_career_economy_playerAttributes.getAttributeValue('money')<offer.amount then return fail('Insufficient funds for this wager.') end
  local valid,err=overhaul_events_streetKnightsDrag.validate(offer.venue);if not valid then return fail(err) end
  local v=offer.venue;local side=(v.aiSide=='right' and 1 or -1)*v.laneWidth/2
  local f=overhaul_events_streetKnightsVenues.axes(v)
  local waiting=core_vehicles.spawnNewVehicle(offer.opponent.model,{config=deepcopy(offer.opponent.config),pos=vec3(overhaul_events_streetKnightsVenues.position(v,-2,side)),rot=quatFromDir(vec3(f),vec3(0,0,1)),autoEnterVehicle=false})
  if not waiting then return fail('Could not prepare the opponent. No wager was charged.') end
  waiting.playerUsable=false;waiting:queueLuaCommand("ai.setMode('disabled');input.event('parkingbrake',1,1);electrics.setIgnitionLevel(0)")
  returnMeet=overhaul_career_carmeets_carmeets.getChallengeReturnData(candidate(offer.shopId))
  pending={carId=id,playerConfig=deepcopy(offer.playerConfig),playerVehicleId=player:getID(),kind=offer.kind,amount=offer.amount,opponent=deepcopy(offer.opponent),venue=deepcopy(v),waitingOpponentId=waiting:getID(),age=0,returnMeet=returnMeet}
  pending.winBackId=offer.kind=='boss' and offer.opponent.winBackId or nil
  pending.winBackOwnerId=offer.opponent.winBackOwnerId
  pending.venue.decorations=false
  overhaul_career_carmeets_carmeets.onCarMeetVehiclePurchased(offer.shopId,false)
  overhaul_events_streetKnightsMeet.clear();overhaul_events_streetKnightsDrag.holdTraffic(false)
  offer=nil;revision=revision+1;clearPois();M.route()
  guihooks.trigger('SetTasklistTask',{id='streetChallengeRace',label='Race '..pending.opponent.owner..' at '..v.name,active=true,type='message'})
  notify('Challenge accepted. Your opponent will be waiting at '..v.name..'. No stake is charged until you start.');M.close();return true
end
function M.cancel()
  if handover then return false end
  if active then return M.requestAction('abandon the race') end
  local owned=pending~=nil
  clearRoute();clearTask();removeWaiting();pending=nil;discardOffer();errorMessage=nil;revision=revision+1
  if owned then overhaul_events_streetKnightsMeet.clear();overhaul_events_streetKnightsDrag.holdTraffic(false);clearPois() end
  push();return true
end
local function placePrize(id,record)
  if record.streetChallengesPlacementDone then return true end
  local garage=overhaul_career_garage_garageManager and overhaul_career_garage_garageManager.getNextAvailableSpace()
  record.takesNoInventorySpace=nil
  if garage and overhaul_career_garage_inventory.moveVehicleToGarage(id,garage) then
    record.streetChallengesInWorld=nil
    record.streetChallengesStorePending=true
  else
    record.location=nil;record.niceLocation='At the race venue';record.streetChallengesInWorld=true
  end
  record.streetChallengesPlacementDone=true;overhaul_career_garage_inventory.setVehicleDirty(id);return true
end
function M.onOverhaulAddedVehiclePartsToInventory(id)
  local record=overhaul_career_garage_inventory.getVehicles()[id]
  if record and record.streetChallengesStorePending then
    record.streetChallengesStorePending=nil;overhaul_career_garage_inventory.removeVehicleObject(id);overhaul_career_garage_inventory.setVehicleDirty(id)
  end
end
local function grantPrize(r)
  local inv=overhaul_career_garage_inventory.getVehicles()
  for id,v in pairs(inv) do if v.streetChallengesTransaction==r.id then return placePrize(id,v) end end
  if not r.prize or r.prize.pending then return false,'Prize recovery is pending.' end
  local partConditions=prizeRecovery.conditions(r.prize)
  local conditions=next(partConditions)~=nil
  local mileage=r.prize.mileage or 0
  local sceneId=active and active.id==r.id and overhaul_events_streetKnightsDrag.getOpponentId()
  local veh=sceneId and be:getObjectByID(sceneId)
  local restored=not veh
  if not veh then
    veh=core_vehicles.spawnNewVehicle(r.prize.model,{config=deepcopy(r.prize.config),pos=vec3(r.race.venue.parking)+vec3(0,0,1),autoEnterVehicle=false})
    if not veh then return false,'Prize restoration will retry.' end
    sceneId=veh:getID()
  end
  if restored and conditions then core_vehicleBridge.executeAction(veh,'initPartConditions',partConditions) end
  if restored and r.prize.damagePath and FS:fileExists(r.prize.damagePath) then veh:queueLuaCommand("extensions.load('overhaulDamageState');overhaulDamageState.loadDamageData("..serialize(r.prize.damagePath)..")") end
  if mileage>0 then prizeRecovery.applyMileage(veh,mileage) end
  if settings then prizeRecovery.applyPlayerGearbox(veh,settings.getValue('defaultGearboxBehavior')) end
  local id=overhaul_career_garage_inventory.addVehicle(sceneId,nil,{owned=true,takesNoInventorySpace=true,skipPartConditionInit=conditions or mileage>0,finalPrice=0})
  if not id then return false,'Prize registration will retry.' end
  local record=inv[id]
  if conditions then record.partConditions=partConditions end
  if mileage>0 then record.mileage=mileage end
  record.niceName=r.prize.niceName;record.streetChallengesTransaction=r.id;record.rewardSource='Car Meet Challenge';record.purchasePrice=0
  if r.race.winBackId then record.year=r.prize.year;record.configBaseValue=r.prize.configBaseValue end
  winBack.restoreValue(getfenv(1),record,r.race.winBackId and r.race.opponent and r.race.opponent.originalVehicle)
  record.streetKnightsDamagePath=r.prize.damagePath
  veh.playerUsable=true
  if overhaul_career_repair_insurance then overhaul_career_repair_insurance.onOverhaulVehicleAddedToInventory({inventoryId=id,purchaseData={insuranceId=-1}}) end
  return placePrize(id,record)
end
local function reconcile(r)
  receipts[r.id]=receipts[r.id] or {};local receipt=receipts[r.id]
  if not receipt.escrow then
    if r.race.kind=='cash' and not overhaul_career_economy_payment.pay({money={amount=r.race.amount,canBeNegative=true}},require('overhaul/lib/finance/metadata').tag({label='Car meet challenge stake'},'activity:drag')) then return false,'Could not charge the committed stake.' end
    receipt.escrow=true
  end
  if r.state=='committed' or receipt.settled then return true end
  if r.race.kind=='cash' then
    local amount=r.outcome=='win' and r.race.amount*2 or r.outcome=='void' and r.race.amount or 0
    if amount>0 then overhaul_career_economy_payment.reward({money={amount=amount}},require('overhaul/lib/finance/metadata').tag({label='Car meet challenge '..r.outcome},r.outcome=='void' and 'refund' or 'activity:drag'),true) end
  elseif r.outcome=='loss' then
    if not r.handoverConfirmed then return false,'handover' end
    local transferred,err=winBack.transfer(getfenv(1),journal,r)
    if not transferred then return false,err end
  elseif r.outcome=='win' then
    local ok,err=grantPrize(r);if not ok then return false,err end
  end
  receipt.settled=true
  if r.race.kind=='boss' then winBacks=winBack.list(journal,getCurrentLevelIdentifier()) end
  return true
end
function M.startRace()
  if not pending then return fail('No accepted challenge.') end
  if (overhaul_career_saveSystem.isSaveInFlight or overhaul_career_saveSystem.isSaveBusy)() then return fail('Wait for the career save to finish.') end
  local id,_,player=car()
  if id~=pending.carId or not player or not sameConfiguration(player,pending.playerConfig) or be:getPlayerVehicleID(0)~=player:getID() then return fail('Arrive in the agreed car.') end
  if (player:getPosition()-vec3(pending.venue.parking)):length()>60 then return fail('Drive to the agreed venue first.') end
  if pending.kind=='cash' and overhaul_career_economy_playerAttributes.getAttributeValue('money')<pending.amount then return fail('Insufficient funds.') end
  if overhaul_events_session and overhaul_events_session.mActiveRace then return fail('Finish your current event first.') end
  if gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId() then return fail('Finish your current mission first.') end
  local waiting=be:getObjectByID(pending.waitingOpponentId)
  if not waiting then return fail('The opponent is unavailable. Cancel this challenge without losing your stake.') end
  overhaul_events_streetKnightsDrag.holdTraffic(true)
  local valid,why=overhaul_events_streetKnightsDrag.validate(pending.venue,player:getID(),pending.waitingOpponentId);if not valid then return fail(why) end
  local race=deepcopy(pending);race.id=profile..'_challenge_'..(journal.sequence+1)..'_'..os.time();race.order=journal.sequence+1
  race.controller='overhaul_career_economy_streetChallenges';race.phase='approach';race.playerVehicleId=player:getID()
  local record,err=journal:commit(race);if not record then return fail(err) end
  clearRoute();clearTask();active=race;pending=nil;errorMessage=nil;clearPois();reconcile(record);waiting:setActive(1)
  overhaul_events_streetKnightsMeet.update(race.venue,nil,false)
  local called,started,startErr=pcall(overhaul_events_streetKnightsDrag.start,race)
  if not called or not started then M.systemFault('opponentInitialization',called and startErr or started) end
  M.close();return true
end
local function awaitHandover(r)
  handover=r.id;active=deepcopy(r.race);active.phase='handover';recovering=true;warning=nil;errorMessage=nil
  result={outcome='loss',reason=r.reason,kind='boss',opponent=active.opponent.name};resultCarId=nil
  local sceneId=overhaul_career_garage_inventory.getVehicleIdFromInventoryId(active.carId)
  local player=sceneId and be:getObjectByID(sceneId);if player then player:queueLuaCommand("input.event('throttle',0,1);input.event('brake',1,1);input.event('parkingbrake',1,1)") end
  overhaul_events_streetKnightsDrag.stop(false,'loss',r.reason);guihooks.trigger('StreetKnightsHud',{})
  uiOpen=true;extensions.ui_router.navigate('overhaul.streetChallenges');push();return true
end
function M.giveUpCar()
  if not handover or not journal then return false end
  local record=deepcopy(journal.records[handover]);record.handoverConfirmed=true
  local durable,err=journal:write(record);if not durable then return fail(err) end
  local ok,why=reconcile(durable);if not ok then return fail(why) end
  handover=nil;recovering=false;warning=nil;errorMessage=nil;active.phase='cooldown';cooldown=0
  local callback=handoverCallback;handoverCallback=nil
  M.close();if callback then callback() end;return true
end
local function finish(outcome,reason,prize)
  local runner=overhaul_events_streetKnightsDrag
  local decided=runner and runner.getPendingOutcome and runner.getPendingOutcome()
  if decided and (decided.outcome~=outcome or decided.reason~=reason) then return false end
  if not active or not journal then return false end
  local existing=journal.records[active.id]
  if not existing or (existing.state~='committed' and (existing.state~='locked' or existing.outcome~=outcome or not recovering)) then return false end
  local r,err=journal:lock(active.id,outcome,reason,prize);if not r then return fail(err) end
  if r.race.kind=='boss' and outcome=='loss' then return awaitHandover(r) end
  recovering=true
  local ok,why=reconcile(r);if not ok then return fail(why) end
  recovering=false;errorMessage=nil;warning=nil;active.phase='cooldown';cooldown=0
  result={outcome=outcome,reason=reason,kind=active.kind,amount=active.amount,opponent=active.opponent.name}
  resultCarId=active.returnMeet and active.carId or nil
  overhaul_events_streetKnightsDrag.stop(outcome=='win' and active.kind=='boss',outcome,reason,resultCarId~=nil)
  if active.kind=='cash' then
    local opponentId=overhaul_events_streetKnightsDrag.getOpponentId()
    local opponent=opponentId and be:getObjectByID(opponentId)
    if overhaul_career_carmeets_carmeets.returnChallengeVehicle(active.returnMeet,opponent) then overhaul_events_streetKnightsDrag.releaseOpponent() end
  end
  notify('Challenge '..outcome..': '..reason);push();return true
end
function M.raceFinished(outcome,reason) if outcome=='win' or outcome=='loss' then return finish(outcome,reason) end end
function M.systemFault(code,detail)
  if code~='opponentInitialization' and code~='controllerError' and code~='invalidVenue' then return false end
  log('E','streetChallenges',tostring(detail));return finish('void','Race cancelled by a system fault; your stake was returned.')
end
function M.setPhase(phase) if active then active.phase=phase;push() end end
function M.prizePaths()
  local dir=overhaul_career_saveSystem.getSaveRootDirectory()..profile..'/streetChallengesLedger/'
  return dir..active.id..'_conditions.json',dir..active.id..'_damage.json'
end
function M.lockPendingPrize(outcome,reason,prize)
  if not M.isCommitted() then return false end
  prize.pending=true
  local r,err=journal:lock(active.id,outcome,reason,prize);if not r then return fail(err) end
  recovering=true;active.phase='cooldown';return true
end
function M.completePrize(prize)
  if not active or not recovering then return false end
  prize.pending=nil
  local r,err=journal:attachPrize(active.id,prize);if not r then return fail(err) end
  local ok,why=reconcile(r);if not ok then return fail(why) end
  recovering=false;errorMessage=nil;warning=nil;active.phase='cooldown';cooldown=0
  result={outcome='win',reason=r.reason,kind='boss',opponent=active.opponent.name}
  resultCarId=active.returnMeet and active.carId or nil
  overhaul_events_streetKnightsDrag.stop(true,'win',r.reason,resultCarId~=nil);notify('Challenge won. The opponent car is now yours.');push();return true
end
function M.prizeCaptureFailed() errorMessage='Your win is recorded. Retrying prize condition capture.';push() end
function M.recoverPrizeCapture(prize) return M.completePrize(prizeRecovery.resolve(prize,jsonReadFile)) end
function M.requestAction(label,callback)
  if handover then
    -- Keep the follow-up (quit/travel/recovery) until giveUpCar finishes the keys transfer.
    if callback and not handoverCallback then handoverCallback=callback end
    uiOpen=true;extensions.ui_router.navigate('overhaul.streetChallenges');push();return true
  end
  if recovering and not M.isCommitted() then fail('Prize settlement is still in progress. Please wait.');return true end
  if not M.isCommitted() and not recovering then if callback then callback() end;return false end
  warning={label=label,callback=callback};uiOpen=true;extensions.ui_router.navigate('overhaul.streetChallenges');push();return true
end
function M.confirmAction()
  if not warning or recovering then return end
  local callback=warning.callback
  if finish('loss','Forfeited') then
    if handover then handoverCallback=callback else if callback then callback() end;M.close() end
  end
end
function M.cancelAction() warning=nil;M.close() end
local function recoverLedger()
  local err
  for _,r in ipairs(journal:ordered()) do
    if r.state=='committed' then r,err=journal:lock(r.id,'loss','Unfinished race on reload') end
    if not r then errorMessage=err;return false end
    if r.prize and r.prize.pending then r,err=journal:attachPrize(r.id,prizeRecovery.resolve(r.prize,jsonReadFile));if not r then errorMessage=err;return false end end
    if r.state=='locked' and r.race.kind=='boss' and r.outcome=='loss' and not r.handoverConfirmed and not (receipts[r.id] and receipts[r.id].settled) then awaitHandover(r);return false end
    local applied,why=reconcile(r);if not applied then errorMessage=why;return false end
  end
  winBacks=winBack.list(journal,getCurrentLevelIdentifier())
  recovering=false;errorMessage=nil;return true
end
local function loadCareer()
  local slot,path=overhaul_career_saveSystem.getCurrentProfile();if not slot or not path or loaded then return end
  profile=slot;loaded=path;local snapshot=jsonReadFile(path..snapshotFile) or {};local inv=overhaul_career_garage_inventory.getVehicles()
  receipts=live.profile==slot and live.inventory==inv and live.receipts or snapshot.receipts or {}
  live.profile=slot;live.inventory=inv;live.receipts=receipts
  errorMessage=nil
  local dir=overhaul_career_saveSystem.getSaveRootDirectory()..slot..'/streetChallengesLedger/';overhaul_career_saveSystem.getSaveWriter().mkdir(dir)
  journal=journalFactory.new({readAll=function()
    local list={}
    for _,file in ipairs(FS:findFiles(dir,'*.json',0,false,false) or {}) do
      if file:match('/%d+%.json$') then local r=jsonReadFile(file);if not r then return nil,'Unreadable challenge ledger.' end;list[#list+1]=r end
    end
    return list
  end,write=function(r)
    local file=dir..string.format('%010d',r.sequence)..'.json';overhaul_career_saveSystem.jsonWriteFileSafe(file,r,true)
    local check=jsonReadFile(file);return check and check.id==r.id and check.sequence==r.sequence and check.state==r.state
  end})
  local ok,err=journal:load();if not ok then recovering=true;errorMessage=err;return end
  recovering=true
  winBack.repairReclaimed(getfenv(1),journal,'streetChallengesTransaction')
  ledgerReady=true;recoverLedger()
end
function M.onOverhaulSaveCurrentProfile(path) overhaul_career_saveSystem.jsonWriteFileSafe(path..snapshotFile,{version=1,receipts=receipts},true) end
function M.onOverhaulActive(enabled)
  if enabled then loadCareer() else
    require('overhaul/lib/vehicles/callbacks').cancelOwner('streetChallenges','career ended')
    clearRoute();clearTask();removeWaiting();handover=nil;handoverCallback=nil;pending=nil;active=nil;offer=nil;talk=nil;loaded=nil;journal=nil;profile=nil;uiOpen=false;recovering=false;ledgerReady=false;receipts={};winBacks={};offered={};returnMeet=nil;resultCarId=nil;table.clear(live)
  end
end
function M.onExtensionLoaded() if overhaul_career_career.isActive() then loadCareer() end end
function M.onExtensionUnloaded()
  handoverCallback=nil
  require('overhaul/lib/vehicles/callbacks').cancelOwner('streetChallenges','extension unloaded')
  clearRoute()
  removeWaiting()
  if active then overhaul_events_streetKnightsDrag.clear() end
  if pending or active then overhaul_events_streetKnightsMeet.clear();overhaul_events_streetKnightsDrag.holdTraffic(false);clearPois() end
end
function M.onClientEndMission() handoverCallback=nil;require('overhaul/lib/vehicles/callbacks').cancelOwner('streetChallenges','mission ended');clearRoute();clearTask();removeWaiting();pending=nil;offer=nil;talk=nil;active=nil;loaded=nil;uiOpen=false;returnMeet=nil;resultCarId=nil end
function M.onVehicleResetted(id) if M.isCommitted() and id==active.playerVehicleId then finish('loss','Vehicle reset') end end
function M.onVehicleSwitched(oldId,newId) if M.isCommitted() and oldId==active.playerVehicleId and newId~=oldId then finish('loss','Changed vehicle') end end
function M.onGetRawPoiListForLevel(level,elements)
  if not pending or pending.venue.level~=level then return end
  local forward=overhaul_events_streetKnightsVenues.axes({heading=pending.venue.parkingHeading or pending.venue.heading})
  elements[#elements+1]={id='streetChallengeVenue',data={type='streetChallengeVenue'},markerInfo={parkingMarker={path='streetChallengeVenue',pos=vec3(pending.venue.parking),rot=quatFromDir(vec3(forward),vec3(0,0,1)),scl=vec3(6,10,3),icon='poi_parking_rect'}}}
end
function M.onActivityAcceptGatherData(elements,activities)
  for _,elem in ipairs(elements or {}) do
    if elem.type=='streetChallengeVenue' and pending then activities[#activities+1]={heading='Car Meet Challenge',preheadings={pending.opponent.owner},props={{keyLabel='Wager',valueLabel=pending.kind=='boss' and 'Pink slips' or '$'..pending.amount}},buttonLabel='Start Race',buttonFun=M.startRace}
    end
  end
end
function M.onUpdate(dtReal,dtSim)
  if not overhaul_career_career.isActive() or (editor and editor.active) then return end
  if not loaded then loadCareer() end
  if active and active.phase=='cooldown' and not recovering then
    local player=be:getPlayerVehicle(0);cooldown=(not player or player:getVelocity():length()<1.389) and cooldown+dtSim or 0
    if cooldown>=2 then active=nil;overhaul_events_streetKnightsMeet.clear();overhaul_events_streetKnightsDrag.holdTraffic(false);clearPois();push();require("overhaul/lib/save/store").bind(overhaul_career_saveSystem).request("streetChallenges:raceComplete") end
  end
  tick=tick+dtReal;if tick<1 then return end;local elapsed=tick;tick=0
  if handover then
    local router=extensions.ui_router
    local state=router.getState and router.getState()
    local current=state and state.currentRoute
    if current and current.toRoute and current.toRoute.name~='overhaul.streetChallenges' then router.navigate('overhaul.streetChallenges') end
    push();return
  end
  if recovering and ledgerReady then
    if not active then recoverLedger();push()
    else
      local record=journal.records[active.id]
      if record and record.prize and not record.prize.pending then M.completePrize(deepcopy(record.prize)) end
    end
    return
  end
  if offer then
    age=age+elapsed
    if age>120 or not candidate(offer.shopId) then discardOffer();push()
    elseif not offer.ready and age>15 then errorMessage='Could not measure both cars. Try talking to the owner again.';discardOffer();push() end
  end
  if pending then
    pending.age=pending.age+elapsed;local id,_,veh=car()
    if pending.age>=1800 or id~=pending.carId or pending.venue.level~=getCurrentLevelIdentifier() then M.cancel();notify('Challenge cancelled before the race. No stake was charged.');return end
    local distance=(veh:getPosition()-vec3(pending.venue.parking)):length()
    if distance<=60 then clearRoute() end
    overhaul_events_streetKnightsDrag.holdTraffic(distance<=60)
    local near=distance<350
    overhaul_events_streetKnightsMeet.update(near and pending.venue or nil,nil,false)
    push();return
  end
  if active then return end
  incomingAge=incomingAge+elapsed
  if incomingAge>=60 and not offer and not uiOpen then
    incomingAge=0
    if available() then
      local _,_,player=car();local list={}
      for _,entry in ipairs(candidates()) do local npc=be:getObjectByID(entry.vehicleId)
        if npc and not offered[entry.vehicleId] and (npc:getPosition()-player:getPosition()):length()<75 then list[#list+1]=entry end
      end
      if #list>0 and math.random()<.5 then local entry=list[math.random(#list)];offered[entry.vehicleId]=true;M.challenge(entry.shopId,'incoming') end
    end
  end
end
return M
