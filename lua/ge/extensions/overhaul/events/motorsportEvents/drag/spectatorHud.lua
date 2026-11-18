-- Owns spectator HUD visibility and restoration.
-- drag/spectator.lua toggles this state; MotorsportSpectatorOverlay.vue draws the controls. The Event display is an
-- Overhaul overlay outside the stock app containers, so every stock app can hide while it docks to the right.
local M = {}
local eventDisplay = require('overhaul/events/motorsportEvents/drag/eventDisplay')
local saved

function M.update(watching)
  eventDisplay.setDock(watching and 'right' or 'left')
  if watching and ui_apps_minimap_minimap and ui_apps_minimap_minimap.onUpdate then ui_apps_minimap_minimap.hide() end
  if not ui_appContainers then return end
  if watching then
    saved = saved or ui_appContainers.onSerialize()
    for container, apps in pairs(ui_appContainers.onSerialize()) do
      for app, visible in pairs(apps) do
        if visible then ui_appContainers.setAppVisibility(container, app, false) end
      end
    end
  elseif saved then
    local current = ui_appContainers.onSerialize()
    for container, apps in pairs(saved) do
      for app, visible in pairs(apps) do
        if current[container] and current[container][app] ~= nil then ui_appContainers.setAppVisibility(container, app, visible) end
      end
    end
    saved = nil
  end
end

return M
