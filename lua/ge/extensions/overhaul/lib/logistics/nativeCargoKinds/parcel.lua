-- Parcel loads count items for POIs and mass for native containers.
-- Owns the parcel descriptor: item-count measure and mass-based container load.
local M = { parcel = true, material = false, smallSystem = "parcelDelivery" }

function M.measure() return 1 end

function M.load(container, cargo) container.volume = container.volume + (cargo.weight or 0) end

function M.capacityLabel() end

return M
