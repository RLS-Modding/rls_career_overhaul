local rules=require('overhaul/career/economy/streetKnights/pinkOffers')
local M={}
local states={none=true,available=true,revealed=true,declined=true,expired=true,committed=true,settled=true,invalidated=true}
local function integer(v) return type(v)=='number' and v==v and math.abs(v)<math.huge and v%1==0 end
local function completeOffer(r)
  if type(r.opponent)~='table' or type(r.venue)~='table' or type(r.clues)~='table' or #r.clues~=3
    or type(r.opponentValue)~='number' or r.opponentValue<=0 or r.opponentValue>=math.huge or r.opponentValue~=r.opponentValue then return false end
  local ids={}
  for _,c in ipairs(r.clues) do
    if type(c)~='table' or type(c.id)~='string' or type(c.label)~='string' or ids[c.id]
      or (type(c.value)~='string' and type(c.value)~='number') then return false end
    ids[c.id]=true
  end
  return (r.selectedCategoryId==nil or ids[r.selectedCategoryId]) and (r.state~='revealed' or r.selectedCategoryId~=nil)
end
function M.new(io,level,legacyLevel)
  local self={records={},sequence=0,highNight=-math.huge}
  local function belongs(r) return not level or (r.level or r.venue and r.venue.level or legacyLevel or level)==level end
  function self:load()
    local all,err=io.readAll();if not all then return false,err end
    for _,r in ipairs(all) do if type(r)~='table' or not integer(r.sequence) then return false,'Invalid pink-offer journal.' end end
    table.sort(all,function(a,b)return a.sequence<b.sequence end)
    local seen={}
    for _,r in ipairs(all) do
      if r.version~=1 or type(r.sequence)~='number' or r.sequence<1 or r.sequence%1~=0 or seen[r.sequence]
        or type(r.id)~='string' or not integer(r.night) or not integer(r.revision) or r.revision<1 or not states[r.state] then return false,'Invalid pink-offer journal.' end
      if (r.opponent~=nil or r.state=='available' or r.state=='revealed') and not completeOffer(r) then return false,'Incomplete pink offer.' end
      if r.titleDefense and (r.titleDefense~=true or not integer(r.titleNight) or not integer(r.titleSlot) or r.titleSlot<1 or r.titleSlot>3) then return false,'Invalid title challenge.' end
      seen[r.sequence]=true;self.sequence=r.sequence
      if belongs(r) then
        self.records[r.night]=r;self.highNight=math.max(self.highNight,r.night,r.titleDefense and r.titleNight or r.night)
      end
    end
    return true
  end
  function self:write(record)
    local r=rules.copy(record);r.version=1;r.sequence=self.sequence+1;r.revision=(record.revision or 0)+1
    r.level=r.level or level
    local ok,err=io.write(r)
    if not ok then return nil,err or 'Could not save the pink offer. Reload your career before trying again.' end
    self.sequence=r.sequence;self.records[r.night]=r;self.highNight=math.max(self.highNight,r.night,r.titleDefense and r.titleNight or r.night)
    return r
  end
  return self
end
return M
