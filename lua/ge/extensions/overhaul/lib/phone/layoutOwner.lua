-- Shared access to the phone layout extension for features that post phone notifications.
-- The layout owns the player's notification settings, so callers route through it instead of firing toasts directly.
local M = {}

local LAYOUT_EXTENSION = "overhaul_phone_apps_layout"

-- Loads the layout on first use; returns nil when the phone is unavailable (e.g. outside a career).
function M.get()
  if not overhaul_phone_apps_layout then
    pcall(extensions.load, LAYOUT_EXTENSION)
  end
  return overhaul_phone_apps_layout
end

return M
