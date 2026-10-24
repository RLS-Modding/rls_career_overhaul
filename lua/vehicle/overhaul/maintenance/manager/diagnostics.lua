-- Owns maintenance telemetry, symptom projections, risk flags and preview/debug payloads.
-- Read symptom coefficients, live metrics, service/effect/risk rows, category previews, then debug publication.
local M = {}

local engineSymptomFractions = {
  roughRunning = {roughness = 1.1}, ticking = {roughness = 1.1},
  roughIdle = {roughness = 1.32, ignitionChance = 0.018},
  torqueDip = {torque = 0.94},
  powerFade = {power = 0.9, torque = 0.96, friction = 1.03},
  stall = {power = 0.7, torque = 0.65, roughness = 1.55, friction = 1.05, ignitionChance = 0.045}
}
local radiatorSymptomFractions = {
  coolantSeep = {torque = 0.95, friction = 1.015},
  fanOverwork = {torque = 0.97, friction = 1.01}
}
local transmissionSymptomFractions = {
  roughShift = {friction = 1.03, dynamicFriction = 1.04, clutchFreePlay = 1.08},
  shiftDelay = {shiftSpeed = 0.82},
  slip = {friction = 1.06, dynamicFriction = 1.08, shiftSpeed = 0.88, lockTorque = 0.9, clutchFreePlay = 1.22}
}
local powerCapCheckMinAVRadPerS = 220
local torqueCapToleranceNm = 0.001

function M.create(inputs)
  local runtime, config, helpers, parts = inputs.runtime, inputs.config, inputs.helpers, inputs.parts

  local function buildMatchedPartsDebug(cache, partConditions)
    local matchedParts = {}
    for _, partId in ipairs(cache.partIds or {}) do
      local condition = partConditions and partConditions[partId] or nil
      table.insert(matchedParts, {
        partId = partId,
        miles = (tonumber(condition and condition.odometer) or 0) * config.common.metersToMiles,
        odometer = tonumber(condition and condition.odometer) or 0,
        integrityValue = tonumber(condition and condition.integrityValue),
        isRoot = cache.rootPartId == partId
      })
    end

    table.sort(matchedParts, function(a, b)
      if a.isRoot ~= b.isRoot then
        return a.isRoot
      end
      if math.abs((a.miles or 0) - (b.miles or 0)) > 0.001 then
        return (a.miles or 0) > (b.miles or 0)
      end
      return tostring(a.partId or "") < tostring(b.partId or "")
    end)

    return matchedParts
  end

  local function getRuntimeSymptom(runtimeCategory)
    if runtimeCategory and runtimeCategory.activeSymptom and (runtimeCategory.symptomTimer or 0) > 0 then
      return runtimeCategory.activeSymptom
    end
  end

  local function getSymptomLabel(symptom)
    if type(symptom) ~= "string" or symptom == "" then
      return nil
    end
    return config.symptomLabels[symptom] or symptom
  end

  local function getEngineSymptomModifiers(symptom)
    local modifiers = {
      torqueCoef = 1,
      powerCoef = 1,
      frictionCoef = 1,
      roughnessCoef = 1,
      ignitionBonus = 0
    }

    if symptom == 'roughRunning' or symptom == 'ticking' then
      modifiers.roughnessCoef = engineSymptomFractions[symptom].roughness
    elseif symptom == 'roughIdle' then
      modifiers.roughnessCoef = engineSymptomFractions[symptom].roughness
      modifiers.ignitionBonus = engineSymptomFractions[symptom].ignitionChance
    elseif symptom == 'torqueDip' then
      modifiers.torqueCoef = engineSymptomFractions[symptom].torque
    elseif symptom == 'powerFade' then
      modifiers.powerCoef = engineSymptomFractions[symptom].power
      modifiers.torqueCoef = engineSymptomFractions[symptom].torque
      modifiers.frictionCoef = engineSymptomFractions[symptom].friction
    elseif symptom == 'stall' then
      modifiers.powerCoef = engineSymptomFractions[symptom].power
      modifiers.torqueCoef = engineSymptomFractions[symptom].torque
      modifiers.roughnessCoef = engineSymptomFractions[symptom].roughness
      modifiers.frictionCoef = engineSymptomFractions[symptom].friction
      modifiers.ignitionBonus = engineSymptomFractions[symptom].ignitionChance
    end

    return modifiers
  end

  local function getRadiatorSymptomModifiers(symptom)
    local modifiers = {
      torqueCoef = 1,
      frictionCoef = 1
    }

    if symptom == 'coolantSeep' then
      modifiers.torqueCoef = radiatorSymptomFractions[symptom].torque
      modifiers.frictionCoef = radiatorSymptomFractions[symptom].friction
    elseif symptom == 'fanOverwork' then
      modifiers.torqueCoef = radiatorSymptomFractions[symptom].torque
      modifiers.frictionCoef = radiatorSymptomFractions[symptom].friction
    end

    return modifiers
  end

  local function getTransmissionSymptomModifiers(symptom)
    local modifiers = {
      frictionCoef = 1,
      dynamicFrictionCoef = 1,
      shiftSpeedCoef = 1,
      lockTorqueCoef = 1,
      clutchFreePlayCoef = 1
    }

    if symptom == 'roughShift' then
      modifiers.frictionCoef = transmissionSymptomFractions[symptom].friction
      modifiers.dynamicFrictionCoef = transmissionSymptomFractions[symptom].dynamicFriction
      modifiers.clutchFreePlayCoef = transmissionSymptomFractions[symptom].clutchFreePlay
    elseif symptom == 'shiftDelay' then
      modifiers.shiftSpeedCoef = transmissionSymptomFractions[symptom].shiftSpeed
    elseif symptom == 'slip' then
      modifiers.frictionCoef = transmissionSymptomFractions[symptom].friction
      modifiers.dynamicFrictionCoef = transmissionSymptomFractions[symptom].dynamicFriction
      modifiers.shiftSpeedCoef = transmissionSymptomFractions[symptom].shiftSpeed
      modifiers.lockTorqueCoef = transmissionSymptomFractions[symptom].lockTorque
      modifiers.clutchFreePlayCoef = transmissionSymptomFractions[symptom].clutchFreePlay
    end

    return modifiers
  end

  local function buildMetricRow(key, label, value, valueType, severity, detail)
    return {
      key = key,
      label = label,
      value = value,
      valueType = valueType,
      severity = severity,
      detail = detail
    }
  end

  local function buildRiskFlag(key, label, severity, detail)
    return {
      key = key,
      label = label,
      severity = severity,
      detail = detail
    }
  end

  local function getMinDueMiles(serviceDueMilesRemaining)
    local best = math.huge
    for _, dueMiles in pairs(serviceDueMilesRemaining or {}) do
      if tonumber(dueMiles) and dueMiles < best then
        best = dueMiles
      end
    end

    if best == math.huge then
      return nil
    end
    return best
  end

  local function captureTransmissionMetrics()
    local gearboxEntry = runtime.deviceContexts.transmission.gearboxes[1]
    local clutchEntry = runtime.deviceContexts.transmission.clutches[1]
    local metrics = {}

    if gearboxEntry and gearboxEntry.device then
      local gearbox = gearboxEntry.device
      local base = gearboxEntry.base or {}
      metrics.frictionCoef = base.friction and base.friction ~= 0 and (tonumber(gearbox.friction) or base.friction) / base.friction or nil
      metrics.dynamicFrictionCoef = base.dynamicFriction and base.dynamicFriction ~= 0 and
          (tonumber(gearbox.dynamicFriction) or base.dynamicFriction) / base.dynamicFriction or nil
      metrics.shiftSpeedCoef = base.gearRatioChangeRate and base.gearRatioChangeRate ~= 0 and
          (tonumber(gearbox.gearRatioChangeRate) or base.gearRatioChangeRate) / base.gearRatioChangeRate or nil
      metrics.gearboxLockTorqueCoef = base.lockTorque and base.lockTorque ~= 0 and
          (tonumber(gearbox.lockTorque) or base.lockTorque) / base.lockTorque or nil
    end

    if clutchEntry and clutchEntry.device then
      local clutch = clutchEntry.device
      local base = clutchEntry.base or {}
      metrics.clutchLockTorqueCoef = base.lockTorque and base.lockTorque ~= 0 and
          (tonumber(clutch.lockTorque) or base.lockTorque) / base.lockTorque or nil
      metrics.clutchFreePlayCoef = base.clutchFreePlay and base.clutchFreePlay ~= 0 and
          (tonumber(clutch.clutchFreePlay) or base.clutchFreePlay) / base.clutchFreePlay or nil
    end
    return metrics
  end

  local function captureEngineMetrics(runtimeCategory, derived)
    local entry = runtime.deviceContexts.engine.devices[1]
    if not entry or not entry.device then
      return {}
    end

    local engine = entry.device
    local base = entry.base or {}
    local baseMaxTorque = config.max(tonumber(base.maxTorque) or tonumber(engine.maxTorque) or 0, 0)
    local baseMaxPowerRaw = config.max(tonumber(base.maxPower) or tonumber(engine.maxPower) or 0, 0)
    local baseMaxPowerWatts = config.common.getBeamPowerWatts(baseMaxPowerRaw)
    local currentAV = config.max(config.abs(parts.environment.getNumericValue(engine.outputAV1 or engine.inputAV or engine.outputAV2)), 0)
    local redlineAV = config.max(tonumber(base.maxAV) or tonumber(engine.maxAV) or 0, 1)
    local rpmCapacity = currentAV / redlineAV
    local torqueLimit = tonumber(engine.maxTorqueLimit) or base.originalMaxTorqueLimit or math.huge
    local symptom = getRuntimeSymptom(runtimeCategory)
    local liveTorqueHoldCoef = config.engineCategory.getLiveTorqueHoldCoef(
      tonumber(derived and derived.torqueHoldCoef) or 1,
      tonumber(derived and derived.loadFactor) or 0,
      rpmCapacity
    )
    local expectedTorqueCap = baseMaxTorque * liveTorqueHoldCoef * getEngineSymptomModifiers(symptom).torqueCoef
    local powerCapActive = runtimeCategory and runtimeCategory.lastPowerLimitActive
    if powerCapActive == nil then
      powerCapActive = baseMaxPowerWatts > 0 and currentAV > powerCapCheckMinAVRadPerS and torqueLimit < (expectedTorqueCap - torqueCapToleranceNm)
    end

    return {
      currentAV = currentAV,
      rpmCapacity = rpmCapacity,
      loadFactor = tonumber(derived and derived.loadFactor) or 0,
      baseMaxPowerRaw = baseMaxPowerRaw,
      baseMaxPowerWatts = baseMaxPowerWatts,
      liveTorqueHoldCoef = liveTorqueHoldCoef,
      torqueLimitCoef = baseMaxTorque > 0 and torqueLimit / baseMaxTorque or nil,
      frictionCoef = base.friction and base.friction ~= 0 and (tonumber(engine.friction) or base.friction) / base.friction or nil,
      dynamicFrictionCoef = base.dynamicFriction and base.dynamicFriction ~= 0 and
          (tonumber(engine.dynamicFriction) or base.dynamicFriction) / base.dynamicFriction or nil,
      roughnessCoef = base.idleAVReadErrorRange and base.idleAVReadErrorRange ~= 0 and
          (tonumber(engine.idleAVReadErrorRange) or base.idleAVReadErrorRange) / base.idleAVReadErrorRange or nil,
      ignitionErrorChance = tonumber(engine.fastIgnitionErrorChance) or tonumber(derived and derived.ignitionErrorChance) or 0,
      powerCapActive = powerCapActive,
      powerLimitReason = runtimeCategory and runtimeCategory.lastPowerLimitReason or nil
    }
  end

  local function captureCoolingMetrics(runtimeCategory)
    local entry = runtime.deviceContexts.radiator.devices[1]
    if not entry or not entry.device then
      return {}
    end

    local engine = entry.device
    local base = entry.base or {}
    local baseMaxTorque = config.max(tonumber(base.maxTorque) or tonumber(engine.maxTorque) or 0, 0)
    local torqueLimit = tonumber(engine.maxTorqueLimit) or base.originalMaxTorqueLimit or math.huge
    return {
      torqueLimitCoef = baseMaxTorque > 0 and torqueLimit / baseMaxTorque or nil,
      powerLimitActive = runtimeCategory and runtimeCategory.lastPowerLimitActive == true or false,
      powerLimitReason = runtimeCategory and runtimeCategory.lastPowerLimitReason or nil,
      frictionCoef = base.friction and base.friction ~= 0 and (tonumber(engine.friction) or base.friction) / base.friction or nil,
      dynamicFrictionCoef = base.dynamicFriction and base.dynamicFriction ~= 0 and
          (tonumber(engine.dynamicFriction) or base.dynamicFriction) / base.dynamicFriction or nil
    }
  end

  local function captureLiveMetrics(categoryName, runtimeCategory, derived)
    if categoryName == 'engine' then
      return captureEngineMetrics(runtimeCategory, derived)
    elseif categoryName == 'radiator' then
      return captureCoolingMetrics(runtimeCategory)
    elseif categoryName == 'transmission' then
      local metrics = captureTransmissionMetrics()

      return metrics
    end

    return {}
  end

  local function buildMaintenanceItems(categoryState, derived)
    local items = {}
    for itemName, itemValue in pairs(categoryState.maintenance or {}) do
      table.insert(items, {
        name = itemName,
        label = config.maintenanceLabels[itemName] or itemName,
        value = helpers.roundValue(itemValue, 4),
        targetValue = helpers.roundValue(derived.serviceTargets and derived.serviceTargets[itemName] or 0, 4),
        dueMiles = helpers.roundValue(derived.serviceDueMilesRemaining and derived.serviceDueMilesRemaining[itemName] or 0, 1),
        effectiveIntervalMiles = helpers.roundValue(derived.effectiveIntervals and derived.effectiveIntervals[itemName] or 0, 1)
      })
    end

    table.sort(items, function(a, b)
      return tostring(a.label) < tostring(b.label)
    end)

    return items
  end

  local function appendEngineDiagnosticEffects(derived, liveMetrics, isPreview, symptom, effects)
    local modifiers = getEngineSymptomModifiers(symptom)
    local previewRpmCapacity = derived.rpmCapacity or derived.rpmFactor or 0
    local liveTorqueHoldCoef = liveMetrics.liveTorqueHoldCoef or
                                   config.engineCategory.getLiveTorqueHoldCoef(derived.torqueHoldCoef or 1, derived.loadFactor or 0, previewRpmCapacity)
    local torqueLimitCoef = liveMetrics.torqueLimitCoef or (liveTorqueHoldCoef * modifiers.torqueCoef)
    local roughnessCoef = liveMetrics.roughnessCoef or ((derived.roughnessCoef or 1) * modifiers.roughnessCoef)
    local ignitionErrorChance = liveMetrics.ignitionErrorChance or config.common.clamp((derived.ignitionErrorChance or 0) + modifiers.ignitionBonus, 0, 0.12)
    local frictionCoef = liveMetrics.frictionCoef or ((derived.frictionCoef or 1) * modifiers.frictionCoef)
    local symptomLabel = getSymptomLabel(symptom)

    table.insert(effects, buildMetricRow("symptom", "Current symptom", symptomLabel or (isPreview and "none (preview)" or "stable"), "text",
      symptom and "high" or "ok"))
    table.insert(effects, buildMetricRow("torqueLimitCoef", "Torque limit hold", helpers.roundValue(torqueLimitCoef or 1, 4), "ratio",
      (torqueLimitCoef or 1) < 0.8 and "high" or ((torqueLimitCoef or 1) < 0.92 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("liveTorqueHoldCoef", "Live torque hold", helpers.roundValue(liveTorqueHoldCoef or 1, 4), "ratio",
      (liveTorqueHoldCoef or 1) < 0.8 and "high" or ((liveTorqueHoldCoef or 1) < 0.92 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("powerCapActive", "Power limit active", liveMetrics.powerCapActive == true, "boolean",
      liveMetrics.powerCapActive and "medium" or "ok"))
    table.insert(effects, buildMetricRow("powerLimitReason", "Power limit reason", liveMetrics.powerLimitReason or "none", "text",
      liveMetrics.powerLimitReason and "medium" or "ok"))
    table.insert(effects, buildMetricRow("baseMaxPowerRaw", "Beam max power raw", helpers.roundValue(liveMetrics.baseMaxPowerRaw or 0, 1), "number", "ok"))
    table.insert(effects, buildMetricRow("baseMaxPowerWatts", "Beam max power watts", helpers.roundValue(liveMetrics.baseMaxPowerWatts or 0, 1), "number", "ok"))
    table.insert(effects, buildMetricRow("rpmCapacity", "RPM percent", helpers.roundValue(liveMetrics.rpmCapacity or previewRpmCapacity or 0, 4), "ratio",
      (liveMetrics.rpmCapacity or previewRpmCapacity or 0) > 0.92 and "medium" or "ok"))
    table.insert(effects, buildMetricRow("loadFactor", "Load percent", helpers.roundValue(liveMetrics.loadFactor or derived.loadFactor or 0, 4), "ratio",
      (liveMetrics.loadFactor or derived.loadFactor or 0) > 0.85 and "medium" or "ok"))
    table.insert(effects, buildMetricRow("roughnessCoef", "Roughness", helpers.roundValue(roughnessCoef or 1, 4), "ratio",
      (roughnessCoef or 1) > 1.25 and "medium" or "ok"))
    table.insert(effects, buildMetricRow("ignitionErrorChance", "Ignition error chance", helpers.roundValue(ignitionErrorChance, 5), "chance",
      ignitionErrorChance > 0.02 and "high" or (ignitionErrorChance > 0.01 and "medium" or "ok")))
    table.insert(effects, buildMetricRow("frictionCoef", "Friction", helpers.roundValue(frictionCoef or 1, 4), "ratio",
      (frictionCoef or 1) > 1.04 and "medium" or "ok"))
  end

  local function buildCurrentEffects(categoryName, categoryState, runtimeCategory, derived, liveMetrics, isPreview)
    local symptom = getRuntimeSymptom(runtimeCategory)
    local effects = {}

    if categoryName == 'engine' then
      appendEngineDiagnosticEffects(derived, liveMetrics, isPreview, symptom, effects)
    elseif categoryName == 'radiator' then
      local modifiers = getRadiatorSymptomModifiers(symptom)
      local symptomLabel = getSymptomLabel(symptom)

      table.insert(effects, buildMetricRow("symptom", "Current symptom", symptomLabel or (isPreview and "none (preview)" or "stable"), "text",
        symptom and "medium" or "ok"))
      table.insert(effects, buildMetricRow("coolantMassCoef", "Coolant mass", helpers.roundValue(derived.coolantMassCoef or 1, 4), "ratio",
        (derived.coolantMassCoef or 1) < 0.88 and "high" or ((derived.coolantMassCoef or 1) < 0.95 and "medium" or "ok")))
      table.insert(effects, buildMetricRow("coolingPowerLimitActive", "Power limit active", liveMetrics.powerLimitActive == true, "boolean",
        liveMetrics.powerLimitActive and "high" or "ok"))
      table.insert(effects, buildMetricRow("coolingPowerLimitReason", "Power limit reason", liveMetrics.powerLimitReason or "none", "text",
        liveMetrics.powerLimitReason and "high" or "ok"))
      table.insert(effects, buildMetricRow("isOverheating", "Overheating", derived.isOverheating == true, "boolean",
        derived.isOverheating and "high" or "ok"))
      table.insert(effects, buildMetricRow("frictionCoef", "Cooling friction bump", helpers.roundValue(modifiers.frictionCoef, 4), "ratio",
        modifiers.frictionCoef > 1 and "medium" or "ok"))
    elseif categoryName == 'transmission' then
      local symptomModifiers = getTransmissionSymptomModifiers(symptom)
      local lockTorqueCoef = liveMetrics.clutchLockTorqueCoef or liveMetrics.gearboxLockTorqueCoef or
          config.common.clamp((derived.lockTorqueCoef or 1) * symptomModifiers.lockTorqueCoef, 0, 1)
      local symptomLabel = getSymptomLabel(symptom)

      table.insert(effects, buildMetricRow("symptom", "Current symptom", symptomLabel or (isPreview and "none (preview)" or "stable"), "text",
        symptom and "medium" or "ok"))
      table.insert(effects, buildMetricRow("transmissionHeatFactor", "Transmission heat", helpers.roundValue(derived.transmissionHeatFactor or 0, 4), "ratio",
        (derived.transmissionHeatFactor or 0) >= 1 and "high" or ((derived.transmissionHeatFactor or 0) >= 0.65 and "medium" or "ok"),
        string.format("%.1f C simulated", tonumber(derived.transmissionTempC) or 0)))
      table.insert(effects, buildMetricRow("slipSeverity", "Slip pressure", helpers.roundValue(derived.slipSeverity or 0, 4), "ratio",
        (derived.slipSeverity or 0) >= 1 and "high" or ((derived.slipSeverity or 0) >= 0.65 and "medium" or "ok")))
      table.insert(effects, buildMetricRow("shiftSpeedCoef", "Shift speed", helpers.roundValue(liveMetrics.shiftSpeedCoef or
        config.common.clamp((derived.shiftSpeedCoef or 1) * symptomModifiers.shiftSpeedCoef, 0.25, 1), 4), "ratio",
        (liveMetrics.shiftSpeedCoef or derived.shiftSpeedCoef or 1) < 0.78 and "high" or
            ((liveMetrics.shiftSpeedCoef or derived.shiftSpeedCoef or 1) < 0.88 and "medium" or "ok")))
      table.insert(effects, buildMetricRow("lockTorqueCoef", "Lock torque", helpers.roundValue(lockTorqueCoef, 4), "ratio",
        lockTorqueCoef < 0.86 and "high" or (lockTorqueCoef < 0.94 and "medium" or "ok")))
      table.insert(effects, buildMetricRow("clutchFreePlayCoef", "Clutch free play", helpers.roundValue(liveMetrics.clutchFreePlayCoef or
        config.common.clamp((derived.clutchFreePlayCoef or 1) * symptomModifiers.clutchFreePlayCoef, 1, 5.0), 4), "ratio",
        (liveMetrics.clutchFreePlayCoef or derived.clutchFreePlayCoef or 1) > 1.7 and "high" or
            ((liveMetrics.clutchFreePlayCoef or derived.clutchFreePlayCoef or 1) > 1.3 and "medium" or "ok")))
      table.insert(effects, buildMetricRow("frictionCoef", "Drivetrain friction", helpers.roundValue(liveMetrics.frictionCoef or
        ((derived.frictionCoef or 1) * symptomModifiers.frictionCoef), 4), "ratio",
        (liveMetrics.frictionCoef or derived.frictionCoef or 1) > 1.06 and "medium" or "ok"))
    end

    return effects
  end

  local function appendCriticalEngineRiskFlags(categoryState, derived, flags)
    if (derived.limitStressFactor or 0) >= 0.9 then
      table.insert(flags, buildRiskFlag("limit_stress", "Transmission is operating near its limits", "medium",
        string.format("Limit stress %.2f", tonumber(derived.limitStressFactor) or 0)))
    end
    if (derived.transmissionOverheatFactor or 0) >= 0.45 then
      table.insert(flags, buildRiskFlag("transmission_overheat", "Transmission heat is in breakage territory", "high",
        string.format("%.1f C simulated", tonumber(derived.transmissionTempC) or 0)))
    elseif (derived.transmissionHeatFactor or 0) >= 0.7 then
      table.insert(flags, buildRiskFlag("transmission_heat", "Transmission heat is accelerating wear", "medium",
        string.format("%.1f C simulated", tonumber(derived.transmissionTempC) or 0)))
    end
    if derived.criticalFluidCondition then
      table.insert(flags, buildRiskFlag("fluid_quality_critical", "Transmission fluid quality is causing harsh shifting", "high",
        string.format("%.0f%% quality remaining", (tonumber(categoryState.maintenance and categoryState.maintenance.fluidCondition) or 0) * 100)))
    elseif (derived.fluidConditionSeverity or 0) >= 0.8 then
      table.insert(flags, buildRiskFlag("fluid_quality_low", "Transmission fluid quality is degrading shift behavior", "medium",
        string.format("%.0f%% quality remaining", (tonumber(categoryState.maintenance and categoryState.maintenance.fluidCondition) or 0) * 100)))
    end
    if (derived.loadFactor or 0) >= 0.8 and (derived.maintenancePenalty or 0) >= 0.2 then
      table.insert(flags, buildRiskFlag("slip_risk", "Load and maintenance neglect are raising slip risk", "high",
        string.format("Load %.0f%%", (tonumber(derived.loadFactor) or 0) * 100)))
    end
    if derived.criticalFluidLoss then
      table.insert(flags, buildRiskFlag("fluid_loss", "Transmission fluid reserve is critically low", "high",
        string.format("%.0f%% fluid remaining", (tonumber(categoryState.maintenance and categoryState.maintenance.fluidLevel) or 0) * 100)))
    elseif (derived.fluidLevelSeverity or 0) >= 0.8 then
      table.insert(flags, buildRiskFlag("fluid_low", "Low transmission fluid is cutting clutch hold margin", "high",
        string.format("%.0f%% fluid remaining", (tonumber(categoryState.maintenance and categoryState.maintenance.fluidLevel) or 0) * 100)))
    end
    if (derived.hardFailureRate or 0) >= 0.01 then
      table.insert(flags, buildRiskFlag("failure_window", "Transmission hard-failure chance is now active", "high",
        string.format("%.3f / sec", tonumber(derived.hardFailureRate) or 0)))
    elseif (derived.hardFailureRate or 0) > 0 then
      table.insert(flags, buildRiskFlag("failure_window", "Transmission hard-failure chance is non-zero", "medium",
        string.format("%.3f / sec", tonumber(derived.hardFailureRate) or 0)))
    end
  end

  local function collectEngineRiskFlags(categoryState, derived)
    local flags = {}

    for itemName, targetValue in pairs(derived.serviceTargets or {}) do
      local currentValue = tonumber(categoryState.maintenance and categoryState.maintenance[itemName]) or 1
      if currentValue <= targetValue then
        table.insert(flags, buildRiskFlag(itemName .. "_due", (config.maintenanceLabels[itemName] or itemName) .. " is past service target",
          currentValue < (targetValue - 0.12) and "high" or "medium",
          string.format("%.0f%% value vs %.0f%% target", currentValue * 100, targetValue * 100)))
      end
    end

    local stressMultiplier = tonumber(derived.stressMultiplier) or tonumber(derived.driveMultiplier) or 1
    if stressMultiplier >= 1.45 then
      table.insert(flags, buildRiskFlag("wear_spike", "Current driving is accelerating wear",
        stressMultiplier >= 2.2 and "high" or "medium",
        string.format("Driving stress %.2fx normal", stressMultiplier)))
    end

    local ageMultiplier = tonumber(derived.ageMultiplier) or 1
    if ageMultiplier >= 1.5 then
      table.insert(flags, buildRiskFlag("age_fluid_loss", "Component age is accelerating fluid loss",
        ageMultiplier >= 4 and "high" or "medium",
        string.format("Fluid loss %.2fx at %.0f age-equivalent mi on these parts", ageMultiplier,
          tonumber(derived.wear and derived.wear.avgMiles) or 0)))
    end

    local neglectMultiplier = tonumber(derived.neglectMultiplier) or 1
    if neglectMultiplier >= 1.5 then
      table.insert(flags, buildRiskFlag("fluid_neglect", "Low fluid is accelerating its own loss",
        neglectMultiplier >= 3 and "high" or "medium",
        string.format("Degradation %.2fx from current fluid level", neglectMultiplier)))
    end
    return flags
  end

  local function buildRiskFlags(categoryName, categoryState, derived)
    local flags = collectEngineRiskFlags(categoryState, derived)

    if categoryName == 'engine' then
      if (derived.integrityValue or 1) <= 0.45 then
        table.insert(flags, buildRiskFlag("engine_integrity", "Engine integrity is critically low", "high",
          string.format("%.0f%% integrity remaining", (tonumber(derived.integrityValue) or 0) * 100)))
      elseif (derived.integrityValue or 1) <= 0.7 then
        table.insert(flags, buildRiskFlag("engine_integrity", "Engine integrity is lowering failure margin", "medium",
          string.format("%.0f%% integrity remaining", (tonumber(derived.integrityValue) or 0) * 100)))
      end
      if derived.catastrophicOilStarvation then
        table.insert(flags, buildRiskFlag("oil_starvation_catastrophic", "Catastrophic oil starvation", "high",
          "Oil level and oil quality are effectively gone; hard engine failure is imminent."))
      elseif derived.severeOilStarvation then
        table.insert(flags, buildRiskFlag("oil_starvation", "Severe oil starvation", "high",
          "The engine is running with critically low oil reserve and will not survive continued load."))
      end
      -- Peak torque above the rating is a build advisory; unrated engines keep the absolute threshold.
      local _, ratedRatio = config.common.getRatedOutputFactor(derived.torqueNm, derived.maxTorqueRating)
      if (ratedRatio and ratedRatio >= 1) or (not ratedRatio and (derived.outputStressFactor or 0) >= 1) then
        table.insert(flags, buildRiskFlag("high_output", "Engine is tuned beyond its torque rating", "medium",
          "Heavy load adds oil and ignition wear."))
      end
      if derived.pistonRingsDamaged == true then
        table.insert(flags, buildRiskFlag("piston_rings", "Damaged piston rings are consuming oil", "high",
          string.format("%.6f per sec", tonumber(derived.pistonRingOilConsumptionRate) or 0)))
      end
    elseif categoryName == 'radiator' then
      if derived.catastrophicCoolingLoss then
        table.insert(flags, buildRiskFlag("cooling_catastrophic", "Catastrophic coolant loss", "high",
          "Coolant reserve and integrity are both effectively gone; engine overheating failure is imminent."))
      elseif derived.severeCoolingLoss then
        table.insert(flags, buildRiskFlag("cooling_severe", "Severe cooling loss", "high",
          "Cooling reserve is critically low and heat will escalate rapidly under load."))
      end
      if derived.isOverheating == true then
        table.insert(flags, buildRiskFlag("overheating", "Cooling system is actively overheating", "high",
          string.format("%.1f C coolant", tonumber(derived.coolantTemp) or 0)))
      elseif (derived.criticalCoolantTempFactor or 0) > 0 then
        table.insert(flags, buildRiskFlag("critical_heat", "Coolant temperature is in rapid-loss territory", "medium",
          string.format("%.1f C coolant", tonumber(derived.coolantTemp) or 0)))
      end
    elseif categoryName == 'transmission' then
      appendCriticalEngineRiskFlags(categoryState, derived, flags)
    end

    return flags
  end

  local function appendBrokenComponentFlags(flags, categoryName, cache, partConditions)
    if categoryName ~= 'engine' then return flags end

    local failureIndex = 0
    for _, partId in ipairs(cache.partIds or {}) do
      if partId ~= cache.rootPartId then
        local condition = partConditions and partConditions[partId] or nil
        local integrityValue = tonumber(condition and condition.integrityValue)
        if integrityValue ~= nil and integrityValue <= 0 then
          failureIndex = failureIndex + 1
          local info = runtime.activePartInfos[partId] or {}
          table.insert(flags, {
            key = "engine_component_failure_" .. tostring(failureIndex),
            label = "Engine-related component requires replacement",
            scannerLabel = tostring(info.displayName or info.partName or "Engine-related component") .. " requires replacement",
            scannerDetail = string.format("The installed component reports %.0f%% mechanical integrity.", integrityValue * 100),
            severity = "high",
            detail = string.format("%s has %.0f%% integrity remaining", tostring(info.partName or partId), integrityValue * 100),
            partId = partId,
            componentName = info.displayName or info.partName
          })
        end
      end
    end

    return flags
  end

  local function buildCurvePreview(categoryName, categoryState, derived)
    local datasets = {}
    local xMaxMiles = 0
    local palette = {"#f08b49", "#57b8d8", "#d7c45c", "#91e075"}
    local orderedItems = buildMaintenanceItems(categoryState, derived)

    for index, item in ipairs(orderedItems) do
      local effectiveIntervalMiles = config.max(tonumber(item.effectiveIntervalMiles) or 0, 0.1)
      local targetValue = config.common.clamp(tonumber(item.targetValue) or 0.5, 0, 1)
      local dueMiles = config.max(tonumber(item.dueMiles) or 0, 0)
      local maxMiles = config.max(dueMiles * 1.35, effectiveIntervalMiles * 0.85, 40)
      local stepMiles = config.max(maxMiles / 24, 1)
      local currentValue = config.common.clamp(tonumber(item.value) or 1, 0, 1)
      local simulatedValue = currentValue
      local points = {
        {0, helpers.roundValue(simulatedValue * 100, 2)}
      }

      for stepIndex = 1, 24 do
        simulatedValue = config.common.applyIntervalWear(simulatedValue, effectiveIntervalMiles, stepMiles, 1, targetValue)
        table.insert(points, {helpers.roundValue(stepIndex * stepMiles, 1), helpers.roundValue(simulatedValue * 100, 2)})
      end

      xMaxMiles = config.max(xMaxMiles, maxMiles)
      table.insert(datasets, {
        key = item.name,
        label = item.label,
        color = palette[((index - 1) % #palette) + 1],
        currentValue = currentValue,
        targetValue = targetValue,
        dueMiles = dueMiles,
        effectiveIntervalMiles = effectiveIntervalMiles,
        points = points
      })
    end

    return {
      xMaxMiles = helpers.roundValue(xMaxMiles, 1),
      datasets = datasets
    }
  end

  local function buildCategoryPreview(categoryName, scenarioInputs)
    local preview = helpers.preview()
    local previewState = preview.buildPreviewCategoryState(categoryName, scenarioInputs)
    local previewEnv = preview.buildScenarioEnvironment(categoryName, scenarioInputs)
    local previewDerived = config.categoryModules[categoryName].buildDerived(previewState, previewEnv)
    previewDerived.rpmCapacity = previewEnv.rpmCapacity or previewEnv.rpmFactor
    previewDerived.rpmFactor = previewEnv.rpmFactor
    previewDerived.loadFactor = previewEnv.loadFactor
    previewDerived.heatFactor = previewEnv.heatFactor
    previewDerived.torqueNm = previewEnv.torqueNm
    previewDerived.torqueFactor = previewEnv.torqueFactor
    previewDerived.powerHp = previewEnv.powerHp
    previewDerived.powerFactor = previewEnv.powerFactor
    previewDerived.outputStressFactor = previewEnv.outputStressFactor
    previewDerived.coolantTemp = previewEnv.coolantTemp
    previewDerived.isOverheating = previewEnv.isOverheating
    previewDerived.overheatFactor = previewEnv.overheatFactor

    return {
      avgMiles = helpers.roundValue(scenarioInputs.avgMiles or 0, 1),
      maintenanceAverage = helpers.roundValue(previewDerived.maintenanceAvg or 1, 4),
      driveMultiplier = helpers.roundValue(previewDerived.driveMultiplier or 1, 4),
      serviceDueMiles = helpers.roundValue(getMinDueMiles(previewDerived.serviceDueMilesRemaining) or 0, 1),
      maintenanceItems = buildMaintenanceItems(previewState, previewDerived),
      currentEffects = buildCurrentEffects(categoryName, previewState, {}, previewDerived, {}, true),
      riskFlags = buildRiskFlags(categoryName, previewState, previewDerived),
      curvePreview = buildCurvePreview(categoryName, previewState, previewDerived)
    }
  end

  local function buildOverviewSummary(categories)
    local overview = {
      activeIssues = {},
      categorySummary = {},
      highestSeverity = "ok"
    }
    local severityRank = {ok = 0, medium = 1, high = 2}

    for _, categoryName in ipairs(config.categoryOrder) do
      local categoryData = categories[categoryName]
      if categoryData then
        local severityScore = (1 - (tonumber(categoryData.maintenanceAverage) or 1)) * 65
        if categoryData.activeSymptom then
          severityScore = severityScore + 20
          table.insert(overview.activeIssues, string.format("%s: %s", config.categoryLabels[categoryName] or categoryName, categoryData.activeSymptomLabel or categoryData.activeSymptom))
        end

        for _, risk in ipairs(categoryData.riskFlags or {}) do
          severityScore = severityScore + (risk.severity == "high" and 15 or 8)
          if severityRank[risk.severity] > severityRank[overview.highestSeverity] then
            overview.highestSeverity = risk.severity
          end
        end

        local dueMiles = getMinDueMiles(categoryData.serviceDueMilesRemaining)
        overview.categorySummary[categoryName] = {
          label = config.categoryLabels[categoryName] or categoryName,
          severityScore = helpers.roundValue(config.common.clamp(severityScore, 0, 100), 1),
          activeSymptom = categoryData.activeSymptomLabel or categoryData.activeSymptom,
          dueMiles = dueMiles and helpers.roundValue(dueMiles, 1) or nil,
          maintenanceAverage = helpers.roundValue(categoryData.maintenanceAverage or 1, 4),
          riskCount = #(categoryData.riskFlags or {})
        }
      end
    end

    return overview
  end

  local function engineRestrictionIsDiagnostic(metrics, activeSymptom)
    metrics = metrics or {}
    if metrics.powerCapActive ~= true then return false end
    local reason = metrics.powerLimitReason
    if activeSymptom ~= nil or reason == 'Temporary symptom' or reason == 'Oil starvation' or
        reason == 'Severe ignition issue' then return true end

    -- Ignore routine torque modulation unless a named fault or symptom is active.
    local availability = tonumber(metrics.torqueLimitCoef)
    return availability ~= nil and availability < 0.90
  end

  local function getTransmissionThermalStress(derived)
    derived = derived or {}
    local heat = tonumber(derived.transmissionHeatFactor)
    local overheat = tonumber(derived.transmissionOverheatFactor)
    if overheat and overheat >= 0.45 then return 'high' end
    -- Match the overheat curve's starting point in transmission.lua.
    if (overheat and overheat > 0) or (heat and heat >= 0.88) then return 'elevated' end
    return 'normal'
  end

  local function writeCategoryMaintenanceDiagnostics(
    result, categoryName, categoryState, cache, partConditions, derived
  )
    result.label = config.categoryLabels[categoryName] or categoryName
    result.color = config.categoryColors[categoryName] or "#ffffff"
    result.avgMiles = (categoryState.avgOdometer or 0) * config.common.metersToMiles
    result.ageMiles = config.partCategories.getClassAgeMiles((categoryState.avgOdometer or 0) * config.common.metersToMiles,
      runtime.state and runtime.state.profile)
    result.wearBand = categoryState.wearBand
    result.maintenance = config.common.deepCopy(categoryState.maintenance)
    result.maintenanceItems = buildMaintenanceItems(categoryState, derived)
    result.lastFailureTime = categoryState.lastFailureTime or 0
    result.lastFailureType = categoryState.lastFailureType
    result.rootPartId = cache.rootPartId
    result.hardwareInstalled = categoryState.hardwareInstalled ~= false
    result.matchedPartCount = #(cache.partIds or {})
    result.matchedPartIds = config.common.deepCopy(cache.partIds or {})
    result.matchedParts = buildMatchedPartsDebug(cache, partConditions)
  end

  local function writeCategoryRuntimeDiagnostics(
    result, runtimeCategory, derived, activeSymptom, outputRestrictionDiagnostic
  )
    result.activeSymptom = activeSymptom
    result.activeSymptomLabel = getSymptomLabel(activeSymptom)
    result.outputRestrictionDiagnostic = outputRestrictionDiagnostic
    result.symptomCooldown = runtimeCategory.cooldownTimer or 0
    result.symptomTimer = runtimeCategory.symptomTimer or 0
    result.symptomRate = derived.symptomRate or 0
    result.hardFailureRate = derived.hardFailureRate or 0
    result.maintenanceAverage = derived.maintenanceAvg or 1
    result.neglectSeverity = derived.neglectSeverity or 0
    result.integrityValue = derived.integrityValue or 1
    result.integritySeverity = derived.integritySeverity or 0
    result.driveMultiplier = derived.driveMultiplier or 1
    result.stressMultiplier = derived.stressMultiplier or 1
    result.ageMultiplier = derived.ageMultiplier or 1
    result.neglectMultiplier = derived.neglectMultiplier or 1
    result.driveMultipliers = config.common.deepCopy(derived.driveMultipliers or {})
    result.rawDriveMultipliers = config.common.deepCopy(derived.rawDriveMultipliers or {})
    result.serviceTargets = config.common.deepCopy(derived.serviceTargets or {})
    result.effectiveIntervals = config.common.deepCopy(derived.effectiveIntervals or {})
    result.serviceDueMilesRemaining = config.common.deepCopy(derived.serviceDueMilesRemaining or {})
  end

  local function writeCategoryDriveDiagnostics(result, derived, liveMetrics)
    result.torqueHoldCoef = derived.torqueHoldCoef or 1
    result.liveTorqueHoldCoef = liveMetrics.liveTorqueHoldCoef or
        config.engineCategory.getLiveTorqueHoldCoef(derived.torqueHoldCoef or 1, derived.loadFactor or 0, derived.rpmCapacity or derived.rpmFactor or 0)
    result.powerHoldCoef = derived.powerHoldCoef or 1
    result.roughnessCoef = derived.roughnessCoef or 1
    result.coolantMassCoef = derived.coolantMassCoef or 1
    result.radiatorDamage = derived.radiatorDamage or 0
    result.shiftSpeedCoef = derived.shiftSpeedCoef or 1
    result.lockTorqueCoef = derived.lockTorqueCoef or 1
    result.clutchFreePlayCoef = derived.clutchFreePlayCoef or 1
    result.rpmFactor = derived.rpmFactor or 0
    result.loadFactor = derived.loadFactor or 0
    result.heatFactor = derived.heatFactor or 0
    result.torqueNm = derived.torqueNm or 0
    result.torqueFactor = derived.torqueFactor or 0
    result.powerHp = derived.powerHp or 0
    result.powerFactor = derived.powerFactor or 0
    result.outputStressFactor = derived.outputStressFactor or 0
  end

  local function writeCategoryServiceDiagnostics(result, derived)
    result.profile = config.common.deepCopy(derived.profile or runtime.state.profile or {})
    result.mileageAgeIndex = derived.mileageAgeIndex or 1
    result.levelMileageMultiplier = derived.oilLevelMileageMultiplier or derived.coolantLevelMileageMultiplier or
                                 derived.fluidLevelMileageMultiplier or 1
    result.capacityFactor = derived.oilCapacityFactor or derived.coolantCapacityFactor or derived.fluidCapacityFactor or 1
    result.classConditionIntervalMultiplier = derived.classConditionIntervalMultiplier or 1
    result.lowFluidConditionMultiplier = derived.lowOilConditionMultiplier or derived.lowFluidConditionMultiplier or 1
    result.oilTemperatureMultiplier = derived.oilTemperatureMultiplier or 1
    result.torqueCapacityStress = derived.torqueCapacityStress or 0
    result.torqueCapacityRatio = derived.torqueCapacityRatio
    result.combustionTorque = derived.combustionTorque or 0
    result.maxTorqueRating = derived.maxTorqueRating or 0
    result.extremeOutputGate = derived.extremeOutputGate or 0
    result.extremePowerMultiplier = derived.extremePowerMultiplier or 1
    result.ageWearSeverity = derived.ageWearSeverity or 0
    result.ageWearFrictionCoef = derived.ageWearFrictionCoef or 1
    result.ageWearDynamicFrictionCoef = derived.ageWearDynamicFrictionCoef or 1
    result.ageWearIdleErrorCoef = derived.ageWearIdleErrorCoef or 1
  end

  local function writeCategoryThermalDiagnostics(
    result, categoryName, categoryState, runtimeCategory, derived, liveMetrics, riskFlags
  )
    result.rpmCapacity = derived.rpmCapacity or 0
    result.engineRunningSeconds = derived.engineRunningSeconds or 0
    result.pistonRingsDamaged = derived.pistonRingsDamaged or false
    result.coolantTemp = derived.coolantTemp or 0
    result.oilTemp = derived.oilTemp or 0
    result.oilHeatFactor = derived.oilHeatFactor or 0
    result.oilOverheatFactor = derived.oilOverheatFactor or 0
    result.isOverheating = derived.isOverheating or false
    result.overheatFactor = derived.overheatFactor or 0
    result.hotRuntimeSeconds = derived.hotRuntimeSeconds or 0
    result.overheatingRuntimeSeconds = derived.overheatingRuntimeSeconds or 0
    result.totalHotRuntimeSeconds = derived.totalHotRuntimeSeconds or 0
    result.totalOverheatingRuntimeSeconds = derived.totalOverheatingRuntimeSeconds or 0
    result.warmupEvent = derived.warmupEvent or false
    result.cooldownEvent = derived.cooldownEvent or false
    result.warmupEventCount = derived.warmupEventCount or 0
    result.cooldownEventCount = derived.cooldownEventCount or 0
    result.liveMetrics = liveMetrics
    result.currentEffects = buildCurrentEffects(categoryName, categoryState, runtimeCategory, derived, liveMetrics, false)
    result.riskFlags = riskFlags
    result.curvePreview = buildCurvePreview(categoryName, categoryState, derived)
  end

  local function buildCategoryDebugData(categoryName, categoryState, runtimeCategory, cache, partConditions)
    local derived = runtimeCategory.derived or {}
    local liveMetrics = captureLiveMetrics(categoryName, runtimeCategory, derived)
    local activeSymptom = getRuntimeSymptom(runtimeCategory)
    local outputRestrictionDiagnostic = nil
    if categoryName == 'engine' then
      outputRestrictionDiagnostic = engineRestrictionIsDiagnostic(liveMetrics, activeSymptom)
    end
    local riskFlags = appendBrokenComponentFlags(buildRiskFlags(categoryName, categoryState, derived),
      categoryName, cache, partConditions)
    local result = {}
    writeCategoryMaintenanceDiagnostics(result, categoryName, categoryState, cache, partConditions, derived)
    writeCategoryRuntimeDiagnostics(result, runtimeCategory, derived, activeSymptom, outputRestrictionDiagnostic)
    writeCategoryDriveDiagnostics(result, derived, liveMetrics)
    writeCategoryServiceDiagnostics(result, derived)
    writeCategoryThermalDiagnostics(
      result, categoryName, categoryState, runtimeCategory, derived, liveMetrics, riskFlags
    )
    return result
  end

  local function collectCategoryDiagnostics(partConditions)
    local categories = {}
    for _, categoryName in ipairs(config.categoryOrder) do
      local categoryState = runtime.state.categories and runtime.state.categories[categoryName] or nil
      if categoryState then
        local cache = runtime.categoryCache[categoryName] or {}
        local runtimeCategory = runtime.runtimeState[categoryName] or {}
        categories[categoryName] = buildCategoryDebugData(categoryName, categoryState, runtimeCategory, cache, partConditions)
      end
    end
    return categories
  end

  local function buildDebugStream()
    runtime.tickPartConditions = nil
    local partConditions = parts.state.getTrackedPartConditions()
    runtime.tickPartConditions = partConditions
    local preview = helpers.preview()
    local scenarioInputs = preview.ensureScenarioInputs(parts.environment.buildEnvironmentSnapshot(0, true))
    local categories = collectCategoryDiagnostics(partConditions)

    local scenarioPreview = {
      presetId = runtime.runtimeState and runtime.runtimeState.debug and runtime.runtimeState.debug.scenarioPresetId or nil,
      categories = {}
    }
    for _, categoryName in ipairs(config.categoryOrder) do
      scenarioPreview.categories[categoryName] = buildCategoryPreview(categoryName, scenarioInputs)
    end
    runtime.tickPartConditions = nil

    local lastSyncDistanceM = runtime.state.lastSyncMileage or 0
    return {
      inventoryId = runtime.inventoryId,
      vehicleId = obj:getId(),
      profile = config.common.deepCopy(runtime.state.profile or parts.state.buildDefaultProfile()),
      lastSyncMileageMiles = lastSyncDistanceM * config.common.metersToMiles,
      overview = buildOverviewSummary(categories),
      categories = categories,
      scenarioInputs = config.common.deepCopy(scenarioInputs),
      scenarioPresets = preview.buildScenarioPresetList(),
      scenarioPreview = scenarioPreview,
      currentEffects = {
        engine = config.common.deepCopy(categories.engine and categories.engine.currentEffects or {}),
        radiator = config.common.deepCopy(categories.radiator and categories.radiator.currentEffects or {}),
        transmission = config.common.deepCopy(categories.transmission and categories.transmission.currentEffects or {})
      },
      riskFlags = {
        engine = config.common.deepCopy(categories.engine and categories.engine.riskFlags or {}),
        radiator = config.common.deepCopy(categories.radiator and categories.radiator.riskFlags or {}),
        transmission = config.common.deepCopy(categories.transmission and categories.transmission.riskFlags or {})
      },
      curvePreview = {
        engine = config.common.deepCopy(categories.engine and categories.engine.curvePreview or {}),
        radiator = config.common.deepCopy(categories.radiator and categories.radiator.curvePreview or {}),
        transmission = config.common.deepCopy(categories.transmission and categories.transmission.curvePreview or {})
      },
      debugMeta = {
        builtAt = os.time(),
        streamIntervalSeconds = config.debugStreamInterval,
        buildCount = runtime.debugStreamBuildCount,
        usingTrackedPartConditions = type(runtime.trackedPartConditions) == "table",
        trackedPartConditionSignatureLength = runtime.trackedPartConditionsSignature and string.len(runtime.trackedPartConditionsSignature) or 0,
        scenarioUpdatedAt = runtime.runtimeState and runtime.runtimeState.debug and runtime.runtimeState.debug.scenarioUpdatedAt or 0
      }
    }
  end

  local debugStreamSubscribed = false
  local function sendDebugStream(force)
    if streams and streams.willSend and streams.willSend("vehicleMaintenanceDebugData") then
      -- A reopened view needs a snapshot even if nothing changed while closed.
      if not debugStreamSubscribed then runtime.debugStreamDirty = true end
      debugStreamSubscribed = true
      if force or runtime.debugStreamDirty or not runtime.debugStreamCache then
        runtime.debugStreamBuildCount = runtime.debugStreamBuildCount + 1
        runtime.debugStreamCache = buildDebugStream()
        runtime.debugStreamDirty = false
        if runtime.debugStreamCache and runtime.debugStreamCache.debugMeta then
          runtime.debugStreamCache.debugMeta.buildCount = runtime.debugStreamBuildCount
        end
        if runtime.debugStreamCache then
          runtime.debugStreamSendCount = runtime.debugStreamSendCount + 1
          gui.send("vehicleMaintenanceDebugData", runtime.debugStreamCache)
        end
      end
    else
      debugStreamSubscribed = false
      runtime.debugStreamCache = nil
    end
  end

  return {
    captureLiveMetrics = captureLiveMetrics,
    engineRestrictionIsDiagnostic = engineRestrictionIsDiagnostic,
    getRuntimeSymptom = getRuntimeSymptom,
    getTransmissionThermalStress = getTransmissionThermalStress,
    sendDebugStream = sendDebugStream,
  }

end

return M
