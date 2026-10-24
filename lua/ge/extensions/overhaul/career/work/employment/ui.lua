-- Employment presentation: listings, assignments, damage status and tasklist guidance for the UI.
-- Reading order: translation and formatting, task publication, guidance phases and UI refresh.
local M = {}

local phoneLayout = require("overhaul/lib/phone/layoutOwner")
-- Config ------------------------------------------------------------------------------------------

local BUNDLE_TASK_ROLES = {
  vehicle = {taskKey = "vehicle", liveAlways = true},
  repo = {taskKey = "repo", liveAfterVehicleComplete = true, usesRepoGuidance = true},
}

local TASK = {
  id = "employment-shift",
  main = "employment-shift-main",
  vehicle = "employment-shift-vehicle",
  repo = "employment-shift-repo",
  ending = "employment-shift-ending",
}
local TASK_IDS = { TASK.id, TASK.main, TASK.vehicle, TASK.repo, TASK.ending }
local PHONE_NOTIF_SOUND = { soundClass = "AudioGui", type = "event:>UI>Missions>Info_Open" }

-- State -------------------------------------------------------------------------------------------

-- Last published values, so unchanged guidance is not re-sent every frame.
local lastTaskSignature = nil
local lastSpawnActionSignature = nil
local endingTaskVisible = false

M.TASK = TASK
M.TASK_IDS = TASK_IDS

-- Formatting --------------------------------------------------------------------------------------

function M.resetTasklistCache()
  endingTaskVisible = false
  lastTaskSignature = nil
  lastSpawnActionSignature = nil
end

-- Returns the translator's string, or nil when it is missing, fails or returns nothing.
local function translatedBy(translator, value)
  if type(translator) ~= "function" then return nil end
  local ok, translated = pcall(translator, value)
  if ok and type(translated) == "string" and translated ~= "" then return translated end
  return nil
end

function M.translateText(value, fallback)
  if type(value) ~= "string" or value == "" then
    return fallback or value
  end
  local translated = translatedBy(_tr, value) or translatedBy(translate, value)
  if translated then return translated end
  translated = core_locales.translateWithOrWithoutContext(value)
  if type(translated) == "string" and translated ~= "" then
    return translated
  end
  return fallback or value
end

function M.orgDisplayName(org, orgId)
  return M.translateText(org and org.name, orgId or "Company")
end

function M.reputationLabel(org, level)
  level = tonumber(level)
  local info = org and org.reputationLevels and org.reputationLevels[level + 2]
  if type(info) == "table" and type(info.label) == "string" and info.label ~= "" then
    return info.label
  end
  return nil
end

function M.commissionPercent(companyShare)
  return math.floor(math.min(1, math.max(0, 1 - companyShare)) * 100 + 0.5)
end

function M.formatDamageStatus(strikes, warnMax, dockMax, dockPercent)
  strikes = tonumber(strikes) or 0
  if strikes <= 0 then return nil end
  warnMax = tonumber(warnMax) or 0
  dockMax = tonumber(dockMax) or 0
  if strikes <= warnMax then
    return {
      strikes = strikes,
      phase = "warning",
      detail = string.format("Warning %d of %d", strikes, warnMax),
      warnMax = warnMax,
      dockMax = dockMax,
    }
  end
  if strikes <= warnMax + dockMax then
    return {
      strikes = strikes,
      phase = "dock",
      detail = string.format("Pay dock %d of %d (~%d%% of held wages)", strikes - warnMax, dockMax, math.floor((tonumber(dockPercent) or 0) * 100 + 0.5)),
      warnMax = warnMax,
      dockMax = dockMax,
    }
  end
  return {
    strikes = strikes,
    phase = "terminated",
    detail = "Repeated equipment damage",
    warnMax = warnMax,
    dockMax = dockMax,
  }
end

function M.offeringsWorkSummary(offerings)
  local bits = {}
  for _, offering in ipairs(offerings or {}) do
    if offering and offering.label then
      table.insert(bits, offering.label)
    end
  end
  return #bits > 0 and table.concat(bits, ", ") or "assigned loads"
end

function M.formatListing(view)
  if not view then return nil end
  local offerings = view.offerings
  local skillLocked = view.skillLocked and true or false
  return {
    orgId = view.orgId,
    orgName = view.orgName,
    facId = view.facId,
    facName = view.facName,
    workSummary = M.offeringsWorkSummary(offerings),
    offerings = offerings,
    employerProfile = view.employerProfile,
    sideWork = false,
    rehireBlocked = view.rehireBlocked,
    rehireDaysRemaining = view.rehireDaysRemaining,
    skillLocked = skillLocked,
    preview = view.preview,
    requiredLevel = view.requiredLevel,
    skillMessage = skillLocked
      and (view.skillMessage or "You can't take work at this yard with your current unlocks yet.")
      or nil,
  }
end

function M.formatAssignedVehicles(entries, inventory)
  if not entries or not inventory then return {} end
  local result = {}
  for _, entry in ipairs(entries) do
    local info = inventory.getVehicle(entry.id)
    if info then
      local thumbnail = inventory.getVehicleThumbnail(entry.id) or nil
      if thumbnail and info.dirtyDate then thumbnail = thumbnail .. "?" .. tostring(info.dirtyDate) end
      result[#result + 1] = {
        inventoryId = entry.id,
        name = inventory.getVehicleNiceNameTranslated(entry.id)
          or info.niceName or info.model or "Vehicle",
        thumbnail = thumbnail or "/ui/images/appDefault.png",
        role = entry.role,
      }
    end
  end
  return result
end

function M.formatAccident(view)
  if not view then return nil end
  return {
    label = view.label or "Accident recovery",
    subtext = view.subtext or "Replacement equipment is being issued",
    canClaim = view.canClaim and true or false,
    spawning = view.spawning and true or false,
  }
end

-- Subtext for a shift underway: stop count, distributor vehicles left, or the default finish line.
local function inProgressSubtext(view)
  local subtext = view.phase == "outbound" and view.outboundSubtext
    or "Finish this assignment. End day marks it as your final assignment."
  if view.stringMode and view.hasStops and view.phase == "outbound" then
    local n = math.max(tonumber(view.stringStopTotal) or 0, tonumber(view.stopCount) or 0)
    local i = math.min(view.stopIndex or 1, math.max(n, 1))
    if n > 0 then subtext = string.format("Stop %d of %d · %s", i, n, subtext or "parcels") end
  end
  if view.isDistributorHaul and view.phase == "outbound" then
    local remaining = tonumber(view.distributorRemaining) or 0
    if remaining > 0 then
      subtext = string.format("%d vehicle%s left · company truck and trailer", remaining, remaining == 1 and "" or "s")
    end
  end
  return subtext
end

function M.assignmentDescription(view)
  local label, subtext
  local busState = view.busState
  if view.held then
    label = "Held assignment"
    subtext = view.outboundLabel or "Clock in to continue this job"
  elseif view.spawnBlocked then
    label = view.spawnBlockedReady and "Ready to spawn" or "Spawn area blocked"
    subtext = "Clear the highlighted stalls, then select Spawn vehicle"
  elseif view.useParamedicGuidance then
    local guidance = view.paramedicGuidance
    label, subtext = guidance.label, guidance.subtext
  elseif busState and busState.paused then
    label, subtext = "Bus route paused", "Return to your bus to continue the route"
  elseif busState and view.endAfterAssignment then
    label = "Finishing bus shift"
    subtext = string.format("Drop off your %d passengers at the next stop to collect pay. No new passengers will board.", busState.passengers)
  elseif busState then
    local guidance = view.busGuidance
    label = guidance and guidance.label or view.outboundLabel or "Bus routes"
    subtext = guidance and guidance.subtext or "End Day pays immediately when empty, or after dropping off remaining passengers at the next stop."
  elseif view.openEnded then
    label = view.outboundLabel or "On company time"
    subtext = view.outboundSubtext or "End day anytime to collect today's wages and return the company vehicle"
  elseif view.phase == "loopComplete" or view.wrecked then
    label = view.returnLabel or "Assignment complete"
    subtext = view.returnSubtext or "Take another job or end your day"
  elseif view.phase == "return" then
    if view.returnIsBackhaul and view.assignedReturnCargoInVehicle then
      label = view.returnDeliverLabel or view.returnLabel or "Deliver return parcels"
    else
      label = view.returnLabel or "Return to the company yard"
    end
    subtext = view.returnSubtext or "Deliver the return load, then choose your next job or end the day"
  elseif view.isBundle and view.inProgress then
    label = view.outboundLabel or "Two company assignments"
    subtext = view.outboundSubtext or "Complete both assignments in any order"
  elseif view.inProgress then
    label = view.outboundLabel or "Continue the company assignment"
    subtext = inProgressSubtext(view)
  elseif view.phase == "outbound" then
    label = view.outboundLabel
    subtext = view.outboundSubtext
  else
    label = view.returnLabel
    subtext = view.returnSubtext
  end
  return label, subtext
end

function M.formatAssignment(view)
  if not view then return nil end
  local label, subtext = M.assignmentDescription(view)
  local held = view.held and true or false
  local spawnBlocked = view.spawnBlocked and true or false
  local inProgress = view.inProgress and true or false
  return {
    phase = view.phase,
    jobKind = view.jobKind,
    cargoType = view.cargoType,
    label = label,
    subtext = subtext,
    loopComplete = view.loopComplete,
    wrecked = view.wrecked and true or false,
    held = held,
    endAfterAssignment = view.endAfterAssignment == true,
    busShift = view.busState,
    canEndBusShiftNow = view.canEndBusShiftNow,
    openEnded = view.openEnded,
    holdsOnEndDay = view.holdsOnEndDay,
    spawnBlocked = spawnBlocked,
    canSpawnBlockedEquipment = view.canSpawnBlockedEquipment,
    accident = view.accident,
    canReportAccident = view.canReportAccident,
    awaitingPark = view.awaitingPark and true or false,
    vehiclesParked = view.vehiclesParked and true or false,
    yardDropOffPending = view.yardDropOffPending == true,
    canEndDay = view.canEndDay,
    canAbandonAssignment = view.canAbandonAssignment,
    abandonFine = view.abandonFine,
    canNextRun = view.canNextRun,
    dropOffEscrowPending = view.dropOffEscrowPending and true or false,
    canContinue = view.canContinue,
    inProgress = inProgress,
    shiftAssignments = view.shiftAssignments,
    bundle = view.isBundle and true or false,
    stringMode = view.stringMode and true or false,
    stopIndex = view.stopIndex,
    stopCount = view.stopCount,
  }
end

function M.formatUiState(view)
  if not view then return nil end
  return {
    employed = view.employed,
    onShift = view.onShift,
    roleplayFacility = view.roleplayFacility,
    roleplaySetup = view.roleplaySetup,
    canClockInHere = view.canClockInHere,
    employerOrgId = view.employerOrgId,
    employerName = view.employerName,
    employerPreview = view.employerPreview,
    employerRepLevel = view.employerRepLevel,
    employerRepLabel = view.employerRepLabel,
    commissionPercent = view.commissionPercent,
    employerOfferings = view.employerOfferings,
    companyVehicles = view.companyVehicles,
    assignedVehicles = view.assignedVehicles,
    shiftStartPending = view.shiftStartPending,
    shiftStartReady = view.shiftStartReady,
    logisticsEmployerOrgId = view.logisticsEmployerOrgId,
    logisticsEmployerName = view.logisticsEmployerName,
    homeFacId = view.homeFacId,
    pending = view.pending,
    assignment = view.assignment,
    canReportAccident = view.canReportAccident,
    escrowMoney = view.escrowMoney,
    escrowLegs = view.escrowLegs,
    surgeBonusHeld = view.surgeBonusHeld,
    damageStrikeCount = view.damageStrikeCount,
    showDamageNotice = view.showDamageNotice,
    damageStatus = view.damageStatus,
    listings = view.listings,
    atEmployerYard = view.atEmployerYard,
    deliveryLevel = view.deliveryLevel,
    skillLevel = view.skillLevel,
    skillLabel = view.skillLabel,
    unlocked = view.unlocked,
    apprenticeship = view.apprenticeship,
    independentCargoLevel = view.independentCargoLevel,
    devTools = view.devTools,
    headhunterOffer = view.headhunterOffer,
  }
end

function M.employerTasklistHeader(view)
  local facName = view and view.facName
  if type(facName) == "string" and facName ~= "" then
    return M.translateText(facName, facName)
  end
  return (view and view.orgName) or (view and view.orgId) or "Company"
end

function M.firePhoneNotification(channelKey, title, message, kind, extra, opts)
  local layout = phoneLayout.get()
  if not layout then return end
  local payload = {
    title = title,
    message = message,
    kind = kind or "invite",
    ttl = 10,
    source = "Employment",
    sound = PHONE_NOTIF_SOUND,
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      payload[key] = value
    end
  end
  layout.fireNotification(channelKey, payload, opts)
end

-- Tasklist ----------------------------------------------------------------------------------------

function M.clearTaskGuidance(hooks)
  endingTaskVisible = false
  hooks = hooks or guihooks
  if hooks then
    hooks.trigger("EmploymentSpawnAction", {visible = false})
    for _, id in ipairs(TASK_IDS) do
      hooks.trigger("DiscardTasklistItem", id)
    end
    hooks.trigger("DiscardTasklistItem", "bus_passenger_count")
    hooks.trigger("SetTasklistHeader", nil)
  end
  lastTaskSignature = nil
end

local function publishSpawnAction(hooks, shift, force)
  local spawnAction = {
    visible = shift ~= nil and shift.spawnBlocked ~= nil and not shift.paused,
    ready = shift and shift.spawnBlocked and shift.spawnBlocked.ready == true
      and not shift.spawnBlocked.retryInFlight or false,
  }
  local spawnSignature = tostring(spawnAction.visible) .. tostring(spawnAction.ready)
  if force or spawnSignature ~= lastSpawnActionSignature then
    if hooks then hooks.trigger("EmploymentSpawnAction", spawnAction) end
    lastSpawnActionSignature = spawnSignature
  end
end

local function purgeIndependent(guidance)
  if guidance.purgeIndependent then guidance.purgeIndependent() end
end

-- One tasklist entry; `done` is passed only by items that track completion.
local function publishTask(hooks, id, label, subtext, done)
  hooks.trigger("SetTasklistTask", {
    id = id,
    label = label,
    subtext = subtext,
    done = done,
    active = true,
    type = "message",
    clear = false,
  })
end

-- One message task for the vehicle step; parking and blocked spawns both use it.
local function publishMessageTask(hooks, header, label, subtext)
  if not hooks then return end
  hooks.trigger("SetTasklistHeader", { label = header })
  hooks.trigger("DiscardTasklistItem", TASK.vehicle)
  hooks.trigger("DiscardTasklistItem", TASK.repo)
  publishTask(hooks, TASK.main, label, subtext)
end

local function showMessageTask(header, hooks, force, label, subtext, tag)
  local signature = table.concat({label, subtext, tag}, "|")
  if force or signature ~= lastTaskSignature then
    publishMessageTask(hooks, header, label, subtext)
    lastTaskSignature = signature
  end
end

-- Bundle roles mirror their live step (vehicle position) once the rule's condition holds.
local function bundleRoleIsLive(role, shift)
  return role and (role.liveAlways
    or (role.liveAfterVehicleComplete and shift.assignments and shift.assignments.vehicle and shift.assignments.vehicle.complete))
end

local function publishBundleItem(hooks, item, shift, vehInfo, repoGuidance)
  local role = BUNDLE_TASK_ROLES[item.id]
  local taskId = TASK[role and role.taskKey or "vehicle"]
  if item.complete then
    hooks.trigger("DiscardTasklistItem", taskId)
    return
  end
  local label = item.label or ""
  local subtext = item.subtext or ""
  local liveInfo = bundleRoleIsLive(role, shift) and vehInfo
  if liveInfo then
    local needsEnter = (liveInfo.stepType == "enterVehicle" and not liveInfo.inCargoVehicle)
      or (liveInfo.stepType == "bringToDestination" and not liveInfo.inCargoVehicle and not liveInfo.haulAcquired)
    if needsEnter then
      label = "Enter the assigned vehicle"
      subtext = "Then deliver it to the marked destination"
    elseif liveInfo.stepType == "confirmDropOff" then
      label = item.label or "Drop off the vehicle"
      subtext = "Use the marked drop-off"
    end
  end
  if role and role.usesRepoGuidance and not liveInfo then
    if repoGuidance then
      label = repoGuidance.label or label
      subtext = repoGuidance.subtext or subtext
    else
      subtext = "Get in the company flatbed to start"
    end
  end
  publishTask(hooks, taskId, label, subtext, false)
end

local function bundleItemSignature(item, shift, vehInfo, repoGuidance)
  local live = ""
  local role = BUNDLE_TASK_ROLES[item.id]
  if vehInfo and bundleRoleIsLive(role, shift) then
    live = tostring(vehInfo.stepType) .. "|" .. tostring(vehInfo.inCargoVehicle) .. "|" .. tostring(vehInfo.haulAcquired)
  end
  return (item.complete and "done|" or "open|") .. tostring(item.id) .. "|" .. tostring(item.label) .. "|" .. tostring(repoGuidance and repoGuidance.label) .. "|" .. tostring(repoGuidance and repoGuidance.subtext) .. "|" .. live
end

local function showBundleTasks(guidance, hooks, force, shift, header)
  local items = guidance.bundleItems or {}
  local repo = guidance.getRepo and guidance.getRepo()
  local repoActive = repo and repo.isEmploymentRepoActive()
  local repoGuidance = repoActive and repo.getEmploymentTaskGuidance() or nil
  local vehInfo = guidance.getVehicleTaskInfo and guidance.getVehicleTaskInfo()
  local bits = {}
  for _, item in ipairs(items) do
    table.insert(bits, bundleItemSignature(item, shift, vehInfo, repoGuidance))
  end
  local signature = table.concat({header, table.concat(bits, ";"), tostring(shift.phase)}, "|")
  if force or signature ~= lastTaskSignature then
    purgeIndependent(guidance)
    if hooks then
      hooks.trigger("SetTasklistHeader", { label = header })
      hooks.trigger("DiscardTasklistItem", TASK.id)
      hooks.trigger("DiscardTasklistItem", TASK.main)
      for _, item in ipairs(items) do
        publishBundleItem(hooks, item, shift, vehInfo, repoGuidance)
      end
    end
    lastTaskSignature = signature
  end
end

local function showMainTask(guidance, hooks, force, header, label, subtext, shift)
  local signature = table.concat({header, label, subtext, tostring(shift.phase)}, "|")
  if force or signature ~= lastTaskSignature then
    purgeIndependent(guidance)
    if hooks then
      hooks.trigger("SetTasklistHeader", { label = header })
      hooks.trigger("DiscardTasklistItem", TASK.id)
      hooks.trigger("DiscardTasklistItem", TASK.vehicle)
      hooks.trigger("DiscardTasklistItem", TASK.repo)
      publishTask(hooks, TASK.main, label, subtext)
    end
    lastTaskSignature = signature
  end
end

-- Guidance phases --------------------------------------------------------------------------------

local function showParkGuidance(guidance, hooks, force)
  purgeIndependent(guidance)
  local holding = guidance.assignmentStillInProgress
  local label = "Park the company vehicle"
  local subtext = holding and "Put it in the marked stall to hold this assignment" or "Put it in the marked stall to clock out"
  showMessageTask(guidance.header, hooks, force, label, subtext, "park")
end

local function showSpawnBlockedGuidance(guidance, hooks, force, spawnBlocked)
  purgeIndependent(guidance)
  local label = spawnBlocked.ready and "Ready to spawn" or "Clear the spawn area"
  local subtext = "Clear the highlighted stalls, then select Spawn vehicle"
  showMessageTask(guidance.header, hooks, force, label, subtext, "spawnBlocked")
end

-- The owner's own tasklist takes over; this file only clears its items.
local function handOffToOwnerTasklist(guidance, hooks)
  purgeIndependent(guidance)
  if hooks then
    for _, id in ipairs(TASK_IDS) do
      if id ~= TASK.ending then hooks.trigger("DiscardTasklistItem", id) end
    end
  end
  lastTaskSignature = nil
  if guidance.handoffPolice then guidance.handoffPolice() end
end

local function materialsContractActive(guidance)
  local active = guidance.getMaterialsActive and guidance.getMaterialsActive()
  return active and active.status == "active"
end

local function roleplayGuidance(guidance, shift)
  local busGuidance = (guidance.policy.kindPolicy(shift.jobKind).roleplay and not guidance.policy.kindPolicy(shift.jobKind).emergency) and guidance.getBusGuidance and guidance.getBusGuidance() or nil
  local ambulanceGuidance = (guidance.policy.kindPolicy(shift.jobKind).roleplay and guidance.policy.kindPolicy(shift.jobKind).emergency) and guidance.getAmbulanceGuidance and guidance.getAmbulanceGuidance() or nil
  return busGuidance, ambulanceGuidance
end

local function repossessionText(guidance, shift)
  if shift.repoPendingStart then
    return "Get in the company flatbed", "The dispatcher is waiting to assign a pickup"
  end
  local repo = guidance.getRepo and guidance.getRepo()
  local repoTask = repo and repo.getEmploymentTaskGuidance()
  if repoTask then
    return repoTask.label, repoTask.subtext
  end
  return shift.outboundLabel or "Pickup — haul a vehicle back to the yard", shift.outboundSubtext or "Pick it up with the company flatbed"
end

local function outboundText(shift)
  local label = shift.outboundLabel or "Deliver the assigned load"
  local subtext = shift.outboundSubtext or "Company assignment"
  if shift.stringMode and shift.stops then
    local n = math.max(tonumber(shift.stringStopTotal) or 0, #shift.stops)
    local i = math.min(shift.stopIndex or 1, math.max(n, 1))
    if n > 0 and not (shift.outboundLabel and shift.outboundLabel:find("Stop ", 1, true) == 1) then
      label = string.format("Stop %d/%d · %s", i, n, label)
    end
    subtext = shift.outboundSubtext or (n > 0 and string.format("Stop %d of %d", i, n) or subtext)
  end
  return label, subtext
end

local function returnText(guidance, shift)
  local label
  if shift.returnIsBackhaul and guidance.assignedReturnCargoInVehicle then
    if guidance.clearReturnNeedsPickup then guidance.clearReturnNeedsPickup() end
    label = shift.returnDeliverLabel or shift.returnLabel or "Deliver return load"
  else
    label = shift.returnLabel or "Return to the company yard"
  end
  local subtext = shift.returnSubtext
    or (shift.awaitingLoopChoice and "Then choose your next job or end the day")
    or "Company return"
  return label, subtext
end

-- First match wins: roleplay guidance, then phase, then accident and wreck states.
local function shiftLabelAndSubtext(guidance, shift, busGuidance, ambulanceGuidance)
  if busGuidance then return busGuidance.label, busGuidance.subtext end
  if ambulanceGuidance then return ambulanceGuidance.label, ambulanceGuidance.subtext end
  if shift.phase == "active" then
    return shift.outboundLabel or "On company time",
      shift.outboundSubtext or "End day to collect today's wages and return the company vehicle"
  end
  if guidance.policy.kindPolicy(shift.jobKind).repossession and shift.phase == "outbound" then
    return repossessionText(guidance, shift)
  end
  if guidance.accidentTask then
    local accidentTask = guidance.accidentTask
    return accidentTask and accidentTask.label or "Accident recovery", accidentTask and accidentTask.subtext or ""
  end
  if shift.wrecked then
    return "Return the company vehicle to the yard", "Equipment is too damaged for another load"
  end
  if shift.phase == "outbound" then return outboundText(shift) end
  if shift.phase == "return" then return returnText(guidance, shift) end
  return "On company time", ""
end

local function refreshTaskGuidance(guidance, force)
  local hooks = guidance.guihooks or guihooks
  local shift = guidance.shift
  publishSpawnAction(hooks, shift, force)
  if not shift then
    M.clearTaskGuidance(hooks)
    return
  end
  if shift.awaitingPark then
    showParkGuidance(guidance, hooks, force)
    return
  end
  if shift.spawnBlocked then
    showSpawnBlockedGuidance(guidance, hooks, force, shift.spawnBlocked)
    return
  end
  if shift.paused then
    M.clearTaskGuidance(hooks)
    return
  end
  if shift.phase == "loopComplete" then
    M.clearTaskGuidance(hooks)
    purgeIndependent(guidance)
    return
  end
  if guidance.policy.kindPolicy(shift.jobKind).materialContract and materialsContractActive(guidance) then
    M.clearTaskGuidance(hooks)
    purgeIndependent(guidance)
    return
  end
  if guidance.policy.kindPolicy(shift.jobKind).ownerTasklist then
    handOffToOwnerTasklist(guidance, hooks)
    return
  end
  local header = guidance.header
  if guidance.isBundle then
    showBundleTasks(guidance, hooks, force, shift, header)
    return
  end
  local busGuidance, ambulanceGuidance = roleplayGuidance(guidance, shift)
  local label, subtext = shiftLabelAndSubtext(guidance, shift, busGuidance, ambulanceGuidance)
  showMainTask(guidance, hooks, force, header, label, subtext, shift)
end

function M.refreshTaskGuidance(guidance, force)
  guidance = guidance or {}
  refreshTaskGuidance(guidance, force)
  local shift = guidance.shift
  local hooks = guidance.guihooks or guihooks
  local ending = shift ~= nil and shift.endAfterAssignment == true and not shift.paused and shift.phase ~= "loopComplete"
  if hooks and (force or ending ~= endingTaskVisible) then
    if ending then
      publishTask(hooks, TASK.ending, "Final assignment", "Finish your current assignment to collect pay and clock out.")
    else
      hooks.trigger("DiscardTasklistItem", TASK.ending)
    end
    endingTaskVisible = ending
  end
end

return M
