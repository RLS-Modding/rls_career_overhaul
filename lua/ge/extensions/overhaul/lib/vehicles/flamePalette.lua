-- Called at vehicle configuration, not in a frame loop. The stock textures are
-- runtime dependencies; our definitions/IDs are separate from vanilla effects.
local M={}
local palette=require('common/rlsFlamePalette')
local function inspect()
  local complete=true
  for _,fuel in ipairs(palette.fuels) do
    for tier=1,palette.tiers do
      local expected=palette.particleName(fuel,tier)
      local emitter=scenetree.findObject('BNGP_'..palette.id(fuel,tier))
      local particle=scenetree.findObject(expected)
      if emitter and emitter:getField('particles',0)~=expected then return false,'Particle ID conflict' end
      if not emitter or not particle then complete=false end
    end
  end
  return complete
end
function M.ensure()
  if not scenetree or not loadJsonMaterialsFile then return false end
  local ready,conflict=inspect()
  if ready then return true end
  if conflict then log('W','rlsFlamePalette',conflict..'; native palette retained');return false end
  loadJsonMaterialsFile('art/rlsFuel/flames/particles.json')
  loadJsonMaterialsFile('art/rlsFuel/flames/emitters.json')
  ready=inspect()
  if not ready then log('W','rlsFlamePalette','Custom flame definitions unavailable; native palette retained') end
  return ready
end
-- Explicit development reload: refresh GPU resources as well as JSON fields.
-- The editor uses the same datablock reload calls. Never run this per vehicle.
function M.reload()
  if not scenetree or not loadJsonMaterialsFile then return false end
  local _,conflict=inspect()
  if conflict then return false end
  loadJsonMaterialsFile('art/rlsFuel/flames/particles.json')
  loadJsonMaterialsFile('art/rlsFuel/flames/emitters.json')
  if not inspect() then return false end
  for _,fuel in ipairs(palette.fuels) do
    for tier=1,palette.tiers do
      scenetree.findObject(palette.particleName(fuel,tier)):reload()
      scenetree.findObject('BNGP_'..palette.id(fuel,tier)):reload()
    end
  end
  return true
end
return M
