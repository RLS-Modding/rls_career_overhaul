-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- RLS Career Overhaul · https://github.com/RLS-Modding/rls_career_overhaul
-- RLS modifications: Copyright (C) RLS Modding

-- Logistics generator: material storage, material cargo and generator dispatch.
-- Read getMaterialsTemplates, clampStoredVolume, sizeMaterialGenerator, startingVolume, setupMaterialStorage in order.

local part = {}

-- Builds material storage, material cargo and generator dispatch for one generator instance. Nothing is kept
-- at file level, so each load of generator.lua gets its own closures over its own state.
function part.new(inputs)
  local ext, gen = inputs.services.ext, inputs.state.gen

  -- Storage -----------------------------------------------------------------------------------------

  local function getMaterialsTemplates()
    return inputs.services.sharedTemplates.loadMaterialTemplates()
  end

  -- Keeps a storage's volume between empty and its capacity.
  local function clampStoredVolume(storage)
    if storage.storedVolume > storage.capacity then storage.storedVolume = storage.capacity end
    if storage.storedVolume < 0 then storage.storedVolume = 0 end
  end

  -- Sets the generator's target, capacity and rate from its contract rules. Returns the sizing it used.
  local function sizeMaterialGenerator(generator, materialData)
    local contractRules = inputs.services.xpConfig.getMaterialContractRules()
    local standardLoad = (contractRules.standardLoadByMaterial or {})[generator.materialType]
      or (contractRules.standardLoadByType or {})[materialData and materialData.type]
      or 1
    local loadRange = (generator.materialType == "cash" or generator.materialType == "coin" or generator.materialType == "gold")
      and contractRules.secureLoadCount or contractRules.bulkLoadCount
    local quantity = inputs.services.contractAmounts.resolve(generator, standardLoad, loadRange.min, loadRange.max)
    local maxContractVolume = quantity and quantity.maxAmount or standardLoad * (loadRange.max or 1)
    local configuredTarget = tonumber(generator.target) or 0
    local configuredCapacity = tonumber(generator.capacity) or configuredTarget
    local target = generator.type == "materialProvider" and math.max(configuredTarget, maxContractVolume) or configuredTarget
    local capacity = nil
    if generator.type == "materialProvider" then
      capacity = math.max(configuredCapacity, target + standardLoad)
    else
      capacity = math.max(configuredCapacity, target + maxContractVolume)
    end
    generator.target = target
    generator.capacity = capacity
    if generator.interval and generator.interval > 0 then
      generator.rate = standardLoad * generator.interval / contractRules.stockCycleSecondsPerLoad
    end
    return {target = target, capacity = capacity, standardLoad = standardLoad, maxContractVolume = maxContractVolume}
  end

  -- The volume a storage starts with: the saved one when the save has it, else the target.
  local function startingVolume(fac, generator, target, capacity)
    local vol = target
    local previousCapacity = nil
    -- Some semi-old saves store a bare number instead of a storage table.
    local saved = fac.materialStorages[generator.materialType]
    if saved and type(saved) == "table" then
      previousCapacity = saved.capacity
      vol = saved.storedVolume
    elseif saved and type(saved) == 'number' then
      vol = saved
    end
    -- Expand old provider capacity once so the storage can seed the newly configured contracts.
    if generator.type == "materialProvider" and previousCapacity and previousCapacity < capacity then
      vol = math.max(vol or 0, target)
    end
    return vol
  end

  local function setupMaterialStorage(fac, generator)
    local materialData = inputs.callbacks.getMaterialsTemplatesById(generator.materialType)
    local sizing = sizeMaterialGenerator(generator, materialData)
    local vol = startingVolume(fac, generator, sizing.target, sizing.capacity)
    local previous = fac.materialStorages[generator.materialType]
    previous = type(previous) == 'table' and previous._configuredThisSetup and previous or nil
    local storage = {
      _configuredThisSetup = true,
      id = fac.id .. "-storage-" .. generator.materialType,
      materialType = generator.materialType,
      capacity = sizing.capacity,
      isProvider = generator.type == "materialProvider" or previous and previous.isProvider or false,
      isReceiver = generator.type == "materialReceiver" or previous and previous.isReceiver or false,
      target = sizing.target,
      storedVolume = tonumber(vol) or sizing.target,
      standardLoad = sizing.standardLoad,
      maxContractVolume = sizing.maxContractVolume,
    }
    if previous then
      storage.capacity = math.max(storage.capacity, previous.capacity or 0)
      storage.target = math.max(storage.target, previous.target or 0)
      storage.maxContractVolume = math.max(storage.maxContractVolume, previous.maxContractVolume or 0)
    end
    clampStoredVolume(storage)
    fac.materialStorages[generator.materialType] = storage
  end

  -- Material cargo ----------------------------------------------------------------------------------
  -- The contract's loading parcel at its source facility, before the parcel is registered.
  local function contractMaterialItem(fac, storage, contract, materialData, amount)
    local origin = deepcopy(contract.origin)
    local destination = deepcopy(contract.destination)
    return {
      templateId = -1,
      name = core_locales.contextTranslate("ui.career.delivery.cargoName.materialFromFacility", {material = materialData.name, facility = fac.name}),
      type = materialData.type,
      slots = amount,
      materialType = storage.materialType,
      merge = true,
      offerExpiresAt = math.huge,
      data = {
        delivered = false,
        originalDistance = contract.routeDistance,
        materialContractId = contract.id,
        frozenQuote = deepcopy(contract.quotedRewards),
        frozenQuoteAmount = contract.totalAmount,
        frozenRouteFactor = contract.routeFactor,
      },
      rewards = ext.materialContracts.getProportionalRewards(contract.id, amount),
      modifiers = {},
      location = deepcopy(origin),
      origin = deepcopy(origin),
      destination = destination,
      generatorLabel = "addMaterialAsParcelToContainer",
      weight = amount * materialData.density,
      generatedAtTimestamp = ext.general.time(),
      groupSeed = round(math.random() * 1000000),
      automaticDropOff = false,
      hiddenInFacility = true,
      sourceStorage = storage.id,
      organization = fac.associatedOrganization,
    }
  end

  -- Loads a contract's material into a container: registers the parcel and moves it there.
  local function addMaterialAsParcelToContainer(con, storage, amount, sourceFacId, sourcePsPath, contractId)
    local materialType = storage.materialType
    local materialData = inputs.callbacks.getMaterialsTemplatesById(materialType)
    local contract = ext.materialContracts and ext.materialContracts.getContractById(contractId)
    if not contract or contract.status ~= "active" or contract.sourceFacId ~= sourceFacId or contract.materialType ~= materialType then
      log("W", "", string.format("Rejected material loading without a matching active contract at %s", tostring(sourceFacId)))
      return nil
    end
    amount = math.min(math.max(0, tonumber(amount) or 0), contract.loadableAmount or 0)
    if amount <= 0 then return nil end
    local fac = gen.facilitiesById[sourceFacId]
    local item = contractMaterialItem(fac, storage, contract, materialData, amount)

    local label, desc = ext.parcelMods.getLabelAndShortDescription(materialData.type)
    table.insert(item.modifiers, {type = materialData.type, icon = ext.parcelMods.getModifierIcon(materialData.type), active = true, label = label, description = desc})

    gen.groupId = gen.groupId + 1
    item.groupId = gen.groupId
    gen.cargoId = gen.cargoId + 1
    item.id = gen.cargoId
    ext.parcelManager.addCargo(item, true)
    ext.parcelManager.addTransientMoveCargo(item.id, con.location)
    return item
  end

  -- Gives supply parcels their group and cargo ids, then places the parcel in the container.
  local function registerSupplyCargo(con, item)
    gen.groupId = gen.groupId + 1
    gen.cargoId = gen.cargoId + 1
    item.groupId = gen.groupId
    item.groupSeed = gen.groupId
    item.id = gen.cargoId
    ext.parcelManager.addCargo(item, true)
    ext.parcelManager.addTransientMoveCargo(item.id, con.location)
    return item
  end

  -- One supply destination goes straight; several are collected into a multi-destination.
  local function supplyDestination(destinations)
    if #destinations == 1 then return deepcopy(destinations[1]) end
    return {type = "multi", destinations = deepcopy(destinations)}
  end

  -- Physical supply parcels retain durable ownership in the business reservation.
  local function addPassiveBusinessSupplyCargo(con, reservation, origin, destinations)
    if not con or not reservation or not origin or not destinations or #destinations == 0 then return nil end
    local templateId = reservation.supplyTemplateId or ((reservation.supplyType or "miniMartSupplies") .. "Pallet")
    local template = inputs.callbacks.getParcelTemplateById(templateId)
    if not template then
      templateId = "miniMartSuppliesPallet"
      template = inputs.callbacks.getParcelTemplateById(templateId)
    end
    local slots = tonumber(reservation.supplySlots) or tonumber(template and template.slots) or 128
    local weight = template and template.weight or nil
    if type(weight) == "table" then weight = weight[1] end
    weight = tonumber(weight) or 200
    if not (con.cargoTypesLookup and con.cargoTypesLookup.parcel) or (con.freeCargoSlots or 0) < slots then return nil end
    local destination = supplyDestination(destinations)
    local item = {
      templateId = templateId,
      name = reservation.supplyName or (template and template.names and template.names[1]) or "Business Supplies",
      type = "parcel",
      slots = slots,
      offerExpiresAt = math.huge,
      data = {
        delivered = false,
        passiveBusinessSupplyReservationId = reservation.id,
        passiveBusinessArchetypeId = reservation.archetypeId,
        passiveBusinessSupplyType = reservation.supplyType,
        noDeliveryReward = true,
      },
      rewards = {money = 0},
      modifiers = {},
      location = deepcopy(origin),
      origin = deepcopy(origin),
      destination = destination,
      generatorLabel = "passiveBusinessSupply",
      weight = weight,
      generatedAtTimestamp = ext.general.time(),
      automaticDropOff = false,
      hiddenInFacility = true,
    }
    return registerSupplyCargo(con, item)
  end

  local function addEngineShopSupplyCargo(con, reservation, origin, destinations)
    if not con or not reservation or not origin or not destinations or #destinations == 0 then return nil end
    if not (con.cargoTypesLookup and con.cargoTypesLookup.parcel) or (con.freeCargoSlots or 0) < 128 then return nil end
    local destination = supplyDestination(destinations)
    local template = inputs.callbacks.getParcelTemplateById("miniMartSuppliesPallet")
    local item = {
      templateId = "miniMartSuppliesPallet",
      name = "Engine Production Materials",
      type = "parcel",
      slots = 128,
      offerExpiresAt = math.huge,
      data = {
        delivered = false,
        engineShopSupplyReservationId = reservation.id,
        engineShopBusinessId = reservation.businessId,
        engineShopRevisionId = reservation.revisionId,
        noDeliveryReward = true,
      },
      rewards = {money = 0},
      modifiers = {},
      location = deepcopy(origin),
      origin = deepcopy(origin),
      destination = destination,
      generatorLabel = "engineShopSupply",
      weight = tonumber(template and template.weight) or 450,
      generatedAtTimestamp = ext.general.time(),
      automaticDropOff = false,
      hiddenInFacility = true,
    }
    return registerSupplyCargo(con, item)
  end

  local function splitOffPartsFromMaterialCargo(cargo, otherPartSizes)
    cargo.data = cargo.data or {}
    cargo.data.ownerOpSourceCargoId = cargo.data.ownerOpSourceCargoId or cargo.id
    local ret = {cargo}
    local materialData = inputs.callbacks.getMaterialsTemplatesById(cargo.materialType)
    for _, size in ipairs(otherPartSizes or {}) do
      -- Split off a material parcel for this part.
      local copy = deepcopy(cargo)
      gen.groupId = gen.groupId + 1
      copy.groupId = gen.groupId
      gen.cargoId = gen.cargoId + 1
      copy.id = gen.cargoId
      ext.parcelManager.addCargo(copy, true)

      -- The copy takes the slots and weight that go into storage.
      copy.slots = size
      copy.weight = materialData.density * copy.slots
      if cargo.data and cargo.data.materialContractId and ext.materialContracts then
        copy.rewards = ext.materialContracts.getProportionalRewards(cargo.data.materialContractId, copy.slots)
      else
        copy.rewards.money = inputs.services.sharedCalc.getMaterialReward(materialData, copy.slots).money
      end
      table.insert(ret, copy)

      cargo.slots = cargo.slots - size
      cargo.weight = materialData.density * cargo.slots
      if cargo.data and cargo.data.materialContractId and ext.materialContracts then
        cargo.rewards = ext.materialContracts.getProportionalRewards(cargo.data.materialContractId, cargo.slots)
      else
        cargo.rewards.money = inputs.services.sharedCalc.getMaterialReward(materialData, cargo.slots).money
      end

      if not (cargo.data and cargo.data.materialContractId) then
        local ecoSection = "delivery_" .. (materialData.type or "fluid")
        local copyMoney, copyMult = inputs.services.sharedCalc.applyEconomyAdjuster(copy.rewards.money, ecoSection)
        local cargoMoney, cargoMult = inputs.services.sharedCalc.applyEconomyAdjuster(cargo.rewards.money, ecoSection)
        copy.rewards.money = copyMoney
        copy.rewards.economyMultiplier = copyMult or 1
        cargo.rewards.money = cargoMoney
        cargo.rewards.economyMultiplier = cargoMult or 1
      end
    end
    return ret
  end

  -- Contract quantities are committed already; ordinary receivers still split cargo to fit free capacity.
  local function moveMaterialToDestination(cargo, destination)
    local fac = gen.facilitiesById[destination.facId]
    local storage = fac.materialStorages[cargo.materialType]

    if cargo.data and cargo.data.materialContractId then
      ext.parcelManager.changeCargoLocation(cargo.id, destination)
      return cargo, nil
    end

    if cargo.slots <= storage.capacity - storage.storedVolume then
      ext.parcelManager.changeCargoLocation(cargo.id, destination)
      return cargo, nil
    end

    local amountForTank = storage.capacity - storage.storedVolume
    local materialData = inputs.callbacks.getMaterialsTemplatesById(cargo.materialType)

    -- Split off the part that fits in the tank.
    local copy = deepcopy(cargo)
    gen.groupId = gen.groupId + 1
    copy.groupId = gen.groupId
    gen.cargoId = gen.cargoId + 1
    copy.id = gen.cargoId
    ext.parcelManager.addCargo(copy, true)

    -- The cargo keeps what the tank does not take.
    cargo.slots = cargo.slots - amountForTank
    cargo.weight = materialData.density * cargo.slots
    cargo.rewards.money = inputs.services.sharedCalc.getMaterialReward(materialData, cargo.slots).money

    -- The copy takes the tank's share.
    copy.slots = amountForTank
    copy.weight = materialData.density * copy.slots
    copy.rewards.money = inputs.services.sharedCalc.getMaterialReward(materialData, copy.slots).money

    local ecoSection = "delivery_" .. (materialData.type or "fluid")
    local cargoMoney, cargoMult = inputs.services.sharedCalc.applyEconomyAdjuster(cargo.rewards.money, ecoSection)
    local copyMoney, copyMult = inputs.services.sharedCalc.applyEconomyAdjuster(copy.rewards.money, ecoSection)
    cargo.rewards.money = cargoMoney
    cargo.rewards.economyMultiplier = cargoMult or 1
    copy.rewards.money = copyMoney
    copy.rewards.economyMultiplier = copyMult or 1

    ext.parcelManager.changeCargoLocation(copy.id, destination)
    return copy, cargo
  end

  -- Facility amounts --------------------------------------------------------------------------------

  local function changeMaterialAmountInFacility(facId, materialType, change)
    if not inputs.callbacks.getFacilityById(facId) then return end
    local fac = inputs.callbacks.getFacilityById(facId)
    if not fac.materialStorages or not fac.materialStorages[materialType] then return end

    local storage = fac.materialStorages[materialType]
    local facName = _tr(fac.name)
    log("I", "", string.format("Moved %d %s from %s (%d -> %d)", change, materialType, facName, storage.storedVolume, storage.storedVolume + change))

    storage.storedVolume = storage.storedVolume + change
    if storage.storedVolume > storage.capacity then
      log("W", "", string.format("Stored too much %s in %s (from %d, added %d, maximum %d) : %d too much", materialType, facName, storage.storedVolume-change, change, storage.capacity, storage.storedVolume+change-storage.capacity))
      storage.storedVolume = storage.capacity
    end
    if storage.storedVolume < 0 then
      log("W", "", string.format("Took too much %s from %s (from %d, removed %d) : %d too much", materialType, facName, storage.storedVolume-change, -change, -change-storage.storedVolume))
      storage.storedVolume = 0
    end
  end

  -- Distances ---------------------------------------------------------------------------------------
  -- Kept as a no-op: the facade and the cargo-fluid debug tool still call it per facility.
  local function finalizeMaterialDistances(fac)
    if fac.closestMaterialProviders then return end
  end

  local function finalizeMaterialDistanceRewards(item, destination)
    local distance = inputs.callbacks.getDistanceBetweenFacilities(item.origin, destination)
    local materialData = inputs.callbacks.getMaterialsTemplatesById(item.materialType)
    if not materialData then
      log("E", "", string.format("Unable to finalize unknown bulk material '%s'", tostring(item.materialType)))
      return
    end
    local materialType = materialData.type or "fluid"
    -- Recomputes from the current definition and the carried amount, so loading-time modifiers do not compound.
    local baseMoney = inputs.services.sharedCalc.getMaterialReward(materialData, item.slots).money
    local rewards = inputs.services.sharedCalc.getMaterialXPReward(distance, item.slots, item.organization, nil, nil, baseMoney, materialType)
    item.rewards = item.rewards or {}
    for k, v in pairs(rewards) do
      item.rewards[k] = v
    end
    item.data = item.data or {}
    item.data.originalDistance = distance
  end

  -- Generator triggering ----------------------------------------------------------------------------

  local function triggerMaterialGenerator(fac, generator, timeOffset)
    local storage = fac.materialStorages[generator.materialType]
    if not storage then
      log("E", "", "Missing storage! " .. fac.id .. dumps(generator.generatorLabel))
      return
    end

    local distToTarget = math.abs(storage.target - storage.storedVolume)

    local chanceToFlip = 1 - ((distToTarget / (generator.variance or generator.capacity / 2)) + 0.5)
    chanceToFlip = clamp(chanceToFlip, 0, 1)

    local changeVolume = generator.rate * sign(storage.target - storage.storedVolume)
    if changeVolume == 0 then changeVolume = generator.rate end

    storage._rate = (changeVolume * (1 - chanceToFlip) - changeVolume * (chanceToFlip)) / generator.interval
    storage._rateMax = generator.rate / generator.interval

    if math.random() <= chanceToFlip then
      changeVolume = changeVolume * -1
    end

    local rateRandomizer = math.random() * 0.25 + 1 - 0.25 / 2

    changeVolume = round(changeVolume * rateRandomizer)

    storage.storedVolume = storage.storedVolume + changeVolume
    clampStoredVolume(storage)
  end

  local profileLabels = setmetatable({}, {__mode = "k"})

  local function triggerGenerator(fac, generator, timeOffset)
    if generator._bulkCompatibilityDisabled then return end
    local profileLabel = profileLabels[generator]
    if not profileLabel then
      profileLabel = "Generator: " .. generator.name
      profileLabels[generator] = profileLabel
    end
    local openDepth = #inputs.state.openEvents
    inputs.callbacks.profilerPushEvent(profileLabel)
    timeOffset = timeOffset or 0
    if generator.type == "parcelProvider" or generator.type == "parcelReceiver" then
      inputs.callbacks.triggerParcelGenerator(fac, generator, timeOffset)
    elseif generator.type == "vehOfferProvider" or generator.type == "trailerOfferProvider" then
      inputs.callbacks.triggerVehicleOfferGenerator(fac, generator, timeOffset)
    elseif generator.type == "materialProvider" or generator.type == "materialReceiver" then
      triggerMaterialGenerator(fac, generator, timeOffset)
    end

    inputs.callbacks.profilerPopEvent(profileLabel)
    -- Events a generator opened and never closed are not carried into later frames.
    for i = #inputs.state.openEvents, openDepth + 1, -1 do inputs.state.openEvents[i] = nil end
  end

  -- Public API --------------------------------------------------------------------------------------

  return {
    addEngineShopSupplyCargo = addEngineShopSupplyCargo,
    addMaterialAsParcelToContainer = addMaterialAsParcelToContainer,
    addPassiveBusinessSupplyCargo = addPassiveBusinessSupplyCargo,
    changeMaterialAmountInFacility = changeMaterialAmountInFacility,
    finalizeMaterialDistanceRewards = finalizeMaterialDistanceRewards,
    finalizeMaterialDistances = finalizeMaterialDistances,
    getMaterialsTemplates = getMaterialsTemplates,
    moveMaterialToDestination = moveMaterialToDestination,
    setupMaterialStorage = setupMaterialStorage,
    splitOffPartsFromMaterialCargo = splitOffPartsFromMaterialCargo,
    triggerGenerator = triggerGenerator,
  }
end

return part
