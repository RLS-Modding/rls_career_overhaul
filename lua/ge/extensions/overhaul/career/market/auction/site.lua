-- Auction site layout: parking spots tagged by role, the player's start and exit spots, the exit and
-- counter markers in the scene, and the entrance pin on the big map.
local constants = require('overhaul/career/market/auction/constants')

local site = {}

function site.create()
  local selected, selectedMap
  local api = {}
  local levelData = require('overhaul/lib/world/levelData')

  local function facilityValid(facility)
    for _, key in ipairs({'id', 'name', 'sitesFile', 'entryTrigger', 'exitTrigger'}) do
      if type(facility[key]) ~= 'string' or facility[key] == '' then return false end
    end
    if type(facility.counterTriggers) ~= 'table' or #facility.counterTriggers < 1 then return false end
    for _, name in ipairs(facility.counterTriggers) do
      if type(name) ~= 'string' or name == '' then return false end
    end
    for _, key in ipairs({'presentation', 'spotTags'}) do
      if facility[key] ~= nil then
        if type(facility[key]) ~= 'table' then return false end
        for _, value in pairs(facility[key]) do
          if type(value) ~= 'string' or value == '' then return false end
        end
      end
    end
    if facility.filtersApplyToTypes ~= nil and type(facility.filtersApplyToTypes) ~= 'boolean' then return false end
    return facility.filtersFile == nil or (type(facility.filtersFile) == 'string' and facility.filtersFile ~= '')
  end

  function api.facilities(level)
    level = level or getCurrentLevelIdentifier()
    if not level or not overhaul_world_facilities then return {} end
    local records = overhaul_world_facilities.getFacilitiesByType('auction', level) or {}
    local valid = {}
    for _, facility in ipairs(records) do
      if facilityValid(facility) then
        valid[#valid + 1] = facility
      else
        log('W', 'usedCarAuction', 'Ignoring incomplete auction facility: ' .. tostring(facility.id))
      end
    end
    return valid
  end

  function api.selectFacility(facility)
    selected, selectedMap = facility, getCurrentLevelIdentifier()
  end

  function api.getBinding()
    if selectedMap ~= getCurrentLevelIdentifier() then selected = nil end
    return selected
  end

  function api.clearSelection()
    selected, selectedMap = nil, nil
  end

  function api.facilityForEntry(triggerName)
    for _, facility in ipairs(api.facilities()) do
      if facility.entryTrigger == triggerName then return facility end
    end
  end

  function api.matchesTrigger(triggerName, role)
    local facility = api.getBinding()
    if not facility then return false end
    if role == 'counter' then
      for _, name in ipairs(facility.counterTriggers) do
        if name == triggerName then return true end
      end
      return false
    end
    return triggerName == facility[role .. 'Trigger']
  end

  local function markerName(role)
    local facility = api.getBinding()
    return facility and facility.id .. '_' .. role .. 'Marker'
  end

  -- Parking spots -----------------------------------------------------------------------------------
  local function getSiteParkingSpots(facility, level)
    facility = facility or api.getBinding()
    level = level or getCurrentLevelIdentifier()
    local sitePath = facility and level and levelData.assetPath(level, facility.sitesFile)
    if not sitePath then
      log('W', 'usedCarAuction', 'Auction site binding unavailable on ' .. tostring(level))
      return nil
    end

    local siteData = gameplay_sites_sitesManager.loadSites(sitePath, true, true)
    if not siteData or not siteData.parkingSpots then
      log('W', 'usedCarAuction', 'Auction parking data unavailable: ' .. sitePath)
      return nil
    end

    local spots = siteData.parkingSpots.sorted or siteData.parkingSpots.objects
    local out = {}
    for _, spot in pairs(spots or {}) do
      if spot and spot.pos and spot.rot then
        table.insert(out, spot)
      end
    end

    return out
  end

  local function getSpotTags(spot)
    local tags = (((spot or {}).customFields or {}).tags)
    if type(tags) ~= 'table' then
      return {}
    end
    return tags
  end

  local function hasSpotTag(spot, tag)
    if not spot or not tag then return false end
    local wanted = string.lower(tostring(tag))
    local tags = getSpotTags(spot)

    -- Support both array-style tags {"a","b"} and map-style tags {a=true}.
    for key, value in pairs(tags) do
      local tagKey = string.lower(tostring(key))
      local tagValue = string.lower(tostring(value))
      if tagValue == wanted or tagKey == wanted then
        return true
      end
    end

    -- Editor fallback: accept spot name matching the desired tag.
    local name = string.lower(tostring(spot.name or ''))
    return name == wanted
  end

  local function parseTrailingNumber(name)
    local digits = tostring(name or ''):match('(%d+)%D*$')
    return tonumber(digits)
  end

  local function sortSpotsByNameAndIndex(spots)
    table.sort(spots, function(a, b)
      local na = parseTrailingNumber(a and a.name)
      local nb = parseTrailingNumber(b and b.name)
      if na and nb and na ~= nb then
        return na < nb
      end
      return tostring((a and a.name) or '') < tostring((b and b.name) or '')
    end)
    return spots
  end

  local function collectTaggedSpots(spots, tag)
    local out = {}
    for _, spot in ipairs(spots or {}) do
      if hasSpotTag(spot, tag) then
        table.insert(out, spot)
      end
    end
    return sortSpotsByNameAndIndex(out)
  end

  local function firstSpotWithTag(spots, tags)
    for _, tag in ipairs(tags or {}) do
      local list = collectTaggedSpots(spots, tag)
      if #list > 0 then
        return list[1]
      end
    end
    return nil
  end

  local function buildSiteLayout(spots, facility)
    facility = facility or api.getBinding() or {}
    local tags = facility.spotTags or {}
    local layout = {
      facility = facility,
      allSpots = spots or {},
      playerSpot = firstSpotWithTag(spots, {tags.playerStart or 'auctionPlayerStart'}),
      playerExitSpot = firstSpotWithTag(spots, {tags.playerExit or 'auctionPlayerExit'}),
      spawnSpots = collectTaggedSpots(spots, tags.spawn or 'auctionSpawn'),
      blockSpots = collectTaggedSpots(spots, tags.block or 'auctionBlock'),
      pathInSpots = collectTaggedSpots(spots, tags.pathIn or 'auctionPathIn'),
      pathOutSpots = collectTaggedSpots(spots, tags.pathOut or 'auctionPathOut'),
      despawnSpot = firstSpotWithTag(spots, {tags.despawn or 'auctionDespawn'}),
      returnSpots = collectTaggedSpots(spots, tags['return'] or 'auctionReturn'),
    }

    return layout
  end

  local function buildSpotFromTrigger(triggerName)
    if not triggerName then return nil end
    local trigger = scenetree.findObject(triggerName)
    if not trigger then
      return nil
    end

    local pos = trigger:getPosition()
    local rot = trigger:getRotation()
    if not pos or not rot then
      return nil
    end

    return {
      pos = vec3(pos),
      -- teleportVehicleToSpot adds a 180 deg Z turn; pre-apply it so the facing matches the trigger.
      rot = quat(0, 0, 1, 0) * quat(rot)
    }
  end

  -- The tagged exit spot, or the entry trigger's transform when the level has no exit tag.
  local function getPlayerExitSpot(layout, warnOnFallback)
    if layout and layout.playerExitSpot then
      return layout.playerExitSpot
    end

    local fallbackSpot = buildSpotFromTrigger(((layout and layout.facility) or api.getBinding() or {}).entryTrigger)
    if not fallbackSpot then
      return nil
    end

    if warnOnFallback then
      log('W', 'usedCarAuction', 'Missing player exit spot. Using configured entry trigger transform.')
    end

    if layout then
      layout.playerExitSpot = fallbackSpot
    end
    return fallbackSpot
  end

  -- Markers -----------------------------------------------------------------------------------------
  local function clearMarkerByName(markerName)
    if not markerName then return end
    local marker = scenetree.findObject(markerName)
    if not marker then
      return
    end

    -- The editor extension is absent outside editor sessions.
    if editor and editor.onRemoveSceneTreeObjects then
      editor.onRemoveSceneTreeObjects({marker:getID()})
    end
    marker:delete()
  end

  local function clearAuctionExitMarker()
    clearMarkerByName(markerName('exit'))
  end

  local function clearAuctionCounterMarker()
    clearMarkerByName(markerName('counter'))
  end

  local function buildMarkerAtPos(markerName, markerPos, color, scale)
    if not markerPos then
      return false
    end

    local marker = createObject('TSStatic')
    marker:setField('shapeName', 0, constants.AUCTION_EXIT_MARKER_SHAPE)
    marker:setPosition(markerPos + vec3(0, 0, constants.AUCTION_EXIT_MARKER_Z_OFFSET_M))
    marker.scale = vec3(scale, scale, scale)
    marker:setField('rotation', 0, '1 0 0 0')
    marker.useInstanceRenderData = true
    marker:setField('instanceColor', 0, color)
    marker:setField('collisionType', 0, 'Collision Mesh')
    marker:setField('decalType', 0, 'Collision Mesh')
    marker:setField('allowPlayerStep', 0, '1')
    marker:setField('canSave', 0, '0')
    marker:setField('canSaveDynamicFields', 0, '1')
    marker.canSave = false
    marker:registerObject(markerName)
    if scenetree.MissionGroup then
      scenetree.MissionGroup:addObject(marker)
    end

    return true
  end

  local function ensureAuctionExitMarker(layout)
    clearAuctionExitMarker()

    local markerPos = nil
    local binding = api.getBinding()
    local exitTrigger = binding and scenetree.findObject(binding.exitTrigger)
    if exitTrigger then
      local pos = exitTrigger:getPosition()
      if pos then
        markerPos = vec3(pos)
      end
    end

    if not markerPos then
      local exitSpot = getPlayerExitSpot(layout, false)
      if exitSpot and exitSpot.pos then
        markerPos = vec3(exitSpot.pos)
      end
    end

    if not markerPos then
      return false
    end

    return buildMarkerAtPos(
      markerName('exit'),
      markerPos,
      constants.AUCTION_EXIT_MARKER_COLOR,
      constants.AUCTION_EXIT_MARKER_SCALE
    )
  end

  local function ensureAuctionCounterMarker()
    clearAuctionCounterMarker()

    local binding = api.getBinding()
    local counterTrigger = binding and scenetree.findObject(binding.counterTriggers[1])
    if not counterTrigger then
      return false
    end

    local pos = counterTrigger:getPosition()
    if not pos then
      return false
    end

    return buildMarkerAtPos(
      markerName('counter'),
      vec3(pos),
      constants.AUCTION_COUNTER_MARKER_COLOR,
      constants.AUCTION_COUNTER_MARKER_SCALE
    )
  end

  -- Entrance pin ------------------------------------------------------------------------------------
  local function getAuctionEntrancePos(facility, level)
    local trigger = level == getCurrentLevelIdentifier() and scenetree.findObject(facility.entryTrigger)
    if trigger then
      local pos = trigger:getPosition()
      if pos then
        return vec3(pos)
      end
    end

    local spots = getSiteParkingSpots(facility, level)
    if not spots or #spots < 1 then
      return nil
    end

    local layout = buildSiteLayout(spots, facility)
    local fallbackSpot = getPlayerExitSpot(layout, false)
    if fallbackSpot and fallbackSpot.pos then
      return vec3(fallbackSpot.pos)
    end
    return nil
  end

  local function formatAuctionEntrancePoi(levelIdentifier, facility)
    if not levelIdentifier or not facility then return nil end
    local pos = getAuctionEntrancePos(facility, levelIdentifier)
    if not pos then
      return nil
    end

    return {
      id = facility.poiId or facility.id .. '_entrance',
      data = {
        type = 'dealership',
        facility = facility
      },
      markerInfo = {
        bigmapMarker = {
          pos = pos,
          icon = constants.AUCTION_POI_ICON,
          cardIcon = 'carDealer',
          name = facility.name,
          description = facility.description
        }
      }
    }
  end

  api.buildSiteLayout = buildSiteLayout
  api.clearAuctionCounterMarker = clearAuctionCounterMarker
  api.clearAuctionExitMarker = clearAuctionExitMarker
  api.ensureAuctionCounterMarker = ensureAuctionCounterMarker
  api.ensureAuctionExitMarker = ensureAuctionExitMarker
  api.formatAuctionEntrancePoi = formatAuctionEntrancePoi
  api.getPlayerExitSpot = getPlayerExitSpot
  api.getSiteParkingSpots = getSiteParkingSpots
  return api
end

return site
