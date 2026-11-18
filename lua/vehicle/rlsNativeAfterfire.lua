-- Access native definitions and observe rendering without changing its inputs.
local M={}
local function find(fn,wanted)
  if type(fn)~='function' or not debug or not debug.getupvalue then return end
  for i=1,100 do local name,value=debug.getupvalue(fn,i);if not name then return end;if name==wanted then return value end end
end
function M.inspect(engine)
  local fn=find(engine.thermals and engine.thermals.updateGFX,'updateExhaustGFXMethod')
  local emit=find(fn,'emitBigAfterFireParticles');local af=find(fn,'afterFire')
  if type(emit)~='function' or type(af)~='table' or find(fn,'parentEngine')~=engine then return nil,'Native exhaust helper unavailable' end
  return {emit=emit,afterFire=af}
end
-- Observe the fuel actually consumed by the native thermal renderer. Its
-- physics counters have different timing/units, and its cooldown can advance
-- even when no outlet qualified. Neither is evidence of a flame or sound.
function M.observe(h,engine)
  if not h or h.observer then return end
  local thermals=engine.thermals
  local instant,sustained=engine.instantAfterFireFuelDelay,engine.sustainedAfterFireFuelDelay
  if not thermals or not instant or not sustained or type(instant.popSum)~='function' or type(sustained.popSum)~='function' then return end
  local o={active=true,thermals=thermals,original=thermals.updateGFX,instant=instant,sustained=sustained,
    instantPop=instant.popSum,sustainedPop=sustained.popSum}
  h.visualNodes={};h.soundNodes={}
  o.instantWrapper=function(self,dt)
    local value=o.instantPop(self,dt)
    if o.reading then o.sampled=true;o.instantFuel=o.instantFuel+value*dt end
    return value
  end
  o.sustainedWrapper=function(self,dt)
    local value=o.sustainedPop(self,dt)
    if o.reading then o.sustainedFuel=o.sustainedFuel+value*dt end
    return value
  end
  o.wrapper=function(dt)
    if not o.active then return o.original(dt) end
    local af=h.afterFire
    o.instantFuel=af.instantAfterFireFuel or 0
    o.sustainedFuel=af.sustainedAfterFireFuel or 0
    local shift=(af.shiftAfterFireFuel or 0)+(engine.shiftAfterFireFuel or 0)
    local continuous=(engine.continuousAfterFireFuel or 0)>0
    local ready=(af.afterFireSoundTimer or 0)<=dt
    local load=engine.instantEngineLoad or 0
    o.reading=true;o.sampled=false
    o.original(dt)
    o.reading=false
    for n in pairs(h.visualNodes) do h.visualNodes[n]=nil end
    for n in pairs(h.soundNodes) do h.soundNodes[n]=nil end
    if not o.sampled then return end
    local fuel=math.max(o.instantFuel,o.sustainedFuel,shift)
    local class=fuel==shift and 'Shift' or (fuel==o.sustainedFuel and 'Sustained' or 'Instant')
    local eligible=ready and (class~='Sustained' or load<=0)
    for _,n in pairs(thermals.exhaustEndNodes or {}) do
      if not (obj and obj.inWater and obj:inWater(n.finish)) then
        h.visualNodes[n]=continuous or (eligible and fuel*(n.afterFireVisualCoef or 1)>(af['visualThreshold'..class] or math.huge))
        h.soundNodes[n]=eligible and fuel*(n.afterFireAudioCoef or 1)>(af['audibleThreshold'..class] or math.huge)
          and (n.afterFireVolumeCoef or 1)>0 and (af[class:lower()..'VolumeCoef'] or 1)>0
      end
    end
  end
  h.observer=o
  instant.popSum=o.instantWrapper;sustained.popSum=o.sustainedWrapper
  thermals.updateGFX=o.wrapper
end
function M.stopObserving(h)
  local o=h and h.observer
  if not o then return end
  o.active=false
  if o.thermals.updateGFX==o.wrapper then o.thermals.updateGFX=o.original end
  if o.instant.popSum==o.instantWrapper then o.instant.popSum=o.instantPop end
  if o.sustained.popSum==o.sustainedWrapper then o.sustained.popSum=o.sustainedPop end
  h.observer=nil;h.visualNodes=nil;h.soundNodes=nil
end
return M
