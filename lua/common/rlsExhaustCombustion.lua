-- Reduced-order exhaust chemistry, not CFD. Mass in kg, energy in J, time in s.
-- Calibrated ignition/transport rates are deliberately separate from rendering.
local M={}
local surge=require('common/rlsExhaustSurge')
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local chemistryKeys={'stoich','methanol','nitromethane','diesel','ethanol'}
function M.step(m,fuel,incoming,response,running,dt)
  local temperature=response.exhaustTemperature or 20
  local methanol=fuel.methanol or 0
  local nitro=fuel.nitromethane or 0
  local specific=fuel.energyPerL/fuel.density
  -- Cold walls retain some delivered fuel; warm walls vaporize it faster.
  local liquidShare=clamp((100-temperature)/100,0,.8)*(response.cranking and .8 or .3)
  local liquid=(m.liquidKg or 0)+incoming*liquidShare
  local liquidEnergy=(m.liquidEnergyJ or 0)+incoming*liquidShare*specific
  -- Retained fuel keeps its own chemistry after a tank/blend switch, just as
  -- it keeps its chemical energy. Each entry is mass times that property.
  local lc=m.liquidChemistry or {};m.liquidChemistry=lc
  local vc=m.vaporChemistry or {};m.vaporChemistry=vc
  for _,key in ipairs(chemistryKeys) do
    local value=key=='diesel' and (fuel.diesel and 1 or 0) or (fuel[key] or 0)
    lc[key]=(lc[key] or 0)+incoming*liquidShare*value
    vc[key]=(vc[key] or 0)+incoming*(1-liquidShare)*value
  end
  local liquidMethanol=liquid>0 and lc.methanol/liquid or methanol
  local evaporated=liquid*(1-math.exp(-dt/(.12+clamp((100-temperature)/100,0,1)*(1+liquidMethanol)*1.5)))
  local evaporationShare=liquid>0 and evaporated/liquid or 0
  for _,key in ipairs(chemistryKeys) do
    local moved=lc[key]*evaporationShare
    lc[key]=lc[key]-moved;vc[key]=vc[key]+moved
  end
  local evaporatedEnergy=liquid>0 and liquidEnergy*evaporated/liquid or 0
  m.liquidKg=liquid-evaporated;m.liquidEnergyJ=liquidEnergy-evaporatedEnergy
  local vapor=(m.vaporKg or 0)+incoming*(1-liquidShare)+evaporated
  local energy=(m.vaporEnergyJ or 0)+incoming*(1-liquidShare)*specific+evaporatedEnergy
  local stoich=vapor>0 and vc.stoich/vapor or fuel.stoich
  methanol=vapor>0 and vc.methanol/vapor or methanol
  nitro=vapor>0 and vc.nitromethane/vapor or nitro
  local diesel=vapor>0 and vc.diesel/vapor>.5 or (vapor<=0 and fuel.diesel)
  m.fuelEthanol=vapor>0 and vc.ethanol/vapor or (fuel.ethanol or 0)
  -- Air left after cylinder burning plus bounded mixing at the exhaust outlet.
  -- Fuel stoichiometry already accounts for fuel-bound oxygen (including nitro).
  local air=math.max(0,response.airMassKgPerSec or 0)
  local inCylinder=math.max(0,response.cylinderKgPerSec or 0)
  local oxygenAir=math.max(0,air-inCylinder*fuel.stoich)+air*.12
  m.mixedAirKgPerSec=math.max(oxygenAir,(m.mixedAirKgPerSec or 0)*math.exp(-dt/.15))
  oxygenAir=m.mixedAirKgPerSec
  local escapeRate=1/(response.cranking and .35 or .18)
  local oxygen=clamp(oxygenAir/math.max(1e-12,vapor*stoich*escapeRate),0,1)
  -- Diesel uses hot exhaust ignition; spark-cut/cylinder-flame assumptions do
  -- not transfer to compression ignition. These lumped activation temperatures
  -- use the manifold-temperature proxy, not diesel's autoignition temperature.
  -- Diesel's 350-450 C range is a test calibration for reachable manifold heat;
  -- delivered unburned fuel and available oxygen still limit actual burning.
  local carry=not diesel and running and clamp(response.flameCarry or 0,0,1) or 0
  local hotSurface=diesel and clamp((temperature-350)/100,0,1)
    or clamp((temperature-(480+60*methanol-40*nitro))/180,0,1)
  local ignition=math.max(carry,hotSurface)
  -- A lit pocket persists briefly, but oxygen starvation and cooling extinguish it.
  m.ignitionMemory=math.max(ignition,(m.ignitionMemory or 0)*math.exp(-dt/.08))
  local burnRate=m.ignitionMemory*oxygen*(22+nitro*12)
  local removed=vapor*(1-math.exp(-(burnRate+escapeRate)*dt))
  local burned=math.min(removed*burnRate/(burnRate+escapeRate),oxygenAir*dt/stoich)
  local lost=removed-burned
  local burnedEnergy=vapor>0 and energy*burned/vapor or 0
  m.surge=m.surge or {}
  surge.step(m.surge,burnedEnergy,dt)
  local removedEnergy=vapor>0 and energy*removed/vapor or 0
  m.vaporKg=vapor-removed;m.vaporEnergyJ=energy-removedEnergy
  local retainedShare=vapor>0 and (vapor-removed)/vapor or 0
  for _,key in ipairs(chemistryKeys) do vc[key]=vc[key]*retainedShare end
  m.reservoirKg=m.vaporKg+m.liquidKg
  m.exhaustBurnedKg=(m.exhaustBurnedKg or 0)+burned
  m.exhaustLostKg=(m.exhaustLostKg or 0)+lost
  m.exhaustBurnedJ=(m.exhaustBurnedJ or 0)+burnedEnergy
  m.burnW=burnedEnergy/dt
  m.oxygenAvailability=oxygen;m.ignitionSource=ignition
  m.fuelAppearance=diesel and 'diesel' or (nitro>.05 and 'nitro' or (methanol>.5 and 'methanol' or 'gasoline'))
  return m
end
return M
