-- Closes a radial menu that is still open after the screen it belonged to has changed.
-- Only consecutive mismatched frames count, so a brief route change never closes the menu.
local M = {}
local optional = require("overhaul/lib/platform/optional")

local LOG_TAG = "radialMenuGuard"
local MISMATCH_FRAMES = 30

local mismatchFrames = 0

local function currentRouteName()
  local router = optional("ui_router")
  if not router then return nil end
  local entry = router.getCurrent()
  return entry and entry.request and entry.request.name or nil
end

local function isRadialRoute(name)
  return type(name) == "string" and (name == "radial" or name:sub(1, 7) == "radial.")
end

local function closeStuckRadial()
  if core_quickAccess.endRouteHandoff then core_quickAccess.endRouteHandoff() end
  if core_quickAccess.isEnabled() and core_quickAccess.setEnabled then core_quickAccess.setEnabled(false) end
  log("W", LOG_TAG, "Closed a radial menu that was still open after leaving its screen")
end

local function releaseStuckRadial()
  if not core_quickAccess or not core_quickAccess.isEnabled or not core_quickAccess.isEnabled() then
    mismatchFrames = 0
    return
  end
  local name = currentRouteName()
  if not name or isRadialRoute(name) then
    mismatchFrames = 0
    return
  end
  mismatchFrames = mismatchFrames + 1
  if mismatchFrames < MISMATCH_FRAMES then return end
  mismatchFrames = 0
  if core_quickAccess.isRouteHandoffActive and core_quickAccess.isRouteHandoffActive() then closeStuckRadial() end
end

M.onUpdate = releaseStuckRadial

return M
