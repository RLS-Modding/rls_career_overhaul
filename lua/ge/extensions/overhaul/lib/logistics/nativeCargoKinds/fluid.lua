-- Native fluid cargo kind: liquid-capacity material delivery that needs a material unlock.
-- Owns the fluid descriptor values and the litre capacity label; the rest comes from nativeCargoKinds/material.
local M = require("overhaul/lib/logistics/nativeCargoKinds/material").new({
  economyKey = "delivery_fluid", market = "liquids", requirement = "Liquid cargo capacity",
  smallSystem = "smallFluidDelivery", largeSystem = "largeFluidDelivery",
})

M.requiresMaterialUnlock = true
function M.capacityLabel(cap, icon, translate)
  return {
    icon = icon(cap.type), labelShort = string.format("%dL", cap.amount),
    labelLong = translate("ui.career.loaner.capacity.fluidsLong", { liters = cap.amount }),
  }
end

return M
