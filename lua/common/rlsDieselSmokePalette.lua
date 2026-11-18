-- Presentation only: one particle per existing soot pulse. Blend neighboring
-- darkness/speed variants without changing delivered fuel or the smoke budget.
-- All tiers must share the same soot RGB; vary darkness through opacity only.
-- Separate emitter batches can swap draw order, so gray tiers over black tiers
-- would brighten particles already in the trail instead of just new exhaust.
local M={tiers=3}
-- Stable, mod-owned particle IDs: slow/moving pairs per tier, then the
-- after-flame variants of the same set.
M.firstId=9130
M.afterFlameIdOffset=6
-- Tuning lives here, not in a JSON manifest: the vehicle runtime calls select()
-- on every soot pulse, and the flame palette keeps its values the same way.
M.tuning={
  -- Stock smoke particles used before the custom soot definitions are ready.
  stockSlowParticleId=42,
  stockMovingParticleId=43,
  stockMovingSpeedMps=10,
  -- The slow-to-moving blend starts here and reaches fully moving this much faster,
  -- overlapping the old 10 m/s switch instead of jumping at it.
  speedBlendStartMps=6,
  speedBlendRangeMps=10,
}
local function clamp(x,lo,hi) return math.min(hi,math.max(lo,x)) end
function M.id(tier,fast,afterFlame)
  return M.firstId+(tier-1)*2+(fast and 1 or 0)+(afterFlame and M.afterFlameIdOffset or 0)
end
-- Ordinary (not after-flame) soot IDs, which have an after-flame variant.
function M.isOrdinarySoot(id) return id>=M.firstId and id<M.firstId+M.afterFlameIdOffset end
function M.afterFlameVariant(id) return id+M.afterFlameIdOffset end
function M.particleName(tier,fast,afterFlame)
  return 'RLS_DieselSoot_'..tier..(fast and '_moving' or '_slow')..(afterFlame and '_afterFlame' or '')
end
function M.reset(c) c.sootTierPhase=0;c.sootSpeedPhase=0 end
function M.select(c,intensity,speed,ready)
  local tuning=M.tuning
  speed=math.abs(speed or 0)
  if not ready then
    return speed<tuning.stockMovingSpeedMps and tuning.stockSlowParticleId or tuning.stockMovingParticleId
  end
  local level=1+clamp(intensity,0,1)*(M.tiers-1)
  local tier=math.floor(level)
  local phase=(c.sootTierPhase or 0)+level-tier
  if phase>=1 then tier=math.min(M.tiers,tier+1);phase=phase-1 end
  c.sootTierPhase=phase
  -- Moving particles keep the same opacity as slow ones; only dispersion/drag
  -- changes with road speed.
  phase=(c.sootSpeedPhase or 0)+clamp((speed-tuning.speedBlendStartMps)/tuning.speedBlendRangeMps,0,1)
  local fast=phase>=1
  c.sootSpeedPhase=fast and phase-1 or phase
  return M.id(tier,fast)
end
return M
