-- Native dry-bulk cargo kind: bulk-capacity material delivery that needs a material unlock.
-- Owns the dry-bulk descriptor values; shared behavior comes from nativeCargoKinds/material.
local M = require("overhaul/lib/logistics/nativeCargoKinds/material").new({
  economyKey = "delivery_dryBulk", market = "bulk", requirement = "Bulk cargo capacity",
  loadingHint = "Fit Working Dump Storage (RLS) to a compatible dump bed, or use the company or broker dump truck. An empty dump load slot provides no delivery capacity.",
  smallSystem = "smallDryBulkDelivery", largeSystem = "largeDryBulkDelivery",
})
M.requiresMaterialUnlock = true
return M
