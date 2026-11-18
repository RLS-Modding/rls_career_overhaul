-- Presentation consumes accounted combustion energy once, on graphics ticks.
-- Stock particles/sounds and live native outlet topology; no global renderer override.
local M={}
local palette=require('common/rlsFlamePalette')
local sootPalette=require('common/rlsDieselSmokePalette')
-- Diesel soot that follows a visible flame. Tuning lives here, not in a JSON
-- manifest: this runs on graphics ticks for every lit outlet, and the soot and
-- flame palettes keep their values the same way. Level is the flame tier, 0-1.
M.dieselAfterFlame={
  -- How long soot after a flame keeps the after-flame look and speed.
  holdBaseS=.14,holdPerLevelS=.06,
  -- Soot leaves at the visible jet's speed so it doesn't lag the flame.
  jetBaseMps=3,jetPerLevelMps=2,
  -- Ordinary soot speed when no flame is lit at that outlet.
  ordinarySootMps=3,
}
local paletteReady=false
function M.setPaletteReady(ready) paletteReady=ready==true end
function M.isPaletteReady() return paletteReady end
local function clamp(x,a,b)return math.max(a,math.min(b,x))end
local function outletMotion(n,dt)
  if not ((obj.addParticle and obj.getPosition or obj.addParticleVelWidthTypeCount) and obj.getNodePosition and obj.getNodeVelocityVector) then return end
  -- Node positions share a world-oriented frame; their difference is the live
  -- pipe axis. Node velocity also includes rotation and exhaust deformation.
  local finish=obj:getNodePosition(n.finish)
  local direction=finish-obj:getNodePosition(n.start)
  local length=direction:length()
  if length<=1e-6 then return end
  local velocity=obj:getNodeVelocityVector(n.finish)
  local position
  if obj.addParticle and obj.getPosition then
    -- VE particle requests reach rendering one graphics step later. Advance
    -- only the outlet's carrier motion, using simulation time for slow motion.
    -- Bound prediction during a hitch rather than projecting a distant source.
    position=obj:getPosition()+finish+velocity*math.min(dt,.05)
  end
  return direction/length,velocity,position
end
local function emitFlame(n,speed,id,direction,velocity,position)
  if position then
    obj:addParticle(position,direction,velocity+direction*speed,id,.01,1)
  elseif direction then
    -- Supply carrier motion explicitly; inheritance only scales what is given.
    -- This native path needs positive width; 1 cm keeps emission at the pipe.
    obj:addParticleVelWidthTypeCount(n.finish,direction,velocity+direction*speed,1,.01,id,1)
  else
    obj:addParticleByNodesRelative(n.finish,n.start,-speed,id,0,1)
  end
end
function M.reset(h)
  h.exhaustSeenJ=nil;h.exhaustCreditJ=0;h.exhaustClock=0;h.exhaustSoundClock=0
  h.exhaustEvents=0;h.exhaustSounds=0;h.exhaustBurnW=0;h.exhaustSoundCreditJ=0
  h.exhaustSurgeSeen=0
  h.exhaustSurgeAge=0
  h.exhaustSoundPlayed=setmetatable({}, {__mode='k'})
  h.flameTierPhases=setmetatable({}, {__mode='k'})
  h.flameBlendPhases=setmetatable({}, {__mode='k'})
  h.flameClock=0;h.dieselFlames=setmetatable({}, {__mode='k'})
end
-- The after-flame particles travel invisibly for 0.06-0.18 seconds before soot
-- appears. Match their speed to the visible jet, retaining one soot particle
-- per pulse and the live outlet direction, including upward/side exhausts.
function M.smoke(h,node,particle)
  local flame=h and h.dieselFlames and h.dieselFlames[node]
  if flame and flame.expires>(h.flameClock or 0) and sootPalette.isOrdinarySoot(particle) then
    return sootPalette.afterFlameVariant(particle),flame.speed
  end
  return particle,M.dieselAfterFlame.ordinarySootMps
end
function M.update(h,delivery,dt)
  if not h or dt<=0 then return end
  h.flameClock=(h.flameClock or 0)+dt
  if not h.helper or not delivery or delivery.simulationVersion~=1 then h.dieselFlames=nil;return end
  local total=delivery.burnedJ or 0
  local delta=math.max(0,total-(h.exhaustSeenJ or 0));h.exhaustSeenJ=total
  local serial=delivery.surgeSerial or 0
  local newSurge=serial>(h.exhaustSurgeSeen or 0)
  h.exhaustSurgeSeen=serial
  h.exhaustSurgeAge=newSurge and 0 or (h.exhaustSurgeAge or 0)+dt
  h.exhaustClock=(h.exhaustClock or 0)+dt
  h.exhaustSoundClock=math.max(0,(h.exhaustSoundClock or 0)-dt)
  h.exhaustBurnW=delta/dt
  -- Stale telemetry cannot keep emitting; a long suspended frame cannot dump a backlog.
  if (delivery.age or 1)>.25 or dt>.25 then
    h.exhaustCreditJ=0;h.exhaustSoundCreditJ=0
    h.exhaustSurgeAge=1
    h.dieselFlames=nil
    return
  end
  h.exhaustCreditJ=math.min(20000,(h.exhaustCreditJ or 0)+delta)
  -- Consume a physics-derived surge once. No GFX-rate derivative, quiet-gap
  -- timer, or fuel-family ban; ordinary steady diesel burning stays quiet.
  local pendingSurge=serial>0 and h.exhaustSurgeAge<=.25
  h.exhaustSoundCreditJ=pendingSurge and math.min(20000,math.max(0,delivery.surgeEnergyJ or 0)) or 0
  if delta<=0 then
    if (delivery.burnW or 0)<=0 then h.exhaustCreditJ=0 end
    if not pendingSurge then return end
  end
  local nodes=h.engine.thermals and h.engine.thermals.exhaustEndNodes or {}
  local count=0;for _ in pairs(nodes) do count=count+1 end
  -- Custom methanol brightness is authored in the particle, not faked by
  -- intermittently skipping an otherwise full-bright orange burst.
  local brightness=not paletteReady and delivery.appearance=='methanol' and .2 or 1
  local quantum=paletteReady and 35 or 150
  local threshold=math.huge
  for _,n in pairs(nodes) do
    if (n.afterFireVisualCoef or 1)>0 then threshold=math.min(threshold,quantum*count/((n.afterFireVisualCoef or 1)*brightness)) end
  end
  local interval=paletteReady and 1/60 or 1/30
  local emitVisual=delta>0 and h.exhaustClock>=interval and h.exhaustCreditJ>=threshold
  if not emitVisual and not pendingSurge then return end
  local energy=emitVisual and h.exhaustCreditJ or 0
  if emitVisual then h.exhaustCreditJ=0;h.exhaustClock=h.exhaustClock%interval end
  local perOutlet=energy/math.max(1,count)
  local soundPerOutlet=h.exhaustSoundCreditJ/math.max(1,count)
  local af=h.helper.afterFire
  local audible=pendingSurge and h.exhaustSoundClock<=0
  h.exhaustSoundPlayed=h.exhaustSoundPlayed or setmetatable({}, {__mode='k'})
  local didSound=false
  local waitingSound=false
  for _,n in pairs(nodes) do
    local nativeVisual=h.nativeBaseline and h.helper.visualNodes and h.helper.visualNodes[n]
    local nativeSound=h.nativeBaseline and h.helper.soundNodes and h.helper.soundNodes[n]
    if nativeSound or (obj.inWater and obj:inWater(n.finish)) then h.exhaustSoundPlayed[n]=serial end
    if type(n.finish)=='number' and type(n.start)=='number' and not (obj.inWater and obj:inWater(n.finish)) then
      local visual=math.max(0,n.afterFireVisualCoef or 1)
      local audio=math.max(0,n.afterFireAudioCoef or 1)
      -- Fuel-specific brightness is meaningful even with the native shared palette.
      if (h.customDecel or not nativeVisual) and perOutlet*visual*brightness>=quantum and obj.addParticleByNodesRelative then
        if paletteReady then
          -- Blend adjacent authored sizes over successive emissions. Power
          -- controls size; accumulated energy gates emission. Two layers per
          -- outlet at most, no catch-up loops and no added smoke bundle.
          local level=clamp(math.sqrt(math.max(0,h.exhaustBurnW*visual/math.max(1,count))/6000),0,2)
          local lower=math.floor(level)
          h.flameTierPhases=h.flameTierPhases or setmetatable({}, {__mode='k'})
          local phase=(h.flameTierPhases[n] or 0)+level-lower
          local tier=lower+1
          if phase>=1 then tier=math.min(3,tier+1);phase=phase-1 end
          h.flameTierPhases[n]=phase
          h.flameBlendPhases=h.flameBlendPhases or setmetatable({}, {__mode='k'})
          local appearance,blendPhase=palette.blend(delivery.appearance or 'gasoline',delivery.flameEthanol,h.flameBlendPhases[n])
          h.flameBlendPhases[n]=blendPhase
          local direction,velocity,position=outletMotion(n,dt)
          local outerSpeed=(appearance=='nitromethane' and 3 or 2)+tier
          emitFlame(n,outerSpeed,palette.id(appearance,tier),direction,velocity,position)
          if appearance~='diesel' then
            -- Alcohol and nitro cores travel with the jet instead of lingering
            -- at the tip. Their authored lifetime still ends before the outer layer.
            local coreSpeed=appearance=='gasoline' and 2 or outerSpeed*.8
            emitFlame(n,coreSpeed,palette.id(appearance..'Core',tier),direction,velocity,position)
          elseif tier>1 then
            emitFlame(n,1.5,palette.id(appearance,1),direction,velocity,position)
          end
          if appearance=='diesel' then
            -- One record per outlet, updated in place: no table per flame tick.
            local tuning=M.dieselAfterFlame
            h.dieselFlames=h.dieselFlames or setmetatable({}, {__mode='k'})
            local flame=h.dieselFlames[n]
            if not flame then flame={};h.dieselFlames[n]=flame end
            flame.expires=h.flameClock+tuning.holdBaseS+tuning.holdPerLevelS*level
            flame.speed=tuning.jetBaseMps+tuning.jetPerLevelMps*level
          end
        else
          h.helper.emit(n.finish,n.start,44)
        end
        h.exhaustEvents=(h.exhaustEvents or 0)+1
      end
      if audible and h.exhaustSoundPlayed[n]~=serial and soundPerOutlet*audio>=75 and (n.afterFireVolumeCoef or 1)>0 and obj.playSFXOnceCT then
        obj:playSFXOnceCT(af.instantAudioSample,n.finish,
          (n.afterFireVolumeCoef or 1)*(af.instantVolumeCoef or 1)*clamp(soundPerOutlet*audio/3000,.1,1),
          1,1-(n.afterFireMufflingCoef or 1),0)
        h.exhaustSounds=(h.exhaustSounds or 0)+1;didSound=true
        h.exhaustSoundPlayed[n]=serial
      end
      if h.exhaustSoundPlayed[n]~=serial then waitingSound=true end
    end
  end
  if didSound then h.exhaustSoundClock=.12 end
  if not waitingSound then h.exhaustSoundCreditJ=0 end
end
return M
