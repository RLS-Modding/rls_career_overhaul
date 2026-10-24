-- Condition compatibility: an empty subsystem integrity state is dropped so the numeric integrity applies instead.
-- Vehicle conditions keep their numeric integrity when no subsystem reports any detail.

local M = {}

-- True when any subsystem entry carries real data; an empty table or nothing at all does not count.
local function hasIntegrityDetail(integrityState)
  for _, value in pairs(integrityState) do
    if type(value) ~= "table" or next(value) then return true end
  end
  return false
end

function M.normalizeEmptyIntegrityStates(conditions)
  for _, condition in pairs(type(conditions) == "table" and conditions or {}) do
    local integrityState = type(condition) == "table" and condition.integrityState
    if type(integrityState) == "table" and not hasIntegrityDetail(integrityState) then
      condition.integrityState = nil
    end
  end
  return conditions
end

return M
