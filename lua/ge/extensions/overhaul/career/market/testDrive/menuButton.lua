-- Test-drive cancellation follows certification in the legacy menu and queries the current session.
-- Menu-loaded file: returns the button row, or nil when no test drive is running; testDrive.lua owns the session.
local capabilities = require("overhaul/lib/platform/capabilities")

return function()
  if not capabilities.get("testDriveSession").isActive() then return nil end
  return {label = _tr("ui.career.pause.cancelTestDrive"),
    luaFun = "overhaul_career_market_testDrive.stop()", showIndicator = true}
end
