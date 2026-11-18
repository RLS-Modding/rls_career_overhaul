-- Street Knights rules have no scene/UI dependencies; currency is whole dollars.
local M = {}
M.schedule=require('overhaul/career/economy/streetKnights/schedule').config
M.openTimeText=string.format('%02d:00',M.schedule.meetOpenHour)
M.closeTimeText=string.format('%02d:00',M.schedule.meetCloseHour)
M.version = 2
function M.isCarStake(kind) return kind=='boss' or kind=='pink' end
function M.validKind(kind) return kind=='cash' or M.isCarStake(kind) end
M.caps = {1000, 2000, 3000, 4000, 5000}
M.winsRequired = 5
M.minimumValueFraction = 0.5
-- Below this share of the boss car's value the boss will not negotiate; above it, cash can close the gap.
M.bossFloorFraction = 0.25
M.raceTimeout = 120
M.outsideLaneFouls = false
M.knownFaults = {invalidVenue=true, controllerError=true, opponentInitialization=true}
function M.newProgress()
  return {tier=1, wins=0, defeated=0, nextNight=-1, rotation=0}
end
function M.isOpen(hour) return hour >= M.schedule.meetOpenHour or hour < M.schedule.meetCloseHour end
function M.isScheduledNight(night)
  local eventNight=0
  while eventNight<night do
    local random=((eventNight+1)*2654435761)%4294967296
    eventNight=eventNight+2+math.floor(random/65536)%3
  end
  return eventNight==night
end
function M.meetNight(day, hour) return day - (hour < M.schedule.meetCloseHour and 1 or 0) end
function M.entry(p, hour, night, carValue, bossValue, isBoss)
  if not M.isOpen(hour) then return false, 'The meet opens at '..M.openTimeText..'.' end
  if isBoss and night < p.nextNight then return false, 'Your next rival arrives next night.' end
  if not carValue then return false, 'Arrive in a car you own.' end
  if isBoss then
    if p.defeated >= 5 then return false, 'All five bosses defeated.' end
    if p.wins < M.winsRequired then return false, 'Earn five wins in this tier.' end
    if not bossValue or carValue < bossValue * M.bossFloorFraction then return false, 'Your car is not worth enough for the boss to talk.', 'floor' end
  end
  return true
end
function M.offer(entry, tier, index, revision)
  local cap=M.caps[tier]
  local opening=math.max(100, math.floor(cap * ({0.25,0.5,0.75})[index]))
  return {id=entry.id, revision=revision, kind='cash', amount=opening, opening=opening,
    cap=cap, budget=math.min(cap,opening+250), personality=entry.personality or index,
    countered=false, status='opening'}
end
function M.counter(offer, amount, balance)
  if offer.countered or offer.status ~= 'opening' then return false, 'Only one counter is allowed.' end
  if type(amount)~='number' or amount~=math.floor(amount) or amount < offer.opening+100 or amount>offer.cap or amount>balance then
    return false, 'Counter exceeds your funds or the tier limit.'
  end
  offer.countered=true
  if offer.personality==2 then offer.status='declined'
  elseif amount<=offer.budget and offer.personality==1 then offer.amount=amount;offer.status='agreed'
  else offer.amount=math.min(offer.budget,offer.opening+50);offer.status='final' end
  return true
end
function M.progress(p, race, outcome)
  if race.winBackId then return end
  p.rotation=p.rotation+1
  if race.titleDefense then
    if outcome=='win' then p.titleHolderId=nil
    elseif outcome=='loss' then p.titleHolderId=race.opponent.id end
    return
  end
  if outcome~='win' then return end
  if race.kind=='boss' then
    p.defeated=math.min(5,p.defeated+1);p.wins=0
    if p.defeated<5 then p.tier=p.tier+1;p.nextNight=race.night+1 end
  else p.wins=p.wins+1 end
end
-- Arm the start rules only when the player reaches staging in their lane.
function M.enteredStaging(previousFront,previousInLane,front,inLane)
  if not inLane then return false end
  if front>=-0.8 and front<=0.2 then return true end
  -- Catch a fast forward crossing that skips the pre-stage band between updates.
  return previousInLane==true and previousFront~=nil and previousFront< -0.8 and front>0.2
end
-- Return sub-frame crossing time; nil means no crossing this frame.
function M.crossing(previous, current, finish, elapsed, dt)
  if previous and previous < finish and current >= finish and current > previous then
    return elapsed-dt+dt*(finish-previous)/(current-previous)
  end
end
function M.finishWinner(player, opponent)
  if player and opponent then return player<opponent and 'win' or 'loss' end
  if player then return 'win' end
  if opponent then return 'loss' end
end
-- Side is signed toward the vehicle's own outside edge; 0 is the center line.
function M.laneExit(previous,current,elapsed,dt,width)
  width=M.outsideLaneFouls and width or nil
  if not previous then return end
  if previous<0 or (width and previous>width) then return elapsed-dt end
  if current<0 then return elapsed-dt+dt*previous/(previous-current) end
  if width and current>width then return elapsed-dt+dt*(width-previous)/math.max(current-previous,1e-9) end
end
function M.firstEvent(playerFinish,opponentFinish,playerExit,opponentExit)
  local first
  for _,e in ipairs({{playerExit,'loss','Left your lane'},{opponentFinish,'loss','Opponent crossed first'},
    {opponentExit,'win','Opponent left its lane'},{playerFinish,'win','First across the line'}}) do
    if e[1] and (not first or e[1]<first[1]) then first=e end
  end
  if first then
    if playerFinish and playerFinish==opponentFinish and first[1]==playerFinish then return 'loss','Exact tie' end
    return first[2],first[3]
  end
end
return M
