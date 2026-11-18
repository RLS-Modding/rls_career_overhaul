-- Pure selection/state rules. No player vehicle/garage input is accepted here.
local M={version=1,chances={0.10,0.20,0.30,0.40,0.50},weights={40,20,10,5,5}}
local eligibility=require('overhaul/career/economy/streetKnights/rules')
local function copy(v) if type(v)~='table' then return v end local r={} for k,x in pairs(v) do r[k]=copy(x) end return r end
M.copy=copy
function M.fingerprint(s)
  local n=7
  for i=1,#s do n=(n*65599+s:byte(i))%2147483647 end
  return tostring(n)
end
function M.canonical(v)
  if type(v)~='table' then return type(v)..':'..tostring(v) end
  local keys={} for k in pairs(v) do keys[#keys+1]=k end
  table.sort(keys,function(a,b)return tostring(a)<tostring(b) end)
  local out={'{'} for _,k in ipairs(keys) do out[#out+1]=M.canonical(k)..'='..M.canonical(v[k])..';' end
  out[#out+1]='}';return table.concat(out)
end
function M.random(seed)
  -- Jenkins seed mixing avoids correlated first draws for nearby night suffixes.
  local bit=require('bit');local n=0;seed=tostring(seed)
  for i=1,#seed do
    n=bit.tobit(n+seed:byte(i));n=bit.tobit(n+bit.lshift(n,10));n=bit.bxor(n,bit.rshift(n,6))
  end
  n=bit.tobit(n+bit.lshift(n,3));n=bit.bxor(n,bit.rshift(n,11));n=bit.tobit(n+bit.lshift(n,15))
  if n<0 then n=n+4294967296 end
  n=n%2147483647;if n==0 then n=1 end
  return function() n=(n*16807)%2147483647;return n/2147483647 end
end
function M.select(tier,candidates,random)
  local pools,total={},0
  for _,e in ipairs(candidates) do
    if e.role=='wager' and e.tier>=1 and e.tier<=5 then pools[e.tier]=pools[e.tier] or {};table.insert(pools[e.tier],e) end
  end
  for t=1,5 do if pools[t] and #pools[t]>0 then total=total+M.weights[math.abs(t-tier)+1] end end
  if total==0 then return end
  local roll=random()*total
  for t=1,5 do if pools[t] then
    roll=roll-M.weights[math.abs(t-tier)+1]
    if roll<0 then return copy(pools[t][math.min(#pools[t],math.floor(random()*#pools[t])+1)]) end
  end end
end
function M.chooseClues(clues,random)
  local hardware,performance={},{}
  for _,c in ipairs(clues) do table.insert(c.group=='hardware' and hardware or performance,c) end
  if #clues<3 or #hardware==0 or #performance==0 then return end
  local chosen={table.remove(hardware,math.floor(random()*#hardware)+1),table.remove(performance,math.floor(random()*#performance)+1)}
  local rest={} for _,list in ipairs({hardware,performance}) do for _,c in ipairs(list) do rest[#rest+1]=c end end
  chosen[3]=rest[math.floor(random()*#rest)+1]
  return copy(chosen)
end
function M.reveal(record,revision,category)
  if record.state=='revealed' and record.selectedCategoryId==category then return copy(record) end
  if record.revision~=revision or record.state~='available' then return nil,'This clue choice is locked or the offer changed.' end
  for _,c in ipairs(record.clues) do if c.id==category then
    local r=copy(record);r.selectedCategoryId=category;r.state='revealed';return r
  end end
  return nil,'Unknown clue category.'
end
function M.public(record)
  if not record then return nil end
  local r={id=record.id,revision=record.revision,state=record.state,night=record.night,reason=record.reason,
    titleDefense=record.titleDefense,reclaimTitle=record.reclaimTitle}
  if record.opponent then
    local e=record.opponent
    r.opponent={id=e.id,name=e.name,model=e.model,description=e.description,thumbnail=e.thumbnail}
    r.venue={name=record.venue.name,length=record.venue.length,level=record.venue.level}
    r.minimumValue=record.opponentValue*eligibility.minimumValueFraction;r.selectedCategoryId=record.selectedCategoryId;r.clues={}
    for _,c in ipairs(record.clues) do
      r.clues[#r.clues+1]={id=c.id,label=c.label,context=c.context,value=record.selectedCategoryId==c.id and c.value or nil}
    end
  end
  return r
end
return M
