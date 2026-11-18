-- Shared GE coordinator; the physical model lives in common/rlsFuelModel.
local M = {}
local saveStore = require('overhaul/lib/save/store')
local model=require('common/rlsFuelModel')
local fuelControl=require('common/rlsFuelControl')
local portableFuel=require('common/rlsFuelConfig')
local economy=require('common/rlsFuelEconomy')
local generations, snapshots, scheduled, pending, resetState, retainedTanks = {}, {}, {}, {}, {}, {}
local serial, clock, panel = 0,0,nil
local menuOpen = false
-- The game's own nitrous energy per kg (refueling screen); the pump sells nitrous by weight.
local N2O_J_PER_KG=8.3e6
local J_PER_KWH=3.6e6
local captures = {}
local importedConfigs, testSetups = {}, {}
local originalRefuel, refuelWrapper
-- Retries keep request identity; absolute age uses `started`, not the retry stamp.
local REQUEST_RETRY_S, REQUEST_STUCK_S, REQUEST_GONE_S = 2, 15, 10
local function activeCareer() return overhaul_career_career and overhaul_career_career.isActive() or false end
local function getObject(id) return id and be:getObjectByID(id) end
local function playerId() return be and be:getPlayerVehicleID(0) end
local function inventoryId(id)
  if not activeCareer() then return nil end
  return overhaul_career_garage_inventory and overhaul_career_garage_inventory.getInventoryIdFromVehicleId(id)
end
local function recordFor(id)
  if not activeCareer() then return nil end
  local inv=inventoryId(id)
  if inv then return overhaul_career_garage_inventory.getVehicle(inv),inv end
  local b=overhaul_career_business_fleet
  if b and b.getBusinessVehicleFromSpawnedId then
    local businessId,vehicleId=b.getBusinessVehicleFromSpawnedId(id)
    if businessId and vehicleId and b.getVehicleById then return b.getVehicleById(businessId,vehicleId),nil,{businessId=businessId,vehicleId=vehicleId} end
  end
end
local function partIdentityHint(key, fallback)
  if type(key)~='string' or key=='' then return fallback end
  -- Device/condition container names are not physical part identity.
  if key=='mainEngine' or key=='powertrain' or key=='integrityState' or key=='root' or key=='pc' then return fallback end
  local leaf=key:match('([^/]+)$') or key
  if leaf=='mainEngine' or leaf=='powertrain' or leaf=='integrityState' then return fallback end
  return leaf
end
local function collectConditions(value,out,partHint)
  if type(value)~='table' then return end
  if value.rlsFuelEngineState then
    local s=model.copy(value.rlsFuelEngineState)
    local hint=partIdentityHint(partHint)
    -- Prefer a real jbeam/part name over a stale deviceName stamp like "mainEngine".
    if hint and (s.partOrigin==nil or s.partOrigin=='' or s.partOrigin==s.deviceName or s.partOrigin=='mainEngine') then
      s.partOrigin=hint
    end
    out.engines[s.deviceName or 'mainEngine']=s
  end
  if value.rlsFuelTank then local s=value.rlsFuelTank;out.tanks[s.name]=model.copy(s) end
  for k,child in pairs(value) do
    if k~='rlsFuelEngineState' and k~='rlsFuelTank' and type(child)=='table' then
      collectConditions(child,out,partIdentityHint(k,partHint))
    end
  end
end
local function collectInventoryEngineConditions(inventoryId,out)
  if not inventoryId or not overhaul_career_parts_partInventory or not overhaul_career_parts_partInventory.getInventory then return end
  local parts=overhaul_career_parts_partInventory.getInventory()
  for _,part in pairs(parts or {}) do
    if part.location==inventoryId and part.partCondition then
      collectConditions(part.partCondition,out,part.name)
    end
  end
end
local function samePhysicalEngine(a,b)
  if not a or not b then return false end
  if a.engineOwner and b.engineOwner and a.engineOwner~=b.engineOwner then return false end
  local ao,bo=a.partOrigin,b.partOrigin
  if not ao or not bo or ao=='' or bo=='' then return false end
  if ao=='mainEngine' or bo=='mainEngine' or ao==(a.deviceName or 'mainEngine') or bo==(b.deviceName or 'mainEngine') then
    return false
  end
  return ao==bo
end
local function send(id,kind,payload,callback)
  local veh=getObject(id);if not veh or not generations[id] then return nil end
  serial=serial+1;local requestId=tostring(id)..':'..tostring(generations[id])..':'..tostring(serial)
  pending[requestId]={vehicleId=id,generation=generations[id],callback=callback,started=clock,lastAttempt=clock,kind=kind,payload=model.copy(payload)}
  veh:queueLuaCommand("if not extensions.rlsFuelRuntime then extensions.load('rlsFuelRuntime') end; if extensions.rlsFuelRuntime then extensions.rlsFuelRuntime.request("..serialize(kind)..','..serialize(payload or {})..','..serialize(requestId)..','..generations[id]..') end')
  return requestId
end
local function failPending(requestId,p,message)
  pending[requestId]=nil
  if p.callback then p.callback({ok=false,message=message}) end
end
local function initVehicle(id)
  local veh=getObject(id);if not veh then return end
  local rec,inv=recordFor(id)
  if id~=playerId() and not rec and not testSetups[id] then return end
  local vm=core_vehicle_manager.getVehicleData(id)
  -- Exported setups are data in freeroam. Do not even discover/bind the runtime:
  -- discovery can change tank chemistry and engine condition before updateGFX.
  if not rec and ((testSetups[id] and testSetups[id].native) or (not testSetups[id] and vm and vm.config and portableFuel.isPortable(vm.config.rlsFuel))) then
    generations[id]=nil;snapshots[id]=nil
    veh:queueLuaCommand("if extensions.rlsFuelRuntime then extensions.unload('rlsFuelRuntime') end; if extensions.overhaulFuelMultiplier then extensions.unload('overhaulFuelMultiplier') end")
    return
  end
  -- Retain a monotonic epoch across extension reloads in this GE VM.
  _G.rlsFuelGeneration=(_G.rlsFuelGeneration or 0)+1
  generations[id]=_G.rlsFuelGeneration
  local payload={generation=generations[id],career=activeCareer() and rec~=nil,engines={},tanks={},engineOwners={}}
  if rec then
    collectConditions(rec.partConditions,payload)
    -- Part installs can update inventory entries before vehicle.partConditions is
    -- complete; pull engine blobs from parts on this vehicle as a second source.
    collectInventoryEngineConditions(inv,payload)
    -- Drop blobs that belong to a different physical part than what is installed.
    -- Fleet conditions belong to the fleet record, not the personal parts catalog.
    if inv then
      local installedNames={}
      if overhaul_career_parts_partInventory and overhaul_career_parts_partInventory.getInventory then
        for partId,part in pairs(overhaul_career_parts_partInventory.getInventory() or {}) do
          if part.location==inv and type(part.name)=='string' then
            installedNames[part.name]=true
            payload.engineOwners[part.name]='part:'..tostring(part.id or partId)
          end
        end
      end
      -- Acquisition registers a vehicle before its asynchronous part inventory.
      -- Wait for physical parts rather than creating default owned fuel records
      -- that would incorrectly supersede a portable setup on the next bind.
      if not next(installedNames) and vm and vm.config and portableFuel.isPortable(vm.config.rlsFuel) then scheduled[id]=0.1;return end
      for name,state in pairs(payload.engines) do
        local origin=state and state.partOrigin
        if origin and origin~='' and origin~='mainEngine' and not installedNames[origin] then
          payload.engines[name]=nil
        end
      end
      if vm and vm.config and portableFuel.seed(vm.config.rlsFuel,payload.engines,installedNames) then
        importedConfigs[id]=true
        local setup=portableFuel.read(vm.config.rlsFuel)
        for name,tank in pairs(setup and setup.tanks or {}) do
          if not payload.tanks[name] then payload.tanks[name]=model.copy(tank) end
        end
      end
      -- Both record sources were read, so an engine missing here is new to Fuels.
      payload.recordsChecked=overhaul_career_parts_partInventory~=nil and overhaul_career_parts_partInventory.getInventory~=nil
    end
  elseif testSetups[id] then
    payload.engines=model.copy(testSetups[id].engines)
    payload.tanks=model.copy(testSetups[id].tanks)
  elseif vm and vm.config and type(vm.config.rlsFuel)=='table' then
    for name,e in pairs(vm.config.rlsFuel.engines or {}) do payload.engines[name]=model.copy(e.state or e) end
    payload.tanks=model.copy(vm.config.rlsFuel.tanks or {})
  elseif not rec then
    payload.freshConfig=true
  end
  if resetState[id] then
    local saved=resetState[id];resetState[id]=nil
    -- Engine calibration is owned by the physical part. Vehicle reset after a
    -- parts swap reuses device names (mainEngine) and must not copy the previous
    -- engine's snapshot onto the replacement. Career uses part/inventory records
    -- above; freeroam keeps snapshot continuity via config.
    if rec then
      for name,e in pairs(saved.engines or {}) do
        local incoming=model.copy(e.state or e)
        if e.partOrigin and (incoming.partOrigin==nil or incoming.partOrigin=='' or incoming.partOrigin=='mainEngine') then incoming.partOrigin=e.partOrigin end
        local existing=payload.engines[name]
        if samePhysicalEngine(existing,incoming) then
          payload.engines[name]=incoming
        end
      end
    end
    -- Career tanks stay with the vehicle across reset/rebuild. A freeroam reset
    -- keeps the native refill; the blend stays on the tank itself.
    if not activeCareer() and not testSetups[id] then payload.tanks={}
    elseif (rec or not payload.freshConfig) and saved.tanks and next(saved.tanks) then
      if not next(payload.tanks) then payload.tanks=model.copy(saved.tanks)
      else for name,t in pairs(saved.tanks) do if not payload.tanks[name] then payload.tanks[name]=model.copy(t) end end end
    end
  end
  for name,tank in pairs(retainedTanks[id] or {}) do payload.tanks[name]=model.copy(tank) end
  retainedTanks[id]=nil
  -- Until a record is first bound as owned, its saved tank fuel is the seller's
  -- or employer's fill (saved when the record was created), not fuel the player
  -- chose; the car is delivered as bought instead.
  if rec and not rec.rlsFuelDelivered then payload.asBought=true end
  payload.flamePalette=require('overhaul/lib/vehicles/flamePalette').ensure()
  payload.dieselSmokePalette=require('overhaul/lib/vehicles/dieselSmokePalette').ensure()
  veh:queueLuaCommand("extensions.load('rlsFuelRuntime'); extensions.rlsFuelRuntime.configure("..serialize(payload)..")")
  if payload.career then veh:queueLuaCommand("extensions.load('overhaulFuelMultiplier')")
  else veh:queueLuaCommand("if extensions.overhaulFuelMultiplier then extensions.unload('overhaulFuelMultiplier') end") end
end
-- What a pump visit owes so far (see addToTab); personalOnly leaves out business-paid entries.
local function tabOwed(origin,personalOnly)
  local owed=0
  for _,entry in ipairs(origin and origin.tab or {}) do
    if not entry.payer.free and not (personalOnly and entry.payer.businessId) then owed=owed+(entry.payer.amount or 0) end
  end
  return math.floor(owed*100+0.5)/100
end
-- Money the player can still spend at the pump (set after payerFor below); false when
-- the fill is free or billed to a business.
local pumpFunds
-- Energy kinds on the car that this station sells but the pump can't fill; the pump then
-- offers the game's own refuel screen for them (a hybrid's battery, for one).
local function otherEnergy(origin)
  local kinds={}
  for kind in pairs(origin.otherStorages or {}) do
    local types=origin.nativeTypes
    if not types or types.any or types[kind] then kinds[#kinds+1]=kind end
  end
  table.sort(kinds)
  return #kinds>0 and kinds or false
end
local function hardwarePrice(amount)
  local payment = panel and panel.workshopPayment
  if not payment then return amount end
  return math.floor(amount * payment.priceMultiplier * 100 + 0.5) / 100
end

local function hardwareQuote(snapshot)
  if not snapshot or not panel.workshopPayment then return snapshot end
  local quoted = model.copy(snapshot)
  for _, engine in pairs(quoted.engines or {}) do
    for _, options in pairs(engine.hardware or {}) do
      for _, option in ipairs(options) do
        option.price = option.owned and 0 or hardwarePrice(option.price or 0)
      end
    end
  end
  return quoted
end

local function publish(message)
  if not panel then return end
  if message then panel.message=message end
  local s=snapshots[panel.vehicleId]
  -- Named keys retain stage identity across Lua's 1-based array to JSON conversion.
  local deliveryPrices={stage0=0}
  for stage,price in pairs(economy.deliveryStagePrices) do deliveryPrices['stage'..stage]=price end
  -- An electric car has no fuel snapshot; the pump still needs the career flag to price its charge.
  if not s and panel.mode=='pump' then s={vehicleId=panel.vehicleId,career=activeCareer() and recordFor(panel.vehicleId)~=nil,engines={},tanks={},unsupported={}} end
  guihooks.trigger('RlsFuelPanel',{open=true,paused=panel.mode=='pump' and menuOpen,mode=panel.mode,data=hardwareQuote(s) or false,station=panel.station and panel.station.facility,
    payerLabel=panel.workshopPayment and panel.workshopPayment.label or (panel.businessId and 'Racing Team account' or nil),
    grades=panel.grades,pricePerL=panel.pricePerL,quote=panel.quote or false,busy=panel.busy or false,
    pumping=panel.pumping and {delivered=panel.pumping.delivered,total=panel.pumping.liters,paid=panel.pumping.paid,drain=panel.pumping.drain or false} or false,
    message=panel.message or false,nitrous=panel.nitrous or false,charge=panel.charge or false,otherEnergy=otherEnergy(panel),owed=tabOwed(panel),funds=pumpFunds and pumpFunds(panel) or false,conversionPrice=hardwarePrice(economy.conversionPrice),methanolConversionPrice=hardwarePrice(economy.methanolConversionPrice),nitroConversionPrice=hardwarePrice(economy.nitroConversionPrice),flushPrice=economy.flushPrice,deliveryStagePrices=deliveryPrices,
    tunePrice=overhaul_career_parts_tuning and overhaul_career_parts_tuning.getFuelMapPrice and overhaul_career_parts_tuning.getFuelMapPrice() or economy.tunePrice})
end
local function persist(id, done, waitForCapture)
  local rec,inv,biz=recordFor(id)
  local capture={started=clock,generation=generations[id],attempt=0}
  captures[capture]=true
  local function finished(ok)
    if not captures[capture] then return end
    captures[capture]=nil
    if ok~=false and rec then extensions.hook('onOverhaulFuelSystemPersisted',id,rec.partConditions) end
    if done then done(ok) end
    if ok~=false and activeCareer() and overhaul_career_career.isAutosaveEnabled() then saveStore.request(biz and 'fuelSystem:fleet' or 'fuelSystem') end
  end
  local function sameContext()
    return getObject(id) and generations[id]==capture.generation and recordFor(id)==rec
  end
  local function requestCapture()
    capture.started=clock;capture.attempt=capture.attempt+1
    local attempt=capture.attempt
    local accepted=not waitForCapture
    local function accept(response)
      if not captures[capture] or capture.attempt~=attempt or not sameContext() then return false end
      local conditions=type(response)=='table' and response.result
      if type(conditions)=='table' and conditions.format=='overhaul_inventory_state_v1' then conditions=conditions.partConditions end
      accepted=type(conditions)=='table'
      return accepted
    end
    local function received(ok)
      if not captures[capture] or capture.attempt~=attempt then return end
      if waitForCapture and (not accepted or ok==false or not sameContext()) then return end
      finished(ok)
    end
    if inv then overhaul_career_garage_inventory.updatePartConditions(nil,inv,received,nil,waitForCapture and accept or nil)
    elseif biz then overhaul_career_business_fleet.persistSpawnedFleetVehiclePartConditions(biz.businessId,biz.vehicleId,received,waitForCapture and accept or nil)
    else finished() end
  end
  capture.finish=function()
    if not waitForCapture then finished()
    elseif sameContext() then
      if panel and panel.vehicleId==id then publish('Still waiting for the installed changes to be saved; retrying') end
      requestCapture()
    else finished(false) end
  end
  if inv then
    overhaul_career_garage_inventory.setVehicleDirty(inv)
    if overhaul_career_garage_inventory.isTransientBuild and overhaul_career_garage_inventory.isTransientBuild(inv) then
      -- Inventory deliberately skips hub-car condition captures. Fuel edits are
      -- already confirmed by VE and must reach both durable copies before a
      -- reset, JBeam tuning preview, service exit or autosave can rebuild the car.
      local s=snapshots[id]
      if s and s.generation==generations[id] then
        require('overhaul/lib/vehicles/fuelSnapshot')(rec.partConditions,s,inv)
        extensions.hook('onOverhaulConfirmedFuelSystemState',inv,s)
        local parts=overhaul_career_parts_partInventory
        if parts and parts.updatePartConditionsInInventory then parts.updatePartConditionsInInventory(inv) end
      end
      finished()
    else
      requestCapture()
    end
  elseif biz then
    local dyno=overhaul_career_parts_dyno_dynoSession
    local key=overhaul_career_business_fleet.getBusinessVehicleIdentifier and
      overhaul_career_business_fleet.getBusinessVehicleIdentifier(biz.businessId,biz.vehicleId)
    local access=key and dyno and dyno.getVehicleAccess and dyno.getVehicleAccess(key)
    if access and access.inventory.isTransientBuild(key) then
      local s=snapshots[id]
      if s and s.generation==generations[id] then
        dyno.onOverhaulConfirmedFuelSystemState(key,s)
        finished()
      else finished(false) end
    else requestCapture() end
  else finished() end
end
function M.onVehicleReply(result)
  local s=result and result.data
  if type(s)~='table' then return end
  local current=generations[s.vehicleId]==s.generation
  -- A delayed acknowledgement may settle its own payment, but must not
  -- replace a newer live calibration snapshot in the same generation.
  local previous=snapshots[s.vehicleId]
  if current and previous and previous.generation==s.generation then
    for name,e in pairs(s.engines or {}) do
      local old=previous.engines and previous.engines[name]
      if old and (old.state.revision or 0)>(e.state.revision or 0) then s.engines[name]=model.copy(old) end
    end
  end
  if current then snapshots[s.vehicleId]=s end
  local p=result.requestId and pending[result.requestId]
  -- Settle an acknowledged operation against its captured owner even if the
  -- player has switched cars. Stale snapshots never replace current state.
  if p and p.vehicleId==s.vehicleId and p.generation==(result.requestGeneration or s.generation) then
    pending[result.requestId]=nil
    if p.callback then p.callback(result) end
  end
  if not current then return end
  local vm=core_vehicle_manager.getVehicleData(s.vehicleId)
  -- Configuration serialization retains freeroam calibration; Career ownership
  -- is exclusively native engine part conditions, never this chassis cache.
  if vm and vm.config and not activeCareer() and not testSetups[s.vehicleId] and not portableFuel.isPortable(vm.config.rlsFuel) then vm.config.rlsFuel=model.copy(s) end
  if importedConfigs[s.vehicleId] then
    importedConfigs[s.vehicleId]=nil
    persist(s.vehicleId,nil,true)
  end
  local rec=recordFor(s.vehicleId)
  if rec and s.career and not rec.rlsFuelDelivered then rec.rlsFuelDelivered=true;persist(s.vehicleId) end
  if panel and panel.vehicleId==s.vehicleId then publish() end
end
-- Garage services and the career computer's tune screen are bound to the
-- selected inventory vehicle; the player is usually on foot beside it.
local function followsPlayer() return panel.mode~='garage' and panel.mode~='hardware' and panel.mode~='pump' and not panel.inventoryId end
local function pumpTargetAvailable()
  local veh=panel and getObject(panel.vehicleId)
  if not veh or veh:getVelocity():length()>2 then return false end
  if panel.vehicleId==playerId() then return true end
  local player=getObject(playerId())
  if not player or not player.getJBeamFilename or player:getJBeamFilename()~='unicycle' then return false end
  if activeCareer() and not recordFor(panel.vehicleId) then return false end
  local stations=overhaul_world_fuel_gasStations
  if stations and stations.isWalkUpRefuelTargetInRange then return stations.isWalkUpRefuelTargetInRange(veh) end
  return veh.getPosition and player.getPosition and veh:getPosition():distance(player:getPosition())<=10
end
local function currentContext()
  if not panel or not getObject(panel.vehicleId) then return nil,'Vehicle unavailable' end
  if panel.workshopPayment then
    local payment = panel.workshopPayment
    local context = overhaul_career_business_partCustomization.getFuelHardwareContext(payment.businessId, panel.workshopVehicleId)
    if not overhaul_career_business_manager.isPurchasedBusiness(payment.businessType, payment.businessId)
      or not context or context.vehicleId ~= panel.vehicleId or context.inventoryId ~= panel.inventoryId then
      return nil, 'Workshop vehicle changed; reopen Fuel Hardware'
    end
  end
  if panel.businessId then
    local record,_,owner=recordFor(panel.vehicleId)
    if record~=panel.businessRecord or not owner or tostring(owner.businessId)~=tostring(panel.businessId)
      or tostring(owner.vehicleId)~=tostring(panel.fleetVehicleId)
      or not overhaul_career_business_manager.isPurchasedBusiness('racingTeam',owner.businessId) then
      return nil,'Team vehicle changed; reopen the fuel panel'
    end
    if panel.workshop and not overhaul_career_business_partCustomization.getFuelHardwareContext(panel.businessId,panel.fleetVehicleId) then
      return nil,'Purchase or discard pending workshop changes before using fuel services'
    end
  end
  if panel.busy then return nil,'An operation is already in progress' end
  if panel.mode=='pump' and not pumpTargetAvailable() then return nil,'Pump target unavailable or too far away' end
  if followsPlayer() and panel.vehicleId~=playerId() then return nil,'Vehicle selection changed' end
  return snapshots[panel.vehicleId]
end
local function matchingContext(s,expected)
  if not expected then return true end -- Backward-compatible callers.
  if type(expected)~='table' or expected.vehicleId~=s.vehicleId or expected.generation~=s.generation or expected.mode~=panel.mode then
    publish('Vehicle selection changed; reopen the fuel panel');return false
  end
  return true
end
local function payerFor(id,kind,amount)
  if not activeCareer() or amount<=0 then return {free=true} end
  if panel and panel.vehicleId == id and panel.workshopPayment and (kind == 'installHardware' or kind == 'convert') then
    local payment = panel.workshopPayment
    amount = hardwarePrice(amount)
    local balance = overhaul_career_economy_bank.getAccountBalance(payment.accountId)
    if not balance or balance < amount then return nil end
    return {businessId = payment.businessId, accountId = payment.accountId, amount = amount, workshopService = true}
  end
  local rec,inv,biz=recordFor(id)
  if biz and overhaul_career_business_manager and overhaul_career_business_manager.isPurchasedBusiness('racingTeam',biz.businessId) then
    local account=overhaul_career_economy_bank.getBusinessAccount('racingTeam',biz.businessId)
    if not account or (tonumber(account.balance) or 0)<amount then return nil end
    return {businessId=biz.businessId,accountId=account.id,amount=amount,teamService=true}
  end
  if kind=='deliver' or kind=='charge' then
    local job=overhaul_career_work_employment
    if rec and (rec.loanType=='work' or (rec.loanType=='company' and job and job.isOnShift and job.isOnShift()
      and job.getEmployerOrgId and rec.owningOrganization==job.getEmployerOrgId())) then return {free=true} end
    if biz then return {businessId=biz.businessId,amount=amount} end
  end
  if not overhaul_career_economy_payment or not overhaul_career_economy_payment.canPay({money={amount=amount,canBeNegative=false}}) then return nil end
  return {amount=amount}
end
local function settle(payer,kind,paidFuelAmount)
  if payer.free then return end
  local fuelPurchase=kind=='purchase' or kind=='deliver' or kind=='charge' or kind=='nitrous'
  local label=fuelPurchase and 'Fuel purchase' or 'Fuel system: '..kind
  local category=fuelPurchase and 'fuel' or 'service'
  if payer.workshopService then
    return overhaul_career_economy_bank.payFromAccount({money={amount=payer.amount,canBeNegative=true}},
      payer.accountId,label,label,require('overhaul/lib/finance/metadata').tag(nil,'purchase',{businessId=payer.businessId}))
  end
  if payer.teamService then
    return overhaul_career_economy_bank.payFromAccount({money={amount=payer.amount,canBeNegative=true}},
      payer.accountId,label,label,require('overhaul/lib/finance/metadata').tag(nil,
        category,{businessId=payer.businessId}))
  end
  local business=overhaul_career_business_racingTeam_finances
  if payer.businessId and business and business.tryDebitVehicleFuelCost(payer.businessId,payer.amount,label) then return end
  -- Like the existing pump, bill actual delivered fuel after confirmation. The
  -- captured price/owner cannot change while the vehicle request is in flight.
  -- Affordability was checked before dispatch; delivered goods remain payable
  -- if another charge changed the balance before the acknowledgment arrived.
  overhaul_career_economy_payment.pay({money={amount=payer.amount,canBeNegative=true}},
    require('overhaul/lib/finance/metadata').tag(
      {label=label,tags=fuelPurchase and {'fuel','buying'} or {'fuel','tuning','buying'}},category))
  local fuelAmount=paidFuelAmount or (kind=='deliver' and payer.amount or 0)
  if fuelAmount>0 and gameplay_statistic then gameplay_statistic.metricAdd('career/fuel/paidPrice.money',fuelAmount) end
end
-- Pump visits run a tab, like paying at the counter: each delivery is recorded with its
-- payer and billed once when the pump closes (Pay & leave, the close button, or the pump
-- going away). A delivery confirmed after the tab was settled is billed on its own.
-- Bills what is on the tab so far and keeps the tab open.
local function billTab(origin)
  local billed=#origin.tab>0
  local bills={}
  local businessFunds={}
  for _,entry in ipairs(origin.tab) do
    local payer=entry.payer
    if not payer.free then
      local cents=math.floor((payer.amount or 0)*100+0.5)
      -- Preserve the old per-step business/wallet fallback before combining bills.
      -- A business may afford some deliveries even when it cannot fund the visit.
      local bank=overhaul_career_economy_bank
      if payer.businessId and not payer.teamService and bank and bank.getBusinessAccount
        and overhaul_career_business_racingTeam_finances then
        local account=bank.getBusinessAccount('racingTeam',payer.businessId)
        local accountId=account and (account.id or account.accountId)
        if accountId then
          local funds=businessFunds[accountId]
          if not funds then
            local balance=bank.getAccountBalance and bank.getAccountBalance(accountId) or account.balance
            funds={balance=tonumber(balance) or 0,cents=0}
            funds.remaining=funds.balance
            businessFunds[accountId]=funds
          end
          -- Match the bank's strict checks both for the old step allocation and
          -- for the single combined debit; float noise must not reject that bill.
          if not (funds.remaining<cents/100) and not (funds.balance<(funds.cents+cents)/100) then
            funds.remaining=funds.remaining-cents/100
            funds.cents=funds.cents+cents
          else
            payer={amount=payer.amount}
          end
        else
          payer={amount=payer.amount}
        end
      end
      local bill
      for _,candidate in ipairs(bills) do
        local captured=candidate.payer
        if captured.businessId==payer.businessId and captured.accountId==payer.accountId
          and captured.teamService==payer.teamService then bill=candidate;break end
      end
      if not bill then
        bill={payer=model.copy(payer),cents=0,fuelCents=0}
        bills[#bills+1]=bill
      end
      -- Step prices subtract rounded cumulative prices and can carry float noise.
      -- Sum their individual cents, rather than rounding a new volume-based price.
      bill.cents=bill.cents+cents
      if entry.kind=='deliver' then bill.fuelCents=bill.fuelCents+cents end
    end
  end
  for _,bill in ipairs(bills) do
    bill.payer.amount=bill.cents/100
    settle(bill.payer,'purchase',bill.fuelCents/100)
  end
  origin.tab={}
  if origin.tabHold then origin.tabHold.release();origin.tabHold=nil end
  return billed
end
local function addToTab(origin,payer,kind)
  if not origin.tab or origin.tabSettled then settle(payer,kind);return end
  table.insert(origin.tab,{payer=payer,kind=kind})
  -- The fuel is saved as soon as it is confirmed, so no save may go out without its bill:
  -- a save first bills the open tab (save hold recovery runs before every autosave).
  if activeCareer() and not origin.tabHold then
    origin.tabHold=saveStore.hold(M,'unpaid pump tab',{recover=function()
      if billTab(origin) and panel==origin then publish() end
    end})
  end
end
local function canAffordWithTab(origin,payer)
  if payer.teamService then
    local balance=overhaul_career_economy_bank.getAccountBalance(payer.accountId)
    return (tonumber(balance) or 0)>=tabOwed(origin)+(payer.amount or 0)
  end
  if payer.free or payer.businessId or not overhaul_career_economy_payment then return true end
  return overhaul_career_economy_payment.canPay({money={amount=tabOwed(origin,true)+(payer.amount or 0),canBeNegative=false}})
end
pumpFunds=function(origin)
  if not origin or origin.mode~='pump' or not activeCareer() then return false end
  local payer=payerFor(origin.vehicleId,'deliver',0.01)
  if payer and (payer.free or payer.businessId) then return false end
  local attributes=overhaul_career_economy_playerAttributes
  local money=attributes and attributes.getAttributeValue and tonumber(attributes.getAttributeValue('money')) or 0
  return math.max(0,math.floor((money-tabOwed(origin,true))*100)/100)
end
local function settleTab(origin)
  if not origin or not origin.tab or origin.tabSettled then return false end
  origin.tabSettled=true
  return billTab(origin)
end
local function perform(kind,payload,price,onComplete)
  local s,err=currentContext();if not s then publish(err);return false end
  local id=panel.vehicleId;local origin=panel
  local payer=payerFor(id,kind,price)
  if not payer then publish('Not enough money');return false end
  -- Pump steps repeat every 0.25 s; keep the pump status stable instead of
  -- clearing it and announcing each step.
  local step=kind=='deliver' or (payload and payload.pumpStep)
  origin.busy=true;origin.quote=nil;if not step then origin.message=nil end;publish()
  local hold = activeCareer() and saveStore.hold(M, 'fuel transaction') or nil
  local function release() if hold then hold.release();hold=nil end end
  local function complete(result)
    origin.persisting=nil
    origin.busy=false
    if onComplete then onComplete(result) end
    if panel==origin then publish(not step and (result.ok and 'Completed' or result.message) or nil) end
  end
  local requestId=send(id,kind,payload,function(result)
    if result.ok then
      if not step then origin.persisting=true end
      if kind=='deliver' then addToTab(origin,payer,kind) else settle(payer,kind) end
      local inv=inventoryId(id)
      if inv and (kind=='applyTune' or kind=='recalibrateRpm' or kind=='convert' or kind=='removeConversion' or kind=='installHardware') and overhaul_career_parts_vehiclePerformance then
        overhaul_career_parts_vehiclePerformance.invalidateCertification(inv)
      end
      persist(id,function(saved)
        release()
        if not step then complete(saved==false and {ok=false,message='Vehicle changed before the installed changes could be saved'} or result) end
      end,not step)
      if step then complete(result) end
    else release();complete(result) end
  end)
  if not requestId then release();origin.busy=false;publish('Vehicle unavailable');return false end
  pending[requestId].paid=not payer.free and (payer.amount or 0)>0
  return true
end
function M.openTuning()
  if panel and panel.busy then return false end
  local id=playerId();local inv,computerId,team
  if activeCareer() then
    local context=overhaul_career_parts_tuning and overhaul_career_parts_tuning.getFuelMapContext and overhaul_career_parts_tuning.getFuelMapContext()
    if not context or not context.inventoryId then return false end
    inv,computerId=context.inventoryId,context.computerId
    local dyno=overhaul_career_parts_dyno_dynoSession
    local access=dyno and dyno.getVehicleAccess and dyno.getVehicleAccess(inv)
    team=access and access.service(inv)
    id=(access and access.inventory or overhaul_career_garage_inventory).getVehicleIdFromInventoryId(inv)
    if not id then return false end
  end
  settleTab(panel) -- a pump visit being replaced still pays its tab
  panel={vehicleId=id,inventoryId=inv,computerId=computerId,mode=inv and 'garage' or 'tuning'}
  if team then panel.businessId,panel.fleetVehicleId,panel.businessRecord=team.businessId,team.vehicleId,team.record end
  if not snapshots[id] then initVehicle(id) end
  publish();send(id,'inspect',{})
  return true
end
-- Temporary playtest entry used by the RLS Tester menu. The Tuning menu is
-- the normal way in; this opens it for the occupied vehicle.
function M.openDevShortcut()
  if not (overhaul_shell_extensionManager and overhaul_shell_extensionManager.isDevKeyValid and overhaul_shell_extensionManager.isDevKeyValid(true)) then return false end
  local id=playerId()
  if not id or id<=0 or (panel and panel.busy) then return false end
  settleTab(panel) -- a pump visit being replaced still pays its tab
  panel={vehicleId=id,mode='tuning'}
  if not snapshots[id] then initVehicle(id) end
  publish();send(id,'inspect',{})
  return true
end
local function needsHardwareRepair(id)
  local vehicle,inv=recordFor(id)
  return not vehicle or overhaul_career_market_valueCalculator.getNumberOfBrokenParts(vehicle.partConditions)>0
    or (inv and overhaul_career_repair_insurance.inventoryVehNeedsRepair(inv))
end
local function hardwareAccess()
  if not activeCareer() then return true end
  if not panel or panel.mode~='hardware' then publish('Open Fuel Hardware in Parts Customization');return false end
  if needsHardwareRepair(panel.vehicleId) then publish('Repair the vehicle before installing fuel hardware');return false end
  return true
end
local function openGarage(inv,computerId,mode,id,businessId,fleetVehicleId,payment)
  if panel and panel.busy then return false end
  id=id or overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inv)
  if not id then return false end
  if mode=='hardware' and needsHardwareRepair(id) then return false end
  settleTab(panel) -- a pump visit being replaced still pays its tab
  panel={vehicleId=id,inventoryId=inv,computerId=computerId,mode=mode,
    workshopPayment=payment,workshopVehicleId=payment and fleetVehicleId}
  if businessId and overhaul_career_business_manager and overhaul_career_business_manager.isPurchasedBusiness('racingTeam',businessId) then
    local record,_,owner=recordFor(id)
    if not owner or tostring(owner.businessId)~=tostring(businessId) or tostring(owner.vehicleId)~=tostring(fleetVehicleId) then panel=nil;return false end
    panel.businessId,panel.fleetVehicleId,panel.businessRecord=businessId,fleetVehicleId,record
    panel.workshop=true
  end
  -- Always rebind from part/inventory records. Shopping confirm leaves a stale
  -- preview snapshot that would otherwise keep showing Original after a swap.
  initVehicle(id)
  publish();send(id,'inspect',{});return true
end
function M.openPartsHardware(businessId,vehicleId)
  local owner=businessId and overhaul_career_business_partCustomization or overhaul_career_parts_partShopping
  local context=owner and owner.getFuelHardwareContext(businessId,vehicleId)
  if not context then
    guihooks.trigger('toastrMsg',{type='warning',title='Fuel Hardware',msg='Purchase or discard pending parts and tuning before opening Fuel Hardware.'})
    return false
  end
  local payment
  local manager = overhaul_career_business_manager
  if businessId and not (manager and manager.isPurchasedBusiness('racingTeam',businessId)) then
    local computer = overhaul_career_business_computer
    payment = manager and computer and computer.getPartsPaymentContext(businessId)
    if not payment then
      guihooks.trigger('toastrMsg',{type='warning',title='Fuel Hardware',msg='Workshop account unavailable; reopen Parts Customization.'})
      return false
    end
  end
  return openGarage(context.inventoryId,context.computerId,'hardware',context.vehicleId,businessId,vehicleId,payment)
end
function M.openBusinessTuning(businessId,vehicleId)
  if not businessId or not vehicleId or not overhaul_career_business_manager.isPurchasedBusiness('racingTeam',businessId) then return false end
  local owner=overhaul_career_business_partCustomization
  local context=owner and owner.getFuelHardwareContext(businessId,vehicleId)
  if not context then
    guihooks.trigger('toastrMsg',{type='warning',title='Fuel & Ignition',msg='Purchase or discard pending parts and tuning before opening Fuel & Ignition.'})
    return false
  end
  return openGarage(context.inventoryId,context.computerId,'garage',context.vehicleId,businessId,vehicleId)
end
function M.isOpen() return panel ~= nil end
-- Boost cut outside the Fuel panel (PRO Tuner). Writes the same installed tune
-- value the map editor applies, so both screens always show one cut.
function M.setBoostCut(id,engine,margin)
  local s=snapshots[id];local e=s and s.engines and s.engines[engine]
  if not e then return false,'Fuel system not ready' end
  local ok,err=model.boostCutEditable(e.profile);if not ok then return false,err end
  margin=tonumber(margin)
  if not model.validBoostCutMargin(margin) then return false,'Invalid boost cut' end
  if panel and panel.vehicleId==id and panel.busy then return false,'An operation is already in progress' end
  local requestId=send(id,'setBoostCut',{engine=engine,margin=margin},function(result)
    if not result.ok then return end
    local inv=inventoryId(id)
    if inv and overhaul_career_parts_vehiclePerformance then overhaul_career_parts_vehiclePerformance.invalidateCertification(inv) end
    persist(id)
  end)
  if not requestId then return false,'Vehicle unavailable' end
  return true
end
local liveTrimPending={}
function M.setLiveTrim(id,engine,changes,expected)
  local s=snapshots[id];local e=s and s.engines and s.engines[engine]
  if not e or type(changes)~='table' or type(expected)~='table' or expected.vehicleId~=id or expected.generation~=s.generation then return false,'Vehicle changed' end
  if liveTrimPending[id] or (panel and panel.vehicleId==id and panel.busy) then return false,'Waiting for confirmation' end
  local payload={engine=engine,afrTrim=changes.afrTrim,boostOffset=changes.boostOffset,gearOffsets=changes.gearOffsets,expectedRevision=expected.revision}
  local t=fuelControl.effective(e.state,e.profile).tune
  if changes.afrTrim~=nil then t.afrTrim=changes.afrTrim end
  if changes.boostOffset~=nil or changes.gearOffsets~=nil then
    if e.boostSupported==false then return false,e.boostSupportReason or 'Boost control unsupported' end
    if not t.boost then return false,'Configure gear caps first' end
    t.boost.offset=changes.boostOffset or t.boost.offset;t.boost.offsets=changes.gearOffsets or t.boost.offsets
  end
  local ok,err=model.validateTune(t);if not ok then return false,err end
  liveTrimPending[id]=true
  local requestId=send(id,'setLiveTrim',payload,function(result)
    liveTrimPending[id]=nil
    if result.ok then
      local inv=inventoryId(id);if inv and overhaul_career_parts_vehiclePerformance then overhaul_career_parts_vehiclePerformance.invalidateCertification(inv) end
      persist(id)
    end
    guihooks.trigger('RlsFuelLiveTrimResult',{vehicleId=id,generation=s.generation,engine=engine,revision=expected.revision,ok=result.ok,message=result.message})
  end)
  if not requestId then liveTrimPending[id]=nil;return false,'Vehicle unavailable' end
  return true
end
-- Pay & leave: bill the tab, request a save, and close the pump.
function M.payAndLeave()
  if not panel or panel.mode~='pump' or panel.pumping or panel.busy then return false end
  local paid=settleTab(panel)
  if paid then
    persist(panel.vehicleId)
  end
  return M.close()
end
function M.close()
  if panel and panel.pumping then panel.pumping.stop=true;panel.pumping.close=true end
  if panel and panel.busy then publish(panel.persisting and 'Waiting for the installed changes to be saved' or 'Waiting for the vehicle to confirm the operation');return false end
  if panel and panel.pumping and panel.pumping.delivered>0 then persist(panel.vehicleId) end
  if panel and settleTab(panel) then persist(panel.vehicleId) end
  local returnTo=panel and panel.returnTo
  local reopenPrompt=panel and panel.mode=='pump' and not returnTo and not panel.handOff
  panel=nil;guihooks.trigger('RlsFuelPanel',{open=false})
  if returnTo and extensions.ui_router then extensions.ui_router.navigate('business-computer',returnTo) end
  -- Bring back the station prompt the pump hid, if the player is still standing at it.
  if reopenPrompt and overhaul_integration_services_markerInteraction then overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt() end
  return true
end
function M.convert(engine,kind,expected)
  kind=kind or 'ethanol'
  if kind~='ethanol' and kind~='methanol' and kind~='nitromethane' then return false end
  local s,err=currentContext();if not s then publish(err);return false end
  if not matchingContext(s,expected) then return false end
  if not s.engines[engine] then return false end
  if not hardwareAccess() then return false end
  if model.conversionKind(s.engines[engine].state)==kind then publish('This conversion is already installed');return false end
  local price=kind=='nitromethane' and economy.nitroConversionPrice or (kind=='methanol' and economy.methanolConversionPrice or economy.conversionPrice)
  return perform('convert',{engine=engine,conversionKind=kind},activeCareer() and price or 0)
end
-- Options are owned by the physical engine; swapping owned hardware is free.
function M.installHardware(engine,component,id,expected)
  local s,err=currentContext();if not s then publish(err);return false end
  if not matchingContext(s,expected) or not s.engines[engine] then return false end
  if not hardwareAccess() then return false end
  local e=s.engines[engine];local option=model.hardware.option(e.state,e.profile,component,id)
  if not option then publish('Unknown hardware option');return false end
  if e.state.hardware[component]==id then return false end
  return perform('installHardware',{engine=engine,component=component,id=id},activeCareer() and not option.owned and option.price or 0)
end
function M.setDeliveryStage() publish('Choose separate injectors and pump');return false end
function M.removeConversion(engine,expected)
  local s=currentContext();if not s or not matchingContext(s,expected) then return false end
  if panel.mode=='pump' or not hardwareAccess() then return false end
  if not s.engines[engine] or not s.engines[engine].state.conversion then publish('The standard fuel system is already installed');return false end
  return perform('removeConversion',{engine=engine},0)
end
function M.drain(tank,amount,expectedLiters,expectedBlend,expected)
  local s,err=currentContext();if not s then publish(err);return false end
  if not expected or not matchingContext(s,expected) then return false end
  if activeCareer() and panel.mode~='garage' and panel.mode~='pump' then publish('Drain fuel at a pump or a garage Fuel System service');return false end
  if panel.pumping then return false end
  local t=s.tanks and s.tanks[tank];if not t then publish('Tank unavailable');return false end
  local remaining,message=model.drainAmount(t.liters,t.blend,amount,expectedLiters,expectedBlend)
  if remaining==nil then publish(message);return false end
  return perform('drain',{tank=tank,liters=amount,expectedLiters=expectedLiters,expectedBlend=model.copy(expectedBlend)},0)
end
function M.flush(tank)
  if not panel or (panel.mode~='garage' and (activeCareer() or panel.mode~='pump')) then return false end
  return perform('flush',{tank=tank},activeCareer() and economy.flushPrice or 0)
end
function M.recalibrateRpm(engine,expected)
  if not panel or panel.mode=='pump' then return false end
  local s=currentContext();if not s or not matchingContext(s,expected) then return false end
  if not s.engines[engine] then publish('Engine unavailable');return false end
  return perform('recalibrateRpm',{engine=engine},0)
end
function M.applyTune(engine,tune,expected)
  local ok,err=model.validateTune(tune);if not ok then publish(err);return false end
  if not panel or panel.mode=='pump' then return false end
  local s=currentContext();if not s or not matchingContext(s,expected) then return false end
  return perform('applyTune',{engine=engine,tune=tune,expectedRevision=expected and expected.revision},0)
end
function M.savePreset(engine,name,tune,expected)
  if not panel or panel.mode=='pump' then return false end
  local s=currentContext();if not s or not matchingContext(s,expected) then return false end
  return perform('savePreset',{engine=engine,name=name,tune=tune,expectedRevision=expected and expected.revision},0)
end
local function managePreset(kind,engine,name,newName,expected)
  if not panel or panel.mode=='pump' or type(expected)~='table' then return false end
  local s=currentContext();if not s or not matchingContext(s,expected) then return false end
  if not s.engines[engine] then return false end
  return perform(kind,{engine=engine,name=name,newName=newName,expectedRevision=expected.revision},0)
end
function M.deletePreset(engine,name,expected)
  return managePreset('deletePreset',engine,name,nil,expected)
end
function M.renamePreset(engine,name,newName,expected)
  return managePreset('renamePreset',engine,name,newName,expected)
end
function M.invalidateQuote() if panel and not panel.busy then panel.quote=nil end end
function M.quote(tankName,gradeId,amount,clientToken)
  local s,err=currentContext();if not s then publish(err);return nil end
  if panel.mode~='pump' or panel.pumping then return nil end
  local t=s.tanks[tankName];local grade
  for _,g in ipairs(panel.grades) do if g.id==gradeId then grade=g end end
  if not t or not grade or (t.energyType=='diesel')~=(grade.diesel==true) or not model.finite(amount) then return nil end
  amount=model.clamp(amount,0,math.max(0,t.capacity-t.liters))
  local blend=model.mix(t.blend,t.liters,grade,amount)
  local warnings={}
  for _,e in pairs(s.engines) do
    local connected=false;for _,name in pairs(e.tanks or {}) do if name==tankName then connected=true end end
    local warning=connected and model.warning(e.profile,fuelControl.effective(e.state,e.profile),blend) or ''
    if warning~='' then warnings[#warnings+1]=e.name..': '..warning end
  end
  serial=serial+1
  local q={id=tostring(s.vehicleId)..':'..s.generation..':quote:'..serial,tank=tankName,grade=gradeId,
    liters=amount,resultBlend=blend,warning=table.concat(warnings,' '),clientToken=clientToken,
    expectedLiters=t.liters,expectedBlend=model.copy(t.blend),
    price=activeCareer() and amount>0 and math.max(0.01,math.floor(amount*panel.pricePerL*grade.priceFactor*100+0.5)/100) or 0}
  panel.quote=q;publish();return q
end
function M.purchaseFuel(quoteId,acknowledged)
  if menuOpen or not panel or panel.pumping or not panel.quote or panel.quote.id~=quoteId then return false end
  local q=panel.quote
  if q.liters<=0 or (q.warning~='' and acknowledged~=true) then publish('Acknowledge the fuel warning before pumping');return false end
  local s=currentContext();if not s then return false end
  local tank=s.tanks[q.tank]
  if not tank or math.abs(tank.liters-q.expectedLiters)>0.02 or math.abs(tank.blend.ethanol-q.expectedBlend.ethanol)>0.0001
    or math.abs((tank.blend.methanol or 0)-(q.expectedBlend.methanol or 0))>0.0001
    or math.abs((tank.blend.nitromethane or 0)-(q.expectedBlend.nitromethane or 0))>0.0001
    or math.abs(tank.blend.aki-q.expectedBlend.aki)>0.001 then panel.quote=nil;publish('Tank contents changed; request a new quote');return false end
  local payer=payerFor(panel.vehicleId,'deliver',q.price)
  if not payer or not canAffordWithTab(panel,payer) then publish('Not enough money');return false end
  panel.pumping=model.copy(q);panel.pumping.delivered=0;panel.pumping.paid=0;panel.pumping.tick=0;panel.pumping.step=0
  panel.quote=nil;panel.message=nil;publish();return true
end
function M.purchaseNitrous(name,kg)
  if menuOpen or not panel or panel.mode~='pump' or panel.busy or panel.pumping or not panel.nitrous then return false end
  if not panel.nitrous.offered then publish('This station does not sell nitrous');return false end
  local bottle;for _,b in ipairs(panel.nitrous.bottles) do if b.name==name then bottle=b end end
  local veh=getObject(panel.vehicleId)
  if not bottle or not veh then publish('Nitrous bottle unavailable');return false end
  kg=model.clamp(tonumber(kg) or 0,0,math.max(0,bottle.capacityKg-bottle.kg))
  if kg<=0 then return false end
  local price=activeCareer() and math.max(0.01,math.floor(kg*panel.nitrous.pricePerKg*100+0.5)/100) or 0
  local payer=payerFor(panel.vehicleId,'nitrous',price)
  if not payer or not canAffordWithTab(panel,payer) then publish('Not enough money');return false end
  core_vehicleBridge.executeAction(veh,'setEnergyStorageEnergy',bottle.name,(bottle.kg+kg)*N2O_J_PER_KG)
  addToTab(panel,payer,'nitrous')
  bottle.kg=bottle.kg+kg
  publish(string.format('Filled %.2f kg nitrous · $%.2f',kg,price));return true
end
-- Batteries are native electricEnergy storages, charged at the station's price per kWh.
function M.purchaseCharge(name,kwh)
  if menuOpen or not panel or panel.mode~='pump' or panel.busy or panel.pumping or not panel.charge then return false end
  local battery;for _,b in ipairs(panel.charge.batteries) do if b.name==name then battery=b end end
  local veh=getObject(panel.vehicleId)
  if not battery or not veh then publish('Battery unavailable');return false end
  kwh=model.clamp(tonumber(kwh) or 0,0,math.max(0,battery.capacityKWh-battery.kwh))
  if kwh<=0 then return false end
  local price=activeCareer() and math.max(0.01,math.floor(kwh*panel.charge.pricePerKWh*100+0.5)/100) or 0
  local payer=payerFor(panel.vehicleId,'charge',price)
  if not payer or not canAffordWithTab(panel,payer) then publish('Not enough money');return false end
  core_vehicleBridge.executeAction(veh,'setEnergyStorageEnergy',battery.name,(battery.kwh+kwh)*J_PER_KWH)
  addToTab(panel,payer,'charge')
  battery.kwh=battery.kwh+kwh
  publish(string.format('Charged %.2f kWh · $%.2f',kwh,price));return true
end
-- Pump drain runs like pumping: it empties in half-litre steps until it reaches the amount or
-- is stopped, so letting go of the button early stops it. Free; the fuel is thrown away.
function M.startDrain(tank,liters,expectedLiters,expectedBlend,expected)
  if menuOpen or not panel or panel.mode~='pump' or panel.busy or panel.pumping then return false end
  local s,err=currentContext();if not s then publish(err);return false end
  if not expected or not matchingContext(s,expected) then return false end
  local t=s.tanks and s.tanks[tank];if not t then publish('Tank unavailable');return false end
  local remaining,message=model.drainAmount(t.liters,t.blend,liters,expectedLiters,expectedBlend)
  if remaining==nil then publish(message);return false end
  -- tick starts full so the first step goes out on the next update.
  panel.pumping={drain=true,tank=tank,liters=math.min(liters,t.liters),price=0,delivered=0,paid=0,tick=0.25,step=0}
  publish();return true
end
function M.stopPumping() if panel and panel.pumping then panel.pumping.stop=true;if not panel.pumping.drain then publish('Stopping after the current delivery is confirmed') end end end
-- Player escape hatch when VE replies never arrive; never settles payment.
function M.cancelBusy()
  if not panel or not panel.busy then return false end
  if panel.persisting then publish('Waiting for the installed changes to be saved');return false end
  if panel.pumping then panel.pumping.stop=true end
  local id,cancelled,doomed=panel.vehicleId,false,{}
  for _,p in pairs(pending) do
    if p.vehicleId==id and p.paid then publish('Purchase already sent. Waiting for confirmation before settling payment.');return false end
  end
  for requestId,p in pairs(pending) do
    if p.vehicleId==id then doomed[#doomed+1]=requestId end
  end
  for _,requestId in ipairs(doomed) do
    local p=pending[requestId]
    if p then
      cancelled=true
      failPending(requestId,p,'Operation cancelled; no payment taken')
    end
  end
  if panel and panel.busy then
    panel.busy=false
    publish(cancelled and 'Operation cancelled; no payment taken' or 'Operation cancelled')
  end
  return true
end
local function pumpSellsDiesel(origin)
  for _,grade in ipairs(origin.grades or {}) do if grade.diesel then return true end end
  return false
end
-- Nitrous bottles use the station's n2o price per kg.
local function stationNitrousPrice(station)
  local facility=station.facility or station
  local price=overhaul_world_fuel_fuelPrice and overhaul_world_fuel_fuelPrice.getFuelPrice(facility.id,'n2o')
  if not price and facility.prices and facility.prices.n2o then price=facility.prices.n2o.priceBaseline end
  return price or 25
end
local function stationChargePrice(station)
  local facility=station.facility or station
  if station.rlsFuelChargePrice then return station.rlsFuelChargePrice end
  local price=overhaul_world_fuel_fuelPrice and overhaul_world_fuel_fuelPrice.getFuelPrice(facility.id,'electricEnergy')
  if not price and facility.prices and facility.prices.electricEnergy then price=facility.prices.electricEnergy.priceBaseline end
  return price or 1
end
local function batteriesIn(storages)
  local out={}
  for _,t in ipairs(storages or {}) do
    local capacity=(tonumber(t.maxEnergy) or 0)/J_PER_KWH
    if t.energyType=='electricEnergy' and capacity>0 then
      out[#out+1]={name=t.name,kwh=math.max(0,(tonumber(t.currentEnergy) or 0)/J_PER_KWH),capacityKWh=capacity}
    end
  end
  table.sort(out,function(a,b) return a.name<b.name end)
  return out
end
-- Reads the car's energy stores: nitrous bottles and batteries the pump sells into, and any
-- other kind (kerosine, or diesel or charging where the pump has none) that only the game's own
-- refuel screen can fill. storages: the native energyStorage list when already read.
local function readStorages(origin,storages)
  local function apply(list)
    if panel~=origin then return end
    local bottles,other={},{}
    for _,t in ipairs(list or {}) do
      local capacity=(tonumber(t.maxEnergy) or 0)/N2O_J_PER_KG
      local kind=t.energyType
      if kind=='n2o' and capacity>0 then
        bottles[#bottles+1]={name=t.name,kg=math.max(0,(tonumber(t.currentEnergy) or 0)/N2O_J_PER_KG),capacityKg=capacity}
      elseif type(kind)=='string' and kind~='gasoline' and kind~='n2o' and (tonumber(t.maxEnergy) or 0)>0
        and not (kind=='diesel' and pumpSellsDiesel(origin)) and not (kind=='electricEnergy' and origin.charge.offered) then
        other[kind]=true
      end
    end
    table.sort(bottles,function(a,b) return a.name<b.name end)
    origin.nitrous.bottles=bottles;origin.otherStorages=other
    origin.charge.batteries=origin.charge.offered and batteriesIn(list) or {}
    publish()
  end
  if storages then apply(storages);return end
  local veh=getObject(origin.vehicleId);if not veh or not (core_vehicleBridge and core_vehicleBridge.requestValue) then return end
  core_vehicleBridge.requestValue(veh,function(data) apply(data and data[1]) end,'energyStorage')
end
-- storages: the car's native energyStorage list, when read; without it a car is only
-- recognised by its fuel tanks, so an electric car falls back to the game's screen.
local function openPump(station,veh,storages)
  if not veh then return false end
  local facility=station.facility or station
  local types=model.stationEnergyTypes(facility.energyTypes)
  local gasoline,diesel,charges=types.gasoline==true or types.any==true,types.diesel==true or types.any==true,types.electricEnergy==true or types.any==true
  local id=veh:getID();local s=snapshots[id]
  -- Open only when the pump can fill one of the car's tanks or charge its battery.
  local fillable=charges and #batteriesIn(storages)>0
  for _,t in pairs(s and s.tanks or {}) do if (t.energyType=='diesel' and diesel) or (t.energyType~='diesel' and gasoline) then fillable=true end end
  if not fillable then return false end
  local grades=gasoline and model.stationGrades(facility.energyTypes) or {}
  for _,grade in ipairs(grades) do grade.priceFactor=economy.gradePriceFactors[grade.id] end
  local fuelPrice=overhaul_world_fuel_fuelPrice and overhaul_world_fuel_fuelPrice.getFuelPrice
  local price=fuelPrice and fuelPrice(facility.id,'gasoline') or 1
  if station.rlsFuelRegularPrice then price=station.rlsFuelRegularPrice end
  if diesel then
    -- Grades are priced as a factor of regular, so diesel's own pump price becomes its factor.
    local dieselPrice=station.rlsFuelDieselPrice or (fuelPrice and fuelPrice(facility.id,'diesel')) or price
    local grade=model.copy(model.grades.diesel);grade.priceFactor=dieselPrice/math.max(0.0001,price)
    grades[#grades+1]=grade
  end
  local inv=inventoryId(id)
  local chargePrice=stationChargePrice(station)
  if activeCareer() and inv and not station.rlsFuelRegularPrice and overhaul_career_repair_insurance then
    local discount=overhaul_career_repair_insurance.getInvVehFuelDiscountData(inv)
    if discount and discount.hasFuelDiscount then
      price=price*(1-(discount.fuelDiscount or 0));chargePrice=chargePrice*(1-(discount.fuelDiscount or 0))
    end
  end
  if panel and panel.busy then return true end
  settleTab(panel) -- a pump visit being replaced still pays its tab
  panel={vehicleId=id,mode='pump',station=station,grades=grades,pricePerL=price or 1,nativeTypes=types,returnTo=station.rlsFuelReturn,
    nitrous={offered=types.n2o==true or types.any==true,pricePerKg=stationNitrousPrice(station),bottles={}},
    charge={offered=charges,pricePerKWh=chargePrice,batteries={}},tab={}}
  core_vehicleBridge.executeAction(veh,'setIgnitionLevel',0)
  -- The station's "Refuel vehicle" prompt would stay behind the pump card.
  if overhaul_integration_services_markerInteraction then overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true) end
  readStorages(panel,storages)
  publish();return true
end
local function installPumpHook()
  if not overhaul_world_fuel_gasStations or overhaul_world_fuel_gasStations.refuelCar==refuelWrapper then return end
  originalRefuel=overhaul_world_fuel_gasStations.refuelCar
  local original=originalRefuel
  refuelWrapper=function(station,types,veh)
    types=model.stationEnergyTypes(types)
    if not (types.gasoline or types.diesel or types.electricEnergy or types.any) or not core_vehicleBridge then return original(station,types,veh) end
    -- A battery shows only in the car's energy stores, so read them before choosing the pump.
    core_vehicleBridge.requestValue(veh,function(data)
      if openPump(station,veh,data and data[1]) then panel.nativeTypes=model.copy(types) else original(station,types,veh) end
    end,'energyStorage')
  end
  overhaul_world_fuel_gasStations.refuelCar=refuelWrapper
end
function M.otherFuelTypes()
  if not panel or panel.mode~='pump' or panel.busy or panel.pumping then return false end
  local veh=getObject(panel.vehicleId);if not veh or not originalRefuel then return false end
  local station=model.copy(panel.station);station.rlsFuelExcludeGasoline=true
  local types=model.copy(panel.nativeTypes or {any=true})
  local any=types.any;types.any=nil;types.gasoline=nil
  -- Native ignored tanks (including nitrous) remain ignored by its own handler.
  if any then types.electricEnergy=true;types.diesel=true;types.kerosine=true end
  -- Fuels this pump sells stay here; the game's screen gets only the rest.
  station.rlsFuelExcludeTypes={gasoline=true}
  if pumpSellsDiesel(panel) then types.diesel=nil;station.rlsFuelExcludeTypes.diesel=true end
  if panel.charge and panel.charge.offered then types.electricEnergy=nil;station.rlsFuelExcludeTypes.electricEnergy=true end
  panel.returnTo=nil -- the native transaction owns the eventual business return
  panel.handOff=true -- and its own screen, so the station prompt stays shut
  M.close();originalRefuel(station,types,veh);return true
end
function M.onVehicleSpawned(id)
  -- Explicit config/part records carry rebuild continuity. Object IDs and the
  -- engine part name alone cannot identify a freshly selected vanilla car.
  snapshots[id]=nil;resetState[id]=nil;retainedTanks[id]=nil
  scheduled[id]=0.5
end
function M.onVehicleSwitched(_,id) id=id or playerId();if id and not snapshots[id] then scheduled[id]=0.1 end end
function M.onVehicleResetted(id) resetState[id]=model.copy(snapshots[id]) or {};scheduled[id]=0.2 end
-- Full mechanical repair has already cleared the authoritative part records.
-- A reset snapshot exists to preserve running calibration, not undo a repair.
-- Invalidate the old epoch before respawn, including any late runtime reply.
function M.onVehicleRepair(id)
  snapshots[id]=nil
  resetState[id]=nil
  scheduled[id]=nil
  generations[id]=nil
  for requestId,p in pairs(pending) do
    if p.vehicleId==id then failPending(requestId,p,'Vehicle repaired; reopen the editor.') end
  end
end
-- A vehicle runtime that loaded without being configured asks to be bound.
function M.onRuntimeLoaded(id)
  id=tonumber(id)
  if id and getObject(id) and not scheduled[id] then scheduled[id]=0.1 end
end
-- A car inspected before purchase was bound as unowned; rebind it as owned so
-- it is delivered as bought instead of waiting for its next spawn.
function M.onVehicleAddedToInventory(data)
  local inventoryId=type(data)=='table' and data.inventoryId or tonumber(data)
  local id=inventoryId and overhaul_career_garage_inventory.getVehicleIdFromInventoryId(inventoryId)
  if id and getObject(id) then scheduled[id]=0.1 end
end
function M.onVehicleDestroyed(id) snapshots[id]=nil;scheduled[id]=nil;resetState[id]=nil;retainedTanks[id]=nil;importedConfigs[id]=nil;testSetups[id]=nil;generations[id]=(generations[id] or 0)+1 end
function M.onUiChangedState(name)
  local opened=type(name)=='string' and (name=='pause' or name:sub(1,6)=='pause.' or name=='menu' or name:sub(1,5)=='menu.')
  if menuOpen==opened then return end
  menuOpen=opened
  if panel and panel.mode=='pump' then publish() end
end
function M.onUpdate(dtReal, dtSim)
  clock=clock+dtReal;installPumpHook()
  for capture in pairs(captures) do
    -- Confirmed mutations need a real capture; a timeout only retries it.
    if clock-capture.started>=REQUEST_GONE_S then capture.finish() end
  end
  local expired={}
  for requestId,p in pairs(pending) do
    local age=clock-(p.started or p.created or 0)
    local last=p.lastAttempt or p.created or p.started or 0
    local veh=getObject(p.vehicleId)
    local live=veh and generations[p.vehicleId]==p.generation
    if live then
      if age>=REQUEST_STUCK_S and not p.paid then
        expired[#expired+1]={requestId,p,'Vehicle did not confirm in time; no payment taken'}
      elseif clock-last>=REQUEST_RETRY_S then
        p.lastAttempt=clock
        veh:queueLuaCommand('if extensions.rlsFuelRuntime then extensions.rlsFuelRuntime.request('..serialize(p.kind)..','..serialize(p.payload or {})..','..serialize(requestId)..','..p.generation..') end')
      end
    elseif age>=REQUEST_GONE_S then
      expired[#expired+1]={requestId,p,'Vehicle became unavailable before confirmation; no payment taken'}
    end
  end
  for _,row in ipairs(expired) do failPending(row[1],row[2],row[3]) end
  for id,remaining in pairs(scheduled) do
    remaining=remaining-dtReal
    if remaining<=0 then scheduled[id]=nil;initVehicle(id) else scheduled[id]=remaining end
  end
  if panel and followsPlayer() and panel.vehicleId~=playerId() and not panel.busy then M.close() end
  if panel and panel.mode=='pump' then
    local veh=getObject(panel.vehicleId)
    if not pumpTargetAvailable() then
      if panel.pumping then panel.pumping.stop=true end
      if not panel.busy then M.close() end
    end
  end
  if panel and panel.pumping and not panel.busy then
    local origin=panel;local pumping=panel.pumping
    if not menuOpen then pumping.tick=pumping.tick+dtSim end
    if pumping.stop or pumping.delivered>=pumping.liters-0.000001 then
      if pumping.delivered>0 then persist(panel.vehicleId) end
      local summary=pumping.drain and string.format('Drained %.2f L',pumping.delivered) or string.format('Delivered %.2f L · $%.2f',pumping.delivered,pumping.paid)
      panel.pumping=nil;publish(pumping.failure and summary..' · '..pumping.failure or summary)
      -- Close pressed during an in-flight step finishes once that step settles.
      if pumping.close then M.close() end
    elseif not menuOpen and dtSim>0 and pumping.tick>=0.25 then
      pumping.tick=0;pumping.step=pumping.step+1
      local s=snapshots[panel.vehicleId];local tank=s and s.tanks[pumping.tank]
      if not tank then pumping.stop=true;return end
      if pumping.drain then
        -- The last step takes exactly what is left so engine use since the snapshot can't fail it.
        local amount=math.min(0.5,pumping.liters-pumping.delivered)
        if amount>=tank.liters-0.02 then amount=tank.liters end
        if amount<=0.000001 then pumping.stop=true;return end
        local ok=perform('drain',{tank=pumping.tank,liters=amount,expectedLiters=tank.liters,expectedBlend=model.copy(tank.blend),pumpStep=true},0,function(result)
          if result.ok then pumping.delivered=pumping.delivered+amount else pumping.stop=true;pumping.failure=result.message end
        end)
        if not ok then pumping.stop=true;pumping.failure=panel.message end
        return
      end
      -- 2 L/s; never catch up a stalled UI with one enormous delivery.
      local amount=math.min(0.5,pumping.liters-pumping.delivered)
      local totalPrice=math.floor((pumping.delivered+amount)/pumping.liters*pumping.price*100+0.5)/100
      local price=totalPrice-pumping.paid
      local ok=perform('deliver',{tank=pumping.tank,grade=pumping.grade,liters=amount,
        transaction=pumping.id..':'..pumping.step,expectedLiters=tank.liters,expectedBlend=model.copy(tank.blend)},price,function(result)
        if result.ok then pumping.delivered=pumping.delivered+amount;pumping.paid=totalPrice else pumping.stop=true;pumping.failure=result.message end
      end)
      if not ok then pumping.stop=true;pumping.failure=panel.message end
    end
  end
end
function M.onExtensionLoaded()
  local entry=ui_router and ui_router.getCurrent and ui_router.getCurrent()
  M.onUiChangedState(entry and entry.request and entry.request.name)
  local id=playerId();if id and id>0 then scheduled[id]=0.5 end
end
function M.onClientEndMission()
  pcall(settleTab,panel)
  saveStore.releaseHolds(M)
  guihooks.trigger('RlsFuelPanel',{open=false})
  panel=nil;menuOpen=false;snapshots={};scheduled={};resetState={};retainedTanks={};pending={};liveTrimPending={};generations={};captures={};importedConfigs={};testSetups={}
end
function M.onCareerActivated() local id=playerId();if id and id>0 then scheduled[id]=0.5 end end
function M.onCareerDeactivated()
  -- Preserve the transferable setup, then release every career fuel override.
  -- Returning to Career hydrates owned physical parts through their own records.
  local managed={}
  for id in pairs(generations) do managed[id]=true end
  for id in pairs(snapshots) do managed[id]=true end
  for id in pairs(managed) do
    local snapshot=snapshots[id]
    local rec=recordFor(id)
    if rec or snapshot and snapshot.career then
      local vm=core_vehicle_manager.getVehicleData(id)
      local source=snapshot
      if not source and rec then source={engines={},tanks={}};collectConditions(rec.partConditions,source) end
      local setup=portableFuel.pack(source)
      if vm and vm.config and setup then vm.config.rlsFuel=setup end
      local veh=getObject(id)
      if veh then veh:queueLuaCommand("if extensions.rlsFuelRuntime then extensions.unload('rlsFuelRuntime') end; if extensions.overhaulFuelMultiplier then extensions.unload('overhaulFuelMultiplier') end") end
      -- A pending first reply must not turn a stopped Career into an active
      -- legacy freeroam setup after the ownership boundary has closed.
      generations[id]=nil;snapshots[id]=nil;scheduled[id]=nil;resetState[id]=nil;retainedTanks[id]=nil;importedConfigs[id]=nil
    end
  end
  M.onCareerActivated()
end
function M.onExtensionUnloaded()
  M.onClientEndMission()
  for i=0,be:getObjectCount()-1 do
    local veh=be:getObject(i)
    if veh then veh:queueLuaCommand("if extensions.rlsFuelRuntime then extensions.unload('rlsFuelRuntime') end; if extensions.overhaulFuelMultiplier then extensions.unload('overhaulFuelMultiplier') end") end
  end
  if overhaul_world_fuel_gasStations and overhaul_world_fuel_gasStations.refuelCar==refuelWrapper then overhaul_world_fuel_gasStations.refuelCar=originalRefuel end
end
M.openPump=openPump
function M.conservativeMap(engine,expected)
  local s=currentContext();local e=s and s.engines[engine]
  if not e or not matchingContext(s,expected) then return nil end
  local tune=model.conversionKind(e.state)=='nitromethane' and model.convert(e.state,e.profile,'nitromethane').tune or model.newTune(e.profile)
  local reference=model.copy(tune)
  tune.rpm=model.copy(e.state.tune.rpm);tune.load=model.copy(e.state.tune.load)
  for _,field in ipairs({'lambda','timing'}) do
    tune[field]={};for y,load in ipairs(tune.load) do tune[field][y]={};for x,rpm in ipairs(tune.rpm) do tune[field][y][x]=model.sample(reference,field,rpm,load) end end
  end
  -- Reset calibration completely, retaining only the deliberately chosen axes.
  -- Hardware, tank contents, presets and mechanical damage are separate state.
  tune.afrTrim=0;tune.boostCut=nil;tune.decel={mode='original'}
  local gears=e.boostGears or (e.state.tune.boost and e.state.tune.boost.gears) or {}
  if #gears>0 then
    local base=model.clamp((e.profile.factoryBoostPsi or 0)+(e.profile.wastegateHalfRangePsi or 0),0,200)
    tune.boost={mode='original',gears=model.copy(gears),caps={},offset=0,offsets={},targets={}}
    for i in ipairs(gears) do tune.boost.caps[i]=base;tune.boost.offsets[i]=0 end
    for x in ipairs(tune.rpm) do tune.boost.targets[x]={};for i in ipairs(gears) do tune.boost.targets[x][i]=base end end
  else tune.boost=nil end
  return tune
end
function M.preview(engine,tune,load)
  local s=currentContext();local e=s and s.engines[engine]
  if not e or not model.validateTune(tune) then return {} end
  local state=model.copy(e.state);state.tune=tune
  local blend,volume=model.grades.regular,0
  for _,name in pairs(e.tanks or {}) do
    local t=s.tanks[name]
    if t and t.liters>0 then local weight=1/model.properties(t.blend).energyPerL;blend=model.mix(blend,volume,t.blend,weight);volume=volume+weight end
  end
  local out={}
  for _,rpm in ipairs(tune.rpm) do out[#out+1]=model.response(e.profile,state,blend,rpm,load or 1,90,1) end
  return out
end
M.getSnapshot=function(id) return snapshots[id or playerId()] end
-- Called only by the export service for its unowned test copy. Never global opt-in.
function M.beginExportTest(id,setup)
  local clean=setup==nil and {native=true} or portableFuel.read(setup)
  if not clean or activeCareer() or not getObject(id) then return false end
  testSetups[id]=clean;initVehicle(id);return true
end
function M.endExportTest(id)
  testSetups[id]=nil
  local veh=getObject(id)
  if veh then veh:queueLuaCommand("if extensions.rlsFuelRuntime then extensions.unload('rlsFuelRuntime') end") end
end
-- Part shopping confirms the preview vehicle in place (no spawnVehicle). Clear
-- the stale runtime snapshot and rebuild from inventory/vehicle part records so
-- garage UI matches store/retrieve without requiring a full respawn.
function M.rebindVehicle(id)
  if not id then return false end
  snapshots[id]=nil
  resetState[id]=nil
  scheduled[id]=nil
  initVehicle(id)
  return true
end
-- Internal rebuild adapters. Preserve actual liters and composition, never a
-- minimum fill or a percentage of a newly enlarged tank. Hardware stays in
-- engine part conditions and is deliberately absent from these records.
function M.captureTankForRebuild(id,tank)
  local s=snapshots[id];local t=s and s.tanks[tank.name]
  if not t or tank.energyType~='gasoline' then return nil end
  return {version=1,name=tank.name,blend=model.copy(t.blend),liters=math.max(0,tank.currentEnergy/model.properties(t.blend).energyPerL)}
end
function M.restoreTankAfterRebuild(veh,saved)
  if not veh or not saved or not saved.rlsFuelTank then return false end
  local id=veh:getID();local tank=model.copy(saved.rlsFuelTank)
  if scheduled[id] or not generations[id] then retainedTanks[id]=retainedTanks[id] or {};retainedTanks[id][tank.name]=tank end
  veh:queueLuaCommand("if not extensions.rlsFuelRuntime then extensions.load('rlsFuelRuntime') end; extensions.rlsFuelRuntime.restoreTankState("..serialize(tank)..")")
  return true
end
M.onOverhaulModulesActivated = M.onCareerActivated
M.onOverhaulVehicleAddedToInventory = M.onVehicleAddedToInventory
M.onOverhaulVehicleAdded = M.onVehicleAddedToInventory
M.onCareerDeactivatedWhileLevelLoaded = M.onCareerDeactivated
M.onOverhaulBeforeCareerDeactivate = M.onCareerDeactivated
return M
