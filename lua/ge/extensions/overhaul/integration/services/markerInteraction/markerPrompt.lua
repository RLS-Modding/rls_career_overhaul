-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Activity prompt policy of Overhaul's marker interaction (integration/services/markerInteraction): which POIs
-- may open the prompt, the prompt identity key, the settle delay, the player's dismissal, and the input filter
-- that keeps vehicle chords off the prompt buttons. create() returns one prompt with its own state; the marker
-- interaction owns it, so a reloaded extension starts with a new one.
local markerPrompt = {}

function markerPrompt.sortActivityData(a, b)
  -- Check if elements have a sorting table
  local hasSortingA = a.sorting ~= nil
  local hasSortingB = b.sorting ~= nil

  if hasSortingA and not hasSortingB then
    return true
  elseif not hasSortingA and hasSortingB then
    return false
  elseif hasSortingA and hasSortingB then
    -- Both have a sorting table; prioritize by type
    if a.sorting.type == "mission" and b.sorting.type ~= "mission" then
      return true
    elseif a.sorting.type ~= "mission" and b.sorting.type == "mission" then
      return false
    elseif a.sorting.type ~= b.sorting.type then
      return a.sorting.type < b.sorting.type
    else
      -- Same type; sort by order
      if (a.sorting.order or 0) == (b.sorting.order or 0) then
        return (a.sorting.id or a.heading) < (b.sorting.id or b.heading)
      end
      return (a.sorting.order or 0) < (b.sorting.order or 0)
    end
  else
    -- Neither have a sorting table; sort by heading
    return (a.heading or "") < (b.heading or "")
  end
end
local sortActivityData = markerPrompt.sortActivityData

local function getPOIData(elem)
  return elem and (elem.data or elem) or nil
end
markerPrompt.getPOIData = getPOIData

local noElements = {}
function markerPrompt.classifyCluster(cluster)
  if type(cluster.id) == 'string' and cluster.id:match('^missionMarker') then return false end
  for _, elem in ipairs(cluster.elemData or noElements) do
    local data = getPOIData(elem)
    if data and (data.missionId or data.type == 'mission') then return false end
  end
  return true
end

local function isOnEmploymentShift()
  local emp = overhaul_career_work_employment
  return emp and emp.isOnShift and emp.isOnShift() or false
end

local function isMissionLogisticsPOI(elem)
  local data = getPOIData(elem)
  if not data or not data.type then return false end
  if data.type == "logisticsParking" then
    return data.hasPlayerCargo or data.hasMaterialContract or data.hasEmploymentReturn or data.hasPaidSupply
  end
  if data.type == "logisticsOffice" then
    return false
  end
  return true
end
markerPrompt.isMissionLogisticsPOI = isMissionLogisticsPOI

-- Inspect / clock-in POIs must not use the 100m marker query radius.
local function isStallBoundPoi(elem)
  local data = getPOIData(elem)
  return data and (data.canInspectCargo or data.hasEmploymentClockIn) and true or false
end

local function filterInteractableElements(elements)
  local g = overhaul_career_logistics_general
  local out = {}
  for _, elem in ipairs(elements or {}) do
    local data = getPOIData(elem)
    if data and (data.missionId or data.type == 'mission') then
    elseif isStallBoundPoi(elem) then
      local data = getPOIData(elem)
      local atStall = data and data.psPath and g and g.playerAtFacilityStall
        and g.playerAtFacilityStall(data.psPath, data.canInspectCargo)
      if atStall then
        out[#out + 1] = elem
      end
    else
      out[#out + 1] = elem
    end
  end
  return out
end
markerPrompt.filterInteractableElements = filterInteractableElements

local function isEmploymentAutoDropOffPoi(elem)
  local data = getPOIData(elem)
  if not data or data.type ~= "logisticsParking" then return false end
  local emp = overhaul_career_work_employment
  return emp and emp.willAutoOpenDropOffAt and emp.willAutoOpenDropOffAt(data.facId, data.psPath) or false
end

local function shouldAutoOpenActivityPrompt(elements)
  if not elements or not elements[1] then return false end
  if not isOnEmploymentShift() then return true end
  for _, elem in ipairs(elements) do
    local data = getPOIData(elem)
    if isEmploymentAutoDropOffPoi(elem) then
      if data and (data.hasPaidSupply or data.hasMaterialContract or data.hasPickup) then
        return true
      end
    elseif isMissionLogisticsPOI(elem) then
      return true
    elseif data and data.hasEmploymentClockIn then
      return true
    end
  end
  return false
end
markerPrompt.shouldAutoOpenActivityPrompt = shouldAutoOpenActivityPrompt

-- Per-place id fields carried by POI data (facility, shop, car-meet vehicle,
-- fast-travel place, journal spot, roadside trigger, ...).
local PROMPT_IDENTITY_FIELDS = {"facilityId", "shopId", "inventoryId", "placeId", "mapId", "locationId", "triggerName", "id"}

local function isScalarId(value)
  local t = type(value)
  return t == "string" or t == "number"
end

local function elementIdentity(elem)
  local parts = {}
  local facility = elem.facility
  if type(facility) == "table" then
    -- most facilities carry an id; drag strips only carry a name, and their history-board and
    -- rules markers differ only by the nested dragstripPoiType
    if isScalarId(facility.id) then
      parts[#parts + 1] = "facility=" .. tostring(facility.id)
    elseif isScalarId(facility.name) then
      parts[#parts + 1] = "facilityName=" .. tostring(facility.name)
    end
    if isScalarId(facility.dragstripPoiType) then
      parts[#parts + 1] = "dragstripPoi=" .. tostring(facility.dragstripPoiType)
    end
  end
  for _, field in ipairs(PROMPT_IDENTITY_FIELDS) do
    local value = elem[field]
    if isScalarId(value) then
      parts[#parts + 1] = field .. "=" .. tostring(value)
    end
  end
  local testDriveInfo = elem.testDriveInfo
  local vehicleInfo = type(testDriveInfo) == "table" and testDriveInfo.vehicleInfo
  if type(vehicleInfo) == "table" and isScalarId(vehicleInfo.shopId) then
    parts[#parts + 1] = "testDrive=" .. tostring(vehicleInfo.shopId)
  end
  return table.concat(parts, ",")
end

-- State that changes what a prompt offers without changing which place it is (cargo spots keep these
-- under elem.data). Part of the key, so a changed prompt is a new prompt and is not kept dismissed.
local PROMPT_STATE_FIELDS = {
  "canInspectCargo", "hasPlayerCargo", "hasPaidSupply", "hasPickup", "hasMaterialContract",
  "hasEmploymentReturn", "hasEmploymentClockIn",
}

-- Elements arrive both flat and wrapped ({id, data = {...}, markerInfo}). Read a field from the payload
-- first and fall back to the wrapper, so either shape gives the same key.
local function promptField(elem, data, field)
  local value = data[field]
  if value == nil then value = elem[field] end
  return value
end

local function interactablePromptKey(elements)
  local keys = {}
  for i, elem in ipairs(elements or {}) do
    local data = getPOIData(elem) or elem
    local state = {}
    for _, field in ipairs(PROMPT_STATE_FIELDS) do
      state[#state + 1] = tostring(promptField(elem, data, field))
    end
    -- the wrapper's own identity (e.g. "delivery-parking-<fac>-<path>") stays in the key next to the
    -- payload's, so two wrappers around similar payloads never collide
    local wrapperIdentity = (data ~= elem) and elementIdentity(elem) or ""
    keys[i] = string.format("%s|%s|%s|%s|%s|%s|%s",
      tostring(promptField(elem, data, "type") or ""), tostring(promptField(elem, data, "psPath") or ""),
      tostring(promptField(elem, data, "missionId") or ""), tostring(promptField(elem, data, "facId") or ""),
      table.concat(state, ","), elementIdentity(data), wrapperIdentity)
  end
  table.sort(keys)
  return table.concat(keys, ";;")
end
markerPrompt.interactablePromptKey = interactablePromptKey

-- Vehicle action maps run before interact. Reserve its actual controls while a
-- prompt is visible, but keep the phone, walking and horn independently usable.
local ACTIVITY_PROMPT_FILTER = "rlsActivityPromptInput"
local independentActions = {openPhone = true, toggleWalkingMode = true, horn = true}

local function collectConflictingVehicleActions()
  local conflicting = {}
  if not core_input_actions or not core_input_bindings then
    return conflicting
  end
  local actions = core_input_actions.getActiveActions()
  if type(actions) ~= "table" then
    return conflicting
  end
  for _, name in ipairs(core_input_bindings.getActionsSharingControls("gameplay_interact")) do
    local action = actions[name]
    if not independentActions[name] and type(action) == "table" and
        (action.vehicle ~= nil or action.ctx == "vlua" or
          action.actionMap == "VehicleCommon" or action.actionMap == "VehicleSpecific") then
      conflicting[#conflicting + 1] = name
    end
  end
  return conflicting
end

local function clockNow()
  return (os.clockhp or os.clock)()
end
markerPrompt.clockNow = clockNow

-- Brief pause after reaching parking speed so the driver can set park/parking brake
-- before ActivityStart steals B/Circle for Close.
local PROMPT_SETTLE_DELAY = 0.65
-- A Close that is immediately followed by leaving play is the prompt's own
-- "open pause menu" route, not a dismissal.
local DISMISS_MENU_GRACE = 1.0

-- isOverhaulActive: the marker interaction's own check, for the UI state hook.
function markerPrompt.create(isOverhaulActive)
  local prompt = {}
  local currentInteractableElements = {}
  local cachedInteractablePromptKey = nil
  local pendingPromptElements = nil
  local pendingPromptKey = nil
  local promptSettleTimer = nil

  -- Prompt key the player closed with Close/Back. It stays closed (menu round-trips
  -- included) until the player leaves that place or the prompt key changes.
  local dismissedPromptKey = nil
  local dismissedAt = nil
  -- > 0 while a prompt button callback runs; closes from there are hand-offs.
  local promptActionDepth = 0
  -- True while ui_missionInfo shows a non-empty activity prompt.
  local activityPromptVisible = false
  -- Walking out of one marker re-checks every marker on the next frame before
  -- closing, since the player may still stand in an overlapping one.
  local walkingExitCheckActive = false
  local forceReevaluateOpenPrompt = true
  local activityPromptInputLocked = false

  local function clearDismissedPrompt()
    dismissedPromptKey = nil
    dismissedAt = nil
  end
  prompt.clearDismissedPrompt = clearDismissedPrompt

  local function clearPendingPrompt()
    pendingPromptElements = nil
    pendingPromptKey = nil
    promptSettleTimer = nil
  end

  function prompt.getCurrentInteractableElements()
    return currentInteractableElements
  end

  local function unlockActivityPromptInput()
    if not activityPromptInputLocked then return end
    activityPromptInputLocked = false
    if core_input_actionFilter then
      core_input_actionFilter.addAction(0, ACTIVITY_PROMPT_FILTER, false)
      core_input_actionFilter.setGroup(ACTIVITY_PROMPT_FILTER, {})
    end
  end
  prompt.unlockActivityPromptInput = unlockActivityPromptInput

  local function lockActivityPromptInput()
    if not core_input_actionFilter then return end

    local blocked = collectConflictingVehicleActions()
    if #blocked == 0 then unlockActivityPromptInput() return end

    activityPromptInputLocked = true
    core_input_actionFilter.setGroup(ACTIVITY_PROMPT_FILTER, blocked)
    core_input_actionFilter.addAction(0, ACTIVITY_PROMPT_FILTER, true)
  end

  -- Bindings and the focused vehicle can change without closing the prompt.
  function prompt.refreshInputConflicts()
    if activityPromptVisible and isOverhaulActive() then
      lockActivityPromptInput()
    else
      unlockActivityPromptInput()
    end
  end

  -- Button callbacks often close the prompt before opening their own screen. Mark
  -- those closes as hand-offs so they do not count as the player dismissing it.
  local function wrapPromptAction(fn)
    return function(...)
      promptActionDepth = promptActionDepth + 1
      local ok, err = xpcall(fn, debug.traceback, ...)
      promptActionDepth = promptActionDepth - 1
      if not ok then error(err, 0) end
    end
  end

  local function openViewDetailPrompt(elemData)
    local activityData = {}
    extensions.hook("onActivityAcceptGatherData", elemData, activityData)

    table.sort(activityData, sortActivityData)
    for _, entry in ipairs(activityData) do
      if type(entry.buttonFun) == "function" then
        entry.buttonFun = wrapPromptAction(entry.buttonFun)
      end
    end
    ui_missionInfo.openActivityAcceptDialogue(activityData)
    -- Indeed-style Market Watch advert while engaging career work markers
    if overhaul_career_career and overhaul_career_career.isActive and overhaul_career_career.isActive()
        and overhaul_career_economy_activityHeat and overhaul_career_economy_activityHeat.maybeShowOpportunityAdvert then
      local ok, err = pcall(overhaul_career_economy_activityHeat.maybeShowOpportunityAdvert, "marker")
      if not ok then
        log("E", "markerInteraction", "maybeShowOpportunityAdvert failed: " .. tostring(err))
      end
    end

    -- onMissionInfoChangedState already synced this; repeat in case the hook missed us.
    activityPromptVisible = #activityData > 0
    if activityPromptVisible then
      lockActivityPromptInput()
    else
      unlockActivityPromptInput()
    end
  end

  -- Closes the prompt without treating it as the player's choice (leaving the
  -- marker, driving off). Same effect as the old closeViewDetailPrompt.
  local function closePrompt(force)
    if force then
      unlockActivityPromptInput()
      ui_missionInfo.closeDialogue()
      guihooks.trigger("onMissionAvailabilityChanged", {missionCount = 0})
      guihooks.trigger('ActivityAcceptUpdate', nil)
      extensions.hook("onMissionAvailabilityChanged", {missionCount = 0})
    end
  end
  prompt.closePrompt = closePrompt

  -- The prompt's own Close/Back: the player said no, so keep this place's prompt shut until they leave it.
  function prompt.dismissViewDetailPrompt()
    if activityPromptVisible and promptActionDepth == 0 and cachedInteractablePromptKey then
      dismissedPromptKey = cachedInteractablePromptKey
      dismissedAt = clockNow()
    end
    closePrompt(true)
  end

  function prompt.isActivityPromptOpen()
    return activityPromptVisible
  end

  function prompt.onMissionInfoChangedState(fromState, toState, content)
    if not isOverhaulActive() then return end
    if toState == "closed" then
      activityPromptVisible = false
      unlockActivityPromptInput()
    elseif toState == "opened" then
      -- An empty activity list shows nothing, so it must not hold the input filter.
      activityPromptVisible = type(content) == "table" and #content > 0
      if activityPromptVisible then
        lockActivityPromptInput()
      else
        unlockActivityPromptInput()
      end
    end
  end

  local function openPromptFromElements(elements, promptKey)
    table.clear(currentInteractableElements)
    for i, elem in ipairs(elements) do
      currentInteractableElements[i] = elem
    end
    openViewDetailPrompt(elements)
    cachedInteractablePromptKey = promptKey
  end

  -- Markers read these while the frame's interactables are collected.
  function prompt.isReevaluating()
    return forceReevaluateOpenPrompt
  end
  function prompt.isWalkingExitCheck()
    return walkingExitCheckActive
  end
  -- Re-run prompt evaluation next frame. Keeps a prompt the player closed closed.
  function prompt.requestPromptReevaluation()
    forceReevaluateOpenPrompt = true
  end

  -- Multiseat takes over the markers: the single-player prompt closes.
  function prompt.closeForMultiseat()
    table.clear(currentInteractableElements)
    closePrompt(true)
  end

  -- End of a marker frame: open, settle, keep dismissed or close the prompt for what the markers collected.
  function prompt.update(interactableElements, isWalking, isAtParkingSpeed, parkingSpeedChanged, activeMission, anyMarkerIsInAreaChanged, dtReal)
    local shouldRefreshPrompt = forceReevaluateOpenPrompt
    forceReevaluateOpenPrompt = false
    local walkingExitCheck = walkingExitCheckActive
    walkingExitCheckActive = false
    if next(interactableElements) then
      local filteredElements = filterInteractableElements(interactableElements)
      local promptKey = interactablePromptKey(filteredElements)
      if dismissedPromptKey and promptKey ~= dismissedPromptKey then
        -- Moved on to a different place: the earlier Close no longer applies.
        clearDismissedPrompt()
      end
      if promptKey == dismissedPromptKey then
        -- Closed by the player here; stay closed until they leave.
        if pendingPromptKey == promptKey then
          clearPendingPrompt()
        end
      elseif promptKey ~= cachedInteractablePromptKey or shouldRefreshPrompt then
        local alreadyShowingSame = cachedInteractablePromptKey == promptKey
        local alreadySettlingSame = pendingPromptElements and pendingPromptKey == promptKey
        -- Do not restart the settle timer every frame while cachedInteractablePromptKey
        -- is still nil. Let the existing pending prompt count down and open.
        if not alreadySettlingSame or shouldRefreshPrompt then
          if shouldAutoOpenActivityPrompt(filteredElements) then
            -- Walking has no parking-brake beat; refresh of an already-open prompt should be instant.
            if isWalking or (shouldRefreshPrompt and alreadyShowingSame) then
              clearPendingPrompt()
              openPromptFromElements(filteredElements, promptKey)
            else
              pendingPromptElements = {}
              for i, elem in ipairs(filteredElements) do
                pendingPromptElements[i] = elem
              end
              pendingPromptKey = promptKey
              promptSettleTimer = PROMPT_SETTLE_DELAY
            end
          else
            clearPendingPrompt()
            if cachedInteractablePromptKey then
              table.clear(currentInteractableElements)
              cachedInteractablePromptKey = nil
              closePrompt(true)
            end
          end
        end
      end
    end

    if promptSettleTimer then
      if not isAtParkingSpeed then
        clearPendingPrompt()
      else
        promptSettleTimer = promptSettleTimer - dtReal
        if promptSettleTimer <= 0 and pendingPromptElements then
          if pendingPromptKey ~= dismissedPromptKey and shouldAutoOpenActivityPrompt(pendingPromptElements) then
            openPromptFromElements(pendingPromptElements, pendingPromptKey)
          end
          clearPendingPrompt()
        end
      end
    end

    if not activeMission and not next(interactableElements) then
      if isWalking then
        if walkingExitCheck then
          -- Re-check found no marker around the player: they left.
          table.clear(currentInteractableElements)
          cachedInteractablePromptKey = nil
          clearPendingPrompt()
          clearDismissedPrompt()
          closePrompt(true)
        elseif anyMarkerIsInAreaChanged == "out" then
          -- Leaving one marker can leave the player inside an overlapping one.
          -- Re-collect every marker next frame before closing.
          walkingExitCheckActive = true
        end
      elseif not isAtParkingSpeed or parkingSpeedChanged then
        table.clear(currentInteractableElements)
        cachedInteractablePromptKey = nil
        clearPendingPrompt()
        clearDismissedPrompt()
        closePrompt(parkingSpeedChanged)
      end
    end
  end

  -- Level end / Overhaul stop.
  function prompt.onClientEndMission()
    clearPendingPrompt()
    clearDismissedPrompt()
    walkingExitCheckActive = false
    activityPromptVisible = false
    unlockActivityPromptInput()
  end

  -- Overhaul stops: close a shown prompt (then the level-end reset), then start from a new element list.
  function prompt.closeIfVisible()
    if activityPromptVisible then closePrompt(true) end
  end
  function prompt.resetAfterDisable()
    currentInteractableElements = {}
    cachedInteractablePromptKey = nil
    forceReevaluateOpenPrompt = true
  end

  function prompt.onUIPlayStateChanged(enteredPlay)
    if enteredPlay then
      prompt.requestPromptReevaluation()
    elseif dismissedAt and clockNow() - dismissedAt < DISMISS_MENU_GRACE then
      -- The prompt closed itself to open the pause menu; bring it back afterwards.
      clearDismissedPrompt()
    end
  end

  return prompt
end

return markerPrompt
