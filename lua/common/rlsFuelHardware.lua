-- Effective installed flow capacities. Prices are gameplay values, not quotations.
local M={}
local function copy(t) local r={} for k,v in pairs(t) do r[k]=type(v)=='table' and copy(v) or v end return r end
local function price(n) return math.floor(n/50+.5)*50 end
-- Saved systems without a known individual rating show their total so owned entries differ.
local function legacyInjectorLabel(flowLps) return 'Legacy delivery system, '..math.floor(flowLps*60000+.5)..' cc/min total' end
local function legacyPumpLabel(lph) return 'Legacy pump system, '..lph..' L/h total' end
local function savedSetLabel(rate,count) return rate..' cc/min each, '..count..' injectors' end
-- Catalog ratings describe one injector. Total delivery stays internal to the model.
M.injectorFlows={650,1000,1200,1650,2150,2600,3000}
-- Combined nozzle flow per modeled cylinder/injection location, not a 3-bar single injector.
local equivalentSystems={
  {id='equiv8000',rate=8000,name='Alcohol Race Injection',note='High-flow racing injection for methanol and other supported fuels. 8,000 cc/min equivalent per cylinder; fuel conversion is separate.'},
  {id='equiv40000',rate=40000,name='Top Fuel Mechanical Injection',note='Mechanical multi-nozzle injection for extreme fuel demand. 40,000 cc/min equivalent per cylinder; fuel conversion and pump capacity are separate.'}
}
local equivalentRates={};for _,system in ipairs(equivalentSystems) do equivalentRates[system.id]=system.rate end
local legacyTotalFlows={5200,8000,13200,20800,24000,48000,96000}
local legacyBanks={1,2,4}
local historicalEach={375,800,1600,3250,7500,11250,25000}
local pumpDescriptions={ [255]='Single pump; nominal 255 L/h at 40 psi', [450]='Single pump; nominal 450 L/h at 40 psi', [470]='Single pump; published high-flow rating 470 L/h (525-series)', [900]='Two 450 L/h pumps; 900 L/h combined nominal capacity', [1350]='Three 450 L/h pumps; 1,350 L/h combined nominal capacity', [2725]='Mechanical race system; up to 12 US GPM, about 2,725 L/h', [10902]='Four 12 US GPM race delivery systems; about 10,902 L/h combined' }
-- Nominal individual ratings and authored quantities; IDs retain combined capacity.
local pumpRatings={ [255]={255,1}, [450]={450,1}, [470]={470,1}, [900]={450,2}, [1350]={450,3}, [2725]={2725,1}, [10902]={2725,4} }
M.pumpFlows={255,450,470,900,1350,2725,10902}
M.dieselOver={25,50,75,100,150,200,300}
local allInjectorFlows={3000,4500,6500,9000,12500,18000,26000,40000,60000,90000,140000,200000}
local allPumpFlows={190,255,340,450,470,650,900,1300,1350,2000,2725,3200,5000,8000,10902,12000}
local allDieselOver={25,50,75,100,150,200,250,300}
function M.migrate(s,p)
  if s.hardware then return s end
  local base=math.max(.000001,s.baseDeliveryLps or p.deliveryLps or s.deliveryLps)
  local installed=math.max(.000001,s.deliveryLps or base)
  s.hardware={injector='equipped',pump='equipped',equippedInjectorLps=base,equippedPumpLps=base,
    ownedInjectors={equipped=true},ownedPumps={equipped=true}}
  if math.abs(installed-base)>1e-9 then
    s.hardware.injector='legacy';s.hardware.pump='legacy'
    s.hardware.legacyLps=installed;s.hardware.legacyStage=s.deliveryStage or 0
    s.hardware.ownedInjectors.legacy=true;s.hardware.ownedPumps.legacy=true
  end
  s.version=5
  return s
end
local function sizes(s,p,kind,values)
  M.migrate(s,p)
  local h=s.hardware;local injector=kind=='injector'
  local base=injector and h.equippedInjectorLps or h.equippedPumpLps
  local out={}
  local owned=injector and h.ownedInjectors or h.ownedPumps
  for _,n in ipairs(values) do
    local diesel=injector and p.fuelType=='diesel'
    local id=(diesel and 'over' or injector and 'cc' or 'lph')..n
    local option={id=id,label=diesel and ('+'..n..'% over stock') or (n..(injector and ' cc/min total' or ' L/h')),
      flowLps=diesel and ((h.dieselFlows and h.dieselFlows[id]) or base*(1+n/100)) or n/(injector and 60000 or 3600),
      price=diesel and price(650+22*n) or price(injector and (450+.09*n) or (250+1.2*n)),owned=owned[id]==true or h[kind]==id}
    if not injector then
      local rating=pumpRatings[n]
      if rating then
        option.lphPerPump=rating[1];option.pumpCount=rating[2];option.assemblyNote=pumpDescriptions[n]
        option.label=(rating[2]>1 and (rating[2]..' × ') or '')..rating[1]..' L/h'
      else option.label=legacyPumpLabel(n) end
    end
    out[#out+1]=option
  end
  return out
end
local function count(p) return math.max(1,math.floor(tonumber(p.injectorCount) or 8)) end
local function individual(s,p,banks)
    M.migrate(s,p);local out={};local h=s.hardware
    for _,rate in ipairs(M.injectorFlows) do
      local id='each'..rate..(banks>1 and ('x'..banks) or '');local installed=h.injectorSets and h.injectorSets[id]
      local c=installed and installed.count or count(p)*banks
      out[#out+1]={id=id,label=rate..' cc/min each',ccPerInjector=rate,injectorCount=c,
        flowLps=installed and installed.flowLps or rate*c/60000,
        price=installed and installed.price or price(450+.09*rate*c),owned=h.ownedInjectors[id]==true or h.injector==id}
    end
    return out
end
function M.catalog(s,p,kind)
  local out=kind=='injector' and p.fuelType~='diesel' and individual(s,p,1)
    or sizes(s,p,kind,kind=='injector' and M.dieselOver or M.pumpFlows)
  local h=s.hardware
  if kind=='injector' and p.fuelType~='diesel' then
    for _,system in ipairs(equivalentSystems) do
      local installed=h.injectorSets and h.injectorSets[system.id]
      local c=installed and installed.count or count(p)
      out[#out+1]={id=system.id,label=system.name,systemName=system.name,equivalentCCPerCylinder=system.rate,injectorCount=c,
        assemblyNote=system.note,flowLps=installed and installed.flowLps or system.rate*c/60000,
        price=installed and installed.price or price(450+.09*system.rate*c),owned=h.ownedInjectors[system.id]==true or h.injector==system.id}
    end
  end
  table.insert(out,1,{id='equipped',label='As-equipped',flowLps=kind=='injector' and h.equippedInjectorLps or h.equippedPumpLps,price=0,owned=true})
  return out
end
-- Retired sizes are not new purchases. Existing ownership, flow and resale value survive.
function M.retired(s,p,kind)
  local current={};for _,o in ipairs(M.catalog(s,p,kind)) do current[o.id]=true end
  local out={};local h=s.hardware
  if h.legacyLps then out[#out+1]={id='legacy',label='Legacy-equivalent',flowLps=h.legacyLps,price=(({[1]=1450,[2]=3200,[3]=5500})[h.legacyStage or 0] or 0)*.5,owned=true} end
  local injectorTotals=copy(allInjectorFlows)
  for _,n in ipairs(legacyTotalFlows) do injectorTotals[#injectorTotals+1]=n end
  for _,o in ipairs(sizes(s,p,kind,kind=='injector' and (p.fuelType=='diesel' and allDieselOver or injectorTotals) or allPumpFlows)) do
    if kind=='injector' and p.fuelType~='diesel' then o.label=legacyInjectorLabel(o.flowLps) end
    if o.owned and not current[o.id] then out[#out+1]=o end
  end
  if kind=='injector' and p.fuelType~='diesel' then
    for id,owned in pairs(h.ownedInjectors) do
      if owned==true and id:match('^each') and not current[id] then
        local rate,banks=id:match('^each(%d+)x(%d+)$');rate=tonumber(rate or id:match('^each(%d+)$'));banks=tonumber(banks) or 1
        local set=h.injectorSets and h.injectorSets[id];local c=set and set.count or count(p)*banks
        local flow=set and set.flowLps or (rate or 0)*c/60000
        local rated=false;for _,n in ipairs(M.injectorFlows) do if rate==n then rated=true end end
        out[#out+1]={id=id,label=rated and savedSetLabel(rate,c) or legacyInjectorLabel(flow),ccPerInjector=rated and rate or nil,
          injectorCount=c,flowLps=flow,price=set and set.price or price(450+.09*flow*60000),owned=true}
      end
    end
  end
  return out
end
function M.option(s,p,kind,id)
  if kind=='injector' and p.fuelType~='diesel' and tostring(id):match('^each') then
    local banks=tonumber(tostring(id):match('x(%d+)$')) or 1
    if banks==1 or banks==2 or banks==4 then for _,o in ipairs(individual(s,p,banks)) do if o.id==id then return o end end end
  end
  -- Finish requests from an already-open total-flow panel without reinterpreting its IDs.
  if kind=='injector' and p.fuelType~='diesel' then
    for _,o in ipairs(sizes(s,p,kind,legacyTotalFlows)) do if o.id==id then o.label=legacyInjectorLabel(o.flowLps);return o end end
  end
  if kind~='injector' and kind~='pump' then return nil end
  for _,o in ipairs(M.catalog(s,p,kind)) do if o.id==id then return o end end
  for _,o in ipairs(M.retired(s,p,kind)) do if o.id==id then return o end end
end
local allowedCC,allowedLPH,allowedOver,allowedEach={},{},{},{}
for _,n in ipairs(historicalEach) do allowedEach['each'..n]=n end
for _,n in ipairs(M.injectorFlows) do for _,banks in ipairs(legacyBanks) do allowedEach['each'..n..(banks>1 and ('x'..banks) or '')]=n*banks end end
for _,n in ipairs(legacyTotalFlows) do allowedCC['cc'..n]=n/60000 end
for _,n in ipairs(allInjectorFlows) do allowedCC['cc'..n]=n/60000 end
for _,n in ipairs(allPumpFlows) do allowedLPH['lph'..n]=n/3600 end
for _,n in ipairs(allDieselOver) do allowedOver['over'..n]=1+n/100 end
function M.capacity(s,p)
  M.migrate(s,p)
  local h=s.hardware
  local function flow(id,base,injector)
    if id=='legacy' then return h.legacyLps or base end
    if id=='equipped' then return base end
    if injector and p.fuelType~='diesel' and equivalentRates[id] then local set=h.injectorSets and h.injectorSets[id];return set and set.flowLps or equivalentRates[id]*count(p)/60000 end
    if injector and allowedEach[id] then local set=h.injectorSets and h.injectorSets[id];return set and set.flowLps or allowedEach[id]*count(p)/60000 end
    if injector then return p.fuelType=='diesel' and ((h.dieselFlows and h.dieselFlows[id]) or base*(allowedOver[id] or 1)) or allowedCC[id] or base end
    return allowedLPH[id] or base
  end
  return flow(h.injector,h.equippedInjectorLps,true),flow(h.pump,h.equippedPumpLps,false)
end
function M.syncNative(s,p,fingerprint)
  M.migrate(s,p)
  local h=s.hardware
  -- Purchased diesel percentage sets are physical parts, not percentages that
  -- silently compound when a different native configuration is installed.
  if p.fuelType=='diesel' then
    h.dieselFlows=h.dieselFlows or {}
    for id in pairs(h.ownedInjectors) do
      if allowedOver[id] and not h.dieselFlows[id] then h.dieselFlows[id]=h.equippedInjectorLps*allowedOver[id] end
    end
  end
  local previous=s.nativeBaseline
  if previous and previous.version==1 and previous.fingerprint==fingerprint then return false end
  h.equippedInjectorLps=p.deliveryLps;h.equippedPumpLps=p.deliveryLps
  s.baseDeliveryLps=p.deliveryLps
  s.nativeBaseline={version=1,fingerprint=fingerprint,deliveryLps=p.deliveryLps,
    factoryBoostPsi=p.factoryBoostPsi,factorySuperchargerPsi=p.factorySuperchargerPsi}
  s.version=6
  local i,f=M.capacity(s,p);s.deliveryLps=math.min(i,f)
  return true
end
function M.install(s,p,kind,id)
  local option=M.option(s,p,kind,id)
  if not option then return false,'Unknown hardware option' end
  local h=s.hardware
  if kind=='injector' and (allowedEach[id] or equivalentRates[id]) then
    h.injectorSets=h.injectorSets or {};h.injectorSets[id]=h.injectorSets[id] or {count=option.injectorCount,flowLps=option.flowLps,price=option.price}
  end
  h[kind]=id
  h[kind=='injector' and 'ownedInjectors' or 'ownedPumps'][id]=true
  if kind=='injector' and p.fuelType=='diesel' and allowedOver[id] then
    h.dieselFlows=h.dieselFlows or {};h.dieselFlows[id]=option.flowLps
  end
  local i,f=M.capacity(s,p);s.deliveryLps=math.min(i,f)
  return true
end
function M.installedValue(s,p)
  if not s.hardware then return nil end
  local total=0
  for _,kind in ipairs({'injector','pump'}) do
    local o=M.option(s,p,kind,s.hardware[kind]);total=total+(o and o.price or 0)
  end
  return total
end
return M
