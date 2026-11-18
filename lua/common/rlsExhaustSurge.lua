-- Bounded acoustic proxy from actual heat release, not exhaust pressure/CFD.
local M={}
function M.step(m,burnedJ,dt)
  if dt<=0 then return end
  local power=math.max(0,burnedJ)/dt
  m.fastW=(m.fastW or 0)+(power-(m.fastW or 0))*(1-math.exp(-dt/.015))
  m.baselineW=(m.baselineW or 0)+(power-(m.baselineW or 0))*(1-math.exp(-dt/.15))
  local excess=math.max(0,m.fastW-m.baselineW)
  local threshold=math.max(1500,m.baselineW*.5)
  -- Hysteresis prevents numerical chatter and steady burns from retriggering.
  if excess<threshold*.2 then
    m.active=false;m.sent=false;m.energyJ=0;m.time=0
  elseif excess>threshold or m.active then
    m.active=true
    m.energyJ=(m.energyJ or 0)+math.min(math.max(0,burnedJ),excess*dt)
    m.time=(m.time or 0)+dt
    if not m.sent and m.time>=.04 and m.energyJ>=75 then
      m.serial=(m.serial or 0)+1;m.eventEnergyJ=m.energyJ;m.sent=true
    end
    -- The serial is one opportunity, but quieter/multi-tip outlets may need
    -- more of this same onset before its divided energy becomes audible.
    if m.sent then m.eventEnergyJ=m.energyJ end
  end
end
return M
