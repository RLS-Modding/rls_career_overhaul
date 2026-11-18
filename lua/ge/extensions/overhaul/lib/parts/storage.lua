-- Storage identities are resolved by the vehicle's owner, never by a client-supplied source.
local M = {}

-- ownership supplies vehicle-resolved isPersonal and, for shop storage, businessId.
function M.get(ownership, partId)
  local owner
  if ownership.isPersonal then owner = overhaul_career_parts_partInventory
  else owner = overhaul_career_business_partInventory end
  local inventory = owner and owner.getInventory()
  local part = inventory and inventory[tonumber(partId) or partId]
  if not part then return nil end
  if ownership.isPersonal then
    if part.location ~= 0 or part.enginePackageId then return nil end
  elseif tostring(part.businessId) ~= tostring(ownership.businessId) then
    return nil
  end
  return part
end

function M.personalParts(vehicleModel)
  local owner = overhaul_career_parts_partInventory
  local ownership = {isPersonal = true}
  local result = {}
  for partId, part in pairs(owner and owner.getInventory() or {}) do
    if M.get(ownership, partId) and part.vehicleModel == vehicleModel then
      local offered = deepcopy(part)
      offered.partId = partId
      result[#result + 1] = offered
    end
  end
  table.sort(result, function(first, second) return first.partId < second.partId end)
  return result
end

return M
