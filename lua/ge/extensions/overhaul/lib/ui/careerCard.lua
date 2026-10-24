-- Pause summaries are contributed by their live owners. No optional feature is loaded by opening pause.
local manifests = require('overhaul/lib/platform/manifests')
local optional = require('overhaul/lib/platform/optional')
local M = {dir = '/gameplay/overhaul/ui/careerCard/'}

local function validate(data)
  if type(data.owner) ~= 'string' or not data.owner:match('^[%w_]+$') then return nil, 'invalid owner' end
  if type(data.method) ~= 'string' or not data.method:match('^[%w_]+$') then return nil, 'invalid method' end
  return data
end

function M.getData()
  local mode = optional('overhaul_shell_gameMode')
  if not mode or not mode.isActive() then return nil end
  local result = {sections = {}}
  for _, declaration in ipairs(manifests.scan({dir = M.dir, validate = validate})) do
    local owner = optional(declaration.owner)
    if owner and type(owner[declaration.method]) == 'function' then
      local ok, section = pcall(owner[declaration.method])
      if ok and type(section) == 'table' then
        local copy = {}
        for key, value in pairs(section) do copy[key] = value end
        copy.id = declaration.id
        result.sections[#result.sections + 1] = copy
      elseif not ok and type(log) == 'function' then
        log('W', 'overhaul_careerCard', declaration.id .. ': ' .. tostring(section))
      end
    end
  end
  return result
end

return M
