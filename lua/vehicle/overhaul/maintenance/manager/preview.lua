-- Scenario preview: preset definitions, scenario inputs and preview category states.
-- Each extension load owns its runtime and the parts it calls.
local M = {}

local scenarioPresetDefinitions = {
  {
    id = "highMileageLowOil",
    label = "High-mileage low-oil car",
    description = "Older engine with neglected oil and moderate stress.",
    inputs = {
      avgMiles = 210000,
      loadFactor = 0.62,
      rpmFactor = 0.58,
      heatFactor = 0.45,
      powerHp = 320,
      torqueNm = 460,
      maintenance = {
        engine = {oilCondition = 0.42, oilLevel = 0.24, ignitionService = 0.55},
        radiator = {coolantLevel = 0.72, coolantIntegrity = 0.68},
        transmission = {fluidCondition = 0.74, fluidLevel = 0.84}
      }
    }
  },
  {
    id = "enduranceRace",
    label = "Endurance race car",
    description = "Healthy car under sustained but reasonable race stress.",
    inputs = {
      avgMiles = 18000,
      loadFactor = 0.74,
      rpmFactor = 0.76,
      heatFactor = 0.42,
      powerHp = 320,
      torqueNm = 410,
      maintenance = {
        engine = {oilCondition = 0.92, oilLevel = 0.9, ignitionService = 0.9},
        radiator = {coolantLevel = 0.95, coolantIntegrity = 0.94},
        transmission = {fluidCondition = 0.92, fluidLevel = 0.94}
      }
    }
  },
  {
    id = "overheatedCooling",
    label = "Overheated cooling system",
    description = "Cooling system on the edge with active thermal stress.",
    inputs = {
      avgMiles = 125000,
      loadFactor = 0.78,
      rpmFactor = 0.71,
      heatFactor = 0.92,
      powerHp = 360,
      torqueNm = 500,
      maintenance = {
        engine = {oilCondition = 0.72, oilLevel = 0.8, ignitionService = 0.76},
        radiator = {coolantLevel = 0.36, coolantIntegrity = 0.42},
        transmission = {fluidCondition = 0.86, fluidLevel = 0.88}
      }
    }
  },
  {
    id = "wornTowRig",
    label = "Worn towing transmission",
    description = "Load-heavy drivetrain with overdue transmission fluid service.",
    inputs = {
      avgMiles = 165000,
      loadFactor = 0.88,
      rpmFactor = 0.54,
      heatFactor = 0.36,
      powerHp = 420,
      torqueNm = 980,
      maintenance = {
        engine = {oilCondition = 0.76, oilLevel = 0.84, ignitionService = 0.78},
        radiator = {coolantLevel = 0.82, coolantIntegrity = 0.8},
        transmission = {fluidCondition = 0.38, fluidLevel = 0.52}
      }
    }
  },
  {
    id = "extremeDrag",
    label = "Extreme high-hp drag build",
    description = "Very high output engine where service life falls rapidly.",
    inputs = {
      avgMiles = 26000,
      loadFactor = 0.96,
      rpmFactor = 0.93,
      heatFactor = 0.62,
      powerHp = 2200,
      torqueNm = 2400,
      maintenance = {
        engine = {oilCondition = 0.74, oilLevel = 0.82, ignitionService = 0.68},
        radiator = {coolantLevel = 0.84, coolantIntegrity = 0.8},
        transmission = {fluidCondition = 0.66, fluidLevel = 0.72}
      }
    }
  }
}

function M.create(inputs)
  local runtime, config, helpers, parts = inputs.runtime, inputs.config, inputs.helpers, inputs.parts

  local function buildScenarioPresetList()
    local presets = {}
    for _, preset in ipairs(scenarioPresetDefinitions) do
      table.insert(presets, {
        id = preset.id,
        label = preset.label,
        description = preset.description
      })
    end
    return presets
  end

  local function getCurrentAverageMiles()
    local total = 0
    local count = 0
    if type(runtime.state) == "table" and type(runtime.state.categories) == "table" then
      for _, categoryName in ipairs(config.categoryOrder) do
        local categoryState = runtime.state.categories[categoryName]
        if type(categoryState) == "table" then
          total = total + ((tonumber(categoryState.avgOdometer) or 0) * config.common.metersToMiles)
          count = count + 1
        end
      end
    end
    if count <= 0 then
      return 0
    end
    return total / count
  end

  local function buildScenarioInputsFromLiveSnapshot(snapshot)
    local maintenance = {}
    for _, categoryName in ipairs(config.categoryOrder) do
      maintenance[categoryName] = config.common.deepCopy(runtime.state and runtime.state.categories and runtime.state.categories[categoryName] and
                                                      runtime.state.categories[categoryName].maintenance or
                                                      config.categoryModules[categoryName].getDefaultMaintenance())
    end

    return {
      avgMiles = helpers.roundValue(getCurrentAverageMiles(), 1),
      loadFactor = config.common.clamp(snapshot and snapshot.loadFactor or 0, 0, 1),
      rpmFactor = config.common.clamp(snapshot and snapshot.rpmFactor or 0, 0, 1),
      heatFactor = config.common.clamp(snapshot and snapshot.heatFactor or 0, 0, 1),
      powerHp = helpers.roundValue(snapshot and snapshot.powerHp or 0, 1),
      torqueNm = helpers.roundValue(snapshot and snapshot.torqueNm or 0, 1),
      maintenance = maintenance
    }
  end

  local function normalizeScenarioInputs(inputs)
    local normalized = inputs and config.common.deepCopy(inputs) or {}
    normalized.avgMiles = config.max(tonumber(normalized.avgMiles) or 0, 0)
    normalized.loadFactor = config.common.clamp(tonumber(normalized.loadFactor) or 0, 0, 1)
    normalized.rpmFactor = config.common.clamp(tonumber(normalized.rpmFactor) or 0, 0, 1)
    normalized.heatFactor = config.common.clamp(tonumber(normalized.heatFactor) or 0, 0, 1)
    normalized.powerHp = config.max(tonumber(normalized.powerHp) or 0, 0)
    normalized.torqueNm = config.max(tonumber(normalized.torqueNm) or 0, 0)
    normalized.maintenance = type(normalized.maintenance) == "table" and normalized.maintenance or {}

    for _, categoryName in ipairs(config.categoryOrder) do
      local categoryMaintenance = normalized.maintenance[categoryName]
      local defaultMaintenance = config.categoryModules[categoryName].getDefaultMaintenance()
      normalized.maintenance[categoryName] = {}
      for itemName, defaultValue in pairs(defaultMaintenance) do
        normalized.maintenance[categoryName][itemName] = config.common.clamp(
          tonumber(type(categoryMaintenance) == "table" and categoryMaintenance[itemName] or nil) or tonumber(defaultValue) or 1,
          0,
          1
        )
      end
    end

    return normalized
  end

  local function mergeScenarioInputs(baseInputs, updateInputs)
    local merged = normalizeScenarioInputs(baseInputs)
    if type(updateInputs) ~= "table" then
      return merged
    end

    for key, value in pairs(updateInputs) do
      if key == "maintenance" and type(value) == "table" then
        merged.maintenance = merged.maintenance or {}
        for categoryName, maintenanceValues in pairs(value) do
          if type(maintenanceValues) == "table" then
            merged.maintenance[categoryName] = merged.maintenance[categoryName] or {}
            for itemName, itemValue in pairs(maintenanceValues) do
              merged.maintenance[categoryName][itemName] = itemValue
            end
          end
        end
      else
        merged[key] = value
      end
    end

    return normalizeScenarioInputs(merged)
  end

  local function ensureScenarioInputs(snapshot)
    runtime.runtimeState.debug = runtime.runtimeState.debug or {}
    if type(runtime.runtimeState.debug.scenarioInputs) ~= "table" then
      runtime.runtimeState.debug.scenarioInputs = normalizeScenarioInputs(buildScenarioInputsFromLiveSnapshot(snapshot))
      runtime.runtimeState.debug.scenarioUpdatedAt = os.time()
    end
    return runtime.runtimeState.debug.scenarioInputs
  end

  local function buildScenarioEnvironment(categoryName, inputs)
    inputs = normalizeScenarioInputs(inputs)
    local avgMiles = config.max(tonumber(inputs.avgMiles) or 0, 0)
    local coolantTemp = config.common.lerp(70, 135, inputs.heatFactor or 0)
    local oilTemp = config.common.lerp(85, 165, inputs.heatFactor or 0)
    local env = parts.environment.buildEnvironment(categoryName, avgMiles, {
      loadFactor = inputs.loadFactor,
      rpmFactor = inputs.rpmFactor,
      heatFactor = inputs.heatFactor,
      torqueNm = inputs.torqueNm,
      torqueFactor = config.common.getTorqueFactor(inputs.torqueNm),
      coolantTemp = coolantTemp,
      oilTemp = oilTemp,
      oilHeatFactor = config.common.clamp(config.common.linearScale(oilTemp, 105, 145, 0, 1), 0, 1),
      oilOverheatFactor = config.common.clamp(config.common.linearScale(oilTemp, 135, 170, 0, 1), 0, 1),
      powerHp = inputs.powerHp,
      powerFactor = config.common.getPowerFactor(inputs.powerHp),
      outputStressFactor = config.common.getOutputStress(inputs.powerHp, inputs.torqueNm).engine,
      rpmCapacity = config.common.clamp(config.common.linearScale(inputs.rpmFactor or 0, 0, 1, 0.35, 1.05), 0, 1.5),
      engineRunningSeconds = 0,
      pistonRingsDamaged = false,
      isOverheating = coolantTemp >= 115,
      overheatFactor = config.common.clamp(config.common.linearScale(coolantTemp, 115, 135, 0, 1), 0, 1),
      warmupEvent = false,
      cooldownEvent = false,
      hotRuntimeSeconds = 0,
      overheatingRuntimeSeconds = 0,
      totalHotRuntimeSeconds = 0,
      totalOverheatingRuntimeSeconds = 0,
      warmupEventCount = 0,
      cooldownEventCount = 0
    })

    return env
  end

  local function buildPreviewCategoryState(categoryName, inputs)
    inputs = normalizeScenarioInputs(inputs)
    return {
      maintenance = config.common.deepCopy(inputs.maintenance and inputs.maintenance[categoryName] or
                                        config.categoryModules[categoryName].getDefaultMaintenance())
    }
  end

  return {
    buildPreviewCategoryState = buildPreviewCategoryState,
    buildScenarioEnvironment = buildScenarioEnvironment,
    buildScenarioPresetList = buildScenarioPresetList,
    ensureScenarioInputs = ensureScenarioInputs,
  }

end

return M
