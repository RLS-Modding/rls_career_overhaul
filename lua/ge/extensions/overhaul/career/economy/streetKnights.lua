local M={}
M.dependencies={'overhaul_career_career','overhaul_career_saveSystem','overhaul_career_garage_inventory','overhaul_career_economy_payment','overhaul_events_streetKnightsVenues','overhaul_events_streetKnightsDrag','overhaul_events_streetKnightsMeet','overhaul_events_streetKnightsRoster'}
local rules=require('overhaul/career/economy/streetKnights/rules')
local rosterPolicy=require('overhaul/career/economy/streetKnights/roster')
local pinkPolicy=require('overhaul/career/economy/streetKnights/pinkOffers')
local bossTalk=require('overhaul/career/economy/streetKnights/bossNegotiation')
local carSpend=require('overhaul/career/economy/streetKnights/carSpend')
local pinkFactory=require('overhaul/career/economy/streetKnights/pinkRuntime')
local pink=pinkFactory.new(getfenv(1))
local parking=require('overhaul/events/streetKnights/parking')
local transactionsFactory=require('overhaul/career/economy/streetKnights/transactions')
local clubPolicy=require('overhaul/career/economy/streetKnights/club')
local prizeRecovery=require('overhaul/career/economy/streetKnights/prizeRecovery')
local winBack=require('overhaul/lib/vehicles/pinkSlipWinBack')
local live=require('overhaul/career/economy/streetKnights/session')
local transactions=transactionsFactory.new(getfenv(1),live)
local raid=require('overhaul/events/streetKnights/raid').new(getfenv(1))
local progress=transactions.progress
local roster,venues={},{}
local rosterLevel,rosterError
local journal,profile,loadedPath,active,offer,selectedVenue,result,warning
local errorMessage,revision,uiOpen,tick,slowTime=nil,0,false,0,0
local recovering=false
local settleRetryIn
local handover,handoverCallback
local parkReleaseIn
local bossToken,talkRandom=0,nil
local spendCache={}
local signupSeen
local signupMarkersOpen
local meetKey
local locationNotifiedNight,locationReadyIn,locationFading=nil,2,false
local meetRoute
local function clearMeetRoute()
  if not meetRoute then return end
  local route=meetRoute;meetRoute=nil
  local ownership=require("overhaul/lib/platform/capabilities").get("groundMarkerOwnership")
  if ownership then ownership.release("streetKnights") end
  local target=core_groundMarkers and core_groundMarkers.getTargetPos and core_groundMarkers.getTargetPos()
  if not target or (target-vec3(route.target)):length()>1 then return end
  if core_groundMarkers.clearOwnedPath then core_groundMarkers.clearOwnedPath(route.token)
  else core_groundMarkers.setPath(nil) end
end
local clubId='no_prep_knights'
local club=transactions.club
local function copy(t) return deepcopy(t) end
local function money() return overhaul_career_economy_playerAttributes.getAttributeValue('money') end
local dev={}
local function devTools(validateNow) return overhaul_shell_extensionManager and overhaul_shell_extensionManager.isDevKeyValid(validateNow) or false end
local function clock()
  -- The calendar preserves weather's rounding and readiness without building forecasts.
  local weather=overhaul_world_weather and overhaul_world_weather.getCalendarState()
  local tod=not (weather and weather.minuteOfDay) and core_environment.getTimeOfDay() or nil
  return clubPolicy.clock(weather,tod,dev)
end
local function car()
  local veh=be:getPlayerVehicle(0)
  if not veh then return end
  local id=overhaul_career_garage_inventory.getInventoryIdFromVehicleId(veh:getID())
  local record=id and overhaul_career_garage_inventory.getVehicles()[id]
  if not record or record.owned==false then return end
  return id,record,veh
end
local function entry(id) for _,v in ipairs(roster) do if v.id==id then return v end end end
local function boss(tier) for _,v in ipairs(roster) do if v.role=='boss' and v.tier==tier then return v end end end
local function entryValue(e)
  if not e then return end
  local configKey=e.configKey or e.id
  local info=core_vehicles.getConfig(e.model,configKey)
  if not info then return end
  local catalog=overhaul_career_market_valueCalculator.getVehicleCatalogProfile(e.model,configKey,info)
  local base=catalog and catalog.catalogValue or info.Value or 0
  return overhaul_career_market_valueCalculator.getVehicleCatalogIntrinsicBookValue({modelName=e.model,configKey=configKey,configInfo=info,catalogBaseValue=base,age=0,mileageMeters=0})
end
-- Your car as the boss sees it: what you have spent on it, or its market value when that is higher.
-- The history scan is cached briefly per car; it also refreshes when rows are added or the car's finance identity changes.
local function carWorth(id)
  if not id then return end
  local value=overhaul_career_market_valueCalculator.getInventoryVehicleValue(id,false)
  local history=overhaul_career_economy_playerAttributes.getAttributeLog and overhaul_career_economy_playerAttributes.getAttributeLog() or {}
  local record=overhaul_career_garage_inventory.getVehicles()[id]
  local key=record and record.financeId
  local cached,now=spendCache[id],os.clock()
  if not cached or cached.rows~=#history or cached.key~=key or now-cached.at>5 then
    cached={rows=#history,key=key,at=now,spend=carSpend.total(history,key)};spendCache[id]=cached
  end
  return value and carSpend.worth(value,cached.spend),value,cached.spend
end
local function unresolved() return active and journal and journal.records[active.id] and journal.records[active.id].state=='committed' end
-- Settling a won car (recovering with a race active) still guards reset, travel and quitting, as car meets do.
function M.isCommitted() return unresolved() or handover~=nil or (recovering and active~=nil) or (overhaul_career_economy_streetChallenges and overhaul_career_economy_streetChallenges.blocksSave()) or false end
function M.blocksSave() return unresolved() or recovering or (overhaul_career_economy_streetChallenges and overhaul_career_economy_streetChallenges.blocksSave()) or false end
function M.blocksOtherRaces() return active~=nil or (uiOpen and selectedVenue~=nil) or (overhaul_career_economy_streetChallenges and overhaul_career_economy_streetChallenges.isBusy()) or false end
local function near(v,veh)
  return parking.isParked(v,veh,overhaul_events_streetKnightsVenues.axes)
end
local function nearMeet(v,veh,radius)
  radius=radius or 350
  local p=veh:getPosition()
  if (p-vec3(v.parking)):length()<radius then return true end
  local along=overhaul_events_streetKnightsVenues.project(v,p)
  local nearest=vec3(overhaul_events_streetKnightsVenues.position(v,math.max(0,math.min(v.length,along)),0))
  return (p-nearest):length()<radius
end
local function member()
  return overhaul_career_carmeets_carmeets and overhaul_career_carmeets_carmeets.isClubJoined and overhaul_career_carmeets_carmeets.isClubJoined(clubId) or false
end
local function hasMeetRSVP(venue,night)
  local rsvp=club.rsvp
  return rsvp and venue and rsvp.night==night and rsvp.venue==venue.id or false
end
local function venuePool() return clubPolicy.venuePool(venues) end
local venueCache={enabled={}}
local function tonight(night)
  local developer=devTools()
  local changed=venueCache.count~=#venues
  for i,v in ipairs(venues)do
    local enabled=v.enabled~=false
    if venueCache.enabled[i]~=enabled then changed=true;venueCache.enabled[i]=enabled end
  end
  venueCache.count=#venues
  if changed or venueCache.venues~=venues or venueCache.night~=night or venueCache.developer~=developer or venueCache.devNight~=dev.night or venueCache.devVenue~=dev.venue or venueCache.cleared~=dev.cleared then
    venueCache.venues=venues;venueCache.night=night;venueCache.developer=developer;venueCache.devNight=dev.night;venueCache.devVenue=dev.venue;venueCache.cleared=dev.cleared
    venueCache.value=clubPolicy.tonight(venues,night,dev,developer)
  end
  return venueCache.value
end
local function venueById(id) return clubPolicy.venueById(venues,id) end
local function spotName(v) return clubPolicy.spotName(v) end
local function notify(channel,payload)
  if not overhaul_phone_apps_layout and extensions and extensions.load then pcall(extensions.load,'overhaul_phone_apps_layout') end
  if not (overhaul_phone_apps_layout and overhaul_phone_apps_layout.fireNotification) then return false end
  payload.title=payload.title or 'No Prep Knights';payload.source=payload.source or 'No Prep Knights'
  payload.route=payload.route or 'phone-no-prep-knights';payload.ttl=10
  return overhaul_phone_apps_layout.fireNotification(channel,payload)
end
local function choices()
  local pool={} for _,e in ipairs(roster) do if e.tier==progress.tier and e.role=='wager' then pool[#pool+1]=e end end
  local res={} for i=1,math.min(3,#pool) do
    local e=copy(pool[(progress.rotation+i-1)%#pool+1]);e.offer=rules.offer(e,progress.tier,i,revision);res[#res+1]=e
  end
  local _,night=clock()
  for _,lost in ipairs(transactions.winBacks)do
    if lost.night<night then
      local e=winBack.opponent(lost)
      e.offer={id=e.id,revision=revision,kind='pink',amount=0,status='accepted',winBackId=lost.id}
      res[math.max(1,#res)]=e;break
    end
  end
  return res
end
local pinkRecord
local function eligible(isBoss,titleAllowed,challenge)
  if raid.isPursuing() then return false,'Lose the police before racing.' end
  if overhaul_career_economy_streetChallenges and overhaul_career_economy_streetChallenges.isBusy() then return false,'Finish your car meet challenge first.' end
  if not loadedPath or transactions.level~=getCurrentLevelIdentifier() or not journal or errorMessage then return false,errorMessage or 'Career state is not ready.' end
  if isBoss and rosterError then return false,rosterError end
  if active then return false,'Finish your race and slow down first.' end
  if not titleAllowed and progress.defeated>=5 then
    if challenge==nil then challenge=pinkRecord() end
    if challenge and challenge.titleDefense and (challenge.state=='available' or challenge.state=='revealed') then
      return false,'Race your title challenger before entering another Knights race.'
    end
  end
  if not member() then return false,'Join No Prep Knights in the Car Meet app first.' end
  if overhaul_events_session and overhaul_events_session.mActiveRace then return false,'Finish your current event first.' end
  if gameplay_missions_missionManager and gameplay_missions_missionManager.getForegroundMissionId() then return false,'Finish your current mission first.' end
  local id,record,veh=car()
  if not near(selectedVenue,veh) then return false,'Park at the signup spot.' end
  local hour,night=clock()
  if not hasMeetRSVP(selectedVenue,night) then return false,'RSVP to the meet in the Car Meet app first.' end
  if isBoss and club.bossWalked and club.bossWalked.night==night and club.bossWalked.tier==progress.tier then
    local b=boss(progress.tier);return false,(b and b.name or 'The boss')..' walked away. Come back next meet.'
  end
  local value=id and (isBoss and carWorth(id) or overhaul_career_market_valueCalculator.getInventoryVehicleValue(id,false))
  return rules.entry(progress,hour,night,value,entryValue(boss(progress.tier)),isBoss)
end
local function ladder()
  local rivals={} for tier=1,5 do local e=boss(tier);rivals[tier]={tier=tier,name=tier<=progress.tier and e and e.name or 'Unknown rival',
    thumbnail=tier<=progress.tier and e and e.thumbnail or nil,defeated=tier<=progress.defeated} end
  return rivals
end
pinkRecord=function(notificationOnly)
  if not loadedPath or transactions.level~=getCurrentLevelIdentifier() or not profile or not journal or recovering or errorMessage or not member() or dev.night then return end
  local hour,night=clock();local v=tonight(night)
  local player=be:getPlayerVehicle(0)
  local ensure=notificationOnly and pink.notificationOffer or pink.ensure
  return ensure(pink,profile,progress,hour,night,v,roster,entryValue,journal,transactions.receipts,not active and v and player and nearMeet(v,player))
end
local function playerConfig(veh)
  local data=veh and core_vehicle_manager.getVehicleData(veh:getID())
  return data and pinkPolicy.canonical(data.config)
end
local function eligiblePink(r)
  local ok,why=eligible(false,r and r.titleDefense);if not ok then return false,why end
  local hour,night=clock()
  if not r or (r.state~='available' and r.state~='revealed') or (not r.titleDefense and r.night~=night) or not rules.isOpen(hour)
    or not selectedVenue or r.venue.id~=selectedVenue.id or r.venue.level~=selectedVenue.level then return false,'This offer is not available at this meet.' end
  if not pink:valid(r,selectedVenue,roster) then return false,'Build or venue changed; offer withdrawn.' end
  local id=car();local value=id and overhaul_career_market_valueCalculator.getInventoryVehicleValue(id,false)
  if not value or value<r.opponentValue*rules.minimumValueFraction then return false,'Your car does not meet the displayed minimum value.' end
  return true
end
function M.getState()
  local hour,night=clock();local id,record=car();local b=boss(progress.tier)
  local worth,marketValue,spend=carWorth(id)
  local pr=pinkRecord();local canPink,pinkWhy=eligiblePink(pr)
  local shownOpponent=offer and (offer.opponent or entry(offer.id))
  if shownOpponent and offer.kind=='pink' then
    shownOpponent={id=shownOpponent.id,name=shownOpponent.name,model=shownOpponent.model,description=shownOpponent.description,thumbnail=shownOpponent.thumbnail}
  end
  local can,why=eligible(false,false,pr or false);local canBoss,bossWhy,bossBlock=eligible(true,false,pr or false)
  local rivals=ladder()
  local v=active and (venueById(active.venue.id) or active.venue) or selectedVenue or tonight(night)
  local venue=v and {name=spotName(v),level=clubPolicy.levelName(v.level or getCurrentLevelIdentifier()),length=v.length,laneWidth=v.laneWidth}
  return {title='No Prep Knights',hour=hour,night=night,open=rules.isOpen(hour),openTime=rules.openTimeText,closeTime=rules.closeTimeText,balance=money(),progress=copy(progress),
    car=id and {name=record.niceName,value=marketValue,spend=spend,worth=worth} or nil,
    boss=b and copy(b),bossValue=entryValue(b),minimumValue=(entryValue(b) or 0)*rules.bossFloorFraction,rivals=rivals,canRace=can,reason=why,canBoss=canBoss,bossReason=bossWhy,bossTalkOnly=bossBlock=='floor',
    pinkOffer=pink:public(pr),canPink=canPink,pinkReason=pinkWhy,titleHolderName=progress.titleHolderId and entry(progress.titleHolderId) and entry(progress.titleHolderId).name,
    opponents=choices(),offer=offer and {id=offer.id,revision=offer.revision,kind=offer.kind,amount=offer.amount,status=offer.status,countered=offer.countered,cap=offer.cap,minimumValue=offer.minimumValue,titleDefense=offer.titleDefense,
      winBackId=offer.winBackId,vehicleName=offer.opponent and offer.opponent.originalVehicle and offer.opponent.originalVehicle.niceName,
      bossCash=offer.bossCash,probing=offer.probe~=nil,negotiation=offer.kind=='boss' and bossTalk.public(offer.negotiation) or nil},opponent=shownOpponent and copy(shownOpponent),race=active and {phase=active.phase,kind=active.kind,amount=active.amount,bossCash=active.bossCash},
    prizePending=active and recovering and journal.records[active.id] and journal.records[active.id].outcome=='win' or false,
    handover=handover and {name=active.opponent.name,bossCash=active.bossCash},result=result and copy(result),warning=warning and {label=warning.label,stake=active and (rules.isCarStake(active.kind) and 'your car'..((active.bossCash or 0)>0 and ' and $'..active.bossCash or '') or '$'..active.amount)},error=errorMessage,
    distance=v and v.length or 201.168,venue=venue}
end
local function push() if uiOpen then guihooks.trigger('StreetKnightsState',M.getState()) end end
local function fail(msg) guihooks.trigger('StreetKnightsError',msg);return false,msg end
function M.open(venueId)
  if raid.isPursuing() then return fail('Lose the police before returning to the meet.') end
  if handover then uiOpen=true;extensions.ui_router.navigate('overhaul.streetKnights');push();return true end
  if overhaul_career_economy_streetChallenges and overhaul_career_economy_streetChallenges.isBusy() then return fail('Finish or cancel your car meet challenge first.') end
  if not overhaul_career_career.isActive() then return false end
  if not unresolved() then
    if not member() then return fail('Join No Prep Knights in the Car Meet app first.') end
    local _,_,veh=car();local hour,night=clock();local v=tonight(night);selectedVenue=nil
    if not rules.isOpen(hour) then return fail('The meet opens at '..rules.openTimeText..'.') end
    if not v or (venueId and v.id~=venueId) or not near(v,veh) then return fail('Park at a Street Knights signup spot.') end
    if not hasMeetRSVP(v,night) then return fail('RSVP to the meet in the Car Meet app first.') end
    selectedVenue=v
  end
  uiOpen=true
  clearMeetRoute()
  if result and club.last then club.last.seen=true end
  if not unresolved() then guihooks.trigger('StreetKnightsHud',{}) end
  -- A refused navigation (another screen holding a protected navigation) never mounts
  -- the screen, so nothing would ever report it closed.
  local nav=extensions.ui_router.navigate('overhaul.streetKnights')
  if nav and (nav.success==false or nav.result==false) then uiOpen=false;return false end
  push();return true
end
function M.close()
  if handover then push();return false end
  uiOpen=false
  guihooks.trigger('ChangeState',{state='play'})
end
-- The phone, map and other menus can replace the screen without close(); a stale
-- uiOpen would stop the signup prompt from ever opening again. During a car handover
-- the screen is forced back, so uiOpen stays true.
function M.screenClosed() if not handover then uiOpen=false end end
function M.requestState() if raid.isPursuing() then guihooks.trigger('ChangeState',{state='play'});return end;uiOpen=true;push() end
function M.inspectPinkOffer(id)
  local r=pinkRecord()
  if not r or r.id~=id then return fail('Offer unavailable.') end
  result=nil;push();return true
end
function M.revealPinkClue(id,offerRevision,category)
  local r=pinkRecord()
  local ok,why=eligible(false,r and r.titleDefense);if not ok then return fail(why) end
  if not r or r.id~=id or not r.venue or not selectedVenue or r.venue.id~=selectedVenue.id or r.venue.level~=selectedVenue.level then return fail('Offer unavailable at this meet.') end
  local saved,err=pink:mutate(id,offerRevision,'reveal',category)
  if not saved then return fail(err) end
  push();return true
end
function M.declinePinkOffer(id,offerRevision)
  local r=pinkRecord();if not r or r.id~=id or active then return fail('Offer unavailable.') end
  local saved,err=pink:mutate(id,offerRevision,'decline')
  if not saved then return fail(err) end
  if offer and offer.kind=='pink' then offer=nil end
  push();return true
end
function M.acceptPinkOffer(id,offerRevision)
  local r=pinkRecord();local ok,why=eligiblePink(r);if not ok then return fail(why) end
  if r.id~=id or r.revision~=offerRevision or r.state~='revealed' then return fail('Choose one clue before reviewing the stake.') end
  local carId,_,veh=car()
  offer={id=r.opponent.id,offerId=r.id,revision=r.revision,kind='pink',amount=0,status='accepted',carId=carId,playerConfig=playerConfig(veh),minimumValue=r.opponentValue*rules.minimumValueFraction,titleDefense=r.titleDefense}
  result=nil;push();return true
end
function M.selectOpponent(id)
  local ok,err=eligible(false);if not ok then return fail(err) end
  for _,e in ipairs(choices()) do if e.id==id then
    offer=copy(e.offer)
    if e.winBackId then
      local carId,_,veh=car()
      offer.opponent=copy(e);offer.opponent.offer=nil;offer.carId=carId;offer.playerConfig=playerConfig(veh)
    end
    result=nil;push();return true
  end end
  return fail('That challenger is no longer available.')
end
function M.counter(amount,offerRevision)
  local ok,err=eligible(false);if not ok then return fail(err) end
  if not offer or offer.kind~='cash' or offer.revision~=offerRevision then return fail('Offer changed. Choose again.') end
  ok,err=rules.counter(offer,amount,money());if not ok then return fail(err) end
  push();return true
end
function M.acceptOffer(offerRevision)
  local ok,err=eligible(false);if not ok then return fail(err) end
  if not offer or offer.revision~=offerRevision or offer.status=='declined' then return fail('Offer unavailable.') end
  offer.status='accepted';push();return true
end
-- Measures a car's power and weight for the boss's read on who should win; the reply arrives in M.receiveBossPerformance.
local function bossProbe(veh,token)
  local request=require('overhaul/lib/vehicles/callbacks').open('streetKnightsBossPerformance',{owner='streetKnights',vehId=veh:getID(),timeout=15,endsWith={'map','profile'}})
  if not request then return false end
  veh:queueLuaCommand("local p=0; for _,e in ipairs(powertrain.getDevicesByCategory('engine') or {}) do p=p+(e.maxPower or 0) end; obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').reply("..request..",'streetKnightsBossPerformance',"..serialize(token..',').."..obj:getID()..','..serialize({power=p,weight=obj:calcBeamStats().total_weight})))")
  return true
end
-- Opens the talk once both cars are measured, or when the measurement times out (the boss then calls it even).
local function startBossTalk()
  local probe=offer.probe;offer.probe=nil
  local _,night=clock()
  talkRandom=pinkPolicy.random(profile..':boss:'..night..':'..progress.tier)
  local n=bossTalk.open({carValue=offer.carValue,bossValue=offer.bossValue,odds=bossTalk.odds(probe.player,probe.boss),random=talkRandom})
  local saved=club.bossTalk
  if saved and saved.night==night and saved.tier==progress.tier then
    local same=saved.carValue==offer.carValue and saved.bossValue==offer.bossValue
    bossTalk.resume(n,{patience=saved.patience,ask=same and saved.ask or nil,final=same and saved.final},talkRandom)
  end
  offer.negotiation=n
  if n.status=='agreed' then offer.status='accepted';offer.bossCash=0 end
end
function M.challengeBoss()
  -- A car under the value floor can still walk up; the boss just refuses (and says why).
  local ok,err,block=eligible(true);if not ok and block~='floor' then return fail(err) end
  local b=boss(progress.tier);local carId,_,veh=car()
  bossToken=bossToken+1
  local shownId=overhaul_events_streetKnightsMeet.getBossVehicleId and overhaul_events_streetKnightsMeet.getBossVehicleId()
  local bossVeh=shownId and be:getObjectByID(shownId)
  offer={id=b.id,revision=revision,kind='boss',amount=0,bossCash=0,status='negotiating',carId=carId,playerConfig=playerConfig(veh),
    carValue=carWorth(carId),bossValue=entryValue(b),
    probe={token=bossToken,playerId=veh:getID(),bossId=shownId,wait=3}}
  result=nil
  if block=='floor' or not (bossVeh and bossProbe(veh,bossToken) and bossProbe(bossVeh,bossToken)) then startBossTalk() end
  push();return true
end
function M.receiveBossPerformance(token,id,stats)
  local probe=offer and offer.kind=='boss' and offer.probe
  if not probe or probe.token~=token then return end
  if id==probe.playerId then probe.player=stats elseif id==probe.bossId then probe.boss=stats else return end
  if probe.player and probe.boss then startBossTalk();push() end
end
local function bossTalkStep(offerRevision,step)
  local ok,err=eligible(true);if not ok then return fail(err) end
  local n=offer and offer.kind=='boss' and offer.negotiation
  if not n or offer.revision~=offerRevision then return fail('Offer changed. Talk to the boss again.') end
  local done,why=step(n);if not done then return fail(why) end
  local _,night=clock()
  if n.status=='agreed' then offer.status='accepted';offer.bossCash=n.cash
  elseif n.status=='walked' then club.bossWalked={night=night,tier=progress.tier} end
  club.bossTalk={night=night,tier=progress.tier,patience=n.patience,ask=n.ask,final=n.status=='final',carValue=n.carValue,bossValue=n.bossValue}
  revision=revision+1;offer.revision=revision;push();return true
end
-- Puts `amount` cash on top of your car; it is only paid if you lose.
function M.bossOffer(amount,offerRevision) return bossTalkStep(offerRevision,function(n) return bossTalk.offer(n,tonumber(amount),money(),talkRandom) end) end
function M.acceptBossAsk(offerRevision) return bossTalkStep(offerRevision,function(n) return bossTalk.acceptAsk(n,money(),talkRandom) end) end
function M.cancelOffer() if unresolved() then return end offer=nil;push() end
local function reconcileRecord(r)
  local sceneId=active and active.id==r.id and overhaul_events_streetKnightsDrag.getOpponentId()
  local ok,err=transactions:reconcile(r,sceneId)
  if active and active.id==r.id then active.prizeInWorld=r.prizeInWorld end
  return ok,err
end
function M.commit(offerRevision)
  local ok,err=eligible(offer and offer.kind=='boss',offer and offer.titleDefense);if not ok then return fail(err) end
  if not offer or not rules.validKind(offer.kind) or offer.revision~=offerRevision or offer.status~='accepted' then return fail('Accept the current terms first.') end
  local pr
  if offer.winBackId then
    local available=false
    for _,e in ipairs(choices())do if e.winBackId==offer.winBackId then available=true;break end end
    local carId,_,veh=car()
    if not available then return fail('This win-back race is no longer available.') end
    if carId~=offer.carId or playerConfig(veh)~=offer.playerConfig then offer=nil;push();return fail('Your entered car changed. Review the stake again.') end
  elseif offer.kind=='pink' then
    pr=pinkRecord();local ready,why=eligiblePink(pr);if not ready then return fail(why) end
    local carId,_,veh=car()
    if pr.id~=offer.offerId or pr.revision~=offerRevision or pr.state~='revealed' then return fail('Offer changed.') end
    if carId~=offer.carId or playerConfig(veh)~=offer.playerConfig then offer=nil;push();return fail('Your entered car changed. Review the stake again.') end
  elseif offer.kind=='boss' then
    local carId,_,veh=car()
    if carId~=offer.carId or playerConfig(veh)~=offer.playerConfig then offer=nil;push();return fail('Your entered car changed. Talk to the boss again.') end
    if money()<(offer.bossCash or 0) then return fail('You no longer have the cash you offered.') end
  end
  if (overhaul_career_saveSystem.isSaveInFlight or overhaul_career_saveSystem.isSaveBusy)() then return fail('A career save is finishing. Try again in a moment.') end
  if offer.kind=='cash' and money()<offer.amount then return fail('Insufficient funds.') end
  local id,record,veh=car();local hour,night=clock()
  local opponent=offer.opponent or entry(offer.id)
  if not opponent or (type(opponent.config)=='string' and not FS:fileExists(opponent.config)) then return fail('Opponent configuration unavailable.') end
  local valid,why=overhaul_events_streetKnightsDrag.validate(selectedVenue,veh:getID())
  if not valid then return fail(why) end
  local order=journal.sequence+1
  local race={id=profile..'_'..order..'_'..os.time(),order=order,kind=offer.kind,amount=offer.amount,carId=id,
    playerVehicleId=veh:getID(),opponent=copy(opponent),night=night,tier=progress.tier,venue=copy(selectedVenue),phase='approach',
    offerId=pr and pr.id,opponentConfigSnapshot=pr and copy(pr.fullConfigSnapshot),titleDefense=pr and pr.titleDefense,titleSlot=pr and pr.titleSlot,reclaimTitle=pr and pr.reclaimTitle,
    winBackId=offer.winBackId,winBackOwnerId=opponent.winBackOwnerId,
    bossCash=offer.kind=='boss' and (offer.bossCash or 0)>0 and offer.bossCash or nil}
  local durable,writeErr=journal:commit(race)
  if not durable then return fail(writeErr) end
  active=race;reconcileRecord(durable)
  if pr then pink:committed(pr,race.id) end -- durable wager remains authoritative if this write fails
  overhaul_events_streetKnightsMeet.update(selectedVenue,nil,false)
  local called,started,startErr=pcall(overhaul_events_streetKnightsDrag.start,race)
  if not called or not started then M.systemFault('opponentInitialization',called and startErr or started) end
  M.close();return true
end
function M.onOverhaulAddedVehiclePartsToInventory(id)
  local record=overhaul_career_garage_inventory.getVehicles()[id]
  if record and record.streetKnightsStorePending then record.streetKnightsStorePending=nil;overhaul_career_garage_inventory.removeVehicleObject(id);overhaul_career_garage_inventory.setVehicleDirty(id) end
end
local function remember(outcome,reason)
  result={outcome=outcome,reason=reason,kind=active.kind,amount=active.amount,opponent=active.opponent.name,venue=spotName(active.venue),prizeInWorld=active.prizeInWorld,
    progressCredit=active.kind=='pink' and not active.titleDefense and not active.winBackId and outcome=='win' and 1 or 0,transactionId=active.id,titleDefense=active.titleDefense,reclaimTitle=active.reclaimTitle,bossCash=active.bossCash,winBackId=active.winBackId}
  local raceClub=transactions:mapState(active.venue.level).club
  raceClub.last=copy(result);raceClub.last.night=active.night;raceClub.last.spot=spotName(active.venue);raceClub.last.seen=false
end
local function awaitHandover(r)
  handover=r.id;active=copy(r.race);active.phase='handover';recovering=true;warning=nil;offer=nil;errorMessage=nil
  remember('loss',r.reason)
  local id=overhaul_career_garage_inventory.getVehicleIdFromInventoryId(active.carId)
  local veh=id and be:getObjectByID(id)
  if veh and not raid.isPursuing() then veh:queueLuaCommand("input.event('throttle',0,1);input.event('brake',1,1);input.event('parkingbrake',1,1)") end
  overhaul_events_streetKnightsDrag.stop(false,'loss',r.reason);guihooks.trigger('StreetKnightsHud',{})
  if not raid.isPursuing() then uiOpen=true;extensions.ui_router.navigate('overhaul.streetKnights');push() end;return true
end
function M.giveUpCar()
  if not handover then return false end
  local r=copy(journal.records[handover]);r.handoverConfirmed=true
  local durable,err=journal:write(r);if not durable then return fail(err) end
  local ok,why=reconcileRecord(durable);if not ok then return fail(why) end
  handover=nil;recovering=false;errorMessage=nil;active.phase='cooldown';slowTime=0;revision=revision+1
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
  if not journal.records[active.id].decidedOutcome then
    local noted=journal:decide(active.id,outcome,reason,prize)
    if not noted then errorMessage='Could not persist the race decision.';push();return false end
  end
  local durable,err=journal:lock(active.id,outcome,reason,prize)
  if not durable then errorMessage=err;push();return false end
  if rules.isCarStake(durable.race.kind) and outcome=='loss' then return awaitHandover(durable) end
  recovering=true
  local ok,applyErr=reconcileRecord(durable)
  recovering=not ok
  if not ok then errorMessage=applyErr;push();return false end
  errorMessage=nil;remember(outcome,reason)
  active.phase='cooldown';warning=nil;offer=nil;revision=revision+1
  overhaul_events_streetKnightsDrag.stop(outcome=='win' and rules.isCarStake(active.kind),outcome,reason)
  push();return true
end
function M.rememberDecision(outcome,reason,prize)
  if not active or not journal then return false end
  if outcome~='win' and outcome~='loss' and outcome~='void' then return false end
  local existing=journal.records[active.id]
  if not existing or existing.state~='committed' then return existing~=nil end
  local durable=journal:decide(active.id,outcome,reason,prize)
  return durable~=nil
end
function M.raceFinished(outcome,reason,prize)
  if outcome~='win' and outcome~='loss' then return false end
  return finish(outcome,reason,prize)
end
function M.lockPendingPrize(outcome,reason,prize)
  if not unresolved() then return false end
  prize.pending=true
  if not journal.records[active.id].decidedOutcome then
    local noted=journal:decide(active.id,outcome,reason,prize)
    if not noted then errorMessage='Could not persist the race decision.';return false end
  end
  local r,err=journal:lock(active.id,outcome,reason,prize)
  if not r then errorMessage=err;return false end
  recovering=true;errorMessage=nil;active.phase='cooldown'
  return true
end
function M.prizePaths()
  if not active then return end
  local dir=overhaul_career_saveSystem.getSaveRootDirectory()..profile..'/streetKnightsLedger/'
  return dir..active.id..'_conditions.json',dir..active.id..'_damage.json'
end
function M.completePrize(prize)
  if not active or not recovering then return false end
  prize.pending=nil
  local r,err=journal:attachPrize(active.id,prize)
  if not r then errorMessage=err;return false end
  local ok,why=reconcileRecord(r)
  if not ok then errorMessage=why;return false end
  recovering=false;errorMessage=nil;remember('win',r.reason)
  warning=nil;offer=nil;revision=revision+1
  overhaul_events_streetKnightsDrag.stop(true,'win',r.reason);push();return true
end
function M.prizeCaptureFailed()
  errorMessage='Your win is saved. Retrying the prize condition capture.'
  push()
end
function M.recoverPrizeCapture(prize)
  return M.completePrize(prizeRecovery.resolve(prize,jsonReadFile))
end
function M.systemFault(code,detail)
  if not rules.knownFaults[code] then return false end
  log('E','streetKnights',code..': '..tostring(detail))
  return finish('void','Race cancelled: verified system fault. Your stake was returned.')
end
function M.setPhase(phase) if unresolved() then active.phase=phase;push() end end
function M.requestAction(label,callback)
  if handover then
    if callback and not handoverCallback then handoverCallback=callback end
    M.open();return true
  end
  if overhaul_career_economy_streetChallenges and overhaul_career_economy_streetChallenges.blocksSave() then return overhaul_career_economy_streetChallenges.requestAction(label,callback) end
  -- The won car is handed over once the race has stopped it; leaving before then would cut the hand-over short.
  if recovering and active then
    local message='Your race result is still being settled. Try again in a few seconds.'
    fail(message)
    if not uiOpen and ui_message then ui_message(message,5,'streetKnights','warning') end
    return true
  end
  if not unresolved() then if callback then callback() end return false end
  warning={label=label,callback=callback};uiOpen=true;extensions.ui_router.navigate('overhaul.streetKnights');push();return true
end
function M.abandon() return M.requestAction('abandon this race') end
function M.requestRecovery(vehicleId,alternate)
  return M.requestAction('recover your car',function()
    local veh=be:getObjectByID(vehicleId)
    if veh then veh:queueLuaCommand("extensions.unload('overhaulStreetKnightsRaceGuard'); recovery.startRecovering("..tostring(alternate==true).."); recovery.stopRecovering()") end
  end)
end
function M.requestHomeRecovery(vehicleId)
  return M.requestAction('reset to your home position',function()
    local veh=be:getObjectByID(vehicleId)
    if veh then veh:queueLuaCommand("extensions.unload('overhaulStreetKnightsRaceGuard'); recovery.loadHome()") end
  end)
end
function M.cancelAction() warning=nil;M.close() end
function M.confirmAction()
  if not warning or not unresolved() then return end
  local callback=warning.callback
  if finish('loss','Forfeited') then
    if handover then handoverCallback=callback else if callback then callback() end M.close() end
  end
end
function M.onOverhaulSaveCurrentProfile(path) transactions:save(path) end
local function loadCareer(retry)
  local slot,path=overhaul_career_saveSystem.getCurrentProfile()
  if not slot or not path then return end
  local level=getCurrentLevelIdentifier()
  if not level then return end
  -- Keep loaded records on temporary settlement failure; retry=true re-runs ledger recovery without wiping state.
  if loadedPath and not retry and transactions.level==level then return end
  if overhaul_career_saveSystem.isSaveBusy and overhaul_career_saveSystem.isSaveBusy() then return end
  local wasRecovering=recovering
  local ok,err=transactions:load(slot,path)
  profile=slot;loadedPath=path
  if not retry then locationNotifiedNight=nil;locationReadyIn=2 end
  pink=pinkFactory.new(getfenv(1),transactions.legacyLevel)
  progress,club,journal=transactions.progress,transactions.club,transactions.journal
  spendCache={}
  raid.configure(slot)
  if club.last and not club.last.seen then result=copy(club.last) end
  errorMessage=err;recovering=transactions.recovering
  if transactions.handover then awaitHandover(transactions.handover) end
  if wasRecovering and retry and not recovering and not errorMessage and active and not handover then
    local reason=(club.last and club.last.reason) or 'Prize recovered'
    remember('win',reason)
    warning=nil;offer=nil;active.phase='cooldown';revision=revision+1
    overhaul_events_streetKnightsDrag.stop(true,'win',reason)
    push()
  end
  if overhaul_events_streetKnightsSafety then overhaul_events_streetKnightsSafety.sync() end
end
function M.onStreetKnightsVenuesChanged()
  local level=getCurrentLevelIdentifier();venues=level and overhaul_events_streetKnightsVenues.list(level) or {}
  if rosterLevel~=level then
    roster,rosterError=rosterPolicy.load(level,jsonReadFile,FS);rosterLevel=level
    if rosterError then log('E','streetKnights',rosterError) end
  end
  if gameplay_rawPois then gameplay_rawPois.clear() end
end
function M.onGetRawPoiListForLevel(level,elements)
  if overhaul_career_economy_streetChallenges and overhaul_career_economy_streetChallenges.ownsVenue() then return end
  if not overhaul_career_career.isActive() or level~=getCurrentLevelIdentifier() or not rules.isOpen(clock()) or not member() then return end
  local _,night=clock();local v=tonight(night)
  if v then
    local id='streetKnights_signup_'..v.id
    local f=overhaul_events_streetKnightsVenues.axes({heading=v.parkingHeading or v.heading})
    elements[#elements+1]={id=id,data={id=id,type='streetKnightsSignup',venueId=v.id},markerInfo={parkingMarker={
      path=id,pos=vec3(v.parking),rot=quatFromDir(vec3(f),vec3(0,0,1)),
      scl=vec3(v.parkingWidth or 4,v.parkingLength or 8,3),icon='poi_parking_rect'}}}
  end
end
function M.onOverhaulActive(enabled)
  if enabled then loadCareer();M.onStreetKnightsVenuesChanged()
  else raid.clear();clearMeetRoute();handover=nil;handoverCallback=nil;overhaul_events_streetKnightsDrag.clear();overhaul_events_streetKnightsMeet.clear();table.clear(live);loadedPath=nil;profile=nil;journal=nil;active=nil;offer=nil;warning=nil;uiOpen=false end
end
function M.onExtensionLoaded()
  if overhaul_events_streetKnightsSafety then overhaul_events_streetKnightsSafety.onExtensionLoaded()
  else extensions.load('overhaul_events_streetKnightsSafety') end
  roster,rosterError=rosterPolicy.load(getCurrentLevelIdentifier(),jsonReadFile,FS);rosterLevel=getCurrentLevelIdentifier()
  if rosterError then log('E','streetKnights',rosterError) end
  if overhaul_career_career.isActive() then M.onOverhaulActive(true) end
end
function M.onExtensionUnloaded()
  raid.clear()
  clearMeetRoute()
  if overhaul_events_streetKnightsSafety then overhaul_events_streetKnightsSafety.clear() end
  overhaul_events_streetKnightsMeet.clear()
  overhaul_events_streetKnightsDrag.clear()
end
function M.resultMessage(r) return clubPolicy.resultMessage(r) end
function M.getClubState()
  local pr=pinkRecord()
  local hour,night=clock();local v=active and venueById(active.venue.id) or tonight(night)
  local last=club.last and copy(club.last)
  if last then last.line=M.resultMessage(last).message end
  return {member=member(),hour=hour,open=rules.isOpen(hour),openTime=rules.openTimeText,closeTime=rules.closeTimeText,spot=spotName(v),progress=copy(progress),rivals=ladder(),
    boss=boss(progress.tier) and copy(boss(progress.tier)),nextRivalReady=night>=progress.nextNight,racing=active~=nil,last=last,pinkOffer=pink:public(pr),titleHolderName=progress.titleHolderId and entry(progress.titleHolderId) and entry(progress.titleHolderId).name}
end
local function meetVenue()
  local hour,night=clock()
  return clubPolicy.meetVenue(venues,active,hour,night,dev,devTools())
end
function M.getMeetInvite()
  if not overhaul_career_career.isActive() or not member() then return end
  local v,hour,night=meetVenue()
  local invite=clubPolicy.getMeetInvite(v,hour,night,active,getCurrentLevelIdentifier())
  if invite then invite.devAccess=devTools();invite.attending=hasMeetRSVP(v,night) end
  return invite
end
function M.rsvpMeet()
  if not overhaul_career_career.isActive() or not member() then return false end
  local v,_,night=meetVenue()
  if not v then return fail('No race invite is available.') end
  if not hasMeetRSVP(v,night) then club.rsvp={night=night,venue=v.id} end
  if overhaul_career_carmeets_carmeets and overhaul_career_carmeets_carmeets.requestRSVPData then overhaul_career_carmeets_carmeets.requestRSVPData() end
  require("overhaul/lib/save/store").bind(overhaul_career_saveSystem).request("streetKnights:devReset");return true
end
-- Venues on the current map that a meet can use, for the developer venue picker.
function M.debugVenues()
  local list={}
  for _,v in ipairs(venuePool()) do list[#list+1]={value=v.id,label=spotName(v)} end
  return list
end
-- Without venueId the invite moves to the next venue; with one, to that venue on this map.
function M.debugRaceInvite(forceRaid,venueId)
  if not devTools(true) or not overhaul_career_career.isActive() then return false end
  if active or recovering or raid.isPursuing() then return fail('Finish your current race or pursuit first.') end
  local pool=venuePool()
  if #pool==0 then return false end
  local _,night=clock()
  local pick
  if venueId~=nil then
    for _,v in ipairs(pool) do if v.id==venueId then pick=v end end
    if not pick then return fail('That venue is not available on this map.') end
  else
    local current=dev.last or (tonight(night) or {}).id
    local index=0
    for i,v in ipairs(pool) do if v.id==current then index=i end end
    pick=pool[index%#pool+1]
  end
  if not raid.devInvite(pick,night,forceRaid==true) then return fail('Could not prepare the developer raid selection.') end
  dev.night=night;dev.venue=pick.id;dev.last=pick.id;dev.cleared=nil
  club.locationNight=nil;signupSeen=nil;tick=1
  if gameplay_rawPois then gameplay_rawPois.clear() end
  return true
end
function M.debugClearRace()
  if not devTools(true) then return false end
  raid.clear()
  if unresolved() then finish('void','Race cleared from dev tools. Your stake was returned.') end
  overhaul_events_streetKnightsDrag.clear()
  active=nil;offer=nil;selectedVenue=nil;result=nil;warning=nil;recovering=false;signupSeen=nil
  local _,night=clock()
  local shown=tonight(night)
  if shown then dev.last=shown.id end
  dev.night=nil;dev.venue=nil;dev.cleared=night
  if gameplay_rawPois then gameplay_rawPois.clear() end
  if uiOpen then M.close() end
  guihooks.trigger('StreetKnightsHud',{})
  return true
end
function M.debugGoToRace()
  if not devTools(true) or not overhaul_career_career.isActive() then return false end
  if active or recovering or (overhaul_career_economy_streetChallenges and overhaul_career_economy_streetChallenges.isBusy()) then return fail('Finish your current race first.') end
  if gameplay_walk and gameplay_walk.isWalking() then return fail('Enter intended car.') end
  local id,_,veh=car()
  if not id or not veh then return fail('Enter intended car.') end
  local v=meetVenue()
  if not v or not v.parking then return fail('No race venue is available.') end
  local hour=clock()
  -- Only jump to lights-out when the meet is closed. Resetting the clock while already open
  -- lets Go to race farm cash all night.
  if not rules.isOpen(hour) then
    if not overhaul_world_weather or not overhaul_world_weather.setMinuteOfDay or not overhaul_world_weather.setMinuteOfDay(rules.schedule.meetOpenHour*60,false) then return fail('Could not set race time.') end
  end
  local _,night=clock();dev.night=night;dev.venue=v.id;dev.cleared=nil
  M.rsvpMeet()
  clearMeetRoute();signupSeen=nil;tick=1
  local forward=overhaul_events_streetKnightsVenues.axes({heading=v.parkingHeading or v.heading})
  spawn.safeTeleport(veh,vec3(v.parking),quatFromDir(vec3(forward),vec3(0,0,1)),true,nil,false,true,false)
  -- Hold briefly for teleport settle, then release so the drive to the start line does not burn the clutch.
  veh:queueLuaCommand("input.event('throttle',0,1);input.event('brake',1,1);input.event('parkingbrake',1,1)")
  parkReleaseIn=0.75
  if gameplay_rawPois then gameplay_rawPois.clear() end
  M.close();return true
end
function M.routeToMeet()
  local v=meetVenue()
  if not member() or not v or not v.parking or not core_groundMarkers then return false end
  meetRoute={target=copy(v.parking),token=core_groundMarkers.setPath(vec3(v.parking),{color={1,0.4,0},step=4,renderDecals=true})}
  local ownership=require("overhaul/lib/platform/capabilities").get("groundMarkerOwnership")
  if ownership then ownership.claim("streetKnights") end
  return true
end
function M.onUpdate(dtReal,dtSim)
  if not overhaul_career_career.isActive() then return end
  if offer and offer.probe then
    offer.probe.wait=offer.probe.wait-(dtReal or 0)
    if offer.probe.wait<=0 then startBossTalk();push() end
  end
  if parkReleaseIn then
    parkReleaseIn=parkReleaseIn-dtReal
    if parkReleaseIn<=0 then
      parkReleaseIn=nil
      local veh=be:getPlayerVehicle(0)
      if veh and veh.queueLuaCommand and not raid.isPursuing() then veh:queueLuaCommand("input.event('brake',0,1);input.event('parkingbrake',0,1)") end
    end
  end
  if editor and editor.active then return end
  local loading=core_gamestate and core_gamestate.loading and core_gamestate.loading()
  local black=ui_fadeScreen and ui_fadeScreen.isBlack and ui_fadeScreen.isBlack()
  if loading or black or locationFading then locationReadyIn=2
  else locationReadyIn=math.max(0,locationReadyIn-math.max(0,dtReal or 0)) end
  if not loadedPath then
    loadCareer()
    if not loadedPath then return end
    M.onStreetKnightsVenuesChanged()
  end
  -- Temporary prize/settlement failures leave recovering+errorMessage; retry until saves can unblock.
  if recovering and errorMessage and not handover and not unresolved() then
    settleRetryIn=(settleRetryIn or 2)-dtReal
    if settleRetryIn<=0 then settleRetryIn=2;loadCareer(true) end
  else
    settleRetryIn=nil
  end
  local raidHour,raidNight=clock()
  local raidVenue=active and venueById(active.venue.id) or tonight(raidNight)
  venueCache.raidContext=venueCache.raidContext or {near=nearMeet}
  local context=venueCache.raidContext
  context.venue=raidVenue;context.night=raidNight;context.time=raidNight*24+raidHour+(raidHour<rules.schedule.meetCloseHour and 24 or 0)
  context.open=rules.isOpen(raidHour) and member() and (active~=nil or hasMeetRSVP(raidVenue,raidNight));context.player=be:getPlayerVehicle(0);context.dtReal=dtReal
  if raid.update(context) then
    if handover then
      local veh=be:getPlayerVehicle(0)
      if veh then veh:queueLuaCommand("input.event('brake',0,1);input.event('parkingbrake',0,1)") end
    end
    uiOpen=false;warning=nil;clearMeetRoute();guihooks.trigger('ChangeState',{state='play'})
    guihooks.trigger('Message',{ttl=8,msg='Police raid! Pull over or escape.',category='warning',icon='warning'})
  end
  if overhaul_career_economy_streetChallenges and overhaul_career_economy_streetChallenges.ownsVenue() then return end
  if handover and not raid.isPursuing() then
    local router=extensions.ui_router;local state=router.getState and router.getState();local current=state and state.currentRoute
    if current and current.toRoute and current.toRoute.name~='overhaul.streetKnights' then router.navigate('overhaul.streetKnights') end
    push();return
  end
  if active and active.phase=='cooldown' and not recovering then
    local veh=be:getPlayerVehicle(0)
    slowTime=(not veh or veh:getVelocity():length()<1.389) and slowTime+dtSim or 0
    if slowTime>=2 then active=nil;signupSeen=nil;clearMeetRoute();guihooks.trigger('StreetKnightsHud',{});push();require("overhaul/lib/save/store").bind(overhaul_career_saveSystem).request("streetKnights:raceComplete") end
  end
  tick=tick+dtReal
  if tick<1 then return end local realElapsed=tick;tick=0
  local _,night=clock();local hour=clock();local player=be:getPlayerVehicle(0)
  local markersOpen=rules.isOpen(hour) and member()
  if markersOpen~=signupMarkersOpen then
    signupMarkersOpen=markersOpen
    if gameplay_rawPois then gameplay_rawPois.clear() end
  end
  local nearby
  local spot=active and venueById(active.venue.id) or tonight(night)
  local hasRSVP=hasMeetRSVP(spot,night)
  if not hasRSVP then club.rsvp=nil end
  local attending=markersOpen and hasRSVP
  if spot and (active or (attending and player and nearMeet(spot,player))) then nearby=spot end
  if attending and not club.rsvp.traffic and player and nearMeet(spot,player,800) then club.rsvp.traffic=true end
  if club.rsvp and club.rsvp.traffic and player and not active then
    if nearMeet(spot,player,1500) then club.rsvp.awaySeconds=nil
    else
      club.rsvp.awaySeconds=(club.rsvp.awaySeconds or 0)+realElapsed
      if club.rsvp.awaySeconds>60 then club.rsvp.traffic=nil;club.rsvp.awaySeconds=nil;selectedVenue=nil end
    end
  end
  overhaul_events_streetKnightsDrag.holdTraffic((active~=nil or (attending and (club.rsvp.traffic or (selectedVenue and selectedVenue.id==spot.id)))) or false)
  if profile and locationReadyIn<=0 then
    local delivered=club.locationNight==night and locationNotifiedNight or nil
    local location=clubPolicy.locationNotification({locationNight=delivered},night,hour,spot,member())
    if location then
      if notify('carMeet.knightsLocation',location) then
        club.locationNight=night;locationNotifiedNight=night
      else locationReadyIn=5 end
    end
  end
  local invite=M.getMeetInvite()
  if nearby and not active and locationReadyIn<=0 then
    local challenge=pinkRecord(true)
    if challenge and challenge.titleDefense and (challenge.state=='available' or challenge.state=='revealed') and club.titleNotified~=challenge.id then
      if notify('carMeet.knightsLocation',{title=challenge.reclaimTitle and 'Reclaim your spot' or 'Defend your spot',kind='invite',
        message=challenge.opponent.name..' is waiting. Pink slips and the top spot are on the line.'}) then club.titleNotified=challenge.id end
    end
  end
  local key=invite and (invite.id..invite.status) or ''
  if key~=meetKey then
    meetKey=key
    if overhaul_career_carmeets_carmeets and overhaul_career_carmeets_carmeets.requestRSVPData then overhaul_career_carmeets_carmeets.requestRSVPData() end
  end
  local notice=clubPolicy.resultNotification(club,active,hour)
  if notice then
    result=nil;guihooks.trigger('StreetKnightsHud',{})
    notify('carMeet.knightsResult',notice)
  end
  local lostDisplay=not active and transactions.winBacks[#transactions.winBacks] or nil
  overhaul_events_streetKnightsMeet.update(nearby,boss(progress.tier),not active and progress.defeated<5 and night>=progress.nextNight,lostDisplay,night)
  if not active and not uiOpen then
    local _,_,veh=car()
    if not attending or not near(spot,veh) then signupSeen=nil
    elseif signupSeen~=spot.id then signupSeen=spot.id;M.open(spot.id) end
  end
  push()
end
function M.onVehicleSwitched(oldId,newId)
  if unresolved() and newId~=active.playerVehicleId then finish('loss','Changed entered vehicle') end
end
function M.onVehicleResetted(id) if unresolved() and id==active.playerVehicleId then finish('loss','Vehicle reset') end end
function M.onPursuitAction(id,action) raid.onPursuitAction(id,action) end
function M.onClientEndMission()
  raid.clear();clearMeetRoute();loadedPath=nil;uiOpen=false;locationNotifiedNight=nil;locationReadyIn=2;locationFading=false
  active=nil;offer=nil;selectedVenue=nil;result=nil;warning=nil;signupSeen=nil;signupMarkersOpen=nil;meetKey=nil;dev={}
  venues={};parkReleaseIn=nil;slowTime=0
end
function M.onScreenFadeState(state)
  if state==1 then locationFading=true;locationReadyIn=2
  elseif state==3 then locationFading=false;locationReadyIn=2 end
end
function M.onWorldReadyState(state)
  if state==2 and overhaul_career_career.isActive() then locationFading=false;locationReadyIn=2;loadCareer();M.onStreetKnightsVenuesChanged() end
end
return M
