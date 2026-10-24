-- Repair operation deadlines live in gameplay/overhaul/repair/operations.json.
local M = {}
local settings

function M.get()
  if not settings then
    settings = assert(jsonReadFile('/gameplay/overhaul/repair/operations.json'), 'Missing repair operation settings')
    for _, name in ipairs({'captureTimeoutS', 'replacementTimeoutS'}) do
      local value = settings[name]
      assert(type(value) == 'number' and value > 0 and value < math.huge, 'Invalid repair deadline: ' .. name)
    end
  end
  return settings
end

return M
