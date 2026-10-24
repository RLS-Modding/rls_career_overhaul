-- Materials retain their existing cargo-dependent economy leaves.
-- Read surgeLeaf in order.

local M = {}
local LEAVES = {fluid = 'delivery_fluid', dryBulk = 'delivery_dryBulk', cement = 'delivery_cement'}

function M.surgeLeaf(cargoType) return LEAVES[cargoType] or 'delivery_fluid' end
return M
