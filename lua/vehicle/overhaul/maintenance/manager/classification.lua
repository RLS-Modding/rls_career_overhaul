-- Owns installed-part category matching, hardware caches and device baseline capture.
-- Read part matching, category cache construction, then device contexts and public bindings.
local M = {}

function M.create(inputs)
  local runtime, config, parts = inputs.runtime, inputs.config, inputs.parts

  local function splitTag(tag)
    local parts = {}
    if type(tag) ~= "string" then
      return parts
    end
    for piece in string.gmatch(tag, "[^:]+") do
      table.insert(parts, piece)
    end
    return parts
  end

  local function lookForPowertrainClues(partId, partData)
    local tags
    for key, value in pairs(partData or {}) do
      if type(value) == "table" then
        if key == "powertrain" then
          local previousPartPath
          for index = 2, #value do
            if value[index].partPath then
              previousPartPath = value[index].partPath
            elseif #value[index] > 1 then
              local deviceName = value[index][2]
              local taggedPartId = previousPartPath or partId
              tags = tags or {}
              tags[taggedPartId] = tags[taggedPartId] or {}
              table.insert(tags[taggedPartId], "powertrainDevice:" .. deviceName)
            end
          end
        else
          if value.radiatorArea and not value.inertia then
            tags = tags or {}
            tags[partId] = tags[partId] or {}
            table.insert(tags[partId], string.format("powertrainDevice:%s:%s", key, "radiator"))
          elseif value.torqueModExhaust and not value.inertia then
            tags = tags or {}
            tags[partId] = tags[partId] or {}
            table.insert(tags[partId], string.format("powertrainDevice:%s:%s", key, "exhaust"))
          elseif value.turbocharger and not value.inertia then
            tags = tags or {}
            tags[partId] = tags[partId] or {}
            table.insert(tags[partId], string.format("powertrainDevice:%s:%s", key, "turbocharger"))
          end
        end
      end
    end
    return tags
  end

  -- What a part costs new stands in for how much of its subsystem it actually is.
  local function readPartValue(activePartData)
    local information = type(activePartData) == "table" and activePartData.information or nil
    local value = type(information) == "table" and tonumber(information.value) or nil
    if value and value > 0 then return value end
    return nil
  end

  local function ensureCategoryCache()
    runtime.categoryCache = {
      engine = {partIds = {}, partIdSet = {}, partLinks = {}, rootPartId = nil, rootDeviceName = nil},
      radiator = {partIds = {}, partIdSet = {}, partLinks = {}, rootPartId = nil, rootDeviceName = nil},
      transmission = {partIds = {}, partIdSet = {}, partLinks = {}, rootPartId = nil, rootDeviceName = nil}
    }
  end

  local function addPartToCategory(categoryName, partId, deviceName, subSystem)
    if not runtime.categoryCache[categoryName] or not partId then
      return
    end
    local cache = runtime.categoryCache[categoryName]
    if not cache.partIdSet[partId] then
      cache.partIdSet[partId] = true
      table.insert(cache.partIds, partId)
    end
    cache.partLinks[partId] = cache.partLinks[partId] or {}
    if deviceName then
      table.insert(cache.partLinks[partId], {deviceName = deviceName, subSystem = subSystem})
    end
  end

  local function matchesKeywordSet(partInfo, keywords)
    return config.partCategories.matchesDirect(partInfo, keywords)
  end

  local function isCombustionEngine(device)
    -- Substring match: mod engines use types such as "classic_combustionEngine".
    return tostring(device and device.type or ""):find("combustionEngine", 1, true) ~= nil
  end

  -- Generator shafts have tireless wheels and must not count as road traction.
  local function isRoadWheel(wheelName)
    local source = wheels and (wheels.wheelRotators or wheels.wheels) or {}
    local wheelData = source[wheelName]
    if not wheelData then
      for _, candidate in pairs(source) do
        if candidate.name == wheelName then
          wheelData = candidate
          break
        end
      end
    end
    if not wheelData then return false end
    return (tonumber(wheelData.tireVolume) or 0) > 0 or wheelData.wheelSection == "pressureWheels"
  end

  -- A generator's electric motor drives a tireless shaft, so it belongs to the powerplant.
  local function isGeneratorDevice(device)
    for _, child in ipairs(device.children or {}) do
      if child.connectedWheel and not isRoadWheel(child.connectedWheel) then return true end
    end
    return false
  end

  -- Accessories suppress the mounting fallback; nil leaves the device's category undecided.
  local ACCESSORY = "accessory"

  local function powertrainDeviceCategory(device)
    local categories = device and device.deviceCategories or nil
    if not categories then return nil end
    if categories.engine then
      if isCombustionEngine(device) or isGeneratorDevice(device) then return 'engine' end
      return ACCESSORY
    end
    -- Air compressors are tagged clutchlike but drive an accessory, not the wheels.
    if categories.pneumaticPowerSource or categories.torqueConsumer then return ACCESSORY end
    if categories.gearbox or categories.clutchlike or categories.clutch then return 'transmission' end
    return nil
  end

  -- A generator carries a motor and clutch, so rank their categories to give the part one owner.
  local categoryPriority = {engine = 1, transmission = 2}


  local function getDeviceVerdict(partId)
    local verdict = {explicit = false, accessory = false, radiatorDevices = {}, rank = math.huge}
    for _, tag in ipairs(runtime.partTypeTags[partId] or {}) do
      local pieces = splitTag(tag)
      if pieces[1] == "powertrainDevice" then
        local deviceName = pieces[2]
        local subSystem = pieces[3]
        if subSystem == "radiator" then
          verdict.explicit = true
          table.insert(verdict.radiatorDevices, deviceName)
        else
          local device = deviceName and powertrain.getDevice(deviceName) or nil
          local category = powertrainDeviceCategory(device)
          if category == ACCESSORY then
            verdict.explicit = true
            verdict.accessory = true
          elseif category then
            verdict.explicit = true
            local rank = categoryPriority[category]
            if rank < verdict.rank then
              verdict.category, verdict.rank, verdict.deviceName, verdict.subSystem = category, rank, deviceName, subSystem
            end
          end
        end
      end
    end
    return verdict
  end

  -- Accessory-only parts must not make their cosmetic children inherit a drivetrain slot name.
  local function passesCategoryToChildren(partInfo)
    local verdict = getDeviceVerdict(partInfo.constructedPartId)
    return not (verdict.accessory and not verdict.category)
  end

  local function preparePartMetadata()
    runtime.activePartInfos = {}
    runtime.partTypeTags = {}

    for partId, partTypeName in pairs(v.data.activeParts or {}) do
      local partInfo = runtime.activePartInfos[partId] or {}
      local slotPath = partId:match("^(.*[/])[^/]+$") or "/"
      partInfo.partId = partId
      partInfo.slotPath = slotPath
      partInfo.slotName = config.partCategories.getImmediateSlotName(slotPath)
      partInfo.partName = partId:match("([^/]+)$") or partId
      runtime.activePartInfos[partId] = partInfo

      local activePartData = v.data.activePartsData and v.data.activePartsData[partTypeName] or nil
      partInfo.partValue = readPartValue(activePartData)
      local clueTags = lookForPowertrainClues(partId, activePartData)
      if clueTags then
        for taggedPartId, tags in pairs(clueTags) do
          runtime.partTypeTags[taggedPartId] = runtime.partTypeTags[taggedPartId] or {}
          for _, tag in ipairs(tags) do
            table.insert(runtime.partTypeTags[taggedPartId], tag)
          end
        end
      end
    end

    config.partCategories.walkPartsTree(v.config and v.config.partsTree or {}, function(walkInfo)
      local partId = walkInfo.constructedPartId
      runtime.activePartInfos[partId] = runtime.activePartInfos[partId] or {}
      runtime.activePartInfos[partId].partId = partId
      runtime.activePartInfos[partId].partName = walkInfo.partName
      runtime.activePartInfos[partId].slotName = walkInfo.slotName
      runtime.activePartInfos[partId].slotPath = walkInfo.slotPath
      runtime.activePartInfos[partId].ownerCategory = walkInfo.ownerCategory
      local activePartData = v.data.activePartsData and v.data.activePartsData[walkInfo.partName] or nil
      local information = type(activePartData) == "table" and activePartData.information or nil
      runtime.activePartInfos[partId].displayName = type(information) == "table" and information.name or nil
      runtime.activePartInfos[partId].partValue = readPartValue(activePartData) or runtime.activePartInfos[partId].partValue
    end, passesCategoryToChildren)
  end

  local function classifyPart(partId, partInfo)
    local verdict = getDeviceVerdict(partId)
    -- Radiator data remains additive when it shares a part with an engine.
    for _, deviceName in ipairs(verdict.radiatorDevices) do
      addPartToCategory('radiator', partId, deviceName, 'radiator')
    end
    local foundExplicit = verdict.explicit

    if verdict.category then
      addPartToCategory(verdict.category, partId, verdict.deviceName, verdict.subSystem)
    end

    -- Only a confident accessory verdict blocks mounting-based classification for modded parts.
    if foundExplicit then
      return
    end

    local inferredCategory = partInfo.ownerCategory or config.partCategories.getDirectCategory(partInfo)
    if inferredCategory then addPartToCategory(inferredCategory, partId) end
  end

  -- A traction motor mounted in a differential must not earn drivetrain root credit from its location.
  local function linkBelongsToCategory(categoryName, link, device)
    if categoryName == 'radiator' then return link.subSystem == 'radiator' end
    local categories = device and device.deviceCategories or nil
    if not categories then return false end
    if categoryName == 'engine' then return categories.engine == true end
    if categoryName == 'transmission' then
      -- Torque converters declare clutchlike, so they qualify even without a clutch category.
      return categories.gearbox == true or categories.clutch == true or categories.clutchlike == true
    end
    return false
  end

  local function chooseRootPart(categoryName)
    local cache = runtime.categoryCache[categoryName]
    if not cache then
      return
    end

    local bestScore = -1
    local bestPartId = nil
    local bestDeviceName = nil
    for _, partId in ipairs(cache.partIds) do
      local info = runtime.activePartInfos[partId] or {}
      local score = 0
      if matchesKeywordSet(info, config.rootKeywordSets[categoryName]) then
        score = score + 10
      end
      if matchesKeywordSet(info, config.keywordSets[categoryName]) then
        score = score + 2
      end
      local links = cache.partLinks[partId]
      local categoryDeviceName = nil
      for _, link in ipairs(links or {}) do
        local device = powertrain.getDevice(link.deviceName)
        if linkBelongsToCategory(categoryName, link, device) then
          categoryDeviceName = categoryDeviceName or link.deviceName
          if categoryName == 'radiator' then
            score = score + 5
          elseif categoryName == 'engine' then
            score = score + 4
            -- Prefer the engine device's declaring part over subsystem modifiers.
            if link.subSystem == nil then
              score = score + 20
            end
          elseif categoryName == 'transmission' then
            -- Declared gearboxes outrank drivetrain-named slots so EV reduction boxes classify correctly.
            score = score + (device.deviceCategories.gearbox and 10 or 2)
          end
        end
      end
      if categoryDeviceName then
        score = score + 5
      end

      if score > bestScore then
        bestScore = score
        bestPartId = partId
        bestDeviceName = categoryDeviceName or (links and links[1] and links[1].deviceName) or nil
      end
    end

    cache.rootPartId = bestPartId or cache.partIds[1]
    cache.rootDeviceName = bestDeviceName
  end

  local function hasPowertrainDeviceType(deviceTypes)
    for _, device in pairs(powertrain.getDevices() or {}) do
      -- Substring match: mod engines use types such as "classic_combustionEngine".
      local deviceType = tostring(device.type or "")
      for _, wanted in ipairs(deviceTypes) do
        if deviceType:find(wanted, 1, true) then return true end
      end
    end
    return false
  end

  local function rebuildCategoryCache()
    runtime.hardwareByCategory = {}
    preparePartMetadata()
    ensureCategoryCache()
    for partId, partInfo in pairs(runtime.activePartInfos or {}) do
      classifyPart(partId, partInfo)
    end
    -- Engine and cooling hardware needs its required powertrain device to count as installed.
    for _, categoryName in ipairs(config.categoryOrder) do
      local required = config.partCategories.definitions[categoryName].requiredPowertrainDevices
      if required and not hasPowertrainDeviceType(required) then
        runtime.categoryCache[categoryName] = {partIds = {}, partIdSet = {}, partLinks = {}, rootPartId = nil, rootDeviceName = nil}
      end
    end
    for _, categoryName in ipairs(config.categoryOrder) do
      table.sort(runtime.categoryCache[categoryName].partIds)
      chooseRootPart(categoryName)
    end
  end

  local function buildDeviceEntry(device)
    local entry = {device = device, base = {}}
    entry.base.maxTorque = device.maxTorque or (device.torqueData and device.torqueData.maxTorque) or 0
    entry.base.maxPower = device.maxPower or (device.torqueData and device.torqueData.maxPower) or 0
    entry.base.maxAV = device.maxAV or 0
    -- onReset precedes powertrain.reset; recapturing bases would compound scaling.
    local scaledBase = device.rlsMaintenanceScaledBase
    if type(scaledBase) ~= "table" then
      scaledBase = {
        originalMaxTorqueLimit = device.maxTorqueLimit or math.huge,
        idleAVReadErrorRangeHalf = device.idleAVReadErrorRangeHalf or 0,
        idleAVReadErrorRange = device.idleAVReadErrorRange or 0,
        friction = device.friction,
        dynamicFriction = device.dynamicFriction,
        gearRatioChangeRate = device.gearRatioChangeRate,
        lockTorque = device.lockTorque,
        clutchFreePlay = device.clutchFreePlay
      }
      device.rlsMaintenanceScaledBase = scaledBase
    end
    entry.base.originalMaxTorqueLimit = scaledBase.originalMaxTorqueLimit
    entry.base.idleAVReadErrorRangeHalf = scaledBase.idleAVReadErrorRangeHalf
    entry.base.idleAVReadErrorRange = scaledBase.idleAVReadErrorRange
    entry.base.friction = scaledBase.friction
    entry.base.dynamicFriction = scaledBase.dynamicFriction
    entry.base.gearRatioChangeRate = scaledBase.gearRatioChangeRate
    entry.base.lockTorque = scaledBase.lockTorque
    entry.base.clutchFreePlay = scaledBase.clutchFreePlay
    entry.base.damageFrictionCoef = device.damageFrictionCoef
    entry.base.damageDynamicFrictionCoef = device.damageDynamicFrictionCoef
    entry.base.damageIdleAVReadErrorRangeCoef = device.damageIdleAVReadErrorRangeCoef
    entry.base.fastIgnitionErrorChance = device.fastIgnitionErrorChance
    entry.base.slowIgnitionErrorChance = device.slowIgnitionErrorChance
    entry.base.damageGearRatioChangeRateCoef = device.damageGearRatioChangeRateCoef
    entry.base.damageLockTorqueCoef = device.damageLockTorqueCoef
    entry.base.damageClutchFreePlayCoef = device.damageClutchFreePlayCoef
    entry.base.clutchPermanentlyDamaged = device.clutchPermanentlyDamaged
    entry.base.maxTorqueRating = tonumber(device.maxTorqueRating) or tonumber(device.torqueData and device.torqueData.maxTorqueRating) or 0
    entry.base.requiredEnergyType = device.requiredEnergyType or device.energyType
    entry.base.oilVolume = tonumber(device.oilVolume) or tonumber(device.thermals and device.thermals.oilVolume)

    local engineConfig = v and v.data and v.data[device.name] or {}
    entry.base.coolantMass = config.max(tonumber(engineConfig.coolantVolume) or 0, 1.5)
    return entry
  end

  local function rebuildDeviceContexts()
    runtime.deviceContexts = {
      engine = {devices = {}},
      radiator = {devices = {}},
      transmission = {gearboxes = {}, clutches = {}}
    }

    for _, device in ipairs(powertrain.getDevicesByCategory("engine") or {}) do
      if isCombustionEngine(device) then
        local entry = buildDeviceEntry(device)
        table.insert(runtime.deviceContexts.engine.devices, entry)
        table.insert(runtime.deviceContexts.radiator.devices, entry)
      end
    end

    for _, device in ipairs(powertrain.getDevicesByCategory("gearbox") or {}) do
      table.insert(runtime.deviceContexts.transmission.gearboxes, buildDeviceEntry(device))
    end

    for _, device in ipairs(powertrain.getDevicesByCategory("clutch") or {}) do
      table.insert(runtime.deviceContexts.transmission.clutches, buildDeviceEntry(device))
    end
  end

  -- jbeam node weights do not change while the vehicle exists.
  local massNodes, massTotal

  local function getVehicleMassKg()
    local nodes = v and v.data and v.data.nodes or nil
    if nodes ~= nil and nodes == massNodes then return massTotal end
    local total = 0
    for _, nodeData in pairs(nodes or {}) do
      total = total + config.max(tonumber(nodeData and nodeData.nodeWeight) or 0, 0)
    end
    massNodes, massTotal = nodes, total
    return total
  end

  local function getEngineBlockMassKg(engine)
    local total = 0
    local seen = {}
    for key, value in pairs(engine and engine.engineBlockNodes or {}) do
      local nodeId = type(value) == 'number' and value or (type(key) == 'number' and key or nil)
      if nodeId ~= nil and not seen[nodeId] then
        local nodeData = v and v.data and v.data.nodes and v.data.nodes[nodeId] or nil
        total = total + config.max(tonumber(nodeData and nodeData.nodeWeight) or 0, 0)
        seen[nodeId] = true
      end
    end
    return total
  end

  local function classifyLiveVehicle(modelFamily, curbWeightKg, engineMassKg)
    local model = string.lower(tostring(modelFamily or ''))
    if string.find(model, 'tseries', 1, true) or string.find(model, 'semi', 1, true) then
      return 'heavyTruck', 'modelFamily'
    end
    if string.find(model, 'mdseries', 1, true) or string.find(model, 'medium', 1, true) then
      return 'mediumTruck', 'modelFamily'
    end
    for _, token in ipairs({'pickup', 'dseries', 'roamer', 'hopper', 'van'}) do
      if string.find(model, token, 1, true) then
        return 'lightTruck', 'modelFamily'
      end
    end
    if curbWeightKg >= 8000 then
      return 'heavyTruck', 'curbWeight'
    elseif curbWeightKg >= 3500 then
      return 'mediumTruck', 'curbWeight'
    elseif curbWeightKg >= 2300 then
      return 'lightTruck', 'curbWeight'
    elseif curbWeightKg > 0 then
      return 'passenger', 'curbWeight'
    end
    if engineMassKg >= 650 then
      return 'heavyTruck', 'engineMass'
    elseif engineMassKg >= 350 then
      return 'mediumTruck', 'engineMass'
    elseif engineMassKg >= 220 then
      return 'lightTruck', 'engineMass'
    end
    return 'passenger', 'default'
  end

  local function buildLiveVehicleProfile(existing)
    existing = parts.state.normalizeProfile(existing)
    local engineEntry = runtime.deviceContexts and runtime.deviceContexts.engine and runtime.deviceContexts.engine.devices[1] or nil
    local engine = engineEntry and engineEntry.device or nil
    local vehicleDirectory = v and v.data and v.data.vehicleDirectory or nil
    local normalizedDirectory = vehicleDirectory and string.lower(tostring(vehicleDirectory)):gsub('\\', '/') or ''
    local modelFamily = normalizedDirectory:match('/vehicles/([^/]+)') or normalizedDirectory:match('vehicles/([^/]+)') or
                            (v and v.data and (v.data.model or v.data.name)) or existing.modelFamily
    local liveCurbWeightKg = getVehicleMassKg()
    local curbWeightKg = existing.curbWeightKg > 0 and existing.curbWeightKg or liveCurbWeightKg
    local engineMassKg = getEngineBlockMassKg(engine)
    local lockedClass = existing.classSource == 'maintenanceClass' or existing.classSource == 'bodyStyle'
    local className, classSource = classifyLiveVehicle(modelFamily, curbWeightKg, engineMassKg)
    if lockedClass then
      className = existing.class
      classSource = existing.classSource
    end

    local profile = parts.state.normalizeProfile({
      class = className,
      classSource = classSource,
      capacities = existing.class == className and existing.capacities or config.common.getClassDefaultCapacities(className),
      fuelType = engineEntry and engineEntry.base.requiredEnergyType or existing.fuelType,
      isDiesel = existing.isDiesel,
      curbWeightKg = curbWeightKg,
      engineMassKg = engineMassKg,
      powerHp = existing.powerHp,
      torqueNm = existing.torqueNm,
      modelFamily = modelFamily
    })
    local oilVolume = engineEntry and tonumber(engineEntry.base.oilVolume) or nil
    local coolantMass = engineEntry and tonumber(engineEntry.base.coolantMass) or nil
    if oilVolume and oilVolume >= 0.25 and oilVolume <= 100 then
      profile.capacities.oil = oilVolume
    end
    if coolantMass and coolantMass >= 0.25 and coolantMass <= 100 then
      profile.capacities.coolant = coolantMass
    end
    local rawPower = engineEntry and tonumber(engineEntry.base.maxPower) or 0
    profile.powerHp = rawPower > 10000 and rawPower / 745.7 or rawPower * 0.98632
    profile.torqueNm = engineEntry and config.max(tonumber(engineEntry.base.maxTorque) or 0, 0) or 0
    return profile
  end

  return {
    buildLiveVehicleProfile = buildLiveVehicleProfile,
    rebuildCategoryCache = rebuildCategoryCache,
    rebuildDeviceContexts = rebuildDeviceContexts,
  }

end

return M
