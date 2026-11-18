-- Paid combustion owns presentation for the fuel runtime. The older coefficient
-- adapter remains a compatibility path for callers without physical delivery.
local M={}
local native=require('vehicle/rlsNativeAfterfire')
local presentation=require('vehicle/rlsExhaustPresentation')
local model=require('common/rlsFuelModel')
local classes={'Instant','Sustained','Shift'}
local coefficientKeys={'instantAfterFireCoef','sustainedAfterFireCoef'}
local function clamp(n,a,b)return math.max(a,math.min(b,n))end
local function restore(record)
  for key,value in pairs(record.applied) do
    if record.target[key]==value then record.target[key]=record.original[key] end
    record.applied[key]=nil
  end
end
local function record(target)return {target=target,original={},applied={}}end
local function set(r,key,value)
  if r.applied[key]==nil then r.original[key]=r.target[key] end
  r.target[key]=value;r.applied[key]=value
end
function M.new(engine)
  local helper,why=native.inspect(engine)
  if helper then
    for _,class in ipairs({'instant','sustained','shift'}) do
      if type(helper.afterFire[class..'AudioSample'])~='string' or helper.afterFire[class..'AudioSample']=='' then
        helper=nil;why='Native afterfire sound definitions unavailable; original effects retained.';break
      end
    end
    if helper then
      for _,class in ipairs(classes) do
        local a,b=helper.afterFire['audibleThreshold'..class],helper.afterFire['visualThreshold'..class]
        if type(a)~='number' or type(b)~='number' or a~=a or b~=b or a<=0 or b<=0 or a==math.huge or b==math.huge then
          helper=nil;why='Native afterfire threshold controls unavailable; original effects retained.';break
        end
      end
    end
  end
  return {engine=engine,helper=helper,warning=why,engineFields=record(engine),nodes={},present={},
    soundFields=helper and record(helper.afterFire),points=0,burstPoints=0,sustainedPoints=0}
end
function M.restore(h)
  if not h then return end
  native.stopObserving(h.helper)
  restore(h.engineFields)
  for _,r in pairs(h.nodes) do restore(r) end
  if h.soundFields then restore(h.soundFields) end
  if h.timerOwned then
    h.engine.sustainedAfterFireTimer=math.min(h.engine.sustainedAfterFireTimer or 0,h.nativeTimer or 0)
    h.timerOwned=nil
  end
  h.points,h.burstPoints,h.sustainedPoints=0,0,0
  if h.physical then presentation.reset(h);h.physical=nil end
  h.nativeBaseline=nil
  h.customDecel=nil
end
function M.update(h,decel,delivery,response,dt)
  if not h then return end
  local e=h.engine
  -- Restore before computing every adjustment: repeated frames never compound.
  restore(h.engineFields)
  for _,r in pairs(h.nodes) do restore(r) end
  if h.soundFields then restore(h.soundFields) end
  if h.helper and delivery and delivery.simulationVersion==1 then
    h.physical=true
    -- Custom decel adds paid fuel; it never revokes the vehicle's native tune.
    -- Ignore the legacy allowStockAfterfire switch on this physical path.
    h.nativeBaseline=true
    h.customDecel=decel and decel.mode=='custom' and decel.enabled~=false or false
    local reference=model.referenceLambda(response.load or 0)
    local scale=clamp(1+(reference-(response.lambda or reference))*2-(response.effectiveTiming or 0)*.015,0,3)
    for _,key in ipairs(coefficientKeys) do
      if type(e[key])=='number' then set(h.engineFields,key,e[key]*scale) end
    end
    native.observe(h.helper,e)
    h.points,h.burstPoints,h.sustainedPoints=0,0,0
    return
  end
  if h.timerOwned then
    h.nativeTimer=math.max(0,(h.nativeTimer or 0)-dt)
    if (e.instantEngineLoad or 0)>0 then h.nativeTimer=e.sustainedAfterFireTime or 0 end
  end
  local running=e.requiredEnergyType~='diesel' and not e.isDisabled and not e.isStalled and e.hasFuel~=false
    and (e.ignitionCoef or 1)>0 and (e.outputAV1 or 0)>1
  local thermals=e.thermals or {}
  -- Native temperature is a lumped exhaust value; stock low-output engines
  -- can settle near 300 C at full load. Let the effect slider reach its stated
  -- additive range there while keeping cold exhaust and unpaid fuel gated.
  -- This is effect sensitivity, separate from the conserved combustion heat.
  local hot=clamp(((thermals.exhaustTemperature or 20)-220)/80,0,1)
  local active=h.helper and decel and decel.mode=='custom' and decel.enabled~=false and running
    and (thermals.engineBlockTemperature or 20)>45 and hot>0
  local fresh=delivery and (delivery.age or math.huge)<.25
  local points=active and clamp((decel.fueling or 0)*(1+(decel.retard or 0)/20),0,4)*hot or 0
  local burst=points*(fresh and (delivery.chargedLps or 0)>1e-12 and clamp(1/math.max(1,response.deliveryDuty or 1),0,1) or 0)
  local overrun=(e.requestedThrottle or e.throttle or 0)<.02 and (e.instantEngineLoad or 0)<=0
  local extraDemand=delivery and delivery.extraDemandLps or 0
  local sustained=points*(overrun and fresh and extraDemand>1e-12 and
    clamp((delivery.extraLps or 0)/extraDemand,0,1) or 0)
  -- Closed-throttle outlet additions require paid extra fuel. Otherwise a
  -- leftover native sustained signal could be amplified after the cut delay.
  h.points,h.burstPoints,h.sustainedPoints=overrun and sustained or burst,burst,sustained
  if h.points<=0 then
    if h.timerOwned then e.sustainedAfterFireTimer=math.min(e.sustainedAfterFireTimer or 0,h.nativeTimer or 0);h.timerOwned=nil end
    return
  end
  set(h.engineFields,'instantAfterFireCoef',(e.instantAfterFireCoef or 0)+burst)
  set(h.engineFields,'sustainedAfterFireCoef',(e.sustainedAfterFireCoef or 0)+sustained)
  if sustained>0 then
    if not h.timerOwned then h.nativeTimer=e.sustainedAfterFireTimer or 0;h.timerOwned=true end
    -- Actual paid overrun injection controls duration. Never use the native
    -- continuousAfterFireFuel shortcut: that branch emits flames silently.
    e.sustainedAfterFireTimer=math.max(e.sustainedAfterFireTimer or 0,dt*2)
  end
  local af=h.helper.afterFire
  local ratio=1
  for _,class in ipairs(classes) do
    ratio=math.max(ratio,(af['audibleThreshold'..class] or 0)/math.max(1,af['visualThreshold'..class] or 1))
    local key=class:lower()..'VolumeCoef'
    if (af[key] or 0)<=0 then set(h.soundFields,key,.25) end
  end
  local present=h.present
  for node in pairs(present) do present[node]=nil end
  for _,n in pairs(thermals.exhaustEndNodes or {}) do
    present[n]=true;local r=h.nodes[n] or record(n);h.nodes[n]=r
    local visual=(n.afterFireVisualCoef or 1)+h.points
    set(r,'afterFireVisualCoef',visual)
    set(r,'afterFireAudioCoef',math.max((n.afterFireAudioCoef or 1)+h.points,visual*ratio))
    -- Keep positive native volume and muffling. A suppressed stock exhaust
    -- gets a modest allowance, rather than the volume of a race exhaust.
    if (n.afterFireVolumeCoef or 1)<=0 then set(r,'afterFireVolumeCoef',.08+.04*h.points) end
  end
  for n in pairs(h.nodes) do if not present[n] then h.nodes[n]=nil end end
end
function M.status(h)
  return {supported=h and h.helper~=nil or false,warning=h and h.warning,
    points=h and h.points or 0,burstPoints=h and h.burstPoints or 0,sustainedPoints=h and h.sustainedPoints or 0,
    mode=h and h.physical and (h.nativeBaseline and 'native+combustion' or 'combustion') or 'native',burnW=h and h.exhaustBurnW or 0,
    flameEvents=h and h.exhaustEvents or 0,soundEvents=h and h.exhaustSounds or 0,
    palette=presentation.isPaletteReady() and 'rls' or 'native',fuelColorsSupported=presentation.isPaletteReady()}
end
M.updateGFX=presentation.update
M.smoke=presentation.smoke
M.setPaletteReady=presentation.setPaletteReady
return M
