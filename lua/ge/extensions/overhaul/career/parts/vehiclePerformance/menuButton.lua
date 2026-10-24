-- Pause-menu button that cancels a running certification test.
-- Menu-loaded: returns the button description, or nil when no test is in progress.
local capabilities = require("overhaul/lib/platform/capabilities")

return function()
  if not capabilities.get("certificationSession").isTestInProgress() then return nil end
  return {label = _tr("ui.career.pause.cancelCertification"),
    luaFun = "overhaul_career_parts_vehiclePerformance.cancelTest()", showIndicator = true}
end
