-- Native cash cargo kind: secure-capacity material delivery.
-- Owns the cash descriptor values; shared behavior comes from nativeCargoKinds/material.
local M = require("overhaul/lib/logistics/nativeCargoKinds/material").new({
  economyKey = "delivery_cash", market = "specialty", requirement = "Secure cargo capacity",
  smallSystem = "smallCashDelivery", largeSystem = "largeCashDelivery",
})
return M
