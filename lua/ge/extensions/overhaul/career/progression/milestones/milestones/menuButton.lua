-- The legacy career menu asks for Skills only after the starter purchase; its indicator is a live query.
-- Menu-loaded by the milestones owner manifest (gameplay/overhaul/ui/owners); the function returns the button, or nil before the purchase.
local capabilities = require("overhaul/lib/platform/capabilities")

return function(career)
  if not career.hasBoughtStarterVehicle() then return nil end
  return {label = "Skills", luaFun = "extensions.ui_router.navigate('overhaul.domainSelection')",
    showIndicator = capabilities.get("progressIndicators").unclaimedMilestonesCount() > 0}
end
