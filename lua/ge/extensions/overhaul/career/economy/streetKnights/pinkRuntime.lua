local policy=require('overhaul/career/economy/streetKnights/pinkOffers')
local journalFactory=require('overhaul/career/economy/streetKnights/offerJournal')
local clues=require('overhaul/career/economy/streetKnights/clues')
local rules=require('overhaul/career/economy/streetKnights/rules')
local title=require('overhaul/career/economy/streetKnights/titleDefense')
local M={}
function M.new(runtime,legacyLevel)
  local self={}
  local function read(path) return runtime.readFile(path) end
  function self:load(profile,level)
    if self.profile==profile and self.level==level then return not self.error end
    self.profile=profile;self.level=level;self.error=nil;self.notificationKey=nil;self.notificationRecord=nil
    self.metadata=(runtime.jsonReadFile('/gameplay/overhaul/streetKnights/clues.json') or {}).entries or {}
    local dir=runtime.overhaul_career_saveSystem.getSaveRootDirectory()..profile..'/streetKnightsOffers/'
    runtime.overhaul_career_saveSystem.getSaveWriter().mkdir(dir)
    self.journal=journalFactory.new({readAll=function()
      local all={}
      for _,file in ipairs(runtime.FS:findFiles(dir,'offer-*.json',0,false,false) or {}) do
        local r=runtime.jsonReadFile(file);if not r then return nil,'Pink-offer journal is unreadable.' end;all[#all+1]=r
      end
      return all
    end,write=function(r)
      local file=dir..string.format('offer-%010d.json',r.sequence)
      runtime.overhaul_career_saveSystem.jsonWriteFileSafe(file,r,true)
      local check=runtime.jsonReadFile(file)
      return check and policy.canonical(check)==policy.canonical(r)
    end},level,legacyLevel)
    local ok,err=self.journal:load();self.error=err;return ok
  end
  function self:valid(r,venue,roster)
    local found
    for _,e in ipairs(roster) do if e.id==r.opponent.id and e.model==r.opponent.model and e.role=='wager' then found=e end end
    if not found or not venue or policy.canonical(venue)~=policy.canonical(r.venueDefinition) then return false end
    local meta=self.metadata[found.id]
    return meta and policy.fingerprint(policy.canonical(meta))==r.metadataFingerprint and clues.validate(meta,found,read)
  end
  function self:write(r)
    local saved,err=self.journal:write(r)
    if not saved then self.error=err end
    return saved,err
  end
  function self:ensureTitle(profile,progress,hour,night,venue,roster,value,transactions,receipts,attending)
    local pending
    for _,record in pairs(self.journal.records) do
      if record.titleDefense and (record.state=='available' or record.state=='revealed' or record.state=='committed') then
        if pending then return nil end
        pending=record
      end
    end
    if pending then
      for id,tx in pairs(transactions.records or {}) do
        if tx.race.offerId==pending.id then
          local settled=receipts and receipts[id] and receipts[id].settled
          local state=settled and 'settled' or 'committed'
          if pending.state~=state or pending.transactionId~=id then
            local changed=policy.copy(pending);changed.state=state;changed.transactionId=id
            if settled and tx.outcome=='void' then
              changed.id=changed.id..':retry';changed.transactionId=nil
              changed.state=changed.selectedCategoryId and 'revealed' or 'available'
            end
            pending=self:write(changed);if not pending then return end
          end
          break
        end
      end
      if pending.state~='settled' then
        if night<self.journal.highNight then return pending end
        if pending.state=='committed' or not venue or not rules.isOpen(hour) then return pending end
        local moved=pending.titleNight~=night or policy.canonical(venue)~=policy.canonical(pending.venueDefinition)
        local changed=pending
        if moved then
          changed=policy.copy(pending);changed.venueDefinition=policy.copy(venue)
          changed.venue={id=venue.id,name=venue.name or venue.id,level=venue.level,length=venue.length}
          if changed.titleNight~=night then
            changed.titleNight=night
            changed.titleSlot=title.slot(profile,night,hour,transactions,receipts,self.level,legacyLevel) or 1
          end
        end
        if not self:valid(changed,venue,roster) then
          changed=policy.copy(changed)
          changed.state='invalidated';changed.reason='Challenger build changed; a replacement is required.'
          if not self:write(changed) then return end
        elseif moved then return self:write(changed)
        else return pending end
      end
    end
    if not attending or not venue or not rules.isOpen(hour) or not rules.isScheduledNight(night) or night<self.journal.highNight then return end
    local slot,count,used=title.slot(profile,night,hour,transactions,receipts,self.level,legacyLevel)
    if not slot then return end
    local candidates={}
    for _,entry in ipairs(roster) do
      local meta=self.metadata[entry.id]
      local speed=meta and meta.evidence and meta.evidence.trapMps
      if entry.role=='wager' and type(speed)=='number' and speed>0 and speed<math.huge and clues.validate(meta,entry,read) then
        local worth=value(entry)
        if type(worth)=='number' and worth>0 and worth<math.huge then
          local candidate=policy.copy(entry)
          candidate.speed=speed;candidate.value=worth;candidate.metadata=meta
          candidates[#candidates+1]=candidate
        end
      end
    end
    local opponent=title.select(candidates,progress.titleHolderId,used)
    if not opponent then return end
    local random=policy.random(profile..':title:'..night..':'..slot)
    local picked=policy.chooseClues(opponent.metadata.clues,random)
    local snapshot=runtime.jsonReadFile(opponent.config)
    if not picked or not snapshot then return end
    local r={id=profile..':title:'..(self.level and self.level..':' or '')..night..':'..slot..':'..(self.journal.sequence+1),night=night,state='available',
      titleDefense=true,reclaimTitle=progress.titleHolderId~=nil,titleNight=night,titleSlot=slot,
      generation={count=count},opponentValue=opponent.value,clues=picked,fullConfigSnapshot=snapshot,
      metadataFingerprint=policy.fingerprint(policy.canonical(opponent.metadata)),
      venueDefinition=policy.copy(venue),venue={id=venue.id,name=venue.name or venue.id,level=venue.level,length=venue.length}}
    opponent.metadata=nil;opponent.value=nil;opponent.speed=nil;r.opponent=opponent
    return self:write(r)
  end
  function self:ensure(profile,progress,hour,night,venue,roster,value,transactions,receipts,attending)
    if not profile or progress.defeated<1 then return end
    local level=venue and venue.level or runtime.getCurrentLevelIdentifier and runtime.getCurrentLevelIdentifier() or self.level
    if not self:load(profile,level) then return end
    if progress.defeated>=5 then return self:ensureTitle(profile,progress,hour,night,venue,roster,value,transactions,receipts,attending) end
    local r=self.journal.records[night]
    -- The wager journal is authoritative if a crash occurred between the two writes.
    for _,tx in pairs(transactions.records or {}) do
      if tx.race.offerId and r and tx.race.offerId==r.id and r.state~='settled' then
        local state=tx.state=='locked' and 'settled' or 'committed'
        if r.state~=state or r.transactionId~=tx.id then
          r=policy.copy(r);r.state=state;r.transactionId=tx.id;r=self:write(r);if not r then return end
        end
      end
    end
    -- Expire old open records even when the player travelled over multiple nights.
    for n,old in pairs(self.journal.records) do
      if (n<night or (n==night and not rules.isOpen(hour))) and (old.state=='available' or old.state=='revealed') then
        local expired=policy.copy(old);expired.state='expired'
        if not self:write(expired) then return end
      end
    end
    r=self.journal.records[night]
    if r then
      if (r.state=='available' or r.state=='revealed') and venue and r.venue.level==venue.level and r.venue.id==venue.id and not self:valid(r,venue,roster) then
        r=policy.copy(r);r.state='invalidated';r.reason='Build or venue changed; offer withdrawn.';r=self:write(r)
      end
      return r
    end
    if not rules.isOpen(hour) or not rules.isScheduledNight(night) or not venue or night<self.journal.highNight then return end
    local seed=profile..':pink-v1:'..night;local random=policy.random(seed)
    local chance=policy.chances[math.min(5,progress.defeated)]
    r={id=profile..':pink:'..(self.level and self.level..':' or '')..night,night=night,state='none',generation={chance=chance,bossesDefeated=progress.defeated,tier=progress.tier,weightsVersion=1,seed=seed}}
    if random()<chance then
      local candidates={}
      for _,e in ipairs(roster) do
        local meta=self.metadata[e.id]
        if e.role=='wager' and clues.validate(meta,e,read) then
          local v=value(e)
          if type(v)=='number' and v>0 and v<math.huge then
            local c=policy.copy(e);c.clues=meta.clues;c.value=v;c.metadataFingerprint=policy.fingerprint(policy.canonical(meta));candidates[#candidates+1]=c
          end
        end
      end
      local e=policy.select(progress.tier,candidates,random)
      if e then
        local picked=policy.chooseClues(e.clues,random)
        if picked then
          r.state='available';r.clues=picked;r.opponentValue=e.value;r.metadataFingerprint=e.metadataFingerprint
          e.clues=nil;e.value=nil;e.metadataFingerprint=nil;r.opponent=e
          r.fullConfigSnapshot=runtime.jsonReadFile(e.config)
          r.venueDefinition=policy.copy(venue);r.venue={id=venue.id,name=venue.name or venue.id,level=venue.level,length=venue.length}
          if not r.fullConfigSnapshot then r.state='none';r.reason='Opponent configuration unavailable.' end
        end
      else r.reason='No compatible pink-slip challenger is available tonight.' end
    end
    return self:write(r)
  end
  -- The notification loop only needs to revisit offer generation when its inputs change.
  -- Explicit UI actions and final commitment still call ensure/valid directly.
  function self:notificationOffer(profile,progress,hour,night,venue,roster,value,transactions,receipts,attending)
    if not profile or progress.defeated<5 then return end
    local level=venue and venue.level or runtime.getCurrentLevelIdentifier and runtime.getCurrentLevelIdentifier() or self.level
    if not self:load(profile,level) then return end
    local pending={}
    for _,record in pairs(self.journal.records) do
      if record.titleDefense and (record.state=='available' or record.state=='revealed' or record.state=='committed') then
        pending[record.id]=true
      end
    end
    local relevant={}
    for id,tx in pairs(transactions.records or {}) do
      local race=tx.race
      local raceLevel=race and race.venue and race.venue.level or legacyLevel or self.level
      if race and (not self.level or raceLevel==self.level) and (pending[race.offerId] or (race.titleDefense and race.night==night)) then
        relevant[id]={offerId=race.offerId,titleDefense=race.titleDefense,night=race.night,
          titleSlot=race.titleSlot,opponent=race.opponent,outcome=tx.outcome,
          settled=receipts and receipts[id] and receipts[id].settled or false}
      end
    end
    local slot=title.slot(profile,night,hour,transactions,receipts,self.level,legacyLevel)
    local function key()
      return policy.canonical({profile=profile,progress=progress,night=night,open=rules.isOpen(hour),slot=slot,
        venue=venue,attending=not not attending,sequence=self.journal.sequence,transactions=relevant})
    end
    local before=key()
    if self.notificationKey==before then return self.notificationRecord end
    local record=self:ensure(profile,progress,hour,night,venue,roster,value,transactions,receipts,attending)
    -- Failed writes must be retried; successful writes advance the journal sequence.
    if not self.error then self.notificationKey=key();self.notificationRecord=record end
    return record
  end
  function self:mutate(id,revision,action,category)
    if self.error or not self.journal then return nil,self.error or 'Pink offers are not ready.' end
    local current
    for _,r in pairs(self.journal.records) do if r.id==id then current=r end end
    if not current then return nil,'Offer unavailable.' end
    local changed,err
    if action=='reveal' then changed,err=policy.reveal(current,revision,category)
    elseif action=='decline' and current.revision==revision and not current.titleDefense and (current.state=='available' or current.state=='revealed') then changed=policy.copy(current);changed.state='declined'
    end
    if not changed then return nil,err or 'Offer changed.' end
    if policy.canonical(changed)==policy.canonical(current) then return current end
    return self:write(changed)
  end
  function self:committed(record,transactionId)
    local r=policy.copy(record);r.state='committed';r.transactionId=transactionId
    return self:write(r)
  end
  function self:public(record)
    if self.error then return {state='unavailable',reason=self.error} end
    return policy.public(record)
  end
  return self
end
return M
