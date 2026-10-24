-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Transient bus stop corner markers and the boarding perimeter trigger.
-- Read object creation and cleanup, corner geometry, perimeter registration and public operations.
return function()
  local stopMarkerObjects = {}
  local stopPerimeterTrigger = nil

  -- Attach transient markers to MissionGroup so level teardown owns their lifetime.
  local function createCornerMarker(markerName)
    local marker = createObject('TSStatic')
    marker:setField('shapeName', 0, "art/shapes/interface/position_marker.dae")
    marker:setPosition(vec3(0, 0, 0))
    marker.scale = vec3(1, 1, 1)
    marker:setField('rotation', 0, '1 0 0 0')
    marker.useInstanceRenderData = true
    marker:setField('instanceColor', 0, '1 1 1 1')
    marker:setField('collisionType', 0, "Collision Mesh")
    marker:setField('decalType', 0, "Collision Mesh")
    marker:setField('playAmbient', 0, "1")
    marker:setField('allowPlayerStep', 0, "1")
    marker:setField('canSave', 0, "0")
    marker:setField('canSaveDynamicFields', 0, "1")
    marker:setField('renderNormals', 0, "0")
    marker:setField('meshCulling', 0, "0")
    marker:setField('originSort', 0, "0")
    marker:setField('forceDetail', 0, "-1")
    marker.canSave = false
    marker:registerObject(markerName)
    if scenetree.MissionGroup then
      scenetree.MissionGroup:addObject(marker)
    end
    return marker
  end

  -- Remove a renamed replacement before deleting the retained marker handle.
  local function safeDelete(obj, objName)
    if not obj then
      return
    end
    local success, err = pcall(function()
      local name = obj:getName()
      local found = name and scenetree.findObject(name) or nil
      local sameObject = found and (found == obj or found:getId() == obj:getId())

      if sameObject then
        if editor and editor.onRemoveSceneTreeObjects then
          editor.onRemoveSceneTreeObjects({obj:getId()})
        end
        obj:delete()
      else
        if found then
          if editor and editor.onRemoveSceneTreeObjects then
            editor.onRemoveSceneTreeObjects({found:getId()})
          end
          found:delete()
        end
        if obj:isValid() then
          if editor and editor.onRemoveSceneTreeObjects then
            editor.onRemoveSceneTreeObjects({obj:getId()})
          end
          obj:delete()
        end
      end
    end)
    if not success and objName then
      log('D', 'bus', string.format("Error deleting %s: %s", objName, tostring(err)))
    end
  end

  -- Clear stored handles when removing transient stop objects so teardown remains repeatable.
  local function clearStopMarkers()
    for _, obj in ipairs(stopMarkerObjects) do
      safeDelete(obj, "marker")
    end
    table.clear(stopMarkerObjects)
    safeDelete(stopPerimeterTrigger, "perimeter trigger")
    stopPerimeterTrigger = nil
  end

  -- Replace the old perimeter before positioning corners and registering the new trigger.
  local function createPerimeterTrigger(trigger, uniqueId, triggerPos, stopLength, stopWidth, stopHeight, rot)
    local perimeterName = string.format("busStopPerimeter_%s_%s", trigger:getName() or "unknown", uniqueId)
    local perimeterTrigger = createObject('BeamNGTrigger')
    perimeterTrigger.loadMode = 1
    perimeterTrigger:setField("triggerType", 0, "Box")
    perimeterTrigger:setPosition(triggerPos)
    perimeterTrigger:setScale(vec3(stopLength, stopWidth, stopHeight))
    local rotTorque = rot:toTorqueQuat()
    perimeterTrigger:setField('rotation', 0,
      rotTorque.x .. ' ' .. rotTorque.y .. ' ' .. rotTorque.z .. ' ' .. rotTorque.w)
    perimeterTrigger:registerObject(perimeterName)
    stopPerimeterTrigger = perimeterTrigger

  end

  local function stopCorners(triggerPos, vecX, vecY, halfLength, halfWidth)
    local corners = {{
      pos = triggerPos - vecX * halfLength + vecY * halfWidth,
      name = "TL"
    },
    {
      pos = triggerPos + vecX * halfLength + vecY * halfWidth,
      name = "TR"
    },
    {
      pos = triggerPos + vecX * halfLength - vecY * halfWidth,
      name = "BR"
    },
    {
      pos = triggerPos - vecX * halfLength - vecY * halfWidth,
      name = "BL"
    }
    }

    return corners
  end

  local function createStopPerimeter(trigger)
    if not trigger then
      return
    end

    clearStopMarkers()

    local triggerPos = trigger:getPosition()
    local triggerRot = trigger:getRotation()
    local triggerScale = trigger:getScale()

    local stopLength = triggerScale and triggerScale.x or 15
    local stopWidth = triggerScale and triggerScale.y or 8
    local stopHeight = triggerScale and triggerScale.z or 5

    local rot = quat(triggerRot)
    local vecX = rot * vec3(1, 0, 0)
    local vecY = rot * vec3(0, 1, 0)
    local vecZ = rot * vec3(0, 0, 1)

    local halfLength = stopLength * 0.5
    local halfWidth = stopWidth * 0.5

    local corners = stopCorners(triggerPos, vecX, vecY, halfLength, halfWidth)

    local qOff = quatFromEuler(0, 0, math.pi / 2) * quatFromEuler(0, math.pi / 2, math.pi / 2)
    local rotations = {quatFromEuler(0, 0, math.rad(90)),
    quatFromEuler(0, 0, math.rad(180)),
    quatFromEuler(0, 0, math.rad(270)),
    quatFromEuler(0, 0, 0)
    }

    local uniqueId = os.time() .. "_" .. math.random(1000, 9999)
    for i, corner in ipairs(corners) do
      local markerName = string.format("busStopMarker_%s_%d_%s", trigger:getName() or "unknown", i, uniqueId)

      local hit = Engine.castRay(corner.pos + vecZ * 2, corner.pos - vecZ * 10, true, false)
      local groundPos = hit and vec3(hit.pt) or (corner.pos + vecZ * 0.05)
      groundPos = groundPos + vecZ * 0.05

      local finalRot = rotations[i] * qOff * quatFromDir(vec3(0, 0, 1), vecY)

      local marker = createCornerMarker(markerName)
      marker:setPosRot(groundPos.x, groundPos.y, groundPos.z, finalRot.x, finalRot.y, finalRot.z, finalRot.w)
      marker:setField('instanceColor', 0, "0.6 0.9 0.23 1")
      table.insert(stopMarkerObjects, marker)
    end

    createPerimeterTrigger(trigger, uniqueId, triggerPos, stopLength, stopWidth, stopHeight, rot)

    log('D', 'bus', string.format("Created perimeter markers for stop: %s (scale: %.1f x %.1f x %.1f)",
      trigger:getName() or "unknown", stopLength, stopWidth, stopHeight))
  end

  local function hideStopMarkers()
    clearStopMarkers()
  end

  return {clearStopMarkers = clearStopMarkers, createStopPerimeter = createStopPerimeter,
    hideStopMarkers = hideStopMarkers}
end
