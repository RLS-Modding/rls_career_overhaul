-- Owns append-only wager revisions and outcome locks; callers supply durable read/write adapters.
-- Parts: feature owners decide results; payment/inventory apply effects; career snapshots own receipts.
-- Contract: preserve version-1 records and their race payload; never overwrite the last durable revision.
local M={}
local function copy(t) local r={} for k,v in pairs(t) do r[k]=type(v)=='table' and copy(v) or v end return r end
function M.new(io)
  local self={records={}, sequence=0, io=io}
  function self:load()
    local records,err=self.io.readAll()
    if not records then return false,err end
    self.records={};self.sequence=0
    local seen={}
    for _,r in ipairs(records) do
      if type(r)~='table' or r.version~=1 or type(r.sequence)~='number' or r.sequence~=math.floor(r.sequence) or r.sequence<1
        or seen[r.sequence] or type(r.id)~='string' or type(r.race)~='table' or type(r.race.order)~='number'
        or (r.state~='committed' and r.state~='locked') then return false,'Invalid wager ledger.' end
      if r.state=='locked' and r.outcome~='win' and r.outcome~='loss' and r.outcome~='void' then return false,'Invalid wager outcome.' end
      seen[r.sequence]=true
    end
    table.sort(records,function(a,b) return a.sequence<b.sequence end)
    for _,r in ipairs(records) do
      if r.version~=1 or type(r.sequence)~='number' or not r.id or not r.race then return false,'Invalid wager ledger.' end
      self.sequence=math.max(self.sequence,r.sequence);self.records[r.id]=r
    end
    return true
  end
  function self:write(record)
    local nextRecord=copy(record);nextRecord.sequence=self.sequence+1;nextRecord.version=1
    local ok,err=self.io.write(nextRecord)
    if not ok then return nil,err or 'Could not persist the wager.' end
    self.sequence=nextRecord.sequence;self.records[nextRecord.id]=nextRecord
    return nextRecord
  end
  function self:commit(race)
    if self.records[race.id] then return nil,'Duplicate commitment.' end
    return self:write({id=race.id,race=copy(race),state='committed'})
  end
  function self:decide(id,outcome,reason,prize)
    local r=self.records[id]
    if not r then return nil,'Missing commitment.' end
    if r.state~='committed' then return r end
    if outcome~='win' and outcome~='loss' and outcome~='void' then return nil,'Invalid wager outcome.' end
    -- Durable decision while still committed so a failed lock write cannot become a reload loss.
    local nextRecord=copy(r)
    nextRecord.decidedOutcome=outcome
    nextRecord.decidedReason=reason
    nextRecord.decidedPrize=prize
    return self:write(nextRecord)
  end
  function self:lock(id,outcome,reason,prize)
    local r=self.records[id]
    if not r then return nil,'Missing commitment.' end
    if r.state~='committed' then return r end
    local nextRecord=copy(r);nextRecord.state='locked';nextRecord.outcome=outcome;nextRecord.reason=reason;nextRecord.prize=prize
    nextRecord.decidedOutcome=nil;nextRecord.decidedReason=nil;nextRecord.decidedPrize=nil
    return self:write(nextRecord)
  end
  function self:ordered()
    local result={} for _,r in pairs(self.records) do result[#result+1]=r end
    table.sort(result,function(a,b) return a.race.order<b.race.order end)
    return result
  end
  function self:attachPrize(id,prize)
    local r=self.records[id]
    if not r or r.state~='locked' or r.outcome~='win' then return nil,'No locked prize claim.' end
    local updated=copy(r);updated.prize=copy(prize)
    return self:write(updated)
  end
  return self
end
return M
