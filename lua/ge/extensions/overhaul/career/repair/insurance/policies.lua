-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Insurance policies: player policy data load/save and the active insurance.
-- Part of the Overhaul fork of stock lua/ge/extensions/career/modules/insurance/insurance.lua.
local partFactory = {}

-- inputs: state.
-- Bind sibling helpers after construction so each extension load keeps its own closures.
function partFactory.new(inputs)
  local insuranceState = inputs.state
  local M, availableClasses, availableInsurances, dataFiles, defaultDriverScore, lastPos,
    normalizeInvVehsKeys, plInsuranceDataFileName

  local function saveInsurancesData(currentSavePath)
    local dataToSave =
    {
      plDriverScore = insuranceState.plDriverScore,
      lastDriverScoreKmIncrease = insuranceState.lastDriverScoreKmIncrease,
      lastDriverScoreInsuredKmIncrease = insuranceState.lastDriverScoreInsuredKmIncrease,
      totalDrivenDistance = insuranceState.totalDrivenDistance,
      insuredDrivenDistance = insuranceState.insuredDrivenDistance,
      plInsurancesData = insuranceState.plInsurancesData,
      invVehs = insuranceState.invVehs,
      plHistory = overhaul_career_repair_insuranceHistory.getPlHistory(),
    }

    overhaul_career_saveSystem.jsonWriteFileSafe(currentSavePath .. "/career/"..plInsuranceDataFileName..".json", dataToSave, true)
  end

  local function setActiveInsurance()
    local newVehId = be:getPlayerVehicleID(0)
    if newVehId == -1 then return end

    if gameplay_walk.isWalking() then
      insuranceState.activeInsuranceId = -1
    else
      local invVehId = overhaul_career_garage_inventory.getInventoryIdFromVehicleId(newVehId)
      if invVehId then
        -- Every owned car contributes mileage, including cars without a policy.
        local newVeh = scenetree.findObjectById(newVehId)
        if newVeh then
          lastPos:set(newVeh:getPosition())
        end
        if insuranceState.invVehs[invVehId] then
          insuranceState.activeInsuranceId = insuranceState.invVehs[invVehId].insuranceId or -1
        else
          insuranceState.activeInsuranceId = -1
        end
      else
        insuranceState.activeInsuranceId = -1
      end
    end
  end

  local function ensurePlInsurancesDataSchema()
    if type(insuranceState.plInsurancesData) ~= "table" then
      insuranceState.plInsurancesData = {}
    end

    for _, insuranceInfo in pairs(availableInsurances) do
      local insuranceId = insuranceInfo.id
      local plData = insuranceState.plInsurancesData[insuranceId]
      local createdNew = false

      if type(plData) ~= "table" then
        plData = {}
        insuranceState.plInsurancesData[insuranceId] = plData
        createdNew = true
      end

      plData.metersDriven = plData.metersDriven or 0
      plData.accidentForgiveness = plData.accidentForgiveness or 0
      plData.roadsideAssistance = plData.roadsideAssistance or 0
      plData.score = plData.score or 1
      plData.loyalty = plData.loyalty or 0
      plData.insuranceId = plData.insuranceId or insuranceId
      plData.lastRenewedAt = plData.lastRenewedAt or 0
      plData.nextInsuranceEditTimer = plData.nextInsuranceEditTimer or 0

      if type(plData.gesturesData) ~= "table" then
        plData.gesturesData = {}
      end
      if type(plData.coverageOptionsData) ~= "table" then
        plData.coverageOptionsData = {}
      end
      if type(plData.coverageOptionsData.currentCoverageOptions) ~= "table" then
        plData.coverageOptionsData.currentCoverageOptions = {}
      end

      if type(insuranceInfo.gestures) == "table" then
        for gestureName, _ in pairs(insuranceInfo.gestures) do
          if type(plData.gesturesData[gestureName]) ~= "table" then
            plData.gesturesData[gestureName] = {lastHappenedAt = 0}
          elseif plData.gesturesData[gestureName].lastHappenedAt == nil then
            plData.gesturesData[gestureName].lastHappenedAt = 0
          end
        end
      end

      if type(insuranceInfo.coverageOptions) == "table" then
        for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions) do
          local optionDef = insuranceState.availableCoverageOptions and insuranceState.availableCoverageOptions[coverageOptionName]
          if optionDef and optionDef.isInsuranceWide then
            if plData.coverageOptionsData.currentCoverageOptions[coverageOptionName] == nil then
              plData.coverageOptionsData.currentCoverageOptions[coverageOptionName] = coverageOptionInfo.baseValueId
            end
          end
        end
      end

      if createdNew then
        M.topUpRoadsideAssistance(insuranceId)
      end
    end
  end

  local englishTranslations = {}

  -- The legacy native translator can miss mod locale files in shipping
  -- builds. Resolve definition text before it is copied into UI and history.
  local function translateInsuranceText(key)
    if type(key) ~= "string" then return key end
    local translated = type(_tr) == "function" and _tr(key) or nil
    if type(translated) == "string" and translated ~= "" and translated ~= key then
      return translated
    end
    local fallback = englishTranslations[key]
    return type(fallback) == "string" and fallback ~= "" and fallback or key
  end

  local function loadInsuranceProviderDefinitions()
    local perks = jsonReadFile(dataFiles.resolve("gameplay/insurance/perks/perks.json")).perks

    -- load insurance providers, and translate their names and descriptions
    local insuranceProvidersFileNames = dataFiles.findFiles("gameplay/insurance/providers", "*.json", -1, true, false)
    for _, insuranceProviderFileName in ipairs(insuranceProvidersFileNames) do
      local insuranceInfo = jsonReadFile(insuranceProviderFileName)
      availableInsurances[insuranceInfo.id] = insuranceInfo

      -- create the texts for the perks
      if insuranceInfo.perks then
        for perkId, perkInfo in pairs(insuranceInfo.perks) do
          local perkStaticData = perks[perkId]
          local suffixTranslatedIntro = translateInsuranceText(perkStaticData.intro)
          local translatedIntro = ""
          if perkStaticData.valueType == "unit" then
            translatedIntro = perkInfo.value .. " " .. suffixTranslatedIntro
          elseif perkStaticData.valueType == "percentage" then
            translatedIntro = perkInfo.value * 100 .. "% " .. suffixTranslatedIntro
          elseif perkStaticData.valueType == "boolean" then
            translatedIntro = suffixTranslatedIntro
          end

          perkInfo.intro = translatedIntro
          perkInfo.description = translateInsuranceText(perkStaticData.description)
        end
      end

      -- deductible discount perk
      local deductibleDiscountPerkValue = M.getPerkValueByInsuranceId(insuranceInfo.id, "reduceDeductible")
      if deductibleDiscountPerkValue then
        insuranceInfo.coverageOptions.deductible.perkText = insuranceInfo.perks.reduceDeductible.intro
        for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.deductible.choices) do
          coverageOptionInfo.oldValue = coverageOptionInfo.value
          coverageOptionInfo.value = coverageOptionInfo.value * (1 - deductibleDiscountPerkValue)
        end
      end

      -- paint repair perk
      local paintRepairPerkValue = M.getPerkValueByInsuranceId(insuranceInfo.id, "freeRepaintDuringRepair")
      if paintRepairPerkValue then
        insuranceInfo.coverageOptions.paintRepair.perkText = insuranceInfo.perks.freeRepaintDuringRepair.intro
        for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.paintRepair.choices) do
          coverageOptionInfo.oldPremiumInfluence = coverageOptionInfo.premiumInfluence
          coverageOptionInfo.premiumInfluence = 0
        end
      end

      -- free towing perk
      local freeTowingPerkValue = M.getPerkValueByInsuranceId(insuranceInfo.id, "freeTowing")
      if freeTowingPerkValue then
        local lastTowPremiumInfluence = 0
        insuranceInfo.coverageOptions.roadsideAssistance.perkText = insuranceInfo.perks.freeTowing.intro
        for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.roadsideAssistance.choices) do
          coverageOptionInfo.oldPremiumInfluence = coverageOptionInfo.premiumInfluence
          if coverageOptionInfo.value <= freeTowingPerkValue then
            if coverageOptionInfo.value < freeTowingPerkValue then
              coverageOptionInfo.disabled = true -- players can't select this option
            end
            lastTowPremiumInfluence = coverageOptionInfo.premiumInfluence
            coverageOptionInfo.premiumInfluence = 0
          else -- discount on tows number that are more than the perk covers
            coverageOptionInfo.premiumInfluence = coverageOptionInfo.premiumInfluence - lastTowPremiumInfluence
          end
        end
      end

      -- repair time discount perk
      local repairTimeDiscountPerkValue = M.getPerkValueByInsuranceId(insuranceInfo.id, "repairTimeDiscount")
      if repairTimeDiscountPerkValue then
        insuranceInfo.coverageOptions.repairTime.perkText = insuranceInfo.perks.repairTimeDiscount.intro
        for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.repairTime.choices) do
          coverageOptionInfo.premiumInfluence = coverageOptionInfo.premiumInfluence * (1 - repairTimeDiscountPerkValue)
        end
      end

      -- instant repair perk
      local instantRepairPerkValue = M.getPerkValueByInsuranceId(insuranceInfo.id, "instantRepair")
      if instantRepairPerkValue then
        insuranceInfo.coverageOptions.repairTime.perkText = insuranceInfo.perks.instantRepair.intro
        for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.repairTime.choices) do
          if coverageOptionInfo.value > 0 then
            coverageOptionInfo.disabled = true
          end
          coverageOptionInfo.premiumInfluence = 0
        end
      end

      for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.roadsideAssistance.choices) do
        coverageOptionInfo.choiceText = string.format("%i tows", coverageOptionInfo.value)
      end
      for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.repairTime.choices) do
        coverageOptionInfo.choiceText = coverageOptionInfo.value / 60 > 0 and string.format("%i min", coverageOptionInfo.value / 60) or "Instant"
      end
      for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions.deductible.choices) do
        coverageOptionInfo.choiceText = string.format("%i$", coverageOptionInfo.value)
      end
      insuranceInfo.name = translateInsuranceText(insuranceInfo.name)
      insuranceInfo.slogan = translateInsuranceText(insuranceInfo.slogan)
      for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions) do
        for choiceId, choiceInfo in pairs(coverageOptionInfo.choices) do --add id to each choice to make it more practical
          choiceInfo.id = choiceId
        end
        coverageOptionInfo.name = coverageOptionName
        coverageOptionInfo.unit = insuranceState.availableCoverageOptions[coverageOptionName].unit
        coverageOptionInfo.niceName = translateInsuranceText(insuranceState.availableCoverageOptions[coverageOptionName].niceName)
        coverageOptionInfo.desc = translateInsuranceText(insuranceState.availableCoverageOptions[coverageOptionName].desc)
      end
    end
  end

  -- resetSomeData is there only for career debug
  local function loadInsurancesData(resetSomeData)
    if resetSomeData == nil then
      resetSomeData = false
    end

    local saveSlot, savePath = overhaul_career_saveSystem.getCurrentProfile()
    if not saveSlot then return end

    local locale = jsonReadFile("/locales/translations/en-US/rls_career_overhaul.insurance.translation.json")
    englishTranslations = type(locale) == "table" and locale or {}

    insuranceState.driverScoreTiers = jsonReadFile(dataFiles.resolve("gameplay/insurance/driverScoreTiers.json")).tiers

    insuranceState.availableCoverageOptions = jsonReadFile(dataFiles.resolve("gameplay/insurance/coverageOptions/coverageOptions.json")).coverageOptions
    loadInsuranceProviderDefinitions()

    -- load insurance classes, and translate their names
    local classesFileNames = dataFiles.findFiles("gameplay/insurance/classes", "*.json", -1, true, false)
    for _, className in ipairs(classesFileNames) do
      local classInfo = jsonReadFile(className)
      availableClasses[classInfo.id] = classInfo
      classInfo.name = translateInsuranceText(classInfo.name)
      classInfo.description = translateInsuranceText(classInfo.description)
    end

    -- load player data
    local savedPlInsuranceData = (savePath and jsonReadFile(savePath .. "/career/"..plInsuranceDataFileName..".json")) or {}
    local saveInfo = savePath and jsonReadFile(savePath .. "/info.json")
    if type(saveInfo) ~= "table" then
      log("W", "career.insurance", "Missing or unreadable info.json while loading insurance; preserving insurance tables if present")
    end
    -- First load only when insurance bookkeeping is missing. Do not wipe on a
    -- save-system version bump or a bad info.json (migration keeps the fleet).
    local isFirstLoadEver = type(savedPlInsuranceData.invVehs) ~= "table"
      or type(savedPlInsuranceData.plInsurancesData) ~= "table"
    if isFirstLoadEver then -- first load ever
      insuranceState.invVehs = {}
      normalizeInvVehsKeys()
      overhaul_career_repair_insuranceHistory.initPlHistory()
      insuranceState.plDriverScore = 65
      insuranceState.lastDriverScoreKmIncrease = 0
      insuranceState.lastDriverScoreInsuredKmIncrease = 0
      insuranceState.totalDrivenDistance = 0
      insuranceState.insuredDrivenDistance = 0
      insuranceState.plInsurancesData = {}
      for _, insuranceInfo in pairs(availableInsurances) do
        insuranceState.plInsurancesData[insuranceInfo.id] = {
          metersDriven = 0,
          accidentForgiveness = 0,
          roadsideAssistance = 0,
          score = 1,
          loyalty = 0,
          insuranceId = insuranceInfo.id,
          lastRenewedAt = 0,
          gesturesData = {},
          coverageOptionsData = {
            currentCoverageOptions = {}
          }
        }
        for gestureName, gestureInfo in pairs(insuranceInfo.gestures) do
          insuranceState.plInsurancesData[insuranceInfo.id].gesturesData[gestureName] = {
            lastHappenedAt = 0
          }
        end
        for coverageOptionName, coverageOptionInfo in pairs(insuranceInfo.coverageOptions) do
          if insuranceState.availableCoverageOptions[coverageOptionName].isInsuranceWide then
            insuranceState.plInsurancesData[insuranceInfo.id].coverageOptionsData.currentCoverageOptions[coverageOptionName] = coverageOptionInfo.baseValueId
          end
        end
        M.topUpRoadsideAssistance(insuranceInfo.id)
      end
    else
      insuranceState.plDriverScore = savedPlInsuranceData.plDriverScore or defaultDriverScore
      insuranceState.lastDriverScoreKmIncrease = savedPlInsuranceData.lastDriverScoreKmIncrease or 0
      insuranceState.totalDrivenDistance = savedPlInsuranceData.totalDrivenDistance or 0
      insuranceState.insuredDrivenDistance = savedPlInsuranceData.insuredDrivenDistance
      if not insuranceState.insuredDrivenDistance then
        -- Older saves never tracked this; every metre logged against a policy was insured.
        insuranceState.insuredDrivenDistance = 0
        for _, plData in pairs(savedPlInsuranceData.plInsurancesData or {}) do
          insuranceState.insuredDrivenDistance = insuranceState.insuredDrivenDistance + (tonumber(plData.metersDriven) or 0)
        end
        insuranceState.insuredDrivenDistance = math.min(insuranceState.insuredDrivenDistance, insuranceState.totalDrivenDistance)
      end
      insuranceState.lastDriverScoreInsuredKmIncrease = savedPlInsuranceData.lastDriverScoreInsuredKmIncrease
      if insuranceState.lastDriverScoreInsuredKmIncrease == nil then
        -- Preserve existing progress when migrating the total-distance marker.
        local progress = math.min(insuranceState.insuredDrivenDistance,
          math.max(0, insuranceState.totalDrivenDistance - insuranceState.lastDriverScoreKmIncrease))
        insuranceState.lastDriverScoreInsuredKmIncrease = insuranceState.insuredDrivenDistance - progress
      end
      insuranceState.invVehs = savedPlInsuranceData.invVehs
      normalizeInvVehsKeys()
      -- saves can carry entries for vehicles that are no longer in the inventory. Only prune when the
      -- inventory actually loaded, so a load-order change can never wipe every entry.
      local inventoryVehs = not overhaul_career_garage_inventory.isEmpty() and overhaul_career_garage_inventory.getVehicles() or nil
      for invVehId, invVehData in pairs(insuranceState.invVehs) do
        -- making sure old broken nil insuranceId are converted to -1
        if invVehData.insuranceId == nil then
          log("W", "Career", "Repaired legacy invVeh entry " .. tostring(invVehId) .. ": insuranceId was nil, coerced to -1")
          invVehData.insuranceId = -1
        end
        if inventoryVehs and not inventoryVehs[invVehData.id or invVehId] then
          log("W", "Career", "Dropped stale invVeh entry " .. tostring(invVehId) .. ": no such vehicle in the inventory")
          overhaul_career_ui_log.addLog(string.format("Dropped stale invVeh entry %s (insuranceId %s): no such vehicle in the inventory", tostring(invVehId), tostring(invVehData.insuranceId)), "insurance", "W")
          insuranceState.invVehs[invVehId] = nil
        end
      end
      overhaul_career_repair_insuranceHistory.setPlHistory(savedPlInsuranceData.plHistory)
      insuranceState.plInsurancesData = savedPlInsuranceData.plInsurancesData or {}
    end

    ensurePlInsurancesDataSchema()

    overhaul_career_ui_log.addLog(string.format("Loaded insurance data (%s): %d insured vehicle entries, driver score %d, %.0fm driven (%.0fm insured)",
      isFirstLoadEver and "fresh init" or "from save", tableSize(insuranceState.invVehs), tonumber(insuranceState.plDriverScore) or 0, tonumber(insuranceState.totalDrivenDistance) or 0, tonumber(insuranceState.insuredDrivenDistance) or 0), "insurance")
  end

  return {
    loadInsurancesData = loadInsurancesData,
    saveInsurancesData = saveInsurancesData,
    setActiveInsurance = setActiveInsurance,
    bindInputs = function(inputs)
      M = inputs.M
      availableClasses = inputs.availableClasses
      availableInsurances = inputs.availableInsurances
      dataFiles = inputs.dataFiles
      defaultDriverScore = inputs.defaultDriverScore
      lastPos = inputs.lastPos
      normalizeInvVehsKeys = inputs.normalizeInvVehsKeys
      plInsuranceDataFileName = inputs.plInsuranceDataFileName
    end,
  }
end

return partFactory
