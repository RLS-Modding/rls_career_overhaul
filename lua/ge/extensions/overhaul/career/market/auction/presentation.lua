-- Auction presentation: entry and exit trigger visibility, overlay UI, faded transitions, sounds, win
-- emitters and active scene assets, and returning or despawning lot vehicles.
local constants = require('overhaul/career/market/auction/constants')
local optional = require('overhaul/lib/platform/optional')

local presentation = {}

function presentation.create(deps)
  local api = {}
  local auctionState = deps.auctionState
  local pendingFreezeTokens = deps.pendingFreezeTokens
  local pendingTransitCallbacks = deps.pendingTransitCallbacks

  -- Triggers and overlay --------------------------------------------------------------------------
  local function setTriggerHidden(triggerName, hidden)
    local trigger = triggerName and scenetree.findObject(triggerName)
    if trigger then
      trigger:setHidden(hidden and true or false)
    end
  end

  function api.setIdleTriggerState()
    for _, facility in ipairs(deps.site.facilities()) do
      setTriggerHidden(facility.entryTrigger, false)
      setTriggerHidden(facility.exitTrigger, true)
    end
  end

  function api.setAuctionRunningTriggerState()
    local facility = deps.site.getBinding()
    if not facility then return end
    setTriggerHidden(facility.entryTrigger, true)
    setTriggerHidden(facility.exitTrigger, false)
  end

  function api.openMenu()
    if auctionState.uiOpen then
      return
    end
    auctionState.uiOpen = true
    if extensions.overhaul_phone_musicPlayer and extensions.overhaul_phone_musicPlayer.loadMusicLibrary then
      extensions.overhaul_phone_musicPlayer.loadMusicLibrary('/music', nil, true)
    end
    extensions.ui_router.navigate('used-car-auction')
  end

  function api.closeCounterOverlayUi()
    guihooks.trigger('UsedAuctionCounterHide')
  end

  function api.closeAuctionOverlayUi()
    local wasOpen = auctionState.uiOpen
    auctionState.uiOpen = false
    api.closeCounterOverlayUi()
    guihooks.trigger('UsedAuctionHide')
    local player = wasOpen and optional('overhaul_phone_musicPlayer')
    if player then player.uiStop() end
    if wasOpen then extensions.ui_router.navigate('play') end
  end

  -- Faded transitions and sounds ------------------------------------------------------------------
  local function startFadeSafe()
    ui_fadeScreen.start(constants.FADE_DURATION_S)
  end

  local function stopFadeSafe()
    ui_fadeScreen.stop(constants.FADE_DURATION_S)
  end

  function api.exitAuctionEntryLoadingScreen()
    if not core_gamestate.getLoadingStatus(constants.AUCTION_ENTRY_LOADING_TAG) then
      return
    end
    core_gamestate.requestExitLoadingScreen(constants.AUCTION_ENTRY_LOADING_TAG)
  end

  function api.runFadedTransition(workFn)
    if auctionState.transitionActive then
      return
    end

    auctionState.transitionActive = true
    core_jobsystem.create(function(job)
      startFadeSafe()
      job.sleep(constants.FADE_DURATION_S)

      local ok, err = pcall(workFn)

      stopFadeSafe()
      api.exitAuctionEntryLoadingScreen()
      auctionState.transitionActive = false

      if not ok then
        log('E', 'usedCarAuction', 'Transition failed: ' .. tostring(err))
      end
    end)
  end

  function api.deleteVehicleSafe(vehId)
    if not vehId then return end
    pendingTransitCallbacks[vehId] = nil
    pendingFreezeTokens[vehId] = nil
    -- Traffic is per-level; vehicle cleanup also runs after its teardown.
    if gameplay_traffic then gameplay_traffic.removeTraffic(vehId) end
    local veh = getObjectByID(vehId)
    if veh then
      veh:delete()
    end
  end

  function api.playUiSound(eventName)
    if not eventName or eventName == '' then return end
    Engine.Audio.playOnce('AudioGui', eventName)
  end

  function api.playBidAcceptedSound()
    api.playUiSound(constants.BID_ACCEPTED_SFX_EVENT)
  end

  function api.playLotWinCelebrationSound()
    api.playUiSound(constants.LOT_WIN_CELEBRATION_SFX_EVENT)
  end

  -- Scene emitters and assets ---------------------------------------------------------------------
  local function resolveSceneRefToObject(ref)
    local refType = type(ref)
    if refType == 'userdata' then return ref end
    if refType == 'number' then return scenetree.findObjectById(ref) end
    if refType == 'string' then return scenetree.findObject(ref) end
    return nil
  end

  -- Asset groups mix scene classes; only supported methods and call signatures are used.
  local function listChildrenSafe(obj)
    if not obj or not obj.getObjects then
      return {}
    end

    local refs = obj:getObjects()
    if type(refs) ~= 'table' then
      return {}
    end

    local out = {}
    for _, ref in ipairs(refs) do
      local child = resolveSceneRefToObject(ref)
      if child then
        table.insert(out, child)
      end
    end
    return out
  end

  local function setEmitterObjectEnabled(obj, enabled)
    if not obj then return end
    local boolEnabled = enabled and true or false
    local numericEnabled = boolEnabled and 1 or 0
    local textEnabled = boolEnabled and '1' or '0'

    if obj.setEnabled then
      obj:setEnabled(boolEnabled)
    end
    if obj.setActive then
      obj:setActive(numericEnabled)
    end
    if obj.setField then
      obj:setField('enabled', 0, textEnabled)
      obj:setField('active', 0, textEnabled)
      obj:setField('isEnabled', 0, textEnabled)
    end
    if obj.setHidden then
      obj:setHidden(not boolEnabled)
    end
  end

  local function getSceneObjectName(obj)
    if not obj or not obj.getName then
      return nil
    end
    return obj:getName()
  end

  local function setAuctionActiveAssetObjectEnabled(obj, enabled, musicEnabled)
    if not obj then return end

    local objName = getSceneObjectName(obj)
    local isAuctionMusicEmitter = objName == ((deps.site.getBinding() or {}).presentation or {}).musicEmitter
    local effectiveEnabled = enabled and true or false
    if isAuctionMusicEmitter and (not musicEnabled) then
      effectiveEnabled = false
    end

    setEmitterObjectEnabled(obj, effectiveEnabled)

    -- Scene asset classes expose both no-argument and indexed playback bindings.
    if effectiveEnabled and obj.play and not isAuctionMusicEmitter then
      local played = pcall(function() obj:play() end)
      if not played then
        pcall(function() obj:play(-1) end)
      end
    elseif (not effectiveEnabled) and obj.stop then
      local stopped = pcall(function() obj:stop() end)
      if not stopped then
        pcall(function() obj:stop(-1) end)
      end
    end
  end

  -- Heavy interiors are scene-authored data until a visit starts. Stable names make
  -- repeated activation (music changes) and Lua reload idempotent. Once loaded,
  -- the building belongs to the level, not the visit: leaving must keep it visible.
  local function ensureDeferredStatics(root)
    local encoded = root.getField and root:getField('deferredStatics', '')
    if type(encoded) ~= 'string' or encoded == '' then return false end
    local changed = false
    for index, definition in ipairs(jsonDecode(encoded)) do
      local name = root:getName() .. '_interior_' .. index
      local existing = scenetree.findObject(name)
      if not existing then
        local obj = createObject('TSStatic')
        local ok, err = pcall(function()
          for key, value in pairs(definition.fields) do
            obj:setField(key, 0, tostring(value))
          end
          local transform = MatrixF(true)
          local rotation = definition.rotationMatrix or {1, 0, 0, 0, 1, 0, 0, 0, 1}
          for axis = 0, 2 do
            local offset = axis * 3
            transform:setColumn(axis, vec3(rotation[offset + 1], rotation[offset + 2], rotation[offset + 3]))
          end
          transform:setColumn(3, vec3(unpack(definition.position)))
          obj:setTransform(transform)
          obj:setScale(vec3(unpack(definition.scale or {1, 1, 1})))
          obj:setCanSave(false)
          if obj:registerObject(name) == false then error('Cannot register ' .. name) end
          -- Authored instances disable ordinary rendering; new runtime statics need it.
          obj:setRenderEnabled(true)
          -- Keep geometry outside the emitter group so audio toggles never alter it.
          root:getGroup():addObject(obj)
        end)
        if not ok then
          obj:delete()
          error(err, 0)
        end
        changed = true
      end
    end
    return changed
  end

  -- Applies applyToObject to a scene group and every object under it, each object once.
  local function applyToSceneGroup(groupName, applyToObject, prepareGroup)
    local root = groupName and scenetree.findObject(groupName)
    if not root then
      return false
    end

    if prepareGroup then prepareGroup(root) end

    local visited = {}
    local function applyRecursive(obj)
      if not obj then return end
      local id = obj.getID and obj:getID() or tostring(obj)
      if visited[id] then return end
      visited[id] = true

      applyToObject(obj)
      for _, child in ipairs(listChildrenSafe(obj)) do
        applyRecursive(child)
      end
    end

    applyRecursive(root)
    return true
  end

  local function applyPresentationGroup(key, enabled, apply, prepareGroup)
    local facility = deps.site.getBinding()
    local facilities = facility and {facility} or (not enabled and deps.site.facilities() or {})
    local found = false
    for _, record in ipairs(facilities) do
      found = applyToSceneGroup((record.presentation or {})[key], apply, prepareGroup) or found
    end
    return found
  end

  function api.setAuctionWinEmittersEnabled(enabled)
    return applyPresentationGroup('winEmittersGroup', enabled, function(obj)
      setEmitterObjectEnabled(obj, enabled)
    end)
  end

  function api.setAuctionActiveAssetsEnabled(enabled)
    local musicEnabled = auctionState.musicEnabled ~= false
    local geometryChanged = false
    local found = applyPresentationGroup('activeAssetsGroup', enabled, function(obj)
      setAuctionActiveAssetObjectEnabled(obj, enabled, musicEnabled)
    end, function(root)
      if enabled then geometryChanged = ensureDeferredStatics(root) or geometryChanged end
    end)
    -- New level geometry must enter the physics world before player placement.
    if geometryChanged then be:reloadCollision() end
    return found
  end

  function api.hardDisableAuctionAudioVisuals()
    api.setAuctionWinEmittersEnabled(false)
    api.setAuctionActiveAssetsEnabled(false)
    if deps.site.getBinding() then
      deps.site.clearAuctionExitMarker()
      deps.site.clearAuctionCounterMarker()
    else
      for _, facility in ipairs(deps.site.facilities()) do
        deps.site.selectFacility(facility)
        deps.site.clearAuctionExitMarker()
        deps.site.clearAuctionCounterMarker()
      end
      deps.site.clearSelection()
    end
  end

  function api.triggerAuctionWinEmitters(duration)
    local pulseDuration = tonumber(duration) or constants.LOT_WIN_EMITTER_DURATION_S
    if pulseDuration <= 0 then return end

    auctionState.winEmitterPulseToken = (auctionState.winEmitterPulseToken or 0) + 1
    local token = auctionState.winEmitterPulseToken

    api.setAuctionWinEmittersEnabled(true)
    core_jobsystem.create(function(job)
      job.sleep(pulseDuration)
      if token ~= (auctionState.winEmitterPulseToken or 0) then
        return
      end
      api.setAuctionWinEmittersEnabled(false)
    end)
  end

  -- Lot vehicle placement -------------------------------------------------------------------------
  local function isSpotFree(spot)
    if not spot then return false end
    if spot.vehicle then return false end
    if spot.hasAnyVehicles then
      if spot:hasAnyVehicles() then
        return false
      end
    end
    return true
  end

  function api.removeSpotFromList(spots, spotToRemove)
    if not spots or not spotToRemove then return false end
    for i, spot in ipairs(spots) do
      if spot == spotToRemove then
        table.remove(spots, i)
        return true
      end
    end
    return false
  end

  function api.getBestReturnSpotForVehicle(vehId, candidateSpots)
    if not vehId or type(candidateSpots) ~= 'table' or #candidateSpots == 0 then
      return nil
    end

    local bestSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(vehId, candidateSpots)
    if bestSpot then
      return bestSpot
    end

    return candidateSpots[1]
  end

  -- A won lot stays loaded and parks at a free return spot; an unsold lot is deleted.
  function api.despawnLotVehicle(lot)
    if not lot then return end
    if lot.wonInventoryId then
      local veh = lot.vehId and getObjectByID(lot.vehId)
      if veh then
        local returnSpots = ((auctionState.siteLayout or {}).returnSpots) or {}
        local freeSpots = {}
        for _, spot in ipairs(returnSpots) do
          if isSpotFree(spot) then
            table.insert(freeSpots, spot)
          end
        end
        local returnSpot = api.getBestReturnSpotForVehicle(veh:getID(), freeSpots)
        local placed = false
        if returnSpot and returnSpot.moveResetVehicleTo then
          local ok, placedPos = pcall(function()
            return returnSpot:moveResetVehicleTo(veh:getID(), nil, nil, nil, nil, true)
          end)
          placed = ok and placedPos ~= nil
        end
        if not placed then
          -- Keep the inventory record and final damage snapshot. Removal is
          -- asynchronous, so first clear the stage at the off-stage exit.
          local exitSpot = (auctionState.siteLayout or {}).despawnSpot
          if not exitSpot then return false end
          spawn.safeTeleport(veh, vec3(exitSpot.pos), quat(exitSpot.rot))
          deps.vehicleControl.cancelLotTransit(veh:getID())
          deps.vehicleControl.setLotVehicleDriveLock(veh, 'staged')
          deps.vehicleControl.restorePlayerGearboxMode(veh)
          overhaul_career_garage_inventory.removeVehicleObject(lot.wonInventoryId)
          lot.vehId = nil
          return true
        end
        gameplay_traffic.removeTraffic(veh:getID())
        deps.vehicleControl.setLotVehicleDriveLock(veh, 'staged')
        lot.vehId = veh:getID()
        return
      end
    end
    api.deleteVehicleSafe(lot.vehId)
    lot.vehId = nil
  end

  return api
end

return presentation
