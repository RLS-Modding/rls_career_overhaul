local nitrousControl=require('vehicle/rlsNitrousControl')
local M = {}
local model = require('common/rlsFuelModel')
local blendCache=require('vehicle/rlsFuelRuntime/blendCache')
local nativeDamage = require('vehicle/rlsFuelDamage')
local combustion = require('common/rlsFuelCombustion')
local hardware=model.hardware
local boostControl=require('vehicle/rlsBoostControl')
local fuelControl=require('common/rlsFuelControl')
local afterfire=require('vehicle/rlsAfterfireAdapter')
local fuelClutch=require('vehicle/rlsFuelClutch')
local dieselLimiterSmoke=require('vehicle/rlsDieselLimiterSmoke')
local dieselSmokePalette=require('common/rlsDieselSmokePalette')
local dieselSmokePaletteReady=false
local contexts, tanks, unsupported = {}, {}, {}
local generation, enabled, career = 0, false, false
local elapsed, pushElapsed = 0, 0
local receipts = {}
local combustionCount=0
local discoveryDirty=true
local discoveredPartMap
local syncEffects
local emptyData={}
local function dataFor(e) return v and v.data and v.data[e.name] or emptyData end
-- Career stores fuel state on the physical engine part. Device names like
-- mainEngine are reused across swaps, so identity comes from slotPartMap.
local function physicalPartName(engine)
  local authored=dataFor(engine).partOrigin
  if type(authored)=='string' and authored~='' and authored~='mainEngine' then return authored end
  local map=v and v.data and v.data.slotPartMap
  if type(map)~='table' then return nil end
  local best,bestDepth
  for slot,part in pairs(map) do
    if type(slot)=='string' and type(part)=='string' and part~='' then
      local leaf=(slot:match('([^/]+)/?$') or ''):lower()
      local pname=part:lower()
      if (leaf=='engine' or leaf:match('_engine$')) and pname:find('engine',1,true)
        and not pname:find('ecu',1,true) and not pname:find('mount',1,true)
        and not pname:find('oilpan',1,true) and not pname:find('internals',1,true) then
        local depth=0;for _ in slot:gmatch('/') do depth=depth+1 end
        if not bestDepth or depth<bestDepth then best,bestDepth=part,depth end
      end
    end
  end
  return best
end
local function originCompatible(stateOrigin,installed)
  if not installed or installed=='' then return true end
  if not stateOrigin or stateOrigin=='' or stateOrigin=='mainEngine' then return true end
  return stateOrigin==installed
end
local settleFactoryBoost
local function adaptTransmission(c)
  if not c.state.tune.boost then return end
  c.gearbox=boostControl.gearbox(c.engine)
  local gears=boostControl.gears(c.gearbox)
  local baselinePsi=(c.profile.factoryBoostPsi or 0)+(c.profile.wastegateHalfRangePsi or 0)
  local wasActive=c.state.control.boost and model.boostEnabled(c.state.tune)
  if not model.adaptBoostGears(c.state.tune,gears,baselinePsi) then return end
  local previousRevision=c.state.revision or 0
  c.state.revision=previousRevision+1
  if not c.state.tune.boost then c.state.control.boost=false end
  if wasActive then c.state.observedPull=nil;c.state.observedBoostPsi=nil;c.state.rating=nil;c.pull=nil end
  c.effectiveState=nil
  c.boostAdaptation={previousRevision=previousRevision,revision=c.state.revision,
    message=#gears>0 and 'Boost by gear adapted to the installed transmission. Review the targets before driving.'
      or 'Boost by gear reset to stock control: this transmission has no known forward gear layout.'}
  return true
end
local function normalizeState(s,p)
  if type(s)~='table' then return model.newEngineState(p) end
  if (s.version~=1 and s.version~=2 and s.version~=3 and s.version~=4 and s.version~=5 and s.version~=6) or not model.validateTune(s.tune) then
    local fallback=model.newEngineState(p)
    for _,key in ipairs({'damage','exposure','fuelFailures','legacyCondition'}) do fallback[key]=model.copy(s[key]) end
    fuelControl.normalize(fallback);return nativeDamage.normalize(fallback)
  end
  s=nativeDamage.normalize(model.copy(s));s.conversionKind=model.conversionKind(s);s.deliveryLps=math.max(0.000001,tonumber(s.deliveryLps) or p.deliveryLps)
  model.migrateDelivery(s);hardware.migrate(s,p);s.version=s.nativeBaseline and 6 or 5;s.revision=s.revision or 0
  s.tune.fuelType=p.fuelType or 'gasoline'
  s.presets=type(s.presets)=='table' and s.presets or {};fuelControl.normalize(s);return s
end
local function liters(t) return t.storedEnergy/math.max(1,t.fuelLiquidDensity*t.energyDensity) end
local function setBlend(t,blend,volume)
  if t.energyType=='diesel' then
    t.rlsFuelBlend={diesel=true,density=t.fuelLiquidDensity,energyPerL=t.fuelLiquidDensity*t.energyDensity,ethanol=0,methanol=0,nitromethane=0,aki=0}
    t.storedEnergy=model.clamp(volume,0,t.capacity)*t.fuelLiquidDensity*t.energyDensity
    t.remainingVolume=volume;t.remainingRatio=volume/t.capacity;return
  end
  local p=model.properties(blend)
  t.rlsFuelBlend={ethanol=p.ethanol,methanol=p.methanol,nitromethane=p.nitromethane,aki=p.aki}
  t.fuelLiquidDensity=p.density;t.energyDensity=p.energyPerL/p.density
  t.energyCapacity=t.capacity*p.energyPerL
  t.storedEnergy=model.clamp(volume,0,t.capacity)*p.energyPerL
  t.remainingVolume=t.storedEnergy/p.energyPerL
  t.remainingRatio=t.capacity>0 and t.remainingVolume/t.capacity or 0
  local count=0;for _ in pairs(t.fuelNodes or {}) do count=count+1 end
  t.fuelNodeMassCoef=count>0 and 1/(t.energyDensity*count) or 0
  if obj.setNodeMass then for node,baseMass in pairs(t.fuelNodes or {}) do obj:setNodeMass(node,baseMass+t.storedEnergy*t.fuelNodeMassCoef) end end
end
local function computeEngineBlend(e)
  local blend,amount=model.copy(e.requiredEnergyType=='diesel' and model.grades.diesel or model.grades.regular),0
  local names=e.registeredEnergyStorages or e.energyStorage or {}
  if type(names)=='string' then names={names} end
  for _,name in pairs(names) do
    local t=tanks[name]
    -- Follow actual native withdrawal ratios (normally equal per nonempty
    -- tank). A tank selector can assign zero without changing its contents.
    if t and liters(t)>0 then
      local ratio=e.energyStorageRatios and e.energyStorageRatios[name] or 1
      local n=math.max(0,ratio)/model.properties(t.rlsFuelBlend).energyPerL
      blend=model.mix(blend,amount,t.rlsFuelBlend,n);amount=amount+n
    end
  end
  return blend
end
local function engineBlend(engine)
  local context=engine.rlsFuelContext
  if not context then return computeEngineBlend(engine) end
  context.blendCache=context.blendCache or {inputs={}}
  return blendCache.get(context.blendCache,engine,tanks,computeEngineBlend,model)
end
local function responseBuffer(context)
  -- Only this context owns the response; snapshots and physics inputs copy it.
  local response=context.responseBuffer or {}
  context.responseBuffer=response
  return response
end
local function snapshot()
  local out={version=3,vehicleId=obj:getID(),generation=generation,career=career,engines={},tanks={},unsupported=model.copy(unsupported)}
  for name,c in pairs(contexts) do
    syncEffects(c)
    local outlets,visible=0,0
    for _,n in pairs(c.engine.thermals and c.engine.thermals.exhaustEndNodes or {}) do
      outlets=outlets+1;if (n.afterFireVisualCoef or 1)>0 then visible=visible+1 end
    end
    local cutEditable,cutReason=model.boostCutEditable(c.profile)
    local nitrousSupported,nitrousReason=nitrousControl.supported(c.engine,c.gearbox)
    local nitrousMatch,nitrousCalibrationReason=nitrousControl.supported(c.engine,c.gearbox,c.state.tune.nitrous)
    local boostSupported,boostSupportReason=boostControl.supported(c.engine,c.gearbox)
    out.engines[name]={name=name,profile=model.copy(c.profile),state=model.copy(c.state),effectiveTune=model.copy(c.effectiveState.tune),telemetry=model.copy(c.response),control=model.copy(c.control),
      nitrousInstalled=nitrousControl.installed(c.engine),nitrousSupported=nitrousSupported,nitrousSupportReason=nitrousReason,nitrousCalibrationReason=not nitrousMatch and nitrousCalibrationReason or nil,
      boostCutEditable=cutEditable==true,boostCutLockReason=cutReason,
      hardware={injectors=hardware.catalog(c.state,c.profile,'injector'),pumps=hardware.catalog(c.state,c.profile,'pump'),
        retiredInjectors=hardware.retired(c.state,c.profile,'injector'),retiredPumps=hardware.retired(c.state,c.profile,'pump')},
      boostGears=boostControl.gears(c.gearbox),boostSupported=boostSupported,boostSupportReason=boostSupportReason,
      boostAdaptation=model.copy(c.boostAdaptation),
      afterfire={outlets=outlets,visibleOutlets=visible,adapter=afterfire.status(c.afterfire)},
      condition=nativeDamage.inspect(c.engine,c.response),
      warning=c.effectsActive and model.warning(c.profile,c.effectiveState,engineBlend(c.engine)) or '',partOrigin=physicalPartName(c.engine) or c.state.partOrigin,
      tanks=model.copy(c.engine.registeredEnergyStorages or {})}
  end
  for name,t in pairs(tanks) do
    out.tanks[name]={name=name,capacity=t.capacity,liters=liters(t),blend=model.copy(t.rlsFuelBlend),energyType=t.energyType}
  end
  return out
end
local function reply(requestId,ok,message,requestGeneration)
  local result={requestId=requestId,requestGeneration=requestGeneration or generation,ok=ok,message=message,data=snapshot()}
  obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('fuelReply', serialize(result)))
end
local function bindTank(t)
  if t.rlsFuelConditionBound then return end
  t.rlsFuelConditionBound=true
  local get,set=t.getPartCondition,t.setPartCondition
  local binding={get=get,set=set,energyDensity=t.energyDensity,fuelLiquidDensity=t.fuelLiquidDensity,
    energyCapacity=t.energyCapacity,fuelNodeMassCoef=t.fuelNodeMassCoef}
  t.rlsFuelNativeBinding=binding
  if get then t.getPartCondition=function(self,...)
    local integrity,state=get(self,...)
    if type(state)=='table' then state.rlsFuelTank={version=3,name=self.name,blend=model.copy(self.rlsFuelBlend),liters=liters(self)} end
    return integrity,state
  end end
  if set then t.setPartCondition=function(self,odometer,integrity,visual)
    set(self,odometer,integrity,visual)
    if type(integrity)=='table' and type(integrity.rlsFuelTank)=='table' then
      local saved=integrity.rlsFuelTank;setBlend(self,saved.blend,saved.liters or liters(self));self.rlsFuelTankRestored=true
    end
  end end
  binding.getWrapper,binding.setWrapper=t.getPartCondition,t.setPartCondition
end
local function bindColdStart(c)
  local e=c.engine
  if c.starterWrapper or type(e.activateStarter)~='function' then return end
  c.starterOriginal=e.activateStarter
  c.starterWrapper=function(self,...)
    local time=self.starterThrottleKillTime
    local factor=enabled and c.active~=false and c.effectsActive and model.coldStartMultiplier(engineBlend(self),self.thermals and self.thermals.engineBlockTemperature) or 1
    if model.finite(time) then self.starterThrottleKillTime=time*factor end
    local ok,err=pcall(c.starterOriginal,self,...)
    self.starterThrottleKillTime=time
    if not ok then error(err) end
  end
  e.activateStarter=c.starterWrapper
end
local function bindEngineConditions(c)
  local e=c.engine
  e.rlsFuelContext=c
  if e.rlsFuelConditionBound then return end
  e.rlsFuelConditionBound=true
  local get,set=e.getPartCondition,e.setPartCondition
  if get then e.getPartCondition=function(self,sub,...)
    local integrity,state=get(self,sub,...)
    local current=self.rlsFuelContext
    -- Only publish runtime fuel state after it has been hydrated from the part or
    -- configure. Emitting a fresh Original before that can wipe inventory blobs.
    if not sub and current and current.fuelConditionReady and type(state)=='table' then
      adaptTransmission(current)
      local installed=physicalPartName(self)
      state.rlsFuelEngineState=model.copy(current.state);state.rlsFuelEngineState.deviceName=self.name
      -- Always stamp the currently installed part; never keep a previous engine's origin.
      state.rlsFuelEngineState.partOrigin=installed or current.state.partOrigin
      if installed then current.state.partOrigin=installed end
    elseif not sub and current and not current.fuelConditionReady and type(state)=='table' then
      -- Keep an existing part blob untouched until Fuels hydrates; do not replace it
      -- with a blank/default runtime state.
      if type(state.rlsFuelEngineState)~='table' and type(current.preservedPartState)=='table' then
        state.rlsFuelEngineState=model.copy(current.preservedPartState)
      end
    end
    return integrity,state
  end end
  if set then e.setPartCondition=function(self,sub,odometer,integrity,visual)
    set(self,sub,odometer,not sub and nativeDamage.pendingCondition(self,integrity) or integrity,visual)
    local current=self.rlsFuelContext
    if not sub and current and type(integrity)=='table' and integrity.rlsFuelEngineState then
      local installed=physicalPartName(self)
      local incoming=integrity.rlsFuelEngineState
      current.preservedPartState=model.copy(incoming)
      -- Ignore a blob that clearly belongs to a different physical engine part.
      if originCompatible(incoming.partOrigin,installed) then
        current.state=normalizeState(incoming,current.profile)
        current.state.partOrigin=installed or incoming.partOrigin
        current.fuelConditionReady=true;settleFactoryBoost(current)
        adaptTransmission(current)
        nativeDamage.apply(self,current.state)
      end
    elseif not sub and current and type(integrity)=='number' and integrity>=1 then
      nativeDamage.clearExposure(current.state);current.knockRetard=0
    end
  end end
end
local function applyWallEnergy(c,joules)
  local thermals=c.engine.thermals
  if joules~=0 and thermals and model.finite(thermals.cylinderWallTemperature) then
    local ambient=obj.getEnvTemperature and obj:getEnvTemperature()-273.15 or 20
    thermals.cylinderWallTemperature=math.max(ambient,thermals.cylinderWallTemperature+joules/c.profile.cylinderWallHeatCapacity)
  end
end
local function bindFuelAccounting(c)
  local e=c.engine
  if type(e.updateFuelUsage)~='function' then return end
  -- Bind once per context. Re-wrapping when another mod takes the tip nests a
  -- second Fuels adapter and can double accounting / recurse on later discovers.
  if c.fuelWrapper then return end
  local original=e.updateFuelUsage
  c.fuelAccountingBefore=c.fuelAccountingBefore or {}
  c.fuelWrapper=function(self,...)
    if not enabled or c.active==false or not c.effectsActive or c.accounting then return original(self,...) end
    c.accounting=true
    local before=c.fuelAccountingBefore
    for name in pairs(before) do before[name]=nil end
    for _,name in pairs(self.registeredEnergyStorages or {}) do local t=tanks[name];if t then before[name]=t.storedEnergy end end
    local requested=self.spentEnergy or 0
    local ok,err=pcall(original,self,...)
    local blend,volume=model.grades.regular,0
    local multiplier=self.rlsFuelConsumptionMultiplier or 1
    if ok then for name,energy in pairs(before) do
      local t=tanks[name];local amount=math.max(0,energy-t.storedEnergy)/multiplier/model.properties(t.rlsFuelBlend).energyPerL
      blend=model.mix(blend,volume,t.rlsFuelBlend,amount);volume=volume+amount
    end end
    local dt=c.accountTime or 0
    if dt>0 and ok then
      local fraction=model.clamp((c.extraEnergy or 0)/math.max(1e-12,requested),0,1)
      local fuel=volume>0 and model.properties(blend) or c.fuel or model.properties(blend);c.combustion=c.combustion or {}
      dieselLimiterSmoke.confirm(c,volume*fuel.energyPerL*multiplier,requested)
      local paid=model.clamp(volume*fuel.energyPerL*multiplier/math.max(1e-12,requested),0,1)
      model.accumulateExposure(c.state,{knockExposureRate=(c.pendingKnockExposure or 0)*paid},1)
      nativeDamage.apply(self,c.state)
      local response=c.combustionInput or {};c.combustionInput=response
      for k in pairs(response) do response[k]=nil end
      for k,value in pairs(c.response or {}) do response[k]=value end
      response.exhaustSimulation=true
      response.exhaustTemperature=self.thermals and self.thermals.exhaustTemperature or response.exhaustTemperature
      response.unburnedLiters=volume*model.clamp((c.unburnedEnergy or 0)/math.max(1e-12,requested),0,1-fraction)
      response.flameCarry=(c.fireTime or 0)/dt
      response.cranking=(c.crankTime or 0)>0
      response.airMassKgPerSec=(c.exhaustAirMass or 0)/dt
      local burning=(c.fireTime or 0)>0
      combustion.step(c.combustion,fuel,volume*(1-fraction),volume*fraction,response,burning,dt)
      -- Apply this accounted interval once, before the native thermal update.
      -- A cached watts value replayed on GFX ticks invents cooling after fuel
      -- cut and loses/doubles energy when physics and graphics steps differ.
      applyWallEnergy(c,(c.combustion.extraCylinderHeatW-c.combustion.wallCoolingW)*dt+(c.pendingDieselHeatJ or 0)*paid)
      if response.exhaustSimulation and self.thermals and model.finite(self.thermals.exhaustTemperature) then
        -- Only a bounded fraction of released heat reaches the lumped pipe wall.
        -- Consume accounted joules once; cached GFX watts must not create heat.
        local capacity=2000+c.profile.referencePowerKW*20
        self.thermals.exhaustTemperature=self.thermals.exhaustTemperature+c.combustion.burnW*dt*.15/capacity
      end
      local state=self.rlsAfterfireState or {};self.rlsAfterfireState=state
      state.burnW=c.combustion.burnW;state.nitromethane=fuel.nitromethane;state.methanol=fuel.methanol;state.ethanol=fuel.ethanol
      if response.exhaustSimulation then
        state.simulationVersion=1;state.burnedJ=c.combustion.exhaustBurnedJ or 0;state.appearance=c.combustion.fuelAppearance
        state.flameEthanol=c.combustion.fuelEthanol or 0
        local surge=c.combustion.surge or {}
        state.surgeSerial=surge.serial or 0;state.surgeEnergyJ=surge.eventEnergyJ or 0
      end
      -- Confirmed tank withdrawals gate native effect additions. These rates
      -- exclude Career pacing, just like the conserved combustion budget.
      state.chargedLps=volume*(1-fraction)/dt;state.extraLps=volume*fraction/dt
      state.extraDemandLps=c.extraFlowLps or 0;state.age=0
    end
    c.pendingKnockExposure=0;c.pendingDieselHeatJ=0
    c.accountTime=0;c.extraEnergy=0;c.unburnedEnergy=0;c.fireTime=0;c.crankTime=0;c.exhaustAirMass=0;c.accounting=false
    if not ok then dieselLimiterSmoke.clear(c);error(err) end
  end
  c.fuelOriginal=original;e.updateFuelUsage=c.fuelWrapper
end
local function bindPhysics(c)
  local e=c.engine
  bindFuelAccounting(c)
  if not c.afterfire then c.afterfire=afterfire.new(e) end
  if type(e.torqueUpdate)~='function' then return end
  -- main.onReset calls extensions before powertrain.reset. The native engine
  -- then replaces torqueUpdate on the same device, so repair on the next GFX
  -- discovery, after that replacement. Ordinary third-party wrappers keep the
  -- one-bind rule; the shared inCall guard also prevents nested reset hooks
  -- from applying the fuel response twice.
  if c.physicsResetPending then
    c.physicsResetPending=nil
    if c.wrapper and e.torqueUpdate~=c.wrapper then c.wrapper=nil end
  elseif c.wrapper and e.torqueUpdate==c.original then
    e.torqueUpdate=c.wrapper
  end
  if c.wrapper then return end
  local original=e.torqueUpdate
  c.wrapper=function(self,dt)
    if not enabled or c.active==false or not c.effectsActive or c.inCall then return original(self,dt) end
    c.inCall=true
    local air,eff=self.intakeAirDensityCoef,self.invBurnEfficiencyCoef
    local av,cut=self.outputAV1,(self.ignitionCutTime or 0)>0
    local response=c.response or {torque=1,efficiencyPenalty=1}
    local cranking=(self.starterEngagedCoef or 0)>0 and av<(self.idleAV or c.profile.idleRPM/9.5492966)*.8
    local injection=self.requiredEnergyType~='diesel' and not self.isDisabled and self.hasFuel~=false
      and (self.ignitionCoef or 1)>0 and av>1 and not response.boostFuelCut and not self.revLimiterActive
      and (not self.isStalled or cranking)
    local delivered=self.rlsAfterfireState
    if delivered then delivered.age=(delivered.age or 0)+dt end
    afterfire.update(c.afterfire,c.effectiveDecel,delivered,response,dt)
    local densityGain=1+model.clamp(c.chargeCooling or 0,0,model.constants.maximumChargeCoolingC)/model.constants.referenceChargeKelvin
    c.pulseTime=(c.pulseTime or 0)+dt
    local rough=response.idleRoughness or 0;local nitro=response.nitroPulse or 0
    local pulse=1-rough*.22+rough*.28*math.sin(c.pulseTime*37)+nitro*.12*math.sin(c.pulseTime*53)
    local crankQuality=1
    if cranking and self.requiredEnergyType~='diesel' then
      local lambda=response.lambda or 1
      crankQuality=model.clamp((lambda-.35)/.3,0,1)*model.clamp((1.8-lambda)/.5,0,1)
        *(1-.75*(response.coldRunningSeverity or 0))
      c.crankPhase=((c.crankPhase or 0)+math.max(0,av)*9.5492966/120*4*dt)%1
      crankQuality=c.crankPhase<crankQuality and 1 or 0
    end
    local appliedAir=air*response.torque*densityGain*math.max(.35,pulse)*crankQuality
    local appliedEff=eff*response.efficiencyPenalty/(math.max(.35,pulse)*densityGain)
    self.intakeAirDensityCoef,self.invBurnEfficiencyCoef=appliedAir,appliedEff
    local beforeEnergy=self.spentEnergy
    local ok,err=pcall(original,self,dt)
    if ok and model.finite(beforeEnergy) and model.finite(self.spentEnergy) and dt>0 then
      local spent=math.max(0,self.spentEnergy-beforeEnergy)
      dieselLimiterSmoke.record(c,self,response,spent,dt)
      local fueled=spent>0 and not cut and not cranking and not response.boostFuelCut
        and self.hasFuel~=false and not self.isDisabled and not self.isStalled and (self.ignitionCoef or 1)>0
      if fueled then
        if c.profile.fuelType=='diesel' then
          -- Supplementary diesel heat is bounded by consumed energy, then
          -- scaled by the confirmed tank withdrawal. No GFX replay or cut heat.
          local fraction=model.clamp(1-(response.referenceFlowLps or 0)/math.max(1e-12,response.flowLps or 0),0,1)
          c.pendingDieselHeatJ=(c.pendingDieselHeatJ or 0)+spent/(self.rlsFuelConsumptionMultiplier or 1)*fraction*.18
        elseif (self.instantEngineLoad or self.engineLoad or 0)>.45 and av*9.5492966>c.profile.idleRPM*1.4 then
          c.pendingKnockExposure=(c.pendingKnockExposure or 0)+math.max(0,response.knockExposureRate or 0)*dt
        end
      end
      local factor=math.max(0.00001,response.efficiencyPenalty*response.torque)
      local reference=combustion.referenceEnergy(self,av,air,eff,cut,dt)
      c.referenceEnergy=(c.referenceEnergy or 0)+(reference or spent/factor/(self.rlsFuelConsumptionMultiplier or 1))
      c.referenceTime=(c.referenceTime or 0)+dt
      c.accountTime=(c.accountTime or 0)+dt
      local firing=injection and not cut and (not cranking or ((self.starterThrottleKillCoef or 1)>0 and crankQuality>0))
      local carry=firing and model.clamp((response.exhaustFraction or 0)*3+(response.decelRetard or 0)*.025,0,1) or 0
      -- Failure to make useful crank torque does not rule out a small local
      -- ignition kernel reaching an over-rich exhaust charge. Model bounded
      -- cycle pulses separately; do not give the engine extra starting torque.
      -- This is a reduced-order calibration, not a spark/mixture simulation.
      if cranking and injection and not cut and (self.starterThrottleKillCoef or 1)>0
        and (response.flowLps or 0)>0 and (response.lambda or 1)<.65
        and (c.crankPhase or 0)<.12 then
        carry=math.max(carry,.15)
      end
      c.fireTime=(c.fireTime or 0)+carry*dt
      c.crankTime=(c.crankTime or 0)+(cranking and dt or 0)
      local exhaustAir=math.max(0,response.airMassKgPerSec or 0)
      local cutFlow
      if injection and cut then
        local counterfactual=combustion.referenceEnergy(self,av,air,eff,false,dt)
        local fuel=c.fuel or model.properties(model.grades.regular)
        if counterfactual then
          cutFlow=counterfactual/dt*factor/fuel.energyPerL
          exhaustAir=cutFlow*fuel.density*fuel.stoich*math.max(.01,response.lambda or 1)
        else
          exhaustAir=math.max(exhaustAir,c.lastFueledAir or 0)
        end
      end
      local overrun=injection and not cranking and not cut and (self.requestedThrottle or self.throttle or 0)<.02 and (c.extraFlowLps or 0) or 0
      -- Native fuel cut does not imply zero airflow through a spinning engine.
      -- Use the same bounded air estimate that generated extra overrun fuel.
      if overrun>0 then exhaustAir=math.max(exhaustAir,c.overrunAirKgPerSec or 0) end
      c.exhaustAirMass=(c.exhaustAirMass or 0)+exhaustAir*dt
      local missing=injection and (cut or cranking) and math.max(0,response.flowLps or 0) or 0
      if injection and not cut and not cranking then c.lastFueledFlow=response.flowLps or 0;c.lastFueledAir=exhaustAir end
      if injection and cut then missing=cutFlow or math.max(missing,c.lastFueledFlow or 0) end
      if c.fuelWrapper and (overrun>0 or missing>0) then
        local fuel=c.fuel or model.properties(model.grades.regular)
        local multiplier=self.rlsFuelConsumptionMultiplier or 1
        local nativeFlow=spent/dt/multiplier/fuel.energyPerL
        -- Custom Decel requests additional injection; native fuel remains counted once.
        local missingExtra=math.max(0,missing-nativeFlow)
        local extra=math.min(overrun+missingExtra,math.max(0,(c.effectiveState.deliveryLps or 0)-nativeFlow))
        local extraEnergy=extra*dt*fuel.energyPerL*multiplier
        local available,participating=math.huge,false
        for _,name in pairs(self.registeredEnergyStorages or {}) do
          local t=tanks[name];local ownRatio=self.energyStorageRatios and self.energyStorageRatios[name] or 0
          if t and ownRatio>0 then
            participating=true;local pending=0
            for _,other in pairs(contexts) do
              pending=pending+(other.engine.spentEnergy or 0)*(other.engine.energyStorageRatios and other.engine.energyStorageRatios[name] or 0)
            end
            available=math.min(available,math.max(0,t.storedEnergy-pending)/ownRatio)
          end
        end
        extraEnergy=participating and math.min(extraEnergy,available) or 0
        self.spentEnergy=self.spentEnergy+extraEnergy
        local overrunShare=overrun/math.max(1e-12,overrun+missingExtra)
        c.extraEnergy=(c.extraEnergy or 0)+extraEnergy*overrunShare
        -- Ignition-cut charge goes entirely to exhaust; a successful crank
        -- pulse burns part of its charge. Keep these categories across GFX ticks.
        -- Successful crank pulses use the same mixture-derived exhaust fraction
        -- as normal firing. Only failed ignition sends the entire extra charge
        -- unburned; a fixed 25% here made clean starts spit flames.
        local failedShare=(cut or not firing) and 1 or 0
        c.unburnedEnergy=(c.unburnedEnergy or 0)+extraEnergy*(1-overrunShare)*failedShare
      end
    end
    if self.intakeAirDensityCoef==appliedAir then self.intakeAirDensityCoef=air end
    if self.invBurnEfficiencyCoef==appliedEff then self.invBurnEfficiencyCoef=eff end
    c.inCall=false
    if not ok then error(err) end
  end
  c.original=original;e.torqueUpdate=c.wrapper
end
local function releaseEffects(c)
  local e=c.engine
  fuelClutch.release(e)
  afterfire.restore(c.afterfire);c.afterfire=nil
  if c.effectsActive==false then return end
  if c.effectsActive then boostControl.release(e,'fuel') end
  c.effectsActive=false;e.rlsFuelOwner=nil;e.rlsAfterfireState=nil
  dieselLimiterSmoke.clear(c)
  c.pendingKnockExposure=0;c.pendingDieselHeatJ=0
  c.response=nil
  -- Only detach our own functions. A downstream mod may still call a captured
  -- wrapper; its effectsActive guard makes that call a native pass-through.
  if e.torqueUpdate==c.wrapper then e.torqueUpdate=c.original;c.wrapper=nil end
  if e.updateFuelUsage==c.fuelWrapper then e.updateFuelUsage=c.fuelOriginal;c.fuelWrapper=nil end
  if e.activateStarter==c.starterWrapper then e.activateStarter=c.starterOriginal;c.starterWrapper=nil end
  c.chargeCooling=0;c.knockRetard=0;c.knockSoundTime=0;c.sootTime=0
  dieselSmokePalette.reset(c)
  c.extraFlowLps=0;c.referenceEnergy=0;c.referenceTime=0;c.accountTime=0;c.extraEnergy=0;c.combustion={}
  c.unburnedEnergy=0;c.fireTime=0;c.crankTime=0;c.exhaustAirMass=0;c.lastFueledFlow=0;c.lastFueledAir=0;c.crankPhase=0
  c.boostCut={active=false,hold=0}
end
syncEffects=function(c)
  -- Restoration and tune application adapt directly; discovery flags the rest.
  if c.transmissionCheckPending then c.transmissionCheckPending=false;adaptTransmission(c) end
  local calibrationChanged=c.effectiveSource~=c.state or c.effectiveRevision~=(c.state.revision or 0) or not c.effectiveState
  if calibrationChanged then
    c.effectiveState=fuelControl.effective(c.state,c.profile)
    c.effectiveDecel=model.decel(c.effectiveState.tune)
    c.effectiveSource=c.state;c.effectiveRevision=c.state.revision or 0
  end
  nitrousControl.set(c.engine,c.gearbox,c.effectiveState.tune.nitrous)
  -- Calibration is cached; exposure and mechanical failures change in place.
  c.effectiveState.exposure=c.state.exposure;c.effectiveState.fuelFailures=c.state.fuelFailures
  c.effectiveState.legacyCondition=c.state.legacyCondition
  local variables=v and v.data and v.data.variables or emptyData
  local adjustment=variables['$rlsWastegateAdjustment']
  c.profile.nativeBoostDeviation=math.abs(tonumber(type(adjustment)=='table' and adjustment.val) or 0)>1e-8
    or math.abs(boostControl.proOffset(c.engine))>1e-8
  local blend,chemistry=engineBlend(c.engine)
  local fuelEffects=not blend.diesel and ((blend.ethanol or 0)>.15000001 or (blend.methanol or 0)>.001 or (blend.nitromethane or 0)>.001)
  -- Live fuel selection and boost adjustment can change without a tune revision.
  -- Rebuild calibration reasons only when one of the status inputs changes.
  if calibrationChanged or not c.control or c.controlProfile~=c.profile
    or c.controlFuelEffects~=fuelEffects or c.controlBoostDeviation~=c.profile.nativeBoostDeviation then
    c.control=fuelControl.status(c.state,c.profile,blend)
    c.controlProfile=c.profile;c.controlFuelEffects=fuelEffects;c.controlBoostDeviation=c.profile.nativeBoostDeviation
  end
  local decel=c.effectiveDecel
  if decel.mode~='custom' or not decel.enabled or decel.fueling<=0 then
    -- OFF must stop extra injection even if another tuning subsystem remains
    -- active and physics runs before the next graphics response calculation.
    c.extraFlowLps=0
  end
  if c.control.mode=='native' then c.state.rating=nil;releaseEffects(c)
  else
    c.effectsActive=true;c.engine.rlsFuelOwner='overhaul'
    bindColdStart(c);bindPhysics(c)
  end
  fuelClutch.sync(c.engine,c.profile,c.effectiveState,blend,c.effectsActive)
  return blend,chemistry
end
-- Factory boost of the only turbo: its wastegate opening without the RLS
-- adjustable-wastegate offset. Unknown for superchargers and multi-engine cars.
local function turboData(e)
  local name=dataFor(e).turbocharger
  local data=v and v.data and v.data[type(name)=='string' and name or 'turbocharger']
  return type(data)=='table' and data or nil
end
local function factoryBoostPsi(e)
  if combustionCount~=1 or type(e.turbocharger)~='table' or not e.turbocharger.isExisting then return nil end
  local turbo=turboData(e)
  local start=type(turbo)=='table' and tonumber(turbo.wastegateStart)
  if not model.finite(start) then return nil end
  local vars=v.data.variables
  local adjustment=type(vars)=='table' and type(vars['$rlsWastegateAdjustment'])=='table' and tonumber(vars['$rlsWastegateAdjustment'].val) or 0
  return start-(model.finite(adjustment) and adjustment or 0)
end
-- Full-throttle boost (psi) of the only supercharger: the blower's pressure
-- curve at the engine's redline, from the same jbeam data and efficiency
-- curves the native supercharger uses. Unknown for multi-engine cars.
local superchargerEfficiency={roots={-0.55,1},rootsTwisted={-0.35,1},screws={0.3,0.7},centrifugal={0.6,0.45}}
local function superchargerBoostPsi(e)
  if combustionCount~=1 or type(e.supercharger)~='table' or not e.supercharger.isExisting then return nil end
  local sc=v and v.data and v.data.supercharger
  if type(sc)~='table' or not model.finite(tonumber(sc.pressurePSIPer1kRPM)) then return nil end
  local kind=string.lower(tostring(sc.type or ''))
  local curve=superchargerEfficiency[kind=='roots' and sc.twistedLobes and 'rootsTwisted' or kind]
  if not curve then return nil end
  local ratio=tonumber(sc.gearRatio) or 1
  local maxBlower=tonumber(sc.maxRPM) or math.ceil((e.maxRPM or 6000)*ratio)
  local blower=math.min((e.maxRPM or 6000)*ratio,maxBlower)
  if maxBlower<=0 or blower<=0 then return nil end
  local relative=blower/maxBlower
  -- Full-throttle boost controller coefficient: the curve's last point.
  local controller,atX=1,-1
  for _,point in pairs(type(sc.boostController)=='table' and sc.boostController or {}) do
    if type(point)=='table' and tonumber(point[1]) and tonumber(point[2]) and tonumber(point[1])>atX then atX=tonumber(point[1]);controller=tonumber(point[2]) end
  end
  return math.max(0,(curve[1]*relative*relative+curve[2])*sc.pressurePSIPer1kRPM*0.001*blower*controller)
end
-- Native references belong to installed parts, not the route used to buy them.
local function settleBoost(c,key,live)
  c.profile[key]=live
  if c.fuelConditionReady then c.state[key]=live end
end
-- The native turbo targets halfway between wastegate start and limit; a part
-- property, so it follows the installed turbo.
local function wastegateHalfRangePsi(e)
  local turbo=turboData(e)
  if type(turbo)~='table' then return 0 end
  local function top(x) if type(x)~='table' then return tonumber(x) end local m;for _,y in pairs(x) do y=tonumber(y);if model.finite(y) then m=math.max(m or y,y) end end;return m end
  local start,limit=top(turbo.wastegateStart),top(turbo.wastegateLimit)
  return model.finite(start) and model.finite(limit) and math.max(0,(limit-start)*.5) or 0
end
settleFactoryBoost=function(c)
  settleBoost(c,'factoryBoostPsi',factoryBoostPsi(c.engine))
  settleBoost(c,'factorySuperchargerPsi',superchargerBoostPsi(c.engine))
  c.profile.wastegateHalfRangePsi=c.profile.factoryBoostPsi and wastegateHalfRangePsi(c.engine) or nil
  if c.fuelConditionReady then
    local p=c.profile
    local signature=table.concat({p.fuelType,tostring(p.referencePowerKW),tostring(p.baseFlowLps),tostring(p.deliveryLps),
      tostring(p.maxRPM),tostring(p.requiredAKI),tostring(p.knockControl),tostring(p.factoryBoostPsi),
      tostring(p.factorySuperchargerPsi),tostring(p.wastegateHalfRangePsi)},'|')
    if c.nativeSignature~=signature then
      local parts={}
      for slot,part in pairs(v and v.data and v.data.slotPartMap or {}) do parts[#parts+1]=tostring(slot)..'='..tostring(part) end
      table.sort(parts)
      -- Compact deterministic identity, not a security hash. Keep the numeric
      -- reference in clear text so a hash collision cannot change its capacity.
      local hash=0
      for _,part in ipairs(parts) do
        for i=1,#part do hash=(hash*131+part:byte(i))%2147483647 end
        hash=(hash*131+59)%2147483647
      end
      c.nativeFingerprint=signature..'|parts='..tostring(hash);c.nativeSignature=signature
    end
    if hardware.syncNative(c.state,p,c.nativeFingerprint) then
      c.effectiveState=nil
      c.state.observedPull=nil;c.state.observedBoostPsi=nil;c.pull=nil
    end
  end
end
local function discover()
  discoveryDirty=false
  discoveredPartMap=v and v.data and v.data.slotPartMap
  unsupported={}
  local devices=powertrain and powertrain.getDevices and powertrain.getDevices() or {}
  combustionCount=0
  for _,e in pairs(devices) do if model.isCombustionEngine(e) then combustionCount=combustionCount+1 end end
  -- ECU presence is only an estimate, and is ambiguous with multiple engines.
  -- Explicit per-engine metadata always wins over this generic inference.
  local capabilities={ecu=false}
  if combustionCount==1 then
    for slot,part in pairs(v and v.data and v.data.slotPartMap or (v and v.config and v.config.parts) or {}) do
      local leaf=type(slot)=='string' and (slot:match('([^/]+)/?$') or slot):lower() or ''
      if type(part)=='string' and part~='' and
        (leaf:match('^ecu[_]?') or leaf:match('_ecu$')) then capabilities.ecu=true end
    end
  end
  local candidates,blockedTanks={},{}
  for name,e in pairs(devices) do
    if e.requiredEnergyType=='gasoline' or e.requiredEnergyType=='diesel' then
      candidates[name]=model.isCombustionEngine(e) and type(e.torqueUpdate)=='function' and
        type(e.torqueCurve)=='table' and model.finite(e.intakeAirDensityCoef) and model.finite(e.invBurnEfficiencyCoef)
      if not candidates[name] then
        local names=e.registeredEnergyStorages or e.energyStorage or {}
        if type(names)=='string' then names={names} end
        for _,tankName in pairs(names) do blockedTanks[tankName]=true end
      end
    end
  end
  for name,e in pairs(devices) do
    if e.requiredEnergyType=='gasoline' or e.requiredEnergyType=='diesel' then
      local d=dataFor(e)
      local supported=candidates[name]
      local names=e.registeredEnergyStorages or e.energyStorage or {}
      if type(names)=='string' then names={names} end
      local sharedUnsupported=false
      for _,tankName in pairs(names) do if blockedTanks[tankName] then sharedUnsupported=true;supported=false end end
      if supported then
        local c=contexts[name]
        if not c or c.engine~=e then
          if c then fuelClutch.release(c.engine);nitrousControl.release(c.engine);boostControl.release(c.engine,'fuel') end
          c={engine=e,profile=model.infer(e,d,capabilities,v and v.data),boostCut={active=false,hold=0},chargeCooling=0,knockRetard=0,sourcePower=e.maxPower,sourceRPM=e.maxRPM,sourceECU=capabilities.ecu,sourceData=d,fuelConditionReady=false}
          c.state=e.rlsFuelSavedState and normalizeState(e.rlsFuelSavedState,c.profile) or model.newEngineState(c.profile)
          if e.rlsFuelSavedState then c.fuelConditionReady=true end
          contexts[name]=c
          bindEngineConditions(c)
          nativeDamage.apply(e,c.state)
        end
        if c.sourcePower~=e.maxPower or c.sourceRPM~=e.maxRPM or c.sourceECU~=capabilities.ecu or c.sourceData~=d then
          c.profile=model.infer(e,d,capabilities,v and v.data);c.sourcePower=e.maxPower;c.sourceRPM=e.maxRPM
          c.sourceECU=capabilities.ecu;c.sourceData=d
          c.nativeSignature=nil
          -- Purchased delivery hardware and map axes remain unchanged.
        end
        settleFactoryBoost(c)
        c.gearbox=boostControl.gearbox(e)
        -- Gear layouts only change when discovery runs (new engine, reset or parts
        -- rebuild), so the per-frame sync checks once here, not every frame.
        c.transmissionCheckPending=true
      else
        local previous=contexts[name]
        if previous then
          previous.active=false;nitrousControl.release(e);boostControl.release(e,'fuel')
          releaseEffects(previous)
          e.rlsFuelSavedState=model.copy(previous.state);e.rlsFuelContext=nil;e.rlsFuelOwner=nil;contexts[name]=nil
        end
        unsupported[#unsupported+1]={name=name,reason=sharedUnsupported and candidates[name] and 'Tank shared with an unsupported engine: native fuel behavior retained' or 'Custom engine interface: fuel effects bypassed'}
      end
    end
  end
  for name,c in pairs(contexts) do if devices[name]~=c.engine then fuelClutch.release(c.engine);nitrousControl.release(c.engine);boostControl.release(c.engine,'fuel');contexts[name]=nil end end
  local connected={}
  for _,c in pairs(contexts) do
    local names=c.engine.registeredEnergyStorages or c.engine.energyStorage or {}
    if type(names)=='string' then names={names} end
    for _,name in pairs(names) do connected[name]=true end
  end
  for name,t in pairs(energyStorage and energyStorage.getStorages and energyStorage.getStorages() or {}) do
    if connected[name] and (t.energyType=='gasoline' or t.energyType=='diesel') and model.finite(t.capacity) and t.capacity>0 and model.finite(t.storedEnergy)
      and model.finite(t.energyDensity) and t.energyDensity>0 and model.finite(t.fuelLiquidDensity) and t.fuelLiquidDensity>0 then
      if tanks[name]~=t then bindTank(t);setBlend(t,t.rlsFuelBlend or model.grades.regular,liters(t)) end
      tanks[name]=t
    end
  end
  for name in pairs(tanks) do if not connected[name] then tanks[name]=nil end end
  for _,c in pairs(contexts) do syncEffects(c) end
end
-- Internal engine/parts rebuild restoration; intentionally not an editable UI
-- operation. Discovery still enforces unsupported-engine ownership boundaries.
function M.restoreTankState(saved)
  if type(saved)~='table' or (saved.version~=1 and saved.version~=2 and saved.version~=3) or not model.finite(saved.liters) then return false end
  discover();local tank=tanks[saved.name]
  if not tank then return false end
  setBlend(tank,saved.blend,saved.liters);reply(nil,true);return true
end
function M.configure(payload)
  payload=payload or {}
  -- The first GE bind must retain a notice created while restoring the part.
  if generation~=0 and payload.generation and payload.generation~=generation then
    for _,c in pairs(contexts) do c.boostAdaptation=nil end
  end
  generation=payload.generation or generation;career=payload.career==true
  if payload.flamePalette~=nil then afterfire.setPaletteReady(payload.flamePalette==true) end
  if payload.dieselSmokePalette~=nil then dieselSmokePaletteReady=payload.dieselSmokePalette==true end
  discover()
  if payload.freshConfig then
    for name,t in pairs(tanks) do if not (payload.tanks and payload.tanks[name]) then setBlend(t,model.grades.regular,liters(t)) end end
  end
  local used,asBought={},{}
  for name,c in pairs(contexts) do
    local installed=physicalPartName(c.engine)
    local installedOwner=installed and payload.engineOwners and payload.engineOwners[installed]
    if installedOwner and c.state.engineOwner and installedOwner~=c.state.engineOwner then
      c.state=normalizeState(nil,c.profile);c.fuelConditionReady=false
    end
    local saved=payload.engines and payload.engines[name]
    -- Prefer an explicit blob for the installed jbeam part when device-name lookup
    -- would otherwise reuse another engine's mainEngine record.
    if installed then
      local byPart,count=nil,0
      for _,candidate in pairs(payload.engines or {}) do
        if candidate.partOrigin==installed and not used[candidate] then byPart=candidate;count=count+1 end
      end
      if count==1 then saved=byPart end
    elseif not saved and dataFor(c.engine).partOrigin then
      -- Legacy authored partOrigin path for renamed package installs.
      local origin=dataFor(c.engine).partOrigin;local count=0
      for _,candidate in pairs(payload.engines or {}) do
        if candidate.partOrigin==origin and not used[candidate] then saved=candidate;count=count+1 end
      end
      local targets=0;for _,target in pairs(contexts) do if dataFor(target.engine).partOrigin==origin then targets=targets+1 end end
      if count~=1 or targets~=1 then saved=nil end
    end
    if saved and used[saved] then saved=nil end
    if saved and not originCompatible(saved.partOrigin,installed) then
      -- Car-level / previous-engine snapshot must not paint a replacement part.
      saved=nil
    end
    if saved and installedOwner and saved.engineOwner and saved.engineOwner~=installedOwner then saved=nil end
    if not saved and (payload.recordsChecked or payload.freshConfig) then
      -- Authoritative records found no state for the actual installed instance.
      -- An in-place preview / same-model replacement must not reuse old ownership.
      c.state=normalizeState(nil,c.profile);c.fuelConditionReady=false
    end
    if saved then
      -- setPartCondition may already have hydrated this part; only replace when the
      -- incoming blob is for the same physical engine (or we are still unhydrated).
      if not c.fuelConditionReady or originCompatible(c.state.partOrigin,installed) then
        c.state=normalizeState(saved,c.profile)
        c.state.partOrigin=installed or saved.partOrigin
        c.fuelConditionReady=true
        -- A restored tune may carry the previous gearbox's boost columns.
        c.transmissionCheckPending=true
      end
      used[saved]=true
    elseif installed then
      c.state.partOrigin=c.state.partOrigin or installed
    end
    if installedOwner then c.state.engineOwner=installedOwner end
    -- GE found no record for this engine in the vehicle or its part inventory:
    -- it is new to Fuels. Native delivery follows installed parts; explicitly
    -- purchased injectors and pumps retain their own capacities.
    if not saved and payload.recordsChecked and not c.fuelConditionReady then
      c.fuelConditionReady=true;asBought[c]=true
    elseif not saved and not payload.career and not c.fuelConditionReady then
      -- A car the player does not own (for sale, freeroam, a delivery job) is
      -- filled the same way, without claiming its calibration as the player's.
      asBought[c]=true
    end
    nativeDamage.apply(c.engine,c.state)
    settleFactoryBoost(c)
  end
  for name,s in pairs(payload.tanks or {}) do if tanks[name] then setBlend(tanks[name],s.blend,s.liters or liters(tanks[name])) end end
  -- A car arrives on fuel its engine runs on, like its cut and injectors. Only
  -- tanks with no saved fuel and not yet filled in this vehicle, unless GE says
  -- the saved fuel is the seller's fill (payload.asBought); premium is the best
  -- pump grade.
  for c in pairs(asBought) do
    local need=c.profile.requiredAKI or model.grades.regular.aki
    if model.conversionKind(c.state)=='gasoline' and need>model.grades.regular.aki then
      local names=c.engine.registeredEnergyStorages or c.engine.energyStorage or {}
      if type(names)=='string' then names={names} end
      for _,name in pairs(names) do
        local t=tanks[name]
        local sellerFill=t and (payload.asBought or not (payload.tanks and payload.tanks[name]) and not t.rlsFuelTankRestored and not t.rlsFuelFilled)
        if sellerFill and t.rlsFuelBlend.aki<need then
          setBlend(t,model.grades.premium,liters(t))
        end
      end
    end
  end
  for _,t in pairs(tanks) do t.rlsFuelFilled=true end
  for _,c in pairs(contexts) do c.effectiveState=nil;syncEffects(c) end
  enabled=true;reply(payload.requestId,true)
end
-- A changed map, kit or stage is a different car to a buyer: rate it after a new pull.
local function newSetup(c) c.state.observedPull=nil;c.state.observedBoostPsi=nil;c.state.rating=nil;c.pull=nil;c.effectiveState=nil end
local function sameAxis(a,b)
  if type(a)~='table' or type(b)~='table' or #a~=#b then return false end
  for i,value in ipairs(a) do if value~=b[i] then return false end end
  return true
end
function M.request(kind,payload,requestId,expectedGeneration)
  if expectedGeneration~=generation then reply(requestId,false,'Vehicle generation changed; reopen the fuel panel',expectedGeneration);return end
  if receipts[requestId] then reply(requestId,receipts[requestId].ok,receipts[requestId].message);return end
  payload=payload or {};local c=contexts[payload.engine];local ok,message=true,nil
  local transmissionAdapted=false
  if kind=='inspect' then
  elseif kind=='deliver' then
    local t=tanks[payload.tank];local grade=model.grades[payload.grade]
    if not t or not grade or (t.energyType=='diesel')~=(grade.diesel==true) or not model.finite(payload.liters) or payload.liters<0 then ok=false;message='Invalid fuel delivery'
    elseif t.rlsFuelLastTransaction==payload.transaction then -- idempotent retry
    elseif math.abs(liters(t)-(payload.expectedLiters or liters(t)))>0.02 or
      (payload.expectedBlend and (math.abs(t.rlsFuelBlend.ethanol-payload.expectedBlend.ethanol)>0.0001 or math.abs((t.rlsFuelBlend.nitromethane or 0)-(payload.expectedBlend.nitromethane or 0))>0.0001 or math.abs((t.rlsFuelBlend.methanol or 0)-(payload.expectedBlend.methanol or 0))>0.0001 or math.abs(t.rlsFuelBlend.aki-payload.expectedBlend.aki)>0.001)) then
      ok=false;message='Tank contents changed; request a new quote'
    else
      local current=liters(t)
      if payload.liters>t.capacity-current+0.000001 then ok=false;message='Tank capacity changed; request a new quote'
      else setBlend(t,model.mix(t.rlsFuelBlend,current,grade,payload.liters),current+payload.liters);t.rlsFuelLastTransaction=payload.transaction end
    end
  elseif kind=='drain' then
    local t=tanks[payload.tank]
    if not t then ok=false;message='Tank unavailable'
    else
      local remaining,err=model.drainAmount(liters(t),t.rlsFuelBlend,payload.liters,payload.expectedLiters,payload.expectedBlend)
      if remaining==nil then ok=false;message=err
      else setBlend(t,t.rlsFuelBlend,remaining) end
    end
  elseif kind=='flush' then
    local t=tanks[payload.tank];if not t then ok=false;message='Tank unavailable' else setBlend(t,model.grades.regular,0) end
  elseif not c then ok=false;message='Engine unavailable'
  elseif kind=='convert' then
    if c.profile.fuelType=='diesel' then ok=false;message='Diesel does not use spark-fuel conversions'
    elseif payload.conversionKind and payload.conversionKind~='ethanol' and payload.conversionKind~='methanol' and payload.conversionKind~='nitromethane' then ok=false;message='Unknown conversion'
    else c.state=model.convert(c.state,c.profile,payload.conversionKind);c.state.conversionPurchased=true;c.fuelConditionReady=true;newSetup(c) end
  elseif kind=='removeConversion' then
    if c.state.conversion then
      c.state.conversion=false;c.state.conversionKind='gasoline';c.state.conversionPurchased=nil
      c.state.control.conversion=false
      hardware.migrate(c.state,c.profile)
      c.state.tune=model.newTune(c.profile);c.state.tune.decel={mode='original'};fuelControl.appliedTune(c.state,c.profile);c.fuelConditionReady=true;newSetup(c)
    end
  elseif kind=='installHardware' then
    ok,message=hardware.install(c.state,c.profile,payload.component,payload.id)
    if ok then c.state.control.hardware=true;c.fuelConditionReady=true;newSetup(c) end
  elseif kind=='setLiveTrim' then
    if payload.expectedRevision~=nil and payload.expectedRevision~=(c.state.revision or 0) then reply(requestId,false,'Tune changed; refresh the tuner');return end
    -- A phone trim owns only the changed fields. Keep dormant garage maps and
    -- their activation flags; applying an AFR trim must not erase or revive them.
    local t=model.copy(c.state.tune)
    if payload.afrTrim~=nil then t.afrTrim=payload.afrTrim end
    if payload.boostOffset~=nil or payload.gearOffsets~=nil then
      if not c.effectiveState.tune.boost then ok=false;message='Configure gear caps in the garage first'
      else
        ok,message=boostControl.supported(c.engine,c.gearbox)
        if ok then
          if payload.boostOffset~=nil then t.boost.offset=payload.boostOffset end
          if payload.gearOffsets~=nil then t.boost.offsets=model.copy(payload.gearOffsets) end
        end
      end
    end
    if ok then ok,message=model.validateTune(t) end
    if ok then
      c.state.tune=t
      if payload.afrTrim~=nil then c.state.control.liveMixtureTrim=math.abs(t.afrTrim or 0)>1e-8 end
      c.fuelConditionReady=true;newSetup(c)
    end
  elseif kind=='recalibrateRpm' then
    -- Only the installed map. Presets stay snapshots of the limiter they were saved with.
    local axis=model.rpmAxis(c.profile.maxRPM)
    if sameAxis(c.state.tune.rpm,axis) then ok=false;message='This calibration already matches the rev limiter'
    else c.state.tune=model.resizeTune(c.state.tune,c.profile.maxRPM);c.fuelConditionReady=true;newSetup(c) end
  elseif kind=='applyTune' then
    ok,message=model.validateTune(payload.tune)
    if ok then
      local loadMatches=sameAxis(payload.tune.load,c.state.tune.load)
      local rpmMatchesInstalled=sameAxis(payload.tune.rpm,c.state.tune.rpm)
      -- A saved map from another limiter installs only when that limiter is on the car now.
      local rpmMatchesLimiter=sameAxis(payload.tune.rpm,model.rpmAxis(c.profile.maxRPM))
      if not loadMatches then ok=false;message='Map load columns must match this engine calibration'
      elseif payload.expectedRevision~=nil and payload.expectedRevision~=(c.state.revision or 0) then ok=false;message='Installed tune changed; reload before applying'
      elseif payload.tune.fuelType and payload.tune.fuelType~=c.profile.fuelType then ok=false;message='Map fuel family does not match this engine'
      elseif payload.tune.nitrous and payload.tune.nitrous.mode~='original' and not nitrousControl.supported(c.engine,c.gearbox,payload.tune.nitrous) then
        ok,message=nitrousControl.supported(c.engine,c.gearbox,payload.tune.nitrous)
      elseif model.boostEnabled(payload.tune) and not boostControl.supported(c.engine,c.gearbox) then
        ok,message=boostControl.supported(c.engine,c.gearbox)
      elseif model.boostCutMargin(payload.tune)~=model.boostCutMargin(c.state.tune) and not model.boostCutEditable(c.profile) then
        ok,message=model.boostCutEditable(c.profile)
      else
        c.state.tune=model.copy(payload.tune);transmissionAdapted=adaptTransmission(c)
        fuelControl.appliedTune(c.state,c.profile);c.fuelConditionReady=true;newSetup(c)
        -- Another map can also change mixture/timing; existing dirty drafts
        -- must not advance their guard as if only boost columns had changed.
        if transmissionAdapted then c.boostAdaptation.previousRevision=nil end
      end
    end
  elseif kind=='setBoostCut' then
    -- Only the installed boost cut; the rest of the map stays as installed.
    local margin=tonumber(payload.margin)
    ok,message=model.boostCutEditable(c.profile)
    if ok and not model.validBoostCutMargin(margin) then ok=false;message='Invalid boost cut' end
    if ok and margin~=model.boostCutMargin(c.state.tune) then
      c.state.tune.boostCut=margin~=model.constants.stockBoostCutMarginPsi and margin or nil
      c.state.control.boostCut=c.state.tune.boostCut~=nil
      c.fuelConditionReady=true;newSetup(c)
    end
  elseif kind=='savePreset' then
    ok,message=model.validateTune(payload.tune)
    if ok and payload.expectedRevision~=nil and payload.expectedRevision~=(c.state.revision or 0) then
      ok=false;message='Installed tune changed; reload before saving'
    end
    local name=type(payload.name)=='string' and payload.name:match('^%s*(.-)%s*$') or ''
    if #name<1 or #name>40 then ok=false;message='Use a preset name of 1–40 characters' end
    if ok then c.state.presets[name]=model.copy(payload.tune);c.fuelConditionReady=true end
  elseif kind=='deletePreset' or kind=='renamePreset' then
    local name=payload.name
    if payload.expectedRevision==nil or payload.expectedRevision~=(c.state.revision or 0) then
      ok=false;message='Saved maps changed; reopen the list'
    elseif type(name)~='string' or not c.state.presets[name] then
      ok=false;message='Saved map unavailable'
    elseif kind=='renamePreset' then
      local newName=type(payload.newName)=='string' and payload.newName:match('^%s*(.-)%s*$') or ''
      if #newName<1 or #newName>40 or newName:find('[%z\1-\31\127]') then
        ok=false;message='Use a map name of 1–40 characters'
      elseif newName~=name and c.state.presets[newName] then
        ok=false;message='A map with that name already exists'
      else
        c.state.presets[newName]=c.state.presets[name]
        if newName~=name then c.state.presets[name]=nil end
      end
    else c.state.presets[name]=nil end
    if ok then c.fuelConditionReady=true end
  else ok=false;message='Unknown fuel operation' end
  if ok and c and kind~='inspect' and not transmissionAdapted then c.state.revision=(c.state.revision or 0)+1 end
  if ok then for _,context in pairs(contexts) do syncEffects(context) end end
  if requestId then receipts[requestId]={ok=ok,message=message} end
  reply(requestId,ok,message)
end
local helloTimer=0
function M.updateGFX(dt)
  if not enabled then
    -- Loaded without a configure (for example after the vehicle's Lua reloaded):
    -- ask GE once for this vehicle's records instead of running unmanaged.
    if helloTimer>=0 then
      helloTimer=helloTimer+dt
      if helloTimer>1 then
        helloTimer=-1
        obj:queueGameEngineLua(require('vehicle/overhaul/geCallback').command('fuelRuntimeLoaded', tostring(obj:getID())))
      end
    end
    return
  end
  elapsed=elapsed+dt;pushElapsed=pushElapsed+dt
  if discoveredPartMap~=(v and v.data and v.data.slotPartMap) then discoveryDirty=true end
  for _,c in pairs(contexts) do
    if c.sourcePower~=c.engine.maxPower or c.sourceRPM~=c.engine.maxRPM or c.sourceData~=dataFor(c.engine) then discoveryDirty=true end
  end
  if discoveryDirty then discover() end
  for _,c in pairs(contexts) do
    local blend,chemistry=syncEffects(c)
    local e=c.engine
    if c.effectsActive then afterfire.updateGFX(c.afterfire,e.rlsAfterfireState,dt) end
    if not c.effectsActive then
      -- Telemetry is advisory. Native mode never calls the combustion response,
      -- accumulates exposure, adds exhaust combustion or wraps engine physics.
      local fuel=chemistry.fuel
      local load=model.clamp(e.engineLoad or 0,0,1)
      local lambda=c.profile.fuelType=='diesel' and model.dieselAFR(load)/14.5 or model.referenceLambda(load)
      local manifold=e.manifoldPressurePa;local ambient=powertrain.currentEnvPressure or model.constants.referenceAtmospherePa
      local response=c.nativeResponse or {mode='native',torque=1,efficiencyPenalty=1,timing=0,effectiveTiming=0,
        knock=0,knockRetard=0,requestedRetard=0,knockExposureRate=0,leanExposureRate=0,
        richSeverity=0,leanSeverity=0,idleRoughness=0,exhaustFraction=0,coolingW=0,chargeCoolingC=0,soot=0,smokeSoot=0,
        boostFuelCut=false,exposureValid=false,afrEstimated=true}
      c.nativeResponse=response
      response.rpm=(e.outputAV1 or 0)*9.5492966
      response.load=load
      response.lambda=lambda
      response.targetLambda=lambda
      response.afr=lambda*fuel.stoich
      response.targetAFR=lambda*fuel.stoich
      response.fuelDensity=fuel.density
      response.ethanol=fuel.ethanol
      response.methanol=fuel.methanol
      response.nitromethane=fuel.nitromethane
      response.pressureEstimated=not model.finite(manifold)
      response.manifoldPressureKPa=model.finite(manifold) and manifold/1000 or nil
      response.boostPsi=model.finite(manifold) and (manifold-ambient)/model.constants.pascalsPerPSI or nil
      response.exhaustTemperature=e.thermals and e.thermals.exhaustTemperature
      c.response=response
    elseif not e.isDisabled and (not e.isStalled or (e.starterEngagedCoef or 0)>0) and e.hasFuel~=false and (e.ignitionCoef or 1)>0 and (e.outputAV1 or 0)>1 then
      local load=model.clamp(e.engineLoad or 0,0,1)
      local temp=e.thermals and e.thermals.engineBlockTemperature or 90
      local measuredFlow=(c.referenceTime or 0)>0 and c.referenceEnergy/c.referenceTime/(c.profile.referenceEnergyPerL or model.constants.referenceEnergyPerL) or nil
      local cranking=(e.starterEngagedCoef or 0)>0 and (e.outputAV1 or 0)<(e.idleAV or c.profile.idleRPM/9.5492966)*.8
      if cranking then measuredFlow=c.profile.baseFlowLps*math.max(0,e.outputAV1*9.5492966)/c.profile.maxRPM*.12 end
      c.referenceEnergy,c.referenceTime=0,0
      local ambient=math.max(1000,powertrain.currentEnvPressure or model.constants.referenceAtmospherePa)
      local manifold=e.manifoldPressurePa
      if not model.finite(manifold) and combustionCount==1 and c.profile.boosted and electrics and electrics.values and model.finite(electrics.values.boost) then
        manifold=ambient+electrics.values.boost*model.constants.pascalsPerPSI
      end
      local pressureEstimated=not model.finite(manifold)
      if pressureEstimated then manifold=ambient*(e.forcedInductionCoef or 1) end
      local rpm=(e.outputAV1 or 0)*9.5492966
      -- The installed fuel map controls combustion; gear selects the boost map.
      local gear=boostControl.currentGear(c.gearbox)
      local state=c.effectiveState
      -- Neutral and reverse share first gear's boost settings for staging.
      local boostGear=gear<=0 and 1 or gear
      local target=model.boostTarget(state.tune,rpm,boostGear)
      local boostMapMismatch=model.boostEnabled(state.tune) and not sameAxis(state.tune.boost.gears,boostControl.gears(c.gearbox))
      -- Keep ownership with a zero target if the installed gear map is invalid.
      -- Only disabling the override returns boost to other tools.
      if model.boostEnabled(state.tune) and (boostMapMismatch or target==nil) then target=0 end
      local smokeBoostReference=target and 1+target*model.constants.pascalsPerPSI/ambient or nil
      local variables=v and v.data and v.data.variables or emptyData
      local adjustment=variables['$rlsWastegateAdjustment']
      c.profile.nativeBoostDeviation=math.abs(tonumber(type(adjustment)=='table' and adjustment.val) or 0)>1e-8
        or math.abs(boostControl.proOffset(e))>1e-8
      c.responseProbe=c.responseProbe or {}
      local probe=model.response(c.profile,state,blend,rpm,load,temp-c.chargeCooling,manifold/ambient,measuredFlow,c.knockRetard or 0,smokeBoostReference,c.responseProbe,chemistry)
      local previousRetard=c.knockRetard or 0
      local responseTime=probe.requestedRetard>previousRetard and model.constants.knockAttackSeconds or model.constants.knockReleaseSeconds
      c.knockRetard=previousRetard+(probe.requestedRetard-previousRetard)*(1-math.exp(-dt/responseTime))
      c.response=model.response(c.profile,state,blend,rpm,load,temp-c.chargeCooling,manifold/ambient,measuredFlow,c.knockRetard,smokeBoostReference,responseBuffer(c),chemistry)
      local r=c.response
      if boostMapMismatch then r.boostMapMismatch=true end
      if target~=nil then boostControl.setTarget(e,target) else boostControl.release(e,'fuel') end
      r.boostTargetPsi=target;r.boostOwner=target~=nil and 'overhaul' or 'external';r.gear=gear
      c.fuel=chemistry.fuel;c.combustion=c.combustion or {}
      local extra,retard,active,overrunAir=combustion.overrun(c.combustion,c.profile,state.tune,c.fuel,
        {running=not cranking,throttle=e.requestedThrottle or e.throttle or (electrics and electrics.values.throttle) or 0,load=load,rpm=rpm,temperature=temp,state=state},dt)
      c.extraFlowLps=extra
      c.overrunAirKgPerSec=overrunAir
      r.decelActive=active;r.decelRetard=retard;r.extraFlowLps=extra
      r.torque=r.torque*math.max(.1,1-retard*.008)
      r.efficiencyPenalty=r.efficiencyPenalty/math.max(.1,1-retard*.008)
      r.exhaustFraction=model.clamp((r.exhaustFraction or 0)+retard*.008,0,.75)
      -- Overboost fuel cut: above the calibration's limit the ECU stops fuel
      -- until boost falls back. Cutting drops boost, so it cycles at full load.
      -- Original retains native protection. Our separate cut is active only
      -- with an explicit calibration or Weepy-controlled boost adjustment.
      local customCut=state.tune.boostCut~=nil or not model.nativeControl(c.profile,state.tune)
      local cutPsi=customCut and not pressureEstimated and model.boostCutPsi(c.profile,state.tune)
      local cut=c.boostCut or {active=false,hold=0};c.boostCut=cut
      local boostPsi=(manifold-ambient)/model.constants.pascalsPerPSI
      cut.over=cutPsi and boostPsi>cutPsi and (cut.over or 0)+dt or 0
      if not cutPsi then cut.active=false
      elseif not cut.active and cut.over>=model.constants.boostCutDelaySeconds then cut.active=true;cut.hold=.15
      elseif cut.active then
        cut.hold=cut.hold-dt
        if cut.hold<=0 and boostPsi<cutPsi-model.constants.boostCutReleasePsi then cut.active=false end
      end
      r.boostCutPsi=cutPsi or nil;r.boostFuelCut=cut.active
      if cut.active then r.torque=0 end
      -- Resale rating: the boost a full-throttle pull actually reaches, then the
      -- setup rated at that boost. It travels with the engine part. A naturally
      -- aspirated engine's boost is known to be zero; a boosted one without a
      -- pressure reading is skipped rather than rated at a guessed boost.
      if (not pressureEstimated or not c.profile.boosted) and load>=.9 and rpm>=(c.profile.maxRPM or 6000)*.4 then
        local p=c.pull or {boostPsi=0,duty=0,knock=false,lean=false,cut=false};c.pull=p;c.pullGap=0
        p.boostPsi=math.max(p.boostPsi,boostPsi);p.duty=math.max(p.duty,r.deliveryDuty or 0)
        p.knock=p.knock or (r.knock or 0)>.05;p.lean=p.lean or (r.leanSeverity or 0)>.05;p.cut=p.cut or cut.active
      elseif c.pull then
        c.pullGap=(c.pullGap or 0)+dt
        if c.pullGap>2 then c.state.observedPull=c.pull;c.pull=nil end
      end
      c.ratingTimer=(c.ratingTimer or 0)+dt
      if c.ratingTimer>=2 then
        c.ratingTimer=0
        c.state.rating=model.tuneRating(c.profile,state,blend,c.state.observedPull)
      end
      r.exhaustTemperature=e.thermals and e.thermals.exhaustTemperature or temp
      r.exhaustBurnW=c.combustion.burnW or 0
      c.fuelBudget=c.fuelBudget or {}
      for key in pairs(c.fuelBudget) do c.fuelBudget[key]=nil end
      for key,value in pairs(c.combustion) do c.fuelBudget[key]=model.copy(value) end
      r.fuelBudget=c.fuelBudget
      r.manifoldPressureKPa=manifold/1000;r.pressureEstimated=pressureEstimated
      local fuel=chemistry.fuel
      local airMass=r.flowLps*fuel.density*fuel.stoich*r.lambda
      local target=airMass>0.00001 and model.clamp(r.coolingW/(airMass*model.constants.airSpecificHeat),0,model.constants.maximumChargeCoolingC) or 0
      c.chargeCooling=c.chargeCooling+(target-c.chargeCooling)*(1-math.exp(-dt/model.constants.chargeResponseSeconds))
      -- Advisory eligibility only; damage is accumulated by physics and settled
      -- against actual tank withdrawals in bindFuelAccounting, never here.
      r.exposureValid=model.finite(measuredFlow) and measuredFlow>0 and dt>0 and model.finite(e.engineLoad)
      nativeDamage.apply(e,c.state)
      r.chargeCoolingC=c.chargeCooling;r.rpm=(e.outputAV1 or 0)*9.5492966;r.load=load
      if e.thermals and model.finite(e.thermals.cylinderWallTemperature) then
        -- All supplementary heating/cooling was settled once in fuel accounting.
        r.wallCoolingW=c.combustion.wallCoolingW or 0;r.cylinderWallTemperature=e.thermals.cylinderWallTemperature
      end
      local smokeSoot=r.smokeSoot or r.soot or 0
      if c.profile.fuelType=='diesel' then
        r.smokePalette=dieselSmokePaletteReady and 'rls' or 'native'
        local staged=dieselLimiterSmoke.consume(c,dt)
        if e.isTempRevLimiterActive then smokeSoot=staged
        else smokeSoot=math.max(smokeSoot,staged) end
        r.limiterSmokeSoot=staged
        if cut.active then dieselLimiterSmoke.clear(c) end
      end
      if smokeSoot>0 and not cut.active and obj.addParticleByNodesRelative then
        -- Bound hitch catch-up, while retaining the requested rate at 10+ FPS.
        local rate=model.constants.dieselSmokeParticlesPerSecond
        local smokeDt=math.min(math.max(0,dt),.1)
        c.sootTime=(c.sootTime or 0)+smokeDt*rate*smokeSoot
        local whole=math.floor(c.sootTime+1e-9)
        local pulses=math.min(math.ceil(rate*.1),whole)
        c.sootTime=math.max(0,c.sootTime-whole)
        for pulse=1,pulses do
          local particle=dieselSmokePalette.select(c,smokeSoot,electrics.values.airspeed or 0,dieselSmokePaletteReady)
          for _,tip in pairs(e.thermals and e.thermals.exhaustEndNodes or {}) do
            if tip.finish and tip.start and (not obj.inWater or not obj:inWater(tip.finish)) then
              local smokeParticle,speed=afterfire.smoke(c.afterfire,tip,particle)
              obj:addParticleByNodesRelative(tip.finish,tip.start,-speed,smokeParticle,0,1)
            end
          end
        end
      else c.sootTime=0;dieselSmokePalette.reset(c) end
      -- Audible detonation follows current combustion knock, never a target table
      -- or old damage exposure. Native bearing-damage audio keeps its own owner.
      local audible=c.profile.fuelType~='diesel' and (r.knock or 0)>.05 and load>.2 and rpm>500
        and not (e.thermals and e.thermals.connectingRodBearingsDamaged)
      c.knockSoundTime=audible and (c.knockSoundTime or 0)+dt*math.min(12,rpm/120)*r.knock or 0
      if c.knockSoundTime>=1 then
        c.knockSoundTime=c.knockSoundTime%1
        if sounds and sounds.playSoundOnceFollowNode and e.engineNodeID then
          sounds.playSoundOnceFollowNode('event:>Vehicle>Failures>failure_engine_knock',e.engineNodeID,model.clamp(r.knock*.6,.08,.6))
        end
      end
      r.coldStartMultiplier=model.coldStartMultiplier(blend,temp)
      r.oilTemperature=e.thermals and e.thermals.oilTemperature
      r.coolantTemperature=e.thermals and e.thermals.coolantTemperature
    else
      local ownsBoost=model.boostEnabled(c.effectiveState.tune)
      if ownsBoost then boostControl.setTarget(e,0) else boostControl.release(e,'fuel') end
      nativeDamage.apply(e,c.state)
      local response=c.stoppedResponse or {}
      c.stoppedResponse=response
      response.boostOwner=ownsBoost and 'overhaul' or 'external'
      response.boostTargetPsi=ownsBoost and 0 or nil
      response.torque=1
      response.efficiencyPenalty=1
      response.rpm=0
      response.load=0
      response.ethanol=blend.ethanol
      response.methanol=blend.methanol
      c.response=response
      c.chargeCooling=0;c.knockRetard=0;c.knockSoundTime=0;c.sootTime=0;c.referenceTime,c.referenceEnergy=0,0
      dieselSmokePalette.reset(c)
      -- Retain paid exhaust fuel after a stall/key-off: hot exhaust may burn
      -- briefly without new injection. Accounting owns decay, not GFX replay.
      c.extraFlowLps=0;c.lastFueledFlow=0
      dieselLimiterSmoke.clear(c)
      c.response.exhaustTemperature=e.thermals and e.thermals.exhaustTemperature or 20
    end
  end
  if pushElapsed>=0.5 then pushElapsed=0;reply(nil,true) end
end
function M.onReset()
  discoveryDirty=true
  for _,c in pairs(contexts) do fuelClutch.invalidate(c.engine) end
  elapsed=0;pushElapsed=0
  for _,c in pairs(contexts) do afterfire.restore(c.afterfire);c.afterfire=nil;c.physicsResetPending=true;c.referenceTime=0;c.referenceEnergy=0;c.knockSoundTime=0;c.sootTime=0;c.extraFlowLps=0;c.combustion={};c.accountTime=0;c.extraEnergy=0;c.engine.rlsAfterfireState=nil end
  for _,c in pairs(contexts) do dieselLimiterSmoke.clear(c);dieselSmokePalette.reset(c);c.pendingKnockExposure=0;c.pendingDieselHeatJ=0;c.unburnedEnergy=0;c.fireTime=0;c.crankTime=0;c.exhaustAirMass=0;c.lastFueledFlow=0;c.lastFueledAir=0;c.crankPhase=0 end
end
-- In-place parts rebuilds invalidate setup; ordinary telemetry updates do not.
function M.onPartsChanged()
  discoveryDirty=true
  for _,c in pairs(contexts) do fuelClutch.invalidate(c.engine) end
end
function M.onExtensionUnloaded()
  enabled=false
  for _,c in pairs(contexts) do
    fuelClutch.release(c.engine)
    afterfire.restore(c.afterfire);c.afterfire=nil
    nitrousControl.release(c.engine)
    boostControl.release(c.engine,'fuel')
    if c.engine.torqueUpdate==c.wrapper then c.engine.torqueUpdate=c.original end
    if c.engine.updateFuelUsage==c.fuelWrapper then c.engine.updateFuelUsage=c.fuelOriginal end
    if c.engine.activateStarter==c.starterWrapper then c.engine.activateStarter=c.starterOriginal end
    c.engine.rlsFuelSavedState=model.copy(c.state);c.engine.rlsFuelContext=nil;c.engine.rlsFuelOwner=nil
    c.engine.rlsAfterfireState=nil
  end
  -- Dormant portable metadata must not leave alternative-fuel density, range or
  -- tank mass active in freeroam. Preserve litres while restoring native storage.
  for _,t in pairs(tanks) do
    local binding=t.rlsFuelNativeBinding
    if binding then
      local volume=liters(t)
      t.energyDensity,t.fuelLiquidDensity=binding.energyDensity,binding.fuelLiquidDensity
      t.energyCapacity,t.fuelNodeMassCoef=binding.energyCapacity,binding.fuelNodeMassCoef
      t.storedEnergy=volume*t.energyDensity*t.fuelLiquidDensity
      t.remainingVolume=volume;t.remainingRatio=t.capacity>0 and volume/t.capacity or 0
      if obj.setNodeMass and t.fuelNodeMassCoef then
        for node,baseMass in pairs(t.fuelNodes or {}) do obj:setNodeMass(node,baseMass+t.storedEnergy*t.fuelNodeMassCoef) end
      end
      if t.getPartCondition==binding.getWrapper then t.getPartCondition=binding.get end
      if t.setPartCondition==binding.setWrapper then t.setPartCondition=binding.set end
      t.rlsFuelConditionBound=nil;t.rlsFuelNativeBinding=nil;t.rlsFuelBlend=nil
      t.rlsFuelTankRestored=nil;t.rlsFuelFilled=nil
    end
  end
end
M.getSnapshot=snapshot
return M
