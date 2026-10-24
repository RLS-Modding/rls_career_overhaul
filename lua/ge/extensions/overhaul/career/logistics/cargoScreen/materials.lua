-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Cargo-screen materials: loads material contracts from storages, builds material storage cards, runs the pickup screen and stages material and cargo moves. materialContractManager owns contracts and credit.
-- Read transientSlotsForStorage, loadTarget, addLoadTargetsForContainer, formatLoadTargets in order.

-- Part of the Overhaul fork of stock `lua/ge/extensions/career/modules/delivery/cargoScreen.lua`.

local part = {}

-- Built once per cargo screen load; the facility location is read from the shared screen state.
function part.new(inputs)
  local api = {}
  local ext, screen = inputs.ext, inputs.screen

  -- Load targets ------------------------------------------------------------------------------------

  -- Cargo already moved toward this container from the storage, which the container can still take.
  local function transientSlotsForStorage(storage, con)
    local transientCargoSlots = 0
    if storage.id then
      for _, cargo in ipairs(ext.parcelManager.getAllCargoCustomFilter(function(c) return c.sourceStorage == storage.id and c._transientMove end)) do
        if ext.parcelManager.sameLocation(cargo._transientMove.targetLocation, con.location) then
          transientCargoSlots = transientCargoSlots + cargo.slots
        end
      end
    end
    return transientCargoSlots
  end

  local function loadTarget(storage, con, transientCargoSlots, usedCargoSlots)
    return {
      label = con.name,
      maxAmount = math.min(con.freeCargoSlots+transientCargoSlots, storage.storedVolume),
      selectedAmount = transientCargoSlots,
      location = con.location,
      containerVehicleInfo = {
        vehId = con.vehId,
        vehName = con.vehName,
        conName = con.name,
      },
      usedCargoSlots = usedCargoSlots,
      totalCargoSlots = con.totalCargoSlots,
    }
  end

  -- An empty container, or one whose only cargo is this storage's transient moves, takes the material.
  local function addLoadTargetsForContainer(targetLocations, storage, con)
    local transientCargoSlots = transientSlotsForStorage(storage, con)
    if storage.storedVolume > 0 then
      -- use empty containers or same-fluids containers with remaining space
      if con.usedCargoSlots-transientCargoSlots == 0 then
        table.insert(targetLocations, loadTarget(storage, con, transientCargoSlots, 0))
      end
      if (con.freeCargoSlots+transientCargoSlots) > 0 and next(con.rawCargo) and con.rawCargo[1].materialType == storage.materialType then
        table.insert(targetLocations, loadTarget(storage, con, transientCargoSlots, con.usedCargoSlots - transientCargoSlots))
      end
    end
  end

  local function formatLoadTargets(storage, playerCargoContainers)
    local targetLocations = {}
    if not storage or not storage.materialType then
      return targetLocations
    end
    for _, con in ipairs(playerCargoContainers) do
      local materialData = ext.generator.getMaterialsTemplatesById(storage.materialType)
      if materialData and con.cargoTypesLookup[materialData.type] then
        addLoadTargetsForContainer(targetLocations, storage, con)
      end
    end
    return targetLocations
  end

  -- Storage cards -----------------------------------------------------------------------------------

  -- Equipment that can take this material, counted by its full capacity.
  local function storageCapacityFor(playerCargoContainers, material)
    local capacity = 0
    for _, con in ipairs(playerCargoContainers or {}) do
      if con.cargoTypesLookup and con.cargoTypesLookup[material.type] then
        capacity = capacity + math.max(0, con.totalCargoSlots or con.freeCargoSlots or 0)
      end
    end
    return capacity
  end

  -- A contract offer the facility posts: its pay, trips and lock state, for the player to accept.
  local function formatOfferCard(offer, material, playerCargoContainers)
    local locked, flagDefinition = ext.parcelMods.lockedBecauseOfMods({[material.type]=true})
    local equipmentCapacity = storageCapacityFor(playerCargoContainers, material)
    local offerData = {
      id = offer.id,
      materialContractId = offer.id,
      cardType = "materialContractOffer",
      isFacilityCard = true,
      name = _tr(offer.materialName),
      materialType = offer.materialType,
      material = material,
      destinationName = _tr(offer.destinationName),
      destinationNameLong = _tr(offer.destinationName),
      distance = offer.routeDistance,
      slots = offer.totalAmount,
      units = offer.units or material.units or "L",
      standardLoad = offer.standardLoad,
      standardLoadCount = offer.quantityMode ~= "exact" and offer.loadCount or nil,
      estimatedTrips = equipmentCapacity > 0 and math.ceil(offer.totalAmount / equipmentCapacity) or 0,
      estimatedStandardLoadPay = (offer.quotedRewards.money or 0) / math.max(1, offer.loadCount),
      rewardMoney = offer.quotedRewards.money or 0,
      quotedRewards = offer.quotedRewards,
      abandonmentRate = 0.15,
      remainingTime = {type = "offer", time = math.max(0, offer.offerExpiresAt - ext.general.time())},
      modifiers = {},
      enabled = not locked,
      unlockInfo = flagDefinition and flagDefinition.unlockInfo,
      bigMapIds = {},
    }
    -- On a company shift the company pays through escrow, so the personal pay fields are hidden.
    local empOnShift = overhaul_career_work_employment.isOnShift()
    if empOnShift then
      offerData.rewardMoney = nil
      offerData.estimatedStandardLoadPay = nil
      offerData.quotedRewards = nil
      offerData.companyEmployment = true
    end
    local label, desc = ext.parcelMods.getLabelAndShortDescription(material.type)
    table.insert(offerData.modifiers, {type = material.type, icon = ext.parcelMods.getModifierIcon(material.type), active = true, label = label, description = desc})
    if locked then offerData.disableReason = flagDefinition.lockedReason
    elseif inputs.ownerOpBlocksPerDiemOffer(offer) then
      offerData.enabled = false
      offerData.disableReason = inputs.OWNER_OP_PER_DIEM_BLOCK
    end
    return offerData
  end

  local function applyActiveContractCardPolicy(activeData, active, material, pickupName, atContractPickup)
    local empOnShift = overhaul_career_work_employment.isOnShift()
    if empOnShift then
      activeData.rewardMoney = nil
      activeData.quotedRewards = nil
      activeData.paidMoney = nil
      activeData.escrowedMoney = nil
      activeData.remainingValue = nil
      activeData.abandonmentFine = nil
      activeData.companyEmployment = true
    end
    for _, targetLocation in ipairs(activeData.targetLocations) do
      activeData._transientMaterialMoveAmount = activeData._transientMaterialMoveAmount + targetLocation.selectedAmount
    end
    if not atContractPickup then
      activeData.enabled = false
      activeData.disableReason = {type = "wrongPickup", label = string.format("Go to %s to load.", pickupName)}
    elseif active.loadableAmount <= 0 then
      activeData.enabled = false
      activeData.disableReason = {type = "inTransit", label = "All remaining material is already in transit."}
    elseif inputs.ownerOpBlocksPerDiemOffer(active) then
      activeData.enabled = false
      activeData.disableReason = inputs.OWNER_OP_PER_DIEM_BLOCK
    end
    local label, desc = ext.parcelMods.getLabelAndShortDescription(material.type)
    table.insert(activeData.modifiers, {type = material.type, icon = ext.parcelMods.getModifierIcon(material.type), active = true, label = label, description = desc})
  end

  -- An accepted contract at this facility: what is left to load, where, and what it pays.
  local function formatActiveContractCard(fac, active, playerCargoContainers)
    if active.sourceFacId ~= fac.id or active.status ~= "active" then return nil end
    local material = ext.generator.getMaterialsTemplatesById(active.materialType)
    local sourceStorage = fac.materialStorages and fac.materialStorages[active.materialType]
    if not (material and sourceStorage) then return nil end

    local virtualStorage = deepcopy(sourceStorage)
    virtualStorage.storedVolume = active.sourceReservedAmount
    virtualStorage.capacity = active.totalAmount
    local atContractPickup = active.origin and active.origin.psPath == screen.cargoScreenPsPath
    local pickupName = string.format("%s loading point", _tr(active.sourceName))
    local activeData = {
      id = active.id,
      storageId = sourceStorage.id,
      materialContractId = active.id,
      materialContractActive = true,
      sourceFacId = active.sourceFacId,
      origin = deepcopy(active.origin),
      cardType = "storage",
      isFacilityCard = true,
      name = _tr(active.materialName),
      materialType = active.materialType,
      material = material,
      storage = virtualStorage,
      targetLocations = atContractPickup and formatLoadTargets(virtualStorage, playerCargoContainers) or {},
      destinationName = _tr(active.destinationName),
      destinationNameLong = _tr(active.destinationName),
      pickupName = pickupName,
      pickupNameLong = pickupName,
      atContractPickup = atContractPickup,
      distance = active.routeDistance,
      slots = active.remainingAmount,
      units = active.units or material.units or "L",
      rewardMoney = active.remainingValue,
      quotedRewards = active.quotedRewards,
      deliveredAmount = active.deliveredAmount,
      inTransitAmount = active.inTransitAmount,
      remainingAmount = active.remainingAmount,
      paidMoney = active.paidMoney,
      escrowedMoney = active.escrowedMoney or active.paidMoney,
      remainingValue = active.remainingValue,
      abandonmentFine = active.abandonmentFine,
      standardLoad = active.standardLoad,
      standardLoadCount = active.quantityMode ~= "exact" and active.loadCount or nil,
      modifiers = {},
      enabled = atContractPickup and active.loadableAmount > 0,
      _transientMaterialMoveAmount = 0,
      bigMapIds = {},
    }
    applyActiveContractCardPolicy(activeData, active, material, pickupName, atContractPickup)
    return activeData
  end

  function api.formatMaterialStorage(fac, facPsLocation, playerCargoContainers)
    table.sort(playerCargoContainers, function(a,b) return a.freeCargoSlots < b.freeCargoSlots end)
    local data = { }
    if not ext.materialContracts then return data end
    local activeContracts = ext.materialContracts.getActiveContracts()

    for _, offer in ipairs(ext.materialContracts.getOffersForFacility(fac.id)) do
      local material = ext.generator.getMaterialsTemplatesById(offer.materialType)
      if material then
        local offerData = formatOfferCard(offer, material, playerCargoContainers)
        table.insert(data, offerData)
        inputs.addCard(offerData)
      end
    end

    for _, active in ipairs(activeContracts) do
      local activeData = formatActiveContractCard(fac, active, playerCargoContainers)
      if activeData then
        table.insert(data, 1, activeData)
        inputs.addCard(activeData)
      end
    end
    return data
  end

  -- Routes ------------------------------------------------------------------------------------------

  -- Sets the bigMap route to one end of a contract. Without a contract id, the active contract is used.
  local function routeToContract(contractId, showMessage, point, messageFor)
    -- Employment may call with (showMessage) only; resolve active/assigned contract.
    if type(contractId) ~= "string" and type(contractId) ~= "number" then
      showMessage = contractId
      local fallback = ext.materialContracts and ext.materialContracts.getActiveContract()
      contractId = fallback and fallback.id
    end
    local active = ext.materialContracts and ext.materialContracts.getContractById(contractId)
    if not active or active.status ~= "active" or not active[point] then return false end
    local toPos = ext.generator.getLocationCoordinates(active[point])
    if not toPos then return false end
    if ext.general and ext.general.setDeliveryNavFocus then
      ext.general.setDeliveryNavFocus(toPos)
    else
      freeroam_bigMapMode.setNavFocus(toPos)
    end
    core_groundMarkers.setPath({toPos}, {clearPathOnReachingTarget = false})
    if showMessage ~= false then
      ui_message(messageFor(active), 6, "info")
    end
    return true
  end

  function api.setMaterialContractPickupRoute(contractId, showMessage)
    return routeToContract(contractId, showMessage, "origin", function(active)
      return string.format("Route set: go to %s loading point to load %s.", _tr(active.sourceName), _tr(active.materialName))
    end)
  end

  function api.setMaterialContractDestinationRoute(contractId, showMessage)
    return routeToContract(contractId, showMessage, "destination", function(active)
      return string.format("Route set: deliver %s to %s.", _tr(active.materialName), _tr(active.destinationName))
    end)
  end

  -- Pickup screen -----------------------------------------------------------------------------------

  local function isAtActiveMaterialPickup(contractId, facId, psPath)
    local active = ext.materialContracts and ext.materialContracts.getContractById(contractId)
    return active and active.status == "active" and active.origin
      and active.origin.facId == facId and active.origin.psPath == psPath
  end

  -- One row per container: whether it takes this material, and why not when it cannot.
  local function pickupEquipment(playerCargoContainers, material, active)
    local equipment = {}
    local compatibleCapacity = 0
    for _, con in ipairs(playerCargoContainers or {}) do
      local supportsType = con.cargoTypesLookup and con.cargoTypesLookup[material.type]
      local carriesOtherMaterial = next(con.rawCargo or {}) and con.rawCargo[1].materialType ~= active.materialType
      local free = math.max(0, tonumber(con.freeCargoSlots) or 0)
      local eligible = supportsType and not carriesOtherMaterial and free > 0
      if eligible then compatibleCapacity = compatibleCapacity + free end
      local reason
      if not supportsType then
        reason = string.format("Not compatible with %s", _tr(material.name))
      elseif carriesOtherMaterial then
        reason = "Contains a different material"
      elseif free <= 0 then
        reason = "Container is full"
      end
      equipment[#equipment + 1] = {
        vehId = con.vehId,
        containerId = con.containerId,
        vehicleName = con.vehName or "Vehicle",
        containerName = con.name or "Cargo container",
        used = math.max(0, tonumber(con.usedCargoSlots) or 0),
        capacity = math.max(0, tonumber(con.totalCargoSlots) or 0),
        free = free,
        eligible = eligible and true or false,
        reason = reason,
      }
    end
    return equipment, compatibleCapacity
  end

  -- Company shifts hide the pay fields: the company pays through escrow.
  local function blankCompanyPayFields(uiContract)
    if type(uiContract.quotedRewards) == "table" then
      uiContract.quotedRewards = deepcopy(uiContract.quotedRewards)
      uiContract.quotedRewards.money = nil
    end
    if type(uiContract.paidRewards) == "table" then
      uiContract.paidRewards = deepcopy(uiContract.paidRewards)
      uiContract.paidRewards.money = nil
    end
    uiContract.paidMoney = nil
    uiContract.escrowedMoney = nil
    uiContract.remainingValue = nil
  end

  local function formatMaterialPickupData(playerCargoContainers)
    local active = ext.materialContracts and ext.materialContracts.getContractById(screen.materialPickupContractId)
    if not active or active.status ~= "active" then
      return {available = false, reason = "There is no active material contract."}
    end
    if not isAtActiveMaterialPickup(screen.materialPickupContractId, screen.materialPickupFacId, screen.materialPickupPsPath) then
      return {available = false, reason = "This is not the contract loading point."}
    end

    local material = ext.generator.getMaterialsTemplatesById(active.materialType)
    if not material then return {available = false, reason = "The contract material is unavailable."} end

    local equipment, compatibleCapacity = pickupEquipment(playerCargoContainers, material, active)
    local loadable = math.max(0, tonumber(active.loadableAmount) or 0)
    local uiContract = deepcopy(active)
    uiContract.sourceName = _tr(active.sourceName)
    uiContract.destinationName = _tr(active.destinationName)
    uiContract.materialName = _tr(active.materialName)
    local emp = overhaul_career_work_employment
    local companyEmployment = emp and emp.isOnShift() or false
    if companyEmployment then
      blankCompanyPayFields(uiContract)
    end
    return {
      available = true,
      contract = uiContract,
      material = {name = _tr(material.name), type = material.type, units = active.units or material.units or "L"},
      equipment = equipment,
      equipmentHint = require('overhaul/lib/logistics/cargoSemantics').material(material.type).loadingHint or '',
      compatibleCapacity = compatibleCapacity,
      maximumLoad = math.min(loadable, compatibleCapacity),
      loading = screen.materialPickupLoadInProgress,
      companyEmployment = companyEmployment,
    }
  end

  function api.requestMaterialContractPickupData()
    if not screen.materialPickupScreenOpen then return false end
    ext.general.getNearbyVehicleCargoContainers(function(playerCargoContainers)
      if screen.materialPickupScreenOpen then
        guihooks.trigger("materialContractPickupData", formatMaterialPickupData(playerCargoContainers))
      end
    end)
    return true
  end

  function api.closeMaterialContractPickupScreen(setRoute)
    local contractId = screen.materialPickupContractId
    screen.materialPickupScreenOpen = false
    screen.materialPickupFacId, screen.materialPickupPsPath, screen.materialPickupContractId = nil, nil, nil
    screen.materialPickupLoadInProgress = false
    simTimeAuthority.pause(false)
    if setRoute == true then api.setMaterialContractDestinationRoute(contractId, false) end
    guihooks.trigger("ChangeState", {state = "play"})
    overhaul_integration_services_markerInteraction.setForceReevaluateOpenPrompt()
  end

  function api.enterMaterialContractPickupScreen(contractId, facId, psPath)
    if not isAtActiveMaterialPickup(contractId, facId, psPath) then
      ui_message("Go to the contract's marked loading point to load material.", 5, "warning")
      api.setMaterialContractPickupRoute(contractId, false)
      return false
    end
    screen.materialPickupFacId, screen.materialPickupPsPath, screen.materialPickupContractId = facId, psPath, contractId
    screen.materialPickupScreenOpen = true
    screen.materialPickupLoadInProgress = false
    overhaul_integration_services_markerInteraction.closeViewDetailPrompt(true)
    simTimeAuthority.pause(true)
    guihooks.trigger("ChangeState", {state = "overhaul.materialContractPickup"})
    return true
  end

  -- Containers that take this material from the pickup, same material or empty first, then the emptiest.
  local function pickupEligibleContainers(playerCargoContainers, material, active)
    local eligible = {}
    for _, con in ipairs(playerCargoContainers or {}) do
      local supportsType = con.cargoTypesLookup and con.cargoTypesLookup[material.type]
      local sameOrEmpty = not next(con.rawCargo or {}) or con.rawCargo[1].materialType == active.materialType
      if supportsType and sameOrEmpty and (con.freeCargoSlots or 0) > 0 then eligible[#eligible + 1] = con end
    end
    table.sort(eligible, function(a, b)
      local aSame = next(a.rawCargo or {}) and 1 or 0
      local bSame = next(b.rawCargo or {}) and 1 or 0
      if aSame ~= bSame then return aSame > bSame end
      return (a.freeCargoSlots or 0) < (b.freeCargoSlots or 0)
    end)
    return eligible
  end

  -- Returns how much was loaded.
  local function loadIntoContainers(eligible, requested, facStorage, active)
    local remaining = requested
    local loaded = 0
    for _, con in ipairs(eligible) do
      if remaining <= 0 then break end
      local loadAmount = math.min(remaining, con.freeCargoSlots or 0)
      if loadAmount > 0 and ext.generator.addMaterialAsParcelToContainer(con, facStorage, loadAmount, active.sourceFacId, active.origin.psPath, active.id) then
        remaining = remaining - loadAmount
        loaded = loaded + loadAmount
      end
    end
    return loaded
  end

  function api.loadMaterialContract(contractId, amount)
    if not screen.materialPickupScreenOpen or screen.materialPickupLoadInProgress or contractId ~= screen.materialPickupContractId then return false end
    screen.materialPickupLoadInProgress = true
    ext.general.getNearbyVehicleCargoContainers(function(playerCargoContainers)
      local active = ext.materialContracts and ext.materialContracts.getContractById(contractId)
      local material = active and ext.generator.getMaterialsTemplatesById(active.materialType)
      local fac = active and ext.generator.getFacilityById(active.sourceFacId)
      local facStorage = fac and fac.materialStorages and fac.materialStorages[active.materialType]
      if not active or not material or not facStorage or not isAtActiveMaterialPickup(contractId, screen.materialPickupFacId, screen.materialPickupPsPath) then
        screen.materialPickupLoadInProgress = false
        guihooks.trigger("materialContractPickupResult", {success = false, message = "The contract loading point is no longer available."})
        api.requestMaterialContractPickupData()
        return
      end

      local requested = math.min(math.max(0, tonumber(amount) or 0), active.loadableAmount or 0)
      local eligible = pickupEligibleContainers(playerCargoContainers, material, active)
      local loaded = loadIntoContainers(eligible, requested, facStorage, active)

      if loaded > 0 then
        ext.parcelManager.applyTransientMoves(active.origin)
        if not ext.general.isDeliveryModeActive() then ext.general.startDeliveryMode() end
        ext.general.requestUpdateContainerWeights()
        overhaul_career_logistics_tasklist.sendCargoToTasklist()
        ext.materialContracts.refreshTaskGuidance(true)
        Engine.Audio.playOnce("AudioGui", "event:>UI>Missions>Info_Open")
        guihooks.trigger("materialContractPickupResult", {
          success = true,
          amount = loaded,
          message = string.format("Loaded %d %s. Deliver it to %s.", math.floor(loaded + 0.5), active.units or "L", _tr(active.destinationName)),
        })
        api.closeMaterialContractPickupScreen(true)
      else
        screen.materialPickupLoadInProgress = false
        guihooks.trigger("materialContractPickupResult", {success = false, message = "No compatible free container space is nearby."})
        api.requestMaterialContractPickupData()
      end
    end)
    return true
  end

  -- Cargo moves -------------------------------------------------------------------------------------

  -- Moves the cargo to a different location. Moved onto the player it gets a transient flag; moved back to the facility, the flag goes.
  function api.moveCargoFromUi(cargoId, targetLocation)
    local emp = overhaul_career_work_employment
    if emp and emp.canMoveCargoOntoLocation and not emp.canMoveCargoOntoLocation(cargoId, targetLocation) then
      if targetLocation and targetLocation.type == "facilityParkingspot" then
        ui_message("Drop off assigned cargo at the marked destination.", 5, "warning")
      else
        ui_message("This company vehicle can only carry your assigned load.", 5, "warning")
      end
      return
    end
    ext.parcelManager.addTransientMoveCargo(cargoId, targetLocation)
  end

  function api.toggleOfferForSpawning(offerId)
    local offer = ext.vehicleOfferManager.getOfferById(offerId)
    offer.spawnWhenCommitingCargo = not offer.spawnWhenCommitingCargo
  end

  return api
end

return part
