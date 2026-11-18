local M={}
local rules=require('overhaul/career/economy/streetKnights/rules')
function M.clock(weather,tod,dev)
  local hour,night
  if weather and weather.minuteOfDay then
    hour=weather.minuteOfDay/60;night=rules.meetNight(weather.dayIndex or 0,hour)
  else
    hour=((tod.time+0.5)%1)*24;night=rules.meetNight(0,hour)
  end
  return hour,night
end
function M.venuePool(venues)
  local pool={}
  for _,v in ipairs(venues) do if v.enabled~=false then pool[#pool+1]=v end end
  table.sort(pool,function(a,b) return tostring(a.id)<tostring(b.id) end)
  return pool
end
function M.tonight(venues,night,dev,developer)
  if dev.cleared==night then return end
  local pool=M.venuePool(venues)
  if #pool==0 then return end
  if dev.night==night then for _,v in ipairs(pool) do if v.id==dev.venue then return v end end end
  if not developer and not rules.isScheduledNight(night) then return end
  return pool[math.floor(night*2654435761/4096)%#pool+1]
end
function M.venueById(venues,id) for _,v in ipairs(venues) do if v.id==id then return v end end end
M.spotName=require('overhaul/career/economy/streetKnights/venueName').resolve
function M.levelName(id)
  if id=='rls_west_coast' then return 'West Coast USA' end
  if not id or id=='' then return nil end
  return (id:gsub('_',' '):gsub('(%a)(%w*)',function(a,b) return a:upper()..b end):gsub('%f[%a]Usa%f[%A]','USA'))
end
local function dollars(n) return '$'..(tostring(math.floor(n or 0)):reverse():gsub('(%d%d%d)','%1,'):reverse():gsub('^,','')) end
local resultLines={
  win={cash="Congrats on the win - I've sent your payment.",boss='Congrats on the win - the pink slip is yours.'},
  loss={cash='Tough break tonight. Your stake stays with us.',boss='Tough break tonight. Your car stays with us.'},
  void={cash="Race got called off. I've sent your stake back.",boss='Race got called off. Your car is still yours.'},
}
function M.resultMessage(r)
  local kind=rules.isCarStake(r.kind) and 'boss' or 'cash'
  local money=kind=='cash' and ({win=dollars((r.amount or 0)*2)..' sent',loss='-'..dollars(r.amount),void=dollars(r.amount)..' returned'})[r.outcome]
  local lines=resultLines[r.outcome] or resultLines.void
  return {message=lines[kind],meta=table.concat({r.reason or '',money or ''},money and r.reason and ' · ' or ''),
    kind=r.outcome=='win' and 'success' or r.outcome=='loss' and 'warning' or 'info'}
end
function M.meetVenue(venues,active,hour,night,dev,developer)
  local v=active and (M.venueById(venues,active.venue.id) or active.venue) or M.tonight(venues,night,dev,developer)
  if v then return v,hour,night end
end
function M.getMeetInvite(v,hour,night,active,level)
  if not v then return end
  local open=rules.isOpen(hour)
  return {id='streetKnights_'..night,type='STREET_DRAG',typeName='Street Drag Meet',clubId='no_prep_knights',clubName='No Prep Knights',
    location=M.spotName(v),level=M.levelName(v.level or level),distance=v.length or 201.168,
    open=open,racing=active~=nil,openTime=rules.openTimeText,closeTime=rules.closeTimeText,
    status=active and 'Racing now' or open and ('Live until '..rules.closeTimeText) or ('Lights at '..rules.openTimeText),
    screen='phone-no-prep-knights'}
end

function M.locationNotification(club,night,hour,spot,member)
  if not member or club.locationNight==night or not spot then return end
  club.locationNight=night
  return {title='New Invite',source='Car Meets',route='car-meets-phone',kind='invite',
    message='Street Drag Meet - '..M.spotName(spot),meta='No Prep Knights · '..(rules.isOpen(hour) and ('Live until '..rules.closeTimeText) or ('Lights at '..rules.openTimeText))}
end
function M.resultNotification(club,active,hour)
  if not club.last or club.last.seen or active or rules.isOpen(hour) then return end
  club.last.seen=true
  return M.resultMessage(club.last)
end
return M
