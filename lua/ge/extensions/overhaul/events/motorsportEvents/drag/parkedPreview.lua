-- Owns decorative vehicle preview data.
-- drag/parking.lua owns active paddock vehicles; art/shapes/motorsport contains the separate static display assets.
local M = {}
local configs

function M.forEntrant(entrant)
  if entrant.parkedModel and entrant.parkedConfig then return entrant.parkedModel, entrant.parkedConfig end
  if not configs then
    configs = {}
    for key, config in pairs(core_vehicles.getModel('simple_traffic').configs or {}) do
      if config.Type == 'PropParked' then configs[#configs + 1] = key end
    end
    table.sort(configs)
  end
  local prefix = entrant.model .. '_'
  for _, key in ipairs(configs) do
    if key:sub(1, #prefix) == prefix then return 'simple_traffic', key end
  end
  return 'simple_traffic', 'fullsize_stock_parked'
end

return M
