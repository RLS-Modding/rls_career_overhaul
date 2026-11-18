-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul ; additional permission: licenses/RLS-BeamNG-Permission.txt
-- Copyright (C) RLS Modding
-- SPDX-License-Identifier: AGPL-3.0-only

-- Physical deletion only; callers retain authority over ownership and inventory.
-- Callers: career/garage/inventory/bindings.lua (inventory removal), career/repair/damageManager.lua
-- (damage capture on removal), and logistics cleanup in vehicleTasks.lua, vehicleTasks/rewards.lua,
-- vehicleOfferManager.lua and loanerVehicles/spawn.lua.
local M = {}
local pending = {}
local MAX_DETACH_FRAMES = 120

local function connections(vehId)
  local result = {}
  for _, link in ipairs(core_vehicles and core_vehicles.attachedCouplers or {}) do
    if link[1] ~= link[2] and (link[1] == vehId or link[2] == vehId) then
      result[#result + 1] = link
    end
  end
  return result
end

-- Allocation-free check for the per-frame wait loop.
local function isConnected(vehId)
  for _, link in ipairs(core_vehicles and core_vehicles.attachedCouplers or {}) do
    if link[1] ~= link[2] and (link[1] == vehId or link[2] == vehId) then return true end
  end
  return false
end

local function queueDetach(links)
  for _, link in ipairs(links) do
    local source, target = getObjectByID(link[1]), getObjectByID(link[2])
    -- Use the initiating node, including when the retiring trailer is the child.
    -- Disarm both endpoints so auto-coupling cannot undo the detach.
    if target then target:queueLuaCommand('beamstate.disableAutoCoupling()') end
    if source then
      source:queueLuaCommand(string.format('beamstate.disableAutoCoupling(); obj:detachCoupler(%d, 0)', link[3]))
    end
  end
end

function M.delete(object)
  if not object or pending[object] then return end
  -- Ordinary uncoupled deletion keeps its synchronous path.
  if not next(core_vehicles and core_vehicles.attachedCouplers or {}) then object:delete(); return end
  local vehId = object:getID()
  local links = connections(vehId)
  if #links == 0 then object:delete(); return end

  pending[object] = true
  queueDetach(links)
  core_jobsystem.create(function()
    local detachedFrames, physicsFrames = 0, 0
    while physicsFrames < MAX_DETACH_FRAMES do
      -- A queued VE command is not a detach acknowledgement. Yield actual frames,
      -- then allow stock trailerRespawn's deferred unregister to finish as well.
      -- Its new job first starts and yields; it can run after this older job.
      local _, dt = coroutine.yield()
      -- Confirmation screens pause physics, but GE jobs keep updating. A queued
      -- physics detach must get its full budget after the player resumes.
      if not dt or dt.dtSim ~= 0 then physicsFrames = physicsFrames + 1 end
      if getObjectByID(vehId) ~= object then pending[object] = nil; return end
      if not isConnected(vehId) then
        detachedFrames = detachedFrames + 1
        if detachedFrames >= 3 then
          pending[object] = nil
          object:delete()
          return
        end
      else
        detachedFrames = 0
      end
    end
    pending[object] = nil
    -- Never fall back to the hazardous hitched delete if physics did not detach.
    log('W', 'vehicleRemoval', 'Vehicle removal cancelled: couplers did not detach for ' .. tostring(vehId))
  end)
end

return M
