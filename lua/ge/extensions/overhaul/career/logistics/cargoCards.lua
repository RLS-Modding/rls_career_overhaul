-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding
-- Fork of stock lua/ge/extensions/career/modules/delivery/cargoCards.lua (BeamNG 0.40).

-- Owns delivery-card grouping, sorting and the cargo overview shown by the UI.
-- The cargo screen and parcel manager supply live offers and cargo; this module formats them.
-- Start with card keys and filter helpers, then the card-building and ordering functions.
-- Public UI queries and career activation follow the formatting helpers.

local M = {}

-- Extension references that exist only while the career is active; onCareerActivated fills them.
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dProgress, dVehOfferManager, dParcelMods, dVehicleTasks
M.onCareerActivated = function()
  dParcelManager = overhaul_career_logistics_parcelManager
  dCargoScreen = overhaul_career_logistics_cargoScreen
  dGeneral = overhaul_career_logistics_general
  dGenerator = overhaul_career_logistics_generator
  dProgress = overhaul_career_logistics_progress
  dVehOfferManager = overhaul_career_logistics_vehicleOfferManager
  dParcelMods = overhaul_career_logistics_parcelMods
  dVehicleTasks = overhaul_career_logistics_vehicleTasks
end

local filterTags

local function ensureFilterTags()
  if filterTags then return end
  filterTags = {
    {
      value = "parcel", label = _tr("ui.career.cargoCards.parcel.label"), icon = "cardboardBox", type="cargo",
      shortDescription = _tr("ui.career.cargoCards.parcel.shortDescription"),
      noContent = _tr("ui.career.cargoCards.parcel.noContent"),
      cover = "/gameplay/branches/labourer/filterCovers/parcelCover.jpg",
      howTo = {label=_tr("ui.career.cargoCards.parcel.howTo"), pages={"delivery/parcelDeliveryHelp"}},
      groupings = {"destinations","ungrouped"},
    }, {
      value = "vehicle", label = _tr("ui.career.cargoCards.vehicle.label"), icon = "keys1", type="cargo",
      shortDescription = _tr("ui.career.cargoCards.vehicle.shortDescription"),
      noContent = _tr("ui.career.cargoCards.vehicle.noContent"),
      cover = "/gameplay/branches/labourer/filterCovers/vehicleCover.jpg",
      howTo = {label=_tr("ui.career.cargoCards.vehicle.howTo"), pages={"delivery/vehicleDeliveryHelp"}},
      groupings = {"destinations","ungrouped"},
    }, {
      value = "trailer", label = _tr("ui.career.cargoCards.trailer.label"), icon = "smallTrailer", type="cargo",
      shortDescription = _tr("ui.career.cargoCards.trailer.shortDescription"),
      noContent = _tr("ui.career.cargoCards.trailer.noContent"),
      cover = "/gameplay/branches/labourer/filterCovers/trailerCover.jpg",
      howTo = {label=_tr("ui.career.cargoCards.trailer.howTo"), pages={"delivery/trailerDeliveryHelp"}},
      groupings = {"destinations","ungrouped"},
    }, {
      value = "material", label = _tr("ui.career.cargoCards.material.label"), icon = "droplet", type="cargo",
      shortDescription = _tr("ui.career.cargoCards.material.shortDescription"),
      noContent = _tr("ui.career.cargoCards.material.noContent"),
      cover = "/gameplay/branches/labourer/filterCovers/materialsCover.jpg",
      howTo = {label=_tr("ui.career.cargoCards.material.howTo"), pages={"delivery/materialsDeliveryHelp"}},
      groupings = {"cargoType", "destinations","ungrouped"},
    }, {
      value = "all", label = _tr("ui.career.cargoCards.all.label"), icon = "infinity", type="cargo",
      shortDescription = _tr("ui.career.cargoCards.all.shortDescription"),
      cover = "/gameplay/branches/labourer/filterCovers/everythingCover.jpg",
      hideDetailed = true,
      groupings = {"destinations","cargoType","ungrouped"},
    }, {
      value = "loaner", label = _tr("ui.career.cargoCards.loaner.label"), icon = "carCoins", type="other",
      shortDescription = _tr("ui.career.cargoCards.loaner.shortDescription"),
      noContent = _tr("ui.career.cargoCards.loaner.noContent"),
      cover = "/gameplay/branches/labourer/filterCovers/loanerCover.jpg",
      howTo = {label=_tr("ui.career.cargoCards.loaner.howTo"), pages={"delivery/loanerHelp"}},
      groupings = {"loaner", "ungrouped"},
    },
  }
end
local filtersByKey = {}
local function resetFilterCounters()
  ensureFilterTags()
  for _, filter in ipairs(filterTags) do
    filter.facilityCards = 0
    filter.playerCards = 0
    filtersByKey[filter.value] = filter
  end
end
local defaultSortings = {"rewardMoney", "distance", "weight", "availablilty"}

local function makeGroup(groupsByKey, key, label, meta)
  groupsByKey[key] = groupsByKey[key] or {label=label, meta=meta}
end

local function getCardGroupSetsByKey(cardsById, usePlayerCards, playerCargoContainers)
  local groupsByKey = {
    ungrouped = {label=_tr("ui.career.cargoCards.group.none"), meta={type="hidden"}},
    -- cargo types
    type_parcel = {label=_tr("ui.career.cargoCards.group.parcel")},
    type_fluid = {label=_tr("ui.career.cargoCards.group.fluid")},
    type_dryBulk = {label=_tr("ui.career.cargoCards.group.dryBulk")},
    type_cement = {label="Cement"},
    type_cash = {label="Bank Deliveries"},
    type_vehicle = {label=_tr("ui.career.cargoCards.group.vehicle")},
    type_trailer = {label=_tr("ui.career.cargoCards.group.trailer")},
    type_loaner = {label=_tr("ui.career.cargoCards.group.loaner")},
    type_loaner_vehicle = {label=_tr("ui.career.cargoCards.group.loanerVehicle")},
    type_loaner_trailer = {label=_tr("ui.career.cargoCards.group.loanerTrailer")},

    -- destination (keys built from cards)
    destination_noDestination = {label = _tr("ui.career.cargoCards.group.unknownDestination")},

    type_totalStorage_parcel = {meta={type="totalStorage", usedCargoSlots = 0, totalCargoSlots = 0, icon="cardboardBox"}},
    type_totalStorage_fluid = {meta={type="totalStorage", usedCargoSlots = 0, totalCargoSlots = 0, icon="droplet"}},
    type_totalStorage_dryBulk = {meta={type="totalStorage", usedCargoSlots = 0, totalCargoSlots = 0, icon="rocks"}},
    type_totalStorage_cement = {meta={type="totalStorage", usedCargoSlots = 0, totalCargoSlots = 0, icon="rocks"}},
    type_totalStorage_cash = {meta={type="totalStorage", usedCargoSlots = 0, totalCargoSlots = 0, icon="beamCurrency"}},
  }

  if usePlayerCards and playerCargoContainers then
    for _, con in ipairs(playerCargoContainers) do
      local icon = "cardboardBox"
      local totalGroupMeta = groupsByKey['type_totalStorage_parcel'].meta
      if con.cargoTypesLookup.fluid then
        icon = "droplet"
        totalGroupMeta = groupsByKey['type_totalStorage_fluid'].meta
      elseif con.cargoTypesLookup.dryBulk then
        icon = "rocks"
        totalGroupMeta = groupsByKey['type_totalStorage_dryBulk'].meta
      elseif con.cargoTypesLookup.cash then
        icon = "beamCurrency"
        totalGroupMeta = groupsByKey['type_totalStorage_cash'].meta
      elseif con.cargoTypesLookup.cement then
        icon = "rocks"
        totalGroupMeta = groupsByKey['type_totalStorage_cement'].meta
      end
      totalGroupMeta.usedCargoSlots = totalGroupMeta.usedCargoSlots + con.usedCargoSlots
      totalGroupMeta.totalCargoSlots = totalGroupMeta.totalCargoSlots + con.totalCargoSlots
      totalGroupMeta.fillPercent = 0
      if totalGroupMeta.totalCargoSlots > 0 then
        totalGroupMeta.fillPercent = totalGroupMeta.usedCargoSlots / totalGroupMeta.totalCargoSlots
      end


      groupsByKey[string.format("container_%d_%d", con.vehId, con.containerId)] = {
        label = con.name,
        meta = {
          container = con,
          usedCargoSlots = con.usedCargoSlots,
          totalCargoSlots= con.totalCargoSlots,

          type = "container",
          fillPercent = con.usedCargoSlots / con.totalCargoSlots,
          icon = icon
        },
        showEmpty = true,
        filterTags = deepcopy(con.cargoTypesLookup),
      }
    end
  end

  -- build grouping data on cards
  for id, card in pairs(cardsById) do
    local groupTags = {}
    card.filterTags = card.filterTags or {}
    card.filterTags['all'] = true

    -- skip player cards and vice versa depending on usePlayerCards
    if
      (card.isPlayerCard and not usePlayerCards)
      or (card.isFacilityCard and usePlayerCards)
      or (card.isFacilityCard and card.hiddenInFacility)
       then
      goto continue
    end

    -- build filter data from card data
    groupTags['ungrouped'] = true
    --cargo type
    if card.cardType == "parcelGroup" then
      groupTags['type_'..card.type] = true
      if card.materialType then
        card.filterTags['material'] = true
      else
        card.filterTags['parcel'] = true
      end
    elseif card.cardType == "storage" or card.cardType == "materialContractOffer" then
      groupTags['type_'..card.material.type] = true
      card.filterTags['material'] = true
    elseif card.cardType == "passiveBusinessSupplyOffer" or card.cardType == "engineShopSupplyOffer" then
      groupTags['type_parcel'] = true
      card.filterTags['parcel'] = true
    elseif card.cardType == "vehicleOffer" then
      groupTags['type_'..card.vehOfferType] = true
      card.filterTags[card.vehOfferType] = true
    elseif card.cardType == "loaner" then
      groupTags['type_loaner'] = true
      groupTags['type_loaner_'..card.vehOfferType] = true
      card.filterTags['loaner'] = true
      --card.filterTags['loaner_'..card.vehOfferType] = true
    end

    if card.isPlayerCard then
      card.filterTags['myCargo'] = true
    end

    -- destinationName
    if card.destinationName then
      groupTags['destination_'..card.destinationName] = true
      makeGroup(groupsByKey, 'destination_'..card.destinationName, card.destinationName,
      { type="location", distance=card.distance })
    elseif card.cardType == "storage" then
      for _, destination in ipairs(card.locations) do
        groupTags['destination_'..destination.destinationName] = true
        makeGroup(groupsByKey, 'destination_'..destination.destinationName, destination.destinationName, { type="location", distance=destination.distance })
      end
    else
      groupTags['destination_noDestination'] = true
    end

    -- container location
    if card.isPlayerCard and card.cardType == 'parcelGroup' then
      local loc = card.location
      if card.transientMove then loc = card._transientMove.targetLocation end
      if loc.type == "vehicle" or card.transientMove  then
        groupTags[string.format("container_%d_%d", loc.vehId, loc.containerId)] = true
      end
    end

    -- tasklist grouping
    if usePlayerCards and card.isPlayerCard then
      local taskLabels = {_tr("ui.career.cargoCards.group.noTask")}
      if card.cardType == "parcelGroup" then
        taskLabels = card.taskList
      elseif card.cardType == "vehicleOffer" then
        taskLabels = card.taskList
      end

      for _, label in ipairs(taskLabels) do
        groupTags['task_'..label] = true
        makeGroup(groupsByKey, 'task_'..label, label, { type="task" })
      end
    end

    ::continue::

    -- assign to card
    card.groupTags = groupTags

  end

  -- build group lists (new groups might have been added)
  for key, group in pairs(groupsByKey) do
    group.cardIdsUnsorted = {}
    group.meta = group.meta or {type="none"}
    group.filterTags = group.filterTags or {}
    group.filterTags['all'] = true
  end

  -- add card ids to groups
  for id, card in pairs(cardsById) do
    for groupKey, _ in pairs(card.groupTags) do
      table.insert(groupsByKey[groupKey].cardIdsUnsorted, id)
      for filterKey, _ in pairs(card.filterTags) do
        groupsByKey[groupKey].filterTags[filterKey] = true
      end
    end
    for filterKey, _ in pairs(card.filterTags) do
      if not usePlayerCards then
        local cardTypeKey = card.isFacilityCard and 'facilityCards' or 'playerCards'
        filtersByKey[filterKey][cardTypeKey] = filtersByKey[filterKey][cardTypeKey] + 1
      end
    end
  end

  -- build grouping sets

  local groupSetsByKey = { }
  groupSetsByKey['ungrouped'] = {
    key = "ungrouped",
    label = _tr("ui.career.cargoCards.group.none"),
    hideProps = true,
    hideModsAndTimer = true,
    groups = {
      groupsByKey.ungrouped
    },
    sortings = defaultSortings,
  }
  groupSetsByKey['cargoType'] = {
    key = "cargoType",
    label = _tr("ui.career.cargoCards.groupSet.cargoType"),
    hideProps = true,
    hideModsAndTimer = true,
    focus = "none",
    groups = {
      groupsByKey.type_parcel,
      groupsByKey.type_fluid,
      groupsByKey.type_dryBulk,
      groupsByKey.type_cement,
      groupsByKey.type_cash,
      groupsByKey.type_vehicle,
      groupsByKey.type_trailer,
    },
    sortings = defaultSortings,
  }

  local destinationGroups = {}
  for key, group in pairs(groupsByKey) do
    if key ~= "destination_noDestination" and key:startswith('destination_') then
      table.insert(destinationGroups, group)
    end
  end
  table.sort(destinationGroups, function(a, b)
    local aDist = a and a.meta and tonumber(a.meta.distance)
    local bDist = b and b.meta and tonumber(b.meta.distance)
    if aDist == nil and bDist == nil then return false end
    if aDist == nil then return false end
    if bDist == nil then return true end
    return aDist < bDist
  end)
  table.insert(destinationGroups, groupsByKey['destination_noDestination'])
  groupSetsByKey['destinations'] = {
    key = "destinations",
    label = _tr("ui.career.cargoCards.groupSet.destinations"),
    groups = destinationGroups,
    hideProps = true,
    hideModsAndTimer = true,
    focus = "destination",
    sortings = defaultSortings,
  }

  if usePlayerCards then
    local containerGroups = {}
    for _, con in ipairs(playerCargoContainers) do
      table.insert(containerGroups, groupsByKey[string.format("container_%d_%d", con.vehId, con.containerId)])
    end
    table.insert(containerGroups, groupsByKey.type_vehicle)
    table.insert(containerGroups, groupsByKey.type_trailer)

    groupSetsByKey['containers'] = {
      key = "containers",
      label = _tr("ui.career.cargoCards.groupSet.cargoContainers"),
      groups = containerGroups,
      hideProps = true,
      hideModsAndTimer = true,
      hideTotalStorage = true,
      sortings = defaultSortings,
    }

    local taskGroups = {}
    for key, group in pairs(groupsByKey) do
      if key:startswith('task_') then
        group.showEmpty = true
        group.ignoreFilter = true
        table.insert(taskGroups, group)
      end
    end
    table.sort(taskGroups, function(a,b) return a.label < b.label end)
    groupSetsByKey['tasklist'] = {
      key = "tasklist",
      label = _tr("ui.career.cargoCards.groupSet.tasklist"),
      groups = taskGroups,
      hideProps = true,
      hideModsAndTimer = true,
      sortings = defaultSortings,
    }
  end

  groupSetsByKey['loaner'] = {
    key = "loaner",
    label = _tr("ui.career.cargoCards.groupSet.vehicleType"),
    hideProps = true,
    hideModsAndTimer = true,
    groups = {
      groupsByKey.type_loaner_vehicle,
      groupsByKey.type_loaner_trailer,
    },
    sortings = {"cardId"}
  }

  groupSetsByKey['totalStorages'] = {
    key = 'totalStorages',
    groups = {
      groupsByKey.type_totalStorage_parcel,
      groupsByKey.type_totalStorage_fluid,
      groupsByKey.type_totalStorage_dryBulk,
      groupsByKey.type_totalStorage_cement,
      groupsByKey.type_totalStorage_cash,
    }
  }

  return groupSetsByKey
end

local function getCardSortingSetsByKey(cardsById)
  local sortSetsByKey = {}

  local cards = {}
  local idx = 1
  for _, card in pairs(cardsById) do
    card.sortValues = {}
    cards[idx] = card
    idx = idx + 1
  end

  -- cardId sorting
  table.sort(cards, function(a,b)
    return a.cardId < b.cardId
  end)
  for i, card in ipairs(cards) do
    card.sortValues.cardId = i
  end
  sortSetsByKey['cardId'] = {label = _tr("ui.career.cargoCards.sort.id"), key = "cardId"}

  -- rewardMoney sorting: from high to low
  table.sort(cards, function(a, b)
    if not a.rewardMoney and not b.rewardMoney then
      return a.cardId < b.cardId
    end
    if not a.rewardMoney then
      return false
    end
    if not b.rewardMoney then
      return true
    end
    return a.rewardMoney < b.rewardMoney
  end)
  for i, card in ipairs(cards) do
    card.sortValues.rewardMoney = i
  end
  sortSetsByKey['rewardMoney'] = {label = _tr("ui.career.cargoCards.sort.rewards"), key = "rewardMoney"}

  -- weight sorting: from high to low
  table.sort(cards, function(a, b)
    if not a.weight and not b.weight then
      return a.sortValues.rewardMoney < b.sortValues.rewardMoney
    end
    if not a.weight then
      return false
    end
    if not b.weight then
      return true
    end
    return a.weight < b.weight
  end)
  for i, card in ipairs(cards) do
    card.sortValues.weight = i
  end
  sortSetsByKey['weight'] = {label = _tr("ui.career.cargoCards.sort.weight"), key = "weight"}

  -- distance sorting from close to far
  table.sort(cards, function(a, b)
    if not a.distance and not b.distance then
      return a.sortValues.rewardMoney < b.sortValues.rewardMoney
    end
    if not a.distance then
      return false
    end
    if not b.distance then
      return true
    end
    return a.distance < b.distance
  end)
  for i, card in ipairs(cards) do
    card.sortValues.distance = i
  end
  sortSetsByKey['distance'] = {label = _tr("ui.career.cargoCards.sort.distance"), key = "distance"}


  local disableReasonOrder = {
    limit = 0,
    wrongPickup = 1,
    inTransit = 1,
    noSpace = 1,
    locked = 2,
    tutorial = 3,
    ownerOp = 4,
    expired = 100
  }
  -- availablilty
  table.sort(cards, function(a, b)
    if a.enabled and b.enabled then
      return a.sortValues.rewardMoney < b.sortValues.rewardMoney
    end
    if not a.enabled and b.enabled then
      return false
    end
    if not b.enabled and a.enabled then
      return true
    end
    if not a.disableReason and not b.disableReason then
      return false
    end
    if not a.disableReason then
      return false
    end
    if not b.disableReason then
      return true
    end
    local aOrder = disableReasonOrder[a.disableReason.type] or 50
    local bOrder = disableReasonOrder[b.disableReason.type] or 50
    return aOrder < bOrder
  end)
  for i, card in ipairs(cards) do
    card.sortValues.availablilty = i
  end
  sortSetsByKey['availablilty'] = {label = _tr("ui.career.cargoCards.sort.availability"), key = "availablilty"}


  return sortSetsByKey
end

local function addSortingValuesToGroups(cardsById, groupSets)
  -- give the groups in the groupsets the sorting values.
  for _, groupSet in pairs(groupSets) do
    for _, group in ipairs(groupSet.groups) do
      group.sortValues = {}
      for _, sortKey in ipairs({"cardId", "rewardMoney","weight","distance"}) do
        local min = math.huge
        for _, id in ipairs(group.cardIdsUnsorted) do
          min = math.min(min, cardsById[id].sortValues[sortKey] or math.huge)
        end
        group.sortValues[sortKey] = min
      end
    end
  end
end

local function getFilterSets(cardsById)
  ensureFilterTags()
  local filterSets = { }
  local function hasUnlockFlag(flag)
    return overhaul_career_progression_unlockFlags.getFlag(flag)
  end
  local function flagLevel(flag)
    local definition = overhaul_career_progression_unlockFlags.getFlagDefinition(flag)
    return definition and definition.level
  end
  for i, filter in ipairs(filterTags) do

    if filter.playerCards > 0 or filter.facilityCards > 0 then
      filter.hasAvailableOffers = true
    end
    filter.lockedInfo = nil
    if filter.value == "trailer" then
      if not hasUnlockFlag("smallTrailersDelivery") then
        local trailerLevel = flagLevel("smallTrailersDelivery")
        filter.lockedInfo = {
          type = "minLevel",
          icon = "boxPickUp03",
          longLabel = core_locales.contextTranslate("ui.career.cargoCards.locked.requiresCargoDeliveryLevelLong", {branch = _tr("ui.career.logistics.delivery.name"), level = trailerLevel}),
          shortLabel = core_locales.contextTranslate("ui.career.cargoCards.locked.levelShort", {level = trailerLevel}),
          minLevel = trailerLevel
        }
      end
    end
    if filter.value == "material" then
      if not (hasUnlockFlag("logisticsFluidDelivery") or hasUnlockFlag("logisticsAggregateDelivery") or hasUnlockFlag("logisticsCementDelivery")) then
        local materialLevel
        for _, flag in ipairs({"logisticsFluidDelivery", "logisticsAggregateDelivery", "logisticsCementDelivery"}) do
          local level = flagLevel(flag)
          if level then materialLevel = math.min(materialLevel or math.huge, level) end
        end
        filter.lockedInfo = {
          type = "minLevel",
          icon = "boxPickUp03",
          longLabel = core_locales.contextTranslate("ui.career.cargoCards.locked.requiresCargoDeliveryLevelLong", {branch = _tr("ui.career.logistics.delivery.name"), level = materialLevel}),
          shortLabel = core_locales.contextTranslate("ui.career.cargoCards.locked.levelShort", {level = materialLevel}),
          minLevel = materialLevel
        }
      end
    end

    -- if current facility does not offer this kind of orders then
    filter.order = i
    table.insert(filterSets, filter)
  end
  return filterSets
end



local function addFilterPlayerData(filterSets, playerGroupSets, playerCargoContainers)
  -- figure out if the player has storage for this thing.
  local storageAmount =  {parcel = 0, fluid = 0, dryBulk = 0, cement = 0, cash = 0}
  for _, con in ipairs(playerCargoContainers) do
    if con.cargoTypesLookup.parcel then
      storageAmount.parcel = 1
    elseif con.cargoTypesLookup.fluid then
      storageAmount.fluid = 1
    elseif con.cargoTypesLookup.dryBulk then
      storageAmount.dryBulk = 1
    elseif con.cargoTypesLookup.cement then
      storageAmount.cement = 1
    elseif con.cargoTypesLookup.cash then
      storageAmount.cash = 1
    end
  end
  for _, filter in ipairs(filterSets) do
    filter.noContainers = nil
    if require('overhaul/lib/logistics/cargoSemantics').cargo(filter.value).parcel and storageAmount.parcel == 0 then
      filter.noContainers = true
    elseif filter.value == "material" and (storageAmount.fluid == 0 and storageAmount.dryBulk == 0 and storageAmount.cement == 0 and storageAmount.cash == 0) then
      filter.noContainers = true
    elseif filter.value == "all" and (storageAmount.parcel == 0 and storageAmount.fluid == 0 and storageAmount.dryBulk == 0 and storageAmount.cement == 0 and storageAmount.cash == 0) then
      filter.noContainers = true
    end
  end

end

local function getConfirmButtonFromPlayerCards(cardsById)
  local itemCount = 0
  for _, card in pairs(cardsById) do
    if card.isPlayerCard and
       (   (card.transientMoveCounts and card.transientMoveCounts > 0)
        or card.spawnWhenCommitingCargo) then
      local count = 1
      if card.cardType == "parcelGroup" and (not card.materialType) then
        count = #card.ids
      end
      itemCount = itemCount + count
    end
  end
  return {
    itemCount = itemCount,
  }

end

M.onLanguageChanged = function()
  filterTags = nil
  table.clear(filtersByKey)
end

M.resetFilterCounters = resetFilterCounters
M.getFilterSets = getFilterSets
M.addFilterPlayerData = addFilterPlayerData
M.getCardGroupSetsByKey = getCardGroupSetsByKey
M.addSortingValuesToGroups = addSortingValuesToGroups
M.getCardSortingSetsByKey = getCardSortingSetsByKey
M.getConfirmButtonFromPlayerCards = getConfirmButtonFromPlayerCards
return M
