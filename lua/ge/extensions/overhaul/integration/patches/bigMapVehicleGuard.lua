-- Unblocks vehicle input when the big map pops its pause request, so closing the map never leaves controls locked.
-- Installed through the shell patch registry; the wrapper only changes the pause call it sees.
local M = {}
M.dependencies = {"overhaul_shell_patches"}

local PATCH_ID = "bigMapVehicleGuard"

local function unblockBigMapVehicleInput()
  core_input_actionFilter.addAction(0, "bigmapBlockedActions", false)
end

local function wrapPopPauseRequest(original)
  if type(original) ~= "function" then return end
  return function(id, ...)
    if id == "bigMap" then unblockBigMapVehicleInput() end
    return original(id, ...)
  end
end

function M.onExtensionLoaded()
  overhaul_shell_patches.registerFields(PATCH_ID, function() return rawget(_G, "simTimeAuthority") end, {
    popPauseRequest = wrapPopPauseRequest,
  })
end

function M.onExtensionUnloaded()
  if overhaul_shell_patches then overhaul_shell_patches.unregister(PATCH_ID) end
end

return M
