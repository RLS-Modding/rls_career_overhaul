-- Opening HUD snapshots pair the current view with its saved placement.
-- Copy settings so a queued UI event cannot retain the mutable settings table.
local M = {}

function M.build(state, layoutSetting)
  if type(state) ~= "table" then return nil end
  local settings = rawget(_G, "overhaul_shell_settings")
  local saved = settings and settings.getSetting(layoutSetting)
  local layout = {}
  if type(saved) == "table" then
    layout.x, layout.y, layout.width = saved.x, saved.y, saved.width
  end
  return { state = state, layout = layout }
end

return M
