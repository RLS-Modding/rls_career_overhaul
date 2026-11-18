-- Raw JBeam prices for selected config parts, before age, condition or market changes.
-- Copyright (C) RLS Modding; SPDX-License-Identifier: AGPL-3.0-only
local M = {}

function M.sum(config, priceForPart)
  local stats = {total = 0, highest = 0, count = 0}
  local function add(name)
    if type(name) ~= 'string' or name == '' then return end
    local value = tonumber(priceForPart(name))
    if not value or value ~= value or math.abs(value) == math.huge then return end
    value = math.max(0, value)
    stats.total = stats.total + value
    stats.highest = math.max(stats.highest, value)
    stats.count = stats.count + 1
  end

  local visiting = {}
  local function visit(node, depth)
    assert(type(node) == 'table' and depth <= 64 and not visiting[node], 'Invalid config parts tree')
    visiting[node] = true
    add(node.chosenPartName)
    if node.children ~= nil then
      assert(type(node.children) == 'table', 'Invalid config part children')
      for _, child in pairs(node.children) do visit(child, depth + 1) end
    end
    visiting[node] = nil
  end

  -- A tree records part instances: two wheels with the same name still cost twice.
  -- When both formats exist, the selected tree wins; never add the flat list again.
  if type(config.partsTree) == 'table' then
    visit(config.partsTree, 0)
  else
    assert(type(config.parts) == 'table', 'Config has no selected parts')
    for _, name in pairs(config.parts) do add(name) end
  end
  assert(stats.total < math.huge, 'Config part prices overflowed')
  return stats
end

return M
