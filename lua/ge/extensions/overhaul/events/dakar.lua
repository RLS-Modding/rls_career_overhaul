-- Shared Dakar event controller, activated by map optional-feature manifests.
-- Owns signup, run state, UI and saves; dakar/course.lua owns routes and headings,
-- dakar/vehicle.lua owns classification, kits and payments. UI calls the public M API.
local M = {}
local Course = require('overhaul/events/dakar/course')
local Vehicle = require('overhaul/events/dakar/vehicle')
local levelData = require('overhaul/lib/world/levelData')
local saveStore = require('overhaul/lib/save/store')

M.dependencies = {
  "overhaul_career_career",
  "overhaul_career_saveSystem",
  "overhaul_career_garage_inventory",
  "overhaul_career_economy_payment",
  "overhaul_career_economy_playerAttributes",
  "overhaul_career_market_valueCalculator",
  "overhaul_career_economy_difficultyMode",
  "overhaul_career_logistics_general",
  "overhaul_career_logistics_parcelManager",
  "overhaul_career_logistics_generator",
  "overhaul_career_repair_insurance"
}

local saveFile
local poiPrefix
local levelLabel
local course
local vehicle
local config
local spotsByName = {}

local function newState()
  return {
    phase = "idle",
    settings = {
      skipIntro = false
    },
    stats = {
      totalCompletions = 0,
      totalWins = 0,
      noRepairCompletions = 0,
      classCompletions = {},
      claimedAccolades = {}
    }
  }
end

local state = newState()
local phoneDirtyTimer = 0
local compassTimer = 0
local compassInterval = 1 / 30
local startPromptOpen = false
local activeCheckpointMarker
local activeCheckpointMarkerId
local signupRequest
local repairRequest
local compassState
local loadingState = false

local function releaseKitCargo(run)
  if not vehicle or not run then return end
  for _, key in ipairs(run.repairKitCargoIds or {}) do vehicle.removeRepairCargo(key) end
end

local function clearPoiCache()
  if gameplay_rawPois and gameplay_rawPois.clear then gameplay_rawPois.clear() end
end

local function hideStartOverlay()
  if guihooks and guihooks.trigger then guihooks.trigger("DakarStartUi", { visible = false }) end
end

local function hideFinishOverlay()
  if guihooks and guihooks.trigger then guihooks.trigger("DakarFinishUi", { visible = false }) end
end

local function hideCompassOverlay()
  compassTimer = 0
  compassState = nil
  if guihooks and guihooks.trigger then guihooks.trigger("DakarCompassUi", { visible = false }) end
end

local function clearCheckpointMarker()
  if activeCheckpointMarker then
    activeCheckpointMarker:delete()
    activeCheckpointMarker = nil
    activeCheckpointMarkerId = nil
  end
end

local function notify(msg, category)
  ui_message(msg, 5, category or "info", category or "info")
end

local function loadSites()
  course.loadSites()
  spotsByName = course.getSpots()
end

local function savePath()
  if not overhaul_career_saveSystem or not overhaul_career_saveSystem.getCurrentProfile then return nil end
  local _, currentSavePath = overhaul_career_saveSystem.getCurrentProfile()
  return currentSavePath and (currentSavePath .. saveFile) or nil
end

local function rebuildActiveRoute(active)
  if not active or active.route then return end
  loadSites()
  local route = {}
  for _, id in ipairs(active.routeIds or {}) do
    if spotsByName[id] then table.insert(route, spotsByName[id]) end
  end
  active.route = course.enrichRoute(route)
end

local function encodeForSave()
  local liveRoute = state.active and state.active.route or nil
  if state.active then state.active.route = nil end
  local payload = deepcopy(state)
  if state.active then state.active.route = liveRoute end
  if payload.active and liveRoute then
    payload.active.routeIds = {}
    for _, spot in ipairs(liveRoute) do
      table.insert(payload.active.routeIds, spot.id)
    end
  end
  return payload
end

local function ensureStats()
  state.settings = state.settings or {}
  state.settings.skipIntro = state.settings.skipIntro == true
  state.stats = state.stats or {}
  state.stats.totalCompletions = state.stats.totalCompletions or 0
  state.stats.totalWins = state.stats.totalWins or 0
  state.stats.noRepairCompletions = state.stats.noRepairCompletions or 0
  state.stats.classCompletions = state.stats.classCompletions or {}
  state.stats.claimedAccolades = state.stats.claimedAccolades or {}
end

local function saveState()
  ensureStats()
  local path = savePath()
  if not path then return end
  overhaul_career_saveSystem.jsonWriteFileSafe(path, encodeForSave(), true)
end

local function loadState()
  local path = savePath()
  local loaded = path and jsonReadFile(path) or nil
  if loaded then state = loaded end
  ensureStats()
  rebuildActiveRoute(state.active)
  if config.failure and config.failure.failActiveOnLoad and state.phase == "active" then
    state.lastFailure = { reason = "reload", time = os.time() }
    state.phase = "failed"
    releaseKitCargo(state.active)
    state.active = nil
    hideCompassOverlay()
    saveState()
  end
end

local function formatDistanceMeters(meters)
  meters = tonumber(meters) or 0
  if meters >= 1000 then return string.format("%.1f km", meters / 1000) end
  return tostring(math.max(0, math.floor(meters + 0.5))) .. " m"
end

local function emitDakarNotification(title, message, meta, image, ttl)
  if not guihooks or not guihooks.trigger then return end
  guihooks.trigger("PhoneLockNotification", {
    title = title or "Dakar",
    message = message or "",
    kind = "dakar",
    ttl = ttl or 8,
    meta = meta or "",
    source = "Dakar",
    image = image,
    sound = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" }
  })
end

local function emitStartNotification()
  loadSites()
  local veh = getPlayerVehicle(0)
  local startSpot = spotsByName[config.startSpot]
  local meters = (veh and startSpot) and (startSpot.pos - veh:getPosition()):length() or nil
  emitDakarNotification(
    "Dakar Signed Up",
    "Drive to the starting line.",
    meters and formatDistanceMeters(meters) or "",
    course.resolveCheckpointImage("Dakar Start"),
    9
  )
end

local function emitCheckpointNotification()
  local active = state.active
  local cp = active and active.route and active.route[active.index]
  if not cp then return end
  local veh = getPlayerVehicle(0)
  local meters = veh and (cp.pos - veh:getPosition()):length() or nil
  local count = active.route and #active.route or 0
  local metaParts = { string.format("%d/%d", active.index or 1, count) }
  if meters then table.insert(metaParts, formatDistanceMeters(meters)) end
  if config.showHeadingClue ~= false then table.insert(metaParts, cp.headingText or course.formatHeading(cp.headingDegrees)) end
  emitDakarNotification(
    "Next Checkpoint",
    cp.name or "Checkpoint",
    table.concat(metaParts, " - "),
    cp.image,
    10
  )
end

local function compassPayload()
  local active = state.active
  local cp = active and active.route and active.route[active.index]
  if state.phase ~= "active" or not active or not cp then
    return nil
  end
  local veh = getPlayerVehicle(0)
  local vehHeading = veh and course.headingFromVector(veh:getDirectionVector()) or nil
  -- Keep sub-degree motion without publishing floating-point noise while parked.
  if vehHeading then vehHeading = math.floor(vehHeading * 10 + 0.5) / 10 % 360 end
  local distance = veh and math.floor((cp.pos - veh:getPosition()):length() + 0.5) or nil
  local previous = compassState and compassState.payload
  if previous and previous.vehicleHeadingDegrees == vehHeading and
    previous.distanceMeters == distance and previous.checkpointIndex == active.index and
    previous.checkpointName == (cp.name or "Checkpoint") then return nil end
  compassState = {
    visible = true,
    payload = {
      vehicleHeadingDegrees = vehHeading,
      vehicleHeadingText = course.formatHeading(vehHeading),
      clueHeadingDegrees = cp.headingDegrees,
      clueHeadingText = cp.headingText or course.formatHeading(cp.headingDegrees),
      checkpointName = cp.name or "Checkpoint",
      checkpointIndex = active.index or 1,
      checkpointCount = active.route and #active.route or 0,
      distanceMeters = distance,
      distanceText = distance and formatDistanceMeters(distance) or ""
    }
  }
  return compassState
end

local function emitCompass()
  if not guihooks or not guihooks.trigger then return end
  local payload = compassPayload()
  if payload then guihooks.trigger("DakarCompassUi", payload) end
end

local function phonePayload()
  local active = state.active
  local cp = active and active.route and active.route[active.index]
  local veh = getPlayerVehicle(0)
  local distance = (cp and veh) and (cp.pos - veh:getPosition()):length() or nil
  local startSpot = spotsByName[config.startSpot]
  local startDistance = (state.phase == "signedUp" and startSpot and veh) and (startSpot.pos - veh:getPosition()):length() or nil
  return {
    phase = state.phase,
    active = active ~= nil,
    pending = state.phase == "signedUp",
    start = startDistance and {
      distanceMeters = startDistance,
      atStart = startDistance <= (config.startRadiusMeters or 18)
    } or nil,
    checkpoint = cp and {
      name = cp.name,
      image = cp.image,
      index = active.index,
      count = #active.route,
      distanceMeters = distance,
      headingDegrees = cp.headingDegrees,
      headingText = cp.headingText or course.formatHeading(cp.headingDegrees)
    } or nil,
    repairsLeft = active and active.repairsLeft or (state.pending and state.pending.repairsLeft or 0),
    canRepair = active and active.repairsLeft and active.repairsLeft > 0 or false,
    lastResult = state.lastResult
  }
end

local function emitPhone()
  guihooks.trigger("dakarPhoneData", phonePayload())
end

local function accoladeProgress(acc)
  ensureStats()
  if acc.stat == "classCompletions" then
    return state.stats.classCompletions[acc.class] or 0
  end
  return state.stats[acc.stat] or 0
end

local function formatMoney(amount)
  amount = math.floor((tonumber(amount) or 0) + 0.5)
  local str = tostring(amount)
  while true do
    local formatted, count = str:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    str = formatted
    if count == 0 then break end
  end
  return "$" .. str
end

local function accoladeRewardMoney(acc)
  local reward = acc and acc.reward or {}
  return tonumber(reward.money) or 0
end

local function menuPayload()
  local classInfo = vehicle.detectClass()
  local invId, _, veh = vehicle.currentVehicleInfo()
  local setupBlockedReason = (not veh or not invId) and "You must be in your race vehicle." or nil
  local kit = config.repairKit
  local kitCost = math.floor(((classInfo and classInfo.vehicleValue) or 0) * kit.costVehicleValueFactor)
  local containerSlots = 0
  local containerCount = 0
  local cached = overhaul_career_logistics_general and overhaul_career_logistics_general.getMostRecentCargoContainerData and overhaul_career_logistics_general.getMostRecentCargoContainerData() or {}
  for _, con in ipairs(cached or {}) do
    if veh and con.vehId == veh:getID() and con.cargoTypesLookup and con.cargoTypesLookup.parcel then
      containerSlots = containerSlots + math.floor((con.freeCargoSlots or 0) / kit.slots) * kit.slots
      containerCount = containerCount + 1
    end
  end
  local maxKitsByCargo = math.floor(containerSlots / kit.slots)

  local accolades = {}
  for _, acc in ipairs(config.accolades or {}) do
    local progress = accoladeProgress(acc)
    local rewardMoney = accoladeRewardMoney(acc)
    table.insert(accolades, {
      id = acc.id,
      title = acc.title,
      description = acc.description,
      progress = progress,
      target = acc.target,
      claimed = state.stats.claimedAccolades[acc.id] == true,
      ready = progress >= acc.target and state.stats.claimedAccolades[acc.id] ~= true,
      rewardMoney = rewardMoney,
      rewardLabel = formatMoney(rewardMoney),
      reward = acc.reward
    })
  end

  return {
    phase = state.phase,
    classInfo = classInfo,
    setupBlockedReason = setupBlockedReason,
    showIntro = state.settings.skipIntro ~= true,
    classes = config.classes,
    classOrder = config.classOrder,
    repairKit = {
      slots = kit.slots,
      weightKg = kit.weightKg,
      cost = kitCost,
      freeCargoSlots = containerSlots,
      cargoContainerCount = containerCount,
      maxByCargo = maxKitsByCargo
    },
    pending = state.pending,
    lastResult = state.lastResult,
    accolades = accolades
  }
end

local function startPayload(distance)
  local pending = state.pending or {}
  return {
    visible = true,
    payload = {
      title = "Dakar Start",
      levelName = levelLabel,
      classLabel = pending.classLabel or "Unlimited",
      repairsLeft = pending.repairsLeft or 0,
      distanceMeters = distance or 0
    }
  }
end

local function finishPayload()
  local r = state.lastResult or {}
  return {
    visible = true,
    payload = {
      title = "Dakar Complete",
      placement = r.placement or "Finished",
      placementId = r.placementId or "top10",
      classLabel = r.classLabel or "Dakar",
      elapsedSeconds = r.elapsedSeconds or 0,
      adjustedSeconds = r.adjustedSeconds or 0,
      targetSeconds = r.targetSeconds or 0,
      repairPenaltySeconds = r.repairPenaltySeconds or 0,
      repairsUsed = r.repairsUsed or 0,
      totalDistanceKm = r.totalDistanceKm or 0,
      baseReward = r.baseReward or 0,
      bonus = r.bonus or 0,
      totalReward = r.totalReward or 0
    }
  }
end

local function emitMenu()
  local requestedConfig = config
  vehicle.getPlayerCargoContainers(function()
    if config ~= requestedConfig then return end
    guihooks.trigger("dakarData", menuPayload())
  end)
end

local function clearGroundRoute()
  if core_groundMarkers and core_groundMarkers.setPath then core_groundMarkers.setPath(nil) end
end

local function routeToStart()
  loadSites()
  local startSpot = spotsByName[config.startSpot]
  if startSpot and core_groundMarkers and core_groundMarkers.setPath then
    core_groundMarkers.setPath(startSpot.pos, { clearPathOnReachingTarget = true })
  end
end

-- Freight restores numeric parcel identities before Dakar resolves persistent kit keys.
local function restoreStateWhenReady()
  if not loadingState then return true end
  if overhaul_career_logistics_general.ensureSetupForCurrentMap and
    not overhaul_career_logistics_general.ensureSetupForCurrentMap() then return false end
  loadState()
  loadingState = false
  if state.phase == "signedUp" then routeToStart() end
  if state.phase == "active" then emitCompass() end
  clearPoiCache()
  return true
end

function M.requestDakarMenuData()
  if not config or not restoreStateWhenReady() then return end
  emitMenu()
end

function M.requestDakarPhoneData()
  if not config or not restoreStateWhenReady() then return end
  emitPhone()
end

function M.closeMenu()
  if not config then return end
  log("I", poiPrefix, "Closing Dakar menu")
  hideStartOverlay()
  hideFinishOverlay()
  if state.phase ~= "active" then hideCompassOverlay() end
  if overhaul_career_career and overhaul_career_career.closeAllMenus then overhaul_career_career.closeAllMenus() end
  guihooks.trigger("ChangeState", { state = "play", params = {} })
end

function M.closeStartPrompt()
  if not config then return end
  startPromptOpen = false
  hideStartOverlay()
end

function M.dismissFinish()
  if not config then return end
  hideFinishOverlay()
end

function M.openMenu(tab)
  if not config or not restoreStateWhenReady() then return end
  guihooks.trigger("ChangeState", { state = "dakar", params = { tab or "signup" } })
  emitMenu()
end

function M.dismissIntro(dontShowAgain)
  if not config or not restoreStateWhenReady() then return end
  state.settings = state.settings or {}
  if dontShowAgain == true then
    state.settings.skipIntro = true
    saveState()
  end
  emitMenu()
end

function M.signUp(kitCount)
  if not config or not restoreStateWhenReady() then return end
  loadSites()
  kitCount = math.max(0, math.floor(tonumber(kitCount) or 0))
  log("I", poiPrefix, "Dakar sign-up requested with " .. tostring(kitCount) .. " repair kits")
  if signupRequest or state.phase == "active" or state.phase == "signedUp" then
    notify("Finish or abandon the current Dakar first.", "warning")
    return
  end

  local classInfo = vehicle.detectClass()
  local invId, _, veh = vehicle.currentVehicleInfo()
  if not veh or not invId then notify("You must be in your race vehicle.", "warning") emitMenu() return end
  if not classInfo then notify("Could not determine this vehicle's Dakar class.", "warning") emitMenu() return end

  local requestedConfig = config
  local request = {}
  signupRequest = request
  vehicle.getPlayerCargoContainers(function(containers)
    if config ~= requestedConfig or signupRequest ~= request then return end
    signupRequest = nil
    if state.phase ~= "idle" and state.phase ~= "failed" then return end
    if vehicle.currentVehicleInfo() ~= invId or getPlayerVehicle(0) ~= veh then return end
    local neededSlots = kitCount * config.repairKit.slots
    local repairContainers, totalSlots = vehicle.getRepairContainers(containers, veh:getID())
    if kitCount > 0 and totalSlots < neededSlots then
      notify("Not enough parcel cargo space for those Repair Kits.", "warning")
      emitMenu()
      return
    end
    if kitCount > 0 and (not overhaul_career_logistics_parcelManager or not overhaul_career_logistics_parcelManager.addCargo) then
      notify("Cargo manager is not available for Dakar Repair Kits.", "warning")
      emitMenu()
      return
    end

    local cost = math.floor(vehicle.getVehicleValue(invId) * config.repairKit.costVehicleValueFactor * kitCount)
    if cost > 0 and not vehicle.canPayMoney(cost) then
      notify("Not enough money for those Repair Kits.", "warning")
      emitMenu()
      return
    end

    local kitIds = kitCount > 0 and vehicle.addRepairCargo(repairContainers, kitCount) or {}
    if kitCount > 0 and #kitIds < kitCount then
      for _, id in ipairs(kitIds) do vehicle.removeRepairCargo(id) end
      notify("Could not load all Dakar Repair Kits.", "warning")
      emitMenu()
      return
    end
    if cost > 0 and not vehicle.payMoney(cost, "Purchased Dakar Repair Kits") then
      for _, id in ipairs(kitIds) do vehicle.removeRepairCargo(id) end
      notify("Not enough money for those Repair Kits.", "warning")
      emitMenu()
      return
    end
    state.phase = "signedUp"
    state.pending = {
      classId = classInfo.id,
      classLabel = classInfo.label,
      inventoryId = invId,
      vehicleId = veh:getID(),
      repairsLeft = kitCount,
      repairKitCargoIds = kitIds,
      kitCost = cost,
      signedUpAt = os.time()
    }
    state.lastResult = nil
    startPromptOpen = false
    saveState()
    clearPoiCache()
    routeToStart()
    notify("Dakar signed up. Drive to the starting line.", "info")
    emitStartNotification()
    if overhaul_career_career and overhaul_career_career.closeAllMenus then overhaul_career_career.closeAllMenus() end
    guihooks.trigger("ChangeState", { state = "play", params = {} })
    emitMenu()
    emitPhone()
  end)
end

function M.startEvent()
  if not config or not restoreStateWhenReady() then return end
  loadSites()
  if state.phase ~= "signedUp" or not state.pending then notify("Sign up before starting Dakar.", "warning") return end
  if vehicle.currentVehicleInfo() ~= state.pending.inventoryId then
    notify("Return to your registered Dakar vehicle.", "warning")
    return
  end
  local classRule = config.classes[state.pending.classId] or config.classes.Unlimited
  local route = course.buildRoute(classRule)
  if not route then notify("Dakar route generation failed. Add more spaced checkpoints or lower spacing.", "warning") return end
  local totalDistance = course.routeDistance(route)
  state.phase = "active"
  state.active = {
    classId = state.pending.classId,
    classLabel = state.pending.classLabel,
    inventoryId = state.pending.inventoryId,
    vehicleId = state.pending.vehicleId,
    route = route,
    index = 1,
    elapsed = 0,
    repairsLeft = state.pending.repairsLeft or 0,
    repairKitCargoIds = deepcopy(state.pending.repairKitCargoIds or {}),
    repairPenaltySeconds = 0,
    repairsUsed = 0,
    totalDistanceMeters = totalDistance,
    targetSeconds = course.targetTime(totalDistance),
    startedAt = os.time()
  }
  state.pending = nil
  startPromptOpen = false
  clearPoiCache()
  clearGroundRoute()
  hideStartOverlay()
  saveState()
  notify("Dakar started. Navigate to the first checkpoint.", "info")
  emitCheckpointNotification()
  emitPhone()
  emitCompass()
end

local function completeEvent()
  local active = state.active
  if not active then return end
  local adjustedSeconds = active.elapsed + (active.repairPenaltySeconds or 0)
  local placement = course.placementFor(adjustedSeconds, active.totalDistanceMeters, active.targetSeconds)
  local distanceKm = active.totalDistanceMeters / 1000
  local rawBaseReward = math.floor((config.rewards.baseMoney or 5000) + (config.rewards.moneyPerKm or 1000) * distanceKm)
  local rawBonus = math.floor(rawBaseReward * (placement.bonusFactor or 0))
  local baseReward = vehicle.scaleRewardMoney(rawBaseReward)
  local bonus = vehicle.scaleRewardMoney(rawBonus)
  local total = baseReward + bonus
  vehicle.addMoney(total, "Dakar finish reward")

  ensureStats()
  state.stats.totalCompletions = state.stats.totalCompletions + 1
  state.stats.classCompletions[active.classId] = (state.stats.classCompletions[active.classId] or 0) + 1
  if placement.id == "first" then state.stats.totalWins = state.stats.totalWins + 1 end
  if (active.repairsUsed or 0) == 0 then state.stats.noRepairCompletions = state.stats.noRepairCompletions + 1 end

  state.lastResult = {
    placement = placement.label,
    placementId = placement.id,
    elapsedSeconds = active.elapsed,
    adjustedSeconds = adjustedSeconds,
    targetSeconds = active.targetSeconds,
    repairPenaltySeconds = active.repairPenaltySeconds or 0,
    repairsUsed = active.repairsUsed or 0,
    totalDistanceKm = distanceKm,
    classLabel = active.classLabel,
    baseReward = baseReward,
    bonus = bonus,
    totalReward = total
  }
  repairRequest = nil
  releaseKitCargo(active)
  state.phase = "idle"
  state.active = nil
  clearCheckpointMarker()
  hideCompassOverlay()
  saveState()
  saveStore.request("dakar:complete")
  guihooks.trigger("DakarFinishUi", finishPayload())
  emitPhone()
end

local function advanceCheckpoint()
  if not state.active then return end
  Engine.Audio.playOnce("AudioGui", "art/sound/ui_checkpoint.ogg", { volume = 2 })
  if state.active.index >= #state.active.route then
    completeEvent()
  else
    state.active.index = state.active.index + 1
    saveState()
    emitCheckpointNotification()
    emitPhone()
  end
end

function M.useRepairKit()
  if not config or repairRequest then return end
  local requestedConfig = config
  local active = state.active
  if not active or (active.repairsLeft or 0) <= 0 then notify("No Dakar Repair Kits remaining.", "warning") return end
  local key = active.repairKitCargoIds and active.repairKitCargoIds[1]
  if not key or not vehicle.getRepairCargo(key) then
    notify("Dakar Repair Kit cargo is not available.", "warning")
    return
  end
  local vehInfo = active.inventoryId and overhaul_career_garage_inventory.getVehicle(active.inventoryId)
  if not vehInfo or not overhaul_career_repair_insurance or not overhaul_career_repair_insurance.startRepairInstant then
    notify("Dakar repair is not available.", "warning")
    return
  end
  local request = {}
  repairRequest = request
  local function complete(success)
    if config ~= requestedConfig or state.active ~= active or repairRequest ~= request then return end
    repairRequest = nil
    if success == false then
      notify("Dakar repair failed. Your Repair Kit has not been used.", "warning")
      return
    end
    active.repairsLeft = active.repairsLeft - 1
    active.repairsUsed = (active.repairsUsed or 0) + 1
    active.repairPenaltySeconds = (active.repairPenaltySeconds or 0) + (config.repairKit.penaltySeconds or 60)
    table.remove(active.repairKitCargoIds, 1)
    vehicle.removeRepairCargo(key)
    saveState()
    emitPhone()
  end
  local ok = pcall(overhaul_career_repair_insurance.startRepairInstant, vehInfo, complete, true)
  if not ok then complete(false) end
end

function M.abandonEvent()
  if not config or not restoreStateWhenReady() then return end
  if state.phase ~= "active" and state.phase ~= "signedUp" then return end
  releaseKitCargo(state.active or state.pending)
  state.pending = nil
  signupRequest, repairRequest = nil, nil
  state.phase = "failed"
  state.lastFailure = { reason = "abandoned", time = os.time() }
  state.active = nil
  startPromptOpen = false
  clearCheckpointMarker()
  clearGroundRoute()
  hideCompassOverlay()
  saveState()
  notify("Dakar abandoned.", "warning")
  emitPhone()
end

function M.claimAccolade(id)
  if not config or not restoreStateWhenReady() then return end
  ensureStats()
  if state.stats.claimedAccolades[id] then return end
  for _, acc in ipairs(config.accolades or {}) do
    if acc.id == id and accoladeProgress(acc) >= acc.target then
      local reward = acc.reward or {}
      if reward.money then vehicle.addMoney(reward.money, acc.title .. " reward") end
      if reward.vehicle then
        notify(acc.title .. " vehicle reward unlocked. Placeholder config: " .. tostring(reward.vehicle.config), "info")
      end
      state.stats.claimedAccolades[id] = true
      saveState()
      emitMenu()
      return
    end
  end
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  if not config then return end
  if levelIdentifier ~= config.levelId then return end
  loadSites()

  local function addPoi(id, spot, label, action)
    if not spot then return end
    table.insert(elements, {
      id = id,
      clusterType = "activity",
      data = { type = poiPrefix, action = action, id = id, name = label },
      markerInfo = {
        inspectVehicleMarker = {
          pos = spot.pos,
          radius = config.startRadiusMeters or 18,
          vehicleHeight = 4
        },
        bigmapMarker = {
          pos = spot.pos,
          icon = "poi_fasttravel_round_orange_green",
          name = label,
          description = levelLabel .. " Dakar"
        }
      },
      pos = spot.pos,
      radius = config.startRadiusMeters or 18
    })
  end

  addPoi(poiPrefix .. "Registration", spotsByName[config.registrationSpot], "Dakar Registration", "registration")
  if state.phase == "signedUp" then
    addPoi(poiPrefix .. "Start", spotsByName[config.startSpot], "Dakar Start", "start")
  end
end

function M.onActivityAcceptGatherData(elemData, activityData)
  if not config then return end
  for _, elem in ipairs(elemData or {}) do
    if elem.type == poiPrefix and elem.action == "registration" then
      table.insert(activityData, {
        icon = "poi_fasttravel_round_orange_green",
        heading = "Dakar",
        preheadings = { levelLabel },
        sorting = {
          type = elem.type,
          id = "registration"
        },
        buttonLabel = "Event Sign Up",
        buttonFun = function() M.openMenu("signup") end
      })
    elseif elem.type == poiPrefix and elem.action == "start" then
      table.insert(activityData, {
        icon = "poi_fasttravel_round_orange_green",
        heading = "Dakar Start",
        preheadings = { levelLabel },
        sorting = {
          type = elem.type,
          id = "start"
        },
        buttonLabel = "Start Event",
        buttonFun = function() M.startEvent() end
      })
    end
  end
end

local function showCheckpointMarker(cp)
  if not course.isDakarCheckpointSpot(cp) then
    clearCheckpointMarker()
    return
  end
  if activeCheckpointMarkerId == cp.id then return end
  clearCheckpointMarker()
  local marker = createObject("TSStatic")
  if not marker then return end
  marker.shapeName = "art/shapes/race/flagMarkerOrange.dae"
  marker:setPosRot(cp.pos.x, cp.pos.y, cp.pos.z, 0, 0, 0, 0)
  marker.scale = vec3(3, 3, 3)
  local markerName = poiPrefix .. "CheckpointMarker"
  if scenetree.findObject(markerName) then scenetree.findObject(markerName):delete() end
  marker:registerObject(markerName)
  activeCheckpointMarker = marker
  activeCheckpointMarkerId = cp.id
end

function M.onUpdate(dtReal, dtSim)
  if not config or not restoreStateWhenReady() then return end
  if state.phase == "signedUp" and state.pending then
    loadSites()
    local veh = getPlayerVehicle(0)
    local startSpot = spotsByName[config.startSpot]
    if veh and startSpot then
      local distance = (startSpot.pos - veh:getPosition()):length()
      if distance <= (config.startRadiusMeters or 18) then
        if not startPromptOpen then
          startPromptOpen = true
          notify("You are at the Dakar starting line.", "info")
          guihooks.trigger("DakarStartUi", startPayload(distance))
        end
      elseif distance > ((config.startRadiusMeters or 18) * 1.8) then
        startPromptOpen = false
        hideStartOverlay()
      end
    end

    phoneDirtyTimer = phoneDirtyTimer + (dtReal or 0)
    if phoneDirtyTimer > 0.5 then
      phoneDirtyTimer = 0
      emitPhone()
    end
    return
  end

  if state.phase ~= "active" or not state.active then return end
  state.active.elapsed = state.active.elapsed + (dtSim or 0)
  local veh = getPlayerVehicle(0)
  local cp = state.active.route[state.active.index]
  if not cp then
    hideCompassOverlay()
    return
  end
  if not veh or vehicle.currentVehicleInfo() ~= state.active.inventoryId then
    clearCheckpointMarker()
    return
  end

  local distance = (cp.pos - veh:getPosition()):length()
  if distance <= (config.checkpointRevealDistanceMeters or 300) then
    showCheckpointMarker(cp)
  else
    clearCheckpointMarker()
  end
  if distance <= (config.checkpointRadiusMeters or 18) then
    clearCheckpointMarker()
    advanceCheckpoint()
  end

  phoneDirtyTimer = phoneDirtyTimer + (dtReal or 0)
  if phoneDirtyTimer > 0.5 then
    phoneDirtyTimer = 0
    emitPhone()
  end
  compassTimer = compassTimer + (dtReal or 0)
  if compassTimer >= compassInterval then
    compassTimer = compassTimer % compassInterval
    emitCompass()
  end
end

local function reset()
  signupRequest, repairRequest = nil, nil
  loadingState = false
  if state.phase == "signedUp" then clearGroundRoute() end
  clearCheckpointMarker()
  hideStartOverlay()
  hideFinishOverlay()
  hideCompassOverlay()
  config, saveFile, poiPrefix, levelLabel, course, vehicle = nil, nil, nil, nil, nil, nil
  spotsByName = {}
  state = newState()
  phoneDirtyTimer, startPromptOpen = 0, false
end

local function activate()
  reset()
  if not overhaul_career_career.isActive() then return end
  local level = getCurrentLevelIdentifier()
  local metadata = levelData.getMap(level)
  local feature = metadata and metadata.optionalFeatures and metadata.optionalFeatures.dakar
  if not feature or feature.provider ~= "overhaul_events_dakar" then return end
  local path = levelData.assetPath(level, feature.config)
  local data = path and jsonReadFile(path)
  if not data or data.levelId ~= level or type(data.sitesFile) ~= "string" or not FS:fileExists(data.sitesFile) then return end
  config = data
  levelLabel = metadata.label
  poiPrefix = config.poiPrefix or ("dakar_" .. level)
  saveFile = config.saveFile or ("/career/rls_career/" .. level .. "Dakar.json")
  course, vehicle = Course.new(config), Vehicle.new(config)
  loadSites()
  for _, key in ipairs({"registrationSpot", "startSpot", "finishSpot"}) do
    if not spotsByName[config[key]] then
      log("W", poiPrefix, "Dakar config references missing site: " .. key)
      reset()
      return
    end
  end
  loadingState = true
  restoreStateWhenReady()
end

function M.onCareerActivated()
  if not config then activate() end
end

M.onExtensionLoaded = activate
M.onClientStartMission = activate
M.onClientEndMission = reset
M.onOverhaulBeforeSetProfile = reset

function M.onOverhaulActive(active)
  if not active then reset() elseif not config then activate() end
end

function M.onOverhaulSaveCurrentProfile(currentSavePath, _, writer)
  writer = writer or overhaul_career_saveSystem.getSaveWriter()
  local _, previousPath = overhaul_career_saveSystem.getCurrentProfile()
  if previousPath then
    local root = previousPath:gsub('\\', '/'):gsub('^/+', '')
    for _, file in ipairs(FS:findFiles(previousPath .. "/career/rls_career/", "*Dakar.json", 0, true, false) or {}) do
      local relative = file:gsub('\\', '/'):gsub('^/+', ''):sub(#root + 1)
      if relative ~= saveFile then
        local saved = jsonReadFile(file)
        if saved then writer.json(currentSavePath .. relative, saved, true) end
      end
    end
  end
  if config then
    ensureStats()
    -- A map switch may delay freight readiness. Capture the stored state intact
    -- until its kit references can safely be reconciled with restored parcels.
    local previous = savePath()
    local payload = loadingState and previous and jsonReadFile(previous) or encodeForSave()
    return writer.json(currentSavePath .. saveFile, payload or encodeForSave(), true)
  end
end

function M.onExtensionUnloaded()
  reset()
  clearPoiCache()
end

return M
