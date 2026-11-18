-- Stable, mod-owned particle IDs. Never replace the game's BNGP_61..67.
local M = {version=2, firstId=9100, tiers=3}
M.fuels={'gasoline','diesel','methanol','nitromethane','ethanol','gasolineCore','ethanolCore','methanolCore','nitromethaneCore'}
M.offsets={gasoline=0,diesel=3,methanol=6,nitromethane=9,nitro=9,ethanol=12,
  gasolineCore=15,ethanolCore=18,methanolCore=21,nitromethaneCore=24}
-- Blend authored endpoint layers over emissions, avoiding a green RGB midpoint.
function M.blend(fuel,ethanol,phase)
  if fuel=='nitro' then fuel='nitromethane' end
  if fuel~='gasoline' then return fuel,phase or 0 end
  phase=(phase or 0)+math.max(0,math.min(1,ethanol or 0))
  if phase>=1 then return 'ethanol',phase-1 end
  return 'gasoline',phase
end
function M.id(fuel,tier)
  return M.firstId+(M.offsets[fuel] or 0)+math.max(0,math.min(2,tier-1))
end
function M.particleName(fuel,tier) return 'RLS_FuelFlame_'..fuel..'_'..tier end
return M
