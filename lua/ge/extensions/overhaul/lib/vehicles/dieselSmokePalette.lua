-- Register once at vehicle configuration. Never overwrite stock smoke or
-- another mod's emitter ID; failed registration retains native exhaust.
local M={}
local palette=require('common/rlsDieselSmokePalette')
local function inspect()
  local complete=true
  for tier=1,palette.tiers do
    for _,fast in ipairs({false,true}) do
      for _,afterFlame in ipairs({false,true}) do
        local expected=palette.particleName(tier,fast,afterFlame)
        local emitter=scenetree.findObject('BNGP_'..palette.id(tier,fast,afterFlame))
        if emitter and emitter:getField('particles',0)~=expected then return false,'Particle ID conflict' end
        if not emitter or not scenetree.findObject(expected) then complete=false end
      end
    end
  end
  return complete
end
local function load()
  for _,path in ipairs({'/art/rlsFuel/dieselSmoke/particles.json','/art/rlsFuel/dieselSmoke/emitters.json'}) do
    local ok=pcall(loadJsonMaterialsFile,path)
    if not ok then return false end
  end
  return inspect()
end
function M.ensure()
  if not scenetree or not loadJsonMaterialsFile then return false end
  local ready,conflict=inspect()
  if ready then return true end
  if conflict or not load() then
    log('W','rlsDieselSmokePalette',conflict or 'Custom soot definitions unavailable; native smoke retained')
    return false
  end
  return true
end
function M.reload()
  if not scenetree or not loadJsonMaterialsFile then return false end
  local _,conflict=inspect()
  if conflict or not load() then return false end
  for tier=1,palette.tiers do
    for _,fast in ipairs({false,true}) do
      for _,afterFlame in ipairs({false,true}) do
        scenetree.findObject(palette.particleName(tier,fast,afterFlame)):reload()
        scenetree.findObject('BNGP_'..palette.id(tier,fast,afterFlame)):reload()
      end
    end
  end
  return true
end
return M
