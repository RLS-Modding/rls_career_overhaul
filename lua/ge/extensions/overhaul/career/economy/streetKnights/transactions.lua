local M={}
local rules=require('overhaul/career/economy/streetKnights/rules')
local journalFactory=require('overhaul/lib/finance/wagerJournal')
local prizeRecovery=require('overhaul/career/economy/streetKnights/prizeRecovery')
  local winBack=require('overhaul/lib/vehicles/pinkSlipWinBack')
local snapshotFile='/career/streetKnights.json'

function M.new(runtime,live)
  local self={progress=rules.newProgress(),receipts={},club={},maps={},winBacks={}}
  local function copy(t) return runtime.deepcopy(t) end
  function self:mapState(level)
    level=level or self.legacyLevel or self.level or 'rls_west_coast'
    if not self.maps[level] then self.maps[level]={progress=rules.newProgress(),club={}} end
    return self.maps[level]
  end
  local function selectLevel(level)
    self.level=level
    local state=self:mapState(level)
    self.progress,self.club=state.progress,state.club
    live.level=level;live.maps=self.maps;live.legacyLevel=self.legacyLevel
    live.progress=self.progress;live.club=self.club
  end
  local function grantPrize(r,sceneId)
    local inv=runtime.overhaul_career_garage_inventory.getVehicles()
    for _,v in pairs(inv) do if v.streetKnightsTransaction==r.id then return true end end
    if not r.prize or r.prize.pending then return false,'Your win is recorded; prize condition recovery is pending.' end
    local conditions=prizeRecovery.conditions(r.prize)
    local hasConditions=next(conditions)~=nil
    local mileage=r.prize.mileage or 0
    local veh=sceneId and runtime.be:getObjectByID(sceneId)
    local restored=not veh
    if not veh then
      local pos=runtime.vec3(r.race.venue.parking)+runtime.vec3(0,0,1)
      veh=runtime.core_vehicles.spawnNewVehicle(r.prize.model,{config=copy(r.prize.config),pos=pos,autoEnterVehicle=false})
      if not veh then return false,'Your win is recorded; prize restoration will retry.' end
      sceneId=veh:getID()
    end
    if restored and hasConditions then runtime.core_vehicleBridge.executeAction(veh,'initPartConditions',conditions) end
    if restored and r.prize.damagePath and runtime.FS:fileExists(r.prize.damagePath) then
      veh:queueLuaCommand("extensions.load('overhaulDamageState'); overhaulDamageState.loadDamageData("..runtime.serialize(r.prize.damagePath)..")")
    end
    if mileage>0 then prizeRecovery.applyMileage(veh,mileage) end
    if runtime.settings then prizeRecovery.applyPlayerGearbox(veh,runtime.settings.getValue('defaultGearboxBehavior')) end
    -- Pink rivals race on a copy of their .pc, which has no file name. Name it so the inventory
    -- finds the catalogue entry: without it the car gets the current year and a 1000 base value.
    -- Only a config the catalogue still knows: the inventory reads its entry without a nil check.
    local opponentConfig=r.race.opponent and r.race.opponent.config
    local configKey=type(opponentConfig)=='string' and opponentConfig:match('([^/]+)%.pc$')
    if configKey and runtime.core_vehicles.getConfig(r.prize.model,configKey) then
      local data=runtime.core_vehicle_manager.getVehicleData(sceneId)
      if data and type(data.config)=='table' then data.config.partConfigFilename=opponentConfig end
    end
    local id=runtime.overhaul_career_garage_inventory.addVehicle(sceneId,nil,{owned=true,takesNoInventorySpace=true,skipPartConditionInit=hasConditions or mileage>0,finalPrice=0})
    if not id then return false,'Could not register the recorded prize; the claim is retained.' end
    local v=inv[id]
    local baseValue=tonumber(r.prize.configBaseValue)
    if baseValue and baseValue>0 then v.configBaseValue=baseValue end
    if v.config and type(opponentConfig)=='string' then v.config.partConfigFilename=opponentConfig end
    if hasConditions then v.partConditions=conditions end
    if mileage>0 then v.mileage=mileage end
    v.niceName=r.prize.niceName
    if r.race.winBackId then v.year=r.prize.year end
    winBack.restoreValue(runtime,v,r.race.winBackId and r.race.opponent and r.race.opponent.originalVehicle)
    v.streetKnightsTransaction=r.id;v.rewardSource='Street Knights';v.purchasePrice=0
    v.streetKnightsDamagePath=r.prize.damagePath
    v.streetKnightsRecoveredDamage=r.prize.recoveredFromIncompleteCapture
    veh.playerUsable=true
    if runtime.overhaul_career_repair_insurance then
      runtime.overhaul_career_repair_insurance.onOverhaulVehicleAddedToInventory({inventoryId=id,purchaseData={insuranceId=-1}})
    end
    local garage=runtime.overhaul_career_garage_garageManager and runtime.overhaul_career_garage_garageManager.getNextAvailableSpace()
    v.takesNoInventorySpace=nil
    if garage and runtime.overhaul_career_garage_inventory.moveVehicleToGarage(id,garage) then v.streetKnightsStorePending=true
    else v.location=nil;v.niceLocation='At the race venue';v.streetKnightsInWorld=true end
    r.prizeInWorld=v.streetKnightsInWorld or false
    runtime.overhaul_career_garage_inventory.setVehicleDirty(id)
    return true
  end
  function self:reconcile(r,sceneId)
    local progress=self:mapState(r.race.venue and r.race.venue.level).progress
    local receipts=self.receipts
    local inv=runtime.overhaul_career_garage_inventory.getVehicles()
    receipts[r.id]=receipts[r.id] or {}
    local receipt=receipts[r.id]
    if not receipt.escrow then
      if r.race.kind=='cash' then
        -- Reconciliation must honor an existing commitment even if loaded funds changed.
        if not runtime.overhaul_career_economy_payment.pay({money={amount=r.race.amount,canBeNegative=true}},require('overhaul/lib/finance/metadata').tag({label='Street Knights stake'},'activity:drag')) then return false,'Could not charge the committed stake.' end
      end
      receipt.escrow=true
    end
    if r.state=='committed' or receipt.settled then return true end
    if r.race.kind=='cash' then
      local reward=r.outcome=='win' and r.race.amount*2 or r.outcome=='void' and r.race.amount or 0
      if reward>0 then runtime.overhaul_career_economy_payment.reward({money={amount=reward}},require('overhaul/lib/finance/metadata').tag({label='Street Knights '..r.outcome},r.outcome=='void' and 'refund' or 'activity:drag'),true) end
    elseif r.outcome=='loss' then
      if not r.handoverConfirmed then return false,'Car handover required.' end
      -- Cash added in a boss negotiation is only owed on a loss.
      if (r.race.bossCash or 0)>0 and not receipt.bossCash then
        if not runtime.overhaul_career_economy_payment.pay({money={amount=r.race.bossCash,canBeNegative=true}},require('overhaul/lib/finance/metadata').tag({label='Street Knights boss cash'},'activity:drag')) then return false,'Could not charge the cash you offered.' end
        receipt.bossCash=true
      end
      local transferred,err=winBack.transfer(runtime,self.journal,r)
      if not transferred then return false,err end
    elseif r.outcome=='win' then
      local ok,err=grantPrize(r,sceneId);if not ok then return false,err end
    end
    if r.outcome~='void' then rules.progress(progress,r.race,r.outcome) end
    receipt.settled=true
    if rules.isCarStake(r.race.kind) then self.winBacks=winBack.list(self.journal,self.level) end
    return true
  end
  function self:load(slot,path)
    local errorMessage
    self.profile=slot
    local snapshot=runtime.jsonReadFile(path..snapshotFile) or {}
    local inventory=runtime.overhaul_career_garage_inventory.getVehicles()
    local source=live.profile==slot and live.inventory==inventory and live or snapshot
    local receipts=source.receipts or {}
    local level=runtime.getCurrentLevelIdentifier and runtime.getCurrentLevelIdentifier() or source.level or 'rls_west_coast'
    errorMessage=nil
    local dir=runtime.overhaul_career_saveSystem.getSaveRootDirectory()..slot..'/streetKnightsLedger/'
    runtime.overhaul_career_saveSystem.getSaveWriter().mkdir(dir)
    local journal=journalFactory.new({readAll=function()
      local list={}
      for _,file in ipairs(runtime.FS:findFiles(dir,'*.json',0,false,false) or {}) do
        if file:match('/%d+%.json$') then
        local r=runtime.jsonReadFile(file)
        if not r then return nil,'Street Knights ledger is unreadable; stakes disabled.' end
        list[#list+1]=r
        end
      end
      return list
    end,write=function(r)
      local file=dir..string.format('%010d',r.sequence)..'.json'
      runtime.overhaul_career_saveSystem.jsonWriteFileSafe(file,r,true)
      local check=runtime.jsonReadFile(file)
      return check and check.sequence==r.sequence and check.id==r.id and check.state==r.state
    end})
    self.journal=journal
    self.recovering=false;self.handover=nil
    local ok,err=journal:load()
    if not ok then self.recovering=true;return false,err end
    winBack.repairReclaimed(runtime,journal,'streetKnightsTransaction')
    self.maps=source.maps or {}
    self.receipts=receipts;self.legacyLevel=source.legacyLevel
    live.profile=slot;live.inventory=inventory;live.receipts=receipts
    if not source.maps then
      local owner,latest=source.level,0
      for id,record in pairs(journal.records) do
        if not owner and receipts[id] and receipts[id].settled and record.race.venue and record.race.venue.level and record.sequence>latest then
          latest=record.sequence;self.legacyLevel=record.race.venue.level
        end
      end
      self.legacyLevel=owner or self.legacyLevel or level
      self.maps[self.legacyLevel]={progress=source.progress or rules.newProgress(),club=source.club or {}}
    end
    selectLevel(level)
    self.recovering=true
    for _,r in ipairs(journal:ordered()) do
      if r.state=='committed' then
        local outcome=r.decidedOutcome or 'loss'
        local reason=r.decidedReason or 'Unresolved commitment on reload'
        r,err=journal:lock(r.id,outcome,reason,r.decidedPrize)
      end
      if not r then errorMessage=err;break end
      if r.prize and r.prize.pending then
        -- A completed race stays completed, even when shutdown interrupted damage capture.
        local prize=prizeRecovery.resolve(r.prize,runtime.jsonReadFile)
        local attached,why=journal:attachPrize(r.id,prize)
        if not attached then errorMessage=why;break end
        r=attached
      end
      if r.state=='locked' and rules.isCarStake(r.race.kind) and r.outcome=='loss' and not r.handoverConfirmed and not (receipts[r.id] and receipts[r.id].settled) then self.handover=r;self.winBacks=winBack.list(journal,level);return true end
      local applied,why=self:reconcile(r);if not applied then errorMessage=why;break end
    end
    self.recovering=errorMessage~=nil
    self.winBacks=winBack.list(journal,level)
    return not self.recovering,errorMessage
  end

  function self:save(path)
    runtime.overhaul_career_saveSystem.jsonWriteFileSafe(path..snapshotFile,{version=3,level=self.level,legacyLevel=self.legacyLevel,maps=self.maps,
      progress=self.progress,receipts=self.receipts,club=self.club},true)
  end
  return self
end
return M
