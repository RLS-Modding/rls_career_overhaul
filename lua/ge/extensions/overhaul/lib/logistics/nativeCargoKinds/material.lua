-- Native material cargo uses volume slots and derives density from its mass.
-- Owns the shared descriptor builder that cash, cement, dryBulk and fluid extend.
local M = {}

function M.new(descriptor)
  descriptor.parcel, descriptor.material = false, true
  descriptor.measure = function(cargo) return cargo.slots end
  descriptor.load = function(container, cargo)
    container.volume = container.volume + (cargo.slots or 0)
    container.density = (cargo.weight and cargo.slots and cargo.slots > 0) and cargo.weight / cargo.slots or 1
  end
  descriptor.capacityLabel = function() end
  return descriptor
end

return M
