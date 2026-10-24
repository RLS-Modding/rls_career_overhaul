-- Native cement cargo kind: concrete-mixer material delivery.
-- Owns the cement descriptor values; shared behavior comes from nativeCargoKinds/material.
local M = require("overhaul/lib/logistics/nativeCargoKinds/material").new({
  economyKey = "delivery_cement", market = "specialty", requirement = "Concrete mixer",
  loadingHint = "Fit the RLS Career Concrete load part to a mixer drum, or use the company or broker concrete mixer. Standard fluid drums cannot load cement.",
  smallSystem = "smallCementDelivery", largeSystem = "largeCementDelivery",
})
return M
