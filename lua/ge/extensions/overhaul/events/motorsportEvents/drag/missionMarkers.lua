-- Owns event-specific native mission-marker integration.
-- motorsportEvents.lua calls init/shutdown; venueInteractions.lua supplies the event interaction POIs.
local M = {}
local registered

function M.init()
  if registered then return end
  local patches = overhaul_shell_patches
  patches.registerFields('motorsportStagePoi', function() return gameplay_drag_poi end, {
    createStagePoi = function(original)
      if type(original) ~= 'function' then return end
      return function(...)
        local poi = original(...)
        local trigger = poi and poi.markerInfo and poi.markerInfo.invisibleTrigger
        if trigger and trigger.onInside then
          local onInside = trigger.onInside
          trigger.onInside = function(...)
            if overhaul_events_motorsportEvents and overhaul_events_motorsportEvents.isDragDispatchActive() then return end
            return onInside(...)
          end
        end
        return poi
      end
    end
  })
  patches.registerFields('motorsportMissionVisibility', function() return gameplay_missions_unlocks end, {
    isMissionVisible = function(original)
      if type(original) ~= 'function' then return end
      return function(mission)
        if overhaul_career_career and overhaul_career_career.isActive() and mission.missionType == 'dragStripRace' then return false end
        return original(mission)
      end
    end,
  })
  patches.registerFields('motorsportTuningMarker', function() return overhaul_world_facilities end, {
    walkingMarkerFormatFacility = function(original)
      if type(original) ~= 'function' then return end
      return function(facility, elements)
        local first = #elements + 1
        original(facility, elements)
        if not facility.inspectMarker then return end
        for index = first, #elements do
          local markers = elements[index].markerInfo
          local walking = markers and markers.walkingMarker
          if walking then
            markers.walkingMarker = nil
            markers.inspectVehicleMarker = {pos = walking.pos, radius = 4, icon = facility.icon,
              focus = facility.inspectMarkerFocus ~= false}
          end
        end
      end
    end,
  })
  registered = true
  gameplay_rawPois.clear()
end

function M.shutdown()
  if not registered then return end
  for _, id in ipairs({'motorsportStagePoi', 'motorsportMissionVisibility', 'motorsportTuningMarker'}) do
    overhaul_shell_patches.unregister(id)
  end
  registered = nil
  gameplay_rawPois.clear()
end

return M
