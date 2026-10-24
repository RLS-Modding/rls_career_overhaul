-- Local map personalities take precedence; maps may name a shared source before the global default.
local M = {}
local levelData = require('overhaul/lib/world/levelData')

local function readSource(file)
  local data = file and jsonReadFile(file)
  if type(data) ~= 'table' or type(data.archetypes) ~= 'table' then return end
  -- Both roles must resolve before this source can be cached for the map.
  for _, role in ipairs({'randomBuyerArchetypes', 'randomSellerArchetypes'}) do
    local keys = data[role]
    if type(keys) ~= 'table' or #keys == 0 then return end
    for i = 1, #keys do
      local archetype = type(keys[i]) == 'string' and data.archetypes[keys[i]]
      if type(archetype) ~= 'table' or next(archetype) == nil then return end
    end
  end
  return data
end

function M.load(map)
  if not map then return nil end
  local localFile = '/levels/' .. map .. '/facilities/negotiationPersonalities.json'
  local data = readSource(localFile)
  if data then return data end

  local metadata = levelData.getMap(map)
  local source = metadata and levelData.assetPath(map, metadata.negotiationPersonalities)
  if source and source ~= localFile then
    data = readSource(source)
    if data then return data end
  end
  local defaults = jsonReadFile('/gameplay/overhaul/market/negotiation.json')
  local fallback = type(defaults) == 'table' and defaults.defaultPersonalitySource
  if type(fallback) == 'string' and fallback:sub(1, 1) == '/' and fallback ~= localFile and fallback ~= source then
    return readSource(fallback)
  end
end

return M
