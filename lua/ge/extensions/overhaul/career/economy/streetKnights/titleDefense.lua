-- Owns challenge timing and opponent selection. pinkRuntime writes offers to
-- the offer journal; settled transaction receipts gate later challenge slots.
local random=require('overhaul/career/economy/streetKnights/pinkOffers').random
local rules=require('overhaul/career/economy/streetKnights/rules')
local M={}
function M.slot(profile,night,hour,transactions,receipts,level,legacyLevel)
  local config=rules.schedule
  local count=config.titleChallengesMinPerMeet+math.floor(random(profile..':title-v1:'..night)()*(config.titleChallengesMaxPerMeet-config.titleChallengesMinPerMeet+1))
  local time=hour<config.meetCloseHour and hour+24 or hour
  local duration=24-config.meetOpenHour+config.meetCloseHour
  local slot=math.min(count,math.floor((time-config.meetOpenHour)/(duration/(count+1))+0.000001))
  if slot<1 then return end
  local latest,used=0,{}
  for id,record in pairs(transactions.records or {}) do
    local race=record.race
    local raceLevel=race.venue and race.venue.level or legacyLevel or level
    if race.titleDefense and race.night==night and (not level or raceLevel==level) then
      if not (receipts and receipts[id] and receipts[id].settled) then return end
      if record.outcome~='void' then
        latest=math.max(latest,race.titleSlot or 1);used[race.opponent.id]=true
      end
    end
  end
  if slot<=latest then return end
  return slot,count,used
end
function M.select(candidates,holder,used)
  if holder then
    for _,entry in ipairs(candidates) do if entry.id==holder then return entry end end
    return
  end
  table.sort(candidates,function(a,b)
    if a.speed~=b.speed then return a.speed>b.speed end
    return a.id<b.id
  end)
  for _,entry in ipairs(candidates) do if not used[entry.id] then return entry end end
end
return M
