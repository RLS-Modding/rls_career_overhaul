-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Activity resource: the player camera. Remembers the camera active before the first change and restores it on release.
-- Uses the calls owners make today: core_camera.setByName(0, name, ...), and resetCamera when none was remembered.
local M = {}

local function camera()
  return core_camera
end

function M.create(owner)
  local cam = {}
  local previousCamera = nil
  local changed = false

  function cam.getOwner() return owner end

  function cam.set(name, ...)
    local stockCamera = camera()
    if not changed then
      previousCamera = stockCamera.getActiveCamName(0) or nil
      changed = true
    end
    stockCamera.setByName(0, name, ...)
    return true
  end

  function cam.restore()
    if not changed then return false end
    local stockCamera = camera()
    local previous = previousCamera
    previousCamera, changed = nil, false
    if previous and previous ~= "" then
      stockCamera.setByName(0, previous, false)
    else
      stockCamera.resetCamera(0)
    end
    return true
  end

  function cam.isChanged() return changed end

  return cam
end

return M
