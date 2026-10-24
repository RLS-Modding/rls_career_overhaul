-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
-- Fork of stock lua/ge/extensions/career/modules/delivery/tasklist.lua (BeamNG 0.40).

-- HUD tasklist for delivery: projects cargo and vehicle offers into tasklist elements and pushes them to the UI.
-- Read dependency binding, sendCargoToTasklist, the per-id update and clear calls, then updateCargoTasklistElements.

local M = {}

-- State -------------------------------------------------------------------------------------------
-- Sibling extensions bound in onCareerActivated; they are not loaded yet when this file runs.
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehicleTasks

-- Binding -----------------------------------------------------------------------------------------
local function bindDeliveryDeps()
  dParcelManager = overhaul_career_logistics_parcelManager
  dCargoScreen = overhaul_career_logistics_cargoScreen
  dGeneral = overhaul_career_logistics_general
  dGenerator = overhaul_career_logistics_generator
  dProgress = overhaul_career_logistics_progress
  dVehicleTasks = overhaul_career_logistics_vehicleTasks
  return dParcelManager and dVehicleTasks
end

M.onCareerActivated = function()
  bindDeliveryDeps()
end

-- HUD helpers and element store -------------------------------------------------------------------
local function ensureHudVisible()
  ui_appContainers.showApp("topLeft", "tasks")
end
M.ensureHudVisible = ensureHudVisible

local function employmentOwnsHudTasklist()
  local emp = overhaul_career_work_employment
  if emp and emp.ownsHudTasklist() then
    return true
  end
  local transfer = overhaul_career_logistics_vehicleTransfer
  return transfer and transfer.ownsHudTasklist() or false
end

-- "<Facility> - <Parking spot name>" without the vanilla _tr fallback bug that yields "- string".
local function pickupLocationLabel(loc)
  local label = loc and dParcelManager.getLocationLabelShort(loc)
  if type(label) ~= "string" or label == "" then label = "the pickup location" end
  if loc and loc.type == "facilityParkingspot" and dGenerator and dGenerator.getParkingSpotByPath then
    local ps = dGenerator.getParkingSpotByPath(loc.psPath)
    local fields = ps and ps.customFields
    local spotName = fields and fields.has and fields:has("name") and fields:get("name") or nil
    if type(spotName) == "string" and spotName ~= "" and spotName ~= "string" then
      spotName = _tr(spotName)
      if type(spotName) == "string" and spotName ~= "" then
        label = string.format("%s - %s", label, spotName)
      end
    end
  end
  return label
end

local cargoIdToTasklistElementId = {}
local offerIdToTasklistElementId = {}
local tasklistElements = {}
local sortedTasklistIds

local function setTasklistElement(id, element)
  if not tasklistElements[id] then sortedTasklistIds = nil end
  tasklistElements[id] = element
end

local function getSortedTasklistIds()
  if not sortedTasklistIds then sortedTasklistIds = tableKeysSorted(tasklistElements) end
  return sortedTasklistIds
end

-- Sending to the tasklist -------------------------------------------------------------------------
local function sendCargoToTasklist()
  if not bindDeliveryDeps() then return end
  ensureHudVisible()
  if employmentOwnsHudTasklist() then
    -- Clear only delivery-owned cards. Employment/CarGo paint their own HUD ids
    -- via guihooks and must be refreshed after this pass.
    for _, elem in pairs(tasklistElements) do
      if elem and (elem.type == "vehicle" or elem.type == "trailer"
          or elem.type == "parcels" or elem.type == "pickup" or elem.type == "header") then
        elem.clear = true
      end
    end
    M.updateCargoTasklistElements()
    local emp = overhaul_career_work_employment
    if emp and emp.ownsHudTasklist() then
      if emp.refreshHudTasklist then
        emp.refreshHudTasklist(true)
      elseif emp.onVehicleTaskStepChanged then
        emp.onVehicleTaskStepChanged()
      end
    end
    local transfer = overhaul_career_logistics_vehicleTransfer
    if transfer and transfer.ownsHudTasklist() and transfer.refreshHudTasklist then
      transfer.refreshHudTasklist(true)
    end
    return
  end

  cargoIdToTasklistElementId = {}
  for _, elem in pairs(tasklistElements) do
    elem.clear = true
  end

  local cargoCount = 0
  local cargoGrouped = {}
  -- HUD creation can replace or unload the map owner before cargo is projected.
  local general = overhaul_career_logistics_general
  for _, cargo in ipairs(general and dParcelManager.getAllCargoInVehicles(false) or {}) do
    local facId = cargo and cargo.destination and (cargo.destination.facId
      or (cargo.destination.destinations and cargo.destination.destinations[1] and cargo.destination.destinations[1].facId))
    local facilityMissing = facId and dGenerator and dGenerator.getFacilityById and not dGenerator.getFacilityById(facId)
    if cargo and cargo.destination and not facilityMissing and general.belongsHere(cargo) then
      local modifiers = cargo.modifiers or {}
      local gId = string.format("%s-%s", dParcelManager.getLocationLabelShort(cargo.destination),
        #modifiers == 0 and "noMods"
        or string.format("%s-%0.2f", cargo.groupId, cargo.loadedAtTimeStamp or -1)
      )
      gId = gId .. (cargo.logisticsPending and "-pending" or "-ready")
      cargoCount = cargoCount + 1
      cargoGrouped[gId] = cargoGrouped[gId] or {}
      table.insert(cargoGrouped[gId], cargo.id)
    end
  end
  for _, gId in ipairs(tableKeysSorted(cargoGrouped)) do
    local tasklistElement = {
      type = "parcels",
      cargoIds = cargoGrouped[gId],
      id = gId,
      update = true,
    }
    setTasklistElement(gId, tasklistElement)
    for _, cId in ipairs(cargoGrouped[gId]) do
      cargoIdToTasklistElementId[cId] = gId
    end
  end

  local transientCount = 0
  local transientPickupLocationGrouped = {}
  for _, cargo in ipairs(dParcelManager.getTransientMoveCargo() or {}) do
    if cargo and cargo.location and cargo.location.type ~= "vehicle" then
      local dId = string.format("%s", dParcelManager.getLocationLabelLong(cargo.location))
      transientCount = transientCount + 1
      transientPickupLocationGrouped[dId] = transientPickupLocationGrouped[dId] or {}
      table.insert(transientPickupLocationGrouped[dId], cargo.id)
    end
  end
  for _, dId in ipairs(tableKeysSorted(transientPickupLocationGrouped)) do
    local tasklistElement = {
      type = "pickup",
      cargoIds = transientPickupLocationGrouped[dId],
      id = dId,
      update = true,
    }
    setTasklistElement(dId, tasklistElement)
    for _, cId in ipairs(transientPickupLocationGrouped[dId]) do
      cargoIdToTasklistElementId[cId] = dId
    end
  end

  local vehicleTaskCount = 0
  for _, taskData in ipairs(dVehicleTasks.getVehicleTasks() or {}) do
    if taskData and taskData.offer and taskData.offer.data then
      local tasklistElement = {
        type = taskData.offer.data.type,
        id = "trailer"..taskData.offer.id,
        update = true,
        taskData = taskData
      }
      setTasklistElement(tasklistElement.id, tasklistElement)
      offerIdToTasklistElementId[taskData.offer.id] = tasklistElement.id
      vehicleTaskCount = vehicleTaskCount + 1
    end
  end

  local hasNonClearElement = false
  for _, elem in pairs(tasklistElements) do
    hasNonClearElement = hasNonClearElement or not elem.clear
  end
  if hasNonClearElement then
    local subtext = ""
    if cargoCount > 0 and vehicleTaskCount == 0 then
      subtext = core_locales.contextTranslate(cargoCount == 1 and "ui.career.delivery.tasklist.itemLoaded" or "ui.career.delivery.tasklist.itemsLoaded", {count = cargoCount})
    else
      local taskCount = cargoCount + vehicleTaskCount + transientCount
      subtext = core_locales.contextTranslate(taskCount == 1 and "ui.career.delivery.tasklist.ongoingTask" or "ui.career.delivery.tasklist.ongoingTasks", {count = taskCount})
    end
    setTasklistElement("header", {
      id = "header",
      update = true,
      type = "header",
      label = _tr("ui.career.delivery.tasklist.activeDeliveries"),
      subtext = subtext
    })
  end

  M.updateCargoTasklistElements()
end
M.sendCargoToTasklist = sendCargoToTasklist

function M.restoreActiveJobGuidance()
  local career = overhaul_career_career
  if not career or not career.isActive() then return end
  bindDeliveryDeps()
  if employmentOwnsHudTasklist() then
    sendCargoToTasklist()
  elseif dGeneral and dGeneral.isDeliveryModeActive() then
    sendCargoToTasklist()
  end
end

local function updateTasklistForCargoId(cargoId)
  if cargoIdToTasklistElementId[cargoId] and tasklistElements[cargoIdToTasklistElementId[cargoId]] then
    tasklistElements[cargoIdToTasklistElementId[cargoId]].update = true
  end
end
M.updateTasklistForCargoId = updateTasklistForCargoId

local function updateTasklistForOfferId(offerId)
  if offerIdToTasklistElementId[offerId] and tasklistElements[offerIdToTasklistElementId[offerId]] then
    tasklistElements[offerIdToTasklistElementId[offerId]].update = true
  end
end
M.updateTasklistForOfferId = updateTasklistForOfferId

local function clearTasklistForOfferId(offerId)
  if offerIdToTasklistElementId[offerId] and tasklistElements[offerIdToTasklistElementId[offerId]] then
    tasklistElements[offerIdToTasklistElementId[offerId]].clear = true
  end
end
M.clearTasklistForOfferId = clearTasklistForOfferId

local function clearAll()
  for _, elem in pairs(tasklistElements) do
    elem.clear = true
  end
end
M.clearAll = clearAll

-- Per-frame update --------------------------------------------------------------------------------
local anyUpdated = false
local elementsToClearById = {}
local function updateCargoTasklistElements()
  if not bindDeliveryDeps() then return end
  anyUpdated = false
  local empOwns = employmentOwnsHudTasklist()

  table.clear(elementsToClearById)
  for _, tasklistId in ipairs(getSortedTasklistIds()) do
    local elem = tasklistElements[tasklistId]
    if elem.clear then
      if elem.type == "parcels" then
        guihooks.trigger("DiscardTasklistItem", elem.id)
      end
      if elem.type == "pickup" then
        guihooks.trigger("DiscardTasklistItem", elem.id)
      end
      if elem.type == "header" then
        if not empOwns then
          guihooks.trigger("SetTasklistHeader", nil)
        end
      end
      if elem.type == "trailer" or elem.type == "vehicle" then
        guihooks.trigger("DiscardTasklistItem", elem.id)
      end
      elementsToClearById[elem.id] = true
    end

    if elem.update and not empOwns then
      anyUpdated = true
      if elem.type == "parcels" then
        local first = dParcelManager.getCargoById(elem.cargoIds[1])
        if first and first.destination then
          local modifierStrings = {core_locales.contextTranslate(#elem.cargoIds == 1 and "ui.career.delivery.tasklist.itemCount" or "ui.career.delivery.tasklist.itemsCount", {count = #elem.cargoIds})}

          for _, mod in ipairs(first.modifiers or {}) do
            if mod.type == "timed" then
              local expiredTime = dGeneral.time() - (first.loadedAtTimeStamp or dGeneral.time())
              if expiredTime <= mod.timeUntilDelayed then
                table.insert(modifierStrings, core_locales.contextTranslate("ui.career.delivery.tasklist.timeRemaining", {seconds = math.floor(mod.timeUntilDelayed - expiredTime)}))
              elseif expiredTime <= mod.timeUntilLate then
                table.insert(modifierStrings, core_locales.contextTranslate("ui.career.delivery.tasklist.delayedTimeRemaining", {seconds = math.floor(mod.timeUntilLate - expiredTime)}))
              else
                table.insert(modifierStrings, _tr("ui.career.delivery.tasklist.late"))
              end
            end
          end
          guihooks.trigger("SetTasklistTask", {
              id = tasklistId,
              label = first.logisticsPending and 'Delivery held — retry vehicle in Logistics.'
                or core_locales.contextTranslate("ui.career.delivery.tasklist.deliverTo", {destination = dParcelManager.getLocationLabelShort(first.destination)}),
              subtext = table.concat(modifierStrings, ", "),
              active = true,
              type = "message"
            }
          )
        end
      end

      if elem.type == "pickup" then
        local first = dParcelManager.getCargoById(elem.cargoIds[1])
        if first and first.location then
          guihooks.trigger("SetTasklistTask", {
              id = tasklistId,
              label = core_locales.contextTranslate(#elem.cargoIds == 1 and "ui.career.delivery.tasklist.pickUpItemFrom" or "ui.career.delivery.tasklist.pickUpItemsFrom", {count = #elem.cargoIds, location = pickupLocationLabel(first.location)}),
              active = true,
              type = "message"
            }
          )
        end
      end

      if elem.type == "trailer" or elem.type == "vehicle" then
        local task = elem.taskData and elem.taskData.tasks and elem.taskData.tasks[elem.taskData.activeTaskIndex]
        if task then
          local label
          if elem.taskData.logisticsPending then
            label = 'Delivery held — restore its vehicle in the Logistics phone app.'
          elseif task.type == "coupleTrailer" then
            label = _tr("ui.career.delivery.tasklist.coupleTrailer")
          elseif task.type == "enterVehicle" then
            label = _tr("ui.career.delivery.tasklist.enterVehicle")
          elseif task.type == "bringToDestination" or task.type == "confirmDropOff" then
            local destLabel = "the destination"
            local dest = task.destination
              or (elem.taskData.offer and elem.taskData.offer.task and (elem.taskData.offer.task.dropOff or elem.taskData.offer.task.destination))
              or (elem.taskData.offer and elem.taskData.offer.destination)
            if dest then
              local short = dParcelManager.getLocationLabelShort(dest)
              if type(short) == "string" and short ~= "" then
                destLabel = short
              elseif dest.facId then
                destLabel = tostring(dest.facId)
              end
            end
            label = core_locales.contextTranslate(elem.type == "trailer" and "ui.career.delivery.tasklist.dropOffTrailerAt" or "ui.career.delivery.tasklist.dropOffVehicleAt", {destination = destLabel})
          elseif task.type == "putIntoParkingSpot" then
            local translationKey = "ui.career.delivery.tasklist.parkTrailer"
            if task.forwardOn == "uncouple" then
              translationKey = "ui.career.delivery.tasklist.parkTrailerAndDecouple"
            elseif task.forwardOn == "exitVehicle" then
              translationKey = "ui.career.delivery.tasklist.parkTrailerAndExitVehicle"
            end
            label = core_locales.contextTranslate(translationKey, {
              destination = dParcelManager.getLocationLabelShort(task.destination)
            })
          end
          local veh = elem.taskData.offer and elem.taskData.offer.vehicle or {}
          local name = veh.name
          local brand = veh.brand
          if (not name or name == "") and elem.taskData.vehId and dGeneral and dGeneral.getVehicleName then
            name = dGeneral.getVehicleName(elem.taskData.vehId)
          end
          if not name or name == "" then
            name = veh.model or "Vehicle"
          end
          local subtext = tostring(name)
          if elem.type == "vehicle" and brand and brand ~= "" then
            subtext = string.format("%s %s", tostring(brand), tostring(name))
          end
          guihooks.trigger("SetTasklistTask", {
              id = tasklistId,
              label = label,
              subtext = subtext,
              active = true,
              type = "message"
            }
          )
        end
      end

      if elem.type == "header" then
        guihooks.trigger("SetTasklistHeader", {
          label = elem.label,
          subtext = elem.subtext
        })
      end
      elem.update = false
    elseif elem.update and empOwns then
      elem.update = false
    end
  end

  for id, _ in pairs(elementsToClearById) do
    local element = tasklistElements[id]
    -- Reverse lookups belong to the card; finished deliveries must not leave
    -- one entry per historical cargo item or vehicle offer in this owner.
    for _, cargoId in ipairs(element and element.cargoIds or {}) do
      if cargoIdToTasklistElementId[cargoId] == id then cargoIdToTasklistElementId[cargoId] = nil end
    end
    local offerId = element and element.taskData and element.taskData.offer.id
    if offerId and offerIdToTasklistElementId[offerId] == id then offerIdToTasklistElementId[offerId] = nil end
    if tasklistElements[id] then sortedTasklistIds = nil end
    tasklistElements[id] = nil
  end
end
M.updateCargoTasklistElements = updateCargoTasklistElements

M.onUpdate = function(dtReal, dtSim, dtRaw)
  if employmentOwnsHudTasklist() then return end
  M.updateCargoTasklistElements()
end

return M
