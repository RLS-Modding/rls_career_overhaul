-- Pure fuel math. No game state, currency, or career consumption multiplier here.
local M = {version = 4}
local hardware=require('common/rlsFuelHardware')
M.hardware=hardware
local min, max, abs = math.min, math.max, math.abs
function M.finite(x) return type(x) == 'number' and x == x and abs(x) < math.huge end
function M.clamp(x, lo, hi) return min(hi, max(lo, M.finite(x) and x or lo)) end
-- Mod engines fork the native device under types such as "combustionEngine_camshalfts_vip".
-- Same substring rule as the scanner and maintenance; the runtime still checks the interface.
function M.isCombustionEngine(device)
  return type(device) == 'table' and tostring(device.type or ''):find('combustionEngine', 1, true) ~= nil
end
function M.copy(x)
  if type(x) ~= 'table' then return x end
  local out = {}; for k, v in pairs(x) do out[k] = M.copy(v) end; return out
end
M.grades = {
  diesel = {id='diesel',label='Diesel',diesel=true},
  regular = {id='regular', label='Regular 87 AKI · E10', ethanol=0.10, aki=87},
  premium = {id='premium', label='Premium 93 AKI · E10', ethanol=0.10, aki=93},
  e85 = {id='e85', label='E85 · 85% ethanol', ethanol=0.85, methanol=0, aki=100},
  m100 = {id='m100', label='M100 · Racing methanol', ethanol=0, methanol=1, aki=99},
  nitro90 = {id='nitro90', label='Nitro 90 · 90% nitromethane / 10% methanol', ethanol=0, methanol=0.10, nitromethane=0.90},
}
M.constants = {
  -- Reference E10 equals BeamNG's stock gasoline: 31.125 MJ/L, .75 kg/L.
  -- Ethanol: ~26.8 MJ/kg, .789 kg/L, AFRstoich 9; gasoline AFRstoich 14.7.
  ethanolDensity=0.789, ethanolLHV=26.8e6, ethanolLatent=840000,
  methanolDensity=0.792, methanolLHV=19.9e6, methanolLatent=1100000, methanolStoich=6.4,
  -- Density at 20 C (FIA fuel specification); NIST combustion HHV corrected
  -- for 1.5 mol water vapor: (709.6 - 1.5*44.004) kJ / .061040 kg.
  nitroDensity=1.138, nitroLHV=10.543806e6, nitroLatent=627000,
  nitroStoich=24/(61.040*0.232), -- CH3NO2 + .75 O2; dry-air oxygen mass fraction.
  methanolPurityMinimum=0.98, methanolWarmTemperatureC=40, methanolColdTorqueLoss=0.40,
  gasolineDensity=(0.75-0.1*0.789)/0.9,
  gasolineEnergyPerL=(31.125e6-0.1*0.789*26.8e6)/0.9,
  gasolineLatent=350000, referenceEnergyPerL=31.125e6,
  -- Stock delivery runs near its limit at factory power, so raised boost soon
  -- needs larger injectors. Version 2 of the sizing; see migrateDelivery.
  defaultDuty=0.935, previousDefaultDuty=0.85, deliverySizing=2,
  deliveryStageFactors={[0]=1,[1]=1.25,[2]=1.5,[3]=2},
  -- Stock calibration cuts fuel this far above factory boost (psi), like an
  -- overboost pressure switch. A custom map may move it up to the maximum.
  stockBoostCutMarginPsi=4.5, minBoostCutMarginPsi=1, maxBoostCutMarginPsi=25, boostCutReleasePsi=1.5,
  -- Boost must stay over the cut this long; short overshoot after a shift is tolerated.
  boostCutDelaySeconds=0.3,
  conversionDuty=0.80, minLambda=0.60, maxLambda=1.40,
  minTiming=-20, maxTiming=20, knockDamageSeconds=120,
  maximumChargeCoolingC=12, chargeResponseSeconds=0.35, airSpecificHeat=1005,
  referenceChargeKelvin=300, coolingUtilization=0.30,
  -- Empirical exposure thresholds, not fractions of physical engine health.
  ringExposure=0.25, gasketKnockExposure=0.65, catastrophicExposure=1,
  inferredKnockRetard=6, maximumKnockRetard=12, knockAttackSeconds=0.08, knockReleaseSeconds=1.5,
  -- Empirical tuning headroom around the reference map (full load, specified fuel).
  bestPowerLambdaOffset=0.03, bestPowerGain=0.02, knockDegreesPerLambda=33,
  knockMarginDegrees=2, bestTorqueDegrees=3, bestTorqueGain=0.012,
  pascalsPerPSI=6894.757293, referenceAtmospherePa=101325,
  -- Octane demand per atmosphere of boost added above the car's reference
  -- (its factory boost, at least ratio 2 for boosted engines). About 2 AKI of
  -- premium headroom lets a stock 91 AKI turbo engine add ~8 psi; more needs E85.
  boostOctanePerAtm=3.5,
  -- Richest diesel exhaust: ten times the former 24-particle/s allowance.
  dieselSmokeParticlesPerSecond=240,
}
-- Effective AFR coefficients fit gameplay E10/E85/M100/Nitro90 anchors.
-- Density and chemical energy remain independent of these calibration values.
local a=.1*M.constants.ethanolDensity/.75
local b=.85*M.constants.ethanolDensity/(.85*M.constants.ethanolDensity+.15*M.constants.gasolineDensity)
local delta=(9.8-14.7)/(b-a)
M.constants.gasolineStoich=14.7-a*delta
M.constants.ethanolStoich=M.constants.gasolineStoich+delta
M.constants.nitroStoich=(1.7*(.9*M.constants.nitroDensity+.1*M.constants.methanolDensity)-.1*M.constants.methanolDensity*6.4)/(.9*M.constants.nitroDensity)
-- Bounded gameplay vaporization penalty on the native cranking timer. Native
-- temperature scaling, starter torque and start/stop logic remain in control.
function M.coldStartMultiplier(blend,temperature)
  if not blend or blend.diesel then return 1 end
  return 1+2.5*M.clamp(((temperature or 90)-20)/-40,0,1)*M.clamp(((blend.ethanol or 0)-.15)/.70,0,1)
end
function M.properties(blend)
  blend = blend or M.grades.regular
  if blend.diesel then return {diesel=true,ethanol=0,methanol=0,nitromethane=0,aki=0,density=blend.density or .84,energyPerL=blend.energyPerL or 36.12e6,stoich=14.5,latent=250000} end
  local e = M.clamp(blend.ethanol, 0, 1)
  local m = M.clamp(blend.methanol or 0, 0, 1-e)
  local n = M.clamp(blend.nitromethane or 0, 0, 1-e-m)
  local c = M.constants
  local em,mm,nm,gm=e*c.ethanolDensity,m*c.methanolDensity,n*c.nitroDensity,(1-e-m-n)*c.gasolineDensity
  local density=em+mm+nm+gm
  return {ethanol=e,methanol=m,nitromethane=n,aki=M.clamp(blend.aki or 87,60,120),density=density,
    energyPerL=em*c.ethanolLHV+mm*c.methanolLHV+nm*c.nitroLHV+(1-e-m-n)*c.gasolineEnergyPerL,
    stoich=(em*c.ethanolStoich+mm*c.methanolStoich+nm*c.nitroStoich+gm*c.gasolineStoich)/density,
    latent=(em*c.ethanolLatent+mm*c.methanolLatent+nm*c.nitroLatent+gm*c.gasolineLatent)/density}
end
-- The reference fuel is fixed; do not allocate its properties in each cooling step.
local coolingReferenceFuel=M.properties(M.grades.regular)
function M.mix(a, litersA, b, litersB)
  litersA, litersB = max(0, litersA or 0), max(0, litersB or 0)
  local total=litersA+litersB
  if total<=0 then return M.copy(a or b or M.grades.regular) end
  if (a and a.diesel) or (b and b.diesel) then return M.copy((a and a.diesel) and a or b) end
  a,b=M.properties(a),M.properties(b)
  -- AKI interpolation is an explicit empirical approximation, not blend chemistry.
  return {ethanol=(a.ethanol*litersA+b.ethanol*litersB)/total,
    methanol=(a.methanol*litersA+b.methanol*litersB)/total,
    nitromethane=(a.nitromethane*litersA+b.nitromethane*litersB)/total,
    aki=((a.aki or 87)*litersA+(b.aki or 87)*litersB)/total}
end
local stationGradeAliases={gasoline='regular',any='regular',methanol='m100',['nitro 90']='nitro90'}
local function stationGrade(kind)
  if type(kind)~='string' then return nil end
  kind=kind:lower()
  return M.grades[stationGradeAliases[kind] or kind]
end
function M.stationGrades(energyTypes)
  local out,seen={},{}
  for _,kind in ipairs(energyTypes or {'any'}) do
    local grade=stationGrade(kind)
    if grade and not grade.diesel and not seen[grade.id] then
      seen[grade.id]=true;out[#out+1]=M.copy(grade)
    end
  end
  return out
end
-- Grade names advertise gasoline-compatible blends, never additional native tank types.
function M.stationEnergyTypes(energyTypes)
  local out={}
  for key,value in pairs(energyTypes or {any=true}) do
    local kind=type(key)=='number' and value or value==true and key
    if type(kind)=='string' then
      local grade=stationGrade(kind)
      local native=kind=='any' and 'any' or grade and (grade.diesel and 'diesel' or 'gasoline') or kind
      out[native]=true
    end
  end
  return out
end
-- Peak full-load combustion power (W) as native fuel use sees it: the torque
-- curve with the turbo or supercharger's own full-boost coefficients, before
-- friction. Rated maxPower is after friction, so fuel demand sized from it runs
-- short by the friction share. nil when the engine has no usable curve.
function M.grossPowerW(engine)
  local curve=type(engine.torqueCurve)=='table' and engine.torqueCurve
  if not curve then return nil end
  local coefs
  for _,key in ipairs({'turbocharger','supercharger'}) do
    local device=engine[key]
    if not coefs and type(device)=='table' and device.isExisting and type(device.getTorqueCoefs)=='function' then
      local ok,result=pcall(device.getTorqueCoefs)
      if ok and type(result)=='table' then coefs=result end
    end
  end
  local maxRPM=engine.maxRPM or math.huge;local best
  for rpm,torque in pairs(curve) do
    if type(rpm)=='number' and rpm<maxRPM and M.finite(torque) then
      local watts=torque*(coefs and tonumber(coefs[rpm]) or 1)*rpm*0.104719755
      if not best or watts>best then best=watts end
    end
  end
  return best and best>0 and best or nil
end
-- Match native combustionEngineThermals: walls use max(block mass / 100, 4 kg),
-- not a fraction of the whole block's heat capacity. Keep the old estimate for
-- custom engines without a compiled node group/material we can identify.
local function cylinderWallHeatCapacity(data,vehicleData,fallback)
  local material=data.engineBlockMaterial or 'iron'
  local specificHeat=material=='iron' and 450 or ((material=='aluminum' or material=='aluminium') and 910)
  local group=type(data.engineBlock)=='table' and data.engineBlock._engineGroup_nodes
  local nodes=vehicleData and vehicleData.nodes
  if not specificHeat or type(group)~='table' or type(nodes)~='table' then return fallback end
  local mass=0
  for _,id in pairs(group) do
    local weight=nodes[id] and nodes[id].nodeWeight
    if not M.finite(weight) or weight<0 then return fallback end
    mass=mass+weight
  end
  return mass>0 and max(mass/100,4)*specificHeat or fallback
end
function M.infer(engine, data, capabilities, vehicleData)
  data=data or {}; local meta=data.rlsFuel or {}
  local count=tonumber(meta.injectorCount or meta.cylinderCount or data.cylinderCount or data.numberOfCylinders)
  local countEstimated=false
  if not count then
    local sound=type(data.soundConfig)=='table' and data.soundConfig or (vehicleData and vehicleData[data.soundConfig or 'soundConfig'])
    count=type(sound)=='table' and tonumber(sound.fundamentalFrequencyCylinderCount) or nil
    countEstimated=true -- audio cylinder count assumes one injector per cylinder
  end
  if not count or count<1 or count>64 or count%1~=0 then count=8;countEstimated=true end
  local boosted = type(engine.turbocharger)=='table' and engine.turbocharger.isExisting
    or type(engine.supercharger)=='table' and engine.supercharger.isExisting or false
  local kw=max(1,(engine.maxPower or 100)*0.735499)
  local displacement=tonumber(meta.displacementLiters or data.displacement or data.engineDisplacement)
  -- Native curves/controllers already author a working engine. Induction and
  -- power density alone are not evidence of an octane deficit at native boost.
  local aki=87
  local explicit=M.finite(meta.requiredAKI)
  aki=explicit and M.clamp(meta.requiredAKI,60,110) or aki
  local inverseEfficiency=engine.invBurnEfficiencyTable and engine.invBurnEfficiencyTable[100]
  inverseEfficiency=M.finite(inverseEfficiency) and max(1,inverseEfficiency) or 1/0.30
  local fuelType=engine.requiredEnergyType=='diesel' and 'diesel' or 'gasoline'
  local referenceEnergyPerL=fuelType=='diesel' and 36.12e6 or M.constants.referenceEnergyPerL
  local baseLps=(M.grossPowerW(engine) or kw*1000)*inverseEfficiency/referenceEnergyPerL
  local inferredDelivery=baseLps/M.constants.defaultDuty
  if meta.flexFuel==true then
    local reference,ethanol=M.properties(M.grades.regular),M.properties(M.grades.e85)
    inferredDelivery=inferredDelivery*reference.density*reference.stoich/(ethanol.density*ethanol.stoich)
  end
  local declaredKnock=type(meta.knockControl)=='boolean'
  local knockControl=declaredKnock and meta.knockControl or (not declaredKnock and capabilities and capabilities.ecu==true) or false
  -- An existing native/custom controller may opt out of our additional retard.
  if meta.knockControlOwner=='native' then knockControl=false end
  local blockHeatCapacity=max(20000,tonumber(meta.blockHeatCapacityJPerK) or (displacement or 2)*35000)
  return {injectorCount=count,injectorCountEstimated=countEstimated,fuelType=fuelType,referenceEnergyPerL=referenceEnergyPerL,requiredAKI=aki, estimated=not explicit, boosted=not not boosted,
    knockControl=knockControl, knockControlEstimated=not declaredKnock,
    knockControlSource=meta.knockControlOwner=='native' and 'native controller' or (declaredKnock and 'declared' or (knockControl and 'installed ECU estimate' or 'unknown; not assumed')),
    maxKnockRetard=knockControl and M.clamp(meta.maxKnockRetard or M.constants.inferredKnockRetard,0,M.constants.maximumKnockRetard) or 0,
    referenceBoostRatio=tonumber(meta.referenceBoostRatio) or (boosted and 2 or 1),
    maxRPM=max(1000,engine.maxRPM or 6500), idleRPM=max(300,engine.idleRPM or 800),
    referencePowerKW=kw, baseFlowLps=baseLps,
    deliveryLps=M.finite(meta.deliveryLps) and max(0.00001,meta.deliveryLps) or inferredDelivery,
    deliveryEstimated=not M.finite(meta.deliveryLps), nativeReferenceVersion=1, factoryFlex=meta.flexFuel==true,
    referenceFuel=meta.referenceFuel=='nitro90' and 'nitro90' or 'regular',
    blockHeatCapacity=blockHeatCapacity,
    cylinderWallHeatCapacity=cylinderWallHeatCapacity(data,vehicleData,max(2000,blockHeatCapacity*.15))}
end
-- As-equipped is the delivery included with the current native configuration.
-- It follows native demand, never a Weepy boost target or purchased flow rating.
function M.nativeControl(profile,tune)
  return not M.boostEnabled(tune) and not profile.nativeBoostDeviation
end
function M.nativeCapacity(profile,state,referenceFlow,injector,pump)
  local h=state.hardware
  if profile.nativeReferenceVersion and profile.deliveryEstimated and h and M.nativeControl(profile,state.tune) then
    -- Native burn-efficiency curves and transients can exceed a peak-power
    -- estimate. Treat this as native delivery, with the same fixed duty margin.
    local native=referenceFlow/M.constants.defaultDuty
    if h.injector=='equipped' and abs(h.equippedInjectorLps-profile.deliveryLps)<1e-9 then injector=max(injector,native) end
    if h.pump=='equipped' and abs(h.equippedPumpLps-profile.deliveryLps)<1e-9 then pump=max(pump,native) end
  end
  return injector,pump
end
function M.stockLambda(load) return 1-0.14*M.clamp((load-0.55)/0.45,0,1) end
local referenceLoadAxis={0,0.15,0.30,0.45,0.60,0.75,0.90,1}
function M.referenceLambda(load)
  local axis=referenceLoadAxis
  load=M.clamp(load,0,1)
  for i=1,#axis-1 do if load<=axis[i+1] then
    local f=(load-axis[i])/(axis[i+1]-axis[i])
    return M.stockLambda(axis[i])*(1-f)+M.stockLambda(axis[i+1])*f
  end end
  return M.stockLambda(1)
end
-- Validate a reviewed drain in both VMs. The tolerance matches fuel delivery
-- quotes and allows tiny idle consumption while a request crosses the bridge.
function M.drainAmount(current,blend,amount,expected,expectedBlend)
  if not M.finite(current) or current<0 or not M.finite(amount) or amount<=0 or
    not M.finite(expected) or expected<=0 or amount>expected or type(expectedBlend)~='table' or type(blend)~='table' then
    return nil,'Invalid drain amount'
  end
  for _,key in ipairs({'ethanol','methanol','nitromethane','aki'}) do
    local wanted=expectedBlend[key];local actual=blend[key]
    if key=='methanol' or key=='nitromethane' then wanted=wanted or 0;actual=actual or 0 end
    if not M.finite(wanted) or not M.finite(actual) then return nil,'Invalid tank blend' end
    local tolerance=key=='aki' and 0.001 or 0.0001
    if math.abs(actual-wanted)>tolerance then return nil,'Tank blend changed; review the drain again' end
  end
  if math.abs(current-expected)>0.02 then return nil,'Tank quantity changed; review the drain again' end
  -- Only an explicitly reviewed full drain may consume the tiny remainder
  -- difference. A partial request cannot grow to empty a tank unexpectedly.
  local full=math.abs(amount-expected)<0.000001
  if amount>current and not full then return nil,'Not enough fuel; review the drain again' end
  local drained=full and current or amount
  return math.max(0,current-drained),drained
end

-- Twelve columns, evenly spaced from idle-side 0 to the engine's current rev limiter.
function M.rpmAxis(maxRPM,spacing)
  local limit=max(1000,tonumber(maxRPM) or 6500)
  limit=M.clamp(limit,1000,50000)
  local rpm={}
  if spacing==100 or spacing==500 or spacing==1000 then
    for n=0,limit,spacing do rpm[#rpm+1]=n end
    if rpm[#rpm]~=limit then rpm[#rpm+1]=limit end
    return rpm
  end
  for i=1,12 do rpm[i]=math.floor(limit*(i-1)/11+0.5) end
  return rpm
end
function M.dieselAFR(load) return 60-42*M.clamp(load,0,1) end
function M.newTune(profile)
  local t={version=2,fuelType=profile.fuelType or 'gasoline',afrTrim=0,rpm=M.rpmAxis(profile.maxRPM),load={0,0.15,0.30,0.45,0.60,0.75,0.90,1},lambda={},timing={}}
  for y,l in ipairs(t.load) do
    t.lambda[y],t.timing[y]={},{}
    for x in ipairs(t.rpm) do t.lambda[y][x]=profile.fuelType=='diesel' and M.dieselAFR(l)/14.5 or M.stockLambda(l);t.timing[y][x]=0 end
  end
  return t
end
function M.decel(tune)
  local d=tune and tune.decel or {}
  return {mode=d.mode or 'original',cutDelay=d.cutDelay or 0.5,fueling=d.fueling or 1,retard=d.retard or 0,continuous=d.continuous==true,enabled=d.enabled~=false,allowStockAfterfire=d.allowStockAfterfire==true}
end
-- Overboost fuel cut, as psi above factory boost. nil keeps the stock margin.
function M.boostCutMargin(tune)
  local margin=tune and tune.boostCut
  return M.finite(margin) and margin or M.constants.stockBoostCutMarginPsi
end
function M.boostCutPsi(profile,tune)
  if not profile or not M.finite(profile.factoryBoostPsi) then return nil end
  return profile.factoryBoostPsi+M.boostCutMargin(tune)
end
-- Whether this engine's boost cut may be changed. The map editor and the PRO
-- Tuner both go through here, so a future ECU requirement covers both.
function M.boostCutEditable(profile)
  if not profile or not M.finite(profile.factoryBoostPsi) or profile.factoryBoostPsi<=0 then return false,'No known factory boost to cut above' end
  return true
end
function M.validBoostCutMargin(margin)
  return M.finite(margin) and margin>=M.constants.minBoostCutMarginPsi and margin<=M.constants.maxBoostCutMarginPsi
end
-- Delivery hardware: a kit's base capacity times the installed injector stage.
function M.deliveryStage(state)
  local stage=state and tonumber(state.deliveryStage) or 0
  return M.constants.deliveryStageFactors[stage] and stage or 0
end
function M.deliveryBase(state)
  return M.finite(state.baseDeliveryLps) and state.baseDeliveryLps or
    (state.deliveryLps or 0)/M.constants.deliveryStageFactors[M.deliveryStage(state)]
end
function M.setDeliveryStage(state,stage,base)
  base=base or M.deliveryBase(state)
  state.deliveryStage=stage;state.baseDeliveryLps=base
  state.deliveryLps=base*M.constants.deliveryStageFactors[stage]
  return state
end
-- Engines sized before version 2 carry the larger stock capacity. Rescale
-- the base once; kits keep their own sizing and every stage keeps its factor.
function M.migrateDelivery(state)
  if state.deliverySizing==M.constants.deliverySizing then return state end
  local base=M.deliveryBase(state)
  if M.conversionKind(state)=='gasoline' then base=base*M.constants.previousDefaultDuty/M.constants.defaultDuty end
  M.setDeliveryStage(state,M.deliveryStage(state),base)
  state.deliverySizing=M.constants.deliverySizing
  return state
end
function M.validateDecel(tune)
  if tune.decel==nil then return true end
  if type(tune.decel)~='table' then return false end
  local d=M.decel(tune)
  return (d.mode=='original' or d.mode=='custom') and M.finite(d.cutDelay) and d.cutDelay>=0 and d.cutDelay<=5
    and M.finite(d.fueling) and d.fueling>=0 and d.fueling<=2 and M.finite(d.retard) and d.retard>=0 and d.retard<=20
    and (tune.decel.continuous==nil or type(tune.decel.continuous)=='boolean')
    and (tune.decel.enabled==nil or type(tune.decel.enabled)=='boolean')
    and (tune.decel.allowStockAfterfire==nil or type(tune.decel.allowStockAfterfire)=='boolean')
end
local nitrousTune=require('common/rlsNitrousTune')
function M.validateTune(t)
  if type(t)~='table' or (t.version~=1 and t.version~=2) or type(t.rpm)~='table' or #t.rpm<2 or #t.rpm>501 or (t.version==1 and #t.rpm~=12) or
    type(t.load)~='table' or #t.load~=8 or type(t.lambda)~='table' or type(t.timing)~='table' then return false,'Invalid map format' end
  for _,axis in ipairs({t.rpm,t.load}) do
    for i,v in ipairs(axis) do if not M.finite(v) or (i>1 and v<=axis[i-1]) then return false,'Map axes must increase' end end
  end
  if t.rpm[1]~=0 or t.rpm[#t.rpm]>50000 or t.load[1]~=0 or t.load[8]~=1 then return false,'Invalid map range' end
  for y=1,8 do
    if type(t.lambda[y])~='table' or type(t.timing[y])~='table' or #t.lambda[y]~=#t.rpm or #t.timing[y]~=#t.rpm then return false,'Missing map cells' end
    for x=1,#t.rpm do
      local l,d=t.lambda[y][x],t.timing[y][x]
      if not M.finite(l) or l<(t.fuelType=='diesel' and 12/14.5 or .6) or l>(t.fuelType=='diesel' and 200/14.5 or 1.4) or not M.finite(d) or d< -20 or d>20 then return false,'Cell outside supported range' end
    end
  end
  if t.afrTrim~=nil and (not M.finite(t.afrTrim) or t.afrTrim< -20 or t.afrTrim>20) then return false,'Invalid AFR trim' end
  if t.boost~=nil then local ok,err=M.validateBoost(t.boost,#t.rpm);if not ok then return false,err end end
  local nitrousOK,nitrousError=nitrousTune.validate(t.nitrous)
  if not nitrousOK then return false,nitrousError end
  if not M.validateDecel(t) then return false,'Invalid Decel settings' end
  if t.boostCut~=nil and not M.validBoostCutMargin(t.boostCut) then
    return false,'Invalid boost cut'
  end
  return true
end
local function segment(axis, value)
  value=M.clamp(value,axis[1],axis[#axis])
  for i=1,#axis-1 do if value<=axis[i+1] then return i,(value-axis[i])/(axis[i+1]-axis[i]) end end
  return #axis-1,1
end
function M.sample(t,field,rpm,load)
  local x,xf=segment(t.rpm,rpm);local y,yf=segment(t.load,load);local a=t[field]
  local lo=a[y][x]*(1-xf)+a[y][x+1]*xf
  local hi=a[y+1][x]*(1-xf)+a[y+1][x+1]*xf
  return lo*(1-yf)+hi*yf
end
function M.boostEnabled(tune)
  local b=tune and tune.boost
  return b~=nil and b.enabled==true and b.mode~='original'
end
function M.validateBoost(b,rows)
  if type(b)~='table' or (b.mode~='original' and b.mode~='caps' and b.mode~='map') then return false,'Invalid boost mode' end
  if b.enabled~=nil and type(b.enabled)~='boolean' then return false,'Invalid boost override' end
  if not M.finite(b.offset or 0) or abs(b.offset or 0)>30 then return false,'Invalid boost offset' end
  if type(b.gears)~='table' or #b.gears<1 or #b.gears>64 or type(b.caps)~='table' or #b.caps~=#b.gears then return false,'Invalid boost gears' end
  if type(b.offsets)~='table' or #b.offsets~=#b.gears then return false,'Invalid gear offsets' end
  if type(b.targets)~='table' or #b.targets~=rows then return false,'Invalid boost rows' end
  for i,g in ipairs(b.gears) do
    if not M.finite(g) or g%1~=0 or g<1 or (i>1 and g<=b.gears[i-1]) then return false,'Invalid forward gear' end
    if not M.finite(b.caps[i]) or b.caps[i]<0 or b.caps[i]>200 or not M.finite(b.offsets[i]) or abs(b.offsets[i])>30 then return false,'Invalid boost cap/offset' end
  end
  for _,row in ipairs(b.targets) do
    if type(row)~='table' or #row~=#b.gears then return false,'Invalid boost columns' end
    for _,value in ipairs(row) do if not M.finite(value) or value<0 or value>200 then return false,'Invalid boost target' end end
  end
  return true
end
-- Reconcile only the boost columns; presets remain snapshots until loaded.
function M.adaptBoostGears(tune,gears,baselinePsi)
  local previous=tune.boost
  if not previous then return false end
  local same=#previous.gears==#gears
  for index,gear in ipairs(gears) do if previous.gears[index]~=gear then same=false;break end end
  if same then return false end
  if #gears==0 then
    if not M.boostEnabled(tune) then return false end
    tune.boost=nil;return true
  end
  local columns={}
  for index,gear in ipairs(previous.gears) do columns[gear]=index end
  local lastColumn=#previous.gears
  local globalOffsetPsi=previous.offset or 0
  local lastOffsetPsi=globalOffsetPsi+previous.offsets[lastColumn]
  local safeBaselinePsi=M.clamp(tonumber(baselinePsi) or 0,0,200)
  -- Keep negative trim after interpolation: clamping each row first can raise
  -- the new column above the old target between RPM rows.
  local newOffsetPsi=min(lastOffsetPsi,0)
  local function newTargetPsi(valuePsi)
    return min(safeBaselinePsi-newOffsetPsi,valuePsi+lastOffsetPsi-newOffsetPsi,200)
  end
  local boost=M.copy(previous)
  boost.gears=M.copy(gears);boost.caps={};boost.offsets={};boost.targets={}
  for row in ipairs(tune.rpm) do boost.targets[row]={} end
  for index,gear in ipairs(gears) do
    local source=columns[gear]
    boost.caps[index]=source and previous.caps[source] or newTargetPsi(previous.caps[lastColumn])
    boost.offsets[index]=source and previous.offsets[source] or newOffsetPsi-globalOffsetPsi
    for row in ipairs(tune.rpm) do
      boost.targets[row][index]=source and previous.targets[row][source] or newTargetPsi(previous.targets[row][lastColumn])
    end
  end
  tune.boost=boost
  return true
end
function M.boostTarget(t,rpm,gear)
  local b=t.boost;if not M.boostEnabled(t) then return nil end
  local col;for i,g in ipairs(b.gears) do if g==gear then col=i;break end end
  if not col then return nil end
  local target=b.caps[col]
  -- Advanced owns the request completely; saved Simple caps are inactive.
  if b.mode=='map' then local x,f=segment(t.rpm,rpm);target=b.targets[x][col]*(1-f)+b.targets[x+1][col]*f end
  return M.clamp(target+(b.offset or 0)+b.offsets[col],0,200)
end
function M.resizeTune(t,limit,spacing)
  local out=M.copy(t);out.version=2;out.rpm=M.rpmAxis(limit,spacing)
  for _,field in ipairs({'lambda','timing'}) do
    out[field]={};for y,l in ipairs(t.load) do out[field][y]={};for x,r in ipairs(out.rpm) do out[field][y][x]=M.sample(t,field,r,l) end end
  end
  if out.boost then
    out.boost.targets={};for x,r in ipairs(out.rpm) do
      local i,f=segment(t.rpm,r);local row={}
      for col in ipairs(t.boost.gears) do row[col]=t.boost.targets[i][col]*(1-f)+t.boost.targets[i+1][col]*f end
      out.boost.targets[x]=row
    end
  end
  return out
end
function M.newEngineState(profile)
  local state={version=5,revision=0,conversion=profile.factoryFlex,conversionKind=profile.factoryFlex and 'ethanol' or 'gasoline',deliveryLps=profile.deliveryLps,
    baseDeliveryLps=profile.deliveryLps,deliveryStage=0,deliverySizing=M.constants.deliverySizing,
    tune=M.newTune(profile),control={version=1,conversion=profile.factoryFlex==true},exposure={knock=0,lean=0,legacy=0},fuelFailures={},presets={}}
  hardware.migrate(state,profile);return state
end
function M.conversionKind(state)
  return state.conversion and (state.conversionKind=='nitromethane' and 'nitromethane' or (state.conversionKind=='methanol' and 'methanol' or 'ethanol')) or 'gasoline'
end
function M.convert(state,profile,kind)
  kind=kind or 'ethanol'
  assert(kind=='ethanol' or kind=='methanol' or kind=='nitromethane','Unsupported conversion')
  local out=M.copy(state)
  out.version=state.nativeBaseline and 6 or 5;out.conversion=true;out.conversionKind=kind
  out.control=out.control or {version=1};out.control.conversion=true
  local reference,ethanol=M.properties(M.grades.regular),M.properties(kind=='nitromethane' and M.grades.nitro90 or (kind=='methanol' and M.grades.m100 or M.grades.e85))
  hardware.migrate(out,profile) -- retain separately owned hardware
  out.deliverySizing=M.constants.deliverySizing
  out.tune=M.newTune(profile)
  if kind=='nitromethane' then
    for y,l in ipairs(out.tune.load) do for x in ipairs(out.tune.rpm) do out.tune.lambda[y][x]=1-.28*M.clamp(l/.75,0,1) end end
  end
  return out
end
-- kg inputs produce joules; kg/s inputs produce watts. One usable evaporation
-- budget above the native gasoline reference is shared by charge and walls.
-- Reserve the full charge-cooling target even while its response is smoothing,
-- so the wall correction cannot spend that same energy a second time.
function M.evaporativeCooling(fuel,mass,airMass,referenceLambda,coldSeverity)
  if fuel.diesel then return 0,0,0 end
  local referenceMass=airMass/max(.001,coolingReferenceFuel.stoich*referenceLambda)
  local total=max(0,mass*fuel.latent-referenceMass*coolingReferenceFuel.latent)*M.constants.coolingUtilization
    *(1-M.clamp(coldSeverity or 0,0,1))
  local charge=min(total,airMass*M.constants.airSpecificHeat*M.constants.maximumChargeCoolingC)
  return total,charge,max(0,total-charge)
end
-- Callers may own scratch outputs; the ordinary public path still returns a
-- detached table. Chemistry is immutable until the actual blend changes.
function M.responseChemistry(blend)
  local fuel=M.properties(blend)
  return {fuel=fuel,reference=M.properties(M.grades.regular),nitro=M.properties(M.grades.nitro90),
    ethanol=M.properties({ethanol=fuel.ethanol,aki=fuel.aki}),
    diesel=fuel.diesel and fuel or M.properties(M.grades.diesel)}
end
local function clearResponse(output)
  output=output or {}
  for key in pairs(output) do output[key]=nil end
  return output
end
function M.response(profile,state,blend,rpm,load,temperature,boostRatio,referenceFlowLps,appliedRetard,smokeBoostReference,output,chemistry)
  if profile.fuelType=='diesel' then return M.dieselResponse(profile,state,blend,rpm,load,referenceFlowLps,boostRatio,smokeBoostReference,output,chemistry) end
  local fuel=chemistry and chemistry.fuel or M.properties(blend);local reference=chemistry and chemistry.reference or M.properties(M.grades.regular)
  load=M.clamp(load,0,1);rpm=max(0,rpm or 0);boostRatio=max(1,boostRatio or 1)
  local target=M.clamp(M.sample(state.tune,'lambda',rpm,load)/(1+(state.tune.afrTrim or 0)/100),.6,1.4)
  local timing=M.sample(state.tune,'timing',rpm,load)
  local referenceLambda=M.referenceLambda(load)
  local refFlow=M.finite(referenceFlowLps) and max(0,referenceFlowLps) or profile.baseFlowLps*load*M.clamp(rpm/profile.maxRPM,0,1.5)
  local airFlow=refFlow*reference.density*reference.stoich*referenceLambda
  local kind=M.conversionKind(state)
  -- The ethanol sensor is not a universal alcohol sensor. M100 hardware uses a
  -- fixed methanol calibration; contaminated fuel requires draining/recalibration.
  local meteredStoich=kind=='nitromethane' and (chemistry and chemistry.nitro or M.properties(M.grades.nitro90)).stoich or (kind=='methanol' and M.constants.methanolStoich or
    (kind=='ethanol' and (chemistry and chemistry.ethanol or M.properties({ethanol=fuel.ethanol,aki=fuel.aki})).stoich or reference.stoich))
  local desiredMass=airFlow/max(0.001,meteredStoich*target)
  local injector,pump=hardware.capacity(state,profile)
  injector,pump=M.nativeCapacity(profile,state,refFlow,injector,pump)
  local capacity=max(0.000001,min(injector,pump))*fuel.density
  local mass=min(desiredMass,capacity)
  local lambda=airFlow>0.000001 and airFlow/max(0.000001,mass*fuel.stoich) or target
  local optimalAdvance=M.clamp((fuel.aki-profile.requiredAKI)*0.25,0,3)
  if kind=='ethanol' then optimalAdvance=optimalAdvance+(8-optimalAdvance)*M.clamp(fuel.ethanol/.85,0,1)
  elseif kind=='methanol' then optimalAdvance=20*fuel.methanol end
  -- A zero trim is deliberately a conservative tune. No automatic boost increase.
  -- Like a factory map, the reference runs rich of best power at high load;
  -- leaning toward it gains a little but spends knock margin (below).
  local C=M.constants
  local highLoad=M.clamp((load-0.55)/0.45,0,1)
  local bestLambda=referenceLambda+C.bestPowerLambdaOffset*highLoad
  local leanGain=C.bestPowerGain*highLoad
  local mixtureGain
  if lambda<=referenceLambda then mixtureGain=1-0.8*(referenceLambda-lambda)^2
  elseif lambda<bestLambda then mixtureGain=1+leanGain*(1-(1-(lambda-referenceLambda)/(bestLambda-referenceLambda))^2)
  else mixtureGain=1+leanGain-1.5*(lambda-bestLambda)^2 end
  local loadRisk=M.clamp((load-0.45)/0.55,0,1)^2
  -- Authored induction is already included in the inferred requirement. Only
  -- pressure above that reference adds further octane demand. A car runs its
  -- boost as bought on the pump fuel it arrives on, like the boost cut; only
  -- boost added on top of it raises the requirement.
  local boostReference=profile.referenceBoostRatio or 1
  local factory=M.finite(profile.factoryBoostPsi) and profile.factoryBoostPsi+(tonumber(profile.wastegateHalfRangePsi) or 0) or profile.factorySuperchargerPsi
  if M.finite(factory) and factory>0 then
    local atm=C.referenceAtmospherePa/C.pascalsPerPSI
    boostReference=(atm+factory)/atm
  end
  local nativePoint=abs(target-referenceLambda)<1e-8 and abs(timing)<1e-8 and M.nativeControl(profile,state.tune)
  local requirement=profile.requiredAKI+(nativePoint and 0 or max(0,(temperature or 90)-105)*0.10)
    +(M.nativeControl(profile,state.tune) and 0 or max(0,boostRatio-boostReference)*C.boostOctanePerAtm)
  local octaneDeficit=max(0,requirement-fuel.aki)
  -- Map retard below the reference earns the same knock margin per degree as
  -- protection retard, so knock control only covers what the map leaves.
  -- A leaner mixture spends the 2 degree margin; a richer one adds to it.
  local mixtureShift=(lambda-referenceLambda)*C.knockDegreesPerLambda
  local rawKnock=max(0,octaneDeficit/12+max(0,timing+mixtureShift-optimalAdvance-C.knockMarginDegrees)/16-max(0,-timing)/16)
  local retardLimit=profile.knockControl and (profile.maxKnockRetard or 0) or 0
  local requestedRetard=M.clamp(rawKnock*16,0,retardLimit)*loadRisk
  local retard=M.clamp(appliedRetard==nil and requestedRetard or appliedRetard,0,retardLimit)
  local effectiveTiming=timing-retard
  -- Best torque sits just past knock onset, so advancing to the edge pays a
  -- little and one degree more knocks away the gain.
  local past=max(0,effectiveTiming-optimalAdvance);local mbt=C.bestTorqueDegrees
  local marginGain=past<=mbt and C.bestTorqueGain*(1-(1-past/mbt)^2) or C.bestTorqueGain-0.0015*(past-mbt)^2
  local timingGain=1+0.012*min(effectiveTiming,optimalAdvance)+marginGain-0.007*max(0,-effectiveTiming)
  local knock=M.clamp((rawKnock-retard/16)*loadRisk,0,1)
  local lean=M.clamp((lambda-1.04)/0.35,0,1)*loadRisk
  local rich=M.clamp((0.68-lambda)/0.15,0,1)
  if airFlow<=0.000001 then knock,lean,rich=0,0,0 end
  -- Empirical warm-up/poor-running approximation, not a cranking or vapor model.
  local coldSeverity=fuel.methanol*M.clamp((M.constants.methanolWarmTemperatureC-(temperature or 90))/40,0,1)*M.clamp(1-rpm/3000,0,1)
  local torque=M.clamp(timingGain*mixtureGain*(1-0.30*knock)*(1-0.65*lean)*(1-0.7*rich)*(1-M.constants.methanolColdTorqueLoss*coldSeverity),0.05,1.08)
  local exhaustFraction=M.clamp(max(0,referenceLambda-lambda)*.8+max(0,-effectiveTiming)*.004,0,.30)
  -- Full nitro response (including cleared gasoline knock) only with Nitro 90
  -- hardware. Trace contamination in an unconverted tank must not wipe knock risk.
  if fuel.nitromethane>0.001 and kind=='nitromethane' then
    -- Reduced-order nitro combustion: extra fuel per external air, bounded
    -- in-cylinder completion, late burning and delivery starvation. No AKI gain.
    local complete=M.clamp(lambda^0.65,.35,1)
    local perAir=(fuel.energyPerL/fuel.density)/(fuel.stoich*max(.1,lambda))
    local refPerAir=(reference.energyPerL/reference.density)/(reference.stoich*referenceLambda)
    if profile.referenceFuel=='nitro90' then
      local refNitro=chemistry and chemistry.nitro or M.properties(M.grades.nitro90)
      refPerAir=(refNitro.energyPerL/refNitro.density)/(refNitro.stoich*.72)*(.72^0.65)
    end
    requestedRetard,retard,knock=0,0,0;effectiveTiming=timing
    local timingFactor=M.clamp(1+.004*min(max(0,timing),15)-.008*max(0,-timing)-.012*max(0,timing-15)^2,.05,1.06)
    knock=M.clamp(max(0,timing-15)/10,0,1)*loadRisk
    lean=M.clamp((lambda-.95)/.6,0,1)*loadRisk
    rich=M.clamp((.60-lambda)/.3,0,1)
    torque=M.clamp(perAir/refPerAir*complete*timingFactor*(1-.8*lean)*(1-.8*rich),.05,3)
    exhaustFraction=M.clamp(1-complete+max(0,-timing)*.005,0,.65)
  end
  local fuelFlowLps=mass/fuel.density
  -- Nitro's family-specific branch must not recreate knock after the zero-air
  -- guard above; no delivered charge means no damaging combustion.
  if airFlow<=.000001 or mass<=.000001 then knock,lean,rich=0,0,0 end
  -- Only extra evaporative cooling relative to reference gasoline is added.
  local referenceMass=airFlow/max(0.001,reference.stoich*referenceLambda)
  local coolingW=M.evaporativeCooling(fuel,mass,airFlow,referenceLambda,coldSeverity)
  local energyRatio=referenceMass>0.000001 and (mass/fuel.density*fuel.energyPerL)/(referenceMass/reference.density*reference.energyPerL) or 1
  local baseInjector=state.hardware and state.hardware.equippedInjectorLps or profile.deliveryLps
  local roughness=max(0,M.idleRoughness(profile,injector,fuelFlowLps,rpm,load)-M.idleRoughness(profile,baseInjector,fuelFlowLps,rpm,load))
  local response=clearResponse(output)
  response.fuelDensity=fuel.density
  response.calibrationAFR=meteredStoich
  response.afr=lambda*fuel.stoich
  response.targetAFR=target*meteredStoich
  response.referenceAFR=fuel.stoich
  response.injectorDuty=desiredMass/(injector*fuel.density)
  response.pumpDuty=desiredMass/(pump*fuel.density)
  response.deliveryLimit=injector<=pump and 'injector' or 'pump'
  response.idleRoughness=roughness
  response.nitroPulse=kind=='nitromethane' and fuel.nitromethane*M.clamp(1-load*3,0,1)*M.clamp(1-(rpm-profile.idleRPM)/1500,0,1) or 0
  response.lambda=lambda
  response.targetLambda=target
  response.timing=timing
  response.effectiveTiming=effectiveTiming
  response.knockRetard=retard
  response.requestedRetard=requestedRetard
  response.torque=torque
  response.efficiencyPenalty=energyRatio/max(0.05,torque)
  response.referenceFlowLps=refFlow
  response.flowLps=fuelFlowLps
  response.deliveryDuty=desiredMass/capacity
  response.knock=knock
  response.knockExposureRate=knock*knock/M.constants.knockDamageSeconds
  -- Mixture risk is advisory; native thermals own temperature-based failures.
  response.leanExposureRate=0
  response.richSeverity=rich
  response.leanSeverity=lean
  response.airMassKgPerSec=airFlow
  response.exhaustFraction=exhaustFraction
  response.coolingW=coolingW
  response.coldRunningSeverity=coldSeverity
  response.requiredAKI=requirement
  response.ethanol=fuel.ethanol
  response.methanol=fuel.methanol
  response.nitromethane=fuel.nitromethane
  response.aki=fuel.aki
  return response
end
function M.idleRoughness(profile,injector,flow,rpm,load)
  if flow<=0 then return 0 end
  local pulseMs=120000/max(profile.idleRPM,rpm)*flow/max(.000001,injector)
  -- Effective minimum repeatable pulse; total-set flow avoids invented cylinder counts.
  return M.clamp(1-pulseMs/.7,0,1)*M.clamp(1-load*5,0,1)*M.clamp(1-(rpm-profile.idleRPM)/1200,0,1)
end
function M.dieselResponse(p,s,blend,rpm,load,referenceFlow,boostRatio,smokeBoostReference,output,chemistry)
  local fuel=chemistry and chemistry.diesel or M.properties(blend and blend.diesel and blend or M.grades.diesel)
  load=M.clamp(load,0,1)
  local ref=max(0,referenceFlow or p.baseFlowLps*load*M.clamp(rpm/p.maxRPM,0,1.5))
  local baseAFR=M.dieselAFR(load);local air=ref*fuel.density*baseAFR
  local target=M.clamp(M.sample(s.tune,'lambda',rpm,load)*14.5/(1+(s.tune.afrTrim or 0)/100),12,200)
  local desired=air/target/fuel.density
  local injector,pump=hardware.capacity(s,p)
  injector,pump=M.nativeCapacity(p,s,ref,injector,pump)
  local flow=min(desired,injector,pump)
  local afr=flow>1e-9 and air/(flow*fuel.density) or target
  local ratio=ref>1e-9 and flow/ref or 1
  local soot=M.clamp((18-afr)/6,0,1)*load
  -- Visual mixing/spool approximation, separate from the delivered-AFR soot
  -- that already controls torque and heat. A loaded turbo diesel smokes more
  -- before air catches up, but genuinely over-fuelled exhaust remains smoky
  -- at full boost. Lean/starved engines cannot create this extra cloud.
  local reference=smokeBoostReference
  if not M.finite(reference) then
    reference=M.finite(p.factoryBoostPsi) and 1+p.factoryBoostPsi*M.constants.pascalsPerPSI/M.constants.referenceAtmospherePa or p.referenceBoostRatio or 1
  end
  local deficit=p.boosted and reference>1.01 and M.clamp((reference-max(1,boostRatio or 1))/(reference-1),0,1) or 0
  -- Add Weepy spool smoke only for fuel delivered beyond the native baseline.
  -- Native diesel exhaust remains responsible for its own stock smoke.
  local enrichment=baseAFR-afr>1e-8 and M.clamp((baseAFR-afr)/6,0,1) or 0
  -- Begin smoothly above zero load, including idle-speed throttle pickup. The
  -- old 20% dead zone and squared ramp hid enriched smoke until much later.
  -- Full-load intensity, boost taper and actual delivered-fuel gates stay intact.
  local mixing=.75*deficit*load*M.clamp((24-afr)/6,0,1)*enrichment
  -- Exhaust visibility is nonlinear: moderately rich delivery still leaves a
  -- substantial plume when the turbo has finished spooling. Preserve clean
  -- delivery at zero soot, and keep this separate from combustion penalties.
  local richCloud=math.sqrt(soot)
  local smokeSoot=flow>1e-9 and M.clamp(richCloud+(1-richCloud)*mixing,0,1) or 0
  local torque=M.clamp(min(ratio,baseAFR/16.5)*(1-.18*soot),.05,4)
  local thermal=M.clamp((16.5-afr)/4.5,0,1)*load
  -- Separate combustible hydrocarbon estimate from soot/visual cloud intensity.
  -- Conservative loaded-overfuel calibration, not measured injection chemistry.
  -- Spool smoke alone must not create a flame fuel supply. Cold starting and
  -- long-term wet stacking need their own cylinder/film model in a later pass.
  local dieselUnburnedFraction=flow>1e-9 and .08*load*M.clamp((16.5-afr)/4.5,0,1)^2 or 0
  local response=clearResponse(output)
  response.afr=afr
  response.targetAFR=target
  response.referenceAFR=14.5
  response.lambda=afr/14.5
  response.targetLambda=target/14.5
  response.torque=torque
  response.efficiencyPenalty=ratio/max(.05,torque)
  response.flowLps=flow
  response.referenceFlowLps=ref
  response.injectorDuty=desired/injector
  response.pumpDuty=desired/pump
  response.deliveryDuty=desired/min(injector,pump)
  response.deliveryLimit=injector<=pump and 'injector' or 'pump'
  response.idleRoughness=M.idleRoughness(p,injector,flow,rpm,load)
  response.soot=soot
  response.smokeSoot=smokeSoot
  response.smokeBoostDeficit=deficit
  response.dieselThermalStress=thermal
  response.extraCylinderHeatW=max(0,flow-ref)*fuel.energyPerL*.18
  response.knock=0
  response.knockRetard=0
  response.requestedRetard=0
  response.knockExposureRate=0
  response.leanExposureRate=0
  response.leanSeverity=0
  response.richSeverity=soot
  response.coolingW=0
  response.airMassKgPerSec=air
  response.exhaustFraction=dieselUnburnedFraction
  response.dieselUnburnedFraction=dieselUnburnedFraction
  response.ethanol=0
  response.methanol=0
  response.nitromethane=0
  response.aki=0
  response.requiredAKI=0
  response.coldRunningSeverity=0
  response.timing=0
  response.effectiveTiming=0
  return response
end
-- Explicit mechanical repair retains the purchased hardware and calibration.
-- This operation is used by the existing repair service, never by tuning.
-- What a buyer's test drive would find: full-load output at the boost the car
-- actually runs versus factory boost on the reference map, and whether the
-- setup is sound at that boost. Used for resale value, not for physics.
-- `pull` is the last full-throttle pull with this setup: its peak boost and
-- delivery, and whether knock, lean running or the fuel cut showed up. Without
-- one the rating uses factory boost and the model's own estimate.
function M.tuneRating(profile,state,blend,pull)
  pull=type(pull)=='table' and pull or nil
  local atm=M.constants.referenceAtmospherePa/M.constants.pascalsPerPSI
  local factory=M.finite(profile.factoryBoostPsi) and profile.factoryBoostPsi or nil
  local boostPsi=factory and max(factory,pull and M.finite(pull.boostPsi) and pull.boostPsi or factory) or 0
  local pressureGain=factory and (atm+boostPsi)/(atm+factory) or 1
  local ratio=(atm+boostPsi)/atm
  local rpm=(profile.maxRPM or 6000)*.85
  local flow=(profile.baseFlowLps or 0)*pressureGain
  local r=M.response(profile,state,blend,rpm,1,90,ratio,flow)
  if pull and M.finite(pull.duty) and pull.duty>0 and r.deliveryDuty>0 then
    -- Rated power overstates some engines' real fuel demand; use the measured one.
    r=M.response(profile,state,blend,rpm,1,90,ratio,flow*pull.duty/r.deliveryDuty)
  end
  local e=state.exposure or {}
  local failed=false;for _,v in pairs(state.fuelFailures or {}) do if v then failed=true end end
  local customBoost=not M.nativeControl(profile,state.tune)
  local cut=(state.tune.boostCut~=nil or customBoost) and M.boostCutPsi(profile,state.tune)
  local healthy=r.knock<=.05 and r.leanSeverity<=.05 and r.deliveryDuty<=1 and not failed
    and (e.knock or 0)+(e.legacy or 0)<.1 and (not cut or cut>=boostPsi+.5)
    and not (pull and (pull.knock or pull.lean or pull.cut))
  return {version=2,gain=(customBoost and pressureGain or 1)*r.torque-1,healthy=healthy,boostPsi=boostPsi,duty=r.deliveryDuty,measured=pull~=nil}
end
function M.repairedEngineState(state)
  local out=M.copy(state)
  out.version=out.nativeBaseline and 6 or (out.hardware and 5 or 4);out.damage=nil;out.legacyCondition=0
  out.exposure={knock=0,lean=0,legacy=0};out.fuelFailures={}
  return out
end
-- Exposure stays with the engine but is not a displayed health percentage.
function M.accumulateExposure(state,response,dt)
  local e=state.exposure
  dt=max(0,M.finite(dt) and dt or 0)
  e.knock=M.clamp(e.knock+(response.knockExposureRate or 0)*dt,0,1)
  -- Retain old lean exposure for save compatibility, but never let the old
  -- temperature-blind counter create new failures (including during load).
  -- Existing failure flags remain persistent until an explicit repair.
  local total=e.knock+e.legacy
  if total>=M.constants.ringExposure then state.fuelFailures.pistonRingsDamaged=true end
  if e.knock>=M.constants.gasketKnockExposure then state.fuelFailures.headGasketBlown=true end
  if total>=M.constants.catastrophicExposure then state.fuelFailures.lockedUp=true end
end
function M.warning(profile,state,blend)
  if profile.fuelType=='diesel' then return '' end
  local warnings={}
  local kind=M.conversionKind(state);blend=M.properties(blend)
  if blend.nitromethane>0.001 or kind=='nitromethane' then
    if kind~='nitromethane' then warnings[#warnings+1]='Nitro 90 needs the Nitro 90 conversion. Without it the engine can run dangerously lean.' end
    if kind=='nitromethane' and (math.abs(blend.nitromethane-.90)>.02 or math.abs(blend.methanol-.10)>.02) then warnings[#warnings+1]='The Nitro 90 kit needs the 90/10 blend. Drain before changing fuels.' end
  end
  if blend.methanol>0.001 and kind~='methanol' and kind~='nitromethane' then warnings[#warnings+1]='Methanol needs the M100 conversion. This fuel system cannot run it.' end
  if kind=='methanol' and blend.methanol<M.constants.methanolPurityMinimum then warnings[#warnings+1]='The M100 kit needs nearly pure methanol. Drain first; this mix can run very rich.' end
  if blend.methanol>0.001 and blend.methanol<0.98 and kind~='nitromethane' then warnings[#warnings+1]='Avoid mixing methanol with other fuel. Drain first.' end
  if blend.ethanol>0.15 and kind=='gasoline' then warnings[#warnings+1]='Too much ethanol for this engine. Fit the flex-fuel kit, or drain and refill with gasoline.' end
  if kind~='nitromethane' and kind~='methanol' and (blend.aki or 87)+0.25<profile.requiredAKI then
    warnings[#warnings+1]=string.format('Octane too low: %.0f AKI in the tank, the engine needs about %.0f. Use higher-octane fuel, or pull timing or boost and go easy on high load.',blend.aki or 87,profile.requiredAKI)
  end
  local delivery=M.response(profile,state,blend,profile.maxRPM,1,90,profile.referenceBoostRatio or 1,profile.baseFlowLps)
  if delivery.deliveryDuty>1 then warnings[#warnings+1]='Full-load fuel demand is over the '..delivery.deliveryLimit..' capacity. Fit a bigger '..delivery.deliveryLimit..' or reduce boost; a richer AFR won\'t fix it.' end
  return table.concat(warnings,' ')
end
return M
