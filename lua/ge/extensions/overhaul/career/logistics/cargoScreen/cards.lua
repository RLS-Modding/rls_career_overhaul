-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Cargo-screen cards: builds the card records the cargo screen UI reads, and keeps the card store.
-- Owned by career/logistics/cargoScreen.lua, which builds this part with part.new(inputs).
-- Part of the Overhaul fork of stock `lua/ge/extensions/career/modules/delivery/cargoScreen.lua`.
--
-- Map, in reading order:
--   card store: addCard and cardsById; the owner-operator card and its per-diem block
--   owner-operator cards: the active contract's task, destination, markers and route
--   group formatting: baseCargoRecord, addBigMapIds, addModifiers, addLoadTargets, formatCargoGroup
--   clustering: clusterFormatCargo groups cargo by group id and arrival time, then formats each group
--   vehicle offers: formatVehicleOfferForUi (facility offers) and formatAcceptedOfferForUI (accepted offers)
--   accepted offers: getAcceptedVehicleOffers, the player vehicles and offers that spawn on commit

local part = {}
local templates = require('overhaul/lib/logistics/templates')

-- Built once per cargo screen load; the card store lives in this closure.
function part.new(inputs)
  local ext, sharedCalc = inputs.ext, inputs.sharedCalc

  -- Card store --------------------------------------------------------------------------------------

  local cardsById = {}

  local CARD_ID_PREFIX_BY_TYPE = {
    parcelGroup = "pg-",
    storage = "st-",
    materialContractOffer = "mc-",
    passiveBusinessSupplyOffer = "pb-",
    engineShopSupplyOffer = "es-",
    vehicleOffer = "vo-",
    loaner = "lo-",
  }

  local function addCard(data)
    local id = data.isFacilityCard and "F-" or "P-"
    local typePrefix = CARD_ID_PREFIX_BY_TYPE[data.cardType]
    if typePrefix then
      id = id .. typePrefix .. data.id
    end
    data.cardId = id
    cardsById[data.cardId] = data
  end

  local OWNER_OP_PER_DIEM_BLOCK = {
    type = "ownerOp",
    label = "Finish your owner-operator contract before taking per diem jobs.",
  }

  local function getActiveOwnerOpContract()
    local ooc = overhaul_career_logistics_ownerOpContracts
    if not ooc or not ooc.getActiveContract then return nil end
    return ooc.getActiveContract()
  end

  local function ownerOpBlocksPerDiemOffer(offer)
    local active = getActiveOwnerOpContract()
    if not active then return false end
    if offer and offer.data and offer.data.finkContractId and tostring(offer.data.finkContractId) == tostring(active.id) then
      return false
    end
    if offer and active.nativeMaterialContractId then
      local contractId = offer.data and offer.data.materialContractId or offer.id
      return contractId ~= active.nativeMaterialContractId
    end
    if not offer or not active.originFacId or not offer.origin or offer.origin.facId ~= active.originFacId then return true end
    if active.kind ~= 'hubDistribute' and active.kind ~= 'hubAB' and active.kind ~= 'bpsHub'
      and active.kind ~= 'bpsAB' and active.kind ~= 'bpsPort' then return true end
    if offer.materialType then return true end
    local template = offer.templateId and templates.getTemplateById(offer.templateId)
    local logisticType = offer.lookupType or offer.logisticType or (template and template.logisticType)
    if not logisticType or logisticType ~= active.logisticType then return true end
    local destination = offer.destination or (offer.task and offer.task.destination)
    local function matches(location)
      if not location then return false end
      if not active.stringMode then return location.facId == active.destFacId end
      for _, stop in ipairs(active.stops or {}) do
        if location.facId == stop.destFacId then return true end
      end
      return false
    end
    if matches(destination) then return false end
    for _, location in ipairs(destination and destination.destinations or {}) do
      if matches(location) then return false end
    end
    return true
  end

  -- Owner-operator cards ----------------------------------------------------------------------------

  local function ownerOpTaskLabel(active, phase)
    if active.kind == "finkHaul" then
      if phase == "planTrip" then
        return "Plan a yard trip in the Logistics phone app"
      elseif phase == "staging" then
        return "Cars are staging at the distributor yard"
      elseif phase == "hauling" then
        return string.format(
          "Haul staged cars · %d pending · %d staged · %d delivered",
          active.pendingCount or 0,
          active.stagedCount or 0,
          active.deliveredCount or 0
        )
      end
      return "Owner-operator car haul in progress"
    elseif phase == "pickup" then
      return "Pick up at the marked origin"
    elseif phase == "dropoff" then
      return "Deliver to the marked destination"
    end
    return "Owner-operator contract in progress"
  end

  local function ownerOpDestinationName(active)
    if active.kind == "finkHaul" and type(active.destinations) == "table" and active.destinations[1] then
      if #active.destinations == 1 then
        return active.destinations[1].name or "Contract destinations"
      end
      return string.format("%d dealerships", #active.destinations)
    elseif active.destFacName then
      return active.destFacName
    elseif active.destinationName then
      return active.destinationName
    elseif active.destFacId then
      return tostring(active.destFacId)
    end
    return "Contract destinations"
  end

  local function ownerOpBigMapIds(active)
    local bigMapIds = {}
    if active.originFacId and active.originPsPath then
      bigMapIds[string.format("delivery-parking-%s-%s", active.originFacId, active.originPsPath)] = true
    end
    if active.kind == "finkHaul" then
      for _, veh in ipairs(active.vehicles or {}) do
        if veh.destFacId and veh.destPsPath and veh.status ~= "delivered" then
          bigMapIds[string.format("delivery-parking-%s-%s", veh.destFacId, veh.destPsPath)] = true
        end
      end
    elseif active.destFacId and active.destPsPath then
      bigMapIds[string.format("delivery-parking-%s-%s", active.destFacId, active.destPsPath)] = true
    end
    return bigMapIds
  end

  -- Runs from the origin to the destination, or to the first car's stop on a car haul without one.
  local function ownerOpRoute(active)
    local originLoc = {
      type = "facilityParkingspot",
      facId = active.originFacId,
      psPath = active.originPsPath,
    }
    local destLoc = originLoc
    if active.destFacId then
      destLoc = {
        type = "facilityParkingspot",
        facId = active.destFacId,
        psPath = active.destPsPath,
      }
    elseif active.kind == "finkHaul" and active.vehicles and active.vehicles[1] then
      local veh = active.vehicles[1]
      if veh.destFacId then
        destLoc = {
          type = "facilityParkingspot",
          facId = veh.destFacId,
          psPath = veh.destPsPath,
        }
      end
    end
    return {type = "navgraph", locations = {originLoc, destLoc}}
  end

  local function addActiveOwnerOpMyCargoCards()
    local active = getActiveOwnerOpContract()
    if not active then return end

    local phase = active.phase or "active"
    local card = {
      id = "ownerOpActive-" .. tostring(active.id),
      name = active.kind == "finkHaul"
        and string.format("Owner-op haul · %d cars", active.qty or #(active.vehicles or {}))
        or (active.title or "Owner-operator contract"),
      cardType = "vehicleOffer",
      vehOfferType = "vehicle",
      isPlayerCard = true,
      destinationName = ownerOpDestinationName(active),
      distance = 0,
      rewardMoney = active.pay or 0,
      rewards = {money = active.pay or 0},
      enabled = true,
      taskList = {ownerOpTaskLabel(active, phase)},
      thumbnail = "/ui/images/appDefault.png",
      bigMapIds = ownerOpBigMapIds(active),
      ownerOpContractId = active.id,
      ownerOpKind = active.kind,
      ownerOpPhase = phase,
    }
    if active.originFacId then
      card.route = ownerOpRoute(active)
    end
    addCard(card)
  end

  -- Cargo formatting --------------------------------------------------------------------------------

  local lowestIdSort = function(a,b) return a.ids[1] < b.ids[1] end
  local idSort = function(a,b) return a.id < b.id end

  -- The base record for one group: identity, labels, places, rewards and the route.
  local function baseCargoRecord(group)
    local material = group[1].materialType and ext.generator.getMaterialsTemplatesById(group[1].materialType) or nil
    return {
      id = group[1].id,

      ids = {}, -- implicit count of included objects in this group

      name = _tr(group[1].name),
      loadedAtTimeStamp = group[1].loadedAtTimeStamp,

      originName = ext.parcelManager.getLocationLabelShort(group[1].origin),
      locationName = ext.parcelManager.getLocationLabelShort(group[1].location),
      destinationName = ext.parcelManager.getLocationLabelShort(group[1].destination),

      originNameLong = ext.parcelManager.getLocationLabelLong(group[1].origin),
      locationNameLong = ext.parcelManager.getLocationLabelLong(group[1].location),
      destinationNameLong = ext.parcelManager.getLocationLabelLong(group[1].destination),

      origin = group[1].origin,
      location = group[1].location,
      destination = group[1].destination,

      type = group[1].type,
      materialType = group[1].materialType,
      materialContractId = group[1].data and group[1].data.materialContractId or nil,
      slots = group[1].slots,
      distance = group[1].data and group[1].data.originalDistance,
      rewardMoney = group[1].rewards and group[1].rewards.money,
      economyMultiplier = (group[1].rewards and group[1].rewards.economyMultiplier) or 1,
      weight = group[1].weight,
      units = material and (material.units or "L") or nil,
      rewardMoneyPerKg = material and sharedCalc.getMaterialMoneyPerKg(material) or nil,

      enabled = true, -- not needed in player view
      disableReason = {}, -- not needed in player view

      targetLocations = {},
      autoLoadLocations = {},
      remainingOfferTime = (tonumber(group[1].offerExpiresAt) or 0) - ext.general.time(),

      modifiers = {},

      automaticDropOff = group[1].automaticDropOff,
      _transientMove = group[1]._transientMove,
      hiddenInFacility = group[1].hiddenInFacility,

      route = {
        type = "navgraph",
        locations = {group[1].location, group[1].destination}
      },
      bigMapIds = {}
    }
  end

  -- Map markers for the group: its destination, or every stop of a multi-destination job. A cargo move points at where it is now.
  local function addBigMapIds(ret, group)
    local destination = group[1].destination
    if destination and destination.type ~= "multi" then
      ret.bigMapIds[string.format("delivery-parking-%s-%s", destination.facId, destination.psPath)] = true
    elseif destination and destination.destinations then
      for _, loc in ipairs(destination.destinations) do
        ret.bigMapIds[string.format("delivery-parking-%s-%s", loc.facId, loc.psPath)] = true
      end
    end

    if group[1]._transientMove then
      ret.bigMapIds = {}
      ret.bigMapIds[string.format("delivery-parking-%s-%s", group[1].location.facId, group[1].location.psPath)] = true
    end
  end

  -- Every cargo id in the group, and how many of them are already reserved for a move.
  local function addIdsAndTransientCount(ret, group)
    for _, cargo in ipairs(group) do
      table.insert(ret.ids, cargo.id)
    end
    local transientMoveCounts = 0
    for _, cargo in ipairs(group) do
      transientMoveCounts = transientMoveCounts + (cargo._transientMove and 1 or 0)
    end
    ret.transientMoveCounts = transientMoveCounts
  end

  -- A group that just arrived shows a short "new" timer for three seconds.
  local function addFirstSeenTimer(ret, group)
    if group[1].firstSeen and (ext.general.time() - group[1].firstSeen) < 3 then
      ret.showNewTimer = 3 - (ext.general.time() - group[1].firstSeen)
    end
  end

  -- The timed modifier's countdown: until delayed, until late, or late. Before loading it is the full delay.
  local function addTimedRemaining(ret, mod)
    ret.hasTimerMod = true
    ret.remainingTime = {}
    if ret.loadedAtTimeStamp then
      local expiredTime = ext.general.time() - ret.loadedAtTimeStamp
      if expiredTime <= mod.timeUntilDelayed then
        ret.remainingTime = {
          type = "untilDelayed",
          time = mod.timeUntilDelayed - expiredTime,
          percent = (mod.timeUntilDelayed - expiredTime) / mod.timeUntilDelayed
        }
      elseif expiredTime <= mod.timeUntilLate then
        ret.remainingTime = {
          type = "untilLate",
          time = mod.timeUntilLate - expiredTime,
          percent = (mod.timeUntilLate - expiredTime) / (mod.timeUntilLate-mod.timeUntilDelayed)
        }
      else
        ret.remainingTime = {
          type = "late",
          percent = 0
        }
      end
    else
      ret.remainingTime = {
        type = "preLoad",
        time = mod.timeUntilDelayed,
      }
    end
  end

  -- Visible modifiers for the group. Returns the set of modifier types, which the progress lock checks.
  local function addModifiers(ret, group)
    local modifierKeys = {}
    for _, mod in ipairs(group[1].modifiers) do
      local modData = ext.parcelMods.getModData(mod.type)
      modifierKeys[mod.type] = true
      if not modData.hidden then
        local modProp = {type = mod.type, icon = modData.icon, active = true, label = modData.label, description = modData.shortDescription, important = modData.important}
        table.insert(ret.modifiers, modProp)
        if mod.type == "timed" then
          addTimedRemaining(ret, mod)
        end
      end
    end
    return modifierKeys
  end

  -- Progress locks disable the group and say why. Returns true when the group is locked.
  local function blockedByModifiers(ret, modifierKeys)
    local lockedBecauseOfMods, flagDefinition = ext.parcelMods.lockedBecauseOfMods(modifierKeys)
    if flagDefinition then
      ret.unlockInfo = flagDefinition.unlockInfo
    end
    if lockedBecauseOfMods then
      ret.enabled = false
      ret.disableReason = flagDefinition and flagDefinition.lockedReason
      return true
    end
    return false
  end

  -- A container can take this group unless it holds other cargo the group may not mix with, or it has no room for this cargo type.
  local function containerCanTakeGroup(con, cargo)
    if next(con.rawCargo) and cargo.type and not ext.generator.isMixable(cargo.type) then
      for _, otherCargo in ipairs(con.rawCargo) do
        if otherCargo.type ~= cargo.type then
          return false
        end
      end
    end
    return con.cargoTypesLookup[cargo.type] and true or false
  end

  -- How many of the group's cargo already has a move to this container.
  local function addTransientMovesToLoadTarget(elem, group, con)
    for _, groupCargo in ipairs(group) do
      if groupCargo._transientMove and ext.parcelManager.sameLocation(groupCargo._transientMove.targetLocation, con.location) then
        elem.maxAmount = elem.maxAmount + 1
        elem.selectedAmount = elem.selectedAmount + 1
        elem.usedCargoSlots = elem.usedCargoSlots - groupCargo.slots
        elem.enabled = true
      end
    end
  end

  -- Every container where the group can be loaded, with how many items fit and how many of it already have a move there.
  local function addLoadTargets(ret, group, playerCargoContainers)
    local cargo = group[1]
    for _, con in ipairs(playerCargoContainers) do
      if containerCanTakeGroup(con, cargo) then
        local maxAmount = math.floor(con.freeCargoSlots / cargo.slots)
        if maxAmount > 0 then
          local elem = {
            enabled = con.freeCargoSlots >= cargo.slots,
            label = con.moveToLabel,
            location = con.location,
            maxAmount = maxAmount,
            selectedAmount = 0,
            containerVehicleInfo = {
              vehId = con.vehId,
              vehName = con.vehName,
              conName = con.name,
            },
            usedCargoSlots = con.usedCargoSlots,
            totalCargoSlots = con.totalCargoSlots,
          }
          addTransientMovesToLoadTarget(elem, group, con)
          table.insert(ret.targetLocations, elem)
        end
      end
    end
  end

  -- The auto-load plan: the enabled targets with the most room first, one location per item, until every item has one.
  local function addAutoLoadLocations(ret)
    local tgtIds = {}
    for id, elem in ipairs(ret.targetLocations) do
      if elem.enabled then
        table.insert(tgtIds, id)
      end
    end
    table.sort(tgtIds, function(a,b)
      local tgtA = ret.targetLocations[a]
      local tgtB = ret.targetLocations[b]
      if tgtA.maxAmount ~= tgtB.maxAmount then
        return tgtA.maxAmount > tgtB.maxAmount
      else
        return (tgtA.totalCargoSlots - tgtA.usedCargoSlots) < (tgtB.totalCargoSlots - tgtB.usedCargoSlots)
      end
    end)
    ret.autoLoadLocations = {}
    local autoloadCounts = 0
    for _, id in ipairs(tgtIds) do
      for i = 1, ret.targetLocations[id].maxAmount do
        if autoloadCounts < #ret.ids then
          table.insert(ret.autoLoadLocations, ret.targetLocations[id].location)
          autoloadCounts = autoloadCounts + 1
        end
      end
    end
  end

  -- Formats one group of identical cargo for the UI. Gates run in the order players see them: owner-operator block, expiry, progress lock, no space.
  -- Without containers the group is a plain record for a facility card.
  local function formatCargoGroup(group, playerCargoContainers, showFirstSeen)
    table.sort(group, idSort)
    local ret = baseCargoRecord(group)
    addBigMapIds(ret, group)
    addIdsAndTransientCount(ret, group)
    if showFirstSeen then
      addFirstSeenTimer(ret, group)
    end
    local modifierKeys = addModifiers(ret, group)

    if not playerCargoContainers then
      return ret
    end

    for _, cargo in ipairs(group) do
      if ownerOpBlocksPerDiemOffer(cargo) then
        ret.enabled = false
        ret.disableReason = OWNER_OP_PER_DIEM_BLOCK
        return ret
      end
    end

    -- if this item is expired, return early.
    if ret.remainingOfferTime <= 0 then
      ret.enabled = false
      ret.disableReason = {type = "expired"}
      return ret
    end

    if blockedByModifiers(ret, modifierKeys) then
      return ret
    end

    addLoadTargets(ret, group, playerCargoContainers)

    -- if there is no target, that means there is "no space"
    if not next(ret.targetLocations) and ret.transientMoveCounts == 0 then
      ret.enabled = false
      ret.disableReason = {type = "noSpace"}
      return ret
    end

    addAutoLoadLocations(ret)
    if not next(ret.autoLoadLocations) and ret.transientMoveCounts == 0 then
      ret.enabled = false
      ret.disableReason = {type = "noSpace"}
      return ret
    end

    return ret
  end

  -- Groups the cargo first, then formats each group. Cargo shares a group only when its group id and load time match.
  local function clusterFormatCargo(cargo, playerCargoContainers, updateFirstSeen)
    local ret = {}
    -- The current location must match too; the caller guarantees that.
    local cargoByGroupId = {}
    for _, c in ipairs(cargo) do
      local gId = string.format("%s-%s", tostring(c.groupId or c.id or 0), tostring(c.loadedAtTimeStamp or -1))
      cargoByGroupId[gId] = cargoByGroupId[gId] or {}
      -- finalize the fields that require "costly" computation at this point
      ext.generator.finalizeParcelItemDistanceAndRewards(c)
      if updateFirstSeen then
        c.firstSeen = c.firstSeen or ext.general.time()
      end
      table.insert(cargoByGroupId[gId], c)
    end
    -- format each group individually
    for _, group in pairs(cargoByGroupId) do
      local formatted = formatCargoGroup(group, playerCargoContainers, updateFirstSeen)
      table.insert(ret, formatted)
      formatted.cardType = "parcelGroup"
      if playerCargoContainers then
        formatted.isFacilityCard = true
      else
        formatted.isPlayerCard = true
      end
      addCard(formatted)
    end
    table.sort(ret, lowestIdSort)
    return ret
  end

  -- Vehicle offer formatting ------------------------------------------------------------------------

  -- gets the thumbnail for a vehicle
  local function getVehicleThumb(vehicle)
    local model = core_vehicles.getModel(vehicle.model)
    if not model or not model.configs or not vehicle.config then return nil end
    local config = model.configs[vehicle.config]
    if not config then return nil end
    return config.preview
  end

  local function facilityOfferCard(offer)
    return {
      id = offer.id,
      name = offer.vehicle.name,
      type = "vehOffer",
      vehOfferType = offer.data.type,
      vehName = offer.vehicle.name,
      vehBrand = offer.vehicle.brand,
      vehMileage = offer.vehicle.mileage,
      destinationName = ext.parcelManager.getLocationLabelShort(offer.task.destination),
      destinationNameLong = ext.parcelManager.getLocationLabelLong(offer.task.destination),
      locationName = ext.parcelManager.getLocationLabelShort(offer.origin),
      locationNameLong = ext.parcelManager.getLocationLabelLong(offer.origin),
      task = ext.vehicleOfferManager.makeTaskLabel(offer.task),
      thumbnail = getVehicleThumb(offer.vehicle) or '/ui/images/appDefault.png',
      distance = offer.data.originalDistance,
      rewards = offer.rewards,
      rewardMoney = offer.rewards.money,
      economyMultiplier = (offer.rewards and offer.rewards.economyMultiplier) or 1,
      remainingOfferTime = offer.offerExpiresAt - (ext.general.time()),
      connector = "ConName",
      unlockTag = offer.vehicle.filterName,
      enabled = true,
      spawnWhenCommitingCargo = offer.spawnWhenCommitingCargo,

      route = {
        type = "navgraph",
        locations = {offer.origin, offer.task.destination}
      },
      modifiers = ext.vehicleOfferManager.getDefaultVehicleModifiersForUI(),
      bigMapIds = {}
    }
  end

  -- An expired or locked offer keeps its reason; the owner-operator block and spawn flag are applied after.
  local function applyOfferLock(item, enabled, flagDefinition)
    if item.remainingOfferTime <= 0 then
      item.enabled = false
      item.disableReason = {type = "expired"}
      return
    end
    item.unlockInfo = flagDefinition and flagDefinition.unlockInfo
    if not enabled then
      item.enabled = false
      item.disableReason = flagDefinition and flagDefinition.lockedReason
    end
  end

  local function applyOwnerOpAndSpawnState(item, offer)
    if ownerOpBlocksPerDiemOffer(offer) then
      item.enabled = false
      item.disableReason = OWNER_OP_PER_DIEM_BLOCK
    elseif item.spawnWhenCommitingCargo then
      item.enabled = true
      item.disableReason = nil
    end
  end

  local function formatVehicleOfferForUi(offers)
    local ret = {}

    for _, offer in ipairs(offers) do
      ext.generator.finalizeVehicleOffer(offer)
      local item = facilityOfferCard(offer)

      local enabled, flagDefinition = ext.vehicleOfferManager.isVehicleTagUnlocked(offer.vehicle.unlockTag)
      item.bigMapIds[string.format("delivery-parking-%s-%s", offer.task.destination.facId, offer.task.destination.psPath)] = true

      applyOfferLock(item, enabled, flagDefinition)
      applyOwnerOpAndSpawnState(item, offer)

      table.insert(ret, item)
      item.cardType = "vehicleOffer"
      item.isFacilityCard = true
      addCard(item)
    end
    return ret
  end

  -- Accepted offers ---------------------------------------------------------------------------------

  -- What the player must do next with an accepted vehicle or trailer, from its active vehicle task.
  local function acceptedOfferTaskList(item, offer)
    local task = ext.vehicleTasks.getVehicleTaskForOffer(offer)
    if not task or not task.tasks then
      if item.type == "vehicle" then
        return {_tr("ui.career.delivery.cargoScreen.enterVehicle")}
      end
      return {_tr("ui.career.delivery.cargoScreen.coupleTrailer")}
    end
    local activeTask = task.tasks[task.activeTaskIndex]
    if activeTask.type == "coupleTrailer" then
      return {_tr("ui.career.delivery.cargoScreen.coupleTrailer")}
    elseif activeTask.type == "enterVehicle" then
      return {_tr("ui.career.delivery.cargoScreen.enterVehicle")}
    elseif activeTask.type == "bringToDestination" or activeTask.type == "confirmDropOff" then
      return {item.type == "trailer"
        and core_locales.contextTranslate("ui.career.delivery.cargoScreen.dropOffTrailer", {destination = item.destinationName})
        or core_locales.contextTranslate("ui.career.delivery.cargoScreen.dropOffVehicle", {destination = item.destinationName})}
    end
    return {activeTask.type or "no type?"}
  end

  local function formatAcceptedOfferForUI(offer)
    local item = {
      id = offer.id,
      name = offer.vehicle.name,
      vehName = offer.vehicle.name,
      vehBrand = offer.vehicle.brand,
      vehMileage = offer.vehicle.mileage,
      vehOfferType = offer.data.type,
      destinationName = ext.parcelManager.getLocationLabelShort(offer.task.destination),
      task = ext.vehicleOfferManager.makeTaskLabel(offer.task),
      thumbnail = getVehicleThumb(offer.vehicle) or '/ui/images/appDefault.png',
      distance = offer.data.originalDistance,
      rewards = offer.rewards,
      rewardMoney = offer.rewards.money,
      economyMultiplier = (offer.rewards and offer.rewards.economyMultiplier) or 1,
      connector = "ConName",
      type = offer.data.type,
      enabled = true,

      route = {
        type = "navgraph",
        locations = {{type="vehicle", vehId = offer.vehicle.vehId}, offer.task.destination}
      },
      modifiers = ext.vehicleOfferManager.getDefaultVehicleModifiersForUI(),
      bigMapIds = {}
    }
    item.bigMapIds[string.format("delivery-parking-%s-%s", offer.task.destination.facId, offer.task.destination.psPath)] = true

    if offer.vehicle then
      item.abandonInfo = {
        penaltyMoney = offer.rewards.money * ext.general.getDeliveryAbandonPenaltyFactor(),
        vehId = offer.vehicle.vehId
      }
    end

    -- The default is set before the task lookup, and acceptedOfferTaskList replaces it on every path.
    item.taskList = {_tr("ui.career.delivery.cargoScreen.noTask")}
    item.taskList = acceptedOfferTaskList(item, offer)
    return item
  end

  local function getAcceptedVehicleOffers()
    local vehicleTasks = overhaul_career_logistics_vehicleTasks.getVehicleTasks()
    local res = {}
    for _, taskData in ipairs(vehicleTasks) do
      if not taskData.giveBack then
        local vehOffer = formatAcceptedOfferForUI(taskData.offer)
        table.insert(res, vehOffer)
        vehOffer.cardType = "vehicleOffer"
        vehOffer.isPlayerCard = true
        addCard(vehOffer)
      end
    end

    local vehOffers = ext.vehicleOfferManager.getAllOfferUnexpired()
    for _, offer in ipairs(vehOffers) do
      if offer.spawnWhenCommitingCargo then
        local vehOffer = formatAcceptedOfferForUI(offer)
        vehOffer.transientMove = true
        table.insert(res, vehOffer)
        vehOffer.cardType = "vehicleOffer"
        vehOffer.isPlayerCard = true
        vehOffer.spawnWhenCommitingCargo = true
        addCard(vehOffer)
      end
    end

    return res
  end

  return {
    addActiveOwnerOpMyCargoCards = addActiveOwnerOpMyCargoCards,
    addCard = addCard,
    cardsById = cardsById,
    clusterFormatCargo = clusterFormatCargo,
    formatAcceptedOfferForUI = formatAcceptedOfferForUI,
    formatCargoGroup = formatCargoGroup,
    formatVehicleOfferForUi = formatVehicleOfferForUi,
    getAcceptedVehicleOffers = getAcceptedVehicleOffers,
    getActiveOwnerOpContract = getActiveOwnerOpContract,
    OWNER_OP_PER_DIEM_BLOCK = OWNER_OP_PER_DIEM_BLOCK,
    ownerOpBlocksPerDiemOffer = ownerOpBlocksPerDiemOffer,
  }
end

return part
